#!/bin/bash
# dev-workflow: 準備成果ディレクトリ（node_modules 等）をレーンへ symlink で共有する（ベンダー中立）
#
# `/dev-workflow:run` の並列レーンでは、generator の isolation worktree がタスクごとに新規作成
# される（作るのはハーネスであり、dev-workflow 側から再利用させる手段は無い）。そのため node 系
# プロジェクトではレーンごとに `yarn install` がフル実行され、Windows + Docker Desktop の
# バインドマウント上では1回20〜40分かかる（issue #104。実測で run 総所要 5.5h の半分以上）。
#
# Epic 専用 worktree には準備コマンドが1回だけ実行されており、その成果（`node_modules` 等）は
# 既に存在する。これをレーンへ symlink で共有すればレーンでの install は不要になる。
# 判定を散文で generator に委ねると取りこぼすため、本スクリプトに固定する。
#
# 本スクリプトは共有モード（既定モード）・`--detach`（#110）・ロック兼完了マーカーと
# `--run-prep`（#111）を実装する。symlink 作成が失敗した場合の実体コピー・フォールバック
# （#139）については後述の「コピー・フォールバックについて」を参照。
#
# --detach は共有モードの逆操作である。依存マニフェスト（package.json / yarn.lock 等）を
# 変更するタスクは、install 前に共有リンクを解除しないと symlink 越しに共有元と他レーンの
# 成果を壊す（issue #104 と同種の壊れ方を、共有によってより広範囲に起こしうる）。
# `--detach` はレーン側 <dir> が symlink のときだけ unlink する。symlink でない実体
# ディレクトリには絶対に触れない（skip reason not-a-link として保護する）。
#
# 使い方（レーンの作業ディレクトリをカレントディレクトリとして呼び出す前提）:
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> \
#       --spec "$(cat <<'SPEC'
#   node_modules  yarn.lock package.json
#   SPEC
#       )"
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> \
#       --dir "node_modules yarn.lock package.json" --dir ".venv requirements.txt"
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> --epic epic105 --dry-run ...
#   bash scripts/share-prepared-dirs.sh --detach --dir node_modules --dir .venv
#   bash scripts/share-prepared-dirs.sh --source <epic-worktree-path> --dir "node_modules yarn.lock" \
#       --run-prep "yarn install --frozen-lockfile"
#
# オプション:
#   --source <path>   共有元（Epic 専用 worktree）のパス。必須（--detach 時は不要）
#   --spec <text>     共有対象の指定。複数行可（1行1エントリ）。複数回指定すると連結される
#   --dir <text>      --spec の1行分を追加する（繰り返し可）
#   --epic <識別子>   sandbox-exec.sh に渡す --epic（例 epic105）。省略可
#   --dry-run         symlink を実際には作らず判定結果だけを出す。ロック（後述）の
#                     取得・`done` の書き込みも行わない（プレビューのため状態を変えない）
#   --detach          共有モードの逆操作（#110）。依存マニフェストを変更するタスクが
#                     install 前に共有リンクを解除するために使う。--source は不要で、
#                     --dir が1つ以上必要。symlink の解除のみを行い、実体ディレクトリ
#                     には絶対に触れない（skip reason not-a-link として保護する）。
#                     --detach にはロック（後述）は適用されない
#   --force           残存ロック（`done` が無いロックディレクトリ）を無視して続行する（#111）
#   --run-prep <cmd>  共有の判定結果が prep=run のときだけ、渡されたコマンドをレーンの
#                     作業ディレクトリで実行する（#111）。詳細は後述
#
# エントリの行書式（空白区切り、すべてリポジトリルート相対。空行と # 始まりの行は無視する）:
#   <共有するディレクトリ> [<フィンガープリントファイル> ...]
#   例: node_modules  yarn.lock package.json
#
# 出力（1行1件・タブ区切り・機械可読。最後に必ず prep= 行を1行出す）:
#   linked	<dir>	<symlinkのターゲット（レーンからの相対パス）>
#   copied	<dir>                                            （#139。後述のコピー・フォールバック）
#   skip	<dir>	reason	<no-source|exists|fingerprint-mismatch|link-failed>
#   prep=<skip|run>
#
# 全エントリが linked・copied・exists のいずれかなら prep=skip、1つでもそれ以外があれば
# prep=run。--dry-run でも linked 行を出すが実際には作らない（copied はコピー・フォールバック
# 自体を --dry-run では実行しないため出ない）
# （scripts/cleanup-lane-worktrees.sh の removed 行が「削除予定」を表す既存慣習に合わせる）。
#
# 出力（--detach。1行1件・タブ区切り。prep= 行は出さない。エントリは <dir> のみ使い、
# --dir の2番目以降のフィールド（フィンガープリントファイル）は無視する）:
#   detached	<dir>
#   skip	<dir>	reason	<not-a-link|absent>
#
# --detach の判定順序:
#   1. レーン側 <dir> が symlink である              -> unlink して detached
#      （--dry-run 指定時は実際には解除せず detached だけを出す）
#   2. symlink ではないが存在する（実体ディレクトリ等） -> skip reason not-a-link（触れない）
#   3. 存在しない                                    -> skip reason absent
#
# エントリごとの判定順序（共有モード）:
#   1. <source>/<dir> が存在しない（ディレクトリでない）      -> no-source
#   2. レーン側 <dir> が既に存在する。ただし「空の」実体ディレクトリは exists に
#      含めない（#180）。symlink、または「非空」の実体・非ディレクトリの場合のみ
#      -> exists
#   3. フィンガープリントファイルの欠損・不一致が1つでもある   -> fingerprint-mismatch
#   4. レーン側 <dir> が「空の」実体ディレクトリとして既に存在する場合   -> link-failed
#      （#180。`ln -s <target> <既存の空ディレクトリ>` は <dir> 自体を symlink に
#      置き換えず、<dir> の中に target のベース名で symlink を作ってしまう
#      （BusyBox/coreutils 双方で確認済み）。<dir> は symlink 化されないまま
#      `ln -s` 自体は rc=0 を返すため、ln -s を試みると壊れた成功になる。よって
#      空の実体ディレクトリに対しては ln -s を一切試みず、直接 link-failed として
#      確定し、下記の「コピー・フォールバックについて」に委ねる。コピー・フォールバックは
#      自身でも「空であること」を確認したうえで安全に埋める）
#   5. symlink を作り、作った symlink を辿った実体がディレクトリであることまで確認する
#      （`ln -s` はターゲットが存在しなくても成功するため、作成成功だけでは
#      dangling symlink を linked と誤報告しうる。#115）。成功なら linked、
#      作成失敗または実体確認に失敗した場合は                -> link-failed
#      （実体確認に失敗した場合は、link-failed を印字する前に自分が作成した symlink を
#      `unlink` で撤去してから link-failed とする。撤去しないと dangling symlink が
#      <dir> を占有したまま残り、(a) 同一実行内で --run-prep を使うとその dangling
#      symlink に <dir> が占有されたまま install が走り失敗する（#116 の解除対象は
#      kind=linked のみ）、(b) 再実行すると判定順序2が dangling symlink でも exists と
#      誤判定し、フォールバックの install が走らないまま done が書かれる、という
#      2つの不具合が生じる。#118）。link-failed になった場合は続けて下記の
#      「コピー・フォールバックについて」を試み、成功すれば結果は copied に置き換わる（#139）
#
# コピー・フォールバックについて（#139。#177/#178/#179/#180 で再設計）:
#
# Windows + Docker Desktop のバインドマウント環境では、コンテナ内からの `ln -s` が
# `Operation not permitted` になり symlink 方式そのものが成立しないと報告されている
# （issue #139）。設計にあたり実際に確認できたことと、確認できなかったことを分けて記す
# （推測で実装しないため。詳細は docs/adr/0007-share-prepared-dirs-copy-fallback.md）。
#
#   - 確認できたこと: 本リポジトリのサンドボックス（dockerfile モード、Windows の
#     バインドマウント上に `docker run -v` でマウント）では、コンテナ内から
#     バインドマウント配下への `ln -s` は成功した。また `cp -a` / `cp -r` による
#     実体コピーも成功することを確認した（コピー先とコピー元の inode 番号が異なることまで
#     確認し、独立したファイルであることを検証済み）。**一方で `cp -a` / `cp -r` は
#     シンボリックリンクを symlink(2) で再作成することも確認した（#178）。**
#     つまり symlink 作成そのものが拒否される環境では、`node_modules/.bin/*` 等の
#     シンボリックリンクを含むソースに対して `cp -a` / `cp -r` も同じ理由で部分的に
#     失敗する。これは机上の懸念ではなく、本フォールバックが対象とする状況（`ln -s` が
#     拒否される環境）そのものに直結する。そのため後述のとおり `-L`（シンボリックリンクを
#     辿って実体をコピーする）を付けて symlink(2) の呼び出し自体を避ける
#   - 確認できたこと（`-L` の挙動）: `cp -aL` / `cp -rL` は BusyBox でも利用可能で、
#     (a) 相対シンボリックリンク（`.bin/foo -> ../pkg/foo`）を実体としてコピーする、
#     (b) ソースツリー外を指す相対シンボリックリンク（yarn workspace 等の
#     `node_modules/pkg -> ../../packages/pkg`）も正しく解決して実体をコピーする、
#     (c) リンク先が存在しないシンボリックリンク（dangling symlink）に対しては
#     `cp` がそのエントリでエラーを返し、他のエントリは成功したまま全体の終了コードが
#     非0になる（部分失敗）ことを確認した。(c) は後述の完全性検証でそのまま
#     copy-failed として扱われるため、dangling symlink があっても壊れた成功にはならない
#   - 確認できなかったこと: issue #139 の元の再現環境（compose モード・実際の
#     Node.js/yarn プロジェクト）そのものは用意できず、`ln -s` が実際に失敗する状態
#     そのものは再現できていない。そのため本フォールバックが issue #139 の実環境で
#     効果があるかどうかは未検証である（#176 で実環境測定時に `.bin` 配下のリンク
#     再作成が成功したかを確認項目に追加した）
#
# 上記の理由により symlink 方式自体は変更せず、引き続き第一選択のままにする（Windows 以外の
# 既存動作を変えない）。symlink 作成が link-failed になったエントリに限り、実体コピー
# （`cp -aL`。失敗時は `cp -rL` にフォールバック）を1回だけ追加で試みる。
#
# `-L` を付けるトレードオフ（#178）: シンボリックリンクがディレクトリを指している場合
# （yarn workspace 等）、`-L` はそのディレクトリの中身を丸ごと重複コピーするため、
# ハードリンク・symlink方式に比べてディスク使用量が増える。**それでもこのトレードオフを
# 受け入れる。** 理由は、本フォールバックが必要になる状況（symlink 作成が拒否される環境）
# では `-L` を付けない `cp -a` / `cp -r` も `.bin` 配下のようなシンボリックリンクで
# 必ず部分的に失敗するため、`-L` を付けない実装は本フォールバックの主要な対象
# （実 Node.js/yarn プロジェクトの `node_modules`。ほぼ必ず `.bin` を含む）に対して
# 事実上機能しない。ディスク使用量の増加は、フォールバック自体が成立しないことに比べて
# 小さい代償と判断した。
#
# ハードリンク（`cp -al` 等）は意図的に使わない。ハードリンクは共有元と同一 inode を指すため、
# 後続の `--run-prep`（yarn install 等）がコピー先へ書き込むと共有元（Epic 専用 worktree）を
# 書き換えてしまう。これは Review #116 で symlink 方式に対して対策済みの問題（インストール
# コマンドが共有元を破壊する）と同種だが、ハードリンクにはその対策（`--run-prep` 前の
# unlink）が効かない（unlink はシンボリックリンクの解除であり、ハードリンクされた実体
# ディレクトリには使えない）。よって実体を完全に独立させるコピーのみを使う。
#
# コピー先の書き込み条件・完全性の確定方法（#177/#180 で再設計。「部分的に失敗したコピーを
# 成功として確定させない」ことが目的）:
#
#   - 対象 <dir> が既に「空でない」実体ディレクトリ、または symlink・その他の非ディレクトリで
#     ある -> 一切触れない（copy-failed のまま。安全ルールに従い削除は行わない）
#   - それ以外（<dir> が存在しない、または「空の」実体ディレクトリとして残っている
#     [Windows で `ln -s` 失敗時の副作用として空ディレクトリが残るという issue #139 の
#     報告への対応]）は、次の**単一の**手順で処理する。「存在しない」場合と「空」場合を
#     別コードパスにしない（#177 の根本原因は、この2ケースをコードパスとして分けたうえで
#     「存在しない」側の再試行がネスト・コピーを作ったことだった。単一の手順に統一することで
#     この分岐自体を無くす）:
#       1. `<dir>` とは別の、コミット対象になりえない一時ディレクトリ（後述）を新規に
#          `mkdir` する（既に同名の一時ディレクトリが残っていれば `mkdir` は失敗し、
#          そのエントリは copy-failed として確定させる。**古い残骸を再利用しての
#          継ぎ足しコピーは行わない**。これにより #177 のネスト・コピーが構造的に
#          発生しなくなる: 一時ディレクトリは常に新規かつ空から始まり、コピーは
#          「ソースの中身を一時ディレクトリの直下へ」（`cp -aL "<src>/." "<tmp>/"`）という
#          内容形のみを使うため、一時ディレクトリの深さが不意に1段増える余地が無い）
#       2. `cp -aL "<src>/." "<tmp>/" || cp -rL "<src>/." "<tmp>/"` で内容をコピーする
#       3. **確定前に完全性を検証する。** `ls -A` によるソースと一時ディレクトリ直下の
#          エントリ数が一致する場合に限り「完全」とみなす（#177 が指摘したとおり、rc だけの
#          判定は部分失敗を成功として通してしまう経路を作りうる。直下エントリ数の比較を
#          使う理由は、`-L` によるディレクトリ・シンボリックリンクの実体展開があっても
#          直下の1エントリという対応関係は崩れないため、`-L` と両立できる）
#       4. 完全性検証を満たした場合のみ `mv -T "<tmp>" "<dir>"` で確定させる。`mv -T` は
#          rename(2) 相当であり、`<dir>` が存在しない場合はそのまま作成、`<dir>` が
#          「空の」実体ディレクトリとして残っている場合はその場所に上書きで置き換える
#          （サンドボックスで両方の挙動を確認済み）ことをどちらも1回の呼び出しで扱える。
#          検証を満たさない場合は copy-failed として確定させず `mv` もしない
#          （`<dir>` 自体には何も書き込まれないため、次回実行時に `<dir>` が誤って
#          exists 判定されることはない。#180）
#
# 一時ディレクトリの置き場所について（#179）: 従来は `<dir>.dwtmp$$` としてレーンの
# 作業ツリー直下に置いていたが、コピーが失敗して残った場合、generator は安全ルールにより
# `rm`/`rmdir` を使えず自力で除去できない。しかも駆動先の `.gitignore` は通常
# `node_modules/` のような名前しか無視しないため `node_modules.dwtmp12345` には一致せず、
# 未追跡ファイルとして `git status` に現れ `git add -A` 系の操作でコミットに巻き込まれうる。
#
# この問題を避けるため、レーンが git worktree である場合（実運用では常にそう。ロック兼
# 完了マーカーが git-dir を解決できた場合と同じ条件）は、一時ディレクトリをレーンの
# 作業ツリーの外――`git rev-parse --git-dir` が指すディレクトリ（worktree ごとに独立しており、
# git の追跡対象外で `git status` にも一切現れない）配下の `dev-workflow-copy-tmp/` ――に
# 作る。失敗して残った場合もレーンの作業ツリーから見えないため、generator が除去できなくても
# 実害が無い（**削除自体はしない。安全ルールと矛盾しないための意図的な選択であり、
# 失敗が繰り返されるとこの領域にゴミが蓄積することは許容する**）。
#
# git-dir を解決できない場合（レーンの作業ディレクトリが git リポジトリでない。実運用では
# 起こらないが、素の一時ディレクトリでの検証等）は、従来どおりレーンの作業ツリー直下の
# `<dir>.dwtmp$$` にフォールバックする。この場合に限り、コピーが失敗して残った一時
# ディレクトリのパスを stderr に明示する（「人間が消す必要がある」ことを伝えるため。
# 出力形式は `WARNING: ... 残骸 <path>` の1行）。
#
# symlink が確認できる環境（Linux/macOS 等。`ln -s` が通常成功する）では link-failed が
# そもそも発生しないため、この経路は実行されない（既存動作を変えない）。
#
# フィンガープリントの比較は素のファイル読み取りだけで済むためホスト側で行う
# （フィンガープリント未指定のエントリは検査しない）。
#
# symlink の作成と存在判定はコンテナ内で行う（重要）。ホストが Windows（Git Bash）の場合、
# `ln -s` が実体コピーになる・`test -L` が誤判定する等でホスト側からは扱えないためである。
# コンテナへの投入は scripts/sandbox-exec.sh 経由で行い、環境変数 DEV_WORKFLOW_SANDBOX_EXEC
# （既定: 本スクリプトと同じディレクトリの sandbox-exec.sh）で差し替えられるようにする。
# 単体テストはこの差し替えでスタブを刺し、Docker に依存せず検証する
# （tests/run-tests.sh は Docker を一切呼ばない方針）。
# コンテナへの投入は1回にまとめる（エントリごとに docker exec を往復させない）。
#
# symlink のターゲットは、レーン worktree から共有元への相対パスで張る。絶対パスにすると
# ホストとコンテナでパスが異なり解決できない。symlink のターゲットはリンク自身の親ディレクトリ
# 基準で解決されるため、<dir> がネストしている場合（例: packages/app/node_modules。行書式は
# リポジトリルート相対であり、モノレポでは主要な用途）は、レーン worktree 基準の相対パスに
# <dir> の "/" の個数ぶん "../" を追加で前置してリンク位置基準に補正する（#115）。
# 相対パスが計算できない場合（共有元がリポジトリ
# ルート外。実装上はカレントディレクトリと共有元が同じドライブ/ルートを共有しない場合）は
# link-failed として扱う。
#
# ロック兼完了マーカー（#111。共有モードのみ。--detach には適用されない）:
#
# issue #104 では、generator が同一 worktree に2本目の準備コマンド（`yarn install` 等）を
# 並行実行し、ネイティブバイナリを破損させた。「同一 worktree で準備は初回1回だけ」という
# 規約（Task #94）は散文でしかなく強制力が無いため、本スクリプトの構造で固定する。
#
# 対象はレーンの作業ディレクトリ単位。`git rev-parse --git-dir` が返すディレクトリ配下の
# `dev-workflow-prep.lock`（ディレクトリ）を `mkdir` で作って取得する（`mkdir` はアトミック）。
# 作業ツリー内にロックを置かないのは、`git status` を汚し可読性ガードやコミット対象に
# 混ざるのを避けるためである（`.git` 配下は git の追跡対象外）。
#   - `mkdir` に成功                        -> 自分が初回。処理を行い、成功したときだけ
#                                              ロックディレクトリ内に `done` ファイルを書く
#                                              （`--run-prep` のコマンドが失敗した場合は
#                                              「処理が完了していない」ので書かない）
#   - `mkdir` に失敗し、中に `done` がある   -> 準備済み。prep=done-already を出して exit 0。
#                                              symlink 作成も準備コマンド実行も行わない
#   - `mkdir` に失敗し、`done` が無い        -> 実行中（または異常終了で残った残骸）。
#                                              待たずに exit 3 で停止し、ロックパスを
#                                              stderr に出す。`--force` 指定時のみ、この
#                                              「`done` の無い残存ロック」を無視して続行する
#                                              （異常終了後の復旧手段）
#
# **ロックディレクトリは削除しない。** 安全ルール（`rm` / `rmdir` を使わない）と整合させる
# ためであり、同時に「同一 worktree で準備は1回だけ」を決定論的に固定する効果を持つ。
# 異常終了で `done` の無いロックが残り以降 exit 3 になり続けるのは意図した挙動である
# （黙って2本目を走らせて事故るより、明示的に停止して人間に判断させる。復旧には `--force`
# を使う）。
#
# `git rev-parse --git-dir` が失敗する場合（レーンの作業ディレクトリが git リポジトリでない。
# 実運用では起こらないが、素の一時ディレクトリでの検証等）はロックを適用せず、既存の
# 共有モード（#106）どおりに動作する。
#
# `--run-prep <cmd>`:
#   - prep=run のときだけ、渡されたコマンドをレーンの作業ディレクトリで実行する。
#     prep=skip / prep=done-already のときは実行しない
#   - 実行は `DEV_WORKFLOW_SANDBOX_EXEC`（既定: 本スクリプトと同じディレクトリの
#     sandbox-exec.sh）経由で行う。**`--warm` は使わない**（終了コードが必要なため）
#   - コマンドが失敗したら exit 4 で停止し、`done` マーカーを作らない
#     （準備が完了していないため。次回呼び出しは実行中ロックとして exit 3 になり、
#     `--force` での再試行が明示的に必要になる）
#   - `--run-prep` を渡さなかった場合は何も実行しない（prep=run を出して exit 0）
#   - `--dry-run` 指定時は実行しない
#   - **エントリが複数あり一部だけ linked・残りが no-source 等で prep=run になった場合、
#     コマンドを実行する直前にその linked 済みエントリの共有symlinkを全て解除してから
#     実行する（Review #116）。** linked 済みの symlink を張ったまま準備コマンド
#     （`yarn install` 等）を実行すると、install はレーンの `<dir>`（= 共有元 Epic 専用
#     worktree への symlink）へ書き込むため、共有元と他レーンが参照している実体を
#     書き換えてしまう（issue #104 の『同一 node_modules への並行 install によるネイティブ
#     バイナリ破損』を、レーンをまたいでより広範囲に再現しうる）。エントリが1件のみ
#     （全件 linked または全件 non-linked）の場合はこの解除は発生しない。
#     解除はコマンド実行と同じコンテナ呼び出し内で `unlink <dir> || exit 1` を改行区切りで
#     1行ずつ前置し、最後に改行で本体コマンドを連結する（コンテナ呼び出しを増やさないため）。
#     `RUN_PREP` は複数行が実運用での通常形であり、`&&` による同一行連結では守れるのが
#     1行目だけになる（Review #117）ため、改行区切りに変更した。解除に失敗した場合は
#     その時点で停止し本体コマンドは1行も実行されず、以降の失敗時と同じ扱い
#     （exit 4、`done` を作らない）にする。
#     全件 linked でなければ全件 prep=run に倒す（all-or-nothing）方式は採らなかった。
#     `--run-prep` を渡さない呼び出し（#106 の複数エントリ混在ケース等）では、混在バッチ
#     でも個々の共有可否をそのまま `linked`/`skip` 行で報告する既存の挙動を変えないため。
#
# 終了コード:
#   0 = 正常終了（共有モードは prep= 行で成否を判断する。--detach に prep= 行は無い）
#   2 = 引数エラー（--source 欠落（共有モード）、--dir 皆無（--detach）、
#       値なしのオプション、未知のオプション等）
#   3 = ロック競合（同一 worktree で既に準備が実行中。#111）
#   4 = --run-prep に渡したコマンドが失敗した（#111）
#
# 安全ルール:
#   - 削除コマンド（rm / rmdir）を使わない
#   - 追加の依存物（jq 等）を要求しない。素の bash / git / grep / sed のみで完結させる

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_EXEC="${DEV_WORKFLOW_SANDBOX_EXEC:-${SCRIPT_DIR}/sandbox-exec.sh}"

