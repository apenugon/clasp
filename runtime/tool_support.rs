use std::collections::{HashMap, HashSet};
use std::env;
use std::ffi::CString;
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::mem;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::ptr::null_mut;
use std::slice;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, UNIX_EPOCH};

use clasp_runtime::{
    clasp_rt_activate_native_module_image, clasp_rt_call_native_dispatch, clasp_rt_call_native_route_json,
    clasp_rt_init,
    clasp_rt_json_from_string, clasp_rt_native_image_module_name, clasp_rt_native_image_validate,
    clasp_rt_native_module_image_free, clasp_rt_native_module_image_load, clasp_rt_release, clasp_rt_retain,
    clasp_rt_shutdown, clasp_rt_string_from_utf8, ClaspRtHeader, ClaspRtJson, ClaspRtNativeModuleImage,
    ClaspRtResultString, ClaspRtRuntime, ClaspRtString,
};

pub const PROJECT_BUNDLE_SEPARATOR: &str = "\n-- CLASP_PROJECT_MODULE --\n";
const PROJECT_BUNDLE_CACHE_VERSION: &str = "bundle-cache-v1";
const NATIVE_EXPORT_HOST_VERSION: &str = "export-host-v1";
const DEFAULT_SHARED_CACHE_ROOT: &str = "/tmp/clasp-nix-cache";
const DEFAULT_SHORT_HOST_ROOT: &str = "/tmp/clasp-native-export-host";
const NATIVE_EXPORT_HOST_STACK_BYTES: usize = 64 * 1024 * 1024;
const NATIVE_IMAGE_READ_RETRY_ATTEMPTS: usize = 10;
const NATIVE_IMAGE_READ_RETRY_DELAY_MS: u64 = 25;

#[cfg(test)]
pub(crate) static TEST_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

static NATIVE_EXPORT_HOST_FAILURES: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

const BACKEND_DECLARATION_KEYWORDS: &[&str] = &[
    "route",
    "guide",
    "policy",
    "role",
    "agent",
    "workflow",
    "hook",
    "toolserver",
    "tool",
    "verifier",
    "mergegate",
];

const NATIVE_RUNTIME_ONLY_SYMBOLS: &[&str] = &[
    "argv",
    "timeUnixMs",
    "envVar",
    "writeFile",
    "appendFile",
    "mkdirAll",
    "readFile",
    "fileExists",
    "pathJoin",
    "pathDirname",
    "pathBasename",
];

#[derive(Clone)]
struct ProjectModuleInfo {
    canonical_path: PathBuf,
    module_name: String,
    source_fingerprint: String,
    bundled_source: String,
    import_module_names: Vec<String>,
    import_paths: Vec<PathBuf>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectBundleModule {
    pub canonical_path: String,
    pub module_name: String,
    pub source_fingerprint: String,
    pub import_module_names: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectBundleBuild {
    pub bundle: String,
    pub modules: Vec<ProjectBundleModule>,
}

struct BundledProjectSourceModule {
    module_name: String,
    source: String,
    imports: Vec<String>,
}

unsafe fn string_bytes(value: *mut ClaspRtString) -> &'static [u8] {
    if value.is_null() || (*value).byte_length == 0 || (*value).bytes.is_null() {
        &[]
    } else {
        slice::from_raw_parts((*value).bytes as *const u8, (*value).byte_length)
    }
}

unsafe fn release(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    if !header.is_null() {
        clasp_rt_release(runtime, header);
    }
}

fn push_unique_import(imports: &mut Vec<String>, import_name: &str) {
    if !imports.iter().any(|existing| existing == import_name) {
        imports.push(import_name.to_owned());
    }
}

fn parse_header_imports(source: &str) -> Vec<String> {
    let mut imports = Vec::new();

    for line in source.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some(module_body) = trimmed.strip_prefix("module ") {
            if let Some((_, imported_modules)) = module_body.split_once(" with ") {
                for import_name in imported_modules
                    .split(',')
                    .map(str::trim)
                    .filter(|import_name| !import_name.is_empty())
                {
                    push_unique_import(&mut imports, import_name);
                }
            }
        }

        break;
    }

    imports
}

fn parse_imports(source: &str) -> Vec<String> {
    let mut imports = parse_header_imports(source);

    for import_name in source
        .lines()
        .filter_map(|line| line.trim().strip_prefix("import "))
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        push_unique_import(&mut imports, import_name);
    }

    imports
}

fn parse_module_name(source: &str) -> Result<String, String> {
    for line in source.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(module_body) = trimmed.strip_prefix("module ") {
            let header = module_body
                .split_once(" with ")
                .map(|(name, _)| name)
                .unwrap_or(module_body)
                .trim();
            let module_name = header.split_whitespace().next().unwrap_or("").trim();
            if module_name.is_empty() {
                return Err("project module header was missing a module name".to_owned());
            }
            return Ok(module_name.to_owned());
        }
        break;
    }
    Err("project module was missing a `module` header".to_owned())
}

fn parse_bundled_project_modules(bundle: &str) -> Result<Vec<BundledProjectSourceModule>, String> {
    bundle
        .split(PROJECT_BUNDLE_SEPARATOR)
        .filter(|source| !source.trim().is_empty())
        .map(|source| {
            let module_name = parse_module_name(source)?;
            Ok(BundledProjectSourceModule {
                imports: parse_imports(source),
                module_name,
                source: source.to_owned(),
            })
        })
        .collect()
}

pub fn build_module_scoped_bundle(
    bundle_build: &ProjectBundleBuild,
    entry_module_name: &str,
) -> Result<String, String> {
    let bundled_modules = parse_bundled_project_modules(&bundle_build.bundle)?;
    let mut imports_by_name = HashMap::new();
    let mut has_entry = false;

    for bundled_module in &bundled_modules {
        if bundled_module.module_name == entry_module_name {
            has_entry = true;
        }
        imports_by_name.insert(
            bundled_module.module_name.clone(),
            bundled_module.imports.clone(),
        );
    }

    if !has_entry {
        return Err(format!(
            "internal error: missing scoped project module `{entry_module_name}`"
        ));
    }

    let mut included = HashSet::new();
    let mut pending = vec![entry_module_name.to_owned()];
    while let Some(module_name) = pending.pop() {
        if included.contains(&module_name) {
            continue;
        }
        let Some(imports) = imports_by_name.get(&module_name) else {
            return Err(format!(
                "internal error: missing scoped import metadata for `{module_name}`"
            ));
        };
        included.insert(module_name);
        for import_name in imports {
            if !included.contains(import_name) {
                pending.push(import_name.clone());
            }
        }
    }

    let mut scoped_sources = Vec::new();
    for bundled_module in bundled_modules {
        if included.contains(&bundled_module.module_name) {
            scoped_sources.push(bundled_module.source);
        }
    }

    Ok(scoped_sources.join(PROJECT_BUNDLE_SEPARATOR))
}

fn hosted_foreign_signature_line(module_path: &Path, line: &str) -> Result<Option<String>, String> {
    let trimmed = line.trim();
    let Some(foreign_body) = trimmed
        .strip_prefix("foreign unsafe ")
        .or_else(|| trimmed.strip_prefix("foreign "))
    else {
        return Ok(None);
    };

    let Some((foreign_name, _)) = foreign_body.split_once(" :") else {
        return Ok(None);
    };

    let Some((_, declaration_tail)) = foreign_body.split_once(" declaration \"") else {
        return Ok(None);
    };
    let Some((declaration_path_text, _)) = declaration_tail.split_once('"') else {
        return Err(format!("failed to parse hosted package declaration path in `{trimmed}`"));
    };

    let declaration_path = module_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(declaration_path_text);
    let signature = fs::read_to_string(&declaration_path).map_err(|err| {
        format!(
            "failed to read package declaration `{}`: {err}",
            declaration_path.display()
        )
    })?;

    Ok(Some(format!(
        "hosted foreign-signature {} = {:?}",
        foreign_name.trim(),
        signature.trim()
    )))
}

fn augment_source_with_hosted_metadata(module_path: &Path, source: &str) -> Result<String, String> {
    let mut signature_lines = Vec::new();

    for line in source.lines() {
        if let Some(signature_line) = hosted_foreign_signature_line(module_path, line)? {
            signature_lines.push(signature_line);
        }
    }

    if signature_lines.is_empty() {
        Ok(source.to_owned())
    } else {
        Ok(format!("{source}\n\n{}", signature_lines.join("\n")))
    }
}

