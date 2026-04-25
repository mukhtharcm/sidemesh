import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SidemeshLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    if #available(iOSApplicationExtension 16.1, *) {
      SidemeshPrimaryLiveActivity()
    }
  }
}

@available(iOSApplicationExtension 16.1, *)
struct SidemeshPrimaryLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: SidemeshLiveActivityAttributes.self) { context in
      SidemeshLockScreenView(state: context.state)
        .padding(16)
        .background(SidemeshPalette.canvas)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          SidemeshIslandBadge(state: context.state)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 3) {
            Text(context.state.headline)
              .font(.headline)
              .lineLimit(1)
            Text(context.state.host)
              .font(.caption)
              .foregroundColor(SidemeshPalette.muted)
              .lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.detail)
            .font(.caption)
            .foregroundColor(SidemeshPalette.muted)
            .lineLimit(2)
        }
      } compactLeading: {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .foregroundColor(SidemeshPalette.accent)
      } compactTrailing: {
        Text(context.state.badge)
          .font(.caption.bold())
          .foregroundColor(SidemeshPalette.accent)
      } minimal: {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .foregroundColor(SidemeshPalette.accent)
      }
    }
  }
}

@available(iOSApplicationExtension 16.1, *)
private struct SidemeshLockScreenView: View {
  let state: SidemeshLiveActivityAttributes.ContentState

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      SidemeshBadge(text: state.badge)

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(state.status.uppercased())
            .font(.caption2.bold())
            .tracking(0.8)
            .foregroundColor(SidemeshPalette.accent)
          Text(state.host)
            .font(.caption)
            .foregroundColor(SidemeshPalette.muted)
            .lineLimit(1)
        }

        Text(state.headline)
          .font(.headline)
          .foregroundColor(.white)
          .lineLimit(1)

        Text(state.detail)
          .font(.subheadline)
          .foregroundColor(SidemeshPalette.muted)
          .lineLimit(2)

        if !state.footnote.isEmpty {
          Text(state.footnote)
            .font(.caption2)
            .foregroundColor(SidemeshPalette.faint)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 0)
    }
  }
}

@available(iOSApplicationExtension 16.1, *)
private struct SidemeshIslandBadge: View {
  let state: SidemeshLiveActivityAttributes.ContentState

  var body: some View {
    VStack(spacing: 5) {
      SidemeshBadge(text: state.badge)
      Text(state.status.uppercased())
        .font(.caption2.bold())
        .foregroundColor(SidemeshPalette.accent)
        .lineLimit(1)
    }
  }
}

@available(iOSApplicationExtension 16.1, *)
private struct SidemeshBadge: View {
  let text: String

  var body: some View {
    ZStack {
      Circle()
        .fill(SidemeshPalette.accent.opacity(0.18))
      Circle()
        .stroke(SidemeshPalette.accent, lineWidth: 1.5)
      Text(text)
        .font(.system(size: text.count > 2 ? 12 : 17, weight: .bold))
        .foregroundColor(SidemeshPalette.accent)
    }
    .frame(width: 44, height: 44)
  }
}

private enum SidemeshPalette {
  static let canvas = Color(red: 0.08, green: 0.08, blue: 0.07)
  static let accent = Color(red: 0.98, green: 0.67, blue: 0.28)
  static let muted = Color.white.opacity(0.72)
  static let faint = Color.white.opacity(0.48)
}
