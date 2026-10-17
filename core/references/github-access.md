# GitHub アクセス: `gh` と MCP の2バックエンド（正本）

**いつ読むか**: スキル本文・スクリプトで GitHub 操作（issue / PR）が必要になったときに読む。
`core/instructions.md`「停止させるものと、記録して進めるもの」の分類をこの文書の判断に
適用する際にも参照する。

## 背景

クラウド（`CLAUDE_CODE_REMOTE=true` の使い捨て Linux コンテナ）では外部通信がすべて
プロキシ経由になり、**`api.github.com` が 403 を返す。** `gh` は原理的に通らず、
GitHub 操作は `mcp__github__*`（MCP バックエンド）前提になる。

一方で **MCP ツールはシェルスクリプトから呼べない。** `gh` と MCP という非対称な2つの
経路を各スキル・各スクリプトに個別に書くと、どこかで食い違う（片方だけ直して他方が
古い判定のまま残る）事故が起きる。そのため選択規則・対応表・スクリプト層の方針を
この文書1つに集約する。

## 2つのバックエンド

| バックエンド | 使える場所 | 使えない場所 |
|---|---|---|
| `gh`（GitHub CLI） | シェルスクリプト・エージェントの両方から呼べる | クラウドでは `api.github.com` 403 により原理的に使えないことが多い |
| MCP（`mcp__github__*`） | エージェントのツール呼び出しからのみ | **シェルスクリプトからは呼べない**（`scripts/*.sh` の制約） |

## 選択規則は1つだけ

`scripts/lib/detect-env.sh`（#268）の `dev_workflow_gh_available` が:

- **真** → `gh` を使う（ローカル既定の経路）
- **偽** → MCP（`mcp__github__*`）を使う

エージェント（スキル本文）はこの1つの規則だけに従い、各所に `CLAUDE_CODE_REMOTE` や
`api.github.com` 到達性の個別判定を書かない。スキル本文には「GitHub 操作はこの文書
（`core/references/github-access.md`）に従う」と参照するだけにする
（progressive disclosure 方針。実装は #276）。

## 操作の対応表

| 操作 | `gh` バックエンド | MCP バックエンド |
|---|---|---|
| issue 参照 | `gh issue view N --json body` | `mcp__github__*` の該当ツール（issue 取得） |
| issue コメント | `gh issue comment N --body` | `mcp__github__*` の該当ツール（issue コメント追加） |
| issue 作成・ラベル付け | `gh issue create --label` | `mcp__github__*` の該当ツール（issue 作成） |
| issue 一覧（ラベル検索） | `gh issue list --label` | `mcp__github__*` の該当ツール（issue 検索） |
| PR 作成 | `gh pr create` | `mcp__github__*` の該当ツール（PR 作成） |

MCP 側の具体的なツール名は、MCP サーバーの実装（接続した `github` MCP サーバーの
提供ツール）に依存するため、この表では固定しない。`dev_workflow_gh_available` が偽と
判定された時点で、エージェントは接続済みの `mcp__github__*` ツール一覧から該当する
ものを選ぶ。

## スクリプト層は「fail-soft＋ファイル入力」または「明示して退く」のどちらかにする

**MCP ツールはシェルスクリプトから呼べない。** `gh` が使えない環境でスクリプトが
GitHub へ到達する必要がある場合、取れる道は次の2つしかない。**黙って劣化させない。**

1. **GitHub へ行かずに済む経路を持つ** — 事前にエージェントが MCP で取得した内容を
   ファイルへ書き出し、スクリプトはそのファイルを読む（`--from-file` 系の入力経路）
2. **行けないことを明示して退く** — 理由を出力して停止する、または（安全に縮退できる
   任意機能に限り）理由を表示して exit 0 で抜ける

| スクリプト | `gh` 不可時の挙動 |
|---|---|
| `scripts/plan-waves.sh` | 既存の `load_from_file` 経路を使う。`--from-file` が無ければ**理由を明示して停止**する（黙って1レーンに落とさない）。入力はエージェントが MCP で取得して書き出す |
| `scripts/watchdog.sh` | 既に fail-soft（取得失敗時は既定値へ continue）。この挙動を仕様として明記し、クラウドでは想定時間が取れない旨を警告する |
| `scripts/feedback-ledger.sh` / `scripts/collect-feedback-signals.sh` | 台帳へのローカル記録は続け、**issue 還流だけをスキップ**して「未還流」として残す |
| Jev の shadow 評価スクリプト（任意機能。詳細は `docs/adr/0012-jev-system-one-decision-points.md`） | `gh issue list` 依存の検証は実行せず、理由を表示して exit 0（shadow 検証は任意機能のため安全に縮退できる） |

上記スクリプト本体の実装（fail-soft化・ファイル入力経路の追加）は本タスク（#274）の
スコープ外であり、別タスク（#275）で行う。この文書はその実装が従うべき方針を定めるだけである。

## `core/instructions.md`「停止させるものと、記録して進めるもの」との対応

上記の2つの道は、`core/instructions.md` の三分類にそのまま対応する。

| この文書での扱い | 三分類での位置づけ |
|---|---|
| 「GitHub へ行かずに済む経路を持つ」が成立し、かつ正常に完了した場合 | 通常の進行（三分類に該当しない） |
| 「GitHub へ行かずに済む経路を持つ」が無く、代替も無い場合 | **停止**（続行すると成果物が壊れる。例: `plan-waves.sh` の `--from-file` 無し） |
| issue 還流のスキップ・shadow 検証の未実行など、成果物の正しさを左右しない項目 | **記録して進む**（事実を issue・台帳・PR 本文に残し、そのまま次へ進む） |

**「記録して進む」に分類される項目を黙って省略してはならない。** 「行けないことを明示して
退く」の「明示して」は、この記録を省略しないことを指す。
