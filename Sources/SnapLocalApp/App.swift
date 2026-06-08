// App.swift
// SnapLocal - App Entry Point

import SwiftUI
import CoreGraphics
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.snaplocal.app", category: "App")

@main
struct SnapLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                // Remove default settings menu
            }
        }
    }
}

// AppDelegate to ensure window is properly configured and in foreground
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        logger.debug("applicationWillFinishLaunching called")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.debug("applicationDidFinishLaunching called")
        // Make sure the app is in the foreground
        NSApp.activate(ignoringOtherApps: true)
        
        // Ensure main window appears on screen with proper level
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let mainWindow = NSApplication.shared.mainWindow {
                mainWindow.level = .floating
                mainWindow.makeKeyAndOrderFront(nil)
                mainWindow.orderFrontRegardless()
                logger.debug("Main window configured: \\(mainWindow)")
            } else {
                logger.warning("Main window not yet available")
                // Try again in next run loop
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let mainWindow = NSApplication.shared.mainWindow {
                        mainWindow.level = .floating
                        mainWindow.makeKeyAndOrderFront(nil)
                        mainWindow.orderFrontRegardless()
                        logger.debug("Main window configured (retry): \\(mainWindow)")
                    }
                }
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
@MainActor
final class SnapLocalState: ObservableObject, @unchecked Sendable {
    @Published var statusMessage = ""
    @Published var statusVisible = false
    @Published var history: [VaultItem] = []

    var canvas = CanvasViewModel()
    private let vault = TempVault()
    private var captureEngine: CaptureEngine?
    private var statusTask: Task<Void, Never>?

    init() {
        let hotkey = SettingsManager.shared.hotkeyConfig
        captureEngine = CaptureEngine(hotkey: hotkey) { [weak self] result in
            Task { @MainActor in
                self?.handleCaptureResult(result)
            }
        }
        captureEngine?.registerHotkey()
        refreshHistory()
    }

