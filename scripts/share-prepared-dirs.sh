#!/bin/bash
# dev-workflow: 準備成果ディレクトリ（node_modules 等）をレーンへ symlink で共有する（ベンダー中立）
#
# `/dev-workflow:run` の並列レーンでは、generator の isolation worktree がタスクごとに新規作成
# される（作るのはハーネスであり、dev-workflow 側から再利用させる手段は無い）。そのため node 系
# プロジェクトではレーンごとに `yarn install` がフル実行され、Windows + Docker Desktop の
# バインドマウント上では1回20〜40分かかる（issue #104。実測で run 総所要 5.5h の半分以上）。
#
# Epic 専用 worktree には準備コマンドが1回だけ実行されており、その成果（`node_modules` 等）は
# 既に存在する。これをレーンへ symlink で共有すればレーンでの install は不要になる。
# 判定を散文で generator に委ねると取りこぼすため、本スクリプトに固定する。
#
# 本スクリプトは共有モード（既定モード）・`--detach`（#110）・ロック兼完了マーカーと
# `--run-prep`（#111）を実装する。
#
# --detach は共有モードの逆操作である。依存マニフェスト（package.json / yarn.lock 等）を
# 変更するタスクは、install 前に共有リンクを解除しないと symlink 越しに共有元と他レーンの
# 成果を壊す（issue #104 と同種の壊れ方を、共有によってより広範囲に起こしうる）。
# `--detach` はレーン側 <dir> が symlink のときだけ unlink する。symlink でない実体
# ディレクトリには絶対に触れない（skip reason not-a-link として保護する）。
#
# 使い方（レーンの作業ディレクトリをカレントディレクトリとして呼び出す前提）:
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> \
#       --spec "$(cat <<'SPEC'
#   node_modules  yarn.lock package.json
#   SPEC
#       )"
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> \
#       --dir "node_modules yarn.lock package.json" --dir ".venv requirements.txt"
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> --epic epic105 --dry-run ...
#   bash scripts/share-prepared-dirs.sh --detach --dir node_modules --dir .venv
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> --dir "node_modules yarn.lock" \
#       --run-prep "yarn install --frozen-lockfile"
#
# オプション:
#   --source <path>   共有元（Epic 専用 worktree）のパス。必須（--detach 時は不要）
#   --spec <text>     共有対象の指定。複数行可（1行1エントリ）。複数回指定すると連結される
#   --dir <text>      --spec の1行分を追加する（繰り返し可）
#   --epic <識別子>   sandbox-exec.sh に渡す --epic（例 epic105）。省略可
#   --dry-run         symlink を実際には作らず判定結果だけを出す。ロック（後述）の
#                     取得・`done` の書き込みも行わない（プレビューのため状態を変えない）
#   --detach          共有モードの逆操作（#110）。依存マニフェストを変更するタスクが
#                     install 前に共有リンクを解除するために使う。--source は不要で、
#                     --dir が1つ以上必要。symlink の解除のみを行い、実体ディレクトリ
#                     には絶対に触れない（skip reason not-a-link として保護する）。
#                     --detach にはロック（後述）は適用されない
#   --force           残存ロック（`done` が無いロックディレクトリ）を無視して続行する（#111）
#   --run-prep <cmd>  共有の判定結果が prep=run のときだけ、渡されたコマンドをレーンの
#                     作業ディレクトリで実行する（#111）。詳細は後述
#
# エントリの行書式（空白区切り、すべてリポジトリルート相対。空行と # 始まりの行は無視する）:
#   <共有するディレクトリ> [<フィンガープリントファイル> ...]
#   例: node_modules  yarn.lock package.json
#
# 出力（1行1件・タブ区切り・機械可読。最後に必ず prep= 行を1行出す）:
#   linked	<dir>	<symlinkのターゲット（レーンからの相対パス）>
#   skip	<dir>	reason	<no-source|exists|fingerprint-mismatch|link-failed>
#   prep=<skip|run>
#
# 全エントリが linked または exists なら prep=skip、1つでもそれ以外があれば prep=run。
# --dry-run でも linked 行を出すが実際には作らない
# （scripts/cleanup-lane-worktrees.sh の removed 行が「削除予定」を表す既存慣習に合わせる）。
#
# 出力（--detach。1行1件・タブ区切り。prep= 行は出さない。エントリは <dir> のみ使い、
# --dir の2番目以降のフィールド（フィンガープリントファイル）は無視する）:
#   detached	<dir>
#   skip	<dir>	reason	<not-a-link|absent>
#
# --detach の判定順序:
#   1. レーン側 <dir> が symlink である              -> unlink して detached
#      （--dry-run 指定時は実際には解除せず detached だけを出す）
#   2. symlink ではないが存在する（実体ディレクトリ等） -> skip reason not-a-link（触れない）
#   3. 存在しない                                    -> skip reason absent
#
# エントリごとの判定順序（共有モード）:
#   1. <source>/<dir> が存在しない（ディレクトリでない）      -> no-source
#   2. レーン側 <dir> が既に存在する（symlink・実体を問わない） -> exists
#   3. フィンガープリントファイルの欠損・不一致が1つでもある   -> fingerprint-mismatch
#   4. symlink を作り、作った symlink を辿った実体がディレクトリであることまで確認する
#      （`ln -s` はターゲットが存在しなくても成功するため、作成成功だけでは
#      dangling symlink を linked と誤報告しうる。#115）。成功なら linked、
#      作成失敗または実体確認に失敗した場合は                -> link-failed
#
# フィンガープリントの比較は素のファイル読み取りだけで済むためホスト側で行う
# （フィンガープリント未指定のエントリは検査しない）。
#
# symlink の作成と存在判定はコンテナ内で行う（重要）。ホストが Windows（Git Bash）の場合、
# `ln -s` が実体コピーになる・`test -L` が誤判定する等でホスト側からは扱えないためである。
# コンテナへの投入は scripts/sandbox-exec.sh 経由で行い、環境変数 DEV_WORKFLOW_SANDBOX_EXEC
# （既定: 本スクリプトと同じディレクトリの sandbox-exec.sh）で差し替えられるようにする。
# 単体テストはこの差し替えでスタブを刺し、Docker に依存せず検証する
# （tests/run-tests.sh は Docker を一切呼ばない方針）。
# コンテナへの投入は1回にまとめる（エントリごとに docker exec を往復させない）。
#
# symlink のターゲットは、レーン worktree から共有元への相対パスで張る。絶対パスにすると
# ホストとコンテナでパスが異なり解決できない。symlink のターゲットはリンク自身の親ディレクトリ
# 基準で解決されるため、<dir> がネストしている場合（例: packages/app/node_modules。行書式は
# リポジトリルート相対であり、モノレポでは主要な用途）は、レーン worktree 基準の相対パスに
# <dir> の "/" の個数ぶん "../" を追加で前置してリンク位置基準に補正する（#115）。
# 相対パスが計算できない場合（共有元がリポジトリ
# ルート外。実装上はカレントディレクトリと共有元が同じドライブ/ルートを共有しない場合）は
# link-failed として扱う。
#
# ロック兼完了マーカー（#111。共有モードのみ。--detach には適用されない）:
#
# issue #104 では、generator が同一 worktree に2本目の準備コマンド（`yarn install` 等）を
# 並行実行し、ネイティブバイナリを破損させた。「同一 worktree で準備は初回1回だけ」という
# 規約（Task #94）は散文でしかなく強制力が無いため、本スクリプトの構造で固定する。
#
# 対象はレーンの作業ディレクトリ単位。`git rev-parse --git-dir` が返すディレクトリ配下の
# `dev-workflow-prep.lock`（ディレクトリ）を `mkdir` で作って取得する（`mkdir` はアトミック）。
# 作業ツリー内にロックを置かないのは、`git status` を汚し可読性ガードやコミット対象に
# 混ざるのを避けるためである（`.git` 配下は git の追跡対象外）。
#   - `mkdir` に成功                        -> 自分が初回。処理を行い、成功したときだけ
#                                              ロックディレクトリ内に `done` ファイルを書く
#                                              （`--run-prep` のコマンドが失敗した場合は
#                                              「処理が完了していない」ので書かない）
#   - `mkdir` に失敗し、中に `done` がある   -> 準備済み。prep=done-already を出して exit 0。
#                                              symlink 作成も準備コマンド実行も行わない
#   - `mkdir` に失敗し、`done` が無い        -> 実行中（または異常終了で残った残骸）。
#                                              待たずに exit 3 で停止し、ロックパスを
#                                              stderr に出す。`--force` 指定時のみ、この
#                                              「`done` の無い残存ロック」を無視して続行する
#                                              （異常終了後の復旧手段）
#
# **ロックディレクトリは削除しない。** 安全ルール（`rm` / `rmdir` を使わない）と整合させる
# ためであり、同時に「同一 worktree で準備は1回だけ」を決定論的に固定する効果を持つ。
# 異常終了で `done` の無いロックが残り以降 exit 3 になり続けるのは意図した挙動である
# （黙って2本目を走らせて事故るより、明示的に停止して人間に判断させる。復旧には `--force`
# を使う）。
#
# `git rev-parse --git-dir` が失敗する場合（レーンの作業ディレクトリが git リポジトリでない。
# 実運用では起こらないが、素の一時ディレクトリでの検証等）はロックを適用せず、既存の
# 共有モード（#106）どおりに動作する。
#
# `--run-prep <cmd>`:
#   - prep=run のときだけ、渡されたコマンドをレーンの作業ディレクトリで実行する。
#     prep=skip / prep=done-already のときは実行しない
#   - 実行は `DEV_WORKFLOW_SANDBOX_EXEC`（既定: 本スクリプトと同じディレクトリの
#     sandbox-exec.sh）経由で行う。**`--warm` は使わない**（終了コードが必要なため）
#   - コマンドが失敗したら exit 4 で停止し、`done` マーカーを作らない
#     （準備が完了していないため。次回呼び出しは実行中ロックとして exit 3 になり、
#     `--force` での再試行が明示的に必要になる）
#   - `--run-prep` を渡さなかった場合は何も実行しない（prep=run を出して exit 0）
#   - `--dry-run` 指定時は実行しない
#   - **エントリが複数あり一部だけ linked・残りが no-source 等で prep=run になった場合、
#     コマンドを実行する直前にその linked 済みエントリの共有symlinkを全て解除してから
#     実行する（Review #116）。** linked 済みの symlink を張ったまま準備コマンド
#     （`yarn install` 等）を実行すると、install はレーンの `<dir>`（= 共有元 Epic 専用
#     worktree への symlink）へ書き込むため、共有元と他レーンが参照している実体を
#     書き換えてしまう（issue #104 の『同一 node_modules への並行 install によるネイティブ
#     バイナリ破損』を、レーンをまたいでより広範囲に再現しうる）。エントリが1件のみ
#     （全件 linked または全件 non-linked）の場合はこの解除は発生しない。
#     解除はコマンド実行と同じコンテナ呼び出し内で `unlink <dir> && ...` として前置する
#     （コンテナ呼び出しを増やさないため）。解除に失敗した場合はコマンド自体を実行せず、
#     以降の失敗時と同じ扱い（exit 4、`done` を作らない）にする。
#     全件 linked でなければ全件 prep=run に倒す（all-or-nothing）方式は採らなかった。
#     `--run-prep` を渡さない呼び出し（#106 の複数エントリ混在ケース等）では、混在バッチ
#     でも個々の共有可否をそのまま `linked`/`skip` 行で報告する既存の挙動を変えないため。
#
# 終了コード:
#   0 = 正常終了（共有モードは prep= 行で成否を判断する。--detach に prep= 行は無い）
#   2 = 引数エラー（--source 欠落（共有モード）、--dir 皆無（--detach）、
#       値なしのオプション、未知のオプション等）
#   3 = ロック競合（同一 worktree で既に準備が実行中。#111）
#   4 = --run-prep に渡したコマンドが失敗した（#111）
#
# 安全ルール:
#   - 削除コマンド（rm / rmdir）を使わない
#   - 追加の依存物（jq 等）を要求しない。素の bash / git / grep / sed のみで完結させる

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_EXEC="${DEV_WORKFLOW_SANDBOX_EXEC:-${SCRIPT_DIR}/sandbox-exec.sh}"

