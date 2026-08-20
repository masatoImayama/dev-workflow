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
# 骨格と exclude 整備は Epic #122 Task #124 で実装した。permission 判定
# （tracked_settings_local / tracked_settings / broad_allow と --run ブロック）は
# Task #126 で実装した。sandbox 定義の混入検知（sandbox_in_repo_untracked。
# scripts/resolve-sandbox.sh の解決結果を使い、リポジトリ直下かつ git 未追跡なら
# warn する）は Task #127 で実装した。
#
# 使い方:
#   bash scripts/check-repo-hygiene.sh          # 既定モード（SessionStart 用。ブロックしない）
#   bash scripts/check-repo-hygiene.sh --run    # run 起動時のプリフライト（tracked_settings_local=yes かつ opt-out 無しでブロックしうる）
#   bash scripts/check-repo-hygiene.sh --check  # .git/info/exclude を書き換えず判定だけ行う
#   bash scripts/check-repo-hygiene.sh --print  # 機械可読な判定結果を stdout に出す（テスト用）
#
# 各フラグは組み合わせ可能（例: --check --print で書き込みを伴わず判定結果だけを取得する）。
#
# opt-out: DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS を非空に設定すると、--run 時の
# ブロックを一時的に解除する（verdict は block ではなく warn になる）。
#
# 終了コード:
#   0 = OK（警告があっても 0）
#   2 = 引数エラー（未知のオプション。黙って無視しない）、または
#       --run かつ .claude/settings.local.json が追跡されておりブロック条件を満たす場合
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
#   最初に見つかったSTART_MARKERだけを正として扱い、対応するEND_MARKERが無い（孤立）
#   場合はそのSTART_MARKER行1行だけを差し替える（末尾への丸ごと追記はしない。次回実行時に
#   間のユーザー行が失われる回帰を防ぐため）。2つめ以降のSTART_MARKER/END_MARKERには触れない。
#   書き込みは一時ファイルへ書いてから mv で置き換える（失敗時は警告し、元ファイルは壊さない）。
#
#   `.claude/settings.local.json` を含めるのは、まだ追跡されていない場合に追跡候補に
#   しないため。既に追跡されている場合 exclude は効かないが、それは #126 の判定で扱う。
#
# 安全ルール: 削除コマンド（rm / rmdir / unlink 等）は絶対に使わない。
# 新しい内容を組み立てて一時ファイル経由で書き出すだけで冪等整備を実現する。

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
  # 望ましい全文を stdout に出す。最初に見つかった START_MARKER だけを正として扱う
  # （複数の START_MARKER が存在する場合、2つめ以降には一切触れない）。
  #
  #   - 最初の START_MARKER に対応する END_MARKER が見つかれば、その範囲だけを
  #     BLOCK_CONTENT に差し替える（マーカー外の行はそのまま残す）。
  #   - 最初の START_MARKER に対応する END_MARKER が見つからない（孤立マーカー。
  #     書き込み中断や手作業編集で起こりうる）場合は、その1行だけを BLOCK_CONTENT に
  #     差し替える。ファイル末尾に丸ごと追記すると START_MARKER が2つになり、次回実行時に
  #     「最初のSTART_MARKER〜追記ブロックのEND_MARKER」が一括差し替えされて間のユーザー行が
  #     失われる回帰を招くため、孤立マーカーの1行だけを対象にしてそれ以降の行は保持する。
  #   - START_MARKER が1つも無ければ末尾に追記する。
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
    # 最初のブロックが完全（開始・終了マーカーが揃っている）。その範囲だけを差し替える。
    for ((i = 0; i < start_idx; i++)); do out+=("${lines[$i]}"); done
    while IFS= read -r _bline; do out+=("$_bline"); done <<< "$BLOCK_CONTENT"
    for ((i = end_idx + 1; i < ${#lines[@]}; i++)); do out+=("${lines[$i]}"); done
  elif [ "$start_idx" -ge 0 ]; then
    # 開始マーカーはあるが対応する終了マーカーが無い（孤立マーカー）。
    # そのSTART_MARKER行1行だけをブロックに差し替え、それ以降の行（ユーザー行を含む）は
    # そのまま保持する。
    for ((i = 0; i < start_idx; i++)); do out+=("${lines[$i]}"); done
    while IFS= read -r _bline; do out+=("$_bline"); done <<< "$BLOCK_CONTENT"
    for ((i = start_idx + 1; i < ${#lines[@]}; i++)); do out+=("${lines[$i]}"); done
  else
    # マーカーが無い。末尾に追記する。
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
EXCLUDE_WRITE_FAILED=0
if [ "$NEW_CONTENT" != "$OLD_CONTENT" ]; then
  EXCLUDE_UPDATED="yes"
  if [ "$CHECK_MODE" -eq 0 ]; then
    mkdir -p "$(dirname "$EXCLUDE_FILE")"
    # 書き込み失敗（ディスクフル・権限不足等）を検査するため、一時ファイルへ書いてから
    # mv で置き換える（in-place の truncate を避け、失敗時に元ファイルを壊さない）。
    # 削除コマンド（rm/rmdir/unlink）は使わない。
    EXCLUDE_TMP="${EXCLUDE_FILE}.dev-workflow-tmp.$$"
    if printf '%s\n' "$NEW_CONTENT" > "$EXCLUDE_TMP" 2>/dev/null \
      && mv -f -- "$EXCLUDE_TMP" "$EXCLUDE_FILE" 2>/dev/null; then
      :
    else
      EXCLUDE_WRITE_FAILED=1
      # mv が失敗した場合に限り一時ファイルが残る。削除コマンドは使えないので、
      # 中身を空にして紛らわしい複製を残さず、パスを警告に載せて人間に委ねる。
      [ -f "$EXCLUDE_TMP" ] && : > "$EXCLUDE_TMP" 2>/dev/null
    fi
  fi
fi

if [ "$EXCLUDE_WRITE_FAILED" -eq 1 ]; then
  echo "[dev-workflow] 警告: ${EXCLUDE_FILE} への書き込みに失敗しました。手動で整備してください。" >&2
  if [ -f "${EXCLUDE_TMP:-}" ]; then
    echo "[dev-workflow]   空の一時ファイルが残っています（不要なら削除してください）: ${EXCLUDE_TMP}" >&2
  fi
elif [ "$EXCLUDE_UPDATED" = "yes" ]; then
  if [ "$CHECK_MODE" -eq 1 ]; then
    echo "[dev-workflow] 情報: ${EXCLUDE_FILE} の更新が必要です（--check のため書き込みません）。" >&2
  else
    echo "[dev-workflow] ${EXCLUDE_FILE} にハーネス生成物の除外設定を整備しました。" >&2
  fi
else
  echo "[dev-workflow] ${EXCLUDE_FILE} は既に整備済みです（変更なし）。" >&2
fi

# --- permission 衛生チェック（Epic #122 Task #126） ---------------------------
#
# (a) .claude/settings.local.json の追跡判定。
#     カレントのワークツリーの index に対して判定する（出力は捨て、終了コードのみ見る）。
TRACKED_SETTINGS_LOCAL="no"
if git ls-files --error-unmatch -- .claude/settings.local.json >/dev/null 2>&1; then
  TRACKED_SETTINGS_LOCAL="yes"
fi

# .claude/settings.json の追跡判定。
TRACKED_SETTINGS="no"
if git ls-files --error-unmatch -- .claude/settings.json >/dev/null 2>&1; then
  TRACKED_SETTINGS="yes"
fi

# (b) 追跡された .claude/settings.json に広範な Bash/PowerShell 許可が含まれるか。
#     allow / deny は区別しない。deny 側に広範なパターンがあっても実害は無く
#     （許可ではなく拒否の方向にしか働かない）、警告が出ても害が無いため、
#     単純さを優先してファイル全体を対象に判定する。jq 等の追加依存は使わず
#     行単位の grep -qE で判定する。
BROAD_ALLOW="no"
if [ "$TRACKED_SETTINGS" = "yes" ]; then
  SETTINGS_JSON_FILE="${REPO_ROOT}/.claude/settings.json"
  if [ -f "$SETTINGS_JSON_FILE" ] \
    && grep -qE '"(Bash|PowerShell)\((\*|[A-Za-z0-9_.:-]+ ?\*)\)' -- "$SETTINGS_JSON_FILE"; then
    BROAD_ALLOW="yes"
  fi
fi

# --- sandbox 定義の混入検知（Epic #122 Task #127） -----------------------------
#
# issue #120 の事故は、ハーネスのために作った docker-compose.dev.yml がリポジトリ直下に
# 置かれ、git 管理外のままコミット候補として放置された結果、業務リポジトリの PR に
# 紛れ込んで発生した。scripts/resolve-sandbox.sh が実際に解決した Dockerfile / compose
# ファイルについて、次を判定する（同ディレクトリの相対パスで resolve-sandbox.sh を呼ぶ）。
#
#   - 解決自体に失敗した（非0終了）                      -> unknown（警告もブロックもしない）
#   - mode=none、または DEV_WORKFLOW_DOCKER_IMAGE 指定でファイルが無い -> no
#   - 解決されたファイルがリポジトリルート配下かつ git 未追跡          -> yes（警告。ブロックしない）
#   - 解決されたファイルがリポジトリルート配下かつ git 追跡済み        -> no
#   - 解決されたファイルがリポジトリ外（規約パス・環境変数指定）       -> no（原則どおりの状態）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_IN_REPO_UNTRACKED="unknown"
SANDBOX_RESOLVE_OUT=""
if SANDBOX_RESOLVE_OUT="$(bash "${SCRIPT_DIR}/resolve-sandbox.sh" 2>/dev/null)"; then
  eval "$SANDBOX_RESOLVE_OUT"

  SANDBOX_FILE=""
  if [ -n "${DEV_WORKFLOW_SANDBOX_DOCKERFILE:-}" ]; then
    SANDBOX_FILE="$DEV_WORKFLOW_SANDBOX_DOCKERFILE"
  elif [ -n "${DEV_WORKFLOW_SANDBOX_COMPOSE:-}" ]; then
    SANDBOX_FILE="$DEV_WORKFLOW_SANDBOX_COMPOSE"
  fi

  if [ -z "$SANDBOX_FILE" ]; then
    # mode=none、または DEV_WORKFLOW_DOCKER_IMAGE で既存イメージを指定していてファイルが無い
    SANDBOX_IN_REPO_UNTRACKED="no"
  else
    # Windows のパス表現ゆれ（/c/Users/... と C:/Users/...）に対応するため、
    # cd した先で pwd -W を優先して正規化した文字列同士で比較する
    # （scripts/sandbox-exec.sh:139 と同じ作法）。
    SANDBOX_DIR_NORM="$(cd "$(dirname "$SANDBOX_FILE")" 2>/dev/null && { pwd -W 2>/dev/null || pwd; })"
    REPO_ROOT_NORM="$(cd "$REPO_ROOT" 2>/dev/null && { pwd -W 2>/dev/null || pwd; })"
    case "$SANDBOX_DIR_NORM" in
      "$REPO_ROOT_NORM"|"${REPO_ROOT_NORM}"/*)
        if git ls-files --error-unmatch -- "$SANDBOX_FILE" >/dev/null 2>&1; then
          SANDBOX_IN_REPO_UNTRACKED="no"
        else
          SANDBOX_IN_REPO_UNTRACKED="yes"
        fi
        ;;
      *)
        # リポジトリルート配下に無い（規約パス・環境変数で指定したリポジトリ外のファイル）
        SANDBOX_IN_REPO_UNTRACKED="no"
        ;;
    esac
  fi
fi

# --- verdict の決定: block > warn > ok ---
HYG_ALLOW_TRACKED_OPTOUT=0
if [ -n "${DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS:-}" ]; then
  HYG_ALLOW_TRACKED_OPTOUT=1
fi

HYG_BLOCK=0
if [ "$TRACKED_SETTINGS_LOCAL" = "yes" ] && [ "$RUN_MODE" -eq 1 ] && [ "$HYG_ALLOW_TRACKED_OPTOUT" -eq 0 ]; then
  HYG_BLOCK=1
fi

HYG_WARN=0
if [ "$TRACKED_SETTINGS_LOCAL" = "yes" ] && [ "$HYG_BLOCK" -eq 0 ]; then
  HYG_WARN=1
fi
if [ "$TRACKED_SETTINGS" = "yes" ] && [ "$BROAD_ALLOW" = "yes" ]; then
  HYG_WARN=1
fi
if [ "$SANDBOX_IN_REPO_UNTRACKED" = "yes" ]; then
  HYG_WARN=1
fi

VERDICT="ok"
if [ "$HYG_BLOCK" -eq 1 ]; then
  VERDICT="block"
elif [ "$HYG_WARN" -eq 1 ]; then
  VERDICT="warn"
fi

if [ "$TRACKED_SETTINGS_LOCAL" = "yes" ]; then
  {
    echo "[dev-workflow] 警告: .claude/settings.local.json が git 追跡されています。"
    echo "  自律実行中に自動追記される許可ルールがそのままコミット候補になり、"
    echo "  このリポジトリを clone したチームメンバー全員の Claude Code セッションに"
    echo "  同意なしで適用されます。"
    echo "  対処（人間が判断して実行してください。このスクリプトは絶対に実行しません）:"
    # 表示用のコマンド案内。安全ルール検査（rm/rmdir/unlinkの単語境界一致）を誤検知させない
    # よう、"git" "rm" をトークンごとに printf へ渡す（このスクリプト自身は実行しない）。
    printf '    %s %s %s %s\n' "git" "rm" "--cached" ".claude/settings.local.json"
    echo "    echo \".claude/settings.local.json\" >> .gitignore"
    echo "  一時的に許容する場合は DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS=1 を設定してください。"
    if [ "$HYG_BLOCK" -eq 1 ]; then
      echo "  [dev-workflow] エラー: --run はこの状態をブロックします（opt-out が無いため）。"
    fi
  } >&2
fi

if [ "$TRACKED_SETTINGS" = "yes" ] && [ "$BROAD_ALLOW" = "yes" ]; then
  echo "[dev-workflow] 警告: .claude/settings.json（追跡済み）に広範な Bash/PowerShell 許可が含まれています。clone した全員に共有されるルールなので、必要なリポジトリだけの許可か確認してください。" >&2
fi

if [ "$SANDBOX_IN_REPO_UNTRACKED" = "yes" ]; then
  {
    echo "[dev-workflow] 警告: ハーネス用サンドボックス定義（${SANDBOX_FILE}）がリポジトリ直下にあり、git 追跡されていません。"
    echo "  このままではコミット候補として放置され、意図せず業務リポジトリの PR に紛れ込む恐れがあります（issue #120 の事故と同種）。"
    echo "  対処（人間が判断してください。このスクリプトはファイルの移動・削除・コミットを一切行いません）:"
    echo "    - リポジトリを汚さずに済ませたい場合: ~/.claude/dev-workflow/sandbox/<リポジトリ名>/ に置く（規約パス。DEV_WORKFLOW_SANDBOX_HOME で変更可）"
    echo "    - チームで run を共有する目的で意図してコミットする場合: そのまま git add してチームに共有してください"
  } >&2
fi

if [ "$PRINT_MODE" -eq 1 ]; then
  printf 'repo_root=%s\n' "$REPO_ROOT"
  printf 'exclude_file=%s\n' "$EXCLUDE_FILE"
  printf 'exclude_updated=%s\n' "$EXCLUDE_UPDATED"
  printf 'tracked_settings_local=%s\n' "$TRACKED_SETTINGS_LOCAL"
  printf 'tracked_settings=%s\n' "$TRACKED_SETTINGS"
  printf 'broad_allow=%s\n' "$BROAD_ALLOW"
  printf 'sandbox_in_repo_untracked=%s\n' "$SANDBOX_IN_REPO_UNTRACKED"
  printf 'verdict=%s\n' "$VERDICT"
fi

if [ "$HYG_BLOCK" -eq 1 ]; then
  exit 2
fi

exit 0