    func showStatus(_ message: String) {
        statusTask?.cancel()
        statusMessage = message
        statusVisible = true
        statusTask = Task {
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                statusVisible = false
            } catch {}
        }
    }

    func captureNow() {
        showStatus("撮影中…")
        captureEngine?.captureScreen()
    }

    func acceptCapture(_ image: CGImage) {
        canvas.backgroundImage = image
        canvas.canvasSize = CGSize(width: image.width, height: image.height)
        canvas.annotations.removeAll()
        showStatus("撮影しました")
        Task {
            _ = await vault.saveToMemory(image: image)
            await loadHistory()
        }
    }

    func handleCaptureResult(_ result: Result<CGImage, Error>) {
        switch result {
        case .success(let image):
            acceptCapture(image)
        case .failure(let error):
            showStatus(Self.captureFailureMessage(for: error))
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func captureFailureMessage(for error: Error) -> String {
        if case CaptureError.permissionDenied = error {
            return "画面録画権限が必要です"
        }
        let nsError = error as NSError
        return "撮影失敗: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    func loadHistoryItem(_ item: VaultItem) {
        guard let nsImage = NSImage(data: item.imageData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        canvas.resetAndLoad(image: cgImage, annotations: item.annotations)
        showStatus("履歴を読み込みました")
    }

    func saveAnnotatedImage() {
        guard let image = canvas.renderAnnotations(),
              let data = pngData(from: image) else {
            showStatus("保存できる画像がありません")
            return
        }

        do {
            let directory = SettingsManager.shared.saveDirectoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = directory.appendingPathComponent("SnapLocal-\(formatter.string(from: Date())).png")
            try data.write(to: url, options: .atomic)
            showStatus("保存しました")
            Task {
                if let rendered = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    _ = await vault.saveToMemory(image: rendered, annotations: canvas.annotations)
                    await loadHistory()
                }
            }
        } catch {
            showStatus("保存失敗: \(error.localizedDescription)")
        }
    }

    func refreshHistory() {
        Task { await loadHistory() }
    }

    private func loadHistory() async {
        let items = await vault.allItems()
        history = items
    }

    private func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

// MARK: - Compact Toolbar

struct CompactToolbar: View {
    @ObservedObject var canvas: CanvasViewModel
    let onCapture: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCapture) {
                Image(systemName: "camera.viewfinder")
            }
            .help("撮影 (⌘⇧2)")
            .keyboardShortcut("2", modifiers: [.command, .shift])

            Button(action: onSave) {
                Image(systemName: "square.and.arrow.down")
            }
            .help("保存")
            .disabled(canvas.backgroundImage == nil)

            Divider().frame(height: 18)

            Picker("", selection: $canvas.currentTool) {
                ForEach(DrawingTool.allCases, id: \.self) { tool in
                    Image(systemName: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 264)

            Divider().frame(height: 18)

            ForEach(AnnotationColor.allCases, id: \.self) { color in
                Button(action: { canvas.currentColor = color }) {
                    ZStack {
                        Circle()
                            .fill(color.color)
                            .frame(width: 14, height: 14)
                        if canvas.currentColor == color {
                            Circle()
                                .stroke(Color.primary.opacity(0.75), lineWidth: 2)
                                .frame(width: 19, height: 19)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
                .help(color.rawValue)
            }

            Divider().frame(height: 18)

            Picker("", selection: $canvas.currentLineWidth) {
                Text("S").tag(LineWidth.thin)
                Text("L").tag(LineWidth.thick)
            }
            .pickerStyle(.segmented)
            .frame(width: 52)

            Spacer()

            Button(action: { canvas.undo() }) {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!canvas.canUndo)
            .help("元に戻す (⌘Z)")
            .keyboardShortcut("z", modifiers: .command)

            Button(action: { canvas.redo() }) {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!canvas.canRedo)
            .help("やり直し (⌘⇧Z)")
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Button(action: { canvas.deleteSelectedAnnotation() }) {
                Image(systemName: "trash")
            }
            .disabled(canvas.selectedAnnotationID == nil)
            .help("削除 (⌫)")
            .keyboardShortcut(.delete, modifiers: [])
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: - History Rail

struct HistoryRail: View {
    let history: [VaultItem]
    let onSelect: (VaultItem) -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(history) { item in
                        Button(action: { onSelect(item) }) {
                            Group {
                                if let nsImage = NSImage(data: item.thumbnailData) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: item.level.systemImage)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 58, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .frame(width: 74)
        .background(.regularMaterial)
    }
}

// MARK: - Status Chip

struct StatusChip: View {
    let message: String
    let visible: Bool

    var body: some View {
        if visible {
            Text(message)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var state = SnapLocalState()

    var body: some View {
        VStack(spacing: 0) {
            CompactToolbar(
                canvas: state.canvas,
                onCapture: state.captureNow,
                onSave: state.saveAnnotatedImage
            )
            Divider()
            HStack(spacing: 0) {
                AnnotationCanvasView(
                    viewModel: state.canvas,
                    onCapture: state.captureNow,
                    onOpenPermissions: state.openScreenRecordingSettings
                )
                    .frame(minWidth: 600, minHeight: 400)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .bottom) {
                        StatusChip(message: state.statusMessage, visible: state.statusVisible)
                            .padding(.bottom, 14)
                            .animation(.easeInOut(duration: 0.2), value: state.statusVisible)
                    }

                if !state.history.isEmpty {
                    Divider()
                    HistoryRail(
                        history: state.history,
                        onSelect: state.loadHistoryItem,
                        onRefresh: state.refreshHistory
                    )
                }
            }
        }
    }
}

// MARK: - Canvas View

struct AnnotationCanvasView: View {
    @ObservedObject var viewModel: CanvasViewModel
    var onCapture: (() -> Void)? = nil
    var onOpenPermissions: (() -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = viewModel.backgroundImage {
                    Image(decorative: image, scale: 1.0, orientation: .up)
                        .resizable()
                        .scaledToFit()
                    annotationLayer(size: proxy.size)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text("撮影するとここに編集キャンバスが表示されます")
                            .foregroundStyle(.secondary)
                        if let onCapture = onCapture {
                            Button("撮影する", action: onCapture)
                                .buttonStyle(.borderedProminent)
                        }
                        if let onOpenPermissions = onOpenPermissions {
                            Button("画面録画の設定を開く", action: onOpenPermissions)
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: proxy.frame(in: .local)))
            .onAppear { viewModel.canvasSize = proxy.size }
            .onChange(of: proxy.size) { _, newSize in viewModel.canvasSize = newSize }
            .overlay(textInputOverlay)
        }
    }

    private func annotationLayer(size: CGSize) -> some View {
        Canvas { context, _ in
            let canvasRect = CGRect(origin: .zero, size: size)
            for annotation in viewModel.annotations {
                let path = annotation.path(in: canvasRect)
                if annotation.id == viewModel.selectedAnnotationID {
                    context.stroke(path, with: .color(.white), lineWidth: annotation.lineWidth.rawValue + 4)
                }
                context.stroke(path, with: .color(annotation.color.color), lineWidth: annotation.lineWidth.rawValue)
            }
            if let selectedID = viewModel.selectedAnnotationID,
               let sel = viewModel.annotations.first(where: { $0.id == selectedID }) {
                let bounds = sel.bounds(in: canvasRect).insetBy(dx: -4, dy: -4)
                context.stroke(Path(bounds), with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
            if viewModel.dragState.isDrawing,
               let start = viewModel.dragState.startPoint,
               let end = viewModel.dragState.currentPoint {
                var preview = Path()
                switch viewModel.currentTool {
                case .line, .arrow:
                    preview.move(to: start)
                    preview.addLine(to: end)
                case .rectangle, .mosaic, .blur:
                    preview = Path(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                         width: abs(end.x - start.x), height: abs(end.y - start.y)))
                case .ellipse:
                    preview = Path(ellipseIn: CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                                     width: abs(end.x - start.x), height: abs(end.y - start.y)))
                default:
                    break
                }
                context.stroke(preview, with: .color(viewModel.currentColor.color.opacity(0.6)),
                               style: StrokeStyle(lineWidth: viewModel.currentLineWidth.rawValue, dash: [4, 2]))
            }
        }
    }

    private func dragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if viewModel.dragState.isDrawing {
                    viewModel.handleDragUpdate(at: value.location, in: rect)
                } else {
                    viewModel.handleDragStart(at: value.location, in: rect)
                }
            }
            .onEnded { value in
                viewModel.handleDragEnd(at: value.location, in: rect)
            }
    }

    @ViewBuilder
    private var textInputOverlay: some View {
        if viewModel.showTextInput {
            TextField("テキスト", text: $viewModel.textInputString)
                .textFieldStyle(.roundedBorder)
                .frame(width: viewModel.textInputRect.width)
                .position(x: viewModel.textInputRect.midX, y: viewModel.textInputRect.midY)
                .onSubmit { viewModel.confirmTextInput() }
                .onExitCommand { viewModel.cancelTextInput() }
        }
    }
}
