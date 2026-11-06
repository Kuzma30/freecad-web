# HarfBuzz headers for FreeCAD main's Part module

FreeCAD main shapes `Part.makeWireString()` text with HarfBuzz (`src/Mod/Part/App/Geometry.cpp`)
and `SetupFreeType.cmake` stops configure with "HarfBuzz not found" when FreeType is on.

The wasm build already links one HarfBuzz: Qt's `libQt6BundledHarfbuzz.a`. A second copy
would collide with it under `--allow-multiple-definition`, so Part uses Qt's. Qt does not
install the headers of its bundled libraries, so these are the public headers that `hb.h`
pulls in, copied unchanged from `qtbase/src/3rdparty/harfbuzz-ng/src` at tag v6.11.2
(HarfBuzz 14.3.0). Update them together with Qt.

Qt builds its copy with `HB_NO_UNICODE_FUNCS` (Qt sets its own on each buffer). FreeCAD's
`hb_buffer_guess_segment_properties()` therefore finds no script and shapes left-to-right
with the default shaper: Latin, Cyrillic, Greek and CJK come out as before; right-to-left and
complex scripts (Arabic, Hebrew, Devanagari) are not shaped.

License: "Old MIT", see COPYING.
