// HistoryRail.swift
// SnapLocal - History sidebar: HistoryRail, HistoryItemRow, HistoryItemPopover
// (extracted from App.swift — PLAN.md T0.3, mechanical move only)

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookUI

// MARK: - History Rail

struct HistoryRail: View {
    let history: [VaultItem]
    @Binding var searchQuery: String
    @Binding var focusTrigger: Bool
    let selectedID: UUID?
    let onSelect: (VaultItem) -> Void
    let onDelete: (VaultItem) -> Void
    let onRefresh: () -> Void
    let onSearch: () -> Void
    let onExport: (VaultItem) -> Void
    var onRename: ((VaultItem, String?) -> Void)? = nil
    var onDuplicate: ((VaultItem) -> Void)? = nil
    var onDeleteAll: (() -> Void)? = nil
    var onExportZip: (() -> Void)? = nil
    var onExportPDF: (() -> Void)? = nil
    var onUpdateNotes: ((VaultItem, String?) -> Void)? = nil
    var onToggleStar: ((VaultItem) -> Void)? = nil
    var onReocr: ((VaultItem) -> Void)? = nil

    @FocusState private var searchFocused: Bool
    @State private var thumbCache: [UUID: NSImage] = [:]
    @State private var hoveredItemID: UUID? = nil
    @State private var popoverItemID: UUID? = nil   // delayed popover — avoids flicker on fast scroll
    @State private var popoverTask: Task<Void, Never>? = nil
    @State private var renamingItemID: UUID? = nil
    @State private var quickLookItem: VaultItem? = nil
    @State private var renameText: String = ""
    @State private var showDeleteAllConfirm = false
    @State private var showOnlyStarred = false

    // Gyazo風2列グリッド (PLAN.md T4.1)
    private let thumbW: CGFloat = 110
    private let thumbH: CGFloat = 74
    private var railWidth: CGFloat { thumbW * 2 + DS.Space.xs + DS.Space.xs * 2 }

