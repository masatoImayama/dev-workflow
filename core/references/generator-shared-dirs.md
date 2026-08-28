# generator: 共有ディレクトリ運用の詳細（share-prepared-dirs.sh）

**いつ読むか**: run から共有ディレクトリの指定（Epic 本文の `## 共有ディレクトリ` 節に由来する
`--source` / `--spec` 等の引数）が渡されたときにだけ読む。`core/roles/generator.md`
「共有ディレクトリの指定がある場合は share-prepared-dirs.sh を呼ぶ」の詳細版。

run から**共有ディレクトリ**の指定（Epic 本文の `## 共有ディレクトリ` 節に由来する
`--source` / `--spec` 等の引数）が渡された場合、上記の準備コマンドを自分で直接実行せず、
`scripts/share-prepared-dirs.sh` を**自分の作業ディレクトリで1回だけ**呼ぶ。このスクリプトは
Epic 専用 worktree に既にある準備成果（`node_modules` 等）を symlink で共有し、共有できなかった
分だけ（`--run-prep` が渡されていれば）準備コマンドを代行実行する。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/share-prepared-dirs.sh" --source "<Epic専用worktreeの絶対パス>" \
  --epic epicXX --spec "<共有ディレクトリ節の内容>" --run-prep "<準備コマンド>"
```

- スクリプトの実出力（各 `linked`/`skip` 行と、最後の `prep=<skip|run|done-already>` 行）を
  **完了報告にそのまま貼る**（自己申告にしない）
- **`prep=run`（共有できなかった）場合でも、自前で準備コマンドを追加実行しない。**
  `--run-prep` を渡していればスクリプト自身が既に実行している。渡していなければ何もしない
  （run 側の結線の問題であり、generator が肩代わりしない）
- `prep=done-already` の場合は既に準備済みなので、そのまま実装に進む
- **exit 3（ロック競合）を受け取ったら、待ったり2本目を起動したりしない。** 同一 worktree に
  2本目の準備コマンドを並行実行してネイティブバイナリを破損させた事故（issue #104）の直接の
  再発防止である。exit 3 が返ったら実装に進まず、その事実を完了報告に含めて停止する
- exit 4（`--run-prep` に渡したコマンドが失敗した）の場合も実装に進まず、その事実を報告する
- **共有ディレクトリが複数あり一部だけ共有できた場合（prep=run）、`--run-prep` に渡した
  コマンドが linked 済みの共有symlink越しに共有元へ書き込むことは無い。** スクリプト自身が
  実行直前に linked 済みエントリの共有symlinkを全て解除してから準備コマンドを実行する
  （Review #116）。generator 側で個別に `--detach` を挟む必要は無い
- **依存マニフェスト（`package.json` / lockfile 等）を変更するタスクでは、install 系コマンドを
  実行する前に `--detach --dir <共有ディレクトリ>` で共有リンクを解除する。** 解除せずに
  install すると、symlink 越しに共有元（Epic 専用 worktree）と他レーンの成果を壊す
  （issue #104 のネイティブバイナリ破損の、共有によってより広範囲な再現になる）
- 共有ディレクトリの指定が渡されていない場合は、上記の「初回1回だけ実行する」という
  従来どおりの経路になる（後方互換）
