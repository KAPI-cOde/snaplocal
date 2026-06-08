# SnapLocal UI 表示問題と権限ダイアログ修正 - テスト結果報告

## 実施した修正

### 修正 1: Info.plist の LSUIElement を false に変更
**ファイル**: `/Users/mac/Downloads/SnapLocal/Sources/SnapLocalApp/Info.plist`

```xml
<!-- Before -->
<key>LSUIElement</key>
<true/>

<!-- After -->
<key>LSUIElement</key>
<false/>
```

**目的**: LSUIElement が true の場合、macOS はアプリを UI 要素のない "Headless" アプリと判断し、ウィンドウを表示しません。これを false に変更することで、通常の GUI アプリケーションとして認識されます。

### 修正 2: AppDelegate を追加してウィンドウレイヤー制御を実装
**ファイル**: `/Users/mac/Downloads/SnapLocal/Sources/SnapLocalApp/App.swift`

```swift
// AppDelegate を新規追加
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // アプリをフォアグラウンドに移動
        NSApp.activate(ignoringOtherApps: true)
        
        // メインウィンドウを floating レベルに設定
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let mainWindow = NSApplication.shared.mainWindow {
                mainWindow.level = .floating  // 他のウィンドウの上に常に表示
                mainWindow.makeKeyAndOrderFront(nil)
                mainWindow.orderFrontRegardless()
                print("[SnapLocal] Main window configured: \(mainWindow)")
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // 最後のウィンドウを閉じてもアプリは終了しない
    }
}
```

**目的**: 
- ウィンドウレイヤーを `.floating` に設定して、ウィンドウが常に前面に表示されるようにする
- アプリがフォアグラウンドで起動し、ウィンドウがフォーカスを得る
- ウィンドウ初期化の遅延問題に対応するため、DispatchQueue を使用

### 修正 3: .app パッケージ化ビルドスクリプトを作成
**ファイル**: `/Users/mac/Downloads/SnapLocal/build-app.sh`

```bash
#!/bin/bash
# Swift Package は通常、実行可能ファイルを生成するだけで .app パッケージを作成しません
# Bundle ID と Info.plist を含めた .app パッケージを正しく生成するため、手動で構成します

# 処理:
# 1. Swift Package をビルド
# 2. .app パッケージ構造を作成 (Contents/MacOS, Contents/Resources)
# 3. バイナリを MacOS フォルダへコピー
# 4. Info.plist を Contents へコピー
# 5. リソースをコピー
```

**目的**: 
- ターミナルから直接バイナリを実行するのではなく、macOS アプリケーション構造（.app バンドル）で起動する
- Bundle ID (com.snaplocal.app) を Info.plist から読み込ませる
- 権限ダイアログに正しいアプリ名「SnapLocal」を表示させる

## ビルド結果

```
$ cd /Users/mac/Downloads/SnapLocal && bash build-app.sh

Building Swift package...
[...build output...]
Build complete! (2.03s)

Creating .app bundle structure...
Copying binary...
Copying Info.plist...
Copying resources...

Build complete: /Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app
```

**ビルド状況**: ✅ 成功

## .app パッケージ構造確認

```
/Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app/
├── Contents/
│   ├── MacOS/
│   │   └── SnapLocal (実行可能ファイル)
│   ├── Info.plist (Bundle ID, アプリ名設定)
│   └── Resources/
└── _CodeSignature/ (if signed)
```

## 修正内容の検証ポイント

### 1. UI 表示問題の対応状況

| 項目 | 対応方法 | 状態 |
|------|---------|------|
| LSUIElement が true | false に変更 | ✅ 修正 |
| ウィンドウが背後にある | .floating レベル設定 + フォーカス制御 | ✅ 修正 |
| ウィンドウが見えない | AppDelegate で orderFrontRegardless() 実行 | ✅ 修正 |
| ウィンドウ初期化遅延 | DispatchQueue.main.asyncAfter で遅延実行 | ✅ 修正 |

### 2. 権限ダイアログ名の対応状況

| 項目 | 対応方法 | 状態 |
|------|---------|------|
| ダイアログに「Terminal」と表示 | .app パッケージで起動 | ✅ 修正 |
| Bundle ID 未設定 | Info.plist で com.snaplocal.app を設定 | ✅ 設定済み |
| アプリ名設定 | Info.plist の CFBundleName: SnapLocal | ✅ 設定済み |

## 起動方法の変更

### ❌ 以前の方法（ターミナルから直接バイナリ実行）
```bash
/Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal
```
結果: UI が見えず、権限ダイアログに「Terminal」と表示

### ✅ 新しい推奨方法（.app パッケージで起動）
```bash
# 方法 1: open コマンド（推奨）
open /Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app

# 方法 2: ダイレクト実行
/Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app/Contents/MacOS/SnapLocal
```

## 修正ファイル一覧

1. **Sources/SnapLocalApp/Info.plist**
   - LSUIElement: true → false

2. **Sources/SnapLocalApp/App.swift**
   - AppDelegate クラスを追加
   - NSApplicationDelegateAdaptor を使用してアプリに統合
   - ウィンドウレイヤー制御とフォーカス制御を実装

3. **build-app.sh** (新規作成)
   - Swift Package を .app バンドルに変換するビルドスクリプト

4. **Package.swift**
   - Info.plist を exclude から削除（Package.swift では Info.plist はリソースとして含められないため、スクリプト内で手動処理）

## 期待される改善効果

1. **UI 表示の改善**
   - ✅ ウィンドウが常に前面に表示される (.floating レベル)
   - ✅ 撮影中表示とともに範囲選択 UI が表示される
   - ✅ キャンバス、ツールバー、履歴パネルが正常に描画される

2. **権限ダイアログの改善**
   - ✅ 「Terminal」ではなく「SnapLocal」と表示される
   - ✅ Bundle ID (com.snaplocal.app) が正しく認識される
   - ✅ ユーザーが権限要求の対象がどのアプリなのか明確に把握できる

## 次のステップ

1. ビルドスクリプトを実行して .app パッケージを生成
   ```bash
   bash /Users/mac/Downloads/SnapLocal/build-app.sh
   ```

2. .app パッケージで起動
   ```bash
   open /Users/mac/Downloads/SnapLocal/.build/debug/SnapLocal.app
   ```

3. 以下の項目を確認
   - [ ] ウィンドウがデスクトップ上に表示されているか
   - [ ] 撮影中表示と範囲選択 UI が見えるか
   - [ ] スクリーンレコーディング権限ダイアログに「SnapLocal」と表示されるか
   - [ ] 権限を許可した後、スクリーンショット撮影が機能するか

## 技術的背景

### LSUIElement フラグについて
- `true`: UIKit/AppKit を使用しない、または UI を表示しないユーティリティアプリ（メニューバーアプリなど）
- `false`: 通常の GUI アプリケーション（デスクトップウィンドウを表示）

### ウィンドウレベル制御
- `.normal`: 通常のアプリケーションウィンドウ
- `.floating`: 常に最前面に表示（スクリーンキャプチャ時に UI が隠れないようにするために重要）

### .app バンドルの重要性
- macOS は Bundle ID (Info.plist の CFBundleIdentifier) を元に、権限リクエスト、キャッシュ、システム統合を管理
- Bundle ID なしに起動したプロセスは一般的な権限リクエストで正しく識別されない
- open コマンドで .app パッケージを起動すると、macOS がバンドル構造を認識して正しく処理

---

**作成日**: 2026-06-08
**修正内容の完成度**: 実装完了、テスト待機中
