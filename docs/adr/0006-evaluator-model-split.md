# ADR 0006: evaluator を「発見は sonnet、確度判定は opus」に変える

## ステータス

承認済み（Epic #143 / Task #157）

## コンテキスト

Epic #143 の後半5タスク（#153〜#157）は「LLMの推論ターン数と出力トークン量そのものの削減」を
狙う軸である。`agents/evaluator.md` は `model: opus` / `effort: high` / `maxTurns: 120` で
Epic全差分をレビューしており、完全に直列の尾になっている。

参考にした設計は `treflebonbon/dotfiles` の `model: sonnet` + `advisorModel: opus` +
advisor tool 構成（難所だけ上位モデルに上げる）である。`skills/run/SKILL.md` は
オーケストレータ本体には既にこの構成を推奨しているが、evaluator自体はopus固定のままだった。

方針は、#147/#149で導入した観点別レビュー（focus）の**発見役をsonnetで並列に回し**、
拾った指摘の**確度判定だけをopusに寄せる**こと。

## 確認した事実（推測で実装しないため）

モデル指定は `adapters/claude/overlays/evaluator.md` の frontmatter `model:` に固定されている。
観点別に別モデルを使うには次の3案があった。

- (a) 別エージェント定義を用意する
- (b) 起動時に上書きする
- (c) advisor tool を使う

**(b) が実際に可能であることを確認した。** Claude CodeのTask/Agent起動には、エージェント
定義のfrontmatterの`model:`を上書きする「起動時のモデル指定」が存在する。指定できる値は
`sonnet` / `opus` / `haiku` / `fable` で、指定しなければエージェント定義の`model:`が使われる。
したがって「同じ`evaluator`定義を、発見役ではsonnetで、確度判定役ではopusで起動する」ことは
**別エージェント定義を増やさずに実現できる**。

**(c) advisor toolの有無は確認していない。** これを前提にした設計にはしない。

**Codex側（`adapters/codex/overlays/evaluator.toml`）に同等のモデル切り替え機構があるかは
確認していない。** Codexは`codex exec`を子プロセスとして逐次起動する構造であり、Claude Code
のサブエージェント起動時上書きに相当する機構の有無を実測していない。**未確認のまま実装しない。**

## 決定

### A. 採用: (b) 起動時のモデル上書き

`adapters/claude/overlays/evaluator.md`の`model:`の既定値を`opus`から`sonnet`に変更する
（=発見役の既定値）。R1（Epic末レビューの観点別4本並列起動）はこの既定のまま動く。

R1とR2（issue化）の間に**確度判定ステップを1本**追加する（`skills/run/references/review.md`
「確度判定」）。この呼び出しでは、起動時モデル指定で明示的に`model: opus`を上書きする。
確度判定役の責務は「新しい指摘の発見」ではなく「R1が出した`findings`の確度判定」だけであり、
各findingに`confidence`（`high-confidence` / `low-confidence`）を付与して返す。

### B. wave-review / delta-reviewは確度判定を経由しない

対象差分が小さく、誤検知1件あたりのコストがepic-reviewの一括レビューより低いため、
既定モデル（sonnet）のまま単発で動かす。確度判定を挟むのはR1→R2の間だけに限定する。

### C. 確度判定を通らなかった指摘の扱い

`low-confidence`と判定された指摘は**破棄しない**。「レビューで挙がった軽微な指摘」
（issue化せず記録のみ。共通ルールの「レビュー基準」のlowと同じ枠）へ格下げして記録する。
**highの指摘であっても、確度判定を経ずに黙って捨てる経路は作らない。** 確度判定呼び出し自体が
失敗・応答不能だった場合も同様に、対象findingsを`high-confidence`とみなして安全側（R2へ進めて
人間のレビューに委ねる側）に倒し、確度判定未実施の事実を記録する（「記録して進む」に分類）。

### D. Codexは据え置き

同等のモデル切り替え機構の有無を確認していないため、Codex側は変更しない。従来どおり単一
evaluator（観点未指定・全観点、モデルは親セッション継承）のまま据え置く。#147のADR 0003で
決定済みの「Codexは単一evaluatorのまま」という制約とも整合する。

### E. レビュー基準は変更しない

`core/instructions.md`「レビュー基準」（重要度の3段階・過剰実装/過剰設計の当てはめ・判定）は
一切変更しない。確度判定は「重要度の判定基準」を変えるものではなく、「発見された指摘が
実在するか（誤検知でないか）」を別モデルで再確認する追加ステップである。

## 理由

- 発見役（sonnet・並列4本）は速度優先で誤検知を許容し、確度判定役（opus・単発）が精度を
  引き上げる。全4本をopusで直列に回す現行構成より、レイテンシとコストの両方を削減できる
- 別エージェント定義を増やさずに実現できるため、`adapters/claude/overlays/evaluator.md`・
  `core/roles/evaluator.md`の変更量を最小化できる（定義ファイルは1つのまま）
- wave-review / delta-reviewは対象差分が小さく、確度判定を挟むコストに見合わないため対象外とする

## トレードオフ

- **確度判定1本ぶんのopus呼び出しが追加される。** R1の4本ぶんのsonnetコストは下がるが、
  確度判定でopusを1回使うため、純減にはならない場合がある（トークン単価が支配的な場合は
  それでも4本opus直列より安くなる想定だが、実測はしていない）
- **確度判定が誤って`low-confidence`と判定すると、実在する指摘を記録のみに格下げしてしまう
  リスクがある。** これを軽減するため、highの指摘を黙って破棄する経路は作らず、必ず
  「レビューで挙がった軽微な指摘」として記録に残す（Cの決定）
- **wave-review / delta-reviewは確度判定の恩恵を受けない。** 対象差分が小さいため許容したが、
  将来これらのモードでも誤検知が問題になった場合は再検討が必要

## 却下した代案

### (a) 別エージェント定義（evaluator-discovery / evaluator-confidence）を用意する

`adapters/claude/overlays/`に新しいオーバーレイファイルを追加し、`core/roles/evaluator.md`を
2つの役割に分割する案。(b)の起動時モデル上書きで同じ結果を達成でき、かつ定義ファイルの
数を増やさずに済む（保守対象が1つで済む）ため採用しなかった。

### (c) advisor toolを使う

`skills/run/SKILL.md`がオーケストレータ本体に推奨する`advisorModel`構成
（`model: sonnet` + `advisorModel: opus`）をevaluatorにも適用する案。evaluator自身にadvisor
toolが結線されているかを確認できておらず、未確認の機構を前提に設計しないという方針
（Task #157の必須要件）により採用を見送った。将来advisor toolの利用可否が確認できれば
再検討する余地がある。
