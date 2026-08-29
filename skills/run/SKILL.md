---
name: run
description: 承認済みのEpic issueに対して、Docker sandbox内でgenerator+evaluatorが完全自律で開発を進める。
argument-hint: "#[epic issue番号]"
disallowed-tools: AskUserQuestion
---

## 目的

承認済みの Epic issue $ARGUMENTS 配下の全Task issueを、Docker sandbox内でgenerator+evaluatorの2エージェント体制で完全自律的に完了させる。
全作業はEpicブランチ上で行い、mainブランチには直接変更を加えない。
**YOLOモード: ユーザー確認は一切行わず、完全自律で動作する。**

## パーミッション確認

YOLOモードで動作するためには、プロジェクトの `.claude/settings.json` で必要なBashコマンドが
`allow` に設定されている必要がある（推奨サンプルはREADME参照）。

- `deny` に `rm`, `rmdir`, `unlink` 等の破壊的コマンドを設定してブロック
- `allow` に `git`, `gh`, `docker`, ビルド・テスト系コマンドを設定して自動承認

未設定の場合、Bash実行のたびに「Do you want to proceed?」と確認が入り自律動作が中断される。

**ファイルツール（Read/Edit/Write）の権限について**: 本 run は Epic 専用 worktree を
`.claude/worktrees/<epicN>` に作る（後述）。この配下は**リポジトリルートの一部**なので、
`permissions.additionalDirectories` にリポジトリルート（例: `.../github/<repo>`）を1つ入れておけば
worktree もサブエージェントの isolation worktree も**追加設定なしで自動許可**され、確認が入らない。
逆に worktree を `../<repo>-epicN` のような**リポジトリ外の兄弟ディレクトリに作ると許可外**となり、
generator の Read/Edit のたびに確認が入る（＝自律動作が止まる）。だから worktree は必ず
`.claude/worktrees/` 配下に作る。

## 起動時の確認

**リポジトリ衛生プリフライトを最初に実行する。** git追跡された `.claude/settings.local.json`
がある状態でYOLOモードを回すと、自動追記された許可ルールがコミット候補になってしまう
（追跡されたpermission設定は `git clone` した全員に同意なく適用されてしまうため、issue #121）。
**exit 2 が返ったらrunを開始せず、ここで停止する。** 意図的に追跡されたまま続行する場合は
`DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS=1` を設定してから再実行する（opt-out）。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-repo-hygiene.sh" --run || exit 1
```

!`gh issue view $ARGUMENTS 2>/dev/null || echo "ERROR: issue $ARGUMENTS が見つかりません"`

!`gh issue list --label "task" --state open --json number,title,labels,body --limit 100 2>/dev/null | head -200`
### モデル構成の確認（オーケストレータ側）

run 本体（このスキルを解釈しているセッション）は Epic 全体を通して動き続ける、最も長寿命な
コンテキストである。ここを最上位モデルで固定するとコストがウェーブ数に比例して膨らむ。
**推奨は「本体は sonnet、難所だけ advisor(opus) に上げる」構成**である。ユーザーの
`~/.claude/settings.json` に次を推奨する（README「推奨 settings.json」参照）:

```json
{
  "model": "sonnet",
  "advisorModel": "opus",
  "effortLevel": "xhigh",
  "env": { "ENABLE_TOOL_SEARCH": "true" }
}
```

```bash
# 現在の構成を表示するだけ。未設定でも run は止めない（記録して進む）
grep -E '"(model|advisorModel|effortLevel)"' "$HOME/.claude/settings.json" 2>/dev/null \
  || echo "NOTE: ~/.claude/settings.json にモデル構成の記載なし（既定値で動作します）"
```

- **generator（sonnet）のモデルはエージェント定義側で固定されており、この設定の影響を
  受けない。** evaluatorは既定でsonnet（発見役）だが、確度判定役として起動する呼び出しだけ
  `model: opus`を起動時に上書きする（Task #157。詳細は`docs/adr/0006-evaluator-model-split.md`）。
  いずれもここで変わるのはオーケストレータ本体だけである
- `advisorModel` が未設定でも run は動作する。設定は推奨であって前提条件ではない

### Epicブランチ + 作業 worktree の準備

Epic issue本文の「ブランチ」セクションからブランチ名を取得し、**Epic 専用の作業 worktree を
`.claude/worktrees/<epicN>` に作成**する（`../<repo>-epicN` のような**兄弟ディレクトリは作らない**）。

なぜ `.claude/worktrees/` 配下か:
- **並行 epic 実行**が可能（各 epic が独立した worktree を持つ）。
- worktree パスが**プロジェクトツリー内**に収まるため、`.claude/settings.json` の
  `additionalDirectories` がリポジトリルートを許可していれば **追加の権限設定なしで**
  ファイルツール（Read/Edit/Write）が自動許可される。`github` 直下の**他リポジトリには一切及ばない**
  （兄弟ディレクトリ方式だと other-project へ権限が漏れる or 毎回プロンプトが出る）。
- メインリポのチェックアウトを切り替えないので、他の作業を壊さない。

```bash
# Epic issueからブランチ名を取得 (形式: epic/epicXX/[機能名])
EPIC_BRANCH=$(gh issue view $ARGUMENTS --json body -q '.body' | grep -oP '`epic/epic\d+/[^`]+`' | tr -d '`' | head -1)
EPIC_NUM=$(printf '%s' "$EPIC_BRANCH" | grep -oP 'epic\d+' | head -1)   # 例: epic259（sandbox-exec.sh の --epic 用の識別子）
EPIC_ISSUE_NUM="${EPIC_NUM#epic}"   # 例: 259（plan-waves.sh の --epic 用。数値のEpic issue番号。ブランチ名の命名規則epic/epicXX上、epicXXの数値部分=Epic issue番号）

# ブランチの存在確認
git fetch origin
git rev-parse --verify "origin/${EPIC_BRANCH}" >/dev/null 2>&1 || { echo "ERROR: ブランチ ${EPIC_BRANCH} が見つかりません"; exit 1; }

# ローカル追跡ブランチを用意（無ければ origin から作成）
git show-ref --verify --quiet "refs/heads/${EPIC_BRANCH}" || git branch "${EPIC_BRANCH}" "origin/${EPIC_BRANCH}"

# Epic 専用 worktree を .claude/worktrees/<epicN> に作成（既存なら再利用）
EPIC_WT=".claude/worktrees/${EPIC_NUM}"
if [ -d "$EPIC_WT" ]; then
  git -C "$EPIC_WT" checkout "${EPIC_BRANCH}" 2>/dev/null || true
else
  git worktree add "$EPIC_WT" "${EPIC_BRANCH}"
fi
```

**重要**: 以降の**すべてのステップ**（Docker 準備・タスクループ・generator/evaluator 起動・
commit/push・PR 作成・クリーンアップ）は、この `$EPIC_WT`（= `.claude/worktrees/<epicN>`）を
**作業ディレクトリ**として実行すること。**git コマンドは `cd "$EPIC_WT"` してから叩かず、
必ず `git -C "$EPIC_WT" ...` で対象を明示する**（`cd` 直後の git 実行は「未信頼な hooks が
走りうる」として承認プロンプトを誘発するため。issue #140）。`sandbox-exec.sh` /
`check-readability.sh` のように呼び出し元 cwd に依存するコマンドを叩く場合に限り
`cd "$EPIC_WT"` を使い、その直後に git を続けない。
**メインリポのチェックアウトを epic ブランチに切り替えてはならない**（兄弟 worktree も作らない）。

### 自律実行の開始を記録

Slack通知が「完全な完了」と「途中停止」を区別できるよう、ループ開始前にマーカーを置く:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify-slack.sh" run-start "Epic #$ARGUMENTS"
```

worktree内から実行してもマーカーはメインリポのルートに置かれるため、実行場所は問わない。

run マーカーが置かれた直後に、ハング・スリープを検知する watchdog を起動する（`--start`
自体は自己デタッチして**即座に返る**。監視ループはプロセス外で動く常駐プロセスに移る）。
watchdog は run マーカー（`.claude/.dev-workflow-run`）の消失を自己終了条件の1つにしているため、
**マーカーより後に起動すること**（先に起動するとマーカーがまだ無い一瞬で誤って自己終了しうる）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --start --epic "$EPIC_NUM" --label "Epic #$ARGUMENTS"
```

### Docker sandbox の準備

**まず作業 worktree に移動してから**、`sandbox-exec.sh` でサンドボックスを準備する（以降 `pwd` は
`$EPIC_WT`。マウント・イメージ解決はこの worktree を基点に行う）。

**`docker build` / `docker compose up` を直接叩いてはならない。** イメージのビルド・
コンテナの起動・compose サービスの起動はすべて `sandbox-exec.sh` に集約されている（後述）。
スキル側がやることは、`--print-plan` で解決結果を確認し、`--warm` を1回流すことだけである。

```bash
cd "$EPIC_WT"   # 以降の作業ディレクトリを Epic 専用 worktree に固定

# docker に一切触れず、解決結果（mode / container / image / compose_* 等）を表示する
PLAN="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --print-plan)"
echo "$PLAN"

if printf '%s\n' "$PLAN" | grep -q '^mode=none$'; then
  echo "ERROR: サンドボックス定義が見つかりません（mode=none）"
  echo "次のいずれかで供給してください（1・2 は駆動先リポジトリを汚しません）:"
  echo "  1. 規約パスに置く（推奨）: ~/.claude/dev-workflow/sandbox/<リポジトリ名>/Dockerfile.dev"
  echo "     （または同ディレクトリの docker-compose.dev.yml）"
  echo "  2. 環境変数で渡す: DEV_WORKFLOW_DOCKERFILE / DEV_WORKFLOW_DOCKER_COMPOSE_FILE / DEV_WORKFLOW_DOCKER_IMAGE"
  echo "  3. リポジトリ直下に置いてコミットする（チームで run を共有する場合のみ）"
  exit 1
