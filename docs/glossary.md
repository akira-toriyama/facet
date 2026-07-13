---
title: facet 用語集
tags: [glossary, macos, window-manager]
repo: facet
aliases: []
---

# 用語集 — facet のユビキタス言語

facet を構成する各パーツの **正規の呼び名** をまとめた規範ドキュメント。
**コード・ドキュメント・コミットメッセージ・PR タイトル・Claude Code への
プロンプト、すべてここに載っている名前のみを使う**。同義語は揺らぎを生む。
1 つに決めて、それで通す。

なお **正規名は英語のまま** 保持する。コード識別子・設定キー
（`FacetCore`, `WindowBackend`, `[[desktop.N.section]]`, `pal` など）と一対一に対応
させるため。日本語化するのは説明文だけ。

なお **似て紛れやすい 5 概念** は最優先で区別する（下の「5 つの中核概念」を
参照）。とくに **mac desktop**（OS の native Space）と **facet workspace**
（facet 独自の抽象）は語感が近く混同の温床なので、コード識別子・設定キー・
コメントすべてで綴り分ける。階層は **mac desktop > [[section]] > window**、
plus **[[facet workspace]]**（各 section の空間セル）と **[[isolate desktop]]**
（`[desktop.N] type=isolate` の常時 match 駆動 desktop）。**isolate は desktop の型で
あって section ではない**（旧 section-lens は t-ec9s で退役・旧称 `lens` は t-mqqw で退役）。

用語が足りなければ、その用語を導入する PR で同時にこのファイルへ追記する。
用語名を変える場合は、コード・ドキュメント・このファイルを **同一 PR で**
書き換える。

> 各エントリの形式: **正規名**, 1〜2 行の定義, 設定 / コードでの所在,
> そして `Don't call it:` 行 — このエントリが置き換える誤った呼び名のリスト。

---

## アーキテクチャ全体像

facet は **ヘキサゴナル 3 層分割**（[docs/architecture.md](architecture.md)）。
下の図は層と主要な seam を示す。レイヤーをまたぐ型は常に protocol を介す。

```mermaid
flowchart TB
  subgraph CORE["FacetCore — pure logic (CoreGraphics OK / NO AppKit / NO AX)"]
    MODELS["Models / WindowBackend (port)"]
    CONFIG["FacetConfig"]
    LOG["Log"]
  end
  subgraph ADAPTER["FacetAdapterNative — OS adapter (AX + CGS + SkyLight)"]
    NATIVE["NativeAdapter (sole backend)"]
    AXHELPERS["FacetAccessibility (AXFocus / AXTitles / AXGeom / Displays / WindowEventObserver / MacDesktops)"]
  end
  subgraph VIEW["FacetView — GUI only"]
    PANELHOST["PanelHost"]
    SIDEBAR["SidebarView (tree)"]
    GRID["Grid overlay"]
    THEME["pal (palette)"]
  end
  subgraph APP["FacetApp — @main + CLI"]
    MAIN["FacetApp.Main"]
    CTRL["Controller (application coordinator)"]
    DNC["Distributed<br/>Notification"]
  end
  MAIN -->|argv| CTRL
  DNC -->|cross-process| CTRL
  CTRL -->|WindowBackend| NATIVE
  NATIVE --> AXHELPERS
  CTRL --> PANELHOST
  PANELHOST --> SIDEBAR
  PANELHOST --> GRID
  PANELHOST --> THEME
```

---

## レイヤー / モジュール

### FacetCore
**純ロジック層**。CoreGraphics の値型は OK だが AppKit / AX / バックエンド型
は持ち込まない。XCTest で単体検証可能であることが層境界の根拠。
- 場所: [`Sources/FacetCore/`](../Sources/FacetCore/)
- 含むもの: `Models`, `WindowBackend` protocol, `FacetConfig`, `Log`
  （`Controller` は AppKit に依存する Application coordinator なので
  [[FacetApp]] 側。architecture.md の Application 層に一致）
- **Don't call it:** domain layer, business logic, model layer, ドメイン層

### FacetAdapterNative
**window 管理の唯一の backend adapter**（v2.0.0 で `rift` 廃止。画像 capture は
別軸の [[FacetCapture]]）。AX / CGS / SkyLight プライベート API への入口。
[[WindowBackend]] を実装。バックエンド固有の型は **この中に閉じ込める**。
- 場所: [`Sources/FacetAdapterNative/`](../Sources/FacetAdapterNative/)
- **Don't call it:** native backend, ax adapter, アダプタレイヤー（一般化したい時のみ）

### FacetCapture
**画像 capture adapter**（P7）。`ScreenCaptureKit` の唯一の consumer で、
FacetCore の [[WindowCapturing]] port を実装（`SCKWindowCapture`）。
window 管理（AX/CGS）とは別軸の backend なので [[FacetAdapterNative]] に畳まず
独立モジュールにする。`FacetView` は capture backend を import しない。
- 場所: [`Sources/FacetCapture/`](../Sources/FacetCapture/)
- **Don't call it:** preview module, screenshot adapter, WindowPreview（旧 FacetView 内の型名・P7 で改名移設）

### FacetAccessibility
M5 で抽出した **AX ヘルパ群**。`AXFocus`, `AXTitles`, `Focus.assert /
withRetry`, `AXGeom`, `Displays`, `WindowEventObserver`, `MacDesktops` がここに
住む。Phase ε 後の唯一の consumer は `FacetAdapterNative`。新規 AX コードは
backend 固有でない限りここへ。
- 場所: [`Sources/FacetAccessibility/`](../Sources/FacetAccessibility/)
- **Don't call it:** ax utils, accessibility helpers, AX ユーティリティ

### FacetView
**GUI 専用層**。View は `WindowBackend` protocol だけを見る。具体 adapter を
直接参照しない。
- 場所: [`Sources/FacetView/`](../Sources/FacetView/)
- **Don't call it:** ui layer, presentation layer, ビュー層

### WindowBackend (port)
Core と **window 管理 adapter** の間の seam（hexagonal port）。workspaces /
move / focus / switch / layout / display / event stream を抽象化。Controller /
View が見るのはこの protocol のみ。capture は別 port（[[WindowCapturing]]）。
- 定義: [`Sources/FacetCore/`](../Sources/FacetCore/) 内
- **Don't call it:** adapter protocol, backend interface, バックエンド契約

### WindowCapturing (port)
Core と **capture adapter** の間の seam（hexagonal port・P7）。per-window 画像
capture（overview サムネ + tree hover preview）を抽象化。[[WindowBackend]] とは
直交する別軸（window 管理 ではなく描画用 asset の取得）。`CGImage` を返す
（FacetCore は AppKit-free）＝view 側が `NSImage` に包む。唯一の実装は
[[FacetCapture]] の `SCKWindowCapture`（ScreenCaptureKit）。
- 定義: [`Sources/FacetCore/WindowCapturing.swift`](../Sources/FacetCore/WindowCapturing.swift)
- **Don't call it:** preview protocol, screenshot interface, WindowPreview（旧型名）

---

## ドメインモデル

### 5 つの中核概念（最優先で区別する）

似た語が複数の意味で流通していた歴史があるため、まずこの 5 つを綴り分ける。

