// PinToScreen.swift
// Floating screenshot windows that stay above all apps.

import AppKit
import AudioToolbox
import SwiftUI

// MARK: - Scroll Wheel modifier

private struct ScrollWheelModifier: ViewModifier {
    let handler: (CGPoint) -> Void
    func body(content: Content) -> some View {
        content.background(ScrollWheelCapture(handler: handler))
    }
}

private struct ScrollWheelCapture: NSViewRepresentable {
    let handler: (CGPoint) -> Void
    func makeNSView(context: Context) -> ScrollWheelView {
        let v = ScrollWheelView(); v.handler = handler; return v
    }
    func updateNSView(_ v: ScrollWheelView, context: Context) { v.handler = handler }
}

private class ScrollWheelView: NSView {
    var handler: ((CGPoint) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func scrollWheel(with event: NSEvent) {
        handler?(CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
    }
}

extension View {
    func onScrollWheel(_ handler: @escaping (CGPoint) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}

extension CGFloat {
    func clampedTo(min lo: CGFloat, max hi: CGFloat) -> CGFloat { Swift.min(hi, Swift.max(lo, self)) }
}

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
    private var currentW: CGFloat = 0
    private var currentH: CGFloat = 0
    private let minDim: CGFloat = 80
    private let maxDim: CGFloat = 1600

    init(image: CGImage) {
        self.cgImage = image
        super.init()

        let initialMax: CGFloat = 680
        let scale = min(initialMax / CGFloat(image.width), initialMax / CGFloat(image.height), 1.0)
        let w = CGFloat(image.width) * scale
        let h = CGFloat(image.height) * scale
        currentW = w; currentH = h
        let aspectRatio = w / max(h, 1)

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
        let view = PinnedContentView(
            image: nsImage,
            onClose: { [weak self] in self?.close() },
            onCopy: { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([nsImage]) },
            onScale: { [weak self] factor in
                guard let self, let p = self.panel else { return }
                let newW = (self.currentW * factor).clampedTo(min: self.minDim, max: self.maxDim)
                let newH = newW / aspectRatio
                let center = CGPoint(x: p.frame.midX, y: p.frame.midY)
                let newOrigin = CGPoint(x: center.x - newW / 2, y: center.y - newH / 2)
                p.setFrame(NSRect(x: newOrigin.x, y: newOrigin.y, width: newW, height: newH), display: true, animate: false)
                self.currentW = newW; self.currentH = newH
            }
        )
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
    var onScale: ((CGFloat) -> Void)? = nil   // called with new scale multiplier
    @State private var isHovering = false
    @State private var opacity: Double = 1.0

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

            // Opacity indicator badge (when opacity < 1)
            if opacity < 0.95 && isHovering {
                Text("\(Int(opacity * 100))%")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

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
        .opacity(opacity)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .gesture(
            MagnifyGesture()
                .onChanged { v in onScale?(v.magnification) }
        )
        .onScrollWheel { delta in
            if NSEvent.modifierFlags.contains(.option) {
                // ⌥+scroll: change opacity
                let newOpacity = min(1.0, max(0.1, opacity - delta.y * 0.05))
                withAnimation(.easeOut(duration: 0.1)) { opacity = newOpacity }
            } else {
                // scroll: resize window
                let scale = 1.0 + delta.y * -0.04
                onScale?(scale)
            }
        }
        .contextMenu {
            Button("コピー") { onCopy() }
            Divider()
            Button("不透明度 100%") { withAnimation { opacity = 1.0 } }
            Button("不透明度 75%")  { withAnimation { opacity = 0.75 } }
            Button("不透明度 50%")  { withAnimation { opacity = 0.5 } }
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