SOURCE=""
EPIC=""
DRY_RUN=0
DETACH=0
FORCE=0
RUN_PREP=""
RAW_LINES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      if [ $# -lt 2 ]; then
        echo "ERROR: --source には値が必要です" >&2
        exit 2
      fi
      SOURCE="$2"; shift 2 ;;
    --spec)
      if [ $# -lt 2 ]; then
        echo "ERROR: --spec には値が必要です" >&2
        exit 2
      fi
      while IFS= read -r _spec_line; do
        RAW_LINES+=("$_spec_line")
      done <<< "$2"
      shift 2 ;;
    --dir)
      if [ $# -lt 2 ]; then
        echo "ERROR: --dir には値が必要です" >&2
        exit 2
      fi
      RAW_LINES+=("$2"); shift 2 ;;
    --epic)
      if [ $# -lt 2 ]; then
        echo "ERROR: --epic には値が必要です" >&2
        exit 2
      fi
      EPIC="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --detach) DETACH=1; shift ;;
    --force) FORCE=1; shift ;;
    --run-prep)
      if [ $# -lt 2 ]; then
        echo "ERROR: --run-prep には値が必要です" >&2
        exit 2
      fi
      RUN_PREP="$2"; shift 2 ;;
    -*) echo "ERROR: 未知のオプション: $1" >&2; exit 2 ;;
    *)  echo "ERROR: 未知の引数: $1" >&2; exit 2 ;;
  esac
