#!/bin/bash
# dev-workflow: share-prepared-dirs.sh の実環境測定（issue #176）用の合成 node プロジェクトを作る
#
# issue #176 のやること1「Windows + Docker Desktop の node 系駆動先で run を1本実測する」は、
# 実 Node.js/yarn プロジェクトが手元に無いために止まっている（ADR-0007 / ADR-0008 が
# 「`ln -s` が実際に失敗する状態そのものを再現できていない」と繰り返し記録している）。
#
# しかし share-prepared-dirs.sh が分岐に使うのは `node_modules` の**構造**だけであり、
# 中身が実在のパッケージかどうかは一切見ていない。使うのは次の4点である:
#
#   1. 直下エントリ数           -> コピー完全性検証（`ls -A` の件数一致）が実データ量で通るか
#   2. ファイルへの symlink     -> `.bin/*`。`-L` 無しの `cp -a` が部分失敗する原因（#178）
#   3. ディレクトリへの symlink -> yarn workspace 相当。`-L` でディスクが膨らむ原因
#   4. 深い階層・循環 symlink   -> COPY_CYCLE_GUARD_CAP（80）が発火するか（#182 / #185）
#
# 本スクリプトはこの4点だけを持つ偽プロジェクトを数十秒で作る。`yarn install` の20〜40分を
# 待たずに linked / copied / link-failed / copy-cycle-guard のどれが出るかを何度でも試せる。
#
# 測れないこと（#176 のやること2に必要な分は本スクリプトの範囲外）:
#   - install 所要時間の短縮効果。中身がダミーなので `yarn install` に意味が無い。
#     この数値だけは実プロジェクトでしか得られない
#   - 実 workspace 構成での正確なディスク増加量（--workspace-files で目安は作れる）
#
# 使い方:
#   bash tests/fixtures/make-fake-node-project.sh --dest /c/tmp/fake-node-app
#   bash tests/fixtures/make-fake-node-project.sh --dest ... --packages 500 --workspace-files 200
#   bash tests/fixtures/make-fake-node-project.sh --dest ... --with-cycle
#   bash tests/fixtures/make-fake-node-project.sh --dest ... --verify
#
# オプション:
#   --dest <path>            生成先。必須。既存かつ空でなければ何もせず失敗する（後述の安全ルール）
#   --packages <N>           node_modules 直下のダミーパッケージ数（既定 300）
#   --workspace-files <N>    workspace 実体（packages/my-lib）に置くファイル数（既定 50）。
#                            `-L` によるディレクトリ重複コピーのコストを観測するための重り
#   --with-cycle             循環シンボリックリンクを1本仕込む（COPY_CYCLE_GUARD_CAP の発火確認用）。
#                            既定では作らない。**通常の測定では付けないこと**（ガードが発火すると
#                            そのエントリは copy-failed で確定し、コピー経路の測定にならない）
#   --verify                 生成せず、--dest の中身を検査して機械可読な結果を出す
#
# 安全ルール（share-prepared-dirs.sh の冒頭コメントと揃える）:
#   本スクリプトは削除コマンド（`rm` / `rmdir`）を一切使わない。生成先が空でない場合は
#   上書きや掃除を試みず、そのまま失敗する。後始末は利用者が明示的に行う。
#
# 終了コード:
#   0 = 生成を完了した、または --verify で検査を完了した
#       （fixture が測定に使えるかどうかは stdout 最終行の `fixture<TAB>valid|invalid` で表す）
#   2 = 引数エラー（未知のオプション・--dest 未指定・生成先が空でない）
#
# 人間向けメッセージは stderr、機械可読な結果は stdout に出す
# （scripts/share-prepared-dirs.sh と同じ作法）。
set -u

DEST=""
PACKAGES=300
WORKSPACE_FILES=50
WITH_CYCLE=0
VERIFY=0

