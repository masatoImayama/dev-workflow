# Jev（System One Model）に判断を委ねるときの作法

issue #244 の棚卸しで「Jev に置いてよい」と判定された3つの判断点の、呼び出し方・倒し方・
記録の仕方をまとめた正本。参照元は次の2か所。

| 判断点 | 参照元 | 型 | 状態 |
|---|---|---|---|
| ① 指摘の重複排除 | `skills/run/references/review.md`「R1の結果マージ」step 2 | `Noul` | **鍵があれば有効**（誤統合率 0.0% / 25ペア） |
| ② feedback 台帳の分類 | `skills/feedback/SKILL.md` Phase 2 | `Choice` + `Score` | **鍵があれば有効**（`scope` 一致率 78.6% / 14件） |
| ③ 確度判定のトリアージ | — | `Noul` | **結線しない**（削減効果 0% / 158件。下記 ③ 節） |

実測値の詳細と読み方の注意は `docs/adr/0012-jev-system-one-decision-points.md`「測定結果」。

## 0. 大前提

**Jev は任意依存である。** `JEV_API_KEY` が未設定なら以下はすべて従来どおり（あなた自身の
判断）で実行する。未導入は異常ではないので、警告も出さずそのまま進む。
`scripts/jev-ask.sh available` が非0を返したら、その判断点は従来経路で処理する。

```bash
if bash "${CLAUDE_PLUGIN_ROOT}/scripts/jev-ask.sh" available 2>/dev/null; then
  JEV=1
else
  JEV=0   # 従来どおり。ここで止まらない
fi
```

**API 呼び出しが失敗したときも同じ**（`ask` の終了コード 3）。リトライは1回までにして、
それでも駄目なら従来経路へ倒す。Jev の不調でハーネスが止まる経路を作らない。

### criteria は英語で書く。入力（state）は日本語のまま渡す

Jev は日本語入力で精度が落ちる（issue #244「構造的な懸念5」）。判定基準＝`instructions` と
`criteria` は**英語で固定**し、判定対象の finding 本文・観測本文は**翻訳せず日本語のまま**
`state` に入れる。翻訳を挟むと、翻訳の誤りが判定の誤りと区別できなくなる。

### 確率をそのまま残す

ハーネスの中核は「状態は GitHub issue と git に置く。だから別セッションから再開できる」。
確率的な判断を挟むなら、**`choice` / `noul` / `score` / `confidence` の生の値を残す**
（issue #244「構造的な懸念1」）。残し方は各節に書く。値を丸めた結論だけを残してはならない。

### state の上限

context 予算は1リクエスト 64k トークン、うち **`state` + 最長の question で 32k トークン**まで
（公式 `docs.typesafe.ai/models`）。① は finding 2件・② は観測1件しか入れないので通常は
問題にならないが、`detail` が長い finding は **先頭 1,500 文字で打ち切って渡す**（打ち切った
事実は判定の記録に残す）。打ち切りで上限を超えなくなるのに呼び出しを諦める必要はない。

---

## ① 指摘の重複排除（`Noul`）

### 候補の絞り込み

**全ペアを投げない。** まず従来どおり「同一 `location`（ファイル:行）」でグループ化し、
**同じグループ内のペアだけ**を Jev に投げる。`location` が違うペアは従来どおり別件として扱う
（Jev を呼ばない）。これで state は極小になり、ペア数も現実的な数に収まる。

### リクエスト

1ペア1リクエスト。複数ペアは並列に投げてよい。

```bash
A_TITLE="$(printf '%s' "$a_title" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/jev-ask.sh" json-escape)"
# detail / location / severity / focus も同様に json-escape を通す

cat > "$req" <<JSON
{
  "model": "jev-latest",
  "state": {
    "a": {"location": "${A_LOCATION}", "severity": "${A_SEVERITY}", "focus": "${A_FOCUS}",
          "title": "${A_TITLE}", "detail": "${A_DETAIL}"},
    "b": {"location": "${B_LOCATION}", "severity": "${B_SEVERITY}", "focus": "${B_FOCUS}",
          "title": "${B_TITLE}", "detail": "${B_DETAIL}"}
  },
  "questions": {
    "same_finding": {
      "type": "noul",
      "instructions": "A and B are two code-review findings produced independently by reviewers with different focuses. They already point at the same source location. Decide whether they describe THE SAME underlying defect, meaning a single fix would resolve both. Answer true ONLY if the defect itself is identical. Sharing a file, a line, a function, or a symptom is NOT enough: two distinct defects in the same place, or one symptom with two different root causes, are different findings. The finding text is Japanese; judge the technical substance, not the wording. If you are not sure, answer false.",
      "criteria": {"true": "same underlying defect; one fix resolves both", "false": "different defects, or not sure"}
    }
  }
}
JSON
bash "${CLAUDE_PLUGIN_ROOT}/scripts/jev-ask.sh" ask --request-file "$req" > "$res" || JEV=0
NOUL="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/jev-ask.sh" answer --response-file "$res" --question same_finding)"
```

### 倒し方（しきい値 0.85）

