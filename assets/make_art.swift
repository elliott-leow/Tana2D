// Draws the app icon and the disk image background.
// usage: swift assets/make_art.swift <output directory>
// Writes Tana2D.iconset/ (for iconutil) and dmg-background.png, dmg-background@2x.png.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func render(_ width: Int, _ height: Int, scale: CGFloat, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    // The context already maps rep.size points onto the pixels.
    // Draw top-down like a page.
    cg.translateBy(x: 0, y: CGFloat(height) / scale); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func gradient(_ cg: CGContext, _ colors: [NSColor], _ locations: [CGFloat], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map { $0.cgColor } as CFArray, locations: locations)!
    cg.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// A window on the plane: a rounded card with a title bar and three dots.
func card(_ cg: CGContext, _ rect: CGRect, fill: NSColor, bar: NSColor, dots: Bool, radius: CGFloat) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.addPath(path); cg.setFillColor(fill.cgColor); cg.fillPath()
    cg.saveGState(); cg.addPath(path); cg.clip()
    let barHeight = max(rect.height * 0.16, radius * 1.2)
    cg.setFillColor(bar.cgColor); cg.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: barHeight))
    cg.restoreGState()
    if dots {
        let d = barHeight * 0.36
        for (i, c) in [0xff5f57, 0xfebc2e, 0x28c840].enumerated() {
            cg.setFillColor(color(UInt32(c)).cgColor)
            cg.fillEllipse(in: CGRect(x: rect.minX + barHeight * 0.45 + CGFloat(i) * d * 1.6, y: rect.minY + (barHeight - d) / 2, width: d, height: d))
        }
    }
}

// MARK: Icon

func icon(_ px: Int) -> NSBitmapImageRep {
    render(px, px, scale: CGFloat(px) / 1024) { cg in
        // Apple's icon grid: an 824-point rounded square centred in 1024.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x000000, 0.35).cgColor)
        cg.addPath(shape); cg.setFillColor(color(0x0b1020).cgColor); cg.fillPath()
        cg.restoreGState()
        cg.saveGState(); cg.addPath(shape); cg.clip()
        gradient(cg, [color(0x18234a), color(0x0a0e1e)], [0, 1], from: CGPoint(x: 200, y: 100), to: CGPoint(x: 820, y: 924))
        // The plane's dot grid.
        cg.setFillColor(color(0xffffff, 0.07).cgColor)
        var y: CGFloat = 132
        while y < 924 { var x: CGFloat = 132; while x < 924 { cg.fillEllipse(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)); x += 56 }; y += 56 }
        // Neighbouring windows, receding off the edges.
        let ghost = color(0xffffff, 0.13), ghostBar = color(0xffffff, 0.10)
        card(cg, CGRect(x: 40, y: 250, width: 220, height: 300), fill: ghost, bar: ghostBar, dots: false, radius: 30)
        card(cg, CGRect(x: 40, y: 580, width: 220, height: 190), fill: ghost, bar: ghostBar, dots: false, radius: 30)
        card(cg, CGRect(x: 764, y: 180, width: 260, height: 230), fill: ghost, bar: ghostBar, dots: false, radius: 30)
        card(cg, CGRect(x: 764, y: 440, width: 260, height: 330), fill: ghost, bar: ghostBar, dots: false, radius: 30)
        card(cg, CGRect(x: 300, y: 820, width: 424, height: 200), fill: ghost, bar: ghostBar, dots: false, radius: 30)
        card(cg, CGRect(x: 300, y: 0, width: 424, height: 170), fill: ghost, bar: ghostBar, dots: false, radius: 30)
        // The focused window, glowing.
        let focus = CGRect(x: 292, y: 222, width: 440, height: 560)
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 70, color: color(0x4b8bff, 0.75).cgColor)
        cg.addPath(CGPath(roundedRect: focus, cornerWidth: 38, cornerHeight: 38, transform: nil))
        cg.setFillColor(color(0x4b8bff).cgColor); cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: focus, cornerWidth: 38, cornerHeight: 38, transform: nil)); cg.clip()
        gradient(cg, [color(0x6aa2ff), color(0x3a6fe8)], [0, 1], from: CGPoint(x: focus.minX, y: focus.minY), to: CGPoint(x: focus.maxX, y: focus.maxY))
        cg.restoreGState()
        card(cg, focus, fill: .clear, bar: color(0xffffff, 0.22), dots: true, radius: 38)
        // Content lines inside it.
        cg.setFillColor(color(0xffffff, 0.55).cgColor)
        for (i, w) in [300, 240, 330, 200].enumerated() {
            cg.addPath(CGPath(roundedRect: CGRect(x: focus.minX + 50, y: focus.minY + 160 + CGFloat(i) * 70, width: CGFloat(w), height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
            cg.fillPath()
        }
        // A thin rim of light on the tile.
        cg.restoreGState()
        cg.addPath(shape); cg.setStrokeColor(color(0xffffff, 0.12).cgColor); cg.setLineWidth(3); cg.strokePath()
    }
}

let iconset = out.appendingPathComponent("Tana2D.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    save(icon(size), iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    save(icon(size * 2), iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

// MARK: Disk image background
// 640x400 points. Finder draws the icon labels in black (light mode) or white
// (dark mode) and cannot be told otherwise, so the band the labels sit on is a
// mid tone that reads at better than 4:1 against either.

let W: CGFloat = 640, H: CGFloat = 400
let appCenter = CGPoint(x: 180, y: 210), folderCenter = CGPoint(x: 460, y: 210)

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let shadow = NSShadow(); shadow.shadowColor = color(0x000000, 0.25); shadow.shadowBlurRadius = 6; shadow.shadowOffset = NSSize(width: 0, height: -1)
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(0xffffff, alpha), .paragraphStyle: style, .shadow: shadow]
    NSAttributedString(string: string, attributes: attributes).draw(in: CGRect(x: 0, y: y, width: W, height: size * 1.5))
}

