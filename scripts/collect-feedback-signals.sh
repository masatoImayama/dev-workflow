#!/bin/bash
# dev-workflow: フィードバック分析の入力となる「実行ログの所在と要約」を集める
#
# 背景: /dev-workflow:feedback は「ハーネスの実行ログを読んで改善点を出す」スキルだが、
# **どこに何があるかの探索まで自然言語の指示に任せると、毎回違う場所を見て違う結論が出る**。
# 探索と一次集計はここに固定し、スキル側には「読むべきファイルと数字」だけを渡す。
# Docker には一切触れない。gh も呼ばない（ネットワークとレート制限に依存させない）。
#
# **追加の依存物（jq 等）は一切使わない。** 素の bash と sed だけで完結する。
#
# 見る対象:
#   1. <マーカールート>/.claude/.dev-workflow-run-state       … 中断した run の epic/wave/budget
#   2. <マーカールート>/.claude/.dev-workflow-heartbeat        … 最終の生存信号
#   3. <マーカールート>/.claude/.dev-workflow-watchdog.log     … stall / escalate / abort の回数
#   4. <マーカールート>/.claude/agent-tokens.tsv               … role 別のトークン消費
#   5. ${HOME}/.claude/projects/<slug>/*.jsonl                 … ハーネスのセッション transcript
#   6. フィードバック台帳（scripts/feedback-ledger.sh path）    … 既存の観測と閾値到達状況
#
# transcript の中身はここでは読まない（会話本文の解釈は分析側の仕事であり、
# grep で拾える性質のものではない）。**パスと更新時刻と行数だけを返す。**
#
# 使い方:
#   collect-feedback-signals.sh [--since <日数>] [--epic <N>] [--max-transcripts <N>]
#
#   --since            transcript を絞る日数（既定: 7）
#   --epic             トークン集計を特定Epicに絞る（既定: 全件）
#   --max-transcripts  列挙する transcript の上限（既定: 20。新しい順）
#
# 出力: `キー=値` の1行1項目。キーはドット区切りで、セクションを前置する。
#       値が無い・ファイルが無い場合は `<section>.available=0` を出す（黙って省略しない）。
#
# 終了コード: 0=成功（対象が1つも無くても0） / 2=引数エラー

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/marker-root.sh
. "${SCRIPT_DIR}/lib/marker-root.sh"

SINCE_DAYS=7
EPIC=""
MAX_TRANSCRIPTS=20

usage() {
  sed -n '/^# 使い方:/,/^# 終了コード:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

is_digits() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      [ $# -ge 2 ] || { echo "ERROR: --since には値が必要です" >&2; exit 2; }
      SINCE_DAYS="$2"; shift 2 ;;
    --epic)
      [ $# -ge 2 ] || { echo "ERROR: --epic には値が必要です" >&2; exit 2; }
      EPIC="$2"; shift 2 ;;
    --max-transcripts)
      [ $# -ge 2 ] || { echo "ERROR: --max-transcripts には値が必要です" >&2; exit 2; }
      MAX_TRANSCRIPTS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: 不明な引数: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

is_digits "$SINCE_DAYS" || { echo "ERROR: --since は数値です" >&2; exit 2; }
is_digits "$MAX_TRANSCRIPTS" || { echo "ERROR: --max-transcripts は数値です" >&2; exit 2; }
if [ -n "$EPIC" ] && ! is_digits "$EPIC"; then
  echo "ERROR: --epic は数値です" >&2
  exit 2
fi

NOW="$(date +%s)"
SINCE_TS=$((NOW - SINCE_DAYS * 86400))

echo "collected_at=${NOW}"
echo "since_ts=${SINCE_TS}"
echo "since_days=${SINCE_DAYS}"

# ---------------------------------------------------------------------------
# 1. リポジトリ
# ---------------------------------------------------------------------------

REPO_ROOT=""
if REPO_ROOT="$(dev_workflow_marker_root)"; then
  :
else
  REPO_ROOT=""
fi

if [ -z "$REPO_ROOT" ]; then
  echo "repo.available=0"
  echo "repo.note=git管理下ではありません"
else
  echo "repo.available=1"
  echo "repo.root=${REPO_ROOT}"
  echo "repo.key=$(basename "$REPO_ROOT")"
  # 駆動先が dev-workflow 自身かどうかで、ハーネス起因の指摘を「その場で直す」か
  # 「還流させる」かが変わる（skills/feedback/references/scope.md）
  ORIGIN="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  echo "repo.origin=${ORIGIN:-none}"
  case "$ORIGIN" in
    *dev-workflow*) echo "repo.is_dev_workflow=1" ;;
    *) echo "repo.is_dev_workflow=0" ;;
  esac
fi

STATE_DIR=""
[ -n "$REPO_ROOT" ] && STATE_DIR="${REPO_ROOT}/.claude"

# ---------------------------------------------------------------------------
# 2. run-state（中断した run の痕跡）
# ---------------------------------------------------------------------------

