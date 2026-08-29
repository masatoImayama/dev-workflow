# ADR 0008: レーン専用 `node_modules` の named volume 化は据え置く（issue #104）

## ステータス

承認済み・据え置き（Epic #173 / Task #104）

## コンテキスト

issue #104 は、Windows + Docker Desktop のバインドマウント環境で `/dev-workflow:run` の
並列レーンを実行すると、レーン worktree ごとに `yarn install` がフル実行され1回20〜40分
かかる（並列時は I/O 輻輳でさらに悪化する）という問題を報告している。issue が挙げる改善案は
4つあり、このうち3つは本 Epic の前提タスクで既に扱われている。

| 改善案 | 状態（本タスク着手時点） |
|---|---|
| lockfileハッシュをキーにした `node_modules` 用 named volume | 未着手（本ADRの対象） |
| レーンworktreeをウェーブ跨ぎで再利用する | 不採用・据え置き（`docs/adr/0004-cross-wave-lane-reuse.md`） |
| 準備成果をコピー/ハードリンクで移送する公式ステップ | 実装済み（Task #139。ADR-0007） |
| 同一worktreeへのinstall多重実行のガード | 実装済み（Task #111。ロック兼完了マーカー） |

本タスクでは、まず残る2項目（named volume・多重実行ガード）の実際の到達点を確認し、
その上で named volume 化についてのみ設計判断を記録する。

## 確認できたこと・確認できなかったこと（推測で実装しないため）

**本タスクでも issue #104 / #139 の元の再現環境（Windows + Docker Desktop・compose モード・
実際の Node.js/yarn プロジェクト）そのものは用意できなかった。** そのため以下は、
このリポジトリ自身のコード（`scripts/sandbox-exec.sh` / `scripts/share-prepared-dirs.sh`）を
実際に読み、`--print-plan` を実際に実行して確認できた事実であり、Windows 実環境での効果は
未検証である。

### 確認できたこと

