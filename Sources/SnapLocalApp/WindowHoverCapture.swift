// WindowHoverCapture.swift
// CleanShot X-style window capture: hover over a window to highlight it, click to capture.

import AppKit
import ScreenCaptureKit

// MARK: - Entry point

@MainActor
enum WindowHoverCapture {
    static func start(windows: [SCWindow], completion: @escaping @MainActor (SCWindow?) -> Void) {
        let controller = WindowHoverCaptureController(windows: windows, completion: completion)
        controller.show()
    }
}

// MARK: - Controller

@MainActor
final class WindowHoverCaptureController: NSObject {
    private var panels: [NSPanel] = []
    private var overlayViews: [WindowOverlayView] = []
    private var keyMonitor: Any?
    private let windows: [SCWindow]
    private let completion: @MainActor (SCWindow?) -> Void

    // Sorted front-to-back for hit-testing (SCWindow list comes front-to-back from API)
    private let sortedWindows: [SCWindow]

    init(windows: [SCWindow], completion: @escaping @MainActor (SCWindow?) -> Void) {
        self.windows = windows
        self.sortedWindows = windows
        self.completion = completion
        super.init()
    }

    func show() {
        // Create an overlay panel for each screen
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelKey.screenSaverWindow.rawValue) + 5)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = WindowOverlayView(
                screenFrame: screen.frame,
                windows: sortedWindows,
                onHoverChange: { [weak self] hoveredID in
                    // Broadcast hover state to all views (multi-monitor sync)
                    self?.overlayViews.forEach { $0.updateHoveredWindowID(hoveredID) }
                },
                onClick: { [weak self] win in
                    self?.finish(with: win)
                },
                onCancel: { [weak self] in
                    self?.finish(with: nil)
                }
            )
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            view.autoresizingMask = [.width, .height]
            panel.contentView = view

            panels.append(panel)
            overlayViews.append(view)
        }

        panels.forEach { $0.orderFrontRegardless() }

        // ESC key monitor (panels are non-activating, so keyDown on view won't fire)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.finish(with: nil)
                return nil
            }
            return event
        }
    }

    private func finish(with window: SCWindow?) {
        if let mon = keyMonitor { NSEvent.removeMonitor(mon); keyMonitor = nil }
        let toClose = panels
        panels.removeAll()
        overlayViews.removeAll()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            toClose.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            toClose.forEach { $0.orderOut(nil) }
        })
        completion(window)
    }
}

// MARK: - Overlay NSView

private final class WindowOverlayView: NSView {
    private let screenFrame: NSRect         // NS screen-space frame of this panel's screen
    private let windows: [SCWindow]
    private var hoveredWindowID: CGWindowID? = nil

    var onHoverChange: ((CGWindowID?) -> Void)?
    var onClick: ((SCWindow) -> Void)?
    var onCancel: (() -> Void)?

