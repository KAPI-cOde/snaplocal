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

### [ ] T7.3 注釈座標系のレターボックスずれ修正(WYSIWYG)
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

#### [ ] R1.5 CanvasView.swift の分割
- **新規 `CanvasHelpers.swift`**: `ZoomNotificationHandler` / `ScrollWheelHandler` / `ScrollableNSView` / `MultilineTextInput` / `NonScrollingTextView` / `HintRow` / `makeDiagonalCursor()` / カーソルグローバル
- **新規 `CanvasOverlays.swift`**: `extension AnnotationCanvasView` として `annotationLayer` / `selectionHandlesOverlay` / `handleDot` / `cropOverlayLayer` / `drawCropOverlay` / `textInputOverlay`

#### [ ] R1.6 SnapLocalState の extension 分割
- **新規 `StateCapture.swift`**: captureNow / captureNowToClipboard / captureRegion系 / captureWindow系 / captureWithDelay / acceptCapture / handleCaptureResult / repeatLastRegionCapture
- **新規 `StateHistory.swift`**: loadHistoryItem / loadHistory / refreshHistory / navigateHistory / applySearch / deleteHistoryItem / deleteAllHistory / renameHistoryItem / updateNotesForItem / toggleStar / duplicateHistoryItem
- **新規 `StateExport.swift`**: saveAnnotatedImage(As) / exportHistoryAsZip / exportHistoryAsPDF / exportHistoryItem / copy系クリップボード / pinCurrentImage / openInPreview / shareCurrentImage
- **新規 `StateVision.swift`**: reRunOCR / detectBarcodes / detectFaceRects / autoRedactFaces / ocrSelectedRegion
- **完了時**: App.swift は概ね500行以下(App/AppDelegate/SnapLocalState本体/ContentView/チップ)

#### [ ] R1.7 HistoryQuickLook.swift の分離
- **対象**: CaptureNotification.swift から `HistoryQuickLook` + `HistoryQuickLookView` を新ファイルへ機械移動

### Phase R2: 重複排除(挙動保存・各タスク400行以内)

#### [ ] R2.1 AnnotationElement の共通化
- `applyTransform` のデフォルト実装を protocol extension に追加し、12型の同一実装を削除(**CalloutAnnotation は tailPoint 変換があるため独自実装を残す**)
- hit tolerance 式 `max(lineWidth.rawValue + 8, 12)` を protocol extension の `hitTolerance` に統一(6箇所)
- AnyAnnotation の hex パース重複を `customColorComponents` ヘルパーに統一(2箇所)
- **ガード**: stored プロパティ・Codable 形式は一切変えない。`applyTransform` は `transform.concatenating(self.transform)` の式を厳守(CLAUDE.md 落とし穴)

#### [ ] R2.2 小ユーティリティの統合(新規 `Utilities.swift`)
- `CGImage.pngData()`(PersistentVault/App の2重複)、`CGImage.nsImage`(4箇所)、アプリ前面化2行セット(5箇所)、タイムスタンプ DateFormatter(3箇所)
- `CanvasViewModel.effectiveSelectedIDs`(選択ID解決の7重複)
- `DrawingTool.supportsGrabMove`(3箇所のSet定義統一。**CanvasView側 grabCapableTools の `.select` 込み差分は意味が違うので別プロパティとして保持**)
- `AnnotationColor.isLightColor`(yellow/white判定の3重複)

#### [ ] R2.3 座標変換ヘルパーの導入 — **Fable 5 レビュー必須**
- `CanvasViewModel` に view座標→ピクセル座標変換ヘルパーを導入し6箇所の重複を置換。**Y反転あり(CI用)となし(crop用)の2系統を別メソッドとして明示**(`canvasRectToPixelCI` / `canvasRectToPixel` 等)
- **ガード**: CLAUDE.md「CoreImageの座標系」落とし穴を厳守。置換前後で各呼び出し箇所の数式が同値であることをレビューで確認

#### [ ] R2.4 Toolbar.swift 内の重複排除
- NSColorSampler→hex変換ブロック(2箇所完全コピー)をメソッド化
- 調整スライダー4行を `adjustmentRow(...)` ViewBuilder に統一

#### [ ] R2.5 対角カーソル生成の統合
- CanvasView.swift `makeDiagonalCursor()` と RegionCapture.swift `ResizeHandle.diagonalResizeCursor()` のほぼ同一実装を1箇所に統合

### Phase R3: デッドコード除去

#### [ ] R3.1 デッドコード削除(調査結果に基づき内容確定)
- 並列調査3本目(デッドコード)の結果リストから、確信度 high(grep参照ゼロ確認済み)のみ削除。medium 以下は進捗ログに記録して残す
- **ガード**: index.json.bak 関連・AnnotationType raw value・AppIntents・Codableキーは削除禁止

### Phase R4: 構造改善(永続化互換レビュー必須 — Fable 5 直接実装)

#### [ ] R4.1 MosaicAnnotation / BlurAnnotation の統合検討
- 2型は `type` と CIFilter 以外ほぼ全フィールド・全メソッド同一(約40行重複)。統合する場合、**旧形式で保存済みの mosaic/blur 注釈が新コードでデコードできること**をテストで証明してから着手。リスクが利益を上回ると判断したら「見送り」を進捗ログに記録して完了扱い

### Phase R5: 仕上げ

#### [ ] R5.1 最終監査
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
