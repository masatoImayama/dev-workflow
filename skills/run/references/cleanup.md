# 後片付け（run スキル参照資料）

`skills/run/SKILL.md` の「サンドボックスの後片付け」「PR作成」の後から参照される。

### 人間向けの手動クリーンアップ

自律実行の外で、残存コンテナの棚卸しをしたい場合は次を使う:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --ls          # 管理コンテナを一覧表示（他リポジトリ分も含む）
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-exec.sh" --down --all   # 現在のリポジトリに属する管理コンテナを全て削除
```


## worktree クリーンアップ

**重要:** `git worktree remove` はworktree内のファイルを削除するが、`node_modules` 等がメインリポへのsymlinkの場合、symlink越しに実体ファイルが削除される。また**カレントディレクトリが対象 worktree 内だと削除できない**ため、必ずメインリポのルートへ戻ってから削除する。

Epic 専用 worktree（`.claude/worktrees/<epicN>`）は **PR 作成後**に削除してよい（epic ブランチは
origin に push 済みのため安全）。フォローアップ修正で使い続けたい場合は残しておいてもよい。

```bash
# 1) メインリポのルートへ戻る（対象 worktree の中からは remove できない）
MAIN_ROOT=$(git -C "$EPIC_WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##')
cd "$MAIN_ROOT" 2>/dev/null || cd "$(git rev-parse --show-toplevel)"

# 2) symlink（node_modules 等）を解除してから Epic 専用 worktree を削除
if [ -d "$EPIC_WT" ]; then
  find "$EPIC_WT" -maxdepth 2 -type l -name "node_modules" -exec unlink {} \; 2>/dev/null || true
  git worktree remove "$EPIC_WT" --force 2>/dev/null || true
fi
```

**generator の isolation worktree（`.claude/worktrees/agent-*`）は、ハーネスが自動整理するわけ
ではない。** 変更を加えた（＝コミットを持つ）worktree は自動整理の対象外と見られ、Epic を
重ねるごとに単調増加する。`git worktree prune` は**登録が壊れたもの**しか掃除しないため、
ディレクトリが実在する worktree は放置され続ける（実測: `docs/dev-workflow-handover.md` H6節）。

本runで実際に使ったレーンの作業ブランチ名（Step 3の完了報告で得た値。Step 5・「統合ゲート失敗時の
原因特定手順」で`merge-lane.sh --lane-branch`に渡した値と同じもの）をすべて集め、`--lane-branch`に
渡して`scripts/cleanup-lane-worktrees.sh`を呼ぶ。Epicブランチへ取り込み済みであることの確認は
スクリプト側が行うため、run側は対象を集めて渡すだけでよい。

Epic本文に「共有ディレクトリ」節があり、共有対象のディレクトリ名（`node_modules`とは限らない。
`vendor`・`.venv`等もありうる）が宣言されている場合は、その名前をすべて`--unlink-dir`として渡す。
節が無い（宣言が無い）場合は`--unlink-dir`を付けず、現行どおり既定の`node_modules`のみで動かす。

```bash
# 3) 本Epicで使ったレーンworktreeのうち、Epicブランチへ取り込み済みのものだけを削除する
#    （削除失敗でrun全体を止めない。取り込み判定はスクリプト側が行う。
#     --lane-branch は本runで使ったレーンの数だけ繰り返す。
#     --unlink-dir はEpic本文の「共有ディレクトリ」節が宣言されている場合のみ、
#     宣言された名前の数だけ繰り返す。節が無ければ付けない（既定node_modulesのまま））
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-lane-worktrees.sh" \
  --epic-branch "${EPIC_BRANCH}" \
  --lane-branch "[レーンAの作業ブランチ]" \
  --lane-branch "[レーンBの作業ブランチ]" \
  --unlink-dir "[共有ディレクトリ節で宣言された名前A]" \
  --unlink-dir "[共有ディレクトリ節で宣言された名前B]" 2>&1 || true

# 4) 上記で保護された（=削除されなかった）worktree はそのまま残る。壊れた登録だけを掃除する
git worktree prune
```

- **本runで使ったレーンブランチだけを渡す。他Epicのレーンworktreeには触れない**
  （`sandbox-exec.sh --down --all`と同じ「自リポジトリ・自Epic分だけ」の原則。`agent-*`を
  名前で総なめしてはならない）
- Epicブランチへ取り込めなかったレーン（レーン内ゲート失敗・ベース逸脱・競合で見送った分を
  含む）のworktreeは、スクリプトが`skip ... reason not-merged`として保護し削除しない。
  取り込めなかった分もそのまま渡してよい
- 人間向けの棚卸し導線として、`git worktree list`で残存状況を確認できる。事前に対象と
  判定理由だけを見たい場合は`--dry-run`を付ける:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-lane-worktrees.sh" \
    --epic-branch "${EPIC_BRANCH}" --lane-branch "<ブランチ>" --dry-run
  ```

サンドボックスの後片付け（常駐コンテナの `--down`）は「自律ループ（YOLOモード、ウェーブ単位）」の
直前の節で**既に実行済み**である（正常終了・異常終了を問わず必ず実行する節）。ここで重複して
実行する必要はない。

