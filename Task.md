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

---

## macOS 最小サポート見直し（min macOS 14・痛みゼロ範囲で旧 OS 維持）+ ローカルテスト環境（2026-06-24・計画済/実装未）

> **方針（トミー確定 2026-06-24・当初の「26-only ハードカットオーバー」から改訂）**:
> 最新 OS 寄りにしつつ、**痛みの無い範囲で旧 OS をサポート**。**少しでも痛みがあれば切る**。
> ① 最小 OS = **macOS 14**（version 分岐は 13↔14 境界**だけ**＝13 を切れば痛みが全消、14/15/26 は
>   コード分岐ゼロでタダ両対応。26 まで上げると 14/15 をタダで切る＝方針に反するので 14 が最適点）。
>   **= `macOS 26 only` ではない**。② ローカルで `swift test` を回せる環境を整える。
>
> **⏱ timing（クロード推奨・トミー確認待ち）**: **バグ修正（Phase 9 退行回収）を先 → OS 整理は後**
>   （OS 整理は内部都合・新方針で緊急度↓）。ただし **ローカルテスト環境（Xcode 導入）は早め/並行**
>   が得（`swift test` で退行回収 PR の検証が強くなる・Xcode 導入はトミー手作業ゆえ空き時間に）。
> **隔離**: R10 はマージ済（#327）＝当初の worktree 隔離の必要は解消。OS 整理は通常ブランチで可。

### ツールチェーン注意（worktree 隔離は R10 マージで不要に）
- 当初は別セッション R10 と同居していたため worktree 隔離を前提にしたが、**R10 マージ済（#327）
  ＝通常ブランチ（`feat/macos-support` 等）で可**。
- **`xcode-select -s` 禁止**（global＝他作業の toolchain も切替わる）。テストは
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` でコマンド単位に Xcode toolchain を借りる。

### A. min macOS 14 化（痛みのある 13-gate を撤去・1 PR）
硬い version 分岐は macOS 13↔14 境界**だけ**（それより上に gate 無し）。`#available(macOS 14.0,*)`
4箇所＋`@available`1箇所を全除去すれば痛み全消＝最小 14 で 14/15/26 をタダ両対応:
- [ ] `Package.swift` L49 `platforms: [.macOS(.v13)]` → `.macOS(.v14)`（`.v14` は既存 enum＝確実に通る。
  **26 にはしない**＝14/15 をタダで切らないため）
- [ ] スライド: [NativeAdapter+Slide.swift](Sources/FacetAdapterNative/NativeAdapter+Slide.swift)
  `stopSlideClock`/`startSlideDriver` の Timer fallback 削除・CADisplayLink 一本化。
  [NativeAdapter.swift](Sources/FacetAdapterNative/NativeAdapter.swift) L218 `slideTimer` 削除・
  L245 `displayLink: AnyObject?`→`CADisplayLink?`。`SlideTicker` のコメント更新。
- [ ] focus: [AXFocus.swift](Sources/FacetAccessibility/AXFocus.swift) `activateFront` L223-232 の
  else（macOS 13 `activateIgnoringOtherApps`）削除・14+ 本体を無条件化。
- [ ] capture: [SCKWindowCapture.swift](Sources/FacetCapture/SCKWindowCapture.swift) L19
  `@available(macOS 14.0,*)` 削除。[Controller.swift](Sources/FacetApp/Controller.swift) L299 無条件化。
  **`winPreview` 非 Optional 化（負債ゼロ・推奨）**: Controller.swift L194 + nil ガード除去
  ([Controller+Overview.swift](Sources/FacetApp/Controller+Overview.swift) L126/144・
  [Controller+Preview.swift](Sources/FacetApp/Controller+Preview.swift) L25/43/89・Controller.swift L819/993)。
- [ ] docs 同期: [CLAUDE.md](CLAUDE.md) L25 `macOS 13+`→`macOS 14+`／[README.md](README.md)+
  [README.ja.md](README.ja.md)（バッジは 14+／window preview の `(macOS 14+)` 注記 L233/281/696・
  L218/263/655 は最小 14 で**常時可**になるので削除）／
  [architecture.md](docs/architecture.md) L42・[references.md](docs/references.md) L166・
  [glossary.md](docs/glossary.md) L93/125 の capture 注記。`docs/superpowers/plans/*` は歴史記録ゆえ触らない。

