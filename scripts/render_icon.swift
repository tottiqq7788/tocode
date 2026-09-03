import AppKit

// 渲染 SF Symbol "folder" 为 PNG，用于生成 app 图标（与菜单栏图标一致）。
let outputPath = CommandLine.arguments[1]
let size: CGFloat = 1024

guard let symbol = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) else {
    fputs("error: folder symbol not found\n", stderr)
    exit(1)
}

let config = NSImage.SymbolConfiguration(pointSize: 800, weight: .regular)
    .applying(.init(paletteColors: [NSColor.systemBlue]))
guard let configured = symbol.withSymbolConfiguration(config) else {
    fputs("error: failed to configure symbol\n", stderr)
    exit(1)
}

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let drawSize = configured.size
let origin = NSPoint(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2)
configured.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("error: failed to encode PNG\n", stderr)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outputPath))
