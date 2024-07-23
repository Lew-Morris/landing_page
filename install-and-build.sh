#!/bin/bash

DART_SASS_VERSION=${DART_SASS_VERSION:-1.70.0}
DEPLOY_PRIME_URL=${DEPLOY_PRIME_URL:-"https://qdrant.com"}
SEGMENT_WRITE_KEY=${SEGMENT_WRITE_KEY:-"noKey"}

CURRENT_DIR=$(pwd)

curl -LJO https://github.com/sass/dart-sass/releases/download/${DART_SASS_VERSION}/dart-sass-${DART_SASS_VERSION}-linux-x64.tar.gz && \
    tar -xf dart-sass-${DART_SASS_VERSION}-linux-x64.tar.gz && \
    rm dart-sass-${DART_SASS_VERSION}-linux-x64.tar.gz && \
    export PATH="${CURRENT_DIR}/dart-sass:${PATH}" && \
    cd qdrant-landing && npm install && hugo --gc --minify --config config.toml,config-theme.toml --buildFuture -b ${DEPLOY_PRIME_URL} --segment-write-key ${SEGMENT_WRITE_KEY}
