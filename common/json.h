/* Minimal JSON reader and writer.
 *
 * Hand-written rather than vendored: the harness needs only object, array,
 * string, number, bool and null, and a self-contained implementation keeps
 * the tree free of third-party source and its licence bookkeeping.
 */
#ifndef HARNESS_JSON_H
#define HARNESS_JSON_H

#include <stdbool.h>
#include <stddef.h>

typedef enum {
    JSON_NULL,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_STRING,
    JSON_ARRAY,
    JSON_OBJECT
} JsonType;

typedef struct JsonValue JsonValue;

struct JsonValue {
    JsonType type;
    /* JSON_BOOL */
    bool boolean;
    /* JSON_NUMBER */
    double number;
    /* JSON_STRING: NUL-terminated, but length is authoritative because
     * decoded strings may legitimately contain NUL. */
    char *string;
    size_t string_len;
    /* JSON_ARRAY and JSON_OBJECT: children as a linked list. Object children
     * carry a key; array children do not. */
    JsonValue *first_child;
    JsonValue *last_child;
    JsonValue *next_sibling;
    char *key;
};

/* Parses NUL-terminated JSON text. Returns NULL on malformed input. */
JsonValue *json_parse(const char *text);

/* Parses at most len bytes, stopping at the end of the first complete value. */
JsonValue *json_parse_len(const char *text, size_t len);

void json_free(JsonValue *value);

/* Object member lookup; NULL when absent or when value is not an object. */
const JsonValue *json_object_get(const JsonValue *object, const char *key);

/* Typed accessors returning the fallback when absent or of the wrong type. */
const char *json_string_or(const JsonValue *value, const char *key,
                           const char *fallback);
double json_number_or(const JsonValue *value, const char *key, double fallback);
bool json_bool_or(const JsonValue *value, const char *key, bool fallback);

/* Array iteration. */
size_t json_array_size(const JsonValue *array);
const JsonValue *json_array_at(const JsonValue *array, size_t index);

/* Growable output buffer used by the writer and by output capture. */
typedef struct {
    char *data;
    size_t len;
    size_t cap;
} Buffer;

void buffer_init(Buffer *buffer);
void buffer_free(Buffer *buffer);
bool buffer_append(Buffer *buffer, const char *bytes, size_t len);
bool buffer_append_str(Buffer *buffer, const char *text);
bool buffer_printf(Buffer *buffer, const char *format, ...);
void buffer_reset(Buffer *buffer);

/* Appends text as a quoted, escaped JSON string. Control characters and any
 * invalid UTF-8 are escaped so the result is always parseable. */
bool json_write_string(Buffer *out, const char *text, size_t len);

/* Appends a number in a round-trippable form, writing integers without a
 * decimal point so exit codes and step counts read naturally. */
bool json_write_number(Buffer *out, double number);

#endif /* HARNESS_JSON_H */
