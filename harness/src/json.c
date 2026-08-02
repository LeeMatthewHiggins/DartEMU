#include "json.h"

#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { BUFFER_MIN_CAP = 128, NUMBER_TEXT_MAX = 40, UNICODE_ESCAPE_LEN = 6 };

/* ---------------------------------------------------------------- buffer */

void buffer_init(Buffer *buffer) {
    buffer->data = NULL;
    buffer->len = 0;
    buffer->cap = 0;
}

void buffer_free(Buffer *buffer) {
    free(buffer->data);
    buffer_init(buffer);
}

void buffer_reset(Buffer *buffer) {
    buffer->len = 0;
    if (buffer->data != NULL) {
        buffer->data[0] = '\0';
    }
}

static bool buffer_reserve(Buffer *buffer, size_t extra) {
    size_t needed = buffer->len + extra + 1;
    if (needed <= buffer->cap) {
        return true;
    }
    size_t cap = buffer->cap == 0 ? BUFFER_MIN_CAP : buffer->cap;
    while (cap < needed) {
        if (cap > SIZE_MAX / 2) {
            return false;
        }
        cap *= 2;
    }
    char *grown = realloc(buffer->data, cap);
    if (grown == NULL) {
        return false;
    }
    buffer->data = grown;
    buffer->cap = cap;
    /* Keep the buffer a valid C string at all times. Without this an empty
     * buffer hands back whatever realloc happened to return, which reads as
     * zeroed memory on some allocators and as garbage on others. */
    buffer->data[buffer->len] = '\0';
    return true;
}

bool buffer_append(Buffer *buffer, const char *bytes, size_t len) {
    if (len == 0) {
        return buffer_reserve(buffer, 0);
    }
    if (!buffer_reserve(buffer, len)) {
        return false;
    }
    memcpy(buffer->data + buffer->len, bytes, len);
    buffer->len += len;
    buffer->data[buffer->len] = '\0';
    return true;
}

bool buffer_append_str(Buffer *buffer, const char *text) {
    return buffer_append(buffer, text, strlen(text));
}

bool buffer_printf(Buffer *buffer, const char *format, ...) {
    va_list args;
    va_start(args, format);
    va_list probe;
    va_copy(probe, args);
    int needed = vsnprintf(NULL, 0, format, probe);
    va_end(probe);
    if (needed < 0) {
        va_end(args);
        return false;
    }
    if (!buffer_reserve(buffer, (size_t)needed)) {
        va_end(args);
        return false;
    }
    vsnprintf(buffer->data + buffer->len, (size_t)needed + 1, format, args);
    va_end(args);
    buffer->len += (size_t)needed;
    return true;
}

/* ---------------------------------------------------------------- writer */

static bool write_unicode_escape(Buffer *out, unsigned code_unit) {
    char escape[UNICODE_ESCAPE_LEN + 1];
    snprintf(escape, sizeof(escape), "\\u%04x", code_unit);
    return buffer_append(out, escape, UNICODE_ESCAPE_LEN);
}

/* Length of the UTF-8 sequence starting at s, or 0 when it is not valid.
 * Invalid bytes are escaped individually rather than copied through, so the
 * writer can never emit a string that a strict parser would reject. */
static size_t utf8_sequence_len(const unsigned char *s, size_t remaining) {
    unsigned char lead = s[0];
    size_t len;
    if (lead < 0x80u) {
        return 1;
    }
    if ((lead & 0xE0u) == 0xC0u) {
        len = 2;
    } else if ((lead & 0xF0u) == 0xE0u) {
        len = 3;
    } else if ((lead & 0xF8u) == 0xF0u) {
        len = 4;
    } else {
        return 0;
    }
    if (len > remaining) {
        return 0;
    }
    for (size_t i = 1; i < len; i++) {
        if ((s[i] & 0xC0u) != 0x80u) {
            return 0;
        }
    }
    return len;
}

