// PinToScreen.swift
// Floating screenshot windows that stay above all apps.

import AppKit
import SwiftUI

// MARK: - PinManager

@MainActor
final class PinManager {
    static let shared = PinManager()
    private var windows: [PinnedImageWindow] = []
    private init() {}

    func pin(image: CGImage) {
        let win = PinnedImageWindow(image: image)
        win.onClose = { [weak self, weak win] in
            guard let win else { return }
            self?.windows.removeAll { $0 === win }
        }
        win.show()
        windows.append(win)
    }
}

// MARK: - PinnedImageWindow

@MainActor
final class PinnedImageWindow: NSObject {
    var onClose: (() -> Void)?
    private var window: NSWindow?

    init(image: CGImage) {
        super.init()
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let maxDim: CGFloat = 600
        let scale = min(maxDim / CGFloat(image.width), maxDim / CGFloat(image.height), 1.0)
        let w = CGFloat(image.width) * scale
        let h = CGFloat(image.height) * scale

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h + 28),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "SnapLocal — ピン留め"
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(white: 0.12, alpha: 1)

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        imageView.image = nsImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.addSubview(imageView)
        container.autoresizingMask = [.width, .height]
        win.contentView = container

        win.center()
        win.setFrameAutosaveName("")
        self.window = win
        win.delegate = self
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }
}

extension PinnedImageWindow: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in onClose?() }
    }
}

// MARK: - Countdown Overlay

@MainActor
final class CountdownOverlay {
    static let shared = CountdownOverlay()
    private var window: NSWindow?
    private var label: NSTextField?
    private init() {}

    func show(count: Int) {
        if window == nil { setup() }
        label?.stringValue = "\(count)"
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func setup() {
        let size: CGFloat = 160
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - size / 2
        let y = screen.frame.midY - size / 2
        let win = NSWindow(
            contentRect: NSRect(x: x, y: y, width: size, height: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelKey.floatingWindow.rawValue) + 100)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = size / 2
        bg.layer?.masksToBounds = true
        container.addSubview(bg)

        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: size, height: size))
        tf.isEditable = false
        tf.isBordered = false
        tf.backgroundColor = .clear
        tf.alignment = .center
        tf.font = NSFont.boldSystemFont(ofSize: 72)
        tf.textColor = .labelColor
        container.addSubview(tf)

        win.contentView = container
        win.center()
        self.window = win
        self.label = tf
    }
}
