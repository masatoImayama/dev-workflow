#!/bin/bash
# dev-workflow: 環境診断を1コマンドにまとめる（Task #218）
#
# 環境の状態を知る手段が次のように分散していた:
#   - 必須依存（gh/docker）と gh 認証         -> scripts/check-prerequisites.sh（hook 経由前提）
#   - サンドボックスの解決結果                -> scripts/sandbox-exec.sh --print-plan（別コマンド）
#   - 任意 MCP ツールの導入手順               -> docs/optional-mcp-tools.md（診断結果と繋がっていない）
#
# 本スクリプトはこれらをまとめて表示する、利用者が任意のタイミングで叩く診断コマンドである。
#
# 使い方:
#   bash scripts/doctor.sh
#
# 終了コード:
#   0 = 必須依存（gh/docker とその認証・起動状態）が揃っている
#       （任意依存の未導入・リポジトリ衛生の警告・CRLF警告があっても 0）
#   1 = 必須依存のいずれかが不足している
#
# 副作用は一切無い（ファイルを作らない・何もインストールしない・何も書き換えない）。
# 導入コマンドを"表示"するだけで、このスクリプト自身は実行しない。
#
# 必須依存が不足していても、最後まで走り切ってから終了コードで判定する
# （最初の不足で止まると全体像が見えず、目的を果たさない）。
#
# shellcheck disable=SC2317
# ↑ ファイル全体に対する指定（ファイル冒頭・コード開始前のみ有効な書式）。
# check-prerequisites.sh は「`BASH_SOURCE[0]` と `$0` が一致する場合（直接実行時）
# のみ本体を実行し、source されただけなら即 return する」作りだが、shellcheck -x は
# その実行時条件を評価できず、sourced 側末尾の無条件 `exit 0` にそのまま到達すると
# みなして、source 文以降の doctor.sh 側コード全てを「到達不能」(SC2317) と誤検知する。
# 実際には該当の `exit` へは到達しない（このファイルの動作確認は tests/run-tests.sh の
# scripts/doctor.sh セクションで行う）。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# crlf_warning_message は check-prerequisites.sh から source して再利用する
# （判定ロジックを二重実装しない。#218）。check-prerequisites.sh は
# `BASH_SOURCE[0]` と `$0` が一致する場合（直接実行時）のみ本体の前提条件チェックを
# 実行する作りになっているため、source しただけでは副作用（gh auth setup-git 等）は
# 一切起きない。
# shellcheck source=./check-prerequisites.sh
source "${SCRIPT_DIR}/check-prerequisites.sh"

REQUIRED_MISSING=0

echo "=== 必須依存 ==="

if command -v gh >/dev/null 2>&1; then
  echo "[OK] gh: $(command -v gh)"
  if gh auth status >/dev/null 2>&1; then
    echo "[OK] gh auth status: 認証済み"
  else
    echo "[NG] gh auth status: 未認証です。'gh auth login' を実行してください。"
    REQUIRED_MISSING=1
  fi
else
  echo "[NG] gh: 見つかりません。https://cli.github.com/ からインストールしてください。"
  REQUIRED_MISSING=1
fi

if command -v docker >/dev/null 2>&1; then
  echo "[OK] docker: $(command -v docker)"
  if docker info >/dev/null 2>&1; then
    echo "[OK] docker info: デーモンが起動しています"
  else
    echo "[NG] docker info: Docker デーモンが起動していません。Docker Desktop を起動してください。"
    REQUIRED_MISSING=1
  fi
else
  echo "[NG] docker: 見つかりません。https://docs.docker.com/get-docker/ からインストールしてください。"
  REQUIRED_MISSING=1
fi

echo
echo "=== 任意依存（未導入でも dev-workflow は従来どおり動作します。異常ではありません） ==="

# パッケージ名・導入コマンドの出典: docs/optional-mcp-tools.md
# 「## 対象ツール」節・「## 申し送りに対してどう応えたか（#80 レビュー対応）」節。
# ここではハードコードして表示するが、正本は docs/optional-mcp-tools.md であり、
# 齟齬が出た場合はこのスクリプトではなく docs/optional-mcp-tools.md 側を直すこと。
#
# code-review-graph の導入コマンドは環境（pip/pip3/pipx/uvx のいずれが入っているか）に
# よって変わるため、ここでは特定のコマンドをハードコードしない（#233）。代わりに、
# 実行時に前提を検出して正しいコマンドを組み立てる scripts/install-optional-mcp.sh の
# 実行を案内する。この性質（利用者に貼り付けさせる導入コマンドは、その環境で実際に
# 実行可能なものであること）は #234 でも問題になった。
CONTEXT7_PACKAGE="@upstash/context7-mcp"
CONTEXT7_INSTALL_CMD="npm install -g @upstash/context7-mcp"
CODE_REVIEW_GRAPH_PACKAGE="code-review-graph"
CODE_REVIEW_GRAPH_INSTALL_CMD="bash scripts/install-optional-mcp.sh --apply --only code-review-graph"

if command -v context7-mcp >/dev/null 2>&1; then
  echo "[OK] context7 (${CONTEXT7_PACKAGE}): 導入済み ($(command -v context7-mcp))"
else
  echo "[任意・未導入] context7 (${CONTEXT7_PACKAGE})"
  echo "  未導入でも generator は従来どおり動作します（未知のライブラリの確認は"
  echo "  リポジトリ内の既存利用箇所・公式ドキュメントで行います）。"
  echo "  導入する場合: ${CONTEXT7_INSTALL_CMD}"
  echo "  詳細: docs/optional-mcp-tools.md"
