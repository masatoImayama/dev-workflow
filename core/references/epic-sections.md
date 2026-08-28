# Epic 本文の任意節（詳細）

`core/instructions.md`「サンドボックス方針」の本体には、Epic 本文に3つの任意節が
あることと、書くかどうかを判断するのは planner であることだけを残してある。
ここには各節の背景・書き方・run/generator 側の扱いの詳細を置く。
**Epic issue 本文にこれらの節を書くか判断するとき（planner）、run/generator がこれらの
節の扱いで迷ったときにだけ読む。**

### プロジェクト固有の準備コマンド

生成物の配置（wasm 等）・依存物のダウンロード・コード生成など、**タスクに依らず同じ結果になる
準備作業**は、run が Epic 開始時に1回だけ実行する。コンテナは Epic 単位で常駐する
（`sandbox-exec.sh` の既存挙動）ため、この1回はキャッシュを温め、統合ゲート用のコンテナに
配置する目的で行う。**適用範囲は run が実行する Epic 専用 worktree に限られ、各レーンの
isolation worktree には及ばない。**

- Epic issue 本文に `## 準備コマンド` 節があれば、run がその内容を Epic 開始時の
  `--warm`（`sandbox-exec.sh`）に1回だけ渡す
- 節が無い場合は現行どおり、ビルドコマンドで `--warm` するだけになる（後方互換）
- `--warm` は失敗してもループを止めない（`sandbox-exec.sh` の既存挙動）。準備が失敗した場合は
  その旨を表示するだけで続行する
- run から準備コマンドが渡された場合、generator は**自分の作業ディレクトリ（isolation
  worktree）で初回1回だけ実行**し、**同一 worktree 内で2回目以降は実行しない**。
  準備が効いていないと判断した場合も、自前で再実行はせずその事実を報告する
  （`core/roles/generator.md`）
- 節を書くかどうかの判断は planner が行う（`core/roles/planner.md`）

### Epic 本文の `## 共有ディレクトリ` 節

レーンごとに準備コマンドをフル実行すると、`node_modules` / `vendor` 等の大量のファイルを
含むディレクトリ生成が支配的なコストになる（issue #104）。Epic 本文の `## 共有ディレクトリ`
節は、Epic 専用 worktree の準備成果ディレクトリをレーンへ symlink で共有するための宣言である。

- 節があれば run が Epic 開始時にその内容を読み、Step 3 の各 generator プロンプトへ渡す
- 節が無ければ何もしない（共有せず、現行どおり各レーンで準備コマンドをフル実行する）
- 節を書くかどうかの判断は planner が行う（`core/roles/planner.md`）

### Epic 本文の `## SKIPパターン` 節

`scripts/count-skips.sh` は go / jest / pytest の3形式しか built-in で判定できない。
駆動先プロジェクトのテスト出力がこの3形式のいずれとも異なる場合、Epic issue 本文に
`## SKIPパターン` 節（SKIP行に一致するERE1行）が無いと `count-skips.sh` は既定で
`skips=unknown` になり、SKIP件数の検証が働かないまま run が進んでしまう。

- 節があれば run がその内容を `DEV_WORKFLOW_SKIP_PATTERN` として読み取り、Step 3 の各
  generator プロンプトと統合ゲートの両方に渡す（`## 準備コマンド` 節と同じ抽出方法）
- 節が無ければ何も設定されず、built-in ランナー（go/jest/pytest）の判定だけが行われる
- 節を書くかどうかの判断は `## 準備コマンド` 節と同様に planner が行う（`core/roles/planner.md`）