fn module_import_path(root: &Path, import_name: &str) -> PathBuf {
    let relative = import_name.replace('.', "/");
    root.join(relative).with_extension("clasp")
}

fn default_bundle_jobs() -> usize {
    env::var("CLASP_NATIVE_BUNDLE_JOBS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or_else(|| {
            thread::available_parallelism()
                .map(|value| value.get())
                .unwrap_or(4)
                .min(8)
        })
}

fn load_project_module(root: &Path, path: PathBuf) -> Result<ProjectModuleInfo, String> {
    let canonical_path = fs::canonicalize(&path)
        .map_err(|err| format!("failed to resolve project module `{}`: {err}", path.display()))?;
    let source = fs::read_to_string(&canonical_path)
        .map_err(|err| format!("failed to read project module `{}`: {err}", canonical_path.display()))?;
    let bundled_source = augment_source_with_hosted_metadata(&canonical_path, &source)?;
    let module_name = parse_module_name(&source)
        .map_err(|message| format!("{message} in `{}`", canonical_path.display()))?;
    let import_module_names = parse_imports(&source);
    let import_paths = import_module_names
        .iter()
        .map(|import_name| {
            let import_path = module_import_path(root, import_name);
            fs::canonicalize(&import_path).map_err(|err| {
                format!(
                    "failed to resolve imported module `{}` from `{}`: {err}",
                    import_name,
                    canonical_path.display()
                )
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ProjectModuleInfo {
        canonical_path,
        module_name,
        source_fingerprint: stable_fingerprint_text(&bundled_source),
        bundled_source,
        import_module_names,
        import_paths,
    })
}

fn load_project_module_wave(
    root: &Path,
    pending: &[PathBuf],
    max_jobs: usize,
) -> Result<Vec<ProjectModuleInfo>, String> {
    if pending.is_empty() {
        return Ok(Vec::new());
    }

    if max_jobs <= 1 || pending.len() == 1 {
        return pending
            .iter()
            .cloned()
            .map(|path| load_project_module(root, path))
            .collect();
    }

    let mut infos = Vec::new();
    for chunk in pending.chunks(max_jobs) {
        let mut handles = Vec::new();
        for path in chunk {
            let worker_root = root.to_path_buf();
            let worker_path = path.clone();
            handles.push(thread::spawn(move || load_project_module(&worker_root, worker_path)));
        }
        for handle in handles {
            let info = handle
                .join()
                .map_err(|_| "parallel project module worker panicked".to_owned())??;
            infos.push(info);
        }
    }
    Ok(infos)
}

fn append_project_bundle_module(
    module_path: &Path,
    module_infos: &HashMap<PathBuf, ProjectModuleInfo>,
    seen: &mut HashSet<PathBuf>,
    bundled_sources: &mut Vec<String>,
    bundled_modules: &mut Vec<ProjectBundleModule>,
) -> Result<(), String> {
    let canonical_path = module_path.to_path_buf();
    if seen.contains(&canonical_path) {
        return Ok(());
    }

    let Some(info) = module_infos.get(&canonical_path) else {
        return Err(format!(
            "internal error: missing bundled project module `{}`",
            canonical_path.display()
        ));
    };

    seen.insert(canonical_path.clone());
    bundled_sources.push(info.bundled_source.clone());
    bundled_modules.push(ProjectBundleModule {
        canonical_path: info.canonical_path.to_string_lossy().into_owned(),
        module_name: info.module_name.clone(),
        source_fingerprint: info.source_fingerprint.clone(),
        import_module_names: info.import_module_names.clone(),
    });
    for import_path in &info.import_paths {
        append_project_bundle_module(import_path, module_infos, seen, bundled_sources, bundled_modules)?;
    }

    Ok(())
}

fn stable_fingerprint_bytes(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn stable_fingerprint_text(text: &str) -> String {
    stable_fingerprint_bytes(text.as_bytes())
}

fn native_export_host_socket_path(image_path_text: &str) -> Option<PathBuf> {
    let current_exe = env::current_exe().ok()?;
    let current_exe_bytes = fs::read(current_exe).ok()?;
    let image_bytes = fs::read(image_path_text).ok()?;
    let host_key = stable_fingerprint_bytes(&[current_exe_bytes, image_bytes].concat());
    let file_name = format!("{host_key}.sock");
    let primary_path = native_export_host_dir().join(&file_name);
    if unix_socket_path_is_short_enough(&primary_path) {
        Some(primary_path)
    } else {
        let cache_root_key = stable_fingerprint_text(&native_export_host_dir().display().to_string());
        Some(short_native_export_host_dir(&cache_root_key).join(file_name))
    }
}

fn native_export_host_lock_path(socket_path: &Path) -> PathBuf {
    socket_path.with_extension("sock.lock")
}

fn unix_socket_path_is_short_enough(path: &Path) -> bool {
    path.as_os_str().as_encoded_bytes().len() < 104
}

fn short_native_export_host_dir(cache_root_key: &str) -> PathBuf {
    PathBuf::from(DEFAULT_SHORT_HOST_ROOT)
        .join(NATIVE_EXPORT_HOST_VERSION)
        .join(cache_root_key)
}

fn write_host_frame(stream: &mut UnixStream, bytes: &[u8]) -> Result<(), String> {
    stream
        .write_all(&(bytes.len() as u64).to_le_bytes())
        .map_err(|err| format!("failed to write native export host frame length: {err}"))?;
    stream
        .write_all(bytes)
        .map_err(|err| format!("failed to write native export host frame bytes: {err}"))
}

fn read_host_frame(stream: &mut UnixStream) -> Result<Vec<u8>, String> {
    let mut length_bytes = [0u8; 8];
    stream
        .read_exact(&mut length_bytes)
        .map_err(|err| format!("failed to read native export host frame length: {err}"))?;
    let frame_length = u64::from_le_bytes(length_bytes) as usize;
    let mut frame = vec![0u8; frame_length];
    stream
        .read_exact(&mut frame)
        .map_err(|err| format!("failed to read native export host frame bytes: {err}"))?;
    Ok(frame)
}

fn write_host_request(
    stream: &mut UnixStream,
    export_name: &str,
    source_args: &[String],
) -> Result<(), String> {
    write_host_frame(stream, export_name.as_bytes())?;
    stream
        .write_all(&(source_args.len() as u32).to_le_bytes())
        .map_err(|err| format!("failed to write native export host arg count: {err}"))?;
    for source_arg in source_args {
        write_host_frame(stream, source_arg.as_bytes())?;
    }
    stream
        .flush()
        .map_err(|err| format!("failed to flush native export host request: {err}"))
}

fn read_host_request(stream: &mut UnixStream) -> Result<(String, Vec<String>), String> {
    let export_name = String::from_utf8(read_host_frame(stream)?)
        .map_err(|err| format!("native export host export name was not UTF-8: {err}"))?;
    let mut arg_count_bytes = [0u8; 4];
    stream
        .read_exact(&mut arg_count_bytes)
        .map_err(|err| format!("failed to read native export host arg count: {err}"))?;
    let arg_count = u32::from_le_bytes(arg_count_bytes) as usize;
    let mut source_args = Vec::with_capacity(arg_count);
    for _ in 0..arg_count {
        source_args.push(
            String::from_utf8(read_host_frame(stream)?)
                .map_err(|err| format!("native export host arg was not UTF-8: {err}"))?,
        );
    }
    Ok((export_name, source_args))
}

fn write_host_response(stream: &mut UnixStream, status: u8, payload: &[u8]) -> Result<(), String> {
    stream
        .write_all(&[status])
        .map_err(|err| format!("failed to write native export host status: {err}"))?;
    write_host_frame(stream, payload)?;
    stream
        .flush()
        .map_err(|err| format!("failed to flush native export host response: {err}"))
}

fn read_host_response(stream: &mut UnixStream) -> Result<Result<Vec<u8>, String>, String> {
    let mut status = [0u8; 1];
    stream
        .read_exact(&mut status)
        .map_err(|err| format!("failed to read native export host status: {err}"))?;
    let payload = read_host_frame(stream)?;
    if status[0] == 0 {
        Ok(Ok(payload))
    } else {
        Ok(Err(
            String::from_utf8(payload)
                .map_err(|err| format!("native export host error was not UTF-8: {err}"))?,
        ))
    }
}

fn runtime_cache_root() -> PathBuf {
    if let Ok(value) = env::var("XDG_CACHE_HOME") {
        PathBuf::from(value).join("claspc-native")
    } else {
        PathBuf::from(DEFAULT_SHARED_CACHE_ROOT).join("claspc-native")
    }
}

fn trace_native_cache(message: &str) {
    if env::var("CLASP_NATIVE_TRACE_CACHE").is_ok() {
        eprintln!("[claspc-cache] {message}");
    }
}

fn trace_native_timing(message: &str) {
    if env::var("CLASP_NATIVE_TRACE_TIMING").is_ok() {
        eprintln!("[claspc-timing] {message}");
    }
}

fn trace_native_host(message: &str) {
    if env::var("CLASP_NATIVE_TRACE_HOST").is_ok() {
        eprintln!("[claspc-host] {message}");
    }
}

fn native_export_host_failure_key(image_path_text: &str, export_name: &str) -> String {
    stable_fingerprint_text(&format!("{image_path_text}\n{export_name}"))
}

fn native_export_host_failures() -> &'static Mutex<HashSet<String>> {
    NATIVE_EXPORT_HOST_FAILURES.get_or_init(|| Mutex::new(HashSet::new()))
}

fn compiler_native_image_is_stateful(image_path_text: &str) -> bool {
    Path::new(image_path_text)
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.ends_with(".compiler.native.image.json"))
        .unwrap_or(false)
}

fn read_native_image_text(image_path_text: &str) -> Result<String, String> {
    for attempt in 0..NATIVE_IMAGE_READ_RETRY_ATTEMPTS {
        match fs::read_to_string(image_path_text) {
            Ok(image_text) => return Ok(image_text),
            Err(err) if err.kind() == ErrorKind::NotFound && attempt + 1 < NATIVE_IMAGE_READ_RETRY_ATTEMPTS => {
                thread::sleep(Duration::from_millis(NATIVE_IMAGE_READ_RETRY_DELAY_MS));
            }
            Err(_) => return Err("failed to read native compiler image".to_owned()),
        }
    }

    Err("failed to read native compiler image".to_owned())
}

fn should_bypass_native_export_host(image_path_text: &str, export_name: &str) -> bool {
    if compiler_native_image_is_stateful(image_path_text) {
        return true;
    }
    let key = native_export_host_failure_key(image_path_text, export_name);
    native_export_host_failures()
        .lock()
        .map(|failures| failures.contains(&key))
        .unwrap_or(false)
}

fn record_native_export_host_failure(image_path_text: &str, export_name: &str) {
    let key = native_export_host_failure_key(image_path_text, export_name);
    if let Ok(mut failures) = native_export_host_failures().lock() {
        failures.insert(key);
    }
}

fn project_bundle_cache_dir() -> PathBuf {
    runtime_cache_root().join(PROJECT_BUNDLE_CACHE_VERSION)
}

fn native_export_host_dir() -> PathBuf {
    runtime_cache_root().join(NATIVE_EXPORT_HOST_VERSION)
}

fn project_bundle_cache_key(entry_path: &Path) -> String {
    stable_fingerprint_text(&entry_path.to_string_lossy())
}

fn project_module_cache_signature(module_path: &Path) -> Result<String, String> {
    let source = fs::read(module_path)
        .map_err(|err| format!("failed to read project module source `{}`: {err}", module_path.display()))?;
    Ok(stable_fingerprint_bytes(&source))
}

struct CachedProjectBundle {
    bundle: String,
    module_paths: Vec<PathBuf>,
}

fn read_cached_project_bundle(entry_path: &Path) -> Result<Option<CachedProjectBundle>, String> {
    let cache_dir = project_bundle_cache_dir();
    let cache_key = project_bundle_cache_key(entry_path);
    let manifest_path = cache_dir.join(format!("{cache_key}.manifest"));
    let bundle_path = cache_dir.join(format!("{cache_key}.bundle"));
    if !manifest_path.exists() || !bundle_path.exists() {
        trace_native_cache(&format!(
            "bundle miss entry={} reason=missing-files",
            entry_path.display()
        ));
        return Ok(None);
    }

    let manifest = fs::read_to_string(&manifest_path)
        .map_err(|err| format!("failed to read cached project bundle manifest `{}`: {err}", manifest_path.display()))?;
    let mut module_paths = Vec::new();
    for line in manifest.lines().filter(|line| !line.trim().is_empty()) {
        let mut parts = line.splitn(2, '\t');
        let Some(expected_signature) = parts.next() else {
            return Ok(None);
        };
        let Some(path_text) = parts.next() else {
            return Ok(None);
        };
        let module_path = PathBuf::from(path_text);
        module_paths.push(module_path.clone());
        let current_signature = match project_module_cache_signature(&module_path) {
            Ok(signature) => signature,
            Err(_) => {
                trace_native_cache(&format!(
                    "bundle miss entry={} reason=missing-module-signature module={}",
                    entry_path.display(),
                    module_path.display()
                ));
                return Ok(None);
            }
        };
        if current_signature != expected_signature {
            trace_native_cache(&format!(
                "bundle miss entry={} reason=signature-changed module={}",
                entry_path.display(),
                module_path.display()
            ));
            return Ok(None);
        }
    }

    let bundle = fs::read_to_string(&bundle_path)
        .map_err(|err| format!("failed to read cached project bundle `{}`: {err}", bundle_path.display()))?;
    trace_native_cache(&format!(
        "bundle hit entry={} manifest={} bundle={}",
        entry_path.display(),
        manifest_path.display(),
        bundle_path.display()
    ));
    Ok(Some(CachedProjectBundle { bundle, module_paths }))
}

fn write_cached_project_bundle(
    entry_path: &Path,
    module_infos: &HashMap<PathBuf, ProjectModuleInfo>,
    bundle: &str,
) -> Result<(), String> {
    let cache_dir = project_bundle_cache_dir();
    fs::create_dir_all(&cache_dir)
        .map_err(|err| format!("failed to create project bundle cache `{}`: {err}", cache_dir.display()))?;
    let cache_key = project_bundle_cache_key(entry_path);
    let manifest_path = cache_dir.join(format!("{cache_key}.manifest"));
    let bundle_path = cache_dir.join(format!("{cache_key}.bundle"));
    let unique_suffix = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    );
    let manifest_temp_path = cache_dir.join(format!("{cache_key}.manifest.tmp.{unique_suffix}"));
    let bundle_temp_path = cache_dir.join(format!("{cache_key}.bundle.tmp.{unique_suffix}"));

    let mut module_paths: Vec<PathBuf> = module_infos.keys().cloned().collect();
    module_paths.sort();
    let mut manifest_lines = Vec::new();
    for module_path in module_paths {
        let signature = project_module_cache_signature(&module_path)?;
        manifest_lines.push(format!("{signature}\t{}", module_path.to_string_lossy()));
    }

    fs::write(&bundle_temp_path, bundle).map_err(|err| {
        format!(
            "failed to write project bundle cache temp bundle `{}`: {err}",
            bundle_temp_path.display()
        )
    })?;
    fs::write(&manifest_temp_path, manifest_lines.join("\n")).map_err(|err| {
        format!(
            "failed to write project bundle cache temp manifest `{}`: {err}",
            manifest_temp_path.display()
        )
    })?;
    fs::rename(&bundle_temp_path, &bundle_path).map_err(|err| {
        format!(
            "failed to publish project bundle cache `{}`: {err}",
            bundle_path.display()
        )
    })?;
    fs::rename(&manifest_temp_path, &manifest_path).map_err(|err| {
        format!(
            "failed to publish project bundle cache manifest `{}`: {err}",
            manifest_path.display()
        )
    })?;
    Ok(())
}

fn cached_project_bundle_modules(bundle: &str, module_paths: &[PathBuf]) -> Result<Vec<ProjectBundleModule>, String> {
    let mut path_by_module_name = HashMap::new();
    for module_path in module_paths {
        let source = fs::read_to_string(module_path).map_err(|err| {
            format!(
                "failed to read cached project module `{}` for bundle metadata: {err}",
                module_path.display()
            )
        })?;
        let module_name = parse_module_name(&source)?;
        path_by_module_name.insert(module_name, module_path.to_string_lossy().into_owned());
    }

    bundle
        .split(PROJECT_BUNDLE_SEPARATOR)
        .filter(|source| !source.trim().is_empty())
        .map(|source| {
            let module_name = parse_module_name(source)?;
            let Some(canonical_path) = path_by_module_name.get(&module_name) else {
                return Err(format!(
                    "cached project bundle metadata is missing module path for `{module_name}`"
                ));
            };
            Ok(ProjectBundleModule {
                canonical_path: canonical_path.clone(),
                module_name,
                source_fingerprint: stable_fingerprint_text(source),
                import_module_names: parse_imports(source),
            })
        })
        .collect()
}

fn build_project_bundle_with_jobs_detail(entry_path: &str, max_jobs: usize) -> Result<ProjectBundleBuild, String> {
    let entry = PathBuf::from(entry_path);
    let entry_canonical = fs::canonicalize(&entry)
        .map_err(|err| format!("failed to resolve project entry module `{}`: {err}", entry.display()))?;
    if let Some(cached) = read_cached_project_bundle(&entry_canonical)? {
        return Ok(ProjectBundleBuild {
            modules: cached_project_bundle_modules(&cached.bundle, &cached.module_paths)?,
            bundle: cached.bundle,
        });
    }
    let root = entry
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let mut module_infos = HashMap::new();
    let mut discovered = HashSet::new();
    let mut pending = vec![entry.clone()];

    while !pending.is_empty() {
        let infos = load_project_module_wave(&root, &pending, max_jobs)?;
        let mut next_pending = Vec::new();

        for info in infos {
            let canonical_path = info.canonical_path.clone();
            discovered.insert(canonical_path.clone());
            for import_path in &info.import_paths {
                if discovered.contains(import_path)
                    || module_infos.contains_key(import_path)
                    || next_pending.iter().any(|candidate| candidate == import_path)
                {
                    continue;
                }
                next_pending.push(import_path.clone());
            }
            module_infos.insert(canonical_path, info);
        }

        next_pending.sort();
        pending = next_pending;
    }

    let mut ordered_sources = Vec::new();
    let mut ordered_modules = Vec::new();
    let mut seen = HashSet::new();
    append_project_bundle_module(
        &entry_canonical,
        &module_infos,
        &mut seen,
        &mut ordered_sources,
        &mut ordered_modules,
    )?;
    let bundle = ordered_sources.join(PROJECT_BUNDLE_SEPARATOR);
    let _ = write_cached_project_bundle(&entry_canonical, &module_infos, &bundle);
    Ok(ProjectBundleBuild {
        bundle,
        modules: ordered_modules,
    })
}

fn build_project_bundle_with_jobs(entry_path: &str, max_jobs: usize) -> Result<String, String> {
    build_project_bundle_with_jobs_detail(entry_path, max_jobs).map(|build| build.bundle)
}

pub fn build_project_bundle_build(entry_path: &str) -> Result<ProjectBundleBuild, String> {
    build_project_bundle_with_jobs_detail(entry_path, default_bundle_jobs())
}

pub fn build_project_bundle(entry_path: &str) -> Result<String, String> {
    build_project_bundle_with_jobs(entry_path, default_bundle_jobs())
}

pub fn project_declares_backend_surface(source: &str) -> bool {
    source.lines().any(|line| {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return false;
        }
        let keyword = trimmed.split_whitespace().next().unwrap_or("");
        BACKEND_DECLARATION_KEYWORDS.contains(&keyword)
            || trimmed
                .split(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '_'))
                .any(|token| NATIVE_RUNTIME_ONLY_SYMBOLS.contains(&token))
    })
}

