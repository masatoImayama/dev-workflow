# サンドボックスの詳細（run スキル参照資料）

`skills/run/SKILL.md`「Docker sandbox の準備」から参照される。Epic 本文の任意節の意味づけと、
sandbox-exec.sh へ集約されている機能、compose の要求仕様をまとめる。

#### プロジェクト固有の準備コマンド（Epic 本文の `## 準備コマンド` 節）

生成物の配置（wasm 等）のような**タスクに依らず同じ結果になる**プロジェクト固有の準備は、
タスクごとに generator へ繰り返させず、ここ（Epic 開始時）で1回だけ実行する。
SKILL.md 本体の `sect '準備コマンド'` はこの抽出手順を1行にまとめたものであり、意味は同じである。

```bash
# Epic本文に「## 準備コマンド」節があれば、その中身（フェンスコードブロックの内容）を取り出す
PREP_CMD="$(gh issue view $ARGUMENTS --json body -q '.body' \
  | awk '/^## 準備コマンド/{f=1; next} /^## /{f=0} f' \
  | sed -n '/^```/,/^```/p' | sed '1d;$d')"

if [ -n "$PREP_CMD" ]; then
  echo "Epic本文の準備コマンドを実行します:"
  echo "$PREP_CMD"
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" --warm "$PREP_CMD"
fi
```

- **節が無ければ何もしない**（上記の `[build-command]` による `--warm` だけが従来どおり走る）。
  既存の Epic（`## 準備コマンド` 節が無いもの）はこの追加ステップの影響を受けない
- `--warm` は失敗してもループを止めない（`sandbox-exec.sh` の既存挙動）。準備コマンドが失敗しても
  表示だけしてそのまま先へ進む
- **この1回が効くのは Epic 専用 worktree（`$EPIC_WT`）だけである。** コンテナは Epic 単位で
  常駐するが、共有されるのはコンテナとキャッシュ volume であって作業ディレクトリではない。
  generator の isolation worktree はこの後にタスクごとに作られる別ツリーであり、ここで配置した
  生成物（`.gitignore` されたビルド成果物・wasm 等）はそこには存在しない。この1回の役割は
  （a）ビルドキャッシュを温めること、（b）統合ゲートが実行される Epic worktree に生成物を配置しておくこと、
  の2点に限られる
- `$PREP_CMD` は変数として保持しておき、Step 3 で各レーンの generator プロンプトに
  そのまま埋め込む（レーンの作業ディレクトリで初回1回だけ実行させるため）

#### 共有ディレクトリ（Epic 本文の `## 共有ディレクトリ` 節。任意）

レーンごとに準備コマンドをフル実行すると、`node_modules` / `vendor` 等の大量のファイルを
含むディレクトリ生成が支配的なコストになる（issue #104）。Epic 本文に `## 共有ディレクトリ`
節があれば、Epic 専用 worktree（`$EPIC_WT`）の準備成果ディレクトリを、各レーンへ
コンテナ内から張った symlink で共有させ、レーンでの準備コマンド実行そのものを不要にする。

「準備コマンド」節・「SKIPパターン」節と**同じ位置・同じ方法**で抽出する:

```bash
# Epic本文に「## 共有ディレクトリ」節があれば、その中身（フェンスコードブロックの内容）を取り出す
SHARED_DIRS="$(gh issue view $ARGUMENTS --json body -q '.body' \
  | awk '/^## 共有ディレクトリ/{f=1; next} /^## /{f=0} f' \
  | sed -n '/^```/,/^```/p' | sed '1d;$d')"

# レーンから共有元（Epic専用worktree）を指すための絶対パス
EPIC_WT_ABS="$(cd "$EPIC_WT" && pwd)"
```

- **節が無ければ `$SHARED_DIRS` は空文字のまま**で、以降の挙動は現行と完全に同じにする
  （既存 Epic への後方互換。各レーンは従来どおり `$PREP_CMD` を直接実行する）
- `$SHARED_DIRS` と `$EPIC_WT_ABS` は変数として保持しておき、Step 3 で各レーンの generator
  プロンプトに埋め込む（`scripts/share-prepared-dirs.sh` の `--spec` / `--source` に渡すため）
- 節の書き方は `core/roles/planner.md`「共有ディレクトリ（該当する場合のみ）」を参照

#### SKIP件数の判定パターン（Epic 本文の `## SKIPパターン` 節。任意）

`scripts/count-skips.sh`（SKIP件数を機械的に数えるスクリプト。詳細はREADME参照）は
built-inランナー（go/jest/pytest）の出力形式しか自動認識できず、それ以外の形式では
`skips=unknown`（exit 1）になる。駆動先プロジェクトの形式が独自の場合に備え、Epic本文に
任意の節を置けるようにする。

```bash
# Epic本文に「## SKIPパターン」節があれば、その中身（フェンスコードブロックの内容）を取り出す
SKIP_PATTERN="$(gh issue view $ARGUMENTS --json body -q '.body' \
  | awk '/^## SKIPパターン/{f=1; next} /^## /{f=0} f' \
  | sed -n '/^```/,/^```/p' | sed '1d;$d')"
```

- **節が無ければ何もしない**（`$SKIP_PATTERN` は空文字のまま）。built-inランナーの形式で
  数えられるプロジェクトはこの節を書かなくてよい
