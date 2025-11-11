# syntax=docker/dockerfile:1.4
ARG OPENSSL_VERSION=3.5.2
ARG ZLIB_VERSION=1.2.13
ARG XZ_VERSION=5.6.2
ARG LIBXML2_VERSION=2.10.3

FROM mirror.gcr.io/84codes/crystal:1.16.3-alpine AS builder

ARG OPENSSL_VERSION
ARG ZLIB_VERSION
ARG XZ_VERSION
ARG LIBXML2_VERSION

ENV PREFIX=/usr/local
ENV PATH=$PREFIX/bin:$PATH
ENV PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH

RUN apk add --no-cache \
      build-base curl perl linux-headers autoconf automake libtool pkgconfig musl-dev \
      pngquant jpeg-dev libpng-dev freetype-dev fontconfig-dev \
      sqlite-static yaml-static rsvg-convert

WORKDIR /usr/src

### 1) zlib (static)
RUN set -eux; \
    curl -fsSL "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz" | tar xz; \
    cd "zlib-${ZLIB_VERSION}"; \
    ./configure --prefix=$PREFIX; \
    make -j$(nproc); \
    make install

### 2) xz / liblzma (static)
RUN set -eux; \
    curl -fsSL "https://tukaani.org/xz/xz-${XZ_VERSION}.tar.gz" | tar xz; \
    cd "xz-${XZ_VERSION}"; \
    ./configure --prefix=$PREFIX --disable-shared --enable-static; \
    make -j$(nproc); \
    make install

### 3) libxml2 (static)
RUN set -eux; \
    curl -fsSL "ftp://xmlsoft.org/libxml2/libxml2-${LIBXML2_VERSION}.tar.gz" | tar xz; \
    cd "libxml2-${LIBXML2_VERSION}"; \
    ./configure --prefix=$PREFIX --without-python --enable-static --disable-shared --with-zlib=$PREFIX; \
    make -j$(nproc); \
    make install

### 4) OpenSSL (build & install)
RUN set -eux; \
    curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" | tar xz; \
    cd "openssl-${OPENSSL_VERSION}"; \
    ./Configure linux-x86_64 --prefix=$PREFIX --openssldir=/etc/ssl && \
    make -j$(nproc) && make install_sw

WORKDIR /invidious

COPY ./shard.yml ./shard.yml
COPY ./shard.lock ./shard.lock
RUN shards install --production

COPY ./src/ ./src/
COPY ./.git/ ./.git/
COPY ./scripts/ ./scripts/
COPY ./assets/ ./assets/
COPY ./videojs-dependencies.yml ./videojs-dependencies.yml

# Pre-render SVGs
RUN mkdir -p /invidious/assets/raster; \
    for svg in $(find assets -name '*.svg' || true); do \
      out="/invidious/assets/raster/$(basename "${svg%.*}.png")"; \
      rsvg-convert "$svg" -o "$out" || echo "warning: rsvg-convert failed $svg"; \
    done

# Build Crystal binary statically and strip
RUN --mount=type=cache,target=/root/.cache/crystal \
    PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig \
    crystal build ./src/invidious.cr \
      --release -s -p -t --mcpu=x86-64-v2 \
      --static --warnings all \
      --link-flags "-lxml2 -llzma -lz -lssl -lcrypto -ldl -lpthread -lm"

RUN if command -v ldd >/dev/null 2>&1; then ldd ./invidious || true; fi

### Runtime image
FROM mirror.gcr.io/alpine:3.22 AS runtime

# Remove default openssl package if present
RUN apk del --no-cache openssl openssl-dev || true

# Only install absolutely needed runtime packages
RUN apk add --no-cache \
      tini tzdata ttf-opensans ca-certificates

WORKDIR /invidious

RUN addgroup -g 1000 -S invidious && \
    adduser -u 1000 -S invidious -G invidious

COPY --from=builder --chown=invidious /invidious/invidious .
COPY --from=builder --chown=invidious /invidious/assets/raster ./assets/raster
COPY --from=builder --chown=invidious /invidious/assets ./assets
COPY --from=builder --chown=invidious /invidious/config/config.* ./config/
COPY --from=builder --chown=invidious /invidious/config/sql ./config/sql
COPY --from=builder --chown=invidious /invidious/locales ./locales

RUN mv -n config/config.example.yml config/config.yml && \
    sed -i 's/host: \(127.0.0.1\|localhost\)/host: invidious-db/' config/config.yml && \
    chmod o+rX -R ./assets ./config ./locales

EXPOSE 3000
USER invidious
ENTRYPOINT ["/sbin/tini", "--"]
CMD [ "/invidious/invidious" ]
