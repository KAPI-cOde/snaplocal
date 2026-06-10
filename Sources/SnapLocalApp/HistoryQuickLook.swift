// HistoryQuickLook.swift
// SnapLocal – History Quick Look Panel (Space key preview)

import SwiftUI
import AppKit

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
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                .padding(DS.Space.m)
                .onTapGesture { onDismiss() }
            HStack(spacing: DS.Space.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = item.title {
                        Text(title)
                            .font(.system(size: DS.FontSize.caption, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    HStack(spacing: DS.Space.xs) {
                        if item.width > 0 {
                            Text("\(item.width) × \(item.height)")
                                .font(.system(size: DS.FontSize.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: DS.FontSize.caption))
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
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.s)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.large).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }
}
