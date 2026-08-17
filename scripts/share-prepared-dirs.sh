#!/bin/bash
# dev-workflow: 準備成果ディレクトリ（node_modules 等）をレーンへ symlink で共有する（ベンダー中立）
#
# `/dev-workflow:run` の並列レーンでは、generator の isolation worktree がタスクごとに新規作成
# される（作るのはハーネスであり、dev-workflow 側から再利用させる手段は無い）。そのため node 系
# プロジェクトではレーンごとに `yarn install` がフル実行され、Windows + Docker Desktop の
# バインドマウント上では1回20〜40分かかる（issue #104。実測で run 総所要 5.5h の半分以上）。
#
# Epic 専用 worktree には準備コマンドが1回だけ実行されており、その成果（`node_modules` 等）は
# 既に存在する。これをレーンへ symlink で共有すればレーンでの install は不要になる。
# 判定を散文で generator に委ねると取りこぼすため、本スクリプトに固定する。
#
# 本スクリプトは共有モード（既定モード）のみを実装する。`--detach`（#110）と
# ロック・`--run-prep`（#111）は後続タスクで追加する。
#
# 使い方（レーンの作業ディレクトリをカレントディレクトリとして呼び出す前提）:
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> \
#       --spec "$(cat <<'SPEC'
#   node_modules  yarn.lock package.json
#   SPEC
#       )"
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> \
#       --dir "node_modules yarn.lock package.json" --dir ".venv requirements.txt"
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> --epic epic105 --dry-run ...
#
# オプション:
#   --source <path>  共有元（Epic 専用 worktree）のパス。必須
#   --spec <text>    共有対象の指定。複数行可（1行1エントリ）。複数回指定すると連結される
#   --dir <text>     --spec の1行分を追加する（繰り返し可）
#   --epic <識別子>  sandbox-exec.sh に渡す --epic（例 epic105）。省略可
#   --dry-run        symlink を実際には作らず判定結果だけを出す
#
# エントリの行書式（空白区切り、すべてリポジトリルート相対。空行と # 始まりの行は無視する）:
#   <共有するディレクトリ> [<フィンガープリントファイル> ...]
#   例: node_modules  yarn.lock package.json
#
# 出力（1行1件・タブ区切り・機械可読。最後に必ず prep= 行を1行出す）:
#   linked	<dir>	<symlinkのターゲット（レーンからの相対パス）>
#   skip	<dir>	reason	<no-source|exists|fingerprint-mismatch|link-failed>
#   prep=<skip|run>
#
# 全エントリが linked または exists なら prep=skip、1つでもそれ以外があれば prep=run。
# --dry-run でも linked 行を出すが実際には作らない
# （scripts/cleanup-lane-worktrees.sh の removed 行が「削除予定」を表す既存慣習に合わせる）。
#
# エントリごとの判定順序:
#   1. <source>/<dir> が存在しない（ディレクトリでない）      -> no-source
#   2. レーン側 <dir> が既に存在する（symlink・実体を問わない） -> exists
#   3. フィンガープリントファイルの欠損・不一致が1つでもある   -> fingerprint-mismatch
#   4. symlink を作る。成功なら linked、失敗なら              -> link-failed
#
# フィンガープリントの比較は素のファイル読み取りだけで済むためホスト側で行う
# （フィンガープリント未指定のエントリは検査しない）。
#
# symlink の作成と存在判定はコンテナ内で行う（重要）。ホストが Windows（Git Bash）の場合、
# `ln -s` が実体コピーになる・`test -L` が誤判定する等でホスト側からは扱えないためである。
# コンテナへの投入は scripts/sandbox-exec.sh 経由で行い、環境変数 DEV_WORKFLOW_SANDBOX_EXEC
# （既定: 本スクリプトと同じディレクトリの sandbox-exec.sh）で差し替えられるようにする。
# 単体テストはこの差し替えでスタブを刺し、Docker に依存せず検証する
# （tests/run-tests.sh は Docker を一切呼ばない方針）。
# コンテナへの投入は1回にまとめる（エントリごとに docker exec を往復させない）。
#
# symlink のターゲットは、レーン worktree から共有元への相対パスで張る。絶対パスにすると
# ホストとコンテナでパスが異なり解決できない。相対パスが計算できない場合（共有元がリポジトリ
# ルート外。実装上はカレントディレクトリと共有元が同じドライブ/ルートを共有しない場合）は
# link-failed として扱う。
#
# 終了コード:
#   0 = 正常終了（共有の成否は prep= 行で判断する）
#   2 = 引数エラー（--source 欠落、値なしのオプション、未知のオプション等）
#
# 安全ルール:
#   - 削除コマンド（rm / rmdir）を使わない
#   - 追加の依存物（jq 等）を要求しない。素の bash / git / grep / sed のみで完結させる

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_EXEC="${DEV_WORKFLOW_SANDBOX_EXEC:-${SCRIPT_DIR}/sandbox-exec.sh}"

