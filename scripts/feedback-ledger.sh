#!/bin/bash
# dev-workflow: フィードバック台帳（観測の記録・再現回数の集計・還流レポートの生成）
#
# 背景: ハーネスの実行ログから得た気付きを、その場の会話で消費して終わらせず、
# 「何回再現したか」を数えられる形で蓄積するための台帳。1回きりの事故で
# プロジェクトのルールを書き換えたりissueを立てたりすると誤検知が定着するため、
# **同じキーが閾値回数だけ再現して初めて反映・還流を提案する**（昇格閾値）。
#
# 置き場所（ハーネス非注入原則。README「ハーネス非注入原則」節）:
#   ${HOME}/.claude/dev-workflow/feedback/<repo>/observations.tsv
# サンドボックス定義の規約パス（${HOME}/.claude/dev-workflow/sandbox/<repo>/）と同じ流儀で、
# **駆動先の業務リポジトリには一切書き込まない**。<repo> の解決方法は
# scripts/resolve-sandbox.sh の REPO と同一（git-common-dir 由来。worktree の basename に依存しない）。
#
# **追加の依存物（jq 等）は一切使わない。** 集計は bash の連想配列だけで行う
# （scripts/record-agent-tokens.sh と同じ作法）。redact だけは正規表現が要るため sed -E を使う。
#
# 記録形式: TSV（タブ区切り）1行1レコード、8列。
#   timestamp  scope  category  key  severity  epic  summary  evidence
#
#   timestamp … epoch秒（date +%s）
#   scope     … project = このプロジェクト固有の話 / harness = dev-workflow 本体の話
#   category  … 分類スラッグ（gate / sandbox / permission / plan / review / telemetry / docs / other）
#   key       … 再現回数を数える単位となる安定したスラッグ。同じ現象には同じ key を付けること
#   severity  … high / medium / low
#   epic      … 観測元のEpic issue番号（無ければ空）
#   summary   … 1行要約
#   evidence  … 根拠の参照（例: watchdog.log:stall x3）
#
#   summary / evidence 中のタブ・改行は記録時に空白へ潰す（TSVの列構造を壊さないため）。
#   空になるフィールド（epic / evidence）は `-` で埋める。IFS にタブを指定した read は
#   連続タブを1つに畳むため、空フィールドをそのまま書くと読み出し時に列がずれる。
#
# 使い方:
#   feedback-ledger.sh record --scope <project|harness> --category <slug> --key <slug> \
#     [--severity <high|medium|low>] [--epic <N>] --summary <1行> [--evidence <1行>]
#   feedback-ledger.sh list [--scope <s>] [--key <slug>] [--since <epoch秒>]
#   feedback-ledger.sh count --key <slug>
#   feedback-ledger.sh ready [--scope <s>] [--threshold <N>]
#   feedback-ledger.sh render-upstream --key <slug>
#   feedback-ledger.sh upstream-repo   （還流先の owner/repo を出力）
#   feedback-ledger.sh redact          （標準入力を redact して標準出力へ。単体テスト用）
#   feedback-ledger.sh path            （台帳ディレクトリの絶対パスを出力）
#
# 環境変数:
#   DEV_WORKFLOW_FEEDBACK_DIR        台帳ディレクトリを直接上書きする（テスト用）
#   DEV_WORKFLOW_FEEDBACK_HOME       台帳の親ディレクトリ（既定: ${HOME}/.claude/dev-workflow/feedback）
#   DEV_WORKFLOW_FEEDBACK_THRESHOLD  昇格閾値（既定: 3）
#   DEV_WORKFLOW_UPSTREAM_REPO       還流先の owner/repo を上書きする（既定: マニフェストの repository）
#
# 終了コード: 0=成功 / 1=書き込み・読み取り失敗 / 2=引数エラー・置き場所を解決できない
#            ready と count は「該当0件」でも 0 を返す（件数は標準出力で表す）

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '/^# 使い方:/,/^# 終了コード:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# 置き場所の解決
# ---------------------------------------------------------------------------

