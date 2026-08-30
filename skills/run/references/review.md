# 一括レビューの詳細（run スキル参照資料）

`skills/run/SKILL.md`「Epic一括レビュー」の R1 の結果マージ、および R2 以降。**R1 が
REQUEST_CHANGES を返したとき、または変更が 50 ファイルを超えたときにだけ読む。**

### R1の結果マージ

R1 は `correctness` / `readability` / `over-engineering` / `security` の4観点を
`@evaluator` の同一メッセージで並列起動する（詳細は SKILL.md「R1: 一括レビューの実行」）。
4本それぞれが末尾に JSON ブロック（`verdict` / `reviewed_commit` / `focus` / `findings`）を
返すので、run が次の手順でマージ・重複排除する。**JSON のパースはあなた（runの実行者）が
直接行う。`jq` に依存せず、パイプラインで機械的に処理しようとしない。**

1. **findings の連結**: 4本の `findings[]` をそのまま連結する
2. **重複排除**: 同一 `location`（ファイル:行）かつ同一趣旨の指摘は1件に統合する。
   統合時は**最も高い severity** を採用し、由来した観点名（`findings[].focus`）を
   `detail` または備考に併記する（例:「correctness / security の両観点から指摘」）
3. **verdict の合成**: 4本のうち1本でも `REQUEST_CHANGES` なら全体を `REQUEST_CHANGES`
   とする。4本すべてが `APPROVE` の場合のみ全体を `APPROVE` とする
4. **`reviewed_commit` の食い違い**: 4本とも同じ値になるはずだが、食い違った場合は
   **最も古いもの**を採用する（次の delta-review が差分を取りこぼさないようにするため）。
   食い違った事実は Epic issue にコメントする
5. **1本の失敗**: 4本のうち1本でも起動失敗・応答不能で結果が得られなかった場合、
   **その観点が未レビューである事実を Epic issue と PR 本文に記録**して先へ進む
   （「記録して進む」に分類する。run は止めない）。残り3本の結果でマージ・判定は続行する

マージ後の `findings[]` は、次の「確度判定」を経てから R2（issue化）へ進む。

### 確度判定（R1 と R2 の間。Task #157）

R1（発見役・sonnet・観点別4本並列）はスピード優先のため、opus単独レビューより誤検知
（false positive）が混じりやすい。**issue化する前に、より高精度なモデルで1本だけ確度判定を
挟む。** 発見（並列・sonnet）と確度判定（単発・opus）で役割を分けることで、並列化による
レイテンシ削減と最終判定の精度を両立させる（役割の定義は `core/roles/evaluator.md`
「発見役と確度判定役」を参照）。

対象は「R1の結果マージ」後の `findings[]` のうち **high / medium のみ**（low はもともと
issue化しないため確度判定は不要。共通ルールの「レビュー基準」の3段階は変更しない）。
high/medium が1件も無ければこのステップ自体を省略し、そのままR2（0件のissue化）へ進む。

**この呼び出しは、プロンプト本文の指示ではなく Task/Agent ツールの起動時パラメータで
モデルを上書きして起動する。** ADR-0006 が確認したとおり、Claude Code の Task/Agent 起動には
エージェント定義 frontmatter の `model:` を上書きする起動時パラメータが実在し、
`sonnet` / `opus` / `haiku` / `fable` を取る。**R1（発見役）と同じ `@evaluator` 定義のまま、
この1本だけ起動パラメータに `model: opus` を渡す。**プロンプト本文に「model: opus」という
1行を書き添えるだけでは、それを転記するだけの起動経路では上書きが効かないまま既定の sonnet で
動いてしまい、しかも空振りしても検知できない。そのため、プロンプト本文からはモデル指定の指示行を
外し、run（オーケストレータ）自身が起動時パラメータとして `model: opus` を渡す責務を負う。

