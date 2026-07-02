//
//  NotchWindow.swift
//  TraeFlow
//
//  Transparent window that overlays the notch area.
//  Mouse-event ignoring is managed dynamically by NotchWindowController
//  based on real-time mouse position — when the cursor is inside the
//  Flow Island content area, ignoresMouseEvents is set to false so
//  SwiftUI buttons can respond; when the cursor is outside, it is set
//  to true so clicks pass through to windows behind the panel.
//

import AppKit

// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Floating panel behavior
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Transparent configuration
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false

        // CRITICAL: Prevent window from moving during space switches
        isMovable = false

        // Window behavior - stays on all spaces, above menu bar
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        // Above the menu bar
        level = .mainMenu + 3

        // Enable tooltips even when app is inactive (needed for panel windows)
        allowsToolTipsWhenApplicationIsInactive = true

        // Default: ignore all mouse events.
        // NotchWindowController dynamically toggles this to false when
        // the mouse is inside the actual content area and the panel is opened.
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