_repo_key() {
  # scripts/resolve-sandbox.sh の REPO と同じ解決方法にすること。
  # worktree の basename（agent-xxxx / epicNN）を使うと worktree ごとに別台帳になってしまう。
  local git_common root
  git_common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$git_common" ]; then
    root="$(dirname "$git_common")"
    basename "$root"
  else
    basename "$(pwd)"
  fi
}

_feedback_dir() {
  local home repo
  if [ -n "${DEV_WORKFLOW_FEEDBACK_DIR:-}" ]; then
    printf '%s' "$DEV_WORKFLOW_FEEDBACK_DIR"
    return 0
  fi
  home="${DEV_WORKFLOW_FEEDBACK_HOME:-}"
  if [ -z "$home" ] && [ -n "${HOME:-}" ]; then
    home="${HOME}/.claude/dev-workflow/feedback"
  fi
  [ -n "$home" ] || return 1
  repo="$(_repo_key)"
  [ -n "$repo" ] || return 1
  printf '%s/%s' "$home" "$repo"
}

_ledger_file() {
  local dir
  dir="$(_feedback_dir)" || return 1
  printf '%s/observations.tsv' "$dir"
}

_threshold() {
  local t="${DEV_WORKFLOW_FEEDBACK_THRESHOLD:-3}"
  case "$t" in
    ''|*[!0-9]*)
      printf '3'
      return 0
      ;;
  esac
  if [ "$t" -lt 1 ]; then
    printf '3'
  else
    printf '%s' "$t"
  fi
}

# ---------------------------------------------------------------------------
# 入力の検証と整形
# ---------------------------------------------------------------------------

_is_slug() {
  case "$1" in
    ''|*[!a-z0-9-]*) return 1 ;;
    -*|*-) return 1 ;;
    *) return 0 ;;
  esac
}

_is_digits() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