fi

# キャッシュを温める（イメージが無ければここで自動ビルドされる。最初のタスクにビルドコストを負担させない）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --warm '[build-command]'
```

コンテナ内でコードをマウントし、全ての実装・テスト・ビルドコマンドをコンテナ内で実行する。
Gitオペレーション（commit, push等）はホスト側で実行する。

#### Epic 本文の任意節を取り込む

Epic 本文には `## 準備コマンド` / `## 共有ディレクトリ` / `## SKIPパターン` / `## 編集時チェック`
の4つの任意節を置ける。いずれも**節が無ければ空文字のまま**で、既存 Epic の挙動は変わらない。
各節の意味・書き方・レーンへの伝わり方は
[references/sandbox.md](references/sandbox.md) を参照する（**書き方に迷ったときだけ読む**）。

```bash
EPIC_BODY="$(gh issue view $ARGUMENTS --json body -q '.body')"
sect() { printf '%s\n' "$EPIC_BODY" | awk -v h="^## $1\$" '$0 ~ h {f=1; next} /^## /{f=0} f' \
  | sed -n '/^```/,/^```/p' | sed '1d;$d'; }

PREP_CMD="$(sect '準備コマンド')"
SHARED_DIRS="$(sect '共有ディレクトリ')"
SKIP_PATTERN="$(sect 'SKIPパターン')"
EDIT_CHECK="$(sect '編集時チェック')"
EPIC_WT_ABS="$(cd "$EPIC_WT" && pwd)"

# 準備コマンドがあれば Epic 専用 worktree で1回だけ流す（キャッシュを温め、統合ゲート用の生成物を置く）
[ -n "$PREP_CMD" ] && bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --warm "$PREP_CMD"

# 編集時チェックの仕様をマーカーファイルへ書く（PostToolUseフックはBashツール越しのexportを
# 受け取れないため、ファイル経由で渡す。edit-check.sh --write/--clear が原子的に書き換える）。
# 節が無ければ --clear し、前回Epicの内容が残留しないようにする
if [ -n "$EDIT_CHECK" ]; then
  printf '%s\n' "$EDIT_CHECK" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/edit-check.sh" --write
else
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/edit-check.sh" --clear
fi
```

`$PREP_CMD` / `$SHARED_DIRS` / `$SKIP_PATTERN` / `$EPIC_WT_ABS` は Step 3 のレーンプロンプトと
Step 6 の統合ゲートで使うので、変数として保持しておく。`$SKIP_PATTERN` は両方へ
`DEV_WORKFLOW_SKIP_PATTERN` として渡す（Epic 本文の `## SKIPパターン` 節に由来する）。
`$EDIT_CHECK` はマーカーファイルへの書き込みだけで完結し、Step 3 のレーンプロンプトへの
埋め込みは不要（PostToolUseフックが編集のたびに自動発火するため、generator 側の対応は無い）。

### サンドボックスへのコマンド投入は sandbox-exec.sh 経由に統一する

**`docker build` / `docker compose up` / `docker run` を直接叩いてはならない。** イメージ解決・
ビルド・キャッシュ永続化・コンテナ再利用・Windows のパス変換対策はすべて
`scripts/sandbox-exec.sh` が引き受ける。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" 'make test'
```

終了コードは実行したコマンドのものがそのまま返るので、機械的ゲートの判定に使える。
compose を使う場合の要求仕様（常駐サービス名・マウント・`container_name` 禁止など）は
[references/sandbox.md](references/sandbox.md) を参照する。
## 2エージェント体制

| エージェント | 役割 | 起動頻度 | 判断権限 |
|-------------|------|----------|----------|
| **generator** | Docker内でコード実装・テスト・コミット | **レーンごと**（1レーンで複数タスクを連続処理） | 実装方針の判断 |
| **evaluator** | Epic全差分の一括レビュー | **Epicにつき1〜3回** | APPROVE / REQUEST_CHANGES |

### レビューはEpic単位でまとめて行う

**タスクごとにevaluatorを起動してはならない。** レビューは最もコストの高い工程であり、
タスクのたびにOpusで全文脈を読み直すとレビュー費用が実装費用を上回る。

代わりに:

1. **タスクごと**は機械的ゲート（テスト・ビルド・可読性ガード）だけで通す — LLM呼び出しなし
2. **全タスク完了後**にevaluatorを1回起動し、`main...epicブランチ` の全差分をレビュー
3. 指摘は**個別のissueに変換**し、generatorが対応する
4. 対応後は**その差分だけ**を再レビュー（最大2巡）

これにより、evaluatorの起動回数はタスク数に比例せず、Epicあたり1〜3回に固定される。

### 機械的ゲートの三段構成

フルスイートを「タスクごと」「ウェーブごと」の両方で走らせてはならない。1レーンが複数
タスクを連続処理する以上、レーン内のフルスイートはレーン内で**直列に積み上がる**。同様に
ウェーブごとのフルスイートも「ウェーブ数 × フルスイート時間」の直列区間になる。
**フルスイートは Epic につき1回、全ウェーブ完了後（Epic一括レビューの前）に集約する。**
検証点は次の3段に分離する。

| 検証点 | 対象ツリー | 実行するもの | 頻度 |
|---|---|---|---|
| **レーン内ゲート** | generator の isolation worktree | **変更範囲のテスト**（そのタスクが触った領域を実際に走らせる） | タスクごと |
| **ウェーブ末の取り込み検証** | wave ブランチ（全レーン取り込み後） | merge-base 完全一致検証（`merge-lane.sh`）＋可読性ガード | ウェーブごとに1回 |
| **Epic 統合ゲート** | Epic ブランチ | **プロジェクトの全テスト＋可読性ガード** | **Epic につき1回**（全ウェーブ完了後） |

- 「回帰なし」を宣言できるのは**Epic 統合ゲートだけ**である。generator は自分の報告で「回帰なし」と
  書いてはならない（`core/roles/generator.md`「回帰確認の分担」参照）
- レーン内ゲートは高速フィードバックのための関門であり、無関係な領域の回帰は拾わない。
  拾う責務は Epic 統合ゲートにあり、失敗した場合の原因ウェーブの特定手順は
  [references/recovery.md](references/recovery.md) にある（**失敗したときにだけ読む**）
- **タスクごと**は機械的ゲートだけで通す — LLM 呼び出しは行わない
- **トレードオフ**: 回帰の検知が Epic 末まで遅れる。ウェーブ内の自動の安全網はレーン内ゲート・
  マージ健全性チェック・可読性ガードだけになり、Epic ブランチに「フルスイート未通過のコミット」
  が一時的に載りうる（従来の不変条件「Epic ブランチには統合ゲートを通ったコミットだけが載る」は
  変わる）。これは実行時間短縮のための意識的な選択であり、main への取り込みは人間の PR レビューを
  通ること、Epic 統合ゲートが Epic につき1回必ず実行されることが前提である
  （詳細は `docs/adr/0001-integration-gate-at-epic-end.md`）

## ブランチ戦略

```
main (保護: 人間のみマージ可)
 └─ epic/epicXX/[機能名] (Epic単位のブランチ。ウェーブ取り込み後、Epic統合ゲートを経てPR化される)
     └─ 作業 worktree: .claude/worktrees/epicXX/  ← このツリー内で全作業（許可済み領域・兄弟ディレクトリは作らない）
         └─ wave/epicXX/<ウェーブ番号>  ← レーンを取り込み取り込み検証に掛ける一時ブランチ（originへpushしない）
             └─ 各レーンの作業ブランチ（generator の isolation worktree 由来）
```

- Epic 専用 worktree は **`.claude/worktrees/<epicN>`** に作る（`../<repo>-epicN` の兄弟は作らない）。additionalDirectories はリポジトリルート許可で足り、他リポジトリに権限が及ばない。
- 各レーン（generator の isolation worktree）が実装着手前に自分のHEADを合わせるべき唯一の
  正しい基準点が、そのウェーブ開始時点のEpicブランチtip（`WAVE_BASE`）である。isolation
  worktree を作るのは**ハーネス**であり、その分岐元はハーネスが決めるため WAVE_BASE とは
  限らない。そのため generator は `git merge --ff-only "$WAVE_BASE"` で自分の HEAD を明示的に
  合わせてから実装に着手する（`git reset --hard` は一般的な安全設定でブロックされるため
  使わない。Step 3 のプロンプト雛形参照）
- レーンは wave ブランチを経由し、**ウェーブ末の取り込み検証（merge-base 完全一致検証＋
  可読性ガード）通過後にのみ** `--ff-only` でEpicブランチへ合流する。**プロジェクトの
  全テストはここでは走らせない**（Epic統合ゲートへ集約する。「機械的ゲートの三段構成」参照）
- 実装・テスト・ビルドは全てDockerコンテナ内で実行する
- 全タスク完了後、Epic統合ゲート（全ウェーブ完了後にEpicにつき1回、プロジェクトの全テスト＋
  可読性ガード）を実行し、Epicブランチ→mainのPRを作成する
- mainへのマージは人間が行う
- wave ブランチはローカルの一時ブランチであり、originへはpushしない。**Epicブランチへのforce pushは行わない**

## タスク選定・実行方式（ウェーブ単位の並列実行）

plannerは介在しない。タスクの実行順序は`- 前提: #N`が作る**依存グラフだけ**を根拠に決める
（`core/instructions.md`「タスク選定順序」参照）。Phaseは人間向けの区分であり、実行順序の決定には
使わない。ウェーブ分解は `scripts/plan-waves.sh` に切り出されており、散文としてこのスキルが
解釈し直すことはしない。

```bash
# ドライラン: 現在のウェーブ分解を人間向けに確認する（依存宣言のレビューにも使える）
# plan-waves.sh の --epic は数値のEpic issue番号（$EPIC_ISSUE_NUM）。sandbox-exec.sh の
# --epic（epicXX形式の $EPIC_NUM）とは別の契約なので取り違えないこと
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh" --epic "$EPIC_ISSUE_NUM" --lanes "$LANES" --print
```

