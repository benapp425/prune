// Draws Prune's app icon: a storage ring on a light tile, with one segment lifted out of the ring.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// The macOS icon shape: a superellipse, not a rounded rectangle.
func squircle(_ r: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = squircle(body)

// Shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
ctx.addPath(tile)
ctx.setFillColor(rgb(0xF4F6F9))
ctx.fillPath()
ctx.restoreGState()

// Tile: soft white-to-cool-gray, like brushed aluminum under studio light.
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xE3E7ED)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tile)
ctx.setStrokeColor(rgb(0x000000, 0.08))
ctx.setLineWidth(2)
ctx.strokePath()
ctx.restoreGState()

let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 212
let width: CGFloat = 100

/// Angles in degrees, clockwise from 12 o'clock.
func rad(_ deg: CGFloat) -> CGFloat { (90 - deg) * .pi / 180 }

func segmentPath(_ from: CGFloat, _ to: CGFloat, offset: CGFloat = 0) -> CGPath {
    let mid = rad((from + to) / 2)
    let c = CGPoint(x: center.x + cos(mid) * offset, y: center.y + sin(mid) * offset)
    let p = CGMutablePath()
    p.addArc(center: c, radius: radius + width / 2, startAngle: rad(from), endAngle: rad(to), clockwise: true)
    p.addArc(center: c, radius: radius - width / 2, startAngle: rad(to), endAngle: rad(from), clockwise: false)
    p.closeSubpath()
    return p
}

func fill(_ path: CGPath, top: UInt32, bottom: UInt32, shadow: CGFloat = 0) {
    ctx.saveGState()
    if shadow > 0 {
        ctx.setShadow(offset: CGSize(width: 0, height: -shadow / 2), blur: shadow, color: rgb(0x0B1E3F, 0.30))
        ctx.addPath(path)
        ctx.setFillColor(rgb(bottom))
        ctx.fillPath()
    }
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    let box = path.boundingBox
    ctx.drawLinearGradient(g, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
    ctx.restoreGState()
}

// Empty track behind the ring.
ctx.saveGState()
ctx.addPath(segmentPath(0, 360))
ctx.setFillColor(rgb(0x0F172A, 0.06))
ctx.fillPath()
ctx.restoreGState()

let gap: CGFloat = 3.5
fill(segmentPath(0 + gap, 128 - gap), top: 0x3B82F6, bottom: 0x1D4ED8, shadow: 6)
fill(segmentPath(128 + gap, 206 - gap), top: 0x6D7BF2, bottom: 0x4F46E5, shadow: 6)
fill(segmentPath(206 + gap, 262 - gap), top: 0x9AA9C2, bottom: 0x6B7A93, shadow: 6)

// The segment being removed, lifted out of the ring.
fill(segmentPath(262 + gap, 330 - gap, offset: 38), top: 0x2DD4BF, bottom: 0x0D9488, shadow: 20)

// Inner face.
ctx.saveGState()
let inner = radius - width / 2 - 24
ctx.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
ctx.clip()
let face = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xEEF1F5)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(face, start: CGPoint(x: 0, y: center.y + inner), end: CGPoint(x: 0, y: center.y - inner), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
ctx.setStrokeColor(rgb(0x0F172A, 0.07))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