_flatten() {
  # TSVの列構造を壊さないよう、タブ・CR・LF を空白へ潰す
  local s="$1"
  s="${s//$'\t'/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

_require_opt_value() {
  # _require_opt_value <サブコマンド名> <オプション名> <残り引数の個数>
  local sub="$1" opt="$2" remaining="$3"
  if [ "$remaining" -lt 2 ]; then
    echo "ERROR: ${sub}: ${opt} には値が必要です" >&2
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# redact（還流レポートに載せる前の機械的な伏字化）
# ---------------------------------------------------------------------------
#
# 「還流させたい情報」は現象と再現条件であって、駆動先プロジェクトの中身ではない。
# ここでは機械的に落とせるものだけを落とす。**判断が要る伏字化（コード片・社名・
# 未公開の仕様）は呼び出し側（skills/feedback）が行い、人間が投稿前に必ず確認する。**
# このスクリプトは最後の網であって、唯一の防御線ではない。

_redact() {
  local line user repo
  user="${USER:-${USERNAME:-}}"
  repo="$(_repo_key 2>/dev/null || true)"

  # 文字列としてそのまま置換できるもの（HOME・ユーザー名・リポジトリ名）を先に潰す。
  # ユーザー名が2文字以下だと普通の単語を巻き込むため置換しない。
  # リポジトリ名が dev-workflow のとき（＝このリポジトリ自身を駆動している）は、
  # 伏字にすると還流レポートの意味が失われるので置換しない。
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "${HOME:-}" ]; then
      line="${line//"${HOME}"/<home>}"
    fi
    if [ -n "$user" ] && [ "${#user}" -ge 3 ]; then
      line="${line//"${user}"/<user>}"
    fi
    if [ -n "$repo" ] && [ "$repo" != "dev-workflow" ] && [ "${#repo}" -ge 3 ]; then
      line="${line//"${repo}"/<repo>}"
    fi
    printf '%s\n' "$line"
  done | sed -E \
    -e 's#gh[pousr]_[A-Za-z0-9]{16,}#<secret>#g' \
    -e 's#github_pat_[A-Za-z0-9_]{16,}#<secret>#g' \
    -e 's#xox[abposr]-[A-Za-z0-9-]{10,}#<secret>#g' \
    -e 's#sk-[A-Za-z0-9_-]{16,}#<secret>#g' \
    -e 's#https://hooks\.slack\.com/[A-Za-z0-9/_+-]+#<slack-webhook>#g' \
    -e 's#[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}#<email>#g' \
    -e 's#/[A-Za-z]/[Uu]sers/[^/[:space:]]+#<home>#g' \
    -e 's#[A-Za-z]:/[Uu]sers/[^/[:space:]]+#<home>#g' \
    -e 's#[A-Za-z]:\\[Uu]sers\\[^\\/[:space:]]+#<home>#g' \
    -e 's#/[Uu]sers/[^/[:space:]]+#<home>#g' \
    -e 's#/home/[^/[:space:]]+#<home>#g'
}

# ---------------------------------------------------------------------------
# サブコマンド
# ---------------------------------------------------------------------------

cmd_record() {
  local scope="" category="" key="" severity="medium" epic="" summary="" evidence=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)    _require_opt_value record "$1" "$#" || return 2; scope="$2"; shift 2 ;;
      --category) _require_opt_value record "$1" "$#" || return 2; category="$2"; shift 2 ;;
      --key)      _require_opt_value record "$1" "$#" || return 2; key="$2"; shift 2 ;;
      --severity) _require_opt_value record "$1" "$#" || return 2; severity="$2"; shift 2 ;;
      --epic)     _require_opt_value record "$1" "$#" || return 2; epic="$2"; shift 2 ;;
      --summary)  _require_opt_value record "$1" "$#" || return 2; summary="$2"; shift 2 ;;
      --evidence) _require_opt_value record "$1" "$#" || return 2; evidence="$2"; shift 2 ;;
      *)
        echo "ERROR: record: 不明な引数: $1" >&2
        return 2
        ;;
    esac
  done

  case "$scope" in
    project|harness) ;;
    *)
      echo "ERROR: record: --scope は project か harness です（受け取った値: '${scope}'）" >&2
      return 2
      ;;
  esac

  if ! _is_slug "$category"; then
    echo "ERROR: record: --category は小文字英数字とハイフンのスラッグです（受け取った値: '${category}'）" >&2
    return 2
  fi

  if ! _is_slug "$key"; then
    echo "ERROR: record: --key は小文字英数字とハイフンのスラッグです（受け取った値: '${key}'）" >&2
    return 2
  fi

  case "$severity" in
    high|medium|low) ;;
    *)
      echo "ERROR: record: --severity は high / medium / low です（受け取った値: '${severity}'）" >&2
      return 2
      ;;
  esac

  if [ -n "$epic" ] && ! _is_digits "$epic"; then
    echo "ERROR: record: --epic は数値です（受け取った値: '${epic}'）" >&2
    return 2
  fi

  if [ -z "$summary" ]; then
    echo "ERROR: record: --summary は必須です" >&2
    return 2
  fi

  local file dir
  file="$(_ledger_file)" || {
    echo "ERROR: record: 台帳の置き場所を解決できませんでした（HOME 未設定か git 管理外）" >&2
    return 2
  }
  dir="$(dirname "$file")"

  mkdir -p "$dir" 2>/dev/null || {
    echo "ERROR: record: ディレクトリを作成できませんでした: ${dir}" >&2
    return 1
  }

  local ts summary_out evidence_out
  ts="$(date +%s)"

  # 空フィールドは `-` で埋める。
  # タブは IFS の「空白」扱いなので、`IFS=$'\t' read` は**連続したタブを1つに畳み、
  # 行頭のタブを読み飛ばす**。空の epic や evidence をそのまま空文字で書くと、
  # 読み出し側で列が1つずれて summary が epic に入る（実測済み）。
  # 読み出し側を complicate させるより、書き込み側で空フィールドを作らないほうが安全。
  summary_out="$(_flatten "$summary")"
  evidence_out="$(_flatten "$evidence")"
  [ -n "$summary_out" ] || summary_out="-"
  [ -n "$evidence_out" ] || evidence_out="-"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$scope" "$category" "$key" "$severity" "${epic:--}" \
    "$summary_out" "$evidence_out" >> "$file" || {
    echo "ERROR: record: 台帳へ書き込めませんでした: ${file}" >&2
    return 1
  }

  echo "recorded key=${key} scope=${scope} severity=${severity} file=${file}"
  return 0
}

