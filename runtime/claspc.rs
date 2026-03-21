mod tool_support;

use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use tool_support::{
    build_project_bundle, execute_native_export_from_image_path, execute_native_export_from_image_text,
    execute_native_route_from_image_text, project_declares_backend_surface,
};

const STAGE1_NATIVE_IMAGE: &str = include_str!("../src/stage1.native.image.json");
const EMBEDDED_IMAGE_MARKER: &[u8] = b"CLASP_EMBEDDED_IMAGE_V1\0";

#[derive(Clone, Copy, PartialEq, Eq)]
enum Command {
    Check,
    Explain,
    Compile,
    Native,
    NativeImage,
}

struct CliOptions {
    json: bool,
    command: Command,
    input_path: PathBuf,
    output_path: Option<PathBuf>,
}

fn usage(program: &str) -> ! {
    eprintln!(
        "usage: {program} [--json] <check|explain|compile|native|native-image> <entry.clasp> [-o output]"
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

fn print_json_error(message: &str) {
    println!(
        "{{\"status\":\"error\",\"implementation\":\"clasp-native\",\"error\":{}}}",
        json_string(message)
    );
}

fn fail(message: &str, json: bool) -> ExitCode {
    if json {
        print_json_error(message);
    } else {
        eprintln!("{message}");
    }
    ExitCode::from(1)
}

fn parse_command(name: &str) -> Option<Command> {
    match name {
        "check" => Some(Command::Check),
        "explain" => Some(Command::Explain),
        "compile" => Some(Command::Compile),
        "native" => Some(Command::Native),
        "native-image" => Some(Command::NativeImage),
        _ => None,
    }
}

fn parse_cli(args: &[String]) -> Result<CliOptions, String> {
    let mut json = false;
    let mut output_path = None;
    let mut positionals = Vec::new();
    let mut index = 1usize;

    while index < args.len() {
        let arg = &args[index];
        match arg.as_str() {
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
            "unsupported command `{}`; native `claspc` currently supports check, explain, compile, native, and native-image",
            positionals[0]
        ));
    };

    Ok(CliOptions {
        json,
        command,
        input_path: PathBuf::from(&positionals[1]),
        output_path,
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

fn cache_root() -> PathBuf {
    if let Ok(value) = env::var("XDG_CACHE_HOME") {
        PathBuf::from(value).join("claspc-native")
    } else {
        env::temp_dir().join("claspc-native")
    }
}

fn stage1_image_path() -> Result<PathBuf, String> {
    let cache_root = cache_root();
    fs::create_dir_all(&cache_root)
        .map_err(|err| format!("failed to create native compiler cache `{}`: {err}", cache_root.display()))?;
    let stage1_path = cache_root.join("stage1.native.image.json");
    let needs_write = match fs::read_to_string(&stage1_path) {
        Ok(existing) => existing != STAGE1_NATIVE_IMAGE,
        Err(_) => true,
    };
    if needs_write {
        fs::write(&stage1_path, STAGE1_NATIVE_IMAGE).map_err(|err| {
            format!(
                "failed to prepare embedded native compiler image `{}`: {err}",
                stage1_path.display()
            )
        })?;
    }
    Ok(stage1_path)
}

fn bundle_path(entry_path: &Path) -> Result<String, String> {
    let entry_text = entry_path
        .to_str()
        .ok_or_else(|| format!("entry path `{}` is not valid UTF-8", entry_path.display()))?;
    build_project_bundle(entry_text)
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

fn run_embedded_image(image_text: &str, args: &[String]) -> ExitCode {
    if args.get(1).map(|value| value.as_str()) != Some("route") {
        let result = unsafe { execute_native_export_from_image_text(image_text, "main", None) };
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

    eprintln!("usage: {} [route <METHOD> <PATH> <JSON_BODY>]", args[0]);
    ExitCode::from(2)
}

fn run_check(options: &CliOptions, stage1_path: &Path, bundle: &str) -> ExitCode {
    let stage1_path_text = stage1_path.to_string_lossy();
    let result =
        unsafe { execute_native_export_from_image_path(&stage1_path_text, "checkProjectText", Some(bundle)) };
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
        eprintln!(
            "Checked {} with clasp-native",
            options.input_path.display()
        );
    }

    ExitCode::SUCCESS
}

fn run_explain(options: &CliOptions, stage1_path: &Path, bundle: &str) -> ExitCode {
    let stage1_path_text = stage1_path.to_string_lossy();
    let result =
        unsafe { execute_native_export_from_image_path(&stage1_path_text, "explainProjectText", Some(bundle)) };
    let explanation = match result {
        Ok(output_bytes) => String::from_utf8_lossy(&output_bytes).into_owned(),
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
    stage1_path: &Path,
    bundle: &str,
    export_name: &str,
    default_extension: &str,
    target_name: &str,
) -> ExitCode {
    let stage1_path_text = stage1_path.to_string_lossy();
    let result =
        unsafe { execute_native_export_from_image_path(&stage1_path_text, export_name, Some(bundle)) };
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
    let source_text = if args.len() == 6 {
        match load_exec_image_source(&args[4]) {
            Ok(source_text) => Some(source_text),
            Err(message) => {
                eprintln!("{message}");
                return ExitCode::from(1);
            }
        }
    } else {
        None
    };

    let result = unsafe {
        execute_native_export_from_image_path(image_path, export_name, source_text.as_deref())
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

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    match read_embedded_image_from_executable() {
        Ok(Some(image_text)) => return run_embedded_image(&image_text, &args),
        Ok(None) => {}
        Err(message) => return fail(&message, args.iter().any(|arg| arg == "--json")),
    }

    if args.get(1).map(|value| value.as_str()) == Some("exec-image") {
        return run_exec_image(&args);
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

    let stage1_path = match stage1_image_path() {
        Ok(stage1_path) => stage1_path,
        Err(message) => return fail(&message, options.json),
    };

    let bundle = match bundle_path(&options.input_path) {
        Ok(bundle) => bundle,
        Err(message) => return fail(&message, options.json),
    };

    match options.command {
        Command::Check => run_check(&options, &stage1_path, &bundle),
        Command::Explain => run_explain(&options, &stage1_path, &bundle),
        Command::Compile => {
            if project_declares_backend_surface(&bundle) {
                let stage1_path_text = stage1_path.to_string_lossy();
                let result = unsafe {
                    execute_native_export_from_image_path(
                        &stage1_path_text,
                        "nativeImageProjectText",
                        Some(&bundle),
                    )
                };
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
                    &stage1_path,
                    &bundle,
                    "compileProjectText",
                    "js",
                    "frontend-js",
                )
            }
        }
        Command::Native => run_build(
            &options,
            &stage1_path,
            &bundle,
            "nativeProjectText",
            "native.ir",
            "native-ir",
        ),
        Command::NativeImage => run_build(
            &options,
            &stage1_path,
            &bundle,
            "nativeImageProjectText",
            "native.image.json",
            "native-image",
        ),
    }
}
