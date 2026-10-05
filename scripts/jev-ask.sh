#!/bin/bash
# dev-workflow: Jev（TypeSafe AI の System One Model）へ型付きの判断だけを問い合わせる薄い
# クライアント。
#
# 背景（issue #244）: ハーネス内には「選択肢が有限で、局所的な文脈で閉じ、間違えても成果物が
# 壊れない」判断点がいくつかある（指摘の重複排除・feedback 台帳の分類・確度判定のトリアージ）。
# これらを文章生成モデルで判断させると、親エージェントの読解コンテキストを丸ごと消費する。
# Jev は文章を生成せず Choice / Score / Noul の3型だけを返すため、この用途に限って置き換えられる。
#
# **任意依存である。** context7 / code-review-graph / LSP と同格で、未導入（JEV_API_KEY 未設定）
# でもハーネスは従来どおり動作する（フォールバック＝従来の LLM 判断）。
# 詳細は docs/optional-mcp-tools.md「Jev（System One Model）」節を参照。
#
# **追加の依存物（jq 等）は一切使わない。** curl と素の bash で完結する
# （scripts/record-agent-tokens.sh・scripts/feedback-ledger.sh と同じ作法）。
#
# API 仕様（上流で確認した値。2026-10 時点）:
#   POST ${JEV_API_URL}  Authorization: Bearer ${JEV_API_KEY}
#   既定 https://api.typesafe.ai/v1/systemone（公式。docs.typesafe.ai / console.typesafe.ai）
#   リクエスト: {"model": "...", "state": <文字列|オブジェクト>, "questions": {"<名前>": {...}}}
#     questions[].type         … noul | choice | score
#     questions[].instructions … 判定の指示（最大 1,800 文字）
#     questions[].criteria     … choice: {"キー":"説明"}（2〜20個） /
#                                score:  ["段1","段2",...]（2〜10段、順序付き配列） /
#                                noul:   {"true":"ラベル","false":"ラベル"}（省略可）
#   state はテキストのみ（文字列 / JSON オブジェクト / テキスト配列）。context 予算は1リクエスト
#   64k トークン、うち `state` + 最長の question で 32k トークンまで。1リクエストに複数の
#   question を並べて同時に答えさせられる。
#   レスポンス: {"model": "jev-1.13.0", "answers": {"<名前>": {"type": ..., "choice": ...,
#               "probabilities": {...}, "confidence": ..., "noul": ..., "score": ...,
#               "legend": {...}}}, "usage": {"input_tokens": N, "output_tokens": N}}
#
#   **型ごとに返るフィールドが違う（公式 docs.typesafe.ai/api の実例で確認した値）:**
#     noul   … `noul` のみ。**`confidence` は返らない**（noul 自身が校正済み確率なので不要）
#     choice … `choice` / `probabilities` / `confidence`
#     score  … `score` / `probabilities` / `confidence` / **`legend`**（段番号→段ラベルの対応）
#   `probabilities` と `legend` は入れ子オブジェクトなので、answer は抽出前に両方を取り除く。
#   出力トークンは無料。課金は入力トークンのみ。
#
# 使い方:
#   jev-ask.sh available
#     Jev が使える状態か（JEV_API_KEY が設定され curl がある）を判定する。使えるなら 0。
#     使えない理由は標準エラーへ1行出す。呼び出し側はこれが非0でも止まらず従来経路へ倒すこと。
#
#   jev-ask.sh ask --request-file <JSONファイル>
#     リクエスト JSON をそのまま POST し、レスポンス JSON を標準出力へ出す。
#
#   jev-ask.sh answer --response-file <f> --question <名前> [--field <auto|noul|choice|score|confidence>]
#     レスポンスから1つの値を取り出して標準出力へ出す（--field auto は type に応じて
#     noul / choice / score のいずれかを返す）。
#
#   jev-ask.sh json-escape
#     標準入力を JSON 文字列の中身として安全な形へエスケープして標準出力へ出す
#     （前後のダブルクォートは付けない）。日本語はそのまま通す。
#
# 環境変数:
#   JEV_API_KEY                   APIキー（console.typesafe.ai/keys で発行。`sk-` 始まり）。
#                                 未設定なら Jev は未導入として扱う（エラーにしない）。
#                                 未設定のときは TYPESAFE_API_KEY → 鍵ファイル（下記）の順で読む
#   TYPESAFE_API_KEY              上流公式のドキュメントが使う名前。JEV_API_KEY が無いときに使う
#   DEV_WORKFLOW_JEV_ENV_FILE     鍵ファイルのパスを上書きする
#                                 （既定: ${HOME}/.claude/dev-workflow/jev.env。`JEV_API_KEY=...` の1行）
#   JEV_API_URL                   エンドポイント（既定: https://api.typesafe.ai/v1/systemone）
#   JEV_MODEL                     モデル名（既定: jev-latest）
#   DEV_WORKFLOW_JEV_TIMEOUT      1リクエストのタイムアウト秒（既定: 20）
#   DEV_WORKFLOW_JEV_DISABLE      1 を設定すると available が常に非0になる（切り戻し用）
#
# 終了コード:
#   0 = 成功 / available が「使える」
#   1 = available が「使えない」（未導入・無効化）。異常ではない
#   2 = 引数エラー
#   3 = API 呼び出しの失敗（ネットワーク・非2xx・応答不正）。呼び出し側は従来経路へ倒すこと
#   4 = answer で指定した question / field が応答に無い
#
# APIキーを標準出力・標準エラー・ログへ出さない（README「安全ルール」）。curl へは --config で
# ファイル経由に渡し、引数列（ps から見える）に載せない。エラー時に出すのは HTTP ステータスと
# 応答本文だけに限る。

