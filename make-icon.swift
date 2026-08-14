import Cocoa

// Генератор иконки приложения. Запускается вручную и кладёт рядом Switcher.icns:
//   swiftc -O make-icon.swift -o make-icon && ./make-icon
// Отдельно от сборки, чтобы каждый build.sh не перерисовывал одно и то же.

/// Рисует иконку заданного размера: скруглённый квадрат с градиентом и белым знаком обмена.
func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Поле вокруг: macOS ожидает, что иконка не занимает квадрат целиком.
    let inset = size * 0.055
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect,
                             xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.47, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.51, green: 0.24, blue: 0.89, alpha: 1)])?
        .draw(in: shape, angle: -90)

    // Знак обмена — единственный элемент, который остаётся читаемым и на 16 пикселях.
    let glyph = "⇄"
    let font = NSFont.systemFont(ofSize: size * 0.62, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let text = NSAttributedString(string: glyph, attributes: attributes)
    let textSize = text.size()
    text.draw(at: NSPoint(x: (size - textSize.width) / 2,
                          y: (size - textSize.height) / 2 + size * 0.01))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: "Switcher.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Набор имён, который ждёт iconutil.
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let rep = drawIcon(size: variant.size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try! data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "Switcher.iconset", "-o", "Switcher.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "готово: Switcher.icns" : "iconutil не справился")
