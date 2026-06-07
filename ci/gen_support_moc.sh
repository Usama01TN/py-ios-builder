#!/usr/bin/env bash
#
# gen_support_moc.sh — generate the inline ".moc" files that libpyside /
# libpysideqml (and occasionally libshiboken) sources #include.
#
# WHY THIS EXISTS
# ---------------
# Some Qt C++ sources use the "included moc" idiom: a .cpp that declares a
# QObject/Q_OBJECT type inline ends with
#     #include "thisfile.moc"
# where thisfile.moc is the output of running Qt's Meta-Object Compiler (moc)
# on that .cpp itself. Upstream this is produced automatically by CMake's
# AUTOMOC / qt6_wrap_cpp.
#
# pyside6-ios's standalone build_support_libs.sh compiles these sources with
# clang directly and never runs moc, so the build fails with e.g.:
#     fatal error: 'dynamicslot.moc' file not found
#
# This script reproduces AUTOMOC for exactly those sources: it scans the
# support-library source directories, finds every .cpp whose own body
# #includes "<basename>.moc", runs moc on that .cpp, and writes <basename>.moc
# beside it (where the compiler's -I "" default include path will find it).
#
# It is dynamic (no hardcoded filenames) so it stays correct across PySide
# versions, and idempotent (skips sources whose .moc is already up to date).
#
# USAGE
#   ./ci/gen_support_moc.sh /path/to/pyside6-ios
# or via env:
#   TOOLKIT_DIR=$GITHUB_WORKSPACE/pyside6-ios ./ci/gen_support_moc.sh
#
# Honours the same overrides as the toolkit's scripts/env.sh:
#   QT_IOS, QT_MACOS
#
set -euo pipefail

TOOLKIT_DIR="${1:-${TOOLKIT_DIR:-$PWD/pyside6-ios}}"
PYSIDE_SETUP="$TOOLKIT_DIR/build/pyside-setup"
PYSIDE_SRC="$PYSIDE_SETUP/sources/pyside6"

# Source dirs that build_support_libs.sh compiles. libshiboken is included for
# completeness (its current sources don't use the inline idiom, but scanning is
# cheap and future-proofs the step).
SCAN_DIRS=(
    "$PYSIDE_SRC/libpyside"
    "$PYSIDE_SRC/libpysideqml"
    "$PYSIDE_SETUP/sources/shiboken6/libshiboken"
)

# -- Locate Qt SDKs (mirror env.sh defaults/overrides) --
: "${QT_IOS:=$HOME/dev/lib/Qt-6/6.8.3/ios}"
: "${QT_MACOS:=${QT_IOS%/ios}/macos}"
[ -d "$QT_IOS/lib/QtCore.framework" ] || { echo "ERROR: QT_IOS not found: $QT_IOS" >&2; exit 1; }

# -- Find moc (host tool, in the macOS SDK) --
MOC=""
for cand in "$QT_MACOS/libexec/moc" "$QT_MACOS/bin/moc"; do
    [ -x "$cand" ] && { MOC="$cand"; break; }
done
[ -n "$MOC" ] || { echo "ERROR: moc not found under $QT_MACOS/{libexec,bin}/" >&2; exit 1; }

# -- Detect Qt version (for header include paths) --
_qt_ver_dir=$(ls -d "$QT_IOS/lib/QtCore.framework/Headers"/[0-9]* 2>/dev/null | head -1)
QT_VERSION=$(basename "${_qt_ver_dir:-unknown}")

echo "==> Generating included-moc files for support libraries"
echo "    moc        : $MOC"
echo "    Qt version : $QT_VERSION"

# moc is a preprocessor-level tool; it needs include dirs to resolve macros like
# Q_OBJECT and any Qt headers pulled in. Framework + module includes mirror the
# flags build_support_libs.sh uses to compile.
MOC_INCLUDES=(
    -I "$QT_IOS/include"
    -I "$QT_IOS/lib/QtCore.framework/Headers"
    -I "$QT_IOS/lib/QtCore.framework/Headers/$QT_VERSION"
    -I "$QT_IOS/lib/QtCore.framework/Headers/$QT_VERSION/QtCore"
)

generated=0
scanned=0
for dir in "${SCAN_DIRS[@]}"; do
    [ -d "$dir" ] || { echo "    (skip, not present: ${dir#"$PYSIDE_SETUP/"})"; continue; }
    # Each .cpp directly under the dir (recurse one level for signature/ etc.)
    while IFS= read -r -d '' cpp; do
        scanned=$((scanned + 1))
        base="$(basename "$cpp" .cpp)"
        # Does this source include its own .moc? (the inline idiom)
        if grep -Eq "^[[:space:]]*#include[[:space:]]+\"${base}\.moc\"" "$cpp"; then
            out="$(dirname "$cpp")/${base}.moc"
            # idempotent: skip if up to date
            if [ -f "$out" ] && [ "$out" -nt "$cpp" ]; then
                continue
            fi
            echo "    moc: ${cpp#"$PYSIDE_SETUP/"} -> ${base}.moc"
            # Per-source include dir so moc can find the file's own header.
            "$MOC" "${MOC_INCLUDES[@]}" -I "$(dirname "$cpp")" "$cpp" -o "$out"
            generated=$((generated + 1))
        fi
    done < <(find "$dir" -maxdepth 2 -name '*.cpp' -print0)
done

echo "    Scanned $scanned source(s); generated $generated .moc file(s)."
echo "==> Included-moc generation complete."
