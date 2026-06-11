# SnapLocal — エージェント向けガードレール

macOS用の完全ローカル・スクリーンショットアプリ(SwiftUI, Swift Package, macOS 14+, 外部依存ゼロ)。
**改善作業は必ず `PLAN.md` のタスク単位で行う。** 着手前に PLAN.md で自分のタスクを確認すること。

## ビルドと検証(全タスク共通の完了条件)

```bash
bash build-app.sh && open .build/debug/SnapLocal.app
```

- 初回起動で画面録画権限ダイアログが出るのは正常(build-app.sh が tccutil reset するため毎回出る)
- **ビルド通過だけでは完了ではない。** アプリを起動し、タスクの受け入れ条件を目視確認してから完了とする
- **このマシンでは `swift test` は動かない**(Command Line Toolsのみで swift-testing/XCTest が無い)。テストは Tests/SnapLocalTests にあり、GitHub Actions(.github/workflows/ci.yml、Xcode入りランナー)で実行される。ローカルで `no such module 'Testing'` が出ても壊したわけではない
- コミットは1タスク1コミット。`feat:` / `refactor:` / `fix:` プレフィックス。PLAN.md のチェックボックス更新を同コミットに含める

## 絶対原則(違反は即やり直し)

1. **完全ローカル** — ネットワーク通信・外部API・テレメトリのコードを一切書かない
2. **外部依存ゼロ** — Package.swift に依存を追加しない。Apple純正フレームワークのみ
3. **セキュリティ** — entitlements を増やさない。Info.plist の権限追加は事前にユーザー承認が必要
4. **軽量UX方針** — 機能の新規追加より整理・隠蔽を優先。表面に出すコントロールは最小限(Gyazoが手本)。新機能の提案はタスク外なら PLAN.md への追記提案に留める
5. **機能を勝手に削除しない** — 「隠す」はOK、「消す」はNG。全機能にショートカットかメニューからの到達経路を残す

## 作業プロトコル(スコープ制御)

- **1セッション = PLAN.md の1タスク。** 隣のコードが気になっても直さない。気づきは PLAN.md の進捗ログに1行記録するだけ
- Phase 0 のタスクは**振る舞い変更ゼロ**(機械的移動のみ)。リネーム・整形・「ついでの改善」を混ぜない
- diffの目安: 機械的移動を除き、1タスク400行以内。超えそうならタスクを分割提案して停止
- PLAN.md 内の行番号は古い可能性がある。**必ずシンボル名で grep して現在位置を特定**してから編集する
- デザイン値(padding/角丸/フォント/アニメーション時間)は `DesignTokens.swift` の `DS.*` のみ使用。新しい数値・durationを発明しない(T0.1完了後)

## 既知の落とし穴(過去に実際に壊れた箇所)

### canvasSize の所有権 — 最重要
`canvasSize` は `AnnotationCanvasView` の GeometryReader が管理し、値は**表示画像サイズ(画像アスペクトに一致した fit、T7.3)**。
**`SnapLocalState.acceptCapture()` や `resetAndLoad()` で canvasSize を上書きしてはいけない。**
アノテーションはview座標(0..canvasSize)で記録されるため、画像ピクセルサイズで上書きすると全アノテーションがズレる。
例外: `resizeCanvas` / `stitch` / `extendCanvas` は処理後にセットしてよい(次のリドローで上書きされる一時値)。
ジェスチャ/ホバーの座標変換は `toCanvas()` 1箇所の漏斗を必ず通す(キャンバスはビューポート中央配置・中心基準で写像)。

### renderAnnotations のストローク描画はコンテキスト反転が前提
CGContext は左下原点・パスはY下向きview座標のため、ストローク描画前の `translateBy(0,imageH)+scaleBy(1,-1)` が必須(無いと書き出しが上下ミラーになる — T7.3で修正済みの実バグ)。テキストは `NSGraphicsContext(flipped: true)`、コンテキストへ画像を再描画する箇所(スポットライト)だけ局所的に反転を戻す。

### NSCursor — SwiftUI の .onHover から呼ぶと OS ごと固まる
`NSCursor.push()` / `.set()` を `.onHover` から呼ぶと、フルスクリーン遷移中に macOS の Space ごとフリーズする(pkill でしか回復不能)。
カーソル変更は **NSViewRepresentable + NSTrackingArea で `cursorUpdate(with:)` を override する方法のみ許可。**