cmd_list() {
  local want_scope="" want_key="" since=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --scope) _require_opt_value list "$1" "$#" || return 2; want_scope="$2"; shift 2 ;;
      --key)   _require_opt_value list "$1" "$#" || return 2; want_key="$2"; shift 2 ;;
      --since) _require_opt_value list "$1" "$#" || return 2; since="$2"; shift 2 ;;
      *)
        echo "ERROR: list: 不明な引数: $1" >&2
        return 2
        ;;
    esac
  done

  if [ -n "$since" ] && ! _is_digits "$since"; then
    echo "ERROR: list: --since は epoch 秒（数値）です" >&2
    return 2
  fi

  local file
  file="$(_ledger_file)" || {
    echo "ERROR: list: 台帳の置き場所を解決できませんでした" >&2
    return 2
  }
  [ -f "$file" ] || return 0

  local ts scope category key severity epic summary evidence
  while IFS=$'\t' read -r ts scope category key severity epic summary evidence; do
    _is_digits "$ts" || continue
    if [ -n "$want_scope" ] && [ "$scope" != "$want_scope" ]; then
      continue
    fi
    if [ -n "$want_key" ] && [ "$key" != "$want_key" ]; then
      continue
    fi
    if [ -n "$since" ] && [ "$ts" -lt "$since" ]; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ts" "$scope" "$category" "$key" "$severity" "$epic" "$summary" "$evidence"
  done < "$file"

  return 0
}

cmd_count() {
  local key=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --key) _require_opt_value count "$1" "$#" || return 2; key="$2"; shift 2 ;;
      *)
        echo "ERROR: count: 不明な引数: $1" >&2
        return 2
        ;;
    esac
  done

  if [ -z "$key" ]; then
    echo "ERROR: count: --key は必須です" >&2
    return 2
  fi

  local file n=0
  file="$(_ledger_file)" || {
    echo "ERROR: count: 台帳の置き場所を解決できませんでした" >&2
    return 2
  }

  if [ -f "$file" ]; then
    local ts rec_key
    while IFS=$'\t' read -r ts _ _ rec_key _; do
      _is_digits "$ts" || continue
      if [ "$rec_key" = "$key" ]; then
        n=$((n + 1))
      fi
    done < "$file"
  fi

  echo "count=${n}"
  echo "threshold=$(_threshold)"
  return 0
}

