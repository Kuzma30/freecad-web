#!/usr/bin/env bash
# HarfBuzz for wasm64, WITH its Unicode tables, installed into the Qt prefix.
#
#   . toolchain/env.sh
#   bash build-harfbuzz-weh.sh <harfbuzz src dir> <prefix>
#
# Qt's bundled HarfBuzz is built with HB_NO_UNICODE_FUNCS: Qt hands every buffer its own
# Unicode functions, so it does not need them. FreeCAD main's Part module (makeWireString,
# Draft ShapeString) calls HarfBuzz directly and relies on hb_buffer_guess_segment_properties,
# which without Unicode functions finds no script: right-to-left and complex scripts come out
# unshaped. So Qt is configured with -harfbuzz system and this library is the one HarfBuzz in
# the binary -- Qt and FreeCAD both use it, and there is no second copy to collide with.
#
# The source is Qt's own copy (qt-src/qtbase/src/3rdparty/harfbuzz-ng/src), so the version is
# exactly the one Qt 6.11.2 was tested with (HarfBuzz 14.3.0) and nothing extra is downloaded.
# harfbuzz.cc is HarfBuzz's single-file build; it includes hb-ucd.cc, the built-in Unicode
# tables. The platform back ends it also includes (FreeType, GLib, ICU, CoreText, DirectWrite,
# Uniscribe, Graphite, wasm shaper) are compiled out because their HAVE_* macros are not set.
#
# Installed into the Qt prefix so it travels in the Qt cache, and found by every consumer of
# Qt6::Gui through lib/cmake/harfbuzz (Qt's FindWrapSystemHarfbuzz does find_package(harfbuzz)).
set -euo pipefail

SRC="${1:?harfbuzz src dir (the one holding harfbuzz.cc)}"
PREFIX="${2:?install prefix}"
[ -f "$SRC/harfbuzz.cc" ] || { echo "ERROR: no $SRC/harfbuzz.cc" >&2; exit 1; }
[ -f "$SRC/hb-ucd.cc" ] || { echo "ERROR: no $SRC/hb-ucd.cc -- Unicode tables missing" >&2; exit 1; }
command -v em++ >/dev/null || { echo "ERROR: em++ not on PATH -- source toolchain/env.sh first" >&2; exit 1; }

VER="$(sed -n 's/^#define HB_VERSION_STRING "\(.*\)"/\1/p' "$SRC/hb-version.h")"
[ -n "$VER" ] || { echo "ERROR: no HB_VERSION_STRING in $SRC/hb-version.h" >&2; exit 1; }
echo "harfbuzz $VER from $SRC"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# EMCC_CFLAGS (toolchain/env.sh) supplies -m64 and the exception model. HAVE_PTHREAD gives
# HarfBuzz real mutexes: Qt lays out text from more than one thread.
em++ -c -O2 -pthread -fwasm-exceptions \
  -DHAVE_PTHREAD -DHAVE_ATEXIT -DHB_NDEBUG \
  -I"$SRC" "$SRC/harfbuzz.cc" -o "$work/harfbuzz.o"
rm -f "$work/libharfbuzz.a"
emar rcs "$work/libharfbuzz.a" "$work/harfbuzz.o"

# The Unicode functions must actually be in there, not the empty ones.
if ! emnm "$work/libharfbuzz.a" 2>/dev/null | grep -q " T hb_ucd_get_unicode_funcs"; then
  echo "ERROR: hb_ucd_get_unicode_funcs is not defined -- built without the Unicode tables" >&2
  exit 1
fi

mkdir -p "$PREFIX/lib" "$PREFIX/include/harfbuzz" "$PREFIX/lib/cmake/harfbuzz"
install -m 644 "$work/libharfbuzz.a" "$PREFIX/lib/libharfbuzz.a"
# Public headers only (.h; the .hh files are internal).
for h in "$SRC"/hb*.h; do install -m 644 "$h" "$PREFIX/include/harfbuzz/"; done

# Relocatable config: paths are taken from where this file sits, so the cache can be restored
# into any workspace.
cat > "$PREFIX/lib/cmake/harfbuzz/harfbuzz-config.cmake" <<'EOF'
# Written by freecad-web build-harfbuzz-weh.sh (static wasm64 build, with Unicode tables).
get_filename_component(_hb_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
if(NOT TARGET harfbuzz::harfbuzz)
  add_library(harfbuzz::harfbuzz STATIC IMPORTED)
  set_target_properties(harfbuzz::harfbuzz PROPERTIES
    IMPORTED_LOCATION "${_hb_prefix}/lib/libharfbuzz.a"
    INTERFACE_INCLUDE_DIRECTORIES "${_hb_prefix}/include/harfbuzz;${_hb_prefix}/include")
endif()
set(harfbuzz_INCLUDE_DIR "${_hb_prefix}/include/harfbuzz")
set(harfbuzz_LIBRARY "${_hb_prefix}/lib/libharfbuzz.a")
unset(_hb_prefix)
EOF
cat > "$PREFIX/lib/cmake/harfbuzz/harfbuzz-config-version.cmake" <<EOF
set(PACKAGE_VERSION "$VER")
if(PACKAGE_FIND_VERSION VERSION_GREATER PACKAGE_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOF
echo "installed $PREFIX/lib/libharfbuzz.a ($(du -h "$PREFIX/lib/libharfbuzz.a" | cut -f1)), headers in $PREFIX/include/harfbuzz"
