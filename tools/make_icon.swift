// Generates the app icon PNGs (light, dark, tinted) into the given directory.
//
//   swift tools/make_icon.swift WikiReader/Assets.xcassets/AppIcon.appiconset
//
// An open book with seven waveform bars above the spine, on a blue gradient. The icon is a plain
// 1024x1024 render, so changing a color or shape here and re-running is all that's needed;
// Contents.json in the icon set already references the three file names.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Variant { case light, dark, tinted }

func render(_ v: Variant, to path: String) {
    let s = 1024
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

    func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])!
    }

    // Background
    let top: CGColor, bottom: CGColor, page: CGColor, line: CGColor
    switch v {
    case .light:
        top = rgb(76, 139, 245); bottom = rgb(28, 54, 150)
        page = rgb(255, 255, 255); line = rgb(60, 100, 200, 0.35)
    case .dark:
        top = rgb(30, 41, 70); bottom = rgb(8, 12, 28)
        page = rgb(226, 234, 252); line = rgb(60, 80, 140, 0.45)
    case .tinted:
        top = rgb(0, 0, 0); bottom = rgb(0, 0, 0)
        page = rgb(255, 255, 255); line = rgb(0, 0, 0, 0.35)
    }
    let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(s)), end: .zero, options: [])

    // Open book (y axis points up)
    let cx: CGFloat = 512
    func pagePath(mirror: Bool) -> CGPath {
        let m: CGFloat = mirror ? -1 : 1
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx + m * 10, y: 230))
        p.addLine(to: CGPoint(x: cx + m * 340, y: 290))
        p.addLine(to: CGPoint(x: cx + m * 340, y: 590))
        p.addQuadCurve(to: CGPoint(x: cx + m * 10, y: 540), control: CGPoint(x: cx + m * 180, y: 625))
        p.closeSubpath()
        return p
    }
    ctx.setFillColor(page)
    ctx.addPath(pagePath(mirror: false)); ctx.fillPath()
    ctx.addPath(pagePath(mirror: true)); ctx.fillPath()

    // Text lines on the pages
    ctx.setStrokeColor(line)
    ctx.setLineWidth(18)
    ctx.setLineCap(.round)
    for side in [-1.0, 1.0] {
        let m = CGFloat(side)
        for (i, y) in [470.0, 400.0, 330.0].enumerated() {
            let drop = CGFloat(i) * 0 // keep lines parallel to the page bottom slope
            let x0 = cx + m * 70, x1 = cx + m * (i == 2 ? 190 : 270)
            let slope: CGFloat = 60.0 / 330.0
            ctx.move(to: CGPoint(x: x0, y: CGFloat(y) + (abs(x0 - cx) - 10) * slope * 1 - drop))
            ctx.addLine(to: CGPoint(x: x1, y: CGFloat(y) + (abs(x1 - cx) - 10) * slope - drop))
            ctx.strokePath()
        }
    }

    // Waveform bars above the spine
    let heights: [CGFloat] = [70, 140, 230, 300, 230, 140, 70]
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(page)
    for (i, h) in heights.enumerated() {
        let x = cx + CGFloat(i - 3) * 82
        ctx.move(to: CGPoint(x: x, y: 790 - h / 2 + 23))
        ctx.addLine(to: CGPoint(x: x, y: 790 + h / 2 - 23))
        ctx.strokePath()
    }

    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let dir = CommandLine.arguments[1]
render(.light, to: dir + "/AppIcon.png")
render(.dark, to: dir + "/AppIcon-Dark.png")
render(.tinted, to: dir + "/AppIcon-Tinted.png")
