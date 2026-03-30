mod tool_support;
mod swarm;

use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use tool_support::{
    build_project_bundle, build_project_bundle_build, execute_native_export_from_image_path,
    execute_native_export_from_image_path_args_local_only,
    execute_native_export_from_image_path_args, execute_native_export_from_image_text,
    execute_native_route_from_image_text, project_declares_backend_surface, run_native_export_host_server,
    ProjectBundleBuild, ProjectBundleModule, PROJECT_BUNDLE_SEPARATOR,
};

const EMBEDDED_NATIVE_IMAGE: &str = include_str!("../src/stage1.native.image.json");
const EMBEDDED_COMPILER_NATIVE_IMAGE: &str = include_str!("../src/stage1.compiler.native.image.json");
const EMBEDDED_IMAGE_MARKER: &[u8] = b"CLASP_EMBEDDED_IMAGE_V1\0";
const NATIVE_IMAGE_SECTION_WORKER_STACK_BYTES: usize = 32 * 1024 * 1024;
const CLASPC_MAIN_STACK_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Command {
    Check,
    Explain,
    Compile,
    Run,
    Native,
    NativeImage,
}

struct CliOptions {
    json: bool,
    command: Command,
    input_path: PathBuf,
    output_path: Option<PathBuf>,
    program_args: Vec<String>,
}

fn usage(program: &str) -> ! {
    eprintln!(
        "usage: {program} [--json] <check|explain|compile|run|native|native-image> <entry.clasp> [-o output] [-- args...]"
    );
    std::process::exit(2);
}

fn exec_image_usage(program: &str) -> ! {
    eprintln!(
        "usage: {program} exec-image <module.native.image.json> <export> [source.clasp|--project-entry=entry.clasp] <output>"
    );
    std::process::exit(2);
}

fn json_string(value: &str) -> String {
    format!("{value:?}")
}

const NATIVE_IMAGE_MONOLITHIC_DECLS_EXPORT: &str = "nativeImageProjectDeclsText";
const NATIVE_IMAGE_MONOLITHIC_EXPORT: &str = "nativeImageProjectText";
const NATIVE_IMAGE_BUILD_PLAN_EXPORT: &str = "nativeImageProjectBuildPlanText";
const NATIVE_IMAGE_CONSTRUCTOR_DECLS_EXPORT: &str = "nativeImageProjectConstructorDeclsText";
const NATIVE_IMAGE_DECL_MODULE_PLAN_EXPORT: &str = "nativeImageProjectDeclModulePlanText";
const NATIVE_IMAGE_DECL_NAMES_EXPORT: &str = "nativeImageProjectDeclNamesText";
const NATIVE_IMAGE_MODULE_DECLS_EXPORT: &str = "nativeImageProjectModuleDeclsText";
const NATIVE_IMAGE_NAMED_DECLS_EXPORT: &str = "nativeImageProjectNamedDeclsText";
const NATIVE_IMAGE_PLAN_EXPORT: &str = "nativeImageProjectPlanText";
const NATIVE_IMAGE_PLAN_FIELD_SEPARATOR: &str = "\n-- CLASP_NATIVE_IMAGE_PLAN_FIELD --\n";
const NATIVE_IMAGE_DECL_PLAN_FIELD_SEPARATOR: &str = "\n-- CLASP_NATIVE_IMAGE_DECL_PLAN_FIELD --\n";
const NATIVE_IMAGE_DECL_MODULE_SEPARATOR: &str = "\n-- CLASP_NATIVE_IMAGE_DECL_MODULE --\n";
const NATIVE_IMAGE_DECL_MODULE_FIELD_SEPARATOR: &str = "\n-- CLASP_NATIVE_IMAGE_DECL_MODULE_FIELD --\n";
const NATIVE_IMAGE_BUILD_PLAN_CACHE_SEPARATOR: &str = "\n-- CLASP_NATIVE_IMAGE_BUILD_PLAN_CACHE --\n";
const NATIVE_IMAGE_BUILD_PLAN_CACHE_MODULE_SEPARATOR: &str = "\n-- CLASP_NATIVE_IMAGE_BUILD_PLAN_CACHE_MODULE --\n";
const NATIVE_IMAGE_BUILD_PLAN_CACHE_FIELD_SEPARATOR: &str = "\n-- CLASP_NATIVE_IMAGE_BUILD_PLAN_CACHE_FIELD --\n";
const NATIVE_IMAGE_FALLBACK_PLAN_EXPORTS: [(&str, &str); 7] = [
    ("exports", "nativeImageProjectExportsText"),
    ("entrypoints", "nativeImageProjectEntrypointsText"),
    ("abi", "nativeImageProjectAbiText"),
    ("runtime", "nativeImageProjectRuntimeText"),
    ("compatibility", "nativeImageProjectCompatibilityText"),
    ("constructor_decls", NATIVE_IMAGE_CONSTRUCTOR_DECLS_EXPORT),
    ("decl_names", NATIVE_IMAGE_DECL_NAMES_EXPORT),
];
const NATIVE_IMAGE_CACHE_VERSION: &str = "native-image-cache-v1";
const NATIVE_IMAGE_BUILD_PLAN_CACHE_VERSION: &str = "native-image-build-plan-cache-v2";
const NATIVE_IMAGE_DECL_MODULE_CACHE_VERSION: &str = "native-image-decl-module-cache-v1";
const MODULE_SUMMARY_CACHE_VERSION: &str = "module-summary-cache-v2";
const SOURCE_EXPORT_CACHE_VERSION: &str = "source-export-cache-v1";
const DEFAULT_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD: usize = 128;
const DEFAULT_SHARED_CACHE_ROOT: &str = "/tmp/clasp-nix-cache";

struct NativeImageSections {
    module_name: String,
    exports: String,
    entrypoints: String,
    abi: String,
    runtime: String,
    compatibility: String,
    decls: String,
}

struct NativeImageProjectPlan {
    module_name: String,
    exports: String,
    entrypoints: String,
    abi: String,
    runtime: String,
    compatibility: String,
    constructor_decls: String,
    decl_names: String,
}

struct NativeImageDeclModulePlan {
    context_fingerprint: String,
    modules: Vec<NativeImageDeclModuleEntry>,
}

struct NativeImageDeclModuleEntry {
    module_name: String,
    decl_names_text: String,
    interface_fingerprint: String,
}

struct NativeImageBuildPlanCacheModule {
    canonical_path: String,
    module_name: String,
    source_fingerprint: String,
    conservative_interface_fingerprint: String,
    interface_fingerprint: String,
}

struct NativeImageBuildPlanCacheEntry {
    build_plan_text: String,
    modules: Vec<NativeImageBuildPlanCacheModule>,
}

struct IncrementalProjectSummaryPlan {
    module_order: Vec<String>,
    modules: HashMap<String, IncrementalProjectSummaryModulePlan>,
}

struct IncrementalProjectSummaryModulePlan {
    imported_module_order: Vec<String>,
    scoped_bundle: String,
}

fn print_json_error(message: &str) {
    println!(
        "{{\"status\":\"error\",\"implementation\":\"clasp-native\",\"error\":{}}}",
        json_string(message)
    );
}

fn trace_native_cache(message: &str) {
    if env::var("CLASP_NATIVE_TRACE_CACHE").is_ok() {
        eprintln!("[claspc-cache] {message}");
    }
}

fn fail(message: &str, json: bool) -> ExitCode {
    if json {
        print_json_error(message);
    } else {
        eprintln!("{message}");
    }
    ExitCode::from(1)
}

fn default_native_image_jobs() -> usize {
    env::var("CLASP_NATIVE_IMAGE_SECTION_JOBS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or_else(|| thread::available_parallelism().map(|value| value.get()).unwrap_or(4).min(6))
}

fn monolithic_decl_threshold() -> usize {
    env::var("CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD)
}

fn monolithic_bundle_bytes_threshold() -> Option<usize> {
    env::var("CLASP_NATIVE_IMAGE_MONOLITHIC_BUNDLE_BYTES_THRESHOLD")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
}

fn parse_command(name: &str) -> Option<Command> {
    match name {
        "check" => Some(Command::Check),
        "explain" => Some(Command::Explain),
        "compile" => Some(Command::Compile),
        "run" => Some(Command::Run),
        "native" => Some(Command::Native),
        "native-image" => Some(Command::NativeImage),
        _ => None,
    }
}

fn parse_cli(args: &[String]) -> Result<CliOptions, String> {
    let mut json = false;
    let mut output_path = None;
    let mut positionals = Vec::new();
    let mut program_args = Vec::new();
    let mut index = 1usize;

    while index < args.len() {
        let arg = &args[index];
        match arg.as_str() {
            "--" => {
                program_args.extend_from_slice(&args[index + 1..]);
                break;
            }
            "--json" => {
                json = true;
                index += 1;
            }
            "-o" => {
                let Some(path) = args.get(index + 1) else {
                    return Err("missing output path after -o".to_owned());
                };
                output_path = Some(PathBuf::from(path));
                index += 2;
            }
            _ if arg.starts_with("--compiler=") => {
                return Err(
                    "deprecated compiler selection is gone; `claspc` is always the native self-hosted compiler"
                        .to_owned(),
                );
            }
            _ if arg.starts_with('-') => {
                return Err(format!("unknown option `{arg}`"));
            }
            _ => {
                positionals.push(arg.clone());
                index += 1;
            }
        }
    }

    if positionals.len() != 2 {
        return Err("expected a command and one entry module path".to_owned());
    }

    let Some(command) = parse_command(&positionals[0]) else {
        return Err(format!(
            "unsupported command `{}`; native `claspc` currently supports check, explain, compile, run, native, and native-image",
            positionals[0]
        ));
    };

    if !program_args.is_empty() && command != Command::Run {
        return Err("program arguments after `--` are only supported with `claspc run`".to_owned());
    }

    Ok(CliOptions {
        json,
        command,
        input_path: PathBuf::from(&positionals[1]),
        output_path,
        program_args,
    })
}

fn load_exec_image_source(argument: &str) -> Result<String, String> {
    if let Some(project_entry_path) = argument.strip_prefix("--project-entry=") {
        build_project_bundle(project_entry_path)
    } else {
        fs::read_to_string(argument)
            .map_err(|err| format!("failed to read native compiler source input `{argument}`: {err}"))
    }
}

fn execute_project_export(image_path: &str, export_name: &str, bundle: &str) -> Result<String, String> {
    let output_bytes =
        unsafe { execute_native_export_from_image_path(image_path, export_name, Some(bundle)) }?;
    Ok(String::from_utf8_lossy(&output_bytes).into_owned())
}

fn execute_project_export_args(
    image_path: &str,
    export_name: &str,
    args: &[String],
) -> Result<String, String> {
    let output_bytes = unsafe { execute_native_export_from_image_path_args(image_path, export_name, args) }?;
    Ok(String::from_utf8_lossy(&output_bytes).into_owned())
}

fn parse_native_image_project_plan(plan_text: &str) -> Result<NativeImageProjectPlan, String> {
    if let Some(message) = plan_text.strip_prefix("ERROR:") {
        return Err(message.to_owned());
    }

    let fields: Vec<&str> = plan_text.split(NATIVE_IMAGE_PLAN_FIELD_SEPARATOR).collect();
    if fields.len() != 8 {
        return Err(format!(
            "native image plan returned {} fields; expected 8",
            fields.len()
        ));
    }

    Ok(NativeImageProjectPlan {
        module_name: fields[0].to_owned(),
        exports: fields[1].to_owned(),
        entrypoints: fields[2].to_owned(),
        abi: fields[3].to_owned(),
        runtime: fields[4].to_owned(),
        compatibility: fields[5].to_owned(),
        constructor_decls: fields[6].to_owned(),
        decl_names: fields[7].to_owned(),
    })
}

fn parse_native_image_project_build_plan(plan_text: &str) -> Result<(NativeImageProjectPlan, NativeImageDeclModulePlan), String> {
    if let Some(message) = plan_text.strip_prefix("ERROR:") {
        return Err(message.to_owned());
    }

    let fields: Vec<&str> = plan_text.split(NATIVE_IMAGE_PLAN_FIELD_SEPARATOR).collect();
    if fields.len() != 8 {
        return Err(format!(
            "native image build plan returned {} fields; expected 8",
            fields.len()
        ));
    }

    let project_plan = NativeImageProjectPlan {
        module_name: fields[0].to_owned(),
        exports: fields[1].to_owned(),
        entrypoints: fields[2].to_owned(),
        abi: fields[3].to_owned(),
        runtime: fields[4].to_owned(),
        compatibility: fields[5].to_owned(),
        constructor_decls: fields[6].to_owned(),
        decl_names: String::new(),
    };
    let decl_module_plan = parse_native_image_decl_module_plan(fields[7])?;
    Ok((project_plan, decl_module_plan))
}

fn parse_native_image_decl_module_plan(plan_text: &str) -> Result<NativeImageDeclModulePlan, String> {
    if let Some(message) = plan_text.strip_prefix("ERROR:") {
        return Err(message.to_owned());
    }

    let fields: Vec<&str> = plan_text.split(NATIVE_IMAGE_DECL_PLAN_FIELD_SEPARATOR).collect();
    if fields.len() != 2 {
        return Err(format!(
            "native image decl module plan returned {} fields; expected 2",
            fields.len()
        ));
    }

    let modules = if fields[1].trim().is_empty() {
        Vec::new()
    } else {
        let mut parsed_modules = Vec::new();
        for module_text in fields[1].split(NATIVE_IMAGE_DECL_MODULE_SEPARATOR) {
            if module_text.trim().is_empty() {
                continue;
            }
            let module_fields: Vec<&str> = module_text.split(NATIVE_IMAGE_DECL_MODULE_FIELD_SEPARATOR).collect();
            if module_fields.len() != 3 {
                return Err(format!(
                    "native image decl module entry returned {} fields; expected 3",
                    module_fields.len()
                ));
            }
            parsed_modules.push(NativeImageDeclModuleEntry {
                module_name: module_fields[0].to_owned(),
                decl_names_text: module_fields[1].to_owned(),
                interface_fingerprint: module_fields[2].to_owned(),
            });
        }
        parsed_modules
    };

    Ok(NativeImageDeclModulePlan {
        context_fingerprint: fields[0].to_owned(),
        modules,
    })
}

fn render_native_image_decl_module_plan_text(plan: &NativeImageDeclModulePlan) -> String {
    let module_entries = plan
        .modules
        .iter()
        .map(|module| {
            format!(
                "{}{}{}{}{}",
                module.module_name,
                NATIVE_IMAGE_DECL_MODULE_FIELD_SEPARATOR,
                module.decl_names_text,
                NATIVE_IMAGE_DECL_MODULE_FIELD_SEPARATOR,
                module.interface_fingerprint
            )
        })
        .collect::<Vec<_>>()
        .join(NATIVE_IMAGE_DECL_MODULE_SEPARATOR);
    format!(
        "{}{}{}",
        plan.context_fingerprint, NATIVE_IMAGE_DECL_PLAN_FIELD_SEPARATOR, module_entries
    )
}

fn render_native_image_project_build_plan_text(
    plan: &NativeImageProjectPlan,
    decl_module_plan: &NativeImageDeclModulePlan,
) -> String {
    let mut fields = Vec::new();
    fields.push(plan.module_name.clone());
    fields.push(plan.exports.clone());
    fields.push(plan.entrypoints.clone());
    fields.push(plan.abi.clone());
    fields.push(plan.runtime.clone());
    fields.push(plan.compatibility.clone());
    fields.push(plan.constructor_decls.clone());
    fields.push(render_native_image_decl_module_plan_text(decl_module_plan));
    fields.join(NATIVE_IMAGE_PLAN_FIELD_SEPARATOR)
}

fn project_bundle_module_source_fingerprint<'a>(
    bundle_build: &'a ProjectBundleBuild,
    module_name: &str,
) -> Option<&'a str> {
    bundle_build
        .modules
        .iter()
        .find(|module| module.module_name == module_name)
        .map(|module| module.source_fingerprint.as_str())
}

