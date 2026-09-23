import AppKit
import Foundation

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in sizes {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else { fatalError("Could not create app icon bitmap.") }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.imageInterpolation = .high

  let size = CGFloat(pixels)
  let bounds = NSRect(x: 0, y: 0, width: size, height: size)
  let inset = size * 0.04
  let tile = NSBezierPath(
    roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: size * 0.21,
    yRadius: size * 0.21)
  NSColor(calibratedRed: 0.14, green: 0.37, blue: 0.78, alpha: 1).setFill()
  tile.fill()

  let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
  guard
    let waveform = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
  else { fatalError("Could not create waveform symbol.") }
  let aspect = waveform.size.width / waveform.size.height
  let width = min(size * 0.66, size * 0.56 * aspect)
  let height = width / aspect
  waveform.draw(
    in: NSRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height),
    from: .zero, operation: .sourceOver, fraction: 1)

  context.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode app icon PNG.")
  }
  try png.write(to: iconset.appendingPathComponent(name))
}