| 正規名 | 意味 | コード / 設定での所在 |
|---|---|---|
| **mac desktop** | macOS の native Space（OS の仮想デスクトップ。Mission Control の "Desktop N"）。**型付き**（`workspace` / `isolate`） | `MacDesktops`, `activeMacDesktopID`, `[desktop.N]` / `[[desktop.N.section]]` |
| **section** | config が宣言する **順序付きの表示単位**（tree の並び）＝各 [[facet workspace]] の空間セル | `DesktopSection`, `ProjectedSection`, `FilterProjection` |
| **window** | facet が扱う個々の OS window（title は AX 解決） | `Window`, `WindowSlot`, `AXTitles` |
| **facet workspace** | facet 独自の window グループ抽象（1 mac desktop に N 個） | `WorkspaceCatalog`, `workspaces()` |
| **isolate desktop** | `[desktop.N] type=isolate` の **常時有効な filtered mac desktop**。`match` の窓を `layout` でタイルし残りを park（tree 専用）。**旧称 `lens` は t-mqqw で退役** | `desktopType`, `desktopIsolate`, `applyIsolatePark` |

**mac desktop ↔ facet workspace は最重要の混同ポイント**。OS のデスクトップ
（mac desktop）と facet の抽象（facet workspace）は別物で、1 mac desktop が
複数の facet workspace を抱える（[[per-mac-desktop workspaces]]）。M11-2 で
両者を 1:1 にする予定だが、それは**実装上の関係**であって、概念としては
区別し続ける。**facet workspace ↔ [[isolate desktop]]** も別物（前者は窓を並べる
空間セル・後者は窓を絞り込む型付き mac desktop）。**facet view**（`tree`/`grid`/
`rail`）は "どう見せるか" の直交軸で、上の 5 概念（何を・どこに）とは別レイヤー。

### mac desktop
macOS の **native Space**（OS が提供する仮想デスクトップ。Mission Control が
"Desktop 1" / "Desktop 2" … と表示するもの）。facet はこれを **read-only** に
しか触らない（別 mac desktop への window 移動は SIP-off が要るので非対応）。
- コード: `MacDesktops`（in `FacetAccessibility`・SkyLight 経由の read-only
  クエリ）, `NativeAdapter.activeMacDesktopID`
- 設定: `[[desktop.N.section]]` / `[desktop.N]`（typed desktop・[[isolate desktop]]）
  ブロック（Mission Control 順の ordinal で指定）
- UI: tree の上部ハンドル帯に "Desktop N"（macOS の呼称に合わせた表示ラベル）
- **Don't call it:** Space, native Space, workspace, virtual desktop（facet
  workspace と紛れる）, デスクトップ別
  - ※ Apple の API 名（`SLSGetActiveSpace`, `NSWorkspace.activeSpaceDidChange`,
    SLS の `"Spaces"` dict キー等）は Apple の語のまま残す。"mac desktop" に
    綴り替えるのは facet 自身の surface だけ。

### facet workspace
**facet が定義する Window 集合**。タブのようにグループ化された window 群を
1 まとまりとして扱う単位。1 つの [[mac desktop]] が複数の facet workspace を
持つ。**workspace は任意の `label` で config 命名可**（§A・旧 `[desktop.N]` の
by-name seed は廃止）。**未命名（label 空）は無名のまま 1始まりの index で表示**
（§B・emoji 自動命名プール `WorkspaceNaming` は退役）。名前変更は実行時
`facet workspace --rename` でも可（session-only）。workspace は空間スロット＝
意味は [[section]] / tag が担う。
- コード: `WorkspaceCatalog` / `workspaces()` / `FacetConfig.effectiveWorkspaceList`
  （section active 時：非空 `label` を名前に・空は無名スロット）／表示は
  `sectionDisplayLabel(index:label:)`（§D・`index` or `index (label)`）
- **Don't call it:** group, tab, page, desktop, mac desktop, Space, グループ, タブ

### isolate desktop
`[desktop.N] type = "isolate"` で型付けした [[mac desktop]]＝**常時有効（always-on）の
match 駆動 desktop**。階層は **mac desktop > section > window**（旧 **board** 層は
t-0sbm で廃止——「workspace と isolate を両方使いたい」は board でなく **mac desktop を
型で分けて**解く。1 ordinal = 1 desktop = 1 type）。`[desktop.N]` は SINGLE table で、
`type` は `workspace`（従来どおり `[[desktop.N.section]]` が中身を記述・section だけ
書けば暗黙にこの型）か `isolate`。
- **挙動**: その mac desktop に居る間ずっと、`match` に合う窓を `layout` でタイルし、
  合わない窓を corner に anchor-park（sticky は免除・`match` から毎 reconcile 導出）。
  focus toggle は無い——**desktop に入ることが focus**。flat＝sub-workspace 無し
  （`effectiveWorkspaceList` は N=1 の 1 slot だけを seed）。**実窓を動かす**（park は
  離れても解けない）——だから旧称 `lens` は嘘だった（下記）。tree に何を並べるかは
  `show-non-matching` が決める（`true` で park された非マッチ窓も **holding** section
  に載り全窓 inventory になる）。
- **tree 専用**（2世界分離）: membership が動的で固定画面が無い→サムネイル不能。
  `--view grid` / `--view rail` はその desktop 上では **loud reject**
  （`IsolateDesktopGate`）。`show-non-matching = true` で tree が **matched** +
  **holding**（非マッチ）の 2 section 表示（既定 false = matched の 1 section）。
- 設定: `[desktop.N]`（SINGLE table・`[[…]]` 配列ではない）: `type` 必須／`isolate` は
  `match` 必須・`layout`・`show-non-matching`・`label` 任意
- コード: `DesktopType.isolate` / `DesktopMeta` / `FacetConfig.desktopType`・
  `desktopIsolate` / `FilterProjection.projectIsolateDesktop`（1|2 section 合成・純）/
  `NativeAdapter.applyIsolatePark`（always-on park + layout seam）/
  `WorkspaceCatalog.isolateParked` / `IsolatePark.parkSet`（純）/ `IsolateDesktopGate`
- **🪦 旧称 `lens`（t-mqqw で退役）**: 光学メタファは「見るだけで対象に触れない」ことが
  語の内容そのものだが、この desktop は**実窓をタイルし・park し・離れても park を解かない**。
  `type = "lens"` は **loud reject**（alias は作らない・`DesktopMeta.parse` が
  「it was never a view」と名指しで返す）。コード側は誰にも指示されず `IsolatePark` /
  `isolateParked` / `facet query` の `parked` に収束していた——config 語がそれに追いついた形。
- **Don't call it:** lens（🪦退役）, board（旧概念・t-0sbm で廃止）, tab, focus mode,
  filtered space, saved filter, フォーカスモード

### 🪦 迷子 (orphan) — 退役（t-6rbc）
**どの [[facet workspace]] にも属さない窓**、という概念だった（`WindowSlot.workspace == nil`）。
**死語**。**facet は迷子を作れなかった** —— 唯一の生成源 `setOrphan` の唯一の呼び元
`orphanWindow` は、t-qtpx が ws→lens DnD を消した時点で**呼び元ゼロ**になっていた。
つまり迷子の集合は 2 リリースにわたり**証明可能に空**で、そのために 6 モジュールが配管を
抱え、tree は**永久に空の section**（[[unassigned]] 受け皿）を描き続けていた ——
[[isolate desktop]] の旧称 `lens` が嘘だったのと**同じクラスの欠陥**（UI が持たないものを
持つと言う）。