done

if [ "$DETACH" -eq 0 ] && [ -z "$SOURCE" ]; then
  echo "ERROR: --source は必須です" >&2
  exit 2
fi

CWD="$(pwd)"

# ---------------------------------------------------------------------------
# エントリの解析（--spec / --dir から集めた RAW_LINES を分解する）。
# 空行・# 始まりの行は無視する。read -ra は先頭・末尾の空白を自然に落とすため、
# 個別に trim する必要が無い。
# ---------------------------------------------------------------------------

ENTRY_DIRS=()
ENTRY_FILES=()

for _raw in "${RAW_LINES[@]:-}"; do
  [ -z "${_raw+x}" ] && continue
  _raw="${_raw%$'\r'}"
  read -ra _fields <<< "$_raw"
  [ "${#_fields[@]}" -eq 0 ] && continue
  case "${_fields[0]}" in
    "#"*) continue ;;
  esac
  ENTRY_DIRS+=("${_fields[0]}")
  ENTRY_FILES+=("${_fields[*]:1}")
done

if [ "$DETACH" -eq 1 ] && [ "${#ENTRY_DIRS[@]}" -eq 0 ]; then
  echo "ERROR: --detach には --dir が1つ以上必要です" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# 共有元からレーン（カレントディレクトリ）への相対パスを計算する（純粋な文字列処理。
