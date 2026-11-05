# pg-repack job image: stock pg_repack 1.5.3 client + the struct-throttle patch.
# The server side stays the stock 1.5.3 extension on Azure; this image only
# contains the client (it reports version 1.5.3 so the version check passes).
#
#   docker build -t <acr>/ops/pg-repack:1.5.3-throttle.1 .
FROM postgres:16-bookworm AS build
ARG PG_REPACK_VERSION=1.5.3
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl patch postgresql-server-dev-16 \
      libpq-dev liblz4-dev libzstd-dev libreadline-dev zlib1g-dev libssl-dev libkrb5-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN curl -fsSL "https://github.com/reorg/pg_repack/archive/refs/tags/ver_${PG_REPACK_VERSION}.tar.gz" \
      | tar xz --strip-components=1
COPY patches/ /patches/
RUN for p in /patches/*.patch; do echo "applying $p"; patch -p1 --forward < "$p"; done \
 && make -C bin \
 && ./bin/pg_repack --version | grep -q "pg_repack ${PG_REPACK_VERSION} (struct-throttle"

FROM postgres:16-bookworm
COPY --from=build /src/bin/pg_repack /usr/local/bin/pg_repack
COPY repack.sh /usr/local/bin/repack.sh
RUN chmod 0755 /usr/local/bin/repack.sh && pg_repack --version
USER postgres
ENTRYPOINT ["/usr/local/bin/repack.sh"]