SOURCE=""
EPIC=""
DRY_RUN=0
RAW_LINES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      if [ $# -lt 2 ]; then
        echo "ERROR: --source には値が必要です" >&2
        exit 2
      fi
      SOURCE="$2"; shift 2 ;;
    --spec)
      if [ $# -lt 2 ]; then
        echo "ERROR: --spec には値が必要です" >&2
        exit 2
      fi
      while IFS= read -r _spec_line; do
        RAW_LINES+=("$_spec_line")
      done <<< "$2"
      shift 2 ;;
    --dir)
      if [ $# -lt 2 ]; then
        echo "ERROR: --dir には値が必要です" >&2
        exit 2
      fi
      RAW_LINES+=("$2"); shift 2 ;;
    --epic)
      if [ $# -lt 2 ]; then
        echo "ERROR: --epic には値が必要です" >&2
        exit 2
      fi
      EPIC="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
    *)  echo "ERROR: 未知の引数: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SOURCE" ]; then
  echo "ERROR: --source は必須です" >&2
  exit 2
fi

CWD="$(pwd)"

# ---------------------------------------------------------------------------
# エントリの解析（--spec / --dir から集めた RAW_LINES を分解する）。
# 空行・# 始まりの行は無視する。read -ra は先頭・末尾の空白を自然に落とすため、
# 個別に trim する必要が無い。
# ---------------------------------------------------------------------------

ENTRY_DIRS=()
ENTRY_FILES=()

for _raw in "${RAW_LINES[@]:-}"; do
  [ -z "${_raw+x}" ] && continue
  _raw="${_raw%$'\r'}"
  read -ra _fields <<< "$_raw"
  [ "${#_fields[@]}" -eq 0 ] && continue
  case "${_fields[0]}" in
    "#"*) continue ;;
  esac
  ENTRY_DIRS+=("${_fields[0]}")
  ENTRY_FILES+=("${_fields[*]:1}")
done

# ---------------------------------------------------------------------------
# 共有元からレーン（カレントディレクトリ）への相対パスを計算する（純粋な文字列処理。
# cd で正規化するため、両ディレクトリが実在すれば十分で、対象の <dir> 自体の存在は問わない）。
# ---------------------------------------------------------------------------

