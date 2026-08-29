#!/bin/bash
# dev-workflow: レーンの証跡ファイル群から「レーン結果:」表示用の1レーン分の断片を組み立てる（ベンダー中立）
#
# 背景（Task #156）: `skills/run/SKILL.md` Step 4 の「レーン結果: A=#5(12:03-12:11 8m00s) ...」
# 表示は、generator の自由記述の完了報告をオーケストレータ（LLM）が毎回読んで組み立て直して
# いた。generator の完了報告を「証跡はファイルに書き出し、報告にはパスと1行の判定だけを載せる」
# 形式へ変えた結果（`core/roles/generator.md`「完了報告」節）、各タスクの証跡ファイルは
# task=/status=/start_hm=/end_hm=/duration_sec= を含む機械可読なトレーラを持つようになった。
# この組み立てをここに切り出す（決定論的処理をCLIへ寄せる方針。plan-waves.sh / merge-lane.sh
# と同じ発想）。
#
# 使い方:
#   bash scripts/format-lane-result.sh --lane <レーン記号> --file <証跡ファイル> [--file <証跡ファイル> ...]
#
# --file は割り当てられたタスクの実行順に指定する（複数タスクを連続処理したレーンは複数回
# 指定する）。各証跡ファイルは1タスク1ファイルであることを前提とする
# （`core/roles/generator.md`「完了報告」節が定める形式）。
#
# 出力（1行、末尾改行あり）:
#   <レーン記号>=#<task1>,#<task2>(<最初のstart_hm>-<最後のend_hm> <合計duration_secのXmSs表記>)
#   start_hm/end_hmが無い証跡ファイルの場合は時刻区間を省略し `(<合計duration_sec>)` のみ出す。
#   status が success 以外のタスクは `#<task>(失敗)` と付記する。
#
# 終了コード:
#   0 = 組み立てられた
#   2 = 引数エラー・証跡ファイル不備（ファイル不在・必須フィールド欠落）

set -u

LANE=""
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --lane)
      if [ $# -lt 2 ]; then
        echo "ERROR: --lane には値が必要です" >&2
        exit 2
      fi
      LANE="$2"; shift 2 ;;
    --file)
      if [ $# -lt 2 ]; then
        echo "ERROR: --file には値が必要です" >&2
        exit 2
      fi
      FILES+=("$2"); shift 2 ;;
    -*) echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
    *)  echo "ERROR: 未知の引数: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$LANE" ]; then
  echo "ERROR: --lane は必須です" >&2
  exit 2
fi
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "ERROR: --file を1つ以上指定してください" >&2
  exit 2
fi

fmt_duration() {
  local total_sec="$1"
  printf '%dm%02ds' "$((total_sec / 60))" "$((total_sec % 60))"
}

TASK_LABELS=()
FIRST_START_HM=""
LAST_END_HM=""
TOTAL_SEC=0

for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: 証跡ファイルが見つかりません: ${f}" >&2
    exit 2
  fi

  task="$(grep -m1 '^task=' "$f" | cut -d= -f2-)"
  status="$(grep -m1 '^status=' "$f" | cut -d= -f2-)"
  start_hm="$(grep -m1 '^start_hm=' "$f" | cut -d= -f2-)"
  end_hm="$(grep -m1 '^end_hm=' "$f" | cut -d= -f2-)"
  duration_sec="$(grep -m1 '^duration_sec=' "$f" | cut -d= -f2-)"

  if [ -z "$task" ] || [ -z "$status" ] || [ -z "$duration_sec" ]; then
    echo "ERROR: 証跡ファイルに必須フィールド（task=/status=/duration_sec=）がありません: ${f}" >&2
    exit 2
  fi

  label="#${task}"
  [ "$status" = "success" ] || label="${label}(失敗)"
  TASK_LABELS+=("$label")

  if [ -z "$FIRST_START_HM" ]; then
    FIRST_START_HM="$start_hm"
  fi
  if [ -n "$end_hm" ]; then
    LAST_END_HM="$end_hm"
  fi
  TOTAL_SEC=$((TOTAL_SEC + duration_sec))
done

TASKS_JOINED="$(IFS=,; echo "${TASK_LABELS[*]}")"

if [ -n "$FIRST_START_HM" ] && [ -n "$LAST_END_HM" ]; then
  printf '%s=%s(%s-%s %s)\n' "$LANE" "$TASKS_JOINED" "$FIRST_START_HM" "$LAST_END_HM" "$(fmt_duration "$TOTAL_SEC")"
else
  printf '%s=%s(%s)\n' "$LANE" "$TASKS_JOINED" "$(fmt_duration "$TOTAL_SEC")"
fi
