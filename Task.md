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

### 1. section ラベル統一（index アドレス + label 任意・header 統一）（旧 R13・①固い ③基盤・large / 破壊的・多段PR）

section ヘッダの右クリック/`m` が workspace＝「WS1」ハードコード・lens＝`label` で不統一（核心 ＝ [ViewContextMenu.swift:115](Sources/FacetView/ViewContextMenu.swift#L115) の `"WS\(ws+1)"` が実 `name` を無視）。**識別子と表示名を分離**して統一する: **index = 常設ハンドル**（1始まり・tree 表示順・macOS Desktop 式）／**label = 任意**（全 type 共通・unique は warn+先勝ち）。`facet section --focus N|"label"` 両対応・表示は `index` or `index (label)`・`WorkspaceNaming` 絵文字命名廃止・**tree から runtime rename**。

- **2026-06-25 壁打ちで required → optional に改訂**（required は「とりあえず作る」摩擦が強い／label を CLI 参照に兼用すると lens が `facet lens 🐶` で打てず致命的 → index を主ハンドルに分離して解決）。**詳細設計 → 付録 B**（旧 required 版を supersede）。
- 既存シーム（`ActiveSection`/`activateSection`・`TagEditPanel` rename）再利用で低リスクだが、**Core / View / App / Adapter / CLI / config / schema / docs / test を横断＝1 PR 不可・relay 多段**。実装はトミー在席時。

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

## 📎 付録 B: section ラベル統一 設計（index アドレス + label 任意・Open #1 / 旧 R13）

> **改訂（トミー 2026-06-25 壁打ち）**: 旧 required 設計（`label` 必須・CLI `--add LABEL` 必須）を **supersede**。required は「とりあえず作る」摩擦が強く、label を CLI 参照の識別子に兼用すると lens が `facet lens 🐶` で打てず致命的 → **識別子=index / 表示名=label（任意）に分離**する新モデルへ。
> **plan ファイル**: `~/.claude/plans/task-md-graceful-milner.md`（承認済・2026-06-25）。旧 `task-md-cuddly-creek.md` は required 版＝旧版扱い。

### 確定した新設計（壁打ち全合意 2026-06-25）
1. **index = 常設ハンドル**: 1始まり・**tree 表示順**（reorder override 反映後）。全 section に必ず付く。macOS Desktop 番号と同発想。
2. **label = 任意**: workspace / lens / unassigned 全 type 共通。未指定可。
3. **label unique（warn + 先勝ち）**: 1 mac desktop 内で重複は loud warn し先勝ち（layout を壊さない）。
4. **アドレッシング**: `facet section --focus N`（index）／ `--focus "label"`（付いていれば）。両対応。
5. **表示**: 無 → `index`（`1`）／ 有 → `index (label)`（`1 (Web)`）。全 type・全 view 共通。
6. **`WorkspaceNaming` 絵文字命名は廃止**（未命名は index 表示）。
7. **header の `WS\(ws+1)` ハードコード除去** → `index (label?)`。
8. **tree から label を runtime rename**（作成は摩擦ゼロ・命名は後付け）。
9. lens の **`match` は必須維持**（label のみ optional 化）。

### feasibility = 低リスク（破壊的だが既存シーム再利用）
- **統一シーム既存**: `ActiveSection`(.workspace(n)/.lens(label)) [ActiveSection.swift](Sources/FacetCore/ActiveSection.swift) + `Controller.activateSection` [Controller+CLIDispatch.swift:534](Sources/FacetApp/Controller+CLIDispatch.swift#L534) + `NativeAdapter.activateSection` [NativeAdapter.swift:506](Sources/FacetAdapterNative/NativeAdapter.swift#L506) → `facet section --focus` は「index→ActiveSection 解決層 + CLI verb」追加のみ。
- **窓 routing は index ベース**（`sourceWorkspaceIndex`）→ label が空でも不変。
- **rename 流用**: `TagEditPanel`（[TagEditPanel.swift:388](Sources/FacetView/TagEditPanel.swift#L388)）+ `enterTagManage`（[Controller+ActiveMode.swift:272](Sources/FacetApp/Controller+ActiveMode.swift#L272)）の rename フローを section rename へ転用。
- ⚠️ **CLAUDE.md「Workspaces are never named from config」を反転**（label 任意で命名可へ）→ docs/memory 更新必須。
- ⚠️ **index は tree 表示順（reorder override 反映）**＝Controller `lastSections`（main）。`--focus N` 解決は main hop で読む（or config 順許容を要判断）。

### 実装アウトライン（relay 多段・各 PR で build/test green 維持）

> **進捗（2026-06-25）**: ✅ **C 完了**（`facet section --focus N|label`・#337）＋ ✅ **空 section 移動時の focused-highlight stale 修正**（active section 内のみ highlight・#337 同梱）。lens 任意ラベルは **(い) 全 type optional に決定**（トミー 2026-06-25）→ **A0（lens identity を label→安定 id へ decouple）を新設・最初に実施**。**実装は別セッション**（本セッションは設計確定 + C まで）。順序 = **A0 → A → B+D → E → F**（破壊的・relay 多段）。


- **A0 lens identity を安定 id へ decouple**（(い) の前提・**挙動不変リファクタ**で安全に先行可） — 今 lens は **label 文字列で同定**: `ActiveSection.lens(label)` / `catalog.activeSectionLens` / `setActiveLens`（[Controller+CLIDispatch.swift:467](Sources/FacetApp/Controller+CLIDispatch.swift#L467)）/ `setSectionLens` の `$0.label ==`（[NativeAdapter.swift:648](Sources/FacetAdapterNative/NativeAdapter.swift#L648)）/ `headerActive` の `sec.label == activeLens`（[SidebarView.swift:540](Sources/FacetViewTree/SidebarView.swift#L540)）。label が空可・重複可になると同定が壊れる（`lens("")`／空ラベル2個を区別不可）。→ **lens 内部キーを declOrder（config 宣言順＝`ProjectedSection.id` の `"section:<declOrder>:<label>"` に既存・display reorder 不変・label 非依存で一意）へ**。label は表示専用に降格。`facet lens NAME` は **非空 unique label のみ** name→id 解決（無名 lens は `facet section --focus N`/クリックで id 経由 activate）。projection id は declOrder 込みで衝突しない＝変更不要。
- **A Core: モデル/一意性** — `DesktopSection.parse`（lens [:183](Sources/FacetCore/DesktopSection.swift#L183)/unassigned [:207](Sources/FacetCore/DesktopSection.swift#L207) の label 必須 guard 除去・workspace [:202](Sources/FacetCore/DesktopSection.swift#L202) の label 破棄をやめ保持）で **全 type label optional**（(い)）・lens `match` は必須維持／`decodeDesktopSectionSections`（[FacetConfig+Decode.swift:65](Sources/FacetCore/FacetConfig+Decode.swift#L65)）に desktop 内 **非空 label のみ unique（warn+先勝ち・空はスキップ＝複数可）** 新規追加／`effectiveWorkspaceList`（[FacetConfig.swift:514](Sources/FacetCore/FacetConfig.swift#L514)）を `s.label`（空可）へ。⚠️ **#338 で TOML が swift-toml-edit 経由に変更**＝parse 層の見え方を着手時に確認。
- **B Core: 命名廃止** — [WorkspaceNaming.swift](Sources/FacetCore/WorkspaceNaming.swift) 廃止、参照 3 箇所（[FacetConfig:514](Sources/FacetCore/FacetConfig.swift#L514)/[DynamicWS:37](Sources/FacetAdapterNative/NativeAdapter+DynamicWS.swift#L37)/[WorkspaceLabel:21](Sources/FacetCore/WorkspaceLabel.swift#L21)）を index ベースへ。`addWorkspace` emoji 命名除去（label 空で作成）。
- **C CLI: `facet section --focus N|label`** — verb（FacetApp+ClientCommands）+ DNC post（FacetApp+Client）+ `section:` dispatch（Controller+CLIDispatch）。index→ActiveSection は `lastSections[N-1]` 解決。index/label 判定は `parseWorkspaceFocus`（[FacetApp+Client.swift:186](Sources/FacetApp/FacetApp+Client.swift#L186)）流用。`facet lens`/`workspace --focus` は当面残す。
- **D 表示統一** — 新 `sectionDisplayLabel(index:label:)`（[WorkspaceLabel.swift](Sources/FacetCore/WorkspaceLabel.swift)）= `label.isEmpty ? "\(index)" : "\(index) (\(label))"`。`"WS\(ws+1)"` 除去・lens と共通化（[ViewContextMenu.swift:115](Sources/FacetView/ViewContextMenu.swift#L115)/:152）・tree([SidebarView.swift:623](Sources/FacetViewTree/SidebarView.swift#L623))/grid([GridView.swift:463](Sources/FacetViewGrid/GridView.swift#L463))/rail([RailHeader.swift:69](Sources/FacetViewRail/RailHeader.swift#L69))。
- **E tree rename** — `SectionEditPanel`（TagEditPanel 同型）+ `enterSectionLabelManage` + 入口（キー/ヘッダメニュー）+ `WindowBackend.renameSectionLabel(index:to:)`（runtime・session-only or `facet section --rename`）。
- **F config/schema/docs/test** — [config.toml](config.toml) を label optional 例へ・[FacetConfig+Spec.swift](Sources/FacetCore/FacetConfig+Spec.swift)→`--emit-schema`・CLAUDE.md ルール反転+glossary/README+memory・`WorkspaceNamingTests` 削除/`SectionDecodeTests`(optional+unique)/`WorkspaceLabelTests`(`sectionDisplayLabel`)。

### 調査メモ（次セッション用・2026-06-25 調査）
- **DNC dispatch は main actor 上**（`installCLIControl` の `MainActor.assumeIsolated`・[Controller+CLIDispatch.swift:26](Sources/FacetApp/Controller+CLIDispatch.swift#L26)）→ `dispatchSectionFocus` は `lastSections`/`lastWorkspaces` を直接読める（threading hop 不要）。**headless（wss=0／パネル未表示）では `lastWorkspaces` が空**になり得る点に注意（degrade は `SectionOrder.applyWorkspaces` で並べた `lastWorkspaces` を使うため、空なら "no sections"）。
- **ws.index は 0-based**・`ActiveSection.workspace(n)` は 1-based（`activeWSIndex = (ws.index ?? 0)+1`・[Controller.swift:153](Sources/FacetApp/Controller.swift#L153)）。workspace section → `.workspace(sourceWorkspaceIndex+1)`（既存 grid pick [Controller+Grid.swift:80](Sources/FacetApp/Controller+Grid.swift#L80) と同一・C で踏襲済）。
- **空 section へ移動時の focus 仕様**（#337 で理解確定）: `applyAutoFocus`（[NativeAdapter.swift:618](Sources/FacetAdapterNative/NativeAdapter.swift#L618)）は移動先が非空なら `autoFocusTarget`（last-touched `lastFocusedOnLeave` → `predictedFocus`＝newest・[WorkspaceCatalog+Layout.swift:233](Sources/FacetAdapterNative/WorkspaceCatalog+Layout.swift#L233)）で focus、**空なら `activateFinder()`**（[NativeAdapter.swift:739](Sources/FacetAdapterNative/NativeAdapter.swift#L739)＝デスクトップへ defocus・public API only・「空WS」シグナル）。**「いい感じの窓 or 無ければ focus 無し」は既に満たす**。#337 で直したのは「空移動後に tree が旧窓を focused 表示する stale」のみ（`hot` を `headerActive` で gate・section/degrade 両 render path + sig）。
- **focused 窓の解決**: `focusedWindow()` → `AXFocus.frontmostFocusedCGID`（[AXFocus.swift:161](Sources/FacetAccessibility/AXFocus.swift#L161)＝frontmost app の kAXFocusedWindow）。park 窓は OS focus が残る（facet park は on-screen sliver ＝ `isOnscreen` true なので isOnscreen では区別不可）→ A0/将来 isFocused を「active section 内のみ」へ厳密化する余地（今は view 側 gate で十分）。

### 検証
`grep -rn "WorkspaceNaming" Sources` = 0／`swift build`／`swift test`（ローカル Xcode 26.5）／実機 `./run.sh` で `facet section --focus 1` 移動・`index (label)` 表示・tree rename。**#337 の実機目視 2 点（非空 focus 切替／空移動で旧窓非 active）はトミー側で wss≥1 時に確認**（本セッションは env wss=0 で未）。

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