    private func historyItemLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return f.string(from: date)
        } else if Calendar.current.isDateInYesterday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "昨日 " + f.string(from: date)
        } else {
            let f = DateFormatter(); f.dateFormat = "M/d"
            return f.string(from: date)
        }
    }

    private enum DateGroup: String {
        case today = "今日"
        case yesterday = "昨日"
        case thisWeek = "今週"
        case older = "それ以前"
    }

    private func dateGroup(for date: Date) -> DateGroup {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        if let daysAgo = cal.dateComponents([.day], from: date, to: Date()).day, daysAgo < 7 { return .thisWeek }
        return .older
    }

    private var displayedHistory: [VaultItem] {
        showOnlyStarred ? history.filter { $0.isStarred } : history
    }

    private var groupedHistory: [(DateGroup, [VaultItem])] {
        let order: [DateGroup] = [.today, .yesterday, .thisWeek, .older]
        let grouped = Dictionary(grouping: displayedHistory, by: { dateGroup(for: $0.createdAt) })
        return order.compactMap { g in
            guard let items = grouped[g], !items.isEmpty else { return nil }
            return (g, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("検索", text: $searchQuery)
                    .font(.caption2)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: searchQuery) { _, _ in onSearch() }
                    .onChange(of: focusTrigger) { _, _ in searchFocused = true }
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = ""; onSearch() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.xxs)
            .background(.ultraThinMaterial)

            Divider()

            if displayedHistory.isEmpty {
                VStack(spacing: DS.Space.xs) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(searchQuery.isEmpty ? "キャプチャなし" : "見つかりません")
                        .font(.system(size: DS.FontSize.caption))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(groupedHistory, id: \.0.rawValue) { group, items in
                        Text(group.rawValue)
                            .font(.system(size: DS.FontSize.caption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DS.Space.xs)
                            .padding(.top, DS.Space.xs)
                            .padding(.bottom, 2)
                        LazyVGrid(columns: [GridItem(.fixed(thumbW), spacing: DS.Space.xs),
                                            GridItem(.fixed(thumbW))],
                                  alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(items) { item in
                            HistoryItemRow(
                                item: item,
                                isSelected: item.id == selectedID,
                                isHovered: hoveredItemID == item.id,
                                showPopover: popoverItemID == item.id,
                                isRenaming: renamingItemID == item.id,
                                renameText: $renameText,
                                searchQuery: searchQuery,
                                thumbW: thumbW, thumbH: thumbH,
                                thumbCache: $thumbCache,
                                onSelect: { onSelect(item) },
                                onToggleStar: { onToggleStar?(item) },
                                onDelete: { onDelete(item) },
                                onDuplicate: { onDuplicate?(item) },
                                onExport: { onExport(item) },
                                onRename: { name in onRename?(item, name); renamingItemID = nil },
                                onRenameBegin: { renameText = item.title ?? ""; renamingItemID = item.id },
                                onRenameCancelled: { renamingItemID = nil },
                                onPopoverDismiss: { popoverItemID = nil },
                                onUpdateNotes: onUpdateNotes,
                                onReocr: { onReocr?(item) },
                                historyItemLabel: historyItemLabel,
                                onHoverChanged: { hovering in
                                    hoveredItemID = hovering ? item.id : nil
                                    popoverTask?.cancel()
                                    if hovering {
                                        popoverTask = Task {
                                            try? await Task.sleep(nanoseconds: 400_000_000)
                                            if hoveredItemID == item.id { popoverItemID = item.id }
                                        }
                                    } else {
                                        popoverItemID = nil
                                    }
                                }
                            )
                        }   // ForEach(items)
                        }   // LazyVGrid for items
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.bottom, DS.Space.xxs)
                    }   // ForEach(groupedHistory)
                }   // outer VStack
            }
            .onChange(of: selectedID) { _, newID in
                if let id = newID {
                    withAnimation(DS.Anim.smooth) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onKeyPress(.space) {
                if let id = hoveredItemID, let item = displayedHistory.first(where: { $0.id == id }) {
                    if quickLookItem?.id == item.id {
                        quickLookItem = nil
                    } else {
                        quickLookItem = item
                    }
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(characters: .init(charactersIn: "\u{F700}\u{F701}"), phases: [.down, .repeat]) { press in
                // ↑/↓ keyboard navigation in history
                let list = displayedHistory
                guard !list.isEmpty else { return .ignored }
                let currentIdx = list.firstIndex(where: { $0.id == selectedID }) ?? -1
                let delta = press.key == .upArrow ? -1 : 1
                let nextIdx = max(0, min(list.count - 1, currentIdx + delta))
                let nextItem = list[nextIdx]
                if nextItem.id != selectedID {
                    onSelect(nextItem)
                    withAnimation(DS.Anim.smooth) {
                        proxy.scrollTo(nextItem.id, anchor: .center)
                    }
                }
                return .handled
            }
            .onKeyPress(.return) {
                if let id = selectedID, let item = displayedHistory.first(where: { $0.id == id }) {
                    onSelect(item); return .handled
                }
                return .ignored
            }
            .onKeyPress(.deleteForward) {
                if let id = selectedID, let item = displayedHistory.first(where: { $0.id == id }) {
                    onDelete(item); return .handled
                }
                return .ignored
            }
            } // ScrollViewReader

            Divider()
            HStack(spacing: 0) {
                Text("\(displayedHistory.count)件")
                    .font(.system(size: DS.FontSize.caption2))
                    .foregroundStyle(.secondary)
                    .padding(.leading, DS.Space.xs)
                Spacer()
                Button(action: { showOnlyStarred.toggle() }) {
                    Image(systemName: showOnlyStarred ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundStyle(showOnlyStarred ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(showOnlyStarred ? "全件表示" : "スター付きのみ表示")
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                if let onExportZip {
                    Button(action: onExportZip) {
                        Image(systemName: "arrow.down.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("すべての履歴をZIPでエクスポート")
                }
                if let onExportPDF {
                    Button(action: onExportPDF) {
                        Image(systemName: "doc.richtext")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("すべての履歴をPDFでエクスポート")
                }
                if let onDeleteAll {
                    Button(action: { showDeleteAllConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, DS.Space.xxs)
                    .confirmationDialog("すべての履歴を削除しますか？\nこの操作は取り消せません。", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
                        Button("すべて削除", role: .destructive) { onDeleteAll() }
                        Button("キャンセル", role: .cancel) {}
                    }
                }
            }
            .padding(.vertical, DS.Space.xxs)
        }
        .frame(width: railWidth)
        .background(.regularMaterial)
        .onKeyPress(.escape) {
            if quickLookItem != nil {
                HistoryQuickLook.shared.dismiss()
                quickLookItem = nil
                return .handled
            }
            return .ignored
        }
        .onChange(of: quickLookItem?.id) { _, newID in
            if let item = quickLookItem {
                HistoryQuickLook.shared.show(item: item)
            } else {
                HistoryQuickLook.shared.dismiss()
            }
        }
    }
}

// MARK: - History Item Row

private struct HistoryItemRow: View {
    let item: VaultItem
    let isSelected: Bool
    let isHovered: Bool
    let showPopover: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let searchQuery: String
    let thumbW: CGFloat
    let thumbH: CGFloat
    @Binding var thumbCache: [UUID: NSImage]
    @State private var justCopied = false
    let onSelect: () -> Void
    let onToggleStar: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onRename: (String?) -> Void
    let onRenameBegin: () -> Void
    let onRenameCancelled: () -> Void
    let onPopoverDismiss: () -> Void
    var onUpdateNotes: ((VaultItem, String?) -> Void)?
    var onReocr: (() -> Void)? = nil
    let historyItemLabel: (Date) -> String
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 3) {
                thumbnailView
                labelView
                if !item.ocrText.isEmpty && !searchQuery.isEmpty {
                    Text(item.ocrText)
                        .font(.system(size: DS.FontSize.caption2))
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .frame(width: thumbW, alignment: .leading)
                }
            }
        }
        .id(item.id)
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(contentsOf: item.imageURL) ?? NSItemProvider() }
        .onHover(perform: onHoverChanged)
        .popover(isPresented: Binding(get: { showPopover }, set: { if !$0 { onPopoverDismiss() } }), arrowEdge: .leading) {
            HistoryItemPopover(item: item, onUpdateNotes: onUpdateNotes)
        }
        .contextMenu { contextMenuContent }
        .help(makeHelp())
    }

    private func copyImageToClipboard() {
        guard let nsImage = NSImage(contentsOf: item.imageURL) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
        withAnimation(DS.Anim.fast) { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(DS.Anim.fast) { justCopied = false }
        }
    }

    private func makeHelp() -> String {
        var s = item.createdAt.formatted(date: .complete, time: .shortened)
        if item.width > 0 { s += "  \(item.width)×\(item.height)" }
        s += "  Space: クイックルック"
        if !item.ocrText.isEmpty { s += "\n" + String(item.ocrText.prefix(80)) }
        return s
    }

    @ViewBuilder private var thumbnailView: some View {
        Group {
            if let nsImage = thumbCache[item.id] ?? NSImage(data: item.thumbnailData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .onAppear { if thumbCache[item.id] == nil { thumbCache[item.id] = nsImage } }
            } else {
                Image(systemName: "photo")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: thumbW, height: thumbH)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small))
        .overlay(alignment: .topTrailing) {
            if item.annotations.count > 0 {
                Text("\(item.annotations.count)")
                    .font(.system(size: DS.FontSize.caption2, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
                    .padding(2)
            }
        }
        .overlay(alignment: .bottomLeading) {
            let dim = item.dimensionLabel
            if !dim.isEmpty {
                Text(dim)
                    .font(.system(size: DS.FontSize.caption2, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(2)
            }
        }
        .overlay(alignment: .topLeading) {
            if item.isStarred || isHovered {
                let icon = item.isStarred ? "star.fill" : "star"
                let color: Color = item.isStarred ? .yellow : .white.opacity(0.8)
                Button(action: onToggleStar) {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(color)
                        .padding(2)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(item.isStarred ? "スターを外す" : "スターを付ける")
                .padding(2)
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 2) {
                if item.notes != nil {
                    Image(systemName: "note.text")
                        .font(.system(size: 7))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Color.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                if isHovered {
                    Button(action: copyImageToClipboard) {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.clipboard")
                            .font(.system(size: 10))
                            .foregroundStyle(justCopied ? Color.green : .white.opacity(0.9))
                            .padding(2)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("クリップボードにコピー")
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            .padding(2)
        }
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .scaleEffect(isHovered && !isSelected ? 1.04 : 1)
        .animation(DS.Anim.base, value: isSelected)
        .animation(DS.Anim.fast, value: isHovered)
    }

    @ViewBuilder private var labelView: some View {
        if isRenaming {
            TextField("名前", text: $renameText)
                .font(.system(size: DS.FontSize.caption2))
                .textFieldStyle(.roundedBorder)
                .frame(width: thumbW)
                .onSubmit { onRename(renameText.isEmpty ? nil : renameText) }
                .onExitCommand { onRenameCancelled() }
        } else {
            VStack(spacing: 1) {
                if let title = item.title {
                    Text(title)
                        .font(.system(size: DS.FontSize.caption2, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .frame(width: thumbW, alignment: .leading)
                }
                Text(historyItemLabel(item.createdAt))
                    .font(.system(size: DS.FontSize.caption2))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var contextMenuContent: some View {
        Button(item.isStarred ? "スターを外す" : "スターを付ける") { onToggleStar() }
        Divider()
        Button("開く") { onSelect() }
        Button("複製") { onDuplicate() }
        Button("名前を変更…") { onRenameBegin() }
        Divider()
        Button("ファイルに保存…") { onExport() }
        Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([item.imageURL]) }
        Button("Previewで開く") {
            NSWorkspace.shared.open([item.imageURL], withAppBundleIdentifier: "com.apple.Preview",
                                    options: [], additionalEventParamDescriptor: nil, launchIdentifiers: nil)
        }
        Button("ファイルパスをコピー") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.imageURL.path, forType: .string)
        }
        Button("Markdownリンクをコピー") {
            let alt = item.title ?? "screenshot"
            let md = "![" + alt + "](" + item.imageURL.path + ")"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(md, forType: .string)
        }
        Button("クリップボードにコピー") {
            if let nsImage = NSImage(contentsOf: item.imageURL) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([nsImage])
            }
        }
        Button("共有…") {
            let picker = NSSharingServicePicker(items: [item.imageURL])
            if let btn = NSApp.keyWindow?.contentView?.subviews.first {
                picker.show(relativeTo: .zero, of: btn, preferredEdge: .minY)
            }
        }
        if !item.ocrText.isEmpty {
            Button("OCRテキストをコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.ocrText, forType: .string)
            }
        }
        // 自動OCRの誤認識・失敗時用(通常導線には出さない — 撮影後に自動実行される)
        Button("文字認識を再実行") { onReocr?() }
        Divider()
        Button("削除", role: .destructive) { onDelete() }
    }
}

// MARK: - History Item Popover

struct HistoryItemPopover: View {
    let item: VaultItem
    var onUpdateNotes: ((VaultItem, String?) -> Void)?

    @State private var notesText: String
    @State private var fullImage: NSImage? = nil
    @State private var ocrCopied = false

    init(item: VaultItem, onUpdateNotes: ((VaultItem, String?) -> Void)?) {
        self.item = item
        self.onUpdateNotes = onUpdateNotes
        self._notesText = State(initialValue: item.notes ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Preview image
            let displayImage: NSImage? = fullImage ?? NSImage(data: item.thumbnailData)
            if let nsImage = displayImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 380, maxHeight: 220)
                    .clipped()
                    .animation(DS.Anim.fast, value: fullImage != nil)
            } else {
                Color.secondary.opacity(0.1)
                    .frame(width: 380, height: 120)
            }

            // OCR text — selectable, shown immediately if available
            if !item.ocrText.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("テキスト")
                            .font(.system(size: DS.FontSize.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.ocrText, forType: .string)
                            ocrCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { ocrCopied = false }
                        } label: {
                            Label(ocrCopied ? "コピー済" : "全コピー",
                                  systemImage: ocrCopied ? "checkmark" : "doc.on.clipboard")
                                .font(.system(size: DS.FontSize.caption))
                                .foregroundStyle(ocrCopied ? .green : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    // Selectable text via TextEditor (read-only binding workaround)
                    TextEditor(text: .constant(item.ocrText))
                        .font(.system(size: DS.FontSize.caption))
                        .scrollContentBackground(.hidden)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.small))
                        .frame(height: 72)
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
            }

            Divider()

            // Notes
            VStack(alignment: .leading, spacing: 4) {
                Text("メモ")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $notesText)
                    .font(.system(size: DS.FontSize.body))
                    .frame(height: 52)
                    .scrollContentBackground(.hidden)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.small))
                    .overlay(alignment: .topLeading) {
                        if notesText.isEmpty {
                            Text("メモを追加…")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: DS.FontSize.body))
                                .padding(.top, DS.Space.xxs).padding(.leading, DS.Space.xxs)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: notesText) { _, newVal in
                        onUpdateNotes?(item, newVal.isEmpty ? nil : newVal)
                    }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
        }
        .frame(width: 380)
        .task {
            guard fullImage == nil else { return }
            let url = item.imageURL
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            fullImage = loaded
        }
    }
}
