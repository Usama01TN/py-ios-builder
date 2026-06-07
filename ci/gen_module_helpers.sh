#!/usr/bin/env bash
#
# gen_module_helpers.sh — compile the PySide6 per-module sources that
# build_pyside6_module.sh omits, add them to libPySide6_<Module>.a, and VERIFY
# that the previously-undefined symbols are now defined. Fails loudly otherwise.
#
# WHY THIS EXISTS
# ---------------
# build_pyside6_module.sh archives only the shiboken-generated *_wrapper.cpp.
# Each module also needs:
#   (a) hand-written helper sources in sources/pyside6/PySide6/<Module>/*.cpp
#       (e.g. qtcorehelper.cpp, qiopipe.cpp -> QtCoreHelper::*, QIOPipe;
#        qpytextobject.cpp -> QPyTextObject). These use Q_OBJECT, so they also
#       need their .moc generated.
#   (b) the glue inject-code in sources/pyside6/PySide6/<Module>/glue/*.cpp
#       (qObjectFindChild, init_QThread, QVariant_*, PySideEasingCurveFunctor,
#        PySide::addPostRoutine, Py{Date,Time,DateTime}_ImportAndCheck). These
#       are NOT standalone TUs (no includes of their own); upstream shiboken
#       splices them into the module wrapper. We compile them by generating a
#       small wrapper TU that pulls in the right headers then #includes the glue.
# Without (a)/(b) the app link fails with the corresponding undefined symbols.
#
# This script is self-verifying: after archiving, it runs `nm` and aborts if any
# required symbol is still undefined, so an incomplete library can never pass
# (and therefore can never be cached as "good").
#
# USAGE:  ./ci/gen_module_helpers.sh /path/to/pyside6-ios QtCore QtGui QtWidgets
#
set -euo pipefail

if [ "${1:-}" ] && [ -d "${1:-}" ]; then TOOLKIT_DIR="$1"; shift
else TOOLKIT_DIR="${TOOLKIT_DIR:-$PWD/pyside6-ios}"; fi
MODULES=("$@"); [ "${#MODULES[@]}" -gt 0 ] || MODULES=(QtCore QtGui QtWidgets)

SCRIPTS_DIR="$TOOLKIT_DIR/scripts"
[ -f "$SCRIPTS_DIR/env.sh" ] || { echo "ERROR: $SCRIPTS_DIR/env.sh not found" >&2; exit 1; }
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/env.sh"

OUT_DIR="$P6IOS_ROOT/build/pyside6-ios-static"

# moc (host tool in the macOS Qt SDK).
MOC=""
for c in "$QT_MACOS/libexec/moc" "$QT_MACOS/bin/moc"; do [ -x "$c" ] && { MOC="$c"; break; }; done
[ -n "$MOC" ] || { echo "ERROR: moc not found under $QT_MACOS" >&2; exit 1; }

# Symbols (demangled, substring match) that MUST be defined per module after we
# finish. Used by the verification gate. Keep these aligned with the linker
# errors the standalone toolkit produces.
required_symbols() {
    case "$1" in
        QtCore) cat <<'SYMS'
QtCoreHelper::QGenericArgumentHolder
QtCoreHelper::QGenericReturnArgumentHolder
QtCoreHelper::QIOPipe
QtCoreHelper::QDirListingIterator
invokeMetaMethod
qObjectFindChild
qObjectTr
init_QThread(
QVariant_isStringList
PySideEasingCurveFunctor
PySide::addPostRoutine
PyDate_ImportAndCheck
PyDateTime_ImportAndCheck
SYMS
        ;;
        QtGui) cat <<'SYMS'
QPyTextObject
SYMS
        ;;
        *) : ;;
    esac
}

# Base compile flags mirror build_pyside6_module.sh. Populates global FLAGS
# (no mapfile -> works on macOS Bash 3.2).
FLAGS=()
base_cxxflags() {
    local mod="$1" gendir="$P6IOS_ROOT/build/pyside6-ios-gen/PySide6/$1"
    FLAGS=(-arch arm64 -std=c++17 -isysroot "$IOS_SDK" -miphoneos-version-min=16.0
        -iframework "$QT_IOS/lib" -I "$QT_IOS/include"
        $(qt_header_flags QtCore)
        -I "$PYTHON_FW/Headers" -I "$LIBSHIBOKEN_SRC" -I "$LIBPYSIDE_SRC"
        -I "$PYSIDE6_SRC" -I "$gendir"
        -I "$P6IOS_ROOT/build/pyside6-ios-gen/PySide6/QtCore"
        -I "$PYSIDE6_SRC/$mod"
        -DQT_LEAN_HEADERS=1 -DQT_NO_DEBUG -O2 -fPIC)
    case "$mod" in
        QtGui)     FLAGS+=($(qt_header_flags QtGui)) ;;
        QtWidgets) FLAGS+=($(qt_header_flags QtGui) $(qt_header_flags QtWidgets)
                          -I "$P6IOS_ROOT/build/pyside6-ios-gen/PySide6/QtGui") ;;
        QtNetwork) FLAGS+=($(qt_header_flags QtNetwork)) ;;
        QtQml)     FLAGS+=(-I "$LIBPYSIDEQML_SRC" $(qt_header_flags QtQml)) ;;
        QtQuick)   FLAGS+=(-I "$LIBPYSIDEQML_SRC" $(qt_header_flags QtQml) $(qt_header_flags QtQuick)) ;;
    esac
}

