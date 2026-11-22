import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Enable native macOS Vibrancy (frosted glass) behind Flutter surface
    self.isOpaque = false
    self.backgroundColor = .clear
    flutterViewController.backgroundColor = .clear
    if let contentView = self.contentView {
      let visualEffect = NSVisualEffectView(frame: contentView.bounds)
      visualEffect.autoresizingMask = [.width, .height]
      visualEffect.blendingMode = .behindWindow
      visualEffect.material = .sidebar
      visualEffect.state = .active
      contentView.addSubview(visualEffect, positioned: .below, relativeTo: nil)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