### CoreImage の座標系とマスク合成
- CI座標は Y=0 が下(SwiftUIは上)。renderAnnotations() では `ciY = imageH - viewRect.maxY * scaleY` の反転が必要
- `CGImage.cropping(to:)` は Y=0 が上 → クロップではY反転**不要**
- モザイク/ぼかしマスクは `whiteRect.composited(over: blackBackground)` の順。逆にすると全面黒になる

### AnyAnnotation の transform
`applyTransform` は `self.transform = t.concatenating(self.transform)` で直接変更する。クロージャ内で struct を値コピーすると変更が消える(旧バグ)。

### 永続化互換性
- `AnnotationType` の case 名と raw value、`VaultManifestEntry` のキー名は**変更禁止**(既存ユーザーの履歴・アノテーションが読めなくなる)。キーの**追加**のみ可
- インデックスは月別シャード `index/YYYY-MM.json`(T6.1〜)。旧 `index.json` は初回起動で自動移行され `index.json.bak` として残る(**bakを削除するコードを書かない**)。書き込みは変更があったシャードのみ。クラウド同期の競合コピー(`YYYY-MM (1).json` 等)は読み込み時にマージされ、正規ファイルが重複IDで勝つ
- DrawingTool.redact は UI 統合のみで、AnnotationType は `.mosaic` / `.blur` のまま — この分離を崩さない

### その他
- **Vision 等の完了ハンドラを `@MainActor` 文脈で作らない** — クロージャが MainActor 隔離を継承し、フレームワークのバックグラウンドキューから呼ばれた瞬間に Swift 6 の動的隔離検証で SIGTRAP(T9.4 の実クラッシュ)。`nonisolated` な関数/型に置く(`OCRService` が正解形)
- `handleDragEnd` 冒頭で `dragState.end()` が呼ばれる。crop モード等のブロック内で二重に呼ばない
- background mutation 関数は `registerBackgroundUndo` → `recomputeAllFilterPreviews()` → `objectWillChange.send()` の順序を崩さない
- `CIContext.createCGImage()` はメインスレッド実行。重い処理を足すときは注意
- APFS はケース非感知。Package.swift に大文字小文字違いの製品名を作らない

## ファイル構成

| ファイル | 役割 |
|---|---|
| `App.swift` | App/AppDelegate、SnapLocalState本体(メインVM)、ContentView |
| `StateCapture/StateHistory/StateExport/StateVision.swift` | SnapLocalState の extension(撮影/履歴/書き出し/OCR・顔検出) |
| `Toolbar.swift` | CompactToolbar |
| `HistoryRail.swift` | 履歴サイドバー(グリッド) |
| `Sheets.swift` | 設定・ヘルプ |
| `DesignTokens.swift` | DS.* デザイントークン |
| `AnnotationModels.swift` | アノテーション関連の型定義(AnnotationType/DrawingTool/DragState 等) |
| `AnnotationCanvas.swift` | CanvasViewModel本体(状態・CRUD・undo・テキスト入力) |
| `CanvasRendering.swift` | CanvasViewModel extension: renderAnnotations()/フィルタプレビュー |
| `CanvasImageOps.swift` | CanvasViewModel extension: クロップ・回転・リサイズ・結合 |
| `CanvasInteraction.swift` | CanvasViewModel extension: ドラッグ状態機械・注釈生成 |
| `CanvasView.swift` | AnnotationCanvasView(キャンバスUI本体) |
| `CanvasHelpers.swift` / `CanvasOverlays.swift` | キャンバス補助NSView類 / 選択ハンドル・クロップ等のオーバーレイ |
| `AnyAnnotation.swift` | アノテーションの型消去ラッパー+Codable(デコード分岐) |
| `AnnotationElements.swift` / `AnnotationMosaicBlur.swift` | 各アノテーション struct(後者は統合後の RedactAnnotation = .mosaic/.blur 両対応) |
| `PersistentVault.swift` | ディスク永続化 + OCRService |
| `HistoryQuickLook.swift` | 履歴のQuickLookプレビュー |
| `RegionCapture.swift` | 領域選択オーバーレイ(CGRectを返すだけ。キャプチャはしない) |
| `CaptureEngine.swift` | ScreenCaptureKit キャプチャ |
| `Settings.swift` | SettingsManager |
| `Utilities.swift` | 共通小ユーティリティ(R2.2) |

## 完了時のチェックリスト

- [ ] `bash build-app.sh` 通過
- [ ] アプリ起動 + タスクの受け入れ条件を目視確認
- [ ] ライト/ダーク両モード確認(UI変更時)
- [ ] PLAN.md のチェックボックス更新 + 進捗ログに1行追記
- [ ] 1コミットにまとめてコミット(メッセージは日本語可、プレフィックス必須)