bool json_write_string(Buffer *out, const char *text, size_t len) {
    if (!buffer_append(out, "\"", 1)) {
        return false;
    }
    const unsigned char *bytes = (const unsigned char *)text;
    for (size_t i = 0; i < len;) {
        unsigned char c = bytes[i];
        const char *shortcut = NULL;
        switch (c) {
            case '"': shortcut = "\\\""; break;
            case '\\': shortcut = "\\\\"; break;
            case '\n': shortcut = "\\n"; break;
            case '\r': shortcut = "\\r"; break;
            case '\t': shortcut = "\\t"; break;
            case '\b': shortcut = "\\b"; break;
            case '\f': shortcut = "\\f"; break;
            default: break;
        }
        if (shortcut != NULL) {
            if (!buffer_append_str(out, shortcut)) {
                return false;
            }
            i++;
            continue;
        }
        if (c < 0x20u) {
            if (!write_unicode_escape(out, c)) {
                return false;
            }
            i++;
            continue;
        }
        size_t seq = utf8_sequence_len(bytes + i, len - i);
        if (seq == 0) {
            /* Guest output is arbitrary bytes and need not be valid UTF-8. */
            if (!write_unicode_escape(out, 0xFFFDu)) {
                return false;
            }
            i++;
            continue;
        }
        if (!buffer_append(out, (const char *)(bytes + i), seq)) {
            return false;
        }
        i += seq;
    }
    return buffer_append(out, "\"", 1);
}

bool json_write_number(Buffer *out, double number) {
    if (!isfinite(number)) {
        return buffer_append_str(out, "null");
    }
    if (number == (double)(long long)number) {
        return buffer_printf(out, "%lld", (long long)number);
    }
    return buffer_printf(out, "%.17g", number);
}

/* ---------------------------------------------------------------- parser */

typedef struct {
    const char *text;
    size_t len;
    size_t pos;
    bool failed;
} Parser;

static JsonValue *parse_value(Parser *p);

static JsonValue *value_new(JsonType type) {
    JsonValue *value = calloc(1, sizeof(JsonValue));
    if (value != NULL) {
        value->type = type;
    }
    return value;
}

static void append_child(JsonValue *parent, JsonValue *child) {
    if (parent->last_child == NULL) {
        parent->first_child = child;
    } else {
        parent->last_child->next_sibling = child;
    }
    parent->last_child = child;
}

static void skip_whitespace(Parser *p) {
    while (p->pos < p->len) {
        char c = p->text[p->pos];
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
            break;
        }
        p->pos++;
    }
}

static bool consume(Parser *p, char expected) {
    if (p->pos < p->len && p->text[p->pos] == expected) {
        p->pos++;
        return true;
    }
    p->failed = true;
    return false;
}

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool encode_utf8(Buffer *out, unsigned code_point) {
    char seq[4];
    size_t len;
    if (code_point < 0x80u) {
        seq[0] = (char)code_point;
        len = 1;
    } else if (code_point < 0x800u) {
        seq[0] = (char)(0xC0u | (code_point >> 6));
        seq[1] = (char)(0x80u | (code_point & 0x3Fu));
        len = 2;
    } else if (code_point < 0x10000u) {
        seq[0] = (char)(0xE0u | (code_point >> 12));
        seq[1] = (char)(0x80u | ((code_point >> 6) & 0x3Fu));
        seq[2] = (char)(0x80u | (code_point & 0x3Fu));
        len = 3;
    } else {
        seq[0] = (char)(0xF0u | (code_point >> 18));
        seq[1] = (char)(0x80u | ((code_point >> 12) & 0x3Fu));
        seq[2] = (char)(0x80u | ((code_point >> 6) & 0x3Fu));
        seq[3] = (char)(0x80u | (code_point & 0x3Fu));
        len = 4;
    }
    return buffer_append(out, seq, len);
}

static bool parse_hex4(Parser *p, unsigned *out) {
    if (p->pos + 4 > p->len) {
        return false;
    }
    unsigned value = 0;
    for (int i = 0; i < 4; i++) {
        int digit = hex_digit(p->text[p->pos + (size_t)i]);
        if (digit < 0) {
            return false;
        }
        value = (value << 4) | (unsigned)digit;
    }
    p->pos += 4;
    *out = value;
    return true;
}

