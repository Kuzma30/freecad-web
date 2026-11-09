#!/usr/bin/env bash
# Build and cache the emscripten ports the FreeCAD link uses (zlib, ICU), with the build's own
# flags, by compiling one empty translation unit:
#
#   . toolchain/env.sh
#   bash tools/emports-prebuild.sh
#
# Why through em++ and not embuilder: see the comment at the call sites (embuilder ignores
# EMCC_CFLAGS and builds the wasm32, single-threaded variant).
#
# Why the local copy and the retries: em++ downloads the ICU source (icu4c-68_2-src.zip) from
# GitHub every time the emscripten cache is fresh -- on the self-hosted box that is every run,
# because checkout's `git clean -ffdx` wipes emsdk/ with the rest of the workspace. One such
# download failed with "HTTP Error 504: Gateway Time-out" and took the link job down. Port
# archives are checked against their SHA-512 before use, so keeping them in
# $HOME/.cache/fcweb-emports and putting them back into <cache>/ports first is safe: emcc reuses
# a matching archive and downloads only when it is missing or wrong.
set -euo pipefail

store="${EMPORTS_STORE:-$HOME/.cache/fcweb-emports}"
cache="$(em-config CACHE)"
ports="$cache/ports"
mkdir -p "$ports"

shopt -s nullglob
seeded=0
for f in "$store"/*.zip "$store"/*.tar.gz "$store"/*.tgz; do
  [ -e "$ports/$(basename "$f")" ] || { cp -p "$f" "$ports/"; seeded=$((seeded + 1)); }
done
shopt -u nullglob
[ "$seeded" -gt 0 ] && echo "  ports: $seeded archive(s) from $store"

probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT
echo 'int main(){return 0;}' > "$probe/portprobe.cpp"

ok=0
for attempt in 1 2 3 4; do
  if em++ -pthread --use-port=zlib --use-port=icu -c "$probe/portprobe.cpp" -o "$probe/portprobe.o"; then
    ok=1
    break
  fi
  [ "$attempt" -lt 4 ] || break
  wait_s=$((attempt * 30))
  echo "::warning::port build failed (attempt $attempt/4) -- retrying in ${wait_s}s"
  sleep "$wait_s"
done
[ "$ok" = 1 ] || { echo "::error::could not build the emscripten ports (zlib, ICU)"; exit 1; }

# Keep the downloaded archives for the next run. Not on GitHub-hosted runners: $HOME is
# thrown away with the machine there anyway.
if [ "${RUNNER_ENVIRONMENT:-self-hosted}" != "github-hosted" ]; then
  mkdir -p "$store"
  shopt -s nullglob
  for f in "$ports"/*.zip "$ports"/*.tar.gz "$ports"/*.tgz; do
    cmp -s "$f" "$store/$(basename "$f")" 2>/dev/null || cp -p "$f" "$store/"
  done
  shopt -u nullglob
fi
