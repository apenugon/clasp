#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../runtime/clasp_runtime.h"

static char *read_file(const char *path) {
  FILE *file = fopen(path, "rb");
  if (file == NULL) {
    fprintf(stderr, "failed to open %s\n", path);
    exit(1);
  }

  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    fprintf(stderr, "failed to seek %s\n", path);
    exit(1);
  }

  long length = ftell(file);
  if (length < 0) {
    fclose(file);
    fprintf(stderr, "failed to size %s\n", path);
    exit(1);
  }

  rewind(file);

  char *buffer = calloc((size_t) length + 1u, 1u);
  if (buffer == NULL) {
    fclose(file);
    fprintf(stderr, "failed to allocate input buffer\n");
    exit(1);
  }

  size_t read = fread(buffer, 1u, (size_t) length, file);
  fclose(file);

  if (read != (size_t) length) {
    free(buffer);
    fprintf(stderr, "failed to read %s\n", path);
    exit(1);
  }

  buffer[length] = '\0';
  return buffer;
}

static uint64_t run_compiler_source_text(
  ClaspRtRuntime *runtime,
  const char *input_text,
  int iterations
) {
  uint64_t checksum = 0u;
  ClaspRtString *source = clasp_rt_string_from_utf8(input_text);
  ClaspRtString *split_separator = clasp_rt_string_from_utf8("\n");
  ClaspRtString *join_separator = clasp_rt_string_from_utf8("::");
  ClaspRtString *prefix = clasp_rt_string_from_utf8("module");

  for (int index = 0; index < iterations; index += 1) {
    ClaspRtStringList *parts = clasp_rt_text_split(source, split_separator);
    ClaspRtString *joined = clasp_rt_text_join(join_separator, parts);
    ClaspRtResultString *prefix_result = clasp_rt_text_prefix(joined, prefix);

    checksum +=
      (uint64_t) joined->byte_length +
      (uint64_t) parts->length +
      (uint64_t) (prefix_result->is_ok ? 1u : 0u);

    clasp_rt_release(runtime, (ClaspRtHeader *) prefix_result);
    clasp_rt_release(runtime, (ClaspRtHeader *) joined);
    clasp_rt_release(runtime, (ClaspRtHeader *) parts);
  }

  clasp_rt_release(runtime, (ClaspRtHeader *) prefix);
  clasp_rt_release(runtime, (ClaspRtHeader *) join_separator);
  clasp_rt_release(runtime, (ClaspRtHeader *) split_separator);
  clasp_rt_release(runtime, (ClaspRtHeader *) source);

  return checksum;
}

static uint64_t run_boundary_transport(
  ClaspRtRuntime *runtime,
  const char *input_text,
  int iterations
) {
  uint64_t checksum = 0u;
  ClaspRtString *payload = clasp_rt_string_from_utf8(input_text);

  for (int index = 0; index < iterations; index += 1) {
    ClaspRtJson *json = clasp_rt_json_from_string(payload);
    ClaspRtBytes *binary = clasp_rt_binary_from_json(json);
    ClaspRtBytes *frame = clasp_rt_transport_frame(binary);
    ClaspRtBytes *unframed = clasp_rt_transport_unframe(frame);
    ClaspRtJson *restored_json = clasp_rt_json_from_binary(unframed);
    ClaspRtString *restored = clasp_rt_json_to_string(restored_json);

    checksum +=
      (uint64_t) restored->byte_length +
      (uint64_t) frame->byte_length;

    clasp_rt_release(runtime, (ClaspRtHeader *) restored);
    clasp_rt_release(runtime, (ClaspRtHeader *) restored_json);
    clasp_rt_release(runtime, (ClaspRtHeader *) unframed);
    clasp_rt_release(runtime, (ClaspRtHeader *) frame);
    clasp_rt_release(runtime, (ClaspRtHeader *) binary);
    clasp_rt_release(runtime, (ClaspRtHeader *) json);
  }

  clasp_rt_release(runtime, (ClaspRtHeader *) payload);
  return checksum;
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(
      stderr,
      "usage: runtime-bench <compiler-source-text|boundary-transport> <iterations> <input-path>\n"
    );
    return 1;
  }

  const char *workload = argv[1];
  int iterations = atoi(argv[2]);
  if (iterations <= 0) {
    fprintf(stderr, "iterations must be positive\n");
    return 1;
  }

  char *input_text = read_file(argv[3]);
  ClaspRtRuntime runtime = {0};
  clasp_rt_init(&runtime);

  uint64_t checksum = 0u;
  if (strcmp(workload, "compiler-source-text") == 0) {
    checksum = run_compiler_source_text(&runtime, input_text, iterations);
  } else if (strcmp(workload, "boundary-transport") == 0) {
    checksum = run_boundary_transport(&runtime, input_text, iterations);
  } else {
    fprintf(stderr, "unknown workload: %s\n", workload);
    clasp_rt_shutdown(&runtime);
    free(input_text);
    return 1;
  }

  printf(
    "{\"workload\":\"%s\",\"iterations\":%d,\"checksum\":%llu}\n",
    workload,
    iterations,
    (unsigned long long) checksum
  );

  clasp_rt_shutdown(&runtime);
  free(input_text);
  return 0;
}