**「窓は必ずどれか 1 つの workspace に居る」は、いまや型**: `WindowSlot.workspace: Int`
（Optional ではない）。adopt 経路（`reconcile` → `WindowSlot(workspace: activeIndex)`）は
最初から必ず workspace を割り当てていた。
- 消えたもの: `setOrphan` / `orphanWindow` / `orphanWindows` / `WindowSlot.workspace` の
  `Int?` / `ProjectedSectionType.unassigned` / §G 受け皿 / `GridPick.unassigned` /
  `RailPick.unassigned` / `OverviewCell.isReceptacle` / `facet query` の `"Orphans"` 行
- **`unassigned` は退役キー**（[[unassigned]] 参照）＝黙って消すと section が workspace セルに
  **昇格して layout が変わる**ので、行ごと **loud drop** する
- **Don't call it:** lost window, homeless, デタッチ窓 —— そもそも存在しない

### per-mac-desktop workspaces
各 [[mac desktop]]（native Space）ごとに **独立した `WorkspaceCatalog`** を
持つ機能。`NativeAdapter` は active な mac desktop id でカタログを park / swap
する。SkyLight は **read-only** 利用（書き込みは SIP-off 必要）。SkyLight
未利用環境では `activeMacDesktopID == 0` で 1 つの shared catalog に縮退
（pre-feature 挙動）。**opt-in 管理は `[[desktop.N.section]]` または `[desktop.N]`
ブロックが在れば発火**。[[section]] が 1 つでも在れば section モデルが active 化し、
その desktop の workspace 数 + 各 layout を section が決める（section 未定義の
[[mac desktop]] は既定 5 workspace に縮退）。
- 設定: `[[desktop.N.section]]`（[[section]]・ordinal で指定）
- コード: `MacDesktops`（in `FacetAccessibility`）, `FacetConfig.isMacDesktopManaged`
  / `FacetConfig.isSectionModelActive`（section モデル発火の gate）
- **Don't call it:** per-native-Space workspaces（コメント / メモリでは旧称が
  残る）, virtual desktop workspace, multi-desktop, デスクトップ別

### facet view
ユーザー向け UI surface の種類。`tree` / `grid` / `rail` が正規名（`canonicalViews`）。
新規 view 追加時は `Main.canonicalViews` + `Controller.dispatchView/Hide/Toggle`
の case を増やすだけで済むよう **per-view 専用フラグを作らない**。`--view`
（どう見せるか）は [[facet workspace]] / [[tag]] / [[isolate desktop]]（何を見せるか）
とは直交する別軸。
- CLI: `--view NAME` / `--hide NAME` / `--toggle NAME`
- **Don't call it:** mode, panel, window, lens（🪦退役・[[isolate desktop]] を参照）,
  モード, ペイン

### tree view
左サイドバーに表示する **[[facet workspace]] の階層リスト**。`SidebarView` がレンダリング。
- コード: `SidebarView`
- **Don't call it:** sidebar, outline, list, サイドバー（描画される場所を指す時のみ別）

### grid view
全画面の **window グリッド overlay**。`--view grid` で起動。常に key/active
（construction 上）。
- **Don't call it:** mosaic, overview, expose, モザイク, グリッド表示

### rail view
全画面の **[[facet workspace]] overview**（Mission Control 風）の **active 中央
カルーセル switcher**（2-b）。`--view rail` で召喚。中央 HERO に下見中 WS を大表示、
いずれかの画面 **[[edge]]** に WS の window サムネミニ画面を 1 列（strip）に並べ、
**active を strip 中央に固定**・前後を循環で配置。strip 軸の矢印で **strip が回転**
（中央＝選択／下見のみ・hero が追従）・Return/クリックで切替＆閉じ・Esc で閉じ・
window を WS 間 drag / header drag で swap。WS が `[rail] cells` 数を超えると縮小せず
**回転**（両端 peek で「まだある」合図）。tree / grid とは役割が違う（速い切替・俯瞰）。
起動時に自動表示はされない（facet は常に agent-only で起動・どの view も召喚のみ）。#109 shipped →
M9-3/M9-4 で edge 化 → **2-b でカルーセル化（M9-4 の scroll を置換）**。
- コード: `RailView`（`FacetViewRail`）/ `railBands`・`railCarouselOffsets`（`FacetCore`、純幾何）
- **Don't call it:** switcher, expose, mission control, スイッチャー, ミッションコントロール, scroll bar

### overview surface
**grid view と rail view が共有する「[[facet workspace]] のミニ画面＋window
サムネを敷き詰める全画面 overlay」という総称軸**（tree view は含まない — 階層
リストでミニ画面を持たない）。両 view は値型（`OverviewCell` / `OverviewDrag` /
`OverviewPendingDrop` / `OverviewPendingSwap`）・スロット周回（`cycleSlotIndex`）・
サムネ painter（`drawMiniThumb`）・全画面 panel（`OverviewPanel`）・純幾何
（`OverviewGeometry`）を共有し、さらに**振る舞い契約 `OverviewView`**（`FacetView`
の protocol — snapshot-on-show 入力・move/swap/run-ops コールバック・サムネ供給・
border・共通キー Esc/Return/Space/Tab/`m`）で Controller 配線（`Controller+Overview`
の `seedOverviewCommon` / `presentOverview` / `overviewCommonKey` 等）を 1 本化する。
本質的に異なる部分（grid の `cols×rows` + FLIP ↔ rail の carousel + hero + edge、
`onPick` 形、矢印 nav、scroll 回転）は契約に押し込まない。「overview」単独で
grid view を指すのは禁止（grid view の項参照）— umbrella を指す時は必ず "overview surface"。
- コード: `Overview*`（値型 / 幾何＝`FacetCore`、描画 / panel / `OverviewView` protocol＝`FacetView`）
- **Don't call it:** expose, mission control（個別 view の見た目の比喩）, grid（grid view 専用語）

### edge
rail の strip を寄せる **画面の辺**（`top` / `bottom` / `left` / `right`）。
`--view rail --edge NAME`（一回限り）か config `[rail] edge`（既定）で指定。CLI typo は
**loud exit 2**、config typo は **silent clamp→bottom**（[[facet view]] / theme と同じ
非対称ポリシー）。上下辺＝水平 strip（←/→ browse）、左右辺＝垂直 strip（↑/↓ browse）。
`RailEdge.axis` がこの軸を返す。M9-3 で導入。
- コード: `RailEdge`（`FacetCore`）・`canonicalEdges`/`canonicalEdge`（`FacetApp`）
- **Don't call it:** side, anchor, position, dock（辺以外の意味で）, 配置

### strip
[[rail view]] で [[facet workspace]] の window サムネミニ画面を [[edge]] に沿って
1 列に並べた帯。サムネは行を埋めるよう **justify**（拡大）され、セル間は一定の
gap になる。サイズ上限は `[rail] strip`（画面短辺に対する %・`stripPercent`）で、
[[hero]] が残り領域を占める。同時表示数の上限は `[rail] cells`。`[rail] strip`
という設定キー名そのものでもある（帯の概念とキー名が同名）。
- コード: `RailView.layoutCells` の `stripRect` / `railBands`（strip/hero 分割）
  / `railScaledPads`（短辺基準の余白）
