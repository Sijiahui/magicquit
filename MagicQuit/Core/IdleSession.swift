import CoreGraphics
import Foundation
import IOKit

enum HIDIdle {
    static func seconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        let seconds = value.doubleValue / 1_000_000_000
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }
}

struct IdleSuspension {
    enum Reason: Hashable {
        case sleep, locked, inactiveSession
    }

    private(set) var reasons: Set<Reason> = []
    var perAppPaused: Bool { !reasons.isEmpty }
    var wholeMacPaused: Bool { reasons.contains(.sleep) || reasons.contains(.inactiveSession) }

    mutating func set(_ reason: Reason, active: Bool) {
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}

/// Tracks elapsed awake idle time and which app keys have already acted during that idle session.
struct WholeMacIdleSession {
    private var lastSample: (time: TimeInterval, hidIdle: TimeInterval)?
    private var pausedHIDIdle: TimeInterval?
    private var elapsed: TimeInterval?
    private var handled: Set<String> = []

    mutating func reset(at time: TimeInterval, hidIdle: TimeInterval?) {
        elapsed = 0
        handled.removeAll()
        pausedHIDIdle = nil
        lastSample = hidIdle.map { (time, $0) }
    }

    mutating func pause() {
        if let lastSample { pausedHIDIdle = lastSample.hidIdle }
        lastSample = nil
    }

    mutating func sample(at time: TimeInterval, hidIdle: TimeInterval?) -> TimeInterval? {
        guard let hidIdle else { return nil }
        if let previous = lastSample {
            let delta = max(0, time - previous.time)
            // A later HID event starts a new session. Allow for timing skew between reads.
            if hidIdle + 0.1 < previous.hidIdle + delta {
                elapsed = hidIdle
                handled.removeAll()
            } else {
                elapsed = (elapsed ?? previous.hidIdle) + delta
            }
        } else {
            if let pausedHIDIdle, hidIdle + 0.1 < pausedHIDIdle {
                elapsed = hidIdle
                handled.removeAll()
            } else if elapsed == nil {
                elapsed = hidIdle
            }
            pausedHIDIdle = nil
        }
        lastSample = (time, hidIdle)
        return elapsed
    }

    func hasHandled(_ key: String) -> Bool { handled.contains(key) }

    mutating func claim(_ key: String) -> Bool {
        handled.insert(key).inserted
    }
}

/// An app's launch and activation can occur without user input.
struct AppUseGate: Equatable {
    private static let interactionEvents: [CGEventType] = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]
    private var foregroundSince: TimeInterval?

    static func interactionAge() -> TimeInterval? {
        interactionEvents
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .filter { $0.isFinite && $0 >= 0 }
            .min()
    }

    mutating func observe(isFrontmost: Bool, at time: TimeInterval, inputAge: TimeInterval?) -> Bool {
        guard isFrontmost else {
            foregroundSince = nil
            return false
        }
        if let foregroundSince {
            return inputAge.map { time - $0 > foregroundSince } ?? false
        }
        foregroundSince = time
        return false
    }
}

@MainActor
enum AppTermination {
    static func perform(
        request: () -> Bool,
        hasExited: () -> Bool,
        now: () -> TimeInterval,
        wait: () async -> Void,
        timeout: TimeInterval = 20,
        restartIfAllowed: (() -> Void)?
    ) async {
        // Never launch if this instance had already exited before the request.
        guard !hasExited(), request() else { return }
        let deadline = now() + timeout
        while now() < deadline {
            if hasExited() {
                restartIfAllowed?()
                return
            }
            await wait()
        }
    }
}