    // Primary screen height for CG↔NS y-axis flip
    private static var primaryNSHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 768
    }

    init(screenFrame: NSRect, windows: [SCWindow],
         onHoverChange: @escaping (CGWindowID?) -> Void,
         onClick: @escaping (SCWindow) -> Void,
         onCancel: @escaping () -> Void) {
        self.screenFrame = screenFrame
        self.windows = windows
        self.onHoverChange = onHoverChange
        self.onClick = onClick
        self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Tracking area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    // MARK: Coordinate helpers

    /// Convert SCWindow's CG-coordinate frame to NS screen space
    private func nsFrame(for cgFrame: CGRect) -> CGRect {
        let primaryH = WindowOverlayView.primaryNSHeight
        let nsY = primaryH - cgFrame.maxY
        return CGRect(x: cgFrame.minX, y: nsY, width: cgFrame.width, height: cgFrame.height)
    }

    /// Convert NS screen-space rect to view-local coordinates
    private func viewLocal(for nsRect: CGRect) -> CGRect {
        CGRect(
            x: nsRect.minX - screenFrame.minX,
            y: nsRect.minY - screenFrame.minY,
            width: nsRect.width,
            height: nsRect.height
        )
    }

    /// Find the frontmost window containing the NS-space point
    private func findWindow(atNS nsPoint: CGPoint) -> SCWindow? {
        for win in windows {
            if nsFrame(for: win.frame).contains(nsPoint) { return win }
        }
        return nil
    }

    // MARK: Update from controller

    func updateHoveredWindowID(_ id: CGWindowID?) {
        if hoveredWindowID != id {
            hoveredWindowID = id
            needsDisplay = true
        }
    }

    // MARK: Mouse events

    override func mouseMoved(with event: NSEvent) {
        let screenPt = NSEvent.mouseLocation
        let hit = findWindow(atNS: screenPt)
        let hitID = hit?.windowID
        if hitID != hoveredWindowID {
            hoveredWindowID = hitID
            onHoverChange?(hitID)
            needsDisplay = true
        }
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        if hoveredWindowID != nil {
            hoveredWindowID = nil
            onHoverChange?(nil)
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let screenPt = NSEvent.mouseLocation
        if let win = findWindow(atNS: screenPt) {
            onClick?(win)
        } else {
            onCancel?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Subtle dim over entire screen to signal "capture mode"
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.fill(bounds)

        // Find the hovered window for this view's screen
        guard let hid = hoveredWindowID,
              let hovered = windows.first(where: { $0.windowID == hid }) else {
            drawHint(in: ctx)
            return
        }

        let ns = nsFrame(for: hovered.frame)
        let local = viewLocal(for: ns)
        let visibleLocal = local.intersection(bounds)
        guard !visibleLocal.isNull, visibleLocal.width > 4, visibleLocal.height > 4 else {
            drawHint(in: ctx)
            return
        }

        // Spotlight: clear the dim inside the hovered window
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(local)
        ctx.restoreGState()

        // Outer glow ring
        let outerInset: CGFloat = -4
        let outerRect = local.insetBy(dx: outerInset, dy: outerInset)
        let outerPath = CGPath(roundedRect: outerRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(6)
        ctx.addPath(outerPath)
        ctx.strokePath()

        // Main highlight border (inside)
        let borderRect = local.insetBy(dx: 2, dy: 2)
        let borderPath = CGPath(roundedRect: borderRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(3)
        ctx.addPath(borderPath)
        ctx.strokePath()

        drawBadge(for: hovered, windowLocalFrame: local, in: ctx)
        drawHint(in: ctx)
    }

    private func drawBadge(for window: SCWindow, windowLocalFrame: CGRect, in ctx: CGContext) {
        let appName = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        let nameLabel: String
        if title.isEmpty || title == appName {
            nameLabel = appName.isEmpty ? "Window" : appName
        } else if appName.isEmpty {
            nameLabel = title
        } else {
            nameLabel = "\(appName)  —  \(title)"
        }

        // Pixel dimensions using screen backing scale
        let scale = window_(for: windowLocalFrame) ?? 2.0
        let pxW = Int(window.frame.width * scale)
        let pxH = Int(window.frame.height * scale)
        let sizeLabel = "\(pxW) × \(pxH)"

        let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let sizeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: NSColor.white]
        let sizeAttrs: [NSAttributedString.Key: Any] = [.font: sizeFont, .foregroundColor: NSColor.white.withAlphaComponent(0.65)]
        let nameStr = NSAttributedString(string: nameLabel, attributes: nameAttrs)
        let sizeStr = NSAttributedString(string: sizeLabel, attributes: sizeAttrs)
        let nameSize = nameStr.size()
        let sizeSize = sizeStr.size()
        let innerW = max(nameSize.width, sizeSize.width)
        let innerH = nameSize.height + 2 + sizeSize.height

        let hPad: CGFloat = 10
        let vPad: CGFloat = 7
        let badgeW = min(innerW + hPad * 2, windowLocalFrame.width - 8)
        let badgeH = innerH + vPad * 2
        let badgeX = windowLocalFrame.midX - badgeW / 2
        let badgeMinY = windowLocalFrame.minY - badgeH - 8
        let badgeY = badgeMinY >= 0 ? badgeMinY : windowLocalFrame.minY + 8

        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)

        ctx.setFillColor(NSColor(red: 0.05, green: 0.05, blue: 0.12, alpha: 0.90).cgColor)
        ctx.addPath(badgePath); ctx.fillPath()
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1); ctx.addPath(badgePath); ctx.strokePath()

        ctx.saveGState()
        ctx.addPath(badgePath)
        ctx.clip()
        // Name on top, size below
        let nameX = badgeRect.minX + hPad
        let nameY = badgeRect.minY + vPad + sizeSize.height + 2
        let sizeX = badgeRect.minX + hPad
        let sizeY = badgeRect.minY + vPad
        nameStr.draw(at: CGPoint(x: nameX, y: nameY))
        sizeStr.draw(at: CGPoint(x: sizeX, y: sizeY))
        ctx.restoreGState()
    }

    // Best-guess backing scale for the window's screen
    private func window_(for localFrame: CGRect) -> CGFloat? {
        // Find the NSScreen whose frame contains the center of the local rect
        let centerNS = CGPoint(
            x: screenFrame.minX + localFrame.midX,
            y: screenFrame.minY + localFrame.midY
        )
        return NSScreen.screens.first(where: { $0.frame.contains(centerNS) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
    }

    private func drawHint(in ctx: CGContext) {
        let hint = "クリックでキャプチャ  •  ESC でキャンセル"
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let str = NSAttributedString(string: hint, attributes: attrs)
        let strSize = str.size()
        let hPad: CGFloat = 12
        let vPad: CGFloat = 5
        let badgeW = strSize.width + hPad * 2
        let badgeH = strSize.height + vPad * 2
        let badgeX = bounds.midX - badgeW / 2
        let badgeY: CGFloat = 18
        let rect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        str.draw(at: CGPoint(x: badgeX + hPad, y: badgeY + vPad))
    }
}
