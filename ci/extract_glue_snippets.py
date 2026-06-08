#!/usr/bin/env python3
"""
extract_glue_snippets.py — extract compilable "native" snippet bodies from
PySide6 glue files into a single .cpp translation unit.

WHY: PySide glue files (e.g. PySide6/QtCore/glue/core_snippets.cpp) are NOT
plain source files. They are a sequence of regions delimited by

    // @snippet <name>
    ...C++...
    // @snippet <name>      (next region begins / previous ends)

Shiboken normally splices these into generated wrappers via <inject-code>. When
shiboken cannot resolve the glue path, it emits the call sites but DROPS the
native definitions, producing undefined symbols at link time (init_QThread,
qObjectFindChild, QVariant_*, PySideEasingCurveFunctor::*, PySide::addPostRoutine,
Py{Date,Time,DateTime}_ImportAndCheck, ...).

This script deterministically reconstructs those definitions: it keeps only
snippet regions that are COMPLETE, standalone C++ (balanced braces, no shiboken
placeholders like %PYARG, %CPPSELF, %0, cppArg, pyResult, sbk*), and writes them
into one TU that #includes the generated module umbrella header. That TU is then
compiled and archived by the caller.

Usage:
    extract_glue_snippets.py --module QtCore \
        --glue-dir   /path/PySide6/QtCore/glue \
        --umbrella   pyside6_qtcore_python.h \
        --out        /path/build/qtcore-ios/helpers/qtcore_glue_extracted.cpp
"""
from __future__ import annotations
import argparse, re, sys
from pathlib import Path

# Tokens that mark a snippet as shiboken target-fragment (NOT standalone C++).
PLACEHOLDER_RE = re.compile(
    r"%PYARG|%CPPSELF|%PYSELF|%RETURN_TYPE|%ARGUMENT_NAMES|%FUNCTION_NAME"
    r"|%CONVERTTOPYTHON|%CONVERTTOCPP|%CHECKTYPE|%ARG\d|%\d|%PYTHONTYPEOBJECT"
    r"|%BEGIN_ALLOW_THREADS|%END_ALLOW_THREADS|\bcppArg\b|\bpyResult\b"
    r"|\bcppSelf\b|\bpythonSelf\b"
)

SNIPPET_HDR = re.compile(r"^//\s*@snippet\s+(\S+)\s*$")


def parse_snippets(text: str):
    """Yield (name, body) for each // @snippet <name> region."""
    lines = text.splitlines()
    cur_name = None
    cur_body: list[str] = []
    for ln in lines:
        m = SNIPPET_HDR.match(ln.strip())
        if m:
            if cur_name is not None:
                yield cur_name, "\n".join(cur_body)
            cur_name = m.group(1)
            cur_body = []
        else:
            if cur_name is not None:
                cur_body.append(ln)
    if cur_name is not None:
        yield cur_name, "\n".join(cur_body)


def is_standalone(body: str) -> bool:
    """Heuristic: complete C++ (balanced braces, has a definition, no shiboken
    placeholders)."""
    if not body.strip():
        return False
    if PLACEHOLDER_RE.search(body):
        return False
    # Must contain at least one function/struct/class body.
    if "{" not in body or "}" not in body:
        return False
    # Balanced braces / parens (cheap check, ignores strings but good enough to
    # reject fragment snippets that are clearly partial).
    if body.count("{") != body.count("}"):
        return False
    if body.count("(") != body.count(")"):
        return False
    # Reject snippets that are obviously statement fragments (start with a
    # statement keyword rather than a declaration).
    first = next((l.strip() for l in body.splitlines() if l.strip()
                  and not l.strip().startswith("//")), "")
    if re.match(r"^(return|if|for|while|switch|delete|Py_|Shiboken::|auto\s+\w+\s*=)",
                first):
        return False
    return True


def destatic(body: str) -> str:
    """Give extracted definitions EXTERNAL linkage.

    Snippet helpers are written `static` because shiboken normally injects them
    into the single wrapper TU that uses them. We compile them in one separate
    TU instead, and they are referenced from *multiple* wrapper objects
    (e.g. qObjectFindChild from qobject_wrapper.o), so they must be external.
    Strip a leading `static` from top-level definitions (not inside braces).
    """
    out = []
    depth = 0
    for line in body.splitlines():
        stripped = line.lstrip()
        if depth == 0 and stripped.startswith("static "):
            # remove only the leading 'static ' keyword, preserve indentation
            indent = line[: len(line) - len(stripped)]
            line = indent + stripped[len("static "):]
        out.append(line)
        depth += line.count("{") - line.count("}")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--module", required=True)
    ap.add_argument("--glue-dir", required=True)
    ap.add_argument("--umbrella", required=True,
                    help="generated umbrella header, e.g. pyside6_qtcore_python.h")
    ap.add_argument("--out", required=True)
    ap.add_argument("--extra-include", action="append", default=[],
                    help="additional #include <...> lines to prepend")
    args = ap.parse_args()

    glue_dir = Path(args.glue_dir)
    if not glue_dir.is_dir():
        print(f"extract: no glue dir {glue_dir}", file=sys.stderr)
        # Not fatal: some modules have no glue.
        Path(args.out).write_text("// no glue dir\n")
        return 0

    kept = []   # (file, name)
    bodies = []
    seen_sigs = set()   # de-dup identical snippet bodies across files
    for cpp in sorted(glue_dir.glob("*.cpp")):
        text = cpp.read_text(errors="replace")
        # Files that use the included-moc idiom or have real out-of-line defs are
        # compiled directly by the caller; here we only mine @snippet regions.
        if "// @snippet" not in text:
            continue
        for name, body in parse_snippets(text):
            if not is_standalone(body):
                continue
            body = destatic(body)
            sig = body.strip()
            if sig in seen_sigs:
                continue
            seen_sigs.add(sig)
            bodies.append(f"// ---- {cpp.name} : @snippet {name} ----\n{body}\n")
            kept.append((cpp.name, name))

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w") as f:
        f.write("// AUTO-GENERATED: native glue snippet definitions extracted "
                "for static linking.\n")
        f.write("// Do not edit. Produced by ci/extract_glue_snippets.py\n")
        f.write("#include <sbkpython.h>\n")
        f.write("#include <shiboken.h>\n")
        for inc in args.extra_include:
            f.write(f"#include {inc}\n")
        f.write(f'#include "{args.umbrella}"\n\n')
        f.write("\n".join(bodies))
        f.write("\n")

    print(f"extract[{args.module}]: kept {len(kept)} standalone snippet(s) "
          f"from {glue_dir}")
    for fn, nm in kept:
        print(f"    + {fn}:{nm}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
