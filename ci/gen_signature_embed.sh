#!/usr/bin/env bash
#
# gen_signature_embed.sh — generate shiboken6's embedded-signature headers.
#
# WHY THIS EXISTS
# ---------------
# libshiboken/signature/signature_globals.cpp does:
#     #include "embed/signature_inc.h"
# That header (and embed/signature_bootstrap_inc.h) is NOT shipped in the
# pyside-setup sources. Upstream, CMake generates it during the build by
# running libshiboken/embed/embedding_generator.py, which embeds the Python
# signature-bootstrap code as a C string array.
#
# pyside6-ios's standalone build_support_libs.sh compiles the libshiboken
# sources directly with clang and never runs that generator, so the header is
# missing and the build fails with:
#     fatal error: 'embed/signature_inc.h' file not found
#
# This script reproduces exactly what CMake does: it runs the upstream
# generator (with the HOST python3 — the embedded bytecode is plain .pyc that
# the on-device interpreter of the same 3.x version loads) so the headers exist
# before build_support_libs.sh compiles signature_globals.cpp.
#
# It is idempotent: if the headers already exist it does nothing.
#
# USAGE
#   ./ci/gen_signature_embed.sh /path/to/pyside6-ios
# or rely on the default (TOOLKIT_DIR env or ./pyside6-ios):
#   TOOLKIT_DIR=$GITHUB_WORKSPACE/pyside6-ios ./ci/gen_signature_embed.sh
#
set -euo pipefail

TOOLKIT_DIR="${1:-${TOOLKIT_DIR:-$PWD/pyside6-ios}}"
PYSIDE_SETUP="$TOOLKIT_DIR/build/pyside-setup"
LIBSHIBOKEN="$PYSIDE_SETUP/sources/shiboken6/libshiboken"
EMBED_DIR="$LIBSHIBOKEN/embed"
PYTHON="${PYTHON:-python3}"

echo "==> Ensuring shiboken signature embed headers exist"
echo "    libshiboken: $LIBSHIBOKEN"

if [ ! -d "$EMBED_DIR" ]; then
    echo "ERROR: $EMBED_DIR not found." >&2
    echo "       Is the pyside-setup checkout present and the version correct?" >&2
    exit 1
fi

GEN="$EMBED_DIR/embedding_generator.py"
INC1="$EMBED_DIR/signature_bootstrap_inc.h"
INC2="$EMBED_DIR/signature_inc.h"

# Idempotent: already generated.
if [ -f "$INC2" ] && [ -f "$INC1" ]; then
    echo "    Already present — nothing to do."
    exit 0
fi

if [ ! -f "$GEN" ]; then
    echo "ERROR: $GEN not found — cannot generate signature headers." >&2
    echo "       Upstream layout may have changed for this PySide version." >&2
    exit 1
fi

# The generator writes its output files into the CURRENT directory using bare
# names (e.g. open('signature_bootstrap_inc.h', 'w')), so it MUST run from
# inside embed/. It also imports sibling modules (signature_bootstrap, and the
# shibokensupport package under ../support), which resolve relative to embed/.
echo "==> Running embedding_generator.py (host $PYTHON) from $EMBED_DIR"
(
    cd "$EMBED_DIR"
    # --use-pyc embeds compiled bytecode (matches the normal CMake build);
    # --limited-api is accepted by newer generators and ignored by older ones
    # because we pass it through parse_known_args-friendly flags only if needed.
    # Try the standard invocation first; fall back without --use-pyc if the
    # flag set differs across versions.
    if "$PYTHON" embedding_generator.py --use-pyc --quiet; then
        :
    elif "$PYTHON" embedding_generator.py --quiet; then
        echo "    (generated without --use-pyc)"
    else
        echo "    Retrying verbose to surface the real error..." >&2
        "$PYTHON" embedding_generator.py --use-pyc
    fi
)

# Verify.
missing=0
for f in "$INC1" "$INC2"; do
    if [ -f "$f" ]; then
        echo "    OK: ${f#"$LIBSHIBOKEN"/}"
    else
        echo "    MISSING: ${f#"$LIBSHIBOKEN"/}" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || {
    echo "ERROR: generator ran but expected headers were not produced." >&2
    echo "       Files now in embed/:" >&2
    ls -la "$EMBED_DIR" >&2
    exit 1
}

echo "==> Signature embed headers ready."
