use std::alloc::{alloc_zeroed, dealloc, handle_alloc_error, Layout};
use std::collections::HashMap;
use std::env;
use std::ffi::{c_char, CStr};
use std::fs::File;
use std::io::Read;
use std::mem::{align_of, size_of};
use std::ptr::{self, null_mut, NonNull};
use std::slice;

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
    Encode(Box<ClaspRtInterpretedExpr>),
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
        unsafe { (*image).entrypoints[export_index] = entrypoint };
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
        let symbol = unsafe { (*image).entrypoint_symbols[export_index] };
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
        unsafe { (*image).entrypoints[export_index] = entrypoint };
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
        unsafe { (*image).entrypoints[export_index] }
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
        unsafe { (*image).entrypoints[export_index] }
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

unsafe fn compare_runtime_values(
    op: ClaspRtInterpretedCompareOp,
    left: *mut ClaspRtHeader,
    right: *mut ClaspRtHeader,
) -> Option<bool> {
    if left.is_null() || right.is_null() {
        return None;
    }

    if (*left).layout_id == CLASP_RT_LAYOUT_STRING && (*right).layout_id == CLASP_RT_LAYOUT_STRING {
        let ordering = string_bytes(left as *mut ClaspRtString).cmp(string_bytes(right as *mut ClaspRtString));
        return Some(match op {
            ClaspRtInterpretedCompareOp::Eq => ordering.is_eq(),
            ClaspRtInterpretedCompareOp::Ne => !ordering.is_eq(),
            ClaspRtInterpretedCompareOp::Lt => ordering.is_lt(),
            ClaspRtInterpretedCompareOp::Le => ordering.is_le(),
            ClaspRtInterpretedCompareOp::Gt => ordering.is_gt(),
            ClaspRtInterpretedCompareOp::Ge => ordering.is_ge(),
        });
    }

    if let (Some(left_value), Some(right_value)) = (header_int_value(left), header_int_value(right)) {
        return Some(match op {
            ClaspRtInterpretedCompareOp::Eq => left_value == right_value,
            ClaspRtInterpretedCompareOp::Ne => left_value != right_value,
            ClaspRtInterpretedCompareOp::Lt => left_value < right_value,
            ClaspRtInterpretedCompareOp::Le => left_value <= right_value,
            ClaspRtInterpretedCompareOp::Gt => left_value > right_value,
            ClaspRtInterpretedCompareOp::Ge => left_value >= right_value,
        });
    }

    if let (Some(left_value), Some(right_value)) = (header_bool_value(left), header_bool_value(right)) {
        return Some(match op {
            ClaspRtInterpretedCompareOp::Eq => left_value == right_value,
            ClaspRtInterpretedCompareOp::Ne => left_value != right_value,
            ClaspRtInterpretedCompareOp::Lt => (!left_value) && right_value,
            ClaspRtInterpretedCompareOp::Le => left_value == right_value || ((!left_value) && right_value),
            ClaspRtInterpretedCompareOp::Gt => left_value && (!right_value),
            ClaspRtInterpretedCompareOp::Ge => left_value == right_value || (left_value && (!right_value)),
        });
    }

    None
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

            let result = if let Some(binding) = unsafe { (*image).runtime_binding(name) } {
                interpret_runtime_binding(binding, &interpreted_args)
            } else {
                interpret_native_decl(runtime, image, name, &interpreted_args, depth + 1)
            };
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
                    if (*args[0]).layout_id != CLASP_RT_LAYOUT_STRING {
                        null_mut()
                    } else {
                        let built = build_runtime_result_string(true, args[0] as *mut ClaspRtString);
                        release_header(runtime, args[0]);
                        built as *mut ClaspRtHeader
                    }
                },
                "Err" if owned_args.as_ref().map_or(0, Vec::len) == 1 => unsafe {
                    let args = owned_args.as_ref().unwrap();
                    if (*args[0]).layout_id != CLASP_RT_LAYOUT_STRING {
                        null_mut()
                    } else {
                        let built = build_runtime_result_string(false, args[0] as *mut ClaspRtString);
                        release_header(runtime, args[0]);
                        built as *mut ClaspRtHeader
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
            unsafe {
                release_header(runtime, left_value);
                release_header(runtime, right_value);
            }
            match appended {
                Some(items) => unsafe { build_runtime_list_value(items) as *mut ClaspRtHeader },
                None => null_mut(),
            }
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
        ("textChars", 1) => unsafe { clasp_rt_text_chars(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("textFingerprint64Hex", 1) => unsafe { clasp_rt_text_fingerprint64_hex(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("textPrefix", 2) => unsafe { clasp_rt_text_prefix(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("textSplitFirst", 2) => unsafe { clasp_rt_text_split_first(args[0] as *mut ClaspRtString, args[1] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("pathJoin", 1) => unsafe {
            list_like_string_items(args[0])
                .map(|parts| build_runtime_string(&join_string_bytes(&parts, b"/")) as *mut ClaspRtHeader)
                .unwrap_or(null_mut())
        },
        ("pathDirname", 1) => unsafe { clasp_rt_path_dirname(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        ("readFile", 1) => unsafe { clasp_rt_read_file(args[0] as *mut ClaspRtString) as *mut ClaspRtHeader },
        _ => null_mut(),
    }
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
    let Some(branch) = branches.iter().find(|branch| branch.tag == tag) else {
        return null_mut();
    };

    if branch.binders.len() > 1 {
        return null_mut();
    }

    let mut extended_env: Vec<(&str, *mut ClaspRtHeader)> = env.to_vec();
    if let Some(binder) = branch.binders.first() {
        extended_env.push((binder.as_str(), payload));
    }
    interpret_native_expr(runtime, image, &branch.body, &extended_env, depth + 1)
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
    let Some(branch) = branches.iter().find(|branch| branch.tag == tag) else {
        return null_mut();
    };

    if branch.binders.len() != payloads.len() {
        return null_mut();
    }

    let mut extended_env: Vec<(&str, *mut ClaspRtHeader)> = env.to_vec();
    for (binder, payload) in branch.binders.iter().zip(payloads.iter().copied()) {
        extended_env.push((binder.as_str(), payload));
    }
    interpret_native_expr(runtime, image, &branch.body, &extended_env, depth + 1)
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

fn json_decode_string(bytes: &[u8], string_slice: JsonSlice) -> Option<Vec<u8>> {
    if bytes.get(string_slice.start) != Some(&b'"')
        || string_slice.end <= string_slice.start + 1
        || bytes.get(string_slice.end - 1) != Some(&b'"')
    {
        return None;
    }

    let mut cursor = string_slice.start + 1;
    let mut decoded = Vec::with_capacity(string_slice.end - string_slice.start);
    while cursor < string_slice.end - 1 {
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

unsafe fn invalid_native_image_result() -> *mut ClaspRtResultString {
    clasp_rt_result_err_string(clasp_rt_string_from_utf8(b"invalid_native_image\0".as_ptr() as *const c_char))
}

unsafe fn missing_native_dispatch_result() -> *mut ClaspRtResultString {
    clasp_rt_result_err_string(clasp_rt_string_from_utf8(b"missing_dispatch_target\0".as_ptr() as *const c_char))
}

unsafe fn missing_native_entrypoint_result() -> *mut ClaspRtResultString {
    clasp_rt_result_err_string(clasp_rt_string_from_utf8(b"missing_native_entrypoint\0".as_ptr() as *const c_char))
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
        let mut items = Vec::with_capacity(json_array_length(bytes, items_slice));
        for index in 0..json_array_length(bytes, items_slice) {
            let item_slice = json_array_item(bytes, items_slice, index)?;
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
        let mut args = Vec::with_capacity(json_array_length(bytes, args_slice));
        for index in 0..json_array_length(bytes, args_slice) {
            let arg_slice = json_array_item(bytes, args_slice, index)?;
            args.push(parse_interpreted_expr_json(bytes, arg_slice)?);
        }
        return Some(ClaspRtInterpretedExpr::CallLocal(callee_name, args));
    }

    if json_string_equals(bytes, kind_slice, "match") {
        let scrutinee_slice = json_object_lookup(bytes, expr_slice, "scrutinee")?;
        let branches_slice = json_object_lookup(bytes, expr_slice, "branches")?;
        let scrutinee = parse_interpreted_expr_json(bytes, scrutinee_slice)?;
        let mut branches = Vec::with_capacity(json_array_length(bytes, branches_slice));
        for index in 0..json_array_length(bytes, branches_slice) {
            let branch_slice = json_array_item(bytes, branches_slice, index)?;
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
        let mut args = Vec::with_capacity(json_array_length(bytes, args_slice));
        for index in 0..json_array_length(bytes, args_slice) {
            let arg_slice = json_array_item(bytes, args_slice, index)?;
            args.push(parse_interpreted_expr_json(bytes, arg_slice)?);
        }
        return Some(ClaspRtInterpretedExpr::Construct(name, args));
    }

    if json_string_equals(bytes, kind_slice, "record") {
        let record_name_slice = json_object_lookup(bytes, expr_slice, "recordName")?;
        let fields_slice = json_object_lookup(bytes, expr_slice, "fields")?;
        let record_name = json_string_owned(bytes, record_name_slice)?;
        let mut fields = Vec::with_capacity(json_array_length(bytes, fields_slice));
        for index in 0..json_array_length(bytes, fields_slice) {
            let field_slice = json_array_item(bytes, fields_slice, index)?;
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
        if json_string_equals(bytes, name_slice, "encode") {
            let value_slice = json_object_lookup(bytes, expr_slice, "value")?;
            return Some(ClaspRtInterpretedExpr::Intrinsic(
                ClaspRtInterpretedIntrinsic::Encode(
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
    let mut binders = Vec::with_capacity(json_array_length(bytes, binders_slice));
    for index in 0..json_array_length(bytes, binders_slice) {
        let binder_slice = json_array_item(bytes, binders_slice, index)?;
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
            let mut params = Vec::new();
            for index in 0..json_array_length(bytes, params_slice) {
                let param_slice = json_array_item(bytes, params_slice, index)?;
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
        exports: Vec::new(),
        entrypoint_symbols: vec![null_mut(); json_array_length(bytes, exports)],
        entrypoints: vec![None; json_array_length(bytes, exports)],
        interpreted_decls: Vec::new(),
        interpreted_decl_indexes: HashMap::new(),
        decl_count: json_array_length(bytes, decls),
    });

    if loaded.module_name.is_null()
        || loaded.runtime_profile.is_null()
        || loaded.interface_fingerprint.is_null()
        || loaded.migration_strategy.is_null()
    {
        drop(loaded);
        return null_mut();
    }

    for index in 0..json_array_length(bytes, accepted_previous_fingerprints) {
        let Some(fingerprint_value) = json_array_item(bytes, accepted_previous_fingerprints, index) else {
            drop(loaded);
            return null_mut();
        };
        let fingerprint = json_string_value(bytes, fingerprint_value);
        if fingerprint.is_null() {
            drop(loaded);
            return null_mut();
        }
        loaded.accepted_previous_fingerprints.push(fingerprint);
    }

    for index in 0..json_array_length(bytes, runtime_bindings) {
        let Some(binding_value) = json_array_item(bytes, runtime_bindings, index) else {
            drop(loaded);
            return null_mut();
        };
        let Some(name_slice) = json_object_lookup(bytes, binding_value, "name") else {
            drop(loaded);
            return null_mut();
        };
        let Some(runtime_name_slice) = json_object_lookup(bytes, binding_value, "runtime") else {
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
        let binding_index = loaded.runtime_bindings.len();
        loaded.runtime_binding_indexes.insert(name.clone(), binding_index);
        loaded.runtime_bindings.push(ClaspRtNativeRuntimeBinding { name, runtime_name });
    }

    for index in 0..json_array_length(bytes, exports) {
        let Some(export_value) = json_array_item(bytes, exports, index) else {
            drop(loaded);
            return null_mut();
        };
        let export_name = json_string_value(bytes, export_value);
        if export_name.is_null() {
            drop(loaded);
            return null_mut();
        }
        loaded.exports.push(export_name);
    }

    for index in 0..json_array_length(bytes, entrypoints) {
        let Some(entrypoint_value) = json_array_item(bytes, entrypoints, index) else {
            drop(loaded);
            return null_mut();
        };
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

    for index in 0..json_array_length(bytes, decls) {
        let Some(decl_value) = json_array_item(bytes, decls, index) else {
            drop(loaded);
            return null_mut();
        };
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
    let symbol = (*image).entrypoint_symbols[index];
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
pub unsafe extern "C" fn clasp_rt_text_concat(parts: *mut ClaspRtStringList) -> *mut ClaspRtString {
    let items = string_list_items_mut(parts);
    build_runtime_string(&join_string_bytes(items, &[]))
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
