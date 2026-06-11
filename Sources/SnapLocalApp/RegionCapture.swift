// RegionCapture.swift
// Full-screen overlay for region selection, like CleanShot X's ⌘⇧4 mode.
// A transparent NSPanel covers all screens; user drags to select the capture region.
// UX: punch-through dark overlay, 8-handle resize, Enter to confirm, arrow-key nudge.

import AppKit
import AudioToolbox
import Carbon
import ScreenCaptureKit

// MARK: - Public entry point

enum RegionCapture {
    /// Strong reference to the live overlay controller. The NSPanels are kept alive by
    /// AppKit while on screen, but this NSObject controller is not — every view/monitor
    /// holds it weakly, so without this reference it deallocates as soon as start()
    /// returns, leaving opaque black panels (RegionView.draw early-returns) that no
    /// event handler can ever dismiss, frozen over every Space at screenSaver level.
    @MainActor private static var activeOverlay: RegionOverlayWindow?

    /// completion receives the selection rect (CG top-left coords) and, when a frozen
    /// screenshot is available, the pre-cropped CGImage so callers can skip re-capture.
    /// - Parameter initialRect: Optional CG-coordinates rect (top-left origin) to pre-select on open.
    @MainActor
    static func start(initialRect: CGRect? = nil, completion: @escaping @MainActor (CGRect?, CGImage?) -> Void) {
        // Toggle: pressing ⌘⇧4 while an overlay is already up cancels it (escape hatch)
        // instead of stacking a second overlay. The new completion is dropped; the
        // original one receives (nil, nil) via cancel().
        if let existing = activeOverlay {
            existing.cancel()
            return
        }
        let overlay = RegionOverlayWindow(completion: completion)
        activeOverlay = overlay
        overlay.show(preselectedCGRect: initialRect)
    }

    @MainActor
    fileprivate static func didDismiss(_ overlay: RegionOverlayWindow) {
        if activeOverlay === overlay { activeOverlay = nil }
    }

    /// Failsafe ESC/Enter, registered as Carbon global hotkeys only while the overlay
    /// is up. NSEvent local monitors require keyboard focus, which is unreliable when
    /// the hotkey fires while another app is active; Carbon hotkeys fire regardless
    /// of focus (same mechanism as ⌘⇧4 itself) and need no extra permissions.
    @MainActor
    fileprivate static func handleFailsafeHotkey(id: UInt32) {
        guard let overlay = activeOverlay else { return }
        if id == 1 {
            overlay.cancel()
        } else if id == 2, overlay.isAdjusting {
            overlay.commit()
        }
    }
}

// MARK: - Capture State

private enum CaptureState {
    case idle       // pre-drag, window snap
    case dragging   // mouse held down
    case adjusting  // selection complete, resize handles visible
}

// MARK: - Resize Handle

private enum ResizeHandle {
    case topLeft, top, topRight
    case left, move, right
    case bottomLeft, bottom, bottomRight

    static let hitRadius: CGFloat = 14

    /// 8 directional handles (excludes .move)
    static let resizeHandles: [ResizeHandle] = [
        .topLeft, .top, .topRight,
        .left, .right,
        .bottomLeft, .bottom, .bottomRight
    ]

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.maxY)
        case .top:         return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.maxY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.minY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .move:        return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    var cursor: NSCursor {
        switch self {
        case .topLeft, .bottomRight: return NSCursor(image: Self.diagonalResizeCursor(nwse: true), hotSpot: NSPoint(x: 8, y: 8))
        case .topRight, .bottomLeft: return NSCursor(image: Self.diagonalResizeCursor(nwse: false), hotSpot: NSPoint(x: 8, y: 8))
        case .top, .bottom:          return .resizeUpDown
        case .left, .right:          return .resizeLeftRight
        case .move:                  return .openHand
        }
    }

    private static func diagonalResizeCursor(nwse: Bool) -> NSImage {
        // Draw a 16×16 diagonal double-headed arrow
        let img = NSImage(size: NSSize(width: 16, height: 16))
        img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        if nwse {
            ctx.move(to: CGPoint(x: 3, y: 13)); ctx.addLine(to: CGPoint(x: 13, y: 3))
            ctx.move(to: CGPoint(x: 3, y: 13)); ctx.addLine(to: CGPoint(x: 3, y: 8))
            ctx.move(to: CGPoint(x: 3, y: 13)); ctx.addLine(to: CGPoint(x: 8, y: 13))
            ctx.move(to: CGPoint(x: 13, y: 3)); ctx.addLine(to: CGPoint(x: 13, y: 8))
            ctx.move(to: CGPoint(x: 13, y: 3)); ctx.addLine(to: CGPoint(x: 8, y: 3))
        } else {
            ctx.move(to: CGPoint(x: 13, y: 13)); ctx.addLine(to: CGPoint(x: 3, y: 3))
            ctx.move(to: CGPoint(x: 13, y: 13)); ctx.addLine(to: CGPoint(x: 8, y: 13))
            ctx.move(to: CGPoint(x: 13, y: 13)); ctx.addLine(to: CGPoint(x: 13, y: 8))
            ctx.move(to: CGPoint(x: 3, y: 3)); ctx.addLine(to: CGPoint(x: 3, y: 8))
            ctx.move(to: CGPoint(x: 3, y: 3)); ctx.addLine(to: CGPoint(x: 8, y: 3))
        }
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        img.unlockFocus()
        return img
    }

    /// Apply a drag delta to a rect, keeping it valid (positive size)
    func apply(delta: CGSize, to rect: CGRect) -> CGRect {
        var r = rect
        switch self {
        case .topLeft:
            r.origin.x += delta.width;  r.size.width  -= delta.width
            r.size.height += delta.height
        case .top:
            r.size.height += delta.height
        case .topRight:
            r.size.width  += delta.width
            r.size.height += delta.height
        case .left:
            r.origin.x += delta.width;  r.size.width  -= delta.width
        case .right:
            r.size.width  += delta.width
        case .bottomLeft:
            r.origin.x += delta.width;  r.size.width  -= delta.width
            r.origin.y += delta.height; r.size.height -= delta.height
        case .bottom:
            r.origin.y += delta.height; r.size.height -= delta.height
        case .bottomRight:
            r.size.width  += delta.width
            r.origin.y += delta.height; r.size.height -= delta.height
        case .move:
            r.origin.x += delta.width; r.origin.y += delta.height
        }
        // Prevent negative dimensions
        if r.size.width < 4  { r.size.width = 4 }
        if r.size.height < 4 { r.size.height = 4 }
        return r
    }
}

