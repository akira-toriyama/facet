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
（`FacetCore`, `WindowBackend`, `[desktop.N]`, `pal` など）と一対一に対応
させるため。日本語化するのは説明文だけ。

なお **似て紛れやすい 4 概念** は最優先で区別する（下の「4 つの中核概念」を
参照）。とくに **mac desktop**（OS の native Space）と **facet workspace**
（facet 独自の抽象）は語感が近く混同の温床なので、コード識別子・設定キー・
コメントすべてで綴り分ける。

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
    CTRL["Controller"]
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
    THEME["Theme.pal (palette)"]
  end
  subgraph APP["FacetApp — @main + CLI"]
    MAIN["FacetApp.Main"]
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
- 含むもの: `Models`, `WindowBackend` protocol, `Controller`, `FacetConfig`, `Log`
- **Don't call it:** domain layer, business logic, model layer, ドメイン層

### FacetAdapterNative
**唯一の backend adapter**（v2.0.0 で `rift` 廃止）。AX / CGS / SkyLight
プライベート API への入口。バックエンド固有の型は **この中に閉じ込める**。
- 場所: [`Sources/FacetAdapterNative/`](../Sources/FacetAdapterNative/)
- **Don't call it:** native backend, ax adapter, アダプタレイヤー（一般化したい時のみ）

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
Core と Adapter の間の **唯一の seam**（hexagonal port）。Controller / View
が見るのはこの protocol のみ。
- 定義: [`Sources/FacetCore/`](../Sources/FacetCore/) 内
- **Don't call it:** adapter protocol, backend interface, バックエンド契約

---

## ドメインモデル

### 4 つの中核概念（最優先で区別する）

似た語が複数の意味で流通していた歴史があるため、まずこの 4 つを綴り分ける。

| 正規名 | 意味 | コード / 設定での所在 |
|---|---|---|
| **mac desktop** | macOS の native Space（OS の仮想デスクトップ。Mission Control の "Desktop N"） | `MacDesktops`, `activeMacDesktopID`, `[desktop.N]` |
| **facet workspace** | facet 独自の window グループ抽象（1 mac desktop に N 個） | `WorkspaceCatalog`, `workspaces()` |
| **facet view** | ユーザー向け UI surface の種類（`tree` / `grid` / `rail`） | `--view NAME`, `FacetView*`, `canonicalViews` |
| **lens** | tag モードで「今見えているタグ集合」（M11-3・#176 で実装済） | `facet lens`, `WorkspaceCatalog.lensOnly` / `lensToggled` |

**mac desktop ↔ facet workspace は最重要の混同ポイント**。OS のデスクトップ
（mac desktop）と facet の抽象（facet workspace）は別物で、1 mac desktop が
複数の facet workspace を抱える（[[per-mac-desktop workspaces]]）。M11-2 で
両者を 1:1 にする予定だが、それは**実装上の関係**であって、概念としては
区別し続ける。**facet view ↔ lens** も直交軸（"どう見せるか" × "どのタグ集合
を見るか"）として分ける。

### mac desktop
macOS の **native Space**（OS が提供する仮想デスクトップ。Mission Control が
"Desktop 1" / "Desktop 2" … と表示するもの）。facet はこれを **read-only** に
しか触らない（別 mac desktop への window 移動は SIP-off が要るので非対応）。
- コード: `MacDesktops`（in `FacetAccessibility`・SkyLight 経由の read-only
  クエリ）, `NativeAdapter.activeMacDesktopID`
- 設定: `[desktop.N]` キー（Mission Control 順の ordinal で指定）
- UI: tree の上部ハンドル帯に "Desktop N"（macOS の呼称に合わせた表示ラベル）
- **Don't call it:** Space, native Space, workspace, virtual desktop（facet
  workspace と紛れる）, デスクトップ別
  - ※ Apple の API 名（`SLSGetActiveSpace`, `NSWorkspace.activeSpaceDidChange`,
    SLS の `"Spaces"` dict キー等）は Apple の語のまま残す。"mac desktop" に
    綴り替えるのは facet 自身の surface だけ。

