import AppKit
import CoreGraphics

struct ActiveWindowFrameResolver {
    static func currentActiveWindowFrame(
        excludingBundleIdentifier excludedBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let preferredProcessIdentifier = preferredProcessIdentifier(
            excludingBundleIdentifier: excludedBundleIdentifier
        )
        let excludedProcessIdentifiers = processIdentifiers(
            forBundleIdentifier: excludedBundleIdentifier
        )

        return topWindowFrame(
            in: windowList,
            preferredProcessIdentifier: preferredProcessIdentifier,
            excludedProcessIdentifiers: excludedProcessIdentifiers
        )
    }

    static func topWindowFrame(
        in windowList: [[String: Any]],
        preferredProcessIdentifier: pid_t?,
        excludedProcessIdentifiers: Set<pid_t> = []
    ) -> CGRect? {
        if let preferredProcessIdentifier,
           let preferredWindow = windowList.first(where: {
               frame(from: $0, matchingProcessIdentifier: preferredProcessIdentifier) != nil
           }) {
            return frame(
                from: preferredWindow,
                matchingProcessIdentifier: preferredProcessIdentifier
            )
        }

        for window in windowList {
            guard let frame = frame(from: window) else { continue }
            let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t
            if let ownerPID, excludedProcessIdentifiers.contains(ownerPID) {
                continue
            }
            return frame
        }

        return nil
    }

    private static func preferredProcessIdentifier(
        excludingBundleIdentifier excludedBundleIdentifier: String?
    ) -> pid_t? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if frontmostApplication.bundleIdentifier == excludedBundleIdentifier {
            return nil
        }

        return frontmostApplication.processIdentifier
    }

    private static func processIdentifiers(
        forBundleIdentifier bundleIdentifier: String?
    ) -> Set<pid_t> {
        guard let bundleIdentifier else { return [] }

        return Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .map(\.processIdentifier)
        )
    }

    private static func frame(
        from window: [String: Any],
        matchingProcessIdentifier processIdentifier: pid_t
    ) -> CGRect? {
        guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
              ownerPID == processIdentifier else {
            return nil
        }

        return frame(from: window)
    }

    private static func frame(from window: [String: Any]) -> CGRect? {
        guard let layer = window[kCGWindowLayer as String] as? Int,
              layer == 0 else {
            return nil
        }

        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        guard alpha > 0 else {
            return nil
        }

        guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              bounds.width > 40,
              bounds.height > 40 else {
            return nil
        }

        return bounds
    }
}
