import XCTest
@testable import MagicQuit

final class IdleSessionTests: XCTestCase {
    func testLockAndSleepOverlapWithSessionSwitch() {
        var suspension = IdleSuspension()
        suspension.set(.locked, active: true)
        XCTAssertTrue(suspension.perAppPaused)
        XCTAssertFalse(suspension.wholeMacPaused)
        suspension.set(.sleep, active: true)
        suspension.set(.inactiveSession, active: true)
        suspension.set(.sleep, active: false)
        XCTAssertTrue(suspension.wholeMacPaused)
        suspension.set(.inactiveSession, active: false)
        XCTAssertFalse(suspension.wholeMacPaused)
        XCTAssertTrue(suspension.perAppPaused)
        suspension.set(.locked, active: false)
        XCTAssertFalse(suspension.perAppPaused)
    }

    func testWholeMacActionRunsOnceAcrossSleepAndReopensOnInput() {
        var session = WholeMacIdleSession()
        session.reset(at: 100, hidIdle: 5)
        XCTAssertEqual(session.sample(at: 200, hidIdle: 105), 100)
        XCTAssertTrue(session.claim("test.app"))
        XCTAssertFalse(session.claim("test.app"))
        XCTAssertTrue(session.claim("test.other"))
        session.pause()
        XCTAssertEqual(session.sample(at: 700, hidIdle: 605), 100)
        XCTAssertEqual(session.sample(at: 701, hidIdle: 606), 101)
        XCTAssertFalse(session.claim("test.app"))
        XCTAssertNil(session.sample(at: 702, hidIdle: nil))
        XCTAssertFalse(session.claim("test.app"))
        XCTAssertEqual(session.sample(at: 703, hidIdle: 0.5), 0.5)
        XCTAssertTrue(session.claim("test.app"))
    }

    func testUnlockResetUsesNewBaselineEvenWithoutHIDInput() {
        var session = WholeMacIdleSession()
        session.reset(at: 100, hidIdle: 10)
        XCTAssertEqual(session.sample(at: 200, hidIdle: 110), 100)
        XCTAssertTrue(session.claim("test.app"))
        session.reset(at: 201, hidIdle: 111)
        XCTAssertEqual(session.sample(at: 202, hidIdle: 112), 1)
        XCTAssertFalse(session.hasHandled("test.app"))
    }

    func testInputWhileSuspendedStartsNewWholeMacCountdownOnFirstValidSample() {
        var session = WholeMacIdleSession()
        session.reset(at: 0, hidIdle: 0)
        XCTAssertEqual(session.sample(at: 10_800, hidIdle: 10_800), 10_800)
        XCTAssertTrue(session.claim("test.app"))
        session.pause()
        session.pause()
        XCTAssertNil(session.sample(at: 10_809, hidIdle: nil))
        XCTAssertEqual(session.sample(at: 10_810, hidIdle: 0.2), 0.2)
        XCTAssertFalse(session.hasHandled("test.app"))
        XCTAssertEqual(session.sample(at: 10_870, hidIdle: 60.2), 60.2)
    }

    @MainActor
    func testSwitchingBackToPerAppStartsFreshCountdown() throws {
        let suiteName = "MagicQuitTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.idleMinutes = 180
        let manager = RunningAppsManager(settings: settings, startMonitoring: false)
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let entry = RunningAppsManager.TrackedApp(app: .current, lastActive: now.addingTimeInterval(-14_400))
        XCTAssertLessThan(manager.remaining(for: entry, now: now), 0)
        settings.idleMode = .wholeMac
        manager.updateIdleMode(at: now.addingTimeInterval(-3_600))
        settings.idleMode = .perApp
        manager.updateIdleMode(at: now)
        XCTAssertEqual(manager.remaining(for: entry, now: now), 10_800)
        manager.updateIdleMode(at: now.addingTimeInterval(60))
        XCTAssertEqual(manager.remaining(for: entry, now: now.addingTimeInterval(60)), 10_740)
    }

    func testBackgroundRelaunchAndSelfActivationDoNotRearmPerAppTimer() {
        var gate = AppUseGate()
        XCTAssertFalse(gate.observe(isFrontmost: false, at: 100, inputAge: 10))
        XCTAssertFalse(gate.observe(isFrontmost: true, at: 101, inputAge: 0))
        XCTAssertFalse(gate.observe(isFrontmost: true, at: 102, inputAge: 1))
        XCTAssertFalse(gate.observe(isFrontmost: false, at: 103, inputAge: 2))
        XCTAssertFalse(gate.observe(isFrontmost: true, at: 200, inputAge: 0))
        XCTAssertFalse(gate.observe(isFrontmost: true, at: 201, inputAge: nil))
        XCTAssertTrue(gate.observe(isFrontmost: true, at: 202, inputAge: 0.5))
    }

    @MainActor
    func testHostDetectsXCTest() {
        XCTAssertTrue(MagicQuitApp.isRunningTests)
    }
}

@MainActor
final class AppTerminationTests: XCTestCase {
    func testRestartsOnlyAfterOriginalInstanceExit() async {
        var clock = 0.0
        var exited = false
        var events: [String] = []
        await AppTermination.perform(
            request: { events.append("terminate original"); return true },
            hasExited: { exited },
            now: { clock },
            wait: {
                clock += 1
                if clock == 2 {
                    events.append("original exited")
                    exited = true
                }
            },
            restartIfAllowed: { events.append("relaunch") }
        )
        XCTAssertEqual(events, ["terminate original", "original exited", "relaunch"])
    }

    func testTimeoutNeverRelaunchesAfterSavePromptOrCancellation() async {
        var clock = 0.0
        var requests = 0
        await AppTermination.perform(
            request: { requests += 1; return true },
            hasExited: { clock >= 3 },
            now: { clock },
            wait: { clock += 1 },
            timeout: 3,
            restartIfAllowed: { XCTFail("Timed-out termination must never relaunch") }
        )
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(clock, 3)
    }

    func testAlreadyExitedAndRejectedRequestsDoNotRelaunch() async {
        await AppTermination.perform(
            request: { XCTFail("Original instance already exited"); return true },
            hasExited: { true }, now: { 0 }, wait: { XCTFail("Unexpected wait") },
            restartIfAllowed: { XCTFail("Unexpected relaunch") }
        )
        await AppTermination.perform(
            request: { false },
            hasExited: { false }, now: { 0 }, wait: { XCTFail("Unexpected wait") },
            restartIfAllowed: { XCTFail("Unexpected relaunch") }
        )
    }
}
