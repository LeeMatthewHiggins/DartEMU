#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "agentos.h"

enum { READ_CHUNK = 4096 };

static void set_error(char **error, const char *message) {
    if (error != NULL) {
        *error = strdup(message);
    }
}

bool http_split_response(const char *raw, size_t len, int *status_code,
                         const char **body, size_t *body_len) {
    if (len < 12 || strncmp(raw, "HTTP/1.", 7) != 0) {
        return false;
    }
    const char *space = memchr(raw, ' ', len);
    if (space == NULL) {
        return false;
    }
    *status_code = atoi(space + 1);

    /* The body starts after the blank line; anything before it is headers we
     * do not need, since the host has already normalised the framing. */
    const char *separator = NULL;
    for (size_t i = 0; i + 3 < len; i++) {
        if (raw[i] == '\r' && raw[i + 1] == '\n' && raw[i + 2] == '\r' &&
            raw[i + 3] == '\n') {
            separator = raw + i + 4;
            break;
        }
    }
    if (separator == NULL) {
        return false;
    }
    *body = separator;
    *body_len = len - (size_t)(separator - raw);
    return true;
}

/* Connects to the gateway and names the upstream in the Host header.
 *
 * There is no name resolution here on purpose. Every reachable name is the
 * host's proxy, which routes on Host rather than on the address, so a lookup
 * could only ever return the gateway. Leaving it out also keeps the static
 * binary honest: statically linked glibc cannot use NSS at runtime, so a
 * gethostbyname compiled in here would be a call that can only fail. */
bool http_post(const char *gateway, int port, const char *host,
               const char *path, const char *authorization, const char *body,
               Buffer *response, int *status_code, char **error) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, gateway, &addr.sin_addr) != 1) {
        set_error(error, "the configured gateway is not an IPv4 address");
        return false;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        set_error(error, "could not create a socket");
        return false;
    }

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        set_error(error,
                  "could not reach the host proxy; this machine can only "
                  "talk to the upstreams its host allows");
        return false;
    }

    Buffer request;
    buffer_init(&request);
    buffer_printf(&request, "POST %s HTTP/1.1\r\n", path);
    buffer_printf(&request, "Host: %s\r\n", host);
    buffer_printf(&request, "Authorization: %s\r\n", authorization);
    buffer_append_str(&request, "Content-Type: application/json\r\n");
    buffer_printf(&request, "Content-Length: %zu\r\n", strlen(body));
    buffer_append_str(&request, "Connection: close\r\n\r\n");
    buffer_append_str(&request, body);

    size_t sent = 0;
    while (sent < request.len) {
        ssize_t wrote = write(fd, request.data + sent, request.len - sent);
        if (wrote < 0) {
            if (errno == EINTR) {
                continue;
            }
            buffer_free(&request);
            close(fd);
            set_error(error, "the connection failed while sending");
            return false;
        }
        sent += (size_t)wrote;
    }
    buffer_free(&request);

    Buffer raw;
    buffer_init(&raw);
    char chunk[READ_CHUNK];
    ssize_t got;
    while ((got = read(fd, chunk, sizeof(chunk))) > 0) {
        if (!buffer_append(&raw, chunk, (size_t)got)) {
            buffer_free(&raw);
            close(fd);
            set_error(error, "ran out of memory reading the response");
            return false;
        }
    }
    close(fd);

    const char *body_start;
    size_t body_len;
    if (!http_split_response(raw.data == NULL ? "" : raw.data, raw.len,
                             status_code, &body_start, &body_len)) {
        bool silent = raw.len == 0;
        buffer_free(&raw);
        set_error(error, silent ? "the connection was accepted and then closed "
                                  "without a reply; nothing is proxying for "
                                  "this machine"
                                : "the reply was not HTTP");
        return false;
    }
    bool ok = buffer_append(response, body_start, body_len);
    buffer_free(&raw);
    if (!ok) {
        set_error(error, "ran out of memory storing the response");
    }
    return ok;
}
