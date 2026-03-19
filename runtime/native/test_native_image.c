#include "clasp_runtime.h"

#include <stdio.h>
#include <string.h>

static int fail(const char *message) {
  fprintf(stderr, "%s\n", message);
  return 1;
}

static ClaspRtHeader *test_main_entry(
  ClaspRtRuntime *runtime,
  ClaspRtHeader **args,
  size_t arg_count
) {
  (void) runtime;
  (void) args;
  (void) arg_count;
  return (ClaspRtHeader *) clasp_rt_string_from_utf8("runtime-dispatched-v1");
}

static ClaspRtHeader *test_main_entry_next(
  ClaspRtRuntime *runtime,
  ClaspRtHeader **args,
  size_t arg_count
) {
  (void) runtime;
  (void) args;
  (void) arg_count;
  return (ClaspRtHeader *) clasp_rt_string_from_utf8("runtime-dispatched-v2");
}

static ClaspRtNativeEntrypointFn test_symbol_resolver(ClaspRtString *symbol) {
  if (symbol != NULL && strcmp(symbol->bytes, "clasp_native__Main__main") == 0) {
    return test_main_entry;
  }

  return NULL;
}

static ClaspRtNativeEntrypointFn test_symbol_resolver_next(ClaspRtString *symbol) {
  if (symbol != NULL && strcmp(symbol->bytes, "clasp_native__Main__main") == 0) {
    return test_main_entry_next;
  }

  return NULL;
}

static ClaspRtString *expected_previous_fingerprint = NULL;
static ClaspRtString *expected_next_fingerprint = NULL;
static ClaspRtString *expected_state_type = NULL;
static ClaspRtJson *expected_snapshot = NULL;
static ClaspRtString *expected_snapshot_symbol = NULL;
static ClaspRtString *expected_handoff_symbol = NULL;
static int handoff_invoked = 0;
static int snapshot_invoked = 0;
static size_t handoff_previous_generation = 0u;
static size_t handoff_next_generation = 0u;
static size_t snapshot_generation = 0u;

static ClaspRtJson *test_snapshot(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t generation,
  ClaspRtString *interface_fingerprint,
  ClaspRtString *state_type
) {
  ClaspRtString *json_string = NULL;
  ClaspRtJson *snapshot = NULL;

  if (module_name == NULL || strcmp(module_name->bytes, "Main") != 0) {
    return NULL;
  }
  if (expected_previous_fingerprint == NULL || expected_state_type == NULL) {
    return NULL;
  }
  if (interface_fingerprint == NULL || state_type == NULL) {
    return NULL;
  }
  if (strcmp(interface_fingerprint->bytes, expected_previous_fingerprint->bytes) != 0 ||
      strcmp(state_type->bytes, expected_state_type->bytes) != 0) {
    return NULL;
  }

  snapshot_invoked = 1;
  snapshot_generation = generation;
  json_string = clasp_rt_string_from_utf8("{\"count\":7,\"status\":\"warm\"}");
  snapshot = clasp_rt_json_from_string(json_string);
  clasp_rt_release(runtime, (ClaspRtHeader *) json_string);
  return snapshot;
}

static ClaspRtNativeSnapshotFn test_snapshot_resolver(ClaspRtString *symbol) {
  if (symbol != NULL && strcmp(symbol->bytes, "$encode_Counter") == 0) {
    return test_snapshot;
  }

  return NULL;
}

