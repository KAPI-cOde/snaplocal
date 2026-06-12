# SnapLocal 改善計画 — 「世界一優れたUXと美しいデザイン」への道筋

> **このドキュメントの使い方(実行エージェント向け)**
> 1セッション = 1タスク。タスクIDを1つ選び、そのタスクだけを完了させる。
> 着手前に `CLAUDE.md`(ガードレール)を必ず読むこと。
> 完了したらこのファイルのチェックボックスを `[x]` にし、`feat:`/`refactor:`/`fix:` プレフィックスでコミットする。
> タスク内の行番号は書いた時点のもの。**必ずシンボル名(struct/関数名)で再検索して位置を特定する。**

## 北極星

**「無料のCleanShot X + Gyazoをローカルで動かす、UXが最高のOSSアプリ」**

- 表面はGyazoのように軽く、機能は奥に隠す(機能追加より整理を優先)
- 「動く」ではなく「気持ちいい」が合格基準
- 完全ローカル・外部依存ゼロ・最小entitlementsは絶対条件

## 現状診断(2026-06-10 時点)

| 領域 | 状態 | 問題 |
|---|---|---|
| デザイントークン | ❌ なし | padding 10種類以上、角丸 3〜8px、フォント 6〜48pt がアドホックに散在 |
| コード構造 | ⚠️ モノリス | App.swift 5,104行(CompactToolbar だけで約1,000行) |
| アニメーション | ⚠️ 疎ら | ズームは良いが、ツール切替・選択・履歴ハイライトが無遷移で唐突 |
| ボタンスタイル | ⚠️ 不統一 | .borderless / .plain / .borderedProminent / .link が混在、意味づけなし |
| ダークモード | △ ほぼOK | システムカラー依存。オーバーレイの `.white`/`.black` 直書きが数カ所 |
| HistoryRail | ⚠️ 旧式 | 68×46pxの縦リスト。Gyazo風グリッドは未着手(ロードマップ既載) |
| 空状態 | △ 最低限 | 撮影ボタン+ショートカット4行のみ。美しさの演出なし |
| サムネイル | ⚠️ 性能 | キャッシュなし、毎回ディスク読み込み |

## フェーズ構成

```
Phase 0  基盤整備      — トークン定義 + App.swift分割(振る舞い変更ゼロ)
Phase 1  視覚的一貫性  — トークン移行・スタイル統一(美しさの土台)
Phase 2  マイクロインタラクション — 全状態変化にフィードバック(気持ちよさ)
Phase 3  表面の軽量化  — Gyazo級のシンプルさ・空状態の美化
Phase 4  履歴のGyazo化 — グリッド表示 + サムネイルキャッシュ
Phase 5  仕上げ        — ドッグフーディング監査・性能・OSS見栄え
```

依存関係: Phase 0 → 1 → 2 は順番厳守。Phase 3 と 4 は Phase 1 完了後なら並行可。Phase 5 は最後。

---

## Phase 0: 基盤整備(振る舞い変更ゼロのリファクタ)

> このフェーズの全タスクは**見た目も挙動も1pxも変えない**。ビルド通過+起動確認が検証のすべて。

### [x] T0.1 DesignTokens.swift の新設(定義のみ、移行はしない)
- **ファイル**: 新規 `Sources/SnapLocalApp/DesignTokens.swift`
- **内容**: `enum DS` 名前空間に以下を定義する:
  - `DS.Space`: 4, 8, 12, 16, 24, 32 の6段階(`xxs/xs/s/m/l/xl`)
  - `DS.Radius`: 4(small), 8(medium), 12(large)の3段階
  - `DS.FontSize`: caption2(9), caption(11), body(13), title(18) の4段階
  - `DS.Anim`: `fast`(0.12s easeIn), `base`(0.15s easeOut), `smooth`(0.2s easeInOut) の3種(`Animation`型で定義)
  - `DS.Shadow`: `overlay`(radius 4, y 2), `canvas`(radius 12, y 4) の2種
- **受け入れ条件**: 新ファイルが存在しビルド通過。**既存コードは1行も変更しない**(使用箇所ゼロでOK)
- **ガード**: 既存の `AnnotationColor`(8色パレット)はVault永続化に関わるため触らない

### [x] T0.2 CompactToolbar を Toolbar.swift へ抽出
- **ファイル**: App.swift → 新規 `Sources/SnapLocalApp/Toolbar.swift`
- **手順**: `struct CompactToolbar` とそれが専有するヘルパー(normalControls / annotationToolControls / imageEditControls / 各ポップオーバー)を機械的に移動。`private` で他から参照されないものだけを一緒に移す
- **受け入れ条件**: ビルド通過、起動して画像なし/ありの両状態でツールバーが従来通り表示される。App.swiftの行数が約1,000行減る
- **ガード**: 移動のみ。リネーム・整形・ロジック変更は一切しない(diffが純粋な移動に見えること)

### [x] T0.3 HistoryRail を HistoryRail.swift へ抽出
- **ファイル**: App.swift → 新規 `Sources/SnapLocalApp/HistoryRail.swift`
- **手順**: `HistoryRail` / `HistoryItemRow` / 履歴ポップオーバー(HistoryItemPopover)を機械的に移動
- **受け入れ条件**: ビルド通過、履歴の表示・検索・スター・コンテキストメニューが従来通り動く
- **ガード**: T0.2 と同じ(移動のみ)

### [x] T0.4 SettingsSheet・HelpPopover・WindowPickerSheet を Sheets.swift へ抽出
- **ファイル**: App.swift → 新規 `Sources/SnapLocalApp/Sheets.swift`
- **受け入れ条件**: ビルド通過、設定・ヘルプ・ウィンドウピッカーが開ける
- **ガード**: 移動のみ。完了時 App.swift は概ね 2,500行以下になっているはず

---

## Phase 1: 視覚的一貫性(美しさの土台)

> 各タスクで「トークンに置き換えた結果、近い値は段階に吸着させる」(例: padding 5→4、10→8、14→16)。
> 吸着で見た目が微妙に変わるのは**意図された変更**。ただし1タスク内で変えるのは対象ファイルのみ。

### [x] T1.1 Toolbar.swift のトークン移行
- **対象**: Toolbar.swift 全体の padding / cornerRadius / font / shadow を `DS.*` に置換
- **受け入れ条件**: Toolbar.swift 内に裸の数値 padding・cornerRadius が残らない(アイコンサイズ等の機能的数値は除く)。ビルド通過+目視で崩れなし
- **ガード**: ボタンの並び順・表示条件は変えない

### [x] T1.2 HistoryRail.swift のトークン移行
- **対象**: 同上を HistoryRail.swift に適用
- **ガード**: サムネイルサイズ 68×46 は T4.1 で変えるので**ここでは触らない**

### [x] T1.3 Sheets.swift + App.swift 残部のトークン移行
- **対象**: 設定・ヘルプ・空状態・ステータスチップ・ズームインジケータ等
- **受け入れ条件**: リポジトリ全体で `cornerRadius: <数値>` を grep して、残っているのは意図的なもの(アノテーション描画など画像出力に関わる値)だけ

### [x] T1.4 セマンティックボタンスタイルの導入
- **ファイル**: DesignTokens.swift に追記
- **内容**: `DSPrimaryButtonStyle`(borderedProminent相当・主要アクション用)、`DSToolButtonStyle`(ツールバーアイコン用: 選択状態の背景・ホバー・押下スケール0.96を内包)を `ButtonStyle` として定義し、Toolbar.swift の全ボタンに適用
- **受け入れ条件**: ツールバー内のボタンが全て統一スタイル経由。選択中ツールの強調表示が従来同等以上に明瞭
- **ガード**: キーボードショートカット・helpテキストを消さない

### [x] T1.5 ダークモード監査
- **手順**: `Color.white` / `Color.black` / `.white.opacity` / `.black.opacity` を全grep。「画像の上に重なるオーバーレイ」(寸法バッジ・ルーペ等)は白黒固定が正解なので残す。「UI面上の要素」はセマンティックカラーへ置換
- **受け入れ条件**: ライト/ダーク両モードでスクリーンショットを撮り(本アプリで!)、視認性の問題ゼロ
- **ガード**: アノテーションの描画色(AnnotationColor)は画像に焼き込む色なので絶対に触らない

---

## Phase 2: マイクロインタラクション(「気持ちいい」の実装)

> すべて `DS.Anim` のトークンを使う。新しいdurationを発明しない。
> 派手さは不要。**唐突さをゼロにする**のが目的。

### [x] T2.1 ツール選択のフィードバック
- **内容**: ツールバーのツール切替時、選択背景が `DS.Anim.base` でフェード/スライドする。`matchedGeometryEffect` で選択インジケータを滑らかに移動させるのが理想
- **受け入れ条件**: ツールをキー(A/R/E/T等)とクリックの両方で切り替えてアニメーションすること

### [x] T2.2 アノテーション選択・選択解除の遷移
- **対象**: AnnotationCanvas.swift の選択ハンドル表示
- **内容**: 選択ハンドル+外接ボックスの出現/消滅に `DS.Anim.fast` のフェード+軽いスケール(0.9→1.0)
- **ガード**: ドラッグ追従(リサイズ・移動中)にはアニメーションを**かけない**(遅延して見えるため)。出現/消滅のみ

### [x] T2.3 履歴アイテムの選択ハイライト
- **内容**: HistoryRail のアイテム選択時、ハイライト枠を `DS.Anim.base` で遷移。ホバー時に軽い持ち上がり(scale 1.02 か明度変化)
- **ガード**: スクロール性能を落とさない(LazyVStack内で重い modifier を使わない)

### [x] T2.4 コピー/保存成功のフィードバック統一
- **内容**: ⌘C・⌘S・各コピー操作の成功時、既存のステータスチップ表示に統一されたチェックマーク遷移(symbolEffect か opacity+scale)を付与。「コピー済」テキスト切替だけの箇所も同じ遷移に揃える
- **受け入れ条件**: コピー成功が「見れば分かる」こと。5秒後の自動消滅は既存挙動を維持

### [x] T2.5 サイドバー・ポップオーバー開閉の遷移統一
- **内容**: サイドバートグル・カラーポップオーバー・調整パネルの開閉を `DS.Anim.smooth` に統一
- **ガード**: ポップオーバー自体はNSPopover由来のシステム遷移なので無理に変えない。中身の状態変化のみ

---

## Phase 3: 表面の軽量化(Gyazo級のシンプルさ)

### [x] T3.1 ツールバー表示数の監査と削減
- **手順**: ①画像なし ②画像あり・選択なし ③アノテーションツール使用中 ④クロップ中 の4状態で、常時表示されるコントロール数を数えて記録する。②の状態で**アイコン12個以下**を目標に、低頻度機能をオーバーフローメニュー(`…` ボタン)へ移す
- **受け入れ条件**: 機能は1つも削除しない(隠すだけ)。全機能にメニューバーかショートカットからの到達経路が残る
- **ガード**: 削減候補はユーザー確認を経ること — このタスクは「監査レポート+提案」をPLAN.mdの下に追記して終了し、実際の移動は承認後の T3.2 で行う

### [x] T3.2 ツールバー削減の実施(T3.1の承認後)
- **内容**: T3.1 で承認された移動のみ実施
- **受け入れ条件**: 4状態すべてで目視確認。ショートカット全動作

#### T3.1 監査結果(2026-06-10)— **ユーザー承認待ち**

| 状態 | 常時表示コントロール数 | 評価 |
|---|---|---|
| ① 画像なし | 7(撮影3+撮影メニュー+ヘルプ+設定+履歴) | ✅ 良好 |
| ② 画像あり・選択なし | **約28** | ❌ 目標12の2倍超 |
| ③ ツール使用中 | 28+ツール別オプション(最大+4) | ❌ |
| ④ クロップ中 | 9(専用バー) | ✅ 良好 |

**状態②の内訳**: 撮影系4 / ツール6+ellipsisメニュー+カラー1 / 画像編集4(crop・調整・装飾・回転メニュー) / 書き出し9(OCR・コピー・保存・共有メニュー・undo・redo・削除・表示切替・テンプレメニュー) / 右端3(ヘルプ・設定・履歴)

**削減提案(機能削除なし、すべて到達経路維持)**:
| # | 対象 | 移動先 | 削減後の到達経路 | 根拠 |
|---|---|---|---|---|
| A | undo / redo (2個) | 非表示(隠しボタン化) | ⌘Z / ⌘⇧Z + メニューバー | 標準ショートカットが浸透済み。Gyazoには無い |
| B | 削除 (trash) | 選択中のみ表示(контекスト化) | ⌫キーは常時有効 | 選択なしでは無効ボタンの視覚ノイズ |
| C | テンプレートメニュー | 「…」オーバーフローへ | …メニュー内 | 低頻度機能 |
| D | 回転/リサイズ/結合メニュー(photo) | 「…」オーバーフローへ | …メニュー内 | 低頻度。crop/調整/装飾は残す |
| E | ヘルプ (?) | 設定シート内へリンク | 設定→ヘルプ、ショートカットは⌘,経由 | 初学者以外は不要 |
| F | アノテーション数バッジ | 選択時のみ表示 | 同左 | 常時表示の必要性薄 |

**承認された場合の状態②**: 撮影4+ツール7+カラー1+画像編集3+書き出し4(OCR・コピー・保存・共有)+「…」+設定+履歴 = **約13個**(OCRは条件付きなので実質12)

> 注: 「…」オーバーフローメニューを新設し、テンプレート・回転リサイズ・(承認次第)その他低頻度機能を収容する。

### [x] T3.3 空状態(初回起動画面)の美化
- **内容**: 現状のカメラアイコン+ボタン+ヒント4行を、余白とタイポグラフィを活かした構成に再設計。アプリアイコン or 控えめなイラスト的要素 + 主要ショートカットを美しいキーキャップ風表示(角丸+subtle border)で
- **受け入れ条件**: 初見で「丁寧に作られたアプリ」と感じられること。情報量は増やさない(むしろ減らす)
- **ガード**: 権限未許可時の導線(画面収録の許可リンク)は必ず残す

### [x] T3.4 設定画面の整理
- **内容**: 6セクションの並び順を使用頻度順に見直し、各項目に1行説明(`.caption` + `.secondary`)を付ける。フォームスタイルは `.grouped` のまま
- **受け入れ条件**: 全設定項目が説明なしでも理解できる表示になる

---

## Phase 4: 履歴のGyazo化

### [x] T4.1 HistoryRail のグリッドレイアウト化
- **内容**: 縦リスト(68×46)を `LazyVGrid` の2列グリッド(サムネイル約110×74、`DS.Radius.medium`)に変更。日付グループヘッダは維持。サイドバー幅は固定値を見直して2列が収まる幅に
- **受け入れ条件**: 100枚以上の履歴でスクロールが滑らか。選択・スター・コンテキストメニュー・⌘↑↓ナビゲーション・ドラッグアウトが全て動く
- **ガード**: index.json のスキーマは変えない。ポップオーバーの表示位置がグリッドセルと重ならないこと

### [x] T4.2 サムネイルのメモリキャッシュ
- **対象**: PersistentVault.swift
- **内容**: `NSCache<NSString, NSImage>` でサムネイルをキャッシュ(コスト=ピクセル数、上限約50MB)。削除・上書き時にinvalidate
- **受け入れ条件**: スクロール時のディスクI/Oが減る(Instrumentsまたはログで確認)。メモリが無制限に増えない
- **ガード**: キャッシュmiss時の挙動は現状と同一。index.json には触らない

### [x] T4.3 グリッドのホバー体験
- **内容**: ホバー時にオーバーレイでクイックアクション(コピー/スター)を表示、既存の400ms遅延ポップオーバーはグリッドに合う位置(.trailing)に調整
- **ガード**: T2.3 のアニメーショントークンを再利用。新しいdurationを作らない

---

## Phase 5: 仕上げ

### [x] T5.1 ドッグフーディング監査(エージェント実施可能分)
- **手順**: 本アプリ自身で「撮影→注釈→コピー→Slack貼り付け相当」「撮影→クロップ→保存」「履歴検索→再編集」の3フローを実際に通し、引っかかり(クリック数・迷い・視線移動)を `PLAN.md` 末尾に記録。修正はしない(発見のみ)
### [x] T5.2 監査結果の修正(発見された問題を新タスク化して実施)
### [x] T5.3 性能パス(自動計測分 — 実機での大規模履歴計測は将来)
- **内容**: 大画像(5K)+アノテーション30個でのCIフィルタプレビュー再計算、起動時の履歴ロードを計測。閾値超え(起動>1秒、操作応答>100ms)があれば修正
### [x] T5.4 README のスクリーンショット刷新
- **内容**: 新UIのスクリーンショットを本アプリで撮影し(書き出し装飾のグラデーション背景を使用)、READMEに反映。OSSとしての第一印象を整える
- **完了(2026-06-10)**: 実履歴は公開不可のため、合成デモvault方式で実施。①架空ダッシュボード画像をCoreGraphicsで生成 ②一時vaultに3件seed(注釈: 赤枠+矢印+テキスト、スター、日付グループ)③起動引数 `-vault.directory.override <path>`(新設、UserDefaults argument domain)で隔離起動 ④`screencapture -l <windowID>` で背面のままウィンドウ撮影 → `docs/screenshot-main.png` ⑤README冒頭に反映。実vault・実設定は無変更

