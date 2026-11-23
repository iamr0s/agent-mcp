import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.title = "Agent MCP Console"
    self.minSize = NSSize(width: 420, height: 560)
    if let screenFrame = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
      let targetW = min(CGFloat(1280), screenFrame.width * 0.90)
      let targetH = min(CGFloat(820), screenFrame.height * 0.88)
      let originX = screenFrame.origin.x + (screenFrame.width - targetW) * 0.5
      let originY = screenFrame.origin.y + (screenFrame.height - targetH) * 0.5
      self.setFrame(NSRect(x: originX, y: originY, width: targetW, height: targetH), display: true)
    } else {
      let windowFrame = self.frame
      self.setFrame(windowFrame, display: true)
    }

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
