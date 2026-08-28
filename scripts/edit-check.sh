#!/bin/bash
# dev-workflow plugin: 編集時チェック（PostToolUse）
#
# 「編集 → sandbox-exec.sh でビルド/テスト実行 → エラーを読む → 修正」で最低3ターン、かつ
# 毎回Docker往復（1回あたり約3.4秒。docs/adr/0002-sandbox-overhead-reduction.md）が発生している。
# 編集直後にホスト側で型チェック単体・lint単体のような軽量チェックを走らせ、その場でエージェントへ
# 差し戻すことでこのループを縮める（Epic #143 Task #155）。
#
# 差し戻し契約は scripts/check-readability.sh と同一にする（新しい差し戻し方式を作らない）:
#   - Claude Code … exit 2 + stderr にメッセージ
#   - Codex CLI  … exit 0 + stdout に {"continue": false, ...} のJSON
#   - pre-commit 等 … exit 1 + stderr（DEV_WORKFLOW_HOOK_VENDOR=exit-code で明示）
# check-readability.sh を直接 source せず重複実装にしている理由は下記「設計メモ」参照。
#
# チェック内容はハードコードしない（dev-workflow は任意のリポジトリを駆動する）。
# Epic 本文の任意節 `## 編集時チェック`（`## 準備コマンド` 等と同じ機構）で受け取る。
# **節が無ければ何もしない**（既存 Epic の挙動を変えない）。
#
# 節の受け渡しは環境変数の伝播に頼らない。PostToolUse フックは CLI 本体の子プロセスとして
# 起動されるため、generator が Bash ツール越しに `export` した値は届かない
# （scripts/heartbeat.sh の --abort フラグ判定と同じ制約）。そのため run が Epic 開始時に
# `--write` でこの節の内容をマーカーファイルへ書き出し、フックはそれを読む
# （`DEV_WORKFLOW_EDIT_CHECK` 環境変数が設定されていればファイルより優先する。テスト・
# デバッグ用の上書き）。
#
# 仕様の書式（Epic 本文の節・マーカーファイルとも同じ）:
#   <glob>  <コマンド。{file} が編集ファイルパスに置換される>
#   1行1マッピング。空行・`#` で始まる行は無視する。編集ファイルに最初に一致した行のコマンドを
#   使う（上から順に判定）。{file} にスペースを含むパスが来ることがあるため、コマンド側で
#   `"{file}"` のように引用するのは呼び出し側（Epic本文を書く側）の責任とする。
#
#   例:
#     *.go  gofmt -l {file}
#     *.ts  npx tsc --noEmit {file}
#
# タイムアウト（既定5秒。DEV_WORKFLOW_EDIT_CHECK_TIMEOUT秒で調整可）:
#   想定するのは型チェック単体・lint単体のような**秒オーダーで終わるもの**であり、
#   **テストスイートではない**（テストはレーン内ゲート・統合ゲートが別途担う）。
#
# フック自体のエラー（コマンド不在・タイムアウト）はブロックしない（exit 0で素通り）。
# ブロックするのは「チェックが実行でき、かつ非0終了＝違反が見つかった場合」だけ。
#
# ホスト側で実行する（コンテナ経由にしない）理由:
#   docs/adr/0005-edit-time-check-hook.md を参照。要約: 目的がDocker往復オーバーヘッドの削減
#   であるため、コンテナ経由にすると効果が減殺される。
#
# 設計メモ（check-readability.sh を直接 source しない理由）:
#   check-readability.sh は「引数なしstdin」「--git」「--staged」「ファイル引数」という
#   4つの起動モードを持つ、広く回帰テストされたスクリプトである。共通ヘルパ
#   （ベンダー判定・JSON文字列化）だけを外部ライブラリへ切り出して両者から source すると、
#   一方の改修がもう一方の挙動に波及し、テストの独立性が失われる。十数行の重複を許容し、
#   互いに独立して変更・回帰確認できる方を優先した。
#
# 使い方:
#   edit-check.sh              # PostToolUseフック本体（stdinのhook JSONからfile_pathを抽出）
#   edit-check.sh --write      # stdinからチェック仕様を読み、マーカーファイルへ書き込む（run用）
#   edit-check.sh --clear      # マーカーファイルを消す（節が無いEpicでの前回分の残留を防ぐ）
#
# 環境変数:
#   DEV_WORKFLOW_EDIT_CHECK          # チェック仕様の直接指定。設定されていればファイルより優先
#   DEV_WORKFLOW_EDIT_CHECK_TIMEOUT  # タイムアウト秒（既定5）
#   DEV_WORKFLOW_HOOK_VENDOR         # check-readability.sh と同じ出し分け（claude|codex|exit-code）
#   DEV_WORKFLOW_MARKER_ROOT         # マーカー置き場の起点を明示指定（scripts/lib/marker-root.sh）

