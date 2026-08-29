---
name: feedback
description: ハーネスの実行ログを分析し、プロジェクト固有の改善はその場で反映し、dev-workflow本体起因の指摘は台帳に溜めて閾値到達後にissueとして還流する。
argument-hint: "[--since 7 | --epic N | --upstream | --list]"
---

## 目的

`/dev-workflow:run` などのハーネスが残した実行ログとセッション transcript を読み、
**次の実行が今回より良くなるための差分**を取り出す。任意のタイミングで手動起動する。

このスキルは3つを分けて扱う:

| 種別 | どこへ反映するか | 誰が承認するか |
|---|---|---|
| プロジェクト固有の知見 | 台帳の `learnings.md`、承認を得た場合のみプロジェクトの `CLAUDE.md` 等 | ユーザー（毎回） |
| dev-workflow 本体起因の問題 | 台帳に蓄積 → 閾値到達で還流先リポジトリへ issue | ユーザー（投稿前に本文を確認） |
| 1回きりのノイズ | 台帳に記録するだけ。何も変更しない | 不要 |

**なぜ台帳を挟むのか**: 1回の事故で恒久ルールを書いたり issue を立てたりすると、
誤検知がそのまま定着する。**同じキーが閾値回数（既定3回）再現して初めて反映・還流を提案する。**

## 絶対に守る範囲（最初に読むこと）

**レビューと修正の対象は、実行中のプロジェクト固有の範囲に限定する。**

- 書き換えてよい: 台帳ディレクトリ配下（`learnings.md` 等）、および**ユーザーが個別に承認した**
  プロジェクト内のファイル（`CLAUDE.md`、`.claude/settings.local.json`、プロジェクトのドキュメント）
- 書き換えてはならない: `${CLAUDE_PLUGIN_ROOT}` 配下のすべて（＝dev-workflow プラグイン本体）。
  ハーネス起因の問題は**その場で直さず、還流させる**
- 触れてはならない: 駆動先リポジトリの `.gitignore`（README「ハーネス非注入原則」）
- 台帳は `${HOME}/.claude/dev-workflow/feedback/<repo>/` に置く。**駆動先リポジトリには一切書き込まない**

**唯一の例外**: 駆動先が dev-workflow リポジトリ自身のとき（`repo.is_dev_workflow=1`）は、
ハーネス起因＝プロジェクト固有なので、通常の修正対象として扱ってよい。還流は不要。

判断に迷ったら `references/scope.md` を読む。

## Phase 0: 信号を集める

探索を自然言語に任せず、決まった場所を決まった順で見る。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/collect-feedback-signals.sh" --since 7
```

`$ARGUMENTS` に `--since N` / `--epic N` があればそのまま渡す。
出力は `キー=値` の羅列で、以下を含む:

- `repo.is_dev_workflow` … 上の「唯一の例外」に該当するか
- `runstate.*` … 中断した run が残っているか（epic / wave / 経過時間）
- `watchdog.stall_count` / `escalate_count` / `abort_count` … 停滞の回数
- `tokens.by.<role>:<mode>` … role 別のトークン消費（コスト劣化の一次証拠）
- `transcripts.N.path` … 読むべきセッションログのパス（新しい順）
- `transcripts.truncated` … `1` なら上限で打ち切られている。**「全部見た」と書かない**
- `ledger.*` … 既存の観測数と閾値到達数

`$ARGUMENTS` が `--list` のときはここで台帳を表示して終了する:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" list
bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" ready
```

`$ARGUMENTS` が `--upstream` のときは Phase 1〜3 を飛ばして Phase 5 だけを実行する。

## Phase 1: 実行ログを読む

`transcripts.N.path` の新しいものから最大5件を読む。**1件が数百〜数千行あるので全文は読まない。**
Grep で当たりを付けてから、該当箇所の前後だけを読むこと。

探すもの（`references/scope.md` に分類の詳細がある）:

1. **ユーザーの訂正** — 「そうじゃなくて」「違う」「やり直して」「なぜ〜しなかった」
2. **同じ作業のやり直し** — 同一ファイルへの連続した Edit、同じテストの反復失敗
3. **ゲートの空振り** — テスト・ビルド・可読性ガードが落ちた回数と、その原因の偏り
4. **権限の中断** — 許可プロンプトで自律動作が止まった箇所
5. **サンドボックスの失敗** — イメージ・compose・共有ディレクトリ由来のエラー
6. **停滞** — `watchdog.stall_count` が立っている時間帯の transcript
7. **スキップ** — SKIP されたタスクと、その理由の偏り
8. **コスト** — `tokens.by.*` の avg が過去と比べて跳ねている role/mode
9. **ドキュメントとの乖離** — README や SKILL.md の記述どおりに動かなかった箇所

