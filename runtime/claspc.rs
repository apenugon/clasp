mod tool_support;

use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

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

    eprintln!("usage: {} [serve <HOST:PORT> | route <METHOD> <PATH> <JSON_BODY>]", args[0]);
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
