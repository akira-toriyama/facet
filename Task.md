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

- [ ] **2. config.toml「迷子」ラベルの英語化**
  - 「迷子」（日本語）をやめ、他（Web / Code / Chat）と揃えて英語に

- [ ] **3. workspace の DnD**
  - workspace 自体を DnD できるようにする（ウィンドウ DnD は既に可）

- [ ] **4. tree のキーボード操作が効かない**
  - tree がキーボード操作を受け付けない（再現条件は本人の補足待ち）

- [ ] **5.（追記待ち…）**

---

_補足: 上記 1–4 は内部で feasibility 調査済み（着手箇所を把握）。聞き取り完了後に提示する。_
