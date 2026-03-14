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
typedef struct ClaspRtStringList ClaspRtStringList;
typedef struct ClaspRtResultString ClaspRtResultString;
typedef struct ClaspRtObject ClaspRtObject;

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
};

struct ClaspRtString {
  ClaspRtHeader header;
  size_t byte_length;
  char *bytes;
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
void clasp_rt_register_static_root(ClaspRtRuntime *runtime, ClaspRtHeader **slot);
ClaspRtObject *clasp_rt_alloc_object(const ClaspRtObjectLayout *layout);
void clasp_rt_retain(ClaspRtHeader *header);
void clasp_rt_release(ClaspRtRuntime *runtime, ClaspRtHeader *header);

ClaspRtString *clasp_rt_string_from_utf8(const char *value);
ClaspRtStringList *clasp_rt_string_list_new(size_t length);
ClaspRtResultString *clasp_rt_result_ok_string(ClaspRtString *value);
ClaspRtResultString *clasp_rt_result_err_string(ClaspRtString *value);
ClaspRtJson *clasp_rt_json_from_string(ClaspRtString *value);
ClaspRtString *clasp_rt_json_to_string(ClaspRtJson *value);

ClaspRtString *clasp_rt_text_concat(ClaspRtStringList *parts);
ClaspRtString *clasp_rt_text_join(ClaspRtString *separator, ClaspRtStringList *parts);
ClaspRtStringList *clasp_rt_text_split(ClaspRtString *value, ClaspRtString *separator);
ClaspRtResultString *clasp_rt_text_prefix(ClaspRtString *value, ClaspRtString *prefix);
ClaspRtResultString *clasp_rt_text_split_first(ClaspRtString *value, ClaspRtString *separator);
ClaspRtString *clasp_rt_path_join(ClaspRtStringList *parts);
ClaspRtString *clasp_rt_path_dirname(ClaspRtString *path);
ClaspRtString *clasp_rt_path_basename(ClaspRtString *path);
bool clasp_rt_file_exists(ClaspRtString *path);
ClaspRtResultString *clasp_rt_read_file(ClaspRtString *path);

#endif
