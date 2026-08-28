# Dev Workflow Plugin for Claude Code

3エージェント自律開発ワークフロー。  
Docker sandbox内でplanner・generator・evaluatorによる仕様策定から自律実装までを一気通貫で行うClaude Codeプラグイン。

## インストール

### 1. マーケットプレイスを追加

```bash
claude plugin marketplace add https://github.com/masatoImayama/claude-dev-workflow-marketplace.git
```

### 2. プラグインをインストール

```bash
claude plugin install dev-workflow@dev-workflow-marketplace
```

### 3. セッションを再起動

```bash
claude
```

### プラグインの更新（インストール済みの場合）

プラグインが更新された場合、以下の手順で再反映できます:

```bash
# 方法1: マーケットプレイスを更新してリロード
/plugin marketplace update dev-workflow-marketplace
/reload-plugins
```

```bash
# 方法2: 再インストール
/plugin uninstall dev-workflow@dev-workflow-marketplace
/plugin install dev-workflow@dev-workflow-marketplace
/reload-plugins
```

### ローカルでテスト（インストール不要）

```bash
claude --plugin-dir /path/to/dev-workflow
```

## 前提条件

- [GitHub CLI (`gh`)](https://cli.github.com/) がインストール・認証済み
- [Docker](https://docs.docker.com/get-docker/) がインストール・起動済み
- Git リポジトリ内で実行
- サンドボックス定義（`Dockerfile.dev` または `docker-compose.dev.yml`）を次の3択のいずれかで
  供給する。**駆動先の業務リポジトリを汚さない選択肢を第一候補とする**（詳細は下記
  「Docker sandbox のセットアップ」参照）
  1. 規約パスに置く（推奨）: `~/.claude/dev-workflow/sandbox/<リポジトリ名>/Dockerfile.dev`
     （または同ディレクトリの `docker-compose.dev.yml`）
  2. 環境変数で渡す: `DEV_WORKFLOW_DOCKERFILE` / `DEV_WORKFLOW_DOCKER_COMPOSE_FILE` /
     `DEV_WORKFLOW_DOCKER_IMAGE`
  3. リポジトリ直下に置いてコミットする（チームで run を共有する場合のみ）
- 上記が満たされない場合、セッション開始時にブロックされます

### 自動設定（SessionStart時）

プラグインのセッション開始フックが以下を自動的に行います:

- **`gh auth setup-git`** — gitの認証をgh CLIに委任し、push/PR作成時のアカウント選択ポップアップを防止
- **Docker起動チェック** — Docker デーモンが未起動の場合にブロック

## 任意依存の外部ツール

dev-workflow は複数の外部ツール（context7 / code-review-graph / LSP）を**任意依存**として利用します。
**必須依存ではありません。入れなくても dev-workflow は従来どおり動作します。**

| ツール | 結線先 | 未導入時の挙動 |
|---|---|---|
| [context7](https://github.com/upstash/context7)（MIT） | generator のみ | generator はライブラリ API を context7 で確認しません。推測に頼らず、既存利用箇所・公式ドキュメントで確認する従来どおりの手順になります |
| [code-review-graph](https://github.com/tirth8205/code-review-graph)（MIT） | evaluator のみ（大規模差分のみ） | evaluator は blast radius（影響範囲）を使った優先順位付けをしません。従来どおり Phase 単位に分割してレビューする手順になります |
| LSP（typescript-lsp / lua-lsp / gopls-lsp / rust-analyzer-lsp 等） | generator のみ（Claude Code のみ。下記参照） | generator は定義・参照の追跡を `Grep` の総当たり＋`Read` で行います（従来どおり） |

**いずれもワークフローを止めません。** テスト・レビューはツールの有無に関わらず従来どおり完走します。

- **入れ方**: 導入手順・結線方式の実測結果・MCPツール名は [`docs/optional-mcp-tools.md`](docs/optional-mcp-tools.md) が正本です（README では二重管理しません）
- **効かなければ外す判断基準**: `docs/optional-mcp-tools.md` の「外す判断基準」節を参照してください。複数 Epic を通してトークン消費が減らず、レビュー品質の向上も観測できない場合は結線を外してかまいません

### LSP（探索ターン数の削減。Claude Code のみ。issue #154）

`Grep` → `Read` → `Read` → `Read` と3〜5ターンかかっていた定義・参照の追跡を、LSP
（go-to-definition・find-references・hover 等）が使えるときは1〜2ターンに縮められます。
**LSP はホスト側で動く探索ツールであり、generator のビルド・テストが行われる Docker sandbox
（`sandbox-exec.sh` 経由のコンテナ）とは別物です。** ビルド・テストの代わりにはなりません。

**有効化方法（実際に確認できた方法）**: `treflebonbon/dotfiles` の
`private_dot_claude/settings.json.tmpl` が、`enabledPlugins` で typescript-lsp / lua-lsp /
gopls-lsp / rust-analyzer-lsp を常時有効にしている例を確認しています。ユーザースコープの
`~/.claude/settings.json` に対象言語の LSP プラグインを `enabledPlugins` で有効化すると、
generator の frontmatter（`adapters/claude/overlays/generator.md` の `tools:`）に列挙済みの
`mcp__typescript-lsp__*` 等のツールが使えるようになります。

**未確認の注意点**: 有効化した LSP プラグインが実際に公開する MCP ツール名の namespace
接頭辞は、プラグインの実装依存で変わりえます。`tools:` に書いた名前と一致しない場合は、
有効化した環境で実際のツール名を確認し、`adapters/claude/overlays/generator.md` を修正して
`bash adapters/claude/build.sh` で再生成してください。

**Codex には同等の機能がありません。** Codex には Claude Code の marketplace プラグイン /
`enabledPlugins` に相当する、ユーザーが任意に有効化できる LSP プラグインの仕組みが
確認できていないため、`adapters/codex/overlays/generator.toml` は LSP の MCP サーバーを
宣言していません（詳細は同ファイルのコメント参照）。Codex 版の generator は常に
`Grep` / `Read` で探索します。

## Docker sandbox のセットアップ

サンドボックス定義（`Dockerfile.dev` / `docker-compose.dev.yml`）は次のいずれかの場所に置きます。
**中身は共通で、置き場所が変わるだけです**（下記のサンプルはそのままどちらの場所でも使えます）。

### 1. 規約パスに置く（推奨・駆動先リポジトリを汚さない）

```bash
mkdir -p ~/.claude/dev-workflow/sandbox/<リポジトリ名>
```

このディレクトリに、下記と同じ内容の `Dockerfile.dev`（または `docker-compose.dev.yml`）を配置
してください。`<リポジトリ名>` は `basename(リポジトリルート)` です。

### 2. 環境変数で渡す

```bash
export DEV_WORKFLOW_DOCKERFILE=/path/to/Dockerfile.dev
```

### 3. リポジトリ直下に置いてコミットする（チームで run を共有する場合のみ）

プロジェクトルートに開発用Dockerfileを配置してください:

```dockerfile
# Dockerfile.dev の例
FROM node:20-alpine
WORKDIR /workspace
COPY package*.json ./
RUN npm ci
# テスト・ビルドに必要なツールをインストール
```

DB等の依存サービスが必要な場合は `docker-compose.dev.yml` を使用:

```yaml
# docker-compose.dev.yml の例
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - .:/workspace
    working_dir: /workspace
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: dev
```

## コマンド

### 段階的に実行

```
/dev-workflow:plan ユーザーがワンクリックで作業を開始できるボタンを追加したい
```
→ planner がヒアリング → 仕様書・計画書作成 → GitHub issue作成 → **ユーザー承認で停止**

```
/dev-workflow:run #123
```
→ 承認済みEpicに対して Docker sandbox内で generator + evaluator が**YOLOモードで完全自律実装**

### 全自動

```
/dev-workflow:goal リアルタイムで他ユーザーの存在が分かるプレゼンス機能を実装したい
```
→ plan → ユーザー承認 → Docker sandbox内でYOLO run を一気通貫

### 個別スキル

```
/dev-workflow:grill-me WebSocket経由のリアルタイム通知を検討したい
/dev-workflow:spec notifications
/dev-workflow:epic notifications
```

## 3エージェント

| エージェント | 役割 | モデル | 特徴 |
|---|---|---|---|
| **planner** (紫) | 仕様ヒアリング・計画・issue管理 | Opus | 書き込み可 |
| **generator** (青) | Docker sandbox内でコード実装・テスト | Sonnet | worktree隔離 + Docker |
| **evaluator** (緑) | Epic完了時に全差分を一括レビュー | Opus | 読み取り専用 + Docker |

generator は実装コードに手を付ける前に、`DietrichGebert/ponytail`（MIT）に由来する7段の判断ラダー
（存在する必要があるか → コードベースに既にあるか → 標準ライブラリ → プラットフォーム標準機能 →
導入済みの依存 → 1行で書けるか → 最小限の実装）で「作るべきか・再利用すべきか」を判定します。
**テスト・回帰確認・検証・セキュリティは削減対象外**で、ラダーは実装コードにのみ適用され、
これらを省く理由には使われません。

## プロンプトの progressive disclosure 方針

各エージェントのシステムプロンプトは、レーン起動のたびに丸ごと読み込まれる。常時読み込む本体を
薄くし、条件付き・詳細な情報は参照ファイルへ退避する（progressive disclosure）ことで、
**レーン起動ごとの入力トークンと cold start を削減する。**

**何を本体に残し、何を参照ファイルへ置くか**の判断基準:

| 本体に残す（常時読み込み） | 参照ファイルへ退避してよい |
|---|---|
| 安全ルール・可読性原則・禁止事項 | 個別機能の詳細な手順・書式・背景説明 |
| ブランチ戦略・依存宣言・ウェーブの要点 | 失敗時・例外時にだけ必要な手順 |
| 停止させるもの／記録して進めるものの分類 | 過去の設計判断の長い理由づけ |

**`skills/*/references/` と `core/references/` の使い分け**:

- `skills/run/references/*.md` — `skills/run/SKILL.md`（run スキル本体）専用の参照。
  run の実行手順に固有の詳細（サンドボックス起動・進捗表示・リカバリ手順等）を置く
- `core/references/*.md` — `core/instructions.md`（planner / generator / evaluator
  3エージェント共通のハーネスルール）専用の参照。個別ロール横断で使う詳細
  （watchdogの詳細・Epic本文の任意節の詳細・ハーネス非注入原則の対応表等）を置く

退避先には**必ず「いつ読むか」を1行で書く**（例:「ハングを調査するときにだけ読む」）。
退避元には本文をインライン展開する `<!-- include: -->` を使わず、参照先へのポインタ行だけを
残す（インライン展開すると本文が再び膨らみ、薄くする目的に反するため）。

## ワークフロー

```
/plan [自然言語の指示]
  │
  ├─ planner: 仕様ヒアリング（1問ずつ）
  ├─ planner: 仕様書・実装計画書作成
  ├─ planner: Epicブランチ作成 (epic/epicXX/[機能名])
  ├─ planner: Epic issue作成（仕様書・計画書を本文に添付）
  ├─ planner: Task issue 作成
  └─ ユーザー承認待ち
        │
        ▼
/run #[epic番号]  [YOLO]
  │
  ├─ Epicブランチの確認
  ├─ Docker sandbox 起動
  ├─ タスク選定（Phase順・自動）
  ├─ generator: Docker sandbox内でEpicブランチ上に実装 + テスト
  ├─ 機械的ゲート: テスト・ビルド・可読性ガード（LLM呼び出しなし）
  ├─ 通過 → Epicブランチにマージ → 次のタスクへ
  ├─ 失敗 → generatorに差し戻し（3回で当該タスクをスキップ）
  │
  ├─ 【全タスク完了後】evaluator: main...epic の全差分を一括レビュー
  ├─ 指摘(high/medium) → review issue化 → generatorが対応 → 差分のみ再レビュー
  ├─ 最大2巡で打ち切り（残りはissueを開いたままPR本文に明記）
  ├─ main向けPR作成（人間がレビュー・マージ）
  └─ Docker sandbox クリーンアップ
```

### レビューをEpic単位でまとめる理由

レビューは最もコストの高い工程で、タスクごとにOpusで全文脈を読み直すと
**レビュー費用が実装費用を上回る**。そこでevaluatorの起動をEpic単位に集約している。

| | 旧（タスクごと） | 現（Epic一括） |
|---|---|---|
| evaluator起動回数 | タスク数 × 差し戻し回数 | **最大2巡（初回R1の観点別4本並列 + delta-review 1本。タスク数に非依存）** |
| タスクごとの品質担保 | Opusレビュー | テスト・ビルド・可読性ガード（機械的・LLM不要） |
| 指摘の扱い | その場で差し戻し | **issue化し、通常のウェーブループで並列に対応** |
| 打ち切り | 3回REQUEST_CHANGESでスキップ | 2巡で打ち切り、残りは人間のPRレビューへ |

副次的な効果として、レビュアーが**タスクをまたいだ整合性**（重複実装、
タスク間で食い違う命名やデータ構造、仕様の実装漏れ）を見られるようになる。
タスク単位のレビューでは原理的に見えなかった観点。

### 観点別レビュー（focus）とウェーブ差分の先行レビュー（wave-review）

evaluator は観点（`correctness` / `readability` / `over-engineering` / `security`）を指定して
起動できる。観点を指定すると、evaluator は**自分の観点の指摘だけ**を返す（観点未指定なら
従来どおり全観点を見る。Codex は観点未指定のまま使う）。Epic末の一括レビュー（R1）は
**この4観点を `@evaluator` の同一メッセージで並列起動**し、run が結果を
マージ・重複排除する（同一 `location` の統合、最も高い severity の採用、verdict の合成、
`reviewed_commit` 食い違い時は最も古いものを採用。手順の詳細は
`skills/run/references/review.md`「R1の結果マージ」参照）。

またモードに `wave-review`（`[前回レビュー済みcommit]..[epic-branch]`）を追加し、あるウェーブが
Epic ブランチへ取り込まれた直後にそのウェーブ差分だけを先行レビューできるようにした。
**wave-review の実際の呼び出し（いつ・どのタイミングで起動するか）は別タスクの担当であり、
現時点では evaluator 側の契約（モードと出力フォーマット）が用意されているだけである**
（設計判断は `docs/adr/0003-parallel-review-by-focus.md` 参照）。

## ブランチ戦略

```
main (保護: 人間のみマージ可)
 ├─ epic/epic10/feature-a  ← Epic #10 の全タスク
 ├─ epic/epic11/feature-b  ← Epic #11 の全タスク（並行開発可）
 └─ ...
```

- 各Epicは専用ブランチで開発し、mainには直接変更を加えない
- 複数Epicの並行開発に対応（ブランチ・Docker sandboxが独立）
- 各タスク開始前にEpicブランチを最新に同期（古いベースからの分岐を防止）
- 全タスク完了後にmain向けPRを作成し、人間がレビュー・マージする

### worktree運用の注意

`node_modules` 等がsymlinkの場合、`git worktree remove --force` がsymlink越しにメインリポの実体ファイルを削除する。worktree削除前に必ずsymlinkを解除すること。

各レーン（generatorのisolation worktree、`.claude/worktrees/agent-*`）は変更を加えた（＝コミットを持つ）ものは自動整理されず、Epicを重ねるごとに蓄積する。`git worktree prune`は登録が壊れたものしか掃除しないため、実在するディレクトリは残り続ける。`scripts/cleanup-lane-worktrees.sh`はrunの完了時に、当該Epicで使ったレーンworktreeのうちEpicブランチへ取り込み済みのものだけを削除する（他Epicの分やまだ取り込まれていない分には触れない）。

```bash
git worktree list                                          # 残存worktreeの棚卸し
bash scripts/cleanup-lane-worktrees.sh --epic-branch <ブランチ> \
  --lane-branch <ブランチ> [--lane-branch <ブランチ> ...] --dry-run   # 削除対象と判定理由だけ確認
```

**共有 symlink と `cleanup-lane-worktrees.sh` の関係**: Epic の `## 共有ディレクトリ` 節で
`node_modules` 以外（`vendor` 等）を共有した場合、既定の `--unlink-dir node_modules` だけでは
その symlink が解除されないまま `git worktree remove --force` が走り、symlink 越しに共有元
（Epic 専用 worktree）の実体を削除してしまう。`--unlink-dir <名前>`（繰り返し可、既定
`node_modules`）で共有対象の名前を明示的に渡すこと。`## 共有ディレクトリ` 節が宣言する
ディレクトリ名は、run のクリーンアップ処理からそのまま `--unlink-dir` として渡される。

## 並列実行（ウェーブ実行）

`/dev-workflow:run` は Task issue が宣言した依存関係だけを根拠に、依存の無いタスクを**ウェーブ単位で並列実行**する。1タスクずつ直列に流していた従来方式に対し、独立したタスクの待ち時間を短縮する。

### 依存宣言（`- 前提:`）の書き方

planner は各 Task issue に次のいずれかを必ず書く。

```
- 前提: #12, #15
- 前提: なし
```

- パースは「`- 前提:` で始まる行から `#\d+` をすべて拾う」方式。`- 前提: #7, #9（全実装完了後）` のような注釈混じりでも動く
- **`- 前提:` 行そのものが無い**（＝宣言漏れ）場合は、そのタスクが**自分より issue 番号が小さい全タスクに依存する**とみなす（fail-safe）。結果として宣言漏れの Epic は完全逐次で実行され、現行（並列化前）と同じ挙動になる。エラーにはしない（前提行の無い既存 Epic を壊さないため）が、`plan-waves.sh --print` はこの劣化を目立たせる警告を出す（次節参照）
- 依存が無い場合も `- 前提: なし` の明記が必須。これが無いと「宣言漏れ」と区別できない

### Phase は実行順序に使わない

Phase は人間向けの区分として残るが、**実行順序の決定には使われない**。理由は「同一 Phase = 並列可能」が成立しない実例があるため（例: Epic #3 の Phase 2 は #5→#6→#7 と鎖状に直列だった一方、Phase 3 の #8・#9 と Phase 4 の #10・#11 は Phase をまたいで相互に独立していた）。実行順序の唯一の根拠は `- 前提:` が作る依存グラフである。

### `--lanes`（並列度）

- 既定は **3**。`/dev-workflow:run #123 --lanes N` で上書きできる。指定が無ければ環境変数 `DEV_WORKFLOW_MAX_LANES` を使い、それも無ければ既定の3を使う
- **ホスト性能からの自動算出はしない。** ボトルネックは（コンパイルではなく）バインドマウントの I/O であり、ホストのコア数と相関しないため
- ウェーブ内のタスク数が `lanes` を超える場合、**サブバッチに分けて順番に流すのではなく、`lanes` 本のレーンへタスク列として配分する**（レーン L には `plan-waves.sh` の `subbatch` 列の L 番目のタスクが順に入る）。各レーンは割り当てられたタスク列を**同一の作業ツリーで連続処理**する。ウェーブ末の取り込み検証（merge-base検証＋可読性ガード）は**ウェーブに1回**。プロジェクトの全テストはEpicにつき1回のEpic統合ゲートに集約する（#144）

### レーン内の連続処理（cold start の排除）

**generator はタスクごとに作り直さない。** 1レーンが複数タスクを持つ場合、同じ worktree・同じコンテキストのまま次のタスクへ進む。

- ベース合わせ（`git reset --hard <WAVE_BASE>`）・プロジェクト固有の準備コマンド・共有ディレクトリのセットアップは、**レーンの先頭で1回だけ**行う
- 2件目以降のタスクは、1件目で得たリポジトリの理解（ディレクトリ構成・テストコマンド・規約）をそのまま使い、調べ直さない
- タスク1件につき独立したコミットを積む。run はタスク単位で issue をクローズする
- **1件のタスクに失敗しても、レーン全体を投げ出さない。** 失敗したタスクは `git reset --hard HEAD` で直前の成功コミットまで戻して見送り、次のタスクへ進む

これは Epic #42 の実測（generator 81k〜150k トークン／タスク）のうち、**タスクごとの cold start が占める分**——system prompt の読み直しとリポジトリの再調査——を取り除くための変更である。従来のサブバッチ方式が持っていた「サブバッチごとに全レーンの完了を待つ」バリア同期も同時に消える。

**この連続処理は同一ウェーブ内に限られる。** ウェーブをまたいでレーン（generator）を使い回す
「cross-wave lane reuse」を検証したが、Claude Code の Task tool には既に完了したサブエージェント
呼び出しへ後から追加のメッセージを送って継続させる手段が無いことを確認し、実装を見送った
（`ウェーブ数 × レーン数` 回の spawn は変わらず残る。検証内容は
`docs/adr/0004-cross-wave-lane-reuse.md` 参照）。

### 機械的ゲートの三段構成

フルスイートを「タスクごと」「ウェーブごと」の両方で走らせない。1レーンが複数タスクを連続処理する以上、レーン内のフルスイートはレーン内で**直列に積み上がる**。同様にウェーブごとのフルスイートも「ウェーブ数 × フルスイート時間」の直列区間になるため、**フルスイートはEpicにつき1回、全ウェーブ完了後に集約する**（#144）。

| 検証点 | 対象ツリー | 実行するもの | 頻度 |
|---|---|---|---|
| **レーン内ゲート** | generator の isolation worktree | **変更範囲のテスト**（変更したファイルが属するパッケージ／モジュール単位） | タスクごと |
| **ウェーブ末の取り込み検証** | wave ブランチ（全レーン取り込み後） | merge-base 完全一致検証＋可読性ガード | ウェーブごとに1回 |
| **Epic 統合ゲート** | Epic ブランチ | **プロジェクトの全テスト＋可読性ガード** | **Epicにつき1回**（全ウェーブ完了後） |

- **「回帰なし」を宣言できるのはEpic統合ゲートだけ。** generator は完了報告に「変更範囲のテストが通った」とだけ書く
- 無関係な領域の回帰はEpic統合ゲートが拾う。Epic統合ゲートが落ちた場合は、ウェーブ単位の二分探索で原因ウェーブを特定し、修正タスクとして通常のウェーブループで対応させる（下記「リカバリ」）
- 変更が共通基盤に及ぶなど広範だと generator が判断した場合に限り、そのタスクで全テストを走らせてよい（判断根拠を報告に残す）
- **トレードオフ**: 回帰の検知がEpic末まで遅れる。ウェーブ内の自動の安全網はレーン内ゲート・マージ健全性チェック・可読性ガードだけになり、Epicブランチに「フルスイート未通過のコミット」が一時的に載りうる（従来の不変条件「Epicブランチには統合ゲートを通ったコミットだけが載る」は変わる）。main への取り込みは常に人間のPRレビューを通ることが前提（詳細は `docs/adr/0001-integration-gate-at-epic-end.md`）

### `--lanes 1` は現行と等価なロールバック手段

`--lanes 1` を指定すると「1レーンのウェーブ」として**並列時と同じコードパス**を通り、逐次実行になる。並列用と逐次用でコードパスを分けていないため、障害時は値を変えるだけで安全にロールバックできる。`lanes=1` は「レーンが1本」という意味であり、「1回に1タスクしか進めない」という意味ではない——そのウェーブの全タスクが1本のレーンで連続処理される。

### ウェーブと wave ブランチ

```
main（保護: 人間のみマージ可）
 └─ epic/epicXX/[機能名]                 ← ウェーブ取り込み後、Epic統合ゲート（Epicにつき1回）を通過してPR化される
     └─ wave/epicXX/<ウェーブ番号>        ← レーンを取り込み取り込み検証に掛ける一時ブランチ（originへpushしない）
         └─ 各レーンの作業ブランチ（generatorのisolation worktree由来）
```

- **ウェーブ**とは、依存グラフの同一レベルに属し同時に実行できるタスクの集合。ウェーブ末の取り込み検証の単位でもある
- **WAVE_BASE** は、ウェーブ開始時点の Epic ブランチ tip。**各レーン（generator の isolation
  worktree）の分岐元はハーネスが決めるため WAVE_BASE とは限らない。** isolation worktree を
  作るのはハーネスであり、run はメインリポのチェックアウトを Epic ブランチへ切り替えないため、
  分岐元は通常メインリポのデフォルトブランチのままである。そのため generator は実装着手前に
  `git reset --hard "$WAVE_BASE"` で自分の HEAD を明示的に合わせる
  （`core/roles/generator.md`「渡されたベースにHEADを合わせる」参照）
- レーン（generator の isolation worktree）は wave ブランチへ merge-base 検証つきで取り込まれ、**wave ブランチ上でウェーブ末の取り込み検証（merge-base完全一致検証・可読性ガード）を1回だけ通過してから** Epic ブランチへ `--ff-only` で進む。**プロジェクトの全テストはここでは走らせない**（Epicにつき1回のEpic統合ゲートに集約する。#144）
- **Epic ブランチにはウェーブ末の取り込み検証を通過したコミットが載る。** プロジェクトの全テストはEpic統合ゲート（Epicにつき1回）で検証するため、Epicブランチに「フルスイート未通過のコミット」が一時的に載りうる（従来の不変条件「Epicブランチには統合ゲートを通ったコミットだけが載る」からの変更。トレードオフは上記「機械的ゲートの三段構成」参照）
- **Epic ブランチへの force push は行わない。wave ブランチは origin へ push しない**（ローカルの一時ブランチ）

### `--ff-only` から merge-base 検証への変更理由

従来の `git merge --ff-only <レーン>` は「ベース逸脱の検出」と「履歴の直線性の強制」という2つの役割を兼ねていた。しかし後者は同一ベースから分岐した並列レーンの取り込みを構造的に不可能にする（並列ブランチは原理的に fast-forward できない）。この2つの役割は分離できる。

```bash
# 旧: 2つの役割を1コマンドで兼ねていた
git merge --ff-only <レーン>

# 新: ベース逸脱の検出だけを維持し、直線性の強制はやめる
ACTUAL_BASE=$(git merge-base "$WAVE_BRANCH" "$LANE_BRANCH")
[ "$ACTUAL_BASE" = "$WAVE_BASE" ] || 停止   # ベース逸脱の検出（維持）
git merge --no-edit "$LANE_BRANCH"          # 直線性の強制はやめる（ff可能ならffになる）
```

`merge-base(wave, laneB)` は laneA を wave に取り込んだ後でも `WAVE_BASE` のままである（wave は WAVE_BASE を含み、laneB の祖先集合は WAVE_BASE 以下だから）ため、完全一致による検証は並列レーンでもそのまま成立する。誤って `main` 等から分岐したレーンは merge-base が古いコミットになるため確実に検出される。**cherry-pick による載せ替えは行わない**（検証されていないツリーを作る経路を残さないため）。

### リカバリ

**共通原則: 失敗した「タスク」だけを落とし、先に取り込めた成果は活かす。レーン全体もウェーブ全体も捨てない。**

| 失敗パターン | 扱い |
|---|---|
| レーン内ゲート失敗（タスク単位） | そのタスクだけ見送り、**レーンの残りのタスクは続行する**。試行回数を保持したまま次ウェーブへ持ち越す（ウェーブ内では再試行しない） |
| merge-base 不一致（`merge-lane.sh` exit 10） | 取り込まず差し戻す。実出力を issue にコメント |
| マージ競合（`merge-lane.sh` exit 11） | 取り込まず、競合ファイル一覧と相手レーンを issue にコメントし次ウェーブで再実行 |
| 競合で2回失敗 | 次ウェーブで単独レーン（`lanes=1` 相当）として実行 |
| 同一タスクで3回失敗 | スキップし、issue にコメントのうえ `--skipped` に加える |
| 統合ゲート失敗（ウェーブ末、可読性ガード） | WAVE_BASE から wave ブランチを作り直し、レーンを1本ずつ「マージ→可読性ガード」で積んで原因レーンを一意に特定。特定したレーンだけ差し戻し、残りは活かす |
| Epic統合ゲート失敗（全ウェーブ完了後、プロジェクトの全テスト） | Epicは既にウェーブを取り込み済みで無傷ではない。ウェーブ単位の二分探索で原因ウェーブを特定し、修正タスクとして起票して通常のウェーブループで対応させる。**再試行は最大2回。** それでも通らなければPR本文冒頭に「Epic統合ゲート不合格」と明記して人間へ渡す（#144） |

「ウェーブ内で再試行しない」のは、バリア同期のためウェーブ内の再試行が完了済みの他レーンを待たせ続けるだけになるため。次ウェーブに回せばベースが進むだけで、「先行タスクの変更が無かったせいで落ちた」類の失敗は自然に解消する。

**スキップの伝播**: スキップされたタスクに依存する後続タスクは実行せずスキップし、その旨を issue にコメントする（推移的に伝播する）。

### ウェーブ差分の先行レビュー（wave-review）

レビューは全タスク完了後にまとめて始めると、実装が終わるまで1秒も進まない完全な直列区間になる。
`/dev-workflow:run`（Claude Code版）は、あるウェーブが Epic ブランチへ取り込まれた時点で、
**次ウェーブのレーン起動と同一メッセージ**で evaluator を1本起動し、そのウェーブ差分
（`REVIEWED_COMMIT..[取り込み後のEpic tip]`）を先行レビューする。Claude Code のサブエージェントは
バッチ全員が終わるまで結果が返らないため、これが並行実行の唯一の実装手段である
（バッチの所要時間は `max(最長レーン, レビュー)` になる）。

- 最初のウェーブでは（前ウェーブが無いため）wave-review を起動しない
- `REVIEWED_COMMIT` の初期値は Epic ブランチの分岐元（`main` との merge-base）。wave-review が
  `reviewed_commit` を返して完了するたびに進める。**evaluator の起動が失敗した場合は進めない**
  （取りこぼしは次の wave-review、最終的には Epic 末レビューが拾う）
- wave-review の指摘はその場で直さない。high/medium は `review` issue として蓄積し、実際の修正は
  Epic 末の指摘対応ループでまとめて行う（同期点を増やしてオーバーラップの利得を消さないため）
- 最終ウェーブの差分と、仕様書との照合・タスク間の重複実装といった**全ウェーブ横断の整合**は
  wave-review の対象外であり、Epic末の一括レビューが引き続き見る
- 詳細は `skills/run/references/wave-review.md` を参照

### Codex との差

並列レーンの起動は Claude Code のみ対応する。Codex はサブエージェント専用の worktree を持たないため、**`lanes=1` 固定**で動作する。これは「仕様が違う」のではなく「設定値が固定されているだけ」であり、依存グラフ・merge-base 検証・wave ブランチ経由の統合ゲート・cherry-pick 廃止・スキップの伝播は共通仕様として両方に同じ形で適用される。`lanes=1` のとき「1レーンのウェーブ」として並列時と同じコードパスを通るため、両 run スキルの記述は一致する。**wave-review も同様の理由（`codex exec` を子プロセスとして逐次起動する構造にはバッチ内並行の手段が無い）で Codex 版には実装しない。**

Epic末の一括レビュー（R1）も同じ理由で差がある。Claude は観点別4本の evaluator を同一メッセージで並列起動するが、**Codex はサブエージェント並列起動の手段が無いため、従来どおり単一 evaluator の全観点レビューのままとする**（`adapters/codex/run-loop.sh` と `skills-codex/` は変更していない）。

### `scripts/plan-waves.sh --print`（ドライラン）

実行前にウェーブ分解を人間向けに確認できる。依存宣言（`- 前提:`）のレビュー手段としても使える。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh" --epic 259 --lanes 3 --print
```

```
=== ウェーブ分解（lanes=3） ===
ウェーブ 1: 5, 10, 11
ウェーブ 2: 6, 8, 9 (サブバッチ1: #6,#8,#9)
...

[警告] 前提未宣言が 8 件あります（対象タスク 8 件中）。
       該当タスクは fail-safe により「自分より小さい issue 番号の全タスク」に依存するとみなされ、
       直列化されます。この計画の実効並列度は 1 です（指定 lanes=3）。
       Task issue 本文に「- 前提: #N」を、依存が無ければ「- 前提: なし」を追記してください。
  #16
```

- `--epic <Epic issue番号>`: 数値のEpic issue番号。`gh issue list --label task --state open --json number,body --limit 200` から依存グラフを構築する。本文の「- Epic: #N」行でNが異なるタスクは除外する（行が無い場合はフェイルオープンで含める）
- `--from-file <TSV>`: GitHub に依存しないテスト用の入力差し替え
- `--lanes N`: 並列度（既定は `DEV_WORKFLOW_MAX_LANES`、無ければ3）
- `--skipped 4,7`: カンマ区切りの issue 番号。それらに依存するタスクを推移的にスキップする
- `--print`: 上記のような人間向けの表を出力する（既定は機械可読な TSV）

宣言漏れは**フェイルオープン**（エラー停止にしない）を維持しつつ、**件数**と**それによって
実効並列度が指定 `--lanes` からどれだけ落ちたか**（`min(lanes, 各ウェーブに属するタスク数の最大値)`。
完全逐次なら1）を上記のように必ず表示する。宣言漏れが0件のときはこの警告自体が出ない。

機械可読な既定出力（`--print` 無し）は run スキルがそのままパースする TSV で、`lanes` / `task ... wave ... subbatch ... deps` / `wave ... tasks ...` / `warn missing-deps` / `warn missing-deps-summary <件数> <対象タスク数> <実効並列度> <指定lanes>`（宣言漏れが1件以上のときだけ1本出る後方互換な集計行） / `warn unknown-dep` / `skip ... reason depends-on-skipped` の各行から成る。終了コードは `0`=成功 `2`=引数エラー `3`=循環依存（循環に含まれるタスクを列挙して停止）。

レーンを wave ブランチへ取り込む `scripts/merge-lane.sh` も同様に切り出されている。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-lane.sh" \
  --wave-branch wave/epic259/1 --expected-base <WAVE_BASEのコミットハッシュ> \
  --lane-branch <レーンの作業ブランチ> [--task <Task issue番号>] [--create]
```

- `--wave-branch`: 統合先のブランチ名（例: `wave/epic259/1`）
- `--expected-base`: そのウェーブの唯一の正しい分岐元（`WAVE_BASE`。ブランチ名・タグ・コミットハッシュのいずれでもよい）
- `--lane-branch`: 取り込むレーンのブランチ名
- `--task`: ログ表示用（省略可）。動作は変わらない
- `--create`: wave ブランチが存在しなければ `--expected-base` から作成する

終了コードは `0`=取り込み成功 `10`=merge-base 不一致（ベース逸脱） `11`=マージ競合（`git merge --abort` 済み） `2`=引数エラー `1`=その他の失敗。exit 10 / 11 のときも作業ツリーは汚さない。

### Epic の `## 準備コマンド` 節

生成物の配置（wasm 等）のような**タスクに依らず同じ結果になる**プロジェクト固有の準備は、タスクごとに generator へ繰り返させず、Epic 開始時に1回だけ実行する。

````markdown
## 準備コマンド

```
make setup && make wasm
```
````

Epic issue 本文にこの節があれば、run がその内容を Epic 開始時の `sandbox-exec.sh --warm` に1回だけ渡す。この1回が効くのは Epic 専用 worktree だけである（キャッシュを温める・統合ゲートが使う Epic worktree に生成物を配置しておく、の2点が目的）。generator のレーン（isolation worktree）はこの後に別ツリーとして作られるため、この1回は及ばない。そのため run は Step 3 で同じ準備コマンドの内容を各 generator のプロンプトにも埋め込み、レーンの作業ディレクトリで初回1回だけ実行させる（同一worktree内で2回目以降は実行しない）。節が無ければ従来どおりビルドコマンドで `--warm` するだけになる（後方互換）。

### `scripts/count-skips.sh`（SKIP件数の機械的カウント）

「SKIP されたテストがあれば件数と内容を報告に含めること」という自然言語の依頼は、`tail` で目視して `--- SKIP` が見えなかったことをもって「SKIP 0件」と誤報告する事故を招いた（依存物が未配置だとテストは無言で `SKIP` され `ok` と表示されるため）。レーン内ゲート（generator）・統合ゲート（run）のどちらも、この自己申告ではなく `count-skips.sh` で機械的に数える。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/count-skips.sh" [--file <テスト出力のログ>] [--pattern <ERE>]
<テスト出力> | bash "${CLAUDE_PLUGIN_ROOT}/scripts/count-skips.sh"
```

出力（1行1項目・機械可読、この順で必ず3行）:

```
skips=<件数 または unknown>
runner=<go|pytest|jest|custom|unknown>
pattern=<実際に使ったERE または none>
```

終了コードは `0`=数えられた `1`=数えられなかった（`skips=unknown`。fail loud） `2`=引数エラー。

判定順序（上から最初に一致したものを使う）:

1. `--pattern` または環境変数 `DEV_WORKFLOW_SKIP_PATTERN` があれば `runner=custom` としてそのEREに一致する行数を数える（最優先）
2. Go と判定できる（`^--- (PASS|FAIL|SKIP)` または `^(ok|FAIL|PASS)` を含む）→ `^--- SKIP` の一致行数
3. jest と判定できる（`^Tests:` を含む）→ `Tests:` 行の `<N> skipped` の N
4. pytest と判定できる（`test session starts` を含む）→ サマリ行の最後の `<N> skipped` の N
5. どれにも当てはまらない → `skips=unknown` / `runner=unknown` / exit 1

built-in ランナー（go/jest/pytest）と異なる出力形式のプロジェクトでは既定で `skips=unknown` になる。この場合に必ず「0件」として扱ってはならない（下記「Epic の `## SKIPパターン` 節」で `DEV_WORKFLOW_SKIP_PATTERN` を設定する）。

### Epic の `## SKIPパターン` 節

駆動先プロジェクトのテスト出力が built-in ランナー（go/jest/pytest）のいずれとも異なる形式で、`count-skips.sh` が既定で `skips=unknown` になる場合に、SKIP行を数える正規表現を Epic issue 本文に明記する。

````markdown
## SKIPパターン

```
^  skip - 
```
````

節があれば run がその内容を `DEV_WORKFLOW_SKIP_PATTERN` として読み取り、Step 3 の各 generator プロンプトと統合ゲートの両方に渡す（`## 準備コマンド` 節と同じ抽出方法）。節が無ければ何も設定されず、built-in ランナーの判定だけが行われる。`skips=unknown` は「0件」を意味しない。built-in ランナー以外の形式で run を止めずに進めるための既定の逃げ道であり、正しい件数を知るには本節でパターンを明記する必要がある。

### Epic の `## 共有ディレクトリ` 節

`/dev-workflow:run` の並列レーンでは、generator の isolation worktree がタスクごとに新規作成
されるため、`## 準備コマンド` 節が `node_modules` / `vendor` 等の**大量のファイルを含む
ディレクトリ**を生成する場合、レーンごとにフル実行すると支配的なコストになる（issue #104。
Windows + Docker Desktop のバインドマウント上で `yarn install` 単独実行が約20分、
5ウェーブ構成の run 全体で install 待ちが総所要時間の半分以上を占めた実測がある）。

`## 共有ディレクトリ` 節は、Epic 専用 worktree に1回だけ作った準備成果ディレクトリを、
各レーンへ**コンテナ内から張った symlink** で共有するための宣言である。書式は空白区切りで
1行に「共有するディレクトリ」と「フィンガープリントファイル」を並べる（すべて
リポジトリルート相対）。

````markdown
## 共有ディレクトリ

```
node_modules  yarn.lock package.json
```
````

- **フィンガープリントには lockfile を必ず書くこと。** 書かないと、依存が変わった後も
  古い成果を共有し続けてしまう
- 節があれば run がその内容を Step 3 の各 generator プロンプトへ渡し、`scripts/share-prepared-dirs.sh`
  が Epic 専用 worktree の成果ディレクトリへの symlink 作成を試みる
- **節が無ければ何もしない**（共有せず、現行どおり各レーンで準備コマンドをフル実行する。
  既存 Epic に完全後方互換）
- symlink 作成に失敗した場合（共有元が無い・フィンガープリント不一致等）は、フォールバックとして
  `## 準備コマンド` 節の内容が実行される
- 依存を追加・更新するタスク（`package.json` / lockfile 等を変更するタスク）では、install 系
  コマンドの前に `share-prepared-dirs.sh --detach` で共有リンクを解除してから install する
  必要がある（generator へは run が指示するが、人間が挙動を追えるようここにも明記する）

### Epic の `## 編集時チェック` 節

「編集 → `sandbox-exec.sh` でビルド/テスト実行 → エラーを読む → 修正」で最低3ターン、かつ
毎回 Docker 往復（1呼び出しあたり約3.4秒。「検証結果のスタンプ（呼び出しごとの固定オーバーヘッド
削減。issue #145）」参照）が発生する。編集直後にホスト側で型チェック単体・lint単体のような
軽量チェックを走らせ、その場で違反をエージェントへ差し戻すことでこのループを縮めるのが
`scripts/edit-check.sh`（`PostToolUse(Write|Edit|MultiEdit)` フック）である。詳細な設計判断は
`docs/adr/0005-edit-time-check-hook.md` を参照。

`## 準備コマンド` / `## SKIPパターン` と同じ機構で、チェック内容をハードコードせず Epic issue
本文から受け取る。書式は空白区切りで1行に「編集ファイルに一致させる glob」と「実行する
コマンド（`{file}` が編集ファイルパスに置換される）」を並べる。上から順に最初に一致した行の
コマンドを使う。

````markdown
## 編集時チェック

```
*.go  gofmt -l {file}
*.ts  npx tsc --noEmit {file}
```
````

- **節が無ければ何もしない**（既存 Epic の挙動を変えない）
- 節があれば run が Epic 開始時に `scripts/edit-check.sh --write` でマーカーファイル
  （`.claude/.dev-workflow-edit-check`。`scripts/lib/marker-root.sh` が解決するメインリポの
  ルート配下、Epic 専用 worktree・各レーンの isolation worktree のいずれから見ても同じ場所）
  へ書き出す。節が無ければ `--clear` で前回 Epic の内容を消す
- **PostToolUse フックは CLI 本体の子プロセスとして起動されるため、generator が Bash ツール
  越しに `export` した環境変数は届かない。** マーカーファイル経由にしているのはこのためで、
  generator 側のプロンプトへ追加の埋め込みは不要（フックが編集のたびに自動発火する）
- **タイムアウトは既定5秒**（`DEV_WORKFLOW_EDIT_CHECK_TIMEOUT` で調整可）。想定するのは
  型チェック単体・lint単体のような**秒オーダーの処理であり、テストスイートではない**。
  テストの実行はレーン内ゲート・統合ゲートが別途担う
- **フック自体のエラー（コマンド不在・タイムアウト）はブロックしない**（`exit 0` で素通り）。
  ブロックするのは「チェックが実行でき、かつ非0終了＝違反が見つかった場合」だけ
- **ホスト側で実行する**（`sandbox-exec.sh` 経由にしない）。Docker 往復削減という目的自体と
  矛盾するため（ADR参照）。ホストにツールチェインが無い場合、その glob 行を書かなければ
  何もしない（フェイルセーフ）
- 差し戻し契約は `check-readability.sh` と同一（`DEV_WORKFLOW_HOOK_VENDOR` で出し分け）

## ハーネス非注入原則

**dev-workflow ハーネス都合のファイル・設定を、駆動先の業務リポジトリに注入しない。**
サンドボックス定義に限らず、permission 設定・マーカー・状態ファイル・worktree 等、
ハーネスが動作のために必要とするものは、業務リポジトリのコミット履歴やPRに混入させない。

| ハーネス由来のもの | あるべき置き場所 |
|---|---|
| サンドボックス定義 | 規約パス `~/.claude/dev-workflow/sandbox/<repo>/` または環境変数。リポジトリ内に置くのは**チームで run を共有する場合に限る** |
| YOLO 用の permission 設定 | gitignore 済みの `.claude/settings.local.json`、またはユーザースコープ。**git 追跡された設定に広範な allow を積まない** |
| マーカー・状態ファイル・worktree | リポジトリ内に置くが、`.git/info/exclude`（コミットされない）で除外する。**`.gitignore` は駆動先の共有ファイルなので触らない** |

### `scripts/check-repo-hygiene.sh`

上記を検証・整備するスクリプト。利用者向けの使い方はここが正本です。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-repo-hygiene.sh"          # 手動チェック（ブロックしない）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-repo-hygiene.sh" --run    # runと同じ判定（ブロックしうる）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-repo-hygiene.sh" --check  # 書き換えず判定だけ行う
```

- 終了コード: `0` = OK（警告があっても0） / `2` = ブロック（引数エラー、または `--run` かつ
  `.claude/settings.local.json` が追跡されておりブロック条件を満たす場合）
- 環境変数 `DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS` を非空に設定すると、`--run` 時のブロックを
  一時的に解除できる（判定は block ではなく warn になる）
- **SessionStart のたびに自動実行され**、`.git/info/exclude` の整備は毎セッション冪等に行われる
  （既存の除外内容が期待値と一致していれば書き込まない）

## YOLOモード（完全自律動作）

実装フェーズ（run）ではユーザー確認を一切行わず完全自律で動作する。

### 推奨 settings.json（モデル構成）

run 本体（`/dev-workflow:run` を解釈しているセッション）は Epic 全体を通して動き続ける、
**最も長寿命なコンテキスト**である。ここを最上位モデルで固定するとコストがウェーブ数に比例して
膨らむ。推奨は「本体は sonnet、難所だけ advisor(opus) に上げる」構成である。

```json
{
  "model": "sonnet",
  "advisorModel": "opus",
  "effortLevel": "xhigh",
  "env": { "ENABLE_TOOL_SEARCH": "true" }
}
```

| 設定 | 効果 |
|---|---|
| `model: sonnet` | オーケストレータ本体のトークン単価を下げる。ウェーブ数に比例するコストがここに集中している |
| `advisorModel: opus` | 難しい判断のときだけ opus に問える。常時 opus とは違い、呼んだ回数分しか払わない |
| `effortLevel: xhigh` | モデルを下げた分の推論深度を戻す。sonnet + xhigh は opus + high より安く、判断品質の劣化を抑えられる |
| `ENABLE_TOOL_SEARCH` | ツール定義を遅延読み込みし、システムプロンプトの固定コストを下げる |

- **generator（sonnet）・evaluator（opus）のモデルはエージェント定義側で固定されており、
  この設定の影響を受けない。** 変わるのはオーケストレータ本体だけである
- **これは推奨であって前提条件ではない。** 未設定でも run は動作する。run は起動時に現在の
  構成を表示するだけで、停止はしない（「停止させるものと、記録して進めるもの」の原則）

**LSP（任意。上記「LSP」節参照）を有効化する場合**は、同じ `settings.json` に
`enabledPlugins` を追加する。`treflebonbon/dotfiles` の `private_dot_claude/settings.json.tmpl`
で確認できた例:

```json
{
  "model": "sonnet",
  "advisorModel": "opus",
  "effortLevel": "xhigh",
  "env": { "ENABLE_TOOL_SEARCH": "true" },
  "enabledPlugins": {
    "typescript-lsp": true,
    "gopls-lsp": true,
    "rust-analyzer-lsp": true,
    "lua-lsp": true
  }
}
```

未設定でも generator は `Grep` / `Read` で従来どおり動作する（前述「LSP」節の「未確認の注意点」参照）。

### パーミッション設定（必須）

YOLOモードではClaude Code本体のパーミッション確認を無効化する必要がある。

#### 置き場所（スコープ）

| 置き場所 | 用途 |
|---|---|
| `.claude/settings.local.json`（**gitignore 済みであること**） | 個人の YOLO 用許可。**既定の置き場所** |
| ユーザースコープ（`~/.claude/settings.json`） | 複数リポジトリで同じ許可を使い回す場合 |
| `.claude/settings.json`（git 追跡） | **チームで共有する場合のみ。** レビューを経て、最小限の許可だけを置く |

**危険性:** git 追跡された設定に広範な allow（`Bash(*)` / `Bash(git *)` 等）をコミットすると、
そのリポジトリを clone したチームメンバー全員の Claude Code セッションに**同意なく適用される**。
個人の判断で入れた YOLO 許可が、リポジトリ経由でチーム全体への権限付与に化ける。

`scripts/check-repo-hygiene.sh` はこれを検知する。**git 追跡された `.claude/settings.local.json`
は run をブロックする**（`DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS=1` で opt-out）。詳細は上記
「ハーネス非注入原則」を参照。

上記いずれかのスコープに、許可・拒否コマンドを設定する:

```json
{
  "permissions": {
    "deny": [
      "Bash(rm *)",
      "Bash(rm)",
      "Bash(rmdir *)",
      "Bash(unlink *)",
      "Bash(shred *)",
      "Bash(* rm *)",
      "Bash(* rmdir *)",
      "PowerShell(Remove-Item *)",
      "PowerShell(* Remove-Item *)",
      "PowerShell(del *)",
      "PowerShell(* del *)",
      "PowerShell(rd *)",
      "PowerShell(* rd *)"
    ],
    "allow": [
      "Bash(*)",
      "PowerShell(*)",
      "Edit",
      "Write",
      "NotebookEdit"
    ]
  }
}
```

> **ルール優先度:** `deny` は `allow` より常に優先される。  
> `rm` 系コマンドはパイプや `&&` 経由でも個別にブロックされる。  
> プロジェクトのビルド・テストコマンドは `allow` に追加してください。

### 停止させるものと、記録して進めるもの

自律ループを止めてよいのは、**続行すると成果物が壊れる**場合に限る。それ以外は記録して進む。

| 種別 | 例 | 扱い |
|---|---|---|
| **停止** | リポジトリ衛生プリフライト exit 2 / サンドボックス `mode=none` / 循環依存 | run を開始しない・停止する |
| **差し戻し** | レーン内ゲート失敗 / 統合ゲート失敗 / ベース逸脱・競合 | 取り込まず次ウェーブへ持ち越す（ループは止めない） |
| **記録して進む** | `skips=unknown` / トークン数が読み取れない / 準備コマンドの `--warm` 失敗 / worktree 削除失敗 / Slack 通知失敗 | 事実を Epic issue と PR 本文に残し、そのまま次へ進む |

「記録して進む」に分類したものを停止条件に格上げしない。これらは成果物の正しさを左右しない観測項目であり、ここで止めると人間が戻るまで run 全体が遊ぶ。**同時に、記録を省略して黙って進むことも禁止する**——`skips=unknown` を「0件」と読み替えないのはこの原則の帰結である。

### 自律動作ポリシー

- ユーザーへの質問・確認は行わない
- 問題発生時はissueにコメントを残してスキップし、次のタスクへ進む
- 同一タスクで機械的ゲート（テスト・ビルド・可読性）に3回失敗 → スキップ
- テスト5回連続失敗 → スキップ
- スキップしたタスクはPR本文に明示される
- Epic一括レビューは最大2巡。未対応の指摘はissueを開いたままPR本文に明示される

### テスト時の注意事項

- **メール送信:** テスト実行時に実ユーザーにメールが送信されないよう細心の注意を払うこと。テスト用の受信アドレス（mailhog, mailtrap等）が設定されていない場合は、タスクを中断し、issueにコメントを残して開発者（人間）にテスト用メール設定を促すこと
- **本番データの保護:** いかなる理由においても本番環境のデータを編集・削除・変更しないこと。本番データは常に非侵襲であること。テスト時はDocker sandbox内のテスト用データベースのみを使用すること

## 可読性ガード

**「ソースを読めば何をしているのか分かる」状態を、AIの自律判断に関わらず決定論的に守る機構。** 可読性を犠牲にした効率化（コンテンツの base64+gzip 化、ミニファイ/難読化されたソースのコミット、元の人間可読ソースの消失）を抑止する。

### 仕組み（多層防御）

| 層 | 内容 |
|---|---|
| **フック**（中核） | `PostToolUse(Write/Edit)` と `Stop` で `check-readability.sh` が変更を走査。違反を検出すると**ブロックし、理由をエージェントに差し戻す**（自己修正ループ）。AIの判断に依存しない |
| **git pre-commit**（任意） | CLIを問わず、コミット時にステージ済みの変更を走査してブロックする。下記で設置する |
| **generator** | 「ソースは人間可読／生成物を正本にしない／元ソースを必ず残す」を最優先ルールとして遵守 |
| **evaluator** | Epic一括レビューで可読性違反を**重要度「高」の必須対応指摘**として扱う |

### git pre-commit への設置（ベンダー非依存の最終防衛線）

CLIのフックは「編集直後の即時フィードバック」を担いますが、素の `git commit` や別のツールから
編集された場合は通りません。git 側にも同じガードを置くと、どこから編集してもコミットは通らなくなります。

```bash
# 設置（既存の pre-commit がある場合は壊さず追記する）
bash "${CLAUDE_PLUGIN_ROOT}/adapters/common/install-git-hooks.sh" .

# 解除
bash "${CLAUDE_PLUGIN_ROOT}/adapters/common/install-git-hooks.sh" --uninstall .
```

一時的に回避する場合は `READABILITY_GUARD=off git commit ...` とします。

### 検出するもの

- 巨大な base64 ブロブ（コンテンツ/データをエンコードしてソースに埋め込む）
- 極端に長い行（ミニファイ/難読化されたコードのコミット）

### 誤検知対策

- **許可リスト:** lock ファイル、`__snapshots__`、`fixtures`/`testdata`、`node_modules`/`vendor`、`*.min.*`、`*.svg`、`*.generated.*`、gitignore 済みファイル等は自動で除外
- **エスケープハッチ:** どうしてもエンコード済みデータが必要な場合、ファイル内に `readability-guard:allow <理由>` と書くと当該ファイルを除外。**人間可読な正当化をソースに残させる**ことで抑止の理念と整合させる

### 調整（環境変数）

```bash
READABILITY_GUARD=off          # ガード全体を無効化
READABILITY_MAX_BASE64=2000    # 連続base64文字列の許容上限（文字数）
READABILITY_MAX_LINE=5000      # ソース1行の許容上限（文字数）
```

### ブロック契約（マルチベンダー対応）

違反の通知方法はCLIごとに契約が異なるため、実行中のCLIを自動判定して出し分けます。

| 実行環境 | 判定条件 | 通知方法 |
|---|---|---|
| Claude Code | 既定 | `exit 2` + stderr |
| Codex CLI | `PLUGIN_ROOT` が設定済み、または入力JSONに `turn_id` がある | `exit 0` + stdout に `{"continue": false, ...}` |
| git pre-commit | インストーラが `DEV_WORKFLOW_HOOK_VENDOR=exit-code` を設定 | `exit 1` + stderr |

`DEV_WORKFLOW_HOOK_VENDOR=claude|codex|exit-code` で自動判定を上書きできます（デバッグ・CI用）。

## サンドボックス設定

実装・テストに使うコンテナの設定は環境変数を正本として解決します（plugin userConfig は
他CLIに相当物がないため）。

```bash
DEV_WORKFLOW_DOCKER_IMAGE=my-image:tag      # 既存イメージを使う（ビルドしない）
DEV_WORKFLOW_DOCKER_COMPOSE_FILE=path.yml   # 使用する compose ファイル
DEV_WORKFLOW_DOCKERFILE=path                # 使用する Dockerfile（既定: Dockerfile.dev）
DEV_WORKFLOW_SANDBOX_HOME=path              # 規約パスのベースディレクトリ（既定: ~/.claude/dev-workflow/sandbox）
DEV_WORKFLOW_DOCKER_BUILD_CONTEXT=path      # ビルドコンテキストの明示指定（最優先）
```

### 解決順

| 順 | 条件 | 結果 |
|---|---|---|
| 1 | `DEV_WORKFLOW_DOCKER_IMAGE` が非空 | 既存イメージを使う（ビルドしない） |
| 2 | `${DEV_WORKFLOW_DOCKERFILE:-Dockerfile.dev}` が存在 | その Dockerfile をビルド |
| 3 | `${DEV_WORKFLOW_DOCKER_COMPOSE_FILE:-docker-compose.dev.yml}` が存在 | compose を使う |
| 4 | `<SANDBOX_HOME>/<repo>/Dockerfile.dev` が存在 | その Dockerfile をビルド |
| 5 | `<SANDBOX_HOME>/<repo>/docker-compose.dev.yml` が存在 | compose を使う |
| 6 | いずれも不成立 | `mode=none`（run は開始しない） |

`<SANDBOX_HOME>` は `DEV_WORKFLOW_SANDBOX_HOME`（既定 `~/.claude/dev-workflow/sandbox`）、
`<repo>` は `basename(リポジトリルート)` です。

現在の解決結果は次のコマンドで確認できます。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-sandbox.sh" --print
```

### ビルドコンテキスト

Dockerfile がリポジトリルート外（規約パス等）にある場合、ビルドコンテキストは
**リポジトリルート**になります（compose の `--project-directory` 固定と同じ思想）。これにより
規約パスに置いた Dockerfile でも `COPY package*.json ./` が動きます。リポジトリ内に置いた
Dockerfile の挙動は従来どおり `dirname(Dockerfile)` のままで変わりません。
`DEV_WORKFLOW_DOCKER_BUILD_CONTEXT` を設定するとこの既定を上書きし、常にその値をビルド
コンテキストとして使います（最優先）。

### 分離単位（コンテナ = epic / キャッシュ = リポジトリ / イメージ = Dockerfileのhash）

3つの資源はそれぞれ異なる単位で分離・共有されます。

| 資源 | 分離・共有の単位 | 命名 |
| --- | --- | --- |
| コンテナ | **epic 単位** | `dw-sandbox-<repo>[-<epic>]` |
| キャッシュ volume | **リポジトリ単位**（epic 間で共有） | `dw-cache-<repo>-<path>` |
| イメージ | **Dockerfile 内容の hash 単位** | `dev-sandbox:<repo>-<hash8>` |

バインドマウントはリポジトリルートに固定しているため、generator の isolation worktree
（`.claude/worktrees/agent-*`）や epic worktree がいくつ増えてもコンテナは epic あたり1個のままです。
**あえて非対称にしています**: キャッシュだけリポジトリ単位で共有し続けるのは、それが v0.10.0 の性能改善
（40秒→17秒）の本体であり、epic 単位にすると新しい epic が毎回コールドスタートに戻ってしまうためです。
非対称であることの唯一の実害は `--reset-cache` の誤爆（他 epic のキャッシュまで巻き込む）なので、
そこだけを running コンテナ検出のガードで潰しています（後述）。

#### 検証結果のスタンプ（呼び出しごとの固定オーバーヘッド削減。issue #145）

dockerfile モードは1回の呼び出しで前置きの検証（イメージ存在・コンテナ存在・マウント元・
イメージIDスキュー・running確認）に docker CLI が最大7回呼ばれ、Windows実測で約1.7秒かかります
（Epicあたり数分の固定オーバーヘッド）。これを毎回やり直す代わりに、フル検証が成功した直後に
「コンテナ名・解決イメージID・正規化済みマウント元」を**スタンプ**として
`${DEV_WORKFLOW_STAMP_HOME:-${HOME}/.claude/dev-workflow/stamps}` 配下に残します。次回以降は
この3点が現在の状態と一致し、かつコンテナが running のときだけ、前置き検証を「現在のイメージID
再確認＋running確認」の2回に短縮し `docker exec` へ直行します（fast path）。

**fail-safe**: スタンプが無い・読めない・3点のいずれかが不一致・`--rebuild` 指定時は、
必ず従来どおりのフル検証に戻ります。`--down` / `--reset-cache` はコンテナ削除と同時にスタンプも
無効化します。スタンプはリポジトリの追跡ファイルにせず `${HOME}` 配下に置くため、ハーネス非注入
原則に適合します（Epic 専用 worktree と各レーンの isolation worktree の両方から共通に読めます）。
`--print-plan` はスタンプの有無に関わらず docker に一切触れません（従来どおり）。
compose モードは対象外です（詳細は `docs/adr/0002-sandbox-overhead-reduction.md`）。

#### レーンスコープ・キャッシュ（並列レーンの資源競合の緩和。issue #145）

キャッシュ volume はリポジトリ単位で共有するため、cargo registry・yarn v1 等
**グローバルロックを取るキャッシュ**では並列レーンが直列化することがあります。volume 自体は
分割せず、`DEV_WORKFLOW_LANE_SCOPED_CACHE_ENV` で宣言した環境変数だけを、同じ volume 内の
レーン別サブディレクトリ（`<宣言パス>/lanes/<レーンスコープ>`）に向けます。

```bash
DEV_WORKFLOW_LANE_SCOPED_CACHE_ENV='CARGO_HOME=/root/.cargo/registry'
```

レーンスコープは呼び出し元 worktree から自動的に決まります: `.claude/worktrees/agent-*`
（generator の isolation worktree）から呼ばれたら `agent-xxxx`、それ以外（リポジトリルート・
epic worktree）は `shared` です。`shared` のときは env 上書きを行わず、従来どおり共有
ディレクトリを使います。**既定は未宣言（空）で、現行と完全に同一の挙動です。** volume 名・
`--reset-cache` / `--ls` / `--down` の作用範囲は変わりません（レーン別サブディレクトリも
同じ volume 内にあるため `--reset-cache` で一緒に消えます）。設計判断の詳細は
`docs/adr/0002-sandbox-overhead-reduction.md` を参照してください。

### サンドボックスへのコマンド投入

`docker run` を直接組み立てず、`sandbox-exec.sh` を使います。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic epic259 'make test'
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic epic259 --warm 'go build ./...'
```

このスクリプトが引き受けること:

| 項目 | 内容 |
| --- | --- |
| イメージの解決とビルド | `Dockerfile.dev` があれば内容の hash でタグ付けして自動ビルドする（`DEV_WORKFLOW_DOCKER_IMAGE` 指定時はビルドしない） |
| ビルドキャッシュの永続化 | `docker run --rm` はコンテナ層ごとキャッシュを毎回捨てる。言語ごとのキャッシュディレクトリを named volume 化して次回に残す |
| コンテナの再利用 | epic単位で常駐させ `docker exec` で叩き、起動オーバーヘッドを消す。既存コンテナのマウント元・イメージIDが期待値と異なれば削除して作り直す |
| Windows のパス変換対策 | Git Bash（MSYS）は `-w /workspace` を `C:/Program Files/Git/workspace` に変換して `docker run` を失敗させる |
| イメージタグの安定化 | タグをリポジトリ名 + Dockerfile 内容の hash にし、worktree ごとに同じイメージをビルドし直す事故を防ぐ |

終了コードは実行したコマンドのものがそのまま返るので、機械的ゲートの判定に使えます。

volume 化するパスは既定で Go / Node / Rust / Python 向けを網羅します。イメージが root 以外の
ユーザーで動く場合は `DEV_WORKFLOW_CACHE_PATHS`（スペース区切り）で上書きしてください。
compose モードで exec するサービス名は `DEV_WORKFLOW_COMPOSE_SERVICE`（既定: `app`）で変えられます。

> **待ち時間の主因はコンパイルではなくバインドマウントのI/O**（Windows 実測）。
> フルツリーを走査するコマンドは1回ごとに走査コストを払うため、
> **ビルド・vet・テストを別々に呼ばず1回にまとめる**ことが最も効きます。

### ライフサイクル操作

| コマンド | 動作 |
| --- | --- |
| `--down` | 現在の repo + epic のコンテナ1個を削除する（キャッシュ volume は残す）。**compose モードのときは** `docker compose -p <project> --project-directory <root> -f <compose_file> down` で現在の project を落とす |
| `--down --all` | 現在のリポジトリに属する管理コンテナをすべて削除する（削除前に対象名を列挙表示。label が無い旧命名の残骸も、マウント元がリポジトリルート配下かで判定して回収する）。**compose モードのときは** `com.docker.compose.project.working_dir` label（＝ `--project-directory` に渡した値）を正規化してリポジトリルート配下と判定できた compose project だけを列挙表示のうえすべて down する（project 名の接頭辞一致では他リポジトリの project を巻き込むため使わない）。リポジトリ外 worktree のフォールバック実行で起動した project は working_dir がリポジトリルート外になるため対象に含まれない |
| `--ls` | 管理コンテナを一覧表示する（NAME / REPO / EPIC / IMAGE / STATUS / CREATED。他リポジトリ分も含む）。**compose モードのときは** compose project の一覧（PROJECT / STATUS）も併せて表示する |
| `--reset-cache [--force]` | キャッシュ volume を削除する（下記「作用範囲」を参照） |
| `--rebuild` | イメージを強制再ビルドし、コンテナも作り直してからコマンドを実行する |
| `--print-plan` | docker に一切触れず、解決結果を `key=value` 形式で表示するドライラン（下記） |

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic epic259 --down
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --down --all
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --ls
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --reset-cache
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic epic259 --rebuild 'make test'
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic epic259 --print-plan
```

#### `--reset-cache` の作用範囲はリポジトリ全体（epicではない）

キャッシュ volume はリポジトリ単位で共有しているため、`--reset-cache` は**現在の epic だけでなく
同一リポジトリの全 epic のキャッシュを削除**します。誤爆を防ぐため:

1. 削除対象の volume 名をすべて列挙表示します（成否によらず必ず表示）。
2. 同一リポジトリの管理コンテナが**1つでも running なら中断**し、`--force` の指定を促します
   （他 epic が実行中にキャッシュを壊さないためのガード）。
3. `--force` を指定した場合のみ、running なコンテナがあっても実行します。

volume 自体は分割していないため、`DEV_WORKFLOW_LANE_SCOPED_CACHE_ENV` で作ったレーン別
サブディレクトリ（`<パス>/lanes/<レーンスコープ>`）も同じ volume 内にあり、`--reset-cache` で
まとめて削除されます（前述「レーンスコープ・キャッシュ」参照）。

#### `--rebuild` の使いどころ

イメージタグは `Dockerfile.dev` の内容の hash（`git hash-object` の先頭8文字）から自動的に決まるため、
`Dockerfile.dev` 自体を編集すれば自動的に別タグになり、再ビルドされます。
しかし hash は **Dockerfile の内容しか見ない**ため、`COPY go.mod .` のように Dockerfile がコピーする
対象ファイル（`go.mod` / `package.json` 等）だけを変更した場合は、タグが変わらず古い内容のイメージが
再利用されてしまいます。この逃げ道が `--rebuild` です。内容に変更が無くても強制的に
`docker build` からやり直し、コンテナも作り直します。

#### `--print-plan`（ドライラン）

docker に一切触れず、解決結果を `key=value` 形式で標準出力に表示して終了します（exit 0）。
人間のデバッグ手段としても、CI・テストでの検証手段としても使えます。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic epic259 --print-plan
```

出力キー:

| キー | 内容 |
| --- | --- |
| `mode` | `dockerfile` / `compose` / `none` |
| `repo` | リポジトリ名（`basename(REPO_ROOT)`。worktree名は使わない） |
| `epic` | epic 識別子（`--epic` または `DEV_WORKFLOW_EPIC`。無ければ空） |
| `repo_root` | ホスト側のリポジトリルート |
| `mount_source` | マウント元（dockerfileモード時） |
| `mount_target` | マウント先（常に `/workspace`） |
| `workdir` | コンテナ内の作業ディレクトリ（リポジトリルートからの相対パスを反映） |
| `rel_path` | リポジトリルートからの相対パス（ルート直下なら空） |
| `fallback` | `1` ならリポジトリ外worktreeのフォールバック中（`0`が通常） |
| `container` | コンテナ名 |
| `image` | イメージタグ |
| `dockerfile` | 使用する Dockerfile のパス（dockerfileモード時） |
| `build_context` | ビルドコンテキスト（dockerfileモード時） |
| `compose_file` / `compose_project` / `compose_service` | composeモード時の設定 |
| `cache_volume` | `<volume名>:<コンテナ内パス>`（キャッシュパスの数だけ複数行） |

### compose モード

`docker-compose.dev.yml` を使う場合、compose ファイルは次の要求仕様を満たす必要があります。

- **常駐サービス名**: 既定 `app`（`DEV_WORKFLOW_COMPOSE_SERVICE` で変更可）
- **マウント**: 当該サービスが `.:/workspace` をマウントすること
  （異なるマウント先にする場合は `DEV_WORKFLOW_COMPOSE_WORKDIR` で上書きする）
- **長時間常駐**: `sleep infinity` 等でプロセスが終了しないこと
  （running でなければ `sandbox-exec.sh` が `up -d` を試み、それでも起動しなければ原因の分かる
  エラーで停止する）

呼び出しは `docker compose -p <PROJECT> --project-directory <HOST_ROOT> -f <compose_file> ...` で行い、
`--project-directory` をリポジトリルートに固定することで、compose ファイル内の相対マウント（`.`）が
どの worktree から叩いても同じツリーを指すようにしています。`PROJECT`（`dw-<repo>[-<epic>]`）は
コンテナ名と同じ元から作るため、リポジトリ外に作られた worktree（フォールバック時）はコンテナ名・
project 名の両方が epic 共有のものと分離されます。既存サービスが running でもマウント元が期待値と
異なれば削除して作り直すため、別ツリーのファイルへ静かに exec してしまう経路はありません。

**既知の限界**: compose ファイルが `container_name:` または固定ホストポート（例: `- "8080:8080"`）を
使っていると、`-p` によるプロジェクト名の分離では解決できない衝突が起き、**epic の並行実行ができません**。
`sandbox-exec.sh` はこれを検出して stderr に警告しますが、自動では直せません。
`container_name:` を使わない・ホストポートは固定せずコンテナ側ポートのみ指定する、で回避してください。

**既知の限界（キャッシュ volume）**: `DEV_WORKFLOW_CACHE_PATHS` によるビルドキャッシュの
volume 化は **dockerfile モード専用**であり、compose モードでは一切マウントされません
（`sandbox-exec.sh` の `cache_mount_args` は `docker run` を使う dockerfile 分岐でしか
呼ばれていません）。compose で同等のキャッシュを効かせるには、compose ファイル側で
named volume を定義する必要があります。**`sandbox-exec.sh` は利用者の compose ファイルへ
介入しません。** そのままコピーして使えるサンプルは以下のとおりです。

```yaml
# docker-compose.dev.yml の例（app サービスにキャッシュ用 named volume を並べる）
services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - .:/workspace
      - yarn-cache:/usr/local/share/.cache/yarn
      - npm-cache:/root/.npm
      - pip-cache:/root/.cache/pip
    working_dir: /workspace
    command: sleep infinity

volumes:
  yarn-cache:
  npm-cache:
  pip-cache:
```

**後片付け**: compose モードで起動されたコンテナは通常の `dw-sandbox-*` という名前を持たないため、
`--down` / `--down --all` / `--ls` はいずれも `docker compose ... down`（`-p` / `--project-directory` 付き）
を使って対応します。詳細は上記「ライフサイクル操作」を参照してください。

### Windows の CRLF に注意

このリポジトリは `.gitattributes` で以下を LF 固定しています。

```
*.sh text eol=lf
*.toml text eol=lf
.gitattributes text eol=lf
```

Windows の `core.autocrlf=true` 環境では、これが無いとシェルスクリプトが CRLF でチェックアウトされ、
行末の `\r` が文字列に混入して `syntax error near unexpected token $'{\r'` のような形で壊れます
（`.gitattributes` 自身も対象にしないと、そのファイル自体がCRLF化されて `git check-attr` の
パターン解決ごと壊れるため、自己参照ルールも必須です）。

**注意: `.gitattributes` にルールを追加しただけでは、既にリポジトリにコミット済みのファイルは
遡って正規化されません。** 新しいルールを追加した直後は、次のコマンドで既存のワーキングツリーを
再正規化する必要があります（本 Epic で実際にこれを踏みました）。

```bash
git rm --cached -r .
git reset --hard
```

新規にシェルスクリプトを追加する場合は、`.gitattributes` に対象パターンが含まれているか確認してください。

### 環境変数一覧

```bash
DEV_WORKFLOW_DOCKER_IMAGE=my-image:tag       # 既存イメージを使う（ビルドしない）
DEV_WORKFLOW_DOCKER_COMPOSE_FILE=path.yml    # 使用する compose ファイル
DEV_WORKFLOW_DOCKERFILE=path                 # 使用する Dockerfile（既定: Dockerfile.dev）
DEV_WORKFLOW_SANDBOX_HOME=path                # 規約パスのベースディレクトリ（既定: ~/.claude/dev-workflow/sandbox）
DEV_WORKFLOW_DOCKER_BUILD_CONTEXT=path        # ビルドコンテキストの明示指定（最優先）
DEV_WORKFLOW_CACHE_PATHS="/path1 /path2"     # volume化するコンテナ内パス（スペース区切り）
DEV_WORKFLOW_EPIC=epic259                    # --epic 未指定時に参照する epic 識別子
DEV_WORKFLOW_COMPOSE_SERVICE=app             # composeモードでexecするサービス名
DEV_WORKFLOW_COMPOSE_WORKDIR=/workspace      # composeモードでのコンテナ内マウント先の基点
READABILITY_STDIN_TIMEOUT=5                  # 可読性ガードが引数なし・非tty時にstdinを待つ上限秒数
DEV_WORKFLOW_SANDBOX_EXEC=path/to/sandbox-exec.sh  # share-prepared-dirs.shが使うsandbox-exec.shのパス
                                                    # （既定: share-prepared-dirs.shと同じディレクトリ。テストでスタブに差し替える口）
```

## Slack通知

**自律実行の完了・許可プロンプトをSlackに通知する。** 長時間の自律実行を放置しておいて、止まったタイミングだけ気づける。

### 設定（プロジェクトごと）

通知先はプロジェクト単位で設定する。**未設定のプロジェクトでは通知は一切行われない（通知OFF扱い）。**

1. Slackで [Incoming Webhook](https://api.slack.com/messaging/webhooks) を作成し、URLを取得
2. プロジェクトルートに `.claude/slack-webhook` を作成

```
# .claude/slack-webhook
name=tessera (API)
https://hooks.slack.com/services/XXX/YYY/ZZZ
```

- `https://` で始まる最初の行がWebhook URL（必須）
- `name=` 行は通知に表示するプロジェクト名（任意、既定はディレクトリ名）
- `mention=` 行はメンション先（任意、**既定は `channel` ＝ 全通知が `@channel`**）
- `#` 始まりの行はコメント

`mention=` に指定できる値:

| 値 | 動作 |
|---|---|
| `channel`（既定） | `@channel` — チャンネル全員に通知 |
| `here` | `@here` — オンラインのメンバーのみ |
| `none` | メンションなし |
| `<@U123ABC>` | 特定ユーザーへのメンション（SlackのメンバーID） |

3. `.claude/slack-webhook` は `.gitignore` に追加しない。ハーネス生成物の除外は、コミットされない
   ローカル設定である `.git/info/exclude` で行う（**`.gitignore` は駆動先チームの共有ファイルなので
   触らない** — 上記「ハーネス非注入原則」参照）。この整備は `scripts/check-repo-hygiene.sh` が
   SessionStart のたびに冪等に行うため、手作業は不要である。なお Webhook URL は秘密情報なので、
   除外方法にかかわらずコミットしないこと

環境変数 `SLACK_WEBHOOK_URL` / `DEV_WORKFLOW_PROJECT_NAME` でも指定できる（ファイル設定が優先）。メンションは `DEV_WORKFLOW_SLACK_MENTION` で上書きでき、こちらはファイル設定より優先される。

### 通知されるタイミング

| タイミング | フック | 内容 |
|---|---|---|
| **許可プロンプト表示** | `Notification` | `:lock: 承認待ち` — ファイルアクセス等の承認でエージェントが止まったとき |
| **入力待ちで放置** | `Notification` | `:hourglass: 入力待ち` — **既定でOFF**（下記） |
| **自律実行の完全な完了** | skill | `:white_check_mark: 完了` — 全タスク完了＋PR作成まで到達したとき |
| **自律実行の途中停止** | `Stop` | `:octagonal_sign: 自律実行が停止` — 完了に到達せず止まったとき |
| **通常の応答完了** | `Stop` | `:white_check_mark: 応答完了` — 既定でOFF（下記） |

通知は必ず `[プロジェクト名]` から始まり、ブランチ名と作業ディレクトリも添えられるため、複数プロジェクトを並行実行していても発信元が分かる。

### 「入力待ち」通知が既定でOFFの理由

`Notification` フックは、人の操作を必要としない場面（サブエージェントの切り替え、LLMの応答待ちなど）でも発火する。**それらとユーザー入力待ちを文言で区別できなかった**ため、待たせていないタイミングで通知が飛び続けた。

そこで **`:hourglass: 入力待ち` は既定で送信しない**。実際に人を止めているのは承認プロンプトであり、そちらは引き続き通知される。

どうしても入力待ちも受け取りたい場合のみ、明示的に有効化する:

```json
// .claude/settings.json
{
  "env": {
    "DEV_WORKFLOW_NOTIFY_IDLE": "1"
  }
}
```

承認待ち・入力待ちのいずれの文言にも一致しない通知は、従来どおり黙って捨てられる。

同じ内容の通知が繰り返し発火した場合に備え、**同一内容は既定で10分間抑止される**。間隔は `DEV_WORKFLOW_NOTIFY_COOLDOWN`（秒、`0` で無効）で変更できる。

それでも不要な通知が届く場合は `DEV_WORKFLOW_NOTIFY_DEBUG=1` を設定すると、受け取った payload が `.claude/.dev-workflow-notify.log` に記録され、どの文言で発火しているか確認できる。

### 「完全な完了」と「途中停止」の区別

`Stop` フックは毎ターン発火するだけで、自律実行がやり切ったのか途中で止まったのかを区別できない。そこでマーカーファイルで判別する:

1. `/run`・`/goal` はループ開始時に `.claude/.dev-workflow-run` を作成する
2. **PR作成まで到達した場合のみ** `run-complete` を実行 → マーカーを消して `:white_check_mark: 完了`（PR URL付き）を通知
3. マーカーが残ったまま `Stop` した場合 → 完了地点に到達していない ＝ `:octagonal_sign: 自律実行が停止` を通知

これにより、**エラーで落ちた・承認待ちで止まった・コンテキストが尽きた**といった「静かな失敗」も取りこぼさずに通知される。停止通知は鳴り続けないよう1回だけ送られる。

マーカーは一時ファイルであり、`.git/info/exclude`（コミットされないローカル除外設定）で
自動的に除外される。**`.gitignore` は駆動先チームの共有ファイルなので触らない**（上記
「ハーネス非注入原則」参照）。この整備は `scripts/check-repo-hygiene.sh` が SessionStart の
たびに冪等に行う。

（通知の抑止状態を持つ `.claude/.dev-workflow-notify-last` とデバッグログも同じ仕組みで除外される）

### 通常の応答完了通知の有効化

自律実行と関係ない通常のターン終了は、毎ターン鳴ってしまうため既定でOFF。必要なプロジェクトでのみ有効にする:

```json
// .claude/settings.json
{
  "env": {
    "DEV_WORKFLOW_NOTIFY_STOP": "1"
  }
}
```

> **注意:** `--dangerously-skip-permissions`（完全なYOLO）では許可プロンプト自体が発生しないため、承認待ち通知も発生しない。`/run`・`/goal` は allowlist ベースで動作するため、許可されていない操作に当たった際は通知される。
>
> 停止通知・応答完了通知の要約表示には `jq` が必要（未インストールでも通知自体は届く）。「完了」通知はskillが渡すサマリーを使うため `jq` は不要。

## 運用手順（watchdog）

**run は無応答・スリープを検知すると Slack で通知するが、自動では打ち切らない。** 待つか打ち切るかは常に人間が判断する（Epic #42「決定事項」）。

### 通知の読み方

| 通知 | 意味 |
|---|---|
| `:rotating_light: 応答なし` | heartbeat の無活動が15分（既定）を超えた。本文の `state` で原因を切り分けられる。`ツール実行中に停止` → サンドボックス（Docker）側を疑う／`モデルの応答待ちで停止` → API側のスロットリングを疑う。ストールが続く限り30分ごと最大3回まで再通知される |
| `:zzz: スリープ痕跡` | tick の実経過が想定より大きく飛んだ（PCのスリープ・休止からの復帰と推定）。この分は無活動時間の判定から差し引かれるため、復帰直後を長時間ストールとして誤報しない |
| `:hourglass_flowing_sand: 想定時間超過` | ウェーブの経過時間が予算（既定90分。Task issue の `- 想定時間:` から自動算出）を超えた |
| `:arrow_forward: 応答が再開` | 上記の無活動から復帰した |

### ハングしたときの対処

1. **通知本文の `state` で切り分ける**
   - `ツール実行中` → Docker側を疑う。`bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --ls` でコンテナの状態を確認する
   - `モデル応答待ち` → API側を疑う
2. **待つか打ち切るかを人間が判断する。** watchdog は自動では止めない
3. **打ち切る場合**: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --abort "理由"` を実行する。これはエージェントが次にツールを呼んだ瞬間に効く（`heartbeat.sh pre` がフラグを見て拒否する経路のため）。**応答待ちの最中には効かない。** 即座に止めたい場合は Claude Code 側のセッションを中断する。**セッションを中断した場合は Stop フックが走らず run マーカー（`.dev-workflow-run`）が削除されないまま残るため、続けて `bash "${CLAUDE_PLUGIN_ROOT}/scripts/watchdog.sh" --stop` を実行して watchdog を止めること。** 放置すると watchdog は打ち切りに気付かず無活動検知・エスカレーション通知を続けてしまう
4. **再開する場合**: `/dev-workflow:run #<epic番号>` を再実行する。残タスクは open な Task issue から再計算され（クローズ済みタスクはやり直さない）、wave ブランチは残骸ブランチの番号から採番し直され、統合ゲートを通過済みのコミットは Epic ブランチ上に残り続ける（失われない）

### スリープ抑止

watchdog は稼働中、tick（既定60秒）ごとに OS のスリープタイマーをリセットする（既定 ON）。`DEV_WORKFLOW_NO_SLEEP_INHIBIT=1` で無効化できる。

**抑止できないもの:**

- ノートPCの**ふたを閉じる操作**
- ユーザーが明示的に実行する**スリープ・休止**
- **バッテリー切れ**
- **OSの更新による再起動**

### watchdog の環境変数一覧

```bash
DEV_WORKFLOW_WATCHDOG_TICK_SEC=60        # tick間隔（秒）
DEV_WORKFLOW_WATCHDOG_MAX_SEC=86400      # 監視デーモンの最大寿命（秒、既定24時間）
DEV_WORKFLOW_WATCHDOG_IDLE_SEC=900       # 無活動しきい値（秒、既定15分）
DEV_WORKFLOW_WATCHDOG_ESCALATE_SEC=1800  # エスカレーション再通知間隔（秒、既定30分・最大3回）
DEV_WORKFLOW_NO_SLEEP_INHIBIT=1          # スリープ抑止を完全に無効化する
```

## プロジェクト固有のカスタマイズ

エージェントはプロジェクトの `CLAUDE.md` と `.claude/rules/` を自動的に読み込みます。  
プロジェクト固有のルール（コーディング規約、禁止事項、設計思想）はそこに記載してください。

## Codex CLI で使う

このプラグインは Claude Code と Codex CLI の**両方のプラグイン**として動作します。
Claude Code が利用不能になったときのフェイルオーバー先として、平常時に用意しておくことを推奨します。

役割定義・ワークフロー規約・可読性原則・安全ルールは両CLIで**同じ `core/` を正本**にしているため、
どちらで作業しても同じルールで動きます。

### 導入

```bash
# 1. マーケットプレイスとプラグインを追加
codex plugin marketplace add masatoImayama/claude-dev-workflow-marketplace
codex plugin add dev-workflow@dev-workflow-marketplace

# 2. サブエージェント定義をプロジェクトに設置
#    （Codexのプラグインは agents を配布できないためコピーが必要）
bash "${CLAUDE_PLUGIN_ROOT}/adapters/codex/install-agents.sh" .

# 3. 生成物をコミット（障害時に生成処理を実行できない可能性があるため）
git add .codex/agents/ && git commit -m "chore: Codex用サブエージェント定義を配置"
```

Codex 側のスキルは `dev-workflow-plan` / `dev-workflow-run` / `dev-workflow-goal` /
`install-codex-agents` です。初回はプラグイン同梱フックの**信頼付与**を求められます
（承認しないと可読性ガードが働きません）。

### 無人で回す

```bash
DEV_WORKFLOW_TEST_CMD='<プロジェクトの全テストコマンド>' \
  bash "${CLAUDE_PLUGIN_ROOT}/adapters/codex/run-loop.sh" <Epic issue番号>
```

ループをシェル側に置き、1回の `codex exec` = 1役として起動するため、役割ごとに文脈が分離されます。

`DEV_WORKFLOW_TEST_CMD` は**必須**です（例: `DEV_WORKFLOW_TEST_CMD='bash tests/run-tests.sh'`）。
未設定だと `run-loop.sh` は起動直後に `exit 1` します。既定値を置いていないのは、対象テストの選定を
generator に委ねると一部しか実行されず回帰を見逃すため（#37 の再発防止）で、**Epic 統合ゲート**
（全タスク完了後にEpicにつき1回）は常にこのコマンドでプロジェクトの全テストを実行します
（#144。ウェーブ＝タスクごとには実行しません）。

`DEV_WORKFLOW_DRY_RUN=1` を付けると実行内容の確認だけができますが、
`DEV_WORKFLOW_TEST_CMD` の必須チェックは DRY_RUN より前に走るため、DRY_RUN で確認する場合も
`DEV_WORKFLOW_TEST_CMD` は設定してください。

### Claude Code との差分

| 項目 | Claude Code | Codex |
|---|---|---|
| 役割ごとのモデル指定 | `agents/*.md` の `model` | `.codex/agents/*.toml` の `model`（既定は継承。環境変数で指定可） |
| レビュアーの書き込み禁止 | `disallowedTools: Write, Edit` | `sandbox_mode = "read-only"` |
| ターン数の上限 | `maxTurns` | **相当機能なし。** ループ側の反復上限とプロンプト規約で担保 |
| サブエージェント専用worktree | `isolation: worktree`（自動） | **なし。** generator を並行実行しない設計 |
| 判定JSONの強制 | なし（本文から読み取り） | `--output-schema` でスキーマ強制 |
| 「入力待ち」Slack通知 | `Notification` フック | **なし**（Codexに該当イベントがない） |
| `watchdog.sh --abort` のブロック | `PreToolUse`が`exit 2`でハードブロック（ツール呼び出しは確実に拒否される） | **ソフトな打ち切り依頼のみ。**`PreToolUse`は`systemMessage`のみ対応で`continue`は読まれないため、ツール呼び出し自体は実行される。確実に止めるにはセッション（`codex exec`／`run-loop.sh`）を人間が中断する |
| 準備成果ディレクトリの共有（`## 共有ディレクトリ` 節） | 対応（`scripts/share-prepared-dirs.sh`） | **なし。** generator を Epic 専用 worktree 上で直接動かすためレーン worktree が存在せず、そもそも問題が発生しない |

## このプラグイン自体を開発する場合

`agents/*.md` と `codex-agents/*.toml` は**生成物**です。直接編集しないでください。

| ファイル | 内容 |
|---|---|
| `core/instructions.md` | ベンダー中立なハーネス共通ルール（ワークフロー・規約・可読性原則・安全ルール） |
| `core/roles/*.md` | ベンダー中立な役割定義（planner / generator / evaluator） |
| `adapters/claude/overlays/*.md` | Claude Code固有のfrontmatterと補足 → `agents/*.md` |
| `adapters/codex/overlays/*.toml` | Codex固有のTOMLキーと補足 → `codex-agents/*.toml` |

```bash
# core/ や overlays/ を編集したら両方を再生成する
bash adapters/claude/build.sh
bash adapters/codex/build.sh

# 生成物が正本と一致しているか検証する（差分があれば exit 1）
bash adapters/claude/build.sh --check
bash adapters/codex/build.sh --check
```

**`core/` を編集したら両方を再生成し、生成物をコミットに含めてください。**

### run スキルの分割（progressive disclosure）

`skills/run/SKILL.md` は run を回すあいだ**ずっとコンテキストに載り続ける**。ウェーブごとに
再解釈されるため、ここに置いた1行はウェーブ数だけ推論コストを払う。そこで本体には
「毎回通る手順」だけを置き、**その状況になったときだけ読むもの**を
`skills/run/references/` へ分けている。

| ファイル | 読むタイミング |
|---|---|
| `references/recovery.md` | レーン内ゲート・統合ゲート・マージが失敗したとき |
| `references/troubleshooting.md` | run がハングし、人間が打ち切り／再開を判断するとき |
| `references/progress-display.md` | バナー・レーン結果・PR 本文の集計を組み立てるとき |
| `references/sandbox.md` | Epic 本文の任意節の書き方、compose の要求仕様を確認するとき |
| `references/cleanup.md` | worktree の後片付け手順が要るとき |
| `references/review.md` | 一括レビューが `REQUEST_CHANGES` を返した／変更が50ファイルを超えたとき |

**新しい手順を足すときは、まず「毎ウェーブ通るか」を問うこと。** 通らないなら
`references/` に置き、本体からは1行のリンクで参照する。判断の根拠・背景・失敗事例の説明は
本体に書かない（本体に必要なのは結論だけである）。

テストは本体と `references/` を連結した平坦化ビュー（`tests/run-tests.sh` の
`RUN_SKILL_FLAT`）に対して「記述があるか」を検査する。**本体内の記述の順序**を問うテストだけが
`skills/run/SKILL.md` そのものを見る。

設計方針は [docs/dev-workflow-multi-vendor-guide.md](docs/dev-workflow-multi-vendor-guide.md) を参照してください。

## ライセンス

MIT