struct NativeExportHost {
    runtime: ClaspRtRuntime,
    image_path: *mut ClaspRtString,
    image: *mut ClaspRtJson,
    module_name_result: *mut ClaspRtResultString,
    module_name: *mut ClaspRtString,
}

impl NativeExportHost {
    unsafe fn cleanup(&mut self) {
        release(&mut self.runtime, self.module_name as *mut ClaspRtHeader);
        release(&mut self.runtime, self.module_name_result as *mut ClaspRtHeader);
        release(&mut self.runtime, self.image as *mut ClaspRtHeader);
        release(&mut self.runtime, self.image_path as *mut ClaspRtHeader);
        self.module_name = null_mut();
        self.module_name_result = null_mut();
        self.image = null_mut();
        self.image_path = null_mut();
        clasp_rt_shutdown(&mut self.runtime);
    }

    unsafe fn from_image_path(image_path_text: &str) -> Result<NativeExportHost, String> {
        let mut host = NativeExportHost {
            runtime: mem::zeroed(),
            image_path: null_mut(),
            image: null_mut(),
            module_name_result: null_mut(),
            module_name: null_mut(),
        };

        clasp_rt_init(&mut host.runtime);

        let result = (|| {
            let image_path_c =
                CString::new(image_path_text).map_err(|_| "image path contains interior NUL byte".to_owned())?;
            host.image_path = clasp_rt_string_from_utf8(image_path_c.as_ptr());
            let image_text = read_native_image_text(image_path_text)?;
            let image_text_c =
                CString::new(image_text.as_str()).map_err(|_| "native compiler image contains interior NUL byte".to_owned())?;
            let image_text_value = clasp_rt_string_from_utf8(image_text_c.as_ptr());
            host.image = clasp_rt_json_from_string(image_text_value);
            release(&mut host.runtime, image_text_value as *mut ClaspRtHeader);
            if !clasp_rt_native_image_validate(host.image) {
                return Err("runtime rejected native compiler image".to_owned());
            }

            host.module_name_result = clasp_rt_native_image_module_name(host.image);
            if host.module_name_result.is_null() || !(*host.module_name_result).is_ok {
                return Err("runtime failed to resolve native compiler image module name".to_owned());
            }
            host.module_name = (*host.module_name_result).value;
            clasp_rt_retain(host.module_name as *mut ClaspRtHeader);

            let loaded_image = clasp_rt_native_module_image_load(host.image);
            if loaded_image.is_null() {
                return Err("runtime failed to load native compiler image".to_owned());
            }
            if !clasp_rt_activate_native_module_image(&mut host.runtime, loaded_image) {
                clasp_rt_native_module_image_free(&mut host.runtime, loaded_image);
                return Err("runtime failed to activate native compiler image".to_owned());
            }

            Ok(())
        })();

        match result {
            Ok(()) => Ok(host),
            Err(message) => {
                host.cleanup();
                Err(message)
            }
        }
    }

