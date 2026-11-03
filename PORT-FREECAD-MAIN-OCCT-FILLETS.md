<!-- SPDX-License-Identifier: LGPL-2.1-or-later -->

# freecad-web on FreeCAD main + OCCT master with the fillet series

This branch moves the port from **FreeCAD 1.1.3 + OCCT 7.8.1** to:

| | before | now |
|---|---|---|
| FreeCAD | tag 1.1.3 | main, commit `66644dee63d3d260f1e0b9a8517d1a13631e903f` (2026-11-01), `patches/freecad.version` |
| OCCT | tag V7_8_1 | master, commit `3d097a0328e71b826377d4814ab05ec3c3d23871` (8.1.0.dev), `patches/occt.version` |
| OCCT patches | `occt.patch` | `occt.patch` (rebased) + `occt-fillets.patch` (25 commits, also in `occt-fillets/`) |
| AddonManager | `937b687` | `745c1b1` (the commit FreeCAD main points at) |
| OndselSolver | `main` branch tarball | `4be80ee` (the commit FreeCAD main points at) |
| RapidJSON | not used | `24b5e7a` (header-only), OCCT 8 builds TKDEGLTF only with it |

The fillet series is the one presented on the FreeCAD forum ("Improving fillets in OCCT"):
rolling-ball constant-radius fillets, exact corner caps, the #20085 square hole cases, and
the corner of a concave fillet with two convex ones computed as when the fillets are made
one after the other.

## What was verified here, and what was not

Not built: the machine this was prepared on could not download the emsdk toolchain
(storage.googleapis.com is blocked there), so **nothing was compiled for wasm**. The first
real test is a run of `build-deps` → `build-freecad` → `link-freecad` (or BUILD-WEH.md by
hand).

Verified:
- `patches/apply.sh` on pristine trees (FreeCAD main tarball + AddonManager `745c1b1`,
  OCCT `3d097a03`): every patch applies; a second run reports all of them as applied.
- `tools/check-patch-applies.py`: `freecad.patch` 253 hunks and `occt.patch` match their
  trees byte for byte.
- `tools/check-hunk-placement.py` against the 1.1.3 port: 9 blocks changed enclosing
  function, all reviewed (upstream moved the code, see below).
- Preprocessor and brace balance of every touched C++ file, `ast.parse` of every touched
  Python file; `tools/check-workflows.py`, `tools/check-workflow-shell.py`.
- OCCT `3d097a03` + `occt.patch` + `occt-fillets.patch` configured natively with the options
  of `configure-occt-weh.sh` and RapidJSON on: TKDEGLTF, TKExpress, TKService and TKV3d are
  generated. A native build of them was started but not finished (about a fifth of OCCT
  compiled without errors).
- The fillet series itself: OCCT `blend` grid 183 OK, TKFillet GTests 39/39, 27 DRAW tests,
  on a native build of the same commit.

## FreeCAD main vs 1.1.3: how the port was carried over

`freecad.patch` was applied to 1.1.3 (whitespace-insensitive, then the CRLF files restored
to CRLF), committed, and cherry-picked onto main. 29 files conflicted; the rest merged.

Taken from main, port hunk dropped because upstream no longer has the code it fixed:
- `NaviCube.cpp`: the cube is a Coin scene graph now; the immediate-mode replacement of
  the client-array draws is gone. The `QMenu::exec()` → `popup()` change is kept.
- `SoDatumLabel.cpp`: no more `glBegin(GL_QUADS)` for the label text.
- `SoBrepFaceSet.cpp`: rewritten upstream to render through `SoIndexedFaceSet`; the VBO
  bypass, the explicit diffuse `glColor4f` and the per-face pick culling are gone. The guard
  against a spurious secondary selection context (which blanked all geometry) is kept.
  **Check face colours and transparency in the browser first.**
- `Base/Parameter.cpp`: upstream `Base::FileLock` already does nothing under Emscripten.
- `FreeCADGuiInit.py`: the FCWEB_DEBUG boot timing prints.
- `Sketcher` `std::less` specialisations: removed upstream.
- `femsolver/calculix/tasks.py`: removed upstream. **The in-browser CalculiX hook lived
  there**, so solving with CalculiX in the browser needs a new hook in
  `calculixtools.CalculiXTools.compute()` (not done). The gmsh hook is ported
  (`model_file` instead of `temp_file_geo`).

Re-done on main's code:
- `Base/SystemHandler.cpp` (signal handlers moved there): no SIGSEGV handler and no
  backtrace under Emscripten.
- `View3DInventorViewer.cpp`: main splits the scene into `renderGLActionScene()`. The
  per-stage framebuffer rebind (`fcwebBindCoinFbo`) is reached there through
  `fcwebRebindCoinFbo`, set by `renderScene()` while it renders; the final composite and
  the GL state reset stay at the end of `renderScene()`; `viewAll()` skips
  `animatedViewAll` under Emscripten.
- `FileDialog.cpp`: main passes `FilterList` instead of a filter string; the wasm save path
  takes the suffix from the selected filter's patterns, and the open picker gets the joined
  filter strings.
- `ApplicationPy`: main generates the method table from `FreeCADGui.module.pyi`; the three
  preference-pack functions are declared there.
- `PropertyEditor.cpp`, `SoFCColorBar.cpp`: the heap menu + `popup()` under Emscripten
  rewritten on main's (larger) menus.
- `SoBrepEdgeSet.cpp`: kept the cached edge array and the per-edge pick culling next to
  main's new line↔edge mapping.
- CMake: `target_compile_warn_error()` is unconditional on main; the QProcess stub include
  stays in front of it.

Also in `freecad.patch`: `Standard_Byte.hxx` is included only for OCCT < 8.1 (it was removed
after 8.0).

## Build scripts

- `configure-occt-weh.sh`: `USE_RAPIDJSON=ON` with `deps/src/rapidjson`.
- `configure-gui-weh.sh`: `FREECAD_USE_EXTERNAL_COIN_PIVY=ON` (main bundles Coin and Pivy
  as submodules and builds them by default).
- `scratchpad/linkcmds/fc-linkcmd-weh.sh`: `libTKExpress.a` (FreeCAD links it for OCCT ≥ 7.9).
- `build-deps.yml`: OCCT and RapidJSON by commit; cache key and hash inputs include the new
  patches. `build-freecad.yml`, `link-freecad.yml`: FreeCAD by commit, recorded in
  `deps/src/freecad/.fcweb-freecad-commit`, which `apply.sh` checks. The boot gate expects
  the version in main's `version.json`. `infra/Dockerfile` fetches the translations by
  commit.

## Known risks

- FreeCAD main needs C++23; emsdk 6.0.9's libc++ (`std::format` with chrono is used in
  `Base/Tools.cpp`) is untested here.
- IfcOpenShell 0.8.0 and gmsh against OCCT 8.1: untested. gmsh is a separate module; the
  published `gmsh.wasm` built with 7.8.1 can be carried over unchanged.
- The rendering changes upstream (Coin overlays, NaviCube, SoBrepFaceSet) touch exactly the
  code the port's GL workarounds were written for; expect a debugging round in the browser.