# cd で正規化するため、両ディレクトリが実在すれば十分で、対象の <dir> 自体の存在は問わない）。
# ---------------------------------------------------------------------------

compute_rel_path() {
  # compute_rel_path <from_dir> <to_dir>  <from_dir> から <to_dir> への相対パスを出力する
  local from="$1" to="$2"
  local from_abs to_abs
  from_abs="$(cd "$from" 2>/dev/null && pwd)" || return 1
  to_abs="$(cd "$to" 2>/dev/null && pwd)" || return 1
  [ -n "$from_abs" ] && [ -n "$to_abs" ] || return 1

  local IFS=/
  local -a fparts=() tparts=()
  local p
  # shellcheck disable=SC2086  # IFS=/ による意図的な単語分割
  for p in $from_abs; do [ -n "$p" ] && fparts+=("$p"); done
  for p in $to_abs; do [ -n "$p" ] && tparts+=("$p"); done

  # 先頭要素（ドライブレター等のルート）が異なる場合は同一ファイルシステム上に無いとみなす
  if [ "${#fparts[@]}" -gt 0 ] && [ "${#tparts[@]}" -gt 0 ] \
    && [ "${fparts[0]}" != "${tparts[0]}" ]; then
    return 1
  fi

  local i=0
  while [ "$i" -lt "${#fparts[@]}" ] && [ "$i" -lt "${#tparts[@]}" ] \
    && [ "${fparts[$i]}" = "${tparts[$i]}" ]; do
    i=$((i + 1))
  done

  local up=$(( ${#fparts[@]} - i ))
  local rel="" j
  for ((j = 0; j < up; j++)); do rel="${rel}../"; done
  for ((j = i; j < ${#tparts[@]}; j++)); do rel="${rel}${tparts[$j]}/"; done
  rel="${rel%/}"
  [ -z "$rel" ] && rel="."
  printf '%s' "$rel"
}

if [ "$DETACH" -eq 0 ]; then

# ---------------------------------------------------------------------------
# ロック兼完了マーカー（#111）。--dry-run はプレビューのため状態を変えない
# （ロックの取得も done の書き込みも行わず、既存の共有モードどおりに動作する）。
# `git rev-parse --git-dir` が失敗する場合（レーンの作業ディレクトリが git リポジトリで
# ない）もロックを適用せず、既存の共有モードどおりに動作する。
# ---------------------------------------------------------------------------

LOCK_ELIGIBLE=0
LOCK_STATE="no-lock"
LOCK_DIR=""

if [ "$DRY_RUN" -eq 0 ]; then
  GIT_DIR_RAW="$(git rev-parse --git-dir 2>/dev/null)"
  if [ -n "$GIT_DIR_RAW" ]; then
    GIT_DIR_ABS="$(cd "$GIT_DIR_RAW" 2>/dev/null && pwd)"
    if [ -n "$GIT_DIR_ABS" ]; then
      LOCK_ELIGIBLE=1
      LOCK_DIR="${GIT_DIR_ABS}/dev-workflow-prep.lock"
    fi
  fi
fi

if [ "$LOCK_ELIGIBLE" -eq 1 ]; then
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_STATE="fresh"
  elif [ -f "${LOCK_DIR}/done" ]; then
    LOCK_STATE="done-already"
  elif [ "$FORCE" -eq 1 ]; then
    LOCK_STATE="forced"
  else
    LOCK_STATE="conflict"
  fi
fi

case "$LOCK_STATE" in
  done-already)
    printf 'prep=done-already\n'
    exit 0 ;;
  conflict)
    echo "ERROR: 同一 worktree で準備が既に実行中です（${LOCK_DIR}）" >&2
    exit 3 ;;
esac

REL_SOURCE=""
REL_SOURCE_OK=0
if [ -d "$SOURCE" ]; then
  if REL_SOURCE="$(compute_rel_path "$CWD" "$SOURCE")"; then
    REL_SOURCE_OK=1
  fi
fi

# ---------------------------------------------------------------------------
# エントリごとの判定（1: no-source, 3: fingerprint はここでホスト側で決める。
# 2: exists, 4: link/link-failed はコンテナ側で決める）。
# ---------------------------------------------------------------------------

RESULT_KIND=()    # linked|exists|no-source|fingerprint-mismatch|link-failed（ENTRY_DIRSと同じ添字）
RESULT_TARGET=()  # linked のときだけ意味を持つ

CANDIDATE_ORIG_IDX=()
CANDIDATE_DIR=()
CANDIDATE_TARGET=()
CANDIDATE_FPOK=()

for idx in "${!ENTRY_DIRS[@]}"; do
  dir="${ENTRY_DIRS[$idx]}"
  files="${ENTRY_FILES[$idx]}"

  if [ ! -d "${SOURCE}/${dir}" ]; then
    RESULT_KIND[idx]="no-source"
    RESULT_TARGET[idx]=""
    continue
  fi

  # フィンガープリント比較（ホスト側。素のファイル読み取りだけで済む）。
  fp_ok=1
  if [ -n "$files" ]; then
    # shellcheck disable=SC2086  # files は空白区切りの複数ファイル名。意図的な単語分割
    for f in $files; do
      if [ ! -f "${SOURCE}/${f}" ] || [ ! -f "$f" ]; then
        fp_ok=0; break
      fi
      if ! cmp -s "${SOURCE}/${f}" "$f"; then
        fp_ok=0; break
      fi
    done
  fi

  if [ "$REL_SOURCE_OK" -eq 1 ]; then
    # symlink のターゲットは、リンク自身（$CWD/$dir）の親ディレクトリ基準で解決される。
    # REL_SOURCE は $CWD 基準の相対パスのため、<dir> がネストしている場合
    # （例: packages/app/node_modules）はリンクの親ディレクトリが $CWD より深い分だけ
    # 余分に "../" を前置しないと誤ったターゲットになる（#115）。前置する数は <dir> に
    # 含まれる "/" の個数（= リンクの親ディレクトリが $CWD から何段深いか）と一致する。
    _dir_slashes="${dir//[^\/]/}"
    _up_prefix=""
    for ((_up_i = 0; _up_i < ${#_dir_slashes}; _up_i++)); do
      _up_prefix+="../"
    done
    target="${_up_prefix}${REL_SOURCE}/${dir}"
  else
    target=""
  fi

  CANDIDATE_ORIG_IDX+=("$idx")
  CANDIDATE_DIR+=("$dir")
  CANDIDATE_TARGET+=("$target")
  CANDIDATE_FPOK+=("$fp_ok")
done

# ---------------------------------------------------------------------------
# コンテナへの投入（1回にまとめる）。exists 判定と symlink 作成（または --dry-run 時は
# 判定のみ）を、候補エントリ全件分のミニスクリプトとして1回の sandbox-exec.sh 呼び出しに
# まとめる。
# ---------------------------------------------------------------------------

if [ "${#CANDIDATE_DIR[@]}" -gt 0 ]; then
  CONTAINER_SCRIPT="set -u"$'\n'
  # shellcheck disable=SC2016  # 単一引用符は意図的。$d/$t はここでは展開せず、
  # コンテナ側で実行されるミニスクリプトの文字列としてそのまま埋め込む。
  for i in "${!CANDIDATE_DIR[@]}"; do
    d="${CANDIDATE_DIR[$i]}"
    t="${CANDIDATE_TARGET[$i]}"
    fpok="${CANDIDATE_FPOK[$i]}"
    CONTAINER_SCRIPT+="d=$(printf '%q' "$d")"$'\n'
    CONTAINER_SCRIPT+="t=$(printf '%q' "$t")"$'\n'
    # 判定順序2（#180 で修正）: <dir> が symlink、または「非空」の実体・非ディレクトリで
    # あれば exists（触れない）。<dir> が「空の」実体ディレクトリの場合はここでは exists と
    # しない。`ln -s <target> <既存の空ディレクトリ>` は BusyBox/coreutils いずれでも
    # ディレクトリ自体を置き換えず「ディレクトリの中に」target のベース名で symlink を
    # 作ってしまう（サンドボックスで確認済み。<dir> 自体は symlink 化されないまま
    # rc=0 になり、壊れた成功を生む）。そのため空の実体ディレクトリは ln -s を一切
    # 試みず、fpmismatch 判定の後で直接 link-failed として確定し、後続のコピー・
    # フォールバック（#177/#179 で再設計済み。空であることを自身でも確認したうえで
    # 安全に埋める）に委ねる。
    CONTAINER_SCRIPT+='if [ -L "$d" ] || { [ -e "$d" ] && { [ ! -d "$d" ] || [ -n "$(ls -A "$d" 2>/dev/null)" ]; }; }; then'$'\n'
    CONTAINER_SCRIPT+='  printf "exists\t%s\n" "$d"'$'\n'
    CONTAINER_SCRIPT+="elif [ ${fpok} -ne 1 ]; then"$'\n'
    CONTAINER_SCRIPT+='  printf "fpmismatch\t%s\n" "$d"'$'\n'
    CONTAINER_SCRIPT+='elif [ -d "$d" ]; then'$'\n'
    CONTAINER_SCRIPT+='  printf "linkfailed\t%s\n" "$d"'$'\n'
    CONTAINER_SCRIPT+='elif [ -z "$t" ]; then'$'\n'
    CONTAINER_SCRIPT+='  printf "linkfailed\t%s\n" "$d"'$'\n'
    CONTAINER_SCRIPT+='else'$'\n'
    if [ "$DRY_RUN" -eq 1 ]; then
      CONTAINER_SCRIPT+='  printf "linked\t%s\t%s\n" "$d" "$t"'$'\n'
    else
      CONTAINER_SCRIPT+='  if ln -s "$t" "$d" 2>/dev/null && [ -d "$d" ]; then'$'\n'
      CONTAINER_SCRIPT+='    printf "linked\t%s\t%s\n" "$d" "$t"'$'\n'
      CONTAINER_SCRIPT+='  else'$'\n'
      # 実体確認に失敗した場合、作成してしまった symlink（dangling）を残さない（#118）。
      # ln -s 自体が失敗していた場合は $d は存在しないため unlink は無害に失敗するだけ。
      CONTAINER_SCRIPT+='    unlink "$d" 2>/dev/null'$'\n'
      CONTAINER_SCRIPT+='    printf "linkfailed\t%s\n" "$d"'$'\n'
      CONTAINER_SCRIPT+='  fi'$'\n'
    fi
    CONTAINER_SCRIPT+='fi'$'\n'
  done

  SANDBOX_ARGS=()
  [ -n "$EPIC" ] && SANDBOX_ARGS+=(--epic "$EPIC")

  CONTAINER_OUTPUT="$(bash "$SANDBOX_EXEC" "${SANDBOX_ARGS[@]}" "$CONTAINER_SCRIPT")"

  cand_i=0
  # 2カラム目（dir名）はCANDIDATE_ORIG_IDX側で既知のため使わない。read の3カラム形式
  # （kind\tdir\ttarget）に合わせるためだけに受け取る。
  # shellcheck disable=SC2034
  while IFS=$'\t' read -r kind _dir b; do
    [ -z "$kind" ] && continue
    [ "$cand_i" -lt "${#CANDIDATE_ORIG_IDX[@]}" ] || break
    orig_idx="${CANDIDATE_ORIG_IDX[$cand_i]}"
    case "$kind" in
      exists)     RESULT_KIND[orig_idx]="exists" ;;
      fpmismatch) RESULT_KIND[orig_idx]="fingerprint-mismatch" ;;
      linkfailed) RESULT_KIND[orig_idx]="link-failed" ;;
      linked)     RESULT_KIND[orig_idx]="linked"; RESULT_TARGET[orig_idx]="$b" ;;
      *)          RESULT_KIND[orig_idx]="link-failed" ;;
    esac
    cand_i=$((cand_i + 1))
  done <<< "$CONTAINER_OUTPUT"

  # コンテナ呼び出しが失敗して出力が想定件数に満たない場合、未確定分は安全側
  # （link-failed）で確定させる。
  while [ "$cand_i" -lt "${#CANDIDATE_ORIG_IDX[@]}" ]; do
    orig_idx="${CANDIDATE_ORIG_IDX[$cand_i]}"
    RESULT_KIND[orig_idx]="link-failed"
    cand_i=$((cand_i + 1))
  done
fi

# ---------------------------------------------------------------------------
# コピー・フォールバック（#139。#177/#178/#179/#180 で再設計。詳細は冒頭コメント
# 「コピー・フォールバックについて」を参照）。
#
# 「存在しない」と「空の実体ディレクトリとして残っている」の2ケースを単一の手順
# （一時ディレクトリへ内容形コピー → 直下エントリ数で完全性検証 → mv -T で確定）に
# 統一する。一時ディレクトリはレーンが git worktree である場合、git-dir 配下
# （git の追跡対象外）に置き、レーンの作業ツリーには一切現れないようにする（#179）。
# git-dir を解決できない場合のみレーンの作業ツリー直下 <dir>.dwtmp$$ にフォールバックし、
# その場合に限り残骸のパスを stderr に明示する。
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 0 ]; then
  COPY_CANDIDATE_ORIG_IDX=()
  COPY_CANDIDATE_DIR=()
  COPY_CANDIDATE_SRC=()

  for idx in "${!ENTRY_DIRS[@]}"; do
    if [ "${RESULT_KIND[$idx]:-}" = "link-failed" ]; then
      COPY_CANDIDATE_ORIG_IDX+=("$idx")
      COPY_CANDIDATE_DIR+=("${ENTRY_DIRS[$idx]}")
      COPY_CANDIDATE_SRC+=("${SOURCE}/${ENTRY_DIRS[$idx]}")
    fi
  done

  if [ "${#COPY_CANDIDATE_DIR[@]}" -gt 0 ]; then
    # 一時ディレクトリの置き場所（#179）。LOCK_ELIGIBLE は既にロック兼完了マーカーの
    # 節（共有モードのみ・DRY_RUN=0）で `git rev-parse --git-dir` の成否から決まっている
    # ため、ここではそれをそのまま再利用する（同じ条件で「レーンが git worktree か」を
    # 二重に判定しない）。
    COPY_TMP_BASE=""
    if [ "$LOCK_ELIGIBLE" -eq 1 ]; then
      COPY_TMP_BASE="$(compute_rel_path "$CWD" "$GIT_DIR_ABS")" || COPY_TMP_BASE=""
    fi

    COPY_SCRIPT="set -u"$'\n'
    # shellcheck disable=SC2016  # 単一引用符は意図的。$tmp_base はここでは展開せず、
    # コンテナ側で実行されるミニスクリプトの文字列としてそのまま埋め込む。
    if [ -n "$COPY_TMP_BASE" ]; then
      COPY_SCRIPT+="tmp_base=$(printf '%q' "${COPY_TMP_BASE}/dev-workflow-copy-tmp")"$'\n'
      COPY_SCRIPT+='mkdir -p "$tmp_base" 2>/dev/null'$'\n'
    else
      COPY_SCRIPT+='tmp_base=""'$'\n'
    fi
    # shellcheck disable=SC2016  # 単一引用符は意図的。$d/$s/$tmp 等はコンテナ側で
    # 実行されるミニスクリプトの文字列としてそのまま埋め込む。
    for i in "${!COPY_CANDIDATE_DIR[@]}"; do
      d="${COPY_CANDIDATE_DIR[$i]}"
      s="${COPY_CANDIDATE_SRC[$i]}"
      COPY_SCRIPT+="d=$(printf '%q' "$d")"$'\n'
      COPY_SCRIPT+="s=$(printf '%q' "$s")"$'\n'
      COPY_SCRIPT+="entry_idx=$(printf '%q' "$i")"$'\n'
      COPY_SCRIPT+='if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then'$'\n'
      COPY_SCRIPT+='  printf "copyfailed\t%s\n" "$d"'$'\n'
      COPY_SCRIPT+='elif [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then'$'\n'
      COPY_SCRIPT+='  printf "copyfailed\t%s\n" "$d"'$'\n'
      COPY_SCRIPT+='else'$'\n'
      COPY_SCRIPT+='  if [ -n "$tmp_base" ]; then tmp="${tmp_base}/dwcopy.$$.${entry_idx}"; else tmp="${d}.dwtmp$$"; fi'$'\n'
      COPY_SCRIPT+='  src_count=$(ls -A "$s" 2>/dev/null | wc -l)'$'\n'
      COPY_SCRIPT+='  if mkdir "$tmp" 2>/dev/null; then'$'\n'
      COPY_SCRIPT+='    if cp -aL "$s/." "$tmp/" 2>/dev/null || cp -rL "$s/." "$tmp/" 2>/dev/null; then'$'\n'
      COPY_SCRIPT+='      tmp_count=$(ls -A "$tmp" 2>/dev/null | wc -l)'$'\n'
      COPY_SCRIPT+='      if [ "$tmp_count" = "$src_count" ] && mv -T "$tmp" "$d" 2>/dev/null && [ -d "$d" ]; then'$'\n'
      COPY_SCRIPT+='        printf "copied\t%s\n" "$d"'$'\n'
      COPY_SCRIPT+='      else'$'\n'
      COPY_SCRIPT+='        printf "copyfailed\t%s\t%s\n" "$d" "$tmp"'$'\n'
      COPY_SCRIPT+='      fi'$'\n'
      COPY_SCRIPT+='    else'$'\n'
      COPY_SCRIPT+='      printf "copyfailed\t%s\t%s\n" "$d" "$tmp"'$'\n'
      COPY_SCRIPT+='    fi'$'\n'
      COPY_SCRIPT+='  else'$'\n'
      COPY_SCRIPT+='    printf "copyfailed\t%s\n" "$d"'$'\n'
      COPY_SCRIPT+='  fi'$'\n'
      COPY_SCRIPT+='fi'$'\n'
    done

    COPY_SANDBOX_ARGS=()
    [ -n "$EPIC" ] && COPY_SANDBOX_ARGS+=(--epic "$EPIC")
    COPY_OUTPUT="$(bash "$SANDBOX_EXEC" "${COPY_SANDBOX_ARGS[@]}" "$COPY_SCRIPT")"

    copy_i=0
    COPY_RESIDUE_PATHS=()
    while IFS=$'\t' read -r ckind cdir cresidue; do
      [ -z "$ckind" ] && continue
      [ "$copy_i" -lt "${#COPY_CANDIDATE_ORIG_IDX[@]}" ] || break
      corig_idx="${COPY_CANDIDATE_ORIG_IDX[$copy_i]}"
      if [ "$ckind" = "copied" ]; then
        RESULT_KIND[corig_idx]="copied"
      elif [ -n "$cresidue" ] && [ -z "$COPY_TMP_BASE" ]; then
        # git-dir 配下に置けなかった場合（#179）に限り、レーンの作業ツリーに
        # 残った一時ディレクトリのパスを人間が消せるよう明示する。
        COPY_RESIDUE_PATHS+=("${cdir}: ${cresidue}")
      fi
      copy_i=$((copy_i + 1))
    done <<< "$COPY_OUTPUT"

    if [ "${#COPY_RESIDUE_PATHS[@]}" -gt 0 ]; then
      echo "WARNING: コピー・フォールバックが失敗し、レーンの作業ツリーに一時ディレクトリの残骸が残りました（generator は安全ルールにより自力で除去できません。人間が確認して削除してください。#179）:" >&2
      for _residue in "${COPY_RESIDUE_PATHS[@]}"; do
        echo "  - ${_residue}" >&2
      done
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 出力（linked / copied / skip の3種）
# ---------------------------------------------------------------------------

PREP="skip"
for idx in "${!ENTRY_DIRS[@]}"; do
  kind="${RESULT_KIND[$idx]:-link-failed}"
  case "$kind" in
    linked)
      printf 'linked\t%s\t%s\n' "${ENTRY_DIRS[$idx]}" "${RESULT_TARGET[$idx]:-}" ;;
    copied)
      printf 'copied\t%s\n' "${ENTRY_DIRS[$idx]}" ;;
    *)
      printf 'skip\t%s\treason\t%s\n' "${ENTRY_DIRS[$idx]}" "$kind"
      [ "$kind" = "exists" ] || PREP="run" ;;
  esac