```
Task/Agent起動パラメータ: model: opus
@evaluator
Epic #$ARGUMENTS のレビュー指摘の確度を判定してください。
- モード: confidence-check
- この呼び出しは opus で起動されている前提である
- 対象: 以下はR1マージ後のfindings（high/mediumのみ）
[マージ済みfindingsのJSON配列をそのまま貼る]
- 差分範囲: main...[epic/epicXX/機能名]
- 各findingについて実際にコードを確認し、confidence（high-confidence / low-confidence）を判定すること
- 新しい指摘を追加しないこと（発見はR1が完了済み。ここでの役割は確度判定のみ）
- 最後に必ずJSONブロック（各findingに`confidence`フィールドを追加したfindings配列。
  トップレベルに実際に動いたモデル名を`model`フィールドとして含めること）を出力すること
```

**`low-confidence` と判定された指摘は、破棄せず「レビューで挙がった軽微な指摘」（PR本文。
issue化せず記録のみ）へ格下げして記録する。** 既存の low severity の指摘を記録するのと
同じ枠を再利用する（共通ルールの「レビュー基準」参照）。**high の指摘であっても、確度判定を
経ずに黙って捨てる経路は無い。** `high-confidence` と判定された指摘だけが、続く
「R2: 指摘をissue化」の対象になる。

**起動時モデル上書きが実際に効いたかは検知手段が無いと空振りに気づけない。** 確度判定呼び出しの
トークン消費を記録する際、返ってきたJSONの`model`フィールド（読み取れた場合のみ）を
`--note`に含め、R1と同じ作法で記録する（`--mode confidence-check`）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" record \
  --epic "$EPIC_NUM" --role evaluator --mode confidence-check \
  --note "model=[JSONのmodelフィールド。読み取れなければ'unknown']" --tokens [読み取ったトークン数]
```

**起動時モデル上書きが技術的に実現できなかった場合（`model`パラメータ自体が使えない等）**は、
確度判定を発見役と同一モデル（sonnet）のまま据え置いて実行し、その事実を Epic issue と PR 本文に
記録する（ADR-0006 決定Cと同じ「記録して進む」枠。据え置きであってもステップ自体は省略しない。
黙って sonnet のまま実行してこの事実を記録しない経路は無い）。

確度判定呼び出しが失敗・応答不能だった場合は、**high/mediumの指摘を無条件でissue化せず
握り潰しもしない**。「記録して進む」に分類し、確度判定未実施の事実をEpic issueとPR本文に
記録した上で、対象findingsを`high-confidence`とみなしてR2へ進める（安全側＝人間のレビューに
委ねる側へ倒す。黙って破棄しない）。

### R2: 指摘をissue化

確度判定を通過した（`high-confidence`と判定された）findingsのうち、**high と medium の
指摘だけ**をissueにする。low、および確度判定で`low-confidence`となった指摘はissue化せず、
PR本文の「レビューで挙がった軽微な指摘」に列挙するだけに留める。

findingsを読み取り、1件ずつ以下を実行する:

```bash
# reviewラベルを用意（初回のみ。既存なら --force で上書き）
gh label create review --color B60205 --description "一括レビューの指摘" --force

# 指摘1件につき1つのissueを作成（[]内はfindingの値で置き換える）
gh issue create --label "task,review" --title "Review: [title]" --body "$(cat <<'BODY'
## 指摘（重要度: [severity]）

[detail]

## 該当箇所
`[location]`

## 修正方針
[fix]

## 対応時の指示
この修正が守ろうとしている性質を、コミットメッセージ本文（またはこのissueへのコメント）に1文で書くこと。
そのうえで、その性質がリポジトリ全体で成り立つことを検査するテストを書けないか検討すること。書けるなら、
個別ケースの回帰テストではなくそちらを書く（書けないと判断した場合はその判断でよい。あらゆる修正に
全体走査テストを義務付けるものではない）。

