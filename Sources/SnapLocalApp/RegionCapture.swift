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

    // Loupe
    private var loupePanel: NSPanel?
    private var loupeView: LoupeView?
    private var screenSnapshots: [CGDirectDisplayID: CGImage] = [:]

    init(completion: @escaping @MainActor (CGRect?) -> Void) {
        self.completion = completion
        super.init()
    }

    func show() {
        // Capture snapshots for loupe (synchronous, before showing overlay)
        for screen in NSScreen.screens {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               let image = CGDisplayCreateImage(displayID) {
                screenSnapshots[displayID] = image
            }
        }

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

        setupLoupe()

        // ESC to cancel + cursor tracking
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            if event.type == .mouseMoved {
                let loc = NSEvent.mouseLocation
                self?.updateLoupe(at: loc, selectionSize: .zero)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            let size = self.startPoint != nil ? self.selectionRect.size : .zero
            self.updateLoupe(at: loc, selectionSize: size)
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
        updateLoupe(at: screenPoint, selectionSize: selectionRect.size)
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
        loupePanel?.orderOut(nil)
        loupePanel = nil
        loupeView = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        trackingAreaViews.removeAll()
        screenSnapshots.removeAll()
        NSCursor.arrow.set()
    }

    // MARK: - Loupe

    private let loupeSize: CGFloat = 152
    private let loupeZoom: CGFloat = 3.0

    private func setupLoupe() {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: loupeSize, height: loupeSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver + 2
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = LoupeView(frame: CGRect(x: 0, y: 0, width: loupeSize, height: loupeSize))
        panel.contentView = view
        panel.orderFrontRegardless()
        loupePanel = panel
        loupeView = view

        updateLoupe(at: NSEvent.mouseLocation, selectionSize: .zero)
    }

    private func updateLoupe(at cursorScreen: NSPoint, selectionSize: CGSize) {
        guard let panel = loupePanel, let view = loupeView else { return }

        // Find which display the cursor is on (NSScreen coords)
        let screen = NSScreen.screens.first(where: { NSPointInRect(cursorScreen, $0.frame) }) ?? NSScreen.main
        guard let screen else { return }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let snapshot = displayID.flatMap { screenSnapshots[$0] }

        // Convert cursor from NSScreen (bottom-left) to display-local points (top-left)
        let localX = cursorScreen.x - screen.frame.minX
        let localY_topLeft = screen.frame.height - (cursorScreen.y - screen.frame.minY)
        let scale = screen.backingScaleFactor

        // Update view
        view.snapshot = snapshot
        view.cursorPixel = CGPoint(x: localX * scale, y: localY_topLeft * scale)
        view.cursorLogicalPoint = CGPoint(x: localX, y: localY_topLeft)
        view.snapshotSize = CGSize(width: CGFloat(snapshot?.width ?? 1), height: CGFloat(snapshot?.height ?? 1))
        view.selectionSize = selectionSize
        view.needsDisplay = true

        // Position loupe: offset from cursor, flip when near right/top edge
        let offset: CGFloat = 20
        var lx = cursorScreen.x + offset
        var ly = cursorScreen.y + offset
        // Flip right if too close to right edge
        if lx + loupeSize > screen.frame.maxX - 4 { lx = cursorScreen.x - loupeSize - offset }
        // Flip down if too close to top edge
        if ly + loupeSize > screen.frame.maxY - 4 { ly = cursorScreen.y - loupeSize - offset }
        panel.setFrameOrigin(NSPoint(x: lx, y: ly))
    }
}

// MARK: - Loupe View

private final class LoupeView: NSView {
    var snapshot: CGImage?
    var cursorPixel: CGPoint = .zero
    var snapshotSize: CGSize = .zero
    var selectionSize: CGSize = .zero
    /// Cursor position in logical points (for the coord label)
    var cursorLogicalPoint: CGPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)

        // Draw zoomed screenshot
        if let snapshot {
            // The region we want to show: loupeSize/zoom logical pixels, in snapshot pixels
            let zoom: CGFloat = 3.0
            let capturePts = bounds.width / zoom  // logical pts we're zooming
            let capturePx = capturePts  // snapshot pixels (snapshot is at display scale already)

            let srcRect = CGRect(
                x: cursorPixel.x - capturePx / 2,
                y: cursorPixel.y - capturePx / 2,
                width: capturePx,
                height: capturePx
            ).intersection(CGRect(origin: .zero, size: snapshotSize))

            if let crop = snapshot.cropping(to: srcRect) {
                ctx.interpolationQuality = .none
                ctx.draw(crop, in: bounds)
            }
        }

        // Crosshair
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.0)
        let cx = bounds.midX, cy = bounds.midY
        ctx.move(to: CGPoint(x: cx, y: 0)); ctx.addLine(to: CGPoint(x: cx, y: bounds.height))
        ctx.move(to: CGPoint(x: 0, y: cy)); ctx.addLine(to: CGPoint(x: bounds.width, y: cy))
        ctx.strokePath()

        // Bottom label: selection size when dragging, cursor coords + color when idle
        let isDragging = selectionSize.width >= 1 && selectionSize.height >= 1
        let label: String
        if isDragging {
            label = "\(Int(selectionSize.width))×\(Int(selectionSize.height))"
        } else {
            label = "\(Int(cursorLogicalPoint.x)), \(Int(cursorLogicalPoint.y))"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let textSize = str.size()
        let pad: CGFloat = 4
        let bgRect = CGRect(
            x: (bounds.width - textSize.width) / 2 - pad,
            y: pad,
            width: textSize.width + pad * 2,
            height: textSize.height + pad
        )
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        let path = CGPath(roundedRect: bgRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(path); ctx.fillPath()
        str.draw(at: CGPoint(x: bgRect.minX + pad, y: bgRect.minY + pad / 2))

        // Pixel color swatch + hex label when idle
        if !isDragging, let snap = snapshot {
            let px = max(0, min(Int(cursorPixel.x), snap.width - 1))
            let py = max(0, min(Int(cursorPixel.y), snap.height - 1))
            if let colorCtx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
               let cropped = snap.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) {
                colorCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if let data = colorCtx.data {
                    let p = data.bindMemory(to: UInt8.self, capacity: 4)
                    let r = p[0], g = p[1], b = p[2]
                    let hexStr = String(format: "#%02X%02X%02X", r, g, b)
                    let swatchW: CGFloat = 12
                    let hexAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                        .foregroundColor: NSColor.white
                    ]
                    let hexAS = NSAttributedString(string: hexStr, attributes: hexAttrs)
                    let hexSz = hexAS.size()
                    let totalW = swatchW + 4 + hexSz.width
                    let rowH: CGFloat = swatchW
                    let rowY = bgRect.maxY + 4
                    let rowX = (bounds.width - totalW) / 2
                    // Color swatch
                    ctx.setFillColor(CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1))
                    ctx.fill(CGRect(x: rowX, y: rowY, width: swatchW, height: rowH))
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
                    ctx.setLineWidth(0.5)
                    ctx.stroke(CGRect(x: rowX, y: rowY, width: swatchW, height: rowH))
                    // Hex label
                    hexAS.draw(at: CGPoint(x: rowX + swatchW + 4, y: rowY + (rowH - hexSz.height) / 2))
                }
            }
        }

        // Circular border
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: bounds.insetBy(dx: 1.25, dy: 1.25))
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
