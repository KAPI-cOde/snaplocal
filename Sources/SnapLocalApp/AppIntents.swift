// AppIntents.swift
// Exposes SnapLocal actions to Shortcuts.app and Siri.

import AppIntents
import AppKit

// MARK: - Notification names

extension Notification.Name {
    static let intentCaptureScreen = Notification.Name("snaplocal.intent.captureScreen")
    static let intentCaptureRegion = Notification.Name("snaplocal.intent.captureRegion")
}

// MARK: - Take Full-Screen Screenshot

struct TakeScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "スクリーンショットを撮影"
    static let description = IntentDescription("SnapLocal で全画面スクリーンショットを撮影します。")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        // Short delay so the app window is front before capture
        try await Task.sleep(nanoseconds: 300_000_000)
        NotificationCenter.default.post(name: .intentCaptureScreen, object: nil)
        return .result()
    }
}

// MARK: - Capture Selected Region

struct CaptureRegionIntent: AppIntent {
    static let title: LocalizedStringResource = "範囲を選択してスクリーンショット"
    static let description = IntentDescription("SnapLocal で画面の任意の範囲を選択して撮影します。")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        NotificationCenter.default.post(name: .intentCaptureRegion, object: nil)
        return .result()
    }
}

// MARK: - Open SnapLocal

struct OpenSnapLocalIntent: AppIntent {
    static let title: LocalizedStringResource = "SnapLocal を開く"
    static let description = IntentDescription("SnapLocal アプリを前面に表示します。")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        return .result()
    }
}

// MARK: - App Shortcuts Provider

struct SnapLocalShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TakeScreenshotIntent(),
            phrases: [
                "SnapLocal でスクリーンショットを撮影",
                "Take a screenshot with \(.applicationName)",
                "Capture screen with \(.applicationName)"
            ],
            shortTitle: "スクリーンショット撮影",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: CaptureRegionIntent(),
            phrases: [
                "SnapLocal で範囲撮影",
                "Capture a region with \(.applicationName)"
            ],
            shortTitle: "範囲撮影",
            systemImageName: "rectangle.dashed.badge.record"
        )
        AppShortcut(
            intent: OpenSnapLocalIntent(),
            phrases: [
                "\(.applicationName) を開く",
                "Open \(.applicationName)"
            ],
            shortTitle: "SnapLocal を開く",
            systemImageName: "photo.stack"
        )
    }
}
