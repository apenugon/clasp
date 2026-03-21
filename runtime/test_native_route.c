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
  ClaspRtString *method = NULL;
  ClaspRtString *route_path = NULL;
  ClaspRtString *request_body = NULL;
  ClaspRtJson *request_json = NULL;
  ClaspRtResultString *response = NULL;
  int exit_code = 1;

  if (argc != 2) {
    fprintf(stderr, "usage: %s <module.native.image.json>\n", argv[0]);
    return 2;
  }

  clasp_rt_init(&runtime);

  path = clasp_rt_string_from_utf8(argv[1]);
  read_result = clasp_rt_read_file(path);
  if (read_result == NULL || !read_result->is_ok) {
    exit_code = fail("failed to read native route image");
    goto cleanup;
  }

  image = clasp_rt_json_from_string(read_result->value);
  if (!clasp_rt_native_image_validate(image)) {
    exit_code = fail("runtime rejected native route image");
    goto cleanup;
  }

  loaded_image = clasp_rt_native_module_image_load(image);
  if (loaded_image == NULL) {
    exit_code = fail("runtime failed to load native route image");
    goto cleanup;
  }

  if (!clasp_rt_activate_native_module_image(&runtime, loaded_image)) {
    exit_code = fail("runtime failed to activate native route image");
    goto cleanup;
  }
  loaded_image = NULL;

  module_name = clasp_rt_string_from_utf8("Main");
  method = clasp_rt_string_from_utf8("POST");
  route_path = clasp_rt_string_from_utf8("/lead/summary");
  request_body = clasp_rt_string_from_utf8("{\"company\":\"Acme\"}");
  request_json = clasp_rt_json_from_string(request_body);
  response = clasp_rt_call_native_route_json(&runtime, module_name, method, route_path, request_json);
  if (response == NULL || !response->is_ok) {
    exit_code = fail("runtime failed to dispatch native route");
    goto cleanup;
  }

  if (strcmp(response->value->bytes, "{\"summary\":\"Acme\"}") != 0) {
    exit_code = fail("unexpected native route response");
    goto cleanup;
  }

  printf("native_route_response=%s\n", response->value->bytes);
  exit_code = 0;

cleanup:
  clasp_rt_release(&runtime, (ClaspRtHeader *) response);
  clasp_rt_release(&runtime, (ClaspRtHeader *) request_json);
  clasp_rt_release(&runtime, (ClaspRtHeader *) request_body);
  clasp_rt_release(&runtime, (ClaspRtHeader *) route_path);
  clasp_rt_release(&runtime, (ClaspRtHeader *) method);
  clasp_rt_release(&runtime, (ClaspRtHeader *) module_name);
  clasp_rt_native_module_image_free(&runtime, loaded_image);
  clasp_rt_release(&runtime, (ClaspRtHeader *) image);
  clasp_rt_release(&runtime, (ClaspRtHeader *) read_result);
  clasp_rt_release(&runtime, (ClaspRtHeader *) path);
  clasp_rt_shutdown(&runtime);
  return exit_code;
}
