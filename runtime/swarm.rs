use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Map, Value};
use std::env;
use std::fs::{self, File};
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::raw::c_int;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command as ProcessCommand, ExitCode, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(unix)]
const SIGTERM: c_int = 15;
#[cfg(unix)]
const SIGKILL: c_int = 9;

#[cfg(unix)]
extern "C" {
    fn setsid() -> c_int;
    fn kill(pid: c_int, sig: c_int) -> c_int;
}

#[derive(Clone)]
struct SwarmEvent {
    kind: String,
    task_id: String,
    actor: String,
    detail: String,
    at_ms: i64,
    payload_json: String,
}

#[derive(Clone)]
struct SwarmTaskState {
    task_id: String,
    status: String,
    lease_actor: String,
    last_heartbeat_at_ms: i64,
    heartbeat_seen: bool,
    attempts: i64,
    last_error: String,
    created_at_ms: i64,
    updated_at_ms: i64,
}

struct SwarmRunRecord {
    run_id: i64,
    task_id: String,
    role: String,
    actor: String,
    name: String,
    cwd: String,
    command: Vec<String>,
    exit_code: i64,
    status: String,
    started_at_ms: i64,
    ended_at_ms: i64,
    stdout_artifact_path: String,
    stderr_artifact_path: String,
}

struct SwarmArtifactRecord {
    artifact_id: i64,
    task_id: String,
    kind: String,
    path: String,
    created_at_ms: i64,
    metadata_json: String,
}

struct SwarmApprovalRecord {
    approval_id: i64,
    task_id: String,
    name: String,
    actor: String,
    detail: String,
    at_ms: i64,
    payload_json: String,
}

struct SwarmMemoryRecord {
    memory_id: i64,
    objective_id: String,
    task_id: String,
    key: String,
    value: String,
    actor: String,
    created_at_ms: i64,
    updated_at_ms: i64,
}

struct SwarmObjectiveRecord {
    objective_id: String,
    detail: String,
    status: String,
    max_tasks: i64,
    max_runs: i64,
    deadline_at_ms: i64,
    created_at_ms: i64,
    updated_at_ms: i64,
}

struct SwarmTaskSpecRecord {
    task_id: String,
    objective_id: String,
    detail: String,
    max_runs: i64,
    deadline_at_ms: i64,
    lease_timeout_ms: i64,
    created_at_ms: i64,
    updated_at_ms: i64,
}

struct SwarmMergePolicyRecord {
    task_id: String,
    mergegate_name: String,
    required_approvals_json: String,
    required_verifiers_json: String,
    created_at_ms: i64,
    updated_at_ms: i64,
}

struct SwarmRuntimePaths {
    root: PathBuf,
    db_path: PathBuf,
    artifacts_dir: PathBuf,
}

const DEFAULT_LEASE_TIMEOUT_MS: i64 = 60_000;

enum SwarmCommand {
    Start { root: PathBuf, task_id: String, actor: String, detail: Option<String> },
    Bootstrap { root: PathBuf, task_id: String, actor: String, detail: Option<String> },
    Lease { root: PathBuf, task_id: String, actor: String, detail: Option<String> },
    Release { root: PathBuf, task_id: String, actor: String, detail: Option<String> },
    Heartbeat { root: PathBuf, task_id: String, actor: String, detail: Option<String> },
    Complete { root: PathBuf, task_id: String, actor: String, detail: Option<String> },
    Fail { root: PathBuf, task_id: String, actor: String, detail: Option<String> },
    Retry { root: PathBuf, task_id: String, actor: String, detail: Option<String> },
    Stop { root: PathBuf, task_id: String, actor: String, detail: Option<String> },
    Resume { root: PathBuf, task_id: String, actor: String, detail: Option<String> },
    Status { root: PathBuf, task_id: String },
    History { root: PathBuf, task_id: String },
    Tasks { root: PathBuf },
    Summary { root: PathBuf },
    Tail { root: PathBuf, task_id: Option<String>, limit: usize },
    Runs { root: PathBuf, task_id: Option<String> },
    Artifacts { root: PathBuf, task_id: Option<String> },
    MemoryPut {
        root: PathBuf,
        objective_id: String,
        task_id: String,
        actor: String,
        key: String,
        value: String,
    },
    MemoryQuery {
        root: PathBuf,
        objective_id: Option<String>,
        task_id: Option<String>,
        key: Option<String>,
        limit: usize,
    },
    ObjectiveCreate {
        root: PathBuf,
        objective_id: String,
        detail: String,
        max_tasks: i64,
        max_runs: i64,
        deadline_at_ms: i64,
    },
    ObjectiveStatus { root: PathBuf, objective_id: String },
    Objectives { root: PathBuf },
    TaskCreate {
        root: PathBuf,
        objective_id: String,
        task_id: String,
        detail: String,
        dependencies: Vec<String>,
        max_runs: i64,
        deadline_at_ms: i64,
        lease_timeout_ms: i64,
    },
    Ready { root: PathBuf, objective_id: Option<String> },
    Approve { root: PathBuf, task_id: String, actor: String, approval_name: String, detail: Option<String> },
    Approvals { root: PathBuf, task_id: Option<String> },
    PolicySet {
        root: PathBuf,
        task_id: String,
        mergegate_name: String,
        required_approvals: Vec<String>,
        required_verifiers: Vec<String>,
    },
    ManagerNext { root: PathBuf, objective_id: String },
    ToolRun {
        root: PathBuf,
        task_id: String,
        actor: String,
        cwd: PathBuf,
        timeout_ms: Option<i64>,
        command: Vec<String>,
    },
    VerifierRun {
        root: PathBuf,
        task_id: String,
        actor: String,
        verifier_name: String,
        cwd: PathBuf,
        timeout_ms: Option<i64>,
        command: Vec<String>,
    },
    MergegateDecide {
        root: PathBuf,
        task_id: String,
        actor: String,
        mergegate_name: String,
        verifier_names: Vec<String>,
    },
}

fn swarm_usage(program: &str) -> ! {
    eprintln!(
        "usage: {program} [--json] swarm <start|bootstrap|lease|release|heartbeat|complete|fail|retry|stop|resume|status|history|tasks|summary|tail|runs|artifacts|memory put|memory query|objective create|objective status|objectives|task create|ready|approve|approvals|policy set|manager next|tool|verifier run|mergegate decide> ..."
    );
    std::process::exit(2);
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

fn default_actor() -> String {
    env::var("CLASP_SWARM_ACTOR").unwrap_or_else(|_| "manager".to_owned())
}

fn normalized_swarm_args(args: &[String]) -> (bool, Vec<String>) {
    let mut json = false;
    let mut filtered = Vec::new();
    for arg in args {
        if arg == "--json" {
            json = true;
        } else {
            filtered.push(arg.clone());
        }
    }
    (json, filtered)
}

fn parse_root_arg(value: &str) -> PathBuf {
    PathBuf::from(value)
}

fn split_command_args(args: &[String]) -> Result<(Vec<String>, Vec<String>), String> {
    let Some(separator_index) = args.iter().position(|arg| arg == "--") else {
        return Err("expected `--` before the command to execute".to_owned());
    };
    let before = args[..separator_index].to_vec();
    let after = args[separator_index + 1..].to_vec();
    if after.is_empty() {
        return Err("expected a command to execute after `--`".to_owned());
    }
    Ok((before, after))
}

fn parse_timeout_ms(value: &str) -> Result<i64, String> {
    let parsed = value
        .parse::<i64>()
        .map_err(|_| format!("invalid --timeout-ms value `{value}`"))?;
    if parsed <= 0 {
        return Err("--timeout-ms must be greater than 0".to_owned());
    }
    Ok(parsed)
}

fn parse_named_run_prefix(prefix: &[String], verb: &str) -> Result<(PathBuf, String, String, PathBuf, Option<i64>), String> {
    if prefix.len() < 2 {
        return Err(format!("usage: claspc swarm {verb} <state-root> <task-id> [--actor NAME] [--cwd DIR] [--timeout-ms MS] -- <command...>"));
    }
    let root = parse_root_arg(&prefix[0]);
    let task_id = prefix[1].clone();
    let mut actor = default_actor();
    let mut cwd = env::current_dir().map_err(|err| format!("failed to resolve current directory: {err}"))?;
    let mut timeout_ms = None;
    let mut index = 2usize;
    while index < prefix.len() {
        match prefix[index].as_str() {
            "--actor" => {
                let Some(value) = prefix.get(index + 1) else {
                    return Err("missing value after --actor".to_owned());
                };
                actor = value.clone();
                index += 2;
            }
            "--cwd" => {
                let Some(value) = prefix.get(index + 1) else {
                    return Err("missing value after --cwd".to_owned());
                };
                cwd = PathBuf::from(value);
                index += 2;
            }
            "--timeout-ms" => {
                let Some(value) = prefix.get(index + 1) else {
                    return Err("missing value after --timeout-ms".to_owned());
                };
                timeout_ms = Some(parse_timeout_ms(value)?);
                index += 2;
            }
            other => {
                return Err(format!("unknown option `{other}`"));
            }
        }
    }
    Ok((root, task_id, actor, cwd, timeout_ms))
}

fn parse_swarm_command(args: &[String]) -> Result<Option<(bool, SwarmCommand)>, String> {
    let (json, filtered) = normalized_swarm_args(args);
    if filtered.get(1).map(|value| value.as_str()) != Some("swarm") {
        return Ok(None);
    }
    let Some(verb) = filtered.get(2).map(|value| value.as_str()) else {
        return Err("missing swarm subcommand".to_owned());
    };
    let rest = &filtered[3..];
    let command = match verb {
        "start" | "bootstrap" => {
            let Some(root) = rest.first() else {
                return Err(format!("usage: claspc swarm {verb} <state-root> [task-id]"));
            };
            let task_id = rest.get(1).cloned().unwrap_or_else(|| "bootstrap".to_owned());
            let actor = default_actor();
            if verb == "start" {
                SwarmCommand::Start {
                    root: parse_root_arg(root),
                    task_id,
                    actor,
                    detail: None,
                }
            } else {
                SwarmCommand::Bootstrap {
                    root: parse_root_arg(root),
                    task_id,
                    actor,
                    detail: None,
                }
            }
        }
        "lease" | "release" | "heartbeat" | "complete" | "fail" | "retry" | "stop" | "resume" => {
            if rest.len() < 2 {
                return Err(format!("usage: claspc swarm {verb} <state-root> <task-id>"));
            }
            let root = parse_root_arg(&rest[0]);
            let task_id = rest[1].clone();
            let actor = default_actor();
            match verb {
                "lease" => SwarmCommand::Lease { root, task_id, actor, detail: None },
                "release" => SwarmCommand::Release { root, task_id, actor, detail: None },
                "heartbeat" => SwarmCommand::Heartbeat { root, task_id, actor, detail: None },
                "complete" => SwarmCommand::Complete { root, task_id, actor, detail: None },
                "fail" => SwarmCommand::Fail { root, task_id, actor, detail: None },
                "retry" => SwarmCommand::Retry { root, task_id, actor, detail: None },
                "stop" => SwarmCommand::Stop { root, task_id, actor, detail: None },
                "resume" => SwarmCommand::Resume { root, task_id, actor, detail: None },
                _ => unreachable!(),
            }
        }
        "status" => {
            if rest.len() != 2 {
                return Err("usage: claspc swarm status <state-root> <task-id>".to_owned());
            }
            SwarmCommand::Status {
                root: parse_root_arg(&rest[0]),
                task_id: rest[1].clone(),
            }
        }
        "history" => {
            if rest.len() != 2 {
                return Err("usage: claspc swarm history <state-root> <task-id>".to_owned());
            }
            SwarmCommand::History {
                root: parse_root_arg(&rest[0]),
                task_id: rest[1].clone(),
            }
        }
        "tasks" => {
            if rest.len() != 1 {
                return Err("usage: claspc swarm tasks <state-root>".to_owned());
            }
            SwarmCommand::Tasks { root: parse_root_arg(&rest[0]) }
        }
        "summary" => {
            if rest.len() != 1 {
                return Err("usage: claspc swarm summary <state-root>".to_owned());
            }
            SwarmCommand::Summary { root: parse_root_arg(&rest[0]) }
        }
        "tail" => {
            if rest.is_empty() {
                return Err("usage: claspc swarm tail <state-root> [task-id] [--limit N]".to_owned());
            }
            let root = parse_root_arg(&rest[0]);
            let mut task_id = None;
            let mut limit = 20usize;
            let mut index = 1usize;
            if let Some(value) = rest.get(index) {
                if value != "--limit" {
                    task_id = Some(value.clone());
                    index += 1;
                }
            }
            while index < rest.len() {
                match rest[index].as_str() {
                    "--limit" => {
                        let Some(value) = rest.get(index + 1) else {
                            return Err("missing value after --limit".to_owned());
                        };
                        limit = value
                            .parse::<usize>()
                            .map_err(|_| format!("invalid --limit value `{value}`"))?;
                        index += 2;
                    }
                    other => return Err(format!("unknown option `{other}`")),
                }
            }
            SwarmCommand::Tail { root, task_id, limit }
        }
        "runs" => {
            if rest.is_empty() || rest.len() > 2 {
                return Err("usage: claspc swarm runs <state-root> [task-id]".to_owned());
            }
            SwarmCommand::Runs {
                root: parse_root_arg(&rest[0]),
                task_id: rest.get(1).cloned(),
            }
        }
        "artifacts" => {
            if rest.is_empty() || rest.len() > 2 {
                return Err("usage: claspc swarm artifacts <state-root> [task-id]".to_owned());
            }
            SwarmCommand::Artifacts {
                root: parse_root_arg(&rest[0]),
                task_id: rest.get(1).cloned(),
            }
        }
        "memory" => {
            let Some(action) = rest.first().map(|value| value.as_str()) else {
                return Err("usage: claspc swarm memory <put|query> ...".to_owned());
            };
            match action {
                "put" => {
                    if rest.len() < 4 {
                        return Err(
                            "usage: claspc swarm memory put <state-root> <key> <value> [--objective ID] [--task ID] [--actor NAME]"
                                .to_owned(),
                        );
                    }
                    let root = parse_root_arg(&rest[1]);
                    let key = rest[2].clone();
                    let value = rest[3].clone();
                    let mut objective_id = String::new();
                    let mut task_id = String::new();
                    let mut actor = default_actor();
                    let mut index = 4usize;
                    while index < rest.len() {
                        match rest[index].as_str() {
                            "--objective" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --objective".to_owned());
                                };
                                objective_id = value.clone();
                                index += 2;
                            }
                            "--task" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --task".to_owned());
                                };
                                task_id = value.clone();
                                index += 2;
                            }
                            "--actor" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --actor".to_owned());
                                };
                                actor = value.clone();
                                index += 2;
                            }
                            other => return Err(format!("unknown option `{other}`")),
                        }
                    }
                    SwarmCommand::MemoryPut {
                        root,
                        objective_id,
                        task_id,
                        actor,
                        key,
                        value,
                    }
                }
                "query" => {
                    if rest.len() < 2 {
                        return Err(
                            "usage: claspc swarm memory query <state-root> [--objective ID] [--task ID] [--key KEY] [--limit N]"
                                .to_owned(),
                        );
                    }
                    let root = parse_root_arg(&rest[1]);
                    let mut objective_id = None;
                    let mut task_id = None;
                    let mut key = None;
                    let mut limit = 50usize;
                    let mut index = 2usize;
                    while index < rest.len() {
                        match rest[index].as_str() {
                            "--objective" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --objective".to_owned());
                                };
                                objective_id = Some(value.clone());
                                index += 2;
                            }
                            "--task" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --task".to_owned());
                                };
                                task_id = Some(value.clone());
                                index += 2;
                            }
                            "--key" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --key".to_owned());
                                };
                                key = Some(value.clone());
                                index += 2;
                            }
                            "--limit" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --limit".to_owned());
                                };
                                limit = value
                                    .parse::<usize>()
                                    .map_err(|_| format!("invalid --limit value `{value}`"))?
                                    .max(1);
                                index += 2;
                            }
                            other => return Err(format!("unknown option `{other}`")),
                        }
                    }
                    SwarmCommand::MemoryQuery {
                        root,
                        objective_id,
                        task_id,
                        key,
                        limit,
                    }
                }
                other => return Err(format!("unknown swarm memory command `{other}`")),
            }
        }
        "objective" => {
            let Some(action) = rest.first().map(|value| value.as_str()) else {
                return Err("usage: claspc swarm objective <create|status> ...".to_owned());
            };
            match action {
                "create" => {
                    if rest.len() < 3 {
                        return Err(
                            "usage: claspc swarm objective create <state-root> <objective-id> [--detail TEXT] [--max-tasks N] [--max-runs N] [--deadline-ms EPOCH_MS]"
                                .to_owned(),
                        );
                    }
                    let root = parse_root_arg(&rest[1]);
                    let objective_id = rest[2].clone();
                    let mut detail = format!("Objective {objective_id}");
                    let mut max_tasks = 0i64;
                    let mut max_runs = 0i64;
                    let mut deadline_at_ms = 0i64;
                    let mut index = 3usize;
                    while index < rest.len() {
                        match rest[index].as_str() {
                            "--detail" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --detail".to_owned());
                                };
                                detail = value.clone();
                                index += 2;
                            }
                            "--max-tasks" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --max-tasks".to_owned());
                                };
                                max_tasks = value
                                    .parse::<i64>()
                                    .map_err(|_| format!("invalid --max-tasks value `{value}`"))?;
                                index += 2;
                            }
                            "--max-runs" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --max-runs".to_owned());
                                };
                                max_runs = value
                                    .parse::<i64>()
                                    .map_err(|_| format!("invalid --max-runs value `{value}`"))?;
                                index += 2;
                            }
                            "--deadline-ms" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --deadline-ms".to_owned());
                                };
                                deadline_at_ms = value
                                    .parse::<i64>()
                                    .map_err(|_| format!("invalid --deadline-ms value `{value}`"))?;
                                index += 2;
                            }
                            other => return Err(format!("unknown option `{other}`")),
                        }
                    }
                    SwarmCommand::ObjectiveCreate {
                        root,
                        objective_id,
                        detail,
                        max_tasks,
                        max_runs,
                        deadline_at_ms,
                    }
                }
                "status" => {
                    if rest.len() != 3 {
                        return Err("usage: claspc swarm objective status <state-root> <objective-id>".to_owned());
                    }
                    SwarmCommand::ObjectiveStatus {
                        root: parse_root_arg(&rest[1]),
                        objective_id: rest[2].clone(),
                    }
                }
                other => return Err(format!("unknown swarm objective command `{other}`")),
            }
        }
        "objectives" => {
            if rest.len() != 1 {
                return Err("usage: claspc swarm objectives <state-root>".to_owned());
            }
            SwarmCommand::Objectives {
                root: parse_root_arg(&rest[0]),
            }
        }
        "task" => {
            let Some(action) = rest.first().map(|value| value.as_str()) else {
                return Err("usage: claspc swarm task create ...".to_owned());
            };
            match action {
                "create" => {
                    if rest.len() < 4 {
                        return Err(
                            "usage: claspc swarm task create <state-root> <objective-id> <task-id> [--detail TEXT] [--depends-on TASK]... [--max-runs N] [--deadline-ms EPOCH_MS] [--lease-timeout-ms N]"
                                .to_owned(),
                        );
                    }
                    let root = parse_root_arg(&rest[1]);
                    let objective_id = rest[2].clone();
                    let task_id = rest[3].clone();
                    let mut detail = format!("Task {task_id}");
                    let mut dependencies = Vec::new();
                    let mut max_runs = 0i64;
                    let mut deadline_at_ms = 0i64;
                    let mut lease_timeout_ms = DEFAULT_LEASE_TIMEOUT_MS;
                    let mut index = 4usize;
                    while index < rest.len() {
                        match rest[index].as_str() {
                            "--detail" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --detail".to_owned());
                                };
                                detail = value.clone();
                                index += 2;
                            }
                            "--depends-on" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --depends-on".to_owned());
                                };
                                dependencies.push(value.clone());
                                index += 2;
                            }
                            "--max-runs" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --max-runs".to_owned());
                                };
                                max_runs = value
                                    .parse::<i64>()
                                    .map_err(|_| format!("invalid --max-runs value `{value}`"))?;
                                index += 2;
                            }
                            "--deadline-ms" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --deadline-ms".to_owned());
                                };
                                deadline_at_ms = value
                                    .parse::<i64>()
                                    .map_err(|_| format!("invalid --deadline-ms value `{value}`"))?;
                                index += 2;
                            }
                            "--lease-timeout-ms" => {
                                let Some(value) = rest.get(index + 1) else {
                                    return Err("missing value after --lease-timeout-ms".to_owned());
                                };
                                lease_timeout_ms = value
                                    .parse::<i64>()
                                    .map_err(|_| format!("invalid --lease-timeout-ms value `{value}`"))?;
                                index += 2;
                            }
                            other => return Err(format!("unknown option `{other}`")),
                        }
                    }
                    SwarmCommand::TaskCreate {
                        root,
                        objective_id,
                        task_id,
                        detail,
                        dependencies,
                        max_runs,
                        deadline_at_ms,
                        lease_timeout_ms,
                    }
                }
                other => return Err(format!("unknown swarm task command `{other}`")),
            }
        }
        "ready" => {
            if rest.is_empty() || rest.len() > 2 {
                return Err("usage: claspc swarm ready <state-root> [objective-id]".to_owned());
            }
            SwarmCommand::Ready {
                root: parse_root_arg(&rest[0]),
                objective_id: rest.get(1).cloned(),
            }
        }
        "approve" => {
            if rest.len() < 3 {
                return Err("usage: claspc swarm approve <state-root> <task-id> <approval-name>".to_owned());
            }
            let root = parse_root_arg(&rest[0]);
            let task_id = rest[1].clone();
            let approval_name = rest[2].clone();
            let actor = default_actor();
            SwarmCommand::Approve { root, task_id, actor, approval_name, detail: None }
        }
        "approvals" => {
            if rest.is_empty() || rest.len() > 2 {
                return Err("usage: claspc swarm approvals <state-root> [task-id]".to_owned());
            }
            SwarmCommand::Approvals {
                root: parse_root_arg(&rest[0]),
                task_id: rest.get(1).cloned(),
            }
        }
        "policy" => {
            if rest.first().map(|value| value.as_str()) != Some("set") {
                return Err(
                    "usage: claspc swarm policy set <state-root> <task-id> <mergegate-name> [--require-approval NAME]... [--require-verifier NAME]..."
                        .to_owned(),
                );
            }
            if rest.len() < 4 {
                return Err(
                    "usage: claspc swarm policy set <state-root> <task-id> <mergegate-name> [--require-approval NAME]... [--require-verifier NAME]..."
                        .to_owned(),
                );
            }
            let root = parse_root_arg(&rest[1]);
            let task_id = rest[2].clone();
            let mergegate_name = rest[3].clone();
            let mut required_approvals = Vec::new();
            let mut required_verifiers = Vec::new();
            let mut index = 4usize;
            while index < rest.len() {
                match rest[index].as_str() {
                    "--require-approval" => {
                        let Some(value) = rest.get(index + 1) else {
                            return Err("missing value after --require-approval".to_owned());
                        };
                        required_approvals.push(value.clone());
                        index += 2;
                    }
                    "--require-verifier" => {
                        let Some(value) = rest.get(index + 1) else {
                            return Err("missing value after --require-verifier".to_owned());
                        };
                        required_verifiers.push(value.clone());
                        index += 2;
                    }
                    other => return Err(format!("unknown option `{other}`")),
                }
            }
            SwarmCommand::PolicySet {
                root,
                task_id,
                mergegate_name,
                required_approvals,
                required_verifiers,
            }
        }
        "manager" => {
            if rest.first().map(|value| value.as_str()) != Some("next") || rest.len() != 3 {
                return Err("usage: claspc swarm manager next <state-root> <objective-id>".to_owned());
            }
            SwarmCommand::ManagerNext {
                root: parse_root_arg(&rest[1]),
                objective_id: rest[2].clone(),
            }
        }
        "tool" => {
            let (prefix, command) = split_command_args(rest)?;
            let (root, task_id, actor, cwd, timeout_ms) = parse_named_run_prefix(&prefix, "tool")?;
            SwarmCommand::ToolRun { root, task_id, actor, cwd, timeout_ms, command }
        }
        "verifier" => {
            if rest.first().map(|value| value.as_str()) != Some("run") {
                return Err("usage: claspc swarm verifier run <state-root> <task-id> <verifier-name> [--actor NAME] [--cwd DIR] [--timeout-ms MS] -- <command...>".to_owned());
            }
            let (prefix, command) = split_command_args(&rest[1..])?;
            if prefix.len() < 3 {
                return Err("usage: claspc swarm verifier run <state-root> <task-id> <verifier-name> [--actor NAME] [--cwd DIR] [--timeout-ms MS] -- <command...>".to_owned());
            }
            let root = parse_root_arg(&prefix[0]);
            let task_id = prefix[1].clone();
            let verifier_name = prefix[2].clone();
            let mut actor = default_actor();
            let mut cwd = env::current_dir().map_err(|err| format!("failed to resolve current directory: {err}"))?;
            let mut timeout_ms = None;
            let mut index = 3usize;
            while index < prefix.len() {
                match prefix[index].as_str() {
                    "--actor" => {
                        let Some(value) = prefix.get(index + 1) else {
                            return Err("missing value after --actor".to_owned());
                        };
                        actor = value.clone();
                        index += 2;
                    }
                    "--cwd" => {
                        let Some(value) = prefix.get(index + 1) else {
                            return Err("missing value after --cwd".to_owned());
                        };
                        cwd = PathBuf::from(value);
                        index += 2;
                    }
                    "--timeout-ms" => {
                        let Some(value) = prefix.get(index + 1) else {
                            return Err("missing value after --timeout-ms".to_owned());
                        };
                        timeout_ms = Some(parse_timeout_ms(value)?);
                        index += 2;
                    }
                    other => return Err(format!("unknown option `{other}`")),
                }
            }
            SwarmCommand::VerifierRun { root, task_id, actor, verifier_name, cwd, timeout_ms, command }
        }
        "mergegate" => {
            if rest.first().map(|value| value.as_str()) != Some("decide") {
                return Err("usage: claspc swarm mergegate decide <state-root> <task-id> <mergegate-name> <verifier-name>...".to_owned());
            }
            if rest.len() < 5 {
                return Err("usage: claspc swarm mergegate decide <state-root> <task-id> <mergegate-name> <verifier-name>...".to_owned());
            }
            SwarmCommand::MergegateDecide {
                root: parse_root_arg(&rest[1]),
                task_id: rest[2].clone(),
                actor: default_actor(),
                mergegate_name: rest[3].clone(),
                verifier_names: rest[4..].to_vec(),
            }
        }
        _ => return Err(format!("unknown swarm subcommand `{verb}`")),
    };
    Ok(Some((json, command)))
}