- 参照: [[hero]] / [[carousel]] / [[edge]] / [[rail view]]
- **Don't call it:** bar, dock, filmstrip, tray, [[sliver]]（sliver は anchor
  park 後の残骸＝別概念）, 帯, バー

### hero
[[rail view]] の中央に大きく表示する **下見中（strip 中央）の section プレビュー**。
実画面の縦横比そのままに縮小したミニ画面で、[[strip]] が占めない残り領域を埋める
（`[rail] strip`% の裏返し）。strip の回転（[[carousel]]）で中央 [[facet workspace]]
が変わると hero が追従する。
- コード: `RailView.hero` / `railBands`（hero 領域）
- 参照: [[strip]] / [[carousel]] / [[rail view]]
- **Don't call it:** preview, main, focus, big cell, spotlight, 主画面, プレビュー

### carousel
[[rail view]] の [[strip]] の並べ方（2-b）。**active（＝選択）を strip 中央に固定**
し、残りを前後へ**循環**配置する。strip 軸の矢印で strip 自体が回転して中央＝
選択が変わり（下見のみ・[[hero]] が追従）、Return / クリックで確定＆閉じる。
**strip は [[facet workspace]] 単位**でセルを一列で回す。
`[rail] cells` 上限を超えるセルは縮小せず回転で送り、両端に **peek**（次セルの
見切れ）で「まだある」合図を出す。**scroll は無い**（M9-4 の scroll を置換）。
- コード: `railCarouselOffsets`（`FacetCore`・純幾何・各 position の中央からの
  符号付き slot offset・選択=0・循環）
- 参照: [[strip]] / memory `[[facet-rail-carousel-decisions]]`
- **Don't call it:** scroll, scrollbar, pager, filmstrip, slider, スクロール, ページャ

### AX target
**現在 facet が操作対象とする window**。`Window.title` は backend だけで
埋まるとは限らず、`AXTitles.resolve` が `kAXTitle` を short-TTL で解決する
（memory `[[window-titles-AX-resolved]]`）。
- コード: `AXTitles` / `AXFocus`
- **Don't call it:** focused window, active window, frontmost window,
  target app, フォーカスウィンドウ, アクティブウィンドウ

### BSP tiling / stack tiling
γ Phase で導入された 2 種の tiling layout。`facet workspace --layout NAME`
で切替。AX role が `dialog` / `sheet` / `palette` の window は **auto-float**
（tiling 対象外）。
- CLI: `--layout NAME` / `--retile`, `facet window --toggle-float` /
  `--toggle-orientation` / `--cycle-stack next|prev`
- **Don't call it:** auto layout, window split, ウィンドウ分割

### master-stack layouts（`master-left` … `master-center`）
master 窓（`order[0]`）が 1 つの辺に陣取り、残りが反対側に積まれる
stateless layout 群。**5 つの正準名**＝`master-left` / `master-right`
/ `master-top` / `master-bottom` / `master-center`（M9-2）。実体は
2 幾何（4 辺共通の edge-master + 中央 3 帯の center-master）で、対辺
どうしは内部 mirror/rotate の鏡像。`--layout master-EDGE` で直接選ぶ
（M9-2 以前の `tall` / `wide` / `centered` は破壊的にリネーム＝alias
無し）。master 比率 / 枚数は `--grow-master` / `--inc-master` 等で実行時
調整、`isMaster` / promote-to-master もこの群でのみ有効。`--toggle-
orientation` での flip は廃止（辺を直接指定するため）。
- コード: `MasterLeftLayout` … `MasterCenterLayout`（`LayoutRegistry`）。
  小バッジ表示は `m-EDGE` に省略（`layoutBadgeLabel`）。
- **Don't call it:** tall, wide, centered（M9-2 で改名・旧称）, 縦/横
  分割, master_stack

### layout mode（per-workspace の layout engine 選択軸）
**1 つの [[facet workspace]] の tiled 窓をどう並べるかを選ぶ軸**。コードの
`layoutMode` / `setLayoutMode` / `--layout NAME` がこの軸。**正準名**＝`float`
（既定・タイルしない）/ `bsp` / `stack` / `master-left` … `master-center`
（[[master-stack layouts]]）/ `grid` / `spiral`。session 限り（`[layout] default`
が起動時シード）。
- ⚠ **`grid` の二義に注意**：ここでの `grid` は **layout**（`GridLayout`・
  `--layout grid` の値＝窓を格子タイル）。同名の **grid [[facet view]]**（`--view grid`
  の俯瞰サーフェス）とは別物。
- コード: `LayoutRegistry`（stateless 群）+ `bsp`/`stack`/`float`（stateful）。
- **Don't call it:** layout（[[facet view]] の grid と紛れる時のみ明示）

### mark
**window に付く名前付きラベル兼ジャンプ先**。`facet window --mark NAME` で
focus 中の窓に付け、`--focus-mark NAME` でその窓へ一気に focus 移動（必要なら
WS も切替）、`--unmark NAME` で外す。**1:1 双射**（1 窓 1 mark・`WorkspaceCatalog.marks`）。
tree では窓行に **primary 枠線の丸角ピル**で `NAME` を表示。`sticky` / `scratchpad`
/ `tag` とは直交（mark は識別ハンドル、他は可視性/配置）。session 限り。
- **Don't call it:** bookmark, label, tag（[[tag]] は可視性ラベルで別概念）, ジャンプ先, しおり

### sticky window
1 つの window を **現在の mac desktop 内・全 facet workspace のメンバー**
にして出っぱなしにする（PiP / タイマー / チャット / 音楽）。実装は既存
anchor park の再利用 2 点だけ:（1）**park 免除** — `shouldParkAnchor` が
sticky id に false を返し、WS 切替で anchor sliver へ流されない、（2）**強制
floating** — `floatingWindows` にも入れて tiling に参加させない（WS ごとに
reflow する tiled 窓が同時に「出っぱなし」はできないため）。集合は
`WorkspaceCatalog.everywhereWindows`。解除すると **今いる workspace の通常
タイル窓**に着地（元 home WS には戻さない＝目の前の窓が消えない POLA）。
mac desktop 跨ぎは対象外（READ-only SkyLight・macOS の「すべてのデスク
トップ」任せ）。session 限り・per-mac-desktop・`marks` と直交。
- CLI: `facet window --toggle-sticky`（`--toggle-float` で OFF にしても同じ
  着地＝float-exit = sticky-exit）。`facet query` に `N sticky`、tree に
  **枠線無し・水平の `SF:pin` アイコン + "sticky" テキストバッジ**（`pal.foreground`・
  枠線なし・斜体なし＝pin グリフが float と区別する。旧 📌 絵文字を廃止・PR#252 で
  枠線/斜体を撤去）。
- UI: tree の右クリック / `m`（keyboard nav）コンテキストメニューに **"Sticky"**
  （非 sticky 窓）/ **"Unstick"**（sticky 窓）項目。sticky 窓は floating で
  float-exit=sticky-exit ゆえ "Unfloat" は出さず "Unstick" 一本に集約。