    unsafe fn execute_export(&mut self, export_name: &str, source_args: &[String]) -> Result<Vec<u8>, String> {
        let dispatch_start = Instant::now();
        let mut target_export: *mut ClaspRtString = null_mut();
        let mut dispatch_arg_cstrings: Vec<CString> = Vec::new();
        let mut owned_dispatch_args: Vec<*mut ClaspRtHeader> = Vec::new();
        let mut dispatch_value: *mut ClaspRtHeader = null_mut();

        let result = (|| {
            let export_c =
                CString::new(export_name).map_err(|_| "export name contains interior NUL byte".to_owned())?;
            target_export = clasp_rt_string_from_utf8(export_c.as_ptr());

            for source_text in source_args {
                let source_text_c =
                    CString::new(source_text.as_str()).map_err(|_| "source input contains interior NUL byte".to_owned())?;
                let dispatch_arg = clasp_rt_string_from_utf8(source_text_c.as_ptr()) as *mut ClaspRtHeader;
                dispatch_arg_cstrings.push(source_text_c);
                owned_dispatch_args.push(dispatch_arg);
            }

            let args_ptr = if owned_dispatch_args.is_empty() {
                null_mut()
            } else {
                owned_dispatch_args.as_mut_ptr()
            };
            dispatch_value = clasp_rt_call_native_dispatch(
                &mut self.runtime,
                self.module_name,
                target_export,
                args_ptr,
                owned_dispatch_args.len(),
            );
            if dispatch_value.is_null() {
                return Err("runtime failed to execute native compiler export".to_owned());
            }

            Ok(string_bytes(dispatch_value as *mut ClaspRtString).to_vec())
        })();

        release(&mut self.runtime, dispatch_value);
        for dispatch_arg in owned_dispatch_args {
            release(&mut self.runtime, dispatch_arg);
        }
        release(&mut self.runtime, target_export as *mut ClaspRtHeader);

        trace_native_timing(&format!(
            "export={} phase=host_dispatch ms={} argc={}",
            export_name,
            dispatch_start.elapsed().as_millis(),
            source_args.len()
        ));

        result
    }
}

impl Drop for NativeExportHost {
    fn drop(&mut self) {
        unsafe {
            self.cleanup();
        }
    }
}

