# https://github.com/openssl/openssl/releases/tag/openssl-3.5.2
ARG OPENSSL_VERSION='3.5.2'

FROM mirror.gcr.io/84codes/crystal:1.16.3-alpine AS builder

RUN apk add --no-cache sqlite-static yaml-static
RUN apk del openssl-dev openssl-libs-static
RUN apk add --no-cache curl perl linux-headers build-base

ARG release

WORKDIR /invidious

ARG OPENSSL_VERSION
RUN curl -Ls "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" | tar xz

# Build OpenSSL with minimal footprint flags
RUN cd openssl-${OPENSSL_VERSION} && \
    CFLAGS="-Os -DOPENSSL_SMALL_FOOTPRINT -ffunction-sections -fdata-sections" \
    LDFLAGS="-Wl,--gc-sections" \
    ./Configure linux-x86_64 --openssldir=/etc/ssl \
      no-shared \
      no-async \
      no-engine \
      no-dso \
      no-comp \
      no-weak-ssl-ciphers \
      no-deprecated \
      no-idea \
      no-rc4 \
      no-rc2 \
      no-md4 \
      no-mdc2 \
      no-whirlpool \
      && make -j$(nproc) && make install_sw && \
    # strip static libs to reduce size
    if command -v strip >/dev/null 2>&1; then strip /usr/local/lib/libcrypto.a /usr/local/lib/libssl.a || true; fi

COPY ./shard.yml ./shard.yml
COPY ./shard.lock ./shard.lock

RUN shards install --production

COPY ./src/ ./src/
# TODO: .git folder is required for building – this is destructive.
# See definition of CURRENT_BRANCH, CURRENT_COMMIT and CURRENT_VERSION.
COPY ./.git/ ./.git/

# Required for fetching player dependencies
COPY ./scripts/ ./scripts/
COPY ./assets/ ./assets/
COPY ./videojs-dependencies.yml ./videojs-dependencies.yml

# Adjust PKG_CONFIG_PATH so Crystal's build can find the OpenSSL we installed
RUN --mount=type=cache,target=/root/.cache/crystal \
        PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
        crystal build ./src/invidious.cr \
        --release -s -p -t --mcpu=x86-64-v2 \
        --static --warnings all \
        --link-flags "-lxml2 -llzma";

FROM mirror.gcr.io/alpine:3.22
RUN apk add --no-cache rsvg-convert ttf-opensans tini tzdata
WORKDIR /invidious
RUN addgroup -g 1000 -S invidious && \
    adduser -u 1000 -S invidious -G invidious
COPY --chown=invidious ./config/config.* ./config/
RUN mv -n config/config.example.yml config/config.yml
RUN sed -i 's/host: \(127.0.0.1\|localhost\)/host: invidious-db/' config/config.yml
COPY ./config/sql/ ./config/sql/
COPY ./locales/ ./locales/
COPY --from=builder /invidious/assets ./assets/
COPY --from=builder /invidious/invidious .
RUN chmod o+rX -R ./assets ./config ./locales

EXPOSE 3000
USER invidious
ENTRYPOINT ["/sbin/tini", "--"]
CMD [ "/invidious/invidious" ]