1. **`同一worktreeへのinstall多重実行のガード」は既に実装済みである。**
   `scripts/share-prepared-dirs.sh` の「ロック兼完了マーカー」（Task #111）が、レーンの
   `.git` 配下に `mkdir` でロックディレクトリを作り、`done` が無いまま2回目の呼び出しが
   来ると `exit 3` で停止する（`--force` 指定時のみ無視して続行）。さらに
   `core/roles/generator.md`（本レーンにも展開されているエージェント指示）に
   「exit 3（ロック競合）を受け取ったら、待ったり2本目を起動したりしない」という
   明文の禁止規定があり、issue #104 が報告した実際の事故（generator が待ちきれず
   同一worktreeに2本目の `yarn install` を並行実行しネイティブバイナリを破損させた）の
   再発防止が、機構（ロック）と規約（generator.md）の両方で二重に効いている。
   `tests/run-tests.sh` に既存の回帰テスト（`dev-workflow-prep.lock` 関連、ケース1〜7）がある。
   **本タスクでは、この項目に対する追加実装は行わない**（既に閉じているため）。

2. **`sandbox-exec.sh` の `cache_volume` は compose モードでは実際に一切マウントされない。**
   `cache_mount_args()`（キャッシュ volume の `-v` 引数を組み立てる関数）の呼び出し箇所は
   `dockerfile` モードの `docker run -d` 一箇所のみで、compose モードの `docker compose up -d`
   には一切渡っていない（`grep -n cache_mount_args scripts/sandbox-exec.sh` で確認）。
   これは issue #104 の「原因の構造 1」の主張と一致する。この事実自体は既に `README.md`
   （「既知の限界（キャッシュ volume）」節）に文書化済みだった。

3. **`--print-plan` はモードに関わらず `cache_volume=` 行を出力していた（バグ）。**
   実際に `DEV_WORKFLOW_DOCKER_COMPOSE_FILE` で compose ファイルを指定し `--print-plan` を
   実行したところ、`mode=compose` であっても `cache_volume=...` の行が複数出力されることを
   確認した。`--print-plan` は「実際に使われる設定を外部から観測できるようにする」ドライラン
   （スクリプト冒頭のコメント）であるにもかかわらず、確認できたこと2（compose モードでは
   キャッシュ volume が一切接続されない）と矛盾する行を出力しており、利用者が
   `--print-plan` の出力だけを見て「compose モードでもキャッシュが効いている」と誤解しうる
   状態だった。**本タスクでこれを修正した**（後述「決定」参照）。

4. **レーン worktree ごとに個別のコンテナ/named volume を割り当てることは、現行の
   コンテナライフサイクルモデルと構造的に衝突する。** `sandbox-exec.sh` はマウント元を
   worktree ではなく**リポジトリルート**（`HOST_ROOT`）に固定し、コンテナ名も
   `PROJECT`（リポジトリ basename）と `EPIC` からのみ決まる（worktree の basename には
   依存しない）。これは「generator の isolation worktree が何個増えてもコンテナは増えない」
   ことを明示的な設計目標としたコメントとして残っている。コンテナは Epic 単位で1個だけ
   常駐し、全レーンが同じコンテナに `docker exec` で入る。レーン worktree
   （`.claude/worktrees/agent-<id>`）はこの共有コンテナが起動した**後に**動的に作られるため、
   レーンごとに異なる `node_modules` パスを named volume として `-v` でマウントするには、
   レーンが増えるたびに**コンテナを作り直す**（`-v` は起動時にしか追加できない）必要があり、
   「コンテナ=epic」というこのリポジトリの分離単位そのものを壊す。この点は
   `docs/adr/0002-sandbox-overhead-reduction.md` 決定2で「レーンごとの別 volume / 別コンテナ」
   が明示的に**却下**されている判断とも一致する（Epic #173 本文が「事前に判明している事実」
   として引用している内容と同じ）。

### 確認できなかったこと

- issue #104 の実環境（Windows + Docker Desktop・compose モード・実際の Node.js/yarn
  プロジェクト）で、名前付き volume に `node_modules` を展開した場合の実際の install
  時間短縮効果
- `docker cp` を使ってレーンの外側（named volume 上）に構築した `node_modules` を、
  レーンのバインドマウント側へ転送する代替案（ADR-0007 でも「評価コストがスコープを
  超える」として評価を打ち切っている）の実効性。理論上は「コンテナ=epic」の分離単位を
  壊さずに済む可能性があるが、`docker cp` は単一ファイル/ディレクトリの逐次コピーであり、
  `node_modules` のような大量の小さいファイルを含むディレクトリに対して実際に
  Windows バインドマウント上のリンク/展開コストより速いかどうかは未検証

## 決定

### A. `--print-plan` の `cache_volume` 出力を dockerfile モード限定にする（実装した）

確認できたこと3の不整合を修正する。`print_plan()` 内の `cache_volume=` 出力を
`DEV_WORKFLOW_SANDBOX_MODE=dockerfile` のときだけ行うようにした。`--reset-cache` 等の
後片付け系コマンドは、モードに関わらず同じ volume 名を対象に `docker volume rm` を試みる
既存挙動のまま変更しない（存在しない volume への削除操作は idempotent に失敗するだけで、
`--print-plan` のような「これから使われる設定の表示」とは性質が異なるため、混同しない）。

この変更は **dockerfile モードの既存出力を一切変えない**（対象は compose/none モードの
出力からの行削除のみ）ため、`tests/run-tests.sh` の既存の cache_volume 関連アサーション
（いずれも dockerfile モードの一時リポジトリに対して行われている）に影響しない。

### B. レーンごとの named volume 化は実装しない（現行アーキテクチャのまま据え置く）

確認できたこと4の理由により、`node_modules` をレーンパスごとに named volume 化する案は
**現行の「コンテナ=epic」共有コンテナモデルと構造的に両立しない。** 両立させるには
レーンごとにコンテナを作り直す（またはレーン専用コンテナに切り替える）という、
`docs/adr/0002` 決定2で既に却下されているアーキテクチャ変更が必要になる。本タスクの
スコープでこの却下済みの決定を覆すだけの新しい確認済み事実（Windows 実環境での実測等）は
得られていないため、覆さない。

`node_modules` をレーンへ届ける実質的な役割は、既に Task #139（symlink→コピーの
段階的フォールバック）と Task #111（多重実行ガード）が担っている。symlink またはコピーが
成功すれば、そもそも `yarn install` 自体が実行されない（`prep=skip` となり `--run-prep` は
呼ばれない）ため、named volume の有無に関わらず issue #104 の本体（レーンごとのフル
install）は回避できる可能性が高い。**この経路が実環境で実際に機能するかどうかは
ADR-0007 の時点で未検証のまま残っており、本タスクでも検証できていない。**

## 理由

- 「確認できた事実だけを根拠に実装する」という Epic #173 の必須要件に従い、確認できなかった
  Windows 実環境での効果を前提にした実装（named volume の新規導入）はしない
- 一方で「`--print-plan` の出力が実際の挙動と矛盾している」ことは、このリポジトリ自身の
  コードを読むだけで確認・修正できる領域であり、実際に確認できた不整合を放置しない
- 「レーンごとの別 volume/別コンテナ」は既に `docs/adr/0002` で却下された決定であり、
  これを覆すには本タスクのスコープを超える実地検証（Windows 実環境での比較実測）が必要。
  中途半端な検証で決定を覆すと、後から実効果が無いと判明した場合に「コンテナ=epic」の
  分離単位という既存の重要な設計判断を無根拠に破棄したことになるため、確認できるまで
  現状維持する方が安全側である

## トレードオフ

- **issue #104 の本体（Windows 実環境での install 時間短縮）は、本タスク単独では実測で
  検証されない。** Epic #173 の完了基準5が明示するとおり、実効果の検証は次回の Windows
  駆動先での run 実測に委ねる
- **named volume 化を求める要望自体は解消されていない。** 将来、Windows 実環境での実測に
  基づき「symlink/コピー共有だけでは install 時間が十分短縮されない」と判明した場合は、
  本ADRを更新するか、レーン専用コンテナモデルへの移行を扱う新しいADRを起こす必要がある
- **`--print-plan` の出力変更は、外部ツール等が compose モードでも `cache_volume` 行の
  存在を前提に解析していた場合に影響しうる。** ただし `cache_volume` はもともと compose
  モードでは意味を持たない値（接続されないため）であり、これに依存した外部処理があれば
  それ自体が誤った前提に基づいている

## 却下した代案

### `docker cp` によるレーン外部（named volume）からレーン内への転送

理論上は「コンテナ=epic」の分離単位を壊さずに済む可能性があるが、`node_modules` の
大量の小ファイルに対する `docker cp` のコピー効率が Windows バインドマウント上の
リンク/展開コストと比べて実際に優位かどうかを検証する手段が本タスクのスコープでは
用意できず、ADR-0007 の時点で既に「評価コストに対してスコープを超える」と判断されている
経緯を踏襲し、引き続き評価を見送った。将来 Windows 実環境での実測ができる段階になれば
再検討する。

### レーン専用コンテナへの切り替え（`docs/adr/0002` 決定2の再検討）

`docs/adr/0002` が却下した「レーンごとの別 volume/別コンテナ」を、本 issue のために
限定的に復活させる案も検討したが、却下理由（コンテナ数がレーン数に比例して増える運用
コスト）は本タスクで新たに反証できておらず、確認できない前提で既存の確定判断を覆す
ことはしない。