// MARK: - Overlay Window

/// Borderless panels refuse key status by default. Key status is required so that
/// ESC/Enter reach our local event monitor when the global hotkey fires while
/// another app is active (.nonactivatingPanel keeps that app active, Spotlight-style).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class RegionOverlayWindow: NSObject {
    private var panels: [NSPanel] = []
    private var trackingViews: [RegionView] = []
    private let completion: @MainActor (CGRect?, CGImage?) -> Void

    // State
    private var captureState: CaptureState = .idle
    var selectionRect: CGRect = .zero   // NSScreen coords (bottom-left origin)
    private var dragStart: NSPoint?
    var cursorScreenPoint: NSPoint = .zero  // current cursor in NSScreen coords

    // Resize/move
    private var activeHandle: ResizeHandle?
    private var handleDragStart: NSPoint?
    private var handleRectStart: CGRect = .zero

    // Space-to-reposition: hold Space during drag to translate the selection
    var spaceHeldDuringDrag = false
    private var spaceDragPrevPoint: NSPoint?

    // Keyboard / event monitors
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var animationTimer: Timer?

    // Failsafe Carbon hotkeys (ESC / Enter), live only while the overlay is shown
    private var failsafeHotkeyRefs: [EventHotKeyRef] = []
    private var failsafeHandler: EventHandlerRef?

    // Selection confirmed pulse
    var selectionConfirmedAt: CFAbsoluteTime = 0

    // App that was frontmost before we activated ourselves (restored on dismiss)
    private var previousApp: NSRunningApplication?

    private var screenSnapshots: [CGDirectDisplayID: CGImage] = [:]

    // Whether the overlay was opened with an initialRect (pre-selection); used to
    // distinguish "adjust existing selection" (traditional Enter-to-confirm) from
    // "fresh drag" (mouseUp → instant commit).
    private var startedWithPreselection = false

    // Window snap
    private var windowSnapPanel: NSPanel?
    private var windowSnapRect: CGRect?
    private var ourPanelNumbers: Set<CGWindowID> = []
    // Snap target stashed at mouseDown; committed on mouseUp only if the mouse
    // didn't move (= a click). A drag starting over a window selects a region.
    private var pendingWindowSnap: CGRect?

    init(completion: @escaping @MainActor (CGRect?, CGImage?) -> Void) {
        self.completion = completion
        super.init()
    }

    func show(preselectedCGRect cgRect: CGRect? = nil) {
        // Frozen-screen snapshots require Screen Recording permission. Without it
        // CGDisplayCreateImage returns a wallpaper-only image (all windows missing),
        // which would freeze the screen to a fake desktop. Skip freezing instead:
        // the nil-snapshot path shows a translucent dark overlay over the live screen
        // and the selection is re-captured via ScreenCaptureKit on commit.
        if CGPreflightScreenCaptureAccess() {
            for screen in NSScreen.screens {
                if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                   let image = CGDisplayCreateImage(displayID) {
                    screenSnapshots[displayID] = image
                }
            }
        }

        // One opaque panel per screen showing frozen screenshot (fade in for smooth entry)
        for screen in NSScreen.screens {
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let frozenImage = displayID.flatMap { screenSnapshots[$0] }
            let panel = makeOverlayPanel(for: screen, opaque: frozenImage != nil)
            let view = RegionView(frame: screen.frame)
            view.overlayWindow = self
            view.frozenImage = frozenImage
            panel.contentView = view
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panels.append(panel)
            trackingViews.append(view)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panels.forEach { $0.animator().alphaValue = 1.0 }
        }

        // Keyboard events (ESC/Enter/arrows) only reach our local monitor while this
        // app is active, so activate it — the overlay covers the screen, so nothing
        // visibly changes — and restore the previously active app on dismiss.
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        let mouse = NSEvent.mouseLocation
        let keyPanel = panels.first(where: { NSPointInRect(mouse, $0.frame) }) ?? panels.first
        keyPanel?.makeKeyAndOrderFront(nil)

        // Snapshot our own window numbers to exclude from window snapping
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for info in list {
                if let pid = info[kCGWindowOwnerPID as String] as? Int32,
                   pid == ProcessInfo.processInfo.processIdentifier,
                   let wid = info[kCGWindowNumber as String] as? CGWindowID {
                    ourPanelNumbers.insert(wid)
                }
            }
        }

        setupWindowSnapPanel()
        NSCursor.crosshair.set()
        setupEvents()
        setupFailsafeHotkeys()
        startBorderAnimation()

        // Pre-select the given region (CG coords → NS coords)
        if let cg = cgRect, let mainH = NSScreen.screens.first?.frame.height {
            // CG: top-left origin. NS: bottom-left origin. Convert:
            let nsY = mainH - cg.maxY
            let nsRect = CGRect(x: cg.minX, y: nsY, width: cg.width, height: cg.height)
            // Clamp to available screen space
            let screenBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            let clamped = nsRect.intersection(screenBounds)
            if !clamped.isNull, clamped.width > 4, clamped.height > 4 {
                selectionRect = clamped
                captureState = .adjusting
                startedWithPreselection = true
                trackingViews.forEach { $0.needsDisplay = true }
            }
        }
    }

    private func makeOverlayPanel(for screen: NSScreen, opaque: Bool = false) -> NSPanel {
        let panel = KeyablePanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = opaque
        panel.backgroundColor = opaque ? .black : .clear
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    // MARK: - Animation

    private func startBorderAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.setNeedsRedisplay()
            }
        }
    }

    func setNeedsRedisplay() {
        trackingViews.forEach { $0.needsDisplay = true }
    }

    // MARK: - Event Setup

    private func setupFailsafeHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard hkID.signature == OSType(0x534E4C52) else { return OSStatus(eventNotHandledErr) }
            let id = hkID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { RegionCapture.handleFailsafeHotkey(id: id) }
            }
            return noErr
        }, 1, &spec, nil, &failsafeHandler)

        let sig = OSType(0x534E4C52)   // 'SNLR'
        for (id, keyCode) in [(UInt32(1), UInt32(kVK_Escape)), (UInt32(2), UInt32(kVK_Return))] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(keyCode, 0, EventHotKeyID(signature: sig, id: id),
                                GetApplicationEventTarget(), 0, &ref)
            if let ref { failsafeHotkeyRefs.append(ref) }
        }
    }

    private func teardownFailsafeHotkeys() {
        failsafeHotkeyRefs.forEach { UnregisterEventHotKey($0) }
        failsafeHotkeyRefs.removeAll()
        if let h = failsafeHandler { RemoveEventHandler(h); failsafeHandler = nil }
    }

    private func setupEvents() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .mouseMoved, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyUp:
                if event.keyCode == 49 {  // Space released
                    self.spaceHeldDuringDrag = false
                    self.spaceDragPrevPoint = nil
                    NSCursor.crosshair.set()
                }
            case .keyDown:
                if event.keyCode == 53 { self.cancel(); return nil }     // ESC
                if event.keyCode == 36 || event.keyCode == 76 {          // Enter / numpad Enter
                    if self.captureState == .adjusting { self.commit(); return nil }
                }
                if event.keyCode == 49 {   // Space
                    if self.captureState == .idle {
                        if let r = self.windowSnapRect { self.commitWindowSnap(r) }
                        return nil
                    } else if self.captureState == .dragging && self.selectionRect != .zero {
                        self.spaceHeldDuringDrag = true
                        self.spaceDragPrevPoint = self.cursorScreenPoint
                        return nil
                    }
                }
                // Arrow key nudge in adjusting state
                if self.captureState == .adjusting {
                    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                    switch event.keyCode {
                    case 123: self.nudgeSelection(dx: -step, dy: 0); return nil   // left
                    case 124: self.nudgeSelection(dx: step, dy: 0); return nil    // right
                    case 125: self.nudgeSelection(dx: 0, dy: -step); return nil   // down
                    case 126: self.nudgeSelection(dx: 0, dy: step); return nil    // up
                    default: break
                    }
                }
            case .mouseMoved:
                let loc = NSEvent.mouseLocation
                self.cursorScreenPoint = loc
                self.setNeedsRedisplay()
                if self.captureState == .idle {
                    self.updateWindowSnap(at: loc)
                }
                if self.captureState == .adjusting {
                    self.updateCursorForAdjusting(at: loc)
                }
            default: break
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            Task { @MainActor in
                self.cursorScreenPoint = loc
                if self.captureState == .idle {
                    self.updateWindowSnap(at: loc)
                }
                self.setNeedsRedisplay()
            }
        }
    }

    // MARK: - Nudge

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        selectionRect.origin.x += dx
        selectionRect.origin.y += dy
        setNeedsRedisplay()
    }

    // MARK: - Cursor for adjusting state

    private func updateCursorForAdjusting(at point: NSPoint) {
        if let h = handleAt(point: point) {
            h.cursor.set()
        } else if selectionRect.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func handleAt(point: NSPoint) -> ResizeHandle? {
        for h in ResizeHandle.resizeHandles {
            let center = h.point(in: selectionRect)
            if hypot(point.x - center.x, point.y - center.y) <= ResizeHandle.hitRadius {
                return h
            }
        }
        return nil
    }

    // MARK: - Mouse events (called by RegionView)

    func mouseDown(at screenPoint: NSPoint, shiftHeld: Bool) {
        switch captureState {
        case .idle:
            pendingWindowSnap = windowSnapRect
            captureState = .dragging
            dragStart = screenPoint
            selectionRect = .zero
            windowSnapPanel?.orderOut(nil)
            windowSnapRect = nil

        case .adjusting:
            // Check if clicking a handle or inside selection to start resize/move
            if let h = handleAt(point: screenPoint) {
                activeHandle = h
                handleDragStart = screenPoint
                handleRectStart = selectionRect
                return
            }
            if selectionRect.contains(screenPoint) {
                activeHandle = .move
                handleDragStart = screenPoint
                handleRectStart = selectionRect
                return
            }
            // Click outside selection → start new selection
            captureState = .dragging
            dragStart = screenPoint
            selectionRect = .zero
            activeHandle = nil

        case .dragging:
            break
        }
    }

    func mouseDragged(to screenPoint: NSPoint, shiftHeld: Bool) {
        switch captureState {
        case .dragging:
            windowSnapPanel?.orderOut(nil)
            windowSnapRect = nil
            // Real movement turns the gesture into a region drag, not a click
            if let start = dragStart, hypot(screenPoint.x - start.x, screenPoint.y - start.y) > 4 {
                pendingWindowSnap = nil
            }

            // Space held: translate the whole selection (don't resize)
            if spaceHeldDuringDrag, let prev = spaceDragPrevPoint, selectionRect != .zero {
                let dx = screenPoint.x - prev.x
                let dy = screenPoint.y - prev.y
                dragStart = NSPoint(x: (dragStart?.x ?? 0) + dx, y: (dragStart?.y ?? 0) + dy)
                spaceDragPrevPoint = screenPoint
                let newEnd = NSPoint(x: screenPoint.x, y: screenPoint.y)
                let s = dragStart!
                selectionRect = CGRect(
                    x: min(s.x, newEnd.x), y: min(s.y, newEnd.y),
                    width: abs(newEnd.x - s.x), height: abs(newEnd.y - s.y)
                )
                NSCursor.closedHand.set()
                setNeedsRedisplay()
                return
            }

            guard let start = dragStart else { return }

            var rect = CGRect(
                x: min(start.x, screenPoint.x),
                y: min(start.y, screenPoint.y),
                width: abs(screenPoint.x - start.x),
                height: abs(screenPoint.y - start.y)
            )
            // Shift → constrain to square
            if shiftHeld {
                let side = min(rect.width, rect.height)
                if screenPoint.x < start.x { rect.origin.x = start.x - side } else { rect.origin.x = start.x }
                if screenPoint.y < start.y { rect.origin.y = start.y - side } else { rect.origin.y = start.y }
                rect.size = CGSize(width: side, height: side)
            }
            selectionRect = rect
            setNeedsRedisplay()

        case .adjusting:
            guard let h = activeHandle, let startPt = handleDragStart else { return }
            let delta = CGSize(width: screenPoint.x - startPt.x, height: screenPoint.y - startPt.y)
            selectionRect = h.apply(delta: delta, to: handleRectStart)
            handleDragStart = screenPoint
            handleRectStart = selectionRect
            setNeedsRedisplay()
            if h == .move { NSCursor.closedHand.set() } else { updateCursorForAdjusting(at: screenPoint) }

        case .idle:
            break
        }
    }

    func mouseUp(at screenPoint: NSPoint) {
        switch captureState {
        case .dragging:
            spaceHeldDuringDrag = false
            spaceDragPrevPoint = nil
            if let snap = pendingWindowSnap {
                pendingWindowSnap = nil
                commitWindowSnap(snap)
                return
            }
            if selectionRect.width > 10 && selectionRect.height > 10 {
                if startedWithPreselection {
                    // Re-drag from adjusting state (started with preselection): stay in
                    // adjusting so the user can fine-tune with handles before pressing Enter.
                    captureState = .adjusting
                    activeHandle = nil
                    handleDragStart = nil
                    selectionConfirmedAt = CFAbsoluteTimeGetCurrent()
                    setNeedsRedisplay()
                    updateCursorForAdjusting(at: screenPoint)
                } else {
                    // Fresh drag (⌘⇧4 without initialRect): commit immediately like
                    // macOS standard screenshot (mouse-up = capture, no Enter needed).
                    commit()
                }
            } else {
                cancel()
            }

        case .adjusting:
            activeHandle = nil
            handleDragStart = nil
            updateCursorForAdjusting(at: screenPoint)

        case .idle:
            break
        }
    }

    func doubleClick(at screenPoint: NSPoint) {
        if captureState == .adjusting { commit() }
    }

    // MARK: - Confirm / Cancel

    fileprivate func commit() {
        guard selectionRect.width > 0, selectionRect.height > 0 else { cancel(); return }
        let mainScreenH = NSScreen.screens.first?.frame.height ?? 0
        let topLeftRect = CGRect(
            x: selectionRect.minX,
            y: mainScreenH - selectionRect.maxY,
            width: selectionRect.width,
            height: selectionRect.height
        )
        // Pre-crop from frozen screenshot so caller can skip re-capture
        let preCroppedImage = cropFrozenSnapshot(selectionNSCoords: selectionRect)

        // Camera shutter sound
        AudioServicesPlaySystemSound(1108)
        // Brief selection flash before dismissing.
        // Capture completion strongly: dismiss() releases the controller, so a
        // `self?.completion` after it would silently never fire.
        let completion = self.completion
        flashSelection { [weak self] in
            self?.dismiss()
            Task { @MainActor in
                // Short pause so the overlay fully fades before editor opens;
                // reduced from 120ms since frozen-image path is near-instant.
                try? await Task.sleep(nanoseconds: preCroppedImage != nil ? 60_000_000 : 120_000_000)
                completion(topLeftRect, preCroppedImage)
            }
        }
    }

    /// Crop the frozen screenshot for the selection, returning a Retina-resolution CGImage.
    private func cropFrozenSnapshot(selectionNSCoords sel: CGRect) -> CGImage? {
        // Find the screen whose frame contains the selection center
        let center = NSPoint(x: sel.midX, y: sel.midY)
        guard let screen = NSScreen.screens.first(where: { NSPointInRect(center, $0.frame) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let snapshot = screenSnapshots[displayID] else { return nil }

        let scale = screen.backingScaleFactor
        // Convert selection from NSScreen coords (bottom-left) to display-local logical coords
        let localX = sel.minX - screen.frame.minX
        let localY = screen.frame.maxY - sel.maxY   // flip to top-left origin
        // Scale to physical pixels
        let pixelRect = CGRect(
            x: localX * scale, y: localY * scale,
            width: sel.width * scale, height: sel.height * scale
        )
        let snapshotBounds = CGRect(origin: .zero, size: CGSize(width: snapshot.width, height: snapshot.height))
        let clipped = pixelRect.intersection(snapshotBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return snapshot.cropping(to: clipped)
    }

    private func flashSelection(completion: @escaping () -> Void) {
        // Create a white flash panel over the selection area
        guard selectionRect.width > 0, selectionRect.height > 0 else { completion(); return }
        let flashPanel = NSPanel(
            contentRect: selectionRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        flashPanel.level = .screenSaver + 3
        flashPanel.isOpaque = false
        flashPanel.backgroundColor = .white
        flashPanel.alphaValue = 0
        flashPanel.ignoresMouseEvents = true
        flashPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        flashPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            flashPanel.animator().alphaValue = 0.7
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.08
                flashPanel.animator().alphaValue = 0
            }, completionHandler: {
                flashPanel.orderOut(nil)
                completion()
            })
        })
    }

    func cancel() {
        dismiss()
        completion(nil, nil)
    }

    private func dismiss() {
        animationTimer?.invalidate(); animationTimer = nil
        teardownFailsafeHotkeys()
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        windowSnapPanel?.orderOut(nil); windowSnapPanel = nil; windowSnapRect = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll(); trackingViews.removeAll()
        screenSnapshots.removeAll(); ourPanelNumbers.removeAll()
        NSCursor.arrow.set()
        // Give keyboard focus back to the app the user was in when the hotkey fired.
        // On commit, completion may re-activate us afterwards (openEditorOnCapture).
        if let prev = previousApp, !prev.isTerminated {
            prev.activate()
            previousApp = nil
        }
        RegionCapture.didDismiss(self)
    }

    // MARK: - Window Snap

    private func setupWindowSnapPanel() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        windowSnapPanel = panel
    }

    private func updateWindowSnap(at cursorScreen: NSPoint) {
        guard let panel = windowSnapPanel else { return }
        let found = windowRectAt(cursor: cursorScreen)
        if let rect = found {
            windowSnapRect = rect
            panel.setFrame(rect, display: true)
            if let v = panel.contentView as? WindowSnapView {
                v.frame = CGRect(origin: .zero, size: rect.size)
                v.needsDisplay = true
            } else {
                panel.contentView = WindowSnapView(frame: CGRect(origin: .zero, size: rect.size))
            }
            panel.orderFrontRegardless()
        } else {
            windowSnapRect = nil
            panel.orderOut(nil)
        }
    }

    private func commitWindowSnap(_ snapRect: CGRect) {
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let topLeftRect = CGRect(
            x: snapRect.minX,
            y: mainH - snapRect.maxY,
            width: snapRect.width,
            height: snapRect.height
        )
        let completion = self.completion
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            completion(topLeftRect, nil)   // window snap always re-captures via SCKit
        }
    }

    private func windowRectAt(cursor: NSPoint) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  !ourPanelNumbers.contains(wid),
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"],
                  w > 20, h > 20
            else { continue }
            let mainScreenH = NSScreen.screens.first?.frame.height ?? 0
            let nsRect = CGRect(x: x, y: mainScreenH - y - h, width: w, height: h)
            if nsRect.contains(cursor) {
                // ウィンドウは画面外へはみ出していることがある(端に寄せた・別画面に跨る等)。
                // カーソルのある画面の枠でクランプし、見えている範囲だけをスナップ対象にする
                // (はみ出した部分まで選択枠が伸びる UX 問題の対策)。
                let screen = NSScreen.screens.first(where: { NSPointInRect(cursor, $0.frame) }) ?? NSScreen.main
                if let sf = screen?.frame {
                    let clamped = nsRect.intersection(sf)
                    if clamped.width > 20, clamped.height > 20 { return clamped }
                }
                return nsRect
            }
        }
        return nil
    }

}