done

# ---------------------------------------------------------------------------
# --run-prep（#111）。prep=run のときだけ実行する。--dry-run 指定時は実行しない。
#
# エントリが複数あり一部だけ linked（残りが no-source 等）で prep=run になった場合、
# linked 済みの共有symlinkを張ったままコマンドを実行すると共有元へ書き込んでしまう
# （Review #116。詳細は冒頭コメント参照）。そのため、linked 済みエントリを解除する
# `unlink` を実行対象コマンドの前に連結し、同じコンテナ呼び出し1回にまとめて実行する。
# `RUN_PREP`（Epic本文『## 準備コマンド』節）は複数行が実運用での通常形であり、
# `&&` による同一行連結では守れるのが1行目だけになる（Review #117）。そのため
# 各 unlink は `unlink <dir> || exit 1` として改行区切りの1行ずつ前置し、最後に
# 改行で `${RUN_PREP}` を連結する（sh -c 実行のため改行はコマンド区切りとして働く）。
# これにより解除失敗時は `exit 1` でその場に停止し、RUN_PREP は1行も実行されず、
# 呼び出し全体が非0終了して以降の失敗時処理（exit 4、doneを作らない）に合流する。
# ---------------------------------------------------------------------------

RUN_PREP_RAN=0
RUN_PREP_EXIT=0
if [ -n "$RUN_PREP" ] && [ "$PREP" = "run" ] && [ "$DRY_RUN" -eq 0 ]; then
  RUN_PREP_RAN=1

  RUN_PREP_UNLINK_PREFIX=""
  for idx in "${!ENTRY_DIRS[@]}"; do
    if [ "${RESULT_KIND[$idx]:-}" = "linked" ]; then
      RUN_PREP_UNLINK_PREFIX+="unlink $(printf '%q' "${ENTRY_DIRS[$idx]}") || exit 1"$'\n'
    fi
  done
  RUN_PREP_CMD="${RUN_PREP_UNLINK_PREFIX}${RUN_PREP}"

  RUN_PREP_SANDBOX_ARGS=()
  [ -n "$EPIC" ] && RUN_PREP_SANDBOX_ARGS+=(--epic "$EPIC")
  bash "$SANDBOX_EXEC" "${RUN_PREP_SANDBOX_ARGS[@]}" "$RUN_PREP_CMD"
  RUN_PREP_EXIT=$?
