use std::alloc::{alloc_zeroed, dealloc, handle_alloc_error, Layout};
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
pub struct ClaspRtObject {
    pub header: ClaspRtHeader,
    pub layout: *const ClaspRtObjectLayout,
    pub words: [usize; 0],
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
    exports: Vec<*mut ClaspRtString>,
    entrypoint_symbols: Vec<*mut ClaspRtString>,
    entrypoints: Vec<ClaspRtNativeEntrypointFn>,
    decl_count: usize,
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

unsafe extern "C" fn destroy_result_string(runtime: *mut ClaspRtRuntime, header: *mut ClaspRtHeader) {
    let result = header as *mut ClaspRtResultString;
    if !result.is_null() {
        release_header(runtime, (*result).value as *mut ClaspRtHeader);
        drop(Box::from_raw(result));
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
        exports: Vec::new(),
        entrypoint_symbols: vec![null_mut(); json_array_length(bytes, exports)],
        entrypoints: vec![None; json_array_length(bytes, exports)],
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
        None => null_mut(),
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
        None => null_mut(),
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
    match find_subslice(value_bytes, separator_bytes, 0) {
        Some(match_index) => {
            clasp_rt_result_ok_string(build_runtime_string(
                &value_bytes[match_index + separator_bytes.len()..],
            ))
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
