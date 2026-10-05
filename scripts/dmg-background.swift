// Build-time installer artwork, not part of the application.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width = 640
let height = 400

for scale in [1, 2] {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width * scale, pixelsHigh: height * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  bitmap.size = NSSize(width: width, height: height)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  let transform = NSAffineTransform()
  transform.scale(by: CGFloat(scale))
  transform.concat()
  NSColor(srgbRed: 0.141, green: 0.141, blue: 0.141, alpha: 1).setFill()
  NSRect(x: 0, y: 0, width: width, height: height).fill()

  func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, brightness: CGFloat)
  {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: size, weight: weight),
      .foregroundColor: NSColor(white: brightness, alpha: 1),
    ]
    let string = value as NSString
    let bounds = string.size(withAttributes: attributes)
    string.draw(
      at: NSPoint(x: (CGFloat(width) - bounds.width) / 2, y: y),
      withAttributes: attributes)
  }

  text("Install Meeting Notes", y: 324, size: 26, weight: .semibold, brightness: 0.98)
  text("Drag Meeting Notes to Applications", y: 292, size: 16, weight: .regular, brightness: 0.78)

  NSColor(white: 0.7, alpha: 1).setStroke()
  let arrow = NSBezierPath()
  arrow.lineWidth = 5
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  arrow.move(to: NSPoint(x: 283, y: 200))
  arrow.line(to: NSPoint(x: 357, y: 200))
  arrow.move(to: NSPoint(x: 341, y: 216))
  arrow.line(to: NSPoint(x: 357, y: 200))
  arrow.line(to: NSPoint(x: 341, y: 184))
  arrow.stroke()

  text(
    "Once copied, open Meeting Notes from Applications.", y: 42,
    size: 13, weight: .regular, brightness: 0.65)
  NSGraphicsContext.restoreGraphicsState()
  let filename = scale == 1 ? "installer.png" : "installer@2x.png"
  try bitmap.representation(using: .png, properties: [:])!
    .write(to: output.appendingPathComponent(filename))
}