fn runtime_paths(root: &Path) -> SwarmRuntimePaths {
    let db_path = if root.extension().and_then(|value| value.to_str()) == Some("db") {
        root.to_path_buf()
    } else {
        root.join("swarm.db")
    };
    let root_dir = if db_path == root {
        root.parent().unwrap_or_else(|| Path::new(".")).to_path_buf()
    } else {
        root.to_path_buf()
    };
    SwarmRuntimePaths {
        root: root_dir.clone(),
        db_path,
        artifacts_dir: root_dir.join("artifacts"),
    }
}

fn open_swarm_connection(root: &Path) -> Result<(SwarmRuntimePaths, Connection), String> {
    let paths = runtime_paths(root);
    fs::create_dir_all(&paths.root)
        .map_err(|err| format!("failed to create swarm state directory `{}`: {err}", paths.root.display()))?;
    fs::create_dir_all(&paths.artifacts_dir).map_err(|err| {
        format!(
            "failed to create swarm artifact directory `{}`: {err}",
            paths.artifacts_dir.display()
        )
    })?;
    let connection = Connection::open(&paths.db_path)
        .map_err(|err| format!("failed to open swarm database `{}`: {err}", paths.db_path.display()))?;
    connection
        .execute_batch(
            "
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS swarm_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              kind TEXT NOT NULL,
              task_id TEXT NOT NULL,
              actor TEXT NOT NULL,
              detail TEXT NOT NULL,
              at_ms INTEGER NOT NULL,
              payload_json TEXT NOT NULL DEFAULT '{}'
            );
            CREATE INDEX IF NOT EXISTS swarm_events_task_idx ON swarm_events(task_id, id);
            CREATE TABLE IF NOT EXISTS swarm_tasks (
              task_id TEXT PRIMARY KEY,
              status TEXT NOT NULL,
              lease_actor TEXT NOT NULL,
              last_heartbeat_at_ms INTEGER NOT NULL,
              heartbeat_seen INTEGER NOT NULL,
              attempts INTEGER NOT NULL,
              last_error TEXT NOT NULL,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS swarm_artifacts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              path TEXT NOT NULL,
              created_at_ms INTEGER NOT NULL,
              metadata_json TEXT NOT NULL DEFAULT '{}'
            );
            CREATE INDEX IF NOT EXISTS swarm_artifacts_task_idx ON swarm_artifacts(task_id, id);
            CREATE TABLE IF NOT EXISTS swarm_memory (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              objective_id TEXT NOT NULL DEFAULT '',
              task_id TEXT NOT NULL DEFAULT '',
              key TEXT NOT NULL,
              value TEXT NOT NULL,
              actor TEXT NOT NULL,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL,
              payload_json TEXT NOT NULL DEFAULT '{}'
            );
            CREATE INDEX IF NOT EXISTS swarm_memory_objective_idx ON swarm_memory(objective_id, id);
            CREATE INDEX IF NOT EXISTS swarm_memory_task_idx ON swarm_memory(task_id, id);
            CREATE INDEX IF NOT EXISTS swarm_memory_key_idx ON swarm_memory(key, id);
            CREATE TABLE IF NOT EXISTS swarm_approvals (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id TEXT NOT NULL,
              name TEXT NOT NULL,
              actor TEXT NOT NULL,
              detail TEXT NOT NULL,
              at_ms INTEGER NOT NULL,
              payload_json TEXT NOT NULL DEFAULT '{}'
            );
            CREATE INDEX IF NOT EXISTS swarm_approvals_task_idx ON swarm_approvals(task_id, id);
            CREATE TABLE IF NOT EXISTS swarm_runs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              task_id TEXT NOT NULL,
              role TEXT NOT NULL,
              actor TEXT NOT NULL,
              name TEXT NOT NULL,
              cwd TEXT NOT NULL,
              command_json TEXT NOT NULL,
              exit_code INTEGER,
              status TEXT NOT NULL,
              started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER,
              stdout_artifact_id INTEGER,
              stderr_artifact_id INTEGER
            );
            CREATE INDEX IF NOT EXISTS swarm_runs_task_role_idx ON swarm_runs(task_id, role, name, id);
            CREATE TABLE IF NOT EXISTS swarm_objectives (
              objective_id TEXT PRIMARY KEY,
              detail TEXT NOT NULL,
              status TEXT NOT NULL,
              max_tasks INTEGER NOT NULL,
              max_runs INTEGER NOT NULL,
              deadline_at_ms INTEGER NOT NULL,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS swarm_task_specs (
              task_id TEXT PRIMARY KEY,
              objective_id TEXT NOT NULL,
              detail TEXT NOT NULL,
              max_runs INTEGER NOT NULL,
              deadline_at_ms INTEGER NOT NULL,
              lease_timeout_ms INTEGER NOT NULL,
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS swarm_task_specs_objective_idx ON swarm_task_specs(objective_id, task_id);
            CREATE TABLE IF NOT EXISTS swarm_task_deps (
              parent_task_id TEXT NOT NULL,
              child_task_id TEXT NOT NULL,
              PRIMARY KEY(parent_task_id, child_task_id)
            );
            CREATE INDEX IF NOT EXISTS swarm_task_deps_child_idx ON swarm_task_deps(child_task_id, parent_task_id);
            CREATE TABLE IF NOT EXISTS swarm_merge_policies (
              task_id TEXT PRIMARY KEY,
              mergegate_name TEXT NOT NULL,
              required_approvals_json TEXT NOT NULL DEFAULT '[]',
              required_verifiers_json TEXT NOT NULL DEFAULT '[]',
              created_at_ms INTEGER NOT NULL,
              updated_at_ms INTEGER NOT NULL
            );
            ",
        )
        .map_err(|err| format!("failed to initialize swarm database: {err}"))?;
    Ok((paths, connection))
}

fn empty_task_state(task_id: &str, at_ms: i64) -> SwarmTaskState {
    SwarmTaskState {
        task_id: task_id.to_owned(),
        status: "missing".to_owned(),
        lease_actor: String::new(),
        last_heartbeat_at_ms: 0,
        heartbeat_seen: false,
        attempts: 0,
        last_error: String::new(),
        created_at_ms: at_ms,
        updated_at_ms: at_ms,
    }
}

fn load_task_state(connection: &Connection, task_id: &str) -> Result<Option<SwarmTaskState>, String> {
    connection
        .query_row(
            "
            SELECT task_id, status, lease_actor, last_heartbeat_at_ms, heartbeat_seen, attempts, last_error, created_at_ms, updated_at_ms
            FROM swarm_tasks
            WHERE task_id = ?1
            ",
            params![task_id],
            |row| {
                Ok(SwarmTaskState {
                    task_id: row.get(0)?,
                    status: row.get(1)?,
                    lease_actor: row.get(2)?,
                    last_heartbeat_at_ms: row.get(3)?,
                    heartbeat_seen: row.get::<_, i64>(4)? != 0,
                    attempts: row.get(5)?,
                    last_error: row.get(6)?,
                    created_at_ms: row.get(7)?,
                    updated_at_ms: row.get(8)?,
                })
            },
        )
        .optional()
        .map_err(|err| format!("failed to load swarm task `{task_id}`: {err}"))
}

