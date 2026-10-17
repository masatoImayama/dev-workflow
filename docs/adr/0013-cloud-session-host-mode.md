# ADR 0013: クラウドマシン自体を Docker sandbox の代替隔離と認め、host モードを正式化する

## ステータス

承認済み（Epic #267 / Task #282）

## コンテキスト

Claude Desktop のクラウドマシン（`CLAUDE_CODE_REMOTE=true` の使い捨て Linux コンテナ）から
dev-workflow を実行したいが、ハーネスはローカルマシン（Windows + Docker Desktop + ユーザー
レベル設定）前提の箇所が複数あり、**クラウドではコマンドが存在せず、仮に載ってもサンドボックス
準備で停止する**（issue #266 の調査に続くクラウドセッションでの実測。issue #267 背景）。

実測で判明した制約は次のとおり。

| 実測項目 | 結果 |
|---|---|
| 環境判定 | `CLAUDE_CODE_REMOTE=true` / `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE=cloud_default` が設定済み。**確実に判定できる** |
| Docker | デーモンに接続不可 |
| 外部通信 | すべてプロキシ経由。**`api.github.com` は 403**。GitHub 操作は `mcp__github__*` 前提になる |
| git push | セッションに指定されたブランチ以外への push は想定されていない |
| 環境リセット | セッション単位（タスク単位ではない） |
| プラグイン同期 | `CLAUDE_CODE_SYNC_PLUGINS=1` は設定済みだが同期先フォルダが空。別経路が必要 |

このうち `api.github.com` の 403 が最も重い。`scripts/plan-waves.sh`（ウェーブ計画の中核）・
`scripts/watchdog.sh`・`scripts/feedback-ledger.sh` 等が `gh` を直叩きしており、
**MCP ツールはシェルスクリプトから呼べない**ため単純な置き換えが効かない。

## 決定

### 決定1: host モードを正式化する

**クラウドマシン自体を Docker sandbox の代替隔離と認める。** Docker sandbox の本来の目的は
「ホストOSを壊さない」ことであり、クラウドマシンは使い捨ての隔離コンテナそのものであるため、
その目的はコンテナを介さずに既に満たされている。従来 `scripts/resolve-sandbox.sh` が
`mode=none` としてエラー停止していた経路を、**`host` モード**として正式に受理するように
変えた（Task #269 / #270）。

`sandbox-exec.sh` 呼び出し側（`run` / generator）のインターフェースは一切変えない。
host モードでは `sh -c "$CMD"` を実行ディレクトリ（Epic 専用 worktree / レーン worktree）で
直接実行し、終了コードを透過する。generator/evaluator の分離は、Docker のコンテナ分離から
**worktree 分離**に代わる（既にレーンごとに isolation worktree を使っているため追加実装は
不要）。

### 決定2: host モードの有効化条件を「明示オプトイン、または `CLAUDE_CODE_REMOTE=true` かつ
Docker 接続不可」に限定した理由

有効化条件は次の2つの OR とした（どちらか一方で十分）。

1. 明示オプトイン: `DEV_WORKFLOW_SANDBOX_HOST=1`
2. `CLAUDE_CODE_REMOTE=true` かつ Docker デーモンに接続不可

**この限定は、ローカルで `Dockerfile.dev` を置き忘れたまま無防備に自律実行される事故を
原理的に防ぐためである。** `CLAUDE_CODE_REMOTE` はローカル環境には存在しない変数であるため
条件2が誤爆することは無く、サンドボックス定義の供給漏れを「隔離なしで実行を続ける」方向へ
機械的に倒してしまうことはない。同時に、**自前で Docker を立てたクラウド環境では
`dev_workflow_docker_available` が真になるため、条件2は成立せず従来どおり Docker 経路（既存の
解決順1〜5）に乗る。** host モードは「Docker が使えない」ことを検知した結果であり、
「クラウドだから無条件に」ではない。

### 決定3: GitHub アクセスを2バックエンドにした理由

クラウドでは `api.github.com` が 403（プロキシ制限）であり、GitHub 操作は `mcp__github__*`
前提になる。一方で**ローカルの既定経路は `gh`（GitHub CLI）であり、かつ `scripts/*.sh` の
シェルスクリプトから MCP ツールは呼べない。** この非対称性――「クラウドは MCP 必須」「
スクリプト層は MCP を呼べない」が同時に成立する――により、単純な「`gh` を MCP に置き換える」
では済まなくなった。

選択規則は `scripts/lib/detect-env.sh`（#268）の `dev_workflow_gh_available` の真偽1つに
一元化し（`core/references/github-access.md`。#274）、**2段構えで対応した。**

1. **スクリプト層**: `scripts/plan-waves.sh` の既存 `load_from_file`（`--from-file`）経路を
   使う。`run` が `gh` 不可時に MCP で Task issue 群を取得し、`--from-file` 用の入力ファイルへ
   書き出してから渡す（#277）。`--from-file` が無ければ黙って1レーンへ落とさず、理由を明示して
   停止する
