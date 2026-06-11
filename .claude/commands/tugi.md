---
description: delegate-impl体制でPLAN.mdの次の未完タスクに着手する(短縮起動)
---

このセッションは次の手順で進めること:

1. `.claude/commands/delegate-impl.md` を読み、その役割分担(実装=Codex優先のサブエージェント[補欠: Opus/Sonnet]、メインセッション Fable 5=設計・監査・レビュー、難所のみ直轄)をこのセッションに適用する
2. メモリと PLAN.md の進捗ログ末尾を確認し、承認済みの次タスクに着手する(引数があればそのタスクを優先: $ARGUMENTS)
3. CLAUDE.md のガードレール厳守: 1セッション=1タスク、1タスク=1コミット、`bash build-app.sh`+実機目視で受け入れ確認、PLAN.md 進捗ログ更新を同コミットに含める
