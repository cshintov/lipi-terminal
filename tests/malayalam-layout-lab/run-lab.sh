#!/bin/bash
set -euo pipefail

lab="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$lab/../.." && pwd)"
build="$root/context/experiments/layout-lab"
mode="${1:-check}"
mkdir -p "$build/module-cache"
frameworks=(-framework CoreText -framework Foundation)
case "$mode" in
    check|measure|measure-lines)
        entry="$lab/LabChecks.swift"
        binary="$build/checks"
        ;;
    view|self-check)
        entry="$lab/LayoutLab.swift"
        bundle="$build/MalayalamLayoutLab.app"
        mkdir -p "$bundle/Contents/MacOS"
        binary="$bundle/Contents/MacOS/MalayalamLayoutLab"
        frameworks+=(-framework AppKit)
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.example.malayalam-layout-lab</string><key>CFBundleExecutable</key><string>MalayalamLayoutLab</string><key>CFBundleName</key><string>Malayalam Layout Laboratory</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/><key>NSQuitAlwaysKeepsWindows</key><false/></dict></plist>' > "$bundle/Contents/Info.plist"
        ;;
    *) printf 'Usage: %s check|measure|measure-lines|view|self-check\n' "$0" >&2; exit 2 ;;
esac

# This compiles only the named first-party lab files, never the iTerm2 project.
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$build/module-cache" \
    "${frameworks[@]}" "$lab/LayoutGeometry.swift" "$lab/CellLayout.swift" "$entry" -o "$binary"
case "$mode" in
    measure) exec env -i HOME="$HOME" PATH=/usr/bin:/bin "$binary" --measure ;;
    measure-lines) exec env -i HOME="$HOME" PATH=/usr/bin:/bin "$binary" --measure-lines ;;
    self-check) exec env -i HOME="$HOME" PATH=/usr/bin:/bin "$binary" --self-check ;;
    view) exec env -i HOME="$HOME" PATH=/usr/bin:/bin "$binary" --demo-interior ;;
    *) exec env -i HOME="$HOME" PATH=/usr/bin:/bin "$binary" ;;
esac
