import CoreText
import Foundation

struct ProbeCase: Codable {
    let title: String
    let measurement: CellMeasurement
    let displayPositions: [CellDisplayPosition]
}

struct ProbeResult: Codable {
    let operatingSystem: String
    let registeredFontPath: String
    let cases: [ProbeCase]
    let suppliedTestLines: [LineMeasurement]
}

@main
struct GeometryProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "GeometryProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Supply the copied font file path"])
        }
        let fontURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw NSError(domain: "GeometryProbe", code: 2)
        }
        let fixtures = CellFixture.examples + [
            CellFixture(title: "Observed tmux conjunct-vowel pieces", cells: ["ന്", "റെ"]),
            CellFixture(title: "Observed tmux word pieces", cells: ["മ", "ല", "യാ", "ളം"])
        ]
        let cases = try fixtures.map { fixture -> ProbeCase in
            let layout = try CellLayout(cells: fixture.cells)
            let measurement = layout.measurement()
            for run in measurement.geometry.runs {
                guard run.fontURL == fontURL.path else {
                    throw NSError(domain: "GeometryProbe", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Unexpected actual Malayalam run font"])
                }
            }
            return ProbeCase(title: fixture.title, measurement: measurement,
                             displayPositions: layout.positions.map { layout.displayPosition(at: $0.column) })
        }
        let suppliedTestLines = try [
            "Demo-2 പുസ്തകത്തിലെ തലക്കെട്ടാണ്, Test-ലേക്ക് പുതിയ sample text rows ചേർത്തിട്ടുണ്ട്.",
            "കൊണ്ടുപോകും ഒരു ആഴ്ച ക്ഷമ സ്ത്രീ"
        ].map { text -> LineMeasurement in
            let measurement = try LineGeometry(text: text).measurement()
            for run in measurement.runs {
                guard run.fontName == "Monaco" ||
                        (run.fontName == "NotoSansMalayalam-Regular" && run.fontURL == fontURL.path) else {
                    throw NSError(domain: "GeometryProbe", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Unexpected actual mixed-line run font"])
                }
            }
            return measurement
        }
        let result = ProbeResult(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                 registeredFontPath: fontURL.path, cases: cases,
                                 suppliedTestLines: suppliedTestLines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
