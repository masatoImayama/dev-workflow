#!/bin/bash
# dev-workflow: Task issue が宣言した依存関係からウェーブ分解を計算する（ベンダー中立）
#
# `dev-workflow:run` のタスク実行を、依存グラフに基づくウェーブ単位の並列実行に切り替えるための
# 決定論の本体（Epic #14 仕様書 5.2）。ウェーブ分解は並列化の「正しさの本体」であり、
# SKILL.md の散文として LLM に実行させると解釈が実行ごとにぶれるため、ここに切り出して
# tests/run-tests.sh で固定する。Docker には一切触れない。
#
# 使い方:
#   bash scripts/plan-waves.sh --epic <Epic issue番号> [--lanes N] [--skipped 4,7] [--print]
#   bash scripts/plan-waves.sh --from-file <TSV> [--lanes N] [--skipped 4,7] [--print]
#
# --epic: 数値の Epic issue 番号（例: 14）。既定の入力は
#         `gh issue list --label task --state open --json number,body --limit 200`。
#         依存先が既に closed（同一 Epic の完了済みタスク）なら充足済み扱いにするため、
#         最初のフェッチに含まれない依存番号は `gh issue view` で個別に state/labels を確認する
#         （task ラベル付き closed のみ充足済み。それ以外は unknown-dep として警告し無視する）。
#
#         Epic 混入対策: 本文の「- Epic: #N」行（`skills/epic/SKILL.md` の Task issue テンプレート、
#         `skills/run/SKILL.md` の Review issue テンプレートが書く行）を見て、指定 Epic の
#         タスクだけを残す。判定は「- Epic: 行の有無」で分岐する:
#           - 行が無い（旧形式の Task issue）        -> 判定不能。フェイルオープンで含める
#           - 行があり #<指定Epic> を含む            -> 含める
#           - 行があり別の #N を含む                 -> 除外する
#           - 行があるが issue 番号を含まない
#             （「- Epic: なし（単発タスク）」等）   -> 除外する。これは「判定不能」ではなく
#             「Epic に属さない」という明示の宣言であり、含めると無関係な実装が Epic ブランチに
#             載る（Task #208 で実データから発覚）
#         `gh issue list --search` は
#         数値・記号をトークン化して "Epic: #3" が "#34" 等にもマッチする誤検出を起こすため
#         （Task #39 対応時に実データで確認済み）、本文の完全一致抽出のみを信頼する。
#
# --from-file: タブ区切り、1行1タスク。テストが GitHub に依存しないようにするための入力差し替え。
#   <issue番号>\t<state: open|closed>\t<前提行の生テキスト（無ければ空文字列）>\t<対象ファイル一覧（無ければ空文字列）>
#   前提行は本文中の「- 前提:」で始まる行そのもの（例: "- 前提: #4, #9（注釈）"）。
#   空文字列は「- 前提: 行そのものが無い」＝宣言漏れを意味する。「- 前提: なし」は
#   明記された0件の依存として扱われ、宣言漏れの警告は出ない。
#   4列目（対象ファイル）はカンマ区切りのファイルパス一覧（例: "scripts/a.sh,docs/b.md"）。
#   空文字列は「## 対象ファイル」節そのものが無い＝宣言漏れを意味する（Task #216）。
#   4列目自体を省略した行（旧形式のフィクスチャ）も同じく空文字列として扱われ、既存Epicとの
#   後方互換を保つ。要素は比較前に正規化される（前後の空白・バッククォート・先頭の "./" を
#   除去。#231）。要素が「なし」（正規化後の完全一致）の場合はその要素を実ファイルパスとして
#   扱わない（対象ファイル0件の明示宣言。core/roles/planner.md「触るファイルが無いタスク」参照）。
#
# --lanes N: 既定3。環境変数 DEV_WORKFLOW_MAX_LANES があればそれを既定にする。
# --skipped: カンマ区切りの issue 番号。それらに依存するタスクは推移的にスキップする。
# --print: 人間向けの表を出す（ドライラン。既定は機械可読な TSV）。
#
# 対象ファイルの重なりによるサブバッチ分割（Task #216、core/roles/planner.md「対象ファイル
# 宣言（## 対象ファイル）の必須化」）:
#   同一ウェーブ内でサブバッチを割り当てる際、対象ファイルが重なる2タスクを同一サブバッチに
#   入れない（依存グラフ＝ウェーブの決定そのものは変えない。あくまでサブバッチ分割の追加制約）。
#   判定は次のとおり:
#     - 両方が宣言済みでファイルが重なる     -> 重なり
#     - 両方が宣言済みでファイルが重ならない -> 従来どおり同居可能
#     - 片方が宣言漏れ・もう片方が宣言済み（1件以上）-> 安全側に倒し重なり扱い
#       （宣言漏れタスクが何を触るか不明なため）
#     - 両方が宣言漏れ                       -> 従来どおり同居可能（後方互換。「## 対象ファイル」
#       導入前の既存Epicで編成が変わらないようにするための扱い）
#     - 片方または両方が「- なし」（対象ファイル0件の明示宣言、#231）のみ  -> 重なりなし
#       （実ファイル0件は何とも重ならない。宣言漏れの安全側ルールは適用しない）
#   ファイルパスの比較前に正規化する（#231）: 前後の空白・バッククォート・先頭の "./" を
#   除去してから比較する。real Task issue にバッククォート付き表記（`` `path` ``）と
#   素のパス表記が混在していても同一ファイルとして検出できるようにするため
#   （正規化しないと表記ゆれにより重なりが検出されず、危険側＝並列実行してしまう）。
#
#   レーン割当は「レーン L には各サブバッチの L 番目（サブバッチ内の昇順順位）のタスクが
#   順に割り当てられる」という位置写像であり（skills/run/SKILL.md Step 3）、サブバッチ間に
#   バリアは無い。そのため「別サブバッチにする」だけでは、たまたま別サブバッチの別順位
#   （＝別レーン）に落ちると並列実行されてしまう（#230）。現在の出力形式（タスクごとの
#   サブバッチ番号のみ。順位はサブバッチ内の昇順順位から事後計算される）では、いったん
#   確定したタスクの順位を後から変更できない。そのため対象ファイルが1件でも重なるタスクは
#   常に「新規かつそのタスク専用のサブバッチ」に単独で入れる。新規サブバッチの先頭（順位1）に
#   単独で入る限り、そのタスクは常に順位1（レーン1）になるため、重なるタスク同士はサブバッチを
#   またいでも必ず同一レーンに落ち、逐次実行が保証される。
#
#   既知の限界（仕様上どうしても保証できない範囲、#230）: 対象ファイルが重ならない独立した
#   複数の「重なりグループ」が同一ウェーブに複数存在する場合、この方式では全グループが
#   レーン1に直列化される（本来は別レーンに割ってよいはずの並列性を犠牲にする）。
#   複数の独立したグループをそれぞれ別レーンに保ったまま安全に並列化するには、サブバッチ内の
#   順位を予約する仕組み（出力形式の拡張）が必要であり、現在のplan-waves.shは対応していない。
#   実効並列度の低下は、最大サブバッチ人数が落ちた場合に限り file-overlap-summary 警告で
#   報告される。最大サブバッチ人数が落ちない場合（例: 独立した複数の重なりグループが
#   同一ウェーブに存在し、分割後もサブバッチ人数の最大値そのものは変わらないケース）は
#   summary が出ないため、警告の有無だけを根拠に実効並列度の低下が無いと判断してはならない
#   （#238）。
#
#   さらに、この宣言は実装前の見積もりであり、実際に触るファイルと乖離しうる。節を書いた
#   （かつファイルが重ならない）からといって競合が起きない保証にはならない。makimaki-sso
#   Epic #1 のウェーブ11では、実際に3レーン中2本が競合して見送りになった実例がある一方、
#   その原因ファイル（tests/run-tests.sh 等）が当該タスクの「## 対象ファイル」節に
#   宣言されていなかった（dev-workflow自身のEpic #212 ウェーブ1でも同種の事例が発生した）。
#   宣言はあくまで見積もりであり、merge-lane.sh の exit 11 による事後検出（共通ルール
#   「失敗時の扱い」参照）は従来どおり残る。
#
# 出力（既定・機械可読、タブ区切り）:
#   lanes	<N>
#   task	<番号>	wave	<W>	subbatch	<S>	deps	<dep1,dep2,...>
#   wave	<W>	tasks	<n1,n2,...>
#   warn	missing-deps	<番号>
#   warn	missing-deps-summary	<宣言漏れ件数>	<対象タスク数>	<実効並列度>	<指定lanes>
#     （宣言漏れが1件以上のときだけ、warn missing-deps の列挙の後に1本だけ出す。
#      実効並列度 = min(指定lanes, 各ウェーブに属するタスク数の最大値)。0件のときは出さない＝後方互換）
#   warn	unknown-dep	<番号>	<未知のdep番号>
#   warn	missing-files	<番号>	（「## 対象ファイル」節が無いタスク。「- 前提:」の欠落と同じ扱い）
#   warn	file-overlap	<番号>	<重なった相手の番号>	<重なったファイル、または宣言漏れなら理由文字列>
#   warn	file-overlap-summary	<分割されたタスク数>	<対象タスク数>	<実効並列度>	<指定lanes>
#     （対象ファイルの重なりによりサブバッチが分割され、かつそれによって実効並列度が
#      「重なりが無かった場合に達成できたはずの並列度」より落ちたときだけ1本出す。
#      実効並列度 = 実際に割り当てられた各(ウェーブ,サブバッチ)組の最大タスク数。0件のときは出さない）
#   skip	<番号>	reason	depends-on-skipped	<依存先番号>
#
# 終了コード: 0=成功 2=引数エラー 3=循環依存（循環に含まれるタスクを stderr に列挙して停止）