**事実**: ローカルは CLT/SDK 15.5/Xcode 無し。min 14 は SDK 15.5 に収まり `swift build` は自明に通る
（macOS14 API は SDK 15.5 に存在・13-gate 除去は安全）。private SLS/`_AXUIElementGetWindow` は
dlsym graceful degradation ＝挙動不変。

### B. ローカルテスト環境
`swift test` には XCTest＝**Xcode 本体が必要**（CLT に XCTest 無し）。テストは充実（5 target・約915
メソッド・大半 FacetCore/AdapterNative 純ロジック）:
- [ ] **Xcode（26系）導入＝トミー手作業**（~15GB・CLT と共存）。副次効果: 新しい SDK 同梱→A の
  min-14 ビルドを正規 SDK で検証可。
- [ ] 導入後（クロード実行）: `DEVELOPER_DIR=… swift test` で main baseline → worktree(A 後) 緑確認。
  CLAUDE.md の「test は CI 任せ」記述に「Xcode あれば `DEVELOPER_DIR=… swift test` で local 可」追記（任意）。
- A（CLT build で先行可）と B（Xcode 待ち）は独立。Xcode が入り次第 `swift test` 緑を確認。

### 検証
`swift build`（必須）／`grep -rn "available(macOS" Sources/` が 0 件／
`DEVELOPER_DIR=… swift test` 緑／`./run.sh` で実機(26.5.1) スライド・preview・別アプリ focus 目視。

### Status
- 🗓️ **計画済み・実装未着手**（2026-06-24・方針を min macOS 14 へ改訂）。R10 マージ済（#327）
  ＝当初の worktree 隔離は不要・通常ブランチで可。timing はバグ修正後を推奨（トミー確認待ち）。
  push はトミー OK 後。

