#!/bin/bash
# dev-workflow: 任意MCPツール（context7 / code-review-graph）の導入を1コマンドにまとめる（Task #219）
#
# `docs/optional-mcp-tools.md` には両ツールの導入手順が上流で確認済みの値として記載されているが、
# 実行するスクリプトが無く、利用者は文書を探して手で叩く必要があった。本スクリプトはその手作業を
# 1コマンドにまとめる。パッケージ名・導入コマンドの正本は引き続き `docs/optional-mcp-tools.md`
# であり、齟齬が出た場合はこのスクリプトではなく `docs/optional-mcp-tools.md` 側を直すこと
# （`scripts/doctor.sh` と同じハードコード方針。ケース6・7参照）。
#
# 使い方:
#   bash scripts/install-optional-mcp.sh [--apply] [--only context7|code-review-graph]
#
#   （引数なし）  既定は dry-run。何もインストールせず、実行予定のコマンドを表示するだけ。
#   --apply       実際に導入コマンドを実行する（明示しない限り何もインストールしない）。
#   --only <対象> 対象を context7 または code-review-graph のどちらかに絞る（既定は両方）。
#   -h, --help    このヘルプを表示する。
#
# 終了コード:
#   0 = 引数エラーなし。dry-run は常に0（何も試みていないため）。--apply は対象が全て
#       導入済み・導入成功のいずれかであれば0。
#   1 = 引数エラー（不明なフラグ・--only の値が不正 等）。
#   2 = --apply 実行時のみ: 前提条件不足のため導入を試みなかった対象がある、
#       導入コマンドが失敗した対象がある、または導入後もPATH解決できなかった対象がある。
#
# 副作用:
#   dry-run では一切無い（何もインストールしない・何も書き換えない）。
#   --apply 時のみ、対象ごとの導入コマンド（context7: npm install -g / code-review-graph:
#   前提チェックで見つかった pip・pip3・pipx・uvx のいずれか）を実行する（issue #224）。
#
# 設計判断の記録（完了条件の1つ）:
#   `code-review-graph install --platform claude-code` はこのスクリプトでは使わない。
#   dev-workflow は `.claude-plugin/plugin.json` の `mcpServers.code-review-graph` で
#   起動コマンド（`code-review-graph serve`）を既に宣言済み（Task #73。
#   `docs/optional-mcp-tools.md` の「Phase 4: code-review-graph の結線（#73）」節）であり、
#   `install --platform claude-code` はMCP設定を自動生成するコマンドである。本タスクの
#   作業環境にはネットワーク接続が無く、上流ソースで実際の出力ファイル・冪等性
#   （dev-workflow側の宣言と衝突しないか）を確認できなかった。issue本文の設計上の注意
#   （「不要なら pip install と build だけでよい可能性がある」）に従い、確認できない
#   コマンドは安全側（実行しない）に倒し、pip系コマンド（pip/pip3/pipx/uvx）による
#   `code-review-graph` の導入のみを行う。
#   グラフ構築（`code-review-graph build`）は Epic issue 本文の `## 準備コマンド` 節で
#   run が Epic 開始時に1回だけ実行する既存の仕組みに任せ、ここでは行わない
#   （`docs/optional-mcp-tools.md` 「グラフ構築は Epic 開始時に1回（#75）」節）。
set -u

usage() {
  cat <<'USAGE'
使い方: bash scripts/install-optional-mcp.sh [--apply] [--only context7|code-review-graph]

既定（--apply なし）: 何もインストールせず、実行予定のコマンドを表示するだけ（dry-run）。
  --apply           実際に導入コマンドを実行する。
  --only <対象>     対象を context7 または code-review-graph のどちらかに絞る（既定は両方）。
  -h, --help        このヘルプを表示する。

終了コード:
  0 = (dry-run) 表示のみ完了 / (--apply) 対象が全て導入済みまたは導入に成功した
  1 = 引数エラー
  2 = (--apply時のみ) 前提条件不足・導入コマンド失敗・導入後のPATH解決失敗のいずれかが発生した
USAGE
}

# パッケージ名・導入コマンドの出典: docs/optional-mcp-tools.md
# 「## 対象ツール」節・「## 申し送りに対してどう応えたか（#80 レビュー対応）」節。
CONTEXT7_PACKAGE="@upstash/context7-mcp"
CODE_REVIEW_GRAPH_PACKAGE="code-review-graph"

install_context7() {
  npm install -g "$CONTEXT7_PACKAGE"
}

# detect_code_review_graph_pip_tool: pip/pip3/pipx/uvx のうち最初に見つかったコマンド名を
# 標準出力へ書く（見つからなければ何も出力せず終了コード1）。
# check_code_review_graph_prereqs() が「前提OK」と判定するコマンドと、install_code_review_graph()
# が実際に実行するコマンドを同じ判定結果から導くための共通の入口（issue #224 再発防止）。
detect_code_review_graph_pip_tool() {
  local candidate
  for candidate in pip pip3 pipx uvx; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# code_review_graph_install_cmd_display: 指定したpipツールで実際に実行するコマンド文字列を返す
# （dry-run表示・[導入中]ログの両方で使い、install_code_review_graph() と表示内容を一致させる）。
code_review_graph_install_cmd_display() {
  local pip_tool="$1"
  case "$pip_tool" in
    pip|pip3) echo "${pip_tool} install ${CODE_REVIEW_GRAPH_PACKAGE}" ;;
    pipx) echo "pipx install ${CODE_REVIEW_GRAPH_PACKAGE}" ;;
    uvx) echo "uvx pip install ${CODE_REVIEW_GRAPH_PACKAGE}" ;;
    *) echo "pip install ${CODE_REVIEW_GRAPH_PACKAGE}" ;;
  esac
}

