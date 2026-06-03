mod swarm;

use std::alloc::{alloc_zeroed, dealloc, handle_alloc_error, Layout};
use std::collections::HashMap;
use std::env;
use std::ffi::{c_char, CStr, CString};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::mem::{align_of, size_of, MaybeUninit};
#[cfg(unix)]
use std::os::raw::{c_int, c_ulong};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::ptr::{self, null_mut, NonNull};
use std::process::{Child, Command as ProcessCommand, Stdio};
use std::slice;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const CLASP_RT_LAYOUT_STRING: u32 = 1;
const CLASP_RT_LAYOUT_BYTES: u32 = 2;
const CLASP_RT_LAYOUT_STRING_LIST: u32 = 3;
const CLASP_RT_LAYOUT_RESULT_STRING: u32 = 4;
const CLASP_RT_LAYOUT_GENERIC_OBJECT: u32 = 5;
const CLASP_RT_LAYOUT_MUTABLE_CELL: u32 = 6;
const CLASP_RT_LAYOUT_VARIANT_VALUE: u32 = 7;
const CLASP_RT_LAYOUT_RECORD_VALUE: u32 = 8;
const CLASP_RT_LAYOUT_INT: u32 = 9;
const CLASP_RT_LAYOUT_BOOL: u32 = 10;
const CLASP_RT_LAYOUT_LIST_VALUE: u32 = 11;
const CLASP_RT_LAYOUT_EARLY_RETURN: u32 = 12;
const CLASP_RT_INTERPRETER_MAX_DEPTH: usize = 4096;
const DOCUMENT_UPLOAD_MAX_BYTES: usize = 64 * 1024;
const DOCUMENT_REFERENCE_MAX_COUNT: usize = 32;
const DOCUMENT_EXCERPT_MAX_CHARS: usize = 160;
const DEFAULT_WATCHED_PROCESS_OUTPUT_LIMIT_BYTES: u64 = 4 * 1024 * 1024;
#[cfg(unix)]
const SIGTERM: c_int = 15;
#[cfg(unix)]
const SIGKILL: c_int = 9;
#[cfg(target_os = "linux")]
const RLIMIT_CORE: c_int = 4;

#[cfg(target_os = "linux")]
#[repr(C)]
struct RLimit {
    rlim_cur: c_ulong,
    rlim_max: c_ulong,
}

#[cfg(unix)]
extern "C" {
    fn setsid() -> c_int;
    fn kill(pid: c_int, sig: c_int) -> c_int;
}

#[cfg(target_os = "linux")]
extern "C" {
    fn setrlimit(resource: c_int, rlim: *const RLimit) -> c_int;
}

#[cfg(unix)]
#[repr(C)]
struct Statvfs {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: c_ulong,
    f_bfree: c_ulong,
    f_bavail: c_ulong,
    f_files: c_ulong,
    f_ffree: c_ulong,
    f_favail: c_ulong,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    __f_spare: [c_int; 6],
}

#[cfg(unix)]
extern "C" {
    fn statvfs(path: *const c_char, buf: *mut Statvfs) -> c_int;
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct DocumentReferenceSpec {
    document_id: String,
    label: String,
    raw: String,
}

#[derive(Clone)]
struct NativeLeadRecord {
    lead_id: String,
    company: String,
    contact: String,
    summary: String,
    priority: String,
    segment: String,
    follow_up_required: bool,
    review_status: String,
    review_note: String,
}

fn seeded_native_leads() -> Vec<NativeLeadRecord> {
    vec![
        NativeLeadRecord {
            lead_id: "lead-2".to_owned(),
            company: "Northwind Studio".to_owned(),
            contact: "Morgan Lee".to_owned(),
            summary: "Northwind Studio is ready for a design-system migration this quarter.".to_owned(),
            priority: "Medium".to_owned(),
            segment: "Growth".to_owned(),
            follow_up_required: true,
            review_status: "Reviewed".to_owned(),
            review_note: "Confirmed budget window and asked for a migration timeline.".to_owned(),
        },
        NativeLeadRecord {
            lead_id: "lead-1".to_owned(),
            company: "Acme Labs".to_owned(),
            contact: "Jordan Kim".to_owned(),
            summary: "Acme Labs is exploring an internal AI pilot for support operations.".to_owned(),
            priority: "High".to_owned(),
            segment: "Enterprise".to_owned(),
            follow_up_required: true,
            review_status: "New".to_owned(),
            review_note: String::new(),
        },
    ]
}

fn native_lead_state() -> &'static Mutex<Vec<NativeLeadRecord>> {
    static STATE: OnceLock<Mutex<Vec<NativeLeadRecord>>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(seeded_native_leads()))
}

fn native_route_error_state() -> &'static Mutex<Option<String>> {
    static STATE: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(None))
}

fn clear_native_route_error() {
    if let Ok(mut state) = native_route_error_state().lock() {
        *state = None;
    }
}

fn set_native_route_error(message: String) {
    if let Ok(mut state) = native_route_error_state().lock() {
        *state = Some(message);
    }
}

fn take_native_route_error() -> Option<String> {
    native_route_error_state().lock().ok().and_then(|mut state| state.take())
}

fn document_boundary_fingerprint(value: &str) -> String {
    const FNV_OFFSET: u64 = 14695981039346656037;
    const FNV_PRIME: u64 = 1099511628211;

    let mut fingerprint = FNV_OFFSET;
    for &byte in value.as_bytes() {
        fingerprint ^= u64::from(byte);
        fingerprint = fingerprint.wrapping_mul(FNV_PRIME);
    }

    format!("{fingerprint:016x}")
}

fn document_excerpt(value: &str) -> String {
    let excerpt: String = value.chars().take(DOCUMENT_EXCERPT_MAX_CHARS).collect();
    if excerpt.chars().count() == value.chars().count() {
        excerpt
    } else {
        format!("{excerpt}...")
    }
}

fn valid_document_reference_id(value: &str) -> bool {
    !value.is_empty()
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | '/' | ':'))
}

fn parse_document_reference_specs(text: &str) -> Result<Vec<DocumentReferenceSpec>, String> {
    let mut references = Vec::new();
    let mut search_index = 0usize;

    while let Some(relative_index) = text[search_index..].find("@document[") {
        let start = search_index + relative_index;
        let payload_start = start + "@document[".len();
        let Some(relative_end) = text[payload_start..].find(']') else {
            return Err("unterminated @document reference".to_owned());
        };
        let end = payload_start + relative_end;
        let raw = &text[start..=end];
        let payload = text[payload_start..end].trim();
        if payload.is_empty() {
            return Err(format!("invalid @document reference `{raw}`"));
        }

        let (document_id, label) = match payload.split_once('|') {
            Some((document_id, label)) => (document_id.trim(), label.trim()),
            None => (payload, payload),
        };

        if !valid_document_reference_id(document_id) {
            return Err(format!("invalid @document id `{document_id}`"));
        }

        references.push(DocumentReferenceSpec {
            document_id: document_id.to_owned(),
            label: if label.is_empty() {
                document_id.to_owned()
            } else {
                label.to_owned()
            },
            raw: raw.to_owned(),
        });

        if references.len() > DOCUMENT_REFERENCE_MAX_COUNT {
            return Err(format!(
                "too many @document references; expected at most {DOCUMENT_REFERENCE_MAX_COUNT}"
            ));
        }

        search_index = end + 1;
    }

    Ok(references)
}

fn trace_interpreter_enabled() -> bool {
    match env::var("CLASP_RT_TRACE_INTERPRETER") {
        Ok(value) => value == "1" || value.eq_ignore_ascii_case("true"),
        Err(_) => false,
    }
}

type DestroyFn = unsafe extern "C" fn(*mut ClaspRtRuntime, *mut ClaspRtHeader);

#[repr(C)]
pub struct ClaspRtHeader {
    pub layout_id: u32,
    pub retain_count: u32,
    pub destroy: Option<DestroyFn>,
}

#[repr(C)]
pub struct ClaspRtObjectLayout {
    pub layout_id: u32,
    pub word_count: usize,
    pub root_count: usize,
    pub root_offsets: *const u32,
}

pub type ClaspRtNativeEntrypointFn =
    Option<unsafe extern "C" fn(*mut ClaspRtRuntime, *mut *mut ClaspRtHeader, usize) -> *mut ClaspRtHeader>;
pub type ClaspRtNativeSymbolResolverFn =
    Option<unsafe extern "C" fn(*mut ClaspRtString) -> ClaspRtNativeEntrypointFn>;
pub type ClaspRtNativeSnapshotFn = Option<
    unsafe extern "C" fn(
        *mut ClaspRtRuntime,
        *mut ClaspRtString,
        usize,
        *mut ClaspRtString,
        *mut ClaspRtString,
    ) -> *mut ClaspRtJson,
>;
pub type ClaspRtNativeSnapshotResolverFn =
    Option<unsafe extern "C" fn(*mut ClaspRtString) -> ClaspRtNativeSnapshotFn>;
pub type ClaspRtNativeHandoffFn = Option<
    unsafe extern "C" fn(
        *mut ClaspRtRuntime,
        *mut ClaspRtString,
        usize,
        usize,
        *mut ClaspRtString,
        *mut ClaspRtString,
        *mut ClaspRtString,
        *mut ClaspRtJson,
    ) -> bool,
>;
pub type ClaspRtNativeHandoffResolverFn =
    Option<unsafe extern "C" fn(*mut ClaspRtString) -> ClaspRtNativeHandoffFn>;

#[repr(C)]
pub struct ClaspRtRuntime {
    pub static_root_count: usize,
    pub static_roots: *mut *mut *mut ClaspRtHeader,
    pub active_native_module_count: usize,
    pub active_native_modules: *mut *mut ClaspRtNativeModuleImage,
}

#[repr(C)]
pub struct ClaspRtString {
    pub header: ClaspRtHeader,
    pub byte_length: usize,
    pub bytes: *mut c_char,
}

pub type ClaspRtJson = ClaspRtString;

#[repr(C)]
pub struct ClaspRtBytes {
    pub header: ClaspRtHeader,
    pub byte_length: usize,
    pub bytes: *mut u8,
}

#[repr(C)]
pub struct ClaspRtStringList {
    pub header: ClaspRtHeader,
    pub length: usize,
    pub items: *mut *mut ClaspRtString,
}

#[repr(C)]
pub struct ClaspRtResultString {
    pub header: ClaspRtHeader,
    pub is_ok: bool,
    pub value: *mut ClaspRtString,
}

#[repr(C)]
struct ClaspRtInt {
    header: ClaspRtHeader,
    value: i64,
}

#[repr(C)]
struct ClaspRtBool {
    header: ClaspRtHeader,
    value: bool,
}

#[repr(C)]
pub struct ClaspRtObject {
    pub header: ClaspRtHeader,
    pub layout: *const ClaspRtObjectLayout,
    pub words: [usize; 0],
}

#[repr(C)]
struct ClaspRtMutableCell {
    header: ClaspRtHeader,
    value: *mut ClaspRtHeader,
}

#[repr(C)]
struct ClaspRtVariantValue {
    header: ClaspRtHeader,
    tag: *mut ClaspRtString,
    item_count: usize,
    items: *mut *mut ClaspRtHeader,
}

#[repr(C)]
struct ClaspRtRecordValue {
    header: ClaspRtHeader,
    record_name: *mut ClaspRtString,
    field_count: usize,
    field_names: *mut *mut ClaspRtString,
    field_values: *mut *mut ClaspRtHeader,
}

#[repr(C)]
struct ClaspRtListValue {
    header: ClaspRtHeader,
    item_count: usize,
    items: *mut *mut ClaspRtHeader,
}

#[repr(C)]
struct ClaspRtEarlyReturn {
    header: ClaspRtHeader,
    value: *mut ClaspRtHeader,
}

pub struct ClaspRtNativeModuleImage {
    module_name: *mut ClaspRtString,
    runtime_profile: *mut ClaspRtString,
    interface_fingerprint: *mut ClaspRtString,
    accepted_previous_fingerprints: Vec<*mut ClaspRtString>,
    migration_strategy: *mut ClaspRtString,
    migration_state_type: *mut ClaspRtString,
    snapshot_symbol: *mut ClaspRtString,
    snapshot: ClaspRtNativeSnapshotFn,
    handoff_symbol: *mut ClaspRtString,
    handoff: ClaspRtNativeHandoffFn,
    state_snapshot_type: *mut ClaspRtString,
    state_snapshot: *mut ClaspRtJson,
    generation: usize,
    runtime_bindings: Vec<ClaspRtNativeRuntimeBinding>,
    runtime_binding_indexes: HashMap<String, usize>,
    route_boundaries: Vec<ClaspRtNativeRouteBoundary>,
    record_schemas: HashMap<String, ClaspRtRecordSchema>,
    variant_schemas: HashMap<String, ClaspRtVariantSchema>,
    exports: Vec<*mut ClaspRtString>,
    entrypoint_symbols: Vec<*mut ClaspRtString>,
    entrypoints: Vec<ClaspRtNativeEntrypointFn>,
    interpreted_decls: Vec<ClaspRtInterpretedDecl>,
    interpreted_decl_indexes: HashMap<String, usize>,
    decl_count: usize,
}

#[derive(Clone)]
enum ClaspRtInterpretedExpr {
    IntLiteral(i64),
    BoolLiteral(bool),
    StringLiteral(Vec<u8>),
    Local(String),
    List(Vec<ClaspRtInterpretedExpr>),
    If(
        Box<ClaspRtInterpretedExpr>,
        Box<ClaspRtInterpretedExpr>,
        Box<ClaspRtInterpretedExpr>,
    ),
    Compare(
        ClaspRtInterpretedCompareOp,
        Box<ClaspRtInterpretedExpr>,
        Box<ClaspRtInterpretedExpr>,
    ),
    CallLocal(String, Vec<ClaspRtInterpretedExpr>),
    Return(Box<ClaspRtInterpretedExpr>),
    Match(Box<ClaspRtInterpretedExpr>, Vec<ClaspRtInterpretedMatchBranch>),
    Let(bool, String, Box<ClaspRtInterpretedExpr>, Box<ClaspRtInterpretedExpr>),
    Assign(String, Box<ClaspRtInterpretedExpr>, Box<ClaspRtInterpretedExpr>),
    ForEach(String, Box<ClaspRtInterpretedExpr>, Box<ClaspRtInterpretedExpr>, Box<ClaspRtInterpretedExpr>),
    Construct(String, Vec<ClaspRtInterpretedExpr>),
    Record(String, Vec<ClaspRtInterpretedRecordField>),
    FieldAccess(String, Box<ClaspRtInterpretedExpr>, String),
    Intrinsic(ClaspRtInterpretedIntrinsic),
}

#[derive(Clone, Copy)]
enum ClaspRtInterpretedCompareOp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

#[derive(Clone)]
enum ClaspRtInterpretedIntrinsic {
    ListAppend(Box<ClaspRtInterpretedExpr>, Box<ClaspRtInterpretedExpr>),
    ListPrepend(Box<ClaspRtInterpretedExpr>, Box<ClaspRtInterpretedExpr>),
    ListReverse(Box<ClaspRtInterpretedExpr>),
    ListConcat(Box<ClaspRtInterpretedExpr>),
    Length(Box<ClaspRtInterpretedExpr>),
    ListMap(String, Box<ClaspRtInterpretedExpr>),
    ListFilter(String, Box<ClaspRtInterpretedExpr>),
    ListFind(String, Box<ClaspRtInterpretedExpr>),
    ListAny(String, Box<ClaspRtInterpretedExpr>),
    ListAll(String, Box<ClaspRtInterpretedExpr>),
    ListFold(String, Box<ClaspRtInterpretedExpr>, Box<ClaspRtInterpretedExpr>),
    ViewAppend(Box<ClaspRtInterpretedExpr>, Box<ClaspRtInterpretedExpr>),
    Encode(Box<ClaspRtInterpretedExpr>),
    Decode(ClaspRtSchemaType, Box<ClaspRtInterpretedExpr>),
    TryDecode(ClaspRtSchemaType, Box<ClaspRtInterpretedExpr>),
}

#[derive(Clone)]
enum ClaspRtInterpretedDeclKind {
    Global,
    Function,
}

#[derive(Clone)]
struct ClaspRtInterpretedDecl {
    kind: ClaspRtInterpretedDeclKind,
    name: String,
    params: Vec<String>,
    body: ClaspRtInterpretedExpr,
}

#[derive(Clone)]
struct ClaspRtInterpretedMatchBranch {
    tag: String,
    binders: Vec<String>,
    body: ClaspRtInterpretedExpr,
}

#[derive(Clone)]
struct ClaspRtInterpretedRecordField {
    name: String,
    value: ClaspRtInterpretedExpr,
}

#[derive(Clone)]
struct ClaspRtNativeRuntimeBinding {
    name: String,
    runtime_name: String,
    binding_type: String,
}

#[derive(Clone)]
enum ClaspRtSchemaType {
    Int,
    Bool,
    Str,
    List(Box<ClaspRtSchemaType>),
    Named(String),
}

#[derive(Clone)]
struct ClaspRtRecordFieldSchema {
    name: String,
    typ: ClaspRtSchemaType,
}

#[derive(Clone)]
struct ClaspRtRecordSchema {
    fields: Vec<ClaspRtRecordFieldSchema>,
}

#[derive(Clone)]
struct ClaspRtVariantConstructorSchema {
    name: String,
    payloads: Vec<ClaspRtSchemaType>,
}

#[derive(Clone)]
struct ClaspRtVariantSchema {
    constructors: HashMap<String, ClaspRtVariantConstructorSchema>,
    constructor_names: Vec<String>,
}

#[derive(Clone)]
struct ClaspRtDecodeError {
    message: String,
}

impl ClaspRtDecodeError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

#[derive(Clone)]
struct ClaspRtNativeRouteBoundary {
    name: String,
    method: String,
    path: String,
    request_type: String,
    response_type: String,
    response_kind: String,
    handler: String,
}

impl ClaspRtNativeModuleImage {
    fn export_index(&self, export_name: *mut ClaspRtString) -> Option<usize> {
        self.exports.iter().position(|candidate| unsafe { string_ptr_equals(*candidate, export_name) })
    }

    fn accepts_previous_fingerprint(&self, fingerprint: *mut ClaspRtString) -> bool {
        if fingerprint.is_null() {
            return false;
        }
        self.accepted_previous_fingerprints
            .iter()
            .any(|candidate| unsafe { string_ptr_equals(*candidate, fingerprint) })
    }

    fn uses_state_handoff(&self) -> bool {
        if self.migration_strategy.is_null() || self.migration_state_type.is_null() || self.handoff_symbol.is_null() {
            return false;
        }
        unsafe { string_bytes(self.migration_strategy) == b"state-handoff" }
    }

    fn capture_state_snapshot(
        &mut self,
        runtime: *mut ClaspRtRuntime,
        state_type: *mut ClaspRtString,
    ) -> bool {
        if state_type.is_null() {
            return false;
        }
        if !self.state_snapshot_type.is_null()
            && !self.state_snapshot.is_null()
            && self.state_snapshot_is_valid()
            && unsafe { string_ptr_equals(self.state_snapshot_type, state_type) }
        {
            return true;
        }

        let Some(snapshot) = self.snapshot else {
            return false;
        };
        let snapshot_value = unsafe {
            snapshot(
                runtime,
                self.module_name,
                self.generation,
                self.interface_fingerprint,
                state_type,
            )
        };
        if snapshot_value.is_null() || !unsafe { native_module_state_snapshot_is_valid(snapshot_value) } {
            return false;
        }

        unsafe {
            release_header(runtime, self.state_snapshot_type as *mut ClaspRtHeader);
            release_header(runtime, self.state_snapshot as *mut ClaspRtHeader);
            retain_header(state_type as *mut ClaspRtHeader);
            self.state_snapshot_type = state_type;
            self.state_snapshot = snapshot_value;
        }
        true
    }

    fn state_snapshot_is_valid(&self) -> bool {
        if self.state_snapshot.is_null() {
            return false;
        }
        unsafe { json_root_object(string_bytes(self.state_snapshot as *mut ClaspRtString)).is_some() }
    }

    fn interpreted_decl(&self, target_name: &str) -> Option<&ClaspRtInterpretedDecl> {
        self.interpreted_decl_indexes
            .get(target_name)
            .and_then(|index| self.interpreted_decls.get(*index))
    }

    fn runtime_binding(&self, target_name: &str) -> Option<&ClaspRtNativeRuntimeBinding> {
        self.runtime_binding_indexes
            .get(target_name)
            .and_then(|index| self.runtime_bindings.get(*index))
    }
}

impl ClaspRtRuntime {
    fn module_slice(&self) -> &[*mut ClaspRtNativeModuleImage] {
        if self.active_native_module_count == 0 || self.active_native_modules.is_null() {
            &[]
        } else {
            unsafe { slice::from_raw_parts(self.active_native_modules, self.active_native_module_count) }
        }
    }

    fn take_modules(&mut self) -> Vec<*mut ClaspRtNativeModuleImage> {
        if self.active_native_module_count == 0 || self.active_native_modules.is_null() {
            Vec::new()
        } else {
            let length = self.active_native_module_count;
            let pointer = self.active_native_modules;
            self.active_native_modules = null_mut();
            self.active_native_module_count = 0;
            unsafe { Vec::from_raw_parts(pointer, length, length) }
        }
    }

    fn store_modules(&mut self, mut modules: Vec<*mut ClaspRtNativeModuleImage>) {
        if modules.is_empty() {
            self.active_native_modules = null_mut();
            self.active_native_module_count = 0;
        } else {
            self.active_native_modules = modules.as_mut_ptr();
            self.active_native_module_count = modules.len();
            std::mem::forget(modules);
        }
    }

    fn take_static_roots(&mut self) -> Vec<*mut *mut ClaspRtHeader> {
        if self.static_root_count == 0 || self.static_roots.is_null() {
            Vec::new()
        } else {
            let length = self.static_root_count;
            let pointer = self.static_roots;
            self.static_roots = null_mut();
            self.static_root_count = 0;
            unsafe { Vec::from_raw_parts(pointer, length, length) }
        }
    }

    fn store_static_roots(&mut self, mut roots: Vec<*mut *mut ClaspRtHeader>) {
        if roots.is_empty() {
            self.static_roots = null_mut();
            self.static_root_count = 0;
        } else {
            self.static_roots = roots.as_mut_ptr();
            self.static_root_count = roots.len();
            std::mem::forget(roots);
        }
    }

    fn find_active_module_index(&self, module_name: *mut ClaspRtString) -> Option<usize> {
        self.module_slice().iter().position(|image_ref| {
            let image = *image_ref;
            !image.is_null() && unsafe { string_ptr_equals((*image).module_name, module_name) }
        })
    }

    fn find_active_module_generation_index(
        &self,
        module_name: *mut ClaspRtString,
        generation: usize,
    ) -> Option<usize> {
        self.module_slice().iter().position(|image_ref| {
            let image = *image_ref;
            !image.is_null()
                && unsafe { string_ptr_equals((*image).module_name, module_name) }
                && unsafe { (*image).generation == generation }
        })
    }

    fn find_latest_active_module_index(&self, module_name: *mut ClaspRtString) -> Option<usize> {
        self.module_slice()
            .iter()
            .enumerate()
            .filter(|(_, image_ref)| {
                let image = **image_ref;
                !image.is_null() && unsafe { string_ptr_equals((*image).module_name, module_name) }
            })
            .max_by_key(|(_, image_ref)| {
                let image = **image_ref;
                if image.is_null() {
                    0
                } else {
                    unsafe { (*image).generation }
                }
            })
            .map(|(index, _)| index)
    }

    fn active_generation_count(&self, module_name: *mut ClaspRtString) -> usize {
        self.module_slice()
            .iter()
            .filter(|image_ref| {
                let image = **image_ref;
                !image.is_null() && unsafe { string_ptr_equals((*image).module_name, module_name) }
            })
            .count()
    }

    fn next_module_generation(&self, module_name: *mut ClaspRtString) -> usize {
        self.module_slice()
            .iter()
            .filter(|image_ref| {
                let image = **image_ref;
                !image.is_null() && unsafe { string_ptr_equals((*image).module_name, module_name) }
            })
            .map(|image_ref| {
                let image = *image_ref;
                unsafe { (*image).generation }
            })
            .max()
            .unwrap_or(0)
            + 1
    }

    fn init_state(&mut self) {
        self.static_root_count = 0;
        self.static_roots = null_mut();
        self.active_native_module_count = 0;
        self.active_native_modules = null_mut();
    }

    fn shutdown_state(&mut self) {
        let modules = self.take_modules();
        for module in modules {
            if !module.is_null() {
                unsafe { drop(Box::from_raw(module)); }
            }
        }
        drop(self.take_static_roots());
    }

    fn register_static_root(&mut self, slot: *mut *mut ClaspRtHeader) {
        let mut roots = self.take_static_roots();
        roots.push(slot);
        self.store_static_roots(roots);
    }

    fn activate_native_module_image(&mut self, image: NonNull<ClaspRtNativeModuleImage>) -> bool {
        let image_ptr = image.as_ptr();
        if unsafe { (*image_ptr).module_name.is_null() } {
            return false;
        }

        let module_name = unsafe { (*image_ptr).module_name };
        if let Some(existing_index) = self.find_latest_active_module_index(module_name) {
            let existing = self.module_slice()[existing_index];
            if existing.is_null() || unsafe { (*existing).interface_fingerprint.is_null() } {
                return false;
            }
            let image_ref = unsafe { image.as_ref() };
            if !image_ref.accepts_previous_fingerprint(unsafe { (*existing).interface_fingerprint }) {
                return false;
            }
            if !unsafe { string_ptr_equals((*image_ptr).interface_fingerprint, (*existing).interface_fingerprint) }
                && !image_ref.uses_state_handoff()
            {
                return false;
            }
        }

        unsafe { (*image_ptr).generation = self.next_module_generation(module_name) };
        let mut modules = self.take_modules();
        modules.push(image_ptr);
        self.store_modules(modules);
        true
    }

    fn active_module_generation(&self, module_name: *mut ClaspRtString) -> usize {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return 0;
        };
        let image = self.module_slice()[module_index];
        if image.is_null() {
            0
        } else {
            unsafe { (*image).generation }
        }
    }

    fn has_active_native_module(&self, module_name: *mut ClaspRtString) -> bool {
        self.find_active_module_index(module_name).is_some()
    }

    fn has_active_native_module_generation(&self, module_name: *mut ClaspRtString, generation: usize) -> bool {
        self.find_active_module_generation_index(module_name, generation).is_some()
    }

    fn retire_native_module_generation(&mut self, module_name: *mut ClaspRtString, generation: usize) -> bool {
        let mut modules = self.take_modules();
        let Some(index) = modules.iter().position(|image| {
            !image.is_null()
                && unsafe { string_ptr_equals((**image).module_name, module_name) }
                && unsafe { (**image).generation == generation }
        }) else {
            self.store_modules(modules);
            return false;
        };

        let removed = modules[index];
        if removed.is_null() {
            self.store_modules(modules);
            return false;
        }

        let successor = modules
            .iter()
            .copied()
            .filter(|image| {
                !image.is_null()
                    && unsafe { string_ptr_equals((**image).module_name, module_name) }
                    && unsafe { (**image).generation > generation }
            })
            .max_by_key(|image| unsafe { (**image).generation });

        if let Some(next_image) = successor {
            if unsafe { (*removed).interface_fingerprint.is_null() || (*next_image).interface_fingerprint.is_null() } {
                self.store_modules(modules);
                return false;
            }

            let removed_ref = unsafe { &mut *removed };
            let next_ref = unsafe { &*next_image };
            if !unsafe { string_ptr_equals(removed_ref.interface_fingerprint, next_ref.interface_fingerprint) } {
                if !next_ref.accepts_previous_fingerprint(removed_ref.interface_fingerprint)
                    || !next_ref.uses_state_handoff()
                {
                    self.store_modules(modules);
                    return false;
                }
                if !removed_ref.capture_state_snapshot(self as *mut ClaspRtRuntime, next_ref.migration_state_type)
                    || removed_ref.state_snapshot_type.is_null()
                    || removed_ref.state_snapshot.is_null()
                    || !removed_ref.state_snapshot_is_valid()
                    || !unsafe { string_ptr_equals(removed_ref.state_snapshot_type, next_ref.migration_state_type) }
                {
                    self.store_modules(modules);
                    return false;
                }
                let Some(handoff) = next_ref.handoff else {
                    self.store_modules(modules);
                    return false;
                };
                if !unsafe {
                    handoff(
                        self as *mut ClaspRtRuntime,
                        removed_ref.module_name,
                        generation,
                        next_ref.generation,
                        removed_ref.interface_fingerprint,
                        next_ref.interface_fingerprint,
                        next_ref.migration_state_type,
                        removed_ref.state_snapshot,
                    )
                } {
                    self.store_modules(modules);
                    return false;
                }
            }
        }

        let removed = modules.remove(index);
        if !removed.is_null() {
            unsafe { drop(Box::from_raw(removed)); }
        }
        self.store_modules(modules);
        true
    }

    fn bind_native_entrypoint(
        &mut self,
        module_name: *mut ClaspRtString,
        export_name: *mut ClaspRtString,
        entrypoint: ClaspRtNativeEntrypointFn,
    ) -> bool {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return false;
        };
        let image = self.module_slice()[module_index];
        let Some(export_index) = unsafe { image.as_ref() }.and_then(|image_ref| image_ref.export_index(export_name)) else {
            return false;
        };
        unsafe { (&mut (*image).entrypoints)[export_index] = entrypoint };
        true
    }

    fn bind_native_snapshot(
        &mut self,
        module_name: *mut ClaspRtString,
        snapshot: ClaspRtNativeSnapshotFn,
    ) -> bool {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return false;
        };
        let image = self.module_slice()[module_index];
        if snapshot.is_none() {
            return false;
        }
        unsafe { (*image).snapshot = snapshot };
        true
    }

    fn bind_native_snapshot_symbol(
        &mut self,
        module_name: *mut ClaspRtString,
        resolve_symbol: ClaspRtNativeSnapshotResolverFn,
    ) -> bool {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return false;
        };
        let image = self.module_slice()[module_index];
        let Some(resolve_symbol) = resolve_symbol else {
            return false;
        };
        let symbol = unsafe { (*image).snapshot_symbol };
        if symbol.is_null() {
            return false;
        }
        let snapshot = unsafe { resolve_symbol(symbol) };
        if snapshot.is_none() {
            return false;
        }
        unsafe { (*image).snapshot = snapshot };
        true
    }

    fn bind_native_entrypoint_symbol(
        &mut self,
        module_name: *mut ClaspRtString,
        export_name: *mut ClaspRtString,
        resolve_symbol: ClaspRtNativeSymbolResolverFn,
    ) -> bool {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return false;
        };
        let image = self.module_slice()[module_index];
        let Some(image_ref) = (unsafe { image.as_ref() }) else {
            return false;
        };
        let Some(export_index) = image_ref.export_index(export_name) else {
            return false;
        };
        let symbol = unsafe { (&(*image).entrypoint_symbols)[export_index] };
        let Some(resolve_symbol) = resolve_symbol else {
            return false;
        };
        if symbol.is_null() {
            return false;
        }
        let entrypoint = unsafe { resolve_symbol(symbol) };
        if entrypoint.is_none() {
            return false;
        }
        unsafe { (&mut (*image).entrypoints)[export_index] = entrypoint };
        true
    }

    fn bind_native_handoff(
        &mut self,
        module_name: *mut ClaspRtString,
        handoff: ClaspRtNativeHandoffFn,
    ) -> bool {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return false;
        };
        let image = self.module_slice()[module_index];
        if handoff.is_none() {
            return false;
        }
        unsafe { (*image).handoff = handoff };
        true
    }

    fn bind_native_handoff_symbol(
        &mut self,
        module_name: *mut ClaspRtString,
        resolve_symbol: ClaspRtNativeHandoffResolverFn,
    ) -> bool {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return false;
        };
        let image = self.module_slice()[module_index];
        let Some(resolve_symbol) = resolve_symbol else {
            return false;
        };
        let symbol = unsafe { (*image).handoff_symbol };
        if symbol.is_null() {
            return false;
        }
        let handoff = unsafe { resolve_symbol(symbol) };
        if handoff.is_none() {
            return false;
        }
        unsafe { (*image).handoff = handoff };
        true
    }

    fn resolve_native_dispatch(
        &self,
        module_name: *mut ClaspRtString,
        export_name: *mut ClaspRtString,
    ) -> *mut ClaspRtResultString {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return unsafe { missing_native_dispatch_result() };
        };
        let image = self.module_slice()[module_index];
        let Some(image_ref) = (unsafe { image.as_ref() }) else {
            return unsafe { missing_native_dispatch_result() };
        };
        if image_ref.export_index(export_name).is_none() {
            return unsafe { missing_native_dispatch_result() };
        }

        unsafe { build_native_dispatch_result(module_name, (*image).generation, export_name) }
    }

    fn resolve_native_dispatch_generation(
        &self,
        module_name: *mut ClaspRtString,
        generation: usize,
        export_name: *mut ClaspRtString,
    ) -> *mut ClaspRtResultString {
        let Some(module_index) = self.find_active_module_generation_index(module_name, generation) else {
            return unsafe { missing_native_dispatch_result() };
        };
        let image = self.module_slice()[module_index];
        let Some(image_ref) = (unsafe { image.as_ref() }) else {
            return unsafe { missing_native_dispatch_result() };
        };
        if image_ref.export_index(export_name).is_none() {
            return unsafe { missing_native_dispatch_result() };
        }

        unsafe { build_native_dispatch_result(module_name, generation, export_name) }
    }

    fn resolve_native_entrypoint(
        &self,
        module_name: *mut ClaspRtString,
        export_name: *mut ClaspRtString,
    ) -> ClaspRtNativeEntrypointFn {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return None;
        };
        let image = self.module_slice()[module_index];
        let Some(image_ref) = (unsafe { image.as_ref() }) else {
            return None;
        };
        let Some(export_index) = image_ref.export_index(export_name) else {
            return None;
        };
        unsafe { (&(*image).entrypoints)[export_index] }
    }

    fn resolve_native_entrypoint_generation(
        &self,
        module_name: *mut ClaspRtString,
        generation: usize,
        export_name: *mut ClaspRtString,
    ) -> ClaspRtNativeEntrypointFn {
        let Some(module_index) = self.find_active_module_generation_index(module_name, generation) else {
            return None;
        };
        let image = self.module_slice()[module_index];
        let Some(image_ref) = (unsafe { image.as_ref() }) else {
            return None;
        };
        let Some(export_index) = image_ref.export_index(export_name) else {
            return None;
        };
        unsafe { (&(*image).entrypoints)[export_index] }
    }

    fn resolve_native_snapshot(&self, module_name: *mut ClaspRtString) -> ClaspRtNativeSnapshotFn {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return None;
        };
        let image = self.module_slice()[module_index];
        unsafe { (*image).snapshot }
    }

    fn resolve_native_handoff(&self, module_name: *mut ClaspRtString) -> ClaspRtNativeHandoffFn {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return None;
        };
        let image = self.module_slice()[module_index];
        unsafe { (*image).handoff }
    }

    fn find_latest_route(
        &self,
        module_name: *mut ClaspRtString,
        method: &str,
        path: &str,
    ) -> Option<(*mut ClaspRtNativeModuleImage, usize)> {
        let module_index = self.find_latest_active_module_index(module_name)?;
        let image = self.module_slice()[module_index];
        let route_index = unsafe {
            (*image)
                .route_boundaries
                .iter()
                .position(|route| route.method == method && route.path == path)
        }?;
        Some((image, route_index))
    }

    fn store_native_module_state_snapshot(
        &mut self,
        module_name: *mut ClaspRtString,
        generation: usize,
        state_type: *mut ClaspRtString,
        snapshot: *mut ClaspRtJson,
    ) -> bool {
        let Some(module_index) = self.find_active_module_generation_index(module_name, generation) else {
            return false;
        };
        if state_type.is_null() || snapshot.is_null() || !unsafe { native_module_state_snapshot_is_valid(snapshot) } {
            return false;
        }
        let image = self.module_slice()[module_index];
        unsafe {
            release_header(self as *mut ClaspRtRuntime, (*image).state_snapshot_type as *mut ClaspRtHeader);
            release_header(self as *mut ClaspRtRuntime, (*image).state_snapshot as *mut ClaspRtHeader);
            retain_header(state_type as *mut ClaspRtHeader);
            retain_header(snapshot as *mut ClaspRtHeader);
            (*image).state_snapshot_type = state_type;
            (*image).state_snapshot = snapshot;
        }
        true
    }

    fn native_module_generation_state_type(
        &self,
        module_name: *mut ClaspRtString,
        generation: usize,
    ) -> *mut ClaspRtString {
        let Some(module_index) = self.find_active_module_generation_index(module_name, generation) else {
            return null_mut();
        };
        let image = self.module_slice()[module_index];
        if unsafe { (*image).state_snapshot_type.is_null() } {
            return null_mut();
        }
        unsafe {
            retain_header((*image).state_snapshot_type as *mut ClaspRtHeader);
            (*image).state_snapshot_type
        }
    }

    fn native_module_generation_state_snapshot(
        &self,
        module_name: *mut ClaspRtString,
        generation: usize,
    ) -> *mut ClaspRtJson {
        let Some(module_index) = self.find_active_module_generation_index(module_name, generation) else {
            return null_mut();
        };
        let image = self.module_slice()[module_index];
        if unsafe { (*image).state_snapshot.is_null() } {
            return null_mut();
        }
        unsafe {
            retain_header((*image).state_snapshot as *mut ClaspRtHeader);
            (*image).state_snapshot
        }
    }

    fn interpret_native_dispatch(
        &self,
        runtime: *mut ClaspRtRuntime,
        module_name: *mut ClaspRtString,
        export_name: *mut ClaspRtString,
        args: *mut *mut ClaspRtHeader,
        arg_count: usize,
    ) -> *mut ClaspRtHeader {
        let Some(module_index) = self.find_latest_active_module_index(module_name) else {
            return null_mut();
        };
        interpret_native_dispatch_for_image(runtime, self.module_slice()[module_index], export_name, args, arg_count)
    }

    fn interpret_native_dispatch_generation(
        &self,
        runtime: *mut ClaspRtRuntime,
        module_name: *mut ClaspRtString,
        generation: usize,
        export_name: *mut ClaspRtString,
        args: *mut *mut ClaspRtHeader,
        arg_count: usize,
    ) -> *mut ClaspRtHeader {
        let Some(module_index) = self.find_active_module_generation_index(module_name, generation) else {
            return null_mut();
        };
        interpret_native_dispatch_for_image(runtime, self.module_slice()[module_index], export_name, args, arg_count)
    }
}

fn interpret_native_dispatch_for_image(
    runtime: *mut ClaspRtRuntime,
    image: *mut ClaspRtNativeModuleImage,
    export_name: *mut ClaspRtString,
    args: *mut *mut ClaspRtHeader,
    arg_count: usize,
) -> *mut ClaspRtHeader {
    if image.is_null() || export_name.is_null() {
        return null_mut();
    }
    let Some(export_name_text) = (unsafe { String::from_utf8(string_bytes(export_name).to_vec()).ok() }) else {
        return null_mut();
    };
    let arg_slice = if args.is_null() || arg_count == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(args, arg_count) }
    };
    interpret_native_decl(runtime, image, &export_name_text, arg_slice, 0)
}

fn interpret_native_decl(
    runtime: *mut ClaspRtRuntime,
    image: *mut ClaspRtNativeModuleImage,
    decl_name: &str,
    args: &[*mut ClaspRtHeader],
    depth: usize,
) -> *mut ClaspRtHeader {
    if image.is_null() || depth > CLASP_RT_INTERPRETER_MAX_DEPTH {
        return null_mut();
    }
    let Some(decl) = (unsafe { (*image).interpreted_decl(decl_name) }) else {
        let binding_result = unsafe {
            if has_runtime_binding_or_builtin(image, decl_name) {
                interpret_runtime_binding_by_name(image, decl_name, args)
            } else {
                null_mut()
            }
        };
        if !binding_result.is_null() {
            return binding_result;
        }
        let codec_result = unsafe { interpret_native_codec_decl(decl_name, args) };
        if !codec_result.is_null() {
            return codec_result;
        }
        if trace_interpreter_enabled() {
            eprintln!("clasp native trace: missing decl `{}` at depth {}", decl_name, depth);
        }
        return null_mut();
    };

    let mut env: Vec<(&str, *mut ClaspRtHeader)> = Vec::new();
    if matches!(decl.kind, ClaspRtInterpretedDeclKind::Function) {
        if decl.params.len() != args.len() {
            return null_mut();
        }
        for (name, value) in decl.params.iter().zip(args.iter().copied()) {
            env.push((name.as_str(), value));
        }
    } else if !args.is_empty() {
        return null_mut();
    }

    let result = interpret_native_expr(runtime, image, &decl.body, &env, depth + 1);
    let result = unsafe { unwrap_early_return(runtime, result) };
    if result.is_null() && trace_interpreter_enabled() {
        eprintln!(
            "clasp native trace: decl `{}` returned null at depth {} with {} arg(s)",
            decl_name,
            depth,
            args.len()
        );
    }
    result
}

fn append_json_string_literal(out: &mut Vec<u8>, bytes: &[u8]) {
    out.push(b'"');
    for &byte in bytes {
        match byte {
            b'"' => out.extend_from_slice(br#"\""#),
            b'\\' => out.extend_from_slice(br#"\\"#),
            b'\n' => out.extend_from_slice(br#"\n"#),
            b'\r' => out.extend_from_slice(br#"\r"#),
            b'\t' => out.extend_from_slice(br#"\t"#),
            b'\x08' => out.extend_from_slice(br#"\b"#),
            b'\x0c' => out.extend_from_slice(br#"\f"#),
            0x00..=0x1f => {
                const HEX: &[u8; 16] = b"0123456789abcdef";
                out.extend_from_slice(br#"\u00"#);
                out.push(HEX[(byte >> 4) as usize]);
                out.push(HEX[(byte & 0x0f) as usize]);
            }
            _ => out.push(byte),
        }
    }
    out.push(b'"');
}

fn json_error_message(message: &str) -> String {
    let mut payload = Vec::new();
    payload.extend_from_slice(b"{\"status\":\"error\",\"error\":");
    append_json_string_literal(&mut payload, message.as_bytes());
    payload.push(b'}');
    String::from_utf8(payload).unwrap_or_else(|_| "{\"status\":\"error\",\"error\":\"invalid_utf8\"}".to_owned())
}

unsafe fn encode_runtime_value_json(value: *mut ClaspRtHeader) -> Option<Vec<u8>> {
    if value.is_null() {
        return None;
    }

    match (*value).layout_id {
        CLASP_RT_LAYOUT_STRING => {
            let mut encoded = Vec::with_capacity(string_bytes(value as *mut ClaspRtString).len() + 2);
            append_json_string_literal(&mut encoded, string_bytes(value as *mut ClaspRtString));
            Some(encoded)
        }
        CLASP_RT_LAYOUT_INT => Some((*(value as *mut ClaspRtInt)).value.to_string().into_bytes()),
        CLASP_RT_LAYOUT_BOOL => Some(
            if (*(value as *mut ClaspRtBool)).value {
                b"true".to_vec()
            } else {
                b"false".to_vec()
            },
        ),
        CLASP_RT_LAYOUT_STRING_LIST => {
            let mut encoded = Vec::from([b'[']);
            for (index, item) in string_list_items_mut(value as *mut ClaspRtStringList).iter().enumerate() {
                if index > 0 {
                    encoded.push(b',');
                }
                append_json_string_literal(&mut encoded, string_bytes(*item));
            }
            encoded.push(b']');
            Some(encoded)
        }
        CLASP_RT_LAYOUT_LIST_VALUE => {
            let mut encoded = Vec::from([b'[']);
            for (index, item) in list_value_items(value as *mut ClaspRtListValue).iter().enumerate() {
                if index > 0 {
                    encoded.push(b',');
                }
                encoded.extend_from_slice(&encode_runtime_value_json(*item)?);
            }
            encoded.push(b']');
            Some(encoded)
        }
        CLASP_RT_LAYOUT_RESULT_STRING => {
            let result = value as *mut ClaspRtResultString;
            let tag = if (*result).is_ok { b"Ok".as_slice() } else { b"Err".as_slice() };
            let payload = encode_runtime_value_json((*result).value as *mut ClaspRtHeader)?;
            let mut encoded = Vec::from([b'{']);
            append_json_string_literal(&mut encoded, b"$tag");
            encoded.extend_from_slice(b":");
            append_json_string_literal(&mut encoded, tag);
            encoded.extend_from_slice(b",");
            append_json_string_literal(&mut encoded, b"$0");
            encoded.extend_from_slice(b":");
            encoded.extend_from_slice(&payload);
            encoded.push(b'}');
            Some(encoded)
        }
        CLASP_RT_LAYOUT_RECORD_VALUE => {
            let record = value as *mut ClaspRtRecordValue;
            let mut encoded = Vec::from([b'{']);
            for (index, (field_name, field_value)) in record_field_names(record)
                .iter()
                .zip(record_field_values(record).iter())
                .enumerate()
            {
                if index > 0 {
                    encoded.push(b',');
                }
                append_json_string_literal(&mut encoded, string_bytes(*field_name));
                encoded.extend_from_slice(b":");
                encoded.extend_from_slice(&encode_runtime_value_json(*field_value)?);
            }
            encoded.push(b'}');
            Some(encoded)
        }
        CLASP_RT_LAYOUT_VARIANT_VALUE => {
            let variant = value as *mut ClaspRtVariantValue;
            if variant_items(variant).is_empty() {
                return Some(
                    json_string_literal(&normalize_variant_wire_tag(
                        &String::from_utf8_lossy(string_bytes((*variant).tag)),
                    ))
                    .into_bytes(),
                );
            }
            let mut encoded = Vec::from([b'{']);
            append_json_string_literal(&mut encoded, b"$tag");
            encoded.extend_from_slice(b":");
            append_json_string_literal(&mut encoded, string_bytes((*variant).tag));
            for (index, item) in variant_items(variant).iter().enumerate() {
                encoded.push(b',');
                append_json_string_literal(&mut encoded, format!("${index}").as_bytes());
                encoded.extend_from_slice(b":");
                encoded.extend_from_slice(&encode_runtime_value_json(*item)?);
            }
            encoded.push(b'}');
            Some(encoded)
        }
        CLASP_RT_LAYOUT_MUTABLE_CELL => encode_runtime_value_json((*(value as *mut ClaspRtMutableCell)).value),
        CLASP_RT_LAYOUT_EARLY_RETURN => encode_runtime_value_json((*(value as *mut ClaspRtEarlyReturn)).value),
        _ => None,
    }
}

pub unsafe fn clasp_rt_runtime_value_to_json_string(value: *mut ClaspRtHeader) -> Option<String> {
    encode_runtime_value_json(value).and_then(|bytes| String::from_utf8(bytes).ok())
}

unsafe fn interpret_native_codec_decl(
    decl_name: &str,
    args: &[*mut ClaspRtHeader],
) -> *mut ClaspRtHeader {
    if !decl_name.starts_with("$encode_") || args.len() != 1 {
        return null_mut();
    }

    match encode_runtime_value_json(args[0]) {
        Some(encoded) => build_runtime_string(&encoded) as *mut ClaspRtHeader,
        None => null_mut(),
    }
}

fn lookup_env_value(env: &[(&str, *mut ClaspRtHeader)], name: &str) -> *mut ClaspRtHeader {
    env.iter()
        .rev()
        .find(|(candidate, _)| *candidate == name)
        .map(|(_, value)| *value)
        .unwrap_or(null_mut())
}

fn read_env_value(env: &[(&str, *mut ClaspRtHeader)], name: &str) -> *mut ClaspRtHeader {
    let value = lookup_env_value(env, name);
    if value.is_null() {
        return null_mut();
    }

    unsafe {
        if (*value).layout_id == CLASP_RT_LAYOUT_MUTABLE_CELL {
            let cell = value as *mut ClaspRtMutableCell;
            retain_header((*cell).value);
            (*cell).value
        } else {
            retain_header(value);
            value
        }
    }
}

unsafe fn is_early_return_value(value: *mut ClaspRtHeader) -> bool {
    !value.is_null() && (*value).layout_id == CLASP_RT_LAYOUT_EARLY_RETURN
}

unsafe fn unwrap_early_return(runtime: *mut ClaspRtRuntime, value: *mut ClaspRtHeader) -> *mut ClaspRtHeader {
    if !is_early_return_value(value) {
        return value;
    }

    let wrapper = value as *mut ClaspRtEarlyReturn;
    let inner = (*wrapper).value;
    retain_header(inner);
    release_header(runtime, value);
    inner
}

fn update_mutable_binding(
    runtime: *mut ClaspRtRuntime,
    env: &[(&str, *mut ClaspRtHeader)],
    name: &str,
    value: *mut ClaspRtHeader,
) -> bool {
    let binding = lookup_env_value(env, name);
    if binding.is_null() {
        unsafe {
            release_header(runtime, value);
        }
        return false;
    }

    unsafe {
        if (*binding).layout_id != CLASP_RT_LAYOUT_MUTABLE_CELL {
            release_header(runtime, value);
            return false;
        }
        let cell = binding as *mut ClaspRtMutableCell;
        release_header(runtime, (*cell).value);
        (*cell).value = value;
    }
    true
}

unsafe fn header_bool_value(value: *mut ClaspRtHeader) -> Option<bool> {
    if value.is_null() || (*value).layout_id != CLASP_RT_LAYOUT_BOOL {
        None
    } else {
        Some((value as *mut ClaspRtBool).as_ref()?.value)
    }
}

unsafe fn header_int_value(value: *mut ClaspRtHeader) -> Option<i64> {
    if value.is_null() || (*value).layout_id != CLASP_RT_LAYOUT_INT {
        None
    } else {
        Some((value as *mut ClaspRtInt).as_ref()?.value)
    }
}

unsafe fn build_runtime_int_binary_result(
    left: *mut ClaspRtHeader,
    right: *mut ClaspRtHeader,
    op: impl FnOnce(i64, i64) -> Option<i64>,
) -> *mut ClaspRtHeader {
    let Some(left_value) = header_int_value(left) else {
        return null_mut();
    };
    let Some(right_value) = header_int_value(right) else {
        return null_mut();
    };
    match op(left_value, right_value) {
        Some(result) => build_runtime_int(result) as *mut ClaspRtHeader,
        None => null_mut(),
    }
}

unsafe fn list_like_string_items(value: *mut ClaspRtHeader) -> Option<Vec<*mut ClaspRtString>> {
    if value.is_null() {
        return None;
    }
    if (*value).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
        return Some(
            string_list_items_mut(value as *mut ClaspRtStringList)
                .iter()
                .copied()
                .collect(),
        );
    }
    if (*value).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
        let mut items = Vec::with_capacity(list_value_items(value as *mut ClaspRtListValue).len());
        for item in list_value_items(value as *mut ClaspRtListValue) {
            if (*item).is_null() || (**item).layout_id != CLASP_RT_LAYOUT_STRING {
                return None;
            }
            items.push(*item as *mut ClaspRtString);
        }
        return Some(items);
    }
    None
}

unsafe fn append_list_like_values(
    left: *mut ClaspRtHeader,
    right: *mut ClaspRtHeader,
) -> Option<Vec<*mut ClaspRtHeader>> {
    let mut items = Vec::new();
    for value in [left, right] {
        if value.is_null() {
            return None;
        }
        if (*value).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
            for item in string_list_items_mut(value as *mut ClaspRtStringList) {
                retain_header(*item as *mut ClaspRtHeader);
                items.push(*item as *mut ClaspRtHeader);
            }
        } else if (*value).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
            for item in list_value_items(value as *mut ClaspRtListValue) {
                retain_header(*item);
                items.push(*item);
            }
        } else {
            for item in items {
                release_header(null_mut(), item);
            }
            return None;
        }
    }
    Some(items)
}

unsafe fn runtime_value_is_view_like(value: *mut ClaspRtHeader) -> bool {
    if value.is_null() || (*value).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return false;
    }
    let record = value as *mut ClaspRtRecordValue;
    string_bytes((*record).record_name).starts_with(b"View")
}

unsafe fn prepend_list_like_value(
    value: *mut ClaspRtHeader,
    values: *mut ClaspRtHeader,
) -> Option<Vec<*mut ClaspRtHeader>> {
    if value.is_null() || values.is_null() {
        return None;
    }
    let mut items = Vec::new();
    items.push(value);
    if (*values).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
        for item in string_list_items_mut(values as *mut ClaspRtStringList) {
            retain_header(*item as *mut ClaspRtHeader);
            items.push(*item as *mut ClaspRtHeader);
        }
    } else if (*values).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
        for item in list_value_items(values as *mut ClaspRtListValue) {
            retain_header(*item);
            items.push(*item);
        }
    } else {
        return None;
    }
    Some(items)
}

unsafe fn reverse_list_like_values(values: *mut ClaspRtHeader) -> Option<Vec<*mut ClaspRtHeader>> {
    if values.is_null() {
        return None;
    }
    let mut items = Vec::new();
    if (*values).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
        for item in string_list_items_mut(values as *mut ClaspRtStringList).iter().rev() {
            retain_header(*item as *mut ClaspRtHeader);
            items.push(*item as *mut ClaspRtHeader);
        }
    } else if (*values).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
        for item in list_value_items(values as *mut ClaspRtListValue).iter().rev() {
            retain_header(*item);
            items.push(*item);
        }
    } else {
        return None;
    }
    Some(items)
}

unsafe fn concat_list_like_values(values: *mut ClaspRtHeader) -> Option<Vec<*mut ClaspRtHeader>> {
    if values.is_null() || (*values).layout_id != CLASP_RT_LAYOUT_LIST_VALUE {
        return None;
    }

    let mut items = Vec::new();
    for nested in list_value_items(values as *mut ClaspRtListValue) {
        if (*nested).is_null() {
            for item in items {
                release_header(null_mut(), item);
            }
            return None;
        }
        if (**nested).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
            for item in string_list_items_mut(*nested as *mut ClaspRtStringList) {
                retain_header(*item as *mut ClaspRtHeader);
                items.push(*item as *mut ClaspRtHeader);
            }
        } else if (**nested).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
            for item in list_value_items(*nested as *mut ClaspRtListValue) {
                retain_header(*item);
                items.push(*item);
            }
        } else {
            for item in items {
                release_header(null_mut(), item);
            }
            return None;
        }
    }
    Some(items)
}

unsafe fn list_or_text_length(value: *mut ClaspRtHeader) -> Option<i64> {
    if value.is_null() {
        return None;
    }
    if (*value).layout_id == CLASP_RT_LAYOUT_STRING {
        return Some(string_bytes(value as *mut ClaspRtString).len() as i64);
    }
    if (*value).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
        return Some(string_list_items_mut(value as *mut ClaspRtStringList).len() as i64);
    }
    if (*value).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
        return Some(list_value_items(value as *mut ClaspRtListValue).len() as i64);
    }
    None
}

unsafe fn list_like_borrowed_values(values: *mut ClaspRtHeader) -> Option<Vec<*mut ClaspRtHeader>> {
    if values.is_null() {
        return None;
    }
    if (*values).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
        return Some(
            string_list_items_mut(values as *mut ClaspRtStringList)
                .iter()
                .map(|item| *item as *mut ClaspRtHeader)
                .collect(),
        );
    }
    if (*values).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
        return Some(list_value_items(values as *mut ClaspRtListValue).iter().copied().collect());
    }
    None
}

fn local_function_name(expr: &ClaspRtInterpretedExpr) -> Option<&str> {
    match expr {
        ClaspRtInterpretedExpr::Local(name) => Some(name.as_str()),
        _ => None,
    }
}

fn interpret_legacy_list_builtin_call(
    runtime: *mut ClaspRtRuntime,
    image: *mut ClaspRtNativeModuleImage,
    name: &str,
    args: &[ClaspRtInterpretedExpr],
    env: &[(&str, *mut ClaspRtHeader)],
    depth: usize,
) -> Option<*mut ClaspRtHeader> {
    match name {
        "||" if args.len() == 2 => {
            let left_value = interpret_native_expr(runtime, image, &args[0], env, depth + 1);
            if left_value.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(left_value) } {
                return Some(left_value);
            }
            let Some(left_bool) = (unsafe { header_bool_value(left_value) }) else {
                unsafe {
                    release_header(runtime, left_value);
                }
                return Some(null_mut());
            };
            unsafe {
                release_header(runtime, left_value);
            }
            if left_bool {
                return Some(unsafe { build_runtime_bool(true) as *mut ClaspRtHeader });
            }
            let right_value = interpret_native_expr(runtime, image, &args[1], env, depth + 1);
            if right_value.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(right_value) } {
                return Some(right_value);
            }
            let result = match unsafe { header_bool_value(right_value) } {
                Some(value) => unsafe { build_runtime_bool(value) as *mut ClaspRtHeader },
                None => null_mut(),
            };
            unsafe {
                release_header(runtime, right_value);
            }
            Some(result)
        }
        "&&" if args.len() == 2 => {
            let left_value = interpret_native_expr(runtime, image, &args[0], env, depth + 1);
            if left_value.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(left_value) } {
                return Some(left_value);
            }
            let Some(left_bool) = (unsafe { header_bool_value(left_value) }) else {
                unsafe {
                    release_header(runtime, left_value);
                }
                return Some(null_mut());
            };
            unsafe {
                release_header(runtime, left_value);
            }
            if !left_bool {
                return Some(unsafe { build_runtime_bool(false) as *mut ClaspRtHeader });
            }
            let right_value = interpret_native_expr(runtime, image, &args[1], env, depth + 1);
            if right_value.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(right_value) } {
                return Some(right_value);
            }
            let result = match unsafe { header_bool_value(right_value) } {
                Some(value) => unsafe { build_runtime_bool(value) as *mut ClaspRtHeader },
                None => null_mut(),
            };
            unsafe {
                release_header(runtime, right_value);
            }
            Some(result)
        }
        "append" if args.len() >= 2 => {
            let mut current_value = interpret_native_expr(runtime, image, &args[0], env, depth + 1);
            if current_value.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(current_value) } {
                return Some(current_value);
            }

            for right_expr in &args[1..] {
                let right_value = interpret_native_expr(runtime, image, right_expr, env, depth + 1);
                if right_value.is_null() {
                    unsafe {
                        release_header(runtime, current_value);
                    }
                    return Some(null_mut());
                }
                if unsafe { is_early_return_value(right_value) } {
                    unsafe {
                        release_header(runtime, current_value);
                    }
                    return Some(right_value);
                }
                let appended = unsafe { append_list_like_values(current_value, right_value) };
                let view_appended = if appended.is_none()
                    && unsafe { runtime_value_is_view_like(current_value) }
                    && unsafe { runtime_value_is_view_like(right_value) }
                {
                    unsafe { clasp_rt_view_append(current_value, right_value) }
                } else {
                    null_mut()
                };
                unsafe {
                    release_header(runtime, current_value);
                    release_header(runtime, right_value);
                }
                current_value = match appended {
                    Some(items) => unsafe { build_runtime_list_value(items) as *mut ClaspRtHeader },
                    None => view_appended,
                };
                if current_value.is_null() {
                    return Some(null_mut());
                }
            }
            Some(current_value)
        }
        "prepend" if args.len() == 2 => {
            let value = interpret_native_expr(runtime, image, &args[0], env, depth + 1);
            if value.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(value) } {
                return Some(value);
            }
            let values = interpret_native_expr(runtime, image, &args[1], env, depth + 1);
            if values.is_null() {
                unsafe {
                    release_header(runtime, value);
                }
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(values) } {
                unsafe {
                    release_header(runtime, value);
                }
                return Some(values);
            }
            let prepended = unsafe { prepend_list_like_value(value, values) };
            unsafe {
                release_header(runtime, values);
            }
            Some(match prepended {
                Some(items) => unsafe { build_runtime_list_value(items) as *mut ClaspRtHeader },
                None => unsafe {
                    release_header(runtime, value);
                    null_mut()
                },
            })
        }
        "reverse" if args.len() == 1 => {
            let values = interpret_native_expr(runtime, image, &args[0], env, depth + 1);
            if values.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(values) } {
                return Some(values);
            }
            let reversed = unsafe { reverse_list_like_values(values) };
            unsafe {
                release_header(runtime, values);
            }
            Some(match reversed {
                Some(items) => unsafe { build_runtime_list_value(items) as *mut ClaspRtHeader },
                None => null_mut(),
            })
        }
        "concat" if args.len() == 1 => {
            let values = interpret_native_expr(runtime, image, &args[0], env, depth + 1);
            if values.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(values) } {
                return Some(values);
            }
            let concatenated = unsafe { concat_list_like_values(values) };
            unsafe {
                release_header(runtime, values);
            }
            Some(match concatenated {
                Some(items) => unsafe { build_runtime_list_value(items) as *mut ClaspRtHeader },
                None => null_mut(),
            })
        }
        "length" if args.len() == 1 => {
            let value = interpret_native_expr(runtime, image, &args[0], env, depth + 1);
            if value.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(value) } {
                return Some(value);
            }
            let result = unsafe { list_or_text_length(value) };
            unsafe {
                release_header(runtime, value);
            }
            Some(match result {
                Some(length) => unsafe { build_runtime_int(length) as *mut ClaspRtHeader },
                None => null_mut(),
            })
        }
        "map" if args.len() == 2 => {
            let Some(callee) = local_function_name(&args[0]) else {
                return Some(null_mut());
            };
            let values = interpret_native_expr(runtime, image, &args[1], env, depth + 1);
            if values.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(values) } {
                return Some(values);
            }
            let result = unsafe {
                let iterable_items: Vec<*mut ClaspRtHeader> = if (*values).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
                    string_list_items_mut(values as *mut ClaspRtStringList)
                        .iter()
                        .map(|item| *item as *mut ClaspRtHeader)
                        .collect()
                } else if (*values).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
                    list_value_items(values as *mut ClaspRtListValue).iter().copied().collect()
                } else {
                    release_header(runtime, values);
                    return Some(null_mut());
                };
                let mut mapped_items = Vec::with_capacity(iterable_items.len());
                for item in iterable_items {
                    let step_result = interpret_native_decl(runtime, image, callee, &[item], depth + 1);
                    if step_result.is_null() {
                        for mapped_item in mapped_items {
                            release_header(runtime, mapped_item);
                        }
                        release_header(runtime, values);
                        return Some(null_mut());
                    }
                    mapped_items.push(step_result);
                }
                release_header(runtime, values);
                Some(build_runtime_list_value(mapped_items) as *mut ClaspRtHeader)
            };
            result
        }
        "filter" if args.len() == 2 => {
            let Some(callee) = local_function_name(&args[0]) else {
                return Some(null_mut());
            };
            let values = interpret_native_expr(runtime, image, &args[1], env, depth + 1);
            if values.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(values) } {
                return Some(values);
            }
            let result = unsafe {
                let Some(iterable_items) = list_like_borrowed_values(values) else {
                    release_header(runtime, values);
                    return Some(null_mut());
                };
                let mut filtered_items = Vec::new();
                for item in iterable_items {
                    let step_result = interpret_native_decl(runtime, image, callee, &[item], depth + 1);
                    if step_result.is_null() {
                        for filtered_item in filtered_items {
                            release_header(runtime, filtered_item);
                        }
                        release_header(runtime, values);
                        return Some(null_mut());
                    }
                    let Some(keep_item) = header_bool_value(step_result) else {
                        release_header(runtime, step_result);
                        for filtered_item in filtered_items {
                            release_header(runtime, filtered_item);
                        }
                        release_header(runtime, values);
                        return Some(null_mut());
                    };
                    release_header(runtime, step_result);
                    if keep_item {
                        retain_header(item);
                        filtered_items.push(item);
                    }
                }
                release_header(runtime, values);
                Some(build_runtime_list_value(filtered_items) as *mut ClaspRtHeader)
            };
            result
        }
        "find" if args.len() == 2 => {
            let Some(callee) = local_function_name(&args[0]) else {
                return Some(null_mut());
            };
            let values = interpret_native_expr(runtime, image, &args[1], env, depth + 1);
            if values.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(values) } {
                return Some(values);
            }
            let result = unsafe {
                let Some(iterable_items) = list_like_borrowed_values(values) else {
                    release_header(runtime, values);
                    return Some(null_mut());
                };
                for item in iterable_items {
                    retain_header(item);
                    let step_result = interpret_native_decl(runtime, image, callee, &[item], depth + 1);
                    if step_result.is_null() {
                        release_header(runtime, item);
                        release_header(runtime, values);
                        return Some(null_mut());
                    }
                    let Some(matches_item) = header_bool_value(step_result) else {
                        release_header(runtime, step_result);
                        release_header(runtime, item);
                        release_header(runtime, values);
                        return Some(null_mut());
                    };
                    release_header(runtime, step_result);
                    if matches_item {
                        release_header(runtime, values);
                        return Some(clasp_rt_build_variant_header("Some", vec![item]));
                    }
                    release_header(runtime, item);
                }
                release_header(runtime, values);
                Some(clasp_rt_build_variant_header("None", Vec::new()))
            };
            result
        }
        "any" if args.len() == 2 => {
            let Some(callee) = local_function_name(&args[0]) else {
                return Some(null_mut());
            };
            let values = interpret_native_expr(runtime, image, &args[1], env, depth + 1);
            if values.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(values) } {
                return Some(values);
            }
            let result = unsafe {
                let Some(iterable_items) = list_like_borrowed_values(values) else {
                    release_header(runtime, values);
                    return Some(null_mut());
                };
                for item in iterable_items {
                    let step_result = interpret_native_decl(runtime, image, callee, &[item], depth + 1);
                    if step_result.is_null() {
                        release_header(runtime, values);
                        return Some(null_mut());
                    }
                    let Some(matches_item) = header_bool_value(step_result) else {
                        release_header(runtime, step_result);
                        release_header(runtime, values);
                        return Some(null_mut());
                    };
                    release_header(runtime, step_result);
                    if matches_item {
                        release_header(runtime, values);
                        return Some(build_runtime_bool(true) as *mut ClaspRtHeader);
                    }
                }
                release_header(runtime, values);
                Some(build_runtime_bool(false) as *mut ClaspRtHeader)
            };
            result
        }
        "all" if args.len() == 2 => {
            let Some(callee) = local_function_name(&args[0]) else {
                return Some(null_mut());
            };
            let values = interpret_native_expr(runtime, image, &args[1], env, depth + 1);
            if values.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(values) } {
                return Some(values);
            }
            let result = unsafe {
                let Some(iterable_items) = list_like_borrowed_values(values) else {
                    release_header(runtime, values);
                    return Some(null_mut());
                };
                for item in iterable_items {
                    let step_result = interpret_native_decl(runtime, image, callee, &[item], depth + 1);
                    if step_result.is_null() {
                        release_header(runtime, values);
                        return Some(null_mut());
                    }
                    let Some(matches_item) = header_bool_value(step_result) else {
                        release_header(runtime, step_result);
                        release_header(runtime, values);
                        return Some(null_mut());
                    };
                    release_header(runtime, step_result);
                    if !matches_item {
                        release_header(runtime, values);
                        return Some(build_runtime_bool(false) as *mut ClaspRtHeader);
                    }
                }
                release_header(runtime, values);
                Some(build_runtime_bool(true) as *mut ClaspRtHeader)
            };
            result
        }
        "fold" if args.len() == 3 => {
            let Some(callee) = local_function_name(&args[0]) else {
                return Some(null_mut());
            };
            let initial_value = interpret_native_expr(runtime, image, &args[1], env, depth + 1);
            if initial_value.is_null() {
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(initial_value) } {
                return Some(initial_value);
            }
            let values = interpret_native_expr(runtime, image, &args[2], env, depth + 1);
            if values.is_null() {
                unsafe {
                    release_header(runtime, initial_value);
                }
                return Some(null_mut());
            }
            if unsafe { is_early_return_value(values) } {
                unsafe {
                    release_header(runtime, initial_value);
                }
                return Some(values);
            }
            let result = unsafe {
                let iterable_items: Vec<*mut ClaspRtHeader> = if (*values).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
                    string_list_items_mut(values as *mut ClaspRtStringList)
                        .iter()
                        .map(|item| *item as *mut ClaspRtHeader)
                        .collect()
                } else if (*values).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
                    list_value_items(values as *mut ClaspRtListValue).iter().copied().collect()
                } else {
                    release_header(runtime, initial_value);
                    release_header(runtime, values);
                    return Some(null_mut());
                };
                let mut accumulator = initial_value;
                for item in iterable_items {
                    let step_result = if callee == "||" {
                        match (header_bool_value(accumulator), header_bool_value(item)) {
                            (Some(left), Some(right)) => build_runtime_bool(left || right) as *mut ClaspRtHeader,
                            _ => null_mut(),
                        }
                    } else if callee == "&&" {
                        match (header_bool_value(accumulator), header_bool_value(item)) {
                            (Some(left), Some(right)) => build_runtime_bool(left && right) as *mut ClaspRtHeader,
                            _ => null_mut(),
                        }
                    } else {
                        interpret_native_decl(runtime, image, callee, &[accumulator, item], depth + 1)
                    };
                    if step_result.is_null() {
                        release_header(runtime, accumulator);
                        release_header(runtime, values);
                        return Some(null_mut());
                    }
                    release_header(runtime, accumulator);
                    accumulator = step_result;
                }
                release_header(runtime, values);
                Some(accumulator)
            };
            result
        }
        _ => None,
    }
}

unsafe fn compare_runtime_values(
    op: ClaspRtInterpretedCompareOp,
    left: *mut ClaspRtHeader,
    right: *mut ClaspRtHeader,
) -> Option<bool> {
    if left.is_null() || right.is_null() {
        return None;
    }

    if matches!(
        op,
        ClaspRtInterpretedCompareOp::Eq | ClaspRtInterpretedCompareOp::Ne
    ) {
        let equality = compare_runtime_value_equality(left, right)?;
        return Some(match op {
            ClaspRtInterpretedCompareOp::Eq => equality,
            ClaspRtInterpretedCompareOp::Ne => !equality,
            _ => unreachable!(),
        });
    }

    if (*left).layout_id == CLASP_RT_LAYOUT_STRING && (*right).layout_id == CLASP_RT_LAYOUT_STRING {
        let ordering = string_bytes(left as *mut ClaspRtString).cmp(string_bytes(right as *mut ClaspRtString));
        return Some(match op {
            ClaspRtInterpretedCompareOp::Lt => ordering.is_lt(),
            ClaspRtInterpretedCompareOp::Le => ordering.is_le(),
            ClaspRtInterpretedCompareOp::Gt => ordering.is_gt(),
            ClaspRtInterpretedCompareOp::Ge => ordering.is_ge(),
            _ => unreachable!(),
        });
    }

    if let (Some(left_value), Some(right_value)) = (header_int_value(left), header_int_value(right)) {
        return Some(match op {
            ClaspRtInterpretedCompareOp::Lt => left_value < right_value,
            ClaspRtInterpretedCompareOp::Le => left_value <= right_value,
            ClaspRtInterpretedCompareOp::Gt => left_value > right_value,
            ClaspRtInterpretedCompareOp::Ge => left_value >= right_value,
            _ => unreachable!(),
        });
    }

    if let (Some(left_value), Some(right_value)) = (header_bool_value(left), header_bool_value(right)) {
        return Some(match op {
            ClaspRtInterpretedCompareOp::Lt => (!left_value) && right_value,
            ClaspRtInterpretedCompareOp::Le => left_value == right_value || ((!left_value) && right_value),
            ClaspRtInterpretedCompareOp::Gt => left_value && (!right_value),
            ClaspRtInterpretedCompareOp::Ge => left_value == right_value || (left_value && (!right_value)),
            _ => unreachable!(),
        });
    }

    None
}

unsafe fn compare_runtime_value_equality(left: *mut ClaspRtHeader, right: *mut ClaspRtHeader) -> Option<bool> {
    if left.is_null() || right.is_null() {
        return None;
    }

    if ptr::eq(left, right) {
        return Some(true);
    }

    if (*left).layout_id == CLASP_RT_LAYOUT_STRING && (*right).layout_id == CLASP_RT_LAYOUT_STRING {
        return Some(string_bytes(left as *mut ClaspRtString) == string_bytes(right as *mut ClaspRtString));
    }

    if let (Some(left_value), Some(right_value)) = (header_int_value(left), header_int_value(right)) {
        return Some(left_value == right_value);
    }

    if let (Some(left_value), Some(right_value)) = (header_bool_value(left), header_bool_value(right)) {
        return Some(left_value == right_value);
    }

    let left_items = list_like_borrowed_values(left)?;
    let right_items = list_like_borrowed_values(right)?;
    if left_items.len() != right_items.len() {
        return Some(false);
    }

    for (left_item, right_item) in left_items.iter().zip(right_items.iter()) {
        match compare_runtime_value_equality(*left_item, *right_item) {
            Some(true) => {}
            Some(false) => return Some(false),
            None => return None,
        }
    }
    Some(true)
}

fn interpret_native_expr(
    runtime: *mut ClaspRtRuntime,
    image: *mut ClaspRtNativeModuleImage,
    expr: &ClaspRtInterpretedExpr,
    env: &[(&str, *mut ClaspRtHeader)],
    depth: usize,
) -> *mut ClaspRtHeader {
    if depth > CLASP_RT_INTERPRETER_MAX_DEPTH {
        return null_mut();
    }

    match expr {
        ClaspRtInterpretedExpr::IntLiteral(value) => unsafe { build_runtime_int(*value) as *mut ClaspRtHeader },
        ClaspRtInterpretedExpr::BoolLiteral(value) => unsafe { build_runtime_bool(*value) as *mut ClaspRtHeader },
        ClaspRtInterpretedExpr::StringLiteral(bytes) => unsafe { build_runtime_string(bytes) as *mut ClaspRtHeader },
        ClaspRtInterpretedExpr::Local(name) => {
            let value = read_env_value(env, name);
            if value.is_null() {
                interpret_native_decl(runtime, image, name, &[], depth + 1)
            } else {
                unsafe { retain_header(value) };
                value
            }
        }
        ClaspRtInterpretedExpr::List(items) => {
            let mut interpreted_items: Vec<*mut ClaspRtHeader> = Vec::with_capacity(items.len());
            for item in items.iter() {
                let value = interpret_native_expr(runtime, image, item, env, depth + 1);
                if value.is_null() {
                    for interpreted in interpreted_items {
                        unsafe { release_header(runtime, interpreted) };
                    }
                    return null_mut();
                }
                if unsafe { is_early_return_value(value) } {
                    for interpreted in interpreted_items {
                        unsafe { release_header(runtime, interpreted) };
                    }
                    return value;
                }
                interpreted_items.push(value);
            }
            unsafe { build_runtime_list_value(interpreted_items) as *mut ClaspRtHeader }
        }
        ClaspRtInterpretedExpr::If(condition, then_branch, else_branch) => {
            let condition_value = interpret_native_expr(runtime, image, condition, env, depth + 1);
            if condition_value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(condition_value) } {
                return condition_value;
            }
            let condition_bool = unsafe { header_bool_value(condition_value) };
            unsafe {
                release_header(runtime, condition_value);
            }
            match condition_bool {
                Some(true) => interpret_native_expr(runtime, image, then_branch, env, depth + 1),
                Some(false) => interpret_native_expr(runtime, image, else_branch, env, depth + 1),
                None => null_mut(),
            }
        }
        ClaspRtInterpretedExpr::Compare(op, left, right) => {
            let left_value = interpret_native_expr(runtime, image, left, env, depth + 1);
            if left_value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(left_value) } {
                return left_value;
            }
            let right_value = interpret_native_expr(runtime, image, right, env, depth + 1);
            if right_value.is_null() {
                unsafe {
                    release_header(runtime, left_value);
                }
                return null_mut();
            }
            if unsafe { is_early_return_value(right_value) } {
                unsafe {
                    release_header(runtime, left_value);
                }
                return right_value;
            }
            let compared = unsafe { compare_runtime_values(*op, left_value, right_value) };
            unsafe {
                release_header(runtime, left_value);
                release_header(runtime, right_value);
            }
            match compared {
                Some(value) => unsafe { build_runtime_bool(value) as *mut ClaspRtHeader },
                None => null_mut(),
            }
        }
        ClaspRtInterpretedExpr::Return(value) => {
            let result = interpret_native_expr(runtime, image, value, env, depth + 1);
            if result.is_null() || unsafe { is_early_return_value(result) } {
                result
            } else {
                unsafe { build_runtime_early_return(result) as *mut ClaspRtHeader }
            }
        }
        ClaspRtInterpretedExpr::CallLocal(name, args) => {
            if let Some(result) =
                interpret_legacy_list_builtin_call(runtime, image, name, args, env, depth)
            {
                if result.is_null() && trace_interpreter_enabled() {
                    eprintln!(
                        "clasp native trace: legacy builtin call `{}` returned null at depth {} with {} arg(s)",
                        name,
                        depth,
                        args.len()
                    );
                }
                return result;
            }
            let mut interpreted_args: Vec<*mut ClaspRtHeader> = Vec::with_capacity(args.len());
            for arg in args {
                let value = interpret_native_expr(runtime, image, arg, env, depth + 1);
                if value.is_null() {
                    for interpreted in interpreted_args {
                        unsafe { release_header(runtime, interpreted) };
                    }
                    return null_mut();
                }
                if unsafe { is_early_return_value(value) } {
                    for interpreted in interpreted_args {
                        unsafe { release_header(runtime, interpreted) };
                    }
                    return value;
                }
                interpreted_args.push(value);
            }

            let result = interpret_native_decl(runtime, image, name, &interpreted_args, depth + 1);
            if result.is_null() && trace_interpreter_enabled() {
                eprintln!(
                    "clasp native trace: call `{}` returned null at depth {} with {} arg(s)",
                    name,
                    depth,
                    interpreted_args.len()
                );
            }
            for interpreted in interpreted_args {
                unsafe { release_header(runtime, interpreted) };
            }
            result
        }
        ClaspRtInterpretedExpr::Match(scrutinee, branches) => {
            let scrutinee_value = interpret_native_expr(runtime, image, scrutinee, env, depth + 1);
            if scrutinee_value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(scrutinee_value) } {
                return scrutinee_value;
            }

            let result = interpret_match_value(runtime, image, scrutinee_value, branches, env, depth + 1);
            unsafe {
                release_header(runtime, scrutinee_value);
            }
            result
        }
        ClaspRtInterpretedExpr::Let(is_mutable, name, value, body) => {
            let bound_value = interpret_native_expr(runtime, image, value, env, depth + 1);
            if bound_value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(bound_value) } {
                return bound_value;
            }
            let scoped_value = if *is_mutable {
                unsafe { build_runtime_mutable_cell(bound_value) as *mut ClaspRtHeader }
            } else {
                bound_value
            };
            let mut extended_env = env.to_vec();
            extended_env.push((name.as_str(), scoped_value));
            let result = interpret_native_expr(runtime, image, body, &extended_env, depth + 1);
            unsafe {
                release_header(runtime, scoped_value);
            }
            result
        }
        ClaspRtInterpretedExpr::Assign(name, value, body) => {
            let assigned_value = interpret_native_expr(runtime, image, value, env, depth + 1);
            if assigned_value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(assigned_value) } {
                return assigned_value;
            }
            if !update_mutable_binding(runtime, env, name, assigned_value) {
                return null_mut();
            }
            interpret_native_expr(runtime, image, body, env, depth + 1)
        }
        ClaspRtInterpretedExpr::ForEach(name, iterable, loop_body, body) => {
            let iterable_value = interpret_native_expr(runtime, image, iterable, env, depth + 1);
            if iterable_value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(iterable_value) } {
                return iterable_value;
            }
            unsafe {
                if (*iterable_value).layout_id != CLASP_RT_LAYOUT_STRING_LIST
                    && (*iterable_value).layout_id != CLASP_RT_LAYOUT_LIST_VALUE
                {
                    release_header(runtime, iterable_value);
                    return null_mut();
                }
                let iterable_items: Vec<*mut ClaspRtHeader> =
                    if (*iterable_value).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
                        string_list_items_mut(iterable_value as *mut ClaspRtStringList)
                            .iter()
                            .map(|item| *item as *mut ClaspRtHeader)
                            .collect()
                    } else {
                        list_value_items(iterable_value as *mut ClaspRtListValue)
                            .iter()
                            .copied()
                            .collect()
                    };
                for item in iterable_items {
                    let mut iteration_env = env.to_vec();
                    iteration_env.push((name.as_str(), item));
                    let loop_result = interpret_native_expr(runtime, image, loop_body, &iteration_env, depth + 1);
                    if is_early_return_value(loop_result) {
                        release_header(runtime, iterable_value);
                        return loop_result;
                    }
                    release_header(runtime, loop_result);
                }
                release_header(runtime, iterable_value);
            }
            interpret_native_expr(runtime, image, body, env, depth + 1)
        }
        ClaspRtInterpretedExpr::Construct(name, args) => {
            let mut interpreted_args: Vec<*mut ClaspRtHeader> = Vec::with_capacity(args.len());
            for arg in args {
                let value = interpret_native_expr(runtime, image, arg, env, depth + 1);
                if value.is_null() {
                    for interpreted in interpreted_args {
                        unsafe { release_header(runtime, interpreted) };
                    }
                    return null_mut();
                }
                if unsafe { is_early_return_value(value) } {
                    for interpreted in interpreted_args {
                        unsafe { release_header(runtime, interpreted) };
                    }
                    return value;
                }
                interpreted_args.push(value);
            }
            let mut owned_args = Some(interpreted_args);
            let result = match name.as_str() {
                "Ok" if owned_args.as_ref().map_or(0, Vec::len) == 1 => unsafe {
                    let args = owned_args.as_ref().unwrap();
                    if (*args[0]).layout_id == CLASP_RT_LAYOUT_STRING {
                        let built = build_runtime_result_string(true, args[0] as *mut ClaspRtString);
                        release_header(runtime, args[0]);
                        built as *mut ClaspRtHeader
                    } else {
                        build_runtime_variant_value(name, owned_args.take().unwrap()) as *mut ClaspRtHeader
                    }
                },
                "Err" if owned_args.as_ref().map_or(0, Vec::len) == 1 => unsafe {
                    let args = owned_args.as_ref().unwrap();
                    if (*args[0]).layout_id == CLASP_RT_LAYOUT_STRING {
                        let built = build_runtime_result_string(false, args[0] as *mut ClaspRtString);
                        release_header(runtime, args[0]);
                        built as *mut ClaspRtHeader
                    } else {
                        build_runtime_variant_value(name, owned_args.take().unwrap()) as *mut ClaspRtHeader
                    }
                },
                _ => unsafe {
                    build_runtime_variant_value(name, owned_args.take().unwrap()) as *mut ClaspRtHeader
                },
            };
            if result.is_null() {
                for interpreted in owned_args.unwrap_or_default() {
                    unsafe { release_header(runtime, interpreted) };
                }
            }
            result
        }
        ClaspRtInterpretedExpr::Record(record_name, fields) => {
            let mut interpreted_fields: Vec<(String, *mut ClaspRtHeader)> = Vec::with_capacity(fields.len());
            for field in fields {
                let value = interpret_native_expr(runtime, image, &field.value, env, depth + 1);
                if value.is_null() {
                    for (_, interpreted) in interpreted_fields {
                        unsafe { release_header(runtime, interpreted) };
                    }
                    return null_mut();
                }
                if unsafe { is_early_return_value(value) } {
                    for (_, interpreted) in interpreted_fields {
                        unsafe { release_header(runtime, interpreted) };
                    }
                    return value;
                }
                interpreted_fields.push((field.name.clone(), value));
            }
            unsafe { build_runtime_record_value(record_name, interpreted_fields) as *mut ClaspRtHeader }
        }
        ClaspRtInterpretedExpr::FieldAccess(record_name, target, field_name) => {
            let target_value = interpret_native_expr(runtime, image, target, env, depth + 1);
            if target_value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(target_value) } {
                return target_value;
            }
            let result = unsafe {
                if (*target_value).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
                    null_mut()
                } else {
                    let record_value = target_value as *mut ClaspRtRecordValue;
                    let record_matches = record_name.is_empty()
                        || string_bytes((*record_value).record_name) == record_name.as_bytes();
                    if !record_matches {
                        null_mut()
                    } else {
                        let mut matched = null_mut();
                        for (name_ptr, value_ptr) in record_field_names(record_value)
                            .iter()
                            .zip(record_field_values(record_value).iter())
                        {
                            if string_bytes(*name_ptr) == field_name.as_bytes() {
                                retain_header(*value_ptr);
                                matched = *value_ptr;
                                break;
                            }
                        }
                        matched
                    }
                }
            };
            unsafe {
                release_header(runtime, target_value);
            }
            result
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ListAppend(left, right)) => {
            let left_value = interpret_native_expr(runtime, image, left, env, depth + 1);
            if left_value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(left_value) } {
                return left_value;
            }
            let right_value = interpret_native_expr(runtime, image, right, env, depth + 1);
            if right_value.is_null() {
                unsafe {
                    release_header(runtime, left_value);
                }
                return null_mut();
            }
            if unsafe { is_early_return_value(right_value) } {
                unsafe {
                    release_header(runtime, left_value);
                }
                return right_value;
            }
            let appended = unsafe { append_list_like_values(left_value, right_value) };
            let view_appended = if appended.is_none()
                && unsafe { runtime_value_is_view_like(left_value) }
                && unsafe { runtime_value_is_view_like(right_value) }
            {
                unsafe { clasp_rt_view_append(left_value, right_value) }
            } else {
                null_mut()
            };
            unsafe {
                release_header(runtime, left_value);
                release_header(runtime, right_value);
            }
            match appended {
                Some(items) => unsafe { build_runtime_list_value(items) as *mut ClaspRtHeader },
                None => view_appended,
            }
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ListPrepend(value_expr, values_expr)) => {
            let value = interpret_native_expr(runtime, image, value_expr, env, depth + 1);
            if value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(value) } {
                return value;
            }
            let values = interpret_native_expr(runtime, image, values_expr, env, depth + 1);
            if values.is_null() {
                unsafe {
                    release_header(runtime, value);
                }
                return null_mut();
            }
            if unsafe { is_early_return_value(values) } {
                unsafe {
                    release_header(runtime, value);
                }
                return values;
            }
            let prepended = unsafe { prepend_list_like_value(value, values) };
            unsafe {
                release_header(runtime, values);
            }
            match prepended {
                Some(items) => unsafe { build_runtime_list_value(items) as *mut ClaspRtHeader },
                None => unsafe {
                    release_header(runtime, value);
                    null_mut()
                },
            }
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ListReverse(values_expr)) => {
            let values = interpret_native_expr(runtime, image, values_expr, env, depth + 1);
            if values.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(values) } {
                return values;
            }
            let reversed = unsafe { reverse_list_like_values(values) };
            unsafe {
                release_header(runtime, values);
            }
            match reversed {
                Some(items) => unsafe { build_runtime_list_value(items) as *mut ClaspRtHeader },
                None => null_mut(),
            }
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ListConcat(values_expr)) => {
            let values = interpret_native_expr(runtime, image, values_expr, env, depth + 1);
            if values.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(values) } {
                return values;
            }
            let concatenated = unsafe { concat_list_like_values(values) };
            unsafe {
                release_header(runtime, values);
            }
            match concatenated {
                Some(items) => unsafe { build_runtime_list_value(items) as *mut ClaspRtHeader },
                None => null_mut(),
            }
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::Length(value_expr)) => {
            let value = interpret_native_expr(runtime, image, value_expr, env, depth + 1);
            if value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(value) } {
                return value;
            }
            let result = unsafe { list_or_text_length(value) };
            unsafe {
                release_header(runtime, value);
            }
            match result {
                Some(length) => unsafe { build_runtime_int(length) as *mut ClaspRtHeader },
                None => null_mut(),
            }
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ListMap(callee, values_expr)) => {
            let values = interpret_native_expr(runtime, image, values_expr, env, depth + 1);
            if values.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(values) } {
                return values;
            }
            let result = unsafe {
                let iterable_items: Vec<*mut ClaspRtHeader> = if (*values).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
                    string_list_items_mut(values as *mut ClaspRtStringList)
                        .iter()
                        .map(|item| *item as *mut ClaspRtHeader)
                        .collect()
                } else if (*values).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
                    list_value_items(values as *mut ClaspRtListValue).iter().copied().collect()
                } else {
                    release_header(runtime, values);
                    return null_mut();
                };
                let mut mapped_items = Vec::with_capacity(iterable_items.len());
                for item in iterable_items {
                    let step_result = interpret_native_decl(runtime, image, callee.as_str(), &[item], depth + 1);
                    if step_result.is_null() {
                        for mapped_item in mapped_items {
                            release_header(runtime, mapped_item);
                        }
                        release_header(runtime, values);
                        return null_mut();
                    }
                    mapped_items.push(step_result);
                }
                release_header(runtime, values);
                build_runtime_list_value(mapped_items) as *mut ClaspRtHeader
            };
            result
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ListFilter(callee, values_expr)) => {
            let values = interpret_native_expr(runtime, image, values_expr, env, depth + 1);
            if values.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(values) } {
                return values;
            }
            let result = unsafe {
                let Some(iterable_items) = list_like_borrowed_values(values) else {
                    release_header(runtime, values);
                    return null_mut();
                };
                let mut filtered_items = Vec::new();
                for item in iterable_items {
                    let step_result = interpret_native_decl(runtime, image, callee.as_str(), &[item], depth + 1);
                    if step_result.is_null() {
                        for filtered_item in filtered_items {
                            release_header(runtime, filtered_item);
                        }
                        release_header(runtime, values);
                        return null_mut();
                    }
                    let Some(keep_item) = header_bool_value(step_result) else {
                        release_header(runtime, step_result);
                        for filtered_item in filtered_items {
                            release_header(runtime, filtered_item);
                        }
                        release_header(runtime, values);
                        return null_mut();
                    };
                    release_header(runtime, step_result);
                    if keep_item {
                        retain_header(item);
                        filtered_items.push(item);
                    }
                }
                release_header(runtime, values);
                build_runtime_list_value(filtered_items) as *mut ClaspRtHeader
            };
            result
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ListFind(callee, values_expr)) => {
            let values = interpret_native_expr(runtime, image, values_expr, env, depth + 1);
            if values.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(values) } {
                return values;
            }
            let result = unsafe {
                let Some(iterable_items) = list_like_borrowed_values(values) else {
                    release_header(runtime, values);
                    return null_mut();
                };
                for item in iterable_items {
                    retain_header(item);
                    let step_result = interpret_native_decl(runtime, image, callee.as_str(), &[item], depth + 1);
                    if step_result.is_null() {
                        release_header(runtime, item);
                        release_header(runtime, values);
                        return null_mut();
                    }
                    let Some(matches_item) = header_bool_value(step_result) else {
                        release_header(runtime, step_result);
                        release_header(runtime, item);
                        release_header(runtime, values);
                        return null_mut();
                    };
                    release_header(runtime, step_result);
                    if matches_item {
                        release_header(runtime, values);
                        return clasp_rt_build_variant_header("Some", vec![item]);
                    }
                    release_header(runtime, item);
                }
                release_header(runtime, values);
                clasp_rt_build_variant_header("None", Vec::new())
            };
            result
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ListAny(callee, values_expr)) => {
            let values = interpret_native_expr(runtime, image, values_expr, env, depth + 1);
            if values.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(values) } {
                return values;
            }
            let result = unsafe {
                let Some(iterable_items) = list_like_borrowed_values(values) else {
                    release_header(runtime, values);
                    return null_mut();
                };
                for item in iterable_items {
                    let step_result = interpret_native_decl(runtime, image, callee.as_str(), &[item], depth + 1);
                    if step_result.is_null() {
                        release_header(runtime, values);
                        return null_mut();
                    }
                    let Some(matches_item) = header_bool_value(step_result) else {
                        release_header(runtime, step_result);
                        release_header(runtime, values);
                        return null_mut();
                    };
                    release_header(runtime, step_result);
                    if matches_item {
                        release_header(runtime, values);
                        return build_runtime_bool(true) as *mut ClaspRtHeader;
                    }
                }
                release_header(runtime, values);
                build_runtime_bool(false) as *mut ClaspRtHeader
            };
            result
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ListAll(callee, values_expr)) => {
            let values = interpret_native_expr(runtime, image, values_expr, env, depth + 1);
            if values.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(values) } {
                return values;
            }
            let result = unsafe {
                let Some(iterable_items) = list_like_borrowed_values(values) else {
                    release_header(runtime, values);
                    return null_mut();
                };
                for item in iterable_items {
                    let step_result = interpret_native_decl(runtime, image, callee.as_str(), &[item], depth + 1);
                    if step_result.is_null() {
                        release_header(runtime, values);
                        return null_mut();
                    }
                    let Some(matches_item) = header_bool_value(step_result) else {
                        release_header(runtime, step_result);
                        release_header(runtime, values);
                        return null_mut();
                    };
                    release_header(runtime, step_result);
                    if !matches_item {
                        release_header(runtime, values);
                        return build_runtime_bool(false) as *mut ClaspRtHeader;
                    }
                }
                release_header(runtime, values);
                build_runtime_bool(true) as *mut ClaspRtHeader
            };
            result
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ListFold(
            callee,
            initial_expr,
            values_expr,
        )) => {
            let initial_value = interpret_native_expr(runtime, image, initial_expr, env, depth + 1);
            if initial_value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(initial_value) } {
                return initial_value;
            }
            let values = interpret_native_expr(runtime, image, values_expr, env, depth + 1);
            if values.is_null() {
                unsafe {
                    release_header(runtime, initial_value);
                }
                return null_mut();
            }
            if unsafe { is_early_return_value(values) } {
                unsafe {
                    release_header(runtime, initial_value);
                }
                return values;
            }
            let result = unsafe {
                let iterable_items: Vec<*mut ClaspRtHeader> = if (*values).layout_id == CLASP_RT_LAYOUT_STRING_LIST {
                    string_list_items_mut(values as *mut ClaspRtStringList)
                        .iter()
                        .map(|item| *item as *mut ClaspRtHeader)
                        .collect()
                } else if (*values).layout_id == CLASP_RT_LAYOUT_LIST_VALUE {
                    list_value_items(values as *mut ClaspRtListValue).iter().copied().collect()
                } else {
                    release_header(runtime, initial_value);
                    release_header(runtime, values);
                    return null_mut();
                };
                let mut accumulator = initial_value;
                for item in iterable_items {
                    let step_result =
                        interpret_native_decl(runtime, image, callee.as_str(), &[accumulator, item], depth + 1);
                    if step_result.is_null() {
                        release_header(runtime, accumulator);
                        release_header(runtime, values);
                        return null_mut();
                    }
                    release_header(runtime, accumulator);
                    accumulator = step_result;
                }
                release_header(runtime, values);
                accumulator
            };
            result
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::ViewAppend(left, right)) => {
            let left_value = interpret_native_expr(runtime, image, left, env, depth + 1);
            if left_value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(left_value) } {
                return left_value;
            }
            let right_value = interpret_native_expr(runtime, image, right, env, depth + 1);
            if right_value.is_null() {
                unsafe {
                    release_header(runtime, left_value);
                }
                return null_mut();
            }
            if unsafe { is_early_return_value(right_value) } {
                unsafe {
                    release_header(runtime, left_value);
                }
                return right_value;
            }
            let appended = unsafe { clasp_rt_view_append(left_value, right_value) };
            unsafe {
                release_header(runtime, left_value);
                release_header(runtime, right_value);
            }
            appended
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::Encode(value_expr)) => {
            let value = interpret_native_expr(runtime, image, value_expr, env, depth + 1);
            if value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(value) } {
                return value;
            }
            let encoded = unsafe { encode_runtime_value_json(value) };
            unsafe {
                release_header(runtime, value);
            }
            match encoded {
                Some(bytes) => unsafe { build_runtime_string(&bytes) as *mut ClaspRtHeader },
                None => null_mut(),
            }
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::Decode(typ, value_expr)) => {
            let value = interpret_native_expr(runtime, image, value_expr, env, depth + 1);
            if value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(value) } {
                return value;
            }
            if unsafe { (*value).layout_id != CLASP_RT_LAYOUT_STRING } {
                unsafe {
                    release_header(runtime, value);
                }
                return null_mut();
            }
            let decoded = unsafe {
                let json_bytes = string_bytes(value as *mut ClaspRtString);
                let decoded_value = match json_root_value(json_bytes) {
                    Some(value_slice) => decode_json_to_runtime_value(&*image, typ, json_bytes, value_slice, None),
                    None => Err(ClaspRtDecodeError::new("value must be valid JSON")),
                };
                release_header(runtime, value);
                decoded_value
            };
            match decoded {
                Ok(decoded_value) => decoded_value,
                Err(error) => {
                    set_native_route_error(format!("model_boundary:{}", error.message));
                    null_mut()
                }
            }
        }
        ClaspRtInterpretedExpr::Intrinsic(ClaspRtInterpretedIntrinsic::TryDecode(typ, value_expr)) => {
            let value = interpret_native_expr(runtime, image, value_expr, env, depth + 1);
            if value.is_null() {
                return null_mut();
            }
            if unsafe { is_early_return_value(value) } {
                return value;
            }
            if unsafe { (*value).layout_id != CLASP_RT_LAYOUT_STRING } {
                unsafe {
                    release_header(runtime, value);
                    return runtime_result_err("tryDecode expects Str");
                }
            }
            let decoded = unsafe {
                let json_bytes = string_bytes(value as *mut ClaspRtString);
                let decoded_value = match json_root_value(json_bytes) {
                    Some(value_slice) => decode_json_to_runtime_value(&*image, typ, json_bytes, value_slice, None),
                    None => Err(ClaspRtDecodeError::new("value must be valid JSON")),
                };
                release_header(runtime, value);
                decoded_value
            };
            match decoded {
                Ok(decoded_value) => unsafe { runtime_result_ok(decoded_value) },
                Err(error) => unsafe { runtime_result_err(&error.message) },
            }
        }
    }
}

fn interpret_runtime_binding(
    binding: &ClaspRtNativeRuntimeBinding,
    args: &[*mut ClaspRtHeader],
) -> *mut ClaspRtHeader {
    match (binding.runtime_name.as_str(), args.len()) {
        ("textConcat", 1) => unsafe {
            list_like_string_items(args[0])
                .map(|parts| build_runtime_string(&join_string_bytes(&parts, &[])) as *mut ClaspRtHeader)
                .unwrap_or(null_mut())
        },
        ("textJoin", 2) => unsafe {
            list_like_string_items(args[1])
                .map(|parts| build_runtime_string(&join_string_bytes(&parts, string_bytes(args[0] as *mut ClaspRtString))) as *mut ClaspRtHeader)
                .unwrap_or(null_mut())
        },
        ("textSplit", 2) => unsafe { clasp_rt_text_split(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("textContains", 2) => unsafe {
            build_runtime_bool(clasp_rt_text_contains(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString)) as *mut ClaspRtHeader
        },
        ("textChars", 1) => unsafe { clasp_rt_text_chars(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("textFingerprint64Hex", 1) => unsafe { clasp_rt_text_fingerprint64_hex(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("intAdd", 2) => unsafe { clasp_rt_int_add(args[0], args[1]) },
        ("intSubtract", 2) => unsafe { clasp_rt_int_subtract(args[0], args[1]) },
        ("not", 1) => unsafe {
            header_bool_value(args[0])
                .map(|value| build_runtime_bool(!value) as *mut ClaspRtHeader)
                .unwrap_or(null_mut())
        },
        ("textPrefix", 2) => unsafe { clasp_rt_text_prefix(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("textSplitFirst", 2) => unsafe { clasp_rt_text_split_first(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("dictEmpty", 0) => unsafe { clasp_rt_dict_empty() },
        ("dictSet", 3) => unsafe { clasp_rt_dict_set(args[0] as *mut ClaspRtString, args[1], args[2]) },
        ("dictGet", 2) => unsafe { clasp_rt_dict_get(args[0] as *mut ClaspRtString, args[1]) },
        ("dictHas", 2) => unsafe { clasp_rt_dict_has(args[0] as *mut ClaspRtString, args[1]) },
        ("dictRemove", 2) => unsafe { clasp_rt_dict_remove(args[0] as *mut ClaspRtString, args[1]) },
        ("dictKeys", 1) => unsafe { clasp_rt_dict_keys(args[0]) },
        ("dictValues", 1) => unsafe { clasp_rt_dict_values(args[0]) },
        ("viewText", 1) => unsafe { clasp_rt_view_text(args[0] as *mut ClaspRtString) },
        ("viewElement", 2) => unsafe { clasp_rt_view_element(args[0] as *mut ClaspRtString, args[1]) },
        ("viewStyled", 2) => unsafe { clasp_rt_view_styled(args[0] as *mut ClaspRtString, args[1]) },
        ("viewLink", 2) => unsafe { clasp_rt_view_link(args[0] as *mut ClaspRtString, args[1]) },
        ("viewForm", 3) => unsafe { clasp_rt_view_form(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2]) },
        ("viewInput", 3) => unsafe { clasp_rt_view_input(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) },
        ("viewSubmit", 1) => unsafe { clasp_rt_view_submit(args[0] as *mut ClaspRtString) },
        ("systemPrompt", 1) => unsafe { clasp_rt_system_prompt(args[0] as *mut ClaspRtString) },
        ("assistantPrompt", 1) => unsafe { clasp_rt_assistant_prompt(args[0] as *mut ClaspRtString) },
        ("userPrompt", 1) => unsafe { clasp_rt_user_prompt(args[0] as *mut ClaspRtString) },
        ("appendPrompt", 2) => unsafe { clasp_rt_append_prompt(args[0], args[1]) },
        ("promptText", 1) => unsafe { clasp_rt_prompt_text(args[0]) as *mut ClaspRtHeader },
        ("page", 2) => unsafe { clasp_rt_page(args[0] as *mut ClaspRtString, args[1]) },
        ("redirect", 1) => unsafe { clasp_rt_redirect(args[0] as *mut ClaspRtString) },
        ("principal", 1) => unsafe { clasp_rt_principal(args[0] as *mut ClaspRtString) },
        ("tenant", 1) => unsafe { clasp_rt_tenant(args[0] as *mut ClaspRtString) },
        ("resourceIdentity", 2) => unsafe {
            clasp_rt_resource_identity(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString)
        },
        ("authSession", 4) => unsafe {
            clasp_rt_auth_session(
                args[0] as *mut ClaspRtString,
                args[1],
                args[2],
                args[3],
            )
        },
        ("argv", 0) => unsafe { clasp_rt_argv() as *mut ClaspRtHeader },
        ("timeUnixMs", 0) => unsafe { clasp_rt_time_unix_ms() },
        ("envVar", 1) => unsafe { clasp_rt_env_var(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("currentWorkingDirectory", 0) => unsafe {
            clasp_rt_current_working_directory() as *mut ClaspRtHeader
        },
        ("pathJoin", 1) => unsafe {
            list_like_string_items(args[0])
                .map(|parts| build_runtime_string(&join_string_bytes(&parts, b"/")) as *mut ClaspRtHeader)
                .unwrap_or(null_mut())
        },
        ("pathBasename", 1) => unsafe { clasp_rt_path_basename(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("pathDirname", 1) => unsafe { clasp_rt_path_dirname(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("fileExists", 1) => unsafe { build_runtime_bool(clasp_rt_file_exists(args[0] as *mut ClaspRtString)) as *mut ClaspRtHeader },
        ("listDir", 1) => unsafe { clasp_rt_list_dir(args[0] as *mut ClaspRtString) },
        ("hostAvailableDiskMb", 1) => unsafe { clasp_rt_host_available_disk_mb(args[0] as *mut ClaspRtString) },
        ("hostFileSizeMb", 1) => unsafe { clasp_rt_host_file_size_mb(args[0] as *mut ClaspRtString) },
        ("hostCapFileTailMb", 2) => unsafe { clasp_rt_host_cap_file_tail_mb(args[0] as *mut ClaspRtString, args[1]) },
        ("hostAvailableMemoryMb", 0) => unsafe { clasp_rt_host_available_memory_mb() },
        ("hostProcessAlive", 1) => unsafe { clasp_rt_host_process_alive(args[0] as *mut ClaspRtString) },
        ("hostProcessCountByName", 1) => unsafe { clasp_rt_host_process_count_by_name(args[0] as *mut ClaspRtStringList) },
        ("hostUnmanagedProcessCountByName", 1) => unsafe { clasp_rt_host_unmanaged_process_count_by_name(args[0] as *mut ClaspRtStringList) },
        ("hostUnmanagedProcessRssMbByName", 1) => unsafe { clasp_rt_host_unmanaged_process_rss_mb_by_name(args[0] as *mut ClaspRtStringList) },
        ("workspacePath", 2) => unsafe { clasp_rt_workspace_path(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("workspaceReadFile", 2) => unsafe { clasp_rt_workspace_read_file(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("workspaceWriteFile", 3) => unsafe { clasp_rt_workspace_write_file(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("workspaceAppendFile", 3) => unsafe { clasp_rt_workspace_append_file(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("workspaceMkdirAll", 2) => unsafe { clasp_rt_workspace_mkdir_all(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("workspaceListDir", 2) => unsafe { clasp_rt_workspace_list_dir(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) },
        ("workspaceListTree", 4) => unsafe { clasp_rt_workspace_list_tree(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2], args[3]) },
        ("workspaceSearchText", 7) => unsafe { clasp_rt_workspace_search_text(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5], args[6]) },
        ("workspaceReplaceText", 6) => unsafe { clasp_rt_workspace_replace_text(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5]) },
        ("workspacePathSizeMb", 2) => unsafe { clasp_rt_workspace_path_size_mb(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) },
        ("workspaceRemovePath", 2) => unsafe { clasp_rt_workspace_remove_path(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmBootstrapJson", 3) => unsafe { clasp_rt_swarm_bootstrap_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmStartJson", 3) => unsafe { clasp_rt_swarm_start_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmLeaseJson", 3) => unsafe { clasp_rt_swarm_lease_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmReleaseJson", 3) => unsafe { clasp_rt_swarm_release_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmHeartbeatJson", 3) => unsafe { clasp_rt_swarm_heartbeat_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmCompleteJson", 3) => unsafe { clasp_rt_swarm_complete_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmFailJson", 3) => unsafe { clasp_rt_swarm_fail_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmRetryJson", 3) => unsafe { clasp_rt_swarm_retry_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmStopJson", 3) => unsafe { clasp_rt_swarm_stop_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmResumeJson", 3) => unsafe { clasp_rt_swarm_resume_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmStatusJson", 2) => unsafe { clasp_rt_swarm_status_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmHistoryJson", 2) => unsafe { clasp_rt_swarm_history_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmTasksJson", 1) => unsafe { clasp_rt_swarm_tasks_json(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmSummaryJson", 1) => unsafe { clasp_rt_swarm_summary_json(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmTailJson", 3) => unsafe {
            clasp_rt_swarm_tail_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as i64,
            ) as *mut ClaspRtHeader
        },
        ("swarmReadyJson", 2) => unsafe { clasp_rt_swarm_ready_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmManagerNextJson", 2) => unsafe { clasp_rt_swarm_manager_next_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmObjectiveCreateJson", 5) => unsafe { clasp_rt_swarm_objective_create_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4]) as *mut ClaspRtHeader },
        ("swarmObjectiveCreateWithDeadlineJson", 6) => unsafe { clasp_rt_swarm_objective_create_with_deadline_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5]) as *mut ClaspRtHeader },
        ("swarmObjectiveStatusJson", 2) => unsafe { clasp_rt_swarm_objective_status_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmObjectivesJson", 1) => unsafe { clasp_rt_swarm_objectives_json(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmTaskCreateJson", 7) => unsafe { clasp_rt_swarm_task_create_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5], args[6]) as *mut ClaspRtHeader },
        ("swarmTaskCreateWithDeadlineJson", 8) => unsafe { clasp_rt_swarm_task_create_with_deadline_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5], args[6], args[7]) as *mut ClaspRtHeader },
        ("swarmTaskCreateWithDeadlineAndPriorityJson", 9) => unsafe { clasp_rt_swarm_task_create_with_deadline_and_priority_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5], args[6], args[7], args[8]) as *mut ClaspRtHeader },
        ("swarmTaskCreateChildWithDeadlineAndPriorityJson", 11) => unsafe { clasp_rt_swarm_task_create_child_with_deadline_and_priority_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5], args[6], args[7], args[8], args[9], args[10]) as *mut ClaspRtHeader },
        ("swarmTaskCreateChildWithPolicyJson", 12) => unsafe { clasp_rt_swarm_task_create_child_with_policy_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5], args[6], args[7], args[8], args[9], args[10], args[11]) as *mut ClaspRtHeader },
        ("swarmTaskReprioritizeJson", 4) => unsafe { clasp_rt_swarm_task_reprioritize_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3]) as *mut ClaspRtHeader },
        ("swarmPolicySetJson", 5) => unsafe { clasp_rt_swarm_policy_set_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4]) as *mut ClaspRtHeader },
        ("swarmPolicySetWithProcessAccessJson", 6) => unsafe { clasp_rt_swarm_policy_set_with_process_access_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5]) as *mut ClaspRtHeader },
        ("swarmPolicySetWithAccessJson", 7) => unsafe { clasp_rt_swarm_policy_set_with_access_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5], args[6]) as *mut ClaspRtHeader },
        ("swarmPolicySetWithCapabilitiesJson", 8) => unsafe { clasp_rt_swarm_policy_set_with_capabilities_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5], args[6], args[7] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmPolicySetWithNetworkAccessJson", 9) => unsafe { clasp_rt_swarm_policy_set_with_network_access_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5], args[6], args[7] as *mut ClaspRtString, args[8]) as *mut ClaspRtHeader },
        ("swarmPolicySetWithFilesystemAccessJson", 10) => unsafe { clasp_rt_swarm_policy_set_with_filesystem_access_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5], args[6], args[7], args[8] as *mut ClaspRtString, args[9]) as *mut ClaspRtHeader },
        ("swarmToolRunJson", 5) => unsafe { clasp_rt_swarm_tool_run_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4]) as *mut ClaspRtHeader },
        ("swarmToolRunWithTimeoutJson", 6) => unsafe { clasp_rt_swarm_tool_run_with_timeout_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5]) as *mut ClaspRtHeader },
        ("swarmToolRunWithLimitsJson", 7) => unsafe { clasp_rt_swarm_tool_run_with_limits_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5], args[6]) as *mut ClaspRtHeader },
        ("swarmVerifierRunJson", 6) => unsafe { clasp_rt_swarm_verifier_run_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5]) as *mut ClaspRtHeader },
        ("swarmVerifierRunWithTimeoutJson", 7) => unsafe { clasp_rt_swarm_verifier_run_with_timeout_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5], args[6]) as *mut ClaspRtHeader },
        ("swarmVerifierRunWithLimitsJson", 8) => unsafe { clasp_rt_swarm_verifier_run_with_limits_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5], args[6], args[7]) as *mut ClaspRtHeader },
        ("swarmApproveJson", 4) => unsafe { clasp_rt_swarm_approve_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmApprovalsJson", 2) => unsafe { clasp_rt_swarm_approvals_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmMergegateDecideJson", 5) => unsafe { clasp_rt_swarm_mergegate_decide_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4]) as *mut ClaspRtHeader },
        ("swarmRunsJson", 2) => unsafe { clasp_rt_swarm_runs_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmArtifactsJson", 2) => unsafe { clasp_rt_swarm_artifacts_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmArtifactReadJson", 3) => unsafe { clasp_rt_swarm_artifact_read_json(args[0] as *mut ClaspRtString, args[1], args[2]) as *mut ClaspRtHeader },
        ("swarmArtifactSearchJson", 6) => unsafe { clasp_rt_swarm_artifact_search_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5]) as *mut ClaspRtHeader },
        ("swarmArtifactWriteJson", 5) => unsafe { clasp_rt_swarm_artifact_write_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmMemoryPutJson", 6) => unsafe { clasp_rt_swarm_memory_put_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmMemoryQueryJson", 5) => unsafe { clasp_rt_swarm_memory_query_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as i64) as *mut ClaspRtHeader },
        ("swarmMemorySearchJson", 5) => unsafe { clasp_rt_swarm_memory_search_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as i64) as *mut ClaspRtHeader },
        ("runCommandJson", 2) => unsafe { clasp_rt_run_command_json(args[0] as *mut ClaspRtString, args[1]) as *mut ClaspRtHeader },
        ("runCommandTimeoutJson", 3) => unsafe {
            clasp_rt_run_command_timeout_json(args[0] as *mut ClaspRtString, args[1], args[2])
                as *mut ClaspRtHeader
        },
        ("runProcessJson", 3) => unsafe {
            clasp_rt_run_process_json(args[0] as *mut ClaspRtString, args[1], args[2])
                as *mut ClaspRtHeader
        },
        ("runProcessTimeoutJson", 4) => unsafe {
            clasp_rt_run_process_timeout_json(args[0] as *mut ClaspRtString, args[1], args[2], args[3])
                as *mut ClaspRtHeader
        },
        ("runWorkspaceCommandTimeoutJson", 4) => unsafe {
            clasp_rt_run_workspace_command_timeout_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2],
                args[3],
            ) as *mut ClaspRtHeader
        },
        ("spawnCommandJson", 6) => unsafe {
            clasp_rt_spawn_command_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4],
                args[5],
            ) as *mut ClaspRtHeader
        },
        ("spawnCommandWithLimitsJson", 7) => unsafe {
            clasp_rt_spawn_command_with_limits_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4],
                args[5],
                args[6],
            ) as *mut ClaspRtHeader
        },
        ("watchCommandJson", 6) => unsafe {
            clasp_rt_watch_command_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4],
                args[5],
            ) as *mut ClaspRtHeader
        },
        ("watchCommandWithLimitsJson", 7) => unsafe {
            clasp_rt_watch_command_with_limits_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4],
                args[5],
                args[6],
            ) as *mut ClaspRtHeader
        },
        ("reconcileWatchedProcessJson", 1) => unsafe {
            clasp_rt_reconcile_watched_process_json(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader
        },
        ("cancelWatchedProcessJson", 1) => unsafe {
            clasp_rt_cancel_watched_process_json(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader
        },
        ("awaitWatchedProcessJson", 2) => unsafe {
            clasp_rt_await_watched_process_json(args[0] as *mut ClaspRtString, args[1]) as *mut ClaspRtHeader
        },
        ("awaitWatchedProcessTimeoutJson", 3) => unsafe {
            clasp_rt_await_watched_process_timeout_json(
                args[0] as *mut ClaspRtString,
                args[1],
                args[2],
            ) as *mut ClaspRtHeader
        },
        ("handoffCommandJson", 10) => unsafe {
            clasp_rt_handoff_command_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4],
                args[5] as *mut ClaspRtString,
                args[6] as *mut ClaspRtString,
                args[7],
                args[8],
                args[9],
            ) as *mut ClaspRtHeader
        },
        ("upgradeCommandJson", 11) => unsafe {
            clasp_rt_upgrade_command_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4] as *mut ClaspRtString,
                args[5] as *mut ClaspRtString,
                args[6],
                args[7],
                args[8],
                args[9],
                args[10],
            ) as *mut ClaspRtHeader
        },
        ("superviseCommandJson", 10) => unsafe {
            clasp_rt_supervise_command_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4] as *mut ClaspRtString,
                args[5],
                args[6],
                args[7],
                args[8],
                args[9],
            ) as *mut ClaspRtHeader
        },
        ("sleepMs", 1) => unsafe { clasp_rt_sleep_ms(args[0]) as *mut ClaspRtHeader },
        ("writeFile", 2) => unsafe { clasp_rt_write_file(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("appendFile", 2) => unsafe { clasp_rt_append_file(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("mkdirAll", 1) => unsafe { clasp_rt_mkdir_all(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("readFile", 1) => unsafe { clasp_rt_read_file(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("documentUploadBoundary", 1) => unsafe { interpret_document_upload_boundary(args[0]) },
        ("documentReferenceBoundary", 1) => unsafe { interpret_document_reference_boundary(args[0]) },
        ("mockLeadSummaryModel", 1) => unsafe { interpret_mock_lead_summary_model_binding(args[0]) },
        ("mockLeadOutreachModel", 1) => unsafe { interpret_mock_lead_outreach_model_binding(args[0]) },
        ("storeLead", 2) => unsafe { interpret_store_lead_binding(args[0], args[1]) },
        ("loadInbox", 1) => unsafe { interpret_load_inbox_binding() },
        ("loadPrimaryLead", 1) => unsafe { interpret_load_primary_lead_binding() },
        ("loadSecondaryLead", 1) => unsafe { interpret_load_secondary_lead_binding() },
        ("reviewLead", 1) => unsafe { interpret_review_lead_binding(args[0]) },
        (runtime_name, 1) if runtime_name.starts_with("storage:") => unsafe {
            clasp_rt_retain(args[0]);
            args[0]
        },
        ("provider:reviewRelease", 1) => unsafe { interpret_review_release_binding(args[0]) },
        ("provider:replyPreview", 1) => unsafe { interpret_reply_preview_binding(binding, args[0]) },
        _ => null_mut(),
    }
}

fn interpret_builtin_runtime_binding(
    name: &str,
    args: &[*mut ClaspRtHeader],
) -> *mut ClaspRtHeader {
    match (name, args.len()) {
        ("textConcat", 1) => unsafe {
            list_like_string_items(args[0])
                .map(|parts| build_runtime_string(&join_string_bytes(&parts, &[])) as *mut ClaspRtHeader)
                .unwrap_or(null_mut())
        },
        ("textJoin", 2) => unsafe {
            list_like_string_items(args[1])
                .map(|parts| build_runtime_string(&join_string_bytes(&parts, string_bytes(args[0] as *mut ClaspRtString))) as *mut ClaspRtHeader)
                .unwrap_or(null_mut())
        },
        ("textSplit", 2) => unsafe { clasp_rt_text_split(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("textContains", 2) => unsafe {
            build_runtime_bool(clasp_rt_text_contains(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString)) as *mut ClaspRtHeader
        },
        ("textChars", 1) => unsafe { clasp_rt_text_chars(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("textFingerprint64Hex", 1) => unsafe { clasp_rt_text_fingerprint64_hex(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("intAdd", 2) => unsafe { clasp_rt_int_add(args[0], args[1]) },
        ("intSubtract", 2) => unsafe { clasp_rt_int_subtract(args[0], args[1]) },
        ("not", 1) => unsafe {
            header_bool_value(args[0])
                .map(|value| build_runtime_bool(!value) as *mut ClaspRtHeader)
                .unwrap_or(null_mut())
        },
        ("textPrefix", 2) => unsafe { clasp_rt_text_prefix(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("textSplitFirst", 2) => unsafe { clasp_rt_text_split_first(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("dictEmpty", 0) => unsafe { clasp_rt_dict_empty() },
        ("dictSet", 3) => unsafe { clasp_rt_dict_set(args[0] as *mut ClaspRtString, args[1], args[2]) },
        ("dictGet", 2) => unsafe { clasp_rt_dict_get(args[0] as *mut ClaspRtString, args[1]) },
        ("dictHas", 2) => unsafe { clasp_rt_dict_has(args[0] as *mut ClaspRtString, args[1]) },
        ("dictRemove", 2) => unsafe { clasp_rt_dict_remove(args[0] as *mut ClaspRtString, args[1]) },
        ("dictKeys", 1) => unsafe { clasp_rt_dict_keys(args[0]) },
        ("dictValues", 1) => unsafe { clasp_rt_dict_values(args[0]) },
        ("viewText" | "text", 1) => unsafe { clasp_rt_view_text(args[0] as *mut ClaspRtString) },
        ("viewElement" | "element", 2) => unsafe { clasp_rt_view_element(args[0] as *mut ClaspRtString, args[1]) },
        ("viewStyled" | "styled", 2) => unsafe { clasp_rt_view_styled(args[0] as *mut ClaspRtString, args[1]) },
        ("viewLink" | "link", 2) => unsafe { clasp_rt_view_link(args[0] as *mut ClaspRtString, args[1]) },
        ("viewForm" | "form", 3) => unsafe { clasp_rt_view_form(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2]) },
        ("viewInput" | "input", 3) => unsafe { clasp_rt_view_input(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) },
        ("viewSubmit" | "submit", 1) => unsafe { clasp_rt_view_submit(args[0] as *mut ClaspRtString) },
        ("systemPrompt", 1) => unsafe { clasp_rt_system_prompt(args[0] as *mut ClaspRtString) },
        ("assistantPrompt", 1) => unsafe { clasp_rt_assistant_prompt(args[0] as *mut ClaspRtString) },
        ("userPrompt", 1) => unsafe { clasp_rt_user_prompt(args[0] as *mut ClaspRtString) },
        ("appendPrompt", 2) => unsafe { clasp_rt_append_prompt(args[0], args[1]) },
        ("promptText", 1) => unsafe { clasp_rt_prompt_text(args[0]) as *mut ClaspRtHeader },
        ("page", 2) => unsafe { clasp_rt_page(args[0] as *mut ClaspRtString, args[1]) },
        ("redirect", 1) => unsafe { clasp_rt_redirect(args[0] as *mut ClaspRtString) },
        ("principal", 1) => unsafe { clasp_rt_principal(args[0] as *mut ClaspRtString) },
        ("tenant", 1) => unsafe { clasp_rt_tenant(args[0] as *mut ClaspRtString) },
        ("resourceIdentity", 2) => unsafe {
            clasp_rt_resource_identity(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString)
        },
        ("authSession", 4) => unsafe {
            clasp_rt_auth_session(args[0] as *mut ClaspRtString, args[1], args[2], args[3])
        },
        ("argv", 0) => unsafe { clasp_rt_argv() as *mut ClaspRtHeader },
        ("timeUnixMs", 0) => unsafe { clasp_rt_time_unix_ms() },
        ("envVar", 1) => unsafe { clasp_rt_env_var(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("currentWorkingDirectory", 0) => unsafe {
            clasp_rt_current_working_directory() as *mut ClaspRtHeader
        },
        ("pathJoin", 1) => unsafe { clasp_rt_path_join(args[0] as *mut ClaspRtStringList) as *mut ClaspRtHeader },
        ("pathBasename", 1) => unsafe { clasp_rt_path_basename(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("pathDirname", 1) => unsafe { clasp_rt_path_dirname(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("fileExists", 1) => unsafe { build_runtime_bool(clasp_rt_file_exists(args[0] as *mut ClaspRtString)) as *mut ClaspRtHeader },
        ("listDir", 1) => unsafe { clasp_rt_list_dir(args[0] as *mut ClaspRtString) },
        ("hostAvailableDiskMb", 1) => unsafe { clasp_rt_host_available_disk_mb(args[0] as *mut ClaspRtString) },
        ("hostFileSizeMb", 1) => unsafe { clasp_rt_host_file_size_mb(args[0] as *mut ClaspRtString) },
        ("hostCapFileTailMb", 2) => unsafe { clasp_rt_host_cap_file_tail_mb(args[0] as *mut ClaspRtString, args[1]) },
        ("hostAvailableMemoryMb", 0) => unsafe { clasp_rt_host_available_memory_mb() },
        ("hostProcessAlive", 1) => unsafe { clasp_rt_host_process_alive(args[0] as *mut ClaspRtString) },
        ("hostProcessCountByName", 1) => unsafe { clasp_rt_host_process_count_by_name(args[0] as *mut ClaspRtStringList) },
        ("hostUnmanagedProcessCountByName", 1) => unsafe { clasp_rt_host_unmanaged_process_count_by_name(args[0] as *mut ClaspRtStringList) },
        ("hostUnmanagedProcessRssMbByName", 1) => unsafe { clasp_rt_host_unmanaged_process_rss_mb_by_name(args[0] as *mut ClaspRtStringList) },
        ("workspacePath", 2) => unsafe { clasp_rt_workspace_path(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("workspaceReadFile", 2) => unsafe { clasp_rt_workspace_read_file(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("workspaceWriteFile", 3) => unsafe { clasp_rt_workspace_write_file(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("workspaceAppendFile", 3) => unsafe { clasp_rt_workspace_append_file(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("workspaceMkdirAll", 2) => unsafe { clasp_rt_workspace_mkdir_all(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("workspaceListDir", 2) => unsafe { clasp_rt_workspace_list_dir(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) },
        ("workspaceListTree", 4) => unsafe { clasp_rt_workspace_list_tree(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2], args[3]) },
        ("workspaceSearchText", 7) => unsafe { clasp_rt_workspace_search_text(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5], args[6]) },
        ("workspaceReplaceText", 6) => unsafe { clasp_rt_workspace_replace_text(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5]) },
        ("workspacePathSizeMb", 2) => unsafe { clasp_rt_workspace_path_size_mb(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) },
        ("workspaceRemovePath", 2) => unsafe { clasp_rt_workspace_remove_path(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmBootstrapJson", 3) => unsafe { clasp_rt_swarm_bootstrap_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmStartJson", 3) => unsafe { clasp_rt_swarm_start_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmLeaseJson", 3) => unsafe { clasp_rt_swarm_lease_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmReleaseJson", 3) => unsafe { clasp_rt_swarm_release_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmHeartbeatJson", 3) => unsafe { clasp_rt_swarm_heartbeat_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmCompleteJson", 3) => unsafe { clasp_rt_swarm_complete_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmFailJson", 3) => unsafe { clasp_rt_swarm_fail_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmRetryJson", 3) => unsafe { clasp_rt_swarm_retry_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmStopJson", 3) => unsafe { clasp_rt_swarm_stop_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmResumeJson", 3) => unsafe { clasp_rt_swarm_resume_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmStatusJson", 2) => unsafe { clasp_rt_swarm_status_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmHistoryJson", 2) => unsafe { clasp_rt_swarm_history_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmTasksJson", 1) => unsafe { clasp_rt_swarm_tasks_json(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmSummaryJson", 1) => unsafe { clasp_rt_swarm_summary_json(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmTailJson", 3) => unsafe {
            clasp_rt_swarm_tail_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as i64,
            ) as *mut ClaspRtHeader
        },
        ("swarmReadyJson", 2) => unsafe { clasp_rt_swarm_ready_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmManagerNextJson", 2) => unsafe { clasp_rt_swarm_manager_next_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmObjectiveCreateJson", 5) => unsafe { clasp_rt_swarm_objective_create_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4]) as *mut ClaspRtHeader },
        ("swarmObjectiveCreateWithDeadlineJson", 6) => unsafe { clasp_rt_swarm_objective_create_with_deadline_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5]) as *mut ClaspRtHeader },
        ("swarmObjectiveStatusJson", 2) => unsafe { clasp_rt_swarm_objective_status_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmObjectivesJson", 1) => unsafe { clasp_rt_swarm_objectives_json(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmTaskCreateJson", 7) => unsafe { clasp_rt_swarm_task_create_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5], args[6]) as *mut ClaspRtHeader },
        ("swarmTaskCreateWithDeadlineJson", 8) => unsafe { clasp_rt_swarm_task_create_with_deadline_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5], args[6], args[7]) as *mut ClaspRtHeader },
        ("swarmTaskCreateWithDeadlineAndPriorityJson", 9) => unsafe { clasp_rt_swarm_task_create_with_deadline_and_priority_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5], args[6], args[7], args[8]) as *mut ClaspRtHeader },
        ("swarmTaskCreateChildWithDeadlineAndPriorityJson", 11) => unsafe { clasp_rt_swarm_task_create_child_with_deadline_and_priority_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5], args[6], args[7], args[8], args[9], args[10]) as *mut ClaspRtHeader },
        ("swarmTaskCreateChildWithPolicyJson", 12) => unsafe { clasp_rt_swarm_task_create_child_with_policy_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5], args[6], args[7], args[8], args[9], args[10], args[11]) as *mut ClaspRtHeader },
        ("swarmTaskReprioritizeJson", 4) => unsafe { clasp_rt_swarm_task_reprioritize_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3]) as *mut ClaspRtHeader },
        ("swarmPolicySetJson", 5) => unsafe { clasp_rt_swarm_policy_set_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4]) as *mut ClaspRtHeader },
        ("swarmPolicySetWithProcessAccessJson", 6) => unsafe { clasp_rt_swarm_policy_set_with_process_access_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5]) as *mut ClaspRtHeader },
        ("swarmPolicySetWithAccessJson", 7) => unsafe { clasp_rt_swarm_policy_set_with_access_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5], args[6]) as *mut ClaspRtHeader },
        ("swarmPolicySetWithCapabilitiesJson", 8) => unsafe { clasp_rt_swarm_policy_set_with_capabilities_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5], args[6], args[7] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmPolicySetWithNetworkAccessJson", 9) => unsafe { clasp_rt_swarm_policy_set_with_network_access_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5], args[6], args[7] as *mut ClaspRtString, args[8]) as *mut ClaspRtHeader },
        ("swarmPolicySetWithFilesystemAccessJson", 10) => unsafe { clasp_rt_swarm_policy_set_with_filesystem_access_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3], args[4], args[5], args[6], args[7], args[8] as *mut ClaspRtString, args[9]) as *mut ClaspRtHeader },
        ("swarmToolRunJson", 5) => unsafe { clasp_rt_swarm_tool_run_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4]) as *mut ClaspRtHeader },
        ("swarmToolRunWithTimeoutJson", 6) => unsafe { clasp_rt_swarm_tool_run_with_timeout_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5]) as *mut ClaspRtHeader },
        ("swarmToolRunWithLimitsJson", 7) => unsafe { clasp_rt_swarm_tool_run_with_limits_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5], args[6]) as *mut ClaspRtHeader },
        ("swarmVerifierRunJson", 6) => unsafe { clasp_rt_swarm_verifier_run_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5]) as *mut ClaspRtHeader },
        ("swarmVerifierRunWithTimeoutJson", 7) => unsafe { clasp_rt_swarm_verifier_run_with_timeout_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5], args[6]) as *mut ClaspRtHeader },
        ("swarmVerifierRunWithLimitsJson", 8) => unsafe { clasp_rt_swarm_verifier_run_with_limits_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5], args[6], args[7]) as *mut ClaspRtHeader },
        ("swarmApproveJson", 4) => unsafe { clasp_rt_swarm_approve_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmApprovalsJson", 2) => unsafe { clasp_rt_swarm_approvals_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmMergegateDecideJson", 5) => unsafe { clasp_rt_swarm_mergegate_decide_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4]) as *mut ClaspRtHeader },
        ("swarmRunsJson", 2) => unsafe { clasp_rt_swarm_runs_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmArtifactsJson", 2) => unsafe { clasp_rt_swarm_artifacts_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmArtifactReadJson", 3) => unsafe { clasp_rt_swarm_artifact_read_json(args[0] as *mut ClaspRtString, args[1], args[2]) as *mut ClaspRtHeader },
        ("swarmArtifactSearchJson", 6) => unsafe { clasp_rt_swarm_artifact_search_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4], args[5]) as *mut ClaspRtHeader },
        ("swarmArtifactWriteJson", 5) => unsafe { clasp_rt_swarm_artifact_write_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmMemoryPutJson", 6) => unsafe { clasp_rt_swarm_memory_put_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as *mut ClaspRtString, args[5] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("swarmMemoryQueryJson", 5) => unsafe { clasp_rt_swarm_memory_query_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as i64) as *mut ClaspRtHeader },
        ("swarmMemorySearchJson", 5) => unsafe { clasp_rt_swarm_memory_search_json(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString, args[2] as *mut ClaspRtString, args[3] as *mut ClaspRtString, args[4] as i64) as *mut ClaspRtHeader },
        ("runCommandJson", 2) => unsafe { clasp_rt_run_command_json(args[0] as *mut ClaspRtString, args[1]) as *mut ClaspRtHeader },
        ("runCommandTimeoutJson", 3) => unsafe {
            clasp_rt_run_command_timeout_json(args[0] as *mut ClaspRtString, args[1], args[2])
                as *mut ClaspRtHeader
        },
        ("runProcessJson", 3) => unsafe {
            clasp_rt_run_process_json(args[0] as *mut ClaspRtString, args[1], args[2])
                as *mut ClaspRtHeader
        },
        ("runProcessTimeoutJson", 4) => unsafe {
            clasp_rt_run_process_timeout_json(args[0] as *mut ClaspRtString, args[1], args[2], args[3])
                as *mut ClaspRtHeader
        },
        ("runWorkspaceCommandTimeoutJson", 4) => unsafe {
            clasp_rt_run_workspace_command_timeout_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2],
                args[3],
            ) as *mut ClaspRtHeader
        },
        ("spawnCommandJson", 6) => unsafe {
            clasp_rt_spawn_command_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4],
                args[5],
            ) as *mut ClaspRtHeader
        },
        ("spawnCommandWithLimitsJson", 7) => unsafe {
            clasp_rt_spawn_command_with_limits_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4],
                args[5],
                args[6],
            ) as *mut ClaspRtHeader
        },
        ("watchCommandJson", 6) => unsafe {
            clasp_rt_watch_command_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4],
                args[5],
            ) as *mut ClaspRtHeader
        },
        ("watchCommandWithLimitsJson", 7) => unsafe {
            clasp_rt_watch_command_with_limits_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4],
                args[5],
                args[6],
            ) as *mut ClaspRtHeader
        },
        ("reconcileWatchedProcessJson", 1) => unsafe {
            clasp_rt_reconcile_watched_process_json(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader
        },
        ("cancelWatchedProcessJson", 1) => unsafe {
            clasp_rt_cancel_watched_process_json(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader
        },
        ("awaitWatchedProcessJson", 2) => unsafe {
            clasp_rt_await_watched_process_json(args[0] as *mut ClaspRtString, args[1]) as *mut ClaspRtHeader
        },
        ("awaitWatchedProcessTimeoutJson", 3) => unsafe {
            clasp_rt_await_watched_process_timeout_json(
                args[0] as *mut ClaspRtString,
                args[1],
                args[2],
            ) as *mut ClaspRtHeader
        },
        ("handoffCommandJson", 10) => unsafe {
            clasp_rt_handoff_command_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4],
                args[5] as *mut ClaspRtString,
                args[6] as *mut ClaspRtString,
                args[7],
                args[8],
                args[9],
            ) as *mut ClaspRtHeader
        },
        ("upgradeCommandJson", 11) => unsafe {
            clasp_rt_upgrade_command_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4] as *mut ClaspRtString,
                args[5] as *mut ClaspRtString,
                args[6],
                args[7],
                args[8],
                args[9],
                args[10],
            ) as *mut ClaspRtHeader
        },
        ("superviseCommandJson", 10) => unsafe {
            clasp_rt_supervise_command_json(
                args[0] as *mut ClaspRtString,
                args[1] as *mut ClaspRtString,
                args[2] as *mut ClaspRtString,
                args[3] as *mut ClaspRtString,
                args[4] as *mut ClaspRtString,
                args[5],
                args[6],
                args[7],
                args[8],
                args[9],
            ) as *mut ClaspRtHeader
        },
        ("sleepMs", 1) => unsafe { clasp_rt_sleep_ms(args[0]) as *mut ClaspRtHeader },
        ("writeFile", 2) => unsafe { clasp_rt_write_file(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("appendFile", 2) => unsafe { clasp_rt_append_file(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("mkdirAll", 1) => unsafe { clasp_rt_mkdir_all(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("readFile", 1) => unsafe { clasp_rt_read_file(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        _ => null_mut(),
    }
}

fn builtin_runtime_binding_name(name: &str) -> bool {
    matches!(
        name,
        "textConcat"
            | "textJoin"
            | "textSplit"
            | "textContains"
            | "textChars"
            | "textFingerprint64Hex"
            | "intAdd"
            | "intSubtract"
            | "not"
            | "textPrefix"
            | "textSplitFirst"
            | "dictEmpty"
            | "dictSet"
            | "dictGet"
            | "dictHas"
            | "dictRemove"
            | "dictKeys"
            | "dictValues"
            | "text"
            | "viewText"
            | "element"
            | "viewElement"
            | "styled"
            | "viewStyled"
            | "link"
            | "viewLink"
            | "form"
            | "viewForm"
            | "input"
            | "viewInput"
            | "submit"
            | "viewSubmit"
            | "systemPrompt"
            | "assistantPrompt"
            | "userPrompt"
            | "appendPrompt"
            | "promptText"
            | "page"
            | "redirect"
            | "principal"
            | "tenant"
            | "resourceIdentity"
            | "authSession"
            | "argv"
            | "timeUnixMs"
            | "envVar"
            | "currentWorkingDirectory"
            | "pathJoin"
            | "pathBasename"
            | "pathDirname"
            | "fileExists"
            | "listDir"
            | "hostAvailableDiskMb"
            | "hostFileSizeMb"
            | "hostCapFileTailMb"
            | "hostAvailableMemoryMb"
            | "hostProcessAlive"
            | "hostProcessCountByName"
            | "hostUnmanagedProcessCountByName"
            | "hostUnmanagedProcessRssMbByName"
            | "workspacePath"
            | "workspaceReadFile"
            | "workspaceWriteFile"
            | "workspaceAppendFile"
            | "workspaceMkdirAll"
            | "workspaceListDir"
            | "workspaceListTree"
            | "workspaceSearchText"
            | "workspaceReplaceText"
            | "workspacePathSizeMb"
            | "workspaceRemovePath"
            | "swarmBootstrapJson"
            | "swarmStartJson"
            | "swarmLeaseJson"
            | "swarmReleaseJson"
            | "swarmHeartbeatJson"
            | "swarmCompleteJson"
            | "swarmFailJson"
            | "swarmRetryJson"
            | "swarmStopJson"
            | "swarmResumeJson"
            | "swarmStatusJson"
            | "swarmHistoryJson"
            | "swarmTasksJson"
            | "swarmSummaryJson"
            | "swarmTailJson"
            | "swarmReadyJson"
            | "swarmManagerNextJson"
            | "swarmObjectiveCreateJson"
            | "swarmObjectiveCreateWithDeadlineJson"
            | "swarmObjectiveStatusJson"
            | "swarmObjectivesJson"
            | "swarmTaskCreateJson"
            | "swarmTaskCreateWithDeadlineJson"
            | "swarmTaskCreateWithDeadlineAndPriorityJson"
            | "swarmTaskCreateChildWithDeadlineAndPriorityJson"
            | "swarmTaskCreateChildWithPolicyJson"
            | "swarmTaskReprioritizeJson"
            | "swarmPolicySetJson"
            | "swarmPolicySetWithProcessAccessJson"
            | "swarmPolicySetWithAccessJson"
            | "swarmPolicySetWithCapabilitiesJson"
            | "swarmPolicySetWithNetworkAccessJson"
            | "swarmPolicySetWithFilesystemAccessJson"
            | "swarmToolRunJson"
            | "swarmToolRunWithTimeoutJson"
            | "swarmToolRunWithLimitsJson"
            | "swarmVerifierRunJson"
            | "swarmVerifierRunWithTimeoutJson"
            | "swarmVerifierRunWithLimitsJson"
            | "swarmApproveJson"
            | "swarmApprovalsJson"
            | "swarmMergegateDecideJson"
            | "swarmRunsJson"
            | "swarmArtifactsJson"
            | "swarmArtifactReadJson"
            | "swarmArtifactSearchJson"
            | "swarmArtifactWriteJson"
            | "swarmMemoryPutJson"
            | "swarmMemoryQueryJson"
            | "swarmMemorySearchJson"
            | "runCommandJson"
            | "runCommandTimeoutJson"
            | "runProcessJson"
            | "runProcessTimeoutJson"
            | "runWorkspaceCommandTimeoutJson"
            | "spawnCommandJson"
            | "spawnCommandWithLimitsJson"
            | "watchCommandJson"
            | "watchCommandWithLimitsJson"
            | "reconcileWatchedProcessJson"
            | "cancelWatchedProcessJson"
            | "awaitWatchedProcessJson"
            | "awaitWatchedProcessTimeoutJson"
            | "handoffCommandJson"
            | "upgradeCommandJson"
            | "superviseCommandJson"
            | "sleepMs"
            | "writeFile"
            | "appendFile"
            | "mkdirAll"
            | "readFile"
    )
}

unsafe fn interpret_runtime_binding_by_name(
    image: *mut ClaspRtNativeModuleImage,
    name: &str,
    args: &[*mut ClaspRtHeader],
) -> *mut ClaspRtHeader {
    if let Some(binding) = (*image).runtime_binding(name) {
        interpret_runtime_binding(binding, args)
    } else {
        interpret_builtin_runtime_binding(name, args)
    }
}

unsafe fn has_runtime_binding_or_builtin(image: *mut ClaspRtNativeModuleImage, name: &str) -> bool {
    (*image).runtime_binding(name).is_some() || builtin_runtime_binding_name(name)
}

fn binding_return_type_name(binding: &ClaspRtNativeRuntimeBinding) -> Option<&str> {
    binding
        .binding_type
        .rsplit("->")
        .next()
        .map(str::trim)
        .filter(|name| !name.is_empty())
}

fn json_string_literal(value: &str) -> String {
    format!("{value:?}")
}

fn normalize_variant_wire_tag(tag: &str) -> String {
    let mut normalized = String::with_capacity(tag.len());
    let mut seen_text = false;

    for ch in tag.chars() {
        if ch == '_' {
            if seen_text && !normalized.ends_with('_') {
                normalized.push('_');
            }
            continue;
        }

        if ch.is_ascii_uppercase() {
            if seen_text && !normalized.ends_with('_') {
                normalized.push('_');
            }
            normalized.push(ch.to_ascii_lowercase());
            seen_text = true;
            continue;
        }

        normalized.push(ch);
        seen_text = true;
    }

    if normalized.ends_with('_') {
        normalized.pop();
    }

    normalized
}

fn variant_constructor_for_wire_tag<'a>(
    variant_schema: &'a ClaspRtVariantSchema,
    tag: &str,
) -> Option<&'a ClaspRtVariantConstructorSchema> {
    variant_schema.constructors.get(tag).or_else(|| {
        variant_schema
            .constructors
            .values()
            .find(|constructor| normalize_variant_wire_tag(&constructor.name) == tag)
    })
}

fn json_variant_literal(tag: &str) -> String {
    format!("{{\"$tag\":{}}}", json_string_literal(tag))
}

fn lead_priority_label(tag: &str) -> &'static str {
    match tag {
        "High" => "high",
        "Medium" => "medium",
        _ => "low",
    }
}

fn lead_segment_label(tag: &str) -> &'static str {
    match tag {
        "Enterprise" => "enterprise",
        "Growth" => "growth",
        _ => "startup",
    }
}

unsafe fn string_field_text(
    record_value: *mut ClaspRtRecordValue,
    field_name: &[u8],
) -> Option<String> {
    let field_value = record_field_value_by_name(record_value, field_name)?;
    if field_value.is_null() || (*field_value).layout_id != CLASP_RT_LAYOUT_STRING {
        return None;
    }

    Some(String::from_utf8_lossy(string_bytes(field_value as *mut ClaspRtString)).into_owned())
}

unsafe fn int_field_value(
    record_value: *mut ClaspRtRecordValue,
    field_name: &[u8],
) -> Option<i64> {
    let field_value = record_field_value_by_name(record_value, field_name)?;
    header_int_value(field_value)
}

unsafe fn bool_field_value(
    record_value: *mut ClaspRtRecordValue,
    field_name: &[u8],
) -> Option<bool> {
    let field_value = record_field_value_by_name(record_value, field_name)?;
    header_bool_value(field_value)
}

unsafe fn variant_tag_text(value: *mut ClaspRtHeader) -> Option<String> {
    if value.is_null() || (*value).layout_id != CLASP_RT_LAYOUT_VARIANT_VALUE {
        return None;
    }

    let variant_value = value as *mut ClaspRtVariantValue;
    Some(String::from_utf8_lossy(string_bytes((*variant_value).tag)).into_owned())
}

unsafe fn variant_field_text(
    record_value: *mut ClaspRtRecordValue,
    field_name: &[u8],
) -> Option<String> {
    let field_value = record_field_value_by_name(record_value, field_name)?;
    variant_tag_text(field_value)
}

unsafe fn runtime_result_ok(value: *mut ClaspRtHeader) -> *mut ClaspRtHeader {
    clasp_rt_build_variant_header("Ok", vec![value])
}

unsafe fn runtime_result_err(message: &str) -> *mut ClaspRtHeader {
    clasp_rt_build_variant_header(
        "Err",
        vec![clasp_rt_build_string_header(message)],
    )
}

unsafe fn document_upload_field_record(value: *mut ClaspRtHeader) -> Result<*mut ClaspRtRecordValue, String> {
    if value.is_null() || (*value).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return Err("document upload must be a record".to_owned());
    }
    Ok(value as *mut ClaspRtRecordValue)
}

unsafe fn interpret_document_upload_boundary(upload: *mut ClaspRtHeader) -> *mut ClaspRtHeader {
    let upload_record = match document_upload_field_record(upload) {
        Ok(record) => record,
        Err(message) => return runtime_result_err(&message),
    };

    let Some(document_id) = string_field_text(upload_record, b"documentId") else {
        return runtime_result_err("document upload is missing `documentId`");
    };
    let Some(filename) = string_field_text(upload_record, b"filename") else {
        return runtime_result_err("document upload is missing `filename`");
    };
    let Some(media_type) = string_field_text(upload_record, b"mediaType") else {
        return runtime_result_err("document upload is missing `mediaType`");
    };
    let Some(size_bytes) = int_field_value(upload_record, b"sizeBytes") else {
        return runtime_result_err("document upload is missing `sizeBytes`");
    };
    let Some(content_text) = string_field_text(upload_record, b"contentText") else {
        return runtime_result_err("document upload is missing `contentText`");
    };

    if document_id.trim().is_empty() {
        return runtime_result_err("document upload `documentId` must not be empty");
    }
    if filename.trim().is_empty() {
        return runtime_result_err("document upload `filename` must not be empty");
    }
    if media_type.trim().is_empty() {
        return runtime_result_err("document upload `mediaType` must not be empty");
    }
    if size_bytes < 0 {
        return runtime_result_err("document upload `sizeBytes` must not be negative");
    }
    if size_bytes as usize > DOCUMENT_UPLOAD_MAX_BYTES {
        return runtime_result_err("document upload exceeds the native ingestion byte limit");
    }
    if content_text.len() > DOCUMENT_UPLOAD_MAX_BYTES {
        return runtime_result_err("document upload content exceeds the native ingestion byte limit");
    }

    let normalized_size_bytes = if size_bytes == 0 && !content_text.is_empty() {
        content_text.len() as i64
    } else {
        size_bytes
    };
    let handle = clasp_rt_build_record_header(
        "DocumentHandle",
        vec![
            ("documentId".to_owned(), clasp_rt_build_string_header(&document_id)),
            ("filename".to_owned(), clasp_rt_build_string_header(&filename)),
            ("mediaType".to_owned(), clasp_rt_build_string_header(&media_type)),
            ("sizeBytes".to_owned(), clasp_rt_build_int_header(normalized_size_bytes)),
            ("excerpt".to_owned(), clasp_rt_build_string_header(&document_excerpt(&content_text))),
            (
                "contentFingerprint".to_owned(),
                clasp_rt_build_string_header(&document_boundary_fingerprint(&content_text)),
            ),
        ],
    );
    runtime_result_ok(handle)
}

unsafe fn interpret_document_reference_boundary(value: *mut ClaspRtHeader) -> *mut ClaspRtHeader {
    let text = match clasp_rt_string_arg(value) {
        Ok(text) => text,
        Err(_) => return runtime_result_err("document references must be extracted from a string"),
    };

    match parse_document_reference_specs(&text) {
        Ok(references) => {
            let items = references
                .into_iter()
                .map(|reference| {
                    clasp_rt_build_record_header(
                        "DocumentReference",
                        vec![
                            (
                                "documentId".to_owned(),
                                clasp_rt_build_string_header(&reference.document_id),
                            ),
                            ("label".to_owned(), clasp_rt_build_string_header(&reference.label)),
                            ("raw".to_owned(), clasp_rt_build_string_header(&reference.raw)),
                        ],
                    )
                })
                .collect();
            runtime_result_ok(clasp_rt_build_list_header(items))
        }
        Err(message) => runtime_result_err(&message),
    }
}

fn lead_record_json(lead: &NativeLeadRecord) -> String {
    format!(
        "{{\"leadId\":{},\"company\":{},\"contact\":{},\"summary\":{},\"priority\":{},\"segment\":{},\"followUpRequired\":{},\"reviewStatus\":{},\"reviewNote\":{}}}",
        json_string_literal(&lead.lead_id),
        json_string_literal(&lead.company),
        json_string_literal(&lead.contact),
        json_string_literal(&lead.summary),
        json_variant_literal(&lead.priority),
        json_variant_literal(&lead.segment),
        if lead.follow_up_required { "true" } else { "false" },
        json_variant_literal(&lead.review_status),
        json_string_literal(&lead.review_note),
    )
}

fn lead_label(lead: &NativeLeadRecord) -> String {
    format!(
        "{} ({}, {})",
        lead.company,
        lead_priority_label(&lead.priority),
        lead_segment_label(&lead.segment),
    )
}

fn inbox_snapshot_json(leads: &[NativeLeadRecord]) -> String {
    let primary = leads.first().cloned().unwrap_or_else(|| seeded_native_leads()[0].clone());
    let secondary = leads.get(1).cloned().unwrap_or_else(|| primary.clone());

    format!(
        "{{\"headline\":\"Priority inbox\",\"primaryLeadLabel\":{},\"secondaryLeadLabel\":{}}}",
        json_string_literal(&lead_label(&primary)),
        json_string_literal(&lead_label(&secondary)),
    )
}

unsafe fn interpret_review_release_binding(arg: *mut ClaspRtHeader) -> *mut ClaspRtHeader {
    if arg.is_null() || (*arg).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }

    let request = arg as *mut ClaspRtRecordValue;
    let Some(release_id) = string_field_text(request, b"releaseId") else {
        return null_mut();
    };
    let Some(summary) = string_field_text(request, b"summary") else {
        return null_mut();
    };

    let approved = summary.to_lowercase().contains("ship");
    let status = if approved { "Approved" } else { "RolledBack" };
    let note = if approved {
        "Approved after typed policy review."
    } else {
        "Rolled back pending follow-up."
    };

    let payload = format!(
        "{{\"releaseId\":{},\"status\":{},\"note\":{},\"audit\":{{\"session\":{{\"sessionId\":\"sess-release-204\",\"principal\":{{\"id\":\"ops-9\"}},\"tenant\":{{\"id\":\"operations\"}},\"resource\":{{\"resourceType\":\"release\",\"resourceId\":{}}}}},\"resource\":{{\"resourceType\":\"release\",\"resourceId\":{}}},\"releaseId\":{},\"status\":{},\"note\":{}}}}}",
        json_string_literal(&release_id),
        json_variant_literal(status),
        json_string_literal(note),
        json_string_literal(&release_id),
        json_string_literal(&release_id),
        json_string_literal(&release_id),
        json_variant_literal(status),
        json_string_literal(note),
    );

    build_runtime_string(payload.as_bytes()) as *mut ClaspRtHeader
}

unsafe fn interpret_mock_lead_summary_model_binding(arg: *mut ClaspRtHeader) -> *mut ClaspRtHeader {
    if arg.is_null() || (*arg).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }

    let intake = arg as *mut ClaspRtRecordValue;
    let Some(company) = string_field_text(intake, b"company") else {
        return null_mut();
    };
    let Some(contact) = string_field_text(intake, b"contact") else {
        return null_mut();
    };
    let Some(budget) = int_field_value(intake, b"budget") else {
        return null_mut();
    };
    let priority_hint = variant_field_text(intake, b"priorityHint");
    let segment = variant_field_text(intake, b"segment")
        .unwrap_or_else(|| "Startup".to_owned())
        .to_ascii_lowercase();

    let priority = if let Some(priority_hint) = priority_hint {
        priority_hint
    } else if budget >= 50_000 {
        "High".to_owned()
    } else if budget >= 20_000 {
        "Medium".to_owned()
    } else {
        "Low".to_owned()
    };
    let priority = env::var("CLASP_MOCK_LEAD_SUMMARY_PRIORITY")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(priority);
    let segment_tag = match segment.as_str() {
        "enterprise" => "Enterprise",
        "growth" => "Growth",
        _ => "Startup",
    };
    let segment_tag = env::var("CLASP_MOCK_LEAD_SUMMARY_SEGMENT")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| segment_tag.to_owned());
    let follow_up_required = env::var("CLASP_MOCK_LEAD_SUMMARY_FOLLOW_UP_REQUIRED")
        .ok()
        .and_then(|value| match value.to_ascii_lowercase().as_str() {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        })
        .unwrap_or(budget >= 20_000);
    let summary = env::var("CLASP_MOCK_LEAD_SUMMARY_SUMMARY")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| {
            format!(
                "{company} led by {contact} fits the {} priority pipeline.",
                lead_priority_label(&priority)
            )
        });
    let payload = format!(
        "{{\"summary\":{},\"priority\":{},\"segment\":{},\"followUpRequired\":{}}}",
        json_string_literal(&summary),
        json_variant_literal(&priority),
        json_variant_literal(&segment_tag),
        if follow_up_required { "true" } else { "false" },
    );

    build_runtime_string(payload.as_bytes()) as *mut ClaspRtHeader
}

unsafe fn interpret_mock_lead_outreach_model_binding(arg: *mut ClaspRtHeader) -> *mut ClaspRtHeader {
    if arg.is_null() || (*arg).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }

    let request = arg as *mut ClaspRtRecordValue;
    let Some(lead_id) = string_field_text(request, b"leadId") else {
        return null_mut();
    };
    let Some(company) = string_field_text(request, b"company") else {
        return null_mut();
    };
    let Some(contact) = string_field_text(request, b"contact") else {
        return null_mut();
    };
    let Some(summary) = string_field_text(request, b"summary") else {
        return null_mut();
    };
    let Some(channel) = string_field_text(request, b"channel") else {
        return null_mut();
    };
    let Some(guidance) = string_field_text(request, b"guidance") else {
        return null_mut();
    };
    let Some(call_to_action) = string_field_text(request, b"callToAction") else {
        return null_mut();
    };

    let payload = format!(
        "{{\"leadId\":{},\"channel\":{},\"subject\":{},\"message\":{},\"callToAction\":{}}}",
        json_string_literal(&lead_id),
        json_string_literal(&channel),
        json_string_literal(&format!("{company} {channel} follow-up")),
        json_string_literal(&format!(
            "{summary} Reach out to {contact} with: {guidance}"
        )),
        json_string_literal(&call_to_action),
    );

    build_runtime_string(payload.as_bytes()) as *mut ClaspRtHeader
}

unsafe fn interpret_store_lead_binding(
    intake_arg: *mut ClaspRtHeader,
    summary_arg: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if intake_arg.is_null()
        || summary_arg.is_null()
        || (*intake_arg).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE
        || (*summary_arg).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE
    {
        return null_mut();
    }

    let intake = intake_arg as *mut ClaspRtRecordValue;
    let summary = summary_arg as *mut ClaspRtRecordValue;
    let Some(company) = string_field_text(intake, b"company") else {
        return null_mut();
    };
    let Some(contact) = string_field_text(intake, b"contact") else {
        return null_mut();
    };
    let Some(summary_text) = string_field_text(summary, b"summary") else {
        return null_mut();
    };
    let priority = variant_field_text(summary, b"priority").unwrap_or_else(|| "Low".to_owned());
    let segment = variant_field_text(summary, b"segment").unwrap_or_else(|| "Startup".to_owned());
    let Some(follow_up_required) = bool_field_value(summary, b"followUpRequired") else {
        return null_mut();
    };

    let mut leads = native_lead_state().lock().unwrap();
    let lead = NativeLeadRecord {
        lead_id: format!("lead-{}", leads.len() + 1),
        company,
        contact,
        summary: summary_text,
        priority,
        segment,
        follow_up_required,
        review_status: "New".to_owned(),
        review_note: String::new(),
    };
    leads.insert(0, lead.clone());

    build_runtime_string(lead_record_json(&lead).as_bytes()) as *mut ClaspRtHeader
}

unsafe fn interpret_load_inbox_binding() -> *mut ClaspRtHeader {
    let leads = native_lead_state().lock().unwrap();
    build_runtime_string(inbox_snapshot_json(&leads).as_bytes()) as *mut ClaspRtHeader
}

unsafe fn interpret_load_primary_lead_binding() -> *mut ClaspRtHeader {
    let leads = native_lead_state().lock().unwrap();
    let lead = leads.first().cloned().unwrap_or_else(|| seeded_native_leads()[0].clone());
    build_runtime_string(lead_record_json(&lead).as_bytes()) as *mut ClaspRtHeader
}

unsafe fn interpret_load_secondary_lead_binding() -> *mut ClaspRtHeader {
    let leads = native_lead_state().lock().unwrap();
    let lead = leads
        .get(1)
        .cloned()
        .or_else(|| leads.first().cloned())
        .unwrap_or_else(|| seeded_native_leads()[0].clone());
    build_runtime_string(lead_record_json(&lead).as_bytes()) as *mut ClaspRtHeader
}

unsafe fn interpret_review_lead_binding(arg: *mut ClaspRtHeader) -> *mut ClaspRtHeader {
    if arg.is_null() || (*arg).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }

    let review = arg as *mut ClaspRtRecordValue;
    let Some(lead_id) = string_field_text(review, b"leadId") else {
        return null_mut();
    };
    let Some(note) = string_field_text(review, b"note") else {
        return null_mut();
    };

    let mut leads = native_lead_state().lock().unwrap();
    let Some(lead) = leads.iter_mut().find(|candidate| candidate.lead_id == lead_id) else {
        set_native_route_error(format!("Unknown lead: {lead_id}"));
        return null_mut();
    };
    lead.review_status = "Reviewed".to_owned();
    lead.review_note = note;

    build_runtime_string(lead_record_json(lead).as_bytes()) as *mut ClaspRtHeader
}

unsafe fn cloned_string_field(
    record_value: *mut ClaspRtRecordValue,
    field_name: &[u8],
) -> Option<*mut ClaspRtHeader> {
    let field_value = record_field_value_by_name(record_value, field_name)?;
    if field_value.is_null() || (*field_value).layout_id != CLASP_RT_LAYOUT_STRING {
        return None;
    }
    Some(build_runtime_string(string_bytes(field_value as *mut ClaspRtString)) as *mut ClaspRtHeader)
}

unsafe fn interpret_reply_preview_binding(
    binding: &ClaspRtNativeRuntimeBinding,
    arg: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if arg.is_null() || (*arg).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }

    let record_value = arg as *mut ClaspRtRecordValue;
    let Some(customer_id) = cloned_string_field(record_value, b"customerId") else {
        return null_mut();
    };
    let Some(summary_value) = record_field_value_by_name(record_value, b"summary") else {
        release_header(null_mut(), customer_id);
        return null_mut();
    };
    if summary_value.is_null() || (*summary_value).layout_id != CLASP_RT_LAYOUT_STRING {
        release_header(null_mut(), customer_id);
        return null_mut();
    }

    let summary_text = String::from_utf8_lossy(string_bytes(summary_value as *mut ClaspRtString)).into_owned();
    let suggested_reply = build_runtime_string(
        format!(
            "Thanks for the update. {} We will send the next renewal step today.",
            summary_text
        )
        .as_bytes(),
    ) as *mut ClaspRtHeader;
    if suggested_reply.is_null() {
        release_header(null_mut(), customer_id);
        return null_mut();
    }

    let escalation_needed =
        build_runtime_bool(summary_text.to_lowercase().contains("blocked")) as *mut ClaspRtHeader;
    if escalation_needed.is_null() {
        release_header(null_mut(), customer_id);
        release_header(null_mut(), suggested_reply);
        return null_mut();
    }

    clasp_rt_build_record_header(
        binding_return_type_name(binding).unwrap_or("TicketPreview"),
        vec![
            ("customerId".to_owned(), customer_id),
            ("suggestedReply".to_owned(), suggested_reply),
            ("escalationNeeded".to_owned(), escalation_needed),
        ],
    )
}

fn interpret_match_value(
    runtime: *mut ClaspRtRuntime,
    image: *mut ClaspRtNativeModuleImage,
    value: *mut ClaspRtHeader,
    branches: &[ClaspRtInterpretedMatchBranch],
    env: &[(&str, *mut ClaspRtHeader)],
    depth: usize,
) -> *mut ClaspRtHeader {
    if value.is_null() {
        return null_mut();
    }

    unsafe {
        if (*value).layout_id == CLASP_RT_LAYOUT_RESULT_STRING {
            let result = value as *mut ClaspRtResultString;
            let tag = if (*result).is_ok { "Ok" } else { "Err" };
            let payload = (*result).value as *mut ClaspRtHeader;
            return interpret_match_branch(runtime, image, branches, tag, payload, env, depth);
        }
        if (*value).layout_id == CLASP_RT_LAYOUT_VARIANT_VALUE {
            let variant = value as *mut ClaspRtVariantValue;
            let tag = String::from_utf8_lossy(string_bytes((*variant).tag)).into_owned();
            return interpret_match_branch_many(runtime, image, branches, &tag, variant_items(variant), env, depth);
        }
    }

    null_mut()
}

fn interpret_match_branch(
    runtime: *mut ClaspRtRuntime,
    image: *mut ClaspRtNativeModuleImage,
    branches: &[ClaspRtInterpretedMatchBranch],
    tag: &str,
    payload: *mut ClaspRtHeader,
    env: &[(&str, *mut ClaspRtHeader)],
    depth: usize,
) -> *mut ClaspRtHeader {
    let payloads = [payload];
    interpret_match_branch_many(runtime, image, branches, tag, &payloads, env, depth)
}

fn interpret_match_branch_many(
    runtime: *mut ClaspRtRuntime,
    image: *mut ClaspRtNativeModuleImage,
    branches: &[ClaspRtInterpretedMatchBranch],
    tag: &str,
    payloads: &[*mut ClaspRtHeader],
    env: &[(&str, *mut ClaspRtHeader)],
    depth: usize,
) -> *mut ClaspRtHeader {
    for branch in branches {
        let Some(bindings) = match_branch_payload_bindings(branch, tag, payloads) else {
            continue;
        };

        let mut extended_env: Vec<(&str, *mut ClaspRtHeader)> = env.to_vec();
        for (name, value) in &bindings {
            extended_env.push((name.as_str(), *value));
        }
        return interpret_native_expr(runtime, image, &branch.body, &extended_env, depth + 1);
    }
    null_mut()
}

fn match_branch_payload_bindings(
    branch: &ClaspRtInterpretedMatchBranch,
    tag: &str,
    payloads: &[*mut ClaspRtHeader],
) -> Option<Vec<(String, *mut ClaspRtHeader)>> {
    if branch.tag == "_" {
        return branch.binders.is_empty().then(Vec::new);
    }
    if branch.tag != tag || branch.binders.len() != payloads.len() {
        return None;
    }

    let mut bindings = Vec::new();
    for (binder, payload) in branch.binders.iter().zip(payloads.iter().copied()) {
        if !collect_match_pattern_bindings(binder, payload, &mut bindings) {
            return None;
        }
    }
    Some(bindings)
}

fn collect_match_pattern_bindings(
    pattern: &str,
    value: *mut ClaspRtHeader,
    bindings: &mut Vec<(String, *mut ClaspRtHeader)>,
) -> bool {
    let checkpoint = bindings.len();
    let matched = collect_match_pattern_bindings_inner(pattern, value, bindings);
    if !matched {
        bindings.truncate(checkpoint);
    }
    matched
}

fn collect_match_pattern_bindings_inner(
    pattern: &str,
    value: *mut ClaspRtHeader,
    bindings: &mut Vec<(String, *mut ClaspRtHeader)>,
) -> bool {
    let pattern = normalize_match_pattern(pattern);
    if pattern.is_empty() {
        return false;
    }
    if pattern == "_" {
        return true;
    }

    let parts = split_match_pattern_atoms(&pattern);
    if let Some(head) = parts.first() {
        if starts_with_uppercase_ascii(head) {
            let Some((tag, payloads)) = match_value_tag_payloads(value) else {
                return false;
            };
            if tag != *head || payloads.len() + 1 != parts.len() {
                return false;
            }
            for (nested_pattern, nested_value) in parts.iter().skip(1).zip(payloads.iter().copied()) {
                if !collect_match_pattern_bindings(nested_pattern, nested_value, bindings) {
                    return false;
                }
            }
            return true;
        }
    }

    bindings.push((pattern, value));
    true
}

fn normalize_match_pattern(pattern: &str) -> String {
    let mut current = pattern.trim().to_owned();
    loop {
        let Some(inner) = strip_balanced_outer_parens(&current) else {
            return current;
        };
        current = inner.trim().to_owned();
    }
}

fn strip_balanced_outer_parens(value: &str) -> Option<&str> {
    let bytes = value.as_bytes();
    if bytes.first().copied() != Some(b'(') || bytes.last().copied() != Some(b')') {
        return None;
    }

    let mut depth = 0i32;
    for (index, byte) in bytes.iter().enumerate() {
        match *byte {
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth == 0 && index + 1 != bytes.len() {
                    return None;
                }
                if depth < 0 {
                    return None;
                }
            }
            _ => {}
        }
    }
    if depth == 0 {
        Some(&value[1..value.len() - 1])
    } else {
        None
    }
}

fn split_match_pattern_atoms(value: &str) -> Vec<String> {
    let mut atoms = Vec::new();
    let mut start: Option<usize> = None;
    let mut depth = 0i32;

    for (index, ch) in value.char_indices() {
        match ch {
            '(' => {
                if start.is_none() {
                    start = Some(index);
                }
                depth += 1;
            }
            ')' => {
                depth -= 1;
            }
            ch if ch.is_whitespace() && depth == 0 => {
                if let Some(atom_start) = start.take() {
                    if atom_start < index {
                        atoms.push(value[atom_start..index].trim().to_owned());
                    }
                }
            }
            _ => {
                if start.is_none() {
                    start = Some(index);
                }
            }
        }
    }

    if let Some(atom_start) = start {
        if atom_start < value.len() {
            atoms.push(value[atom_start..].trim().to_owned());
        }
    }
    atoms
}

fn starts_with_uppercase_ascii(value: &str) -> bool {
    value
        .as_bytes()
        .first()
        .copied()
        .is_some_and(|byte| byte.is_ascii_uppercase())
}

fn match_value_tag_payloads(value: *mut ClaspRtHeader) -> Option<(String, Vec<*mut ClaspRtHeader>)> {
    if value.is_null() {
        return None;
    }
    unsafe {
        if (*value).layout_id == CLASP_RT_LAYOUT_RESULT_STRING {
            let result = value as *mut ClaspRtResultString;
            let tag = if (*result).is_ok { "Ok" } else { "Err" };
            return Some((tag.to_owned(), vec![(*result).value as *mut ClaspRtHeader]));
        }
        if (*value).layout_id == CLASP_RT_LAYOUT_VARIANT_VALUE {
            let variant = value as *mut ClaspRtVariantValue;
            let tag = String::from_utf8_lossy(string_bytes((*variant).tag)).into_owned();
            return Some((tag, variant_items(variant).to_vec()));
        }
    }
    None
}

impl Drop for ClaspRtNativeModuleImage {
    fn drop(&mut self) {
        unsafe {
            release_header(null_mut(), self.module_name as *mut ClaspRtHeader);
            release_header(null_mut(), self.runtime_profile as *mut ClaspRtHeader);
            release_header(null_mut(), self.interface_fingerprint as *mut ClaspRtHeader);
            release_header(null_mut(), self.migration_strategy as *mut ClaspRtHeader);
            release_header(null_mut(), self.migration_state_type as *mut ClaspRtHeader);
            release_header(null_mut(), self.snapshot_symbol as *mut ClaspRtHeader);
            release_header(null_mut(), self.handoff_symbol as *mut ClaspRtHeader);
            release_header(null_mut(), self.state_snapshot_type as *mut ClaspRtHeader);
            release_header(null_mut(), self.state_snapshot as *mut ClaspRtHeader);
            for fingerprint in &self.accepted_previous_fingerprints {
                release_header(null_mut(), *fingerprint as *mut ClaspRtHeader);
            }
            for export_name in &self.exports {
                release_header(null_mut(), *export_name as *mut ClaspRtHeader);
            }
            for symbol in &self.entrypoint_symbols {
                release_header(null_mut(), *symbol as *mut ClaspRtHeader);
            }
        }
    }
}

#[derive(Clone, Copy)]
struct JsonSlice {
    start: usize,
    end: usize,
}

fn abort_oom() -> ! {
    eprintln!("clasp native runtime: out of memory");
    std::process::abort();
}

fn layout_for_array<T>(len: usize) -> Layout {
    Layout::array::<T>(len.max(1)).unwrap_or_else(|_| abort_oom())
}

fn layout_for_bytes(len: usize) -> Layout {
    Layout::from_size_align(len.max(1), 1).unwrap_or_else(|_| abort_oom())
}

unsafe fn alloc_zeroed_with_layout(layout: Layout) -> *mut u8 {
    let memory = alloc_zeroed(layout);
    if memory.is_null() {
        handle_alloc_error(layout);
    }
    memory
}

unsafe fn alloc_zeroed_array<T>(len: usize) -> *mut T {
    alloc_zeroed_with_layout(layout_for_array::<T>(len)) as *mut T
}

unsafe fn free_array<T>(ptr: *mut T, len: usize) {
    if !ptr.is_null() {
        dealloc(ptr as *mut u8, layout_for_array::<T>(len));
    }
}

unsafe fn alloc_zeroed_bytes(len: usize) -> *mut u8 {
    alloc_zeroed_with_layout(layout_for_bytes(len))
}

unsafe fn free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        dealloc(ptr, layout_for_bytes(len));
    }
}

fn object_layout_for_words(word_count: usize) -> Layout {
    Layout::from_size_align(
        size_of::<ClaspRtObject>() + (word_count * size_of::<usize>()),
        align_of::<ClaspRtObject>(),
    )
    .unwrap_or_else(|_| abort_oom())
}

unsafe fn object_words_ptr(object: *mut ClaspRtObject) -> *mut usize {
    (&mut (*object).words as *mut [usize; 0]) as *mut usize
}

unsafe fn string_bytes<'a>(value: *const ClaspRtString) -> &'a [u8] {
    if value.is_null() || (*value).byte_length == 0 || (*value).bytes.is_null() {
        &[]
    } else {
        slice::from_raw_parts((*value).bytes as *const u8, (*value).byte_length)
    }
}

unsafe fn bytes_bytes<'a>(value: *const ClaspRtBytes) -> &'a [u8] {
    if value.is_null() || (*value).byte_length == 0 || (*value).bytes.is_null() {
        &[]
    } else {
        slice::from_raw_parts((*value).bytes, (*value).byte_length)
    }
}

unsafe fn string_from_c(value: *const c_char) -> &'static [u8] {
    if value.is_null() {
        &[]
    } else {
        CStr::from_ptr(value).to_bytes()
    }
}

unsafe fn build_runtime_string(bytes: &[u8]) -> *mut ClaspRtString {
    let raw_bytes = alloc_zeroed_bytes(bytes.len() + 1);
    if !bytes.is_empty() {
        ptr::copy_nonoverlapping(bytes.as_ptr(), raw_bytes, bytes.len());
    }
    *raw_bytes.add(bytes.len()) = 0;

    Box::into_raw(Box::new(ClaspRtString {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_STRING,
            retain_count: 1,
            destroy: Some(destroy_string),
        },
        byte_length: bytes.len(),
        bytes: raw_bytes as *mut c_char,
    }))
}

unsafe fn build_runtime_bytes(len: usize) -> *mut ClaspRtBytes {
    Box::into_raw(Box::new(ClaspRtBytes {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_BYTES,
            retain_count: 1,
            destroy: Some(destroy_bytes),
        },
        byte_length: len,
        bytes: alloc_zeroed_bytes(len),
    }))
}

unsafe fn build_runtime_int(value: i64) -> *mut ClaspRtInt {
    Box::into_raw(Box::new(ClaspRtInt {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_INT,
            retain_count: 1,
            destroy: Some(destroy_int),
        },
        value,
    }))
}

unsafe fn build_runtime_bool(value: bool) -> *mut ClaspRtBool {
    Box::into_raw(Box::new(ClaspRtBool {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_BOOL,
            retain_count: 1,
            destroy: Some(destroy_bool),
        },
        value,
    }))
}

unsafe fn build_runtime_string_list(len: usize) -> *mut ClaspRtStringList {
    Box::into_raw(Box::new(ClaspRtStringList {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_STRING_LIST,
            retain_count: 1,
            destroy: Some(destroy_string_list),
        },
        length: len,
        items: alloc_zeroed_array::<*mut ClaspRtString>(len),
    }))
}

unsafe fn build_runtime_list_value(items: Vec<*mut ClaspRtHeader>) -> *mut ClaspRtListValue {
    let item_count = items.len();
    let item_ptr = alloc_zeroed_array::<*mut ClaspRtHeader>(item_count);
    for (index, item) in items.into_iter().enumerate() {
        *item_ptr.add(index) = item;
    }

    Box::into_raw(Box::new(ClaspRtListValue {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_LIST_VALUE,
            retain_count: 1,
            destroy: Some(destroy_list_value),
        },
        item_count,
        items: item_ptr,
    }))
}

unsafe fn build_runtime_early_return(value: *mut ClaspRtHeader) -> *mut ClaspRtEarlyReturn {
    Box::into_raw(Box::new(ClaspRtEarlyReturn {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_EARLY_RETURN,
            retain_count: 1,
            destroy: Some(destroy_early_return),
        },
        value,
    }))
}

unsafe fn build_runtime_result_string(is_ok: bool, value: *mut ClaspRtString) -> *mut ClaspRtResultString {
    retain_header(value as *mut ClaspRtHeader);
    Box::into_raw(Box::new(ClaspRtResultString {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_RESULT_STRING,
            retain_count: 1,
            destroy: Some(destroy_result_string),
        },
        is_ok,
        value,
    }))
}

unsafe fn build_runtime_mutable_cell(value: *mut ClaspRtHeader) -> *mut ClaspRtMutableCell {
    Box::into_raw(Box::new(ClaspRtMutableCell {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_MUTABLE_CELL,
            retain_count: 1,
            destroy: Some(destroy_mutable_cell),
        },
        value,
    }))
}

unsafe fn build_runtime_variant_value(tag: &str, items: Vec<*mut ClaspRtHeader>) -> *mut ClaspRtVariantValue {
    let item_count = items.len();
    let item_ptr = alloc_zeroed_array::<*mut ClaspRtHeader>(item_count);
    for (index, item) in items.into_iter().enumerate() {
        *item_ptr.add(index) = item;
    }

    Box::into_raw(Box::new(ClaspRtVariantValue {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_VARIANT_VALUE,
            retain_count: 1,
            destroy: Some(destroy_variant_value),
        },
        tag: build_runtime_string(tag.as_bytes()),
        item_count,
        items: item_ptr,
    }))
}

unsafe fn build_runtime_record_value(
    record_name: &str,
    fields: Vec<(String, *mut ClaspRtHeader)>,
) -> *mut ClaspRtRecordValue {
    let field_count = fields.len();
    let field_name_ptr = alloc_zeroed_array::<*mut ClaspRtString>(field_count);
    let field_value_ptr = alloc_zeroed_array::<*mut ClaspRtHeader>(field_count);
    for (index, (name, value)) in fields.into_iter().enumerate() {
        *field_name_ptr.add(index) = build_runtime_string(name.as_bytes());
        *field_value_ptr.add(index) = value;
    }

    Box::into_raw(Box::new(ClaspRtRecordValue {
        header: ClaspRtHeader {
            layout_id: CLASP_RT_LAYOUT_RECORD_VALUE,
            retain_count: 1,
            destroy: Some(destroy_record_value),
        },
        record_name: build_runtime_string(record_name.as_bytes()),
        field_count,
        field_names: field_name_ptr,
        field_values: field_value_ptr,
    }))
}

pub unsafe fn clasp_rt_build_string_header(value: &str) -> *mut ClaspRtHeader {
    build_runtime_string(value.as_bytes()) as *mut ClaspRtHeader
}

pub unsafe fn clasp_rt_build_int_header(value: i64) -> *mut ClaspRtHeader {
    build_runtime_int(value) as *mut ClaspRtHeader
}

pub unsafe fn clasp_rt_build_bool_header(value: bool) -> *mut ClaspRtHeader {
    build_runtime_bool(value) as *mut ClaspRtHeader
}

pub unsafe fn clasp_rt_build_list_header(items: Vec<*mut ClaspRtHeader>) -> *mut ClaspRtHeader {
    build_runtime_list_value(items) as *mut ClaspRtHeader
}

pub unsafe fn clasp_rt_build_variant_header(tag: &str, items: Vec<*mut ClaspRtHeader>) -> *mut ClaspRtHeader {
    build_runtime_variant_value(tag, items) as *mut ClaspRtHeader
}

pub unsafe fn clasp_rt_build_record_header(
    record_name: &str,
    fields: Vec<(String, *mut ClaspRtHeader)>,
) -> *mut ClaspRtHeader {
    build_runtime_record_value(record_name, fields) as *mut ClaspRtHeader
}

unsafe fn retain_header(header: *mut ClaspRtHeader) {
    if !header.is_null() {
        (*header).retain_count = (*header).retain_count.saturating_add(1);
    }
}

unsafe fn release_header(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    if header.is_null() {
        return;
    }

    if (*header).retain_count > 1 {
        (*header).retain_count -= 1;
        return;
    }

    if let Some(destroy) = (*header).destroy {
        destroy(runtime, header);
    }
}

unsafe fn string_list_items_mut<'a>(list: *mut ClaspRtStringList) -> &'a mut [*mut ClaspRtString] {
    if list.is_null() || (*list).length == 0 || (*list).items.is_null() {
        &mut []
    } else {
        slice::from_raw_parts_mut((*list).items, (*list).length)
    }
}

unsafe fn variant_items<'a>(value: *mut ClaspRtVariantValue) -> &'a [*mut ClaspRtHeader] {
    if value.is_null() || (*value).item_count == 0 || (*value).items.is_null() {
        &[]
    } else {
        slice::from_raw_parts((*value).items, (*value).item_count)
    }
}

unsafe fn list_value_items<'a>(value: *mut ClaspRtListValue) -> &'a [*mut ClaspRtHeader] {
    if value.is_null() || (*value).item_count == 0 || (*value).items.is_null() {
        &[]
    } else {
        slice::from_raw_parts((*value).items, (*value).item_count)
    }
}

unsafe fn record_field_names<'a>(value: *mut ClaspRtRecordValue) -> &'a [*mut ClaspRtString] {
    if value.is_null() || (*value).field_count == 0 || (*value).field_names.is_null() {
        &[]
    } else {
        slice::from_raw_parts((*value).field_names, (*value).field_count)
    }
}

unsafe fn record_field_values<'a>(value: *mut ClaspRtRecordValue) -> &'a [*mut ClaspRtHeader] {
    if value.is_null() || (*value).field_count == 0 || (*value).field_values.is_null() {
        &[]
    } else {
        slice::from_raw_parts((*value).field_values, (*value).field_count)
    }
}

unsafe fn record_field_value_by_name(
    value: *mut ClaspRtRecordValue,
    field_name: &[u8],
) -> Option<*mut ClaspRtHeader> {
    for (name_ptr, value_ptr) in record_field_names(value)
        .iter()
        .zip(record_field_values(value).iter())
    {
        if string_bytes(*name_ptr) == field_name {
            return Some(*value_ptr);
        }
    }
    None
}

unsafe fn record_is_dict(value: *mut ClaspRtRecordValue) -> bool {
    !value.is_null() && string_bytes((*value).record_name) == b"Dict"
}

unsafe fn dict_clone_fields(
    value: *mut ClaspRtRecordValue,
    skip_field_name: Option<&[u8]>,
    replacement: Option<(&str, *mut ClaspRtHeader)>,
) -> Vec<(String, *mut ClaspRtHeader)> {
    let mut fields = Vec::new();
    let mut replaced = false;
    for (name_ptr, value_ptr) in record_field_names(value)
        .iter()
        .zip(record_field_values(value).iter())
    {
        let name_bytes = string_bytes(*name_ptr);
        if let Some(skip_name) = skip_field_name {
            if name_bytes == skip_name {
                continue;
            }
        }
        if let Some((replacement_name, replacement_value)) = replacement {
            if name_bytes == replacement_name.as_bytes() {
                retain_header(replacement_value);
                fields.push((replacement_name.to_owned(), replacement_value));
                replaced = true;
                continue;
            }
        }
        retain_header(*value_ptr);
        fields.push((String::from_utf8_lossy(string_bytes(*name_ptr)).into_owned(), *value_ptr));
    }
    if let Some((replacement_name, replacement_value)) = replacement {
        if !replaced {
            retain_header(replacement_value);
            fields.push((replacement_name.to_owned(), replacement_value));
        }
    }
    fields
}

unsafe fn build_prompt_message_header(role: &str, content: *mut ClaspRtString) -> *mut ClaspRtHeader {
    if content.is_null() {
        return null_mut();
    }
    clasp_rt_build_record_header(
        "PromptMessage",
        vec![
            ("role".to_owned(), clasp_rt_build_string_header(role)),
            (
                "content".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(content))),
            ),
        ],
    )
}

unsafe fn build_prompt_header(messages: Vec<*mut ClaspRtHeader>) -> *mut ClaspRtHeader {
    clasp_rt_build_record_header(
        "Prompt",
        vec![("messages".to_owned(), clasp_rt_build_list_header(messages))],
    )
}

unsafe fn prompt_messages_cloned(prompt: *mut ClaspRtHeader) -> Option<Vec<*mut ClaspRtHeader>> {
    if prompt.is_null() || (*prompt).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return None;
    }
    let prompt_record = prompt as *mut ClaspRtRecordValue;
    if string_bytes((*prompt_record).record_name) != b"Prompt" {
        return None;
    }
    let messages_value = record_field_value_by_name(prompt_record, b"messages")?;
    if messages_value.is_null() || (*messages_value).layout_id != CLASP_RT_LAYOUT_LIST_VALUE {
        return None;
    }
    let mut cloned = Vec::new();
    for item in list_value_items(messages_value as *mut ClaspRtListValue) {
        retain_header(*item);
        cloned.push(*item);
    }
    Some(cloned)
}

unsafe fn join_string_bytes(parts: &[*mut ClaspRtString], separator: &[u8]) -> Vec<u8> {
    let mut total_length = 0usize;
    for (index, part) in parts.iter().enumerate() {
        total_length += string_bytes(*part).len();
        if index + 1 < parts.len() {
            total_length += separator.len();
        }
    }

    let mut buffer = Vec::with_capacity(total_length);
    for (index, part) in parts.iter().enumerate() {
        buffer.extend_from_slice(string_bytes(*part));
        if index + 1 < parts.len() {
            buffer.extend_from_slice(separator);
        }
    }
    buffer
}

fn find_subslice(haystack: &[u8], needle: &[u8], start: usize) -> Option<usize> {
    if needle.is_empty() {
        return Some(start.min(haystack.len()));
    }
    haystack[start..]
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|offset| start + offset)
}

unsafe fn string_ptr_equals(left: *mut ClaspRtString, right: *mut ClaspRtString) -> bool {
    string_bytes(left) == string_bytes(right)
}

unsafe fn build_native_dispatch_result(
    module_name: *mut ClaspRtString,
    generation: usize,
    export_name: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(string_bytes(module_name));
    bytes.extend_from_slice(b"@");
    bytes.extend_from_slice(generation.to_string().as_bytes());
    bytes.extend_from_slice(b"::");
    bytes.extend_from_slice(string_bytes(export_name));
    clasp_rt_result_ok_string(build_runtime_string(&bytes))
}

unsafe fn native_module_state_snapshot_is_valid(snapshot: *mut ClaspRtJson) -> bool {
    if snapshot.is_null() {
        return false;
    }
    json_root_object(string_bytes(snapshot as *mut ClaspRtString)).is_some()
}

unsafe fn find_export_index(image: *mut ClaspRtNativeModuleImage, export_name: *mut ClaspRtString) -> Option<usize> {
    if image.is_null() {
        return None;
    }
    (*image)
        .exports
        .iter()
        .position(|candidate| string_ptr_equals(*candidate, export_name))
}

fn skip_json_ws(bytes: &[u8], mut cursor: usize) -> usize {
    while cursor < bytes.len() && matches!(bytes[cursor], b' ' | b'\n' | b'\r' | b'\t') {
        cursor += 1;
    }
    cursor
}

fn skip_json_string(bytes: &[u8], mut cursor: usize) -> Option<usize> {
    if bytes.get(cursor) != Some(&b'"') {
        return None;
    }

    cursor += 1;
    while cursor < bytes.len() {
        match bytes[cursor] {
            b'\\' => {
                cursor += 1;
                if cursor >= bytes.len() {
                    return None;
                }
                if bytes[cursor] == b'u' {
                    for _ in 0..4 {
                        cursor += 1;
                        if cursor >= bytes.len() || !(bytes[cursor] as char).is_ascii_hexdigit() {
                            return None;
                        }
                    }
                    cursor += 1;
                    continue;
                }
                cursor += 1;
            }
            b'"' => return Some(cursor + 1),
            _ => cursor += 1,
        }
    }

    None
}

fn skip_json_number(bytes: &[u8], mut cursor: usize) -> Option<usize> {
    if bytes.get(cursor) == Some(&b'-') {
        cursor += 1;
    }

    if !matches!(bytes.get(cursor), Some(value) if (*value as char).is_ascii_digit()) {
        return None;
    }

    if bytes[cursor] == b'0' {
        cursor += 1;
    } else {
        while matches!(bytes.get(cursor), Some(value) if (*value as char).is_ascii_digit()) {
            cursor += 1;
        }
    }

    if bytes.get(cursor) == Some(&b'.') {
        cursor += 1;
        if !matches!(bytes.get(cursor), Some(value) if (*value as char).is_ascii_digit()) {
            return None;
        }
        while matches!(bytes.get(cursor), Some(value) if (*value as char).is_ascii_digit()) {
            cursor += 1;
        }
    }

    if matches!(bytes.get(cursor), Some(b'e' | b'E')) {
        cursor += 1;
        if matches!(bytes.get(cursor), Some(b'+' | b'-')) {
            cursor += 1;
        }
        if !matches!(bytes.get(cursor), Some(value) if (*value as char).is_ascii_digit()) {
            return None;
        }
        while matches!(bytes.get(cursor), Some(value) if (*value as char).is_ascii_digit()) {
            cursor += 1;
        }
    }

    Some(cursor)
}

fn skip_json_array(bytes: &[u8], mut cursor: usize) -> Option<usize> {
    if bytes.get(cursor) != Some(&b'[') {
        return None;
    }

    cursor = skip_json_ws(bytes, cursor + 1);
    if bytes.get(cursor) == Some(&b']') {
        return Some(cursor + 1);
    }

    while cursor < bytes.len() {
        let value_end = skip_json_value(bytes, cursor)?;
        cursor = skip_json_ws(bytes, value_end);
        match bytes.get(cursor) {
            Some(b']') => return Some(cursor + 1),
            Some(b',') => cursor = skip_json_ws(bytes, cursor + 1),
            _ => return None,
        }
    }

    None
}

fn skip_json_object(bytes: &[u8], mut cursor: usize) -> Option<usize> {
    if bytes.get(cursor) != Some(&b'{') {
        return None;
    }

    cursor = skip_json_ws(bytes, cursor + 1);
    if bytes.get(cursor) == Some(&b'}') {
        return Some(cursor + 1);
    }

    while cursor < bytes.len() {
        let key_end = skip_json_string(bytes, cursor)?;
        cursor = skip_json_ws(bytes, key_end);
        if bytes.get(cursor) != Some(&b':') {
            return None;
        }
        cursor = skip_json_ws(bytes, cursor + 1);
        let value_end = skip_json_value(bytes, cursor)?;
        cursor = skip_json_ws(bytes, value_end);
        match bytes.get(cursor) {
            Some(b'}') => return Some(cursor + 1),
            Some(b',') => cursor = skip_json_ws(bytes, cursor + 1),
            _ => return None,
        }
    }

    None
}

fn skip_json_value(bytes: &[u8], cursor: usize) -> Option<usize> {
    let cursor = skip_json_ws(bytes, cursor);
    match bytes.get(cursor) {
        Some(b'"') => skip_json_string(bytes, cursor),
        Some(b'{') => skip_json_object(bytes, cursor),
        Some(b'[') => skip_json_array(bytes, cursor),
        Some(b'-') | Some(b'0'..=b'9') => skip_json_number(bytes, cursor),
        Some(_) if bytes[cursor..].starts_with(b"true") => Some(cursor + 4),
        Some(_) if bytes[cursor..].starts_with(b"false") => Some(cursor + 5),
        Some(_) if bytes[cursor..].starts_with(b"null") => Some(cursor + 4),
        _ => None,
    }
}

fn json_root_object(bytes: &[u8]) -> Option<JsonSlice> {
    let start = skip_json_ws(bytes, 0);
    if bytes.get(start) != Some(&b'{') {
        return None;
    }

    let end = skip_json_value(bytes, start)?;
    if skip_json_ws(bytes, end) != bytes.len() {
        return None;
    }

    Some(JsonSlice { start, end })
}

fn json_root_value(bytes: &[u8]) -> Option<JsonSlice> {
    let start = skip_json_ws(bytes, 0);
    let end = skip_json_value(bytes, start)?;
    if skip_json_ws(bytes, end) != bytes.len() {
        return None;
    }
    Some(JsonSlice { start, end })
}

fn json_hex_digit(byte: u8) -> Option<u32> {
    match byte {
        b'0'..=b'9' => Some((byte - b'0') as u32),
        b'a'..=b'f' => Some((byte - b'a' + 10) as u32),
        b'A'..=b'F' => Some((byte - b'A' + 10) as u32),
        _ => None,
    }
}

fn json_decode_u16_escape(bytes: &[u8], mut cursor: usize, limit: usize) -> Option<(u16, usize)> {
    if cursor.checked_add(4)? > limit {
        return None;
    }

    let mut value = 0u32;
    for _ in 0..4 {
        value = (value << 4) | json_hex_digit(*bytes.get(cursor)?)?;
        cursor += 1;
    }
    Some((value as u16, cursor))
}

fn json_decode_string(bytes: &[u8], string_slice: JsonSlice) -> Option<Vec<u8>> {
    if bytes.get(string_slice.start) != Some(&b'"')
        || string_slice.end <= string_slice.start + 1
        || bytes.get(string_slice.end - 1) != Some(&b'"')
    {
        return None;
    }

    let mut cursor = string_slice.start + 1;
    let string_end = string_slice.end - 1;
    let mut decoded = Vec::with_capacity(string_slice.end - string_slice.start);
    while cursor < string_end {
        let mut value = bytes[cursor];
        if value == b'\\' {
            cursor += 1;
            value = match bytes.get(cursor)? {
                b'"' | b'\\' | b'/' => *bytes.get(cursor)?,
                b'b' => 0x08,
                b'f' => 0x0c,
                b'n' => b'\n',
                b'r' => b'\r',
                b't' => b'\t',
                b'u' => {
                    let (unit, next_cursor) = json_decode_u16_escape(bytes, cursor + 1, string_end)?;
                    let codepoint = if (0xD800..=0xDBFF).contains(&unit) {
                        if bytes.get(next_cursor) != Some(&b'\\') || bytes.get(next_cursor + 1) != Some(&b'u') {
                            return None;
                        }
                        let (low, after_low) = json_decode_u16_escape(bytes, next_cursor + 2, string_end)?;
                        if !(0xDC00..=0xDFFF).contains(&low) {
                            return None;
                        }
                        cursor = after_low;
                        0x10000 + ((((unit as u32) - 0xD800) << 10) | ((low as u32) - 0xDC00))
                    } else if (0xDC00..=0xDFFF).contains(&unit) {
                        return None;
                    } else {
                        cursor = next_cursor;
                        unit as u32
                    };
                    let character = char::from_u32(codepoint)?;
                    let mut buffer = [0u8; 4];
                    decoded.extend_from_slice(character.encode_utf8(&mut buffer).as_bytes());
                    continue;
                }
                _ => return None,
            };
        }
        decoded.push(value);
        cursor += 1;
    }

    Some(decoded)
}

fn json_string_equals(bytes: &[u8], string_slice: JsonSlice, expected: &str) -> bool {
    json_decode_string(bytes, string_slice)
        .map(|decoded| decoded == expected.as_bytes())
        .unwrap_or(false)
}

fn json_is_null(bytes: &[u8], value_slice: JsonSlice) -> bool {
    bytes.get(value_slice.start..value_slice.end) == Some(b"null".as_slice())
}

fn json_object_lookup(bytes: &[u8], object: JsonSlice, key: &str) -> Option<JsonSlice> {
    if bytes.get(object.start) != Some(&b'{') {
        return None;
    }

    let mut cursor = skip_json_ws(bytes, object.start + 1);
    if cursor >= object.end || bytes.get(cursor) == Some(&b'}') {
        return None;
    }

    while cursor < object.end {
        let key_end = skip_json_string(bytes, cursor)?;
        let key_slice = JsonSlice {
            start: cursor,
            end: key_end,
        };
        cursor = skip_json_ws(bytes, key_end);
        if bytes.get(cursor) != Some(&b':') {
            return None;
        }

        let value_start = skip_json_ws(bytes, cursor + 1);
        let value_end = skip_json_value(bytes, value_start)?;
        if json_string_equals(bytes, key_slice, key) {
            return Some(JsonSlice {
                start: value_start,
                end: value_end,
            });
        }

        cursor = skip_json_ws(bytes, value_end);
        match bytes.get(cursor) {
            Some(b'}') => break,
            Some(b',') => cursor = skip_json_ws(bytes, cursor + 1),
            _ => return None,
        }
    }

    None
}

fn json_array_length(bytes: &[u8], array_slice: JsonSlice) -> usize {
    if bytes.get(array_slice.start) != Some(&b'[') {
        return 0;
    }

    let mut cursor = skip_json_ws(bytes, array_slice.start + 1);
    if cursor >= array_slice.end || bytes.get(cursor) == Some(&b']') {
        return 0;
    }

    let mut count = 0usize;
    while cursor < array_slice.end {
        let value_end = match skip_json_value(bytes, cursor) {
            Some(value_end) => value_end,
            None => return 0,
        };
        count += 1;
        cursor = skip_json_ws(bytes, value_end);
        match bytes.get(cursor) {
            Some(b']') => return count,
            Some(b',') => cursor = skip_json_ws(bytes, cursor + 1),
            _ => return 0,
        }
    }

    0
}

#[cfg(test)]
fn json_array_item(bytes: &[u8], array_slice: JsonSlice, item_index: usize) -> Option<JsonSlice> {
    if bytes.get(array_slice.start) != Some(&b'[') {
        return None;
    }

    let mut cursor = skip_json_ws(bytes, array_slice.start + 1);
    if cursor >= array_slice.end || bytes.get(cursor) == Some(&b']') {
        return None;
    }

    let mut current_index = 0usize;
    while cursor < array_slice.end {
        let value_end = skip_json_value(bytes, cursor)?;
        if current_index == item_index {
            return Some(JsonSlice {
                start: cursor,
                end: value_end,
            });
        }
        current_index += 1;
        cursor = skip_json_ws(bytes, value_end);
        match bytes.get(cursor) {
            Some(b']') => return None,
            Some(b',') => cursor = skip_json_ws(bytes, cursor + 1),
            _ => return None,
        }
    }

    None
}

fn json_array_items(bytes: &[u8], array_slice: JsonSlice) -> Option<Vec<JsonSlice>> {
    if bytes.get(array_slice.start) != Some(&b'[') {
        return None;
    }

    let mut cursor = skip_json_ws(bytes, array_slice.start + 1);
    if cursor >= array_slice.end || bytes.get(cursor) == Some(&b']') {
        return Some(Vec::new());
    }

    let mut items = Vec::new();
    while cursor < array_slice.end {
        let value_end = skip_json_value(bytes, cursor)?;
        items.push(JsonSlice {
            start: cursor,
            end: value_end,
        });
        cursor = skip_json_ws(bytes, value_end);
        match bytes.get(cursor) {
            Some(b']') => return Some(items),
            Some(b',') => cursor = skip_json_ws(bytes, cursor + 1),
            _ => return None,
        }
    }

    None
}

fn json_array_contains_string(bytes: &[u8], array_slice: JsonSlice, expected: &str) -> bool {
    if bytes.get(array_slice.start) != Some(&b'[') {
        return false;
    }

    let mut cursor = skip_json_ws(bytes, array_slice.start + 1);
    if cursor >= array_slice.end || bytes.get(cursor) == Some(&b']') {
        return false;
    }

    while cursor < array_slice.end {
        let value_end = match skip_json_value(bytes, cursor) {
            Some(value_end) => value_end,
            None => return false,
        };
        if json_string_equals(bytes, JsonSlice { start: cursor, end: value_end }, expected) {
            return true;
        }
        cursor = skip_json_ws(bytes, value_end);
        match bytes.get(cursor) {
            Some(b']') => return false,
            Some(b',') => cursor = skip_json_ws(bytes, cursor + 1),
            _ => return false,
        }
    }

    false
}

fn parse_schema_type_text(value: &str) -> Option<ClaspRtSchemaType> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    if value == "Int" {
        return Some(ClaspRtSchemaType::Int);
    }
    if value == "Bool" {
        return Some(ClaspRtSchemaType::Bool);
    }
    if value == "Str" {
        return Some(ClaspRtSchemaType::Str);
    }
    if value.starts_with('[') && value.ends_with(']') {
        let inner = &value[1..value.len() - 1];
        return parse_schema_type_text(inner).map(|item| ClaspRtSchemaType::List(Box::new(item)));
    }
    Some(ClaspRtSchemaType::Named(value.to_owned()))
}

fn load_record_schemas(bytes: &[u8], abi: JsonSlice) -> Option<HashMap<String, ClaspRtRecordSchema>> {
    let record_layouts = json_object_lookup(bytes, abi, "recordLayouts")?;
    let mut schemas = HashMap::new();
    for layout in json_array_items(bytes, record_layouts)? {
        let name = json_string_owned(bytes, json_object_lookup(bytes, layout, "name")?)?;
        let fields_value = json_object_lookup(bytes, layout, "fields")?;
        let field_values = json_array_items(bytes, fields_value)?;
        let mut fields = Vec::with_capacity(field_values.len());
        for field in field_values {
            let field_name = json_string_owned(bytes, json_object_lookup(bytes, field, "name")?)?;
            let field_type = json_string_owned(bytes, json_object_lookup(bytes, field, "type")?)?;
            let field_typ = parse_schema_type_text(&field_type)?;
            fields.push(ClaspRtRecordFieldSchema { name: field_name, typ: field_typ });
        }
        schemas.insert(name, ClaspRtRecordSchema { fields });
    }
    Some(schemas)
}

fn load_variant_schemas(bytes: &[u8], abi: JsonSlice) -> Option<HashMap<String, ClaspRtVariantSchema>> {
    let variant_layouts = json_object_lookup(bytes, abi, "variantLayouts")?;
    let mut schemas = HashMap::new();
    for layout in json_array_items(bytes, variant_layouts)? {
        let type_name = json_string_owned(bytes, json_object_lookup(bytes, layout, "name")?)?;
        let constructors_value = json_object_lookup(bytes, layout, "constructors")?;
        let mut constructors = HashMap::new();
        let mut constructor_names = Vec::new();
        for constructor in json_array_items(bytes, constructors_value)? {
            let constructor_name = json_string_owned(bytes, json_object_lookup(bytes, constructor, "name")?)?;
            let payloads_value = json_object_lookup(bytes, constructor, "payloads")?;
            let payload_values = json_array_items(bytes, payloads_value)?;
            let mut payloads = Vec::with_capacity(payload_values.len());
            for payload in payload_values {
                let payload_type = json_string_owned(bytes, json_object_lookup(bytes, payload, "type")?)?;
                payloads.push(parse_schema_type_text(&payload_type)?);
            }
            constructor_names.push(constructor_name.clone());
            constructors.insert(
                constructor_name.clone(),
                ClaspRtVariantConstructorSchema {
                    name: constructor_name,
                    payloads,
                },
            );
        }
        schemas.insert(type_name, ClaspRtVariantSchema { constructors, constructor_names });
    }
    Some(schemas)
}

fn load_route_boundaries(bytes: &[u8], runtime: JsonSlice) -> Option<Vec<ClaspRtNativeRouteBoundary>> {
    let boundaries = json_object_lookup(bytes, runtime, "boundaries")?;
    let mut routes = Vec::new();
    for boundary in json_array_items(bytes, boundaries)? {
        let kind = json_string_owned(bytes, json_object_lookup(bytes, boundary, "kind")?)?;
        if kind != "route" {
            continue;
        }
        let name = json_string_owned(bytes, json_object_lookup(bytes, boundary, "name")?)?;
        let method = json_string_owned(bytes, json_object_lookup(bytes, boundary, "method")?)?;
        let path = json_string_owned(bytes, json_object_lookup(bytes, boundary, "path")?)?;
        let request_type = json_string_owned(bytes, json_object_lookup(bytes, boundary, "request")?)?;
        let response_type = json_string_owned(bytes, json_object_lookup(bytes, boundary, "response")?)?;
        let response_kind = json_string_owned(bytes, json_object_lookup(bytes, boundary, "responseKind")?)?;
        let handler = json_object_lookup(bytes, boundary, "handler")
            .and_then(|value| json_string_owned(bytes, value))
            .unwrap_or_default();
        routes.push(ClaspRtNativeRouteBoundary {
            name,
            method,
            path,
            request_type,
            response_type,
            response_kind,
            handler,
        });
    }
    Some(routes)
}

unsafe fn release_owned_headers(values: Vec<*mut ClaspRtHeader>) {
    for value in values {
        release_header(null_mut(), value);
    }
}

unsafe fn release_owned_named_headers(values: Vec<(String, *mut ClaspRtHeader)>) {
    for (_, value) in values {
        release_header(null_mut(), value);
    }
}

fn decode_subject(field_name: Option<&str>) -> &str {
    field_name.unwrap_or("value")
}

fn variant_enum_wire_tags(variant_schema: &ClaspRtVariantSchema) -> Option<Vec<String>> {
    let mut tags = Vec::with_capacity(variant_schema.constructor_names.len());
    for constructor_name in &variant_schema.constructor_names {
        let constructor = variant_schema.constructors.get(constructor_name)?;
        if !constructor.payloads.is_empty() {
            return None;
        }
        tags.push(normalize_variant_wire_tag(&constructor.name));
    }
    Some(tags)
}

fn decode_expected_message(
    image: &ClaspRtNativeModuleImage,
    typ: &ClaspRtSchemaType,
    field_name: Option<&str>,
) -> String {
    let subject = decode_subject(field_name);
    match typ {
        ClaspRtSchemaType::Int => format!("{subject} must be an integer"),
        ClaspRtSchemaType::Bool => format!("{subject} must be a boolean"),
        ClaspRtSchemaType::Str => format!("{subject} must be a string"),
        ClaspRtSchemaType::List(_) => format!("{subject} must be a list"),
        ClaspRtSchemaType::Named(name) => {
            if image.record_schemas.contains_key(name) {
                format!("{subject} must be an object")
            } else if let Some(variant_schema) = image.variant_schemas.get(name) {
                if let Some(tags) = variant_enum_wire_tags(variant_schema) {
                    format!("{subject} must be one of: {}", tags.join(", "))
                } else {
                    format!("{subject} must be a {name} value")
                }
            } else {
                format!("{subject} must be a {name} value")
            }
        }
    }
}

unsafe fn decode_named_json_to_runtime(
    image: &ClaspRtNativeModuleImage,
    name: &str,
    bytes: &[u8],
    value_slice: JsonSlice,
    field_name: Option<&str>,
) -> Result<*mut ClaspRtHeader, ClaspRtDecodeError> {
    match name {
        "Int" => json_i64_value(bytes, value_slice)
            .map(|raw| clasp_rt_build_int_header(raw))
            .ok_or_else(|| ClaspRtDecodeError::new(decode_expected_message(image, &ClaspRtSchemaType::Int, field_name))),
        "Bool" => json_bool_value(bytes, value_slice)
            .map(|raw| clasp_rt_build_bool_header(raw))
            .ok_or_else(|| ClaspRtDecodeError::new(decode_expected_message(image, &ClaspRtSchemaType::Bool, field_name))),
        "Str" => {
            let decoded = json_string_value(bytes, value_slice);
            if decoded.is_null() {
                Err(ClaspRtDecodeError::new(decode_expected_message(
                    image,
                    &ClaspRtSchemaType::Str,
                    field_name,
                )))
            } else {
                Ok(decoded as *mut ClaspRtHeader)
            }
        }
        other => {
            if let Some(record_schema) = image.record_schemas.get(other) {
                if bytes.get(value_slice.start) != Some(&b'{') {
                    return Err(ClaspRtDecodeError::new(format!(
                        "{} must be an object",
                        decode_subject(field_name)
                    )));
                }
                let mut fields = Vec::with_capacity(record_schema.fields.len());
                for field in &record_schema.fields {
                    let Some(field_slice) = json_object_lookup(bytes, value_slice, &field.name) else {
                        release_owned_named_headers(fields);
                        return Err(ClaspRtDecodeError::new(decode_expected_message(
                            image,
                            &field.typ,
                            Some(&field.name),
                        )));
                    };
                    let field_value = match decode_json_to_runtime_value(
                        image,
                        &field.typ,
                        bytes,
                        field_slice,
                        Some(&field.name),
                    ) {
                        Ok(field_value) => field_value,
                        Err(error) => {
                            release_owned_named_headers(fields);
                            return Err(error);
                        }
                    };
                    fields.push((field.name.clone(), field_value));
                }
                return Ok(clasp_rt_build_record_header(other, fields));
            }

            if let Some(variant_schema) = image.variant_schemas.get(other) {
                if bytes.get(value_slice.start) == Some(&b'"') {
                    let tag = json_string_owned(bytes, value_slice).ok_or_else(|| {
                        ClaspRtDecodeError::new(decode_expected_message(
                            image,
                            &ClaspRtSchemaType::Named(other.to_owned()),
                            field_name,
                        ))
                    })?;
                    let constructor = variant_constructor_for_wire_tag(variant_schema, &tag).ok_or_else(|| {
                        ClaspRtDecodeError::new(decode_expected_message(
                            image,
                            &ClaspRtSchemaType::Named(other.to_owned()),
                            field_name,
                        ))
                    })?;
                    if !constructor.payloads.is_empty() {
                        return Err(ClaspRtDecodeError::new(format!(
                            "{} must be a {other} value",
                            decode_subject(field_name)
                        )));
                    }
                    return Ok(clasp_rt_build_variant_header(&constructor.name, Vec::new()));
                }

                if bytes.get(value_slice.start) != Some(&b'{') {
                    return Err(ClaspRtDecodeError::new(decode_expected_message(
                        image,
                        &ClaspRtSchemaType::Named(other.to_owned()),
                        field_name,
                    )));
                }
                let tag_slice = json_object_lookup(bytes, value_slice, "$tag").ok_or_else(|| {
                    ClaspRtDecodeError::new(decode_expected_message(
                        image,
                        &ClaspRtSchemaType::Named(other.to_owned()),
                        field_name,
                    ))
                })?;
                let tag = json_string_owned(bytes, tag_slice).ok_or_else(|| {
                    ClaspRtDecodeError::new(decode_expected_message(
                        image,
                        &ClaspRtSchemaType::Named(other.to_owned()),
                        field_name,
                    ))
                })?;
                let constructor = variant_constructor_for_wire_tag(variant_schema, &tag).ok_or_else(|| {
                    ClaspRtDecodeError::new(decode_expected_message(
                        image,
                        &ClaspRtSchemaType::Named(other.to_owned()),
                        field_name,
                    ))
                })?;
                let mut payloads = Vec::with_capacity(constructor.payloads.len());
                for (index, payload_type) in constructor.payloads.iter().enumerate() {
                    let payload_key = format!("${index}");
                    let Some(payload_slice) = json_object_lookup(bytes, value_slice, &payload_key) else {
                        release_owned_headers(payloads);
                        return Err(ClaspRtDecodeError::new(decode_expected_message(
                            image,
                            payload_type,
                            Some(&payload_key),
                        )));
                    };
                    let payload_value = match decode_json_to_runtime_value(
                        image,
                        payload_type,
                        bytes,
                        payload_slice,
                        Some(&payload_key),
                    ) {
                        Ok(payload_value) => payload_value,
                        Err(error) => {
                            release_owned_headers(payloads);
                            return Err(error);
                        }
                    };
                    payloads.push(payload_value);
                }
                return Ok(clasp_rt_build_variant_header(&constructor.name, payloads));
            }

            Err(ClaspRtDecodeError::new(format!(
                "{} uses unknown schema type {other}",
                decode_subject(field_name)
            )))
        }
    }
}

unsafe fn decode_json_to_runtime_value(
    image: &ClaspRtNativeModuleImage,
    typ: &ClaspRtSchemaType,
    bytes: &[u8],
    value_slice: JsonSlice,
    field_name: Option<&str>,
) -> Result<*mut ClaspRtHeader, ClaspRtDecodeError> {
    match typ {
        ClaspRtSchemaType::Int => json_i64_value(bytes, value_slice)
            .map(|raw| clasp_rt_build_int_header(raw))
            .ok_or_else(|| ClaspRtDecodeError::new(decode_expected_message(image, typ, field_name))),
        ClaspRtSchemaType::Bool => json_bool_value(bytes, value_slice)
            .map(|raw| clasp_rt_build_bool_header(raw))
            .ok_or_else(|| ClaspRtDecodeError::new(decode_expected_message(image, typ, field_name))),
        ClaspRtSchemaType::Str => {
            let decoded = json_string_value(bytes, value_slice);
            if decoded.is_null() {
                Err(ClaspRtDecodeError::new(decode_expected_message(image, typ, field_name)))
            } else {
                Ok(decoded as *mut ClaspRtHeader)
            }
        }
        ClaspRtSchemaType::List(item_type) => {
            if bytes.get(value_slice.start) != Some(&b'[') {
                return Err(ClaspRtDecodeError::new(decode_expected_message(image, typ, field_name)));
            }
            let item_slices = json_array_items(bytes, value_slice)
                .ok_or_else(|| ClaspRtDecodeError::new(decode_expected_message(image, typ, field_name)))?;
            let mut decoded_items = Vec::with_capacity(item_slices.len());
            for (index, item_slice) in item_slices.into_iter().enumerate() {
                let item_field = format!("{}[{index}]", decode_subject(field_name));
                let decoded_item = match decode_json_to_runtime_value(
                    image,
                    item_type,
                    bytes,
                    item_slice,
                    Some(&item_field),
                ) {
                    Ok(decoded_item) => decoded_item,
                    Err(error) => {
                        release_owned_headers(decoded_items);
                        return Err(error);
                    }
                };
                decoded_items.push(decoded_item);
            }
            Ok(clasp_rt_build_list_header(decoded_items))
        }
        ClaspRtSchemaType::Named(name) => decode_named_json_to_runtime(image, name, bytes, value_slice, field_name),
    }
}

unsafe fn invalid_native_image_result() -> *mut ClaspRtResultString {
    clasp_rt_result_err_string(clasp_rt_string_from_utf8(b"invalid_native_image\0".as_ptr() as *const c_char))
}

unsafe fn missing_native_dispatch_result() -> *mut ClaspRtResultString {
    clasp_rt_result_err_string(clasp_rt_string_from_utf8(b"missing_dispatch_target\0".as_ptr() as *const c_char))
}

unsafe fn missing_native_entrypoint_result() -> *mut ClaspRtResultString {
    clasp_rt_result_err_string(clasp_rt_string_from_utf8(b"missing_native_entrypoint\0".as_ptr() as *const c_char))
}

unsafe fn native_route_error_result(message: &str) -> *mut ClaspRtResultString {
    clasp_rt_result_err_string(build_runtime_string(message.as_bytes()))
}

unsafe fn json_string_value(bytes: &[u8], string_slice: JsonSlice) -> *mut ClaspRtString {
    match json_decode_string(bytes, string_slice) {
        Some(decoded) => build_runtime_string(&decoded),
        None => null_mut(),
    }
}

unsafe fn json_optional_string_value(bytes: &[u8], value_slice: JsonSlice) -> *mut ClaspRtString {
    if json_is_null(bytes, value_slice) {
        null_mut()
    } else {
        json_string_value(bytes, value_slice)
    }
}

fn json_string_owned(bytes: &[u8], string_slice: JsonSlice) -> Option<String> {
    json_decode_string(bytes, string_slice).and_then(|decoded| String::from_utf8(decoded).ok())
}

fn json_bool_value(bytes: &[u8], value_slice: JsonSlice) -> Option<bool> {
    match bytes.get(value_slice.start..value_slice.end) {
        Some(b"true") => Some(true),
        Some(b"false") => Some(false),
        _ => None,
    }
}

fn json_i64_value(bytes: &[u8], value_slice: JsonSlice) -> Option<i64> {
    std::str::from_utf8(bytes.get(value_slice.start..value_slice.end)?)
        .ok()?
        .parse::<i64>()
        .ok()
}

fn trim_ascii(bytes: &[u8]) -> &[u8] {
    let mut start = 0usize;
    let mut end = bytes.len();
    while start < end && bytes[start].is_ascii_whitespace() {
        start += 1;
    }
    while end > start && bytes[end - 1].is_ascii_whitespace() {
        end -= 1;
    }
    &bytes[start..end]
}

fn split_top_level_once(bytes: &[u8], delimiter: u8) -> Option<(&[u8], &[u8])> {
    let mut paren_depth = 0usize;
    let mut bracket_depth = 0usize;
    let mut brace_depth = 0usize;
    let mut in_string = false;
    let mut escape = false;
    for (index, byte) in bytes.iter().enumerate() {
        if in_string {
            if escape {
                escape = false;
            } else if *byte == b'\\' {
                escape = true;
            } else if *byte == b'"' {
                in_string = false;
            }
            continue;
        }

        match *byte {
            b'"' => in_string = true,
            b'(' => paren_depth += 1,
            b')' => paren_depth = paren_depth.saturating_sub(1),
            b'[' => bracket_depth += 1,
            b']' => bracket_depth = bracket_depth.saturating_sub(1),
            b'{' => brace_depth += 1,
            b'}' => brace_depth = brace_depth.saturating_sub(1),
            _ => {}
        }

        if *byte == delimiter && paren_depth == 0 && bracket_depth == 0 && brace_depth == 0 {
            return Some((&bytes[..index], &bytes[index + 1..]));
        }
    }
    None
}

fn split_top_level_items(bytes: &[u8]) -> Option<Vec<&[u8]>> {
    let bytes = trim_ascii(bytes);
    if bytes.is_empty() {
        return Some(Vec::new());
    }

    let mut items = Vec::new();
    let mut cursor = 0usize;
    let mut item_start = 0usize;
    let mut paren_depth = 0usize;
    let mut bracket_depth = 0usize;
    let mut brace_depth = 0usize;
    let mut in_string = false;
    let mut escape = false;

    while cursor < bytes.len() {
        let byte = bytes[cursor];
        if in_string {
            if escape {
                escape = false;
            } else if byte == b'\\' {
                escape = true;
            } else if byte == b'"' {
                in_string = false;
            }
            cursor += 1;
            continue;
        }

        match byte {
            b'"' => in_string = true,
            b'(' => paren_depth += 1,
            b')' => paren_depth = paren_depth.saturating_sub(1),
            b'[' => bracket_depth += 1,
            b']' => bracket_depth = bracket_depth.saturating_sub(1),
            b'{' => brace_depth += 1,
            b'}' => brace_depth = brace_depth.saturating_sub(1),
            b',' if paren_depth == 0 && bracket_depth == 0 && brace_depth == 0 => {
                items.push(trim_ascii(&bytes[item_start..cursor]));
                item_start = cursor + 1;
            }
            _ => {}
        }
        cursor += 1;
    }

    items.push(trim_ascii(&bytes[item_start..]));
    Some(items)
}

fn parse_local_name(bytes: &[u8]) -> Option<String> {
    let bytes = trim_ascii(bytes);
    if !(bytes.starts_with(b"local(") && bytes.ends_with(b")")) {
        return None;
    }
    String::from_utf8(trim_ascii(&bytes[6..bytes.len() - 1]).to_vec()).ok()
}

fn parse_interpreted_expr_text(bytes: &[u8]) -> Option<ClaspRtInterpretedExpr> {
    let bytes = trim_ascii(bytes);
    if bytes.starts_with(b"string(") && bytes.ends_with(b")") {
        let literal_bytes = trim_ascii(&bytes[7..bytes.len() - 1]);
        let decoded = json_decode_string(
            literal_bytes,
            JsonSlice {
                start: 0,
                end: literal_bytes.len(),
            },
        )?;
        return Some(ClaspRtInterpretedExpr::StringLiteral(decoded));
    }

    if let Some(name) = parse_local_name(bytes) {
        return Some(ClaspRtInterpretedExpr::Local(name));
    }

    if bytes.starts_with(b"return(") && bytes.ends_with(b")") {
        return parse_interpreted_expr_text(&bytes[7..bytes.len() - 1])
            .map(|expr| ClaspRtInterpretedExpr::Return(Box::new(expr)));
    }

    if bytes.starts_with(b"call(") && bytes.ends_with(b")") {
        let inner = trim_ascii(&bytes[5..bytes.len() - 1]);
        let (callee_bytes, args_bytes) = split_top_level_once(inner, b',')?;
        let callee_name = parse_local_name(callee_bytes)?;
        let args_bytes = trim_ascii(args_bytes);
        if !(args_bytes.starts_with(b"[") && args_bytes.ends_with(b"]")) {
            return None;
        }
        let arg_slices = split_top_level_items(&args_bytes[1..args_bytes.len() - 1])?;
        let mut args = Vec::with_capacity(arg_slices.len());
        for arg_bytes in arg_slices {
            args.push(parse_interpreted_expr_text(arg_bytes)?);
        }
        return Some(ClaspRtInterpretedExpr::CallLocal(callee_name, args));
    }

    None
}

fn parse_interpreted_expr_json(bytes: &[u8], expr_slice: JsonSlice) -> Option<ClaspRtInterpretedExpr> {
    let kind_slice = json_object_lookup(bytes, expr_slice, "kind")?;

    if json_string_equals(bytes, kind_slice, "int") {
        let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
        return json_i64_value(bytes, value_slice).map(ClaspRtInterpretedExpr::IntLiteral);
    }

    if json_string_equals(bytes, kind_slice, "bool") {
        let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
        return json_bool_value(bytes, value_slice).map(ClaspRtInterpretedExpr::BoolLiteral);
    }

    if json_string_equals(bytes, kind_slice, "string") {
        let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
        let decoded = json_decode_string(bytes, value_slice)?;
        return Some(ClaspRtInterpretedExpr::StringLiteral(decoded));
    }

    if json_string_equals(bytes, kind_slice, "local") {
        let name_slice = json_object_lookup(bytes, expr_slice, "name")?;
        let name = json_string_owned(bytes, name_slice)?;
        return Some(ClaspRtInterpretedExpr::Local(name));
    }

    if json_string_equals(bytes, kind_slice, "list") {
        let items_slice = json_object_lookup(bytes, expr_slice, "items")?;
        let item_slices = json_array_items(bytes, items_slice)?;
        let mut items = Vec::with_capacity(item_slices.len());
        for item_slice in item_slices {
            items.push(parse_interpreted_expr_json(bytes, item_slice)?);
        }
        return Some(ClaspRtInterpretedExpr::List(items));
    }

    if json_string_equals(bytes, kind_slice, "if") {
        let condition_slice = json_object_lookup(bytes, expr_slice, "condition")?;
        let then_slice = json_object_lookup(bytes, expr_slice, "thenBranch")?;
        let else_slice = json_object_lookup(bytes, expr_slice, "elseBranch")?;
        return Some(ClaspRtInterpretedExpr::If(
            Box::new(parse_interpreted_expr_json(bytes, condition_slice)?),
            Box::new(parse_interpreted_expr_json(bytes, then_slice)?),
            Box::new(parse_interpreted_expr_json(bytes, else_slice)?),
        ));
    }

    if json_string_equals(bytes, kind_slice, "return") {
        let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
        return parse_interpreted_expr_json(bytes, value_slice)
            .map(|expr| ClaspRtInterpretedExpr::Return(Box::new(expr)));
    }

    if json_string_equals(bytes, kind_slice, "compare") {
        let op_slice = json_object_lookup(bytes, expr_slice, "op")?;
        let left_slice = json_object_lookup(bytes, expr_slice, "left")?;
        let right_slice = json_object_lookup(bytes, expr_slice, "right")?;
        let op = if json_string_equals(bytes, op_slice, "eq") {
            ClaspRtInterpretedCompareOp::Eq
        } else if json_string_equals(bytes, op_slice, "ne") {
            ClaspRtInterpretedCompareOp::Ne
        } else if json_string_equals(bytes, op_slice, "lt") {
            ClaspRtInterpretedCompareOp::Lt
        } else if json_string_equals(bytes, op_slice, "le") {
            ClaspRtInterpretedCompareOp::Le
        } else if json_string_equals(bytes, op_slice, "gt") {
            ClaspRtInterpretedCompareOp::Gt
        } else if json_string_equals(bytes, op_slice, "ge") {
            ClaspRtInterpretedCompareOp::Ge
        } else {
            return None;
        };
        return Some(ClaspRtInterpretedExpr::Compare(
            op,
            Box::new(parse_interpreted_expr_json(bytes, left_slice)?),
            Box::new(parse_interpreted_expr_json(bytes, right_slice)?),
        ));
    }

    if json_string_equals(bytes, kind_slice, "call") {
        let callee_slice = json_object_lookup(bytes, expr_slice, "callee")?;
        let args_slice = json_object_lookup(bytes, expr_slice, "args")?;
        let callee_name = match parse_interpreted_expr_json(bytes, callee_slice)? {
            ClaspRtInterpretedExpr::Local(name) => name,
            _ => return None,
        };
        let arg_slices = json_array_items(bytes, args_slice)?;
        let mut args = Vec::with_capacity(arg_slices.len());
        for arg_slice in arg_slices {
            args.push(parse_interpreted_expr_json(bytes, arg_slice)?);
        }
        return Some(ClaspRtInterpretedExpr::CallLocal(callee_name, args));
    }

    if json_string_equals(bytes, kind_slice, "match") {
        let scrutinee_slice = json_object_lookup(bytes, expr_slice, "scrutinee")?;
        let branches_slice = json_object_lookup(bytes, expr_slice, "branches")?;
        let scrutinee = parse_interpreted_expr_json(bytes, scrutinee_slice)?;
        let branch_slices = json_array_items(bytes, branches_slice)?;
        let mut branches = Vec::with_capacity(branch_slices.len());
        for branch_slice in branch_slices {
            branches.push(parse_interpreted_match_branch_json(bytes, branch_slice)?);
        }
        return Some(ClaspRtInterpretedExpr::Match(Box::new(scrutinee), branches));
    }

    if json_string_equals(bytes, kind_slice, "let") {
        let mutability_slice = json_object_lookup(bytes, expr_slice, "mutability")?;
        let name_slice = json_object_lookup(bytes, expr_slice, "name")?;
        let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
        let body_slice = json_object_lookup(bytes, expr_slice, "body")?;
        let name = json_string_owned(bytes, name_slice)?;
        let is_mutable = json_string_equals(bytes, mutability_slice, "mutable");
        let value = parse_interpreted_expr_json(bytes, value_slice)?;
        let body = parse_interpreted_expr_json(bytes, body_slice)?;
        return Some(ClaspRtInterpretedExpr::Let(
            is_mutable,
            name,
            Box::new(value),
            Box::new(body),
        ));
    }

    if json_string_equals(bytes, kind_slice, "assign") {
        let name_slice = json_object_lookup(bytes, expr_slice, "name")?;
        let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
        let body_slice = json_object_lookup(bytes, expr_slice, "body")?;
        let name = json_string_owned(bytes, name_slice)?;
        let value = parse_interpreted_expr_json(bytes, value_slice)?;
        let body = parse_interpreted_expr_json(bytes, body_slice)?;
        return Some(ClaspRtInterpretedExpr::Assign(name, Box::new(value), Box::new(body)));
    }

    if json_string_equals(bytes, kind_slice, "for_each") {
        let name_slice = json_object_lookup(bytes, expr_slice, "name")?;
        let iterable_slice = json_object_lookup(bytes, expr_slice, "iterable")?;
        let loop_body_slice = json_object_lookup(bytes, expr_slice, "loopBody")?;
        let body_slice = json_object_lookup(bytes, expr_slice, "body")?;
        let name = json_string_owned(bytes, name_slice)?;
        let iterable = parse_interpreted_expr_json(bytes, iterable_slice)?;
        let loop_body = parse_interpreted_expr_json(bytes, loop_body_slice)?;
        let body = parse_interpreted_expr_json(bytes, body_slice)?;
        return Some(ClaspRtInterpretedExpr::ForEach(
            name,
            Box::new(iterable),
            Box::new(loop_body),
            Box::new(body),
        ));
    }

    if json_string_equals(bytes, kind_slice, "construct") {
        let name_slice = json_object_lookup(bytes, expr_slice, "name")?;
        let args_slice = json_object_lookup(bytes, expr_slice, "args")?;
        let name = json_string_owned(bytes, name_slice)?;
        let arg_slices = json_array_items(bytes, args_slice)?;
        let mut args = Vec::with_capacity(arg_slices.len());
        for arg_slice in arg_slices {
            args.push(parse_interpreted_expr_json(bytes, arg_slice)?);
        }
        return Some(ClaspRtInterpretedExpr::Construct(name, args));
    }

    if json_string_equals(bytes, kind_slice, "record") {
        let record_name_slice = json_object_lookup(bytes, expr_slice, "recordName")?;
        let fields_slice = json_object_lookup(bytes, expr_slice, "fields")?;
        let record_name = json_string_owned(bytes, record_name_slice)?;
        let field_slices = json_array_items(bytes, fields_slice)?;
        let mut fields = Vec::with_capacity(field_slices.len());
        for field_slice in field_slices {
            fields.push(parse_interpreted_record_field_json(bytes, field_slice)?);
        }
        return Some(ClaspRtInterpretedExpr::Record(record_name, fields));
    }

    if json_string_equals(bytes, kind_slice, "field_access") {
        let record_name_slice = json_object_lookup(bytes, expr_slice, "recordName")?;
        let target_slice = json_object_lookup(bytes, expr_slice, "target")?;
        let field_name_slice = json_object_lookup(bytes, expr_slice, "fieldName")?;
        let record_name = json_string_owned(bytes, record_name_slice)?;
        let target = parse_interpreted_expr_json(bytes, target_slice)?;
        let field_name = json_string_owned(bytes, field_name_slice)?;
        return Some(ClaspRtInterpretedExpr::FieldAccess(record_name, Box::new(target), field_name));
    }

    if json_string_equals(bytes, kind_slice, "intrinsic") {
        let name_slice = json_object_lookup(bytes, expr_slice, "name")?;
        if json_string_equals(bytes, name_slice, "list.append") {
            let left_slice = json_object_lookup(bytes, expr_slice, "left")?;
            let right_slice = json_object_lookup(bytes, expr_slice, "right")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ListAppend(
                    Box::new(parse_interpreted_expr_json(bytes, left_slice)?),
                    Box::new(parse_interpreted_expr_json(bytes, right_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "list.prepend") {
            let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
            let values_slice = json_object_lookup(bytes, expr_slice, "values")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ListPrepend(
                    Box::new(parse_interpreted_expr_json(bytes, value_slice)?),
                    Box::new(parse_interpreted_expr_json(bytes, values_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "list.reverse") {
            let values_slice = json_object_lookup(bytes, expr_slice, "values")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ListReverse(Box::new(parse_interpreted_expr_json(
                    bytes,
                    values_slice,
                )?)),
            ));
        }
        if json_string_equals(bytes, name_slice, "list.concat") {
            let values_slice = json_object_lookup(bytes, expr_slice, "values")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ListConcat(Box::new(parse_interpreted_expr_json(
                    bytes,
                    values_slice,
                )?)),
            ));
        }
        if json_string_equals(bytes, name_slice, "length") {
            let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::Length(Box::new(parse_interpreted_expr_json(
                    bytes,
                    value_slice,
                )?)),
            ));
        }
        if json_string_equals(bytes, name_slice, "list.map") {
            let callee_slice = json_object_lookup(bytes, expr_slice, "callee")?;
            let values_slice = json_object_lookup(bytes, expr_slice, "values")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ListMap(
                    json_string_owned(bytes, callee_slice)?,
                    Box::new(parse_interpreted_expr_json(bytes, values_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "list.filter") {
            let callee_slice = json_object_lookup(bytes, expr_slice, "callee")?;
            let values_slice = json_object_lookup(bytes, expr_slice, "values")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ListFilter(
                    json_string_owned(bytes, callee_slice)?,
                    Box::new(parse_interpreted_expr_json(bytes, values_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "list.find") {
            let callee_slice = json_object_lookup(bytes, expr_slice, "callee")?;
            let values_slice = json_object_lookup(bytes, expr_slice, "values")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ListFind(
                    json_string_owned(bytes, callee_slice)?,
                    Box::new(parse_interpreted_expr_json(bytes, values_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "list.any") {
            let callee_slice = json_object_lookup(bytes, expr_slice, "callee")?;
            let values_slice = json_object_lookup(bytes, expr_slice, "values")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ListAny(
                    json_string_owned(bytes, callee_slice)?,
                    Box::new(parse_interpreted_expr_json(bytes, values_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "list.all") {
            let callee_slice = json_object_lookup(bytes, expr_slice, "callee")?;
            let values_slice = json_object_lookup(bytes, expr_slice, "values")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ListAll(
                    json_string_owned(bytes, callee_slice)?,
                    Box::new(parse_interpreted_expr_json(bytes, values_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "list.fold") {
            let callee_slice = json_object_lookup(bytes, expr_slice, "callee")?;
            let initial_slice = json_object_lookup(bytes, expr_slice, "initial")?;
            let values_slice = json_object_lookup(bytes, expr_slice, "values")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ListFold(
                    json_string_owned(bytes, callee_slice)?,
                    Box::new(parse_interpreted_expr_json(bytes, initial_slice)?),
                    Box::new(parse_interpreted_expr_json(bytes, values_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "view.append") {
            let left_slice = json_object_lookup(bytes, expr_slice, "left")?;
            let right_slice = json_object_lookup(bytes, expr_slice, "right")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::ViewAppend(
                    Box::new(parse_interpreted_expr_json(bytes, left_slice)?),
                    Box::new(parse_interpreted_expr_json(bytes, right_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "encode") {
            let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::Encode(
                    Box::new(parse_interpreted_expr_json(bytes, value_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "decode") {
            let type_slice = json_object_lookup(bytes, expr_slice, "type")?;
            let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
            let target_type = parse_schema_type_text(&json_string_owned(bytes, type_slice)?)?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::Decode(
                    target_type,
                    Box::new(parse_interpreted_expr_json(bytes, value_slice)?),
                ),
            ));
        }
        if json_string_equals(bytes, name_slice, "tryDecode") {
            let type_slice = json_object_lookup(bytes, expr_slice, "type")?;
            let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
            let target_type = parse_schema_type_text(&json_string_owned(bytes, type_slice)?)?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::TryDecode(
                    target_type,
                    Box::new(parse_interpreted_expr_json(bytes, value_slice)?),
                ),
            ));
        }
    }

    None
}

fn parse_interpreted_match_branch_json(
    bytes: &[u8],
    branch_slice: JsonSlice,
) -> Option<ClaspRtInterpretedMatchBranch> {
    let tag_slice = json_object_lookup(bytes, branch_slice, "tag")?;
    let binders_slice = json_object_lookup(bytes, branch_slice, "binders")?;
    let body_slice = json_object_lookup(bytes, branch_slice, "body")?;
    let tag = json_string_owned(bytes, tag_slice)?;
    let body = parse_interpreted_expr_json(bytes, body_slice)?;
    let binder_slices = json_array_items(bytes, binders_slice)?;
    let mut binders = Vec::with_capacity(binder_slices.len());
    for binder_slice in binder_slices {
        binders.push(json_string_owned(bytes, binder_slice)?);
    }
    Some(ClaspRtInterpretedMatchBranch { tag, binders, body })
}

fn parse_interpreted_record_field_json(
    bytes: &[u8],
    field_slice: JsonSlice,
) -> Option<ClaspRtInterpretedRecordField> {
    let name_slice = json_object_lookup(bytes, field_slice, "name")?;
    let value_slice = json_object_lookup(bytes, field_slice, "value")?;
    let name = json_string_owned(bytes, name_slice)?;
    let value = parse_interpreted_expr_json(bytes, value_slice)?;
    Some(ClaspRtInterpretedRecordField { name, value })
}

fn parse_interpreted_decl(bytes: &[u8], decl_slice: JsonSlice) -> Option<ClaspRtInterpretedDecl> {
    let kind_slice = json_object_lookup(bytes, decl_slice, "kind")?;
    let name_slice = json_object_lookup(bytes, decl_slice, "name")?;
    let kind = json_string_owned(bytes, kind_slice)?;
    let name = json_string_owned(bytes, name_slice)?;
    let body = json_object_lookup(bytes, decl_slice, "body")
        .and_then(|body_slice| parse_interpreted_expr_json(bytes, body_slice))
        .or_else(|| {
            let body_slice = json_object_lookup(bytes, decl_slice, "bodyText")?;
            let body_text = json_string_owned(bytes, body_slice)?;
            parse_interpreted_expr_text(body_text.as_bytes())
        })?;

    match kind.as_str() {
        "global" => Some(ClaspRtInterpretedDecl {
            kind: ClaspRtInterpretedDeclKind::Global,
            name,
            params: Vec::new(),
            body,
        }),
        "function" => {
            let params_slice = json_object_lookup(bytes, decl_slice, "params")?;
            let param_slices = json_array_items(bytes, params_slice)?;
            let mut params = Vec::with_capacity(param_slices.len());
            for param_slice in param_slices {
                params.push(json_string_owned(bytes, param_slice)?);
            }
            Some(ClaspRtInterpretedDecl {
                kind: ClaspRtInterpretedDeclKind::Function,
                name,
                params,
                body,
            })
        }
        _ => None,
    }
}

unsafe extern "C" fn destroy_string(_runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let string = header as *mut ClaspRtString;
    if !string.is_null() {
        free_bytes((*string).bytes as *mut u8, (*string).byte_length + 1);
        drop(Box::from_raw(string));
    }
}

unsafe extern "C" fn destroy_bytes(_runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let bytes = header as *mut ClaspRtBytes;
    if !bytes.is_null() {
        free_bytes((*bytes).bytes, (*bytes).byte_length);
        drop(Box::from_raw(bytes));
    }
}

unsafe extern "C" fn destroy_int(_runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let value = header as *mut ClaspRtInt;
    if !value.is_null() {
        drop(Box::from_raw(value));
    }
}

unsafe extern "C" fn destroy_bool(_runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let value = header as *mut ClaspRtBool;
    if !value.is_null() {
        drop(Box::from_raw(value));
    }
}

unsafe extern "C" fn destroy_string_list(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let list = header as *mut ClaspRtStringList;
    if !list.is_null() {
        for item in string_list_items_mut(list).iter() {
            release_header(runtime, *item as *mut ClaspRtHeader);
        }
        free_array::<*mut ClaspRtString>((*list).items, (*list).length);
        drop(Box::from_raw(list));
    }
}

unsafe extern "C" fn destroy_list_value(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let list = header as *mut ClaspRtListValue;
    if !list.is_null() {
        for item in list_value_items(list) {
            release_header(runtime, *item);
        }
        free_array::<*mut ClaspRtHeader>((*list).items, (*list).item_count);
        drop(Box::from_raw(list));
    }
}

unsafe extern "C" fn destroy_early_return(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let value = header as *mut ClaspRtEarlyReturn;
    if !value.is_null() {
        release_header(runtime, (*value).value);
        drop(Box::from_raw(value));
    }
}

unsafe extern "C" fn destroy_result_string(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let result = header as *mut ClaspRtResultString;
    if !result.is_null() {
        release_header(runtime, (*result).value as *mut ClaspRtHeader);
        drop(Box::from_raw(result));
    }
}

unsafe extern "C" fn destroy_mutable_cell(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let cell = header as *mut ClaspRtMutableCell;
    if !cell.is_null() {
        release_header(runtime, (*cell).value);
        drop(Box::from_raw(cell));
    }
}

unsafe extern "C" fn destroy_variant_value(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let value = header as *mut ClaspRtVariantValue;
    if !value.is_null() {
        release_header(runtime, (*value).tag as *mut ClaspRtHeader);
        for item in variant_items(value) {
            release_header(runtime, *item);
        }
        free_array::<*mut ClaspRtHeader>((*value).items, (*value).item_count);
        drop(Box::from_raw(value));
    }
}

unsafe extern "C" fn destroy_record_value(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let value = header as *mut ClaspRtRecordValue;
    if !value.is_null() {
        release_header(runtime, (*value).record_name as *mut ClaspRtHeader);
        for field_name in record_field_names(value) {
            release_header(runtime, *field_name as *mut ClaspRtHeader);
        }
        for field_value in record_field_values(value) {
            release_header(runtime, *field_value);
        }
        free_array::<*mut ClaspRtString>((*value).field_names, (*value).field_count);
        free_array::<*mut ClaspRtHeader>((*value).field_values, (*value).field_count);
        drop(Box::from_raw(value));
    }
}

unsafe extern "C" fn destroy_object(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let object = header as *mut ClaspRtObject;
    if object.is_null() {
        return;
    }

    let layout = (*object).layout;
    if !layout.is_null() {
        for index in 0..(*layout).root_count {
            let offset = *(*layout).root_offsets.add(index) as usize;
            let word_pointer = object_words_ptr(object).add(offset);
            release_header(runtime, (*word_pointer) as *mut ClaspRtHeader);
        }
        dealloc(object as *mut u8, object_layout_for_words((*layout).word_count));
    } else {
        dealloc(object as *mut u8, object_layout_for_words(0));
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_init(runtime: *mut ClaspRtRuntime) {
    let Some(runtime) = runtime.as_mut() else {
        return;
    };
    runtime.init_state();
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_shutdown(runtime: *mut ClaspRtRuntime) {
    let Some(runtime) = runtime.as_mut() else {
        return;
    };
    runtime.shutdown_state();
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_register_static_root(runtime: *mut ClaspRtRuntime, slot: *mut *mut ClaspRtHeader) {
    let Some(runtime) = runtime.as_mut() else {
        return;
    };
    runtime.register_static_root(slot);
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_alloc_object(layout: *const ClaspRtObjectLayout) -> *mut ClaspRtObject {
    if layout.is_null() {
        return null_mut();
    }
    let memory = alloc_zeroed_with_layout(object_layout_for_words((*layout).word_count)) as *mut ClaspRtObject;
    (*memory).header.layout_id = CLASP_RT_LAYOUT_GENERIC_OBJECT;
    (*memory).header.retain_count = 1;
    (*memory).header.destroy = Some(destroy_object);
    (*memory).layout = layout;
    memory
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_retain(header: *mut ClaspRtHeader) {
    retain_header(header);
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_release(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    release_header(runtime, header);
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_string_from_utf8(value: *const c_char) -> *mut ClaspRtString {
    build_runtime_string(string_from_c(value))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_bytes_new(length: usize) -> *mut ClaspRtBytes {
    build_runtime_bytes(length)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_string_list_new(length: usize) -> *mut ClaspRtStringList {
    build_runtime_string_list(length)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_result_ok_string(value: *mut ClaspRtString) -> *mut ClaspRtResultString {
    build_runtime_result_string(true, value)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_result_err_string(value: *mut ClaspRtString) -> *mut ClaspRtResultString {
    build_runtime_result_string(false, value)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_json_from_string(value: *mut ClaspRtString) -> *mut ClaspRtJson {
    retain_header(value as *mut ClaspRtHeader);
    value as *mut ClaspRtJson
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_json_to_string(value: *mut ClaspRtJson) -> *mut ClaspRtString {
    retain_header(value as *mut ClaspRtHeader);
    value as *mut ClaspRtString
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_binary_from_json(value: *mut ClaspRtJson) -> *mut ClaspRtBytes {
    let source = string_bytes(value as *mut ClaspRtString);
    let bytes = build_runtime_bytes(source.len());
    if !source.is_empty() {
        ptr::copy_nonoverlapping(source.as_ptr(), (*bytes).bytes, source.len());
    }
    bytes
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_json_from_binary(value: *mut ClaspRtBytes) -> *mut ClaspRtJson {
    let json_string = build_runtime_string(bytes_bytes(value));
    clasp_rt_json_from_string(json_string)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_transport_frame(payload: *mut ClaspRtBytes) -> *mut ClaspRtBytes {
    let payload_bytes = bytes_bytes(payload);
    let frame = build_runtime_bytes(payload_bytes.len() + 4);
    (*frame).bytes.add(0).write((payload_bytes.len() & 0xff) as u8);
    (*frame).bytes.add(1).write(((payload_bytes.len() >> 8) & 0xff) as u8);
    (*frame).bytes.add(2).write(((payload_bytes.len() >> 16) & 0xff) as u8);
    (*frame).bytes.add(3).write(((payload_bytes.len() >> 24) & 0xff) as u8);
    if !payload_bytes.is_empty() {
        ptr::copy_nonoverlapping(payload_bytes.as_ptr(), (*frame).bytes.add(4), payload_bytes.len());
    }
    frame
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_transport_unframe(frame: *mut ClaspRtBytes) -> *mut ClaspRtBytes {
    let frame_bytes = bytes_bytes(frame);
    if frame_bytes.len() < 4 {
        return build_runtime_bytes(0);
    }

    let mut payload_length = (frame_bytes[0] as usize)
        | ((frame_bytes[1] as usize) << 8)
        | ((frame_bytes[2] as usize) << 16)
        | ((frame_bytes[3] as usize) << 24);
    let available_length = frame_bytes.len() - 4;
    if payload_length > available_length {
        payload_length = available_length;
    }

    let payload = build_runtime_bytes(payload_length);
    if payload_length > 0 {
        ptr::copy_nonoverlapping(frame_bytes[4..].as_ptr(), (*payload).bytes, payload_length);
    }
    payload
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_image_validate(image: *mut ClaspRtJson) -> bool {
    let bytes = string_bytes(image as *mut ClaspRtString);
    let Some(root) = json_root_object(bytes) else {
        return false;
    };
    let Some(format) = json_object_lookup(bytes, root, "format") else {
        return false;
    };
    let Some(ir_format) = json_object_lookup(bytes, root, "irFormat") else {
        return false;
    };
    let Some(module_name) = json_object_lookup(bytes, root, "module") else {
        return false;
    };
    let Some(runtime) = json_object_lookup(bytes, root, "runtime") else {
        return false;
    };
    let Some(entrypoints) = json_object_lookup(bytes, root, "entrypoints") else {
        return false;
    };
    let Some(compatibility) = json_object_lookup(bytes, root, "compatibility") else {
        return false;
    };
    let Some(runtime_profile) = json_object_lookup(bytes, runtime, "profile") else {
        return false;
    };
    let Some(artifacts) = json_object_lookup(bytes, runtime, "artifacts") else {
        return false;
    };
    let Some(compatibility_kind) = json_object_lookup(bytes, compatibility, "kind") else {
        return false;
    };
    let Some(interface_fingerprint) = json_object_lookup(bytes, compatibility, "interfaceFingerprint") else {
        return false;
    };
    let Some(accepted_previous_fingerprints) =
        json_object_lookup(bytes, compatibility, "acceptedPreviousFingerprints")
    else {
        return false;
    };
    let Some(migration) = json_object_lookup(bytes, compatibility, "migration") else {
        return false;
    };
    let Some(migration_kind) = json_object_lookup(bytes, migration, "kind") else {
        return false;
    };
    let Some(migration_strategy) = json_object_lookup(bytes, migration, "strategy") else {
        return false;
    };
    let Some(migration_state_type) = json_object_lookup(bytes, migration, "stateType") else {
        return false;
    };
    let Some(migration_snapshot_symbol) = json_object_lookup(bytes, migration, "snapshotSymbol") else {
        return false;
    };
    let Some(migration_handoff_symbol) = json_object_lookup(bytes, migration, "handoffSymbol") else {
        return false;
    };
    let Some(decls) = json_object_lookup(bytes, root, "decls") else {
        return false;
    };

    json_string_equals(bytes, format, "clasp-native-image-v1")
        && json_string_equals(bytes, ir_format, "clasp-native-ir-v1")
        && bytes.get(module_name.start) == Some(&b'"')
        && bytes.get(runtime.start) == Some(&b'{')
        && bytes.get(entrypoints.start) == Some(&b'[')
        && bytes.get(compatibility.start) == Some(&b'{')
        && bytes.get(runtime_profile.start) == Some(&b'"')
        && bytes.get(artifacts.start) == Some(&b'[')
        && json_string_equals(bytes, compatibility_kind, "clasp-native-compatibility-v1")
        && bytes.get(interface_fingerprint.start) == Some(&b'"')
        && bytes.get(accepted_previous_fingerprints.start) == Some(&b'[')
        && bytes.get(migration.start) == Some(&b'{')
        && json_string_equals(bytes, migration_kind, "clasp-native-migration-v1")
        && bytes.get(migration_strategy.start) == Some(&b'"')
        && (bytes.get(migration_state_type.start) == Some(&b'"') || json_is_null(bytes, migration_state_type))
        && (bytes.get(migration_snapshot_symbol.start) == Some(&b'"') || json_is_null(bytes, migration_snapshot_symbol))
        && (bytes.get(migration_handoff_symbol.start) == Some(&b'"') || json_is_null(bytes, migration_handoff_symbol))
        && bytes.get(decls.start) == Some(&b'[')
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_image_module_name(image: *mut ClaspRtJson) -> *mut ClaspRtResultString {
    let bytes = string_bytes(image as *mut ClaspRtString);
    let Some(root) = json_root_object(bytes) else {
        return invalid_native_image_result();
    };
    let Some(module_name) = json_object_lookup(bytes, root, "module") else {
        return invalid_native_image_result();
    };

    let value = json_string_value(bytes, module_name);
    if value.is_null() {
        invalid_native_image_result()
    } else {
        clasp_rt_result_ok_string(value)
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_image_runtime_profile(
    image: *mut ClaspRtJson,
) -> *mut ClaspRtResultString {
    let bytes = string_bytes(image as *mut ClaspRtString);
    let Some(root) = json_root_object(bytes) else {
        return invalid_native_image_result();
    };
    let Some(runtime) = json_object_lookup(bytes, root, "runtime") else {
        return invalid_native_image_result();
    };
    let Some(profile) = json_object_lookup(bytes, runtime, "profile") else {
        return invalid_native_image_result();
    };

    let value = json_string_value(bytes, profile);
    if value.is_null() {
        invalid_native_image_result()
    } else {
        clasp_rt_result_ok_string(value)
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_image_decl_count(image: *mut ClaspRtJson) -> usize {
    let bytes = string_bytes(image as *mut ClaspRtString);
    let Some(root) = json_root_object(bytes) else {
        return 0;
    };
    let Some(decls) = json_object_lookup(bytes, root, "decls") else {
        return 0;
    };
    json_array_length(bytes, decls)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_image_has_runtime_artifact(
    image: *mut ClaspRtJson,
    artifact: *mut ClaspRtString,
) -> bool {
    if artifact.is_null() {
        return false;
    }
    let bytes = string_bytes(image as *mut ClaspRtString);
    let Some(root) = json_root_object(bytes) else {
        return false;
    };
    let Some(runtime) = json_object_lookup(bytes, root, "runtime") else {
        return false;
    };
    let Some(artifacts) = json_object_lookup(bytes, runtime, "artifacts") else {
        return false;
    };
    let expected = String::from_utf8_lossy(string_bytes(artifact)).into_owned();
    json_array_contains_string(bytes, artifacts, &expected)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_load(
    image: *mut ClaspRtJson,
) -> *mut ClaspRtNativeModuleImage {
    let bytes = string_bytes(image as *mut ClaspRtString);
    let Some(root) = json_root_object(bytes) else {
        return null_mut();
    };
    let Some(module_name) = json_object_lookup(bytes, root, "module") else {
        return null_mut();
    };
    let Some(abi) = json_object_lookup(bytes, root, "abi") else {
        return null_mut();
    };
    let Some(runtime) = json_object_lookup(bytes, root, "runtime") else {
        return null_mut();
    };
    let Some(runtime_profile) = json_object_lookup(bytes, runtime, "profile") else {
        return null_mut();
    };
    let Some(runtime_bindings) = json_object_lookup(bytes, runtime, "bindings") else {
        return null_mut();
    };
    let Some(exports) = json_object_lookup(bytes, root, "exports") else {
        return null_mut();
    };
    let Some(entrypoints) = json_object_lookup(bytes, root, "entrypoints") else {
        return null_mut();
    };
    let Some(compatibility) = json_object_lookup(bytes, root, "compatibility") else {
        return null_mut();
    };
    let Some(interface_fingerprint) = json_object_lookup(bytes, compatibility, "interfaceFingerprint") else {
        return null_mut();
    };
    let Some(accepted_previous_fingerprints) =
        json_object_lookup(bytes, compatibility, "acceptedPreviousFingerprints")
    else {
        return null_mut();
    };
    let Some(migration) = json_object_lookup(bytes, compatibility, "migration") else {
        return null_mut();
    };
    let Some(migration_strategy) = json_object_lookup(bytes, migration, "strategy") else {
        return null_mut();
    };
    let Some(migration_state_type) = json_object_lookup(bytes, migration, "stateType") else {
        return null_mut();
    };
    let Some(migration_snapshot_symbol) = json_object_lookup(bytes, migration, "snapshotSymbol") else {
        return null_mut();
    };
    let Some(migration_handoff_symbol) = json_object_lookup(bytes, migration, "handoffSymbol") else {
        return null_mut();
    };
    let Some(decls) = json_object_lookup(bytes, root, "decls") else {
        return null_mut();
    };
    let Some(accepted_previous_fingerprint_values) =
        json_array_items(bytes, accepted_previous_fingerprints)
    else {
        return null_mut();
    };
    let Some(runtime_binding_values) = json_array_items(bytes, runtime_bindings) else {
        return null_mut();
    };
    let Some(export_values) = json_array_items(bytes, exports) else {
        return null_mut();
    };
    let Some(entrypoint_values) = json_array_items(bytes, entrypoints) else {
        return null_mut();
    };
    let Some(decl_values) = json_array_items(bytes, decls) else {
        return null_mut();
    };

    let mut loaded = Box::new(ClaspRtNativeModuleImage {
        module_name: json_string_value(bytes, module_name),
        runtime_profile: json_string_value(bytes, runtime_profile),
        interface_fingerprint: json_string_value(bytes, interface_fingerprint),
        accepted_previous_fingerprints: Vec::new(),
        migration_strategy: json_string_value(bytes, migration_strategy),
        migration_state_type: json_optional_string_value(bytes, migration_state_type),
        snapshot_symbol: json_optional_string_value(bytes, migration_snapshot_symbol),
        snapshot: None,
        handoff_symbol: json_optional_string_value(bytes, migration_handoff_symbol),
        handoff: None,
        state_snapshot_type: null_mut(),
        state_snapshot: null_mut(),
        generation: 0,
        runtime_bindings: Vec::new(),
        runtime_binding_indexes: HashMap::new(),
        route_boundaries: Vec::new(),
        record_schemas: HashMap::new(),
        variant_schemas: HashMap::new(),
        exports: Vec::new(),
        entrypoint_symbols: vec![null_mut(); export_values.len()],
        entrypoints: vec![None; export_values.len()],
        interpreted_decls: Vec::new(),
        interpreted_decl_indexes: HashMap::new(),
        decl_count: decl_values.len(),
    });

    if loaded.module_name.is_null()
        || loaded.runtime_profile.is_null()
        || loaded.interface_fingerprint.is_null()
        || loaded.migration_strategy.is_null()
    {
        drop(loaded);
        return null_mut();
    }

    for fingerprint_value in accepted_previous_fingerprint_values {
        let fingerprint = json_string_value(bytes, fingerprint_value);
        if fingerprint.is_null() {
            drop(loaded);
            return null_mut();
        }
        loaded.accepted_previous_fingerprints.push(fingerprint);
    }

    let Some(record_schemas) = load_record_schemas(bytes, abi) else {
        drop(loaded);
        return null_mut();
    };
    loaded.record_schemas = record_schemas;

    let Some(variant_schemas) = load_variant_schemas(bytes, abi) else {
        drop(loaded);
        return null_mut();
    };
    loaded.variant_schemas = variant_schemas;

    let Some(route_boundaries) = load_route_boundaries(bytes, runtime) else {
        drop(loaded);
        return null_mut();
    };
    loaded.route_boundaries = route_boundaries;

    for binding_value in runtime_binding_values {
        let Some(name_slice) = json_object_lookup(bytes, binding_value, "name") else {
            drop(loaded);
            return null_mut();
        };
        let Some(runtime_name_slice) = json_object_lookup(bytes, binding_value, "runtime") else {
            drop(loaded);
            return null_mut();
        };
        let Some(binding_type_slice) = json_object_lookup(bytes, binding_value, "type") else {
            drop(loaded);
            return null_mut();
        };
        let Some(name) = json_string_owned(bytes, name_slice) else {
            drop(loaded);
            return null_mut();
        };
        let Some(runtime_name) = json_string_owned(bytes, runtime_name_slice) else {
            drop(loaded);
            return null_mut();
        };
        let Some(binding_type) = json_string_owned(bytes, binding_type_slice) else {
            drop(loaded);
            return null_mut();
        };
        let binding_index = loaded.runtime_bindings.len();
        loaded.runtime_binding_indexes.insert(name.clone(), binding_index);
        loaded
            .runtime_bindings
            .push(ClaspRtNativeRuntimeBinding { name, runtime_name, binding_type });
    }

    for export_value in export_values {
        let export_name = json_string_value(bytes, export_value);
        if export_name.is_null() {
            drop(loaded);
            return null_mut();
        }
        loaded.exports.push(export_name);
    }

    for entrypoint_value in entrypoint_values {
        let Some(export_name_slice) = json_object_lookup(bytes, entrypoint_value, "name") else {
            drop(loaded);
            return null_mut();
        };
        let Some(symbol_slice) = json_object_lookup(bytes, entrypoint_value, "symbol") else {
            drop(loaded);
            return null_mut();
        };
        let export_name = json_string_value(bytes, export_name_slice);
        let symbol = json_string_value(bytes, symbol_slice);
        let export_index = find_export_index(&mut *loaded as *mut ClaspRtNativeModuleImage, export_name);
        release_header(null_mut(), export_name as *mut ClaspRtHeader);
        let Some(export_index) = export_index else {
            release_header(null_mut(), symbol as *mut ClaspRtHeader);
            drop(loaded);
            return null_mut();
        };
        if symbol.is_null() {
            drop(loaded);
            return null_mut();
        }
        loaded.entrypoint_symbols[export_index] = symbol;
    }

    for decl_value in decl_values {
        if let Some(decl) = parse_interpreted_decl(bytes, decl_value) {
            let decl_index = loaded.interpreted_decls.len();
            loaded.interpreted_decl_indexes.insert(decl.name.clone(), decl_index);
            loaded.interpreted_decls.push(decl);
        }
    }

    Box::into_raw(loaded)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_free(
    _runtime: *mut ClaspRtRuntime,
    image: *mut ClaspRtNativeModuleImage,
) {
    if !image.is_null() {
        drop(Box::from_raw(image));
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_module_name(
    image: *mut ClaspRtNativeModuleImage,
) -> *mut ClaspRtString {
    if image.is_null() || (*image).module_name.is_null() {
        return null_mut();
    }
    retain_header((*image).module_name as *mut ClaspRtHeader);
    (*image).module_name
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_runtime_profile(
    image: *mut ClaspRtNativeModuleImage,
) -> *mut ClaspRtString {
    if image.is_null() || (*image).runtime_profile.is_null() {
        return null_mut();
    }
    retain_header((*image).runtime_profile as *mut ClaspRtHeader);
    (*image).runtime_profile
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_interface_fingerprint(
    image: *mut ClaspRtNativeModuleImage,
) -> *mut ClaspRtString {
    if image.is_null() || (*image).interface_fingerprint.is_null() {
        return null_mut();
    }
    retain_header((*image).interface_fingerprint as *mut ClaspRtHeader);
    (*image).interface_fingerprint
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_migration_strategy(
    image: *mut ClaspRtNativeModuleImage,
) -> *mut ClaspRtString {
    if image.is_null() || (*image).migration_strategy.is_null() {
        return null_mut();
    }
    retain_header((*image).migration_strategy as *mut ClaspRtHeader);
    (*image).migration_strategy
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_state_type(
    image: *mut ClaspRtNativeModuleImage,
) -> *mut ClaspRtString {
    if image.is_null() || (*image).migration_state_type.is_null() {
        return null_mut();
    }
    retain_header((*image).migration_state_type as *mut ClaspRtHeader);
    (*image).migration_state_type
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_snapshot_symbol(
    image: *mut ClaspRtNativeModuleImage,
) -> *mut ClaspRtString {
    if image.is_null() || (*image).snapshot_symbol.is_null() {
        return null_mut();
    }
    retain_header((*image).snapshot_symbol as *mut ClaspRtHeader);
    (*image).snapshot_symbol
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_handoff_symbol(
    image: *mut ClaspRtNativeModuleImage,
) -> *mut ClaspRtString {
    if image.is_null() || (*image).handoff_symbol.is_null() {
        return null_mut();
    }
    retain_header((*image).handoff_symbol as *mut ClaspRtHeader);
    (*image).handoff_symbol
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_export_count(
    image: *mut ClaspRtNativeModuleImage,
) -> usize {
    if image.is_null() {
        0
    } else {
        (*image).exports.len()
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_has_export(
    image: *mut ClaspRtNativeModuleImage,
    export_name: *mut ClaspRtString,
) -> bool {
    image.as_ref().and_then(|image_ref| image_ref.export_index(export_name)).is_some()
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_accepts_previous_fingerprint(
    image: *mut ClaspRtNativeModuleImage,
    fingerprint: *mut ClaspRtString,
) -> bool {
    image
        .as_ref()
        .map(|image_ref| image_ref.accepts_previous_fingerprint(fingerprint))
        .unwrap_or(false)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_entrypoint_symbol(
    image: *mut ClaspRtNativeModuleImage,
    export_name: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let Some(index) = image.as_ref().and_then(|image_ref| image_ref.export_index(export_name)) else {
        return missing_native_entrypoint_result();
    };
    let symbol = (&(*image).entrypoint_symbols)[index];
    if symbol.is_null() {
        missing_native_entrypoint_result()
    } else {
        clasp_rt_result_ok_string(symbol)
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_image_decl_count(
    image: *mut ClaspRtNativeModuleImage,
) -> usize {
    if image.is_null() {
        0
    } else {
        (*image).decl_count
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_activate_native_module_image(
    runtime: *mut ClaspRtRuntime,
    image: *mut ClaspRtNativeModuleImage,
) -> bool {
    let Some(runtime) = runtime.as_mut() else {
        return false;
    };
    let Some(image) = NonNull::new(image) else {
        return false;
    };
    runtime.activate_native_module_image(image)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_active_native_module_count(runtime: *mut ClaspRtRuntime) -> usize {
    runtime.as_ref().map(|runtime| runtime.active_native_module_count).unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_active_native_module_generation(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
) -> usize {
    runtime
        .as_ref()
        .map(|runtime| runtime.active_module_generation(module_name))
        .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_active_native_module_generation_count(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
) -> usize {
    runtime
        .as_ref()
        .map(|runtime| runtime.active_generation_count(module_name))
        .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_has_active_native_module(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
) -> bool {
    runtime
        .as_ref()
        .map(|runtime| runtime.has_active_native_module(module_name))
        .unwrap_or(false)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_has_active_native_module_generation(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    generation: usize,
) -> bool {
    runtime
        .as_ref()
        .map(|runtime| runtime.has_active_native_module_generation(module_name, generation))
        .unwrap_or(false)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_retire_native_module_generation(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    generation: usize,
) -> bool {
    let Some(runtime) = runtime.as_mut() else {
        return false;
    };
    runtime.retire_native_module_generation(module_name, generation)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_bind_native_entrypoint(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    export_name: *mut ClaspRtString,
    entrypoint: ClaspRtNativeEntrypointFn,
) -> bool {
    let Some(runtime) = runtime.as_mut() else {
        return false;
    };
    runtime.bind_native_entrypoint(module_name, export_name, entrypoint)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_bind_native_snapshot(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    snapshot: ClaspRtNativeSnapshotFn,
) -> bool {
    let Some(runtime) = runtime.as_mut() else {
        return false;
    };
    runtime.bind_native_snapshot(module_name, snapshot)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_bind_native_snapshot_symbol(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    resolve_symbol: ClaspRtNativeSnapshotResolverFn,
) -> bool {
    let Some(runtime) = runtime.as_mut() else {
        return false;
    };
    runtime.bind_native_snapshot_symbol(module_name, resolve_symbol)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_bind_native_entrypoint_symbol(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    export_name: *mut ClaspRtString,
    resolve_symbol: ClaspRtNativeSymbolResolverFn,
) -> bool {
    let Some(runtime) = runtime.as_mut() else {
        return false;
    };
    runtime.bind_native_entrypoint_symbol(module_name, export_name, resolve_symbol)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_bind_native_handoff(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    handoff: ClaspRtNativeHandoffFn,
) -> bool {
    let Some(runtime) = runtime.as_mut() else {
        return false;
    };
    runtime.bind_native_handoff(module_name, handoff)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_bind_native_handoff_symbol(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    resolve_symbol: ClaspRtNativeHandoffResolverFn,
) -> bool {
    let Some(runtime) = runtime.as_mut() else {
        return false;
    };
    runtime.bind_native_handoff_symbol(module_name, resolve_symbol)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_resolve_native_dispatch(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    export_name: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let Some(runtime) = runtime.as_ref() else {
        return missing_native_dispatch_result();
    };
    runtime.resolve_native_dispatch(module_name, export_name)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_resolve_native_dispatch_generation(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    generation: usize,
    export_name: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let Some(runtime) = runtime.as_ref() else {
        return missing_native_dispatch_result();
    };
    runtime.resolve_native_dispatch_generation(module_name, generation, export_name)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_resolve_native_entrypoint(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    export_name: *mut ClaspRtString,
) -> ClaspRtNativeEntrypointFn {
    let Some(runtime) = runtime.as_ref() else {
        return None;
    };
    runtime.resolve_native_entrypoint(module_name, export_name)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_resolve_native_entrypoint_generation(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    generation: usize,
    export_name: *mut ClaspRtString,
) -> ClaspRtNativeEntrypointFn {
    let Some(runtime) = runtime.as_ref() else {
        return None;
    };
    runtime.resolve_native_entrypoint_generation(module_name, generation, export_name)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_resolve_native_handoff(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
) -> ClaspRtNativeHandoffFn {
    let Some(runtime) = runtime.as_ref() else {
        return None;
    };
    runtime.resolve_native_handoff(module_name)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_resolve_native_snapshot(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
) -> ClaspRtNativeSnapshotFn {
    let Some(runtime) = runtime.as_ref() else {
        return None;
    };
    runtime.resolve_native_snapshot(module_name)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_store_native_module_state_snapshot(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    generation: usize,
    state_type: *mut ClaspRtString,
    snapshot: *mut ClaspRtJson,
) -> bool {
    let Some(runtime) = runtime.as_mut() else {
        return false;
    };
    runtime.store_native_module_state_snapshot(module_name, generation, state_type, snapshot)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_generation_state_type(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    generation: usize,
) -> *mut ClaspRtString {
    let Some(runtime) = runtime.as_ref() else {
        return null_mut();
    };
    runtime.native_module_generation_state_type(module_name, generation)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_native_module_generation_state_snapshot(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    generation: usize,
) -> *mut ClaspRtJson {
    let Some(runtime) = runtime.as_ref() else {
        return null_mut();
    };
    runtime.native_module_generation_state_snapshot(module_name, generation)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_call_native_dispatch(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    export_name: *mut ClaspRtString,
    args: *mut *mut ClaspRtHeader,
    arg_count: usize,
) -> *mut ClaspRtHeader {
    let Some(runtime_ref) = runtime.as_ref() else {
        return null_mut();
    };
    match runtime_ref.resolve_native_entrypoint(module_name, export_name) {
        Some(entrypoint) => entrypoint(runtime, args, arg_count),
        None => runtime_ref.interpret_native_dispatch(runtime, module_name, export_name, args, arg_count),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_call_native_dispatch_generation(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    generation: usize,
    export_name: *mut ClaspRtString,
    args: *mut *mut ClaspRtHeader,
    arg_count: usize,
) -> *mut ClaspRtHeader {
    let Some(runtime_ref) = runtime.as_ref() else {
        return null_mut();
    };
    match runtime_ref.resolve_native_entrypoint_generation(module_name, generation, export_name) {
        Some(entrypoint) => entrypoint(runtime, args, arg_count),
        None => runtime_ref.interpret_native_dispatch_generation(runtime, module_name, generation, export_name, args, arg_count),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_call_native_route_json(
    runtime: *mut ClaspRtRuntime,
    module_name: *mut ClaspRtString,
    method: *mut ClaspRtString,
    path: *mut ClaspRtString,
    request_json: *mut ClaspRtJson,
) -> *mut ClaspRtResultString {
    let Some(runtime_ref) = runtime.as_ref() else {
        return null_mut();
    };
    if module_name.is_null() || method.is_null() || path.is_null() || request_json.is_null() {
        return native_route_error_result("invalid_route_call");
    }

    let Some(method_text) = String::from_utf8(string_bytes(method).to_vec()).ok() else {
        return native_route_error_result("invalid_route_method");
    };
    let Some(path_text) = String::from_utf8(string_bytes(path).to_vec()).ok() else {
        return native_route_error_result("invalid_route_path");
    };

    let Some((image, route_index)) = runtime_ref.find_latest_route(module_name, &method_text, &path_text) else {
        return native_route_error_result("missing_route");
    };
    let route = &(&(*image).route_boundaries)[route_index];
    if route.handler.is_empty() {
        return native_route_error_result("route_handler_missing");
    }

    let request_bytes = string_bytes(request_json as *mut ClaspRtString);
    let Some(request_value) = json_root_value(request_bytes) else {
        return native_route_error_result("invalid_route_request_json");
    };
    let Some(request_type) = parse_schema_type_text(&route.request_type) else {
        return native_route_error_result("invalid_route_request_type");
    };
    clear_native_route_error();
    let request_header = match decode_json_to_runtime_value(&*image, &request_type, request_bytes, request_value, None) {
        Ok(request_header) => request_header,
        Err(error) => {
            return native_route_error_result(&format!("request_boundary:{}", error.message));
        }
    };

    let handler_name = build_runtime_string(route.handler.as_bytes());
    if handler_name.is_null() {
        release_header(runtime, request_header);
        return native_route_error_result("invalid_route_handler");
    }

    let mut dispatch_args = [request_header];
    let dispatch_value = clasp_rt_call_native_dispatch(
        runtime,
        module_name,
        handler_name,
        dispatch_args.as_mut_ptr(),
        1,
    );

    release_header(runtime, handler_name as *mut ClaspRtHeader);
    release_header(runtime, request_header);

    if dispatch_value.is_null() {
        if let Some(message) = take_native_route_error() {
            return native_route_error_result(&message);
        }
        return native_route_error_result("route_dispatch_failed");
    }

    let encoded = clasp_rt_runtime_value_to_json_string(dispatch_value);
    release_header(runtime, dispatch_value);

    match encoded {
        Some(body) => clasp_rt_result_ok_string(build_runtime_string(body.as_bytes())),
        None => native_route_error_result("route_response_encode_failed"),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_text_concat(parts: *mut ClaspRtStringList) -> *mut ClaspRtString {
    let items = string_list_items_mut(parts);
    build_runtime_string(&join_string_bytes(items, &[]))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_int_add(
    left: *mut ClaspRtHeader,
    right: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    build_runtime_int_binary_result(left, right, i64::checked_add)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_int_subtract(
    left: *mut ClaspRtHeader,
    right: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    build_runtime_int_binary_result(left, right, i64::checked_sub)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_argv() -> *mut ClaspRtStringList {
    let values: Vec<String> = env::args().skip(1).collect();
    let list = build_runtime_string_list(values.len());
    for (index, value) in values.iter().enumerate() {
        *string_list_items_mut(list).get_unchecked_mut(index) = build_runtime_string(value.as_bytes());
    }
    list
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_time_unix_ms() -> *mut ClaspRtHeader {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => clasp_rt_build_int_header(duration.as_millis() as i64),
        Err(_) => clasp_rt_build_int_header(0),
    }
}

fn runtime_time_unix_ms() -> i64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_millis() as i64,
        Err(_) => 0,
    }
}

fn ensure_parent_dir(path: &str) -> Result<(), String> {
    let Some(parent) = Path::new(path).parent() else {
        return Ok(());
    };
    if parent.as_os_str().is_empty() {
        return Ok(());
    }
    fs::create_dir_all(parent).map_err(|err| err.to_string())
}

fn write_file_atomic(path: &str, bytes: &[u8]) -> Result<(), String> {
    ensure_parent_dir(path)?;
    let target = Path::new(path);
    let parent = target.parent().unwrap_or_else(|| Path::new("."));
    let file_name = target
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("clasp-write");
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::from_secs(0))
        .as_nanos();
    let temp_path = parent.join(format!(".{file_name}.{}.{}.tmp", std::process::id(), stamp));

    let write_result = (|| -> Result<(), String> {
        let mut file = File::create(&temp_path).map_err(|err| err.to_string())?;
        file.write_all(bytes).map_err(|err| err.to_string())?;
        file.sync_all().map_err(|err| err.to_string())?;
        fs::rename(&temp_path, target).map_err(|err| err.to_string())
    })();

    if write_result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }

    write_result
}

fn display_path(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn canonical_workspace_root(root: &str) -> Result<PathBuf, String> {
    if root.trim().is_empty() {
        return Err(
            "workspace_root_missing: workspace root must be a non-empty path".to_owned(),
        );
    }
    let root_path = Path::new(root);
    let canonical = fs::canonicalize(root_path).map_err(|err| {
        format!(
            "workspace_root_missing: workspace root `{}` must exist before workspace file operations: {err}",
            root_path.display()
        )
    })?;
    if !canonical.is_dir() {
        return Err(format!(
            "workspace_not_directory: workspace root `{}` is not a directory",
            canonical.display()
        ));
    }
    Ok(canonical)
}

fn normalize_workspace_relative_path(relative: &str) -> Result<PathBuf, String> {
    let relative_path = Path::new(relative);
    if relative_path.is_absolute() {
        return Err(
            "workspace_path_escape: absolute paths are not allowed; pass a path relative to the workspace root"
                .to_owned(),
        );
    }

    let mut normalized = PathBuf::new();
    for component in relative_path.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(part) => normalized.push(part),
            Component::ParentDir => {
                return Err(
                    "workspace_path_escape: `..` path segments are not allowed; pass a path inside the workspace root"
                        .to_owned(),
                )
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(
                    "workspace_path_escape: rooted paths are not allowed; pass a path relative to the workspace root"
                        .to_owned(),
                )
            }
        }
    }
    Ok(normalized)
}

fn ensure_workspace_existing_prefix(root: &Path, relative: &Path) -> Result<(), String> {
    let mut current = root.to_path_buf();
    for component in relative.components() {
        current.push(component.as_os_str());
        if current.exists() {
            let canonical = fs::canonicalize(&current).map_err(|err| {
                format!(
                    "workspace_io_error: failed to resolve workspace path `{}`: {err}",
                    current.display()
                )
            })?;
            if !canonical.starts_with(root) {
                return Err(format!(
                    "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
                    canonical.display(),
                    root.display()
                ));
            }
        } else {
            break;
        }
    }
    Ok(())
}

fn resolve_workspace_path(root: &str, relative: &str) -> Result<PathBuf, String> {
    let root = canonical_workspace_root(root)?;
    let relative = normalize_workspace_relative_path(relative)?;
    ensure_workspace_existing_prefix(&root, &relative)?;
    Ok(root.join(relative))
}

fn resolve_existing_workspace_path(root: &str, relative: &str) -> Result<PathBuf, String> {
    let root = canonical_workspace_root(root)?;
    let relative = normalize_workspace_relative_path(relative)?;
    let target = root.join(relative);
    let canonical = fs::canonicalize(&target).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            format!("workspace_missing: `{}` does not exist", target.display())
        } else {
            format!(
                "workspace_io_error: failed to resolve workspace path `{}`: {err}",
                target.display()
            )
        }
    })?;
    if !canonical.starts_with(&root) {
        return Err(format!(
            "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
            canonical.display(),
            root.display()
        ));
    }
    Ok(canonical)
}

fn resolve_existing_workspace_regular_file_path(root: &str, relative: &str) -> Result<PathBuf, String> {
    let root = canonical_workspace_root(root)?;
    let relative = normalize_workspace_relative_path(relative)?;
    if relative.as_os_str().is_empty() || relative.file_name().is_none() {
        return Err(
            "workspace_invalid_path: replace path must name a file inside the workspace root"
                .to_owned(),
        );
    }
    let target = root.join(relative);
    let metadata = fs::symlink_metadata(&target).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            format!("workspace_missing: `{}` does not exist", target.display())
        } else {
            format!(
                "workspace_io_error: failed to inspect workspace path `{}`: {err}",
                target.display()
            )
        }
    })?;
    if metadata.file_type().is_symlink() {
        return Err(format!(
            "workspace_path_escape: symlink file paths are not allowed for workspaceReplaceText: `{}`",
            target.display()
        ));
    }
    if !metadata.file_type().is_file() {
        return Err(format!(
            "workspace_not_file: `{}` is not a regular file",
            target.display()
        ));
    }
    let canonical = fs::canonicalize(&target).map_err(|err| {
        format!(
            "workspace_io_error: failed to resolve workspace path `{}`: {err}",
            target.display()
        )
    })?;
    if !canonical.starts_with(&root) {
        return Err(format!(
            "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
            canonical.display(),
            root.display()
        ));
    }
    Ok(canonical)
}

fn resolve_existing_workspace_removal_path(root: &str, relative: &str) -> Result<PathBuf, String> {
    let root = canonical_workspace_root(root)?;
    let relative = normalize_workspace_relative_path(relative)?;
    if relative.as_os_str().is_empty() {
        return Err(
            "workspace_invalid_path: remove path must name a file or directory inside the workspace root"
                .to_owned(),
        );
    }
    let target = root.join(&relative);
    let canonical = fs::canonicalize(&target).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            format!("workspace_missing: `{}` does not exist", target.display())
        } else {
            format!(
                "workspace_io_error: failed to resolve workspace path `{}`: {err}",
                target.display()
            )
        }
    })?;
    if canonical == root {
        return Err("workspace_invalid_path: remove path must not name the workspace root".to_owned());
    }
    if !canonical.starts_with(&root) {
        return Err(format!(
            "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
            canonical.display(),
            root.display()
        ));
    }
    Ok(target)
}

fn resolve_workspace_process_cwd(root: &str, relative: &str) -> Result<PathBuf, String> {
    let path = resolve_existing_workspace_path(root, relative)?;
    if !path.is_dir() {
        return Err(format!(
            "workspace_not_directory: process cwd `{}` is not a directory",
            path.display()
        ));
    }
    Ok(path)
}

fn workspace_path_size_bytes(path: &Path) -> Result<u128, String> {
    let metadata = fs::symlink_metadata(path).map_err(|err| {
        format!(
            "workspace_io_error: failed to inspect workspace path `{}`: {err}",
            path.display()
        )
    })?;
    if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
        let mut total = 0u128;
        let entries = fs::read_dir(path).map_err(|err| {
            format!(
                "workspace_io_error: failed to list workspace directory `{}`: {err}",
                path.display()
            )
        })?;
        for entry in entries {
            let entry = entry.map_err(|err| {
                format!(
                    "workspace_io_error: failed to read workspace directory entry `{}`: {err}",
                    path.display()
                )
            })?;
            total = total.saturating_add(workspace_path_size_bytes(&entry.path())?);
        }
        Ok(total)
    } else {
        Ok(metadata.len() as u128)
    }
}

fn workspace_path_size_mb(root: &str, relative: &str) -> Result<i64, String> {
    let path = resolve_existing_workspace_path(root, relative)?;
    let bytes = workspace_path_size_bytes(&path)?;
    let mb = (bytes.saturating_add(1_048_575)) / 1_048_576;
    Ok(mb.min(i64::MAX as u128) as i64)
}

fn host_file_size_mb(path: &str) -> Result<i64, String> {
    if path.trim().is_empty() {
        return Err("host_file_invalid_path: empty path".to_owned());
    }
    let path = Path::new(path);
    let metadata = fs::symlink_metadata(path).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            format!("host_file_missing: `{}` does not exist", path.display())
        } else {
            format!("host_file_io_error: failed to inspect `{}`: {err}", path.display())
        }
    })?;
    if metadata.file_type().is_symlink() {
        return Err(format!(
            "host_file_not_regular: `{}` is a symlink",
            path.display()
        ));
    }
    if !metadata.file_type().is_file() {
        return Err(format!(
            "host_file_not_regular: `{}` is not a regular file",
            path.display()
        ));
    }
    let mb = ((metadata.len() as u128).saturating_add(1_048_575)) / 1_048_576;
    Ok(mb.min(i64::MAX as u128) as i64)
}

fn cap_host_file_tail_mb(path: &str, max_mb: i64) -> Result<i64, String> {
    if max_mb < 0 {
        return Err("host_file_invalid_limit: maxMb must be non-negative".to_owned());
    }
    if path.trim().is_empty() {
        return Err("host_file_invalid_path: empty path".to_owned());
    }

    let path = Path::new(path);
    let metadata = fs::symlink_metadata(path).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            format!("host_file_missing: `{}` does not exist", path.display())
        } else {
            format!("host_file_io_error: failed to inspect `{}`: {err}", path.display())
        }
    })?;
    if metadata.file_type().is_symlink() {
        return Err(format!(
            "host_file_not_regular: `{}` is a symlink",
            path.display()
        ));
    }
    if !metadata.file_type().is_file() {
        return Err(format!(
            "host_file_not_regular: `{}` is not a regular file",
            path.display()
        ));
    }

    let max_bytes = (max_mb as u128).saturating_mul(1_048_576).min(u64::MAX as u128) as u64;
    let size_bytes = metadata.len();
    if size_bytes <= max_bytes {
        return host_file_size_mb(&path.to_string_lossy());
    }

    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("clasp-host-file");
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::from_secs(0))
        .as_nanos();
    let temp_path = parent.join(format!(".{file_name}.tail.{}.{}.tmp", std::process::id(), stamp));

    let cap_result = (|| -> Result<(), String> {
        if max_bytes > 0 {
            let mut source = File::open(path).map_err(|err| {
                format!("host_file_io_error: failed to open `{}`: {err}", path.display())
            })?;
            let start = size_bytes.saturating_sub(max_bytes);
            source.seek(SeekFrom::Start(start)).map_err(|err| {
                format!("host_file_io_error: failed to seek `{}`: {err}", path.display())
            })?;
            let mut temp = File::create(&temp_path).map_err(|err| {
                format!(
                    "host_file_io_error: failed to create cap temp `{}`: {err}",
                    temp_path.display()
                )
            })?;
            let mut limited = source.take(max_bytes);
            std::io::copy(&mut limited, &mut temp).map_err(|err| {
                format!(
                    "host_file_io_error: failed to copy tail for `{}`: {err}",
                    path.display()
                )
            })?;
            temp.sync_all().map_err(|err| {
                format!(
                    "host_file_io_error: failed to sync cap temp `{}`: {err}",
                    temp_path.display()
                )
            })?;
        } else {
            File::create(&temp_path).map_err(|err| {
                format!(
                    "host_file_io_error: failed to create cap temp `{}`: {err}",
                    temp_path.display()
                )
            })?;
        }

        let mut temp = File::open(&temp_path).map_err(|err| {
            format!(
                "host_file_io_error: failed to read cap temp `{}`: {err}",
                temp_path.display()
            )
        })?;
        let mut target = OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(path)
            .map_err(|err| format!("host_file_io_error: failed to truncate `{}`: {err}", path.display()))?;
        std::io::copy(&mut temp, &mut target).map_err(|err| {
            format!("host_file_io_error: failed to rewrite `{}`: {err}", path.display())
        })?;
        target.sync_all().map_err(|err| {
            format!("host_file_io_error: failed to sync `{}`: {err}", path.display())
        })?;
        Ok(())
    })();

    let _ = fs::remove_file(&temp_path);
    cap_result?;
    host_file_size_mb(&path.to_string_lossy())
}

fn workspace_relative_output_path(root: &Path, path: &Path, is_dir: bool) -> Result<String, String> {
    let relative = path.strip_prefix(root).map_err(|_| {
        format!(
            "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
            path.display(),
            root.display()
        )
    })?;
    let mut parts = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_string_lossy().into_owned()),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(format!(
                    "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
                    path.display(),
                    root.display()
                ));
            }
        }
    }
    let mut rendered = parts.join("/");
    if is_dir && !rendered.is_empty() {
        rendered.push('/');
    }
    Ok(rendered)
}

fn push_workspace_tree_entry(
    root: &Path,
    path: &Path,
    is_dir: bool,
    output: &mut Vec<String>,
    max_entries: usize,
) -> Result<(), String> {
    if output.len() >= max_entries {
        return Err(format!(
            "workspace_limit_exceeded: workspaceListTree reached maxEntries={max_entries}"
        ));
    }
    let rendered = workspace_relative_output_path(root, path, is_dir)?;
    if !rendered.is_empty() {
        output.push(rendered);
    }
    Ok(())
}

fn workspace_list_tree_visit(
    root: &Path,
    path: &Path,
    depth: i64,
    max_depth: i64,
    max_entries: usize,
    output: &mut Vec<String>,
) -> Result<(), String> {
    if depth >= max_depth {
        return Ok(());
    }
    let entries = fs::read_dir(path).map_err(|err| {
        format!(
            "workspace_io_error: failed to list workspace directory `{}`: {err}",
            path.display()
        )
    })?;
    let mut children = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|err| {
            format!(
                "workspace_io_error: failed to read workspace directory entry `{}`: {err}",
                path.display()
            )
        })?;
        children.push(entry.path());
    }
    children.sort_by(|left, right| display_path(left).cmp(&display_path(right)));

    for child in children {
        let metadata = fs::symlink_metadata(&child).map_err(|err| {
            format!(
                "workspace_io_error: failed to inspect workspace path `{}`: {err}",
                child.display()
            )
        })?;
        let is_real_dir = metadata.file_type().is_dir() && !metadata.file_type().is_symlink();
        let display_child = if is_real_dir {
            fs::canonicalize(&child).map_err(|err| {
                format!(
                    "workspace_io_error: failed to resolve workspace directory `{}`: {err}",
                    child.display()
                )
            })?
        } else {
            child.clone()
        };
        if !display_child.starts_with(root) {
            return Err(format!(
                "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
                display_child.display(),
                root.display()
            ));
        }
        push_workspace_tree_entry(root, &display_child, is_real_dir, output, max_entries)?;
        if is_real_dir {
            workspace_list_tree_visit(root, &display_child, depth + 1, max_depth, max_entries, output)?;
        }
    }
    Ok(())
}

fn workspace_list_tree(
    root: &str,
    relative: &str,
    max_entries: i64,
    max_depth: i64,
) -> Result<Vec<String>, String> {
    if max_entries <= 0 {
        return Err("workspace_invalid_limit: maxEntries must be positive".to_owned());
    }
    if max_depth < 0 {
        return Err("workspace_invalid_limit: maxDepth must be non-negative".to_owned());
    }
    let max_entries = usize::try_from(max_entries)
        .map_err(|_| "workspace_invalid_limit: maxEntries is too large".to_owned())?;
    let root = canonical_workspace_root(root)?;
    let relative = normalize_workspace_relative_path(relative)?;
    let target = root.join(&relative);
    let target = fs::canonicalize(&target).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            format!("workspace_missing: `{}` does not exist", target.display())
        } else {
            format!(
                "workspace_io_error: failed to resolve workspace path `{}`: {err}",
                target.display()
            )
        }
    })?;
    if !target.starts_with(&root) {
        return Err(format!(
            "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
            target.display(),
            root.display()
        ));
    }
    let metadata = fs::symlink_metadata(&target).map_err(|err| {
        format!(
            "workspace_io_error: failed to inspect workspace path `{}`: {err}",
            target.display()
        )
    })?;
    let mut output = Vec::new();
    if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
        workspace_list_tree_visit(&root, &target, 0, max_depth, max_entries, &mut output)?;
    } else {
        push_workspace_tree_entry(&root, &target, false, &mut output, max_entries)?;
    }
    Ok(output)
}

fn workspace_search_result_line(root: &Path, path: &Path, line_index: usize, line: &str) -> Result<String, String> {
    let rendered_path = workspace_relative_output_path(root, path, false)?;
    let trimmed = line.trim();
    let snippet: String = trimmed.chars().take(240).collect();
    Ok(format!("{}:{}:{}", rendered_path, line_index + 1, snippet))
}

fn workspace_search_text_file(
    root: &Path,
    path: &Path,
    needle: &str,
    max_matches: usize,
    max_files: usize,
    max_file_bytes: u64,
    files_seen: &mut usize,
    output: &mut Vec<String>,
) -> Result<(), String> {
    if *files_seen >= max_files {
        return Err(format!(
            "workspace_limit_exceeded: workspaceSearchText reached maxFiles={max_files}"
        ));
    }
    *files_seen += 1;

    let metadata = fs::symlink_metadata(path).map_err(|err| {
        format!(
            "workspace_io_error: failed to inspect workspace file `{}`: {err}",
            path.display()
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
        return Ok(());
    }
    if metadata.len() > max_file_bytes {
        return Ok(());
    }

    let bytes = fs::read(path).map_err(|err| {
        format!(
            "workspace_io_error: failed to read workspace file `{}`: {err}",
            path.display()
        )
    })?;
    if bytes.len() > max_file_bytes as usize {
        return Ok(());
    }
    let Ok(text) = String::from_utf8(bytes) else {
        return Ok(());
    };

    for (line_index, line) in text.lines().enumerate() {
        if !line.contains(needle) {
            continue;
        }
        if output.len() >= max_matches {
            return Err(format!(
                "workspace_limit_exceeded: workspaceSearchText reached maxMatches={max_matches}"
            ));
        }
        output.push(workspace_search_result_line(root, path, line_index, line)?);
    }
    Ok(())
}

fn workspace_search_text_visit(
    root: &Path,
    path: &Path,
    needle: &str,
    depth: i64,
    max_depth: i64,
    max_matches: usize,
    max_files: usize,
    max_file_bytes: u64,
    files_seen: &mut usize,
    output: &mut Vec<String>,
) -> Result<(), String> {
    if depth > max_depth {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(path).map_err(|err| {
        format!(
            "workspace_io_error: failed to inspect workspace path `{}`: {err}",
            path.display()
        )
    })?;
    if metadata.file_type().is_symlink() {
        return Ok(());
    }
    if metadata.file_type().is_file() {
        return workspace_search_text_file(
            root,
            path,
            needle,
            max_matches,
            max_files,
            max_file_bytes,
            files_seen,
            output,
        );
    }
    if !(metadata.file_type().is_dir()) {
        return Ok(());
    }
    if depth >= max_depth {
        return Ok(());
    }

    let entries = fs::read_dir(path).map_err(|err| {
        format!(
            "workspace_io_error: failed to list workspace directory `{}`: {err}",
            path.display()
        )
    })?;
    let mut children = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|err| {
            format!(
                "workspace_io_error: failed to read workspace directory entry `{}`: {err}",
                path.display()
            )
        })?;
        children.push(entry.path());
    }
    children.sort_by(|left, right| display_path(left).cmp(&display_path(right)));

    for child in children {
        let metadata = fs::symlink_metadata(&child).map_err(|err| {
            format!(
                "workspace_io_error: failed to inspect workspace path `{}`: {err}",
                child.display()
            )
        })?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        let child_path = if metadata.file_type().is_dir() {
            fs::canonicalize(&child).map_err(|err| {
                format!(
                    "workspace_io_error: failed to resolve workspace directory `{}`: {err}",
                    child.display()
                )
            })?
        } else {
            child
        };
        if !child_path.starts_with(root) {
            return Err(format!(
                "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
                child_path.display(),
                root.display()
            ));
        }
        workspace_search_text_visit(
            root,
            &child_path,
            needle,
            depth + 1,
            max_depth,
            max_matches,
            max_files,
            max_file_bytes,
            files_seen,
            output,
        )?;
    }
    Ok(())
}

fn workspace_search_text(
    root: &str,
    relative: &str,
    needle: &str,
    max_matches: i64,
    max_files: i64,
    max_file_bytes: i64,
    max_depth: i64,
) -> Result<Vec<String>, String> {
    if needle.is_empty() {
        return Err("workspace_invalid_search: needle must be non-empty".to_owned());
    }
    if max_matches <= 0 {
        return Err("workspace_invalid_limit: maxMatches must be positive".to_owned());
    }
    if max_files <= 0 {
        return Err("workspace_invalid_limit: maxFiles must be positive".to_owned());
    }
    if max_file_bytes <= 0 {
        return Err("workspace_invalid_limit: maxFileBytes must be positive".to_owned());
    }
    if max_depth < 0 {
        return Err("workspace_invalid_limit: maxDepth must be non-negative".to_owned());
    }
    let max_matches = usize::try_from(max_matches)
        .map_err(|_| "workspace_invalid_limit: maxMatches is too large".to_owned())?;
    let max_files = usize::try_from(max_files)
        .map_err(|_| "workspace_invalid_limit: maxFiles is too large".to_owned())?;
    let max_file_bytes = u64::try_from(max_file_bytes)
        .map_err(|_| "workspace_invalid_limit: maxFileBytes is too large".to_owned())?;
    let root = canonical_workspace_root(root)?;
    let relative = normalize_workspace_relative_path(relative)?;
    let target = root.join(&relative);
    let target = fs::canonicalize(&target).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            format!("workspace_missing: `{}` does not exist", target.display())
        } else {
            format!(
                "workspace_io_error: failed to resolve workspace path `{}`: {err}",
                target.display()
            )
        }
    })?;
    if !target.starts_with(&root) {
        return Err(format!(
            "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
            target.display(),
            root.display()
        ));
    }

    let mut files_seen = 0usize;
    let mut output = Vec::new();
    workspace_search_text_visit(
        &root,
        &target,
        needle,
        0,
        max_depth,
        max_matches,
        max_files,
        max_file_bytes,
        &mut files_seen,
        &mut output,
    )?;
    Ok(output)
}

fn workspace_replace_text_output_len(
    original_len: usize,
    find_len: usize,
    replace_len: usize,
    replacement_count: usize,
) -> Result<usize, String> {
    if replace_len >= find_len {
        let per_replacement_growth = replace_len - find_len;
        let total_growth = replacement_count
            .checked_mul(per_replacement_growth)
            .ok_or_else(|| "workspace_limit_exceeded: workspaceReplaceText output size overflow".to_owned())?;
        original_len
            .checked_add(total_growth)
            .ok_or_else(|| "workspace_limit_exceeded: workspaceReplaceText output size overflow".to_owned())
    } else {
        let per_replacement_shrink = find_len - replace_len;
        let total_shrink = replacement_count
            .checked_mul(per_replacement_shrink)
            .ok_or_else(|| "workspace_limit_exceeded: workspaceReplaceText output size overflow".to_owned())?;
        Ok(original_len.saturating_sub(total_shrink))
    }
}

fn workspace_replace_text(
    root: &str,
    relative: &str,
    find_text: &str,
    replace_text: &str,
    max_replacements: i64,
    max_file_bytes: i64,
) -> Result<i64, String> {
    if find_text.is_empty() {
        return Err("workspace_invalid_replace: findText must be non-empty".to_owned());
    }
    if max_replacements <= 0 {
        return Err("workspace_invalid_limit: maxReplacements must be positive".to_owned());
    }
    if max_file_bytes <= 0 {
        return Err("workspace_invalid_limit: maxFileBytes must be positive".to_owned());
    }
    let max_replacements = usize::try_from(max_replacements)
        .map_err(|_| "workspace_invalid_limit: maxReplacements is too large".to_owned())?;
    let max_file_bytes_u64 = u64::try_from(max_file_bytes)
        .map_err(|_| "workspace_invalid_limit: maxFileBytes is too large".to_owned())?;
    let max_file_bytes_usize = usize::try_from(max_file_bytes)
        .map_err(|_| "workspace_invalid_limit: maxFileBytes is too large".to_owned())?;

    let path = resolve_existing_workspace_regular_file_path(root, relative)?;
    let metadata = fs::symlink_metadata(&path).map_err(|err| {
        format!(
            "workspace_io_error: failed to inspect workspace file `{}`: {err}",
            path.display()
        )
    })?;
    if metadata.len() > max_file_bytes_u64 {
        return Err(format!(
            "workspace_limit_exceeded: workspaceReplaceText input exceeds maxFileBytes={max_file_bytes}"
        ));
    }
    let bytes = fs::read(&path).map_err(|err| {
        format!(
            "workspace_io_error: failed to read workspace file `{}`: {err}",
            path.display()
        )
    })?;
    if bytes.len() > max_file_bytes_usize {
        return Err(format!(
            "workspace_limit_exceeded: workspaceReplaceText input exceeds maxFileBytes={max_file_bytes}"
        ));
    }
    let text = String::from_utf8(bytes).map_err(|_| {
        format!(
            "workspace_invalid_utf8: workspaceReplaceText requires UTF-8 text in `{}`",
            path.display()
        )
    })?;
    let replacement_count = text.matches(find_text).count();
    if replacement_count == 0 {
        return Err("workspace_replace_missing: findText was not found".to_owned());
    }
    if replacement_count > max_replacements {
        return Err(format!(
            "workspace_limit_exceeded: workspaceReplaceText would replace {replacement_count} occurrences, above maxReplacements={max_replacements}"
        ));
    }
    let output_len = workspace_replace_text_output_len(
        text.len(),
        find_text.len(),
        replace_text.len(),
        replacement_count,
    )?;
    if output_len > max_file_bytes_usize {
        return Err(format!(
            "workspace_limit_exceeded: workspaceReplaceText output exceeds maxFileBytes={max_file_bytes}"
        ));
    }
    let replaced = text.replace(find_text, replace_text);
    let path_text = display_path(&path);
    write_file_atomic(&path_text, replaced.as_bytes()).map_err(|err| {
        format!(
            "workspace_io_error: failed to write workspace file `{}`: {err}",
            path.display()
        )
    })?;
    Ok(replacement_count.min(i64::MAX as usize) as i64)
}

fn create_workspace_dir_all(root: &str, relative: &str) -> Result<PathBuf, String> {
    let root = canonical_workspace_root(root)?;
    let relative = normalize_workspace_relative_path(relative)?;
    ensure_workspace_existing_prefix(&root, &relative)?;
    let target = root.join(&relative);
    fs::create_dir_all(&target).map_err(|err| {
        format!(
            "workspace_io_error: failed to create workspace directory `{}`: {err}",
            target.display()
        )
    })?;
    let canonical = fs::canonicalize(&target).map_err(|err| {
        format!(
            "workspace_io_error: failed to resolve workspace directory `{}`: {err}",
            target.display()
        )
    })?;
    if !canonical.starts_with(&root) {
        return Err(format!(
            "workspace_path_escape: resolved path `{}` escapes workspace root `{}`",
            canonical.display(),
            root.display()
        ));
    }
    Ok(canonical)
}

fn prepare_workspace_write_path(root: &str, relative: &str) -> Result<PathBuf, String> {
    let root = canonical_workspace_root(root)?;
    let relative = normalize_workspace_relative_path(relative)?;
    if relative.as_os_str().is_empty() || relative.file_name().is_none() {
        return Err(
            "workspace_invalid_path: write path must name a file inside the workspace root"
                .to_owned(),
        );
    }
    if let Some(parent) = relative.parent() {
        if !parent.as_os_str().is_empty() {
            let parent_text = display_path(parent);
            create_workspace_dir_all(&display_path(&root), &parent_text)?;
        }
    }
    ensure_workspace_existing_prefix(&root, &relative)?;
    let target = root.join(relative);
    if target.is_dir() {
        return Err(format!(
            "workspace_not_file: `{}` is a directory",
            target.display()
        ));
    }
    Ok(target)
}

fn configure_killable_process_command(command: &mut ProcessCommand) {
    #[cfg(unix)]
    unsafe {
        command.pre_exec(|| {
            disable_core_dumps()?;
            if setsid() < 0 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
}

fn configure_no_core_dump_process_command(command: &mut ProcessCommand) {
    #[cfg(unix)]
    unsafe {
        command.pre_exec(|| disable_core_dumps());
    }
}

#[cfg(target_os = "linux")]
fn disable_core_dumps() -> std::io::Result<()> {
    let limit = RLimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    unsafe {
        if setrlimit(RLIMIT_CORE, &limit) < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(())
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn disable_core_dumps() -> std::io::Result<()> {
    Ok(())
}

fn parse_process_memory_limit_mb(value: *mut ClaspRtHeader) -> Result<i64, String> {
    unsafe { clasp_rt_int_arg(value) }.map(|limit| limit.max(0))
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

fn create_truncated_output_file(path: &str) -> Result<File, String> {
    ensure_parent_dir(path)?;
    File::create(path).map_err(|err| err.to_string())
}

fn watched_process_output_limit_bytes() -> u64 {
    env::var("CLASP_RT_WATCH_OUTPUT_LIMIT_BYTES")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value > 0)
        .map(|value| value.min(DEFAULT_WATCHED_PROCESS_OUTPUT_LIMIT_BYTES))
        .unwrap_or(DEFAULT_WATCHED_PROCESS_OUTPUT_LIMIT_BYTES)
}

fn watched_process_output_limit_exceeded(path: &str, output_limit_bytes: u64) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.len() > output_limit_bytes)
        .unwrap_or(false)
}

fn watched_process_any_output_limit_exceeded(
    stdout_path: &str,
    stderr_path: &str,
    output_limit_bytes: u64,
) -> bool {
    watched_process_output_limit_exceeded(stdout_path, output_limit_bytes)
        || watched_process_output_limit_exceeded(stderr_path, output_limit_bytes)
}

fn truncate_watched_process_output_file_to_limit(path: &str, output_limit_bytes: u64) {
    if !watched_process_output_limit_exceeded(path, output_limit_bytes) {
        return;
    }

    let tmp_path = format!("{path}.tmp.limit.{}", std::process::id());
    let result = (|| -> Result<(), String> {
        let source = File::open(path).map_err(|err| err.to_string())?;
        let mut limited_source = source.take(output_limit_bytes);
        let mut target = File::create(&tmp_path).map_err(|err| err.to_string())?;
        std::io::copy(&mut limited_source, &mut target).map_err(|err| err.to_string())?;
        target.flush().map_err(|err| err.to_string())?;
        fs::rename(&tmp_path, path).map_err(|err| err.to_string())
    })();

    if result.is_err() {
        let _ = fs::remove_file(&tmp_path);
    }
}

fn truncate_watched_process_outputs_to_limit(stdout_path: &str, stderr_path: &str, output_limit_bytes: u64) {
    truncate_watched_process_output_file_to_limit(stdout_path, output_limit_bytes);
    truncate_watched_process_output_file_to_limit(stderr_path, output_limit_bytes);
}

fn resolve_process_program(program: &str, child_cwd: &str) -> String {
    let candidate = Path::new(program);
    if !program.contains('/') && !program.starts_with('.') {
        return program.to_owned();
    }
    if !candidate.is_relative() {
        return program.to_owned();
    }

    if let Ok(current_dir) = env::current_dir() {
        let current_dir_candidate = current_dir.join(candidate);
        if current_dir_candidate.exists() {
            return current_dir_candidate.to_string_lossy().into_owned();
        }
    }

    let child_dir_candidate = Path::new(child_cwd).join(candidate);
    if child_dir_candidate.exists() {
        return child_dir_candidate.to_string_lossy().into_owned();
    }

    program.to_owned()
}

fn watched_process_status_json(
    pid: u32,
    running: bool,
    completed: bool,
    exit_code: i32,
    stdout_path: &str,
    stderr_path: &str,
    heartbeat_path: &str,
    command: &[String],
    started_at_ms: i64,
    timed_out: bool,
    error: &str,
    output_limit_bytes: u64,
    stdout_truncated: bool,
    stderr_truncated: bool,
) -> String {
    let updated_at_ms = runtime_time_unix_ms();
    let ended_at_ms = if completed { updated_at_ms } else { 0 };
    let duration_ms = if started_at_ms > 0 {
        updated_at_ms.saturating_sub(started_at_ms)
    } else {
        0
    };
    let status = if error == "output-limit" {
        "output-limit"
    } else if timed_out {
        "timeout"
    } else if completed && exit_code == 0 {
        "completed-pass"
    } else if completed {
        "completed-fail"
    } else if running {
        "running"
    } else {
        "stopped"
    };

    serde_json::json!({
        "pid": pid as i64,
        "status": status,
        "running": running,
        "completed": completed,
        "exitCode": exit_code,
        "timedOut": timed_out,
        "error": error,
        "outputLimitBytes": output_limit_bytes,
        "stdoutTruncated": stdout_truncated,
        "stderrTruncated": stderr_truncated,
        "command": command,
        "stdoutPath": stdout_path,
        "stderrPath": stderr_path,
        "heartbeatPath": heartbeat_path,
        "startedAtMs": started_at_ms,
        "endedAtMs": ended_at_ms,
        "durationMs": duration_ms,
        "updatedAtMs": updated_at_ms,
    })
    .to_string()
}

fn write_watched_process_heartbeat(path: &str, payload: &str) -> Result<(), String> {
    write_file_atomic(path, payload.as_bytes())
}

fn run_watched_process_json(cwd: &str, args: &[String]) -> Result<(i32, String), String> {
    if args.len() < 5 {
        return Err("invalid_watch_command".to_owned());
    }

    let stdout_path = &args[0];
    let stderr_path = &args[1];
    let heartbeat_path = &args[2];
    let poll_ms = args[3]
        .parse::<u64>()
        .map_err(|_| "invalid_watch_poll_ms".to_owned())?
        .max(50);
    let watched_command = &args[4..];
    if watched_command.is_empty() {
        return Err("missing_watch_command".to_owned());
    }

    let started_at_ms = runtime_time_unix_ms();
    let stdout_file = create_truncated_output_file(stdout_path)?;
    let stderr_file = create_truncated_output_file(stderr_path)?;
    let resolved_program = resolve_process_program(&watched_command[0], cwd);
    let output_limit_bytes = watched_process_output_limit_bytes();
    let mut output_limit_exceeded = false;
    let mut command = ProcessCommand::new(&resolved_program);
    command
        .args(&watched_command[1..])
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout_file))
        .stderr(Stdio::from(stderr_file));
    configure_killable_process_command(&mut command);
    let mut child = command.spawn().map_err(|err| err.to_string())?;
    let pid = child.id();

    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let stdout_truncated = watched_process_output_limit_exceeded(stdout_path, output_limit_bytes);
                let stderr_truncated = watched_process_output_limit_exceeded(stderr_path, output_limit_bytes);
                let exceeded = output_limit_exceeded || stdout_truncated || stderr_truncated;
                if exceeded {
                    truncate_watched_process_outputs_to_limit(stdout_path, stderr_path, output_limit_bytes);
                }
                let exit_code = if exceeded {
                    125
                } else {
                    status.code().unwrap_or(-1)
                };
                let payload = watched_process_status_json(
                    pid,
                    false,
                    true,
                    exit_code,
                    stdout_path,
                    stderr_path,
                    heartbeat_path,
                    watched_command,
                    started_at_ms,
                    false,
                    if exceeded { "output-limit" } else { "" },
                    output_limit_bytes,
                    stdout_truncated,
                    stderr_truncated,
                );
                write_watched_process_heartbeat(heartbeat_path, &payload)?;
                return Ok((exit_code, payload));
            }
            Ok(None) => {
                if watched_process_any_output_limit_exceeded(
                    stdout_path,
                    stderr_path,
                    output_limit_bytes,
                ) {
                    output_limit_exceeded = true;
                    terminate_child_tree(&mut child, pid);
                    continue;
                }
                let payload = watched_process_status_json(
                    pid,
                    true,
                    false,
                    -1,
                    stdout_path,
                    stderr_path,
                    heartbeat_path,
                    watched_command,
                    started_at_ms,
                    false,
                    "",
                    output_limit_bytes,
                    false,
                    false,
                );
                write_watched_process_heartbeat(heartbeat_path, &payload)?;
                thread::sleep(Duration::from_millis(poll_ms));
            }
            Err(err) => return Err(err.to_string()),
        }
    }
}

const WATCHED_PROCESS_MONITOR_SCRIPT: &str = r#"
set -u

stdout_path="$1"
stderr_path="$2"
heartbeat_path="$3"
poll_ms="$4"
shift 4

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_command_array() {
  local first=true
  local value
  printf '['
  for value in "$@"; do
    if [ "$first" = true ]; then
      first=false
    else
      printf ','
    fi
    printf '"%s"' "$(json_escape "$value")"
  done
  printf ']'
}

now_ms() {
  date +%s%3N 2>/dev/null || printf '0'
}

started_at_ms="$(now_ms)"
command_json="$(json_command_array "$@")"
cancel_path="${heartbeat_path}.cancel"
watch_token="${CLASP_RT_WATCH_TOKEN:-}"
memory_limit_mb="${CLASP_RT_WATCH_MEMORY_MB:-0}"
watch_output_limit_bytes="${CLASP_RT_WATCH_OUTPUT_LIMIT_BYTES:-4194304}"
memory_limit_kb=0
process_group_id=0
output_limit_exceeded=false
stdout_truncated=false
stderr_truncated=false

case "$memory_limit_mb" in
  ""|0)
    memory_limit_kb=0
    ;;
  *[!0-9]*)
    printf 'invalid_memory_limit_mb\n' >&2
    exit 125
    ;;
  *)
    memory_limit_kb=$((memory_limit_mb * 1024))
    ;;
esac

case "$watch_output_limit_bytes" in
  ""|0)
    watch_output_limit_bytes=4194304
    ;;
  *[!0-9]*)
    printf 'invalid_watch_output_limit_bytes\n' >&2
    exit 125
    ;;
esac

write_heartbeat() {
  local running="$1"
  local completed="$2"
  local exit_code="$3"
  local now
  local ended_at_ms
  local duration_ms
  local status
  local timed_out=false
  local error=""
  local tmp_path="${heartbeat_path}.tmp.${BASHPID}"
  now="$(now_ms)"
  ended_at_ms=0
  if [ "$completed" = true ]; then
    ended_at_ms="$now"
  fi
  duration_ms=$((now - started_at_ms))
  if [ "$duration_ms" -lt 0 ]; then
    duration_ms=0
  fi
  if [ "$output_limit_exceeded" = true ]; then
    error="output-limit"
    status="output-limit"
    if [ "$completed" = true ]; then
      exit_code=125
    fi
  elif [ -f "$cancel_path" ]; then
    timed_out=true
    error="timeout"
    status="timeout"
    if [ "$completed" = true ]; then
      exit_code=124
    fi
  elif [ "$completed" = true ] && [ "$exit_code" -eq 0 ]; then
    status="completed-pass"
  elif [ "$completed" = true ]; then
    status="completed-fail"
  elif [ "$running" = true ]; then
    status="running"
  else
    status="stopped"
  fi
  printf '{"pid":%s,"processGroupId":%s,"watchToken":"%s","status":"%s","running":%s,"completed":%s,"exitCode":%s,"timedOut":%s,"error":"%s","outputLimitBytes":%s,"stdoutTruncated":%s,"stderrTruncated":%s,"command":%s,"stdoutPath":"%s","stderrPath":"%s","heartbeatPath":"%s","startedAtMs":%s,"endedAtMs":%s,"durationMs":%s,"updatedAtMs":%s}' \
    "$child_pid" \
    "$process_group_id" \
    "$(json_escape "$watch_token")" \
    "$status" \
    "$running" \
    "$completed" \
    "$exit_code" \
    "$timed_out" \
    "$error" \
    "$watch_output_limit_bytes" \
    "$stdout_truncated" \
    "$stderr_truncated" \
    "$command_json" \
    "$(json_escape "$stdout_path")" \
    "$(json_escape "$stderr_path")" \
    "$(json_escape "$heartbeat_path")" \
    "$started_at_ms" \
    "$ended_at_ms" \
    "$duration_ms" \
    "$now" >"$tmp_path" && mv "$tmp_path" "$heartbeat_path"
}

mkdir -p "$(dirname "$stdout_path")" "$(dirname "$stderr_path")" "$(dirname "$heartbeat_path")" || exit 125
: >"$stdout_path" || exit 125
: >"$stderr_path" || exit 125

file_size_bytes() {
  wc -c <"$1" 2>/dev/null | tr -d ' ' || printf '0'
}

output_file_over_limit() {
  local path="$1"
  local size
  if [ ! -f "$path" ]; then
    return 1
  fi
  size="$(file_size_bytes "$path")"
  case "$size" in
    ""|*[!0-9]*)
      size=0
      ;;
  esac
  [ "$size" -gt "$watch_output_limit_bytes" ]
}

truncate_output_file_to_limit() {
  local path="$1"
  local tmp_path
  if ! output_file_over_limit "$path"; then
    return 0
  fi
  tmp_path="${path}.tmp.limit.${BASHPID}"
  if head -c "$watch_output_limit_bytes" "$path" >"$tmp_path" 2>/dev/null; then
    mv "$tmp_path" "$path" || rm -f "$tmp_path"
  else
    rm -f "$tmp_path"
  fi
}

terminate_child_for_output_limit() {
  output_limit_exceeded=true
  if [ "$process_group_id" -gt 0 ]; then
    kill -TERM "-$process_group_id" >/dev/null 2>&1 || true
  fi
  kill -TERM "$child_pid" >/dev/null 2>&1 || true
  sleep 0.05 2>/dev/null || sleep 1
  if [ "$process_group_id" -gt 0 ]; then
    kill -KILL "-$process_group_id" >/dev/null 2>&1 || true
  fi
  kill -KILL "$child_pid" >/dev/null 2>&1 || true
}

check_output_limit() {
  if output_file_over_limit "$stdout_path"; then
    stdout_truncated=true
    terminate_child_for_output_limit "$stdout_path"
    return 0
  fi
  if output_file_over_limit "$stderr_path"; then
    stderr_truncated=true
    terminate_child_for_output_limit "$stderr_path"
    return 0
  fi
  return 1
}

truncate_outputs_to_limit() {
  truncate_output_file_to_limit "$stdout_path"
  truncate_output_file_to_limit "$stderr_path"
}

poll_sleep="0.050"
if command -v awk >/dev/null 2>&1; then
  poll_sleep="$(awk -v ms="$poll_ms" 'BEGIN { if (ms < 50) ms = 50; printf "%.3f", ms / 1000 }')"
fi

if command -v setsid >/dev/null 2>&1; then
  CLASP_RT_WATCH_HEARTBEAT="$heartbeat_path" CLASP_RT_WATCH_TOKEN="$watch_token" setsid sh -c '
    memory_limit_kb="$1"
    shift
    ulimit -c 0 >/dev/null 2>&1 || true
    if [ "$memory_limit_kb" -gt 0 ]; then
      ulimit -v "$memory_limit_kb" || exit 125
    fi
    exec "$@"
  ' clasp-rt-watch-child "$memory_limit_kb" "$@" </dev/null >"$stdout_path" 2>"$stderr_path" &
  child_pid=$!
  process_group_id="$child_pid"
else
  CLASP_RT_WATCH_HEARTBEAT="$heartbeat_path" CLASP_RT_WATCH_TOKEN="$watch_token" sh -c '
    memory_limit_kb="$1"
    shift
    ulimit -c 0 >/dev/null 2>&1 || true
    if [ "$memory_limit_kb" -gt 0 ]; then
      ulimit -v "$memory_limit_kb" || exit 125
    fi
    exec "$@"
  ' clasp-rt-watch-child "$memory_limit_kb" "$@" </dev/null >"$stdout_path" 2>"$stderr_path" &
  child_pid=$!
fi
write_heartbeat true false -1

(
  while kill -0 "$child_pid" >/dev/null 2>&1; do
    if check_output_limit; then
      break
    fi
    write_heartbeat true false -1
    sleep "$poll_sleep"
  done
) &
heartbeat_loop_pid=$!

wait "$child_pid"
exit_code=$?
kill "$heartbeat_loop_pid" >/dev/null 2>&1 || true
wait "$heartbeat_loop_pid" >/dev/null 2>&1 || true
if output_file_over_limit "$stdout_path"; then
  stdout_truncated=true
  output_limit_exceeded=true
fi
if output_file_over_limit "$stderr_path"; then
  stderr_truncated=true
  output_limit_exceeded=true
fi
if [ "$output_limit_exceeded" = true ]; then
  output_limit_exceeded=true
  truncate_outputs_to_limit
fi
write_heartbeat false true "$exit_code"
exit "$exit_code"
"#;

fn spawn_watched_process_monitor_json(
    cwd: &str,
    stdout_path: &str,
    stderr_path: &str,
    heartbeat_path: &str,
    poll_ms: u64,
    memory_limit_mb: Option<i64>,
    extra_env: &[(String, String)],
    watched_command: &[String],
) -> Result<String, String> {
    if watched_command.is_empty() {
        return Err("missing_watch_command".to_owned());
    }

    ensure_parent_dir(stdout_path)?;
    ensure_parent_dir(stderr_path)?;
    ensure_parent_dir(heartbeat_path)?;

    let watch_token = format!(
        "{}-{}-{}",
        runtime_time_unix_ms(),
        std::process::id(),
        heartbeat_path.len()
    );
    let mut command = ProcessCommand::new("bash");
    command
        .arg("-c")
        .arg(WATCHED_PROCESS_MONITOR_SCRIPT)
        .arg("clasp-rt-watch-monitor")
        .arg(stdout_path)
        .arg(stderr_path)
        .arg(heartbeat_path)
        .arg(poll_ms.to_string())
        .args(watched_command)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    for (key, value) in extra_env {
        command.env(key, value);
    }
    if let Some(limit_mb) = memory_limit_mb.filter(|limit| *limit > 0) {
        command.env("CLASP_RT_WATCH_MEMORY_MB", limit_mb.to_string());
    }
    command
        .env("CLASP_RT_WATCH_HEARTBEAT", heartbeat_path)
        .env("CLASP_RT_WATCH_TOKEN", &watch_token)
        .env(
            "CLASP_RT_WATCH_OUTPUT_LIMIT_BYTES",
            watched_process_output_limit_bytes().to_string(),
        );
    configure_no_core_dump_process_command(&mut command);

    let mut monitor = command.spawn().map_err(|err| err.to_string())?;
    let monitor_pid = monitor.id();
    thread::spawn(move || {
        let _ = monitor.wait();
    });

    for _ in 0..100 {
        match fs::read_to_string(heartbeat_path) {
            Ok(payload) if !payload.trim().is_empty() => return Ok(payload),
            _ => thread::sleep(Duration::from_millis(10)),
        }
    }

    let fallback = watched_process_status_json(
        monitor_pid,
        true,
        false,
        -1,
        stdout_path,
        stderr_path,
        heartbeat_path,
        watched_command,
        runtime_time_unix_ms(),
        false,
        "",
        watched_process_output_limit_bytes(),
        false,
        false,
    );
    write_watched_process_heartbeat(heartbeat_path, &fallback)?;
    Ok(fallback)
}

fn spawn_watched_process_json(cwd: &str, args: &[String]) -> Result<String, String> {
    if args.len() < 5 {
        return Err("invalid_spawn_command".to_owned());
    }

    let poll_ms = args[3]
        .parse::<u64>()
        .map_err(|_| "invalid_watch_poll_ms".to_owned())?
        .max(50);
    spawn_watched_process_monitor_json(cwd, &args[0], &args[1], &args[2], poll_ms, None, &[], &args[4..])
}

fn spawn_watched_process_with_limits_json(cwd: &str, args: &[String]) -> Result<String, String> {
    if args.len() < 6 {
        return Err("invalid_spawn_command".to_owned());
    }

    let poll_ms = args[3]
        .parse::<u64>()
        .map_err(|_| "invalid_watch_poll_ms".to_owned())?
        .max(50);
    let memory_limit_mb = args[4]
        .parse::<i64>()
        .map_err(|_| "invalid_memory_limit_mb".to_owned())?
        .max(0);
    spawn_watched_process_monitor_json(
        cwd,
        &args[0],
        &args[1],
        &args[2],
        poll_ms,
        Some(memory_limit_mb),
        &[],
        &args[5..],
    )
}

fn watched_process_exit_code(payload: &str) -> i32 {
    serde_json::from_str::<serde_json::Value>(payload)
        .ok()
        .and_then(|decoded| decoded.get("exitCode").and_then(serde_json::Value::as_i64))
        .unwrap_or(-1) as i32
}

fn watch_watched_process_with_limits_json(cwd: &str, args: &[String]) -> Result<(i32, String), String> {
    if args.len() < 6 {
        return Err("invalid_watch_command".to_owned());
    }

    let poll_ms = args[3]
        .parse::<u64>()
        .map_err(|_| "invalid_watch_poll_ms".to_owned())?
        .max(50);
    let memory_limit_mb = args[4]
        .parse::<i64>()
        .map_err(|_| "invalid_memory_limit_mb".to_owned())?
        .max(0);
    let heartbeat_path = args[2].clone();
    spawn_watched_process_monitor_json(
        cwd,
        &args[0],
        &args[1],
        &args[2],
        poll_ms,
        Some(memory_limit_mb),
        &[],
        &args[5..],
    )?;
    let payload = await_watched_process_json(&heartbeat_path, poll_ms)?;
    Ok((watched_process_exit_code(&payload), payload))
}

fn spawn_watched_process_with_env_json(
    cwd: &str,
    stdout_path: &str,
    stderr_path: &str,
    heartbeat_path: &str,
    poll_ms: u64,
    extra_env: &[(String, String)],
    watched_command: &[String],
) -> Result<String, String> {
    spawn_watched_process_monitor_json(
        cwd,
        stdout_path,
        stderr_path,
        heartbeat_path,
        poll_ms.max(50),
        None,
        extra_env,
        watched_command,
    )
}

fn watched_process_exists(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    let proc_root = format!("/proc/{pid}");
    if !Path::new(&proc_root).exists() {
        return false;
    }

    let stat_path = format!("{proc_root}/stat");
    let Ok(stat) = fs::read_to_string(stat_path) else {
        return true;
    };
    let Some((_, fields_after_name)) = stat.rsplit_once(") ") else {
        return true;
    };
    let state = fields_after_name.split_whitespace().next().unwrap_or("");
    state != "Z" && state != "X"
}

fn watched_process_has_marker(pid: u32, heartbeat_path: &str, watch_token: &str) -> bool {
    if heartbeat_path.is_empty() || watch_token.is_empty() {
        return false;
    }
    let environ_path = format!("/proc/{pid}/environ");
    let Ok(environ_bytes) = fs::read(environ_path) else {
        return false;
    };
    let heartbeat_marker = format!("CLASP_RT_WATCH_HEARTBEAT={heartbeat_path}");
    let token_marker = format!("CLASP_RT_WATCH_TOKEN={watch_token}");
    let mut has_heartbeat = false;
    let mut has_token = false;
    for entry in environ_bytes.split(|byte| *byte == 0) {
        if entry == heartbeat_marker.as_bytes() {
            has_heartbeat = true;
        }
        if entry == token_marker.as_bytes() {
            has_token = true;
        }
    }
    has_heartbeat && has_token
}

fn terminate_watched_process_pid(pid: u32) {
    if pid == 0 {
        return;
    }
    #[cfg(unix)]
    unsafe {
        let pid_value = pid as c_int;
        let _ = kill(pid_value, SIGTERM);
        thread::sleep(Duration::from_millis(50));
        let _ = kill(pid_value, SIGKILL);
    }
}

fn terminate_watched_process_tree(
    pid: u32,
    process_group_id: u32,
    heartbeat_path: &str,
    watch_token: &str,
) {
    let has_marker = !watch_token.is_empty()
        && watched_process_has_marker(pid, heartbeat_path, watch_token);
    if !has_marker {
        return;
    }
    #[cfg(unix)]
    {
        if process_group_id > 0 && process_group_id == pid {
            signal_process_group(process_group_id, SIGTERM);
            thread::sleep(Duration::from_millis(50));
            signal_process_group(process_group_id, SIGKILL);
        }
    }

    terminate_watched_process_pid(pid);
}

fn mark_watched_process_timeout(payload: &mut serde_json::Value) {
    let now = runtime_time_unix_ms();
    let started_at_ms = payload
        .get("startedAtMs")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(now);
    if payload.get("command").is_none() {
        payload["command"] = serde_json::Value::Array(Vec::new());
    }
    payload["status"] = serde_json::Value::String("timeout".to_owned());
    payload["running"] = serde_json::Value::Bool(false);
    payload["completed"] = serde_json::Value::Bool(true);
    payload["exitCode"] = serde_json::Value::Number(serde_json::Number::from(124));
    payload["timedOut"] = serde_json::Value::Bool(true);
    payload["error"] = serde_json::Value::String("timeout".to_owned());
    payload["startedAtMs"] = serde_json::Value::Number(serde_json::Number::from(started_at_ms));
    payload["endedAtMs"] = serde_json::Value::Number(serde_json::Number::from(now));
    payload["durationMs"] =
        serde_json::Value::Number(serde_json::Number::from(now.saturating_sub(started_at_ms)));
    payload["updatedAtMs"] = serde_json::Value::Number(serde_json::Number::from(now));
}

fn cancel_watched_process_json(heartbeat_path: &str) -> Result<String, String> {
    let (_, mut payload) = read_watched_process_payload(heartbeat_path)?;
    let running = payload
        .get("running")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let completed = payload
        .get("completed")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    if completed || !running {
        return Ok(payload.to_string());
    }

    let cancel_path = format!("{heartbeat_path}.cancel");
    write_file_atomic(&cancel_path, b"timeout")?;

    let pid = payload
        .get("pid")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0)
        .max(0) as u32;
    let process_group_id = payload
        .get("processGroupId")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0)
        .max(0) as u32;
    let watch_token = payload
        .get("watchToken")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    terminate_watched_process_tree(pid, process_group_id, heartbeat_path, watch_token);

    for _ in 0..40 {
        thread::sleep(Duration::from_millis(25));
        if let Ok((_, mut latest)) = read_watched_process_payload(heartbeat_path) {
            let latest_completed = latest
                .get("completed")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            let latest_timed_out = latest
                .get("timedOut")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            if latest_completed && latest_timed_out {
                return Ok(latest.to_string());
            }
            if latest_completed {
                mark_watched_process_timeout(&mut latest);
                let updated = latest.to_string();
                write_watched_process_heartbeat(heartbeat_path, &updated)?;
                return Ok(updated);
            }
        }
    }

    mark_watched_process_timeout(&mut payload);
    let updated = payload.to_string();
    write_watched_process_heartbeat(heartbeat_path, &updated)?;
    Ok(updated)
}

fn reconcile_watched_process_json(heartbeat_path: &str) -> Result<String, String> {
    let heartbeat_text = fs::read_to_string(heartbeat_path).map_err(|err| err.to_string())?;
    let mut payload: serde_json::Value =
        serde_json::from_str(&heartbeat_text).map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
    let pid = payload
        .get("pid")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0)
        .max(0) as u32;
    let running = payload
        .get("running")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let completed = payload
        .get("completed")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);

    if completed || !running {
        return Ok(payload.to_string());
    }

    if watched_process_exists(pid) {
        return Ok(payload.to_string());
    }

    let now = runtime_time_unix_ms();
    let started_at_ms = payload
        .get("startedAtMs")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(now);
    if payload.get("command").is_none() {
        payload["command"] = serde_json::Value::Array(Vec::new());
    }
    payload["running"] = serde_json::Value::Bool(false);
    payload["completed"] = serde_json::Value::Bool(true);
    payload["exitCode"] = serde_json::Value::Number(serde_json::Number::from(-1));
    payload["status"] = serde_json::Value::String("completed-fail".to_owned());
    payload["timedOut"] = serde_json::Value::Bool(false);
    payload["error"] = serde_json::Value::String("stale_process".to_owned());
    payload["startedAtMs"] = serde_json::Value::Number(serde_json::Number::from(started_at_ms));
    payload["endedAtMs"] = serde_json::Value::Number(serde_json::Number::from(now));
    payload["durationMs"] =
        serde_json::Value::Number(serde_json::Number::from(now.saturating_sub(started_at_ms)));
    payload["updatedAtMs"] = serde_json::Value::Number(serde_json::Number::from(now));

    let updated = payload.to_string();
    write_watched_process_heartbeat(heartbeat_path, &updated)?;
    Ok(updated)
}

fn sleep_ms_json(delay_ms: i64) -> String {
    let clamped = delay_ms.max(0) as u64;
    thread::sleep(Duration::from_millis(clamped));
    serde_json::json!({
        "sleptMs": clamped as i64,
    })
    .to_string()
}

fn read_watched_process_payload(heartbeat_path: &str) -> Result<(String, serde_json::Value), String> {
    let mut last_error = "invalid watched process heartbeat: empty payload".to_owned();
    for _ in 0..10 {
        let payload = fs::read_to_string(heartbeat_path).map_err(|err| err.to_string())?;
        if payload.trim().is_empty() {
            last_error = "invalid watched process heartbeat: empty payload".to_owned();
            thread::sleep(Duration::from_millis(10));
            continue;
        }
        match serde_json::from_str::<serde_json::Value>(&payload) {
            Ok(decoded) => return Ok((payload, decoded)),
            Err(err) if err.is_eof() => {
                last_error = format!("invalid watched process heartbeat: {err}");
                thread::sleep(Duration::from_millis(10));
            }
            Err(err) => return Err(format!("invalid watched process heartbeat: {err}")),
        }
    }
    Err(last_error)
}

fn await_watched_process_json(heartbeat_path: &str, poll_ms: u64) -> Result<String, String> {
    let clamped = poll_ms.max(50);
    loop {
        let (payload, decoded) = read_watched_process_payload(heartbeat_path)?;
        let running = decoded
            .get("running")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        let completed = decoded
            .get("completed")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        if completed || !running {
            return Ok(payload);
        }
        let pid = decoded
            .get("pid")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0)
            .max(0) as u32;
        if watched_process_exists(pid) {
            thread::sleep(Duration::from_millis(clamped));
            continue;
        }

        thread::sleep(Duration::from_millis(10));
        let (refreshed_payload, refreshed) = read_watched_process_payload(heartbeat_path)?;
        let refreshed_running = refreshed
            .get("running")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        let refreshed_completed = refreshed
            .get("completed")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        if refreshed_completed || !refreshed_running {
            return Ok(refreshed_payload);
        }

        return reconcile_watched_process_json(heartbeat_path);
    }
}

fn await_watched_process_timeout_json(
    heartbeat_path: &str,
    poll_ms: u64,
    timeout_ms: u64,
) -> Result<String, String> {
    let clamped = poll_ms.max(50);
    let started = Instant::now();
    loop {
        let (payload, decoded) = read_watched_process_payload(heartbeat_path)?;
        let running = decoded
            .get("running")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        let completed = decoded
            .get("completed")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        if completed || !running {
            return Ok(payload);
        }
        if started.elapsed() >= Duration::from_millis(timeout_ms) {
            return Err("timeout".to_owned());
        }
        let pid = decoded
            .get("pid")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0)
            .max(0) as u32;
        if watched_process_exists(pid) {
            let remaining_ms = timeout_ms.saturating_sub(started.elapsed().as_millis() as u64);
            let sleep_ms = clamped.min(remaining_ms.max(1));
            thread::sleep(Duration::from_millis(sleep_ms));
            continue;
        }

        thread::sleep(Duration::from_millis(10));
        let (refreshed_payload, refreshed) = read_watched_process_payload(heartbeat_path)?;
        let refreshed_running = refreshed
            .get("running")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        let refreshed_completed = refreshed
            .get("completed")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        if refreshed_completed || !refreshed_running {
            return Ok(refreshed_payload);
        }
        if started.elapsed() >= Duration::from_millis(timeout_ms) {
            return Err("timeout".to_owned());
        }

        return reconcile_watched_process_json(heartbeat_path);
    }
}

fn ready_marker_matches(ready_path: &str, ready_contains: &str) -> Result<bool, String> {
    match fs::read_to_string(ready_path) {
        Ok(contents) => {
            if ready_contains.is_empty() {
                Ok(!contents.trim().is_empty())
            } else {
                Ok(contents.contains(ready_contains))
            }
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(err) => Err(err.to_string()),
    }
}

fn upgrade_phase_is_final(phase: &str) -> bool {
    matches!(phase, "committed" | "completed" | "rolled_back" | "failed")
}

fn read_json_file(path: &str) -> Result<serde_json::Value, String> {
    let text = fs::read_to_string(path).map_err(|err| err.to_string())?;
    serde_json::from_str(&text).map_err(|err| format!("invalid json `{path}`: {err}"))
}

fn write_json_file_atomic(path: &str, value: &serde_json::Value) -> Result<(), String> {
    write_file_atomic(path, value.to_string().as_bytes())
}

fn json_string_field(value: &serde_json::Value, key: &str) -> Result<String, String> {
    value
        .get(key)
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| format!("missing or invalid string field `{key}`"))
}

fn json_i64_field(value: &serde_json::Value, key: &str) -> Result<i64, String> {
    value
        .get(key)
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| format!("missing or invalid integer field `{key}`"))
}

fn json_string_list_field(value: &serde_json::Value, key: &str) -> Result<Vec<String>, String> {
    let Some(items) = value.get(key).and_then(serde_json::Value::as_array) else {
        return Err(format!("missing or invalid string-list field `{key}`"));
    };
    let mut rendered = Vec::with_capacity(items.len());
    for item in items {
        let Some(text) = item.as_str() else {
            return Err(format!("invalid string-list item in `{key}`"));
        };
        rendered.push(text.to_owned());
    }
    Ok(rendered)
}

fn remove_file_if_exists(path: &str) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err.to_string()),
    }
}

fn service_status_json(
    service_root: &str,
    service_id: &str,
    generation: i64,
    status: &str,
    owner_pid: i64,
    heartbeat_path: &str,
    transaction_path: &str,
    snapshot_path: &str,
    exit_code: i64,
) -> serde_json::Value {
    serde_json::json!({
        "serviceRoot": service_root,
        "serviceId": service_id,
        "generation": generation,
        "status": status,
        "ownerPid": owner_pid,
        "heartbeatPath": heartbeat_path,
        "transactionPath": transaction_path,
        "snapshotPath": snapshot_path,
        "exitCode": exit_code,
        "updatedAtMs": runtime_time_unix_ms(),
    })
}

fn service_status_is_final(status: &str) -> bool {
    status == "completed" || status == "failed"
}

fn workflow_status_is_final(status_path: &str) -> bool {
    if status_path.is_empty() || !Path::new(status_path).exists() {
        return false;
    }

    let Ok(payload) = fs::read_to_string(status_path) else {
        return false;
    };
    if payload.trim().is_empty() {
        return false;
    }

    let Ok(value) = serde_json::from_str::<serde_json::Value>(&payload) else {
        return false;
    };
    if value
        .get("final")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
    {
        return true;
    }

    matches!(
        value.get("phase").and_then(serde_json::Value::as_str),
        Some("completed" | "failed")
    )
}

fn upgrade_transaction_json(
    service_root: &str,
    service_id: &str,
    generation: i64,
    phase: &str,
    committed: bool,
    rolled_back: bool,
    reason: &str,
    service_path: &str,
    transaction_path: &str,
    snapshot_path: &str,
    heartbeat_path: &str,
    stdout_path: &str,
    stderr_path: &str,
    candidate_pid: i64,
    exit_code: i64,
) -> serde_json::Value {
    serde_json::json!({
        "serviceRoot": service_root,
        "serviceId": service_id,
        "generation": generation,
        "phase": phase,
        "committed": committed,
        "rolledBack": rolled_back,
        "reason": reason,
        "servicePath": service_path,
        "transactionPath": transaction_path,
        "snapshotPath": snapshot_path,
        "heartbeatPath": heartbeat_path,
        "stdoutPath": stdout_path,
        "stderrPath": stderr_path,
        "candidatePid": candidate_pid,
        "exitCode": exit_code,
        "updatedAtMs": runtime_time_unix_ms(),
    })
}

fn clear_stale_upgrade_lock(lock_path: &str) -> Result<(), String> {
    if !Path::new(lock_path).exists() {
        return Ok(());
    }
    let Ok(lock_value) = read_json_file(lock_path) else {
        return Ok(());
    };
    let Some(transaction_path) = lock_value
        .get("transactionPath")
        .and_then(serde_json::Value::as_str)
    else {
        return Ok(());
    };
    let Ok(transaction_value) = read_json_file(transaction_path) else {
        return Ok(());
    };
    let Some(phase) = transaction_value.get("phase").and_then(serde_json::Value::as_str) else {
        return Ok(());
    };
    if upgrade_phase_is_final(phase) {
        remove_file_if_exists(lock_path)?;
    }
    Ok(())
}

fn clear_stale_service_supervisor_lock(lock_path: &str) -> Result<(), String> {
    if !Path::new(lock_path).exists() {
        return Ok(());
    }
    let Ok(lock_value) = read_json_file(lock_path) else {
        remove_file_if_exists(lock_path)?;
        return Ok(());
    };
    let Some(supervisor_pid) = lock_value
        .get("supervisorPid")
        .and_then(serde_json::Value::as_i64)
        .map(|value| value.max(0) as u32)
    else {
        remove_file_if_exists(lock_path)?;
        return Ok(());
    };
    if supervisor_pid == 0 || !watched_process_exists(supervisor_pid) {
        remove_file_if_exists(lock_path)?;
    }
    Ok(())
}

fn service_record_has_live_owner(service_value: &serde_json::Value) -> Result<bool, String> {
    let status = service_value
        .get("status")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    if status != "active" && status != "starting" && status != "restarting" {
        return Ok(false);
    }

    let Some(heartbeat_path) = service_value
        .get("heartbeatPath")
        .and_then(serde_json::Value::as_str)
    else {
        return Ok(false);
    };
    if heartbeat_path.is_empty() || !Path::new(heartbeat_path).exists() {
        return Ok(false);
    }

    let reconciled_payload = reconcile_watched_process_json(heartbeat_path)?;
    let reconciled: serde_json::Value = serde_json::from_str(&reconciled_payload)
        .map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
    let running = reconciled
        .get("running")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let completed = reconciled
        .get("completed")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);

    Ok(running && !completed)
}

fn reconcile_service_status_payload(service_path: &str) -> Result<Option<String>, String> {
    if !Path::new(service_path).exists() {
        return Ok(None);
    }

    let payload = fs::read_to_string(service_path).map_err(|err| err.to_string())?;
    if payload.trim().is_empty() {
        return Ok(None);
    }

    let mut service_value: serde_json::Value = serde_json::from_str(&payload)
        .map_err(|err| format!("invalid service heartbeat: {err}"))?;
    let status = service_value
        .get("status")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    if service_status_is_final(status) {
        return Ok(Some(payload));
    }
    if status != "active" && status != "starting" && status != "restarting" {
        return Ok(Some(payload));
    }

    let Some(heartbeat_path) = service_value
        .get("heartbeatPath")
        .and_then(serde_json::Value::as_str)
    else {
        return Ok(Some(payload));
    };
    if heartbeat_path.is_empty() {
        return Ok(Some(payload));
    }

    if !Path::new(heartbeat_path).exists() {
        service_value["status"] = serde_json::Value::String("failed".to_owned());
        service_value["exitCode"] = serde_json::Value::Number(serde_json::Number::from(1));
        service_value["updatedAtMs"] =
            serde_json::Value::Number(serde_json::Number::from(runtime_time_unix_ms()));
        let updated = service_value.to_string();
        write_json_file_atomic(service_path, &service_value)?;
        return Ok(Some(updated));
    }

    let reconciled_payload = reconcile_watched_process_json(heartbeat_path)?;
    let reconciled: serde_json::Value = serde_json::from_str(&reconciled_payload)
        .map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
    let running = reconciled
        .get("running")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let completed = reconciled
        .get("completed")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    if running && !completed {
        return Ok(Some(payload));
    }

    let exit_code = reconciled
        .get("exitCode")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(-1);
    let pid = reconciled
        .get("pid")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0);

    service_value["status"] = serde_json::Value::String(if exit_code == 0 {
        "completed".to_owned()
    } else {
        "failed".to_owned()
    });
    if pid > 0 {
        service_value["ownerPid"] = serde_json::Value::Number(serde_json::Number::from(pid));
    }
    service_value["exitCode"] = serde_json::Value::Number(serde_json::Number::from(exit_code));
    service_value["updatedAtMs"] =
        serde_json::Value::Number(serde_json::Number::from(runtime_time_unix_ms()));

    let updated = service_value.to_string();
    write_json_file_atomic(service_path, &service_value)?;
    Ok(Some(updated))
}

fn clear_stale_service_status_for_restart(service_path: &Path) -> Result<(), String> {
    if !service_path.exists() {
        return Ok(());
    }

    let service_path_text = service_path.to_string_lossy();
    let Ok(service_value) = read_json_file(&service_path_text) else {
        remove_file_if_exists(&service_path_text)?;
        return Ok(());
    };

    if service_record_has_live_owner(&service_value)? {
        return Ok(());
    }

    remove_file_if_exists(&service_path_text)
}

fn service_wait_result(service_path: &str, timeout_ms: u64) -> Result<String, String> {
    let started = Instant::now();
    loop {
        if let Some(payload) = reconcile_service_status_payload(service_path)? {
            if !payload.trim().is_empty() {
                let decoded: serde_json::Value = serde_json::from_str(&payload)
                    .map_err(|err| format!("invalid service heartbeat: {err}"))?;
                let status = decoded
                    .get("status")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                if status == "active" || service_status_is_final(status) {
                    return Ok(payload);
                }
            }
        }
        if started.elapsed() >= Duration::from_millis(timeout_ms.max(1)) {
            return Err("service_wait_timeout".to_owned());
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn upgrade_wait_result(transaction_path: &str, timeout_ms: u64) -> Result<String, String> {
    let started = Instant::now();
    loop {
        if Path::new(transaction_path).exists() {
            let payload = fs::read_to_string(transaction_path).map_err(|err| err.to_string())?;
            if !payload.trim().is_empty() {
                let decoded: serde_json::Value = serde_json::from_str(&payload)
                    .map_err(|err| format!("invalid upgrade transaction heartbeat: {err}"))?;
                let phase = decoded
                    .get("phase")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                if phase == "committed" || phase == "completed" {
                    return Ok(payload);
                }
                if phase == "rolled_back" || phase == "failed" {
                    let reason = decoded
                        .get("reason")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("upgrade failed");
                    return Err(format!("upgrade_rolled_back:{reason}"));
                }
            }
        }
        if started.elapsed() >= Duration::from_millis(timeout_ms.max(1)) {
            return Err("upgrade_wait_timeout".to_owned());
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn run_upgrade_supervisor_from_config(config_path: &str) -> Result<(), String> {
    let config = read_json_file(config_path)?;
    let cwd = json_string_field(&config, "cwd")?;
    let service_root = json_string_field(&config, "serviceRoot")?;
    let service_id = json_string_field(&config, "serviceId")?;
    let service_path = json_string_field(&config, "servicePath")?;
    let lock_path = json_string_field(&config, "lockPath")?;
    let transaction_path = json_string_field(&config, "transactionPath")?;
    let snapshot_path = json_string_field(&config, "snapshotPath")?;
    let stdout_path = json_string_field(&config, "stdoutPath")?;
    let stderr_path = json_string_field(&config, "stderrPath")?;
    let heartbeat_path = json_string_field(&config, "heartbeatPath")?;
    let ready_path = json_string_field(&config, "readyPath")?;
    let ready_contains = json_string_field(&config, "readyContains")?;
    let watch_poll_ms = json_i64_field(&config, "watchPollMs")?.max(50) as u64;
    let ready_poll_ms = json_i64_field(&config, "readyPollMs")?.max(10) as u64;
    let ready_timeout_ms = json_i64_field(&config, "readyTimeoutMs")?.max(1) as u64;
    let commit_grace_ms = json_i64_field(&config, "commitGraceMs")?.max(0) as u64;
    let generation = json_i64_field(&config, "generation")?;
    let command = json_string_list_field(&config, "command")?;

    let rollback = |reason: &str, candidate_pid: i64, exit_code: i64| -> Result<(), String> {
        let payload = upgrade_transaction_json(
            &service_root,
            &service_id,
            generation,
            "rolled_back",
            false,
            true,
            reason,
            &service_path,
            &transaction_path,
            &snapshot_path,
            &heartbeat_path,
            &stdout_path,
            &stderr_path,
            candidate_pid,
            exit_code,
        );
        write_json_file_atomic(&transaction_path, &payload)?;
        remove_file_if_exists(&lock_path)
    };

    remove_file_if_exists(&ready_path)?;
    write_json_file_atomic(
        &transaction_path,
        &upgrade_transaction_json(
            &service_root,
            &service_id,
            generation,
            "spawning",
            false,
            false,
            "",
            &service_path,
            &transaction_path,
            &snapshot_path,
            &heartbeat_path,
            &stdout_path,
            &stderr_path,
            0,
            -1,
        ),
    )?;

    let child_env = vec![
        (
            "CLASP_RT_UPGRADE_SNAPSHOT_PATH_JSON".to_owned(),
            json_string_literal(&snapshot_path),
        ),
        (
            "CLASP_RT_UPGRADE_SERVICE_ROOT_JSON".to_owned(),
            json_string_literal(&service_root),
        ),
        (
            "CLASP_RT_UPGRADE_SERVICE_ID_JSON".to_owned(),
            json_string_literal(&service_id),
        ),
        (
            "CLASP_RT_UPGRADE_TRANSACTION_PATH_JSON".to_owned(),
            json_string_literal(&transaction_path),
        ),
        (
            "CLASP_RT_UPGRADE_GENERATION_JSON".to_owned(),
            generation.to_string(),
        ),
        (
            "CLASP_RT_SERVICE_SUPERVISED_JSON".to_owned(),
            "true".to_owned(),
        ),
    ];
    let initial_payload = spawn_watched_process_with_env_json(
        &cwd,
        &stdout_path,
        &stderr_path,
        &heartbeat_path,
        watch_poll_ms,
        &child_env,
        &command,
    )?;
    let initial: serde_json::Value = serde_json::from_str(&initial_payload)
        .map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
    let candidate_pid = initial
        .get("pid")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0);
    write_json_file_atomic(
        &transaction_path,
        &upgrade_transaction_json(
            &service_root,
            &service_id,
            generation,
            "waiting-ready",
            false,
            false,
            "",
            &service_path,
            &transaction_path,
            &snapshot_path,
            &heartbeat_path,
            &stdout_path,
            &stderr_path,
            candidate_pid,
            -1,
        ),
    )?;

    let started = Instant::now();
    loop {
        let reconciled_payload = reconcile_watched_process_json(&heartbeat_path)?;
        let reconciled: serde_json::Value = serde_json::from_str(&reconciled_payload)
            .map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
        let running = reconciled
            .get("running")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        let completed = reconciled
            .get("completed")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        if completed || !running {
            let exit_code = reconciled
                .get("exitCode")
                .and_then(serde_json::Value::as_i64)
                .unwrap_or(-1);
            return rollback(
                &format!("candidate exited before ready:{exit_code}"),
                candidate_pid,
                exit_code,
            );
        }
        if ready_marker_matches(&ready_path, &ready_contains)? {
            break;
        }
        if started.elapsed() >= Duration::from_millis(ready_timeout_ms) {
            return rollback("candidate ready timeout", candidate_pid, -1);
        }
        let remaining_ms = ready_timeout_ms.saturating_sub(started.elapsed().as_millis() as u64);
        thread::sleep(Duration::from_millis(ready_poll_ms.min(remaining_ms.max(1))));
    }

    write_json_file_atomic(
        &transaction_path,
        &upgrade_transaction_json(
            &service_root,
            &service_id,
            generation,
            "ready",
            false,
            false,
            "",
            &service_path,
            &transaction_path,
            &snapshot_path,
            &heartbeat_path,
            &stdout_path,
            &stderr_path,
            candidate_pid,
            -1,
        ),
    )?;

    if commit_grace_ms > 0 {
        match await_watched_process_timeout_json(&heartbeat_path, watch_poll_ms, commit_grace_ms) {
            Err(message) if message == "timeout" => {}
            Ok(payload) => {
                let final_state: serde_json::Value = serde_json::from_str(&payload)
                    .map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
                let exit_code = final_state
                    .get("exitCode")
                    .and_then(serde_json::Value::as_i64)
                    .unwrap_or(-1);
                return rollback(
                    &format!("candidate exited during commit grace:{exit_code}"),
                    candidate_pid,
                    exit_code,
                );
            }
            Err(message) => return rollback(&message, candidate_pid, -1),
        }
    }

    write_json_file_atomic(
        &service_path,
        &service_status_json(
            &service_root,
            &service_id,
            generation,
            "active",
            candidate_pid,
            &heartbeat_path,
            &transaction_path,
            &snapshot_path,
            -1,
        ),
    )?;
    write_json_file_atomic(
        &transaction_path,
        &upgrade_transaction_json(
            &service_root,
            &service_id,
            generation,
            "committed",
            true,
            false,
            "",
            &service_path,
            &transaction_path,
            &snapshot_path,
            &heartbeat_path,
            &stdout_path,
            &stderr_path,
            candidate_pid,
            -1,
        ),
    )?;
    remove_file_if_exists(&lock_path)?;

    let final_payload = await_watched_process_json(&heartbeat_path, watch_poll_ms)?;
    let final_state: serde_json::Value = serde_json::from_str(&final_payload)
        .map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
    let exit_code = final_state
        .get("exitCode")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(-1);
    let final_status = if exit_code == 0 { "completed" } else { "failed" };
    write_json_file_atomic(
        &service_path,
        &service_status_json(
            &service_root,
            &service_id,
            generation,
            final_status,
            candidate_pid,
            &heartbeat_path,
            &transaction_path,
            &snapshot_path,
            exit_code,
        ),
    )?;
    write_json_file_atomic(
        &transaction_path,
        &upgrade_transaction_json(
            &service_root,
            &service_id,
            generation,
            "completed",
            true,
            false,
            "",
            &service_path,
            &transaction_path,
            &snapshot_path,
            &heartbeat_path,
            &stdout_path,
            &stderr_path,
            candidate_pid,
            exit_code,
        ),
    )
}

pub fn clasp_rt_run_upgrade_supervisor_command(config_path: &str) -> Result<(), String> {
    run_upgrade_supervisor_from_config(config_path)
}

fn run_service_supervisor_from_config(config_path: &str) -> Result<(), String> {
    let config = read_json_file(config_path)?;
    let cwd = json_string_field(&config, "cwd")?;
    let service_root = json_string_field(&config, "serviceRoot")?;
    let service_id = json_string_field(&config, "serviceId")?;
    let service_path = json_string_field(&config, "servicePath")?;
    let lock_path = json_string_field(&config, "lockPath")?;
    let final_status_path = config
        .get("finalStatusPath")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_owned();
    let ready_path = json_string_field(&config, "readyPath")?;
    let ready_contains = json_string_field(&config, "readyContains")?;
    let watch_poll_ms = json_i64_field(&config, "watchPollMs")?.max(50) as u64;
    let ready_poll_ms = json_i64_field(&config, "readyPollMs")?.max(10) as u64;
    let ready_timeout_ms = json_i64_field(&config, "readyTimeoutMs")?.max(1) as u64;
    let restart_delay_ms = json_i64_field(&config, "restartDelayMs")?.max(0) as u64;
    let command = json_string_list_field(&config, "command")?;
    let service_root_path = Path::new(&service_root).to_path_buf();
    fs::create_dir_all(service_root_path.join("runs")).map_err(|err| err.to_string())?;

    write_json_file_atomic(
        &lock_path,
        &serde_json::json!({
            "supervisorPid": std::process::id() as i64,
            "configPath": config_path,
            "createdAtMs": runtime_time_unix_ms(),
        }),
    )?;

    let mut generation = read_json_file(&service_path)
        .ok()
        .and_then(|value| value.get("generation").and_then(serde_json::Value::as_i64))
        .unwrap_or(0);

    loop {
        generation += 1;
        let run_id = format!("run-{}-{}", generation, runtime_time_unix_ms());
        let run_root = service_root_path.join("runs").join(&run_id);
        fs::create_dir_all(&run_root).map_err(|err| err.to_string())?;
        let stdout_path = run_root.join("service.stdout.log");
        let stderr_path = run_root.join("service.stderr.log");
        let heartbeat_path = run_root.join("service.heartbeat.json");

        remove_file_if_exists(&ready_path)?;

        let child_env = vec![
            (
                "CLASP_RT_SERVICE_SUPERVISED_JSON".to_owned(),
                "true".to_owned(),
            ),
            (
                "CLASP_RT_SERVICE_ROOT_JSON".to_owned(),
                json_string_literal(&service_root),
            ),
            (
                "CLASP_RT_SERVICE_ID_JSON".to_owned(),
                json_string_literal(&service_id),
            ),
            (
                "CLASP_RT_SERVICE_GENERATION_JSON".to_owned(),
                generation.to_string(),
            ),
        ];
        let initial_payload = spawn_watched_process_with_env_json(
            &cwd,
            &stdout_path.to_string_lossy(),
            &stderr_path.to_string_lossy(),
            &heartbeat_path.to_string_lossy(),
            watch_poll_ms,
            &child_env,
            &command,
        )?;
        let initial: serde_json::Value = serde_json::from_str(&initial_payload)
            .map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
        let owner_pid = initial
            .get("pid")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0);

        write_json_file_atomic(
            &service_path,
            &service_status_json(
                &service_root,
                &service_id,
                generation,
                "starting",
                owner_pid,
                &heartbeat_path.to_string_lossy(),
                config_path,
                "",
                -1,
            ),
        )?;

        let ready_started = Instant::now();
        let mut ready = false;
        loop {
            let reconciled_payload = reconcile_watched_process_json(&heartbeat_path.to_string_lossy())?;
            let reconciled: serde_json::Value = serde_json::from_str(&reconciled_payload)
                .map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
            let running = reconciled
                .get("running")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            let completed = reconciled
                .get("completed")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            if completed || !running {
                let exit_code = reconciled
                    .get("exitCode")
                    .and_then(serde_json::Value::as_i64)
                    .unwrap_or(-1);
                if workflow_status_is_final(&final_status_path) {
                    write_json_file_atomic(
                        &service_path,
                        &service_status_json(
                            &service_root,
                            &service_id,
                            generation,
                            "completed",
                            owner_pid,
                            &heartbeat_path.to_string_lossy(),
                            config_path,
                            "",
                            exit_code,
                        ),
                    )?;
                    remove_file_if_exists(&lock_path)?;
                    return Ok(());
                }
                write_json_file_atomic(
                    &service_path,
                    &service_status_json(
                        &service_root,
                        &service_id,
                        generation,
                        "restarting",
                        owner_pid,
                        &heartbeat_path.to_string_lossy(),
                        config_path,
                        "",
                        exit_code,
                    ),
                )?;
                break;
            }
            if ready_marker_matches(&ready_path, &ready_contains)? {
                ready = true;
                write_json_file_atomic(
                    &service_path,
                    &service_status_json(
                        &service_root,
                        &service_id,
                        generation,
                        "active",
                        owner_pid,
                        &heartbeat_path.to_string_lossy(),
                        config_path,
                        "",
                        -1,
                    ),
                )?;
                break;
            }
            if ready_started.elapsed() >= Duration::from_millis(ready_timeout_ms) {
                write_json_file_atomic(
                    &service_path,
                    &service_status_json(
                        &service_root,
                        &service_id,
                        generation,
                        "failed",
                        owner_pid,
                        &heartbeat_path.to_string_lossy(),
                        config_path,
                        "",
                        -1,
                    ),
                )?;
                remove_file_if_exists(&lock_path)?;
                return Err("service ready timeout".to_owned());
            }
            let remaining_ms = ready_timeout_ms.saturating_sub(ready_started.elapsed().as_millis() as u64);
            thread::sleep(Duration::from_millis(ready_poll_ms.min(remaining_ms.max(1))));
        }

        if !ready {
            if restart_delay_ms > 0 {
                thread::sleep(Duration::from_millis(restart_delay_ms));
            }
            continue;
        }

        let final_payload = await_watched_process_json(&heartbeat_path.to_string_lossy(), watch_poll_ms)?;
        let final_state: serde_json::Value = serde_json::from_str(&final_payload)
            .map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
        let exit_code = final_state
            .get("exitCode")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(-1);

        if exit_code == 0 || workflow_status_is_final(&final_status_path) {
            write_json_file_atomic(
                &service_path,
                &service_status_json(
                    &service_root,
                    &service_id,
                    generation,
                    "completed",
                    owner_pid,
                    &heartbeat_path.to_string_lossy(),
                    config_path,
                    "",
                    exit_code,
                ),
            )?;
            remove_file_if_exists(&lock_path)?;
            return Ok(());
        }

        write_json_file_atomic(
            &service_path,
            &service_status_json(
                &service_root,
                &service_id,
                generation,
                "restarting",
                owner_pid,
                &heartbeat_path.to_string_lossy(),
                config_path,
                "",
                exit_code,
            ),
        )?;
        if restart_delay_ms > 0 {
            thread::sleep(Duration::from_millis(restart_delay_ms));
        }
    }
}

pub fn clasp_rt_run_service_supervisor_command(config_path: &str) -> Result<(), String> {
    run_service_supervisor_from_config(config_path)
}

fn supervise_command_json(cwd: &str, args: &[String]) -> Result<String, String> {
    if args.len() < 9 {
        return Err("invalid_supervise_command".to_owned());
    }

    let service_root = args[0].clone();
    let service_id = args[1].clone();
    let ready_path = args[2].clone();
    let ready_contains = args[3].clone();
    let watch_poll_ms = args[4]
        .parse::<u64>()
        .map_err(|_| "invalid_watch_poll_ms".to_owned())?
        .max(50);
    let ready_poll_ms = args[5]
        .parse::<u64>()
        .map_err(|_| "invalid_ready_poll_ms".to_owned())?
        .max(10);
    let ready_timeout_ms = args[6]
        .parse::<u64>()
        .map_err(|_| "invalid_ready_timeout_ms".to_owned())?
        .max(1);
    let restart_delay_ms = args[7]
        .parse::<u64>()
        .map_err(|_| "invalid_restart_delay_ms".to_owned())?;
    let command = args[8..].to_vec();

    if service_root.is_empty() {
        return Err("missing_service_root".to_owned());
    }
    if service_id.is_empty() {
        return Err("missing_service_id".to_owned());
    }
    if ready_path.is_empty() {
        return Err("missing_service_ready_path".to_owned());
    }
    if command.is_empty() {
        return Err("missing_service_command".to_owned());
    }

    let service_root_path = Path::new(&service_root).to_path_buf();
    fs::create_dir_all(&service_root_path).map_err(|err| err.to_string())?;
    let service_path = service_root_path.join("service.json");
    let lock_path = service_root_path.join("supervisor.lock");
    let config_path = service_root_path.join("supervisor.config.json");
    let final_status_path = Path::new(&ready_path)
        .parent()
        .map(|parent| parent.join("status.json").display().to_string())
        .unwrap_or_default();
    clear_stale_service_supervisor_lock(&lock_path.to_string_lossy())?;
    if !lock_path.exists() {
        clear_stale_service_status_for_restart(&service_path)?;
    }

    let config_payload = serde_json::json!({
        "cwd": cwd,
        "serviceRoot": service_root,
        "serviceId": service_id,
        "servicePath": service_path.display().to_string(),
        "lockPath": lock_path.display().to_string(),
        "finalStatusPath": final_status_path,
        "readyPath": ready_path,
        "readyContains": ready_contains,
        "watchPollMs": watch_poll_ms as i64,
        "readyPollMs": ready_poll_ms as i64,
        "readyTimeoutMs": ready_timeout_ms as i64,
        "restartDelayMs": restart_delay_ms as i64,
        "command": command,
    });
    write_json_file_atomic(&config_path.to_string_lossy(), &config_payload)?;

    if !lock_path.exists() {
        let current_exe =
            env::current_exe().map_err(|err| format!("failed to resolve current executable: {err}"))?;
        let mut supervisor = ProcessCommand::new(current_exe);
        supervisor
            .arg("__clasp-service-supervisor")
            .arg(&config_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null());
        if env::var("CLASP_RT_TRACE_UPGRADE").is_ok() {
            supervisor.stderr(Stdio::inherit());
        } else {
            supervisor.stderr(Stdio::null());
        }
        let spawned = supervisor
            .spawn()
            .map_err(|err| format!("failed to spawn service supervisor: {err}"))?;
        write_json_file_atomic(
            &lock_path.to_string_lossy(),
            &serde_json::json!({
                "supervisorPid": spawned.id() as i64,
                "configPath": config_path.display().to_string(),
                "createdAtMs": runtime_time_unix_ms(),
            }),
        )?;
    }

    service_wait_result(
        &service_path.to_string_lossy(),
        ready_timeout_ms.saturating_add(restart_delay_ms).saturating_add(5000),
    )
}

fn upgrade_command_json(cwd: &str, args: &[String]) -> Result<String, String> {
    if args.len() < 10 {
        return Err("invalid_upgrade_command".to_owned());
    }

    let service_root = args[0].clone();
    let service_id = args[1].clone();
    let snapshot_text = args[2].clone();
    let ready_path = args[3].clone();
    let ready_contains = args[4].clone();
    let watch_poll_ms = args[5]
        .parse::<u64>()
        .map_err(|_| "invalid_watch_poll_ms".to_owned())?
        .max(50);
    let ready_poll_ms = args[6]
        .parse::<u64>()
        .map_err(|_| "invalid_ready_poll_ms".to_owned())?
        .max(10);
    let ready_timeout_ms = args[7]
        .parse::<u64>()
        .map_err(|_| "invalid_ready_timeout_ms".to_owned())?
        .max(1);
    let commit_grace_ms = args[8]
        .parse::<u64>()
        .map_err(|_| "invalid_commit_grace_ms".to_owned())?;
    let command = args[9..].to_vec();

    if service_root.is_empty() {
        return Err("missing_upgrade_service_root".to_owned());
    }
    if service_id.is_empty() {
        return Err("missing_upgrade_service_id".to_owned());
    }
    if ready_path.is_empty() {
        return Err("missing_upgrade_ready_path".to_owned());
    }
    if command.is_empty() {
        return Err("missing_upgrade_command".to_owned());
    }

    let service_root_path = Path::new(&service_root).to_path_buf();
    fs::create_dir_all(&service_root_path).map_err(|err| err.to_string())?;
    let service_path = service_root_path.join("service.json");
    let lock_path = service_root_path.join("upgrade.lock");
    clear_stale_upgrade_lock(&lock_path.to_string_lossy())?;
    let current_generation = read_json_file(&service_path.to_string_lossy())
        .ok()
        .and_then(|value| value.get("generation").and_then(serde_json::Value::as_i64))
        .unwrap_or(0);
    let generation = current_generation + 1;
    let transaction_id = format!("tx-{}-{}", runtime_time_unix_ms(), std::process::id());
    let transaction_root = service_root_path.join("transactions").join(&transaction_id);
    fs::create_dir_all(&transaction_root).map_err(|err| err.to_string())?;
    let transaction_path = transaction_root.join("transaction.json");
    let config_path = transaction_root.join("config.json");
    let snapshot_path = transaction_root.join("snapshot.json");
    let stdout_path = transaction_root.join("candidate.stdout.log");
    let stderr_path = transaction_root.join("candidate.stderr.log");
    let heartbeat_path = transaction_root.join("candidate.heartbeat.json");

    let lock_payload = serde_json::json!({
        "transactionPath": transaction_path.display().to_string(),
        "createdAtMs": runtime_time_unix_ms(),
    });
    write_json_file_atomic(&lock_path.to_string_lossy(), &lock_payload)?;
    fs::write(&snapshot_path, snapshot_text.as_bytes()).map_err(|err| err.to_string())?;
    write_json_file_atomic(
        &transaction_path.to_string_lossy(),
        &upgrade_transaction_json(
            &service_root,
            &service_id,
            generation,
            "preparing",
            false,
            false,
            "",
            &service_path.to_string_lossy(),
            &transaction_path.to_string_lossy(),
            &snapshot_path.to_string_lossy(),
            &heartbeat_path.to_string_lossy(),
            &stdout_path.to_string_lossy(),
            &stderr_path.to_string_lossy(),
            0,
            -1,
        ),
    )?;

    let config_payload = serde_json::json!({
        "cwd": cwd,
        "serviceRoot": service_root,
        "serviceId": service_id,
        "servicePath": service_path.display().to_string(),
        "lockPath": lock_path.display().to_string(),
        "transactionPath": transaction_path.display().to_string(),
        "snapshotPath": snapshot_path.display().to_string(),
        "stdoutPath": stdout_path.display().to_string(),
        "stderrPath": stderr_path.display().to_string(),
        "heartbeatPath": heartbeat_path.display().to_string(),
        "readyPath": ready_path,
        "readyContains": ready_contains,
        "watchPollMs": watch_poll_ms as i64,
        "readyPollMs": ready_poll_ms as i64,
        "readyTimeoutMs": ready_timeout_ms as i64,
        "commitGraceMs": commit_grace_ms as i64,
        "generation": generation,
        "command": command,
    });
    write_json_file_atomic(&config_path.to_string_lossy(), &config_payload)?;

    let current_exe =
        env::current_exe().map_err(|err| format!("failed to resolve current executable: {err}"))?;
    let mut supervisor = ProcessCommand::new(current_exe);
    supervisor
        .arg("__clasp-upgrade-supervisor")
        .arg(config_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null());
    if env::var("CLASP_RT_TRACE_UPGRADE").is_ok() {
        supervisor.stderr(Stdio::inherit());
    } else {
        supervisor.stderr(Stdio::null());
    }
    supervisor
        .spawn()
        .map_err(|err| format!("failed to spawn upgrade supervisor: {err}"))?;

    let wait_timeout_ms = ready_timeout_ms
        .saturating_add(commit_grace_ms)
        .saturating_add(5000);
    upgrade_wait_result(&transaction_path.to_string_lossy(), wait_timeout_ms)
}

fn handoff_watched_process_json(cwd: &str, args: &[String]) -> Result<String, String> {
    if args.len() < 9 {
        return Err("invalid_handoff_command".to_owned());
    }

    let stdout_path = args[0].clone();
    let stderr_path = args[1].clone();
    let heartbeat_path = args[2].clone();
    let watch_poll_ms = args[3]
        .parse::<u64>()
        .map_err(|_| "invalid_watch_poll_ms".to_owned())?
        .max(50);
    let ready_path = args[4].clone();
    let ready_contains = args[5].clone();
    let ready_poll_ms = args[6]
        .parse::<u64>()
        .map_err(|_| "invalid_ready_poll_ms".to_owned())?
        .max(10);
    let ready_timeout_ms = args[7]
        .parse::<u64>()
        .map_err(|_| "invalid_ready_timeout_ms".to_owned())?
        .max(1);
    let handoff_command = args[8..].to_vec();

    if ready_path.is_empty() {
        return Err("missing_handoff_ready_path".to_owned());
    }
    if handoff_command.is_empty() {
        return Err("missing_handoff_command".to_owned());
    }

    match fs::remove_file(&ready_path) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => return Err(err.to_string()),
    }

    let mut spawn_args = vec![
        stdout_path,
        stderr_path,
        heartbeat_path.clone(),
        watch_poll_ms.to_string(),
    ];
    spawn_args.extend(handoff_command);
    let _initial = spawn_watched_process_json(cwd, &spawn_args)?;
    let started = Instant::now();

    loop {
        let reconciled_payload = reconcile_watched_process_json(&heartbeat_path)?;
        let reconciled: serde_json::Value = serde_json::from_str(&reconciled_payload)
            .map_err(|err| format!("invalid watched process heartbeat: {err}"))?;
        let running = reconciled
            .get("running")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        let completed = reconciled
            .get("completed")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        if completed || !running {
            let exit_code = reconciled
                .get("exitCode")
                .and_then(serde_json::Value::as_i64)
                .unwrap_or(-1);
            return Err(format!("handoff_process_exited_before_ready:{exit_code}"));
        }

        if ready_marker_matches(&ready_path, &ready_contains)? {
            return Ok(reconciled_payload);
        }

        if started.elapsed() >= Duration::from_millis(ready_timeout_ms) {
            return Err("handoff_ready_timeout".to_owned());
        }

        let remaining_ms = ready_timeout_ms.saturating_sub(started.elapsed().as_millis() as u64);
        thread::sleep(Duration::from_millis(ready_poll_ms.min(remaining_ms.max(1))));
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_view_text(value: *mut ClaspRtString) -> *mut ClaspRtHeader {
    if value.is_null() {
        return null_mut();
    }
    clasp_rt_build_record_header(
        "ViewText",
        vec![
            ("kind".to_owned(), clasp_rt_build_string_header("text")),
            (
                "text".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(value))),
            ),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_page(
    title: *mut ClaspRtString,
    body: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if title.is_null() || body.is_null() {
        return null_mut();
    }
    retain_header(body);
    clasp_rt_build_record_header(
        "Page",
        vec![
            ("kind".to_owned(), clasp_rt_build_string_header("page")),
            (
                "title".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(title))),
            ),
            ("body".to_owned(), body),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_redirect(location: *mut ClaspRtString) -> *mut ClaspRtHeader {
    if location.is_null() {
        return null_mut();
    }
    clasp_rt_build_record_header(
        "Redirect",
        vec![
            ("kind".to_owned(), clasp_rt_build_string_header("redirect")),
            (
                "location".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(location))),
            ),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_principal(id: *mut ClaspRtString) -> *mut ClaspRtHeader {
    if id.is_null() {
        return null_mut();
    }
    clasp_rt_build_record_header(
        "Principal",
        vec![(
            "id".to_owned(),
            clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(id))),
        )],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_tenant(id: *mut ClaspRtString) -> *mut ClaspRtHeader {
    if id.is_null() {
        return null_mut();
    }
    clasp_rt_build_record_header(
        "Tenant",
        vec![(
            "id".to_owned(),
            clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(id))),
        )],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_resource_identity(
    resource_type: *mut ClaspRtString,
    resource_id: *mut ClaspRtString,
) -> *mut ClaspRtHeader {
    if resource_type.is_null() || resource_id.is_null() {
        return null_mut();
    }
    clasp_rt_build_record_header(
        "ResourceIdentity",
        vec![
            (
                "resourceType".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(resource_type))),
            ),
            (
                "resourceId".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(resource_id))),
            ),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_auth_session(
    session_id: *mut ClaspRtString,
    principal: *mut ClaspRtHeader,
    tenant: *mut ClaspRtHeader,
    resource: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if session_id.is_null() || principal.is_null() || tenant.is_null() || resource.is_null() {
        return null_mut();
    }
    retain_header(principal);
    retain_header(tenant);
    retain_header(resource);
    clasp_rt_build_record_header(
        "AuthSession",
        vec![
            (
                "sessionId".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(session_id))),
            ),
            ("principal".to_owned(), principal),
            ("tenant".to_owned(), tenant),
            ("resource".to_owned(), resource),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_view_append(
    left: *mut ClaspRtHeader,
    right: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if left.is_null() || right.is_null() {
        return null_mut();
    }
    retain_header(left);
    retain_header(right);
    clasp_rt_build_record_header(
        "ViewAppend",
        vec![
            ("kind".to_owned(), clasp_rt_build_string_header("append")),
            ("left".to_owned(), left),
            ("right".to_owned(), right),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_view_element(
    tag: *mut ClaspRtString,
    child: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if tag.is_null() || child.is_null() {
        return null_mut();
    }
    retain_header(child);
    clasp_rt_build_record_header(
        "ViewElement",
        vec![
            ("kind".to_owned(), clasp_rt_build_string_header("element")),
            (
                "tag".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(tag))),
            ),
            ("child".to_owned(), child),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_view_styled(
    style_ref: *mut ClaspRtString,
    child: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if style_ref.is_null() || child.is_null() {
        return null_mut();
    }
    retain_header(child);
    clasp_rt_build_record_header(
        "ViewStyled",
        vec![
            ("kind".to_owned(), clasp_rt_build_string_header("styled")),
            (
                "styleRef".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(style_ref))),
            ),
            ("child".to_owned(), child),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_view_link(
    href: *mut ClaspRtString,
    child: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if href.is_null() || child.is_null() {
        return null_mut();
    }
    retain_header(child);
    clasp_rt_build_record_header(
        "ViewLink",
        vec![
            ("kind".to_owned(), clasp_rt_build_string_header("link")),
            (
                "href".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(href))),
            ),
            ("child".to_owned(), child),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_view_form(
    method: *mut ClaspRtString,
    action: *mut ClaspRtString,
    child: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if method.is_null() || action.is_null() || child.is_null() {
        return null_mut();
    }
    retain_header(child);
    clasp_rt_build_record_header(
        "ViewForm",
        vec![
            ("kind".to_owned(), clasp_rt_build_string_header("form")),
            (
                "method".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(method))),
            ),
            (
                "action".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(action))),
            ),
            ("child".to_owned(), child),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_view_input(
    field_name: *mut ClaspRtString,
    input_kind: *mut ClaspRtString,
    value: *mut ClaspRtString,
) -> *mut ClaspRtHeader {
    if field_name.is_null() || input_kind.is_null() || value.is_null() {
        return null_mut();
    }
    clasp_rt_build_record_header(
        "ViewInput",
        vec![
            ("kind".to_owned(), clasp_rt_build_string_header("input")),
            (
                "fieldName".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(field_name))),
            ),
            (
                "inputKind".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(input_kind))),
            ),
            (
                "value".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(value))),
            ),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_view_submit(label: *mut ClaspRtString) -> *mut ClaspRtHeader {
    if label.is_null() {
        return null_mut();
    }
    clasp_rt_build_record_header(
        "ViewSubmit",
        vec![
            ("kind".to_owned(), clasp_rt_build_string_header("submit")),
            (
                "label".to_owned(),
                clasp_rt_build_string_header(&String::from_utf8_lossy(string_bytes(label))),
            ),
        ],
    )
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_system_prompt(content: *mut ClaspRtString) -> *mut ClaspRtHeader {
    let message = build_prompt_message_header("system", content);
    if message.is_null() {
        return null_mut();
    }
    build_prompt_header(vec![message])
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_assistant_prompt(content: *mut ClaspRtString) -> *mut ClaspRtHeader {
    let message = build_prompt_message_header("assistant", content);
    if message.is_null() {
        return null_mut();
    }
    build_prompt_header(vec![message])
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_user_prompt(content: *mut ClaspRtString) -> *mut ClaspRtHeader {
    let message = build_prompt_message_header("user", content);
    if message.is_null() {
        return null_mut();
    }
    build_prompt_header(vec![message])
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_append_prompt(
    left: *mut ClaspRtHeader,
    right: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    let Some(left_messages) = prompt_messages_cloned(left) else {
        return null_mut();
    };
    let Some(right_messages) = prompt_messages_cloned(right) else {
        release_owned_headers(left_messages);
        return null_mut();
    };
    let mut combined = left_messages;
    combined.extend(right_messages);
    build_prompt_header(combined)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_prompt_text(prompt: *mut ClaspRtHeader) -> *mut ClaspRtString {
    let Some(messages) = prompt_messages_cloned(prompt) else {
        return null_mut();
    };
    let mut rendered = String::new();
    for (index, message) in messages.iter().enumerate() {
        if message.is_null() || (**message).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
            release_owned_headers(messages);
            return null_mut();
        }
        let message_record = *message as *mut ClaspRtRecordValue;
        let Some(role_value) = record_field_value_by_name(message_record, b"role") else {
            release_owned_headers(messages);
            return null_mut();
        };
        let Some(content_value) = record_field_value_by_name(message_record, b"content") else {
            release_owned_headers(messages);
            return null_mut();
        };
        if role_value.is_null()
            || content_value.is_null()
            || (*role_value).layout_id != CLASP_RT_LAYOUT_STRING
            || (*content_value).layout_id != CLASP_RT_LAYOUT_STRING
        {
            release_owned_headers(messages);
            return null_mut();
        }
        if index > 0 {
            rendered.push_str("\n\n");
        }
        rendered.push_str(&String::from_utf8_lossy(string_bytes(role_value as *mut ClaspRtString)));
        rendered.push_str(": ");
        rendered.push_str(&String::from_utf8_lossy(string_bytes(content_value as *mut ClaspRtString)));
    }
    release_owned_headers(messages);
    build_runtime_string(rendered.as_bytes())
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_text_join(
    separator: *mut ClaspRtString,
    parts: *mut ClaspRtStringList,
) -> *mut ClaspRtString {
    let items = string_list_items_mut(parts);
    build_runtime_string(&join_string_bytes(items, string_bytes(separator)))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_text_split(
    value: *mut ClaspRtString,
    separator: *mut ClaspRtString,
) -> *mut ClaspRtStringList {
    let value_bytes = string_bytes(value);
    let separator_bytes = string_bytes(separator);
    if separator_bytes.is_empty() {
        let list = build_runtime_string_list(1);
        string_list_items_mut(list)[0] = build_runtime_string(value_bytes);
        return list;
    }

    let mut parts: Vec<Vec<u8>> = Vec::new();
    let mut segment_start = 0usize;
    while let Some(match_index) = find_subslice(value_bytes, separator_bytes, segment_start) {
        parts.push(value_bytes[segment_start..match_index].to_vec());
        segment_start = match_index + separator_bytes.len();
    }
    parts.push(value_bytes[segment_start..].to_vec());

    let list = build_runtime_string_list(parts.len());
    for (index, part) in parts.iter().enumerate() {
        string_list_items_mut(list)[index] = build_runtime_string(part);
    }
    list
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_text_contains(
    value: *mut ClaspRtString,
    needle: *mut ClaspRtString,
) -> bool {
    find_subslice(string_bytes(value), string_bytes(needle), 0).is_some()
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_text_chars(value: *mut ClaspRtString) -> *mut ClaspRtStringList {
    let bytes = string_bytes(value);
    let list = build_runtime_string_list(bytes.len());
    for (index, byte) in bytes.iter().enumerate() {
        string_list_items_mut(list)[index] = build_runtime_string(slice::from_ref(byte));
    }
    list
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_text_fingerprint64_hex(value: *mut ClaspRtString) -> *mut ClaspRtString {
    const FNV_OFFSET: u64 = 14695981039346656037;
    const FNV_PRIME: u64 = 1099511628211;

    let mut fingerprint = FNV_OFFSET;
    for &byte in string_bytes(value) {
        fingerprint ^= u64::from(byte);
        fingerprint = fingerprint.wrapping_mul(FNV_PRIME);
    }

    build_runtime_string(format!("{fingerprint:016x}").as_bytes())
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_text_prefix(
    value: *mut ClaspRtString,
    prefix: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let value_bytes = string_bytes(value);
    let prefix_bytes = string_bytes(prefix);
    if value_bytes.starts_with(prefix_bytes) {
        clasp_rt_result_ok_string(build_runtime_string(&value_bytes[prefix_bytes.len()..]))
    } else {
        clasp_rt_result_err_string(build_runtime_string(value_bytes))
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_text_split_first(
    value: *mut ClaspRtString,
    separator: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let value_bytes = string_bytes(value);
    let separator_bytes = string_bytes(separator);
    if separator_bytes.is_empty() {
        let mut payload = Vec::with_capacity(value_bytes.len() + 1);
        payload.extend_from_slice(value_bytes);
        payload.push(b'\n');
        return clasp_rt_result_ok_string(build_runtime_string(&payload));
    }
    match find_subslice(value_bytes, separator_bytes, 0) {
        Some(match_index) => {
            let mut payload =
                Vec::with_capacity(value_bytes.len().saturating_sub(separator_bytes.len()) + 1);
            payload.extend_from_slice(&value_bytes[..match_index]);
            payload.push(b'\n');
            payload.extend_from_slice(&value_bytes[match_index + separator_bytes.len()..]);
            clasp_rt_result_ok_string(build_runtime_string(&payload))
        }
        None => clasp_rt_result_err_string(build_runtime_string(value_bytes)),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_dict_empty() -> *mut ClaspRtHeader {
    clasp_rt_build_record_header("Dict", Vec::new())
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_dict_set(
    key: *mut ClaspRtString,
    value: *mut ClaspRtHeader,
    dict: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if key.is_null() || dict.is_null() || (*dict).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }
    let dict_value = dict as *mut ClaspRtRecordValue;
    if !record_is_dict(dict_value) {
        return null_mut();
    }
    let key_text = String::from_utf8_lossy(string_bytes(key)).into_owned();
    clasp_rt_build_record_header("Dict", dict_clone_fields(dict_value, None, Some((&key_text, value))))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_dict_get(
    key: *mut ClaspRtString,
    dict: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if key.is_null() || dict.is_null() || (*dict).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }
    let dict_value = dict as *mut ClaspRtRecordValue;
    if !record_is_dict(dict_value) {
        return null_mut();
    }
    let key_bytes = string_bytes(key);
    match record_field_value_by_name(dict_value, key_bytes) {
        Some(value) => {
            retain_header(value);
            clasp_rt_build_variant_header("Ok", vec![value])
        }
        None => clasp_rt_build_variant_header(
            "Err",
            vec![clasp_rt_build_string_header(&format!(
                "Missing dict key: {}",
                String::from_utf8_lossy(key_bytes)
            ))],
        ),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_dict_has(
    key: *mut ClaspRtString,
    dict: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if key.is_null() || dict.is_null() || (*dict).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }
    let dict_value = dict as *mut ClaspRtRecordValue;
    if !record_is_dict(dict_value) {
        return null_mut();
    }
    clasp_rt_build_bool_header(record_field_value_by_name(dict_value, string_bytes(key)).is_some())
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_dict_remove(
    key: *mut ClaspRtString,
    dict: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    if key.is_null() || dict.is_null() || (*dict).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }
    let dict_value = dict as *mut ClaspRtRecordValue;
    if !record_is_dict(dict_value) {
        return null_mut();
    }
    clasp_rt_build_record_header("Dict", dict_clone_fields(dict_value, Some(string_bytes(key)), None))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_dict_keys(dict: *mut ClaspRtHeader) -> *mut ClaspRtHeader {
    if dict.is_null() || (*dict).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }
    let dict_value = dict as *mut ClaspRtRecordValue;
    if !record_is_dict(dict_value) {
        return null_mut();
    }
    let mut items = Vec::new();
    for name_ptr in record_field_names(dict_value) {
        items.push(build_runtime_string(string_bytes(*name_ptr)) as *mut ClaspRtHeader);
    }
    clasp_rt_build_list_header(items)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_dict_values(dict: *mut ClaspRtHeader) -> *mut ClaspRtHeader {
    if dict.is_null() || (*dict).layout_id != CLASP_RT_LAYOUT_RECORD_VALUE {
        return null_mut();
    }
    let dict_value = dict as *mut ClaspRtRecordValue;
    if !record_is_dict(dict_value) {
        return null_mut();
    }
    let mut items = Vec::new();
    for value in record_field_values(dict_value) {
        retain_header(*value);
        items.push(*value);
    }
    clasp_rt_build_list_header(items)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_path_join(parts: *mut ClaspRtStringList) -> *mut ClaspRtString {
    let items = string_list_items_mut(parts);
    build_runtime_string(&join_string_bytes(items, b"/"))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_path_dirname(path: *mut ClaspRtString) -> *mut ClaspRtString {
    let path_bytes = string_bytes(path);
    match path_bytes.iter().rposition(|byte| *byte == b'/') {
        Some(index) => build_runtime_string(&path_bytes[..index]),
        None => build_runtime_string(b"."),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_path_basename(path: *mut ClaspRtString) -> *mut ClaspRtString {
    let path_bytes = string_bytes(path);
    match path_bytes.iter().rposition(|byte| *byte == b'/') {
        Some(index) => build_runtime_string(&path_bytes[index + 1..]),
        None => build_runtime_string(path_bytes),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_file_exists(path: *mut ClaspRtString) -> bool {
    let path_string = String::from_utf8_lossy(string_bytes(path)).into_owned();
    std::path::Path::new(&path_string).exists()
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_list_dir(path: *mut ClaspRtString) -> *mut ClaspRtHeader {
    let path_string = String::from_utf8_lossy(string_bytes(path)).into_owned();
    let entries = match fs::read_dir(&path_string) {
        Ok(entries) => entries,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return runtime_result_err("missing");
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotADirectory => {
            return runtime_result_err("not_directory");
        }
        Err(_) => return runtime_result_err("io_error"),
    };

    let mut names = Vec::new();
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => return runtime_result_err("io_error"),
        };
        let name = match entry.file_name().into_string() {
            Ok(name) => name,
            Err(_) => return runtime_result_err("invalid_utf8"),
        };
        names.push(name);
    }
    names.sort();

    let items = names
        .iter()
        .map(|name| build_runtime_string(name.as_bytes()) as *mut ClaspRtHeader)
        .collect();
    runtime_result_ok(clasp_rt_build_list_header(items))
}

#[cfg(unix)]
fn runtime_host_available_disk_mb(path: &str) -> Result<i64, String> {
    let c_path = CString::new(path).map_err(|_| "invalid_path".to_owned())?;
    let mut stat = MaybeUninit::<Statvfs>::zeroed();
    let status = unsafe { statvfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if status != 0 {
        return Err("io_error".to_owned());
    }

    let stat = unsafe { stat.assume_init() };
    let fragment_size = if stat.f_frsize == 0 {
        stat.f_bsize
    } else {
        stat.f_frsize
    };
    let available_bytes = u128::from(stat.f_bavail) * u128::from(fragment_size);
    let available_mb = available_bytes / (1024 * 1024);
    if available_mb > i64::MAX as u128 {
        Ok(i64::MAX)
    } else {
        Ok(available_mb as i64)
    }
}

#[cfg(not(unix))]
fn runtime_host_available_disk_mb(_path: &str) -> Result<i64, String> {
    Err("unsupported_platform".to_owned())
}

#[cfg(target_os = "linux")]
fn runtime_host_available_memory_mb() -> Result<i64, String> {
    let contents = fs::read_to_string("/proc/meminfo").map_err(|_| "io_error".to_owned())?;
    for line in contents.lines() {
        let Some(rest) = line.strip_prefix("MemAvailable:") else {
            continue;
        };
        let Some(kb_text) = rest.split_whitespace().next() else {
            return Err("invalid_mem_available".to_owned());
        };
        let available_kb = kb_text
            .parse::<u128>()
            .map_err(|_| "invalid_mem_available".to_owned())?;
        let available_mb = available_kb / 1024;
        return if available_mb > i64::MAX as u128 {
            Ok(i64::MAX)
        } else {
            Ok(available_mb as i64)
        };
    }

    Err("missing_mem_available".to_owned())
}

#[cfg(not(target_os = "linux"))]
fn runtime_host_available_memory_mb() -> Result<i64, String> {
    Err("unsupported_platform".to_owned())
}

#[cfg(unix)]
fn runtime_host_process_alive(pid_text: &str) -> Result<bool, String> {
    let trimmed = pid_text.trim();
    let pid = trimmed
        .parse::<i64>()
        .map_err(|_| "invalid_pid".to_owned())?;
    if pid <= 0 || pid > i64::from(i32::MAX) {
        return Err("invalid_pid".to_owned());
    }

    let status = unsafe { kill(pid as c_int, 0) };
    if status == 0 {
        return Ok(true);
    }

    match std::io::Error::last_os_error().raw_os_error() {
        Some(1) => Ok(true),
        Some(3) => Ok(false),
        _ => Ok(false),
    }
}

#[cfg(not(unix))]
fn runtime_host_process_alive(_pid_text: &str) -> Result<bool, String> {
    Err("unsupported_platform".to_owned())
}

#[cfg(target_os = "linux")]
fn runtime_proc_has_managed_job_marker(pid_path: &Path) -> bool {
    let Ok(environ) = fs::read(pid_path.join("environ")) else {
        return false;
    };
    let mut has_id = false;
    let mut has_root = false;
    let mut has_token = false;

    for item in environ.split(|byte| *byte == 0) {
        if item.starts_with(b"CLASP_MANAGED_JOB_ID=") && item.len() > b"CLASP_MANAGED_JOB_ID=".len() {
            has_id = true;
        } else if item.starts_with(b"CLASP_MANAGED_JOB_ROOT=")
            && item.len() > b"CLASP_MANAGED_JOB_ROOT=".len()
        {
            has_root = true;
        } else if item.starts_with(b"CLASP_MANAGED_JOB_TOKEN=")
            && item.len() > b"CLASP_MANAGED_JOB_TOKEN=".len()
        {
            has_token = true;
        }
    }

    has_id && has_root && has_token
}

#[cfg(target_os = "linux")]
fn runtime_host_process_count_by_name(names: &[String], exclude_managed: bool) -> Result<i64, String> {
    let wanted: Vec<&str> = names
        .iter()
        .map(|name| name.trim())
        .filter(|name| !name.is_empty())
        .collect();
    if wanted.is_empty() {
        return Ok(0);
    }

    let entries = fs::read_dir("/proc").map_err(|_| "io_error".to_owned())?;
    let mut count: i64 = 0;
    for entry in entries {
        let Ok(entry) = entry else {
            continue;
        };
        let file_name = entry.file_name();
        let Some(file_name) = file_name.to_str() else {
            continue;
        };
        if !file_name.bytes().all(|byte| byte.is_ascii_digit()) {
            continue;
        }

        let pid_path = entry.path();
        if exclude_managed && runtime_proc_has_managed_job_marker(&pid_path) {
            continue;
        }

        let Ok(comm) = fs::read_to_string(pid_path.join("comm")) else {
            continue;
        };
        let process_name = comm.trim();
        if wanted.iter().any(|wanted_name| *wanted_name == process_name) {
            count = count.saturating_add(1);
        }
    }

    Ok(count)
}

#[cfg(target_os = "linux")]
fn runtime_proc_rss_mb(pid_path: &Path) -> i64 {
    let Ok(status) = fs::read_to_string(pid_path.join("status")) else {
        return 0;
    };
    for line in status.lines() {
        let Some(rest) = line.strip_prefix("VmRSS:") else {
            continue;
        };
        let kb_text = rest.split_whitespace().next().unwrap_or("0");
        let Ok(kb) = kb_text.parse::<i64>() else {
            return 0;
        };
        return (kb + 1023) / 1024;
    }
    0
}

#[cfg(target_os = "linux")]
fn runtime_host_process_rss_mb_by_name(names: &[String], exclude_managed: bool) -> Result<i64, String> {
    let wanted: Vec<&str> = names
        .iter()
        .map(|name| name.trim())
        .filter(|name| !name.is_empty())
        .collect();
    if wanted.is_empty() {
        return Ok(0);
    }

    let entries = fs::read_dir("/proc").map_err(|_| "io_error".to_owned())?;
    let mut rss_mb: i64 = 0;
    for entry in entries {
        let Ok(entry) = entry else {
            continue;
        };
        let file_name = entry.file_name();
        let Some(file_name) = file_name.to_str() else {
            continue;
        };
        if !file_name.bytes().all(|byte| byte.is_ascii_digit()) {
            continue;
        }

        let pid_path = entry.path();
        if exclude_managed && runtime_proc_has_managed_job_marker(&pid_path) {
            continue;
        }

        let Ok(comm) = fs::read_to_string(pid_path.join("comm")) else {
            continue;
        };
        let process_name = comm.trim();
        if wanted.iter().any(|wanted_name| *wanted_name == process_name) {
            rss_mb = rss_mb.saturating_add(runtime_proc_rss_mb(&pid_path));
        }
    }

    Ok(rss_mb)
}

#[cfg(not(target_os = "linux"))]
fn runtime_host_process_count_by_name(_names: &[String], _exclude_managed: bool) -> Result<i64, String> {
    Err("unsupported_platform".to_owned())
}

#[cfg(not(target_os = "linux"))]
fn runtime_host_process_rss_mb_by_name(_names: &[String], _exclude_managed: bool) -> Result<i64, String> {
    Err("unsupported_platform".to_owned())
}

unsafe fn runtime_string_list_values(names: *mut ClaspRtStringList) -> Vec<String> {
    if names.is_null() {
        return Vec::new();
    }
    string_list_items_mut(names)
        .iter()
        .map(|name| String::from_utf8_lossy(string_bytes(*name)).into_owned())
        .collect()
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_host_available_disk_mb(path: *mut ClaspRtString) -> *mut ClaspRtHeader {
    let path_string = String::from_utf8_lossy(string_bytes(path)).into_owned();
    match runtime_host_available_disk_mb(&path_string) {
        Ok(available_mb) => runtime_result_ok(build_runtime_int(available_mb) as *mut ClaspRtHeader),
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_host_file_size_mb(path: *mut ClaspRtString) -> *mut ClaspRtHeader {
    let path_string = String::from_utf8_lossy(string_bytes(path)).into_owned();
    match host_file_size_mb(&path_string) {
        Ok(size_mb) => runtime_result_ok(build_runtime_int(size_mb) as *mut ClaspRtHeader),
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_host_cap_file_tail_mb(
    path: *mut ClaspRtString,
    max_mb: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    let Some(max_mb_value) = header_int_value(max_mb) else {
        return runtime_result_err("host_file_invalid_limit: maxMb must be an Int");
    };
    let path_string = String::from_utf8_lossy(string_bytes(path)).into_owned();
    match cap_host_file_tail_mb(&path_string, max_mb_value) {
        Ok(size_mb) => runtime_result_ok(build_runtime_int(size_mb) as *mut ClaspRtHeader),
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_host_available_memory_mb() -> *mut ClaspRtHeader {
    match runtime_host_available_memory_mb() {
        Ok(available_mb) => runtime_result_ok(build_runtime_int(available_mb) as *mut ClaspRtHeader),
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_host_process_alive(pid: *mut ClaspRtString) -> *mut ClaspRtHeader {
    let pid_string = String::from_utf8_lossy(string_bytes(pid)).into_owned();
    match runtime_host_process_alive(&pid_string) {
        Ok(alive) => runtime_result_ok(build_runtime_bool(alive) as *mut ClaspRtHeader),
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_host_process_count_by_name(
    names: *mut ClaspRtStringList,
) -> *mut ClaspRtHeader {
    let name_values = runtime_string_list_values(names);
    match runtime_host_process_count_by_name(&name_values, false) {
        Ok(count) => runtime_result_ok(build_runtime_int(count) as *mut ClaspRtHeader),
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_host_unmanaged_process_count_by_name(
    names: *mut ClaspRtStringList,
) -> *mut ClaspRtHeader {
    let name_values = runtime_string_list_values(names);
    match runtime_host_process_count_by_name(&name_values, true) {
        Ok(count) => runtime_result_ok(build_runtime_int(count) as *mut ClaspRtHeader),
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_host_unmanaged_process_rss_mb_by_name(
    names: *mut ClaspRtStringList,
) -> *mut ClaspRtHeader {
    let name_values = runtime_string_list_values(names);
    match runtime_host_process_rss_mb_by_name(&name_values, true) {
        Ok(rss_mb) => runtime_result_ok(build_runtime_int(rss_mb) as *mut ClaspRtHeader),
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_write_file(
    path: *mut ClaspRtString,
    contents: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let path_string = String::from_utf8_lossy(string_bytes(path)).into_owned();
    match write_file_atomic(&path_string, string_bytes(contents)) {
        Ok(_) => clasp_rt_result_ok_string(build_runtime_string(path_string.as_bytes())),
        Err(_) => clasp_rt_result_err_string(build_runtime_string(b"io_error")),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_append_file(
    path: *mut ClaspRtString,
    contents: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let path_string = String::from_utf8_lossy(string_bytes(path)).into_owned();
    if ensure_parent_dir(&path_string).is_err() {
        return clasp_rt_result_err_string(build_runtime_string(b"io_error"));
    }
    let mut file = match OpenOptions::new().create(true).append(true).open(&path_string) {
        Ok(file) => file,
        Err(_) => return clasp_rt_result_err_string(build_runtime_string(b"io_error")),
    };

    match file
        .write_all(string_bytes(contents))
        .and_then(|_| file.sync_all())
    {
        Ok(_) => clasp_rt_result_ok_string(build_runtime_string(path_string.as_bytes())),
        Err(_) => clasp_rt_result_err_string(build_runtime_string(b"io_error")),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_mkdir_all(path: *mut ClaspRtString) -> *mut ClaspRtResultString {
    let path_string = String::from_utf8_lossy(string_bytes(path)).into_owned();
    match fs::create_dir_all(&path_string) {
        Ok(_) => clasp_rt_result_ok_string(build_runtime_string(path_string.as_bytes())),
        Err(_) => clasp_rt_result_err_string(build_runtime_string(b"io_error")),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_env_var(name: *mut ClaspRtString) -> *mut ClaspRtResultString {
    let name_string = String::from_utf8_lossy(string_bytes(name)).into_owned();
    if name_string == "CLASP_RT_CURRENT_EXECUTABLE_PATH_JSON" {
        match env::var(&name_string) {
            Ok(value) => return clasp_rt_result_ok_string(build_runtime_string(value.as_bytes())),
            Err(env::VarError::NotUnicode(_)) => {
                return clasp_rt_result_err_string(build_runtime_string(b"invalid"))
            }
            Err(env::VarError::NotPresent) => {
                let encoded = serde_json::to_string(
                    &env::current_exe()
                        .ok()
                        .map(|path| path.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                );
                return match encoded {
                    Ok(value) => clasp_rt_result_ok_string(build_runtime_string(value.as_bytes())),
                    Err(_) => clasp_rt_result_err_string(build_runtime_string(b"missing")),
                };
            }
        }
    }
    match env::var(&name_string) {
        Ok(value) => clasp_rt_result_ok_string(build_runtime_string(value.as_bytes())),
        Err(env::VarError::NotPresent) => clasp_rt_result_err_string(build_runtime_string(b"missing")),
        Err(env::VarError::NotUnicode(_)) => clasp_rt_result_err_string(build_runtime_string(b"invalid")),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_current_working_directory() -> *mut ClaspRtResultString {
    match env::current_dir() {
        Ok(path) => {
            let path_text = path.to_string_lossy().into_owned();
            clasp_rt_result_ok_string(build_runtime_string(path_text.as_bytes()))
        }
        Err(_) => clasp_rt_result_err_string(build_runtime_string(b"io_error")),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_read_file(path: *mut ClaspRtString) -> *mut ClaspRtResultString {
    let path_string = String::from_utf8_lossy(string_bytes(path)).into_owned();
    let mut file = match File::open(&path_string) {
        Ok(file) => file,
        Err(_) => return clasp_rt_result_err_string(build_runtime_string(b"missing")),
    };

    let mut buffer = Vec::new();
    match file.read_to_end(&mut buffer) {
        Ok(_) => clasp_rt_result_ok_string(build_runtime_string(&buffer)),
        Err(_) => clasp_rt_result_err_string(build_runtime_string(b"io_error")),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_path(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    match resolve_workspace_path(&root_string, &relative_string) {
        Ok(path) => {
            let path_text = display_path(&path);
            clasp_rt_result_ok_string(build_runtime_string(path_text.as_bytes()))
        }
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_read_file(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    let path = match resolve_existing_workspace_path(&root_string, &relative_string) {
        Ok(path) => path,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    if path.is_dir() {
        let message = format!("workspace_not_file: `{}` is a directory", path.display());
        return clasp_rt_result_err_string(build_runtime_string(message.as_bytes()));
    }
    match fs::read(&path) {
        Ok(bytes) => clasp_rt_result_ok_string(build_runtime_string(&bytes)),
        Err(err) => {
            let message = format!(
                "workspace_io_error: failed to read workspace file `{}`: {err}",
                path.display()
            );
            clasp_rt_result_err_string(build_runtime_string(message.as_bytes()))
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_write_file(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
    contents: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    let path = match prepare_workspace_write_path(&root_string, &relative_string) {
        Ok(path) => path,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let path_text = display_path(&path);
    match write_file_atomic(&path_text, string_bytes(contents)) {
        Ok(_) => clasp_rt_result_ok_string(build_runtime_string(path_text.as_bytes())),
        Err(err) => {
            let message = format!(
                "workspace_io_error: failed to write workspace file `{}`: {err}",
                path.display()
            );
            clasp_rt_result_err_string(build_runtime_string(message.as_bytes()))
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_append_file(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
    contents: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    let path = match prepare_workspace_write_path(&root_string, &relative_string) {
        Ok(path) => path,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let mut file = match OpenOptions::new().create(true).append(true).open(&path) {
        Ok(file) => file,
        Err(err) => {
            let message = format!(
                "workspace_io_error: failed to open workspace file `{}` for append: {err}",
                path.display()
            );
            return clasp_rt_result_err_string(build_runtime_string(message.as_bytes()));
        }
    };

    match file
        .write_all(string_bytes(contents))
        .and_then(|_| file.sync_all())
    {
        Ok(_) => {
            let path_text = display_path(&path);
            clasp_rt_result_ok_string(build_runtime_string(path_text.as_bytes()))
        }
        Err(err) => {
            let message = format!(
                "workspace_io_error: failed to append workspace file `{}`: {err}",
                path.display()
            );
            clasp_rt_result_err_string(build_runtime_string(message.as_bytes()))
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_mkdir_all(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    match create_workspace_dir_all(&root_string, &relative_string) {
        Ok(path) => {
            let path_text = display_path(&path);
            clasp_rt_result_ok_string(build_runtime_string(path_text.as_bytes()))
        }
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_list_dir(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
) -> *mut ClaspRtHeader {
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    let path = match resolve_existing_workspace_path(&root_string, &relative_string) {
        Ok(path) => path,
        Err(message) => return runtime_result_err(&message),
    };
    let entries = match fs::read_dir(&path) {
        Ok(entries) => entries,
        Err(err) if err.kind() == std::io::ErrorKind::NotADirectory => {
            let message = format!("workspace_not_directory: `{}` is not a directory", path.display());
            return runtime_result_err(&message);
        }
        Err(err) => {
            let message = format!(
                "workspace_io_error: failed to list workspace directory `{}`: {err}",
                path.display()
            );
            return runtime_result_err(&message);
        }
    };

    let mut names = Vec::new();
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(err) => {
                let message = format!(
                    "workspace_io_error: failed to read workspace directory entry `{}`: {err}",
                    path.display()
                );
                return runtime_result_err(&message);
            }
        };
        let name = match entry.file_name().into_string() {
            Ok(name) => name,
            Err(_) => return runtime_result_err("workspace_invalid_utf8: directory entry is not valid UTF-8"),
        };
        names.push(name);
    }
    names.sort();

    let items = names
        .iter()
        .map(|name| build_runtime_string(name.as_bytes()) as *mut ClaspRtHeader)
        .collect();
    runtime_result_ok(clasp_rt_build_list_header(items))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_list_tree(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
    max_entries: *mut ClaspRtHeader,
    max_depth: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    let Some(max_entries_value) = header_int_value(max_entries) else {
        return runtime_result_err("workspace_invalid_limit: maxEntries must be an Int");
    };
    let Some(max_depth_value) = header_int_value(max_depth) else {
        return runtime_result_err("workspace_invalid_limit: maxDepth must be an Int");
    };
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    match workspace_list_tree(&root_string, &relative_string, max_entries_value, max_depth_value) {
        Ok(paths) => {
            let items = paths
                .iter()
                .map(|path| build_runtime_string(path.as_bytes()) as *mut ClaspRtHeader)
                .collect();
            runtime_result_ok(clasp_rt_build_list_header(items))
        }
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_search_text(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
    needle: *mut ClaspRtString,
    max_matches: *mut ClaspRtHeader,
    max_files: *mut ClaspRtHeader,
    max_file_bytes: *mut ClaspRtHeader,
    max_depth: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    let Some(max_matches_value) = header_int_value(max_matches) else {
        return runtime_result_err("workspace_invalid_limit: maxMatches must be an Int");
    };
    let Some(max_files_value) = header_int_value(max_files) else {
        return runtime_result_err("workspace_invalid_limit: maxFiles must be an Int");
    };
    let Some(max_file_bytes_value) = header_int_value(max_file_bytes) else {
        return runtime_result_err("workspace_invalid_limit: maxFileBytes must be an Int");
    };
    let Some(max_depth_value) = header_int_value(max_depth) else {
        return runtime_result_err("workspace_invalid_limit: maxDepth must be an Int");
    };
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    let needle_string = String::from_utf8_lossy(string_bytes(needle)).into_owned();
    match workspace_search_text(
        &root_string,
        &relative_string,
        &needle_string,
        max_matches_value,
        max_files_value,
        max_file_bytes_value,
        max_depth_value,
    ) {
        Ok(paths) => {
            let items = paths
                .iter()
                .map(|path| build_runtime_string(path.as_bytes()) as *mut ClaspRtHeader)
                .collect();
            runtime_result_ok(clasp_rt_build_list_header(items))
        }
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_replace_text(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
    find_text: *mut ClaspRtString,
    replace_text: *mut ClaspRtString,
    max_replacements: *mut ClaspRtHeader,
    max_file_bytes: *mut ClaspRtHeader,
) -> *mut ClaspRtHeader {
    let Some(max_replacements_value) = header_int_value(max_replacements) else {
        return runtime_result_err("workspace_invalid_limit: maxReplacements must be an Int");
    };
    let Some(max_file_bytes_value) = header_int_value(max_file_bytes) else {
        return runtime_result_err("workspace_invalid_limit: maxFileBytes must be an Int");
    };
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    let find_string = String::from_utf8_lossy(string_bytes(find_text)).into_owned();
    let replace_string = String::from_utf8_lossy(string_bytes(replace_text)).into_owned();
    match workspace_replace_text(
        &root_string,
        &relative_string,
        &find_string,
        &replace_string,
        max_replacements_value,
        max_file_bytes_value,
    ) {
        Ok(count) => runtime_result_ok(build_runtime_int(count) as *mut ClaspRtHeader),
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_path_size_mb(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
) -> *mut ClaspRtHeader {
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    match workspace_path_size_mb(&root_string, &relative_string) {
        Ok(size_mb) => runtime_result_ok(build_runtime_int(size_mb) as *mut ClaspRtHeader),
        Err(message) => runtime_result_err(&message),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_workspace_remove_path(
    root: *mut ClaspRtString,
    relative: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let relative_string = String::from_utf8_lossy(string_bytes(relative)).into_owned();
    let path = match resolve_existing_workspace_removal_path(&root_string, &relative_string) {
        Ok(path) => path,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(err) => {
            let message = format!(
                "workspace_io_error: failed to inspect workspace path `{}`: {err}",
                path.display()
            );
            return clasp_rt_result_err_string(build_runtime_string(message.as_bytes()));
        }
    };
    let removed = if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(&path)
    } else {
        fs::remove_file(&path)
    };
    match removed {
        Ok(_) => {
            let path_text = display_path(&path);
            clasp_rt_result_ok_string(build_runtime_string(path_text.as_bytes()))
        }
        Err(err) => {
            let message = format!(
                "workspace_io_error: failed to remove workspace path `{}`: {err}",
                path.display()
            );
            clasp_rt_result_err_string(build_runtime_string(message.as_bytes()))
        }
    }
}

unsafe fn clasp_rt_result_string_from_owned(value: Result<String, String>) -> *mut ClaspRtResultString {
    match value {
        Ok(text) => clasp_rt_result_ok_string(build_runtime_string(text.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

unsafe fn clasp_rt_string_arg(value: *mut ClaspRtHeader) -> Result<String, String> {
    if value.is_null() || (*value).layout_id != CLASP_RT_LAYOUT_STRING {
        return Err("invalid_string".to_owned());
    }
    Ok(String::from_utf8_lossy(string_bytes(value as *mut ClaspRtString)).into_owned())
}

unsafe fn clasp_rt_int_arg(value: *mut ClaspRtHeader) -> Result<i64, String> {
    header_int_value(value).ok_or_else(|| "invalid_int".to_owned())
}

unsafe fn clasp_rt_string_list_arg(value: *mut ClaspRtHeader) -> Result<Vec<String>, String> {
    let Some(items) = list_like_string_items(value) else {
        return Err("invalid_string_list".to_owned());
    };
    Ok(items
        .iter()
        .map(|item| String::from_utf8_lossy(string_bytes(*item)).into_owned())
        .collect())
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_bootstrap_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_bootstrap(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_start_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_start(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_lease_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_lease(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_release_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_release(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_heartbeat_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_heartbeat(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_complete_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_complete(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_fail_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_fail(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_retry_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_retry(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_stop_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_stop(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_resume_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_resume(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_status_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_status(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_history_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_history(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_tasks_json(root: *mut ClaspRtString) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_tasks(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_summary_json(root: *mut ClaspRtString) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_summary(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_tail_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    limit: i64,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_tail(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        limit,
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_ready_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_ready(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_manager_next_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_manager_next(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_objective_create_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
    detail: *mut ClaspRtString,
    max_tasks: *mut ClaspRtHeader,
    max_runs: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let max_tasks_value = match clasp_rt_int_arg(max_tasks) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_runs_value = match clasp_rt_int_arg(max_runs) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_objective_create(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(detail)).into_owned(),
        max_tasks_value,
        max_runs_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_objective_create_with_deadline_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
    detail: *mut ClaspRtString,
    max_tasks: *mut ClaspRtHeader,
    max_runs: *mut ClaspRtHeader,
    deadline_at_ms: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let max_tasks_value = match clasp_rt_int_arg(max_tasks) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_runs_value = match clasp_rt_int_arg(max_runs) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let deadline_value = match clasp_rt_int_arg(deadline_at_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_objective_create_with_deadline(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(detail)).into_owned(),
        max_tasks_value,
        max_runs_value,
        deadline_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_objective_status_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_objective_status(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_objectives_json(root: *mut ClaspRtString) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_objectives(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_task_create_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    detail: *mut ClaspRtString,
    dependencies: *mut ClaspRtHeader,
    max_runs: *mut ClaspRtHeader,
    lease_timeout_ms: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let dependencies_value = match clasp_rt_string_list_arg(dependencies) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_runs_value = match clasp_rt_int_arg(max_runs) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let lease_timeout_value = match clasp_rt_int_arg(lease_timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_task_create(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(detail)).into_owned(),
        &dependencies_value,
        max_runs_value,
        lease_timeout_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_task_create_with_deadline_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    detail: *mut ClaspRtString,
    dependencies: *mut ClaspRtHeader,
    max_runs: *mut ClaspRtHeader,
    deadline_at_ms: *mut ClaspRtHeader,
    lease_timeout_ms: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let dependencies_value = match clasp_rt_string_list_arg(dependencies) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_runs_value = match clasp_rt_int_arg(max_runs) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let deadline_value = match clasp_rt_int_arg(deadline_at_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let lease_timeout_value = match clasp_rt_int_arg(lease_timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_task_create_with_deadline(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(detail)).into_owned(),
        &dependencies_value,
        max_runs_value,
        deadline_value,
        lease_timeout_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_task_create_with_deadline_and_priority_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    detail: *mut ClaspRtString,
    dependencies: *mut ClaspRtHeader,
    max_runs: *mut ClaspRtHeader,
    deadline_at_ms: *mut ClaspRtHeader,
    priority: *mut ClaspRtHeader,
    lease_timeout_ms: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let dependencies_value = match clasp_rt_string_list_arg(dependencies) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_runs_value = match clasp_rt_int_arg(max_runs) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let deadline_value = match clasp_rt_int_arg(deadline_at_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let priority_value = match clasp_rt_int_arg(priority) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let lease_timeout_value = match clasp_rt_int_arg(lease_timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_task_create_with_deadline_and_priority(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(detail)).into_owned(),
        &dependencies_value,
        max_runs_value,
        deadline_value,
        priority_value,
        lease_timeout_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_task_create_child_with_deadline_and_priority_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
    parent_task_id: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    detail: *mut ClaspRtString,
    dependencies: *mut ClaspRtHeader,
    max_runs: *mut ClaspRtHeader,
    deadline_at_ms: *mut ClaspRtHeader,
    priority: *mut ClaspRtHeader,
    max_spawn_depth: *mut ClaspRtHeader,
    lease_timeout_ms: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let dependencies_value = match clasp_rt_string_list_arg(dependencies) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_runs_value = match clasp_rt_int_arg(max_runs) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let deadline_value = match clasp_rt_int_arg(deadline_at_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let priority_value = match clasp_rt_int_arg(priority) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_spawn_depth_value = match clasp_rt_int_arg(max_spawn_depth) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let lease_timeout_value = match clasp_rt_int_arg(lease_timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_task_create_child_with_deadline_and_priority(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(parent_task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(detail)).into_owned(),
        &dependencies_value,
        max_runs_value,
        deadline_value,
        priority_value,
        max_spawn_depth_value,
        lease_timeout_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_task_create_child_with_policy_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
    parent_task_id: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    detail: *mut ClaspRtString,
    dependencies: *mut ClaspRtHeader,
    max_runs: *mut ClaspRtHeader,
    deadline_at_ms: *mut ClaspRtHeader,
    priority: *mut ClaspRtHeader,
    max_spawn_depth: *mut ClaspRtHeader,
    max_child_tasks: *mut ClaspRtHeader,
    lease_timeout_ms: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let dependencies_value = match clasp_rt_string_list_arg(dependencies) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_runs_value = match clasp_rt_int_arg(max_runs) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let deadline_value = match clasp_rt_int_arg(deadline_at_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let priority_value = match clasp_rt_int_arg(priority) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_spawn_depth_value = match clasp_rt_int_arg(max_spawn_depth) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_child_tasks_value = match clasp_rt_int_arg(max_child_tasks) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let lease_timeout_value = match clasp_rt_int_arg(lease_timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_task_create_child_with_policy(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(parent_task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(detail)).into_owned(),
        &dependencies_value,
        max_runs_value,
        deadline_value,
        priority_value,
        max_spawn_depth_value,
        max_child_tasks_value,
        lease_timeout_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_task_reprioritize_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    priority: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let priority_value = match clasp_rt_int_arg(priority) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_task_reprioritize(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        priority_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_policy_set_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    mergegate_name: *mut ClaspRtString,
    required_approvals: *mut ClaspRtHeader,
    required_verifiers: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let approvals = match clasp_rt_string_list_arg(required_approvals) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let verifiers = match clasp_rt_string_list_arg(required_verifiers) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_policy_set(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(mergegate_name)).into_owned(),
        &approvals,
        &verifiers,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_policy_set_with_process_access_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    mergegate_name: *mut ClaspRtString,
    required_approvals: *mut ClaspRtHeader,
    required_verifiers: *mut ClaspRtHeader,
    allowed_processes: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let approvals = match clasp_rt_string_list_arg(required_approvals) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let verifiers = match clasp_rt_string_list_arg(required_verifiers) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let processes = match clasp_rt_string_list_arg(allowed_processes) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_policy_set_with_process_access(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(mergegate_name)).into_owned(),
        &approvals,
        &verifiers,
        &processes,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_policy_set_with_access_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    mergegate_name: *mut ClaspRtString,
    required_approvals: *mut ClaspRtHeader,
    required_verifiers: *mut ClaspRtHeader,
    allowed_processes: *mut ClaspRtHeader,
    allowed_workspace_roots: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let approvals = match clasp_rt_string_list_arg(required_approvals) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let verifiers = match clasp_rt_string_list_arg(required_verifiers) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let processes = match clasp_rt_string_list_arg(allowed_processes) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let workspaces = match clasp_rt_string_list_arg(allowed_workspace_roots) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_policy_set_with_access(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(mergegate_name)).into_owned(),
        &approvals,
        &verifiers,
        &processes,
        &workspaces,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_policy_set_with_capabilities_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    mergegate_name: *mut ClaspRtString,
    required_approvals: *mut ClaspRtHeader,
    required_verifiers: *mut ClaspRtHeader,
    allowed_processes: *mut ClaspRtHeader,
    allowed_workspace_roots: *mut ClaspRtHeader,
    network_access: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let approvals = match clasp_rt_string_list_arg(required_approvals) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let verifiers = match clasp_rt_string_list_arg(required_verifiers) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let processes = match clasp_rt_string_list_arg(allowed_processes) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let workspaces = match clasp_rt_string_list_arg(allowed_workspace_roots) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_policy_set_with_capabilities(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(mergegate_name)).into_owned(),
        &approvals,
        &verifiers,
        &processes,
        &workspaces,
        &String::from_utf8_lossy(string_bytes(network_access)).into_owned(),
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_policy_set_with_network_access_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    mergegate_name: *mut ClaspRtString,
    required_approvals: *mut ClaspRtHeader,
    required_verifiers: *mut ClaspRtHeader,
    allowed_processes: *mut ClaspRtHeader,
    allowed_workspace_roots: *mut ClaspRtHeader,
    network_access: *mut ClaspRtString,
    allowed_network_destinations: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let approvals = match clasp_rt_string_list_arg(required_approvals) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let verifiers = match clasp_rt_string_list_arg(required_verifiers) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let processes = match clasp_rt_string_list_arg(allowed_processes) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let workspaces = match clasp_rt_string_list_arg(allowed_workspace_roots) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let destinations = match clasp_rt_string_list_arg(allowed_network_destinations) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_policy_set_with_network_access(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(mergegate_name)).into_owned(),
        &approvals,
        &verifiers,
        &processes,
        &workspaces,
        &String::from_utf8_lossy(string_bytes(network_access)).into_owned(),
        &destinations,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_policy_set_with_filesystem_access_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    mergegate_name: *mut ClaspRtString,
    required_approvals: *mut ClaspRtHeader,
    required_verifiers: *mut ClaspRtHeader,
    allowed_processes: *mut ClaspRtHeader,
    allowed_workspace_roots: *mut ClaspRtHeader,
    allowed_readonly_roots: *mut ClaspRtHeader,
    network_access: *mut ClaspRtString,
    allowed_network_destinations: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let approvals = match clasp_rt_string_list_arg(required_approvals) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let verifiers = match clasp_rt_string_list_arg(required_verifiers) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let processes = match clasp_rt_string_list_arg(allowed_processes) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let workspaces = match clasp_rt_string_list_arg(allowed_workspace_roots) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let readonly_roots = match clasp_rt_string_list_arg(allowed_readonly_roots) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let destinations = match clasp_rt_string_list_arg(allowed_network_destinations) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_policy_set_with_filesystem_access(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(mergegate_name)).into_owned(),
        &approvals,
        &verifiers,
        &processes,
        &workspaces,
        &readonly_roots,
        &String::from_utf8_lossy(string_bytes(network_access)).into_owned(),
        &destinations,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_tool_run_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    cwd: *mut ClaspRtString,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let command_value = match clasp_rt_string_list_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_tool_run(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        &String::from_utf8_lossy(string_bytes(cwd)).into_owned(),
        &command_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_tool_run_with_timeout_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    cwd: *mut ClaspRtString,
    timeout_ms: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let timeout_value = match clasp_rt_int_arg(timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let command_value = match clasp_rt_string_list_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_tool_run_with_timeout(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        &String::from_utf8_lossy(string_bytes(cwd)).into_owned(),
        timeout_value,
        &command_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_tool_run_with_limits_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    cwd: *mut ClaspRtString,
    timeout_ms: *mut ClaspRtHeader,
    memory_limit_mb: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let timeout_value = match clasp_rt_int_arg(timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let memory_limit_value = match clasp_rt_int_arg(memory_limit_mb) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let command_value = match clasp_rt_string_list_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_tool_run_with_limits(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        &String::from_utf8_lossy(string_bytes(cwd)).into_owned(),
        timeout_value,
        memory_limit_value,
        &command_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_verifier_run_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    verifier_name: *mut ClaspRtString,
    cwd: *mut ClaspRtString,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let command_value = match clasp_rt_string_list_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_verifier_run(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        &String::from_utf8_lossy(string_bytes(verifier_name)).into_owned(),
        &String::from_utf8_lossy(string_bytes(cwd)).into_owned(),
        &command_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_verifier_run_with_timeout_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    verifier_name: *mut ClaspRtString,
    cwd: *mut ClaspRtString,
    timeout_ms: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let timeout_value = match clasp_rt_int_arg(timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let command_value = match clasp_rt_string_list_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_verifier_run_with_timeout(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        &String::from_utf8_lossy(string_bytes(verifier_name)).into_owned(),
        &String::from_utf8_lossy(string_bytes(cwd)).into_owned(),
        timeout_value,
        &command_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_verifier_run_with_limits_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    verifier_name: *mut ClaspRtString,
    cwd: *mut ClaspRtString,
    timeout_ms: *mut ClaspRtHeader,
    memory_limit_mb: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let timeout_value = match clasp_rt_int_arg(timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let memory_limit_value = match clasp_rt_int_arg(memory_limit_mb) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let command_value = match clasp_rt_string_list_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_verifier_run_with_limits(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        &String::from_utf8_lossy(string_bytes(verifier_name)).into_owned(),
        &String::from_utf8_lossy(string_bytes(cwd)).into_owned(),
        timeout_value,
        memory_limit_value,
        &command_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_approve_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    approval_name: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_approve(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        &String::from_utf8_lossy(string_bytes(approval_name)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_approvals_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_approvals(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
    ))
}

pub unsafe extern "C" fn clasp_rt_swarm_mergegate_decide_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    mergegate_name: *mut ClaspRtString,
    verifier_names: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let verifiers = match clasp_rt_string_list_arg(verifier_names) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_mergegate_decide(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        &String::from_utf8_lossy(string_bytes(mergegate_name)).into_owned(),
        &verifiers,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_runs_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_runs(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_artifacts_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_artifacts(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_artifact_read_json(
    root: *mut ClaspRtString,
    artifact_id: *mut ClaspRtHeader,
    max_bytes: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let artifact_id_value = match clasp_rt_int_arg(artifact_id) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_bytes_value = match clasp_rt_int_arg(max_bytes) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_artifact_read(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        artifact_id_value,
        max_bytes_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_artifact_search_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    kind: *mut ClaspRtString,
    query: *mut ClaspRtString,
    limit: *mut ClaspRtHeader,
    max_bytes: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let limit_value = match clasp_rt_int_arg(limit) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let max_bytes_value = match clasp_rt_int_arg(max_bytes) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_artifact_search(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(kind)).into_owned(),
        &String::from_utf8_lossy(string_bytes(query)).into_owned(),
        limit_value,
        max_bytes_value,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_artifact_write_json(
    root: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    kind: *mut ClaspRtString,
    text: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_artifact_write(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        &String::from_utf8_lossy(string_bytes(kind)).into_owned(),
        &String::from_utf8_lossy(string_bytes(text)).into_owned(),
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_memory_put_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    actor: *mut ClaspRtString,
    key: *mut ClaspRtString,
    value: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_memory_put(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(actor)).into_owned(),
        &String::from_utf8_lossy(string_bytes(key)).into_owned(),
        &String::from_utf8_lossy(string_bytes(value)).into_owned(),
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_memory_query_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    key: *mut ClaspRtString,
    limit: i64,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_memory_query(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(key)).into_owned(),
        limit,
    ))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_swarm_memory_search_json(
    root: *mut ClaspRtString,
    objective_id: *mut ClaspRtString,
    task_id: *mut ClaspRtString,
    query: *mut ClaspRtString,
    limit: i64,
) -> *mut ClaspRtResultString {
    clasp_rt_result_string_from_owned(swarm::builtin_swarm_memory_search(
        &String::from_utf8_lossy(string_bytes(root)).into_owned(),
        &String::from_utf8_lossy(string_bytes(objective_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(task_id)).into_owned(),
        &String::from_utf8_lossy(string_bytes(query)).into_owned(),
        limit,
    ))
}

fn append_run_command_payload_fields(
    payload: &mut Vec<u8>,
    exit_code: i32,
    stdout: &[u8],
    stderr: &[u8],
) {
    payload.extend_from_slice(b"\"exitCode\":");
    payload.extend_from_slice(exit_code.to_string().as_bytes());
    payload.extend_from_slice(b",\"stdout\":");
    append_json_string_literal(payload, stdout);
    payload.extend_from_slice(b",\"stderr\":");
    append_json_string_literal(payload, stderr);
}

fn render_run_command_payload(exit_code: i32, stdout: &[u8], stderr: &[u8]) -> Vec<u8> {
    let mut payload = Vec::new();
    payload.push(b'{');
    append_run_command_payload_fields(&mut payload, exit_code, stdout, stderr);
    payload.push(b'}');
    payload
}

fn render_run_command_timeout_payload(
    exit_code: i32,
    stdout: &[u8],
    stderr: &[u8],
    timed_out: bool,
    error: &str,
) -> Vec<u8> {
    let mut payload = Vec::new();
    payload.push(b'{');
    append_run_command_payload_fields(&mut payload, exit_code, stdout, stderr);
    payload.extend_from_slice(b",\"timedOut\":");
    if timed_out {
        payload.extend_from_slice(b"true");
    } else {
        payload.extend_from_slice(b"false");
    }
    payload.extend_from_slice(b",\"error\":");
    append_json_string_literal(&mut payload, error.as_bytes());
    payload.push(b'}');
    payload
}

unsafe fn clasp_rt_process_argv_arg(command: *mut ClaspRtHeader) -> Result<Vec<String>, String> {
    let command_values = clasp_rt_string_list_arg(command).map_err(|_| "invalid_command".to_owned())?;
    if command_values.is_empty() {
        return Err("missing_command".to_owned());
    }
    if command_values.iter().any(|value| value.contains('\0')) {
        return Err("invalid_command: command arguments must not contain NUL bytes".to_owned());
    }
    Ok(command_values)
}

fn process_program_basename(program: &str) -> &str {
    Path::new(program)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(program)
}

fn process_program_is_shell(program: &str) -> bool {
    matches!(
        process_program_basename(program),
        "sh" | "bash" | "dash" | "zsh" | "fish" | "ksh"
    )
}

fn process_arg_is_shell_string_flag(arg: &str) -> bool {
    arg == "-c" || (arg.starts_with('-') && !arg.starts_with("--") && arg.contains('c'))
}

fn validate_workspace_process_command(command_values: &[String]) -> Result<(), String> {
    if command_values.is_empty() {
        return Err("missing_command".to_owned());
    }
    if command_values[0].starts_with('@') {
        return Err(
            "process_reserved_command: workspace subprocess commands must name an executable, not an internal runtime command"
                .to_owned(),
        );
    }
    if process_program_is_shell(&command_values[0])
        && command_values[1..]
            .iter()
            .any(|arg| process_arg_is_shell_string_flag(arg))
    {
        return Err(
            "process_shell_string_rejected: pass the executable and arguments directly; shell -c is not allowed"
                .to_owned(),
        );
    }
    Ok(())
}

fn parse_process_env_assignment(assignment: &str) -> Result<(String, String), String> {
    let Some((name, value)) = assignment.split_once('=') else {
        return Err("invalid_env".to_owned());
    };
    if name.is_empty() || name.contains('\0') || value.contains('\0') {
        return Err("invalid_env".to_owned());
    }
    Ok((name.to_owned(), value.to_owned()))
}

unsafe fn clasp_rt_process_env_arg(env_values: *mut ClaspRtHeader) -> Result<Vec<(String, String)>, String> {
    let raw_values = clasp_rt_string_list_arg(env_values).map_err(|_| "invalid_env".to_owned())?;
    raw_values
        .iter()
        .map(|value| parse_process_env_assignment(value))
        .collect()
}

fn apply_process_env(command: &mut ProcessCommand, env_values: &[(String, String)]) {
    command.env_clear();
    for (name, value) in env_values {
        command.env(name, value);
    }
}

fn run_process_command_output(
    cwd: &str,
    env_values: &[(String, String)],
    command_values: &[String],
) -> std::io::Result<std::process::Output> {
    let mut command = ProcessCommand::new(&command_values[0]);
    command.args(&command_values[1..]).current_dir(cwd);
    apply_process_env(&mut command, env_values);
    configure_no_core_dump_process_command(&mut command);
    command.output()
}

fn spawn_process_command(
    cwd: &str,
    env_values: &[(String, String)],
    command_values: &[String],
) -> std::io::Result<std::process::Child> {
    let mut command = ProcessCommand::new(&command_values[0]);
    command
        .args(&command_values[1..])
        .current_dir(cwd)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    apply_process_env(&mut command, env_values);
    configure_killable_process_command(&mut command);
    command.spawn()
}

fn run_workspace_process_command_output(
    cwd: &Path,
    command_values: &[String],
) -> std::io::Result<std::process::Output> {
    let mut command = ProcessCommand::new(&command_values[0]);
    command.args(&command_values[1..]).current_dir(cwd);
    configure_no_core_dump_process_command(&mut command);
    command.output()
}

fn spawn_workspace_process_command(
    cwd: &Path,
    command_values: &[String],
) -> std::io::Result<std::process::Child> {
    let mut command = ProcessCommand::new(&command_values[0]);
    command
        .args(&command_values[1..])
        .current_dir(cwd)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    configure_killable_process_command(&mut command);
    command.spawn()
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_run_command_json(
    cwd: *mut ClaspRtString,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let command_values = match clasp_rt_process_argv_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };

    let render_payload = |exit_code: i32, stdout: &[u8], stderr: &[u8]| {
        let payload = render_run_command_payload(exit_code, stdout, stderr);
        clasp_rt_result_ok_string(build_runtime_string(&payload))
    };

    if command_values[0] == "@swarm" {
        let (exit_code, stdout) = match swarm::run_swarm_json_command(&command_values[1..]) {
            Ok(value) => value,
            Err(message) => (2, json_error_message(&message)),
        };
        return render_payload(exit_code, stdout.as_bytes(), b"");
    }

    if command_values[0] == "@proc" {
        let (exit_code, stdout, stderr) = if command_values.len() < 2 {
            (2, String::new(), "missing_proc_command".to_owned())
        } else {
            match command_values[1].as_str() {
                "watch" => match run_watched_process_json(&cwd_string, &command_values[2..]) {
                    Ok((exit_code, stdout)) => (exit_code, stdout, String::new()),
                    Err(message) => (2, String::new(), message),
                },
                _ => (2, String::new(), "invalid_proc_command".to_owned()),
            }
        };
        return render_payload(exit_code, stdout.as_bytes(), stderr.as_bytes());
    }

    let mut process_command = ProcessCommand::new(&command_values[0]);
    process_command
        .args(&command_values[1..])
        .current_dir(&cwd_string);
    configure_no_core_dump_process_command(&mut process_command);
    let output = match process_command.output() {
        Ok(output) => output,
        Err(err) => {
            return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
        }
    };
    render_payload(output.status.code().unwrap_or(-1), &output.stdout, &output.stderr)
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_run_command_timeout_json(
    cwd: *mut ClaspRtString,
    timeout_ms: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let timeout_ms_value = match clasp_rt_int_arg(timeout_ms) {
        Ok(value) => value.max(0) as u64,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let command_values = match clasp_rt_process_argv_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };

    let render_payload = |exit_code: i32, stdout: &[u8], stderr: &[u8], timed_out: bool, error: &str| {
        let payload = render_run_command_timeout_payload(exit_code, stdout, stderr, timed_out, error);
        clasp_rt_result_ok_string(build_runtime_string(&payload))
    };

    if command_values[0] == "@swarm" {
        let (exit_code, stdout) = match swarm::run_swarm_json_command(&command_values[1..]) {
            Ok(value) => value,
            Err(message) => (2, json_error_message(&message)),
        };
        return render_payload(exit_code, stdout.as_bytes(), b"", false, "");
    }

    if command_values[0] == "@proc" {
        let (exit_code, stdout, stderr) = if command_values.len() < 2 {
            (2, String::new(), "missing_proc_command".to_owned())
        } else {
            match command_values[1].as_str() {
                "watch" => match run_watched_process_json(&cwd_string, &command_values[2..]) {
                    Ok((exit_code, stdout)) => (exit_code, stdout, String::new()),
                    Err(message) => (2, String::new(), message),
                },
                _ => (2, String::new(), "invalid_proc_command".to_owned()),
            }
        };
        return render_payload(exit_code, stdout.as_bytes(), stderr.as_bytes(), false, "");
    }

    if timeout_ms_value == 0 {
        let mut process_command = ProcessCommand::new(&command_values[0]);
        process_command
            .args(&command_values[1..])
            .current_dir(&cwd_string);
        configure_no_core_dump_process_command(&mut process_command);
        let output = match process_command.output() {
            Ok(output) => output,
            Err(err) => {
                return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
            }
        };
        return render_payload(
            output.status.code().unwrap_or(-1),
            &output.stdout,
            &output.stderr,
            false,
            "",
        );
    }

    let mut command = ProcessCommand::new(&command_values[0]);
    command
        .args(&command_values[1..])
        .current_dir(&cwd_string)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    configure_killable_process_command(&mut command);

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(err) => {
            return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
        }
    };
    let child_id = child.id();

    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => match child.wait_with_output() {
                Ok(output) => {
                    return render_payload(
                        output.status.code().unwrap_or(-1),
                        &output.stdout,
                        &output.stderr,
                        false,
                        "",
                    );
                }
                Err(err) => {
                    return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
                }
            },
            Ok(None) => {
                if started.elapsed() >= Duration::from_millis(timeout_ms_value) {
                    terminate_child_tree(&mut child, child_id);
                    match child.wait_with_output() {
                        Ok(output) => {
                            return render_payload(124, &output.stdout, &output.stderr, true, "timeout");
                        }
                        Err(err) => {
                            return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
                        }
                    }
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(err) => {
                return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_run_workspace_command_timeout_json(
    root: *mut ClaspRtString,
    cwd: *mut ClaspRtString,
    timeout_ms: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let root_string = String::from_utf8_lossy(string_bytes(root)).into_owned();
    let cwd_relative_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let timeout_ms_value = match clasp_rt_int_arg(timeout_ms) {
        Ok(value) => value.max(0) as u64,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let command_values = match clasp_rt_process_argv_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    if let Err(message) = validate_workspace_process_command(&command_values) {
        return clasp_rt_result_err_string(build_runtime_string(message.as_bytes()));
    }
    let cwd_path = match resolve_workspace_process_cwd(&root_string, &cwd_relative_string) {
        Ok(path) => path,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };

    let render_payload = |exit_code: i32, stdout: &[u8], stderr: &[u8], timed_out: bool, error: &str| {
        let payload = render_run_command_timeout_payload(exit_code, stdout, stderr, timed_out, error);
        clasp_rt_result_ok_string(build_runtime_string(&payload))
    };

    if timeout_ms_value == 0 {
        let output = match run_workspace_process_command_output(&cwd_path, &command_values) {
            Ok(output) => output,
            Err(err) => {
                return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
            }
        };
        return render_payload(
            output.status.code().unwrap_or(-1),
            &output.stdout,
            &output.stderr,
            false,
            "",
        );
    }

    let mut child = match spawn_workspace_process_command(&cwd_path, &command_values) {
        Ok(child) => child,
        Err(err) => {
            return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
        }
    };
    let child_id = child.id();

    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => match child.wait_with_output() {
                Ok(output) => {
                    return render_payload(
                        output.status.code().unwrap_or(-1),
                        &output.stdout,
                        &output.stderr,
                        false,
                        "",
                    );
                }
                Err(err) => {
                    return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
                }
            },
            Ok(None) => {
                if started.elapsed() >= Duration::from_millis(timeout_ms_value) {
                    terminate_child_tree(&mut child, child_id);
                    match child.wait_with_output() {
                        Ok(output) => {
                            return render_payload(124, &output.stdout, &output.stderr, true, "timeout");
                        }
                        Err(err) => {
                            return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
                        }
                    }
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(err) => {
                return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_run_process_json(
    cwd: *mut ClaspRtString,
    env_values: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let env_value = match clasp_rt_process_env_arg(env_values) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let command_values = match clasp_rt_process_argv_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let output = match run_process_command_output(&cwd_string, &env_value, &command_values) {
        Ok(output) => output,
        Err(err) => {
            return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
        }
    };
    let payload = render_run_command_payload(
        output.status.code().unwrap_or(-1),
        &output.stdout,
        &output.stderr,
    );
    clasp_rt_result_ok_string(build_runtime_string(&payload))
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_run_process_timeout_json(
    cwd: *mut ClaspRtString,
    timeout_ms: *mut ClaspRtHeader,
    env_values: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let timeout_ms_value = match clasp_rt_int_arg(timeout_ms) {
        Ok(value) => value.max(0) as u64,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let env_value = match clasp_rt_process_env_arg(env_values) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let command_values = match clasp_rt_process_argv_arg(command) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };

    if timeout_ms_value == 0 {
        let output = match run_process_command_output(&cwd_string, &env_value, &command_values) {
            Ok(output) => output,
            Err(err) => {
                return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
            }
        };
        let payload = render_run_command_timeout_payload(
            output.status.code().unwrap_or(-1),
            &output.stdout,
            &output.stderr,
            false,
            "",
        );
        return clasp_rt_result_ok_string(build_runtime_string(&payload));
    }

    let mut child = match spawn_process_command(&cwd_string, &env_value, &command_values) {
        Ok(child) => child,
        Err(err) => {
            return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
        }
    };
    let child_id = child.id();

    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => match child.wait_with_output() {
                Ok(output) => {
                    let payload = render_run_command_timeout_payload(
                        output.status.code().unwrap_or(-1),
                        &output.stdout,
                        &output.stderr,
                        false,
                        "",
                    );
                    return clasp_rt_result_ok_string(build_runtime_string(&payload));
                }
                Err(err) => {
                    return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
                }
            },
            Ok(None) => {
                if started.elapsed() >= Duration::from_millis(timeout_ms_value) {
                    terminate_child_tree(&mut child, child_id);
                    match child.wait_with_output() {
                        Ok(output) => {
                            let payload = render_run_command_timeout_payload(
                                124,
                                &output.stdout,
                                &output.stderr,
                                true,
                                "timeout",
                            );
                            return clasp_rt_result_ok_string(build_runtime_string(&payload));
                        }
                        Err(err) => {
                            return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
                        }
                    }
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(err) => {
                return clasp_rt_result_err_string(build_runtime_string(err.to_string().as_bytes()));
            }
        }
    }
}

pub unsafe extern "C" fn clasp_rt_watch_command_json(
    cwd: *mut ClaspRtString,
    stdout_path: *mut ClaspRtString,
    stderr_path: *mut ClaspRtString,
    heartbeat_path: *mut ClaspRtString,
    poll_ms: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let stdout_path_string = String::from_utf8_lossy(string_bytes(stdout_path)).into_owned();
    let stderr_path_string = String::from_utf8_lossy(string_bytes(stderr_path)).into_owned();
    let heartbeat_path_string = String::from_utf8_lossy(string_bytes(heartbeat_path)).into_owned();
    let Some(command_items) = list_like_string_items(command) else {
        return clasp_rt_result_err_string(build_runtime_string(b"invalid_command"));
    };
    let command_values: Vec<String> = command_items
        .iter()
        .map(|value| String::from_utf8_lossy(string_bytes(*value)).into_owned())
        .collect();
    let poll_ms_value = match clasp_rt_int_arg(poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let mut args = vec![
        stdout_path_string,
        stderr_path_string,
        heartbeat_path_string,
        poll_ms_value.to_string(),
    ];
    args.extend(command_values);
    match run_watched_process_json(&cwd_string, &args) {
        Ok((_exit_code, payload)) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

pub unsafe extern "C" fn clasp_rt_spawn_command_json(
    cwd: *mut ClaspRtString,
    stdout_path: *mut ClaspRtString,
    stderr_path: *mut ClaspRtString,
    heartbeat_path: *mut ClaspRtString,
    poll_ms: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let stdout_path_string = String::from_utf8_lossy(string_bytes(stdout_path)).into_owned();
    let stderr_path_string = String::from_utf8_lossy(string_bytes(stderr_path)).into_owned();
    let heartbeat_path_string = String::from_utf8_lossy(string_bytes(heartbeat_path)).into_owned();
    let Some(command_items) = list_like_string_items(command) else {
        return clasp_rt_result_err_string(build_runtime_string(b"invalid_command"));
    };
    let command_values: Vec<String> = command_items
        .iter()
        .map(|value| String::from_utf8_lossy(string_bytes(*value)).into_owned())
        .collect();
    let poll_ms_value = match clasp_rt_int_arg(poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let mut args = vec![
        stdout_path_string,
        stderr_path_string,
        heartbeat_path_string,
        poll_ms_value.to_string(),
    ];
    args.extend(command_values);
    match spawn_watched_process_json(&cwd_string, &args) {
        Ok(payload) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

pub unsafe extern "C" fn clasp_rt_spawn_command_with_limits_json(
    cwd: *mut ClaspRtString,
    stdout_path: *mut ClaspRtString,
    stderr_path: *mut ClaspRtString,
    heartbeat_path: *mut ClaspRtString,
    poll_ms: *mut ClaspRtHeader,
    memory_limit_mb: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let stdout_path_string = String::from_utf8_lossy(string_bytes(stdout_path)).into_owned();
    let stderr_path_string = String::from_utf8_lossy(string_bytes(stderr_path)).into_owned();
    let heartbeat_path_string = String::from_utf8_lossy(string_bytes(heartbeat_path)).into_owned();
    let Some(command_items) = list_like_string_items(command) else {
        return clasp_rt_result_err_string(build_runtime_string(b"invalid_command"));
    };
    let command_values: Vec<String> = command_items
        .iter()
        .map(|value| String::from_utf8_lossy(string_bytes(*value)).into_owned())
        .collect();
    let poll_ms_value = match clasp_rt_int_arg(poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let memory_limit_mb_value = match parse_process_memory_limit_mb(memory_limit_mb) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let mut args = vec![
        stdout_path_string,
        stderr_path_string,
        heartbeat_path_string,
        poll_ms_value.to_string(),
        memory_limit_mb_value.to_string(),
    ];
    args.extend(command_values);
    match spawn_watched_process_with_limits_json(&cwd_string, &args) {
        Ok(payload) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

pub unsafe extern "C" fn clasp_rt_watch_command_with_limits_json(
    cwd: *mut ClaspRtString,
    stdout_path: *mut ClaspRtString,
    stderr_path: *mut ClaspRtString,
    heartbeat_path: *mut ClaspRtString,
    poll_ms: *mut ClaspRtHeader,
    memory_limit_mb: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let stdout_path_string = String::from_utf8_lossy(string_bytes(stdout_path)).into_owned();
    let stderr_path_string = String::from_utf8_lossy(string_bytes(stderr_path)).into_owned();
    let heartbeat_path_string = String::from_utf8_lossy(string_bytes(heartbeat_path)).into_owned();
    let Some(command_items) = list_like_string_items(command) else {
        return clasp_rt_result_err_string(build_runtime_string(b"invalid_command"));
    };
    let command_values: Vec<String> = command_items
        .iter()
        .map(|value| String::from_utf8_lossy(string_bytes(*value)).into_owned())
        .collect();
    let poll_ms_value = match clasp_rt_int_arg(poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let memory_limit_mb_value = match parse_process_memory_limit_mb(memory_limit_mb) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let mut args = vec![
        stdout_path_string,
        stderr_path_string,
        heartbeat_path_string,
        poll_ms_value.to_string(),
        memory_limit_mb_value.to_string(),
    ];
    args.extend(command_values);
    match watch_watched_process_with_limits_json(&cwd_string, &args) {
        Ok((_exit_code, payload)) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

pub unsafe extern "C" fn clasp_rt_reconcile_watched_process_json(
    heartbeat_path: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let heartbeat_path_string = String::from_utf8_lossy(string_bytes(heartbeat_path)).into_owned();
    match reconcile_watched_process_json(&heartbeat_path_string) {
        Ok(payload) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

#[no_mangle]
pub unsafe extern "C" fn clasp_rt_cancel_watched_process_json(
    heartbeat_path: *mut ClaspRtString,
) -> *mut ClaspRtResultString {
    let heartbeat_path_string = String::from_utf8_lossy(string_bytes(heartbeat_path)).into_owned();
    match cancel_watched_process_json(&heartbeat_path_string) {
        Ok(payload) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

pub unsafe extern "C" fn clasp_rt_await_watched_process_json(
    heartbeat_path: *mut ClaspRtString,
    poll_ms: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let heartbeat_path_string = String::from_utf8_lossy(string_bytes(heartbeat_path)).into_owned();
    let poll_ms_value = match clasp_rt_int_arg(poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    match await_watched_process_json(&heartbeat_path_string, poll_ms_value.max(0) as u64) {
        Ok(payload) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

pub unsafe extern "C" fn clasp_rt_await_watched_process_timeout_json(
    heartbeat_path: *mut ClaspRtString,
    poll_ms: *mut ClaspRtHeader,
    timeout_ms: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let heartbeat_path_string = String::from_utf8_lossy(string_bytes(heartbeat_path)).into_owned();
    let poll_ms_value = match clasp_rt_int_arg(poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let timeout_ms_value = match clasp_rt_int_arg(timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    match await_watched_process_timeout_json(
        &heartbeat_path_string,
        poll_ms_value.max(0) as u64,
        timeout_ms_value.max(0) as u64,
    ) {
        Ok(payload) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

pub unsafe extern "C" fn clasp_rt_handoff_command_json(
    cwd: *mut ClaspRtString,
    stdout_path: *mut ClaspRtString,
    stderr_path: *mut ClaspRtString,
    heartbeat_path: *mut ClaspRtString,
    watch_poll_ms: *mut ClaspRtHeader,
    ready_path: *mut ClaspRtString,
    ready_contains: *mut ClaspRtString,
    ready_poll_ms: *mut ClaspRtHeader,
    ready_timeout_ms: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let stdout_path_string = String::from_utf8_lossy(string_bytes(stdout_path)).into_owned();
    let stderr_path_string = String::from_utf8_lossy(string_bytes(stderr_path)).into_owned();
    let heartbeat_path_string = String::from_utf8_lossy(string_bytes(heartbeat_path)).into_owned();
    let ready_path_string = String::from_utf8_lossy(string_bytes(ready_path)).into_owned();
    let ready_contains_string = String::from_utf8_lossy(string_bytes(ready_contains)).into_owned();
    let Some(command_items) = list_like_string_items(command) else {
        return clasp_rt_result_err_string(build_runtime_string(b"invalid_command"));
    };
    let command_values: Vec<String> = command_items
        .iter()
        .map(|value| String::from_utf8_lossy(string_bytes(*value)).into_owned())
        .collect();
    let watch_poll_ms_value = match clasp_rt_int_arg(watch_poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let ready_poll_ms_value = match clasp_rt_int_arg(ready_poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let ready_timeout_ms_value = match clasp_rt_int_arg(ready_timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };

    let mut args = vec![
        stdout_path_string,
        stderr_path_string,
        heartbeat_path_string,
        watch_poll_ms_value.to_string(),
        ready_path_string,
        ready_contains_string,
        ready_poll_ms_value.to_string(),
        ready_timeout_ms_value.to_string(),
    ];
    args.extend(command_values);
    match handoff_watched_process_json(&cwd_string, &args) {
        Ok(payload) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

pub unsafe extern "C" fn clasp_rt_upgrade_command_json(
    cwd: *mut ClaspRtString,
    service_root: *mut ClaspRtString,
    service_id: *mut ClaspRtString,
    snapshot_text: *mut ClaspRtString,
    ready_path: *mut ClaspRtString,
    ready_contains: *mut ClaspRtString,
    watch_poll_ms: *mut ClaspRtHeader,
    ready_poll_ms: *mut ClaspRtHeader,
    ready_timeout_ms: *mut ClaspRtHeader,
    commit_grace_ms: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let service_root_string = String::from_utf8_lossy(string_bytes(service_root)).into_owned();
    let service_id_string = String::from_utf8_lossy(string_bytes(service_id)).into_owned();
    let snapshot_text_string = String::from_utf8_lossy(string_bytes(snapshot_text)).into_owned();
    let ready_path_string = String::from_utf8_lossy(string_bytes(ready_path)).into_owned();
    let ready_contains_string = String::from_utf8_lossy(string_bytes(ready_contains)).into_owned();
    let Some(command_items) = list_like_string_items(command) else {
        return clasp_rt_result_err_string(build_runtime_string(b"invalid_command"));
    };
    let command_values: Vec<String> = command_items
        .iter()
        .map(|value| String::from_utf8_lossy(string_bytes(*value)).into_owned())
        .collect();
    let watch_poll_ms_value = match clasp_rt_int_arg(watch_poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let ready_poll_ms_value = match clasp_rt_int_arg(ready_poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let ready_timeout_ms_value = match clasp_rt_int_arg(ready_timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let commit_grace_ms_value = match clasp_rt_int_arg(commit_grace_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };

    let mut args = vec![
        service_root_string,
        service_id_string,
        snapshot_text_string,
        ready_path_string,
        ready_contains_string,
        watch_poll_ms_value.to_string(),
        ready_poll_ms_value.to_string(),
        ready_timeout_ms_value.to_string(),
        commit_grace_ms_value.to_string(),
    ];
    args.extend(command_values);
    match upgrade_command_json(&cwd_string, &args) {
        Ok(payload) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

pub unsafe extern "C" fn clasp_rt_supervise_command_json(
    cwd: *mut ClaspRtString,
    service_root: *mut ClaspRtString,
    service_id: *mut ClaspRtString,
    ready_path: *mut ClaspRtString,
    ready_contains: *mut ClaspRtString,
    watch_poll_ms: *mut ClaspRtHeader,
    ready_poll_ms: *mut ClaspRtHeader,
    ready_timeout_ms: *mut ClaspRtHeader,
    restart_delay_ms: *mut ClaspRtHeader,
    command: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let cwd_string = String::from_utf8_lossy(string_bytes(cwd)).into_owned();
    let service_root_string = String::from_utf8_lossy(string_bytes(service_root)).into_owned();
    let service_id_string = String::from_utf8_lossy(string_bytes(service_id)).into_owned();
    let ready_path_string = String::from_utf8_lossy(string_bytes(ready_path)).into_owned();
    let ready_contains_string = String::from_utf8_lossy(string_bytes(ready_contains)).into_owned();
    let Some(command_items) = list_like_string_items(command) else {
        return clasp_rt_result_err_string(build_runtime_string(b"invalid_command"));
    };
    let command_values: Vec<String> = command_items
        .iter()
        .map(|value| String::from_utf8_lossy(string_bytes(*value)).into_owned())
        .collect();
    let watch_poll_ms_value = match clasp_rt_int_arg(watch_poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let ready_poll_ms_value = match clasp_rt_int_arg(ready_poll_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let ready_timeout_ms_value = match clasp_rt_int_arg(ready_timeout_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let restart_delay_ms_value = match clasp_rt_int_arg(restart_delay_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };

    let mut args = vec![
        service_root_string,
        service_id_string,
        ready_path_string,
        ready_contains_string,
        watch_poll_ms_value.to_string(),
        ready_poll_ms_value.to_string(),
        ready_timeout_ms_value.to_string(),
        restart_delay_ms_value.to_string(),
    ];
    args.extend(command_values);
    match supervise_command_json(&cwd_string, &args) {
        Ok(payload) => clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes())),
        Err(message) => clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    }
}

pub unsafe extern "C" fn clasp_rt_sleep_ms(
    delay_ms: *mut ClaspRtHeader,
) -> *mut ClaspRtResultString {
    let value = match clasp_rt_int_arg(delay_ms) {
        Ok(value) => value,
        Err(message) => return clasp_rt_result_err_string(build_runtime_string(message.as_bytes())),
    };
    let payload = sleep_ms_json(value);
    clasp_rt_result_ok_string(build_runtime_string(payload.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unique_test_suffix() -> String {
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("expected system time after unix epoch")
            .as_nanos();
        format!("{}-{}", std::process::id(), timestamp)
    }

    unsafe fn build_string_list(values: &[&[u8]]) -> *mut ClaspRtHeader {
        let list = build_runtime_string_list(values.len());
        for (index, value) in values.iter().enumerate() {
            string_list_items_mut(list)[index] = build_runtime_string(value);
        }
        list as *mut ClaspRtHeader
    }

    unsafe fn build_value_list(values: &[&[u8]]) -> *mut ClaspRtHeader {
        let items: Vec<*mut ClaspRtHeader> = values
            .iter()
            .map(|value| build_runtime_string(value) as *mut ClaspRtHeader)
            .collect();
        build_runtime_list_value(items) as *mut ClaspRtHeader
    }

    unsafe fn result_string_text(result: *mut ClaspRtResultString) -> String {
        String::from_utf8_lossy(string_bytes((*result).value)).into_owned()
    }

    #[test]
    fn json_decode_string_supports_unicode_escapes() {
        let text = br#""context-verifier-output\u001b]0;\u0007""#;
        let slice = json_root_value(text).expect("expected string root");
        let decoded = json_decode_string(text, slice).expect("expected unicode escape decode");

        assert_eq!(
            String::from_utf8(decoded).expect("expected utf8"),
            "context-verifier-output\u{001b}]0;\u{0007}"
        );
    }

    #[test]
    fn json_decode_string_supports_surrogate_pairs() {
        let text = br#""music-\uD834\uDD1E""#;
        let slice = json_root_value(text).expect("expected string root");
        let decoded = json_decode_string(text, slice).expect("expected surrogate pair decode");

        assert_eq!(String::from_utf8(decoded).expect("expected utf8"), "music-\u{1D11E}");
    }

    #[test]
    fn json_decode_string_rejects_invalid_surrogates() {
        let high_only = br#""bad-\uD834""#;
        let high_slice = json_root_value(high_only).expect("expected string root");
        assert!(json_decode_string(high_only, high_slice).is_none());

        let low_only = br#""bad-\uDD1E""#;
        let low_slice = json_root_value(low_only).expect("expected string root");
        assert!(json_decode_string(low_only, low_slice).is_none());
    }

    #[test]
    fn json_array_items_preserves_nested_values_and_string_commas() {
        let text = br#"[1, {"text":"a,b","nested":[true,false]}, [], "tail"]"#;
        let root = json_root_value(text).expect("expected array root");
        let items = json_array_items(text, root).expect("expected array items");

        assert_eq!(items.len(), json_array_length(text, root));
        for (index, item) in items.iter().enumerate() {
            let indexed = json_array_item(text, root, index).expect("expected indexed item");
            assert_eq!(item.start, indexed.start);
            assert_eq!(item.end, indexed.end);
        }
        assert_eq!(
            &text[items[1].start..items[1].end],
            br#"{"text":"a,b","nested":[true,false]}"#
        );

        let object = br#"{"not":"array"}"#;
        let object_root = json_root_value(object).expect("expected object root");
        assert!(json_array_items(object, object_root).is_none());
    }

    #[test]
    fn parse_document_reference_specs_extracts_explicit_references() {
        let references = parse_document_reference_specs(
            "Compare @document[doc-alpha|Alpha MSA] against @document[doc-beta].",
        )
        .expect("expected @document references to parse");

        assert_eq!(
            references,
            vec![
                DocumentReferenceSpec {
                    document_id: "doc-alpha".to_owned(),
                    label: "Alpha MSA".to_owned(),
                    raw: "@document[doc-alpha|Alpha MSA]".to_owned(),
                },
                DocumentReferenceSpec {
                    document_id: "doc-beta".to_owned(),
                    label: "doc-beta".to_owned(),
                    raw: "@document[doc-beta]".to_owned(),
                },
            ]
        );
    }

    #[test]
    fn parse_document_reference_specs_rejects_unterminated_references() {
        let error = parse_document_reference_specs("Review @document[doc-alpha")
            .expect_err("expected unterminated reference to fail");
        assert_eq!(error, "unterminated @document reference");
    }

    #[test]
    fn document_upload_boundary_returns_typed_handle() {
        unsafe {
            let upload = clasp_rt_build_record_header(
                "UploadedDocument",
                vec![
                    (
                        "documentId".to_owned(),
                        clasp_rt_build_string_header("doc-service-agreement"),
                    ),
                    (
                        "filename".to_owned(),
                        clasp_rt_build_string_header("service-agreement.txt"),
                    ),
                    ("mediaType".to_owned(), clasp_rt_build_string_header("text/plain")),
                    ("sizeBytes".to_owned(), clasp_rt_build_int_header(0)),
                    (
                        "contentText".to_owned(),
                        clasp_rt_build_string_header("Service agreement terms and renewal window."),
                    ),
                ],
            );

            let result = interpret_document_upload_boundary(upload);
            assert_eq!(variant_tag_text(result), Some("Ok".to_owned()));

            let result_variant = result as *mut ClaspRtVariantValue;
            let payload = variant_items(result_variant)[0];
            let payload_record = payload as *mut ClaspRtRecordValue;
            assert_eq!(string_bytes((*payload_record).record_name), b"DocumentHandle");
            assert_eq!(
                string_field_text(payload_record, b"documentId"),
                Some("doc-service-agreement".to_owned())
            );
            assert_eq!(
                string_field_text(payload_record, b"filename"),
                Some("service-agreement.txt".to_owned())
            );
            assert_eq!(
                string_field_text(payload_record, b"mediaType"),
                Some("text/plain".to_owned())
            );
            assert_eq!(int_field_value(payload_record, b"sizeBytes"), Some(43));
            assert_eq!(
                string_field_text(payload_record, b"excerpt"),
                Some("Service agreement terms and renewal window.".to_owned())
            );
            assert_eq!(
                string_field_text(payload_record, b"contentFingerprint"),
                Some(document_boundary_fingerprint(
                    "Service agreement terms and renewal window."
                ))
            );

            release_header(null_mut(), upload);
            release_header(null_mut(), result);
        }
    }

    #[test]
    fn run_command_json_passes_subprocess_args_once() {
        unsafe {
            let cwd_dir = std::env::temp_dir();
            let cwd_text = cwd_dir.display().to_string();
            let cwd = build_runtime_string(cwd_text.as_bytes());
            let script_path = cwd_dir.join(format!("clasp-run-command-json-args-{}.sh", std::process::id()));
            std::fs::write(
                &script_path,
                b"#!/bin/sh\nprintf '%s' \"$#:$1:$2\"\n",
            )
            .expect("expected test script write to succeed");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected test script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions).expect("expected executable test script permissions");

            let command = build_runtime_list_value(vec![
                build_runtime_string(script_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
                build_runtime_string(b"alpha") as *mut ClaspRtHeader,
                build_runtime_string(b"beta") as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let result = clasp_rt_run_command_json(cwd, command);
            assert!((*result).is_ok);

            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid JSON payload");
            assert_eq!(parsed["exitCode"].as_i64(), Some(0));
            assert_eq!(parsed["stdout"].as_str(), Some("2:alpha:beta"));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), command);
            release_header(null_mut(), result as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(script_path);
        }
    }

    #[test]
    fn list_equality_handles_string_list_and_value_list() {
        unsafe {
            let split_value = build_string_list(&[b"Ada"]);
            let literal_value = build_value_list(&[b"Ada"]);

            assert_eq!(
                compare_runtime_values(ClaspRtInterpretedCompareOp::Eq, split_value, literal_value),
                Some(true)
            );
            assert_eq!(
                compare_runtime_values(ClaspRtInterpretedCompareOp::Ne, split_value, literal_value),
                Some(false)
            );

            release_header(null_mut(), split_value);
            release_header(null_mut(), literal_value);
        }
    }

    #[test]
    fn list_equality_detects_mismatched_items() {
        unsafe {
            let left = build_string_list(&[b"Grace", b"Linus"]);
            let right = build_value_list(&[b"Grace", b"Ada"]);

            assert_eq!(
                compare_runtime_values(ClaspRtInterpretedCompareOp::Eq, left, right),
                Some(false)
            );
            assert_eq!(
                compare_runtime_values(ClaspRtInterpretedCompareOp::Ne, left, right),
                Some(true)
            );

            release_header(null_mut(), left);
            release_header(null_mut(), right);
        }
    }

    #[test]
    fn run_command_json_captures_exit_code_and_streams() {
        unsafe {
            let cwd_dir = std::env::temp_dir();
            let cwd_text = cwd_dir.display().to_string();
            let cwd = build_runtime_string(cwd_text.as_bytes());
            let script_path = cwd_dir.join(format!("clasp-run-command-json-{}.sh", std::process::id()));
            std::fs::write(
                &script_path,
                b"#!/bin/sh\nprintf stdout-text\nprintf stderr-text >&2\nexit 7\n",
            )
            .expect("expected test script write to succeed");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected test script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions).expect("expected executable test script permissions");

            let command = build_runtime_list_value(vec![
                build_runtime_string(script_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let result = clasp_rt_run_command_json(cwd, command);
            assert!((*result).is_ok);

            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid JSON payload");
            assert_eq!(parsed["exitCode"].as_i64(), Some(7));
            assert_eq!(parsed["stdout"].as_str(), Some("stdout-text"));
            assert_eq!(parsed["stderr"].as_str(), Some("stderr-text"));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), command);
            release_header(null_mut(), result as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(script_path);
        }
    }

    #[test]
    fn current_working_directory_reports_process_cwd() {
        unsafe {
            let result = clasp_rt_current_working_directory();
            assert!((*result).is_ok);

            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let expected = std::env::current_dir()
                .expect("expected current working directory")
                .to_string_lossy()
                .into_owned();
            assert_eq!(payload, expected);

            let binding = ClaspRtNativeRuntimeBinding {
                name: "currentWorkingDirectoryRaw".to_owned(),
                runtime_name: "currentWorkingDirectory".to_owned(),
                binding_type: "Result Str".to_owned(),
            };
            let binding_result = interpret_runtime_binding(&binding, &[]);
            assert!(!binding_result.is_null());
            assert_eq!((*binding_result).layout_id, CLASP_RT_LAYOUT_RESULT_STRING);
            assert!((*(binding_result as *mut ClaspRtResultString)).is_ok);

            release_header(null_mut(), result as *mut ClaspRtHeader);
            release_header(null_mut(), binding_result);
        }
    }

    #[test]
    fn run_process_json_passes_explicit_env_and_cwd() {
        unsafe {
            let cwd_dir = std::env::temp_dir().join(format!(
                "clasp-run-process-json-{}",
                unique_test_suffix()
            ));
            std::fs::create_dir_all(&cwd_dir).expect("expected run process cwd");
            std::fs::write(cwd_dir.join("input.txt"), "file-text")
                .expect("expected run process input write");
            let cwd_text = cwd_dir.display().to_string();
            let cwd = build_runtime_string(cwd_text.as_bytes());
            let env_values = build_runtime_list_value(vec![
                build_runtime_string(b"CLASP_CHILD_VALUE=child-env") as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;
            let command = build_runtime_list_value(vec![
                build_runtime_string(b"/bin/sh") as *mut ClaspRtHeader,
                build_runtime_string(b"-c") as *mut ClaspRtHeader,
                build_runtime_string(
                    b"IFS= read -r file_text < input.txt; printf $CLASP_CHILD_VALUE; printf ':'; printf ${CLASP_PARENT_SHOULD_NOT_LEAK:-missing}; printf ':'; printf $file_text; printf err-$CLASP_CHILD_VALUE >&2",
                ) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let result = clasp_rt_run_process_json(cwd, env_values, command);
            assert!((*result).is_ok);

            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid JSON payload");
            assert_eq!(parsed["exitCode"].as_i64(), Some(0));
            assert_eq!(parsed["stdout"].as_str(), Some("child-env:missing:file-text"));
            assert_eq!(parsed["stderr"].as_str(), Some("err-child-env"));

            let binding = ClaspRtNativeRuntimeBinding {
                name: "runProcessRaw".to_owned(),
                runtime_name: "runProcessJson".to_owned(),
                binding_type: "Str -> [Str] -> [Str] -> Result Str".to_owned(),
            };
            let binding_result = interpret_runtime_binding(&binding, &[cwd as *mut ClaspRtHeader, env_values, command]);
            assert!(!binding_result.is_null());
            assert_eq!((*binding_result).layout_id, CLASP_RT_LAYOUT_RESULT_STRING);
            assert!((*(binding_result as *mut ClaspRtResultString)).is_ok);

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), env_values);
            release_header(null_mut(), command);
            release_header(null_mut(), result as *mut ClaspRtHeader);
            release_header(null_mut(), binding_result);
            let _ = std::fs::remove_dir_all(cwd_dir);
        }
    }

    #[test]
    fn run_process_json_rejects_malformed_env_entries() {
        unsafe {
            let cwd_dir = std::env::temp_dir();
            let cwd_text = cwd_dir.display().to_string();
            let cwd = build_runtime_string(cwd_text.as_bytes());
            let env_values = build_runtime_list_value(vec![
                build_runtime_string(b"CLASP_CHILD_VALUE") as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;
            let command = build_runtime_list_value(vec![
                build_runtime_string(b"sh") as *mut ClaspRtHeader,
                build_runtime_string(b"-c") as *mut ClaspRtHeader,
                build_runtime_string(b"printf should-not-run") as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let result = clasp_rt_run_process_json(cwd, env_values, command);
            assert!(!(*result).is_ok);
            assert_eq!(
                String::from_utf8_lossy(string_bytes((*result).value)),
                "invalid_env"
            );

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), env_values);
            release_header(null_mut(), command);
            release_header(null_mut(), result as *mut ClaspRtHeader);
        }
    }

    #[test]
    fn run_process_timeout_json_marks_timeout() {
        unsafe {
            let cwd_dir = std::env::temp_dir();
            let cwd_text = cwd_dir.display().to_string();
            let cwd = build_runtime_string(cwd_text.as_bytes());
            let timeout_ms = build_runtime_int(20) as *mut ClaspRtHeader;
            let env_values = build_runtime_list_value(vec![]) as *mut ClaspRtHeader;
            let command = build_runtime_list_value(vec![
                build_runtime_string(b"/bin/sh") as *mut ClaspRtHeader,
                build_runtime_string(b"-c") as *mut ClaspRtHeader,
                build_runtime_string(b"while :; do :; done") as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let result = clasp_rt_run_process_timeout_json(cwd, timeout_ms, env_values, command);
            assert!((*result).is_ok);

            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid JSON payload");
            assert_eq!(parsed["exitCode"].as_i64(), Some(124));
            assert_eq!(parsed["timedOut"].as_bool(), Some(true));
            assert_eq!(parsed["error"].as_str(), Some("timeout"));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), timeout_ms);
            release_header(null_mut(), env_values);
            release_header(null_mut(), command);
            release_header(null_mut(), result as *mut ClaspRtHeader);
        }
    }

    #[test]
    #[cfg(unix)]
    fn run_process_timeout_json_terminates_process_group() {
        let temp_root = env::temp_dir().join(format!(
            "clasp-run-process-timeout-tree-{}",
            unique_test_suffix()
        ));
        fs::create_dir_all(&temp_root).expect("expected timeout tree temp root");
        let marker_path = temp_root.join("survived.txt");

        unsafe {
            let cwd = build_runtime_string(temp_root.to_string_lossy().as_bytes());
            let timeout_ms = build_runtime_int(50) as *mut ClaspRtHeader;
            let path_env = format!("PATH={}", env::var("PATH").unwrap_or_default());
            let env_values = build_runtime_list_value(vec![
                build_runtime_string(path_env.as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;
            let command = build_runtime_list_value(vec![
                build_runtime_string(b"/bin/sh") as *mut ClaspRtHeader,
                build_runtime_string(b"-c") as *mut ClaspRtHeader,
                build_runtime_string(b"(sleep 0.2; printf leaked > \"$1\") & printf parent-start; sleep 5")
                    as *mut ClaspRtHeader,
                build_runtime_string(b"clasp-timeout-child") as *mut ClaspRtHeader,
                build_runtime_string(marker_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let result = clasp_rt_run_process_timeout_json(cwd, timeout_ms, env_values, command);
            assert!((*result).is_ok);

            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid JSON payload");
            assert_eq!(parsed["exitCode"].as_i64(), Some(124));
            assert_eq!(parsed["timedOut"].as_bool(), Some(true));
            assert_eq!(parsed["error"].as_str(), Some("timeout"));

            thread::sleep(Duration::from_millis(350));
            assert!(
                !marker_path.exists(),
                "timed process descendants should not survive timeout"
            );

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), timeout_ms);
            release_header(null_mut(), env_values);
            release_header(null_mut(), command);
            release_header(null_mut(), result as *mut ClaspRtHeader);
        }

        let _ = fs::remove_dir_all(temp_root);
    }

    #[test]
    fn append_file_creates_parent_directory_and_preserves_appends() {
        let temp_root = env::temp_dir().join(format!("clasp-append-file-{}", unique_test_suffix()));
        let log_path = temp_root.join("nested").join("events.jsonl");

        unsafe {
            let path = build_runtime_string(log_path.to_string_lossy().as_bytes());
            let first = build_runtime_string(b"event-one\n");
            let second = build_runtime_string(b"event-two\n");

            let first_result = clasp_rt_append_file(path, first);
            assert!((*first_result).is_ok);
            let second_result = clasp_rt_append_file(path, second);
            assert!((*second_result).is_ok);

            assert_eq!(
                fs::read_to_string(&log_path).expect("expected appended log to be readable"),
                "event-one\nevent-two\n"
            );

            release_header(null_mut(), path as *mut ClaspRtHeader);
            release_header(null_mut(), first as *mut ClaspRtHeader);
            release_header(null_mut(), second as *mut ClaspRtHeader);
            release_header(null_mut(), first_result as *mut ClaspRtHeader);
            release_header(null_mut(), second_result as *mut ClaspRtHeader);
        }

        let _ = fs::remove_dir_all(temp_root);
    }

    #[test]
    fn run_command_timeout_json_captures_success_before_deadline() {
        unsafe {
            let cwd_dir = std::env::temp_dir();
            let cwd_text = cwd_dir.display().to_string();
            let cwd = build_runtime_string(cwd_text.as_bytes());
            let timeout_ms = build_runtime_int(1000) as *mut ClaspRtHeader;
            let script_path = cwd_dir.join(format!("clasp-run-command-timeout-json-{}.sh", std::process::id()));
            std::fs::write(
                &script_path,
                b"#!/bin/sh\nprintf timeout-stdout\nprintf timeout-stderr >&2\nexit 5\n",
            )
            .expect("expected test script write to succeed");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected test script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions).expect("expected executable test script permissions");

            let command = build_runtime_list_value(vec![
                build_runtime_string(script_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let result = clasp_rt_run_command_timeout_json(cwd, timeout_ms, command);
            assert!((*result).is_ok);

            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid JSON payload");
            assert_eq!(parsed["exitCode"].as_i64(), Some(5));
            assert_eq!(parsed["stdout"].as_str(), Some("timeout-stdout"));
            assert_eq!(parsed["stderr"].as_str(), Some("timeout-stderr"));
            assert_eq!(parsed["timedOut"].as_bool(), Some(false));
            assert_eq!(parsed["error"].as_str(), Some(""));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), timeout_ms);
            release_header(null_mut(), command);
            release_header(null_mut(), result as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(script_path);
        }
    }

    #[test]
    fn run_command_timeout_json_kills_slow_process() {
        unsafe {
            let cwd_dir = std::env::temp_dir();
            let cwd_text = cwd_dir.display().to_string();
            let cwd = build_runtime_string(cwd_text.as_bytes());
            let timeout_ms = build_runtime_int(50) as *mut ClaspRtHeader;
            let script_path = cwd_dir.join(format!("clasp-run-command-timeout-json-slow-{}.sh", std::process::id()));
            std::fs::write(
                &script_path,
                b"#!/bin/sh\nprintf before-timeout\nwhile :; do :; done\n",
            )
            .expect("expected test script write to succeed");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected test script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions).expect("expected executable test script permissions");

            let command = build_runtime_list_value(vec![
                build_runtime_string(script_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let result = clasp_rt_run_command_timeout_json(cwd, timeout_ms, command);
            assert!((*result).is_ok);

            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid JSON payload");
            assert_eq!(parsed["exitCode"].as_i64(), Some(124));
            assert_eq!(parsed["stdout"].as_str(), Some("before-timeout"));
            assert_eq!(parsed["timedOut"].as_bool(), Some(true));
            assert_eq!(parsed["error"].as_str(), Some("timeout"));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), timeout_ms);
            release_header(null_mut(), command);
            release_header(null_mut(), result as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(script_path);
        }
    }

    #[test]
    fn run_command_json_dispatches_swarm_commands_without_shelling_out() {
        unsafe {
            let cwd_dir = std::env::temp_dir();
            let cwd_text = cwd_dir.display().to_string();
            let cwd = build_runtime_string(cwd_text.as_bytes());
            let root = cwd_dir.join(format!("clasp-run-command-json-swarm-{}", std::process::id()));
            let root_text = root.display().to_string();
            let command = build_runtime_list_value(vec![
                build_runtime_string(b"@swarm") as *mut ClaspRtHeader,
                build_runtime_string(b"objective") as *mut ClaspRtHeader,
                build_runtime_string(b"create") as *mut ClaspRtHeader,
                build_runtime_string(root_text.as_bytes()) as *mut ClaspRtHeader,
                build_runtime_string(b"loop") as *mut ClaspRtHeader,
                build_runtime_string(b"--detail") as *mut ClaspRtHeader,
                build_runtime_string(b"Direct runtime dispatch.") as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let result = clasp_rt_run_command_json(cwd, command);
            assert!((*result).is_ok);

            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid JSON payload");
            assert_eq!(parsed["exitCode"].as_i64(), Some(0));
            let stdout = parsed["stdout"].as_str().expect("stdout string");
            let stdout_json: serde_json::Value = serde_json::from_str(stdout).expect("stdout json");
            assert_eq!(stdout_json["objectiveId"].as_str(), Some("loop"));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), command);
            release_header(null_mut(), result as *mut ClaspRtHeader);
            let _ = std::fs::remove_dir_all(root);
        }
    }

    #[test]
    fn run_command_json_watch_streams_to_files_and_writes_heartbeat() {
        unsafe {
            let cwd_dir = std::env::temp_dir();
            let cwd_text = cwd_dir.display().to_string();
            let cwd = build_runtime_string(cwd_text.as_bytes());
            let script_path = cwd_dir.join(format!("clasp-run-command-json-watch-{}.sh", std::process::id()));
            let stdout_path = cwd_dir.join(format!("clasp-run-command-json-watch-{}.stdout", std::process::id()));
            let stderr_path = cwd_dir.join(format!("clasp-run-command-json-watch-{}.stderr", std::process::id()));
            let heartbeat_path = cwd_dir.join(format!("clasp-run-command-json-watch-{}.heartbeat.json", std::process::id()));
            std::fs::write(
                &script_path,
                b"#!/bin/sh\nprintf builder-start\\n\nprintf builder-progress >&2\nsleep 0.1\nprintf builder-finish\\n\n",
            )
            .expect("expected watch test script write to succeed");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected watch test script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions).expect("expected executable test script permissions");

            let command = build_runtime_list_value(vec![
                build_runtime_string(b"@proc") as *mut ClaspRtHeader,
                build_runtime_string(b"watch") as *mut ClaspRtHeader,
                build_runtime_string(stdout_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
                build_runtime_string(stderr_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
                build_runtime_string(heartbeat_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
                build_runtime_string(b"50") as *mut ClaspRtHeader,
                build_runtime_string(script_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let result = clasp_rt_run_command_json(cwd, command);
            assert!((*result).is_ok);

            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid JSON payload");
            assert_eq!(parsed["exitCode"].as_i64(), Some(0));
            let stdout = parsed["stdout"].as_str().expect("stdout string");
            let stdout_json: serde_json::Value = serde_json::from_str(stdout).expect("stdout json");
            assert_eq!(stdout_json["completed"].as_bool(), Some(true));
            assert_eq!(stdout_json["exitCode"].as_i64(), Some(0));

            let streamed_stdout = std::fs::read_to_string(&stdout_path).expect("expected stdout log");
            let streamed_stderr = std::fs::read_to_string(&stderr_path).expect("expected stderr log");
            let heartbeat = std::fs::read_to_string(&heartbeat_path).expect("expected heartbeat file");
            assert!(streamed_stdout.contains("builder-start"));
            assert!(streamed_stdout.contains("builder-finish"));
            assert!(streamed_stderr.contains("builder-progress"));
            assert!(heartbeat.contains("\"completed\":true"));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), command);
            release_header(null_mut(), result as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(script_path);
            let _ = std::fs::remove_file(stdout_path);
            let _ = std::fs::remove_file(stderr_path);
            let _ = std::fs::remove_file(heartbeat_path);
        }
    }

    #[test]
    fn spawn_command_json_returns_running_handle_and_awaits_completion() {
        unsafe {
            let cwd_dir = std::env::temp_dir();
            let cwd_text = cwd_dir.display().to_string();
            let cwd = build_runtime_string(cwd_text.as_bytes());
            let script_path = cwd_dir.join(format!("clasp-spawn-command-json-{}.sh", std::process::id()));
            let stdout_path = cwd_dir.join(format!("clasp-spawn-command-json-{}.stdout", std::process::id()));
            let stderr_path = cwd_dir.join(format!("clasp-spawn-command-json-{}.stderr", std::process::id()));
            let heartbeat_path =
                cwd_dir.join(format!("clasp-spawn-command-json-{}.heartbeat.json", std::process::id()));
            std::fs::write(
                &script_path,
                b"#!/bin/sh\nprintf spawn-start\\n\nprintf spawn-progress >&2\nsleep 0.1\nprintf spawn-finish\\n\n",
            )
            .expect("expected spawn test script write to succeed");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected spawn test script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions).expect("expected executable test script permissions");

            let stdout_rt = build_runtime_string(stdout_path.to_string_lossy().as_bytes());
            let stderr_rt = build_runtime_string(stderr_path.to_string_lossy().as_bytes());
            let heartbeat_rt = build_runtime_string(heartbeat_path.to_string_lossy().as_bytes());
            let poll_ms = build_runtime_int(50) as *mut ClaspRtHeader;
            let command = build_runtime_list_value(vec![
                build_runtime_string(script_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let spawned = clasp_rt_spawn_command_json(cwd, stdout_rt, stderr_rt, heartbeat_rt, poll_ms, command);
            assert!((*spawned).is_ok);
            let spawned_payload = String::from_utf8_lossy(string_bytes((*spawned).value)).into_owned();
            let spawned_json: serde_json::Value =
                serde_json::from_str(&spawned_payload).expect("expected valid spawned heartbeat");
            assert_eq!(spawned_json["running"].as_bool(), Some(true));
            assert_eq!(spawned_json["completed"].as_bool(), Some(false));
            assert!(spawned_json["pid"].as_i64().unwrap_or_default() > 0);

            let awaited = clasp_rt_await_watched_process_json(heartbeat_rt, poll_ms);
            assert!((*awaited).is_ok);
            let awaited_payload = String::from_utf8_lossy(string_bytes((*awaited).value)).into_owned();
            let awaited_json: serde_json::Value =
                serde_json::from_str(&awaited_payload).expect("expected valid awaited heartbeat");
            assert_eq!(awaited_json["completed"].as_bool(), Some(true));
            assert_eq!(awaited_json["exitCode"].as_i64(), Some(0));

            let streamed_stdout = std::fs::read_to_string(&stdout_path).expect("expected stdout log");
            let streamed_stderr = std::fs::read_to_string(&stderr_path).expect("expected stderr log");
            assert!(streamed_stdout.contains("spawn-start"));
            assert!(streamed_stdout.contains("spawn-finish"));
            assert!(streamed_stderr.contains("spawn-progress"));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), stdout_rt as *mut ClaspRtHeader);
            release_header(null_mut(), stderr_rt as *mut ClaspRtHeader);
            release_header(null_mut(), heartbeat_rt as *mut ClaspRtHeader);
            release_header(null_mut(), poll_ms);
            release_header(null_mut(), command);
            release_header(null_mut(), spawned as *mut ClaspRtHeader);
            release_header(null_mut(), awaited as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(script_path);
            let _ = std::fs::remove_file(stdout_path);
            let _ = std::fs::remove_file(stderr_path);
            let _ = std::fs::remove_file(heartbeat_path);
        }
    }

    #[test]
    fn spawn_command_json_resolves_relative_programs_from_launcher_cwd() {
        unsafe {
            let launcher_cwd = std::env::current_dir().expect("expected launcher cwd");
            let temp_root = launcher_cwd.join(".clasp-test-tmp").join(format!(
                "clasp-spawn-relative-{}",
                std::process::id()
            ));
            let child_cwd_dir = temp_root.join("workspace");
            std::fs::create_dir_all(&child_cwd_dir).expect("expected child cwd creation");
            let script_path = temp_root.join("tools").join("spawn-relative.sh");
            let stdout_path = temp_root.join("stdout.log");
            let stderr_path = temp_root.join("stderr.log");
            let heartbeat_path = temp_root.join("heartbeat.json");
            std::fs::create_dir_all(script_path.parent().expect("expected parent dir"))
                .expect("expected script dir creation");
            std::fs::write(&script_path, b"#!/bin/sh\nprintf relative-spawn\\n\n")
                .expect("expected relative spawn script write");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected relative spawn script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions)
                .expect("expected relative spawn script permissions");

            let relative_script = script_path
                .strip_prefix(&launcher_cwd)
                .expect("expected test script under launcher cwd")
                .to_string_lossy()
                .into_owned();
            let cwd = build_runtime_string(child_cwd_dir.to_string_lossy().as_bytes());
            let stdout_rt = build_runtime_string(stdout_path.to_string_lossy().as_bytes());
            let stderr_rt = build_runtime_string(stderr_path.to_string_lossy().as_bytes());
            let heartbeat_rt = build_runtime_string(heartbeat_path.to_string_lossy().as_bytes());
            let poll_ms = build_runtime_int(50) as *mut ClaspRtHeader;
            let command = build_runtime_list_value(vec![
                build_runtime_string(relative_script.as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let spawned = clasp_rt_spawn_command_json(cwd, stdout_rt, stderr_rt, heartbeat_rt, poll_ms, command);
            assert!((*spawned).is_ok, "expected spawn to succeed for repo-relative program path");

            let awaited = clasp_rt_await_watched_process_json(heartbeat_rt, poll_ms);
            assert!((*awaited).is_ok, "expected awaited spawn to succeed");
            let awaited_payload = String::from_utf8_lossy(string_bytes((*awaited).value)).into_owned();
            let awaited_json: serde_json::Value =
                serde_json::from_str(&awaited_payload).expect("expected valid awaited heartbeat");
            assert_eq!(awaited_json["completed"].as_bool(), Some(true));
            assert_eq!(awaited_json["exitCode"].as_i64(), Some(0));

            let streamed_stdout = std::fs::read_to_string(&stdout_path).expect("expected relative spawn stdout");
            assert!(streamed_stdout.contains("relative-spawn"));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), stdout_rt as *mut ClaspRtHeader);
            release_header(null_mut(), stderr_rt as *mut ClaspRtHeader);
            release_header(null_mut(), heartbeat_rt as *mut ClaspRtHeader);
            release_header(null_mut(), poll_ms);
            release_header(null_mut(), command);
            release_header(null_mut(), spawned as *mut ClaspRtHeader);
            release_header(null_mut(), awaited as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(script_path);
            let _ = std::fs::remove_file(stdout_path);
            let _ = std::fs::remove_file(stderr_path);
            let _ = std::fs::remove_file(heartbeat_path);
            let _ = std::fs::remove_dir_all(temp_root);
        }
    }

    #[test]
    fn reconcile_watched_process_json_marks_missing_pid_completed() {
        unsafe {
            let heartbeat_path =
                std::env::temp_dir().join(format!("clasp-reconcile-watch-{}.heartbeat.json", std::process::id()));
            std::fs::write(
                &heartbeat_path,
                serde_json::json!({
                    "pid": 0,
                    "running": true,
                    "completed": false,
                    "exitCode": 0,
                    "stdoutPath": heartbeat_path.with_extension("stdout").display().to_string(),
                    "stderrPath": heartbeat_path.with_extension("stderr").display().to_string(),
                    "heartbeatPath": heartbeat_path.display().to_string(),
                    "updatedAtMs": 0,
                })
                .to_string(),
            )
            .expect("expected stale heartbeat write");

            let heartbeat_rt = build_runtime_string(heartbeat_path.to_string_lossy().as_bytes());
            let result = clasp_rt_reconcile_watched_process_json(heartbeat_rt);
            assert!((*result).is_ok);
            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid reconciled heartbeat");
            assert_eq!(parsed["running"].as_bool(), Some(false));
            assert_eq!(parsed["completed"].as_bool(), Some(true));
            assert_eq!(parsed["exitCode"].as_i64(), Some(-1));

            release_header(null_mut(), heartbeat_rt as *mut ClaspRtHeader);
            release_header(null_mut(), result as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(heartbeat_path);
        }
    }

    #[test]
    fn clear_stale_service_status_for_restart_removes_dead_active_record() {
        let temp_root = std::env::temp_dir().join(format!(
            "clasp-stale-service-status-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&temp_root).expect("expected stale service temp root");
        let service_path = temp_root.join("service.json");
        let heartbeat_path = temp_root.join("service.heartbeat.json");
        std::fs::write(
            &heartbeat_path,
            serde_json::json!({
                "pid": 0,
                "running": true,
                "completed": false,
                "exitCode": 0,
                "stdoutPath": temp_root.join("stdout.log").display().to_string(),
                "stderrPath": temp_root.join("stderr.log").display().to_string(),
                "heartbeatPath": heartbeat_path.display().to_string(),
                "updatedAtMs": 0,
            })
            .to_string(),
        )
        .expect("expected stale service heartbeat write");
        std::fs::write(
            &service_path,
            service_status_json(
                &temp_root.to_string_lossy(),
                "goal-manager",
                1,
                "active",
                0,
                &heartbeat_path.to_string_lossy(),
                "",
                "",
                -1,
            )
            .to_string(),
        )
        .expect("expected stale service status write");

        clear_stale_service_status_for_restart(&service_path)
            .expect("expected stale service status cleanup");

        assert!(
            !service_path.exists(),
            "expected stale active service record to be removed before supervisor restart"
        );
        let reconciled: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(&heartbeat_path).expect("expected reconciled heartbeat")
        )
        .expect("expected heartbeat json");
        assert_eq!(reconciled["running"].as_bool(), Some(false));
        assert_eq!(reconciled["completed"].as_bool(), Some(true));

        let _ = std::fs::remove_dir_all(temp_root);
    }

    #[test]
    fn clear_stale_service_status_for_restart_preserves_live_active_record() {
        let temp_root = std::env::temp_dir().join(format!(
            "clasp-live-service-status-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&temp_root).expect("expected live service temp root");
        let service_path = temp_root.join("service.json");
        let heartbeat_path = temp_root.join("service.heartbeat.json");
        std::fs::write(
            &heartbeat_path,
            serde_json::json!({
                "pid": std::process::id(),
                "running": true,
                "completed": false,
                "exitCode": 0,
                "stdoutPath": temp_root.join("stdout.log").display().to_string(),
                "stderrPath": temp_root.join("stderr.log").display().to_string(),
                "heartbeatPath": heartbeat_path.display().to_string(),
                "updatedAtMs": runtime_time_unix_ms(),
            })
            .to_string(),
        )
        .expect("expected live service heartbeat write");
        std::fs::write(
            &service_path,
            service_status_json(
                &temp_root.to_string_lossy(),
                "goal-manager",
                1,
                "active",
                std::process::id() as i64,
                &heartbeat_path.to_string_lossy(),
                "",
                "",
                -1,
            )
            .to_string(),
        )
        .expect("expected live service status write");

        clear_stale_service_status_for_restart(&service_path)
            .expect("expected live service status check");

        assert!(
            service_path.exists(),
            "expected live active service record to be preserved"
        );

        let _ = std::fs::remove_dir_all(temp_root);
    }

    #[test]
    fn service_wait_result_reconciles_dead_active_record() {
        let temp_root = std::env::temp_dir().join(format!(
            "clasp-service-wait-stale-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&temp_root).expect("expected stale service temp root");
        let service_path = temp_root.join("service.json");
        let heartbeat_path = temp_root.join("service.heartbeat.json");
        std::fs::write(
            &heartbeat_path,
            serde_json::json!({
                "pid": 0,
                "running": true,
                "completed": false,
                "exitCode": 0,
                "stdoutPath": temp_root.join("stdout.log").display().to_string(),
                "stderrPath": temp_root.join("stderr.log").display().to_string(),
                "heartbeatPath": heartbeat_path.display().to_string(),
                "updatedAtMs": 0,
            })
            .to_string(),
        )
        .expect("expected stale service heartbeat write");
        std::fs::write(
            &service_path,
            service_status_json(
                &temp_root.to_string_lossy(),
                "goal-manager",
                1,
                "active",
                0,
                &heartbeat_path.to_string_lossy(),
                "",
                "",
                -1,
            )
            .to_string(),
        )
        .expect("expected stale service status write");

        let result = service_wait_result(service_path.to_str().expect("service path text"), 100)
            .expect("expected service wait to reconcile stale active record");
        let parsed: serde_json::Value =
            serde_json::from_str(&result).expect("expected valid reconciled service json");
        assert_eq!(parsed["status"].as_str(), Some("failed"));
        assert_eq!(parsed["exitCode"].as_i64(), Some(-1));

        let persisted: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(&service_path).expect("expected persisted service status")
        )
        .expect("expected persisted service json");
        assert_eq!(persisted["status"].as_str(), Some("failed"));

        let _ = std::fs::remove_dir_all(temp_root);
    }

    #[test]
    fn watched_process_exists_handles_basic_liveness() {
        assert!(!watched_process_exists(0));
        assert!(watched_process_exists(std::process::id()));
    }

    #[test]
    fn await_watched_process_json_retries_transient_empty_heartbeat() {
        unsafe {
            let heartbeat_path =
                std::env::temp_dir().join(format!("clasp-await-watch-empty-{}.heartbeat.json", std::process::id()));
            std::fs::write(&heartbeat_path, "").expect("expected initial empty heartbeat write");

            let completed_payload = serde_json::json!({
                "pid": 0,
                "running": false,
                "completed": true,
                "exitCode": 0,
                "stdoutPath": heartbeat_path.with_extension("stdout").display().to_string(),
                "stderrPath": heartbeat_path.with_extension("stderr").display().to_string(),
                "heartbeatPath": heartbeat_path.display().to_string(),
                "updatedAtMs": runtime_time_unix_ms(),
            })
            .to_string();

            let writer_path = heartbeat_path.clone();
            let writer_payload = completed_payload.clone();
            thread::spawn(move || {
                thread::sleep(Duration::from_millis(20));
                std::fs::write(writer_path, writer_payload).expect("expected completed heartbeat write");
            });

            let heartbeat_rt = build_runtime_string(heartbeat_path.to_string_lossy().as_bytes());
            let poll_ms = build_runtime_int(50) as *mut ClaspRtHeader;
            let result = clasp_rt_await_watched_process_json(heartbeat_rt, poll_ms);
            assert!((*result).is_ok);
            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let parsed: serde_json::Value = serde_json::from_str(&payload).expect("expected valid awaited heartbeat");
            assert_eq!(parsed["completed"].as_bool(), Some(true));
            assert_eq!(parsed["exitCode"].as_i64(), Some(0));

            release_header(null_mut(), heartbeat_rt as *mut ClaspRtHeader);
            release_header(null_mut(), poll_ms);
            release_header(null_mut(), result as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(heartbeat_path);
        }
    }

    #[test]
    fn await_watched_process_timeout_json_times_out_running_process() {
        unsafe {
            let temp_root = std::env::temp_dir().join(format!(
                "clasp-await-watch-timeout-{}",
                std::process::id()
            ));
            std::fs::create_dir_all(&temp_root).expect("expected timeout temp root");
            let script_path = temp_root.join("sleep.sh");
            let stdout_path = temp_root.join("stdout.log");
            let stderr_path = temp_root.join("stderr.log");
            let heartbeat_path = temp_root.join("heartbeat.json");
            std::fs::write(&script_path, b"#!/bin/sh\nsleep 1\nprintf delayed\\n")
                .expect("expected timeout test script write");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected timeout test script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions).expect("expected timeout test script permissions");

            let cwd = build_runtime_string(temp_root.to_string_lossy().as_bytes());
            let stdout_rt = build_runtime_string(stdout_path.to_string_lossy().as_bytes());
            let stderr_rt = build_runtime_string(stderr_path.to_string_lossy().as_bytes());
            let heartbeat_rt = build_runtime_string(heartbeat_path.to_string_lossy().as_bytes());
            let poll_ms = build_runtime_int(50) as *mut ClaspRtHeader;
            let timeout_ms = build_runtime_int(100) as *mut ClaspRtHeader;
            let command = build_runtime_list_value(vec![
                build_runtime_string(script_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let spawned = clasp_rt_spawn_command_json(cwd, stdout_rt, stderr_rt, heartbeat_rt, poll_ms, command);
            assert!((*spawned).is_ok);

            let awaited =
                clasp_rt_await_watched_process_timeout_json(heartbeat_rt, poll_ms, timeout_ms);
            assert!(!(*awaited).is_ok);
            let payload = String::from_utf8_lossy(string_bytes((*awaited).value)).into_owned();
            assert_eq!(payload, "timeout");

            let reconciled = clasp_rt_reconcile_watched_process_json(heartbeat_rt);
            assert!((*reconciled).is_ok);
            let reconciled_payload = String::from_utf8_lossy(string_bytes((*reconciled).value)).into_owned();
            let reconciled_json: serde_json::Value =
                serde_json::from_str(&reconciled_payload).expect("expected valid reconciled heartbeat");
            assert_eq!(reconciled_json["running"].as_bool(), Some(true));
            assert_eq!(reconciled_json["completed"].as_bool(), Some(false));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), stdout_rt as *mut ClaspRtHeader);
            release_header(null_mut(), stderr_rt as *mut ClaspRtHeader);
            release_header(null_mut(), heartbeat_rt as *mut ClaspRtHeader);
            release_header(null_mut(), poll_ms);
            release_header(null_mut(), timeout_ms);
            release_header(null_mut(), command);
            release_header(null_mut(), spawned as *mut ClaspRtHeader);
            release_header(null_mut(), awaited as *mut ClaspRtHeader);
            release_header(null_mut(), reconciled as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(script_path);
            let _ = std::fs::remove_file(stdout_path);
            let _ = std::fs::remove_file(stderr_path);
            let _ = std::fs::remove_file(heartbeat_path);
            let _ = std::fs::remove_dir_all(temp_root);
        }
    }

    #[test]
    fn cancel_watched_process_json_marks_timeout_and_stops_process() {
        unsafe {
            let temp_root = std::env::temp_dir().join(format!(
                "clasp-cancel-watch-timeout-{}",
                std::process::id()
            ));
            std::fs::create_dir_all(&temp_root).expect("expected cancel temp root");
            let script_path = temp_root.join("loop.sh");
            let stdout_path = temp_root.join("stdout.log");
            let stderr_path = temp_root.join("stderr.log");
            let heartbeat_path = temp_root.join("heartbeat.json");
            std::fs::write(&script_path, b"#!/bin/sh\nprintf started\nwhile :; do sleep 1; done\n")
                .expect("expected cancel test script write");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected cancel test script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions).expect("expected cancel test script permissions");

            let cwd = build_runtime_string(temp_root.to_string_lossy().as_bytes());
            let stdout_rt = build_runtime_string(stdout_path.to_string_lossy().as_bytes());
            let stderr_rt = build_runtime_string(stderr_path.to_string_lossy().as_bytes());
            let heartbeat_rt = build_runtime_string(heartbeat_path.to_string_lossy().as_bytes());
            let poll_ms = build_runtime_int(50) as *mut ClaspRtHeader;
            let command = build_runtime_list_value(vec![
                build_runtime_string(script_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let spawned = clasp_rt_spawn_command_json(cwd, stdout_rt, stderr_rt, heartbeat_rt, poll_ms, command);
            assert!((*spawned).is_ok);
            let spawned_payload = String::from_utf8_lossy(string_bytes((*spawned).value)).into_owned();
            let spawned_json: serde_json::Value =
                serde_json::from_str(&spawned_payload).expect("expected valid spawned heartbeat");
            let child_pid = spawned_json["pid"].as_i64().expect("expected child pid") as u32;
            assert!(watched_process_exists(child_pid), "expected watched process to be alive before cancel");

            let cancelled = clasp_rt_cancel_watched_process_json(heartbeat_rt);
            assert!((*cancelled).is_ok);
            let cancelled_payload = String::from_utf8_lossy(string_bytes((*cancelled).value)).into_owned();
            let cancelled_json: serde_json::Value =
                serde_json::from_str(&cancelled_payload).expect("expected valid cancelled heartbeat");
            assert_eq!(cancelled_json["status"].as_str(), Some("timeout"));
            assert_eq!(cancelled_json["completed"].as_bool(), Some(true));
            assert_eq!(cancelled_json["running"].as_bool(), Some(false));
            assert_eq!(cancelled_json["exitCode"].as_i64(), Some(124));
            assert_eq!(cancelled_json["timedOut"].as_bool(), Some(true));
            assert_eq!(cancelled_json["error"].as_str(), Some("timeout"));
            assert_eq!(cancelled_json["command"][0].as_str(), Some(script_path.to_string_lossy().as_ref()));
            assert!(cancelled_json["startedAtMs"].as_i64().unwrap_or_default() > 0);
            assert!(
                cancelled_json["endedAtMs"].as_i64().unwrap_or_default()
                    >= cancelled_json["startedAtMs"].as_i64().unwrap_or_default()
            );

            thread::sleep(Duration::from_millis(100));
            assert!(
                !watched_process_exists(child_pid),
                "expected watched process to stop after cancel"
            );

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), stdout_rt as *mut ClaspRtHeader);
            release_header(null_mut(), stderr_rt as *mut ClaspRtHeader);
            release_header(null_mut(), heartbeat_rt as *mut ClaspRtHeader);
            release_header(null_mut(), poll_ms);
            release_header(null_mut(), command);
            release_header(null_mut(), spawned as *mut ClaspRtHeader);
            release_header(null_mut(), cancelled as *mut ClaspRtHeader);
            let _ = std::fs::remove_dir_all(temp_root);
        }
    }

    #[test]
    fn cancel_watched_process_json_does_not_signal_legacy_unmarked_payload() {
        let temp_root = std::env::temp_dir().join(format!(
            "clasp-cancel-watch-unmarked-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&temp_root).expect("expected unmarked cancel temp root");
        let heartbeat_path = temp_root.join("heartbeat.json");
        let current_pid = std::process::id();
        let payload = serde_json::json!({
            "pid": current_pid,
            "processGroupId": current_pid,
            "status": "running",
            "running": true,
            "completed": false,
            "exitCode": -1,
            "timedOut": false,
            "error": "",
            "command": [],
            "stdoutPath": "",
            "stderrPath": "",
            "heartbeatPath": heartbeat_path.to_string_lossy(),
            "startedAtMs": runtime_time_unix_ms(),
            "updatedAtMs": runtime_time_unix_ms()
        });
        std::fs::write(&heartbeat_path, payload.to_string())
            .expect("expected legacy heartbeat write");

        let cancelled = cancel_watched_process_json(&heartbeat_path.to_string_lossy())
            .expect("expected legacy heartbeat cancellation to fail closed");
        let cancelled_json: serde_json::Value =
            serde_json::from_str(&cancelled).expect("expected valid cancelled heartbeat");
        assert_eq!(cancelled_json["status"].as_str(), Some("timeout"));
        assert_eq!(cancelled_json["completed"].as_bool(), Some(true));
        assert!(
            watched_process_exists(current_pid),
            "legacy unmarked heartbeat must not signal its recorded pid"
        );

        let _ = std::fs::remove_dir_all(temp_root);
    }

    #[test]
    fn cancel_watched_process_json_stops_nested_process_group() {
        unsafe {
            let temp_root = std::env::temp_dir().join(format!(
                "clasp-cancel-watch-group-timeout-{}",
                std::process::id()
            ));
            std::fs::create_dir_all(&temp_root).expect("expected cancel group temp root");
            let script_path = temp_root.join("loop-with-child.sh");
            let nested_pid_path = temp_root.join("nested.pid");
            let stdout_path = temp_root.join("stdout.log");
            let stderr_path = temp_root.join("stderr.log");
            let heartbeat_path = temp_root.join("heartbeat.json");
            std::fs::write(
                &script_path,
                format!(
                    "#!/bin/sh\nprintf started\n(sh -c 'printf \"%s\\n\" \"$$\" > \"$1\"; while :; do sleep 1; done' _ '{}') &\nwhile :; do sleep 1; done\n",
                    nested_pid_path.display()
                ),
            )
            .expect("expected cancel group test script write");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected cancel group test script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions)
                .expect("expected cancel group test script permissions");

            let cwd = build_runtime_string(temp_root.to_string_lossy().as_bytes());
            let stdout_rt = build_runtime_string(stdout_path.to_string_lossy().as_bytes());
            let stderr_rt = build_runtime_string(stderr_path.to_string_lossy().as_bytes());
            let heartbeat_rt = build_runtime_string(heartbeat_path.to_string_lossy().as_bytes());
            let poll_ms = build_runtime_int(50) as *mut ClaspRtHeader;
            let command = build_runtime_list_value(vec![
                build_runtime_string(script_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let spawned = clasp_rt_spawn_command_json(cwd, stdout_rt, stderr_rt, heartbeat_rt, poll_ms, command);
            assert!((*spawned).is_ok);
            let spawned_payload = String::from_utf8_lossy(string_bytes((*spawned).value)).into_owned();
            let spawned_json: serde_json::Value =
                serde_json::from_str(&spawned_payload).expect("expected valid spawned group heartbeat");
            let child_pid = spawned_json["pid"].as_i64().expect("expected child pid") as u32;
            let process_group_id = spawned_json["processGroupId"]
                .as_i64()
                .expect("expected process group id") as u32;
            assert_eq!(process_group_id, child_pid);
            assert!(
                spawned_json["watchToken"].as_str().unwrap_or_default().len() > 0,
                "expected watched process token"
            );

            let mut nested_pid = 0u32;
            for _ in 0..50 {
                if let Ok(text) = std::fs::read_to_string(&nested_pid_path) {
                    nested_pid = text.trim().parse::<u32>().unwrap_or(0);
                    if nested_pid > 0 {
                        break;
                    }
                }
                thread::sleep(Duration::from_millis(20));
            }
            assert!(watched_process_exists(child_pid), "expected watched process before group cancel");
            assert!(nested_pid > 0, "expected nested process pid");
            assert!(
                watched_process_exists(nested_pid),
                "expected nested process before group cancel"
            );

            let cancelled = clasp_rt_cancel_watched_process_json(heartbeat_rt);
            assert!((*cancelled).is_ok);

            thread::sleep(Duration::from_millis(150));
            let child_alive_after_cancel = watched_process_exists(child_pid);
            let nested_alive_after_cancel = watched_process_exists(nested_pid);
            if child_alive_after_cancel {
                terminate_watched_process_pid(child_pid);
            }
            if nested_alive_after_cancel {
                terminate_watched_process_pid(nested_pid);
            }
            assert!(
                !child_alive_after_cancel,
                "expected watched process to stop after group cancel"
            );
            assert!(
                !nested_alive_after_cancel,
                "expected nested process to stop after group cancel"
            );

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), stdout_rt as *mut ClaspRtHeader);
            release_header(null_mut(), stderr_rt as *mut ClaspRtHeader);
            release_header(null_mut(), heartbeat_rt as *mut ClaspRtHeader);
            release_header(null_mut(), poll_ms);
            release_header(null_mut(), command);
            release_header(null_mut(), spawned as *mut ClaspRtHeader);
            release_header(null_mut(), cancelled as *mut ClaspRtHeader);
            let _ = std::fs::remove_dir_all(temp_root);
        }
    }

    #[test]
    fn handoff_command_json_waits_for_successor_ready_marker() {
        unsafe {
            let temp_root = std::env::temp_dir().join(format!(
                "clasp-handoff-command-json-{}",
                std::process::id()
            ));
            std::fs::create_dir_all(&temp_root).expect("expected handoff temp root");
            let script_path = temp_root.join("handoff.sh");
            let stdout_path = temp_root.join("stdout.log");
            let stderr_path = temp_root.join("stderr.log");
            let heartbeat_path = temp_root.join("heartbeat.json");
            let ready_path = temp_root.join("ready.txt");
            std::fs::write(
                &script_path,
                format!(
                    "#!/bin/sh\nsleep 0.1\nprintf ready > {}\nprintf handoff-start\\n\nsleep 0.3\nprintf handoff-finish\\n\n",
                    ready_path.display()
                ),
            )
            .expect("expected handoff script write");
            let mut permissions = std::fs::metadata(&script_path)
                .expect("expected handoff script metadata")
                .permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&script_path, permissions)
                .expect("expected handoff script permissions");

            let cwd = build_runtime_string(temp_root.to_string_lossy().as_bytes());
            let stdout_rt = build_runtime_string(stdout_path.to_string_lossy().as_bytes());
            let stderr_rt = build_runtime_string(stderr_path.to_string_lossy().as_bytes());
            let heartbeat_rt = build_runtime_string(heartbeat_path.to_string_lossy().as_bytes());
            let ready_rt = build_runtime_string(ready_path.to_string_lossy().as_bytes());
            let ready_contains_rt = build_runtime_string(b"ready");
            let watch_poll_ms = build_runtime_int(50) as *mut ClaspRtHeader;
            let ready_poll_ms = build_runtime_int(25) as *mut ClaspRtHeader;
            let ready_timeout_ms = build_runtime_int(1000) as *mut ClaspRtHeader;
            let command = build_runtime_list_value(vec![
                build_runtime_string(script_path.to_string_lossy().as_bytes()) as *mut ClaspRtHeader,
            ]) as *mut ClaspRtHeader;

            let handed_off = clasp_rt_handoff_command_json(
                cwd,
                stdout_rt,
                stderr_rt,
                heartbeat_rt,
                watch_poll_ms,
                ready_rt,
                ready_contains_rt,
                ready_poll_ms,
                ready_timeout_ms,
                command,
            );
            assert!((*handed_off).is_ok);
            let handed_off_payload = String::from_utf8_lossy(string_bytes((*handed_off).value)).into_owned();
            let handed_off_json: serde_json::Value =
                serde_json::from_str(&handed_off_payload).expect("expected valid handoff heartbeat");
            assert_eq!(handed_off_json["running"].as_bool(), Some(true));
            assert_eq!(handed_off_json["completed"].as_bool(), Some(false));
            assert_eq!(
                std::fs::read_to_string(&ready_path).expect("expected ready marker"),
                "ready"
            );

            let awaited = clasp_rt_await_watched_process_json(heartbeat_rt, watch_poll_ms);
            assert!((*awaited).is_ok);
            let awaited_payload = String::from_utf8_lossy(string_bytes((*awaited).value)).into_owned();
            let awaited_json: serde_json::Value =
                serde_json::from_str(&awaited_payload).expect("expected valid awaited heartbeat");
            assert_eq!(awaited_json["completed"].as_bool(), Some(true));
            assert_eq!(awaited_json["exitCode"].as_i64(), Some(0));

            let streamed_stdout = std::fs::read_to_string(&stdout_path).expect("expected handoff stdout");
            assert!(streamed_stdout.contains("handoff-start"));
            assert!(streamed_stdout.contains("handoff-finish"));

            release_header(null_mut(), cwd as *mut ClaspRtHeader);
            release_header(null_mut(), stdout_rt as *mut ClaspRtHeader);
            release_header(null_mut(), stderr_rt as *mut ClaspRtHeader);
            release_header(null_mut(), heartbeat_rt as *mut ClaspRtHeader);
            release_header(null_mut(), ready_rt as *mut ClaspRtHeader);
            release_header(null_mut(), ready_contains_rt as *mut ClaspRtHeader);
            release_header(null_mut(), watch_poll_ms);
            release_header(null_mut(), ready_poll_ms);
            release_header(null_mut(), ready_timeout_ms);
            release_header(null_mut(), command);
            release_header(null_mut(), handed_off as *mut ClaspRtHeader);
            release_header(null_mut(), awaited as *mut ClaspRtHeader);
            let _ = std::fs::remove_file(script_path);
            let _ = std::fs::remove_file(stdout_path);
            let _ = std::fs::remove_file(stderr_path);
            let _ = std::fs::remove_file(heartbeat_path);
            let _ = std::fs::remove_file(ready_path);
            let _ = std::fs::remove_dir_all(temp_root);
        }
    }

    #[test]
    fn upgrade_supervisor_commits_service_identity_and_monitors_exit() {
        let temp_root = std::env::temp_dir().join(format!(
            "clasp-upgrade-supervisor-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&temp_root).expect("expected upgrade temp root");
        let service_root = temp_root.join("service");
        let transaction_root = service_root.join("transactions").join("tx-1");
        std::fs::create_dir_all(&transaction_root).expect("expected transaction root");
        let script_path = temp_root.join("candidate.sh");
        let service_id_capture_path = temp_root.join("candidate.service_id.env");
        let supervised_capture_path = temp_root.join("candidate.supervised.env");
        let ready_path = temp_root.join("ready.txt");
        let snapshot_path = transaction_root.join("snapshot.json");
        let stdout_path = transaction_root.join("candidate.stdout.log");
        let stderr_path = transaction_root.join("candidate.stderr.log");
        let heartbeat_path = transaction_root.join("candidate.heartbeat.json");
        let transaction_path = transaction_root.join("transaction.json");
        let service_path = service_root.join("service.json");
        let lock_path = service_root.join("upgrade.lock");
        let config_path = transaction_root.join("config.json");
        std::fs::write(&snapshot_path, "{\"attempt\":1}").expect("expected snapshot write");
        std::fs::write(
            &script_path,
            format!(
                "#!/bin/sh\nprintf '%s' \"$CLASP_RT_UPGRADE_SERVICE_ID_JSON\" > {}\nprintf '%s' \"$CLASP_RT_SERVICE_SUPERVISED_JSON\" > {}\nsleep 0.05\nprintf ready > {}\nsleep 0.05\nprintf done\\n\n",
                service_id_capture_path.display(),
                supervised_capture_path.display(),
                ready_path.display()
            ),
        )
        .expect("expected upgrade script write");
        let mut permissions = std::fs::metadata(&script_path)
            .expect("expected upgrade script metadata")
            .permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
        std::fs::set_permissions(&script_path, permissions).expect("expected executable upgrade script permissions");

        let config = serde_json::json!({
            "cwd": temp_root.display().to_string(),
            "serviceRoot": service_root.display().to_string(),
            "serviceId": "feedback-loop-service",
            "servicePath": service_path.display().to_string(),
            "lockPath": lock_path.display().to_string(),
            "transactionPath": transaction_path.display().to_string(),
            "snapshotPath": snapshot_path.display().to_string(),
            "stdoutPath": stdout_path.display().to_string(),
            "stderrPath": stderr_path.display().to_string(),
            "heartbeatPath": heartbeat_path.display().to_string(),
            "readyPath": ready_path.display().to_string(),
            "readyContains": "ready",
            "watchPollMs": 50,
            "readyPollMs": 25,
            "readyTimeoutMs": 1000,
            "commitGraceMs": 25,
            "generation": 1,
            "command": [script_path.display().to_string()],
        });
        std::fs::write(&config_path, config.to_string()).expect("expected config write");

        run_upgrade_supervisor_from_config(config_path.to_str().expect("config path text"))
            .expect("expected supervisor run");

        let transaction: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&transaction_path).expect("transaction text"))
                .expect("transaction json");
        let service: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&service_path).expect("service text"))
                .expect("service json");
        let captured_service_id =
            std::fs::read_to_string(&service_id_capture_path).expect("captured service id env");
        let captured_supervised =
            std::fs::read_to_string(&supervised_capture_path).expect("captured supervised env");

        assert_eq!(transaction["phase"].as_str(), Some("completed"));
        assert_eq!(transaction["committed"].as_bool(), Some(true));
        assert_eq!(transaction["exitCode"].as_i64(), Some(0));
        assert_eq!(service["status"].as_str(), Some("completed"));
        assert_eq!(service["generation"].as_i64(), Some(1));
        assert_eq!(captured_service_id, "\"feedback-loop-service\"");
        assert_eq!(captured_supervised, "true");
        assert!(!lock_path.exists(), "expected supervisor to release upgrade lock");

        let _ = std::fs::remove_dir_all(temp_root);
    }

    #[test]
    fn service_supervisor_restarts_failed_candidate_and_finishes_successor() {
        let temp_root = std::env::temp_dir().join(format!(
            "clasp-service-supervisor-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&temp_root).expect("expected service temp root");
        let service_root = temp_root.join("service");
        let service_path = service_root.join("service.json");
        let lock_path = service_root.join("supervisor.lock");
        let config_path = service_root.join("supervisor.config.json");
        let script_path = temp_root.join("service.sh");
        let ready_path = temp_root.join("ready.txt");
        let count_path = temp_root.join("count.txt");
        std::fs::create_dir_all(&service_root).expect("expected service root");

        std::fs::write(
            &script_path,
            format!(
                "#!/bin/sh\ncount=0\nif [ -f {count} ]; then count=$(cat {count}); fi\ncount=$((count + 1))\nprintf '%s' \"$count\" > {count}\nprintf ready > {ready}\nsleep 0.15\nif [ \"$count\" -eq 1 ]; then exit 7; fi\nprintf done\\n\n",
                count = count_path.display(),
                ready = ready_path.display(),
            ),
        )
        .expect("expected service script write");
        let mut permissions = std::fs::metadata(&script_path)
            .expect("expected service script metadata")
            .permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
        std::fs::set_permissions(&script_path, permissions).expect("expected executable service script permissions");

        let config = serde_json::json!({
            "cwd": temp_root.display().to_string(),
            "serviceRoot": service_root.display().to_string(),
            "serviceId": "goal-manager-service",
            "servicePath": service_path.display().to_string(),
            "lockPath": lock_path.display().to_string(),
            "readyPath": ready_path.display().to_string(),
            "readyContains": "ready",
            "watchPollMs": 50,
            "readyPollMs": 25,
            "readyTimeoutMs": 1000,
            "restartDelayMs": 25,
            "command": [script_path.display().to_string()],
        });
        std::fs::write(&config_path, config.to_string()).expect("expected supervisor config write");

        let config_path_text = config_path
            .to_str()
            .expect("expected config path text")
            .to_owned();
        let supervisor = std::thread::spawn(move || {
            run_service_supervisor_from_config(&config_path_text)
                .expect("expected service supervisor run");
        });

        let initial = service_wait_result(service_path.to_str().expect("service path text"), 6000)
            .expect("expected service wait to observe active service");
        let initial_json: serde_json::Value =
            serde_json::from_str(&initial).expect("expected valid initial service json");
        assert_eq!(initial_json["status"].as_str(), Some("active"));

        let started = Instant::now();
        loop {
            let payload = std::fs::read_to_string(&service_path).expect("expected service status");
            let service: serde_json::Value =
                serde_json::from_str(&payload).expect("expected valid service status");
            if service["status"].as_str() == Some("completed") {
                assert_eq!(service["generation"].as_i64(), Some(2));
                break;
            }
            assert!(
                started.elapsed() < Duration::from_secs(5),
                "expected supervisor to complete restarted service"
            );
            std::thread::sleep(Duration::from_millis(25));
        }

        let count = std::fs::read_to_string(&count_path).expect("expected restart counter");
        assert_eq!(count.trim(), "2");
        assert!(!lock_path.exists(), "expected service supervisor lock to be released");
        assert!(config_path.exists(), "expected config to remain for inspection");
        supervisor.join().expect("expected service supervisor thread to join");

        let _ = std::fs::remove_dir_all(temp_root);
    }

    #[test]
    fn service_supervisor_stops_after_domain_final_status_even_when_process_fails() {
        let temp_root = std::env::temp_dir().join(format!(
            "clasp-service-supervisor-domain-final-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&temp_root).expect("expected service temp root");
        let service_root = temp_root.join("service");
        let service_path = service_root.join("service.json");
        let lock_path = service_root.join("supervisor.lock");
        let config_path = service_root.join("supervisor.config.json");
        let script_path = temp_root.join("service.sh");
        let ready_path = temp_root.join("service.ready");
        let final_status_path = temp_root.join("status.json");
        let count_path = temp_root.join("count.txt");
        std::fs::create_dir_all(&service_root).expect("expected service root");

        std::fs::write(
            &script_path,
            format!(
                "#!/bin/sh\ncount=0\nif [ -f {count} ]; then count=$(cat {count}); fi\ncount=$((count + 1))\nprintf '%s' \"$count\" > {count}\nprintf ready > {ready}\nprintf '%s' '{{\"phase\":\"failed\",\"final\":true}}' > {final_status}\nexit 7\n",
                count = count_path.display(),
                ready = ready_path.display(),
                final_status = final_status_path.display(),
            ),
        )
        .expect("expected service script write");
        let mut permissions = std::fs::metadata(&script_path)
            .expect("expected service script metadata")
            .permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
        std::fs::set_permissions(&script_path, permissions).expect("expected executable service script permissions");

        let config = serde_json::json!({
            "cwd": temp_root.display().to_string(),
            "serviceRoot": service_root.display().to_string(),
            "serviceId": "goal-manager-service",
            "servicePath": service_path.display().to_string(),
            "lockPath": lock_path.display().to_string(),
            "finalStatusPath": final_status_path.display().to_string(),
            "readyPath": ready_path.display().to_string(),
            "readyContains": "ready",
            "watchPollMs": 50,
            "readyPollMs": 25,
            "readyTimeoutMs": 1000,
            "restartDelayMs": 25,
            "command": [script_path.display().to_string()],
        });
        std::fs::write(&config_path, config.to_string()).expect("expected supervisor config write");

        run_service_supervisor_from_config(config_path.to_str().expect("config path text"))
            .expect("expected final domain status to stop supervisor");

        let service: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&service_path).expect("service text"))
                .expect("service json");
        let count = std::fs::read_to_string(&count_path).expect("expected restart counter");
        assert_eq!(service["status"].as_str(), Some("completed"));
        assert_eq!(service["generation"].as_i64(), Some(1));
        assert_eq!(service["exitCode"].as_i64(), Some(7));
        assert_eq!(count.trim(), "1");
        assert!(!lock_path.exists(), "expected service supervisor lock to be released");

        let _ = std::fs::remove_dir_all(temp_root);
    }

    #[test]
    fn builtin_runtime_binding_dispatches_file_exists() {
        unsafe {
            let path = build_runtime_string(b"/");
            let args = [path as *mut ClaspRtHeader];

            let builtin_result = interpret_builtin_runtime_binding("fileExists", &args);
            assert_eq!(header_bool_value(builtin_result), Some(true));

            let binding = ClaspRtNativeRuntimeBinding {
                name: "fileExists".to_owned(),
                runtime_name: "fileExists".to_owned(),
                binding_type: "Str -> Bool".to_owned(),
            };
            let binding_result = interpret_runtime_binding(&binding, &args);
            assert_eq!(header_bool_value(binding_result), Some(true));

            release_header(null_mut(), path as *mut ClaspRtHeader);
            release_header(null_mut(), builtin_result);
            release_header(null_mut(), binding_result);
        }
    }

    #[test]
    fn interpreted_decls_shadow_builtin_runtime_names() {
        let image_json = r#"{
            "format": "clasp-native-image-v1",
            "module": "ShadowRuntimeName",
            "exports": ["hostAvailableMemoryMb", "main"],
            "entrypoints": [
                {"name": "hostAvailableMemoryMb", "symbol": "clasp_native__ShadowRuntimeName__hostAvailableMemoryMb", "kind": "function", "arity": 1},
                {"name": "main", "symbol": "clasp_native__ShadowRuntimeName__main", "kind": "global", "arity": 0}
            ],
            "abi": {"recordLayouts": [], "variantLayouts": []},
            "runtime": {"profile": "compiler_backend_minimal", "bindings": [], "boundaries": []},
            "compatibility": {
                "interfaceFingerprint": "native-compat:test",
                "acceptedPreviousFingerprints": [],
                "migration": {
                    "strategy": "exact-interface-only",
                    "stateType": null,
                    "snapshotSymbol": null,
                    "handoffSymbol": null
                }
            },
            "decls": [
                {
                    "kind": "function",
                    "name": "hostAvailableMemoryMb",
                    "params": ["value"],
                    "body": {"kind": "local", "name": "value"}
                },
                {
                    "kind": "global",
                    "name": "main",
                    "body": {
                        "kind": "call",
                        "callee": {"kind": "local", "name": "hostAvailableMemoryMb"},
                        "args": [{"kind": "string", "value": "shadowed"}]
                    }
                }
            ]
        }"#;

        unsafe {
            let image_text = build_runtime_string(image_json.as_bytes());
            let image = clasp_rt_native_module_image_load(image_text as *mut ClaspRtJson);
            assert!(!image.is_null(), "expected native image fixture to load");

            let result = interpret_native_decl(null_mut(), image, "main", &[], 0);
            assert!(!result.is_null(), "expected local declaration to shadow runtime builtin name");
            assert_eq!(
                String::from_utf8_lossy(string_bytes(result as *mut ClaspRtString)),
                "shadowed"
            );

            release_header(null_mut(), result);
            clasp_rt_native_module_image_free(null_mut(), image);
            release_header(null_mut(), image_text as *mut ClaspRtHeader);
        }
    }

    #[test]
    fn interpreted_match_binds_nested_constructor_patterns() {
        let image_json = r#"{
            "format": "clasp-native-image-v1",
            "module": "NestedPatternRuntime",
            "exports": ["nestedPatternSummary", "wildcardPatternSummary"],
            "entrypoints": [
                {"name": "nestedPatternSummary", "symbol": "clasp_native__NestedPatternRuntime__nestedPatternSummary", "kind": "function", "arity": 1},
                {"name": "wildcardPatternSummary", "symbol": "clasp_native__NestedPatternRuntime__wildcardPatternSummary", "kind": "function", "arity": 1}
            ],
            "abi": {"recordLayouts": [], "variantLayouts": []},
            "runtime": {"profile": "compiler_backend_minimal", "bindings": [], "boundaries": []},
            "compatibility": {
                "interfaceFingerprint": "native-compat:test",
                "acceptedPreviousFingerprints": [],
                "migration": {
                    "strategy": "exact-interface-only",
                    "stateType": null,
                    "snapshotSymbol": null,
                    "handoffSymbol": null
                }
            },
            "decls": [
                {
                    "kind": "function",
                    "name": "nestedPatternSummary",
                    "params": ["approval"],
                    "body": {
                        "kind": "match",
                        "scrutinee": {"kind": "local", "name": "approval"},
                        "branches": [
                            {
                                "tag": "SomeApproval",
                                "binders": ["(Accepted name)"],
                                "body": {"kind": "local", "name": "name"}
                            },
                            {
                                "tag": "SomeApproval",
                                "binders": ["(Rejected _)"],
                                "body": {"kind": "string", "value": "rejected"}
                            },
                            {
                                "tag": "SomeApproval",
                                "binders": ["_"],
                                "body": {"kind": "string", "value": "unknown"}
                            },
                            {
                                "tag": "NoApproval",
                                "binders": [],
                                "body": {"kind": "string", "value": "none"}
                            }
                        ]
                    }
                },
                {
                    "kind": "function",
                    "name": "wildcardPatternSummary",
                    "params": ["approval"],
                    "body": {
                        "kind": "match",
                        "scrutinee": {"kind": "local", "name": "approval"},
                        "branches": [
                            {
                                "tag": "_",
                                "binders": [],
                                "body": {"kind": "string", "value": "any"}
                            }
                        ]
                    }
                }
            ]
        }"#;

        unsafe {
            let image_text = build_runtime_string(image_json.as_bytes());
            let image = clasp_rt_native_module_image_load(image_text as *mut ClaspRtJson);
            assert!(!image.is_null(), "expected native image fixture to load");

            let accepted_name = build_runtime_string(b"Ada") as *mut ClaspRtHeader;
            let accepted = clasp_rt_build_variant_header("Accepted", vec![accepted_name]);
            let accepted_approval = clasp_rt_build_variant_header("SomeApproval", vec![accepted]);
            let accepted_result =
                interpret_native_decl(null_mut(), image, "nestedPatternSummary", &[accepted_approval], 0);
            assert!(!accepted_result.is_null(), "expected nested binder to produce a value");
            assert_eq!(
                String::from_utf8_lossy(string_bytes(accepted_result as *mut ClaspRtString)),
                "Ada"
            );

            let rejected_reason = build_runtime_string(b"blocked") as *mut ClaspRtHeader;
            let rejected = clasp_rt_build_variant_header("Rejected", vec![rejected_reason]);
            let rejected_approval = clasp_rt_build_variant_header("SomeApproval", vec![rejected]);
            let rejected_result =
                interpret_native_decl(null_mut(), image, "nestedPatternSummary", &[rejected_approval], 0);
            assert!(!rejected_result.is_null(), "expected rejected branch to produce a value");
            assert_eq!(
                String::from_utf8_lossy(string_bytes(rejected_result as *mut ClaspRtString)),
                "rejected"
            );

            let pending = clasp_rt_build_variant_header("Pending", Vec::new());
            let pending_approval = clasp_rt_build_variant_header("SomeApproval", vec![pending]);
            let pending_result =
                interpret_native_decl(null_mut(), image, "nestedPatternSummary", &[pending_approval], 0);
            assert!(!pending_result.is_null(), "expected constructor fallback to produce a value");
            assert_eq!(
                String::from_utf8_lossy(string_bytes(pending_result as *mut ClaspRtString)),
                "unknown"
            );

            let no_approval = clasp_rt_build_variant_header("NoApproval", Vec::new());
            let wildcard_result =
                interpret_native_decl(null_mut(), image, "wildcardPatternSummary", &[no_approval], 0);
            assert!(!wildcard_result.is_null(), "expected top-level wildcard to produce a value");
            assert_eq!(
                String::from_utf8_lossy(string_bytes(wildcard_result as *mut ClaspRtString)),
                "any"
            );

            release_header(null_mut(), accepted_approval);
            release_header(null_mut(), rejected_approval);
            release_header(null_mut(), rejected_result);
            release_header(null_mut(), pending_approval);
            release_header(null_mut(), pending_result);
            release_header(null_mut(), no_approval);
            release_header(null_mut(), wildcard_result);
            clasp_rt_native_module_image_free(null_mut(), image);
            release_header(null_mut(), image_text as *mut ClaspRtHeader);
        }
    }

    #[test]
    fn builtin_runtime_binding_lists_directory_entries() {
        let temp_root = env::temp_dir().join(format!("clasp-list-dir-{}", unique_test_suffix()));
        fs::create_dir_all(&temp_root).expect("expected temp listDir root");
        fs::write(temp_root.join("beta.txt"), "beta").expect("expected beta fixture write");
        fs::write(temp_root.join("alpha.txt"), "alpha").expect("expected alpha fixture write");

        unsafe {
            let path = build_runtime_string(temp_root.to_string_lossy().as_bytes());
            let args = [path as *mut ClaspRtHeader];

            let result = interpret_builtin_runtime_binding("listDir", &args);
            assert_eq!(variant_tag_text(result), Some("Ok".to_owned()));

            let result_items = variant_items(result as *mut ClaspRtVariantValue);
            assert_eq!(result_items.len(), 1);
            let names = list_value_items(result_items[0] as *mut ClaspRtListValue);
            assert_eq!(names.len(), 2);
            assert_eq!(
                String::from_utf8_lossy(string_bytes(names[0] as *mut ClaspRtString)),
                "alpha.txt"
            );
            assert_eq!(
                String::from_utf8_lossy(string_bytes(names[1] as *mut ClaspRtString)),
                "beta.txt"
            );

            let binding = ClaspRtNativeRuntimeBinding {
                name: "listDirRaw".to_owned(),
                runtime_name: "listDir".to_owned(),
                binding_type: "Str -> Result [Str]".to_owned(),
            };
            let binding_result = interpret_runtime_binding(&binding, &args);
            assert_eq!(variant_tag_text(binding_result), Some("Ok".to_owned()));

            release_header(null_mut(), path as *mut ClaspRtHeader);
            release_header(null_mut(), result);
            release_header(null_mut(), binding_result);
        }

        let _ = fs::remove_dir_all(temp_root);
    }

    #[test]
    fn list_dir_reports_missing_paths_as_result_error() {
        let missing_path =
            env::temp_dir().join(format!("clasp-list-dir-missing-{}", unique_test_suffix()));

        unsafe {
            let path = build_runtime_string(missing_path.to_string_lossy().as_bytes());
            let result = clasp_rt_list_dir(path);

            assert_eq!(variant_tag_text(result), Some("Err".to_owned()));
            let result_items = variant_items(result as *mut ClaspRtVariantValue);
            assert_eq!(result_items.len(), 1);
            assert_eq!(
                String::from_utf8_lossy(string_bytes(result_items[0] as *mut ClaspRtString)),
                "missing"
            );

            release_header(null_mut(), path as *mut ClaspRtHeader);
            release_header(null_mut(), result);
        }
    }

    #[test]
    fn host_available_disk_mb_reports_free_space() {
        unsafe {
            let path = build_runtime_string(b"/");
            let args = [path as *mut ClaspRtHeader];

            let result = interpret_builtin_runtime_binding("hostAvailableDiskMb", &args);
            assert_eq!(variant_tag_text(result), Some("Ok".to_owned()));

            let result_items = variant_items(result as *mut ClaspRtVariantValue);
            assert_eq!(result_items.len(), 1);
            assert_eq!((*result_items[0].cast::<ClaspRtInt>()).value > 0, true);

            let binding = ClaspRtNativeRuntimeBinding {
                name: "hostAvailableDiskMb".to_owned(),
                runtime_name: "hostAvailableDiskMb".to_owned(),
                binding_type: "Str -> Result Int".to_owned(),
            };
            let binding_result = interpret_runtime_binding(&binding, &args);
            assert_eq!(variant_tag_text(binding_result), Some("Ok".to_owned()));

            release_header(null_mut(), path as *mut ClaspRtHeader);
            release_header(null_mut(), result);
            release_header(null_mut(), binding_result);
        }
    }

    #[test]
    fn host_file_size_mb_reports_regular_file_size_and_rejects_missing_paths() {
        let temp_root = env::temp_dir().join(format!("clasp-host-file-size-{}", unique_test_suffix()));
        fs::create_dir_all(&temp_root).expect("expected temp root");
        let file_path = temp_root.join("sample.log");
        fs::write(&file_path, vec![b'x'; 1_048_577]).expect("expected test file");

        unsafe {
            let path = build_runtime_string(file_path.to_string_lossy().as_bytes());
            let args = [path as *mut ClaspRtHeader];

            let result = interpret_builtin_runtime_binding("hostFileSizeMb", &args);
            assert_eq!(variant_tag_text(result), Some("Ok".to_owned()));
            let result_items = variant_items(result as *mut ClaspRtVariantValue);
            assert_eq!(result_items.len(), 1);
            assert_eq!((*result_items[0].cast::<ClaspRtInt>()).value, 2);

            let binding = ClaspRtNativeRuntimeBinding {
                name: "hostFileSizeMb".to_owned(),
                runtime_name: "hostFileSizeMb".to_owned(),
                binding_type: "Str -> Result Int".to_owned(),
            };
            let binding_result = interpret_runtime_binding(&binding, &args);
            assert_eq!(variant_tag_text(binding_result), Some("Ok".to_owned()));

            let missing_path = temp_root.join("missing.log");
            let missing = build_runtime_string(missing_path.to_string_lossy().as_bytes());
            let missing_args = [missing as *mut ClaspRtHeader];
            let missing_result = interpret_builtin_runtime_binding("hostFileSizeMb", &missing_args);
            assert_eq!(variant_tag_text(missing_result), Some("Err".to_owned()));

            release_header(null_mut(), path as *mut ClaspRtHeader);
            release_header(null_mut(), result);
            release_header(null_mut(), binding_result);
            release_header(null_mut(), missing as *mut ClaspRtHeader);
            release_header(null_mut(), missing_result);
        }

        let _ = fs::remove_dir_all(temp_root);
    }

    #[test]
    fn host_cap_file_tail_mb_keeps_tail_and_preserves_regular_file() {
        let temp_root = env::temp_dir().join(format!("clasp-host-tail-cap-{}", unique_test_suffix()));
        fs::create_dir_all(&temp_root).expect("expected temp root");
        let file_path = temp_root.join("sample.log");
        let mut contents = Vec::new();
        contents.extend(vec![b'a'; 1_048_576]);
        contents.extend(vec![b'b'; 1_048_576]);
        fs::write(&file_path, contents).expect("expected test file");

        unsafe {
            let path = build_runtime_string(file_path.to_string_lossy().as_bytes());
            let max_mb = build_runtime_int(1);
            let args = [path as *mut ClaspRtHeader, max_mb as *mut ClaspRtHeader];

            let result = interpret_builtin_runtime_binding("hostCapFileTailMb", &args);
            assert_eq!(variant_tag_text(result), Some("Ok".to_owned()));
            let result_items = variant_items(result as *mut ClaspRtVariantValue);
            assert_eq!(result_items.len(), 1);
            assert_eq!((*result_items[0].cast::<ClaspRtInt>()).value, 1);

            let capped = fs::read(&file_path).expect("expected capped file");
            assert_eq!(capped.len(), 1_048_576);
            assert!(capped.iter().all(|byte| *byte == b'b'));

            let binding = ClaspRtNativeRuntimeBinding {
                name: "hostCapFileTailMb".to_owned(),
                runtime_name: "hostCapFileTailMb".to_owned(),
                binding_type: "Str -> Int -> Result Int".to_owned(),
            };
            let binding_result = interpret_runtime_binding(&binding, &args);
            assert_eq!(variant_tag_text(binding_result), Some("Ok".to_owned()));

            release_header(null_mut(), path as *mut ClaspRtHeader);
            release_header(null_mut(), max_mb as *mut ClaspRtHeader);
            release_header(null_mut(), result);
            release_header(null_mut(), binding_result);
        }

        let _ = fs::remove_dir_all(temp_root);
    }

    #[test]
    fn host_available_memory_mb_reports_free_memory() {
        unsafe {
            let args: [*mut ClaspRtHeader; 0] = [];

            let result = interpret_builtin_runtime_binding("hostAvailableMemoryMb", &args);
            assert_eq!(variant_tag_text(result), Some("Ok".to_owned()));

            let result_items = variant_items(result as *mut ClaspRtVariantValue);
            assert_eq!(result_items.len(), 1);
            assert_eq!((*result_items[0].cast::<ClaspRtInt>()).value > 0, true);

            let binding = ClaspRtNativeRuntimeBinding {
                name: "hostAvailableMemoryMb".to_owned(),
                runtime_name: "hostAvailableMemoryMb".to_owned(),
                binding_type: "Result Int".to_owned(),
            };
            let binding_result = interpret_runtime_binding(&binding, &args);
            assert_eq!(variant_tag_text(binding_result), Some("Ok".to_owned()));

            release_header(null_mut(), result);
            release_header(null_mut(), binding_result);
        }
    }

    #[test]
    fn host_process_alive_reports_live_process_and_rejects_invalid_pid() {
        unsafe {
            let pid_text = std::process::id().to_string();
            let pid = build_runtime_string(pid_text.as_bytes());
            let args = [pid as *mut ClaspRtHeader];

            let result = interpret_builtin_runtime_binding("hostProcessAlive", &args);
            assert_eq!(variant_tag_text(result), Some("Ok".to_owned()));
            let result_items = variant_items(result as *mut ClaspRtVariantValue);
            assert_eq!(result_items.len(), 1);
            assert_eq!(header_bool_value(result_items[0]), Some(true));

            let binding = ClaspRtNativeRuntimeBinding {
                name: "hostProcessAlive".to_owned(),
                runtime_name: "hostProcessAlive".to_owned(),
                binding_type: "Str -> Result Bool".to_owned(),
            };
            let binding_result = interpret_runtime_binding(&binding, &args);
            assert_eq!(variant_tag_text(binding_result), Some("Ok".to_owned()));

            let invalid_pid = build_runtime_string(b"not-a-pid");
            let invalid_args = [invalid_pid as *mut ClaspRtHeader];
            let invalid_result = interpret_builtin_runtime_binding("hostProcessAlive", &invalid_args);
            assert_eq!(variant_tag_text(invalid_result), Some("Err".to_owned()));

            release_header(null_mut(), pid as *mut ClaspRtHeader);
            release_header(null_mut(), result);
            release_header(null_mut(), binding_result);
            release_header(null_mut(), invalid_pid as *mut ClaspRtHeader);
            release_header(null_mut(), invalid_result);
        }
    }

    #[test]
    fn host_process_count_by_name_reports_current_process() {
        unsafe {
            let current_name = fs::read_to_string("/proc/self/comm")
                .unwrap_or_else(|_| "unknown-process-name".to_owned());
            let names = build_string_list(&[current_name.trim().as_bytes()]);
            let args = [names];

            let result = interpret_builtin_runtime_binding("hostProcessCountByName", &args);
            assert_eq!(variant_tag_text(result), Some("Ok".to_owned()));
            let result_items = variant_items(result as *mut ClaspRtVariantValue);
            assert_eq!(result_items.len(), 1);
            assert_eq!((*result_items[0].cast::<ClaspRtInt>()).value > 0, true);

            let binding = ClaspRtNativeRuntimeBinding {
                name: "hostProcessCountByName".to_owned(),
                runtime_name: "hostProcessCountByName".to_owned(),
                binding_type: "[Str] -> Result Int".to_owned(),
            };
            let binding_result = interpret_runtime_binding(&binding, &args);
            assert_eq!(variant_tag_text(binding_result), Some("Ok".to_owned()));

            let unmanaged_result =
                interpret_builtin_runtime_binding("hostUnmanagedProcessCountByName", &args);
            assert_eq!(variant_tag_text(unmanaged_result), Some("Ok".to_owned()));

            let unmanaged_rss_result =
                interpret_builtin_runtime_binding("hostUnmanagedProcessRssMbByName", &args);
            assert_eq!(variant_tag_text(unmanaged_rss_result), Some("Ok".to_owned()));
            let unmanaged_rss_items = variant_items(unmanaged_rss_result as *mut ClaspRtVariantValue);
            assert_eq!(unmanaged_rss_items.len(), 1);
            assert!(
                (*unmanaged_rss_items[0].cast::<ClaspRtInt>()).value > 0,
                "expected positive unmanaged RSS for current process"
            );

            release_header(null_mut(), names);
            release_header(null_mut(), result);
            release_header(null_mut(), binding_result);
            release_header(null_mut(), unmanaged_result);
            release_header(null_mut(), unmanaged_rss_result);
        }
    }

    #[test]
    fn workspace_file_api_reads_writes_lists_and_rejects_escapes() {
        let temp_parent = env::temp_dir().join(format!("clasp-workspace-api-{}", unique_test_suffix()));
        let workspace_root = temp_parent.join("workspace");
        let outside_path = temp_parent.join("outside.txt");
        fs::create_dir_all(&workspace_root).expect("expected workspace root");
        fs::write(&outside_path, "outside-secret").expect("expected outside fixture");

        unsafe {
            let root_text = workspace_root.to_string_lossy().into_owned();
            let outside_text = outside_path.to_string_lossy().into_owned();
            let root = build_runtime_string(root_text.as_bytes());
            let nested_path = build_runtime_string(b"nested/result.txt");
            let nested_dir = build_runtime_string(b"nested");
            let append_path = build_runtime_string(b"logs/events.jsonl");
            let remove_file_path = build_runtime_string(b"removable/file.txt");
            let remove_dir_path = build_runtime_string(b"removable");
            let remove_contents = build_runtime_string(b"remove-me");
            let first_event = build_runtime_string(b"event-one\n");
            let second_event = build_runtime_string(b"event-two\n");
            let contents = build_runtime_string(b"workspace-text");

            let write_result = clasp_rt_workspace_write_file(root, nested_path, contents);
            assert!((*write_result).is_ok, "expected workspace write to succeed");
            assert!(
                result_string_text(write_result).ends_with("nested/result.txt"),
                "expected normalized write path"
            );

            let read_result = clasp_rt_workspace_read_file(root, nested_path);
            assert!((*read_result).is_ok, "expected workspace read to succeed");
            assert_eq!(result_string_text(read_result), "workspace-text");

            let first_append = clasp_rt_workspace_append_file(root, append_path, first_event);
            assert!((*first_append).is_ok, "expected first workspace append to succeed");
            let second_append = clasp_rt_workspace_append_file(root, append_path, second_event);
            assert!((*second_append).is_ok, "expected second workspace append to succeed");
            let appended_read = clasp_rt_workspace_read_file(root, append_path);
            assert!((*appended_read).is_ok, "expected appended log to be readable");
            assert_eq!(result_string_text(appended_read), "event-one\nevent-two\n");

            let binding = ClaspRtNativeRuntimeBinding {
                name: "workspaceAppendText".to_owned(),
                runtime_name: "workspaceAppendFile".to_owned(),
                binding_type: "Str -> Str -> Str -> Result Str".to_owned(),
            };
            let third_event = build_runtime_string(b"event-three\n");
            let binding_result = interpret_runtime_binding(
                &binding,
                &[root as *mut ClaspRtHeader, append_path as *mut ClaspRtHeader, third_event as *mut ClaspRtHeader],
            );
            assert!(!binding_result.is_null(), "expected workspace append runtime binding");
            assert_eq!((*binding_result).layout_id, CLASP_RT_LAYOUT_RESULT_STRING);
            assert!((*(binding_result as *mut ClaspRtResultString)).is_ok);
            let appended_again = clasp_rt_workspace_read_file(root, append_path);
            assert_eq!(result_string_text(appended_again), "event-one\nevent-two\nevent-three\n");

            let list_result = clasp_rt_workspace_list_dir(root, nested_dir);
            assert_eq!(variant_tag_text(list_result), Some("Ok".to_owned()));
            let list_items = variant_items(list_result as *mut ClaspRtVariantValue);
            let names = list_value_items(list_items[0] as *mut ClaspRtListValue);
            assert_eq!(names.len(), 1);
            assert_eq!(
                String::from_utf8_lossy(string_bytes(names[0] as *mut ClaspRtString)),
                "result.txt"
            );

            let max_entries = build_runtime_int(64);
            let max_depth = build_runtime_int(4);
            let tree_root = build_runtime_string(b".");
            let tree_result = clasp_rt_workspace_list_tree(
                root,
                tree_root,
                max_entries as *mut ClaspRtHeader,
                max_depth as *mut ClaspRtHeader,
            );
            assert_eq!(variant_tag_text(tree_result), Some("Ok".to_owned()));
            let tree_items = variant_items(tree_result as *mut ClaspRtVariantValue);
            let tree_paths = list_value_items(tree_items[0] as *mut ClaspRtListValue);
            let rendered_tree_paths: Vec<String> = tree_paths
                .iter()
                .map(|item| String::from_utf8_lossy(string_bytes(*item as *mut ClaspRtString)).into_owned())
                .collect();
            assert!(
                rendered_tree_paths.iter().any(|path| path == "logs/"),
                "expected recursive tree to include directories"
            );
            assert!(
                rendered_tree_paths.iter().any(|path| path == "logs/events.jsonl"),
                "expected recursive tree to include nested files"
            );
            assert!(
                rendered_tree_paths.iter().any(|path| path == "nested/result.txt"),
                "expected recursive tree to include written files"
            );

            let limit_one = build_runtime_int(1);
            let limited_tree = clasp_rt_workspace_list_tree(
                root,
                tree_root,
                limit_one as *mut ClaspRtHeader,
                max_depth as *mut ClaspRtHeader,
            );
            assert_eq!(variant_tag_text(limited_tree), Some("Err".to_owned()));
            let limited_items = variant_items(limited_tree as *mut ClaspRtVariantValue);
            assert!(
                String::from_utf8_lossy(string_bytes(limited_items[0] as *mut ClaspRtString))
                    .contains("workspace_limit_exceeded"),
                "expected bounded recursive tree listing to fail closed"
            );

            let search_needle = build_runtime_string(b"workspace-text");
            let max_matches = build_runtime_int(8);
            let max_files = build_runtime_int(64);
            let max_file_bytes = build_runtime_int(1024);
            let search_result = clasp_rt_workspace_search_text(
                root,
                tree_root,
                search_needle,
                max_matches as *mut ClaspRtHeader,
                max_files as *mut ClaspRtHeader,
                max_file_bytes as *mut ClaspRtHeader,
                max_depth as *mut ClaspRtHeader,
            );
            assert_eq!(variant_tag_text(search_result), Some("Ok".to_owned()));
            let search_items = variant_items(search_result as *mut ClaspRtVariantValue);
            let search_paths = list_value_items(search_items[0] as *mut ClaspRtListValue);
            let rendered_search_paths: Vec<String> = search_paths
                .iter()
                .map(|item| String::from_utf8_lossy(string_bytes(*item as *mut ClaspRtString)).into_owned())
                .collect();
            assert!(
                rendered_search_paths
                    .iter()
                    .any(|line| line == "nested/result.txt:1:workspace-text"),
                "expected workspace text search to include file, line, and snippet"
            );

            let replace_value = build_runtime_string(b"workspace-updated");
            let replace_limit = build_runtime_int(2);
            let replace_result = clasp_rt_workspace_replace_text(
                root,
                nested_path,
                search_needle,
                replace_value,
                replace_limit as *mut ClaspRtHeader,
                max_file_bytes as *mut ClaspRtHeader,
            );
            assert_eq!(variant_tag_text(replace_result), Some("Ok".to_owned()));
            let replace_items = variant_items(replace_result as *mut ClaspRtVariantValue);
            assert_eq!(header_int_value(replace_items[0]), Some(1));
            let replaced_read = clasp_rt_workspace_read_file(root, nested_path);
            assert!((*replaced_read).is_ok, "expected replaced file to be readable");
            assert_eq!(result_string_text(replaced_read), "workspace-updated");

            let missing_find = build_runtime_string(b"workspace-text");
            let missing_replace = clasp_rt_workspace_replace_text(
                root,
                nested_path,
                missing_find,
                replace_value,
                replace_limit as *mut ClaspRtHeader,
                max_file_bytes as *mut ClaspRtHeader,
            );
            assert_eq!(variant_tag_text(missing_replace), Some("Err".to_owned()));
            let missing_replace_items = variant_items(missing_replace as *mut ClaspRtVariantValue);
            assert!(
                String::from_utf8_lossy(string_bytes(missing_replace_items[0] as *mut ClaspRtString))
                    .contains("workspace_replace_missing"),
                "expected missing replacement target to fail closed"
            );

            let empty_find = build_runtime_string(b"");
            let empty_replace = clasp_rt_workspace_replace_text(
                root,
                nested_path,
                empty_find,
                replace_value,
                replace_limit as *mut ClaspRtHeader,
                max_file_bytes as *mut ClaspRtHeader,
            );
            assert_eq!(variant_tag_text(empty_replace), Some("Err".to_owned()));
            let empty_replace_items = variant_items(empty_replace as *mut ClaspRtVariantValue);
            assert!(
                String::from_utf8_lossy(string_bytes(empty_replace_items[0] as *mut ClaspRtString))
                    .contains("workspace_invalid_replace"),
                "expected empty replacement target to fail closed"
            );

            let repeat_path = build_runtime_string(b"nested/repeat.txt");
            let repeat_contents = build_runtime_string(b"repeat repeat");
            let repeat_write = clasp_rt_workspace_write_file(root, repeat_path, repeat_contents);
            assert!((*repeat_write).is_ok, "expected repeat fixture write to succeed");
            let repeat_find = build_runtime_string(b"repeat");
            let repeat_value = build_runtime_string(b"done");
            let repeat_replace = clasp_rt_workspace_replace_text(
                root,
                repeat_path,
                repeat_find,
                repeat_value,
                limit_one as *mut ClaspRtHeader,
                max_file_bytes as *mut ClaspRtHeader,
            );
            assert_eq!(variant_tag_text(repeat_replace), Some("Err".to_owned()));
            let repeat_replace_items = variant_items(repeat_replace as *mut ClaspRtVariantValue);
            assert!(
                String::from_utf8_lossy(string_bytes(repeat_replace_items[0] as *mut ClaspRtString))
                    .contains("workspace_limit_exceeded"),
                "expected replacement count limit to fail closed"
            );
            let repeat_read = clasp_rt_workspace_read_file(root, repeat_path);
            assert_eq!(result_string_text(repeat_read), "repeat repeat");

            let zero_matches = build_runtime_int(0);
            let limited_search = clasp_rt_workspace_search_text(
                root,
                tree_root,
                search_needle,
                zero_matches as *mut ClaspRtHeader,
                max_files as *mut ClaspRtHeader,
                max_file_bytes as *mut ClaspRtHeader,
                max_depth as *mut ClaspRtHeader,
            );
            assert_eq!(variant_tag_text(limited_search), Some("Err".to_owned()));
            let limited_search_items = variant_items(limited_search as *mut ClaspRtVariantValue);
            assert!(
                String::from_utf8_lossy(string_bytes(limited_search_items[0] as *mut ClaspRtString))
                    .contains("workspace_invalid_limit"),
                "expected invalid search limit to fail closed"
            );

            let removable_write = clasp_rt_workspace_write_file(root, remove_file_path, remove_contents);
            assert!((*removable_write).is_ok, "expected removable fixture write to succeed");
            let remove_file_result = clasp_rt_workspace_remove_path(root, remove_file_path);
            assert!((*remove_file_result).is_ok, "expected workspace file removal to succeed");
            assert!(
                !workspace_root.join("removable").join("file.txt").exists(),
                "expected workspace file removal to delete the file"
            );
            let remove_dir_result = clasp_rt_workspace_remove_path(root, remove_dir_path);
            assert!((*remove_dir_result).is_ok, "expected workspace directory removal to succeed");
            assert!(
                !workspace_root.join("removable").exists(),
                "expected workspace directory removal to delete the directory"
            );

            let parent_escape = build_runtime_string(b"../outside.txt");
            let escape_result = clasp_rt_workspace_write_file(root, parent_escape, contents);
            assert!(!(*escape_result).is_ok, "expected parent escape to fail");
            assert!(
                result_string_text(escape_result).contains("workspace_path_escape"),
                "expected actionable escape error"
            );

            let absolute_escape = build_runtime_string(outside_text.as_bytes());
            let absolute_result = clasp_rt_workspace_read_file(root, absolute_escape);
            assert!(!(*absolute_result).is_ok, "expected absolute path to fail");
            assert!(
                result_string_text(absolute_result).contains("absolute paths are not allowed"),
                "expected actionable absolute-path error"
            );

            release_header(null_mut(), root as *mut ClaspRtHeader);
            release_header(null_mut(), nested_path as *mut ClaspRtHeader);
            release_header(null_mut(), nested_dir as *mut ClaspRtHeader);
            release_header(null_mut(), append_path as *mut ClaspRtHeader);
            release_header(null_mut(), remove_file_path as *mut ClaspRtHeader);
            release_header(null_mut(), remove_dir_path as *mut ClaspRtHeader);
            release_header(null_mut(), remove_contents as *mut ClaspRtHeader);
            release_header(null_mut(), first_event as *mut ClaspRtHeader);
            release_header(null_mut(), second_event as *mut ClaspRtHeader);
            release_header(null_mut(), third_event as *mut ClaspRtHeader);
            release_header(null_mut(), contents as *mut ClaspRtHeader);
            release_header(null_mut(), write_result as *mut ClaspRtHeader);
            release_header(null_mut(), read_result as *mut ClaspRtHeader);
            release_header(null_mut(), first_append as *mut ClaspRtHeader);
            release_header(null_mut(), second_append as *mut ClaspRtHeader);
            release_header(null_mut(), appended_read as *mut ClaspRtHeader);
            release_header(null_mut(), binding_result);
            release_header(null_mut(), appended_again as *mut ClaspRtHeader);
            release_header(null_mut(), list_result);
            release_header(null_mut(), max_entries as *mut ClaspRtHeader);
            release_header(null_mut(), max_depth as *mut ClaspRtHeader);
            release_header(null_mut(), tree_root as *mut ClaspRtHeader);
            release_header(null_mut(), tree_result);
            release_header(null_mut(), limit_one as *mut ClaspRtHeader);
            release_header(null_mut(), limited_tree);
            release_header(null_mut(), search_needle as *mut ClaspRtHeader);
            release_header(null_mut(), max_matches as *mut ClaspRtHeader);
            release_header(null_mut(), max_files as *mut ClaspRtHeader);
            release_header(null_mut(), max_file_bytes as *mut ClaspRtHeader);
            release_header(null_mut(), search_result);
            release_header(null_mut(), replace_value as *mut ClaspRtHeader);
            release_header(null_mut(), replace_limit as *mut ClaspRtHeader);
            release_header(null_mut(), replace_result);
            release_header(null_mut(), replaced_read as *mut ClaspRtHeader);
            release_header(null_mut(), missing_find as *mut ClaspRtHeader);
            release_header(null_mut(), missing_replace);
            release_header(null_mut(), empty_find as *mut ClaspRtHeader);
            release_header(null_mut(), empty_replace);
            release_header(null_mut(), repeat_path as *mut ClaspRtHeader);
            release_header(null_mut(), repeat_contents as *mut ClaspRtHeader);
            release_header(null_mut(), repeat_write as *mut ClaspRtHeader);
            release_header(null_mut(), repeat_find as *mut ClaspRtHeader);
            release_header(null_mut(), repeat_value as *mut ClaspRtHeader);
            release_header(null_mut(), repeat_replace);
            release_header(null_mut(), repeat_read as *mut ClaspRtHeader);
            release_header(null_mut(), zero_matches as *mut ClaspRtHeader);
            release_header(null_mut(), limited_search);
            release_header(null_mut(), removable_write as *mut ClaspRtHeader);
            release_header(null_mut(), remove_file_result as *mut ClaspRtHeader);
            release_header(null_mut(), remove_dir_result as *mut ClaspRtHeader);
            release_header(null_mut(), parent_escape as *mut ClaspRtHeader);
            release_header(null_mut(), escape_result as *mut ClaspRtHeader);
            release_header(null_mut(), absolute_escape as *mut ClaspRtHeader);
            release_header(null_mut(), absolute_result as *mut ClaspRtHeader);
        }

        assert_eq!(
            fs::read_to_string(&outside_path).expect("expected outside file"),
            "outside-secret"
        );
        let _ = fs::remove_dir_all(temp_parent);
    }

    #[cfg(unix)]
    #[test]
    fn workspace_file_api_rejects_symlink_escape() {
        use std::os::unix::fs::symlink;

        let temp_parent = env::temp_dir().join(format!("clasp-workspace-symlink-{}", unique_test_suffix()));
        let workspace_root = temp_parent.join("workspace");
        let outside_path = temp_parent.join("outside.txt");
        fs::create_dir_all(&workspace_root).expect("expected workspace root");
        fs::write(&outside_path, "outside-secret").expect("expected outside fixture");
        symlink(&outside_path, workspace_root.join("outside-link")).expect("expected symlink fixture");

        unsafe {
            let root_text = workspace_root.to_string_lossy().into_owned();
            let root = build_runtime_string(root_text.as_bytes());
            let link_path = build_runtime_string(b"outside-link");

            let result = clasp_rt_workspace_read_file(root, link_path);
            assert!(!(*result).is_ok, "expected symlink escape to fail");
            assert!(
                result_string_text(result).contains("workspace_path_escape"),
                "expected symlink escape diagnostic"
            );

            release_header(null_mut(), root as *mut ClaspRtHeader);
            release_header(null_mut(), link_path as *mut ClaspRtHeader);
            release_header(null_mut(), result as *mut ClaspRtHeader);
        }

        let _ = fs::remove_dir_all(temp_parent);
    }

    #[test]
    fn builtin_not_negates_booleans() {
        unsafe {
            let value = build_runtime_bool(true) as *mut ClaspRtHeader;
            let result = interpret_builtin_runtime_binding("not", &[value]);

            assert_eq!(header_bool_value(result), Some(false));

            release_header(null_mut(), value);
            release_header(null_mut(), result);
        }
    }

    #[test]
    fn env_var_virtualizes_current_executable_path_when_unset() {
        let original = std::env::var("CLASP_RT_CURRENT_EXECUTABLE_PATH_JSON").ok();
        std::env::remove_var("CLASP_RT_CURRENT_EXECUTABLE_PATH_JSON");

        unsafe {
            let name = build_runtime_string(b"CLASP_RT_CURRENT_EXECUTABLE_PATH_JSON");
            let result = clasp_rt_env_var(name);
            assert!((*result).is_ok);
            let payload = String::from_utf8_lossy(string_bytes((*result).value)).into_owned();
            let decoded: String = serde_json::from_str(&payload).expect("expected json string payload");
            let expected = std::env::current_exe()
                .expect("expected current test binary path")
                .to_string_lossy()
                .into_owned();
            assert_eq!(decoded, expected);

            release_header(null_mut(), name as *mut ClaspRtHeader);
            release_header(null_mut(), result as *mut ClaspRtHeader);
        }

        match original {
            Some(value) => std::env::set_var("CLASP_RT_CURRENT_EXECUTABLE_PATH_JSON", value),
            None => std::env::remove_var("CLASP_RT_CURRENT_EXECUTABLE_PATH_JSON"),
        }
    }
}
