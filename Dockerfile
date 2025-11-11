# syntax=docker/dockerfile:1.4
ARG OPENSSL_VERSION=3.5.2
ARG ZLIB_VERSION=1.3.1
ARG XZ_VERSION=5.6.2
ARG LIBXML2_VERSION=2.14.5

FROM mirror.gcr.io/84codes/crystal:1.16.3-alpine AS builder

ARG OPENSSL_VERSION
ARG ZLIB_VERSION
ARG XZ_VERSION
ARG LIBXML2_VERSION

ENV PREFIX=/usr/local
ENV PATH=$PREFIX/bin:$PATH
ENV PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH

# Build deps only in builder
RUN apk add --no-cache \
    build-base curl perl linux-headers autoconf automake libtool pkgconfig musl-dev \
    pngquant jpeg-dev libpng-dev freetype-dev fontconfig-dev \
    sqlite-static yaml-static rsvg-convert xz

WORKDIR /usr/src

### Build zlib (static)
RUN set -eux; \
    curl -fsSL "https://zlib.net/zlib-${ZLIB_VERSION}.tar.gz" | tar xz; \
    cd "zlib-${ZLIB_VERSION}"; \
    ./configure --prefix=$PREFIX; \
    make -j$(nproc); \
    make install

### Build xz (liblzma) (static)
RUN set -eux; \
    curl -fsSL "https://tukaani.org/xz/xz-${XZ_VERSION}.tar.gz" | tar xz; \
    cd "xz-${XZ_VERSION}"; \
    ./configure --prefix=$PREFIX --disable-shared --enable-static; \
    make -j$(nproc); \
    make install

### Build libxml2 (static) — use .tar.xz and tar xJ
RUN set -eux; \
    curl -fsSL "https://download.gnome.org/sources/libxml2/2.14/libxml2-${LIBXML2_VERSION}.tar.xz" | tar xJ; \
    cd "libxml2-${LIBXML2_VERSION}"; \
    ./configure --prefix=$PREFIX --without-python --enable-static --disable-shared --with-zlib=$PREFIX; \
    make -j$(nproc); \
    make install

### Build OpenSSL into /usr/local
RUN set -eux; \
    curl -fsSL "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" | tar xz; \
    cd "openssl-${OPENSSL_VERSION}"; \
    ./Configure linux-x86_64 --prefix=$PREFIX --openssldir=/etc/ssl && \
    make -j$(nproc) && make install_sw

### Prepare project files in builder (ensure these COPYs exist in repo)
WORKDIR /invidious

# Must copy config/sql and locales into builder BEFORE building the binary.
COPY ./shard.yml ./shard.yml
COPY ./shard.lock ./shard.lock
RUN shards install --production

COPY ./src/ ./src/
COPY ./.git/ ./.git/
COPY ./scripts/ ./scripts/
COPY ./assets/ ./assets/
COPY ./config/config.* ./config/
# <-- Important: copy the SQL config and locales so they exist in builder
COPY ./config/sql/ ./config/sql/
COPY ./locales/ ./locales/
COPY ./videojs-dependencies.yml ./videojs-dependencies.yml

# Guarantee those directories exist even if empty (avoids COPY failures later)
RUN mkdir -p /invidious/config/sql /invidious/locales

# Pre-render SVGs into raster folder so we don't need librsvg/cairo at runtime
RUN mkdir -p /invidious/assets/raster; \
    for svg in $(find assets -name '*.svg' || true); do \
      out="/invidious/assets/raster/$(basename "${svg%.*}.png")"; \
      rsvg-convert "$svg" -o "$out" || echo "warning: rsvg-convert failed $svg"; \
    done

# Build Crystal binary statically, strip, and link libxml2/xz/zlib/openssl statically
RUN --mount=type=cache,target=/root/.cache/crystal \
    PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig \
    crystal build ./src/invidious.cr \
      --release -s -p -t --mcpu=x86-64-v2 \
      --static --warnings all \
      --link-flags "-lxml2 -llzma -lz -lssl -lcrypto -ldl -lpthread -lm"

# Static binary check — use `file` and `readelf` instead of ldd (ldd fails on fully static)
RUN file ./invidious && readelf -h ./invidious || true

### Final runtime image
FROM mirror.gcr.io/alpine:3.22 AS runtime

# Remove default openssl package (if present) to avoid depending on OS libssl/libcrypto
RUN apk del --no-cache openssl openssl-dev || true

RUN apk add --no-cache tini tzdata ttf-opensans ca-certificates

WORKDIR /invidious

RUN addgroup -g 1000 -S invidious && \
    adduser -u 1000 -S invidious -G invidious

# Copy minimal runtime files from builder (directories now guaranteed to exist)
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