### facet workspace
**facet が定義する Window 集合**。タブのようにグループ化された window 群を
1 まとまりとして扱う単位。1 つの [[mac desktop]] が複数の facet workspace を
持つ。
- コード: `WorkspaceCatalog` / `workspaces()`
- **Don't call it:** group, tab, page, desktop, mac desktop, Space, グループ, タブ

### per-mac-desktop workspaces
各 [[mac desktop]]（native Space）ごとに **独立した `WorkspaceCatalog`** を
持つ機能。`NativeAdapter` は active な mac desktop id でカタログを park / swap
する。SkyLight は **read-only** 利用（書き込みは SIP-off 必要）。SkyLight
未利用環境では `activeMacDesktopID == 0` で 1 つの shared catalog に縮退
（pre-feature 挙動）。
- 設定: `[desktop.N]` キー（ordinal で指定）
- コード: `MacDesktops`（in `FacetAccessibility`）, `FacetConfig.isMacDesktopManaged`
- **Don't call it:** per-native-Space workspaces（コメント / メモリでは旧称が
  残る）, virtual desktop workspace, multi-desktop, デスクトップ別

### facet view
ユーザー向け UI surface の種類。`tree` / `grid` / `rail` が正規名（`canonicalViews`）。
新規 view 追加時は `Main.canonicalViews` + `Controller.dispatchView/Hide/Toggle`
の case を増やすだけで済むよう **per-view 専用フラグを作らない**。`--view`
（どう見せるか）は [[lens]]（どのタグ集合を見るか）と直交する別軸。
- CLI: `--view NAME` / `--hide NAME` / `--toggle NAME`
- **Don't call it:** mode, panel, window, lens（lens は表示中タグ集合の別概念）,
  モード, ペイン

### lens
tag モードで **「今見えているタグ集合」**（dwm の tagset 相当）。`facet view`
が "どう見せるか" なのに対し lens は "どのタグ集合を見るか"＝直交する別軸。
**M11-3 (tag モデル) で #176 にて実装済**（`WorkspaceCatalog.lensOnly` /
`lensAdded` / `lensRemoved` / `lensToggled`）。memory `[[facet-tag-model-decisions]]`。
- CLI: `facet lens --only/--add/--remove/--toggle A[,B,…] / --all`。
  複数タグは**カンマ結合**（空白 variadic ではない＝#227 の per-flag arity 1 を維持・
  `,`/`:` は名前の禁止文字で wire 形が無曖昧）。名前解決は **strict**＝未定義タグが
  1 つでもあれば lens 不変で `lastError`（silent-drop しない）。user verb は user bit
  のみ操作し、lens が空になったら **floor（`_default`）= untagged baseline** へ
  フォールバック（`--all`=`lensAll` とは別状態）。read は `facet query --lens`（#228 PR-1）。
- **Don't call it:** view（facet view は UI surface の別概念）, tagset, filter,
  タグビュー

### tree view
左サイドバーに表示する **[[facet workspace]] の階層リスト**。`SidebarView` がレンダリング。
- コード: `SidebarView`
- **Don't call it:** sidebar, outline, list, サイドバー（描画される場所を指す時のみ別）

### grid view
全画面の **window グリッド overlay**。`--view grid` で起動。常に key/active
（construction 上）なので `--active` 修飾子は無視される。
- **Don't call it:** mosaic, overview, expose, モザイク, グリッド表示

### rail view
全画面の **[[facet workspace]] overview**（Mission Control 風）の **active 中央
カルーセル switcher**（2-b）。`--view rail` で召喚。中央 HERO に下見中 WS を大表示、
いずれかの画面 **[[edge]]** に WS の window サムネミニ画面を 1 列（strip）に並べ、
**active を strip 中央に固定**・前後を循環で配置。strip 軸の矢印で **strip が回転**
（中央＝選択／下見のみ・hero が追従）・Return/クリックで切替＆閉じ・Esc で閉じ・
window を WS 間 drag / header drag で swap。WS が `[rail] cells` 数を超えると縮小せず
**回転**（両端 peek で「まだある」合図）。tree / grid とは役割が違う（速い切替・俯瞰）。
既定 view にはできない（`effectiveDefaultView` は tree / grid のみ受理）。#109 shipped →
M9-3/M9-4 で edge 化 → **2-b でカルーセル化（M9-4 の scroll を置換）**。
- コード: `RailView`（`FacetViewRail`）/ `railBands`・`railCarouselOffsets`（`FacetCore`、純幾何）
- **Don't call it:** switcher, expose, mission control, スイッチャー, ミッションコントロール, scroll bar

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
[[rail view]] の中央に大きく表示する **下見中（strip 中央）の [[facet workspace]]
プレビュー**。実画面の縦横比そのままに縮小したミニ画面で、[[strip]] が占めない
残り領域を埋める（`[rail] strip`% の裏返し）。strip の回転（[[carousel]]）で中央
WS が変わると hero が追従する。
- コード: `RailView.hero` / `railBands`（hero 領域）
- 参照: [[strip]] / [[carousel]] / [[rail view]]
- **Don't call it:** preview, main, focus, big cell, spotlight, 主画面, プレビュー

