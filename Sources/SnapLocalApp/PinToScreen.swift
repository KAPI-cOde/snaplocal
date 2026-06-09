// PinToScreen.swift
// Floating screenshot windows that stay above all apps.

import AppKit
import AudioToolbox
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

    var hasPinnedWindows: Bool { !windows.isEmpty }

    func closeAll() {
        let toClose = windows
        windows.removeAll()
        toClose.forEach { $0.close() }
    }
}

// MARK: - PinnedImageWindow

@MainActor
final class PinnedImageWindow: NSObject {
    var onClose: (() -> Void)?
    private var panel: NSPanel?
    private let cgImage: CGImage

    init(image: CGImage) {
        self.cgImage = image
        super.init()

        let maxDim: CGFloat = 680
        let scale = min(maxDim / CGFloat(image.width), maxDim / CGFloat(image.height), 1.0)
        let w = CGFloat(image.width) * scale
        let h = CGFloat(image.height) * scale

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let view = PinnedContentView(image: nsImage, onClose: { [weak self] in self?.close() },
                                      onCopy: { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([nsImage]) })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        p.center()
        self.panel = p
        p.delegate = self
    }

    func show() {
        panel?.orderFrontRegardless()
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
        onClose?()
    }
}

extension PinnedImageWindow: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in onClose?() }
    }
}

// MARK: - PinnedContentView (SwiftUI)

private struct PinnedContentView: View {
    let image: NSImage
    let onClose: () -> Void
    let onCopy: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)

            // Close button (appears on hover)
            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("コピー") { onCopy() }
            Divider()
            Button("閉じる") { onClose() }
        }
    }
}

// MARK: - Camera Flash Effect

@MainActor
final class CameraFlash {
    static let shared = CameraFlash()
    private var windows: [NSWindow] = []
    private init() {}

    func flash() {
        AudioServicesPlaySystemSound(1108)
        // Create a white borderless panel covering each screen
        let newWindows: [NSWindow] = NSScreen.screens.map { screen in
            let win = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelKey.screenSaverWindow.rawValue) + 1)
            win.isOpaque = true
            win.backgroundColor = .white
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.alphaValue = 0
            win.orderFrontRegardless()
            return win
        }
        windows = newWindows

        // Flash in then out
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.05
            newWindows.forEach { $0.animator().alphaValue = 0.85 }
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                newWindows.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: {
                newWindows.forEach { $0.orderOut(nil) }
            })
        })
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
