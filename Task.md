# Task — facet tree 修正依頼

> **状態: 聞き取り中（intake / 聞き役モード）。** トミーが「修正してほしいこと」を
> 順に挙げる → クロードは解決策を出さず記録に徹する。出揃ったら feasibility →
> 実装計画 → 実装セッションへ。
>
> **進め方（トミー指定）**
> - 1セッションで完結しなくてよい。計画セッションと実装セッションを分けてOK。
> - セッション跨ぎの引き継ぎは**この `Task.md` に集約**（未達成を暗黙にしない）。
> - 品質重視・破壊的変更すべてOK・必要ならリファクタOK・プラン再作成OK。
> - **各 item のルーティン**: ① 修正 → ② `swift build` → ③ Task.md 更新 →
>   ④ commit（stack・**push は許可があるまでしない**）→ ⑤ **`./run.sh` 必須**（実機反映）。

## 修正依頼一覧

- [x] **1. workspace emoji の形式** ✅ 完了（caveat ゼロ・退行ゼロで再実装）
  - 表示: **「絵文字 + 英語名」**（例: `🐶 Dog` `🐱 Cat` …）
  - 設計: **識別子＝素の絵文字（`🐶`・space-free）／ 表示だけ `🐶 Dog`** に分離（識別と表示を分ける）
    - [WorkspaceNaming.swift](Sources/FacetCore/WorkspaceNaming.swift): pool は素の絵文字に戻す＋`words[]`＋純関数 `displayLabel(forName:)`（`🐶`→`🐶 Dog`・overflow `🐶2`→`🐶 Dog2`・非pool/rename はそのまま）
    - [WorkspaceLabel.swift](Sources/FacetCore/WorkspaceLabel.swift): 共有 `workspaceShortLabel` 末尾を `displayLabel` 経由に → grid/rail は自動で friendly 化
    - [SidebarView.swift](Sources/FacetViewTree/SidebarView.swift): tree の `.uppercased()` を4箇所撤去し `workspaceShortLabel` 経由に → `🐶 Dog`（**`DOG` ではない**。lens/grid/rail と一致）
  - **退行なし**: `facet workspace --focus 🐶`（素の絵文字）はむしろ**動くように**なる・DNC/match/query は素の絵文字のまま・lens 識別キーは無傷
  - test: WorkspaceNamingTests に displayLabel/words 4本追加（CI 実行）
  - 検証: `swift build` ✅ ／ CLI（focus 🐶・query）はクロード ／ 実機目視はトミー