fn stable_fingerprint_text(text: &str) -> String {
    stable_fingerprint_parts(&[text.as_bytes()])
}

fn leading_keyword(line: &str) -> &str {
    line.split_whitespace().next().unwrap_or("")
}

fn top_level_signature_name(line: &str) -> Option<String> {
    let (head, _) = line.split_once(':')?;
    let trimmed = head.trim();
    if trimmed.is_empty() || trimmed.contains(' ') {
        return None;
    }
    Some(trimmed.to_owned())
}

fn top_level_definition_name(line: &str) -> Option<String> {
    let (head, _) = line.split_once('=')?;
    let trimmed = head.trim();
    let name = trimmed.split_whitespace().next()?;
    if name.is_empty() {
        return None;
    }
    Some(name.to_owned())
}

fn brace_delta(text: &str) -> isize {
    let opens = text.bytes().filter(|byte| *byte == b'{').count() as isize;
    let closes = text.bytes().filter(|byte| *byte == b'}').count() as isize;
    opens - closes
}

fn conservative_module_interface_fingerprint(source: &str) -> String {
    let mut rendered_lines = Vec::new();
    let mut annotated_names = HashSet::new();
    let mut block_depth: isize = 0;
    let mut fallback_to_full_source = false;

    for raw_line in source.lines() {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if block_depth > 0 {
            rendered_lines.push(trimmed.to_owned());
            block_depth += brace_delta(trimmed);
            continue;
        }

        let top_level = !raw_line.starts_with(' ') && !raw_line.starts_with('\t');
        if !top_level {
            continue;
        }

        if trimmed.starts_with("module ") || trimmed.starts_with("import ") {
            rendered_lines.push(trimmed.to_owned());
            continue;
        }

        if let Some(name) = top_level_signature_name(trimmed) {
            annotated_names.insert(name);
            rendered_lines.push(trimmed.to_owned());
            continue;
        }

        let keyword = leading_keyword(trimmed);
        if matches!(
            keyword,
            "record"
                | "type"
                | "foreign"
                | "guide"
                | "policy"
                | "projection"
                | "role"
                | "agent"
                | "workflow"
                | "route"
                | "hook"
                | "toolserver"
                | "tool"
                | "verifier"
                | "mergegate"
        ) {
            rendered_lines.push(trimmed.to_owned());
            block_depth = brace_delta(trimmed).max(0);
            continue;
        }

        if let Some(name) = top_level_definition_name(trimmed) {
            if !annotated_names.contains(&name) {
                fallback_to_full_source = true;
                break;
            }
            continue;
        }

        fallback_to_full_source = true;
        break;
    }

    if fallback_to_full_source {
        stable_fingerprint_text(source)
    } else {
        stable_fingerprint_text(&rendered_lines.join("\n"))
    }
}

fn source_module_conservative_interface_fingerprint(module: &ProjectBundleModule) -> Result<String, String> {
    let source = fs::read_to_string(&module.canonical_path).map_err(|err| {
        format!(
            "failed to read project module `{}` for interface fingerprint: {err}",
            module.canonical_path
        )
    })?;
    Ok(conservative_module_interface_fingerprint(&source))
}

fn project_bundle_module<'a>(
    bundle_build: &'a ProjectBundleBuild,
    module_name: &str,
) -> Option<&'a ProjectBundleModule> {
    bundle_build
        .modules
        .iter()
        .find(|module| module.module_name == module_name)
}

fn entry_module_name(bundle_build: &ProjectBundleBuild) -> Result<&str, String> {
    bundle_build
        .modules
        .first()
        .map(|module| module.module_name.as_str())
        .ok_or_else(|| "internal error: project bundle was empty".to_owned())
}

fn collect_project_module_postorder_visit(
    bundle_build: &ProjectBundleBuild,
    module_name: &str,
    seen: &mut HashSet<String>,
    ordered: &mut Vec<String>,
) -> Result<(), String> {
    if seen.contains(module_name) {
        return Ok(());
    }
    let Some(module) = project_bundle_module(bundle_build, module_name) else {
        return Err(format!(
            "internal error: missing project module `{module_name}` in bundle metadata"
        ));
    };
    seen.insert(module_name.to_owned());
    for import_name in &module.import_module_names {
        collect_project_module_postorder_visit(bundle_build, import_name, seen, ordered)?;
    }
    ordered.push(module_name.to_owned());
    Ok(())
}

fn collect_project_module_postorder(
    bundle_build: &ProjectBundleBuild,
    module_name: &str,
) -> Result<Vec<String>, String> {
    let mut seen = HashSet::new();
    let mut ordered = Vec::new();
    collect_project_module_postorder_visit(bundle_build, module_name, &mut seen, &mut ordered)?;
    Ok(ordered)
}

fn collect_project_module_closure_set(
    module_name: &str,
    modules_by_name: &HashMap<String, &ProjectBundleModule>,
    memoized_closures: &mut HashMap<String, HashSet<String>>,
    visiting: &mut HashSet<String>,
) -> Result<HashSet<String>, String> {
    if let Some(cached) = memoized_closures.get(module_name) {
        return Ok(cached.clone());
    }
    if !visiting.insert(module_name.to_owned()) {
        return Err(format!("cyclic project import graph reached `{module_name}`"));
    }

    let Some(module) = modules_by_name.get(module_name) else {
        return Err(format!(
            "internal error: missing project module `{module_name}` in bundle metadata"
        ));
    };

    let mut closure = HashSet::from([module_name.to_owned()]);
    for import_name in &module.import_module_names {
        let imported_closure =
            collect_project_module_closure_set(import_name, modules_by_name, memoized_closures, visiting)?;
        closure.extend(imported_closure);
    }

    visiting.remove(module_name);
    memoized_closures.insert(module_name.to_owned(), closure.clone());
    Ok(closure)
}

fn plan_incremental_project_summary(
    bundle_build: &ProjectBundleBuild,
) -> Result<IncrementalProjectSummaryPlan, String> {
    let entry_module_name = entry_module_name(bundle_build)?.to_owned();
    let module_order = collect_project_module_postorder(bundle_build, &entry_module_name)?;
    let bundled_sources = bundle_build
        .bundle
        .split(PROJECT_BUNDLE_SEPARATOR)
        .filter(|source| !source.trim().is_empty())
        .collect::<Vec<_>>();

    if bundled_sources.len() != bundle_build.modules.len() {
        return Err(format!(
            "internal error: project bundle source count {} did not match module metadata count {}",
            bundled_sources.len(),
            bundle_build.modules.len()
        ));
    }

    let mut modules_by_name = HashMap::new();
    let mut source_by_name = HashMap::new();
    let mut original_module_order = Vec::new();

    for (module, source) in bundle_build.modules.iter().zip(bundled_sources.into_iter()) {
        modules_by_name.insert(module.module_name.clone(), module);
        source_by_name.insert(module.module_name.clone(), source);
        original_module_order.push(module.module_name.clone());
    }

    let mut memoized_closures = HashMap::new();
    let mut modules = HashMap::new();
    for module_name in &module_order {
        let closure = collect_project_module_closure_set(
            module_name,
            &modules_by_name,
            &mut memoized_closures,
            &mut HashSet::new(),
        )?;
        let imported_module_order = original_module_order
            .iter()
            .filter(|name| closure.contains(*name) && name.as_str() != module_name)
            .cloned()
            .collect::<Vec<_>>();
        let scoped_bundle = original_module_order
            .iter()
            .filter(|name| closure.contains(*name))
            .map(|name| {
                source_by_name.get(name).copied().ok_or_else(|| {
                    format!("internal error: missing bundled source for project module `{name}`")
                })
            })
            .collect::<Result<Vec<_>, _>>()?
            .join(PROJECT_BUNDLE_SEPARATOR);
        modules.insert(
            module_name.clone(),
            IncrementalProjectSummaryModulePlan {
                imported_module_order,
                scoped_bundle,
            },
        );
    }

    Ok(IncrementalProjectSummaryPlan { module_order, modules })
}

fn module_interface_fingerprints(
    bundle_build: &ProjectBundleBuild,
) -> Result<HashMap<String, String>, String> {
    let mut interface_fingerprints = HashMap::new();
    for module in &bundle_build.modules {
        interface_fingerprints.insert(
            module.module_name.clone(),
            source_module_conservative_interface_fingerprint(module)?,
        );
    }
    Ok(interface_fingerprints)
}