is_extra_source() {
    case "$1" in pysideqmlvolatilebool.cpp|pysidequickregistertype.cpp) return 0;; *) return 1;; esac
}

echo "==> Adding per-module helper + glue sources to module libraries"
echo "    PySide6 sources: $PYSIDE6_SRC"
echo "    moc: $MOC"

total_added=0
for mod in "${MODULES[@]}"; do
    mod_src_dir="$PYSIDE6_SRC/$mod"
    lib="$OUT_DIR/libPySide6_${mod}.a"
    [ -d "$mod_src_dir" ] || { echo "    (skip $mod: no $mod_src_dir)"; continue; }
    [ -f "$lib" ] || { echo "    (skip $mod: $lib not built)"; continue; }

    base_cxxflags "$mod"
    obj_dir="$P6IOS_ROOT/build/$(echo "$mod" | tr 'A-Z' 'a-z')-ios/helpers"
    mkdir -p "$obj_dir"
    added=()

    # moc include flags: QtCore always, plus this module's framework headers
    # (e.g. qpytextobject.cpp in QtGui needs QtGui headers for moc to parse it).
    moc_inc=(-I "$QT_IOS/include"
             -I "$QT_IOS/lib/QtCore.framework/Headers"
             -I "$QT_IOS/lib/QtCore.framework/Headers/$QT_VERSION")
    if [ -d "$QT_IOS/lib/$mod.framework/Headers" ]; then
        moc_inc+=(-I "$QT_IOS/lib/$mod.framework/Headers"
                  -I "$QT_IOS/lib/$mod.framework/Headers/$QT_VERSION")
    fi

    # Compile one PySide6 source DIRECTLY (the way CMake's target_sources does):
    # if it uses the included-moc idiom (#include "<base>.moc"), generate that
    # .moc first, then compile the .cpp itself.
    #
    # Note on glue/: real source files there (qiopipe.cpp, qtcorehelper.cpp)
    # compile and define symbols. Pure @snippet files (core_snippets.cpp,
    # qeasingcurve_glue.cpp) are NOT standalone — compiling them yields no
    # symbols, and that is fine: their definitions are injected into the
    # generated *_module_wrapper.cpp by shiboken once the glue dirs are on the
    # typesystem path (see ci/patch_toolkit_glue_paths.sh). The verification gate
    # below confirms every required symbol ends up defined regardless of source.
    compile_src() {
        local src="$1" b base obj
        b="$(basename "$src")"; base="${b%.cpp}"
        case "$b" in *_wrapper.cpp) return 0;; esac      # generated wrappers built elsewhere
        is_extra_source "$b" && return 0                 # toolkit already builds these
        if grep -Eq "#include[[:space:]]+\"${base}\.moc\"" "$src"; then
            echo "    [$mod] moc: ${base}.moc"
            if ! "$MOC" "${moc_inc[@]}" -I "$(dirname "$src")" "$src" \
                    -o "$(dirname "$src")/${base}.moc" 2>/tmp/me.$$; then
                echo "      WARN: moc failed for $b:" >&2; tail -6 /tmp/me.$$ >&2
            fi
        fi
        obj="$obj_dir/${base}.o"
        echo "    [$mod] source: ${src#"$mod_src_dir/"}"
        if $CXX "${FLAGS[@]}" -I "$(dirname "$src")" -c "$src" -o "$obj" 2>/tmp/ce.$$; then
            added+=("$obj")
        else
            echo "      WARN: $b did not compile:" >&2; tail -8 /tmp/ce.$$ >&2
        fi
        rm -f /tmp/me.$$ /tmp/ce.$$
    }

    # (a) sources directly under the module dir
    for src in "$mod_src_dir"/*.cpp; do
        [ -e "$src" ] || continue
        compile_src "$src"
    done
    # (b) glue sources — also real compilable sources (target_sources upstream)
    if [ -d "$mod_src_dir/glue" ]; then
        for src in "$mod_src_dir/glue"/*.cpp; do
            [ -e "$src" ] || continue
            compile_src "$src"
        done
    fi

    if [ "${#added[@]}" -gt 0 ]; then
        echo "    [$mod] appending ${#added[@]} object(s) to $(basename "$lib")"
        xcrun -sdk iphoneos libtool -static -o "$lib" "$lib" "${added[@]}"
        total_added=$((total_added + ${#added[@]}))
    fi

    # --- VERIFICATION GATE: every required symbol must now be DEFINED ---
    missing_syms=()
    while IFS= read -r sym; do
        [ -n "$sym" ] || continue
        # A defined symbol shows a type letter other than 'U'. Search demangled.
        if nm "$lib" 2>/dev/null | c++filt | grep -F "$sym" | grep -qvE '^[[:xdigit:]]* *U '; then
            : # found at least one non-undefined occurrence
        else
            # Either absent entirely, or only undefined references exist.
            if nm "$lib" 2>/dev/null | c++filt | grep -qF "$sym"; then
                missing_syms+=("$sym (only undefined refs)")
            else
                missing_syms+=("$sym (absent)")
            fi
        fi
    done < <(required_symbols "$mod")

    if [ "${#missing_syms[@]}" -gt 0 ]; then
        echo "ERROR: libPySide6_${mod}.a is still missing required symbols:" >&2
        printf '    - %s\n' "${missing_syms[@]}" >&2
        echo "    The helper/glue sources for $mod did not define them. Build cannot proceed." >&2
        exit 1
    fi
    echo "    [$mod] verification OK — all required symbols defined."
done

echo "==> Done. Added $total_added object(s); all module libraries verified."
