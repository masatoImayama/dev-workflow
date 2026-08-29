#!/bin/bash
# dev-workflow: テスト出力の SKIP 件数を機械的に数える（ベンダー中立）
#
# `skills/run/SKILL.md` は「SKIP されたテストがあれば件数と内容を報告に含めること」とだけ
# 指示し、数え方を示していなかった。結果、`tail` で目視して `--- SKIP` が見えなかったことを
# もって「SKIP 0件」と報告される事故が起きた（`docs/dev-workflow-handover.md` H5節）。
# 「`ok` の有無だけで判定してはならない」という方針を自然言語の依頼のままにせず、
# ここに切り出して固定する。Docker には一切触れない純粋な文字列処理であり、
# tests/run-tests.sh に固定入力で載せられる。
#
# 呼び出し側の差し替え（SKILL.md / generator.md）は #97 で行う。ここではスクリプトと
# その単体テストの追加のみを行う。
#
# 使い方:
#   bash scripts/count-skips.sh [--file <テスト出力のログ>] [--pattern <ERE>] [--runner <go|jest|pytest>]
#   <テスト出力> | bash scripts/count-skips.sh
#   bash scripts/count-skips.sh --help
#
# --file: テスト出力を保存したログファイル。標準入力と両方指定された場合は --file を優先する。
# --pattern: SKIP行を数えるERE（拡張正規表現）。指定されると runner 判定より優先し、
#            一致した行数をそのまま件数とする。環境変数 DEV_WORKFLOW_SKIP_PATTERN でも
#            同様に指定できる（--pattern が両方指定時は優先）。
# --runner: 自動判定を行わず、指定したランナーのSKIP抽出ロジックを強制する（go|jest|pytest）。
#           自動判定が誤検出したとき（#142）に呼び出し側から矯正する手段。--pattern と
#           併用された場合は --pattern を優先する（--pattern の方がより具体的な指定のため）。
# --help: 使い方を表示して終了する（exit 0）。
#
# 出力（1行1項目・機械可読、この順で必ず3行）:
#   skips=<件数 または unknown>
#   runner=<go|pytest|jest|custom|unknown>
#   pattern=<実際に使ったERE または none>
#
# 終了コード:
#   0 = 数えられた
#   1 = 数えられなかった（skips=unknown。認識できない形式を fail loud で報告する）
#   2 = 引数エラー
#
# 判定順序（上から最初に一致したものを使う。ランナーを先に判定してから数えることが
# この設計の核心。そうしないと「SKIP が1件も無い」（skips=0・exit 0）と
# 「形式を認識できない」（skips=unknown・exit 1）を区別できない）:
#
#   1. --pattern または DEV_WORKFLOW_SKIP_PATTERN があれば runner=custom として
#      そのEREに一致する行数を数える
#   2. --runner が指定されていれば、そのランナーの抽出ロジックを自動判定なしで使う
#   3. jest と判定できる（`^Test Suites:` / `^Tests:` / `^Snapshots:` のいずれかを含む）
#      → `Tests:` 行の `<N> skipped` の N
#   4. pytest と判定できる（`test session starts` を含む）→ サマリ行の最後の `<N> skipped` の N
#   5. Go と判定できる（`^--- (PASS|FAIL|SKIP)` または `^(ok|FAIL|PASS)` のいずれかを含む）
#      → `^--- SKIP` の一致行数
#   6. どれにも当てはまらない → skips=unknown / runner=unknown / exit 1
#
# なぜ jest を Go より先に判定するか（#142）:
#   jest はテストファイルごとに `PASS <file>` / `FAIL <file>` という行を出力する。この行は
#   Go判定の `^(ok|FAIL|PASS)`（`go test -v` 末尾の裸の `PASS` / `FAIL` サマリ行を拾うための
#   条件）と字面が衝突し、Go判定を先に行うと jest のログが `runner=go` に誤判定され、
#   `^--- SKIP` が1件も無いために `skips=0`（exit 0）という「最も危険な誤り」が返っていた
#   （実SKIP件数が1件あっても検出できず正常扱いになる）。jest 固有の `Test Suites:` /
#   `Tests:` / `Snapshots:` はGoのログに現れないため、これを先に見ることで誤判定を避ける。
#
# 追加の依存物（jq 等）は要求しない。素の bash / grep / sed のみで完結させる。

set -u

usage() {
  cat <<'USAGE'
使い方:
  bash scripts/count-skips.sh [--file <テスト出力のログ>] [--pattern <ERE>] [--runner <go|jest|pytest>]
  <テスト出力> | bash scripts/count-skips.sh
  bash scripts/count-skips.sh --help

オプション:
  --file <path>       テスト出力を保存したログファイル（標準入力より優先）
  --pattern <ERE>     SKIP行を数える拡張正規表現（runner判定より優先。runner=custom）
  --runner <runner>   自動判定を行わず go|jest|pytest のいずれかを強制する
  --help              このヘルプを表示して終了する（exit 0）

出力（この順で必ず3行）:
  skips=<件数 または unknown>
  runner=<go|pytest|jest|custom|unknown>
  pattern=<実際に使ったERE または none>

終了コード:
  0 = 数えられた
  1 = 数えられなかった（skips=unknown）
  2 = 引数エラー
USAGE
}

