//
//  UserIdleAutoProtection.swift
//  TraeFlow
//
//  Temporarily routes blocking prompts back to the terminal while the user is away.
//

import Foundation
import IOKit

enum SystemUserIdleTimeReader {
    nonisolated static func idleTime() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let idleNanoseconds = idleNanoseconds(from: dictionary["HIDIdleTime"]) else {
            return 0
        }

        return TimeInterval(idleNanoseconds) / 1_000_000_000
    }

    nonisolated private static func idleNanoseconds(from value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let integer = value as? UInt64 {
            return integer
        }
        return nil
    }
}

@MainActor
final class UserIdleAutoProtection {
    static let shared = UserIdleAutoProtection(settings: AppSettingsStore.shared)

    private let settings: AppSettingsStore
    private let idleSecondsProvider: () -> TimeInterval
    private let pollingInterval: TimeInterval
    private var timer: Timer?

    init(
        settings: AppSettingsStore,
        idleSecondsProvider: @escaping () -> TimeInterval = SystemUserIdleTimeReader.idleTime,
        pollingInterval: TimeInterval = 5
    ) {
        self.settings = settings
        self.idleSecondsProvider = idleSecondsProvider
        self.pollingInterval = pollingInterval
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        guard timer == nil else {
            refreshNow()
            return
        }

        refreshNow()
        let nextTimer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        timer = nextTimer
        RunLoop.main.add(nextTimer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        settings.setIdleAutoRoutePromptsToTerminalActive(false)
    }

    func refreshNow() {
        let idleSeconds = max(0, idleSecondsProvider())
        let shouldActivate = Self.shouldActivateAutoProtection(
            enabled: settings.autoRoutePromptsToTerminalWhenIdleEnabled,
            delay: settings.autoRoutePromptsIdleDelay,
            idleSeconds: idleSeconds
        )
        settings.setIdleAutoRoutePromptsToTerminalActive(shouldActivate)
    }

    nonisolated static func shouldActivateAutoProtection(
        enabled: Bool,
        delay: AutoRoutePromptsIdleDelay,
        idleSeconds: TimeInterval
    ) -> Bool {
        enabled && idleSeconds >= delay.duration
    }
}
