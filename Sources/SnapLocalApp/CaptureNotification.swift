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

    func show(image: CGImage, actions: CaptureNotificationActions, onScreen: NSScreen? = nil) {
        dismiss(animated: false)

        let view = CaptureNotificationView(image: image, actions: actions) { [weak self] in
            self?.dismiss(animated: true)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
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
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 80)

        positionPanel(newPanel, on: onScreen)
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()

        // Slide in from bottom-right
        let finalFrame = newPanel.frame
        newPanel.setFrameOrigin(NSPoint(x: finalFrame.minX + 20, y: finalFrame.minY - 20))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrame(finalFrame, display: true)
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

    private func positionPanel(_ p: NSPanel, on preferredScreen: NSScreen? = nil) {
        let screen = preferredScreen ?? NSScreen.screens.first(where: { $0 == NSScreen.main }) ?? NSScreen.screens[0]
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

    @State private var timerProgress: CGFloat = 1.0
    @State private var thumbnailHovered = false
    @State private var copiedFeedback = false

    private var aspectRatio: CGFloat {
        guard image.height > 0 else { return 1 }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    private var thumbWidth: CGFloat { min(80, max(48, 52 * aspectRatio)) }

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail — click to open editor
            Button {
                actions.annotate(); onDismiss()
            } label: {
                Image(nsImage: NSImage(cgImage: image,
                                       size: NSSize(width: image.width, height: image.height)))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbWidth, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(thumbnailHovered ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.15),
                                    lineWidth: thumbnailHovered ? 1.5 : 0.5)
                    )
                    .overlay(alignment: .bottom) {
                        if thumbnailHovered {
                            Text("編集")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .padding(.bottom, 3)
                        }
                    }
                    .scaleEffect(thumbnailHovered ? 1.03 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: thumbnailHovered)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .onHover { thumbnailHovered = $0 }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("撮影しました")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("\(image.width) × \(image.height)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 3) {
                    copyActionBtn
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
        .frame(width: 320, height: 80)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: geo.size.width * timerProgress, height: 2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 2.5)
            .padding(.horizontal, 14)
            .padding(.bottom, 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .onAppear {
            withAnimation(.linear(duration: 5)) {
                timerProgress = 0
            }
        }
    }

    @ViewBuilder
    private var copyActionBtn: some View {
        Button {
            actions.copy()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { copiedFeedback = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { onDismiss() }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: copiedFeedback ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 12))
                    .foregroundStyle(copiedFeedback ? Color.green : Color.primary)
                Text(copiedFeedback ? "完了" : "コピー")
                    .font(.system(size: 8))
                    .foregroundStyle(copiedFeedback ? Color.green : Color.primary)
            }
            .frame(width: 40, height: 32)
            .background(copiedFeedback ? Color.green.opacity(0.12) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7))
            .scaleEffect(copiedFeedback ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionBtn(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 8))
            }
            .foregroundStyle(.primary)
            .frame(width: 40, height: 32)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}
