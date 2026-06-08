# SnapLocal ビルド・起動ガイド（修正版）

## 修正内容の概要

このガイドは、SnapLocal の UI 表示問題と権限ダイアログ名の問題を修正した後の、正しいビルド・起動方法を説明します。

## 主な修正点

### 1. LSUIElement フラグの修正
- **ファイル**: `Sources/SnapLocalApp/Info.plist`
- **変更**: `LSUIElement` を `true` → `false`
- **効果**: アプリがウィンドウを表示する GUI アプリケーションとして認識されます

### 2. ウィンドウレイヤー・フォーカス制御の実装
- **ファイル**: `Sources/SnapLocalApp/App.swift`
- **追加**: `AppDelegate` クラスを新規追加
- **効果**:
  - ウィンドウが常に前面に表示されます（.floating レベル）
  - アプリがフォアグラウンドで起動します
  - 撮影UI が他のウィンドウに隠れません

### 3. macOS .app バンドル化ビルドスクリプト
- **ファイル**: `build-app.sh`
- **目的**: Swift Package を正式な macOS アプリケーション構造に変換
- **効果**: Bundle ID と Info.plist が正しく認識され、権限ダイアログに正しいアプリ名が表示されます

## ビルド手順

### ステップ 1: ビルドスクリプトを実行

```bash
cd /Users/mac/Downloads/SnapLocal
chmod +x build-app.sh
bash build-app.sh
```

**出力例**:
```
Building Swift package...
[...build output...]
Build complete! (2.03s)

Creating .app bundle structure...
Copying binary...
Copying Info.plist...
Copying resources...

Build complete: /Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app

To run the app:
  open /Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app
```

## 起動方法

### 推奨方法 1: open コマンド（最も簡単）

```bash
open /Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app
```

**利点**:
- macOS が .app バンドル構造を完全に認識します
- Bundle ID が正しく読み込まれます
- 権限ダイアログに「SnapLocal」と表示されます
- ウィンドウが前面に表示されます

### 推奨方法 2: 直接バイナリ実行

```bash
/Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app/Contents/MacOS/SnapLocal
```

**利点**: 
- .app パッケージの正式な構造で実行されます
- Info.plist が有効になります

### ❌ 非推奨: 古い方法（修正前）

```bash
# 使用しないでください
/Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal
```

**理由**:
- ターミナルから直接バイナリを実行しています
- Bundle ID が認識されません
- 権限ダイアログに「Terminal」と表示されます
- UI が正しく表示されません

## 動作確認チェックリスト

アプリを起動した後、以下を確認してください：

### UI 表示の確認

- [ ] ウィンドウがデスクトップに表示されている
- [ ] ウィンドウにタイトルバー「SnapLocal」が表示されている
- [ ] ツールバー（撮影、保存、編集ツール）が表示されている
- [ ] キャンバスエリア（中央）が表示されている
- [ ] 履歴パネル（右側）が表示されている（履歴がある場合）

### 撮影機能の確認

1. 「撮影する」ボタンを クリック
2. **期待される動作**:
   - [ ] 「撮影中…」メッセージが画面下部に表示される
   - [ ] **スクリーンレコーディング権限リクエストダイアログが表示される**
   - [ ] ダイアログのアプリ名が「SnapLocal」であることを確認
   - [ ] 「許可」をクリック
3. **撮影完了後**:
   - [ ] キャンバスにスクリーンショットが表示される
   - [ ] 「撮影しました」メッセージが表示される

### 権限ダイアログの確認（重要）

スクリーンレコーディング権限リクエストダイアログを確認する際：

```
┌─────────────────────────────────────────┐
│ "SnapLocal" は画面収録へのアクセスを    │
│ 求めています                           │
│                                         │
│ [許可しない]              [許可]        │
└─────────────────────────────────────────┘
```

**確認点**:
- [ ] ダイアログのアプリ名が「SnapLocal」である（「Terminal」ではない）
- [ ] 権限が正しく認識されている

## .app パッケージの構造

```
SnapLocal.app/
├── Contents/
│   ├── Info.plist
│   │   ├── CFBundleIdentifier: com.snaplocal.app
│   │   ├── CFBundleName: SnapLocal
│   │   ├── LSUIElement: false
│   │   └── NSScreenCaptureUsageDescription: (権限説明)
│   ├── MacOS/
│   │   └── SnapLocal (実行可能ファイル)
│   └── Resources/
│       └── (リソースファイル)
```

## トラブルシューティング

### ウィンドウが表示されない場合

1. **AppDelegate が初期化されているか確認**:
   ```swift
   @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
   ```

2. **LSUIElement が false になっているか確認**:
   ```bash
   cat /Users/mac/Downloads/SnapLocal/Sources/SnapLocalApp/Info.plist | grep -A1 LSUIElement
   ```

3. **ビルドスクリプトで .app が正しく生成されたか確認**:
   ```bash
   ls -la /Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app/Contents/
   ```

### 権限ダイアログに「Terminal」と表示される場合

1. **起動方法を確認**: `open` コマンドで起動しているか
2. **Info.plist が .app に含まれているか確認**:
   ```bash
   cat /Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app/Contents/Info.plist | grep CFBundleIdentifier
   ```
3. **ビルドスクリプトを再実行**: 新しい Info.plist が反映されたか確認

### 撮影がうまくいかない場合

1. **スクリーン収録権限を付与してください**:
   ```
   システム設定 > プライバシーとセキュリティ > 画面収録
   → SnapLocal を有効にする
   ```

2. **既存の権限をリセットしたい場合**:
   ```bash
   defaults delete com.snaplocal.app
   ```

## CLI 版（SnapLocalCLI）について

このリポジトリには CLI 版もあります：
- ビルド: `swift build -c debug`
- 実行: `/Users/mac/Downloads/SnapLocal/.build/debug/snaplocal`

GUI 版（SnapLocalApp）とは独立しており、この修正による影響はありません。

---

**最終更新**: 2026-06-08
**対象バージョン**: SnapLocal v0.1.0