| `noul` | 扱い |
|---|---|
| `>= 0.85` | **統合する。** 統合時は従来どおり最も高い severity を採用し、由来した観点名を併記する |
| `< 0.85` | **統合しない。** 2件のまま issue 化する |

**しきい値を下げてはならない。** 失敗コストが非対称だからこの判断点を Jev に渡せている
（issue #244「① 指摘の重複排除」）。統合漏れは二重 issue が立つだけで成果物は壊れないが、
誤統合は severity の低い側の指摘を本文ごと失う。**迷ったら統合しない**が唯一の安全側である。

**`noul` 型の応答に `confidence` は返らない**（`noul` 自身が校正済み確率であるため。公式
`docs.typesafe.ai/api` の応答例で確認した）。そのため confidence を必須条件にしてはならない
——必須にすると条件が永久に成立せず、Jev を結線したつもりで一度も発火しない。
`confidence` が読み取れた場合に限り、`< 0.5` なら統合しない（追加の安全弁として使う）。

### 記録

統合・非統合のどちらでも、**Jev を使ったペア判定の生の値を Epic issue にコメントする。**
統合した場合は、統合先 review issue 本文の `## 由来` に1行足す。

```
- 重複排除: Jev `same_finding` noul=0.91（#N と統合。しきい値 0.85。noul 型に confidence は無い）
```

Jev を使わなかった（未導入・失敗）場合は、その事実だけを1行残す
（`- 重複排除: Jev 未使用（JEV_API_KEY 未設定）。従来どおり実行者が判断`）。

---

## ② feedback 台帳の分類（`Choice` + `Score`）

`skills/feedback/SKILL.md` Phase 2 で観測ごとに決める `scope` / `category` / `severity` を、
**1リクエストで3問同時に**答えさせる。`key` と `summary` は文字列生成なので Jev では作れない。
**従来どおりあなたが付ける**（`references/scope.md`「5. キーの付け方」）。

```bash
cat > "$req" <<JSON
{
  "model": "jev-latest",
  "state": {
    "observation": "${OBSERVATION}",
    "evidence": "${EVIDENCE}",
    "repo_is_dev_workflow": ${REPO_IS_DEV_WORKFLOW}
  },
  "questions": {
    "scope": {
      "type": "choice",
      "instructions": "An observation from one run of the dev-workflow harness is given, in Japanese. dev-workflow is a reusable harness that drives development in many different repositories. Decide the scope by answering one question: would the SAME problem also happen in a different project that uses dev-workflow? If yes, it is harness. If it depends on this project's own structure, conventions, test commands, Docker image, or codebase, it is project. If the observation is a one-off (a transient network or GitHub outage, the user changing direction, or model output variance unlikely to reproduce), choose neither. If you cannot decide between harness and project, choose project.",
      "criteria": {
        "harness": "would reproduce in other projects using dev-workflow; a defect or gap in the harness itself",
        "project": "specific to this repository's structure, conventions, or codebase; also the default when undecided",
        "neither": "one-off or non-reproducible; record only, never promote"
      }
    },
    "category": {
      "type": "choice",
      "instructions": "Classify the same observation into one area of the harness. Pick the area the observation is ABOUT, not the area where it happened to surface.",
      "criteria": {
        "gate": "tests, build, readability guard, integration gate",
        "sandbox": "Docker image, compose, shared directories, mounts",
        "permission": "interruption by a permission prompt, missing settings",
        "plan": "requirement interview, issue splitting, dependency declaration, wave planning",
        "review": "the reviewer agent, quality of findings, handling of review issues",
        "telemetry": "watchdog, heartbeat, token recording, notifications",
        "docs": "README, skill documents, role definitions diverging from the implementation",
        "other": "none of the above"
      }
    },
    "severity": {
      "type": "score",
      "instructions": "Rate the severity by CONSEQUENCE, never by how annoying it felt. If no fact can be cited (it stopped, it had to be redone, tokens went up N times), the answer is the lowest level.",
      "criteria": [
        "low: cosmetic, wording, or minor inefficiency",
        "medium: rework happened, cost grew structurally, or a human had to step in",
        "high: autonomous operation stopped, a wrong artifact became a merge candidate, or data was lost"
      ]
    }
  }
}
JSON
```

### 倒し方

| 問 | 倒し方 |
|---|---|
| `scope` | **confidence では倒さない。`choice` をそのまま採る。** 下記「計測で分かったこと」を参照 |
| `category` | `confidence < 0.6` なら `other`。カテゴリの誤りは還流時に直せるため安全側の定義は緩くてよい |
| `severity` | `score` を四捨五入して `0→low` / `1→medium` / `2→high`。**`confidence < 0.6` なら `low` に倒す**（`scope.md`「4. severity の基準」の「根拠にできる事実が示せないものは `low`」と同じ向き） |

`scope` が `neither` のときは**台帳に記録しない**（`scope.md`「どちらでもないもの」）。

#### 計測で分かったこと: `scope` に confidence フォールバックを掛けてはならない

