#!/bin/bash
# dev-workflow: 配布用マーケットプレイスへ現行バージョンを公開する
#
# このプラグインは2つのリポジトリで配布されている:
#   - 開発リポジトリ（このリポジトリ）   ... 正本。tag v<version> がリリース点
#   - 配布リポジトリ（marketplace）      ... `plugins/<plugin>/` に配布物のコピーを持ち、
#                                            marketplace.json の `source.sha` でコミットを固定する
#
# 利用者の `/plugin update` が見るのは**配布リポジトリの sha**だけである。開発リポジトリに
# tag を打っただけでは誰にも届かない（実際に v0.18.1 のまま2リリース分配り漏れた）。
# この公開作業を手でやると次の3点を取りこぼす:
#   1. 配布対象の切り出し（docs/ や tests/ を混ぜる・新規ディレクトリを入れ忘れる）
#   2. sha の更新漏れ（内容だけ push して sha が前バージョンを指し続ける＝利用者には何も届かない）
#   3. sha を持つ marketplace.json が複数ある（現在2つ）ことの見落とし
# 本スクリプトはこの3点を機械化する。
#
# sha はコミット後にしか確定しないため、コミットは必ず2本になる（既存のリリース履歴と同じ）:
#   1本目: Update <plugin> to v<version>   ... 配布物の差し替え
#   2本目: Update SHA for v<version> (...) ... 1本目の sha を marketplace.json へ書き戻す
#
# 使い方:
#   bash scripts/publish-marketplace.sh            # 公開する（clone → 2コミット → push）
#   bash scripts/publish-marketplace.sh --check    # 差分だけ表示する（commit も push もしない）
#   bash scripts/publish-marketplace.sh --no-push  # clone に2コミット作るだけ（push しない）
#   bash scripts/publish-marketplace.sh --ref v0.19.1                  # 公開する ref（既定: v<version>）
#   bash scripts/publish-marketplace.sh --marketplace-repo <path|url>   # 配布先の差し替え（テスト用）
#
# 環境変数:
#   DEV_WORKFLOW_MARKETPLACE_REPO  配布リポジトリの既定値を上書きする（--marketplace-repo と同義）
#
# 終了コード:
#   0 = 公開した、または既に最新だった（冪等。差分が無ければコミットを作らない）
#   1 = 失敗（ref が無い / version 不整合 / clone・push 失敗）
#   2 = 引数エラー（未知のオプション。黙って無視しない）
#
# このリポジトリには一切書き込まない（読むのは git の ref のみ）。作業は mktemp -d 配下の
# clone で行い、**完了後も消さずにパスを表示する**（push 失敗時に人間が続きを引き継げるようにする）。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_MARKETPLACE_REPO="https://github.com/masatoImayama/claude-dev-workflow-marketplace.git"

# 配布対象から外すもの。
# 「配布物 = 正本ツリー - これ」という引き算の形にしてある。列挙式（足し算）にすると
# 正本に増えた新しいディレクトリを入れ忘れる（skills/setup/ はまさにその位置にあった）。
# docs/ と tests/ は開発者向けで利用者のコンテキストには載せない。Dockerfile.dev は
# 駆動先リポジトリが用意するものであり、プラグインが配るものではない。
EXCLUDE_FROM_DIST=(".gitignore" "Dockerfile.dev" "docs" "tests")

MARKETPLACE_REPO="${DEV_WORKFLOW_MARKETPLACE_REPO:-$DEFAULT_MARKETPLACE_REPO}"
REF=""
MODE="publish"
DO_PUSH="yes"