- **Don't call it:** always-on-top, pin, float, 常駐ウィンドウ, scratchpad
  （scratchpad は「名前付きの隠し棚から今の WS に呼ぶ」別機能）

### tree status badge (master / float)
tree の各 window 行に、その窓の状態を示す **枠線無しのアイコン + テキスト
バッジ**（`SidebarView` の `drawStatusPill`）。**master**（tiling の `order[0]`）は
`SF:crown` + "master" を `pal.primary`（緑）で、**float**（floating 窓）は
`SF:macwindow` + "float" を `pal.foreground`（"Desktop N" 帯ラベルと同色）で描く。
PR#252 で全バッジを枠線/塗り/斜体無しの icon+text に統一（sticky / scratchpad /
hidden / `#tag` チップと同じ clean な見た目）＝色とグリフが意味を運ぶ。
- コード: `SidebarView.drawStatusPill`（`FacetViewTree`）
- ⚠ workspace 単位の layout バッジ（`m-EDGE`＝[[master-stack layouts]]）とは別物：
  こちらは **窓ごと**の master/float 状態を指す。
- **Don't call it:** pill, outline badge, ピルバッジ, 枠線バッジ, 斜体バッジ

### scratchpad
**名前付きの隠し棚**。既存 window を登録すると即 anchor park で隠れ、必要な時
に **今いる workspace へフロート overlay として呼ぶ**（ドロップダウン端末 /
メモ用途）。`sticky` が「全 WS に出っぱなし」なのに対し scratchpad は「普段は
隠れていて呼んだ WS にだけ出る」＝役割が被らない。実装は park + floating +
名前付きマップの再利用:`WorkspaceCatalog.scratchpads`（`[名前: WindowID]`
1:1 双射・`marks` と同型）+ `stashedWindows`（隠れ中＝棚に居る集合）。
- **stash / summon / settle / release** … `--stash NAME`＝即 park（強制
  floating + 棚へ）。`--toggle NAME`＝**今の WS で見えていれば棚に戻す / 見え
  ていなければ今の WS に呼ぶ**（別 WS に居着いた窓を引っ張るのも同じ操作）。
  呼んだ窓は **居着く**（普通の floating 窓として WS 切替で park/restore・棚
  に戻すのは見えてる時に toggle した時だけ）。`--release NAME`＝棚から外して
  今の WS の通常タイル窓にする（`sticky` 解除と同じ着地・POLA）。
- 表示制御の肝: 隠れ中（stashed）の窓は **snapshot から除外**＝tree にも window
  count にも出ず、`facet query` の `stashed:` 行にだけ名前が出る。居着き
  （settled）の窓は tree に **枠線無しの `SF:tray` アイコン + `scratchpad:NAME`
  テキストバッジ**（`pal.tertiary`＝最も控えめな tier・PR#252 で枠線を撤去）。
  WS 切替で stashed 窓を絶対 restore しないよう `setActive` の park/restore
  リストと `resyncVisibleState` で `isStashed` を明示スキップ（`sticky` の
  park 免除の鏡像）。
- spawn なし（既存窓の出し入れのみ・launcher 化しない＝rules engine 領域は
  scope 外）。`sticky` と排他（一方を立てると他方解除）/ `marks` と直交 /
  float-exit = scratchpad-exit（`--toggle-float` で release）/ 窓 close で
  `forgetWindow` が自動 prune / session 限り・per-mac-desktop。
- CLI: `facet scratchpad --stash NAME / --toggle NAME / --release NAME`
  （`window` でも `workspace` でもない**新 subject**＝名前付きスロットを扱う
  ため）。
- **Don't call it:** 隠し窓, hidden window, stash（git の stash ではない）,
  sticky（sticky は「全 WS に出っぱなし」別機能）, launcher（起動はしない）

### real-window DnD (枠C)
実 window を mouse で直接掴んで active workspace の tile 内を再配置する操作
（PR-1 = backend / PR-2 = UI / PR-3 = prediction overlay）。検知は Controller の
**global NSEvent monitor**（観測のみ・facet 自身の programmatic move は mouse-down
が無いので自然に除外）。対象は tile 可視 window のみ（**float 除外**）。
- **intent zone** … drag 中、対象 window 上のカーソル位置を分類する純粋幾何
  ([Sources/FacetCore/IntentZone.swift](../Sources/FacetCore/IntentZone.swift))。
  中央矩形（面積 ~40%）= **swap** / 四隅対角線の三角ウェッジ 4 辺 = **insert**。
- **swap / insert** … backend verb 2 種（`WindowBackend.swapWindows` /
  `insertWindow(_:beside:edge:)`）。stateless / stack は window order、bsp は
  `LayoutTree` を変換。**CLI には出さない**（DnD 専用 op）。
- **InsertEdge** … insert 先の辺（`left` / `right` / `top` / `bottom`）。
  layout が解釈（bsp = その辺で分割 / stateless = order の前後）。
- **prediction overlay** … drag 中、ドロップ後レイアウトを HazeOver 風に提示
  ([Sources/FacetView/DndPredictionOverlay.swift](../Sources/FacetView/DndPredictionOverlay.swift))。
  暗幕で全体を沈め、**動く window だけ**スポットライト（accent 実線 = 掴み窓 /
  accent2 破線 = 玉突きで動く窓）。frames は `WindowBackend.predictedDrop`
  （commit と同じ計算 → ズレ無し）。
- **resize（機能2・縁ドラッグ）** … window の縁を掴んでリサイズ→隣接連動。
  FOLLOW モデル（掴んだ window は OS native resize・facet は ratio 更新 +
  反対側を連動）。`WindowBackend.resizeWindow(_:to:)` が「掴んだ window の新
  frame → **controlling split**（その辺を仕切る最近接祖先 split・yabai
  `window_node_fence` 流）の ratio」を更新（bsp）/ master 仕切り
  （`master-*` の `masterRatio`）。PR-1 = 土台 backend のみ。
- **Don't call it:** window warp, snap zone, drop zone, ドラッグ移動

### loading skeleton
mac desktop 切替時の flicker を隠す **CLI-triggered な skeleton 表示**。
`facet --view tree --loading MS` を **switch キー押下より前に** 外部から
発火させる（macOS は pre-mac-desktop-switch hook を出さないため auto trigger 不可）。
- コード: `Controller.showLoading` → `SidebarView` の skeleton
- **Don't call it:** placeholder, loader, spinner, ローディング表示

### anchor
**非アクティブ [[facet workspace]] の window を画面から隠す手法**。AX
`kAXPosition` で window を画面隅へ寄せ、最小可視の [[sliver]] だけ残す
（macOS の clamp で完全な画面外には出せないため）。公開 AX のみ・SIP-on・
**即時**（アニメ無し）。facet 唯一の hide 手法（`minimize` は genie アニメで
WS 切替が遅く 2026-05-28 廃止）。parked 窓は `isOnscreen=true` を保つので、
ユーザーの Cmd+H / Cmd+M による真の hide と区別できる。`sticky` / `scratchpad`
はこの anchor park の再利用。
- コード: `shouldParkAnchor` / `applyHide`（`FacetAdapterNative`）
- 参照: memory `[[native-window-hide-methods]]`（全 hide 手法の検証記録・
  完全消去は SIP-off 必須で本体 scope 外）