die() { printf '%s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)            [ $# -ge 2 ] || die "--dest には値が必要"; DEST="$2"; shift 2 ;;
    --packages)        [ $# -ge 2 ] || die "--packages には値が必要"; PACKAGES="$2"; shift 2 ;;
    --workspace-files) [ $# -ge 2 ] || die "--workspace-files には値が必要"; WORKSPACE_FILES="$2"; shift 2 ;;
    --with-cycle)      WITH_CYCLE=1; shift ;;
    --verify)          VERIFY=1; shift ;;
    *) die "未知のオプション: $1（黙って無視しない）" ;;
  esac
done

[ -n "$DEST" ] || die "--dest は必須"

case "$PACKAGES" in ''|*[!0-9]*) die "--packages は非負整数で指定する: $PACKAGES" ;; esac
case "$WORKSPACE_FILES" in ''|*[!0-9]*) die "--workspace-files は非負整数で指定する: $WORKSPACE_FILES" ;; esac

# --- 検査モード -------------------------------------------------------------
# 生成直後のホスト側検査にも、run 実測後のレーン側検査にも同じコードを使う。
# 「.bin/* が symlink のままか実ファイルとして展開されたか」は #176 の 8/29 コメントが
# 追加した確認項目そのものであり、レーン worktree に対して本モードを回すのが実測の本体。
if [ "$VERIFY" -eq 1 ]; then
  [ -d "$DEST" ] || die "検査対象が存在しない: $DEST"
  NM="$DEST/node_modules"
  if [ -L "$NM" ]; then
    printf 'node_modules\tsymlink\t%s\n' "$(readlink "$NM")"
  elif [ -d "$NM" ]; then
    printf 'node_modules\tdirectory\t-\n'
  else
    printf 'node_modules\tmissing\t-\n'
    printf 'fixture\tinvalid\n'
    exit 0
  fi
  # shellcheck disable=SC2012  # share-prepared-dirs.sh の完全性検証が使う `ls -A | wc -l` と
  # 同じ数え方を意図的に再現するため（find を使うと件数の数え方がずれる）。
  printf 'entries-toplevel\t%s\n' "$(ls -A "$NM" 2>/dev/null | wc -l | tr -d ' ')"
  # .bin 配下の各エントリが symlink のままか実ファイルかを1件ずつ出す。
  # コピー・フォールバックが `-L` で成立したなら realfile になっているはずで、symlink の
  # まま残っていれば共有が symlink 方式で成立したことを意味する。どちらなのかは
  # share-prepared-dirs.sh の linked / copied 行と突き合わせて確定させる。
  if [ -d "$NM/.bin" ]; then
    for e in "$NM"/.bin/*; do
      [ -e "$e" ] || [ -L "$e" ] || continue
      if [ -L "$e" ]; then
        printf 'bin\t%s\tsymlink\t%s\n' "$(basename "$e")" "$(readlink "$e")"
      elif [ -f "$e" ]; then
        printf 'bin\t%s\trealfile\t-\n' "$(basename "$e")"
      else
        printf 'bin\t%s\tother\t-\n' "$(basename "$e")"
      fi
    done
  else
    printf 'bin\t-\tmissing\t-\n'
  fi
  WS="$NM/@fake/my-lib"
  if [ -L "$WS" ]; then
    printf 'workspace\tsymlink\t%s\n' "$(readlink "$WS")"
  elif [ -d "$WS" ]; then
    # shellcheck disable=SC2012  # share-prepared-dirs.sh の完全性検証が使う `ls -A | wc -l` と
    # 同じ数え方を意図的に再現するため（find を使うと件数の数え方がずれる）。
    printf 'workspace\tdirectory\t%s\n' "$(ls -A "$WS" 2>/dev/null | wc -l | tr -d ' ')"
  else
    printf 'workspace\tmissing\t-\n'
  fi
  printf 'disk-kb\t%s\n' "$(du -sk "$NM" 2>/dev/null | cut -f1)"
  printf 'fixture\tchecked\n'
  exit 0
fi

# --- 生成モード -------------------------------------------------------------
# 既存物への上書きを避ける。削除はしない（安全ルール）。
if [ -e "$DEST" ]; then
  [ -d "$DEST" ] || die "生成先が既にディレクトリ以外として存在する: $DEST"
  [ -z "$(ls -A "$DEST" 2>/dev/null)" ] || die "生成先が空でない: $DEST（本スクリプトは削除を行わない。別の場所を指定するか、手動で退避すること）"
fi

mkdir -p "$DEST" || die "生成先を作れない: $DEST"
NM="$DEST/node_modules"

# 依存マニフェスト。share-prepared-dirs.sh のフィンガープリント照合
# （`node_modules yarn.lock package.json`）に実際に使わせるため、中身がダミーでも
# 共有元とレーンで一致していれば判定は本物と同じ経路を通る。
cat > "$DEST/package.json" <<'JSON'
{
  "name": "fake-node-app",
  "private": true,
  "version": "0.0.0",
  "workspaces": ["packages/*"],
  "comment": "dev-workflow issue #176 の実環境測定用の合成プロジェクト。実在のパッケージは含まない"
}
JSON
cat > "$DEST/yarn.lock" <<'LOCK'
# THIS IS A FAKE LOCKFILE -- dev-workflow issue #176 fixture
# yarn lockfile v1
LOCK

# 1. 直下エントリ数を稼ぐダミーパッケージ。コピー完全性検証（ソースと一時ディレクトリの
#    `ls -A` 件数一致）が実データ量で通るかを見るための重り。
mkdir -p "$NM"
i=0
while [ "$i" -lt "$PACKAGES" ]; do
  p="$NM/pkg-$i"
  mkdir -p "$p"
  printf '{"name":"pkg-%s","version":"1.0.0","main":"index.js"}\n' "$i" > "$p/package.json"
  printf 'module.exports = %s;\n' "$i" > "$p/index.js"
  i=$((i + 1))
done

# 2. ファイルへの symlink（本命）。`.bin/*` は実 node プロジェクトならほぼ必ず存在し、
#    `-L` 無しの `cp -a` / `cp -r` はここで部分失敗する（#178 の根拠）。
mkdir -p "$NM/eslint/bin" "$NM/typescript/bin" "$NM/jest/bin" "$NM/.bin"
printf '#!/usr/bin/env node\nconsole.log("fake eslint");\n' > "$NM/eslint/bin/eslint.js"
printf '#!/usr/bin/env node\nconsole.log("fake tsc");\n'    > "$NM/typescript/bin/tsc.js"
printf '#!/usr/bin/env node\nconsole.log("fake jest");\n'   > "$NM/jest/bin/jest.js"
printf '{"name":"eslint","version":"9.0.0"}\n'     > "$NM/eslint/package.json"
printf '{"name":"typescript","version":"5.0.0"}\n' > "$NM/typescript/package.json"
printf '{"name":"jest","version":"29.0.0"}\n'      > "$NM/jest/package.json"

BIN_LINKS_OK=1
ln -s "../eslint/bin/eslint.js"  "$NM/.bin/eslint" 2>/dev/null || BIN_LINKS_OK=0
ln -s "../typescript/bin/tsc.js" "$NM/.bin/tsc"    2>/dev/null || BIN_LINKS_OK=0
ln -s "../jest/bin/jest.js"      "$NM/.bin/jest"   2>/dev/null || BIN_LINKS_OK=0

# 3. ディレクトリへの symlink（yarn workspace 相当）。`-L` はこの実体を丸ごと重複コピー
#    するため、ディスク使用量増加の観測点になる（ADR-0007 の未実測項目）。
mkdir -p "$DEST/packages/my-lib/src" "$NM/@fake"
printf '{"name":"@fake/my-lib","version":"1.0.0"}\n' > "$DEST/packages/my-lib/package.json"
j=0
while [ "$j" -lt "$WORKSPACE_FILES" ]; do
  printf 'export const v%s = %s;\n' "$j" "$j" > "$DEST/packages/my-lib/src/mod-$j.js"
  j=$((j + 1))
done
WS_LINK_OK=1
ln -s "../../packages/my-lib" "$NM/@fake/my-lib" 2>/dev/null || WS_LINK_OK=0

# 4. 循環シンボリックリンク（明示指定時のみ）。祖先を指す symlink を1本だけ作り、
#    COPY_CYCLE_GUARD_CAP=80 の事前検査が発火して copy-cycle-guard で確定するかを見る。
CYCLE_LINK_OK="-"
if [ "$WITH_CYCLE" -eq 1 ]; then
  mkdir -p "$NM/cycle-pkg"
  CYCLE_LINK_OK=1
  ln -s "../.." "$NM/cycle-pkg/self" 2>/dev/null || CYCLE_LINK_OK=0
fi

# 生成結果の要約（機械可読）。symlink が本当に symlink として作れたかを必ず出す:
# Windows のホスト側 Git Bash は既定で `ln -s` をコピーに落とすことがあり、その状態の
# fixture では測定対象（ファイル／ディレクトリへの symlink）が最初から存在しないため、
# 測定そのものが無効になる。
printf 'dest\t%s\n' "$DEST"
printf 'packages\t%s\n' "$PACKAGES"
# shellcheck disable=SC2012  # share-prepared-dirs.sh の完全性検証が使う `ls -A | wc -l` と
# 同じ数え方を意図的に再現するため（find を使うと件数の数え方がずれる）。
printf 'entries-toplevel\t%s\n' "$(ls -A "$NM" | wc -l | tr -d ' ')"
printf 'workspace-files\t%s\n' "$WORKSPACE_FILES"
printf 'disk-kb\t%s\n' "$(du -sk "$NM" 2>/dev/null | cut -f1)"

BIN_REAL_SYMLINK=0
[ -L "$NM/.bin/eslint" ] && BIN_REAL_SYMLINK=1
WS_REAL_SYMLINK=0
[ -L "$NM/@fake/my-lib" ] && WS_REAL_SYMLINK=1
printf 'bin-symlinks-created\t%s\n' "$BIN_LINKS_OK"
printf 'bin-is-real-symlink\t%s\n' "$BIN_REAL_SYMLINK"
printf 'workspace-symlink-created\t%s\n' "$WS_LINK_OK"
printf 'workspace-is-real-symlink\t%s\n' "$WS_REAL_SYMLINK"
printf 'cycle-symlink-created\t%s\n' "$CYCLE_LINK_OK"

if [ "$BIN_REAL_SYMLINK" -eq 1 ] && [ "$WS_REAL_SYMLINK" -eq 1 ]; then
  printf 'fixture\tvalid\n'
  exit 0
fi

# 無効な fixture のまま測定に進ませない。ホスト側で symlink を作れない場合の対処は、
# コンテナ内から同じスクリプトを走らせること（バインドマウント配下への `ln -s` は
# ADR-0007 のサンドボックス確認では成功している。それが Windows 実環境で実際に
# どうなるかを見ること自体が #176 の主眼でもある）。
printf 'fixture\tinvalid\n'
{
  echo "警告: symlink が symlink として作成できていない（ホスト側 Git Bash が ln -s をコピーに落とした可能性）。"
  echo "この fixture では .bin / workspace の symlink が存在せず、#176 の測定対象そのものが欠ける。"
  echo "対処: 生成先を空にしてから、コンテナ内で本スクリプトを実行する:"
  echo "  bash scripts/sandbox-exec.sh --epic <epic> -- bash tests/fixtures/make-fake-node-project.sh --dest <コンテナ内パス>"
  echo "または Git Bash 側で MSYS=winsymlinks:nativestrict を設定し、開発者モードを有効にして再実行する。"
} >&2
exit 0