set -u

# ---------------------------------------------------------------------------
# 引数解析
# ---------------------------------------------------------------------------

EPIC=""
FROM_FILE=""
LANES="${DEV_WORKFLOW_MAX_LANES:-3}"
SKIPPED_CSV=""
PRINT_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --epic)
      if [ $# -lt 2 ]; then
        echo "ERROR: --epic には値が必要です" >&2
        exit 2
      fi
      EPIC="$2"; shift 2 ;;
    --from-file)
      if [ $# -lt 2 ]; then
        echo "ERROR: --from-file には値が必要です" >&2
        exit 2
      fi
      FROM_FILE="$2"; shift 2 ;;
    --lanes)
      if [ $# -lt 2 ]; then
        echo "ERROR: --lanes には値が必要です" >&2
        exit 2
      fi
      LANES="$2"; shift 2 ;;
    --skipped)
      if [ $# -lt 2 ]; then
        echo "ERROR: --skipped には値が必要です" >&2
        exit 2
      fi
      SKIPPED_CSV="$2"; shift 2 ;;
    --print) PRINT_MODE=1; shift ;;
    -*) echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
    *)  echo "ERROR: 未知の引数: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$EPIC" ] && [ -n "$FROM_FILE" ]; then
  echo "ERROR: --epic と --from-file は同時に指定できません" >&2
  exit 2
fi
if [ -z "$EPIC" ] && [ -z "$FROM_FILE" ]; then
  echo "ERROR: --epic または --from-file のいずれかが必要です" >&2
  exit 2
fi

case "$LANES" in
  ''|*[!0-9]*) echo "ERROR: --lanes は正の整数で指定してください: [${LANES}]" >&2; exit 2 ;;
esac
if [ "$LANES" -lt 1 ]; then
  echo "ERROR: --lanes は1以上で指定してください: [${LANES}]" >&2
  exit 2