cmd_ready() {
  # 閾値に達した key を一覧する（＝反映・還流を提案してよい候補）
  local want_scope="" threshold=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --scope)     _require_opt_value ready "$1" "$#" || return 2; want_scope="$2"; shift 2 ;;
      --threshold) _require_opt_value ready "$1" "$#" || return 2; threshold="$2"; shift 2 ;;
      *)
        echo "ERROR: ready: 不明な引数: $1" >&2
        return 2
        ;;
    esac
  done

  if [ -n "$threshold" ] && ! _is_digits "$threshold"; then
    echo "ERROR: ready: --threshold は数値です" >&2
    return 2
  fi
  if [ -z "$threshold" ]; then
    threshold="$(_threshold)"
  fi

  local file
  file="$(_ledger_file)" || {
    echo "ERROR: ready: 台帳の置き場所を解決できませんでした" >&2
    return 2
  }
  [ -f "$file" ] || return 0

  local -A count_map
  local -A scope_map
  local -A category_map
  local -A severity_map
  local -A summary_map
  local -A first_map
  local -A last_map
  local keys_order=()

  local ts scope category key severity summary
  while IFS=$'\t' read -r ts scope category key severity _ summary _; do
    _is_digits "$ts" || continue
    if [ -n "$want_scope" ] && [ "$scope" != "$want_scope" ]; then
      continue
    fi
    if [ -z "${count_map[$key]:-}" ]; then
      keys_order+=("$key")
      count_map[$key]=0
      first_map[$key]="$ts"
      severity_map[$key]="low"
    fi
    count_map[$key]=$((count_map[$key] + 1))
    scope_map[$key]="$scope"
    category_map[$key]="$category"
    summary_map[$key]="$summary"
    last_map[$key]="$ts"
    # 深刻度は観測の中で最も重いものを採る
    case "${severity}:${severity_map[$key]}" in
      high:*) severity_map[$key]="high" ;;
      medium:low) severity_map[$key]="medium" ;;
    esac
  done < "$file"

  if [ "${#keys_order[@]}" -eq 0 ]; then
    return 0
  fi

  local k
  for k in "${keys_order[@]}"; do
    if [ "${count_map[$k]}" -lt "$threshold" ]; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$k" "${count_map[$k]}" "${scope_map[$k]}" "${category_map[$k]}" \
      "${severity_map[$k]}" "${first_map[$k]}" "${last_map[$k]}" "${summary_map[$k]}"
  done

  return 0
}

_iso_utc() {
  # epoch秒 -> ISO8601(UTC)。GNU date と BSD date の両方を試し、どちらも駄目なら epoch のまま返す
  local ts="$1" out
  if out="$(date -u -d "@${ts}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
    printf '%s' "$out"
    return 0
  fi
  if out="$(date -u -r "$ts" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
    printf '%s' "$out"
    return 0
  fi
  printf 'epoch:%s' "$ts"
}

_plugin_version() {
  local manifest line
  manifest="${SCRIPT_DIR}/../.claude-plugin/plugin.json"
  if [ ! -f "$manifest" ]; then
    printf 'unknown'
    return 0
  fi
  line="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$manifest" 2>/dev/null | head -1)"
  # 例: `"version": "0.17.0"` -> 末尾の引用符を落としてから、最後の引用符より後ろを取る
  line="${line%\"}"
  line="${line##*\"}"
  if [ -n "$line" ]; then
    printf '%s' "$line"
  else
    printf 'unknown'
  fi
}

cmd_render_upstream() {
  # ハーネス起因の観測を、dev-workflow へ還流させる issue 本文に組み立てる。
  # **出力は redact 済みだが、投稿前に人間が読むことを前提としている**（skills/feedback が承認を取る）。
  local key=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --key) _require_opt_value render-upstream "$1" "$#" || return 2; key="$2"; shift 2 ;;
      *)
        echo "ERROR: render-upstream: 不明な引数: $1" >&2
        return 2
        ;;
    esac
  done

  if [ -z "$key" ]; then
    echo "ERROR: render-upstream: --key は必須です" >&2
    return 2
  fi

  local file
  file="$(_ledger_file)" || {
    echo "ERROR: render-upstream: 台帳の置き場所を解決できませんでした" >&2
    return 2
  }
  if [ ! -f "$file" ]; then
    echo "ERROR: render-upstream: 台帳がまだありません: ${file}" >&2
    return 1
  fi

  local n=0 first="" last="" sev="low" category="" latest_summary="" rows=""
  local ts rec_cat rec_key severity epic summary evidence
  while IFS=$'\t' read -r ts _ rec_cat rec_key severity epic summary evidence; do
    _is_digits "$ts" || continue
    if [ "$rec_key" != "$key" ]; then
      continue
    fi
    n=$((n + 1))
    if [ -z "$first" ]; then
      first="$ts"
    fi
    last="$ts"
    category="$rec_cat"
    latest_summary="$summary"
    case "${severity}:${sev}" in
      high:*) sev="high" ;;
      medium:low) sev="medium" ;;
    esac
    rows+="| $(_iso_utc "$ts") | ${epic} | ${summary} | ${evidence} |"$'\n'
  done < "$file"

  if [ "$n" -eq 0 ]; then
    echo "ERROR: render-upstream: key=${key} の観測が台帳にありません" >&2
    return 1
  fi

  {
    echo "## 概要"
    echo ""
    echo "${latest_summary}"
    echo ""
    echo "## 再現状況"
    echo ""
    echo "- 観測回数: ${n} 回"
    echo "- 初回: $(_iso_utc "$first")"
    echo "- 直近: $(_iso_utc "$last")"
    echo "- 深刻度: ${sev}"
    echo "- 分類: ${category}"
    echo "- キー: \`${key}\`"
    echo ""
    echo "## 観測ログ"
    echo ""
    echo "| 日時(UTC) | Epic | 要約 | 根拠 |"
    echo "|---|---|---|---|"
    printf '%s' "$rows"
    echo ""
    echo "## 環境"
    echo ""
    echo "- dev-workflow: $(_plugin_version)"
    echo "- OSTYPE: ${OSTYPE:-unknown}"
    echo ""
    echo "---"
    echo ""
    echo "このissueは \`/dev-workflow:feedback\` が生成した還流レポートです。"
    echo "駆動先プロジェクト固有の情報は伏字化しており、投稿前に人間が内容を確認しています。"
  } | _redact

  return 0
}