## 由来
- Epic: #[epic番号]
- 前提: なし
- 起因タスク: [task_ref]
- 観点: [focus]
- レビュー時点: `[reviewed_commit]`
BODY
)"
```

`- Epic: #[epic番号]` と `- 前提: なし` は必ず書く。`scripts/plan-waves.sh` がこの2行を
読んで他Epicのタスクを除外し、review issueを通常のウェーブへ載せられるようにするため
（R3参照）。

`reviewed_commit` は次の delta-review の起点になるので、**必ず控えておく。**

作成したissueの番号一覧をEpic issueにコメントし、追跡できるようにする。

### 指摘対応時に「性質」を言語化させる（#197）

**同じ性質の欠陥を修正が別の場所に作り直す事故が繰り返されている**（Epic #143 / #173 / #174 で
4件。詳細は issue #197）。共通する原因は、修正した本人が「元の欠陥の**現れ方**」だけを直し、
「守るべき**性質**」を言語化しないまま次へ進むことにある。

上記issueテンプレートの `## 対応時の指示` は、この言語化を**review issueを実装する
generator自身**に促すためのものである。review issueは通常のウェーブループ（Step 1〜7）に
載って処理されるため、対応する generator は `skills/run/references/review.md` ではなく
issue本文を読む。そのため、この指示は run 側の手順書だけに書いても届かず、issue本文に
埋め込んで初めて実効性を持つ。

**「書けるなら書く」という判断の余地を残すこと。** 元の欠陥の性質を汎用的に検査する手段が
無い場合や、対象が単発の設定ミスに過ぎない場合まで、リポジトリ全体を走査するテストを
一律に要求すると、あらゆる修正の実装コストが跳ね上がる（issue #197「スコープの注意」）。
このテンプレートの文言を「必ず全体走査テストを書け」という義務規定に強めてはならない。

evaluator側の対応する確認観点は `core/references/review-checklist-correctness.md`
「修正の妥当性」を参照（同じ性質を別の角度――実装時の自己言語化と、レビュー時の第三者確認
――から支える。片方だけでは、言語化を怠った場合にもレビューで拾えない）。

### R3: 指摘対応ループ

`APPROVE` なら何もせずPR作成へ進む。`REQUEST_CHANGES` の場合:

1. 作成した review issue を**1件ずつ generator に渡すのではなく**、通常のウェーブループ
   （Step 1〜7）に載せて**並列に**処理する。review issue は `task` ラベルを持ち、
   本文に `- 前提: なし` を書いているため、依存関係の無い1つのウェーブとして自然にまとまる
   （`scripts/plan-waves.sh` の依存グラフ構築に相乗りする）
2. 全件対応したら **delta-review** で再レビューする（delta-reviewは観点別に分けず、
   対象が指摘対応差分に限られ小さいため**1本**で行う）:

```
@evaluator
Epic #$ARGUMENTS の指摘対応を確認してください。
- モード: delta-review
- 差分範囲: [R1のreviewed_commit]..[epic/epicXX/機能名]
- 指定範囲外の蒸し返しはしないこと
- 最後に必ずJSONブロックを出力すること
```

R1と同じ作法でこのdelta-review呼び出しのトークン消費も記録する（`--mode delta-review`）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" record \
  --epic "$EPIC_NUM" --role evaluator --mode delta-review --tokens [読み取ったトークン数]
```

3. `APPROVE` → PR作成へ / `REQUEST_CHANGES` → R2 に戻る

### R4: 打ち切り条件

**レビューは最大2巡まで**（初回R1の観点別4本並列 + 確度判定1本（1本）+ delta-review 1回（1本）。
合わせてevaluator起動は最大6回）。

2巡目でも `REQUEST_CHANGES` が残る場合は、**そこで打ち切ってPRを作成する。**
未対応の指摘は:

1. issueは**オープンのまま残す**（クローズしない）
2. PR本文の「未対応の指摘」セクションに issue 番号付きで列挙する
3. 人間のレビュアーがPR上で判断する

無限ループでコストを溶かすより、人間に判断を渡す方が安い。

### レビュー粒度の調整

R1の起動前に変更ファイル数を数え、既存のしきい値（目安: 変更50ファイル超）で3つに分岐する。
**新しいしきい値の軸は増やさず、この50ファイル超のしきい値に相乗りする。**

dev-workflowは**駆動先プロジェクト**でこのSKILL.mdを実行するプラグインであり、駆動先の
デフォルトブランチが `main` とは限らない。**ベースブランチを `master`/`main` に決め打ちしない**
（dev-workflow自身のリポジトリのデフォルトブランチが `master` であっても、それを駆動先の値として
埋め込んではならない）。`gh repo view` で駆動先の実際のデフォルトブランチを解決する:

```bash
BASE_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
BASE_BRANCH="${BASE_BRANCH:-main}"