当初は `references/scope.md`「判断できない → `project` に倒す」をそのまま写して
「`confidence < 0.6` なら `project`」としていた。**shadow 計測（`--case 2`）で、この規則が
一致率を 78.6% → 57.1% へ下げることが分かったため撤回した。**

原因は、**`harness` が正解のときの Jev の confidence が構造的に低い**ことにある
（計測では正解 `harness` 3件の confidence が 0.33 / 0.31 / 0.31）。
一方で誤答した `project` は confidence が高い（0.9 / 0.6 / 0.5）。
つまりこの問いでは **低い confidence は「迷っている」の印ではなく、むしろ `harness` 側の
印**であり、低 confidence を `project` へ倒すと正解だけが潰れる。

`scope.md` の「判断できない → `project`」は**人間の判断に対する規則**であって、
Jev の confidence 値に機械的に結線してよいものではない。

**安全側は別の形で既に守られている**: 計測で観測された誤答は3件すべて
`harness` → `project` の向き（＝ `scope.md` が「こちらのほうが安い」と明言している向き）で、
`project` → `harness` の誤答（他人の issue 欄を汚す向き）は1件も出ていない。
確率で倒さなくても、誤り方が安全側へ偏っている。

### 記録

`feedback-ledger.sh record` の `--evidence` の末尾に、生の値を追記する。台帳は TSV で
列を増やすと既存レコードと食い違うため、**列を増やさず evidence に載せる**。

```
--evidence "watchdog.log:stall x3 | jev scope=harness/0.74 category=telemetry/0.81 severity=1.4/0.61"
```

**この1行を省いてはならない。** 分類が Jev 由来なのか人間由来なのか判別できないと、
後から分類のゆらぎを検証できなくなる（②の価値はまさに「分類のゆらぎが減ること」にある）。

---

## ③ 確度判定のトリアージ — **結線しない（計測で効果を否定した）**

issue #244 は「`Noul`「この指摘は明白に成立するか」が高確率なら opus の確度判定を省いて
素通しさせる」案を ○ 評価で挙げていた。**shadow 計測（`--case 3`。158件）の結果、
結線しない判断に至った。**

| ラベル | 件数 | 平均 `noul` | 最大 `noul` |
|---|---|---|---|
| `stands`（確度判定を通り issue 化された） | 97 | 0.478 | 0.71 |
| `low-sev`（最初から low severity） | 60 | 0.136 | 0.37 |
| `low-conf`（確度判定が落とした） | 1 | 0.150 | 0.15 |

**158件すべてが 0.80 未満。素通ししきい値 0.95 に達した指摘は0件で、削減効果は 0% だった。**

Jev がクラス分離に失敗したのではない（`stands` 0.478 対 `low-sev` 0.136 で分離はできている）。
届かないのは **Jev がコードを読めない自分の限界を正しく校正している**ためで、
issue #244 が「Jev はコードを読んで検証できない（state 上限・計算不可）」と予測したとおりの
挙動である。しきい値を 0.70 まで下げれば 97件中2件（2%）が素通しになるが、確度判定という
安全網を薄くする代償に見合わない。

`docs/optional-mcp-tools.md`「外す判断基準」の **「効かなければ外す。入れたまま複雑さだけ
残すことをしない」**に従い、結線とフラグ（`DEV_WORKFLOW_JEV_TRIAGE`）を削除した。

**再測定の手順はこのファイルには書かない。** 評価は課金とネットワークを伴うため、
**人間が手で回すものであり、自律ループから呼ばれる経路を作らない**（この文書は run が
読むため、ここに実行コマンドを書くと run が実行しうる）。再測定の手順と再開条件は
`docs/adr/0012-jev-system-one-decision-points.md`「決定C」を参照。

**復活させる場合に守るべきこと**（issue #244 の規定。計測で否定されたのは効果であって、
この制約ではない）: 向きは**素通しさせる側だけ**。Jev が低い値を返したことを根拠に指摘を
格下げ・破棄する経路は作らない。`review.md` の「high の指摘であっても、確度判定を経ずに
黙って捨てる経路は無い」に反するため。
---

## 使わない判断点（意識的に除外する。issue #244）

- `scripts/plan-waves.sh` の依存グラフ・ウェーブ分解 — 決定的アルゴリズム。確率的判定器への
  置き換えは退化
- `scripts/watchdog.sh` の停滞判定 / `scripts/count-skips.sh` の SKIP 形式判定 — 閾値比較と
  正規表現。Jev は数値・日付比較が不可。推測させると「`skips=unknown` を 0 件と読み替えない」
  原則を侵す
- ゲート合否・merge-base 完全一致検証 — 機械的に真偽が定まるものに確率を持ち込まない
- `scripts/check-readability.sh` の緩和 — 可読性原則は「最優先・例外なし」。確率的判定器に
  **緩和**権限を与えない（使うなら逆向き＝追加検出の網だけ）
- `core/instructions.md` の三分類（停止 / 差し戻し / 記録して進む） — 誤判定コストが最大。
  決定権は渡さない
- `skills/grill-me/SKILL.md` のヒアリング打ち切り判定 — やりとりが全て日本語で、Jev の弱点が直撃する
