// Renders the Kontor app icon — a rising line across ledger rules on a deep blue tile — into an
// .iconset directory. Usage: swift Scripts/make-icon.swift <output.iconset>
//
// The geometry mirrors `KontorMark` in Sources/Kontor/KontorMark.swift (the in-app version).
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

/// Draws the icon into a square canvas of `pixels` using the macOS icon grid: an 824/1024 tile with
/// continuous corners, centred, with a soft drop shadow.
func renderIcon(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let canvas = CGFloat(pixels)
    let tileSize = canvas * 824 / 1024
    let origin = (canvas - tileSize) / 2
    let tile = CGRect(x: origin, y: origin, width: tileSize, height: tileSize)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tileSize * 0.225, cornerHeight: tileSize * 0.225, transform: nil)

    // Shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012), blur: canvas * 0.03, color: color(0x000000, alpha: 0.3))
    context.addPath(tilePath)
    context.setFillColor(color(0x0C2744))
    context.fillPath()
    context.restoreGState()

    // Tile gradient.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x1F5A94), color(0x0C2744)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // A faint top highlight gives the tile some depth.
    let highlight = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, alpha: 0.10), color(0xFFFFFF, alpha: 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(highlight, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
    context.restoreGState()

    // Unit coordinates inside the tile, y up.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * tileSize, y: tile.minY + y * tileSize) }

    // Ledger rules.
    context.setLineCap(.round)
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.16))
    context.setLineWidth(tileSize * 0.022)
    for y in [0.30, 0.43, 0.56, 0.69] as [CGFloat] {
        context.move(to: p(0.20, y))
        context.addLine(to: p(0.80, y))
        context.strokePath()
    }

    // Rising line, stroked with a mint → white gradient.
    let points = [p(0.20, 0.34), p(0.36, 0.47), p(0.49, 0.40), p(0.65, 0.60), p(0.80, 0.71)]
    context.saveGState()
    context.setLineJoin(.round)
    context.setLineWidth(tileSize * 0.062)
    context.addLines(between: points)
    context.replacePathWithStrokedPath()
    context.clip()
    let lineGradient = CGGradient(colorsSpace: space, colors: [color(0x7CE7C0), color(0xFFFFFF)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(lineGradient, start: p(0.2, 0.3), end: p(0.8, 0.7), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    // End point.
    let r = tileSize * 0.055
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: points[4].x - r, y: points[4].y - r, width: r * 2, height: r * 2))

    return context.makeImage()!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let image = renderIcon(pixels: points * scale)
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("failed to write \(name)\n".utf8))
        exit(1)
    }
}
