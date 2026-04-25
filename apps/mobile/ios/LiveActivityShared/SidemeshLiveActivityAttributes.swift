import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct SidemeshLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var headline: String
    var detail: String
    var footnote: String
    var status: String
    var host: String
    var count: Int
    var badge: String
    var updatedAt: Date
  }

  var id: String
}