- **Don't call it:** corner hide, HideCorner（rift の旧称）, off-screen hide,
  minimize（別手法・廃止済）, 角配置, 隅寄せ

### sliver
**anchor park 後に画面隅に残る window の可視部分**。macOS の clamp invariant
により最小 **1×41 logical pt**（右下隅）まで詰められるが、完全な 0px には
できない（macOS が「title bar は必ず画面内に残して救出可能にする」救済仕様の
ため）。完全消去（画面 + Mission Control から消す）は公開 / read-only-private
API では不可能で SIP-off + Dock 注入が要る＝本体 scope 外。
- 参照: [[anchor]] / memory `[[native-window-hide-methods]]`
- **Don't call it:** strip, remnant, leftover, edge（[[edge]] は rail の辺の
  別概念）, 残り, 断片, はみ出し

### tag
**window に付く自由記述の文字列ラベル**（free-form・多重所属＝1 window = タグの集合）。
storage は `WindowSlot.tags: Set<String>`（語彙宣言なし・初出で自動生成・上限なし・
session-only・per-mac-desktop）。[[facet filter]] の `match` で `tag~=NAME` として参照され、
NAME を持つ窓を集める（[[isolate desktop]] / [[rule]] の `match`・`facet query --filter`）。
割当は **runtime のみ**（config に静的マッピングなし）：
`facet window --tag NAME / --untag NAME / --toggle-tag NAME / --retag OLD NEW`。新規窓が
[[rule]] の [[match]] に当たれば その `apply` tags を継ぐ。tree では各窓行に全タグを `#tag`
チップ表示（`Window.tags: [String]`・seam で sorted）。tree の `t`（tag-manage）でも編集する。
- **タグの付与と絞り込みを混同しない**（用語規則）：`facet window --tag` = **窓**にタグを
  付ける（初出なら自動生成）／[[facet filter]] の `tag~=NAME` = その語彙で **絞り込む**
  （窓のタグは不変）。`facet window --retag OLD NEW` は窓の OLD を NEW に置換
  （OLD 不在なら NEW の素の付与・`OLD==NEW` は no-op）。read は `facet query --tags`
  （いま使われている全タグの sorted union）。
- **Don't call it:** label, category, workspace（tag は多重所属、workspace は 1 窓 1 個）, group, ラベル, カテゴリ

---

## CLI / IPC

### DNC (Distributed Notification)
プロセス間 IPC の通り道。`facet --view tree` のような CLI 呼び出しは
`com.facet.app` 宛の Distributed Notification として届く。
- **Don't call it:** ipc message, event, distributed event, IPC イベント

### `--active` modifier（廃止）
🪦 **廃止** — `--view tree` 自体に畳み込まれた。tree は常にキーボードナビ
モードで開く（show = `enterActive`＝activation policy フリップ + key 取得）。
窓に作用する瞬間（click / Enter → `exitActive` 先行）に key を手放すので
same-app focus（#66）は維持。[[grid view]] は construction 上常に key/active。
- **Don't call it:** focus flag, activate flag, アクティブフラグ

### typo rejection
未知の view / theme 名は `exit 2` + stderr で **明示エラー**。silent fallback
は意図的に出さない。
- 反例: TOML キーの値は **clamp**（typo 起こしても layout が壊れない方針）
- **Don't call it:** strict mode, fail-fast, 厳密モード

### query
server の管理状態を読む **read-only verb**（`facet query`）。backend / theme /
workspaces（active マーカー + 窓数）/ last error / timestamp の greppable な
スナップショットを stdout に出す。server が `/tmp/facet-status.json` を
atomically 書き、client が読む（[[DNC (Distributed Notification)]] と同じ
post-and-exit 系の IPC）。#227 で旧 `facet status` を吸収・改名（出力は同一）。
`facet query --windows`（#223）は全 mac desktop の全窓を flat JSON 配列で吐く
（raw プロパティ + 窓ごとの `facet` 状態 / 管理外は `null`・yabai `-m query` 相当・
`jq` で絞る）。server は `/tmp/facet-query.json` を reconcile 毎に atomic 書き込み。
`facet query --tags`（#228）は **いま窓に付いている全 [[tag]] の sorted union**を
JSON 配列で吐く（session-only・窓を 1 つもタグ付けしていなければ `[]`）。
projection flag は 1 回につき 1 つだけ（`--windows`/`--tags` の複数併用は
exit 2）。query は read-only。`facet window --tag NAME` がタグを書く write verb なのに
対し、`query --tags` はその集合を読むだけ（read ↔ write の別物）。
- コード: `runQuery`/`runQueryWindows`/`runQueryTags`（`FacetApp`）/
  `StatusSnapshot`・`WindowQueryEntry`/`WindowQuery`（`FacetCore`）/
  `definedTagNames()`/`queryEntries()`（backend）
- **Don't call it:** status, facet status, state dump, info コマンド

### facet filter
window 述語を書く facet 横断のミニ言語（SQL の WHERE 句相当）。`facet query --filter`・
[[isolate desktop]] の `match`・[[rule]] の `match`・`facet section --match` が **1 つの文法**を
共有する＝pivot が search / AX-role-float の個別マッチ機構を統合する
横断プリミティブ（memory `[[facet-filter-pivot-plan]]`）。
- atom = `field op value`。op は **CSS 属性演算子**：`=`（完全一致）/ `~=`（空白トークン
  含有・list 値 `tag` 向け）/ `^=`（前方）/ `$=`（後方）/ `*=`（部分）/ `|=`（階層前方）。
  裸 field は presence（`tag` / `floating` / `sticky` / `master` …）、`not tag` は
  タグを 1 つも持たない窓。
- 結合 = `and` / `or` / `not` / `()`（各 1 綴り・優先 `not` > `and` > `or`・暗黙 space-AND /
  comma-OR / `-` 否定短縮なし）。値は裸 or `"…"`（引用内は `* ^ $` もリテラル）。大小無視が
  既定・末尾 ` s` で大小区別。
- field 名 frozen: `app` / `title` / `bundleId` / `workspace` / `tag` / `floating` / `sticky` /
  `master` / `mark` / `scratchpad` / `desktop` / `onscreen` / `focused`。未知 field は parse
  通過 → eval で no-match（typo は eval で loud・parse は crash しない）。malformed 式は caret 付き
  loud だが **non-fatal**（該当面は show-all へ degrade）。**regex / 数値 op / `is:` / `has:` /
  `[...]` なし**（重いパターンは将来 `facet query | jig`）。
- コード: `FacetFilter`（AST + `parse` + `matches` + `description`）/ `WindowFields`（窓 → field
  解決の protocol）/ `QueryFilter`（`facet query --filter` 配線）。すべて `FacetCore`・
  純ロジック・CI-only テスト。#283（Phase 0）で AST/parser/evaluator、#290 で
  `facet query --filter`。[[isolate desktop]] の `match` もこの言語を共有する。
- **Don't call it:** query language, search syntax, predicate DSL, WHERE engine,
  クエリ言語, 検索構文, フィルタ DSL

