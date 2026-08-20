#!/bin/bash
# dev-workflow: 駆動先リポジトリのツリー衛生（repo hygiene）をチェック・整備する（ベンダー中立）
#
# dev-workflow はハーネス由来のファイル（`.claude/.dev-workflow-*` / `.claude/worktrees/` /
# `.claude/agent-tokens.tsv` / `.claude/slack-webhook` 等）を駆動先リポジトリのツリー内に
# 生成する。これまで README.md の「.gitignore に追加しておく」という人間の手作業に丸投げ
# されており、検証も自動化も無かった（issue #120）。
#
# `.gitignore` は駆動先チームの共有ファイルであり、ハーネスが勝手に書き換えるのは
# 「ハーネス都合のものを注入しない」という原則に反する。代わりに
# `.git/info/exclude`（コミットされずローカルに閉じる）に書く。
#
# 本スクリプトは新スクリプトの骨格と exclude 整備だけを実装する（Epic #122 Task #124）。
# permission 判定（tracked_settings* / broad_allow）は #126、sandbox 定義の混入検知
# （sandbox_in_repo_untracked）は #127 が追加するため、本タスクでは実装しない。
# --print の出力キーの領域だけを先に確保し、値は固定で返す。
#
# 使い方:
#   bash scripts/check-repo-hygiene.sh          # 既定モード（SessionStart 用。ブロックしない）
#   bash scripts/check-repo-hygiene.sh --run    # run 起動時のプリフライト（#126 でブロックしうる）
#   bash scripts/check-repo-hygiene.sh --check  # .git/info/exclude を書き換えず判定だけ行う
#   bash scripts/check-repo-hygiene.sh --print  # 機械可読な判定結果を stdout に出す（テスト用）
#
# 各フラグは組み合わせ可能（例: --check --print で書き込みを伴わず判定結果だけを取得する）。
#
# 終了コード:
#   0 = OK（警告があっても 0。本タスクの範囲では常にこの終了コードを返す）
#   2 = 引数エラー（未知のオプション。黙って無視しない）
#   （#126 が追加する「ブロック」用の終了コードは本タスクでは返さない）
#
# 人間向けメッセージはすべて stderr に出す（SessionStart フックの stdout を汚さないため。
# scripts/check-prerequisites.sh と同じ作法）。--print 指定時のみ、機械可読な
# key=value 出力を stdout に出す。
#
# git 管理下でなければ何もせず exit 0（メッセージのみ）。
#
# .git/info/exclude の冪等整備:
#   書き込み先は `<git-common-dir>/info/exclude`。
#   `git rev-parse --path-format=absolute --git-common-dir` で解決するため、
#   worktree から呼んでもメインリポの1箇所に集約される。
#
#   開始/終了マーカー行の間だけを対象に置換し、マーカー外の既存行は1行も変更しない。
#   既存ブロックの内容が期待値と完全一致していれば書き込まない（冪等。mtime も変えない）。
#   マーカーが無ければファイル末尾に追記する。ファイル/ディレクトリが無ければ作成する。
#
#   `.claude/settings.local.json` を含めるのは、まだ追跡されていない場合に追跡候補に
#   しないため。既に追跡されている場合 exclude は効かないが、それは #126 の判定で扱う。
#
# 安全ルール: 削除コマンド（rm / rmdir / unlink 等）は絶対に使わない。
# 新しい内容を組み立てて `>` で書き出すだけで冪等整備を実現する。

set -u

RUN_MODE=0
CHECK_MODE=0
PRINT_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --run)   RUN_MODE=1; shift ;;
    --check) CHECK_MODE=1; shift ;;
    --print) PRINT_MODE=1; shift ;;
    *) echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[dev-workflow] 情報: git リポジトリ内ではないため check-repo-hygiene.sh はスキップします。" >&2
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
GIT_COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
EXCLUDE_FILE="${GIT_COMMON_DIR}/info/exclude"

START_MARKER="# >>> dev-workflow: ハーネス生成物のローカル除外（自動生成。コミットされません） >>>"
END_MARKER="# <<< dev-workflow <<<"