fn store_task_state(connection: &Connection, task: &SwarmTaskState) -> Result<(), String> {
    connection
        .execute(
            "
            INSERT INTO swarm_tasks (
              task_id, status, lease_actor, last_heartbeat_at_ms, heartbeat_seen, attempts, last_error, created_at_ms, updated_at_ms
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            ON CONFLICT(task_id) DO UPDATE SET
              status = excluded.status,
              lease_actor = excluded.lease_actor,
              last_heartbeat_at_ms = excluded.last_heartbeat_at_ms,
              heartbeat_seen = excluded.heartbeat_seen,
              attempts = excluded.attempts,
              last_error = excluded.last_error,
              created_at_ms = excluded.created_at_ms,
              updated_at_ms = excluded.updated_at_ms
            ",
            params![
                task.task_id,
                task.status,
                task.lease_actor,
                task.last_heartbeat_at_ms,
                if task.heartbeat_seen { 1 } else { 0 },
                task.attempts,
                task.last_error,
                task.created_at_ms,
                task.updated_at_ms
            ],
        )
        .map_err(|err| format!("failed to store swarm task `{}`: {err}", task.task_id))?;
    Ok(())
}

fn load_objective(connection: &Connection, objective_id: &str) -> Result<Option<SwarmObjectiveRecord>, String> {
    connection
        .query_row(
            "
            SELECT objective_id, detail, status, max_tasks, max_runs, deadline_at_ms, created_at_ms, updated_at_ms
            FROM swarm_objectives
            WHERE objective_id = ?1
            ",
            params![objective_id],
            |row| {
                Ok(SwarmObjectiveRecord {
                    objective_id: row.get(0)?,
                    detail: row.get(1)?,
                    status: row.get(2)?,
                    max_tasks: row.get(3)?,
                    max_runs: row.get(4)?,
                    deadline_at_ms: row.get(5)?,
                    created_at_ms: row.get(6)?,
                    updated_at_ms: row.get(7)?,
                })
            },
        )
        .optional()
        .map_err(|err| format!("failed to load swarm objective `{objective_id}`: {err}"))
}

fn insert_objective(
    connection: &Connection,
    objective_id: &str,
    detail: &str,
    max_tasks: i64,
    max_runs: i64,
    deadline_at_ms: i64,
) -> Result<SwarmObjectiveRecord, String> {
    let created_at_ms = now_ms();
    connection
        .execute(
            "
            INSERT INTO swarm_objectives (
              objective_id, detail, status, max_tasks, max_runs, deadline_at_ms, created_at_ms, updated_at_ms
            ) VALUES (?1, ?2, 'active', ?3, ?4, ?5, ?6, ?6)
            ",
            params![objective_id, detail, max_tasks, max_runs, deadline_at_ms, created_at_ms],
        )
        .map_err(|err| format!("failed to create swarm objective `{objective_id}`: {err}"))?;
    Ok(SwarmObjectiveRecord {
        objective_id: objective_id.to_owned(),
        detail: detail.to_owned(),
        status: "active".to_owned(),
        max_tasks,
        max_runs,
        deadline_at_ms,
        created_at_ms,
        updated_at_ms: created_at_ms,
    })
}

fn widened_limit(existing: i64, requested: i64) -> i64 {
    if existing <= 0 || requested <= 0 {
        existing
    } else {
        existing.max(requested)
    }
}

fn ensure_objective(
    connection: &Connection,
    objective_id: &str,
    detail: &str,
    max_tasks: i64,
    max_runs: i64,
    deadline_at_ms: i64,
) -> Result<SwarmObjectiveRecord, String> {
    let Some(existing) = load_objective(connection, objective_id)? else {
        return insert_objective(connection, objective_id, detail, max_tasks, max_runs, deadline_at_ms);
    };
    let next_detail = if detail.is_empty() {
        existing.detail.clone()
    } else {
        detail.to_owned()
    };
    let next_max_tasks = widened_limit(existing.max_tasks, max_tasks);
    let next_max_runs = widened_limit(existing.max_runs, max_runs);
    let next_deadline_at_ms = widened_limit(existing.deadline_at_ms, deadline_at_ms);
    if next_detail == existing.detail
        && next_max_tasks == existing.max_tasks
        && next_max_runs == existing.max_runs
        && next_deadline_at_ms == existing.deadline_at_ms
    {
        return Ok(existing);
    }
    let updated_at_ms = now_ms();
    connection
        .execute(
            "
            UPDATE swarm_objectives
            SET detail = ?2,
                max_tasks = ?3,
                max_runs = ?4,
                deadline_at_ms = ?5,
                updated_at_ms = ?6
            WHERE objective_id = ?1
            ",
            params![
                objective_id,
                next_detail,
                next_max_tasks,
                next_max_runs,
                next_deadline_at_ms,
                updated_at_ms
            ],
        )
        .map_err(|err| format!("failed to update swarm objective `{objective_id}`: {err}"))?;
    Ok(SwarmObjectiveRecord {
        objective_id: existing.objective_id,
        detail: next_detail,
        status: existing.status,
        max_tasks: next_max_tasks,
        max_runs: next_max_runs,
        deadline_at_ms: next_deadline_at_ms,
        created_at_ms: existing.created_at_ms,
        updated_at_ms,
    })
}

fn load_task_spec(connection: &Connection, task_id: &str) -> Result<Option<SwarmTaskSpecRecord>, String> {
    connection
        .query_row(
            "
            SELECT task_id, objective_id, detail, max_runs, deadline_at_ms, lease_timeout_ms, created_at_ms, updated_at_ms
            FROM swarm_task_specs
            WHERE task_id = ?1
            ",
            params![task_id],
            |row| {
                Ok(SwarmTaskSpecRecord {
                    task_id: row.get(0)?,
                    objective_id: row.get(1)?,
                    detail: row.get(2)?,
                    max_runs: row.get(3)?,
                    deadline_at_ms: row.get(4)?,
                    lease_timeout_ms: row.get(5)?,
                    created_at_ms: row.get(6)?,
                    updated_at_ms: row.get(7)?,
                })
            },
        )
        .optional()
        .map_err(|err| format!("failed to load swarm task spec `{task_id}`: {err}"))
}

fn load_merge_policy(connection: &Connection, task_id: &str) -> Result<Option<SwarmMergePolicyRecord>, String> {
    connection
        .query_row(
            "
            SELECT task_id, mergegate_name, required_approvals_json, required_verifiers_json, created_at_ms, updated_at_ms
            FROM swarm_merge_policies
            WHERE task_id = ?1
            ",
            params![task_id],
            |row| {
                Ok(SwarmMergePolicyRecord {
                    task_id: row.get(0)?,
                    mergegate_name: row.get(1)?,
                    required_approvals_json: row.get(2)?,
                    required_verifiers_json: row.get(3)?,
                    created_at_ms: row.get(4)?,
                    updated_at_ms: row.get(5)?,
                })
            },
        )
        .optional()
        .map_err(|err| format!("failed to load swarm merge policy for `{task_id}`: {err}"))
}

fn store_merge_policy(
    connection: &Connection,
    task_id: &str,
    mergegate_name: &str,
    required_approvals: &[String],
    required_verifiers: &[String],
) -> Result<SwarmMergePolicyRecord, String> {
    if load_task_state(connection, task_id)?.is_none() {
        return Err(format!("unknown swarm task `{task_id}`"));
    }
    let created_at_ms = load_merge_policy(connection, task_id)?
        .map(|value| value.created_at_ms)
        .unwrap_or_else(now_ms);
    let updated_at_ms = now_ms();
    let required_approvals_json =
        serde_json::to_string(required_approvals).map_err(|err| format!("failed to encode required approvals: {err}"))?;
    let required_verifiers_json =
        serde_json::to_string(required_verifiers).map_err(|err| format!("failed to encode required verifiers: {err}"))?;
    connection
        .execute(
            "
            INSERT INTO swarm_merge_policies (
              task_id, mergegate_name, required_approvals_json, required_verifiers_json, created_at_ms, updated_at_ms
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(task_id) DO UPDATE SET
              mergegate_name = excluded.mergegate_name,
              required_approvals_json = excluded.required_approvals_json,
              required_verifiers_json = excluded.required_verifiers_json,
              updated_at_ms = excluded.updated_at_ms
            ",
            params![
                task_id,
                mergegate_name,
                required_approvals_json,
                required_verifiers_json,
                created_at_ms,
                updated_at_ms
            ],
        )
        .map_err(|err| format!("failed to store swarm merge policy for `{task_id}`: {err}"))?;
    Ok(SwarmMergePolicyRecord {
        task_id: task_id.to_owned(),
        mergegate_name: mergegate_name.to_owned(),
        required_approvals_json,
        required_verifiers_json,
        created_at_ms,
        updated_at_ms,
    })
}

fn task_dependency_ids(connection: &Connection, task_id: &str) -> Result<Vec<String>, String> {
    let mut statement = connection
        .prepare(
            "
            SELECT parent_task_id
            FROM swarm_task_deps
            WHERE child_task_id = ?1
            ORDER BY parent_task_id ASC
            ",
        )
        .map_err(|err| format!("failed to prepare swarm dependency query: {err}"))?;
    let rows = statement
        .query_map(params![task_id], |row| row.get::<_, String>(0))
        .map_err(|err| format!("failed to query swarm dependencies: {err}"))?;
    let mut values = Vec::new();
    for row in rows {
        values.push(row.map_err(|err| format!("failed to read swarm dependency row: {err}"))?);
    }
    Ok(values)
}

fn objective_task_count(connection: &Connection, objective_id: &str) -> Result<i64, String> {
    connection
        .query_row(
            "SELECT COUNT(*) FROM swarm_task_specs WHERE objective_id = ?1",
            params![objective_id],
            |row| row.get(0),
        )
        .map_err(|err| format!("failed to count swarm tasks for objective `{objective_id}`: {err}"))
}

fn objective_run_count(connection: &Connection, objective_id: &str) -> Result<i64, String> {
    connection
        .query_row(
            "
            SELECT COUNT(*)
            FROM swarm_runs AS runs
            INNER JOIN swarm_task_specs AS specs ON specs.task_id = runs.task_id
            WHERE specs.objective_id = ?1
            ",
            params![objective_id],
            |row| row.get(0),
        )
        .map_err(|err| format!("failed to count swarm runs for objective `{objective_id}`: {err}"))
}

fn task_run_count(connection: &Connection, task_id: &str) -> Result<i64, String> {
    connection
        .query_row(
            "SELECT COUNT(*) FROM swarm_runs WHERE task_id = ?1",
            params![task_id],
            |row| row.get(0),
        )
        .map_err(|err| format!("failed to count swarm runs for task `{task_id}`: {err}"))
}

fn widen_retry_run_budget(connection: &Connection, task_id: &str, updated_at_ms: i64) -> Result<(), String> {
    let Some(spec) = load_task_spec(connection, task_id)? else {
        return Err(format!("unknown swarm task `{task_id}`"));
    };
    let run_count = task_run_count(connection, task_id)?;
    if spec.max_runs > 0 && run_count >= spec.max_runs {
        let next_max_runs = run_count + 1;
        connection
            .execute(
                "
                UPDATE swarm_task_specs
                SET max_runs = ?2,
                    updated_at_ms = ?3
                WHERE task_id = ?1
                ",
                params![task_id, next_max_runs, updated_at_ms],
            )
            .map_err(|err| format!("failed to widen retry run budget for swarm task `{task_id}`: {err}"))?;
    }
    if let Some(objective) = load_objective(connection, &spec.objective_id)? {
        let objective_runs = objective_run_count(connection, &objective.objective_id)?;
        if objective.max_runs > 0 && objective_runs >= objective.max_runs {
            let next_max_runs = objective_runs + 1;
            connection
                .execute(
                    "
                    UPDATE swarm_objectives
                    SET max_runs = ?2,
                        updated_at_ms = ?3
                    WHERE objective_id = ?1
                    ",
                    params![objective.objective_id, next_max_runs, updated_at_ms],
                )
                .map_err(|err| format!("failed to widen retry run budget for swarm objective `{}`: {err}", spec.objective_id))?;
        }
    }
    Ok(())
}

fn insert_task_spec(
    connection: &mut Connection,
    objective_id: &str,
    task_id: &str,
    detail: &str,
    dependencies: &[String],
    max_runs: i64,
    deadline_at_ms: i64,
    lease_timeout_ms: i64,
) -> Result<SwarmTaskSpecRecord, String> {
    let Some(objective) = load_objective(connection, objective_id)? else {
        return Err(format!("unknown swarm objective `{objective_id}`"));
    };
    if load_task_spec(connection, task_id)?.is_some() {
        return Err(format!("swarm task `{task_id}` already exists"));
    }
    if objective.max_tasks > 0 && objective_task_count(connection, objective_id)? >= objective.max_tasks {
        return Err(format!("objective `{objective_id}` exhausted its max task budget"));
    }
    let created_at_ms = now_ms();
    let lease_timeout_ms = if lease_timeout_ms <= 0 {
        DEFAULT_LEASE_TIMEOUT_MS
    } else {
        lease_timeout_ms
    };
    let transaction = connection
        .transaction()
        .map_err(|err| format!("failed to start swarm task spec transaction: {err}"))?;
    transaction
        .execute(
            "
            INSERT INTO swarm_task_specs (
              task_id, objective_id, detail, max_runs, deadline_at_ms, lease_timeout_ms, created_at_ms, updated_at_ms
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
            ",
            params![task_id, objective_id, detail, max_runs, deadline_at_ms, lease_timeout_ms, created_at_ms],
        )
        .map_err(|err| format!("failed to create swarm task spec `{task_id}`: {err}"))?;
    for dependency in dependencies {
        transaction
            .execute(
                "
                INSERT INTO swarm_task_deps (parent_task_id, child_task_id)
                VALUES (?1, ?2)
                ",
                params![dependency, task_id],
            )
            .map_err(|err| format!("failed to record swarm task dependency `{dependency}` -> `{task_id}`: {err}"))?;
    }
    transaction
        .commit()
        .map_err(|err| format!("failed to commit swarm task spec `{task_id}`: {err}"))?;
    let _ = record_swarm_event(
        connection,
        "task_created",
        task_id,
        "manager",
        detail,
        json!({
            "objectiveId": objective_id,
            "dependencies": dependencies,
            "maxRuns": max_runs,
            "deadlineAtMs": deadline_at_ms,
            "leaseTimeoutMs": lease_timeout_ms
        }),
    )?;
    Ok(SwarmTaskSpecRecord {
        task_id: task_id.to_owned(),
        objective_id: objective_id.to_owned(),
        detail: detail.to_owned(),
        max_runs,
        deadline_at_ms,
        lease_timeout_ms,
        created_at_ms,
        updated_at_ms: created_at_ms,
    })
}

fn apply_event(task: &mut SwarmTaskState, event: &SwarmEvent) {
    task.updated_at_ms = event.at_ms;
    match event.kind.as_str() {
        "task_created" => {
            task.status = "created".to_owned();
            if task.created_at_ms == 0 {
                task.created_at_ms = event.at_ms;
            }
        }
        "lease_acquired" => {
            task.status = "leased".to_owned();
            task.lease_actor = event.actor.clone();
            task.attempts += 1;
        }
        "lease_released" => {
            task.status = "queued".to_owned();
            task.lease_actor.clear();
            task.last_heartbeat_at_ms = 0;
            task.heartbeat_seen = false;
        }
        "worker_heartbeat" => {
            task.status = "active".to_owned();
            task.lease_actor = event.actor.clone();
            task.last_heartbeat_at_ms = event.at_ms;
            task.heartbeat_seen = true;
        }
        "task_completed" => {
            task.status = "completed".to_owned();
            task.last_error.clear();
        }
        "task_failed" => {
            task.status = "failed".to_owned();
            task.last_error = event.detail.clone();
        }
        "task_requeued" => {
            task.status = "queued".to_owned();
            task.lease_actor.clear();
            task.last_heartbeat_at_ms = 0;
            task.heartbeat_seen = false;
        }
        "task_stopped" => {
            task.status = "stopped".to_owned();
            task.lease_actor.clear();
            task.last_heartbeat_at_ms = 0;
            task.heartbeat_seen = false;
        }
        "task_resumed" => {
            task.status = "queued".to_owned();
            task.lease_actor.clear();
            task.last_heartbeat_at_ms = 0;
            task.heartbeat_seen = false;
        }
        _ => {}
    }
}

fn task_last_lease_activity_at_ms(task: &SwarmTaskState) -> i64 {
    if task.last_heartbeat_at_ms > 0 {
        task.last_heartbeat_at_ms
    } else {
        task.updated_at_ms
    }
}

fn lease_is_expired(task: &SwarmTaskState, spec: Option<&SwarmTaskSpecRecord>, at_ms: i64) -> bool {
    if task.status != "leased" && task.status != "active" {
        return false;
    }
    let timeout_ms = spec
        .map(|value| value.lease_timeout_ms)
        .unwrap_or(DEFAULT_LEASE_TIMEOUT_MS);
    if timeout_ms <= 0 {
        return true;
    }
    at_ms.saturating_sub(task_last_lease_activity_at_ms(task)) >= timeout_ms
}

fn lease_ownership_is_expired(task: &SwarmTaskState, spec: Option<&SwarmTaskSpecRecord>, at_ms: i64) -> bool {
    let timeout_ms = spec
        .map(|value| value.lease_timeout_ms)
        .unwrap_or(DEFAULT_LEASE_TIMEOUT_MS);
    if timeout_ms <= 0 {
        return true;
    }
    let activity_at_ms = if task.status == "leased" || task.status == "active" {
        task_last_lease_activity_at_ms(task)
    } else {
        task.updated_at_ms
    };
    at_ms.saturating_sub(activity_at_ms) >= timeout_ms
}

fn require_active_lease_owner(
    connection: &Connection,
    task_id: &str,
    actor: &str,
    action: &str,
    at_ms: i64,
) -> Result<(SwarmTaskState, Option<SwarmTaskSpecRecord>), String> {
    let Some(task) = load_task_state(connection, task_id)? else {
        return Err(format!("unknown swarm task `{task_id}`"));
    };
    let spec = load_task_spec(connection, task_id)?;
    if task.status != "leased" && task.status != "active" {
        return Err(format!(
            "swarm task `{task_id}` cannot {action}: no active lease is held"
        ));
    }
    if lease_is_expired(&task, spec.as_ref(), at_ms) {
        return Err(format!(
            "swarm task `{task_id}` cannot {action}: lease held by `{}` expired",
            task.lease_actor
        ));
    }
    if task.lease_actor.as_str() != actor {
        return Err(format!(
            "swarm task `{task_id}` cannot {action}: active lease is owned by `{}`",
            task.lease_actor
        ));
    }
    Ok((task, spec))
}

fn require_unexpired_lease_owner(
    connection: &Connection,
    task_id: &str,
    actor: &str,
    action: &str,
    at_ms: i64,
) -> Result<(SwarmTaskState, Option<SwarmTaskSpecRecord>), String> {
    let Some(task) = load_task_state(connection, task_id)? else {
        return Err(format!("unknown swarm task `{task_id}`"));
    };
    let spec = load_task_spec(connection, task_id)?;
    if task.lease_actor.is_empty() {
        return Err(format!(
            "swarm task `{task_id}` cannot {action}: no lease owner is recorded"
        ));
    }
    if task.status != "leased" && task.status != "active" && task.status != "completed" {
        return Err(format!(
            "swarm task `{task_id}` cannot {action}: lease ownership is not valid for status `{}`",
            task.status
        ));
    }
    if lease_ownership_is_expired(&task, spec.as_ref(), at_ms) {
        return Err(format!(
            "swarm task `{task_id}` cannot {action}: lease held by `{}` expired",
            task.lease_actor
        ));
    }
    if task.lease_actor.as_str() != actor {
        return Err(format!(
            "swarm task `{task_id}` cannot {action}: lease is owned by `{}`",
            task.lease_actor
        ));
    }
    Ok((task, spec))
}

fn require_completion_lease_owner(
    connection: &Connection,
    task_id: &str,
    actor: &str,
    _at_ms: i64,
) -> Result<(SwarmTaskState, Option<SwarmTaskSpecRecord>), String> {
    let Some(task) = load_task_state(connection, task_id)? else {
        return Err(format!("unknown swarm task `{task_id}`"));
    };
    let spec = load_task_spec(connection, task_id)?;
    if task.lease_actor.is_empty() {
        return Err(format!(
            "swarm task `{task_id}` cannot complete: no lease owner is recorded"
        ));
    }
    if task.status == "failed" && actor == "manager" && task.lease_actor.as_str() == actor {
        return Ok((task, spec));
    }
    if task.status != "leased" && task.status != "active" && task.status != "completed" {
        return Err(format!(
            "swarm task `{task_id}` cannot complete: lease ownership is not valid for status `{}`",
            task.status
        ));
    }
    if task.lease_actor.as_str() != actor {
        return Err(format!(
            "swarm task `{task_id}` cannot complete: lease is owned by `{}`",
            task.lease_actor
        ));
    }
    Ok((task, spec))
}

fn require_recorded_lease_owner(
    connection: &Connection,
    task_id: &str,
    actor: &str,
    action: &str,
) -> Result<SwarmTaskState, String> {
    let Some(task) = load_task_state(connection, task_id)? else {
        return Err(format!("unknown swarm task `{task_id}`"));
    };
    if task.lease_actor.is_empty() {
        return Err(format!(
            "swarm task `{task_id}` cannot {action}: no lease owner is recorded"
        ));
    }
    if task.lease_actor.as_str() != actor {
        return Err(format!(
            "swarm task `{task_id}` cannot {action}: lease is owned by `{}`",
            task.lease_actor
        ));
    }
    Ok(task)
}

fn require_manager_actor(
    connection: &Connection,
    task_id: &str,
    actor: &str,
    action: &str,
) -> Result<(), String> {
    if actor != "manager" {
        return Err(format!(
            "swarm task `{task_id}` cannot {action}: actor `{actor}` is not a swarm manager"
        ));
    }
    if load_task_state(connection, task_id)?.is_none() {
        return Err(format!("unknown swarm task `{task_id}`"));
    }
    Ok(())
}

fn unfinished_dependency_ids(connection: &Connection, task_id: &str) -> Result<Vec<String>, String> {
    let mut blocked = Vec::new();
    for dependency in task_dependency_ids(connection, task_id)? {
        match load_task_state(connection, &dependency)? {
            Some(task) if task.status == "completed" => {}
            _ => blocked.push(dependency),
        }
    }
    Ok(blocked)
}

fn deadline_expired(deadline_at_ms: i64, at_ms: i64) -> bool {
    deadline_at_ms > 0 && at_ms > deadline_at_ms
}

fn task_ready_state(
    connection: &Connection,
    task: &SwarmTaskState,
    at_ms: i64,
) -> Result<(bool, bool, Vec<String>, Option<SwarmTaskSpecRecord>, Option<SwarmObjectiveRecord>), String> {
    let spec = load_task_spec(connection, &task.task_id)?;
    let objective = if let Some(spec_value) = spec.as_ref() {
        load_objective(connection, &spec_value.objective_id)?
    } else {
        None
    };
    let mut blocked = Vec::new();
    if task.status == "missing" {
        blocked.push("task is missing".to_owned());
    }
    if task.status == "completed" || task.status == "failed" || task.status == "stopped" {
        blocked.push(format!("task status is `{}`", task.status));
    }
    let lease_expired = lease_is_expired(task, spec.as_ref(), at_ms);
    if (task.status == "leased" || task.status == "active") && !lease_expired {
        blocked.push(format!("lease held by `{}`", task.lease_actor));
    }
    if let Some(spec_value) = spec.as_ref() {
        if deadline_expired(spec_value.deadline_at_ms, at_ms) {
            blocked.push("task deadline expired".to_owned());
        }
        if spec_value.max_runs > 0 && task_run_count(connection, &task.task_id)? >= spec_value.max_runs {
            blocked.push("task run budget exhausted".to_owned());
        }
        let dependencies = unfinished_dependency_ids(connection, &task.task_id)?;
        if !dependencies.is_empty() {
            blocked.push(format!("waiting on {}", dependencies.join(",")));
        }
    }
    if let Some(objective_value) = objective.as_ref() {
        if deadline_expired(objective_value.deadline_at_ms, at_ms) {
            blocked.push("objective deadline expired".to_owned());
        }
        if objective_value.max_runs > 0 && objective_run_count(connection, &objective_value.objective_id)? >= objective_value.max_runs {
            blocked.push("objective run budget exhausted".to_owned());
        }
    }
    Ok((blocked.is_empty(), lease_expired, blocked, spec, objective))
}

fn task_merge_policy_satisfied(connection: &Connection, task_id: &str) -> Result<bool, String> {
    match merge_policy_status_json(connection, task_id)? {
        Some(policy) => Ok(policy.get("satisfied").and_then(Value::as_bool) == Some(true)),
        None => Ok(true),
    }
}

fn projected_objective_status(
    connection: &Connection,
    objective: &SwarmObjectiveRecord,
    tasks: &[SwarmTaskState],
    at_ms: i64,
) -> Result<String, String> {
    if deadline_expired(objective.deadline_at_ms, at_ms) {
        return Ok("expired".to_owned());
    }
    if tasks.is_empty() {
        return Ok("empty".to_owned());
    }
    if tasks.iter().any(|task| task.status == "failed" || task.status == "stopped") {
        return Ok("blocked".to_owned());
    }
    for task in tasks {
        if lease_is_expired(task, load_task_spec(connection, &task.task_id)?.as_ref(), at_ms) {
            return Ok("recovering".to_owned());
        }
    }
    if tasks.iter().any(|task| {
        (task.status == "leased" || task.status == "active")
            && !lease_is_expired(task, load_task_spec(connection, &task.task_id).ok().flatten().as_ref(), at_ms)
    }) {
        return Ok("running".to_owned());
    }
    for task in tasks {
        if task.status == "completed" && !task_merge_policy_satisfied(connection, &task.task_id)? {
            return Ok("gating".to_owned());
        }
    }
    if tasks
        .iter()
        .any(|task| task_ready_state(connection, task, at_ms).map(|(ready, _, _, _, _)| ready).unwrap_or(false))
    {
        return Ok("ready".to_owned());
    }
    let all_satisfied = tasks
        .iter()
        .all(|task| task.status == "completed" && task_merge_policy_satisfied(connection, &task.task_id).unwrap_or(false));
    if all_satisfied {
        Ok("completed".to_owned())
    } else {
        Ok("waiting".to_owned())
    }
}

fn objective_json(connection: &Connection, objective: &SwarmObjectiveRecord) -> Result<Value, String> {
    let tasks = objective_tasks(connection, &objective.objective_id)?;
    let projected_status = projected_objective_status(connection, objective, &tasks, now_ms())?;
    Ok(json!({
        "objectiveId": objective.objective_id,
        "detail": objective.detail,
        "status": objective.status,
        "projectedStatus": projected_status,
        "maxTasks": objective.max_tasks,
        "maxRuns": objective.max_runs,
        "deadlineAtMs": objective.deadline_at_ms,
        "createdAtMs": objective.created_at_ms,
        "updatedAtMs": objective.updated_at_ms,
        "taskCount": objective_task_count(connection, &objective.objective_id)?,
        "runCount": objective_run_count(connection, &objective.objective_id)?,
    }))
}

fn task_record_json(connection: &Connection, task: &SwarmTaskState) -> Result<Value, String> {
    let at_ms = now_ms();
    let (ready, lease_expired, blocked, spec, objective) = task_ready_state(connection, task, at_ms)?;
    let merge_policy = merge_policy_status_json(connection, &task.task_id)?;
    Ok(json!({
        "taskId": task.task_id,
        "status": task.status,
        "leaseActor": task.lease_actor,
        "lastHeartbeatAtMs": task.last_heartbeat_at_ms,
        "heartbeatSeen": task.heartbeat_seen,
        "attempts": task.attempts,
        "lastError": task.last_error,
        "createdAtMs": task.created_at_ms,
        "updatedAtMs": task.updated_at_ms,
        "objectiveId": spec.as_ref().map(|value| value.objective_id.clone()),
        "detail": spec.as_ref().map(|value| value.detail.clone()).unwrap_or_default(),
        "maxRuns": spec.as_ref().map(|value| value.max_runs).unwrap_or(0),
        "deadlineAtMs": spec.as_ref().map(|value| value.deadline_at_ms).unwrap_or(0),
        "leaseTimeoutMs": spec.as_ref().map(|value| value.lease_timeout_ms).unwrap_or(DEFAULT_LEASE_TIMEOUT_MS),
        "dependencies": task_dependency_ids(connection, &task.task_id)?,
        "ready": ready,
        "leaseExpired": lease_expired,
        "blockedBy": blocked,
        "objectiveDeadlineAtMs": objective.as_ref().map(|value| value.deadline_at_ms).unwrap_or(0),
        "mergePolicy": merge_policy,
    }))
}

fn append_event(connection: &mut Connection, event: &SwarmEvent) -> Result<SwarmTaskState, String> {
    let transaction = connection
        .transaction()
        .map_err(|err| format!("failed to start swarm transaction: {err}"))?;
    transaction
        .execute(
            "
            INSERT INTO swarm_events (kind, task_id, actor, detail, at_ms, payload_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ",
            params![
                event.kind,
                event.task_id,
                event.actor,
                event.detail,
                event.at_ms,
                event.payload_json
            ],
        )
        .map_err(|err| format!("failed to append swarm event: {err}"))?;
    let mut task = load_task_state(&transaction, &event.task_id)?.unwrap_or_else(|| empty_task_state(&event.task_id, event.at_ms));
    apply_event(&mut task, event);
    store_task_state(&transaction, &task)?;
    transaction
        .commit()
        .map_err(|err| format!("failed to commit swarm event transaction: {err}"))?;
    Ok(task)
}

fn record_swarm_event(
    connection: &mut Connection,
    kind: &str,
    task_id: &str,
    actor: &str,
    detail: &str,
    payload: Value,
) -> Result<SwarmTaskState, String> {
    append_event(
        connection,
        &SwarmEvent {
            kind: kind.to_owned(),
            task_id: task_id.to_owned(),
            actor: actor.to_owned(),
            detail: detail.to_owned(),
            at_ms: now_ms(),
            payload_json: payload.to_string(),
        },
    )
}

fn swarm_event_output(paths: &SwarmRuntimePaths, event: &SwarmEvent, task: Value) -> Value {
    json!({
        "root": paths.root.display().to_string(),
        "database": paths.db_path.display().to_string(),
        "event": {
            "kind": event.kind,
            "taskId": event.task_id,
            "actor": event.actor,
            "detail": event.detail,
            "atMs": event.at_ms,
        },
        "task": task,
    })
}

fn task_json(task: &SwarmTaskState) -> Value {
    json!({
        "taskId": task.task_id,
        "status": task.status,
        "leaseActor": task.lease_actor,
        "lastHeartbeatAtMs": task.last_heartbeat_at_ms,
        "heartbeatSeen": task.heartbeat_seen,
        "attempts": task.attempts,
        "lastError": task.last_error,
        "createdAtMs": task.created_at_ms,
        "updatedAtMs": task.updated_at_ms,
    })
}

fn event_json(kind: String, task_id: String, actor: String, detail: String, at_ms: i64, payload_json: String) -> Value {
    let payload = serde_json::from_str::<Value>(&payload_json).unwrap_or(Value::Null);
    json!({
        "kind": kind,
        "taskId": task_id,
        "actor": actor,
        "detail": detail,
        "atMs": at_ms,
        "payload": payload,
    })
}

fn history_json(connection: &Connection, task_id: &str) -> Result<Value, String> {
    let mut statement = connection
        .prepare(
            "
            SELECT kind, task_id, actor, detail, at_ms, payload_json
            FROM swarm_events
            WHERE task_id = ?1
            ORDER BY id ASC
            ",
        )
        .map_err(|err| format!("failed to prepare swarm history query: {err}"))?;
    let rows = statement
        .query_map(params![task_id], |row| {
            Ok(event_json(
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
            ))
        })
        .map_err(|err| format!("failed to query swarm history: {err}"))?;
    let mut values = Vec::new();
    for row in rows {
        values.push(row.map_err(|err| format!("failed to read swarm history row: {err}"))?);
    }
    Ok(Value::Array(values))
}

fn tail_json(connection: &Connection, task_id: Option<&str>, limit: usize) -> Result<Value, String> {
    let limit = limit.max(1) as i64;
    let mut values = Vec::new();
    if let Some(task_id) = task_id {
        let mut statement = connection
            .prepare(
                "
                SELECT kind, task_id, actor, detail, at_ms, payload_json
                FROM (
                  SELECT kind, task_id, actor, detail, at_ms, payload_json, id
                  FROM swarm_events
                  WHERE task_id = ?1
                  ORDER BY id DESC
                  LIMIT ?2
                )
                ORDER BY at_ms ASC
                ",
            )
            .map_err(|err| format!("failed to prepare swarm tail query: {err}"))?;
        let rows = statement
            .query_map(params![task_id, limit], |row| {
                Ok(event_json(
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            })
            .map_err(|err| format!("failed to query swarm tail: {err}"))?;
        for row in rows {
            values.push(row.map_err(|err| format!("failed to read swarm tail row: {err}"))?);
        }
    } else {
        let mut statement = connection
            .prepare(
                "
                SELECT kind, task_id, actor, detail, at_ms, payload_json
                FROM (
                  SELECT kind, task_id, actor, detail, at_ms, payload_json, id
                  FROM swarm_events
                  ORDER BY id DESC
                  LIMIT ?1
                )
                ORDER BY at_ms ASC
                ",
            )
            .map_err(|err| format!("failed to prepare swarm tail query: {err}"))?;
        let rows = statement
            .query_map(params![limit], |row| {
                Ok(event_json(
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            })
            .map_err(|err| format!("failed to query swarm tail: {err}"))?;
        for row in rows {
            values.push(row.map_err(|err| format!("failed to read swarm tail row: {err}"))?);
        }
    }
    Ok(Value::Array(values))
}

fn tasks_json(connection: &Connection) -> Result<Value, String> {
    let mut statement = connection
        .prepare(
            "
            SELECT task_id, status, lease_actor, last_heartbeat_at_ms, heartbeat_seen, attempts, last_error, created_at_ms, updated_at_ms
            FROM swarm_tasks
            ORDER BY created_at_ms ASC, task_id ASC
            ",
        )
        .map_err(|err| format!("failed to prepare swarm tasks query: {err}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok(SwarmTaskState {
                task_id: row.get(0)?,
                status: row.get(1)?,
                lease_actor: row.get(2)?,
                last_heartbeat_at_ms: row.get(3)?,
                heartbeat_seen: row.get::<_, i64>(4)? != 0,
                attempts: row.get(5)?,
                last_error: row.get(6)?,
                created_at_ms: row.get(7)?,
                updated_at_ms: row.get(8)?,
            })
        })
        .map_err(|err| format!("failed to query swarm tasks: {err}"))?;
    let mut values = Vec::new();
    for row in rows {
        values.push(task_record_json(connection, &row.map_err(|err| format!("failed to read swarm task row: {err}"))?)?);
    }
    Ok(Value::Array(values))
}

fn summary_json(connection: &Connection) -> Result<Value, String> {
    let tasks = tasks_json(connection)?;
    let Some(task_values) = tasks.as_array() else {
        return Ok(json!({
            "allTaskIds": [],
            "createdTaskIds": [],
            "leasedTaskIds": [],
            "activeTaskIds": [],
            "queuedTaskIds": [],
            "completedTaskIds": [],
            "failedTaskIds": [],
            "heartbeatTaskIds": [],
            "statusByTask": {},
            "leaseByTask": {},
            "hasBootstrap": false,
            "bootstrapStatus": "missing",
            "taskStatusKeys": [],
            "leaseValuesWithoutDraft": [],
        }));
    };
    let collect = |status: &str| -> Vec<Value> {
        task_values
            .iter()
            .filter(|task| task.get("status").and_then(Value::as_str) == Some(status))
            .filter_map(|task| task.get("taskId").cloned())
            .collect()
    };
    let heartbeat = task_values
        .iter()
        .filter(|task| task.get("heartbeatSeen").and_then(Value::as_bool) == Some(true))
        .filter_map(|task| task.get("taskId").cloned())
        .collect::<Vec<_>>();
    let ready = task_values
        .iter()
        .filter(|task| task.get("ready").and_then(Value::as_bool) == Some(true))
        .filter_map(|task| task.get("taskId").cloned())
        .collect::<Vec<_>>();
    let mut status_by_task = Map::new();
    let mut lease_by_task = Map::new();
    let mut task_status_keys = Vec::new();
    let mut lease_values_without_draft = Vec::new();
    for task in task_values {
        let Some(task_id) = task.get("taskId").and_then(Value::as_str) else {
            continue;
        };
        let status = task.get("status").and_then(Value::as_str).unwrap_or_default();
        let lease_actor = task.get("leaseActor").and_then(Value::as_str).unwrap_or_default();
        status_by_task.insert(task_id.to_owned(), Value::String(status.to_owned()));
        lease_by_task.insert(task_id.to_owned(), Value::String(lease_actor.to_owned()));
        task_status_keys.push(Value::String(task_id.to_owned()));
        if task_id != "draft" {
            lease_values_without_draft.push(Value::String(lease_actor.to_owned()));
        }
    }
    let bootstrap_status = status_by_task
        .get("bootstrap")
        .and_then(Value::as_str)
        .unwrap_or("missing")
        .to_owned();
    Ok(json!({
        "allTaskIds": task_values.iter().filter_map(|task| task.get("taskId").cloned()).collect::<Vec<_>>(),
        "createdTaskIds": collect("created"),
        "leasedTaskIds": collect("leased"),
        "activeTaskIds": collect("active"),
        "queuedTaskIds": collect("queued"),
        "stoppedTaskIds": collect("stopped"),
        "completedTaskIds": collect("completed"),
        "failedTaskIds": collect("failed"),
        "heartbeatTaskIds": heartbeat,
        "readyTaskIds": ready,
        "statusByTask": status_by_task,
        "leaseByTask": lease_by_task,
        "hasBootstrap": task_status_keys.iter().any(|value| value.as_str() == Some("bootstrap")),
        "bootstrapStatus": bootstrap_status,
        "taskStatusKeys": task_status_keys,
        "leaseValuesWithoutDraft": lease_values_without_draft,
    }))
}

fn artifact_json(record: &SwarmArtifactRecord) -> Value {
    let metadata = serde_json::from_str::<Value>(&record.metadata_json).unwrap_or(Value::Null);
    json!({
        "artifactId": record.artifact_id,
        "taskId": record.task_id,
        "kind": record.kind,
        "path": record.path,
        "createdAtMs": record.created_at_ms,
        "metadata": metadata,
    })
}

fn approval_json(record: &SwarmApprovalRecord) -> Value {
    let payload = serde_json::from_str::<Value>(&record.payload_json).unwrap_or(Value::Null);
    json!({
        "approvalId": record.approval_id,
        "taskId": record.task_id,
        "name": record.name,
        "actor": record.actor,
        "detail": record.detail,
        "atMs": record.at_ms,
        "payload": payload,
    })
}

fn memory_json(record: &SwarmMemoryRecord) -> Value {
    json!({
        "memoryId": record.memory_id,
        "objectiveId": record.objective_id,
        "taskId": record.task_id,
        "key": record.key,
        "value": record.value,
        "actor": record.actor,
        "createdAtMs": record.created_at_ms,
        "updatedAtMs": record.updated_at_ms,
    })
}

fn insert_memory(
    connection: &mut Connection,
    objective_id: &str,
    task_id: &str,
    actor: &str,
    key: &str,
    value: &str,
) -> Result<SwarmMemoryRecord, String> {
    if key.is_empty() {
        return Err("swarm memory key cannot be empty".to_owned());
    }
    if !objective_id.is_empty() && load_objective(connection, objective_id)?.is_none() {
        return Err(format!("unknown swarm objective `{objective_id}`"));
    }
    if !task_id.is_empty() {
        if load_task_state(connection, task_id)?.is_none() {
            return Err(format!("unknown swarm task `{task_id}`"));
        }
        if !objective_id.is_empty() {
            if let Some(spec) = load_task_spec(connection, task_id)? {
                if spec.objective_id != objective_id {
                    return Err(format!(
                        "swarm task `{task_id}` belongs to objective `{}`, not `{objective_id}`",
                        spec.objective_id
                    ));
                }
            }
        }
    }
    let at_ms = now_ms();
    connection
        .execute(
            "
            INSERT INTO swarm_memory (
              objective_id, task_id, key, value, actor, created_at_ms, updated_at_ms, payload_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, '{}')
            ",
            params![objective_id, task_id, key, value, actor, at_ms],
        )
        .map_err(|err| format!("failed to store swarm memory `{key}`: {err}"))?;
    Ok(SwarmMemoryRecord {
        memory_id: connection.last_insert_rowid(),
        objective_id: objective_id.to_owned(),
        task_id: task_id.to_owned(),
        key: key.to_owned(),
        value: value.to_owned(),
        actor: actor.to_owned(),
        created_at_ms: at_ms,
        updated_at_ms: at_ms,
    })
}

fn memory_query_json(
    connection: &Connection,
    objective_id: Option<&str>,
    task_id: Option<&str>,
    key: Option<&str>,
    limit: usize,
) -> Result<Value, String> {
    let objective_filter = objective_id.unwrap_or_default();
    let task_filter = task_id.unwrap_or_default();
    let key_filter = key.unwrap_or_default();
    let limit = limit.max(1).min(1_000) as i64;
    let mut statement = connection
        .prepare(
            "
            SELECT id, objective_id, task_id, key, value, actor, created_at_ms, updated_at_ms
            FROM swarm_memory
            WHERE (?1 = '' OR objective_id = ?1)
              AND (?2 = '' OR task_id = ?2)
              AND (?3 = '' OR key = ?3)
            ORDER BY id DESC
            LIMIT ?4
            ",
        )
        .map_err(|err| format!("failed to prepare swarm memory query: {err}"))?;
    let rows = statement
        .query_map(params![objective_filter, task_filter, key_filter, limit], |row| {
            Ok(SwarmMemoryRecord {
                memory_id: row.get(0)?,
                objective_id: row.get(1)?,
                task_id: row.get(2)?,
                key: row.get(3)?,
                value: row.get(4)?,
                actor: row.get(5)?,
                created_at_ms: row.get(6)?,
                updated_at_ms: row.get(7)?,
            })
        })
        .map_err(|err| format!("failed to query swarm memory: {err}"))?;
    let mut values = Vec::new();
    for row in rows {
        values.push(memory_json(&row.map_err(|err| format!("failed to read swarm memory row: {err}"))?));
    }
    Ok(Value::Array(values))
}

fn decode_string_list(raw: &str) -> Vec<String> {
    serde_json::from_str::<Vec<String>>(raw).unwrap_or_default()
}

fn granted_approval_names(connection: &Connection, task_id: &str) -> Result<Vec<String>, String> {
    let mut statement = connection
        .prepare(
            "
            SELECT DISTINCT name
            FROM swarm_approvals
            WHERE task_id = ?1
            ORDER BY name ASC
            ",
        )
        .map_err(|err| format!("failed to prepare granted approval query: {err}"))?;
    let rows = statement
        .query_map(params![task_id], |row| row.get::<_, String>(0))
        .map_err(|err| format!("failed to query granted approvals: {err}"))?;
    let mut values = Vec::new();
    for row in rows {
        values.push(row.map_err(|err| format!("failed to read granted approval row: {err}"))?);
    }
    Ok(values)
}

fn latest_mergegate_payload(connection: &Connection, task_id: &str, mergegate_name: &str) -> Result<Option<Value>, String> {
    let mut statement = connection
        .prepare(
            "
            SELECT payload_json
            FROM swarm_events
            WHERE task_id = ?1 AND kind = 'mergegate_decision'
            ORDER BY id DESC
            ",
        )
        .map_err(|err| format!("failed to prepare mergegate payload query: {err}"))?;
    let rows = statement
        .query_map(params![task_id], |row| row.get::<_, String>(0))
        .map_err(|err| format!("failed to query mergegate payloads: {err}"))?;
    for row in rows {
        let payload_json = row.map_err(|err| format!("failed to read mergegate payload row: {err}"))?;
        let payload = serde_json::from_str::<Value>(&payload_json).unwrap_or(Value::Null);
        if payload.get("mergegateName").and_then(Value::as_str) == Some(mergegate_name) {
            return Ok(Some(payload));
        }
    }
    Ok(None)
}

fn merge_policy_status_json(connection: &Connection, task_id: &str) -> Result<Option<Value>, String> {
    let Some(policy) = load_merge_policy(connection, task_id)? else {
        return Ok(None);
    };
    let required_approvals = decode_string_list(&policy.required_approvals_json);
    let required_verifiers = decode_string_list(&policy.required_verifiers_json);
    let granted_approvals = granted_approval_names(connection, task_id)?;
    let missing_approvals = required_approvals
        .iter()
        .filter(|name| !granted_approvals.iter().any(|granted| granted == *name))
        .cloned()
        .collect::<Vec<_>>();
    let mut verifier_states = Vec::new();
    let mut missing_verifiers = Vec::new();
    let mut failed_verifiers = Vec::new();
    for verifier_name in &required_verifiers {
        match latest_verifier_run(connection, task_id, verifier_name)? {
            Some(run) if run.exit_code == 0 => verifier_states.push(json!({
                "name": verifier_name,
                "status": "passed",
                "runId": run.run_id,
                "exitCode": run.exit_code,
            })),
            Some(run) => {
                failed_verifiers.push(verifier_name.clone());
                verifier_states.push(json!({
                    "name": verifier_name,
                    "status": "failed",
                    "runId": run.run_id,
                    "exitCode": run.exit_code,
                }));
            }
            None => {
                missing_verifiers.push(verifier_name.clone());
                verifier_states.push(json!({
                    "name": verifier_name,
                    "status": "missing",
                    "runId": Value::Null,
                    "exitCode": Value::Null,
                }));
            }
        }
    }
    let mergegate_payload = latest_mergegate_payload(connection, task_id, &policy.mergegate_name)?;
    let mergegate_verdict = mergegate_payload
        .as_ref()
        .and_then(|value| value.get("verdict"))
        .and_then(Value::as_str)
        .unwrap_or("missing");
    let ready_for_mergegate = missing_approvals.is_empty() && missing_verifiers.is_empty() && failed_verifiers.is_empty();
    let satisfied = ready_for_mergegate && mergegate_verdict == "pass";
    Ok(Some(json!({
        "taskId": policy.task_id,
        "mergegateName": policy.mergegate_name,
        "requiredApprovals": required_approvals,
        "grantedApprovals": granted_approvals,
        "missingApprovals": missing_approvals,
        "requiredVerifiers": verifier_states,
        "missingVerifiers": missing_verifiers,
        "failedVerifiers": failed_verifiers,
        "mergegate": mergegate_payload.unwrap_or_else(|| json!({
            "mergegateName": policy.mergegate_name,
            "verdict": "missing",
        })),
        "readyForMergegate": ready_for_mergegate,
        "satisfied": satisfied,
        "createdAtMs": policy.created_at_ms,
        "updatedAtMs": policy.updated_at_ms,
    })))
}

fn artifacts_json(connection: &Connection, task_id: Option<&str>) -> Result<Value, String> {
    let mut values = Vec::new();
    if let Some(task_id) = task_id {
        let mut statement = connection
            .prepare(
                "
                SELECT id, task_id, kind, path, created_at_ms, metadata_json
                FROM swarm_artifacts
                WHERE task_id = ?1
                ORDER BY id DESC
                ",
            )
            .map_err(|err| format!("failed to prepare swarm artifacts query: {err}"))?;
        let rows = statement
            .query_map(params![task_id], |row| {
                Ok(SwarmArtifactRecord {
                    artifact_id: row.get(0)?,
                    task_id: row.get(1)?,
                    kind: row.get(2)?,
                    path: row.get(3)?,
                    created_at_ms: row.get(4)?,
                    metadata_json: row.get(5)?,
                })
            })
            .map_err(|err| format!("failed to query swarm artifacts: {err}"))?;
        for row in rows {
            values.push(artifact_json(&row.map_err(|err| format!("failed to read swarm artifact row: {err}"))?));
        }
    } else {
        let mut statement = connection
            .prepare(
                "
                SELECT id, task_id, kind, path, created_at_ms, metadata_json
                FROM swarm_artifacts
                ORDER BY id DESC
                ",
            )
            .map_err(|err| format!("failed to prepare swarm artifacts query: {err}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok(SwarmArtifactRecord {
                    artifact_id: row.get(0)?,
                    task_id: row.get(1)?,
                    kind: row.get(2)?,
                    path: row.get(3)?,
                    created_at_ms: row.get(4)?,
                    metadata_json: row.get(5)?,
                })
            })
            .map_err(|err| format!("failed to query swarm artifacts: {err}"))?;
        for row in rows {
            values.push(artifact_json(&row.map_err(|err| format!("failed to read swarm artifact row: {err}"))?));
        }
    }
    Ok(Value::Array(values))
}

fn approvals_json(connection: &Connection, task_id: Option<&str>) -> Result<Value, String> {
    let mut values = Vec::new();
    if let Some(task_id) = task_id {
        let mut statement = connection
            .prepare(
                "
                SELECT id, task_id, name, actor, detail, at_ms, payload_json
                FROM swarm_approvals
                WHERE task_id = ?1
                ORDER BY id DESC
                ",
            )
            .map_err(|err| format!("failed to prepare swarm approvals query: {err}"))?;
        let rows = statement
            .query_map(params![task_id], |row| {
                Ok(SwarmApprovalRecord {
                    approval_id: row.get(0)?,
                    task_id: row.get(1)?,
                    name: row.get(2)?,
                    actor: row.get(3)?,
                    detail: row.get(4)?,
                    at_ms: row.get(5)?,
                    payload_json: row.get(6)?,
                })
            })
            .map_err(|err| format!("failed to query swarm approvals: {err}"))?;
        for row in rows {
            values.push(approval_json(&row.map_err(|err| format!("failed to read swarm approval row: {err}"))?));
        }
    } else {
        let mut statement = connection
            .prepare(
                "
                SELECT id, task_id, name, actor, detail, at_ms, payload_json
                FROM swarm_approvals
                ORDER BY id DESC
                ",
            )
            .map_err(|err| format!("failed to prepare swarm approvals query: {err}"))?;
        let rows = statement
            .query_map([], |row| {
                Ok(SwarmApprovalRecord {
                    approval_id: row.get(0)?,
                    task_id: row.get(1)?,
                    name: row.get(2)?,
                    actor: row.get(3)?,
                    detail: row.get(4)?,
                    at_ms: row.get(5)?,
                    payload_json: row.get(6)?,
                })
            })
            .map_err(|err| format!("failed to query swarm approvals: {err}"))?;
        for row in rows {
            values.push(approval_json(&row.map_err(|err| format!("failed to read swarm approval row: {err}"))?));
        }
    }
    Ok(Value::Array(values))
}

fn objectives_json(connection: &Connection) -> Result<Value, String> {
    let mut statement = connection
        .prepare(
            "
            SELECT objective_id, detail, status, max_tasks, max_runs, deadline_at_ms, created_at_ms, updated_at_ms
            FROM swarm_objectives
            ORDER BY created_at_ms ASC, objective_id ASC
            ",
        )
        .map_err(|err| format!("failed to prepare swarm objectives query: {err}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok(SwarmObjectiveRecord {
                objective_id: row.get(0)?,
                detail: row.get(1)?,
                status: row.get(2)?,
                max_tasks: row.get(3)?,
                max_runs: row.get(4)?,
                deadline_at_ms: row.get(5)?,
                created_at_ms: row.get(6)?,
                updated_at_ms: row.get(7)?,
            })
        })
        .map_err(|err| format!("failed to query swarm objectives: {err}"))?;
    let mut values = Vec::new();
    for row in rows {
        values.push(objective_json(connection, &row.map_err(|err| format!("failed to read swarm objective row: {err}"))?)?);
    }
    Ok(Value::Array(values))
}

fn objective_status_json(connection: &Connection, objective_id: &str) -> Result<Value, String> {
    let Some(objective) = load_objective(connection, objective_id)? else {
        return Ok(json!({
            "objective": {
                "objectiveId": objective_id,
                "detail": "",
                "status": "missing",
                "projectedStatus": "missing",
                "maxTasks": 0,
                "maxRuns": 0,
                "deadlineAtMs": 0,
                "createdAtMs": 0,
                "updatedAtMs": 0,
                "taskCount": 0,
                "runCount": 0,
            },
            "projectedStatus": "missing",
            "tasks": [],
        }));
    };
    let mut statement = connection
        .prepare(
            "
            SELECT task_id, status, lease_actor, last_heartbeat_at_ms, heartbeat_seen, attempts, last_error, created_at_ms, updated_at_ms
            FROM swarm_tasks
            WHERE task_id IN (
              SELECT task_id FROM swarm_task_specs WHERE objective_id = ?1
            )
            ORDER BY created_at_ms ASC, task_id ASC
            ",
        )
        .map_err(|err| format!("failed to prepare swarm objective task query: {err}"))?;
    let rows = statement
        .query_map(params![objective_id], |row| {
            Ok(SwarmTaskState {
                task_id: row.get(0)?,
                status: row.get(1)?,
                lease_actor: row.get(2)?,
                last_heartbeat_at_ms: row.get(3)?,
                heartbeat_seen: row.get::<_, i64>(4)? != 0,
                attempts: row.get(5)?,
                last_error: row.get(6)?,
                created_at_ms: row.get(7)?,
                updated_at_ms: row.get(8)?,
            })
        })
        .map_err(|err| format!("failed to query swarm objective tasks: {err}"))?;
    let mut tasks = Vec::new();
    for row in rows {
        tasks.push(task_record_json(connection, &row.map_err(|err| format!("failed to read swarm objective task row: {err}"))?)?);
    }
    let raw_tasks = objective_tasks(connection, objective_id)?;
    let projected_status = projected_objective_status(connection, &objective, &raw_tasks, now_ms())?;
    Ok(json!({
        "objective": objective_json(connection, &objective)?,
        "projectedStatus": projected_status,
        "tasks": tasks,
    }))
}

fn objective_tasks(connection: &Connection, objective_id: &str) -> Result<Vec<SwarmTaskState>, String> {
    let mut statement = connection
        .prepare(
            "
            SELECT tasks.task_id, tasks.status, tasks.lease_actor, tasks.last_heartbeat_at_ms, tasks.heartbeat_seen,
                   tasks.attempts, tasks.last_error, tasks.created_at_ms, tasks.updated_at_ms
            FROM swarm_tasks AS tasks
            INNER JOIN swarm_task_specs AS specs ON specs.task_id = tasks.task_id
            WHERE specs.objective_id = ?1
            ORDER BY tasks.created_at_ms ASC, tasks.task_id ASC
            ",
        )
        .map_err(|err| format!("failed to prepare swarm objective task listing: {err}"))?;
    let rows = statement
        .query_map(params![objective_id], |row| {
            Ok(SwarmTaskState {
                task_id: row.get(0)?,
                status: row.get(1)?,
                lease_actor: row.get(2)?,
                last_heartbeat_at_ms: row.get(3)?,
                heartbeat_seen: row.get::<_, i64>(4)? != 0,
                attempts: row.get(5)?,
                last_error: row.get(6)?,
                created_at_ms: row.get(7)?,
                updated_at_ms: row.get(8)?,
            })
        })
        .map_err(|err| format!("failed to query swarm objective task listing: {err}"))?;
    let mut tasks = Vec::new();
    for row in rows {
        tasks.push(row.map_err(|err| format!("failed to read swarm objective task listing row: {err}"))?);
    }
    Ok(tasks)
}

fn string_values(values: Vec<String>) -> Value {
    Value::Array(values.into_iter().map(Value::String).collect())
}

fn required_verifier_names_from_policy(policy: Option<&Value>) -> Vec<String> {
    policy
        .and_then(|value| value.get("requiredVerifiers"))
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .or_else(|| value.get("name").and_then(Value::as_str).map(str::to_owned))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn manager_action_with_details(connection: &Connection, mut value: Value) -> Result<Value, String> {
    let Some(map) = value.as_object_mut() else {
        return Ok(value);
    };
    let task_id = map
        .get("taskId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let merge_policy = map.get("mergePolicy").cloned();
    let at_ms = now_ms();

    let mut task_status = String::new();
    let mut blocked_by = string_list(map.get("blockedBy"));
    let mut blocker_task_ids = Vec::new();
    if !task_id.is_empty() {
        if let Some(task) = load_task_state(connection, &task_id)? {
            task_status = task.status.clone();
            if blocked_by.is_empty() {
                let (_ready, _lease_expired, blocked, _spec, _objective) =
                    task_ready_state(connection, &task, at_ms)?;
                blocked_by = blocked;
            }
        }
        blocker_task_ids = unfinished_dependency_ids(connection, &task_id)?;
    }

    let mut required_approvals =
        string_list(merge_policy.as_ref().and_then(|value| value.get("requiredApprovals")));
    let mut required_verifiers = required_verifier_names_from_policy(merge_policy.as_ref());
    let mut mergegate_name = map
        .get("mergegateName")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    if let Some(policy) = merge_policy.as_ref() {
        if mergegate_name.is_empty() {
            mergegate_name = policy
                .get("mergegateName")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
        }
    }
    if !task_id.is_empty()
        && (required_approvals.is_empty() || required_verifiers.is_empty() || mergegate_name.is_empty())
    {
        if let Some(policy) = load_merge_policy(connection, &task_id)? {
            if required_approvals.is_empty() {
                required_approvals = decode_string_list(&policy.required_approvals_json);
            }
            if required_verifiers.is_empty() {
                required_verifiers = decode_string_list(&policy.required_verifiers_json);
            }
            if mergegate_name.is_empty() {
                mergegate_name = policy.mergegate_name;
            }
        }
    }

    let latest_run = if task_id.is_empty() {
        None
    } else {
        latest_run_for_task(connection, &task_id)?
    };
    let verifier_hint = map
        .get("verifier")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let latest_verifier = if task_id.is_empty() {
        None
    } else if verifier_hint.is_empty() {
        latest_verifier_run_for_task(connection, &task_id)?
    } else {
        latest_verifier_run(connection, &task_id, &verifier_hint)?
    };

    let mergegate_value = merge_policy.as_ref().and_then(|policy| policy.get("mergegate"));
    let mergegate_verdict = mergegate_value
        .and_then(|value| value.get("verdict"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let mergegate_detail = mergegate_value
        .and_then(|value| value.get("detail"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();

    if !map.contains_key("taskId") {
        map.insert("taskId".to_owned(), Value::String(task_id));
    }
    map.insert("taskStatus".to_owned(), Value::String(task_status));
    map.insert("blockedBy".to_owned(), string_values(blocked_by));
    map.insert("blockerTaskIds".to_owned(), string_values(blocker_task_ids));
    map.insert("requiredApprovals".to_owned(), string_values(required_approvals));
    map.insert("requiredVerifiers".to_owned(), string_values(required_verifiers));
    map.insert(
        "latestRunId".to_owned(),
        json!(latest_run.as_ref().map(|run| run.run_id).unwrap_or(-1)),
    );
    map.insert(
        "latestRunRole".to_owned(),
        Value::String(
            latest_run
                .as_ref()
                .map(|run| run.role.clone())
                .unwrap_or_default(),
        ),
    );
    map.insert(
        "latestRunName".to_owned(),
        Value::String(
            latest_run
                .as_ref()
                .map(|run| run.name.clone())
                .unwrap_or_default(),
        ),
    );
    map.insert(
        "latestRunStatus".to_owned(),
        Value::String(
            latest_run
                .as_ref()
                .map(|run| run.status.clone())
                .unwrap_or_default(),
        ),
    );
    map.insert(
        "latestRunExitCode".to_owned(),
        json!(latest_run.as_ref().map(|run| run.exit_code).unwrap_or(-999)),
    );
    map.insert(
        "latestVerifier".to_owned(),
        Value::String(
            latest_verifier
                .as_ref()
                .map(|run| run.name.clone())
                .unwrap_or(verifier_hint),
        ),
    );
    map.insert(
        "latestVerifierStatus".to_owned(),
        Value::String(
            latest_verifier
                .as_ref()
                .map(|run| run.status.clone())
                .unwrap_or_default(),
        ),
    );
    map.insert(
        "latestVerifierExitCode".to_owned(),
        json!(latest_verifier.as_ref().map(|run| run.exit_code).unwrap_or(-999)),
    );
    map.insert("mergegateName".to_owned(), Value::String(mergegate_name));
    map.insert("mergegateVerdict".to_owned(), Value::String(mergegate_verdict));
    map.insert("mergegateDetail".to_owned(), Value::String(mergegate_detail));

    Ok(value)
}

fn manager_next_json(connection: &Connection, objective_id: &str) -> Result<Value, String> {
    let Some(objective) = load_objective(connection, objective_id)? else {
        return manager_action_with_details(connection, json!({
            "objectiveId": objective_id,
            "status": "missing",
            "action": "missing-objective",
            "suggestedCommand": ["claspc", "swarm", "objective", "create", "<state-root>", objective_id],
        }));
    };
    let tasks = objective_tasks(connection, objective_id)?;
    if tasks.is_empty() {
        return manager_action_with_details(connection, json!({
            "objectiveId": objective.objective_id.clone(),
            "status": "empty",
            "action": "plan-tasks",
            "taskCount": 0,
            "suggestedCommand": [
                "claspc",
                "swarm",
                "task",
                "create",
                "<state-root>",
                objective.objective_id.clone(),
                "<task-id>"
            ],
        }));
    }
    let at_ms = now_ms();
    for task in &tasks {
        let spec = load_task_spec(connection, &task.task_id)?;
        if lease_is_expired(task, spec.as_ref(), at_ms) {
            return manager_action_with_details(connection, json!({
                "objectiveId": objective_id,
                "status": "needs-attention",
                "action": "recover-lease",
                "taskId": task.task_id,
                "leaseActor": task.lease_actor,
                "leaseExpired": true,
                "suggestedCommand": ["claspc", "swarm", "lease", "<state-root>", task.task_id.clone()],
            }));
        }
    }
    for task in &tasks {
        if (task.status == "leased" || task.status == "active")
            && !lease_is_expired(task, load_task_spec(connection, &task.task_id)?.as_ref(), at_ms)
        {
            return manager_action_with_details(connection, json!({
                "objectiveId": objective_id,
                "status": "waiting",
                "action": "wait-for-lease",
                "taskId": task.task_id,
                "leaseActor": task.lease_actor,
                "suggestedCommand": ["claspc", "swarm", "status", "<state-root>", task.task_id.clone()],
            }));
        }
    }
    for task in &tasks {
        if task.status == "completed" {
            if let Some(policy) = merge_policy_status_json(connection, &task.task_id)? {
                if let Some(failed_verifier) = policy
                    .get("failedVerifiers")
                    .and_then(Value::as_array)
                    .and_then(|values| values.first())
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                {
                    let failed_verifier_command = failed_verifier.clone();
                    return manager_action_with_details(connection, json!({
                        "objectiveId": objective_id,
                        "status": "needs-attention",
                        "action": "rerun-verifier",
                        "taskId": task.task_id,
                        "verifier": failed_verifier,
                        "mergePolicy": policy,
                        "suggestedCommand": [
                            "claspc",
                            "swarm",
                            "verifier",
                            "run",
                            "<state-root>",
                            task.task_id.clone(),
                            failed_verifier_command,
                            "--",
                            "<command...>"
                        ],
                    }));
                }
                if let Some(missing_verifier) = policy
                    .get("missingVerifiers")
                    .and_then(Value::as_array)
                    .and_then(|values| values.first())
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                {
                    let missing_verifier_command = missing_verifier.clone();
                    return manager_action_with_details(connection, json!({
                        "objectiveId": objective_id,
                        "status": "ready",
                        "action": "run-verifier",
                        "taskId": task.task_id,
                        "verifier": missing_verifier,
                        "mergePolicy": policy,
                        "suggestedCommand": [
                            "claspc",
                            "swarm",
                            "verifier",
                            "run",
                            "<state-root>",
                            task.task_id.clone(),
                            missing_verifier_command,
                            "--",
                            "<command...>"
                        ],
                    }));
                }
                if let Some(missing_approval) = policy
                    .get("missingApprovals")
                    .and_then(Value::as_array)
                    .and_then(|values| values.first())
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                {
                    let missing_approval_command = missing_approval.clone();
                    return manager_action_with_details(connection, json!({
                        "objectiveId": objective_id,
                        "status": "ready",
                        "action": "request-approval",
                        "taskId": task.task_id,
                        "approval": missing_approval,
                        "mergePolicy": policy,
                        "suggestedCommand": [
                            "claspc",
                            "swarm",
                            "approve",
                            "<state-root>",
                            task.task_id.clone(),
                            missing_approval_command
                        ],
                    }));
                }
                if policy.get("satisfied").and_then(Value::as_bool) != Some(true) {
                    let mergegate_name = policy
                        .get("mergegateName")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                        .unwrap_or_default();
                    let required_verifiers = policy
                        .get("requiredVerifiers")
                        .and_then(Value::as_array)
                        .map(|values| {
                            values
                                .iter()
                                .filter_map(|value| value.get("name").and_then(Value::as_str))
                                .map(str::to_owned)
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    let mut suggested_command = vec![
                        json!("claspc"),
                        json!("swarm"),
                        json!("mergegate"),
                        json!("decide"),
                        json!("<state-root>"),
                        json!(task.task_id.clone()),
                        json!(mergegate_name.clone()),
                    ];
                    suggested_command.extend(required_verifiers.into_iter().map(|value| json!(value)));
                    return manager_action_with_details(connection, json!({
                        "objectiveId": objective_id,
                        "status": "ready",
                        "action": "decide-mergegate",
                        "taskId": task.task_id,
                        "mergegateName": mergegate_name.clone(),
                        "mergePolicy": policy,
                        "suggestedCommand": suggested_command,
                    }));
                }
            }
            continue;
        }
        let (ready, _lease_expired, blocked, _spec, _objective) = task_ready_state(connection, task, at_ms)?;
        if ready {
            return manager_action_with_details(connection, json!({
                "objectiveId": objective_id,
                "status": "ready",
                "action": "run-task",
                "taskId": task.task_id,
                "suggestedCommand": ["claspc", "swarm", "lease", "<state-root>", task.task_id.clone()],
            }));
        }
        if task.status == "failed" || task.status == "stopped" {
            return manager_action_with_details(connection, json!({
                "objectiveId": objective_id,
                "status": "blocked",
                "action": "inspect-task",
                "taskId": task.task_id,
                "blockedBy": blocked,
                "lastError": task.last_error,
                "suggestedCommand": ["claspc", "swarm", "status", "<state-root>", task.task_id.clone()],
            }));
        }
    }
    let all_satisfied = tasks.iter().all(|task| {
        if task.status != "completed" {
            return false;
        }
        match merge_policy_status_json(connection, &task.task_id) {
            Ok(Some(policy)) => policy.get("satisfied").and_then(Value::as_bool) == Some(true),
            Ok(None) => true,
            Err(_) => false,
        }
    });
    let mut selected_task_id = "";
    let mut selected_blocked_by = Vec::new();
    for task in &tasks {
        if task.status != "completed" {
            let (_ready, _lease_expired, blocked, _spec, _objective) =
                task_ready_state(connection, task, at_ms)?;
            selected_task_id = &task.task_id;
            selected_blocked_by = blocked;
            break;
        }
    }
    manager_action_with_details(connection, json!({
        "objectiveId": objective.objective_id.clone(),
        "status": if all_satisfied { "completed" } else { "waiting" },
        "action": if all_satisfied { "objective-complete" } else { "wait" },
        "taskId": if all_satisfied { "" } else { selected_task_id },
        "blockedBy": selected_blocked_by,
        "taskCount": tasks.len(),
        "suggestedCommand": if all_satisfied {
            json!(["claspc", "swarm", "objective", "status", "<state-root>", objective.objective_id.clone()])
        } else {
            json!(["claspc", "swarm", "tail", "<state-root>", "--limit", "20"])
        },
    }))
}

fn ready_json(connection: &Connection, objective_id: Option<&str>) -> Result<Value, String> {
    let mut values = Vec::new();
    if let Some(objective_id) = objective_id {
        let mut statement = connection
            .prepare(
                "
                SELECT task_id, status, lease_actor, last_heartbeat_at_ms, heartbeat_seen, attempts, last_error, created_at_ms, updated_at_ms
                FROM swarm_tasks
                WHERE task_id IN (
                  SELECT task_id FROM swarm_task_specs WHERE objective_id = ?1
                )
                ORDER BY created_at_ms ASC, task_id ASC
                ",
            )
            .map_err(|err| format!("failed to prepare swarm ready query: {err}"))?;
        let rows = statement
            .query_map(params![objective_id], |row| {
                Ok(SwarmTaskState {
                    task_id: row.get(0)?,
                    status: row.get(1)?,
                    lease_actor: row.get(2)?,
                    last_heartbeat_at_ms: row.get(3)?,
                    heartbeat_seen: row.get::<_, i64>(4)? != 0,
                    attempts: row.get(5)?,
                    last_error: row.get(6)?,
                    created_at_ms: row.get(7)?,
                    updated_at_ms: row.get(8)?,
                })
            })
            .map_err(|err| format!("failed to query swarm ready rows: {err}"))?;
        for row in rows {
            let task = row.map_err(|err| format!("failed to read swarm ready row: {err}"))?;
            let task_value = task_record_json(connection, &task)?;
            if task_value.get("ready").and_then(Value::as_bool) == Some(true) {
                values.push(task_value);
            }
        }
    } else {
        let tasks = tasks_json(connection)?;
        let Some(task_values) = tasks.as_array() else {
            return Ok(Value::Array(vec![]));
        };
        for task_value in task_values {
            if task_value.get("ready").and_then(Value::as_bool) == Some(true) {
                values.push(task_value.clone());
            }
        }
    }
    Ok(Value::Array(values))
}

fn next_artifact_path(paths: &SwarmRuntimePaths, task_id: &str, run_id: i64, kind: &str) -> PathBuf {
    let sanitized_task = task_id.replace('/', "-");
    paths.artifacts_dir.join(format!("{sanitized_task}-{run_id}.{kind}.txt"))
}

fn create_artifact(
    connection: &Connection,
    task_id: &str,
    kind: &str,
    path: &Path,
    metadata: Value,
) -> Result<i64, String> {
    connection
        .execute(
            "
            INSERT INTO swarm_artifacts (task_id, kind, path, created_at_ms, metadata_json)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ",
            params![
                task_id,
                kind,
                path.display().to_string(),
                now_ms(),
                metadata.to_string()
            ],
        )
        .map_err(|err| format!("failed to create swarm artifact record: {err}"))?;
    Ok(connection.last_insert_rowid())
}

fn insert_run(
    connection: &Connection,
    task_id: &str,
    role: &str,
    actor: &str,
    name: &str,
    cwd: &Path,
    command: &[String],
) -> Result<i64, String> {
    connection
        .execute(
            "
            INSERT INTO swarm_runs (task_id, role, actor, name, cwd, command_json, status, started_at_ms)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'running', ?7)
            ",
            params![
                task_id,
                role,
                actor,
                name,
                cwd.display().to_string(),
                serde_json::to_string(command).map_err(|err| format!("failed to encode swarm run command: {err}"))?,
                now_ms()
            ],
        )
        .map_err(|err| format!("failed to insert swarm run: {err}"))?;
    Ok(connection.last_insert_rowid())
}

fn finish_run(
    connection: &Connection,
    run_id: i64,
    exit_code: i64,
    status: &str,
    stdout_artifact_id: i64,
    stderr_artifact_id: i64,
) -> Result<(), String> {
    connection
        .execute(
            "
            UPDATE swarm_runs
            SET exit_code = ?2,
                status = ?3,
                ended_at_ms = ?4,
                stdout_artifact_id = ?5,
                stderr_artifact_id = ?6
            WHERE id = ?1
            ",
            params![run_id, exit_code, status, now_ms(), stdout_artifact_id, stderr_artifact_id],
        )
        .map_err(|err| format!("failed to update swarm run `{run_id}`: {err}"))?;
    Ok(())
}

fn latest_verifier_run(
    connection: &Connection,
    task_id: &str,
    verifier_name: &str,
) -> Result<Option<SwarmRunRecord>, String> {
    connection
        .query_row(
            "
            SELECT id, task_id, role, actor, name, cwd, command_json, COALESCE(exit_code, -999), status,
                   started_at_ms, COALESCE(ended_at_ms, started_at_ms), stdout_artifact_id, stderr_artifact_id
            FROM swarm_runs
            WHERE task_id = ?1 AND role = 'verifier' AND name = ?2
            ORDER BY id DESC
            LIMIT 1
            ",
            params![task_id, verifier_name],
            |row| {
                let command_json: String = row.get(6)?;
                let command = serde_json::from_str::<Vec<String>>(&command_json).unwrap_or_default();
                let stdout_artifact_id: Option<i64> = row.get(11)?;
                let stderr_artifact_id: Option<i64> = row.get(12)?;
                Ok(SwarmRunRecord {
                    run_id: row.get(0)?,
                    task_id: row.get(1)?,
                    role: row.get(2)?,
                    actor: row.get(3)?,
                    name: row.get(4)?,
                    cwd: row.get(5)?,
                    command,
                    exit_code: row.get(7)?,
                    status: row.get(8)?,
                    started_at_ms: row.get(9)?,
                    ended_at_ms: row.get(10)?,
                    stdout_artifact_path: artifact_path_by_id(connection, stdout_artifact_id)?,
                    stderr_artifact_path: artifact_path_by_id(connection, stderr_artifact_id)?,
                })
            },
        )
        .optional()
        .map_err(|err| format!("failed to load verifier run `{verifier_name}`: {err}"))
}

fn latest_run_for_task(connection: &Connection, task_id: &str) -> Result<Option<SwarmRunRecord>, String> {
    connection
        .query_row(
            "
            SELECT runs.id, runs.task_id, runs.role, runs.actor, runs.name, runs.cwd, runs.command_json,
                   COALESCE(runs.exit_code, -999), runs.status, runs.started_at_ms, COALESCE(runs.ended_at_ms, runs.started_at_ms),
                   COALESCE(stdout.path, ''), COALESCE(stderr.path, '')
            FROM swarm_runs AS runs
            LEFT JOIN swarm_artifacts AS stdout ON stdout.id = runs.stdout_artifact_id
            LEFT JOIN swarm_artifacts AS stderr ON stderr.id = runs.stderr_artifact_id
            WHERE runs.task_id = ?1
            ORDER BY runs.id DESC
            LIMIT 1
            ",
            params![task_id],
            |row| {
                let command_json: String = row.get(6)?;
                let command = serde_json::from_str::<Vec<String>>(&command_json).unwrap_or_default();
                Ok(SwarmRunRecord {
                    run_id: row.get(0)?,
                    task_id: row.get(1)?,
                    role: row.get(2)?,
                    actor: row.get(3)?,
                    name: row.get(4)?,
                    cwd: row.get(5)?,
                    command,
                    exit_code: row.get(7)?,
                    status: row.get(8)?,
                    started_at_ms: row.get(9)?,
                    ended_at_ms: row.get(10)?,
                    stdout_artifact_path: row.get(11)?,
                    stderr_artifact_path: row.get(12)?,
                })
            },
        )
        .optional()
        .map_err(|err| format!("failed to load latest run for `{task_id}`: {err}"))
}

fn latest_verifier_run_for_task(connection: &Connection, task_id: &str) -> Result<Option<SwarmRunRecord>, String> {
    connection
        .query_row(
            "
            SELECT runs.id, runs.task_id, runs.role, runs.actor, runs.name, runs.cwd, runs.command_json,
                   COALESCE(runs.exit_code, -999), runs.status, runs.started_at_ms, COALESCE(runs.ended_at_ms, runs.started_at_ms),
                   COALESCE(stdout.path, ''), COALESCE(stderr.path, '')
            FROM swarm_runs AS runs
            LEFT JOIN swarm_artifacts AS stdout ON stdout.id = runs.stdout_artifact_id
            LEFT JOIN swarm_artifacts AS stderr ON stderr.id = runs.stderr_artifact_id
            WHERE runs.task_id = ?1 AND runs.role = 'verifier'
            ORDER BY runs.id DESC
            LIMIT 1
            ",
            params![task_id],
            |row| {
                let command_json: String = row.get(6)?;
                let command = serde_json::from_str::<Vec<String>>(&command_json).unwrap_or_default();
                Ok(SwarmRunRecord {
                    run_id: row.get(0)?,
                    task_id: row.get(1)?,
                    role: row.get(2)?,
                    actor: row.get(3)?,
                    name: row.get(4)?,
                    cwd: row.get(5)?,
                    command,
                    exit_code: row.get(7)?,
                    status: row.get(8)?,
                    started_at_ms: row.get(9)?,
                    ended_at_ms: row.get(10)?,
                    stdout_artifact_path: row.get(11)?,
                    stderr_artifact_path: row.get(12)?,
                })
            },
        )
        .optional()
        .map_err(|err| format!("failed to load latest verifier run for `{task_id}`: {err}"))
}

fn runs_json(connection: &Connection, task_id: Option<&str>) -> Result<Value, String> {
    let mut values = Vec::new();
    if let Some(task_id) = task_id {
        let mut statement = connection
            .prepare(
                "
                SELECT runs.id, runs.task_id, runs.role, runs.actor, runs.name, runs.cwd, runs.command_json,
                       COALESCE(runs.exit_code, -999), runs.status, runs.started_at_ms, COALESCE(runs.ended_at_ms, runs.started_at_ms),
                       COALESCE(stdout.path, ''), COALESCE(stderr.path, '')
                FROM swarm_runs AS runs
                LEFT JOIN swarm_artifacts AS stdout ON stdout.id = runs.stdout_artifact_id
                LEFT JOIN swarm_artifacts AS stderr ON stderr.id = runs.stderr_artifact_id
                WHERE runs.task_id = ?1
                ORDER BY runs.id DESC
                ",
            )
            .map_err(|err| format!("failed to prepare swarm runs query: {err}"))?;
        let rows = statement
            .query_map(params![task_id], |row| {
                let command_json: String = row.get(6)?;
                let command = serde_json::from_str::<Vec<String>>(&command_json).unwrap_or_default();
                Ok(SwarmRunRecord {
                    run_id: row.get(0)?,
                    task_id: row.get(1)?,
                    role: row.get(2)?,
                    actor: row.get(3)?,
                    name: row.get(4)?,
                    cwd: row.get(5)?,
                    command,
                    exit_code: row.get(7)?,
                    status: row.get(8)?,
                    started_at_ms: row.get(9)?,
                    ended_at_ms: row.get(10)?,
                    stdout_artifact_path: row.get(11)?,
                    stderr_artifact_path: row.get(12)?,
                })
            })
            .map_err(|err| format!("failed to query swarm runs: {err}"))?;
        for row in rows {
            values.push(run_json(&row.map_err(|err| format!("failed to read swarm run row: {err}"))?));
        }
    } else {
        let mut statement = connection
            .prepare(
                "
                SELECT runs.id, runs.task_id, runs.role, runs.actor, runs.name, runs.cwd, runs.command_json,
                       COALESCE(runs.exit_code, -999), runs.status, runs.started_at_ms, COALESCE(runs.ended_at_ms, runs.started_at_ms),
                       COALESCE(stdout.path, ''), COALESCE(stderr.path, '')
                FROM swarm_runs AS runs
                LEFT JOIN swarm_artifacts AS stdout ON stdout.id = runs.stdout_artifact_id
                LEFT JOIN swarm_artifacts AS stderr ON stderr.id = runs.stderr_artifact_id
                ORDER BY runs.id DESC
                ",
            )
            .map_err(|err| format!("failed to prepare swarm runs query: {err}"))?;
        let rows = statement
            .query_map([], |row| {
                let command_json: String = row.get(6)?;
                let command = serde_json::from_str::<Vec<String>>(&command_json).unwrap_or_default();
                Ok(SwarmRunRecord {
                    run_id: row.get(0)?,
                    task_id: row.get(1)?,
                    role: row.get(2)?,
                    actor: row.get(3)?,
                    name: row.get(4)?,
                    cwd: row.get(5)?,
                    command,
                    exit_code: row.get(7)?,
                    status: row.get(8)?,
                    started_at_ms: row.get(9)?,
                    ended_at_ms: row.get(10)?,
                    stdout_artifact_path: row.get(11)?,
                    stderr_artifact_path: row.get(12)?,
                })
            })
            .map_err(|err| format!("failed to query swarm runs: {err}"))?;
        for row in rows {
            values.push(run_json(&row.map_err(|err| format!("failed to read swarm run row: {err}"))?));
        }
    }
    Ok(Value::Array(values))
}

fn artifact_path_by_id(connection: &Connection, artifact_id: Option<i64>) -> rusqlite::Result<String> {
    let Some(artifact_id) = artifact_id else {
        return Ok(String::new());
    };
    connection
        .query_row(
            "SELECT path FROM swarm_artifacts WHERE id = ?1",
            params![artifact_id],
            |row| row.get(0),
        )
        .optional()
        .map(|value| value.unwrap_or_default())
}

struct NativeCommandOutcome {
    exit_code: i64,
    status: String,
    timed_out: bool,
    stdout_reader_finished: bool,
    stderr_reader_finished: bool,
    reader_errors: Vec<String>,
}

fn timeout_duration(timeout_ms: i64) -> Duration {
    Duration::from_millis(timeout_ms.max(1) as u64)
}

fn reader_timeout_grace_duration() -> Duration {
    Duration::from_millis(150)
}

fn configure_killable_command(command: &mut ProcessCommand) {
    #[cfg(unix)]
    unsafe {
        command.pre_exec(|| {
            if setsid() < 0 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
}

#[cfg(unix)]
fn signal_process_group(child_id: u32, signal: c_int) {
    if child_id > c_int::MAX as u32 {
        return;
    }
    let pgid = -(child_id as c_int);
    unsafe {
        let _ = kill(pgid, signal);
    }
}

#[cfg(not(unix))]
fn signal_process_group(_child_id: u32, _signal: i32) {}

fn terminate_child_tree(child: &mut Child, child_id: u32) {
    #[cfg(unix)]
    {
        signal_process_group(child_id, SIGTERM);
        let _ = child.kill();
        thread::sleep(Duration::from_millis(50));
        signal_process_group(child_id, SIGKILL);
        let _ = child.kill();
    }
    #[cfg(not(unix))]
    {
        let _ = child.kill();
    }
}

fn wait_child_until(child: &mut Child, deadline: Instant) -> Result<Option<ExitStatus>, String> {
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(Some(status)),
            Ok(None) => {
                let now = Instant::now();
                if now >= deadline {
                    return Ok(None);
                }
                let remaining = deadline.saturating_duration_since(now);
                thread::sleep(remaining.min(Duration::from_millis(10)));
            }
            Err(err) => return Err(format!("failed to wait for swarm command: {err}")),
        }
    }
}

fn spawn_pipe_reader<R>(mut reader: R, path: PathBuf, label: &'static str) -> Receiver<Result<u64, String>>
where
    R: Read + Send + 'static,
{
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let result = (|| -> Result<u64, String> {
            let mut file = File::create(&path)
                .map_err(|err| format!("failed to create swarm {label} artifact `{}`: {err}", path.display()))?;
            let mut buffer = [0u8; 8192];
            let mut total = 0u64;
            loop {
                let read = reader
                    .read(&mut buffer)
                    .map_err(|err| format!("failed to read swarm {label}: {err}"))?;
                if read == 0 {
                    break;
                }
                file.write_all(&buffer[..read])
                    .map_err(|err| format!("failed to write swarm {label} artifact `{}`: {err}", path.display()))?;
                file.flush()
                    .map_err(|err| format!("failed to flush swarm {label} artifact `{}`: {err}", path.display()))?;
                total += read as u64;
            }
            Ok(total)
        })();
        let _ = sender.send(result);
    });
    receiver
}

fn try_pipe_reader(receiver: &Receiver<Result<u64, String>>, label: &str) -> Option<(bool, Option<String>)> {
    match receiver.try_recv() {
        Ok(Ok(_)) => Some((true, None)),
        Ok(Err(message)) => Some((true, Some(message))),
        Err(TryRecvError::Empty) => None,
        Err(TryRecvError::Disconnected) => Some((true, Some(format!("swarm {label} reader disconnected")))),
    }
}

fn wait_pipe_readers_until(
    stdout_rx: &Receiver<Result<u64, String>>,
    stderr_rx: &Receiver<Result<u64, String>>,
    deadline: Instant,
    stdout_reader_finished: &mut bool,
    stdout_reader_error: &mut Option<String>,
    stderr_reader_finished: &mut bool,
    stderr_reader_error: &mut Option<String>,
) {
    loop {
        if !*stdout_reader_finished {
            if let Some((finished, error)) = try_pipe_reader(stdout_rx, "stdout") {
                *stdout_reader_finished = finished;
                *stdout_reader_error = error;
            }
        }
        if !*stderr_reader_finished {
            if let Some((finished, error)) = try_pipe_reader(stderr_rx, "stderr") {
                *stderr_reader_finished = finished;
                *stderr_reader_error = error;
            }
        }
        if *stdout_reader_finished && *stderr_reader_finished {
            return;
        }

        let now = Instant::now();
        if now >= deadline {
            if !*stdout_reader_finished && stdout_reader_error.is_none() {
                *stdout_reader_error = Some("swarm stdout reader did not finish before the bounded wait elapsed".to_owned());
            }
            if !*stderr_reader_finished && stderr_reader_error.is_none() {
                *stderr_reader_error = Some("swarm stderr reader did not finish before the bounded wait elapsed".to_owned());
            }
            return;
        }
        let remaining = deadline.saturating_duration_since(now);
        thread::sleep(remaining.min(Duration::from_millis(10)));
    }
}

fn run_command_with_timeout_to_artifacts(
    cwd: &Path,
    command: &[String],
    stdout_path: &Path,
    stderr_path: &Path,
    timeout_ms: i64,
) -> Result<NativeCommandOutcome, String> {
    fs::write(stdout_path, [])
        .map_err(|err| format!("failed to initialize swarm stdout artifact `{}`: {err}", stdout_path.display()))?;
    fs::write(stderr_path, [])
        .map_err(|err| format!("failed to initialize swarm stderr artifact `{}`: {err}", stderr_path.display()))?;

    let mut process = ProcessCommand::new(&command[0]);
    process
        .args(&command[1..])
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    configure_killable_command(&mut process);

    let mut child = process
        .spawn()
        .map_err(|err| format!("failed to execute swarm command `{}`: {err}", command[0]))?;
    let child_id = child.id();
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "failed to capture swarm stdout".to_owned())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "failed to capture swarm stderr".to_owned())?;
    let stdout_rx = spawn_pipe_reader(stdout, stdout_path.to_path_buf(), "stdout");
    let stderr_rx = spawn_pipe_reader(stderr, stderr_path.to_path_buf(), "stderr");

    let deadline = Instant::now() + timeout_duration(timeout_ms);
    let mut timed_out = false;
    let mut status = match wait_child_until(&mut child, deadline)? {
        Some(status) => Some(status),
        None => {
            timed_out = true;
            terminate_child_tree(&mut child, child_id);
            wait_child_until(&mut child, Instant::now() + Duration::from_millis(200))?
        }
    };
    if timed_out {
        terminate_child_tree(&mut child, child_id);
        if status.is_none() {
            status = wait_child_until(&mut child, Instant::now() + Duration::from_millis(200))?;
        }
    }

    let mut stdout_reader_finished = false;
    let mut stdout_reader_error = None;
    let mut stderr_reader_finished = false;
    let mut stderr_reader_error = None;
    let reader_deadline = if timed_out {
        Instant::now() + reader_timeout_grace_duration()
    } else {
        deadline
    };
    wait_pipe_readers_until(
        &stdout_rx,
        &stderr_rx,
        reader_deadline,
        &mut stdout_reader_finished,
        &mut stdout_reader_error,
        &mut stderr_reader_finished,
        &mut stderr_reader_error,
    );
    if !timed_out && (!stdout_reader_finished || !stderr_reader_finished) {
        timed_out = true;
        terminate_child_tree(&mut child, child_id);
        wait_pipe_readers_until(
            &stdout_rx,
            &stderr_rx,
            Instant::now() + reader_timeout_grace_duration(),
            &mut stdout_reader_finished,
            &mut stdout_reader_error,
            &mut stderr_reader_finished,
            &mut stderr_reader_error,
        );
    }
    let mut reader_errors = Vec::new();
    if let Some(message) = stdout_reader_error {
        reader_errors.push(message);
    }
    if let Some(message) = stderr_reader_error {
        reader_errors.push(message);
    }

    let exit_code = if timed_out {
        124
    } else {
        status.and_then(|value| value.code()).unwrap_or(1) as i64
    };
    let status_text = if timed_out {
        "timed_out"
    } else if exit_code == 0 {
        "passed"
    } else {
        "failed"
    };
    Ok(NativeCommandOutcome {
        exit_code,
        status: status_text.to_owned(),
        timed_out,
        stdout_reader_finished,
        stderr_reader_finished,
        reader_errors,
    })
}

fn run_native_command(
    connection: &mut Connection,
    paths: &SwarmRuntimePaths,
    task_id: &str,
    actor: &str,
    role: &str,
    name: &str,
    cwd: &Path,
    command: &[String],
    timeout_ms: Option<i64>,
) -> Result<SwarmRunRecord, String> {
    let at_ms = now_ms();
    let (_, spec) = if role == "verifier" {
        require_unexpired_lease_owner(connection, task_id, actor, &format!("run {role} `{name}`"), at_ms)?
    } else {
        require_active_lease_owner(connection, task_id, actor, &format!("run {role} `{name}`"), at_ms)?
    };
    if let Some(spec) = spec {
        if deadline_expired(spec.deadline_at_ms, now_ms()) {
            return Err(format!("swarm task `{task_id}` missed its deadline"));
        }
        if spec.max_runs > 0 && task_run_count(connection, task_id)? >= spec.max_runs {
            return Err(format!("swarm task `{task_id}` exhausted its run budget"));
        }
        if let Some(objective) = load_objective(connection, &spec.objective_id)? {
            if deadline_expired(objective.deadline_at_ms, now_ms()) {
                return Err(format!("swarm objective `{}` missed its deadline", objective.objective_id));
            }
            if objective.max_runs > 0 && objective_run_count(connection, &objective.objective_id)? >= objective.max_runs {
                return Err(format!("swarm objective `{}` exhausted its run budget", objective.objective_id));
            }
        }
    }

    let run_id = insert_run(connection, task_id, role, actor, name, cwd, command)?;
    let started_at_ms = now_ms();
    let start_kind = if role == "verifier" { "verifier_run_started" } else { "tool_run_started" };
    let finish_kind = if role == "verifier" { "verifier_run_finished" } else { "tool_run_finished" };
    let _ = record_swarm_event(
        connection,
        start_kind,
        task_id,
        actor,
        &format!("Run {role} `{name}`."),
        json!({ "runId": run_id, "cwd": cwd.display().to_string(), "command": command }),
    )?;

    let stdout_path = next_artifact_path(paths, task_id, run_id, "stdout");
    let stderr_path = next_artifact_path(paths, task_id, run_id, "stderr");
    let outcome = if let Some(timeout_ms) = timeout_ms {
        run_command_with_timeout_to_artifacts(cwd, command, &stdout_path, &stderr_path, timeout_ms)?
    } else {
        let output = ProcessCommand::new(&command[0])
            .args(&command[1..])
            .current_dir(cwd)
            .output()
            .map_err(|err| format!("failed to execute swarm {role} command `{}`: {err}", command[0]))?;
        fs::write(&stdout_path, &output.stdout)
            .map_err(|err| format!("failed to write swarm stdout artifact `{}`: {err}", stdout_path.display()))?;
        fs::write(&stderr_path, &output.stderr)
            .map_err(|err| format!("failed to write swarm stderr artifact `{}`: {err}", stderr_path.display()))?;
        let exit_code = output.status.code().unwrap_or(1) as i64;
        NativeCommandOutcome {
            exit_code,
            status: if output.status.success() { "passed" } else { "failed" }.to_owned(),
            timed_out: false,
            stdout_reader_finished: true,
            stderr_reader_finished: true,
            reader_errors: Vec::new(),
        }
    };
    let ended_at_ms = now_ms();
    let artifact_metadata = json!({
        "runId": run_id,
        "role": role,
        "name": name,
        "timedOut": outcome.timed_out,
        "timeoutMs": timeout_ms.unwrap_or(0),
        "stdoutReaderFinished": outcome.stdout_reader_finished,
        "stderrReaderFinished": outcome.stderr_reader_finished,
        "readerErrors": outcome.reader_errors.clone(),
    });
    let stdout_artifact_id = create_artifact(
        connection,
        task_id,
        "stdout",
        &stdout_path,
        artifact_metadata.clone(),
    )?;
    let stderr_artifact_id = create_artifact(
        connection,
        task_id,
        "stderr",
        &stderr_path,
        artifact_metadata.clone(),
    )?;
    let exit_code = outcome.exit_code;
    let status = outcome.status.as_str();
    finish_run(connection, run_id, exit_code, status, stdout_artifact_id, stderr_artifact_id)?;
    let _ = record_swarm_event(
        connection,
        finish_kind,
        task_id,
        actor,
        &format!("Finished {role} `{name}` with status {status}."),
        json!({
            "runId": run_id,
            "exitCode": exit_code,
            "status": status,
            "timedOut": outcome.timed_out,
            "timeoutMs": timeout_ms.unwrap_or(0),
            "stdoutReaderFinished": outcome.stdout_reader_finished,
            "stderrReaderFinished": outcome.stderr_reader_finished,
            "readerErrors": outcome.reader_errors.clone(),
            "stdoutArtifactPath": stdout_path.display().to_string(),
            "stderrArtifactPath": stderr_path.display().to_string()
        }),
    )?;

    Ok(SwarmRunRecord {
        run_id,
        task_id: task_id.to_owned(),
        role: role.to_owned(),
        actor: actor.to_owned(),
        name: name.to_owned(),
        cwd: cwd.display().to_string(),
        command: command.to_vec(),
        exit_code,
        status: status.to_owned(),
        started_at_ms,
        ended_at_ms,
        stdout_artifact_path: stdout_path.display().to_string(),
        stderr_artifact_path: stderr_path.display().to_string(),
    })
}

fn run_json(run: &SwarmRunRecord) -> Value {
    json!({
        "runId": run.run_id,
        "taskId": run.task_id,
        "role": run.role,
        "actor": run.actor,
        "name": run.name,
        "cwd": run.cwd,
        "command": run.command,
        "exitCode": run.exit_code,
        "status": run.status,
        "timedOut": run.status == "timed_out",
        "startedAtMs": run.started_at_ms,
        "endedAtMs": run.ended_at_ms,
        "stdoutArtifactPath": run.stdout_artifact_path,
        "stderrArtifactPath": run.stderr_artifact_path,
    })
}

fn insert_approval(
    connection: &mut Connection,
    task_id: &str,
    actor: &str,
    approval_name: &str,
    detail: &str,
) -> Result<SwarmApprovalRecord, String> {
    if load_task_state(connection, task_id)?.is_none() {
        return Err(format!("unknown swarm task `{task_id}`"));
    }
    let at_ms = now_ms();
    let payload = json!({ "name": approval_name });
    connection
        .execute(
            "
            INSERT INTO swarm_approvals (task_id, name, actor, detail, at_ms, payload_json)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ",
            params![task_id, approval_name, actor, detail, at_ms, payload.to_string()],
        )
        .map_err(|err| format!("failed to record swarm approval `{approval_name}`: {err}"))?;
    let approval_id = connection.last_insert_rowid();
    let _ = record_swarm_event(
        connection,
        "approval_granted",
        task_id,
        actor,
        detail,
        json!({ "approvalId": approval_id, "name": approval_name }),
    )?;
    Ok(SwarmApprovalRecord {
        approval_id,
        task_id: task_id.to_owned(),
        name: approval_name.to_owned(),
        actor: actor.to_owned(),
        detail: detail.to_owned(),
        at_ms,
        payload_json: payload.to_string(),
    })
}

fn task_detail_for_kind(kind: &str, task_id: &str) -> String {
    match kind {
        "task_created" => "Initialize swarm state.".to_owned(),
        "lease_acquired" => format!("Acquire lease for {task_id}."),
        "lease_released" => format!("Release lease for {task_id}."),
        "worker_heartbeat" => format!("Heartbeat for {task_id}."),
        "task_completed" => format!("Complete task {task_id}."),
        "task_failed" => format!("Fail task {task_id}."),
        "task_requeued" => format!("Requeue task {task_id}."),
        "task_stopped" => format!("Stop task {task_id}."),
        "task_resumed" => format!("Resume task {task_id}."),
        _ => format!("Update task {task_id}."),
    }
}

fn string_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn bool_field(value: &Value, key: &str) -> Option<bool> {
    value.get(key).and_then(Value::as_bool)
}

fn i64_field(value: &Value, key: &str) -> Option<i64> {
    value.get(key).and_then(Value::as_i64)
}

fn string_list(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn format_event_line(value: &Value) -> Option<String> {
    let kind = string_field(value, "kind")?;
    let task_id = string_field(value, "taskId").unwrap_or("unknown");
    let actor = string_field(value, "actor").unwrap_or("unknown");
    let detail = string_field(value, "detail").unwrap_or_default();
    let at_ms = i64_field(value, "atMs").unwrap_or(0);
    Some(format!("[{at_ms}] {task_id} {kind} by {actor}: {detail}"))
}

fn format_task_text(value: &Value) -> String {
    let task_id = string_field(value, "taskId").unwrap_or("unknown");
    let status = string_field(value, "status").unwrap_or("unknown");
    let mut lines = vec![format!("task {task_id}"), format!("  status: {status}")];
    if let Some(detail) = string_field(value, "detail") {
        if !detail.is_empty() {
            lines.push(format!("  detail: {detail}"));
        }
    }
    if let Some(objective_id) = string_field(value, "objectiveId") {
        if !objective_id.is_empty() {
            lines.push(format!("  objective: {objective_id}"));
        }
    }
    if let Some(lease_actor) = string_field(value, "leaseActor") {
        if !lease_actor.is_empty() {
            lines.push(format!("  lease actor: {lease_actor}"));
        }
    }
    if let Some(attempts) = i64_field(value, "attempts") {
        lines.push(format!("  attempts: {attempts}"));
    }
    if let Some(ready) = bool_field(value, "ready") {
        lines.push(format!("  ready: {ready}"));
    }
    if let Some(lease_expired) = bool_field(value, "leaseExpired") {
        if lease_expired {
            lines.push("  lease: expired".to_owned());
        }
    }
    let dependencies = string_list(value.get("dependencies"));
    if !dependencies.is_empty() {
        lines.push(format!("  dependencies: {}", dependencies.join(", ")));
    }
    let blocked = string_list(value.get("blockedBy"));
    if !blocked.is_empty() {
        lines.push(format!("  blocked: {}", blocked.join("; ")));
    }
    if let Some(merge_policy) = value.get("mergePolicy") {
        if let Some(mergegate_name) = string_field(merge_policy, "mergegateName") {
            let satisfied = bool_field(merge_policy, "satisfied").unwrap_or(false);
            lines.push(format!("  merge policy: {mergegate_name} satisfied={satisfied}"));
        }
        let missing_approvals = string_list(merge_policy.get("missingApprovals"));
        if !missing_approvals.is_empty() {
            lines.push(format!("  missing approvals: {}", missing_approvals.join(", ")));
        }
        let missing_verifiers = string_list(merge_policy.get("missingVerifiers"));
        if !missing_verifiers.is_empty() {
            lines.push(format!("  missing verifiers: {}", missing_verifiers.join(", ")));
        }
    }
    lines.join("\n")
}

fn format_approval_text(value: &Value) -> String {
    let task_id = string_field(value, "taskId").unwrap_or("unknown");
    let name = string_field(value, "name").unwrap_or("unknown");
    let actor = string_field(value, "actor").unwrap_or("unknown");
    let mut lines = vec![format!("approval {task_id} {name}"), format!("  actor: {actor}")];
    if let Some(detail) = string_field(value, "detail") {
        if !detail.is_empty() {
            lines.push(format!("  detail: {detail}"));
        }
    }
    lines.join("\n")
}

fn format_run_text(value: &Value) -> String {
    let role = string_field(value, "role").unwrap_or("run");
    let task_id = string_field(value, "taskId").unwrap_or("unknown");
    let name = string_field(value, "name").unwrap_or("unknown");
    let status = string_field(value, "status").unwrap_or("unknown");
    let exit_code = i64_field(value, "exitCode").unwrap_or(-1);
    format!("{role} {task_id} {name} status={status} exit={exit_code}")
}

fn format_artifact_text(value: &Value) -> String {
    let task_id = string_field(value, "taskId").unwrap_or("unknown");
    let kind = string_field(value, "kind").unwrap_or("artifact");
    let path = string_field(value, "path").unwrap_or_default();
    format!("artifact {task_id} {kind} {path}")
}

fn format_objective_text(value: &Value) -> String {
    let objective_id = string_field(value, "objectiveId").unwrap_or("unknown");
    let projected_status = string_field(value, "projectedStatus")
        .or_else(|| string_field(value, "status"))
        .unwrap_or("unknown");
    let task_count = i64_field(value, "taskCount").unwrap_or(0);
    format!("objective {objective_id} status={projected_status} tasks={task_count}")
}

fn format_manager_next_text(value: &Value) -> String {
    let objective_id = string_field(value, "objectiveId").unwrap_or("unknown");
    let status = string_field(value, "status").unwrap_or("unknown");
    let action = string_field(value, "action").unwrap_or("unknown");
    let mut lines = vec![format!("objective {objective_id}"), format!("  status: {status}"), format!("  action: {action}")];
    if let Some(task_id) = string_field(value, "taskId") {
        if !task_id.is_empty() {
            lines.push(format!("  task: {task_id}"));
        }
    }
    if let Some(approval) = string_field(value, "approval") {
        if !approval.is_empty() {
            lines.push(format!("  approval: {approval}"));
        }
    }
    if let Some(verifier) = string_field(value, "verifier") {
        if !verifier.is_empty() {
            lines.push(format!("  verifier: {verifier}"));
        }
    }
    if let Some(mergegate_name) = string_field(value, "mergegateName") {
        if !mergegate_name.is_empty() {
            lines.push(format!("  mergegate: {mergegate_name}"));
        }
    }
    if let Some(task_status) = string_field(value, "taskStatus") {
        if !task_status.is_empty() {
            lines.push(format!("  task status: {task_status}"));
        }
    }
    if let Some(latest_verifier_status) = string_field(value, "latestVerifierStatus") {
        if !latest_verifier_status.is_empty() {
            lines.push(format!("  latest verifier: {latest_verifier_status}"));
        }
    }
    if let Some(mergegate_verdict) = string_field(value, "mergegateVerdict") {
        if !mergegate_verdict.is_empty() {
            lines.push(format!("  mergegate verdict: {mergegate_verdict}"));
        }
    }
    let suggested_command = string_list(value.get("suggestedCommand"));
    if !suggested_command.is_empty() {
        lines.push(format!("  command: {}", suggested_command.join(" ")));
    }
    let blocked = string_list(value.get("blockedBy"));
    if !blocked.is_empty() {
        lines.push(format!("  blocked: {}", blocked.join("; ")));
    }
    let blockers = string_list(value.get("blockerTaskIds"));
    if !blockers.is_empty() {
        lines.push(format!("  blocker tasks: {}", blockers.join(", ")));
    }
    lines.join("\n")
}

fn format_objective_status_text(value: &Value) -> String {
    let Some(objective) = value.get("objective") else {
        return value.to_string();
    };
    let projected_status = string_field(value, "projectedStatus").unwrap_or("unknown");
    let objective_id = string_field(objective, "objectiveId").unwrap_or("unknown");
    let task_count = value
        .get("tasks")
        .and_then(Value::as_array)
        .map(|tasks| tasks.len())
        .unwrap_or(0);
    format!("objective {objective_id} status={projected_status} tasks={task_count}")
}

fn render_swarm_text(value: &Value) -> String {
    match value {
        Value::Array(entries) => {
            if entries.is_empty() {
                return "no records".to_owned();
            }
            entries
                .iter()
                .map(|entry| {
                    if entry.get("kind").is_some() && entry.get("taskId").is_some() {
                        format_event_line(entry).unwrap_or_else(|| entry.to_string())
                    } else if entry.get("approvalId").is_some() {
                        format_approval_text(entry)
                    } else if entry.get("runId").is_some() {
                        format_run_text(entry)
                    } else if entry.get("artifactId").is_some() {
                        format_artifact_text(entry)
                    } else if entry.get("objectiveId").is_some() && entry.get("projectedStatus").is_some() {
                        format_objective_text(entry)
                    } else if entry.get("taskId").is_some() && entry.get("status").is_some() {
                        format_task_text(entry)
                    } else {
                        entry.to_string()
                    }
                })
                .collect::<Vec<_>>()
                .join("\n")
        }
        Value::Object(_) => {
            if let Some(event) = value.get("event") {
                let mut lines = vec![format_event_line(event).unwrap_or_else(|| event.to_string())];
                if let Some(task) = value.get("task") {
                    lines.push(format_task_text(task));
                }
                lines.join("\n")
            } else if value.get("approvalId").is_some() {
                format_approval_text(value)
            } else if value.get("runId").is_some() {
                format_run_text(value)
            } else if value.get("artifactId").is_some() {
                format_artifact_text(value)
            } else if value.get("objective").is_some() && value.get("tasks").is_some() {
                format_objective_status_text(value)
            } else if value.get("objectiveId").is_some() && value.get("action").is_some() {
                format_manager_next_text(value)
            } else if value.get("objectiveId").is_some() && value.get("projectedStatus").is_some() {
                format_objective_text(value)
            } else if value.get("taskId").is_some() && value.get("status").is_some() {
                format_task_text(value)
            } else {
                value.to_string()
            }
        }
        Value::String(text) => text.clone(),
        _ => value.to_string(),
    }
}

fn print_output(value: &Value, json_mode: bool) {
    if json_mode {
        println!("{value}");
    } else {
        println!("{}", render_swarm_text(value));
    }
}

fn fail(message: &str, json_mode: bool) -> ExitCode {
    if json_mode {
        println!("{}", json!({ "status": "error", "error": message }));
    } else {
        eprintln!("{message}");
    }
    ExitCode::from(1)
}

fn execute_event_command(
    root: &Path,
    task_id: &str,
    actor: &str,
    kind: &str,
    explicit_detail: &Option<String>,
) -> Result<Value, String> {
    let (paths, mut connection) = open_swarm_connection(root)?;
    let at_ms = now_ms();
    if kind == "lease_acquired" {
        let Some(task) = load_task_state(&connection, task_id)? else {
            return Err(format!("unknown swarm task `{task_id}`"));
        };
        let (ready, lease_expired, blocked, _, _) = task_ready_state(&connection, &task, at_ms)?;
        if !ready {
            return Err(format!("swarm task `{task_id}` is not ready: {}", blocked.join("; ")));
        }
        if (task.status == "leased" || task.status == "active") && !lease_expired {
            return Err(format!("swarm task `{task_id}` already has an active lease"));
        }
    } else if kind == "lease_released" {
        let _ = require_active_lease_owner(&connection, task_id, actor, "release its lease", at_ms)?;
    } else if kind == "worker_heartbeat" {
        let _ = require_active_lease_owner(&connection, task_id, actor, "record a heartbeat", at_ms)?;
    } else if kind == "task_completed" {
        let _ = require_completion_lease_owner(&connection, task_id, actor, at_ms)?;
    } else if kind == "task_failed" {
        let _ = require_recorded_lease_owner(&connection, task_id, actor, "fail")?;
    } else if kind == "task_requeued" {
        require_manager_actor(&connection, task_id, actor, "requeue")?;
        widen_retry_run_budget(&connection, task_id, at_ms)?;
    } else if kind == "task_stopped" {
        require_manager_actor(&connection, task_id, actor, "stop")?;
    } else if kind == "task_resumed" {
        require_manager_actor(&connection, task_id, actor, "resume")?;
    }
    let detail = explicit_detail
        .clone()
        .unwrap_or_else(|| task_detail_for_kind(kind, task_id));
    let event = SwarmEvent {
        kind: kind.to_owned(),
        task_id: task_id.to_owned(),
        actor: actor.to_owned(),
        detail,
        at_ms,
        payload_json: "{}".to_owned(),
    };
    let task = append_event(&mut connection, &event)?;
    let rendered_task = task_record_json(&connection, &task)?;
    Ok(swarm_event_output(&paths, &event, rendered_task))
}

fn handle_event_command(
    json_mode: bool,
    root: &Path,
    task_id: &str,
    actor: &str,
    kind: &str,
    explicit_detail: &Option<String>,
) -> ExitCode {
    match execute_event_command(root, task_id, actor, kind, explicit_detail) {
        Ok(value) => {
            print_output(&value, json_mode);
            ExitCode::SUCCESS
        }
        Err(message) => fail(&message, json_mode),
    }
}

fn execute_query_command(command: SwarmCommand) -> Result<Value, String> {
    let root = match &command {
        SwarmCommand::Status { root, .. }
        | SwarmCommand::History { root, .. }
        | SwarmCommand::Tasks { root }
        | SwarmCommand::Summary { root }
        | SwarmCommand::Tail { root, .. }
        | SwarmCommand::Runs { root, .. }
        | SwarmCommand::MemoryQuery { root, .. }
        | SwarmCommand::ObjectiveStatus { root, .. }
        | SwarmCommand::Objectives { root }
        | SwarmCommand::Ready { root, .. }
        | SwarmCommand::Approvals { root, .. }
        | SwarmCommand::Artifacts { root, .. }
        | SwarmCommand::ManagerNext { root, .. } => root,
        _ => unreachable!(),
    };
    let (_paths, connection) = open_swarm_connection(root)?;
    match command {
        SwarmCommand::Status { task_id, .. } =>
            match load_task_state(&connection, &task_id)? {
                Some(task) => task_record_json(&connection, &task),
                None => task_record_json(&connection, &empty_task_state(&task_id, 0)),
            },
        SwarmCommand::History { task_id, .. } => history_json(&connection, &task_id),
        SwarmCommand::Tasks { .. } => tasks_json(&connection),
        SwarmCommand::ObjectiveStatus { objective_id, .. } => objective_status_json(&connection, &objective_id),
        SwarmCommand::Objectives { .. } => objectives_json(&connection),
        SwarmCommand::Ready { objective_id, .. } => ready_json(&connection, objective_id.as_deref()),
        SwarmCommand::Summary { .. } => summary_json(&connection),
        SwarmCommand::Tail { task_id, limit, .. } => tail_json(&connection, task_id.as_deref(), limit),
        SwarmCommand::Runs { task_id, .. } => runs_json(&connection, task_id.as_deref()),
        SwarmCommand::Artifacts { task_id, .. } => artifacts_json(&connection, task_id.as_deref()),
        SwarmCommand::MemoryQuery { objective_id, task_id, key, limit, .. } =>
            memory_query_json(&connection, objective_id.as_deref(), task_id.as_deref(), key.as_deref(), limit),
        SwarmCommand::Approvals { task_id, .. } => approvals_json(&connection, task_id.as_deref()),
        SwarmCommand::ManagerNext { objective_id, .. } => manager_next_json(&connection, &objective_id),
        _ => unreachable!(),
    }
}

fn handle_query_command(json_mode: bool, command: SwarmCommand) -> ExitCode {
    match execute_query_command(command) {
        Ok(value) => {
            print_output(&value, json_mode);
            ExitCode::SUCCESS
        }
        Err(message) => fail(&message, json_mode),
    }
}

fn execute_approve_command(
    root: &Path,
    task_id: &str,
    actor: &str,
    approval_name: &str,
    explicit_detail: &Option<String>,
) -> Result<Value, String> {
    let (_paths, mut connection) = open_swarm_connection(root)?;
    let detail = explicit_detail
        .clone()
        .unwrap_or_else(|| format!("Approve `{approval_name}` for {task_id}."));
    let approval = insert_approval(&mut connection, task_id, actor, approval_name, &detail)?;
    Ok(approval_json(&approval))
}

fn handle_approve_command(
    json_mode: bool,
    root: &Path,
    task_id: &str,
    actor: &str,
    approval_name: &str,
    explicit_detail: &Option<String>,
) -> ExitCode {
    match execute_approve_command(root, task_id, actor, approval_name, explicit_detail) {
        Ok(value) => {
            print_output(&value, json_mode);
            ExitCode::SUCCESS
        }
        Err(message) => fail(&message, json_mode),
    }
}

fn execute_memory_put(
    root: &Path,
    objective_id: &str,
    task_id: &str,
    actor: &str,
    key: &str,
    value: &str,
) -> Result<Value, String> {
    let (_paths, mut connection) = open_swarm_connection(root)?;
    let memory = insert_memory(&mut connection, objective_id, task_id, actor, key, value)?;
    Ok(memory_json(&memory))
}

fn execute_objective_create(
    root: &Path,
    objective_id: &str,
    detail: &str,
    max_tasks: i64,
    max_runs: i64,
    deadline_at_ms: i64,
) -> Result<Value, String> {
    let (_paths, connection) = open_swarm_connection(root)?;
    let objective = ensure_objective(&connection, objective_id, detail, max_tasks, max_runs, deadline_at_ms)?;
    objective_json(&connection, &objective)
}

fn handle_objective_create(
    json_mode: bool,
    root: &Path,
    objective_id: &str,
    detail: &str,
    max_tasks: i64,
    max_runs: i64,
    deadline_at_ms: i64,
) -> ExitCode {
    match execute_objective_create(root, objective_id, detail, max_tasks, max_runs, deadline_at_ms) {
        Ok(value) => {
            print_output(&value, json_mode);
            ExitCode::SUCCESS
        }
        Err(message) => fail(&message, json_mode),
    }
}

fn execute_task_create(
    root: &Path,
    objective_id: &str,
    task_id: &str,
    detail: &str,
    dependencies: &[String],
    max_runs: i64,
    deadline_at_ms: i64,
    lease_timeout_ms: i64,
) -> Result<Value, String> {
    let (_paths, mut connection) = open_swarm_connection(root)?;
    let _spec = match insert_task_spec(
        &mut connection,
        objective_id,
        task_id,
        detail,
        dependencies,
        max_runs,
        deadline_at_ms,
        lease_timeout_ms,
    ) {
        Ok(value) => value,
        Err(message) => return Err(message),
    };
    let task = match load_task_state(&connection, task_id)? {
        Some(value) => value,
        None => empty_task_state(task_id, 0),
    };
    task_record_json(&connection, &task)
}

fn handle_task_create(
    json_mode: bool,
    root: &Path,
    objective_id: &str,
    task_id: &str,
    detail: &str,
    dependencies: &[String],
    max_runs: i64,
    deadline_at_ms: i64,
    lease_timeout_ms: i64,
) -> ExitCode {
    match execute_task_create(root, objective_id, task_id, detail, dependencies, max_runs, deadline_at_ms, lease_timeout_ms) {
        Ok(value) => {
            print_output(&value, json_mode);
            ExitCode::SUCCESS
        }
        Err(message) => fail(&message, json_mode),
    }
}

fn execute_policy_set(
    root: &Path,
    task_id: &str,
    mergegate_name: &str,
    required_approvals: &[String],
    required_verifiers: &[String],
) -> Result<Value, String> {
    let (_paths, mut connection) = open_swarm_connection(root)?;
    let policy = store_merge_policy(&connection, task_id, mergegate_name, required_approvals, required_verifiers)?;
    let _ = record_swarm_event(
        &mut connection,
        "merge_policy_set",
        task_id,
        "manager",
        &format!("Set merge policy `{mergegate_name}` for {task_id}."),
        json!({
            "mergegateName": mergegate_name,
            "requiredApprovals": required_approvals,
            "requiredVerifiers": required_verifiers,
        }),
    );
    Ok(json!({
        "taskId": policy.task_id,
        "mergegateName": policy.mergegate_name,
        "requiredApprovals": decode_string_list(&policy.required_approvals_json),
        "requiredVerifiers": decode_string_list(&policy.required_verifiers_json),
        "createdAtMs": policy.created_at_ms,
        "updatedAtMs": policy.updated_at_ms,
    }))
}

fn handle_policy_set(
    json_mode: bool,
    root: &Path,
    task_id: &str,
    mergegate_name: &str,
    required_approvals: &[String],
    required_verifiers: &[String],
) -> ExitCode {
    match execute_policy_set(root, task_id, mergegate_name, required_approvals, required_verifiers) {
        Ok(value) => {
            print_output(&value, json_mode);
            ExitCode::SUCCESS
        }
        Err(message) => fail(&message, json_mode),
    }
}

fn execute_tool_run(
    root: &Path,
    task_id: &str,
    actor: &str,
    cwd: &Path,
    command: &[String],
    timeout_ms: Option<i64>,
) -> Result<SwarmRunRecord, String> {
    let (paths, mut connection) = open_swarm_connection(root)?;
    run_native_command(&mut connection, &paths, task_id, actor, "tool", &command[0], cwd, command, timeout_ms)
}

fn handle_tool_run(
    json_mode: bool,
    root: &Path,
    task_id: &str,
    actor: &str,
    cwd: &Path,
    command: &[String],
    timeout_ms: Option<i64>,
) -> ExitCode {
    match execute_tool_run(root, task_id, actor, cwd, command, timeout_ms) {
        Ok(run) => {
            print_output(&run_json(&run), json_mode);
            if run.exit_code == 0 {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(run.exit_code as u8)
            }
        }
        Err(message) => fail(&message, json_mode),
    }
}

fn execute_verifier_run(
    root: &Path,
    task_id: &str,
    actor: &str,
    verifier_name: &str,
    cwd: &Path,
    command: &[String],
    timeout_ms: Option<i64>,
) -> Result<SwarmRunRecord, String> {
    let (paths, mut connection) = open_swarm_connection(root)?;
    run_native_command(
        &mut connection,
        &paths,
        task_id,
        actor,
        "verifier",
        verifier_name,
        cwd,
        command,
        timeout_ms,
    )
}

fn handle_verifier_run(
    json_mode: bool,
    root: &Path,
    task_id: &str,
    actor: &str,
    verifier_name: &str,
    cwd: &Path,
    command: &[String],
    timeout_ms: Option<i64>,
) -> ExitCode {
    match execute_verifier_run(root, task_id, actor, verifier_name, cwd, command, timeout_ms) {
        Ok(run) => {
            print_output(&run_json(&run), json_mode);
            if run.exit_code == 0 {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(run.exit_code as u8)
            }
        }
        Err(message) => fail(&message, json_mode),
    }
}

fn execute_mergegate_decide(
    root: &Path,
    task_id: &str,
    actor: &str,
    mergegate_name: &str,
    verifier_names: &[String],
) -> Result<(ExitCode, Value), String> {
    let (_paths, mut connection) = open_swarm_connection(root)?;
    let effective_verifier_names =
        effective_mergegate_verifier_names(&connection, task_id, mergegate_name, verifier_names)?;
    let mut verifier_states = Vec::new();
    let mut missing = false;
    let mut failed = false;
    for verifier_name in &effective_verifier_names {
        match latest_verifier_run(&connection, task_id, verifier_name) {
            Ok(Some(run)) => {
                let passed = run.exit_code == 0;
                if !passed {
                    failed = true;
                }
                verifier_states.push(json!({
                    "name": verifier_name,
                    "status": if passed { "passed" } else { "failed" },
                    "runId": run.run_id,
                    "exitCode": run.exit_code,
                    "stdoutArtifactPath": run.stdout_artifact_path,
                    "stderrArtifactPath": run.stderr_artifact_path,
                }));
            }
            Ok(None) => {
                missing = true;
                verifier_states.push(json!({
                    "name": verifier_name,
                    "status": "missing",
                    "runId": Value::Null,
                    "exitCode": Value::Null,
                }));
            }
            Err(message) => return Err(message),
        }
    }
    let verdict = if failed {
        "fail"
    } else if missing {
        "pending"
    } else {
        "pass"
    };
    let decision = json!({
        "taskId": task_id,
        "mergegateName": mergegate_name,
        "verdict": verdict,
        "detail": format!("Mergegate `{mergegate_name}` decided {verdict}."),
        "verifiers": verifier_states,
    });
    let _ = record_swarm_event(
        &mut connection,
        "mergegate_decision",
        task_id,
        actor,
        &format!("Mergegate `{mergegate_name}` decided {verdict}."),
        decision.clone(),
    );
    Ok((
        match verdict {
            "pass" => ExitCode::SUCCESS,
            "pending" => ExitCode::from(2),
            _ => ExitCode::from(1),
        },
        decision,
    ))
}

fn effective_mergegate_verifier_names(
    connection: &Connection,
    task_id: &str,
    mergegate_name: &str,
    verifier_names: &[String],
) -> Result<Vec<String>, String> {
    let mut names = Vec::new();
    if let Some(policy) = load_merge_policy(connection, task_id)? {
        if policy.mergegate_name == mergegate_name {
            for verifier_name in decode_string_list(&policy.required_verifiers_json) {
                if !names.iter().any(|name| name == &verifier_name) {
                    names.push(verifier_name);
                }
            }
        }
    }
    for verifier_name in verifier_names {
        if !names.iter().any(|name| name == verifier_name) {
            names.push(verifier_name.clone());
        }
    }
    Ok(names)
}

fn handle_mergegate_decide(
    json_mode: bool,
    root: &Path,
    task_id: &str,
    actor: &str,
    mergegate_name: &str,
    verifier_names: &[String],
) -> ExitCode {
    match execute_mergegate_decide(root, task_id, actor, mergegate_name, verifier_names) {
        Ok((exit_code, value)) => {
            print_output(&value, json_mode);
            exit_code
        }
        Err(message) => fail(&message, json_mode),
    }
}

fn execute_command(command: SwarmCommand) -> Result<(ExitCode, Value), String> {
    match command {
        SwarmCommand::Start { root, task_id, actor, detail }
        | SwarmCommand::Bootstrap { root, task_id, actor, detail } => {
            Ok((ExitCode::SUCCESS, execute_event_command(&root, &task_id, &actor, "task_created", &detail)?))
        }
        SwarmCommand::Lease { root, task_id, actor, detail } => {
            Ok((ExitCode::SUCCESS, execute_event_command(&root, &task_id, &actor, "lease_acquired", &detail)?))
        }
        SwarmCommand::Release { root, task_id, actor, detail } => {
            Ok((ExitCode::SUCCESS, execute_event_command(&root, &task_id, &actor, "lease_released", &detail)?))
        }
        SwarmCommand::Heartbeat { root, task_id, actor, detail } => {
            Ok((ExitCode::SUCCESS, execute_event_command(&root, &task_id, &actor, "worker_heartbeat", &detail)?))
        }
        SwarmCommand::Complete { root, task_id, actor, detail } => {
            Ok((ExitCode::SUCCESS, execute_event_command(&root, &task_id, &actor, "task_completed", &detail)?))
        }
        SwarmCommand::Fail { root, task_id, actor, detail } => {
            Ok((ExitCode::SUCCESS, execute_event_command(&root, &task_id, &actor, "task_failed", &detail)?))
        }
        SwarmCommand::Retry { root, task_id, actor, detail } => {
            Ok((ExitCode::SUCCESS, execute_event_command(&root, &task_id, &actor, "task_requeued", &detail)?))
        }
        SwarmCommand::Stop { root, task_id, actor, detail } => {
            Ok((ExitCode::SUCCESS, execute_event_command(&root, &task_id, &actor, "task_stopped", &detail)?))
        }
        SwarmCommand::Resume { root, task_id, actor, detail } => {
            Ok((ExitCode::SUCCESS, execute_event_command(&root, &task_id, &actor, "task_resumed", &detail)?))
        }
        SwarmCommand::Approve { root, task_id, actor, approval_name, detail } => {
            Ok((ExitCode::SUCCESS, execute_approve_command(&root, &task_id, &actor, &approval_name, &detail)?))
        }
        SwarmCommand::ObjectiveCreate { root, objective_id, detail, max_tasks, max_runs, deadline_at_ms } => {
            Ok((ExitCode::SUCCESS, execute_objective_create(&root, &objective_id, &detail, max_tasks, max_runs, deadline_at_ms)?))
        }
        SwarmCommand::TaskCreate {
            root,
            objective_id,
            task_id,
            detail,
            dependencies,
            max_runs,
            deadline_at_ms,
            lease_timeout_ms,
        } => Ok((
            ExitCode::SUCCESS,
            execute_task_create(&root, &objective_id, &task_id, &detail, &dependencies, max_runs, deadline_at_ms, lease_timeout_ms)?,
        )),
        SwarmCommand::PolicySet { root, task_id, mergegate_name, required_approvals, required_verifiers } => Ok((
            ExitCode::SUCCESS,
            execute_policy_set(&root, &task_id, &mergegate_name, &required_approvals, &required_verifiers)?,
        )),
        SwarmCommand::MemoryPut { root, objective_id, task_id, actor, key, value } => Ok((
            ExitCode::SUCCESS,
            execute_memory_put(&root, &objective_id, &task_id, &actor, &key, &value)?,
        )),
        SwarmCommand::Status { .. }
        | SwarmCommand::History { .. }
        | SwarmCommand::Tasks { .. }
        | SwarmCommand::Summary { .. }
        | SwarmCommand::Tail { .. }
        | SwarmCommand::Runs { .. }
        | SwarmCommand::MemoryQuery { .. }
        | SwarmCommand::ObjectiveStatus { .. }
        | SwarmCommand::Objectives { .. }
        | SwarmCommand::Ready { .. }
        | SwarmCommand::Approvals { .. }
        | SwarmCommand::Artifacts { .. }
        | SwarmCommand::ManagerNext { .. } => Ok((ExitCode::SUCCESS, execute_query_command(command)?)),
        SwarmCommand::ToolRun { root, task_id, actor, cwd, timeout_ms, command } => {
            let run = execute_tool_run(&root, &task_id, &actor, &cwd, &command, timeout_ms)?;
            let exit_code = if run.exit_code == 0 {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(run.exit_code as u8)
            };
            Ok((exit_code, run_json(&run)))
        }
        SwarmCommand::VerifierRun { root, task_id, actor, verifier_name, cwd, timeout_ms, command } => {
            let run = execute_verifier_run(&root, &task_id, &actor, &verifier_name, &cwd, &command, timeout_ms)?;
            let exit_code = if run.exit_code == 0 {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(run.exit_code as u8)
            };
            Ok((exit_code, run_json(&run)))
        }
        SwarmCommand::MergegateDecide { root, task_id, actor, mergegate_name, verifier_names } => {
            execute_mergegate_decide(&root, &task_id, &actor, &mergegate_name, &verifier_names)
        }
    }
}

pub fn run_swarm_json_command(args: &[String]) -> Result<(i32, String), String> {
    let mut cli_args = vec!["claspc".to_owned(), "--json".to_owned(), "swarm".to_owned()];
    cli_args.extend(args.iter().cloned());
    let (_, command) = parse_swarm_command(&cli_args)?
        .ok_or_else(|| "missing swarm subcommand".to_owned())?;
    let (exit_code, value) = execute_command(command)?;
    Ok((if exit_code == ExitCode::SUCCESS { 0 } else if exit_code == ExitCode::from(2) { 2 } else { 1 }, value.to_string()))
}

fn render_builtin_json(value: Value) -> Result<String, String> {
    serde_json::to_string(&value).map_err(|err| format!("failed to encode swarm json: {err}"))
}

fn render_builtin_query(command: SwarmCommand) -> Result<String, String> {
    render_builtin_json(execute_query_command(command)?)
}

fn render_builtin_event(root: &str, task_id: &str, actor: &str, kind: &str) -> Result<String, String> {
    render_builtin_json(execute_event_command(
        Path::new(root),
        task_id,
        actor,
        kind,
        &None,
    )?)
}

pub fn builtin_swarm_bootstrap(root: &str, task_id: &str, actor: &str) -> Result<String, String> {
    render_builtin_event(root, task_id, actor, "task_created")
}

pub fn builtin_swarm_start(root: &str, task_id: &str, actor: &str) -> Result<String, String> {
    render_builtin_event(root, task_id, actor, "task_created")
}

pub fn builtin_swarm_lease(root: &str, task_id: &str, actor: &str) -> Result<String, String> {
    render_builtin_event(root, task_id, actor, "lease_acquired")
}

pub fn builtin_swarm_release(root: &str, task_id: &str, actor: &str) -> Result<String, String> {
    render_builtin_event(root, task_id, actor, "lease_released")
}

pub fn builtin_swarm_heartbeat(root: &str, task_id: &str, actor: &str) -> Result<String, String> {
    render_builtin_event(root, task_id, actor, "worker_heartbeat")
}

pub fn builtin_swarm_complete(root: &str, task_id: &str, actor: &str) -> Result<String, String> {
    render_builtin_event(root, task_id, actor, "task_completed")
}

pub fn builtin_swarm_fail(root: &str, task_id: &str, actor: &str) -> Result<String, String> {
    render_builtin_event(root, task_id, actor, "task_failed")
}

pub fn builtin_swarm_retry(root: &str, task_id: &str, actor: &str) -> Result<String, String> {
    render_builtin_event(root, task_id, actor, "task_requeued")
}

pub fn builtin_swarm_stop(root: &str, task_id: &str, actor: &str) -> Result<String, String> {
    render_builtin_event(root, task_id, actor, "task_stopped")
}

pub fn builtin_swarm_resume(root: &str, task_id: &str, actor: &str) -> Result<String, String> {
    render_builtin_event(root, task_id, actor, "task_resumed")
}

pub fn builtin_swarm_status(root: &str, task_id: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::Status {
        root: PathBuf::from(root),
        task_id: task_id.to_owned(),
    })
}

pub fn builtin_swarm_history(root: &str, task_id: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::History {
        root: PathBuf::from(root),
        task_id: task_id.to_owned(),
    })
}

pub fn builtin_swarm_tasks(root: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::Tasks {
        root: PathBuf::from(root),
    })
}

pub fn builtin_swarm_summary(root: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::Summary {
        root: PathBuf::from(root),
    })
}

pub fn builtin_swarm_tail(root: &str, task_id: &str, limit: i64) -> Result<String, String> {
    let limit = if limit <= 0 { 0 } else { limit as usize };
    render_builtin_query(SwarmCommand::Tail {
        root: PathBuf::from(root),
        task_id: Some(task_id.to_owned()),
        limit,
    })
}

pub fn builtin_swarm_ready(root: &str, objective_id: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::Ready {
        root: PathBuf::from(root),
        objective_id: Some(objective_id.to_owned()),
    })
}

pub fn builtin_swarm_manager_next(root: &str, objective_id: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::ManagerNext {
        root: PathBuf::from(root),
        objective_id: objective_id.to_owned(),
    })
}

pub fn builtin_swarm_objective_create(
    root: &str,
    objective_id: &str,
    detail: &str,
    max_tasks: i64,
    max_runs: i64,
) -> Result<String, String> {
    builtin_swarm_objective_create_with_deadline(root, objective_id, detail, max_tasks, max_runs, 0)
}

pub fn builtin_swarm_objective_create_with_deadline(
    root: &str,
    objective_id: &str,
    detail: &str,
    max_tasks: i64,
    max_runs: i64,
    deadline_at_ms: i64,
) -> Result<String, String> {
    render_builtin_json(execute_objective_create(
        Path::new(root),
        objective_id,
        detail,
        max_tasks,
        max_runs,
        deadline_at_ms,
    )?)
}

pub fn builtin_swarm_objective_status(root: &str, objective_id: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::ObjectiveStatus {
        root: PathBuf::from(root),
        objective_id: objective_id.to_owned(),
    })
}

pub fn builtin_swarm_objectives(root: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::Objectives {
        root: PathBuf::from(root),
    })
}