---

## Phase 6: 大規模アーカイブ対応(Google Drive 永続アーカイブ前提)

> 想定ユースケース: Google Drive 上の vault に数年単位で撮り溜め(年〜1万枚)、「あの画像どこだっけ」を OCR 検索で探す。
> 検索が index 内テキストだけで完結する現構造(画像ファイル非依存)は維持する。
> 着手前の推奨(ユーザー作業): 数十枚溜まった時点で日本語スクリーンショットの検索ヒット感をドッグフーディング確認。OCR品質の問題は1万枚溜まってから直すと痛い

### [x] T6.1 インデックスの月別シャーディング
- **内容**: 単一 `index.json` を `index/YYYY-MM.json` に分割。書き込みは当月シャードのみ(過去月は不変 → Drive の差分同期が効き、毎キャプチャの全量再アップロードを解消)。起動時は全シャードを読んでマージ
- **移行**: 旧 `index.json` が存在すれば初回起動時に自動分割。旧ファイルは `index.json.bak` として残す(削除しない)
- **ガード**: `VaultManifestEntry` の既存キー名・値形式は変更禁止(キーの追加のみ可)。シャード内のエントリ形式は現行と同一。cleanOrphans の安全ガード(manifest 空なら何もしない)がシャード読み込み失敗時にも機能すること
- **受け入れ条件**: 既存 vault が無損失で移行され、撮影→保存で当月シャードだけの mtime が変わる。移行・分割書き込みの CI テストを追加

### [x] T6.2 検索の軽量パス+デバウンス
- **内容**: `search()` をテキストのみの軽量スキャンに変更 — `annotationsData` の全件 JSON デコードとサムネイル読みを検索パスから排除する。検索フィールドに約200msのデバウンス(UIアニメーションではない機能値なので DS.Anim 対象外)
- **アノテーションテキスト検索の維持**: 保存時に検索用平文を別キー(追加のみ・既存キー変更なし)へ併記する等で、デコードなしに検索可能にする
- **受け入れ条件**: 1万件相当の合成 manifest で検索応答 <100ms(CI に計測テスト追加)。検索結果の内容・表示は現状と同一
- **ガード**: index スキーマはキー追加のみ。既存ユーザーの履歴が旧形式のまま読めること

---

## Phase 7: コア導線の信頼性(2026-06-10 監査で発見)

> 監査方法: 合成デモvault(`-vault.directory.override`)で実起動し、スクリーンショットのピクセル走査で表示実寸を計測。
> コア導線「撮る→カットする→注釈→保存→自動OCR→検索」のコード検証も実施。
> 自動OCR・タイトル自動設定・月別シャード・軽量検索は仕様通り動作を確認済み。問題は以下の3領域。

### [x] T7.1 ズーム・フィット表示系の修正
- **症状(すべて実機で再現確認済み)**:
  1. 起動時の自動復元で画像が42%表示(1440×870ウィンドウで537pt幅)。原因: ウィンドウフレーム復元前の canvasSize(600×400=minWidth/minHeight)でフィット計算され、その後再計算されない
  2. 小さい画像(800×600px)を開くと**ツールバーを覆い隠してUI外まで溢れる**。原因: scaledToFit でビューポートまで拡大したベースにさらに zoom>1 を掛ける + `.clipped()` なし
  3. フィット計算が `canvasSize(pt) ÷ 画像(px)` の単位混在。ベースが scaledToFit 済みなので「フィット= zoom 1.0」が正しく、現式は典型サイズで偶然それらしく見えるだけ
  4. ⌘F が三重割当(メニュー=フィット / キャンバス642行=フィット / キャンバス719行=検索フォーカス)。メニューが先取りするため検索フォーカスは死んでいる
  5. 「実寸 (100%)」(⌘0)は実際にはフィット表示。ズームバッジの%もRetina実ピクセルと無関係
- **修正方針**: zoom の意味は「fitベースへの倍率」のまま変えない。`naturalZoom = 1/(backingScale×fitScale)` を導入し、①読み込み時は「実寸、収まらなければフィット」(zoom≤1なので溢れない) ②canvasSize変化時、ユーザーが手動ズームしていなければ自動再フィット(起動レース解消) ③⌘0=本当の実寸、フィット=⌘9(メニュー維持)、⌘F=検索フォーカス(サイドバー自動表示) ④バッジは実ピクセル比(100%=撮影時と同じ大きさ) ⑤キャンバスに `.clipped()`
- **受け入れ条件**: 起動直後・大画像・小画像貼り付けの3ケースで溢れず適切なサイズ表示。⌘0/⌘9/⌘Fが上記の通り動く。ヘルプ文言一致

### [x] T7.2 画像編集(クロップ・回転・結合)のvault永続化
- **承認済み設計(2026-06-10)**: 「新しいアイテムとして保存」方式。理由(ユーザー): 隠すことが目的ではない・切り抜き前の画像をあとから使いたくなる。**「置き換え方式を設定で選べるようにする」は将来オプション候補**として保留
- **症状**: `confirmCrop()` 等の背景変更はメモリ上のcanvasのみ。vaultの画像ファイルは撮影時のまま不変なので、**履歴から開き直すとクロップが消える**。さらにクロップ時の `annotations.removeAll()` が3秒オートセーブで走り、**既存注釈がvaultからも消える**。クロップ後に付けた注釈は元画像に対してズレて復元される。サムネイルだけは注釈焼き込みで更新されるため「サムネはクロップ済み・開くと元画像」という不整合も起きる
- **提案**: vault に `updateImage(id:image:)` を追加(同一ファイル名へ上書き・width/height更新・サムネ再生成・OCR再実行)。canvas に背景ダーティフラグを設け、注釈と同じ保存タイミング(3秒オートセーブ/切替/終了時)で永続化
- **論点(要ユーザー判断)**: 上書きすると撮影時の元画像はセッション内undo以外で戻せない(破壊的)。代替案=クロップ確定時に新規アイテムとして保存(元画像保全、ただし履歴が2件になる)
- **ガード**: VaultManifestEntry のキー変更禁止(追加のみ)。acceptCapture/resetAndLoad でダーティフラグを必ずリセット

### [x] T7.3 注釈座標系のレターボックスずれ修正(WYSIWYG)
- **症状**: 注釈はビューポート全域(proxy.size)の座標で記録されるが、画像は scaledToFit でレターボックス表示される。書き出しはビューポート全域→画像全域の引き伸ばし写像のため、**ビューポートと画像のアスペクト比が違うほど、描いた位置と書き出し位置がズレる**(1280×800画像/1180×790ビューポートで端部約20px)。ウィンドウリサイズ後の書き出しずれも同根の疑い
- **方針案**: キャンバス(GeometryReader)を画像アスペクトに `.aspectRatio(_:contentMode:.fit)` で一致させ、canvasSize=表示画像サイズにする。既存の保存済み注釈座標の互換性検証が必須(canvasSize比率で再解釈されるため理論上は無害だが要実測)。canvasSize所有権ルール(CLAUDE.md最重要項)に抵触しないよう設計レビューを経て着手
- **注意**: diffが大きくなる場合は分割。T7.1完了後に着手

### [x] T7.4 履歴レールの視覚ノイズ削減
- **内容**: ①全セル常時表示の寸法バッジ(黒地「1280×800」)をホバー時のみに ②サムネイルのレターボックス黒地をセル背景色(secondary系)に ③「昨日」グループ内の各セルにも「昨日 13:25」と重複表示される日付ラベルを時刻のみに
- **ガード**: index スキーマ・サムネイル生成は変えない(表示のみ)
- **完了(2026-06-10)**: ①③実施・実機確認済み。②はサムネイルJPEGに黒地が焼き込まれており「表示のみ」では直せないため見送り(生成変更は既存サムネと混在するため、やるなら再生成込みの別タスク)

### [x] T7.5 ツール調整の使い勝手(ユーザーフィードバック対応)
- **フィードバック(2026-06-10)**: ①矢印が両端`<-->`になっていて変 ②直線・四角・矢印の太さを色選択のようにその場で調整したい ③色選択にスポイトが欲しい
- **対応**: ①両方向矢印の固着バグ修正 — `currentArrowDoubleSided` がUserDefaultsに永続化され、既存の両方向矢印を選択しただけでも didSet で保存されて以後の矢印が全部両端になっていた。永続化を廃止し起動ごとに片側へリセット(トグル自体は残す) ②線を描くツール選択時にツールバーへ S/M/L セグメントをインライン表示(カラーポップオーバー内の既存コントロールと状態共有) ③カラーポップオーバーのカスタムカラー行に NSColorSampler スポイトボタンを追加

### [x] T7.6 パン後の注釈ズレ修正(toCanvas の panOffset 対応)
- **症状(T7.3で記録した既存バグ)**: `toCanvas()`(view→canvas 逆写像の漏斗)が `panOffset` を引いていないため、スクロール/ズームでキャンバスをパンした後に注釈を描く・選択する・ホバーすると、パン量÷zoom ぶん座標がズレる。順写像2箇所(テキスト入力オーバーレイ・配置リップル)は `+ panOffset` 済みで非対称だった
- **修正**: `toCanvas()` に `- panOffset` を追加(逆写像は全ジェスチャ・ホバー・ダブルクリックがこの1箇所を通るため修正もここだけ)
- **受け入れ条件**: パン後のホバー座標バッジが正しい画像ピクセル座標を示す。パン後に描いた注釈が描いた位置に表示・書き出しされる。パンなし(panOffset=0)の挙動は完全不変

---

## Phase 8: ⌘⇧4 ネイティブ化ピボット(2026-06-11 ユーザー指示)

> **方向**: mac標準⌘⇧4の操作感 + Gyazo/CleanShot流の自動化を基本導線にする。
> 「⌘⇧4 → 素のクロスヘアで選択 → マウスを離した瞬間に撮影 → 画面中央に軽量注釈パネル → 完了(⌘↩/ボタン)で**注釈込み**画像をクリップボード+保存確定(OCRは既存の自動実行)」。
> **ユーザー決定(2026-06-11)**: ①ルーペは完全削除(コードごと。明示承認済みのため原則5の例外) ②注釈は既存キャンバス流用の軽量フローティングパネル(メインウィンドウは出さない) ③完了=⌘↩+完了ボタン、Escは注釈保持のままパネルを閉じるだけ(クリップボードは撮影時の素画像のまま)。

### [x] T8.1 選択オーバーレイのネイティブ化(ルーペ削除+release即撮影)
- LoupeView / loupePanel / loupeView / setupLoupe / updateLoupe を完全削除(ユーザー承認済み)
- 新規ドラッグは mouseUp で即 commit(`.adjusting` を経由しない)— mac標準と同じ
- `initialRect`(前回範囲の再選択)起動時のみ `.adjusting`+ハンドル+Enter確定を維持(機能削除しない)
- クリック=ウィンドウスナップ(pendingWindowSnap)・ESC・⌘⇧4トグルは現状維持
- ドラッグ中の選択サイズpx表示はルーペ内のみだった場合、選択枠近くの小バッジに移植(mac標準にもある)
- **受け入れ**: ⌘⇧4→ドラッグ→離す→即シャッター。ルーペが一切出ない(grep Loupe ゼロ)。再選択パス・スナップ・ESCは従来どおり

### [x] T8.2 中央フローティング注釈パネル+完了アクション
- 撮影後、メインウィンドウではなくフローティングパネル(NSPanel)を画面中央に表示。AnnotationCanvasView + CanvasViewModel を流用(**canvasSize所有権ルール厳守 — メインセッション直轄**)
- 表示サイズ: 撮影実寸、画面の約70%を超えるなら縮小フィット
- 完了=⌘↩ or パネルの「完了」ボタン → 注釈込みレンダをクリップボード+保存確定+パネル閉じ。Esc=注釈保持のまま閉じるだけ
- メインエディタへの到達経路は残す(パネル内「エディタで開く」等 — 機能削除しない)
- vault保存+自動OCRは既存 acceptCapture 経路のまま変更しない
- **受け入れ**: ⌘⇧4→ドラッグ→離す→中央にパネル→注釈→⌘↩→ペースト先に注釈込み画像、履歴に保存済み・OCR済み

### [x] T8.3 ショートカット衝突の解消オプション(ユーザーFB起点で再定義)
- **背景**: ⌘⇧4 は Carbon ホットキーでも mac標準スクショと**両方発火**する(発見: 2026-06-11 実機FB)。「変な挙動」の正体はこの二重発火
- **実装**: 設定>ホットキーに「⌘⇧4 を SnapLocal の範囲選択にする」トグル(既定オン)
  - オン: 私的CGS API(`CGSSetSymbolicHotKeyEnabled`、ID 30)で mac標準の範囲スクショを**起動中だけ**無効化(再ログイン不要・即時)。⌘Q で必ず復元、毎起動時に再適用
  - オフ: mac標準を復元し、SnapLocal の範囲選択は ⌥⌘4 に切替(エンジンの領域ホットキーを即時再登録)
  - メニューバーの表記も ⌘⇧4/⌥⌘4 に動的追従
- **既知の制限**: 強制終了(SIGKILL等)時は復元が走らず、次回起動または再ログインまで mac標準⌘⇧4 が無効のまま
- ついで: パネル表示中のペースト/ドロップで HUD が併出する問題を修正(isVisible ガード)

### [x] T8.5 ウィンドウスナップ矩形の画面外クランプ(ユーザーFB 2026-06-11)
- **症状**: ウィンドウ撮影スナップが `CGWindowListCopyWindowInfo` のウィンドウ全体 bounds をそのまま使い、画面外へはみ出した部分・負座標まで選択枠に含めていた(端に寄せた/別画面に跨るウィンドウで顕著)
- **修正**: `windowRectAt` でカーソルのある画面の `frame` と intersection し、見えている範囲だけをスナップ対象に(20pt 未満になる場合は元矩形へフォールバック)。座標系が絡むため Fable 5 直接実装

### [x] T8.6 開発ビルドの画面録画権限が毎回失効する問題(ユーザーFB 2026-06-11)
- **症状**: build-app.sh のアドホック署名でビルド毎にバイナリハッシュが変わり TCC が権限を黙って失効 → 毎回 tccutil reset でプロンプト再表示していた = 毎回承認が必要
- **修正**: 安定した自己署名コード署名証明書「SnapLocal Dev Cert」で署名すれば designated requirement がハッシュ非依存になり権限が再ビルドをまたいで保持される。`setup-signing.sh`(一度きり・sudo不要・全アプリ開放-Aはしない・SnapLocal専用ローカル鍵・ネットワークなし)を新設。build-app.sh は「証明書があれば安定署名+resetなし / なければ従来のアドホック+reset」に分岐(証明書未作成時の挙動は不変)
- **ガード**: entitlements は不変(署名IDのみ。CLAUDE.md原則3に抵触せず)。キーチェーン操作はユーザーが setup-signing.sh を実行して承認(自動実行は分類器がブロック=妥当)
- **残**: ユーザーが `./setup-signing.sh` 実行 → 一度だけ `bash build-app.sh`+権限許可 → 以後保持、を実機確認

### [x] T8.4 導線整理の残り(小粒)
- パネル内 CompactToolbar のサイドバートグルが無意味(非表示化 or パネル用に間引き)
- 完了/コピー時の statusChip がメインウィンドウ非表示中は見えない(パネル内に出すか通知に寄せる)
- openEditorOnCapture / autoCopyOnCapture とヘルプ文言の最終整合

### [x] T8.7 全画面撮影→パネルで範囲選択=即クロップ(ユーザーFB 2026-06-11)
- **背景**: ⌘⇧2(全画面)→中央パネルは好評。「その後に範囲を選択したらそこが切り抜かれるようにしたい」
- **実装**: 全画面撮影経由でパネルが開くときだけクロップモードで開始し、ドラッグを離した瞬間に `confirmCrop()`(release=即コミット、⌘⇧4ピボットと同じ原則)。`CanvasViewModel.autoConfirmCropOnDragEnd` フラグ+`SnapLocalState.fullScreenCapturePending`(acceptCaptureで消費、範囲/ウィンドウ撮影の入口で必ず倒す)
- Esc=クロップモード解除して全画面のまま注釈(パネルは2回目のEscで閉じる)。クリックのみ(ドラッグなし)もクロップスキップ。⌘Zでクロップ取り消し可。⌘⇧4/ウィンドウ/ペースト/ドロップ経路は不変
- **受け入れ**: ⌘⇧2→パネル中央表示(ツールバーがクロップUI)→範囲ドラッグ→離す→即その範囲に切り抜き→注釈ツールへ復帰

### [x] T8.8 ウィンドウスナップの不可視ウィンドウ除外(ユーザーFB 2026-06-11)
- **症状**: ⌘⇧4 のウィンドウスナップで「表示されていないウィンドウ」が候補にハイライトされる
- **原因**: `windowRectAt` が `kCGWindowAlpha` を見ておらず、画面上に存在するが完全透明のヘルパーウィンドウ(Electron系等)がカーソル直下の最前面ヒットになっていた
- **修正**: guard に `alpha > 0.05` を追加(optionOnScreenOnly・layer==0・サイズ>20・画面クランプは不変)

