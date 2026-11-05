#!/bin/sh
# Regenerate patches/0001-struct-throttle.patch: the client changes over the
# upstream ver_1.5.3 tag (only bin/; the extension is untouched).
set -eu
cd "$(dirname "$0")/.."
git rev-parse -q --verify ver_1.5.3 >/dev/null \
  || git fetch https://github.com/reorg/pg_repack.git 'refs/tags/ver_1.5.3:refs/tags/ver_1.5.3'
mkdir -p struct/patches
git diff --no-color --no-ext-diff ver_1.5.3 HEAD -- bin/ > struct/patches/0001-struct-throttle.patch
echo "wrote struct/patches/0001-struct-throttle.patch ($(wc -l < struct/patches/0001-struct-throttle.patch) lines)"