set -u

JEV_API_URL_DEFAULT='https://api.typesafe.ai/v1/systemone'
JEV_MODEL_DEFAULT='jev-latest'
JEV_TIMEOUT_DEFAULT=20

# 鍵ファイルからの読み込み（環境変数が未設定のときだけ）。
#
# ハーネス非注入原則の置き場所（${HOME}/.claude/dev-workflow/ 配下。sandbox 定義・feedback 台帳と
# 同じ流儀）に鍵を置けるようにする。**駆動先リポジトリには絶対に置かない。**
# 環境変数のほうが優先される（CI では env で渡す）。
#
# 形式は `JEV_API_KEY=...`（または上流公式の名前 `TYPESAFE_API_KEY=...`）の1行だけ。
# `source` せず自前で読む（鍵ファイルに任意のシェルコードを書けてしまう経路を作らないため）。
_load_key_file() {
  local f="${DEV_WORKFLOW_JEV_ENV_FILE:-}"
  if [ -z "$f" ] && [ -n "${HOME:-}" ]; then
    f="${HOME}/.claude/dev-workflow/jev.env"
  fi
  [ -n "$f" ] && [ -f "$f" ] || return 0

  local line value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      JEV_API_KEY=*|TYPESAFE_API_KEY=*)
        value="${line#*=}"
        # 前後の引用符と空白を落とす
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        value="${value%"${value##*[![:space:]]}"}"
        [ -n "$value" ] && JEV_API_KEY="$value"
        ;;
    esac
  done < "$f"
  return 0
}

# 環境変数 → 上流公式の名前 → 鍵ファイルの順で解決する。
[ -n "${JEV_API_KEY:-}" ] || JEV_API_KEY="${TYPESAFE_API_KEY:-}"
[ -n "${JEV_API_KEY:-}" ] || _load_key_file

usage() {
  sed -n '/^# 使い方:/,/^# 終了コード:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

_api_url() { printf '%s' "${JEV_API_URL:-$JEV_API_URL_DEFAULT}"; }

# model はリクエスト JSON の組み立て側（呼び出し元・jev-shadow-eval.sh）が使う。
_model() { printf '%s' "${JEV_MODEL:-$JEV_MODEL_DEFAULT}"; }

_timeout() {
  local t="${DEV_WORKFLOW_JEV_TIMEOUT:-$JEV_TIMEOUT_DEFAULT}"
  case "$t" in
    ''|*[!0-9]*) printf '%s' "$JEV_TIMEOUT_DEFAULT"; return 0 ;;
  esac
  if [ "$t" -lt 1 ]; then printf '%s' "$JEV_TIMEOUT_DEFAULT"; else printf '%s' "$t"; fi
}

