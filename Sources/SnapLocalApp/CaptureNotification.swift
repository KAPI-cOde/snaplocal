// CaptureNotification.swift
// SnapLocal – Post-capture floating HUD (CleanShot X-style)

import SwiftUI
import AppKit

// MARK: - Actions passed into the notification

struct CaptureNotificationActions {
    let copy: () -> Void
    let save: () -> Void
    let annotate: () -> Void
    let pin: () -> Void
    let share: () -> Void
}

// MARK: - Floating panel

@MainActor
final class CaptureNotificationWindow {
    static let shared = CaptureNotificationWindow()

    private var panel: NSPanel?
    private var dismissTimer: DispatchWorkItem?

    private init() {}

    func show(image: CGImage, actions: CaptureNotificationActions) {
        dismiss(animated: false)

        let view = CaptureNotificationView(image: image, actions: actions) { [weak self] in
            self?.dismiss(animated: true)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 76),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.isMovableByWindowBackground = true
        newPanel.contentView = hosting

        // Fit panel to hosting view's intrinsic size
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 76)

        positionPanel(newPanel)
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()

        // Animate in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            newPanel.animator().alphaValue = 1
        }

        panel = newPanel
        scheduleDismiss()
    }

    func dismiss(animated: Bool = true) {
        dismissTimer?.cancel()
        dismissTimer = nil
        guard let p = panel else { return }
        panel = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        } else {
            p.orderOut(nil)
        }
    }

    private func positionPanel(_ p: NSPanel) {
        let screen = NSScreen.screens.first(where: { $0 == NSScreen.main }) ?? NSScreen.screens[0]
        let margin: CGFloat = 24
        let x = screen.visibleFrame.maxX - p.frame.width - margin
        let y = screen.visibleFrame.minY + margin
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func scheduleDismiss() {
        let item = DispatchWorkItem { [weak self] in
            self?.dismiss(animated: true)
        }
        dismissTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }
}

// MARK: - SwiftUI View

struct CaptureNotificationView: View {
    let image: CGImage
    let actions: CaptureNotificationActions
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail
            Image(nsImage: NSImage(cgImage: image,
                                   size: NSSize(width: image.width, height: image.height)))
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 60, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text("撮影しました")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 2) {
                    actionBtn("doc.on.clipboard", label: "コピー") {
                        actions.copy(); onDismiss()
                    }
                    actionBtn("square.and.arrow.down", label: "保存") {
                        actions.save(); onDismiss()
                    }
                    actionBtn("pencil.and.outline", label: "注釈") {
                        actions.annotate(); onDismiss()
                    }
                    actionBtn("pin", label: "ピン") {
                        actions.pin(); onDismiss()
                    }
                    actionBtn("square.and.arrow.up", label: "共有") {
                        actions.share(); onDismiss()
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 300, height: 76)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func actionBtn(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 8))
            }
            .foregroundStyle(.primary)
            .frame(width: 42, height: 30)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
