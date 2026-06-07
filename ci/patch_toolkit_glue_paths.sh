#!/usr/bin/env bash
#
# patch_toolkit_glue_paths.sh — make shiboken resolve PySide6 glue snippets.
#
# ROOT CAUSE this fixes
# ---------------------
# build_pyside6_module.sh runs shiboken with:
#     --typesystem-paths=$PYSIDE6_SRC:$PYSIDE6_SRC/templates
# PySide's typesystem files inject native helper code from external glue files
# by basename, e.g.
#     <inject-code class="native" file="core_snippets.cpp" snippet="..."/>
# Per the Shiboken docs, such `file=` snippets are searched for ON THE
# TYPESYSTEM PATH. The glue files live in per-module subdirs:
#     $PYSIDE6_SRC/QtCore/glue/core_snippets.cpp
#     $PYSIDE6_SRC/QtCore/glue/qeasingcurve_glue.cpp
#     $PYSIDE6_SRC/QtGui/glue/...   etc.
# Those `glue/` dirs are NOT on --typesystem-paths, so shiboken cannot find the
# snippets. It still emits the CALL sites (from the typesystem function entries)
# but silently DROPS the native definitions, producing undefined symbols at app
# link time:
#     init_QThread, qObjectFindChild, qObjectTr, QVariant_*, PySideEasingCurveFunctor::*,
#     PySide::addPostRoutine, PySide::globalPostRoutineCallback,
#     Py{Date,Time,DateTime}_ImportAndCheck, ...
#
# THE FIX
# -------
# Append every module's glue directory (and the shared glue dirs) to
# --typesystem-paths so shiboken resolves the snippets and injects the
# definitions into the generated *_module_wrapper.cpp itself — exactly as the
# upstream CMake build does. The toolkit already compiles those wrappers, so the
# symbols then end up in libPySide6_<Module>.a with correct (external) linkage.
#
# This is idempotent: it only rewrites the line if it hasn't been patched yet.
#
# USAGE: ./ci/patch_toolkit_glue_paths.sh /path/to/pyside6-ios
#
set -euo pipefail

TOOLKIT_DIR="${1:-${TOOLKIT_DIR:-$PWD/pyside6-ios}}"
SCRIPT="$TOOLKIT_DIR/scripts/build_pyside6_module.sh"
[ -f "$SCRIPT" ] || { echo "ERROR: $SCRIPT not found" >&2; exit 1; }

if grep -q 'PYSIDE6_GLUE_PATHS' "$SCRIPT"; then
    echo "==> build_pyside6_module.sh already patched for glue paths; skipping."
    exit 0
fi

echo "==> Patching $SCRIPT to add PySide6 glue dirs to --typesystem-paths"

# Insert a block that builds a colon-separated list of all */glue dirs just
# before the shiboken invocation, then extend the --typesystem-paths argument.
# We do this with a small python rewrite for robustness (no fragile sed quoting).
python3 - "$SCRIPT" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()

# 1) Inject a PYSIDE6_GLUE_PATHS assignment right before the API_VERSION line
#    (which immediately precedes the shiboken call).
anchor = 'API_VERSION="${SHIBOKEN_MAJOR}.${SHIBOKEN_MINOR}"'
if anchor not in src:
    sys.stderr.write("ERROR: anchor for glue-path injection not found\n")
    sys.exit(1)

glue_block = (
    '# --- glue snippet search path (added by patch_toolkit_glue_paths.sh) ---\n'
    '# Shiboken resolves <inject-code file="..."> snippets on the typesystem\n'
    '# path. PySide ships those snippets in per-module glue/ subdirs, so collect\n'
    '# them all and append to --typesystem-paths below.\n'
    'PYSIDE6_GLUE_PATHS=""\n'
    'for _gd in "$PYSIDE6_SRC"/*/glue "$PYSIDE6_SRC"/glue; do\n'
    '    [ -d "$_gd" ] && PYSIDE6_GLUE_PATHS="$PYSIDE6_GLUE_PATHS:$_gd"\n'
    'done\n'
    '\n'
)
src = src.replace(anchor, glue_block + anchor, 1)

# 2) Extend the --typesystem-paths argument with the glue paths.
old_tp = '"--typesystem-paths=$PYSIDE6_SRC:$PYSIDE6_SRC/templates"'
new_tp = '"--typesystem-paths=$PYSIDE6_SRC:$PYSIDE6_SRC/templates$PYSIDE6_GLUE_PATHS"'
if old_tp not in src:
    sys.stderr.write("ERROR: --typesystem-paths line not found in expected form\n")
    sys.exit(1)
src = src.replace(old_tp, new_tp, 1)

open(path, "w").write(src)
print("    patched: PYSIDE6_GLUE_PATHS added and appended to --typesystem-paths")
PY

echo "==> Verifying patch..."
grep -n 'PYSIDE6_GLUE_PATHS' "$SCRIPT" >/dev/null || { echo "ERROR: patch did not apply" >&2; exit 1; }
echo "==> Done."