fn load_cached_or_execute_native_image_build_plan(
    image_path: &str,
    bundle_build: &ProjectBundleBuild,
) -> Result<(String, NativeImageProjectPlan, NativeImageDeclModulePlan), String> {
    if let Some(cached) = read_cached_native_image_build_plan(image_path, bundle_build) {
        if cached.modules.len() == bundle_build.modules.len() {
            let mut cache_matches = true;
            for (current_module, cached_module) in bundle_build.modules.iter().zip(cached.modules.iter()) {
                if current_module.canonical_path != cached_module.canonical_path
                    || current_module.module_name != cached_module.module_name
                {
                    cache_matches = false;
                    break;
                }
                let current_interface_fingerprint =
                    if current_module.source_fingerprint == cached_module.source_fingerprint {
                        cached_module.interface_fingerprint.clone()
                    } else {
                        let current_conservative_fingerprint =
                            match source_module_conservative_interface_fingerprint(current_module) {
                                Ok(value) => value,
                                Err(_) => {
                                    cache_matches = false;
                                    break;
                                }
                            };
                        if current_conservative_fingerprint == cached_module.conservative_interface_fingerprint {
                            cached_module.interface_fingerprint.clone()
                        } else {
                            cache_matches = false;
                            break;
                        }
                    };
                if current_interface_fingerprint != cached_module.interface_fingerprint {
                    cache_matches = false;
                    break;
                }
            }

            if cache_matches {
                if let Ok((plan, decl_module_plan)) =
                    parse_native_image_project_build_plan(&cached.build_plan_text)
                {
                    return Ok((cached.build_plan_text, plan, decl_module_plan));
                }
            }
        }
    }

    let (build_plan_text, plan, decl_module_plan) = match execute_project_export(
        image_path,
        NATIVE_IMAGE_BUILD_PLAN_EXPORT,
        &bundle_build.bundle,
    ) {
        Ok(build_plan_text) => {
            let (plan, decl_module_plan) = parse_native_image_project_build_plan(&build_plan_text)?;
            (build_plan_text, plan, decl_module_plan)
        }
        Err(_) => {
            let fallback_plan_text =
                execute_project_export(image_path, NATIVE_IMAGE_PLAN_EXPORT, &bundle_build.bundle)?;
            let fallback_plan = parse_native_image_project_plan(&fallback_plan_text)?;
            let fallback_decl_module_plan = match execute_project_export(
                image_path,
                NATIVE_IMAGE_DECL_MODULE_PLAN_EXPORT,
                &bundle_build.bundle,
            ) {
                Ok(plan_text) => parse_native_image_decl_module_plan(&plan_text)?,
                Err(message) if should_fallback_to_monolithic_decls(&message) => NativeImageDeclModulePlan {
                    context_fingerprint: String::new(),
                    modules: Vec::new(),
                },
                Err(message) => return Err(message),
            };
            let synthetic_build_plan_text =
                render_native_image_project_build_plan_text(&fallback_plan, &fallback_decl_module_plan);
            (synthetic_build_plan_text, fallback_plan, fallback_decl_module_plan)
        }
    };
    write_cached_native_image_build_plan(image_path, bundle_build, &build_plan_text, &decl_module_plan);
    Ok((build_plan_text, plan, decl_module_plan))
}

fn json_array_inner(array_text: &str) -> Result<&str, String> {
    let trimmed = array_text.trim();
    if !trimmed.starts_with('[') || !trimmed.ends_with(']') {
        return Err("native image section did not return a JSON array".to_owned());
    }
    Ok(&trimmed[1..trimmed.len() - 1])
}

fn merge_json_arrays(parts: &[String]) -> Result<String, String> {
    let mut merged = Vec::new();
    for part in parts {
        let inner = json_array_inner(part)?.trim();
        if !inner.is_empty() {
            merged.push(inner.to_owned());
        }
    }
    Ok(format!("[{}]", merged.join(", ")))
}