func background(scale: CGFloat) -> NSBitmapImageRep {
    render(Int(W * scale), Int(H * scale), scale: scale) { cg in
        gradient(cg, [color(0x2c3a66), color(0x51648f), color(0x6b7ba3), color(0x55658e)], [0, 0.42, 0.72, 1],
                 from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: H))
        // Faint windows on a plane, like the app.
        let ghost = color(0xffffff, 0.06)
        for r in [CGRect(x: -30, y: 40, width: 150, height: 110), CGRect(x: 520, y: 30, width: 170, height: 120),
                  CGRect(x: -40, y: 300, width: 170, height: 130), CGRect(x: 540, y: 290, width: 140, height: 140),
                  CGRect(x: 250, y: 345, width: 140, height: 80)] {
            card(cg, r, fill: ghost, bar: color(0xffffff, 0.05), dots: false, radius: 10)
        }
        // A soft pool of light behind each icon.
        for c in [appCenter, folderCenter] {
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0xffffff, 0.16).cgColor, color(0xffffff, 0).cgColor] as CFArray, locations: [0, 1])!
            cg.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 96, options: [])
        }
        // The arrow from the app to the folder.
        let y = appCenter.y, x0: CGFloat = 262, x1: CGFloat = 372
        cg.setStrokeColor(color(0xffffff, 0.92).cgColor); cg.setLineWidth(7); cg.setLineCap(.round); cg.setLineJoin(.round)
        cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: color(0x000000, 0.25).cgColor)
        cg.move(to: CGPoint(x: x0, y: y)); cg.addQuadCurve(to: CGPoint(x: x1, y: y), control: CGPoint(x: (x0 + x1) / 2, y: y - 26)); cg.strokePath()
        cg.move(to: CGPoint(x: x1 - 20, y: y - 18)); cg.addLine(to: CGPoint(x: x1 + 2, y: y + 1)); cg.addLine(to: CGPoint(x: x1 - 24, y: y + 12)); cg.strokePath()
        cg.setShadow(offset: .zero, blur: 0, color: nil)
        text("Install Tana2D", size: 26, weight: .bold, alpha: 1, y: 34)
        text("Drag the Tana2D icon onto the Applications folder.", size: 15, weight: .medium, alpha: 0.92, y: 74)
        text("Then open it: press ⌘ Space, type Tana2D, and press Return.", size: 14, weight: .semibold, alpha: 0.95, y: 326)
        text("It walks you through the rest.", size: 13, weight: .medium, alpha: 0.85, y: 350)
    }
}

save(background(scale: 1), out.appendingPathComponent("dmg-background.png"))
save(background(scale: 2), out.appendingPathComponent("dmg-background@2x.png"))
