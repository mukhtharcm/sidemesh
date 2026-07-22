import Flutter
import UIKit
import UserNotifications

final class SidemeshPushBridge {
  static let shared = SidemeshPushBridge()

  private let channelName = "dev.sidemesh.mobile/apns"
  private var channel: FlutterMethodChannel?
  private var deviceToken: String?
  private var pendingNotification: [String: Any]?

  private init() {}

  func attach(to messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let nextChannel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    nextChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: "APNs bridge unavailable", details: nil))
        return
      }
      switch call.method {
      case "initialize":
        UIApplication.shared.registerForRemoteNotifications()
        result(self.registrationPayload())
        if let notification = self.pendingNotification {
          self.pendingNotification = nil
          DispatchQueue.main.async {
            nextChannel.invokeMethod("notificationTapped", arguments: notification)
          }
        }
      case "currentRegistration":
        result(self.registrationPayload())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = nextChannel
  }

  func didRegister(deviceToken data: Data) {
    deviceToken = data.map { String(format: "%02x", $0) }.joined()
    channel?.invokeMethod("tokenChanged", arguments: registrationPayload())
  }

  func didFailToRegister(error: Error) {
    channel?.invokeMethod("registrationFailed", arguments: error.localizedDescription)
  }

  func handleNotificationResponse(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard let payload = sidemeshPayload(userInfo) else { return false }
    if let channel {
      channel.invokeMethod("notificationTapped", arguments: payload)
    } else {
      pendingNotification = payload
    }
    return true
  }

  func isSidemeshNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    sidemeshPayload(userInfo) != nil
  }

  private func registrationPayload() -> [String: Any] {
    var payload: [String: Any] = [
      "bundleId": Bundle.main.bundleIdentifier ?? "",
      "environment": apnsEnvironment(),
    ]
    if let deviceToken {
      payload["deviceToken"] = deviceToken
    }
    return payload
  }

  private func apnsEnvironment() -> String {
    #if DEBUG
      return "development"
    #else
      return "production"
    #endif
  }

  private func sidemeshPayload(_ userInfo: [AnyHashable: Any]) -> [String: Any]? {
    if let payload = userInfo["sidemesh"] as? [String: Any] {
      return payload
    }
    if let payload = userInfo["sidemesh"] as? [AnyHashable: Any] {
      return Dictionary(uniqueKeysWithValues: payload.compactMap { key, value in
        guard let key = key as? String else { return nil }
        return (key, value)
      })
    }
    return nil
  }
}