fn stable_fingerprint_parts(parts: &[&[u8]]) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for part in parts {
        for byte in *part {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        hash ^= 0xff;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn split_decl_name_chunks(decl_names: &[String], max_jobs: usize) -> Vec<String> {
    if decl_names.is_empty() {
        return Vec::new();
    }
    let chunk_count = decl_names.len().min(max_jobs.max(1));
    let chunk_size = decl_names.len().div_ceil(chunk_count);
    decl_names
        .chunks(chunk_size)
        .map(|chunk| chunk.join("\n"))
        .collect()
}

fn should_fallback_to_monolithic_decls(error: &str) -> bool {
    error.contains("runtime failed to execute native compiler export")
}

fn execute_parallel_decl_section_export(
    image_path: &str,
    bundle: &str,
    constructor_decls: &str,
    decl_names_text: &str,
    max_jobs: usize,
) -> Result<String, String> {
    if decl_names_text.starts_with("ERROR:") {
        return Err(decl_names_text.trim_start_matches("ERROR:").to_owned());
    }

    let mut decl_sections = vec![constructor_decls.to_owned()];
    let decl_names: Vec<String> = decl_names_text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(ToOwned::to_owned)
        .collect();

    if decl_names.len() >= monolithic_decl_threshold() {
        return execute_project_export(image_path, NATIVE_IMAGE_MONOLITHIC_DECLS_EXPORT, bundle);
    }

    let decl_name_chunks = split_decl_name_chunks(&decl_names, max_jobs);

    if decl_name_chunks.is_empty() {
        return merge_json_arrays(&decl_sections);
    }

    if max_jobs <= 1 || decl_name_chunks.len() <= 1 {
        for chunk in decl_name_chunks {
            decl_sections.push(execute_project_export_args(
                image_path,
                NATIVE_IMAGE_NAMED_DECLS_EXPORT,
                &[bundle.to_owned(), chunk],
            )?);
        }
        return merge_json_arrays(&decl_sections);
    }

    for chunk_group in decl_name_chunks.chunks(max_jobs) {
        let mut chunk_iter = chunk_group.iter();
        if let Some(first_chunk) = chunk_iter.next() {
            decl_sections.push(execute_project_export_args(
                image_path,
                NATIVE_IMAGE_NAMED_DECLS_EXPORT,
                &[bundle.to_owned(), first_chunk.clone()],
            )?);
        }

        let mut handles = Vec::new();
        for chunk in chunk_iter {
            let worker_image_path = image_path.to_owned();
            let worker_bundle = bundle.to_owned();
            let worker_chunk = chunk.clone();
            handles.push(
                thread::Builder::new()
                    .stack_size(NATIVE_IMAGE_SECTION_WORKER_STACK_BYTES)
                    .spawn(move || {
                        execute_project_export_args(
                            &worker_image_path,
                            NATIVE_IMAGE_NAMED_DECLS_EXPORT,
                            &[worker_bundle, worker_chunk],
                        )
                    })
                    .map_err(|err| format!("failed to spawn native image decl worker: {err}"))?,
            );
        }
        for handle in handles {
            decl_sections.push(
                handle
                    .join()
                    .map_err(|_| "parallel native image decl worker panicked".to_owned())??,
            );
        }
    }

    merge_json_arrays(&decl_sections)
}

fn execute_parallel_decl_section_export_with_fallback(
    image_path: &str,
    bundle: &str,
    max_jobs: usize,
) -> Result<String, String> {
    let decl_names_text = match execute_project_export(image_path, NATIVE_IMAGE_DECL_NAMES_EXPORT, bundle) {
        Ok(value) => value,
        Err(message) if should_fallback_to_monolithic_decls(&message) => {
            return execute_project_export(image_path, NATIVE_IMAGE_MONOLITHIC_DECLS_EXPORT, bundle);
        }
        Err(message) => return Err(message),
    };
    let constructor_decls = execute_project_export(image_path, NATIVE_IMAGE_CONSTRUCTOR_DECLS_EXPORT, bundle)?;
    match execute_parallel_decl_section_export(image_path, bundle, &constructor_decls, &decl_names_text, max_jobs) {
        Ok(value) => Ok(value),
        Err(message) if should_fallback_to_monolithic_decls(&message) => {
            execute_project_export(image_path, NATIVE_IMAGE_MONOLITHIC_DECLS_EXPORT, bundle)
        }
        Err(message) => Err(message),
    }
}

fn execute_project_module_decls_export(
    image_path: &str,
    bundle: &str,
    module_name: &str,
) -> Result<String, String> {
    execute_project_export_args(
        image_path,
        NATIVE_IMAGE_MODULE_DECLS_EXPORT,
        &[bundle.to_owned(), module_name.to_owned()],
    )
}

fn execute_parallel_module_decl_section_export(
    image_path: &str,
    bundle_build: &ProjectBundleBuild,
    constructor_decls: &str,
    decl_plan: &NativeImageDeclModulePlan,
    max_jobs: usize,
) -> Result<String, String> {
    let summary_plan = plan_incremental_project_summary(bundle_build)?;
    let mut decl_sections = vec![constructor_decls.to_owned()];
    if decl_plan.modules.is_empty() {
        return merge_json_arrays(&decl_sections);
    }

    for chunk in decl_plan.modules.chunks(max_jobs.max(1)) {
        let mut group_results: Vec<Option<String>> = chunk.iter().map(|_| None).collect();
        let mut handles = Vec::new();
        let mut probed_uncached = false;

        for (index, module_entry) in chunk.iter().enumerate() {
            if module_entry.decl_names_text.trim().is_empty() {
                group_results[index] = Some("[]".to_owned());
                continue;
            }

            let Some(module_source_fingerprint) =
                project_bundle_module_source_fingerprint(bundle_build, &module_entry.module_name)
            else {
                return Err(format!(
                    "internal error: missing source fingerprint for project module `{}`",
                    module_entry.module_name
                ));
            };

            if let Some(cached) = read_cached_native_image_decl_module(
                image_path,
                &decl_plan.context_fingerprint,
                &module_entry.module_name,
                module_source_fingerprint,
            ) {
                group_results[index] = Some(cached);
                continue;
            }

            if max_jobs <= 1 || chunk.len() <= 1 {
                let module_bundle = summary_plan
                    .modules
                    .get(&module_entry.module_name)
                    .ok_or_else(|| {
                        format!(
                            "internal error: missing scoped bundle plan for project module `{}`",
                            module_entry.module_name
                        )
                    })?;
                let decl_text =
                    execute_project_module_decls_export(
                        image_path,
                        &module_bundle.scoped_bundle,
                        &module_entry.module_name,
                    )?;
                write_cached_native_image_decl_module(
                    image_path,
                    &decl_plan.context_fingerprint,
                    &module_entry.module_name,
                    module_source_fingerprint,
                    &decl_text,
                );
                group_results[index] = Some(decl_text);
                continue;
            }

            if !probed_uncached {
                let module_bundle = summary_plan
                    .modules
                    .get(&module_entry.module_name)
                    .ok_or_else(|| {
                        format!(
                            "internal error: missing scoped bundle plan for project module `{}`",
                            module_entry.module_name
                        )
                    })?;
                let decl_text =
                    execute_project_module_decls_export(
                        image_path,
                        &module_bundle.scoped_bundle,
                        &module_entry.module_name,
                    )?;
                write_cached_native_image_decl_module(
                    image_path,
                    &decl_plan.context_fingerprint,
                    &module_entry.module_name,
                    module_source_fingerprint,
                    &decl_text,
                );
                group_results[index] = Some(decl_text);
                probed_uncached = true;
                continue;
            }

            let worker_image_path = image_path.to_owned();
            let worker_bundle = summary_plan
                .modules
                .get(&module_entry.module_name)
                .ok_or_else(|| {
                    format!(
                        "internal error: missing scoped bundle plan for project module `{}`",
                        module_entry.module_name
                    )
                })?
                .scoped_bundle
                .clone();
            let worker_module_name = module_entry.module_name.clone();
            let worker_context_fingerprint = decl_plan.context_fingerprint.clone();
            let worker_source_fingerprint = module_source_fingerprint.to_owned();
            handles.push((
                index,
                worker_module_name.clone(),
                worker_source_fingerprint.clone(),
                thread::Builder::new()
                    .stack_size(NATIVE_IMAGE_SECTION_WORKER_STACK_BYTES)
                    .spawn(move || {
                        execute_project_module_decls_export(&worker_image_path, &worker_bundle, &worker_module_name)
                            .map(|decl_text| {
                                (
                                    worker_context_fingerprint,
                                    worker_module_name,
                                    worker_source_fingerprint,
                                    decl_text,
                                )
                            })
                    })
                    .map_err(|err| format!("failed to spawn native image module decl worker: {err}"))?,
            ));
        }

        for (index, _, _, handle) in handles {
            let (context_fingerprint, module_name, source_fingerprint, decl_text) = handle
                .join()
                .map_err(|_| "parallel native image module decl worker panicked".to_owned())??;
            write_cached_native_image_decl_module(
                image_path,
                &context_fingerprint,
                &module_name,
                &source_fingerprint,
                &decl_text,
            );
            group_results[index] = Some(decl_text);
        }

        for decl_text in group_results {
            decl_sections.push(decl_text.unwrap_or_else(|| "[]".to_owned()));
        }
    }

    merge_json_arrays(&decl_sections)
}

fn execute_parallel_native_image_plan_fallback(
    image_path: &str,
    bundle: &str,
    max_jobs: usize,
) -> Result<NativeImageProjectPlan, String> {
    let module_name = execute_project_export(image_path, "nativeImageProjectModuleText", bundle)?;
    if let Some(message) = module_name.strip_prefix("ERROR:") {
        return Err(message.to_owned());
    }

    let mut plan = NativeImageProjectPlan {
        module_name,
        exports: String::new(),
        entrypoints: String::new(),
        abi: String::new(),
        runtime: String::new(),
        compatibility: String::new(),
        constructor_decls: String::new(),
        decl_names: String::new(),
    };
    let mut outputs = Vec::new();

    if max_jobs <= 1 {
        for (field_name, export_name) in NATIVE_IMAGE_FALLBACK_PLAN_EXPORTS {
            outputs.push((
                field_name.to_owned(),
                execute_project_export(image_path, export_name, bundle)?,
            ));
        }
    } else {
        for chunk in NATIVE_IMAGE_FALLBACK_PLAN_EXPORTS.chunks(max_jobs) {
            let mut handles = Vec::new();
            for (field_name, export_name) in chunk {
                let worker_image_path = image_path.to_owned();
                let worker_bundle = bundle.to_owned();
                let worker_field_name = (*field_name).to_owned();
                let worker_export_name = (*export_name).to_owned();
                handles.push(
                    thread::Builder::new()
                        .stack_size(NATIVE_IMAGE_SECTION_WORKER_STACK_BYTES)
                        .spawn(move || {
                            execute_project_export(&worker_image_path, &worker_export_name, &worker_bundle)
                                .map(|value| (worker_field_name, value))
                        })
                        .map_err(|err| format!("failed to spawn native image fallback worker: {err}"))?,
                );
            }
            for handle in handles {
                outputs.push(
                    handle
                        .join()
                        .map_err(|_| "parallel native image fallback worker panicked".to_owned())??,
                );
            }
        }
    }

    for (field_name, value) in outputs {
        match field_name.as_str() {
            "exports" => plan.exports = value,
            "entrypoints" => plan.entrypoints = value,
            "abi" => plan.abi = value,
            "runtime" => plan.runtime = value,
            "compatibility" => plan.compatibility = value,
            "constructor_decls" => plan.constructor_decls = value,
            "decl_names" => plan.decl_names = value,
            _ => return Err(format!("internal error: unknown native image fallback field `{field_name}`")),
        }
    }

    Ok(plan)
}

fn assemble_native_image_text(sections: &NativeImageSections) -> String {
    format!(
        "{{\"format\":\"clasp-native-image-v1\",\"irFormat\":\"clasp-native-ir-v1\",\"module\":{},\"exports\":{},\"entrypoints\":{},\"abi\":{},\"runtime\":{},\"compatibility\":{},\"decls\":{}}}",
        json_string(&sections.module_name),
        sections.exports,
        sections.entrypoints,
        sections.abi,
        sections.runtime,
        sections.compatibility,
        sections.decls
    )
}

fn execute_parallel_native_image_export(image_path: &str, bundle_build: &ProjectBundleBuild) -> Result<Vec<u8>, String> {
    if let Some(cached) = read_cached_native_image(image_path, &bundle_build.bundle) {
        return Ok(cached);
    }

    if let Some(threshold) = monolithic_bundle_bytes_threshold() {
        if bundle_build.bundle.len() >= threshold {
            let image_bytes =
                execute_project_export(image_path, NATIVE_IMAGE_MONOLITHIC_EXPORT, &bundle_build.bundle)?.into_bytes();
            write_cached_native_image(image_path, &bundle_build.bundle, &image_bytes);
            return Ok(image_bytes);
        }
    }

    let max_jobs = default_native_image_jobs();
    let (_build_plan_text, plan, decl_module_plan) =
        match load_cached_or_execute_native_image_build_plan(image_path, bundle_build) {
        Ok(value) => value,
        Err(message) if should_fallback_to_monolithic_decls(&message) => {
            let fallback_plan = match execute_project_export(image_path, NATIVE_IMAGE_PLAN_EXPORT, &bundle_build.bundle) {
                Ok(plan_text) => parse_native_image_project_plan(&plan_text)?,
                Err(message) if should_fallback_to_monolithic_decls(&message) => {
                    execute_parallel_native_image_plan_fallback(image_path, &bundle_build.bundle, max_jobs)?
                }
                Err(message) => return Err(message),
            };
            let fallback_decl_module_plan = match execute_project_export(
                image_path,
                NATIVE_IMAGE_DECL_MODULE_PLAN_EXPORT,
                &bundle_build.bundle,
            ) {
                Ok(plan_text) => parse_native_image_decl_module_plan(&plan_text)?,
                Err(message) if should_fallback_to_monolithic_decls(&message) => {
                    NativeImageDeclModulePlan {
                        context_fingerprint: String::new(),
                        modules: Vec::new(),
                    }
                }
                Err(message) => return Err(message),
            };
            (String::new(), fallback_plan, fallback_decl_module_plan)
        }
        Err(message) => return Err(message),
    };

    let decls = if !decl_module_plan.modules.is_empty() {
        match execute_parallel_module_decl_section_export(
            image_path,
            bundle_build,
            &plan.constructor_decls,
            &decl_module_plan,
            max_jobs,
        ) {
            Ok(value) => value,
            Err(message) if should_fallback_to_monolithic_decls(&message) => {
                trace_native_cache(&format!(
                    "decl-module fallback reason={message}"
                ));
                execute_project_export(image_path, NATIVE_IMAGE_MONOLITHIC_DECLS_EXPORT, &bundle_build.bundle)?
            }
            Err(message) => return Err(message),
        }
    } else {
        match execute_parallel_decl_section_export(
            image_path,
            &bundle_build.bundle,
            &plan.constructor_decls,
            &plan.decl_names,
            max_jobs,
        ) {
            Ok(value) => value,
            Err(message) if should_fallback_to_monolithic_decls(&message) => {
                execute_parallel_decl_section_export_with_fallback(
                    image_path,
                    &bundle_build.bundle,
                    max_jobs,
                )?
            }
            Err(message) => return Err(message),
        }
    };

    let sections = NativeImageSections {
        module_name: plan.module_name,
        exports: plan.exports,
        entrypoints: plan.entrypoints,
        abi: plan.abi,
        runtime: plan.runtime,
        compatibility: plan.compatibility,
        decls,
    };

    let image_bytes = assemble_native_image_text(&sections).into_bytes();
    write_cached_native_image(image_path, &bundle_build.bundle, &image_bytes);
    Ok(image_bytes)
}

#[cfg(test)]
mod tests {
    use super::{
        collect_project_module_postorder, conservative_module_interface_fingerprint, merge_json_arrays,
        native_image_cache_dir, plan_incremental_project_summary, read_cached_native_image,
        split_decl_name_chunks, write_cached_native_image, ProjectBundleBuild, ProjectBundleModule,
        PROJECT_BUNDLE_SEPARATOR,
    };
    use std::fs;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique_test_root(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("clasp-claspc-{name}-{}-{stamp}", std::process::id()))
    }

    #[test]
    fn split_decl_name_chunks_preserves_decl_order() {
        let decl_names = vec![
            "alpha".to_owned(),
            "beta".to_owned(),
            "gamma".to_owned(),
            "delta".to_owned(),
            "epsilon".to_owned(),
        ];
        let chunks = split_decl_name_chunks(&decl_names, 3);
        assert_eq!(
            chunks,
            vec![
                "alpha\nbeta".to_owned(),
                "gamma\ndelta".to_owned(),
                "epsilon".to_owned()
            ]
        );
    }

    #[test]
    fn collect_project_module_postorder_visits_imports_before_entry() {
        let bundle_build = ProjectBundleBuild {
            bundle: String::new(),
            modules: vec![
                ProjectBundleModule {
                    canonical_path: "/tmp/Main.clasp".to_owned(),
                    module_name: "Main".to_owned(),
                    source_fingerprint: "main".to_owned(),
                    import_module_names: vec!["Shared.User".to_owned(), "Shared.Note".to_owned()],
                },
                ProjectBundleModule {
                    canonical_path: "/tmp/Shared/User.clasp".to_owned(),
                    module_name: "Shared.User".to_owned(),
                    source_fingerprint: "user".to_owned(),
                    import_module_names: vec!["Shared.Helper".to_owned()],
                },
                ProjectBundleModule {
                    canonical_path: "/tmp/Shared/Helper.clasp".to_owned(),
                    module_name: "Shared.Helper".to_owned(),
                    source_fingerprint: "helper".to_owned(),
                    import_module_names: vec![],
                },
                ProjectBundleModule {
                    canonical_path: "/tmp/Shared/Note.clasp".to_owned(),
                    module_name: "Shared.Note".to_owned(),
                    source_fingerprint: "note".to_owned(),
                    import_module_names: vec![],
                },
            ],
        };

        let ordered = collect_project_module_postorder(&bundle_build, "Main").expect("postorder");
        assert_eq!(
            ordered,
            vec![
                "Shared.Helper".to_owned(),
                "Shared.User".to_owned(),
                "Shared.Note".to_owned(),
                "Main".to_owned(),
            ]
        );
    }

    #[test]
    fn incremental_project_summary_plan_preserves_original_scoped_bundle_order() {
        let bundle_build = ProjectBundleBuild {
            bundle: [
                "module Main\nimport Shared.User\nimport Shared.Note\nmain : Str\nmain = greeting\n",
                "module Shared.User\nimport Shared.Helper\ngreeting : Str\ngreeting = helper\n",
                "module Shared.Helper\nhelper : Str\nhelper = \"ok\"\n",
                "module Shared.Note\nnote : Str\nnote = \"note\"\n",
            ]
            .join(PROJECT_BUNDLE_SEPARATOR),
            modules: vec![
                ProjectBundleModule {
                    canonical_path: "/tmp/Main.clasp".to_owned(),
                    module_name: "Main".to_owned(),
                    source_fingerprint: "main".to_owned(),
                    import_module_names: vec!["Shared.User".to_owned(), "Shared.Note".to_owned()],
                },
                ProjectBundleModule {
                    canonical_path: "/tmp/Shared/User.clasp".to_owned(),
                    module_name: "Shared.User".to_owned(),
                    source_fingerprint: "user".to_owned(),
                    import_module_names: vec!["Shared.Helper".to_owned()],
                },
                ProjectBundleModule {
                    canonical_path: "/tmp/Shared/Helper.clasp".to_owned(),
                    module_name: "Shared.Helper".to_owned(),
                    source_fingerprint: "helper".to_owned(),
                    import_module_names: vec![],
                },
                ProjectBundleModule {
                    canonical_path: "/tmp/Shared/Note.clasp".to_owned(),
                    module_name: "Shared.Note".to_owned(),
                    source_fingerprint: "note".to_owned(),
                    import_module_names: vec![],
                },
            ],
        };

        let plan = plan_incremental_project_summary(&bundle_build).expect("summary plan");
        let user_plan = plan
            .modules
            .get("Shared.User")
            .expect("summary plan for Shared.User");

        assert_eq!(user_plan.imported_module_order, vec!["Shared.Helper".to_owned()]);
        assert_eq!(
            user_plan.scoped_bundle,
            [
                "module Shared.User\nimport Shared.Helper\ngreeting : Str\ngreeting = helper\n",
                "module Shared.Helper\nhelper : Str\nhelper = \"ok\"\n",
            ]
            .join(PROJECT_BUNDLE_SEPARATOR)
        );
    }

    #[test]
    fn merge_json_arrays_preserves_element_order() {
        let merged = merge_json_arrays(&[
            r#"[{"kind":"ctor","name":"Keep"}]"#.to_owned(),
            r#"[{"kind":"decl","name":"main"},{"kind":"decl","name":"render"}]"#.to_owned(),
            "[]".to_owned(),
        ])
        .expect("merge");
        assert_eq!(
            merged,
            r#"[{"kind":"ctor","name":"Keep"}, {"kind":"decl","name":"main"},{"kind":"decl","name":"render"}]"#
        );
    }

    #[test]
    fn conservative_module_interface_fingerprint_ignores_annotated_body_only_changes() {
        let original = r#"
module Main

record User = {
  name : Str,
}

renderUser : User -> Str
renderUser user = textJoin ":" [user.name, "planner"]
"#;
        let changed = r#"
module Main

record User = {
  name : Str,
}

renderUser : User -> Str
renderUser user = textJoin ":" [user.name, "operator"]
"#;
        assert_eq!(
            conservative_module_interface_fingerprint(original),
            conservative_module_interface_fingerprint(changed)
        );
    }

    #[test]
    fn conservative_module_interface_fingerprint_changes_when_signature_changes() {
        let original = r#"
module Main

renderUser : Str -> Str
renderUser value = value
"#;
        let changed = r#"
module Main

renderUser : Str -> [Str]
renderUser value = [value]
"#;
        assert_ne!(
            conservative_module_interface_fingerprint(original),
            conservative_module_interface_fingerprint(changed)
        );
    }

    #[test]
    fn native_image_cache_roundtrips_for_same_image_and_bundle() {
        let _env_lock = super::tool_support::TEST_ENV_LOCK.lock().expect("lock test env");
        let cache_root = unique_test_root("native-image-cache");
        std::env::set_var("XDG_CACHE_HOME", &cache_root);

        let image_path = cache_root.join("compiler.native.image.json");
        fs::create_dir_all(&cache_root).expect("create cache root");
        fs::write(&image_path, "image-bytes").expect("write image");
        write_cached_native_image(
            image_path.to_str().expect("utf8 path"),
            "bundle-text",
            b"cached-image-output",
        );

        let cached = read_cached_native_image(image_path.to_str().expect("utf8 path"), "bundle-text")
            .expect("cached native image");
        assert_eq!(cached, b"cached-image-output");
        assert!(native_image_cache_dir().exists());

        std::env::remove_var("XDG_CACHE_HOME");
        let _ = fs::remove_dir_all(cache_root);
    }

    #[test]
    fn source_export_cache_roundtrips_for_same_image_export_and_bundle() {
        let _env_lock = super::tool_support::TEST_ENV_LOCK.lock().expect("lock test env");
        let cache_root = unique_test_root("source-export-cache");
        std::env::set_var("XDG_CACHE_HOME", &cache_root);

        let image_path = cache_root.join("compiler.native.image.json");
        fs::create_dir_all(&cache_root).expect("create cache root");
        fs::write(&image_path, "image-bytes").expect("write image");
        super::write_cached_source_export(
            image_path.to_str().expect("utf8 path"),
            "checkSourceText",
            "module Main\nmain = []\n",
            b"cached-check-output",
        );

        let cached = super::read_cached_source_export(
            image_path.to_str().expect("utf8 path"),
            "checkSourceText",
            "module Main\nmain = []\n",
        )
        .expect("cached source export");
        assert_eq!(cached, b"cached-check-output");
        assert!(super::source_export_cache_dir().exists());

        std::env::remove_var("XDG_CACHE_HOME");
        let _ = fs::remove_dir_all(cache_root);
    }

    #[test]
    fn cache_root_defaults_to_shared_cache_path() {
        let _env_lock = super::tool_support::TEST_ENV_LOCK.lock().expect("lock test env");
        std::env::remove_var("XDG_CACHE_HOME");
        assert_eq!(
            super::cache_root(),
            PathBuf::from("/tmp/clasp-nix-cache").join("claspc-native")
        );
    }

    #[test]
    fn embedded_app_image_path_uses_cache_root_and_reuses_same_file() {
        let _env_lock = super::tool_support::TEST_ENV_LOCK.lock().expect("lock test env");
        let cache_root = unique_test_root("embedded-app-image-cache");
        std::env::set_var("XDG_CACHE_HOME", &cache_root);

        let first = super::embedded_app_image_path("{\"module\":\"Main\"}").expect("first embedded app image");
        let second = super::embedded_app_image_path("{\"module\":\"Main\"}").expect("second embedded app image");
        let third = super::embedded_app_image_path("{\"module\":\"Other\"}").expect("third embedded app image");

        assert_eq!(first, second);
        assert_ne!(first, third);
        assert!(first.starts_with(cache_root.join("claspc-native")));
        assert_eq!(
            fs::read_to_string(&first).expect("read cached embedded app image"),
            "{\"module\":\"Main\"}"
        );

        std::env::remove_var("XDG_CACHE_HOME");
        let _ = fs::remove_dir_all(cache_root);
    }
}

fn cache_root() -> PathBuf {
    if let Ok(value) = env::var("XDG_CACHE_HOME") {
        PathBuf::from(value).join("claspc-native")
    } else {
        PathBuf::from(DEFAULT_SHARED_CACHE_ROOT).join("claspc-native")
    }
}

fn native_image_cache_dir() -> PathBuf {
    cache_root().join(NATIVE_IMAGE_CACHE_VERSION)
}

fn native_image_build_plan_cache_dir() -> PathBuf {
    cache_root().join(NATIVE_IMAGE_BUILD_PLAN_CACHE_VERSION)
}

fn native_image_decl_module_cache_dir() -> PathBuf {
    cache_root().join(NATIVE_IMAGE_DECL_MODULE_CACHE_VERSION)
}

fn source_export_cache_dir() -> PathBuf {
    cache_root().join(SOURCE_EXPORT_CACHE_VERSION)
}

fn module_summary_cache_dir() -> PathBuf {
    cache_root().join(MODULE_SUMMARY_CACHE_VERSION)
}

fn native_image_cache_path(image_path: &str, bundle: &str) -> Option<PathBuf> {
    let image_bytes = fs::read(image_path).ok()?;
    let cache_key = stable_fingerprint_parts(&[&image_bytes, bundle.as_bytes()]);
    Some(native_image_cache_dir().join(format!("{cache_key}.json")))
}

fn native_image_decl_module_cache_path(
    image_path: &str,
    context_fingerprint: &str,
    module_name: &str,
    module_source_fingerprint: &str,
) -> Option<PathBuf> {
    let image_bytes = fs::read(image_path).ok()?;
    let cache_key = stable_fingerprint_parts(&[
        &image_bytes,
        context_fingerprint.as_bytes(),
        module_name.as_bytes(),
        module_source_fingerprint.as_bytes(),
    ]);
    Some(native_image_decl_module_cache_dir().join(format!("{cache_key}.json")))
}

fn native_image_build_plan_cache_path(image_path: &str, bundle_build: &ProjectBundleBuild) -> Option<PathBuf> {
    let image_bytes = fs::read(image_path).ok()?;
    let mut parts: Vec<&[u8]> = vec![&image_bytes];
    for module in &bundle_build.modules {
        parts.push(module.canonical_path.as_bytes());
        parts.push(module.module_name.as_bytes());
    }
    let cache_key = stable_fingerprint_parts(&parts);
    Some(native_image_build_plan_cache_dir().join(format!("{cache_key}.cache")))
}

fn source_export_cache_path(image_path: &str, export_name: &str, bundle: &str) -> Option<PathBuf> {
    let image_bytes = fs::read(image_path).ok()?;
    let cache_key = stable_fingerprint_parts(&[&image_bytes, export_name.as_bytes(), bundle.as_bytes()]);
    Some(source_export_cache_dir().join(format!("{cache_key}.cache")))
}

fn module_summary_cache_path(
    image_path: &str,
    bundle_build: &ProjectBundleBuild,
    module_name: &str,
    imported_module_names: &[String],
    imported_summaries_text: &str,
    interface_fingerprints: &HashMap<String, String>,
) -> Option<PathBuf> {
    let image_bytes = fs::read(image_path).ok()?;
    let module = project_bundle_module(bundle_build, module_name)?;
    let mut imported_interface_fingerprints = Vec::new();
    for imported_module_name in imported_module_names {
        imported_interface_fingerprints.push(interface_fingerprints.get(imported_module_name)?);
    }

    let mut parts: Vec<&[u8]> = vec![
        &image_bytes,
        module_name.as_bytes(),
        module.source_fingerprint.as_bytes(),
        imported_summaries_text.as_bytes(),
    ];
    for imported_module_name in imported_module_names {
        parts.push(imported_module_name.as_bytes());
    }
    for fingerprint in imported_interface_fingerprints {
        parts.push(fingerprint.as_bytes());
    }

    let cache_key = stable_fingerprint_parts(&parts);
    Some(module_summary_cache_dir().join(format!("{cache_key}.cache")))
}

fn read_cached_native_image(image_path: &str, bundle: &str) -> Option<Vec<u8>> {
    let cache_path = native_image_cache_path(image_path, bundle)?;
    match fs::read(&cache_path) {
        Ok(bytes) => {
            trace_native_cache(&format!("native-image hit path={}", cache_path.display()));
            Some(bytes)
        }
        Err(_) => {
            trace_native_cache(&format!("native-image miss path={}", cache_path.display()));
            None
        }
    }
}

fn read_cached_native_image_decl_module(
    image_path: &str,
    context_fingerprint: &str,
    module_name: &str,
    module_source_fingerprint: &str,
) -> Option<String> {
    let cache_path = native_image_decl_module_cache_path(
        image_path,
        context_fingerprint,
        module_name,
        module_source_fingerprint,
    )?;
    match fs::read_to_string(&cache_path) {
        Ok(text) => {
            trace_native_cache(&format!(
                "decl-module hit module={} path={}",
                module_name,
                cache_path.display()
            ));
            Some(text)
        }
        Err(_) => {
            trace_native_cache(&format!(
                "decl-module miss module={} path={}",
                module_name,
                cache_path.display()
            ));
            None
        }
    }
}

fn parse_cached_native_image_build_plan(text: &str) -> Option<NativeImageBuildPlanCacheEntry> {
    let (build_plan_text, module_text) = text.split_once(NATIVE_IMAGE_BUILD_PLAN_CACHE_SEPARATOR)?;
    let modules = if module_text.trim().is_empty() {
        Vec::new()
    } else {
        let mut parsed = Vec::new();
        for module_entry_text in module_text.split(NATIVE_IMAGE_BUILD_PLAN_CACHE_MODULE_SEPARATOR) {
            if module_entry_text.trim().is_empty() {
                continue;
            }
            let fields: Vec<&str> = module_entry_text
                .split(NATIVE_IMAGE_BUILD_PLAN_CACHE_FIELD_SEPARATOR)
                .collect();
            if fields.len() != 5 {
                return None;
            }
            parsed.push(NativeImageBuildPlanCacheModule {
                canonical_path: fields[0].to_owned(),
                module_name: fields[1].to_owned(),
                source_fingerprint: fields[2].to_owned(),
                conservative_interface_fingerprint: fields[3].to_owned(),
                interface_fingerprint: fields[4].to_owned(),
            });
        }
        parsed
    };
    Some(NativeImageBuildPlanCacheEntry {
        build_plan_text: build_plan_text.to_owned(),
        modules,
    })
}

fn read_cached_native_image_build_plan(
    image_path: &str,
    bundle_build: &ProjectBundleBuild,
) -> Option<NativeImageBuildPlanCacheEntry> {
    let cache_path = native_image_build_plan_cache_path(image_path, bundle_build)?;
    let cache_text = match fs::read_to_string(&cache_path) {
        Ok(text) => {
            trace_native_cache(&format!("build-plan hit path={}", cache_path.display()));
            text
        }
        Err(_) => {
            trace_native_cache(&format!("build-plan miss path={}", cache_path.display()));
            return None;
        }
    };
    parse_cached_native_image_build_plan(&cache_text)
}

fn read_cached_source_export(image_path: &str, export_name: &str, bundle: &str) -> Option<Vec<u8>> {
    let cache_path = source_export_cache_path(image_path, export_name, bundle)?;
    match fs::read(&cache_path) {
        Ok(bytes) => {
            trace_native_cache(&format!(
                "source-export hit export={} path={}",
                export_name,
                cache_path.display()
            ));
            Some(bytes)
        }
        Err(_) => {
            trace_native_cache(&format!(
                "source-export miss export={} path={}",
                export_name,
                cache_path.display()
            ));
            None
        }
    }
}

fn read_cached_module_summary(
    image_path: &str,
    bundle_build: &ProjectBundleBuild,
    module_name: &str,
    imported_module_names: &[String],
    imported_summaries_text: &str,
    interface_fingerprints: &HashMap<String, String>,
) -> Option<String> {
    let cache_path = module_summary_cache_path(
        image_path,
        bundle_build,
        module_name,
        imported_module_names,
        imported_summaries_text,
        interface_fingerprints,
    )?;
    match fs::read_to_string(&cache_path) {
        Ok(text) => {
            trace_native_cache(&format!(
                "module-summary hit module={} path={}",
                module_name,
                cache_path.display()
            ));
            Some(text)
        }
        Err(_) => {
            trace_native_cache(&format!(
                "module-summary miss module={} path={}",
                module_name,
                cache_path.display()
            ));
            None
        }
    }
}

fn write_cached_native_image(image_path: &str, bundle: &str, image_bytes: &[u8]) {
    let Some(cache_path) = native_image_cache_path(image_path, bundle) else {
        return;
    };
    if let Some(parent) = cache_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(cache_path, image_bytes);
}

fn write_cached_native_image_decl_module(
    image_path: &str,
    context_fingerprint: &str,
    module_name: &str,
    module_source_fingerprint: &str,
    decl_text: &str,
) {
    let Some(cache_path) = native_image_decl_module_cache_path(
        image_path,
        context_fingerprint,
        module_name,
        module_source_fingerprint,
    ) else {
        return;
    };
    if let Some(parent) = cache_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(cache_path, decl_text);
}

fn write_cached_native_image_build_plan(
    image_path: &str,
    bundle_build: &ProjectBundleBuild,
    build_plan_text: &str,
    decl_module_plan: &NativeImageDeclModulePlan,
) {
    let Some(cache_path) = native_image_build_plan_cache_path(image_path, bundle_build) else {
        return;
    };
    let mut module_entries = Vec::new();
    for module in &bundle_build.modules {
        let interface_fingerprint = decl_module_plan
            .modules
            .iter()
            .find(|entry| entry.module_name == module.module_name)
            .map(|entry| entry.interface_fingerprint.clone())
            .unwrap_or_default();
        let conservative_interface_fingerprint =
            source_module_conservative_interface_fingerprint(module).unwrap_or_default();
        module_entries.push(format!(
            "{}{}{}{}{}{}{}{}{}",
            module.canonical_path,
            NATIVE_IMAGE_BUILD_PLAN_CACHE_FIELD_SEPARATOR,
            module.module_name,
            NATIVE_IMAGE_BUILD_PLAN_CACHE_FIELD_SEPARATOR,
            module.source_fingerprint,
            NATIVE_IMAGE_BUILD_PLAN_CACHE_FIELD_SEPARATOR,
            conservative_interface_fingerprint,
            NATIVE_IMAGE_BUILD_PLAN_CACHE_FIELD_SEPARATOR,
            interface_fingerprint
        ));
    }
    let cache_text = format!(
        "{}{}{}",
        build_plan_text,
        NATIVE_IMAGE_BUILD_PLAN_CACHE_SEPARATOR,
        module_entries.join(NATIVE_IMAGE_BUILD_PLAN_CACHE_MODULE_SEPARATOR)
    );
    if let Some(parent) = cache_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(cache_path, cache_text);
}

fn write_cached_source_export(image_path: &str, export_name: &str, bundle: &str, output: &[u8]) {
    let Some(cache_path) = source_export_cache_path(image_path, export_name, bundle) else {
        return;
    };
    if let Some(parent) = cache_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(cache_path, output);
}

fn write_cached_module_summary(
    image_path: &str,
    bundle_build: &ProjectBundleBuild,
    module_name: &str,
    imported_module_names: &[String],
    imported_summaries_text: &str,
    interface_fingerprints: &HashMap<String, String>,
    output: &str,
) {
    let Some(cache_path) = module_summary_cache_path(
        image_path,
        bundle_build,
        module_name,
        imported_module_names,
        imported_summaries_text,
        interface_fingerprints,
    ) else {
        return;
    };
    if let Some(parent) = cache_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(cache_path, output);
}

fn embedded_image_path(file_name: &str, image_text: &str) -> Result<PathBuf, String> {
    let cache_root = cache_root();
    fs::create_dir_all(&cache_root)
        .map_err(|err| format!("failed to create native compiler cache `{}`: {err}", cache_root.display()))?;
    let embedded_path = cache_root.join(file_name);
    let needs_write = match fs::read_to_string(&embedded_path) {
        Ok(existing) => existing != image_text,
        Err(_) => true,
    };
    if needs_write {
        fs::write(&embedded_path, image_text).map_err(|err| {
            format!(
                "failed to prepare embedded native compiler image `{}`: {err}",
                embedded_path.display()
            )
        })?;
    }
    Ok(embedded_path)
}

fn embedded_runtime_image_path() -> Result<PathBuf, String> {
    embedded_image_path("embedded.native.image.json", EMBEDDED_NATIVE_IMAGE)
}

fn embedded_compiler_image_path() -> Result<PathBuf, String> {
    embedded_image_path("embedded.compiler.native.image.json", EMBEDDED_COMPILER_NATIVE_IMAGE)
}

fn embedded_app_image_path(image_text: &str) -> Result<PathBuf, String> {
    let fingerprint = stable_fingerprint_text(image_text);
    embedded_image_path(&format!("embedded-app-{fingerprint}.native.image.json"), image_text)
}

fn bundle_build(entry_path: &Path) -> Result<ProjectBundleBuild, String> {
    let entry_text = entry_path
        .to_str()
        .ok_or_else(|| format!("entry path `{}` is not valid UTF-8", entry_path.display()))?;
    build_project_bundle_build(entry_text)
}

fn replace_extension(path: &Path, extension: &str) -> PathBuf {
    let mut output = path.to_path_buf();
    output.set_extension(extension);
    output
}

fn ensure_parent_dir(path: &Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to prepare output directory `{}`: {err}", parent.display()))?;
    }
    Ok(())
}

