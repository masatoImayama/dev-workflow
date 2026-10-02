#!/bin/bash
# dev-workflow: 人間向け出力の言語解決（ベンダー中立・単一の正本）
#
# 言語の解決（許容リストの判定・不正値のフォールバック・記録用メッセージの生成）は
# run・scripts/doctor.sh・各エージェントの3か所から必要になるため、三重実装を避けて
# ここに1つだけ置く（Epic #246）。
#
# 使い方:
#   bash scripts/resolve-lang.sh            # 環境変数 DEV_WORKFLOW_LANG から解決する
#   bash scripts/resolve-lang.sh --lang en  # 明示値を検証する（run が保持する解決値・
#                                           # evaluator が返した値の再検証に使う）
#   bash scripts/resolve-lang.sh --help     # 使い方を表示して exit 0
#
# 優先順位: --lang > DEV_WORKFLOW_LANG > 既定 ja
#
# 出力（stdout。1行1項目・機械可読。必ずこの順で3行）:
#   lang=<ja|en>
#   source=<arg|env|default|fallback>
#   note=<不正値だった事実を1行で。正常時は none>
#
# 終了コード: 常に 0
#   不正値・未サポート値・空文字は ja に倒し、その事実を note= に記録する。停止しない
#   （scripts/doctor.sh は終了コードで必須依存の有無を判定するため、言語の不正値で
#   診断全体を失敗扱いにしてはならない。run も止めてはならない）。
#
# 許容値は SUPPORTED_LANGS の1変数に定義する。将来の言語追加はこの変数への1語追加で
# 済ませる（ja/en を条件分岐に散らさない）。
#
# 副作用は持たない（ファイルを作らない・何も書き換えない・何もインストールしない）。
#
# note= の文言は日本語のまま固定する（Epic #246 の D2。bash スクリプトが出す人間向け
# メッセージは本 Epic のスコープ外であり、DEV_WORKFLOW_LANG に従わせない）。
# 出力キー（lang= / source= / note=）と値（ja|en|arg|env|default|fallback）は
# 呼び出し側が機械的に読むため、言語設定の対象外とする（字面を変えない）。

set -u

SUPPORTED_LANGS="ja en"

usage() {
  cat <<'USAGE'
使い方:
  bash scripts/resolve-lang.sh            # 環境変数 DEV_WORKFLOW_LANG から解決する
  bash scripts/resolve-lang.sh --lang en  # 明示値を検証する
  bash scripts/resolve-lang.sh --help     # このヘルプを表示して終了する（exit 0）

出力（この順で必ず3行）:
  lang=<ja|en>
  source=<arg|env|default|fallback>
  note=<不正値だった事実を1行で。正常時は none>

終了コード: 常に 0
USAGE
}

# is_supported_lang <値>
#   SUPPORTED_LANGS に含まれるかを判定する。許容リストを1変数に閉じ込めるための
#   唯一の判定箇所（将来の言語追加はSUPPORTED_LANGSへの1語追加だけで済む）。
is_supported_lang() {
  local candidate="$1" lang
  for lang in $SUPPORTED_LANGS; do
    [ "$lang" = "$candidate" ] && return 0
  done
  return 1
}

ARG_LANG=""
HAS_ARG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help)
      usage
      exit 0 ;;
    --lang)
      if [ $# -lt 2 ]; then
        echo "lang=ja"
        echo "source=fallback"
        echo "note=--lang には値が必要です。ja にフォールバックしました"
        exit 0
      fi
      ARG_LANG="$2"
      HAS_ARG=1
      shift 2 ;;
    *)
      echo "lang=ja"
      echo "source=fallback"
      echo "note=未知の引数です: $1。ja にフォールバックしました"
      exit 0 ;;
  esac
done

if [ "$HAS_ARG" -eq 1 ]; then
  if is_supported_lang "$ARG_LANG"; then
    echo "lang=${ARG_LANG}"
    echo "source=arg"
    echo "note=none"
  else
    echo "lang=ja"
    echo "source=fallback"
    echo "note=--lang に未サポートの値が指定されました: '${ARG_LANG}'。ja にフォールバックしました"
  fi
  exit 0
fi

ENV_LANG="${DEV_WORKFLOW_LANG:-}"

if [ -z "$ENV_LANG" ]; then
  if [ -z "${DEV_WORKFLOW_LANG+x}" ]; then
    echo "lang=ja"
    echo "source=default"
    echo "note=none"
  else
    echo "lang=ja"
    echo "source=fallback"
    echo "note=DEV_WORKFLOW_LANG が空文字です。ja にフォールバックしました"
  fi
  exit 0
fi

if is_supported_lang "$ENV_LANG"; then
  echo "lang=${ENV_LANG}"
  echo "source=env"
  echo "note=none"
else
  echo "lang=ja"
  echo "source=fallback"
  echo "note=DEV_WORKFLOW_LANG に未サポートの値が指定されました: '${ENV_LANG}'。ja にフォールバックしました"
fi
exit 0