// MARK: - RegionView

private final class RegionView: NSView {
    weak var overlayWindow: RegionOverlayWindow?
    var frozenImage: CGImage?
    private var dashPhase: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The panel is key while the overlay is up; the local monitor consumes the keys
    // we care about (ESC/Enter/Space/arrows). Swallow the rest to avoid system beeps.
    override func keyDown(with event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        let pt = convertToScreen(event.locationInWindow)
        if event.clickCount == 2 {
            overlayWindow?.doubleClick(at: pt)
        } else {
            overlayWindow?.mouseDown(at: pt, shiftHeld: event.modifierFlags.contains(.shift))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convertToScreen(event.locationInWindow)
        overlayWindow?.mouseDragged(to: pt, shiftHeld: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convertToScreen(event.locationInWindow)
        overlayWindow?.mouseUp(at: pt)
    }

    private func convertToScreen(_ windowPoint: NSPoint) -> NSPoint {
        guard let win = window else { return windowPoint }
        let f = win.frame
        return NSPoint(x: f.minX + windowPoint.x, y: f.minY + windowPoint.y)
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
            owner: self, userInfo: nil
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let ow = overlayWindow else { return }

        // Advance dash phase for marching ants
        dashPhase -= 1.2

        // Draw frozen screenshot as background (screen freeze effect)
        if let img = frozenImage {
            ctx.draw(img, in: bounds)
        }

        // Build dark overlay: full bounds minus selection hole (even-odd clipping)
        let localSel: CGRect
        let hasSelection: Bool
        if ow.selectionRect.width > 0 && ow.selectionRect.height > 0, let win = window {
            let screenOrigin = win.frame.origin
            localSel = CGRect(
                x: ow.selectionRect.minX - screenOrigin.x,
                y: ow.selectionRect.minY - screenOrigin.y,
                width: ow.selectionRect.width,
                height: ow.selectionRect.height
            )
            hasSelection = !localSel.intersection(bounds).isNull
        } else {
            localSel = .zero
            hasSelection = false
        }

        ctx.saveGState()
        if hasSelection {
            ctx.addRect(bounds)
            ctx.addRect(localSel)
            ctx.clip(using: .evenOdd)
        }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()

        // Crosshair lines: extend full-screen from cursor (idle or dragging states)
        if !ow.isAdjusting, let win = window {
            let screenOrigin = win.frame.origin
            let localCursor = CGPoint(
                x: ow.cursorScreenPoint.x - screenOrigin.x,
                y: ow.cursorScreenPoint.y - screenOrigin.y
            )
            if bounds.contains(localCursor) {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
                ctx.setLineWidth(0.5)
                // Horizontal line
                ctx.move(to: CGPoint(x: 0, y: localCursor.y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: localCursor.y))
                // Vertical line
                ctx.move(to: CGPoint(x: localCursor.x, y: 0))
                ctx.addLine(to: CGPoint(x: localCursor.x, y: bounds.height))
                ctx.strokePath()
            }
        }

        // Draw selection decorations
        if hasSelection {
            let clipped = localSel.intersection(bounds)
            if !clipped.isNull {
                // Subtle bright tint on selection
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.04).cgColor)
                ctx.fill(clipped)

                // Marching ants border with brief "pop" glow when transitioning to adjusting
                let insetSel = localSel
                let pulseAge = CFAbsoluteTimeGetCurrent() - ow.selectionConfirmedAt
                let pulse = pulseAge < 0.25 ? CGFloat(1.0 - pulseAge / 0.25) : 0.0
                ctx.saveGState()
                if pulse > 0 {
                    // Bright glow during confirmation pulse
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5 + pulse * 0.5).cgColor)
                    ctx.setLineWidth(2.5 + pulse * 1.5)
                    ctx.setLineDash(phase: 0, lengths: [])
                    ctx.stroke(insetSel.insetBy(dx: -0.5, dy: -0.5))
                }
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
                ctx.setLineWidth(1.5)
                ctx.setLineDash(phase: dashPhase, lengths: [8, 4])
                ctx.stroke(insetSel.insetBy(dx: 0.75, dy: 0.75))

                // Solid white outer border
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
                ctx.setLineWidth(0.5)
                ctx.stroke(insetSel.insetBy(dx: -0.25, dy: -0.25))
                ctx.restoreGState()

                // Rule-of-thirds grid (dashed, subtle — only visible when selection is large enough)
                if localSel.width > 60 && localSel.height > 60 {
                    ctx.saveGState()
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor)
                    ctx.setLineWidth(0.5)
                    ctx.setLineDash(phase: 0, lengths: [4, 3])
                    for i in [1, 2] {
                        let x = localSel.minX + localSel.width * CGFloat(i) / 3
                        let y = localSel.minY + localSel.height * CGFloat(i) / 3
                        ctx.move(to: CGPoint(x: x, y: localSel.minY)); ctx.addLine(to: CGPoint(x: x, y: localSel.maxY))
                        ctx.move(to: CGPoint(x: localSel.minX, y: y)); ctx.addLine(to: CGPoint(x: localSel.maxX, y: y))
                    }
                    ctx.strokePath()
                    ctx.restoreGState()
                }

