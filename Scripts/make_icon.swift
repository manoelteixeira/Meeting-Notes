// Draws the app icon and writes Resources/AppIcon.icns.
//
// Generated rather than committed as a binary, so the artwork stays reviewable
// and editable in the same place as everything else.
//
//   swift Scripts/make_icon.swift
import AppKit
import CoreGraphics
import Foundation

/// Renders one square icon at `size` points.
func drawIcon(size: CGFloat) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    // macOS icons sit inside a rounded square with generous margin.
    let inset = size * 0.08
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.225

    context.saveGState()
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(path)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 0.36, green: 0.32, blue: 0.86, alpha: 1),
            CGColor(red: 0.16, green: 0.48, blue: 0.92, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: []
    )
    context.restoreGState()

    // A waveform, tapering from the edges toward the middle, over three
    // "note" rules that read as a written-up page.
    let centerY = body.midY + body.height * 0.06
    let barCount = 11
    let barWidth = body.width * 0.038
    let spacing = body.width * 0.062
    let totalWidth = CGFloat(barCount - 1) * spacing
    let startX = body.midX - totalWidth / 2
    // Deterministic, hand-tuned heights so the shape reads as speech.
    let heights: [CGFloat] = [0.18, 0.34, 0.55, 0.78, 0.46, 1.0, 0.42, 0.72, 0.5, 0.3, 0.16]

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
    for index in 0..<barCount {
        let height = body.height * 0.30 * heights[index]
        let x = startX + CGFloat(index) * spacing - barWidth / 2
        let bar = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
        context.addPath(
            CGPath(
                roundedRect: bar,
                cornerWidth: barWidth / 2,
                cornerHeight: barWidth / 2,
                transform: nil
            )
        )
        context.fillPath()
    }

    // Three text rules beneath, the shortest last, like a finished paragraph.
    let ruleHeight = body.height * 0.030
    let ruleWidths: [CGFloat] = [0.62, 0.62, 0.40]
    var ruleY = body.minY + body.height * 0.235
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.62))
    for width in ruleWidths.reversed() {
        let ruleWidth = body.width * width
        let rule = CGRect(
            x: body.midX - ruleWidth / 2,
            y: ruleY,
            width: ruleWidth,
            height: ruleHeight
        )
        context.addPath(
            CGPath(
                roundedRect: rule,
                cornerWidth: ruleHeight / 2,
                cornerHeight: ruleHeight / 2,
                transform: nil
            )
        )
        context.fillPath()
        ruleY += ruleHeight * 2.4
    }

    return context.makeImage()
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "build/AppIcon.iconset", directoryHint: .isDirectory)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes iconutil expects, each in 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        guard let image = drawIcon(size: CGFloat(base * scale)) else {
            fatalError("could not render \(base)@\(scale)x")
        }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let url = iconset.appending(path: name, directoryHint: .notDirectory)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("could not encode \(name)")
        }
        try data.write(to: url)
    }
}

let output = root.appending(path: "Resources/AppIcon.icns", directoryHint: .notDirectory)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
