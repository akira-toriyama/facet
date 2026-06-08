# Roadmap board — 運用ワークフロー (GTD)

この repo の roadmap board（GitHub Projects）の運用ルール。
トミーの roadmap-managed repo すべてで **同一内容**。canonical な編集元は
`akira-toriyama/facet` のこのファイル — 変更はそこで行い、各 repo に展開する。
（AI 側のミラーは Claude memory `roadmap-board-status-workflow`。）

## Status（6 列・board の左 → 右）

| Status | 意味 |
|--------|------|
| 📥 **Inbox** | capture。何も考えず放り込む。週次レビューで 0 に。 |
| 📋 **Backlog** | やる予定。コミット済・未スコープ。grill で Ready へ昇格。 |
| ✅ **Ready** | 着手可。grill / スコープ確定済。次に拾う。**WIP 2〜3**。 |
| 🔨 **In Progress** | 作業中（PR レビュー中も含む）。 |
| ✔️ **Done** | merge / close 済。 |
| 🧊 **Icebox** | someday。いつかやる。脇の冷凍庫。 |

## Hot path

```
Inbox → Backlog → Ready → In Progress → Done
```

直線が hot path。**Done と Icebox は脇**（本線ではない）。Icebox は末尾の
冷凍庫で、レビュー時しか触らない。

## ルール

- **Inbox は週次レビューで 0 キープ**。溜めない。
- **Inbox の行き先 = Backlog（やる） or Icebox（someday）**。
  - 例）「UI 音声操作可能化」= Icebox（いつか）
  - 例）「README 更新」= Backlog（やる）の温度感
- **迷ったら Inbox**。分類不明な issue は Inbox に置いて週次で捌く。
  open issue を board 外に残さない（= 迷子を作らない）。
- **grill ゲートは Backlog → Ready**。スコープが固まって初めて Ready。
- **Ready は 2〜3 個まで（WIP limit）**。GitHub は上限を強制しないので
  自己管理。超えたら警戒。
- **Review 段は無し**（In Progress が PR 中を吸収）。Blocked 段も無し
  （必要なら label で）。

## 構造

- repo ごとに 1 枚の Project board（横断 1 枚ではない）。
- owner = `akira-toriyama`（user-level project）。