### CLI 文法（`--flag VALUE`）
全コマンドが **yabai 式の空白区切り**（`--flag VALUE`）。`--flag=VALUE`（`=`）は
#227 で全廃（hard cutover・後方互換なし）。各 flag は arity を宣言し、値トークンを
無条件に食う（**strict consumption**・lookahead ゼロ）ので負座標 `--pos-x -1440` も
そのまま読める。パース用の純粋型 `ArgCursor` は [[FacetCore]]
（`Sources/FacetCore/CLIParse.swift`・AppKit 非依存で単体テスト可）にあり、
FacetApp の client 層（`Main.swift` / `FacetApp+Client*.swift`）がそれを駆動して
exit / stderr など副作用を担う。コアへ渡る DNC 制御文字列（`view:rail+edge:left` /
`view:tree+loading:300` 等・`view:NAME` に `+loading:` `+geom:` `+edge:` の修飾子が付く）は不変。
- **Don't call it:** equals syntax, `--flag=value`, GNU-style options

### active section
**常にちょうど 1 つ**。[[facet workspace]] desktop ではアクティブな facet workspace、
[[isolate desktop]] ではその always-on な合成 section。`ActiveSection`
（`Sources/FacetCore/ActiveSection.swift`）は **単一 case の enum**（`case workspace(Int)`・
1-based）＝section を activate するとは workspace を切り替えることに他ならない。
t-ec9s で **section-lens の ACTIVATE 概念が撤去**され、旧
`activeLens XOR activeWorkspace` の二択は消えた（`facet lens NAME` という動詞も無い）。
CLI / tree header クリック / grid・rail のセルクリックは全て `Controller.activateSection`
という 1 本の seam を通る。
- **Don't call it:** active lens, current section, selected workspace, アクティブレンズ

### section
config で宣言する **順序付きの表示単位**（`[[desktop.N.section]]`）。per-mac-desktop の
順序付き配列で、**配列順 = [[tree view]] の表示順**。**全 section は [[facet workspace]] の
空間セル**（タイル単位・grid/rail のセル）＝`{ label, layout }` だけを持つ。
かつての `type = "lens"` section（保存可視性フィルタ）は **退役**した（t-ec9s）＝その後継は
[[isolate desktop]] としてのみ存在する。
- **workspace セル（既定）**: 常設の空間土台。**任意の `label` で命名・無名は 1始まり
  index 表示**。任意の `layout` seed を持つ。所属は DnD / `facet window --move-to N` で
  変える。`type` / `match` / `apply` は無い（stray なキーは decode で無視＝
  `config --validate` が flag）。
- **🪦 `unassigned = true`（マーカー）は退役**（t-6rbc・[[unassigned]] 参照）。**全 row が
  workspace セル**になった。

section 未定義の [[mac desktop]] は内蔵の既定 workspace 群へ degrade。**LIVE**（tree が
消費）＝`FilterProjection.project` が live window 上に section を投影し、1 表示単位として
`ProjectedSection` を産む。**config の宣言 `DesktopSection` ↔ 投影結果 `ProjectedSection`
を区別する**（後者は旧称 `FilterGroup`＝Phase D で禁止語 group をリネーム）。
- コード: `DesktopSection`（config 宣言・`{ label, layout }`）/
  `ProjectedSection`（投影結果＝1 表示単位・`id`〔`"ws:<index>"`〕/
  `label` / `windows` / `sourceWorkspaceIndex`・`OverviewModels`）/
  `FilterProjection.project`（投影・純）/
  `FacetConfig.macDesktopSectionConfigs` / `decodeDesktopSectionSections` /
  `effectiveMacDesktopSectionConfigs`（`FacetCore`）
- **Don't call it:** group（旧称＝旧型名 `FilterGroup`）, lens / `type="lens"` section（🪦両方退役・
  後継は [[isolate desktop]]）, tab, page, グループ, セクション以外

### 🪦 unassigned — 退役キー（t-6rbc）
§G の「迷子受け皿 section」（`unassigned = true` マーカー）だった。**死語**。
受け皿が集める leftover は [[迷子 (orphan)]] であり、**facet は迷子を作れなかった** ⇒
この section は**永久に空**＝UI が持たないものを持つと言っていた。

⚠️ **単に消すのではなく「退役キー」として loud reject する**。unknown key は decode で
**無視**されるので、キーだけ消すと **その section が普通の workspace セルに黙って昇格** →
**workspace が 1 個増えて layout が黙って変わる**（`workspaceSubstrateSections` が受け皿を
substrate から除外していた、その filter が消えるため）。だから **行ごと DROP** する ——
実効の substrate は今日と同一のまま、概念だけが消える。**沈黙こそが最悪**の答えになる箇所。
- 挙動: `DesktopSection.parse` が `(nil, "…retired…")` を返す → 行が落ちる →
  `ConfigDiagnostic(.error)` → `config --validate` が **exit 1**（schema 側も
  `additionalProperties:false` で unknown key として二重に捕まえる）。daemon は
  従来どおり**寛容**（ログして起動する）
- **auto-promote ゾンビも封じた**: snapshot writer の `unassigned` 書き出し経路
  （退役キーが自分で蘇る唯一の道）を削除
- **Don't call it:** lost & found, catch-all filter, leftover bucket, ゴミ箱 —— 全部無い

### facet section
全 [[section]] を **1始まりの tree index か label で指す統一アドレッシング CLI**。
`--focus N|LABEL` で activate（workspace 切替。[[isolate desktop]] 上では合成 section の
先頭窓 focus）、`--rename N "label"` で表示 label を runtime 変更（workspace は catalog 名。
**[[isolate desktop]] の `matched` section は desktop 自体を改名**＝`[desktop.N] label`・t-j7ps。
`--match` が中身を retarget して永続する以上、名前だけ固定だと**中身について嘘をつく**ので
その対称形。**ordinal-keyed**〔id は `section:0:<label>` で config label を焼き込んでいるので
id-keyed だと rename が**自分の鍵を動かして**消える〕・`[config] export-path` があれば
`--match` と同条件で snapshot 永続。`holding` section は **loud reject**＝match の補集合から
合成され、書き込み先の config キーが無い。空 label は revert・relaunch で reset・
`facet reload` では消えない）、
`--match N "expr"` で [[isolate desktop]] の `match` を runtime retarget（session-only・
[[facet filter]] 式・空で config へ revert）。GUI twin = tree ヘッダ右クリック →
Section ▸ Rename / Edit match。
- CLI: `facet section --focus N|LABEL` / `--rename N "label"` / `--match N "expr"`
- コード: `addressableSections()` / `dispatchSectionFocus` / `renameSection(indexN1Based:to:)` /
  `applyLabelOverrides` / `Controller.sectionLabelOverride`（`FacetApp`）
- **Don't call it:** workspace --focus（旧 per-kind verb・section が統一層）, lens 切替専用（🪦退役）,
  group --focus