# 書き込むブロック（この内容で完全固定。Epic #122 仕様書 4.3.1）
BLOCK_CONTENT="$(cat <<EOF
${START_MARKER}
/.claude/.dev-workflow-*
/.claude/worktrees/
/.claude/agent-tokens.tsv
/.claude/slack-webhook
/.claude/settings.local.json
${END_MARKER}
EOF
)"

build_desired_content() {
  # build_desired_content <既存の.git/info/excludeの内容>
  # 望ましい全文を stdout に出す。マーカー行が両方見つかれば、その行の範囲だけを
  # BLOCK_CONTENT に差し替える（マーカー外の行はそのまま残す）。マーカーが無ければ
  # 末尾に追記する。
  local existing="$1"
  local -a lines=()
  if [ -n "$existing" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
      lines+=("$_line")
    done <<< "$existing"
  fi

  local start_idx=-1 end_idx=-1 i
  for i in "${!lines[@]}"; do
    if [ "$start_idx" -eq -1 ] && [ "${lines[$i]}" = "$START_MARKER" ]; then
      start_idx="$i"
    elif [ "$start_idx" -ge 0 ] && [ "$end_idx" -eq -1 ] && [ "${lines[$i]}" = "$END_MARKER" ]; then
      end_idx="$i"
    fi
  done

  local -a out=()
  if [ "$start_idx" -ge 0 ] && [ "$end_idx" -ge "$start_idx" ]; then
    for ((i = 0; i < start_idx; i++)); do out+=("${lines[$i]}"); done
    while IFS= read -r _bline; do out+=("$_bline"); done <<< "$BLOCK_CONTENT"
    for ((i = end_idx + 1; i < ${#lines[@]}; i++)); do out+=("${lines[$i]}"); done
  else
    for ((i = 0; i < ${#lines[@]}; i++)); do out+=("${lines[$i]}"); done
    while IFS= read -r _bline; do out+=("$_bline"); done <<< "$BLOCK_CONTENT"
  fi

  printf '%s\n' "${out[@]}"
}

OLD_CONTENT=""
if [ -f "$EXCLUDE_FILE" ]; then
  OLD_CONTENT="$(cat -- "$EXCLUDE_FILE")"
fi

NEW_CONTENT="$(build_desired_content "$OLD_CONTENT")"

EXCLUDE_UPDATED="no"
if [ "$NEW_CONTENT" != "$OLD_CONTENT" ]; then
  EXCLUDE_UPDATED="yes"
  if [ "$CHECK_MODE" -eq 0 ]; then
    mkdir -p "$(dirname "$EXCLUDE_FILE")"
    printf '%s\n' "$NEW_CONTENT" > "$EXCLUDE_FILE"
  fi
fi

if [ "$EXCLUDE_UPDATED" = "yes" ]; then
  if [ "$CHECK_MODE" -eq 1 ]; then
    echo "[dev-workflow] 情報: ${EXCLUDE_FILE} の更新が必要です（--check のため書き込みません）。" >&2
  else
    echo "[dev-workflow] ${EXCLUDE_FILE} にハーネス生成物の除外設定を整備しました。" >&2
  fi
else
  echo "[dev-workflow] ${EXCLUDE_FILE} は既に整備済みです（変更なし）。" >&2
fi

if [ "$RUN_MODE" -eq 1 ]; then
  # run 起動時のプリフライト。permission 判定（#126）が実装されるまでは
  # ブロック判定を行わず、常に非ブロッキングのまま通す。
  :
fi

if [ "$PRINT_MODE" -eq 1 ]; then
  printf 'repo_root=%s\n' "$REPO_ROOT"
  printf 'exclude_file=%s\n' "$EXCLUDE_FILE"
  printf 'exclude_updated=%s\n' "$EXCLUDE_UPDATED"
  # 以下は #126 / #127 が実装するまでの予約領域（固定値）
  printf 'tracked_settings_local=no\n'
  printf 'tracked_settings=no\n'
  printf 'broad_allow=no\n'
  printf 'sandbox_in_repo_untracked=unknown\n'
  printf 'verdict=ok\n'
fi

exit 0