fi

printf 'prep=%s\n' "$PREP"

# prep=run のまま何のコマンドも実行されずに exit 0 で終わると、呼び出し側が
# prep= 行を見落とした場合に「レーンへ node_modules 等が一切用意されないまま
# 実装へ進む」という無言の状態になる（issue #139 の実害）。symlink・copy いずれの
# フォールバックも尽きて prep=run のまま残り、かつ --run-prep も渡されていない
# （＝何も実行されない）場合は、それを stderr に明示する。exit コードは変えない
# （既存の呼び出し側との互換性を保つ。判断は prep= 行を見て呼び出し側が行う）。
if [ "$PREP" = "run" ] && [ -z "$RUN_PREP" ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "WARNING: prep=run のまま --run-prep が指定されていないため、共有できなかったエントリの準備コマンドは実行されていません。レーンは準備成果が無い状態のまま進みます（#139）。" >&2
fi

if [ "$RUN_PREP_RAN" -eq 1 ] && [ "$RUN_PREP_EXIT" -ne 0 ]; then
  echo "ERROR: --run-prep のコマンドが失敗しました（exit ${RUN_PREP_EXIT}）" >&2
  exit 4
fi

# 成功したのでロック取得済みなら done マーカーを書く（#111）。
if [ "$LOCK_ELIGIBLE" -eq 1 ]; then
  printf '' > "${LOCK_DIR}/done" 2>/dev/null || true
fi

exit 0

fi

# ---------------------------------------------------------------------------
# --detach: 共有モードの逆操作（#110）。レーン側 <dir> が symlink であれば解除する。
# 判定・解除はコンテナ内で行う（共有モードと同じ理由。ホストが Windows（Git Bash）の場合、
# コンテナ内から作られた symlink をホスト側の test -L が正しく判定できない）。
# symlink でない実体には絶対に触れない（not-a-link として保護し、削除しない）。
# コンテナへの投入は1回にまとめる（エントリごとに docker exec を往復させない）。
# --dry-run 指定時は detached 行を出すが実際には解除しない（共有モードの linked と同じ慣習）。
# ---------------------------------------------------------------------------

if [ "$DETACH" -eq 1 ]; then

DETACH_SCRIPT="set -u"$'\n'
# shellcheck disable=SC2016  # 単一引用符は意図的。$d はここでは展開せず、
# コンテナ側で実行されるミニスクリプトの文字列としてそのまま埋め込む。
for dir in "${ENTRY_DIRS[@]}"; do
  DETACH_SCRIPT+="d=$(printf '%q' "$dir")"$'\n'
  DETACH_SCRIPT+='if [ -L "$d" ]; then'$'\n'
  if [ "$DRY_RUN" -eq 1 ]; then
    DETACH_SCRIPT+='  printf "detached\t%s\n" "$d"'$'\n'
  else
    DETACH_SCRIPT+='  if unlink "$d" 2>/dev/null; then'$'\n'
    DETACH_SCRIPT+='    printf "detached\t%s\n" "$d"'$'\n'
    DETACH_SCRIPT+='  else'$'\n'
    DETACH_SCRIPT+='    printf "skip\t%s\treason\tunlink-failed\n" "$d"'$'\n'
    DETACH_SCRIPT+='  fi'$'\n'
  fi
  DETACH_SCRIPT+='elif [ -e "$d" ]; then'$'\n'
  DETACH_SCRIPT+='  printf "skip\t%s\treason\tnot-a-link\n" "$d"'$'\n'
  DETACH_SCRIPT+='else'$'\n'
  DETACH_SCRIPT+='  printf "skip\t%s\treason\tabsent\n" "$d"'$'\n'
  DETACH_SCRIPT+='fi'$'\n'
done

SANDBOX_ARGS=()
[ -n "$EPIC" ] && SANDBOX_ARGS+=(--epic "$EPIC")

bash "$SANDBOX_EXEC" "${SANDBOX_ARGS[@]}" "$DETACH_SCRIPT"
exit $?

fi
