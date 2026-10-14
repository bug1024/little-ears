import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let box = NSRect(x: 40, y: 40, width: 944, height: 944)
let shape = NSBezierPath(roundedRect: box, xRadius: 210, yRadius: 210)
NSColor(srgbRed: 0.09, green: 0.12, blue: 0.16, alpha: 1).setFill(); shape.fill()
for i in 0..<4 {
    let inset = CGFloat(i) * 70 + 120
    let ring = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2))
    NSColor(srgbRed: 0.50, green: 0.78, blue: 0.95, alpha: 0.12 + Double(i) * 0.03).setStroke(); ring.lineWidth = 3; ring.stroke()
}
let config = NSImage.SymbolConfiguration(pointSize: 320, weight: .light).applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(srgbRed: 0.50, green: 0.78, blue: 0.95, alpha: 1)]))
if let symbol = NSImage(systemSymbolName: "ear.badge.waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    symbol.draw(in: NSRect(x: 330, y: 300, width: 364, height: 424))
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
