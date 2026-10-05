#!/bin/bash
# dev-workflow: Jev（System One Model）の判定精度を run を止めずにオフラインで測る（shadow mode）
#
# 背景（issue #244「検証方針」）: ① 指摘の重複排除・② feedback 台帳の分類・③ 確度判定の
# トリアージ は、いずれも過去の実績が GitHub 側に残っているため、**ハーネスを1度も動かさずに
# 精度を測れる**。日本語入力 + 英語 criteria が実用水準かという最大の未知に、最も安く答えが出る。
#
# **このスクリプトはハーネスから呼ばれない。** 人間が手で回す評価用ツールである。
# 課金（入力トークン）とネットワークが発生するため、自律ループの経路には絶対に入れない。
#
# **追加の依存物（jq 等）は使わない。** JSON の取り出しは gh の `-q`（gh 組み込みの jq）に任せ、
# 行処理は awk / sed で行う（scripts/feedback-ledger.sh と同じ作法）。
#
# 教師データの出どころと、その限界（**数値を読む前に必ず読むこと**）:
#
#   ① 重複排除
#      R1 のマージ前 findings JSON は**どこにも永続化されていない**（Epic issue のコメントにも
#      残らない）。そのため issue #244 が書いた「観点別4本の findings JSON を再生する」は
#      現状のリポジトリでは実行できない。代わりに **R2 が作った review issue** を使う。
#      同一 Epic・同一ファイルを指す2つの review issue は、run が「同一趣旨ではない」と
#      判断した結果として別々に立っているため、**正解ラベル = different のペア**になる。
#      → 測れるのは**誤統合率（偽陽性）だけ**。統合漏れ（偽陰性）は測れない。
#        失敗コストが非対称で、危険な向きが誤統合である（統合漏れは二重 issue が立つだけ）
#        ことから、この向きだけでも判断材料になる。
#
#   ② 台帳の分類
#      台帳（observations.tsv）に行があればそれを使う（`scope` / `category` / `severity` が
#      そのまま教師データになる）。**空なら** `skills/feedback/references/scope.md` の
#      「harness の例」「project の例」の著者ラベル付き例を使う。
#      → 後者は criteria の元になった文そのものなので、**精度は楽観側に出る**。
#        この経路で測ったときは出力にその旨が出る。
#
#   ③ 確度判定のトリアージ
#      issue 化された review issue = 確度判定を通った（high-confidence かつ high/medium）、
#      PR 本文「レビューで挙がった軽微な指摘」の各行 = issue 化されなかった指摘。
#      → 後者は `low` severity と `low-confidence` が混在しており厳密には同一ではない。
#        「明白に成立する指摘か」という問いに対する**近似ラベル**として扱う。
#
# 使い方:
#   jev-shadow-eval.sh build --case <1|2|3> [--out <dir>]
#     教師データを GitHub（gh）・台帳・scope.md から集め、TSV のデータセットを書き出す。
#     Jev は呼ばない（課金なし・鍵不要）。
#
#   jev-shadow-eval.sh run --case <1|2|3> [--out <dir>] [--limit <N>] [--dry-run]
#     データセットの各行を Jev に投げ、判定結果を追記して精度を集計・出力する。
#     --dry-run は組み立てたリクエスト JSON を表示するだけで POST しない（鍵不要）。
#
#   jev-shadow-eval.sh report --case <1|2|3> [--out <dir>]
#     既に run 済みの結果 TSV を再集計する（Jev を呼び直さない）。
#
# 出力先（既定）: ${DEV_WORKFLOW_JEV_EVAL_DIR:-${HOME}/.claude/dev-workflow/jev-eval}
#   case<N>-dataset.tsv  … 教師データ
#   case<N>-result.tsv   … Jev の生の応答を付けたもの（choice / noul / score / confidence）
#   生の値をそのまま残す（issue #244「構造的な懸念1」）。丸めた結論だけを残さない。
#
# 環境変数: scripts/jev-ask.sh と同じ（JEV_API_KEY / JEV_API_URL / JEV_MODEL ほか）
#   DEV_WORKFLOW_JEV_EVAL_DIR     出力先を上書きする
#   DEV_WORKFLOW_JEV_PAIR_SCOPE   ① の候補の絞り方。file（既定・同一ファイル）| line（同一ファイル:行）
#
# 終了コード: 0=成功 / 1=実行失敗（gh・Jev・書き込み） / 2=引数エラー

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JEV_ASK="${SCRIPT_DIR}/jev-ask.sh"

# ① の統合しきい値。core/references/jev-assist.md と同じ値にすること。
MERGE_THRESHOLD_PCT=85
MERGE_MIN_CONFIDENCE_PCT=50
# ③ の素通ししきい値。同上。
TRIAGE_THRESHOLD_PCT=95
TRIAGE_MIN_CONFIDENCE_PCT=70
# ② の低 confidence フォールバックしきい値。同上。
CLASSIFY_MIN_CONFIDENCE_PCT=60