pub fn builtin_swarm_task_create(
    root: &str,
    objective_id: &str,
    task_id: &str,
    detail: &str,
    dependencies: &[String],
    max_runs: i64,
    lease_timeout_ms: i64,
) -> Result<String, String> {
    builtin_swarm_task_create_with_deadline(
        root,
        objective_id,
        task_id,
        detail,
        dependencies,
        max_runs,
        0,
        lease_timeout_ms,
    )
}

pub fn builtin_swarm_task_create_with_deadline(
    root: &str,
    objective_id: &str,
    task_id: &str,
    detail: &str,
    dependencies: &[String],
    max_runs: i64,
    deadline_at_ms: i64,
    lease_timeout_ms: i64,
) -> Result<String, String> {
    render_builtin_json(execute_task_create(
        Path::new(root),
        objective_id,
        task_id,
        detail,
        dependencies,
        max_runs,
        deadline_at_ms,
        lease_timeout_ms,
    )?)
}

pub fn builtin_swarm_policy_set(
    root: &str,
    task_id: &str,
    mergegate_name: &str,
    required_approvals: &[String],
    required_verifiers: &[String],
) -> Result<String, String> {
    render_builtin_json(execute_policy_set(
        Path::new(root),
        task_id,
        mergegate_name,
        required_approvals,
        required_verifiers,
    )?)
}

