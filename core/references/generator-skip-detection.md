# generator: SKIP検出の背景説明・詳細（count-skips.sh）

**いつ読むか**: `skips=unknown` になった、または「なぜ tail 目視ではダメなのか」の背景を
確認したいときにだけ読む。`core/roles/generator.md`「#### SKIP を通過扱いにしない」の詳細版。

依存物が未配置だとテストが無言で `SKIP` され、`ok` と表示されて**成功に見える**。

```
--- SKIP: TestE2E_Foo (0.00s)
PASS
ok  	example.com/pkg	0.032s
```

`ok` の有無だけで判定しない。**SKIP件数は `tail` で目視して報告してはならない。**
テスト出力を証跡ファイルへ保存し、`scripts/count-skips.sh` で機械的に数える。

`$SKIP_OUT` は `count-skips.sh` の3行（`skips=<件数|unknown>` /
`runner=<go|pytest|jest|custom|unknown>` / `pattern=<使用したERE|none>`）で、
終了コードは `0`=数えられた `1`=数えられなかった（`skips=unknown`）。

- `skips=<件数>`（exit 0）→ 報告の1行にその件数を書く。**想定外の SKIP は不合格として扱う**
- `skips=unknown`（exit 1）→ **報告の1行に「0件」と報告してはならない。** built-in ランナー
  （go/jest/pytest）と異なる形式のため数えられなかったことを明示し、
  `DEV_WORKFLOW_SKIP_PATTERN`（run から渡された場合は Epic 本文の `## SKIPパターン` 節に
  由来する）の設定が必要である旨を報告する。渡されていない場合は、`tail` ではなく
  `$EVIDENCE_FILE` の生のテスト出力全体を自分の目でも確認したうえでその旨を報告する
