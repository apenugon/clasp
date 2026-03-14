#include "clasp_runtime.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
  CLASP_RT_LAYOUT_STRING = 1,
  CLASP_RT_LAYOUT_STRING_LIST = 2,
  CLASP_RT_LAYOUT_RESULT_STRING = 3,
  CLASP_RT_LAYOUT_GENERIC_OBJECT = 4
};

static void clasp_rt_abort_oom(void) {
  fputs("clasp native runtime: out of memory\n", stderr);
  abort();
}

static void *clasp_rt_alloc_bytes(size_t size) {
  void *memory = calloc(1, size);
  if (memory == NULL) {
    clasp_rt_abort_oom();
  }
  return memory;
}

static char *clasp_rt_dup_bytes(const char *value, size_t length) {
  char *copy = clasp_rt_alloc_bytes(length + 1u);
  memcpy(copy, value, length);
  copy[length] = '\0';
  return copy;
}

static void clasp_rt_destroy_string(ClaspRtRuntime *runtime, ClaspRtHeader *header);
static void clasp_rt_destroy_string_list(ClaspRtRuntime *runtime, ClaspRtHeader *header);
static void clasp_rt_destroy_result_string(ClaspRtRuntime *runtime, ClaspRtHeader *header);
static void clasp_rt_destroy_object(ClaspRtRuntime *runtime, ClaspRtHeader *header);

void clasp_rt_init(ClaspRtRuntime *runtime) {
  runtime->static_root_count = 0;
  runtime->static_roots = NULL;
}

void clasp_rt_register_static_root(ClaspRtRuntime *runtime, ClaspRtHeader **slot) {
  size_t next_count = runtime->static_root_count + 1u;
  ClaspRtHeader ***next_roots =
    realloc(runtime->static_roots, next_count * sizeof(*runtime->static_roots));
  if (next_roots == NULL) {
    clasp_rt_abort_oom();
  }

  runtime->static_roots = next_roots;
  runtime->static_roots[runtime->static_root_count] = slot;
  runtime->static_root_count = next_count;
}

ClaspRtObject *clasp_rt_alloc_object(const ClaspRtObjectLayout *layout) {
  size_t bytes = sizeof(ClaspRtObject) + (layout->word_count * sizeof(uintptr_t));
  ClaspRtObject *object = clasp_rt_alloc_bytes(bytes);
  object->header.layout_id = CLASP_RT_LAYOUT_GENERIC_OBJECT;
  object->header.retain_count = 1;
  object->header.destroy = clasp_rt_destroy_object;
  object->layout = layout;
  return object;
}

void clasp_rt_retain(ClaspRtHeader *header) {
  if (header != NULL) {
    header->retain_count += 1u;
  }
}

void clasp_rt_release(ClaspRtRuntime *runtime, ClaspRtHeader *header) {
  if (header == NULL) {
    return;
  }

  if (header->retain_count > 1u) {
    header->retain_count -= 1u;
    return;
  }

  if (header->destroy != NULL) {
    header->destroy(runtime, header);
  }
}

ClaspRtString *clasp_rt_string_from_utf8(const char *value) {
  size_t length = strlen(value);
  ClaspRtString *string = clasp_rt_alloc_bytes(sizeof(ClaspRtString));
  string->header.layout_id = CLASP_RT_LAYOUT_STRING;
  string->header.retain_count = 1;
  string->header.destroy = clasp_rt_destroy_string;
  string->byte_length = length;
  string->bytes = clasp_rt_dup_bytes(value, length);
  return string;
}

ClaspRtStringList *clasp_rt_string_list_new(size_t length) {
  ClaspRtStringList *list = clasp_rt_alloc_bytes(sizeof(ClaspRtStringList));
  list->header.layout_id = CLASP_RT_LAYOUT_STRING_LIST;
  list->header.retain_count = 1;
  list->header.destroy = clasp_rt_destroy_string_list;
  list->length = length;
  list->items = clasp_rt_alloc_bytes(length * sizeof(*list->items));
  return list;
}