static bool parse_escape(Parser *p, Buffer *out) {
    if (p->pos >= p->len) {
        return false;
    }
    char c = p->text[p->pos++];
    switch (c) {
        case '"': return buffer_append(out, "\"", 1);
        case '\\': return buffer_append(out, "\\", 1);
        case '/': return buffer_append(out, "/", 1);
        case 'b': return buffer_append(out, "\b", 1);
        case 'f': return buffer_append(out, "\f", 1);
        case 'n': return buffer_append(out, "\n", 1);
        case 'r': return buffer_append(out, "\r", 1);
        case 't': return buffer_append(out, "\t", 1);
        case 'u': break;
        default: return false;
    }

    unsigned code_unit;
    if (!parse_hex4(p, &code_unit)) {
        return false;
    }
    if (code_unit >= 0xD800u && code_unit <= 0xDBFFu) {
        /* High surrogate: pair it when the low half follows. */
        if (p->pos + 1 < p->len && p->text[p->pos] == '\\' &&
            p->text[p->pos + 1] == 'u') {
            size_t saved = p->pos;
            p->pos += 2;
            unsigned low;
            if (parse_hex4(p, &low) && low >= 0xDC00u && low <= 0xDFFFu) {
                unsigned combined = 0x10000u + ((code_unit - 0xD800u) << 10) +
                                    (low - 0xDC00u);
                return encode_utf8(out, combined);
            }
            p->pos = saved;
        }
        return encode_utf8(out, 0xFFFDu);
    }
    if (code_unit >= 0xDC00u && code_unit <= 0xDFFFu) {
        return encode_utf8(out, 0xFFFDu);
    }
    return encode_utf8(out, code_unit);
}

static bool parse_string_into(Parser *p, Buffer *out) {
    if (!consume(p, '"')) {
        return false;
    }
    while (p->pos < p->len) {
        char c = p->text[p->pos];
        if (c == '"') {
            p->pos++;
            return true;
        }
        if (c == '\\') {
            p->pos++;
            if (!parse_escape(p, out)) {
                return false;
            }
            continue;
        }
        if (!buffer_append(out, &c, 1)) {
            return false;
        }
        p->pos++;
    }
    return false;
}

static JsonValue *parse_string(Parser *p) {
    Buffer text;
    buffer_init(&text);
    if (!parse_string_into(p, &text)) {
        buffer_free(&text);
        p->failed = true;
        return NULL;
    }
    JsonValue *value = value_new(JSON_STRING);
    if (value == NULL) {
        buffer_free(&text);
        p->failed = true;
        return NULL;
    }
    if (text.data == NULL) {
        text.data = calloc(1, 1);
        if (text.data == NULL) {
            free(value);
            p->failed = true;
            return NULL;
        }
    }
    value->string = text.data;
    value->string_len = text.len;
    return value;
}

static JsonValue *parse_number(Parser *p) {
    size_t start = p->pos;
    if (p->pos < p->len && (p->text[p->pos] == '-' || p->text[p->pos] == '+')) {
        p->pos++;
    }
    bool digits = false;
    while (p->pos < p->len) {
        char c = p->text[p->pos];
        if ((c >= '0' && c <= '9')) {
            digits = true;
            p->pos++;
        } else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
            p->pos++;
        } else {
            break;
        }
    }
    if (!digits) {
        p->failed = true;
        return NULL;
    }
    char text[NUMBER_TEXT_MAX];
    size_t len = p->pos - start;
    if (len >= sizeof(text)) {
        p->failed = true;
        return NULL;
    }
    memcpy(text, p->text + start, len);
    text[len] = '\0';
    JsonValue *value = value_new(JSON_NUMBER);
    if (value == NULL) {
        p->failed = true;
        return NULL;
    }
    value->number = strtod(text, NULL);
    return value;
}

static JsonValue *parse_literal(Parser *p, const char *word, JsonType type,
                                bool boolean) {
    size_t len = strlen(word);
    if (p->pos + len > p->len || strncmp(p->text + p->pos, word, len) != 0) {
        p->failed = true;
        return NULL;
    }
    p->pos += len;
    JsonValue *value = value_new(type);
    if (value == NULL) {
        p->failed = true;
        return NULL;
    }
    value->boolean = boolean;
    return value;
}

static JsonValue *parse_array(Parser *p) {
    if (!consume(p, '[')) {
        return NULL;
    }
    JsonValue *array = value_new(JSON_ARRAY);
    if (array == NULL) {
        p->failed = true;
        return NULL;
    }
    skip_whitespace(p);
    if (p->pos < p->len && p->text[p->pos] == ']') {
        p->pos++;
        return array;
    }
    for (;;) {
        JsonValue *item = parse_value(p);
        if (item == NULL) {
            json_free(array);
            return NULL;
        }
        append_child(array, item);
        skip_whitespace(p);
        if (p->pos < p->len && p->text[p->pos] == ',') {
            p->pos++;
            continue;
        }
        if (p->pos < p->len && p->text[p->pos] == ']') {
            p->pos++;
            return array;
        }
        p->failed = true;
        json_free(array);
        return NULL;
    }
}