cmd_upstream_repo() {
  # 還流先（`gh issue create --repo` に渡す owner/repo）を決める。
  # **プラグインのマニフェストから引く**ので、fork して配布された環境ではその fork が還流先になる。
  # 環境変数で明示された場合はそれを最優先する（社内ミラーへ還流させたい場合など）。
  if [ -n "${DEV_WORKFLOW_UPSTREAM_REPO:-}" ]; then
    printf '%s\n' "$DEV_WORKFLOW_UPSTREAM_REPO"
    return 0
  fi

  local manifest line url
  manifest="${SCRIPT_DIR}/../.claude-plugin/plugin.json"
  if [ ! -f "$manifest" ]; then
    echo "ERROR: upstream-repo: プラグインのマニフェストが見つかりません: ${manifest}" >&2
    return 1
  fi

  line="$(grep -oE '"repository"[[:space:]]*:[[:space:]]*"[^"]+"' "$manifest" 2>/dev/null | head -1)"
  line="${line%\"}"
  url="${line##*\"}"
  if [ -z "$url" ]; then
    echo "ERROR: upstream-repo: マニフェストに repository がありません" >&2
    return 1
  fi

  # https://github.com/owner/repo(.git) -> owner/repo
  url="${url%.git}"
  url="${url#https://github.com/}"
  url="${url#git@github.com:}"
  case "$url" in
    */*) printf '%s\n' "$url" ;;
    *)
      echo "ERROR: upstream-repo: owner/repo を取り出せませんでした: ${url}" >&2
      return 1
      ;;
  esac
  return 0
}

cmd_path() {
  local dir
  dir="$(_feedback_dir)" || {
    echo "ERROR: path: 台帳の置き場所を解決できませんでした（HOME 未設定か git 管理外）" >&2
    return 2
  }
  printf '%s\n' "$dir"
  return 0
}

# ---------------------------------------------------------------------------
# エントリポイント
# ---------------------------------------------------------------------------

if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

case "$1" in
  record)          shift; cmd_record "$@"; exit $? ;;
  list)            shift; cmd_list "$@"; exit $? ;;
  count)           shift; cmd_count "$@"; exit $? ;;
  ready)           shift; cmd_ready "$@"; exit $? ;;
  render-upstream) shift; cmd_render_upstream "$@"; exit $? ;;
  redact)          shift; _redact; exit $? ;;
  upstream-repo)   shift; cmd_upstream_repo "$@"; exit $? ;;
  path)            shift; cmd_path "$@"; exit $? ;;
  -h|--help)       usage; exit 0 ;;
  *)
    echo "ERROR: 不明なサブコマンド: $1" >&2
    usage >&2
    exit 2
    ;;
esac
