// RegionCapture.swift
// Full-screen overlay for region selection, like CleanShot X's ⌘⇧4 mode.
// A transparent NSPanel covers all screens; user drags to select the capture region.

import AppKit
import ScreenCaptureKit

// MARK: - Public entry point

enum RegionCapture {
    /// Show the region selector. Calls `completion` with the selected rect (top-left origin, logical points)
    /// or nil if the user cancelled.
    @MainActor
    static func start(completion: @escaping @MainActor (CGRect?) -> Void) {
        let overlay = RegionOverlayWindow(completion: completion)
        overlay.show()
    }
}

// MARK: - Overlay Window

@MainActor
private final class RegionOverlayWindow: NSObject {
    private var panels: [NSPanel] = []
    private var selectionPanel: NSPanel?
    private var startPoint: NSPoint?
    private var selectionRect: CGRect = .zero
    private var trackingAreaViews: [RegionView] = []
    private let completion: @MainActor (CGRect?) -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(completion: @escaping @MainActor (CGRect?) -> Void) {
        self.completion = completion
        super.init()
    }

    func show() {
        // One transparent panel per screen
        for screen in NSScreen.screens {
            let panel = makeOverlayPanel(for: screen)
            let view = RegionView(frame: screen.frame)
            view.overlayWindow = self
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
            trackingAreaViews.append(view)
        }
        NSCursor.crosshair.set()

        // ESC to cancel
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.cancel()
                return nil
            }
            return event
        }
    }

    private func makeOverlayPanel(for screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 1.0
        return panel
    }

    // MARK: - Mouse events (called by RegionView)

    func mouseDown(at screenPoint: NSPoint) {
        startPoint = screenPoint
        selectionRect = .zero

        let panel = NSPanel(
            contentRect: CGRect(x: screenPoint.x, y: screenPoint.y, width: 0, height: 0),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.contentView = SelectionRectView(frame: .zero)
        panel.orderFrontRegardless()
        selectionPanel = panel
    }

    func mouseDragged(to screenPoint: NSPoint) {
        guard let start = startPoint else { return }
        selectionRect = CGRect(
            x: min(start.x, screenPoint.x),
            y: min(start.y, screenPoint.y),
            width: abs(screenPoint.x - start.x),
            height: abs(screenPoint.y - start.y)
        )
        selectionPanel?.setFrame(selectionRect, display: true)
        if let view = selectionPanel?.contentView {
            view.frame = CGRect(origin: .zero, size: selectionRect.size)
            view.needsDisplay = true
        }
    }

    func mouseUp(at screenPoint: NSPoint) {
        guard selectionRect.width > 10, selectionRect.height > 10 else {
            cancel()
            return
        }
        captureSelection()
    }

    private func captureSelection() {
        // selectionRect is in NSScreen coordinates (bottom-left origin)
        // Convert to top-left origin (CaptureKit / CGWindowList convention)
        let mainScreenH = NSScreen.screens.first?.frame.height ?? 0
        let topLeftRect = CGRect(
            x: selectionRect.minX,
            y: mainScreenH - selectionRect.maxY,
            width: selectionRect.width,
            height: selectionRect.height
        )
        let rect = topLeftRect
        dismiss()

        Task { @MainActor in
            // Let overlay panels fully disappear before screenshot
            try? await Task.sleep(nanoseconds: 120_000_000)
            completion(rect)
        }
    }

    func cancel() {
        dismiss()
        completion(nil)  // nil = cancelled
    }

    private func dismiss() {
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
        selectionPanel?.orderOut(nil)
        selectionPanel = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        trackingAreaViews.removeAll()
        NSCursor.arrow.set()
    }
}

// MARK: - RegionView (receives mouse events)

private final class RegionView: NSView {
    weak var overlayWindow: RegionOverlayWindow?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convertToScreen(event.locationInWindow)
        overlayWindow?.mouseDown(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convertToScreen(event.locationInWindow)
        overlayWindow?.mouseDragged(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convertToScreen(event.locationInWindow)
        overlayWindow?.mouseUp(at: point)
    }

    private func convertToScreen(_ windowPoint: NSPoint) -> NSPoint {
        guard let win = window else { return windowPoint }
        let winFrame = win.frame
        return NSPoint(x: winFrame.minX + windowPoint.x, y: winFrame.minY + windowPoint.y)
    }

    override func draw(_ rect: NSRect) {
        // Slightly darker overlay (the panel background handles the global dim)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }
}

// MARK: - Selection rectangle visual

private final class SelectionRectView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.white.cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 2
    }
    required init?(coder: NSCoder) { fatalError() }
}
