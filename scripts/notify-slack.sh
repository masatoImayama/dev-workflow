#!/bin/bash
# dev-workflow plugin: Slack通知
# hookのJSON payloadを標準入力から受け取り、Slack Incoming Webhookに送信する
#
# 使い方: notify-slack.sh <event> [引数]
#   notification              — hook用。承認待ち／入力待ちを通知
#   stop                      — hook用。ターン終了時。自律実行中なら「中断」として通知
#   run-start   <ラベル>      — skill用。自律実行の開始を記録（通知はしない）
#   run-complete <サマリー>   — skill用。自律実行の完全な完了を通知
#   stall            <詳細>   — watchdog用。無活動しきい値を超えた（メンション付き）
#   stall-recovered  <詳細>   — watchdog用。ストール後に活動が戻った
#   sleep-gap        <詳細>   — watchdog用。tickの実経過が異常に飛んだ（スリープ痕跡）
#   budget           <詳細>   — watchdog用。ウェーブが予算を超えた（メンション付き）
#   sleep-inhibit-warn <詳細> — watchdog用。スリープ抑止に失敗、または対応する手段が無い
#                               （run中でもPCがスリープしうる状態。初回のみ通知される）
#
# watchdogイベントの<詳細>は呼び出し側（watchdog.sh）が組み立てた文字列をそのまま本文に載せる。
# ストール警告では「ツール実行中に停止（state=pre）」「モデルの応答待ちで停止（state=post）」を
# 呼び出し側が文言に含めることで、原因の切り分けができる本文にする（Epic #42 受け入れ条件2）。
# sleep-gapはstallとは別イベントなので、スリープ復帰をストールとして誤報することはない
# （Epic #42 受け入れ条件3）。
#
# 自律実行中は .claude/.dev-workflow-run をマーカーとして置き、
# run-complete に到達せずStopした場合を「中断」として区別する。
#
# Webhook URLの解決順（プロジェクト単位の設定を優先）:
#   1. プロジェクトの .claude/slack-webhook ファイル（1行目のURL）
#   2. 環境変数 SLACK_WEBHOOK_URL
#   どちらも無ければ下記「Epic issueへのフォールバック」へ進む（通知OFFとして
#   黙って捨てる、ではない。クラウドでは .claude/slack-webhook が .gitignore で
#   除外され存在しないため、数時間の自律実行が無音になる問題への対処。Task #280）
#
# Epic issueへのフォールバック（Task #280）:
#   Webhookが未解決、または実送信（curl）が失敗した場合、run marker
#   （.claude/.dev-workflow-run。run-startが書き込む1行目「Epic #<N>」）からEpic番号を
#   取り出し、`gh issue comment` でEpic issueへ記録する。**対象は節目イベントのみ**
#   （stop/run-complete/stall/stall-recovered/sleep-gap/budget/sleep-inhibit-warn）。
#   notification（アイドル・承認待ち通知）はここには進まない（issueが通知ログで
#   埋まるため）。Epic番号が取れない、または `gh` も使えない（インストールされていない・
#   未認証・api.github.com 403等）場合は、.claude/.dev-workflow-notify-fallback.log に
#   ローカル記録するだけに退く（いずれの経路でもrunは止めない。exit 0で抜ける）。
#   連続する同一内容の記録は、既存の .claude/.dev-workflow-notify-last による抑止
#   （DEV_WORKFLOW_NOTIFY_COOLDOWN秒）を流用して間引く。
#   **Slackが生きている（送信に成功する）場合はSlackのみで、フォールバックは一切発生しない**
#   （多重通知にしない。Slack設定済み環境での既存挙動は1ビットも変わらない）。
#   `core/references/github-access.md` の原則どおり、MCP（mcp__github__*）はシェルから
#   呼べないため、ここでは「gh を使えるならgh、使えないならローカル記録」の二択にする。
#   **本文に last_assistant_message（直近応答の末尾最大800文字・無加工）は含めない（#285）。**
#   stopイベントのSlack本文にはlast_assistant_messageを含めるが、Epic issueフォールバックの
#   本文はステータス行＋$ARG相当（FALLBACK_DETAIL）のみにする。Slackはユーザーが能動的に
#   設定した秘匿チャネルだが、Epic issueはリポジトリの共有issueであり、閲覧者の範囲・
#   永続性が異なるため。
#
# 環境変数:
#   DEV_WORKFLOW_NOTIFY_STOP     — "1" のときのみStop完了通知を送る（既定: 送らない）
#   DEV_WORKFLOW_NOTIFY_IDLE     — "1" のときのみ「入力待ち」通知を送る（既定: 送らない）
#   DEV_WORKFLOW_NOTIFY_COOLDOWN — 同じ通知・フォールバック記録を抑止する秒数（既定: 600、0で無効）
#   DEV_WORKFLOW_NOTIFY_DEBUG    — "1" で受け取ったNotificationのpayloadを
#                                  .claude/.dev-workflow-notify.log に記録する
#   DEV_WORKFLOW_NOTIFY_SINK     — 設定されていればcurlを呼ばず、組み立てた本文(JSON)を
#                                  このパスへ書き出す（テスト用。Slackへは送信しない。
#                                  この経路は常に成功扱いとなり、フォールバックへは進まない）