compute_rel_path() {
  # compute_rel_path <from_dir> <to_dir>  <from_dir> から <to_dir> への相対パスを出力する
  local from="$1" to="$2"
  local from_abs to_abs
  from_abs="$(cd "$from" 2>/dev/null && pwd)" || return 1
  to_abs="$(cd "$to" 2>/dev/null && pwd)" || return 1
  [ -n "$from_abs" ] && [ -n "$to_abs" ] || return 1

  local IFS=/
  local -a fparts=() tparts=()
  local p
  # shellcheck disable=SC2086  # IFS=/ による意図的な単語分割
  for p in $from_abs; do [ -n "$p" ] && fparts+=("$p"); done
  for p in $to_abs; do [ -n "$p" ] && tparts+=("$p"); done

  # 先頭要素（ドライブレター等のルート）が異なる場合は同一ファイルシステム上に無いとみなす
  if [ "${#fparts[@]}" -gt 0 ] && [ "${#tparts[@]}" -gt 0 ] \
    && [ "${fparts[0]}" != "${tparts[0]}" ]; then
    return 1
  fi

  local i=0
  while [ "$i" -lt "${#fparts[@]}" ] && [ "$i" -lt "${#tparts[@]}" ] \
    && [ "${fparts[$i]}" = "${tparts[$i]}" ]; do
    i=$((i + 1))
  done

  local up=$(( ${#fparts[@]} - i ))
  local rel="" j
  for ((j = 0; j < up; j++)); do rel="${rel}../"; done
  for ((j = i; j < ${#tparts[@]}; j++)); do rel="${rel}${tparts[$j]}/"; done
  rel="${rel%/}"
  [ -z "$rel" ] && rel="."
  printf '%s' "$rel"
}

REL_SOURCE=""
REL_SOURCE_OK=0
if [ -d "$SOURCE" ]; then
  if REL_SOURCE="$(compute_rel_path "$CWD" "$SOURCE")"; then
    REL_SOURCE_OK=1
  fi
fi

# ---------------------------------------------------------------------------
# エントリごとの判定（1: no-source, 3: fingerprint はここでホスト側で決める。
# 2: exists, 4: link/link-failed はコンテナ側で決める）。
# ---------------------------------------------------------------------------

RESULT_KIND=()    # linked|exists|no-source|fingerprint-mismatch|link-failed（ENTRY_DIRSと同じ添字）
RESULT_TARGET=()  # linked のときだけ意味を持つ

CANDIDATE_ORIG_IDX=()
CANDIDATE_DIR=()
CANDIDATE_TARGET=()
CANDIDATE_FPOK=()

for idx in "${!ENTRY_DIRS[@]}"; do
  dir="${ENTRY_DIRS[$idx]}"
  files="${ENTRY_FILES[$idx]}"

  if [ ! -d "${SOURCE}/${dir}" ]; then
    RESULT_KIND[idx]="no-source"
    RESULT_TARGET[idx]=""
    continue
  fi

  # フィンガープリント比較（ホスト側。素のファイル読み取りだけで済む）。
  fp_ok=1
  if [ -n "$files" ]; then
    # shellcheck disable=SC2086  # files は空白区切りの複数ファイル名。意図的な単語分割
    for f in $files; do
      if [ ! -f "${SOURCE}/${f}" ] || [ ! -f "$f" ]; then
        fp_ok=0; break
      fi
      if ! cmp -s "${SOURCE}/${f}" "$f"; then
        fp_ok=0; break
      fi
    done
  fi

  if [ "$REL_SOURCE_OK" -eq 1 ]; then
    target="${REL_SOURCE}/${dir}"
  else
    target=""
  fi

  CANDIDATE_ORIG_IDX+=("$idx")
  CANDIDATE_DIR+=("$dir")
  CANDIDATE_TARGET+=("$target")
  CANDIDATE_FPOK+=("$fp_ok")
done

# ---------------------------------------------------------------------------
# コンテナへの投入（1回にまとめる）。exists 判定と symlink 作成（または --dry-run 時は
# 判定のみ）を、候補エントリ全件分のミニスクリプトとして1回の sandbox-exec.sh 呼び出しに
# まとめる。
# ---------------------------------------------------------------------------

if [ "${#CANDIDATE_DIR[@]}" -gt 0 ]; then
  CONTAINER_SCRIPT="set -u"$'\n'
  # shellcheck disable=SC2016  # 単一引用符は意図的。$d/$t はここでは展開せず、
  # コンテナ側で実行されるミニスクリプトの文字列としてそのまま埋め込む。
  for i in "${!CANDIDATE_DIR[@]}"; do
    d="${CANDIDATE_DIR[$i]}"
    t="${CANDIDATE_TARGET[$i]}"
    fpok="${CANDIDATE_FPOK[$i]}"
    CONTAINER_SCRIPT+="d=$(printf '%q' "$d")"$'\n'
    CONTAINER_SCRIPT+="t=$(printf '%q' "$t")"$'\n'
    CONTAINER_SCRIPT+='if [ -e "$d" ] || [ -L "$d" ]; then'$'\n'
    CONTAINER_SCRIPT+='  printf "exists\t%s\n" "$d"'$'\n'
    CONTAINER_SCRIPT+="elif [ ${fpok} -ne 1 ]; then"$'\n'
    CONTAINER_SCRIPT+='  printf "fpmismatch\t%s\n" "$d"'$'\n'
    CONTAINER_SCRIPT+='elif [ -z "$t" ]; then'$'\n'
    CONTAINER_SCRIPT+='  printf "linkfailed\t%s\n" "$d"'$'\n'
    CONTAINER_SCRIPT+='else'$'\n'
    if [ "$DRY_RUN" -eq 1 ]; then
      CONTAINER_SCRIPT+='  printf "linked\t%s\t%s\n" "$d" "$t"'$'\n'
    else
      CONTAINER_SCRIPT+='  if ln -s "$t" "$d" 2>/dev/null; then'$'\n'
      CONTAINER_SCRIPT+='    printf "linked\t%s\t%s\n" "$d" "$t"'$'\n'
      CONTAINER_SCRIPT+='  else'$'\n'
      CONTAINER_SCRIPT+='    printf "linkfailed\t%s\n" "$d"'$'\n'
      CONTAINER_SCRIPT+='  fi'$'\n'
    fi
    CONTAINER_SCRIPT+='fi'$'\n'
  done

  SANDBOX_ARGS=()
  [ -n "$EPIC" ] && SANDBOX_ARGS+=(--epic "$EPIC")

  CONTAINER_OUTPUT="$(bash "$SANDBOX_EXEC" "${SANDBOX_ARGS[@]}" "$CONTAINER_SCRIPT")"

  cand_i=0
  # 2カラム目（dir名）はCANDIDATE_ORIG_IDX側で既知のため使わない。read の3カラム形式
  # （kind\tdir\ttarget）に合わせるためだけに受け取る。
  # shellcheck disable=SC2034
  while IFS=$'\t' read -r kind _dir b; do
    [ -z "$kind" ] && continue
    [ "$cand_i" -lt "${#CANDIDATE_ORIG_IDX[@]}" ] || break
    orig_idx="${CANDIDATE_ORIG_IDX[$cand_i]}"
    case "$kind" in
      exists)     RESULT_KIND[orig_idx]="exists" ;;
      fpmismatch) RESULT_KIND[orig_idx]="fingerprint-mismatch" ;;
      linkfailed) RESULT_KIND[orig_idx]="link-failed" ;;
      linked)     RESULT_KIND[orig_idx]="linked"; RESULT_TARGET[orig_idx]="$b" ;;
      *)          RESULT_KIND[orig_idx]="link-failed" ;;
    esac
    cand_i=$((cand_i + 1))
  done <<< "$CONTAINER_OUTPUT"

  # コンテナ呼び出しが失敗して出力が想定件数に満たない場合、未確定分は安全側
  # （link-failed）で確定させる。
  while [ "$cand_i" -lt "${#CANDIDATE_ORIG_IDX[@]}" ]; do
    orig_idx="${CANDIDATE_ORIG_IDX[$cand_i]}"
    RESULT_KIND[orig_idx]="link-failed"
    cand_i=$((cand_i + 1))
  done
fi

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------

PREP="skip"
for idx in "${!ENTRY_DIRS[@]}"; do
  kind="${RESULT_KIND[$idx]:-link-failed}"
  if [ "$kind" = "linked" ]; then
    printf 'linked\t%s\t%s\n' "${ENTRY_DIRS[$idx]}" "${RESULT_TARGET[$idx]:-}"
  else
    printf 'skip\t%s\treason\t%s\n' "${ENTRY_DIRS[$idx]}" "$kind"
    [ "$kind" = "exists" ] || PREP="run"
  fi
done

printf 'prep=%s\n' "$PREP"
exit 0