2. **スキル本文側**: エージェントが直接 GitHub を操作する箇所（issue コメント・PR 作成等）は
   `mcp__github__*` を呼べるため、`dev_workflow_gh_available` が偽のときはスキル本文内で
   MCP に切り替える（#276）

この二段構えは「スクリプト層はファイル入力に倒す／スキル本文は MCP 直接呼び出しに倒す」という
形で、**MCP を呼べない層と呼べる層それぞれに適した手段を割り当てた結果**である。

## 却下した案

### 案A: クラウドコンテナ内で dind（Docker-in-Docker）を立てる

クラウドの実行環境自体がネストしたコンテナ上にあり、**デーモンへの接続自体が元から不可能**
（上記実測）。dind はホスト側のカーネル機能（cgroup 等）へのアクセスを前提とするため、
クラウドの提供元が意図的に塞いでいる制約を利用者側のセットアップで突破しようとする案であり、
実現性・保守性のいずれも低い。隔離の目的（ホストOSを壊さない）がクラウドマシンの使い捨て性で
既に満たされている（決定1）以上、dind を立てる追加コストを払う理由がない。

### 案B: `run` をローカル専用と割り切り、クラウド対応をしない

最小の変更で済むが、Claude Desktop のクラウドセッションから dev-workflow を使いたいという
元々の要求（issue #266）そのものを満たせない。`CLAUDE_CODE_REMOTE` による確実な判定が既に
可能であり（上記実測）、ローカルの既存挙動を変えずに分岐を追加できる見通しが立ったため、
対応しない案は採らなかった。

## 残っているリスク

- **`$HOME` 揮発による性能劣化。** クラウドの環境リセットはセッション単位であり、検証スタンプ
  （`DEV_WORKFLOW_STAMP_HOME`）やビルドキャッシュが毎セッション消える。host モードではそもそも
  スタンプを使わない（検証すべきコンテナ・イメージが無い）ため影響は限定的だが、ビルド・
  依存インストールのキャッシュが効かない分、毎回の所要時間は長くなる。**明示（`doctor.sh` の
  注記）までで、性能の作り込みはスコープ外とした**（D7）
- **セッション時間上限。** クラウドセッションのタイムアウトに対する `run` の再開性強化は
  行っていない。長時間の Epic はセッション内で完了しない可能性がある
- **Codex 版での `mcp__github__*` の可否が未検証。** Claude Code の `mcp__github__*` という
  命名規則自体が Claude Code 固有の MCP サーバー結線を前提にしており、Codex 側に同名・同機能の
  ツールが存在する保証がない。そのため Codex 版（`skills-codex/dev-workflow-run/SKILL.md`）は
  `gh` 必須のまま、フォールバックなしで明示停止する方針を採っている
  （`docs/dev-workflow-multi-vendor-guide.md` 3.3.6 節の「意図的な divergence」）。将来 Codex 側の
  MCP GitHub 連携が実測で確認できた時点で、Claude 版と同じフォールバック経路の追加を検討する

## 実装中に変えた決定（教訓）

本 Epic のレビュー（wave-review・delta-review）が、仕様書・計画書の時点では見えていなかった
2つの設計上の欠陥を検出した。後から同種の欠陥を繰り返さないために、ここに教訓として残す。

### 教訓1: 通知経路を差し替えるときは、経路ごとの閲覧者の範囲と永続性を区別しなければならない

仕様書 §8（進捗の Epic issue フォールバック）は、当初「Slack が使えないときは Epic issue
コメントへフォールバックする」とだけ定めていた。これは **Slack webhook（ユーザーが能動的に
設定する秘匿チャネル）と GitHub issue（リポジトリの共有・永続記録）を等価に扱う**設計であり、
欠陥だった。

レビュー（issue #285）がこれを指摘した。クラウド環境では Slack webhook がそもそも存在しない
ことが多く、このフォールバックは「稀な代替」ではなく**常用の既定経路**になる。結果として、
`stop` / `run-complete` 等のイベントに含めていた `last_assistant_message`（直近応答の末尾
最大800文字・無加工）が、ユーザーが明示的に選んでいない形で共有 issue のコメント履歴に
残ってしまう。修正は、Epic issue フォールバックの本文から `last_assistant_message` を除外し
（ステータス行＋`$ARG` 相当のみにする。`scripts/notify-slack.sh` の `FALLBACK_DETAIL`）、
Slack 経路（ユーザーが選んだ秘匿チャネル）の本文は従来どおり変えないことで解決した。