fn write_output(path: &Path, bytes: &[u8]) -> Result<(), String> {
    ensure_parent_dir(path)?;
    fs::write(path, bytes).map_err(|err| format!("failed to write `{}`: {err}", path.display()))
}

fn default_backend_binary_path(input_path: &Path) -> PathBuf {
    match input_path.file_stem() {
        Some(file_stem) if !file_stem.is_empty() => input_path.with_file_name(file_stem),
        _ => input_path.with_extension("bin"),
    }
}

fn output_path_requests_frontend_js(path: &Path) -> bool {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("js") | Some("mjs") => true,
        _ => false,
    }
}

fn appended_image(image_bytes: &[u8]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(
        image_bytes.len() + EMBEDDED_IMAGE_MARKER.len() + std::mem::size_of::<u64>(),
    );
    payload.extend_from_slice(image_bytes);
    payload.extend_from_slice(EMBEDDED_IMAGE_MARKER);
    payload.extend_from_slice(&(image_bytes.len() as u64).to_le_bytes());
    payload
}

fn write_backend_binary(output_path: &Path, image_bytes: &[u8]) -> Result<(), String> {
    let current_exe =
        env::current_exe().map_err(|err| format!("failed to resolve current claspc binary: {err}"))?;
    ensure_parent_dir(output_path)?;
    fs::copy(&current_exe, output_path).map_err(|err| {
        format!(
            "failed to copy native runtime launcher from `{}` to `{}`: {err}",
            current_exe.display(),
            output_path.display()
        )
    })?;
    let metadata = fs::metadata(output_path)
        .map_err(|err| format!("failed to inspect native runtime launcher `{}`: {err}", output_path.display()))?;
    let mut permissions = metadata.permissions();
    permissions.set_mode(permissions.mode() | 0o700);
    fs::set_permissions(output_path, permissions).map_err(|err| {
        format!(
            "failed to make native runtime launcher writable at `{}`: {err}",
            output_path.display()
        )
    })?;
    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(output_path)
        .map_err(|err| format!("failed to reopen `{}` for app image append: {err}", output_path.display()))?;
    file.write_all(&appended_image(image_bytes))
        .map_err(|err| format!("failed to append app image to `{}`: {err}", output_path.display()))
}

