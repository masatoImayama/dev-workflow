# ウェーブ差分の先行レビュー（wave-review。run スキル参照資料）

`skills/run/SKILL.md`「Step 3」「Step 7」から参照される。**wave-review の起動条件・差分範囲・
`REVIEWED_COMMIT` の管理・指摘の扱いを詳しく知りたいときに読む。**

## なぜ「レーン起動と同一メッセージ」でなければならないか

Claude Code のサブエージェントは**バッチ全員が終わるまで結果が返らない**。したがって
「レーンを起動した後に、別途バックグラウンドで evaluator を走らせる」ことはできない。
**次ウェーブのレーン起動メッセージに、wave-review の evaluator 起動を同梱する**ことだけが、
実装上ただ一つの並行化手段である。このバッチの所要時間は `max(最長レーン, レビュー)` になり、
レビューが実装より速ければレビューの時間はゼロコストで隠れる。

Codex は `codex exec` を子プロセスとして逐次起動する構造であり、この「同一バッチで並行」という
手段そのものが存在しない。**そのため wave-review は Claude Code 版の run にのみ実装し、
Codex 版（`skills-codex/` / `adapters/codex/run-loop.sh`）は変更しない。**

## `REVIEWED_COMMIT` の初期値・更新・失敗時の扱い

`REVIEWED_COMMIT` は「そこまでは既にレビュー済み」であるEpicブランチ上のコミットを指す変数。
自律ループの前提変数（`SKIPPED_CSV` 等）と同じ場所で、**ループ開始前に1回だけ**初期化する。

```bash
REVIEWED_COMMIT="$(git merge-base main "${EPIC_BRANCH}")"   # Epicブランチの分岐元
PREV_WAVE_INCORPORATED=false   # 「このrunセッション内で、直前のウェーブをEpicへ取り込んだか」
```

- **`PREV_WAVE_INCORPORATED` が `false` の間（＝このrunセッションでまだ一度もウェーブを
  取り込んでいない、最初のウェーブ）は wave-review を起動しない。** 前ウェーブが無いので
  レビューすべき差分がまだ確定していない
- Step 7 でウェーブ N を Epic ブランチへ取り込んだら、`PREV_WAVE_INCORPORATED=true` にする。
  以降のウェーブ（N+1 以降）の Step 3 では、`WAVE_BASE`（＝ウェーブ N 取り込み後の Epic tip）を
  上限とした `REVIEWED_COMMIT..WAVE_BASE` の差分で wave-review を起動できる
- wave-review の evaluator が **`APPROVE` または `REQUEST_CHANGES` を返した**（＝実行が完了し
  `reviewed_commit` が得られた）場合のみ、`REVIEWED_COMMIT` をその起動時点の `WAVE_BASE` へ
  進める。**evaluator の起動自体が失敗した／JSONが読み取れなかった／タイムアウトした場合は
  `REVIEWED_COMMIT` を進めない。** 進めなければ、その未レビュー区間は次の wave-review、
  最終的には Epic 末レビューが必ず拾う（**取りこぼしを作らない**という設計上の要請）
- 更新のタイミングは Step 7（ウェーブ N+1 の取り込み処理）。この時点で、Step 3 で同時起動した
  wave-review（ウェーブ N の差分に対するもの）の結果が既にバッチとして返ってきているため、
  取り込み処理とあわせて `REVIEWED_COMMIT` の更新も行う

## 差分範囲の決め方

wave-review の起動メッセージには次を渡す。

```
- モード: wave-review
- 差分範囲: [REVIEWED_COMMIT]..[WAVE_BASE]（＝直前に取り込まれたウェーブまでの未レビュー分）
- 作業ディレクトリ: .claude/worktrees/[epicN]
```

`WAVE_BASE` は Step 2 で記録した「今回のウェーブが分岐する Epic tip」であり、直前のウェーブが
Step 7 で取り込まれた直後の値と一致する。したがって `REVIEWED_COMMIT..WAVE_BASE` は
「前回レビュー済みの地点から、直前ウェーブが取り込まれた地点まで」の差分になる。

## 指摘の扱い（その場で直さない）

**wave-review の指摘はその場で直さない。** high / medium の指摘を `review` ラベル付きの issue
として蓄積し、実際の修正は Epic 末の指摘対応ループ（「Epic一括レビュー」節の R2〜R3）で
通常のタスクとして processed する。ウェーブ内で直すと同期点が増え、オーバーラップの利得が
消えるため。issue 化の書式は [references/review.md](review.md) の R2 と同じで、本文には
次を必ず含める。

```
- Epic: #[Epic issue番号]
- 前提: なし
```

low の指摘は issue 化せず、PR 本文の「レビューで挙がった軽微な指摘」に合流させる（Epic 末レビュー
の指摘と同じ扱い）。

## 最終ウェーブとEpic全体整合はEpic末レビューが見る

最終ウェーブの差分は「次のウェーブ」が存在しないため wave-review されない。この取りこぼしは
Epic末の一括レビュー（`REVIEWED_COMMIT..Epic tip`。通常は最終ウェーブ分だけになる）が拾う。
また、仕様書との照合やタスク間の重複実装・命名の食い違いといった**全ウェーブ横断の整合**は、
wave-review が「そのウェーブ差分だけ」を見る設計上カバーできないため、これもEpic末レビューの
守備範囲になる（「Epic一括レビュー」節冒頭を参照）。
