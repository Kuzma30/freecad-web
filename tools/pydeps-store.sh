#!/usr/bin/env bash
# Keep the Python extension trees on this box, next to the build-tree store.
#
#   tools/pydeps-store.sh save    <key>   copy the trees from the workspace into the store
#   tools/pydeps-store.sh restore <key>   copy them back; prints hit=true|false to $GITHUB_OUTPUT
#
# Why: the pydeps cache is ~3.4 GB compressed. Pulling it back through actions/cache
# runs at a few MB/s, and the download URL is only signed for a limited time: link run
# on 2026-11-04 got half way in ten minutes and then failed with "Server failed to
# authenticate the request", restored nothing and reported every Python archive missing.
# The trees are produced on this box and consumed on this box, so -- like the build tree
# and ccache -- they live here. actions/cache stays as the fallback for other runners.
#
# <key> is PYDEPS_KEY (the ABI part of the cache key). The store keeps exactly one
# generation: a different key replaces it, so it never grows past one copy.
#
# The store is a plain copy, not hard links: later steps patch files in these trees in
# place, and a hard link would carry that edit back into the store.
set -euo pipefail

op="${1:?save|restore}"
key="${2:?PYDEPS_KEY}"
store="${PYDEPS_STORE:-$HOME/.cache/fcweb-pydeps}"

# Keep this list identical to the actions/cache path lists in build-python-deps.yml and
# link-freecad.yml.
paths=(
  deps/wasm/lib/numpy-mod
  deps/wasm/lib/mpl-mod
  deps/wasm/lib/kiwi-mod
  deps/wasm/lib/ctypes-mod
  deps/wasm/lib/pil-mod
  deps/wasm/lib/ifc-mod
  deps/wasm/lib/pivy-mod
  deps/wasm/lib/libffi.a
  deps/src/cpython
  deps/src/numpy
  deps/src/matplotlib
  deps/wasm/include/freetype2
  deps/src/pivy
  deps/src/ifcopenshell
  deps/src/pyside-setup
  deps/src/eigen
  build-numpy
  build-pivy-wasm
  build-ifcopenshell
  deps/host/shiboken6
  deps/wasm/pyside-pkg
  deps/wasm/shiboken6
  build-shiboken-wasm
  build-pyside-wasm
)

out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; echo "$1"; }

case "$op" in
  save)
    present=()
    for p in "${paths[@]}"; do [ -e "$p" ] && present+=("$p"); done
    shopt -s nullglob
    for p in deps/host/llvm-*; do present+=("$p"); done
    shopt -u nullglob
    if [ ${#present[@]} -eq 0 ]; then
      echo "::warning::nothing to store -- no Python extension trees in the workspace"
      exit 0
    fi
    mkdir -p "$(dirname "$store")"
    tmp="$store.new.$$"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    # tar keeps symlinks, modes and mtimes, and copies only what is listed.
    tar -cf - "${present[@]}" | tar -xf - -C "$tmp"
    echo "$key" > "$tmp/.key"
    rm -rf "$store.old"
    [ -d "$store" ] && mv "$store" "$store.old"
    mv "$tmp" "$store"
    rm -rf "$store.old"
    echo "stored ${#present[@]} trees ($(du -sh "$store" | cut -f1)) in $store for $key"
    ;;
  restore)
    stamp="$(cat "$store/.key" 2>/dev/null || true)"
    if [ ! -d "$store" ] || [ "$stamp" != "$key" ]; then
      echo "no local store for $key (have: ${stamp:-none}) -- falling back to actions/cache"
      out "hit=false"
      exit 0
    fi
    (cd "$store" && tar -cf - --exclude=./.key .) | tar -xf -
    echo "restored $(du -sh "$store" | cut -f1) from $store"
    out "hit=true"
    ;;
  *)
    echo "usage: $0 save|restore <key>" >&2
    exit 2
    ;;
esac
