use std::ffi::CString;
use std::fs;
use std::mem;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;
use std::slice;

use clasp_runtime::{
    clasp_rt_activate_native_module_image, clasp_rt_call_native_dispatch, clasp_rt_call_native_route_json,
    clasp_rt_init,
    clasp_rt_json_from_string, clasp_rt_native_image_module_name, clasp_rt_native_image_validate,
    clasp_rt_native_module_image_free, clasp_rt_native_module_image_load, clasp_rt_read_file, clasp_rt_release,
    clasp_rt_retain, clasp_rt_shutdown, clasp_rt_string_from_utf8, ClaspRtHeader, ClaspRtJson,
    ClaspRtNativeModuleImage, ClaspRtResultString, ClaspRtRuntime, ClaspRtString,
};

pub const PROJECT_BUNDLE_SEPARATOR: &str = "\n-- CLASP_PROJECT_MODULE --\n";

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
    "writeFile",
    "readFile",
    "fileExists",
    "pathJoin",
    "pathDirname",
    "pathBasename",
];

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

fn push_project_module(
    root: &Path,
    path: &Path,
    seen: &mut Vec<PathBuf>,
    bundled_sources: &mut Vec<String>,
) -> Result<(), String> {
    let canonical_path = fs::canonicalize(path)
        .map_err(|err| format!("failed to resolve project module `{}`: {err}", path.display()))?;
    if seen.iter().any(|existing| existing == &canonical_path) {
        return Ok(());
    }

    let source = fs::read_to_string(&canonical_path)
        .map_err(|err| format!("failed to read project module `{}`: {err}", canonical_path.display()))?;
    let bundled_source = augment_source_with_hosted_metadata(&canonical_path, &source)?;
    seen.push(canonical_path);
    bundled_sources.push(bundled_source);

    for import_name in parse_imports(&source) {
        let import_path = module_import_path(root, &import_name);
        push_project_module(root, &import_path, seen, bundled_sources)?;
    }

    Ok(())
}

pub fn build_project_bundle(entry_path: &str) -> Result<String, String> {
    let entry = PathBuf::from(entry_path);
    let root = entry
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let mut seen = Vec::new();
    let mut bundled_sources = Vec::new();
    push_project_module(&root, &entry, &mut seen, &mut bundled_sources)?;
    Ok(bundled_sources.join(PROJECT_BUNDLE_SEPARATOR))
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
    let mut runtime: ClaspRtRuntime = mem::zeroed();
    let mut image_path: *mut ClaspRtString = null_mut();
    let mut image_read_result: *mut ClaspRtResultString = null_mut();
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
            return Err("runtime failed to execute native compiler export".to_owned());
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
