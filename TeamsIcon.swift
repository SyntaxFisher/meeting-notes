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
    let image = variant(of: app, dark: dark) ?? NSWorkspace.shared.icon(forFile: app.path)
    cached[dark] = image
    return image
  }

  private static func variant(of app: URL, dark: Bool) -> NSImage? {
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
    return NSImage(cgImage: unsafeDowncast(rendered, to: CGImage.self), size: points)
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