### rule
`[[rule]]` adopt-rule（#282/#286 Phase 3）＝**新規窓**が [[match]]（[[facet filter]] の WHERE
式）に当たると、その窓の adopt 時に [[apply]] facet を設定する宣言的ルール。グローバル（全
mac desktop・per-desktop でない）で、宣言順に評価し窓は当たった**全 rule** の apply を累積
（`setWorkspace` は単数値 auto-replace で last-wins）。#191 で撤去された `[[assign]]` の宣言的
後継を [[facet filter]] 言語で復活させたもの。consumer は facet が窓を adopt した**直後**
（classify gate の**外**・reconcile 後）に評価する＝malformed [[match]] が role-auto-float を
乱せない（その rule のみ loud かつ **non-fatal** で skip・他は走る・sheet/dialog は必ず
float）。wire は兄弟の top-level
matcher [[exclude]] に倣う **flat キー**（`match` + `workspace`/`tags`/`floating`/`sticky`/
`master`）＝[[apply]] と同じ `ApplyOp` 語彙だが nested table でなく flat（厳格 schema で typo
検知・sill `ConfigSchema` に nested-object field 型が無いため）。
- コード: `Rule` / `FacetConfig.rules` / `FacetConfig.decodeRuleSections` /
  `effectiveRules`（`FacetCore`）
- **Don't call it:** assign（旧称・#191 で撤去）, exclude（[[exclude]] は管理可否の**分類**＝別軸）,
  trigger, hook, automation, ルール以外

### match
[[isolate desktop]] / [[rule]] が共有する **述語キー**＝当たった窓を isolate desktop がタイル
（rule では apply 対象に）する [[facet filter]] の WHERE 式。`facet section --match` の
runtime 値も同じ。config には**文字列のまま**格納し、consumer 側で compile（parse error は
caret 付き loud かつ **non-fatal**＝該当面は show-all へ degrade）。rule では `match` / [[apply]]
が match に当たる窓へ apply を効かせる**対のキー**。
- コード: isolate desktop の `match`（`desktopIsolate`）/ `Rule.match`（生文字列）→
  `FacetFilter.parse`（consumer）
- **Don't call it:** filter, where, query, predicate（式言語そのものは [[facet filter]]）,
  マッチ条件, 絞り込み

### apply
[[rule]] の **[[match]] の逆写像**＝[[match]] に当たった**新規窓**へ adopt 時に設定する
facet 群（旧 `onDrop` の改称）。型付き `ApplyOp`（`addTag` / `setFloating` / `setSticky` /
`setMaster` / `setWorkspace`）のリスト。frozen セマンティクス: `addTag`=additive（冪等）/
`setWorkspace`=単数値 auto-replace（last-wins）。wire は flat キー（`[[rule]]` の
`workspace` / `tags` / `floating` / `sticky` / `master`）＝兄弟 [[exclude]] に倣う
（厳格 schema で typo 検知）。かつて `type="lens"` section の drop 副作用（drop で tag 付与・
move-out で反転）が同じ `ApplyOp` を使ったが、section-lens 退役（t-ec9s）でその DnD 経路は
無くなり、apply は今や `[[rule]]` の adopt-time 設定のみ。tree DnD は ws→ws のメンバー
付け替え（＝`setWorkspace`）と受け皿からの rescue に単純化された。
- コード: `ApplyOp` / `ApplyOp.list(from:)`（`FacetCore`）/
  `NativeAdapter.setFloating`/`setSticky`/`setMaster` / `Controller.applyAdd`
- **Don't call it:** onDrop, onGroupChange, action, ハンドラ, 副作用

---

## 設定 / Theme

### `config.toml`
リポジトリルートの `config.toml` が **source-of-truth テンプレート**。
ユーザーは `curl` して `~/.config/facet/config.toml` に置く。app は読むだけ
（書かない / 自動生成しない / 永続化しない）。唯一の例外＝startup `auto-promote`
（t-hdxb・opt-in）: `[config] auto-promote = true` ＋ `export-path` 設定時のみ、
次回起動で config.toml より新しい snapshot を promote（overwrite + load）する
＝唯一の sanctioned write（詳細は CLAUDE.md `### Configuration`）。memory
`[[config-default-behavior]]`。
- **Don't call it:** settings, preferences, user config, 設定ファイル（一般指示語）

### effective accessors
`FacetConfig` の `effective*` プロパティ。out-of-range / unknown 値を
**default に clamp** して返す。raw Optional は読まずに必ずこちらを通す。
- **Don't call it:** safe getters, validated accessors, バリデート getter

### `pal` (palette)
sill の PaletteKit が公開する **`@MainActor` module-level var**
（`ResolvedPalette`）。`Sources/FacetView/Palette.swift` が `@_exported
import` で再公開し、view ファイルが `pal.foreground` / `pal.muted` /
`pal.primary` などを直接参照する。**`pal` という変数名は改名しない**
（view 側 ~数百箇所の変更を引き起こすが behavior 利得ゼロ）。ロール名は
Phase V で Tailwind 風にリネーム（`text→foreground` / `dim→muted` /
`accent→primary` / `accent2→secondary` …）。
- preset: `ThemeSpec` の `.terminal` / `.dracula` / `.system` … は純粋
  `Sendable`（UInt32 hex）。`@MainActor` 制約は解決後の `ResolvedPalette`
  / `resolve(_:)` 側（`NSColor` が Sendable でないため）。
- **Don't call it:** theme.current, currentPalette, theme, テーマ

---

## ログ / 観測

### `Log.line`
**常時 ON** のログ関数。end-user 向けの operational event（AX focus
mismatch 等）を出す用途。
- **Don't call it:** info log, always-on log, 通常ログ

### `Log.debug`
**`debugMode` global で gate**（`FACET_DEBUG` 環境変数の設定時のみ）。
Controller / Adapter / EventSource の hot path で気軽に使う。
- 出力先: `/tmp/facet.log` 常時 + `FACET_DEBUG` 時のみ stderr ミラー
- **Don't call it:** verbose log, trace log, 詳細ログ

### `FlippedClipView`
day-one から使う `NSClipView` 派生。非 flipped を使うと grip-drag が
散発的に失敗する（memory `[[grid-branch-grip-intermittent]]`）。**初日から
全 scroll view に投入**。
- **Don't call it:** custom clip view, fixed clip view, クリップビュー

### drag-state lifecycle
drag 状態は **backend round-trip 完了で clear**（`mouseUp` で clear しない）。
- **Don't call it:** mouse drag flag, drag state, ドラッグ状態（一般語として
  はあえて避ける）

---

## バンドル / 配布

### bundle id `com.facet.app`
TCC grant と self-signed cert identity の鍵。**変えない**（M2 で確定）。
- 設定: [`package.sh`](../package.sh)
- **Don't call it:** app identifier, app id, バンドル ID

### sole backend (`rift` 廃止)
v2.0.0 で旧 `rift` adapter を retire し、`FacetAdapterNative` が唯一の
backend に。Phase ε で完了。新規 adapter を足す場合も view 側変更不要
（`WindowBackend` port 経由のため）。
- **Don't call it:** legacy backend, primary backend, メイン backend

---

## エントリ追加時のルール

- 1 つの概念につき正規名は 1 つ。複数の呼び方が流通しているなら、
  このファイルで勝者を選び、敗者は `Don't call it:` 行に並べる。
- 正規名は **英語のまま** 書く。コード識別子（`FacetCore`, `pal`,
  `[[desktop.N.section]]`）はその表記を維持する。
- 定義は **1〜2 文** に収める。動作の詳細は設定セクションやソース
  ファイルへリンクし、ここで説明し直さない。
- 用語が CLI surface / DNC / config に表面化する場合は CLI フラグ名を
  必ず併記する。
