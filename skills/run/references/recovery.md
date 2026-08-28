# 失敗時のリカバリ（run スキル参照資料）

`skills/run/SKILL.md`「Step 8: 失敗時のリカバリ」から参照される。**失敗が起きたときにだけ読む。**

### Step 8: 失敗時のリカバリ

**共通原則: 失敗したレーンだけを落とし、先に取り込めたレーンの成果は活かす。ウェーブ全体は捨てない。**

| 失敗パターン | 扱い |
|---|---|
| レーン内ゲート失敗 | waveに取り込まず、試行回数を保持したまま次ウェーブへ持ち越す。**ウェーブ内では再試行しない** |
| `merge-lane.sh` exit 10（ベース逸脱） | 取り込まず差し戻す。実出力をissueにコメント。**cherry-pick載せ替えはしない** |
| `merge-lane.sh` exit 11（競合） | 取り込まず、競合ファイル一覧と相手レーンをissueにコメント。次ウェーブで再実行 |
| 競合で2回失敗 | 次ウェーブで**単独レーン**（`lanes=1`相当のサブバッチ）として実行する |
| 同一タスクで3回失敗 | スキップする。issueにコメントし、`SKIPPED_CSV` に加える（以降の`plan-waves.sh`呼び出しの`--skipped`に反映される） |
| 統合ゲート失敗 | Epicは無傷のまま。WAVE_BASEからwaveブランチを作り直し、レーンを1本ずつ「マージ→ゲート」で積んで原因レーンを一意に特定する。特定したレーンだけ差し戻し、残りは活かす |

**「ウェーブ内で再試行しない」理由**: バリア同期のため、ウェーブ内の再試行は完了済みの他レーンを
待たせ続けるだけになる。次ウェーブに回せばベースが進むだけで、「先行タスクの変更が無かった
せいで落ちた」「同じ行を触ったせいで競合した」類の失敗は自然に解消する。

#### 統合ゲート失敗時の原因特定手順

この時点で `wave/${EPIC_NUM}/${WAVE_NO}` は checkout 中のブランチであり、`git branch -f` は
チェックアウト中のブランチの強制更新を拒否する。**`git checkout -B` で作り直すこと**
（`git branch -f` の後に `git checkout` を続ける2行構成にはしない）。

```bash
cd "$EPIC_WT"
git checkout -B "wave/${EPIC_NUM}/${WAVE_NO}" "$WAVE_BASE"

# レーンを1本ずつ merge-lane.sh で取り込み、そのつどゲートを実行する
bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-lane.sh" \
  --wave-branch "wave/${EPIC_NUM}/${WAVE_NO}" --expected-base "$WAVE_BASE" \
  --lane-branch "[レーン1の作業ブランチ]" --task <番号1>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --epic "$EPIC_NUM" '[全テストを走らせるコマンド]'
# 通れば次のレーンを取り込んでまたゲートを実行する。落ちた時点のレーンが原因と一意に特定できる
```

#### スキップの伝播

スキップされたタスクに依存する後続タスクは、`plan-waves.sh` の出力（`skip <番号> reason
depends-on-skipped <依存先番号>`）に従って実行せずスキップし、Task issueにその旨をコメントする
（推移的に伝播する）。スキップ一覧は**Epic一括レビュー前にEpic issueへコメントし、PR本文にも
明記して人間に判断を渡す**（詳細は「Epic一括レビュー」節）。

