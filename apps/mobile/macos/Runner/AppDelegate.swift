import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  @IBOutlet private weak var applicationMenu: NSMenu?
  @IBOutlet private weak var mainFlutterWindow: NSWindow?

  private var updaterController: SPUStandardUpdaterController?
  private var updaterChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    configureUpdater()
    configureUpdaterChannel()
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
    DispatchQueue.main.async { [weak self] in
      self?.installCheckForUpdatesMenuItem(controller: controller)
    }
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
    guard let appMenu = applicationMenu else {
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

  private func configureUpdaterChannel(retryCount: Int = 0) {
    guard updaterChannel == nil else {
      return
    }

    guard
      let flutterViewController = mainFlutterWindow?.contentViewController as? FlutterViewController
    else {
      guard retryCount < 4 else {
        return
      }
      DispatchQueue.main.async { [weak self] in
        self?.configureUpdaterChannel(retryCount: retryCount + 1)
      }
      return
    }

    let registrar = flutterViewController.registrar(forPlugin: "SidemeshUpdater")
    let channel = FlutterMethodChannel(
      name: "dev.sidemesh/updater",
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleUpdaterMethodCall(call, result: result)
    }
    updaterChannel = channel
  }

  private func handleUpdaterMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getState":
      result(updaterStatePayload())

    case "setAutomaticallyChecksForUpdates":
      guard let updater = updaterController?.updater else {
        result(unsupportedUpdaterError())
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let enabled = arguments["enabled"] as? Bool
      else {
        result(invalidArgumentsError())
        return
      }
      updater.automaticallyChecksForUpdates = enabled
      result(updaterStatePayload())

    case "setUpdateCheckIntervalSeconds":
      guard let updater = updaterController?.updater else {
        result(unsupportedUpdaterError())
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let seconds = arguments["seconds"] as? NSNumber
      else {
        result(invalidArgumentsError())
        return
      }
      updater.updateCheckInterval = max(3600, seconds.doubleValue)
      result(updaterStatePayload())

    case "checkForUpdates":
      guard
        let updater = updaterController?.updater,
        let controller = updaterController
      else {
        result(unsupportedUpdaterError())
        return
      }
      guard updater.canCheckForUpdates else {
        result(
          FlutterError(
            code: "busy",
            message: "An update check is already in progress.",
            details: nil
          )
        )
        return
      }
      controller.checkForUpdates(nil)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func updaterStatePayload() -> [String: Any] {
    guard let updater = updaterController?.updater else {
      return [
        "supported": false,
        "automaticallyChecksForUpdates": false,
        "updateCheckIntervalSeconds": 86400,
        "canCheckForUpdates": false,
      ]
    }
    return [
      "supported": true,
      "automaticallyChecksForUpdates": updater.automaticallyChecksForUpdates,
      "updateCheckIntervalSeconds": Int(updater.updateCheckInterval.rounded()),
      "canCheckForUpdates": updater.canCheckForUpdates,
    ]
  }

  private func unsupportedUpdaterError() -> FlutterError {
    FlutterError(
      code: "unsupported",
      message: "In-app updates are not available in this build.",
      details: nil
    )
  }

  private func invalidArgumentsError() -> FlutterError {
    FlutterError(
      code: "invalid_arguments",
      message: "Missing or invalid updater arguments.",
      details: nil
    )
  }
}