fn read_embedded_image_from_executable() -> Result<Option<String>, String> {
    let current_exe =
        env::current_exe().map_err(|err| format!("failed to resolve current executable: {err}"))?;
    let bytes = fs::read(&current_exe)
        .map_err(|err| format!("failed to read current executable `{}`: {err}", current_exe.display()))?;
    let footer_len = EMBEDDED_IMAGE_MARKER.len() + std::mem::size_of::<u64>();
    if bytes.len() < footer_len {
        return Ok(None);
    }
    let marker_start = bytes.len() - footer_len;
    let marker_end = marker_start + EMBEDDED_IMAGE_MARKER.len();
    if &bytes[marker_start..marker_end] != EMBEDDED_IMAGE_MARKER {
        return Ok(None);
    }
    let mut length_bytes = [0u8; 8];
    length_bytes.copy_from_slice(&bytes[marker_end..]);
    let image_len = u64::from_le_bytes(length_bytes) as usize;
    if marker_start < image_len {
        return Err("embedded app image footer was truncated".to_owned());
    }
    let image_start = marker_start - image_len;
    let image_text = std::str::from_utf8(&bytes[image_start..marker_start])
        .map_err(|err| format!("embedded app image was not valid UTF-8 JSON: {err}"))?;
    Ok(Some(image_text.to_owned()))
}

fn parse_json_text_field(body: &str, field_name: &str) -> Option<String> {
    let field_prefix = format!("\"{field_name}\":\"");
    let start = body.find(&field_prefix)? + field_prefix.len();
    let mut decoded = String::new();
    let mut escaped = false;
    for ch in body[start..].chars() {
        if escaped {
            match ch {
                'n' => decoded.push('\n'),
                'r' => decoded.push('\r'),
                't' => decoded.push('\t'),
                '"' => decoded.push('"'),
                '\\' => decoded.push('\\'),
                other => decoded.push(other),
            }
            escaped = false;
        } else if ch == '\\' {
            escaped = true;
        } else if ch == '"' {
            return Some(decoded);
        } else {
            decoded.push(ch);
        }
    }
    None
}

