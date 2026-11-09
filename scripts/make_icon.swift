// Renders Docklet's app icon at every size macOS needs and packs it into AppIcon.icns.
// Usage: swift scripts/make_icon.swift <output-dir>
import AppKit

let canvas: CGFloat = 1024
// macOS icon grid: an 824pt body centred on the 1024pt canvas, leaving room for the shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Apple's icon shape is a continuous-curvature squircle, not a plain rounded rect.
func squircle(_ rect: CGRect, exponent n: CGFloat = 4.2) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func draw(_ ctx: CGContext) {
    let shape = squircle(body)

    // Drop shadow, baked in as macOS icons expect.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.38))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x15171d)); ctx.fillPath()
    ctx.restoreGState()

    // Body: deep graphite, lit from above — the colour of the Dock's own dark material.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x3a3f4c), rgb(0x22252e), rgb(0x121419)], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    // Soft top bloom, light catching the material.
    ctx.drawRadialGradient(gradient([rgb(0xffffff, 0.10), rgb(0xffffff, 0)], [0, 1]),
                           startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 900), endRadius: 520, options: [])

    // Frosted Dock shelf along the bottom.
    let shelf = CGRect(x: body.minX - 20, y: body.minY - 20, width: body.width + 40, height: 200)
    ctx.setFillColor(rgb(0xffffff, 0.05)); ctx.fill(shelf)
    ctx.setFillColor(rgb(0xffffff, 0.16)); ctx.fill(CGRect(x: shelf.minX, y: shelf.maxY - 2, width: shelf.width, height: 2))
    ctx.restoreGState()

    // Running-indicator dot, like the one under an open app in the Dock.
    ctx.setFillColor(rgb(0xffffff, 0.85))
    ctx.fillEllipse(in: CGRect(x: 512 - 14, y: 190, width: 28, height: 28))

    // The gauge: a 240° arch opening downward, the same shape the Dock tiles draw.
    let centre = CGPoint(x: 512, y: 565)
    let radius: CGFloat = 240, line: CGFloat = 88
    let start: CGFloat = 210 * .pi / 180              // bottom-left end
    let sweep: CGFloat = 240 * .pi / 180
    let fill: CGFloat = 0.68

    func arc(to fraction: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addArc(center: centre, radius: radius, startAngle: start, endAngle: start - sweep * fraction, clockwise: true)
        return p
    }

    ctx.setLineCap(.round); ctx.setLineWidth(line)
    ctx.addPath(arc(to: 1)); ctx.setStrokeColor(rgb(0xffffff, 0.13)); ctx.strokePath()

    let colors = [rgb(0x7cf29a), rgb(0x34c759), rgb(0x1fb8a6)]
    // Glow.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: rgb(0x34c759, 0.75))
    ctx.addPath(arc(to: fill)); ctx.setStrokeColor(rgb(0x34c759)); ctx.strokePath()
    ctx.restoreGState()
    // Gradient stroke.
    ctx.saveGState()
    ctx.addPath(arc(to: fill)); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient(colors, [0, 0.55, 1]),
                           start: CGPoint(x: centre.x - radius, y: centre.y - radius),
                           end: CGPoint(x: centre.x + radius, y: centre.y + radius), options: [])
    // Specular sheen along the top of the stroke.
    ctx.drawLinearGradient(gradient([rgb(0xffffff, 0.35), rgb(0xffffff, 0)], [0, 1]),
                           start: CGPoint(x: 0, y: centre.y + radius + line / 2),
                           end: CGPoint(x: 0, y: centre.y), options: [])
    ctx.restoreGState()

    // Bead at the tip, marking where the value lands.
    let tipAngle = start - sweep * fill
    let tip = CGPoint(x: centre.x + cos(tipAngle) * radius, y: centre.y + sin(tipAngle) * radius)
    ctx.setFillColor(rgb(0xffffff, 0.95))
    ctx.fillEllipse(in: CGRect(x: tip.x - 17, y: tip.y - 17, width: 34, height: 34))

    // Inner edge highlight to finish the material.
    ctx.saveGState()
    ctx.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5))); ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xffffff, 0.30), rgb(0xffffff, 0.04)], [0, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: out.appendingPathComponent("AppIcon-1024.png"))
print(iconset.path)