**教訓**: 通知経路の差し替え・フォールバック先の追加を設計するときは、「送信に失敗したから
別の経路に流す」という実装上の都合だけでなく、**差し替え先の閲覧者の範囲（誰が読めるか）と
永続性（どれだけ残るか）が元の経路と同じかどうか**を設計時点で検討しなければならない。
今回は元の経路（Slack webhook）の方が狭く・流動的で、差し替え先（GitHub issue）の方が
広く・永続的だったため、同じ内容を流すと情報露出になった。

### 教訓2: 「正本を作る」ことと「正本が使われる」ことは別の問題であり、前者だけでは再実装の
再発を防げない

`scripts/lib/detect-env.sh`（#268）は「同じ判定を各所で書くと片方だけ直して食い違う事故が
起きる」ことを明記し、判定ロジックの正本として新設された。しかし、**正本を作った直後の
タスク（#271）と、さらに後のタスク（#272）が、それぞれ独自に Docker/gh 判定を再実装した。**

- #271（`check-prerequisites.sh`）: `detect-env.sh` を source せず、`command -v docker` /
  `docker info` / `gh auth status` を独自に再実装した。結果、`DEV_WORKFLOW_DOCKER_UNAVAILABLE`
  等の上書き環境変数が効かず、`gh api rate_limit`（クラウドの 403 を実際に検知するための
  軽量疎通確認）も欠落していた。同一ウェーブのレビューで検出され、issue #283 として修正した
- #272（`skills/run/SKILL.md` の Docker 必須チェック）: 同じファイル内の別ブロック
  （`SINGLE_BRANCH_MODE` 判定・`gh` 可否判定）は `detect-env.sh` を正しく source していたにも
  関わらず、**直後に追加した Docker 必須チェックだけが同じ独自実装を繰り返した。** これは
  **#283 がまさに修正したアンチパターンと同じ形**であり、次のウェーブのレビューで issue #287
  として再度検出された

**2回とも、修正対象になった判定ロジック自体は（独自実装の範囲では）正しく動いていた。**
問題は「正本の存在を知っているはずの後続タスクが、それでも正本を source せずに独自実装を
選んだ」ことであり、正本を1箇所に置くという設計判断だけでは、実装者（レビューが無ければ
そのまま残っていた）がその正本を実際に使うことを保証できない。

**教訓**: 判定ロジック・ユーティリティの正本を新設するタスクは、それ自体では「今後の
再実装を防ぐ」ところまでは担保しない。正本の設計と、正本が使われているかどうかの検査
（例: 対象スクリプト・対象ブロックが `command -v docker` / `docker info` / `gh auth status`
を正本の関数経由ではなく直接呼んでいないかを静的に検査するテストを `tests/run-tests.sh` に
追加する）は、別の対策として分けて検討する必要がある。`docs/adr/0012-jev-system-one-decision-points.md`
の決定E（除外する判断点をテストで静的に固定した）と同じ発想——「規約をドキュメントに書くだけでは
実効性を保証できないので、機械的な検査で固定する」——がここにも当てはまる。

## 影響

### 変更したもの

- `scripts/resolve-sandbox.sh` — host モードの解決（既存解決順の最上位に追加。#269）
- `scripts/sandbox-exec.sh` — host 実行分岐（契約は変えない。#270）
- `scripts/check-prerequisites.sh` — Docker/gh 必須判定を非ブロッキング警告へ格下げ、
  `detect-env.sh` への委譲（#271、#283 で修正）
- `skills/run/SKILL.md` / `skills/goal/SKILL.md` — 冒頭の Docker 事前チェック、
  `detect-env.sh` への委譲（#272、#287 で修正）
- `scripts/doctor.sh` — クラウド診断・成立しない機能一覧（#273）
- `scripts/plan-waves.sh` / `scripts/watchdog.sh` / `scripts/feedback-ledger.sh` /
  `scripts/collect-feedback-signals.sh` — fail-soft 化とファイル入力経路（#275）
- `scripts/merge-lane.sh` — 単一ブランチ運用への縮退（#278）
- `scripts/notify-slack.sh` — Epic issue フォールバック、`last_assistant_message` の除外
  （#280、#285 で修正）
- `README.md` / `docs/dev-workflow-multi-vendor-guide.md` — クラウド対応の供給手順・
  差異表（#279、#281）
- `skills-codex/dev-workflow-run/SKILL.md` 他 Codex 版 — クラウド対応の反映（#281）

### 追加したもの

- `scripts/lib/detect-env.sh` — 環境判定の正本（#268）
- `core/references/github-access.md` — GitHub アクセス2バックエンドの選択規則と対応表（#274）

## 関連

- Epic #267（仕様書・計画書）
- issue #266（先行調査）
- issue #283 / #287（判定ロジックの再実装。教訓2）
- issue #285（Epic issue フォールバックの情報露出。教訓1）
- `docs/adr/0012-jev-system-one-decision-points.md`（決定Eの「テストで静的に固定する」発想が
  教訓2と同根）