fi

if command -v code-review-graph >/dev/null 2>&1; then
  echo "[OK] code-review-graph (${CODE_REVIEW_GRAPH_PACKAGE}): 導入済み ($(command -v code-review-graph))"
else
  echo "[任意・未導入] code-review-graph (${CODE_REVIEW_GRAPH_PACKAGE})"
  echo "  未導入でも evaluator は従来どおり動作します（blast radius 算出を使わず"
  echo "  Phase 単位に分割してレビューします）。"
  echo "  導入する場合: ${CODE_REVIEW_GRAPH_INSTALL_CMD}"
  echo "  詳細: docs/optional-mcp-tools.md"
fi

# Jev は MCP サーバーではなく HTTP API なので command -v では判定できない。
# 鍵の有無で判定する（scripts/jev-ask.sh available）。
# **毎 run の非ブロッキング通知（check-prerequisites.sh）には出さない。** 課金のある
# hosted API であり、使う予定の無い利用者に毎回通知するのは雑音になるため、
# 利用者が意図して叩く doctor にだけ出す。
if bash "${SCRIPT_DIR}/jev-ask.sh" available 2>/dev/null; then
  echo "[OK] Jev (System One Model): 鍵あり（指摘の重複排除・feedback 分類で使われます）"
  echo "  確度判定のトリアージは結線していません（計測で削減効果 0%。ADR-0012 決定C）"
else
  echo "[任意・未導入] Jev (System One Model)"
  echo "  未導入でも run / feedback は従来どおり動作します（指摘の重複排除・台帳の分類は"
  echo "  実行者自身が判断します）。"
  echo "  導入する場合: JEV_API_KEY を環境変数か \${HOME}/.claude/dev-workflow/jev.env に置く"
  echo "  詳細: docs/optional-mcp-tools.md「Jev（System One Model）」"
fi

echo
echo "=== 応答言語（scripts/resolve-lang.sh） ==="
# 解決ロジックは resolve-lang.sh の単一の正本を呼ぶだけで、ここでは二重実装しない
# （Epic #246。許容リスト判定・不正値のフォールバックは resolve-lang.sh 側に閉じる）。
# resolve-lang.sh は常に exit 0 を返す契約であり、不正値（source=fallback）であっても
# REQUIRED_MISSING には影響させない（「記録して進む」観測項目であり、診断全体を
# 失敗扱いにしてはならない）。
RESOLVE_LANG_OUT="$(bash "${SCRIPT_DIR}/resolve-lang.sh")"
RESOLVE_LANG_VALUE="$(printf '%s\n' "$RESOLVE_LANG_OUT" | sed -n 's/^lang=//p')"
RESOLVE_LANG_SOURCE="$(printf '%s\n' "$RESOLVE_LANG_OUT" | sed -n 's/^source=//p')"
RESOLVE_LANG_NOTE="$(printf '%s\n' "$RESOLVE_LANG_OUT" | sed -n 's/^note=//p')"
echo "  lang=${RESOLVE_LANG_VALUE}"
echo "  source=${RESOLVE_LANG_SOURCE}"
if [ "$RESOLVE_LANG_NOTE" != "none" ]; then
  echo "[警告] ${RESOLVE_LANG_NOTE}"
fi

echo
echo "=== サンドボックス（scripts/sandbox-exec.sh --print-plan） ==="
SANDBOX_PLAN="$(bash "${SCRIPT_DIR}/sandbox-exec.sh" --print-plan 2>&1)"
SANDBOX_EXIT=$?
if [ "$SANDBOX_EXIT" -eq 0 ]; then
  printf '%s\n' "$SANDBOX_PLAN" | sed 's/^/  /'
else
  echo "[NG] sandbox-exec.sh --print-plan の実行に失敗しました（exit ${SANDBOX_EXIT}）:"
  printf '%s\n' "$SANDBOX_PLAN" | sed 's/^/  /'
fi

echo
echo "=== リポジトリ衛生（scripts/check-repo-hygiene.sh --check --print） ==="
# --check を付け、.git/info/exclude への書き込み（副作用）を伴わずに判定だけ取得する。
HYGIENE_OUT="$(bash "${SCRIPT_DIR}/check-repo-hygiene.sh" --check --print 2>/dev/null)"
TRACKED_SETTINGS_LOCAL="$(printf '%s\n' "$HYGIENE_OUT" | sed -n 's/^tracked_settings_local=//p')"
case "$TRACKED_SETTINGS_LOCAL" in
  yes)
    echo "[警告] .claude/settings.local.json が git 追跡されています。"
    echo "  詳細・対処方法: bash scripts/check-repo-hygiene.sh"
    ;;
  no)
    echo "[OK] .claude/settings.local.json は追跡されていません"
    ;;
  *)
    echo "[skip] git リポジトリ外のためスキップしました"
    ;;
esac

echo
echo "=== CRLF設定（check-prerequisites.sh の crlf_warning_message） ==="
CRLF_WARNING="$(crlf_warning_message)"
if [ -n "$CRLF_WARNING" ]; then
  printf '%s\n' "$CRLF_WARNING" | sed 's/^/[警告] /'
else
  echo "[OK] CRLF設定に問題はありません"
fi

echo
if [ "$REQUIRED_MISSING" -eq 1 ]; then
  echo "[dev-workflow] 診断結果: 必須依存が不足しています（上記 [NG] を参照）。"
  exit 1
fi

echo "[dev-workflow] 診断結果: 必須依存は揃っています。"
exit 0
