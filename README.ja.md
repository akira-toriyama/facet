# facet

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![status](https://img.shields.io/badge/status-alpha-orange)

[English](README.md) · **日本語**

macOS 向け Swift 製ワークスペース + ウィンドウマネージャ。 同じ
ワークスペースモデルを **複数の view から切り替えて見る**
（半透明ツリーサイドバー、 フルスクリーンオーバービュー、
将来の dock / hover / palette 等）。 backend は AX/CGS を直接叩く
native 実装、 外部依存なし。 レイヤー図は
[docs/architecture.md](docs/architecture.md)。

## 何ができるか

facet は menu-bar-less な agent (`LSUIElement`) として常駐し、
ワークスペースを view で見せる。 view は tree / grid / rail の
いずれもオンデマンドで召喚する (`facet --view tree|grid|rail`):

- **Tree** — 半透明・常時最前面のサイドバー。 各ワークスペースと
  その windows をツリー表示。 行クリックで focus、 window 行ドラッグで
  window を別 ws に移動、 ワークスペース header (左にグリップ) ドラッグ
  で 2 つのワークスペースの中身を swap、 ホバーで実画面プレビュー。
- **Grid** — フルスクリーンのオーバービュー。 1 セル =
  1 ワークスペース、 ScreenCaptureKit のリアルサムネイル、 セル間 DnD:
  window サムネイルドラッグで移動、 セル header ドラッグでセル丸ごと
  swap。 必要時に `facet --view grid` で呼び出し、 Esc / 背景クリック
  で閉じる。
- **Rail** — フルスクリーンの Mission Control 風ワークスペース
  **スイッチャー**。 window サムネのミニ画面を画面のいずれかの辺に strip
  として並べた **active 中央カルーセル**で、 下見中の WS を中央に大きく表示。
  active を strip 中央に固定し前後を循環配置。 browse の矢印（上下辺＝←/→、
  左右辺＝↑/↓）で **strip が回転**して別 WS を中央へ、 Return / クリックで
  中央の WS に切替＋閉じ、 Esc で閉じる。 window を ws 間ドラッグ / header
  ドラッグで swap。 `--edge top|bottom|left|right` で辺を選ぶ（既定 bottom）。
  サムネは strip を埋めるよう justify され（均等な隙間）、 そのサイズ上限を
  `[rail] strip`（画面短辺に対する % — hero が残りを占める）が決める。 画面の
  向き・サイズが変わっても比は保たれる。 `[rail] cells` は同時表示数の上限で、
  超えた WS は回転（両端 peek 付き）。 `facet --view rail` で呼び出す。

DnD は各 view 共通のモデル — **掴んだ対象が動作を決める**: window を
掴めば移動、 ワークスペース header を掴めば 2 ワークスペースの中身を
swap (ワークスペースの枠自体は動かないので hotkey 番号は不変)。 修飾
キーは使わない。

各 view は同じ backend と同じテーマ (terminal / chomp / rainbow /
dracula / github-dark / catppuccin-mocha … 全13テーマ + `random`、ライブ切替) を共有。

## レイアウト

各ワークスペースは 1 つのレイアウトで動作し、 実行時に
`facet workspace --layout NAME` で切り替える (per-WS、 永続化しない —
起動時の layout は [`config.toml`](config.toml) の `[[desktop.N.section]]`
ブロック (`type = "workspace"` + `layout = "bsp"`) で指定)。 facet
は window を隠さないので、 レイアウトは window を*配置*するだけで、
focus 中の window は常に前面に来る。 図は 4 window 想定、 **1** が
master / focus。

master は 5 つの辺のどこにでも置ける — `--layout master-EDGE` で
直接選ぶ。 5 つは 1 つの幾何を共有し (対辺どうしは鏡像)、 master が
どの辺に付くかだけが違う。

### `master-left` — master を左に
dwm `tile` / xmonad `Tall`。 master が左カラム (幅の可変割合) を占め、
残りが右に行で積まれる。 ウルトラワイドの定番。

```
┌────────────┬───────────┐
│            │     2     │
│            ├───────────┤
│     1      │     3     │
│  (master)  ├───────────┤
│            │     4     │
└────────────┴───────────┘
```

### `master-right` — master を右に
`master-left` の鏡像: master が右カラム、 stack が左に行で積まれる。

```
┌───────────┬────────────┐
│     2     │            │
├───────────┤            │
│     3     │     1      │
├───────────┤  (master)  │
│     4     │            │
└───────────┴────────────┘
```

### `master-top` — master を上に
`master-left` を 90° 回転: master が上の行、 残りが下のカラムになる。

```
┌─────────────────────────┐
│        1 (master)       │
├───────┬───────┬─────────┤
│   2   │   3   │    4    │
└───────┴───────┴─────────┘
```

### `master-bottom` — master を下に
`master-top` の鏡像: master が下の行、 stack が上のカラムになる。

```
┌───────┬───────┬─────────┐
│   2   │   3   │    4    │
├───────┴───────┴─────────┤
│        1 (master)       │
└─────────────────────────┘
```

### `master-center` — master を中央に
dwm `centeredmaster` / xmonad ThreeColMid。 master を中央に、 残りを
左右のサイドカラムに分配 (右から埋まる)。 ウルトラワイド向け。

```
┌───────┬───────────────┬───────┐
│       │               │   2   │
│   4   │   1 (master)  ├───────┤
│       │               │   3   │
└───────┴───────────────┴───────┘
```

### `grid` — 均等タイル
awesome `grid`。 ほぼ正方の格子 (`ceil(√N)` 列)、 最終行は幅いっぱいに
広がる。

```
 2 window          3 window           4 window
┌─────┬─────┐    ┌─────┬─────┐      ┌─────┬─────┐
│  1  │  2  │    │  1  │  2  │      │  1  │  2  │
└─────┴─────┘    ├─────┴─────┤      ├─────┼─────┤
                 │     3     │      │  3  │  4  │
                 └───────────┘      └─────┴─────┘
```

### `spiral` — フィボナッチ
dwm `fibonacci`。 新しい window が残り空間を半分にしながら時計回りに
内へ巻いていく。

```
┌────────────┬───────────┐
│            │     2     │
│     1      ├─────┬─────┤
│            │  4  │  3  │
└────────────┴─────┴─────┘
```

### `bsp` — 二分割
bspwm 流。 新しい window が focus 中のタイルを半分に割る (アスペクトで
自動バランス)。 `--toggle-orientation` で focus 中の split を回転。

```
┌────────────┬───────────┐
│            │     2     │
│     1      ├─────┬─────┤
│            │  3  │  4  │
└────────────┴─────┴─────┘
```

### `stack` — 全画面フォーカス
1 window が画面いっぱい、 残りは画面外に park。
`--cycle-stack next|prev` で前面の window を巡回。

```
┌─────────────────────────┐    他 (2, 3, 4) は画面外に park。
│                         │    cycle-stack で次を前面に。
│       1  (front)        │
│                         │
└─────────────────────────┘
```

`float` (デフォルト) はレイアウトを適用しない — window は置いた位置に
留まる。

### master-stack の操作

`master-*` レイアウトは実行時に調整できる (per-WS)。 focus 中の
window を master スロットへ **昇格**:

```
  before (3 を focus)         after --promote (menu)
┌────────────┬───────┐      ┌────────────┬───────┐
│            │   2   │      │            │   1   │
│     1      ├───────┤  →   │     3      ├───────┤
│  (master)  │   3   │      │  (master)  │   2   │
└────────────┴───────┘      └────────────┴───────┘
```

master の **リサイズ** (`--grow-master` / `--shrink-master`、 ±0.05) と
**枚数変更** (`--inc-master` / `--dec-master`):

```
  --grow-master              --inc-master (2 masters)
┌──────────────┬─────┐      ┌────────────┬───────────┐
│              │  2  │      │     1      │     3     │
│      1       ├─────┤  →   │  (master)  ├───────────┤
│   (master)   │  3  │      │     2      │     4     │
└──────────────┴─────┘      │  (master)  │           │
                            └────────────┴───────────┘
```

## 操作

| 操作 | 結果 |
|---|---|
| window 行クリック (tree) | そのワークスペースに切替 + その window に focus |
| window を隠す (⌘H / ⌘M) | タイルしてた隣の window が空き枠を埋める。 隠れた window は tree に薄く `hidden` バッジ付きで残る — 行クリックで復帰 |
| ワークスペース header クリック (tree) | そのワークスペースに切替 |
| window 行を別ワークスペースにドラッグ (tree) | その window を裏で移動 — 切替なし・focus 不動 |
| ワークスペース header を別 header にドラッグ (tree) | 2 ワークスペースの中身を swap |
| 空白部分ドラッグ、 または ⌘+ドラッグ (tree) | パネル位置を変更 (session 限り — 固定は `[tree]` geometry を config に書く) |
| パネルヘッダをダブルクリック (tree) | 位置・サイズを `[tree]` config geometry (未設定なら既定) にリセット |
| 右クリック (tree) | 対象別コンテキストメニュー: window 行 → アクション ・ workspace header → layout 切替 ・「Desktop N」バンド → Search (`s` モード) |
| window 行ホバー (tree) | ライブプレビュー — デフォルトは row 横の小型ポップオーバー。 `[tree] preview-mode = "mirror"` で実サイズ + WS 切替後の位置に切替可 |
| セルクリック (grid) | そのワークスペースに切替 |
| window サムネイルクリック (grid) | 切替 + その window に focus |
| サムネイルを別セルにドラッグ (grid) | その window を移動 |
| ワークスペース header を別セルにドラッグ (grid) | 2 セルの内容を丸ごと swap |

表示制御 / 非表示 / トグル / キーボードモードは全部 CLI 経由 —
[CLI](#cli) 参照。

### キーボードナビ

tree は最初からキーボードナビで開く — 出た瞬間に facet が key focus を取る
(Spotlight 風) ので、 矢印キー・`Return`・検索 (`s`) が
すぐ使える。 代償: パネル表示中は facet が一時的に active app になる
(Dock + Cmd-Tab に表示)。 窓に作用する時 — 行をクリック か選択行で
`Return` — は先に key を**手放す**ので、 同一 app の別窓への focus も効く;
その後 facet は背景に戻る。 `Esc` は検索 / コンテキストメニューを 1 段
戻すだけで **tree からは抜けない**。

**「Desktop N」ヘッダの右クリック**でも **Search** (`s`) のメニューが開く。

| キー | アクション |
|---|---|
| `↓`/`↑`, `Ctrl-N`/`Ctrl-P`, `j`/`k` | 行間移動 |
| `Tab`/`⇧Tab`, `→`/`←`, `l`/`h` | 前/次ワークスペースへジャンプ |
| `s` | type-to-filter: 全ワークスペース横断 fuzzy 検索 (本物の text field、 IME 動く) |
| `Space` | 選択行を持ち上げて DnD — window 行は移動、 ワークスペース header は swap。 矢印で行き先ワークスペースを照準、 `Return`/`Space` で確定、 `Esc` でキャンセル |
| `m` | 選択行のコンテキストメニュー (キーボード操作可: `↑↓`/`Return`/`Esc`) |
| `Return` | 持ち上げ確定、 または (非持ち上げ時) クリックと同等に切替 + focus |
| `Esc` | 1 段戻る — 持ち上げキャンセル、 なければ filter クリア、 なければ検索を抜けて nav へ。 tree からは抜けない (抜けるのは他 app クリック / window で `Return`) |

window タイトルは Accessibility (`kAXTitle`、 CGWindowID で
照合、 短 TTL キャッシュ) で解決。 タイトル解決できない行は
コンパクト表示。 Accessibility 権限必要 (クリックと同じ grant)。

### Grid オーバービューのキーボード操作

| キー | アクション |
|---|---|
| 矢印 | セルカーソル移動 |
| `Tab` / `⇧Tab` | 同一セル内の header + windows をカーソル循環 |
| `Space` | 選択を持ち上げて DnD — window (移動) か header スロット (セル丸ごと swap)。 矢印で照準、 `Return`/`Space` で確定 |
| `Return` | 持ち上げ中なら確定 / 通常時は切替 |
| `Esc` | 持ち上げをキャンセル / オーバービューを閉じる |

セルは **ScreenCaptureKit サムネイル** (Screen Recording
権限必要) で描画。 バックグラウンド refresh でキャッシュを温めるので、
オーバービュー初回表示でアイコンフォールバックではなく実スクリーン
ショットが出る。

### Rail スイッチャーのキーボード操作

rail は表示中キーフォーカスを取る。 矢印は strip 軸に沿って browse —
上下辺ドック時は `←`/`→`、 左右辺ドック時は `↑`/`↓`。

| キー | アクション |
|---|---|
| 矢印 | strip を回転 — 前/次 workspace を中央へ (持ち上げ中は行き先を照準) |
| `Tab` / `⇧Tab` | 中央 workspace の header + windows を選択循環 |
| `Space` | 選択を持ち上げて DnD — window (移動) か header スロット (WS 丸ごと swap)。 持ち上げ中の `Space` は drop |
| `Return` | 持ち上げ確定 / 中央 workspace へ切替 |
| `Esc` | 持ち上げキャンセル → rail を閉じる |

## インストール

```sh
brew install akira-toriyama/tap/facet

# 詳細コメント付き config を配置 (デフォルト値は妥当)。 初回起動で
# すぐ読まれるよう、 app を開く前に置く:
curl --create-dirs -o ~/.config/facet/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/facet/main/config.toml

# facet は GUI agent — install だけでは起動しない。 1 度 app を開く:
open "$(brew --prefix)/opt/facet/Facet.app"
```

初回起動時、 *facet* に **Accessibility** 権限を付与 (System
Settings → Privacy & Security → Accessibility)、 でないとクリック /
ドラッグが効かない。 grid view のサムネイルが欲しければ **Screen
Recording** も付与。

`curl` の行で詳細コメント付きの [config.toml](config.toml) が
配置される。 デフォルト値は妥当で、 そのまま起動すれば tree view
(常駐サイドバー) が立ち上がる。 デフォルト view 切替・テーマ・
カラム数・ラベル位置等の変更はファイル内のコメントを参照。

## 設定

facet は `~/.config/facet/config.toml` を **読むだけ** (書き戻し
なし、 source of truth は 1 ファイル)。 設定可能な項目はリポジトリ
ルートの [config.toml](config.toml) のコメントを参照。 CLI override
(`facet --theme dracula` 等) はセッション中のみ有効; 永続化したい
場合はファイルを編集。

よく触る key:

- `[theme] name` — 全13テーマ: `terminal` (default) / `chomp` /
  `rainbow` / `cobalt2` / `shades-of-purple` / `tokyo-hack` /
  `github-dark` / `dracula` / `catppuccin-mocha` / `gruvbox` /
  `github-light` / `catppuccin-latte` / `system`、加えて `random`
  (起動/`--reload` ごとにランダム選択・`system` は除外)
- `[tree]` テーブル — `preview-mode` (`popover` / `mirror`) と、パネル
  geometry シード `pos-x` / `pos-y` / `width` / `height` (画面 pt・**左上
  原点**: 0,0 = メイン画面の左上・y は下方向・4つ全て必須)。毎起動 /
  `--reload` で権威 (ドラッグ・CLI geom は session 限り) なので、位置/
  サイズを固定するならここに書く。座標は `facet --view tree --pos-x/...`
  と同じ。さらに `line-pets` — **tree パネルの外枠**を歩くアーケード
  sprite (`chomp` / `ghost`)。透明オーバーレイに乗って枠の手前に描かれる。
  共有テーマライブラリ sill 由来の装飾 (同じ pet が halo のフォーカス枠も
  周回)。`pet-scale` (既定0.9) / `pet-lap-seconds` (既定8) で調整。空 = off
  (opt-in)。
- `[layout]` テーブル — `inner-gap` (タイル window 間の隙間) と
  `outer-gap` (画面端からの距離)、 単位 pt。 `outer-gap` は4辺一括、
  `outer-gap-top` / `-bottom` / `-left` / `-right` で辺ごとに上書き。
  すべて default 0 (隙間なしのフラッシュ配置); [0, 1000] にクランプ。
  全 layout に適用、 floating window は対象外。
  `smart-gaps` (default `false`) は WS にタイル window が 1 枚だけの時
  outer gap を落とし、 単独 window を画面端いっぱいに広げる。
- `[animation]` テーブル — 遷移をアニメ化。 `enabled` (default `false`、
  使うなら `true` に opt-in) が master スイッチ、 `curve` で質感を選ぶ:
  `cubic` (既定・ease-out) / `spring` (弾む) / `silky` (なめらか・長め) /
  `snappy` (キレ) / `random` (遷移ごとにランダム)。 off は `enabled = false`。
  `duration-ms` で長さ上書き ([80, 800] クランプ)、 未指定なら各カーブ既定。
  `event-driven` (master ON 時の default = `true`) は背景の窓 開閉 reflow
  をカバー — `false` にすると WS 切替 + 自分の操作起点の retile はアニメ
  のまま、 背景の open / close だけ snap。 対象は WS 切替 (方向性
  filmstrip スライド)・retile / レイアウト変更 (その場 reflow)・stack
  cycle (旧 top が抜け次が入る)・窓 open / close (既存タイル窓が新しいサイ
  ズへスライド、 新窓は タイル slot に snap)。 公開 AX のみ。 macOS
  「視差効果を減らす」 ON なら設定に関わらず即時。
- `[border]` テーブル — 全 view のネオン枠 (tree パネル / grid・rail は
  画面縁の枠・`theme` と直交)。
  `effect` = `off` (既定) / `neon` / `cyber` / `vapor` / `kawaii` /
  `chomp` / `rainbow` / `random`、 `glow` (既定 `true`) で bloom on/off、 `width`
  で線幅 (px・0.5–30 クランプ・既定 1.5)。 WS 切替でネオンが一瞬フラッシュ、
  `color-cycle-ms` (1周の ms・1000–120000 クランプ・既定 6000・小さいほど速い)
  は連続アニメの周期 = `rainbow` の色相回転 +、 `min-width`/`max-width`
  を両方指定 (max > min・各 0.5–30) した時の幅ブリージング (どの effect
  でも幅が min↔max で脈動・固定 `width` を上書き) を駆動。 off は素の
  テーマ accent 枠。
- `[window]` テーブル — `raise-on-open` は、 開いたばかりの **floating**
  窓 (sheet / dialog / palette、 `[[exclude]]` で float した窓、 facet が
  自動 float する窓) を最初に検知した瞬間どう前面に出すか。 こうした窓は
  アプリが置いた位置に生まれ、 タイル配置の *下* に隠れることがある。
  継続的な固定ではなく窓が開いた時 1 回だけのナッジ (既存の float 窓は
  desktop 切替では触らない): `raise` (デフォルト) は focus を奪わず自アプリ
  内の window 重なりの最前面へ持ち上げる; `activate` は新規 float の度に所有
  アプリを最前面化する (毎回 focus を奪う ―― `raise` で他アプリ窓の下から
  出し切れない時に選ぶ); `off` はアプリが置いた位置のまま。 floating 窓のみ
  が対象・起動時読み込み (変更は再起動)。
- `[[exclude]]` ルール — ポップアップ / 無名窓 / 補助窓をタイル対象から
  外す。 `app` (bundle-id 正規表現)、 `title` (正規表現; `^$` = 無名)、
  `role` / `subrole` (AX 完全一致)、 `max-width` / `max-height` (pt) で
  マッチ。 1ルール内の key は AND、 複数ルールは OR (上から最初の一致が
  勝ち)。 `action = "float"` (デフォルト) は追跡継続のままタイルから除外、
  `"ignore"` は完全に非管理、 `"manage"` は allowlist が float / ignore
  した窓を強制タイル (非標準 subrole で実窓を誤判定するアプリ向けの
  escape hatch)。 テンプレには「極小の無名ポップアップを float する」
  デフォルトを 1 件同梱。 (システムの sheet / dialog / palette は AX
  role で自動 float される。)
- `[[rule]]` adopt ルール — 窓を facet が採用した瞬間に facet を付与。
  各ルールは `match` (facet filter の WHERE 句。 例:
  `app=Safari and not floating`) と、 付与する facet: `workspace`
  (名前付き workspace へ移動)、 `tags`、 `floating` / `sticky` /
  `master` の組。 `[[exclude]]` と同じ**トップレベルのグローバル**ブロック
  (全 mac desktop に発火)、 宣言順に評価され窓は一致した全ルールの facet を
  受け取る。 廃止された `[[assign]]` の宣言的後継。 `match` が不正なら loud +
  非 fatal (そのルールのみスキップ・他は走る)。
- `[[desktop.N.section]]` ブロック — mac desktop ごとの section モデル
  (`N` は Mission Control 順の位置)。 順序付き section リストで desktop を
  記述。 各 section は必須の `type` を持つ: `"workspace"` (任意の `label` で
  命名・無ければ無名で 1始まりの index 表示の空間セル。 任意の `layout` seed 付き。 この個数がその desktop の
  workspace 数)、 `"lens"` (保存フィルタ — `label` + `match` + 任意の
  `layout` + `apply`。 `facet lens NAME` で有効化すると、 match を外れた窓を
  **すべての workspace 横断で** anchor park (cross-workspace exclusive な実 hide)
  し、 一致した窓を union タイルする。 どれかの workspace に切り替えると lens は
  自動解除・`facet lens --clear` で park した窓が戻る。 **窓を lens に DnD すると
  元の workspace から外れ**、 lens 経由でのみ存在する＝一致 lens が非 active の間は
  **迷子 (orphan)** になる)。 よって窓は**どの workspace にも属さない**ことがあり、
  迷子は invisible-but-logged（WS1 へ auto-home しない）。 **迷子受け皿** =
  `match = 'not workspace'` の `type = "lens"` section で集約（desktop ごとに 1 つ推奨）。
  **workspace は任意の `label` で config 命名可**（無ければ無名＝1始まりの index 表示）—
  実行時 `facet workspace --rename` が上書き。 2 モード:
  `[[desktop.N.section]]` が**1 つも無ければ**全 mac desktop が自動で
  デフォルト workspace を持つ。 **1 つでもあれば opt-in**: section ブロックの
  ある mac desktop だけ facet が管理し、 無い mac desktop は完全に
  ノータッチ（窓そのまま・パネル非表示）。 3 view すべてが同じ
  section リストを描画する — lens section は tree・grid・**rail** でセルとして
  並び、 ちょうど 1 つだけハイライト。 rail では active section が中央の hero
  になる（active な lens はそこに union を描く）。
- **per-window tag** は config を持たない — **実行時** (session 限り) に
  `facet window --tag NAME` (および `--untag` / `--toggle-tag` / `--retag`)
  で付ける自由記述の文字列。 `match` に `tag~=NAME` を含む `type = "lens"`
  section が NAME を持つ全窓を表示する。 `facet query --tags` でいま使われて
  いる全 tag を一覧。

## CLI

facet は **CLI 駆動**: 小さな flag set が稼働中の server に
distributed notification を投げる仕組み。 hotkey ツール (skhd /
Karabiner / Raycast / Hammerspoon / macOS Shortcuts 等) からこれら
を bind して使う想定。 完全リファレンスは `facet --help`。

```sh
# View 対称コマンド — NAME ∈ tree | grid | rail、 全 op で必須
facet --view NAME                 # NAME 開く (idempotent)
facet --view rail --edge left     # rail strip を辺に dock (top|bottom|left|right)
facet --hide NAME                 # NAME 閉じる
facet --toggle NAME               # NAME トグル

# Tiling (M5 Phase γ)
facet workspace --layout NAME     # bsp | stack | master-left | master-right | master-top | master-bottom | master-center | grid | spiral | float
facet workspace --retile          # active WS のレイアウトを再適用 (任意の tiling mode)
facet workspace --balance         # master 比率 / 数を均等な初期値にリセット
facet workspace --rotate 90|180|270        # bsp tree を時計回りに回転 (bsp のみ)
facet workspace --mirror horizontal|vertical # bsp tree を左右 / 上下に反転
facet window --toggle-float          # focused window の float flag flip
facet window --toggle-sticky         # 全 workspace に常駐させる (PiP / タイマー /
                                     # チャット)。 OFF にすると今いる workspace の
                                     # タイル窓に戻る。 session 限り・mac desktop 単位
facet window --toggle-orientation    # bsp: focus 中 window の親 split を 90 度回転
facet window --cycle-stack next|prev # stack の次 / 前メンバーへ循環
facet window --grow-master|--shrink-master   # master 幅 ±0.05 (master-* engine)
facet window --inc-master|--dec-master       # master 窓数 ±1 (master-* engine)

# --view tree は最初からキーボードナビで開く: facet が即 focus 取得
# (Spotlight 風) なので 矢印 / Return / 検索 (s) が
# すぐ効く。 窓に作用する時 (行クリック か Return) は先に key を手放す
# ので同一 app focus も効く。「Desktop N」ヘッダ右クリックでも
# Search に入れる。 (grid は常に key/active・rail は passive)

# Workspace 操作
facet workspace --focus N               # workspace N に切替 (1-indexed)
facet workspace --focus NAME            # 名前で切替 (reorder しても安定)
facet workspace --focus next|prev|recent # 巡回 (wrap) / 直前へ戻る
facet workspace --add                   # workspace を末尾に追加
facet workspace --remove TARGET         # WS を削除 (current | index N)・窓は隣 WS へ
facet workspace --rename NAME           # active workspace を改名
facet workspace --move N                # active workspace を位置 N へ移動
facet window --move-to N          # focus 中の window を WS N へ
facet window --move-to N --follow # …自分も WS N へ移動 (send-and-follow)
facet window --mark NAME          # focus 中の window にマークを付ける
facet window --focus-mark NAME    # そのマークの window へ jump (WS 跨ぎ可)
facet window --unmark NAME        # マークを消す
                                  # 1:1 — 1 窓 = 1 マーク。同名を付け直すと
                                  # 旧窓から外れる。session のみ・mac desktop ごと。

# Lens (section モデル) — type="lens" の [[desktop.N.section]] を label で
# 有効化。match を外れた窓を全 workspace 横断で anchor park
# (cross-workspace exclusive な実 hide) し、一致した窓を union タイル。
# どれかの workspace に切り替えると lens は自動解除。mac desktop 切替を跨いで持続。
facet lens "Web"                  # label が Web の lens を有効化
facet lens --clear                # active lens を解除 (park した窓が戻る)

# Section —任意の section (workspace でも lens でも) を 1-based の tree index
# か label で指す。`--focus` は activate (workspace へ切替 / lens を有効化)。
# `--rename` は表示 label を runtime で変更 (session のみ・relaunch で reset・
# `facet reload` では消えない・空 label は lens を config の label へ戻す)。
# tree からも改名可: section ヘッダ右クリック → Section ▸ Rename。
facet section --focus N            # tree 順で N 番目の section を focus
facet section --focus LABEL        # label が LABEL の section を focus
facet section --rename N "label"   # N 番目の section の表示 label を改名

# Scratchpad — 名前付きの隠し棚 (ドロップダウン端末 / メモ用途)
facet scratchpad --stash NAME     # focus 中の window を名前付き棚へしまう (画面外へ隠す)
facet scratchpad --toggle NAME    # 今いる WS にフロート overlay として呼ぶ —
                                  # すでにここで見えていれば棚に戻す
facet scratchpad --release NAME   # 棚から外して今の WS の通常タイル窓にする
                                  # spawn なし (既存窓のみ)・1:1 (名前↔窓)・
                                  # session のみ・mac desktop ごと。
facet query                      # スナップショット: backend /
                                  # theme / workspaces / stashed (隠し棚) /
                                  # lastError / timestamp
facet query --windows            # 全窓を flat JSON で (全 mac desktop)。
                                  # raw プロパティ + 窓ごとの facet 状態
                                  # (管理外は null)。jq で絞る:
                                  #   facet query --windows \
                                  #     | jq '.[] | select(.facet.tags[]? == "190")'
facet query --windows --filter EXPR  # その配列を facet filter 式
                                  # (WHERE 句) で後置フィルタ: field op
                                  # value (= ~= ^= $= *= |=) + 裸の
                                  # presence (tag/floating/…) を
                                  # and/or/not/() で結合。式が不正でも
                                  # loud だが非 fatal: caret を stderr に
                                  # 出し全窓表示 (exit 0)。例:
                                  #   facet query --windows \
                                  #     --filter 'tag~=web and not floating'
facet query --tags               # いま使われている全 tag を sorted な
                                  # JSON 配列で (窓を 1 つもタグ付けする
                                  # まで [])

# Server 制御
facet --theme NAME                # 全13テーマ + random (terminal, chomp, …, catppuccin-latte; config.toml 参照)
facet --reload                    # config.toml 再読込 + 反映
                                  # (theme / preview-mode)
facet --quit                      # server 終了
facet --resign                    # Facet.app 再 sign (brew install 後)
facet --help                      # 完全リファレンス
```

不明な flag / view / theme 名は exit `2` + stderr メッセージ —
typo は silent fail せず明示エラー。 短縮 (シェル alias / hotkey
バインド) は各自の環境の領分で、 facet 側では扱わない。

### Window tag

1 窓は **自由記述の文字列 tag** を好きなだけ持てる — 初出で自動生成・
session 限り・CLI でライブに付ける。 lens フィルタの材料になる: `match`
に `tag~=NAME` を含む `type = "lens"` section ([設定](#設定) 参照) が
NAME を持つ全窓を表示する。

```sh
facet window --tag NAME           # focus 中の窓に tag を付ける
facet window --untag NAME         # focus 中の窓から tag を外す
facet window --toggle-tag NAME    # focus 中の窓の tag を flip
facet window --retag OLD NEW      # 窓の tag を別の tag に置換
facet query --tags                # いま使われている全 tag (sorted JSON)
```

### ホットキー連携

facet は CLI のみ提供 — ホットキーは使い慣れたツールで。 例:

**[chord](https://github.com/akira-toriyama/chord)** — facet の
兄弟プロジェクト。 TOML 駆動のキーボード + マウス hotkey daemon
for macOS。 facet と同じ hexagonal Swift 構造、 GUI なし、
config 1 ファイル。

```toml
[[bindings]]
name   = "facet workspace 1"
input  = "ctrl + alt - 1"
action-shell = "/opt/homebrew/bin/facet workspace --focus 1"

[[bindings]]
name   = "move focused window to workspace 1"
input  = "ctrl + shift + alt - 1"
action-shell = "/opt/homebrew/bin/facet window --move-to 1"
```

**skhd** (`~/.config/skhd/skhdrc`):

```
ctrl + alt - 1          : facet workspace --focus 1
ctrl + alt - 2          : facet workspace --focus 2
ctrl + shift + alt - 1  : facet window --move-to 1
ctrl + shift + alt - 2  : facet window --move-to 2
```

**Karabiner-Elements**: *Complex Modifications* の JSON で
`shell_command` に `/opt/homebrew/bin/facet workspace --focus 1` 等を
指定。

**Hammerspoon**: `hs.hotkey.bind({"ctrl","alt"}, "1", function()
hs.execute("/opt/homebrew/bin/facet workspace --focus 1") end)`。

#### おまけ: mac desktop 切替のローディングスケルトン

フレーム単位が気になるあなたへ。 macOS は「mac desktop 切替が *これから*
始まる」 フックを出してくれないので、 facet が切替を知るのはスライド
*後* — 切替先 mac desktop に前 mac desktop の tree が一瞬チラッと残る、
ちょうどそのくらい遅い。 額に入れて飾るような美しい解ではない。

でも、 その 1 フレームのチラつきが我々と同じくらい気になるなら: ホット
キーツールで mac desktop 切替キーの *直前* に `facet --view tree --loading 2000`
を撃つ。 facet は tree にスケルトンを被せ、 スライド中ずっと保持し、
切替先 mac desktop の workspace がロードされた瞬間（または 2 秒経過、
早い方）に外す。 [chord](https://github.com/akira-toriyama/chord) なら
`action-shell` が先に走り、 `action-keys` が本来のキーを送る:

```toml
[[bindings]]
name         = "space-left + facet tree"
input        = "ctrl + fn - left"
action-shell = "facet --view tree --loading 2000"
action-keys  = "ctrl + fn - left"
```

> **2.x 未満の文法からの移行時の注意。** facet は空白区切りの値
> （`--flag VALUE`）になり、旧 `--flag=VALUE` 形は hard error（`exit 2`）。
> chord / skhd の `action-shell` は終了コードを無言で握り潰すため、古い
> `facet --view=tree --loading=2000` バインドは **エラーも出さずに静かに**
> スケルトンを出さなくなる。新文法でバインドを点検すること —
> [docs/cli-migration.md](docs/cli-migration.md) 参照。

ハック？ 間違いなく。 1 フレームに気づいてしまう人へのささやかな
ラブレター？ それも。 💙

## デバッグ

`FACET_DEBUG=1` で `/tmp/facet.log` への出力を stderr にもミラー
し、 verbose トレース (refresh tick、 backend command、 focus
retry、 grid DnD イベント等) を有効化。 `./run.sh` は自動で設定する。
生バイナリはコマンド前に付ける:

```sh
FACET_DEBUG=1 .build/release/facet              # foreground でイベント流れる
FACET_DEBUG=1 .build/release/facet 2>&1 | tee bug.log   # issue 用にキャプチャ
```

`FACET_DEBUG` は server 起動時に一度だけ読まれる。 無ければ stderr は
静か、 `Log.debug` 呼出もゼロコスト — brew 版 `facet` がシェルを
汚すことはない。 (`--debug` flag は無い: 渡すと未知 flag として `2`
で exit。)

## ソースからビルド

```sh
./run.sh             # release ビルド → 起動中の instance kill → Facet.app 起動
./run.sh --dev       # 同じだが Facet-dev.app を作る (bundle id 別、
                     #   Homebrew 版と並行運用したい時用、 TCC 分離)
./stop.sh            # 起動中の facet 全部 kill (release / dev / raw SwiftPM)
```

`./run.sh` が日常の rebuild ループ — bundle 差し替えて再起動まで
1 コマンド。 `./stop.sh` は「どれが動いてるか分からなくなった時」
の保険。

bundle を起動しただけでは `facet` CLI は PATH に乗らない
(`zsh: command not found: facet` — Homebrew 版は formula が
面倒を見るが、source build には無い工程)。rebuild ループに
alias を相乗りさせる — repo root で:

```sh
./run.sh && alias facet="$PWD/.build/release/facet"
```

意図的に session スコープ: rc ファイルは触らず、新しいタブでは
上の 1 行を打ち直すだけ。alias が無い場所では素の `facet` は
Homebrew 版に解決されたまま。alias が持つのはビルド・パスなので
rebuild すれば実体も最新になる。

bundle 化せずに verify だけ:

```sh
swift build          # コンパイルのみ
swift test           # XCTest — Xcode 必要 (CLT には入ってない)
```

## 正直な制限事項

- **Apple Silicon 専用**。 Intel Mac は対象外。
- **multi-display の layout / preview 位置は軽くしかテストして
  いない** — 主開発機がシングルディスプレイ。 multi-monitor 環境
  で挙動がおかしい場合は再現手順付きで issue 報告を。
- **window preview** は Screen Recording 権限が必要。
- **Ad-hoc 署名は rebuild ごとに Accessibility 再要求**。
  `./setup-signing-cert.sh` を 1 度走らせると persistent な
  self-signed identity ができ、 rebuild 跨ぎで TCC grant が維持
  される (Homebrew install では install サブプロセスが login
  keychain にアクセスできず ad-hoc になる — upgrade ごとに
  再要求)。
- **drop target はワークスペースの縦バンド単位** (tree view)。
  空のワークスペースへのドロップも可 (header band が target)。
- **WS 全体プレビュー** (ワークスペース header ホバー) は、 その
  ワークスペースの window 数だけ overlay を並列キャプチャするので、
  10+ window あると初回ホバーで CPU 一時 spike。
- **チューニング定数は `Sources/Facet*/Tunables.swift`** に各
  module ごと配置。 散らかった literal より、 これらの const を
  調整するのを優先。

## 「facet」 という名前

同じ workspace データを **角度を変えて複数の view で見る** — 
サイドバーの行、 grid のタイル、 dock のチップ、 等。 それぞれが
ワークスペースモデルの一つの **facet (面)**。 アーキテクチャも
同じ思想：1 つの core、 複数の adapter、 複数の view。

## ライセンス

[MIT](LICENSE) © akira-toriyama
