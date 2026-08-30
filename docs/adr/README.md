# ADR（Architecture Decision Record）索引

**ADR は設計判断の記録であり、使い方の説明は README に書く。** ここには「なぜその設計を選んだか・
何を却下したか」だけを記録する。ハーネスの使い方・コマンド一覧・環境変数などの説明は
リポジトリルートの `README.md`（または `docs/dev-workflow-handover.md`）を参照すること。

## 一覧

| 番号 | タイトル | 決定の要約 | 状態 |
|---|---|---|---|
| [0001](0001-integration-gate-at-epic-end.md) | 統合ゲート（フルスイート実行）を Epic 末の1回に集約する | ウェーブごとのフルスイート実行をやめ、プロジェクトの全テストは Epic につき1回、全ウェーブ完了後に集約する。ウェーブ単位の安全網は取り込み検証（merge-base 完全一致検証＋可読性ガード）に置き換える | 承認済み（Task #144） |
| [0002](0002-sandbox-overhead-reduction.md) | サンドボックス呼び出しオーバーヘッドの削減 | `sandbox-exec.sh` の呼び出しごとの固定オーバーヘッド（docker CLI 複数回呼び出し）を fast path 判定で削減する | 採用（Task #145） |
| [0003](0003-parallel-review-by-focus.md) | 観点別レビュー（focus）とウェーブ差分の先行レビュー（wave-review） | evaluator に観点（correctness / readability / over-engineering / security）指定と `wave-review` モードを追加し、レビューの並列化とウェーブ間オーバーラップの土台を作る | 承認済み（Task #147） |
| [0004](0004-cross-wave-lane-reuse.md) | レーンのウェーブ横断維持（cross-wave lane reuse）は見送る（未実装のまま） | ウェーブをまたいでレーン（generator）を継続させる機構（`SendMessage`）自体は存在するが、本 Epic のスコープでは実装・実地検証していないため、現状は毎ウェーブ新規 spawn する方式を維持する。Task #153 時点の「手段が存在しない」という結論は誤りであり、Task #152 で訂正した | 承認済み・見送り（Task #153、Task #152 で記述を訂正） |
| [0005](0005-edit-time-check-hook.md) | 編集時チェック（PostToolUse フック） | generator の編集直後にホスト側で型/lint の軽量チェックを行い、`sandbox-exec.sh` 経由のビルド/テスト往復の一部を削減する | 採用（Task #155） |
| [0006](0006-evaluator-model-split.md) | evaluator を「発見は sonnet、確度判定は opus」に変える | 観点別レビューの発見役を sonnet で並列に回し、拾った指摘の確度判定だけを opus に寄せることで、レビューの直列区間のコストを下げる | 承認済み（Task #157） |
| [0007](0007-share-prepared-dirs-copy-fallback.md) | symlink 失敗時のコピー・フォールバック（Windows バインドマウント環境） | Windows + Docker Desktop 環境での `ln -s` 失敗（issue #139）そのものは再現できなかったため symlink 方式は据え置き、`link-failed` になったエントリに限り実体コピー（`cp -a`。ハードリンクは不採用）を追加で試みる防御を入れる | 承認済み（Task #139） |
| [0008](0008-node-modules-named-volume-deferred.md) | レーン専用 `node_modules` の named volume 化は据え置く | レーンごとの named volume 化は「コンテナ=epic」共有コンテナモデルと構造的に衝突し `docs/adr/0002` 決定2の却下理由と一致するため実装しない。`--print-plan` が compose/none モードでも `cache_volume` 行を誤って出力していたバグは修正した | 承認済み・据え置き（Task #104） |
| [0009](0009-flaky-suite-mitigation-deferred.md) | 統合ゲートの flaky スイート対策（issue #114）は前提未確認のため見送る | issue #114 が対策要否判定の前提とした「並行 install の解消」が #176 の実測でまだ確認されていないため、独立した flaky/回帰判定ロジックの実装を見送る。単純なリトライは前提の確認状況に関わらず不採用。再開条件は #176 の実測結果に連動させる | 承認済み・見送り（Task #114） |
| [0010](0010-plugin-script-permission-wrapper-deferred.md) | プラグインスクリプトの許可集約ラッパー（issue #131）は観測不足のため実装を保留する | 狭い許可運用チームでの許可エントリ増殖再発の有無・より低コストなワイルドカード許可1本での緩和の有効性・Codex `execpolicy` 側の対応可否のいずれも本タスクの範囲では確認できなかったため、ラッパー実装（(A)）・wontfix確定（(B)）のいずれも行わず判断を保留する。再開条件を明記した | 保留（Task #131） |
| [0011](0011-invariant-level-review-checks.md) | 修正が同じ性質の欠陥を作り直す事故への対策は、案1・2のみ実装し案3は見送る | issue #197 が提示した3案のうち、記述追加だけで済む案1（review issueテンプレートに「守るべき性質」の言語化を促す指示を埋め込む）・案2（evaluatorのcorrectnessチェックリストに確認項目を追加）を実装した。既存テストの整理を伴う案3（不変条件テストの明示的カテゴリ化）は、案1・2の効果がまだ観測されていないことと過剰実装の回避を理由に見送り、再開条件を明記した | 承認済み・案3は見送り（issue #197） |

## 命名・運用ルール

- ファイル名は `NNNN-短い英語スラッグ.md`（4桁の連番＋ハイフン区切りの英語スラッグ）
- 新しい ADR を追加したら、この索引の表に1行追加すること（Epic 完了時の最終整合タスクだけでなく、
  ADR を新規作成したタスク自身がこの表を更新するのが望ましい）
- 状態は ADR 本文の「ステータス」節をそのまま短縮して転記する（「承認済み」「採用」「見送り」等）