                // Draw size label inside selection
                drawSizeLabel(ctx: ctx, inRect: localSel, size: ow.selectionRect.size, spaceHeld: ow.spaceHeldDuringDrag)

                // Draw resize handles when adjusting
                if ow.isAdjusting {
                    drawResizeHandles(ctx: ctx, selection: localSel)
                    drawHints(ctx: ctx, in: bounds, selection: localSel)
                } else {
                    // Dragging: hint about Space-to-reposition
                    drawBottomHint(ctx: ctx, in: bounds,
                                   text: "Space で移動  |  ⇧ 正方形  |  ↵ 確定  |  Esc キャンセル")
                }
            }
        }
        if !hasSelection && !ow.isAdjusting {
            drawBottomHint(ctx: ctx, in: bounds,
                           text: "ドラッグして範囲を選択  |  ⇧ 正方形  |  Esc キャンセル")
        }
    }

    private func drawBottomHint(ctx: CGContext, in viewBounds: CGRect, text: String) {
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.75)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        let padH: CGFloat = 12, padV: CGFloat = 5
        let margin: CGFloat = 20
        let bgRect = CGRect(
            x: (viewBounds.width - sz.width) / 2 - padH,
            y: margin,
            width: sz.width + padH * 2,
            height: sz.height + padV * 2
        )
        ctx.setShadow(offset: .zero, blur: 8, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        let path = CGPath(roundedRect: bgRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        str.draw(at: CGPoint(x: bgRect.minX + padH, y: bgRect.minY + padV))
    }

    private func drawSizeLabel(ctx: CGContext, inRect localSel: CGRect, size: CGSize, spaceHeld: Bool = false) {
        let scale = window?.screen?.backingScaleFactor ?? 2.0
        let pxW = Int(size.width * scale), pxH = Int(size.height * scale)
        let ratioSuffix: String = {
            guard pxW > 0 && pxH > 0 else { return "" }
            let g = gcd(pxW, pxH)
            let rw = pxW / g, rh = pxH / g
            let knownRatios: [(Int, Int, String)] = [
                (16, 9, "16:9"), (4, 3, "4:3"), (3, 2, "3:2"), (1, 1, "1:1"),
                (16, 10, "16:10"), (21, 9, "21:9"), (3, 4, "3:4"), (9, 16, "9:16")
            ]
            for (w, h, name) in knownRatios where rw == w && rh == h { return "  \(name)" }
            return ""
        }()
        let label = spaceHeld ? "移動中... \(pxW) × \(pxH) px" : "\(pxW) × \(pxH) px\(ratioSuffix)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: spaceHeld ? NSColor.systemYellow : NSColor.white
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let textSize = str.size()
        let padH: CGFloat = 8
        let padV: CGFloat = 5
        let margin: CGFloat = 10

        // Position: below the selection (most visible)
        var labelY = localSel.minY - textSize.height - padV * 2 - margin
        if labelY < 2 {
            // Not enough space below → inside bottom
            labelY = localSel.minY + margin
        }
        let labelBg = CGRect(
            x: localSel.midX - (textSize.width + padH * 2) / 2,
            y: labelY,
            width: textSize.width + padH * 2,
            height: textSize.height + padV * 2
        )
        // Shadow for label background
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        let bgPath = CGPath(roundedRect: labelBg, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(bgPath); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        str.draw(at: CGPoint(x: labelBg.minX + padH, y: labelBg.minY + padV))
    }

    private func drawResizeHandles(ctx: CGContext, selection: CGRect) {
        for handle in ResizeHandle.resizeHandles {
            let center = handle.point(in: selection)
            let handleSize: CGFloat = 8
            let handleRect = CGRect(
                x: center.x - handleSize / 2,
                y: center.y - handleSize / 2,
                width: handleSize, height: handleSize
            )
            // White filled circle with shadow
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: handleRect)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: handleRect)
        }
    }

    private func drawHints(ctx: CGContext, in viewBounds: CGRect, selection: CGRect) {
        // Draw keyboard hint pills: [Enter 確定] [Esc キャンセル] [↑↓←→ 微調整]
        let items: [(key: String, desc: String)] = [
            ("↵ Enter", "確定"),
            ("Esc", "やり直し"),
            ("↑↓←→", "1px"),
            ("⇧+↑↓←→", "10px"),
        ]
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let keyFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let pillPadH: CGFloat = 7, pillPadV: CGFloat = 4, pillGap: CGFloat = 6
        var totalW: CGFloat = 0
        var pillSizes: [(CGFloat, CGFloat)] = []  // (key width, desc width)
        for item in items {
            let kw = (item.key as NSString).size(withAttributes: [.font: keyFont]).width
            let dw = (item.desc as NSString).size(withAttributes: [.font: font]).width
            pillSizes.append((kw, dw))
            totalW += kw + dw + 8 + pillPadH * 2  // key+gap+desc+padding
            totalW += pillGap
        }
        totalW -= pillGap
        let pillH: CGFloat = font.ascender - font.descender + pillPadV * 2
        let margin: CGFloat = 14
        var startX = viewBounds.midX - totalW / 2
        // Position below or above selection
        var y = selection.minY - pillH - margin - 26  // above size label
        if y < viewBounds.minY + margin { y = selection.maxY + margin + 26 }

        for (i, item) in items.enumerated() {
            let (kw, dw) = pillSizes[i]
            let pillW = kw + dw + 8 + pillPadH * 2
            let pillRect = CGRect(x: startX, y: y, width: pillW, height: pillH)
            // Background
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillH/2, cornerHeight: pillH/2, transform: nil))
            ctx.fillPath()
            // Key text (slightly brighter)
            let keyAttrs: [NSAttributedString.Key: Any] = [
                .font: keyFont,
                .foregroundColor: NSColor.white
            ]
            (item.key as NSString).draw(at: CGPoint(x: startX + pillPadH, y: y + pillPadV), withAttributes: keyAttrs)
            // Desc text (dimmer)
            let descAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.65)
            ]
            (item.desc as NSString).draw(at: CGPoint(x: startX + pillPadH + kw + 5, y: y + pillPadV), withAttributes: descAttrs)
            startX += pillW + pillGap
        }
    }
}

// MARK: - Expose isAdjusting for RegionView

extension RegionOverlayWindow {
    var isAdjusting: Bool { captureState == .adjusting }
}

// MARK: - Window snap border visual

private final class WindowSnapView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = false }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.10).cgColor)
        ctx.fill(bounds)
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(2.5)
        ctx.stroke(bounds.insetBy(dx: 1.25, dy: 1.25))
        let hint = "クリックまたはSpaceで撮影"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: hint, attributes: attrs)
        let sz = str.size()
        let pad: CGFloat = 6
        let bgRect = CGRect(
            x: (bounds.width - sz.width) / 2 - pad,
            y: bounds.height - sz.height - pad * 2 - 4,
            width: sz.width + pad * 2,
            height: sz.height + pad
        )
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        str.draw(at: CGPoint(x: bgRect.minX + pad, y: bgRect.minY + pad / 2))
    }
}

private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
