import XCTest
@testable import MagicQuit

final class IdleDurationTests: XCTestCase {
    func testStepsAreAscendingAndBounded() {
        XCTAssertEqual(IdleDuration.stepsInMinutes.first, 15)
        XCTAssertEqual(IdleDuration.stepsInMinutes.last, 2880)
        XCTAssertEqual(IdleDuration.stepsInMinutes, IdleDuration.stepsInMinutes.sorted())
        XCTAssertTrue(IdleDuration.stepsInMinutes.contains(IdleDuration.defaultMinutes))
    }

    func testStepAtLeast() {
        XCTAssertEqual(IdleDuration.stepAtLeast(minutes: 0), 15)
        // Migration must never shorten a configured duration
        XCTAssertEqual(IdleDuration.stepAtLeast(minutes: 90), 120)
        XCTAssertEqual(IdleDuration.stepAtLeast(minutes: 3 * 60), 180)
        XCTAssertEqual(IdleDuration.stepAtLeast(minutes: 500), 720)
        // ...except beyond the largest step, which clamps
        XCTAssertEqual(IdleDuration.stepAtLeast(minutes: 72 * 60), 2880)
        // Exact steps map to themselves; 8h was the 1.x default
        XCTAssertEqual(IdleDuration.stepAtLeast(minutes: 8 * 60), 480)
        XCTAssertEqual(IdleDuration.stepAtLeast(minutes: 15), 15)
    }

    func testStepUpAndDown() {
        XCTAssertEqual(IdleDuration.stepUp(from: 15), 30)
        XCTAssertEqual(IdleDuration.stepDown(from: 30), 15)
        XCTAssertEqual(IdleDuration.stepDown(from: 15), 15)
        XCTAssertEqual(IdleDuration.stepUp(from: 2880), 2880)
        XCTAssertEqual(IdleDuration.stepUp(from: 100), 120)
        XCTAssertEqual(IdleDuration.stepDown(from: 100), 60)
    }

    private var usesSimplifiedChinese: Bool {
        Bundle.main.preferredLocalizations.first == "zh-Hans"
    }

    func testLabels() {
        XCTAssertEqual(IdleDuration.label(minutes: 15), usesSimplifiedChinese ? "15 分钟" : "15 min")
        XCTAssertEqual(IdleDuration.label(minutes: 30), usesSimplifiedChinese ? "30 分钟" : "30 min")
        XCTAssertEqual(IdleDuration.label(minutes: 60), usesSimplifiedChinese ? "1 小时" : "1 h")
        XCTAssertEqual(IdleDuration.label(minutes: 2880), usesSimplifiedChinese ? "48 小时" : "48 h")
    }

    func testShortRemaining() {
        XCTAssertEqual(IdleDuration.shortRemaining(seconds: 7200), usesSimplifiedChinese ? "2 小时" : "2 h")
        XCTAssertEqual(IdleDuration.shortRemaining(seconds: 3599), usesSimplifiedChinese ? "59 分钟" : "59 min")
        XCTAssertEqual(IdleDuration.shortRemaining(seconds: 59), usesSimplifiedChinese ? "59 秒" : "59 s")
        XCTAssertEqual(IdleDuration.shortRemaining(seconds: -5), usesSimplifiedChinese ? "0 秒" : "0 s")
    }
}

final class QuitPolicyTests: XCTestCase {
    func testTrackableRegularApp() {
        XCTAssertTrue(QuitPolicy.isTrackable(bundleId: "com.apple.Safari", activationPolicy: .regular, ownBundleId: "com.MagicQuit"))
    }

    func testAccessoryAppsAreNotTracked() {
        XCTAssertFalse(QuitPolicy.isTrackable(bundleId: "com.apple.Safari", activationPolicy: .accessory, ownBundleId: "com.MagicQuit"))
        XCTAssertFalse(QuitPolicy.isTrackable(bundleId: "com.apple.Safari", activationPolicy: .prohibited, ownBundleId: "com.MagicQuit"))
    }

    func testOwnAppIsNotTracked() {
        XCTAssertFalse(QuitPolicy.isTrackable(bundleId: "com.MagicQuit", activationPolicy: .regular, ownBundleId: "com.MagicQuit"))
    }

    func testSystemAppsAreNotTracked() {
        for id in QuitPolicy.systemExcluded {
            XCTAssertFalse(QuitPolicy.isTrackable(bundleId: id, activationPolicy: .regular, ownBundleId: "com.MagicQuit"))
        }
    }

    func testNilBundleIdRegularAppIsTracked() {
        XCTAssertTrue(QuitPolicy.isTrackable(bundleId: nil, activationPolicy: .regular, ownBundleId: "com.MagicQuit"))
    }