while [ $# -gt 0 ]; do
  case "$1" in
    --check)   MODE="check" ;;
    --no-push) DO_PUSH="no" ;;
    --ref)
      shift
      [ $# -gt 0 ] || { echo "エラー: --ref に値がありません" >&2; exit 2; }
      REF="$1" ;;
    --marketplace-repo)
      shift
      [ $# -gt 0 ] || { echo "エラー: --marketplace-repo に値がありません" >&2; exit 2; }
      MARKETPLACE_REPO="$1" ;;
    -h|--help)
      echo "使い方: bash scripts/publish-marketplace.sh [--check] [--no-push] [--ref <ref>] [--marketplace-repo <path|url>]"
      echo "詳細はこのスクリプト冒頭のコメントを参照してください。"
      exit 0 ;;
    *)
      echo "エラー: 未知のオプション: $1" >&2
      echo "使い方: bash scripts/publish-marketplace.sh [--check] [--no-push] [--ref <ref>] [--marketplace-repo <path|url>]" >&2
      exit 2 ;;
  esac
  shift
done

json_string_value() {
  # json_string_value <file> <key>
  # マニフェストから文字列値を1つ取り出す。jq を前提にしない（jq は任意依存であり、
  # 公開作業が外部ツールの導入状況に左右されるべきではない）。
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

MANIFEST="${REPO_ROOT}/.claude-plugin/plugin.json"
if [ ! -f "$MANIFEST" ]; then
  echo "エラー: ${MANIFEST} が見つかりません（このリポジトリのルートで実行してください）" >&2
  exit 1
fi

PLUGIN_NAME="$(json_string_value "$MANIFEST" name)"
VERSION="$(json_string_value "$MANIFEST" version)"
if [ -z "$PLUGIN_NAME" ] || [ -z "$VERSION" ]; then
  echo "エラー: ${MANIFEST} から name / version を読めませんでした" >&2
  exit 1
fi

[ -n "$REF" ] || REF="v${VERSION}"

if ! git -C "$REPO_ROOT" rev-parse -q --verify "${REF}^{commit}" >/dev/null; then
  echo "エラー: ref '${REF}' がこのリポジトリにありません。" >&2
  echo "       リリース tag を打ってから実行してください（例: git tag v${VERSION} && git push origin v${VERSION}）。" >&2
  exit 1
fi

# ref 側のマニフェストと、いま読んだ version が一致していることを確認する。
# ここがズレると「0.20.0 として公開したのに中身は 0.19.1」という最悪の事故になる
# （利用者側は version 表記だけ見て更新済みと判断してしまい、気づく手段が無い）。
REF_VERSION="$(git -C "$REPO_ROOT" show "${REF}:.claude-plugin/plugin.json" 2>/dev/null \
  | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
if [ "$REF_VERSION" != "$VERSION" ]; then
  echo "エラー: ref '${REF}' のマニフェストは version='${REF_VERSION}' で、現在の '${VERSION}' と一致しません。" >&2
  echo "       意図した ref を --ref で明示するか、tag を打ち直してください。" >&2
  exit 1
fi

echo "== ${PLUGIN_NAME} v${VERSION} を配布リポジトリへ公開する =="
echo "   ref    : ${REF} ($(git -C "$REPO_ROOT" rev-parse --short "${REF}^{commit}"))"
echo "   配布先 : ${MARKETPLACE_REPO}"
if [ "$DO_PUSH" = "no" ]; then
  echo "   モード : ${MODE} (--no-push)"
else
  echo "   モード : ${MODE}"
fi
echo ""

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-publish.XXXXXX")"
CLONE="${WORKDIR}/marketplace"

# core.autocrlf=false / core.eol=lf を clone に固定する。Windows の既定（autocrlf=true）で
# 作業ツリーが CRLF 化されると、.gitattributes の対象外ファイルで無害な警告が大量に出るだけ
# でなく、配布物の行末が環境によって変わる余地が残る。公開物は行末まで決定的にする。
if ! git -c core.autocrlf=false -c core.eol=lf clone -q "$MARKETPLACE_REPO" "$CLONE" 2>"${WORKDIR}/clone.err"; then
  echo "エラー: 配布リポジトリの clone に失敗しました: ${MARKETPLACE_REPO}" >&2
  sed 's/^/       /' "${WORKDIR}/clone.err" >&2
  exit 1
fi

git -C "$CLONE" config core.autocrlf false
git -C "$CLONE" config core.eol lf

BRANCH="$(git -C "$CLONE" symbolic-ref --short HEAD 2>/dev/null)"
[ -n "$BRANCH" ] || BRANCH="master"

DIST_DIR="${CLONE}/plugins/${PLUGIN_NAME}"
if [ ! -d "$DIST_DIR" ]; then
  echo "エラー: 配布リポジトリに plugins/${PLUGIN_NAME}/ がありません（配布先の構成を確認してください）" >&2
  echo "       clone: ${CLONE}" >&2
  exit 1
fi

# --- 配布物の差し替え -------------------------------------------------------
# git archive を使うのは、作業ツリーの未コミット・未追跡ファイル（.claude/ 配下の
# ハーネス生成物など）を絶対に混ぜないため。ref の中身そのものが配布物になる。
# 先に丸ごと消してから展開するのは、正本から**消えた**ファイルを配布物に残さないため。
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
if ! git -C "$REPO_ROOT" archive "$REF" | tar -x -C "$DIST_DIR"; then
  echo "エラー: ref '${REF}' の展開に失敗しました" >&2
  exit 1
fi
for _ex in "${EXCLUDE_FROM_DIST[@]}"; do
  rm -rf "${DIST_DIR:?}/${_ex}"
done
unset _ex

if ! git -C "$CLONE" add -A; then
  echo "エラー: 差分のステージに失敗しました（clone: ${CLONE}）" >&2
  exit 1
fi

CONTENT_CHANGED="no"
git -C "$CLONE" diff --cached --quiet || CONTENT_CHANGED="yes"

if [ "$CONTENT_CHANGED" = "yes" ]; then
  echo "-- 配布物の差分 --"
  git -C "$CLONE" diff --cached --name-status | sed 's/^/   /'
else
  echo "-- 配布物は既に ${REF} と一致している（内容コミットは作らない） --"
fi
echo ""

if [ "$MODE" = "check" ]; then
  echo "== --check のため commit も push もしていない =="
  echo "   clone: ${CLONE}"
  exit 0
fi

if [ "$CONTENT_CHANGED" = "yes" ]; then
  if ! git -C "$CLONE" commit -q -m "Update ${PLUGIN_NAME} to v${VERSION}"; then
    echo "エラー: 配布物のコミットに失敗しました（clone: ${CLONE}）" >&2
    exit 1
  fi
  if [ "$DO_PUSH" = "yes" ]; then
    if ! git -C "$CLONE" push -q origin "$BRANCH"; then
      echo "エラー: push に失敗しました。配布リポジトリが先に進んでいる可能性があります。" >&2
      echo "       clone: ${CLONE}（ここで続きを引き継げます）" >&2
      exit 1
    fi
  fi
  echo "   1/2 コミット: $(git -C "$CLONE" log --oneline -1)"
fi

# --- sha の書き戻し ---------------------------------------------------------
# sha を持つ marketplace.json は現在2つ（.claude-plugin/ と .agents/plugins/）だが、
# 増減しても追従できるよう**探して全部直す**。片方だけ直すと、そのベンダーの利用者に
# だけ更新が届かないという、配り手からは気づけない形で壊れる。
SHA_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && SHA_FILES+=("$f")
done < <(cd "$CLONE" && grep -rl --include=marketplace.json '"sha"' . 2>/dev/null | sed 's|^\./||' | sort)

if [ "${#SHA_FILES[@]}" -eq 0 ]; then
  echo "エラー: sha を持つ marketplace.json が配布リポジトリに見つかりません（clone: ${CLONE}）" >&2
  exit 1
fi

# 書き込む sha を決める。
# 単純に HEAD を書くと、内容に差分が無い実行（＝2回目以降）でも「sha コミット自身」を
# 指す新しい sha を書いてしまい、毎回コミットが増え続ける（冪等でなくなる）。
# 判定の基準は「その sha の plugins/<plugin> の中身が、いま公開したい中身と同じか」である。
# 既存の sha が同じ中身を配っているなら触らない。違う中身（＝前バージョン）を配っていれば
# 直す。これは「内容だけ push して sha が前バージョンを指し続けた」事故の検知そのものである。
CONTENT_SHA="$(git -C "$CLONE" rev-parse HEAD)"
DIST_TREE="$(git -C "$CLONE" rev-parse "HEAD:plugins/${PLUGIN_NAME}")"
EXISTING_SHA="$(grep -o -E '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' "${CLONE}/${SHA_FILES[0]}" | head -1 | grep -o -E '[0-9a-f]{40}')"
EXISTING_DIST_TREE=""
if [ -n "$EXISTING_SHA" ]; then
  EXISTING_DIST_TREE="$(git -C "$CLONE" rev-parse -q --verify "${EXISTING_SHA}:plugins/${PLUGIN_NAME}" 2>/dev/null)"
fi
if [ -n "$EXISTING_DIST_TREE" ] && [ "$EXISTING_DIST_TREE" = "$DIST_TREE" ]; then
  CONTENT_SHA="$EXISTING_SHA"
fi

for f in "${SHA_FILES[@]}"; do
  # 対象ファイルには dev-workflow のエントリしか無いことを前提にしている。
  # 将来この配布リポジトリが複数プラグインを持つなら、ファイル単位ではなく
  # エントリ単位の置換に直すこと（他プラグインの sha を巻き込むため）。
  sed -i -E "s/(\"sha\"[[:space:]]*:[[:space:]]*\")[0-9a-f]{40}(\")/\1${CONTENT_SHA}\2/" "${CLONE}/${f}"
done

SHA_CHANGED="no"
git -C "$CLONE" diff --quiet || SHA_CHANGED="yes"

if [ "$SHA_CHANGED" = "yes" ]; then
  if ! git -C "$CLONE" commit -aq -m "Update SHA for v${VERSION} (${#SHA_FILES[@]} marketplace files)"; then
    echo "エラー: sha のコミットに失敗しました（clone: ${CLONE}）" >&2
    exit 1
  fi
  if [ "$DO_PUSH" = "yes" ]; then
    if ! git -C "$CLONE" push -q origin "$BRANCH"; then
      echo "エラー: sha コミットの push に失敗しました（clone: ${CLONE}）" >&2
      exit 1
    fi
  fi
  echo "   2/2 コミット: $(git -C "$CLONE" log --oneline -1)"
else
  echo "   sha は既に ${CONTENT_SHA} を指している（sha コミットは作らない）"
fi

PUBLISHED_VERSION="$(json_string_value "${DIST_DIR}/.claude-plugin/plugin.json" version)"
echo ""
echo "== 公開結果 =="
echo "   version : ${PUBLISHED_VERSION}"
echo "   sha     : ${CONTENT_SHA}"
echo "   sha を直したファイル: ${SHA_FILES[*]}"
echo "   clone   : ${CLONE}"

if [ "$DO_PUSH" = "no" ]; then
  echo ""
  echo "!! --no-push のため push していない。marketplace.json の sha はまだ公開されていない"
  echo "   コミットを指している（この状態の配布リポジトリを公開すると利用者側の取得が失敗する）。"
  echo "   続けるなら: git -C '${CLONE}' push origin ${BRANCH}"
  exit 0
fi

echo ""
echo "次の手順（手元のインストールへ反映する）:"
echo "   claude plugin marketplace update <marketplace名>   # /plugin の表示に合わせる"
echo "   claude plugin update ${PLUGIN_NAME}"
echo "   その後 Claude Code / Claude Desktop を再起動する（再起動するまで旧版が読み込まれたままになる）"

exit 0