# ---------------------------------------------------------------------------
# available
# ---------------------------------------------------------------------------

cmd_available() {
  if [ "${DEV_WORKFLOW_JEV_DISABLE:-0}" = "1" ]; then
    echo "[jev] DEV_WORKFLOW_JEV_DISABLE=1 のため無効化されています（従来経路で動作します）" >&2
    return 1
  fi
  if [ -z "${JEV_API_KEY:-}" ]; then
    echo "[jev] JEV_API_KEY が未設定です（任意依存。未導入でも従来どおり動作します）" >&2
    return 1
  fi
  if ! command -v curl > /dev/null 2>&1; then
    echo "[jev] curl が見つかりません（従来経路で動作します）" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# ask
# ---------------------------------------------------------------------------

cmd_ask() {
  local request_file=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --request-file)
        [ $# -ge 2 ] || { echo "エラー: --request-file に値がありません" >&2; return 2; }
        request_file="$2"; shift 2 ;;
      *) echo "エラー: 不明なオプション: $1" >&2; return 2 ;;
    esac
  done
  [ -n "$request_file" ] || { echo "エラー: --request-file は必須です" >&2; return 2; }
  [ -f "$request_file" ] || { echo "エラー: リクエストファイルがありません: $request_file" >&2; return 2; }

  cmd_available || return 3

  local body_file conf_file status
  body_file="$(mktemp)" || { echo "エラー: 一時ファイルを作れません" >&2; return 3; }
  conf_file="$(mktemp)" || { rm -f "$body_file"; echo "エラー: 一時ファイルを作れません" >&2; return 3; }
  printf 'header = "Authorization: Bearer %s"\n' "$JEV_API_KEY" > "$conf_file"

  status="$(curl --silent --show-error \
    --config "$conf_file" \
    --header 'Content-Type: application/json' \
    --max-time "$(_timeout)" \
    --output "$body_file" \
    --write-out '%{http_code}' \
    --data-binary "@${request_file}" \
    "$(_api_url)" 2>&1)" || {
      # curl 自体の失敗（ネットワーク・タイムアウト）。$status に curl のメッセージが入る。
      rm -f "$conf_file" "$body_file"
      echo "[jev] API 呼び出しに失敗しました: ${status}" >&2
      return 3
    }
  rm -f "$conf_file"

  case "$status" in
    2*)
      cat "$body_file"
      rm -f "$body_file"
      return 0
      ;;
    *)
      echo "[jev] API が HTTP ${status} を返しました: $(tr -d '\n' < "$body_file" | cut -c1-500)" >&2
      rm -f "$body_file"
      return 3
      ;;
  esac
}

# ---------------------------------------------------------------------------
# answer（応答から1つの値を取り出す）
# ---------------------------------------------------------------------------

# 応答 JSON を1行へ潰し、値の抽出を邪魔する入れ子を取り除く。
# 残る question ブロックは入れ子を持たないフラットなオブジェクトになるため、
# "名前": { ... } のスライスが成立する。
#
# **取り除く入れ子はキー名で明示的に列挙する。** 「ブレースを含まない入れ子をすべて消す」
# という汎用パターンにすると、入れ子を取り除いた後の question ブロック自身
# （`"same_finding": {"type": "noul", "noul": 0.12}`）も同じ形になるため、question ごと
# 消してしまう。上流が新しい入れ子フィールドを足したらこの列挙に追加する。
#
# `legend`（score の段番号→段ラベル）を見落とすと、その後ろにある `confidence` が
# スライスの外に出て読めなくなる（公式 docs.typesafe.ai/api の応答例で確認した）。
_flatten_response() {
  tr '\n\t' '  ' \
    | sed -E 's/"probabilities"[[:space:]]*:[[:space:]]*\{[^}]*\}[[:space:]]*,?//g' \
    | sed -E 's/"legend"[[:space:]]*:[[:space:]]*\{[^}]*\}[[:space:]]*,?//g'
}