fn write_native_export_host_lock_metadata(lock_path: &Path, lock_file: &mut fs::File) -> Result<(), String> {
    lock_file
        .write_all(std::process::id().to_string().as_bytes())
        .map_err(|err| {
            format!(
                "failed to write native export host lock metadata `{}`: {err}",
                lock_path.display()
            )
        })
}

fn native_export_host_lock_owner_pid(lock_path: &Path) -> Option<u32> {
    fs::read_to_string(lock_path).ok()?.trim().parse::<u32>().ok()
}

fn process_appears_alive(pid: u32) -> bool {
    PathBuf::from("/proc").join(pid.to_string()).exists()
}

fn clear_native_export_host_path(path: &Path) -> bool {
    fs::remove_file(path).is_ok()
}

fn recover_stale_native_export_host_state(socket_path: &Path, lock_path: &Path) -> bool {
    let lock_owner_alive = native_export_host_lock_owner_pid(lock_path)
        .map(process_appears_alive)
        .unwrap_or(false);
    let mut recovered = false;

    if lock_path.exists() && !lock_owner_alive {
        if clear_native_export_host_path(lock_path) {
            recovered = true;
            trace_native_host(&format!(
                "cleared stale host lock socket={} lock={}",
                socket_path.display(),
                lock_path.display()
            ));
        }
    }

    if socket_path.exists() && (!lock_path.exists() || recovered) {
        match UnixStream::connect(socket_path) {
            Ok(stream) => drop(stream),
            Err(err) => {
                if clear_native_export_host_path(socket_path) {
                    recovered = true;
                    trace_native_host(&format!(
                        "cleared orphaned host socket socket={} reason={err}",
                        socket_path.display()
                    ));
                }
            }
        }
    }

    recovered
}

fn wait_for_native_export_host(socket_path: &Path) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if socket_path.exists() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err(format!(
        "timed out waiting for native export host socket `{}`",
        socket_path.display()
    ))
}

fn wait_for_native_export_host_startup(socket_path: &Path, lock_path: &Path) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if recover_stale_native_export_host_state(socket_path, lock_path) {
            return Ok(());
        }
        if socket_path.exists() {
            return Ok(());
        }
        if !lock_path.exists() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(50));
    }
    Err(format!(
        "timed out waiting for native export host startup socket=`{}` lock=`{}`",
        socket_path.display(),
        lock_path.display()
    ))
}

fn spawn_native_export_host(image_path_text: &str, socket_path: &Path) -> Result<(), String> {
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create native export host dir `{}`: {err}", parent.display()))?;
    }
    let _ = fs::remove_file(socket_path);
    let current_exe =
        env::current_exe().map_err(|err| format!("failed to resolve current claspc binary: {err}"))?;
    let mut command = Command::new(current_exe);
    command
        .arg("__serve-native-export-host")
        .arg(image_path_text)
        .arg(socket_path)
        .env("CLASP_NATIVE_DISABLE_EXPORT_HOST", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null());
    if env::var("CLASP_NATIVE_TRACE_HOST").is_ok() {
        command.stderr(Stdio::inherit());
    } else {
        command.stderr(Stdio::null());
    }
    command
        .spawn()
        .map_err(|err| format!("failed to start native export host: {err}"))?;
    wait_for_native_export_host(socket_path)
}

fn execute_native_export_via_host(
    image_path_text: &str,
    export_name: &str,
    source_args: &[String],
) -> Result<Vec<u8>, String> {
    let Some(socket_path) = native_export_host_socket_path(image_path_text) else {
        return Err("unable to determine native export host socket path".to_owned());
    };
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent).map_err(|err| {
            format!(
                "failed to create native export host dir `{}`: {err}",
                parent.display()
            )
        })?;
    }
    let lock_path = native_export_host_lock_path(&socket_path);

    for attempt in 0..4 {
        match UnixStream::connect(&socket_path) {
            Ok(mut stream) => {
                write_host_request(&mut stream, export_name, source_args)?;
                return read_host_response(&mut stream)?;
            }
            Err(err) => {
                recover_stale_native_export_host_state(&socket_path, &lock_path);
                match fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&lock_path)
                {
                    Ok(mut lock_file) => {
                        if let Err(message) =
                            write_native_export_host_lock_metadata(&lock_path, &mut lock_file)
                        {
                            drop(lock_file);
                            let _ = fs::remove_file(&lock_path);
                            return Err(message);
                        }
                        trace_native_host(&format!(
                            "starting host image={} socket={} reason={err}",
                            image_path_text,
                            socket_path.display()
                        ));
                        let spawn_result = spawn_native_export_host(image_path_text, &socket_path);
                        drop(lock_file);
                        let _ = fs::remove_file(&lock_path);
                        spawn_result?;
                    }
                    Err(lock_err) if lock_err.kind() == ErrorKind::AlreadyExists => {
                        wait_for_native_export_host_startup(&socket_path, &lock_path)?;
                    }
                    Err(lock_err) => {
                        return Err(format!(
                            "failed to acquire native export host lock `{}`: {lock_err}",
                            lock_path.display()
                        ));
                    }
                }

                if attempt == 3 {
                    return Err(format!(
                        "failed to connect to native export host `{}`: {err}",
                        socket_path.display()
                    ));
                }
            }
        }
    }

    Err("native export host connection attempts exhausted".to_owned())
}

fn handle_native_export_host_client(host: &mut NativeExportHost, stream: &mut UnixStream) -> Result<(), String> {
    let (export_name, source_args) = read_host_request(stream)?;
    match unsafe { host.execute_export(&export_name, &source_args) } {
        Ok(bytes) => write_host_response(stream, 0, &bytes),
        Err(message) => write_host_response(stream, 1, message.as_bytes()),
    }
}

fn run_native_export_host_server_inner(image_path_text: &str, socket_path_text: &str) -> Result<(), String> {
    let socket_path = PathBuf::from(socket_path_text);
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create native export host dir `{}`: {err}", parent.display()))?;
    }

    let mut host = unsafe { NativeExportHost::from_image_path(image_path_text)? };
    let _ = fs::remove_file(&socket_path);
    let listener = UnixListener::bind(&socket_path)
        .map_err(|err| format!("failed to bind native export host `{}`: {err}", socket_path.display()))?;
    listener
        .set_nonblocking(true)
        .map_err(|err| format!("failed to configure native export host socket `{}`: {err}", socket_path.display()))?;

    let idle_timeout = Duration::from_secs(120);
    let mut last_activity = Instant::now();
    loop {
        match listener.accept() {
            Ok((mut stream, _)) => {
                last_activity = Instant::now();
                if let Err(message) = handle_native_export_host_client(&mut host, &mut stream) {
                    trace_native_host(&format!("client error socket={} message={message}", socket_path.display()));
                }
            }
            Err(err) if err.kind() == ErrorKind::WouldBlock => {
                if last_activity.elapsed() >= idle_timeout {
                    break;
                }
                thread::sleep(Duration::from_millis(25));
            }
            Err(err) => {
                let _ = fs::remove_file(&socket_path);
                return Err(format!(
                    "native export host accept failed for `{}`: {err}",
                    socket_path.display()
                ));
            }
        }
    }

    let _ = fs::remove_file(&socket_path);
    Ok(())
}

pub fn run_native_export_host_server(image_path_text: &str, socket_path_text: &str) -> Result<(), String> {
    let image_path = image_path_text.to_owned();
    let socket_path = socket_path_text.to_owned();
    thread::Builder::new()
        .name("clasp-native-export-host".to_owned())
        .stack_size(NATIVE_EXPORT_HOST_STACK_BYTES)
        .spawn(move || run_native_export_host_server_inner(&image_path, &socket_path))
        .map_err(|err| format!("failed to spawn native export host server thread: {err}"))?
        .join()
        .map_err(|_| "native export host server thread panicked".to_owned())?
}

pub unsafe fn execute_native_export_from_image_path(
    image_path_text: &str,
    export_name: &str,
    source_text: Option<&str>,
) -> Result<Vec<u8>, String> {
    let source_args = match source_text {
        Some(value) => vec![value.to_owned()],
        None => Vec::new(),
    };
    execute_native_export_from_image_path_args(image_path_text, export_name, &source_args)
}