set -u

NOTIFY_SLACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/marker-root.sh
. "${NOTIFY_SLACK_DIR}/lib/marker-root.sh"

EVENT="${1:-unknown}"
ARG="${2:-}"

# hook以外（skillからの直接実行）は標準入力を待たない
case "$EVENT" in
  notification|stop) PAYLOAD="$(cat)" ;;
  *)                 PAYLOAD="" ;;
esac

# JSONから文字列フィールドを取り出す（jqがあれば使い、無ければsedで代替）
json_field() {
  local key="$1"
  if command -v jq &> /dev/null; then
    printf '%s' "$PAYLOAD" | jq -r --arg k "$key" '.[$k] // ""'
  else
    # jqが無い環境向けの簡易抽出。取り出した値のJSONエスケープも戻す
    printf '%s' "$PAYLOAD" \
      | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\(\([^\"\\]\|\\\\.\)*\)\".*/\1/p" \
      | head -1 \
      | sed 's/\\n/ /g; s/\\"/"/g; s/\\\\/\\/g'
  fi
}

# Slackに送る文字列をJSON文字列としてエスケープする
json_escape() {
  if command -v jq &> /dev/null; then
    printf '%s' "$1" | jq -Rs .
  else
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')"
  fi
}

# transcript(jsonl)から最後のアシスタント発言を抜き出す。jqが無い環境では空を返す
last_assistant_message() {
  local transcript
  transcript="$(json_field transcript_path)"
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 0
  command -v jq &> /dev/null || return 0
  tail -50 "$transcript" \
    | jq -r 'select(.type == "assistant")
             | .message.content[]? | select(.type == "text") | .text' 2>/dev/null \
    | tail -20 \
    | cut -c1-800
}

# _dedupe_or_record <signature>
# 同じ署名（内容のハッシュ）を DEV_WORKFLOW_NOTIFY_COOLDOWN 秒以内に連続して記録させない
# （Epic #42 の既存機構を #280 のEpic issueフォールバックにも流用する。再実装しない）。
# 戻り値: 0=初めて（続行してよい。状態ファイルを更新済み） 1=直近に同じ署名を記録済み（抑止する）
_dedupe_or_record() {
  local sig="$1" cooldown state_file now last_sig last_at
  cooldown="${DEV_WORKFLOW_NOTIFY_COOLDOWN:-600}"
  case "$cooldown" in ''|*[!0-9]*) return 0 ;; esac
  [ "$cooldown" -gt 0 ] || return 0

  state_file="$MARKER_ROOT/.claude/.dev-workflow-notify-last"
  now="$(date +%s)"
  last_sig=""
  last_at=0
  [ -f "$state_file" ] && read -r last_sig last_at < "$state_file"
  if [ "$last_sig" = "$sig" ] && [ $((now - ${last_at:-0})) -lt "$cooldown" ]; then
    return 1
  fi
  mkdir -p "$MARKER_ROOT/.claude" 2>/dev/null
  printf '%s %s\n' "$sig" "$now" > "$state_file"
  return 0
}

# notify_fallback <headline> <detail>
# Slack（webhook未解決、または送信失敗）に代わる経路。Epic issueへのコメント、それが
# 使えなければローカルファイルへの記録、のいずれかに必ず到達する（run は止めない。#280）。
# 呼び出し側（EVENT別の分岐）が「notificationは呼ばない」を保証する前提で、ここでは
# EVENT の種類を判定しない。
notify_fallback() {
  local headline="$1" detail="$2" sig body fallback_log

  sig="$(printf '%s' "${EVENT}|${headline}|${detail}" | cksum | cut -d' ' -f1)"
  _dedupe_or_record "$sig" || return 0

  body="[$PROJECT_NAME] ${headline}"
  [ -n "$detail" ] && body="$body
$detail"
  body="$body

context: $CONTEXT"

  # gh issue comment はシェルから直接実行できる経路なのでまず試す（#274の原則:
  # MCPはツール呼び出しであり bash から呼べないため、スクリプト層の二択は
  # 「gh を使えるならgh、使えないならローカル記録」になる）。
  # `timeout` が無い環境（存在しない coreutils 等）ではガード無しで直接実行する
  # （無くても壊れない。あれば api.github.com 到達不能時の長時間ハングを防ぐ）。
  if [ -n "$EPIC_NUM" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout 10 gh issue comment "$EPIC_NUM" --body "$body" >/dev/null 2>&1 && return 0
    else
      gh issue comment "$EPIC_NUM" --body "$body" >/dev/null 2>&1 && return 0
    fi
  fi

  # Epic番号が取れない、または gh が使えない（未インストール・未認証・403等）場合は
  # ローカルに記録するだけに退く（記録を失わない。issueへは後から人間が拾える）。
  fallback_log="$MARKER_ROOT/.claude/.dev-workflow-notify-fallback.log"
  mkdir -p "$MARKER_ROOT/.claude" 2>/dev/null
  {
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$EVENT" "$headline"
    [ -n "$detail" ] && printf '%s\n' "$detail"
  } >> "$fallback_log" 2>/dev/null
  return 0
}

CWD="$(json_field cwd)"
[ -z "$CWD" ] && CWD="$(pwd)"

# 自律実行中であることを示すマーカー。
# skillはworktree（.claude/worktrees/<epicN>）内から実行されるが、hookのcwdはメインリポの
# ルートなので、両者が同じファイルを見るようメインリポのルートに固定する
# （解決処理は scripts/lib/marker-root.sh に共通化してある）
MARKER_ROOT="$(dev_workflow_marker_root "$CWD")"
[ -n "$MARKER_ROOT" ] || MARKER_ROOT="$CWD"
RUN_MARKER="$MARKER_ROOT/.claude/.dev-workflow-run"

# 通知が多すぎるときに、実際どのpayloadで発火しているかを追えるようにする
if [ "$EVENT" = "notification" ] && [ "${DEV_WORKFLOW_NOTIFY_DEBUG:-}" = "1" ]; then
  mkdir -p "$MARKER_ROOT/.claude"
  printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PAYLOAD" \
    >> "$MARKER_ROOT/.claude/.dev-workflow-notify.log"
fi

# run-startは通知を伴わないので、Webhook解決より前に処理する
if [ "$EVENT" = "run-start" ]; then
  mkdir -p "$MARKER_ROOT/.claude"
  printf '%s\n' "${ARG:-自律実行}" > "$RUN_MARKER"
  exit 0
fi

# マーカーの有無で「完全な完了」と「途中停止」を判別する。
# 通知OFFのプロジェクトでもマーカーは残さないよう、Webhook解決より前に消す
RUN_LABEL=""
[ -f "$RUN_MARKER" ] && RUN_LABEL="$(head -1 "$RUN_MARKER" | tr -d '\r')"
[ "$EVENT" = "run-complete" ] && rm -f "$RUN_MARKER"

# Epic issueフォールバック（#280）用。run-startが書き込むラベルは「Epic #<N>」形式
# （skills/run/SKILL.md）。ラベルが無い・形式が違う場合は空のままにする（止めない）。
EPIC_NUM="$(printf '%s' "$RUN_LABEL" | grep -oE '#[0-9]+' | head -1 | tr -d '#')"

# プロジェクト個別の設定を優先し、無ければ環境変数にフォールバックする。
# 設定ファイルはgitignore対象でworktreeには存在しないため、メインリポのルートを見る
WEBHOOK_FILE="$MARKER_ROOT/.claude/slack-webhook"
[ -f "$WEBHOOK_FILE" ] || WEBHOOK_FILE="$CWD/.claude/slack-webhook"
WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
PROJECT_NAME="${DEV_WORKFLOW_PROJECT_NAME:-}"
if [ -f "$WEBHOOK_FILE" ]; then
  # コメント行・空行を無視して最初のURLを採用（末尾のCRも除去）
  FROM_FILE="$(grep -v '^[[:space:]]*#' "$WEBHOOK_FILE" | grep -m1 '^[[:space:]]*https://' | tr -d '\r' | xargs)"
  [ -n "$FROM_FILE" ] && WEBHOOK_URL="$FROM_FILE"
  # 任意: `name=表示名` 行で通知に出すプロジェクト名を上書きできる
  NAME_LINE="$(grep -m1 '^[[:space:]]*name[[:space:]]*=' "$WEBHOOK_FILE" | tr -d '\r' | sed 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*//')"
  [ -n "$NAME_LINE" ] && [ -z "$PROJECT_NAME" ] && PROJECT_NAME="$NAME_LINE"
  # 任意: `mention=` 行でメンション先を変更できる（既定は channel）
  MENTION_LINE="$(grep -m1 '^[[:space:]]*mention[[:space:]]*=' "$WEBHOOK_FILE" | tr -d '\r' | sed 's/^[[:space:]]*mention[[:space:]]*=[[:space:]]*//')"
  [ -n "$MENTION_LINE" ] && [ -z "${DEV_WORKFLOW_SLACK_MENTION:-}" ] && MENTION_SETTING="$MENTION_LINE"
fi

# 既定で @channel を付ける。channel / here / none / 生のメンション文字列（<@U123>等）を受け付ける
MENTION_SETTING="${DEV_WORKFLOW_SLACK_MENTION:-${MENTION_SETTING:-channel}}"
case "$MENTION_SETTING" in
  channel) MENTION="<!channel> " ;;
  here)    MENTION="<!here> " ;;
  none|"") MENTION="" ;;
  *)       MENTION="$MENTION_SETTING " ;;