### carousel
[[rail view]] の [[strip]] の並べ方（2-b）。**active（＝選択）を strip 中央に固定**
し、残りを前後へ**循環**配置する。strip 軸の矢印で strip 自体が回転して中央＝
選択が変わり（下見のみ・[[hero]] が追従）、Return / クリックで確定＆閉じる。
`[rail] cells` 上限を超える WS は縮小せず回転で送り、両端に **peek**（次セルの
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
  **枠線無し・斜体（oblique）の "sticky" テキストバッジ**（accent2・pill
  枠無し・`.obliqueness` で傾き。旧 📌 絵文字を廃止）。
- UI: tree の右クリック / `m`（--active）コンテキストメニューに **"Sticky"**
  （非 sticky 窓）/ **"Unstick"**（sticky 窓）項目。sticky 窓は floating で
  float-exit=sticky-exit ゆえ "Unfloat" は出さず "Unstick" 一本に集約。
- **Don't call it:** always-on-top, pin, float, 常駐ウィンドウ, scratchpad
  （scratchpad は「名前付きの隠し棚から今の WS に呼ぶ」別機能）

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
  （settled）の窓は tree に `scratchpad:NAME` の **dim 枠線 pill バッジ**。
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

### grouping
**1 つの [[mac desktop]] 内で window をどう束ねるかを決めるモード**。`config.toml`
`[grouping] by = "workspace" | "tag"` で **起動時に択一**（静的・再起動で変更・動的変更不可）。
- **by=workspace**: 1 mac desktop : N [[facet workspace]]（**1:n**）。1 window = 1 workspace。
  facet workspace 切替で非表示 WS の窓を [[anchor]] park。＝現状モデル（[[per-mac-desktop workspaces]]）。
- **by=tag**: 1 mac desktop : 1 [[tag world]]（**1:1**）。1 window = N [[tag]]（多重所属）。
  [[lens]] で表示タグ集合を選び、外れた窓を [[anchor]] park。
- **両モードとも hide = [[anchor]]**（窓を mac desktop に composited のまま残す＝hover/hero preview 温存）。
  別 mac desktop への退避や order-out は窓を非 composited にして preview を殺すため **不採用**
  （memory `[[native-window-hide-methods]]` の hide×hero 実測）。
