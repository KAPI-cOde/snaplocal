// StateHistory.swift
// SnapLocal — SnapLocalState extension: 履歴系メソッド (R1.6)

import AppKit

@MainActor
extension SnapLocalState {

    // MARK: - History

    func loadHistoryItem(_ item: VaultItem) {
        loadHistoryItem(item, quiet: false)
    }

    /// quiet=true: 起動時の自動復元など、ユーザー操作によらないロードではチップを出さない
    func loadHistoryItem(_ item: VaultItem, quiet: Bool) {
        // Save current annotations / pending background edits before switching
        if canvas.backgroundDirty {
            flushPendingBackgroundEdit()
        } else if let id = currentVaultID, !canvas.annotations.isEmpty {
            let anns = canvas.annotations
            let basis = canvas.annotationsBasis
            let v = vault
            Task { await v.updateAnnotations(id: id, annotations: anns, basis: basis) }
        }
        // Set selection immediately for responsive UI
        currentVaultID = item.id
        selectedHistoryID = item.id
        // Load image off the main thread to avoid blocking on large PNGs
        loadHistoryTask?.cancel()
        let url = item.imageURL
        let itemID = item.id
        let v = vault
        loadHistoryTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let nsImage = NSImage(contentsOf: url),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            // 注釈は history スナップショットでなく vault の最新を読む(T9.5)。
            // 直前の updateAnnotations(切替時 persist)は同じ actor 内で先に処理される
            let (annotations, basis) = await v.currentAnnotations(id: itemID) ?? (item.annotations, item.annotationsBasis)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.canvas.resetAndLoad(image: cgImage, annotations: annotations, basis: basis)
                if !quiet { self?.showStatus("履歴を読み込みました") }
            }
        }
    }

    private func cgImage(from data: Data) -> CGImage? {
        NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func refreshHistory() {
        Task { await loadHistory() }
    }

    func loadHistory() async {
        let q = searchQuery
        let items = q.isEmpty ? await vault.allItems() : await vault.search(query: q)
        // 入力が進んで古くなった結果は捨てる(タイプ中の結果順序の乱れ防止)
        guard q == searchQuery else { return }
        let wasEmpty = history.isEmpty && currentVaultID == nil
        history = items
        // Auto-load the most recent screenshot on first launch
        if wasEmpty, let first = items.first {
            loadHistoryItem(first, quiet: true)
        }
    }

    /// 検索フィールドからの呼び出し。1文字ごとに全件スキャンしないよう200msデバウンス(T6.2)
    func applySearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.loadHistory()
        }
    }

    func navigateHistory(by delta: Int) {
        guard !history.isEmpty else { return }
        if let current = selectedHistoryID,
           let idx = history.firstIndex(where: { $0.id == current }) {
            let newIdx = max(0, min(history.count - 1, idx + delta))
            if newIdx != idx { loadHistoryItem(history[newIdx]) }
        } else {
            loadHistoryItem(history[0])
        }
    }

    func deleteHistoryItem(_ item: VaultItem) {
        Task {
            await vault.delete(id: item.id)
            await loadHistory()
        }
    }

    func deleteAllHistory() {
        Task {
            for item in history { await vault.delete(id: item.id) }
            canvas.backgroundImage = nil
            canvas.annotations.removeAll()
            currentVaultID = nil
            selectedHistoryID = nil
            await loadHistory()
            showStatus("すべての履歴を削除しました", success: true)
        }
    }

    func renameHistoryItem(_ item: VaultItem, title: String?) {
        Task {
            await vault.updateTitle(id: item.id, title: title)
            await loadHistory()
        }
    }

    func updateNotesForItem(_ item: VaultItem, notes: String?) {
        Task {
            await vault.updateNotes(id: item.id, notes: notes)
            await loadHistory()
        }
    }

    func toggleStar(for item: VaultItem) {
        Task {
            await vault.toggleStar(id: item.id)
            await loadHistory()
        }
    }

    func duplicateHistoryItem(_ item: VaultItem) {
        Task {
            _ = await vault.duplicate(id: item.id)
            await loadHistory()
            showStatus("複製しました", success: true)
        }
    }

    func stitchFromClipboard(vertical: Bool) {
        guard let nsImage = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let other = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showStatus("クリップボードに画像がありません")
            return
        }
        canvas.stitch(with: other, vertical: vertical)
        showStatus(vertical ? "下に結合しました" : "右に結合しました", success: true)
    }

    func revealCurrentItemInFinder() {
        guard let id = currentVaultID,
              let item = history.first(where: { $0.id == id }) else {
            showStatus("保存済みのファイルがありません")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.imageURL])
    }
}