esac

# Webhook未設定の場合はここでは終了しない（#280）。直後の EVENT 別分岐で
# 「そもそも通知すべき内容か」を判定したあと、Slackへ送れなければEpic issueへ
# フォールバックする。PROJECT_NAME/CONTEXT はフォールバック本文にも使うため、
# Webhookの有無に関わらず計算する。

# 表示名の既定はメインリポのディレクトリ名（worktree内でもプロジェクト名がぶれないように）。
# どの環境から来た通知かブランチとパスも添える
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="$(basename "$MARKER_ROOT")"
BRANCH="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
CONTEXT="$CWD"
[ -n "$BRANCH" ] && CONTEXT="branch: $BRANCH ・ $CWD"

DETAIL=""
# FALLBACK_DETAIL: Epic issueフォールバック（notify_fallback）にだけ渡す本文（#285）。
# last_assistant_message（直近応答の末尾最大800文字・無加工）はSlack（DETAIL）専用とし、
# 共有issueであるEpic issueへは含めない。Slackはユーザーが能動的に設定した秘匿チャネル、
# Epic issueはリポジトリの共有issueという非対称性が根拠（#280のwave-review指摘）。
# $ARG（watchdog.sh等の呼び出し側が組み立てた固定文言）は会話内容ではないため、
# 従来どおりそのままフォールバックにも渡す。
FALLBACK_DETAIL=""
case "$EVENT" in
  notification)
    MESSAGE="$(json_field message)"
    # Notification hookは人の操作を必要としない場面（サブエージェントの切り替え、
    # LLMの応答待ちなど）でも発火し、文言からは区別できなかった。
    # そのため「入力待ち」通知は既定でOFFとし、承認待ちだけを送る。
    # DEV_WORKFLOW_NOTIFY_IDLE=1 のときに限り入力待ちも送る。
    case "$MESSAGE" in
      *permission*|*Permission*|*許可*)
        HEADLINE=":lock: 承認待ち" ;;
      *"waiting for your input"*|*"waiting for input"*|*idle*|*Idle*|*入力待ち*)
        [ "${DEV_WORKFLOW_NOTIFY_IDLE:-}" = "1" ] || exit 0
        HEADLINE=":hourglass: 入力待ち" ;;
      *)
        exit 0 ;;
    esac
    DETAIL="$MESSAGE"
    # notificationはEpic issueフォールバックへ進まない（下記ガードで除外済み）ため
    # FALLBACK_DETAILは使われないが、空のままにしておく（会話内容を混ぜない）。
    ;;
  run-complete)
    # 自律実行が最後まで到達した唯一の地点。常に通知する
    HEADLINE=":white_check_mark: 完了${RUN_LABEL:+ — $RUN_LABEL}"
    DETAIL="$ARG"
    FALLBACK_DETAIL="$ARG"
    ;;
  stop)
    if [ -n "$RUN_LABEL" ]; then
      # マーカーが残ったままのStop = run-completeに到達せず止まった
      HEADLINE=":octagonal_sign: 自律実行が停止 — $RUN_LABEL"
      FALLBACK_DETAIL="完了前に停止しました。エラー・承認待ち・コンテキスト切れの可能性があります。"
      DETAIL="$FALLBACK_DETAIL
