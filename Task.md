# Task — facet 修正トラッカー（正本）

> **正本（single source of truth）。** セッション跨ぎの引き継ぎはこの `Task.md` に集約（未達成を暗黙にしない）。
>
> **進め方（トミー指定）**
> - 1 セッションで完結しなくてよい。計画と実装のセッションを分けて OK。品質重視・破壊的変更すべて OK・必要ならリファクタ OK・プラン再作成 OK。
> - **各 item のルーティン**: ① 修正 → ② `swift build`（CLT の bar。`swift test` は Xcode 必須＝CI 任せ）→ ③ **Task.md 更新を同じ PR に同梱**（[[doc-updates-in-pr]]・後回し禁止・古ければ doc-only PR で即同期）→ ④ commit（gitmoji+Conventional・**push は許可があるまでしない**）→ ⑤ **`./run.sh` 必須**（実機反映）。
> - **1 item = 1 PR**（squash）。root cause を file:line 特定 → 最小修正 → 実機検証 → Task.md 更新。
> - **正本はこの Task.md 一本**。GitHub issue 化したい場合は roadmap board (#5) に起票（トミー判断）。

---

## 🎯 Open（優先度順）

> **優先基準（トミー 2026-06-24）**: ① 仕様が固い ② 小さい ③ 基盤になる ＝ 高優先。
> 通し番号＝優先順。括弧内は legacy R-id（memory / commit 参照用に温存）。

### 1. section ラベル統一（`label` 必須・unique・header 統一）（旧 R13・①固い ③基盤・ただし large / 破壊的）

section ヘッダの右クリック/`m` が workspace＝「WS1」・lens＝`label` で不統一（核心 ＝ [ViewContextMenu.swift:115](Sources/FacetView/ViewContextMenu.swift#L115) の `"WS\(ws+1)"` ハードコードが実 `name` を無視）。全 type で `label` を **必須+unique** 化 → header/識別子に使用・emoji 自動命名（`WorkspaceNaming`）**廃止**・CLI `--add LABEL` 必須化・Taplo 検証。将来 `facet section --focus` の前提。

- spec は異例に固い（全 WHAT+WHERE が file:line 確定・`CLIName`/`validateWorkspaceName` 既存ヘルパ再利用可）＋ 基盤性最強（workspace/lens を単一 label identity に統一・`WorkspaceNaming` 負債削除）。
- ただし **8 サブ項目 A–H が Core / View / App / Adapter / CLI 署名 / config / schema / docs / test を横断＝1 PR 不可・段階的**。**詳細設計 → 付録 B。**

---

## 🔬 要設計 / 要 triage（着手前に一手間・まだ actionable でない）

- **R7. grid / rail のキーボードが「怪しい」**（トミー実機報告・**症状未定義**）— コードに決定的バグは無し（`gridKbMonitor`/`railKbMonitor`・各 `kbMoveSelection` は guard 完備）。唯一の smell ＝ OverviewPanel（`.nonactivatingPanel`）を `overlay.makeKeyAndOrderFront` だけで提示し、tree の `enterActive` のような `setActivationPolicy(.regular)+NSApp.activate` をしない（[Controller+Overview.swift:65](Sources/FacetApp/Controller+Overview.swift#L65)）→ frontmost でない時に key を取れず keyboard 死、という **仮説**。確定単一バグではない。**実機で症状を切り分け → 起票が先**。R12 とは独立経路（`panel.isKeyWindow` 非依存）。
- **C2. tree から match/apply 編集 ＋ workspace の match/apply**（pivot 中核・大・要壁打ち）— `match`/`apply` は現状 **config-only**（`DesktopSection` の `public let`・TOML decode のみ・setMatch/editApply 等は Sources に存在せず）。workspace＝土台 / lens＝フィルタ の分離 + config 非書込の鉄則に触れる → **専用の計画ラウンドが先**。#321 `[[rule]]` adopt-rules（宣言的 facet）とは別物。設計の直交 2 軸モデル → [[facet-pivot-section-lens-model]]。
- **R6. lens の cross-workspace union-TILING は正しい意味か**（深い設計問い）— EX-1 の union-tile（マッチ窓を再タイルして集約・`WorkspaceCatalog+SectionLens.sectionLensUnionFrames` → `NativeAdapter+Scratchpad` で再タイル）は現存・稼働。「再タイルして集約すべきか／可視性フィルタのみ（非マッチ park・マッチは元位置表示）か」の **0 ベース再検討**。R2(#324) は float-home 除外のみで本質未変更。トミー曰く「あやしい」。

## 🧊 温存（実害が出たら着手・LOWEST）

- **R4. anchor park/restore が position-only**（size 非保存）— `WorkspaceCatalog.originalPositions` は CGPoint のみ（restore は現在 size + 保存 origin で frame 再構成）。union/park で size を失う構造的脆さ（item 5 / R2 の根因の一部）。
- **R8. loading skeleton の早期 clear ハードニング** — skeleton clear が content-sig（ordinal + 全窓内容）依存（[SidebarView.swift:329-332](Sources/FacetViewTree/SidebarView.swift#L329-L332)）→ 切替の最中に旧 desktop の窓状態が揺れると早期 clear し得る tail risk（item 4 の既知 tail risk）。clear を「**mac desktop ordinal 変化のみ**」に絞れば構造的に封じられるが、flicker mask 本体に触れる＝実機目視要。低頻度ゆえ温存。

## ✅ Done（アーカイブ）

<details><summary>完了項目（PR / commit・新しい順）</summary>

- **keyboard section reorder**（旧 Open #1 / R3）keyboard Space-lift のヘッダが section mode で無音 no-op だった退行を修正＝mouse mode-4 と同じ `controller.reorderSection`（display-only）へ。boundary ＝ `tgt < g ? tgt : tgt+1`（持ち上げた section が aim した target ordinal に着地）。degrade は performSwap 維持（mouse mode-3 と parity）。契約を `SectionOrderTests` に固定（+2 test=917）。実機キー操作の最終確認はトミー（section≥2 要・環境は wss=1）— **#334**（`fix/kb-section-reorder`）
- **macOS min 14**（旧 Open #1）13-gate 全撤去（OS 下限 13→14・`available(macOS)` 5 hit → 0）+ slide CADisplayLink 一本化（Timer fallback 削除）+ `winPreview` 非 Optional 化 + docs 同期。part B（ローカル `swift test`）も Xcode 26.5 導入で解禁＝915 tests local green — **#333**（`refactor` ＝ no-bump・`feat/macos-min-14`）
- **R12** mac desktop 切替後 tree キーボード死 — thrash 修正 + click-to-activate — **#330**（`5342aea`）／doc 同期 **#331**
- **R11-C1** global `t` タグ管理モード（rename/delete across windows） — **#329**
- **R10** 窓のタグ操作 GUI（"Add to lens" → "Tag" チェックリスト） — **#327**
- **R9** lens header に `m`/右クリックメニュー（stateless union layout picker） — **#326**
- **item5 = R2** grid: lens union が float 窓を凍結（float-home を union 除外） — **#324**（`2f4d45f`）
- **item4** tree が常に enterActive・`default-view` 廃止 — **#325**（`004d48c`）
- **item3 = R1** section DnD 並び替え復活（display-only reorder・tree/grid/rail） — **#323**
- **item2.1** workspace ラベルの emoji を末尾へ（`Dog 🐶`）
- **item2** config「迷子」→ **"Orphans"**（📌 内部の用語/ログ/schema は未英語化＝item 2-b 候補）
- **item1** workspace emoji 形式（識別子＝素の絵文字／表示＝「絵文字 + 英語名」）

📌 **R9 follow-up（未対応・暗黙にしない）**: lens header メニューの ✓（現在 layout 表示）は v1 省略。active lens の layout を thread-safe に view へ渡す配線（catalog → main・P6 規則で main から catalog を読まない）が要るため defer。

📌 **R5+（未特定）**: トミーが挙げる他のバグ/欠落は「🎯 Open」or「🔬 要設計」へ追記して潰していく。
</details>

---

## 📎 付録 A: macOS 最小サポート min 14（詳細計画・✅完了→Done）

> **✅ 実装完了**（`feat/macos-min-14`・#333）: part A 全 Step（floor→slide→@available→AXFocus→winPreview→docs）実装済・`available(macOS)` 0 件・`swift build` green・`swift test` 915/0 fail（ローカル Xcode 26.5）。part B も Xcode 導入済で解禁＝ローカル `swift test` 稼働確認済（CLAUDE.md にローカルテスト手順を追記）。以下は実装時の詳細計画（記録として保持）。

> **方針（トミー確定 2026-06-24・当初の「26-only ハードカットオーバー」から改訂）**:
> 最新 OS 寄りにしつつ、**痛みの無い範囲で旧 OS をサポート**。**少しでも痛みがあれば切る**。
> ① 最小 OS ＝ **macOS 14**（version 分岐は 13↔14 境界**だけ**＝13 を切れば痛みが全消、14/15/26 はコード分岐ゼロでタダ両対応。26 まで上げると 14/15 をタダで切る＝方針に反するので 14 が最適点）。**＝ `macOS 26 only` ではない**。② ローカルで `swift test` を回せる環境を整える。

### ツールチェーン注意
- 通常ブランチ（`feat/macos-support` 等）で可（R10 マージ済＝当初の worktree 隔離は不要）。
- **`xcode-select -s` 禁止**（global＝他作業の toolchain も切替わる）。テストは `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` でコマンド単位に Xcode toolchain を借りる。

### A. min macOS 14 化（痛みのある 13-gate を撤去・1 PR）
硬い version 分岐は macOS 13↔14 境界**だけ**。`#available(macOS 14.0,*)` 4 箇所＋`@available` 1 箇所を全除去:
- [ ] `Package.swift` L49 `platforms: [.macOS(.v13)]` → `.macOS(.v14)`（`.v14` は既存 enum＝確実に通る。**26 にはしない**）
- [ ] スライド: [NativeAdapter+Slide.swift](Sources/FacetAdapterNative/NativeAdapter+Slide.swift) L79 / L192 `stopSlideClock`/`startSlideDriver` の Timer fallback 削除・CADisplayLink 一本化。[NativeAdapter.swift](Sources/FacetAdapterNative/NativeAdapter.swift) L218 `slideTimer` 削除・L245 `displayLink: AnyObject?`→`CADisplayLink?`。`SlideTicker` コメント更新。
- [ ] focus: [AXFocus.swift](Sources/FacetAccessibility/AXFocus.swift) `activateFront` L223-232 の else（macOS 13 `activateIgnoringOtherApps`）削除・14+ 本体を無条件化。
- [ ] capture: [SCKWindowCapture.swift](Sources/FacetCapture/SCKWindowCapture.swift) L19 `@available(macOS 14.0,*)` 削除。[Controller.swift](Sources/FacetApp/Controller.swift) **L304**（`if #available … winPreview = SCKWindowCapture()`）無条件化。**`winPreview` 非 Optional 化（負債ゼロ・推奨）**: Controller.swift L194 + nil ガード除去（[Controller+Overview.swift](Sources/FacetApp/Controller+Overview.swift) L126/144・[Controller+Preview.swift](Sources/FacetApp/Controller+Preview.swift) L25/43/89・Controller.swift **L845/L1026**）。
- [ ] docs 同期: [CLAUDE.md](CLAUDE.md) L25 `macOS 13+`→`macOS 14+`／[README.md](README.md)+[README.ja.md](README.ja.md)（バッジ 14+／window preview の `(macOS 14+)` 注記 L233/281/696・L218/263/655 は最小 14 で常時可になるので削除）／[architecture.md](docs/architecture.md) L42・[references.md](docs/references.md) L166・[glossary.md](docs/glossary.md) L93/125 の capture 注記。`docs/superpowers/plans/*` は歴史記録ゆえ触らない。

**事実**: ローカルは CLT/SDK 15.5/Xcode 無し。min 14 は SDK 15.5 に収まり `swift build` は自明に通る（macOS14 API は SDK 15.5 に存在・13-gate 除去は安全）。private SLS/`_AXUIElementGetWindow` は dlsym graceful degradation ＝挙動不変。

> ⚠️ 旧版の行参照が古かったので訂正済み（`Controller.swift L299→L304`、winPreview nil ガード `L819/993→L845/L1026`）。着手時は実 grep で再確認。

### B. ローカルテスト環境
`swift test` には XCTest＝**Xcode 本体が必要**（CLT に XCTest 無し）。テストは充実（5 target・約 915 メソッド・大半 FacetCore/AdapterNative 純ロジック）:
- [ ] **Xcode（26 系）導入＝トミー手作業**（~15GB・CLT と共存）。副次効果: 新 SDK 同梱→A の min-14 ビルドを正規 SDK で検証可。
- [ ] 導入後（クロード実行）: `DEVELOPER_DIR=… swift test` で main baseline → A 後の緑確認。CLAUDE.md「test は CI 任せ」に「Xcode あれば `DEVELOPER_DIR=… swift test` で local 可」追記（任意）。
- A（CLT build で先行可）と B（Xcode 待ち）は独立。

### 検証
`swift build`（必須）／`grep -rn "available(macOS" Sources/` ＝ 0 件／`DEVELOPER_DIR=… swift test` 緑／`./run.sh` で実機 (26.5.1) スライド・preview・別アプリ focus 目視。

---

## 📎 付録 B: section ラベル統一 Phase-1 設計（詳細・Open #3 / 旧 R13）

> **依頼（トミー 2026-06-24）**: section ヘッダの右クリック/`m` で workspace は「WS1/WS2」・lens は `label` と不統一 → **統一**したい。手段: `config.toml` に `label` を**必須**化し header に使用 → emoji 名「Dog」廃止・**CLI 動的追加も `label` 必須**。
> 拡張方針: **label = section（lens も workspace も）を一意特定する識別子**（unique）。**理想形は `facet section --focus xxx`**（workspace/lens を “section” として統一アドレッシング・破壊的変更 OK・段階的）。Taplo（JSON schema）検証も入れる。
> **plan ファイル**: `~/.claude/plans/task-md-cuddly-creek.md`（承認済）。

### feasibility = 問題なし（破壊的変更だが clean）
- **「WS1/WS2」の核心** ＝ menu タイトルが [ViewContextMenu.swift:115](Sources/FacetView/ViewContextMenu.swift#L115) `let header = "WS\(ws + 1)"` ハードコード（実 `workspaces[].name` を無視）。lens は [:152](Sources/FacetView/ViewContextMenu.swift#L152) で `label` 使用 → **この非対称が症状**。
- **emoji 命名** [WorkspaceNaming.swift](Sources/FacetCore/WorkspaceNaming.swift) の production 参照は 2 箇所だけ（seed [FacetConfig.swift:514](Sources/FacetCore/FacetConfig.swift#L514)・add [NativeAdapter+DynamicWS.swift:37](Sources/FacetAdapterNative/NativeAdapter+DynamicWS.swift#L37)）＋display 経路 [WorkspaceLabel.swift:21](Sources/FacetCore/WorkspaceLabel.swift#L21) → label 置換で **丸ごと削除可**（負債ゼロ）。
- 窓 routing は **index ベース**（`sourceWorkspaceIndex`）→ label にスペースが入っても不変。
- **統一の核が既存**: `ActiveSection`(.workspace(n)/.lens(label)) + `backend.activateSection` [Controller+CLIDispatch.swift:534](Sources/FacetApp/Controller+CLIDispatch.swift#L534) → 将来 `facet section --focus` は **CLI 表層 + label 解決のみ**（低リスク）。
- **既存ヘルパ再利用で低リスク**: `CLIName.isClean`/`CLIName.sanitized`（[CLIName.swift](Sources/FacetCore/CLIName.swift)・TagName が既に再利用）と `validateWorkspaceName`（[FacetApp+ClientCommands.swift:367](Sources/FacetApp/FacetApp+ClientCommands.swift#L367) 定義・:49 呼出）。
- ⚠️ **CLAUDE.md「Workspaces are never named from config」を反転** → docs/memory 更新が必須。

### 確定した設計判断（Q&A 反映）
1. **label = section の一意識別子**。全 type（workspace/lens/unassigned）で `label` 必須・**1 mac desktop 内で unique**。
2. **形式 = CLIName-clean トークン**（非空・スペース無・`=,:`無・先頭`-`無）を**全 section label** に適用（lens label も現状「非空のみ」から tighten）。← `facet section --focus LABEL` を無クォートで通す＋一意識別。自由形式（スペース可）は不採用。
3. **label 欠落 = loud ドロップ**（`type` 必須・lens label 必須と同作法）。ある desktop の workspace セクションが全て欠落 → section model 無効化 → 既定 5 WS に縮退（config 更新を促す）。
4. **unique 違反 = loud warn + 先勝ち**（layout を壊さない total 動作・runtime 担保。JSON schema は cross-row unique 表現不可）。
5. **Taplo**: `[[desktop.N.section]]` 各行に `type`+`label` 必須を schema 表現。**caveat**: desktop-section は現状「記述のみ」→ 構造付与が要（sill `ConfigSchema` の dynamic-table item 表現可否を着手時確認・不可なら schema fragment 手当て）。
6. **zero-config（section ブロック皆無）**: label 要求不可 → 既定 `WS1..WS5` 表示を維持（強制・不変）。

### Phase 1 実装設計（A–H）
- **A パース/モデル**（FacetCore）: [DesktopSection.swift:195-204](Sources/FacetCore/DesktopSection.swift#L195-L204) `.workspace` を label 必須+CLIName-clean+`label` 格納へ（破棄をやめる・`match` は implicit のまま caveat warn 継続）／lens・unassigned も CLIName-clean（共通ヘルパ化）／[FacetConfig+Decode.swift:65-108](Sources/FacetCore/FacetConfig+Decode.swift#L65-L108) `decodeDesktopSectionSections` に **desktop 内 unique 検証を追加**（※現状そこに unique チェックは無い＝新規追加）／[FacetConfig.swift:514](Sources/FacetCore/FacetConfig.swift#L514) `effectiveWorkspaceList` を `WorkspaceNaming.name` → `s.label`。
- **B 命名廃止**（FacetCore）: [WorkspaceNaming.swift](Sources/FacetCore/WorkspaceNaming.swift) を**丸ごと削除**・[WorkspaceLabel.swift](Sources/FacetCore/WorkspaceLabel.swift) `workspaceShortLabel` は `name.isEmpty ? "WS<n>" : name`（"workspace " prefix strip は維持）。
- **C メニュー統一**（FacetView）: [ViewContextMenu.swift:115](Sources/FacetView/ViewContextMenu.swift#L115) を `workspaceShortLabel(name: workspaces.first{$0.index==ws}?.name ?? "", idx: ws)` へ（tree/grid/rail 共通・lens と一致）。
- **D CLI 動的追加**（FacetApp+Adapter+protocol）: `facet workspace --add LABEL`（[FacetApp+ClientCommands.swift:44](Sources/FacetApp/FacetApp+ClientCommands.swift#L44) `case "--add"` を値消費へ・**既存** `validateWorkspaceName`（:367）を再利用）→ `workspace-add:LABEL` → [NativeAdapter+DynamicWS.swift:29-42](Sources/FacetAdapterNative/NativeAdapter+DynamicWS.swift#L29-L42) `addWorkspace(label:)`（現状 `addWorkspace()` は無引数＝シグネチャ変更・emoji 命名除去）・`WindowBackend` 更新。
- **E config.toml**: 全 `type="workspace"` セクションに `label` 追加・大コメントから「auto-named emoji 🐶🍎🍕 / you can't name from config」を除去 → 「label 必須・unique・全 type 共通」へ。
- **F schema/Taplo**: [FacetConfig+Spec.swift](Sources/FacetCore/FacetConfig+Spec.swift) 更新 → `--emit-schema` で `config.schema.json` 再生成 + per-row 必須（上記 caveat 5）。
- **G docs/memory**: [CLAUDE.md](CLAUDE.md) ルール反転・[glossary.md](docs/glossary.md)/[README.md](README.md)/[README.ja.md](README.ja.md)/[architecture.md](docs/architecture.md)・memory `[[facet-per-native-space-ws]]`。
- **H テスト**: [WorkspaceNamingTests.swift](Tests/FacetCoreTests/WorkspaceNamingTests.swift) 削除・SectionDecodeTests（label 必須+carried・unique・CLIName-clean）・WorkspaceLabelTests・[SectionLensCatalogTests.swift:58-59](Tests/FacetAdapterNativeTests/SectionLensCatalogTests.swift#L58-L59) 更新。CLT は `swift test` 不可 → `swift build` を bar・テストは CI。

### 将来フェーズ（記録のみ・本タスク非対象）
**`facet section --focus LABEL`（理想形・要設計ラウンド）**: workspace/lens を “section” として統一アドレッシング。内部 `ActiveSection`/`activateSection` が既に統一済みゆえ CLI verb 追加 + 「label → `.workspace(n)`(switch) / `.lens(label)`(activate)」解決のみ。`facet workspace --focus NAME` / `facet lens NAME` の retire 是非・曖昧解消・DNC routing は別途壁打ち。Phase 1 の unique label がこの前提を満たす。

### 検証
`grep -rn "WorkspaceNaming" Sources` ＝ 0 件／`swift build`／実機で workspace ヘッダ右クリックが label 表示（lens と統一）。

---

## 🧭 メタ: filter-pivot 退行回収（背景・進め方）

> **背景（トミー 2026-06-23）**: filter pivot で workspace+tag を **section/lens モデルに統合**した。統合自体は完了したが、その過程で **バグの混入・機能の欠落（暗黙のドロップ）が多い**。それらを体系的に **修正/復活** させる。Open / 要設計 / 温存 / Done の各項目（R1〜）はその実例。

### 起点（origin）
- **Epic**: `#282`「filter pivot」（Phase 0–3）。
- **commit 範囲**: `51dc740`（#287・2026-06-17 facet filter AST/parser＝起点）→ `004bba9`（#321・2026-06-23 Phase 3＝現行終端）。
- **破壊的な統合の節目**:
  - `fa3b6ba`（#312・**BREAKING**）`[desktop.N]` seed 廃止 → section モデルに一本化。
  - `f5eea8f`（#319・**BREAKING**）EX-4 tag mode 純削除 + window tags `UInt64→Set<String>`。
  - `b777aa9`（#301）section apply/un-apply DnD（header-swap を section mode で無効化 → reorder 喪失の起点＝R1）。
  - `1222793`（#311・**BREAKING**）`--active` flag 廃止。
- 既存 memory: `[[facet-filter-pivot-epic-282]]`（epic 経緯）/ `[[facet-tag-unification-design]]`（統合コア設計）/ `[[facet-pivot-section-lens-model]]`（直交 2 軸）/ `[[facet-pivot-regression-recovery]]`（本回収フェーズ）。

### 進め方・指針
- **指針（トミー 2026-06-23）**: **filter pivot 以降の修正はあやしい**。コード/テスト/設計に違和感を感じたら、後方互換を気にせず振り返って是正して OK（破壊的変更 OK）。テストが「旧バグ挙動」を固定している場合は test 側を正す（R2 がその実例）。
- **フレーミング（トミー 2026-06-24）**: pivot で workspace 機能と tag 機能を統合 → バグ/不整合が混入。**pivot 以前（`group by = tag|workspace`）は個々で正しく動いていた**はず＝それが正動作の基準。
- **pre-pivot 参照 clone（旧正動作の確認用・トミー許可）**: `../facet-prepivot`（= `/Volumes/workspace/github.com/akira-toriyama/facet-prepivot`）@ `130cf93`（pivot 起点 `51dc740`#287 の親＝group-by モデル無傷）。`swift build`/実行で旧挙動を実機比較可。

### 📌 R2 の副産物メモ（学び・温存）
- **CI が旧バグ挙動の固定テストを検出**: float-home 除外で `TargetFramesLensTests`/`SetLayoutModeLensTests`/`SectionLensCatalogTests` の 3 本が RED（デフォルト float WS で「union が窓を含む」を検証＝まさに直したバグ挙動を固定していた）→ WS を tiled 明示に更新。**post-pivot テストも「あやしい」側だった実例**。
- **トレードオフ**: R2 案 A は inactive WS の float マッチ窓を集約しない（float を動かさない方針の帰結）。→ R6 で本質を問う。

### Phase 9 intake の経緯（2026-06-24・Cluster → R 対応）
- Cluster B → **R9**（lens header メニュー・#326）✅ / Cluster A → **R10**（窓タグ "Tag" 化・#327）✅ / Cluster C-1 → **R11-C1**（global `t`・#329）✅。
- Cluster C-2（= **C2**・tree から match/apply 編集）は要設計のまま → 「🔬 要設計」へ。"Add to lens" は R10 で廃止済（→ "Tag"）。rename スコープは per-window retag と global vocabulary を分離（R10=付与/外す・R11-C1=vocabulary rename/delete）で確定。
