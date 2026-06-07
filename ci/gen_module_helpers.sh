#!/usr/bin/env bash
#
# gen_module_helpers.sh — compile the hand-written PySide6 per-module helper
# sources and add them to libPySide6_<Module>.a.
#
# WHY THIS EXISTS
# ---------------
# build_pyside6_module.sh compiles ONLY the shiboken-generated *_wrapper.cpp
# files (plus the module wrapper and a couple of EXTRA_SOURCES). But each Qt
# module's binding also depends on hand-written C++ helper sources that live in
#     sources/pyside6/PySide6/<Module>/*.cpp
# (e.g. qtcorehelper.cpp, qiopipe.cpp for QtCore; qpytextobject.cpp for QtGui).
# Upstream CMake adds these to the module target. The standalone script omits
# them, so linking the app fails with undefined symbols such as:
#     QtCoreHelper::QGenericArgumentHolder::...
#     QtCoreHelper::QIOPipe::...
#     QtCoreHelper::QDirListingIterator::...
#     invokeMetaMethod(...) / invokeMetaMethodWithReturn(...)
#     QPyTextObject::... / typeinfo for QPyTextObject
#
# This script finds those helper sources for each requested module, cross-
# compiles them for iOS arm64 with the SAME flags build_pyside6_module.sh uses
# (it sources the toolkit's env.sh), and appends the objects to the existing
# static library. It is idempotent and additive.
#
# USAGE
#   ./ci/gen_module_helpers.sh /path/to/pyside6-ios QtCore QtGui QtWidgets
# or rely on env:
#   TOOLKIT_DIR=... ./ci/gen_module_helpers.sh QtCore QtGui QtWidgets
#
set -euo pipefail

# First arg may be the toolkit dir; remaining args are module names.
if [ "${1:-}" ] && [ -d "${1:-}" ]; then
    TOOLKIT_DIR="$1"; shift
else
    TOOLKIT_DIR="${TOOLKIT_DIR:-$PWD/pyside6-ios}"
fi
MODULES=("$@")
[ "${#MODULES[@]}" -gt 0 ] || MODULES=(QtCore QtGui QtWidgets)

SCRIPTS_DIR="$TOOLKIT_DIR/scripts"
[ -f "$SCRIPTS_DIR/env.sh" ] || { echo "ERROR: $SCRIPTS_DIR/env.sh not found" >&2; exit 1; }

# Source the toolkit's environment so our compile flags exactly match the
# wrapper build (CXX, IOS_SDK, QT_IOS, QT_VERSION, *_SRC paths, qt_header_flags).
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/env.sh"

OUT_DIR="$P6IOS_ROOT/build/pyside6-ios-static"
PYSIDE6_MODSRC_ROOT="$PYSIDE6_SRC"   # .../sources/pyside6/PySide6

echo "==> Adding per-module helper sources to module libraries"
echo "    PySide6 module sources: $PYSIDE6_MODSRC_ROOT"

# Base flags mirror build_pyside6_module.sh's CXXFLAGS.
base_cxxflags() {
    local mod="$1"
    local gendir="$P6IOS_ROOT/build/pyside6-ios-gen/PySide6/$mod"
    local flags=(-arch arm64 -std=c++17 -isysroot "$IOS_SDK" -miphoneos-version-min=16.0
        -iframework "$QT_IOS/lib" -I "$QT_IOS/include"
        $(qt_header_flags QtCore)
        -I "$PYTHON_FW/Headers" -I "$LIBSHIBOKEN_SRC" -I "$LIBPYSIDE_SRC"
        -I "$PYSIDE6_SRC" -I "$gendir"
        -I "$P6IOS_ROOT/build/pyside6-ios-gen/PySide6/QtCore"
        -I "$PYSIDE6_SRC/$mod"
        -DQT_LEAN_HEADERS=1 -DQT_NO_DEBUG -O2 -fPIC)
    # Per-module Qt framework headers (mirror the EXTRA_CXXFLAGS cases).
    case "$mod" in
        QtGui)     flags+=($(qt_header_flags QtGui)) ;;
        QtWidgets) flags+=($(qt_header_flags QtGui) $(qt_header_flags QtWidgets)
                          -I "$P6IOS_ROOT/build/pyside6-ios-gen/PySide6/QtGui") ;;
        QtNetwork) flags+=($(qt_header_flags QtNetwork)) ;;
        QtQml)     flags+=(-I "$LIBPYSIDEQML_SRC" $(qt_header_flags QtQml)) ;;
        QtQuick)   flags+=(-I "$LIBPYSIDEQML_SRC" $(qt_header_flags QtQml) $(qt_header_flags QtQuick)) ;;
    esac
    printf '%s\n' "${flags[@]}"
}