- [x] **2. config.toml「迷子」ラベルの英語化** ✅ 完了（→ **"Orphans"**）
  - 英単語: **"Orphans"**（コードベース既存の "orphan" 用語に合わせる）
  - 変更（user-facing「迷子」を英語化）:
    - **両 config.toml**（repo + `~/.config/facet/`）: lens `label = "Orphans"` ＋ 受け皿コメント英語化
    - 実行表示: `facet query` の orphan 表示 [NativeAdapter+QueryCommand.swift:140](Sources/FacetAdapterNative/NativeAdapter+QueryCommand.swift#L140) → `workspace: "Orphans"`
  - 📌 **未対応（内部・暗黙にしない）**: dev ログ文字列（Tagging/NativeAdapter）・schema 説明（FacetConfig+Spec → config.schema.json）・~20 の内部コメント「EX-3 迷子」・glossary/README/architecture の用語「迷子(orphan)」・test fixture の "迷子" ラベル。**= 内部の概念名**。これらも英語化するか別途確認（item 2-b 候補）

- [x] **2.1 workspace ラベルの emoji を最後に** ✅ 完了（`🐶 Dog` → `Dog 🐶`）
  - [WorkspaceNaming.swift](Sources/FacetCore/WorkspaceNaming.swift) `displayLabel` の並び順を反転（識別子＝素の絵文字は不変・**表示のみ**）
  - overflow も emoji 最後: 識別子 `🐶2` → 表示 `Dog2 🐶`
  - tree/grid/rail 全 view に反映（共有 `workspaceShortLabel` 経由）／ test 2本更新

- [x] **3. section の DnD（並び替え reorder）** ✅ 完了（tree/grid/rail 実機 Good）
  - **確定スペック**: section（workspace も lens も）を1単位で掴んで**並び替え**。
    - **表示順のみ**（窓は動かない・tiling 不変）／ **tree+grid+rail 全部**で掴めて、3 view 一貫反映
    - **session のみ**（`config.toml` は書かない＝鉄則維持・再起動で config 順に戻る）／ **mac desktop またぎ無し**
    - 挿入型（insert-between）・型混在 OK（lens の列に workspace を差し込み可）・ドロップ表示は挿入線
  - **核心**: projection の**出力**（`lastSections`）を session 並び替え。入力 `[DesktopSection]` を並べ替えると workspace の位置束縛（`FilterProjection` wsCursor）で窓が再束縛されるため厳禁。ルーティングは `sourceWorkspaceIndex` 経由なので窓は不動。
  - 実装:
    - [SectionOrder.swift](Sources/FacetCore/SectionOrder.swift) 純関数（stable-partition + insert-between・CI test [SectionOrderTests.swift](Tests/FacetCoreTests/SectionOrderTests.swift)）
    - Controller: session var `macDesktopSectionOrder` + [Controller+Reorder.swift](Sources/FacetApp/Controller+Reorder.swift) `reorderSection` + apply() の単一チョークポイント（`lastSections`）で3 view 反映
    - tree: [SidebarView+Drag.swift](Sources/FacetViewTree/SidebarView+Drag.swift) mode 4 + 挿入線 / grid: [GridView.swift](Sources/FacetViewGrid/GridView.swift) header-drag→reorder（旧 swap 置換）/ rail: [RailView.swift](Sources/FacetViewRail/RailView.swift) 同上 / 共通 seam [Controller+Overview.swift](Sources/FacetApp/Controller+Overview.swift) `onReorder`
  - 副次効果: grid/rail のヘッダ掴みが旧 swap（窓移動）→ reorder に置換され、**ヘッダ掴み起因の「窓が動く」は解消**
  - 📌 **未対応（暗黙にしない）**: キーボード Space のヘッダ持ち上げは旧 swap のまま（マウス reorder を優先実装）。希望あれば reorder 化。

- [ ] **4. tree のキーボード操作が効かない**
  - tree がキーボード操作を受け付けない（再現条件は本人の補足待ち）

- [ ] **5. grid のウィンドウが offscreen に居座る（park/restore リグレッション）**
  - **症状**: grid を開いて閉じた後、**アクティブ workspace の窓が画面の一部だけ（右 ~65%・左半分が黒）に居座り復帰しない**。再起動/手動操作まで戻らない。
  - **トミーの見立て**: section reorder とは**無関係の別バグ**・おそらく **filter pivot 対応で壊れた**。今回の reorder 変更（窓位置/park に未介入）が原因でもない。
  - **証拠（2026-06-23 動画 `画面収録 21.10.30.mov` + `/tmp/facet.log`）**:
    - `native: switchWorkspace 2 -> 1 autoFocus=true` → `anchor parked=0 restored=1` の後、
    - `native: classify ... onscreen=0 offscreen=4` が継続 = **アクティブ WS の窓まで offscreen 扱いのまま on-screen 復帰していない**。
  - **疑い箇所（着手は systematic-debug で file:line 追跡）**:
    - lens 解除 / workspace 切替時の **anchor park → restore** の復元漏れ（`reconcileHidden` / `revealWindow` / lens-clear 経路）
    - もしくは **float レイアウト**時の位置復元（float 窓は park 後に元 frame を戻す主体が誰か）
    - grid を閉じる際の最終 reconcile が park 状態を on-screen に戻し切れていない可能性
  - **再現待ち（要トミー補足）**: grid で具体的にどの操作か（lens セルをクリック？ 窓サムネを別 WS へドラッグ？ ただ開閉？）。トリガを1つに絞れると一気に詰まる。

---

_補足: 上記 1–4 は内部で feasibility 調査済み（着手箇所を把握）。聞き取り完了後に提示する。_
