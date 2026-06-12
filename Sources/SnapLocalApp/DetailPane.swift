import SwiftUI
import AppKit

struct DetailPane: View {
    let item: VaultItem
    var onRename: ((VaultItem, String?) -> Void)?
    var onUpdateNotes: ((VaultItem, String?) -> Void)?

    private var displayedOCRText: String {
        if let polished = item.ocrTextPolished, !polished.isEmpty {
            return polished
        }
        return item.ocrText
    }

    @State private var titleText: String
    @State private var notesText: String
    @State private var ocrCopied = false
    @FocusState private var titleFocused: Bool

    init(
        item: VaultItem,
        onRename: ((VaultItem, String?) -> Void)? = nil,
        onUpdateNotes: ((VaultItem, String?) -> Void)? = nil
    ) {
        self.item = item
        self.onRename = onRename
        self.onUpdateNotes = onUpdateNotes
        self._titleText = State(initialValue: item.title ?? "")
        self._notesText = State(initialValue: item.notes ?? "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                TextField("タイトルを追加…", text: $titleText)
                    .font(.system(size: DS.FontSize.body, weight: .medium))
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    .onChange(of: titleFocused) { wasFocused, isFocused in
                        if wasFocused && !isFocused { commitTitle() }
                    }

                HStack(spacing: DS.Space.xs) {
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: DS.FontSize.caption))
                        .foregroundStyle(.secondary)

                    if let urlString = item.sourceURL, let url = URL(string: urlString) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "link")
                                Text({
                                    if let t = item.sourcePageTitle, !t.isEmpty { return t }
                                    return url.host ?? urlString
                                }())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            }
                            .font(.system(size: DS.FontSize.caption))
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(urlString)
                    }
                }

                TextField("メモを追加…", text: $notesText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...2)
                    .font(.system(size: DS.FontSize.caption))
                    .foregroundStyle(.secondary)
                    .onChange(of: notesText) { _, newVal in
                        onUpdateNotes?(item, newVal.isEmpty ? nil : newVal)
                    }
            }
            .frame(minWidth: 260, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                if item.ocrText.isEmpty {
                    Text("テキストなし")
                        .font(.system(size: DS.FontSize.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    HStack {
                        Text("テキスト")
                            .font(.system(size: DS.FontSize.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(displayedOCRText, forType: .string)
                            ocrCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                ocrCopied = false
                            }
                        } label: {
                            Label(ocrCopied ? "コピー済" : "全コピー",
                                  systemImage: ocrCopied ? "checkmark" : "doc.on.clipboard")
                                .font(.system(size: DS.FontSize.caption))
                                .foregroundStyle(ocrCopied ? .green : Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }

                    TextEditor(text: .constant(displayedOCRText))
                        .font(.system(size: DS.FontSize.caption))
                        .scrollContentBackground(.hidden)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.small))
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .layoutPriority(2)
        }
        .padding(DS.Space.s)
        .frame(height: 92)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func commitTitle() {
        onRename?(item, titleText.isEmpty ? nil : titleText)
    }
}
