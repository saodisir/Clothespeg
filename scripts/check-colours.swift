#!/usr/bin/env swift
//
//  check-colours.swift — how many oranges does this app have?
//
//  The app has one accent: clay `#d97757`. It is easy to say and easy to lose:
//  a second orange appears as a literal in a view that "just needed to look a
//  bit warmer", and nothing about a screenshot says which file it came from.
//  So the rule is mechanical: every colour literal lives in `CDSTokens.swift`,
//  and no other file may introduce an orange.
//
//  Run: `swift scripts/check-colours.swift` (exit 1 on an orange outside the
//  tokens). Named system colours — `.systemOrange` on a permission row, the
//  editor's own pen palette — are listed but not judged: they are semantic,
//  not decoration, and which of them is right is a design question rather than
//  a grep.
//
import Foundation

let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // scripts
    .deletingLastPathComponent()   // repo root
    .appendingPathComponent("Sources")

let tokens = "CDSTokens.swift"

struct Literal {
    let file: String
    let line: Int
    let red: Double
    let green: Double
    let blue: Double

    var hex: String {
        String(format: "#%02x%02x%02x",
               Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// Hue in degrees, saturation and brightness — enough to say "this is an
    /// orange" without pulling in AppKit.
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let high = max(red, green, blue), low = min(red, green, blue)
        let delta = high - low
        var hue: Double = 0
        if delta > 0.0001 {
            if high == red {
                hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if high == green {
                hue = 60 * ((blue - red) / delta + 2)
            } else {
                hue = 60 * ((red - green) / delta + 4)
            }
        }
        if hue < 0 { hue += 360 }
        return (hue, high > 0.0001 ? delta / high : 0, high)
    }

    /// Warm, saturated, and not red — the band clay sits in, and the band a
    /// "second orange" would land in whichever way it was mixed.
    var isOrange: Bool {
        let hs = hsb
        return hs.hue >= 10 && hs.hue <= 45 && hs.saturation >= 0.25 && hs.brightness >= 0.2
    }
}

let pattern = try NSRegularExpression(
    pattern: #"(?:Color\(red:|NSColor\(srgbRed:)\s*([0-9.]+),\s*green:\s*([0-9.]+),\s*blue:\s*([0-9.]+)"#)

var literals: [Literal] = []
var whites = 0

func walk(_ dir: URL) {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        if file.hasDirectoryPath { walk(file); continue }
        guard file.pathExtension == "swift" else { continue }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let name = file.lastPathComponent
        var line = 1
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let string = String(raw)
            if string.contains("NSColor(white:") { whites += 1 }
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            for match in pattern.matches(in: string, range: range) {
                func value(_ index: Int) -> Double {
                    guard let r = Range(match.range(at: index), in: string) else { return 0 }
                    return Double(string[r]) ?? 0
                }
                literals.append(Literal(file: name, line: line,
                                        red: value(1), green: value(2), blue: value(3)))
            }
            line += 1
        }
    }
}

walk(sources)

// One entry per value, with the places it is written down. Three files defining
// the same hex is the failure this list is for: the values agree today and
// drift the first time one of them is "slightly warmed".
var groups: [String: [Literal]] = [:]
for literal in literals { groups[literal.hex, default: []].append(literal) }
let sorted = groups.sorted { $0.key < $1.key }

print("colours: \(literals.count) literals, \(whites) greys in NSColor(white:), \(groups.count) distinct values")
for (hex, places) in sorted {
    let first = places[0]
    let hs = first.hsb
    let tag = first.isOrange ? "orange" : (hs.saturation < 0.12 ? "grey  " : "       ")
    let where_ = places.map { "\($0.file):\($0.line)" }.joined(separator: " ")
    print(String(format: "  %@ %@ hue %3.0f° sat %2.0f%%  ×%d  %@",
                 hex, tag, hs.hue, hs.saturation * 100, places.count, where_))
}

let oranges = literals.filter(\.isOrange)
let strays = oranges.filter { $0.file != tokens }
print("")
print("colours: \(oranges.count) orange literal(s) in \(Set(oranges.map(\.file)).sorted().joined(separator: ", "))")
if strays.isEmpty {
    print("colours: no orange outside CDSTokens.swift ok")
} else {
    for stray in strays {
        print("colours: WRONG — \(stray.hex) at \(stray.file):\(stray.line); oranges live in \(tokens)")
    }
}
exit(strays.isEmpty ? 0 : 1)
