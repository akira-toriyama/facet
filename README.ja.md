# facet

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![status](https://img.shields.io/badge/status-bootstrap-yellow)

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
リストラクチャしながら持ち込んでる。 詳細は
[docs/architecture.md](docs/architecture.md)。

## ステータス

**ブートストラップ中** — multi-target SwiftPM scaffold 配置済み、
view / adapter は移植前。

| マイルストーン | 状態 |
|---|---|
| M1 — repo scaffold、 `swift build` green | ✅ |
| M2 — tree + grid view が `FacetAdapterRift` 経由で動作 | 🚧 |
| M3 — Homebrew tap (`brew install akira-toriyama/tap/facet`) | ⏳ |
| M4 — ws-tabs を archive | ⏳ |
| M5+ — `FacetAdapterNative` Phase α–ε | ⏳ |

レイヤー図と移行計画は [docs/architecture.md](docs/architecture.md)。

## インストール

M3 (Homebrew tap 整備) 完了後:

```sh
brew install akira-toriyama/tap/facet
curl --create-dirs -o ~/.config/facet/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/facet/main/config.toml
```

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

# --active は修飾子 — --view=tree と組み合わせた時のみ意味あり
# (kb モード)。 --view=grid と組み合わせると silent no-op (grid
# は常に key/active)。

# Server 制御
facet --theme=NAME                # terminal | cute | system
facet --quit                      # server 終了
facet --debug                     # verbose log (stderr +
                                  # /tmp/facet.log、 server-mode)
facet --help                      # 完全リファレンス
```

不明な flag / view / theme 名は exit `2` + stderr メッセージ —
typo は silent fail せず明示エラー。 短縮はシェル alias で対応:

```sh
alias fa='facet --view=tree --active'
alias fg='facet --view=grid'
```

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

## 「facet」 という名前

同じ workspace データを **角度を変えて複数の view で見る** — 
サイドバーの行、 grid のタイル、 dock のチップ、 等。 それぞれが
ワークスペースモデルの一つの **facet (面)**。 アーキテクチャも
同じ思想：1 つの core、 複数の adapter、 複数の view。

## ライセンス

[MIT](LICENSE) © akira-toriyama
