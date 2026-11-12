#!/bin/bash
# Stage the static site as infra/Dockerfile builds it, without docker.
set -euo pipefail
cd /work/freecad-web
OUT=/work/fcweb-site
BIN=$HOME/.cache/fcweb-buildtree/build-freecad-gui-weh/bin
rm -rf "$OUT"; mkdir -p "$OUT"
cp play-gui/freecad-gui.html play-gui/qtloader.js play-gui/legal.html play-gui/calculix-demo.html "$OUT/"
cp play-gui/og.png play-gui/robots.txt play-gui/sitemap.xml LICENSE NOTICE "$OUT/"
cp -r LICENSES play-gui/am play-gui/3dx "$OUT/"
cp play-gui/manifest.webmanifest play-gui/sw.js play-gui/icon-192.png play-gui/icon-512.png "$OUT/"
# GL patch table (same three calls as the glpatch stage)
cp "$BIN/FreeCAD.js" "$OUT/FreeCAD.js"
python3 tools/patch-freecad-js.py --selftest >/dev/null
python3 tools/patch-freecad-js.py "$OUT/FreeCAD.js" >/dev/null
python3 tools/patch-freecad-js.py "$OUT/FreeCAD.js" --check >/dev/null
cp "$BIN/FreeCAD.wasm" "$BIN/FreeCAD.data" "$OUT/"
python3 tools/check-payload-packages.py "$OUT/FreeCAD.js" | tail -1
# i18n (the i18n stage, from the FreeCAD tree this build used)
LR=qt-host/6.11.2/gcc_64/bin/lrelease
mkdir -p "$OUT/i18n"
find deps/src/freecad/src -name '*_*.ts' | while read -r ts; do "$LR" -silent "$ts" -qm "$OUT/i18n/$(basename "${ts%.ts}").qm"; done
V=$(grep -v '^#' patches/freecad.version | grep -v '^ *$' | tail -1)
python3 -c "import json,os; d='$OUT/i18n'; json.dump({'version': '$V', 'files': {f: os.path.getsize(os.path.join(d, f)) for f in sorted(os.listdir(d)) if f.endswith('.qm')}}, open(d + '/index.json', 'w'))"
n=$(ls "$OUT"/i18n/*_de.qm | wc -l); echo "i18n: $(ls "$OUT"/i18n/*.qm | wc -l) files, $n German"; test "$n" -gt 20
# precompressed variants
gzip -6 -k "$OUT/FreeCAD.data" & gzip -6 -k "$OUT/FreeCAD.wasm" &
brotli -q 5 -k "$OUT/FreeCAD.data" & brotli -q 5 -k "$OUT/FreeCAD.wasm" & wait
for f in FreeCAD.data.gz FreeCAD.data.br FreeCAD.wasm.gz FreeCAD.wasm.br; do test -s "$OUT/$f"; done
H="$OUT/freecad-gui.html"
JS=$(md5sum "$OUT/FreeCAD.js" | cut -c1-12); WA=$(md5sum "$OUT/FreeCAD.wasm" | cut -c1-12); DA=$(md5sum "$OUT/FreeCAD.data" | cut -c1-12)
sed -i "s|FreeCAD\.data\.gz?v=[A-Za-z0-9]*|FreeCAD.data.gz?v=$DA|g; s|'FreeCAD\.js'|'FreeCAD.js?v=$JS'|g; s|'FreeCAD\.wasm'|'FreeCAD.wasm?v=$WA'|g" "$H"
grep -q "FreeCAD.data.gz?v=$DA" "$H"; grep -q "FreeCAD.js?v=$JS" "$H"; grep -q "FreeCAD.wasm?v=$WA" "$H"
cp gate-serve/gmsh.js gate-serve/gmsh.wasm gate-serve/ccx.js gate-serve/ccx.wasm "$OUT/"
GM=$(md5sum "$OUT/gmsh.wasm" | cut -c1-12); CX=$(md5sum "$OUT/ccx.wasm" | cut -c1-12)
sed -i "s|'gmsh\.js'|'gmsh.js?v=$GM'|g; s|'ccx\.js'|'ccx.js?v=$CX'|g" "$H"
grep -q "gmsh.js?v=$GM" "$H"; grep -q "ccx.js?v=$CX" "$H"
sed -i "s|'ccx\.js'|'ccx.js?v=$CX'|g" "$OUT/calculix-demo.html"
AB=$(md5sum "$OUT/3dx/autobahn.min.js" | cut -c1-12); TD=$(md5sum "$OUT/3dx/3dconnexion.min.js" | cut -c1-12)
sed -i "s|'3dx/autobahn\.min\.js'|'3dx/autobahn.min.js?v=$AB'|g; s|'3dx/3dconnexion\.min\.js'|'3dx/3dconnexion.min.js?v=$TD'|g" "$H"
grep -q "autobahn.min.js?v=$AB" "$H"; grep -q "3dconnexion.min.js?v=$TD" "$H"
BUILD="local-qtpdf-$(date -u +%Y%m%d)-${V:0:7}"
sed -i "s|__FCWEB_BUILD__|$BUILD|g" "$H"; ! grep -q "__FCWEB_BUILD__" "$H"
chmod -R a+rX "$OUT"
echo "stamped js=$JS wasm=$WA data=$DA gmsh=$GM ccx=$CX build=$BUILD"
du -sh "$OUT"