# detail の切り詰め（state 上限 8,000 文字に収めるため。jev-assist.md「state の上限」）
DETAIL_MAX_CHARS=1500

usage() {
  sed -n '/^# 使い方:/,/^# 終了コード:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

_out_dir() {
  printf '%s' "${DEV_WORKFLOW_JEV_EVAL_DIR:-${HOME}/.claude/dev-workflow/jev-eval}"
}

# 小数（0.87 等）を整数パーセントへ直す。bash は浮動小数を扱えないため、
# しきい値比較はすべて整数パーセントで行う。読めない値は -1 を返す。
_pct() {
  local v="$1"
  case "$v" in
    ''|*[!0-9.]*) printf '%s' -1; return 0 ;;
  esac
  awk -v v="$v" 'BEGIN { printf "%d", (v * 100) + 0.5 }'
}

# 空フィールドは `-` で埋める（scripts/feedback-ledger.sh と同じ規約）。
#
# **これを省くと列がずれる。** `IFS=$'\t' read` はタブが IFS 空白文字であるため連続タブを
# 1つの区切りに畳む。空フィールドを素のまま書くと、読み出し側で以降の列が1つずつ手前に
# 寄り、判定対象の本文に別の列の値が入る（しかもエラーにならない）。
# 読み出し側は `_undash` で元に戻す。
_undash() {
  [ "$1" = "-" ] && printf '' || printf '%s' "$1"
}

_esc() { bash "$JEV_ASK" json-escape; }

# ---------------------------------------------------------------------------
# build: ① 指摘の重複排除
# ---------------------------------------------------------------------------