pub fn builtin_swarm_tool_run(
    root: &str,
    task_id: &str,
    actor: &str,
    cwd: &str,
    command: &[String],
) -> Result<String, String> {
    builtin_swarm_tool_run_with_timeout(root, task_id, actor, cwd, 0, command)
}

pub fn builtin_swarm_tool_run_with_timeout(
    root: &str,
    task_id: &str,
    actor: &str,
    cwd: &str,
    timeout_ms: i64,
    command: &[String],
) -> Result<String, String> {
    let timeout_ms = if timeout_ms > 0 { Some(timeout_ms) } else { None };
    render_builtin_json(run_json(&execute_tool_run(
        Path::new(root),
        task_id,
        actor,
        Path::new(cwd),
        command,
        timeout_ms,
    )?))
}

pub fn builtin_swarm_verifier_run(
    root: &str,
    task_id: &str,
    actor: &str,
    verifier_name: &str,
    cwd: &str,
    command: &[String],
) -> Result<String, String> {
    builtin_swarm_verifier_run_with_timeout(root, task_id, actor, verifier_name, cwd, 0, command)
}

pub fn builtin_swarm_verifier_run_with_timeout(
    root: &str,
    task_id: &str,
    actor: &str,
    verifier_name: &str,
    cwd: &str,
    timeout_ms: i64,
    command: &[String],
) -> Result<String, String> {
    let timeout_ms = if timeout_ms > 0 { Some(timeout_ms) } else { None };
    render_builtin_json(run_json(&execute_verifier_run(
        Path::new(root),
        task_id,
        actor,
        verifier_name,
        Path::new(cwd),
        command,
        timeout_ms,
    )?))
}