set -u

EDIT_CHECK_SELF="${BASH_SOURCE[0]:-$0}"
EDIT_CHECK_DIR="${EDIT_CHECK_SELF%/*}"
[ "$EDIT_CHECK_DIR" = "$EDIT_CHECK_SELF" ] && EDIT_CHECK_DIR="."

_edit_check_marker_file() {
  # shellcheck source=./lib/marker-root.sh
  . "${EDIT_CHECK_DIR}/lib/marker-root.sh" 2>/dev/null || return 1
  local root
  # shellcheck disable=SC2119
  root="$(dev_workflow_marker_root 2>/dev/null)" || return 1
  [ -n "$root" ] || return 1
  printf '%s/.claude/.dev-workflow-edit-check' "$root"
}

# ── --write: 標準入力からチェック仕様を読み、マーカーファイルへ原子的に書き込む ──
if [ "${1:-}" = "--write" ]; then
  MARKER_FILE="$(_edit_check_marker_file)" || { echo "edit-check.sh --write: マーカー置き場を解決できません（gitリポジトリ外）" >&2; exit 1; }
  mkdir -p "$(dirname "$MARKER_FILE")" 2>/dev/null || true
  TMP_MARKER="${MARKER_FILE}.tmp.$$.${RANDOM}"
  cat > "$TMP_MARKER"
  mv -f "$TMP_MARKER" "$MARKER_FILE"
  exit 0
fi

# ── --clear: マーカーファイルを消す（前回Epicの内容を残さない） ──
if [ "${1:-}" = "--clear" ]; then
  MARKER_FILE="$(_edit_check_marker_file)" || exit 0
  rm -f "$MARKER_FILE" 2>/dev/null || true
  exit 0
fi

# ── ここから PostToolUse フック本体 ─────────────────────────────────────

SPEC="${DEV_WORKFLOW_EDIT_CHECK:-}"
if [ -z "$SPEC" ]; then
  MARKER_FILE="$(_edit_check_marker_file)" || MARKER_FILE=""
  if [ -n "$MARKER_FILE" ] && [ -f "$MARKER_FILE" ]; then
    SPEC="$(cat "$MARKER_FILE" 2>/dev/null)"
  fi
fi

# 節が無い（仕様が空）なら何もしない。既存Epicの挙動を変えない。
[ -z "$SPEC" ] && exit 0

TIMEOUT_SECS="${DEV_WORKFLOW_EDIT_CHECK_TIMEOUT:-5}"

# ── フック入力からfile_pathを取り出す（check-readability.shと同じ抽出方法） ──
HOOK_INPUT=""
if [ ! -t 0 ]; then
  IFS= read -r -d '' HOOK_INPUT 2>/dev/null || true
fi

raw=$(printf '%s' "$HOOK_INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
      | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
[ -z "$raw" ] && exit 0
# JSONエスケープ解除（\\ → \）と Windows パスの正規化（\ → /）
EDIT_CHECK_FILE=$(printf '%s' "$raw" | sed -e 's/\\\\/\\/g' -e 's/\\/\//g')
[ -f "$EDIT_CHECK_FILE" ] || exit 0

# ── 仕様の各行を上から順に見て、最初に一致したglobのコマンドを使う ──
CMD_TEMPLATE=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  glob="" rest=""
  read -r glob rest <<< "$line"
  [ -z "$glob" ] && continue
  # $glob をここでクォートすると文字どおりの文字列一致になり glob として機能しなくなる
  # （それが本来の目的）。意図的な未クォート展開なので shellcheck SC2254 を抑止する。
  # shellcheck disable=SC2254
  case "$EDIT_CHECK_FILE" in
    $glob)
      CMD_TEMPLATE="$rest"
      break
      ;;
  esac
done <<< "$SPEC"

# 一致するglobが無ければ、このファイルに対するチェックは無い（exit 0）
[ -z "$CMD_TEMPLATE" ] && exit 0

CMD="${CMD_TEMPLATE//\{file\}/$EDIT_CHECK_FILE}"