fi

if [ -n "$EPIC" ]; then
  case "$EPIC" in
    ''|*[!0-9]*) echo "ERROR: --epic は数値のEpic issue番号で指定してください: [${EPIC}]" >&2; exit 2 ;;
  esac
fi

SOURCE_MODE="file"
[ -n "$EPIC" ] && SOURCE_MODE="gh"

# ---------------------------------------------------------------------------
# タスク登録
# ---------------------------------------------------------------------------

declare -A TASK_STATE   # issue番号 -> open|closed（この番号を知っている＝Epic内 or 個別確認済み）
declare -A DEPS_LINE    # issue番号 -> 前提行の生テキスト（空文字列＝宣言漏れ）
declare -A FILES_LINE   # issue番号 -> 対象ファイル一覧（カンマ区切り。空文字列＝宣言漏れ、Task #216）
PLAN_LIST=()            # ウェーブ計画の対象（state=open のタスク）issue番号の配列

register_task() {
  # register_task <issue番号> <state:open|closed> <前提行の生テキスト> [対象ファイル一覧（カンマ区切り）]
  local num="$1" state="$2" deps_line="$3" files_line="${4:-}"
  TASK_STATE["$num"]="$state"
  DEPS_LINE["$num"]="$deps_line"
  FILES_LINE["$num"]="$files_line"
  if [ "$state" = "open" ]; then
    PLAN_LIST+=("$num")
  fi
}

load_from_file() {
  local file="$1" num state deps_line files_line
  if [ ! -f "$file" ]; then
    echo "ERROR: --from-file で指定されたファイルが見つかりません: ${file}" >&2
    exit 2
  fi
  # タブそのものを区切りに使わず、いったん Unit Separator（0x1f）に変換してから読む。
  # bash の read は tab を「IFS空白文字」として扱うため、3列目（前提行）が空で4列目
  # （対象ファイル）が続く行（Task #216 で追加）だと連続する区切りを1個に畳んでしまい、
  # 4列目の値が3列目にずれる（load_from_gh が同じ理由で \x1f を使っているのと同じ問題）。
  while IFS=$'\x1f' read -r num state deps_line files_line; do
    [ -n "$num" ] || continue
    case "$num" in ''|*[!0-9]*) continue ;; esac
    register_task "$num" "$state" "$deps_line" "$files_line"
  done < <(tr '\t' '\037' < "$file")
}