---

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
- [x] **R9. lens header にコンテキストメニュー（`m`/右クリック）** ✅ **完了（PR #326・main `534201c` マージ済・実機メニュー目視 OK＝トミー確認済）**。workspace header=全 layout / **lens header=stateless のみ**（`LensLayout.isStateless`・bsp/stack/float 除外＝トミーの「workspace の方が多い」と一致）。選択→`controller.setLensLayout`＝lens を（未 active なら）activate してから union layout セット（cliQueue FIFO で activate→layout 保証）。実装: [ViewContextMenu.showLensLayout](Sources/FacetView/ViewContextMenu.swift) / [TreeController.setLensLayout](Sources/FacetViewTree/TreeController.swift) / [Controller+CLIDispatch.swift](Sources/FacetApp/Controller+CLIDispatch.swift) / dispatch [SidebarView+Menus.swift](Sources/FacetViewTree/SidebarView+Menus.swift)+[SidebarView+KbNav.swift](Sources/FacetViewTree/SidebarView+KbNav.swift)。`swift build`✅ ／ `./run.sh` 起動＋tree 召喚クラッシュ無し✅。📌 **未対応（暗黙にしない）**: ✓（現在 layout 表示）は v1 省略＝active lens の layout を thread-safe に view へ渡す配線が要る follow-up（catalog を main から読まない P6 規則のため）。**調査結果: active lens の layout は現状 main 側/Status/snapshot に出ていない（grid/rail も）→ adapter(cliQueue)→main へ通す配線が必要＝想定より小さくないので defer（Task.md でトラッキング継続）**。= Phase 9 **Cluster B**。
- [x] **R10. 窓のタグ操作 GUI（"Add to lens" → "Tag" チェックリスト）** ✅ **完了（実機確認 OK＝トミー・branch `feat/window-tag-edit`・PR 作成→マージ）**。#319 削除の `TagEditPanel` **WINDOW モードのみ**を pre-pivot clone から復元し `Set<String>` 適応（[TagEditPanel.swift](Sources/FacetView/TagEditPanel.swift) 新規）。窓行メニュー: "Add to ＜Lens＞" 撤去 → **"Tag"**（[ViewContextMenu.swift](Sources/FacetView/ViewContextMenu.swift)）→ `TreeController.openTagEditor`（[Controller+ActiveMode.swift](Sources/FacetApp/Controller+ActiveMode.swift)）。トグル→`backend.addTag`/`removeTag`、"+Create"→addTag。allTags は snapshot から view 側 union（backend 呼び出し無し）。key/IME パネル＋`handlePanelKeyChange` ガード＋`finishTagEditor` 再 key（pre-pivot と同型）。`applyAdd`（右クリック ADD）撤去（drag の `applyMove` は無傷）。**UI 修正（実機 FB）: パネルはメニューと同じアンカー（行の高さ＝`m` 位置）で開く・ラベルは "Tag"（… 無し）**。`swift build`✅ `./run.sh`✅ 実機 OK。**rename/delete は本 PR 対象外＝C（global `t`）へ**（per-window=付与/外す・tag 自体=vocabulary 分離）。= Phase 9 **Cluster A**（本命）。
- [~] **R11. global `t` タグ管理モード（C1）＋ tree から match/apply 編集（C2）** = Phase 9 **Cluster C**。
  - **C1 = `t` タグ管理モード復活** ✅ **完了（実機 OK＝トミー・branch `feat/tag-manage-mode`・PR→マージ）**。#319 削除の `TagEditPanel` MANAGE モードを復元（[TagEditPanel.swift](Sources/FacetView/TagEditPanel.swift) に WINDOW と統合）。`t`（section model 有効時・[Controller+ActiveMode.swift](Sources/FacetApp/Controller+ActiveMode.swift) `enterTagManage`）→ tree 右隣に**タグ名一覧**パネル。行を Enter/右クリック→[Rename, Delete]（inline rename・delete 即時）。backend: 全窓 `renameTag(old,to:)`/`removeTag(name)` 再実装（[WorkspaceCatalog+WindowTags.swift](Sources/FacetAdapterNative/WorkspaceCatalog+WindowTags.swift) `renameTagEverywhere`/`removeTagEverywhere` + [NativeAdapter+Tagging.swift](Sources/FacetAdapterNative/NativeAdapter+Tagging.swift) + protocol）。タグ一覧は snapshot から view 側 union。**"+ Create" は無し**（Set<String> では窓無しタグは存在し得ず＝作成は A の窓モードの役割）。`swift build`✅ `./run.sh`✅。
  - [ ] **C2 = tree から match/apply 編集 ＋ type=workspace の match/apply** — **未着手・要設計ラウンド（pivot 中核・workspace=土台/lens=フィルタ の分離に触れる・config 非書込で session-only）**。トミーと壁打ちしてから。