### [x] T8.9 設置済み注釈のその場リサイズ・太さ変更(ユーザーFB 2026-06-11)
- **背景**: 「一回設置したアノテーションのサイズを変えたい、線の太さも」。リサイズ機構(角ハンドル/矢印・直線の端点/吹き出し尻尾)と太さの選択適用は select ツール限定で実装済みだったが、描画ツールのまま注釈をつかむ通常導線からは到達不能だった
- **実装**: ①新規注釈を addAnnotation で自動選択(描いた直後に太さ/色変更が効く — 適用配線 applyCurrentLineWidthToSelection は既存) ②ハンドルのヒットテストを beginHandleDragIfHit() に抽出し grab-move 対応ツールでも発動 ③ハンドルドラッグの更新・確定(undo登録)を select ゲートの外へ巻き上げ(ツール非依存化、select の挙動は等価) ④ハンドル描画条件を select‖supportsGrabMove に拡張
- **受け入れ**: 矢印を描く→端点ハンドルが出る→端点ドラッグで伸縮/本体ドラッグで移動/空き地ドラッグで新規描画。太さコントロールが選択中注釈に反映。Escで選択解除。selectツールの挙動不変
- **fix(同日FB)**: 描画直後の自動選択はハンドル非武装(selectionIsFromCreation)で乗っ取り解消・純クリックで注釈の選び直し(タップ選択+スタイル同期)

### [x] T8.10 ツールバーの視覚再デザイン(ユーザーFB 2026-06-11、承認済み)
- **背景**: 「ごちゃついていてよくわからない。大きさもバラバラでダサい。世界一のアプリはこんなデザインじゃない」(スクリーンショットFB)。太さセグメント(S/M/L/XL)とフォントサイズセグメント(S/M/L)が同時に並んで同じ見た目=判別不能、コントロールの高さ/アイコンサイズ不揃い、色スウォッチだけ突出
- **方針案**: ビットマップアイコン生成は不要(SF Symbolsがベクター・ダークモード対応で最適。生成画像はかえって浮く)。直すのはレイアウトの規律:
  - 全コントロールの高さ・SF Symbolポイントサイズ・余白を DS.* で統一
  - ツール群/スタイル群/アクション群をセパレータで分節
  - **状況依存表示**: 太さは線系ツール・選択時のみ、フォントサイズはテキスト系のみ(同時に2つのセグメントを並べない)。並ぶ場合もラベルで区別がつく表示に
  - 色スウォッチの小型化・整列
- **受け入れ**: ライト/ダーク両モードのスクリーンショットでビフォーアフター比較、コントロール数は増やさない(軽量UX原則)
- **実装(2026-06-11)**: DS.Toolbar トークン新設(高さ28/セパレータ18/メニュー幅22/グループ間6・内2/スライダー60/スウォッチ16)+DSToolToggleStyle(トグル4個を28×28のツールボタン同等見た目に)。太さセグメントは `usesLineWidth && tool != .text` に変更し双子セグメント解消、各セグメントに10pt補助アイコン(lineweight/textformat.size)。スウォッチは二重リング→16pt円+ヘアライン(DSToolButtonStyle枠内)。全Divider高さ・全セグメント controlSize(.small)・メニュー幅/高さ・spacing を統一。分節は [撮影]|[ツール]|[スタイル(太さ・文脈・色)]|[画像編集]…[書き出し]。コントロール増減ゼロ

### [x] T8.11 リサイズハンドルのホバーカーソル(ユーザーFB 2026-06-11)
- **背景**: 「四角のアノテーションの四隅にカーソルを合わせて大きさを変えられるとき、マウスカーソルの形状が変わって欲しい」。ハンドル別カーソル(対角/上下/左右)は updateCursor() に実装済みだが select ツール限定で、T8.9 で描画ツールに開放したハンドル操作にカーソルが未追従。端点(9/10)・吹き出し尻尾(8)は select でも crosshair のままの未仕上げもあり
- **方針**: CanvasView.swift のみ。hoverHandleIndex → hoverHandleCursor(NSCursor?)に置換、onContinuousHover の検出ゲートを武装条件 `select ‖ (supportsGrabMove && !selectionIsFromCreation)`(オーバーレイ/beginHandleDragIfHit と同一式)に拡張。角=NWSE/NESW、辺=上下/左右、端点=線の向きから算出(±22.5°量子化)、尻尾=openHand。updateCursor() の default 分岐(描画ツール)でもハンドルカーソルを最優先反映。**新しいカーソル機構は作らない**(既存 updateCursor/onContinuousHover の値の拡張のみ)
- **受け入れ**: 矩形を明示選択(クリック)→四隅で対角カーソル・辺中点で上下/左右、矢印端点で向きに応じた resize カーソル。描画直後(selectionIsFromCreation=true、ハンドル非表示)ではカーソル不変。既存の openHand(本体ホバー)/crosshair(空き地)/iBeam(text)は不変

### [x] T9.1 履歴の概要表示(OCR)と検索システムのブラッシュアップ(ユーザーFB 2026-06-11、承認済み)
- **背景(ユーザー原文の趣旨)**: メインウィンドウの履歴で過去スクリーンショットを選んだ/ホバーしたときにツールチップで概要(OCRテキスト等)が出るが、**じっくり読みたくてもすぐ消えてしまう**。この機会に過去スクリーンショットの構造(概要の見せ方)と検索システム全体をブラッシュアップしたい
- **進め方**: セッション冒頭で現状調査(HistoryRail のホバーポップオーバー/ツールチップの実装・消滅条件、HistoryQuickLook、applySearch の検索対象と挙動)→ 改善案を理由つきで提案 → ユーザー承認後に実装(非エンジニアのユーザーに平易な説明で。スコープが大きければタスク分割)
- **論点の種**: ①OCR概要を「読める」形にする(消えない詳細表示への導線 — 固定可能なパネル/QuickLook統合/選択時の詳細ペイン等。軽量UX原則: 表面のコントロールは増やさない) ②検索の対象・ヒット箇所の可視化(OCR本文ヒットの抜粋表示等) ③ツールチップの遅延・滞留時間の規律
- **受け入れ**: 提案時に定義(ユーザー承認とセットで)
- **実装(2026-06-12、承認スコープ a+b+c)**: (a)ポップオーバー固定化 — ホバー解除の即閉じを250ms遅延クローズに変更し、ポップオーバー内ホバー中(onPopoverHoverChanged)は維持。マウスを中へ移動してOCR全文の閲覧・スクロール・コピーが可能に。OCR欄高さを行数比例72〜200ptに可変化 (b)ネイティブツールチップ(.help)からOCR80字を削除し日時+サイズ+Spaceヒントへ — 読む導線はポップオーバーに一本化 (c)検索ヒットの抜粋表示 — ocrText→notesの順でヒット箇所前後(前12字/後60字)を抜粋し、一致語をAttributedStringで太字+アクセント色ハイライト。notesヒットは「メモ: 」接頭辞。タイトル等のみヒット時は従来どおりOCR冒頭(空なら非表示)。HistoryRail.swiftのみ+69/−8行

### [x] T9.2 メインウィンドウを閉じた後に再表示できない(ユーザー報告 2026-06-12、同セッションで承認・修正)
- **症状**: ⌘⇧4→パネル→「エディタで開く」が無反応。メニューバーの「SnapLocalを表示」も同様
- **根因**: メインウィンドウの再表示は全経路が `NSApp.bringToFront()`(Utilities.swift)経由だが、これは既存ウィンドウを `makeKeyAndOrderFront` するだけ。ユーザーがメインウィンドウを閉じると WindowGroup のウィンドウは破棄され、**アプリ内に作り直す経路が存在しない**(Dockクリックのみ再生成される)
- **追加発見**: 「閉じた状態」のままアプリを終了すると、次回以降の起動はウィンドウなしで復元される(メニューバー/ホットキーは生きるためユーザーには「本体が起動しなくなった」と見える)。この状態では ContentView が一度も出現しないため、openWindow を View から退避する設計は機能しない
- **実装(2026-06-12、Fable 5直接 — ライフサイクル難所)**: `NSApp.reopenMainWindow()` 新設 — Dockクリックと同じ reopen Apple Event('aevt'/'rapp')を自プロセスへ送り、SwiftUI に WindowGroup ウィンドウを再生成させる(自分宛AEは権限プロンプト対象外)。bringToFront() は canBecomeMain なウィンドウが無いときのみこれを呼ぶ(既存時の挙動は完全不変)。AppDelegate の起動時リトライにも同フォールバックを追加し、ウィンドウなし復元の起動でも自動でメインが出る。**不成立だった代替案2件を実機検証で棄却**: ①delegate の applicationShouldHandleReopen 直呼び=YESが返るだけで再生成されない(既定処理はAEハンドラ側) ②openWindow のグローバル退避=メニューバーラベルは onAppear 非発火、ContentView 退避はウィンドウなし起動で未設定
- **受け入れ(実機E2E済み)**: ①ウィンドウなし復元の起動→約0.7秒で自動表示 ②閉じて0枚→メニューバー「SnapLocalを表示」で再表示(System Events自動操作で確認。「エディタで開く」は同一経路)

### [x] T9.3 クイック注釈パネルの移動・サイズ変更(ユーザー要望 2026-06-12)
- **背景**: ⌘⇧4後に中央表示されるパネルを「移動やサイズ変更可能だといいね」
- **論点の種**: isMovableByWindowBackground は T8.2 fix で注釈ドラッグと競合し false にした経緯あり → タイトルバー相当のつかみ領域 or ⌘ドラッグ等の代替が必要。リサイズは canvasSize 所有権(GeometryReader)との整合を確認すること
- **実装(2026-06-12)**: QuickAnnotatePanel.swift のみ(+25/−4)。**移動** = ①ツールバー行・フッター行の背景に `WindowDragHandle`(NSView.performDrag) ②ツールバーの .ultraThinMaterial は NSVisualEffectView 実体で①にヒットテストが届かないため、`QuickAnnotatePanelWindow.mouseDown` override で未消費クリックをウィンドウドラッグへフォールバック(ボタン・canvasジェスチャに消費されたイベントは届かない = T8.2 競合なし)。isMovableByWindowBackground は false のまま。**リサイズ** = styleMask に `.resizable` 追加(ボーダーレスでもエッジドラッグ可、リサイズゾーンはコンテンツの mouseDown より優先)+キャンバスを固定 frame → min/ideal/max 可変 frame 化+`hosting.sizingOptions = [.minSize]`(初期サイズは従来どおり fittingSize、最小はキャンバス600×280+ツールバー最小幅で自然にクランプ)。fit 変化時の注釈追従は T9.5 の adoptCanvasSpace 漏斗がそのまま処理(canvasSize/basis に不触)
- **受け入れ(実機E2E済み)**: ①ツールバー隙間/フッター空き領域ドラッグでパネル移動(座標一致で確認) ②キャンバスドラッグは注釈描画のみでウィンドウ不動(T8.2 退行なし) ③右/下エッジドラッグでリサイズ、縮小時はズームバッジ93%+矢印が画像コンテンツ上に追従(adoptCanvasSpace 動作) ④最小サイズで正しくクランプ ⑤ツールバーボタンのクリックは奪われない(□ツール選択→矩形描画) ⑥完了でクリップボード+注釈・basis 永続化(basis 同期を index JSON で確認)

### [x] T9.4 顔検出(detectFaceRects)のスレッド違反クラッシュ修正(クラッシュレポート 2026-06-11 21:26)
- **症状**: VNRequest 完了ハンドラ(VisionのバックグラウンドキューVNRequestPerformingPriorityGroup1AsyncTasksQueue)から MainActor 隔離コードに触れて dispatch_assert_queue_fail → SIGTRAP で本体ごと落ちる(StateVision.swift `detectFaceRects(in:)` 内クロージャ)
- **根因(2026-06-12 確定)**: StateVision.swift の extension が `@MainActor` のため、`withCheckedContinuation` 内で作る VNRequest 完了ハンドラが MainActor 隔離を継承。Swift 6 言語モード+StrictConcurrency の動的隔離検証が、Vision バックグラウンドキューからの呼び出し時に dispatch_assert_queue_fail でトラップ。`detectBarcodes(in:)` も同型。`OCRService.recognizeText`(nonisolated enum)は同パターンでも安全 = 既存の正解形
- **実装(2026-06-12)**: `detectFaceRects` / `detectBarcodes` を `nonisolated` 化(2行のみ。両者とも self に不触で意味的にも正しい)。副次効果: 同期実行の `handler.perform` がメインスレッドから降りる。横並び点検済み — Vision 完了ハンドラはソース全体でこの2箇所+OCRService のみ
- **受け入れ(実機E2E済み)**: ①貼り付け画像→redactツール→「顔を自動検出」ボタンで「顔が検出されませんでした」表示+プロセス生存(旧クラッシュ経路 = 検出0件でも完了ハンドラはVisionキューで呼ばれるため完全に通る) ②⌘⇧2撮影で detectBarcodes 経路も完走・生存

### [x] T9.5 アノテーション座標のウィンドウサイズ非依存化(ユーザーFB 2026-06-12「エディタで開いた後、最大化されていないとアノテーションの位置が正しくない」)
- **診断(2026-06-12)**: アノテーションは記録時の canvasSize(=その時のウィンドウのfit表示サイズ)基準のview座標で永続化され、**別のウィンドウサイズで再表示しても座標変換が一切ない**(resetAndLoad も onChange(of: fit) も注釈を変換しない)。パネル(画面70%クランプ)で描いた注釈は、エディタが最大化でほぼ同じfitになる時だけ偶然一致し、小さいウィンドウではズレる。T7.3進捗ログの「従来もウィンドウ幅依存でズレていた」と同根の構造問題
- **実装(2026-06-12)**: 方針①+②の複合。`CanvasViewModel.annotationsBasis`(注釈座標の現在の基準サイズ)を導入し、fit確定・変化時は view から `adoptCanvasSpace(fit)` 漏斗で注釈ごと新空間へ比例換算(ライブ追従)。保存は `VaultManifestEntry.annotationsBasis`(追加キーのみ・互換OK)に基準を記録し、ロード時に現fitへ再換算。旧データ(キーなし)は換算なしの従来表示+初回保存時に basis 付与の一回きり移行。`AnyAnnotation.encode` は _encode がラップ時点の transform/fontSize を捕捉する問題を共有キーコンテナの後書き上書きで解消(リスケール済み transform の永続化に必須)。画像オペ(crop/rotate/flip/extend/stitch/resize)と undo の basis 往復、パネル⇄エディタの fit 不変ケース用 WindowKeyObserver、nil-basis 描画の安全網(addAnnotation/顔検出)を含む
- **受け入れ(実機E2E済み)**: パネルで注釈→エディタを任意サイズで開いても位置一致。ウィンドウリサイズ中も注釈が画像に追従。既存vaultの表示が悪化しない — デモvault(basis 600×400で seed)でウィンドウ 1000×700 / 1340×840 の相対位置一致(0.248/0.248–0.501/0.502)、リスケール済み transform(1.825)の保存→再ロード位置一致、旧データ(キーなし)の従来表示+自然移行をピクセル走査で確認

### [x] T9.6 エディタ下部の常設詳細面(OCR+メモ、Gyazo風) — スコープ確定済み(壁打ち 2026-06-12)
- **背景**: T9.1でホバーポップオーバーを固定化したが、ユーザー評価は「クリックすれば読めるがホバーだけだと消える/体験がいまいち/メモが入れにくい」。ホバー依存の表示そのものに限界。ツールバーからのメモ入力も「フワフワした感じ」と不評
- **承認済みスコープ(ユーザー4決定のうち②③)**: Gyazoの画像ページ構図 — 検索→履歴で候補選択→画像編集、その**キャンバス下部に常設の詳細面**(日時・タイトル・メモ=その場で直接編集・OCRテキスト=選択/コピー可)。**ホバー吹き出しは廃止**(読む導線は詳細面へ一本化。T9.1の検索ヒット抜粋+ハイライトは履歴セル側の表示なので維持)。ツールバーのメモ入力経路は隠してよいが到達経路は残す(機能削除禁止)
- **論点の種(着手時に設計)**: 詳細面の高さ規律(薄い帯+OCRは行数可変?)/canvasSize 所有権との整合(キャンバスのビューポートが縮む=fitが変わるだけなので adoptCanvasSpace がそのまま効くはず — T9.3 で実証済みの経路)/パネル(撮影直後)への詳細面追加はスコープ外(将来論点)
- **依存**: T9.7(OCR整形)が入ると詳細面の「読む」品質が上がる。T9.9(URL記録)の表示先になる
- **受け入れ(実機E2E済み 2026-06-12)**: ①履歴選択中にキャンバス下へ詳細面(タイトル直接編集/日時/メモ直接編集/OCR選択・全コピー)が常設表示、未選択・クイックパネル編集中は非表示 ②タイトル確定でウィンドウタイトル・履歴セル・JSONに反映 ③メモは即時保存・編集中の巻き戻りなし ④ホバー吹き出し廃止(検索ヒット抜粋+ハイライトは維持) ⑤詳細面でfitが縮んでも注釈が追従(相対位置0.247/0.244→0.503/0.503=T9.5基準と一致) ⑥ライト/ダーク両対応

