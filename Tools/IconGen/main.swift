import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders the app icon variants from HermesMarkPath.swift.
// Usage: swiftc -O Tools/IconGen/main.swift App/Design/HermesMarkPath.swift -o $TMPDIR/icongen && $TMPDIR/icongen <output-dir>

enum Variant: String, CaseIterable {
    case light = "AppIcon"          // default ("Any") appearance
    case dark = "AppIcon-Dark"      // iOS dark appearance: transparent background
    case tinted = "AppIcon-Tinted"  // iOS tinted appearance: grayscale on black
    case preview = "MarkPreview"    // mark on white, for eyeballing
    case dev = "AppIconDev"         // Debug builds ("Hermes Dev"): amber, so they never pass for the real app
}

func render(_ variant: Variant, size: Int, macBody: Bool = false) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let canvas = CGFloat(size)
    // Flip to a top-left origin so the design grid reads the same as SwiftUI.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)
    var full = CGRect(x: 0, y: 0, width: canvas, height: canvas)

    if macBody {
        // macOS icon grid: an 824 pt body centred in 1024 pt, with a soft drop shadow.
        let unit = canvas / 1024
        full = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let body = CGPath(roundedRect: full, cornerWidth: 185.4 * unit, cornerHeight: 185.4 * unit, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 10 * unit), blur: 22 * unit, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(body)
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.addPath(body)
        context.clip()
    }
    let s = full.width
    context.translateBy(x: full.minX, y: full.minY)
    full.origin = .zero

    switch variant {
    case .light:
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1),
            CGColor(srgbRed: 0.02, green: 0.02, blue: 0.025, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: s * 0.2, y: 0), end: CGPoint(x: s * 0.8, y: s), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // A soft light bloom behind the wing.
        let bloom = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(bloom, startCenter: CGPoint(x: s * 0.62, y: s * 0.36), startRadius: 0, endCenter: CGPoint(x: s * 0.62, y: s * 0.36), endRadius: s * 0.55, options: [])
    case .dev:
        let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.98, green: 0.62, blue: 0.16, alpha: 1),
            CGColor(srgbRed: 0.80, green: 0.30, blue: 0.06, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: s * 0.2, y: 0), end: CGPoint(x: s * 0.8, y: s), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    case .dark:
        break
    case .tinted:
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(full)
    case .preview:
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(full)
    }

    let markRect = full.insetBy(dx: s * 0.14, dy: s * 0.14)
    let mark = HermesMarkPath.path(in: markRect)
    context.addPath(mark)
    switch variant {
    case .preview:
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
    case .tinted:
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
    case .light, .dark, .dev:
        context.saveGState()
        context.clip()
        let ink = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            CGColor(srgbRed: 0.80, green: 0.80, blue: 0.82, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(ink, start: CGPoint(x: 0, y: markRect.minY), end: CGPoint(x: 0, y: markRect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "failed to write \(url.path)")
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for variant in Variant.allCases {
    write(render(variant, size: 1024), to: output.appendingPathComponent("\(variant.rawValue).png"))
}
// macOS wants every size explicitly.
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        write(render(.light, size: points * scale, macBody: true), to: output.appendingPathComponent("AppIcon-mac-\(points)@\(scale)x.png"))
        write(render(.dev, size: points * scale, macBody: true), to: output.appendingPathComponent("AppIconDev-mac-\(points)@\(scale)x.png"))
    }
}
print("wrote icons to \(output.path)")