ClaspRtResultString *clasp_rt_result_ok_string(ClaspRtString *value) {
  ClaspRtResultString *result = clasp_rt_alloc_bytes(sizeof(ClaspRtResultString));
  result->header.layout_id = CLASP_RT_LAYOUT_RESULT_STRING;
  result->header.retain_count = 1;
  result->header.destroy = clasp_rt_destroy_result_string;
  result->is_ok = true;
  result->value = value;
  clasp_rt_retain((ClaspRtHeader *) value);
  return result;
}

ClaspRtResultString *clasp_rt_result_err_string(ClaspRtString *value) {
  ClaspRtResultString *result = clasp_rt_result_ok_string(value);
  result->is_ok = false;
  return result;
}

ClaspRtJson *clasp_rt_json_from_string(ClaspRtString *value) {
  clasp_rt_retain((ClaspRtHeader *) value);
  return (ClaspRtJson *) value;
}

ClaspRtString *clasp_rt_json_to_string(ClaspRtJson *value) {
  clasp_rt_retain((ClaspRtHeader *) value);
  return (ClaspRtString *) value;
}

ClaspRtString *clasp_rt_text_concat(ClaspRtStringList *parts) {
  return clasp_rt_text_join(clasp_rt_string_from_utf8(""), parts);
}

ClaspRtString *clasp_rt_text_join(ClaspRtString *separator, ClaspRtStringList *parts) {
  size_t separator_length = separator == NULL ? 0 : separator->byte_length;
  size_t total_length = 0;

  for (size_t index = 0; index < parts->length; index += 1u) {
    total_length += parts->items[index] == NULL ? 0 : parts->items[index]->byte_length;
    if (index + 1u < parts->length) {
      total_length += separator_length;
    }
  }

  char *buffer = clasp_rt_alloc_bytes(total_length + 1u);
  size_t offset = 0;

  for (size_t index = 0; index < parts->length; index += 1u) {
    ClaspRtString *part = parts->items[index];
    if (part != NULL && part->byte_length > 0u) {
      memcpy(buffer + offset, part->bytes, part->byte_length);
      offset += part->byte_length;
    }

    if (index + 1u < parts->length && separator_length > 0u) {
      memcpy(buffer + offset, separator->bytes, separator_length);
      offset += separator_length;
    }
  }

  ClaspRtString *result = clasp_rt_string_from_utf8(buffer);
  free(buffer);
  return result;
}

ClaspRtStringList *clasp_rt_text_split(ClaspRtString *value, ClaspRtString *separator) {
  if (separator == NULL || separator->byte_length == 0u) {
    ClaspRtStringList *single = clasp_rt_string_list_new(1u);
    single->items[0] = clasp_rt_string_from_utf8(value->bytes);
    return single;
  }

  size_t count = 1u;
  const char *cursor = value->bytes;
  while ((cursor = strstr(cursor, separator->bytes)) != NULL) {
    count += 1u;
    cursor += separator->byte_length;
  }

  ClaspRtStringList *parts = clasp_rt_string_list_new(count);
  const char *segment_start = value->bytes;
  size_t part_index = 0u;
  const char *match = NULL;

  while ((match = strstr(segment_start, separator->bytes)) != NULL) {
    size_t segment_length = (size_t) (match - segment_start);
    parts->items[part_index] =
      clasp_rt_string_from_utf8(clasp_rt_dup_bytes(segment_start, segment_length));
    free(parts->items[part_index]->bytes);
    parts->items[part_index]->bytes = clasp_rt_dup_bytes(segment_start, segment_length);
    parts->items[part_index]->byte_length = segment_length;
    part_index += 1u;
    segment_start = match + separator->byte_length;
  }

  parts->items[part_index] = clasp_rt_string_from_utf8(segment_start);
  return parts;
}

ClaspRtResultString *clasp_rt_text_prefix(ClaspRtString *value, ClaspRtString *prefix) {
  if (prefix->byte_length <= value->byte_length &&
      strncmp(value->bytes, prefix->bytes, prefix->byte_length) == 0) {
    const char *suffix = value->bytes + prefix->byte_length;
    return clasp_rt_result_ok_string(clasp_rt_string_from_utf8(suffix));
  }

  return clasp_rt_result_err_string(clasp_rt_string_from_utf8(value->bytes));
}