    func testRemainingAndDue() {
        let now = Date()
        let lastActive = now.addingTimeInterval(-3600)
        XCTAssertEqual(QuitPolicy.remainingSeconds(lastActive: lastActive, now: now, idleMinutes: 120), 3600)
        XCTAssertFalse(QuitPolicy.idleQuitDue(lastActive: lastActive, now: now, idleMinutes: 120))
        XCTAssertTrue(QuitPolicy.idleQuitDue(lastActive: lastActive, now: now, idleMinutes: 60))
        XCTAssertTrue(QuitPolicy.idleQuitDue(lastActive: lastActive, now: now, idleMinutes: 30))
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "MagicQuitTests.AppSettings"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.idleMinutes, IdleDuration.defaultMinutes)
        XCTAssertEqual(settings.idleMode, .perApp)
        XCTAssertFalse(settings.showQuitButton)
        XCTAssertFalse(settings.quitOnLastWindowClosed)
        XCTAssertTrue(settings.idleQuitExcluded.isEmpty)
        XCTAssertEqual(settings.windowQuitExcluded, AppSettings.defaultWindowQuitExcluded)
    }

    func testLegacyHoursMigration() {
        defaults.set(8, forKey: "hoursUntilClose")
        XCTAssertEqual(AppSettings(defaults: defaults).idleMinutes, 480)

        // Preserve the exact legacy 3-hour setting.
        defaults.set(3, forKey: "hoursUntilClose")
        defaults.removeObject(forKey: "idleMinutes")
        XCTAssertEqual(AppSettings(defaults: defaults).idleMinutes, 180)

        defaults.set(72, forKey: "hoursUntilClose")
        defaults.removeObject(forKey: "idleMinutes")
        XCTAssertEqual(AppSettings(defaults: defaults).idleMinutes, 2880)
    }

    func testExistingIdleMinutesWinsOverLegacyHours() {
        defaults.set(60, forKey: "idleMinutes")
        defaults.set(8, forKey: "hoursUntilClose")
        XCTAssertEqual(AppSettings(defaults: defaults).idleMinutes, 60)
    }

    func testLegacyToggleMigration() throws {
        let legacy = ["Safari": false, "Mail": true]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "com.MagicQuit.toggleStatus")

        let settings = AppSettings(defaults: defaults)
        settings.migrateLegacyToggleIfNeeded(appName: "Safari", bundleId: "com.apple.Safari")
        XCTAssertTrue(settings.idleQuitExcluded.contains("com.apple.Safari"))

        // Enabled legacy entries do not create exclusions
        settings.migrateLegacyToggleIfNeeded(appName: "Mail", bundleId: "com.apple.mail")
        XCTAssertFalse(settings.idleQuitExcluded.contains("com.apple.mail"))

        // Fully consumed legacy storage is removed
        XCTAssertNil(defaults.data(forKey: "com.MagicQuit.toggleStatus"))

        // Consuming again is a no-op
        settings.setIdleAction(.quit, for: "com.apple.Safari")
        settings.migrateLegacyToggleIfNeeded(appName: "Safari", bundleId: "com.apple.Safari")
        XCTAssertFalse(settings.idleQuitExcluded.contains("com.apple.Safari"))
    }

    func testExclusionPersistenceRoundtrip() {
        let settings = AppSettings(defaults: defaults)
        settings.setIdleAction(.off, for: "com.apple.Safari")
        settings.windowQuitExcluded.insert("com.example.tool")
        settings.idleMinutes = 120
        settings.quitOnLastWindowClosed = true

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.idleQuitExcluded.contains("com.apple.Safari"))
        XCTAssertTrue(reloaded.windowQuitExcluded.contains("com.example.tool"))
        XCTAssertEqual(reloaded.idleMinutes, 120)
        XCTAssertTrue(reloaded.quitOnLastWindowClosed)
    }

    func testModeAndIdleActionsPersistAndStayMutuallyExclusive() {
        let key = "test.fixture"
        let settings = AppSettings(defaults: defaults)
        settings.idleMode = .wholeMac
        settings.setIdleAction(.off, for: key)
        settings.setIdleAction(.restart, for: key)
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.idleMode, .wholeMac)
        XCTAssertEqual(reloaded.idleAction(for: key), .restart)
        XCTAssertFalse(reloaded.idleQuitExcluded.contains(key))

        reloaded.setIdleAction(.off, for: key)
        XCTAssertFalse(reloaded.idleRestartApps.contains(key))
        XCTAssertEqual(AppSettings(defaults: defaults).idleAction(for: key), .off)
        reloaded.setIdleAction(.quit, for: key)
        XCTAssertEqual(AppSettings(defaults: defaults).idleAction(for: key), .quit)
    }

    func testConflictingStoredActionsPreferOff() {
        let key = "test.fixture"
        defaults.set([key], forKey: "idleQuitExcludedApps")
        defaults.set([key], forKey: "idleRestartApps")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.idleAction(for: key), .off)
        XCTAssertEqual(defaults.stringArray(forKey: "idleRestartApps"), [])
    }

    func testEmptiedWindowExclusionsStayEmpty() {
        let settings = AppSettings(defaults: defaults)
        for id in AppSettings.defaultWindowQuitExcluded {
            settings.windowQuitExcluded.remove(id)
        }
        XCTAssertTrue(AppSettings(defaults: defaults).windowQuitExcluded.isEmpty)
    }
}