# install_code_review_graph: check_code_review_graph_prereqs() 側で検出したのと同じ探索順
# （pip/pip3/pipx/uvx）で見つかったコマンドを引数で受け取り、そのコマンドで導入する。
# 前提チェックが許容したコマンドと実際に実行するコマンドを一致させる（issue #224）。
install_code_review_graph() {
  local pip_tool="$1"
  case "$pip_tool" in
    pip|pip3)
      "$pip_tool" install "$CODE_REVIEW_GRAPH_PACKAGE"
      ;;
    pipx)
      pipx install "$CODE_REVIEW_GRAPH_PACKAGE"
      ;;
    uvx)
      uvx pip install "$CODE_REVIEW_GRAPH_PACKAGE"
      ;;
    *)
      echo "[dev-workflow] エラー: 未知のpipツールです: ${pip_tool}" >&2
      return 1
      ;;
  esac
}

# check_context7_prereqs: 不足している前提を1行1件で標準出力へ書く。
# 何も出力しなければ前提は揃っている。
check_context7_prereqs() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm が見つかりません（Node.js https://nodejs.org/ からインストールしてください）"
  fi
}

# check_code_review_graph_prereqs: 不足している前提を1行1件で標準出力へ書く。
# Python 3.10+ と pip/pipx/uvx のいずれかが必要（issue #219 実装内容 5）。
check_code_review_graph_prereqs() {
  local python_bin=""
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      python_bin="$candidate"
      break
    fi
  done

  if [ -z "$python_bin" ]; then
    echo "Python 3.10+ が見つかりません（https://www.python.org/ からインストールしてください）"
  elif ! "$python_bin" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
    local ver
    ver="$("$python_bin" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null)"
    echo "Python 3.10+ が必要です（検出したバージョン: ${ver:-不明}）"
  fi

  detect_code_review_graph_pip_tool >/dev/null || echo "pip/pipx/uvx のいずれも見つかりません"
}

APPLY=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --only)
      if [ $# -lt 2 ]; then
        echo "[dev-workflow] エラー: --only には値が必要です" >&2
        usage >&2
        exit 1
      fi
      ONLY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[dev-workflow] エラー: 不明な引数です: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$ONLY" in
  ""|context7|code-review-graph)
    ;;
  *)
    echo "[dev-workflow] エラー: --only には context7 または code-review-graph を指定してください（実際: ${ONLY}）" >&2
    exit 1
    ;;
esac

if [ -n "$ONLY" ]; then
  TARGETS=("$ONLY")
else
  TARGETS=("context7" "code-review-graph")
fi

OVERALL_STATUS=0

for target in "${TARGETS[@]}"; do
  case "$target" in
    context7)
      bin_name="context7-mcp"
      display_name="context7 (${CONTEXT7_PACKAGE})"
      install_cmd_display="npm install -g ${CONTEXT7_PACKAGE}"
      prereq_missing="$(check_context7_prereqs)"
      ;;
    code-review-graph)
      bin_name="code-review-graph"
      display_name="code-review-graph (${CODE_REVIEW_GRAPH_PACKAGE})"
      # 前提チェック（check_code_review_graph_prereqs）が許容するコマンドと同じ探索結果を
      # ここでも使い、表示・実行の両方を一致させる（issue #224）。
      crg_pip_tool="$(detect_code_review_graph_pip_tool)"
      install_cmd_display="$(code_review_graph_install_cmd_display "${crg_pip_tool:-pip}")"
      prereq_missing="$(check_code_review_graph_prereqs)"
      ;;
  esac

  if command -v "$bin_name" >/dev/null 2>&1; then
    echo "[OK] ${display_name}: 既に導入済みです（$(command -v "$bin_name")）。何もしません。"
    continue
  fi

  if [ -n "$prereq_missing" ]; then
    echo "[前提不足] ${display_name}: 導入に必要な前提が不足しているため、導入は試みません。"
    printf '%s\n' "$prereq_missing" | sed 's/^/  - /'
    [ "$APPLY" -eq 1 ] && OVERALL_STATUS=2
    continue
  fi

  if [ "$APPLY" -eq 0 ]; then
    echo "[dry-run] ${display_name}: 次のコマンドで導入できます（何も実行していません）:"
    echo "  ${install_cmd_display}"
    continue
  fi

  echo "[導入中] ${display_name}: ${install_cmd_display}"
  case "$target" in
    context7) install_ok=0; install_context7 || install_ok=1 ;;
    code-review-graph) install_ok=0; install_code_review_graph "$crg_pip_tool" || install_ok=1 ;;
  esac

  if [ "$install_ok" -ne 0 ]; then
    echo "[NG] ${display_name}: 導入コマンドが失敗しました（ネットワーク不通の可能性があります）。" >&2
    OVERALL_STATUS=2
    continue
  fi

  if command -v "$bin_name" >/dev/null 2>&1; then
    echo "[OK] ${display_name}: 導入が完了し、PATHで解決できました（$(command -v "$bin_name")）。"
  else
    echo "[警告] ${display_name}: 導入コマンドは完了しましたが、PATHで '${bin_name}' を解決できません。" >&2
    echo "  導入先がPATHに含まれているか確認してください（例: pip install --user の場合の ~/.local/bin 等）。" >&2
    OVERALL_STATUS=2
  fi
done

exit "$OVERALL_STATUS"
