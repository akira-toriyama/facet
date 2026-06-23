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
  - **トミーの見立て（的中）**: section reorder とは**無関係の別バグ**・**filter pivot（EX-1 union-tile）で壊れた**。今回の reorder 変更は無関係。
  - **✅ ROOT CAUSE 確定**（並行調査 workflow + ログ `section-lens-union frames=1 applied=0 rect=(0,0,5120,2160)` ループ）— 4連鎖:
    1. lens active 中、`applyLayout` は workspace layout を無視し union タイル（[NativeAdapter+Scratchpad.swift:519](Sources/FacetAdapterNative/NativeAdapter+Scratchpad.swift#L519)）。**float モード home の窓も除外されず**（除外はリテラル floating のみ・[WorkspaceCatalog+SectionLens.swift:106-113](Sources/FacetAdapterNative/WorkspaceCatalog+SectionLens.swift#L106-L113)）→ float 窓が partial-width タイルに**リサイズ**される（master系で右0.65＝「右65%・左黒」）。
    2. anchor park/restore は **position のみ・size 非保存**（[WorkspaceCatalog.swift:156](Sources/FacetAdapterNative/WorkspaceCatalog.swift#L156) / [NativeAdapter+Anchor.swift:42-48](Sources/FacetAdapterNative/NativeAdapter+Anchor.swift#L42-L48)）。
    3. lens 解除時、float の `applyLayout` は **完全 NO-OP**（float にエンジン無し）→ 縮んだ frame が**永久凍結**。
    4. マッチ窓は park されない（park は非マッチのみ [WorkspaceCatalog+SectionLens.swift:80-85](Sources/FacetAdapterNative/WorkspaceCatalog+SectionLens.swift#L80-L85)）→ 復元用保存 frame が**どこにも無い**。
    - 引き金 = lens の activate/clear（grid セルクリック→`activateSection→switchWorkspace`）。grid 開閉自体は無実。条件 = **同じ窓が `type=workspace`(float) と `type=lens` に居る multi-match**（トミー仮説どおり）。
  - **🔧 FIX（採用案 A・破壊的変更OK）**: **lens は各窓の home layout 契約を尊重** — `sectionLensUnionMembers` に「**float モード home の窓を除外**」を追加（リテラル floating 除外の対称拡張）。float では lens=可視性フィルタ（マッチ窓は元位置表示・非マッチは park）。tiled(bsp/stack/master系) home はリサイズ可逆なので従来通り union タイル。orphan は home 無しなので union 維持。
    - 実装: [WorkspaceCatalog+SectionLens.swift](Sources/FacetAdapterNative/WorkspaceCatalog+SectionLens.swift) `isFloatModeHome` 除外 ＋ CI test 2本（[SectionLensCatalogTests.swift](Tests/FacetAdapterNativeTests/SectionLensCatalogTests.swift)）。`swift build` ✅
    - ✅ **実機検証 PASS（2026-06-23 自動操作）**: float WS に `facet lens Web` 当て→ Chrome 3窓の frame が activate→clear 通して**完全不変**・`visible=3 parked=4`→`cleared restored=4`（park/restore 正常）・**`section-lens-union` 無発火**（float-home 完全除外）。
    - ⚠️ 既に凍結中の1窓は**手動リサイズで1回戻す**必要あり（A は復元パスを足さない方針）。今後は二度と発生しない。
    - 残課題(別item候補): anchor park/restore が position-only な根本的脆さ（size 喪失の温床）は A では触れず温存。必要なら別途。

---

## 🧭 親トラッカー: filter-pivot 統合の退行回収（regression recovery）

> **背景（トミー 2026-06-23）**: filter pivot で workspace+tag を **section/lens モデルに統合**した。
> 統合自体は完了したが、その過程で **バグの混入・機能の欠落（暗黙のドロップ）が多い**。
> それらを体系的に **修正 / 復活** させる。本セクションがその親トラッカー（item 3/5 等はその実例）。

### 起点（origin）

- **Epic**: `#282`「filter pivot」（Phase 0–3）。
- **commit 範囲**: `51dc740`（#287・2026-06-17 facet filter AST/parser＝起点）→ `004bba9`（#321・2026-06-23 Phase 3＝現行終端）。
- **破壊的な統合の節目**:
  - `fa3b6ba`（#312・**BREAKING**）`[desktop.N]` seed 廃止 → section モデルに**一本化**。
  - `f5eea8f`（#319・**BREAKING**）EX-4 tag mode **純削除** + window tags `UInt64→Set<String>`。
  - `b777aa9`（#301）section apply/un-apply DnD（**header-swap を section mode で無効化** → reorder 喪失の起点）。
  - `1222793`（#311・**BREAKING**）`--active` flag 廃止。
- 既存 memory: `[[facet-filter-pivot-epic-282]]`（epic 経緯）/ `[[facet-tag-unification-design]]`（統合コア設計）。

### 退行・欠落の回収リスト（随時追記。トミー曰く「多い」＝オープン）

- [x] **R1. section の DnD（並び替え）復活** — header-swap が section mode で殺された（#301）まま reorder も無し → **display-only reorder として復活**（tree/grid/rail）。**PR #323 merged**。= 本ファイル item 3。
- [x] **R2. grid: lens union が float 窓を凍結** — float 窓を union リサイズ→復元不能。**案A（float-home を union 除外）実装＋CI test＋実機検証 PASS**。= 本ファイル item 5。（PR マージ待ち）
- [ ] **R3. キーボード Space のヘッダ持ち上げが旧 swap のまま**（reorder 化されていない）— マウスは reorder 済み。整合のため要追従。
- [ ] **R4.（候補・温存）anchor park/restore が position-only**（size 非保存）— item 5 の根因の一部。union/park で size を失う構造的脆さ。
- [ ] **R5+. （未特定）** — トミーが挙げる他のバグ/欠落をここに追記して潰していく。

### 進め方

- 各回収は **1 item = 1 PR**（gitmoji+Conventional・squash）。root cause を systematic-debug で file:line 特定 → 最小修正 → 実機検証 → Task.md 更新。
- 「正本はこの Task.md 一本」。GitHub issue 化したい場合は roadmap board(#5) に起票（トミー判断）。

---

_補足: 上記 1–4 は内部で feasibility 調査済み（着手箇所を把握）。_