pub fn builtin_swarm_approve(
    root: &str,
    task_id: &str,
    actor: &str,
    approval_name: &str,
) -> Result<String, String> {
    render_builtin_json(execute_approve_command(
        Path::new(root),
        task_id,
        actor,
        approval_name,
        &None,
    )?)
}

pub fn builtin_swarm_approvals(root: &str, task_id: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::Approvals {
        root: PathBuf::from(root),
        task_id: Some(task_id.to_owned()),
    })
}

pub fn builtin_swarm_mergegate_decide(
    root: &str,
    task_id: &str,
    actor: &str,
    mergegate_name: &str,
    verifier_names: &[String],
) -> Result<String, String> {
    let (_, value) = execute_mergegate_decide(
        Path::new(root),
        task_id,
        actor,
        mergegate_name,
        verifier_names,
    )?;
    render_builtin_json(value)
}

pub fn builtin_swarm_runs(root: &str, task_id: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::Runs {
        root: PathBuf::from(root),
        task_id: Some(task_id.to_owned()),
    })
}

pub fn builtin_swarm_artifacts(root: &str, task_id: &str) -> Result<String, String> {
    render_builtin_query(SwarmCommand::Artifacts {
        root: PathBuf::from(root),
        task_id: Some(task_id.to_owned()),
    })
}