SOURCE=""
EPIC=""
DRY_RUN=0
DETACH=0
FORCE=0
RUN_PREP=""
RAW_LINES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      if [ $# -lt 2 ]; then
        echo "ERROR: --source には値が必要です" >&2
        exit 2
      fi
      SOURCE="$2"; shift 2 ;;
    --spec)
      if [ $# -lt 2 ]; then
        echo "ERROR: --spec には値が必要です" >&2
        exit 2
      fi
      while IFS= read -r _spec_line; do
        RAW_LINES+=("$_spec_line")
      done <<< "$2"
      shift 2 ;;
    --dir)
      if [ $# -lt 2 ]; then
        echo "ERROR: --dir には値が必要です" >&2
        exit 2
      fi
      RAW_LINES+=("$2"); shift 2 ;;
    --epic)
      if [ $# -lt 2 ]; then
        echo "ERROR: --epic には値が必要です" >&2
        exit 2
      fi
      EPIC="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --detach) DETACH=1; shift ;;
    --force) FORCE=1; shift ;;
    --run-prep)
      if [ $# -lt 2 ]; then
        echo "ERROR: --run-prep には値が必要です" >&2
        exit 2
      fi
      RUN_PREP="$2"; shift 2 ;;
    -*) echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
    *)  echo "ERROR: 未知の引数: $1" >&2; exit 2 ;;
  esac
