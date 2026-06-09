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
    private var isHovered = false

    private init() {}

    func show(image: CGImage, actions: CaptureNotificationActions, onScreen: NSScreen? = nil) {
        dismiss(animated: false)

        let view = CaptureNotificationView(
            image: image,
            actions: actions,
            onDismiss: { [weak self] in self?.dismiss(animated: true) },
            onHoverChanged: { [weak self] hovering in self?.handleHoverChange(hovering) }
        )
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
        isHovered = false
        scheduleDismiss()
    }

    func dismiss(animated: Bool = true) {
        dismissTimer?.cancel()
        dismissTimer = nil
        isHovered = false
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

    // Pause dismiss timer while HUD is hovered; resume with full 4s when mouse leaves
    func handleHoverChange(_ hovering: Bool) {
        isHovered = hovering
        if hovering {
            dismissTimer?.cancel()
            dismissTimer = nil
        } else {
            scheduleDismiss(delay: 4)
        }
    }

    private func positionPanel(_ p: NSPanel, on preferredScreen: NSScreen? = nil) {
        let screen = preferredScreen ?? NSScreen.screens.first(where: { $0 == NSScreen.main }) ?? NSScreen.screens[0]
        let margin: CGFloat = 24
        let x = screen.visibleFrame.maxX - p.frame.width - margin
        let y = screen.visibleFrame.minY + margin
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func scheduleDismiss(delay: Double = 5) {
        dismissTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard self?.isHovered == false else { return }
            self?.dismiss(animated: true)
        }
        dismissTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

// MARK: - SwiftUI View

struct CaptureNotificationView: View {
    let image: CGImage
    let actions: CaptureNotificationActions
    let onDismiss: () -> Void
    var onHoverChanged: ((Bool) -> Void)? = nil

    @State private var isHUDHovered = false
    @State private var thumbnailHovered = false
    @State private var isDragging = false
    @State private var copiedFeedback = false
    // Time-based progress tracking (avoids SwiftUI animation state bug)
    @State private var lastResumeTime: Date = .now
    @State private var pausedElapsed: Double = 0
    @State private var isProgressPaused: Bool = false
    private let hudDuration: Double = 5.0

    private var aspectRatio: CGFloat {
        guard image.height > 0 else { return 1 }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    private var thumbWidth: CGFloat { min(80, max(48, 52 * aspectRatio)) }
    private var nsImage: NSImage { NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail — click to open editor, drag to other apps
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbWidth, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isDragging ? Color.green.opacity(0.8)
                                : thumbnailHovered ? Color.accentColor.opacity(0.8)
                                : Color.white.opacity(0.15),
                                lineWidth: (thumbnailHovered || isDragging) ? 1.5 : 0.5)
                )
                .overlay(alignment: .bottom) {
                    if thumbnailHovered && !isDragging {
                        HStack(spacing: 3) {
                            Image(systemName: "pencil")
                                .font(.system(size: 7))
                            Text("編集")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(.bottom, 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if thumbnailHovered && !isDragging {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(3)
                            .background(.black.opacity(0.4), in: Circle())
                            .padding(3)
                    }
                }
                .scaleEffect(isDragging ? 0.92 : (thumbnailHovered ? 1.03 : 1.0))
                .animation(.easeInOut(duration: 0.15), value: thumbnailHovered)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .onTapGesture { actions.annotate(); onDismiss() }
                .onDrag {
                    isDragging = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isDragging = false }
                    return NSItemProvider(object: nsImage)
                }
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
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { tl in
                let elapsed = isProgressPaused
                    ? pausedElapsed
                    : pausedElapsed + tl.date.timeIntervalSince(lastResumeTime)
                let progress = max(0, CGFloat(1.0 - elapsed / hudDuration))
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(isHUDHovered ? 0.25 : 0.5))
                        .frame(width: geo.size.width * progress, height: 2.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 2.5)
                .padding(.horizontal, 14)
                .padding(.bottom, 3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isHUDHovered ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .onHover { hovering in
            isHUDHovered = hovering
            onHoverChanged?(hovering)
            if hovering {
                isProgressPaused = true
                pausedElapsed += Date.now.timeIntervalSince(lastResumeTime)
            } else {
                isProgressPaused = false
                lastResumeTime = .now
            }
        }
        .onAppear {
            lastResumeTime = .now
            pausedElapsed = 0
            isProgressPaused = false
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

// MARK: - History Quick Look Panel (Space key preview)

@MainActor
final class HistoryQuickLook {
    static let shared = HistoryQuickLook()
    private var panel: NSPanel?
    private init() {}

    func show(item: VaultItem) {
        dismiss(animated: false)
        guard let nsImage = NSImage(contentsOf: item.imageURL) else { return }
        let imgW = CGFloat(item.width > 0 ? item.width : Int(nsImage.size.width))
        let imgH = CGFloat(item.height > 0 ? item.height : Int(nsImage.size.height))
        guard imgW > 0, imgH > 0 else { return }

        let maxW: CGFloat = 640, maxH: CGFloat = 520
        let scale = min(maxW / imgW, maxH / imgH, 1.0)
        let panelW = max(imgW * scale + 32, 200)
        let panelH = imgH * scale + 72

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let view = HistoryQuickLookView(image: nsImage, item: item, onDismiss: { [weak self] in self?.dismiss() })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: panelW, height: panelH)
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        if let screen = NSScreen.main {
            let sx = screen.visibleFrame.midX - panelW / 2
            let sy = screen.visibleFrame.midY - panelH / 2
            p.setFrameOrigin(NSPoint(x: sx, y: sy))
        }

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
        panel = p
    }

    func dismiss(animated: Bool = true) {
        guard let p = panel else { return }
        panel = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        } else {
            p.orderOut(nil)
        }
    }
}

private struct HistoryQuickLookView: View {
    let image: NSImage
    let item: VaultItem
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                .padding(16)
                .onTapGesture { onDismiss() }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = item.title {
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if item.width > 0 {
                            Text("\(item.width) × \(item.height)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }
}