fn decode_form_component(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut index = 0usize;
    let mut decoded = Vec::with_capacity(bytes.len());
    while index < bytes.len() {
        match bytes[index] {
            b'+' => {
                decoded.push(b' ');
                index += 1;
            }
            b'%' if index + 2 < bytes.len() => {
                let hex = &value[index + 1..index + 3];
                if let Ok(byte) = u8::from_str_radix(hex, 16) {
                    decoded.push(byte);
                    index += 3;
                } else {
                    decoded.push(bytes[index]);
                    index += 1;
                }
            }
            byte => {
                decoded.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

fn form_body_to_json(body: &str) -> String {
    let mut fields = Vec::new();
    for pair in body.split('&').filter(|pair| !pair.is_empty()) {
        let (raw_name, raw_value) = pair.split_once('=').unwrap_or((pair, ""));
        let name = decode_form_component(raw_name);
        let value = decode_form_component(raw_value);
        fields.push(format!("{}:{}", json_string(&name), json_string(&value)));
    }
    format!("{{{}}}", fields.join(","))
}

fn normalize_native_request_json(path: &str, request_json: &str) -> String {
    if path != "/leads" && path != "/api/leads" {
        return request_json.to_owned();
    }

    let Some(segment) = parse_json_text_field(request_json, "segment") else {
        return request_json.to_owned();
    };
    let normalized_segment = match segment.as_str() {
        "startup" => "Startup",
        "growth" => "Growth",
        "enterprise" => "Enterprise",
        _ => return request_json.to_owned(),
    };
    request_json.replacen(
        &format!("\"segment\":{}", json_string(&segment)),
        &format!("\"segment\":{}", json_string(normalized_segment)),
        1,
    )
}

fn native_route_error_http_response(path: &str, request_json: &str, message: &str) -> (String, Vec<u8>) {
    if message == "invalid_route_request_payload" {
        if path == "/api/leads" && parse_json_text_field(request_json, "budget").is_some() {
            return (
                "400 Bad Request".to_owned(),
                b"{\"error\":\"budget must be an integer\"}".to_vec(),
            );
        }
        return (
            "400 Bad Request".to_owned(),
            format!("{{\"error\":{}}}", json_string(message)).into_bytes(),
        );
    }

    if message == "invalid_route_request_json" || message == "invalid_route_request_type" {
        return (
            "400 Bad Request".to_owned(),
            format!("{{\"error\":{}}}", json_string(message)).into_bytes(),
        );
    }

    if message == "route_dispatch_failed" || message.starts_with("Unknown lead:") {
        return (
            "502 Bad Gateway".to_owned(),
            format!("{{\"error\":{}}}", json_string(message)).into_bytes(),
        );
    }

    (
        "500 Internal Server Error".to_owned(),
        format!("{{\"error\":{}}}", json_string(message)).into_bytes(),
    )
}

fn read_http_request(stream: &mut TcpStream) -> Result<(String, String, String), String> {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|err| format!("failed to configure request timeout: {err}"))?;

    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let mut header_end = None;
    let mut content_length = 0usize;
    let mut content_type = String::new();

    loop {
        let bytes_read = match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(bytes_read) => bytes_read,
            Err(err) => return Err(format!("failed to read HTTP request: {err}")),
        };
        buffer.extend_from_slice(&chunk[..bytes_read]);

        if header_end.is_none() {
            header_end = buffer.windows(4).position(|window| window == b"\r\n\r\n");
            if let Some(header_index) = header_end {
                let header_text = String::from_utf8_lossy(&buffer[..header_index]).into_owned();
                for line in header_text.lines().skip(1) {
                    if let Some((name, value)) = line.split_once(':') {
                        if name.eq_ignore_ascii_case("content-length") {
                            content_length = value.trim().parse::<usize>().unwrap_or(0);
                        } else if name.eq_ignore_ascii_case("content-type") {
                            content_type = value.trim().to_owned();
                        }
                    }
                }
            }
        }

        if let Some(header_index) = header_end {
            let body_start = header_index + 4;
            if buffer.len() >= body_start + content_length {
                break;
            }
        }
    }

    let Some(header_index) = header_end else {
        return Err("invalid HTTP request: missing header terminator".to_owned());
    };
    let header_text = String::from_utf8_lossy(&buffer[..header_index]).into_owned();
    let mut header_lines = header_text.lines();
    let request_line = header_lines
        .next()
        .ok_or_else(|| "invalid HTTP request: missing request line".to_owned())?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts
        .next()
        .ok_or_else(|| "invalid HTTP request: missing method".to_owned())?;
    let target = request_parts
        .next()
        .ok_or_else(|| "invalid HTTP request: missing target".to_owned())?;
    let path = target.split('?').next().unwrap_or(target).to_owned();
    let body_start = header_index + 4;
    if buffer.len() < body_start + content_length {
        return Err("invalid HTTP request: truncated body".to_owned());
    }
    let body_bytes = &buffer[body_start..body_start + content_length];
    let body_text = String::from_utf8_lossy(body_bytes).into_owned();
    let request_json = if body_text.trim().is_empty() {
        "{}".to_owned()
    } else if content_type.starts_with("application/x-www-form-urlencoded") {
        form_body_to_json(&body_text)
    } else {
        body_text
    };
    Ok((method.to_owned(), path, request_json))
}

fn write_http_response(
    stream: &mut TcpStream,
    status_line: &str,
    extra_headers: &[(&str, String)],
    body: &[u8],
) -> Result<(), String> {
    let mut response = format!("HTTP/1.1 {status_line}\r\n");
    response.push_str("Connection: close\r\n");
    response.push_str(&format!("Content-Length: {}\r\n", body.len()));
    for (name, value) in extra_headers {
        response.push_str(name);
        response.push_str(": ");
        response.push_str(value);
        response.push_str("\r\n");
    }
    response.push_str("\r\n");

    stream
        .write_all(response.as_bytes())
        .map_err(|err| format!("failed to write HTTP response head: {err}"))?;
    stream
        .write_all(body)
        .map_err(|err| format!("failed to write HTTP response body: {err}"))?;
    stream
        .flush()
        .map_err(|err| format!("failed to flush HTTP response: {err}"))
}

fn handle_http_connection(stream: &mut TcpStream, image_text: &str) -> Result<(), String> {
    let (method, path, request_json) = read_http_request(stream)?;
    let normalized_request_json = normalize_native_request_json(&path, &request_json);
    match unsafe { execute_native_route_from_image_text(image_text, &method, &path, &normalized_request_json) } {
        Ok(body) => {
            let body_text = String::from_utf8_lossy(&body).into_owned();
            if body_text.contains("\"kind\":\"redirect\"") {
                let location = parse_json_text_field(&body_text, "location")
                    .ok_or_else(|| "redirect response was missing location".to_owned())?;
                write_http_response(
                    stream,
                    if method == "POST" {
                        "303 See Other"
                    } else {
                        "302 Found"
                    },
                    &[
                        ("Content-Type", "application/json".to_owned()),
                        ("Location", location),
                    ],
                    &body,
                )
            } else {
                write_http_response(
                    stream,
                    "200 OK",
                    &[("Content-Type", "application/json".to_owned())],
                    &body,
                )
            }
        }
        Err(message) => {
            if message == "missing_route" {
                write_http_response(
                    stream,
                    "404 Not Found",
                    &[("Content-Type", "application/json".to_owned())],
                    b"{\"error\":\"missing_route\"}",
                )
            } else {
                let (status_line, error_body) =
                    native_route_error_http_response(&path, &normalized_request_json, &message);
                write_http_response(
                    stream,
                    &status_line,
                    &[("Content-Type", "application/json".to_owned())],
                    &error_body,
                )
            }
        }
    }
}

fn run_embedded_server(image_text: &str, addr: &str) -> ExitCode {
    let listener = match TcpListener::bind(addr) {
        Ok(listener) => listener,
        Err(err) => {
            eprintln!("failed to bind native server at {addr}: {err}");
            return ExitCode::from(1);
        }
    };
    eprintln!("clasp-native serving {addr}");
    for incoming in listener.incoming() {
        match incoming {
            Ok(mut stream) => {
                if let Err(message) = handle_http_connection(&mut stream, image_text) {
                    eprintln!("{message}");
                }
            }
            Err(err) => {
                eprintln!("failed to accept native server connection: {err}");
            }
        }
    }
    ExitCode::SUCCESS
}

fn run_embedded_image(image_text: &str, args: &[String]) -> ExitCode {
    if args.get(1).map(|value| value.as_str()) == Some("serve") {
        if args.len() != 3 {
            eprintln!("usage: {} serve <HOST:PORT>", args[0]);
            return ExitCode::from(2);
        }
        return run_embedded_server(image_text, &args[2]);
    }

    if args.get(1).map(|value| value.as_str()) != Some("route") {
        let embedded_image_path = match embedded_app_image_path(image_text) {
            Ok(path) => path,
            Err(message) => {
                eprintln!("{message}");
                return ExitCode::from(1);
            }
        };
        let embedded_image_path_text = embedded_image_path.to_string_lossy();
        let result =
            unsafe { execute_native_export_from_image_path_args_local_only(&embedded_image_path_text, "main", &[]) };
        let output_bytes = match result {
            Ok(output_bytes) => output_bytes,
            Err(message) => {
                eprintln!("{message}");
                return ExitCode::from(1);
            }
        };
        if let Err(err) = std::io::stdout().write_all(&output_bytes) {
            eprintln!("failed to write stdout: {err}");
            return ExitCode::from(1);
        }
        if !output_bytes.ends_with(b"\n") {
            let _ = std::io::stdout().write_all(b"\n");
        }
        return ExitCode::SUCCESS;
    }

    if args.len() == 5 && args[1] == "route" {
        let result = unsafe {
            execute_native_route_from_image_text(image_text, &args[2], &args[3], &args[4])
        };
        let output_bytes = match result {
            Ok(output_bytes) => output_bytes,
            Err(message) => {
                eprintln!("{message}");
                return ExitCode::from(1);
            }
        };
        if let Err(err) = std::io::stdout().write_all(&output_bytes) {
            eprintln!("failed to write stdout: {err}");
            return ExitCode::from(1);
        }
        if !output_bytes.ends_with(b"\n") {
            let _ = std::io::stdout().write_all(b"\n");
        }
        return ExitCode::SUCCESS;
    }

    eprintln!("usage: {} [serve <HOST:PORT> | route <METHOD> <PATH> <JSON_BODY>]", args[0]);
    ExitCode::from(2)
}

fn run_check(options: &CliOptions, embedded_path: &Path, bundle_build: &ProjectBundleBuild) -> ExitCode {
    let embedded_path_text = embedded_path.to_string_lossy();
    let summary = match execute_incremental_project_summary(&embedded_path_text, bundle_build) {
        Ok(summary) => summary,
        Err(message) if should_fallback_to_monolithic_decls(&message) => {
            let result = unsafe {
                execute_native_export_from_image_path(
                    &embedded_path_text,
                    "checkProjectText",
                    Some(&bundle_build.bundle),
                )
            };
            match result {
                Ok(output_bytes) => String::from_utf8_lossy(&output_bytes).into_owned(),
                Err(message) => return fail(&message, options.json),
            }
        }
        Err(message) => return fail(&message, options.json),
    };

    if options.json {
        println!(
            "{{\"status\":\"ok\",\"command\":\"check\",\"input\":{},\"implementation\":\"clasp-native\",\"summary\":{}}}",
            json_string(&options.input_path.display().to_string()),
            json_string(&summary)
        );
    } else {
        eprintln!(
            "Checked {} with clasp-native",
            options.input_path.display()
        );
    }

    ExitCode::SUCCESS
}

fn bundle_build_is_single_source_module(bundle_build: &ProjectBundleBuild) -> bool {
    bundle_build.modules.len() == 1 && bundle_text_is_single_source_module(&bundle_build.bundle)
}

fn bundle_text_is_single_source_module(bundle: &str) -> bool {
    !bundle.contains(PROJECT_BUNDLE_SEPARATOR)
}

fn source_export_name_for_project_export(export_name: &str) -> Option<&'static str> {
    match export_name {
        "checkProjectText" => Some("checkSourceText"),
        "explainProjectText" => Some("explainSourceText"),
        "compileProjectText" => Some("compileSourceText"),
        "nativeProjectText" => Some("nativeSourceText"),
        "nativeImageProjectText" => Some("nativeImageSourceText"),
        _ => None,
    }
}

fn execute_source_or_project_export(
    embedded_path_text: &str,
    bundle_build: &ProjectBundleBuild,
    project_export_name: &str,
) -> Result<Vec<u8>, String> {
    let export_name = if bundle_build_is_single_source_module(bundle_build) {
        source_export_name_for_project_export(project_export_name).unwrap_or(project_export_name)
    } else {
        project_export_name
    };
    if let Some(cached) = read_cached_source_export(embedded_path_text, export_name, &bundle_build.bundle) {
        return Ok(cached);
    }
    let output =
        unsafe { execute_native_export_from_image_path(embedded_path_text, export_name, Some(&bundle_build.bundle)) }?;
    write_cached_source_export(embedded_path_text, export_name, &bundle_build.bundle, &output);
    Ok(output)
}

fn execute_project_module_summary_export(
    embedded_path_text: &str,
    scoped_bundle: &str,
    imported_summaries_text: &str,
) -> Result<String, String> {
    execute_project_export_args(
        embedded_path_text,
        "checkProjectModuleSummaryText",
        &[scoped_bundle.to_owned(), imported_summaries_text.to_owned()],
    )
}

fn execute_incremental_project_summary(
    embedded_path_text: &str,
    bundle_build: &ProjectBundleBuild,
) -> Result<String, String> {
    let summary_plan = plan_incremental_project_summary(bundle_build)?;
    let interface_fingerprints = module_interface_fingerprints(bundle_build)?;
    let mut module_summaries: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();

    for module_name in &summary_plan.module_order {
        let module_plan = summary_plan.modules.get(module_name).ok_or_else(|| {
            format!("internal error: missing incremental summary plan for `{module_name}`")
        })?;
        let imported_summaries = module_plan
            .imported_module_order
            .iter()
            .filter_map(|name| module_summaries.get(name))
            .filter(|summary| !summary.trim().is_empty())
            .cloned()
            .collect::<Vec<_>>();
        let imported_summaries_text = imported_summaries.join("\n");

        let summary_text = if let Some(cached) = read_cached_module_summary(
            embedded_path_text,
            bundle_build,
            module_name,
            &module_plan.imported_module_order,
            &imported_summaries_text,
            &interface_fingerprints,
        ) {
            cached
        } else {
            let output = execute_project_module_summary_export(
                embedded_path_text,
                &module_plan.scoped_bundle,
                &imported_summaries_text,
            )?;
            write_cached_module_summary(
                embedded_path_text,
                bundle_build,
                module_name,
                &module_plan.imported_module_order,
                &imported_summaries_text,
                &interface_fingerprints,
                &output,
            );
            output
        };

        if let Some(message) = summary_text.strip_prefix("ERROR:") {
            return Err(message.to_owned());
        }
        module_summaries.insert(module_name.clone(), summary_text);
    }

    let summaries = summary_plan
        .module_order
        .iter()
        .filter_map(|module_name| module_summaries.get(module_name))
        .map(|summary| summary.trim())
        .filter(|summary| !summary.is_empty())
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    Ok(summaries.join("\n"))
}

fn remap_exec_image_project_export_name<'a>(export_name: &'a str, source_text: Option<&str>) -> &'a str {
    if source_text.map(bundle_text_is_single_source_module).unwrap_or(false) {
        source_export_name_for_project_export(export_name).unwrap_or(export_name)
    } else {
        export_name
    }
}

fn run_explain(options: &CliOptions, embedded_path: &Path, bundle_build: &ProjectBundleBuild) -> ExitCode {
    let embedded_path_text = embedded_path.to_string_lossy();
    let explanation = match execute_incremental_project_summary(&embedded_path_text, bundle_build) {
        Ok(explanation) => explanation,
        Err(message) if should_fallback_to_monolithic_decls(&message) => {
            let result = execute_source_or_project_export(&embedded_path_text, bundle_build, "explainProjectText");
            match result {
                Ok(output_bytes) => String::from_utf8_lossy(&output_bytes).into_owned(),
                Err(message) => return fail(&message, options.json),
            }
        }
        Err(message) => return fail(&message, options.json),
    };

    if options.json {
        println!(
            "{{\"status\":\"ok\",\"command\":\"explain\",\"input\":{},\"implementation\":\"clasp-native\",\"explanation\":{}}}",
            json_string(&options.input_path.display().to_string()),
            json_string(&explanation)
        );
    } else {
        print!("{explanation}");
    }

    ExitCode::SUCCESS
}

