import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// T9.7: 生OCRテキストをオンデバイスLLM(Apple Foundation Models)で「軽く整える」。
/// 三重ゲート(canImport + #available + availability)— 非対応環境・失敗・安全弁違反は nil(静かにスキップ、生OCR維持)
enum OCRPolishService {
    /// PoC実測: 25字の断片に対しモデルが455字の創作を返した。短文はそもそも整形不要
    private static let minChars = 200
    /// コンテキスト4096トークン制約。超過は respond が throw し catch で生維持だが、無駄な実行を避ける
    private static let maxChars = 3000
    /// 整形前後の文字数比の許容範囲(要約・創作の機械的検出)
    private static let ratioRange = 0.7...1.4

    nonisolated static func polish(_ raw: String) async -> String? {
#if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minChars, trimmed.count <= maxChars else { return nil }
        guard SystemLanguageModel.default.availability == .available else { return nil }

        do {
            // この指示文は実機PoC(2026-06-12)で品質検証済み — 変更時は再計測すること
            let session = LanguageModelSession(instructions: """
            あなたはOCR結果の整形係です。スクリーンショットからOCRで抽出したテキストを、内容を変えずに読みやすく整えてください。
            ルール:
            - 要約・言い換え・翻訳・新しい内容の追加をしない
            - 元のテキストの語句をできる限りそのまま使う
            - 不自然な改行を直し、同じ文の断片をつなげる
            - 明らかなOCR誤認識(文字化け・脱字)だけ修正する
            - メニュー名やUIラベルなど意味の薄い断片はそのまま残してよい
            - プレーンテキストのみで出力する。マークダウン記号や箇条書き記号を新しく追加しない
            - 整形後のテキストだけを出力する(前置き・説明は不要)
            """)
            let response = try await session.respond(
                to: trimmed,
                options: GenerationOptions(sampling: .greedy)
            )
            let polished = stripMarkdownDecoration(response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !polished.isEmpty else { return nil }
            let ratio = Double(polished.count) / Double(trimmed.count)
            guard ratioRange.contains(ratio) else { return nil }
            return polished
        } catch {
            return nil
        }
#else
        return nil
#endif
    }

    /// 実測でモデルが **強調** や行頭の箇条書き記号を勝手に足す(プロンプトでは抑止しきれない)ため機械的に除去。
    /// 行頭の `- ` はOCR原文に頻出するので触らない
    nonisolated static func stripMarkdownDecoration(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { return nil }
                var cleaned = line.replacingOccurrences(of: "**", with: "")
                cleaned = cleaned.replacingOccurrences(
                    of: #"^\s*\*\s+"#, with: "", options: .regularExpression)
                cleaned = cleaned.replacingOccurrences(
                    of: #"^\s*#{1,6}\s+"#, with: "", options: .regularExpression)
                return cleaned
            }
            .joined(separator: "\n")
    }
}