### [x] T9.8 パネルの最前面ピン留め設定+ピンインジケータ(ユーザーFB 2026-06-12、壁打ちで確定)
- **背景**: T9.3後のFB「最前列ピン留めがデフォルトでもいいが設定で好みに任せたい。ピン留め中なのが上の四隅で分かるといい」
- **承認済みスコープ(ユーザー決定①)**: パネル右上隅に小さなピンアイコン(ピン中=塗り、解除=半透明アウトライン)を常時表示し、**クリックでその場トグル**(level .floating ⇄ .normal)。設定に「パネルを常に最前面に表示」トグルを追加=**デフォルト値**(既定ON=現挙動)。デザイン値は DS.* のみ
- **受け入れ**: 着手時に定義(①ピンアイコンの表示/トグルで前面挙動が即変わる ②設定の既定値が次回パネルに効く、を含むこと)

### [x] T9.9 キャプチャ時のソースURL記録 — ブックマーク的活用(ユーザー要望 2026-06-12、壁打ちで確定)
- **背景**: 「スキャンした時にURLも記録してくれるとブックマーク的に使える」(GyazoのソースリンクのSnapLocal版)
- **承認済みスコープ(ユーザー決定④)**: **Info.plist への NSAppleEventsUsageDescription 追加をユーザー承認済み(2026-06-12 壁打ち)・機能は既定ON**(設定でOFF可)。撮影時に最前面(領域オーバーレイ起動直前)のアプリがブラウザなら、現在タブのURL+ページタイトルを `VaultManifestEntry` の**追加キー**(例: sourceURL / sourcePageTitle — キー追加のみ・互換維持)で記録。詳細面(T9.6)に表示+クリックでブラウザで開く+検索対象(searchText)に追加。完全ローカル原則は不変(Apple EventsはMac内のブラウザへの問い合わせのみ・通信なし)
- **論点の種**: 領域キャプチャで「どのウィンドウのURLか」(第一案: オーバーレイ起動直前の最前面アプリ)/対応ブラウザ範囲(Safari+Chromium系のAppleScript共通形、Arc等は要確認)/権限拒否・非対応ブラウザ時は静かにスキップ(エラーUIを出さない)
- **依存**: 表示先として T9.6 が先にあると良い(記録自体は独立実装可)
- **受け入れ(実機E2E済み 2026-06-12)**: ①Safari最前面で⌘⇧2→JSONに sourceURL/sourcePageTitle 記録 ②Chrome(Chromium形)も同様(初回はAutomation同意ダイアログ→許可後に遅延記録される非同期設計も動作) ③詳細面のリンククリックで既定ブラウザが開く ④非ブラウザ最前面・同意なしは静かにスキップ(エントリは sourceURL なしで正常保存・エラーUIなし) ⑤キャンセル/失敗/ペースト経路に残骸が付かない ⑥設定トグル既定ON ⑦検索対象化はコード+永続化JSONで確認(UI検索はユーザー受け入れ時に確認)

### [ ] T9.10 ツールバー右側アクションアイコンの直感性+グリフ大きさの整列(ユーザーFB 2026-06-12)
- **背景**: T9.8受け入れ時のFB「ダウンロードボタンとクリップボードボタンがあまり直感的じゃない気がする」「アイコンの大きさも前よりはいいけど、まだ少しでこぼこしている感じがある」(T8.10視覚再デザインの続き)
- **論点の種(着手時に壁打ち)**: ①保存/コピーのSF Symbols選定 — square.and.arrow.down(保存)が共有(square.and.arrow.up)と紛らわしい、doc.on.doc(コピー)の意味が伝わりにくい可能性。代替候補や小ラベル併記の是非 ②グリフの光学サイズ — SF Symbolsはシンボルごとに見た目の大きさが揺れるため、font指定だけでなくシンボル単位の微調整 or 別シンボル選定が要るかも ③対象はメインツールバー+パネル共通(CompactToolbar)
- **受け入れ**: 着手時に定義(アイコン案をスクショ比較で提示→ユーザー合意後に確定)

### [x] T9.11 注釈選択時のミニアクション(ゴミ箱+複製、Gyazo風)(ユーザー要望 2026-06-12、壁打ちで確定)
- **背景**: T9.6受け入れ時の要望「アノテーション設置後にクリックした時にゴミ箱かコピーのアイコンが出るといい。delで削除、ctrl c ctrl v でコピペも」。調査の結果、**Del削除・⌘C/⌘V(注釈コピペ)・⌘D複製は実装済み**(CanvasView の onKeyPress(.delete) / StateExport の注釈優先コピペ)— 本質は発見性の問題
- **承認済みスコープ(壁打ち 2026-06-12)**: 注釈を明示選択したとき、選択領域の近くに**ゴミ箱+複製の2つだけ**小アイコンを表示(控えめ)。クリップボードコピーは⌘C/右クリックメニュー据え置き
- **論点の種(着手時に設計)**: 表示位置(バウンディング上辺の外側?キャンバス端でのフリップ)/描画直後の自動選択(selectionIsFromCreation)では出さない=T8.9の流儀どおり明示選択のみ/ドラッグ・リサイズ中は隠す/デザイン値は DS.* のみ
- **受け入れ**: 着手時に定義

### [x] T9.12 詳細面の控えめ化 — 優先度: 日付>撮影場所URL>OCR>メモ(ユーザーFB 2026-06-12)
- **背景**: T9.6受け入れ時FB「メモはつける画像よりつけない画像の方が圧倒的に多いので、もうちょっと控えめでいい。日付とか撮影場所(URLならリンクだといい)、OCR、メモぐらいの優先度」
- **スコープ**: DetailPane を再設計 — 高さ縮小、メタ行(日付・ソースURL=クリックでブラウザで開く)を主役に、メモは1行の控えめ表示(クリックで編集)。**T9.9 のソースURL表示先を兼ねるため T9.9 とセットで実装**(表示先を二度作り直さない)
- **受け入れ(実機スクショ確認済み 2026-06-12)**: 高さ150→92、左列=タイトル/メタ行(日付+🔗リンク=ページタイトル中央省略・.helpでフルURL)/メモ1行控えめ(TextField化・即時保存漏斗は不変)、右列OCRは従来構成のまま。ライト/ダーク両確認。**ユーザー受け入れ時の確認項目: 見た目の好み(Before/After)+メモのクリック編集**(合成入力ではTextFieldフォーカス検証不可のため)

### [ ] T9.13 検索バーのツールバー常設移設(ブラウザ風)(ユーザー要望 2026-06-12、壁打ちで確定)
- **背景**: 「ブラウザみたいに検索バーがツールバーにあってもいいかもしれない」(T9.6受け入れ時)
- **承認済みスコープ(壁打ち 2026-06-12)**: ツールバー右側に**常設の検索フィールド**。入力でサイドバーを自動展開して絞り込み(既存 searchQuery / applySearch / searchFocusTrigger を流用)。⌘F は新フィールドへフォーカス。**T9.10(アイコン整理)と同時に実施**してツールバーレイアウトを1回で確定
- **論点の種**: 狭いウィンドウでの最小幅・折りたたみ/サイドバー内の旧検索欄の扱い(移設=同一機能のUI再配置なので削除可、ただし⌘Fの到達経路は維持)
- **受け入れ**: 着手時に定義

### [x] T9.14 矢印(線系注釈)が掴みづらい(ユーザーFB 2026-06-12)
- **背景**: T9.6受け入れ時FB「矢印が掴みづらい」
- **診断の種(起票時調査)**: ヒット判定は `hitTolerance = max(lineWidth.rawValue + 8, 12)`(AnnotationModels.swift:45)を線の strokedPath 幅として使用 — 細線だと**線の左右±6pt**しか反応せず、斜めの細い矢印では実質数ピクセル。候補: ①線系(arrow/line)だけ許容幅を広げる(例: 20〜24pt) ②ズーム縮小表示時の実効許容幅の補正 ③描画ツール選択中のグラブ移動(supportsGrabMove)との資格関係の確認(T8.9のselectionIsFromCreationと干渉しないこと)。T9.11(ミニアクション)と同じ選択まわりなので**T9.11と同セッションで実施してもよい**(diffが小さければ)
- **受け入れ**: 着手時に定義(細線の矢印を近傍クリックで選択できる・隣接注釈の誤選択が増えない)

### [x] T9.15 設置済み矢印の向き反転(ユーザー要望 2026-06-12)
- **背景**: T9.6受け入れ時の要望「一度設置した矢印の向きも簡単に変えられるといい」
- **診断の種(起票時調査)**: ArrowAnnotation は startPoint/endPoint+doubleSided を持つので、**反転=始点と終点のスワップ**で実装は小さい(transform は両点共通なので不変でよい)。入口の候補: ①選択中矢印の右クリックメニュー「向きを反転」 ②選択中のキー1発(例: R) ③T9.11のミニアクションに矢印選択時だけ反転アイコンを追加(ただしユーザーは「2つに絞る」を選択済みなので、増やすなら壁打ちで確認)。線(line)・吹き出し尻尾など他の方向性注釈に広げるかも着手時に判断
- **依存**: T9.11(ミニアクション)・T9.14(掴みづらい)と同じ選択まわり — **同セッション実施可**
- **受け入れ**: 着手時に定義(選択した矢印の向きが1操作で反転・undo可・永続化される)

### [ ] T9.7 OCRテキストの整形 — FoundationModelsで「軽く整える」(方針ユーザー承認 2026-06-12)
- **背景**: Vision OCRは複数カラム・UIレイアウトのスクリーンショットで読み順が乱れ、検索には使えるが「読む」品質ではない。ユーザー要望: 要約・言い換えはせず、改行の修正と明らかな誤認識の修正だけ
- **手段候補(いずれも完全ローカル・Apple純正のみ)**: ①観測ボックスの座標で読み順を再構成(カラム検出・行グルーピング)— 軽量・全環境で動く ②Apple Foundation Models(macOS 26+のオンデバイスLLM)で整形 — Apple Intelligence有効化が必要(本機は現在オプトインなし)・macOS 26未満はフォールバック必須・品質/速度は要実測PoC。①を基本に②をオプション検討の二段構え
- **事前検討(2026-06-12、ユーザー依頼で実地プローブ済み)**: (1)現行OCR=Vision VNRecognizeTextRequest(accurate+言語補正+言語自動検出)、出力は観測ボックスごとのtop候補を"\n"連結した素のString — 読み順・段落構造なし。全7呼び出しが OCRService.recognizeText 漏斗経由で vault.updateOCR に入る (2)FoundationModels組み込み可否=**本機でコンパイル・実行可を確認済み**(SDK 26.5/Swift 6.3、Package.swiftはmacOS14のままで `#if canImport`+`#available(macOS 26,*)` 二重ゲートでOK・依存追加/entitlements/Info.plist不要・完全オンデバイス)。ただし実行時 availability が **appleIntelligenceNotEnabled**=システム設定でApple Intelligence有効化(+モデルDL)がユーザー側に必要。生成品質・レイテンシの実測は有効化後のPoCで (3)最小変更の挿し込み位置=acceptCapture の updateOCR 直後に非同期二段書き(生OCRで即検索可→整形完了後に再updateOCR)。availability非対応・整形失敗・長文(コンテキスト4096トークン)は静かに生OCR維持。永続化は新キー不要(ocrText上書き)か、生を残すなら追加キー ocrTextPolished(互換OK)の二案 — 実装方針はユーザー判断待ち
- **承認済みスコープ(壁打ち 2026-06-12: 「元のモデル(生OCR)も残そう」)**:
  - **生OCRは保持**: `ocrText` は従来どおり生のまま(検索・互換・巻き戻しの基盤)。整形結果は**追加キー `ocrTextPolished: String?`**(VaultManifestEntry/VaultItem、キー追加のみ・互換維持)
  - **挿し込み=二段書き**: acceptCapture で生OCRを即保存(検索即可)→ 裏で整形 → 新漏斗 `updatePolishedOCR(id:text:)` で保存。reRunOCR(再実行)も同経路。**updateOCR で生テキストが変わるときは ocrTextPolished を必ず nil に無効化**(画像編集→OCR撮り直しで古い整形が残る事故防止)
  - **ゲートと安全弁**: `#if canImport(FoundationModels)` + `#available(macOS 26,*)` + availability の三重ゲート。非対応・失敗・長文(コンテキスト4096トークン超相当)は静かにスキップ(生のまま・エラーUIなし)。プロンプトで要約・言い換え・追加を禁止し、**整形前後の文字数比が大きく外れたら不採用**(機械的安全弁)。sampling=greedy(再現性)。NSAppleScript同様、完了ハンドラのMainActor隔離継承に注意(OCRService と同じ nonisolated 形)
  - **表示**: DetailPane のOCR欄は polished があれば表示・全コピーも表示中のもの、なければ生。検索 searchText は生+polished の両方を対象
  - **UI追加なし**: OCR方針(自動実行ファースト)どおり全自動。設定トグル・ボタンは作らない
- **前提条件(ユーザー側の作業・着手前)**: システム設定 → Apple Intelligence と Siri で **Apple Intelligence を有効化**(初回モデルDLあり)。有効化まで availability=appleIntelligenceNotEnabled のため PoC も実装検証も不能
- **段取り**: ①PoC実測(実スクショ数枚で品質・レイテンシをM1実機計測、「軽く整える」が守られるか確認)→ ②結果提示(品質不十分なら手段①=読み順再構成への切替を壁打ち)→ ③実装+実機E2E
- **受け入れ(着手時に最終化)**: ①撮影→生OCRが即検索可→数秒後に詳細面の表示が整形版に置き換わる ②JSONに ocrText(生)と ocrTextPolished の両方が残る ③画像編集→OCR撮り直しで古い polished が消える ④Apple Intelligence無効環境では従来どおり(エラーなし) ⑤要約・言い換えが起きていない(PoCサンプルで目視)

---

## Phase R: 蓄積した無駄の全面リファクタリング(2026-06-10 調査)

> **調査方法**: 並列コード調査3本(重複パターン / 構造・責務 / デッドコード)。
> **大原則: 挙動変更ゼロ。** R1は機械的移動のみ(diffが純粋な移動に見えること)、R2は挙動保存の重複排除、R3はデッドコード削除、R4は永続化互換に関わるため設計レビュー必須。
> **実行体制**: Sonnet サブエージェントが実装、Fable 5 がレビュー+難所の直接実装。1タスク=1コミット、各タスクで `bash build-app.sh` 通過必須。
> **依存**: R1 → R2 → R3 → R4 の順。R1内・R2内も同一ファイルを触るため**直列実行**(並行不可)。

### 現状診断(2026-06-10、計12,794行)

| 問題 | 実態 |
|---|---|
| CanvasViewModel | **2,305行のGodクラス**(AnnotationCanvas.swift)。状態38 @Published+CRUD+CoreImage+CGContext書き出し+画像変換+ドラッグ状態機械が同居 |
| AnnotationCanvasView | 1,453行(CanvasView.swift)。body約700行に .onKeyPress 約25個直書き |
| SnapLocalState | 1,105行・約40メソッド(App.swift)。撮影/履歴/書き出し/OCR/背景永続化が混在 |
| RegionCapture.swift | RegionOverlayWindow 583行、RegionView.draw() 270行の単一メソッド |
| 重複 | applyTransform×12型、選択ID解決×7、hit tolerance×6、座標変換×6、対角カーソル生成×2、pngData×2、スポイトhex変換×2 等、計200行超 |
| 同居 | HistoryQuickLook が CaptureNotification.swift に無関係同居。モデル型定義とVMが AnnotationCanvas.swift に同居 |

### Phase R1: 機械的ファイル分割(振る舞い変更ゼロ)

> stored プロパティは class 本体に残し、**メソッドのみ extension として新ファイルへ移す**。リネーム・整形・ロジック変更は一切しない。クラス分解(別オブジェクト化)は**やらない**(observation グラフが変わりリスクが利益を上回るため)。

#### [x] R1.1 AnnotationModels.swift の抽出
- **移動元→先**: AnnotationCanvas.swift → 新規 `AnnotationModels.swift`
- **対象**: `AnnotationElement`(protocol) / `AnnotationType` / `AnnotationColor` / `LineWidth` / `LineStyle` / `DrawingTool` / `RedactMode` / `SpotlightShape` / `CropHandle` / `SnapGuide` / `DragState`(約390行)
- **ガード**: AnnotationType の case名・raw value は1文字も変えない

#### [x] R1.2 CanvasRendering.swift の抽出
- **対象**: `extension CanvasViewModel` として `renderAnnotations()` / `applyFilter(...)` / `updateFilterPreview()` / `updateRedactDragPreview()` / `applyDecoration` 系 / `sampleColor()`(約400行)を移動
- **ガード**: CI座標系のY反転コードは一切触らない(CLAUDE.md 落とし穴)

#### [x] R1.3 CanvasImageOps.swift の抽出
- **対象**: `extension CanvasViewModel` として `rotateImage` / `flipImage` / `resizeCanvas` / `resizeToFit` / `extendCanvas` / `stitch` / `bakeAdjustments` / `resetAdjustments` / crop系(`confirmCrop` / `cropToRect` 等)(約500行)

#### [x] R1.4 CanvasInteraction.swift の抽出
- **対象**: `extension CanvasViewModel` として `handleDragStart` / `handleDragUpdate` / `handleDragEnd` / `handleDragCancel` / `shiftConstrainedPoint` / `computeSnap` / `createAnnotation`(約800行)
- **完了時**: AnnotationCanvas.swift は概ね900行以下(状態+CRUD+undo+テキスト入力)

