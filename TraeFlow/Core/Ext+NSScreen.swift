//
//  Ext+NSScreen.swift
//  TraeFlow
//
//  Extensions for NSScreen to detect notch and built-in display
//

import AppKit

extension NSScreen {
    var notchMetrics: ScreenNotchMetrics {
        ScreenNotchMetrics.detect(
            screenFrame: frame,
            safeAreaTop: safeAreaInsets.top,
            auxiliaryTopLeftWidth: auxiliaryTopLeftArea?.width,
            auxiliaryTopRightWidth: auxiliaryTopRightArea?.width
        )
    }

    /// Returns the size of the notch on this screen using macOS safe-area APIs when available.
    var notchSize: CGSize {
        notchMetrics.size
    }

    /// Whether this is the built-in display
    var isBuiltinDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    /// The built-in display (with notch on newer MacBooks)
    static var builtin: NSScreen? {
        if let builtin = screens.first(where: { $0.isBuiltinDisplay }) {
            return builtin
        }
        return NSScreen.main
    }

    /// Whether this screen has a physical notch (camera housing)
    var hasPhysicalNotch: Bool {
        notchMetrics.hasPhysicalNotch
    }
}