# Files the toolkit already builds as EXTRA_SOURCES (don't double-compile).
is_extra_source() {
    case "$1" in
        pysideqmlvolatilebool.cpp|pysidequickregistertype.cpp) return 0 ;;
        *) return 1 ;;
    esac
}

total_added=0
for mod in "${MODULES[@]}"; do
    mod_src_dir="$PYSIDE6_MODSRC_ROOT/$mod"
    lib="$OUT_DIR/libPySide6_${mod}.a"
    if [ ! -d "$mod_src_dir" ]; then
        echo "    (skip $mod: no source dir $mod_src_dir)"
        continue
    fi
    if [ ! -f "$lib" ]; then
        echo "    (skip $mod: $lib not built yet)"
        continue
    fi

    mapfile -t flags < <(base_cxxflags "$mod")
    obj_dir="$P6IOS_ROOT/build/$(echo "$mod" | tr '[:upper:]' '[:lower:]')-ios/helpers"
    mkdir -p "$obj_dir"

    # Hand-written helper sources: every *.cpp DIRECTLY in the module dir that
    # is not a generated wrapper and not an already-built extra source. We also
    # scan glue/ for the inject-code helper TUs (qObjectFindChild, init_QThread,
    # QVariant_*, PySideEasingCurveFunctor, addPostRoutine, Py*_ImportAndCheck).
    added=()
    compile_one() {
        local src="$1" b obj
        b="$(basename "$src")"
        case "$b" in
            *_wrapper.cpp) return ;;            # generated wrappers (built elsewhere)
        esac
        is_extra_source "$b" && return
        obj="$obj_dir/${b%.cpp}.o"
        echo "    [$mod] compile helper: ${src#"$mod_src_dir/"}"
        if "$CXX" "${flags[@]}" -I "$mod_src_dir" -I "$mod_src_dir/glue" \
                -c "$src" -o "$obj" 2>/tmp/helper_err.$$; then
            added+=("$obj")
        else
            # Some TUs aren't standalone-compilable (inject-code fragments meant
            # to be #included). Surface the error but don't abort; an unused or
            # non-standalone TU shouldn't fail the whole build.
            echo "      WARN: skipped $b (not standalone-compilable):" >&2
            tail -6 /tmp/helper_err.$$ >&2
        fi
    }
    while IFS= read -r -d '' src; do compile_one "$src"; done \
        < <(find "$mod_src_dir" -maxdepth 1 -name '*.cpp' -print0)
    if [ -d "$mod_src_dir/glue" ]; then
        while IFS= read -r -d '' src; do compile_one "$src"; done \
            < <(find "$mod_src_dir/glue" -maxdepth 1 -name '*.cpp' -print0)
    fi
    rm -f /tmp/helper_err.$$

    if [ "${#added[@]}" -gt 0 ]; then
        echo "    [$mod] appending ${#added[@]} object(s) to $(basename "$lib")"
        # Re-archive: extract existing + add new, rebuild for arm64.
        xcrun -sdk iphoneos libtool -static -o "$lib" "$lib" "${added[@]}"
        total_added=$((total_added + ${#added[@]}))
    else
        echo "    [$mod] no helper sources found to add"
    fi
done

echo "==> Done. Added $total_added helper object(s) across modules."
