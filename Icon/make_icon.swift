import AppKit

// Zapret Manager uygulama simgesi üreteci.
// Kullanım: swift make_icon.swift <çıktı.iconset dizini>
// Uygulamanın kimliğiyle uyumlu: mürekkep zemin + aurora-teal parıltı + degrade kalkan.

let teal  = NSColor(red: 0.208, green: 0.878, blue: 0.753, alpha: 1)
let inkTop = NSColor(red: 0.078, green: 0.090, blue: 0.118, alpha: 1)
let inkBot = NSColor(red: 0.039, green: 0.047, blue: 0.063, alpha: 1)
let rgb = CGColorSpaceCreateDeviceRGB()

func renderPNG(_ px: Int) -> Data {
    let S = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: S, height: S)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // macOS simge ızgarası: yuvarlatılmış kare + saydam kenar boşluğu
    let inset = S * 0.0977
    let side = S - inset * 2
    let radius = side * 0.2237
    let rect = CGRect(x: inset, y: inset, width: side, height: side)
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Zemin degrade
    cg.saveGState()
    cg.addPath(squircle); cg.clip()
    let bg = CGGradient(colorsSpace: rgb, colors: [inkTop.cgColor, inkBot.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    // Teal radyal parıltı
    let glow = CGGradient(colorsSpace: rgb,
        colors: [teal.withAlphaComponent(0.50).cgColor, teal.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1])!
    let center = CGPoint(x: S * 0.5, y: S * 0.54)
    cg.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: S * 0.40, options: [])
    cg.restoreGState()

    // Üst kenar ince ışık
    cg.saveGState()
    cg.addPath(squircle)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    cg.setLineWidth(max(1, S * 0.004))
    cg.strokePath()
    cg.restoreGState()

    // Kalkan glifi (uygulamadaki küre ikonuyla aynı sembol)
    let glyphPt = S * 0.46
    let cfg = NSImage.SymbolConfiguration(pointSize: glyphPt, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let g = sym.size
        let origin = CGPoint(x: (S - g.width) / 2, y: (S - g.height) / 2)
        let glyphRect = CGRect(origin: origin, size: g)
        var proposed = glyphRect
        if let mask = sym.cgImage(forProposedRect: &proposed, context: ctx, hints: nil) {
            // Hafif teal gölge ile parıltı
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: S * 0.05, color: teal.withAlphaComponent(0.7).cgColor)
            // Glifi maske olarak kullanıp beyaz→teal degrade ile doldur
            cg.clip(to: glyphRect, mask: mask)
            let shieldGrad = CGGradient(colorsSpace: rgb,
                colors: [NSColor.white.cgColor, teal.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(shieldGrad,
                start: CGPoint(x: 0, y: origin.y + g.height),
                end: CGPoint(x: 0, y: origin.y), options: [])
            cg.restoreGState()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("kullanım: make_icon.swift <iconset dizini>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// iconutil için gereken boyut/isim eşlemesi
let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for e in entries {
    let data = renderPNG(e.px)
    try data.write(to: outDir.appendingPathComponent(e.name))
}
print("iconset yazıldı: \(outDir.path)")