### `--lanes`（並列度）の受け取り

- 既定は **3**。`$ARGUMENTS` に `--lanes N` が含まれていればそれを使う。無ければ環境変数
  `DEV_WORKFLOW_MAX_LANES` を使う。どちらも無ければ既定の3を使う（優先順位: `--lanes` 引数 >
  `DEV_WORKFLOW_MAX_LANES` > 既定3）
- **ホスト性能からの自動算出はしない**（ボトルネックはI/Oでありコア数と相関しないため）
- **`--lanes 1` を指定すると、現行（並列化前）と等価な逐次実行になる。** 障害発生時のロール
  バック手段として使える。並列用と逐次用でコードパスを分けていないため、値を変えるだけで
  安全に落とせる

```bash
LANES="${DEV_WORKFLOW_MAX_LANES:-3}"
# $ARGUMENTS に --lanes N が含まれていれば LANES をその値で上書きする
```

## 自律ループ（YOLOモード、ウェーブ単位）

**ユーザー確認なしで**、以下のサイクルをウェーブが無くなるまで繰り返す。

```bash
SKIPPED_CSV=""   # 3回失敗して見送ったタスク番号のカンマ区切り。ループを回すうちに積み上げる

# ウェーブ差分の先行レビュー（wave-review）用。詳細は references/wave-review.md を参照
# （読むタイミング: wave-reviewの起動条件・REVIEWED_COMMITの更新規則を確認したいとき）。
# ベースブランチを master/main に決め打ちしない（dev-workflow自身のデフォルトブランチが
# masterであっても、それを駆動先の値として埋め込んではならない。references/review.md と
# 同じ方法で解決する）。
BASE_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
BASE_BRANCH="${BASE_BRANCH:-main}"
REVIEWED_COMMIT="$(git merge-base "$BASE_BRANCH" "${EPIC_BRANCH}")"   # 「そこまではレビュー済み」の地点
# 解決・merge-baseのいずれかに失敗した場合（REVIEWED_COMMITが空）はwave-reviewを起動しない。
# REVIEWED_COMMITを進めずEpic末レビューに委ねる（詳細はreferences/wave-review.md）。
PREV_WAVE_INCORPORATED=false   # このrunセッション内で直前のウェーブをEpicへ取り込んだか

# WAVE_NO: wave ブランチ名（wave/${EPIC_NUM}/${WAVE_NO}）に使う通し番号。
# plan-waves.sh の出力の「wave番号」とは別物（再計算のたびに wave 1 から始まり直すため、
# 通し番号はここで自前に管理する）。
#
# 0 から始めてはならない（Task #54）。中断→再開（`/dev-workflow:run` の再実行）では
# セッション変数が失われるため 0 から数え直すことになるが、`wave/${EPIC_NUM}/*` ブランチは
# ローカルに残り続ける（originへpushしない設計）。0 から始めると、前回の残骸である古い
# wave ブランチをそのまま掴んでしまい、`merge-lane.sh --create` がそれを「取り込み済み」と
# 誤認する（詳細は references/troubleshooting.md の「再開する場合」を参照）。
# 既存の wave ブランチの番号の最大値の次から始めることで、再開時も必ず新しい wave ブランチが
# 使われる。
WAVE_NO=$(git for-each-ref --format='%(refname:short)' "refs/heads/wave/${EPIC_NUM}/*" \
  | sed "s#^wave/${EPIC_NUM}/##" | sort -n | tail -1)
WAVE_NO="${WAVE_NO:-0}"

# --- 計測（並列化とオーバーヘッド削減の寄与を分けて読むための実測。表示形式は references/progress-display.md） ---
# 前ウェーブの内訳（次ウェーブ開始時のバナー表示に使う）。ウェーブ1の開始時点では空文字のまま。
# GATE_SEC はウェーブ単位では計測しない（フルスイートをEpic末に集約したため。MERGE_SECに
# 可読性ガードの所要時間を含める）。Epic統合ゲートの所要時間は EPIC_GATE_SEC として
# 「Epic 統合ゲート」節でEpicにつき1回だけ計測する。
PREV_WAVE_IMPL_SEC=""
PREV_WAVE_MERGE_SEC=""
# Epic全体の累計（PR本文の集計に使う）
TOTAL_IMPL_SEC=0
TOTAL_MERGE_SEC=0
DONE_TASK_COUNT=0   # ウェーブ末の取り込み検証を通過して取り込めたタスク数の累計

# 秒数を "Nm Ss" 形式にする（例: 65 -> 1m05s）。追加の依存物（jq等）は使わず `date +%s` の差分のみで計測する
fmt_duration() {
  local total_sec="$1"
  printf '%dm%02ds' "$((total_sec / 60))" "$((total_sec % 60))"
}
```

### Step 1: ウェーブ計画を取得する

**毎ウェーブ、計画を再計算する**（前ウェーブの完了・スキップを反映するため。1回だけ計算して
使い回さない）。完了したタスクは `gh issue list --state open` から自然に消えるため、
再計算のたびに残りのタスクだけを対象とした**新しいウェーブ1**が得られる。
すなわち、**出力の `wave 1 tasks ...` が常に「次に実行すべきウェーブ」である。**

```bash
cd "$EPIC_WT"
PLAN_ARGS=(--epic "$EPIC_ISSUE_NUM" --lanes "$LANES")
[ -n "$SKIPPED_CSV" ] && PLAN_ARGS+=(--skipped "$SKIPPED_CSV")
PLAN="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh" "${PLAN_ARGS[@]}")"
PLAN_EXIT=$?
echo "$PLAN"
```

- `PLAN_EXIT` が **3**（循環依存）なら、列挙されたタスクをそのままEpic issueにコメントし停止する
- `warn missing-deps <番号>` / `warn unknown-dep <番号> <dep番号>` が出力に含まれる場合、
  該当タスクの宣言漏れ・不明な依存を報告に含める（fail-safeで完全逐次扱いになっている旨も明記）
- `warn missing-deps-summary <件数> <対象タスク数> <実効並列度> <指定lanes>` が出力に含まれる場合、
  この集計行（宣言漏れの件数・実効並列度が指定lanesからどれだけ落ちたか）も報告に含める
- 出力に `wave` 行が無い（＝全タスク完了）→ ループを終了し **「Epic一括レビュー」** へ進む
- `wave 1 tasks 4,5,10` のような行から、今回処理するタスク番号の集合を取り出す。各タスクの
  `subbatch` 列（`task` 行）を見て、**レーンへ割り当てる**: レーン L には各サブバッチの
  L 番目のタスクが順に入る（Step 3 参照）。**サブバッチ単位に分割して逐次実行してはならない**
- 処理対象のウェーブが決まったら `WAVE_NO=$((WAVE_NO + 1))` する（wave ブランチ名
  `wave/${EPIC_NUM}/${WAVE_NO}` に使う通し番号。plan-waves.sh の出力の「wave番号」とは別物）

今回のウェーブの内容が決まったら、Step 2 に進む前に進捗バナーを表示する（形式は
references/progress-display.md を参照。`PREV_WAVE_*` はウェーブ1の実行前は空文字なので「前ウェーブ: (初回のため計測なし)」
と表示する）。

### Step 2: WAVE_BASE を記録する

```bash
# cd してから git を叩かない（cd 直後の git 実行は「未信頼なフックが走りうる」として
# 承認プロンプトを誘発する。git -C で対象 worktree を明示する。issue #140）
git -C "$EPIC_WT" fetch origin
git -C "$EPIC_WT" checkout "${EPIC_BRANCH}"
git -C "$EPIC_WT" pull origin "${EPIC_BRANCH}"
WAVE_BASE=$(git -C "$EPIC_WT" rev-parse HEAD)
IMPL_START_SEC=$(date +%s)   # 「実装」フェーズ（Step 3〜4）の計測開始
```

ウェーブ予算の監視（watchdog）に、このウェーブの内訳を伝える:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --wave --epic "$EPIC_NUM" \
  --wave-no "$WAVE_NO" --tasks "[今回のウェーブのタスク番号のカンマ区切り]"
```

**同期はここ（ウェーブの先頭）でだけ行う。** タスクごとには行わない。この `WAVE_BASE` が、
このウェーブに属する全レーンが実装着手前に自分のHEADを合わせるべき唯一の正しい基準点になる。
**各レーン（generatorのisolation worktree）の分岐元はハーネスが決めるため、WAVE_BASEとは
限らない。** そのため generator は実装着手前に `git merge --ff-only "$WAVE_BASE"` の1コマンドで
自分のHEADをWAVE_BASEへ明示的に合わせる（Step 3のプロンプト雛形参照）。**`git reset --hard` は
使わない**（一般的な安全設定でブロックされる代表的なコマンドであり、実際に本Epicのウェーブ2で
全レーンがこれにより着手不能になって停止した実績がある。`merge --ff-only`は破壊的でないため
ブロックされにくく、isolation worktreeの分岐元はWAVE_BASEの祖先であるためfast-forwardは
必ず成功する）。この1コマンドを除き、generator自身は `fetch` / `checkout` / `pull` を行わない
（`core/roles/generator.md`）。

### Step 3: レーンにタスク列を割り当て、generator を並列起動する

**サブバッチによるバリア同期は行わない。** ウェーブ内のタスクは互いに独立している
（依存があれば別ウェーブになる）ため、順序制約は無い。ウェーブ内の全タスクを `LANES` 本の
レーンへ分配し、**各レーンが自分のタスク列を同一 worktree で連続処理する。**

- 分配は Step 1 で得た `subbatch` 列をそのまま使う。**レーン L には、各サブバッチの L 番目の
  タスクが順に割り当てられる**（例: lanes=3、タスク #4,#5,#10,#11,#12 → A=#4,#11 / B=#5,#12 / C=#10）
- 1レーンが複数タスクを持つ場合、generator は**エージェントを作り直さず**、同じ worktree・
  同じコンテキストのまま次のタスクへ進む。ベース合わせ・準備コマンド・共有ディレクトリの
  セットアップは**レーンの先頭（＝自分の作業ディレクトリで初回1回だけ）**行う
- これによりタスク2件目以降の cold start（system prompt の読み直し・リポジトリの再調査）が
  消える。従来のサブバッチ方式が持っていた「サブバッチごとに全レーンの完了を待つ」バリアも
  同時に消える

レーンは**同一メッセージで同時に起動する**（レーンA・B・C…）:

```
@generator
レーン A を担当してください。割り当てられたタスクは次のとおりです（**この順に連続処理する**）:
  #[番号A1] → #[番号A2] → …
- Epicブランチ: [epic/epicXX/機能名]
- WAVE_BASE: [WAVE_BASEのコミットハッシュ]（ブランチ名ではなくこのハッシュそのものに対して検証すること）
- **あなたの isolation worktree の分岐元は WAVE_BASE とは限らない**（worktree を作るのは
  ハーネスであり、分岐元はハーネスが決める）。**レーンの先頭で1回だけ**、次をこの順に実行して
  HEAD を WAVE_BASE に合わせること。**2件目以降のタスクでは再実行しないこと**
  （再実行すると積んだコミットが失われる）。**証跡はファイルに書き出し、報告にはパスと
  1行の判定だけを載せること**（Task #156。自己申告にしないという意図は変わらない。
  実在するファイルとして `grep`/`cat` で機械的に検証できる）:
  ```bash
  BASE_EVIDENCE_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-lane-evidence.XXXXXX")"
  ```
  1) `{ echo '$ git status --short'; git status --short; } | tee -a "$BASE_EVIDENCE_FILE"`
     （空であることを確認。空でなければ着手せず、`$BASE_EVIDENCE_FILE` のパスを添えて報告し停止すること）
  2) `{ echo '$ git merge --ff-only "[WAVE_BASE]"'; git merge --ff-only "[WAVE_BASE]"; } | tee -a "$BASE_EVIDENCE_FILE"`
     （HEADをWAVE_BASEに合わせる。fetch/checkout/pullではないためネットワーク不要。
     isolation worktreeの分岐元はWAVE_BASEの祖先であるためfast-forwardは必ず成功する。
     **失敗した場合は自力で直そうとせず、`$BASE_EVIDENCE_FILE` のパスを添えて報告し停止すること**）
  3) `{ echo '$ git merge-base --is-ancestor "[WAVE_BASE]" HEAD && echo BASE_OK'; git merge-base --is-ancestor "[WAVE_BASE]" HEAD && echo BASE_OK; } | tee -a "$BASE_EVIDENCE_FILE"`
     （偽なら着手せず、`$BASE_EVIDENCE_FILE` のパスを添えて報告し停止すること）
  4) `{ echo '$ git log --oneline -1'; git log --oneline -1; } | tee -a "$BASE_EVIDENCE_FILE"`
     （実際のHEADが証跡に残る）
  報告には `ベース検証: [OK|NG] evidence=[BASE_EVIDENCE_FILEのパス]` の1行だけを書くこと。
  実出力そのものをチャットへ貼り直さないこと
- **`git fetch` / `git checkout` / `git pull` / `git reset --hard` は実行しないこと。** 同期は
  run が Epic 専用 worktree で既に済ませている。手順2の `git merge --ff-only` のみが例外として
  許可されている。**`git reset --hard` は使わないこと**（一般的な安全設定（permission deny の
  代表的な対象）でブロックされ、実際に本Epicのウェーブ2で全レーンが着手不能になった）
- サンドボックスへのコマンド投入は `${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh` 経由で行い、
  ビルド・テストは1回の呼び出しにまとめること（分けると待ち時間が倍増する）
- `sandbox-exec.sh` を呼ぶ際は必ず `--epic "$EPIC_NUM"` を渡すこと（例: `--epic "$EPIC_NUM" 'make test'`）
- **サンドボックスに渡すコマンドの中で `cd` して作業ディレクトリを変えないこと。**
  `sandbox-exec.sh` は呼び出し元cwdから workdir を解決するため、`cd` はそれを上書きし、
  自分の変更を含まないツリーを検証してしまう（サブディレクトリだけを対象にしたい場合は
  `cd` ではなく `make -C sub test` のようにコマンド側の相対指定で行うこと）
- （`$SHARED_DIRS` が**空でない**場合のみ、次のブロックを出す。準備コマンドを直接実行させる
  行の**代わり**に出すもので、下の「`$SHARED_DIRS` が空の場合」のブロックとは排他）
  共有ディレクトリ（Epic本文の `## 共有ディレクトリ` 節）が宣言されているため、次を
  **自分の作業ディレクトリで初回1回だけ**実行してから実装に入ること:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/share-prepared-dirs.sh" --epic "$EPIC_NUM" \
    --source "[EPIC_WT_ABSの内容]" \
    --spec '[SHARED_DIRSの内容]'
  ```
  （`$PREP_CMD` が空でない場合のみ、上のコマンドに `--run-prep '[PREP_CMDの内容]'` を追加する。
  `$PREP_CMD` が空の場合は `--run-prep` 自体を付けない）
  - 出力の各行と `prep=` 行を `$BASE_EVIDENCE_FILE` に追記し（`>> "$BASE_EVIDENCE_FILE"`）、
    報告には `準備: [prep=の値] evidence=[BASE_EVIDENCE_FILEのパス]` の1行だけを書くこと
    （自己申告にしない。実出力はファイルに残す）
  - **exit 3**（ロック競合）が返った場合、2本目を起動せず、その事実を報告して停止すること
  - **exit 4**（`--run-prep` に渡したコマンドの失敗）が返った場合、実装に進まず、その事実を
    報告すること
  - **`prep=run`**（共有できなかった）場合でも、**自前で準備コマンドを追加実行しないこと**
    （`--run-prep` を渡していればスクリプトが既に実行している）
  - **依存マニフェスト（`package.json` / lockfile 等）を変更するタスクでは**、install 系の
    コマンドを実行する前に次を1回実行し、共有リンクを解除してから自前で install すること
    （解除せずに install すると、共有元である Epic 専用 worktree と他レーンの成果を壊す）:
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/share-prepared-dirs.sh" --detach --dir <共有ディレクトリ名>
    ```
  - **同一worktree内で2回目以降は実行しないこと**（1レーンで複数タスクを扱うため、
    2件目以降のタスクでは必ず省略する）

- （`$SHARED_DIRS` が**空**の場合は現行どおり。`$PREP_CMD` が空でない場合のみ、次の行を
  追加する。空の場合はこの行を出さない。既存の Epic に後方互換）プロジェクト固有の準備コマンド
  （Epic本文の `## 準備コマンド` 節の内容をそのまま埋め込む）:
  [PREP_CMDの内容をそのまま貼り付ける]
  これを**自分の作業ディレクトリで初回1回だけ**実行してから実装に入ること。Epic開始時に run が
  実行した1回は Epic 専用 worktree にしか効かず、レーンの作業ディレクトリ（isolation worktree）
  には及ばないため、この実行が別途必要になる。**同一worktree内で2回目以降は実行しないこと**
  （1レーンで複数タスクを扱う場合を含む）。1回実行しても効いていないと判断した場合も自前で
  追加実行せず、その事実を報告すること
- **回帰確認はあなたの責務ではない。** 各タスクで走らせるのは**そのタスクの変更範囲のテスト**
  （変更したファイルが属するパッケージ／モジュール単位）であり、プロジェクトの全テストではない。
  全テストは run がウェーブごとに統合ゲートで1回だけ走らせる。報告には「変更範囲のテストが
  通った」とだけ書き、**「回帰なし」と書かないこと**。変更が共通基盤に及ぶなど広範だと判断した
  場合に限り全テストを走らせてよく、そのときは判断根拠を報告に書くこと
- **SKIP件数は `tail` の目視ではなく `scripts/count-skips.sh` で機械的に数えること。**
  **証跡はファイルに書き出し、報告にはパスと1行の判定だけを載せること**（Task #156）。
  テスト出力を証跡ファイルへ保存し、そのファイルに続けて機械可読なトレーラ（`key=value`
  1行1項目）を追記する。**並列レーンが同じ固定パスへ `tee` すると他レーンの出力を
  上書きし合うため、`mktemp` で一意な一時ファイルを作ってから使うこと**（issue #145）:
  ```bash
  EVIDENCE_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-lane-evidence.XXXXXX")"
  TASK_START_EPOCH="$(date +%s)"; TASK_START_HM="$(date +%H:%M)"
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" '[変更範囲のテストコマンド]' \
    2>&1 | tee "$EVIDENCE_FILE"
  SKIP_OUT="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/count-skips.sh" --file "$EVIDENCE_FILE")"
  TASK_END_EPOCH="$(date +%s)"; TASK_END_HM="$(date +%H:%M)"
  {
    echo "---"; echo "task=[番号]"; echo "lane=[記号]"; echo "status=success";
    echo "start_epoch=${TASK_START_EPOCH}"; echo "end_epoch=${TASK_END_EPOCH}";
    echo "start_hm=${TASK_START_HM}"; echo "end_hm=${TASK_END_HM}";
    echo "duration_sec=$((TASK_END_EPOCH - TASK_START_EPOCH))"; echo "$SKIP_OUT";
  } >> "$EVIDENCE_FILE"
  ```
  （`$SKIP_PATTERN` が空でない場合のみ、`count-skips.sh` を呼ぶ前に次を実行する。
  空の場合はこの行を出さない）
  このプロジェクトのテスト出力は built-in ランナー（go/jest/pytest）と形式が異なるため、
  `count-skips.sh` を呼ぶ前に次を実行してから数えること:
  `export DEV_WORKFLOW_SKIP_PATTERN='[SKIP_PATTERNの内容]'`
  - `skips=<件数>`（exit 0）→ 報告の1行にその件数を書く。想定外のSKIPは不合格として扱う
  - `skips=unknown`（exit 1）→ **報告の1行に「0件」と報告してはならない。** built-inランナー
    以外の形式のため数えられなかった事実と、`DEV_WORKFLOW_SKIP_PATTERN`（Epic本文の
    `## SKIPパターン` 節）の設定が必要である旨を報告すること。この場合に限り、
    `tail` ではなく `$EVIDENCE_FILE` の生のテスト出力全体を自分の目でも確認すること
- issueの要件を確認し、Task issueの記載だけで着手できない場合に限り親Epic issueの本文を参照すること
- テストファーストで実装し、**タスクごとに独立したコミットを積むこと**（タスクをまたいで1つの
  コミットにまとめない）
- **1件のタスクに失敗しても、そのタスクだけを見送って次のタスクへ進むこと。**
  見送るときは `git restore --source=HEAD --staged --worktree -- :/` で追跡ファイルを直前の
  成功コミットの状態へ戻し、`git status --short --untracked-files=all -- :/`（削除はしない）で
  残る未追跡ファイルを報告してから次へ進むこと。その実出力を `$EVIDENCE_FILE` に追記すること
  （レーン全体を投げ出さない）。**`git reset --hard` / `git clean` はベース合わせと同じ理由で
  `permissions.deny` にブロックされうるため（`git clean` はフラグに関わらずコマンド名の
  前方一致でブロックされうるため、dry-runの `-nd` を付けても対象になる）、ここでも使わない
  こと。`-- :/` は cwd 相対にならず常にリポジトリ全域を対象にするために必須（省略すると
  サブディレクトリから実行した際に他所の変更・未追跡ファイルが戻らない／報告されないまま
  「残留なし」という誤った証跡が残る）。`--untracked-files=all`（`-uall`）も必須
  （`status.showUntrackedFiles=no` のようなローカル設定を上書きしないと、未追跡ファイルが
  隠れたまま「残留なし」という誤った証跡が残る）**
- 報告は**タスク1件につき1行**とし、レーン先頭のベース検証行を1回だけ添えること。
  各行には**必ず**次の5項目を含めること: **タスク番号 / 成功・見送り / SKIP件数 /
  所要秒数 / 証跡ファイルのパス**（例:
  `Task #[番号]: success skips=[件数|unknown] duration_sec=[秒数] evidence=[EVIDENCE_FILEのパス] commit=[ハッシュ]`。
  見送りの場合は `見送り` に変え `理由=[短い要約]` を添える）。
  対象とした変更範囲・実際に叩いたテストコマンドの全文など5項目に収まらない情報は
  `$EVIDENCE_FILE` に追記し、チャットへ長文で貼り直さないこと。
  レーンの末尾に「レーン記号（A）」「最終的な作業ブランチ名」「成功／見送りのタスク番号」を
  1回だけ書くこと（作業ブランチ名は Step 5 の merge-lane.sh で使う）

@generator
レーン B を担当してください。割り当てられたタスクは #[番号B1] → #[番号B2] → … です。
（内容はレーンAと同様。WAVE_BASE は同じハッシュを渡す）
```

Claude Code のサブエージェントは**バッチ全員が終わるまで結果が返らない**ため、動的なレーン
補充は原理的に実装できない。ウェーブの所要時間は**最長レーン（そのレーンのタスク列の合計）**で
決まる。これは harness の制約として受け入れる。

#### レーンはウェーブをまたいで維持されない（Task #153の検証結果。Task #152で記述を訂正）

上記は**バッチ内**（同一ウェーブの実行中）の制約である。これとは別に、**バッチ間**（ウェーブが
変わるたびにレーン＝generatorを作り直さず継続させられないか）を Task #153 が検証した。当時は
「このエージェント自身（Task tool で起動された generator）に割り当てられたツール一覧に、
既に完了したサブエージェント呼び出しへ後から追加のメッセージを送って継続させる手段が見当たら
なかった」ことを根拠に「Claude Code にはその手段が無い」と結論したが、**この結論は誤りだった**
（Task #152 が訂正）。Claude Code には `SendMessage` ツールが実在し、`Agent` ツールの説明にも
既存サブエージェントをコンテキストを保持したまま継続させられる旨が明記されている。ただし
`SendMessage` は**オーケストレータ（run）側のツール**であり、generator 自身の道具箱に無かった
ことは根拠として誤っていた。**とはいえ本 Epic では実際に `SendMessage` によるレーン継続を
実装・実地検証してはいない。** そのため機構としては存在するが未検証であることを理由に、
**レーンはウェーブごとに新規 spawn する現行の方式のまま**とし、本 Epic では実装を見送る。
検証の詳細と判断理由は `docs/adr/0004-cross-wave-lane-reuse.md` を参照する。この結果、Step 2 で
記録する `WAVE_BASE` へのベース合わせ（`git merge --ff-only`）は、常に「レーンの先頭（＝各
ウェーブで新規 spawn された直後）で1回だけ」のままであり、タスク境界／ウェーブ境界という区別は
生じない（レーンがウェーブをまたいで生存する場合にのみ意味を持つ区別のため）。

#### 同一メッセージで前ウェーブの wave-review を起動する（`PREV_WAVE_INCORPORATED` が true のときのみ）

**バッチ全員が終わるまで結果が返らない**という上記の制約は、逆に言えば**同一バッチに含めれば
並行に走る**ということでもある。この性質を使い、直前のウェーブが Epic ブランチへ取り込まれた
直後の差分（`REVIEWED_COMMIT..WAVE_BASE`）を、**レーン起動と同一メッセージで** evaluator に
先行レビューさせ、次ウェーブの実装と並行させる。レーンの動的補充（バッチ内の話）とは別の、
**バッチ間（ウェーブ間）の並行化**であることに注意する。

`PREV_WAVE_INCORPORATED` が `false`（このrunセッションでまだ一度もウェーブを取り込んでいない、
最初のウェーブ）の間は wave-review を起動しない。起動条件・`REVIEWED_COMMIT` の初期値と更新・
指摘の扱いの詳細は [references/wave-review.md](references/wave-review.md) を参照する
（**wave-reviewを起動する段になったら読む**）。

```
@evaluator
Epic #$ARGUMENTS のウェーブ差分を先行レビューしてください。
- モード: wave-review
- 差分範囲: [REVIEWED_COMMIT]..[WAVE_BASE]
- 作業ディレクトリ: .claude/worktrees/[epicN]
- 指摘はその場で直させない。high/mediumはissue化のためJSONで返すだけでよい
- 最後に必ずJSONブロック（verdict / reviewed_commit / findings）を出力すること
```

### Step 4: レーン内ゲートの結果を確認する

各 generator は自分の isolation worktree 内で、タスクごとの完了報告（**変更範囲のテスト**結果）を
返す。**レーン内ゲートはフルスイートではない**（理由は「機械的ゲートの三段構成」節）。

- レーン内ゲートに失敗したタスクは wave へ取り込まれない（generator が commit を積んでいない）。
  試行回数を保持したまま次ウェーブへ持ち越す
- **レーン内の一部のタスクが失敗しても、そのレーンの成功分は取り込む。** レーンごと捨てない
- **「コミット0件だが作業ツリーに未コミットの変更が残っている」レーンは、通常の失敗と区別し
  「未完」として報告に記録する**（issue #138。generator がサンドボックス実行の完了通知を待つと
  誤認してターンを終えた場合に起こる。実装自体は揃っていることが多い）。**ただしウェーブ内では
  再試行しない**（`core/instructions.md`「失敗時の扱い」の規定どおり。バリア同期のため、
  ウェーブ内の再試行は完了済みの他レーンを待たせ続けるだけになる）。isolation worktree は
  ハーネスが generator の spawn ごとに新規作成するため、**次ウェーブでは新しい worktree が
  作られ、旧worktreeの未コミットの変更は引き継がれない**（引き継ぐ機構は存在しない。
  `core/roles/generator.md`「レーンの先頭はウェーブごとに新規spawnされた自分自身の先頭を指す」
  参照）。そのため「未完」の区別は**作業の保存**のためではなく、**同じ失敗を次ウェーブで
  繰り返させないため**に使う: 次に計算されるウェーブへは、該当タスクの issue が開いたままの
  ため通常どおり自然に含まれる（優先度を割り込ませる仕組みは無い）。そのタスクを次ウェーブで
  レーンへ再割当てするときは、Step 3 のプロンプトに「前回はサンドボックス実行の完了通知を
  待っている間にターンが終わっている（#138）。バックグラウンド化されても
  `until grep -q ... done; do sleep 30; done` 等で自分で完了を待ち、コミットに到達するまで
  報告を終えないこと」という一文を追加すること
- 品質・設計・セキュリティの観点はここでは見ない。**それらは Epic 完了後の一括レビューで見る**

各 generator の報告は「タスク1件につき1行＋証跡ファイルのパス」に縮小されている
（`core/roles/generator.md`「完了報告」節、Task #156）。証跡ファイルは generator の
isolation worktree ではなく `${TMPDIR:-/tmp}` 配下（オーケストレータと同じホスト）に
あるため、**疑わしい報告（skips=unknown が続く・duration_sec が異様に短い等）のときだけ**
`cat`/`grep` でそのパスを直接確認してよい。全レコードを毎回読み直す必要はない
（読み直すと今回の削減が無意味になる）。

全レーンの完了直後に、実装フェーズの計測を締める:

```bash
IMPL_END_SEC=$(date +%s)
IMPL_SEC=$((IMPL_END_SEC - IMPL_START_SEC))
```

レーン結果の表示形式は [references/progress-display.md](references/progress-display.md) を参照する。

#### トークン消費の記録（効果測定）

各 generator の Task 呼び出し完了時に、ハーネスが `⎿ Done (N tool uses · Xk tokens · Ym Zs)`
形式でトークン消費を報告する。読み取れたレーンについてのみ、1レーン1レコードで記録する:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" record \
  --epic "$EPIC_NUM" --role generator --mode "タスク実装" --tokens [読み取ったトークン数] \
  --note "レーンA #[タスク番号],#[タスク番号]"
```

**読み取れない場合はそのレーンの記録をスキップしてよい。記録の成否で自律ループを止めない。**
連続処理により1レコードが複数タスク分になるため、Epic #42 のベースライン（81k〜150k/タスク）と
比較するときは `--note` のタスク件数で割って読むこと。
### Step 5: wave ブランチへレーンを取り込む

全レーン完了後、Epic worktreeでwaveブランチを作成し、（1件以上のタスクを取り込めた）レーンを
レーン記号順に取り込む。**1レーンは複数タスク分のコミットを持つ**ため、`--task` にはそのレーンで
成功したタスク番号をカンマ区切りで渡す。**`--create` は「1本目のレーン」ではなく、最初に実際に取り込むレーンに
付ける。** 取り込み対象はレーン内ゲートに通ったレーンに限られるため、issue番号順で先頭の
レーン（例: レーンA）がレーン内ゲートに失敗していれば、`--create` はレーンBなど次に取り込む
レーンに付く。

```bash
cd "$EPIC_WT"
MERGE_START_SEC=$(date +%s)   # 「統合」フェーズ（merge-lane.sh群）の計測開始

# 最初に実際に取り込むレーン（レーンAとは限らない）: --create でwaveブランチをWAVE_BASEから作成する
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-lane.sh" \
  --wave-branch "wave/${EPIC_NUM}/${WAVE_NO}" --expected-base "$WAVE_BASE" \
  --lane-branch "[レーンAの作業ブランチ]" --task "<レーンAで成功したタスク番号のカンマ区切り>" --create

# 2本目以降: waveブランチは既に存在するので --create は不要
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-lane.sh" \
  --wave-branch "wave/${EPIC_NUM}/${WAVE_NO}" --expected-base "$WAVE_BASE" \
  --lane-branch "[レーンBの作業ブランチ]" --task "<レーンBで成功したタスク番号のカンマ区切り>"

MERGE_END_SEC=$(date +%s)
MERGE_SEC=$((MERGE_END_SEC - MERGE_START_SEC))
```

終了コードで扱いを分岐する:

| 終了コード | 意味 | 扱い |
|---|---|---|
| 0 | 取り込み成功 | 次のレーンへ |
| 10 | merge-base ≠ WAVE_BASE（ベース逸脱） | 取り込まず差し戻す。実出力をTask issueにコメント。**cherry-pickによる載せ替えはしない** |
| 11 | マージ競合（`git merge --abort` 済み） | 取り込まず、stdoutの競合ファイル一覧と相手レーンをTask issueにコメント。次ウェーブで再実行 |
| 2 | 引数エラー | runの呼び出しミス。停止して報告する |
| 1 | その他の失敗 | 停止して報告する |

取り込めなかったレーンはこの時点でwaveに含まれない。**先に取り込めたレーンの成果は活かし、
ウェーブ全体は捨てない。**

**取り込めたレーンが0本の場合**（全レーンがレーン内ゲートに失敗した、またはレーン内ゲートに
通った全レーンが `merge-lane.sh` から exit 10/11 で拒否された）、`merge-lane.sh --create` が
一度も成功しておらず `wave/${EPIC_NUM}/${WAVE_NO}` は存在しない。この場合は **Step 6・Step 7 を
実行せず**、このウェーブの各タスクの試行回数を加算したうえで Step 1 に戻る（次ウェーブへ）。

### Step 6: wave ブランチの取り込み検証（可読性ガード）

全レーンの取り込み（成功分のみ）が終わったら、waveブランチ上で**可読性ガードだけ**を実行する。
merge-base 完全一致検証は Step 5 の `merge-lane.sh` が既に行っている。**プロジェクトの全テストは
ここでは走らせない**（Epic につき1回、全ウェーブ完了後の「Epic 統合ゲート」節に集約する。
「機械的ゲートの三段構成」参照）。
**このStepはStep 5で取り込めたレーンが1本以上ある場合のみ実行する**（0本の場合はStep 5末尾の
分岐を参照）。念のため冒頭で wave ブランチの存在を確認してから進む:

```bash
# git は git -C で対象 worktree を明示する（cd 直後の git 実行を避ける。issue #140）
git -C "$EPIC_WT" rev-parse --verify -q "refs/heads/wave/${EPIC_NUM}/${WAVE_NO}" >/dev/null || {
  echo "ERROR: wave/${EPIC_NUM}/${WAVE_NO} が存在しません（取り込めたレーンが0本）。Step 7を実行せずStep 1へ戻ってください"
  exit 1
}
git -C "$EPIC_WT" checkout "wave/${EPIC_NUM}/${WAVE_NO}"

# check-readability.sh は内部で bare git（cwd依存）を使うため、ここでは cd が必要
# （git の実行そのものは上で完了しており、この cd の後に git は続かない）
cd "$EPIC_WT"
# 可読性ガード — waveブランチの差分に対して実行（PostToolUseフックと同じ判定）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh" --git

MERGE_END_SEC=$(date +%s)   # 「統合」フェーズ（merge-lane.sh群＋可読性ガード）の計測終了
MERGE_SEC=$((MERGE_END_SEC - MERGE_START_SEC))
```

**Epic worktree に対する単独のゲートは行わない。** レーンの変更が Epic に入るのはこの取り込み
検証通過後のマージであり、Epic worktree を先に検証しても検証対象として意味を持たない。

- **通過** → Step 7 へ
- **失敗** → Step 8 のリカバリへ。原因レーンの特定手順は [references/recovery.md](references/recovery.md)
  の「統合ゲート失敗時の原因特定手順」を参照する（Epicブランチは無傷のまま）

### Step 7: Epicブランチへ取り込んで次のウェーブへ

#### なぜ `--ff-only` の役割を分離するか

従来は `git merge --ff-only <レーン>` の1本で「ベース逸脱の検出」と「履歴の直線性の強制」を
兼ねていたが、後者が並列実行を構造的に不可能にしていた（同一ベースから分岐した並列ブランチは
原理的にfast-forwardできない）。**この2つの役割は分離できる**: ベース逸脱の検出はStep 5の
`merge-lane.sh`によるmerge-base完全一致検証が引き継ぎ、直線性の強制はやめる。

epicへの取り込みは、waveがWAVE_BASEの子孫であるため取り込み検証通過後は必ずfast-forwardになる。

```bash
# git は git -C で対象 worktree を明示する（cd 直後の git 実行を避ける。issue #140）
git -C "$EPIC_WT" checkout "${EPIC_BRANCH}"
git -C "$EPIC_WT" merge --ff-only "wave/${EPIC_NUM}/${WAVE_NO}"
git -C "$EPIC_WT" push origin "${EPIC_BRANCH}"
```

**Epicへのforce pushは行わない。waveブランチはoriginへpushしない**（ローカルの一時ブランチ）。

1. 取り込めたレーンに対応するTask issueをクローズする: `gh issue close [番号]`
2. Epic issueの進捗を更新する
3. このウェーブの計測を確定し、次ウェーブのバナー表示・PR本文の集計に使う値を更新する:

```bash
WAVE_TOTAL_SEC=$((IMPL_SEC + MERGE_SEC))
echo "前ウェーブ: 実装 $(fmt_duration "$IMPL_SEC") + 統合 $(fmt_duration "$MERGE_SEC") = $(fmt_duration "$WAVE_TOTAL_SEC")"

PREV_WAVE_IMPL_SEC="$IMPL_SEC"
PREV_WAVE_MERGE_SEC="$MERGE_SEC"

TOTAL_IMPL_SEC=$((TOTAL_IMPL_SEC + IMPL_SEC))
TOTAL_MERGE_SEC=$((TOTAL_MERGE_SEC + MERGE_SEC))
DONE_TASK_COUNT=$((DONE_TASK_COUNT + N))   # N = 直前の「取り込めたレーンに対応するTask issueをクローズする」で閉じた件数
```

4. Step 3 で同一メッセージで起動した wave-review（起動していれば）の結果を確定させる。
   `APPROVE`/`REQUEST_CHANGES` が返り `reviewed_commit` が得られた場合のみ
   `REVIEWED_COMMIT="$WAVE_BASE"`（このウェーブの起点。＝ wave-review が見た差分の上限）へ進め、
   high/mediumの指摘を `review` issue化する（`- Epic: #$ARGUMENTS` と `- 前提: なし` を必ず書く。
   書式は [references/review.md](references/review.md) の R2 と同じ）。evaluator の起動自体が
   失敗した／JSON が読み取れなかった場合は `REVIEWED_COMMIT` を進めない（次の wave-review、
   最終的には Epic 末レビューが拾う）。詳細は
   [references/wave-review.md](references/wave-review.md) を参照する。
   その後 `PREV_WAVE_INCORPORATED=true` にする（次ウェーブの Step 3 で wave-review を起動する条件）。
5. → Step 1 に戻る（次のウェーブへ）

全ウェーブが完了したら **「Epic 統合ゲート」** へ進む（フルスイートはここで初めて、Epicにつき
1回だけ実行する）。

**取り込み検証に失敗した場合（Step 8 のリカバリを経由した場合）は、この計測更新を行わない。**
`PREV_WAVE_*` と累計は「取り込み検証を通過して実際に取り込めたウェーブ」だけを反映する
（失敗した試行の時間まで合算すると、並列化とオーバーヘッド削減の寄与という本来の目的が
読み取れない数字になるため）。

### Step 8: 失敗時のリカバリ

**共通原則: 失敗したタスクだけを落とし、先に取り込めた成果は活かす。ウェーブ全体は捨てない。**

| 失敗パターン | 扱い |
|---|---|
| レーン内ゲート失敗（タスク単位） | そのタスクだけ見送り、レーンの残りは続行。次ウェーブへ持ち越す |
| `merge-lane.sh` exit 10 / 11（ベース逸脱・競合） | 取り込まず差し戻し、実出力をissueにコメント。次ウェーブで再実行 |
| 同一タスクで3回失敗 | スキップし、`SKIPPED_CSV` に加える |
| 統合ゲート失敗（Step 6、可読性ガード） | Epicは無傷。レーンを1本ずつ積み直して原因を特定する |
| Epic 統合ゲート失敗（全ウェーブ完了後） | Epicは既にウェーブを取り込み済みで無傷ではない。修正タスク化して再試行する（詳細は「Epic 統合ゲート」節） |

**ウェーブ内では再試行しない。** バリア同期のため、ウェーブ内の再試行は他レーンを待たせるだけに
なる。次ウェーブに回せばベースが進み、この種の失敗は自然に解消することが多い。

手順の詳細（統合ゲート失敗時の原因特定、Epic統合ゲート失敗時のウェーブ単位の二分探索、
スキップの伝播）は [references/recovery.md](references/recovery.md) を参照する。
**失敗が起きたときにだけ読む。**

## サンドボックスの後片付け（正常終了・異常終了を問わず必ず実行）

自律ループが終わる経路は複数ある（全タスク完了 → 一括レビュー → PR作成、スキップが続いた末の
停止、予期しないエラーによる中断）。**どの経路で終わる場合も、後続処理へ進む前に必ず実行すること。**
完了通知の後ろに置いて成功時にしか走らない、ということがあってはならない。

```bash
# 常駐コンテナの削除（epic 単位。キャッシュ volume は次の Epic のために残す）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --down

# watchdog の停止（正常終了・異常終了を問わず必ず実行する。--down と同じ強さで必須）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --stop
```

**キャッシュ volume は削除しない。** 次の Epic でそのまま効くのが利点である。
人間向けの手動棚卸しは [references/cleanup.md](references/cleanup.md) を参照する。

## ハング・進捗表示

- run が応答しなくなったときに人間が取る手順（watchdog の通知の読み方・打ち切り・再開）は
  [references/troubleshooting.md](references/troubleshooting.md) を参照する
- ウェーブバナー・レーン結果・PR本文への計測集計の**表示フォーマット**は
  [references/progress-display.md](references/progress-display.md) を参照する。
  計測変数（`IMPL_SEC` / `MERGE_SEC` と各累計）は本ファイルの Step 2〜7 で、`EPIC_GATE_SEC` は
  「Epic 統合ゲート」節で更新する

## Epic 統合ゲート（全ウェーブ完了後・Epic一括レビューの前）

全ウェーブが完了し、Epicブランチが最新の状態になった時点で、**Epicにつき1回だけ**フルスイートを
実行する。これが「機械的ゲートの三段構成」における唯一の全テスト実行点である。

```bash
# git は git -C で対象 worktree を明示する（cd 直後の git 実行を避ける。issue #140）。
# 以降の sandbox-exec.sh / check-readability.sh は呼び出し元cwdに依存するため、
# git を終えたあとで cd する（cd の直後に git を続けない）
git -C "$EPIC_WT" checkout "${EPIC_BRANCH}"
cd "$EPIC_WT"
EPIC_GATE_START_SEC=$(date +%s)   # 「Epic統合ゲート」フェーズの計測開始

# 1) テスト（Docker sandbox内）— 1回にまとめる。落ちたら不合格
# 固定パスは複数ウェーブ・並列実行間で衝突しうるため mktemp で一意化する（issue #145）
EPIC_GATE_TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-epic-gate-test-output.XXXXXX")"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" '[全テストを走らせるコマンド]' \
  2>&1 | tee "$EPIC_GATE_TEST_LOG"

# 1b) SKIP件数はレーンの自己申告に依存せず、run自身がcount-skips.shで機械的に数える。
#     0件でも必ず表示する（黙って省略しない）
[ -n "$SKIP_PATTERN" ] && export DEV_WORKFLOW_SKIP_PATTERN="$SKIP_PATTERN"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/count-skips.sh" --file "$EPIC_GATE_TEST_LOG"

# 2) 可読性ガード — Epicブランチの差分に対して実行（PostToolUseフックと同じ判定）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh" --git

EPIC_GATE_END_SEC=$(date +%s)
EPIC_GATE_SEC=$((EPIC_GATE_END_SEC - EPIC_GATE_START_SEC))
```

**フルスイートを走らせるのはここだけである**（「機械的ゲートの三段構成」節）。ウェーブ末の
取り込み検証は可読性ガードとmerge-base検証しか行わないため、**回帰の判定はこのEpic統合ゲートが
単独で担う。**
Epic統合ゲートの `count-skips.sh` の結果は、レーンが完了報告に書いた値（変更範囲テストの
SKIP件数）と**食い違うことがある**（対象ツリーも対象範囲も異なるため）。
**食い違った場合はEpic統合ゲートの値を採用し**、その旨を Epic issue にコメントする。

#### 何を実行すれば「回帰なし」と言えるか

ゲートで走らせるのは**プロジェクトの全テスト**とする。`make test` 等のプロジェクト標準
ターゲットがあればそれを優先し、**対象の選択をgeneratorに委ねない。**

- ビルドタグ付きのテスト（`//go:build integration` 等）があるプロジェクトでは、それも含める
- ビルド・vet・テストを**別々の呼び出しに分けない**。サンドボックスはソースツリーを
  バインドマウントしており、フルツリーを走査するコマンドは1回ごとにその走査コストを払う
- テストがビルドを兼ねるなら（`go test ./...` 等）、それ1本で足りる

#### SKIP を通過扱いにしない

依存物が未配置だとテストが無言で `SKIP` され、`ok` と表示されて成功に見える。
**`ok` の有無だけで判定してはならない。** SKIP件数の数え方は自然言語の依頼にせず、
`scripts/count-skips.sh` に固定する（`tail` の目視で「0件」と判定することを禁止する。
上記1b参照）。

- `skips=<件数>`（exit 0）→ その件数を確認し、検証したかったテストが実際に走ったことを
  確かめる。**想定外のSKIPは不合格として扱う**
- `skips=unknown`（exit 1）→ **「0件」として扱ってはならない。** 同時に、これは
  **「記録して進む」に分類される**（「停止させるものと、記録して進めるもの」節）。built-in
  ランナー（go/jest/pytest）以外の形式であるため数えられなかった事実を Epic issue と PR 本文に
  明記し、**そのまま Epic一括レビューへ進む。ここで run を止めない。**
  記録して進むことと、黙って通すことは違う。「0件」への読み替えは常に禁止する。
  恒久対処として、次の run までに Epic issue 本文へ `## SKIPパターン` 節（ERE1行）を
  追加することを明記する（書き方は `core/roles/planner.md`「SKIPパターン（該当する場合のみ）」節）

- **通過** → 下記「Epic一括レビュー」へ

#### 失敗時の扱い（Epicブランチは既にウェーブを取り込み済みで無傷ではない）

1. 失敗内容（失敗したテスト名と出力）を Epic issue にコメントする
2. **修正タスクとして扱う**: `task` ラベルの issue を作成し（本文に `- Epic: #[番号]` と
   `- 前提: なし` を必ず書く）、通常のウェーブループ（Step 1 以降）で generator に修正させ、
   取り込み後に Epic 統合ゲートを再実行する
3. **再試行は最大2回。** それでも通らなければ run を止めずに PR を作成し、
   **PR 本文の冒頭に「Epic 統合ゲート不合格」と失敗内容を明記**して人間へ渡す
4. 原因ウェーブの特定手順（ウェーブ単位の二分探索）は
   [references/recovery.md](references/recovery.md) の「Epic統合ゲート失敗時の原因特定手順」を
   参照する。**失敗したときにだけ読む。**

## Epic一括レビュー（全タスク完了後・PR作成前）

全Task issueがクローズされ、Epic統合ゲートを通過した時点で、**ここで初めてevaluatorを起動する。**

**wave-review が各ウェーブの差分を先行レビュー済みのため、ここでの守備範囲は
(1) 未レビュー差分（`REVIEWED_COMMIT..Epic tip`。通常は最終ウェーブ分）と
(2) 全ウェーブ横断の整合（仕様書との照合・実装漏れ・タスク間の重複実装や命名の食い違い）に絞る**
（詳細は [references/wave-review.md](references/wave-review.md)「最終ウェーブとEpic全体整合は
Epic末レビューが見る」を参照）。**この絞り込みは宣言するだけでは効かない。** R1起動時に
`REVIEWED_COMMIT` の値を4本すべてへ明示的に渡し、「そこまではwave-reviewが指摘済みなので
再提出しない」と指示して初めて有効になる（渡し忘れると、evaluatorの「指定された差分の範囲外を
蒸し返さない」規律はwave-review / delta-reviewにしか適用されないため（`core/roles/evaluator.md`
「レビュー範囲」）、R1がwave-review済みの指摘を正当に再提出し二重issue化を招く。下記R1の
プロンプト雛形の `既レビュー済み地点` を参照）。

### R0: スキップ一覧をEpic issueにコメントする

3回失敗してスキップしたタスク、または依存先のスキップが伝播して未実行のままとなったタスクが
あれば、一括レビューの前に一覧をEpic issueへコメントする。無ければこの節は省略する。

```bash
gh issue comment "$ARGUMENTS" --body "$(cat <<'BODY'
## スキップされたタスク

- #[番号]: [スキップ理由（3回失敗 / 依存先 #[番号] のスキップの伝播）]
BODY
)"
```

### R1: 一括レビューの実行

起動前に [references/review.md](references/review.md) の「レビュー粒度の調整」の3分岐に従う
（変更50ファイル以下なら以下の基本形のまま起動する）。判定結果（3分岐のどれに該当したか）は
4本すべてに同じように渡す。

**Epic統合ゲート（フルスイート）は直前にrunが実行済みである。R1の4本はテストを再実行せず、
差分の内容の妥当性に集中する。** 4本は同一 `--epic` の同一コンテナ・同一バインドマウントを
共有するため、同時にテストを再実行させるとビルドキャッシュや一時ファイルが干渉して偽の失敗を
生みうる。直列区間の削減が目的のEpicで、レビュー段のフルスイート実行を4倍にするのは設計として
逆向きでもある。テストの再実行が必要と判断した場合は `correctness` 観点の1本だけに限定する。

**`@evaluator` を同一メッセージで4本（correctness / readability / over-engineering / security）
起動する。** 同一メッセージでなければ並行にならない（Claudeのサブエージェントはバッチ完了まで
結果が返らない）。4本には同じ差分範囲・同じ `既レビュー済み地点` を渡し、それぞれに
`- 観点: [focus]` を1行加える。

```
@evaluator
Epic #$ARGUMENTS の全変更をレビューしてください。
- モード: epic-review
- 観点: correctness
- 差分範囲: main...[epic/epicXX/機能名]
- 既レビュー済み地点: [REVIEWED_COMMIT]（ここまではwave-reviewが指摘済み。既にissue化された指摘を再提出しないこと。この範囲では全ウェーブ横断の整合〈仕様との照合・実装漏れ・重複実装・命名の食い違い〉だけを見ること）
- 作業ディレクトリ: .claude/worktrees/[epicN]
- 親Epic issueの仕様書と照合し、実装漏れも指摘すること
- Epic統合ゲート（フルスイート）は直前に実行済みで結果は「[EPIC_GATE_RESULT（例: passed, skips=0）]」である。再実行せず差分の内容の妥当性に集中すること。この観点に限り、再検証が必要と判断した場合だけテストを再実行してよい
- 最後に必ずJSONブロック（verdict / reviewed_commit / focus / findings）を出力すること

@evaluator
（同上。- 観点: readability。テストは再実行しないこと）

@evaluator
（同上。- 観点: over-engineering。テストは再実行しないこと）

@evaluator
（同上。- 観点: security。テストは再実行しないこと）
```

4本のTask呼び出しが完了したら、Step 4と同じ作法で観点ごとにトークン消費を記録する
（読み取れた場合のみ。読み取れなくても止めない。1本失敗して読み取れなかった観点は記録をスキップする）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" record \
  --epic "$EPIC_NUM" --role evaluator --mode epic-review --note "focus=[観点]" --tokens [読み取ったトークン数]
```

4本の結果のマージ・重複排除（同一 `location` の統合・severity 採用・verdict 合成・
`reviewed_commit` 食い違い時の扱い・1本失敗時の扱い）は
[references/review.md](references/review.md)「R1の結果マージ」を参照する。


### R2以降: 指摘のissue化と対応ループ

`APPROVE` ならそのまま PR 作成へ進む。`REQUEST_CHANGES` の場合と、変更が 50 ファイルを
超えてレビュー粒度の調整が要る場合の手順は
[references/review.md](references/review.md) を参照する。**そのときにだけ読む。**

要点だけ再掲する:

- 指摘は **high と medium だけ** issue 化する。low は PR 本文に列挙するのみ
- `reviewed_commit` は次の delta-review の起点になるので必ず控える
- **レビューは最大2巡まで**（初回R1の観点別4本並列 + 確度判定1本 + delta-review 1本、
  evaluator 起動は最大6回）。
  2巡目でも `REQUEST_CHANGES` が残る場合はそこで打ち切り、未対応 issue をオープンのまま
  PR 本文に明記して人間へ渡す
## 完了条件

以下がすべて満たされたらゴール達成:

1. Epic配下の全Task issueがクローズされている（スキップ分はissueにコメント済み）
2. **Epic統合ゲートが実施されている**（通過、または2回再試行後も不合格のままPR本文に明記済み）
3. コンパイル/ビルドが成功する
4. **Epic一括レビューが実施されている**（APPROVE、または2巡で打ち切り済み）
5. **main向けPRが作成されている**

### PR作成（runの最終責務）

一括レビューまで終えたら、**必ずPRを作成する。** これがrunコマンドの最終出力であり、PRのURLを表示して完了とする。
PRを作成せずにrunを終了してはならない。

**Epic 統合ゲートが2回再試行後も不合格のまま終わった場合、下記PR本文の `## Summary` の直前に
「⚠️ Epic 統合ゲート不合格: [失敗したテスト名の要約]」の1行を必ず追加すること。** 通過している
場合はこの行を出さない。

```bash
# Epicブランチの最新をpush
git push origin epic/epicXX/[機能名]

# mainへのPRを作成
gh pr create \
  --base main \
  --head "epic/epicXX/[機能名]" \
  --title "Epic: [機能名]" \
  --body "$(cat <<'BODY'
## Summary
Closes $ARGUMENTS

[仕様書の概要]

## 完了タスク
- [x] #XX Task: [タスク1]
- [x] #XX Task: [タスク2]
...

### スキップされたタスク（未実装。人間の判断が必要）
- [ ] #XX [タイトル] — [スキップ理由（3回失敗 / 依存先スキップの伝播）]

## レビュー結果
- 一括レビュー: [APPROVE / 2巡で打ち切り]
- 対応済みの指摘: #XX, #XX

### 未対応の指摘（人間の判断が必要）
- [ ] #XX [タイトル] — [なぜ未対応か]

### レビューで挙がった軽微な指摘（issue化せず記録のみ）
- [重要度lowの指摘]

## 実行時間
- ウェーブ数: [WAVE_NO] / タスク数: [DONE_TASK_COUNT] / 並列度: [LANES]
- 実装合計: [fmt_duration TOTAL_IMPL_SEC] / 統合合計: [fmt_duration TOTAL_MERGE_SEC] / Epic統合ゲート: [fmt_duration EPIC_GATE_SEC]
- 総所要時間: [fmt_duration (TOTAL_IMPL_SEC + TOTAL_MERGE_SEC + EPIC_GATE_SEC)]

## トークン消費
[record-agent-tokens.sh --summary --epic "$EPIC_NUM" の出力（1件も記録できていない場合は本セクションを省略）]

## Test plan
- [ ] 全テスト通過確認済み（Docker sandbox内）
- [ ] レビュー完了

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

**注意: Epic issueはクローズしない。PRがマージされた時点で人間がクローズする。**

### 完了通知（PR作成後）

PRのURLが取れた時点が「完全な完了」。ここでのみ完了通知を出す:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/notify-slack.sh" run-complete \
  "全[N]タスク完了（スキップ[M]件）
PR: [PRのURL]"
```

**この行に到達せずrunが終了した場合、Stopフックが自動的に「自律実行が停止」として通知する。**
そのため、エラーで中断する場合も含め、成功時以外にこのコマンドを実行してはならない。


## worktree クリーンアップ

Epic 専用 worktree（`.claude/worktrees/<epicN>`）と、generator のレーン worktree
（`.claude/worktrees/agent-*`）の削除手順は
[references/cleanup.md](references/cleanup.md) を参照する。

**削除失敗で run 全体を止めない**（「記録して進む」に分類される）。
本 run で使ったレーンの作業ブランチ名（Step 3 の完了報告で得た値）を集めて
`cleanup-lane-worktrees.sh --lane-branch` に渡すこと。他 Epic のレーン worktree には触れない。
## 自律動作ポリシー（YOLOモード）

- **ユーザーへの確認・質問は一切行わない**
- 同一タスクで3回失敗した場合 → タスクをスキップし、issueにコメントを残して次のウェーブへ進む
- 障害が続く場合は `--lanes 1` を指定すれば逐次実行にロールバックできる
  （並列用と逐次用でコードパスを分けていないため、値を変えるだけで安全に落とせる）
- **タスクループ中にevaluatorを起動しない**（レビューはEpic完了後の一括レビューのみ）
- Epic一括レビューは最大2巡で打ち切り、未対応の指摘はissueを残したままPR本文に明記する
- 予期しないエラーが発生した場合 → issueにエラー詳細をコメントし、次のウェーブへ進む
- **Epicブランチにはウェーブ末の取り込み検証（merge-base完全一致検証＋可読性ガード）を通過した
  コミットが載る。プロジェクトの全テストはEpicにつき1回のEpic統合ゲートで検証する
  （「機械的ゲートの三段構成」参照）。force pushは行わない**
- **mainブランチには絶対にマージしない**
- **テスト時に実ユーザーにメールを送信しないこと。** テスト用受信アドレス（mailhog, mailtrap等）が
  未設定の場合はタスクを中断し、issueにコメントを残して開発者に設定を促す
- **本番環境のデータは絶対に編集・削除・変更しないこと。** テストはDocker sandbox内のテスト用データのみ使用する

### 停止させるものと、記録して進めるもの

run を止めてよいのは、**続行すると成果物が壊れる**場合に限る。それ以外は記録して進む。

| 種別 | 例 | 扱い |
|---|---|---|
| **停止** | リポジトリ衛生プリフライト exit 2 / サンドボックス `mode=none` / 循環依存（`PLAN_EXIT` 3） | run を開始しない・停止する |
| **差し戻し** | レーン内ゲート失敗 / 統合ゲート失敗 / ベース逸脱・競合 | 取り込まず次ウェーブへ持ち越す（ループは止めない） |
| **記録して進む** | `skips=unknown` / トークン数が読み取れない / 準備コマンドの `--warm` 失敗 / worktree 削除失敗 / Slack通知失敗 | 事実を Epic issue と PR 本文に残し、そのまま次へ進む |

**「記録して進む」に分類したものを停止条件に格上げしないこと。** これらは成果物の正しさを
左右しない観測項目であり、ここで止めると人間が戻るまで run 全体が遊ぶ。逆に、記録を省略して
黙って進むことも禁止する（`skips=unknown` を「0件」と読み替えないのはこの原則の帰結である）。