pub unsafe fn execute_native_export_from_image_path_args(
    image_path_text: &str,
    export_name: &str,
    source_args: &[String],
) -> Result<Vec<u8>, String> {
    if env::var("CLASP_NATIVE_DISABLE_EXPORT_HOST").is_err()
        && !should_bypass_native_export_host(image_path_text, export_name)
    {
        match execute_native_export_via_host(image_path_text, export_name, source_args) {
            Ok(bytes) => return Ok(bytes),
            Err(message) => {
                if message.contains("runtime failed to execute native compiler export") {
                    record_native_export_host_failure(image_path_text, export_name);
                }
                trace_native_host(&format!(
                    "fallback image={} export={} reason={message}",
                    image_path_text,
                    export_name
                ));
            }
        }
    } else if env::var("CLASP_NATIVE_DISABLE_EXPORT_HOST").is_err() {
        trace_native_host(&format!(
            "bypass image={} export={} reason=previous-host-failure",
            image_path_text,
            export_name
        ));
    }

    execute_native_export_from_image_path_args_local(image_path_text, export_name, source_args)
}

unsafe fn execute_native_export_from_image_path_args_local(
    image_path_text: &str,
    export_name: &str,
    source_args: &[String],
) -> Result<Vec<u8>, String> {
    let export_start = Instant::now();
    let mut runtime: ClaspRtRuntime = mem::zeroed();
    let mut image_path: *mut ClaspRtString = null_mut();
    let mut image: *mut ClaspRtJson = null_mut();
    let mut module_name_result: *mut ClaspRtResultString = null_mut();
    let mut loaded_image: *mut ClaspRtNativeModuleImage = null_mut();
    let mut module_name: *mut ClaspRtString = null_mut();
    let mut target_export: *mut ClaspRtString = null_mut();
    let mut dispatch_arg_cstrings: Vec<CString> = Vec::new();
    let mut owned_dispatch_args: Vec<*mut ClaspRtHeader> = Vec::new();
    let mut dispatch_value: *mut ClaspRtHeader = null_mut();

    clasp_rt_init(&mut runtime);

    let result = (|| {
        let load_start = Instant::now();
        let image_path_c =
            CString::new(image_path_text).map_err(|_| "image path contains interior NUL byte".to_owned())?;
        image_path = clasp_rt_string_from_utf8(image_path_c.as_ptr());
        let image_text = read_native_image_text(image_path_text)?;
        let image_text_c =
            CString::new(image_text.as_str()).map_err(|_| "native compiler image contains interior NUL byte".to_owned())?;
        let image_text_value = clasp_rt_string_from_utf8(image_text_c.as_ptr());
        image = clasp_rt_json_from_string(image_text_value);
        release(&mut runtime, image_text_value as *mut ClaspRtHeader);
        if !clasp_rt_native_image_validate(image) {
            return Err("runtime rejected native compiler image".to_owned());
        }

        module_name_result = clasp_rt_native_image_module_name(image);
        if module_name_result.is_null() || !(*module_name_result).is_ok {
            return Err("runtime failed to resolve native compiler image module name".to_owned());
        }
        module_name = (*module_name_result).value;
        clasp_rt_retain(module_name as *mut ClaspRtHeader);

        loaded_image = clasp_rt_native_module_image_load(image);
        if loaded_image.is_null() {
            return Err("runtime failed to load native compiler image".to_owned());
        }

        if !clasp_rt_activate_native_module_image(&mut runtime, loaded_image) {
            return Err("runtime failed to activate native compiler image".to_owned());
        }
        loaded_image = null_mut();
        trace_native_timing(&format!(
            "export={} phase=load_activate ms={} argc={}",
            export_name,
            load_start.elapsed().as_millis(),
            source_args.len()
        ));

        let export_c =
            CString::new(export_name).map_err(|_| "export name contains interior NUL byte".to_owned())?;
        target_export = clasp_rt_string_from_utf8(export_c.as_ptr());

        for source_text in source_args {
            let source_text_c =
                CString::new(source_text.as_str()).map_err(|_| "source input contains interior NUL byte".to_owned())?;
            let dispatch_arg = clasp_rt_string_from_utf8(source_text_c.as_ptr()) as *mut ClaspRtHeader;
            dispatch_arg_cstrings.push(source_text_c);
            owned_dispatch_args.push(dispatch_arg);
        }

        let args_ptr = if owned_dispatch_args.is_empty() {
            null_mut()
        } else {
            owned_dispatch_args.as_mut_ptr()
        };
        let dispatch_start = Instant::now();
        dispatch_value = clasp_rt_call_native_dispatch(
            &mut runtime,
            module_name,
            target_export,
            args_ptr,
            owned_dispatch_args.len(),
        );
        if dispatch_value.is_null() {
            return Err("runtime failed to execute native compiler export".to_owned());
        }
        trace_native_timing(&format!(
            "export={} phase=dispatch ms={} argc={}",
            export_name,
            dispatch_start.elapsed().as_millis(),
            source_args.len()
        ));

        Ok(string_bytes(dispatch_value as *mut ClaspRtString).to_vec())
    })();

    release(&mut runtime, dispatch_value);
    for dispatch_arg in owned_dispatch_args {
        release(&mut runtime, dispatch_arg);
    }
    release(&mut runtime, target_export as *mut ClaspRtHeader);
    clasp_rt_native_module_image_free(&mut runtime, loaded_image);
    release(&mut runtime, module_name as *mut ClaspRtHeader);
    release(&mut runtime, module_name_result as *mut ClaspRtHeader);
    release(&mut runtime, image as *mut ClaspRtHeader);
    release(&mut runtime, image_path as *mut ClaspRtHeader);
    clasp_rt_shutdown(&mut runtime);
    trace_native_timing(&format!(
        "export={} phase=total ms={} argc={}",
        export_name,
        export_start.elapsed().as_millis(),
        source_args.len()
    ));

    result
}

pub unsafe fn execute_native_export_from_image_path_args_local_only(
    image_path_text: &str,
    export_name: &str,
    source_args: &[String],
) -> Result<Vec<u8>, String> {
    execute_native_export_from_image_path_args_local(image_path_text, export_name, source_args)
}

pub unsafe fn execute_native_export_from_image_text(
    image_text: &str,
    export_name: &str,
    source_text: Option<&str>,
) -> Result<Vec<u8>, String> {
    let mut runtime: ClaspRtRuntime = mem::zeroed();
    let mut image_string: *mut ClaspRtString = null_mut();
    let mut image: *mut ClaspRtJson = null_mut();
    let mut module_name_result: *mut ClaspRtResultString = null_mut();
    let mut loaded_image: *mut ClaspRtNativeModuleImage = null_mut();
    let mut module_name: *mut ClaspRtString = null_mut();
    let mut target_export: *mut ClaspRtString = null_mut();
    let mut owned_dispatch_arg: *mut ClaspRtHeader = null_mut();
    let mut dispatch_args: [*mut ClaspRtHeader; 1] = [null_mut()];
    let mut dispatch_arg_count = 0usize;
    let mut dispatch_value: *mut ClaspRtHeader = null_mut();

    clasp_rt_init(&mut runtime);

    let result = (|| {
        let image_text_c =
            CString::new(image_text).map_err(|_| "native image contains interior NUL byte".to_owned())?;
        image_string = clasp_rt_string_from_utf8(image_text_c.as_ptr());
        image = clasp_rt_json_from_string(image_string);
        if !clasp_rt_native_image_validate(image) {
            return Err("runtime rejected embedded native image".to_owned());
        }

        module_name_result = clasp_rt_native_image_module_name(image);
        if module_name_result.is_null() || !(*module_name_result).is_ok {
            return Err("runtime failed to resolve embedded native image module name".to_owned());
        }
        module_name = (*module_name_result).value;
        clasp_rt_retain(module_name as *mut ClaspRtHeader);

        loaded_image = clasp_rt_native_module_image_load(image);
        if loaded_image.is_null() {
            return Err("runtime failed to load embedded native image".to_owned());
        }

        if !clasp_rt_activate_native_module_image(&mut runtime, loaded_image) {
            return Err("runtime failed to activate embedded native image".to_owned());
        }
        loaded_image = null_mut();

        let export_c =
            CString::new(export_name).map_err(|_| "export name contains interior NUL byte".to_owned())?;
        target_export = clasp_rt_string_from_utf8(export_c.as_ptr());

        if let Some(source_text) = source_text {
            let source_text_c =
                CString::new(source_text).map_err(|_| "source input contains interior NUL byte".to_owned())?;
            owned_dispatch_arg = clasp_rt_string_from_utf8(source_text_c.as_ptr()) as *mut ClaspRtHeader;
            dispatch_args[0] = owned_dispatch_arg;
            dispatch_arg_count = 1;
        }

        let args_ptr = if dispatch_arg_count == 0 {
            null_mut()
        } else {
            dispatch_args.as_mut_ptr()
        };
        dispatch_value = clasp_rt_call_native_dispatch(
            &mut runtime,
            module_name,
            target_export,
            args_ptr,
            dispatch_arg_count,
        );
        if dispatch_value.is_null() {
            return Err("runtime failed to execute embedded native export".to_owned());
        }

        Ok(string_bytes(dispatch_value as *mut ClaspRtString).to_vec())
    })();

    release(&mut runtime, dispatch_value);
    release(&mut runtime, owned_dispatch_arg);
    release(&mut runtime, target_export as *mut ClaspRtHeader);
    clasp_rt_native_module_image_free(&mut runtime, loaded_image);
    release(&mut runtime, module_name as *mut ClaspRtHeader);
    release(&mut runtime, module_name_result as *mut ClaspRtHeader);
    release(&mut runtime, image as *mut ClaspRtHeader);
    release(&mut runtime, image_string as *mut ClaspRtHeader);
    clasp_rt_shutdown(&mut runtime);

    result
}