#### [x] R1.5 CanvasView.swift の分割
- **新規 `CanvasHelpers.swift`**: `ZoomNotificationHandler` / `ScrollWheelHandler` / `ScrollableNSView` / `MultilineTextInput` / `NonScrollingTextView` / `HintRow` / `makeDiagonalCursor()` / カーソルグローバル
- **新規 `CanvasOverlays.swift`**: `extension AnnotationCanvasView` として `annotationLayer` / `selectionHandlesOverlay` / `handleDot` / `cropOverlayLayer` / `drawCropOverlay` / `textInputOverlay`

#### [x] R1.6 SnapLocalState の extension 分割
- **新規 `StateCapture.swift`**: captureNow / captureNowToClipboard / captureRegion系 / captureWindow系 / captureWithDelay / acceptCapture / handleCaptureResult / repeatLastRegionCapture
- **新規 `StateHistory.swift`**: loadHistoryItem / loadHistory / refreshHistory / navigateHistory / applySearch / deleteHistoryItem / deleteAllHistory / renameHistoryItem / updateNotesForItem / toggleStar / duplicateHistoryItem
- **新規 `StateExport.swift`**: saveAnnotatedImage(As) / exportHistoryAsZip / exportHistoryAsPDF / exportHistoryItem / copy系クリップボード / pinCurrentImage / openInPreview / shareCurrentImage
- **新規 `StateVision.swift`**: reRunOCR / detectBarcodes / detectFaceRects / autoRedactFaces / ocrSelectedRegion
- **完了時**: App.swift は概ね500行以下(App/AppDelegate/SnapLocalState本体/ContentView/チップ)

#### [x] R1.7 HistoryQuickLook.swift の分離
- **対象**: CaptureNotification.swift から `HistoryQuickLook` + `HistoryQuickLookView` を新ファイルへ機械移動

### Phase R2: 重複排除(挙動保存・各タスク400行以内)

#### [x] R2.1 AnnotationElement の共通化
- `applyTransform` のデフォルト実装を protocol extension に追加し、12型の同一実装を削除(**CalloutAnnotation は tailPoint 変換があるため独自実装を残す**)
- hit tolerance 式 `max(lineWidth.rawValue + 8, 12)` を protocol extension の `hitTolerance` に統一(6箇所)
- AnyAnnotation の hex パース重複を `customColorComponents` ヘルパーに統一(2箇所)
- **ガード**: stored プロパティ・Codable 形式は一切変えない。`applyTransform` は `transform.concatenating(self.transform)` の式を厳守(CLAUDE.md 落とし穴)

#### [x] R2.2 小ユーティリティの統合(新規 `Utilities.swift`)
- `CGImage.pngData()`(PersistentVault/App の2重複)、`CGImage.nsImage`(4箇所)、アプリ前面化2行セット(5箇所)、タイムスタンプ DateFormatter(3箇所)
- `CanvasViewModel.effectiveSelectedIDs`(選択ID解決の7重複)
- `DrawingTool.supportsGrabMove`(3箇所のSet定義統一。**CanvasView側 grabCapableTools の `.select` 込み差分は意味が違うので別プロパティとして保持**)
- `AnnotationColor.isLightColor`(yellow/white判定の3重複)

#### [x] R2.3 座標変換ヘルパーの導入 — **Fable 5 レビュー必須**
- `CanvasViewModel` に view座標→ピクセル座標変換ヘルパーを導入し6箇所の重複を置換。**Y反転あり(CI用)となし(crop用)の2系統を別メソッドとして明示**(`canvasRectToPixelCI` / `canvasRectToPixel` 等)
- **ガード**: CLAUDE.md「CoreImageの座標系」落とし穴を厳守。置換前後で各呼び出し箇所の数式が同値であることをレビューで確認

#### [x] R2.4 Toolbar.swift 内の重複排除
- NSColorSampler→hex変換ブロック(2箇所完全コピー)をメソッド化
- 調整スライダー4行を `adjustmentRow(...)` ViewBuilder に統一

#### [x] R2.5 対角カーソル生成の統合 — **差異ありのため見送り**
- CanvasView.swift `makeDiagonalCursor()` と RegionCapture.swift `ResizeHandle.diagonalResizeCursor()` のほぼ同一実装を1箇所に統合
- **見送り理由**: ①戻り値型が異なる(NSCursor vs NSImage) ②RegionCapture側は`ctx.strokePath()`を2回呼んでいるが2回目は空パス(strokePathはパスをクリアする)のため実際の描画は白ストロークのみ。CanvasHelpers側は白+黒の2パスで描画。統合すると RegionCapture のカーソル外観が変わり「挙動は1ビットも変えない」に違反する。将来の修正候補: RegionCapture の単パス描画バグを修正した上で統合する。

### Phase R3: デッドコード除去

#### [x] R3.1 デッドコード削除(調査結果に基づき内容確定)
- 並列調査3本目(デッドコード)の結果リストから、確信度 high(grep参照ゼロ確認済み)のみ削除。medium 以下は進捗ログに記録して残す
- **ガード**: index.json.bak 関連・AnnotationType raw value・AppIntents・Codableキーは削除禁止

### Phase R4: 構造改善(永続化互換レビュー必須 — Fable 5 直接実装)

#### [x] R4.1 MosaicAnnotation / BlurAnnotation の統合検討
- 2型は `type` と CIFilter 以外ほぼ全フィールド・全メソッド同一(約40行重複)。統合する場合、**旧形式で保存済みの mosaic/blur 注釈が新コードでデコードできること**をテストで証明してから着手。リスクが利益を上回ると判断したら「見送り」を進捗ログに記録して完了扱い

### Phase R5: 仕上げ

#### [x] R5.1 最終監査
- 全体ビルド+起動+主要導線(撮影→注釈→保存→履歴復元)の目視確認
- 行数レポート(before/after)を進捗ログに記録
- 調査で見つかった**挙動に関わる気づき**(モザイク/ぼかしの intensity 保存値が renderAnnotations のハードコード値 12/20 と不一致 — 修正すると書き出し結果が変わるため Phase R 対象外)を将来タスク候補として記録

---

## T5.1 監査記録(2026-06-10)

1. **[要対応] vault孤児ファイル**: `~/Pictures/SnapLocal/` に index.json 未登録のPNGが2件残留(6/8付)。削除やindex再構築時に画像ファイルが残る経路がある。プライバシー原則(「消したはずの画像が残る」)に抵触。**対応案**: 起動時に孤児を検出し、ゴミ箱へ移動(`FileManager.trashItem` — 復元可能)+ステータス通知。自動完全削除はしない。→ ユーザー承認後に実装
2. **[軽微] 起動時に index.json が書き換わる**: 閲覧しただけでmtimeが更新される。saveManifest の呼び出し経路を確認する価値あり(Google Drive同期フォルダ利用時に無駄な同期が発生)
3. **[未実施] 対話的フロー監査**: 撮影→注釈→コピー→貼り付けの体感監査は自動化権限(System Events/画面収録のリセット)の制約でエージェントからは不可。ユーザーのドッグフーディングで「引っかかり」をこのセクションに追記してください
4. **[確認済み] 新UI動作**: グリッド履歴・削減後ツールバー・選択遷移はスクリーンショットで目視確認済み

## 進捗ログ

| 2026-06-10 | アイコン改善 | ユーザー指摘「アイコンがイマイチ・小さい」対応。①ツールボタン22→28px+シンボル15pt medium(DSToolButtonStyleがsize比例で自動設定、明示.font指定は優先) ②絵柄修正: select=cursorarrow(旧リサイズ風矢印)、redact=checkerboard.rectangle(旧eye.slashは表示切替と混同)、roundedRect=app(旧上だけ角丸)、pencil=scribble、ellipse=oval、**spotlight=flashlight.on.fill(旧"spotlight"は実在しないシンボル名で空表示だった)** ③カラースウォッチも28pxに統一 |

