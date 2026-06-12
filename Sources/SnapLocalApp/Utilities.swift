// Utilities.swift
// SnapLocal — 共通ユーティリティ(R2.2 重複排除)
//
// Copyright © 2024 SnapLocal. All rights reserved.

import AppKit
import CoreGraphics

// MARK: - CGImage helpers

extension CGImage {
    /// PNG データに変換する。PersistentVault / StateExport 両者の private pngData(from:) を統合。
    func pngData() -> Data? {
        NSBitmapImageRep(cgImage: self).representation(using: .png, properties: [:])
    }

    /// ピクセルサイズと同じ論理サイズの NSImage を返す。
    /// size がピクセルサイズそのままのパターンのみ対象。違うサイズを渡している箇所は触らない。
    var nsImage: NSImage {
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}

// MARK: - NSApplication helpers

extension NSApplication {
    /// アプリを最前面に持ってくる2行セット。
    /// 2行が完全一致するペア5箇所を統合(片方のみ・間に別コードが挟まる箇所は除外)。
    @MainActor
    func bringToFront() {
        activate(ignoringOtherApps: true)
        if let window = windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            reopenMainWindow()
        }
    }

    /// 閉じて破棄された(または「閉じた状態」で復元された)WindowGroupウィンドウをSwiftUIに再生成させる。
    /// Dockクリックと同じ reopen イベントを自分自身へ送る。
    /// T9.2 実機検証: delegateの applicationShouldHandleReopen 直呼びはYESを返すだけで再生成されず、
    /// SwiftUIの openWindow をグローバル退避する案もメニューバーラベルでは onAppear 非発火で不成立 —
    /// この経路のみ動作確認できた。自分自身へのApple Event送信は権限プロンプト対象外。
    @MainActor
    func reopenMainWindow() {
        let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),      // 'aevt'
            eventID: AEEventID(kAEReopenApplication),       // 'rapp'
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        _ = try? event.sendEvent(options: [.noReply], timeout: 0.1)
    }
}

// MARK: - DateFormatter helpers

extension DateFormatter {
    /// ファイル名用タイムスタンプ "yyyyMMdd-HHmmss"。StateExport 3箇所の重複を統合。
    static let fileTimestamp: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df
    }()
}

/// 撮影元ブラウザの現在タブURL+タイトルを Apple Events(ローカルのみ)で取得する(T9.9)。
/// 非対応ブラウザ・権限拒否・取得失敗は全て nil = 静かにスキップ
@MainActor
enum BrowserSourceService {
    private enum ScriptForm { case safari, chromium }
    private static let browsers: [String: ScriptForm] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.brave.Browser": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "org.chromium.Chromium": .chromium,
        "company.thebrowser.Browser": .chromium,  // Arc
    ]

    static func fetchCurrentTab(bundleID: String?) -> (url: String, title: String)? {
        guard let bid = bundleID, let form = browsers[bid] else { return nil }
        let script: String
        switch form {
        case .safari:
            script = """
            try
              tell application id "\(bid)"
                set u to URL of current tab of front window
                set t to name of current tab of front window
                return u & linefeed & t
              end tell
            end try
            """
        case .chromium:
            script = """
            try
              tell application id "\(bid)"
                set u to URL of active tab of front window
                set t to title of active tab of front window
                return u & linefeed & t
              end tell
            end try
            """
        }
        var err: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue else { return nil }
        let parts = result.components(separatedBy: "\n")
        let rawURL = parts.first ?? ""
        let rawTitle = parts.count > 1 ? parts[1] : ""
        guard let parsed = URL(string: rawURL), parsed.scheme == "http" || parsed.scheme == "https" else { return nil }
        let title = rawTitle.isEmpty ? (parsed.host ?? rawURL) : rawTitle
        return (rawURL, title)
    }
}
