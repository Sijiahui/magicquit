import SwiftUI
import AppKit

@main
struct MagicQuitApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var manager: RunningAppsManager

    init() {
        let testing = Self.isRunningTests
        let settings = AppSettings(defaults: testing ? Self.testDefaults : .standard)
        _settings = StateObject(wrappedValue: settings)
        _manager = StateObject(wrappedValue: RunningAppsManager(settings: settings, startMonitoring: !testing))
        if !testing { _ = UpdaterSupport.controller }
    }

    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }

    private static let testDefaults = UserDefaults(suiteName: "MagicQuitTests.Host.\(UUID().uuidString)")!

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(manager)
                .environmentObject(settings)
        } label: {
            let image: NSImage = {
                $0.size.height = 18
                $0.size.width = 18
                $0.isTemplate = true
                return $0
            }(NSImage(named: "MenuBarIcon")!)

            Image(nsImage: image)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(manager)
                .environmentObject(settings)
        }
        .windowResizability(.contentSize)
    }
}
