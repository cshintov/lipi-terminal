//
//  iTermColorMapResolveTests.swift
//  ModernTests
//
//  Tests for iTermColorMap.resolvedColorValue: and resolvedDualModeColor:.
//

import XCTest
@testable import iTerm2SharedARC

final class iTermColorMapResolveTests: XCTestCase {

    private func makeMap(backgroundIsDark: Bool) -> iTermColorMap {
        let map = iTermColorMap()
        // setColor:forKey: with kColorMapBackground updates _backgroundBrightness
        // from the color's perceivedBrightness. Pick saturated black or white
        // for an unambiguous threshold (perceivedBrightness uses BT.709).
        let bg = backgroundIsDark ? NSColor.black : NSColor.white
        map.setColor(bg, forKey: Int32(kColorMapBackground))
        return map
    }

    func testProcessedBackgroundColdCacheAndShortSequences() throws {
        // Zero RGBA is a legitimate first request, including the monochrome offscreen margin path.
        let traces = [[]] + (0..<3).map { [$0] } +
            (0..<3).flatMap { first in (0..<3).map { [first, $0] } }
        for trace in traces {
            var map = makeMap(backgroundIsDark: true)
            var opaque = false
            var whiteBackground = false
            for event in trace.isEmpty ? [-1] : trace {
                switch event {
                case 0: opaque.toggle()
                case 1: map = try XCTUnwrap(map.copy())
                case 2:
                    whiteBackground.toggle()
                    map.setColor(whiteBackground ? .white : .black, forKey: Int32(kColorMapBackground))
                default: break
                }
                let level: CGFloat = opaque ? 0.25 : 0
                let alpha: CGFloat = opaque ? 1 : 0
                let input = NSColor(srgbRed: level, green: level, blue: level, alpha: alpha)
                let result = try XCTUnwrap(map.processedBackgroundColor(forBackgroundColor: input),
                                          "cold/copy/change trace \(trace)")
                let rgb = try XCTUnwrap(result.usingColorSpace(.sRGB))
                XCTAssertEqual(rgb.redComponent, level, accuracy: 0.00001)
                XCTAssertEqual(rgb.greenComponent, level, accuracy: 0.00001)
                XCTAssertEqual(rgb.blueComponent, level, accuracy: 0.00001)
                XCTAssertEqual(rgb.alphaComponent, alpha, accuracy: 0.00001)
                let hit = try XCTUnwrap(map.processedBackgroundColor(forBackgroundColor: input))
                XCTAssertEqual(hit, result, "a populated cache hit preserves the color")
            }
        }
    }

    func testResolvedColorValuePassesThroughWhenNoDarkVariant() {
        let map = makeMap(backgroundIsDark: false)
        let v = VT100TerminalColorValue(red: 11, green: 22, blue: 33, mode: ColorMode24bit,
                                        hasDarkVariant: false, redDark: 0, greenDark: 0, blueDark: 0)
        let r = map.resolvedColorValue(v)
        XCTAssertFalse(r.hasDarkVariant.boolValue)
        XCTAssertEqual(r.red, 11)
        XCTAssertEqual(r.green, 22)
        XCTAssertEqual(r.blue, 33)
    }

    func testResolvedColorValuePicksLightOnLightBackground() {
        let map = makeMap(backgroundIsDark: false)
        let v = VT100TerminalColorValue(red: 11, green: 22, blue: 33, mode: ColorMode24bit,
                                        hasDarkVariant: true, redDark: 44, greenDark: 55, blueDark: 66)
        let r = map.resolvedColorValue(v)
        XCTAssertFalse(r.hasDarkVariant.boolValue)
        XCTAssertEqual(r.red, 11)
        XCTAssertEqual(r.green, 22)
        XCTAssertEqual(r.blue, 33)
    }

    func testResolvedColorValuePicksDarkOnDarkBackground() {
        let map = makeMap(backgroundIsDark: true)
        let v = VT100TerminalColorValue(red: 11, green: 22, blue: 33, mode: ColorMode24bit,
                                        hasDarkVariant: true, redDark: 44, greenDark: 55, blueDark: 66)
        let r = map.resolvedColorValue(v)
        XCTAssertFalse(r.hasDarkVariant.boolValue)
        XCTAssertEqual(r.red, 44)
        XCTAssertEqual(r.green, 55)
        XCTAssertEqual(r.blue, 66)
    }

    // The 24-bit fast path in fastColorForKey:colorSpace: must be bit-identical to
    // the full colorUsingColorSpace: conversion when the target space is the app's
    // native 8-bit space, since it skips that conversion.
    func test24BitFastPathMatchesConversionInNativeSpace() {
        let map = iTermColorMap()
        let native: NSColorSpace = iTermAdvancedSettingsModel.p3() ? .displayP3 : .sRGB
        let red: Int32 = 200, green: Int32 = 100, blue: Int32 = 50
        let key = iTermColorMap.keyFor8bitRed(red, green: green, blue: blue)

        let fast = map.fastColor(forKey: key, colorSpace: native)

        guard let color = NSColor(red, green: green, blue: blue)
            .usingColorSpace(native) else {
            XCTFail("reference conversion failed")
            return
        }
        XCTAssertEqual(fast.x, Float(color.redComponent), accuracy: 1e-5, "red")
        XCTAssertEqual(fast.y, Float(color.greenComponent), accuracy: 1e-5, "green")
        XCTAssertEqual(fast.z, Float(color.blueComponent), accuracy: 1e-5, "blue")
        XCTAssertEqual(fast.w, 1, accuracy: 1e-5, "alpha")
    }

    // The mode field must survive resolution — both light and dark share it.
    func testResolvedColorValuePreservesMode() {
        let map = makeMap(backgroundIsDark: true)
        let v = VT100TerminalColorValue(red: 7, green: 0, blue: 0, mode: ColorModeNormal,
                                        hasDarkVariant: true, redDark: 9, greenDark: 0, blueDark: 0)
        let r = map.resolvedColorValue(v)
        XCTAssertEqual(r.mode, ColorModeNormal)
        XCTAssertEqual(r.red, 9)
    }
}