| 日付 | タスク | 結果 |
|---|---|---|
| 2026-06-10 | 計画再構築 | このファイルと CLAUDE.md を作成 |
| 2026-06-10 | T0.1 | DesignTokens.swift 新設。DS.Space/Radius/FontSize/Anim/Shadow を定義、既存コード変更なし |
| 2026-06-10 | T0.2 | CompactToolbar+OCRTextPanel+ColorWellView+LineStylePreview を Toolbar.swift(1,136行)へ機械移動。App.swift 5,104→3,977行 |
| 2026-06-10 | T0.3 | HistoryRail+HistoryItemRow+HistoryItemPopover を HistoryRail.swift(598行)へ機械移動。App.swift 3,977→3,387行 |
| 2026-06-10 | T0.4 | HelpPopover+SettingsSheet+WindowPickerSheet を Sheets.swift(396行)へ機械移動。App.swift 2,998行(目標2,500よりやや大、AnnotationCanvasViewが残るため許容)。**Phase 0 完了** |
| 2026-06-10 | T1.1 | Toolbar.swift トークン移行(45行)。吸着規則: タイは大きい側へ(6→8、20→24)。ポップオーバーpadding 10/14/14→DS.Space.m(16)に統一。数値モノスペース表示は全てcaption(11)に統一。アイコン/絵文字サイズ・1〜2pxマイクロ調整・装飾プレビュー模擬値は機能的数値として除外 |
| 2026-06-10 | T1.2 | HistoryRail.swift トークン移行(30行)。サムネイル上のオーバーレイバッジ文字(6-8pt)はthumb寸法に連動するためT4.1グリッド化時に一括処理として保留 |
| 2026-06-10 | T1.3 | Sheets/CaptureNotification(HUD)/PinToScreen/App.swift残部の131カ所を移行。Canvas/GraphicsContext内のキャンバスチローム描画・HUDプログレスバー・AppKitアニメーションは対象外として保留。キャンバス画像shadowはDS.Shadow.canvas一致だが据え置き(T2系で検討) |
| 2026-06-10 | T1.4 | DSToolButtonStyle(isActive/size可変、ホバー背景+押下スケール0.96+無効ディム内包)とdsPrimaryButton()を導入。ツールバーの全アイコンButtonと主要アクション3つに適用。Toggle/Menu/Pickerはシステムスタイル維持。**Phase 1 完了** |
| 2026-06-10 | T2.1 | ツール選択をDS.Anim.baseのクロスフェードで遷移(implicit animationなのでキー/クリック両対応)。ツール固有コントロールの出入りも同トークンでレイアウトアニメーション。matchedGeometryEffectのスライド型インジケータは将来の磨き込み候補として保留 |
| 2026-06-10 | T2.2 | リサイズ/端点/テールハンドルをCanvas直描きからselectionHandlesOverlay(SwiftUIビュー)へ移設。出現/消滅はopacity+scale(0.5)、ドラッグ/リサイズ中はanimation=nilで追従遅延なし。破線アウトラインはCanvas内に残置(全面書き直し回避) |
| 2026-06-10 | T2.3 | 履歴サムネイルにホバー時scale 1.04(DS.Anim.fast)+選択枠フェード(DS.Anim.base)。軽量modifierのみでスクロール性能影響なし |
| 2026-06-10 | T2.4 | showStatus(success:)を追加、完了系23メッセージ(〜しました)に緑チェックマーク(scale+opacity遷移)を付与。StatusChipの3秒自動消滅は既存挙動を維持 |
| 2026-06-10 | T2.5 | サイドバーは既存のmove遷移+DS.Anim.smoothで条件充足済みを確認。追加: 撮影直後のツールバーコントロール群出現(画像なし→あり)にDS.Anim.smoothのレイアウト遷移。NSPopover自体はシステム遷移のまま(計画通り)。**Phase 2 完了** |
| 2026-06-10 | T3.1 | ツールバー監査完了。状態②で28個(目標12の2倍超)。削減提案A〜FをPLAN.mdに記載、**ユーザー承認待ち**。T3.2は承認後に実施 |
| 2026-06-10 | T3.3 | 空状態再設計: アクセント色の円形バッジ+光細アイコン、撮影ボタンlarge化、ショートカットをGrid整列のキーキャップ風表示(角丸+ボーダー+微影)に。権限導線維持。情報量は増やさず |
| 2026-06-10 | T3.4 | 設定を使用頻度順に並べ替え(キャプチャ→書き出し→保存先→ホットキー→通知→起動)。曖昧な3項目(カーソル・書き出し形式・ホットキー)にfooter説明を追加 |
| 2026-06-10 | T4.2 | PersistentVault(actor)にNSCacheサムネイルキャッシュ(上限50MB、コスト=バイト数)。allItems/search/duplicateの全件ディスク読みを解消。save/updateThumbnailでシード、deleteでinvalidate。index.json不変 |
| 2026-06-10 | 発見 | `swift test`が既存問題で失敗(`import Testing`モジュールがCLIツールチェーンに無い)。アプリビルドには影響なし。テスト基盤の修理を新タスク候補としてT5.2で扱う |
| 2026-06-10 | T4.1 | 履歴を2列LazyVGrid化(サムネイル110×74、レール幅88→244)。保留していたバッジ/ラベル文字(6-8pt)をcaption2(9)へ統一。日付グループ・スター・コンテキストメニュー・⌘↑↓・ドラッグアウト維持。スクリーンショットで目視確認済み |
| 2026-06-10 | T4.3 | ホバー時にコピーボタン(成功で1.2秒チェックマーク)、スター/コピーともopacity+scale遷移(DS.Anim.fast)。ポップオーバーは.leadingのまま(レール右端配置なのでグリッドと重ならない)。**Phase 4 完了** |
| 2026-06-10 | T3.2 | 承認済み提案A〜Fを全実施: undo/redo隠しボタン化(⌘Z/⌘⇧Z維持)、削除・件数バッジは選択時のみ、回転リサイズ結合+テンプレートを新設「…」メニューへ、ヘルプは設定シート内へ。画像あり時28→約22個(提案表の「約13」は算術ミス。12個達成にはツール群の追加整理が必要 — 新提案として将来検討)。スクリーンショットで目視確認済み |
| 2026-06-10 | T5.2 | 監査#1: cleanOrphans()実装(起動時、未登録PNG/JPGをゴミ箱へ・復元可能・件数通知)— ユーザー承認済み。実データで検証: 孤児2件が正しくゴミ箱へ移動。監査#2: updateOCR/Title/Notes/Annotationsに変更なしならsaveManifestしないガード(クラウド同期の無駄書き込み防止) |
| 2026-06-10 | T1.5 | ダークモード監査(実施漏れ分)。白黒直書きを全grep→ほぼ全てが画像上スクリム付きオーバーレイで両モード正解。実バグ1件: HUD「編集」バッジが適応素材上に白固定文字→.primaryに修正。両モードでスクリーンショット確認、ライトモードに復元済み。**Phase 1 完全完了** |
| 2026-06-10 | T5.3 | 性能パスは**保留**: 現vaultが1件のため計測が無意味。履歴100件以上が溜まった時点で実施(起動>1秒/操作応答>100msが閾値)。T4.2のキャッシュで既知のI/O問題は先行解消済み |
| 2026-06-10 | テスト基盤 | 原因特定: ①テストターゲットがアプリに非依存(dependencies: [] — importすら不可能だった) ②このマシンはCLTのみでswift-testing/XCTestが無く`swift test`自体が実行不能。対応: 依存修正+PersistentVaultの実テスト7本をswift-testing形式で追加、GitHub Actions CI(.github/workflows/ci.yml)を新設。**テストのコンパイル・実行はCIで初回検証される**(ローカル検証不能のため、push後にCI結果を要確認) |
| 2026-06-10 | セッションレビュー | 本日の全diff(18コミット)をエージェントレビュー。**must-fix 1件検出・修正**: cleanOrphansがindex.json破損時(クラウド同期競合)や非vaultフォルダで正規ファイルを誤削除し得た→「manifest空なら何もしない」+「UUID命名ファイル限定」ガードを追加、ガード検証テスト2本追加。nice-to-fix: クロップ中の⌘Z無効化(旧挙動と一致)。他8領域(ハンドルオーバーレイ座標系・ショートカット網羅・グリッド・キャッシュ整合)は問題なしを確認 |
| 2026-06-10 | 追加分割 | AnnotationCanvasView+キャンバス専用ヘルパー(ZoomNotificationHandler/ScrollWheelHandler/MultilineTextInput/HintRow/対角カーソル)を CanvasView.swift(1,670行)へ機械移動。**App.swift 1,379行**(セッション開始時5,104行→73%減) |
| 2026-06-10 | T2.1磨き込み | 保留していたスライド型ツール選択インジケータを実装(matchedGeometryEffect + DSToolButtonStyleのshowsActiveBackground:falseオプション)。選択背景がツール間を滑らかに移動する(Figma風) |
| 2026-06-10 | 微修正 | 起動時の自動履歴復元で「履歴を読み込みました」チップが出るノイズを抑制(loadHistoryItem(quiet:)、ユーザー操作時のみ表示)。スクリーンショットで検証済み |
| 2026-06-10 | CI初回グリーン | push後、CIランナーの厳格なstrict concurrencyで4ラウンドのビルド修正(ColorWellView Coordinator/NSImage境界越え/UndoManagerハンドラ11カ所をregisterMainActorUndoヘルパー化/SCWindowのMainActor固定)。**最終的にビルド+全7テスト合格**。T5.3計測値: allItems×200件 cold 3ms / warm 2ms(閾値100msを大幅クリア)。run 27250004514 |
| 2026-06-10 | アイコン磨き2 | ユーザー指摘「いまだに微妙」対応。①撮影メニューのchevronが標準インジケータと二重表示→全borderlessメニューに.menuIndicator(.hidden) ②arrow=line.diagonal.arrow(旧arrow.up.rightは外部リンク風) ③crop=crop(旧scissors) ④コピー=doc.on.doc(旧doc.on.clipboardはペースト風) ⑤pencil=pencil.line。新シンボル名は全てランタイム実在確認済み。スクリーンショットで目視確認。ダークモードは未確認(ユーザー作業中のため外観切替を回避。SFシンボルはテンプレート描画なのでリスク小)。README heroは旧アイコンのまま(差分軽微・次回更新時に刷新) |
| 2026-06-10 | Drive仕上げ | cleanOrphansに48時間の同期猶予を追加(複数マシン利用時、他マシンの画像PNGが先に同期されシャードJSONが遅れても誤削除しない)。設定の保存先セクションにDrive利用の説明footer追加。ガード検証テスト1本追加 |
| 2026-06-10 | T6.2 | 検索軽量化: searchTextメモリキャッシュ(OCR+タイトル+ノート+注釈平文)を先にスキャンし、VaultItem組み立てはヒット分のみ。追加キーannotationTexts新設(旧エントリは読込時に一度だけデコード補完・メモリ内)。検索入力200msデバウンス+古い結果の破棄ガード。テスト2本追加(旧エントリ注釈検索/1万件<100ms計測) |
| 2026-06-10 | T6.1 | index/YYYY-MM.json月別シャーディング実装。書き込みはエントリの属するシャードのみ(persist(id)+shardOf辞書)。旧index.json自動移行→index.json.bak保全。Drive競合コピー(YYYY-MM (1).json等)を読み込み時マージ・正規へ定着(重複IDは正規勝ち)。AppIntentsもシャード+保存先設定対応。テスト4本追加(移行/シャード分離書き込み/競合マージ/no-op)。実バイナリで移行・競合マージのスモークテスト済み |
| 2026-06-10 | Phase 6 追加 | ユーザー承認を得て大規模アーカイブ対応をタスク化(T6.1 インデックス月別シャーディング / T6.2 検索軽量パス+デバウンス)。背景: Google Driveに永続保存し「あの画像どこだっけ」をOCR検索で探す想定。現状の単一index.json全量書き換えと毎キーストローク全件デコードが数千枚で顕在化するため |
| 2026-06-10 | T5.4 | READMEヒーロー画像完成(合成デモvault+ウィンドウID撮影)。Settings.swiftに開発用vaultオーバーライド起動引数を追加(3行、通常起動に影響なし)。気づき: ①READMEのRoadmapが古い(右クリック削除・ウィンドウ撮影・通知・ログイン起動は実装済み)②canvas極小ステップバッジで数字が円中心からズレて描画される(stepNumber描画、通常サイズでは未確認)|
| 2026-06-10 | T7.5 | ユーザー指摘3点対応(矢印両端固着の根治/太さS・M・Lのインライン表示/スポイト)。実機で太さピッカー表示・矢印片側復帰・ポップオーバーのスポイトを目視確認 |
| 2026-06-10 | T7.2 | 背景編集の永続化。canvas.backgroundDirty(registerBackgroundUndoで両方向セット)+vault.updateImage新設。保存タイミングは注釈と同一(3秒オートセーブ/切替・撮影直前のフラッシュ/⌘S/終了時)。初回編集は新規アイテム化(タイトル・ノート引き継ぎ+OCR撮り直し)、同一セッション内の続き編集はフォーク済みアイテムを上書き(乱造防止、forkedThisSession)。実機検証: クロップ→3秒→vault 6→7件・元画像無傷・チップ表示。テスト2本追加(updateImage上書き/未知ID no-op) |
| 2026-06-10 | T7.4 | 履歴レールのノイズ削減: 寸法バッジをホバー時のみに(スター・コピーと同じ作法)、昨日グループ内セルの「昨日」プレフィックス除去。レターボックス黒地はJPEG焼き込みのため見送り(タスク本文に記録)。デモvaultで通常時/ホバー時を目視確認 |
| 2026-06-10 | T7.1 | ズーム表示系修正。naturalZoom導入(⌘0=本当の実寸)、読み込み既定=実寸/収まらなければフィット(zoom≤1で溢れ根絶)、`.clipped()`追加、canvasSize変化時の自動再フィット(起動42%問題解消、手動ズーム後は追従しない)、フィット=⌘9、⌘F=履歴検索(サイドバー自動表示)、バッジ%を実ピクセル比に統一。ついで発見: 右下情報チップがcanvas非観測で更新されない既存バグ→CanvasInfoChipに切り出し修正。デモvaultで起動/大画像93%/小画像100%/⌘0/⌘9/⌘F/検索ヒットを実機確認。ダークモードは素材ベースのため目視省略(ユーザー作業中につき外観切替回避) |
| 2026-06-10 | コア導線監査 | 目的適合調査(撮る→カット→注釈→保存→自動OCR→検索)。OCR自動実行・自動タイトル・シャードDB・軽量検索は適合を確認。重大3件+軽微1件を発見しPhase 7としてタスク化(T7.1ズーム崩壊/T7.2クロップ非永続/T7.3レターボックスずれ/T7.4レールノイズ)。検証は合成デモvault+ピクセル走査計測 |
| 2026-06-10 | T3.5 | 第2弾削減(承認: G/I/K、Jは却下)。G: 撮影3ボタン→カメラ+メニュー1組(⌘⇧3/4はCommandMenuで維持)。I: 調整+装飾→1ボタン+セグメントタブ切替パネル。K: 設定ボタン非表示→⌘,(アプリメニュー復活)+メニューバー「設定…」+通知経由でシート表示。**OCR方針対応**: 自動OCR前提のためツールバーのOCRボタン撤去(OCRTextPanel削除)、結果確認は履歴ポップオーバー、「文字認識を再実行」を履歴コンテキストメニューに追加(reRunOCR実装)。状態①は3個、状態②は約17個(28→17) |
| 2026-06-10 | R1.1 | AnnotationModels.swift を新規作成し、AnnotationElement/AnnotationType/AnnotationColor/LineWidth/LineStyle/DrawingTool/RedactMode/SpotlightShape/CropHandle/SnapGuide/DragState(11型)を AnnotationCanvas.swift から機械移動。削除322行≒追加329行、ビルド通過 |
| 2026-06-10 | R1.2 | CanvasRendering.swift(384行)を新規作成し、updateFilterPreview/updateRedactDragPreview/sampleColor/applyDecoration/renderAnnotations/applyFilter を機械移動。AnnotationCanvas.swift 2317→1952行(-365行)。private→internal 変更1件(ciPreviewCtx)。ビルド通過 |
| 2026-06-10 | R1.3 | CanvasImageOps.swift(387行)を新規作成し、enterCropMode/confirmCrop/cancelCrop/cropToRect/trimWhitespace/registerBackgroundUndo/extendCanvas/stitch/bakeAdjustments/resetAdjustments/hasActiveAdjustments/rotateImage/flipImage/resizeToFit/resizeCanvas(15件)を機械移動。AnnotationCanvas.swift 1952→1574行(-378行)。private→internal変更1件(cropHandleActive)。ビルド通過 |
| 2026-06-10 | R1.4 | CanvasInteraction.swift(884行)を新規作成し、handleDragStart/handleDragUpdate/handleDragEnd/handleDragCancel/shiftConstrainedPoint/computeSnap/simplifyPoints/createAnnotation(8件)を機械移動。AnnotationCanvas.swift 1574→702行(-872行)。private→internal変更11件(redactPreviewThrottle/editingAnnotationID/isRubberBanding/multiDragStartPositions/cropHandleStartRect/cropHandleDragOrigin/isUndoing/dragStartAnnotation/calloutTailBakedBase/endpointDragBakedStart/endpointDragBakedEnd)。ビルド通過 |
| 2026-06-10 | R1.5 | CanvasHelpers.swift(250行)とCanvasOverlays.swift(611行)を新規作成。CanvasView.swift 1709→866行(-843行)。private→internal変更3件(zoom/panOffset/textInputHeight: extension内textInputOverlayからのアクセス要件)。ビルド通過 |
| 2026-06-10 | R1.6 | StateCapture(247行)/StateHistory(151行)/StateExport(400行)/StateVision(131行)を新規作成。App.swift 1568→681行(-887行)。private→internal変更9件(vault/captureEngine/statusTask/clipboardOnlyCapture/currentVaultID/lastRegionRect/regionCapturePlayedSound/loadHistoryTask/searchDebounceTask)、private func→func変更2件(persistEditedBackground/flushPendingBackgroundEdit)、private func→func変更3件(sendNotification/detectBarcodes/detectFaceRects)。ビルド通過 |
| 2026-06-10 | R1.7 | HistoryQuickLook.swift(123行)を新規作成し、HistoryQuickLook+HistoryQuickLookView を CaptureNotification.swift(442→323行)から機械移動。ビルド通過 |
| 2026-06-10 | R2.1 | AnnotationElement protocol extensionに`applyTransform`デフォルト実装+`hitTolerance`を追加。12型の重複`applyTransform`削除(CalloutAnnotation独自実装は保持)、6箇所の`hitTolerance`式統一、AnyAnnotationの`customColorComponents`ヘルパーで hex パース2重複を統一。ビルド通過・新規警告なし |
| 2026-06-10 | R2.2 | Utilities.swift新設。CGImage.pngData()(PV/SE 2重複→計5箇所置換+private func削除)・CGImage.nsImage(4箇所)・NSApp.bringToFront()(完全ペア5箇所)・DateFormatter.fileTimestamp(SE 3箇所)・CanvasViewModel.effectiveSelectedIDs(7箇所)・AnnotationColor.isLight(2箇所+1箇所はyellow含まずスキップ)・DrawingTool.supportsGrabMove(CanvasInteraction/CanvasView 2箇所置換、CanvasOverlays grabCapableToolsは`supportsGrabMove||==.select`形で保持)。ビルド通過 |
| 2026-06-10 | R2.3 | canvasRectToPixelRect(Y反転なし・crop系4箇所)/canvasRectToCIRect(Y反転+最小2px・CIプレビュー2箇所)をCanvasViewModelに導入し6重複を置換。Fable 5直接実装。全呼び出し元が事前にcanvasSize>0をguard済みで完全同値。renderAnnotations内の変換はクランプ無し+transform連動のため対象外。ビルド通過 |
| 2026-06-10 | R2.4 | スポイト→hex変換2箇所を`applySampledColor(_:)`に統一(差異: colorPickerツール側は`.usingColorSpace`なし+ツール復元あり、ポップオーバー側は`.usingColorSpace(.sRGB)`あり+ツール復元なし — それぞれ呼び出し側で差異を保ったまま共通メソッドに委譲)。調整スライダー4行を`adjustmentRow(label:value:in:format:)`ViewBuilderに統一(フォーマット文字列・range差異は引数で保持)。ビルド通過 |
| 2026-06-10 | R2.5 | 対角カーソル統合を差異ありのため見送り。①戻り値型の違い(NSCursor/NSImage) ②RegionCapture側がstrokePathを2回呼ぶが2回目は空パスで実質白ストロークのみ vs CanvasHelpers側は白+黒2パス — 外観変更なしでは統合不能。将来: RC側バグ修正後に統合可。 |
| 2026-06-10 | R5.1 | 最終監査完了・**Phase R 全完了(15コミット)**。①主要導線を合成vaultで実機確認: 履歴復元→注釈(redactツール新規作成)→3秒オートセーブ→再起動復元、全パス(撮影はScreen Recording権限の制約でエージェント検証不可 — T5.1監査#3と同じ。ユーザーのドッグフーディングに委ねる)②行数: Sources 12,794→12,558(−236行、別途テスト+60行)。CanvasViewModel系 2,317→744行に分解。現最大は RegionCapture.swift 1,221行(Phase R対象外)③Codexによる全diff敵対的レビューを裁定: BROKEN判定2件(mosaic/blurの type/intensity キー欠如でデコード不能)は**誤検出** — let+初期値プロパティはエンコードされる(実vault旧データに"type"キー存在を確認)+旧AnyAnnotationデコードもtypeキー必須+intensityの厳格性は新旧同一(R4.1証明スクリプトcheck#4)。VaultLevel削除は非Codableのメモリ内VaultItemのみで永続化スキーマ外。private→internal拡大は各R1.xログ記録済みの意図的変更。**挙動保存を結論** ④将来タスク候補: mosaic/blurのintensity保存値が CanvasRendering.swift のハードコード(プレビュー31/36行・書き出し352/359行: scale=12/radius=20)に無視される不一致 — 修正すると既存画像の書き出し結果が変わるため要ユーザー判断の別タスク |
| 2026-06-10 | R4.1 | Mosaic/Blur を `RedactAnnotation`(type: .mosaic/.blur)に統合実施。**互換証明3段**: ①ローカルswiftスクリプト(旧structのstoredプロパティを忠実複製→synthesized Codableで旧形式を再現)で旧→新・新→旧(ダウングレード)双方向の全フィールド保存+キー集合一致をPASS ②固定フィクスチャCIテスト2本追加(旧形式JSON→AnyAnnotationデコード/再エンコードのキー集合不変。実vaultの保存形式 `lineWidth:{"thin":{}}` ケース名キー形式も実データで確認) ③合成旧形式vault(/tmp/r41vault)を実機読み込みし pixellate(ハードエッジ)/blur(フェザー)の描画分岐を拡大目視。注: 旧Blurのデフォルトintensity 20→統合後10だが、全生成箇所が明示設定+デコードはキー必須のため挙動差なし。AnnotationType raw value不変。97→69行 |
| 2026-06-10 | R3.1 | デッドコード削除: ①setupDirectories()(PV, 5行) ②Security.swift全体(SecurityVerifier, 130行) ③VaultLevel enum+VaultItem.level(17行+3呼び出し箇所) ④showWindowPicker/windowPickerItems/@Published 2個+.sheet修飾子+WindowPickerSheet+WindowPickerRow(120行超) ⑤CanvasView.swiftのimport UniformTypeIdentifiers ⑥Sheets.swiftのimport ServiceManagement/ScreenCaptureKit ⑦#available(macOS 13.0,*)2箇所(Sheets/Settings) ⑧#if os(macOS)ガード1箇所(Settings)。スキップ: cgImage(from:)はR1.6実施前に既に消滅済み(grep参照ゼロ)。ウィンドウ撮影機能はcaptureWindowMode→WindowHoverCapture経由で健在を確認。Security.swift復活が必要な場合はgit履歴から。ビルド通過 |
| 2026-06-10 | ⌘⇧4致命バグ修正 | **症状**: 領域選択を開くと全Spaceが黒い不透明パネルで覆われ、ESC/クリック/アプリ切替の全てが無効、pkillのみで復旧(ユーザー報告+スクショで確認: 黒画面に取り残されたルーペ2個)。**根因**: RegionOverlayWindow(NSObject制御オブジェクト)を誰も強参照しておらずstart()直後に即時解放 — パネルだけがAppKitに保持され画面に残留し、RegionView.drawはweak参照nilで早期return(凍結画像すら描かれず黒)、全イベントモニタは[weak self]でno-op化。**修正4点**: ①RegionCapture.activeOverlayで表示中のみ強参照保持+⌘⇧4再押下でキャンセルするトグル化(脱出ハッチ) ②ESC/Enterをオーバーレイ表示中のみCarbonグローバルホットキー登録(他アプリ使用中のキーフォーカス非依存・追加権限不要。NSEventローカルモニタは併存=多重防御) ③画面録画権限なし時は凍結スナップショットを無効化(CGDisplayCreateImageが壁紙のみの偽画像を返し「全ウィンドウ消失」に見える問題の対策)→ライブ画面+半透明グレーで動作継続 ④表示時に自前アクティブ化+解除時に元アプリへフォーカス復帰。**実機検証**(合成イベント): Finderアクティブ状態から表示→48%減光+ルーペ+ヒント描画/ESC解除/⌘⇧4トグル解除/Finderへのフォーカス復帰を輝度計測+スクショ目視で確認。ドラッグ選択→Enter→編集画面遷移はTCC制約(マウス合成イベント遮断+画面録画権限)でエージェント検証不可 — ユーザードッグフーディングで確認お願いします |
| 2026-06-10 | ⌘⇧4ドラッグ阻害修正(実機検証済み: 2026-06-11) | mouseDownがウィンドウスナップ対象上(=画面ほぼ全域)で即ウィンドウ撮影をコミットするため、ウィンドウ上からドラッグで範囲選択を開始できなかった。CleanShot/Gyazo流の「クリック=ウィンドウ撮影、4pt以上動かしたらドラッグ=範囲選択」にmouseUp判定へ変更(pendingWindowSnap)。ビルド通過・アプリ起動済みだが、画面ロックのためE2E(ドラッグ→Enter→編集画面)未検証だった → 翌日ユーザー物理操作で検証完了(下記) |
| 2026-06-11 | ⌘⇧4 E2E実機検証 | ユーザー物理操作によるE2E確認(合成イベントはTCC遮断のためエージェント不可)。⌘⇧4→画面録画権限許可→ウィンドウ上からドラッグ→Enter→編集画面、の導線を実施し、vault に新規PNG(2880×1740 — フルスクリーン2880×1800と異なる任意サイズ)が永続化されたことを sips で確認。ドラッグ選択→Enter確定→acceptCapture→vault保存のパイプライン全通。af49ce8/2f61192 の修正は完全クローズ |
| 2026-06-11 | T8.1 | Sonnetサブエージェント実装+Fable 5レビュー。ルーペ完全削除(LoupeView/loupePanel/setupLoupe/updateLoupe+呼び出し9箇所、−187行)、新規ドラッグはmouseUpで即commit(mac標準)、initialRect再選択パスのみ`.adjusting`+Enter維持(startedWithPreselectionフラグ)。レビュー裁定: commit()は状態非依存(selectionRect>0のみガード)で.draggingから直接呼んで安全、screenSnapshots/cursorScreenPointは凍結背景・RegionView描画で現役=死蔵なし、寸法バッジはdrawSizeLabel()が元から独立実装で維持。ビルド通過+⌘⇧4表示/ESC解除スモーク生存確認。E2E目視はT8.2完了後にユーザーがまとめて実施 |
| 2026-06-11 | T8.2 | Fable 5直接実装(canvasSize所有権領域のため)。QuickAnnotatePanel.swift新設(枠なしborderless NSPanel、canBecomeKey、Esc=cancelOperation、画面70%クランプ+中央表示)。**canvasSize単一書き込み者の保証**: パネル表示中は ContentView が `quickPanelActive` でメイン側 AnnotationCanvasView をヒエラルキーから外し、閉じると再挿入の onAppear が canvasSize を取り戻す設計。完了(⌘↩/ボタン)=copyToClipboard(注釈込み)+updateAnnotations即時永続化+閉じ、Esc=保持して閉じるのみ。ペースト/ドロップは suppressQuickPanel(clipboardOnlyCaptureと同作法)でパネル抑止しHUD維持。vault保存/OCR/QRはacceptCapture内Taskで不変。ビルド通過+起動/⌘⇧4/ESCスモーク。気づき(T8.3送り): パネル内ツールバーからのペーストでHUDが併出/サイドバートグルがパネル内で無意味/完了時のstatusChipがメイン非表示中で見えない |
| 2026-06-11 | T8.1+T8.2 E2E実機検証 | ユーザー物理操作で新フロー全通をディスク証拠で確認: ⌘⇧4→ドラッグ→離す即撮影→中央パネル→注釈→完了。vault 8枚目(1442×1740、T8.2バイナリ起動06:26後の06:31撮影)+ annotationsData 1360bytes 永続化(パネルで描いた注釈の保存)+ OCR自動実行1276文字・自動タイトル設定 + クリップボードに画像あり。アプリ生存。UX定性評価(軽やかさ)と T8.3 着手はユーザーフィードバック待ち |
| 2026-06-11 | T8.2 fix(実機FB対応) | ユーザー報告2件を修正。①2回目以降の⌘⇧4で旧挙動(プリセレクション=adjusting+Enterモード)が出る — captureRegion/captureRegionToClipboard が常に initialRect:lastRegionRect を渡していたのが原因。新バイナリ初回のみ lastRegionRect 空で新フローだったためタイムライン一致。両呼び出しを initialRect なしに変更(プリセレクション機構と repeatLastRegionCapture は温存)。「画像反転」に見えた現象はプリセレクション画面の明暗ハイライトの誤認と推定 — 該当画面自体が出なくなる ②注釈ドラッグでパネルが動く — isMovableByWindowBackground=true がキャンバスのドラッグを吸っていた→false に。ビルド+⌘⇧4トグルスモーク通過。ユーザー再検証待ち |
| 2026-06-11 | T8.3 | ユーザーが真因を特定: **⌘⇧4 で mac標準スクショと SnapLocal が両方発火**(Carbonはシステムショートカットと排他でない)。「画像反転/ウィンドウ選択」の混乱はこれ。対応: 設定トグル「⌘⇧4 を SnapLocal の範囲選択にする」(既定オン)。オン=CGS私的API(ID 30)で mac標準を起動中のみ無効化、オフ=mac標準復元+SnapLocalは⌥⌘4(即時再登録、メニュー表記も追従)。**実機検証**: PoC(/tmp/cgstest)で err 0・即時反映、アプリ起動→native-DISABLED/⌘Q終了→native-ENABLED 復元を確認。pkill(SIGTERM)では復元されない既知の制限を記録。ついで: パネル表示中ペーストのHUD併出をisVisibleガードで修正。Fable 5直接実装(Carbon/私的API領域) |
| 2026-06-11 | T8.5+T8.6 | ユーザーFB2件。①ウィンドウスナップが画面外まで矩形表示 → windowRectAtでカーソル画面frameにintersectionクランプ(Fable 5直接、座標系領域)。swift build通過 ②毎ビルドで画面録画権限再承認 → 真因はアドホック署名のハッシュ変動でTCC失効、それを隠すためのtccutil reset。安定自己署名証明書で解決する setup-signing.sh 新設+build-app.sh分岐(証明書あれば安定署名・resetなし)。キーチェーンimportの自動実行は分類器が-A込みでブロック→妥当と判断し、-Aなし(codesignのみACL)・一時ランダムパス・ネットワークなしのユーザー実行スクリプトに分離。証明書未作成時のbuild挙動は不変。実機適用はユーザー待ち |
| 2026-06-11 | T8.6 fix(実機FB対応) | ユーザー報告「証明書を毎回有効にしなきゃいけない」= ビルドごとに鍵アクセス確認ダイアログが出て「常に許可」も保持されない。真因: Sierra以降は `-T /usr/bin/codesign` のACLだけでは不十分で、鍵にパーティションリストが無いとアクセス毎にダイアログ(macOS仕様)。setup-signing.sh に `security set-key-partition-list -S apple-tool:,apple: -s`(ログインパスワードを1回だけ端末で入力)を追加。あわせて**有効な証明書があれば再作成しない**冪等化(再作成=証明書ハッシュ変動=画面録画の再承認が必要になるため。壊れた時は FORCE=1 で作り直し)。bash -n 通過。実機確認(./setup-signing.sh 再実行→ビルド2回でダイアログゼロ)はユーザー待ち |
| 2026-06-11 | T8.6 完全クローズ | ユーザー実機確認で全通。①setup-signing.sh(Terminal実行、パスワード1回)→「OK 完了」②build-app.sh 安定署名・ダイアログなし ③旧アドホック署名に紐付いた古いTCC承認が「許可済み表示なのに撮影不可」を起こしたため tccutil reset 1回→アプリ再起動→再許可で解消(権限はプロセス起動時固定のため、設定変更後のアプリ再起動が必須という運用ノウハウも確認)④⌘⇧4撮影成功。以後のビルドでは鍵ダイアログ・権限再承認ともゼロ。注: スクリプトは非対話実行(Claude Code内の`!`等)では明示エラーで停止する(read不可のため) |
| 2026-06-11 | T8.4 | delegate-impl体制(Sonnet実装+Fable 5レビュー・通知フロー直接実装)。①CompactToolbarにshowsSidebarToggle追加、パネルのみ非表示(メインは⌘⇧H含め不変) ②StatusChipをパネルのキャンバス上にオーバーレイ(メインと同作法) ③設定トグル文言「HUDをスキップ」→「クイック注釈パネルの代わり」+footer・ヘルプに⌘↩/Esc追記。**レビューで2件検出し追加修正**: (a)「撮影完了を通知する」設定が全経路で未参照の死にトグル→sendNotificationにguard追加 (b)撮影時+⌘↩完了時の通知二重化→パネル表示時は撮影完了通知を抑止し⌘↩完了時の1回に集約(willShowPanel)。ビルド+起動生存スモーク通過。パネル内の目視(トグル非表示/チップ/完了通知1回)はユーザードッグフーディング待ち。**Phase 8 全タスク完了** |
| 2026-06-11 | T7.3 | Fable 5直接実装(canvasSize所有権・座標系領域)。①キャンバスを表示画像サイズ(アスペクト一致)の内側ZStackに束ねcanvasSize=fitに(所有権はviewのまま、onChange(of:fit)でリサイズ・画像差し替え両対応) ②座標変換はtoCanvas()1箇所の漏斗を中心基準に変更、逆写像3箇所(テキスト入力・配置リップル)も追従 ③**追加発見: renderAnnotations()のストローク描画にY反転が無く、書き出しが上下ミラー位置になる既存バグ**(中央付近では誤差が小さく未発覚)→コンテキスト反転+テキストはflipped:true+スポットライトの画像再描画は局所反転戻しで修正。**実機検証**(デモvault+ピクセル走査+CGEventドラッグ): 矩形の画面vs書き出し位置=誤差≤1.2px、step数字/テキスト/スポットライト/クロップ/再起動復元すべて位置一致、座標バッジも画像隅で693,1093(期待694,1094)。注: 検証中の「クロップ0.8倍」「開始点26ptズレ」は合成イベントの配送特性(最初のonChangedがドラッグ1-2ステップ目から)による計測アーティファクトと特定済み — 実マウスでは影響なし。既存保存注釈は旧レターボックス帯ぶん(≤20pt)シフトするが従来もウィンドウ幅依存でズレていたため悪化なし。気づき: toCanvasがpanOffsetを考慮しない(パン後に描くとズレる)既存問題は未修正のまま記録 |
| 2026-06-11 | T7.6 | Fable 5直接実装(座標系領域・実質2行)。toCanvas()に`- panOffset`を追加し順写像(テキスト入力・リップル・⌘スクロールズームのアンカー計算)と対称化。逆写像は全ジェスチャ・ホバー・ダブルクリックがこの漏斗1箇所を通るため修正もここだけ。**実機検証**(デモvault+マーカー画像+合成イベント): ①WYSIWYG不変条件 — 画像px(200,200)のマーカーにホバーした座標バッジがパン前(198,198)/スペースドラッグでパン(+110,+70pt)後(198,198)で完全一致(旧コードならパン量÷zoom=110pt超ズレる) ②パン状態で矩形ドラッグ(80×80pt)→表示中心の誤差3pt・サイズ79.5pt(合成イベント配送特性内) ③パンなし挙動はpanOffset=0で数式上完全不変+ベースライン計測でも確認。気づき: 合成スクロールイベント(CGEvent scrollWheelEvent2)はScrollWheelHandlerに届かない(パン検証はスペース+ドラッグで代替) |
| 2026-06-11 | T8.7 | delegate-impl体制(Codex実装+Fable 5設計・レビュー — ユーザーFB「Codexをもっと使って」適用)。全画面撮影(captureNow/captureWithDelay)で fullScreenCapturePending を立て、acceptCapture が消費してパネル表示直後に enterCropMode()+autoConfirmCropOnDragEnd=true+ステータス「ドラッグで切り抜き — Esc でそのまま注釈」。handleDragEnd のクロップブロックで release 即 confirmCrop()(dragState.end() 二重呼びなし・confirmCrop 本体不変)。レビューで堅牢化1件追加: captureRegion/captureWindowNow 入口でフラグを倒す(全画面撮影が無音失敗した後の範囲撮影が誤クロップモードで開くのを防止)。ビルド+起動生存スモーク通過。⌘⇧2実機目視はユーザードッグフーディング待ち |
| 2026-06-11 | T8.8 | Codex実装+Fable 5レビュー。windowRectAt の guard に kCGWindowAlpha > 0.05 を追加 — 完全透明ヘルパーウィンドウ(Electron系等)が「見えないのに候補」になる真因。既存フィルタ・T8.5クランプは不変。ビルド通過。⌘⇧4ホバー実機確認はユーザー待ち |
| 2026-06-11 | T8.7/T8.8 fix(実機FB対応) | ユーザー実機FB3件、Fable 5診断+Codex実装。①⌘⇧2でクロップモードにならない — Carbonホットキーが`engine.captureScreen()`直呼びで`captureNow()`(フラグ設定)を経由しない配線漏れ → `fullScreenCaptureAction`コールバック新設しメニューと同経路に ②**⌘⇧4押下で画面が上下反転 — RegionView.draw()の凍結スクショ描画に不要なY反転(translateBy+scaleBy)。非flippedビューではctx.draw()だけが正しい。T8.6の安定署名で画面録画権限が常時保持されるようになり凍結パスが毎回通って顕在化(過去の「画像反転に見えた」報告の真因もこれ — プリセレクション誤認説を訂正)** ③注釈をgrab-move中に描画プレビューが重なって動く — CanvasOverlaysのDrawing preview条件とredactライブプレビューに`!isGrabMoving`ガード追加。ビルド+起動スモーク通過、実機目視はユーザー待ち |
| 2026-06-11 | T8.9 | ユーザーFB「設置済み注釈のサイズ・太さを変えたい」。Fable 5設計(機構は select 限定で既存と診断)+Codex実装+Fable 5等価性レビュー。①addAnnotationで新規注釈を自動選択 ②ハンドルヒットテストを beginHandleDragIfHit() へ verbatim 抽出し描画ツールでも発動 ③handleDragUpdate の尻尾/端点/リサイズ3ブロックと handleDragEnd の確定(undo)を select ゲート外へ巻き上げ(rubber-band と resize は状態相互排他のため順序入替の影響なし・multiDragはリサイズ中常に空で等価) ④ハンドル描画条件を select‖supportsGrabMove へ。ビルド+起動スモーク通過、実機目視はユーザー待ち。余談: 委譲プロンプトの `$0` がCodex側転送で化けた1箇所をCodexが自己申告のうえ正しく復元(申告精度良好) |
| 2026-06-11 | T8.9 fix(実機FB対応) | FB2件、Fable 5診断+Codex実装。①「選択中の矢印がドラッグで伸びる」— 描画直後の自動選択が端点ハンドル(r=10pt)を武装させ、近くからの新規ドラッグを乗っ取っていた+リサイズ中に描画プレビューが重なる → `selectionIsFromCreation` フラグ新設: 描画直後の選択は太さ/色の即変更用に維持しつつハンドル非表示・乗っ取りなし。明示選択(クリック/つかみ)でのみハンドル武装。空き地から新規描画開始で選択解除。プレビュー条件に resizingHandleIndex==nil 追加 ②「他の注釈を置くと以前の注釈を調整できない」— 純クリック(移動なし)が無反応だった → SpatialTapGesture(count:1) を描画ツール限定で追加、selectAnnotation 流用(スタイルコントロール同期込み・空クリックは選択解除)。ビルド+起動スモーク通過 |
| 2026-06-11 | T8.10 | delegate-impl体制(Fable 5設計・レビュー+Codex実装)。双子セグメント(テキストツールで太さS/M/LとフォントS/M/L/XLが密着して並ぶ)を `usesLineWidth && tool != .text` で解消、各セグメントに lineweight/textformat.size の10pt補助アイコン。DS.Toolbar トークン+DSToolToggleStyle 新設で高さ28/セパレータ18/メニュー幅22/spacing 6・2 を統一、スウォッチ16pt円に小型化。**実機受け入れ済み**: デモvault+System Eventsキー送信でライト/ダーク×select/arrow/text/redact の計8枚を撮影しBEFORE(前回セッション取得分)と比較、双子解消・整列・分節を目視確認(/tmp/t810-shots/T810-before-after.png)。ビルド通過。残検証1点: eyeトグル(⌘')のkeyboardShortcutがDSToolToggleStyle化後も効くか — 注釈が要るため合成検証不可、ユーザードッグフーディングで確認お願いします。ノウハウ: CGEvent直postが効かない環境でもosascript System Eventsのkeystrokeは通る/画面ロック・ディスプレイスリープ中はSCK撮影不可(caffeinate -u -dで起こす) |
| 2026-06-11 | T8.11 | ユーザーFB「四隅でカーソル形状が変わって欲しい」。Fable 5設計+Codex実装+Fable 5レビュー。ハンドル別カーソルは select 限定実装済みだったため、検出ゲートを武装条件 select‖(supportsGrabMove&&!selectionIsFromCreation)(オーバーレイ/beginHandleDragIfHitと同一式)へ拡張し、hoverHandleIndex→hoverHandleCursor(NSCursor?)に置換。updateCursor の default 分岐(描画ツール)でも最優先反映。ついで解消: 端点(9/10)と吹き出し尻尾(8)が select でも crosshair に落ちていた未仕上げ → 端点は線の向きから±22.5°量子化(endpointCursor、Y下向きで dx·dy 同符号=NWSE)、尻尾=openHand。新カーソル機構なし(既存 updateCursor/onContinuousHover の値拡張のみ、NSCursor.push 不使用)。CanvasView.swift のみ+57/−31行。ビルド+起動スモーク通過。ホバー目視は合成マウスが本環境で届かないためユーザードッグフーディングで(矩形クリック選択→四隅対角/辺上下左右、矢印端点、描画直後はカーソル不変、の4点) |
| 2026-06-12 | T9.1 | delegate-impl体制(Fable 5調査・設計・レビュー+Codex実装)。「OCR概要がすぐ消える」の正体は2つ: ①.helpツールチップのOCR80字(OS仕様で数秒+マウス移動で消滅) ②ホバーポップオーバーが「ホバー解除=即閉じ」で、読みにマウスを入れた瞬間に消える構造欠陥。→ a)250ms猶予+ポップオーバー内ホバー維持で「中に入って読める」化+OCR欄72〜200pt可変 b).helpはOCR削除で短縮 c)検索ヒット抜粋+一致語ハイライト(太字+アクセント色、メモヒットは「メモ: 」付き)。レビューで3点修正(memo:→メモ:、OCR空時の空AttributedString退行→nil、...→…)。ビルド通過。ホバー実機目視はユーザードッグフーディング待ち。セッション中に別件発覚→T9.2〜T9.4起票 |
| 2026-06-12 | T9.2 | ユーザー報告「本体が起動しなくなった/エディタで開くが無反応」。診断: bringToFront()は既存ウィンドウを前に出すだけで再生成経路ゼロ+「閉じた状態」終了後は起動時もウィンドウなし復元(メニューバー/ホットキーは生存)の複合。lldb・CGWindowList・AppleScriptで段階検証し、reopen Apple Event自己送信のみが動く再生成経路と特定(delegate直呼び・openWindow退避は実機で棄却)。NSApp.reopenMainWindow()新設+bringToFrontフォールバック+起動時リトライに追加。E2E自動検証2本合格(ウィンドウなし起動→自動表示/閉→メニューバー再表示)。Fable 5直接実装(ライフサイクル難所、Codex初版設計は穴があり差し替え)。ついで発見の顔検出クラッシュ(21:26 .ips、Visionキューからの MainActor 違反)はT9.4起票 |
| 2026-06-12 | T9.5〜T9.7起票 | ユーザー実機FB3点を診断・起票。①注釈位置がウィンドウサイズ依存(最大化以外でズレ)→構造根因を特定しT9.5(座標のサイズ非依存化、設計レビュー必須) ②ホバー吹き出しの体験不満→T9.6(固定面への再設計) ③OCR文章の整形要望→T9.7(読み順再構成+Foundation Models PoC)。質問回答: 検索対象はOCR/タイトル/メモ/注釈内テキストの4種横断(PersistentVault.searchText)、メモも対象 |
| 2026-06-12 | T9.4 | delegate-impl体制(Fable 5診断・設計・E2E+Codex実装)。根因: @MainActor extension 内の VNRequest 完了ハンドラが MainActor 隔離を継承し、Swift 6+StrictConcurrency の動的隔離検証が Vision キューからの呼び出しでトラップ(検出0件でも落ちる)。OCRService(nonisolated enum)が既存の正解形だった。detectFaceRects/detectBarcodes を nonisolated 化(2行)。横並び点検: Vision完了ハンドラは全ソースでこの2箇所+OCRServiceのみ。実機E2E: デモvault+貼り付け→AXで「顔を自動検出」ボタンclick→「顔が検出されませんでした」表示+生存、⌘⇧2撮影でバーコード経路も完走。ノウハウ: SwiftUIボタンはAXでwindow直下に出ない→entire contents から help テキストで特定してclick(.help が AXHelp に乗る) |
| 2026-06-12 | T9.5 | 前セッション(中断)の実装をFable 5が直接レビューして続行。annotationsBasis+adoptCanvasSpace漏斗+永続化追加キー+AnyAnnotation.encode後書き上書き+画像オペ/undoのbasis往復+WindowKeyObserver+nil-basis安全網(レビューで本セッション追加)。実機E2E: デモvault(basis 600×400)で2ウィンドウサイズの相対位置一致・transform 1.825のラウンドトリップ・旧データの従来表示+初回保存での自然移行をピクセル走査で確認。気づき①: LineWidth(CGFloat raw enum)はRawRepresentableのCodable高速経路に乗らず `{"medium":{}}` 形式でJSON化される(seed作成時の落とし穴)。気づき②(既存リスク・T9.5起因でない): annotationsDataのデコード失敗時 `try?` が空配列に化け、自動保存が空を書き戻して注釈データを破壊しうる(デコード失敗時は保存を抑止すべき)— 将来タスク候補 |
| 2026-06-12 | T9.3 | delegate-impl体制(Fable 5設計・E2E+Codex実装、ヒットテスト難所のmouseDownフォールバックはFable 5直接)。移動=WindowDragHandle(performDrag)+ウィンドウmouseDownフォールバックの2段、リサイズ=.resizable+可変frame+sizingOptions[.minSize]。学び: ①SwiftUIの .ultraThinMaterial はNSVisualEffectView実体で、その下の NSViewRepresentable にはヒットテストが届かない(素のSwiftUI背景なら届く — フッターは①だけで動いた) ②ボーダーレス+.resizable のエッジリサイズゾーンはコンテンツのmouseDownより優先(フッター端でも資格衝突なし) ③拡大方向は zoom の実寸キャップで fit 不変(注釈無換算)、縮小方向で fit<1 になり adoptCanvasSpace の比例換算が効く。実機E2E: CGEvent合成ドラッグで移動/リサイズ/注釈描画/ボタンクリック/完了永続化の6項目合格 |
| 2026-06-12 | T9.8 /verify | PASS(9手順)。実スタッキング両方向(解除中=Finderの背面/ピン中=Finderアクティブでも前面、CGWindowListのz順で確認)・連打5回の状態整合・ピンクリックのドラッグ化けなし・ツールバー背景ドラッグ(T9.3)回帰なし・ダーク両状態・設定OFF→次パネルnormal。気づき: パネル表示中の再撮影は新パネルが設定既定値に戻る(ピン解除は引き継がれない — 壁打ち決定どおりの設計。違和感が出たら「セッション中は直近トグル維持」が代替案) |
| 2026-06-12 | T9.8 FB対応+T9.10起票 | ユーザー受け入れOK(3点ok)+FB3点。①ピン縮小: グリフをDS.FontSize.caption(11pt)へ(クリック領域28pt維持)、実機確認済み ②「完了でクリップボードに入っていて欲しい」→実機E2Eで検証: ⌘⇧2→クロップ→矢印描画→完了ボタンで、クリップボードに**注釈込み・クロップ済み画像が正しく入る**(ピクセル走査で矢印確認。当初の赤スキャン0は永続化スタイルが青だったため — 誤検出に注意)。再現せずのためユーザーの具体的な操作手順を確認中 ③保存/コピーアイコンの直感性+グリフでこぼこ→T9.10起票 |
| 2026-06-12 | T9.8 | delegate-impl体制(Fable 5設計・レビュー・E2E+Codex実装)。設定キー `panel.alwaysOnTop`(registerDefaultsで既定ON)+`SettingsManager.panelAlwaysOnTop`、`show()` の level を設定値で分岐、`setPinned()` で表示中パネルをその場トグル(設定は書き換えない=次回既定値のまま)。ピンは QuickAnnotateView のツールバー右端に DSToolButtonStyle で常設(pin.fill+アクセント=固定中/pin+secondary=解除)、@State 初期値が show() ごとに設定を反映。設定シート「キャプチャ」にトグル+footer追記。実機E2E: kCGWindowLayer を真値に ①既定ONでlayer3→AXクリックで0(アイコンもアウトライン化)→再クリックで3 ②設定OFF再起動→次パネルlayer0+アウトライン初期表示 ③設定シートのトグルをAXでON→次パネルlayer3、全合格 |
| 2026-06-12 | T9.6確定+T9.8/T9.9起票 | T9.3のユーザーFB「ベリーグッド」+新要望3点を壁打ちし4決定を確定: ①パネルのピンは右上隅アイコンのクリックトグル+設定はデフォルト値(T9.8) ②エディタ下部の詳細面(OCR+メモ直接編集)は常設・Gyazo構図(T9.6スコープ確定) ③ホバー吹き出しは廃止(読みは詳細面へ一本化、検索ヒット抜粋は維持) ④URL記録はオートメーション権限のInfo.plist追加を承認・既定ON(T9.9)。推奨着手順: T9.8(小)→T9.6→T9.9(表示先がT9.6)、T9.7は詳細面の読む品質に直結するので近接して |
| 2026-06-12 | T9.6 | delegate-impl体制(Fable 5設計・レビュー・E2E+Codex実装)。新ファイル DetailPane.swift(高さ150の薄帯、左=タイトルTextField(onSubmit/フォーカス喪失で確定)+日時+メモTextEditor(即時保存)、右=OCR TextEditor選択可+全コピー、OCR空は「テキストなし」)。ContentViewのキャンバス列をVStack化し `!quickPanelActive && selectedHistoryID∈history` のとき表示、`.id(item.id)` で選択切替時のみ@Stateリセット(同一アイテムの自動OCR完了はitemプロパティ経由で反映=編集中メモが壊れない)。更新は既存漏斗 renameHistoryItem/updateNotesForItem のみ。HistoryItemPopoverと関連state/popoverモディファイア削除(承認済み廃止)、hoveredItemIDと検索ヒット抜粋は維持。canvasSize/basisに不触(fit縮小はadoptCanvasSpaceが吸収=ピクセル走査で注釈相対位置がT9.5基準と一致を確認)。実機E2E: AX座標でタイトル/メモ編集→JSON永続化・ウィンドウタイトル/セル反映・全コピー→pbpaste一致・ホバー吹き出し不在(残るのは.helpツールチップのみ)・ダーク・クイックパネル中非表示、全合格。気づき①: acceptCaptureがselectedHistoryID=nilにする既存設計のため**撮影直後(パネル完了直後含む)は詳細面が出ない**(履歴クリックで出る)— 撮影直後も新規アイテムを選択状態にするかは将来の壁打ち候補 ②キャンバスにフォーカスがある状態のキー入力はツール/色ショートカットに食われる(E2E中にデモ注釈が紫化した実例。実データ影響なし) |
| 2026-06-12 | T9.11〜T9.13起票(壁打ち) | T9.6受け入れ時のユーザー要望3点を壁打ちし確定: ①検索バーはツールバー右に**常設フィールド**(ブラウザ風、入力でサイドバー自動展開)=T9.13、T9.10と同時実施 ②注釈選択時のミニアクションは**ゴミ箱+複製の2つ**(Gyazo風・控えめ)=T9.11 — 調査でDel削除/⌘C/⌘V/⌘D複製は実装済みと判明(発見性の問題)、ユーザーへ周知済み ③詳細面は控えめ化、優先度 日付>撮影場所URL>OCR>メモ=T9.12、T9.9とセット実装。**着手順確定: T9.11→T9.9+T9.12→T9.10+T9.13** |
| 2026-06-12 | T9.14起票 | ユーザーFB「矢印が掴みづらい」(次回以降でOKとのこと)。起票時調査: ヒット判定の hitTolerance=max(線幅+8,12) → 細線は左右±6ptしか掴めない。線系のみ許容幅拡大+ズーム補正が候補、T9.11と同セッション実施可 |
| 2026-06-12 | T9.15起票 | ユーザー要望「設置した矢印の向きも簡単に変えられると」。起票時調査: ArrowAnnotation は startPoint/endPoint 保持なので反転=スワップで小さい。入口(右クリック/キー/ミニアクション3個目)は着手時に壁打ち。T9.11・T9.14と同セッション実施可 — 注釈選択まわり3点セット |
| 2026-06-12 | T9.11 | 前セッション(中断)の実装をFable 5がレビュー・デバッグして完成。明示選択時のみ選択枠上にゴミ箱+複製のミニバー(.ultraThinMaterial、上端でフリップ+ビューポートにクランプ、ズーム非追従)。クリックはキャンバスDragGestureがSwiftUI内部ディスパッチで常に勝つため、NSEventローカルモニタ(ウィンドウ配送前、RegionCapture方式)で横取り — バー非表示時はviewがwindowから外れモニタ自動解除。レビューで前セッション残骸の ScrollWheelHandler.hitTest 透過オーバーライドを除去(NSApp.currentEvent判定が実機で機能せずスクロールを殺す回帰、モニタ方式では不要)→ CanvasHelpers.swift はmainと同一に復帰。複製は⌘D漏斗(duplicateSelectedAnnotation)共用+selectionIsFromCreation=falseでバー連続表示。実機E2E: 矢印描画→明示選択でバー表示・複製(+10,+10・選択追従)・削除・ドラッグ中非表示・描画直後(creation選択)非表示・ダーク両モード、全合格。E2Eノウハウ: DragGesture(minimumDistance:1)はゼロ移動の合成クリックで発火しない(±1pxジッタ必須)/合成scrollWheelイベント(フェーズなし)はScrollWheelHandlerに届かない(スクロール検証は実機手動のみ) |
| 2026-06-12 | T9.9+T9.12 | delegate-impl体制(Fable 5設計・レビュー・E2E+Codex実装)。T9.9: BrowserSourceService(Utilities.swift、@MainActorでNSAppleScript同期実行、Safari形/Chromium形×8ブラウザ、http/httpsのみ採用)+撮影トリガ時に snapshotSourceApp() で最前面bundleIDスナップショット(クリップボード専用系は対象外)→vault.save後のTask内で取得しupdateSource漏斗で永続化(撮影レイテンシに影響なし)。VaultManifestEntry/VaultItemに追加キー sourceURL/sourcePageTitle(互換OK=annotationsBasisと同型のoptional+default)、searchText対象化、設定トグル capture.recordSourceURL 既定ON、Info.plist NSAppleEventsUsageDescription(承認済み)。Codexレビューで stale pendingSourceBundleID を3経路(領域キャンセル/ウィンドウ選択キャンセル/撮影失敗)でクリアする修正を追加(ペースト/ドロップ画像に無関係URLが付くバグ)。T9.12: DetailPane高さ150→92、メタ行=日付+🔗リンク(表示はページタイトル優先・中央省略・.help=フルURL・クリックでNSWorkspace.open)、メモはTextEditor→1行TextField(axis vertical, lineLimit 1...2, caption, secondary)で控えめ化(即時保存onChange不変)。実機E2E: Safari→URL+タイトル記録/Chrome→初回同意後に遅延記録(ブロック中AppleScriptが同意後に完走しupdateSourceされる)/非ブラウザ→記録なしで正常保存/リンククリックで既定ブラウザ起動/ライト・ダーク両モードのスクショ確認。E2Eノウハウ: クラムシェル閉=ディスプレイ0枚だと合成キーもCarbonホットキーも撮影も全死(CGGetActiveDisplayList/AppleClamshellStateで検知、caffeinate -uでは起きない)/TCC同意ダイアログの合成クリックは不可(harness安全ゲートも拒否=ユーザーが押すのが正)/SwiftUI TextFieldはAXクリック・合成クリックでフォーカスが入らない(検索・メモのUI入力E2Eは不可、ユーザー受け入れで確認) |
| 2026-06-12 | T9.7事前検討 | ユーザー依頼でFoundationModels実地プローブ。本機(macOS 26.5/M1/SDK 26.5)でコンパイル・実行可、ただし SystemLanguageModel.availability = appleIntelligenceNotEnabled — **PoC前にユーザーがシステム設定でApple Intelligenceを有効化する必要あり**。組み込みは #if canImport + #available 二重ゲートで macOS14 ターゲット・CI(旧SDK)とも互換。挿し込みは acceptCapture の updateOCR 直後の非同期二段書きが最小。詳細はT9.7本文の事前検討欄 |
| 2026-06-12 | T9.7スコープ確定 | 壁打ちでユーザー決定: **生OCRを保持**し整形結果は追加キー ocrTextPolished へ(互換維持)。二段書き(生で即検索可→整形後に置換表示)・三重ゲート・文字数比の安全弁・updateOCR時のpolished無効化・UI追加なし、で確定。**次セッション=T9.7着手**(前提: ユーザーのApple Intelligence有効化。未有効ならまず依頼)。その後 T9.10+T9.13 → T9.14+T9.15 |
| 2026-06-12 | T9.14 | rate limit残10%のためT9.7(Apple Intelligence待ち)/T9.10+T9.13(スクショ壁打ち要)を飛ばして先行実施(Codex実装+Fable 5レビュー)。実行時ヒット判定は全経路 AnyAnnotation.hitTest 経由と判明(struct側hitToleranceは実行時に使われない)— AnyAnnotation.hitTest で line/arrow のみ許容幅 max(線幅+8,22) に拡大、他注釈は従来 max(線幅+8,12)。struct側(Line/Arrow)のhitToleranceも同値でオーバーライド(整合用)。ズーム補正は今回スコープ外。**ユーザー受け入れ残: 細線矢印を近傍クリックで掴める・隣接注釈の誤選択が増えない(実機手動)** |
| 2026-06-12 | T9.15 | 前セッション(rate limitで中断)の実装を引き継ぎセッションでFable 5がレビュー・コミット。入口=選択中矢印の右クリックメニュー「向きを反転」(起票時の候補①、ミニアクション3個目はユーザーの「2つに絞る」決定を尊重し見送り・キー1発も未割当)。CanvasViewModel.reverseArrow: start/endスワップ — _basePath が concrete struct を捕捉するため ArrowAnnotation を再構築して AnyAnnotation 再ラップ(transform/doubleSided はinit経由、ラッパー専用の opacity/isLocked/lineStyle/customColorHex は明示コピーで漏れなし)。undoはスナップショット復元(clearAllAnnotationsと同型)。永続化は既存経路(アイテム切替/終了時のupdateAnnotations)に乗る。ビルド+起動スモークOK。**ユーザー受け入れ残: 右クリック→向きを反転で反転・undo可・再起動後も保持(実機手動)。入口を増やしたければ(キー/ミニアクション)次回壁打ち** |