load_from_gh() {
  # フィールド区切りは @tsv（タブ）ではなく Unit Separator（0x1f）を使う。tab は bash の read が
  # 「IFS空白文字」として連続する区切りを1個に畳んでしまうため、前提行が空でそのあとに
  # Epic行が続く行（実データで頻出）だと3列目が2列目にずれて誤検出する
  # （Task #39 対応時、テスト実装中に実際にこの畳み込みで検出漏れを起こして発覚した）。
  #
  # 「## 対象ファイル」節（Task #216）も同じ jq 呼び出しの中で抽出する（API 呼び出しを
  # 増やさないため）。本文を行配列にし、見出し行のインデックスを探し、次の「## 」見出し
  # （または末尾）までの「- 」で始まる行を集めてカンマ区切りにする。見出しが無ければ
  # 空文字列（＝宣言漏れ）のまま。
  local num deps_line epic_line files_line epic_in_line
  while IFS=$'\x1f' read -r num deps_line epic_line files_line; do
    [ -n "$num" ] || continue
    # 本文の「- Epic:」行の**有無**で分岐する。行が無い（旧形式）ときだけフェイルオープンで含める。
    # 行があるなら、そこから取り出した #N が指定 Epic と一致する場合だけ含める。
    # 「- Epic: なし（単発タスク）」のように issue 番号を持たない宣言は「判定不能」ではなく
    # 「Epic に属さないと明記されている」ため除外する（Task #208 で実データから発覚）。
    if [ -n "$epic_line" ]; then
      epic_in_line="$(printf '%s' "$epic_line" | grep -oE '#[0-9]+' | head -1 | tr -d '#')"
      if [ "$epic_in_line" != "$EPIC" ]; then
        continue
      fi
    fi
    register_task "$num" "open" "$deps_line" "$files_line"
  done < <(
    # shellcheck disable=SC2016  # 単一引用符は意図的。$L/$h/$files/$ln は jq 側の変数で、
    # bash 側で展開してはならない（gojq が -q の引数として自分で解釈する）
    gh issue list --label task --state open --json number,body --limit 200 \
    -q '.[] | ((.body // "") | split("\n")) as $L
      | ($L | index("## 対象ファイル")) as $h
      | (if $h == null then ""
         else
           ($L[($h+1):]
            | reduce .[] as $ln ({done:false, files:[]};
                if .done then .
                elif ($ln | startswith("## ")) then (.done = true)
                elif ($ln | startswith("- ")) then (.files += [$ln[2:]])
                else . end)
            | .files | join(","))
         end) as $files
      | [(.number|tostring), ((.body // "") | split("\n") | map(select(startswith("- 前提:"))) | (.[0] // "")), ((.body // "") | split("\n") | map(select(startswith("- Epic:"))) | (.[0] // "")), $files] | join("\u001f")')
}

if [ "$SOURCE_MODE" = "file" ]; then
  load_from_file "$FROM_FILE"
else
  load_from_gh
fi

# 昇順に整列する（宣言漏れの fail-safe・サブバッチ分割の両方が昇順を前提にするため）
if [ "${#PLAN_LIST[@]}" -gt 0 ]; then
  mapfile -t PLAN_LIST < <(printf '%s\n' "${PLAN_LIST[@]}" | sort -n)
fi

# ---------------------------------------------------------------------------
# 依存解決（宣言漏れの fail-safe・closed 充足・unknown-dep の検出）
# ---------------------------------------------------------------------------

declare -A REAL_DEPS       # issue番号 -> 実際にウェーブ計算へ使う依存（スペース区切り）
MISSING_DEPS_WARN=()       # 宣言漏れの issue 番号
UNKNOWN_DEP_WARN=()        # "issue番号:未知のdep番号"

lookup_external_state() {
  # lookup_external_state <issue番号>
  # 既知でない依存先の state を確認する。gh モードでは task ラベル付き closed のみ
  # 「充足済み」として扱い、それ以外（存在しない／task ラベル無し／open）は空文字列を返す
  # （呼び出し側が unknown-dep として警告する）。from-file モードは常に空文字列。
  local d="$1"
  [ "$SOURCE_MODE" = "gh" ] || { printf ''; return; }
  local raw state_val has_task
  raw="$(gh issue view "$d" --json state,labels \
    -q '[.state, ([.labels[].name] | index("task") != null)] | @tsv' 2>/dev/null)"
  [ -n "$raw" ] || { printf ''; return; }
  IFS=$'\t' read -r state_val has_task <<< "$raw"
  if [ "$has_task" = "true" ] && [ "$state_val" = "CLOSED" ]; then
    register_task "$d" "closed" ""
    printf 'closed'
  else
    printf ''
  fi
}

resolve_task_deps() {
  # resolve_task_deps <issue番号>  REAL_DEPS[番号] を埋める。副作用で警告配列も積む。
  local n="$1"
  local line="${DEPS_LINE[$n]:-}"
  local deps="" m d st nums

  if [ -z "$line" ]; then
    # 「- 前提:」行そのものが無い＝宣言漏れ。fail-safe: 自分より番号が小さい全タスクに依存する。
    MISSING_DEPS_WARN+=("$n")
    for m in "${PLAN_LIST[@]}"; do
      [ "$m" -lt "$n" ] || continue
      deps="${deps}${deps:+ }${m}"
    done
  else
    nums="$(printf '%s' "$line" | grep -oE '#[0-9]+' | tr -d '#')"
    # shellcheck disable=SC2086  # nums は数字の空白区切り列。意図的に単語分割してループする
    for d in $nums; do
      [ "$d" != "$n" ] || continue   # 自己参照は無視する（循環検出に頼らせない）
      st="${TASK_STATE[$d]:-}"
      if [ -z "$st" ]; then
        st="$(lookup_external_state "$d")"
      fi
      case "$st" in
        closed) : ;;                                   # 充足済み。依存として数えない
        open)   deps="${deps}${deps:+ }${d}" ;;
        *)      UNKNOWN_DEP_WARN+=("${n}:${d}") ;;
      esac
    done
  fi
  REAL_DEPS["$n"]="$deps"
}

for _n in "${PLAN_LIST[@]}"; do
  resolve_task_deps "$_n"
done
unset _n

# ---------------------------------------------------------------------------
# 対象ファイル宣言の検査（Task #216。「- 前提:」の宣言漏れ検査と同じ位置づけ）
# ---------------------------------------------------------------------------

MISSING_FILES_WARN=()   # 「## 対象ファイル」節が無い issue 番号

for _n in "${PLAN_LIST[@]}"; do
  if [ -z "${FILES_LINE[$_n]:-}" ]; then
    MISSING_FILES_WARN+=("$_n")
  fi
done
unset _n

normalize_file_token() {
  # normalize_file_token <1件のファイルトークン>
  # 前後の空白・バッククォートの除去、先頭の "./" の除去（#231）。標準出力に正規化済みの
  # トークンを返す。実在 Task issue の表記ゆれ（バッククォート付き/無しの混在、行末の空白、
  # ./ 接頭）を吸収し、同一ファイルが表記違いで「重ならない」と誤判定されるのを防ぐ。
  local t="$1"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  t="${t#\`}"
  t="${t%\`}"
  case "$t" in
    ./*) t="${t#./}" ;;
  esac
  printf '%s' "$t"
}

split_files_normalized() {
  # split_files_normalized <カンマ区切り生文字列>
  # 戻り値は無い。グローバル配列 SPLIT_FILES_RESULT に正規化済みの実ファイルパスだけを積む。
  # 「なし」（正規化後の完全一致。core/roles/planner.md「触るファイルが無いタスク」参照）は
  # 「対象ファイル0件の明示宣言」を意味する予約語として扱い、実ファイルパスとして積まない
  # （#231: 文字列「なし」がパスとして重なり判定に使われ、別タスクの「なし」と誤って
  # 重なり判定されるのを防ぐ）。
  local raw="$1" tok
  SPLIT_FILES_RESULT=()
  [ -n "$raw" ] || return 0
  local arr=()
  IFS=',' read -r -a arr <<< "$raw"
  for tok in "${arr[@]}"; do
    tok="$(normalize_file_token "$tok")"
    [ -n "$tok" ] || continue
    [ "$tok" != "なし" ] || continue
    SPLIT_FILES_RESULT+=("$tok")
  done
}

files_overlap() {
  # files_overlap <task_a> <task_b>
  # 戻り値 0=重なりあり（安全側判定含む。OVERLAP_FILE に理由/ファイル名を積む） 1=重なりなし
  #
  # 判定表（core/roles/planner.md「対象ファイル宣言（## 対象ファイル）の必須化」参照）:
  #   両方宣言済みで重なるファイルがある     -> 重なり（OVERLAP_FILE=そのファイル）
  #   両方宣言済みで重ならない               -> 重なりなし
  #   片方が宣言漏れ・もう片方が1件以上宣言   -> 安全側に倒し重なり扱い（OVERLAP_FILE=理由文字列）
  #   片方が宣言漏れ・もう片方が「なし」のみ -> 重なりなし（#231: 「なし」は実ファイル0件が
  #                                              明示されているため、宣言漏れ側が不明でも
  #                                              重なりようがない）
  #   両方が宣言漏れ                         -> 重なりなし（既存Epicとの後方互換）
  local a="$1" b="$2"
  local a_files="${FILES_LINE[$a]:-}" b_files="${FILES_LINE[$b]:-}"
  OVERLAP_FILE=""

  if [ -z "$a_files" ] && [ -z "$b_files" ]; then
    return 1
  fi

  local a_arr=() b_arr=()
  if [ -n "$a_files" ]; then
    split_files_normalized "$a_files"
    a_arr=("${SPLIT_FILES_RESULT[@]}")
  fi
  if [ -n "$b_files" ]; then
    split_files_normalized "$b_files"
    b_arr=("${SPLIT_FILES_RESULT[@]}")
  fi

  if [ -z "$a_files" ] || [ -z "$b_files" ]; then
    # 片方は「## 対象ファイル」節そのものが無い（宣言漏れ）。もう片方の宣言側が「なし」
    # のみ（実ファイル0件）なら、宣言漏れ側が何を触るか不明でも重なりようがない（#231）
    local declared_arr=()
    if [ -n "$a_files" ]; then
      declared_arr=("${a_arr[@]}")
    else
      declared_arr=("${b_arr[@]}")
    fi
    if [ "${#declared_arr[@]}" -eq 0 ]; then
      return 1
    fi
    OVERLAP_FILE="(宣言漏れのため不明。安全側に倒しています)"
    return 0
  fi

  local f g
  for f in "${a_arr[@]}"; do
    [ -n "$f" ] || continue
    for g in "${b_arr[@]}"; do
      if [ "$f" = "$g" ]; then
        OVERLAP_FILE="$f"
        return 0
      fi
    done
  done
  return 1
}

# ---------------------------------------------------------------------------
# スキップの推移的伝播
# ---------------------------------------------------------------------------

declare -A SKIPPED_REASON   # issue番号 -> 伝播の原因になった依存先番号（明示スキップは空文字列）
SKIP_PROPAGATED=()          # 伝播によりスキップされた "issue番号:原因番号"（出力順）

IFS=',' read -r -a _skipped_arr <<< "$SKIPPED_CSV"
for _s in "${_skipped_arr[@]:-}"; do
  [ -n "$_s" ] || continue
  SKIPPED_REASON["$_s"]=""
done
unset _s _skipped_arr

_changed=1
while [ "$_changed" -eq 1 ]; do
  _changed=0
  for _n in "${PLAN_LIST[@]}"; do
    [ -z "${SKIPPED_REASON[$_n]+x}" ] || continue
    # shellcheck disable=SC2086  # REAL_DEPS の値は数字の空白区切り列。意図的に単語分割してループする
    for _d in ${REAL_DEPS[$_n]:-}; do
      if [ -n "${SKIPPED_REASON[$_d]+x}" ]; then
        SKIPPED_REASON["$_n"]="$_d"
        SKIP_PROPAGATED+=("${_n}:${_d}")
        _changed=1
        break
      fi
    done
  done
done
unset _n _d _changed

ACTIVE_LIST=()
for _n in "${PLAN_LIST[@]}"; do
  [ -n "${SKIPPED_REASON[$_n]+x}" ] || ACTIVE_LIST+=("$_n")
done
unset _n

# ---------------------------------------------------------------------------
# ウェーブ計算（依存グラフのレベル分け。DFS + 循環検出）
# ---------------------------------------------------------------------------

declare -A WAVE_OF        # issue番号 -> ウェーブ番号
declare -A VISIT_STATE    # issue番号 -> 0未訪問/1訪問中/2完了
PATH_STACK=()
LAST_WAVE=0
CYCLE_MEMBERS=()

compute_wave() {
  # compute_wave <issue番号>  戻り値 0=成功（結果は LAST_WAVE） 1=循環検出
  local n="$1"
  local state="${VISIT_STATE[$n]:-0}"

  if [ "$state" = "2" ]; then
    LAST_WAVE="${WAVE_OF[$n]}"
    return 0
  fi
  if [ "$state" = "1" ]; then
    local item found=0
    CYCLE_MEMBERS=()
    for item in "${PATH_STACK[@]}"; do
      if [ "$found" -eq 1 ] || [ "$item" = "$n" ]; then
        found=1
        CYCLE_MEMBERS+=("$item")
      fi
    done
    return 1
  fi

  VISIT_STATE["$n"]=1
  PATH_STACK+=("$n")

  local max_dep_wave=0 d
  # shellcheck disable=SC2086  # REAL_DEPS の値は数字の空白区切り列。意図的に単語分割してループする
  for d in ${REAL_DEPS[$n]:-}; do
    if ! compute_wave "$d"; then
      unset 'PATH_STACK[${#PATH_STACK[@]}-1]'
      return 1
    fi
    [ "$LAST_WAVE" -gt "$max_dep_wave" ] && max_dep_wave="$LAST_WAVE"
  done

  unset 'PATH_STACK[${#PATH_STACK[@]}-1]'
  WAVE_OF["$n"]=$((max_dep_wave + 1))
  VISIT_STATE["$n"]=2
  LAST_WAVE="${WAVE_OF[$n]}"
  return 0
}

for _n in "${ACTIVE_LIST[@]}"; do
  if [ "${VISIT_STATE[$_n]:-0}" != "2" ]; then
    if ! compute_wave "$_n"; then
      echo "ERROR: 循環依存を検出しました。循環に含まれるタスク: ${CYCLE_MEMBERS[*]}" >&2
      exit 3
    fi
  fi
done
unset _n

# ---------------------------------------------------------------------------
# ウェーブごとのタスク集約とサブバッチ割当
# ---------------------------------------------------------------------------

MAX_WAVE=0
for _n in "${ACTIVE_LIST[@]}"; do
  [ "${WAVE_OF[$_n]}" -gt "$MAX_WAVE" ] && MAX_WAVE="${WAVE_OF[$_n]}"
done
unset _n

declare -A SUBBATCH_OF   # issue番号 -> サブバッチ番号（ウェーブ内、1始まり）
WAVE_TASKS=()            # インデックス = ウェーブ番号（1始まり）の "n1,n2,..." 文字列
FILE_OVERLAP_DETAIL=()   # "task:other:file" 形式。対象ファイルの重なりで別サブバッチへ回した記録
FILE_OVERLAP_TASKS=()    # 重なりにより後続サブバッチへ回されたタスク番号（重複あり。件数計算用）

_w=1
while [ "$_w" -le "$MAX_WAVE" ]; do
  _tasks=()
  for _n in "${ACTIVE_LIST[@]}"; do
    [ "${WAVE_OF[$_n]}" -eq "$_w" ] && _tasks+=("$_n")
  done
  # ACTIVE_LIST は PLAN_LIST（昇順整列済み）由来の順序をそのまま保つため既に昇順
  #
  # サブバッチ割当（Task #216、#230で修正）。
  #
  # run側のレーン割当は「レーン L = 各サブバッチの L 番目（サブバッチ内の昇順順位）」という
  # 位置写像であり、サブバッチ間にバリアは無い（skills/run/SKILL.md Step 3）。そのため、
  # 対象ファイルが重なる2タスクを「別サブバッチに分ける」だけでは、順位（レーン）が
  # 一致しない限り並列実行されうる。現在の出力形式（タスクごとのサブバッチ番号のみ）では
  # 一度確定した順位を後から変えられないため、対象ファイルが1件でも重なるタスクは常に
  # 「新規かつそのタスク専用のサブバッチ」に単独で入れる（＝常に順位1＝レーン1になる）。
  # これにより、重なるタスク同士はサブバッチをまたいでも必ず同一レーンに落ち、逐次実行が
  # 保証される（ヘッダコメント「対象ファイルの重なりによるサブバッチ分割」参照。既知の
  # 限界も同所に記載）。
  #
  # 重なりが無いタスク（従来どおり）は貪欲な first-fit で、単独化されていないサブバッチへ
  # 詰める。対象ファイルが重なるタスクが1件も無いウェーブでは、先頭から LANES 件ずつ詰める
  # 従来のチャンク分割（i/LANES+1）と完全に同じ結果になる（後方互換）。
  declare -A _sb_members   # サブバッチ番号 -> "n1,n2,..."（そのサブバッチに入っているタスク）
  declare -A _sb_solo      # サブバッチ番号 -> 1（対象ファイルの重なりにより単独化されたサブバッチ）
  declare -A _has_conflict # タスク番号 -> 1（ウェーブ内の他タスクと対象ファイルが1件でも重なる）
  _sb_count=0

  # 挿入順序に依存させないため、ウェーブ全体を対象に先に総当たりで重なりの有無だけを判定する
  # （どの相手と重なるかは配置時に改めて files_overlap で確認し、FILE_OVERLAP_DETAIL に積む）
  for _n in "${_tasks[@]}"; do
    _has_conflict["$_n"]=0
  done
  _ti=0
  while [ "$_ti" -lt "${#_tasks[@]}" ]; do
    _tj=$((_ti + 1))
    while [ "$_tj" -lt "${#_tasks[@]}" ]; do
      if files_overlap "${_tasks[$_ti]}" "${_tasks[$_tj]}"; then
        _has_conflict["${_tasks[$_ti]}"]=1
        _has_conflict["${_tasks[$_tj]}"]=1
      fi
      _tj=$((_tj + 1))
    done
    _ti=$((_ti + 1))
  done

  for _n in "${_tasks[@]}"; do
    if [ "${_has_conflict[$_n]}" -eq 1 ]; then
      # 重なりあり: 必ず新規サブバッチに単独で入れる（常に順位1＝レーン1にする）
      _sb_count=$((_sb_count + 1))
      _sb_members[$_sb_count]="$_n"
      _sb_solo[$_sb_count]=1
      SUBBATCH_OF["$_n"]="$_sb_count"
      for _m in "${_tasks[@]}"; do
        [ "$_m" != "$_n" ] || break   # 昇順のため、自分に到達したら以降は未配置（まだ見ない）
        if files_overlap "$_n" "$_m"; then
          FILE_OVERLAP_DETAIL+=("${_n}:${_m}:${OVERLAP_FILE}")
          FILE_OVERLAP_TASKS+=("$_n")
        fi
      done
    else
      # 重なりなし: 空きがあり、かつ単独化されていないサブバッチへ貪欲に詰める
      _placed=0
      _s=1
      while [ "$_s" -le "$_sb_count" ]; do
        if [ -z "${_sb_solo[$_s]:-}" ]; then
          _members_csv="${_sb_members[$_s]}"
          IFS=',' read -r -a _members_arr <<< "$_members_csv"
          if [ "${#_members_arr[@]}" -lt "$LANES" ]; then
            _sb_members[$_s]="${_members_csv:+${_members_csv},}${_n}"
            SUBBATCH_OF["$_n"]="$_s"
            _placed=1
            break
          fi
        fi
        _s=$((_s + 1))
      done
      if [ "$_placed" -eq 0 ]; then
        _sb_count=$((_sb_count + 1))
        _sb_members[$_sb_count]="$_n"
        SUBBATCH_OF["$_n"]="$_sb_count"
      fi
    fi
  done
  unset _sb_members _sb_solo _has_conflict
  _joined="$(IFS=,; printf '%s' "${_tasks[*]:-}")"
  WAVE_TASKS[_w]="$_joined"
  _w=$((_w + 1))
done
unset _w _n _tasks _joined _s _sb_count _placed _m _members_csv _members_arr _ti _tj

# ---------------------------------------------------------------------------
# 実効並列度（宣言漏れ警告で使う。min(指定lanes, 各ウェーブに属するタスク数の最大値)）
# 完全逐次（全ウェーブが1タスク）なら1になる。既に計算済みのWAVE_TASKS/LANESから機械的に求める。
# 対象ファイルの重なりによるサブバッチ分割の影響は受けない（ウェーブのタスク数だけを見るため。
# 「重なりが無かったら達成できたはずの並列度」の基準値として、次のfile-overlap-summary計算で使う）。
# ---------------------------------------------------------------------------

EFFECTIVE_LANES=0
_w=1
while [ "$_w" -le "$MAX_WAVE" ]; do
  _wtasks_csv="${WAVE_TASKS[$_w]:-}"
  _wcount=0
  if [ -n "$_wtasks_csv" ]; then
    IFS=',' read -r -a _wtasks_arr <<< "$_wtasks_csv"
    _wcount="${#_wtasks_arr[@]}"
  fi
  [ "$_wcount" -gt "$EFFECTIVE_LANES" ] && EFFECTIVE_LANES="$_wcount"
  _w=$((_w + 1))
done
unset _w _wtasks_csv _wcount _wtasks_arr
[ "$EFFECTIVE_LANES" -gt "$LANES" ] && EFFECTIVE_LANES="$LANES"

# ---------------------------------------------------------------------------
# 対象ファイルの重なりによる実効並列度の低下（Task #216）
# 実際に割り当てられた各(ウェーブ,サブバッチ)組の最大タスク数を求め、上記EFFECTIVE_LANES
# （重なりが無かったら達成できたはずの並列度）と比べる。重なりで分割が発生し、かつ
# それによって並列度が落ちたときだけ file-overlap-summary を出す。
# ---------------------------------------------------------------------------

FILE_OVERLAP_ACTUAL_LANES=0
declare -A _ws_count
for _n in "${ACTIVE_LIST[@]}"; do
  _key="${WAVE_OF[$_n]}:${SUBBATCH_OF[$_n]}"
  _ws_count["$_key"]=$(( ${_ws_count["$_key"]:-0} + 1 ))
done
for _key in "${!_ws_count[@]}"; do
  [ "${_ws_count[$_key]}" -gt "$FILE_OVERLAP_ACTUAL_LANES" ] && FILE_OVERLAP_ACTUAL_LANES="${_ws_count[$_key]}"
done
unset _n _key
unset _ws_count

FILE_OVERLAP_UNIQUE_COUNT=0
if [ "${#FILE_OVERLAP_TASKS[@]}" -gt 0 ]; then
  FILE_OVERLAP_UNIQUE_COUNT="$(printf '%s\n' "${FILE_OVERLAP_TASKS[@]}" | sort -un | wc -l | tr -d ' ')"
fi

FILE_OVERLAP_SUMMARY_SHOW=0
if [ "$FILE_OVERLAP_UNIQUE_COUNT" -gt 0 ] && [ "$FILE_OVERLAP_ACTUAL_LANES" -lt "$EFFECTIVE_LANES" ]; then
  FILE_OVERLAP_SUMMARY_SHOW=1
fi

# ---------------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------------

print_machine() {
  echo -e "lanes\t${LANES}"

  local n
  for n in "${ACTIVE_LIST[@]}"; do
    local deps_csv
    deps_csv="$(printf '%s' "${REAL_DEPS[$n]:-}" | tr ' ' ',')"
    if [ -n "$deps_csv" ]; then
      echo -e "task\t${n}\twave\t${WAVE_OF[$n]}\tsubbatch\t${SUBBATCH_OF[$n]}\tdeps\t${deps_csv}"
    else
      echo -e "task\t${n}\twave\t${WAVE_OF[$n]}\tsubbatch\t${SUBBATCH_OF[$n]}\tdeps"
    fi
  done

  local w
  w=1
  while [ "$w" -le "$MAX_WAVE" ]; do
    echo -e "wave\t${w}\ttasks\t${WAVE_TASKS[$w]:-}"
    w=$((w + 1))
  done

  if [ "${#MISSING_DEPS_WARN[@]}" -gt 0 ]; then
    local sorted_missing
    mapfile -t sorted_missing < <(printf '%s\n' "${MISSING_DEPS_WARN[@]}" | sort -n)
    for n in "${sorted_missing[@]}"; do
      echo -e "warn\tmissing-deps\t${n}"
    done
    echo -e "warn\tmissing-deps-summary\t${#MISSING_DEPS_WARN[@]}\t${#PLAN_LIST[@]}\t${EFFECTIVE_LANES}\t${LANES}"
  fi

  if [ "${#UNKNOWN_DEP_WARN[@]}" -gt 0 ]; then
    local pair task dep
    for pair in "${UNKNOWN_DEP_WARN[@]}"; do
      task="${pair%%:*}"
      dep="${pair##*:}"
      echo -e "warn\tunknown-dep\t${task}\t${dep}"
    done
  fi

  if [ "${#MISSING_FILES_WARN[@]}" -gt 0 ]; then
    local sorted_missing_files
    mapfile -t sorted_missing_files < <(printf '%s\n' "${MISSING_FILES_WARN[@]}" | sort -n)
    for n in "${sorted_missing_files[@]}"; do
      echo -e "warn\tmissing-files\t${n}"
    done
  fi

  if [ "${#FILE_OVERLAP_DETAIL[@]}" -gt 0 ]; then
    local triple task other file
    for triple in "${FILE_OVERLAP_DETAIL[@]}"; do
      task="$(printf '%s' "$triple" | cut -d: -f1)"
      other="$(printf '%s' "$triple" | cut -d: -f2)"
      file="$(printf '%s' "$triple" | cut -d: -f3-)"
      echo -e "warn\tfile-overlap\t${task}\t${other}\t${file}"
    done
  fi

  if [ "$FILE_OVERLAP_SUMMARY_SHOW" -eq 1 ]; then
    echo -e "warn\tfile-overlap-summary\t${FILE_OVERLAP_UNIQUE_COUNT}\t${#ACTIVE_LIST[@]}\t${FILE_OVERLAP_ACTUAL_LANES}\t${LANES}"
  fi

  if [ "${#SKIP_PROPAGATED[@]}" -gt 0 ]; then
    local pair task dep
    for pair in "${SKIP_PROPAGATED[@]}"; do
      task="${pair%%:*}"
      dep="${pair##*:}"
      echo -e "skip\t${task}\treason\tdepends-on-skipped\t${dep}"
    done
  fi
}

print_human() {
  echo "=== ウェーブ分解（lanes=${LANES}） ==="
  local w
  w=1
  while [ "$w" -le "$MAX_WAVE" ]; do
    local tasks_csv sub_count
    tasks_csv="${WAVE_TASKS[$w]:-}"
    sub_count=0
    local n
    IFS=',' read -r -a _wtasks <<< "$tasks_csv"
    for n in "${_wtasks[@]:-}"; do
      [ -n "$n" ] || continue
      [ "${SUBBATCH_OF[$n]}" -gt "$sub_count" ] && sub_count="${SUBBATCH_OF[$n]}"
    done
    if [ "$sub_count" -gt 1 ]; then
      local detail="" s
      s=1
      while [ "$s" -le "$sub_count" ]; do
        local part=""
        for n in "${_wtasks[@]:-}"; do
          [ -n "$n" ] || continue
          [ "${SUBBATCH_OF[$n]}" -eq "$s" ] && part="${part}${part:+,}#${n}"
        done
        detail="${detail}${detail:+ / }サブバッチ${s}: ${part}"
        s=$((s + 1))
      done
      echo "ウェーブ ${w}: ${tasks_csv//,/, } (${detail})"
    else
      echo "ウェーブ ${w}: ${tasks_csv//,/, }"
    fi
    w=$((w + 1))
  done

  if [ "${#MISSING_DEPS_WARN[@]}" -gt 0 ]; then
    echo ""
    echo "[警告] 前提未宣言が ${#MISSING_DEPS_WARN[@]} 件あります（対象タスク ${#PLAN_LIST[@]} 件中）。"
    echo "       該当タスクは fail-safe により「自分より小さい issue 番号の全タスク」に依存するとみなされ、"
    echo "       直列化されます。この計画の実効並列度は ${EFFECTIVE_LANES} です（指定 lanes=${LANES}）。"
    echo "       Task issue 本文に「- 前提: #N」を、依存が無ければ「- 前提: なし」を追記してください。"
    local sorted_missing n2
    mapfile -t sorted_missing < <(printf '%s\n' "${MISSING_DEPS_WARN[@]}" | sort -n)
    for n2 in "${sorted_missing[@]}"; do
      echo "  #${n2}"
    done
  fi

  if [ "${#UNKNOWN_DEP_WARN[@]}" -gt 0 ]; then
    echo ""
    echo "[警告] 不明な依存（Epic外・存在しない issue。無視されます）:"
    local pair task dep
    for pair in "${UNKNOWN_DEP_WARN[@]}"; do
      task="${pair%%:*}"
      dep="${pair##*:}"
      echo "  #${task} -> #${dep}"
    done
  fi

  if [ "${#MISSING_FILES_WARN[@]}" -gt 0 ]; then
    echo ""
    echo "[警告] 対象ファイル未宣言が ${#MISSING_FILES_WARN[@]} 件あります（対象タスク ${#PLAN_LIST[@]} 件中）。"
    echo "       該当タスクは何を触るか不明なため、対象ファイルを宣言している他タスクとは"
    echo "       同一サブバッチに同居させません（安全側）。Task issue 本文に「## 対象ファイル」節を"
    echo "       追記してください（触るファイルが無い場合も節自体は省略しないでください）。"
    local sorted_missing_files n3
    mapfile -t sorted_missing_files < <(printf '%s\n' "${MISSING_FILES_WARN[@]}" | sort -n)
    for n3 in "${sorted_missing_files[@]}"; do
      echo "  #${n3}"
    done
  fi

  if [ "${#FILE_OVERLAP_DETAIL[@]}" -gt 0 ]; then
    echo ""
    echo "[警告] 対象ファイルの重なりにより、以下のタスクは同一サブバッチに同居させず別サブバッチへ分割しました:"
    local triple task other file
    for triple in "${FILE_OVERLAP_DETAIL[@]}"; do
      task="$(printf '%s' "$triple" | cut -d: -f1)"
      other="$(printf '%s' "$triple" | cut -d: -f2)"
      file="$(printf '%s' "$triple" | cut -d: -f3-)"
      echo "  #${task} と #${other}（${file}）"
    done
    if [ "$FILE_OVERLAP_SUMMARY_SHOW" -eq 1 ]; then
      echo "       この分割により実効並列度は ${FILE_OVERLAP_ACTUAL_LANES} です（指定 lanes=${LANES}）。"
    fi
    echo "       この宣言は実装前の見積もりであり、実際に触るファイルと乖離することがあります。"
    echo "       節を書いた（かつファイルが重ならない）からといって競合が起きない保証にはなりません。"
    echo "       merge-lane.sh の exit 11 による事後検出は従来どおり有効です。"
  fi

  if [ "${#SKIP_PROPAGATED[@]}" -gt 0 ]; then
    echo ""
    echo "[スキップ] 依存先のスキップが伝播:"
    local pair task dep
    for pair in "${SKIP_PROPAGATED[@]}"; do
      task="${pair%%:*}"
      dep="${pair##*:}"
      echo "  #${task}（依存先 #${dep} がスキップされたため）"
    done
  fi
}

if [ "$PRINT_MODE" -eq 1 ]; then
  print_human
else
  print_machine
fi

exit 0