static bool test_handoff(
  ClaspRtRuntime *runtime,
  ClaspRtString *module_name,
  size_t previous_generation,
  size_t next_generation,
  ClaspRtString *previous_fingerprint,
  ClaspRtString *next_fingerprint,
  ClaspRtString *state_type,
  ClaspRtJson *snapshot
) {
  (void) runtime;
  if (module_name == NULL || strcmp(module_name->bytes, "Main") != 0) {
    return false;
  }
  if (expected_previous_fingerprint == NULL || expected_next_fingerprint == NULL ||
      expected_state_type == NULL || expected_snapshot == NULL) {
    return false;
  }
  if (previous_fingerprint == NULL || next_fingerprint == NULL ||
      state_type == NULL || snapshot == NULL) {
    return false;
  }
  if (strcmp(previous_fingerprint->bytes, expected_previous_fingerprint->bytes) != 0 ||
      strcmp(next_fingerprint->bytes, expected_next_fingerprint->bytes) != 0 ||
      strcmp(state_type->bytes, expected_state_type->bytes) != 0 ||
      strcmp(((ClaspRtString *) snapshot)->bytes, ((ClaspRtString *) expected_snapshot)->bytes) != 0) {
    return false;
  }
  handoff_invoked = 1;
  handoff_previous_generation = previous_generation;
  handoff_next_generation = next_generation;
  return true;
}

static ClaspRtNativeHandoffFn test_handoff_resolver(ClaspRtString *symbol) {
  if (symbol != NULL && expected_handoff_symbol != NULL &&
      strcmp(symbol->bytes, expected_handoff_symbol->bytes) == 0) {
    return test_handoff;
  }

  return NULL;
}

