import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  private var updaterController: SPUStandardUpdaterController?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    configureUpdater()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func configureUpdater() {
    guard hasSparkleConfiguration else {
      return
    }

    let controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    updaterController = controller
    installCheckForUpdatesMenuItem(controller: controller)
  }

  private var hasSparkleConfiguration: Bool {
    guard
      let info = Bundle.main.infoDictionary,
      let feedURL = info["SUFeedURL"] as? String,
      let publicKey = info["SUPublicEDKey"] as? String
    else {
      return false
    }

    let trimmedFeedURL = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPublicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(string: trimmedFeedURL) != nil &&
      !trimmedFeedURL.isEmpty &&
      !trimmedFeedURL.contains("$(") &&
      !trimmedPublicKey.isEmpty &&
      !trimmedPublicKey.contains("$(")
  }

  private func installCheckForUpdatesMenuItem(controller: SPUStandardUpdaterController) {
    guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
      return
    }

    let action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
    if appMenu.items.contains(where: { $0.action == action }) {
      return
    }

    let item = NSMenuItem(title: "Check for Updates...", action: action, keyEquivalent: "")
    item.target = controller
    let insertIndex = appMenu.items.firstIndex {
      $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
    }.map { $0 + 1 } ?? 1
    appMenu.insertItem(item, at: insertIndex)
  }
}