FILE=""
PATTERN=""
RUNNER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help)
      usage
      exit 0 ;;
    --file)
      if [ $# -lt 2 ]; then
        echo "ERROR: --file には値が必要です" >&2
        exit 2
      fi
      FILE="$2"; shift 2 ;;
    --pattern)
      if [ $# -lt 2 ]; then
        echo "ERROR: --pattern には値が必要です" >&2
        exit 2
      fi
      PATTERN="$2"; shift 2 ;;
    --runner)
      if [ $# -lt 2 ]; then
        echo "ERROR: --runner には値が必要です" >&2
        exit 2
      fi
      RUNNER="$2"; shift 2
      case "$RUNNER" in
        go|jest|pytest) ;;
        *) echo "ERROR: --runner は go|jest|pytest のいずれかを指定してください（渡された値: ${RUNNER}）" >&2
           exit 2 ;;
      esac
      ;;
    -*) echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
    *)  echo "ERROR: 未知の引数: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$FILE" ]; then
  if [ ! -f "$FILE" ]; then
    echo "ERROR: --file で指定されたファイルが見つかりません: ${FILE}" >&2
    exit 2
  fi
  INPUT="$(cat -- "$FILE")"
else
  INPUT="$(cat)"
fi

# ---------------------------------------------------------------------------
# 1. --pattern / DEV_WORKFLOW_SKIP_PATTERN（最優先）
# ---------------------------------------------------------------------------

EFFECTIVE_PATTERN="${PATTERN:-${DEV_WORKFLOW_SKIP_PATTERN:-}}"

if [ -n "$EFFECTIVE_PATTERN" ]; then
  COUNT="$(printf '%s\n' "$INPUT" | grep -cE -- "$EFFECTIVE_PATTERN")"
  GREP_STATUS=$?
  # grep -c の終了コード: 0=一致あり, 1=一致なし（COUNT=0として正常扱い）,
  # 2=正規表現エラー等。2以上は「数えられなかった」として skips=unknown / exit 1 にする。
  # ここで判定せずそのまま出力すると、不正なEREでも skips= が空値のまま exit 0 になり、
  # SKIP検証が空振りしたまま緑に見えてしまう（#101）。
  if [ "$GREP_STATUS" -ge 2 ]; then
    echo "skips=unknown"
    echo "runner=custom"
    echo "pattern=${EFFECTIVE_PATTERN}"
    exit 1
  fi
  echo "skips=${COUNT}"
  echo "runner=custom"
  echo "pattern=${EFFECTIVE_PATTERN}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. --runner（自動判定なしで強制する。#142）
# ---------------------------------------------------------------------------

if [ -n "$RUNNER" ]; then
  case "$RUNNER" in
    go)
      COUNT="$(printf '%s\n' "$INPUT" | grep -cE -- '^--- SKIP')"
      echo "skips=${COUNT}"
      echo "runner=go"
      echo "pattern=none"
      exit 0
      ;;
    jest)
      COUNT="$(printf '%s\n' "$INPUT" | grep -E -- '^Tests:' | tail -1 \
        | grep -oE -- '[0-9]+ skipped' | grep -oE -- '[0-9]+')"
      COUNT="${COUNT:-0}"
      echo "skips=${COUNT}"
      echo "runner=jest"
      echo "pattern=none"
      exit 0
      ;;
    pytest)
      COUNT="$(printf '%s\n' "$INPUT" | grep -oE -- '[0-9]+ skipped' | tail -1 \
        | grep -oE -- '[0-9]+')"
      COUNT="${COUNT:-0}"
      echo "skips=${COUNT}"
      echo "runner=pytest"
      echo "pattern=none"
      exit 0
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 3. jest（`Test Suites:` / `Tests:` / `Snapshots:` のいずれかを含む形式）
#
# Go判定より先に見る（#142）。jest の `PASS <file>` / `FAIL <file>` 行が
# Go判定の `^(ok|FAIL|PASS)` と字面衝突し、Go判定を先に行うと
# 「実SKIPがあるのにskips=0」という最も危険な誤りになるため。
# ---------------------------------------------------------------------------

if printf '%s\n' "$INPUT" | grep -Eq -- '^(Test Suites:|Tests:|Snapshots:)'; then
  COUNT="$(printf '%s\n' "$INPUT" | grep -E -- '^Tests:' | tail -1 \
    | grep -oE -- '[0-9]+ skipped' | grep -oE -- '[0-9]+')"
  COUNT="${COUNT:-0}"
  echo "skips=${COUNT}"
  echo "runner=jest"
  echo "pattern=none"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. pytest（`= test session starts =` とサマリ行 `<N> skipped` 形式）
# ---------------------------------------------------------------------------

if printf '%s\n' "$INPUT" | grep -Fq -- 'test session starts'; then
  COUNT="$(printf '%s\n' "$INPUT" | grep -oE -- '[0-9]+ skipped' | tail -1 \
    | grep -oE -- '[0-9]+')"
  COUNT="${COUNT:-0}"
  echo "skips=${COUNT}"
  echo "runner=pytest"
  echo "pattern=none"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Go（`go test` の `--- SKIP` 形式）
# ---------------------------------------------------------------------------

if printf '%s\n' "$INPUT" | grep -Eq -- '^--- (PASS|FAIL|SKIP)' \
  || printf '%s\n' "$INPUT" | grep -Eq -- '^(ok|FAIL|PASS)'; then
  COUNT="$(printf '%s\n' "$INPUT" | grep -cE -- '^--- SKIP')"
  echo "skips=${COUNT}"
  echo "runner=go"
  echo "pattern=none"
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. どれにも当てはまらない → fail loud（黙って0件と報告しない）
# ---------------------------------------------------------------------------

echo "skips=unknown"
echo "runner=unknown"
echo "pattern=none"
exit 1
