// Draws the app icon and writes a 1024×1024 PNG. Usage: swift scripts/make-icon.swift out.png
// scripts/make-icon.sh turns that PNG into app/AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Background: the standard macOS rounded square (824 pt inside a 1024 pt canvas) with a soft shadow.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(platePath)
ctx.setFillColor(rgb(0x1B2447))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [rgb(0x34478F), rgb(0x141B38)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// A faint browser window on the right.
let window = CGRect(x: 520, y: 232, width: 470, height: 560)
ctx.addPath(CGPath(roundedRect: window, cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.setFillColor(rgb(0xFFFFFF, 0.10))
ctx.fillPath()
ctx.addPath(CGPath(roundedRect: CGRect(x: 520, y: 700, width: 470, height: 92),
                   cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.setFillColor(rgb(0xFFFFFF, 0.10))
ctx.fillPath()
for (index, width) in [300, 240, 270].enumerated() {
    let line = CGRect(x: 580, y: 610 - CGFloat(index) * 96, width: CGFloat(width), height: 34)
    ctx.addPath(CGPath(roundedRect: line, cornerWidth: 17, cornerHeight: 17, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, 0.13))
    ctx.fillPath()
}
ctx.restoreGState()

// Three bubbles in a column on the left.
let colors: [UInt32] = [0x5B9BFF, 0x3DD6A3, 0xFFA552]
for (index, color) in colors.enumerated() {
    let center = CGPoint(x: 330, y: 512 + CGFloat(1 - index) * 226)
    let radius: CGFloat = 96
    let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: rgb(0x000000, 0.45))
    ctx.setFillColor(rgb(color))
    ctx.fillEllipse(in: circle)
    ctx.restoreGState()
    // Soft highlight, then the white ring.
    ctx.saveGState()
    ctx.addEllipse(in: circle)
    ctx.clip()
    let shine = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.38), rgb(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: center.x, y: center.y + radius),
                           end: CGPoint(x: center.x, y: center.y - radius * 0.2), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.95))
    ctx.setLineWidth(14)
    ctx.strokeEllipse(in: circle.insetBy(dx: 7, dy: 7))
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