pub unsafe fn execute_native_route_from_image_text(
    image_text: &str,
    method: &str,
    path: &str,
    request_json: &str,
) -> Result<Vec<u8>, String> {
    let mut runtime: ClaspRtRuntime = mem::zeroed();
    let mut image_string: *mut ClaspRtString = null_mut();
    let mut image: *mut ClaspRtJson = null_mut();
    let mut module_name_result: *mut ClaspRtResultString = null_mut();
    let mut loaded_image: *mut ClaspRtNativeModuleImage = null_mut();
    let mut module_name: *mut ClaspRtString = null_mut();
    let mut method_value: *mut ClaspRtString = null_mut();
    let mut path_value: *mut ClaspRtString = null_mut();
    let mut request_value: *mut ClaspRtString = null_mut();
    let mut result_value: *mut ClaspRtResultString = null_mut();

    clasp_rt_init(&mut runtime);

    let result = (|| {
        let image_text_c =
            CString::new(image_text).map_err(|_| "native image contains interior NUL byte".to_owned())?;
        image_string = clasp_rt_string_from_utf8(image_text_c.as_ptr());
        image = clasp_rt_json_from_string(image_string);
        if !clasp_rt_native_image_validate(image) {
            return Err("runtime rejected embedded native image".to_owned());
        }

        module_name_result = clasp_rt_native_image_module_name(image);
        if module_name_result.is_null() || !(*module_name_result).is_ok {
            return Err("runtime failed to resolve embedded native image module name".to_owned());
        }
        module_name = (*module_name_result).value;
        clasp_rt_retain(module_name as *mut ClaspRtHeader);

        loaded_image = clasp_rt_native_module_image_load(image);
        if loaded_image.is_null() {
            return Err("runtime failed to load embedded native image".to_owned());
        }

        if !clasp_rt_activate_native_module_image(&mut runtime, loaded_image) {
            return Err("runtime failed to activate embedded native image".to_owned());
        }
        loaded_image = null_mut();

        let method_c =
            CString::new(method).map_err(|_| "route method contains interior NUL byte".to_owned())?;
        let path_c = CString::new(path).map_err(|_| "route path contains interior NUL byte".to_owned())?;
        let request_c =
            CString::new(request_json).map_err(|_| "route request contains interior NUL byte".to_owned())?;
        method_value = clasp_rt_string_from_utf8(method_c.as_ptr());
        path_value = clasp_rt_string_from_utf8(path_c.as_ptr());
        request_value = clasp_rt_string_from_utf8(request_c.as_ptr());

        result_value =
            clasp_rt_call_native_route_json(&mut runtime, module_name, method_value, path_value, request_value);
        if result_value.is_null() {
            return Err("runtime failed to execute embedded native route".to_owned());
        }
        if !(*result_value).is_ok {
            return Err(String::from_utf8_lossy(string_bytes((*result_value).value)).into_owned());
        }

        Ok(string_bytes((*result_value).value).to_vec())
    })();

    release(&mut runtime, result_value as *mut ClaspRtHeader);
    release(&mut runtime, request_value as *mut ClaspRtHeader);
    release(&mut runtime, path_value as *mut ClaspRtHeader);
    release(&mut runtime, method_value as *mut ClaspRtHeader);
    clasp_rt_native_module_image_free(&mut runtime, loaded_image);
    release(&mut runtime, module_name as *mut ClaspRtHeader);
    release(&mut runtime, module_name_result as *mut ClaspRtHeader);
    release(&mut runtime, image as *mut ClaspRtHeader);
    release(&mut runtime, image_string as *mut ClaspRtHeader);
    clasp_rt_shutdown(&mut runtime);

    result
}

