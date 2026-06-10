// Sheets.swift
// SnapLocal - HelpPopoverContent, SettingsSheet, WindowPickerSheet
// (extracted from App.swift — PLAN.md T0.4, mechanical move only)

import SwiftUI
import AppKit
import ScreenCaptureKit
import ServiceManagement

// MARK: - Help Popover

struct HelpPopoverContent: View {
    private let sections: [(String, [(String, String)])] = [
        ("キャプチャ", [
            ("⌘⇧2", "全画面撮影"),
            ("⌘⇧3", "ウィンドウ撮影"),
            ("⌘⇧4", "範囲選択撮影（ウィンドウスナップ対応）"),
            ("⌘⇧R", "前回範囲を再撮影"),
            ("⌘⌃2", "全画面→クリップボードのみ（履歴に保存しない）"),
            ("⌘⌃4", "範囲選択→クリップボードのみ"),
            ("タイマー", "3/5/10秒遅延撮影"),
            ("⌘V", "クリップボードから貼り付け"),
            ("⌘⇧P", "画面にピン留め"),
            ("⌘F", "履歴を検索"),
        ]),
        ("範囲選択モード（⌘⇧4）", [
            ("スクリーンフリーズ", "起動時に画面を静止画として固定 — ツールチップやメニューも撮影可能"),
            ("ドラッグ", "範囲を選択（ウィンドウ自動スナップ対応）"),
            ("Shift+ドラッグ", "正方形に制約"),
            ("Space+ドラッグ中", "選択範囲を移動（サイズ固定）"),
            ("矢印キー", "1px微調整（Shift=10px）"),
            ("↵ / ダブルクリック", "確定して撮影（即時反映 — 再キャプチャ不要）"),
            ("Esc", "キャンセル / やり直し"),
        ]),
        ("ツール", [
            ("V", "選択ツール"),
            ("L", "直線"),
            ("A", "矢印"),
            ("R", "長方形"),
            ("E", "楕円"),
            ("T", "テキスト"),
            ("N", "ステップ番号"),
            ("U", "角丸長方形"),
            ("B", "吹き出し"),
            ("H", "ハイライト"),
            ("P", "鉛筆（フリーハンド）"),
            ("G", "スタンプ（クリックで絵文字配置）"),
            ("I", "スポイト（クリックで色をサンプリング）"),
            ("X / M", "モザイク/ぼかし"),
            ("O", "スポットライト"),
            ("Q", "ピクセル定規"),
            ("Tab", "アノテーション選択切り替え（選択モード）/ 次のツール"),
        ]),
        ("描画", [
            ("Shift+ドラッグ", "45°制約 / 正方形/正円"),
            ("F", "塗りつぶし切り替え（長方形・楕円・吹き出し）"),
            ("Option+クリック", "スポイト（色を拾う）"),
            ("Option+ドラッグ", "アノテーション複製"),
            ("[  /  ]", "線幅 細/太"),
            ("{  /  }", "不透明度 -10% / +10%"),
        ]),
        ("編集", [
            ("⌘Z / ⌘⇧Z", "元に戻す / やり直し"),
            ("⌫", "選択削除"),
            ("⌘A", "全アノテーション選択"),
            ("⌘D", "アノテーション複製"),
            ("⌘L", "ロック / ロック解除"),
            ("⌘'", "アノテーション表示/非表示"),
            ("矢印キー", "1px移動（Shift=10px）"),
            ("⌘] / ⌘[", "前面へ / 背面へ"),
            ("1〜8", "色を選択"),
            ("Enter", "テキスト再編集"),
            ("ダブルクリック", "テキスト再編集"),
            ("テキスト入力中⇧⏎", "テキストに改行を挿入（複数行対応）"),
            ("⌘K → 矢印", "クロップ範囲を移動（⌥+矢印でリサイズ）"),
            ("Esc", "選択解除 / モード終了"),
        ]),
        ("ズーム/パン", [
            ("ピンチ / スクロール", "ズーム・パン"),
            ("Space+ドラッグ", "パン"),
            ("⌘+ / ⌘-", "ズームイン/アウト"),
            ("⌘0", "実寸表示（100% = 撮影時の大きさ）"),
            ("⌘9", "フィット表示"),
        ]),
        ("その他", [
            ("⌘↑ / ⌘↓", "履歴の前/次"),
            ("⌘K", "切り取りモード"),
            ("⌘⌥← / ⌘⌥→", "90°回転（左/右）"),
            ("⌘C", "クリップボードにコピー（アノテーション込み）"),
            ("⌘⌥C", "オリジナルをコピー（アノテーションなし）"),
            ("⌘⌥⇧C", "選択範囲を画像でコピー"),
            ("⌘⌥T", "選択範囲のテキストをOCR・コピー"),
            ("⌘⌥R", "Finderで表示"),
            ("⌘S", "ファイルに保存"),
            ("⌘⇧S", "別名で保存"),
            ("⌘⇧E", "共有（AirDrop・メール等）"),
            ("履歴サムネイルホバー", "プレビュー・メモ編集"),
            ("顔自動モザイク", "消しゴムツールボタンで顔を一括ぼかし"),
            ("↔ トグル", "矢印ツール選択時：両方向矢印に切り替え"),
            ("変形メニュー", "余白自動トリミング・反転・リサイズ"),
            ("テンプレートアイコン", "アノテーションセットを名前付きで保存・適用"),
            ("右下ステータス", "選択アノテーションのpx座標 [幅×高さ @x,y]"),
            ("左下座標", "カーソルのキャンバス座標をリアルタイム表示"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(sections, id: \.0) { section, rows in
                    Text(section)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.top, DS.Space.xxs)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(rows, id: \.0) { key, desc in
                            HStack(alignment: .top, spacing: DS.Space.xs) {
                                Text(key)
                                    .font(.system(size: DS.FontSize.caption, design: .monospaced))
                                    .padding(.horizontal, DS.Space.xxs)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                                    .frame(minWidth: 80, alignment: .leading)
                                Text(desc)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    Divider()
                }
            }
            .padding(DS.Space.s)
        }
        .frame(width: 280, height: 380)
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @StateObject private var settings = SettingsManager.shared
    @State private var saveDirectoryPath: String = ""
    @State private var filenameTemplate: String = ""
    @State private var showHelp = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("設定")
                    .font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)

            Divider()

            Form {
                Section {
                    Toggle("カーソルを含める", isOn: Binding(
                        get: { settings.captureWithCursor },
                        set: { settings.captureWithCursor = $0 }
                    ))
                    Toggle("撮影後にクリップボードへ自動コピー", isOn: Binding(
                        get: { settings.autoCopyOnCapture },
                        set: { settings.autoCopyOnCapture = $0 }
                    ))
                    Toggle("撮影後すぐにエディタを開く（HUDをスキップ）", isOn: Binding(
                        get: { settings.openEditorOnCapture },
                        set: { settings.openEditorOnCapture = $0 }
                    ))
                } header: {
                    Text("キャプチャ")
                } footer: {
                    Text("「カーソルを含める」は撮影画像にマウスポインタを写し込みます")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Section {
                    Picker("形式", selection: Binding(
                        get: { settings.exportFormat },
                        set: { settings.exportFormat = $0 }
                    )) {
                        ForEach(ExportFormat.allCases, id: \.self) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .pickerStyle(.segmented)
                    if settings.exportFormat == .jpeg {
                        HStack {
                            Text("JPEG品質")
                                .foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { settings.jpegQuality },
                                set: { settings.jpegQuality = $0 }
                            ), in: 0.4...1.0, step: 0.05)
                            Text("\(Int(settings.jpegQuality * 100))%")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 36)
                        }
                    }
                } header: {
                    Text("書き出し形式")
                } footer: {
                    Text("⌘S保存時の形式です。別名保存(⌘⇧S)では毎回選択できます")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Section("保存先") {
                    HStack {
                        Text(saveDirectoryPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("変更…") { chooseSaveDirectory() }
                            .controlSize(.small)
                    }
                    Text("Google Drive等の同期フォルダも指定できます。履歴の書き込みは当月分の差分だけなので同期負荷は最小です")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("ファイル名テンプレート")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("{date}, {time}, {width}, {height}, {title}", text: $filenameTemplate)
                            .font(.system(.caption, design: .monospaced))
                            .onSubmit { settings.filenameTemplate = filenameTemplate }
                            .onChange(of: filenameTemplate) { settings.filenameTemplate = filenameTemplate }
                        Text("例: SnapLocal-{date}-{time}  →  \(settings.filename(for: Date(), width: 1920, height: 1080, title: nil))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Section {
                    Picker("全画面撮影", selection: Binding(
                        get: { settings.hotkeyConfig },
                        set: { settings.hotkeyConfig = $0 }
                    )) {
                        ForEach(settings.availableHotkeys, id: \.displayString) { h in
                            Text(h.displayString).tag(h)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("ホットキー")
                } footer: {
                    Text("全画面撮影のキーのみ変更できます。他のショートカットは固定です")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Section("通知") {
                    Toggle("撮影完了を通知する", isOn: Binding(
                        get: { settings.notificationsEnabled },
                        set: { settings.notificationsEnabled = $0 }
                    ))
                }

                if #available(macOS 13.0, *) {
                    Section("起動") {
                        Toggle("ログイン時に起動", isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.launchAtLogin = $0 }
                        ))
                    }
                }

                Section("ヘルプ") {
                    Button("ショートカットキー一覧…") { showHelp = true }
                        .popover(isPresented: $showHelp, arrowEdge: .trailing) {
                            HelpPopoverContent()
                        }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 380)
        .onAppear {
            saveDirectoryPath = settings.saveDirectoryURL.path
            filenameTemplate = settings.filenameTemplate
        }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "選択"
        panel.message = "スクリーンショットの保存先を選択してください"
        panel.directoryURL = settings.saveDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectoryURL = url
            saveDirectoryPath = url.path
        }
    }
}

// MARK: - Window Picker Sheet

struct WindowPickerSheet: View {
    let windows: [SCWindow]
    let onSelect: (SCWindow) -> Void
    let onCancel: () -> Void

    @State private var hovered: CGWindowID? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ウィンドウを選択")
                    .font(.headline)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)

            Divider()

            if windows.isEmpty {
                VStack(spacing: DS.Space.xs) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("キャプチャ可能なウィンドウが見つかりません")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.xxs) {
                        ForEach(windows, id: \.windowID) { win in
                            WindowPickerRow(window: win, isHovered: hovered == win.windowID)
                                .onHover { hovering in
                                    hovered = hovering ? win.windowID : nil
                                }
                                .onTapGesture {
                                    onSelect(win)
                                }
                        }
                    }
                    .padding(DS.Space.xs)
                }
                .frame(minHeight: 200, maxHeight: 480)
            }

            Divider()

            HStack {
                Spacer()
                Button("キャンセル", action: onCancel)
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.xs)
        }
        .frame(width: 480)
    }
}

struct WindowPickerRow: View {
    let window: SCWindow
    let isHovered: Bool

    var appIcon: NSImage? {
        guard let bundleID = window.owningApplication?.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    var appName: String {
        window.owningApplication?.applicationName ?? "不明なアプリ"
    }

    var windowTitle: String {
        let t = window.title ?? ""
        return t.isEmpty ? appName : t
    }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "macwindow")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(windowTitle)
                    .lineLimit(1)
                    .font(.body)
                Text(appName)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(window.frame.width))×\(Int(window.frame.height))")
                .font(.system(size: DS.FontSize.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, DS.Space.xs)
        .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.medium))
        .contentShape(Rectangle())
    }
}
