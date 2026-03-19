#ifndef CLASP_NATIVE_RUNTIME_H
#define CLASP_NATIVE_RUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ClaspRtHeader ClaspRtHeader;
typedef struct ClaspRtObjectLayout ClaspRtObjectLayout;
typedef struct ClaspRtRuntime ClaspRtRuntime;
typedef struct ClaspRtString ClaspRtString;
typedef ClaspRtString ClaspRtJson;
typedef struct ClaspRtBytes ClaspRtBytes;
typedef struct ClaspRtStringList ClaspRtStringList;
typedef struct ClaspRtResultString ClaspRtResultString;
typedef struct ClaspRtObject ClaspRtObject;
typedef struct ClaspRtNativeModuleImage ClaspRtNativeModuleImage;
typedef ClaspRtHeader *(*ClaspRtNativeEntrypointFn)(
  ClaspRtRuntime *runtime,
  ClaspRtHeader **args,
  size_t arg_count
);
typedef ClaspRtNativeEntrypointFn (*ClaspRtNativeSymbolResolverFn)(
  ClaspRtString *symbol
);
typedef ClaspRtJson *(*ClaspRtNativeSnapshotFn)(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t generation,
  ClaspRtString *interface_fingerprint,
  ClaspRtString *state_type
);
typedef ClaspRtNativeSnapshotFn (*ClaspRtNativeSnapshotResolverFn)(
  ClaspRtString *symbol
);
typedef bool (*ClaspRtNativeHandoffFn)(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t previous_generation,
  size_t next_generation,
  ClaspRtString *previous_fingerprint,
  ClaspRtString *next_fingerprint,
  ClaspRtString *state_type,
  ClaspRtJson *snapshot
);
typedef ClaspRtNativeHandoffFn (*ClaspRtNativeHandoffResolverFn)(
  ClaspRtString *symbol
);

struct ClaspRtHeader {
  uint32_t layout_id;
  uint32_t retain_count;
  void (*destroy)(ClaspRtRuntime *runtime, ClaspRtHeader *header);
};

struct ClaspRtObjectLayout {
  uint32_t layout_id;
  size_t word_count;
  size_t root_count;
  const uint32_t *root_offsets;
};

struct ClaspRtRuntime {
  size_t static_root_count;
  ClaspRtHeader ***static_roots;
  size_t active_native_module_count;
  ClaspRtNativeModuleImage **active_native_modules;
};

struct ClaspRtString {
  ClaspRtHeader header;
  size_t byte_length;
  char *bytes;
};

struct ClaspRtBytes {
  ClaspRtHeader header;
  size_t byte_length;
  uint8_t *bytes;
};

struct ClaspRtStringList {
  ClaspRtHeader header;
  size_t length;
  ClaspRtString **items;
};

struct ClaspRtResultString {
  ClaspRtHeader header;
  bool is_ok;
  ClaspRtString *value;
};

struct ClaspRtObject {
  ClaspRtHeader header;
  const ClaspRtObjectLayout *layout;
  uintptr_t words[];
};

void clasp_rt_init(ClaspRtRuntime *runtime);
void clasp_rt_shutdown(ClaspRtRuntime *runtime);
void clasp_rt_register_static_root(ClaspRtRuntime *runtime, ClaspRtHeader **slot);
ClaspRtObject *clasp_rt_alloc_object(const ClaspRtObjectLayout *layout);
void clasp_rt_retain(ClaspRtHeader *header);
void clasp_rt_release(ClaspRtRuntime *runtime, ClaspRtHeader *header);