- [x] **R12. mac desktop 切替（ctrl+→/←）後、tree のキーボード操作が効かない**（トミー実機報告 2026-06-24）— ✅ **完了（PR #330・main `5342aea` マージ済・実機 OK＝トミー）**。段階1（thrash 修正）+ 段階2（click-to-activate）。
  - **✅ ROOT CAUSE 確定（11-agent workflow・3レンズ独立トレース）**: mac desktop 切替（native ctrl+→/← / yabai `space --focus`）が OS により facet からキー（key-window）を剥がす。tree パネルは `.canJoinAllSpaces`（全 desktop 共有・[PanelHost.swift:217](Sources/FacetApp/PanelHost.swift#L217)）なので**閉じず可視のまま**残る。キー喪失が [windowDidResignKey](Sources/FacetApp/PanelHost.swift#L530) → `onKeyChanged(false)` → [handlePanelKeyChange(isKey:false)](Sources/FacetApp/Controller.swift#L391) を呼び、この handler は**無条件に** `exitKbNav()` + `.accessory` に戻す。切替後に kbNav へ戻る経路 = #325 `loadingWantsActive` ゲートだが `--view tree --loading` でしか arm されない。**実ログ確認: トミーは `view:tree`（loading 無し）召喚**＝ゲート永遠 false。クリックも #66 設計で `enterActive` を呼ばない。
  - **❌ 案A（auto-reactivate＝切替後に自動で kbNav 復帰）を実装→実機で却下（2026-06-24）**: ログで**発火は確認**できたが、`enterActive`(`NSApp.activate`) が OS/yabai のスペース切替 auto-focus と**キーを奪い合って thrash**（`panelKey gained`→即`lost`の嵐・07:00–07:06）。**トミー新方針 = 「自動フォーカスは要らない」**（切替後／grid・rail 後とも tree に auto-focus 不要）。→ auto-reactivate は撤去。
  - **🔧 段階1 実装（thrash 修正・撤去）**: ① 案A の二重タイムスタンプ機構を全撤去。② `handlePanelKeyChange(false)` の involuntary 喪失時に `panelHost.resignKey()` を追加＝**`wantsKey` を確実に false へ**（従来は lingering true で、切替戻り等の OS activation サイクルでパネルが勝手に再 key 取得 → thrash の一因だった）。③ 計測 Log.debug（`panelKey gained/lost`・`apply: mac-desktop swap N→M`）を残置。実装: [Controller.swift](Sources/FacetApp/Controller.swift)。`swift build`✅。**効果: 切替後は tree がクリーンに passive・focus 奪取/thrash なし。recovery は再召喚（`--view tree`）で kbNav 復帰。**
  - **🔧 段階2 実装（click-to-activate＝採用 recovery・トミー「明示クリックで tree をアクティブでいい」）**: passive な tree への **plain クリック（drag 無し）→ `enterActive()`**＝キーボード操作開始。クリックした行を kb 選択にセットし、**窓フォーカスはしない**（2クリック目＝active 状態 or Enter で focus＝#66 維持。OS 慣習「非アクティブ面の最初のクリックは focus のみ」に一致）。auto-focus でなくユーザー起点なので thrash も focus 奪い合いも無く、**全 desktop で普遍的に効く**（未管理 13 経由の 14 戻りでも passive→クリックで復帰）。実装: [SidebarView+Drag.swift](Sources/FacetViewTree/SidebarView+Drag.swift)（mouseDown 冒頭で `wasPassive` 捕捉→leftMouseUp `mode==0,wasPassive` 分岐）+ `enterActive()` を [TreeController](Sources/FacetViewTree/TreeController.swift) プロトコルへ追加。`swift build`✅。
  - **トミー方針の変遷（確定事項）**: 自動フォーカス不要 / 今は loading 不使用（plain `view:tree`）/ **明示クリックでアクティブ＝採用** / facet が暗黙 loading を撃つのも許容（＝必要なら追加可だが、click-to-activate で足りる見込み）。
  - **✅ 実機検証 PASS（トミー 2026-06-24）**: ① どの切替後でも tree を**クリック→キーボード操作開始** OK。② **13→14（未管理 desktop 経由）でクリック→復帰** OK（本報告の核心）。③ active な tree の窓行クリックは従来どおり**窓フォーカス**（#66 退行なし）。→ トミー「Good マージしてOK」。
  - 残調査メモ: native ctrl+→ で windowDidResignKey 発火は実機ログで確認済（`panelKey lost` 多数）。13→14 は未管理 13 で empty-guard により panel hide → 14 復帰で再 show・passive。item 4 / R7 とは別経路。
- [ ] **R13. section ラベル統一（`label` 必須・unique・header 統一）** — section ヘッダの右クリック/`m` が **workspace=「WS1/WS2」・lens=`label`** と不統一（[ViewContextMenu.swift:115](Sources/FacetView/ViewContextMenu.swift#L115) のハードコードが核心）。全 section type で `label` を**必須+unique** 化し header/識別子に使用 → emoji 自動命名（`WorkspaceNaming`）**廃止**・CLI `facet workspace --add LABEL` 必須化・Taplo 検証。**理想形=将来 `facet section --focus`**（段階的）。**計画済・実装未**（トミー 2026-06-24・破壊的変更OK・CLAUDE.md「named from config」ルール反転）。詳細 → 末尾「🆕 section ラベル統一」節。
- [ ] **R5+. （未特定）** — トミーが挙げる他のバグ/欠落をここに追記して潰していく。

### 📌 R2 の副産物メモ（学び）
- **CI が旧バグ挙動の固定テストを検出**: float-home 除外で `TargetFramesLensTests`/`SetLayoutModeLensTests`/`SectionLensCatalogTests` の3本が RED（**デフォルト float WS** で「union が窓を含む」を検証していた＝まさに直したバグ挙動を固定していた）。→ WS を tiled 明示に更新（cross-WS union の意図は tiled で保つ・float 除外は新テストが担保）。**= post-pivot テストも「あやしい」側だった実例**。
- **トレードオフ**: Option A は inactive WS の float マッチ窓を集約しない（float を動かさない方針の帰結・トミー config は WS2=stack で無影響）。→ R6 で本質を問う。

### 進め方

- 各回収は **1 item = 1 PR**（gitmoji+Conventional・squash）。root cause を systematic-debug で file:line 特定 → 最小修正 → 実機検証 → Task.md 更新。
- **指針（トミー 2026-06-23）**: **filter pivot 以降の修正はあやしい**。コード/テスト/設計に**違和感を感じたら、後方互換を気にせず振り返って是正してOK**（破壊的変更OK）。テストが「旧バグ挙動」を固定している場合は test 側を正す（R2 がその実例）。
- **フレーミング（トミー 2026-06-24）**: pivot で **workspace 機能と tag 機能を統合** → バグ/不整合が混入。**pivot 以前（`group by = tag|workspace`）は個々で正しく動いていた**はず＝それが正動作の基準。意図せぬ実装は **過去に振り返って確認OK・品質優先**。
- **pre-pivot 参照 clone（旧正動作の確認用・トミー許可）**: `../facet-prepivot`（= `/Volumes/workspace/github.com/akira-toriyama/facet-prepivot`）@ `130cf93`（pivot 起点 `51dc740`#287 の親＝group-by モデル無傷）。`swift build`/実行で旧挙動を実機比較可。方針詳細 → memory `facet-pivot-regression-recovery`。
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

### 🚧 進行: ✅ **B（R9）#326** → ✅ **A（R10）#327** → ✅ **C1（R11・`t` タグ管理）実機 OK・マージ**（branch `feat/tag-manage-mode`）→ ✅ **R12（切替後 tree キーボード死）#330 マージ済**。**残 open**: C2（match/apply・要設計）／R3・R7 等／**R13（section ラベル統一・計画済）**／macOS 最小サポート見直し（min14・別途）。

**A 実装計画（pre-pivot 忠実 + 現モデル適応）**:
- **窓行メニューの "Add to ＜Lens＞" を廃止**（トミー確定）し、**"Tag…"** を追加 → per-window タグ**チェックリストのキーパネル**を開く。
- パネル = #319 削除の `TagEditPanel` **WINDOW モード**を pre-pivot clone（`../facet-prepivot` `130cf93`）から復元し、Set<String> モデルへ適応:
  - 利用可能タグ = snapshot（lastSections/lastWorkspaces の `window.tags`）の和集合＝**view 側で算出**（削除済 `definedTagNames` 不要）。
  - チェック = その窓の tags。トグル → backend `addTag(_:toWindow:)`/`removeTag(_:fromWindow:)`（**現存**）。
  - "+ Create" 行 → 新規タグ付与（auto-vivify）。
  - キー入力可能パネル（KeyablePanel・text field・activation-policy dance）— B と同じ流儀で tree パネル右隣に配置。
- **rename スコープの決定（トミー flagged）**: **rename/delete は per-window でなく vocabulary 操作 → C（global `t` モード）へ**。pre-pivot でも rename/delete は MANAGE モード（窓非依存）にあり、WINDOW モードは toggle+create のみ。A は **付与/外す/作成**に専念。← この方針で進める（異論あれば C で調整）。
- 段階: A-1 パネル復元+適応 → A-2 メニュー配線（"Tag…" 追加・"Add to lens" 撤去）→ build → run → 実機目視（トミー）→ PR。

---

_補足: 上記 1–5 は完了（item 3/4/5 = PR #323/#325/#324 マージ済）。Phase 9（R9–R11）が現行のオープン。_

---

## 🆕 section ラベル統一（`label` 必須・unique・header 統一）＋将来 `facet section --focus`（2026-06-24・計画済/実装未 = R13）

> **依頼（トミー 2026-06-24）**: section ヘッダの右クリック/`m` で **workspace は「WS1/WS2」・lens は `label`** と不統一 → **統一**したい。
> 手段（補足）: `config.toml` に `label` を**必須**化し header に使用 → emoji 名「Dog」廃止・config 修正・**CLI 動的追加も `label` 必須**。
> 拡張方針（聞き取りで判明）: **label = section（lens も workspace も）を一意特定する識別子**（unique）。**理想形は `facet section --focus xxx`**（workspace/lens を “section” として統一アドレッシング・破壊的変更OK）・**段階的**に。Taplo（JSON schema）検証も入れる。
> **plan ファイル**: `~/.claude/plans/task-md-cuddly-creek.md`（承認済）。

### feasibility = 問題なし（破壊的変更だが clean・プロジェクト方針上OK）
- **「WS1/WS2」の核心** = menu タイトルが [ViewContextMenu.swift:115](Sources/FacetView/ViewContextMenu.swift#L115) `let header = "WS\(ws + 1)"` ハードコード（実 `workspaces[].name` を無視）。lens は [:152](Sources/FacetView/ViewContextMenu.swift#L152) で `label` 使用 → **この非対称が症状**。
- **emoji 命名** [WorkspaceNaming.swift](Sources/FacetCore/WorkspaceNaming.swift) の production 参照は2箇所だけ（seed [FacetConfig.swift:514](Sources/FacetCore/FacetConfig.swift#L514)・add [NativeAdapter+DynamicWS.swift:37](Sources/FacetAdapterNative/NativeAdapter+DynamicWS.swift#L37)）＋display 経路 [WorkspaceLabel.swift:21](Sources/FacetCore/WorkspaceLabel.swift#L21) → label 置換で **丸ごと削除可**（負債ゼロ）。
- 窓 routing は **index ベース**（`sourceWorkspaceIndex`）→ label にスペースが入っても不変。
- **統一の核が既存**: `ActiveSection`(.workspace(n)/.lens(label)) + `backend.activateSection` [Controller+CLIDispatch.swift:534](Sources/FacetApp/Controller+CLIDispatch.swift#L534) → 将来 `facet section --focus` は **CLI 表層 + label 解決のみ**（低リスク）。
- ⚠️ **CLAUDE.md「Workspaces are never named from config」を反転**する → docs/memory 更新が必須。

### 確定した設計判断（Q&A 反映）
1. **label = section の一意識別子**。全 type（workspace/lens/unassigned）で `label` 必須・**1 mac desktop 内で unique**。
2. **形式 = CLIName-clean トークン**（非空・スペース無・`=,:`無・先頭`-`無）を**全 section label** に適用（lens label も現状「非空のみ」から tighten）。← `facet section --focus LABEL` を無クォートで通す＋一意識別。自由形式（スペース可）は不採用。
3. **label 欠落 = loud ドロップ**（`type` 必須・lens label 必須と同作法）。ある desktop の workspace セクションが全て欠落 → section model 無効化 → 既定5 WS に縮退（config 更新を促す）。
4. **unique 違反 = loud warn + 先勝ち**（layout を壊さない total 動作・runtime 担保。JSON schema は cross-row unique 表現不可）。
5. **Taplo**: `[[desktop.N.section]]` 各行に `type`+`label` 必須を schema 表現。**caveat**: desktop-section は現状「記述のみ」→ 構造付与が要（sill `ConfigSchema` の dynamic-table item 表現可否を着手時確認・不可なら schema fragment 手当て）。
6. **zero-config（section ブロック皆無）**: label 要求不可 → 既定 `WS1..WS5` 表示を維持（強制・不変）。

### Phase 1 実装設計（本タスク本体・別セッション）
- **A パース/モデル**（FacetCore）: [DesktopSection.swift:195-204](Sources/FacetCore/DesktopSection.swift#L195-L204) `.workspace` を label 必須+CLIName-clean+`label` 格納へ（破棄をやめる・`match` は implicit のまま caveat warn 継続）／lens·unassigned も CLIName-clean（共通ヘルパ化）／[FacetConfig+Decode.swift:65-108](Sources/FacetCore/FacetConfig+Decode.swift#L65-L108) で desktop 内 unique 検証／[FacetConfig.swift:514](Sources/FacetCore/FacetConfig.swift#L514) `effectiveWorkspaceList` を `WorkspaceNaming.name` → `s.label`。
- **B 命名廃止**（FacetCore）: [WorkspaceNaming.swift](Sources/FacetCore/WorkspaceNaming.swift) を**丸ごと削除**・[WorkspaceLabel.swift](Sources/FacetCore/WorkspaceLabel.swift) `workspaceShortLabel` は `name.isEmpty ? "WS<n>" : name`（"workspace " prefix strip は維持）。
- **C メニュー統一**（FacetView）: [ViewContextMenu.swift:115](Sources/FacetView/ViewContextMenu.swift#L115) を `workspaceShortLabel(name: workspaces.first{$0.index==ws}?.name ?? "", idx: ws)` へ（tree/grid/rail 共通・lens と一致）。
- **D CLI 動的追加**（FacetApp+Adapter+protocol）: `facet workspace --add LABEL`（[FacetApp+ClientCommands.swift:44](Sources/FacetApp/FacetApp+ClientCommands.swift#L44) を値消費へ・`validateWorkspaceName`）→ `workspace-add:LABEL` → [NativeAdapter+DynamicWS.swift:29-42](Sources/FacetAdapterNative/NativeAdapter+DynamicWS.swift#L29-L42) `addWorkspace(label:)`（emoji 命名除去）・`WindowBackend` シグネチャ更新。
- **E config.toml**: 全 `type="workspace"` セクションに `label` 追加・大コメントから「auto-named emoji 🐶🍎🍕 / you can't name from config」を除去 → 「label 必須・unique・全 type 共通」へ。
- **F schema/Taplo**: [FacetConfig+Spec.swift](Sources/FacetCore/FacetConfig+Spec.swift) 更新 → `--emit-schema` で `config.schema.json` 再生成 + per-row 必須（上記 caveat 5）。
- **G docs/memory**: [CLAUDE.md](CLAUDE.md) ルール反転・[glossary.md](docs/glossary.md)/[README.md](README.md)/[README.ja.md](README.ja.md)/[architecture.md](docs/architecture.md)・memory `[[facet-per-native-space-ws]]`。
- **H テスト**: [WorkspaceNamingTests.swift](Tests/FacetCoreTests/WorkspaceNamingTests.swift) 削除・[SectionDecodeTests.swift](Tests/FacetCoreTests/SectionDecodeTests.swift)（label 必須+carried・unique・CLIName-clean ケース）・[WorkspaceLabelTests.swift](Tests/FacetCoreTests/WorkspaceLabelTests.swift)・[SectionLensCatalogTests.swift:58-59](Tests/FacetAdapterNativeTests/SectionLensCatalogTests.swift#L58-L59) 更新。CLT は `swift test` 不可 → `swift build` を bar・テストは CI。

### 将来フェーズ（記録のみ・本タスク非対象）
**`facet section --focus LABEL`（理想形・要設計ラウンド）**: workspace/lens を “section” として統一アドレッシング。内部 `ActiveSection`/`activateSection` が既に統一済みゆえ CLI verb 追加 + 「label → `.workspace(n)`(switch) / `.lens(label)`(activate)」解決のみ。`facet workspace --focus NAME` / `facet lens NAME` の retire 是非・曖昧解消・DNC routing は別途壁打ち。Phase 1 の unique label がこの前提を満たす。

### Status
🗓️ **計画済・実装未着手**（2026-06-24・R13）。Phase 1 = label 統一、将来 = `facet section --focus`。実装は別セッション（ルーティン: 修正→`swift build`→Task.md→commit→`./run.sh`）。push はトミー OK 後。検証: `grep -rn "WorkspaceNaming" Sources` が 0 件／実機で workspace ヘッダ右クリックが label 表示（lens と統一）。
