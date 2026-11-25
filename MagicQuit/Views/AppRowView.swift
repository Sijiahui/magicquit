import SwiftUI
import AppKit

struct AppRowView: View {
    @EnvironmentObject private var manager: RunningAppsManager
    @EnvironmentObject private var settings: AppSettings

    let entry: RunningAppsManager.TrackedApp
    let now: Date

    private var action: Binding<IdleAction> {
        Binding(
            get: { manager.idleAction(for: entry.app) },
            set: { manager.setIdleAction($0, for: entry.app) }
        )
    }

    var body: some View {
        let appName = entry.app.localizedName ?? String(localized: "Unknown")
        let enabled = action.wrappedValue != .off
        let perApp = settings.idleMode == .perApp
        let waiting = manager.waitingForUse[entry.id] != nil
        let remaining = manager.remaining(for: entry, now: now)
        let closingSoon = perApp && enabled && !waiting && !manager.idlePaused &&
            remaining < min(3600, settings.idleMinutes * 15)

        HStack(spacing: 8) {
            Image(nsImage: AppIconCache.icon(for: entry.app))
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)

            Text(appName)
                .lineLimit(1)
                .truncationMode(.tail)
                .fontWeight(closingSoon ? .semibold : .regular)
                .foregroundStyle(enabled ? Color.primary : Color.secondary)

            Spacer(minLength: 8)

            if perApp && enabled {
                Text(waiting ? String(localized: "Waiting for use") : IdleDuration.shortRemaining(seconds: remaining))
                    .monospacedDigit()
                    .font(.caption)
                    .fontWeight(closingSoon ? .semibold : .regular)
                    .foregroundStyle(closingSoon ? Color.primary : Color.secondary)

                Button {
                    manager.resetTimer(for: entry.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.plain)
                .help("Reset idle timer")
                .accessibilityLabel("Reset idle timer")
            }

            Picker("Idle action for \(appName)", selection: action) {
                ForEach(manager.availableActions(for: entry.app), id: \.self) { action in
                    Text(LocalizedStringKey(action.rawValue)).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 78)
            .disabled(manager.availableActions(for: entry.app).count == 1)

            if settings.showQuitButton {
                Button {
                    manager.quit(entry.app)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Quit app")
                .accessibilityLabel("Quit app")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

}

/// Icon lookups are not cheap; the menu re-renders every second while open.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for app: NSRunningApplication) -> NSImage {
        let path = app.bundleURL?.path ?? app.executableURL?.path ?? ""
        if let cached = cache[path] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}