ClaspRtResultString *clasp_rt_text_split_first(ClaspRtString *value, ClaspRtString *separator) {
  const char *match = strstr(value->bytes, separator->bytes);
  if (match == NULL) {
    return clasp_rt_result_err_string(clasp_rt_string_from_utf8(value->bytes));
  }

  const char *suffix = match + separator->byte_length;
  return clasp_rt_result_ok_string(clasp_rt_string_from_utf8(suffix));
}

ClaspRtString *clasp_rt_path_join(ClaspRtStringList *parts) {
  return clasp_rt_text_join(clasp_rt_string_from_utf8("/"), parts);
}

ClaspRtString *clasp_rt_path_dirname(ClaspRtString *path) {
  const char *slash = strrchr(path->bytes, '/');
  if (slash == NULL) {
    return clasp_rt_string_from_utf8(".");
  }

  size_t length = (size_t) (slash - path->bytes);
  char *buffer = clasp_rt_dup_bytes(path->bytes, length);
  ClaspRtString *result = clasp_rt_string_from_utf8(buffer);
  free(buffer);
  return result;
}

ClaspRtString *clasp_rt_path_basename(ClaspRtString *path) {
  const char *slash = strrchr(path->bytes, '/');
  return clasp_rt_string_from_utf8(slash == NULL ? path->bytes : slash + 1);
}

bool clasp_rt_file_exists(ClaspRtString *path) {
  FILE *handle = fopen(path->bytes, "rb");
  if (handle == NULL) {
    return false;
  }

  fclose(handle);
  return true;
}

ClaspRtResultString *clasp_rt_read_file(ClaspRtString *path) {
  FILE *handle = fopen(path->bytes, "rb");
  if (handle == NULL) {
    return clasp_rt_result_err_string(clasp_rt_string_from_utf8("missing"));
  }

  if (fseek(handle, 0, SEEK_END) != 0) {
    fclose(handle);
    return clasp_rt_result_err_string(clasp_rt_string_from_utf8("io_error"));
  }

  long file_size = ftell(handle);
  if (file_size < 0 || fseek(handle, 0, SEEK_SET) != 0) {
    fclose(handle);
    return clasp_rt_result_err_string(clasp_rt_string_from_utf8("io_error"));
  }

  char *buffer = clasp_rt_alloc_bytes((size_t) file_size + 1u);
  size_t bytes_read = fread(buffer, 1u, (size_t) file_size, handle);
  fclose(handle);
  buffer[bytes_read] = '\0';

  ClaspRtResultString *result =
    clasp_rt_result_ok_string(clasp_rt_string_from_utf8(buffer));
  free(buffer);
  return result;
}

static void clasp_rt_destroy_string(ClaspRtRuntime *runtime, ClaspRtHeader *header) {
  (void) runtime;
  ClaspRtString *string = (ClaspRtString *) header;
  free(string->bytes);
  free(string);
}

static void clasp_rt_destroy_string_list(ClaspRtRuntime *runtime, ClaspRtHeader *header) {
  ClaspRtStringList *list = (ClaspRtStringList *) header;
  for (size_t index = 0; index < list->length; index += 1u) {
    clasp_rt_release(runtime, (ClaspRtHeader *) list->items[index]);
  }

  free(list->items);
  free(list);
}

static void clasp_rt_destroy_result_string(ClaspRtRuntime *runtime, ClaspRtHeader *header) {
  ClaspRtResultString *result = (ClaspRtResultString *) header;
  clasp_rt_release(runtime, (ClaspRtHeader *) result->value);
  free(result);
}

static void clasp_rt_destroy_object(ClaspRtRuntime *runtime, ClaspRtHeader *header) {
  ClaspRtObject *object = (ClaspRtObject *) header;
  for (size_t index = 0; index < object->layout->root_count; index += 1u) {
    uint32_t offset = object->layout->root_offsets[index];
    clasp_rt_release(runtime, (ClaspRtHeader *) (uintptr_t) object->words[offset]);
  }

  free(object);
}