cmd_answer() {
  local response_file='' question='' field='auto'
  while [ $# -gt 0 ]; do
    case "$1" in
      --response-file)
        [ $# -ge 2 ] || { echo "エラー: --response-file に値がありません" >&2; return 2; }
        response_file="$2"; shift 2 ;;
      --question)
        [ $# -ge 2 ] || { echo "エラー: --question に値がありません" >&2; return 2; }
        question="$2"; shift 2 ;;
      --field)
        [ $# -ge 2 ] || { echo "エラー: --field に値がありません" >&2; return 2; }
        field="$2"; shift 2 ;;
      *) echo "エラー: 不明なオプション: $1" >&2; return 2 ;;
    esac
  done
  [ -n "$response_file" ] || { echo "エラー: --response-file は必須です" >&2; return 2; }
  [ -f "$response_file" ] || { echo "エラー: 応答ファイルがありません: $response_file" >&2; return 2; }
  # question 名は小文字英数字とハイフン・アンダースコアだけに限る。任意文字を許すと
  # 下の sed のパターンに正規表現メタ文字が混ざって抽出が壊れる。
  case "$question" in
    ''|*[!a-z0-9_-]*)
      echo "エラー: --question は小文字英数字・ハイフン・アンダースコアのみ: ${question}" >&2
      return 2 ;;
  esac
  case "$field" in
    auto|noul|choice|score|confidence) ;;
    *) echo "エラー: --field は auto|noul|choice|score|confidence のいずれか: ${field}" >&2; return 2 ;;
  esac

  local block
  block="$(_flatten_response < "$response_file" \
    | sed -n "s/.*\"${question}\"[[:space:]]*:[[:space:]]*{\\([^}]*\\)}.*/\\1/p")"
  [ -n "$block" ] || { echo "[jev] 応答に question がありません: ${question}" >&2; return 4; }

  local target="$field"
  if [ "$field" = "auto" ]; then
    local qtype
    qtype="$(printf '%s' "$block" | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')"
    case "$qtype" in
      noul|choice|score) target="$qtype" ;;
      *) echo "[jev] 応答の type を読み取れません: ${question}" >&2; return 4 ;;
    esac
  fi

  local value
  # 文字列値（choice）と数値（noul / score / confidence）の両方に当てる。
  value="$(printf '%s' "$block" \
    | sed -n "s/.*\"${target}\"[[:space:]]*:[[:space:]]*\"\\{0,1\\}\\([^\",}]*\\)\"\\{0,1\\}.*/\\1/p" \
    | sed -E 's/[[:space:]]+$//')"
  [ -n "$value" ] || { echo "[jev] 応答に field がありません: ${question}.${target}" >&2; return 4; }
  printf '%s\n' "$value"
}

# ---------------------------------------------------------------------------
# json-escape（日本語はそのまま通し、JSON を壊す文字だけを逃がす）
# ---------------------------------------------------------------------------

cmd_json_escape() {
  # 順序が重要: バックスラッシュを先に二重化しないと、後で入れた \" がさらに壊れる。
  # タブ・復帰はエスケープ列へ、その他の制御文字は空白へ潰す（JSON は生の制御文字を許さない）。
  # 最後に改行を \n へ畳む。
  sed -e 's/\\/\\\\/g' \
      -e 's/"/\\"/g' \
      -e 's/\t/\\t/g' \
      -e 's/\r/\\r/g' \
    | tr -d '\001-\010\013\014\016-\037' \
    | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'
}

# ---------------------------------------------------------------------------

[ $# -ge 1 ] || { usage >&2; exit 2; }
subcommand="$1"
shift

case "$subcommand" in
  available)   cmd_available ;;
  ask)         cmd_ask "$@" ;;
  answer)      cmd_answer "$@" ;;
  json-escape) cmd_json_escape ;;
  model)       _model ;;
  -h|--help)   usage ;;
  *)           echo "エラー: 不明なサブコマンド: ${subcommand}" >&2; usage >&2; exit 2 ;;
esac