# review issue を「番号 / Epic / location / severity / title / 指摘本文」の TSV にする。
_dump_review_issues() {
  gh issue list --label review --state all --limit 500 \
    --json number,title,body \
    -q '.[]
        | . as $i
        | ( ($i.body | capture("## 該当箇所[^`]*`(?<v>[^`]+)`").v) // "" ) as $loc
        | ( ($i.body | capture("- Epic: #(?<v>[0-9]+)").v) // "" ) as $epic
        | ( ($i.body | capture("重要度: (?<v>[a-z]+)").v) // "" ) as $sev
        | ( ($i.body | capture("- 観点: (?<v>[^\n]+)").v) // "" ) as $focus
        | ( ($i.body | capture("(?s)## 指摘[^\n]*\n(?<v>.*?)\n## 該当箇所").v) // $i.body ) as $detail
        | [ ($i.number|tostring), $epic, $loc, $sev, $focus, $i.title,
            ($detail | gsub("[\n\t\r]"; " ")) ]
        | @tsv'
}

build_case1() {
  local out="$1" tmp
  tmp="$(mktemp)" || return 1
  echo "[build] review issue を取得中..." >&2
  _dump_review_issues > "$tmp" || { rm -f "$tmp"; echo "エラー: gh issue list に失敗しました" >&2; return 1; }

  local scope="${DEV_WORKFLOW_JEV_PAIR_SCOPE:-file}"
  case "$scope" in
    file|line) ;;
    *) echo "エラー: DEV_WORKFLOW_JEV_PAIR_SCOPE は file|line のいずれか: ${scope}" >&2; rm -f "$tmp"; return 2 ;;
  esac

  # 同一 Epic・同一 location キーのペアを総当たりで組む。location が空・Epic が空の行は捨てる
  # （どちらが欠けても「同じ箇所を指している」と言えないため）。
  printf 'label\ta_num\tb_num\tepic\tgroup\ta_loc\ta_sev\ta_focus\ta_title\ta_detail\tb_loc\tb_sev\tb_focus\tb_title\tb_detail\n' > "$out"
  awk -F'\t' -v OFS='\t' -v scope="$scope" '
    # 空フィールドは "-" で埋める（読み出し側の列ずれを防ぐ。_undash で戻す）
    function d(x) { return (x == "" ? "-" : x) }
    function groupkey(loc) {
      if (scope == "line") return loc
      p = index(loc, ":")
      return (p > 0 ? substr(loc, 1, p - 1) : loc)
    }
    $2 != "" && $3 != "" {
      n++
      num[n] = $1; epic[n] = $2; loc[n] = $3; sev[n] = $4; foc[n] = $5; tit[n] = $6; det[n] = $7
      grp[n] = epic[n] "\x01" groupkey(loc[n])
    }
    END {
      for (i = 1; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if (grp[i] == grp[j]) {
            split(grp[i], g, "\x01")
            print "different", num[i], num[j], d(g[1]), d(g[2]),
                  d(loc[i]), d(sev[i]), d(foc[i]), d(tit[i]), d(det[i]),
                  d(loc[j]), d(sev[j]), d(foc[j]), d(tit[j]), d(det[j])
          }
    }
  ' "$tmp" >> "$out"
  rm -f "$tmp"

  local pairs
  pairs="$(( $(wc -l < "$out") - 1 ))"
  echo "[build] case1: ${pairs} ペア（正解ラベルはすべて different。候補の絞り方=${scope}）" >&2
  echo "[build] 出力: ${out}" >&2
  [ "$pairs" -gt 0 ] || { echo "警告: ペアが0件です。統合率は測れません" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# build: ② 台帳の分類
# ---------------------------------------------------------------------------

build_case2() {
  local out="$1" ledger src=''
  ledger="$(bash "${SCRIPT_DIR}/feedback-ledger.sh" path 2>/dev/null)/observations.tsv"

  printf 'scope\tcategory\tseverity\tobservation\tevidence\tsource\n' > "$out"

  if [ -s "$ledger" ]; then
    src='ledger'
    # 台帳の列: timestamp scope category key severity epic summary evidence
    awk -F'\t' -v OFS='\t' '
      function d(x) { return (x == "" ? "-" : x) }
      NF >= 8 { print d($2), d($3), d($5), d($7), d($8), "ledger" }
    ' "$ledger" >> "$out"
  else
    src='scope.md'
    # 台帳が空なので scope.md の著者ラベル付き例を使う。category / severity のラベルは
    # 付いていないため scope だけを教師データにする（category/severity 列は空にする）。
    awk '
      /^### harness の例/      { mode = "harness"; next }
      /^### project の例/      { mode = "project"; next }
      /^### どちらでもないもの/ { mode = "neither"; next }
      /^## /                    { mode = ""; next }
      mode != "" && /^- / {
        line = $0
        sub(/^- /, "", line)
        gsub(/`/, "", line)
        # category / severity のラベルは scope.md に無いので "-"（空フィールドを素で書くと
        # 読み出し側で列がずれる）
        if (line != "") printf "%s\t-\t-\t%s\t-\tscope.md\n", mode, line
      }
    ' "${SCRIPT_DIR}/../skills/feedback/references/scope.md" >> "$out"
  fi

  local rows
  rows="$(( $(wc -l < "$out") - 1 ))"
  echo "[build] case2: ${rows} 件（教師データの出どころ=${src}）" >&2
  if [ "$src" = "scope.md" ]; then
    echo "[build] 注意: scope.md の例は criteria の元になった文そのものです。" >&2
    echo "        scope の精度は楽観側に出ます。category / severity はラベルが無いため測れません。" >&2
  fi
  echo "[build] 出力: ${out}" >&2
  [ "$rows" -gt 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# build: ③ 確度判定のトリアージ
# ---------------------------------------------------------------------------

build_case3() {
  local out="$1" tmp
  tmp="$(mktemp)" || return 1

  printf 'label\tref\tloc\tsev\ttitle\tdetail\tfix\n' > "$out"

  echo "[build] review issue（= 確度判定を通った指摘）を取得中..." >&2
  _dump_review_issues > "$tmp" || { rm -f "$tmp"; echo "エラー: gh issue list に失敗しました" >&2; return 1; }
  # fix（## 修正方針）も要るので個別に取り直す代わりに、detail に含まれる範囲で評価する。
  awk -F'\t' -v OFS='\t' '
    function d(x) { return (x == "" ? "-" : x) }
    NF >= 7 { print "stands", "#" $1, d($3), d($4), d($6), d($7), "-" }
  ' "$tmp" >> "$out"
  rm -f "$tmp"

  echo "[build] PR 本文の「レビューで挙がった軽微な指摘」（= issue 化されなかった指摘）を取得中..." >&2
  local prs pr
  prs="$(gh pr list --state all --limit 300 --json number -q '.[].number')" \
    || { echo "エラー: gh pr list に失敗しました" >&2; return 1; }
  for pr in $prs; do
    gh pr view "$pr" --json body -q .body 2>/dev/null \
      | awk -v pr="$pr" '
          # 見出し行だけを開始条件にする。本文中の「下記『軽微な指摘』へ格下げ記録」のような
          # 言及で開始すると、直前の「## レビュー結果」の箇条書きまで拾ってしまう。
          /^#+ .*軽微な指摘/ { inside = 1; next }
          # 見出しの深さを問わず、次の見出しで閉じる（#### で閉じ損ねると節が終わらない）。
          inside && /^#+ / { if (buf != "") { print pr "\t" buf; buf = "" } inside = 0 }
          inside {
            if (/^[-*] /) {
              if (buf != "") print pr "\t" buf
              buf = $0
              sub(/^[-*] /, "", buf)
            } else if (buf != "" && /[^ ]/) {
              line = $0
              sub(/^[ \t]+/, "", line)
              buf = buf " " line
            }
          }
          END { if (buf != "") print pr "\t" buf }
        '
  done | awk -F'\t' -v OFS='\t' '
      $2 != "" {
        # 先頭の `#NNN:` は由来タスクの注記であって指摘本文ではないので落とす
        body = $2
        sub(/^#[0-9]+: /, "", body)
        gsub(/`/, "", body)
        # 本文が「確度判定で low-confidence」と明記しているものだけが ③ の厳密な正解ラベル
        # （high/medium で挙がったが確度判定が落としたもの）。それ以外は最初から low severity で
        # 確度判定の対象外なので、別ラベルにして集計を分ける。
        label = (body ~ /low-confidence/) ? "low-conf" : "low-sev"
        print label, "PR#" $1, "-", "low", body, body, "-"
      }
    ' >> "$out"

  local stands lowconf lowsev
  stands="$(awk -F'\t' '$1 == "stands"' "$out" | wc -l)"
  lowconf="$(awk -F'\t' '$1 == "low-conf"' "$out" | wc -l)"
  lowsev="$(awk -F'\t' '$1 == "low-sev"' "$out" | wc -l)"
  echo "[build] case3: stands=${stands} 件 / low-conf=${lowconf} 件 / low-sev=${lowsev} 件" >&2
  echo "[build] 注意: low-conf が ③ の厳密な正解ラベル（確度判定が落とした high/medium）。" >&2
  echo "        low-sev は最初から low severity で確度判定の対象外のため、参考扱い。" >&2
  echo "[build] 出力: ${out}" >&2
  [ "$(( stands + lowconf + lowsev ))" -gt 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# run: 共通部分
# ---------------------------------------------------------------------------

# $1=リクエストJSONファイル / 標準出力に応答JSONファイルのパスを返す
_post() {
  local req="$1" res
  res="$(mktemp)" || return 1
  if bash "$JEV_ASK" ask --request-file "$req" > "$res" 2>/dev/null; then
    printf '%s' "$res"
    return 0
  fi
  # 1回だけ再試行する（jev-assist.md「0. 大前提」）
  if bash "$JEV_ASK" ask --request-file "$req" > "$res" 2>/dev/null; then
    printf '%s' "$res"
    return 0
  fi
  rm -f "$res"
  return 1
}

_field() {
  bash "$JEV_ASK" answer --response-file "$1" --question "$2" --field "$3" 2>/dev/null || printf ''
}

# ---------------------------------------------------------------------------
# run: ①
# ---------------------------------------------------------------------------

run_case1() {
  local dataset="$1" result="$2" limit="$3" dry="$4"
  printf 'label\ta_num\tb_num\tnoul\tconfidence\tjev_verdict\n' > "$result"

  local processed=0 failed=0
  # shellcheck disable=SC2034  # group/*_focus はデータセットの列を読み飛ばすために要る
  while IFS=$'\t' read -r label a_num b_num epic group a_loc a_sev a_focus a_title a_detail b_loc b_sev b_focus b_title b_detail; do
    [ "$label" = "label" ] && continue
    [ -n "$label" ] || continue
    if [ "$limit" -gt 0 ] && [ "$processed" -ge "$limit" ]; then break; fi

    # `-` 埋めを戻す（_undash の説明を参照）
    a_loc="$(_undash "$a_loc")"; a_sev="$(_undash "$a_sev")"; a_focus="$(_undash "$a_focus")"
    a_title="$(_undash "$a_title")"; a_detail="$(_undash "$a_detail")"
    b_loc="$(_undash "$b_loc")"; b_sev="$(_undash "$b_sev")"; b_focus="$(_undash "$b_focus")"
    b_title="$(_undash "$b_title")"; b_detail="$(_undash "$b_detail")"

    local req
    req="$(mktemp)" || return 1
    {
      printf '{\n  "model": "%s",\n' "$(bash "$JEV_ASK" model)"
      printf '  "state": {\n'
      printf '    "a": {"location": "%s", "severity": "%s", "focus": "%s", "title": "%s", "detail": "%s"},\n' \
        "$(printf '%s' "$a_loc" | _esc)" "$(printf '%s' "$a_sev" | _esc)" \
        "$(printf '%s' "$a_focus" | _esc)" "$(printf '%s' "$a_title" | _esc)" \
        "$(printf '%s' "$a_detail" | _esc)"
      printf '    "b": {"location": "%s", "severity": "%s", "focus": "%s", "title": "%s", "detail": "%s"}\n' \
        "$(printf '%s' "$b_loc" | _esc)" "$(printf '%s' "$b_sev" | _esc)" \
        "$(printf '%s' "$b_focus" | _esc)" "$(printf '%s' "$b_title" | _esc)" \
        "$(printf '%s' "$b_detail" | _esc)"
      printf '  },\n  "questions": {\n'
      printf '    "same_finding": {\n'
      printf '      "type": "noul",\n'
      printf '      "instructions": "A and B are two code-review findings produced independently by reviewers with different focuses. They already point at the same source location. Decide whether they describe THE SAME underlying defect, meaning a single fix would resolve both. Answer true ONLY if the defect itself is identical. Sharing a file, a line, a function, or a symptom is NOT enough: two distinct defects in the same place, or one symptom with two different root causes, are different findings. The finding text is Japanese; judge the technical substance, not the wording. If you are not sure, answer false.",\n'
      printf '      "criteria": {"true": "same underlying defect; one fix resolves both", "false": "different defects, or not sure"}\n'
      printf '    }\n  }\n}\n'
    } > "$req"

    if [ "$dry" = "1" ]; then
      echo "--- ${a_num} vs ${b_num} ---"
      cat "$req"
      rm -f "$req"
      processed=$(( processed + 1 ))
      continue
    fi

    local res noul conf verdict
    if res="$(_post "$req")"; then
      noul="$(_field "$res" same_finding noul)"
      conf="$(_field "$res" same_finding confidence)"
      rm -f "$res"
    else
      noul=''; conf=''; failed=$(( failed + 1 ))
    fi
    rm -f "$req"

    verdict='not-merged'
    local np cp
    np="$(_pct "$noul")"; cp="$(_pct "$conf")"
    if [ "$np" -ge "$MERGE_THRESHOLD_PCT" ] 2>/dev/null; then
      if [ "$cp" -lt 0 ] || [ "$cp" -ge "$MERGE_MIN_CONFIDENCE_PCT" ]; then
        verdict='merged'
      else
        verdict='not-merged(low-conf)'
      fi
    fi
    [ "$np" -ge 0 ] 2>/dev/null || verdict='api-failed'

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$a_num" "$b_num" "$noul" "$conf" "$verdict" >> "$result"
    processed=$(( processed + 1 ))
    printf '\r[run] %d 件処理' "$processed" >&2
  done < "$dataset"
  echo >&2
  [ "$failed" -eq 0 ] || echo "[run] 警告: ${failed} 件が API 失敗（api-failed として記録）" >&2
  return 0
}

report_case1() {
  local result="$1"
  awk -F'\t' -v thr="$MERGE_THRESHOLD_PCT" '
    NR == 1 { next }
    { total++ }
    $6 == "merged"   { fp++ }
    $6 == "api-failed" { failed++ }
    $6 ~ /^not-merged/ { tn++ }
    END {
      judged = total - failed
      printf "\n===== ① 指摘の重複排除（Noul）=====\n"
      printf "ペア数:                     %d（正解ラベルはすべて different）\n", total
      printf "API 失敗:                   %d\n", failed
      printf "判定できたペア:             %d\n", judged
      printf "うち Jev が「同じ」と判定:  %d  ← 誤統合（偽陽性）\n", fp
      printf "うち Jev が「別」と判定:    %d  ← 正解\n", tn
      if (judged > 0) {
        rate = 100.0 * fp / judged
        printf "\n誤統合率:                   %.1f%%（しきい値 noul >= %d%%）\n", rate, thr
        printf "判定の一致率:               %.1f%%\n", 100.0 * tn / judged
        printf "\n合否（受入基準: 誤統合率 <= 5%%）: %s\n", (rate <= 5.0 ? "合格" : "不合格")
        if (judged < 100)
          printf "\n注意: n=%d は少ない。誤統合率 0%% でも 95%% 片側上限は約 %.1f%% までしか絞れない\n", judged, 100.0 * (1 - exp(log(0.05) / judged))
      }
      printf "\n測れていないこと: 統合漏れ（偽陰性）。マージ前 findings JSON が永続化されていないため\n"
    }
  ' "$result"
}

# ---------------------------------------------------------------------------
# run: ②
# ---------------------------------------------------------------------------

run_case2() {
  local dataset="$1" result="$2" limit="$3" dry="$4"
  printf 'true_scope\ttrue_category\ttrue_severity\tjev_scope\tscope_conf\tjev_category\tcategory_conf\tjev_score\tscore_conf\tsource\n' > "$result"

  local processed=0
  while IFS=$'\t' read -r t_scope t_cat t_sev obs evidence source; do
    [ "$t_scope" = "scope" ] && continue
    # `-` 埋めを戻す（_undash の説明を参照）
    t_cat="$(_undash "$t_cat")"; t_sev="$(_undash "$t_sev")"
    obs="$(_undash "$obs")"; evidence="$(_undash "$evidence")"
    [ -n "$obs" ] || continue
    if [ "$limit" -gt 0 ] && [ "$processed" -ge "$limit" ]; then break; fi

    local req
    req="$(mktemp)" || return 1
    {
      printf '{\n  "model": "%s",\n' "$(bash "$JEV_ASK" model)"
      printf '  "state": {"observation": "%s", "evidence": "%s"},\n' \
        "$(printf '%s' "$obs" | _esc)" "$(printf '%s' "$evidence" | _esc)"
      printf '  "questions": {\n'
      printf '    "scope": {"type": "choice",\n'
      printf '      "instructions": "An observation from one run of the dev-workflow harness is given, in Japanese. dev-workflow is a reusable harness that drives development in many different repositories. Decide the scope by answering one question: would the SAME problem also happen in a different project that uses dev-workflow? If yes, it is harness. If it depends on this project own structure, conventions, test commands, Docker image, or codebase, it is project. If the observation is a one-off (a transient network or GitHub outage, the user changing direction, or model output variance unlikely to reproduce), choose neither. If you cannot decide between harness and project, choose project.",\n'
      printf '      "criteria": {"harness": "would reproduce in other projects using dev-workflow; a defect or gap in the harness itself", "project": "specific to this repository structure, conventions, or codebase; also the default when undecided", "neither": "one-off or non-reproducible; record only, never promote"}},\n'
      printf '    "category": {"type": "choice",\n'
      printf '      "instructions": "Classify the same observation into one area of the harness. Pick the area the observation is ABOUT, not the area where it happened to surface.",\n'
      printf '      "criteria": {"gate": "tests, build, readability guard, integration gate", "sandbox": "Docker image, compose, shared directories, mounts", "permission": "interruption by a permission prompt, missing settings", "plan": "requirement interview, issue splitting, dependency declaration, wave planning", "review": "the reviewer agent, quality of findings, handling of review issues", "telemetry": "watchdog, heartbeat, token recording, notifications", "docs": "README, skill documents, role definitions diverging from the implementation", "other": "none of the above"}},\n'
      printf '    "severity": {"type": "score",\n'
      printf '      "instructions": "Rate the severity by CONSEQUENCE, never by how annoying it felt. If no fact can be cited (it stopped, it had to be redone, tokens went up N times), the answer is the lowest level.",\n'
      printf '      "criteria": ["low: cosmetic, wording, or minor inefficiency", "medium: rework happened, cost grew structurally, or a human had to step in", "high: autonomous operation stopped, a wrong artifact became a merge candidate, or data was lost"]}\n'
      printf '  }\n}\n'
    } > "$req"

    if [ "$dry" = "1" ]; then
      echo "--- ${t_scope} / $(printf '%s' "$obs" | cut -c1-40) ---"
      cat "$req"
      rm -f "$req"
      processed=$(( processed + 1 ))
      continue
    fi

    local res j_scope s_conf j_cat c_conf j_score sc_conf
    if res="$(_post "$req")"; then
      j_scope="$(_field "$res" scope choice)";      s_conf="$(_field "$res" scope confidence)"
      j_cat="$(_field "$res" category choice)";     c_conf="$(_field "$res" category confidence)"
      j_score="$(_field "$res" severity score)";    sc_conf="$(_field "$res" severity confidence)"
      rm -f "$res"
    else
      j_scope=''; s_conf=''; j_cat=''; c_conf=''; j_score=''; sc_conf=''
    fi
    rm -f "$req"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$t_scope" "$t_cat" "$t_sev" "$j_scope" "$s_conf" "$j_cat" "$c_conf" "$j_score" "$sc_conf" "$source" >> "$result"
    processed=$(( processed + 1 ))
    printf '\r[run] %d 件処理' "$processed" >&2
  done < "$dataset"
  echo >&2
  return 0
}

report_case2() {
  local result="$1"
  awk -F'\t' -v minc="$CLASSIFY_MIN_CONFIDENCE_PCT" '
    function pct(v) { return (v == "" ? -1 : int(v * 100 + 0.5)) }
    NR == 1 { next }
    {
      total++
      src = $10
      if ($4 == "") { failed++; next }
      judged++
      # `scope` は confidence で倒さず choice をそのまま採る（採用した規則）。
      # 比較のため、撤回した「confidence < 0.6 なら project」も併せて数える。
      if ($4 == $1) scope_ok++
      fb_scope = (pct($5) >= 0 && pct($5) < minc) ? "project" : $4
      if (fb_scope == $1) scope_fb_ok++
      # 誤りの向き（harness→project は安全側 / project→harness は危険側）
      if ($4 != $1) { if ($4 == "harness") unsafe_dir++; else safe_dir++ }
      if ($2 != "") { cat_n++; final_cat = (pct($7) >= 0 && pct($7) < minc) ? "other" : $6; if (final_cat == $2) cat_ok++ }
      if ($3 != "") {
        sev_n++
        s = $8 + 0
        lvl = (s < 0.5 ? "low" : (s < 1.5 ? "medium" : "high"))
        if (pct($9) >= 0 && pct($9) < minc) lvl = "low"
        if (lvl == $3) sev_ok++
      }
    }
    END {
      printf "\n===== ② feedback 台帳の分類（Choice + Score）=====\n"
      printf "件数: %d（API 失敗 %d / 判定 %d）\n", total, failed, judged
      if (judged > 0) {
        printf "\nscope 一致率（採用: choice をそのまま）:                  %.1f%% (%d/%d)\n", 100.0*scope_ok/judged, scope_ok, judged
        printf "scope 一致率（撤回: confidence < %d%% なら project に倒す）: %.1f%% (%d/%d)\n", minc, 100.0*scope_fb_ok/judged, scope_fb_ok, judged
        printf "\n誤りの向き: 安全側（harness→project）%d 件 / 危険側（project→harness）%d 件\n", safe_dir + 0, unsafe_dir + 0
        printf "  危険側が0件なら、confidence で倒さなくても安全側の偏りが保たれている\n"
      }
      if (cat_n > 0) printf "category 一致率: %.1f%% (%d/%d)\n", 100.0*cat_ok/cat_n, cat_ok, cat_n
      else           printf "category 一致率: 測れない（教師ラベルが無い）\n"
      if (sev_n > 0) printf "severity 一致率: %.1f%% (%d/%d)\n", 100.0*sev_ok/sev_n, sev_ok, sev_n
      else           printf "severity 一致率: 測れない（教師ラベルが無い）\n"
    }
  ' "$result"
  if awk -F'\t' 'NR>1 && $10 == "scope.md" { found = 1 } END { exit !found }' "$result"; then
    echo
    echo "注意: 教師データが scope.md の例（criteria の元になった文そのもの）。精度は楽観側に出る。"
  fi
}

# ---------------------------------------------------------------------------
# run: ③
# ---------------------------------------------------------------------------

run_case3() {
  local dataset="$1" result="$2" limit="$3" dry="$4"
  printf 'label\tref\tnoul\tconfidence\tjev_verdict\n' > "$result"

  local processed=0
  while IFS=$'\t' read -r label ref loc sev title detail fix; do
    [ "$label" = "label" ] && continue
    [ -n "$label" ] || continue
    if [ "$limit" -gt 0 ] && [ "$processed" -ge "$limit" ]; then break; fi

    # `-` 埋めを戻す（_undash の説明を参照）
    loc="$(_undash "$loc")"; sev="$(_undash "$sev")"
    title="$(_undash "$title")"; detail="$(_undash "$detail")"; fix="$(_undash "$fix")"

    local req
    req="$(mktemp)" || return 1
    {
      printf '{\n  "model": "%s",\n' "$(bash "$JEV_ASK" model)"
      printf '  "state": {"location": "%s", "severity": "%s", "title": "%s", "detail": "%s", "fix": "%s"},\n' \
        "$(printf '%s' "$loc" | _esc)" "$(printf '%s' "$sev" | _esc)" \
        "$(printf '%s' "$title" | _esc)" "$(printf '%s' "$detail" | _esc)" \
        "$(printf '%s' "$fix" | _esc)"
      printf '  "questions": {\n'
      printf '    "clearly_stands": {\n'
      printf '      "type": "noul",\n'
      printf '      "instructions": "A code-review finding is given, in Japanese, together with the location it points at and the fix it proposes. Decide whether the finding CLEARLY stands on its own, meaning a careful reviewer reading the cited code would agree it is a real defect without needing further investigation. Answer false if the finding depends on an assumption about code you cannot see, if it describes a stylistic preference, if it says the problem causes no actual harm, if it is about wording or documentation drift only, or if it might already be handled elsewhere. Answer false when you are not sure. Answering true causes the finding to skip an independent verification step, so only answer true when the defect is self-evident from the text.",\n'
      printf '      "criteria": {"true": "self-evidently a real defect; no further verification needed", "false": "needs verification, is a preference, is harmless, or not sure"}\n'
      printf '    }\n  }\n}\n'
    } > "$req"

    if [ "$dry" = "1" ]; then
      echo "--- ${label} ${ref} ---"
      cat "$req"
      rm -f "$req"
      processed=$(( processed + 1 ))
      continue
    fi

    local res noul conf verdict np cp
    if res="$(_post "$req")"; then
      noul="$(_field "$res" clearly_stands noul)"
      conf="$(_field "$res" clearly_stands confidence)"
      rm -f "$res"
    else
      noul=''; conf=''
    fi
    rm -f "$req"

    np="$(_pct "$noul")"; cp="$(_pct "$conf")"
    verdict='to-opus'
    # noul 型の応答に `confidence` は無い（noul 自身が校正済み確率。公式の応答例で確認）。
    # そのため confidence を必須にすると ③ は一度も発火せず、素通しの精度を測れない。
    # 読み取れたときだけ追加条件として使う。
    if [ "$np" -ge "$TRIAGE_THRESHOLD_PCT" ] 2>/dev/null; then
      if [ "$cp" -lt 0 ] || [ "$cp" -ge "$TRIAGE_MIN_CONFIDENCE_PCT" ] 2>/dev/null; then
        verdict='passed-through'
      fi
    fi
    [ "$np" -ge 0 ] 2>/dev/null || verdict='api-failed'

    printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$ref" "$noul" "$conf" "$verdict" >> "$result"
    processed=$(( processed + 1 ))
    printf '\r[run] %d 件処理' "$processed" >&2
  done < "$dataset"
  echo >&2
  return 0
}

report_case3() {
  local result="$1"
  awk -F'\t' -v thr="$TRIAGE_THRESHOLD_PCT" '
    NR == 1 { next }
    { total++ }
    $5 == "api-failed" { failed++; next }
    { judged++ }
    $1 == "stands"   { stands++ }
    $1 == "low-conf" { lowconf++ }
    $1 == "low-sev"  { lowsev++ }
    $5 == "passed-through" {
      pt++
      if ($1 == "stands")        pt_ok++
      else if ($1 == "low-conf") pt_lowconf++
      else                       pt_lowsev++
    }
    $5 == "to-opus" { op++ }
    END {
      printf "\n===== ③ 確度判定のトリアージ（Noul。素通しさせる向きのみ）=====\n"
      printf "指摘数: %d（stands=%d / low-conf=%d / low-sev=%d。API 失敗 %d）\n",
             total, stands, lowconf, lowsev, failed
      printf "\n素通し（noul >= %d%% かつ confidence >= 70%%）: %d 件\n", thr, pt
      printf "  うち stands（正解。opus を省いてよかった）:   %d\n", pt_ok
      printf "  うち low-conf（確度判定が落としたもの）:      %d  ← これが0件でなければ不採用\n", pt_lowconf
      printf "  うち low-sev（最初から low。参考）:           %d\n", pt_lowsev
      if (pt > 0) printf "  素通し集合の適合率（stands / 素通し全体）: %.1f%%\n", 100.0 * pt_ok / pt
      printf "\nopus へ回す: %d 件\n", op
      if (stands > 0) printf "削減できる opus 確度判定の割合（stands 基準の網羅率）: %.1f%%\n", 100.0 * pt_ok / stands
      printf "\n③ はハーネスに結線していない（ADR-0012 決定C。削減効果が 0%% だったため）。\n"
      printf "この集計は再測定用であり、結線を復活させる判断材料にする。\n"
      if (pt == 0)
        printf "判定: 素通しが0件なので削減効果は 0%%。結線しない判断は維持。\n"
      else if (pt_lowconf + 0 == 0)
        printf "判定: 素通し %d 件・うち low-conf 0 件。安全側は保たれている（復活の検討材料になる）。\n", pt
      else
        printf "判定: 素通し %d 件のうち low-conf が %d 件。opus が落とした指摘を素通しさせているため復活させない。\n", pt, pt_lowconf
    }
  ' "$result"
}

# ---------------------------------------------------------------------------
# ディスパッチ
# ---------------------------------------------------------------------------

[ $# -ge 1 ] || { usage >&2; exit 2; }
subcommand="$1"; shift

case_num=''
out_dir=''
limit=0
dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --case)    [ $# -ge 2 ] || { echo "エラー: --case に値がありません" >&2; exit 2; }; case_num="$2"; shift 2 ;;
    --out)     [ $# -ge 2 ] || { echo "エラー: --out に値がありません" >&2; exit 2; };  out_dir="$2";  shift 2 ;;
    --limit)   [ $# -ge 2 ] || { echo "エラー: --limit に値がありません" >&2; exit 2; }; limit="$2";   shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "エラー: 不明なオプション: $1" >&2; exit 2 ;;
  esac
done

case "$case_num" in
  1|2|3) ;;
  *) echo "エラー: --case は 1|2|3 のいずれかです" >&2; exit 2 ;;
esac
case "$limit" in
  ''|*[!0-9]*) echo "エラー: --limit は数値です" >&2; exit 2 ;;
esac

[ -n "$out_dir" ] || out_dir="$(_out_dir)"
mkdir -p "$out_dir" || { echo "エラー: 出力先を作れません: ${out_dir}" >&2; exit 1; }
dataset="${out_dir}/case${case_num}-dataset.tsv"
result="${out_dir}/case${case_num}-result.tsv"

case "$subcommand" in
  build)
    "build_case${case_num}" "$dataset" || exit $?
    ;;
  run)
    [ -s "$dataset" ] || { "build_case${case_num}" "$dataset" || exit $?; }
    if [ "$dry" = "0" ] && ! bash "$JEV_ASK" available; then
      echo "エラー: Jev が使えないため run できません（JEV_API_KEY を設定してください）。" >&2
      echo "       リクエストの組み立てだけ確認するなら --dry-run を付けてください。" >&2
      exit 1
    fi
    "run_case${case_num}" "$dataset" "$result" "$limit" "$dry" || exit 1
    [ "$dry" = "1" ] && exit 0
    "report_case${case_num}" "$result"
    echo
    echo "生の応答: ${result}"
    ;;
  report)
    [ -s "$result" ] || { echo "エラー: 結果ファイルがありません: ${result}（先に run してください）" >&2; exit 1; }
    "report_case${case_num}" "$result"
    ;;
  *)
    echo "エラー: 不明なサブコマンド: ${subcommand}" >&2; usage >&2; exit 2 ;;
esac
