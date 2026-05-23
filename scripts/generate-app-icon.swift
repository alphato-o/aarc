#!/usr/bin/env swift

// Generates the AARC 1024x1024 app-icon PNG.
//
// Design: dark green canvas (#38503a, matches the brand accent), a
// chunky cream-white wine glass silhouette dead centre, and a thick
// spiral inside the bowl — the "dizzy eye" / drunken haze the founder
// requested. Designed to read at small sizes (down to ~60pt on the
// home screen) so all detail is bold and high-contrast.
//
// Output is a single 1024x1024 PNG. iOS auto-rounds the corners at
// display time and derives all smaller sizes from this master.
//
// Usage:
//   swift scripts/generate-app-icon.swift <output.png>

import Foundation
import CoreGraphics
import AppKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: generate-app-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let size: CGFloat = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("CGContext creation failed\n".data(using: .utf8)!)
    exit(2)
}

// MARK: - Palette

let bgColor = CGColor(red: 56/255, green: 80/255, blue: 58/255, alpha: 1)   // #38503a
let glassColor = CGColor(red: 0.97, green: 0.96, blue: 0.91, alpha: 1)       // cream-white
let swirlColor = bgColor                                                      // green dizzy spiral
let highlightColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.18)         // subtle gloss

// MARK: - Background

ctx.setFillColor(bgColor)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// MARK: - Wine glass silhouette
//
// Coordinates: origin bottom-left, y grows up. We draw a tulip-bowl
// wine glass: wide rim, gentle curve to the stem, slim stem, broad
// base. Symmetric around centreX.

let centerX = size / 2

let rimY: CGFloat = size * 0.82
let bowlBaseY: CGFloat = size * 0.40
let stemTopY: CGFloat = size * 0.38
let stemBottomY: CGFloat = size * 0.16
let baseY: CGFloat = size * 0.13

let rimHalfWidth: CGFloat = size * 0.235
let bowlBottomHalfWidth: CGFloat = size * 0.045   // narrow where bowl meets stem
let stemHalfWidth: CGFloat = size * 0.030
let baseHalfWidth: CGFloat = size * 0.175

let glass = CGMutablePath()

// Start at left rim, go right across rim slightly dipped (wine surface).
glass.move(to: CGPoint(x: centerX - rimHalfWidth, y: rimY))
// Subtle dip across the rim — gives a hint of liquid surface.
glass.addQuadCurve(
    to: CGPoint(x: centerX + rimHalfWidth, y: rimY),
    control: CGPoint(x: centerX, y: rimY - size * 0.012)
)
// Right side of bowl curving down to stem.
glass.addCurve(
    to: CGPoint(x: centerX + bowlBottomHalfWidth, y: bowlBaseY),
    control1: CGPoint(x: centerX + rimHalfWidth * 0.92, y: rimY - size * 0.27),
    control2: CGPoint(x: centerX + rimHalfWidth * 0.55, y: bowlBaseY + size * 0.05)
)
// Right side of stem.
glass.addLine(to: CGPoint(x: centerX + stemHalfWidth, y: stemTopY))
glass.addLine(to: CGPoint(x: centerX + stemHalfWidth, y: stemBottomY))
// Base, right side, slight upward curve at edges for a saucer feel.
glass.addQuadCurve(
    to: CGPoint(x: centerX + baseHalfWidth, y: baseY),
    control: CGPoint(x: centerX + baseHalfWidth * 0.6, y: stemBottomY - size * 0.005)
)
// Base bottom.
glass.addLine(to: CGPoint(x: centerX - baseHalfWidth, y: baseY))
// Base, left side.
glass.addQuadCurve(
    to: CGPoint(x: centerX - stemHalfWidth, y: stemBottomY),
    control: CGPoint(x: centerX - baseHalfWidth * 0.6, y: stemBottomY - size * 0.005)
)
// Stem left.
glass.addLine(to: CGPoint(x: centerX - stemHalfWidth, y: stemTopY))
glass.addLine(to: CGPoint(x: centerX - bowlBottomHalfWidth, y: bowlBaseY))
// Left side of bowl curving up to rim.
glass.addCurve(
    to: CGPoint(x: centerX - rimHalfWidth, y: rimY),
    control1: CGPoint(x: centerX - rimHalfWidth * 0.55, y: bowlBaseY + size * 0.05),
    control2: CGPoint(x: centerX - rimHalfWidth * 0.92, y: rimY - size * 0.27)
)
glass.closeSubpath()

ctx.addPath(glass)
ctx.setFillColor(glassColor)
ctx.fillPath()

// Subtle gloss highlight inside the bowl — a soft curved sliver near
// the upper-left, gives the glass dimension at large sizes without
// being noisy at small ones.
let highlight = CGMutablePath()
highlight.move(to: CGPoint(x: centerX - rimHalfWidth * 0.78, y: rimY - size * 0.04))
highlight.addCurve(
    to: CGPoint(x: centerX - rimHalfWidth * 0.55, y: bowlBaseY + size * 0.14),
    control1: CGPoint(x: centerX - rimHalfWidth * 0.85, y: rimY - size * 0.16),
    control2: CGPoint(x: centerX - rimHalfWidth * 0.75, y: bowlBaseY + size * 0.18)
)
ctx.addPath(highlight)
ctx.setStrokeColor(highlightColor)
ctx.setLineWidth(size * 0.022)
ctx.setLineCap(.round)
ctx.strokePath()

// MARK: - Dizzy spiral inside the bowl

let bowlCenterY: CGFloat = rimY - size * 0.20   // visual centre of the bowl
let maxSpiralRadius: CGFloat = size * 0.155

ctx.setStrokeColor(swirlColor)
ctx.setLineWidth(size * 0.020)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let spiralPath = CGMutablePath()
let revolutions = 3.5
let segments = 220
for i in 0...segments {
    let t = Double(i) / Double(segments)
    let angle = t * revolutions * 2 * .pi
    let radius = CGFloat(t) * maxSpiralRadius
    let x = centerX + cos(angle) * radius
    let y = bowlCenterY + sin(angle) * radius
    if i == 0 {
        spiralPath.move(to: CGPoint(x: x, y: y))
    } else {
        spiralPath.addLine(to: CGPoint(x: x, y: y))
    }
}
ctx.addPath(spiralPath)
ctx.strokePath()

// Tiny solid dot at the spiral's centre — anchors the eye, also
// reads as a pupil in the "dizzy eye" reading.
ctx.setFillColor(swirlColor)
ctx.fillEllipse(in: CGRect(
    x: centerX - size * 0.012,
    y: bowlCenterY - size * 0.012,
    width: size * 0.024,
    height: size * 0.024
))

// MARK: - Save

guard let img = ctx.makeImage() else {
    FileHandle.standardError.write("Failed to make image\n".data(using: .utf8)!)
    exit(3)
}
let bitmap = NSBitmapImageRep(cgImage: img)
guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
    exit(4)
}
do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Wrote \(outputPath) (\(pngData.count) bytes)")
} catch {
    FileHandle.standardError.write("Write failed: \(error)\n".data(using: .utf8)!)
    exit(5)
}