if CHANGED_FILES_LIST="$(git diff --name-only "${BASE_BRANCH}...${EPIC_BRANCH}")"; then
  CHANGED_FILES="$(printf '%s\n' "$CHANGED_FILES_LIST" | grep -c '.')"
else
  echo "WARN: git diff ${BASE_BRANCH}...${EPIC_BRANCH} に失敗し、変更ファイル数を数えられなかった。Phase単位分割にフォールバックする" >&2
  CHANGED_FILES=""
fi
```

`git diff` を `wc -l` に直接パイプしない。パイプすると `git diff` が失敗しても `wc -l` は0を
返して**失敗を握り潰し**、「CHANGED_FILES <= 50 → 従来どおり」に誤判定してしまう
（ベースブランチが存在しない等で起きうる）。上記のとおり `git diff` 自体の終了コードを見て、
失敗時は `CHANGED_FILES` を空にし、**サイズ不明のまま「従来どおり（分割なし）」に倒さず**
Phase単位分割へフォールバックする。

| 条件 | 挙動 |
|---|---|
| `CHANGED_FILES` を数えられなかった（`git diff` 失敗） | **Phase単位分割にフォールバックする**（下記の既存の回避策。サイズ不明の場合に安全側へ倒す） |
| `CHANGED_FILES` <= 50 | **従来どおり。** code-review-graphには一切触れない（グラフ構築もしない） |
| `CHANGED_FILES` > 50 かつ code-review-graphが利用可能（`command -v code-review-graph`） | evaluatorのプロンプトに「blast radiusの算出を使って読む優先順位を付けてよい」旨を含めて起動する |
| `CHANGED_FILES` > 50 かつ code-review-graphが未導入 | **従来どおり**、R1をPhase単位に分割して起動する（下記の既存の回避策） |

code-review-graphが利用可能な場合でも、Phase単位の分割を**禁止はしない**（両立してよい）。
どちらの場合も**タスク単位には戻さない**。分岐の判定は1回だけ行い、その結果
（blast radius可否 / Phase分割の要否）を4観点すべてに同じように適用する。**観点別並列は
どの分岐でも維持する**（4本を同一メッセージで起動する構成は変えない）。

blast radiusを使う場合のプロンプト例（R1の基本形に1行加えるだけでよい。4観点それぞれに
同じ1行を加えて同一メッセージで起動する）:

```
@evaluator
Epic #$ARGUMENTS の全変更をレビューしてください。
- モード: epic-review
- 観点: correctness
- 差分範囲: main...[epic/epicXX/機能名]
- 変更ファイル数が50超のため、code-review-graphのblast radiusの算出を使って読む優先順位を付けてよい
- 最後に必ずJSONブロック（verdict / reviewed_commit / focus / findings）を出力すること

（readability / over-engineering / security も同様に3本続けて同一メッセージで起動する）
```

code-review-graphが未導入の場合（従来どおりPhase単位に分割する既存の回避策。Phaseごとに
4観点を同一メッセージで起動する）:

```
@evaluator
Epic #$ARGUMENTS のうち Phase 1 の変更をレビューしてください。
- 観点: correctness
- 差分範囲: main...[epic-branch] のうち [Phase1で変更されたファイル群]

（readability / over-engineering / security も同様。Phase 2 以降も同じ形で続ける）
```

