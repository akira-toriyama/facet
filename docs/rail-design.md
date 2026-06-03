# rail — summoned WS switcher（Theme D (ii) 設計メモ）

Status: ✅ **shipped #109 (2026-05-31)** — `facet --view=rail` として出荷（`Sources/FacetViewRail/`、`canonicalViews` に登録）。⚠️ **実装は本メモの当初設計から乖離**: shipped 版は「画面下部チップ + 中央ホバープレビュー」ではなく、**全画面 backdrop + 中央 HERO（active WS を大表示）+ 画面下部に全 WS の window サムネ列**（grid 寄りの俯瞰）。←/→ で browse・click で切替・window / header ドラッグで move / swap。以下本文は **Theme D (ii) grill 当時の設計記録**。コードの正は `Sources/FacetViewRail/`（RailView / RailOverlay / RailHeader / RailDrag）。
図解: [`theme-d-rail.excalidraw`](theme-d-rail.excalidraw)
（Excalidraw で再編集可。Theme D 全体は [architecture.md](architecture.md) の "Future themes" 参照）

## rail とは

WS を横一列で見せる **召喚式の「速い切り替え」ビュー**（Mission Control /
Win11 タスクビュー型）。Grid と同じく一時的に画面へ重ねて表示し、操作後に
閉じる。常設ではない。

- ホットキーで召喚 → 操作 → Esc で閉じる（Grid の召喚 / dismiss を流用）
- 画面下部に WS を横一列のチップで並べる（チップ＝番号 + アプリアイコン）
- **ホバー → 中央に 1 枚だけ大きくプレビュー**（詳細はチップではなく中央プレビューが担う）
- クリックで切替

## 決定事項（6 課題の決着）

| # | 課題 | 結論 |
|---|------|------|
| 1 | 常設だと画面の場所を取り合う（タイリングと衝突） | **消滅** — 召喚式なので一時的に重ねるだけ。タイリング領域の予約は不要 |
| 2 | 並べ替えで hotkey 番号がズレる | **A = swap を採用** — ドラッグは grid と同じ「スロット固定・中身だけ交換」。Phase α の番号保存凍結を守る。true reorder（番号振り直し）は不採用 |
| 3 | view か dock か / ライフサイクル | **Grid と同じ召喚式 view** として扱う（`--view=rail` 想定）。dock ではない |
| 4 | 中央プレビューの配置・multi-display | 軽微。`PreviewOverlayPool` 流用 + 配置ロジックのみ新規（詳細は未着手） |
| 5 | Grid と機能が重複しないか | **両方いる** — 役割が違う。rail = 速い切替（switcher）/ Grid = じっくり管理（manager, window 移動・セルスワップ・俯瞰）。共存 OK＝ rail は作る価値あり |
| 6 | focus を奪わないか | ほぼ解決。`KeyablePanel` の非アクティブパターン（`--active` 時のみ key 化） |

### overflow（WS が増えた時）

> ⚠️ **M9-3 / M9-4 でこの当初方針（no-scroll・shrink→wrap）を覆した。**
> 実装は **固定サイズ cell + スクロール**: `[rail] cells` 個を 1 列に出し、
> 超過分は縮小せず strip をスクロール（見切れ peek で「まだある」合図）、
> browse は端で wrap（循環）。理由＝多 WS でも cell が潰れず認識性を保つ方が
> dogfood で勝った。下の当初案は歴史的記録。

当初案（不採用）: scroll は採用しない（要素が隠れ「一眺」に反する）。
**折り返し（wrap）**で全 WS 可視を維持:

1. まずチップを shrink（番号 + アイコンだけなので耐性が高い）
2. 下限を割ったら 2 行目に wrap（番号順は維持）
3. 行数にも上限（2〜3）を設け、それ以上はさらに縮小

## 実装の見立て

共有層 `FacetView` の既存部品でほぼ賄える:

| 必要 | 流用部品 |
|------|----------|
| ホバー→中央プレビュー（WS の全 window をまとめて表示） | `PreviewOverlayPool` + `PreviewOverlay` |
| window 画像キャプチャ（TTL キャッシュ） | `WindowPreview`（ScreenCaptureKit） |
| focus を奪わない召喚パネル | `KeyablePanel` |
| 配色 / テーマ | `Theme` / `Palette` |

**新規で書くのは実質 2 つ**:

1. 横一列レイアウト計算（shrink → wrap の純関数。`GridMath` 相当 → FacetCore でユニットテスト可能）
2. rail パネルのコントローラ（Tree / Grid のコントローラと同型）

DnD / クリックは既存の「掴んだ対象がアクションを決める」モデルを踏襲。

## 未着手 / 次に詰める

- ~~召喚ホットキー・CLI（`facet --view=rail` の是非）~~ → ✅ `--view=rail` で shipped (#109、`canonicalViews`)。なお既定 view 化は不可（`effectiveDefaultView` は tree/grid のみ受理）
- 課題4 の中央プレビュー配置ロジックと multi-display の挙動（実装済 HERO + サムネ列での詰めは将来の rail edge/scroll 強化で継続）
- 着手前 invariants（[architecture.md](architecture.md) と同じ）: `facet-buddha-palm-principle`
  / `facet-scope-exclusions` / `WindowBackend` protocol 経由設計を壊さない
