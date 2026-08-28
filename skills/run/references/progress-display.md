# 進捗表示と計測（run スキル参照資料）

`skills/run/SKILL.md` の Step 1 / Step 4 / Step 7 から参照される表示フォーマットと、PR 本文への集計。

## 進捗表示

本Epicは並列化とオーバーヘッド削減の2つを同時に行うため、**両者の寄与を別々に読めるように**
計測を分けて表示する（「実装」= 並列化の寄与、「統合」= 並列化が追加で持ち込むコスト・
直列に残るコスト）。フルスイートはウェーブ単位では走らせず Epic につき1回に集約したため、
`GATE_SEC` はウェーブ単位では計測しない（可読性ガードの所要時間は「統合」= `MERGE_SEC` に含める）。
`EPIC_GATE_SEC` は Epic 統合ゲート（全ウェーブ完了後の1回）の所要時間として別に計測する。
時刻の取得に追加の依存物（`jq` 等）は使わず、`date +%s` の差分だけで計測する
（`fmt_duration` ヘルパーは「自律ループ」節冒頭で定義済み）。

### Step 1 の直後（ウェーブ開始時）に表示するバナー

```
═══════════════════════════════════════
  Run: Epic $ARGUMENTS [YOLO / lanes=[LANES]]
  ウェーブ: [ウェーブ番号] / [総ウェーブ数]   タスク: [完了数] / [全タスク数] 完了（スキップ [スキップ数]）
  レーン: A=#[番号A] B=#[番号B] C=#[番号C]
  前ウェーブ: [PREV_WAVE_*が空なら「(初回のため計測なし)」／それ以外は下記の内訳]
═══════════════════════════════════════
```

「前ウェーブ」の行は次の形式（Step 7 で確定させた `PREV_WAVE_*` を使う）:

```bash
if [ -n "$PREV_WAVE_IMPL_SEC" ]; then
  PREV_TOTAL_SEC=$((PREV_WAVE_IMPL_SEC + PREV_WAVE_MERGE_SEC))
  echo "前ウェーブ: 実装 $(fmt_duration "$PREV_WAVE_IMPL_SEC") + 統合 $(fmt_duration "$PREV_WAVE_MERGE_SEC") = $(fmt_duration "$PREV_TOTAL_SEC")"
else
  echo "前ウェーブ: (初回のため計測なし)"
fi
```

「[総ウェーブ数]」は `plan-waves.sh` の出力からは得られない（残タスクからの再計算のため、既に
完了したウェーブ数を含む総数は自明ではない）。**Epic issueの「タスク一覧」節に列挙されたウェーブ
数を初回に数えて控えておき、以降はその値を使い回す**（スキップの伝播で後続ウェーブが減っても、
「予定していたウェーブ数」としてそのまま使ってよい。厳密な再計算は要求しない）。

### Step 4 の直後（サブバッチ完了時）に表示するレーン結果

```
レーン結果: A=#5(12:03-12:11 8m00s) B=#10(12:03-12:09 6m00s) C=#11(12:03-12:07 4m12s)
```

各generatorが報告した開始・終了時刻（Step 3 のプロンプトで要求済み）をもとに組み立てる。
レーン内ゲートに失敗したレーンは末尾に `失敗` を添える。

### Step 7 の直後（ウェーブ完了時）に表示するウェーブ合計

```bash
echo "前ウェーブ: 実装 $(fmt_duration "$IMPL_SEC") + 統合 $(fmt_duration "$MERGE_SEC") = $(fmt_duration "$WAVE_TOTAL_SEC")"
```

これは次ウェーブのバナーで使う文言と同じ（`PREV_WAVE_*` に格納した値をそのまま使う）。

### 「Epic 統合ゲート」節の直後（全ウェーブ完了後）に表示するEpic統合ゲート結果

```bash
echo "Epic統合ゲート: $(fmt_duration "$EPIC_GATE_SEC")"
```

### PR本文への集計（Epic完了時）

全ウェーブ完了後、PR本文（後述「PR作成」節）に次の集計を載せる。`TOTAL_IMPL_SEC` /
`TOTAL_MERGE_SEC` は Step 7 で毎ウェーブ加算した累計、`EPIC_GATE_SEC` は「Epic 統合ゲート」節で
Epicにつき1回だけ計測した値、`WAVE_NO` は実行した総ウェーブ数、`DONE_TASK_COUNT` は
取り込めたタスク数である。

```
## 実行時間
- ウェーブ数: [WAVE_NO] / タスク数: [DONE_TASK_COUNT] / 並列度: [LANES]
- 実装合計: [fmt_duration TOTAL_IMPL_SEC] / 統合合計: [fmt_duration TOTAL_MERGE_SEC] / Epic統合ゲート: [fmt_duration EPIC_GATE_SEC]
- 総所要時間: [fmt_duration (TOTAL_IMPL_SEC + TOTAL_MERGE_SEC + EPIC_GATE_SEC)]
```

これにより、次に何を削るべきか（LLM時間か、Epic統合ゲートの待ち時間か、統合処理か）が実測で分かる。
並列化タスク（#15・#16・#18・#20・#21・#22）とオーバーヘッド削減タスク（#17・#19・#23・#144）の
どちらの寄与が大きかったかは、複数Epicでこの集計を比較することで読み取れる。

### PR本文への「トークン消費」集計（効果測定。Task #76）

「実行時間」の隣に、`record-agent-tokens.sh --summary` の出力をそのまま載せる:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/record-agent-tokens.sh" --summary --epic "$EPIC_NUM"
```

```
## トークン消費
[record-agent-tokens.sh --summary --epic "$EPIC_NUM" の出力をそのまま貼る]

比較対象（Epic #42実測。docs/optional-mcp-tools.md「効果測定のベースライン」参照）:
generator タスク実装 81k〜150k / evaluator delta-review 83k / evaluator epic-review 139k。
```

1件も記録できていない場合（トークン数が一度も読み取れなかった等）は、このセクション自体を
省略してよい。**記録の有無はPR作成のブロッカーにしない。**