**証拠のない推測を観測として記録しない。** 各項目は transcript の行、ログの行、
数値のいずれかを根拠として持てること。持てないものは捨てる。

## Phase 2: 分類してキーを付ける

観測ごとに次を決める。

- `scope`: `project`（このプロジェクト固有）か `harness`（dev-workflow 本体の話か）
- `category`: `gate` / `sandbox` / `permission` / `plan` / `review` / `telemetry` / `docs` / `other`
- `key`: 再現回数を数える単位。**同じ現象には毎回同じキーを付ける。**
  既存キーを再利用するため、新しいキーを作る前に必ず `ledger list` の既存キーを確認する
- `severity`: `high`（自律動作が止まる・誤った成果物が出る） / `medium`（手戻りが発生する） / `low`（軽微）
- `summary`: 1行。**この時点でプロジェクト固有の固有名詞を含めない**（還流時にそのまま使う）

## Phase 3: 台帳に記録する

分類した観測をすべて記録する。**この段階では何も修正しない。**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" record \
  --scope <project|harness> --category <slug> --key <slug> \
  --severity <high|medium|low> --epic <N> \
  --summary "<1行要約>" --evidence "<根拠のファイル:行 や 数値>"
```

記録が終わったら、今回の観測を一覧で報告する（scope / key / severity / summary）。

## Phase 4: プロジェクト固有の反映（承認ゲート）

閾値に達した `project` スコープのキーを取り出す:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" ready --scope project
```

0件なら「今回反映するものはない」と報告して Phase 5 へ進む。**無理に何か直さない。**

1件以上あれば、キーごとに次を提示してユーザーの承認を求める:

- 何が何回起きたか（根拠つき）
- どのファイルをどう変えるか（具体的な差分）
- 変えない場合に何が起き続けるか

承認されたものだけを適用する。適用先の優先順位:

1. 台帳の `learnings.md`（常に安全。次回の Phase 1 で最初に読む）
2. プロジェクトの `CLAUDE.md`（**プロジェクトの知識**である場合のみ。ハーネス都合の設定は書かない）
3. `.claude/settings.local.json`（権限の追加。**git 追跡されていないことを確認してから**）

`learnings.md` は台帳ディレクトリ直下に置く:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" path
```

## Phase 5: dev-workflow への還流（承認ゲート）

`repo.is_dev_workflow=1` のときはこの Phase を飛ばし、代わりに Phase 4 と同じ手順で
ハーネス起因の指摘を直接修正する（＝それがこのプロジェクトの仕事だから）。

そうでない場合、閾値に達した `harness` スコープのキーを取り出す:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" ready --scope harness
```

キーごとに `references/upstream.md` の手順に従う。要点だけ再掲する:

- 本文は `feedback-ledger.sh render-upstream --key <slug>` が生成する（機械的 redact 済み）
- **機械的 redact は最後の網であって唯一の防御線ではない。** 生成された本文を読み、
  社名・未公開仕様・コード片・独自の用語が残っていたら書き換える
- **本文全文をユーザーに見せ、投稿の可否を明示的に確認する。** 承認なしに投稿しない
- 投稿先は `feedback-ledger.sh upstream-repo` が返す owner/repo（fork 配布でも正しく解決される）
- `gh` が未認証、またはユーザーが投稿を望まない場合は、本文を台帳配下のファイルに保存して
  パスを案内する。**投稿しなかったことを成功と報告しない**

## 完了報告

次を1画面で報告する。

```
══════════════════════════════════════════
  フィードバック分析 完了
  対象: 直近 [N] 日 / transcript [M] 件（打ち切り: あり/なし）
  新規観測: [K] 件（project [x] / harness [y]）
  反映: [適用したファイル、または「なし」]
  還流: [作成したissueのURL、または「なし（理由）」]
  台帳: [パス]
══════════════════════════════════════════
```

**何も見つからなかった場合は「何も見つからなかった」と報告する。**
成果を作るために弱い指摘を昇格させない。

## 参照

- `references/scope.md` … 修正範囲の境界と、project / harness の分類基準
- `references/upstream.md` … redact 規約と issue 化の手順
