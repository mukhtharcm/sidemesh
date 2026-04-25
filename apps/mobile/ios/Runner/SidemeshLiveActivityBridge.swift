import ActivityKit
import Flutter
import Foundation
import UIKit

final class SidemeshLiveActivityBridge {
  static let shared = SidemeshLiveActivityBridge()

  private let defaultActivityId = "sidemesh.pendingApprovals"
  private var channel: FlutterMethodChannel?

  private init() {}

  func attach(to messenger: FlutterBinaryMessenger) {
    if channel != nil {
      return
    }
    let channel = FlutterMethodChannel(
      name: "dev.sidemesh/live_activity",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler(handle)
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(isSupported)
    case "createOrUpdate":
      guard #available(iOS 16.1, *) else {
        result(false)
        return
      }
      guard let args = call.arguments as? [String: Any] else {
        result(
          FlutterError(
            code: "BAD_ARGS",
            message: "Expected live activity arguments",
            details: nil
          )
        )
        return
      }
      createOrUpdate(args: args, result: result)
    case "end":
      guard #available(iOS 16.1, *) else {
        result(false)
        return
      }
      let args = call.arguments as? [String: Any]
      let activityId = args?["activityId"] as? String ?? defaultActivityId
      end(activityId: activityId, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private var isSupported: Bool {
    guard #available(iOS 16.1, *) else {
      return false
    }
    return ActivityAuthorizationInfo().areActivitiesEnabled
  }

  @available(iOS 16.1, *)
  private func createOrUpdate(args: [String: Any], result: @escaping FlutterResult) {
    if !ActivityAuthorizationInfo().areActivitiesEnabled {
      result(false)
      return
    }

    let activityId = args["activityId"] as? String ?? defaultActivityId
    let state = makeState(args: args)

    Task {
      if let activity = Self.findActivity(activityId: activityId) {
        await activity.update(using: state)
        result(true)
        return
      }

      guard await MainActor.run(body: { UIApplication.shared.applicationState == .active }) else {
        result(false)
        return
      }

      do {
        let attributes = SidemeshLiveActivityAttributes(id: activityId)
        _ = try Activity.request(
          attributes: attributes,
          contentState: state,
          pushType: nil
        )
        result(true)
      } catch {
        result(
          FlutterError(
            code: "LIVE_ACTIVITY_ERROR",
            message: "Could not start Sidemesh Live Activity",
            details: error.localizedDescription
          )
        )
      }
    }
  }

  @available(iOS 16.1, *)
  private func end(activityId: String, result: @escaping FlutterResult) {
    Task {
      guard let activity = Self.findActivity(activityId: activityId) else {
        result(true)
        return
      }
      await activity.end(dismissalPolicy: .immediate)
      result(true)
    }
  }

  @available(iOS 16.1, *)
  private func makeState(args: [String: Any]) -> SidemeshLiveActivityAttributes.ContentState {
    let updatedAtMillis = args["updatedAtMillis"] as? Double
    let updatedAt = updatedAtMillis.map {
      Date(timeIntervalSince1970: $0 / 1000)
    } ?? Date()

    return SidemeshLiveActivityAttributes.ContentState(
      headline: args["headline"] as? String ?? "Sidemesh",
      detail: args["detail"] as? String ?? "",
      footnote: args["footnote"] as? String ?? "",
      status: args["status"] as? String ?? "active",
      host: args["host"] as? String ?? "",
      count: args["count"] as? Int ?? 1,
      updatedAt: updatedAt
    )
  }

  @available(iOS 16.1, *)
  private static func findActivity(
    activityId: String
  ) -> Activity<SidemeshLiveActivityAttributes>? {
    Activity<SidemeshLiveActivityAttributes>.activities.first {
      $0.attributes.id == activityId
    }
  }
}