- layout は grouping で互換 filter（master-left/master-right/master-top/master-bottom/master-center/grid/spiral/float = 両対応 / bsp・stack = workspace のみ・
  非互換は起動時 `exit 2`）。M11-3 (#176) で実装済・`by` はオープン enum（将来の編成パラダイムを 1 値で拡張）。
  memory `[[facet-tag-model-decisions]]`。
- **Don't call it:** mode, layout mode, grouping policy, 編成モード, グルーピング

### tag
**window に付く可視性ラベル**（[[grouping]] `by=tag` 時のみ）。1 window = タグの集合（bitmask /
OptionSet 的・多重所属）。可視性述語 = `window.tags ∩ [[lens]] ≠ ∅`（dwm `tags & viewmask` 直写し）。
`config.toml` の `[[tag]]` は **起動時の語彙 seed のみ**（記載順がタグ順＝bit 順・行ごとのチップ表示順。
tag モードの [[tree]] はタグで grouping せず **flat な窓リスト**で、各行に全タグを `#tag` チップ表示）。**割当は runtime**：
新規窓は現 [[lens]] の primary タグ（lens 最下位 bit）を継ぐだけで、`facet window --tag/--untag/--toggle-tag/--retag` と
`facet tag --add/--remove/--rename` で窓・語彙を動的編集（session-only）。GUI は flat [[tree]] 行の右クリック /
`m` メニューの「Tag」→ **per-window タグ編集チェックリスト**（付与/解除トグル・`+ Create` で auto-vivify＋付与・#4）。
語彙そのものの add/rename/delete は `t` の [[tag 管理モード]]（#4 follow-up）。**静的 `[[assign]]` は #191 で廃止**
（runtime タグ付けが置換）。**M11-3 (#176) で実装・#191 で runtime 動的化**。
memory `[[facet-tag-model-decisions]]`。
- **3 つの「add a tag」を混同しない**（用語規則）：`facet tag --add` = **語彙**にタグを定義（窓は触らない）／
  `facet window --tag` = **窓**にタグを付ける（未定義なら auto-vivify）／`facet lens --only/--add/--remove/--toggle` = **表示集合**を変える
  （窓も語彙も不変・複数タグはカンマ結合・strict 解決）。`facet window --retag OLD NEW`（#228）は **窓**の OLD を NEW に**原子的に置換**
  （`(tags & ~oldBit) | newBit | floor` を 1 回書き込み・OLD は Strict-A で要定義・NEW は auto-vivify・`OLD==NEW` は no-op）。
- **`_default`（システム予約）**: 全 tag モード窓が常に持つ floor bit（bit63）。`tags==0`（迷子）を無くすための
  内部マーカーで、`[[tag]]` 名にできず・チップ非表示・`lens --all` の user-tag union にも入らない（floor は別途 OR）。
- **Don't call it:** label, category, workspace（tag は多重所属、workspace は 1 窓 1 個）, group, ラベル, カテゴリ

### tag world
**[[grouping]] `by=tag` 時、1 つの [[mac desktop]] が持つ「タグ付き window の集合」**
（mac desktop : tag world = **1:1**・per-mac-desktop で独立した世界）。by=workspace の「N [[facet workspace]]」
層を置き換える単位＝by=tag は 1 desktop に 1 tag world。中で [[lens]] を [[anchor]] park で切替
（intra-desktop・mac desktop 切替ではない＝preview 温存）。**M11-3 (#176) で実装済**。
- **Don't call it:** workspace, tagspace, tag group, タグ空間, tagset（tagset は [[lens]] 寄り）

### tag 管理モード
**タグの語彙（vocabulary）そのものを編集する [[tree]] パネルの keyboard モード**
（`--active` で `t`・[[grouping]] `by=tag` 時のみ）。`s`（検索モード）の双子＝窓に
紐づかない panel レベルのモードで、tree パネル基準に出るフローティングパネル。#4 の
per-window タグ編集チェックリスト（窓へのタグ付与/解除）とは**別レイヤ**：こちらは
窓に紐づかず **add / rename / delete** を行う（`facet tag --add/--remove/--rename`
の GUI 等価）。#4 の `TagEditPanel` UI を流用した "manage" 変種：ヘッダ「Tags」・行は
タグ名のみ（チェックボックス無し）・`+ Create` で語彙宣言・タグ選択 → **Enter /
右クリック** → `PopupMenu` [Rename, Delete]（rename はフィルタ欄インライン編集・
delete は "everywhere?" 確認）。`m` はトリガー不可（フィルタ欄が letter を食う）。
- コード: `enterTagManage`（`Controller+ActiveMode`）/ `TagEditPanel.showManage`（`FacetView`）
- ⚠ **[[tag]] mode とは別物**：「tag mode」は `by=tag` グルーピング自体を指す既存語。
- **Don't call it:** tag mode, タグモード, vocab editor（コード外）, label manager

### grouping の概念関係（by=workspace / by=tag）
[[grouping]] は同じ [[mac desktop]] 上の window を **workspace 束ね**（1:n）か **tag 束ね**（1:1 tag world）
かに切り替える、facet の編成軸。[[facet view]] のうち **tree はどちらの束ね方も描画**（grouping 非依存）だが、
**grid / rail は workspace 専用**＝by=tag では使えない（`--view`/`--hide`/`--toggle`＝grid|rail と
`default-view="grid"` は **exit 2**・#191 PR-5）。hide は両モードとも [[anchor]]（窓を mac desktop に
composited のまま残し preview を温存。別 desktop 退避 / order-out は preview を殺すので不採用）。

```mermaid
flowchart TB
  MD["mac desktop<br/>(native Space・read-only)"]
  MD -->|"by=workspace (1:n)"| WS["N × facet workspace<br/>1窓 = 1 workspace"]
  MD -->|"by=tag (1:1)"| TW["1 × tag world<br/>1窓 = N tag・lens で表示集合を選択"]
  WS -->|"workspace 切替"| HW["hide = anchor<br/>(窓は composited のまま → preview ◯)"]
  TW -->|"lens 切替"| HT["hide = anchor<br/>(同上・intra-desktop)"]
  VIEW["facet view: tree / grid / rail<br/>(UI surface)"]
  VIEW -. "tree / grid / rail" .-> WS
  VIEW -. "tree のみ（grid/rail は ws 専用）" .-> TW
```

---

## CLI / IPC

### DNC (Distributed Notification)
プロセス間 IPC の通り道。`facet --view tree` のような CLI 呼び出しは
`com.facet.app` 宛の Distributed Notification として届く。
- **Don't call it:** ipc message, event, distributed event, IPC イベント

### `--active` modifier
view を出す動作の **修飾子**（verb ではない）。`--view tree` と組合せた時のみ
意味を持ち、key focus を即時奪う（+ activation policy フリップ）。[[grid view]]
では無視。
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
`facet query --tags` / `--lens`（#228）は tag 世界を JSON で露出する：`--tags` は
定義済みタグ語彙（宣言順の配列・workspace モードでは `[]`）、`--lens` は現
[[lens]]（`{"tags":[…],"showsAll":bool}`・tag モード外は `null`）。`showsAll` は
全窓表示の lens（floor-only / `--all`）を `tags` が空でも機械判別可能にする。
projection flag は 1 回につき 1 つだけ（`--windows`/`--tags`/`--lens` の複数併用は
exit 2）。query は read-only なので **mode 寛容**（tag verb と違い `requireGrouping`
ゲートなし）。**`facet lens --only/--add/--remove/--toggle/--all` がタグ表示集合を
変える write verb なのに対し、`query --lens` はその集合を読むだけ**（read ↔ write の別物）。
- コード: `runQuery`/`runQueryWindows`/`runQueryTags`/`runQueryLens`（`FacetApp`）/
  `StatusSnapshot`・`LensStatus`・`WindowQueryEntry`/`WindowQuery`（`FacetCore`）/
  `definedTagNames()`/`currentLens()`/`queryEntries()`（backend）
- **Don't call it:** status, facet status, state dump, info コマンド

### CLI 文法（`--flag VALUE`）
全コマンドが **yabai 式の空白区切り**（`--flag VALUE`）。`--flag=VALUE`（`=`）は
#227 で全廃（hard cutover・後方互換なし）。各 flag は arity を宣言し、値トークンを
無条件に食う（**strict consumption**・lookahead ゼロ）ので負座標 `--pos-x -1440` も
そのまま読める。文法は CLI パーサー層（`Main.swift` / `FacetApp+Client.swift` の
`ArgCursor`）に隔離され、コアへ渡る DNC 制御文字列（`view:tree+active` 等）は不変。
- **Don't call it:** equals syntax, `--flag=value`, GNU-style options

---

## 設定 / Theme

### `config.toml`
リポジトリルートの `config.toml` が **source-of-truth テンプレート**。
ユーザーは `curl` して `~/.config/facet/config.toml` に置く。app は読むだけ
（書かない / 自動生成しない / 永続化しない）。memory `[[config-default-behavior]]`。
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
  `[desktop.N]`）はその表記を維持する。
- 定義は **1〜2 文** に収める。動作の詳細は設定セクションやソース
  ファイルへリンクし、ここで説明し直さない。
- 用語が CLI surface / DNC / config に表面化する場合は CLI フラグ名を
  必ず併記する。
