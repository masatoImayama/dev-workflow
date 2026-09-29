---
name: setup
description: 環境診断・任意MCPの導入・サンドボックス定義の整備をまとめて案内する。新しいマシン・新しい駆動先リポジトリでの立ち上げに使う。
argument-hint: ""
---

## 目的

`/dev-workflow:run` を初めて使うマシン・駆動先リポジトリで、`scripts/doctor.sh`（#218）・
`scripts/install-optional-mcp.sh`（#219）・`scripts/sandbox-exec.sh --init`（#220）を
診断 → 案内 → （同意があれば）導入 → 再診断 の順にまとめて案内する。

**setup は run の前提ではない（Epic #217 決定D5）。** setup を一度も実行していない環境でも
`/dev-workflow:run` は従来どおり動く。setup はあくまで立ち上げを楽にする任意の支援コマンドで
あり、run が内部で setup を呼び出したり、setup の完了を待ったりすることは無い。

各スクリプトの判定ロジック・導入コマンドはここで**再実装しない**。呼び出すだけにする。
パッケージ名・導入手順の正本は引き続き `docs/optional-mcp-tools.md`（Epic #217 決定D3。
二重管理しない）。

## 手順

### 1. 現状を診断する

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

必須依存（gh / docker）・任意依存（context7 / code-review-graph）・サンドボックス定義・
リポジトリ衛生・CRLF設定をまとめて表示する。副作用は無い（何もインストールしない・
何も書き換えない）。

### 2. 必須依存（gh / docker）が不足している場合

**自動導入は行わない。** OSごとに手段と権限が分かれるため自動化の対象外（Epic #217 スコープ外）。
`scripts/doctor.sh` の出力にある案内（インストール先URL・`gh auth login` 等）をそのまま
ユーザーへ提示し、ここで停止する。不足が解消されるまで手順3以降へは進まない。

### 3. サンドボックス定義が無い場合（`mode=none`）

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --print-plan
```

`mode=none` であれば、規約パス（`~/.claude/dev-workflow/sandbox/<リポジトリ名>/`。駆動先
リポジトリは汚さない）に最小構成の雛形を生成できることを案内する。**書き込みを伴うため、
実行前に必ずユーザーの明示的な同意を確認する**:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --init
```

既存ファイルは上書きしない（冪等。Epic #217 決定D4）。雛形は最小構成であり、言語・
フレームワーク固有の依存はユーザー自身が追記する必要がある旨も伝える。

### 4. 任意MCP（context7 / code-review-graph）が未導入の場合

まず既定の dry-run で提示する（**何もインストールしない**。Epic #217 決定D2）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-optional-mcp.sh"
```

**利用者が明示的に選んだ場合に限り** `--apply` する。無断で導入しない:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-optional-mcp.sh" --apply
```

導入対象を絞りたい場合は `--only context7` または `--only code-review-graph` を追加する。
`install-optional-mcp.sh` は導入前に npm / Python 3.10+ 等の前提コマンドの有無を確認し、
無ければ前提不足を表示するだけで導入を試みない。ネットワーク不通時（前提コマンドは揃って
いる場合）は導入コマンドの失敗として検知し、クラッシュ・ハングせず `[NG]` と exit 2 で
終了する（Epic #217 決定D6。詳細・実装との対応関係の正本は `docs/optional-mcp-tools.md`
「導入コマンド化」節。#225）。

**「任意依存を入れない」という選択も正当な結末である。** context7 / code-review-graph が
未導入でも generator / evaluator は従来どおり動作する
（`docs/optional-mcp-tools.md`「任意依存であることの保証」参照）。ユーザーが導入しないと
決めた場合は、それ以上勧めずそのまま手順5へ進む。

### 5. 再診断する

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"
```

手順2〜4で行った変更の解消状況を表示して終える。

## 設計上の注意

- **`check-prerequisites.sh` を置き換えない。** hook としての必須依存ブロック（SessionStart時の
  gh/docker チェック）は従来どおり残る。setup はその上位にある「整える」導線であり、
  `scripts/doctor.sh` が内部で `check-prerequisites.sh` の判定ロジックを再利用している
  （二重実装しない）。
- **勝手に導入しない（D2）。** 既定は診断と提示であり、サンドボックス雛形の生成・任意MCPの
  導入はいずれも利用者の明示的な同意を経てから実行する。
- **run の前提にしない（D5）。** setup を実行していない環境でも `/dev-workflow:run` は
  従来どおり動く。
- 各スクリプトは冪等（D4）であり、setup を繰り返し実行しても副作用が積み上がらない
  （`--init` は既存ファイルを上書きしない、`install-optional-mcp.sh` は導入済みなら
  何もしない）。
