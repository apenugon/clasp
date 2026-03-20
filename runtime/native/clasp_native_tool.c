#include "clasp_runtime.h"

#include <stdio.h>
#include <string.h>

static int fail(const char *message) {
  fprintf(stderr, "%s\n", message);
  return 1;
}

int main(int argc, char **argv) {
  ClaspRtRuntime runtime = {0};
  ClaspRtString *image_path = NULL;
  ClaspRtResultString *image_read_result = NULL;
  ClaspRtJson *image = NULL;
  ClaspRtResultString *module_name_result = NULL;
  ClaspRtNativeModuleImage *loaded_image = NULL;
  ClaspRtString *module_name = NULL;
  ClaspRtString *target_export = NULL;
  ClaspRtString *source_path = NULL;
  ClaspRtResultString *source_read_result = NULL;
  ClaspRtHeader *dispatch_args[1] = {NULL};
  size_t dispatch_arg_count = 0;
  ClaspRtHeader *dispatch_value = NULL;
  ClaspRtString *dispatch_result = NULL;
  FILE *output_file = NULL;
  int exit_code = 1;

  if (argc != 4 && argc != 5) {
    fprintf(stderr, "usage: %s <module.native.image.json> <export> [source.clasp] <output>\n", argv[0]);
    return 2;
  }

  clasp_rt_init(&runtime);

  image_path = clasp_rt_string_from_utf8(argv[1]);
  image_read_result = clasp_rt_read_file(image_path);
  if (!image_read_result->is_ok) {
    exit_code = fail("failed to read native compiler image");
    goto cleanup;
  }

  image = clasp_rt_json_from_string(image_read_result->value);
  if (!clasp_rt_native_image_validate(image)) {
    exit_code = fail("runtime rejected native compiler image");
    goto cleanup;
  }

  module_name_result = clasp_rt_native_image_module_name(image);
  if (!module_name_result->is_ok) {
    exit_code = fail("runtime failed to resolve native compiler image module name");
    goto cleanup;
  }
  module_name = module_name_result->value;
  clasp_rt_retain((ClaspRtHeader *) module_name);

  loaded_image = clasp_rt_native_module_image_load(image);
  if (loaded_image == NULL) {
    exit_code = fail("runtime failed to load native compiler image");
    goto cleanup;
  }

  if (!clasp_rt_activate_native_module_image(&runtime, loaded_image)) {
    exit_code = fail("runtime failed to activate native compiler image");
    goto cleanup;
  }
  loaded_image = NULL;

  target_export = clasp_rt_string_from_utf8(argv[2]);
  if (argc == 5) {
    source_path = clasp_rt_string_from_utf8(argv[3]);
    source_read_result = clasp_rt_read_file(source_path);
    if (!source_read_result->is_ok) {
      exit_code = fail("failed to read hosted compiler source input");
      goto cleanup;
    }
    dispatch_args[0] = (ClaspRtHeader *) source_read_result->value;
    dispatch_arg_count = 1;
  }
  dispatch_value = clasp_rt_call_native_dispatch(&runtime, module_name, target_export, dispatch_args, dispatch_arg_count);
  if (dispatch_value == NULL) {
    exit_code = fail("runtime failed to execute native compiler export");
    goto cleanup;
  }

  dispatch_result = (ClaspRtString *) dispatch_value;
  output_file = fopen(argv[argc - 1], "wb");
  if (output_file == NULL) {
    exit_code = fail("failed to open hosted compiler result path");
    goto cleanup;
  }

  if (dispatch_result->byte_length > 0 &&
      fwrite(dispatch_result->bytes, 1, dispatch_result->byte_length, output_file) != dispatch_result->byte_length) {
    exit_code = fail("failed to write hosted compiler result");
    goto cleanup;
  }

  if (fclose(output_file) != 0) {
    output_file = NULL;
    exit_code = fail("failed to close hosted compiler result");
    goto cleanup;
  }
  output_file = NULL;
  exit_code = 0;

cleanup:
  if (output_file != NULL) {
    fclose(output_file);
  }
  clasp_rt_release(&runtime, (ClaspRtHeader *) dispatch_value);
  clasp_rt_release(&runtime, (ClaspRtHeader *) source_read_result);
  clasp_rt_release(&runtime, (ClaspRtHeader *) source_path);
  clasp_rt_release(&runtime, (ClaspRtHeader *) target_export);
  clasp_rt_native_module_image_free(&runtime, loaded_image);
  clasp_rt_release(&runtime, (ClaspRtHeader *) module_name);
  clasp_rt_release(&runtime, (ClaspRtHeader *) module_name_result);
  clasp_rt_release(&runtime, (ClaspRtHeader *) image);
  clasp_rt_release(&runtime, (ClaspRtHeader *) image_read_result);
  clasp_rt_release(&runtime, (ClaspRtHeader *) image_path);
  clasp_rt_shutdown(&runtime);
  return exit_code;
}