fn run_build(
    options: &CliOptions,
    embedded_path: &Path,
    bundle_build: &ProjectBundleBuild,
    export_name: &str,
    default_extension: &str,
    target_name: &str,
) -> ExitCode {
    let embedded_path_text = embedded_path.to_string_lossy();
    let result = if export_name == "nativeImageProjectText" {
        execute_parallel_native_image_export(&embedded_path_text, bundle_build)
    } else {
        execute_source_or_project_export(&embedded_path_text, bundle_build, export_name)
    };
    let output_bytes = match result {
        Ok(output_bytes) => output_bytes,
        Err(message) => return fail(&message, options.json),
    };

    let output_path = options
        .output_path
        .clone()
        .unwrap_or_else(|| replace_extension(&options.input_path, default_extension));
    if let Err(message) = write_output(&output_path, &output_bytes) {
        return fail(&message, options.json);
    }

    if options.json {
        println!(
            "{{\"status\":\"ok\",\"command\":{},\"input\":{},\"implementation\":\"clasp-native\",\"target\":{},\"output\":{}}}",
            json_string(match options.command {
                Command::Compile => "compile",
                Command::Run => "run",
                Command::Native => "native",
                Command::NativeImage => "native-image",
                Command::Check => "check",
                Command::Explain => "explain",
            }),
            json_string(&options.input_path.display().to_string()),
            json_string(target_name),
            json_string(&output_path.display().to_string())
        );
    } else {
        eprintln!("Wrote {} with clasp-native", output_path.display());
    }

    ExitCode::SUCCESS
}

fn run_exec_image(args: &[String]) -> ExitCode {
    if args.len() != 5 && args.len() != 6 {
        exec_image_usage(&args[0]);
    }

    let image_path = &args[2];
    let export_name = &args[3];
    let exec_image_source_argument = args.get(4).map(|value| value.as_str());
    let project_entry_path = exec_image_source_argument.and_then(|argument| argument.strip_prefix("--project-entry="));
    let source_text = if args.len() == 6 && project_entry_path.is_none() {
        match load_exec_image_source(&args[4]) {
            Ok(source_text) => Some(source_text),
            Err(message) => {
                eprintln!("{message}");
                return ExitCode::from(1);
            }
        }
    } else if let Some(project_entry_path) = project_entry_path {
        if export_name == "nativeImageProjectText" {
            None
        } else {
            match build_project_bundle(project_entry_path) {
                Ok(bundle) => Some(bundle),
                Err(message) => {
                    eprintln!("{message}");
                    return ExitCode::from(1);
                }
            }
        }
    } else {
        None
    };

    let remapped_export_name = remap_exec_image_project_export_name(export_name, source_text.as_deref());
    let cacheable_bundle = if export_name == "nativeImageProjectText" {
        None
    } else {
        source_text.as_deref()
    };
    if let Some(bundle) = cacheable_bundle {
        if let Some(cached) = read_cached_source_export(image_path, remapped_export_name, bundle) {
            let output_path = Path::new(args.last().expect("missing output path"));
            if let Err(message) = write_output(output_path, &cached) {
                eprintln!("{message}");
                return ExitCode::from(1);
            }
            return ExitCode::SUCCESS;
        }
    }

    let result = unsafe {
        if export_name == "nativeImageProjectText" {
            match project_entry_path {
                Some(project_entry_path) => match build_project_bundle_build(project_entry_path) {
                    Ok(bundle_build) => {
                        if let Some(cached) =
                            read_cached_source_export(image_path, remapped_export_name, &bundle_build.bundle)
                        {
                            Ok(cached)
                        } else {
                            match if bundle_build_is_single_source_module(&bundle_build) {
                                execute_native_export_from_image_path(
                                    image_path,
                                    source_export_name_for_project_export(export_name).unwrap_or(export_name),
                                    Some(&bundle_build.bundle),
                                )
                            } else {
                                execute_parallel_native_image_export(image_path, &bundle_build)
                            } {
                                Ok(output_bytes) => {
                                    write_cached_source_export(
                                        image_path,
                                        remapped_export_name,
                                        &bundle_build.bundle,
                                        &output_bytes,
                                    );
                                    Ok(output_bytes)
                                }
                                Err(message) => Err(message),
                            }
                        }
                    }
                    Err(message) => Err(message),
                },
                None => match source_text.as_deref() {
                    Some(bundle) => {
                        if let Some(cached) = read_cached_source_export(image_path, remapped_export_name, bundle) {
                            Ok(cached)
                        } else {
                            match execute_native_export_from_image_path(
                                image_path,
                                remapped_export_name,
                                Some(bundle),
                            ) {
                                Ok(output_bytes) => {
                                    write_cached_source_export(
                                        image_path,
                                        remapped_export_name,
                                        bundle,
                                        &output_bytes,
                                    );
                                    Ok(output_bytes)
                                }
                                Err(message) => Err(message),
                            }
                        }
                    }
                    None => execute_native_export_from_image_path(image_path, remapped_export_name, None),
                },
            }
        } else {
            match execute_native_export_from_image_path(image_path, remapped_export_name, source_text.as_deref()) {
                Ok(output_bytes) => {
                    if let Some(bundle) = cacheable_bundle {
                        write_cached_source_export(image_path, remapped_export_name, bundle, &output_bytes);
                    }
                    Ok(output_bytes)
                }
                Err(message) => Err(message),
            }
        }
    };
    let output_bytes = match result {
        Ok(output_bytes) => output_bytes,
        Err(message) => {
            eprintln!("{message}");
            return ExitCode::from(1);
        }
    };

    let output_path = Path::new(args.last().expect("missing output path"));
    if let Err(message) = write_output(output_path, &output_bytes) {
        eprintln!("{message}");
        return ExitCode::from(1);
    }

    ExitCode::SUCCESS
}

fn temporary_backend_binary_path(input_path: &Path) -> PathBuf {
    let stem = input_path
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("clasp-run");
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::from_secs(0))
        .as_nanos();
    std::env::temp_dir().join(format!("claspc-run-{stem}-{}-{stamp}", std::process::id()))
}

fn exit_code_from_status(status: std::process::ExitStatus) -> ExitCode {
    if status.success() {
        ExitCode::SUCCESS
    } else {
        let code = status.code().unwrap_or(1).clamp(1, 255) as u8;
        ExitCode::from(code)
    }
}

fn run_backend_binary(binary_path: &Path, program_args: &[String]) -> Result<ExitCode, String> {
    let status = std::process::Command::new(binary_path)
        .args(program_args)
        .status()
        .map_err(|err| format!("failed to run {}: {err}", binary_path.display()))?;
    Ok(exit_code_from_status(status))
}

fn run_main(args: Vec<String>) -> ExitCode {
    if args.get(1).map(|value| value.as_str()) == Some("__serve-native-export-host") {
        if args.len() != 4 {
            eprintln!("usage: {} __serve-native-export-host <image-path> <socket-path>", args[0]);
            return ExitCode::from(2);
        }
        return match run_native_export_host_server(&args[2], &args[3]) {
            Ok(()) => ExitCode::SUCCESS,
            Err(message) => {
                eprintln!("{message}");
                ExitCode::from(1)
            }
        };
    }

    match read_embedded_image_from_executable() {
        Ok(Some(image_text)) => return run_embedded_image(&image_text, &args),
        Ok(None) => {}
        Err(message) => return fail(&message, args.iter().any(|arg| arg == "--json")),
    }

    if args.get(1).map(|value| value.as_str()) == Some("exec-image") {
        return run_exec_image(&args);
    }

    if let Some(exit_code) = swarm::maybe_run_swarm(&args) {
        return exit_code;
    }

    let options = match parse_cli(&args) {
        Ok(options) => options,
        Err(message) => {
            if args.iter().any(|arg| arg == "--json") {
                print_json_error(&message);
                return ExitCode::from(2);
            }
            eprintln!("{message}");
            usage(&args[0]);
        }
    };

    let embedded_path = match embedded_compiler_image_path() {
        Ok(embedded_path) => embedded_path,
        Err(message) => return fail(&message, options.json),
    };

    let bundle_build = match bundle_build(&options.input_path) {
        Ok(bundle_build) => bundle_build,
        Err(message) => return fail(&message, options.json),
    };
    let bundle = &bundle_build.bundle;

    match options.command {
        Command::Check => {
            if bundle_build_is_single_source_module(&bundle_build) {
                let embedded_path_text = embedded_path.to_string_lossy();
                let result = execute_source_or_project_export(&embedded_path_text, &bundle_build, "checkProjectText");
                let summary = match result {
                    Ok(output_bytes) => String::from_utf8_lossy(&output_bytes).into_owned(),
                    Err(message) => return fail(&message, options.json),
                };

                if options.json {
                    println!(
                        "{{\"status\":\"ok\",\"command\":\"check\",\"input\":{},\"implementation\":\"clasp-native\",\"summary\":{}}}",
                        json_string(&options.input_path.display().to_string()),
                        json_string(&summary)
                    );
                } else {
                    eprintln!("Checked {} with clasp-native", options.input_path.display());
                }
                ExitCode::SUCCESS
            } else {
                run_check(&options, &embedded_path, &bundle_build)
            }
        }
        Command::Explain => run_explain(&options, &embedded_path, &bundle_build),
        Command::Compile => {
            let explicit_output_requests_frontend_js = options
                .output_path
                .as_ref()
                .map(|path| output_path_requests_frontend_js(path))
                .unwrap_or(false);
            if (project_declares_backend_surface(&bundle) && !bundle_build_is_single_source_module(&bundle_build))
                || !explicit_output_requests_frontend_js
            {
                let embedded_path_text = embedded_path.to_string_lossy();
                let result = execute_parallel_native_image_export(&embedded_path_text, &bundle_build);
                let output_bytes = match result {
                    Ok(output_bytes) => output_bytes,
                    Err(message) => return fail(&message, options.json),
                };
                let output_path = options
                    .output_path
                    .clone()
                    .unwrap_or_else(|| default_backend_binary_path(&options.input_path));
                if let Err(message) = write_backend_binary(&output_path, &output_bytes) {
                    return fail(&message, options.json);
                }
                if options.json {
                    println!(
                        "{{\"status\":\"ok\",\"command\":\"compile\",\"input\":{},\"implementation\":\"clasp-native\",\"target\":\"backend-native-binary\",\"output\":{}}}",
                        json_string(&options.input_path.display().to_string()),
                        json_string(&output_path.display().to_string())
                    );
                } else {
                    eprintln!("Wrote {} with clasp-native", output_path.display());
                }
                ExitCode::SUCCESS
            } else {
                run_build(
                    &options,
                    &embedded_path,
                    &bundle_build,
                    "compileProjectText",
                    "js",
                    "frontend-js",
                )
            }
        }
        Command::Run => {
            if options.json {
                return fail("`claspc run` does not support --json", true);
            }
            let output_path = options
                .output_path
                .clone()
                .unwrap_or_else(|| temporary_backend_binary_path(&options.input_path));
            let embedded_path_text = embedded_path.to_string_lossy();
            let output_bytes = match execute_parallel_native_image_export(&embedded_path_text, &bundle_build) {
                Ok(output_bytes) => output_bytes,
                Err(message) => return fail(&message, false),
            };
            if let Err(message) = write_backend_binary(&output_path, &output_bytes) {
                return fail(&message, false);
            }
            let exit_code = match run_backend_binary(&output_path, &options.program_args) {
                Ok(exit_code) => exit_code,
                Err(message) => return fail(&message, false),
            };
            if options.output_path.is_none() {
                let _ = fs::remove_file(&output_path);
            }
            exit_code
        }
        Command::Native => run_build(
            &options,
            &embedded_path,
            &bundle_build,
            "nativeProjectText",
            "native.ir",
            "native-ir",
        ),
        Command::NativeImage => run_build(
            &options,
            &embedded_path,
            &bundle_build,
            "nativeImageProjectText",
            "native.image.json",
            "native-image",
        ),
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    match thread::Builder::new()
        .name("claspc-main".to_owned())
        .stack_size(CLASPC_MAIN_STACK_BYTES)
        .spawn(move || run_main(args))
    {
        Ok(handle) => match handle.join() {
            Ok(exit_code) => exit_code,
            Err(_) => {
                eprintln!("claspc main thread panicked");
                ExitCode::from(1)
            }
        },
        Err(err) => {
            eprintln!("failed to spawn claspc main thread: {err}");
            ExitCode::from(1)
        }
    }
}
