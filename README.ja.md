# facet

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![status](https://img.shields.io/badge/status-alpha-orange)

[English](README.md) · **日本語**

macOS 向け Swift 製ワークスペース + ウィンドウマネージャ。 同じ
ワークスペースモデルを **複数の view から切り替えて見る**
（半透明ツリーサイドバー、 TS3 風フルスクリーンオーバービュー、
将来の dock / hover / palette 等）。 backend も差し替え可能で、
現状は `rift-cli`、 将来は AX/CGS を直接叩く native adapter へ
段階移行する。

facet は [ws-tabs](https://github.com/akira-toriyama/ws-tabs) の
アーキテクチャ後継。 ws-tabs v1.6 で完成した grid view の DnD
（macOS が Big Sur で壊した TS3 "ウィンドウを別 Space にドラッグ"
UX を rift-cli 経由で復活させたもの）を、 クリーンな三層構造に
リストラクチャして持ち込み済み。 詳細は
[docs/architecture.md](docs/architecture.md)。

## 何ができるか

facet は menu-bar-less な agent (`LSUIElement`) として常駐し、
ワークスペースを 2 種類の view で見せる。 起動時にどちらを表示する
かは [`config.toml`](config.toml) の `default_view` で選ぶ:

- **Tree** — 半透明・常時最前面のサイドバー。 rift 各ワークスペースと
  その windows をツリー表示。 行クリックで focus、 行ドラッグで window
  を別 ws に移動、 ホバーで実画面プレビュー。
- **Grid** — フルスクリーンの TS3 風オーバービュー。 1 セル =
  1 ワークスペース、 ScreenCaptureKit のリアルサムネイル、 セル間 DnD
  (通常ドラッグで window 移動、 Shift+ドラッグでセル丸ごと内容
  swap)。 必要時に `facet --view=grid` で呼び出し、 Esc / 背景クリック
  で閉じる。

両 view は同じ backend (現状 `rift-cli`、 将来 swap 可) と同じ
テーマ (terminal / cute / system、 ライブ切替) を共有。

## 操作

| 操作 | 結果 |
|---|---|
| window 行クリック (tree) | そのワークスペースに切替 + その window に focus |
| ワークスペース header クリック (tree) | そのワークスペースに切替 |
| window 行を別ワークスペースにドラッグ (tree) | その window を移動 |
| 空白部分をドラッグ (tree) | パネル位置を変更 — 位置は永続 |
| 右クリック (tree) | コンテキストメニュー — window アクション / layout 切替 |
| window 行ホバー (tree、 macOS 14+) | その window の実画面位置でライブプレビュー |
| セルクリック (grid) | そのワークスペースに切替 |
| window サムネイルクリック (grid) | 切替 + その window に focus |
| サムネイルを別セルにドラッグ (grid) | その window を移動 |
| **Shift+ドラッグ** (grid) | source ↔ destination セルの内容を丸ごと swap |

表示制御 / 非表示 / トグル / キーボードモードは全部 CLI 経由 —
[CLI](#cli) 参照。

### キーボードナビ

tree パネルは focus を持っている間、 キー入力に反応する。 focus 取得
方法は 2 通り:

- **パネルクリック** — `facet --view=tree` 単体は passive (= 邪魔
  しない)、 ユーザがクリックした瞬間にキーボードナビ ON。 他 app に
  focus 移すと OFF、 キー漏れなし。
- **`--active` フラグ** — `facet --view=tree --active` は即 focus 取得
  (= hotkey から 1 発でナビ突入、 クリック不要)。 代償: ナビ中 facet
  が active app になる (Dock + Cmd-Tab に表示)、 `Esc` で抜ければ元の
  app に focus 戻る。

| キー | アクション |
|---|---|
| `↓`/`↑`, `Ctrl-N`/`Ctrl-P`, `j`/`k` | 行間移動 |
| `Tab`/`⇧Tab`, `→`/`←`, `l`/`h` | 前/次ワークスペースへジャンプ |
| `s` | type-to-filter: 全ワークスペース横断 fuzzy 検索 (本物の text field、 IME 動く) |
| `Space` | 選択行のコンテキストメニュー (キーボード操作可: `↑↓`/`Return`/`Esc`) |
| `Return` | 切替 + focus (クリックと同等) |
| `Esc` | filter クリア → keyboard mode 抜ける (パネルは表示維持) |

window タイトルは rift から取得、 rift が空を返す app
(Chrome / Code 等) は Accessibility (`kAXTitle`、 CGWindowID で
照合、 短 TTL キャッシュ) で解決。 タイトル解決できない行はコンパクト
表示。 Accessibility 権限必要 (クリックと同じ grant)。

### Grid オーバービューのキーボード操作

| キー | アクション |
|---|---|
| 矢印 | セルカーソル移動 |
| `Tab` / `⇧Tab` | 同一セル内で window 選択を循環 |
| `Space` | 選択 window を持ち上げ (キーボード DnD)、 矢印で照準、 `Return` で確定 |
| `Shift+Space` | セル丸ごと持ち上げ (swap) |
| `Return` | 持ち上げ中なら確定 / 通常時は切替 |
| `Esc` | 持ち上げをキャンセル / オーバービューを閉じる |

セルは **ScreenCaptureKit サムネイル** (macOS 14+、 Screen Recording
権限必要) で描画。 バックグラウンド refresh でキャッシュを温めるので、
オーバービュー初回表示でアイコンフォールバックではなく実スクリーン
ショットが出る。

## ステータス

**Alpha** — ws-tabs v1.6 との feature parity 達成 (M2)、 Homebrew
配布 (M3)、 ws-tabs archive (M4) 完了。 両 view 動作、 CLI 確定、
`brew install akira-toriyama/tap/facet` 稼働中。 次は native AX/CGS
backend (M5+) で rift-cli 依存を外す。

| マイルストーン | 状態 |
|---|---|
| M1 — repo scaffold、 `swift build` green | ✅ |
| M2 — tree + grid view が `FacetAdapterRift` 経由で動作 | ✅ |
| M3 — Homebrew tap (`brew install akira-toriyama/tap/facet`) | ✅ |
| M4 — ws-tabs を archive | ✅ |
| M5+ — `FacetAdapterNative` Phase α–ε | ⏳ |

レイヤー図と移行計画は [docs/architecture.md](docs/architecture.md)。

## インストール

```sh
brew install akira-toriyama/tap/facet

# facet は GUI agent — install だけでは起動しない。 1 度 app を開く:
open "$(brew --prefix)/opt/facet/Facet.app"

# 詳細コメント付き config を配置 (デフォルト値は妥当):
curl --create-dirs -o ~/.config/facet/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/facet/main/config.toml
```

初回起動時、 *facet* に **Accessibility** 権限を付与 (System
Settings → Privacy & Security → Accessibility)、 でないとクリック /
ドラッグが効かない。 grid view のサムネイルが欲しければ **Screen
Recording** も付与。 [rift](https://github.com/acsandmann/rift) +
`rift-cli` が PATH 上に必要。

`curl` の行で詳細コメント付きの [config.toml](config.toml) が
配置される。 デフォルト値は妥当で、 そのまま起動すれば tree view
(常駐サイドバー) が立ち上がる。 デフォルト view 切替・テーマ・
カラム数・ラベル位置等の変更はファイル内のコメントを参照。

## 設定

facet は `~/.config/facet/config.toml` を **読むだけ** (書き戻し
なし、 source of truth は 1 ファイル)。 設定可能な項目はリポジトリ
ルートの [config.toml](config.toml) のコメントを参照。 CLI override
(`facet --theme=cute` 等) はセッション中のみ有効; 永続化したい
場合はファイルを編集。

## CLI

facet は **CLI 駆動**: 小さな flag set が稼働中の server に
distributed notification を投げる仕組み。 hotkey ツール (skhd /
Karabiner / Raycast / Hammerspoon / macOS Shortcuts 等) からこれら
を bind して使う想定。 完全リファレンスは `facet --help`。

```sh
# View 対称コマンド — NAME ∈ tree | grid、 全 op で必須
facet --view=NAME [--active]      # NAME 開く (idempotent)
facet --hide=NAME                 # NAME 閉じる
facet --toggle=NAME               # NAME トグル

# --active は修飾子 — --view=tree と組み合わせた時のみ意味あり。
# --active なしでも tree パネルはクリックすればキーボードナビ ON
# になる; --active は hotkey から 1 発で focus 取得したい場合用
# (Spotlight 風起動)。 --view=grid と組み合わせると silent no-op
# (grid は常に key/active)。

# Server 制御
facet --theme=NAME                # terminal | cute | system
facet --quit                      # server 終了
facet --debug                     # verbose log (stderr +
                                  # /tmp/facet.log、 server-mode)
facet --help                      # 完全リファレンス
```

不明な flag / view / theme 名は exit `2` + stderr メッセージ —
typo は silent fail せず明示エラー。 短縮 (シェル alias / hotkey
バインド) は各自の環境の領分で、 facet 側では扱わない。

## デバッグ

`--debug` フラグで `/tmp/facet.log` への出力を stderr にもミラー
し、 verbose トレース (refresh tick、 backend command、 focus
retry、 grid DnD イベント等) を有効化:

```sh
.build/release/facet --debug              # foreground でイベント流れる
.build/release/facet --debug 2>&1 | tee bug.log   # issue 用にキャプチャ
```

`--debug` は server 起動時のみ有効 (`--show` 等の client mode flag
と併用しても no-op)。 通常起動では stderr は静か、 `Log.debug` 呼出
もゼロコスト。

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

bundle 化せずに verify だけ:

```sh
swift build          # コンパイルのみ
swift test           # XCTest — Xcode 必要 (CLT には入ってない)
```

## 正直な制限事項

- **Apple Silicon 専用**。 Intel Mac は対象外 (rift CLI path
  `/opt/homebrew/bin/rift-cli` は意図的に固定 — M5+ で rift
  adapter 自体を native adapter に丸ごと置き換える前提)。
- **シングルディスプレイ前提** (rift が 1 つを返す)。 multi-display
  での layout / preview 位置 は未検証。
- **window preview は macOS 14+** + Screen Recording 権限が必要。
  プレビューの表示位置に rift の論理 frame を使うため、 multi-display
  の caveat はここにも適用。
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