$(last_assistant_message 2>/dev/null || true)"
      # 停止通知は1回だけ。以降のターンで鳴り続けないようマーカーを消す
      rm -f "$RUN_MARKER"
    else
      # 通常のターン終了。毎ターン鳴るため明示的にONにしたときだけ送る
      if [ "${DEV_WORKFLOW_NOTIFY_STOP:-}" != "1" ]; then
        exit 0
      fi
      HEADLINE=":white_check_mark: 応答完了"
      DETAIL="$(last_assistant_message 2>/dev/null || true)"
      # last_assistant_message以外に載せる固定文言が無いため、フォールバック本文は
      # ステータス行（$HEADLINE）のみになる（#285）
      FALLBACK_DETAIL=""
    fi
    ;;
  stall)
    # 無活動しきい値超過。呼び出し側（watchdog.sh）が「ツール実行中に停止」
    # 「モデルの応答待ちで停止」のどちらかを詳細文字列に含めて渡す
    HEADLINE=":rotating_light: 応答なし"
    DETAIL="$ARG"
    FALLBACK_DETAIL="$ARG"
    ;;
  stall-recovered)
    HEADLINE=":arrow_forward: 応答が再開"
    DETAIL="$ARG"
    FALLBACK_DETAIL="$ARG"
    ;;
  sleep-gap)
    # スリープ復帰の痕跡。stallとは別イベントなので、通知を見ればストールとの誤報と
    # 区別できる
    HEADLINE=":zzz: スリープ痕跡"
    DETAIL="$ARG"
    FALLBACK_DETAIL="$ARG"
    ;;
  budget)
    HEADLINE=":hourglass_flowing_sand: 想定時間超過"
    DETAIL="$ARG"
    FALLBACK_DETAIL="$ARG"
    ;;
  sleep-inhibit-warn)
    # スリープ抑止に失敗した、または対応する手段が無い場合の警告。同じ警告を毎tick
    # 送るとSlackを埋めるため、初回のみ呼び出す（watchdog.sh側でWD_STATE_INHIBIT_WARNEDを
    # 見て制御している。ここでは受け取った通知をそのまま送るだけ）
    HEADLINE=":warning: スリープ抑止に失敗"
    DETAIL="$ARG"
    FALLBACK_DETAIL="$ARG"
    ;;
  *)
    HEADLINE=":information_source: $EVENT"
    ;;
