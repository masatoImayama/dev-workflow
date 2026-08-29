# ハーネス非注入原則の詳細

`core/instructions.md`「ハーネス非注入原則」の本体には原則1文と検証コマンドだけを
残してある。ここには何がハーネス由来にあたるか・あるべき置き場所の対応表と背景を置く。
**新しくハーネス由来のファイルを増やすときにだけ読む。**

## ハーネス非注入原則

**dev-workflow ハーネス都合のファイル・設定を、駆動先の業務リポジトリに注入しない。**
サンドボックス定義に限らず、permission 設定・マーカー・状態ファイル・worktree 等、
ハーネスが動作のために必要とするものは、業務リポジトリのコミット履歴やPRに混入させない。

| ハーネス由来のもの | あるべき置き場所 |
|---|---|
| サンドボックス定義 | 規約パス `~/.claude/dev-workflow/sandbox/<repo>/` または環境変数。リポジトリ内に置くのは**チームで run を共有する場合に限る** |
| YOLO 用の permission 設定 | gitignore 済みの `.claude/settings.local.json`、またはユーザースコープ。**git 追跡された設定に広範な allow を積まない** |
| マーカー・状態ファイル・worktree | リポジトリ内に置くが、`.git/info/exclude`（コミットされない）で除外する。**`.gitignore` は駆動先の共有ファイルなので触らない** |

- 検証は `scripts/check-repo-hygiene.sh` が行う（SessionStart で exclude 整備、
  run 起動時に `--run` でプリフライト）
- **git 追跡された `.claude/settings.local.json` は run をブロックする**
  （`DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS=1` で opt-out）。追跡された permission 設定は、
  clone したチームメンバー全員のセッションに**同意なく適用される**ため、既定でブロックする
- 新しくハーネス由来のファイルを増やす場合は、必ずこの表のどれかに当てはめてから追加すること
