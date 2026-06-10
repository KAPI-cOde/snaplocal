// CanvasHelpers.swift
// SnapLocal - Canvas-only helper types (extracted from CanvasView.swift — mechanical move only)

import SwiftUI
import AppKit
import CoreGraphics

// MARK: - Zoom Notification Handler

struct ZoomNotificationHandler: ViewModifier {
    @Binding var zoom: CGFloat
    @Binding var baseZoom: CGFloat
    @Binding var panOffset: CGSize
    @Binding var basePan: CGSize
    @Binding var userZoomed: Bool
    let canvasSize: CGSize
    let imageSize: CGSize?

    // zoom はscaledToFit済みベースへの倍率なので、フィット = 1.0。
    // 実寸(画像1px = 画面1デバイスpx)は 1/(backingScale × fitScale)
    private var fitScale: CGFloat {
        guard let sz = imageSize, sz.width > 0, sz.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        return min(canvasSize.width / sz.width, canvasSize.height / sz.height)
    }
    private var naturalZoom: CGFloat {
        (1.0 / (NSScreen.main?.backingScaleFactor ?? 2.0)) / fitScale
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .snapLocalZoomIn)) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    zoom = min(8.0, zoom * 1.25); baseZoom = zoom; userZoomed = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .snapLocalZoomOut)) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    zoom = max(0.25, zoom / 1.25); baseZoom = zoom; userZoomed = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .snapLocalZoomReset)) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    zoom = max(0.25, min(8.0, naturalZoom)); baseZoom = zoom
                    panOffset = .zero; basePan = .zero; userZoomed = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .snapLocalZoomFit)) { _ in
                guard imageSize != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    zoom = 1.0; baseZoom = 1.0
                    panOffset = .zero; basePan = .zero; userZoomed = true
                }
            }
    }
}

// MARK: - Scroll Wheel Zoom/Pan Helper

struct ScrollWheelHandler: NSViewRepresentable {
    // dx, dy, isCommandDown, cursorInView (nil if not cmd)
    let onScroll: (CGFloat, CGFloat, Bool, CGPoint?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollableNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollableNSView)?.onScroll = onScroll
    }

    class ScrollableNSView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool, CGPoint?) -> Void)?

        override var acceptsFirstResponder: Bool { false }

        override func scrollWheel(with event: NSEvent) {
            let cmd = event.modifierFlags.contains(.command)
            let cursor: CGPoint? = cmd ? convert(event.locationInWindow, from: nil) : nil
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, cmd, cursor)
            if !cmd { super.scrollWheel(with: event) }
        }
    }
}


// MARK: - Multiline text input (NSTextView wrapper)
// Supports Return=commit, Shift/Option+Return=newline, Escape=cancel
struct MultilineTextInput: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var color: NSColor
    var minWidth: CGFloat
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onHeightChange: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NonScrollingTextView()
        tv.delegate = context.coordinator
        tv.isEditable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.autoresizingMask = [.width]
        tv.onHeightChange = onHeightChange

        let sv = NSScrollView()
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.documentView = tv
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NonScrollingTextView else { return }
        context.coordinator.isUpdating = true
        if tv.string != text { tv.string = text }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        tv.font = font
        tv.textColor = color
        context.coordinator.isUpdating = false
        // Become first responder on first appearance
        if !context.coordinator.didBecomeFirstResponder {
            context.coordinator.didBecomeFirstResponder = true
            DispatchQueue.main.async { sv.window?.makeFirstResponder(tv) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel, onHeightChange: onHeightChange)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onCommit: () -> Void
        let onCancel: () -> Void
        let onHeightChange: ((CGFloat) -> Void)?
        var isUpdating = false
        var didBecomeFirstResponder = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void, onHeightChange: ((CGFloat) -> Void)?) {
            _text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
            self.onHeightChange = onHeightChange
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                if mods.contains(.shift) || mods.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    text = textView.string
                    return true
                }
                onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
        }
    }
}

class NonScrollingTextView: NSTextView {
    var onHeightChange: ((CGFloat) -> Void)?

    override func didChangeText() {
        super.didChangeText()
        sizeToFit()
        let h = frame.height
        onHeightChange?(h + 8)
    }
}

struct HintRow: View {
    let key: String
    let label: String
    var body: some View {
        GridRow {
            Text(key)
                .font(.system(size: DS.FontSize.caption, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.xs)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 0.5, y: 1)
                .gridColumnAlignment(.trailing)
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
        }
    }
}

// MARK: - Diagonal resize cursor

private func makeDiagonalCursor(nwse: Bool) -> NSCursor {
    let size: CGFloat = 16
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    for (color, lineWidth) in [(NSColor.white.cgColor, CGFloat(3.0)), (NSColor.black.cgColor, CGFloat(1.5))] {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
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
    }
    img.unlockFocus()
    return NSCursor(image: img, hotSpot: NSPoint(x: size / 2, y: size / 2))
}

@MainActor let cursorNWSE = makeDiagonalCursor(nwse: true)
@MainActor let cursorNESW = makeDiagonalCursor(nwse: false)
