import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()

    // Default launch size — tuned for a laptop display; user can resize.
    let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let width: CGFloat = min(1180, screenFrame.width - 120)
    let height: CGFloat = min(760, screenFrame.height - 120)
    let originX = screenFrame.midX - width / 2
    let originY = screenFrame.midY - height / 2
    let windowFrame = NSRect(x: originX, y: originY, width: width, height: height)

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 760, height: 520)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