done

if [ "$DETACH" -eq 0 ] && [ -z "$SOURCE" ]; then
  echo "ERROR: --source は必須です" >&2
  exit 2
fi

CWD="$(pwd)"

# ---------------------------------------------------------------------------
# エントリの解析（--spec / --dir から集めた RAW_LINES を分解する）。
# 空行・# 始まりの行は無視する。read -ra は先頭・末尾の空白を自然に落とすため、
# 個別に trim する必要が無い。
# ---------------------------------------------------------------------------

ENTRY_DIRS=()
ENTRY_FILES=()

for _raw in "${RAW_LINES[@]:-}"; do
  [ -z "${_raw+x}" ] && continue
  _raw="${_raw%$'\r'}"
  read -ra _fields <<< "$_raw"
  [ "${#_fields[@]}" -eq 0 ] && continue
  case "${_fields[0]}" in
    "#"*) continue ;;
  esac
  ENTRY_DIRS+=("${_fields[0]}")
  ENTRY_FILES+=("${_fields[*]:1}")
done

if [ "$DETACH" -eq 1 ] && [ "${#ENTRY_DIRS[@]}" -eq 0 ]; then
  echo "ERROR: --detach には --dir が1つ以上必要です" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# 共有元からレーン（カレントディレクトリ）への相対パスを計算する（純粋な文字列処理。
