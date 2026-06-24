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

- [x] **4. tree のキーボード操作が効かない** ✅ 完了（**PR #325・main `004d48c` マージ済**）— `--view tree` は常に enterActive ／ `default-view` 廃止。⚠️実機での keyboard 復活の最終目視はトミー。grid/rail の keyboard は別経路＝**R7 で別途**。
  - **症状**: tree が ↑↓/Enter/`s`/`m` 等を受け付けない。※ `t` は別件（#319 で tag mode を純削除済＝設計通り。復活の是非は調査済み・別途）。
  - **✅ ROOT CAUSE（2経路・コード確定＋敵対レビュー3レンズ通過）**:
    1. **chord `--loading` 経路が enterActive を素通り**。chord は `facet --view=tree --loading=2000`（`~/.config/chord/config.toml`）で起動。`dispatchView` の `--loading` 分岐が `showLoading(); return` で [enterActive()](Sources/FacetApp/Controller+CLIDispatch.swift) に到達せず → panel が key にならず `handleKbKey` の `guard panel.isKeyWindow`（[Controller+ActiveMode.swift:70](Sources/FacetApp/Controller+ActiveMode.swift#L70)）が常に false → 全キー死。**#311（`--active` 廃止）が「`--view tree` は常に active」へ集約した際、loading 分岐だけ取りこぼした回帰**。
    2. **boot `default-view = "tree"` が passive 固定**。#311 が「launch で focus を奪わない」ため意図的に passive show。passive panel は構造上 key になれず（`wantsKey=false`）keyboard 不可。
  - **🔧 FIX（破壊的変更・トミー判断）**:
    1. **Fix A: loading 解決後に自動 enterActive**。`loadingWantsActive` フラグを `showLoading` で arm し、`apply()` で skeleton→実コンテンツ遷移時（＝mac desktop 切替が落ち着いた瞬間）に1回だけ `enterActive`。**切替の最中は撃たない**（旧 `--active`+`--loading` の排他制約を「順序づけ」で解消）。grid takeover / user-hide / empty space で解除。[Controller.swift](Sources/FacetApp/Controller.swift) / [Controller+CLIDispatch.swift](Sources/FacetApp/Controller+CLIDispatch.swift) / [Controller+Grid.swift](Sources/FacetApp/Controller+Grid.swift)。
    2. **`default-view` を廃止＋関連コード全削除**。boot は**常に agent-only**（panel を出さない）。view は summon した時のみ出現＝必ず active → 「**表示されてるのに keyboard 死**」を構造的に不能化。削除: `FacetConfig`(field/`effectiveDefaultView`/validation)・`FacetConfig+Spec`・`Status`(`defaultView` field)・`Controller`(caller)・`Main`(boot switch/help)・`config.toml`・`config.schema.json`(再生成)・docs(CLAUDE/README 日英/glossary/rail-design)・tests(FacetConfig/Status)。
  - 敵対レビュー: **blocker 無し**。tail risk（切替の最中に旧 desktop の content-sig が揺れると skeleton が早期 clear → 旧 desktop で activate・**低**・skeleton 機構の pivot 前からの既存特性）は YAGNI で温存（実機で実際に出たら別 item＝R8 候補で ordinal-gate ハードニング）。
  - `swift build` ✅（CLT なので test は CI）。実機検証＝トミー: chord ctrl+→/← で keyboard 復活／boot は agent-only（panel 出ない）。
  - 📌 **user 対応**: `~/.config/facet/config.toml` の `default-view = "tree"` は不要に（unknown key は無視＝無害だが削除推奨）。

- [x] **5. grid のウィンドウが offscreen に居座る（park/restore リグレッション）** ✅ 完了（**PR #324・main `2f4d45f` マージ済**）
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
- [x] **R2. grid: lens union が float 窓を凍結** — float 窓を union リサイズ→復元不能。**案A（float-home を union 除外）実装＋CI test＋実機検証 PASS**。= 本ファイル item 5。**✅ PR #324 merged（main `2f4d45f`）**。
- [ ] **R3. キーボード Space のヘッダ持ち上げが旧 swap のまま**（reorder 化されていない）— マウスは reorder 済み。整合のため要追従。
- [ ] **R4.（候補・温存）anchor park/restore が position-only**（size 非保存）— item 5 の根因の一部。union/park で size を失う構造的脆さ。
- [ ] **R6.（候補・深い問い）lens の cross-workspace union-TILING は正しい意味か？** — R2 で float を除外した結果「inactive WS の float マッチ窓は lens に集約されない」トレードオフが出た。そもそも lens（＝可視性フィルタ／SQL VIEW）が**マッチ窓を再タイルして集約する**のが正しいのか、**可視性のみ（非マッチを park・マッチは元位置表示）**が筋ではないか。EX-1 の union-tile は post-pivot 追加分で、トミー曰く「あやしい」。要 0ベース再検討。
- [ ] **R7. grid / rail のキーボードが怪しい**（トミー実機報告・**別タスク**）— item 4 の敵対レビューでは tree とは**独立経路**（`gridKbMonitor` / `railKbMonitor`・`panel.isKeyWindow` 非依存・`loadingWantsActive` と無関係）で本 bug の影響外と判定。実機で症状を切り分けてから起票。
- [ ] **R8.（候補・温存）loading skeleton の早期 clear ハードニング** — item 4 Fix A の tail risk。skeleton clear を「content-sig 変化」ではなく「**mac desktop ordinal 変化**」に絞れば、切替の最中の旧 desktop sig 揺れによる早期 activate を構造的に封じられる。flicker mask 本体に触れる＝実機目視が要るので、実際に出てから着手。
- [x] **R9. lens header にコンテキストメニュー（`m`/右クリック）** 🔧 実装済・**実機メニュー目視待ち（トミー）**（branch `feat/lens-header-menu`・未 commit→commit 予定）。workspace header=全 layout / **lens header=stateless のみ**（`LensLayout.isStateless`・bsp/stack/float 除外＝トミーの「workspace の方が多い」と一致）。選択→`controller.setLensLayout`＝lens を（未 active なら）activate してから union layout セット（cliQueue FIFO で activate→layout 保証）。実装: [ViewContextMenu.showLensLayout](Sources/FacetView/ViewContextMenu.swift) / [TreeController.setLensLayout](Sources/FacetViewTree/TreeController.swift) / [Controller+CLIDispatch.swift](Sources/FacetApp/Controller+CLIDispatch.swift) / dispatch [SidebarView+Menus.swift](Sources/FacetViewTree/SidebarView+Menus.swift)+[SidebarView+KbNav.swift](Sources/FacetViewTree/SidebarView+KbNav.swift)。`swift build`✅ ／ `./run.sh` 起動＋tree 召喚クラッシュ無し✅。📌 **未対応（暗黙にしない）**: ✓（現在 layout 表示）は v1 省略＝active lens の layout を thread-safe に view へ渡す配線が要る小 follow-up（catalog を main から読まない P6 規則のため）。= Phase 9 **Cluster B**。
- [ ] **R10. 窓のタグ操作 GUI が欠落（"Add to lens" が代替になっていない）** — pivot 前の per-window タグ 付与/外す/リネーム を GUI で。backend API（`addTagToWindow`/`removeTagFromWindow`/`toggleTagOnWindow`/`retagWindow`）＋CLI（`facet window --tag/--untag/--toggle-tag/--retag`）は**現存**、GUI 未露出。#319 削除の `TagEditPanel` WINDOW モード復活が筋。= Phase 9 **Cluster A**（本命）。
- [ ] **R11. global `t` タグ管理モード削除（#319）＋ tree から match/apply 編集が無い** — `t` vocab モード復活（C1）＋ 実行時 match/apply 編集・type=workspace の match/apply（C2・要設計・pivot 中核に触れる）。= Phase 9 **Cluster C**。
- [ ] **R5+. （未特定）** — トミーが挙げる他のバグ/欠落をここに追記して潰していく。

### 📌 R2 の副産物メモ（学び）
- **CI が旧バグ挙動の固定テストを検出**: float-home 除外で `TargetFramesLensTests`/`SetLayoutModeLensTests`/`SectionLensCatalogTests` の3本が RED（**デフォルト float WS** で「union が窓を含む」を検証していた＝まさに直したバグ挙動を固定していた）。→ WS を tiled 明示に更新（cross-WS union の意図は tiled で保つ・float 除外は新テストが担保）。**= post-pivot テストも「あやしい」側だった実例**。
- **トレードオフ**: Option A は inactive WS の float マッチ窓を集約しない（float を動かさない方針の帰結・トミー config は WS2=stack で無影響）。→ R6 で本質を問う。

### 進め方

- 各回収は **1 item = 1 PR**（gitmoji+Conventional・squash）。root cause を systematic-debug で file:line 特定 → 最小修正 → 実機検証 → Task.md 更新。
- **指針（トミー 2026-06-23）**: **filter pivot 以降の修正はあやしい**。コード/テスト/設計に**違和感を感じたら、後方互換を気にせず振り返って是正してOK**（破壊的変更OK）。テストが「旧バグ挙動」を固定している場合は test 側を正す（R2 がその実例）。
- 「正本はこの Task.md 一本」。GitHub issue 化したい場合は roadmap board(#5) に起票（トミー判断）。

---

## 🆕 Phase 9 実使用フィードバック intake（2026-06-24・聞き取り＋feasibility）

> トミー指示: 大ボリューム・じっくり読む・意見を聞きたい・すこしずつ修正したい。
> 主テーマ = filter pivot 以降の「タグ操作 UI」と「コンテキストメニューの不整合」。
> 3-agent 精読で現状を file:line 確定済み（解決策の方向性は私見・着手順はトミー確定待ち）。

### データ構成（トミーの理解＝コードと一致を確認）
- section → header（`type=workspace` | `type=lens`）→ window 行（窓は複数 section に重複表示しうる）。
- TreeRow: `.header(group, workspaceIndex?)` / `.window(...)`。**lens header は `workspaceIndex==nil`** で識別。

### Cluster B = R9 — lens header に `m`/右クリックメニュー（小・着手しやすい）
- **現状**: workspace header は `m`/右クリックで Layout picker（[ViewContextMenu.showLayout](Sources/FacetView/ViewContextMenu.swift)）。**lens header はメニュー皆無**（[SidebarView+Menus.swift:20-23](Sources/FacetViewTree/SidebarView+Menus.swift) / [SidebarView+KbNav.swift:230-251](Sources/FacetViewTree/SidebarView+KbNav.swift) の `if let ws { … }` が nil 素通り）。
- **意見**: 低リスク高整合。lens にも `layout` フィールドがある（union-tile に使用）ので「workspace と同じ」= 最低限 Layout picker を `ws==nil` 分岐に足すだけ。lens 固有（Clear lens / Edit match…）は C と合流可。
- **feasibility 注意**: lens layout の実行時セットが session-only で効くか要確認（config 非書込の鉄則）。

### Cluster A = R10 — 窓のタグ操作を pivot 前へ（「ADD TO LENS がおかしい」）（中・本命）
- **現状**: 窓行メニューに `"Add to <Lens>"`（[ViewContextMenu.swift:202-209](Sources/FacetView/ViewContextMenu.swift)）。これは **lens の `apply` が定義するタグ等を窓へ付与**して match を満たさせる操作で、**タグ直接編集（付与/外す/リネーム）の GUI は無い**。
- **「おかしい」理由（私見）**: ① タグと lens を混同（心象「窓に web タグ」⇄ UI「Web lens に入れる＝apply セット適用」）② remove/rename が GUI に無く非対称 ③ `tag~=` 以外の match を持つ lens では "Add to" が無意味な副作用になりうる。
- **重要**: per-window タグ backend API は**全て現存**（[WorkspaceCatalog+WindowTags.swift](Sources/FacetAdapterNative/WorkspaceCatalog+WindowTags.swift)・CLI `facet window --tag/--untag/--toggle-tag/--retag`）。GUI 未露出なだけ。
- **意見**: #319 純削除の `TagEditPanel` **WINDOW モード（タグ・チェックリスト＋Create 行）を git から復活**し窓行メニュー "Tag…" に載せる（既存 toggle API を呼ぶだけ）。"Add to lens" の扱いは要相談（タグで表せない apply＝float/sticky/workspace 一括なら残す価値／単なるタグ付与なら廃止）。
- **rename の所在**: per-window retag（[NativeAdapter+Tagging.swift:144](Sources/FacetAdapterNative/NativeAdapter+Tagging.swift)）は窓単位。global rename（全窓横断）は #319 で削除済み → C へ。

### Cluster C = R11 — global `t` 復活 ＋ tree から match/apply 操作（大・要設計）
- **C1 `t` タグ管理モード復活**: #319 削除の `TagEditPanel` MANAGE モード（vocabulary 編集 create/rename/delete・窓非依存）＋ backend vocab verbs（`addTag/removeTag/renameTag/definedTagNames`）も削除済み。**git から復活可**だが、現モデル Set<String> は vocabulary が暗黙（窓が持つ間だけ存在）→ rename/delete は全窓走査で再実装。中。
- **C2 tree から match/apply 編集 ＋ type=workspace の match/apply**: **新規・大・pivot 中核**。現状 `match`/`apply` は config 専用（実行時編集 UI 無し）・workspace は match 非対応（index 直割当て）・lens のみ match（[[facet-pivot-section-lens-model]] 直交2軸設計）。「workspace に match」は **workspace=常設土台/lens=フィルタの分離を曖昧化**しうる。#321 `[[rule]]` adopt-rules と重複の可能性も。config 非書込の鉄則 → 実行時編集は session-only。→ **専用の計画ラウンドが必要**。

### 🔑 判断（トミー確定 2026-06-24）
1. ✅ **着手順 = B → A → C**（小・整合性 → 本命 → 要設計を最後）。各 1 item=1 PR。
2. ✅ **"Add to lens" は廃止し、窓のタグ直接編集（"Tag…"）に置換**（A で実施）。
3. ⏳ **rename スコープ（per-window retag / global vocabulary）は A 着手時に確定**（未確定で残す）。
4. ⏳ **「workspace の match/apply」(C2) はまだ固めない** → C 着手時に専用ラウンドで相談（今は intake 記録のみ）。

### 🚧 進行: **B（R9）= lens header メニュー** 🔧 実装済・実機目視待ち → 次は **A（R10）= 窓のタグ編集**

---

_補足: 上記 1–5 は完了（item 3/4/5 = PR #323/#325/#324 マージ済）。Phase 9（R9–R11）が現行のオープン。_