esac

# アイドル通知は待たせている間ずっと繰り返し発火するので、
# 同じ内容が続く間は一定時間鳴らさない（_dedupe_or_record。#280でEpic issueフォールバックにも
# 同じ機構を流用したため共通関数へ切り出した。挙動は従来と同一）
if [ "$EVENT" = "notification" ]; then
  SIG="$(printf '%s' "$HEADLINE|$DETAIL" | cksum | cut -d' ' -f1)"
  _dedupe_or_record "$SIG" || exit 0
fi

# 1行目でプロジェクトを特定できるようにする
TEXT="${MENTION}[$PROJECT_NAME] $HEADLINE"
[ -n "$DETAIL" ] && TEXT="$TEXT
$DETAIL"

BODY="{\"text\":$(json_escape "$TEXT"),\"blocks\":[
  {\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":$(json_escape "${MENTION}*[$PROJECT_NAME]* $HEADLINE${DETAIL:+
$DETAIL}")}},
  {\"type\":\"context\",\"elements\":[{\"type\":\"mrkdwn\",\"text\":$(json_escape "$CONTEXT")}]}
]}"

# 実送信は1箇所に閉じ込める。DEV_WORKFLOW_NOTIFY_SINK（ファイルパス）が設定されていれば
# curlを呼ばず、組み立てた本文をそのファイルへ書き出すだけにする。
# これによりテストがSlackへ実送信せずペイロードを検証できる。
send_to_slack() {
  local body="$1"

  if [ -n "${DEV_WORKFLOW_NOTIFY_SINK:-}" ]; then
    printf '%s' "$body" > "$DEV_WORKFLOW_NOTIFY_SINK"
    return 0
  fi

  # 本文は必ずファイル経由で渡す。
  # Git for Windows の curl はネイティブビルドのため、コマンドライン引数として渡した
  # UTF-8 の日本語が cp932 に変換されて壊れる（--data は使わない）。
  local body_file
  # mktemp失敗を「成功扱い」で握り潰すと#280のフォールバック判定が働かない
  # （実送信していないのに成功とみなしてしまう）ため、失敗として返す。
  body_file="$(mktemp -t slack-notify.XXXXXX)" || return 1
  trap 'rm -f "$body_file"' RETURN
  printf '%s' "$body" > "$body_file"

  # -f（--fail）でHTTPエラー応答（4xx/5xx。例: webhook URLが無効化された）も
  # 失敗として扱う（#280）。従来は応答コードを見ておらず、プロキシにブロックされて
  # 4xxが返っても「成功」扱いだった。
  curl -sS -f -m 10 -X POST -H 'Content-Type: application/json; charset=utf-8' \
    --data-binary @"$body_file" "$WEBHOOK_URL" > /dev/null 2>&1
}

# Webhookが解決できていれば送信し、その成否をフォールバック判定に使う（#280）。
# 未解決の場合は「失敗」として扱い、同じフォールバック経路へ進む。
# notification はここに到達した時点で「送るべき内容」が確定済みだが、Slackが
# 使えないときにEpic issueへは進まない（アイドル・承認待ち通知でissueを埋めないため）。
if [ -n "$WEBHOOK_URL" ]; then
  send_to_slack "$BODY"
  SLACK_SEND_RC=$?
else
  SLACK_SEND_RC=1
fi

if [ "$SLACK_SEND_RC" -ne 0 ] && [ "$EVENT" != "notification" ]; then
  # DETAILではなくFALLBACK_DETAILを渡す。last_assistant_message（会話内容の無加工な抜粋）を
  # 共有issueであるEpic issueへ持ち込まないため（#285）
  notify_fallback "$HEADLINE" "$FALLBACK_DETAIL"
fi

exit 0