- `$SKIP_PATTERN` は変数として保持しておき、Step 3 の各レーンの generator プロンプトと
  Step 6 の統合ゲートの両方に、`DEV_WORKFLOW_SKIP_PATTERN` として渡す
- 節の書き方は README「Epic の `## SKIPパターン` 節」を参照

#### 編集時チェック（Epic 本文の `## 編集時チェック` 節。任意）

`scripts/edit-check.sh`（PostToolUse(Write|Edit|MultiEdit)フック）は、編集直後にホスト側で
型チェック単体・lint単体のような軽量チェックを実行し、違反があれば即座にエージェントへ
差し戻す。目的は「編集 → sandbox-exec.sh でビルド/テスト → エラーを読む → 修正」という
Docker往復を伴うループの短縮（Task #155、`docs/adr/0005-edit-time-check-hook.md`）。

「準備コマンド」節・「SKIPパターン」節と同じ位置・同じ方法で抽出する:

```bash
# Epic本文に「## 編集時チェック」節があれば、その中身（フェンスコードブロックの内容）を取り出す
EDIT_CHECK="$(gh issue view $ARGUMENTS --json body -q '.body' \
  | awk '/^## 編集時チェック/{f=1; next} /^## /{f=0} f' \
  | sed -n '/^```/,/^```/p' | sed '1d;$d')"

# マーカーファイルへ書く（節が無ければ--clearし、前回Epicの内容を残さない）
if [ -n "$EDIT_CHECK" ]; then
  printf '%s\n' "$EDIT_CHECK" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/edit-check.sh" --write
else
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/edit-check.sh" --clear
fi
```

- **節が無ければ何もしない**（マーカーファイルが `--clear` され、既存 Epic の挙動と完全に同じ
  になる）
- **他の3節と異なり、Step 3 のレーンプロンプトへ埋め込む必要が無い。** PostToolUse フックは
  CLI 本体の子プロセスとして起動されるため、generator が Bash ツール越しに `export` した
  環境変数は届かない（`scripts/heartbeat.sh` の `--abort` フラグ判定と同じ制約）。そのため
  マーカーファイル経由にしており、書き込みが済めば以降は編集のたびに自動発火する
- 節の書き方は README「Epic の `## 編集時チェック` 節」・ADR 0005 を参照

### サンドボックスへのコマンド投入は sandbox-exec.sh 経由に統一する

**`docker run` を直接組み立ててはならない。** 以下をすべて `scripts/sandbox-exec.sh` が引き受ける:

- **イメージの解決とビルド** — `Dockerfile.dev` があれば内容の hash でタグ付けして自動ビルドする
  （`DEV_WORKFLOW_DOCKER_IMAGE` を指定すれば既存イメージをそのまま使い、ビルドはしない）
- **ビルドキャッシュの永続化** — `docker run --rm` はコンテナ層を毎回捨てるため、`GOCACHE` 等に
  貯まったコンパイル結果が次回に残らない。言語ごとのキャッシュディレクトリを named volume 化する
  （対象パスは `DEV_WORKFLOW_CACHE_PATHS` で上書きできる）
- **コンテナの再利用** — Epic 単位で常駐させ `docker exec` で叩き、起動オーバーヘッドを消す。
  `--epic` を渡し忘れても環境変数 `DEV_WORKFLOW_EPIC` が設定されていれば同じコンテナに載る
- **Windows のパス変換対策** — Git Bash（MSYS）は `-w /workspace` を
  `C:/Program Files/Git/workspace` に変換してしまい、`docker run` がそのまま失敗する。
  `MSYS_NO_PATHCONV=1` と `pwd -W` で回避する
- **イメージタグの安定化** — タグをリポジトリ名基準（+ Dockerfile の内容 hash）にし、worktree
  ごとに別イメージをビルドし直す事故を防ぐ。COPY 対象だけを変更した場合は hash が変わらないため、
  その場合は `--rebuild` で強制的に再ビルド・コンテナ作り直しを行う

```bash
# 実行（複数コマンドは1回にまとめる。後述）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" 'make test'
```

終了コードは実行したコマンドのものがそのまま返るので、機械的ゲートの判定に使える。

### compose を使う場合の要求仕様

`docker-compose.dev.yml` を使う場合、素直に「ビルド・テストを実行する compose ファイル」を
書くと常駐サービスが存在せず `sandbox-exec.sh` が `exec` できない。次の要求仕様を満たすこと:

- **常駐サービス名**: 既定 `app`（`DEV_WORKFLOW_COMPOSE_SERVICE` で変更可）
- **マウント**: 当該サービスが `.:/workspace` をマウントすること
  （異なるマウント先にする場合は `DEV_WORKFLOW_COMPOSE_WORKDIR` で上書きする）
- **長時間常駐**: `sleep infinity` 等でプロセスが終了しないこと（サービスが running であり
  続けないと `sandbox-exec.sh` は `up -d` を試みた上で、原因の分かるエラーを出して停止する）
- **`container_name:` と固定ホストポート（例: `- "8080:8080"`）を使わないこと** —
  `sandbox-exec.sh` は `-p <project>` でプロジェクト名を epic 単位に分離するが、これらは
  `-p` では解決できない衝突であり、epic の並行実行ができなくなる。`sandbox-exec.sh` は
  検出時に stderr へ警告するが、自動では直せない

サンプル（そのまま貼り付けて使える最小構成）:

```yaml
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - .:/workspace
    working_dir: /workspace
    command: ["sleep", "infinity"]
```

