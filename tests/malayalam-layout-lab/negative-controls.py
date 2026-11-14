#!/usr/bin/env python3
"""Run targeted defects in generated copies, never modify retained lab source."""
import hashlib
import json
import argparse
from pathlib import Path
import subprocess
from tempfile import mkdtemp

LAB = Path(__file__).resolve().parent
ROOT = LAB.parent.parent
BUILD = ROOT / "context/experiments/layout-lab"
ENV = {"HOME": str(Path.home()), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
       "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
CASES = [
    ("invented-interior-caret", "CellLayout.swift",
     "let nativeX = offsets.count == 1 ? offsets[0] : nil",
     "let nativeX = offsets.count == 1 ? offsets[0] + (position.kind == .insideGrapheme ? 1 : 0) : nil",
     "native display caret must not invent or interpolate interior geometry", False),
    ("missing-caret-edges", "LayoutGeometry.swift", "caretEdges: edges", "caretEdges: []",
     "three ASCII characters must expose six leading/trailing caret edges", False),
    ("scaled-caret", "LayoutGeometry.swift",
     "x: Double(CTLineGetOffsetForStringIndex(shapedLine, $0, nil))",
     "x: 0.9 * Double(CTLineGetOffsetForStringIndex(shapedLine, $0, nil))",
     "ASCII caret offsets match font-advance arithmetic", False),
    ("missing-cursor-step", "CellLayout.swift", "cursor += 1", "cursor += 0",
     "cell operations keep the logical grid as the source of text", False),
    ("zero-cell-map", "CellLayout.swift", "rawPrimaryX: primary, rawSecondaryX: secondary",
     "rawPrimaryX: primary * 0, rawSecondaryX: secondary * 0",
     "ASCII caret offsets match font-advance arithmetic", False),
    ("no-delete", "CellLayout.swift", "cells.remove(at: cursor)", "_ = cells[cursor]",
     "delete shifts the suffix, preserves cursor and permits later combining input", False),
    ("no-first-mouse", "LayoutLab.swift",
     "override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }",
     "override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }",
     "mouse must select source column zero", True),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=[case[0] for case in CASES])
    args = parser.parse_args()
    cases = [case for case in CASES if args.case is None or case[0] == args.case]
    evidence = BUILD / "cluster-marker" if args.case == "invented-interior-caret" else BUILD
    if args.case == "invented-interior-caret":
        evidence.mkdir(parents=True, exist_ok=True)
        evidence = Path(mkdtemp(prefix="negative-", dir=evidence))
        print(f"Evidence: {evidence}", flush=True)
    results = []
    for name, filename, old, new, expected, gui in cases:
        print(f"Checking negative control: {name}", flush=True)
        original = (LAB / filename).read_text()
        if original.count(old) != 1:
            raise RuntimeError(f"Mutation site is no longer unique: {filename}")
        folder = evidence / "mutants" / name
        folder.mkdir(parents=True, exist_ok=True)
        mutant = folder / filename
        mutant.write_text(original.replace(old, new))
        entry = "LayoutLab.swift" if gui else "LabChecks.swift"
        sources = [mutant if f == filename else LAB / f
                   for f in ["LayoutGeometry.swift", "CellLayout.swift", entry]]
        binary = folder / "checks"
        frameworks = ["-framework", "CoreText", "-framework", "Foundation"]
        if gui:
            frameworks += ["-framework", "AppKit"]
            bundle = folder / "FirstMouseMutant.app" / "Contents"
            (bundle / "MacOS").mkdir(parents=True, exist_ok=True)
            binary = bundle / "MacOS" / "MalayalamLayoutLab"
            (bundle / "Info.plist").write_text(
                (BUILD / "MalayalamLayoutLab.app/Contents/Info.plist").read_text().replace(
                    "com.example.malayalam-layout-lab", "com.example.malayalam-layout-lab.first-mouse-mutant"))
        command = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors",
                   "-module-cache-path", str(BUILD / "module-cache"), *frameworks,
                   *map(str, sources), "-o", str(binary)]
        compiled = subprocess.run(command, cwd=ROOT, env=ENV, capture_output=True, text=True)
        (folder / "compile.log").write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode != 0:
            raise RuntimeError(f"Compiler failure is not a valid negative control: {folder}")
        run = subprocess.run([str(binary), *(["--self-check"] if gui else [])],
                             cwd=ROOT, env=ENV, capture_output=True, text=True)
        output = run.stdout + run.stderr
        (folder / "run.log").write_text(output)
        killed = run.returncode != 0 and expected in output
        results.append({"mutation": name, "rejected": killed, "exit_code": run.returncode,
                        "expected_check": expected,
                        "original_sha256": hashlib.sha256(original.encode()).hexdigest()})
        if not killed:
            raise RuntimeError(f"Check failed to reject targeted defect: {name}; see {folder}")
    result_name = f"negative-{args.case}.json" if args.case else "negative-controls.json"
    (evidence / result_name).write_text(json.dumps(results, indent=2) + "\n")
    print(f"PASS: all {len(results)} targeted defects rejected by the intended checks")


if __name__ == "__main__":
    main()
