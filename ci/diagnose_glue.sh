#!/usr/bin/env bash
# diagnose_glue.sh — dump the facts needed to fix the missing-symbol problem.
# Run this on the macOS runner (or locally on a mac with the build checked out).
# It prints exactly what's needed: the real glue file structure, the typesystem
# inject-code entries, and whether the regenerated module wrapper contains the
# missing definitions. Paste its output back.
set -uo pipefail
TOOLKIT_DIR="${1:-$PWD/pyside6-ios}"
PS="$TOOLKIT_DIR/build/pyside-setup/sources/pyside6/PySide6"
GEN="$TOOLKIT_DIR/build/pyside6-ios-gen/PySide6/QtCore"

echo "######## 1. glue dir listing ########"
ls -la "$PS/QtCore/glue" 2>&1

echo; echo "######## 2. @snippet labels in core_snippets.cpp ########"
grep -nE '^[[:space:]]*//[[:space:]]*@snippet' "$PS/QtCore/glue/core_snippets.cpp" 2>&1 | head -80

echo; echo "######## 3. how init_QThread is defined (context) ########"
grep -n -B2 -A12 'init_QThread' "$PS/QtCore/glue/core_snippets.cpp" 2>&1 | head -60

echo; echo "######## 4. typesystem inject-code entries referencing these snippets ########"
grep -rnE 'inject-code|@snippet|file=|snippet=' "$PS/QtCore/typesystem_core.xml" 2>&1 | grep -iE 'snippet|inject' | head -60

echo; echo "######## 5. does the regenerated module wrapper define init_QThread? ########"
if [ -f "$GEN/qtcore_module_wrapper.cpp" ]; then
    grep -n 'init_QThread' "$GEN/qtcore_module_wrapper.cpp" 2>&1 | head
    echo "--- (U=undefined-ref vs T=defined in the compiled .o) ---"
else
    echo "no qtcore_module_wrapper.cpp generated at $GEN"
fi

echo; echo "######## 6. is the toolkit patched for glue paths? ########"
grep -n 'PYSIDE6_GLUE_PATHS\|typesystem-paths' "$TOOLKIT_DIR/scripts/build_pyside6_module.sh" 2>&1
