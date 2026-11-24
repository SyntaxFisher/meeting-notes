import AppKit
import SwiftUI

/// The icon of the installed Teams app, read from the system so the app ships no Microsoft
/// artwork. Without Teams there is no icon and views show their own symbol instead.
@MainActor
enum TeamsIcon {
  private static var cached: [Bool: NSImage] = [:]

  /// The icon variant for a light or dark interface. `NSWorkspace` only follows the system-wide
  /// icon style, so the variant comes from IconServices, which has no public interface; when
  /// that is unavailable the icon is the one the system-wide style gives.
  static func image(dark: Bool) -> NSImage? {
    if let image = cached[dark] { return image }
    guard
      let app = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: TeamsWindowSource.bundleIdentifier)
    else { return nil }
    let points = NSRect(x: 0, y: 0, width: 64, height: 64)
    var proposed = points
    let icon =
      variant(of: app, dark: dark)
      ?? NSWorkspace.shared.icon(forFile: app.path).cgImage(
        forProposedRect: &proposed, context: nil, hints: nil)
    guard let icon else { return nil }
    let image = NSImage(cgImage: trimmed(icon), size: points.size)
    cached[dark] = image
    return image
  }

  /// App icons leave a transparent margin around the shape; without it the icon is as large
  /// as the symbols it stands next to.
  private static func trimmed(_ image: CGImage) -> CGImage {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard
      let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width
    var maxX = -1
    var minY = height
    var maxY = -1
    for y in 0..<height {
      for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 127 {
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return image }
    let side = max(maxX - minX, maxY - minY) + 1
    let square = CGRect(
      x: (minX + maxX + 1 - side) / 2, y: (minY + maxY + 1 - side) / 2, width: side, height: side)
    return image.cropping(to: square) ?? image
  }

  private static func variant(of app: URL, dark: Bool) -> CGImage? {
    dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_LAZY)
    let create = NSSelectorFromString("initWithURL:")
    let prepare = NSSelectorFromString("prepareImagesForDescriptors:")
    let render = NSSelectorFromString("CGImageForDescriptor:")
    guard let iconClass = NSClassFromString("ISIcon") as? NSObject.Type,
      let descriptorClass = NSClassFromString("ISImageDescriptor") as? NSObject.Type,
      iconClass.instancesRespond(to: prepare), iconClass.instancesRespond(to: render),
      descriptorClass.instancesRespond(to: NSSelectorFromString("setSize:")),
      descriptorClass.instancesRespond(to: NSSelectorFromString("setScale:")),
      descriptorClass.instancesRespond(to: NSSelectorFromString("setAppearance:")),
      let allocated = iconClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
      allocated.responds(to: create),
      let icon = allocated.perform(create, with: app as NSURL)?.takeUnretainedValue()
    else { return nil }
    let points = NSSize(width: 64, height: 64)
    let descriptor = descriptorClass.init()
    descriptor.setValue(NSValue(size: points), forKey: "size")
    descriptor.setValue(2.0, forKey: "scale")
    descriptor.setValue(dark ? 1 : 0, forKey: "appearance")
    _ = icon.perform(prepare, with: [descriptor])
    guard let rendered = icon.perform(render, with: descriptor)?.takeUnretainedValue(),
      CFGetTypeID(rendered) == CGImage.typeID
    else { return nil }
    return unsafeDowncast(rendered, to: CGImage.self)
  }
}

/// Marks something as belonging to Teams. Decorative: the text next to it names Teams.
struct TeamsMark<Fallback: View>: View {
  let size: CGFloat
  @ViewBuilder var fallback: Fallback
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if let image = TeamsIcon.image(dark: colorScheme == .dark) {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    } else {
      fallback
    }
  }
}

extension TeamsMark where Fallback == EmptyView {
  init(size: CGFloat) {
    self.init(size: size) { EmptyView() }
  }
}
