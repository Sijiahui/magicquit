import AppKit
import Combine

enum IdleMode: String, CaseIterable {
    case perApp
    case wholeMac

    var title: String {
        switch self {
        case .perApp: String(localized: "Per App")
        case .wholeMac: String(localized: "Whole Mac")
        }
    }
}

enum IdleAction: String, CaseIterable {
    case off = "Off"
    case quit = "Quit"
    case restart = "Restart"
}

/// Single source of truth for user settings, persisted to UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let idleMode = "idleMode"
        static let idleRestart = "idleRestartApps"
        static let idleMinutes = "idleMinutes"
        static let showQuitButton = "showCloseButton" // key kept from 1.x
        static let quitOnLastWindowClosed = "quitOnLastWindowClosed"
        static let idleQuitExcluded = "idleQuitExcludedApps"
        static let windowQuitExcluded = "windowQuitExcludedApps"
        static let legacyHours = "hoursUntilClose"
        static let legacyToggles = "com.MagicQuit.toggleStatus"
    }

    static let defaultWindowQuitExcluded: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
        "com.apple.podcasts",
        "org.videolan.vlc",
    ]

    private let defaults: UserDefaults

    @Published var idleMode: IdleMode {
        didSet { defaults.set(idleMode.rawValue, forKey: Keys.idleMode) }
    }

    @Published var idleMinutes: Int {
        didSet { defaults.set(idleMinutes, forKey: Keys.idleMinutes) }
    }

    @Published var showQuitButton: Bool {
        didSet { defaults.set(showQuitButton, forKey: Keys.showQuitButton) }
    }

    @Published var quitOnLastWindowClosed: Bool {
        didSet { defaults.set(quitOnLastWindowClosed, forKey: Keys.quitOnLastWindowClosed) }
    }

    /// Bundle identifiers excluded from idle quitting (menu action picker).
    @Published private(set) var idleQuitExcluded: Set<String> {
        didSet { defaults.set(Array(idleQuitExcluded).sorted(), forKey: Keys.idleQuitExcluded) }
    }

    @Published private(set) var idleRestartApps: Set<String> {
        didSet { defaults.set(Array(idleRestartApps).sorted(), forKey: Keys.idleRestart) }
    }

    func idleAction(for key: String) -> IdleAction {
        if idleQuitExcluded.contains(key) { return .off }
        return idleRestartApps.contains(key) ? .restart : .quit
    }

    func setIdleAction(_ action: IdleAction, for key: String) {
        guard idleAction(for: key) != action else { return }
        switch action {
        case .off:
            if idleRestartApps.contains(key) { idleRestartApps.remove(key) }
            idleQuitExcluded.insert(key)
        case .quit:
            if idleRestartApps.contains(key) { idleRestartApps.remove(key) }
            if idleQuitExcluded.contains(key) { idleQuitExcluded.remove(key) }
        case .restart:
            if idleQuitExcluded.contains(key) { idleQuitExcluded.remove(key) }
            idleRestartApps.insert(key)
        }
    }

    /// Bundle identifiers excluded from quit-on-last-window-closed.
    @Published var windowQuitExcluded: Set<String> {
        didSet { defaults.set(Array(windowQuitExcluded).sorted(), forKey: Keys.windowQuitExcluded) }
    }

    /// 1.x stored per-app enablement keyed by localized app name; consumed lazily as apps appear.
    private var legacyTogglesByName: [String: Bool]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let minutes = defaults.object(forKey: Keys.idleMinutes) as? Int {
            idleMinutes = minutes
        } else if let hours = defaults.object(forKey: Keys.legacyHours) as? Int {
            idleMinutes = IdleDuration.stepAtLeast(minutes: hours * 60)
        } else {
            idleMinutes = IdleDuration.defaultMinutes
        }

        idleMode = defaults.string(forKey: Keys.idleMode).flatMap(IdleMode.init(rawValue:)) ?? .perApp
        showQuitButton = defaults.bool(forKey: Keys.showQuitButton)
        quitOnLastWindowClosed = defaults.bool(forKey: Keys.quitOnLastWindowClosed)
        let excluded = Set(defaults.stringArray(forKey: Keys.idleQuitExcluded) ?? [])
        idleQuitExcluded = excluded

        let storedRestart = Set(defaults.stringArray(forKey: Keys.idleRestart) ?? [])
        let restart = storedRestart.subtracting(excluded)
        idleRestartApps = restart
        if storedRestart != restart {
            defaults.set(Array(restart).sorted(), forKey: Keys.idleRestart)
        }

        if let stored = defaults.stringArray(forKey: Keys.windowQuitExcluded) {
            windowQuitExcluded = Set(stored)
        } else {
            windowQuitExcluded = AppSettings.defaultWindowQuitExcluded
        }

        if let data = defaults.data(forKey: Keys.legacyToggles),
           let toggles = try? JSONDecoder().decode([String: Bool].self, from: data) {
            legacyTogglesByName = toggles
        } else {
            legacyTogglesByName = [:]
        }
    }

    /// Consume the 1.x per-app toggle for an app once its bundle identifier is known.
    func migrateLegacyToggleIfNeeded(appName: String?, bundleId: String?) {
        guard let appName, let bundleId,
              let enabled = legacyTogglesByName.removeValue(forKey: appName) else { return }
        if !enabled && idleAction(for: bundleId) == .quit {
            setIdleAction(.off, for: bundleId)
        }
        persistLegacyToggles()
    }

    private func persistLegacyToggles() {
        if legacyTogglesByName.isEmpty {
            defaults.removeObject(forKey: Keys.legacyToggles)
        } else if let data = try? JSONEncoder().encode(legacyTogglesByName) {
            defaults.set(data, forKey: Keys.legacyToggles)
        }
    }
}
