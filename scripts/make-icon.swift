// 生成 AppIcon:swift scripts/make-icon.swift
import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "MacTool/Assets.xcassets/AppIcon.appiconset")

func renderIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS 图标网格:1024 画布中内容区 824,圆角约 185
    let scale = size / 1024
    let rect = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185 * scale, yRadius: 185 * scale)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 20 * scale
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.27, blue: 0.93, alpha: 1),
    ])!.draw(in: shape, angle: -60)

    let config = NSImage.SymbolConfiguration(pointSize: 430 * scale, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let file = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        try renderIcon(pixels: points * factor).write(to: outputDir.appendingPathComponent(file))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(factor)x", "filename": file])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outputDir.appendingPathComponent("Contents.json"))
print("已生成 \(images.count) 个图标到 \(outputDir.path)")
