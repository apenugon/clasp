use std::env;
use std::ffi::CString;
use std::fs;
use std::mem;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::ptr::null_mut;
use std::slice;

use clasp_runtime::{
    clasp_rt_activate_native_module_image, clasp_rt_call_native_dispatch, clasp_rt_init,
    clasp_rt_json_from_string, clasp_rt_native_image_module_name, clasp_rt_native_image_validate,
    clasp_rt_native_module_image_free, clasp_rt_native_module_image_load, clasp_rt_read_file, clasp_rt_release,
    clasp_rt_retain, clasp_rt_shutdown, clasp_rt_string_from_utf8, ClaspRtHeader, ClaspRtJson,
    ClaspRtNativeModuleImage, ClaspRtResultString, ClaspRtRuntime, ClaspRtString,
};

fn usage(program: &str) -> ! {
    eprintln!("usage: {program} <module.native.image.json> <export> [source.clasp] <output>");
    std::process::exit(2);
}

const PROJECT_BUNDLE_SEPARATOR: &str = "\n-- CLASP_PROJECT_MODULE --\n";

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

fn fail(message: &str) -> ExitCode {
    eprintln!("{message}");
    ExitCode::from(1)
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

fn build_project_bundle(entry_path: &str) -> Result<String, String> {
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

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() != 4 && args.len() != 5 {
        usage(&args[0]);
    }

    let mut runtime: ClaspRtRuntime = unsafe { mem::zeroed() };
    let mut image_path: *mut ClaspRtString = null_mut();
    let mut image_read_result: *mut ClaspRtResultString = null_mut();
    let mut image: *mut ClaspRtJson = null_mut();
    let mut module_name_result: *mut ClaspRtResultString = null_mut();
    let mut loaded_image: *mut ClaspRtNativeModuleImage = null_mut();
    let mut module_name: *mut ClaspRtString = null_mut();
    let mut target_export: *mut ClaspRtString = null_mut();
    let mut source_path: *mut ClaspRtString = null_mut();
    let mut source_read_result: *mut ClaspRtResultString = null_mut();
    let mut dispatch_args: [*mut ClaspRtHeader; 1] = [null_mut()];
    let mut owned_dispatch_arg: *mut ClaspRtHeader = null_mut();
    let mut dispatch_arg_count = 0usize;
    let mut dispatch_value: *mut ClaspRtHeader = null_mut();

    let exit_code = (|| unsafe {
        clasp_rt_init(&mut runtime);

        let image_path_c = CString::new(args[1].as_str()).expect("image path contains interior NUL byte");
        image_path = clasp_rt_string_from_utf8(image_path_c.as_ptr());
        image_read_result = clasp_rt_read_file(image_path);
        if image_read_result.is_null() || !(*image_read_result).is_ok {
            return fail("failed to read native compiler image");
        }

        image = clasp_rt_json_from_string((*image_read_result).value);
        if !clasp_rt_native_image_validate(image) {
            return fail("runtime rejected native compiler image");
        }

        module_name_result = clasp_rt_native_image_module_name(image);
        if module_name_result.is_null() || !(*module_name_result).is_ok {
            return fail("runtime failed to resolve native compiler image module name");
        }
        module_name = (*module_name_result).value;
        clasp_rt_retain(module_name as *mut ClaspRtHeader);

        loaded_image = clasp_rt_native_module_image_load(image);
        if loaded_image.is_null() {
            return fail("runtime failed to load native compiler image");
        }

        if !clasp_rt_activate_native_module_image(&mut runtime, loaded_image) {
            return fail("runtime failed to activate native compiler image");
        }
        loaded_image = null_mut();

        let export_c = CString::new(args[2].as_str()).expect("export name contains interior NUL byte");
        target_export = clasp_rt_string_from_utf8(export_c.as_ptr());

        if args.len() == 5 {
            let source_text = if let Some(project_entry_path) = args[3].strip_prefix("--project-entry=") {
                match build_project_bundle(project_entry_path) {
                    Ok(bundle) => bundle,
                    Err(message) => return fail(&message),
                }
            } else {
                let source_path_c = CString::new(args[3].as_str()).expect("source path contains interior NUL byte");
                source_path = clasp_rt_string_from_utf8(source_path_c.as_ptr());
                source_read_result = clasp_rt_read_file(source_path);
                if source_read_result.is_null() || !(*source_read_result).is_ok {
                    return fail("failed to read hosted compiler source input");
                }
                String::from_utf8_lossy(string_bytes((*source_read_result).value)).into_owned()
            };
            let source_text_c = CString::new(source_text).expect("source input contains interior NUL byte");
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
            return fail("runtime failed to execute native compiler export");
        }

        let output_path = args.last().expect("missing output path");
        let output_path_ref = Path::new(output_path);
        if let Some(parent) = output_path_ref.parent() {
            if let Err(err) = fs::create_dir_all(parent) {
                return fail(&format!(
                    "failed to prepare hosted compiler output directory `{}`: {err}",
                    parent.display()
                ));
            }
        }
        if let Err(err) = fs::write(output_path_ref, string_bytes(dispatch_value as *mut ClaspRtString)) {
            return fail(&format!(
                "failed to write hosted compiler result `{}`: {err}",
                output_path_ref.display()
            ));
        }

        ExitCode::SUCCESS
    })();

    unsafe {
        release(&mut runtime, dispatch_value);
        release(&mut runtime, owned_dispatch_arg);
        release(&mut runtime, source_read_result as *mut ClaspRtHeader);
        release(&mut runtime, source_path as *mut ClaspRtHeader);
        release(&mut runtime, target_export as *mut ClaspRtHeader);
        clasp_rt_native_module_image_free(&mut runtime, loaded_image);
        release(&mut runtime, module_name as *mut ClaspRtHeader);
        release(&mut runtime, module_name_result as *mut ClaspRtHeader);
        release(&mut runtime, image as *mut ClaspRtHeader);
        release(&mut runtime, image_read_result as *mut ClaspRtHeader);
        release(&mut runtime, image_path as *mut ClaspRtHeader);
        clasp_rt_shutdown(&mut runtime);
    }

    exit_code
}
