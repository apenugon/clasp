use std::collections::{HashMap, HashSet};
use std::env;
use std::ffi::CString;
use std::fs;
use std::mem;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;
use std::slice;
use std::thread;
use std::time::UNIX_EPOCH;

use clasp_runtime::{
    clasp_rt_activate_native_module_image, clasp_rt_call_native_dispatch, clasp_rt_call_native_route_json,
    clasp_rt_init,
    clasp_rt_json_from_string, clasp_rt_native_image_module_name, clasp_rt_native_image_validate,
    clasp_rt_native_module_image_free, clasp_rt_native_module_image_load, clasp_rt_read_file, clasp_rt_release,
    clasp_rt_retain, clasp_rt_shutdown, clasp_rt_string_from_utf8, ClaspRtHeader, ClaspRtJson,
    ClaspRtNativeModuleImage, ClaspRtResultString, ClaspRtRuntime, ClaspRtString,
};

pub const PROJECT_BUNDLE_SEPARATOR: &str = "\n-- CLASP_PROJECT_MODULE --\n";
const PROJECT_BUNDLE_CACHE_VERSION: &str = "bundle-cache-v1";

#[cfg(test)]
pub(crate) static TEST_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

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
    import_paths: Vec<PathBuf>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectBundleModule {
    pub module_name: String,
    pub source_fingerprint: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectBundleBuild {
    pub bundle: String,
    pub modules: Vec<ProjectBundleModule>,
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
    let import_paths = parse_imports(&source)
        .into_iter()
        .map(|import_name| {
            let import_path = module_import_path(root, &import_name);
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
        module_name: info.module_name.clone(),
        source_fingerprint: info.source_fingerprint.clone(),
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

fn runtime_cache_root() -> PathBuf {
    if let Ok(value) = env::var("XDG_CACHE_HOME") {
        PathBuf::from(value).join("claspc-native")
    } else {
        env::temp_dir().join("claspc-native")
    }
}

fn project_bundle_cache_dir() -> PathBuf {
    runtime_cache_root().join(PROJECT_BUNDLE_CACHE_VERSION)
}

fn project_bundle_cache_key(entry_path: &Path) -> String {
    stable_fingerprint_text(&entry_path.to_string_lossy())
}

fn project_module_cache_signature(module_path: &Path) -> Result<String, String> {
    let metadata = fs::metadata(module_path)
        .map_err(|err| format!("failed to read project module metadata `{}`: {err}", module_path.display()))?;
    let modified = metadata
        .modified()
        .map_err(|err| format!("failed to read project module modification time `{}`: {err}", module_path.display()))?
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    Ok(format!("{}\t{}", metadata.len(), modified))
}

fn read_cached_project_bundle(entry_path: &Path) -> Result<Option<String>, String> {
    let cache_dir = project_bundle_cache_dir();
    let cache_key = project_bundle_cache_key(entry_path);
    let manifest_path = cache_dir.join(format!("{cache_key}.manifest"));
    let bundle_path = cache_dir.join(format!("{cache_key}.bundle"));
    if !manifest_path.exists() || !bundle_path.exists() {
        return Ok(None);
    }

    let manifest = fs::read_to_string(&manifest_path)
        .map_err(|err| format!("failed to read cached project bundle manifest `{}`: {err}", manifest_path.display()))?;
    for line in manifest.lines().filter(|line| !line.trim().is_empty()) {
        let mut parts = line.splitn(3, '\t');
        let Some(expected_len) = parts.next() else {
            return Ok(None);
        };
        let Some(expected_modified) = parts.next() else {
            return Ok(None);
        };
        let Some(path_text) = parts.next() else {
            return Ok(None);
        };
        let module_path = PathBuf::from(path_text);
        let current_signature = match project_module_cache_signature(&module_path) {
            Ok(signature) => signature,
            Err(_) => return Ok(None),
        };
        let expected_signature = format!("{expected_len}\t{expected_modified}");
        if current_signature != expected_signature {
            return Ok(None);
        }
    }

    fs::read_to_string(&bundle_path)
        .map(Some)
        .map_err(|err| format!("failed to read cached project bundle `{}`: {err}", bundle_path.display()))
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

    let mut module_paths: Vec<PathBuf> = module_infos.keys().cloned().collect();
    module_paths.sort();
    let mut manifest_lines = Vec::new();
    for module_path in module_paths {
        let signature = project_module_cache_signature(&module_path)?;
        manifest_lines.push(format!("{signature}\t{}", module_path.to_string_lossy()));
    }

    fs::write(&manifest_path, manifest_lines.join("\n")).map_err(|err| {
        format!(
            "failed to write project bundle cache manifest `{}`: {err}",
            manifest_path.display()
        )
    })?;
    fs::write(&bundle_path, bundle)
        .map_err(|err| format!("failed to write project bundle cache `{}`: {err}", bundle_path.display()))
}

fn cached_project_bundle_modules(bundle: &str) -> Result<Vec<ProjectBundleModule>, String> {
    bundle
        .split(PROJECT_BUNDLE_SEPARATOR)
        .filter(|source| !source.trim().is_empty())
        .map(|source| {
            let module_name = parse_module_name(source)?;
            Ok(ProjectBundleModule {
                module_name,
                source_fingerprint: stable_fingerprint_text(source),
            })
        })
        .collect()
}

fn build_project_bundle_with_jobs_detail(entry_path: &str, max_jobs: usize) -> Result<ProjectBundleBuild, String> {
    let entry = PathBuf::from(entry_path);
    let entry_canonical = fs::canonicalize(&entry)
        .map_err(|err| format!("failed to resolve project entry module `{}`: {err}", entry.display()))?;
    if let Some(bundle) = read_cached_project_bundle(&entry_canonical)? {
        return Ok(ProjectBundleBuild {
            modules: cached_project_bundle_modules(&bundle)?,
            bundle,
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
    let mut runtime: ClaspRtRuntime = mem::zeroed();
    let mut image_path: *mut ClaspRtString = null_mut();
    let mut image_read_result: *mut ClaspRtResultString = null_mut();
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
        let image_path_c =
            CString::new(image_path_text).map_err(|_| "image path contains interior NUL byte".to_owned())?;
        image_path = clasp_rt_string_from_utf8(image_path_c.as_ptr());
        image_read_result = clasp_rt_read_file(image_path);
        if image_read_result.is_null() || !(*image_read_result).is_ok {
            return Err("failed to read native compiler image".to_owned());
        }

        image = clasp_rt_json_from_string((*image_read_result).value);
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
            &mut runtime,
            module_name,
            target_export,
            args_ptr,
            owned_dispatch_args.len(),
        );
        if dispatch_value.is_null() {
            return Err("runtime failed to execute native compiler export".to_owned());
        }

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
    release(&mut runtime, image_read_result as *mut ClaspRtHeader);
    release(&mut runtime, image_path as *mut ClaspRtHeader);
    clasp_rt_shutdown(&mut runtime);

    result
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
        build_project_bundle_with_jobs, project_bundle_cache_dir, project_bundle_cache_key, PROJECT_BUNDLE_SEPARATOR,
    };
    use std::fs;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique_test_root(name: &str) -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time before unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("clasp-tool-support-{name}-{}-{stamp}", std::process::id()))
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
}
