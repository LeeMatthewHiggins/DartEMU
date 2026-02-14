FROM alpine:latest

RUN apk add --no-cache \
    alpine-keys \
    apk-tools \
    e2fsprogs \
    wget \
    tar

COPY build_image.sh /build_image.sh
RUN chmod +x /build_image.sh

ENTRYPOINT ["/build_image.sh"]