pub fn builtin_swarm_memory_put(
    root: &str,
    objective_id: &str,
    task_id: &str,
    actor: &str,
    key: &str,
    value: &str,
) -> Result<String, String> {
    render_builtin_json(execute_memory_put(
        Path::new(root),
        objective_id,
        task_id,
        actor,
        key,
        value,
    )?)
}

pub fn builtin_swarm_memory_query(
    root: &str,
    objective_id: &str,
    task_id: &str,
    key: &str,
    limit: i64,
) -> Result<String, String> {
    render_builtin_query(SwarmCommand::MemoryQuery {
        root: PathBuf::from(root),
        objective_id: if objective_id.is_empty() { None } else { Some(objective_id.to_owned()) },
        task_id: if task_id.is_empty() { None } else { Some(task_id.to_owned()) },
        key: if key.is_empty() { None } else { Some(key.to_owned()) },
        limit: if limit <= 0 { 1 } else { limit as usize },
    })
}

pub fn maybe_run_swarm(args: &[String]) -> Option<ExitCode> {
    let (json_mode, command) = match parse_swarm_command(args) {
        Ok(Some(value)) => value,
        Ok(None) => return None,
        Err(message) => {
            let json = args.iter().any(|arg| arg == "--json");
            if json {
                println!("{}", json!({ "status": "error", "error": message }));
                return Some(ExitCode::from(2));
            }
            eprintln!("{message}");
            swarm_usage(args.first().map(String::as_str).unwrap_or("claspc"));
        }
    };
    match execute_command(command) {
        Ok((exit_code, value)) => {
            print_output(&value, json_mode);
            Some(exit_code)
        }
        Err(message) => {
            if json_mode {
                println!("{}", json!({ "status": "error", "error": message }));
                Some(ExitCode::from(1))
            } else {
                eprintln!("{message}");
                Some(ExitCode::from(1))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{maybe_run_swarm, render_swarm_text, run_swarm_json_command, runtime_paths};
    use std::process::ExitCode;
    use rusqlite::Connection;
    use serde_json::{json, Value};
    use std::fs;
    use std::path::PathBuf;
    use std::thread;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    fn unique_root(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("clasp-swarm-{name}-{}-{stamp}", std::process::id()))
    }

    #[test]
    fn swarm_event_flow_updates_task_state_in_sqlite() {
        let root = unique_root("events");
        let root_text = root.to_string_lossy().to_string();
        let bootstrap_args = vec!["claspc".to_owned(), "swarm".to_owned(), "bootstrap".to_owned(), root_text.clone(), "bootstrap".to_owned()];
        let lease_args = vec!["claspc".to_owned(), "swarm".to_owned(), "lease".to_owned(), root_text.clone(), "bootstrap".to_owned()];
        let heartbeat_args = vec!["claspc".to_owned(), "swarm".to_owned(), "heartbeat".to_owned(), root_text.clone(), "bootstrap".to_owned()];
        let complete_args = vec!["claspc".to_owned(), "swarm".to_owned(), "complete".to_owned(), root_text.clone(), "bootstrap".to_owned()];
        assert_eq!(maybe_run_swarm(&bootstrap_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&lease_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&heartbeat_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&complete_args), Some(ExitCode::SUCCESS));

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let mut statement = connection
            .prepare("SELECT status, lease_actor, heartbeat_seen, attempts FROM swarm_tasks WHERE task_id = 'bootstrap'")
            .expect("prepare");
        let mut rows = statement.query([]).expect("query");
        let row = rows.next().expect("row result").expect("row exists");
        let status: String = row.get(0).expect("status");
        let lease_actor: String = row.get(1).expect("lease actor");
        let heartbeat_seen: i64 = row.get(2).expect("heartbeat seen");
        let attempts: i64 = row.get(3).expect("attempts");
        assert_eq!(status, "completed");
        assert_eq!(lease_actor, "manager");
        assert_eq!(heartbeat_seen, 1);
        assert_eq!(attempts, 1);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn run_swarm_json_command_supports_ordinary_program_calls() {
        let root = unique_root("direct-json");
        let root_text = root.to_string_lossy().to_string();

        let objective = run_swarm_json_command(&vec![
            "objective".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "loop".to_owned(),
            "--detail".to_owned(),
            "Direct Clasp orchestration.".to_owned(),
        ])
        .expect("objective create");
        assert_eq!(objective.0, 0);
        assert!(objective.1.contains("\"objectiveId\":\"loop\""));

        let task = run_swarm_json_command(&vec![
            "task".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "loop".to_owned(),
            "repair".to_owned(),
            "--detail".to_owned(),
            "Repair runtime.".to_owned(),
        ])
        .expect("task create");
        assert_eq!(task.0, 0);
        assert!(task.1.contains("\"taskId\":\"repair\""));

        let lease = run_swarm_json_command(&vec![
            "lease".to_owned(),
            root_text.clone(),
            "repair".to_owned(),
            "--actor".to_owned(),
            "worker-1".to_owned(),
        ])
        .expect("lease");
        assert_eq!(lease.0, 0);
        assert!(lease.1.contains("\"kind\":\"lease_acquired\""));

        let status = run_swarm_json_command(&vec![
            "status".to_owned(),
            root_text.clone(),
            "repair".to_owned(),
        ])
        .expect("status");
        assert_eq!(status.0, 0);
        assert!(status.1.contains("\"taskId\":\"repair\""));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_verifier_and_mergegate_commands_record_runs() {
        let root = unique_root("mergegate");
        let root_text = root.to_string_lossy().to_string();
        let bootstrap_args = vec!["claspc".to_owned(), "swarm".to_owned(), "bootstrap".to_owned(), root_text.clone(), "repair".to_owned()];
        let lease_args = vec!["claspc".to_owned(), "swarm".to_owned(), "lease".to_owned(), root_text.clone(), "repair".to_owned()];
        assert_eq!(maybe_run_swarm(&bootstrap_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&lease_args), Some(ExitCode::SUCCESS));

        let verifier_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "verifier".to_owned(),
            "run".to_owned(),
            root_text.clone(),
            "repair".to_owned(),
            "native-smoke".to_owned(),
            "--".to_owned(),
            "bash".to_owned(),
            "-lc".to_owned(),
            "printf ok".to_owned(),
        ];
        assert_eq!(maybe_run_swarm(&verifier_args), Some(ExitCode::SUCCESS));

        let mergegate_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "mergegate".to_owned(),
            "decide".to_owned(),
            root_text.clone(),
            "repair".to_owned(),
            "trunk".to_owned(),
            "native-smoke".to_owned(),
        ];
        assert_eq!(maybe_run_swarm(&mergegate_args), Some(ExitCode::SUCCESS));

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let run_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM swarm_runs", [], |row| row.get(0))
            .expect("count runs");
        assert_eq!(run_count, 1);
        let event_count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM swarm_events WHERE kind = 'mergegate_decision'",
                [],
                |row| row.get(0),
            )
            .expect("count mergegate events");
        assert_eq!(event_count, 1);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn timed_verifier_kills_pipe_holding_descendant_and_finishes_run() {
        let root = unique_root("timeout-descendant");
        let root_text = root.to_string_lossy().to_string();
        fs::create_dir_all(&root).expect("create root");
        let hold_path = root.join("held-open.txt");
        fs::write(&hold_path, b"").expect("write hold file");
        let hold_text = hold_path.to_string_lossy().to_string();

        let bootstrap_args = vec!["claspc".to_owned(), "swarm".to_owned(), "bootstrap".to_owned(), root_text.clone(), "repair".to_owned()];
        let lease_args = vec!["claspc".to_owned(), "swarm".to_owned(), "lease".to_owned(), root_text.clone(), "repair".to_owned()];
        assert_eq!(maybe_run_swarm(&bootstrap_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&lease_args), Some(ExitCode::SUCCESS));

        let verifier_args = vec![
            "claspc".to_owned(),
            "--json".to_owned(),
            "swarm".to_owned(),
            "verifier".to_owned(),
            "run".to_owned(),
            root_text.clone(),
            "repair".to_owned(),
            "pipe-timeout".to_owned(),
            "--timeout-ms".to_owned(),
            "200".to_owned(),
            "--".to_owned(),
            "bash".to_owned(),
            "-lc".to_owned(),
            "printf timed-out; printf timed-err >&2; tail -f \"$1\" >&1 2>&2 & wait".to_owned(),
            "bash".to_owned(),
            hold_text,
        ];
        let started = Instant::now();
        assert_eq!(maybe_run_swarm(&verifier_args), Some(ExitCode::from(124)));
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "timed verifier exceeded bounded timeout: {:?}",
            started.elapsed()
        );

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let (exit_code, status, stdout_path, stderr_path): (i64, String, String, String) = connection
            .query_row(
                "
                SELECT runs.exit_code, runs.status, stdout.path, stderr.path
                FROM swarm_runs AS runs
                LEFT JOIN swarm_artifacts AS stdout ON stdout.id = runs.stdout_artifact_id
                LEFT JOIN swarm_artifacts AS stderr ON stderr.id = runs.stderr_artifact_id
                WHERE runs.task_id = 'repair' AND runs.role = 'verifier' AND runs.name = 'pipe-timeout'
                ORDER BY runs.id DESC
                LIMIT 1
                ",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .expect("load timed run");
        assert_eq!(exit_code, 124);
        assert_eq!(status, "timed_out");
        assert!(fs::read_to_string(stdout_path).expect("read stdout").contains("timed-out"));
        assert!(fs::read_to_string(stderr_path).expect("read stderr").contains("timed-err"));

        let finish_payload: String = connection
            .query_row(
                "
                SELECT payload_json
                FROM swarm_events
                WHERE task_id = 'repair' AND kind = 'verifier_run_finished'
                ORDER BY id DESC
                LIMIT 1
                ",
                [],
                |row| row.get(0),
            )
            .expect("load finished event");
        assert!(finish_payload.contains("\"timedOut\":true"));
        assert!(finish_payload.contains("\"exitCode\":124"));

        let detached_hold_path = root.join("detached-held-open.txt");
        fs::write(&detached_hold_path, b"").expect("write detached hold file");
        let detached_hold_text = detached_hold_path.to_string_lossy().to_string();
        let detached_bootstrap_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "bootstrap".to_owned(),
            root_text.clone(),
            "tool-detached".to_owned(),
        ];
        let detached_lease_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "lease".to_owned(),
            root_text.clone(),
            "tool-detached".to_owned(),
        ];
        assert_eq!(maybe_run_swarm(&detached_bootstrap_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&detached_lease_args), Some(ExitCode::SUCCESS));
        let detached_tool_args = vec![
            "claspc".to_owned(),
            "--json".to_owned(),
            "swarm".to_owned(),
            "tool".to_owned(),
            root_text.clone(),
            "tool-detached".to_owned(),
            "--timeout-ms".to_owned(),
            "1000".to_owned(),
            "--".to_owned(),
            "bash".to_owned(),
            "-lc".to_owned(),
            "printf detached-out; printf detached-err >&2; tail -f \"$1\" >&1 2>&2 & exit 0".to_owned(),
            "bash".to_owned(),
            detached_hold_text,
        ];
        let detached_started = Instant::now();
        assert_eq!(maybe_run_swarm(&detached_tool_args), Some(ExitCode::from(124)));
        assert!(
            detached_started.elapsed() < Duration::from_secs(4),
            "detached pipe holder exceeded bounded reader timeout: {:?}",
            detached_started.elapsed()
        );
        let (detached_exit_code, detached_status): (i64, String) = connection
            .query_row(
                "
                SELECT exit_code, status
                FROM swarm_runs
                WHERE task_id = 'tool-detached' AND role = 'tool'
                ORDER BY id DESC
                LIMIT 1
                ",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("load detached timed run");
        assert_eq!(detached_exit_code, 124);
        assert_eq!(detached_status, "timed_out");

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_manager_commands_record_stop_resume_and_artifacts() {
        let root = unique_root("manager");
        let root_text = root.to_string_lossy().to_string();

        let start_args = vec!["claspc".to_owned(), "swarm".to_owned(), "start".to_owned(), root_text.clone(), "repair".to_owned()];
        let lease_args = vec!["claspc".to_owned(), "swarm".to_owned(), "lease".to_owned(), root_text.clone(), "repair".to_owned()];
        let stop_args = vec!["claspc".to_owned(), "swarm".to_owned(), "stop".to_owned(), root_text.clone(), "repair".to_owned()];
        let resume_args = vec!["claspc".to_owned(), "swarm".to_owned(), "resume".to_owned(), root_text.clone(), "repair".to_owned()];
        let tool_lease_args = vec!["claspc".to_owned(), "swarm".to_owned(), "lease".to_owned(), root_text.clone(), "repair".to_owned()];
        let tool_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "tool".to_owned(),
            root_text.clone(),
            "repair".to_owned(),
            "--".to_owned(),
            "bash".to_owned(),
            "-lc".to_owned(),
            "printf ok; >&2 printf err".to_owned(),
        ];
        let release_args = vec!["claspc".to_owned(), "swarm".to_owned(), "release".to_owned(), root_text.clone(), "repair".to_owned()];
        let tail_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "tail".to_owned(),
            root_text.clone(),
            "repair".to_owned(),
            "--limit".to_owned(),
            "4".to_owned(),
        ];
        let runs_args = vec!["claspc".to_owned(), "swarm".to_owned(), "runs".to_owned(), root_text.clone(), "repair".to_owned()];
        let artifacts_args =
            vec!["claspc".to_owned(), "swarm".to_owned(), "artifacts".to_owned(), root_text.clone(), "repair".to_owned()];
        let approve_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "approve".to_owned(),
            root_text.clone(),
            "repair".to_owned(),
            "merge-ready".to_owned(),
        ];
        let approvals_args =
            vec!["claspc".to_owned(), "swarm".to_owned(), "approvals".to_owned(), root_text.clone(), "repair".to_owned()];

        assert_eq!(maybe_run_swarm(&start_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&lease_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&stop_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&resume_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&tool_lease_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&tool_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&release_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&approve_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&tail_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&runs_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&artifacts_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&approvals_args), Some(ExitCode::SUCCESS));

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let status: String = connection
            .query_row(
                "SELECT status FROM swarm_tasks WHERE task_id = 'repair'",
                [],
                |row| row.get(0),
            )
            .expect("task status");
        assert_eq!(status, "queued");

        let stopped_count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM swarm_events WHERE kind = 'task_stopped' AND task_id = 'repair'",
                [],
                |row| row.get(0),
            )
            .expect("count stopped events");
        assert_eq!(stopped_count, 1);

        let resumed_count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM swarm_events WHERE kind = 'task_resumed' AND task_id = 'repair'",
                [],
                |row| row.get(0),
            )
            .expect("count resumed events");
        assert_eq!(resumed_count, 1);

        let run_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM swarm_runs WHERE task_id = 'repair'", [], |row| row.get(0))
            .expect("count runs");
        assert_eq!(run_count, 1);

        let artifact_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM swarm_artifacts WHERE task_id = 'repair'", [], |row| row.get(0))
            .expect("count artifacts");
        assert_eq!(artifact_count, 2);

        let approval_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM swarm_approvals WHERE task_id = 'repair'", [], |row| row.get(0))
            .expect("count approvals");
        assert_eq!(approval_count, 1);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn manager_can_complete_failed_task_with_recorded_pass_without_retry_budget() {
        let root = unique_root("complete-failed");
        let root_text = root.to_string_lossy().to_string();

        let objective = run_swarm_json_command(&vec![
            "objective".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "loop".to_owned(),
            "--max-tasks".to_owned(),
            "4".to_owned(),
            "--max-runs".to_owned(),
            "4".to_owned(),
        ])
        .expect("objective create");
        assert_eq!(objective.0, 0);

        let task = run_swarm_json_command(&vec![
            "task".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "loop".to_owned(),
            "artifact".to_owned(),
            "--max-runs".to_owned(),
            "1".to_owned(),
        ])
        .expect("task create");
        assert_eq!(task.0, 0);

        let dependent = run_swarm_json_command(&vec![
            "task".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "loop".to_owned(),
            "integration".to_owned(),
            "--max-runs".to_owned(),
            "1".to_owned(),
            "--depends-on".to_owned(),
            "artifact".to_owned(),
        ])
        .expect("dependent task create");
        assert_eq!(dependent.0, 0);

        let lease = run_swarm_json_command(&vec!["lease".to_owned(), root_text.clone(), "artifact".to_owned()])
            .expect("lease");
        assert_eq!(lease.0, 0);

        let run = run_swarm_json_command(&vec![
            "tool".to_owned(),
            root_text.clone(),
            "artifact".to_owned(),
            "--".to_owned(),
            "bash".to_owned(),
            "-lc".to_owned(),
            "true".to_owned(),
        ])
        .expect("tool run");
        assert_eq!(run.0, 0);

        let failed = run_swarm_json_command(&vec!["fail".to_owned(), root_text.clone(), "artifact".to_owned()])
            .expect("fail");
        assert_eq!(failed.0, 0);

        let ready_before = run_swarm_json_command(&vec![
            "ready".to_owned(),
            root_text.clone(),
            "loop".to_owned(),
        ])
        .expect("ready before");
        assert_eq!(ready_before.0, 0);
        assert!(!ready_before.1.contains("\"taskId\":\"integration\""));

        let completed = run_swarm_json_command(&vec!["complete".to_owned(), root_text.clone(), "artifact".to_owned()])
            .expect("complete failed artifact");
        assert_eq!(completed.0, 0);
        assert!(completed.1.contains("\"status\":\"completed\""));

        let ready_after = run_swarm_json_command(&vec![
            "ready".to_owned(),
            root_text.clone(),
            "loop".to_owned(),
        ])
        .expect("ready after");
        assert_eq!(ready_after.0, 0);
        assert!(ready_after.1.contains("\"taskId\":\"integration\""));

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let run_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM swarm_runs WHERE task_id = 'artifact'", [], |row| row.get(0))
            .expect("count artifact runs");
        assert_eq!(run_count, 1);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn retry_widens_exhausted_task_and_objective_run_budgets() {
        let root = unique_root("retry-budget");
        let root_text = root.to_string_lossy().to_string();

        let objective = run_swarm_json_command(&vec![
            "objective".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "loop".to_owned(),
            "--max-runs".to_owned(),
            "1".to_owned(),
        ])
        .expect("objective create");
        assert_eq!(objective.0, 0);

        let task = run_swarm_json_command(&vec![
            "task".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "loop".to_owned(),
            "repair".to_owned(),
            "--max-runs".to_owned(),
            "1".to_owned(),
        ])
        .expect("task create");
        assert_eq!(task.0, 0);

        let lease = run_swarm_json_command(&vec!["lease".to_owned(), root_text.clone(), "repair".to_owned()])
            .expect("lease");
        assert_eq!(lease.0, 0);

        let run = run_swarm_json_command(&vec![
            "tool".to_owned(),
            root_text.clone(),
            "repair".to_owned(),
            "--".to_owned(),
            "bash".to_owned(),
            "-lc".to_owned(),
            "true".to_owned(),
        ])
        .expect("tool run");
        assert_eq!(run.0, 0);

        let failed = run_swarm_json_command(&vec!["fail".to_owned(), root_text.clone(), "repair".to_owned()])
            .expect("fail");
        assert_eq!(failed.0, 0);

        let retry = run_swarm_json_command(&vec!["retry".to_owned(), root_text.clone(), "repair".to_owned()])
            .expect("retry");
        assert_eq!(retry.0, 0);
        assert!(retry.1.contains("\"status\":\"queued\""));
        assert!(retry.1.contains("\"ready\":true"));

        let second_lease = run_swarm_json_command(&vec!["lease".to_owned(), root_text.clone(), "repair".to_owned()])
            .expect("second lease");
        assert_eq!(second_lease.0, 0);

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let task_max_runs: i64 = connection
            .query_row("SELECT max_runs FROM swarm_task_specs WHERE task_id = 'repair'", [], |row| row.get(0))
            .expect("task max runs");
        let objective_max_runs: i64 = connection
            .query_row("SELECT max_runs FROM swarm_objectives WHERE objective_id = 'loop'", [], |row| row.get(0))
            .expect("objective max runs");
        assert_eq!(task_max_runs, 2);
        assert_eq!(objective_max_runs, 2);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_objectives_and_task_dag_enforce_readiness_and_budgets() {
        let root = unique_root("objectives");
        let root_text = root.to_string_lossy().to_string();

        let objective_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "objective".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "appbench".to_owned(),
            "--detail".to_owned(),
            "Beat appbench".to_owned(),
            "--max-tasks".to_owned(),
            "2".to_owned(),
            "--max-runs".to_owned(),
            "2".to_owned(),
        ];
        let plan_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "task".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "appbench".to_owned(),
            "plan".to_owned(),
            "--detail".to_owned(),
            "Plan compiler work".to_owned(),
            "--max-runs".to_owned(),
            "1".to_owned(),
        ];
        let repair_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "task".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "appbench".to_owned(),
            "repair".to_owned(),
            "--detail".to_owned(),
            "Repair parser hot path".to_owned(),
            "--depends-on".to_owned(),
            "plan".to_owned(),
            "--max-runs".to_owned(),
            "1".to_owned(),
        ];
        let inspect_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "task".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "appbench".to_owned(),
            "inspect".to_owned(),
            "--detail".to_owned(),
            "Inspect an independent benchmark angle".to_owned(),
            "--max-runs".to_owned(),
            "1".to_owned(),
        ];
        let extend_objective_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "objective".to_owned(),
            "create".to_owned(),
            root_text.clone(),
            "appbench".to_owned(),
            "--detail".to_owned(),
            "Beat appbench with another autonomous wave".to_owned(),
            "--max-tasks".to_owned(),
            "3".to_owned(),
            "--max-runs".to_owned(),
            "3".to_owned(),
        ];
        let ready_args = vec!["claspc".to_owned(), "swarm".to_owned(), "ready".to_owned(), root_text.clone(), "appbench".to_owned()];
        let lease_plan_args = vec!["claspc".to_owned(), "swarm".to_owned(), "lease".to_owned(), root_text.clone(), "plan".to_owned()];
        let complete_plan_args = vec!["claspc".to_owned(), "swarm".to_owned(), "complete".to_owned(), root_text.clone(), "plan".to_owned()];
        let objective_status_args =
            vec!["claspc".to_owned(), "swarm".to_owned(), "objective".to_owned(), "status".to_owned(), root_text.clone(), "appbench".to_owned()];
        let run_plan_args = vec![
            "claspc".to_owned(),
            "swarm".to_owned(),
            "tool".to_owned(),
            root_text.clone(),
            "plan".to_owned(),
            "--".to_owned(),
            "bash".to_owned(),
            "-lc".to_owned(),
            "printf plan".to_owned(),
        ];
        let run_plan_again_args = run_plan_args.clone();

        assert_eq!(maybe_run_swarm(&objective_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&plan_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&repair_args), Some(ExitCode::SUCCESS));
        assert_ne!(maybe_run_swarm(&inspect_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&extend_objective_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&inspect_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&ready_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&lease_plan_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&run_plan_args), Some(ExitCode::SUCCESS));
        assert_ne!(maybe_run_swarm(&run_plan_again_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&complete_plan_args), Some(ExitCode::SUCCESS));
        assert_eq!(maybe_run_swarm(&objective_status_args), Some(ExitCode::SUCCESS));

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");

        let objective_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM swarm_objectives WHERE objective_id = 'appbench'", [], |row| row.get(0))
            .expect("count objectives");
        assert_eq!(objective_count, 1);

        let objective_max_tasks: i64 = connection
            .query_row("SELECT max_tasks FROM swarm_objectives WHERE objective_id = 'appbench'", [], |row| row.get(0))
            .expect("objective max tasks");
        assert_eq!(objective_max_tasks, 3);

        let dependency_count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM swarm_task_deps WHERE parent_task_id = 'plan' AND child_task_id = 'repair'",
                [],
                |row| row.get(0),
            )
            .expect("count dependencies");
        assert_eq!(dependency_count, 1);

        let ready_repair: bool = super::ready_json(&connection, Some("appbench"))
            .expect("ready json")
            .as_array()
            .expect("ready array")
            .iter()
            .any(|value| value.get("taskId").and_then(|field| field.as_str()) == Some("repair"));
        assert!(ready_repair);

        let plan_run_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM swarm_runs WHERE task_id = 'plan'", [], |row| row.get(0))
            .expect("count plan runs");
        assert_eq!(plan_run_count, 1);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_builtin_deadline_creation_persists_objective_and_task_limits() {
        let root = unique_root("builtin-deadlines");
        let root_text = root.to_string_lossy().to_string();
        let objective_deadline = 4_102_444_800_000i64;
        let task_deadline = 4_102_444_200_000i64;

        let objective_text = super::builtin_swarm_objective_create_with_deadline(
            &root_text,
            "loop",
            "deadline-aware objective",
            4,
            8,
            objective_deadline,
        )
        .expect("create objective with deadline");
        let objective_json: serde_json::Value =
            serde_json::from_str(&objective_text).expect("decode objective json");
        assert_eq!(
            objective_json.get("deadlineAtMs").and_then(|value| value.as_i64()),
            Some(objective_deadline)
        );

        let task_text = super::builtin_swarm_task_create_with_deadline(
            &root_text,
            "loop",
            "repair",
            "deadline-aware task",
            &["plan".to_owned()],
            3,
            task_deadline,
            25_000,
        )
        .expect("create task with deadline");
        let task_json: serde_json::Value = serde_json::from_str(&task_text).expect("decode task json");
        assert_eq!(
            task_json.get("deadlineAtMs").and_then(|value| value.as_i64()),
            Some(task_deadline)
        );
        assert_eq!(
            task_json.get("objectiveDeadlineAtMs").and_then(|value| value.as_i64()),
            Some(objective_deadline)
        );
        assert_eq!(
            task_json.get("leaseTimeoutMs").and_then(|value| value.as_i64()),
            Some(25_000)
        );

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let persisted_objective_deadline: i64 = connection
            .query_row(
                "SELECT deadline_at_ms FROM swarm_objectives WHERE objective_id = 'loop'",
                [],
                |row| row.get(0),
            )
            .expect("objective deadline");
        let persisted_task_deadline: i64 = connection
            .query_row(
                "SELECT deadline_at_ms FROM swarm_task_specs WHERE task_id = 'repair'",
                [],
                |row| row.get(0),
            )
            .expect("task deadline");
        assert_eq!(persisted_objective_deadline, objective_deadline);
        assert_eq!(persisted_task_deadline, task_deadline);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_manager_loop_flags_expired_leases_for_recovery() {
        let root = unique_root("lease-recovery");
        let root_text = root.to_string_lossy().to_string();

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "objective".to_owned(),
                "create".to_owned(),
                root_text.clone(),
                "loop".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "task".to_owned(),
                "create".to_owned(),
                root_text.clone(),
                "loop".to_owned(),
                "repair".to_owned(),
                "--lease-timeout-ms".to_owned(),
                "1".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "lease".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );

        thread::sleep(Duration::from_millis(10));

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let status = super::task_record_json(
            &connection,
            &super::load_task_state(&connection, "repair")
                .expect("load task state")
                .expect("task exists"),
        )
        .expect("task json");
        assert_eq!(status.get("leaseExpired").and_then(|value| value.as_bool()), Some(true));

        let manager_next = super::manager_next_json(&connection, "loop").expect("manager next");
        assert_eq!(manager_next.get("action").and_then(|value| value.as_str()), Some("recover-lease"));
        assert_eq!(manager_next.get("taskId").and_then(|value| value.as_str()), Some("repair"));

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "complete".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::from(1))
        );

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "fail".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        let failed_status = super::task_record_json(
            &connection,
            &super::load_task_state(&connection, "repair")
                .expect("load failed task state")
                .expect("failed task exists"),
        )
        .expect("failed task json");
        assert_eq!(failed_status.get("status").and_then(|value| value.as_str()), Some("failed"));

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "retry".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "lease".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );

        let recovered_status = super::task_record_json(
            &connection,
            &super::load_task_state(&connection, "repair")
                .expect("load recovered task state")
                .expect("recovered task exists"),
        )
        .expect("recovered task json");
        assert_eq!(recovered_status.get("attempts").and_then(|value| value.as_i64()), Some(2));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_manager_loop_projects_merge_policy_state() {
        let root = unique_root("manager-loop");
        let root_text = root.to_string_lossy().to_string();

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "objective".to_owned(),
                "create".to_owned(),
                root_text.clone(),
                "loop".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "task".to_owned(),
                "create".to_owned(),
                root_text.clone(),
                "loop".to_owned(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "policy".to_owned(),
                "set".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
                "trunk".to_owned(),
                "--require-approval".to_owned(),
                "merge-ready".to_owned(),
                "--require-verifier".to_owned(),
                "native-smoke".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "lease".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "complete".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let initial = super::manager_next_json(&connection, "loop").expect("manager next json");
        assert_eq!(initial.get("action").and_then(|value| value.as_str()), Some("run-verifier"));
        assert_eq!(initial.get("taskId").and_then(|value| value.as_str()), Some("repair"));
        assert_eq!(initial.get("taskStatus").and_then(|value| value.as_str()), Some("completed"));
        assert_eq!(
            initial.get("requiredApprovals").and_then(Value::as_array).map(|values| values.len()),
            Some(1)
        );
        assert_eq!(
            initial
                .get("requiredVerifiers")
                .and_then(Value::as_array)
                .and_then(|values| values.first())
                .and_then(Value::as_str),
            Some("native-smoke")
        );
        assert_eq!(initial.get("mergegateVerdict").and_then(|value| value.as_str()), Some("missing"));
        let status = super::task_record_json(
            &connection,
            &super::load_task_state(&connection, "repair")
                .expect("load task state")
                .expect("task exists"),
        )
        .expect("task json");
        assert_eq!(
            status
                .get("mergePolicy")
                .and_then(|value| value.get("missingVerifiers"))
                .and_then(|value| value.as_array())
                .map(|values| values.len()),
            Some(1)
        );

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "verifier".to_owned(),
                "run".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
                "native-smoke".to_owned(),
                "--".to_owned(),
                "bash".to_owned(),
                "-lc".to_owned(),
                "printf ok".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        let after_verifier = super::manager_next_json(&connection, "loop").expect("manager next after verifier");
        assert_eq!(
            after_verifier.get("action").and_then(|value| value.as_str()),
            Some("request-approval")
        );
        assert_eq!(
            after_verifier.get("latestVerifier").and_then(|value| value.as_str()),
            Some("native-smoke")
        );
        assert_eq!(
            after_verifier.get("latestVerifierStatus").and_then(|value| value.as_str()),
            Some("passed")
        );
        assert_eq!(
            after_verifier.get("latestVerifierExitCode").and_then(|value| value.as_i64()),
            Some(0)
        );

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "approve".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
                "merge-ready".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        let after_approval = super::manager_next_json(&connection, "loop").expect("manager next after approval");
        assert_eq!(
            after_approval.get("action").and_then(|value| value.as_str()),
            Some("decide-mergegate")
        );
        assert_eq!(
            after_approval.get("mergegateName").and_then(|value| value.as_str()),
            Some("trunk")
        );
        assert_eq!(
            after_approval.get("latestRunStatus").and_then(|value| value.as_str()),
            Some("passed")
        );

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "mergegate".to_owned(),
                "decide".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
                "trunk".to_owned(),
                "native-smoke".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        let completed = super::manager_next_json(&connection, "loop").expect("manager next complete");
        assert_eq!(
            completed.get("action").and_then(|value| value.as_str()),
            Some("objective-complete")
        );
        assert_eq!(completed.get("taskId").and_then(|value| value.as_str()), Some(""));
        let objective_status = super::objective_status_json(&connection, "loop").expect("objective status");
        assert_eq!(
            objective_status.get("projectedStatus").and_then(|value| value.as_str()),
            Some("completed")
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_mergegate_uses_policy_verifiers_when_decider_omits_them() {
        let root = unique_root("mergegate-policy-verifiers");
        let root_text = root.to_string_lossy().to_string();

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "objective".to_owned(),
                "create".to_owned(),
                root_text.clone(),
                "loop".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "task".to_owned(),
                "create".to_owned(),
                root_text.clone(),
                "loop".to_owned(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "policy".to_owned(),
                "set".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
                "trunk".to_owned(),
                "--require-approval".to_owned(),
                "merge-ready".to_owned(),
                "--require-verifier".to_owned(),
                "native-smoke".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "lease".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "complete".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "verifier".to_owned(),
                "run".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
                "native-smoke".to_owned(),
                "--".to_owned(),
                "bash".to_owned(),
                "-lc".to_owned(),
                "printf failed-verifier-out; printf failed-verifier-err >&2; exit 9".to_owned(),
            ]),
            Some(ExitCode::from(9))
        );
        let empty_verifier_names: Vec<String> = Vec::new();
        let (mergegate_exit_code, mergegate_decision) =
            super::execute_mergegate_decide(&root, "repair", "manager", "trunk", &empty_verifier_names)
                .expect("decide mergegate");
        assert_eq!(mergegate_exit_code, ExitCode::from(1));
        assert_eq!(
            mergegate_decision.get("verdict").and_then(|value| value.as_str()),
            Some("fail")
        );

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let run = super::latest_verifier_run(&connection, "repair", "native-smoke")
            .expect("load verifier run")
            .expect("verifier run exists");
        assert_eq!(run.status, "failed");
        assert_eq!(run.exit_code, 9);
        assert!(
            fs::read_to_string(&run.stdout_artifact_path)
                .expect("read stdout artifact")
                .contains("failed-verifier-out")
        );
        assert!(
            fs::read_to_string(&run.stderr_artifact_path)
                .expect("read stderr artifact")
                .contains("failed-verifier-err")
        );

        let decision = super::latest_mergegate_payload(&connection, "repair", "trunk")
            .expect("load mergegate decision")
            .expect("mergegate decision exists");
        assert_eq!(decision.get("verdict").and_then(|value| value.as_str()), Some("fail"));
        assert_eq!(
            decision
                .get("verifiers")
                .and_then(|value| value.as_array())
                .and_then(|values| values.first())
                .and_then(|value| value.get("name"))
                .and_then(|value| value.as_str()),
            Some("native-smoke")
        );
        assert_eq!(
            decision
                .get("verifiers")
                .and_then(|value| value.as_array())
                .and_then(|values| values.first())
                .and_then(|value| value.get("status"))
                .and_then(|value| value.as_str()),
            Some("failed")
        );
        let next = super::manager_next_json(&connection, "loop").expect("manager next");
        assert_eq!(next.get("action").and_then(|value| value.as_str()), Some("rerun-verifier"));
        assert_eq!(next.get("verifier").and_then(|value| value.as_str()), Some("native-smoke"));
        assert_eq!(next.get("latestVerifierStatus").and_then(|value| value.as_str()), Some("failed"));
        assert_eq!(next.get("latestVerifierExitCode").and_then(|value| value.as_i64()), Some(9));
        assert_eq!(next.get("mergegateVerdict").and_then(|value| value.as_str()), Some("fail"));
        assert_eq!(
            next.get("mergegateDetail").and_then(|value| value.as_str()),
            Some("Mergegate `trunk` decided fail.")
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_manager_next_keeps_empty_objectives_actionable() {
        let root = unique_root("empty-objective");
        let root_text = root.to_string_lossy().to_string();

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "objective".to_owned(),
                "create".to_owned(),
                root_text,
                "loop".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let manager_next = super::manager_next_json(&connection, "loop").expect("manager next");
        assert_eq!(manager_next.get("status").and_then(|value| value.as_str()), Some("empty"));
        assert_eq!(manager_next.get("action").and_then(|value| value.as_str()), Some("plan-tasks"));
        assert_eq!(manager_next.get("taskId").and_then(|value| value.as_str()), Some(""));
        assert_eq!(manager_next.get("taskStatus").and_then(|value| value.as_str()), Some(""));
        assert_eq!(
            manager_next.get("blockerTaskIds").and_then(Value::as_array).map(|values| values.len()),
            Some(0)
        );
        assert_eq!(manager_next.get("taskCount").and_then(|value| value.as_i64()), Some(0));
        assert_eq!(
            manager_next.get("suggestedCommand"),
            Some(&json!([
                "claspc",
                "swarm",
                "task",
                "create",
                "<state-root>",
                "loop",
                "<task-id>"
            ]))
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_objective_status_missing_returns_typed_shape() {
        let root = unique_root("missing-objective-status");
        let (_paths, connection) = super::open_swarm_connection(&root).expect("open sqlite db");
        let objective_status = super::objective_status_json(&connection, "missing").expect("missing objective status");

        assert_eq!(
            objective_status
                .get("objective")
                .and_then(|value| value.get("objectiveId"))
                .and_then(|value| value.as_str()),
            Some("missing")
        );
        assert_eq!(
            objective_status
                .get("objective")
                .and_then(|value| value.get("status"))
                .and_then(|value| value.as_str()),
            Some("missing")
        );
        assert_eq!(
            objective_status
                .get("projectedStatus")
                .and_then(|value| value.as_str()),
            Some("missing")
        );
        assert_eq!(objective_status.get("tasks"), Some(&json!([])));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_summary_projects_dict_backed_fields_for_sqlite_state() {
        let root = unique_root("summary");
        let root_text = root.to_string_lossy().to_string();

        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "bootstrap".to_owned(),
                root_text.clone(),
                "bootstrap".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "lease".to_owned(),
                root_text.clone(),
                "bootstrap".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "heartbeat".to_owned(),
                root_text.clone(),
                "bootstrap".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "complete".to_owned(),
                root_text.clone(),
                "bootstrap".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "bootstrap".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "lease".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "fail".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            maybe_run_swarm(&vec![
                "claspc".to_owned(),
                "swarm".to_owned(),
                "retry".to_owned(),
                root_text.clone(),
                "repair".to_owned(),
            ]),
            Some(ExitCode::SUCCESS)
        );

        let paths = runtime_paths(&root);
        let connection = Connection::open(paths.db_path).expect("open sqlite db");
        let summary = super::summary_json(&connection).expect("summary json");

        assert_eq!(
            summary.get("statusByTask"),
            Some(&json!({
                "bootstrap": "completed",
                "repair": "queued",
            }))
        );
        assert_eq!(
            summary.get("leaseByTask"),
            Some(&json!({
                "bootstrap": "manager",
                "repair": "",
            }))
        );
        assert_eq!(summary.get("hasBootstrap").and_then(|value| value.as_bool()), Some(true));
        assert_eq!(summary.get("bootstrapStatus").and_then(|value| value.as_str()), Some("completed"));
        assert_eq!(
            summary.get("taskStatusKeys"),
            Some(&json!(["bootstrap", "repair"]))
        );
        assert_eq!(
            summary.get("leaseValuesWithoutDraft"),
            Some(&json!(["manager", ""]))
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn swarm_text_rendering_makes_status_and_tail_actionable() {
        let status_text = render_swarm_text(&json!({
            "taskId": "repair",
            "status": "completed",
            "objectiveId": "loop",
            "detail": "Repair parser hot path",
            "leaseActor": "worker-1",
            "attempts": 2,
            "ready": false,
            "blockedBy": ["task status is `completed`"],
            "dependencies": ["plan"],
            "mergePolicy": {
                "mergegateName": "trunk",
                "satisfied": false,
                "missingApprovals": ["merge-ready"],
                "missingVerifiers": ["native-smoke"]
            }
        }));
        assert!(status_text.contains("task repair"));
        assert!(status_text.contains("status: completed"));
        assert!(status_text.contains("objective: loop"));
        assert!(status_text.contains("missing approvals: merge-ready"));
        assert!(status_text.contains("missing verifiers: native-smoke"));

        let tail_text = render_swarm_text(&json!([
            {
                "kind": "task_created",
                "taskId": "repair",
                "actor": "manager",
                "detail": "Create repair task.",
                "atMs": 100
            },
            {
                "kind": "approval_granted",
                "taskId": "repair",
                "actor": "manager",
                "detail": "Approve `merge-ready` for repair.",
                "atMs": 200
            }
        ]));
        assert!(tail_text.contains("[100] repair task_created by manager"));
        assert!(tail_text.contains("[200] repair approval_granted by manager"));
    }

    #[test]
    fn swarm_text_rendering_makes_manager_next_and_approval_actionable() {
        let manager_text = render_swarm_text(&json!({
            "objectiveId": "loop",
            "status": "ready",
            "action": "request-approval",
            "taskId": "repair",
            "taskStatus": "completed",
            "approval": "merge-ready",
            "latestVerifierStatus": "passed",
            "mergegateVerdict": "missing",
            "suggestedCommand": ["claspc", "swarm", "approve", "<state-root>", "repair", "merge-ready"]
        }));
        assert!(manager_text.contains("objective loop"));
        assert!(manager_text.contains("action: request-approval"));
        assert!(manager_text.contains("approval: merge-ready"));
        assert!(manager_text.contains("task status: completed"));
        assert!(manager_text.contains("latest verifier: passed"));
        assert!(manager_text.contains("mergegate verdict: missing"));
        assert!(manager_text.contains("command: claspc swarm approve <state-root> repair merge-ready"));

        let approval_text = render_swarm_text(&json!({
            "approvalId": 7,
            "taskId": "repair",
            "name": "merge-ready",
            "actor": "manager",
            "detail": "Approve `merge-ready` for repair."
        }));
        assert!(approval_text.contains("approval repair merge-ready"));
        assert!(approval_text.contains("actor: manager"));

        let recover_text = render_swarm_text(&json!({
            "objectiveId": "loop",
            "status": "needs-attention",
            "action": "recover-lease",
            "taskId": "repair",
            "leaseActor": "worker-1",
            "suggestedCommand": ["claspc", "swarm", "lease", "<state-root>", "repair"]
        }));
        assert!(recover_text.contains("action: recover-lease"));
        assert!(recover_text.contains("command: claspc swarm lease <state-root> repair"));

        let empty_text = render_swarm_text(&json!({
            "objectiveId": "loop",
            "status": "empty",
            "action": "plan-tasks",
            "taskCount": 0,
            "suggestedCommand": ["claspc", "swarm", "task", "create", "<state-root>", "loop", "<task-id>"]
        }));
        assert!(empty_text.contains("action: plan-tasks"));
        assert!(empty_text.contains("command: claspc swarm task create <state-root> loop <task-id>"));
    }
}