ClaspRtString *clasp_rt_string_from_utf8(const char *value);
ClaspRtBytes *clasp_rt_bytes_new(size_t length);
ClaspRtStringList *clasp_rt_string_list_new(size_t length);
ClaspRtResultString *clasp_rt_result_ok_string(ClaspRtString *value);
ClaspRtResultString *clasp_rt_result_err_string(ClaspRtString *value);
ClaspRtJson *clasp_rt_json_from_string(ClaspRtString *value);
ClaspRtString *clasp_rt_json_to_string(ClaspRtJson *value);
ClaspRtBytes *clasp_rt_binary_from_json(ClaspRtJson *value);
ClaspRtJson *clasp_rt_json_from_binary(ClaspRtBytes *value);
ClaspRtBytes *clasp_rt_transport_frame(ClaspRtBytes *payload);
ClaspRtBytes *clasp_rt_transport_unframe(ClaspRtBytes *frame);
bool clasp_rt_native_image_validate(ClaspRtJson *image);
ClaspRtResultString *clasp_rt_native_image_module_name(ClaspRtJson *image);
ClaspRtResultString *clasp_rt_native_image_runtime_profile(ClaspRtJson *image);
size_t clasp_rt_native_image_decl_count(ClaspRtJson *image);
bool clasp_rt_native_image_has_runtime_artifact(ClaspRtJson *image, ClaspRtString *artifact);
ClaspRtNativeModuleImage *clasp_rt_native_module_image_load(ClaspRtJson *image);
void clasp_rt_native_module_image_free(ClaspRtRuntime *runtime, ClaspRtNativeModuleImage *image);
ClaspRtString *clasp_rt_native_module_image_module_name(ClaspRtNativeModuleImage *image);
ClaspRtString *clasp_rt_native_module_image_runtime_profile(ClaspRtNativeModuleImage *image);
ClaspRtString *clasp_rt_native_module_image_interface_fingerprint(ClaspRtNativeModuleImage *image);
ClaspRtString *clasp_rt_native_module_image_migration_strategy(ClaspRtNativeModuleImage *image);
ClaspRtString *clasp_rt_native_module_image_state_type(ClaspRtNativeModuleImage *image);
ClaspRtString *clasp_rt_native_module_image_snapshot_symbol(ClaspRtNativeModuleImage *image);
ClaspRtString *clasp_rt_native_module_image_handoff_symbol(ClaspRtNativeModuleImage *image);
size_t clasp_rt_native_module_image_export_count(ClaspRtNativeModuleImage *image);
bool clasp_rt_native_module_image_has_export(ClaspRtNativeModuleImage *image, ClaspRtString *export_name);
bool clasp_rt_native_module_image_accepts_previous_fingerprint(
  ClaspRtNativeModuleImage *image,
  ClaspRtString *fingerprint
);
ClaspRtResultString *clasp_rt_native_module_image_entrypoint_symbol(
  ClaspRtNativeModuleImage *image,
  ClaspRtString *export_name
);
size_t clasp_rt_native_module_image_decl_count(ClaspRtNativeModuleImage *image);
bool clasp_rt_activate_native_module_image(ClaspRtRuntime *runtime, ClaspRtNativeModuleImage *image);
size_t clasp_rt_active_native_module_count(ClaspRtRuntime *runtime);
size_t clasp_rt_active_native_module_generation(ClaspRtRuntime *runtime, ClaspRtString *module_name);
size_t clasp_rt_active_native_module_generation_count(ClaspRtRuntime *runtime, ClaspRtString *module_name);
bool clasp_rt_has_active_native_module(ClaspRtRuntime *runtime, ClaspRtString *module_name);
bool clasp_rt_has_active_native_module_generation(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t generation
);
bool clasp_rt_retire_native_module_generation(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t generation
);
bool clasp_rt_bind_native_entrypoint(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  ClaspRtString *export_name,
  ClaspRtNativeEntrypointFn entrypoint
);
bool clasp_rt_bind_native_entrypoint_symbol(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  ClaspRtString *export_name,
  ClaspRtNativeSymbolResolverFn resolve_symbol
);
bool clasp_rt_bind_native_snapshot(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  ClaspRtNativeSnapshotFn snapshot
);
bool clasp_rt_bind_native_snapshot_symbol(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  ClaspRtNativeSnapshotResolverFn resolve_symbol
);
bool clasp_rt_bind_native_handoff(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  ClaspRtNativeHandoffFn handoff
);
bool clasp_rt_bind_native_handoff_symbol(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  ClaspRtNativeHandoffResolverFn resolve_symbol
);
ClaspRtResultString *clasp_rt_resolve_native_dispatch(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  ClaspRtString *export_name
);
ClaspRtResultString *clasp_rt_resolve_native_dispatch_generation(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t generation,
  ClaspRtString *export_name
);
ClaspRtNativeEntrypointFn clasp_rt_resolve_native_entrypoint(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  ClaspRtString *export_name
);
ClaspRtNativeEntrypointFn clasp_rt_resolve_native_entrypoint_generation(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t generation,
  ClaspRtString *export_name
);
ClaspRtHeader *clasp_rt_call_native_dispatch(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  ClaspRtString *export_name,
  ClaspRtHeader **args,
  size_t arg_count
);
ClaspRtHeader *clasp_rt_call_native_dispatch_generation(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t generation,
  ClaspRtString *export_name,
  ClaspRtHeader **args,
  size_t arg_count
);
ClaspRtNativeSnapshotFn clasp_rt_resolve_native_snapshot(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name
);
ClaspRtNativeHandoffFn clasp_rt_resolve_native_handoff(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name
);
bool clasp_rt_store_native_module_state_snapshot(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t generation,
  ClaspRtString *state_type,
  ClaspRtJson *snapshot
);
ClaspRtString *clasp_rt_native_module_generation_state_type(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t generation
);
ClaspRtJson *clasp_rt_native_module_generation_state_snapshot(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t generation
);

ClaspRtString *clasp_rt_text_concat(ClaspRtStringList *parts);
ClaspRtString *clasp_rt_text_join(ClaspRtString *separator, ClaspRtStringList *parts);
ClaspRtStringList *clasp_rt_text_split(ClaspRtString *value, ClaspRtString *separator);
ClaspRtStringList *clasp_rt_text_chars(ClaspRtString *value);
ClaspRtResultString *clasp_rt_text_prefix(ClaspRtString *value, ClaspRtString *prefix);
ClaspRtResultString *clasp_rt_text_split_first(ClaspRtString *value, ClaspRtString *separator);
ClaspRtString *clasp_rt_path_join(ClaspRtStringList *parts);
ClaspRtString *clasp_rt_path_dirname(ClaspRtString *path);
ClaspRtString *clasp_rt_path_basename(ClaspRtString *path);
bool clasp_rt_file_exists(ClaspRtString *path);
ClaspRtResultString *clasp_rt_read_file(ClaspRtString *path);

#endif
