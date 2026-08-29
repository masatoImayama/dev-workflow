# dev-workflow への還流手順

`skills/feedback/SKILL.md` の Phase 5 から参照される。

**このプラグインを配布した先で見つかった問題を、配布元へ戻すための経路である。**
戻ってきた issue は `/dev-workflow:plan` → `/dev-workflow:run` で処理され、
次のリリースでプラグイン本体が改善される。これが自己フィードバックループの外周にあたる。

## 前提

- 還流させるのは `scope=harness` かつ閾値に達したキーだけ
- 駆動先が dev-workflow 自身のとき（`repo.is_dev_workflow=1`）は還流しない。その場で直す
- **ユーザーの明示的な承認なしに投稿しない。** 外部サービスへの送信は取り消せない

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

```bash
gh issue create --repo "${UPSTREAM}" \
  --title "<タイトル>" \
  --body-file "<本文を書き出したファイル>" \
  --label "feedback"
```

- タイトルは現象を1行で。`[feedback] ` の接頭辞を付ける
- `--label` が存在しないリポジトリではラベル指定を外して再実行する（ラベルの有無で投稿を止めない）
- 本文は `--body` に直接渡さず、いったんファイルへ書き出してから `--body-file` で渡す
  （改行・引用符・日本語がシェルを通る回数を減らすため）。書き出し先は台帳配下:

```bash
LEDGER_DIR="$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/feedback-ledger.sh" path)"
mkdir -p "${LEDGER_DIR}/upstream"
# -> ${LEDGER_DIR}/upstream/<key>.md
```

### 6. 投稿できないときの扱い

次の場合は投稿せず、本文を `${LEDGER_DIR}/upstream/<key>.md` に残してパスを案内する:

- `gh auth status` が失敗する（未認証）
- ユーザーが投稿を承認しなかった
- ネットワーク・権限エラーで `gh issue create` が失敗した

**投稿しなかったことを「還流済み」と報告しない。** 完了報告には
「還流: なし（未認証のため本文を保存: <パス>）」のように理由とパスを書く。

## 重複を作らない

同じキーで既に issue を作っている場合、新しい issue を立てずに既存 issue へコメントする。

```bash
gh issue list --repo "${UPSTREAM}" --search "<key> in:body" --state all --json number,title,state
```

`render-upstream` の本文にはキーが `` `<key>` `` として入るので、検索で拾える。
既存 issue があれば、追加の観測回数と新しい根拠だけをコメントする。