RUN_STATE="${STATE_DIR:+${STATE_DIR}/.dev-workflow-run-state}"
if [ -n "$RUN_STATE" ] && [ -f "$RUN_STATE" ]; then
  echo "runstate.available=1"
  echo "runstate.path=${RUN_STATE}"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      *=*) echo "runstate.${line}" ;;
    esac
  done < "$RUN_STATE"
else
  echo "runstate.available=0"
fi

# ---------------------------------------------------------------------------
# 3. heartbeat（最終の生存信号）
# ---------------------------------------------------------------------------

HEARTBEAT="${STATE_DIR:+${STATE_DIR}/.dev-workflow-heartbeat}"
if [ -n "$HEARTBEAT" ] && [ -f "$HEARTBEAT" ]; then
  hb_ts=""; hb_phase=""; hb_tool=""
  IFS=$'\t' read -r hb_ts hb_phase hb_tool < "$HEARTBEAT" || true
  hb_tool="${hb_tool%$'\r'}"
  echo "heartbeat.available=1"
  echo "heartbeat.ts=${hb_ts}"
  echo "heartbeat.phase=${hb_phase}"
  echo "heartbeat.tool=${hb_tool:--}"
  if is_digits "$hb_ts"; then
    echo "heartbeat.age_sec=$((NOW - hb_ts))"
  fi
else
  echo "heartbeat.available=0"
fi

# ---------------------------------------------------------------------------
# 4. watchdog.log（停滞の回数。ハーネスが詰まった場所の一次証拠）
# ---------------------------------------------------------------------------

WATCHDOG_LOG="${STATE_DIR:+${STATE_DIR}/.dev-workflow-watchdog.log}"
if [ -n "$WATCHDOG_LOG" ] && [ -f "$WATCHDOG_LOG" ]; then
  echo "watchdog.available=1"
  echo "watchdog.path=${WATCHDOG_LOG}"
  wd_total=0; wd_stall=0; wd_escalate=0; wd_abort=0; wd_inhibit=0
  wd_last_stall=""
  while IFS= read -r line || [ -n "$line" ]; do
    wd_total=$((wd_total + 1))
    case "$line" in
      *$'\t'stall*)    wd_stall=$((wd_stall + 1)); wd_last_stall="$line" ;;
      *$'\t'escalate*) wd_escalate=$((wd_escalate + 1)) ;;
      *$'\t'abort*)    wd_abort=$((wd_abort + 1)) ;;
      *$'\t'inhibit*)  wd_inhibit=$((wd_inhibit + 1)) ;;
    esac
  done < "$WATCHDOG_LOG"
  echo "watchdog.lines=${wd_total}"
  echo "watchdog.stall_count=${wd_stall}"
  echo "watchdog.escalate_count=${wd_escalate}"
  echo "watchdog.abort_count=${wd_abort}"
  echo "watchdog.inhibit_count=${wd_inhibit}"
  echo "watchdog.last_stall=${wd_last_stall:--}"
else
  echo "watchdog.available=0"
fi

# ---------------------------------------------------------------------------
# 5. agent-tokens.tsv（role 別のトークン消費。コスト面の劣化を見る）
# ---------------------------------------------------------------------------

TOKENS_TSV="${DEV_WORKFLOW_AGENT_TOKENS_FILE:-${STATE_DIR:+${STATE_DIR}/agent-tokens.tsv}}"
if [ -n "$TOKENS_TSV" ] && [ -f "$TOKENS_TSV" ]; then
  echo "tokens.available=1"
  echo "tokens.path=${TOKENS_TSV}"
  declare -A tok_count
  declare -A tok_sum
  tok_order=()
  tok_records=0
  t_ts=""; t_epic=""; t_role=""; t_mode=""; t_tokens=""
  while IFS=$'\t' read -r t_ts t_epic t_role t_mode t_tokens _; do
    is_digits "$t_ts" || continue
    is_digits "$t_tokens" || continue
    if [ -n "$EPIC" ] && [ "$t_epic" != "$EPIC" ]; then
      continue
    fi
    tok_records=$((tok_records + 1))
    tk="${t_role}:${t_mode}"
    if [ -z "${tok_count[$tk]:-}" ]; then
      tok_order+=("$tk")
      tok_count[$tk]=0
      tok_sum[$tk]=0
    fi
    tok_count[$tk]=$((tok_count[$tk] + 1))
    tok_sum[$tk]=$((tok_sum[$tk] + t_tokens))
  done < "$TOKENS_TSV"
  echo "tokens.records=${tok_records}"
  echo "tokens.epic_filter=${EPIC:--}"
  if [ "${#tok_order[@]}" -gt 0 ]; then
    for tk in "${tok_order[@]}"; do
      echo "tokens.by.${tk}=count:${tok_count[$tk]},sum:${tok_sum[$tk]},avg:$((tok_sum[$tk] / tok_count[$tk]))"
    done
  fi