# ── タイムアウト付き実行（外部 `timeout` コマンドに非依存。check-readability.sh と
#    同じ理由＝macOS既定環境に `timeout` が無いため、bash組み込みだけで実装する） ──
run_with_timeout() {
  # run_with_timeout <timeout_secs> <command string> <出力の書き出し先ファイル>
  # 戻り値がコマンドの終了コード。SIGTERMで打ち切られた場合は128+15=143を返す
  # （呼び出し側でタイムアウトと判定する）。
  #
  # コマンドの出力（stdout+stderr）はコマンド置換のパイプではなく一時ファイルへ書く
  # （呼び出し側でファイルを読む）。監視用サブシェル `( sleep ...; kill ... )` は
  # `bash -c "$cmd" &` と同じプロセスグループ内でパイプの書き込み端を継承するため、
  # そちらを /dev/null にリダイレクトするだけでは、"$cmd" 自身が生成した孫プロセスが
  # 依然としてパイプを保持しうる（レビュー#158で指摘・実測確認）。出力先を一時ファイルに
  # することで、pipeのEOF待ちという失敗モード自体を解消する。
  local secs="$1" cmd="$2" outfile="$3"
  (
    bash -c "$cmd" >"$outfile" 2>&1 &
    local cmd_pid=$!
    # 監視用サブシェルの標準出力・標準エラーは親（コマンド置換のパイプ）から切り離す。
    # 切り離さないと、kill後も孫プロセスの sleep がパイプの書き込み端を保持し続け、
    # 呼び出し側の command substitution が EOF を待って常にタイムアウト秒数ぶんブロックする
    # （レビュー#158。実測: 5366ms→179ms）。
    ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
    local watch_pid=$!
    wait "$cmd_pid" 2>/dev/null
    local rc=$?
    kill "$watch_pid" 2>/dev/null
    wait "$watch_pid" 2>/dev/null
    exit "$rc"
  )
}

EDIT_CHECK_OUTFILE="$(mktemp "${TMPDIR:-/tmp}/dw-edit-check-out.XXXXXX" 2>/dev/null || printf '/tmp/dw-edit-check-out.%s' "$$")"
run_with_timeout "$TIMEOUT_SECS" "$CMD" "$EDIT_CHECK_OUTFILE"
RC=$?
OUTPUT="$(cat "$EDIT_CHECK_OUTFILE" 2>/dev/null)"
rm -f "$EDIT_CHECK_OUTFILE" 2>/dev/null

# rc=127: コマンド不在 / rc>=128: シグナルで終了（タイムアウトのSIGTERM含む）
# → いずれもフック自体のエラーとして扱い、ブロックしない
if [ "$RC" -eq 0 ] || [ "$RC" -eq 127 ] || [ "$RC" -ge 128 ]; then
  if [ "$RC" -eq 127 ] || [ "$RC" -ge 128 ]; then
    echo "【編集時チェック】 '${CMD}' が実行できなかった、またはタイムアウト（${TIMEOUT_SECS}秒）したためスキップします（rc=${RC}）" >&2
  fi
  exit 0
fi

# ── 違反あり（チェックが実行でき、かつ非0終了） ──────────────────────────

# 文字列をJSON文字列リテラルに変換する（jq非依存。check-readability.shのjson_stringと同一実装）
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

# 実行中のCLIを判定する（check-readability.shのdetect_hook_vendorと同一ロジック）
detect_hook_vendor() {
  if [ -n "${DEV_WORKFLOW_HOOK_VENDOR:-}" ]; then
    printf '%s' "$DEV_WORKFLOW_HOOK_VENDOR"
    return
  fi
  if [ -n "${PLUGIN_ROOT:-}" ]; then
    printf 'codex'
    return
  fi
  case "$HOOK_INPUT" in
    *'"turn_id"'*) printf 'codex'; return ;;
  esac
  printf 'claude'
}

message=$(
  echo "編集時チェックが問題を検出しました: ${EDIT_CHECK_FILE}"
  echo ""
  echo "実行したコマンド: ${CMD}"
  echo ""
  printf '%s\n' "$OUTPUT"
  echo ""
  echo "対応方針: 上記の出力を確認し、型/lintの違反を修正してから再度編集してください。"
)

case "$(detect_hook_vendor)" in
  codex)
    # Codex は stdout のJSONでブロックする。非0終了は「フックの失敗」として扱われ
    # JSONが読まれないため exit 0 で返す。
    printf '{"continue":false,"stopReason":%s,"systemMessage":%s}\n' \
      "$(json_string '編集時チェックが問題を検出しました')" \
      "$(json_string "$message")"
    exit 0
    ;;
  exit-code)
    # pre-commit などの素のgitフック用。慣例どおり exit 1 で失敗させる。
    printf '%s\n' "$message" >&2
    exit 1
    ;;
  *)
    # Claude Code。exit 2 + stderr でツール結果をブロックし、理由を差し戻す。
    printf '%s\n' "$message" >&2
    exit 2
    ;;
esac