static JsonValue *parse_object(Parser *p) {
    if (!consume(p, '{')) {
        return NULL;
    }
    JsonValue *object = value_new(JSON_OBJECT);
    if (object == NULL) {
        p->failed = true;
        return NULL;
    }
    skip_whitespace(p);
    if (p->pos < p->len && p->text[p->pos] == '}') {
        p->pos++;
        return object;
    }
    for (;;) {
        skip_whitespace(p);
        Buffer key;
        buffer_init(&key);
        if (!parse_string_into(p, &key)) {
            buffer_free(&key);
            p->failed = true;
            json_free(object);
            return NULL;
        }
        skip_whitespace(p);
        if (!consume(p, ':')) {
            buffer_free(&key);
            json_free(object);
            return NULL;
        }
        JsonValue *member = parse_value(p);
        if (member == NULL) {
            buffer_free(&key);
            json_free(object);
            return NULL;
        }
        member->key = key.data != NULL ? key.data : calloc(1, 1);
        append_child(object, member);
        skip_whitespace(p);
        if (p->pos < p->len && p->text[p->pos] == ',') {
            p->pos++;
            continue;
        }
        if (p->pos < p->len && p->text[p->pos] == '}') {
            p->pos++;
            return object;
        }
        p->failed = true;
        json_free(object);
        return NULL;
    }
}

static JsonValue *parse_value(Parser *p) {
    skip_whitespace(p);
    if (p->pos >= p->len) {
        p->failed = true;
        return NULL;
    }
    switch (p->text[p->pos]) {
        case '{': return parse_object(p);
        case '[': return parse_array(p);
        case '"': return parse_string(p);
        case 't': return parse_literal(p, "true", JSON_BOOL, true);
        case 'f': return parse_literal(p, "false", JSON_BOOL, false);
        case 'n': return parse_literal(p, "null", JSON_NULL, false);
        default: return parse_number(p);
    }
}

JsonValue *json_parse_len(const char *text, size_t len) {
    if (text == NULL) {
        return NULL;
    }
    Parser p = {.text = text, .len = len, .pos = 0, .failed = false};
    JsonValue *value = parse_value(&p);
    if (p.failed) {
        json_free(value);
        return NULL;
    }
    return value;
}

JsonValue *json_parse(const char *text) {
    return text == NULL ? NULL : json_parse_len(text, strlen(text));
}

void json_free(JsonValue *value) {
    while (value != NULL) {
        JsonValue *next = value->next_sibling;
        json_free(value->first_child);
        free(value->string);
        free(value->key);
        free(value);
        value = next;
    }
}

/* -------------------------------------------------------------- accessors */

const JsonValue *json_object_get(const JsonValue *object, const char *key) {
    if (object == NULL || object->type != JSON_OBJECT) {
        return NULL;
    }
    for (const JsonValue *child = object->first_child; child != NULL;
         child = child->next_sibling) {
        if (child->key != NULL && strcmp(child->key, key) == 0) {
            return child;
        }
    }
    return NULL;
}

const char *json_string_or(const JsonValue *value, const char *key,
                           const char *fallback) {
    const JsonValue *member = json_object_get(value, key);
    if (member == NULL || member->type != JSON_STRING) {
        return fallback;
    }
    return member->string;
}

double json_number_or(const JsonValue *value, const char *key, double fallback) {
    const JsonValue *member = json_object_get(value, key);
    if (member == NULL || member->type != JSON_NUMBER) {
        return fallback;
    }
    return member->number;
}

bool json_bool_or(const JsonValue *value, const char *key, bool fallback) {
    const JsonValue *member = json_object_get(value, key);
    if (member == NULL || member->type != JSON_BOOL) {
        return fallback;
    }
    return member->boolean;
}

size_t json_array_size(const JsonValue *array) {
    if (array == NULL || array->type != JSON_ARRAY) {
        return 0;
    }
    size_t count = 0;
    for (const JsonValue *child = array->first_child; child != NULL;
         child = child->next_sibling) {
        count++;
    }
    return count;
}

const JsonValue *json_array_at(const JsonValue *array, size_t index) {
    if (array == NULL || array->type != JSON_ARRAY) {
        return NULL;
    }
    size_t i = 0;
    for (const JsonValue *child = array->first_child; child != NULL;
         child = child->next_sibling, i++) {
        if (i == index) {
            return child;
        }
    }
    return NULL;
}