#[cfg(test)]
mod tests {
    use super::{
        build_module_scoped_bundle, build_project_bundle_build, build_project_bundle_with_jobs,
        project_bundle_cache_dir, project_bundle_cache_key, PROJECT_BUNDLE_SEPARATOR,
    };
    use std::fs;
    use std::os::unix::net::UnixListener;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique_test_root(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("clasp-tool-support-{name}-{}-{stamp}", std::process::id()))
    }

    fn unique_short_socket_root(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("cts-{name}-{}-{stamp}", std::process::id()))
    }

    #[test]
    fn build_project_bundle_preserves_import_preorder() {
        let root = unique_test_root("bundle-order");
        fs::create_dir_all(root.join("Shared/Nested")).expect("create test module tree");
        fs::write(
            root.join("Main.clasp"),
            "module Main\nimport Shared.User\nimport Shared.Note\nmain : Str\nmain = greeting\n",
        )
        .expect("write Main");
        fs::write(
            root.join("Shared/User.clasp"),
            "module Shared.User\nimport Shared.Nested.Helper\ngreeting : Str\ngreeting = helper\n",
        )
        .expect("write Shared.User");
        fs::write(
            root.join("Shared/Nested/Helper.clasp"),
            "module Shared.Nested.Helper\nhelper : Str\nhelper = \"ok\"\n",
        )
        .expect("write Shared.Nested.Helper");
        fs::write(
            root.join("Shared/Note.clasp"),
            "module Shared.Note\nnote : Str\nnote = \"note\"\n",
        )
        .expect("write Shared.Note");

        let bundle =
            build_project_bundle_with_jobs(root.join("Main.clasp").to_str().expect("utf8 path"), 4).expect("build bundle");
        let parts: Vec<&str> = bundle.split(PROJECT_BUNDLE_SEPARATOR).collect();

        assert_eq!(parts.len(), 4);
        assert!(parts[0].contains("module Main"));
        assert!(parts[1].contains("module Shared.User"));
        assert!(parts[2].contains("module Shared.Nested.Helper"));
        assert!(parts[3].contains("module Shared.Note"));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn build_project_bundle_matches_serial_output() {
        let root = unique_test_root("bundle-deterministic");
        fs::create_dir_all(root.join("Shared")).expect("create shared dir");
        fs::write(
            root.join("Main.clasp"),
            "module Main with Shared.User\nmain : Str\nmain = greeting\n",
        )
        .expect("write Main");
        fs::write(
            root.join("Shared/User.clasp"),
            "module Shared.User\ngreeting : Str\ngreeting = \"hi\"\n",
        )
        .expect("write Shared.User");

        let entry = root.join("Main.clasp");
        let serial =
            build_project_bundle_with_jobs(entry.to_str().expect("utf8 path"), 1).expect("build serial bundle");
        let parallel =
            build_project_bundle_with_jobs(entry.to_str().expect("utf8 path"), 4).expect("build parallel bundle");

        assert_eq!(serial, parallel);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn build_module_scoped_bundle_keeps_entry_and_transitive_imports_only() {
        let root = unique_test_root("bundle-scope");
        fs::create_dir_all(root.join("Shared/Nested")).expect("create test module tree");
        fs::write(
            root.join("Main.clasp"),
            "module Main\nimport Shared.User\nimport Shared.Note\nmain : Str\nmain = greeting\n",
        )
        .expect("write Main");
        fs::write(
            root.join("Shared/User.clasp"),
            "module Shared.User\nimport Shared.Nested.Helper\ngreeting : Str\ngreeting = helper\n",
        )
        .expect("write Shared.User");
        fs::write(
            root.join("Shared/Nested/Helper.clasp"),
            "module Shared.Nested.Helper\nhelper : Str\nhelper = \"ok\"\n",
        )
        .expect("write Shared.Nested.Helper");
        fs::write(
            root.join("Shared/Note.clasp"),
            "module Shared.Note\nnote : Str\nnote = \"note\"\n",
        )
        .expect("write Shared.Note");

        let build = build_project_bundle_build(root.join("Main.clasp").to_str().expect("utf8 path"))
            .expect("build bundle");
        let scoped = build_module_scoped_bundle(&build, "Shared.User").expect("scoped bundle");
        let parts: Vec<&str> = scoped.split(PROJECT_BUNDLE_SEPARATOR).collect();

        assert_eq!(parts.len(), 2);
        assert!(parts[0].contains("module Shared.User"));
        assert!(parts[1].contains("module Shared.Nested.Helper"));
        assert!(!scoped.contains("module Main"));
        assert!(!scoped.contains("module Shared.Note"));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn build_project_bundle_reuses_cached_bundle_when_sources_are_unchanged() {
        let _env_lock = super::TEST_ENV_LOCK.lock().expect("lock test env");
        let root = unique_test_root("bundle-cache");
        let cache_root = unique_test_root("bundle-cache-store");
        fs::create_dir_all(root.join("Shared")).expect("create shared dir");
        fs::create_dir_all(&cache_root).expect("create cache dir");
        std::env::set_var("XDG_CACHE_HOME", &cache_root);

        fs::write(
            root.join("Main.clasp"),
            "module Main\nimport Shared.User\nmain : Str\nmain = greeting\n",
        )
        .expect("write Main");
        fs::write(
            root.join("Shared/User.clasp"),
            "module Shared.User\ngreeting : Str\ngreeting = \"hi\"\n",
        )
        .expect("write Shared.User");

        let entry = root.join("Main.clasp");
        let _ = build_project_bundle_with_jobs(entry.to_str().expect("utf8 path"), 4).expect("build cached bundle");

        let entry_canonical = fs::canonicalize(&entry).expect("canonical entry");
        let cache_key = project_bundle_cache_key(&entry_canonical);
        let bundle_path = project_bundle_cache_dir().join(format!("{cache_key}.bundle"));
        fs::write(
            &bundle_path,
            format!(
                "module Main\nimport Shared.User\nmain : Str\nmain = greeting\n{PROJECT_BUNDLE_SEPARATOR}module Shared.User\ngreeting : Str\ngreeting = \"cached\"\n"
            ),
        )
        .expect("overwrite cached bundle");

        let cached =
            build_project_bundle_with_jobs(entry.to_str().expect("utf8 path"), 4).expect("reuse cached bundle");
        assert!(cached.contains("greeting = \"cached\""));

        std::env::remove_var("XDG_CACHE_HOME");
        let _ = fs::remove_dir_all(cache_root);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn project_module_cache_signature_changes_for_same_length_edits() {
        let root = unique_test_root("bundle-signature");
        fs::create_dir_all(&root).expect("create signature root");
        let module_path = root.join("Main.clasp");
        fs::write(&module_path, "module Main\nmain : Str\nmain = \"aaaa\"\n").expect("write initial module");
        let initial = super::project_module_cache_signature(&module_path).expect("initial signature");

        fs::write(&module_path, "module Main\nmain : Str\nmain = \"bbbb\"\n").expect("write changed module");
        let changed = super::project_module_cache_signature(&module_path).expect("changed signature");

        assert_ne!(initial, changed);

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn host_failure_cache_is_keyed_by_image_and_export() {
        let image_path = "/tmp/compiler-a.native.image.json";
        assert!(!super::should_bypass_native_export_host(
            image_path,
            "nativeImageProjectModuleDeclsText"
        ));

        super::record_native_export_host_failure(image_path, "nativeImageProjectModuleDeclsText");

        assert!(super::should_bypass_native_export_host(
            image_path,
            "nativeImageProjectModuleDeclsText"
        ));
        assert!(!super::should_bypass_native_export_host(
            image_path,
            "nativeImageProjectBuildPlanText"
        ));
        assert!(!super::should_bypass_native_export_host(
            "/tmp/compiler-b.native.image.json",
            "nativeImageProjectModuleDeclsText"
        ));
    }

    #[test]
    fn compiler_images_bypass_the_native_export_host() {
        assert!(super::should_bypass_native_export_host(
            "/tmp/embedded.compiler.native.image.json",
            "checkProjectText"
        ));
        assert!(super::should_bypass_native_export_host(
            "/tmp/stage1.compiler.native.image.json",
            "nativeImageProjectBuildPlanText"
        ));
        assert!(!super::should_bypass_native_export_host(
            "/tmp/embedded.native.image.json",
            "checkProjectText"
        ));
    }

    #[test]
    fn read_native_image_text_retries_transient_missing_file() {
        let root = unique_test_root("native-image-read-retry");
        fs::create_dir_all(&root).expect("create retry root");
        let image_path = root.join("embedded.compiler.native.image.json");
        let image_path_for_writer = image_path.clone();

        let writer = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(40));
            fs::write(&image_path_for_writer, "{\"module\":\"Main\"}").expect("write delayed native image");
        });

        let image_text =
            super::read_native_image_text(image_path.to_str().expect("utf8 image path")).expect("read retried image");
        writer.join().expect("join delayed image writer");

        assert_eq!(image_text, "{\"module\":\"Main\"}");

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn stale_native_export_host_state_recovers_empty_lock_and_orphaned_socket() {
        let root = unique_short_socket_root("stale");
        fs::create_dir_all(&root).expect("create host state root");
        let socket_path = root.join("host.sock");
        let lock_path = super::native_export_host_lock_path(&socket_path);

        let listener = UnixListener::bind(&socket_path).expect("bind stale socket");
        drop(listener);
        fs::write(&lock_path, "").expect("write stale lock");

        assert!(socket_path.exists());
        assert!(lock_path.exists());
        assert!(super::recover_stale_native_export_host_state(&socket_path, &lock_path));
        assert!(!socket_path.exists());
        assert!(!lock_path.exists());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn stale_native_export_host_state_keeps_live_lock_owner() {
        let root = unique_short_socket_root("live");
        fs::create_dir_all(&root).expect("create host lock root");
        let socket_path = root.join("host.sock");
        let lock_path = super::native_export_host_lock_path(&socket_path);
        fs::write(&lock_path, std::process::id().to_string()).expect("write live lock");

        assert!(!super::recover_stale_native_export_host_state(&socket_path, &lock_path));
        assert!(lock_path.exists());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn native_export_host_socket_path_falls_back_to_short_root_for_long_cache_paths() {
        let _env_lock = super::TEST_ENV_LOCK.lock().expect("lock test env");
        let cache_root = unique_test_root("long-host-cache");
        let image_root = unique_test_root("long-host-image");
        let mut deep_cache_root = cache_root.clone();
        for _ in 0..8 {
            deep_cache_root = deep_cache_root.join("deep-cache-segment");
        }
        fs::create_dir_all(&deep_cache_root).expect("create deep cache root");
        fs::create_dir_all(&image_root).expect("create image root");
        std::env::set_var("XDG_CACHE_HOME", &deep_cache_root);

        let image_path = image_root.join("compiler.native.image.json");
        fs::write(&image_path, "{\"module\":\"Main\"}").expect("write image");

        let socket_path = super::native_export_host_socket_path(image_path.to_str().expect("utf8 image path"))
            .expect("socket path");
        let short_root = PathBuf::from(super::DEFAULT_SHORT_HOST_ROOT)
            .join(super::NATIVE_EXPORT_HOST_VERSION);

        assert!(socket_path.starts_with(&short_root));
        assert!(super::unix_socket_path_is_short_enough(&socket_path));

        std::env::remove_var("XDG_CACHE_HOME");
        let _ = fs::remove_dir_all(cache_root);
        let _ = fs::remove_dir_all(image_root);
    }

    #[test]
    fn runtime_cache_root_defaults_to_shared_cache_path() {
        let _env_lock = super::TEST_ENV_LOCK.lock().expect("lock test env");
        std::env::remove_var("XDG_CACHE_HOME");
        assert_eq!(
            super::runtime_cache_root(),
            PathBuf::from("/tmp/clasp-nix-cache").join("claspc-native")
        );
    }
}