# cd で正規化するため、両ディレクトリが実在すれば十分で、対象の <dir> 自体の存在は問わない）。
# ---------------------------------------------------------------------------

compute_rel_path() {
  # compute_rel_path <from_dir> <to_dir>  <from_dir> から <to_dir> への相対パスを出力する
  local from="$1" to="$2"
  local from_abs to_abs
  from_abs="$(cd "$from" 2>/dev/null && pwd)" || return 1
  to_abs="$(cd "$to" 2>/dev/null && pwd)" || return 1
  [ -n "$from_abs" ] && [ -n "$to_abs" ] || return 1

  local IFS=/
  local -a fparts=() tparts=()
  local p
  # shellcheck disable=SC2086  # IFS=/ による意図的な単語分割
  for p in $from_abs; do [ -n "$p" ] && fparts+=("$p"); done
  for p in $to_abs; do [ -n "$p" ] && tparts+=("$p"); done

  # 先頭要素（ドライブレター等のルート）が異なる場合は同一ファイルシステム上に無いとみなす
  if [ "${#fparts[@]}" -gt 0 ] && [ "${#tparts[@]}" -gt 0 ] \
    && [ "${fparts[0]}" != "${tparts[0]}" ]; then
    return 1
  fi

  local i=0
  while [ "$i" -lt "${#fparts[@]}" ] && [ "$i" -lt "${#tparts[@]}" ] \
    && [ "${fparts[$i]}" = "${tparts[$i]}" ]; do
    i=$((i + 1))
  done

  local up=$(( ${#fparts[@]} - i ))
  local rel="" j
  for ((j = 0; j < up; j++)); do rel="${rel}../"; done
  for ((j = i; j < ${#tparts[@]}; j++)); do rel="${rel}${tparts[$j]}/"; done
  rel="${rel%/}"
  [ -z "$rel" ] && rel="."
  printf '%s' "$rel"
}

if [ "$DETACH" -eq 0 ]; then

# ---------------------------------------------------------------------------
# ロック兼完了マーカー（#111）。--dry-run はプレビューのため状態を変えない
# （ロックの取得も done の書き込みも行わず、既存の共有モードどおりに動作する）。
# `git rev-parse --git-dir` が失敗する場合（レーンの作業ディレクトリが git リポジトリで
# ない）もロックを適用せず、既存の共有モードどおりに動作する。
# ---------------------------------------------------------------------------

LOCK_ELIGIBLE=0
LOCK_STATE="no-lock"
LOCK_DIR=""

if [ "$DRY_RUN" -eq 0 ]; then
  GIT_DIR_RAW="$(git rev-parse --git-dir 2>/dev/null)"
  if [ -n "$GIT_DIR_RAW" ]; then
    GIT_DIR_ABS="$(cd "$GIT_DIR_RAW" 2>/dev/null && pwd)"
    if [ -n "$GIT_DIR_ABS" ]; then
      LOCK_ELIGIBLE=1
      LOCK_DIR="${GIT_DIR_ABS}/dev-workflow-prep.lock"
    fi
  fi
fi

if [ "$LOCK_ELIGIBLE" -eq 1 ]; then
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_STATE="fresh"
  elif [ -f "${LOCK_DIR}/done" ]; then
    LOCK_STATE="done-already"
  elif [ "$FORCE" -eq 1 ]; then
    LOCK_STATE="forced"
  else
    LOCK_STATE="conflict"
  fi
fi

case "$LOCK_STATE" in
  done-already)
    printf 'prep=done-already\n'
    exit 0 ;;
  conflict)
    echo "ERROR: 同一 worktree で準備が既に実行中です（${LOCK_DIR}）" >&2
    exit 3 ;;
esac

REL_SOURCE=""
REL_SOURCE_OK=0
if [ -d "$SOURCE" ]; then
  if REL_SOURCE="$(compute_rel_path "$CWD" "$SOURCE")"; then
    REL_SOURCE_OK=1
  fi
fi

# ---------------------------------------------------------------------------
# エントリごとの判定（1: no-source, 3: fingerprint はここでホスト側で決める。
# 2: exists, 4: link/link-failed はコンテナ側で決める）。
# ---------------------------------------------------------------------------

RESULT_KIND=()    # linked|exists|no-source|fingerprint-mismatch|link-failed（ENTRY_DIRSと同じ添字）
RESULT_TARGET=()  # linked のときだけ意味を持つ

CANDIDATE_ORIG_IDX=()
CANDIDATE_DIR=()
CANDIDATE_TARGET=()
CANDIDATE_FPOK=()

for idx in "${!ENTRY_DIRS[@]}"; do
  dir="${ENTRY_DIRS[$idx]}"
  files="${ENTRY_FILES[$idx]}"

  if [ ! -d "${SOURCE}/${dir}" ]; then
    RESULT_KIND[idx]="no-source"
    RESULT_TARGET[idx]=""
    continue
  fi

  # フィンガープリント比較（ホスト側。素のファイル読み取りだけで済む）。
  fp_ok=1
  if [ -n "$files" ]; then
    # shellcheck disable=SC2086  # files は空白区切りの複数ファイル名。意図的な単語分割
    for f in $files; do
      if [ ! -f "${SOURCE}/${f}" ] || [ ! -f "$f" ]; then
        fp_ok=0; break
      fi
      if ! cmp -s "${SOURCE}/${f}" "$f"; then
        fp_ok=0; break
      fi
    done
  fi

  if [ "$REL_SOURCE_OK" -eq 1 ]; then
    # symlink のターゲットは、リンク自身（$CWD/$dir）の親ディレクトリ基準で解決される。
    # REL_SOURCE は $CWD 基準の相対パスのため、<dir> がネストしている場合
    # （例: packages/app/node_modules）はリンクの親ディレクトリが $CWD より深い分だけ
    # 余分に "../" を前置しないと誤ったターゲットになる（#115）。前置する数は <dir> に
    # 含まれる "/" の個数（= リンクの親ディレクトリが $CWD から何段深いか）と一致する。
    _dir_slashes="${dir//[^\/]/}"
    _up_prefix=""
    for ((_up_i = 0; _up_i < ${#_dir_slashes}; _up_i++)); do
      _up_prefix+="../"
    done
    target="${_up_prefix}${REL_SOURCE}/${dir}"
  else
    target=""
  fi

  CANDIDATE_ORIG_IDX+=("$idx")
  CANDIDATE_DIR+=("$dir")
  CANDIDATE_TARGET+=("$target")
  CANDIDATE_FPOK+=("$fp_ok")
done

# ---------------------------------------------------------------------------
# コンテナへの投入（1回にまとめる）。exists 判定と symlink 作成（または --dry-run 時は
# 判定のみ）を、候補エントリ全件分のミニスクリプトとして1回の sandbox-exec.sh 呼び出しに
# まとめる。
# ---------------------------------------------------------------------------

if [ "${#CANDIDATE_DIR[@]}" -gt 0 ]; then
  CONTAINER_SCRIPT="set -u"$'\n'
  # shellcheck disable=SC2016  # 単一引用符は意図的。$d/$t はここでは展開せず、
  # コンテナ側で実行されるミニスクリプトの文字列としてそのまま埋め込む。
  for i in "${!CANDIDATE_DIR[@]}"; do
    d="${CANDIDATE_DIR[$i]}"
    t="${CANDIDATE_TARGET[$i]}"
    fpok="${CANDIDATE_FPOK[$i]}"
    CONTAINER_SCRIPT+="d=$(printf '%q' "$d")"$'\n'
    CONTAINER_SCRIPT+="t=$(printf '%q' "$t")"$'\n'
    CONTAINER_SCRIPT+='if [ -e "$d" ] || [ -L "$d" ]; then'$'\n'
    CONTAINER_SCRIPT+='  printf "exists\t%s\n" "$d"'$'\n'
    CONTAINER_SCRIPT+="elif [ ${fpok} -ne 1 ]; then"$'\n'
    CONTAINER_SCRIPT+='  printf "fpmismatch\t%s\n" "$d"'$'\n'
    CONTAINER_SCRIPT+='elif [ -z "$t" ]; then'$'\n'
    CONTAINER_SCRIPT+='  printf "linkfailed\t%s\n" "$d"'$'\n'
    CONTAINER_SCRIPT+='else'$'\n'
    if [ "$DRY_RUN" -eq 1 ]; then
      CONTAINER_SCRIPT+='  printf "linked\t%s\t%s\n" "$d" "$t"'$'\n'
    else
      CONTAINER_SCRIPT+='  if ln -s "$t" "$d" 2>/dev/null && [ -d "$d" ]; then'$'\n'
      CONTAINER_SCRIPT+='    printf "linked\t%s\t%s\n" "$d" "$t"'$'\n'
      CONTAINER_SCRIPT+='  else'$'\n'
      CONTAINER_SCRIPT+='    printf "linkfailed\t%s\n" "$d"'$'\n'
      CONTAINER_SCRIPT+='  fi'$'\n'
    fi
    CONTAINER_SCRIPT+='fi'$'\n'
  done

  SANDBOX_ARGS=()
  [ -n "$EPIC" ] && SANDBOX_ARGS+=(--epic "$EPIC")

  CONTAINER_OUTPUT="$(bash "$SANDBOX_EXEC" "${SANDBOX_ARGS[@]}" "$CONTAINER_SCRIPT")"

  cand_i=0
  # 2カラム目（dir名）はCANDIDATE_ORIG_IDX側で既知のため使わない。read の3カラム形式
  # （kind\tdir\ttarget）に合わせるためだけに受け取る。
  # shellcheck disable=SC2034
  while IFS=$'\t' read -r kind _dir b; do
    [ -z "$kind" ] && continue
    [ "$cand_i" -lt "${#CANDIDATE_ORIG_IDX[@]}" ] || break
    orig_idx="${CANDIDATE_ORIG_IDX[$cand_i]}"
    case "$kind" in
      exists)     RESULT_KIND[orig_idx]="exists" ;;
      fpmismatch) RESULT_KIND[orig_idx]="fingerprint-mismatch" ;;
      linkfailed) RESULT_KIND[orig_idx]="link-failed" ;;
      linked)     RESULT_KIND[orig_idx]="linked"; RESULT_TARGET[orig_idx]="$b" ;;
      *)          RESULT_KIND[orig_idx]="link-failed" ;;
    esac
    cand_i=$((cand_i + 1))
  done <<< "$CONTAINER_OUTPUT"

  # コンテナ呼び出しが失敗して出力が想定件数に満たない場合、未確定分は安全側
  # （link-failed）で確定させる。
  while [ "$cand_i" -lt "${#CANDIDATE_ORIG_IDX[@]}" ]; do
    orig_idx="${CANDIDATE_ORIG_IDX[$cand_i]}"
    RESULT_KIND[orig_idx]="link-failed"
    cand_i=$((cand_i + 1))
  done
fi

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------

PREP="skip"
for idx in "${!ENTRY_DIRS[@]}"; do
  kind="${RESULT_KIND[$idx]:-link-failed}"
  if [ "$kind" = "linked" ]; then
    printf 'linked\t%s\t%s\n' "${ENTRY_DIRS[$idx]}" "${RESULT_TARGET[$idx]:-}"
  else
    printf 'skip\t%s\treason\t%s\n' "${ENTRY_DIRS[$idx]}" "$kind"
    [ "$kind" = "exists" ] || PREP="run"
  fi
done

# ---------------------------------------------------------------------------
# --run-prep（#111）。prep=run のときだけ実行する。--dry-run 指定時は実行しない。
#
# エントリが複数あり一部だけ linked（残りが no-source 等）で prep=run になった場合、
# linked 済みの共有symlinkを張ったままコマンドを実行すると共有元へ書き込んでしまう
# （Review #116。詳細は冒頭コメント参照）。そのため、linked 済みエントリを解除する
# `unlink` を実行対象コマンドの前に連結し、同じコンテナ呼び出し1回にまとめて実行する。
# `&&` で連結するため、解除に1つでも失敗すれば本体のコマンドは実行されず、
# 呼び出し全体が非0終了して以降の失敗時処理（exit 4、doneを作らない）に合流する。
# ---------------------------------------------------------------------------

RUN_PREP_RAN=0
RUN_PREP_EXIT=0
if [ -n "$RUN_PREP" ] && [ "$PREP" = "run" ] && [ "$DRY_RUN" -eq 0 ]; then
  RUN_PREP_RAN=1

  RUN_PREP_UNLINK_PREFIX=""
  for idx in "${!ENTRY_DIRS[@]}"; do
    if [ "${RESULT_KIND[$idx]:-}" = "linked" ]; then
      RUN_PREP_UNLINK_PREFIX+="unlink $(printf '%q' "${ENTRY_DIRS[$idx]}") && "
    fi
  done
  RUN_PREP_CMD="${RUN_PREP_UNLINK_PREFIX}${RUN_PREP}"

  RUN_PREP_SANDBOX_ARGS=()
  [ -n "$EPIC" ] && RUN_PREP_SANDBOX_ARGS+=(--epic "$EPIC")
  bash "$SANDBOX_EXEC" "${RUN_PREP_SANDBOX_ARGS[@]}" "$RUN_PREP_CMD"
  RUN_PREP_EXIT=$?
fi

printf 'prep=%s\n' "$PREP"

if [ "$RUN_PREP_RAN" -eq 1 ] && [ "$RUN_PREP_EXIT" -ne 0 ]; then
  echo "ERROR: --run-prep のコマンドが失敗しました（exit ${RUN_PREP_EXIT}）" >&2
  exit 4
fi

# 成功したのでロック取得済みなら done マーカーを書く（#111）。
if [ "$LOCK_ELIGIBLE" -eq 1 ]; then
  printf '' > "${LOCK_DIR}/done" 2>/dev/null || true
fi

exit 0

fi

# ---------------------------------------------------------------------------
# --detach: 共有モードの逆操作（#110）。レーン側 <dir> が symlink であれば解除する。
# 判定・解除はコンテナ内で行う（共有モードと同じ理由。ホストが Windows（Git Bash）の場合、
# コンテナ内から作られた symlink をホスト側の test -L が正しく判定できない）。
# symlink でない実体には絶対に触れない（not-a-link として保護し、削除しない）。
# コンテナへの投入は1回にまとめる（エントリごとに docker exec を往復させない）。
# --dry-run 指定時は detached 行を出すが実際には解除しない（共有モードの linked と同じ慣習）。
# ---------------------------------------------------------------------------

if [ "$DETACH" -eq 1 ]; then

DETACH_SCRIPT="set -u"$'\n'
# shellcheck disable=SC2016  # 単一引用符は意図的。$d はここでは展開せず、
# コンテナ側で実行されるミニスクリプトの文字列としてそのまま埋め込む。
for dir in "${ENTRY_DIRS[@]}"; do
  DETACH_SCRIPT+="d=$(printf '%q' "$dir")"$'\n'
  DETACH_SCRIPT+='if [ -L "$d" ]; then'$'\n'
  if [ "$DRY_RUN" -eq 1 ]; then
    DETACH_SCRIPT+='  printf "detached\t%s\n" "$d"'$'\n'
  else
    DETACH_SCRIPT+='  if unlink "$d" 2>/dev/null; then'$'\n'
    DETACH_SCRIPT+='    printf "detached\t%s\n" "$d"'$'\n'
    DETACH_SCRIPT+='  else'$'\n'
    DETACH_SCRIPT+='    printf "skip\t%s\treason\tunlink-failed\n" "$d"'$'\n'
    DETACH_SCRIPT+='  fi'$'\n'
  fi
  DETACH_SCRIPT+='elif [ -e "$d" ]; then'$'\n'
  DETACH_SCRIPT+='  printf "skip\t%s\treason\tnot-a-link\n" "$d"'$'\n'
  DETACH_SCRIPT+='else'$'\n'
  DETACH_SCRIPT+='  printf "skip\t%s\treason\tabsent\n" "$d"'$'\n'
  DETACH_SCRIPT+='fi'$'\n'
done

SANDBOX_ARGS=()
[ -n "$EPIC" ] && SANDBOX_ARGS+=(--epic "$EPIC")

bash "$SANDBOX_EXEC" "${SANDBOX_ARGS[@]}" "$DETACH_SCRIPT"
exit $?

fi
