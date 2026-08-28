# 一括レビューの詳細（run スキル参照資料）

`skills/run/SKILL.md`「Epic一括レビュー」の R2 以降。**R1 が REQUEST_CHANGES を返したとき、または変更が 50 ファイルを超えたときにだけ読む。**

### R2: 指摘をissue化

evaluatorの出力末尾のJSONを読み、**high と medium の指摘だけ**をissueにする。
low は issue化せず、PR本文の「レビューで挙がった軽微な指摘」に列挙するだけに留める。

JSONのパースは**あなた（runの実行者）が直接行う。** `jq` は環境によっては入っていないため、
パイプラインで機械的に処理しようとしない。findingsを読み取り、1件ずつ以下を実行する:

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

## 由来
- Epic: #[epic番号]
- 起因タスク: [task_ref]
- レビュー時点: `[reviewed_commit]`
BODY
)"
```

`reviewed_commit` は次の delta-review の起点になるので、**必ず控えておく。**

作成したissueの番号一覧をEpic issueにコメントし、追跡できるようにする。

### R3: 指摘対応ループ

`APPROVE` なら何もせずPR作成へ進む。`REQUEST_CHANGES` の場合:

1. 作成した review issue を**1件ずつ** generator に渡して修正させる
   （通常のタスクと同じ自律ループの手順を通す。Step 1〜7）
2. 全件対応したら **delta-review** で再レビューする:

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

**レビューは最大2巡まで**（初回 + delta-review 1回。合わせてevaluator起動は最大3回）。

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
どちらの場合も**タスク単位には戻さない**。

blast radiusを使う場合のプロンプト例（R1の基本形に1行加えるだけでよい）:

```
@evaluator
Epic #$ARGUMENTS の全変更をレビューしてください。
- モード: epic-review
- 差分範囲: main...[epic/epicXX/機能名]
- 変更ファイル数が50超のため、code-review-graphのblast radiusの算出を使って読む優先順位を付けてよい
- 最後に必ずJSONブロック（verdict / reviewed_commit / findings）を出力すること
```

code-review-graphが未導入の場合（従来どおりPhase単位に分割する既存の回避策）:

```
@evaluator
Epic #$ARGUMENTS のうち Phase 1 の変更をレビューしてください。
- 差分範囲: main...[epic-branch] のうち [Phase1で変更されたファイル群]
```