int main(int argc, char **argv) {
  ClaspRtRuntime runtime = {0};
  ClaspRtString *path = NULL;
  ClaspRtString *migrating_path = NULL;
  ClaspRtString *incompatible_path = NULL;
  ClaspRtResultString *read_result = NULL;
  ClaspRtResultString *migrating_read_result = NULL;
  ClaspRtResultString *incompatible_read_result = NULL;
  ClaspRtJson *image = NULL;
  ClaspRtJson *migrating_image = NULL;
  ClaspRtJson *incompatible_image = NULL;
  ClaspRtNativeModuleImage *loaded_image = NULL;
  ClaspRtNativeModuleImage *loaded_image_next = NULL;
  ClaspRtNativeModuleImage *loaded_incompatible_image = NULL;
  ClaspRtString *module_name = NULL;
  ClaspRtString *runtime_profile = NULL;
  ClaspRtString *runtime_artifact = NULL;
  ClaspRtString *main_export = NULL;
  ClaspRtString *interface_fingerprint = NULL;
  ClaspRtString *next_interface_fingerprint = NULL;
  ClaspRtString *migration_strategy = NULL;
  ClaspRtString *migration_state_type = NULL;
  ClaspRtString *migration_snapshot_symbol = NULL;
  ClaspRtString *migration_handoff_symbol = NULL;
  ClaspRtString *stored_state_type = NULL;
  ClaspRtJson *stored_snapshot = NULL;
  ClaspRtResultString *entrypoint_symbol = NULL;
  ClaspRtResultString *dispatch_target = NULL;
  ClaspRtResultString *dispatch_target_generation_one = NULL;
  ClaspRtHeader *dispatch_value = NULL;
  ClaspRtHeader *dispatch_value_generation_one = NULL;
  ClaspRtString *dispatch_result = NULL;
  ClaspRtString *dispatch_result_generation_one = NULL;
  ClaspRtNativeEntrypointFn resolved_entrypoint = NULL;
  ClaspRtNativeEntrypointFn resolved_entrypoint_generation_one = NULL;
  size_t active_module_count = 0u;
  size_t latest_generation = 0u;
  size_t active_generation_count = 0u;
  size_t overlap_generation_count = 0u;
  size_t export_count = 0u;
  size_t decl_count = 0u;
  int rejected_incompatible_upgrade = 0;
  int exit_code = 1;

  if (argc != 4) {
    fprintf(stderr, "usage: %s <module.native.image.json> <migrating-upgrade.native.image.json> <incompatible-upgrade.native.image.json>\n", argv[0]);
    return 2;
  }

  clasp_rt_init(&runtime);

  path = clasp_rt_string_from_utf8(argv[1]);
  migrating_path = clasp_rt_string_from_utf8(argv[2]);
  incompatible_path = clasp_rt_string_from_utf8(argv[3]);
  read_result = clasp_rt_read_file(path);
  if (!read_result->is_ok) {
    exit_code = fail("failed to read native image");
    goto cleanup;
  }

  image = clasp_rt_json_from_string(read_result->value);
  if (!clasp_rt_native_image_validate(image)) {
    exit_code = fail("runtime rejected native image");
    goto cleanup;
  }

  loaded_image = clasp_rt_native_module_image_load(image);
  if (loaded_image == NULL) {
    exit_code = fail("runtime failed to load native image");
    goto cleanup;
  }

  module_name = clasp_rt_native_module_image_module_name(loaded_image);
  if (module_name == NULL || strcmp(module_name->bytes, "Main") != 0) {
    exit_code = fail("unexpected native image module name");
    goto cleanup;
  }

  runtime_profile = clasp_rt_native_module_image_runtime_profile(loaded_image);
  if (runtime_profile == NULL ||
      strcmp(runtime_profile->bytes, "compiler_backend_minimal") != 0) {
    exit_code = fail("unexpected native image runtime profile");
    goto cleanup;
  }

  interface_fingerprint = clasp_rt_native_module_image_interface_fingerprint(loaded_image);
  if (interface_fingerprint == NULL || interface_fingerprint->byte_length == 0u) {
    exit_code = fail("expected native image compatibility fingerprint");
    goto cleanup;
  }
  if (!clasp_rt_native_module_image_accepts_previous_fingerprint(loaded_image, interface_fingerprint)) {
    exit_code = fail("expected native image to accept its own compatibility fingerprint");
    goto cleanup;
  }

  export_count = clasp_rt_native_module_image_export_count(loaded_image);
  if (export_count == 0u) {
    exit_code = fail("expected native image exports");
    goto cleanup;
  }

  main_export = clasp_rt_string_from_utf8("main");
  if (!clasp_rt_native_module_image_has_export(loaded_image, main_export)) {
    exit_code = fail("expected main export in native image");
    goto cleanup;
  }

  entrypoint_symbol = clasp_rt_native_module_image_entrypoint_symbol(loaded_image, main_export);
  if (!entrypoint_symbol->is_ok ||
      strcmp(entrypoint_symbol->value->bytes, "clasp_native__Main__main") != 0) {
    exit_code = fail("unexpected native image entrypoint symbol");
    goto cleanup;
  }

  decl_count = clasp_rt_native_module_image_decl_count(loaded_image);
  if (decl_count == 0u) {
    exit_code = fail("expected native image declarations");
    goto cleanup;
  }

  expected_state_type = clasp_rt_native_module_image_state_type(loaded_image);
  if (expected_state_type == NULL || strcmp(expected_state_type->bytes, "Counter") != 0) {
    exit_code = fail("expected native image state type");
    goto cleanup;
  }

  expected_snapshot_symbol = clasp_rt_native_module_image_snapshot_symbol(loaded_image);
  if (expected_snapshot_symbol == NULL || strcmp(expected_snapshot_symbol->bytes, "$encode_Counter") != 0) {
    exit_code = fail("expected native image snapshot symbol");
    goto cleanup;
  }

  expected_handoff_symbol = clasp_rt_native_module_image_handoff_symbol(loaded_image);
  if (expected_handoff_symbol == NULL ||
      strcmp(expected_handoff_symbol->bytes, "clasp_native__Main__CounterFlow__handoff") != 0) {
    exit_code = fail("expected native image handoff symbol");
    goto cleanup;
  }

  if (!clasp_rt_activate_native_module_image(&runtime, loaded_image)) {
    exit_code = fail("runtime failed to activate native image");
    goto cleanup;
  }
  loaded_image = NULL;

  active_module_count = clasp_rt_active_native_module_count(&runtime);
  if (active_module_count != 1u) {
    exit_code = fail("expected one active native module");
    goto cleanup;
  }

  latest_generation = clasp_rt_active_native_module_generation(&runtime, module_name);
  if (latest_generation != 1u) {
    exit_code = fail("expected generation one after first activation");
    goto cleanup;
  }

  active_generation_count = clasp_rt_active_native_module_generation_count(&runtime, module_name);
  if (active_generation_count != 1u) {
    exit_code = fail("expected one active generation after first activation");
    goto cleanup;
  }

  expected_previous_fingerprint = interface_fingerprint;
  if (!clasp_rt_bind_native_snapshot_symbol(&runtime, module_name, test_snapshot_resolver)) {
    exit_code = fail("runtime failed to bind native snapshot symbol");
    goto cleanup;
  }

  if (clasp_rt_resolve_native_snapshot(&runtime, module_name) != test_snapshot) {
    exit_code = fail("runtime resolved unexpected native snapshot hook");
    goto cleanup;
  }

  if (clasp_rt_native_module_generation_state_type(&runtime, module_name, 1u) != NULL) {
    exit_code = fail("expected generation one state type to be empty before snapshot capture");
    goto cleanup;
  }

  if (clasp_rt_native_module_generation_state_snapshot(&runtime, module_name, 1u) != NULL) {
    exit_code = fail("expected generation one snapshot payload to be empty before snapshot capture");
    goto cleanup;
  }

  if (!clasp_rt_has_active_native_module(&runtime, module_name)) {
    exit_code = fail("expected active Main module");
    goto cleanup;
  }

  dispatch_target = clasp_rt_resolve_native_dispatch(&runtime, module_name, main_export);
  if (!dispatch_target->is_ok ||
      strcmp(dispatch_target->value->bytes, "Main@1::main") != 0) {
    exit_code = fail("unexpected native dispatch target");
    goto cleanup;
  }

  if (clasp_rt_resolve_native_entrypoint(&runtime, module_name, main_export) != NULL) {
    exit_code = fail("expected unbound native entrypoint before bind");
    goto cleanup;
  }

  if (!clasp_rt_bind_native_entrypoint_symbol(&runtime, module_name, main_export, test_symbol_resolver)) {
    exit_code = fail("runtime failed to bind native entrypoint symbol");
    goto cleanup;
  }

  resolved_entrypoint = clasp_rt_resolve_native_entrypoint(&runtime, module_name, main_export);
  if (resolved_entrypoint != test_main_entry) {
    exit_code = fail("runtime resolved unexpected native entrypoint");
    goto cleanup;
  }

  migrating_read_result = clasp_rt_read_file(migrating_path);
  if (!migrating_read_result->is_ok) {
    exit_code = fail("failed to read migrating native image");
    goto cleanup;
  }

  migrating_image = clasp_rt_json_from_string(migrating_read_result->value);
  if (!clasp_rt_native_image_validate(migrating_image)) {
    exit_code = fail("runtime rejected migrating native image");
    goto cleanup;
  }

  loaded_image_next = clasp_rt_native_module_image_load(migrating_image);
  if (loaded_image_next == NULL) {
    exit_code = fail("runtime failed to load upgrade native image");
    goto cleanup;
  }

  next_interface_fingerprint = clasp_rt_native_module_image_interface_fingerprint(loaded_image_next);
  if (next_interface_fingerprint == NULL ||
      strcmp(next_interface_fingerprint->bytes, interface_fingerprint->bytes) == 0) {
    exit_code = fail("expected migrating upgrade fingerprint to differ from the original");
    goto cleanup;
  }

  migration_strategy = clasp_rt_native_module_image_migration_strategy(loaded_image_next);
  if (migration_strategy == NULL ||
      strcmp(migration_strategy->bytes, "state-handoff") != 0) {
    exit_code = fail("expected state-handoff migration strategy on upgrade image");
    goto cleanup;
  }

  migration_state_type = clasp_rt_native_module_image_state_type(loaded_image_next);
  if (migration_state_type == NULL ||
      strcmp(migration_state_type->bytes, "Counter") != 0) {
    exit_code = fail("expected migration state type on upgrade image");
    goto cleanup;
  }

  migration_snapshot_symbol = clasp_rt_native_module_image_snapshot_symbol(loaded_image_next);
  if (migration_snapshot_symbol == NULL ||
      strcmp(migration_snapshot_symbol->bytes, "$encode_Counter") != 0) {
    exit_code = fail("expected migration snapshot symbol on upgrade image");
    goto cleanup;
  }

  migration_handoff_symbol = clasp_rt_native_module_image_handoff_symbol(loaded_image_next);
  if (migration_handoff_symbol == NULL ||
      strcmp(migration_handoff_symbol->bytes, "clasp_native__Main__CounterFlow__handoff") != 0) {
    exit_code = fail("expected migration handoff symbol on upgrade image");
    goto cleanup;
  }

  expected_next_fingerprint = next_interface_fingerprint;

  if (!clasp_rt_activate_native_module_image(&runtime, loaded_image_next)) {
    exit_code = fail("runtime failed to activate upgrade native image");
    goto cleanup;
  }
  loaded_image_next = NULL;

  active_module_count = clasp_rt_active_native_module_count(&runtime);
  if (active_module_count != 2u) {
    exit_code = fail("expected overlapping native module generations");
    goto cleanup;
  }

  latest_generation = clasp_rt_active_native_module_generation(&runtime, module_name);
  if (latest_generation != 2u) {
    exit_code = fail("expected generation two after upgrade activation");
    goto cleanup;
  }

  active_generation_count = clasp_rt_active_native_module_generation_count(&runtime, module_name);
  if (active_generation_count != 2u) {
    exit_code = fail("expected dual-generation overlap after upgrade activation");
    goto cleanup;
  }
  overlap_generation_count = active_generation_count;

  if (!clasp_rt_has_active_native_module_generation(&runtime, module_name, 1u) ||
      !clasp_rt_has_active_native_module_generation(&runtime, module_name, 2u)) {
    exit_code = fail("expected both generation one and generation two to remain active");
    goto cleanup;
  }

  clasp_rt_release(&runtime, (ClaspRtHeader *) dispatch_target);
  dispatch_target = clasp_rt_resolve_native_dispatch(&runtime, module_name, main_export);
  if (!dispatch_target->is_ok ||
      strcmp(dispatch_target->value->bytes, "Main@2::main") != 0) {
    exit_code = fail("expected default dispatch to target the newest generation");
    goto cleanup;
  }

  dispatch_target_generation_one =
    clasp_rt_resolve_native_dispatch_generation(&runtime, module_name, 1u, main_export);
  if (!dispatch_target_generation_one->is_ok ||
      strcmp(dispatch_target_generation_one->value->bytes, "Main@1::main") != 0) {
    exit_code = fail("expected generation-specific dispatch to preserve the old generation");
    goto cleanup;
  }

  if (!clasp_rt_bind_native_entrypoint_symbol(&runtime, module_name, main_export, test_symbol_resolver_next)) {
    exit_code = fail("runtime failed to bind native entrypoint symbol for the newest generation");
    goto cleanup;
  }

  resolved_entrypoint = clasp_rt_resolve_native_entrypoint(&runtime, module_name, main_export);
  if (resolved_entrypoint != test_main_entry_next) {
    exit_code = fail("runtime resolved unexpected newest-generation native entrypoint");
    goto cleanup;
  }

  resolved_entrypoint_generation_one =
    clasp_rt_resolve_native_entrypoint_generation(&runtime, module_name, 1u, main_export);
  if (resolved_entrypoint_generation_one != test_main_entry) {
    exit_code = fail("runtime lost the older generation entrypoint");
    goto cleanup;
  }

  if (clasp_rt_retire_native_module_generation(&runtime, module_name, 1u)) {
    exit_code = fail("expected old-generation retirement to require a migration handoff");
    goto cleanup;
  }

  if (!snapshot_invoked || snapshot_generation != 1u) {
    exit_code = fail("expected native snapshot hook to run for generation one");
    goto cleanup;
  }

  stored_state_type = clasp_rt_native_module_generation_state_type(&runtime, module_name, 1u);
  if (stored_state_type == NULL || strcmp(stored_state_type->bytes, "Counter") != 0) {
    exit_code = fail("expected stored state snapshot type on generation one");
    goto cleanup;
  }

  stored_snapshot = clasp_rt_native_module_generation_state_snapshot(&runtime, module_name, 1u);
  if (stored_snapshot == NULL ||
      strcmp(((ClaspRtString *) stored_snapshot)->bytes, "{\"count\":7,\"status\":\"warm\"}") != 0) {
    exit_code = fail("expected stored state snapshot payload on generation one");
    goto cleanup;
  }
  expected_snapshot = stored_snapshot;

  if (!clasp_rt_bind_native_handoff_symbol(&runtime, module_name, test_handoff_resolver)) {
    exit_code = fail("runtime failed to bind native handoff symbol");
    goto cleanup;
  }

  if (clasp_rt_resolve_native_handoff(&runtime, module_name) != test_handoff) {
    exit_code = fail("runtime resolved unexpected native handoff hook");
    goto cleanup;
  }

  dispatch_value = clasp_rt_call_native_dispatch(&runtime, module_name, main_export, NULL, 0u);
  dispatch_result = (ClaspRtString *) dispatch_value;
  if (dispatch_result == NULL || strcmp(dispatch_result->bytes, "runtime-dispatched-v2") != 0) {
    exit_code = fail("runtime newest-generation dispatch returned unexpected value");
    goto cleanup;
  }

  dispatch_value_generation_one =
    clasp_rt_call_native_dispatch_generation(&runtime, module_name, 1u, main_export, NULL, 0u);
  dispatch_result_generation_one = (ClaspRtString *) dispatch_value_generation_one;
  if (dispatch_result_generation_one == NULL ||
      strcmp(dispatch_result_generation_one->bytes, "runtime-dispatched-v1") != 0) {
    exit_code = fail("runtime old-generation dispatch returned unexpected value");
    goto cleanup;
  }

  runtime_artifact = clasp_rt_string_from_utf8("runtime/native/clasp_runtime.rs");
  if (!clasp_rt_native_image_has_runtime_artifact(image, runtime_artifact)) {
    exit_code = fail("missing native runtime artifact in image");
    goto cleanup;
  }

  if (!clasp_rt_retire_native_module_generation(&runtime, module_name, 1u)) {
    exit_code = fail("runtime failed to retire the old generation");
    goto cleanup;
  }

  if (!handoff_invoked || handoff_previous_generation != 1u || handoff_next_generation != 2u) {
    exit_code = fail("expected migration handoff to run before old-generation retirement");
    goto cleanup;
  }

  active_module_count = clasp_rt_active_native_module_count(&runtime);
  if (active_module_count != 1u) {
    exit_code = fail("expected one active native module after old-generation retirement");
    goto cleanup;
  }

  active_generation_count = clasp_rt_active_native_module_generation_count(&runtime, module_name);
  if (active_generation_count != 1u) {
    exit_code = fail("expected one live generation after old-generation retirement");
    goto cleanup;
  }

  if (clasp_rt_has_active_native_module_generation(&runtime, module_name, 1u)) {
    exit_code = fail("expected old generation retirement to remove generation one");
    goto cleanup;
  }

  incompatible_read_result = clasp_rt_read_file(incompatible_path);
  if (!incompatible_read_result->is_ok) {
    exit_code = fail("failed to read incompatible native image");
    goto cleanup;
  }

  incompatible_image = clasp_rt_json_from_string(incompatible_read_result->value);
  if (!clasp_rt_native_image_validate(incompatible_image)) {
    exit_code = fail("runtime rejected incompatible-image fixture as invalid");
    goto cleanup;
  }

  loaded_incompatible_image = clasp_rt_native_module_image_load(incompatible_image);
  if (loaded_incompatible_image == NULL) {
    exit_code = fail("runtime failed to load incompatible native image");
    goto cleanup;
  }

  if (clasp_rt_activate_native_module_image(&runtime, loaded_incompatible_image)) {
    exit_code = fail("runtime accepted an incompatible upgrade image");
    goto cleanup;
  }
  rejected_incompatible_upgrade = 1;

  printf(
    "native-image-ok module=%s profile=%s fingerprint=%s next_fingerprint=%s handoff_strategy=%s state_type=%s snapshot_symbol=%s handoff_symbol=%s snapshot=%s snapshot_hook=%d handoff=%d active_modules=%zu latest_generation=%zu overlap=%zu rejected_incompatible_upgrade=%d symbol=%s dispatch=%s old_dispatch=%s call=%s old_call=%s exports=%zu decls=%zu\n",
    module_name->bytes,
    runtime_profile->bytes,
    interface_fingerprint->bytes,
    next_interface_fingerprint->bytes,
    migration_strategy->bytes,
    migration_state_type->bytes,
    migration_snapshot_symbol->bytes,
    migration_handoff_symbol->bytes,
    ((ClaspRtString *) stored_snapshot)->bytes,
    snapshot_invoked,
    handoff_invoked,
    active_module_count,
    latest_generation,
    overlap_generation_count,
    rejected_incompatible_upgrade,
    entrypoint_symbol->value->bytes,
    dispatch_target->value->bytes,
    dispatch_target_generation_one->value->bytes,
    dispatch_result->bytes,
    dispatch_result_generation_one->bytes,
    export_count,
    decl_count
  );
  exit_code = 0;

cleanup:
  clasp_rt_native_module_image_free(&runtime, loaded_incompatible_image);
  clasp_rt_release(&runtime, dispatch_value_generation_one);
  clasp_rt_release(&runtime, dispatch_value);
  clasp_rt_release(&runtime, (ClaspRtHeader *) dispatch_target_generation_one);
  clasp_rt_release(&runtime, (ClaspRtHeader *) entrypoint_symbol);
  clasp_rt_release(&runtime, (ClaspRtHeader *) dispatch_target);
  clasp_rt_release(&runtime, (ClaspRtHeader *) stored_snapshot);
  clasp_rt_release(&runtime, (ClaspRtHeader *) stored_state_type);
  clasp_rt_release(&runtime, (ClaspRtHeader *) main_export);
  clasp_rt_release(&runtime, (ClaspRtHeader *) runtime_artifact);
  clasp_rt_release(&runtime, (ClaspRtHeader *) migration_handoff_symbol);
  clasp_rt_release(&runtime, (ClaspRtHeader *) migration_snapshot_symbol);
  clasp_rt_release(&runtime, (ClaspRtHeader *) migration_state_type);
  clasp_rt_release(&runtime, (ClaspRtHeader *) migration_strategy);
  clasp_rt_release(&runtime, (ClaspRtHeader *) expected_handoff_symbol);
  clasp_rt_release(&runtime, (ClaspRtHeader *) expected_snapshot_symbol);
  clasp_rt_release(&runtime, (ClaspRtHeader *) expected_state_type);
  clasp_rt_release(&runtime, (ClaspRtHeader *) next_interface_fingerprint);
  clasp_rt_release(&runtime, (ClaspRtHeader *) interface_fingerprint);
  clasp_rt_release(&runtime, (ClaspRtHeader *) runtime_profile);
  clasp_rt_release(&runtime, (ClaspRtHeader *) module_name);
  clasp_rt_native_module_image_free(&runtime, loaded_image_next);
  clasp_rt_native_module_image_free(&runtime, loaded_image);
  clasp_rt_release(&runtime, (ClaspRtHeader *) incompatible_image);
  clasp_rt_release(&runtime, (ClaspRtHeader *) incompatible_read_result);
  clasp_rt_release(&runtime, (ClaspRtHeader *) incompatible_path);
  clasp_rt_release(&runtime, (ClaspRtHeader *) migrating_image);
  clasp_rt_release(&runtime, (ClaspRtHeader *) migrating_read_result);
  clasp_rt_release(&runtime, (ClaspRtHeader *) migrating_path);
  clasp_rt_release(&runtime, (ClaspRtHeader *) image);
  clasp_rt_release(&runtime, (ClaspRtHeader *) read_result);
  clasp_rt_release(&runtime, (ClaspRtHeader *) path);
  clasp_rt_shutdown(&runtime);
  return exit_code;
}
