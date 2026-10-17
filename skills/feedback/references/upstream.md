# dev-workflow への還流手順

`skills/feedback/SKILL.md` の Phase 5 から参照される。

**このプラグインを配布した先で見つかった問題を、配布元へ戻すための経路である。**
戻ってきた issue は `/dev-workflow:plan` → `/dev-workflow:run` で処理され、
次のリリースでプラグイン本体が改善される。これが自己フィードバックループの外周にあたる。

## 前提

- 還流させるのは `scope=harness` かつ閾値に達したキーだけ
- 駆動先が dev-workflow 自身のとき（`repo.is_dev_workflow=1`）は還流しない。その場で直す
- **ユーザーの明示的な承認なしに投稿しない。** 外部サービスへの送信は取り消せない
- **GitHub操作について**: 以下の `gh issue create` / `gh issue list --search` は
  **ghバックエンドでの実行例**である。選択規則・MCP（`mcp__github__*`）との対応表は
  `core/references/github-access.md` が正本であり、ここでは再掲しない。`gh` が使えない
  環境では同文書の対応表から該当する `mcp__github__*` ツールを選ぶ

## 手順

### 1. 還流先を解決する

```bash
UPSTREAM="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" upstream-repo)"
echo "還流先: ${UPSTREAM}"
```

プラグインのマニフェストの `repository` から引くので、fork して配布された環境では
その fork が還流先になる。社内ミラーへ送りたい場合はユーザーが
`DEV_WORKFLOW_UPSTREAM_REPO=owner/repo` を設定する。

### 2. 本文を生成する

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" render-upstream --key <slug>
```

生成される本文は機械的に redact 済み（HOME・ユーザー名・リポジトリ名・メールアドレス・
GitHub / Slack / API のトークン様文字列・Windows と POSIX のホームパス）。

### 3. 人間の目で redact を仕上げる

**機械的 redact は最後の網であって、唯一の防御線ではない。**
生成された本文を自分で読み、次が残っていたら書き換える:

- 社名・製品名・チーム名・顧客名
- 未公開の仕様、社内用語、チケット番号
- コード片、テーブル名、カラム名、API のパス、環境固有のホスト名
- ディレクトリ構成から業務内容が推測できる記述

**判断に迷ったら消す。** 還流に必要なのは「dev-workflow のどこが、どういう条件で、
どう壊れたか」であって、駆動先プロジェクトの中身ではない。

現象を再現条件つきで一般化して書き直すこと。

- 悪い例: 「`services/billing/invoice_test.go` のテストで可読性ガードが誤検知した」
- 良い例: 「Go のテーブル駆動テストで、テーブル定義の行数が閾値を超えると可読性ガードが誤検知する」

### 4. 承認を得る

**本文の全文をユーザーに見せる。** 要約で済ませない。そのうえで確認する:

- 投稿先の owner/repo
- issue のタイトル
- 本文全文

ユーザーが承認した場合のみ次へ進む。

### 5. 投稿する

まず `gh` が使えるか確認する（#268 の判定を再実装しない）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" gh-available
```

exit 0（使える）なら `gh` バックエンドで投稿する:

```bash
gh issue create --repo "${UPSTREAM}" \
  --title "<タイトル>" \
  --body-file "<本文を書き出したファイル>" \
  --label "feedback"
```

- タイトルは現象を1行で。`[feedback] ` の接頭辞を付ける
- `--label` が存在しないリポジトリではラベル指定を外して再実行する（ラベルの有無で投稿を止めない）
- 本文は `--body` に直接渡さず、いったんファイルへ書き出してから `--body-file` で渡す
  （改行・引用符・日本語がシェルを通る回数を減らすため）

exit 1（使えない）なら `mcp__github__*` の issue 作成ツール（`core/references/github-access.md`
の対応表参照）で同じ内容（owner/repo・タイトル・本文・ラベル）を投稿する。

### 6. 投稿できないときの扱い

次の場合は投稿せず、本文を保存してパスを案内する:

- `gh` も MCP も使えない、またはいずれも失敗した
- ユーザーが投稿を承認しなかった
- ネットワーク・権限エラーで作成が失敗した

保存先は `unreflected-path` が返す絶対パスを使う（`${LEDGER_DIR}/upstream/<key>.md` を
手で組み立てない。保存先ディレクトリも事前に作られる）:

```bash
UNREFLECTED_PATH="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" unreflected-path --key "<key>")"
```

**投稿しなかったことを「還流済み」と報告しない。** 完了報告には
「還流: なし（gh/MCPが使えないため本文を保存: <パス>）」のように理由とパスを書く。
台帳の観測記録自体は残るため（レコードを削除しない）、次回 `ready --scope harness` で
同じキーが再び拾われ、後から還流し直せる（記録が失われない）。

## 重複を作らない

同じキーで既に issue を作っている場合、新しい issue を立てずに既存 issue へコメントする。
`gh` が使える場合:

```bash
gh issue list --repo "${UPSTREAM}" --search "<key> in:body" --state all --json number,title,state
```

`gh` が使えない場合は `mcp__github__*` の issue 検索ツールで同じ条件（`<key> in:body`）を
検索する。`render-upstream` の本文にはキーが `` `<key>` `` として入るので、検索で拾える。
既存 issue があれば、追加の観測回数と新しい根拠だけをコメントする。
