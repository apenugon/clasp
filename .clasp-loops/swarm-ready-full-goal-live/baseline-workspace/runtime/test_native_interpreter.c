#include "clasp_runtime.h"

#include <stdio.h>
#include <string.h>

static int fail(const char *message) {
  fprintf(stderr, "%s\n", message);
  return 1;
}

int main(int argc, char **argv) {
  ClaspRtRuntime runtime = {0};
  ClaspRtString *path = NULL;
  ClaspRtResultString *read_result = NULL;
  ClaspRtJson *image = NULL;
  ClaspRtNativeModuleImage *loaded_image = NULL;
  ClaspRtString *module_name = NULL;
  ClaspRtString *target_export = NULL;
  ClaspRtString *arg_value = NULL;
  ClaspRtHeader *dispatch_args[1] = {NULL};
  ClaspRtHeader *dispatch_value = NULL;
  ClaspRtString *dispatch_result = NULL;
  const char *export_name = "main";
  const char *expected_value = "Hello from Clasp";
  size_t arg_count = 0;
  int skip_exact_match = 0;
  int exit_code = 1;

  if (argc != 2 && argc != 4 && argc != 5) {
    fprintf(stderr, "usage: %s <module.native.image.json> [<export> <expected-string> [<arg-string>]]\n", argv[0]);
    return 2;
  }

  if (argc >= 4) {
    export_name = argv[2];
    expected_value = argv[3];
    if (strcmp(expected_value, "*") == 0) {
      skip_exact_match = 1;
    }
  }
  if (argc == 5) {
    arg_count = 1;
  }

  clasp_rt_init(&runtime);

  path = clasp_rt_string_from_utf8(argv[1]);
  read_result = clasp_rt_read_file(path);
  if (!read_result->is_ok) {
    exit_code = fail("failed to read native image for interpreter smoke");
    goto cleanup;
  }

  image = clasp_rt_json_from_string(read_result->value);
  if (!clasp_rt_native_image_validate(image)) {
    exit_code = fail("runtime rejected native image for interpreter smoke");
    goto cleanup;
  }

  loaded_image = clasp_rt_native_module_image_load(image);
  if (loaded_image == NULL) {
    exit_code = fail("runtime failed to load native image for interpreter smoke");
    goto cleanup;
  }

  if (!clasp_rt_activate_native_module_image(&runtime, loaded_image)) {
    exit_code = fail("runtime failed to activate native image for interpreter smoke");
    goto cleanup;
  }
  loaded_image = NULL;

  module_name = clasp_rt_string_from_utf8("Main");
  target_export = clasp_rt_string_from_utf8(export_name);
  if (arg_count == 1) {
    arg_value = clasp_rt_string_from_utf8(argv[4]);
    dispatch_args[0] = (ClaspRtHeader *) arg_value;
  }
  dispatch_value = clasp_rt_call_native_dispatch(&runtime, module_name, target_export, dispatch_args, arg_count);
  if (dispatch_value == NULL) {
    exit_code = fail("runtime failed to interpret native dispatch");
    goto cleanup;
  }

  dispatch_result = (ClaspRtString *) dispatch_value;
  if (!skip_exact_match && strcmp(dispatch_result->bytes, expected_value) != 0) {
    exit_code = fail("runtime returned an unexpected interpreted native dispatch result");
    goto cleanup;
  }

  printf("interpreted_call[%s]=%s\n", export_name, dispatch_result->bytes);
  exit_code = 0;

cleanup:
  clasp_rt_release(&runtime, (ClaspRtHeader *) dispatch_value);
  clasp_rt_release(&runtime, (ClaspRtHeader *) arg_value);
  clasp_rt_release(&runtime, (ClaspRtHeader *) target_export);
  clasp_rt_release(&runtime, (ClaspRtHeader *) module_name);
  clasp_rt_native_module_image_free(&runtime, loaded_image);
  clasp_rt_release(&runtime, (ClaspRtHeader *) image);
  clasp_rt_release(&runtime, (ClaspRtHeader *) read_result);
  clasp_rt_release(&runtime, (ClaspRtHeader *) path);
  clasp_rt_shutdown(&runtime);
  return exit_code;
}
