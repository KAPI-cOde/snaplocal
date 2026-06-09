import SwiftUI

/// デザイントークン名前空間。
/// UI面のpadding・角丸・フォントサイズ・アニメーション・影は必ずここの値を使う。
/// 画像出力に焼き込まれる値(アノテーション描画・renderAnnotations)は対象外。
enum DS {

    /// 余白スケール(6段階)。中間値が欲しくなったら近い段階に吸着させる。
    enum Space {
        /// 4pt
        static let xxs: CGFloat = 4
        /// 8pt
        static let xs: CGFloat = 8
        /// 12pt
        static let s: CGFloat = 12
        /// 16pt
        static let m: CGFloat = 16
        /// 24pt
        static let l: CGFloat = 24
        /// 32pt
        static let xl: CGFloat = 32
    }

    /// 角丸スケール(3段階)。
    enum Radius {
        /// 4pt — サムネイル・小バッジ・ツールボタン背景
        static let small: CGFloat = 4
        /// 8pt — ポップオーバー内パネル・チップ
        static let medium: CGFloat = 8
        /// 12pt — シート・大きなカード
        static let large: CGFloat = 12
    }

    /// フォントサイズ(4段階)。
    enum FontSize {
        /// 9pt — 補助ラベル・バッジ
        static let caption2: CGFloat = 9
        /// 11pt — キャプション・セクション見出し
        static let caption: CGFloat = 11
        /// 13pt — 本文
        static let body: CGFloat = 13
        /// 18pt — タイトル
        static let title: CGFloat = 18
    }

    /// アニメーション(3種)。新しいdurationを発明しない。
    enum Anim {
        /// 0.12s easeIn — 即時フィードバック(出現)
        static let fast: Animation = .easeIn(duration: 0.12)
        /// 0.15s easeOut — 標準(ズーム・選択・状態変化)
        static let base: Animation = .easeOut(duration: 0.15)
        /// 0.2s easeInOut — パネル開閉・レイアウト変化
        static let smooth: Animation = .easeInOut(duration: 0.2)
    }

    /// 影(2種)。`view.shadow(DS.Shadow.overlay)` の形で使う。
    enum Shadow {
        /// オーバーレイ要素(チップ・バッジ・ポップオーバー)
        static let overlay = ShadowStyle(radius: 4, y: 2)
        /// キャンバス上の画像
        static let canvas = ShadowStyle(radius: 12, y: 4)

        struct ShadowStyle {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat

            init(color: Color = .black.opacity(0.25), radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
                self.color = color
                self.radius = radius
                self.x = x
                self.y = y
            }
        }
    }
}

extension View {
    /// DS.Shadow のスタイルを適用する。
    func shadow(_ style: DS.Shadow.ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}