else
  echo "tokens.available=0"
fi

# ---------------------------------------------------------------------------
# 6. セッション transcript（ハーネスの実行ログ本体。中身は分析側が読む）
# ---------------------------------------------------------------------------

slugify() {
  # Claude Code は cwd の絶対パスを「英数字以外すべてハイフン」に潰したものを
  # ~/.claude/projects/ 配下のディレクトリ名に使う（例: C:\a\b -> C--a-b）。
  printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

TRANSCRIPT_DIR=""
PROJECTS_ROOT="${CLAUDE_PROJECTS_DIR:-${HOME:-}/.claude/projects}"

if [ -n "${HOME:-}" ] && [ -d "$PROJECTS_ROOT" ] && [ -n "$REPO_ROOT" ]; then
  # Windows（Git Bash）では $PWD 由来の `/c/...` ではなく Windows 形式の `C:\...` から
  # スラッグが作られる。両方の表現を候補にして、実在するほうを採る。
  cand_paths=("$REPO_ROOT")
  if win_path="$(cd "$REPO_ROOT" 2>/dev/null && pwd -W 2>/dev/null)"; then
    [ -n "$win_path" ] && cand_paths+=("$win_path")
  fi
  for p in "${cand_paths[@]}"; do
    d="${PROJECTS_ROOT}/$(slugify "$p")"
    if [ -d "$d" ]; then
      TRANSCRIPT_DIR="$d"
      break
    fi
  done
  # 候補が外れたときは、リポジトリ名で終わるディレクトリを探す（末尾一致の後方互換）
  if [ -z "$TRANSCRIPT_DIR" ]; then
    repo_base="$(basename "$REPO_ROOT")"
    for d in "${PROJECTS_ROOT}"/*"$(slugify "$repo_base")"; do
      if [ -d "$d" ]; then
        TRANSCRIPT_DIR="$d"
        break
      fi
    done
  fi
fi

if [ -z "$TRANSCRIPT_DIR" ]; then
  echo "transcripts.available=0"
  echo "transcripts.projects_root=${PROJECTS_ROOT}"
else
  echo "transcripts.available=1"
  echo "transcripts.dir=${TRANSCRIPT_DIR}"
  # 更新時刻の新しい順に並べる。`ls -t` に頼らず mtime を前置してソートする
  # （ファイル名に空白が入っても壊れないようにするため）。
  listing="$(
    for f in "${TRANSCRIPT_DIR}"/*.jsonl; do
      [ -f "$f" ] || continue
      m="$(date -r "$f" +%s 2>/dev/null || echo 0)"
      [ "$m" -lt "$SINCE_TS" ] && continue
      printf '%s\t%s\n' "$m" "$f"
    done | sort -rn
  )"
  n=0
  if [ -n "$listing" ]; then
    while IFS=$'\t' read -r m f; do
      [ -n "$f" ] || continue
      n=$((n + 1))
      [ "$n" -gt "$MAX_TRANSCRIPTS" ] && break
      echo "transcripts.${n}.mtime=${m}"
      echo "transcripts.${n}.path=${f}"
      echo "transcripts.${n}.lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')"
    done <<< "$listing"
  fi
  listed=$((n > MAX_TRANSCRIPTS ? MAX_TRANSCRIPTS : n))
  echo "transcripts.listed=${listed}"
  # 上限で打ち切ったことを黙って隠さない（「全部見た」と読める出力を作らない）
  if [ "$n" -gt "$MAX_TRANSCRIPTS" ]; then
    echo "transcripts.truncated=1"
  else
    echo "transcripts.truncated=0"
  fi
fi

# ---------------------------------------------------------------------------
# 7. フィードバック台帳（既存の観測と、閾値に達しているキー）
# ---------------------------------------------------------------------------

LEDGER_SH="${SCRIPT_DIR}/feedback-ledger.sh"
if [ -f "$LEDGER_SH" ]; then
  ledger_dir="$(bash "$LEDGER_SH" path 2>/dev/null || true)"
  if [ -n "$ledger_dir" ]; then
    echo "ledger.available=1"
    echo "ledger.dir=${ledger_dir}"
    echo "ledger.observations=$(bash "$LEDGER_SH" list 2>/dev/null | wc -l | tr -d ' ')"
    echo "ledger.ready_harness=$(bash "$LEDGER_SH" ready --scope harness 2>/dev/null | wc -l | tr -d ' ')"
    echo "ledger.ready_project=$(bash "$LEDGER_SH" ready --scope project 2>/dev/null | wc -l | tr -d ' ')"
    if [ -f "${ledger_dir}/learnings.md" ]; then
      echo "ledger.learnings=${ledger_dir}/learnings.md"
    else
      echo "ledger.learnings=none"
    fi
  else
    echo "ledger.available=0"
  fi
else
  echo "ledger.available=0"
fi

exit 0
