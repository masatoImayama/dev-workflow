#!/bin/bash
# dev-workflow: このリポジトリ自身を検証するテストランナー（ベンダー中立・Docker 非依存）
#
# bats 等の外部依存を追加せず、素の bash アサーションだけで組み立てる。
# ここに書くテストは Docker を一切呼び出さない。`scripts/sandbox-exec.sh --print-plan`
# のようなドライラン出力・構文チェックのみを対象にする（Docker を使う検証は別途サンドボックス内で行う）。
#
# 使い方:
#   bash tests/run-tests.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# run スキルは SKILL.md 本体 + references/*.md の progressive disclosure 構成である。
# 「run スキルにこの記述があるか」を問うテストは、本体だけを見ると参照ファイルへ移した記述を
# 取りこぼす。本体を先頭に置いた平坦化ビューを1つ作り、内容の有無を問うテストはこれを見る
# （本体内の記述の**順序**を問うテストは、従来どおり SKILL.md 本体そのものを見ること）。
RUN_SKILL_FLAT="$(mktemp "${TMPDIR:-/tmp}/dw-run-skill-flat.XXXXXX")"
cat "${REPO_ROOT}/skills/run/SKILL.md" > "$RUN_SKILL_FLAT"
for _ref in "${REPO_ROOT}"/skills/run/references/*.md; do
  [ -f "$_ref" ] || continue
  printf '
' >> "$RUN_SKILL_FLAT"
  cat "$_ref" >> "$RUN_SKILL_FLAT"
done
unset _ref
trap 'rm -f "$RUN_SKILL_FLAT"' EXIT

# core/instructions.md も同じ progressive disclosure 構成（本体 + core/references/*.md）を
# 採る（Task #146）。本体だけを見ると参照ファイルへ移した記述を取りこぼすため、同じ作法で
# 平坦化ビューを1つ作る。
CORE_INSTRUCTIONS_FLAT="$(mktemp "${TMPDIR:-/tmp}/dw-core-instructions-flat.XXXXXX")"
cat "${REPO_ROOT}/core/instructions.md" > "$CORE_INSTRUCTIONS_FLAT"
for _ref in "${REPO_ROOT}"/core/references/*.md; do
  [ -f "$_ref" ] || continue
  printf '\n' >> "$CORE_INSTRUCTIONS_FLAT"
  cat "$_ref" >> "$CORE_INSTRUCTIONS_FLAT"
done
unset _ref

# core/roles/evaluator.md も同じ構成（本体 + core/references/review-checklist-*.md 等）を
# 採る（Task #151）。evaluator 用の平坦化ビューを2つ作る:
# - EVALUATOR_ROLE_FLAT: 正本（core/roles/evaluator.md）+ core/references/*.md
# - AGENT_EVALUATOR_FLAT: 生成物（agents/evaluator.md）+ core/references/*.md
#   （生成物は <!-- include: --> で core/roles/evaluator.md をそのまま束ねるだけで
#   core/references/*.md は束ねない＝実行時に evaluator が Read ツールで読む設計のため、
#   生成物単体を見るテストは参照ファイルへ移った記述を取りこぼす）
EVALUATOR_ROLE_FLAT="$(mktemp "${TMPDIR:-/tmp}/dw-evaluator-role-flat.XXXXXX")"
cat "${REPO_ROOT}/core/roles/evaluator.md" > "$EVALUATOR_ROLE_FLAT"
AGENT_EVALUATOR_FLAT="$(mktemp "${TMPDIR:-/tmp}/dw-agent-evaluator-flat.XXXXXX")"
cat "${REPO_ROOT}/agents/evaluator.md" > "$AGENT_EVALUATOR_FLAT"
CODEX_AGENT_EVALUATOR_FLAT="$(mktemp "${TMPDIR:-/tmp}/dw-codex-agent-evaluator-flat.XXXXXX")"
cat "${REPO_ROOT}/codex-agents/evaluator.toml" > "$CODEX_AGENT_EVALUATOR_FLAT"
for _ref in "${REPO_ROOT}"/core/references/*.md; do
  [ -f "$_ref" ] || continue
  printf '\n' >> "$EVALUATOR_ROLE_FLAT"
  cat "$_ref" >> "$EVALUATOR_ROLE_FLAT"
  printf '\n' >> "$AGENT_EVALUATOR_FLAT"
  cat "$_ref" >> "$AGENT_EVALUATOR_FLAT"
  printf '\n' >> "$CODEX_AGENT_EVALUATOR_FLAT"
  cat "$_ref" >> "$CODEX_AGENT_EVALUATOR_FLAT"
done
unset _ref
trap 'rm -f "$RUN_SKILL_FLAT" "$CORE_INSTRUCTIONS_FLAT" "$EVALUATOR_ROLE_FLAT" "$AGENT_EVALUATOR_FLAT" "$CODEX_AGENT_EVALUATOR_FLAT"' EXIT

PASS=0
FAIL=0
SKIP=0
FAILED_CASES=()

pass() {
  PASS=$((PASS + 1))
  echo "  ok   - $1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES+=("$1")
  echo "  NG   - $1"
  [ -n "${2:-}" ] && echo "         ${2}"
}

skip() {
  SKIP=$((SKIP + 1))
  echo "  skip - $1 (${2:-})"
}

assert_eq() {
  # assert_eq <説明> <期待値> <実際の値>
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "expected=[${expected}] actual=[${actual}]"
  fi
}

assert_exit_code() {
  # assert_exit_code <説明> <期待する終了コード> <実際の終了コード>
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" -eq "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "expected exit=${expected} actual exit=${actual}"
  fi
}

assert_no_hang() {
  # assert_no_hang <説明> <期待する終了コード> <実際の終了コード> <実際のstderr(またはstdout+stderr)> <stderrに含まれるべき文字列>
  #
  # 「無限ループしない（ハングしない）」ことを検証するテストは `timeout` でコマンドを
  # 打ち切って回帰を防ぐが、timeout がタイムアウト時に返す終了コードは環境依存
  # （GNU coreutils=124, BusyBox=143 など SIGTERM由来の 128+シグナル番号）であり、
  # 「タイムアウトで打ち切られた（=ハングしたまま殺された）」ことを終了コードだけで
  # 判定できない。ハングした場合はエラーメッセージも出力されないため、
  # 「期待する終了コードちょうどであること」と「期待するエラーメッセージが出ていること」の
  # 両方を assert することで、ハング（timeoutによる強制終了）を確実に不合格にする。
  local desc="$1" expected_exit="$2" actual_exit="$3" actual_output="$4" expected_msg="$5"
  if [ "$actual_exit" -eq "$expected_exit" ] && printf '%s' "$actual_output" | grep -Fq -- "$expected_msg"; then
    pass "$desc"
  else
    fail "$desc" "expected exit=${expected_exit}（メッセージに[${expected_msg}]を含む） actual exit=${actual_exit} output=[${actual_output}]"
  fi
}

# ---------------------------------------------------------------------------
# 一時 git リポジトリ / worktree を組み立てるヘルパ。
# 後続タスク（epic worktree / agent worktree / リポジトリ外 worktree のケース追加）で再利用する。
# 一時ディレクトリは mktemp -d 配下に限定し、削除コマンドは実行しない
# （OS のテンポラリ領域に任せる。破壊的コマンドを避けるため明示的な rm は行わない）。
# ---------------------------------------------------------------------------

make_temp_repo() {
  # 新規の一時 git リポジトリを作り、初回コミットまで済ませてパスを返す。
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-repo.XXXXXX")"
  (
    cd "$dir" || exit 1
    git init -q
    git config user.email "dev-workflow-test@example.com"
    git config user.name "dev-workflow test"
    printf 'test repo\n' > README.md
    git add README.md
    git commit -q -m "init"
  ) >/dev/null 2>&1
  printf '%s' "$dir"
}

make_worktree() {
  # make_worktree <repo_dir> <worktree_dir> <branch>
  # repo_dir に対して worktree_dir へ新しいブランチの worktree を追加する。
  local repo_dir="$1" worktree_dir="$2" branch="$3"
  (
    cd "$repo_dir" || exit 1
    git worktree add -q -b "$branch" "$worktree_dir"
  ) >/dev/null 2>&1
}

copy_sandbox_scripts() {
  # copy_sandbox_scripts <dest_repo_dir>
  # sandbox-exec.sh / resolve-sandbox.sh / lib / Dockerfile.dev を検証対象の一時リポジトリへ複製する。
  # worktree はコミット済みの内容しか見えないため、複製後にコミットまで済ませる
  # （worktree からもスクリプトを実行できるようにするため）。
  local dest="$1"
  mkdir -p "${dest}/scripts/lib"
  cp "${REPO_ROOT}/scripts/sandbox-exec.sh"    "${dest}/scripts/sandbox-exec.sh"
  cp "${REPO_ROOT}/scripts/resolve-sandbox.sh" "${dest}/scripts/resolve-sandbox.sh"
  cp "${REPO_ROOT}/scripts/lib/mount-path.sh"           "${dest}/scripts/lib/mount-path.sh"
  cp "${REPO_ROOT}/scripts/lib/container-membership.sh" "${dest}/scripts/lib/container-membership.sh"
  cp "${REPO_ROOT}/scripts/lib/compose-conflicts.sh"    "${dest}/scripts/lib/compose-conflicts.sh"
  cp "${REPO_ROOT}/Dockerfile.dev"             "${dest}/Dockerfile.dev"
  (
    cd "$dest" || exit 1
    git add scripts Dockerfile.dev
    git commit -q -m "add sandbox scripts"
  ) >/dev/null 2>&1
}

copy_sandbox_scripts_no_dockerfile() {
  # copy_sandbox_scripts_no_dockerfile <dest_repo_dir>
  # compose モード検証用。Dockerfile.dev を置かないことで resolve-sandbox.sh が
  # compose モードを解決するようにする（Dockerfile.dev が優先されてしまうため）。
  local dest="$1"
  mkdir -p "${dest}/scripts/lib"
  cp "${REPO_ROOT}/scripts/sandbox-exec.sh"    "${dest}/scripts/sandbox-exec.sh"
  cp "${REPO_ROOT}/scripts/resolve-sandbox.sh" "${dest}/scripts/resolve-sandbox.sh"
  cp "${REPO_ROOT}/scripts/lib/mount-path.sh"           "${dest}/scripts/lib/mount-path.sh"
  cp "${REPO_ROOT}/scripts/lib/container-membership.sh" "${dest}/scripts/lib/container-membership.sh"
  cp "${REPO_ROOT}/scripts/lib/compose-conflicts.sh"    "${dest}/scripts/lib/compose-conflicts.sh"
  (
    cd "$dest" || exit 1
    git add scripts
    git commit -q -m "add sandbox scripts (no dockerfile)"
  ) >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# ケース1: 全 scripts/*.sh に対する bash -n（構文チェック）
# ---------------------------------------------------------------------------

echo "== bash -n（構文チェック） =="

for script in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh; do
  name="$(basename "$script")"
  bashn_out="$(bash -n "$script" 2>&1)"
  if [ $? -eq 0 ]; then
    pass "bash -n: ${name}"
  else
    fail "bash -n: ${name}" "$bashn_out"
  fi
done

# ---------------------------------------------------------------------------
# ケース2: shellcheck（あれば実行。無ければ skip 扱いで通す）
# ---------------------------------------------------------------------------

echo "== shellcheck（利用可能な場合のみ） =="

if command -v shellcheck >/dev/null 2>&1; then
  # -x: sandbox-exec.sh は変数（${SCRIPT_DIR}）経由で scripts/lib/*.sh を source する。
  # shellcheck はデフォルトでは変数経由の source 先を検証しない（SC1091）ため、
  # severity を下げるのではなく -x で実際に解決させて検証の穴を作らないようにする。
  for script in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh; do
    name="$(basename "$script")"
    shellcheck_out="$(cd "$(dirname "$script")" && shellcheck -x "$(basename "$script")" 2>&1)"
    if [ $? -eq 0 ]; then
      pass "shellcheck: ${name}"
    else
      fail "shellcheck: ${name}" "$shellcheck_out"
    fi
  done
else
  skip "shellcheck" "コマンドが見つからないためスキップ"
fi

# ---------------------------------------------------------------------------
# ケース3: --print-plan がドライランであること（docker を一切呼ばない）
# ---------------------------------------------------------------------------

echo "== --print-plan（ドライラン） =="

PRINT_PLAN_REPO="$(make_temp_repo)"
copy_sandbox_scripts "$PRINT_PLAN_REPO"

# 実際に docker を呼んでいないことを検出するため、docker という名前の偽コマンドを
# PATH の先頭に置き、呼ばれたらマーカーファイルを残して失敗させる。
FAKE_BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fakebin.XXXXXX")"
DOCKER_CALLED_MARKER="${FAKE_BIN_DIR}/docker-called-marker"
cat > "${FAKE_BIN_DIR}/docker" <<'FAKE_DOCKER'
#!/bin/bash
echo "$@" >> "${DOCKER_CALLED_MARKER}"
exit 1
FAKE_DOCKER
chmod +x "${FAKE_BIN_DIR}/docker"

PRINT_PLAN_OUTPUT="$(
  cd "$PRINT_PLAN_REPO" || exit 1
  DOCKER_CALLED_MARKER="$DOCKER_CALLED_MARKER" PATH="${FAKE_BIN_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --print-plan
)"
PRINT_PLAN_EXIT=$?

assert_exit_code "--print-plan は exit 0 で終わる" 0 "$PRINT_PLAN_EXIT"

if [ -f "$DOCKER_CALLED_MARKER" ]; then
  fail "--print-plan は docker を起動しない" "docker が呼ばれました: $(cat "$DOCKER_CALLED_MARKER")"
else
  pass "--print-plan は docker を起動しない"
fi

get_plan_value() {
  # get_plan_value <key>  出力から key=value の value 部分（先頭一致1件）を取り出す
  printf '%s\n' "$PRINT_PLAN_OUTPUT" | grep "^${1}=" | head -n1 | cut -d'=' -f2-
}

REPO_BASENAME="$(basename "$PRINT_PLAN_REPO")"

assert_eq "mode=dockerfile" "dockerfile" "$(get_plan_value mode)"
assert_eq "repo は一時リポジトリのディレクトリ名と一致" "$REPO_BASENAME" "$(get_plan_value repo)"
assert_eq "epic 未指定時は空" "" "$(get_plan_value epic)"
assert_eq "mount_target は /workspace" "/workspace" "$(get_plan_value mount_target)"
assert_eq "workdir は /workspace" "/workspace" "$(get_plan_value workdir)"
assert_eq "container はリポジトリ名から決まる" "dw-sandbox-${REPO_BASENAME}" "$(get_plan_value container)"

# image はリポジトリ名 + Dockerfile.dev 内容の hash8（Task #8、仕様書 4.7）で決まる。
# hash8 の具体的な値は Dockerfile.dev の内容依存のため、ここではプレフィックスと
# 末尾8文字が16進数であることだけを確認する（内容変更への追随はケース7で検証する）。
IMAGE_VALUE="$(get_plan_value image)"
case "$IMAGE_VALUE" in
  "dev-sandbox:${REPO_BASENAME}-"*) pass "image はリポジトリ名+hash8のプレフィックスを持つ" ;;
  *) fail "image はリポジトリ名+hash8のプレフィックスを持つ" "image=[${IMAGE_VALUE}]" ;;
esac

IMAGE_HASH_SUFFIX="${IMAGE_VALUE: -8}"
case "$IMAGE_HASH_SUFFIX" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    pass "image の末尾8文字が16進数のhashである" ;;
  *)
    fail "image の末尾8文字が16進数のhashである" "suffix=[${IMAGE_HASH_SUFFIX}]" ;;
esac

assert_eq "dockerfile は Dockerfile.dev" "Dockerfile.dev" "$(get_plan_value dockerfile)"

BUILD_CONTEXT_VALUE="$(get_plan_value build_context)"
case "$BUILD_CONTEXT_VALUE" in
  *"$REPO_BASENAME") pass "--print-plan に build_context が出る（一時リポジトリを指す）" ;;
  *) fail "--print-plan に build_context が出る（一時リポジトリを指す）" "build_context=[${BUILD_CONTEXT_VALUE}]" ;;
esac

# mount_source はこのケースでは一時リポジトリのパス（pwd -W 相当）を指すはず。
MOUNT_SOURCE="$(get_plan_value mount_source)"
case "$MOUNT_SOURCE" in
  *"$REPO_BASENAME") pass "mount_source が一時リポジトリを指す" ;;
  *) fail "mount_source が一時リポジトリを指す" "mount_source=[${MOUNT_SOURCE}]" ;;
esac

# cache_volume が複数行、key=value:path 形式で出ていることを確認する。
CACHE_VOLUME_COUNT="$(printf '%s\n' "$PRINT_PLAN_OUTPUT" | grep -c '^cache_volume=')"
if [ "$CACHE_VOLUME_COUNT" -gt 0 ]; then
  pass "cache_volume が1件以上出力される（${CACHE_VOLUME_COUNT}件）"
else
  fail "cache_volume が1件以上出力される" "0件でした"
fi

FIRST_CACHE_LINE="$(printf '%s\n' "$PRINT_PLAN_OUTPUT" | grep '^cache_volume=' | head -n1)"
case "$FIRST_CACHE_LINE" in
  cache_volume=dw-cache-"${REPO_BASENAME}"-*:*) pass "cache_volume の命名がリポジトリ単位である" ;;
  *) fail "cache_volume の命名がリポジトリ単位である" "実際の1行目: ${FIRST_CACHE_LINE}" ;;
esac

# --epic 指定時にコンテナ名へ反映されることも、この段階の挙動として確認しておく。
PRINT_PLAN_EPIC_OUTPUT="$(
  cd "$PRINT_PLAN_REPO" || exit 1
  DOCKER_CALLED_MARKER="$DOCKER_CALLED_MARKER" PATH="${FAKE_BIN_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --epic epic999 --print-plan
)"
EPIC_CONTAINER="$(printf '%s\n' "$PRINT_PLAN_EPIC_OUTPUT" | grep '^container=' | cut -d'=' -f2-)"
assert_eq "--epic 指定時はコンテナ名に反映される" "dw-sandbox-${REPO_BASENAME}-epic999" "$EPIC_CONTAINER"

if [ -f "$DOCKER_CALLED_MARKER" ]; then
  fail "--epic 付き --print-plan も docker を起動しない" "docker が呼ばれました: $(cat "$DOCKER_CALLED_MARKER")"
else
  pass "--epic 付き --print-plan も docker を起動しない"
fi

# --- --epic に値が無いまま渡された場合は無限ループせず明快なエラーで停止する ---
# shift 2 が失敗して $# が減らないまま while ループが回り続ける不具合があった
# （実測: timeout 8 bash scripts/sandbox-exec.sh --epic は exit 124 だった。
# ただし sandbox 内の BusyBox timeout は exit 143 を返すため、終了コードのみでは
# 「ハングして timeout に強制終了させられた」ことを判定できない。詳細は assert_no_hang 参照）。
if command -v timeout >/dev/null 2>&1; then
  EPIC_NO_VALUE_STDERR="$(
    cd "$PRINT_PLAN_REPO" || exit 1
    PATH="${FAKE_BIN_DIR}:${PATH}" timeout 8 bash scripts/sandbox-exec.sh --epic 2>&1 1>/dev/null
  )"
  EPIC_NO_VALUE_EXIT=$?

  assert_no_hang "--epic に値が無い場合は無限ループせず exit 2 かつ --epic の記載があるエラーで停止する" \
    2 "$EPIC_NO_VALUE_EXIT" "$EPIC_NO_VALUE_STDERR" "--epic には値が必要です"
else
  skip "--epic に値が無い場合は無限ループせず明快なエラーで停止する" "timeout コマンドが利用できません"
fi

# ---------------------------------------------------------------------------
# ケース1〜6: パス解決とコンテナ名の一致（Epic #3 仕様書「5. 検証方針」のケース1〜6、Task #5）
#
# バインドマウント先をリポジトリルートに固定し、コンテナを epic 単位にする変更の検証。
# リポジトリルート / epic worktree / agent worktree のいずれから叩いても
# container が完全に一致し、workdir だけが相対パス分だけ変わることを確認する。
# ---------------------------------------------------------------------------

echo "== パス解決とコンテナ名（ケース1〜6） =="

plan_value() {
  # plan_value <key> <output>  出力から key=value の value 部分（先頭一致1件）を取り出す
  printf '%s\n' "$2" | grep "^${1}=" | head -n1 | cut -d'=' -f2-
}

print_plan_in() {
  # print_plan_in <dir> [追加の引数...]  <dir> で --print-plan を実行し出力全体を返す
  local dir="$1"
  shift
  (
    cd "$dir" || exit 1
    PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan "$@"
  )
}

# --- ケース1: リポジトリルートから ---
CASE1_OUTPUT="$(print_plan_in "$PRINT_PLAN_REPO")"

assert_eq "ケース1: rel_path は空" "" "$(plan_value rel_path "$CASE1_OUTPUT")"
assert_eq "ケース1: fallback は0" "0" "$(plan_value fallback "$CASE1_OUTPUT")"
assert_eq "ケース1: workdir は /workspace" "/workspace" "$(plan_value workdir "$CASE1_OUTPUT")"

CASE1_CONTAINER="$(plan_value container "$CASE1_OUTPUT")"

# --- ケース2: epic worktree（.claude/worktrees/epicN）から ---
EPIC_WORKTREE_DIR="${PRINT_PLAN_REPO}/.claude/worktrees/epic5"
make_worktree "$PRINT_PLAN_REPO" "$EPIC_WORKTREE_DIR" "epic-worktree-branch"

CASE2_OUTPUT="$(print_plan_in "$EPIC_WORKTREE_DIR")"

assert_eq "ケース2: rel_path は .claude/worktrees/epic5" ".claude/worktrees/epic5" "$(plan_value rel_path "$CASE2_OUTPUT")"
assert_eq "ケース2: workdir は相対パス" "/workspace/.claude/worktrees/epic5" "$(plan_value workdir "$CASE2_OUTPUT")"
assert_eq "ケース2: container はルート実行時と同一" "$CASE1_CONTAINER" "$(plan_value container "$CASE2_OUTPUT")"

# --- ケース3: agent worktree（.claude/worktrees/agent-x）から ---
AGENT_WORKTREE_DIR="${PRINT_PLAN_REPO}/.claude/worktrees/agent-x"
make_worktree "$PRINT_PLAN_REPO" "$AGENT_WORKTREE_DIR" "agent-worktree-branch"

CASE3_OUTPUT="$(print_plan_in "$AGENT_WORKTREE_DIR")"

assert_eq "ケース3: rel_path は .claude/worktrees/agent-x" ".claude/worktrees/agent-x" "$(plan_value rel_path "$CASE3_OUTPUT")"
assert_eq "ケース3: workdir は相対パス" "/workspace/.claude/worktrees/agent-x" "$(plan_value workdir "$CASE3_OUTPUT")"
assert_eq "ケース3: container はケース1・2と同一" "$CASE1_CONTAINER" "$(plan_value container "$CASE3_OUTPUT")"

# --- ケース4: --epic 無し + DEV_WORKFLOW_EPIC あり ---
CASE4_OUTPUT="$(
  cd "$PRINT_PLAN_REPO" || exit 1
  DEV_WORKFLOW_EPIC=epic777 PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
assert_eq "ケース4: DEV_WORKFLOW_EPIC がコンテナ名に反映される" "${CASE1_CONTAINER}-epic777" "$(plan_value container "$CASE4_OUTPUT")"
assert_eq "ケース4: epic の値も DEV_WORKFLOW_EPIC になる" "epic777" "$(plan_value epic "$CASE4_OUTPUT")"

# --- ケース5: リポジトリ外の worktree（フォールバック） ---
OUTSIDE_WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-outside.XXXXXX")"
make_worktree "$PRINT_PLAN_REPO" "$OUTSIDE_WORKTREE_DIR" "outside-worktree-branch"

CASE5_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-case5-stderr.XXXXXX")"
CASE5_OUTPUT="$(
  cd "$OUTSIDE_WORKTREE_DIR" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan 2>"$CASE5_STDERR"
)"

assert_eq "ケース5: fallback は1" "1" "$(plan_value fallback "$CASE5_OUTPUT")"

CASE5_CONTAINER="$(plan_value container "$CASE5_OUTPUT")"
if [ "$CASE5_CONTAINER" != "$CASE1_CONTAINER" ]; then
  pass "ケース5: container がリポジトリ共有コンテナと分離される"
else
  fail "ケース5: container がリポジトリ共有コンテナと分離される" "container=[${CASE5_CONTAINER}]（共有コンテナと同一でした）"
fi

if [ -s "$CASE5_STDERR" ]; then
  pass "ケース5: フォールバック時に stderr へ警告する"
else
  fail "ケース5: フォールバック時に stderr へ警告する" "stderr が空でした"
fi

# --- ケース6: キャッシュ volume 名がリポジトリ単位である（worktree から叩いても変わらない） ---
CASE1_CACHE="$(plan_value cache_volume "$CASE1_OUTPUT")"
CASE3_CACHE="$(plan_value cache_volume "$CASE3_OUTPUT")"
assert_eq "ケース6: cache_volume はリポジトリ単位（worktree から叩いても同じ）" "$CASE1_CACHE" "$CASE3_CACHE"

# ---------------------------------------------------------------------------
# ケース7a: normalize_mount_source（Docker 非依存の純粋関数、issue #25）
#
# Windows + Docker Desktop の bind mount .Source（/run/desktop/mnt/host/<drive>/...）と
# pwd -W によるホスト側パス（<DRIVE>:/...）を、大小文字・区切りを揃えた同一表現に
# 正規化できることを、docker を一切起動せずに直接検証する。
# ---------------------------------------------------------------------------

echo "== normalize_mount_source（マウント元の正規化・Docker 非依存・issue #25） =="

# shellcheck source=../scripts/lib/mount-path.sh
. "${REPO_ROOT}/scripts/lib/mount-path.sh"

assert_eq "normalize_mount_source: Docker Desktop 形式 (/run/desktop/mnt/host/<drive>/...) を <DRIVE>:/... へ変換する" \
  "C:/users/mimay/documents/github/dev-workflow" \
  "$(normalize_mount_source "/run/desktop/mnt/host/c/Users/mimay/Documents/github/dev-workflow")"

assert_eq "normalize_mount_source: pwd -W 形式（既に <DRIVE>:/...）も同じ表現に正規化する" \
  "C:/users/mimay/documents/github/dev-workflow" \
  "$(normalize_mount_source "C:/Users/mimay/Documents/github/dev-workflow")"

assert_eq "normalize_mount_source: /mnt/<drive>/...（WSL）も同じ表現に正規化する" \
  "C:/users/mimay/documents/github/dev-workflow" \
  "$(normalize_mount_source "/mnt/c/Users/mimay/Documents/github/dev-workflow")"

assert_eq "normalize_mount_source: //<drive>/...（Git Bash 等）も同じ表現に正規化する" \
  "C:/users/mimay/documents/github/dev-workflow" \
  "$(normalize_mount_source "//c/Users/mimay/Documents/github/dev-workflow")"

assert_eq "normalize_mount_source: バックスラッシュ区切りもスラッシュへ統一する" \
  "C:/users/mimay/repo" \
  "$(normalize_mount_source 'C:\Users\mimay\repo')"

assert_eq "normalize_mount_source: ドライブ形式でない通常の Unix パスは大小文字を変えずそのまま返す" \
  "/home/User/Repo" \
  "$(normalize_mount_source "/home/User/Repo")"

# ---------------------------------------------------------------------------
# ケース7b: container_belongs_to_repo（Docker 非依存の所属判定関数、Task #6 / issue #29）
#
# label あり／label なしの旧命名残骸／他リポジトリの各パターンに加え、
# dev-workflow.root label による同名 basename・別 root の判別（issue #29）と、
# Docker Desktop 形式マウント元の正規化済み比較（issue #25）を、docker を一切
# 起動せずに純粋関数として直接検証する。
#
# シグネチャ: container_belongs_to_repo <label_repo> <label_root> <mount_source> <host_root> <project>
# ---------------------------------------------------------------------------

echo "== container_belongs_to_repo（所属判定・Docker 非依存） =="

# shellcheck source=../scripts/lib/container-membership.sh
. "${REPO_ROOT}/scripts/lib/container-membership.sh"

HOST_ROOT_SAMPLE="/home/user/repo"

if container_belongs_to_repo "myrepo" "$HOST_ROOT_SAMPLE" "" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "label の repo と root label が一致すれば対象に含まれる"
else
  fail "label の repo と root label が一致すれば対象に含まれる"
fi

if container_belongs_to_repo "myrepo" "/home/user2/repo" "" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "同名 basename でも root label が不一致なら対象に含まれない（issue #29）" "含まれてしまいました"
else
  pass "同名 basename でも root label が不一致なら対象に含まれない（issue #29）"
fi

if container_belongs_to_repo "otherrepo" "" "${HOST_ROOT_SAMPLE}/anything" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "label の repo が不一致なら対象に含まれない" "含まれてしまいました（マウント元が一致していても label 不一致を優先すべき）"
else
  pass "label の repo が不一致なら対象に含まれない"
fi

if container_belongs_to_repo "myrepo" "" "${HOST_ROOT_SAMPLE}/anything" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "root label が空（旧コンテナ）の場合はマウント元判定にフォールバックする"
else
  fail "root label が空（旧コンテナ）の場合はマウント元判定にフォールバックする"
fi

if container_belongs_to_repo "myrepo" "" "/home/user/other-repo/subdir" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "root label が空でもマウント元が別リポジトリなら対象に含まれない" "含まれてしまいました"
else
  pass "root label が空でもマウント元が別リポジトリなら対象に含まれない"
fi

if container_belongs_to_repo "" "" "${HOST_ROOT_SAMPLE}/.claude/worktrees/agent-old" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "label なし・マウント元がリポジトリルート配下なら対象に含まれる（旧命名の残骸回収）"
else
  fail "label なし・マウント元がリポジトリルート配下なら対象に含まれる"
fi

if container_belongs_to_repo "" "" "$HOST_ROOT_SAMPLE" "$HOST_ROOT_SAMPLE" "myrepo"; then
  pass "label なし・マウント元がリポジトリルート自身でも対象に含まれる"
else
  fail "label なし・マウント元がリポジトリルート自身でも対象に含まれる"
fi

if container_belongs_to_repo "" "" "/home/user/other-repo/subdir" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "label なし・マウント元が別リポジトリなら対象に含まれない" "含まれてしまいました"
else
  pass "label なし・マウント元が別リポジトリなら対象に含まれない"
fi

if container_belongs_to_repo "" "" "" "$HOST_ROOT_SAMPLE" "myrepo"; then
  fail "label もマウント元も無ければ対象に含まれない" "含まれてしまいました"
else
  pass "label もマウント元も無ければ対象に含まれない"
fi

# --- issue #25: label なし・Docker Desktop 形式のマウント元でも正規化して同一ツリーと判定する ---
if container_belongs_to_repo "" "" "/run/desktop/mnt/host/c/Users/mimay/Documents/github/dev-workflow" \
    "C:/Users/mimay/Documents/github/dev-workflow" "dev-workflow"; then
  pass "label なし・Docker Desktop 形式のマウント元でも正規化して同一ツリーと判定する（issue #25）"
else
  fail "label なし・Docker Desktop 形式のマウント元でも正規化して同一ツリーと判定する（issue #25）"
fi

if container_belongs_to_repo "" "" "/run/desktop/mnt/host/c/Users/mimay/Documents/github/other-repo" \
    "C:/Users/mimay/Documents/github/dev-workflow" "dev-workflow"; then
  fail "Docker Desktop 形式でも別ツリーなら対象に含まれない" "含まれてしまいました"
else
  pass "Docker Desktop 形式でも別ツリーなら対象に含まれない"
fi

# --- issue #29: root label が Docker Desktop 形式・pwd -W 形式など異なる表現でも正規化して一致する ---
if container_belongs_to_repo "myrepo" "/run/desktop/mnt/host/c/Users/mimay/repo" "" \
    "C:/Users/mimay/repo" "myrepo"; then
  pass "root label が別表現（Docker Desktop 形式）でも正規化して一致すれば対象に含まれる（issue #29）"
else
  fail "root label が別表現（Docker Desktop 形式）でも正規化して一致すれば対象に含まれる（issue #29）"
fi

# ---------------------------------------------------------------------------
# ケース7c: dev_workflow_marker_root（マーカー置き場の解決・外部プロセス0、Task #43）
#
# heartbeat.sh（フックから高頻度に呼ばれる。Phase 2 で追加予定）の前提として、この関数は
# 解決処理の中で外部プロセスを一切起動しない。worktree の .git は
# `gitdir: <メインリポ>/.git/worktrees/<名前>` という1行ファイルなので bash の read だけで
# 解析できる（Epic #42 仕様書「3. ファイルと責務」）。
#
# ---------------------------------------------------------------------------

echo "== dev_workflow_marker_root（マーカー置き場の解決・外部プロセス0・Task #43） =="

MARKER_ROOT_LIB="${REPO_ROOT}/scripts/lib/marker-root.sh"

# shellcheck source=../scripts/lib/marker-root.sh
. "$MARKER_ROOT_LIB"

canon_root() {
  # canon_root <dir>  ディレクトリの正規化された絶対パスを返す（pwd -W があれば使う）
  (
    cd "$1" 2>/dev/null || exit 1
    pwd -W 2>/dev/null || pwd
  )
}

# Windows では mktemp が /tmp 配下（MSYS のエイリアス）を返すことがあり、これは
# dev_workflow_marker_root の -d .git 分岐（渡された表現をそのまま返す）と、
# .git ファイル分岐（git 自身が書いた実パスを読む。Windows では常にドライブレター形式）とで
# 表現が食い違う原因になる（実機で確認済み。ドライブレター形式どうしの揺れは
# _dev_workflow_marker_root_normalize が吸収するが、/tmp エイリアスの実パスへの
# 解決は対象外＝コマンド置換なしでは原理的にできない）。
# そのため一時リポジトリのパスは最初に canon_root で実パスへ正規化してから使う。
MR_REPO="$(canon_root "$(make_temp_repo)")"
MR_EXPECTED="$MR_REPO"

assert_eq "dev_workflow_marker_root: メインリポのルートで正しいパスを返す" \
  "$MR_EXPECTED" "$(dev_workflow_marker_root "$MR_REPO")"

mkdir -p "${MR_REPO}/sub/dir"
assert_eq "dev_workflow_marker_root: メインリポのサブディレクトリから呼んでもルートを返す" \
  "$MR_EXPECTED" "$(dev_workflow_marker_root "${MR_REPO}/sub/dir")"

MR_EPIC_WT="${MR_REPO}/.claude/worktrees/epic9"
make_worktree "$MR_REPO" "$MR_EPIC_WT" "mr-epic-branch"
assert_eq "dev_workflow_marker_root: epic worktree（.claude/worktrees/epicN）からメインリポのルートを返す" \
  "$MR_EXPECTED" "$(dev_workflow_marker_root "$MR_EPIC_WT")"

MR_AGENT_WT="${MR_REPO}/.claude/worktrees/agent-x"
make_worktree "$MR_REPO" "$MR_AGENT_WT" "mr-agent-branch"
assert_eq "dev_workflow_marker_root: agent worktree（.claude/worktrees/agent-xxx）からメインリポのルートを返す" \
  "$MR_EXPECTED" "$(dev_workflow_marker_root "$MR_AGENT_WT")"

MR_NONGIT="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-nongit.XXXXXX")"
MR_NONGIT_OUT="$(dev_workflow_marker_root "$MR_NONGIT")"
MR_NONGIT_EXIT=$?
assert_eq "dev_workflow_marker_root: git 管理外のディレクトリでは空文字を返す" "" "$MR_NONGIT_OUT"
assert_exit_code "dev_workflow_marker_root: git 管理外のディレクトリでは非0終了する" 1 "$MR_NONGIT_EXIT"

MR_OVERRIDE_VALUE="/custom/marker/root/for/test"
MR_OVERRIDE_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$MR_OVERRIDE_VALUE" dev_workflow_marker_root "$MR_REPO")"
assert_eq "dev_workflow_marker_root: DEV_WORKFLOW_MARKER_ROOT が最優先で使われる" \
  "$MR_OVERRIDE_VALUE" "$MR_OVERRIDE_OUT"

# CLAUDE_PROJECT_DIR はそのまま使う仕様（正規化しない）なので、既に実パス化済みの
# $MR_REPO をそのまま渡す。
MR_CLAUDE_PROJECT_OUT="$(CLAUDE_PROJECT_DIR="$MR_REPO" dev_workflow_marker_root "${MR_REPO}/sub/dir")"
assert_eq "dev_workflow_marker_root: CLAUDE_PROJECT_DIR 直下に .git があればそれを使う" \
  "$MR_EXPECTED" "$MR_CLAUDE_PROJECT_OUT"

# --- 解決処理が外部コマンド・コマンド置換を一切起動していないことの静的確認 ---
# コメント行は対象外にし、単語境界での一致だけを見る
# （"gitdir:" 等の識別子内の "git" 部分文字列や、算術展開 $(( )) の "$(" を
# 誤検知しないよう、"git "は後ろに空白を要求し、"$(" は直後が "(" でないものだけを見る）
MR_FORBIDDEN_HITS="$(grep -v '^[[:space:]]*#' "$MARKER_ROOT_LIB" \
  | grep -E '(^|[^A-Za-z0-9_])(git|sed|dirname|basename)[[:space:]]|\$\([^(]|`' || true)"
if [ -z "$MR_FORBIDDEN_HITS" ]; then
  pass "dev_workflow_marker_root: 解決処理が外部コマンド・コマンド置換を使っていない"
else
  fail "dev_workflow_marker_root: 解決処理が外部コマンド・コマンド置換を使っていない" "$MR_FORBIDDEN_HITS"
fi

# --- 性能: 100回呼び出しが十分速いこと（外部プロセス0の下地。受け入れ条件10） ---
MR_PERF_START=""
printf -v MR_PERF_START '%(%s)T' -1
MR_PERF_I=0
while [ "$MR_PERF_I" -lt 100 ]; do
  dev_workflow_marker_root "$MR_EPIC_WT" >/dev/null
  MR_PERF_I=$((MR_PERF_I + 1))
done
MR_PERF_END=""
printf -v MR_PERF_END '%(%s)T' -1
MR_PERF_ELAPSED=$((MR_PERF_END - MR_PERF_START))
if [ "$MR_PERF_ELAPSED" -lt 2 ]; then
  pass "dev_workflow_marker_root: 100回呼び出しが2秒未満（実測 ${MR_PERF_ELAPSED}s、外部プロセス0の下地・受け入れ条件10）"
else
  fail "dev_workflow_marker_root: 100回呼び出しが2秒未満" "実測 ${MR_PERF_ELAPSED}s"
fi

# ---------------------------------------------------------------------------
# ケース8: --ls / --down --all（偽 docker で label・マウント元を注入し、実際の docker を起動せず検証する）
#
# 偽 docker は DW_TEST_MANIFEST（name|managed|repo|epic|image|status|created|mount_source|root_label
# の '|' 区切り行）を読み、docker ps / docker container inspect / docker rm を模擬する。
# `docker rm` は本物を一切呼ばず、DW_TEST_RM_LOG に対象名を追記するだけにする。
# ---------------------------------------------------------------------------

echo "== --ls / --down --all（偽 docker） =="

LS_REPO="$(make_temp_repo)"
copy_sandbox_scripts "$LS_REPO"

LS_PLAN_OUTPUT="$(
  cd "$LS_REPO" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
LS_REPO_BASENAME="$(basename "$LS_REPO")"
LS_HOST_ROOT="$(plan_value repo_root "$LS_PLAN_OUTPUT")"

DW_TEST_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/dw-test-manifest.XXXXXX")"
DW_TEST_RM_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-rmlog.XXXXXX")"
: > "$DW_TEST_RM_LOG"

# 1) label ありで現リポジトリに属するコンテナ（現行の起動中コンテナを模す。root label も一致）
# 2) label なしの旧命名残骸で、マウント元が現リポジトリのルート配下（回収されるべき）
# 3) label ありで他リポジトリに属するコンテナ（--down --all の対象に含まれてはいけない）
# 4) label なしで、マウント元が他リポジトリ配下（対象に含まれてはいけない）
# 5) label ありで repo（basename）は一致するが root label が異なる（別クローン。issue #29。
#    --down --all の対象に含まれてはいけない）
cat > "$DW_TEST_MANIFEST" <<MANIFEST
dw-sandbox-${LS_REPO_BASENAME}|1|${LS_REPO_BASENAME}||dev-sandbox:${LS_REPO_BASENAME}|running|2024-01-01T00:00:00Z|${LS_HOST_ROOT}|${LS_HOST_ROOT}
dw-sandbox-${LS_REPO_BASENAME}-legacy|||||exited|2023-01-01T00:00:00Z|${LS_HOST_ROOT}/.claude/worktrees/agent-old|
dw-sandbox-otherrepo|1|otherrepo||dev-sandbox:otherrepo|running|2024-02-02T00:00:00Z|/home/user/otherrepo|/home/user/otherrepo
dw-sandbox-otherrepo-legacy|||||exited|2023-03-03T00:00:00Z|/home/user/otherrepo/subdir|
dw-sandbox-${LS_REPO_BASENAME}-otherclone|1|${LS_REPO_BASENAME}||dev-sandbox:${LS_REPO_BASENAME}|running|2024-03-03T00:00:00Z|/home/otheruser/${LS_REPO_BASENAME}|/home/otheruser/${LS_REPO_BASENAME}
MANIFEST

FAKE_DOCKER_MANIFEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fakebin-manifest.XXXXXX")"
cat > "${FAKE_DOCKER_MANIFEST_DIR}/docker" <<'FAKE_DOCKER_MANIFEST'
#!/bin/bash
# tests/run-tests.sh 用の偽 docker（マニフェスト駆動）。ps / container inspect / rm / volume rm に対応する。
set -u
MANIFEST="${DW_TEST_MANIFEST:?DW_TEST_MANIFEST is required}"

manifest_line() {
  awk -F'|' -v n="$1" '$1==n{print; exit}' "$MANIFEST"
}

case "${1:-}" in
  ps)
    shift
    filter=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --filter) filter="$2"; shift 2 ;;
        --format) shift 2 ;;
        *) shift ;;
      esac
    done
    case "$filter" in
      "label=dev-workflow.managed=1")
        awk -F'|' '$2=="1"{print $1}' "$MANIFEST"
        ;;
      "name=dw-sandbox-")
        awk -F'|' '$1 ~ /dw-sandbox-/{print $1}' "$MANIFEST"
        ;;
    esac
    exit 0
    ;;
  container)
    shift
    [ "${1:-}" = "inspect" ] || exit 1
    shift
    tmpl=""
    name=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) tmpl="$2"; shift 2 ;;
        *) name="$1"; shift ;;
      esac
    done
    line="$(manifest_line "$name")"
    [ -n "$line" ] || exit 1
    IFS='|' read -r f_name f_managed f_repo f_epic f_image f_status f_created f_mount f_root <<< "$line"
    case "$tmpl" in
      *'dev-workflow.root'*) printf '%s\n' "$f_root" ;;
      *'dev-workflow.repo'*) printf '%s\n' "$f_repo" ;;
      *'dev-workflow.epic'*) printf '%s\n' "$f_epic" ;;
      *'Mounts'*)            printf '%s\n' "$f_mount" ;;
      *'Config.Image'*)      printf '%s\n' "$f_image" ;;
      *'State.Status'*)      printf '%s\n' "$f_status" ;;
      *'State.Running'*)
        if [ "$f_status" = "running" ]; then printf 'true\n'; else printf 'false\n'; fi
        ;;
      *'Created'*)           printf '%s\n' "$f_created" ;;
      *)                     printf '\n' ;;
    esac
    exit 0
    ;;
  rm)
    shift
    target=""
    for a in "$@"; do
      case "$a" in
        -f) ;;
        *) target="$a" ;;
      esac
    done
    echo "$target" >> "${DW_TEST_RM_LOG:?DW_TEST_RM_LOG is required}"
    exit 0
    ;;
  volume)
    shift
    [ "${1:-}" = "rm" ] || exit 1
    shift
    for a in "$@"; do
      echo "$a" >> "${DW_TEST_VOLUME_RM_LOG:?DW_TEST_VOLUME_RM_LOG is required}"
    done
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
FAKE_DOCKER_MANIFEST
chmod +x "${FAKE_DOCKER_MANIFEST_DIR}/docker"

# --- --ls: 他リポジトリの管理コンテナも含めて一覧表示する ---
LS_OUTPUT="$(
  cd "$LS_REPO" || exit 1
  DW_TEST_MANIFEST="$DW_TEST_MANIFEST" PATH="${FAKE_DOCKER_MANIFEST_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --ls
)"

case "$LS_OUTPUT" in
  *"dw-sandbox-${LS_REPO_BASENAME}"*"dw-sandbox-otherrepo"*|*"dw-sandbox-otherrepo"*"dw-sandbox-${LS_REPO_BASENAME}"*)
    pass "--ls は自リポジトリと他リポジトリの管理コンテナを両方表示する"
    ;;
  *)
    fail "--ls は自リポジトリと他リポジトリの管理コンテナを両方表示する" "output=[${LS_OUTPUT}]"
    ;;
esac

if printf '%s\n' "$LS_OUTPUT" | grep -q "dw-sandbox-${LS_REPO_BASENAME}-legacy"; then
  pass "--ls は label なしの旧命名残骸も表示する"
else
  fail "--ls は label なしの旧命名残骸も表示する" "output=[${LS_OUTPUT}]"
fi

# --- --down --all: 削除前に対象名を列挙し、自リポジトリ分のみ削除する ---
: > "$DW_TEST_RM_LOG"
DOWN_ALL_OUTPUT="$(
  cd "$LS_REPO" || exit 1
  DW_TEST_MANIFEST="$DW_TEST_MANIFEST" DW_TEST_RM_LOG="$DW_TEST_RM_LOG" \
    PATH="${FAKE_DOCKER_MANIFEST_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --down --all
)"

if printf '%s\n' "$DOWN_ALL_OUTPUT" | grep -q "dw-sandbox-${LS_REPO_BASENAME}$"; then
  pass "--down --all は削除前に label ありの自リポジトリコンテナ名を列挙する"
else
  fail "--down --all は削除前に label ありの自リポジトリコンテナ名を列挙する" "output=[${DOWN_ALL_OUTPUT}]"
fi

if printf '%s\n' "$DOWN_ALL_OUTPUT" | grep -q "dw-sandbox-${LS_REPO_BASENAME}-legacy"; then
  pass "--down --all は削除前に label なしの旧命名残骸（マウント元一致）も列挙する"
else
  fail "--down --all は削除前に label なしの旧命名残骸（マウント元一致）も列挙する" "output=[${DOWN_ALL_OUTPUT}]"
fi

if printf '%s\n' "$DOWN_ALL_OUTPUT" | grep -q "otherrepo"; then
  fail "--down --all は他リポジトリのコンテナを列挙しない" "output=[${DOWN_ALL_OUTPUT}]"
else
  pass "--down --all は他リポジトリのコンテナを列挙しない"
fi

if printf '%s\n' "$DOWN_ALL_OUTPUT" | grep -q "otherclone"; then
  fail "--down --all は repo(basename) が同じでも root label が異なるコンテナを列挙しない（issue #29）" "output=[${DOWN_ALL_OUTPUT}]"
else
  pass "--down --all は repo(basename) が同じでも root label が異なるコンテナを列挙しない（issue #29）"
fi

RM_LOG_CONTENT="$(cat "$DW_TEST_RM_LOG")"
RM_LOG_COUNT="$(printf '%s\n' "$RM_LOG_CONTENT" | grep -c . || true)"
assert_eq "--down --all は自リポジトリ分の2件だけを docker rm する" "2" "$RM_LOG_COUNT"

if printf '%s\n' "$RM_LOG_CONTENT" | grep -q "otherrepo"; then
  fail "--down --all は他リポジトリのコンテナを削除しない" "rm_log=[${RM_LOG_CONTENT}]"
else
  pass "--down --all は他リポジトリのコンテナを削除しない"
fi

if printf '%s\n' "$RM_LOG_CONTENT" | grep -q "otherclone"; then
  fail "--down --all は repo(basename) が同じでも root label が異なるコンテナを削除しない（issue #29）" "rm_log=[${RM_LOG_CONTENT}]"
else
  pass "--down --all は repo(basename) が同じでも root label が異なるコンテナを削除しない（issue #29）"
fi

# --- --down（単体）: 削除対象名を表示し、現在の repo+epic のコンテナ1個だけを rm する（issue #30） ---
: > "$DW_TEST_RM_LOG"
DOWN_SINGLE_OUTPUT="$(
  cd "$LS_REPO" || exit 1
  DW_TEST_MANIFEST="$DW_TEST_MANIFEST" DW_TEST_RM_LOG="$DW_TEST_RM_LOG" \
    PATH="${FAKE_DOCKER_MANIFEST_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --down
)"

case "$DOWN_SINGLE_OUTPUT" in
  *"削除対象のコンテナ: dw-sandbox-${LS_REPO_BASENAME}"*)
    pass "--down（単体）は削除対象名を表示する（issue #30）" ;;
  *)
    fail "--down（単体）は削除対象名を表示する（issue #30）" "output=[${DOWN_SINGLE_OUTPUT}]" ;;
esac

DOWN_SINGLE_RM_CONTENT="$(cat "$DW_TEST_RM_LOG")"
DOWN_SINGLE_RM_COUNT="$(printf '%s\n' "$DOWN_SINGLE_RM_CONTENT" | grep -c . || true)"
assert_eq "--down（単体）は当該コンテナ1件だけを docker rm する（issue #30）" "1" "$DOWN_SINGLE_RM_COUNT"
assert_eq "--down（単体）は現在の repo+epic のコンテナ名を rm する（issue #30）" \
  "dw-sandbox-${LS_REPO_BASENAME}" "$DOWN_SINGLE_RM_CONTENT"

# ---------------------------------------------------------------------------
# ケース9: --reset-cache のガード（列挙・running 検出・--force。Task #7、Epic #3 仕様書 4.6）
#
# キャッシュ volume はリポジトリ単位で共有するため、running 判定は現在の epic だけでなく
# 同一リポジトリの管理コンテナ全体（他 epic のものも含む）を対象にする。--ls / --down --all
# と同じ偽 docker（マニフェスト駆動、State.Running / volume rm に対応済み）を再利用する。
# ---------------------------------------------------------------------------

echo "== --reset-cache（列挙・running 検出・--force。Task #7） =="

RESET_REPO="$(make_temp_repo)"
copy_sandbox_scripts "$RESET_REPO"

RESET_PLAN_OUTPUT="$(
  cd "$RESET_REPO" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
RESET_REPO_BASENAME="$(basename "$RESET_REPO")"
RESET_HOST_ROOT="$(plan_value repo_root "$RESET_PLAN_OUTPUT")"
RESET_CACHE_VOLUME_COUNT="$(printf '%s\n' "$RESET_PLAN_OUTPUT" | grep -c '^cache_volume=')"

DW_TEST_VOLUME_RM_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-volrmlog.XXXXXX")"
: > "$DW_TEST_VOLUME_RM_LOG"

run_reset_cache() {
  # run_reset_cache <manifest内容> [追加の引数...]
  local manifest_body="$1"
  shift
  printf '%s\n' "$manifest_body" > "$DW_TEST_MANIFEST"
  : > "$DW_TEST_RM_LOG"
  : > "$DW_TEST_VOLUME_RM_LOG"
  (
    cd "$RESET_REPO" || exit 1
    DW_TEST_MANIFEST="$DW_TEST_MANIFEST" DW_TEST_RM_LOG="$DW_TEST_RM_LOG" \
      DW_TEST_VOLUME_RM_LOG="$DW_TEST_VOLUME_RM_LOG" \
      PATH="${FAKE_DOCKER_MANIFEST_DIR}:${PATH}" \
      bash scripts/sandbox-exec.sh --reset-cache "$@"
  )
}

# --- 常に: 削除対象 volume がすべて列挙表示される（実行結果の成否によらない） ---
NOT_RUNNING_MANIFEST="dw-sandbox-${RESET_REPO_BASENAME}-epicA|1|${RESET_REPO_BASENAME}|epicA|dev-sandbox:${RESET_REPO_BASENAME}|exited|2024-01-01T00:00:00Z|${RESET_HOST_ROOT}"

RESET_ENUM_OUTPUT="$(run_reset_cache "$NOT_RUNNING_MANIFEST" 2>&1)"
NOT_RUNNING_EXIT=$?
RESET_ENUM_LISTED_COUNT="$(printf '%s\n' "$RESET_ENUM_OUTPUT" | grep -c '^  - dw-cache-')"
assert_eq "--reset-cache は削除対象 volume をすべて列挙表示する" "$RESET_CACHE_VOLUME_COUNT" "$RESET_ENUM_LISTED_COUNT"

# --- 同一リポジトリのコンテナが running でないときは --force なしでも実行される ---
if [ "$NOT_RUNNING_EXIT" -eq 0 ]; then
  pass "同一リポジトリのコンテナが running でないとき --force なしでも成功する"
else
  fail "同一リポジトリのコンテナが running でないとき --force なしでも成功する" "exit=${NOT_RUNNING_EXIT}"
fi

VOL_RM_COUNT="$(grep -c . "$DW_TEST_VOLUME_RM_LOG" || true)"
assert_eq "running でないとき docker volume rm が volume 数だけ呼ばれる" "$RESET_CACHE_VOLUME_COUNT" "$VOL_RM_COUNT"

# --- 同一リポジトリの管理コンテナ（他 epic）が running なら --force なしでは中断する ---
RUNNING_OWN_REPO_MANIFEST="dw-sandbox-${RESET_REPO_BASENAME}-epicA|1|${RESET_REPO_BASENAME}|epicA|dev-sandbox:${RESET_REPO_BASENAME}|running|2024-01-01T00:00:00Z|${RESET_HOST_ROOT}"

RESET_BLOCK_STDERR="$(run_reset_cache "$RUNNING_OWN_REPO_MANIFEST" 2>&1 1>/dev/null)"
RESET_BLOCK_EXIT=$?

if [ "$RESET_BLOCK_EXIT" -ne 0 ]; then
  pass "同一リポジトリの他 epic コンテナが running なら --force なしでは非0で終了する"
else
  fail "同一リポジトリの他 epic コンテナが running なら --force なしでは非0で終了する" "exit=0"
fi

VOL_RM_COUNT_BLOCKED="$(grep -c . "$DW_TEST_VOLUME_RM_LOG" || true)"
assert_eq "running のとき --force なしでは docker volume rm を呼ばない" "0" "$VOL_RM_COUNT_BLOCKED"

case "$RESET_BLOCK_STDERR" in
  *"dw-sandbox-${RESET_REPO_BASENAME}-epicA"*) pass "中断メッセージに running なコンテナ名が含まれる" ;;
  *) fail "中断メッセージに running なコンテナ名が含まれる" "stderr=[${RESET_BLOCK_STDERR}]" ;;
esac

case "$RESET_BLOCK_STDERR" in
  *"--force"*) pass "中断メッセージに --force の案内が含まれる" ;;
  *) fail "中断メッセージに --force の案内が含まれる" "stderr=[${RESET_BLOCK_STDERR}]" ;;
esac

# --- --force 指定時は running でも実行される ---
RESET_FORCE_EXIT_OUTPUT="$(run_reset_cache "$RUNNING_OWN_REPO_MANIFEST" --force 2>&1)"
RESET_FORCE_EXIT=$?

if [ "$RESET_FORCE_EXIT" -eq 0 ]; then
  pass "--force 指定時は running でも成功する"
else
  fail "--force 指定時は running でも成功する" "exit=${RESET_FORCE_EXIT} output=[${RESET_FORCE_EXIT_OUTPUT}]"
fi

VOL_RM_COUNT_FORCED="$(grep -c . "$DW_TEST_VOLUME_RM_LOG" || true)"
assert_eq "--force 指定時は docker volume rm が volume 数だけ呼ばれる" "$RESET_CACHE_VOLUME_COUNT" "$VOL_RM_COUNT_FORCED"

# --- 別リポジトリのコンテナが running でも中断しない（誤って巻き込まない） ---
OTHER_REPO_RUNNING_MANIFEST="dw-sandbox-otherrepo|1|otherrepo||dev-sandbox:otherrepo|running|2024-02-02T00:00:00Z|/home/user/otherrepo"

RESET_OTHER_REPO_OUTPUT="$(run_reset_cache "$OTHER_REPO_RUNNING_MANIFEST" 2>&1)"
RESET_OTHER_REPO_EXIT=$?

if [ "$RESET_OTHER_REPO_EXIT" -eq 0 ]; then
  pass "別リポジトリのコンテナが running でも中断しない"
else
  fail "別リポジトリのコンテナが running でも中断しない" "exit=${RESET_OTHER_REPO_EXIT} output=[${RESET_OTHER_REPO_OUTPUT}]"
fi

# --- ヘルプに作用範囲（リポジトリ全体）の記載がある ---
SANDBOX_EXEC_HEADER="$(sed -n '1,25p' "${REPO_ROOT}/scripts/sandbox-exec.sh")"
case "$SANDBOX_EXEC_HEADER" in
  *"リポジトリ全体"*) pass "ヘッダコメントに --reset-cache の作用範囲（リポジトリ全体）の記載がある" ;;
  *) fail "ヘッダコメントに --reset-cache の作用範囲（リポジトリ全体）の記載がある" "header=[${SANDBOX_EXEC_HEADER}]" ;;
esac

case "$RESET_BLOCK_STDERR" in
  *"リポジトリ全体"*) pass "中断メッセージにも作用範囲（リポジトリ全体）の記載がある" ;;
  *) fail "中断メッセージにも作用範囲（リポジトリ全体）の記載がある" "stderr=[${RESET_BLOCK_STDERR}]" ;;
esac

# ---------------------------------------------------------------------------
# ケース7: イメージタグの hash 依存性（Task #8、Epic #3 仕様書「5. 検証方針」ケース7）
#
# Dockerfile.dev の内容を変更するとタグの hash 部分（末尾8文字）が変わり、内容が同じなら
# 別リポジトリでも hash が変わらないことを確認する。
# ---------------------------------------------------------------------------

echo "== イメージタグの hash 依存性（ケース7、Task #8） =="

IMG_REPO="$(make_temp_repo)"
copy_sandbox_scripts "$IMG_REPO"

IMG_PLAN_OUTPUT="$(
  cd "$IMG_REPO" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
IMG_IMAGE="$(plan_value image "$IMG_PLAN_OUTPUT")"
IMG_DOCKERFILE="$(plan_value dockerfile "$IMG_PLAN_OUTPUT")"
IMG_BUILD_CONTEXT="$(plan_value build_context "$IMG_PLAN_OUTPUT")"
IMG_CONTAINER="$(plan_value container "$IMG_PLAN_OUTPUT")"
IMG_MOUNT_SOURCE="$(plan_value mount_source "$IMG_PLAN_OUTPUT")"
IMG_HASH_BEFORE="${IMG_IMAGE: -8}"

# --- Dockerfile.dev の内容を変更してコミットすると hash（タグの末尾8文字）が変わる ---
printf '\n# case7 marker\n' >> "${IMG_REPO}/Dockerfile.dev"
(
  cd "$IMG_REPO" || exit 1
  git add Dockerfile.dev
  git commit -q -m "case7: change Dockerfile.dev"
) >/dev/null 2>&1

IMG_PLAN_AFTER_CHANGE="$(
  cd "$IMG_REPO" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
IMG_IMAGE_AFTER_CHANGE="$(plan_value image "$IMG_PLAN_AFTER_CHANGE")"
IMG_HASH_AFTER_CHANGE="${IMG_IMAGE_AFTER_CHANGE: -8}"

if [ "$IMG_HASH_BEFORE" != "$IMG_HASH_AFTER_CHANGE" ]; then
  pass "ケース7: Dockerfile.dev の内容変更でタグの hash が変わる"
else
  fail "ケース7: Dockerfile.dev の内容変更でタグの hash が変わる" "hash が変わりませんでした: ${IMG_HASH_BEFORE}"
fi

# 以降の自動ビルド系テストは、この時点（Dockerfile.dev 変更後）の IMG_REPO を使い回す。
# resolve-sandbox.sh の出力は Dockerfile.dev の内容に追随するため、変更後の値で
# 上書きしておかないと docker build の実引数と食い違う。
IMG_IMAGE="$(plan_value image "$IMG_PLAN_AFTER_CHANGE")"
IMG_DOCKERFILE="$(plan_value dockerfile "$IMG_PLAN_AFTER_CHANGE")"
IMG_BUILD_CONTEXT="$(plan_value build_context "$IMG_PLAN_AFTER_CHANGE")"
IMG_CONTAINER="$(plan_value container "$IMG_PLAN_AFTER_CHANGE")"
IMG_MOUNT_SOURCE="$(plan_value mount_source "$IMG_PLAN_AFTER_CHANGE")"
IMG_WORKDIR="$(plan_value workdir "$IMG_PLAN_AFTER_CHANGE")"
IMG_REPO_NAME="$(plan_value repo "$IMG_PLAN_AFTER_CHANGE")"
IMG_HOST_ROOT="$(plan_value repo_root "$IMG_PLAN_AFTER_CHANGE")"

# --- 内容が同じなら別リポジトリ（worktree 相当）でも hash が変わらない ---
IMG_REPO2="$(make_temp_repo)"
copy_sandbox_scripts "$IMG_REPO2"

IMG_PLAN2_OUTPUT="$(
  cd "$IMG_REPO2" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
IMG_HASH2="$(plan_value image "$IMG_PLAN2_OUTPUT")"
IMG_HASH2="${IMG_HASH2: -8}"

assert_eq "ケース7: 内容が同じなら別リポジトリでも hash が変わらない" "$IMG_HASH_BEFORE" "$IMG_HASH2"

# ---------------------------------------------------------------------------
# 自動ビルド・--rebuild・イメージID差分による再作成（Task #8、Epic #3 仕様書 4.7 / 4.3 の1）
#
# 偽 docker は状態をファイルに保持し、docker build / docker rm / docker run の呼び出しを
# 実際の docker を起動せずに検証する。container の存在状態は docker rm / docker run に
# 応じて更新するため、削除後に作り直されることまで検証できる。
# ---------------------------------------------------------------------------

echo "== 自動ビルド・--rebuild・イメージID差分による再作成（Task #8） =="

FAKE_DOCKER_IMAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fakebin-image.XXXXXX")"
cat > "${FAKE_DOCKER_IMAGE_DIR}/docker" <<'FAKE_DOCKER_IMAGE'
#!/bin/bash
# tests/run-tests.sh 用の偽 docker（イメージ解決・自動ビルド・コンテナ再作成の検証専用）。
# 実際の docker には一切触れない。呼び出し引数は DW_IMG_LOG にすべて記録する。
set -u

IMG_LOG="${DW_IMG_LOG:?DW_IMG_LOG is required}"
STATE_FILE="${DW_IMG_CONTAINER_STATE:?DW_IMG_CONTAINER_STATE is required}"          # 1=存在 0=不在
RUNNING_FILE="${DW_IMG_CONTAINER_RUNNING_STATE:?DW_IMG_CONTAINER_RUNNING_STATE is required}" # true/false
RM_LOG="${DW_IMG_RM_LOG:?DW_IMG_RM_LOG is required}"
RUN_LOG="${DW_IMG_RUN_LOG:?DW_IMG_RUN_LOG is required}"

echo "$*" >> "$IMG_LOG"

case "${1:-}" in
  image)
    shift
    [ "${1:-}" = "inspect" ] || exit 1
    shift
    tmpl=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) tmpl="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    [ "${DW_IMG_IMAGE_EXISTS:-0}" = "1" ] || exit 1
    [ -n "$tmpl" ] && printf '%s\n' "${DW_IMG_IMAGE_ID:-sha256:default-image-id}"
    exit 0
    ;;
  build)
    exit "${DW_IMG_BUILD_EXIT:-0}"
    ;;
  container)
    shift
    [ "${1:-}" = "inspect" ] || exit 1
    shift
    tmpl=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) tmpl="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    [ "$(cat "$STATE_FILE" 2>/dev/null)" = "1" ] || exit 1
    case "$tmpl" in
      *'Mounts'*)        printf '%s\n' "${DW_IMG_CONTAINER_MOUNT:-}" ;;
      *'.Image'*)        printf '%s\n' "${DW_IMG_CONTAINER_IMAGE_ID:-}" ;;
      *'State.Running'*) cat "$RUNNING_FILE" 2>/dev/null || printf 'false\n' ;;
      '') : ;;
      *) printf '\n' ;;
    esac
    exit 0
    ;;
  run)
    echo "$*" >> "$RUN_LOG"
    printf '1' > "$STATE_FILE"
    printf 'true\n' > "$RUNNING_FILE"
    exit 0
    ;;
  start)
    printf 'true\n' > "$RUNNING_FILE"
    exit 0
    ;;
  rm)
    shift
    target=""
    for a in "$@"; do
      case "$a" in
        -f) ;;
        *)  target="$a" ;;
      esac
    done
    echo "$target" >> "$RM_LOG"
    printf '0' > "$STATE_FILE"
    exit 0
    ;;
  exec)
    shift
    cmd=""
    workdir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -w) workdir="$2"; shift 2 ;;
        sh) shift ;;
        -c) cmd="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    printf '%s\n' "$workdir" >> "${DW_IMG_EXEC_LOG:?DW_IMG_EXEC_LOG is required}"
    sh -c "$cmd"
    exit $?
    ;;
  *)
    exit 1
    ;;
esac
FAKE_DOCKER_IMAGE
chmod +x "${FAKE_DOCKER_IMAGE_DIR}/docker"

IMG_TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-imglog.XXXXXX")"
IMG_TEST_RM_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgrmlog.XXXXXX")"
IMG_TEST_RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgrunlog.XXXXXX")"
IMG_TEST_EXEC_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgexeclog.XXXXXX")"
IMG_TEST_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgstate.XXXXXX")"
IMG_TEST_RUNNING_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgrunning.XXXXXX")"

run_img_case() {
  # run_img_case <container_exists 0/1> <container_running true/false> <container_image_id>
  #              <container_mount> <image_exists 0/1> <image_id> [追加の sandbox-exec.sh 引数...]
  #
  # DEV_WORKFLOW_STAMP_HOME は呼び出しごとに新規の空ディレクトリにする。スタンプ機構
  # （issue #145）はコンテナ名・イメージID・マウント元が一致すればフル検証を省略するため、
  # このヘルパーで固定の値を使い回すと、ケースをまたいでスタンプが再利用されてしまい
  # （実際に発生した：後続ケースが期待するフル検証がスキップされ、削除/作り直しの
  # アサーションが失敗した）、かつ既定値のままだと実ホストの $HOME を汚染する。
  # このヘルパーが検証する対象はあくまで「フル検証」なので、常にスタンプ不在から始める。
  local container_exists="$1" container_running="$2" container_image_id="$3" container_mount="$4"
  local image_exists="$5" image_id="$6"
  shift 6

  : > "$IMG_TEST_LOG"
  : > "$IMG_TEST_RM_LOG"
  : > "$IMG_TEST_RUN_LOG"
  : > "$IMG_TEST_EXEC_LOG"
  printf '%s' "$container_exists" > "$IMG_TEST_STATE_FILE"
  printf '%s\n' "$container_running" > "$IMG_TEST_RUNNING_FILE"

  (
    cd "$IMG_REPO" || exit 1
    DEV_WORKFLOW_STAMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-imgstamp.XXXXXX")" \
      DW_IMG_LOG="$IMG_TEST_LOG" \
      DW_IMG_RM_LOG="$IMG_TEST_RM_LOG" \
      DW_IMG_RUN_LOG="$IMG_TEST_RUN_LOG" \
      DW_IMG_EXEC_LOG="$IMG_TEST_EXEC_LOG" \
      DW_IMG_CONTAINER_STATE="$IMG_TEST_STATE_FILE" \
      DW_IMG_CONTAINER_RUNNING_STATE="$IMG_TEST_RUNNING_FILE" \
      DW_IMG_CONTAINER_IMAGE_ID="$container_image_id" \
      DW_IMG_CONTAINER_MOUNT="$container_mount" \
      DW_IMG_IMAGE_EXISTS="$image_exists" \
      DW_IMG_IMAGE_ID="$image_id" \
      PATH="${FAKE_DOCKER_IMAGE_DIR}:${PATH}" \
      bash scripts/sandbox-exec.sh "$@"
  )
}

# --- イメージが存在しない場合、docker build が正しい引数で呼ばれる ---
IMG_A_EXIT=0
run_img_case 0 false "" "" 0 "" 'true' >/dev/null 2>&1 || IMG_A_EXIT=$?
assert_exit_code "イメージ未存在時: 実行全体が成功する" 0 "$IMG_A_EXIT"

IMG_A_BUILD_LINE="$(grep '^build ' "$IMG_TEST_LOG" | head -n1)"
assert_eq "イメージ未存在時: docker build が正しい引数で呼ばれる" \
  "build -f ${IMG_DOCKERFILE} -t ${IMG_IMAGE} ${IMG_BUILD_CONTEXT}" "$IMG_A_BUILD_LINE"

# --- コンテナが無い場合の docker run に label / マウント / workdir が正しく渡る（issue #30） ---
# これまで DW_IMG_RUN_LOG は記録するだけで一度もアサートしていなかった
# （label ベースの後片付け全体がこの配線に依存しているにもかかわらず）。
IMG_A_RUN_LINE="$(head -n1 "$IMG_TEST_RUN_LOG")"

case "$IMG_A_RUN_LINE" in
  *"--label dev-workflow.managed=1"*)
    pass "イメージ未存在時: docker run に --label dev-workflow.managed=1 が渡る（issue #30）" ;;
  *)
    fail "イメージ未存在時: docker run に --label dev-workflow.managed=1 が渡る（issue #30）" "run_line=[${IMG_A_RUN_LINE}]" ;;
esac

case "$IMG_A_RUN_LINE" in
  *"--label dev-workflow.repo=${IMG_REPO_NAME}"*)
    pass "イメージ未存在時: docker run に --label dev-workflow.repo=<repo> が渡る（issue #30）" ;;
  *)
    fail "イメージ未存在時: docker run に --label dev-workflow.repo=<repo> が渡る（issue #30）" "run_line=[${IMG_A_RUN_LINE}]" ;;
esac

case "$IMG_A_RUN_LINE" in
  *"--label dev-workflow.epic="*)
    pass "イメージ未存在時: docker run に --label dev-workflow.epic=<epic> が渡る（issue #30）" ;;
  *)
    fail "イメージ未存在時: docker run に --label dev-workflow.epic=<epic> が渡る（issue #30）" "run_line=[${IMG_A_RUN_LINE}]" ;;
esac

case "$IMG_A_RUN_LINE" in
  *"--label dev-workflow.root=${IMG_HOST_ROOT}"*)
    pass "イメージ未存在時: docker run に --label dev-workflow.root=<host_root> が渡る（issue #30）" ;;
  *)
    fail "イメージ未存在時: docker run に --label dev-workflow.root=<host_root> が渡る（issue #30）" "run_line=[${IMG_A_RUN_LINE}]" ;;
esac

case "$IMG_A_RUN_LINE" in
  *"-v ${IMG_MOUNT_SOURCE}:/workspace"*)
    pass "イメージ未存在時: docker run に -v <mount_source>:/workspace が渡る（issue #30）" ;;
  *)
    fail "イメージ未存在時: docker run に -v <mount_source>:/workspace が渡る（issue #30）" "run_line=[${IMG_A_RUN_LINE}]" ;;
esac

IMG_A_EXEC_WORKDIR="$(head -n1 "$IMG_TEST_EXEC_LOG")"
assert_eq "イメージ未存在時: docker exec に解決済み workdir が -w で渡る（issue #30）" \
  "$IMG_WORKDIR" "$IMG_A_EXEC_WORKDIR"

# --- イメージが存在する場合はビルドしない ---
IMG_B_EXIT=0
run_img_case 0 false "" "" 1 "sha256:existing" 'true' >/dev/null 2>&1 || IMG_B_EXIT=$?
assert_exit_code "イメージ存在時: 実行全体が成功する" 0 "$IMG_B_EXIT"

IMG_B_BUILD_COUNT="$(grep -c '^build ' "$IMG_TEST_LOG" || true)"
assert_eq "イメージ存在時: docker build を呼ばない" "0" "$IMG_B_BUILD_COUNT"

# --- --rebuild 指定時は存在してもビルドする ---
IMG_C_EXIT=0
run_img_case 0 false "" "" 1 "sha256:existing" --rebuild 'true' >/dev/null 2>&1 || IMG_C_EXIT=$?
assert_exit_code "--rebuild 指定時: 実行全体が成功する" 0 "$IMG_C_EXIT"

IMG_C_BUILD_COUNT="$(grep -c '^build ' "$IMG_TEST_LOG" || true)"
assert_eq "--rebuild 指定時: イメージが存在してもビルドする" "1" "$IMG_C_BUILD_COUNT"

# --- DEV_WORKFLOW_DOCKER_IMAGE 指定でイメージが無い場合はビルドせずエラーで停止する ---
: > "$IMG_TEST_LOG"
: > "$IMG_TEST_RM_LOG"
: > "$IMG_TEST_RUN_LOG"
printf '0' > "$IMG_TEST_STATE_FILE"
printf 'false\n' > "$IMG_TEST_RUNNING_FILE"

EXPLICIT_IMAGE_STDERR="$(
  cd "$IMG_REPO" || exit 1
  DEV_WORKFLOW_DOCKER_IMAGE="external/image:notfound" \
    DW_IMG_LOG="$IMG_TEST_LOG" \
    DW_IMG_RM_LOG="$IMG_TEST_RM_LOG" \
    DW_IMG_RUN_LOG="$IMG_TEST_RUN_LOG" \
    DW_IMG_CONTAINER_STATE="$IMG_TEST_STATE_FILE" \
    DW_IMG_CONTAINER_RUNNING_STATE="$IMG_TEST_RUNNING_FILE" \
    DW_IMG_IMAGE_EXISTS=0 \
    PATH="${FAKE_DOCKER_IMAGE_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh 'true' 2>&1 1>/dev/null
)"
EXPLICIT_IMAGE_EXIT=$?

if [ "$EXPLICIT_IMAGE_EXIT" -ne 0 ]; then
  pass "DEV_WORKFLOW_DOCKER_IMAGE 指定でイメージが無い場合は非0で終了する"
else
  fail "DEV_WORKFLOW_DOCKER_IMAGE 指定でイメージが無い場合は非0で終了する" "exit=0"
fi

EXPLICIT_IMAGE_BUILD_COUNT="$(grep -c '^build ' "$IMG_TEST_LOG" || true)"
assert_eq "DEV_WORKFLOW_DOCKER_IMAGE 指定時: イメージが無くてもビルドしない" "0" "$EXPLICIT_IMAGE_BUILD_COUNT"

case "$EXPLICIT_IMAGE_STDERR" in
  *"DEV_WORKFLOW_DOCKER_IMAGE"*"external/image:notfound"*)
    pass "DEV_WORKFLOW_DOCKER_IMAGE 指定時のエラーに取得方法の案内が含まれる" ;;
  *)
    fail "DEV_WORKFLOW_DOCKER_IMAGE 指定時のエラーに取得方法の案内が含まれる" "stderr=[${EXPLICIT_IMAGE_STDERR}]" ;;
esac

# --- 既存コンテナのイメージIDが異なれば削除して作り直す（仕様書 4.3 の1） ---
IMG_E_EXIT=0
run_img_case 1 true "sha256:old" "$IMG_MOUNT_SOURCE" 1 "sha256:new" 'true' >/dev/null 2>&1 || IMG_E_EXIT=$?
assert_exit_code "イメージID差分時: 実行全体が成功する" 0 "$IMG_E_EXIT"

IMG_E_RM_COUNT="$(grep -c . "$IMG_TEST_RM_LOG" || true)"
assert_eq "イメージID差分時: 既存コンテナが削除される" "1" "$IMG_E_RM_COUNT"

IMG_E_RUN_COUNT="$(grep -c '^run ' "$IMG_TEST_LOG" || true)"
assert_eq "イメージID差分時: コンテナが作り直される" "1" "$IMG_E_RUN_COUNT"

# --- 既存コンテナのイメージIDが同じなら作り直さない ---
IMG_F_EXIT=0
run_img_case 1 true "sha256:same" "$IMG_MOUNT_SOURCE" 1 "sha256:same" 'true' >/dev/null 2>&1 || IMG_F_EXIT=$?
assert_exit_code "イメージID同一時: 実行全体が成功する" 0 "$IMG_F_EXIT"

IMG_F_RM_COUNT="$(grep -c . "$IMG_TEST_RM_LOG" || true)"
assert_eq "イメージID同一時: 既存コンテナを削除しない" "0" "$IMG_F_RM_COUNT"

IMG_F_RUN_COUNT="$(grep -c '^run ' "$IMG_TEST_LOG" || true)"
assert_eq "イメージID同一時: コンテナを作り直さない" "0" "$IMG_F_RUN_COUNT"

# ---------------------------------------------------------------------------
# マウント元不一致による再作成の検証（issue #30）
#
# これまでの既存コンテナありケース（E・F）はどちらも container_mount に
# $IMG_MOUNT_SOURCE をそのまま渡しており、マウント元が期待値と異なる場合に
# 再作成される分岐（仕様書 4.3 の2。この Epic の「静かに間違ったツリーを
# 実行しない」ための本体）を検証するケースが存在しなかった。
#
# docker_desktop_equivalent は、実際の IMG_MOUNT_SOURCE の形式（Windows の
# pwd -W 形式か、Linux 等の素のパスか）に応じて「同一ツリーを指す別表現」を
# 作る。ドライブレター形式なら Docker Desktop の変換済みパス
# （/run/desktop/mnt/host/<drive>/...）へ、そうでなければバックスラッシュ区切りへ
# 変換する。どちらの実行環境でも normalize_mount_source が同一表現へ正規化する
# ことを、実際の sandbox-exec.sh（docker はモック）経由で確認するため。
# ---------------------------------------------------------------------------

docker_desktop_equivalent() {
  # docker_desktop_equivalent <mount_source>
  local src="$1" drive rest
  case "$src" in
    [A-Za-z]:/*|[A-Za-z]:)
      drive="${src%%:*}"
      rest="${src#*:}"
      drive="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
      printf '/run/desktop/mnt/host/%s%s' "$drive" "$rest"
      ;;
    *)
      printf '%s' "${src//\//\\}"
      ;;
  esac
}

IMG_MOUNT_EQUIVALENT="$(docker_desktop_equivalent "$IMG_MOUNT_SOURCE")"
IMG_G_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-imgg-stderr.XXXXXX")"

# --- (a) container_mount が MOUNT_SOURCE と異なる場合は削除して作り直す ---
IMG_G_EXIT=0
run_img_case 1 true "sha256:same" "${IMG_MOUNT_SOURCE}/different-tree" 1 "sha256:same" 'true' \
  2>"$IMG_G_STDERR_FILE" >/dev/null || IMG_G_EXIT=$?
assert_exit_code "マウント元不一致時: 実行全体が成功する（issue #30）" 0 "$IMG_G_EXIT"

IMG_G_RM_COUNT="$(grep -c . "$IMG_TEST_RM_LOG" || true)"
assert_eq "マウント元不一致時: 既存コンテナが削除される（issue #30）" "1" "$IMG_G_RM_COUNT"

IMG_G_RUN_COUNT="$(grep -c '^run ' "$IMG_TEST_LOG" || true)"
assert_eq "マウント元不一致時: コンテナが作り直される（issue #30）" "1" "$IMG_G_RUN_COUNT"

IMG_G_STDERR="$(cat "$IMG_G_STDERR_FILE")"
case "$IMG_G_STDERR" in
  *"別ツリー実行の防止"*) pass "マウント元不一致時: 別ツリー実行の防止の警告が出る（issue #30）" ;;
  *) fail "マウント元不一致時: 別ツリー実行の防止の警告が出る（issue #30）" "stderr=[${IMG_G_STDERR}]" ;;
esac

# --- (b) Docker Desktop 形式（等）でも同一ツリーと判定され再作成されない ---
IMG_H_EXIT=0
run_img_case 1 true "sha256:same" "$IMG_MOUNT_EQUIVALENT" 1 "sha256:same" 'true' >/dev/null 2>&1 || IMG_H_EXIT=$?
assert_exit_code "マウント元が別表現でも同一ツリー時: 実行全体が成功する（issue #30）" 0 "$IMG_H_EXIT"

IMG_H_RM_COUNT="$(grep -c . "$IMG_TEST_RM_LOG" || true)"
assert_eq "マウント元が別表現（Docker Desktop 形式等）でも同一ツリーなら削除しない（issue #25 / #30）" "0" "$IMG_H_RM_COUNT"

IMG_H_RUN_COUNT="$(grep -c '^run ' "$IMG_TEST_LOG" || true)"
assert_eq "マウント元が別表現（Docker Desktop 形式等）でも同一ツリーなら作り直さない（issue #25 / #30）" "0" "$IMG_H_RUN_COUNT"

# ---------------------------------------------------------------------------
# 検証結果のスタンプ（fast path。issue #145、docs/adr/0002-sandbox-overhead-reduction.md 決定1）
#
# run_img_case とは異なり、複数回の呼び出しにまたがって同一の DEV_WORKFLOW_STAMP_HOME を
# 使い回すことで「1回目のフル検証で書いたスタンプを2回目が読む」という時系列を検証する。
# ---------------------------------------------------------------------------

echo "== 検証結果のスタンプ（fast path・issue #145） =="

STAMP_TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-stamphome.XXXXXX")"

run_img_case_stamped() {
  # run_img_case_stamped <stamp_home> <container_exists> <container_running> <container_image_id>
  #                       <container_mount> <image_exists> <image_id> [追加の sandbox-exec.sh 引数...]
  local stamp_home="$1" container_exists="$2" container_running="$3" container_image_id="$4"
  local container_mount="$5" image_exists="$6" image_id="$7"
  shift 7

  : > "$IMG_TEST_LOG"
  : > "$IMG_TEST_RM_LOG"
  : > "$IMG_TEST_RUN_LOG"
  : > "$IMG_TEST_EXEC_LOG"
  printf '%s' "$container_exists" > "$IMG_TEST_STATE_FILE"
  printf '%s\n' "$container_running" > "$IMG_TEST_RUNNING_FILE"

  (
    cd "$IMG_REPO" || exit 1
    DEV_WORKFLOW_STAMP_HOME="$stamp_home" \
      DW_IMG_LOG="$IMG_TEST_LOG" \
      DW_IMG_RM_LOG="$IMG_TEST_RM_LOG" \
      DW_IMG_RUN_LOG="$IMG_TEST_RUN_LOG" \
      DW_IMG_EXEC_LOG="$IMG_TEST_EXEC_LOG" \
      DW_IMG_CONTAINER_STATE="$IMG_TEST_STATE_FILE" \
      DW_IMG_CONTAINER_RUNNING_STATE="$IMG_TEST_RUNNING_FILE" \
      DW_IMG_CONTAINER_IMAGE_ID="$container_image_id" \
      DW_IMG_CONTAINER_MOUNT="$container_mount" \
      DW_IMG_IMAGE_EXISTS="$image_exists" \
      DW_IMG_IMAGE_ID="$image_id" \
      PATH="${FAKE_DOCKER_IMAGE_DIR}:${PATH}" \
      bash scripts/sandbox-exec.sh "$@"
  )
}

stamp_call_count() { wc -l < "$IMG_TEST_LOG" | tr -d ' '; }

# --- 1回目: スタンプが無いのでフル検証する ---
STAMP1_EXIT=0
run_img_case_stamped "$STAMP_TEST_HOME" 1 true "sha256:same" "$IMG_MOUNT_SOURCE" 1 "sha256:same" 'true' \
  >/dev/null 2>&1 || STAMP1_EXIT=$?
assert_exit_code "スタンプ: 1回目（スタンプ無し・フル検証）は成功する" 0 "$STAMP1_EXIT"
STAMP1_CALLS="$(stamp_call_count)"

# --- 2回目: 直前と同じ状態で再実行すると fast path になり、docker CLI 呼び出しが減る ---
STAMP2_EXIT=0
run_img_case_stamped "$STAMP_TEST_HOME" 1 true "sha256:same" "$IMG_MOUNT_SOURCE" 1 "sha256:same" 'true' \
  >/dev/null 2>&1 || STAMP2_EXIT=$?
assert_exit_code "スタンプ: 2回目（fast path）も成功する" 0 "$STAMP2_EXIT"
STAMP2_CALLS="$(stamp_call_count)"

if [ "$STAMP2_CALLS" -lt "$STAMP1_CALLS" ]; then
  pass "スタンプ: fast path は1回目より docker CLI 呼び出しが少ない（1回目=${STAMP1_CALLS}件 → 2回目=${STAMP2_CALLS}件）"
else
  fail "スタンプ: fast path は1回目より docker CLI 呼び出しが少ない" "1回目=${STAMP1_CALLS}件 2回目=${STAMP2_CALLS}件"
fi

assert_eq "スタンプ: fast path では既存コンテナを削除しない" "0" "$(grep -c . "$IMG_TEST_RM_LOG" || true)"
assert_eq "スタンプ: fast path ではコンテナを作り直さない" "0" "$(grep -c '^run ' "$IMG_TEST_LOG" || true)"
assert_eq "スタンプ: fast path でも docker exec は実行される" "1" "$(grep -c . "$IMG_TEST_EXEC_LOG" || true)"

# --- 3回目: イメージIDが変わっている場合はスタンプを無視してフル検証に戻る（バージョンスキュー解消） ---
STAMP3_EXIT=0
run_img_case_stamped "$STAMP_TEST_HOME" 1 true "sha256:same" "$IMG_MOUNT_SOURCE" 1 "sha256:different" 'true' \
  >/dev/null 2>&1 || STAMP3_EXIT=$?
assert_exit_code "スタンプ: イメージID変更時も成功する" 0 "$STAMP3_EXIT"
STAMP3_CALLS="$(stamp_call_count)"

if [ "$STAMP3_CALLS" -ge "$STAMP1_CALLS" ]; then
  pass "スタンプ: イメージID変更時はフル検証に戻る（呼び出し数=${STAMP3_CALLS}件、1回目=${STAMP1_CALLS}件）"
else
  fail "スタンプ: イメージID変更時はフル検証に戻る" "呼び出し数=${STAMP3_CALLS}件（1回目=${STAMP1_CALLS}件）"
fi
assert_eq "スタンプ: イメージID変更時は既存コンテナを削除して作り直す" "1" "$(grep -c . "$IMG_TEST_RM_LOG" || true)"

# --- マウント元不一致: スタンプへ直接、現在の状態と異なるマウント元を書き込み、
#     フル検証に戻ることを確認する（実際の呼び出し元の違いによる不一致を模擬） ---
STAMP_CONTAINER_SLUG="$(printf '%s' "$IMG_CONTAINER" | tr -c 'A-Za-z0-9_.-' '-')"
STAMP_BOGUS_FILE="${STAMP_TEST_HOME}/${STAMP_CONTAINER_SLUG}.stamp"
{
  printf 'CONTAINER=%s\n'    "$IMG_CONTAINER"
  printf 'IMAGE_ID=%s\n'     "sha256:same"
  printf 'MOUNT_SOURCE=%s\n' "/some/other/tree"
} > "$STAMP_BOGUS_FILE"

STAMP4_EXIT=0
run_img_case_stamped "$STAMP_TEST_HOME" 1 true "sha256:same" "$IMG_MOUNT_SOURCE" 1 "sha256:same" 'true' \
  >/dev/null 2>&1 || STAMP4_EXIT=$?
assert_exit_code "スタンプ: マウント元不一致時も成功する" 0 "$STAMP4_EXIT"
STAMP4_CALLS="$(stamp_call_count)"

if [ "$STAMP4_CALLS" -ge "$STAMP1_CALLS" ]; then
  pass "スタンプ: マウント元不一致時はフル検証に戻る（呼び出し数=${STAMP4_CALLS}件）"
else
  fail "スタンプ: マウント元不一致時はフル検証に戻る" "呼び出し数=${STAMP4_CALLS}件（1回目=${STAMP1_CALLS}件）"
fi

# --- --rebuild: スタンプが（直前の呼び出しで）温まっていても必ずフル検証・再ビルドする ---
STAMP5_EXIT=0
run_img_case_stamped "$STAMP_TEST_HOME" 1 true "sha256:same" "$IMG_MOUNT_SOURCE" 1 "sha256:same" --rebuild 'true' \
  >/dev/null 2>&1 || STAMP5_EXIT=$?
assert_exit_code "スタンプ: --rebuild 指定時も成功する" 0 "$STAMP5_EXIT"
assert_eq "スタンプ: --rebuild 指定時はスタンプがあってもビルドする" "1" "$(grep -c '^build ' "$IMG_TEST_LOG" || true)"

# --- スタンプ不在（新規の空ディレクトリ）では必ずフル検証になる ---
STAMP_EMPTY_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-stampempty.XXXXXX")"
STAMP6_EXIT=0
run_img_case_stamped "$STAMP_EMPTY_HOME" 1 true "sha256:same" "$IMG_MOUNT_SOURCE" 1 "sha256:same" 'true' \
  >/dev/null 2>&1 || STAMP6_EXIT=$?
assert_exit_code "スタンプ: スタンプ不在（新規ディレクトリ）でも成功する" 0 "$STAMP6_EXIT"
STAMP6_CALLS="$(stamp_call_count)"
if [ "$STAMP6_CALLS" -ge "$STAMP1_CALLS" ]; then
  pass "スタンプ: スタンプ不在時はフル検証になる（呼び出し数=${STAMP6_CALLS}件）"
else
  fail "スタンプ: スタンプ不在時はフル検証になる" "呼び出し数=${STAMP6_CALLS}件（1回目=${STAMP1_CALLS}件）"
fi

# --- --print-plan はスタンプの有無に関わらず docker に一切触れない ---
STAMP_PLAN_MARKER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-stampplanmarker.XXXXXX")"
STAMP_PLAN_MARKER="${STAMP_PLAN_MARKER_DIR}/docker-called-marker"
cat > "${STAMP_PLAN_MARKER_DIR}/docker" <<FAKE_DOCKER_PLAN_STAMP
#!/bin/bash
echo "\$@" >> "${STAMP_PLAN_MARKER}"
exit 1
FAKE_DOCKER_PLAN_STAMP
chmod +x "${STAMP_PLAN_MARKER_DIR}/docker"

(
  cd "$IMG_REPO" || exit 1
  DEV_WORKFLOW_STAMP_HOME="$STAMP_TEST_HOME" \
    PATH="${STAMP_PLAN_MARKER_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --print-plan
) >/dev/null 2>&1

if [ -f "$STAMP_PLAN_MARKER" ]; then
  fail "スタンプ: --print-plan はスタンプ有効時も docker を起動しない" "docker が呼ばれました: $(cat "$STAMP_PLAN_MARKER")"
else
  pass "スタンプ: --print-plan はスタンプ有効時も docker を起動しない"
fi

# ---------------------------------------------------------------------------
# レーンスコープ・キャッシュ（issue #145、docs/adr/0002-sandbox-overhead-reduction.md 決定2）
#
# --print-plan のドライラン出力（lane_scope / lane_cache_env）と、dockerfile モードでの
# 実行時の -e 付与・mkdir 実行を検証する。
# ---------------------------------------------------------------------------

echo "== レーンスコープ・キャッシュ（issue #145） =="

assert_eq "lane_scope: リポジトリルートは shared" "shared" "$(plan_value lane_scope "$CASE1_OUTPUT")"
assert_eq "lane_scope: epic worktree も shared" "shared" "$(plan_value lane_scope "$CASE2_OUTPUT")"
assert_eq "lane_scope: agent worktree（.claude/worktrees/agent-x）は agent-x" "agent-x" "$(plan_value lane_scope "$CASE3_OUTPUT")"

LANE_ENV_UNDECLARED_COUNT="$(printf '%s\n' "$CASE3_OUTPUT" | grep -c '^lane_cache_env=' || true)"
assert_eq "lane_cache_env: 未宣言時は0行（既定は現行と同一の挙動）" "0" "$LANE_ENV_UNDECLARED_COUNT"

LANE_ENV_OUTPUT="$(
  cd "$AGENT_WORKTREE_DIR" || exit 1
  DEV_WORKFLOW_LANE_SCOPED_CACHE_ENV='CARGO_HOME=/root/.cargo/registry' \
    PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan
)"
assert_eq "lane_cache_env: 宣言時に <ENV>=<path>/lanes/<scope> が出る" \
  "CARGO_HOME=/root/.cargo/registry/lanes/agent-x" "$(plan_value lane_cache_env "$LANE_ENV_OUTPUT")"

# --- dockerfile モード実行時: agent worktree では -e と mkdir が実際に効く ---
DOCKER_LANE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-dockerlanecache.XXXXXX")"
DOCKER_LANE_BASE="${DOCKER_LANE_TMP}/cargo-registry"

: > "$IMG_TEST_LOG"
: > "$IMG_TEST_RM_LOG"
: > "$IMG_TEST_RUN_LOG"
: > "$IMG_TEST_EXEC_LOG"
printf '0' > "$IMG_TEST_STATE_FILE"
printf 'false\n' > "$IMG_TEST_RUNNING_FILE"

DOCKER_LANE_EXIT=0
(
  cd "$AGENT_WORKTREE_DIR" || exit 1
  DEV_WORKFLOW_STAMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-dockerlanestamp.XXXXXX")" \
    DEV_WORKFLOW_LANE_SCOPED_CACHE_ENV="CARGO_HOME=${DOCKER_LANE_BASE}" \
    DW_IMG_LOG="$IMG_TEST_LOG" \
    DW_IMG_RM_LOG="$IMG_TEST_RM_LOG" \
    DW_IMG_RUN_LOG="$IMG_TEST_RUN_LOG" \
    DW_IMG_EXEC_LOG="$IMG_TEST_EXEC_LOG" \
    DW_IMG_CONTAINER_STATE="$IMG_TEST_STATE_FILE" \
    DW_IMG_CONTAINER_RUNNING_STATE="$IMG_TEST_RUNNING_FILE" \
    DW_IMG_IMAGE_EXISTS=0 \
    PATH="${FAKE_DOCKER_IMAGE_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh 'true'
) >/dev/null 2>&1 || DOCKER_LANE_EXIT=$?
assert_exit_code "dockerfile: レーンスコープ・キャッシュ宣言時も成功する（agent worktree）" 0 "$DOCKER_LANE_EXIT"

DOCKER_LANE_LAST_LINE="$(tail -n1 "$IMG_TEST_LOG")"
case "$DOCKER_LANE_LAST_LINE" in
  *"-e CARGO_HOME=${DOCKER_LANE_BASE}/lanes/agent-x"*)
    pass "dockerfile: agent worktree では docker exec に -e <ENV>=<path>/lanes/<scope> が渡る" ;;
  *)
    fail "dockerfile: agent worktree では docker exec に -e <ENV>=<path>/lanes/<scope> が渡る" \
      "last_line=[${DOCKER_LANE_LAST_LINE}]" ;;
esac

if [ -d "${DOCKER_LANE_BASE}/lanes/agent-x" ]; then
  pass "dockerfile: 実行前にレーン別キャッシュディレクトリが作られる"
else
  fail "dockerfile: 実行前にレーン別キャッシュディレクトリが作られる" "作られていません: ${DOCKER_LANE_BASE}/lanes/agent-x"
fi

# ---------------------------------------------------------------------------
# ケース10: compose_conflict_warnings（Docker 非依存の衝突検出関数、Task #9）
#
# container_name / 固定ホストポートの検出を、docker を一切起動せずに純粋関数として
# 直接検証する（Epic #3 仕様書 4.8）。
# ---------------------------------------------------------------------------

echo "== compose_conflict_warnings（衝突検出・Docker 非依存） =="

# shellcheck source=../scripts/lib/compose-conflicts.sh
. "${REPO_ROOT}/scripts/lib/compose-conflicts.sh"

COMPOSE_CONFLICT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-compose-conflict.XXXXXX")"

COMPOSE_FILE_CONTAINER_NAME="${COMPOSE_CONFLICT_DIR}/container-name.yml"
cat > "$COMPOSE_FILE_CONTAINER_NAME" <<'YAML'
services:
  app:
    build: .
    container_name: myapp
    volumes:
      - .:/workspace
YAML

COMPOSE_FILE_FIXED_PORT="${COMPOSE_CONFLICT_DIR}/fixed-port.yml"
cat > "$COMPOSE_FILE_FIXED_PORT" <<'YAML'
services:
  app:
    build: .
    ports:
      - "8080:80"
    volumes:
      - .:/workspace
YAML

COMPOSE_FILE_NO_CONFLICT="${COMPOSE_CONFLICT_DIR}/no-conflict.yml"
cat > "$COMPOSE_FILE_NO_CONFLICT" <<'YAML'
services:
  app:
    build: .
    ports:
      - "3000"
    volumes:
      - .:/workspace
YAML

CONTAINER_NAME_WARNINGS="$(compose_conflict_warnings "$COMPOSE_FILE_CONTAINER_NAME")"
if [ -n "$CONTAINER_NAME_WARNINGS" ]; then
  pass "container_name: を含む compose ファイルで警告が出る"
else
  fail "container_name: を含む compose ファイルで警告が出る" "警告が空でした"
fi

FIXED_PORT_WARNINGS="$(compose_conflict_warnings "$COMPOSE_FILE_FIXED_PORT")"
if [ -n "$FIXED_PORT_WARNINGS" ]; then
  pass "固定ホストポートを含む compose ファイルで警告が出る"
else
  fail "固定ホストポートを含む compose ファイルで警告が出る" "警告が空でした"
fi

NO_CONFLICT_WARNINGS="$(compose_conflict_warnings "$COMPOSE_FILE_NO_CONFLICT")"
assert_eq "衝突が無い compose ファイル（コンテナ側ポートのみ）では警告が出ない" "" "$NO_CONFLICT_WARNINGS"

# ---------------------------------------------------------------------------
# ケース8: compose モードの compose_project / compose_file / compose_service / workdir
# （Epic #3 仕様書「5. 検証方針」ケース8、Task #9）
#
# --project-directory がどの worktree から叩いてもリポジトリルートを指すこと、
# -p に渡るプロジェクト名が worktree 名に依存しないことが本タスクの本丸。
# ---------------------------------------------------------------------------

echo "== compose モード（ケース8） =="

COMPOSE_REPO="$(make_temp_repo)"
copy_sandbox_scripts_no_dockerfile "$COMPOSE_REPO"

COMPOSE_FILE_DEFAULT="${COMPOSE_REPO}/docker-compose.dev.yml"
cat > "$COMPOSE_FILE_DEFAULT" <<'YAML'
services:
  app:
    build: .
    volumes:
      - .:/workspace
YAML
(
  cd "$COMPOSE_REPO" || exit 1
  git add docker-compose.dev.yml
  git commit -q -m "add compose file"
) >/dev/null 2>&1

COMPOSE_REPO_BASENAME="$(basename "$COMPOSE_REPO")"

# --- print-plan（リポジトリルートから） ---
COMPOSE_CASE1_OUTPUT="$(print_plan_in "$COMPOSE_REPO")"

assert_eq "compose: mode=compose" "compose" "$(plan_value mode "$COMPOSE_CASE1_OUTPUT")"
assert_eq "compose: compose_file は docker-compose.dev.yml" "docker-compose.dev.yml" "$(plan_value compose_file "$COMPOSE_CASE1_OUTPUT")"
assert_eq "compose: compose_service は既定値 app" "app" "$(plan_value compose_service "$COMPOSE_CASE1_OUTPUT")"
assert_eq "compose: compose_project は dw-<repo>" "dw-${COMPOSE_REPO_BASENAME}" "$(plan_value compose_project "$COMPOSE_CASE1_OUTPUT")"
assert_eq "compose: workdir はリポジトリルートで /workspace" "/workspace" "$(plan_value workdir "$COMPOSE_CASE1_OUTPUT")"

# --- agent worktree から叩いても compose_project が worktree 名に依存しない（本タスクの本丸） ---
COMPOSE_AGENT_WORKTREE_DIR="${COMPOSE_REPO}/.claude/worktrees/agent-x"
make_worktree "$COMPOSE_REPO" "$COMPOSE_AGENT_WORKTREE_DIR" "compose-agent-worktree-branch"

COMPOSE_CASE_AGENT_OUTPUT="$(print_plan_in "$COMPOSE_AGENT_WORKTREE_DIR")"

assert_eq "compose: agent worktree からでも compose_project は同一（worktree 名非依存）" \
  "$(plan_value compose_project "$COMPOSE_CASE1_OUTPUT")" "$(plan_value compose_project "$COMPOSE_CASE_AGENT_OUTPUT")"
assert_eq "compose: agent worktree からの workdir は相対パス" \
  "/workspace/.claude/worktrees/agent-x" "$(plan_value workdir "$COMPOSE_CASE_AGENT_OUTPUT")"

# --- epic worktree からも compose_project が同一（agent worktree とも一致） ---
COMPOSE_EPIC_WORKTREE_DIR="${COMPOSE_REPO}/.claude/worktrees/epic7"
make_worktree "$COMPOSE_REPO" "$COMPOSE_EPIC_WORKTREE_DIR" "compose-epic-worktree-branch"

COMPOSE_CASE_EPIC_OUTPUT="$(print_plan_in "$COMPOSE_EPIC_WORKTREE_DIR")"

assert_eq "compose: epic worktree の compose_project も agent worktree と同一" \
  "$(plan_value compose_project "$COMPOSE_CASE_AGENT_OUTPUT")" "$(plan_value compose_project "$COMPOSE_CASE_EPIC_OUTPUT")"

# --- リポジトリ外の worktree（フォールバック）では compose_project も分離される（issue #27） ---
#
# 修正前は CONTAINER だけがフォールバック接尾辞で分離され、COMPOSE_PROJECT は
# 常に dw-<repo> のままだった。compose は project 名だけで既存サービスを探すため、
# リポジトリルートからの実行とリポジトリ外worktreeからの実行が同じ project を
# 共有してしまい、片方が起動した compose サービスへもう片方が警告なしに exec してしまう
# （実行系の再現テストは下記の compose_project 分離を前提にした別ケースで検証する）。
COMPOSE_OUTSIDE_WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-compose-outside.XXXXXX")"
make_worktree "$COMPOSE_REPO" "$COMPOSE_OUTSIDE_WORKTREE_DIR" "compose-outside-worktree-branch"

COMPOSE_CASE_OUTSIDE_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-compose-outside-stderr.XXXXXX")"
COMPOSE_CASE_OUTSIDE_OUTPUT="$(
  cd "$COMPOSE_OUTSIDE_WORKTREE_DIR" || exit 1
  PATH="${FAKE_BIN_DIR}:${PATH}" bash scripts/sandbox-exec.sh --print-plan 2>"$COMPOSE_CASE_OUTSIDE_STDERR"
)"

assert_eq "compose: リポジトリ外worktreeでは fallback=1" "1" "$(plan_value fallback "$COMPOSE_CASE_OUTSIDE_OUTPUT")"

COMPOSE_OUTSIDE_PROJECT="$(plan_value compose_project "$COMPOSE_CASE_OUTSIDE_OUTPUT")"
COMPOSE_ROOT_PROJECT="$(plan_value compose_project "$COMPOSE_CASE1_OUTPUT")"
if [ "$COMPOSE_OUTSIDE_PROJECT" != "$COMPOSE_ROOT_PROJECT" ]; then
  pass "compose: リポジトリ外worktree（フォールバック）では compose_project が分離される（issue #27）"
else
  fail "compose: リポジトリ外worktree（フォールバック）では compose_project が分離される（issue #27）" \
    "compose_project=[${COMPOSE_OUTSIDE_PROJECT}]（共有 project と同一でした）"
fi

COMPOSE_OUTSIDE_CONTAINER="$(plan_value container "$COMPOSE_CASE_OUTSIDE_OUTPUT")"
COMPOSE_ROOT_CONTAINER="$(plan_value container "$COMPOSE_CASE1_OUTPUT")"
if [ "$COMPOSE_OUTSIDE_CONTAINER" != "$COMPOSE_ROOT_CONTAINER" ]; then
  pass "compose: リポジトリ外worktree（フォールバック）では container も分離される（issue #27）"
else
  fail "compose: リポジトリ外worktree（フォールバック）では container も分離される（issue #27）" \
    "container=[${COMPOSE_OUTSIDE_CONTAINER}]（共有コンテナと同一でした）"
fi

if [ -s "$COMPOSE_CASE_OUTSIDE_STDERR" ]; then
  pass "compose: リポジトリ外worktreeのフォールバック時に stderr へ警告する"
else
  fail "compose: リポジトリ外worktreeのフォールバック時に stderr へ警告する" "stderr が空でした"
fi

# ---------------------------------------------------------------------------
# compose モードの実行系（偽 docker で `docker compose` を模擬する）。
#
# 偽 docker は `compose -p PROJECT --project-directory DIR -f FILE <サブコマンド>...`
# を解釈し、状態ファイルでサービスの running / not-running を切り替える。
# 実際の docker には一切触れない。呼び出し引数は DW_COMPOSE_LOG にすべて記録する。
#
# DW_COMPOSE_MOUNT_SOURCE（既定は未設定=空）: `container inspect -f <Mountsを含むテンプレート>`
# の戻り値。既存サービスのマウント元検証（issue #27）を検証するために使う。
# `docker rm -f <id>` を呼ぶと状態ファイルを空にし、以後 running ではなくなったものとして扱う
# （issue #27 の「不一致なら削除して作り直す」を再現するため）。
# ---------------------------------------------------------------------------

FAKE_DOCKER_COMPOSE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fakebin-compose.XXXXXX")"
cat > "${FAKE_DOCKER_COMPOSE_DIR}/docker" <<'FAKE_DOCKER_COMPOSE'
#!/bin/bash
# tests/run-tests.sh 用の偽 docker（compose モード専用）。実際の docker には一切触れない。
set -u

LOG="${DW_COMPOSE_LOG:?DW_COMPOSE_LOG is required}"
STATE_FILE="${DW_COMPOSE_SERVICE_STATE:?DW_COMPOSE_SERVICE_STATE is required}"   # "" | running
UP_SUCCEEDS="${DW_COMPOSE_UP_SUCCEEDS:-1}"
WORKDIR_OK="${DW_COMPOSE_WORKDIR_OK:-1}"
MOUNT_SOURCE="${DW_COMPOSE_MOUNT_SOURCE:-}"
# issue #34 用: 「project|working_dir|running」形式のマニフェスト（1行1project）。
# list_compose_projects_in_repo() の top-level `docker ps -a --filter
# label=com.docker.compose.project ...` を模擬するために使う（未設定なら空扱い）。
PROJECTS_MANIFEST="${DW_COMPOSE_PROJECTS_MANIFEST:-}"
# issue #32 用: 1にすると一覧取得（label=com.docker.compose.project 単体フィルタ）を
# 実機で観測したテンプレート誤用と同様に失敗させ、非0終了 + stderr 出力を模擬する。
PS_FAIL="${DW_COMPOSE_PS_FAIL:-0}"

echo "$*" >> "$LOG"

case "${1:-}" in
  ps)
    shift
    filter=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -a) shift ;;
        --filter) filter="$2"; shift 2 ;;
        --format) shift 2 ;;
        *) shift ;;
      esac
    done
    case "$filter" in
      "label=com.docker.compose.project")
        if [ "$PS_FAIL" = "1" ]; then
          echo 'failed to execute template: error calling index: cannot index slice/array with type string' >&2
          exit 1
        fi
        # 自リポジトリ・他リポジトリ両方の compose project をマニフェストのまま返す。
        # どれを対象にするかは production 側（正規化して working_dir を判定）に委ねる。
        if [ -n "$PROJECTS_MANIFEST" ] && [ -f "$PROJECTS_MANIFEST" ]; then
          while IFS='|' read -r m_proj m_wd _m_running; do
            [ -n "$m_proj" ] || continue
            printf '%s|%s\n' "$m_proj" "$m_wd"
          done < "$PROJECTS_MANIFEST"
        fi
        exit 0
        ;;
      label=com.docker.compose.project=*)
        target_proj="${filter#label=com.docker.compose.project=}"
        if [ -n "$PROJECTS_MANIFEST" ] && [ -f "$PROJECTS_MANIFEST" ]; then
          while IFS='|' read -r m_proj _m_wd m_running; do
            [ "$m_proj" = "$target_proj" ] || continue
            [ "$m_running" = "running" ] && echo "fake-compose-container-id"
          done < "$PROJECTS_MANIFEST"
        fi
        exit 0
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  compose)
    shift
    # 先頭の共通オプション（-p / --project-directory / -f）を読み飛ばしてサブコマンドを取り出す
    while [ $# -gt 0 ]; do
      case "$1" in
        -p|--project-directory|-f) shift 2 ;;
        *) break ;;
      esac
    done
    sub="${1:-}"
    shift || true
    case "$sub" in
      ps)
        state="$(cat "$STATE_FILE" 2>/dev/null || true)"
        if [ "$state" = "running" ]; then
          echo "fake-compose-container-id"
        fi
        exit 0
        ;;
      up)
        if [ "$UP_SUCCEEDS" = "1" ]; then
          printf 'running\n' > "$STATE_FILE"
        fi
        exit 0
        ;;
      down)
        printf '\n' > "$STATE_FILE"
        exit 0
        ;;
      exec)
        case "$*" in
          *"test -d"*)
            [ "$WORKDIR_OK" = "1" ] && exit 0 || exit 1
            ;;
          *)
            # -c の次の引数がコマンド文字列（quoting により1引数として渡ってくる）
            cmd=""
            prev=""
            for a in "$@"; do
              [ "$prev" = "-c" ] && cmd="$a"
              prev="$a"
            done
            sh -c "$cmd"
            exit $?
            ;;
        esac
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  container)
    shift
    [ "${1:-}" = "inspect" ] || exit 1
    shift
    tmpl=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f) tmpl="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    case "$tmpl" in
      *'Mounts'*)
        printf '%s\n' "$MOUNT_SOURCE"
        ;;
      *)
        state="$(cat "$STATE_FILE" 2>/dev/null || true)"
        if [ "$state" = "running" ]; then echo "true"; else echo "false"; fi
        ;;
    esac
    exit 0
    ;;
  rm)
    shift
    # `docker rm -f <id>`。マウント元不一致で再作成する際に呼ばれる（issue #27）。
    # 実際の docker には触れず、状態ファイルを空にして「削除済み」を再現する。
    printf '\n' > "$STATE_FILE"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
FAKE_DOCKER_COMPOSE
chmod +x "${FAKE_DOCKER_COMPOSE_DIR}/docker"

COMPOSE_TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-composelog.XXXXXX")"
COMPOSE_TEST_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-composestate.XXXXXX")"

run_compose_case() {
  # run_compose_case <dir> <initial_state> <up_succeeds 0/1> <workdir_ok 0/1> [追加のsandbox-exec.sh引数...]
  # 環境変数 COMPOSE_TEST_MOUNT_SOURCE が設定されていれば、既存サービスのマウント元検証
  # （issue #27）を再現するための DW_COMPOSE_MOUNT_SOURCE として渡す（未設定なら空のまま）。
  local dir="$1" initial_state="$2" up_succeeds="$3" workdir_ok="$4"
  shift 4

  : > "$COMPOSE_TEST_LOG"
  printf '%s' "$initial_state" > "$COMPOSE_TEST_STATE_FILE"

  (
    cd "$dir" || exit 1
    DW_COMPOSE_LOG="$COMPOSE_TEST_LOG" \
      DW_COMPOSE_SERVICE_STATE="$COMPOSE_TEST_STATE_FILE" \
      DW_COMPOSE_UP_SUCCEEDS="$up_succeeds" \
      DW_COMPOSE_WORKDIR_OK="$workdir_ok" \
      DW_COMPOSE_MOUNT_SOURCE="${COMPOSE_TEST_MOUNT_SOURCE:-}" \
      PATH="${FAKE_DOCKER_COMPOSE_DIR}:${PATH}" \
      bash scripts/sandbox-exec.sh "$@"
  )
}

# --- agent worktree から叩いても --project-directory がリポジトリルートを指す（本タスクの本丸） ---
COMPOSE_HOST_ROOT="$(plan_value repo_root "$COMPOSE_CASE1_OUTPUT")"

COMPOSE_RUN1_EXIT=0
run_compose_case "$COMPOSE_AGENT_WORKTREE_DIR" "running" 1 1 'true' >/dev/null 2>&1 || COMPOSE_RUN1_EXIT=$?
assert_exit_code "compose: agent worktree からの実行が成功する" 0 "$COMPOSE_RUN1_EXIT"

case "$(cat "$COMPOSE_TEST_LOG")" in
  *"--project-directory ${COMPOSE_HOST_ROOT}"*)
    pass "compose: agent worktree から叩いても --project-directory がリポジトリルートを指す" ;;
  *)
    fail "compose: agent worktree から叩いても --project-directory がリポジトリルートを指す" \
      "log=[$(cat "$COMPOSE_TEST_LOG")] expected_root=[${COMPOSE_HOST_ROOT}]" ;;
esac

case "$(cat "$COMPOSE_TEST_LOG")" in
  *"-p dw-${COMPOSE_REPO_BASENAME} "*)
    pass "compose: -p に渡るプロジェクト名が agent worktree でも repo 基準" ;;
  *)
    fail "compose: -p に渡るプロジェクト名が agent worktree でも repo 基準" "log=[$(cat "$COMPOSE_TEST_LOG")]" ;;
esac

# --- サービス未起動時に up -d が呼ばれる ---
COMPOSE_RUN2_EXIT=0
run_compose_case "$COMPOSE_REPO" "" 1 1 'true' >/dev/null 2>&1 || COMPOSE_RUN2_EXIT=$?
assert_exit_code "compose: サービス未起動から up -d 成功時は実行全体が成功する" 0 "$COMPOSE_RUN2_EXIT"

if grep -q ' up -d app$' "$COMPOSE_TEST_LOG"; then
  pass "compose: サービス未起動時に up -d が呼ばれる"
else
  fail "compose: サービス未起動時に up -d が呼ばれる" "log=[$(cat "$COMPOSE_TEST_LOG")]"
fi

# --- up -d しても起動しない場合、サービス名と DEV_WORKFLOW_COMPOSE_SERVICE を含むエラーで停止する ---
COMPOSE_RUN3_STDERR="$(run_compose_case "$COMPOSE_REPO" "" 0 1 'true' 2>&1 1>/dev/null)"
COMPOSE_RUN3_EXIT=$?

if [ "$COMPOSE_RUN3_EXIT" -ne 0 ]; then
  pass "compose: up -d しても起動しない場合は非0で終了する"
else
  fail "compose: up -d しても起動しない場合は非0で終了する" "exit=0"
fi

case "$COMPOSE_RUN3_STDERR" in
  *"app"*) pass "compose: 起動失敗エラーにサービス名が含まれる" ;;
  *) fail "compose: 起動失敗エラーにサービス名が含まれる" "stderr=[${COMPOSE_RUN3_STDERR}]" ;;
esac

case "$COMPOSE_RUN3_STDERR" in
  *"DEV_WORKFLOW_COMPOSE_SERVICE"*) pass "compose: 起動失敗エラーに DEV_WORKFLOW_COMPOSE_SERVICE の案内が含まれる" ;;
  *) fail "compose: 起動失敗エラーに DEV_WORKFLOW_COMPOSE_SERVICE の案内が含まれる" "stderr=[${COMPOSE_RUN3_STDERR}]" ;;
esac

# --- workdir が無い場合、DEV_WORKFLOW_COMPOSE_WORKDIR に言及したエラーで停止する ---
COMPOSE_RUN4_STDERR="$(run_compose_case "$COMPOSE_REPO" "running" 1 0 'true' 2>&1 1>/dev/null)"
COMPOSE_RUN4_EXIT=$?

if [ "$COMPOSE_RUN4_EXIT" -ne 0 ]; then
  pass "compose: workdir が無い場合は非0で終了する"
else
  fail "compose: workdir が無い場合は非0で終了する" "exit=0"
fi

case "$COMPOSE_RUN4_STDERR" in
  *"DEV_WORKFLOW_COMPOSE_WORKDIR"*) pass "compose: workdir 不在エラーに DEV_WORKFLOW_COMPOSE_WORKDIR の案内が含まれる" ;;
  *) fail "compose: workdir 不在エラーに DEV_WORKFLOW_COMPOSE_WORKDIR の案内が含まれる" "stderr=[${COMPOSE_RUN4_STDERR}]" ;;
esac

# --- container_name: を含む compose ファイルを使うと、実行時に stderr へ警告が出る（停止はしない） ---
COMPOSE_WARN_REPO="$(make_temp_repo)"
copy_sandbox_scripts_no_dockerfile "$COMPOSE_WARN_REPO"
cat > "${COMPOSE_WARN_REPO}/docker-compose.dev.yml" <<'YAML'
services:
  app:
    build: .
    container_name: myapp
    volumes:
      - .:/workspace
YAML
(
  cd "$COMPOSE_WARN_REPO" || exit 1
  git add docker-compose.dev.yml
  git commit -q -m "add compose file with container_name"
) >/dev/null 2>&1

COMPOSE_WARN_STDERR="$(
  : > "$COMPOSE_TEST_LOG"
  printf 'running' > "$COMPOSE_TEST_STATE_FILE"
  cd "$COMPOSE_WARN_REPO" || exit 1
  DW_COMPOSE_LOG="$COMPOSE_TEST_LOG" \
    DW_COMPOSE_SERVICE_STATE="$COMPOSE_TEST_STATE_FILE" \
    DW_COMPOSE_UP_SUCCEEDS=1 \
    DW_COMPOSE_WORKDIR_OK=1 \
    PATH="${FAKE_DOCKER_COMPOSE_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh 'true' 2>&1 1>/dev/null
)"

case "$COMPOSE_WARN_STDERR" in
  *"container_name"*) pass "compose: 実行時に container_name の衝突警告が stderr に出る" ;;
  *) fail "compose: 実行時に container_name の衝突警告が stderr に出る" "stderr=[${COMPOSE_WARN_STDERR}]" ;;
esac

# ---------------------------------------------------------------------------
# 既存サービスが running でも、マウント元が期待値（MOUNT_SOURCE）と異なれば削除して
# 作り直す（issue #27）。フォールバック時の compose_project 分離（本コミットで修正済み）が
# 主たる対策だが、その二重チェックとして dockerfile モードと同様の検証をここでも固定する。
# ---------------------------------------------------------------------------

echo "== compose: 既存サービスのマウント元検証（issue #27） =="

COMPOSE_TEST_MOUNT_SOURCE="/some/other/tree"
COMPOSE_MISMATCH_STDERR="$(run_compose_case "$COMPOSE_REPO" "running" 1 1 'true' 2>&1 1>/dev/null)"
COMPOSE_MISMATCH_EXIT=$?
unset COMPOSE_TEST_MOUNT_SOURCE

assert_exit_code "compose: マウント元不一致を検出して削除・作り直し後に成功する（issue #27）" 0 "$COMPOSE_MISMATCH_EXIT"

case "$COMPOSE_MISMATCH_STDERR" in
  *"マウント元"*"削除して作り直します"*)
    pass "compose: 既存サービスのマウント元不一致を検出して警告する（issue #27）" ;;
  *)
    fail "compose: 既存サービスのマウント元不一致を検出して警告する（issue #27）" \
      "stderr=[${COMPOSE_MISMATCH_STDERR}]" ;;
esac

if grep -q '^rm -f fake-compose-container-id$' "$COMPOSE_TEST_LOG"; then
  pass "compose: マウント元不一致の既存コンテナを docker rm -f で削除する（issue #27）"
else
  fail "compose: マウント元不一致の既存コンテナを docker rm -f で削除する（issue #27）" \
    "log=[$(cat "$COMPOSE_TEST_LOG")]"
fi

if grep -q ' up -d app$' "$COMPOSE_TEST_LOG"; then
  pass "compose: マウント元不一致で削除した後は up -d で作り直す（issue #27）"
else
  fail "compose: マウント元不一致で削除した後は up -d で作り直す（issue #27）" \
    "log=[$(cat "$COMPOSE_TEST_LOG")]"
fi

# --- マウント元が一致していれば、running なサービスを削除せず再利用する（回帰防止） ---
COMPOSE_TEST_MOUNT_SOURCE="$COMPOSE_HOST_ROOT"
COMPOSE_MATCH_EXIT=0
run_compose_case "$COMPOSE_REPO" "running" 1 1 'true' >/dev/null 2>&1 || COMPOSE_MATCH_EXIT=$?
unset COMPOSE_TEST_MOUNT_SOURCE

assert_exit_code "compose: マウント元一致時は成功する" 0 "$COMPOSE_MATCH_EXIT"

if grep -q '^rm -f fake-compose-container-id$' "$COMPOSE_TEST_LOG"; then
  fail "compose: マウント元が一致していれば既存コンテナを削除しない（回帰防止）" \
    "log=[$(cat "$COMPOSE_TEST_LOG")]"
else
  pass "compose: マウント元が一致していれば既存コンテナを削除しない（回帰防止）"
fi

# ---------------------------------------------------------------------------
# --down が compose モードのとき docker compose down を -p / --project-directory 付きで
# 呼ぶことを固定する（issue #28）。本 Epic で compose モードは対象サービスが running で
# なければ up -d を自動実行するようになった一方、以前の --down は dw-sandbox-* という
# 名前のコンテナしか削除せず、compose が起動したコンテナを落とす主体がいなかった。
# ---------------------------------------------------------------------------

echo "== compose: --down（issue #28） =="

COMPOSE_DOWN_EXIT=0
COMPOSE_DOWN_STDOUT="$(run_compose_case "$COMPOSE_REPO" "running" 1 1 --down 2>/dev/null)" || COMPOSE_DOWN_EXIT=$?
assert_exit_code "compose: --down は成功する（issue #28）" 0 "$COMPOSE_DOWN_EXIT"

case "$(cat "$COMPOSE_TEST_LOG")" in
  *"compose -p dw-${COMPOSE_REPO_BASENAME} --project-directory ${COMPOSE_HOST_ROOT} -f docker-compose.dev.yml down"*)
    pass "compose: --down は docker compose down を -p / --project-directory 付きで呼ぶ（issue #28）" ;;
  *)
    fail "compose: --down は docker compose down を -p / --project-directory 付きで呼ぶ（issue #28）" \
      "log=[$(cat "$COMPOSE_TEST_LOG")]" ;;
esac

case "$COMPOSE_DOWN_STDOUT" in
  *"dw-${COMPOSE_REPO_BASENAME}"*) pass "compose: --down の出力に project 名が表示される（issue #28）" ;;
  *) fail "compose: --down の出力に project 名が表示される（issue #28）" "output=[${COMPOSE_DOWN_STDOUT}]" ;;
esac

# ---------------------------------------------------------------------------
# CRLF 警告（crlf_warning_message、Docker 非依存の純粋関数、Task #11、Epic #3 仕様書 4.10）
#
# check-prerequisites.sh を source しても本体（gh/docker/git リポジトリチェック等）が
# 実行されないことを利用し、crlf_warning_message だけを直接呼び出して検証する。
# 一時 git リポジトリの core.autocrlf / .gitattributes を組み合わせて条件を再現する。
# ---------------------------------------------------------------------------

echo "== crlf_warning_message（CRLF警告・Docker非依存。Task #11） =="

CHECK_PREREQS_SCRIPT="${REPO_ROOT}/scripts/check-prerequisites.sh"

make_crlf_test_repo() {
  # make_crlf_test_repo <autocrlf値> <gitattributes内容 or 空>
  # core.autocrlf と .gitattributes を指定して一時リポジトリを作り、パスを返す。
  local autocrlf="$1" attrs="$2"
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-crlf-repo.XXXXXX")"
  (
    cd "$dir" || exit 1
    git init -q
    git config user.email "dev-workflow-test@example.com"
    git config user.name "dev-workflow test"
    git config core.autocrlf "$autocrlf"
    if [ -n "$attrs" ]; then
      printf '%s\n' "$attrs" > .gitattributes
    fi
  ) >/dev/null 2>&1
  printf '%s' "$dir"
}

crlf_warning_in() {
  # crlf_warning_in <dir>  <dir> 内で check-prerequisites.sh を source し
  # crlf_warning_message を呼び出した標準出力を返す（stderr は捨てる）。
  local dir="$1"
  (
    cd "$dir" || exit 1
    # shellcheck source=../scripts/check-prerequisites.sh
    source "$CHECK_PREREQS_SCRIPT"
    crlf_warning_message
  ) 2>/dev/null
}

# --- autocrlf=true かつ .gitattributes に *.sh の eol=lf が無ければ警告が出る ---
CRLF_NOATTR_REPO="$(make_crlf_test_repo true "")"
CRLF_NOATTR_WARNING="$(crlf_warning_in "$CRLF_NOATTR_REPO")"

if [ -n "$CRLF_NOATTR_WARNING" ]; then
  pass "autocrlf=true かつ eol=lf 未設定なら警告が出る"
else
  fail "autocrlf=true かつ eol=lf 未設定なら警告が出る" "警告が空でした"
fi

case "$CRLF_NOATTR_WARNING" in
  *".gitattributes"*) pass "警告文に .gitattributes への言及がある" ;;
  *) fail "警告文に .gitattributes への言及がある" "warning=[${CRLF_NOATTR_WARNING}]" ;;
esac

case "$CRLF_NOATTR_WARNING" in
  *"*.sh text eol=lf"*) pass "警告文に *.sh text eol=lf の追記案内がある" ;;
  *) fail "警告文に *.sh text eol=lf の追記案内がある" "warning=[${CRLF_NOATTR_WARNING}]" ;;
esac

if printf '%s' "$CRLF_NOATTR_WARNING" | grep -qF '$'"'"'{\r'"'"''; then
  pass "警告文に構文エラーの症状（\$'{\\r'）が含まれる"
else
  fail "警告文に構文エラーの症状（\$'{\\r'）が含まれる" "warning=[${CRLF_NOATTR_WARNING}]"
fi

# --- autocrlf=true でも .gitattributes に *.sh text eol=lf があれば警告は出ない ---
CRLF_WITHATTR_REPO="$(make_crlf_test_repo true "*.sh text eol=lf")"
CRLF_WITHATTR_WARNING="$(crlf_warning_in "$CRLF_WITHATTR_REPO")"

assert_eq "autocrlf=true でも *.sh text eol=lf があれば警告が出ない" "" "$CRLF_WITHATTR_WARNING"

# --- autocrlf=false なら警告は出ない ---
CRLF_FALSE_REPO="$(make_crlf_test_repo false "")"
CRLF_FALSE_WARNING="$(crlf_warning_in "$CRLF_FALSE_REPO")"

assert_eq "autocrlf=false なら警告が出ない" "" "$CRLF_FALSE_WARNING"

# --- autocrlf=input でも警告は出ない（true のときだけが対象） ---
CRLF_INPUT_REPO="$(make_crlf_test_repo input "")"
CRLF_INPUT_WARNING="$(crlf_warning_in "$CRLF_INPUT_REPO")"

assert_eq "autocrlf=input なら警告が出ない" "" "$CRLF_INPUT_WARNING"

# --- 警告が出るケースでも check-prerequisites.sh 全体の終了コードは変わらない（exit 2 でブロックしない） ---
#
# check-prerequisites.sh 本体は gh/docker の実コマンドを呼び、gh 認証済みなら
# `git config --global credential.helper` まで書き換える副作用を持つ。テストで
# 実ホストの状態を変えないよう、gh/docker は偽コマンドに差し替え、--global の参照先も
# 隔離した HOME に向ける（実際の docker/gh には一切触れない）。
CRLF_FAKE_BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-crlf-fakebin.XXXXXX")"
cat > "${CRLF_FAKE_BIN_DIR}/gh" <<'FAKE_GH'
#!/bin/bash
# tests/run-tests.sh 用の偽 gh。認証済み扱いにして常に成功させる。
exit 0
FAKE_GH
chmod +x "${CRLF_FAKE_BIN_DIR}/gh"
cat > "${CRLF_FAKE_BIN_DIR}/docker" <<'FAKE_DOCKER_PREREQ'
#!/bin/bash
# tests/run-tests.sh 用の偽 docker。起動済み扱いにして常に成功させる。
exit 0
FAKE_DOCKER_PREREQ
chmod +x "${CRLF_FAKE_BIN_DIR}/docker"

CRLF_FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-crlf-fakehome.XXXXXX")"
printf '[credential]\n\thelper = gh\n' > "${CRLF_FAKE_HOME}/.gitconfig"

CRLF_FULL_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-crlf-full-stderr.XXXXXX")"
CRLF_FULL_EXIT=0
(
  cd "$CRLF_NOATTR_REPO" || exit 1
  HOME="$CRLF_FAKE_HOME" PATH="${CRLF_FAKE_BIN_DIR}:${PATH}" \
    bash "$CHECK_PREREQS_SCRIPT" 1>/dev/null 2>"$CRLF_FULL_STDERR"
) || CRLF_FULL_EXIT=$?

assert_exit_code "偽gh/偽dockerが揃った状態でCRLF警告があっても exit 0（ブロックしない）" 0 "$CRLF_FULL_EXIT"

if grep -q "core.autocrlf=true" "$CRLF_FULL_STDERR"; then
  pass "check-prerequisites.sh 本体からも CRLF 警告が stderr に出る"
else
  fail "check-prerequisites.sh 本体からも CRLF 警告が stderr に出る" "stderr=[$(cat "$CRLF_FULL_STDERR")]"
fi

# ---------------------------------------------------------------------------
# optional_tools_notice（任意ツールの非ブロッキング検出、Epic #66 Phase1・Task #68）
#
# context7 / code-review-graph の導入状況（docs/optional-mcp-tools.md「## 申し送りに対してどう応えたか
# （#80 レビュー対応）」節のとおり、dev-workflowが実際に`command`へ指定するコマンド名:
# context7-mcp / code-review-graph）を command -v で判定する純粋関数。`npx`はNode.js同梱でほぼ
# 常に存在し「context7 = 常に導入済み」と誤判定するため使わない（レビュー指摘 #82）。
# crlf_warning_message と同じく check-prerequisites.sh を source して単体テストする。
# ---------------------------------------------------------------------------

echo "== optional_tools_notice（任意ツールの非ブロッキング検出。Task #68） =="

make_tool_stub_dir() {
  # make_tool_stub_dir <ツール名...>  指定した名前の実行可能スタブだけを持つ一時ディレクトリを作る。
  local dir tool
  dir="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-optional-tools.XXXXXX")"
  for tool in "$@"; do
    cat > "${dir}/${tool}" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "${dir}/${tool}"
  done
  printf '%s' "$dir"
}

optional_tools_notice_with_path() {
  # optional_tools_notice_with_path <PATH>
  # 指定した PATH だけを使って optional_tools_notice を呼び出し、標準出力を返す（stderr は捨てる）。
  # 関数内部は command -v の判定しか行わないため、PATH をこのスタブだけに絞っても安全。
  local fake_path="$1"
  (
    # shellcheck source=../scripts/check-prerequisites.sh
    source "$CHECK_PREREQS_SCRIPT"
    PATH="$fake_path" optional_tools_notice
  ) 2>/dev/null
}

# --- 両方とも利用可能な環境では何も出力しない ---
OPT_TOOLS_BOTH_DIR="$(make_tool_stub_dir context7-mcp code-review-graph)"
OPT_TOOLS_BOTH_NOTICE="$(optional_tools_notice_with_path "$OPT_TOOLS_BOTH_DIR")"
assert_eq "context7 / code-review-graph が両方利用可能なら何も出力しない" "" "$OPT_TOOLS_BOTH_NOTICE"

# --- context7 のみ未導入な環境では、context7 と「従来どおり」を含む警告を返す ---
OPT_TOOLS_NO_CONTEXT7_DIR="$(make_tool_stub_dir code-review-graph)"
OPT_TOOLS_NO_CONTEXT7_NOTICE="$(optional_tools_notice_with_path "$OPT_TOOLS_NO_CONTEXT7_DIR")"

case "$OPT_TOOLS_NO_CONTEXT7_NOTICE" in
  *"context7"*) pass "context7 未導入時、警告に context7 という文字列が含まれる" ;;
  *) fail "context7 未導入時、警告に context7 という文字列が含まれる" "notice=[${OPT_TOOLS_NO_CONTEXT7_NOTICE}]" ;;
esac

case "$OPT_TOOLS_NO_CONTEXT7_NOTICE" in
  *"従来どおり"*) pass "context7 未導入時、警告に『従来どおり』の文言が含まれる" ;;
  *) fail "context7 未導入時、警告に『従来どおり』の文言が含まれる" "notice=[${OPT_TOOLS_NO_CONTEXT7_NOTICE}]" ;;
esac

case "$OPT_TOOLS_NO_CONTEXT7_NOTICE" in
  *"code-review-graph"*) fail "context7 のみ未導入なら code-review-graph には言及しない" "notice=[${OPT_TOOLS_NO_CONTEXT7_NOTICE}]" ;;
  *) pass "context7 のみ未導入なら code-review-graph には言及しない" ;;
esac

# --- code-review-graph のみ未導入な環境でも同様（片方が未導入なら未導入分だけ列挙する） ---
OPT_TOOLS_NO_CRG_DIR="$(make_tool_stub_dir context7-mcp)"
OPT_TOOLS_NO_CRG_NOTICE="$(optional_tools_notice_with_path "$OPT_TOOLS_NO_CRG_DIR")"

case "$OPT_TOOLS_NO_CRG_NOTICE" in
  *"code-review-graph"*) pass "code-review-graph 未導入時、警告に code-review-graph という文字列が含まれる" ;;
  *) fail "code-review-graph 未導入時、警告に code-review-graph という文字列が含まれる" "notice=[${OPT_TOOLS_NO_CRG_NOTICE}]" ;;
esac

case "$OPT_TOOLS_NO_CRG_NOTICE" in
  *"従来どおり"*) pass "code-review-graph 未導入時、警告に『従来どおり』の文言が含まれる" ;;
  *) fail "code-review-graph 未導入時、警告に『従来どおり』の文言が含まれる" "notice=[${OPT_TOOLS_NO_CRG_NOTICE}]" ;;
esac

# --- レビュー指摘 #82 の再発防止: npx はあるが context7-mcp が無い環境では、
#     context7 が「未導入」と正しく通知されること（npx の有無を context7 の代わりに
#     見てしまう歪みが直したはずなのに戻っていないかを検出する） ---
OPT_TOOLS_NPX_ONLY_DIR="$(make_tool_stub_dir npx code-review-graph)"
OPT_TOOLS_NPX_ONLY_NOTICE="$(optional_tools_notice_with_path "$OPT_TOOLS_NPX_ONLY_DIR")"

case "$OPT_TOOLS_NPX_ONLY_NOTICE" in
  *"context7"*) pass "npx はあるが context7-mcp が無い環境で、context7 が未導入と正しく通知される（#82再発防止）" ;;
  *) fail "npx はあるが context7-mcp が無い環境で、context7 が未導入と正しく通知される（#82再発防止）" \
    "notice=[${OPT_TOOLS_NPX_ONLY_NOTICE}]" ;;
esac

case "$OPT_TOOLS_NPX_ONLY_NOTICE" in
  *"code-review-graph"*) fail "npx はあるが context7-mcp が無い環境で、code-review-graph には言及しない（#82再発防止）" \
    "notice=[${OPT_TOOLS_NPX_ONLY_NOTICE}]" ;;
  *) pass "npx はあるが context7-mcp が無い環境で、code-review-graph には言及しない（#82再発防止）" ;;
esac

# --- 両方未導入でも check-prerequisites.sh 全体の終了コードは 2 にならない ---
#
# 他の必須依存（gh/docker）は満たされている前提を再現するため、CRLF警告テストと同じ
# 偽 gh / 偽 docker を使う。context7-mcp / code-review-graph が「未導入」であることを
# 環境非依存で保証するため、実際の $PATH からこの2つの実行ファイルを含むディレクトリだけを
# 取り除いた PATH を組み立てる（git / sed / cat / grep 等、他に必要な外部コマンドはそのまま残す）。
# npx は取り除かない（context7 の判定に npx を使わないことの確認を兼ねる。#82）。
strip_optional_tools_from_path() {
  local dir out=""
  local IFS=':'
  for dir in $PATH; do
    if [ -x "${dir}/context7-mcp" ] || [ -x "${dir}/code-review-graph" ]; then
      continue
    fi
    out="${out:+${out}:}${dir}"
  done
  printf '%s' "$out"
}

OPT_TOOLS_STRIPPED_PATH="$(strip_optional_tools_from_path)"
OPT_TOOLS_FULL_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-optional-tools-full-stderr.XXXXXX")"
OPT_TOOLS_FULL_EXIT=0
(
  cd "$CRLF_WITHATTR_REPO" || exit 1
  HOME="$CRLF_FAKE_HOME" PATH="${CRLF_FAKE_BIN_DIR}:${OPT_TOOLS_STRIPPED_PATH}" \
    bash "$CHECK_PREREQS_SCRIPT" 1>/dev/null 2>"$OPT_TOOLS_FULL_STDERR"
) || OPT_TOOLS_FULL_EXIT=$?

assert_exit_code "context7 / code-review-graph が両方未導入でも exit 0（ブロックしない）" 0 "$OPT_TOOLS_FULL_EXIT"

if grep -q "任意ツールが未導入です" "$OPT_TOOLS_FULL_STDERR"; then
  pass "check-prerequisites.sh 本体からも任意ツールの未導入通知が stderr に出る"
else
  fail "check-prerequisites.sh 本体からも任意ツールの未導入通知が stderr に出る" "stderr=[$(cat "$OPT_TOOLS_FULL_STDERR")]"
fi

# --- errors 配列に context7 / code-review-graph という文字列が追加されていないこと（静的検査） ---
if grep -n "errors+=" "$CHECK_PREREQS_SCRIPT" | grep -qiE "context7|code-review-graph"; then
  fail "errors 配列に任意ツール（context7 / code-review-graph）が追加されていない" \
    "$(grep -n "errors+=" "$CHECK_PREREQS_SCRIPT" | grep -iE "context7|code-review-graph")"
else
  pass "errors 配列に任意ツール（context7 / code-review-graph）が追加されていない"
fi

# ---------------------------------------------------------------------------
# check-readability.sh の非対話ハング修正（Task #10、Epic #3 仕様書 4.9）
#
# `--git` / `--staged` / ファイル引数が1つでもあれば stdin を一切読まない。
# 引数なし・非ttyのフック経路だけ上限付きで読み、タイムアウト時は exit 0 で
# 素通りする。ガード本体の判定ロジック（base64ブロブ検出・長い行検出）は
# 変更しない仕様のため、違反検出が従来どおり働くこともあわせて検証する。
#
# 「stdinを読まない」ことの検証は、プロセス置換 `< <(sleep N)` で終端しない
# stdinを用意して行う。パイプ（`sleep N | cmd`）だと親シェルが sleep の終了まで
# 待たされてテストが遅くなるが、プロセス置換なら判定対象コマンドが先に終われば
# 親シェルはバックグラウンドの sleep を待たない。もしスクリプトが誤って stdin を
# 読もうとした場合だけ `timeout` に引っかかり、それを失敗として検出する。
# ---------------------------------------------------------------------------

echo "== check-readability.sh（非対話ハング修正・Task #10） =="

CHECK_READABILITY_SCRIPT="${REPO_ROOT}/scripts/check-readability.sh"

RG_TMP_REPO="$(make_temp_repo)"
RG_CLEAN_FILE="clean.txt"
(
  cd "$RG_TMP_REPO" || exit 1
  printf 'clean file\n' > "$RG_CLEAN_FILE"
) >/dev/null 2>&1

# --- --git はstdinが開いたままでもハングせず即座に返る ---
RG_GIT_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  timeout 5 bash "$CHECK_READABILITY_SCRIPT" --git < <(sleep 10) >/dev/null 2>&1
)
RG_GIT_EXIT=$?
assert_exit_code "--git はstdinが開いたままでもハングせず即座に返る" 0 "$RG_GIT_EXIT"

# --- ファイル引数を渡した場合もstdinを読まない ---
RG_FILEARG_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  timeout 5 bash "$CHECK_READABILITY_SCRIPT" "$RG_CLEAN_FILE" < <(sleep 10) >/dev/null 2>&1
)
RG_FILEARG_EXIT=$?
assert_exit_code "ファイル引数を渡した場合もstdinを読まず即座に返る" 0 "$RG_FILEARG_EXIT"

# --- --staged も同様 ---
(
  cd "$RG_TMP_REPO" || exit 1
  git add "$RG_CLEAN_FILE"
) >/dev/null 2>&1

RG_STAGED_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  timeout 5 bash "$CHECK_READABILITY_SCRIPT" --staged < <(sleep 10) >/dev/null 2>&1
)
RG_STAGED_EXIT=$?
assert_exit_code "--stagedもstdinが開いたままでもハングせず即座に返る" 0 "$RG_STAGED_EXIT"

# --- 引数なし・非ttyで入力が来ない場合、タイムアウト後にexit 0で素通りする ---
# テストを遅くしないよう READABILITY_STDIN_TIMEOUT=1 で短くする。
RG_TIMEOUT_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-rg-timeout-stderr.XXXXXX")"
RG_TIMEOUT_EXIT=0
timeout 5 env READABILITY_STDIN_TIMEOUT=1 bash "$CHECK_READABILITY_SCRIPT" \
  < <(sleep 10) >/dev/null 2>"$RG_TIMEOUT_STDERR"
RG_TIMEOUT_EXIT=$?
assert_exit_code "引数なし・非ttyで入力が来ない場合はタイムアウト後exit 0で素通りする" 0 "$RG_TIMEOUT_EXIT"

if grep -q "1秒" "$RG_TIMEOUT_STDERR"; then
  pass "タイムアウト時にREADABILITY_STDIN_TIMEOUTの秒数を含む警告がstderrに出る"
else
  fail "タイムアウト時にREADABILITY_STDIN_TIMEOUTの秒数を含む警告がstderrに出る" "stderr=[$(cat "$RG_TIMEOUT_STDERR")]"
fi

# --- 引数なし・非ttyでフックJSONが渡された場合は従来どおり処理される（クリーンなファイル） ---
RG_HOOK_CLEAN_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  printf '{"tool_input":{"file_path":"%s"}}' "$RG_CLEAN_FILE" | bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG_HOOK_CLEAN_EXIT=$?
assert_exit_code "フックJSONのfile_pathから抽出したクリーンなファイルはexit 0" 0 "$RG_HOOK_CLEAN_EXIT"

# --- 引数なし・非ttyでフックJSONが渡された場合は従来どおり処理される（違反ファイル） ---
RG_VIOLATION_FILE="violation.txt"
(
  cd "$RG_TMP_REPO" || exit 1
  head -c 3000 /dev/zero | tr '\0' 'A' > "$RG_VIOLATION_FILE"
) >/dev/null 2>&1

RG_HOOK_VIOLATION_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  printf '{"tool_input":{"file_path":"%s"}}' "$RG_VIOLATION_FILE" \
    | READABILITY_MAX_BASE64=50 bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG_HOOK_VIOLATION_EXIT=$?
assert_exit_code "フックJSON経由でも違反ファイルはブロックされる" 2 "$RG_HOOK_VIOLATION_EXIT"

# --- 違反検出ロジックは従来どおり働く（巨大なbase64ブロブ） ---
RG_BLOB_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  READABILITY_MAX_BASE64=50 bash "$CHECK_READABILITY_SCRIPT" "$RG_VIOLATION_FILE" >/dev/null 2>&1
)
RG_BLOB_EXIT=$?
assert_exit_code "巨大なbase64ブロブを含むファイルはexit 2" 2 "$RG_BLOB_EXIT"

# --- 違反検出ロジックは従来どおり働く（極端に長い行）。
# base64文字集合に含まれない '-' で埋めることで、base64ブロブ検出とは
# 独立に「長い行」ルール単体の検出を確認する。
RG_LONGLINE_FILE="longline.txt"
(
  cd "$RG_TMP_REPO" || exit 1
  head -c 6000 /dev/zero | tr '\0' '-' > "$RG_LONGLINE_FILE"
  printf '\n' >> "$RG_LONGLINE_FILE"
) >/dev/null 2>&1

RG_LONGLINE_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG_LONGLINE_FILE" >/dev/null 2>&1
)
RG_LONGLINE_EXIT=$?
assert_exit_code "極端に長い行を含むファイルはexit 2" 2 "$RG_LONGLINE_EXIT"

# --- クリーンなファイルはexit 0（引数指定） ---
RG_CLEAN_EXIT=0
(
  cd "$RG_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG_CLEAN_FILE" >/dev/null 2>&1
)
RG_CLEAN_EXIT=$?
assert_exit_code "クリーンなファイルはexit 0" 0 "$RG_CLEAN_EXIT"

# --- ヘッダコメントに実在しない --exit-code の記述が残っていない ---
if grep -q -- '--exit-code' "$CHECK_READABILITY_SCRIPT"; then
  fail "ヘッダコメントに実在しない--exit-codeの記述が残っていない" "grep hit: $(grep -n -- '--exit-code' "$CHECK_READABILITY_SCRIPT")"
else
  pass "ヘッダコメントに実在しない--exit-codeの記述が残っていない"
fi

if grep -q "DEV_WORKFLOW_HOOK_VENDOR=exit-code" "$CHECK_READABILITY_SCRIPT"; then
  pass "ヘッダコメントがDEV_WORKFLOW_HOOK_VENDOR=exit-codeの正しい説明に修正されている"
else
  fail "ヘッダコメントがDEV_WORKFLOW_HOOK_VENDOR=exit-codeの正しい説明に修正されている" "grepで見つかりませんでした"
fi

# ---------------------------------------------------------------------------
# .gitattributes の eol=lf カバレッジ（回帰防止）
#
# *.toml（adapters/*/overlays/*.toml・codex-agents/*.toml）に eol=lf 指定が無かったため、
# core.autocrlf=true の環境でワーキングツリー上の *.toml が CRLF 化され、
# adapters/codex/build.sh の include 展開（1行ずつの case 一致）が壊れて
# `build.sh --check` が生成物を誤って STALE 判定する事故が実際に発生した。
# 同じ障害クラスが *.sh / *.toml のどちらでも起きないことを検証する。
#
# このリポジトリ自身（REPO_ROOT）に対して直接 git check-attr を呼ばないのは、
# generator の worktree（.claude/worktrees/agent-*）はリンク済みworktreeであり、
# サンドボックスのバインドマウント経由では .git ファイルが指す gitdir の絶対パスが
# 解決できず `fatal: not a git repository` になる環境依存の問題があるため。
# 実際に使う .gitattributes の内容を、worktree に依存しない素の一時リポジトリへ
# コピーして検証する（他のテストケースの make_temp_repo と同じ考え方）。
# ---------------------------------------------------------------------------

echo "== .gitattributes の eol=lf カバレッジ（回帰防止） =="

GITATTRIBUTES_TEST_REPO="$(make_temp_repo)"
cp "${REPO_ROOT}/.gitattributes" "${GITATTRIBUTES_TEST_REPO}/.gitattributes"
(
  cd "$GITATTRIBUTES_TEST_REPO" || exit 1
  git add .gitattributes
  git commit -q -m "add .gitattributes"
) >/dev/null 2>&1

check_eol_lf() {
  # check_eol_lf <repo> <プローブ用パス（repo内の任意の相対パスでよい）>
  # git check-attr eol の解決結果が lf なら true を返す（Docker 非依存）。
  local repo="$1" probe_path="$2"
  local eol
  eol="$(cd "$repo" && git check-attr eol -- "$probe_path" 2>/dev/null | sed -n 's/^.*: eol: //p')"
  [ "$eol" = "lf" ]
}

if check_eol_lf "$GITATTRIBUTES_TEST_REPO" "dev-workflow-gitattributes-probe.sh"; then
  pass ".gitattributes: *.sh の eol 解決が lf である"
else
  fail ".gitattributes: *.sh の eol 解決が lf である" "check-attr の解決結果が lf ではありませんでした"
fi

if check_eol_lf "$GITATTRIBUTES_TEST_REPO" "dev-workflow-gitattributes-probe.toml"; then
  pass ".gitattributes: *.toml の eol 解決が lf である"
else
  fail ".gitattributes: *.toml の eol 解決が lf である" "check-attr の解決結果が lf ではありませんでした"
fi

if check_eol_lf "$GITATTRIBUTES_TEST_REPO" "adapters/codex/overlays/dev-workflow-gitattributes-probe.toml"; then
  pass ".gitattributes: adapters/codex/overlays/ 配下の *.toml も eol=lf が効く"
else
  fail ".gitattributes: adapters/codex/overlays/ 配下の *.toml も eol=lf が効く" "check-attr の解決結果が lf ではありませんでした"
fi

if check_eol_lf "$GITATTRIBUTES_TEST_REPO" "codex-agents/dev-workflow-gitattributes-probe.toml"; then
  pass ".gitattributes: codex-agents/ 配下の *.toml も eol=lf が効く"
else
  fail ".gitattributes: codex-agents/ 配下の *.toml も eol=lf が効く" "check-attr の解決結果が lf ではありませんでした"
fi

if check_eol_lf "$GITATTRIBUTES_TEST_REPO" ".gitattributes"; then
  pass ".gitattributes: .gitattributes 自身の eol 解決も lf である（自己参照ルール）"
else
  fail ".gitattributes: .gitattributes 自身の eol 解決も lf である（自己参照ルール）" "check-attr の解決結果が lf ではありませんでした"
fi

# ---------------------------------------------------------------------------
# 役割定義・生成物に docker 直接呼び出しの記述が残っていない（回帰防止 #26）
#
# core/roles/evaluator.md の「テスト実行（サンドボックス内）」節が、イメージタグを
# hash 付けに変えた本Epicの変更に追随せず、`docker run --rm ... dev-sandbox:[project]` /
# `docker compose -f docker-compose.dev.yml exec app` という旧い直接呼び出しのまま
# 生成物（agents/evaluator.md・codex-agents/evaluator.toml）に伝播していた。
# Task #12・#13 が対象ファイル一覧に evaluator.md を含めていなかったことが原因なので、
# ファイル名を列挙するのではなく core/roles・agents・codex-agents をディレクトリごと
# 走査する。core/instructions.md も同じ理由で対象に含める。
# ---------------------------------------------------------------------------

echo "== 役割定義・生成物に docker 直接呼び出しの記述が残っていない（回帰防止 #26） =="

FORBIDDEN_SANDBOX_PATTERN='docker run --rm|dev-sandbox:\[project\]|docker compose -f docker-compose\.dev\.yml exec'

check_no_forbidden_sandbox_calls() {
  # check_no_forbidden_sandbox_calls <説明> <検査対象（ファイルまたはディレクトリ）>
  local desc="$1" target="$2"
  local hits
  hits="$(grep -rnE "$FORBIDDEN_SANDBOX_PATTERN" "$target" 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    pass "$desc"
  else
    fail "$desc" "$hits"
  fi
}

check_no_forbidden_sandbox_calls "core/roles/ に docker 直接呼び出しが残っていない" "${REPO_ROOT}/core/roles"
check_no_forbidden_sandbox_calls "core/instructions.md に docker 直接呼び出しが残っていない" "${REPO_ROOT}/core/instructions.md"
check_no_forbidden_sandbox_calls "agents/ に docker 直接呼び出しが残っていない" "${REPO_ROOT}/agents"
check_no_forbidden_sandbox_calls "codex-agents/ に docker 直接呼び出しが残っていない" "${REPO_ROOT}/codex-agents"

# ---------------------------------------------------------------------------
# check-readability.sh: 複数行フックJSONの読み取り（回帰防止 #31）
#
# Task #10 のハング修正で stdin を「上限付きで読む」形にした際、実装が
# `read -r -t` を1回しか呼ばず先頭1行しか読んでいなかった。フック入力は
# 整形された（複数行の）JSONで来ることがあり、1行目に file_path が無い場合
# 検査対象を取りこぼして警告もログも無く exit 0 してしまう欠陥があった
# （可読性ガードが最優先で守るルールが、入力形式の差で黙って無効化される）。
#
# ここでは stdin 全体をタイムアウト付きで読み切る修正後の実装が、
#   1) 複数行JSONでも file_path を抽出して違反を検出できること
#   2) 1行目に file_path が無い複数行JSONでも検出できること
#   3) Task #10 で固定した「stdinを開いたままでもハングしない」性質を
#      壊していないこと
# を確認する。
# ---------------------------------------------------------------------------

echo "== check-readability.sh（複数行フックJSONの読み取り・回帰防止 #31） =="

RG31_TMP_REPO="$(make_temp_repo)"
RG31_VIOLATION_FILE="violation.txt"
(
  cd "$RG31_TMP_REPO" || exit 1
  head -c 3000 /dev/zero | tr '\0' 'A' > "$RG31_VIOLATION_FILE"
) >/dev/null 2>&1

# --- 整形された（複数行の）フックJSON。file_path は先頭行ではなく途中の行にある ---
RG31_MULTILINE_JSON=$(cat <<EOF
{
  "session_id": "abc123",
  "tool_input": {
    "file_path": "${RG31_VIOLATION_FILE}"
  },
  "tool_name": "Write"
}
EOF
)

RG31_MULTILINE_EXIT=0
(
  cd "$RG31_TMP_REPO" || exit 1
  printf '%s' "$RG31_MULTILINE_JSON" \
    | READABILITY_MAX_BASE64=50 bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG31_MULTILINE_EXIT=$?
assert_exit_code "複数行に整形されたフックJSONでもfile_pathを抽出して違反を検出する" 2 "$RG31_MULTILINE_EXIT"

# --- 1行目に file_path が無い複数行JSON（file_path はJSONの末尾近くの行にある） ---
RG31_LATE_FIELD_JSON=$(cat <<EOF
{
  "session_id": "abc123",
  "cwd": "/tmp/somewhere",
  "hook_event_name": "PostToolUse",
  "tool_name": "Write",
  "tool_input": {
    "content": "dummy",
    "file_path": "${RG31_VIOLATION_FILE}"
  }
}
EOF
)

RG31_LATE_FIELD_EXIT=0
(
  cd "$RG31_TMP_REPO" || exit 1
  printf '%s' "$RG31_LATE_FIELD_JSON" \
    | READABILITY_MAX_BASE64=50 bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG31_LATE_FIELD_EXIT=$?
assert_exit_code "1行目にfile_pathが無い複数行JSONでも検出できる" 2 "$RG31_LATE_FIELD_EXIT"

# --- 上記と同じ複数行JSONで、クリーンなファイルならexit 0（誤検出しないことの確認） ---
RG31_CLEAN_FILE="clean-multiline.txt"
(
  cd "$RG31_TMP_REPO" || exit 1
  printf 'clean file\n' > "$RG31_CLEAN_FILE"
) >/dev/null 2>&1

RG31_CLEAN_MULTILINE_JSON=$(cat <<EOF
{
  "session_id": "abc123",
  "tool_input": {
    "file_path": "${RG31_CLEAN_FILE}"
  }
}
EOF
)

RG31_CLEAN_MULTILINE_EXIT=0
(
  cd "$RG31_TMP_REPO" || exit 1
  printf '%s' "$RG31_CLEAN_MULTILINE_JSON" | bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG31_CLEAN_MULTILINE_EXIT=$?
assert_exit_code "複数行JSONでもクリーンなファイルはexit 0（誤検出しない）" 0 "$RG31_CLEAN_MULTILINE_EXIT"

# --- Task #10 の性質を壊していないことの再確認: stdinを開いたまま --git を叩いても即座に返る ---
# RG31_TMP_REPO には未追跡の違反ファイル（violation.txt等）があるため、
# --git で検査すれば違反検出（exit 2）になり得る。ここで確認したいのは
# 「ハングしないこと」だけなので、違反ファイルの無いクリーンな一時リポジトリを別途使う。
RG31_HANG_REPO="$(make_temp_repo)"
RG31_GIT_HANG_EXIT=0
(
  cd "$RG31_HANG_REPO" || exit 1
  timeout 8 bash "$CHECK_READABILITY_SCRIPT" --git < <(sleep 30) >/dev/null 2>&1
)
RG31_GIT_HANG_EXIT=$?
assert_exit_code "stdinを開いたまま--gitを叩いても即座に返る（ハング再発なし）" 0 "$RG31_GIT_HANG_EXIT"

# --- 引数なし・非ttyで入力が来ない場合も、複数行読み取りに変えた後で引き続きタイムアウトする ---
RG31_TIMEOUT_EXIT=0
(
  cd "$RG31_HANG_REPO" || exit 1
  timeout 8 env READABILITY_STDIN_TIMEOUT=1 bash "$CHECK_READABILITY_SCRIPT" \
    < <(sleep 30) >/dev/null 2>&1
)
RG31_TIMEOUT_EXIT=$?
assert_exit_code "複数行読み取りに変えた後も、入力が来ない場合はタイムアウトしてexit 0で素通りする" 0 "$RG31_TIMEOUT_EXIT"

# ---------------------------------------------------------------------------
# compose: --down --all / --ls の project 絞り込み（レビュー2巡目 issue #32 / #33 / #34）
#
# list_compose_projects_in_repo() は本Epicのレビューで次の2点を指摘された:
#   - issue #32: docker ps のフォーマットで `{{ index .Labels "..." }}` を使っていたが、
#     `docker ps` コンテキストでは .Labels は map ではなく文字列であり必ず失敗する。
#     正しくは `{{.Label "..."}}`。失敗を 2>/dev/null で握り潰さず、非0終了時は
#     stderr に警告を出すことも合わせて固定する。
#   - issue #33: 絞り込みが project 名の接頭辞一致だけで、他リポジトリ（basename が
#     接頭辞になる／同じ basename を別ディレクトリにクローンした）の project を
#     巻き込みうる。正しくは com.docker.compose.project.working_dir label
#     （--project-directory に渡した値）を正規化して HOST_ROOT 配下のものだけを対象にする。
#
# 上記2つの穴は、偽 docker が compose モードの `ps`（-a なし・ありの両方）を
# 未実装（*) exit 1）だったため一度もテストされていなかった（issue #34）。
# FAKE_DOCKER_COMPOSE に「project|working_dir|running」形式のマニフェストで駆動する
# ps 実装を追加した（DW_COMPOSE_PROJECTS_MANIFEST）ので、ここでそれを使って固定する。
# 実 docker には一切触れない。
# ---------------------------------------------------------------------------

echo "== compose: --down --all / --ls の project 絞り込み（issue #32 / #33 / #34） =="

COMPOSE_PROJECTS_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-composeprojlog.XXXXXX")"
COMPOSE_PROJECTS_STATE="$(mktemp "${TMPDIR:-/tmp}/dw-test-composeprojstate.XXXXXX")"
: > "$COMPOSE_PROJECTS_STATE"

COMPOSE_PROJECTS_MANIFEST_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-composeprojects.XXXXXX")"

# 他リポジトリのマウント元は正規化後も HOST_ROOT と一致しない、実在しないダミーパスでよい。
COMPOSE_OTHER_CLONE_ROOT="/some/other/clone/root"
COMPOSE_UNRELATED_ROOT="/home/user/otherrepo"

# 1) 自リポジトリ・epicなし（--project-directory は常に HOST_ROOT）
# 2) 自リポジトリ・epicあり（working_dir は同じ HOST_ROOT）
# 3) 他リポジトリ。project 名は自リポジトリの basename が接頭辞になっている
#    （旧・接頭辞一致ロジックなら誤って巻き込んでいた。working_dir は無関係な別root）
# 4) 自リポジトリと「同名」の project だが working_dir が別root
#    （同じ basename を別ディレクトリにクローンした場合を模す。issue #33 (b) / (c)）
# 5) 全く無関係な他リポジトリ
cat > "$COMPOSE_PROJECTS_MANIFEST_FILE" <<MANIFEST
dw-${COMPOSE_REPO_BASENAME}|${COMPOSE_HOST_ROOT}|running
dw-${COMPOSE_REPO_BASENAME}-epicx|${COMPOSE_HOST_ROOT}|stopped
dw-${COMPOSE_REPO_BASENAME}-otherclone|${COMPOSE_OTHER_CLONE_ROOT}|running
dw-${COMPOSE_REPO_BASENAME}|${COMPOSE_OTHER_CLONE_ROOT}|running
dw-otherrepo|${COMPOSE_UNRELATED_ROOT}|running
MANIFEST

run_compose_projects_case() {
  # run_compose_projects_case <sandbox-exec.shへの引数...>
  (
    cd "$COMPOSE_REPO" || exit 1
    DW_COMPOSE_LOG="$COMPOSE_PROJECTS_LOG" \
      DW_COMPOSE_SERVICE_STATE="$COMPOSE_PROJECTS_STATE" \
      DW_COMPOSE_PROJECTS_MANIFEST="$COMPOSE_PROJECTS_MANIFEST_FILE" \
      PATH="${FAKE_DOCKER_COMPOSE_DIR}:${PATH}" \
      bash scripts/sandbox-exec.sh "$@"
  )
}

# --- --ls は自リポジトリの compose project の状態のみ表示する（issue #34 の3点目） ---
: > "$COMPOSE_PROJECTS_LOG"
COMPOSE_LS_OUTPUT="$(run_compose_projects_case --ls)"

case "$COMPOSE_LS_OUTPUT" in
  *"dw-${COMPOSE_REPO_BASENAME}"*"running"*)
    pass "compose: --ls は自リポジトリの compose project を running で表示する" ;;
  *)
    fail "compose: --ls は自リポジトリの compose project を running で表示する" \
      "output=[${COMPOSE_LS_OUTPUT}]" ;;
esac

case "$COMPOSE_LS_OUTPUT" in
  *"dw-${COMPOSE_REPO_BASENAME}-epicx"*"stopped"*)
    pass "compose: --ls は自リポジトリの別epic project を stopped で表示する" ;;
  *)
    fail "compose: --ls は自リポジトリの別epic project を stopped で表示する" \
      "output=[${COMPOSE_LS_OUTPUT}]" ;;
esac

if printf '%s\n' "$COMPOSE_LS_OUTPUT" | grep -q "otherclone"; then
  fail "compose: --ls は basename が接頭辞一致するだけの他リポジトリ project を表示しない（issue #33）" \
    "output=[${COMPOSE_LS_OUTPUT}]"
else
  pass "compose: --ls は basename が接頭辞一致するだけの他リポジトリ project を表示しない（issue #33）"
fi

if printf '%s\n' "$COMPOSE_LS_OUTPUT" | grep -q "otherrepo"; then
  fail "compose: --ls は無関係な他リポジトリ project を表示しない" "output=[${COMPOSE_LS_OUTPUT}]"
else
  pass "compose: --ls は無関係な他リポジトリ project を表示しない"
fi

# --- --down --all は自リポジトリの project すべてを down し、他リポジトリは down しない（issue #34 の1・2点目） ---
: > "$COMPOSE_PROJECTS_LOG"
COMPOSE_DOWN_ALL_EXIT=0
run_compose_projects_case --down --all >/dev/null 2>&1 || COMPOSE_DOWN_ALL_EXIT=$?
assert_exit_code "compose: --down --all は成功する" 0 "$COMPOSE_DOWN_ALL_EXIT"

DOWN_ALL_LOG_CONTENT="$(cat "$COMPOSE_PROJECTS_LOG")"

DOWN_COUNT_SELF_NOEPIC="$(printf '%s\n' "$DOWN_ALL_LOG_CONTENT" \
  | grep -Fc "compose -p dw-${COMPOSE_REPO_BASENAME} --project-directory ${COMPOSE_HOST_ROOT} -f docker-compose.dev.yml down" || true)"
assert_eq "compose: --down --all は自リポジトリの project（epicなし）を down する（issue #34）" "1" "$DOWN_COUNT_SELF_NOEPIC"

DOWN_COUNT_SELF_EPIC="$(printf '%s\n' "$DOWN_ALL_LOG_CONTENT" \
  | grep -Fc "compose -p dw-${COMPOSE_REPO_BASENAME}-epicx --project-directory ${COMPOSE_HOST_ROOT} -f docker-compose.dev.yml down" || true)"
assert_eq "compose: --down --all は自リポジトリの別epic project も down する（issue #34）" "1" "$DOWN_COUNT_SELF_EPIC"

if printf '%s\n' "$DOWN_ALL_LOG_CONTENT" | grep -q "otherclone"; then
  fail "compose: --down --all は basename が接頭辞一致するだけの他リポジトリ project を down しない（issue #33）" \
    "log=[${DOWN_ALL_LOG_CONTENT}]"
else
  pass "compose: --down --all は basename が接頭辞一致するだけの他リポジトリ project を down しない（issue #33）"
fi

if printf '%s\n' "$DOWN_ALL_LOG_CONTENT" | grep -q "otherrepo"; then
  fail "compose: --down --all は無関係な他リポジトリ project を down しない" "log=[${DOWN_ALL_LOG_CONTENT}]"
else
  pass "compose: --down --all は無関係な他リポジトリ project を down しない"
fi

# 同名別root（issue #33 (b)/(c)）: 自プロジェクトと同一名だが working_dir が別のエントリが
# マニフェストに混在していても、down 呼び出しの総数は自リポジトリ分の2件のまま増えない。
DOWN_TOTAL_COUNT="$(printf '%s\n' "$DOWN_ALL_LOG_CONTENT" | grep -c '^compose -p .* down$' || true)"
assert_eq "compose: --down --all は同名別rootの混在があっても自リポジトリ分の2件だけを down する（issue #33）" \
  "2" "$DOWN_TOTAL_COUNT"

# --- issue #32 の直接検証: docker ps のフォーマットに .Label を使い、.Labels は使わない ---
if printf '%s\n' "$DOWN_ALL_LOG_CONTENT" | grep -qF '.Label "com.docker.compose.project"'; then
  pass "compose: docker ps のフォーマットに .Label を使う（issue #32）"
else
  fail "compose: docker ps のフォーマットに .Label を使う（issue #32）" "log=[${DOWN_ALL_LOG_CONTENT}]"
fi

if printf '%s\n' "$DOWN_ALL_LOG_CONTENT" | grep -qF 'index .Labels'; then
  fail "compose: docker ps のフォーマットに index .Labels を使わない（issue #32）" "log=[${DOWN_ALL_LOG_CONTENT}]"
else
  pass "compose: docker ps のフォーマットに index .Labels を使わない（issue #32）"
fi

# --- issue #32: docker ps 失敗時は stderr に警告を出し、--ls 自体は非0で落ちない ---
: > "$COMPOSE_PROJECTS_LOG"
COMPOSE_PS_FAIL_STDERR="$(
  cd "$COMPOSE_REPO" || exit 1
  DW_COMPOSE_LOG="$COMPOSE_PROJECTS_LOG" \
    DW_COMPOSE_SERVICE_STATE="$COMPOSE_PROJECTS_STATE" \
    DW_COMPOSE_PROJECTS_MANIFEST="$COMPOSE_PROJECTS_MANIFEST_FILE" \
    DW_COMPOSE_PS_FAIL=1 \
    PATH="${FAKE_DOCKER_COMPOSE_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --ls 2>&1 1>/dev/null
)"

case "$COMPOSE_PS_FAIL_STDERR" in
  *"WARNING"*"docker ps"*)
    pass "compose: docker ps の失敗を握り潰さず stderr に警告する（issue #32）" ;;
  *)
    fail "compose: docker ps の失敗を握り潰さず stderr に警告する（issue #32）" \
      "stderr=[${COMPOSE_PS_FAIL_STDERR}]" ;;
esac

COMPOSE_PS_FAIL_EXIT=0
(
  cd "$COMPOSE_REPO" || exit 1
  DW_COMPOSE_LOG="$COMPOSE_PROJECTS_LOG" \
    DW_COMPOSE_SERVICE_STATE="$COMPOSE_PROJECTS_STATE" \
    DW_COMPOSE_PROJECTS_MANIFEST="$COMPOSE_PROJECTS_MANIFEST_FILE" \
    DW_COMPOSE_PS_FAIL=1 \
    PATH="${FAKE_DOCKER_COMPOSE_DIR}:${PATH}" \
    bash scripts/sandbox-exec.sh --ls >/dev/null 2>&1
)
COMPOSE_PS_FAIL_EXIT=$?
assert_exit_code "compose: docker ps の列挙に失敗しても --ls 自体は成功する（compose project欄なしで継続）" \
  0 "$COMPOSE_PS_FAIL_EXIT"

# ---------------------------------------------------------------------------
# check-readability.sh: 外部 `timeout` コマンドへの非依存化（回帰防止 #35・レビュー2巡目）
#
# #31 の修正で stdin 読み取りを `timeout "$secs" cat` に丸ごと委譲するようになったが、
# `timeout` は GNU coreutils / BusyBox のコマンドで macOS の既定環境には無い
# （`gtimeout` のみ）。command not found（status 127）を「入力が来なかった」と
# 誤判定し、macOS では可読性ガードの PostToolUse フック経路が常時無効化されて
# いた（#31 が問題視した「入力形式の差でガードが黙って無効化される」のと
# 同じ事故が環境の差で再現していた）。
#
# 修正後は bash 組み込みの `read -t` だけで複数行を読み切り、外部コマンドに
# 依存しない。ここでは
#   1) 末尾に改行の無い入力でも最終行（file_path）を取りこぼさないこと
#   2) PATH から timeout/gtimeout を完全に排除した環境でも、複数行JSONの
#      違反検出・クリーン判定・タイムアウト・--gitのハング防止が
#      引き続き機能すること
# を確認する。
# ---------------------------------------------------------------------------

echo "== check-readability.sh（外部timeoutコマンドへの非依存化・回帰防止 #35） =="

RG35_TMP_REPO="$(make_temp_repo)"
RG35_VIOLATION_FILE="violation.txt"
(
  cd "$RG35_TMP_REPO" || exit 1
  head -c 3000 /dev/zero | tr '\0' 'A' > "$RG35_VIOLATION_FILE"
) >/dev/null 2>&1

# --- 末尾に改行の無いフックJSONでも最終行(file_path)を取りこぼさず違反を検出する ---
RG35_NO_TRAILING_NEWLINE_JSON="$(printf '{\n  "tool_input": {\n    "file_path": "%s"\n  }\n}' "$RG35_VIOLATION_FILE")"

# 検証用入力の末尾に改行が無いこと自体を前提として固定しておく
case "$RG35_NO_TRAILING_NEWLINE_JSON" in
  *$'\n') fail "検証用入力の末尾に改行が無い（前提）" "末尾に改行がありました" ;;
  *) pass "検証用入力の末尾に改行が無い（前提）" ;;
esac

RG35_NO_TRAILING_NEWLINE_EXIT=0
(
  cd "$RG35_TMP_REPO" || exit 1
  printf '%s' "$RG35_NO_TRAILING_NEWLINE_JSON" \
    | READABILITY_MAX_BASE64=50 bash "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG35_NO_TRAILING_NEWLINE_EXIT=$?
assert_exit_code "末尾に改行の無いフックJSONでも最終行(file_path)を取りこぼさず違反を検出する" 2 "$RG35_NO_TRAILING_NEWLINE_EXIT"

# --- PATHから timeout/gtimeout を排除した環境を構築する ---
# 目的は「timeout/gtimeoutが見つからないPATH」を作ることだけなので、以下で
# 実行する check-readability.sh が実際に必要とするコマンド（grep/sed/awk/git/head）
# に加えて、保守的に使われうるもの（bash/env/cat/tr/printf）だけを対象にする。
# timeout/gtimeout を除外する目的はこれまでと変わらない。
#
# 以前はPATH上の全ファイルを `ln -sf` でリンクしていたが、Windows(Git Bash/MSYS)
# では `ln -s` がシンボリックリンクではなく実体コピーになり、PATH上の実行ファイル
# （数百MB級のものを含む）を丸ごと複製してしまい、1回の実行で最大36GBを消費して
# ディスクを枯渇させた（#78）。
#
# 対象をホワイトリスト化しても、コピー先に本体だけを置くと Windows(MSYS) では
# 依存する共有ライブラリ（msys-2.0.dll 等、実行ファイルと同じディレクトリを見に
# 行く）が見つからずロードに失敗する。実行ファイル自体は元の場所から動かさず、
# 元の絶対パスをそのまま呼び出すだけの数十バイトのシムスクリプトを置くことで、
# コピー量をほぼゼロにしつつ依存ライブラリの問題も同時に回避する。
build_path_without_timeout() {
  local dest="$1"
  local cmd cmd_path
  for cmd in bash grep sed awk git env cat head tr printf; do
    cmd_path="$(command -v "$cmd" 2>/dev/null)" || continue
    [ -n "$cmd_path" ] && [ -e "$cmd_path" ] || continue
    [ -e "${dest}/${cmd}" ] && continue
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$cmd_path" > "${dest}/${cmd}" 2>/dev/null
    chmod +x "${dest}/${cmd}" 2>/dev/null
  done
}

RG35_NOTIMEOUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-notimeout-bin.XXXXXX")"
# 正常終了・異常終了（割り込み等）のいずれでも必ず削除する。長いファイル名
# （DLL等）で個々の削除が失敗してもテスト全体を失敗させない（#78）。
# この trap は RG35 のテストブロックを抜けた直後に明示的に解除する
# （tests/run-tests.sh 内の他の EXIT trap（wd_cleanup_all）と共存させるため）。
trap 'rm -rf "$RG35_NOTIMEOUT_DIR" 2>/dev/null || true' EXIT
build_path_without_timeout "$RG35_NOTIMEOUT_DIR"
RG35_BASH_BIN="$(command -v bash)"

# 構築したPATHに timeout/gtimeout が存在しないこと自体を前提として固定しておく
# （この前提が崩れていたら以降のテストは無意味なので、まず単独で確認する）。
if PATH="$RG35_NOTIMEOUT_DIR" command -v timeout >/dev/null 2>&1 \
  || PATH="$RG35_NOTIMEOUT_DIR" command -v gtimeout >/dev/null 2>&1; then
  fail "検証用PATHにtimeout/gtimeoutが存在しない（前提）" "timeoutまたはgtimeoutが見つかりました"
else
  pass "検証用PATHにtimeout/gtimeoutが存在しない（前提）"
fi

# --- timeoutコマンドがPATHに無くても、複数行に整形されたフックJSONの違反を検出できる ---
RG35_MULTILINE_JSON=$(cat <<EOF
{
  "session_id": "abc123",
  "tool_input": {
    "file_path": "${RG35_VIOLATION_FILE}"
  },
  "tool_name": "Write"
}
EOF
)

RG35_MULTILINE_EXIT=0
(
  cd "$RG35_TMP_REPO" || exit 1
  printf '%s' "$RG35_MULTILINE_JSON" \
    | PATH="$RG35_NOTIMEOUT_DIR" READABILITY_MAX_BASE64=50 "$RG35_BASH_BIN" "$CHECK_READABILITY_SCRIPT" \
      >/dev/null 2>&1
)
RG35_MULTILINE_EXIT=$?
assert_exit_code "timeoutコマンドがPATHに無くても複数行JSONの違反を検出する" 2 "$RG35_MULTILINE_EXIT"

# --- timeoutコマンドがPATHに無くても、クリーンなファイルはexit 0（誤検出しない） ---
RG35_CLEAN_FILE="clean-notimeout.txt"
(
  cd "$RG35_TMP_REPO" || exit 1
  printf 'clean file\n' > "$RG35_CLEAN_FILE"
) >/dev/null 2>&1

RG35_CLEAN_JSON=$(cat <<EOF
{
  "tool_input": {
    "file_path": "${RG35_CLEAN_FILE}"
  }
}
EOF
)

RG35_CLEAN_EXIT=0
(
  cd "$RG35_TMP_REPO" || exit 1
  printf '%s' "$RG35_CLEAN_JSON" \
    | PATH="$RG35_NOTIMEOUT_DIR" "$RG35_BASH_BIN" "$CHECK_READABILITY_SCRIPT" >/dev/null 2>&1
)
RG35_CLEAN_EXIT=$?
assert_exit_code "timeoutコマンドがPATHに無くてもクリーンなファイルはexit 0（誤検出しない）" 0 "$RG35_CLEAN_EXIT"

# --- timeoutコマンドがPATHに無くても、入力が来ない場合はハングせずタイムアウトしてexit 0 ---
RG35_NOINPUT_EXIT=0
(
  cd "$RG35_TMP_REPO" || exit 1
  timeout 8 env READABILITY_STDIN_TIMEOUT=1 PATH="$RG35_NOTIMEOUT_DIR" "$RG35_BASH_BIN" \
    "$CHECK_READABILITY_SCRIPT" < <(sleep 30) >/dev/null 2>&1
)
RG35_NOINPUT_EXIT=$?
assert_exit_code "timeoutコマンドがPATHに無くても、入力が来ない場合はハングせずタイムアウトしてexit 0で素通りする" \
  0 "$RG35_NOINPUT_EXIT"

# --- timeoutコマンドがPATHに無くても、stdinを開いたまま--gitを叩けば即座に返る（ハング再発なし） ---
# RG35_TMP_REPO には未追跡の違反ファイル（violation.txt等、上のテストで作成）が残っている
# ため、--git で検査すると（MAX_BASE64を上書きしていない既定値2000のもとでは）violation.txt
# 自体が正規表現の対象文字数を超えて違反検出（exit 2）になり得る。ここで確認したいのは
# 「ハングしないこと」だけなので、RG31（#31, tests/run-tests.sh:2526-2530）と同様に、
# 違反ファイルの無いクリーンな一時リポジトリを別途使う。
RG35_HANG_REPO="$(make_temp_repo)"
RG35_GIT_HANG_EXIT=0
(
  cd "$RG35_HANG_REPO" || exit 1
  timeout 8 env PATH="$RG35_NOTIMEOUT_DIR" "$RG35_BASH_BIN" "$CHECK_READABILITY_SCRIPT" --git \
    < <(sleep 30) >/dev/null 2>&1
)
RG35_GIT_HANG_EXIT=$?
assert_exit_code "timeoutコマンドがPATHに無くても、stdinを開いたまま--gitを叩けば即座に返る" 0 "$RG35_GIT_HANG_EXIT"

# RG35用の一時PATHディレクトリはもう不要なので、ここで確実に片付ける。
# 以降の実行で他のEXIT trap（wd_cleanup_all等）が設定されても上書き競合しないよう、
# 自分のtrapもここで明示的に解除する。
rm -rf "$RG35_NOTIMEOUT_DIR" 2>/dev/null || true
trap - EXIT

# ---------------------------------------------------------------------------
# plan-waves.sh（依存グラフとウェーブ分解、Task #15、Epic #14 仕様書 5.2）
#
# --from-file はタブ区切り、1行1タスク: <番号>\t<state:open|closed>\t<前提行の生テキスト>。
# 前提行が空文字列＝「- 前提:」行そのものが無い（宣言漏れ）を意味する。docker には一切触れない。
# ---------------------------------------------------------------------------

echo "== plan-waves.sh（依存グラフとウェーブ分解） =="

PLAN_WAVES_SCRIPT="${REPO_ROOT}/scripts/plan-waves.sh"

pw_value() {
  # pw_value <task番号> <field> <output>
  # 出力の "task <n> wave <W> subbatch <S> deps <deps>" 行から field の値を取り出す
  printf '%s\n' "$3" | awk -F'\t' -v n="$1" -v f="$2" '
    $1=="task" && $2==n {
      for (i=1; i<=NF; i++) { if ($i==f) { print $(i+1); exit } }
    }'
}

pw_wave_tasks() {
  # pw_wave_tasks <wave番号> <output>
  printf '%s\n' "$2" | awk -F'\t' -v w="$1" '$1=="wave" && $2==w {print $4}'
}

# --- ケース1: Epic #3 の実 issue データ（#4〜#13 の "- 前提:" 宣言）で6ウェーブになる ---
# #4 は実際に「- 前提:」行が無い（宣言漏れの実例）。fail-safe は「自分より番号が小さい
# 全タスクに依存」だが、#4 は最小番号なので依存は空になり、警告だけが出る。
PW_EPIC3_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-epic3.XXXXXX")"
cat > "$PW_EPIC3_FIXTURE" <<'FIXTURE'
4	open
5	open	- 前提: #4
6	open	- 前提: #5（label による所属判定を使う）
7	open	- 前提: #6
8	open	- 前提: #5
9	open	- 前提: #5
10	open	- 前提: #4
11	open	- 前提: #4
12	open	- 前提: #7, #9, #11（全実装の完了後）
13	open	- 前提: #12
FIXTURE

PW_EPIC3_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_EPIC3_FIXTURE")"
PW_EPIC3_EXIT=$?

assert_exit_code "Epic #3 実データ: exit 0" 0 "$PW_EPIC3_EXIT"
assert_eq "Epic #3 実データ: 既定の lanes は3" "3" "$(printf '%s\n' "$PW_EPIC3_OUTPUT" | awk -F'\t' '$1=="lanes"{print $2}')"
assert_eq "Epic #3 実データ: W1={4}" "4" "$(pw_wave_tasks 1 "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: W2={5,10,11}" "5,10,11" "$(pw_wave_tasks 2 "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: W3={6,8,9}" "6,8,9" "$(pw_wave_tasks 3 "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: W4={7}" "7" "$(pw_wave_tasks 4 "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: W5={12}" "12" "$(pw_wave_tasks 5 "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: W6={13}" "13" "$(pw_wave_tasks 6 "$PW_EPIC3_OUTPUT")"

if printf '%s\n' "$PW_EPIC3_OUTPUT" | grep -q '^wave	7	'; then
  fail "Epic #3 実データ: ウェーブは6個で打ち止め（W7が存在しない）"
else
  pass "Epic #3 実データ: ウェーブは6個で打ち止め（W7が存在しない）"
fi

assert_eq "Epic #3 実データ: #12 の deps は 7,9,11" "7,9,11" "$(pw_value 12 deps "$PW_EPIC3_OUTPUT")"
assert_eq "Epic #3 実データ: #4 は実際に宣言漏れ（前提行が無い）として警告される" \
  "1" "$(printf '%s\n' "$PW_EPIC3_OUTPUT" | grep -c '^warn	missing-deps	4$')"

# --- ケース2: --lanes 2 でウェーブ2が {5,10} と {11} のサブバッチに割れる ---
PW_LANES2_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_EPIC3_FIXTURE" --lanes 2)"

assert_eq "--lanes 2: #5 は subbatch 1" "1" "$(pw_value 5 subbatch "$PW_LANES2_OUTPUT")"
assert_eq "--lanes 2: #10 は subbatch 1" "1" "$(pw_value 10 subbatch "$PW_LANES2_OUTPUT")"
assert_eq "--lanes 2: #11 は subbatch 2" "2" "$(pw_value 11 subbatch "$PW_LANES2_OUTPUT")"

# --- ケース3: 「- 前提:」行が無いタスクが「自分より小さい全タスクに依存」となり、
#     全件宣言漏れなら完全逐次になる ---
PW_SERIAL_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-serial.XXXXXX")"
cat > "$PW_SERIAL_FIXTURE" <<'FIXTURE'
501	open
502	open
503	open
FIXTURE

PW_SERIAL_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_SERIAL_FIXTURE")"

assert_eq "宣言漏れの完全逐次: #501 は wave1（依存なし）" "1" "$(pw_value 501 wave "$PW_SERIAL_OUTPUT")"
assert_eq "宣言漏れの完全逐次: #502 は wave2（#501 に依存）" "2" "$(pw_value 502 wave "$PW_SERIAL_OUTPUT")"
assert_eq "宣言漏れの完全逐次: #503 は wave3（#501,#502 に依存）" "3" "$(pw_value 503 wave "$PW_SERIAL_OUTPUT")"
assert_eq "宣言漏れの完全逐次: #503 の deps は 501,502" "501,502" "$(pw_value 503 deps "$PW_SERIAL_OUTPUT")"
PW_SERIAL_MISSING_COUNT="$(printf '%s\n' "$PW_SERIAL_OUTPUT" | grep -c '^warn	missing-deps	')"
assert_eq "宣言漏れの完全逐次: 3件すべてに missing-deps 警告が出る" "3" "$PW_SERIAL_MISSING_COUNT"

# --- ケース4: 循環依存で exit 3 になり、循環に含まれるタスクが列挙される ---
PW_CYCLE_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-cycle.XXXXXX")"
cat > "$PW_CYCLE_FIXTURE" <<'FIXTURE'
601	open	- 前提: #602
602	open	- 前提: #601
FIXTURE

PW_CYCLE_STDERR="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_CYCLE_FIXTURE" 2>&1 1>/dev/null)"
PW_CYCLE_EXIT=$?

assert_exit_code "循環依存: exit 3" 3 "$PW_CYCLE_EXIT"
case "$PW_CYCLE_STDERR" in
  *"601"*"602"*|*"602"*"601"*) pass "循環依存: 循環に含まれる両タスクがエラーに列挙される" ;;
  *) fail "循環依存: 循環に含まれる両タスクがエラーに列挙される" "stderr=[${PW_CYCLE_STDERR}]" ;;
esac

# --- ケース5: Epic外・存在しない issue への依存が warn unknown-dep として報告され、無視される ---
PW_UNKNOWN_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-unknown.XXXXXX")"
cat > "$PW_UNKNOWN_FIXTURE" <<'FIXTURE'
701	open	- 前提: #999
FIXTURE

PW_UNKNOWN_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_UNKNOWN_FIXTURE")"

assert_eq "unknown-dep: 未知の依存は警告として報告される" "1" \
  "$(printf '%s\n' "$PW_UNKNOWN_OUTPUT" | grep -c '^warn	unknown-dep	701	999$')"
assert_eq "unknown-dep: 未知の依存は無視され #701 は wave1 になる" "1" "$(pw_value 701 wave "$PW_UNKNOWN_OUTPUT")"
assert_eq "unknown-dep: #701 の deps は空（未知の依存を数えない）" "" "$(pw_value 701 deps "$PW_UNKNOWN_OUTPUT")"

# --- ケース6: --skipped の伝播が推移的に効く ---
PW_SKIP_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-skip.XXXXXX")"
cat > "$PW_SKIP_FIXTURE" <<'FIXTURE'
801	open
802	open	- 前提: #801
803	open	- 前提: #802
FIXTURE

PW_SKIP_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_SKIP_FIXTURE" --skipped 802)"

if printf '%s\n' "$PW_SKIP_OUTPUT" | grep -q '^task	802	'; then
  fail "スキップ伝播: 明示的にスキップした #802 はタスク一覧に出ない" "output=[${PW_SKIP_OUTPUT}]"
else
  pass "スキップ伝播: 明示的にスキップした #802 はタスク一覧に出ない"
fi

if printf '%s\n' "$PW_SKIP_OUTPUT" | grep -q '^task	803	'; then
  fail "スキップ伝播: #802 に依存する #803 も推移的にスキップされタスク一覧に出ない" "output=[${PW_SKIP_OUTPUT}]"
else
  pass "スキップ伝播: #802 に依存する #803 も推移的にスキップされタスク一覧に出ない"
fi

assert_eq "スキップ伝播: #803 の skip 行に理由（依存先 #802）が出る" "1" \
  "$(printf '%s\n' "$PW_SKIP_OUTPUT" | grep -c '^skip	803	reason	depends-on-skipped	802$')"

if printf '%s\n' "$PW_SKIP_OUTPUT" | grep -q '^task	801	'; then
  pass "スキップ伝播: スキップに依存しない #801 は影響を受けない"
else
  fail "スキップ伝播: スキップに依存しない #801 は影響を受けない" "output=[${PW_SKIP_OUTPUT}]"
fi

# --- ケース7: クローズ済み issue への依存が充足済みとして扱われる ---
PW_CLOSED_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-closed.XXXXXX")"
cat > "$PW_CLOSED_FIXTURE" <<'FIXTURE'
901	closed
902	open	- 前提: #901
FIXTURE

PW_CLOSED_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_CLOSED_FIXTURE")"

assert_eq "closed依存: クローズ済み依存は充足済みとして扱われ #902 は wave1 になる" "1" "$(pw_value 902 wave "$PW_CLOSED_OUTPUT")"
assert_eq "closed依存: #902 の deps は空（クローズ済みを数えない）" "" "$(pw_value 902 deps "$PW_CLOSED_OUTPUT")"
if printf '%s\n' "$PW_CLOSED_OUTPUT" | grep -q '^task	901	'; then
  fail "closed依存: クローズ済みタスク自体はウェーブ計画の対象に含まれない" "output=[${PW_CLOSED_OUTPUT}]"
else
  pass "closed依存: クローズ済みタスク自体はウェーブ計画の対象に含まれない"
fi
if printf '%s\n' "$PW_CLOSED_OUTPUT" | grep -q '^warn	unknown-dep	902	901$'; then
  fail "closed依存: クローズ済み依存は unknown-dep として警告されない" "output=[${PW_CLOSED_OUTPUT}]"
else
  pass "closed依存: クローズ済み依存は unknown-dep として警告されない"
fi

# --- ケース8: --print が人間向けの表を出す（ドライラン） ---
PW_PRINT_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_EPIC3_FIXTURE" --print)"

case "$PW_PRINT_OUTPUT" in
  *"ウェーブ分解"*) pass "--print: 人間向けの見出しが出る" ;;
  *) fail "--print: 人間向けの見出しが出る" "output=[${PW_PRINT_OUTPUT}]" ;;
esac
case "$PW_PRINT_OUTPUT" in
  *"lanes"$'\t'*) fail "--print: 機械可読な TSV ではなく人間向け表示になっている" "output=[${PW_PRINT_OUTPUT}]" ;;
  *) pass "--print: 機械可読な TSV ではなく人間向け表示になっている" ;;
esac

# --- ケース9: 引数バリデーション（引数エラーは exit 2） ---
bash "$PLAN_WAVES_SCRIPT" >/dev/null 2>&1
assert_exit_code "--epic も --from-file も無ければ exit 2" 2 "$?"

bash "$PLAN_WAVES_SCRIPT" --epic 14 --from-file "$PW_EPIC3_FIXTURE" >/dev/null 2>&1
assert_exit_code "--epic と --from-file の同時指定は exit 2" 2 "$?"

bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_EPIC3_FIXTURE" --lanes abc >/dev/null 2>&1
assert_exit_code "--lanes に数値以外を渡すと exit 2" 2 "$?"

bash "$PLAN_WAVES_SCRIPT" --from-file "${TMPDIR:-/tmp}/dw-test-pw-no-such-file" >/dev/null 2>&1
assert_exit_code "--from-file に存在しないファイルを渡すと exit 2" 2 "$?"

# --- ケース10: DEV_WORKFLOW_MAX_LANES で既定の --lanes を上書きできる ---
PW_ENV_LANES_OUTPUT="$(DEV_WORKFLOW_MAX_LANES=5 bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_EPIC3_FIXTURE")"
assert_eq "DEV_WORKFLOW_MAX_LANES で既定の lanes を上書きできる" "5" \
  "$(printf '%s\n' "$PW_ENV_LANES_OUTPUT" | awk -F'\t' '$1=="lanes"{print $2}')"

# --- ケース11: 前提未宣言の集計警告（missing-deps-summary、Task #92） ---
# 全件宣言漏れ（PW_SERIAL_FIXTUREを再利用、既定lanes=3）: 実効並列度は1（完全逐次）に落ちる
PW_DEPSWARN_ALL_PRINT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_SERIAL_FIXTURE" --print)"
case "$PW_DEPSWARN_ALL_PRINT" in
  *"前提未宣言が 3 件あります（対象タスク 3 件中）"*)
    pass "missing-deps-summary --print: 件数と対象タスク数が出る（全件宣言漏れ）" ;;
  *) fail "missing-deps-summary --print: 件数と対象タスク数が出る（全件宣言漏れ）" "output=[${PW_DEPSWARN_ALL_PRINT}]" ;;
esac
case "$PW_DEPSWARN_ALL_PRINT" in
  *"実効並列度は 1 です（指定 lanes=3）"*)
    pass "missing-deps-summary --print: 実効並列度1・指定lanes=3が出る（完全逐次）" ;;
  *) fail "missing-deps-summary --print: 実効並列度1・指定lanes=3が出る（完全逐次）" "output=[${PW_DEPSWARN_ALL_PRINT}]" ;;
esac
case "$PW_DEPSWARN_ALL_PRINT" in
  *"- 前提: #N"*"- 前提: なし"*)
    pass "missing-deps-summary --print: 対処法（- 前提: #N / - 前提: なし）が出る" ;;
  *) fail "missing-deps-summary --print: 対処法（- 前提: #N / - 前提: なし）が出る" "output=[${PW_DEPSWARN_ALL_PRINT}]" ;;
esac

assert_eq "missing-deps-summary 機械可読: warn missing-deps-summary 3 3 1 3（全件宣言漏れ）" "1" \
  "$(printf '%s\n' "$PW_SERIAL_OUTPUT" | grep -c '^warn	missing-deps-summary	3	3	1	3$')"

# 集計行を追加しても既存の warn missing-deps 行は全件・従来書式のまま出る（後方互換）
assert_eq "missing-deps-summary 追加後も warn missing-deps は3件とも従来書式で出る" "3" \
  "$(printf '%s\n' "$PW_SERIAL_OUTPUT" | grep -c '^warn	missing-deps	')"

# --- ケース12: 一部だけ宣言漏れ（実効並列度が1にならないケース。lanes=2で2に留まる） ---
PW_DEPSWARN_PARTIAL_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-depswarn-partial.XXXXXX")"
cat > "$PW_DEPSWARN_PARTIAL_FIXTURE" <<'FIXTURE'
910	open
911	open
912	open	- 前提: なし
913	open	- 前提: #912
FIXTURE

PW_DEPSWARN_PARTIAL_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_DEPSWARN_PARTIAL_FIXTURE" --lanes 2)"
assert_eq "一部宣言漏れ: warn missing-deps-summary 2 4 2 2（実効並列度2で1にならない）" "1" \
  "$(printf '%s\n' "$PW_DEPSWARN_PARTIAL_OUTPUT" | grep -c '^warn	missing-deps-summary	2	4	2	2$')"
assert_eq "一部宣言漏れ: 宣言漏れした#910と#911だけにwarn missing-depsが出る" "2" \
  "$(printf '%s\n' "$PW_DEPSWARN_PARTIAL_OUTPUT" | grep -c '^warn	missing-deps	91[01]$')"

# --- ケース13: 宣言漏れが0件のときは missing-deps-summary 行も前提未宣言の警告も出ない（後方互換） ---
PW_DEPSWARN_NONE_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-depswarn-none.XXXXXX")"
cat > "$PW_DEPSWARN_NONE_FIXTURE" <<'FIXTURE'
920	open	- 前提: なし
921	open	- 前提: #920
FIXTURE

PW_DEPSWARN_NONE_OUTPUT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_DEPSWARN_NONE_FIXTURE")"
if printf '%s\n' "$PW_DEPSWARN_NONE_OUTPUT" | grep -q '^warn	missing-deps-summary	'; then
  fail "宣言漏れ0件: missing-deps-summary 行が出ない（後方互換）" "output=[${PW_DEPSWARN_NONE_OUTPUT}]"
else
  pass "宣言漏れ0件: missing-deps-summary 行が出ない（後方互換）"
fi

PW_DEPSWARN_NONE_PRINT="$(bash "$PLAN_WAVES_SCRIPT" --from-file "$PW_DEPSWARN_NONE_FIXTURE" --print)"
if printf '%s\n' "$PW_DEPSWARN_NONE_PRINT" | grep -q '前提未宣言'; then
  fail "宣言漏れ0件: --print に前提未宣言の警告が出ない（後方互換）" "output=[${PW_DEPSWARN_NONE_PRINT}]"
else
  pass "宣言漏れ0件: --print に前提未宣言の警告が出ない（後方互換）"
fi

# --- ケース11: --epic に非数値を渡すと exit 2（Task #39: sandbox-exec.sh の --epic とは
#     別契約で、plan-waves.sh の --epic は数値のEpic issue番号でなければならない） ---
bash "$PLAN_WAVES_SCRIPT" --epic epic14 >/dev/null 2>&1
assert_exit_code "--epic に epic14 のような非数値を渡すと exit 2" 2 "$?"

bash "$PLAN_WAVES_SCRIPT" --epic abc >/dev/null 2>&1
assert_exit_code "--epic に abc のような非数値を渡すと exit 2" 2 "$?"

# 数値の --epic 単体が拒否されないことは、ケース12（gh フェッチが exit 0 で完了すること）で確認する。

# --- ケース12: gh モードで --limit 200 が付き、本文の「- Epic: #N」行でEpic外を除外し、
#     行が無いタスクはフェイルオープンで含める（Task #39: Epic混入対策と30件上限対策） ---
PW_GH_FAKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-pw-ghfake.XXXXXX")"
PW_GH_CALL_MARKER="$(mktemp "${TMPDIR:-/tmp}/dw-test-pw-ghcall.XXXXXX")"
cat > "${PW_GH_FAKE_DIR}/gh" <<'FAKE_GH'
#!/bin/bash
# tests/run-tests.sh 用の偽 gh。load_from_gh が渡す引数を記録し、issue list 呼び出しには
# 固定のレコード（<番号><US><前提行><US><Epic行>、US=0x1f）を返す。実ネットワークには
# 一切触れない。区切り文字は load_from_gh の実装（@tsv ではなく join("")）に合わせる。
US=$'\x1f'
echo "$*" >> "${PW_GH_CALL_MARKER}"
case "$*" in
  *"issue list --label task --state open"*)
    printf '100%s%s- Epic: #14\n' "$US" "$US"    # 指定Epicと一致 -> 含める
    printf '200%s%s- Epic: #3\n' "$US" "$US"     # 別Epic -> 除外する
    printf '300%s%s\n' "$US" "$US"               # Epic行が無い旧形式 -> フェイルオープンで含める
    ;;
esac
FAKE_GH
chmod +x "${PW_GH_FAKE_DIR}/gh"

PW_GH_OUTPUT="$(PATH="${PW_GH_FAKE_DIR}:${PATH}" PW_GH_CALL_MARKER="$PW_GH_CALL_MARKER" bash "$PLAN_WAVES_SCRIPT" --epic 14)"
PW_GH_EXIT=$?
PW_GH_CALL="$(cat "$PW_GH_CALL_MARKER")"

assert_exit_code "gh モード: --epic 14 は exit 0" 0 "$PW_GH_EXIT"

case "$PW_GH_CALL" in
  *"--limit 200"*) pass "gh モード: issue list に --limit 200 が付く（30件上限対策）" ;;
  *) fail "gh モード: issue list に --limit 200 が付く（30件上限対策）" "call=[${PW_GH_CALL}]" ;;
esac

if printf '%s\n' "$PW_GH_OUTPUT" | grep -q '^task	100	'; then
  pass "gh モード: 指定Epicと一致する #100 は対象に含まれる"
else
  fail "gh モード: 指定Epicと一致する #100 は対象に含まれる" "output=[${PW_GH_OUTPUT}]"
fi

if printf '%s\n' "$PW_GH_OUTPUT" | grep -q '^task	200	'; then
  fail "gh モード: 別Epic（#3）を明記する #200 は除外される" "output=[${PW_GH_OUTPUT}]"
else
  pass "gh モード: 別Epic（#3）を明記する #200 は除外される"
fi

if printf '%s\n' "$PW_GH_OUTPUT" | grep -q '^task	300	'; then
  pass "gh モード: Epic行が無い #300 はフェイルオープンで含まれる"
else
  fail "gh モード: Epic行が無い #300 はフェイルオープンで含まれる" "output=[${PW_GH_OUTPUT}]"
fi

# ---------------------------------------------------------------------------
# merge-lane.sh（merge-base 検証と wave ブランチ統合。Task #16）
#
# 一時 git リポジトリを組み立てて検証する（Docker 非依存）。scripts/merge-lane.sh は
# cwd のリポジトリに対して checkout / merge-base / merge / abort を行うため、
# plan-waves.sh と違いスクリプト自体をコピーせず、cwd を一時リポジトリに変えて
# REPO_ROOT のスクリプトを直接呼び出す。
# ---------------------------------------------------------------------------

echo "== merge-lane.sh（merge-base 検証と wave ブランチ統合） =="

MERGE_LANE_SCRIPT="${REPO_ROOT}/scripts/merge-lane.sh"

ml_commit_file() {
  # ml_commit_file <repo_dir> <相対ファイル名> <内容> <コミットメッセージ>
  local repo="$1" file="$2" content="$3" msg="$4"
  (
    cd "$repo" || exit 1
    printf '%s' "$content" > "$file"
    git add "$file"
    git commit -q -m "$msg"
  ) >/dev/null 2>&1
}

ml_branch_from() {
  # ml_branch_from <repo_dir> <新ブランチ名> <開始点（コミットish）>
  local repo="$1" branch="$2" start="$3"
  (
    cd "$repo" || exit 1
    git checkout -q -b "$branch" "$start"
  ) >/dev/null 2>&1
}

ml_head_of() {
  # ml_head_of <repo_dir> <ref>  ref が指すコミットの完全なSHAを返す
  (cd "$1" || exit 1; git rev-parse "$2") 2>/dev/null
}

run_merge_lane() {
  # run_merge_lane <repo_dir> [追加の引数...]  戻り値は標準出力（呼び出し側で $? を確認する）
  local repo="$1"
  shift
  (cd "$repo" || exit 1; bash "$MERGE_LANE_SCRIPT" "$@")
}

# --- ケース8: 同一ベースから分岐した2レーンが順に取り込め、2本目の merge-base が
#     EXPECTED_BASE のままであること ---
ML_REPO8="$(make_temp_repo)"
ml_commit_file "$ML_REPO8" "base.txt" "wave base\n" "wave base commit"
ML8_BASE="$(ml_head_of "$ML_REPO8" HEAD)"
ml_branch_from "$ML_REPO8" "lane-a" "$ML8_BASE"
ml_commit_file "$ML_REPO8" "a.txt" "lane a\n" "lane a change"
ml_branch_from "$ML_REPO8" "lane-b" "$ML8_BASE"
ml_commit_file "$ML_REPO8" "b.txt" "lane b\n" "lane b change"

ML8_OUT1="$(run_merge_lane "$ML_REPO8" --wave-branch "wave/epicT/1" --expected-base "$ML8_BASE" --lane-branch lane-a --task 16 --create)"
ML8_EXIT1=$?
assert_exit_code "ケース8: 1本目（lane-a）の取り込みは exit 0" 0 "$ML8_EXIT1"

# 2本目のマージ実行前（1本目取り込み後）の merge-base を確認する。マージ後は wave が
# lane-b を取り込んで祖先集合が変わるため、必ずマージ「前」に測る。
ML8_ACTUAL_BASE_2ND="$(cd "$ML_REPO8" && git merge-base "wave/epicT/1" lane-b)"
assert_eq "ケース8: 2本目の merge-base（実行前）は EXPECTED_BASE のまま" "$ML8_BASE" "$ML8_ACTUAL_BASE_2ND"

ML8_OUT2="$(run_merge_lane "$ML_REPO8" --wave-branch "wave/epicT/1" --expected-base "$ML8_BASE" --lane-branch lane-b --task 16)"
ML8_EXIT2=$?
assert_exit_code "ケース8: 2本目（lane-b）の取り込みは exit 0" 0 "$ML8_EXIT2"

ML8_WAVE_HEAD="$(ml_head_of "$ML_REPO8" "wave/epicT/1")"
if [ "$ML8_WAVE_HEAD" != "$ML8_BASE" ]; then
  pass "ケース8: wave ブランチが両レーンの成果を含む（HEAD が進んでいる）"
else
  fail "ケース8: wave ブランチが両レーンの成果を含む（HEAD が進んでいる）" "wave HEAD が BASE から動いていません"
fi

# --- ケース9: 別ベースから分岐したレーンが exit 10 で拒否され、wave ブランチが動かないこと ---
ML_REPO9="$(make_temp_repo)"
ML9_OLD_BASE="$(ml_head_of "$ML_REPO9" HEAD)"
ml_commit_file "$ML_REPO9" "base.txt" "wave base\n" "wave base commit"
ML9_EXPECTED_BASE="$(ml_head_of "$ML_REPO9" HEAD)"

ml_branch_from "$ML_REPO9" "lane-ok" "$ML9_EXPECTED_BASE"
ml_commit_file "$ML_REPO9" "ok.txt" "lane ok\n" "lane ok change"

ml_branch_from "$ML_REPO9" "lane-wrong-base" "$ML9_OLD_BASE"
ml_commit_file "$ML_REPO9" "wrong.txt" "lane wrong base\n" "lane wrong base change"

run_merge_lane "$ML_REPO9" --wave-branch "wave/epicT/1" --expected-base "$ML9_EXPECTED_BASE" --lane-branch lane-ok --task 16 --create >/dev/null
ML9_SETUP_EXIT=$?
assert_exit_code "ケース9: 事前準備（lane-ok の取り込み）は exit 0" 0 "$ML9_SETUP_EXIT"

ML9_WAVE_HEAD_BEFORE="$(ml_head_of "$ML_REPO9" "wave/epicT/1")"

ML9_OUT="$(run_merge_lane "$ML_REPO9" --wave-branch "wave/epicT/1" --expected-base "$ML9_EXPECTED_BASE" --lane-branch lane-wrong-base --task 16)"
ML9_EXIT=$?
assert_exit_code "ケース9: 別ベースから分岐したレーンは exit 10" 10 "$ML9_EXIT"

case "$ML9_OUT" in
  *"$ML9_OLD_BASE"*) pass "ケース9: 実際の merge-base とそのコミットログが stdout に出る" ;;
  *) fail "ケース9: 実際の merge-base とそのコミットログが stdout に出る" "output=[${ML9_OUT}]" ;;
esac

ML9_WAVE_HEAD_AFTER="$(ml_head_of "$ML_REPO9" "wave/epicT/1")"
assert_eq "ケース9: exit 10 のとき wave ブランチが動かない" "$ML9_WAVE_HEAD_BEFORE" "$ML9_WAVE_HEAD_AFTER"

# --- ケース10: 競合するレーンが exit 11 で拒否され、git merge --abort 後に作業ツリーが
#     汚れていないこと（git status --porcelain が空） ---
ML_REPO10="$(make_temp_repo)"
ml_commit_file "$ML_REPO10" "conflict.txt" "base\n" "wave base commit"
ML10_BASE="$(ml_head_of "$ML_REPO10" HEAD)"

ml_branch_from "$ML_REPO10" "lane-c1" "$ML10_BASE"
ml_commit_file "$ML_REPO10" "conflict.txt" "change1\n" "lane c1 change"

ml_branch_from "$ML_REPO10" "lane-c2" "$ML10_BASE"
ml_commit_file "$ML_REPO10" "conflict.txt" "change2\n" "lane c2 change"

run_merge_lane "$ML_REPO10" --wave-branch "wave/epicT/1" --expected-base "$ML10_BASE" --lane-branch lane-c1 --task 16 --create >/dev/null
ML10_SETUP_EXIT=$?
assert_exit_code "ケース10: 事前準備（lane-c1 の取り込み）は exit 0" 0 "$ML10_SETUP_EXIT"

ML10_WAVE_HEAD_BEFORE="$(ml_head_of "$ML_REPO10" "wave/epicT/1")"

ML10_OUT="$(run_merge_lane "$ML_REPO10" --wave-branch "wave/epicT/1" --expected-base "$ML10_BASE" --lane-branch lane-c2 --task 16)"
ML10_EXIT=$?
assert_exit_code "ケース10: 競合するレーンは exit 11" 11 "$ML10_EXIT"

case "$ML10_OUT" in
  *"conflict.txt"*) pass "ケース10: 競合ファイル一覧（conflict.txt）が stdout に出る" ;;
  *) fail "ケース10: 競合ファイル一覧（conflict.txt）が stdout に出る" "output=[${ML10_OUT}]" ;;
esac

ML10_PORCELAIN="$(cd "$ML_REPO10" && git status --porcelain)"
assert_eq "ケース10: git merge --abort 後に作業ツリーが汚れていない" "" "$ML10_PORCELAIN"

ML10_WAVE_HEAD_AFTER="$(ml_head_of "$ML_REPO10" "wave/epicT/1")"
assert_eq "ケース10: exit 11 のとき wave ブランチが動かない" "$ML10_WAVE_HEAD_BEFORE" "$ML10_WAVE_HEAD_AFTER"

# --- ケース11: レーン1本のウェーブで履歴が fast-forward になること（lanes=1 相当） ---
ML_REPO11="$(make_temp_repo)"
ml_commit_file "$ML_REPO11" "base.txt" "wave base\n" "wave base commit"
ML11_BASE="$(ml_head_of "$ML_REPO11" HEAD)"

ml_branch_from "$ML_REPO11" "lane-solo" "$ML11_BASE"
ml_commit_file "$ML_REPO11" "solo.txt" "lane solo\n" "lane solo change"
ML11_LANE_HEAD="$(ml_head_of "$ML_REPO11" lane-solo)"

run_merge_lane "$ML_REPO11" --wave-branch "wave/epicT/1" --expected-base "$ML11_BASE" --lane-branch lane-solo --task 16 --create >/dev/null
ML11_EXIT=$?
assert_exit_code "ケース11: 単独レーンの取り込みは exit 0" 0 "$ML11_EXIT"

ML11_WAVE_HEAD="$(ml_head_of "$ML_REPO11" "wave/epicT/1")"
assert_eq "ケース11: fast-forward により wave HEAD がレーンの HEAD と一致する" "$ML11_LANE_HEAD" "$ML11_WAVE_HEAD"

ML11_MERGE_COUNT="$(cd "$ML_REPO11" && git log --merges --oneline "wave/epicT/1" | wc -l | tr -d ' ')"
assert_eq "ケース11: fast-forward によりマージコミットが作られない" "0" "$ML11_MERGE_COUNT"

# --- ケース12: 引数バリデーション（引数エラーは exit 2） ---
ML_REPO_ARGS="$(make_temp_repo)"

run_merge_lane "$ML_REPO_ARGS" >/dev/null 2>&1
assert_exit_code "引数なしは exit 2" 2 "$?"

run_merge_lane "$ML_REPO_ARGS" --expected-base HEAD --lane-branch dummy >/dev/null 2>&1
assert_exit_code "--wave-branch 省略は exit 2" 2 "$?"

run_merge_lane "$ML_REPO_ARGS" --wave-branch wave/epicT/1 --lane-branch dummy >/dev/null 2>&1
assert_exit_code "--expected-base 省略は exit 2" 2 "$?"

run_merge_lane "$ML_REPO_ARGS" --wave-branch wave/epicT/1 --expected-base HEAD >/dev/null 2>&1
assert_exit_code "--lane-branch 省略は exit 2" 2 "$?"

run_merge_lane "$ML_REPO_ARGS" --wave-branch wave/epicT/1 --expected-base no-such-ref --lane-branch dummy >/dev/null 2>&1
assert_exit_code "--expected-base が解決できない値は exit 2" 2 "$?"

# --- ケース13: wave ブランチが無く --create も無ければ exit 1（その他の失敗） ---
ML_REPO_NOCREATE="$(make_temp_repo)"
ML_NOCREATE_BASE="$(ml_head_of "$ML_REPO_NOCREATE" HEAD)"
ml_branch_from "$ML_REPO_NOCREATE" "lane-x" "$ML_NOCREATE_BASE"
ml_commit_file "$ML_REPO_NOCREATE" "x.txt" "lane x\n" "lane x change"

run_merge_lane "$ML_REPO_NOCREATE" --wave-branch "wave/epicT/1" --expected-base "$ML_NOCREATE_BASE" --lane-branch lane-x >/dev/null 2>&1
assert_exit_code "wave ブランチが無く --create 無しは exit 1" 1 "$?"

# --- ケース14: レーンのブランチが存在しなければ exit 1（その他の失敗） ---
ML_REPO_NOLANE="$(make_temp_repo)"
ML_NOLANE_BASE="$(ml_head_of "$ML_REPO_NOLANE" HEAD)"

run_merge_lane "$ML_REPO_NOLANE" --wave-branch "wave/epicT/1" --expected-base "$ML_NOLANE_BASE" --lane-branch no-such-lane-branch --create >/dev/null 2>&1
assert_exit_code "存在しないレーンブランチは exit 1" 1 "$?"

# --- ケース15（Review #40）: 未コミットのローカル変更でマージが「競合ではない理由」で
#     失敗した場合、exit 1 になり（exit 11 にならず）、`git merge --abort` を試みない
#     （呼べば「There is no merge to abort」で失敗し作業ツリーが汚れる）こと。
#     git merge は "Your local changes to the following files would be overwritten by
#     merge" で非0終了するが、MERGE_HEAD は作られず未マージパスも無いため、これは
#     本物の競合と区別しなければならない。 ---
ML_REPO15="$(make_temp_repo)"
ml_commit_file "$ML_REPO15" "file.txt" "base\n" "wave base commit"
ML15_BASE="$(ml_head_of "$ML_REPO15" HEAD)"

(cd "$ML_REPO15" && git branch "wave/epicT/1" "$ML15_BASE") >/dev/null 2>&1

ml_branch_from "$ML_REPO15" "lane-local" "$ML15_BASE"
ml_commit_file "$ML_REPO15" "file.txt" "lane change\n" "lane local change"

# wave ブランチへ切り替え、file.txt に未コミットの変更を残す（この時点でコミット済みの
# 変更は無いので checkout 自体は成功する）。merge-lane.sh 自身も同じブランチへ checkout
# するため（no-op）、この未コミット変更はそのまま merge 実行時まで残る。
(cd "$ML_REPO15" && git checkout -q "wave/epicT/1") >/dev/null 2>&1
(cd "$ML_REPO15" && printf 'uncommitted local change\n' > file.txt) >/dev/null 2>&1

ML15_PORCELAIN_BEFORE="$(cd "$ML_REPO15" && git status --porcelain)"

ML15_OUT="$(run_merge_lane "$ML_REPO15" --wave-branch "wave/epicT/1" --expected-base "$ML15_BASE" --lane-branch lane-local --task 16)"
ML15_EXIT=$?
assert_exit_code "ケース15: ローカル未コミット変更によるマージ失敗は exit 1（exit 11 にならない）" 1 "$ML15_EXIT"

case "$ML15_OUT" in
  *"マージ競合が発生しました"*) fail "ケース15: 「マージ競合が発生しました」の見出しは出ない（本物の競合ではないため）" "output=[${ML15_OUT}]" ;;
  *) pass "ケース15: 「マージ競合が発生しました」の見出しは出ない（本物の競合ではないため）" ;;
esac

case "$ML15_OUT" in
  *"マージに失敗しました（競合ではありません）"*) pass "ケース15: 「競合ではない失敗」の見出しが出る" ;;
  *) fail "ケース15: 「競合ではない失敗」の見出しが出る" "output=[${ML15_OUT}]" ;;
esac

ML15_MERGE_HEAD_EXISTS="$(cd "$ML_REPO15" && [ -f .git/MERGE_HEAD ] && echo yes || echo no)"
assert_eq "ケース15: MERGE_HEAD が存在しない（git merge --abort を呼んでいない証跡）" "no" "$ML15_MERGE_HEAD_EXISTS"

ML15_PORCELAIN_AFTER="$(cd "$ML_REPO15" && git status --porcelain)"
assert_eq "ケース15: 未コミットのローカル変更（file.txt）がそのまま残っている（abort による破棄が起きていない）" \
  "$ML15_PORCELAIN_BEFORE" "$ML15_PORCELAIN_AFTER"

# --- ケース16（Task #54）: --create 指定時に残骸 wave ブランチ（tip が --expected-base と
#     不一致）が既に存在する場合、exit 1 で拒否され、呼び出し元でチェックアウトしていた
#     ブランチ（epic ブランチ相当）も wave ブランチも一切動かないこと。出力に既存 tip・
#     期待ベース・対処（WAVE_NO の採番し直し）が含まれること。 ---
ML_REPO16="$(make_temp_repo)"
ML16_DEFAULT_BRANCH="$(cd "$ML_REPO16" && git rev-parse --abbrev-ref HEAD)"
ml_commit_file "$ML_REPO16" "base.txt" "wave base\n" "wave base commit"
ML16_EXPECTED_BASE="$(ml_head_of "$ML_REPO16" HEAD)"

# 前回セッションの残骸を模す: EXPECTED_BASE から分岐した別コミットを tip に持つ
# wave ブランチ（checkout はしない。ml_branch_from を使うと現在のブランチが切り替わって
# しまうため、直接 `git branch` で作る）
ml_branch_from "$ML_REPO16" "stale-source" "$ML16_EXPECTED_BASE"
ml_commit_file "$ML_REPO16" "stale.txt" "stale\n" "stale unrelated commit (previous session)"
ML16_STALE_TIP="$(ml_head_of "$ML_REPO16" stale-source)"
(cd "$ML_REPO16" && git branch "wave/epicT/1" "$ML16_STALE_TIP") >/dev/null 2>&1

# 呼び出し元（epic ブランチ相当）へ戻し、この時点のHEADを記録する
(cd "$ML_REPO16" && git checkout -q "$ML16_DEFAULT_BRANCH") >/dev/null 2>&1
ML16_CALLER_HEAD_BEFORE="$(ml_head_of "$ML_REPO16" "$ML16_DEFAULT_BRANCH")"
ML16_WAVE_HEAD_BEFORE="$(ml_head_of "$ML_REPO16" "wave/epicT/1")"

ml_branch_from "$ML_REPO16" "lane-y" "$ML16_EXPECTED_BASE"
ml_commit_file "$ML_REPO16" "y.txt" "lane y\n" "lane y change"

ML16_OUT="$(run_merge_lane "$ML_REPO16" --wave-branch "wave/epicT/1" --expected-base "$ML16_EXPECTED_BASE" --lane-branch lane-y --task 54 --create 2>&1)"
ML16_EXIT=$?
assert_exit_code "ケース16: --create で tip 不一致の残骸 wave ブランチは exit 1" 1 "$ML16_EXIT"

ML16_CALLER_HEAD_AFTER="$(ml_head_of "$ML_REPO16" "$ML16_DEFAULT_BRANCH")"
ML16_WAVE_HEAD_AFTER="$(ml_head_of "$ML_REPO16" "wave/epicT/1")"
assert_eq "ケース16: 呼び出し元ブランチ（epic ブランチ相当）の HEAD が動かない" "$ML16_CALLER_HEAD_BEFORE" "$ML16_CALLER_HEAD_AFTER"
assert_eq "ケース16: wave ブランチの tip が動かない（残骸のまま）" "$ML16_WAVE_HEAD_BEFORE" "$ML16_WAVE_HEAD_AFTER"

case "$ML16_OUT" in
  *"$ML16_STALE_TIP"*) pass "ケース16: 出力に既存 wave ブランチの tip が含まれる" ;;
  *) fail "ケース16: 出力に既存 wave ブランチの tip が含まれる" "output=[${ML16_OUT}]" ;;
esac

case "$ML16_OUT" in
  *"$ML16_EXPECTED_BASE"*) pass "ケース16: 出力に期待していたベース（--expected-base）が含まれる" ;;
  *) fail "ケース16: 出力に期待していたベース（--expected-base）が含まれる" "output=[${ML16_OUT}]" ;;
esac

case "$ML16_OUT" in
  *"WAVE_NO"*) pass "ケース16: 出力に対処（WAVE_NO の採番し直し）が含まれる" ;;
  *) fail "ケース16: 出力に対処（WAVE_NO の採番し直し）が含まれる" "output=[${ML16_OUT}]" ;;
esac

# --- ケース17（Task #54）: --create 指定時に既存 wave ブランチの tip が --expected-base と
#     一致する場合（前回まさに --create で作っただけで、まだレーンを取り込んでいない状態）は
#     残骸扱いにせず、従来どおり取り込みが成功すること（冪等性） ---
ML_REPO17="$(make_temp_repo)"
ml_commit_file "$ML_REPO17" "base.txt" "wave base\n" "wave base commit"
ML17_EXPECTED_BASE="$(ml_head_of "$ML_REPO17" HEAD)"

# 前回の --create で作られたが、まだ何も取り込んでいない wave ブランチ（tip = EXPECTED_BASE）
(cd "$ML_REPO17" && git branch "wave/epicT/1" "$ML17_EXPECTED_BASE") >/dev/null 2>&1

ml_branch_from "$ML_REPO17" "lane-z" "$ML17_EXPECTED_BASE"
ml_commit_file "$ML_REPO17" "z.txt" "lane z\n" "lane z change"
ML17_LANE_HEAD="$(ml_head_of "$ML_REPO17" lane-z)"

ML17_OUT="$(run_merge_lane "$ML_REPO17" --wave-branch "wave/epicT/1" --expected-base "$ML17_EXPECTED_BASE" --lane-branch lane-z --task 54 --create)"
ML17_EXIT=$?
assert_exit_code "ケース17: --create で tip 一致の既存 wave ブランチは従来どおり exit 0（冪等性）" 0 "$ML17_EXIT"

ML17_WAVE_HEAD="$(ml_head_of "$ML_REPO17" "wave/epicT/1")"
assert_eq "ケース17: 冪等時は取り込みが成功し wave HEAD がレーンの HEAD と一致する" "$ML17_LANE_HEAD" "$ML17_WAVE_HEAD"

case "$ML17_OUT" in
  *"取り込み成功"*) pass "ケース17: 出力に取り込み成功のメッセージが含まれる" ;;
  *) fail "ケース17: 出力に取り込み成功のメッセージが含まれる" "output=[${ML17_OUT}]" ;;
esac

# ---------------------------------------------------------------------------
# adapters/codex/run-loop.sh: 統合ゲートが全テストを実行すること（回帰防止 #37）
#
# Review #37: mechanical_gate() が check-readability.sh --git だけを実行しており、
# sandbox-exec.sh 経由でプロジェクトの全テストを走らせていなかった（statically
# 検証できる範囲に限定し、実際の gh/docker 呼び出しは行わない）。
#
# #144でフルスイートはウェーブ（＝タスク）ごとから Epic につき1回に移動した。
# mechanical_gate() は readability_gate()（wave取り込み検証・可読性ガードのみ）と
# epic_gate()（Epic統合ゲート・全テスト+可読性ガード）に分割された。
# ---------------------------------------------------------------------------

echo ""
echo "== adapters/codex/run-loop.sh（統合ゲートの全テスト実行・回帰防止 #37, #144） =="

RUN_LOOP_SCRIPT="${REPO_ROOT}/adapters/codex/run-loop.sh"

RL_BASHN_OUT="$(bash -n "$RUN_LOOP_SCRIPT" 2>&1)"
assert_exit_code "run-loop.sh: bash -n は exit 0" 0 "$?"
[ -z "$RL_BASHN_OUT" ] || echo "         ${RL_BASHN_OUT}"

if command -v shellcheck >/dev/null 2>&1; then
  RL_SHELLCHECK_OUT="$(cd "$(dirname "$RUN_LOOP_SCRIPT")" && shellcheck -x "$(basename "$RUN_LOOP_SCRIPT")" 2>&1)"
  if [ $? -eq 0 ]; then
    pass "shellcheck: run-loop.sh"
  else
    fail "shellcheck: run-loop.sh" "$RL_SHELLCHECK_OUT"
  fi
else
  skip "shellcheck: run-loop.sh" "コマンドが見つからないためスキップ"
fi

# epic_gate()（Epicにつき1回のフルスイート）の関数本体だけを取り出して静的に検証する
RL_EPIC_GATE_BODY="$(sed -n '/^epic_gate() {/,/^}/p' "$RUN_LOOP_SCRIPT")"
RL_EPIC_GATE_ONELINE="$(printf '%s' "$RL_EPIC_GATE_BODY" | tr '\n' ' ')"

case "$RL_EPIC_GATE_ONELINE" in
  *"sandbox-exec.sh"*'"$TEST_CMD"'*)
    pass "run-loop.sh: epic_gate() が sandbox-exec.sh に \$TEST_CMD を渡している（#144）" ;;
  *)
    fail "run-loop.sh: epic_gate() が sandbox-exec.sh に \$TEST_CMD を渡している（#144）" "$RL_EPIC_GATE_BODY" ;;
esac

case "$RL_EPIC_GATE_ONELINE" in
  *"count-skips.sh"*)
    pass "run-loop.sh: epic_gate() が count-skips.sh を呼んでいる（#144）" ;;
  *)
    fail "run-loop.sh: epic_gate() が count-skips.sh を呼んでいる（#144）" "$RL_EPIC_GATE_BODY" ;;
esac

case "$RL_EPIC_GATE_ONELINE" in
  *"check-readability.sh"*)
    pass "run-loop.sh: epic_gate() が check-readability.sh を呼んでいる（#144）" ;;
  *)
    fail "run-loop.sh: epic_gate() が check-readability.sh を呼んでいる（#144）" "$RL_EPIC_GATE_BODY" ;;
esac

# readability_gate()（wave取り込み検証。可読性ガードのみ、フルスイートは走らせない）の
# 関数本体だけを取り出して静的に検証する
RL_READABILITY_GATE_BODY="$(sed -n '/^readability_gate() {/,/^}/p' "$RUN_LOOP_SCRIPT")"
RL_READABILITY_GATE_ONELINE="$(printf '%s' "$RL_READABILITY_GATE_BODY" | tr '\n' ' ')"

case "$RL_READABILITY_GATE_ONELINE" in
  *"check-readability.sh"*)
    pass "run-loop.sh: readability_gate() が check-readability.sh を呼んでいる（#144）" ;;
  *)
    fail "run-loop.sh: readability_gate() が check-readability.sh を呼んでいる（#144）" "$RL_READABILITY_GATE_BODY" ;;
esac

case "$RL_READABILITY_GATE_ONELINE" in
  *"sandbox-exec.sh"*)
    fail "run-loop.sh: readability_gate() はプロジェクトの全テストを走らせない（Epic統合ゲートへ集約。#144）" "$RL_READABILITY_GATE_BODY" ;;
  *)
    pass "run-loop.sh: readability_gate() はプロジェクトの全テストを走らせない（Epic統合ゲートへ集約。#144）" ;;
esac

# 取り込み成功時に呼ばれるのが readability_gate() であり、旧 mechanical_gate() が
# 残っていない（呼び出し漏れの回帰防止）こと
if grep -q 'mechanical_gate' "$RUN_LOOP_SCRIPT"; then
  fail "run-loop.sh: 旧関数名 mechanical_gate が残っていない（#144）" "$(grep -n 'mechanical_gate' "$RUN_LOOP_SCRIPT")"
else
  pass "run-loop.sh: 旧関数名 mechanical_gate が残っていない（#144）"
fi

if grep -q 'readability_gate' "$RUN_LOOP_SCRIPT" && grep -q '&& readability_gate; then' "$RUN_LOOP_SCRIPT"; then
  pass "run-loop.sh: レーン取り込み成功後に readability_gate() を呼んでいる（#144）"
else
  fail "run-loop.sh: レーン取り込み成功後に readability_gate() を呼んでいる（#144）" \
    "$(grep -n 'readability_gate' "$RUN_LOOP_SCRIPT")"
fi

# DEV_WORKFLOW_TEST_CMD 未設定時は、gh/git を呼ぶ前に停止すること
RL_FAKE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fakebin-rl.XXXXXX")"
for rl_fake in gh git; do
  cat > "${RL_FAKE_BIN}/${rl_fake}" <<'FAKE_BIN'
#!/bin/bash
exit 0
FAKE_BIN
  chmod +x "${RL_FAKE_BIN}/${rl_fake}"
done

RL_UNSET_OUT="$(PATH="${RL_FAKE_BIN}:${PATH}" DEV_WORKFLOW_DRY_RUN=1 DEV_WORKFLOW_TEST_CMD="" \
  bash "$RUN_LOOP_SCRIPT" 999 2>&1)"
RL_UNSET_EXIT=$?
assert_exit_code "run-loop.sh: DEV_WORKFLOW_TEST_CMD 未設定は exit 1" 1 "$RL_UNSET_EXIT"
case "$RL_UNSET_OUT" in
  *"DEV_WORKFLOW_TEST_CMD"*)
    pass "run-loop.sh: 未設定時のエラーメッセージに DEV_WORKFLOW_TEST_CMD を含む" ;;
  *)
    fail "run-loop.sh: 未設定時のエラーメッセージに DEV_WORKFLOW_TEST_CMD を含む" "$RL_UNSET_OUT" ;;
esac

RL_SET_OUT="$(PATH="${RL_FAKE_BIN}:${PATH}" DEV_WORKFLOW_DRY_RUN=1 DEV_WORKFLOW_TEST_CMD='true' \
  bash "$RUN_LOOP_SCRIPT" 999 2>&1)"
case "$RL_SET_OUT" in
  *"DEV_WORKFLOW_TEST_CMD が未設定です"*)
    fail "run-loop.sh: DEV_WORKFLOW_TEST_CMD 設定時は未設定エラーを出さない" "$RL_SET_OUT" ;;
  *)
    pass "run-loop.sh: DEV_WORKFLOW_TEST_CMD 設定時は未設定エラーを出さない" ;;
esac

# 伝播スキップ（skip <番号> reason depends-on-skipped <依存先番号>）を issue コメントし、
# 同一実行内で重複コメントしないこと（静的検証: 分岐と重複防止の仕組みが存在するか）
# 行番号を固定値でハードコードせず、目印となる固定文字列（grep -F）から範囲を求める。
RL_LOOP_START="$(grep -n -F 'read -r kind sub num extra dep; do' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
RL_LOOP_END_REL="$(tail -n "+${RL_LOOP_START}" "$RUN_LOOP_SCRIPT" | grep -n -F 'done <<< "$PLAN"' | head -1 | cut -d: -f1)"
RL_LOOP_END=$((RL_LOOP_START + RL_LOOP_END_REL - 1))
RL_WARN_LOOP="$(sed -n "${RL_LOOP_START},${RL_LOOP_END}p" "$RUN_LOOP_SCRIPT")"
RL_WARN_LOOP_ONELINE="$(printf '%s' "$RL_WARN_LOOP" | tr '\n' ' ')"

RL_SKIP_BRANCH_OK=1
case "$RL_WARN_LOOP_ONELINE" in
  *'"$kind" = "skip"'*) : ;;
  *) RL_SKIP_BRANCH_OK=0 ;;
esac
case "$RL_WARN_LOOP_ONELINE" in
  *"gh issue comment"*) : ;;
  *) RL_SKIP_BRANCH_OK=0 ;;
esac
case "$RL_WARN_LOOP_ONELINE" in
  *"depends-on-skipped"*) : ;;
  *) RL_SKIP_BRANCH_OK=0 ;;
esac
if [ "$RL_SKIP_BRANCH_OK" -eq 1 ]; then
  pass "run-loop.sh: skip 行（伝播スキップ）を issue にコメントしている"
else
  fail "run-loop.sh: skip 行（伝播スキップ）を issue にコメントしている" "$RL_WARN_LOOP"
fi

case "$RL_WARN_LOOP_ONELINE" in
  *"PROPAGATED_CSV"*)
    pass "run-loop.sh: 伝播スキップの重複コメントを防ぐ仕組みがある" ;;
  *)
    fail "run-loop.sh: 伝播スキップの重複コメントを防ぐ仕組みがある" "$RL_WARN_LOOP" ;;
esac

# ---------------------------------------------------------------------------
# adapters/codex/run-loop.sh: watchdog / heartbeat の結線（Task #53）
#
# Epic #42 決定事項4: 両アダプタとも「検知して通知するだけ」に揃える（ハードタイムアウト・
# 自動再投入は実装しない）。--start は run-start より後、--wave は generator 起動前、
# --stop は正常終了・異常終了を問わず必ず通ること（trap ... EXIT）を検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== adapters/codex/run-loop.sh（watchdog結線・回帰防止 #53） =="

RL_FULL_SRC="$(cat "$RUN_LOOP_SCRIPT")"

# --start は notify-slack.sh run-start より後にあること（run マーカーより先に watchdog を
# 起動すると自己終了条件を誤検知しうるため）
RL_RUN_START_LINE="$(grep -n 'notify-slack.sh" run-start' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
RL_WD_START_LINE="$(grep -n 'watchdog.sh" --start' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$RL_RUN_START_LINE" ] && [ -n "$RL_WD_START_LINE" ] && [ "$RL_WD_START_LINE" -gt "$RL_RUN_START_LINE" ]; then
  pass "run-loop.sh: watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#53）"
else
  fail "run-loop.sh: watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#53）" \
    "run-start行=${RL_RUN_START_LINE:-なし} --start行=${RL_WD_START_LINE:-なし}"
fi

# --wave は LANE_BRANCH 確定後・generator 起動（run_agent generator）前にあること
RL_WD_WAVE_LINE="$(grep -n 'watchdog.sh" --wave' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
RL_LANE_BRANCH_LINE="$(grep -n 'LANE_BRANCH="task/' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
RL_RUN_AGENT_GEN_LINE="$(grep -n 'run_agent generator' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$RL_WD_WAVE_LINE" ] && [ -n "$RL_LANE_BRANCH_LINE" ] && [ -n "$RL_RUN_AGENT_GEN_LINE" ] \
   && [ "$RL_WD_WAVE_LINE" -gt "$RL_LANE_BRANCH_LINE" ] && [ "$RL_WD_WAVE_LINE" -lt "$RL_RUN_AGENT_GEN_LINE" ]; then
  pass "run-loop.sh: watchdog.sh --wave の呼び出しが LANE_BRANCH確定後・generator起動前にある（#53）"
else
  fail "run-loop.sh: watchdog.sh --wave の呼び出しが LANE_BRANCH確定後・generator起動前にある（#53）" \
    "--wave行=${RL_WD_WAVE_LINE:-なし} LANE_BRANCH行=${RL_LANE_BRANCH_LINE:-なし} run_agent行=${RL_RUN_AGENT_GEN_LINE:-なし}"
fi

# --stop は trap ... EXIT で結線され、正常終了・異常終了・途中の exit を問わず必ず通ること
case "$RL_FULL_SRC" in
  *"trap '_run_loop_watchdog_stop' EXIT"*)
    pass "run-loop.sh: watchdog.sh --stop が trap ... EXIT で結線されている（#53）" ;;
  *)
    fail "run-loop.sh: watchdog.sh --stop が trap ... EXIT で結線されている（#53）" "" ;;
esac

case "$RL_FULL_SRC" in
  *'watchdog.sh" --stop'*)
    pass "run-loop.sh: watchdog.sh --stop の呼び出しが存在する（#53）" ;;
  *)
    fail "run-loop.sh: watchdog.sh --stop の呼び出しが存在する（#53）" "" ;;
esac

# trap は最初の `exit` より前（EPIC_NUMBER 未指定エラーより前）に仕掛けられていること
# （引数エラーのような早期終了経路でも --stop が通ることを保証するため）
RL_TRAP_LINE="$(grep -n "trap '_run_loop_watchdog_stop' EXIT" "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
RL_FIRST_EXIT_LINE="$(grep -nE '^[[:space:]]*exit 1$' "$RUN_LOOP_SCRIPT" | head -1 | cut -d: -f1)"
if [ -n "$RL_TRAP_LINE" ] && [ -n "$RL_FIRST_EXIT_LINE" ] && [ "$RL_TRAP_LINE" -lt "$RL_FIRST_EXIT_LINE" ]; then
  pass "run-loop.sh: trap は最初の exit より前に仕掛けられている（早期終了経路もカバー・#53）"
else
  fail "run-loop.sh: trap は最初の exit より前に仕掛けられている（早期終了経路もカバー・#53）" \
    "trap行=${RL_TRAP_LINE:-なし} 最初のexit行=${RL_FIRST_EXIT_LINE:-なし}"
fi

# watchdog.sh が無い・失敗する環境でもループを止めないよう、--start / --wave の呼び出しが
# `|| true` で握りつぶされていること（--stop は trap 関数内部で握りつぶし済み）
RL_WD_START_TAIL="$(sed -n "${RL_WD_START_LINE}p" "$RUN_LOOP_SCRIPT")"
case "$RL_WD_START_TAIL" in
  *'|| true'*)
    pass "run-loop.sh: watchdog.sh --start の失敗はループを止めない（|| true・#53）" ;;
  *)
    fail "run-loop.sh: watchdog.sh --start の失敗はループを止めない（|| true・#53）" "$RL_WD_START_TAIL" ;;
esac

RL_WD_WAVE_BLOCK="$(sed -n "${RL_WD_WAVE_LINE},$((RL_WD_WAVE_LINE + 1))p" "$RUN_LOOP_SCRIPT")"
case "$RL_WD_WAVE_BLOCK" in
  *'|| true'*)
    pass "run-loop.sh: watchdog.sh --wave の失敗はループを止めない（|| true・#53）" ;;
  *)
    fail "run-loop.sh: watchdog.sh --wave の失敗はループを止めない（|| true・#53）" "$RL_WD_WAVE_BLOCK" ;;
esac

# タイムアウトによる kill 経路が存在しないこと（Epic #42 決定事項4:
# ハードタイムアウト・自動再投入は実装しない。両アダプタで機能差を作らない）
for RL_FORBIDDEN in 'kill -TERM' 'kill -9' 'DEV_WORKFLOW_AGENT_TIMEOUT_SEC'; do
  if grep -qF -- "$RL_FORBIDDEN" "$RUN_LOOP_SCRIPT"; then
    fail "run-loop.sh: タイムアウトによる kill 経路が存在しない（${RL_FORBIDDEN} 不在・#53）" \
      "$(grep -nF -- "$RL_FORBIDDEN" "$RUN_LOOP_SCRIPT")"
  else
    pass "run-loop.sh: タイムアウトによる kill 経路が存在しない（${RL_FORBIDDEN} 不在・#53）"
  fi
done

# --- 動的検証: DEV_WORKFLOW_DRY_RUN=1 で --start → --wave → --stop がこの順で呼ばれる。
#     watchdog.sh を差し替え可能なスタブ（呼び出し引数を記録するだけ）に置き換え、
#     実際に run-loop.sh 全体を DRY_RUN で走らせて確認する（Docker・codex には触れない）。
#     `${PLUGIN_ROOT_DIR}/scripts/watchdog.sh` は BASH_SOURCE から解決される絶対パスのため、
#     run-loop.sh・scripts 一式を一時ディレクトリへ複製し、その中の watchdog.sh だけを
#     差し替える（実リポジトリのファイルは一切変更しない）。
rl_build_fixture() {
  # rl_build_fixture <fixture_dir_var_prefix>
  # 呼び出し側の変数 <prefix>_ROOT / <prefix>_PROJECT / <prefix>_GH_DIR / <prefix>_WD_LOG を埋める。
  local prefix="$1"
  local fake_root project origin gh_dir wd_log
  fake_root="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-rl-root.XXXXXX")"
  mkdir -p "${fake_root}/adapters/codex" "${fake_root}/scripts"
  cp "$RUN_LOOP_SCRIPT" "${fake_root}/adapters/codex/run-loop.sh"
  cp -r "${REPO_ROOT}/scripts/." "${fake_root}/scripts/"

  origin="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-rl-origin.XXXXXX")"
  (cd "$origin" && git init -q --bare) >/dev/null 2>&1

  project="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-rl-project.XXXXXX")"
  (
    cd "$project" || exit 1
    git init -q
    git config user.email "dev-workflow-test@example.com"
    git config user.name "dev-workflow test"
    git remote add origin "$origin"
    printf 'test\n' > README.md
    git add README.md
    git commit -q -m init
    git branch "epic/epic999/watchdog-wiring"
    git push -q origin "epic/epic999/watchdog-wiring"
    mkdir -p .codex/agents
    printf 'name = "generator"\n' > .codex/agents/generator.toml
    printf 'name = "evaluator"\n' > .codex/agents/evaluator.toml
  ) >/dev/null 2>&1

  gh_dir="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-rl-ghfake.XXXXXX")"
  cat > "${gh_dir}/gh" <<'FAKE_GH'
#!/bin/bash
case "$*" in
  "issue view 999 --json body -q .body")
    printf 'ブランチ: epic/epic999/watchdog-wiring\n'
    ;;
  *"issue list --label task --state open"*)
    printf '501\x1f- 前提: なし\x1f- Epic: #999\n'
    ;;
  *)
    exit 0
    ;;
esac
FAKE_GH
  chmod +x "${gh_dir}/gh"

  wd_log="$(mktemp "${TMPDIR:-/tmp}/dw-test-rl-wdlog.XXXXXX")"

  eval "${prefix}_ROOT=\"\$fake_root\""
  eval "${prefix}_PROJECT=\"\$project\""
  eval "${prefix}_GH_DIR=\"\$gh_dir\""
  eval "${prefix}_WD_LOG=\"\$wd_log\""
}

rl_build_fixture RL_FX

# watchdog.sh を「呼び出し引数を1行ずつ記録するだけ」のスタブに差し替える
# （DEV_WORKFLOW_TEST_WATCHDOG_LOG が指す先へ追記。実際の監視は一切行わない）
cat > "${RL_FX_ROOT}/scripts/watchdog.sh" <<'FAKE_WD'
#!/bin/bash
echo "$*" >> "${DEV_WORKFLOW_TEST_WATCHDOG_LOG:?}"
exit 0
FAKE_WD
chmod +x "${RL_FX_ROOT}/scripts/watchdog.sh"

RL_DYN_OUT="$(
  PATH="${RL_FX_GH_DIR}:${PATH}" \
  DEV_WORKFLOW_DRY_RUN=1 \
  DEV_WORKFLOW_TEST_CMD='true' \
  DEV_WORKFLOW_MAX_TASKS=1 \
  DEV_WORKFLOW_TEST_WATCHDOG_LOG="$RL_FX_WD_LOG" \
  bash "${RL_FX_ROOT}/adapters/codex/run-loop.sh" 999 "$RL_FX_PROJECT" 2>&1
)"
RL_DYN_EXIT=$?

assert_exit_code "run-loop.sh: DRY_RUN実行（watchdogスタブあり）は exit 0 で完走する（#53）" 0 "$RL_DYN_EXIT"

RL_WD_CALLS="$(awk '{print $1}' "$RL_FX_WD_LOG" 2>/dev/null)"
assert_eq "run-loop.sh: DRY_RUN実行時、watchdog.shが --start → --wave → --stop の順で呼ばれる（#53）" \
  "$(printf -- '--start\n--wave\n--stop')" "$RL_WD_CALLS"

if [ "$(grep -c '^--wave' "$RL_FX_WD_LOG" 2>/dev/null)" = "1" ]; then
  pass "run-loop.sh: --wave はタスク1件（MAX_TASKS=1）につき1回だけ呼ばれる（#53）"
else
  fail "run-loop.sh: --wave はタスク1件（MAX_TASKS=1）につき1回だけ呼ばれる（#53）" "$(cat "$RL_FX_WD_LOG" 2>/dev/null)"
fi

case "$(grep '^--start' "$RL_FX_WD_LOG" 2>/dev/null)" in
  *'--epic epic999'*'--label Epic #999'*)
    pass "run-loop.sh: --start に --epic / --label が渡っている（#53）" ;;
  *)
    fail "run-loop.sh: --start に --epic / --label が渡っている（#53）" "$(grep '^--start' "$RL_FX_WD_LOG" 2>/dev/null)" ;;
esac

case "$(grep '^--wave' "$RL_FX_WD_LOG" 2>/dev/null)" in
  *'--epic epic999'*'--wave-no 1'*'--tasks 501'*)
    pass "run-loop.sh: --wave に --epic / --wave-no / --tasks が渡っている（#53）" ;;
  *)
    fail "run-loop.sh: --wave に --epic / --wave-no / --tasks が渡っている（#53）" "$(grep '^--wave' "$RL_FX_WD_LOG" 2>/dev/null)" ;;
esac

# --- watchdog.sh が無い環境でも run-loop 自体は継続すること ---
rl_build_fixture RL_FX2
# scripts/watchdog.sh を配置しない（「スクリプトが無い」環境の再現）
rm -f "${RL_FX2_ROOT}/scripts/watchdog.sh"

RL_MISSING_OUT="$(
  PATH="${RL_FX2_GH_DIR}:${PATH}" \
  DEV_WORKFLOW_DRY_RUN=1 \
  DEV_WORKFLOW_TEST_CMD='true' \
  DEV_WORKFLOW_MAX_TASKS=1 \
  bash "${RL_FX2_ROOT}/adapters/codex/run-loop.sh" 999 "$RL_FX2_PROJECT" 2>&1
)"
RL_MISSING_EXIT=$?

assert_exit_code "run-loop.sh: watchdog.sh が無くても run-loop 自体は exit 0 で継続する（#53）" 0 "$RL_MISSING_EXIT"

case "$RL_MISSING_OUT" in
  *"Epic一括レビュー"*)
    pass "run-loop.sh: watchdog.sh が無くてもEpic一括レビューまで到達する（#53）" ;;
  *)
    fail "run-loop.sh: watchdog.sh が無くてもEpic一括レビューまで到達する（#53）" "$RL_MISSING_OUT" ;;
esac

# ---------------------------------------------------------------------------
# skills/run/SKILL.md: 統合ゲート失敗時のリカバリと0レーン取り込みの分岐
# （回帰防止 #38, #41）
# ---------------------------------------------------------------------------

echo ""
echo "== skills/run/SKILL.md（統合ゲート失敗リカバリ・0レーン分岐の回帰防止 #38, #41） =="

RUN_SKILL="$RUN_SKILL_FLAT"

# #38: Step 8「統合ゲート失敗時の原因特定手順」は、この時点で checkout 中の wave ブランチに対して
# 実行される。`git branch -f` はチェックアウト中のブランチの強制更新を拒否するため使ってはならない。
RS_STEP8_RECOVERY="$(awk '/^#### 統合ゲート失敗時の原因特定手順/{f=1} /^#### スキップの伝播/{f=0} f' "$RUN_SKILL")"

case "$RS_STEP8_RECOVERY" in
  *'git branch -f "wave/'*)
    fail "SKILL.md: 統合ゲート失敗時の原因特定手順がチェックアウト中のwaveブランチに git branch -f を使っていない（#38）" "$RS_STEP8_RECOVERY" ;;
  *)
    pass "SKILL.md: 統合ゲート失敗時の原因特定手順がチェックアウト中のwaveブランチに git branch -f を使っていない（#38）" ;;
esac

case "$RS_STEP8_RECOVERY" in
  *'git checkout -B "wave/'*)
    pass "SKILL.md: 統合ゲート失敗時の原因特定手順が git checkout -B でwaveブランチを作り直す（#38）" ;;
  *)
    fail "SKILL.md: 統合ゲート失敗時の原因特定手順が git checkout -B でwaveブランチを作り直す（#38）" "$RS_STEP8_RECOVERY" ;;
esac

# #41: 取り込めたレーンが0本ならwaveブランチは存在しない。Step 5にその分岐が明記され、
# Step 6の冒頭にブランチ存在確認のガードがあること。
RS_STEP5="$(awk '/^### Step 5:/{f=1} /^### Step 6:/{f=0} f' "$RUN_SKILL")"

case "$RS_STEP5" in
  *"取り込めたレーンが0本"*)
    pass "SKILL.md: Step 5 に「取り込めたレーンが0本」の分岐が明記されている（#41）" ;;
  *)
    fail "SKILL.md: Step 5 に「取り込めたレーンが0本」の分岐が明記されている（#41）" "$RS_STEP5" ;;
esac

RS_STEP6="$(awk '/^### Step 6:/{f=1} /^### Step 7:/{f=0} f' "$RUN_SKILL")"

case "$RS_STEP6" in
  *'rev-parse --verify'*)
    pass "SKILL.md: Step 6 冒頭に wave ブランチ存在確認のガードがある（#41）" ;;
  *)
    fail "SKILL.md: Step 6 冒頭に wave ブランチ存在確認のガードがある（#41）" "$RS_STEP6" ;;
esac

# ---------------------------------------------------------------------------
# skills/run/SKILL.md: watchdog の結線（--start/--wave/--stop）とハング時の
# 運用手順の記述（回帰防止 #51）
# ---------------------------------------------------------------------------

echo ""
echo "== skills/run/SKILL.md（watchdog結線・ハング時運用手順の回帰防止 #51） =="

# --start の呼び出しが run-start の記述より後にあること（run マーカーが立った後に
# watchdogを起動する契約。マーカーより先に起動すると自己終了条件を誤検知しうる）
RS_RUN_START_LINE="$(grep -n 'notify-slack.sh" run-start' "$RUN_SKILL" | head -1 | cut -d: -f1)"
RS_WATCHDOG_START_LINE="$(grep -n 'watchdog.sh" --start' "$RUN_SKILL" | head -1 | cut -d: -f1)"

if [ -n "$RS_RUN_START_LINE" ] && [ -n "$RS_WATCHDOG_START_LINE" ] && [ "$RS_WATCHDOG_START_LINE" -gt "$RS_RUN_START_LINE" ]; then
  pass "SKILL.md: watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#51）"
else
  fail "SKILL.md: watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#51）" \
    "run-start行=${RS_RUN_START_LINE:-なし} --start行=${RS_WATCHDOG_START_LINE:-なし}"
fi

# --wave の呼び出しが Step 2（WAVE_BASEを記録する節）にあること
RS_STEP2="$(awk '/^### Step 2:/{f=1} /^### Step 3:/{f=0} f' "$RUN_SKILL")"

case "$RS_STEP2" in
  *'watchdog.sh" --wave'*)
    pass "SKILL.md: watchdog.sh --wave の呼び出しが Step 2（WAVE_BASE）の節にある（#51）" ;;
  *)
    fail "SKILL.md: watchdog.sh --wave の呼び出しが Step 2（WAVE_BASE）の節にある（#51）" "$RS_STEP2" ;;
esac

# --stop の呼び出しが「正常終了・異常終了を問わず」と書かれた節の中にあり、
# かつ完了通知（run-complete）より前の位置にあること
RS_CLEANUP="$(awk '/^## サンドボックスの後片付け（正常終了・異常終了を問わず必ず実行）/{f=1} /^## /{if (f && !/サンドボックスの後片付け/) f=0} f' "$RUN_SKILL")"

case "$RS_CLEANUP" in
  *'watchdog.sh" --stop'*)
    pass "SKILL.md: watchdog.sh --stop の呼び出しが「正常終了・異常終了を問わず」の節にある（#51）" ;;
  *)
    fail "SKILL.md: watchdog.sh --stop の呼び出しが「正常終了・異常終了を問わず」の節にある（#51）" "$RS_CLEANUP" ;;
esac

RS_WATCHDOG_STOP_LINE="$(grep -n 'watchdog.sh" --stop' "$RUN_SKILL" | head -1 | cut -d: -f1)"
RS_RUN_COMPLETE_LINE="$(grep -n 'notify-slack.sh" run-complete' "$RUN_SKILL" | head -1 | cut -d: -f1)"

if [ -n "$RS_WATCHDOG_STOP_LINE" ] && [ -n "$RS_RUN_COMPLETE_LINE" ] && [ "$RS_WATCHDOG_STOP_LINE" -lt "$RS_RUN_COMPLETE_LINE" ]; then
  pass "SKILL.md: watchdog.sh --stop の呼び出しが完了通知（run-complete）より前の位置にある（#51）"
else
  fail "SKILL.md: watchdog.sh --stop の呼び出しが完了通知（run-complete）より前の位置にある（#51）" \
    "--stop行=${RS_WATCHDOG_STOP_LINE:-なし} run-complete行=${RS_RUN_COMPLETE_LINE:-なし}"
fi

# 「ハングしたときに人間がすること」の節が存在し、--abort の説明と再実行の手順を含むこと
RS_HANG_SECTION="$(awk '/^## ハングしたときに人間がすること/{f=1} /^## 進捗表示/{f=0} f' "$RUN_SKILL")"

if [ -n "$RS_HANG_SECTION" ]; then
  pass "SKILL.md: 「ハングしたときに人間がすること」の節が存在する（#51）"
else
  fail "SKILL.md: 「ハングしたときに人間がすること」の節が存在する（#51）" "節が見つかりません"
fi

case "$RS_HANG_SECTION" in
  *'watchdog.sh" --abort'*)
    pass "SKILL.md: ハング時の節に watchdog.sh --abort の説明がある（#51）" ;;
  *)
    fail "SKILL.md: ハング時の節に watchdog.sh --abort の説明がある（#51）" "$RS_HANG_SECTION" ;;
esac

case "$RS_HANG_SECTION" in
  *'/dev-workflow:run'*)
    pass "SKILL.md: ハング時の節に再実行（/dev-workflow:run）の手順がある（#51）" ;;
  *)
    fail "SKILL.md: ハング時の節に再実行（/dev-workflow:run）の手順がある（#51）" "$RS_HANG_SECTION" ;;
esac

# 「自動で打ち切って再投入することはできない」旨の記述が存在すること
case "$RS_HANG_SECTION" in
  *'自動で打ち切って再投入する'*'原理的にできない'*)
    pass "SKILL.md: 「自動で打ち切って再投入することはできない」旨の記述がある（#51）" ;;
  *)
    fail "SKILL.md: 「自動で打ち切って再投入することはできない」旨の記述がある（#51）" "$RS_HANG_SECTION" ;;
esac

# セッション中断後は watchdog.sh --stop を実行する旨の記述が存在すること（レビュー#62）。
# セッションをプロセスごと中断するとStopフックが発火せずrunマーカーが残り続け、
# watchdogが打ち切りに気付かないまま無活動検知・エスカレーション通知を出し続けるため。
case "$RS_HANG_SECTION" in
  *'watchdog.sh" --stop'*)
    pass "SKILL.md: ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" ;;
  *)
    fail "SKILL.md: ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" "$RS_HANG_SECTION" ;;
esac

case "$RS_HANG_SECTION" in
  *'Stop フックが走らず'*'run マーカー'*)
    pass "SKILL.md: セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" ;;
  *)
    fail "SKILL.md: セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" "$RS_HANG_SECTION" ;;
esac

# ---------------------------------------------------------------------------
# skills/run/SKILL.md: WAVE_NO の採番ロジックと中断→再開時の挙動の記述（Task #54）
#
# 中断→再開で WAVE_NO がセッションごとに 0 から始まると、前回の残骸 wave ブランチを
# 誤って掴んでしまう事故が起きる（Epic #42 調査結果 7）。自律ループ冒頭で
# 既存の wave ブランチの番号の最大値から数え直すロジックが明記されていること、
# および再開時の挙動（残タスクの再計算・wave ブランチの採番し直し・取り込み済み
# コミットは失われない）が明記されていることを grep ベースで検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== skills/run/SKILL.md（WAVE_NO 採番・中断→再開時の挙動の回帰防止 #54） =="

RS_AUTONOMOUS_LOOP_HEADER="$(awk '/^## 自律ループ（YOLOモード、ウェーブ単位）/{f=1} /^### Step 1:/{f=0} f' "$RUN_SKILL")"

case "$RS_AUTONOMOUS_LOOP_HEADER" in
  *'for-each-ref'*'wave/${EPIC_NUM}/*'*)
    pass "SKILL.md: 自律ループ冒頭に既存 wave ブランチを列挙する WAVE_NO 採番ロジックがある（#54）" ;;
  *)
    fail "SKILL.md: 自律ループ冒頭に既存 wave ブランチを列挙する WAVE_NO 採番ロジックがある（#54）" "$RS_AUTONOMOUS_LOOP_HEADER" ;;
esac

case "$RS_AUTONOMOUS_LOOP_HEADER" in
  *'WAVE_NO="${WAVE_NO:-0}"'*)
    pass "SKILL.md: WAVE_NO 採番ロジックが既存ブランチ無しの場合 0 にフォールバックする（#54）" ;;
  *)
    fail "SKILL.md: WAVE_NO 採番ロジックが既存ブランチ無しの場合 0 にフォールバックする（#54）" "$RS_AUTONOMOUS_LOOP_HEADER" ;;
esac

case "$RS_AUTONOMOUS_LOOP_HEADER" in
  *'0 から始めてはならない'*)
    pass "SKILL.md: WAVE_NO を 0 から始めてはならない旨の説明がある（#54）" ;;
  *)
    fail "SKILL.md: WAVE_NO を 0 から始めてはならない旨の説明がある（#54）" "$RS_AUTONOMOUS_LOOP_HEADER" ;;
esac

RS_RESUME_SECTION="$(awk '/^3\. \*\*再開する場合\*\*/{f=1} /^\*\*Claude Code 側では/{f=0} f' "$RUN_SKILL")"

if [ -n "$RS_RESUME_SECTION" ]; then
  pass "SKILL.md: 「再開する場合」の説明ブロックが存在する（#54）"
else
  fail "SKILL.md: 「再開する場合」の説明ブロックが存在する（#54）" "節が見つかりません"
fi

case "$RS_RESUME_SECTION" in
  *'残タスクは open な Task issue'*'再計算される'*)
    pass "SKILL.md: 再開時に残タスクが open な Task issue から再計算される旨の記述がある（#54）" ;;
  *)
    fail "SKILL.md: 再開時に残タスクが open な Task issue から再計算される旨の記述がある（#54）" "$RS_RESUME_SECTION" ;;
esac

case "$RS_RESUME_SECTION" in
  *'wave ブランチは採番し直される'*)
    pass "SKILL.md: 再開時に wave ブランチが採番し直される旨の記述がある（#54）" ;;
  *)
    fail "SKILL.md: 再開時に wave ブランチが採番し直される旨の記述がある（#54）" "$RS_RESUME_SECTION" ;;
esac

case "$RS_RESUME_SECTION" in
  *'取り込み済みのコミットは失われない'*)
    pass "SKILL.md: 再開時に取り込み済みのコミットが失われない旨の記述がある（#54）" ;;
  *)
    fail "SKILL.md: 再開時に取り込み済みのコミットが失われない旨の記述がある（#54）" "$RS_RESUME_SECTION" ;;
esac

# ---------------------------------------------------------------------------
# skills-codex/dev-workflow-run/SKILL.md: 統合ゲートの記述が Claude 版と揃っていること
# （回帰防止 #37。#144でフルスイートはEpicにつき1回の「Epic 統合ゲート」に移動したため、
# Step 5 は取り込み検証＝可読性ガードだけを見る）
# ---------------------------------------------------------------------------

echo ""
echo "== skills-codex/dev-workflow-run/SKILL.md（統合ゲートの記述・回帰防止 #37, #144） =="

CODEX_RUN_SKILL="${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md"

CRS_STEP5="$(awk '/^### Step 5:/{f=1} /^### Step 6:/{f=0} f' "$CODEX_RUN_SKILL")"
CRS_EPICGATE="$(awk '/^## Epic 統合ゲート/{f=1} /^## Epic一括レビュー/{f=0} f' "$CODEX_RUN_SKILL")"

case "$CRS_STEP5" in
  *"check-readability.sh"*)
    pass "SKILL.md(codex): Step 5 が check-readability.sh の記述を含む" ;;
  *)
    fail "SKILL.md(codex): Step 5 が check-readability.sh の記述を含む" "$CRS_STEP5" ;;
esac

case "$CRS_STEP5" in
  *"sandbox-exec.sh"*)
    fail "SKILL.md(codex): Step 5 はプロジェクトの全テストを走らせない（Epic統合ゲートへ集約。#144）" "$CRS_STEP5" ;;
  *)
    pass "SKILL.md(codex): Step 5 はプロジェクトの全テストを走らせない（Epic統合ゲートへ集約。#144）" ;;
esac

case "$CRS_EPICGATE" in
  *"sandbox-exec.sh"*)
    pass "SKILL.md(codex): Epic統合ゲートが sandbox-exec.sh で全テストを実行する記述を含む（#144）" ;;
  *)
    fail "SKILL.md(codex): Epic統合ゲートが sandbox-exec.sh で全テストを実行する記述を含む（#144）" "$CRS_EPICGATE" ;;
esac

case "$CRS_EPICGATE" in
  *"対象の選択を"*"generator に委ねない"*)
    pass "SKILL.md(codex): Epic統合ゲートが「対象の選択をgeneratorに委ねない」を含む（#144）" ;;
  *)
    fail "SKILL.md(codex): Epic統合ゲートが「対象の選択をgeneratorに委ねない」を含む（#144）" "$CRS_EPICGATE" ;;
esac

case "$CRS_EPICGATE" in
  *"SKIP を通過扱いにしない"*)
    pass "SKILL.md(codex): Epic統合ゲートが「SKIPを通過扱いにしない」を含む（#144）" ;;
  *)
    fail "SKILL.md(codex): Epic統合ゲートが「SKIPを通過扱いにしない」を含む（#144）" "$CRS_EPICGATE" ;;
esac

if grep -q '^EPIC_NUMBER' "$CODEX_RUN_SKILL"; then
  fail "SKILL.md(codex): 未定義変数 \$EPIC_NUMBER を新たに導入していない" "EPIC_NUMBER の代入が見つかりました"
else
  if grep -q '\$EPIC_NUMBER' "$CODEX_RUN_SKILL"; then
    fail "SKILL.md(codex): 未定義変数 \$EPIC_NUMBER を参照していない" "$(grep -n '\$EPIC_NUMBER' "$CODEX_RUN_SKILL")"
  else
    pass "SKILL.md(codex): 未定義変数 \$EPIC_NUMBER を参照していない"
  fi
fi

# ---------------------------------------------------------------------------
# skills-codex/dev-workflow-run/SKILL.md: watchdog の結線（--start/--wave/--stop）と
# ハング時の運用手順の記述（回帰防止 #53。skills/run/SKILL.md #51 の Codex 側対応物）
# ---------------------------------------------------------------------------

echo ""
echo "== skills-codex/dev-workflow-run/SKILL.md（watchdog結線・ハング時運用手順の回帰防止 #53） =="

# --start の呼び出しが run-start の記述より後にあること
CRS_RUN_START_LINE="$(grep -n 'notify-slack.sh" run-start' "$CODEX_RUN_SKILL" | head -1 | cut -d: -f1)"
CRS_WATCHDOG_START_LINE="$(grep -n 'watchdog.sh" --start' "$CODEX_RUN_SKILL" | head -1 | cut -d: -f1)"

if [ -n "$CRS_RUN_START_LINE" ] && [ -n "$CRS_WATCHDOG_START_LINE" ] && [ "$CRS_WATCHDOG_START_LINE" -gt "$CRS_RUN_START_LINE" ]; then
  pass "SKILL.md(codex): watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#53）"
else
  fail "SKILL.md(codex): watchdog.sh --start の呼び出しが notify-slack.sh run-start より後にある（#53）" \
    "run-start行=${CRS_RUN_START_LINE:-なし} --start行=${CRS_WATCHDOG_START_LINE:-なし}"
fi

# --wave の呼び出しが Step 2（WAVE_BASEを記録し、レーンを作る節）にあること
CRS_STEP2="$(awk '/^### Step 2:/{f=1} /^### Step 3:/{f=0} f' "$CODEX_RUN_SKILL")"

case "$CRS_STEP2" in
  *'watchdog.sh" --wave'*)
    pass "SKILL.md(codex): watchdog.sh --wave の呼び出しが Step 2（WAVE_BASE）の節にある（#53）" ;;
  *)
    fail "SKILL.md(codex): watchdog.sh --wave の呼び出しが Step 2（WAVE_BASE）の節にある（#53）" "$CRS_STEP2" ;;
esac

# --stop の呼び出しが「正常終了・異常終了を問わず」と書かれた節の中にあり、
# かつ完了通知（run-complete）より前の位置にあること
CRS_CLEANUP="$(awk '/^## サンドボックスの後片付け（正常終了・異常終了を問わず必ず実行）/{f=1} /^## /{if (f && !/サンドボックスの後片付け/) f=0} f' "$CODEX_RUN_SKILL")"

case "$CRS_CLEANUP" in
  *'watchdog.sh" --stop'*)
    pass "SKILL.md(codex): watchdog.sh --stop の呼び出しが「正常終了・異常終了を問わず」の節にある（#53）" ;;
  *)
    fail "SKILL.md(codex): watchdog.sh --stop の呼び出しが「正常終了・異常終了を問わず」の節にある（#53）" "$CRS_CLEANUP" ;;
esac

CRS_WATCHDOG_STOP_LINE="$(grep -n 'watchdog.sh" --stop' "$CODEX_RUN_SKILL" | head -1 | cut -d: -f1)"
CRS_RUN_COMPLETE_LINE="$(grep -n 'notify-slack.sh" run-complete' "$CODEX_RUN_SKILL" | head -1 | cut -d: -f1)"

if [ -n "$CRS_WATCHDOG_STOP_LINE" ] && [ -n "$CRS_RUN_COMPLETE_LINE" ] && [ "$CRS_WATCHDOG_STOP_LINE" -lt "$CRS_RUN_COMPLETE_LINE" ]; then
  pass "SKILL.md(codex): watchdog.sh --stop の呼び出しが完了通知（run-complete）より前の位置にある（#53）"
else
  fail "SKILL.md(codex): watchdog.sh --stop の呼び出しが完了通知（run-complete）より前の位置にある（#53）" \
    "--stop行=${CRS_WATCHDOG_STOP_LINE:-なし} run-complete行=${CRS_RUN_COMPLETE_LINE:-なし}"
fi

# 「ハングしたときに人間がすること」の節が存在し、--abort の説明と再実行の手順を含むこと
CRS_HANG_SECTION="$(awk '/^## ハングしたときに人間がすること/{f=1} /^## Epic一括レビュー/{f=0} f' "$CODEX_RUN_SKILL")"

if [ -n "$CRS_HANG_SECTION" ]; then
  pass "SKILL.md(codex): 「ハングしたときに人間がすること」の節が存在する（#53）"
else
  fail "SKILL.md(codex): 「ハングしたときに人間がすること」の節が存在する（#53）" "節が見つかりません"
fi

case "$CRS_HANG_SECTION" in
  *'watchdog.sh" --abort'*)
    pass "SKILL.md(codex): ハング時の節に watchdog.sh --abort の説明がある（#53）" ;;
  *)
    fail "SKILL.md(codex): ハング時の節に watchdog.sh --abort の説明がある（#53）" "$CRS_HANG_SECTION" ;;
esac

# --abort はCodexではツール呼び出しを強制ブロックしない（ソフトな打ち切り依頼にとどまる）
# ことが明記されていること（レビュー#59。以前はClaude版と同一文面で「次のツール呼び出しで
# 効く」と誤って書かれていた）
case "$CRS_HANG_SECTION" in
  *'ブロックしない'*'ソフトな打ち切り依頼'*)
    pass "SKILL.md(codex): --abort がハードブロックではなくソフトな打ち切り依頼である旨が明記されている（#59）" ;;
  *)
    fail "SKILL.md(codex): --abort がハードブロックではなくソフトな打ち切り依頼である旨が明記されている（#59）" \
      "$CRS_HANG_SECTION" ;;
esac

case "$CRS_HANG_SECTION" in
  *'dev-workflow-run'*)
    pass "SKILL.md(codex): ハング時の節に再実行（dev-workflow-run スキル）の手順がある（#53）" ;;
  *)
    fail "SKILL.md(codex): ハング時の節に再実行（dev-workflow-run スキル）の手順がある（#53）" "$CRS_HANG_SECTION" ;;
esac

# 「自動で打ち切って再投入することはできない」旨の記述が存在すること（Claude版と同一方針）
case "$CRS_HANG_SECTION" in
  *'自動で打ち切って再投入する'*'実装しない'*)
    pass "SKILL.md(codex): 「自動で打ち切って再投入することは実装しない」旨の記述がある（#53）" ;;
  *)
    fail "SKILL.md(codex): 「自動で打ち切って再投入することは実装しない」旨の記述がある（#53）" "$CRS_HANG_SECTION" ;;
esac

# セッション中断後は watchdog.sh --stop を実行する旨の記述が存在すること（レビュー#62）。
# セッションをプロセスごと中断するとStopフックが発火せずrunマーカーが残り続け、
# watchdogが打ち切りに気付かないまま無活動検知・エスカレーション通知を出し続けるため。
case "$CRS_HANG_SECTION" in
  *'watchdog.sh" --stop'*)
    pass "SKILL.md(codex): ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" ;;
  *)
    fail "SKILL.md(codex): ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" "$CRS_HANG_SECTION" ;;
esac

case "$CRS_HANG_SECTION" in
  *'Stop フックが走らず'*'run マーカー'*)
    pass "SKILL.md(codex): セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" ;;
  *)
    fail "SKILL.md(codex): セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" "$CRS_HANG_SECTION" ;;
esac

# --abort が届く保証は run-loop.sh 経由の generator/evaluator セッションに限られ、
# このスキルをセッション内で直接回す経路では依存できない旨が明記されていること（レビュー#63）
case "$CRS_HANG_SECTION" in
  *'run-loop.sh'*'に限られる'*)
    pass "SKILL.md(codex): --abort が届く保証はrun-loop.sh経由のセッションに限られる旨の記述がある（#63）" ;;
  *)
    fail "SKILL.md(codex): --abort が届く保証はrun-loop.sh経由のセッションに限られる旨の記述がある（#63）" \
      "$CRS_HANG_SECTION" ;;
esac

case "$CRS_HANG_SECTION" in
  *'このスキル'*'セッション内で直接回している場合は'*'--abort'*'依存できない'*)
    pass "SKILL.md(codex): スキルをセッション内で直接回す経路では--abortに依存できない旨の記述がある（#63）" ;;
  *)
    fail "SKILL.md(codex): スキルをセッション内で直接回す経路では--abortに依存できない旨の記述がある（#63）" \
      "$CRS_HANG_SECTION" ;;
esac

case "$CRS_HANG_SECTION" in
  *'cwd で'*'区別できず'*)
    pass "SKILL.md(codex): メインループとサブエージェントをcwdで区別できない旨の記述がある（#63）" ;;
  *)
    fail "SKILL.md(codex): メインループとサブエージェントをcwdで区別できない旨の記述がある（#63）" \
      "$CRS_HANG_SECTION" ;;
esac

case "$CRS_HANG_SECTION" in
  *'確実に止められる唯一の手段は'*'セッションそのものを中断し'*'watchdog.sh --stop'*)
    pass "SKILL.md(codex): スキル直接実行時の唯一の確実な打ち切り手段がセッション中断+watchdog.sh --stopである旨の記述がある（#63）" ;;
  *)
    fail "SKILL.md(codex): スキル直接実行時の唯一の確実な打ち切り手段がセッション中断+watchdog.sh --stopである旨の記述がある（#63）" \
      "$CRS_HANG_SECTION" ;;
esac

# Claude Code版と挙動が同じ（アダプタ間に機能差を作らない）旨の記述が
# ハング節・自律実行開始節のいずれかに存在すること
CRS_FULL_SRC="$(cat "$CODEX_RUN_SKILL")"
case "$CRS_FULL_SRC" in
  *'アダプタ間に機能差を'*'作らない'*)
    pass "SKILL.md(codex): 「アダプタ間に機能差を作らない」旨の記述がある（#53）" ;;
  *)
    fail "SKILL.md(codex): 「アダプタ間に機能差を作らない」旨の記述がある（#53）" "" ;;
esac

# ---------------------------------------------------------------------------
# skills-codex/dev-workflow-run/SKILL.md, adapters/codex/run-loop.sh:
# WAVE_NO の採番ロジックと中断→再開時の挙動の記述（Task #54。skills/run/SKILL.md #54 の
# Codex 側対応物。Codex は `--lanes 1` 固定で毎タスク --create を呼ぶため、この不具合の
# 影響を Claude Code 版よりも強く受ける）
# ---------------------------------------------------------------------------

echo ""
echo "== skills-codex/dev-workflow-run/SKILL.md・run-loop.sh（WAVE_NO 採番・中断→再開時の挙動の回帰防止 #54） =="

CRS_AUTONOMOUS_LOOP_HEADER="$(awk '/^## 自律ループ（`lanes=1` 固定のウェーブ実行）/{f=1} /^### Step 1:/{f=0} f' "$CODEX_RUN_SKILL")"

case "$CRS_AUTONOMOUS_LOOP_HEADER" in
  *'for-each-ref'*'wave/${EPIC_NUM}/*'*)
    pass "SKILL.md(codex): 自律ループ冒頭に既存 wave ブランチを列挙する WAVE_NO 採番ロジックがある（#54）" ;;
  *)
    fail "SKILL.md(codex): 自律ループ冒頭に既存 wave ブランチを列挙する WAVE_NO 採番ロジックがある（#54）" "$CRS_AUTONOMOUS_LOOP_HEADER" ;;
esac

case "$CRS_AUTONOMOUS_LOOP_HEADER" in
  *'0 から始めてはならない'*)
    pass "SKILL.md(codex): WAVE_NO を 0 から始めてはならない旨の説明がある（#54）" ;;
  *)
    fail "SKILL.md(codex): WAVE_NO を 0 から始めてはならない旨の説明がある（#54）" "$CRS_AUTONOMOUS_LOOP_HEADER" ;;
esac

CRS_RESUME_SECTION="$(awk '/^3\. \*\*再開する場合\*\*/{f=1} /^\*\*Codex 側でも/{f=0} f' "$CODEX_RUN_SKILL")"

if [ -n "$CRS_RESUME_SECTION" ]; then
  pass "SKILL.md(codex): 「再開する場合」の説明ブロックが存在する（#54）"
else
  fail "SKILL.md(codex): 「再開する場合」の説明ブロックが存在する（#54）" "節が見つかりません"
fi

case "$CRS_RESUME_SECTION" in
  *'wave ブランチは採番し直される'*)
    pass "SKILL.md(codex): 再開時に wave ブランチが採番し直される旨の記述がある（#54）" ;;
  *)
    fail "SKILL.md(codex): 再開時に wave ブランチが採番し直される旨の記述がある（#54）" "$CRS_RESUME_SECTION" ;;
esac

case "$CRS_RESUME_SECTION" in
  *'取り込み済みのコミットは失われない'*)
    pass "SKILL.md(codex): 再開時に取り込み済みのコミットが失われない旨の記述がある（#54）" ;;
  *)
    fail "SKILL.md(codex): 再開時に取り込み済みのコミットが失われない旨の記述がある（#54）" "$CRS_RESUME_SECTION" ;;
esac

# run-loop.sh 本体（実際に再実行されるスクリプト）でも同じ採番ロジックになっていること
RUN_LOOP_WAVE_NO_BLOCK="$(awk '/^WAVE_NO=\$\(git -C "\$EPIC_WT" for-each-ref/{p=1} p{print} p && /WAVE_NO="\$\{WAVE_NO:-0\}"/{exit}' "$RUN_LOOP_SCRIPT")"

if [ -n "$RUN_LOOP_WAVE_NO_BLOCK" ]; then
  pass "run-loop.sh: WAVE_NO が既存 wave ブランチの番号の最大値から採番される（#54）"
else
  fail "run-loop.sh: WAVE_NO が既存 wave ブランチの番号の最大値から採番される（#54）" "ブロックが見つかりません"
fi

if grep -qE '^WAVE_NO=0$' "$RUN_LOOP_SCRIPT"; then
  fail "run-loop.sh: WAVE_NO を 0 固定で初期化していない（残骸 wave ブランチを掴む回帰の再発防止 #54）" \
    "$(grep -nE '^WAVE_NO=0$' "$RUN_LOOP_SCRIPT")"
else
  pass "run-loop.sh: WAVE_NO を 0 固定で初期化していない（残骸 wave ブランチを掴む回帰の再発防止 #54）"
fi

# ---------------------------------------------------------------------------
# notify-slack.sh: watchdog イベント（stall / stall-recovered / sleep-gap / budget、Task #46）
#
# 実送信（curl）は使わず、DEV_WORKFLOW_NOTIFY_SINK にファイルパスを渡して
# 組み立てた本文（JSON）をそのファイルへ書き出させて検証する。加えて PATH に
# 偽 curl を差し込み、sink 経由では実際の curl が一度も呼ばれないことも確認する
# （Slack へは実送信しない・Epic #42 完了条件）。
# ---------------------------------------------------------------------------

echo ""
echo "== notify-slack.sh: watchdog イベント（Task #46） =="

NS_SCRIPT="${REPO_ROOT}/scripts/notify-slack.sh"
NS_REPO="$(make_temp_repo)"
NS_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-notify-work.XXXXXX")"

# 偽curl。sink経路では呼ばれてはならない（呼ばれたら呼び出し内容をログへ残す）
NS_FAKE_BIN="${NS_WORK}/bin"
mkdir -p "$NS_FAKE_BIN"
NS_CURL_LOG="${NS_WORK}/curl-calls.log"
printf '#!/bin/bash\necho "called: $*" >> "%s"\nexit 0\n' "$NS_CURL_LOG" > "${NS_FAKE_BIN}/curl"
chmod +x "${NS_FAKE_BIN}/curl"

run_notify() {
  # run_notify <event> <arg> <sink_file>
  # Webhookはダミーの https URL・sinkはファイルパスを渡し、curlを呼ばせずに検証する。
  (
    cd "$NS_REPO" || exit 1
    PATH="${NS_FAKE_BIN}:${PATH}" \
    SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
    DEV_WORKFLOW_PROJECT_NAME="dwtest" \
    DEV_WORKFLOW_NOTIFY_SINK="$3" \
    bash "$NS_SCRIPT" "$1" "$2" < /dev/null
  )
}

read_sink() {
  [ -f "$1" ] && cat "$1" || printf ''
}

# --- stall: state=pre（ツール実行中に停止） ---
NS_STALL_PRE_SINK="${NS_WORK}/stall-pre.json"
run_notify "stall" "無活動920秒 / レーンA / 最後のツール: Bash（state=pre: ツール実行中に停止）" "$NS_STALL_PRE_SINK"
NS_STALL_PRE_EXIT=$?
NS_STALL_PRE_BODY="$(read_sink "$NS_STALL_PRE_SINK")"

assert_exit_code "stall(state=pre): exit 0" 0 "$NS_STALL_PRE_EXIT"
case "$NS_STALL_PRE_BODY" in
  *"応答なし"*) pass "stall: 見出し «応答なし» を含む" ;;
  *) fail "stall: 見出し «応答なし» を含む" "$NS_STALL_PRE_BODY" ;;
esac
case "$NS_STALL_PRE_BODY" in
  *"ツール実行中に停止"*) pass "stall(state=pre): 本文に «ツール実行中に停止» を含む（受け入れ条件2）" ;;
  *) fail "stall(state=pre): 本文に «ツール実行中に停止» を含む（受け入れ条件2）" "$NS_STALL_PRE_BODY" ;;
esac
case "$NS_STALL_PRE_BODY" in
  *"モデルの応答待ちで停止"*) fail "stall(state=pre): «モデルの応答待ちで停止» を誤って含まない" "$NS_STALL_PRE_BODY" ;;
  *) pass "stall(state=pre): «モデルの応答待ちで停止» を誤って含まない" ;;
esac
case "$NS_STALL_PRE_BODY" in
  *"<!channel>"*) pass "stall: 既定のメンション <!channel> を含む" ;;
  *) fail "stall: 既定のメンション <!channel> を含む" "$NS_STALL_PRE_BODY" ;;
esac

# --- stall: state=post（モデルの応答待ちで停止） ---
NS_STALL_POST_SINK="${NS_WORK}/stall-post.json"
run_notify "stall" "無活動920秒 / レーンB / 最後のツール: (なし)（state=post: モデルの応答待ちで停止）" "$NS_STALL_POST_SINK"
NS_STALL_POST_EXIT=$?
NS_STALL_POST_BODY="$(read_sink "$NS_STALL_POST_SINK")"

assert_exit_code "stall(state=post): exit 0" 0 "$NS_STALL_POST_EXIT"
case "$NS_STALL_POST_BODY" in
  *"モデルの応答待ちで停止"*) pass "stall(state=post): 本文に «モデルの応答待ちで停止» を含む（受け入れ条件2）" ;;
  *) fail "stall(state=post): 本文に «モデルの応答待ちで停止» を含む（受け入れ条件2）" "$NS_STALL_POST_BODY" ;;
esac
case "$NS_STALL_POST_BODY" in
  *"ツール実行中に停止"*) fail "stall(state=post): «ツール実行中に停止» を誤って含まない" "$NS_STALL_POST_BODY" ;;
  *) pass "stall(state=post): «ツール実行中に停止» を誤って含まない" ;;
esac

# --- stall-recovered ---
NS_RECOVERED_SINK="${NS_WORK}/stall-recovered.json"
run_notify "stall-recovered" "無活動980秒から復帰 / レーンA" "$NS_RECOVERED_SINK"
NS_RECOVERED_EXIT=$?
NS_RECOVERED_BODY="$(read_sink "$NS_RECOVERED_SINK")"

assert_exit_code "stall-recovered: exit 0" 0 "$NS_RECOVERED_EXIT"
case "$NS_RECOVERED_BODY" in
  *"応答が再開"*"無活動980秒から復帰 / レーンA"*) pass "stall-recovered: 見出しと詳細を含む" ;;
  *) fail "stall-recovered: 見出しと詳細を含む" "$NS_RECOVERED_BODY" ;;
esac

# --- sleep-gap: stallとは別イベントとして区別できる（受け入れ条件3） ---
NS_SLEEPGAP_SINK="${NS_WORK}/sleep-gap.json"
run_notify "sleep-gap" "tick間隔60秒に対し実経過620秒（スリープ復帰と判定・無活動時間から差し引き済み）" "$NS_SLEEPGAP_SINK"
NS_SLEEPGAP_EXIT=$?
NS_SLEEPGAP_BODY="$(read_sink "$NS_SLEEPGAP_SINK")"

assert_exit_code "sleep-gap: exit 0" 0 "$NS_SLEEPGAP_EXIT"
case "$NS_SLEEPGAP_BODY" in
  *"スリープ痕跡"*"tick間隔60秒に対し実経過620秒"*) pass "sleep-gap: 見出しと詳細を含む" ;;
  *) fail "sleep-gap: 見出しと詳細を含む" "$NS_SLEEPGAP_BODY" ;;
esac
case "$NS_SLEEPGAP_BODY" in
  *"応答なし"*) fail "sleep-gap: stallの見出し «応答なし» を誤って含まない（受け入れ条件3）" "$NS_SLEEPGAP_BODY" ;;
  *) pass "sleep-gap: stallの見出し «応答なし» を誤って含まない（受け入れ条件3）" ;;
esac
case "$NS_STALL_PRE_BODY" in
  *"スリープ痕跡"*) fail "stall: sleep-gapの見出し «スリープ痕跡» を誤って含まない（受け入れ条件3）" "$NS_STALL_PRE_BODY" ;;
  *) pass "stall: sleep-gapの見出し «スリープ痕跡» を誤って含まない（受け入れ条件3）" ;;
esac

# --- budget ---
NS_BUDGET_SINK="${NS_WORK}/budget.json"
run_notify "budget" "ウェーブ2 / 経過98分 / 予算90分" "$NS_BUDGET_SINK"
NS_BUDGET_EXIT=$?
NS_BUDGET_BODY="$(read_sink "$NS_BUDGET_SINK")"

assert_exit_code "budget: exit 0" 0 "$NS_BUDGET_EXIT"
case "$NS_BUDGET_BODY" in
  *"想定時間超過"*"ウェーブ2 / 経過98分 / 予算90分"*) pass "budget: 見出しと詳細を含む" ;;
  *) fail "budget: 見出しと詳細を含む" "$NS_BUDGET_BODY" ;;
esac
case "$NS_BUDGET_BODY" in
  *"<!channel>"*) pass "budget: 既定のメンション <!channel> を含む" ;;
  *) fail "budget: 既定のメンション <!channel> を含む" "$NS_BUDGET_BODY" ;;
esac

# --- curlが一度も実行されていないこと（sink経路でネットワークに出ない） ---
if [ -s "$NS_CURL_LOG" ]; then
  fail "notify-slack.sh: sink使用時にcurlが呼ばれない（実送信しない）" "$(read_sink "$NS_CURL_LOG")"
else
  pass "notify-slack.sh: sink使用時にcurlが呼ばれない（実送信しない）"
fi

# --- Webhook未設定: 何もせずexit 0、標準出力・標準エラーも空、sinkにも書かれない ---
NS_NOWEBHOOK_SINK="${NS_WORK}/nowebhook.json"
NS_NOWEBHOOK_OUT="$(
  cd "$NS_REPO" || exit 1
  unset SLACK_WEBHOOK_URL
  PATH="${NS_FAKE_BIN}:${PATH}" \
  DEV_WORKFLOW_NOTIFY_SINK="$NS_NOWEBHOOK_SINK" \
  bash "$NS_SCRIPT" stall "無活動920秒" < /dev/null 2>&1
)"
NS_NOWEBHOOK_EXIT=$?

assert_exit_code "Webhook未設定: stallイベントはexit 0（既存の挙動を維持）" 0 "$NS_NOWEBHOOK_EXIT"
assert_eq "Webhook未設定: 標準出力・標準エラーが空" "" "$NS_NOWEBHOOK_OUT"
if [ -f "$NS_NOWEBHOOK_SINK" ]; then
  fail "Webhook未設定: sinkファイルが作られない" "sinkファイルが作成されました"
else
  pass "Webhook未設定: sinkファイルが作られない"
fi

# ---------------------------------------------------------------------------
# notify-slack.sh: 既存イベント（run-start / run-complete / stop / notification）の
# 挙動が変わっていないこと（Task #46 の回帰確認）
# ---------------------------------------------------------------------------

echo ""
echo "== notify-slack.sh: 既存イベントの回帰確認（Task #46） =="

# --- run-start: マーカーを作るだけで通知はしない ---
NS_RUNSTART_SINK="${NS_WORK}/run-start.json"
NS_RUNSTART_OUT="$(
  cd "$NS_REPO" || exit 1
  PATH="${NS_FAKE_BIN}:${PATH}" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$NS_RUNSTART_SINK" \
  bash "$NS_SCRIPT" run-start "回帰テスト用ラベル" < /dev/null 2>&1
)"
NS_RUNSTART_EXIT=$?

assert_exit_code "run-start: exit 0（既存挙動）" 0 "$NS_RUNSTART_EXIT"
assert_eq "run-start: 標準出力・標準エラーが空（既存挙動）" "" "$NS_RUNSTART_OUT"
if [ -f "$NS_RUNSTART_SINK" ]; then
  fail "run-start: 通知しない（既存挙動）" "sinkに書き込みがありました"
else
  pass "run-start: 通知しない（既存挙動）"
fi
NS_RUNSTART_MARKER_FILE="${NS_REPO}/.claude/.dev-workflow-run"
if [ -f "$NS_RUNSTART_MARKER_FILE" ]; then
  assert_eq "run-start: マーカーにラベルを書く（既存挙動）" "回帰テスト用ラベル" "$(read_sink "$NS_RUNSTART_MARKER_FILE")"
else
  fail "run-start: マーカーが作られる（既存挙動）" "マーカーファイルがありません"
fi

# --- run-complete: マーカーを消し、ラベル入りの見出しで通知する ---
NS_RUNCOMPLETE_SINK="${NS_WORK}/run-complete.json"
NS_RUNCOMPLETE_OUT="$(
  cd "$NS_REPO" || exit 1
  PATH="${NS_FAKE_BIN}:${PATH}" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$NS_RUNCOMPLETE_SINK" \
  bash "$NS_SCRIPT" run-complete "全タスク完了" < /dev/null 2>&1
)"
NS_RUNCOMPLETE_EXIT=$?
NS_RUNCOMPLETE_BODY="$(read_sink "$NS_RUNCOMPLETE_SINK")"

assert_exit_code "run-complete: exit 0（既存挙動）" 0 "$NS_RUNCOMPLETE_EXIT"
case "$NS_RUNCOMPLETE_BODY" in
  *"完了 — 回帰テスト用ラベル"*) pass "run-complete: 見出しにラベルを含む（既存挙動）" ;;
  *) fail "run-complete: 見出しにラベルを含む（既存挙動）" "$NS_RUNCOMPLETE_BODY" ;;
esac
case "$NS_RUNCOMPLETE_BODY" in
  *"全タスク完了"*) pass "run-complete: サマリーを本文に含む（既存挙動）" ;;
  *) fail "run-complete: サマリーを本文に含む（既存挙動）" "$NS_RUNCOMPLETE_BODY" ;;
esac
if [ -f "$NS_RUNSTART_MARKER_FILE" ]; then
  fail "run-complete: マーカーを消す（既存挙動）" "マーカーが残っています"
else
  pass "run-complete: マーカーを消す（既存挙動）"
fi

# --- stop: マーカーがある状態は「自律実行が停止」として通知しマーカーを消す ---
(
  cd "$NS_REPO" || exit 1
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="${NS_WORK}/run-start-2.json" \
  bash "$NS_SCRIPT" run-start "中断テスト用ラベル" < /dev/null
) >/dev/null 2>&1

NS_STOP_SINK="${NS_WORK}/stop.json"
NS_STOP_OUT="$(
  cd "$NS_REPO" || exit 1
  PATH="${NS_FAKE_BIN}:${PATH}" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$NS_STOP_SINK" \
  bash "$NS_SCRIPT" stop <<< '{}' 2>&1
)"
NS_STOP_EXIT=$?
NS_STOP_BODY="$(read_sink "$NS_STOP_SINK")"

assert_exit_code "stop（マーカーあり）: exit 0（既存挙動）" 0 "$NS_STOP_EXIT"
case "$NS_STOP_BODY" in
  *"自律実行が停止 — 中断テスト用ラベル"*) pass "stop（マーカーあり）: 「自律実行が停止」の見出しを含む（既存挙動）" ;;
  *) fail "stop（マーカーあり）: 「自律実行が停止」の見出しを含む（既存挙動）" "$NS_STOP_BODY" ;;
esac
if [ -f "$NS_RUNSTART_MARKER_FILE" ]; then
  fail "stop（マーカーあり）: マーカーを消す（既存挙動）" "マーカーが残っています"
else
  pass "stop（マーカーあり）: マーカーを消す（既存挙動）"
fi

# --- notification: 承認待ちは既定でも通知される ---
NS_NOTIF_SINK="${NS_WORK}/notification.json"
NS_NOTIF_OUT="$(
  cd "$NS_REPO" || exit 1
  PATH="${NS_FAKE_BIN}:${PATH}" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$NS_NOTIF_SINK" \
  DEV_WORKFLOW_NOTIFY_COOLDOWN=0 \
  bash "$NS_SCRIPT" notification <<< '{"message":"Claude needs your permission to use Bash"}' 2>&1
)"
NS_NOTIF_EXIT=$?
NS_NOTIF_BODY="$(read_sink "$NS_NOTIF_SINK")"

assert_exit_code "notification（承認待ち）: exit 0（既存挙動）" 0 "$NS_NOTIF_EXIT"
case "$NS_NOTIF_BODY" in
  *"承認待ち"*) pass "notification（承認待ち）: 見出しを含む（既存挙動）" ;;
  *) fail "notification（承認待ち）: 見出しを含む（既存挙動）" "$NS_NOTIF_BODY" ;;
esac

# --- 回帰確認の全呼び出しを通じてもcurlは一度も呼ばれていない ---
if [ -s "$NS_CURL_LOG" ]; then
  fail "notify-slack.sh: 既存イベントの検証中もcurlが呼ばれない" "$(read_sink "$NS_CURL_LOG")"
else
  pass "notify-slack.sh: 既存イベントの検証中もcurlが呼ばれない"
fi

# ---------------------------------------------------------------------------
# ケース: scripts/heartbeat.sh（フックから生存信号を記録・外部プロセス0、Task #44）
#
# PreToolUse / PostToolUse フックから高頻度に呼ばれるため、内部で date / jq / sed / grep
# を一切呼ばない（唯一の例外は原子的な置き換えに使う mv）。マーカールートの解決は
# scripts/lib/marker-root.sh（#43）に委譲する（Epic #42 仕様書「3. ファイルと責務」）。
# ---------------------------------------------------------------------------

echo "== scripts/heartbeat.sh（フックから生存信号を記録・外部プロセス0・Task #44） =="

HEARTBEAT_SCRIPT="${REPO_ROOT}/scripts/heartbeat.sh"

bash -n "$HEARTBEAT_SCRIPT" >/dev/null 2>&1
assert_exit_code "heartbeat.sh: bash -n が通る（構文エラーなし）" 0 $?

HB_MARKER_FILE=".dev-workflow-heartbeat"

# --- 書式: pre 呼び出しは <epoch>\t<pre>\t<ツール名> の1行だけを書く ---
HB_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HB_REPO}/.claude"
HB_TARGET="${HB_REPO}/.claude/${HB_MARKER_FILE}"

HB_JSON_PRE=$'{\n  "session_id": "abc",\n  "cwd": "'"${HB_REPO}"'",\n  "tool_name": "Bash",\n  "tool_input": {\n    "command": "echo hi"\n  }\n}'

HB_PRE_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" pre <<< "$HB_JSON_PRE" 2>&1)"
assert_exit_code "heartbeat.sh pre: exit 0 で終わる" 0 $?
assert_eq "heartbeat.sh pre: 無出力" "" "$HB_PRE_OUT"

if [ -f "$HB_TARGET" ]; then
  HB_EPOCH="" HB_STATE="" HB_TOOL=""
  IFS=$'\t' read -r HB_EPOCH HB_STATE HB_TOOL < "$HB_TARGET"
  case "$HB_EPOCH" in
    ''|*[!0-9]*) fail "heartbeat.sh pre: 1列目が epoch 秒（数字のみ）" "実際=[${HB_EPOCH}]" ;;
    *)           pass "heartbeat.sh pre: 1列目が epoch 秒（数字のみ）" ;;
  esac
  assert_eq "heartbeat.sh pre: 2列目が pre（ツール実行中を示す）" "pre" "$HB_STATE"
  assert_eq "heartbeat.sh pre: 3列目が複数行JSONからツール名を正しく抽出" "Bash" "$HB_TOOL"
  HB_LINE_COUNT="$(wc -l < "$HB_TARGET" | tr -d ' ')"
  assert_eq "heartbeat.sh pre: マーカーファイルは1行だけ" "1" "$HB_LINE_COUNT"
else
  fail "heartbeat.sh pre: マーカーファイルが書かれる" "存在しません: ${HB_TARGET}"
fi

# --- post 呼び出し: 別の state・別のツール名で上書き（追記ではなく置き換え） ---
HB_JSON_POST=$'{\n  "cwd": "'"${HB_REPO}"'",\n  "tool_name": "mcp__foo__bar"\n}'
HB_POST_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" post <<< "$HB_JSON_POST" 2>&1)"
assert_exit_code "heartbeat.sh post: exit 0 で終わる" 0 $?
assert_eq "heartbeat.sh post: 無出力" "" "$HB_POST_OUT"

IFS=$'\t' read -r HB_EPOCH2 HB_STATE2 HB_TOOL2 < "$HB_TARGET"
assert_eq "heartbeat.sh post: 2列目が post（モデル応答待ちを示す）" "post" "$HB_STATE2"
assert_eq "heartbeat.sh post: 3列目がツール名(mcp形式)を正しく抽出" "mcp__foo__bar" "$HB_TOOL2"
HB_LINE_COUNT2="$(wc -l < "$HB_TARGET" | tr -d ' ')"
assert_eq "heartbeat.sh post: 上書き後もマーカーファイルは1行だけ（追記でない）" "1" "$HB_LINE_COUNT2"

# --- ツール名が取れない入力でも "-" として記録し exit 0 ---
HB_JSON_NOTOOL=$'{\n  "cwd": "'"${HB_REPO}"'"\n}'
HB_NOTOOL_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" pre <<< "$HB_JSON_NOTOOL" 2>&1)"
assert_exit_code "heartbeat.sh: tool_name が無いJSONでも exit 0" 0 $?
IFS=$'\t' read -r HB_EPOCH3 HB_STATE3 HB_TOOL3 < "$HB_TARGET"
assert_eq "heartbeat.sh: tool_name が無ければ '-' として記録" "-" "$HB_TOOL3"

# --- 壊れたJSON（想定外の入力）でも exit 0、"-" として記録 ---
HB_GARBAGE='not even json { [ garbage without any structure'
HB_GARBAGE_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" post <<< "$HB_GARBAGE" 2>&1)"
assert_exit_code "heartbeat.sh: 壊れたJSONでも exit 0" 0 $?
assert_eq "heartbeat.sh: 壊れたJSONでも無出力" "" "$HB_GARBAGE_OUT"
IFS=$'\t' read -r HB_EPOCH4 HB_STATE4 HB_TOOL4 < "$HB_TARGET"
assert_eq "heartbeat.sh: 壊れたJSONでは '-' として記録" "-" "$HB_TOOL4"

# --- 空のstdinでも exit 0（記録は続ける。マーカールート自体は解決できているため） ---
HB_EMPTY_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" pre < /dev/null 2>&1)"
assert_exit_code "heartbeat.sh: 空のstdinでも exit 0" 0 $?
assert_eq "heartbeat.sh: 空のstdinでも無出力" "" "$HB_EMPTY_OUT"

# --- 不正な引数（pre/post以外）は無出力・exit 0 ---
HB_BADARG_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HB_REPO" bash "$HEARTBEAT_SCRIPT" bogus < /dev/null 2>&1)"
assert_exit_code "heartbeat.sh: 不正な引数でも exit 0" 0 $?
assert_eq "heartbeat.sh: 不正な引数では無出力" "" "$HB_BADARG_OUT"

# --- git管理外のディレクトリでは exit 0 かつ無出力（マーカーは書かない） ---
HB_NONGIT="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hb-nongit.XXXXXX")"
HB_NONGIT_OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-hb-nongit-out.XXXXXX")"
(
  cd "$HB_NONGIT" || exit 1
  unset DEV_WORKFLOW_MARKER_ROOT CLAUDE_PROJECT_DIR
  bash "$HEARTBEAT_SCRIPT" pre < /dev/null > "$HB_NONGIT_OUT_FILE" 2>&1
)
HB_NONGIT_EXIT=$?
HB_NONGIT_OUT="$(cat "$HB_NONGIT_OUT_FILE")"
assert_exit_code "heartbeat.sh: git管理外のディレクトリでは exit 0" 0 "$HB_NONGIT_EXIT"
assert_eq "heartbeat.sh: git管理外のディレクトリでは無出力" "" "$HB_NONGIT_OUT"

# --- .claude が無いリポジトリでは exit 0 かつ無出力・マーカーは作られない ---
HB_NOCLAUDE_REPO="$(canon_root "$(make_temp_repo)")"
HB_NOCLAUDE_OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/dw-test-hb-noclaude-out.XXXXXX")"
DEV_WORKFLOW_MARKER_ROOT="$HB_NOCLAUDE_REPO" bash "$HEARTBEAT_SCRIPT" pre < /dev/null \
  > "$HB_NOCLAUDE_OUT_FILE" 2>&1
HB_NOCLAUDE_EXIT=$?
HB_NOCLAUDE_OUT="$(cat "$HB_NOCLAUDE_OUT_FILE")"
assert_exit_code "heartbeat.sh: .claude が無ければ exit 0" 0 "$HB_NOCLAUDE_EXIT"
assert_eq "heartbeat.sh: .claude が無ければ無出力" "" "$HB_NOCLAUDE_OUT"
if [ -e "${HB_NOCLAUDE_REPO}/.claude" ]; then
  fail "heartbeat.sh: .claude が無ければ作成もマーカー書き込みもしない" ".claude が作られました"
else
  pass "heartbeat.sh: .claude が無ければ作成もマーカー書き込みもしない"
fi

# --- worktreeから呼んでもメインリポのルートに書かれる ---
HB_WT_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HB_WT_REPO}/.claude"
HB_WT_DIR="${HB_WT_REPO}/.claude/worktrees/agent-hbtest"
make_worktree "$HB_WT_REPO" "$HB_WT_DIR" "hb-agent-branch"
HB_WT_JSON=$'{\n  "cwd": "'"${HB_WT_DIR}"'",\n  "tool_name": "Write"\n}'
(
  cd "$HB_WT_DIR" || exit 1
  unset DEV_WORKFLOW_MARKER_ROOT CLAUDE_PROJECT_DIR
  bash "$HEARTBEAT_SCRIPT" post <<< "$HB_WT_JSON" > /dev/null 2>&1
)
HB_WT_TARGET="${HB_WT_REPO}/.claude/${HB_MARKER_FILE}"
if [ -f "$HB_WT_TARGET" ]; then
  IFS=$'\t' read -r HB_WT_EPOCH HB_WT_STATE HB_WT_TOOL < "$HB_WT_TARGET"
  assert_eq "heartbeat.sh: worktreeから呼んでもメインリポのルートに書かれる" "Write" "$HB_WT_TOOL"
else
  fail "heartbeat.sh: worktreeから呼んでもメインリポのルートに書かれる" "存在しません: ${HB_WT_TARGET}"
fi

# --- 同時に複数プロセスから呼ばれても、常に「正しい1行」である（行の混在・破損が無い） ---
HB_CONC_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HB_CONC_REPO}/.claude"
HB_CONC_TARGET="${HB_CONC_REPO}/.claude/${HB_MARKER_FILE}"
HB_CONC_JSON_A=$'{\n  "cwd": "'"${HB_CONC_REPO}"'",\n  "tool_name": "ToolA"\n}'
HB_CONC_JSON_B=$'{\n  "cwd": "'"${HB_CONC_REPO}"'",\n  "tool_name": "ToolB"\n}'
HB_CONC_JSON_C=$'{\n  "cwd": "'"${HB_CONC_REPO}"'",\n  "tool_name": "ToolC"\n}'
(
  DEV_WORKFLOW_MARKER_ROOT="$HB_CONC_REPO" bash "$HEARTBEAT_SCRIPT" pre  <<< "$HB_CONC_JSON_A" >/dev/null 2>&1 &
  DEV_WORKFLOW_MARKER_ROOT="$HB_CONC_REPO" bash "$HEARTBEAT_SCRIPT" post <<< "$HB_CONC_JSON_B" >/dev/null 2>&1 &
  DEV_WORKFLOW_MARKER_ROOT="$HB_CONC_REPO" bash "$HEARTBEAT_SCRIPT" pre  <<< "$HB_CONC_JSON_C" >/dev/null 2>&1 &
  wait
)
HB_CONC_LINES="$(wc -l < "$HB_CONC_TARGET" | tr -d ' ')"
assert_eq "heartbeat.sh: 並行3プロセスから呼ばれてもファイルは常に1行" "1" "$HB_CONC_LINES"
IFS=$'\t' read -r HB_CONC_EPOCH HB_CONC_STATE HB_CONC_TOOL < "$HB_CONC_TARGET"
case "$HB_CONC_STATE" in
  pre|post) : ;;
  *) HB_CONC_STATE="invalid" ;;
esac
case "$HB_CONC_TOOL" in
  ToolA|ToolB|ToolC) : ;;
  *) HB_CONC_TOOL="invalid" ;;
esac
if [ "$HB_CONC_STATE" != "invalid" ] && [ "$HB_CONC_TOOL" != "invalid" ]; then
  pass "heartbeat.sh: 並行書き込みの結果は3者のいずれか1つの完全な行（破損・混在なし）"
else
  fail "heartbeat.sh: 並行書き込みの結果は3者のいずれか1つの完全な行（破損・混在なし）" \
    "実際の内容: $(cat "$HB_CONC_TARGET" 2>/dev/null)"
fi

# --- stdinがttyのときは読まない設計になっていることの静的確認 ---
if grep -qE '\[ ! -t 0 \]' "$HEARTBEAT_SCRIPT"; then
  pass "heartbeat.sh: stdinがtty（対話実行）のときは読まないガードがある"
else
  fail "heartbeat.sh: stdinがtty（対話実行）のときは読まないガードがある" "[ ! -t 0 ] が見つかりません"
fi

# --- スクリプト本体が date / jq を呼んでいないことの静的確認（受け入れ条件10の前提） ---
# コメント行は対象外にし、単語境界での一致だけを見る
HB_FORBIDDEN_HITS="$(grep -v '^[[:space:]]*#' "$HEARTBEAT_SCRIPT" \
  | grep -E '(^|[^A-Za-z0-9_])(date|jq)[[:space:]]' || true)"
if [ -z "$HB_FORBIDDEN_HITS" ]; then
  pass "heartbeat.sh: スクリプト本体が date / jq を呼んでいない"
else
  fail "heartbeat.sh: スクリプト本体が date / jq を呼んでいない" "$HB_FORBIDDEN_HITS"
fi

# --- 性能: 100回連続実行が「素のプロセス起動コスト」に対して過大でないこと（受け入れ条件10） ---
# heartbeat.sh は毎回 bash プロセスとして spawn される（フック呼び出しの実態）ため、
# 絶対時間には bind mount 越しのファイル open や git worktree 越しのサンドボックスなど
# 実行環境固有のプロセス起動オーバーヘッドが乗る（実測: Docker Desktop on Windows の
# bind mount 環境では、素の `bash -c 'exit 0'` を100回起動するだけで数秒かかることがある）。
# 絶対時間を固定の秒数で決め打つと環境差でフレーキーになるため、同一環境で素のプロセス起動を
# 100回行った基準時間（FLOOR）を測り、heartbeat.sh 自身のロジック（marker-root.sh の
# source・stdin読み取り・tmp書き込み+mv）に許される予算をその上乗せ分として評価する。
# 外部プロセス（date/jq等）を呼ぶ regression が入れば、その分だけ FLOOR に対して余分な
# プロセス起動が積み増しされるため、この相対評価でも十分検出できる。
HB_PERF_FLOOR_START=""
printf -v HB_PERF_FLOOR_START '%(%s)T' -1
HB_PERF_FLOOR_I=0
while [ "$HB_PERF_FLOOR_I" -lt 100 ]; do
  bash -c 'exit 0' >/dev/null 2>&1
  HB_PERF_FLOOR_I=$((HB_PERF_FLOOR_I + 1))
done
HB_PERF_FLOOR_END=""
printf -v HB_PERF_FLOOR_END '%(%s)T' -1
HB_PERF_FLOOR=$((HB_PERF_FLOOR_END - HB_PERF_FLOOR_START))

HB_PERF_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HB_PERF_REPO}/.claude"
HB_PERF_JSON=$'{\n  "cwd": "'"${HB_PERF_REPO}"'",\n  "tool_name": "Bash"\n}'
HB_PERF_START=""
printf -v HB_PERF_START '%(%s)T' -1
HB_PERF_I=0
while [ "$HB_PERF_I" -lt 100 ]; do
  DEV_WORKFLOW_MARKER_ROOT="$HB_PERF_REPO" bash "$HEARTBEAT_SCRIPT" pre <<< "$HB_PERF_JSON" >/dev/null 2>&1
  HB_PERF_I=$((HB_PERF_I + 1))
done
HB_PERF_END=""
printf -v HB_PERF_END '%(%s)T' -1
HB_PERF_ELAPSED=$((HB_PERF_END - HB_PERF_START))

# FLOOR + 5秒: heartbeat.sh 自身の純粋なbashロジック（外部プロセス無し）に許される予算。
HB_PERF_BUDGET=$((HB_PERF_FLOOR + 5))
if [ "$HB_PERF_ELAPSED" -le "$HB_PERF_BUDGET" ]; then
  pass "heartbeat.sh: 100回連続実行がプロセス起動コストに対して過大でない（実測 ${HB_PERF_ELAPSED}s / floor ${HB_PERF_FLOOR}s+5s予算・受け入れ条件10）"
else
  fail "heartbeat.sh: 100回連続実行がプロセス起動コストに対して過大でない" \
    "実測 ${HB_PERF_ELAPSED}s > floor ${HB_PERF_FLOOR}s + 5s予算"
fi

# ---------------------------------------------------------------------------
# scripts/heartbeat.sh: 打ち切り（--abort）判定（Task #50、Epic #42。cwd拡張はレビュー#59, #61）
#
# .dev-workflow-abort は人間が watchdog.sh --abort を明示的に叩いたときだけ作られる
# （Epic #42 仕様書「5. 打ち切りの仕様」）。heartbeat.sh pre はこのフラグと、フック入力
# JSON の cwd が Claude のisolation worktree（.claude/worktrees/agent-）または
# Codex のEpic共有worktree（.codex/worktrees/。Codexにはタスクごとのisolation worktreeが
# 無いため代わりにこちらを対象にする）を含む場合にのみツール呼び出しを拒否する。
# run のメインループ（Claude: epic worktree・リポジトリルート／Codex: run-loop.sh自体は
# codexセッションではなくフックが発火しない）は絶対に拒否しない。
# Codexのブロック契約はsystemMessageのみでcontinue非対応（後述）のため、実際にはハード
# ブロックにならないソフトな打ち切り依頼になる点に注意（詳細はheartbeat.sh本体を参照）。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/heartbeat.sh: 打ち切り（--abort）判定（Task #50） =="

HBA_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HBA_REPO}/.claude"
HBA_ABORT_FLAG="${HBA_REPO}/.claude/.dev-workflow-abort"
HBA_AGENT_CWD="${HBA_REPO}/.claude/worktrees/agent-hba-test"
HBA_EPIC_CWD="${HBA_REPO}/.claude/worktrees/epic99"
HBA_ROOT_CWD="${HBA_REPO}"

printf 'テスト用の打ち切り理由\n' > "$HBA_ABORT_FLAG"

# --- フラグあり + cwdがagent worktree → 拒否される（Claude契約: exit 2 + stderr） ---
HBA_JSON_AGENT=$'{\n  "cwd": "'"${HBA_AGENT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_AGENT_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_AGENT" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・agent worktreeのcwd → exit 2で拒否" 2 $?
case "$HBA_AGENT_OUT" in
  *"テスト用の打ち切り理由"*) pass "heartbeat.sh: 拒否メッセージに--abortの理由が含まれる" ;;
  *)                          fail "heartbeat.sh: 拒否メッセージに--abortの理由が含まれる" "$HBA_AGENT_OUT" ;;
esac
case "$HBA_AGENT_OUT" in
  *"打ち切りが指示されました"*) pass "heartbeat.sh: 拒否メッセージに中止・報告の指示が含まれる" ;;
  *)                            fail "heartbeat.sh: 拒否メッセージに中止・報告の指示が含まれる" "$HBA_AGENT_OUT" ;;
esac

# 拒否されても生存信号自体は記録される（打ち切り判定は書き込みの後に行う設計）
if [ -f "${HBA_REPO}/.claude/.dev-workflow-heartbeat" ]; then
  pass "heartbeat.sh: 拒否時も生存信号（heartbeatマーカー）は記録される"
else
  fail "heartbeat.sh: 拒否時も生存信号（heartbeatマーカー）は記録される" "マーカーファイルが無い"
fi

# --- フラグあり + cwdがepic worktree → 拒否されない（run本体を絶対に殺さない） ---
HBA_JSON_EPIC=$'{\n  "cwd": "'"${HBA_EPIC_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_EPIC_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_EPIC" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・epic worktreeのcwd → 拒否されない（exit 0）" 0 $?
assert_eq "heartbeat.sh: abortフラグあり・epic worktreeのcwd → 無出力" "" "$HBA_EPIC_OUT"

# --- フラグあり + cwdがリポジトリルート → 拒否されない ---
HBA_JSON_ROOT=$'{\n  "cwd": "'"${HBA_ROOT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_ROOT_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_ROOT" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・リポジトリルートのcwd → 拒否されない（exit 0）" 0 $?
assert_eq "heartbeat.sh: abortフラグあり・リポジトリルートのcwd → 無出力" "" "$HBA_ROOT_OUT"

# --- フラグが無ければ、cwdがagent worktreeでも拒否されない ---
HBA_NOFLAG_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HBA_NOFLAG_REPO}/.claude"
HBA_NOFLAG_AGENT_CWD="${HBA_NOFLAG_REPO}/.claude/worktrees/agent-hba-noflag"
HBA_JSON_NOFLAG=$'{\n  "cwd": "'"${HBA_NOFLAG_AGENT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_NOFLAG_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_NOFLAG_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_NOFLAG" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグが無ければagent worktreeでも拒否されない" 0 $?

# --- Codex契約: exit 0 + stdoutに {"continue":false, ...} のJSON ---
HBA_CODEX_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=codex \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_AGENT" 2>&1)"
assert_exit_code "heartbeat.sh: Codex契約はexit 0で終わる" 0 $?
case "$HBA_CODEX_OUT" in
  *'"continue":false'*) pass "heartbeat.sh: Codex契約はstdoutに\"continue\":falseを含むJSONを出す" ;;
  *)                     fail "heartbeat.sh: Codex契約はstdoutに\"continue\":falseを含むJSONを出す" "$HBA_CODEX_OUT" ;;
esac
case "$HBA_CODEX_OUT" in
  *"テスト用の打ち切り理由"*) pass "heartbeat.sh: Codex契約のJSONにも--abortの理由が含まれる" ;;
  *)                          fail "heartbeat.sh: Codex契約のJSONにも--abortの理由が含まれる" "$HBA_CODEX_OUT" ;;
esac

# --- フラグあり + cwdがCodexのEpic共有worktree（.codex/worktrees/<epic>）→ 打ち切り判定の
#     対象になる（レビュー#59, #61）。Codexにはタスクごとのisolation worktreeという概念自体が
#     無く、generator/evaluatorは常にこの共有worktreeで動くため、Claudeの
#     `.claude/worktrees/agent-` と同じ役割をこのパターンが担う ---
HBA_CODEX_WT_CWD="${HBA_REPO}/.codex/worktrees/42"
HBA_JSON_CODEX_WT=$'{\n  "cwd": "'"${HBA_CODEX_WT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_CODEX_WT_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=codex \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_CODEX_WT" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・Codex共有worktree(.codex/worktrees/)のcwd → exit 0で終わる（Codex契約。#59, #61）" \
  0 $?
case "$HBA_CODEX_WT_OUT" in
  *'"continue":false'*) pass "heartbeat.sh: Codex共有worktreeのcwdでもstdoutに\"continue\":falseを含むJSONを出す（#59, #61）" ;;
  *)                     fail "heartbeat.sh: Codex共有worktreeのcwdでもstdoutに\"continue\":falseを含むJSONを出す（#59, #61）" \
    "$HBA_CODEX_WT_OUT" ;;
esac
case "$HBA_CODEX_WT_OUT" in
  *"テスト用の打ち切り理由"*) pass "heartbeat.sh: Codex共有worktreeのcwdでも--abortの理由がJSONに含まれる（#59, #61）" ;;
  *)                          fail "heartbeat.sh: Codex共有worktreeのcwdでも--abortの理由がJSONに含まれる（#59, #61）" \
    "$HBA_CODEX_WT_OUT" ;;
esac

# --- フラグが無ければ、cwdがCodex共有worktreeでも拒否されない ---
HBA_CODEX_WT_NOFLAG_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_NOFLAG_REPO" DEV_WORKFLOW_HOOK_VENDOR=codex \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$(printf '{\n  "cwd": "%s/.codex/worktrees/42",\n  "tool_name": "Bash"\n}' "$HBA_NOFLAG_REPO")" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグが無ければCodex共有worktreeでも拒否されない" 0 $?

# --- postでは拒否しない（フラグあり・agent worktreeのcwdでも） ---
HBA_POST_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" post <<< "$HBA_JSON_AGENT" 2>&1)"
assert_exit_code "heartbeat.sh: postでは拒否しない（フラグ・agent cwdがあってもexit 0）" 0 $?
assert_eq "heartbeat.sh: postでは無出力" "" "$HBA_POST_OUT"

# --- Windowsネイティブパス表現（バックスラッシュ、JSONでは二重エスケープ）のcwd正規化
#     （レビュー#60）。scripts/check-readability.sh:220-221 と同じ「JSONエスケープ解除
#     （\\ → \）+ Windowsパス正規化（\ → /）」がheartbeat.shにも入っていることを、
#     cwdがバックスラッシュ表現で来た場合に確認する。 ---

# フラグあり + cwdがWindows表現のagent worktree(.claude\worktrees\agent-) → 拒否される
HBA_WIN_AGENT_CWD='C:\\Users\\hba-win\\.claude\\worktrees\\agent-hba-winpath'
HBA_JSON_WIN_AGENT=$'{\n  "cwd": "'"${HBA_WIN_AGENT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_WIN_AGENT_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_WIN_AGENT" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・Windows表現(バックスラッシュ)のagent worktreeのcwd → exit 2で拒否（#60）" \
  2 $?
case "$HBA_WIN_AGENT_OUT" in
  *"テスト用の打ち切り理由"*) pass "heartbeat.sh: Windows表現のcwdでも拒否メッセージに--abortの理由が含まれる（#60）" ;;
  *) fail "heartbeat.sh: Windows表現のcwdでも拒否メッセージに--abortの理由が含まれる（#60）" "$HBA_WIN_AGENT_OUT" ;;
esac

# フラグあり + cwdがWindows表現のCodex共有worktree(.codex\worktrees\) → 拒否される（Codex契約）
HBA_WIN_CODEX_WT_CWD='C:\\Users\\hba-win\\.codex\\worktrees\\epic42'
HBA_JSON_WIN_CODEX_WT=$'{\n  "cwd": "'"${HBA_WIN_CODEX_WT_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_WIN_CODEX_WT_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=codex \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_WIN_CODEX_WT" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・Windows表現(バックスラッシュ)のCodex共有worktreeのcwd → exit 0で終わる（Codex契約。#60）" \
  0 $?
case "$HBA_WIN_CODEX_WT_OUT" in
  *'"continue":false'*) pass "heartbeat.sh: Windows表現のCodex共有worktreeのcwdでもstdoutに\"continue\":falseを含むJSONを出す（#60）" ;;
  *) fail "heartbeat.sh: Windows表現のCodex共有worktreeのcwdでもstdoutに\"continue\":falseを含むJSONを出す（#60）" \
    "$HBA_WIN_CODEX_WT_OUT" ;;
esac
case "$HBA_WIN_CODEX_WT_OUT" in
  *"テスト用の打ち切り理由"*) pass "heartbeat.sh: Windows表現のCodex共有worktreeのcwdでも--abortの理由がJSONに含まれる（#60）" ;;
  *) fail "heartbeat.sh: Windows表現のCodex共有worktreeのcwdでも--abortの理由がJSONに含まれる（#60）" \
    "$HBA_WIN_CODEX_WT_OUT" ;;
esac

# フラグあり + cwdがWindows表現のepic worktree(agent-プレフィックスなし) → 拒否されない
# （正規化してもagent-パターン・.codex/worktrees/パターンいずれにも一致しないこと）
HBA_WIN_EPIC_CWD='C:\\Users\\hba-win\\.claude\\worktrees\\epic99'
HBA_JSON_WIN_EPIC=$'{\n  "cwd": "'"${HBA_WIN_EPIC_CWD}"'",\n  "tool_name": "Bash"\n}'
HBA_WIN_EPIC_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_WIN_EPIC" 2>&1)"
assert_exit_code "heartbeat.sh: abortフラグあり・Windows表現のepic worktreeのcwd → 拒否されない（exit 0。#60）" \
  0 $?
assert_eq "heartbeat.sh: abortフラグあり・Windows表現のepic worktreeのcwd → 無出力（#60）" "" "$HBA_WIN_EPIC_OUT"

# --- heartbeat.sh冒頭コメント: Codexのrun経路2つ（run-loop.sh経由 / スキルをセッション内で
#     直接回す経路）を区別した記述になっていること（レビュー#63）。以前は「Codexではrun-loop.sh
#     自体がbashスクリプトでフックの発火源ではないため、そもそもこのフックが呼ばれない」という
#     包括的な主張をしていたが、スキル`dev-workflow-run`をセッション内で直接回す経路では
#     メインループ自身がcodexセッションであり、この主張が成立しない。 ---
HB_COMMENT="$(cat "$HEARTBEAT_SCRIPT")"

case "$HB_COMMENT" in
  *'codex exec -C "$EPIC_WT"'*'generator/evaluator'*)
    pass "heartbeat.sh: .codex/worktrees/パターンがrun-loop.shのcodex exec -Cで起動するgenerator/evaluatorセッションを対象にする旨の記述がある（#63）" ;;
  *)
    fail "heartbeat.sh: .codex/worktrees/パターンがrun-loop.shのcodex exec -Cで起動するgenerator/evaluatorセッションを対象にする旨の記述がある（#63）" \
      "$HB_COMMENT" ;;
esac

case "$HB_COMMENT" in
  *'dev-workflow-run'*'セッション内で直接回す経路'*'同一セッション内'*)
    pass "heartbeat.sh: スキルをセッション内で直接回す経路ではメインループとサブエージェントが同一セッションである旨の記述がある（#63）" ;;
  *)
    fail "heartbeat.sh: スキルをセッション内で直接回す経路ではメインループとサブエージェントが同一セッションである旨の記述がある（#63）" \
      "$HB_COMMENT" ;;
esac

case "$HB_COMMENT" in
  *'区別できるcwdの差を持たず'*)
    pass "heartbeat.sh: スキル直接実行経路ではメインループとサブエージェントをcwdで区別できない旨の記述がある（#63）" ;;
  *)
    fail "heartbeat.sh: スキル直接実行経路ではメインループとサブエージェントをcwdで区別できない旨の記述がある（#63）" \
      "$HB_COMMENT" ;;
esac

# レビュー#63以前の「Codexではフックがそもそも呼ばれない」という無限定の主張のまま
# 放置されていないこと（スキル直接実行経路への言及なしにこの一文だけが単独で成立していると
# 誤りになる。#63の指摘そのものの再発防止）
if printf '%s' "$HB_COMMENT" | grep -q 'セッション内で直接回す経路'; then
  pass "heartbeat.sh: 「Codexではフックが呼ばれない」という主張がスキル直接実行経路の言及なしに単独で残っていない（#63）"
else
  fail "heartbeat.sh: 「Codexではフックが呼ばれない」という主張がスキル直接実行経路の言及なしに単独で残っていない（#63）" \
    "$HB_COMMENT"
fi

# --- watchdog.sh --abort / --clear との結合: 実際にwatchdog.shで作った/消したフラグで動く ---
HBA_WD_SCRIPT="${REPO_ROOT}/scripts/watchdog.sh"
HBA_INT_REPO="$(canon_root "$(make_temp_repo)")"
mkdir -p "${HBA_INT_REPO}/.claude"
HBA_INT_AGENT_CWD="${HBA_INT_REPO}/.claude/worktrees/agent-hba-integ"
HBA_JSON_INT=$'{\n  "cwd": "'"${HBA_INT_AGENT_CWD}"'",\n  "tool_name": "Bash"\n}'

DEV_WORKFLOW_MARKER_ROOT="$HBA_INT_REPO" bash "$HBA_WD_SCRIPT" --abort "結合テストの理由" >/dev/null 2>&1
HBA_INT_OUT1="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_INT_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_INT" 2>&1)"
assert_exit_code "heartbeat.sh: watchdog.sh --abortで作ったフラグにより拒否される" 2 $?
case "$HBA_INT_OUT1" in
  *"結合テストの理由"*) pass "heartbeat.sh: watchdog.sh --abortの理由がそのまま拒否メッセージに載る" ;;
  *)                     fail "heartbeat.sh: watchdog.sh --abortの理由がそのまま拒否メッセージに載る" "$HBA_INT_OUT1" ;;
esac

DEV_WORKFLOW_MARKER_ROOT="$HBA_INT_REPO" bash "$HBA_WD_SCRIPT" --abort --clear >/dev/null 2>&1
if [ -f "${HBA_INT_REPO}/.claude/.dev-workflow-abort" ]; then
  fail "watchdog.sh --abort --clear: フラグファイルが削除される"
else
  pass "watchdog.sh --abort --clear: フラグファイルが削除される"
fi
HBA_INT_OUT2="$(DEV_WORKFLOW_MARKER_ROOT="$HBA_INT_REPO" DEV_WORKFLOW_HOOK_VENDOR=claude \
  bash "$HEARTBEAT_SCRIPT" pre <<< "$HBA_JSON_INT" 2>&1)"
assert_exit_code "heartbeat.sh: --abort --clear の後は拒否されない" 0 $?
assert_eq "heartbeat.sh: --abort --clear の後は無出力" "" "$HBA_INT_OUT2"

# watchdog.sh --abort / --abort --clear のログ記録
HBA_WD_LOG="${HBA_INT_REPO}/.claude/.dev-workflow-watchdog.log"
if grep -q "$(printf '\tabort\t')" "$HBA_WD_LOG" 2>/dev/null; then
  pass "watchdog.sh --abort: ログに記録される"
else
  fail "watchdog.sh --abort: ログに記録される" "$(cat "$HBA_WD_LOG" 2>&1)"
fi
if grep -q "$(printf '\tabort-clear\t')" "$HBA_WD_LOG" 2>/dev/null; then
  pass "watchdog.sh --abort --clear: ログに記録される"
else
  fail "watchdog.sh --abort --clear: ログに記録される" "$(cat "$HBA_WD_LOG" 2>&1)"
fi

# watchdog.sh --abort: 理由もclearも指定しないとエラー（exit 64）
DEV_WORKFLOW_MARKER_ROOT="$HBA_INT_REPO" bash "$HBA_WD_SCRIPT" --abort >/dev/null 2>&1
assert_exit_code "watchdog.sh --abort: 理由未指定はエラー（exit 64）" 64 $?

# ---------------------------------------------------------------------------
# scripts/watchdog.sh（常駐監視の骨格とライフサイクル。Task #45、Epic #42）
#
# run のメインループはサブエージェント実行中に別処理を回せないため、監視は
# nohup で自己デタッチする常駐プロセスとして実装している（Epic #42 仕様書「2. 全体像」
# 「5. デタッチした常駐プロセス」）。ここでは検知ロジック（#47〜#49）ではなく、
# 起動・停止・状態確認・自己終了・二重起動防止・stale PID 検出のライフサイクルだけを
# 検証する。実プロセスを扱うケースは合計10秒以内に収め、終了後にプロセスを残さない。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/watchdog.sh（常駐監視の骨格とライフサイクル。Task #45） =="

WD_SCRIPT="${REPO_ROOT}/scripts/watchdog.sh"

# wd_new_root  一時マーカールート（.claude/ 付き）を作って絶対パスを返す
wd_new_root() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-watchdog.XXXXXX")"
  mkdir -p "${dir}/.claude"
  printf '%s' "$dir"
}

# wd_pid_of <root>  PIDファイルに書かれたPID部分だけを返す（無ければ空文字）
wd_pid_of() {
  local root="$1" line=""
  [ -f "${root}/.claude/.dev-workflow-watchdog.pid" ] || return 0
  IFS= read -r line < "${root}/.claude/.dev-workflow-watchdog.pid" || true
  printf '%s' "${line%% *}"
}

# wd_pid_alive <pid>  そのPIDが実際に稼働していれば0を返す
#
# `kill -0` だけではゾンビ（終了済みだが未回収のプロセス）にも成功してしまう
# （POSIXの仕様どおり）。init を持たないこのサンドボックスコンテナでは孤児プロセスが
# 永久にゾンビのまま残ることが実測で判明したため、watchdog.sh の
# _watchdog_pid_alive と同じロジック（/proc の State 行でゾンビを除外する）を
# テスト側でも使う。
wd_pid_alive() {
  local pid="$1"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1

  if [ -r "/proc/${pid}/status" ]; then
    local line
    while IFS= read -r line; do
      case "$line" in
        State:*)
          case "$line" in
            *'(zombie)'*) return 1 ;;
          esac
          break
          ;;
      esac
    done < "/proc/${pid}/status"
  fi

  return 0
}

# テストが途中で失敗しても、起動した監視デーモンを必ず後始末する
# （ホストには他の作業が動いているため、無関係なプロセスには触れない。
#   ここで kill するのはこのテストが自分で起動したPIDだけ）
WD_CLEANUP_PIDS=()
wd_cleanup_all() {
  local p
  for p in "${WD_CLEANUP_PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    wd_pid_alive "$p" && kill "$p" 2>/dev/null
  done
}
trap wd_cleanup_all EXIT

# --- ライフサイクル: start（即時に返る・生存）→ status（running）→ 二重start（1プロセスのまま）
#     → stop（確実に停止）→ status（stopped・PIDファイル消滅） ---

WD_ROOT1="$(wd_new_root)"
: > "${WD_ROOT1}/.claude/.dev-workflow-run"

WD_T0=""
printf -v WD_T0 '%(%s)T' -1
WD_START_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT1" DEV_WORKFLOW_WATCHDOG_TICK_SEC=30 \
  bash "$WD_SCRIPT" --start --epic 45 --label "Epic #45 test" 2>&1)"
WD_T1=""
printf -v WD_T1 '%(%s)T' -1
WD_ELAPSED=$((WD_T1 - WD_T0))

if [ "$WD_ELAPSED" -le 1 ]; then
  pass "watchdog.sh --start: 呼び出しが1秒以内に返る（実測 ${WD_ELAPSED}s）"
else
  fail "watchdog.sh --start: 呼び出しが1秒以内に返る" "実測 ${WD_ELAPSED}s / 出力: ${WD_START_OUT}"
fi

WD_PID1="$(wd_pid_of "$WD_ROOT1")"
WD_CLEANUP_PIDS+=("$WD_PID1")

if [ -n "$WD_PID1" ] && wd_pid_alive "$WD_PID1"; then
  pass "watchdog.sh --start: 起動したプロセスが親の呼び出し終了後も生存している（pid=${WD_PID1}）"
else
  fail "watchdog.sh --start: 起動したプロセスが親の呼び出し終了後も生存している" "pid=[${WD_PID1}]"
fi

WD_STATUS_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT1" bash "$WD_SCRIPT" --status)"
WD_STATUS_EXIT=$?
case "$WD_STATUS_OUT" in
  running*) pass "watchdog.sh --status: running を返す（${WD_STATUS_OUT}）" ;;
  *)        fail "watchdog.sh --status: running を返す" "$WD_STATUS_OUT" ;;
esac
assert_exit_code "watchdog.sh --status: running のときexit 0" 0 "$WD_STATUS_EXIT"

case "$WD_STATUS_OUT" in
  *"pid=${WD_PID1}"*) pass "watchdog.sh --status: PIDファイルのPIDと一致する" ;;
  *)                  fail "watchdog.sh --status: PIDファイルのPIDと一致する" "$WD_STATUS_OUT" ;;
esac

# 二重に --start しても新しいプロセスは作らず、既存PIDのまま（監視プロセスは1つ）
WD_START2_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT1" bash "$WD_SCRIPT" --start 2>&1)"
WD_PID1_AFTER="$(wd_pid_of "$WD_ROOT1")"
assert_eq "watchdog.sh --start: 二重起動してもPIDが変わらない（監視プロセスは1つ）" \
  "$WD_PID1" "$WD_PID1_AFTER"
case "$WD_START2_OUT" in
  *"already running"*) pass "watchdog.sh --start: 二重起動時にその旨を出力する" ;;
  *)                    fail "watchdog.sh --start: 二重起動時にその旨を出力する" "$WD_START2_OUT" ;;
esac

# --stop で確実に停止する
WD_STOP_OUT="$(DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT1" bash "$WD_SCRIPT" --stop 2>&1)"
case "$WD_STOP_OUT" in
  *"stopped"*) pass "watchdog.sh --stop: 停止メッセージを出す" ;;
  *)           fail "watchdog.sh --stop: 停止メッセージを出す" "$WD_STOP_OUT" ;;
esac

if wd_pid_alive "$WD_PID1"; then
  fail "watchdog.sh --stop: プロセスが実際に終了している" "pid=${WD_PID1} がまだ生存"
else
  pass "watchdog.sh --stop: プロセスが実際に終了している（pid=${WD_PID1}）"
fi

WD_STATUS_AFTER_STOP="$(DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT1" bash "$WD_SCRIPT" --status)"
WD_STATUS_AFTER_STOP_EXIT=$?
assert_eq "watchdog.sh --status: --stop後はstoppedを返す" "stopped" "$WD_STATUS_AFTER_STOP"
assert_exit_code "watchdog.sh --status: stoppedのときexit 1" 1 "$WD_STATUS_AFTER_STOP_EXIT"

if [ -f "${WD_ROOT1}/.claude/.dev-workflow-watchdog.pid" ]; then
  fail "watchdog.sh --stop: PIDファイルが残っていない（受け入れ条件8）"
else
  pass "watchdog.sh --stop: PIDファイルが残っていない（受け入れ条件8）"
fi

# --- stale PID: プロセスが存在しないPIDファイルが残っていても --start できる ---

WD_ROOT2="$(wd_new_root)"
: > "${WD_ROOT2}/.claude/.dev-workflow-run"

# 確実に生存していないPIDを用意する（起動して即終了させ、waitで回収済みにする）
bash -c 'exit 0' &
WD_DEAD_PID=$!
wait "$WD_DEAD_PID" 2>/dev/null
printf '%s %s\n' "$WD_DEAD_PID" "1700000000" > "${WD_ROOT2}/.claude/.dev-workflow-watchdog.pid"

DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT2" DEV_WORKFLOW_WATCHDOG_TICK_SEC=30 \
  bash "$WD_SCRIPT" --start > /dev/null 2>&1
WD_PID2="$(wd_pid_of "$WD_ROOT2")"
WD_CLEANUP_PIDS+=("$WD_PID2")

if [ -n "$WD_PID2" ] && [ "$WD_PID2" != "$WD_DEAD_PID" ] && wd_pid_alive "$WD_PID2"; then
  pass "watchdog.sh --start: 残骸PIDファイル（存在しないPID）があっても起動できる（新pid=${WD_PID2}）"
else
  fail "watchdog.sh --start: 残骸PIDファイル（存在しないPID）があっても起動できる" "pid=[${WD_PID2}] dead_pid=[${WD_DEAD_PID}]"
fi

if grep -q "stale-pid" "${WD_ROOT2}/.claude/.dev-workflow-watchdog.log" 2>/dev/null; then
  pass "watchdog.sh --start: stale PID検出をログに記録する"
else
  fail "watchdog.sh --start: stale PID検出をログに記録する" "$(cat "${WD_ROOT2}/.claude/.dev-workflow-watchdog.log" 2>&1)"
fi

DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT2" bash "$WD_SCRIPT" --stop > /dev/null 2>&1

# --- --tick-once: 常駐せず1周だけ回してexit 0で返る ---

WD_ROOT3="$(wd_new_root)"

WD_TICK_T0=""
printf -v WD_TICK_T0 '%(%s)T' -1
DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT3" bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WD_TICK_EXIT=$?
WD_TICK_T1=""
printf -v WD_TICK_T1 '%(%s)T' -1

assert_exit_code "watchdog.sh --tick-once: exit 0で返る" 0 "$WD_TICK_EXIT"

if [ $((WD_TICK_T1 - WD_TICK_T0)) -le 2 ]; then
  pass "watchdog.sh --tick-once: 常駐せずすぐに返る"
else
  fail "watchdog.sh --tick-once: 常駐せずすぐに返る" "実測 $((WD_TICK_T1 - WD_TICK_T0))s"
fi

WD_TICK_LOG="${WD_ROOT3}/.claude/.dev-workflow-watchdog.log"
if [ -f "$WD_TICK_LOG" ] && grep -q "$(printf '\ttick\t')" "$WD_TICK_LOG"; then
  pass "watchdog.sh --tick-once: ログにtickイベントが1行追記される"
else
  fail "watchdog.sh --tick-once: ログにtickイベントが1行追記される" "$(cat "$WD_TICK_LOG" 2>&1)"
fi

if [ -f "${WD_ROOT3}/.claude/.dev-workflow-watchdog.pid" ]; then
  fail "watchdog.sh --tick-once: 常駐しない（PIDファイルを作らない）"
else
  pass "watchdog.sh --tick-once: 常駐しない（PIDファイルを作らない）"
fi

# --- DEV_WORKFLOW_WATCHDOG_NOW を与えるとログの時刻がその値になる ---

WD_ROOT4="$(wd_new_root)"
WD_FIXED_NOW=1700000000
WD_EXPECTED_TS=""
printf -v WD_EXPECTED_TS '%(%Y-%m-%d %H:%M:%S)T' "$WD_FIXED_NOW"
DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT4" DEV_WORKFLOW_WATCHDOG_NOW="$WD_FIXED_NOW" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WD_LOGGED_LINE="$(tail -1 "${WD_ROOT4}/.claude/.dev-workflow-watchdog.log" 2>/dev/null)"
WD_LOGGED_TS="${WD_LOGGED_LINE%%$'\t'*}"
assert_eq "watchdog.sh: DEV_WORKFLOW_WATCHDOG_NOW を与えるとログの時刻がその値になる" \
  "$WD_EXPECTED_TS" "$WD_LOGGED_TS"

# --- run マーカーを消すと（短いtick間隔で）自己終了する。受け入れ条件8 ---

WD_ROOT5="$(wd_new_root)"
: > "${WD_ROOT5}/.claude/.dev-workflow-run"

DEV_WORKFLOW_MARKER_ROOT="$WD_ROOT5" DEV_WORKFLOW_WATCHDOG_TICK_SEC=1 \
  bash "$WD_SCRIPT" --start > /dev/null 2>&1
WD_PID5="$(wd_pid_of "$WD_ROOT5")"
WD_CLEANUP_PIDS+=("$WD_PID5")

rm -f "${WD_ROOT5}/.claude/.dev-workflow-run"

WD_SELF_TERM_OK=0
WD_WAIT_I=0
while [ "$WD_WAIT_I" -lt 25 ]; do
  if [ -n "$WD_PID5" ] && ! wd_pid_alive "$WD_PID5"; then
    WD_SELF_TERM_OK=1
    break
  fi
  sleep 0.2
  WD_WAIT_I=$((WD_WAIT_I + 1))
done

if [ "$WD_SELF_TERM_OK" -eq 1 ]; then
  pass "watchdog.sh: run マーカー消失で自己終了する（受け入れ条件8）"
else
  fail "watchdog.sh: run マーカー消失で自己終了する" "pid=${WD_PID5} が終了しなかった"
fi

if [ -f "${WD_ROOT5}/.claude/.dev-workflow-watchdog.pid" ]; then
  fail "watchdog.sh: 自己終了後にPIDファイルが残っていない（受け入れ条件8）"
else
  pass "watchdog.sh: 自己終了後にPIDファイルが残っていない（受け入れ条件8）"
fi

if grep -q "exit-reason" "${WD_ROOT5}/.claude/.dev-workflow-watchdog.log" 2>/dev/null \
  && grep -q "run marker missing" "${WD_ROOT5}/.claude/.dev-workflow-watchdog.log" 2>/dev/null; then
  pass "watchdog.sh: 自己終了の理由がログに記録される"
else
  fail "watchdog.sh: 自己終了の理由がログに記録される" "$(cat "${WD_ROOT5}/.claude/.dev-workflow-watchdog.log" 2>&1)"
fi

# ---------------------------------------------------------------------------
# scripts/watchdog.sh: エージェントを自動で打ち切る経路が存在しない（受け入れ条件6）
#
# 決定事項（Epic #42）: watchdog は検知して通知するだけであり、しきい値超過で
# 自動的にツール呼び出しの拒否やプロセスkillを仕込む経路を持たない。
# ここでは kill の使用箇所が watchdog_stop（人間が --stop を明示的に実行したときだけ
# 通る経路）の1箇所に限られ、対象が監視デーモン自身のPIDであること、tick/検知フック
# （自動発火の起点になり得る箇所）に kill が存在しないことを grep で証明する。
#
# `kill -0`（シグナル0=何も起こさない存在確認クエリ。POSIXの標準的なイディオム）は
# ここでの「kill」から除外する。実際にプロセスを終了させないため、受け入れ条件6が
# 問題にしている「自動打ち切り」には当たらない（_watchdog_pid_alive が
# start/stop/status の生存確認に使っており、tick処理・検知フックからは呼ばれない）。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/watchdog.sh: エージェントを自動で打ち切る経路が存在しない（受け入れ条件6） =="

# コメント行を除いた実コード上で「実際に終了させる」kill（kill -0 は除く）が
# 使われている箇所を数える
WD_KILL_LINES="$(grep -v '^[[:space:]]*#' "$WD_SCRIPT" | grep -E '(^|[^A-Za-z0-9_])kill[[:space:]]' | grep -v -- '-0' || true)"
WD_KILL_COUNT="$(printf '%s\n' "$WD_KILL_LINES" | grep -c . || true)"
[ -z "$WD_KILL_LINES" ] && WD_KILL_COUNT=0

assert_eq "watchdog.sh: 終了シグナルとしてのkillは1箇所だけ（--stop のみ・kill -0の存在確認は除く）" "1" "$WD_KILL_COUNT"

case "$WD_KILL_LINES" in
  *'kill "$pid"'*)
    pass "watchdog.sh: kill は監視デーモン自身のPID（\$pid）だけを対象にする" ;;
  *)
    fail "watchdog.sh: kill は監視デーモン自身のPID（\$pid）だけを対象にする" "$WD_KILL_LINES" ;;
esac

# その1箇所が watchdog_stop（--stop の処理）の中に閉じていること
WD_STOP_FN_BODY="$(awk '/^watchdog_stop\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$WD_SCRIPT")"
case "$WD_STOP_FN_BODY" in
  *'kill "$pid"'*)
    pass "watchdog.sh: kill は watchdog_stop（人間が --stop を叩いたときだけ）に閉じている" ;;
  *)
    fail "watchdog.sh: kill は watchdog_stop（人間が --stop を叩いたときだけ）に閉じている" "$WD_STOP_FN_BODY" ;;
esac

# tick処理・検知フック（監視ループが自動的に回す経路）に kill が存在しないこと
WD_HOOK_BLOCK="$(awk '/^# 監視ループのフック点/{f=1} f&&/^# --start$/{exit} f' "$WD_SCRIPT")"
if printf '%s' "$WD_HOOK_BLOCK" | grep -q 'kill'; then
  fail "watchdog.sh: tick処理・検知フック（自動発火経路）にkillが存在しない（受け入れ条件6）" "$WD_HOOK_BLOCK"
else
  pass "watchdog.sh: tick処理・検知フック（自動発火経路）にkillが存在しない（受け入れ条件6）"
fi

# エージェント（Claude Code / Codex のCLIプロセスやサブエージェント）のPIDを扱う
# 変数・識別子が存在しないこと（watchdogは監視デーモン自身のPIDしか知らない）
if grep -qiE 'claude[_-]?pid|codex[_-]?pid|agent[_-]?pid|cli[_-]?pid' "$WD_SCRIPT"; then
  fail "watchdog.sh: エージェント/CLIプロセスのPIDを扱う変数が存在しない（受け入れ条件6）" \
    "$(grep -inE 'claude[_-]?pid|codex[_-]?pid|agent[_-]?pid|cli[_-]?pid' "$WD_SCRIPT")"
else
  pass "watchdog.sh: エージェント/CLIプロセスのPIDを扱う変数が存在しない（受け入れ条件6）"
fi

# --abort（人間が明示的に叩く打ち切り。#50）は実装されているが、tick処理・検知フック
# （監視ループが自動的に回す経路。WD_HOOK_BLOCKは上でkillチェック用に抽出済み）からは
# 一切参照されないこと（自動発火経路がここにも無いことの担保）
if printf '%s' "$WD_HOOK_BLOCK" | grep -q 'dev-workflow-abort\|ABORT_FLAG_FILE'; then
  fail "watchdog.sh: tick処理・検知フック（自動発火経路）に abort フラグの参照が存在しない（受け入れ条件6・#50）" \
    "$WD_HOOK_BLOCK"
else
  pass "watchdog.sh: tick処理・検知フック（自動発火経路）に abort フラグの参照が存在しない（受け入れ条件6・#50）"
fi

# watchdog_abort関数が存在すること（人間が明示的に叩く経路。#50）
WD_ABORT_FN_BODY="$(awk '/^watchdog_abort\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$WD_SCRIPT")"
if [ -z "$WD_ABORT_FN_BODY" ]; then
  fail "watchdog.sh: watchdog_abort関数が存在する（#50）" "見つかりません"
else
  pass "watchdog.sh: watchdog_abort関数が存在する（#50）"
fi

# ABORT_FLAG_FILE（.dev-workflow-abort）を書き込む・削除するコードが、定義行・コメント行
# を除いて watchdog_abort 関数の外に存在しないこと。これにより「自動でabortフラグを作る
# 経路が存在しない」ことを、tick/検知フックだけでなくスクリプト全体で担保する。
WD_ABORT_REF_LINES="$(grep -n 'ABORT_FLAG_FILE' "$WD_SCRIPT" \
  | grep -vE '^[0-9]+:ABORT_FLAG_FILE=' \
  | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
WD_ABORT_REF_OUTSIDE=""
while IFS=: read -r wd_lno wd_rest; do
  [ -n "$wd_lno" ] || continue
  printf '%s\n' "$WD_ABORT_FN_BODY" | grep -qF -- "$wd_rest" \
    || WD_ABORT_REF_OUTSIDE="${WD_ABORT_REF_OUTSIDE}${wd_lno}:${wd_rest}"$'\n'
done <<< "$WD_ABORT_REF_LINES"
if [ -n "$WD_ABORT_REF_OUTSIDE" ]; then
  fail "watchdog.sh: ABORT_FLAG_FILEを扱うコードはwatchdog_abort関数の内側だけにある（自動発火経路が無いことの担保・#50）" \
    "$WD_ABORT_REF_OUTSIDE"
else
  pass "watchdog.sh: ABORT_FLAG_FILEを扱うコードはwatchdog_abort関数の内側だけにある（自動発火経路が無いことの担保・#50）"
fi

# AUTO_ABORT等、自動発火用の環境変数・分岐が存在しないこと（#50: 環境変数による自動abortも設けない）
if grep -qiE 'auto[_-]?abort' "$WD_SCRIPT"; then
  fail "watchdog.sh: 自動発火用の環境変数・分岐（AUTO_ABORT等）が存在しない（#50）" \
    "$(grep -inE 'auto[_-]?abort' "$WD_SCRIPT")"
else
  pass "watchdog.sh: 自動発火用の環境変数・分岐（AUTO_ABORT等）が存在しない（#50）"
fi

# --- テスト後始末: 生き残っているデーモンがあれば停止する ---
wd_cleanup_all
trap - EXIT

# ---------------------------------------------------------------------------
# scripts/watchdog.sh: ストール判定・エスカレーション・スリープギャップ補正（Task #47、Epic #42）
#
# DEV_WORKFLOW_WATCHDOG_NOW で時刻を注入し --tick-once を連続で叩くことで、実時間を
# 一切待たずに「未検知→初回→エスカレーション→打ち止め→復帰→再ストール」の遷移を検証する。
# 通知は notify-slack.sh の DEV_WORKFLOW_NOTIFY_SINK 経由で検証し、ネットワークには
# 一切出ない（既存の notify-slack.sh テストと同じsink機構。PATHへ偽curlを差し込み、
# 万一sink機構をバイパスしても実curlが呼ばれないことも確認する）。
#
# tick_sec は意図的に大きく（3600秒）取り、テストで注入する時刻ジャンプ（最大でも
# 数千秒）がスリープギャップ（tick間隔の3倍超）として誤検知されないようにしている
# （スリープギャップそのものの検証は専用のケース群で tick_sec=60 を使って別途行う）。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/watchdog.sh: ストール判定・エスカレーション・スリープギャップ補正（Task #47） =="

WDS_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-watchdog-stall.XXXXXX")"
WDS_FAKE_BIN="${WDS_WORK}/bin"
mkdir -p "$WDS_FAKE_BIN"
WDS_CURL_LOG="${WDS_WORK}/curl-calls.log"
printf '#!/bin/bash\necho "called: $*" >> "%s"\nexit 0\n' "$WDS_CURL_LOG" > "${WDS_FAKE_BIN}/curl"
chmod +x "${WDS_FAKE_BIN}/curl"

# wds_write_heartbeat <root> <epoch> <state> <tool>
wds_write_heartbeat() {
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "${1}/.claude/.dev-workflow-heartbeat"
}

# wds_tick <root> <now> <tick_sec> [sink_file]
# --tick-once を1回叩く。SLACK_WEBHOOK_URL は常にダミーを設定し、sink未指定時は
# 使い捨てのsinkへ書かせる（そのtickで通知が発火したかどうかをsinkファイルの
# 有無だけで判定するため、ケースごとに新しいsinkパスを渡す）。
wds_tick() {
  local root="$1" now="$2" tick_sec="$3" sink="${4:-${WDS_WORK}/unused-sink.json}"
  DEV_WORKFLOW_MARKER_ROOT="$root" \
  DEV_WORKFLOW_WATCHDOG_NOW="$now" \
  DEV_WORKFLOW_WATCHDOG_TICK_SEC="$tick_sec" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$sink" \
  DEV_WORKFLOW_NO_SLEEP_INHIBIT=1 \
  PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once --epic 47 --label "Epic #47 test" > /dev/null 2>&1
}

wds_read_sink() {
  [ -f "$1" ] && cat "$1" || printf ''
}

# --- ストール検知・エスカレーション・打ち止め・復帰（既定値 idle=900秒・escalate=1800秒） ---

WDS_ROOT1="$(wd_new_root)"
WDS_T0=1700000000
wds_write_heartbeat "$WDS_ROOT1" "$WDS_T0" "post" "Bash"
WDS_LOG1="${WDS_ROOT1}/.claude/.dev-workflow-watchdog.log"

# 初回tick: 基準時刻を記録するだけ（通知は起きない）
wds_tick "$WDS_ROOT1" "$WDS_T0" 3600
if grep -q "$(printf '\tstall\t')" "$WDS_LOG1" 2>/dev/null; then
  fail "watchdog.sh: 初回tickでは通知しない（基準時刻の記録のみ）" "$(cat "$WDS_LOG1" 2>&1)"
else
  pass "watchdog.sh: 初回tickでは通知しない（基準時刻の記録のみ）"
fi

# 無活動14分: 通知されない
WDS_SINK_14M="${WDS_WORK}/14m.json"
wds_tick "$WDS_ROOT1" "$((WDS_T0 + 14 * 60))" 3600 "$WDS_SINK_14M"
if [ -f "$WDS_SINK_14M" ]; then
  fail "watchdog.sh: 無活動14分では通知されない" "$(wds_read_sink "$WDS_SINK_14M")"
else
  pass "watchdog.sh: 無活動14分では通知されない"
fi

# 無活動16分: 初回通知される（state=post → モデルの応答待ちで停止）
WDS_NOTIFY1_AT=$((WDS_T0 + 16 * 60))
WDS_SINK_16M="${WDS_WORK}/16m.json"
wds_tick "$WDS_ROOT1" "$WDS_NOTIFY1_AT" 3600 "$WDS_SINK_16M"
WDS_BODY_16M="$(wds_read_sink "$WDS_SINK_16M")"
case "$WDS_BODY_16M" in
  *"応答なし"*) pass "watchdog.sh: 無活動16分で初回通知される" ;;
  *)            fail "watchdog.sh: 無活動16分で初回通知される" "$WDS_BODY_16M" ;;
esac
case "$WDS_BODY_16M" in
  *"モデルの応答待ちで停止"*)
    pass "watchdog.sh: state=postの通知本文に «モデルの応答待ちで停止» を含む（受け入れ条件2）" ;;
  *)
    fail "watchdog.sh: state=postの通知本文に «モデルの応答待ちで停止» を含む" "$WDS_BODY_16M" ;;
esac
case "$WDS_BODY_16M" in
  *"ツール実行中に停止"*)
    fail "watchdog.sh: state=postの通知本文に «ツール実行中に停止» を誤って含まない" "$WDS_BODY_16M" ;;
  *)
    pass "watchdog.sh: state=postの通知本文に «ツール実行中に停止» を誤って含まない" ;;
esac
case "$WDS_BODY_16M" in
  *"Epic #47"*) pass "watchdog.sh: 通知本文にEpic番号（--tick-onceで受け取ったもの）を含む" ;;
  *)            fail "watchdog.sh: 通知本文にEpic番号を含む" "$WDS_BODY_16M" ;;
esac
case "$WDS_BODY_16M" in
  *0h16m*) pass "watchdog.sh: 通知本文に無活動の継続時間（Nh Mm形式）を含む" ;;
  *)       fail "watchdog.sh: 通知本文に無活動の継続時間（Nh Mm形式）を含む" "$WDS_BODY_16M" ;;
esac

# 初回通知の29分後: 再通知されない
WDS_SINK_29M="${WDS_WORK}/29m.json"
wds_tick "$WDS_ROOT1" "$((WDS_NOTIFY1_AT + 29 * 60))" 3600 "$WDS_SINK_29M"
if [ -f "$WDS_SINK_29M" ]; then
  fail "watchdog.sh: 初回通知後29分では再通知されない" "$(wds_read_sink "$WDS_SINK_29M")"
else
  pass "watchdog.sh: 初回通知後29分では再通知されない"
fi

# 初回通知の30分後: 2回目が通知される
WDS_NOTIFY2_AT=$((WDS_NOTIFY1_AT + 30 * 60))
WDS_SINK_30M="${WDS_WORK}/30m.json"
wds_tick "$WDS_ROOT1" "$WDS_NOTIFY2_AT" 3600 "$WDS_SINK_30M"
if [ -f "$WDS_SINK_30M" ]; then
  pass "watchdog.sh: 初回通知後30分経過で2回目が通知される"
else
  fail "watchdog.sh: 初回通知後30分経過で2回目が通知される" "sinkが作られなかった"
fi

# 2回目通知の30分後: 3回目が通知される
WDS_NOTIFY3_AT=$((WDS_NOTIFY2_AT + 30 * 60))
WDS_SINK_3RD="${WDS_WORK}/3rd.json"
wds_tick "$WDS_ROOT1" "$WDS_NOTIFY3_AT" 3600 "$WDS_SINK_3RD"
if [ -f "$WDS_SINK_3RD" ]; then
  pass "watchdog.sh: 3回目の通知がされる"
else
  fail "watchdog.sh: 3回目の通知がされる" "sinkが作られなかった"
fi

# 3回目通知の30分後（本来なら4回目のタイミング）: 最大3回で打ち止め、通知されない
WDS_AFTER_3RD=$((WDS_NOTIFY3_AT + 30 * 60))
WDS_SINK_4TH="${WDS_WORK}/4th.json"
wds_tick "$WDS_ROOT1" "$WDS_AFTER_3RD" 3600 "$WDS_SINK_4TH"
if [ -f "$WDS_SINK_4TH" ]; then
  fail "watchdog.sh: 3回通知した後は再通知されない（最大3回で打ち止め）" "$(wds_read_sink "$WDS_SINK_4TH")"
else
  pass "watchdog.sh: 3回通知した後は再通知されない（最大3回で打ち止め）"
fi

# さらに先の時刻でtickしても通知されない（打ち止めが続くことの確認）
WDS_SINK_FAR="${WDS_WORK}/far.json"
wds_tick "$WDS_ROOT1" "$((WDS_AFTER_3RD + 3000))" 3600 "$WDS_SINK_FAR"
if [ -f "$WDS_SINK_FAR" ]; then
  fail "watchdog.sh: 3回打ち止め後はどれだけtickしても通知されない" "$(wds_read_sink "$WDS_SINK_FAR")"
else
  pass "watchdog.sh: 3回打ち止め後はどれだけtickしても通知されない"
fi

WDS_STALL_COUNT_LOG="$(grep -c "$(printf '\tstall\t')" "$WDS_LOG1" 2>/dev/null || true)"
assert_eq "watchdog.sh: ログに記録されたstall通知は3件（打ち止めの上限どおり）" "3" "${WDS_STALL_COUNT_LOG:-0}"

if [ -f "${WDS_ROOT1}/.claude/.dev-workflow-abort" ]; then
  fail "watchdog.sh: ストールを3回検知しても .dev-workflow-abort が作られない（自動打ち切りをしない）"
else
  pass "watchdog.sh: ストールを3回検知しても .dev-workflow-abort が作られない（自動打ち切りをしない）"
fi

# --- heartbeat更新による復帰: stall-recoveredが1回だけ通知され、カウンタがリセットされる ---

WDS_RECOVER_AT=$((WDS_AFTER_3RD + 3000 + 10))
wds_write_heartbeat "$WDS_ROOT1" "$WDS_RECOVER_AT" "pre" "Read"

WDS_SINK_RECOVER="${WDS_WORK}/recovered.json"
wds_tick "$WDS_ROOT1" "$WDS_RECOVER_AT" 3600 "$WDS_SINK_RECOVER"
WDS_BODY_RECOVER="$(wds_read_sink "$WDS_SINK_RECOVER")"
case "$WDS_BODY_RECOVER" in
  *"応答が再開"*) pass "watchdog.sh: heartbeat更新でstall-recoveredが通知される" ;;
  *)              fail "watchdog.sh: heartbeat更新でstall-recoveredが通知される" "$WDS_BODY_RECOVER" ;;
esac

WDS_RECOVERED_COUNT_LOG="$(grep -c "$(printf '\tstall-recovered\t')" "$WDS_LOG1" 2>/dev/null || true)"
assert_eq "watchdog.sh: stall-recovered通知は1回だけ記録される" "1" "${WDS_RECOVERED_COUNT_LOG:-0}"

# 復帰直後（heartbeatが変わらない間）に再tickしても、stall-recoveredは再通知されない
WDS_SINK_RECOVER_AGAIN="${WDS_WORK}/recovered-again.json"
wds_tick "$WDS_ROOT1" "$((WDS_RECOVER_AT + 60))" 3600 "$WDS_SINK_RECOVER_AGAIN"
if [ -f "$WDS_SINK_RECOVER_AGAIN" ]; then
  fail "watchdog.sh: 復帰後、heartbeatが変わらない間はstall-recoveredが再通知されない" \
    "$(wds_read_sink "$WDS_SINK_RECOVER_AGAIN")"
else
  pass "watchdog.sh: 復帰後、heartbeatが変わらない間はstall-recoveredが再通知されない"
fi

# 復帰後に再びストールすると、通知カウンタがリセットされ初回から数え直す
# （4600秒超まで待たず、復帰後わずか16分の無活動で初回通知が来ることを確認する）
WDS_SINK_RESTALL="${WDS_WORK}/restall.json"
wds_tick "$WDS_ROOT1" "$((WDS_RECOVER_AT + 16 * 60))" 3600 "$WDS_SINK_RESTALL"
if [ -f "$WDS_SINK_RESTALL" ]; then
  pass "watchdog.sh: 復帰後に再びストールすると初回から数え直して通知される（16分で初回）"
else
  fail "watchdog.sh: 復帰後に再びストールすると初回から数え直して通知される" "sinkが作られなかった"
fi

WDS_STALL_COUNT_LOG2="$(grep -c "$(printf '\tstall\t')" "$WDS_LOG1" 2>/dev/null || true)"
assert_eq "watchdog.sh: 復帰後の再ストールでstall通知が合計4件になる（打ち止め3件＋復帰後1件）" \
  "4" "${WDS_STALL_COUNT_LOG2:-0}"

# --- state=pre: 通知本文が «ツール実行中に停止» になる（受け入れ条件2） ---

WDS_ROOT2="$(wd_new_root)"
WDS_T0_PRE=1700100000
wds_write_heartbeat "$WDS_ROOT2" "$WDS_T0_PRE" "pre" "Bash"
wds_tick "$WDS_ROOT2" "$WDS_T0_PRE" 3600
WDS_SINK_PRE="${WDS_WORK}/pre.json"
wds_tick "$WDS_ROOT2" "$((WDS_T0_PRE + 16 * 60))" 3600 "$WDS_SINK_PRE"
WDS_BODY_PRE="$(wds_read_sink "$WDS_SINK_PRE")"
case "$WDS_BODY_PRE" in
  *"ツール実行中に停止"*)
    pass "watchdog.sh: state=preの通知本文に «ツール実行中に停止» を含む（受け入れ条件2）" ;;
  *)
    fail "watchdog.sh: state=preの通知本文に «ツール実行中に停止» を含む" "$WDS_BODY_PRE" ;;
esac
case "$WDS_BODY_PRE" in
  *"モデルの応答待ちで停止"*)
    fail "watchdog.sh: state=preの通知本文に «モデルの応答待ちで停止» を誤って含まない" "$WDS_BODY_PRE" ;;
  *)
    pass "watchdog.sh: state=preの通知本文に «モデルの応答待ちで停止» を誤って含まない" ;;
esac

# --- heartbeatファイルが無い場合はストール判定を行わない（run開始直後の誤報防止） ---

WDS_ROOT3="$(wd_new_root)"
WDS_TICK3_OK=1
DEV_WORKFLOW_MARKER_ROOT="$WDS_ROOT3" DEV_WORKFLOW_WATCHDOG_NOW=1700200000 \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1 || WDS_TICK3_OK=0
assert_eq "watchdog.sh: heartbeatが無くてもtick-onceはexit 0で返る" "1" "$WDS_TICK3_OK"

WDS_LOG3="${WDS_ROOT3}/.claude/.dev-workflow-watchdog.log"
if grep -q "$(printf '\tstall\t')" "$WDS_LOG3" 2>/dev/null; then
  fail "watchdog.sh: heartbeatファイルが無い場合はストール判定を行わない" "$(cat "$WDS_LOG3" 2>&1)"
else
  pass "watchdog.sh: heartbeatファイルが無い場合はストール判定を行わない"
fi

# --- スリープギャップ: 実経過がtick間隔の3倍を超えたら記録・通知され、無活動時間から差し引かれる ---

WDS_ROOT4="$(wd_new_root)"
WDS_T0_GAP=1700300000
wds_write_heartbeat "$WDS_ROOT4" "$WDS_T0_GAP" "post" "Bash"
WDS_LOG4="${WDS_ROOT4}/.claude/.dev-workflow-watchdog.log"

# 初回tick（前回tickの記録が無いので判定なし）+ 通常のtick間隔（60秒に対し実経過50秒）
wds_tick "$WDS_ROOT4" "$WDS_T0_GAP" 60
wds_tick "$WDS_ROOT4" "$((WDS_T0_GAP + 50))" 60
if grep -q "$(printf '\tsleep-gap\t')" "$WDS_LOG4" 2>/dev/null; then
  fail "watchdog.sh: 通常のtick間隔ではsleep-gapを検知しない" "$(cat "$WDS_LOG4" 2>&1)"
else
  pass "watchdog.sh: 通常のtick間隔ではsleep-gapを検知しない"
fi

# 大きくジャンプ（tick間隔60秒に対し実経過3700秒 > 60*3）→ スリープと判定
WDS_GAP_NOW=$((WDS_T0_GAP + 50 + 3700))
WDS_SINK_GAP="${WDS_WORK}/sleep-gap.json"
wds_tick "$WDS_ROOT4" "$WDS_GAP_NOW" 60 "$WDS_SINK_GAP"
WDS_BODY_GAP="$(wds_read_sink "$WDS_SINK_GAP")"
case "$WDS_BODY_GAP" in
  *"スリープ痕跡"*) pass "watchdog.sh: tick間隔の3倍を超える実経過でsleep-gapが通知される" ;;
  *)                fail "watchdog.sh: tick間隔の3倍を超える実経過でsleep-gapが通知される" "$WDS_BODY_GAP" ;;
esac
case "$WDS_BODY_GAP" in
  *"応答なし"*)
    fail "watchdog.sh: sleep-gap通知にstallの見出し «応答なし» が誤って混ざらない" "$WDS_BODY_GAP" ;;
  *)
    pass "watchdog.sh: sleep-gap通知にstallの見出し «応答なし» が誤って混ざらない" ;;
esac

if grep -q "$(printf '\tsleep-gap\t')" "$WDS_LOG4" 2>/dev/null; then
  pass "watchdog.sh: sleep-gapイベントがログに記録される（差し引き累計を含め後から読める）"
else
  fail "watchdog.sh: sleep-gapイベントがログに記録される" "$(cat "$WDS_LOG4" 2>&1)"
fi

# スリープギャップ直後: 差し引きが効いて誤ってstallとして通知されない
# （素の経過なら now - heartbeat_epoch = 3750秒 > 900秒でストール誤報になるはずだが、
#   ギャップ分3640秒（実経過3700秒からtick_sec 60秒を引いた分）を差し引いた110秒は
#   900秒未満なので通知されない）
if grep -q "$(printf '\tstall\t')" "$WDS_LOG4" 2>/dev/null; then
  fail "watchdog.sh: スリープギャップ直後のtickでストール誤報が出ない（差し引きが効いている）" \
    "$(cat "$WDS_LOG4" 2>&1)"
else
  pass "watchdog.sh: スリープギャップ直後のtickでストール誤報が出ない（差し引きが効いている）"
fi

# --- curlが一度も実行されていないこと（通知はsink経由でのみ検証し、ネットワークに出ない） ---
if [ -s "$WDS_CURL_LOG" ]; then
  fail "watchdog.sh: 通知でsink使用時にcurlが呼ばれない（実送信しない）" "$(wds_read_sink "$WDS_CURL_LOG")"
else
  pass "watchdog.sh: 通知でsink使用時にcurlが呼ばれない（実送信しない）"
fi

# ---------------------------------------------------------------------------
# scripts/watchdog.sh: ウェーブ予算の監視と `- 想定時間:` 宣言（Task #48、Epic #42）
#
# DEV_WORKFLOW_WATCHDOG_NOW で時刻を注入し --wave / --tick-once を組み合わせて、実時間を
# 一切待たずに「run-state書き込み → 予算内は無通知 → 超過で1回だけ通知 → 次のwaveでリセット」
# を検証する。`- 想定時間:` の解析は、実際の `gh issue view` を呼ばず、PATHに差し込んだ
# 偽ghスクリプト（環境変数で指定したディレクトリのファイルを本文として返すだけ）を使い、
# ネットワーク・GitHub 認証に一切依存しない（完了条件: 「gh に依存しないよう、issue本文の
# 入力を差し替えられるようにする」）。通知はTask #47と同じくnotify-slack.shのsink機構で検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/watchdog.sh: ウェーブ予算の監視と - 想定時間: 宣言（Task #48） =="

WB_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-watchdog-budget.XXXXXX")"

# --- --wave: run-stateを期待どおりの形式で書く ---

WB_ROOT1="$(wd_new_root)"
WB_T0=1700400000
DEV_WORKFLOW_MARKER_ROOT="$WB_ROOT1" DEV_WORKFLOW_WATCHDOG_NOW="$WB_T0" \
  bash "$WD_SCRIPT" --wave --epic 48 --wave-no 2 --tasks "44,45,46" --budget-sec 5000 \
  > /dev/null 2>&1
WB_STATE_FILE1="${WB_ROOT1}/.claude/.dev-workflow-run-state"
WB_EXPECTED1=$'epic=48\nwave=2\ntasks=44,45,46\nwave_started=1700400000\nbudget_sec=5000'
WB_ACTUAL1="$(cat "$WB_STATE_FILE1" 2>/dev/null)"
assert_eq "watchdog.sh --wave: run-stateを期待どおりの形式(key=value)で書く" \
  "$WB_EXPECTED1" "$WB_ACTUAL1"

# --- 予算監視: 予算内は無通知・超過で1回だけ通知される・次の --wave でリセットされる ---

WB_ROOT2="$(wd_new_root)"
WB_LOG2="${WB_ROOT2}/.claude/.dev-workflow-watchdog.log"

# wb_tick <root> <now> <tick_sec> [sink_file]  （wds_tickと同じ作法。偽curlはWDS_FAKE_BINを再利用する）
wb_tick() {
  local root="$1" now="$2" tick_sec="$3" sink="${4:-${WB_WORK}/unused-sink.json}"
  DEV_WORKFLOW_MARKER_ROOT="$root" \
  DEV_WORKFLOW_WATCHDOG_NOW="$now" \
  DEV_WORKFLOW_WATCHDOG_TICK_SEC="$tick_sec" \
  SLACK_WEBHOOK_URL="https://example.invalid/webhook" \
  DEV_WORKFLOW_NOTIFY_SINK="$sink" \
  DEV_WORKFLOW_NO_SLEEP_INHIBIT=1 \
  PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once --epic 48 --label "Epic #48 test" > /dev/null 2>&1
}

WB_T0_BUDGET=1700500000
WB_BUDGET=3600
DEV_WORKFLOW_MARKER_ROOT="$WB_ROOT2" DEV_WORKFLOW_WATCHDOG_NOW="$WB_T0_BUDGET" \
  bash "$WD_SCRIPT" --wave --epic 48 --wave-no 1 --tasks "44" --budget-sec "$WB_BUDGET" \
  > /dev/null 2>&1

# 予算内（30分 < 60分）: 無通知
WB_SINK_WITHIN="${WB_WORK}/within-budget.json"
wb_tick "$WB_ROOT2" "$((WB_T0_BUDGET + 1800))" 3600 "$WB_SINK_WITHIN"
if [ -f "$WB_SINK_WITHIN" ]; then
  fail "watchdog.sh: ウェーブ予算内では通知されない" "$(wds_read_sink "$WB_SINK_WITHIN")"
else
  pass "watchdog.sh: ウェーブ予算内では通知されない"
fi

# 予算超過（61分 > 60分）: 1回通知される
WB_OVER_AT=$((WB_T0_BUDGET + 3700))
WB_SINK_OVER="${WB_WORK}/over-budget.json"
wb_tick "$WB_ROOT2" "$WB_OVER_AT" 3600 "$WB_SINK_OVER"
WB_BODY_OVER="$(wds_read_sink "$WB_SINK_OVER")"
case "$WB_BODY_OVER" in
  *"想定時間超過"*) pass "watchdog.sh: ウェーブ予算超過で通知される" ;;
  *)                fail "watchdog.sh: ウェーブ予算超過で通知される" "$WB_BODY_OVER" ;;
esac
case "$WB_BODY_OVER" in
  *"ウェーブ1"*) pass "watchdog.sh: 予算超過の通知本文にウェーブ番号を含む" ;;
  *)             fail "watchdog.sh: 予算超過の通知本文にウェーブ番号を含む" "$WB_BODY_OVER" ;;
esac

# 超過後さらにtickしても再通知されない（1回だけ）
WB_SINK_OVER_AGAIN="${WB_WORK}/over-budget-again.json"
wb_tick "$WB_ROOT2" "$((WB_OVER_AT + 100))" 3600 "$WB_SINK_OVER_AGAIN"
if [ -f "$WB_SINK_OVER_AGAIN" ]; then
  fail "watchdog.sh: ウェーブ予算超過の通知は1回だけ（再通知されない）" \
    "$(wds_read_sink "$WB_SINK_OVER_AGAIN")"
else
  pass "watchdog.sh: ウェーブ予算超過の通知は1回だけ（再通知されない）"
fi

WB_BUDGET_LOG_COUNT1="$(grep -c "$(printf '\tbudget\t')" "$WB_LOG2" 2>/dev/null || true)"
assert_eq "watchdog.sh: 予算超過ログはウェーブ1で1件" "1" "${WB_BUDGET_LOG_COUNT1:-0}"

# 次の --wave の後に再び超過すると、また1回通知される（通知済みフラグがリセットされる）
WB_T1=$((WB_OVER_AT + 200))
DEV_WORKFLOW_MARKER_ROOT="$WB_ROOT2" DEV_WORKFLOW_WATCHDOG_NOW="$WB_T1" \
  bash "$WD_SCRIPT" --wave --epic 48 --wave-no 2 --tasks "44" --budget-sec 1800 > /dev/null 2>&1

WB_SINK_WAVE2_WITHIN="${WB_WORK}/wave2-within.json"
wb_tick "$WB_ROOT2" "$((WB_T1 + 100))" 3600 "$WB_SINK_WAVE2_WITHIN"
if [ -f "$WB_SINK_WAVE2_WITHIN" ]; then
  fail "watchdog.sh: 新しいウェーブの予算内では通知されない" "$(wds_read_sink "$WB_SINK_WAVE2_WITHIN")"
else
  pass "watchdog.sh: 新しいウェーブの予算内では通知されない"
fi

WB_WAVE2_OVER_AT=$((WB_T1 + 1900))
WB_SINK_WAVE2_OVER="${WB_WORK}/wave2-over.json"
wb_tick "$WB_ROOT2" "$WB_WAVE2_OVER_AT" 3600 "$WB_SINK_WAVE2_OVER"
WB_BODY_WAVE2_OVER="$(wds_read_sink "$WB_SINK_WAVE2_OVER")"
case "$WB_BODY_WAVE2_OVER" in
  *"想定時間超過"*"ウェーブ2"*)
    pass "watchdog.sh: 次の--waveの後に再び超過すると、また1回通知される" ;;
  *)
    fail "watchdog.sh: 次の--waveの後に再び超過すると、また1回通知される" "$WB_BODY_WAVE2_OVER" ;;
esac

WB_BUDGET_LOG_COUNT2="$(grep -c "$(printf '\tbudget\t')" "$WB_LOG2" 2>/dev/null || true)"
assert_eq "watchdog.sh: 予算超過ログは合計2件（ウェーブ1で1件・ウェーブ2で1件）" \
  "2" "${WB_BUDGET_LOG_COUNT2:-0}"

# --- run-stateが無い場合: 予算監視をスキップし、他の監視（ストール検知）は動き続ける ---

WB_ROOT3="$(wd_new_root)"
WB_T0_NOSTATE=1700600000
wds_write_heartbeat "$WB_ROOT3" "$WB_T0_NOSTATE" "post" "Bash"

WB_TICK3_OK=1
wb_tick "$WB_ROOT3" "$WB_T0_NOSTATE" 3600 || WB_TICK3_OK=0
assert_eq "watchdog.sh: run-stateが無くてもtick-onceはexit 0で返る" "1" "$WB_TICK3_OK"

WB_SINK_STALL_NOSTATE="${WB_WORK}/stall-no-run-state.json"
wb_tick "$WB_ROOT3" "$((WB_T0_NOSTATE + 16 * 60))" 3600 "$WB_SINK_STALL_NOSTATE"
WB_BODY_STALL_NOSTATE="$(wds_read_sink "$WB_SINK_STALL_NOSTATE")"
case "$WB_BODY_STALL_NOSTATE" in
  *"応答なし"*) pass "watchdog.sh: run-stateが無くてもストール監視は動き続ける" ;;
  *)            fail "watchdog.sh: run-stateが無くてもストール監視は動き続ける" "$WB_BODY_STALL_NOSTATE" ;;
esac

WB_LOG3="${WB_ROOT3}/.claude/.dev-workflow-watchdog.log"
if grep -q "$(printf '\tbudget\t')" "$WB_LOG3" 2>/dev/null; then
  fail "watchdog.sh: run-stateが無い場合に予算監視をスキップする" "$(cat "$WB_LOG3" 2>&1)"
else
  pass "watchdog.sh: run-stateが無い場合に予算監視をスキップする"
fi

# --- `- 想定時間:` の解析: 30m / 2h / 90 / 不正値 / 宣言なし / 複数タスクの最大値 ---
#
# gh には一切依存しない。PATHに差し込む偽ghは `gh issue view <番号> --json body -q .body`
# だけを模倣し、WB_GH_BODY_DIR/<番号>.txt の中身をそのまま本文として返す（無ければ失敗する）。

WB_GH_BODY_DIR="${WB_WORK}/gh-bodies"
mkdir -p "$WB_GH_BODY_DIR"
WB_FAKE_GH_BIN="${WB_WORK}/gh-bin"
mkdir -p "$WB_FAKE_GH_BIN"
cat > "${WB_FAKE_GH_BIN}/gh" <<'FAKE_GH_EOF'
#!/bin/bash
# テスト用の偽gh。`gh issue view <番号> --json body -q .body` だけを模倣する。
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  num="$3"
  file="${WB_GH_BODY_DIR}/${num}.txt"
  if [ -f "$file" ]; then
    cat "$file"
    exit 0
  fi
  exit 1
fi
exit 1
FAKE_GH_EOF
chmod +x "${WB_FAKE_GH_BIN}/gh"

# wb_set_gh_body <issue番号> <本文>
wb_set_gh_body() {
  printf '%s\n' "$2" > "${WB_GH_BODY_DIR}/$1.txt"
}

# wb_wave_budget_sec <root> <tasks_csv>
# --budget-sec なしで --wave を呼び、書かれたrun-stateのbudget_secを返す
wb_wave_budget_sec() {
  local root="$1" tasks="$2"
  DEV_WORKFLOW_MARKER_ROOT="$root" DEV_WORKFLOW_WATCHDOG_NOW=1700700000 \
  WB_GH_BODY_DIR="$WB_GH_BODY_DIR" PATH="${WB_FAKE_GH_BIN}:${PATH}" \
    bash "$WD_SCRIPT" --wave --epic 48 --wave-no 1 --tasks "$tasks" > /dev/null 2>&1
  grep '^budget_sec=' "${root}/.claude/.dev-workflow-run-state" | cut -d= -f2
}

WB_ROOT_EST="$(wd_new_root)"

wb_set_gh_body 201 '- 想定時間: 30m'
assert_eq "watchdog.sh: - 想定時間: 30m → 予算=(30分*2+900秒)=4500秒" \
  "4500" "$(wb_wave_budget_sec "$WB_ROOT_EST" "201")"

wb_set_gh_body 202 '- 想定時間: 2h'
assert_eq "watchdog.sh: - 想定時間: 2h → 予算=(120分*2+900秒)=15300秒" \
  "15300" "$(wb_wave_budget_sec "$WB_ROOT_EST" "202")"

wb_set_gh_body 203 '- 想定時間: 90'
assert_eq "watchdog.sh: - 想定時間: 90（単位なし=分）→ 予算=(90分*2+900秒)=11700秒" \
  "11700" "$(wb_wave_budget_sec "$WB_ROOT_EST" "203")"

wb_set_gh_body 204 '- 想定時間: abc'
assert_eq "watchdog.sh: - 想定時間: 不正値は無視され既定5400秒になる" \
  "5400" "$(wb_wave_budget_sec "$WB_ROOT_EST" "204")"

# タスク205は本文ファイルを作らない（宣言なし）
assert_eq "watchdog.sh: - 想定時間: 宣言が無いタスクは既定5400秒になる" \
  "5400" "$(wb_wave_budget_sec "$WB_ROOT_EST" "205")"

wb_set_gh_body 206 '- 想定時間: 30m'
wb_set_gh_body 207 '- 想定時間: 2h'
assert_eq "watchdog.sh: 複数タスクの - 想定時間: は最大値を使う（2hが優先）→ 15300秒" \
  "15300" "$(wb_wave_budget_sec "$WB_ROOT_EST" "206,207")"

# ghが使えない場合（常に失敗する偽gh）も既定5400秒になる
WB_FAKE_GH_FAIL_BIN="${WB_WORK}/gh-fail-bin"
mkdir -p "$WB_FAKE_GH_FAIL_BIN"
printf '#!/bin/bash\nexit 1\n' > "${WB_FAKE_GH_FAIL_BIN}/gh"
chmod +x "${WB_FAKE_GH_FAIL_BIN}/gh"
WB_ROOT_NOGH="$(wd_new_root)"
DEV_WORKFLOW_MARKER_ROOT="$WB_ROOT_NOGH" DEV_WORKFLOW_WATCHDOG_NOW=1700700000 \
  PATH="${WB_FAKE_GH_FAIL_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --wave --epic 48 --wave-no 1 --tasks "999" > /dev/null 2>&1
WB_BUDGET_NOGH="$(grep '^budget_sec=' "${WB_ROOT_NOGH}/.claude/.dev-workflow-run-state" \
  | cut -d= -f2)"
assert_eq "watchdog.sh --wave: ghが使えない場合は既定5400秒になる" "5400" "$WB_BUDGET_NOGH"

# ---------------------------------------------------------------------------
# scripts/watchdog.sh: スリープ抑止（Task #49、Epic #42）
#
# このサンドボックス（Alpine）には powershell / caffeinate / systemd-inhibit のいずれも
# 存在しないため、OS判定は DEV_WORKFLOW_WATCHDOG_OS で注入し、実行はしない
# （DEV_WORKFLOW_INHIBIT_SINK に組み立てたコマンド文字列だけを書かせて検証する。
# 既存の notify-slack.sh sink・PATH注入の偽コマンド方式に倣う）。
# 「抑止コマンドが失敗する状況」は、Alpineに実在しないpowershellを注入無しでそのまま
# windowsとして実行させることで自然に再現する（フェイクを追加で用意する必要が無い）。
# Windowsの実際の呼び出し成否は、powershellが存在するWindows実機上で --tick-once を
# 直接叩いて別途確認する（テストでは検証しない。issueへ実出力を記録する）。
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/watchdog.sh: スリープ抑止（Task #49） =="

WI_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-watchdog-inhibit.XXXXXX")"

# --- windows: SetThreadExecutionState を含むコマンドが組み立てられる ---

WI_ROOT_WIN="$(wd_new_root)"
WI_SINK_WIN="${WI_WORK}/windows.cmd"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_WIN" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=windows DEV_WORKFLOW_WATCHDOG_TICK_SEC=60 \
DEV_WORKFLOW_INHIBIT_SINK="$WI_SINK_WIN" PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_EXIT_WIN=$?
assert_exit_code "watchdog.sh --tick-once: windows のスリープ抑止 tick は exit 0" 0 "$WI_EXIT_WIN"
WI_CMD_WIN="$(cat "$WI_SINK_WIN" 2>/dev/null)"
case "$WI_CMD_WIN" in
  windows*"SetThreadExecutionState"*"0x00000001"*)
    pass "watchdog.sh: windowsでSetThreadExecutionStateを含むコマンドが組み立てられる" ;;
  *)
    fail "watchdog.sh: windowsでSetThreadExecutionStateを含むコマンドが組み立てられる" "$WI_CMD_WIN" ;;
esac
case "$WI_CMD_WIN" in
  *powershell*-NoProfile*) pass "watchdog.sh: windowsのコマンドはpowershell -NoProfileで組み立てられる" ;;
  *)                       fail "watchdog.sh: windowsのコマンドはpowershell -NoProfileで組み立てられる" "$WI_CMD_WIN" ;;
esac

# --- macos: caffeinate -u -t <tick+30> を含むコマンドが組み立てられる ---

WI_ROOT_MAC="$(wd_new_root)"
WI_SINK_MAC="${WI_WORK}/macos.cmd"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_MAC" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=macos DEV_WORKFLOW_WATCHDOG_TICK_SEC=60 \
DEV_WORKFLOW_INHIBIT_SINK="$WI_SINK_MAC" PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_CMD_MAC="$(cat "$WI_SINK_MAC" 2>/dev/null)"
case "$WI_CMD_MAC" in
  macos*"caffeinate -u -t 90"*)
    pass "watchdog.sh: macosでcaffeinate -u -t <tick+30>を含むコマンドが組み立てられる" ;;
  *)
    fail "watchdog.sh: macosでcaffeinate -u -t <tick+30>を含むコマンドが組み立てられる" "$WI_CMD_MAC" ;;
esac

# --- linux（systemd-inhibitあり）: systemd-inhibit --what=idle --mode=block を含むコマンドが組み立てられる ---

WI_FAKE_BIN="${WI_WORK}/bin"
mkdir -p "$WI_FAKE_BIN"
printf '#!/bin/bash\nexit 0\n' > "${WI_FAKE_BIN}/systemd-inhibit"
chmod +x "${WI_FAKE_BIN}/systemd-inhibit"

WI_ROOT_LINUX="$(wd_new_root)"
WI_SINK_LINUX="${WI_WORK}/linux.cmd"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_LINUX" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=linux DEV_WORKFLOW_WATCHDOG_TICK_SEC=60 \
DEV_WORKFLOW_INHIBIT_SINK="$WI_SINK_LINUX" PATH="${WI_FAKE_BIN}:${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_CMD_LINUX="$(cat "$WI_SINK_LINUX" 2>/dev/null)"
case "$WI_CMD_LINUX" in
  linux*"systemd-inhibit --what=idle --mode=block sleep 90"*)
    pass "watchdog.sh: linux（systemd-inhibitあり）でsystemd-inhibitを含むコマンドが組み立てられる" ;;
  *)
    fail "watchdog.sh: linux（systemd-inhibitあり）でsystemd-inhibitを含むコマンドが組み立てられる" "$WI_CMD_LINUX" ;;
esac

# --- linux（systemd-inhibitなし）: コマンドは組み立てられず、警告のみ記録される ---

WI_ROOT_LINUX_NO="$(wd_new_root)"
WI_SINK_LINUX_NO="${WI_WORK}/linux-no.cmd"
WI_NOTIFY_LINUX_NO="${WI_WORK}/linux-no-notify.json"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_LINUX_NO" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=linux DEV_WORKFLOW_WATCHDOG_TICK_SEC=60 \
DEV_WORKFLOW_INHIBIT_SINK="$WI_SINK_LINUX_NO" \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" DEV_WORKFLOW_NOTIFY_SINK="$WI_NOTIFY_LINUX_NO" \
PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_EXIT_LINUX_NO=$?
assert_exit_code "watchdog.sh: linux（systemd-inhibitなし）でも--tick-onceはexit 0" 0 "$WI_EXIT_LINUX_NO"
if [ -f "$WI_SINK_LINUX_NO" ]; then
  fail "watchdog.sh: linux（systemd-inhibitなし）ではコマンドを組み立てない" "$(cat "$WI_SINK_LINUX_NO")"
else
  pass "watchdog.sh: linux（systemd-inhibitなし）ではコマンドを組み立てない"
fi
WI_LOG_LINUX_NO="${WI_ROOT_LINUX_NO}/.claude/.dev-workflow-watchdog.log"
if grep -q "$(printf '\tsleep-inhibit-warn\t')" "$WI_LOG_LINUX_NO" 2>/dev/null; then
  pass "watchdog.sh: linux（systemd-inhibitなし）は警告としてログに記録される"
else
  fail "watchdog.sh: linux（systemd-inhibitなし）は警告としてログに記録される" "$(cat "$WI_LOG_LINUX_NO" 2>&1)"
fi
WI_NOTIFY_BODY_LINUX_NO="$(cat "$WI_NOTIFY_LINUX_NO" 2>/dev/null)"
case "$WI_NOTIFY_BODY_LINUX_NO" in
  *"スリープ抑止に失敗"*) pass "watchdog.sh: 抑止手段が無い場合もSlackへ警告が通知される" ;;
  *)                      fail "watchdog.sh: 抑止手段が無い場合もSlackへ警告が通知される" "$WI_NOTIFY_BODY_LINUX_NO" ;;
esac

# --- unknown: 警告を1行出しつつ tick が正常終了する ---

WI_ROOT_UNKNOWN="$(wd_new_root)"
WI_NOTIFY_UNKNOWN="${WI_WORK}/unknown-notify.json"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_UNKNOWN" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=unknown \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" DEV_WORKFLOW_NOTIFY_SINK="$WI_NOTIFY_UNKNOWN" \
PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_EXIT_UNKNOWN=$?
assert_exit_code "watchdog.sh: OS=unknownでも--tick-onceはexit 0で正常終了する" 0 "$WI_EXIT_UNKNOWN"
WI_LOG_UNKNOWN="${WI_ROOT_UNKNOWN}/.claude/.dev-workflow-watchdog.log"
WI_UNKNOWN_WARN_COUNT="$(grep -c "$(printf '\tsleep-inhibit-warn\t')" "$WI_LOG_UNKNOWN" 2>/dev/null || true)"
assert_eq "watchdog.sh: OS=unknownでは警告が1行ログに出る" "1" "${WI_UNKNOWN_WARN_COUNT:-0}"

# --- DEV_WORKFLOW_NO_SLEEP_INHIBIT=1: コマンドが一切組み立てられない ---

WI_ROOT_NOINHIBIT="$(wd_new_root)"
WI_SINK_NOINHIBIT="${WI_WORK}/noinhibit.cmd"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_NOINHIBIT" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=windows DEV_WORKFLOW_NO_SLEEP_INHIBIT=1 \
DEV_WORKFLOW_INHIBIT_SINK="$WI_SINK_NOINHIBIT" PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_EXIT_NOINHIBIT=$?
assert_exit_code "watchdog.sh: DEV_WORKFLOW_NO_SLEEP_INHIBIT=1でも--tick-onceはexit 0" 0 "$WI_EXIT_NOINHIBIT"
if [ -f "$WI_SINK_NOINHIBIT" ]; then
  fail "watchdog.sh: DEV_WORKFLOW_NO_SLEEP_INHIBIT=1ではコマンドが一切組み立てられない" \
    "$(cat "$WI_SINK_NOINHIBIT")"
else
  pass "watchdog.sh: DEV_WORKFLOW_NO_SLEEP_INHIBIT=1ではコマンドが一切組み立てられない"
fi
WI_LOG_NOINHIBIT="${WI_ROOT_NOINHIBIT}/.claude/.dev-workflow-watchdog.log"
if grep -q "sleep-inhibit" "$WI_LOG_NOINHIBIT" 2>/dev/null; then
  fail "watchdog.sh: DEV_WORKFLOW_NO_SLEEP_INHIBIT=1では抑止関連のログも一切残らない" \
    "$(cat "$WI_LOG_NOINHIBIT" 2>&1)"
else
  pass "watchdog.sh: DEV_WORKFLOW_NO_SLEEP_INHIBIT=1では抑止関連のログも一切残らない"
fi

# --- 抑止コマンドが失敗する状況（Alpineに実在しないpowershellをそのまま呼ぶ）でも exit 0 ---

WI_ROOT_FAIL="$(wd_new_root)"
WI_NOTIFY_FAIL="${WI_WORK}/fail-notify.json"
DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_FAIL" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=windows \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" DEV_WORKFLOW_NOTIFY_SINK="$WI_NOTIFY_FAIL" \
PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
WI_EXIT_FAIL=$?
assert_exit_code "watchdog.sh: 抑止コマンドが失敗する状況（powershellが存在しない）でも--tick-onceはexit 0" \
  0 "$WI_EXIT_FAIL"
WI_LOG_FAIL="${WI_ROOT_FAIL}/.claude/.dev-workflow-watchdog.log"
if grep -q "$(printf '\tsleep-inhibit-warn\t')" "$WI_LOG_FAIL" 2>/dev/null; then
  pass "watchdog.sh: 抑止コマンドの実行失敗が警告としてログに記録される"
else
  fail "watchdog.sh: 抑止コマンドの実行失敗が警告としてログに記録される" "$(cat "$WI_LOG_FAIL" 2>&1)"
fi

# --- 同じ警告は毎tick Slackへ通知されない（初回のみ・以降はログのみ） ---

WI_ROOT_WARNONCE="$(wd_new_root)"
WI_NOTIFY_WARNONCE_1="${WI_WORK}/warnonce-1.json"
WI_NOTIFY_WARNONCE_2="${WI_WORK}/warnonce-2.json"

DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_WARNONCE" DEV_WORKFLOW_WATCHDOG_NOW=1700800000 \
DEV_WORKFLOW_WATCHDOG_OS=unknown \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" DEV_WORKFLOW_NOTIFY_SINK="$WI_NOTIFY_WARNONCE_1" \
PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
if [ -f "$WI_NOTIFY_WARNONCE_1" ]; then
  pass "watchdog.sh: 抑止警告は初回tickでSlackへ通知される"
else
  fail "watchdog.sh: 抑止警告は初回tickでSlackへ通知される" "sinkが作られませんでした"
fi

DEV_WORKFLOW_MARKER_ROOT="$WI_ROOT_WARNONCE" DEV_WORKFLOW_WATCHDOG_NOW=1700800100 \
DEV_WORKFLOW_WATCHDOG_OS=unknown \
SLACK_WEBHOOK_URL="https://example.invalid/webhook" DEV_WORKFLOW_NOTIFY_SINK="$WI_NOTIFY_WARNONCE_2" \
PATH="${WDS_FAKE_BIN}:${PATH}" \
  bash "$WD_SCRIPT" --tick-once > /dev/null 2>&1
if [ -f "$WI_NOTIFY_WARNONCE_2" ]; then
  fail "watchdog.sh: 同じ抑止警告は2回目以降Slackへ通知されない（初回のみ）" \
    "$(cat "$WI_NOTIFY_WARNONCE_2")"
else
  pass "watchdog.sh: 同じ抑止警告は2回目以降Slackへ通知されない（初回のみ）"
fi

WI_LOG_WARNONCE="${WI_ROOT_WARNONCE}/.claude/.dev-workflow-watchdog.log"
WI_WARNONCE_LOG_COUNT="$(grep -c "$(printf '\tsleep-inhibit-warn\t')" "$WI_LOG_WARNONCE" 2>/dev/null || true)"
assert_eq "watchdog.sh: ログには通知の有無に関わらず毎tick記録される（2回）" "2" "${WI_WARNONCE_LOG_COUNT:-0}"

# --- 受け入れ条件6の再確認: スリープ抑止のフックにもkill/自動打ち切り経路が無いこと ---

WI_INHIBIT_BLOCK="$(awk '
  /^_watchdog_detect_os\(\) \{/ {f=1}
  f {print}
  /^_watchdog_sleep_inhibit_tick\(\) \{/ {g=1}
  g && /^}/ {print; exit}
' "$WD_SCRIPT")"
if printf '%s' "$WI_INHIBIT_BLOCK" | grep -qE '\bkill\b'; then
  fail "watchdog.sh: スリープ抑止のコードにkillが存在しない（受け入れ条件6）" "$WI_INHIBIT_BLOCK"
else
  pass "watchdog.sh: スリープ抑止のコードにkillが存在しない（受け入れ条件6）"
fi

# --- curlが一度も実行されていないこと（本セクションの通知もsink経由でのみ検証する） ---
if [ -s "$WDS_CURL_LOG" ]; then
  fail "watchdog.sh: ウェーブ予算・スリープ抑止の通知でもcurlが呼ばれない（実送信しない）" \
    "$(wds_read_sink "$WDS_CURL_LOG")"
else
  pass "watchdog.sh: ウェーブ予算・スリープ抑止の通知でもcurlが呼ばれない（実送信しない）"
fi

# ---------------------------------------------------------------------------
# hooks.json / hooks.codex.json: heartbeat結線（Task #52）
# ---------------------------------------------------------------------------

echo "== hooks.json / hooks.codex.json: heartbeat結線（Task #52） =="

HJ_HOOKS_JSON="${REPO_ROOT}/hooks/hooks.json"
HJ_HOOKS_CODEX_JSON="${REPO_ROOT}/hooks/hooks.codex.json"
HJ_HEARTBEAT_SCRIPT="${REPO_ROOT}/scripts/heartbeat.sh"

# JSONとしての構文妥当性を、jq/pythonを新たに足さず括弧の対応だけで確認する
# （文字列リテラル内の括弧は無視する）。完全なJSONパーサではないが、
# このタスクで書き換える範囲の妥当性を検証するには十分（issue #52 の指示どおり
# 「既存に検証手段が無ければ grep で必要なキー・文字列の存在を確認する」方針に沿う）。
_hj_json_syntax_ok() {
  local file="$1"
  local content
  content="$(cat "$file" 2>/dev/null)" || return 1
  local len=${#content}
  local i char depth_curly=0 depth_square=0 in_string=0 escape=0
  for ((i = 0; i < len; i++)); do
    char="${content:i:1}"
    if [ "$escape" -eq 1 ]; then
      escape=0
      continue
    fi
    if [ "$in_string" -eq 1 ]; then
      case "$char" in
        '\') escape=1 ;;
        '"') in_string=0 ;;
      esac
      continue
    fi
    case "$char" in
      '"') in_string=1 ;;
      '{') depth_curly=$((depth_curly + 1)) ;;
      '}') depth_curly=$((depth_curly - 1)); [ "$depth_curly" -lt 0 ] && return 1 ;;
      '[') depth_square=$((depth_square + 1)) ;;
      ']') depth_square=$((depth_square - 1)); [ "$depth_square" -lt 0 ] && return 1 ;;
    esac
  done
  [ "$depth_curly" -eq 0 ] && [ "$depth_square" -eq 0 ] && [ "$in_string" -eq 0 ]
}

# トップレベルキー（4スペースインデント。例: `    "PostToolUse": [`）から、
# 対応する閉じ `],` または `]` までを抜き出す。結線の取り違え（pre/postの混同など）を
# セクション単位で検出するために使う。
_hj_extract_section() {
  local file="$1" key="$2"
  awk -v line="    \"${key}\": [" '
    $0 == line {f = 1}
    f {print}
    f && /^    \],?$/ {exit}
  ' "$file"
}

if _hj_json_syntax_ok "$HJ_HOOKS_JSON"; then
  pass "hooks.json: 構文として妥当（括弧の対応が取れている）"
else
  fail "hooks.json: 構文として妥当（括弧の対応が取れている）" "$(cat "$HJ_HOOKS_JSON" 2>&1)"
fi

if _hj_json_syntax_ok "$HJ_HOOKS_CODEX_JSON"; then
  pass "hooks.codex.json: 構文として妥当（括弧の対応が取れている）"
else
  fail "hooks.codex.json: 構文として妥当（括弧の対応が取れている）" "$(cat "$HJ_HOOKS_CODEX_JSON" 2>&1)"
fi

# --- heartbeat.sh の実契約（pre|postのみを受理する）を確認してから、結線がそれに沿っているか検証する ---

HJ_HB_ACCEPTED_LINE="$(grep -E '^\s*pre\|post\)' "$HJ_HEARTBEAT_SCRIPT")"
if printf '%s' "$HJ_HB_ACCEPTED_LINE" | grep -q 'pre' \
  && printf '%s' "$HJ_HB_ACCEPTED_LINE" | grep -q 'post'; then
  pass "heartbeat.sh: 受理する引数がpre/postであることを確認できる（結線テストの前提）"
else
  fail "heartbeat.sh: 受理する引数がpre/postであることを確認できる（結線テストの前提）" \
    "case文にpre|postが見つかりません: ${HJ_HB_ACCEPTED_LINE}"
fi

# --- hooks.json: PreToolUse(作業ツール)にheartbeat.sh preが結線されている ---

# JSON文字列内の `"` はエスケープされて `\"` になっているため、grep -Fq の照合パターンにも
# バックスラッシュを含める（例: `"command": "bash \"${CLAUDE_PLUGIN_ROOT}/...\" pre"`）。
# ここを素の `"` のまま書くと、実ファイルの内容と1文字も一致せず必ず不一致になる。
HJ_PRETOOLUSE="$(_hj_extract_section "$HJ_HOOKS_JSON" "PreToolUse")"
if printf '%s' "$HJ_PRETOOLUSE" | grep -Eq '"matcher": "[^"]*Bash[^"]*"' \
  && printf '%s' "$HJ_PRETOOLUSE" | grep -Eq '"matcher": "[^"]*Task[^"]*"' \
  && printf '%s' "$HJ_PRETOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh\" pre'; then
  pass "hooks.json: PreToolUse(作業ツール)にheartbeat.sh preが結線されている"
else
  fail "hooks.json: PreToolUse(作業ツール)にheartbeat.sh preが結線されている" "$HJ_PRETOOLUSE"
fi

# matcher は `*`（全ツール）ではなく「実際に作業するツール」に限る。Read/Grep/Glob は
# 1ターンに何十回も呼ばれ、1回ごとに bash 起動コストを払う。読み取りだけが続く状態で
# heartbeat が更新され続けると watchdog のストール検知が鈍る
# （core/instructions.md「ハング・スリープの検知」）。
if printf '%s' "$HJ_PRETOOLUSE" | grep -Fq '"matcher": "*"' \
  || printf '%s' "$HJ_PRETOOLUSE" | grep -Eq '"matcher": "[^"]*(Read|Grep|Glob)[^"]*"'; then
  fail "hooks.json: PreToolUseのmatcherが読み取り専用ツールを含まない（*も不可）" "$HJ_PRETOOLUSE"
else
  pass "hooks.json: PreToolUseのmatcherが読み取り専用ツールを含まない（*も不可）"
fi

# pre/postの取り違えはabort判定（#50）を機能させなくする致命的なバグになるため、
# 混入していないことを個別に確認する
if printf '%s' "$HJ_PRETOOLUSE" | grep -Fq 'heartbeat.sh\" post'; then
  fail "hooks.json: PreToolUseにheartbeat.sh postが紛れ込んでいない" "$HJ_PRETOOLUSE"
else
  pass "hooks.json: PreToolUseにheartbeat.sh postが紛れ込んでいない"
fi

# --- hooks.json: PostToolUse(作業ツール)にheartbeat.sh postが結線され、既存の可読性ガードも残っている ---

HJ_POSTTOOLUSE="$(_hj_extract_section "$HJ_HOOKS_JSON" "PostToolUse")"
if printf '%s' "$HJ_POSTTOOLUSE" | grep -Eq '"matcher": "[^"]*Bash[^"]*"' \
  && printf '%s' "$HJ_POSTTOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh\" post'; then
  pass "hooks.json: PostToolUse(作業ツール)にheartbeat.sh postが結線されている"
else
  fail "hooks.json: PostToolUse(作業ツール)にheartbeat.sh postが結線されている" "$HJ_POSTTOOLUSE"
fi

# matcher は `*`（全ツール）ではなく「実際に作業するツール」に限る。Read/Grep/Glob は
# 1ターンに何十回も呼ばれ、1回ごとに bash 起動コストを払う。読み取りだけが続く状態で
# heartbeat が更新され続けると watchdog のストール検知が鈍る
# （core/instructions.md「ハング・スリープの検知」）。
if printf '%s' "$HJ_POSTTOOLUSE" | grep -Fq '"matcher": "*"' \
  || printf '%s' "$HJ_POSTTOOLUSE" | grep -Eq '"matcher": "[^"]*(Read|Grep|Glob)[^"]*"'; then
  fail "hooks.json: PostToolUseのmatcherが読み取り専用ツールを含まない（*も不可）" "$HJ_POSTTOOLUSE"
else
  pass "hooks.json: PostToolUseのmatcherが読み取り専用ツールを含まない（*も不可）"
fi

if printf '%s' "$HJ_POSTTOOLUSE" | grep -Fq 'heartbeat.sh\" pre'; then
  fail "hooks.json: PostToolUseにheartbeat.sh preが紛れ込んでいない" "$HJ_POSTTOOLUSE"
else
  pass "hooks.json: PostToolUseにheartbeat.sh preが紛れ込んでいない"
fi

if printf '%s' "$HJ_POSTTOOLUSE" | grep -Fq '"matcher": "Write|Edit|MultiEdit"' \
  && printf '%s' "$HJ_POSTTOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh\"'; then
  pass "hooks.json: PostToolUseの既存check-readability.sh（matcher=Write|Edit|MultiEdit）が残っている"
else
  fail "hooks.json: PostToolUseの既存check-readability.sh（matcher=Write|Edit|MultiEdit）が残っている" \
    "$HJ_POSTTOOLUSE"
fi

# --- hooks.codex.json: PreToolUse(作業ツール)にheartbeat.sh preが結線されている ---
#
# CodexのイベントにPreToolUseは実在する（docs/dev-workflow-multi-vendor-guide.md §3.5.1）。
# 当初（#52）はこれを「Codexに存在しない」と誤認して縮退させていたが、レビュー#59で
# タスク間の不整合として指摘され、レビュー#61（state=postしか記録されず原因切り分けが
# 成立しない）と合わせて結線することにした（詳細はheartbeat.shの打ち切り判定コメントを参照）。
# ブロック契約自体はClaude Codeと異なり`continue`非対応でsystemMessageのみ（§3.5.2）だが、
# state=preの記録（pre/postの切り分け）自体はブロック契約と独立して機能するため、
# 結線するだけで#61の実害（stateが常にpostになる問題）は解消する。

HJ_CODEX_PRETOOLUSE="$(_hj_extract_section "$HJ_HOOKS_CODEX_JSON" "PreToolUse")"
if printf '%s' "$HJ_CODEX_PRETOOLUSE" | grep -Eq '"matcher": "[^"]*shell[^"]*"' \
  && printf '%s' "$HJ_CODEX_PRETOOLUSE" | grep -Eq '"matcher": "[^"]*apply_patch[^"]*"' \
  && printf '%s' "$HJ_CODEX_PRETOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh\" pre'; then
  pass "hooks.codex.json: PreToolUse(作業ツール)にheartbeat.sh preが結線されている（#59, #61）"
else
  fail "hooks.codex.json: PreToolUse(作業ツール)にheartbeat.sh preが結線されている（#59, #61）" \
    "$HJ_CODEX_PRETOOLUSE"
fi

# matcher は `*`（全ツール）ではなく「実際に作業するツール」に限る。Read/Grep/Glob は
# 1ターンに何十回も呼ばれ、1回ごとに bash 起動コストを払う。読み取りだけが続く状態で
# heartbeat が更新され続けると watchdog のストール検知が鈍る
# （core/instructions.md「ハング・スリープの検知」）。
if printf '%s' "$HJ_CODEX_PRETOOLUSE" | grep -Fq '"matcher": "*"' \
  || printf '%s' "$HJ_CODEX_PRETOOLUSE" | grep -Eq '"matcher": "[^"]*(Read|Grep|Glob)[^"]*"'; then
  fail "hooks.codex.json: PreToolUseのmatcherが読み取り専用ツールを含まない（*も不可）" "$HJ_CODEX_PRETOOLUSE"
else
  pass "hooks.codex.json: PreToolUseのmatcherが読み取り専用ツールを含まない（*も不可）"
fi

if printf '%s' "$HJ_CODEX_PRETOOLUSE" | grep -Fq 'heartbeat.sh\" post'; then
  fail "hooks.codex.json: PreToolUseにheartbeat.sh postが紛れ込んでいない" "$HJ_CODEX_PRETOOLUSE"
else
  pass "hooks.codex.json: PreToolUseにheartbeat.sh postが紛れ込んでいない"
fi

HJ_CODEX_POSTTOOLUSE="$(_hj_extract_section "$HJ_HOOKS_CODEX_JSON" "PostToolUse")"
if printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Eq '"matcher": "[^"]*shell[^"]*"' \
  && printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh\" post'; then
  pass "hooks.codex.json: PostToolUse(作業ツール)にheartbeat.sh postが結線されている"
else
  fail "hooks.codex.json: PostToolUse(作業ツール)にheartbeat.sh postが結線されている" "$HJ_CODEX_POSTTOOLUSE"
fi

# matcher は `*`（全ツール）ではなく「実際に作業するツール」に限る。Read/Grep/Glob は
# 1ターンに何十回も呼ばれ、1回ごとに bash 起動コストを払う。読み取りだけが続く状態で
# heartbeat が更新され続けると watchdog のストール検知が鈍る
# （core/instructions.md「ハング・スリープの検知」）。
if printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Fq '"matcher": "*"' \
  || printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Eq '"matcher": "[^"]*(Read|Grep|Glob)[^"]*"'; then
  fail "hooks.codex.json: PostToolUseのmatcherが読み取り専用ツールを含まない（*も不可）" "$HJ_CODEX_POSTTOOLUSE"
else
  pass "hooks.codex.json: PostToolUseのmatcherが読み取り専用ツールを含まない（*も不可）"
fi

if printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Fq 'heartbeat.sh\" pre'; then
  fail "hooks.codex.json: PostToolUseにheartbeat.sh preが紛れ込んでいない" "$HJ_CODEX_POSTTOOLUSE"
else
  pass "hooks.codex.json: PostToolUseにheartbeat.sh preが紛れ込んでいない"
fi

if printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Fq '"matcher": "Write|Edit|MultiEdit|apply_patch"' \
  && printf '%s' "$HJ_CODEX_POSTTOOLUSE" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh\"'; then
  pass "hooks.codex.json: PostToolUseの既存check-readability.sh（matcher=Write|Edit|MultiEdit|apply_patch）が残っている"
else
  fail "hooks.codex.json: PostToolUseの既存check-readability.sh（matcher=Write|Edit|MultiEdit|apply_patch）が残っている" \
    "$HJ_CODEX_POSTTOOLUSE"
fi

# --- hooks.codex.json: 既存のStop3フック（通知・可読性ガード・変更チェック）が残っている ---

HJ_CODEX_STOP="$(_hj_extract_section "$HJ_HOOKS_CODEX_JSON" "Stop")"
if printf '%s' "$HJ_CODEX_STOP" | grep -Fq 'notify-slack.sh\" stop' \
  && printf '%s' "$HJ_CODEX_STOP" | grep -Fq 'check-readability.sh\" --git' \
  && printf '%s' "$HJ_CODEX_STOP" | grep -Fq 'check-stop-review.sh\"'; then
  pass "hooks.codex.json: 既存のStop3フック（通知・可読性ガード・変更チェック）が残っている"
else
  fail "hooks.codex.json: 既存のStop3フック（通知・可読性ガード・変更チェック）が残っている" "$HJ_CODEX_STOP"
fi

# --- 両JSONとも heartbeat.sh の結線が ${CLAUDE_PLUGIN_ROOT} を使ったパス指定になっている ---

if grep -Fq '${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh' "$HJ_HOOKS_JSON"; then
  pass "hooks.json: heartbeat.shの結線が\${CLAUDE_PLUGIN_ROOT}を使ったパス指定になっている"
else
  fail "hooks.json: heartbeat.shの結線が\${CLAUDE_PLUGIN_ROOT}を使ったパス指定になっている" \
    "$(cat "$HJ_HOOKS_JSON")"
fi

if grep -Fq '${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh' "$HJ_HOOKS_CODEX_JSON"; then
  pass "hooks.codex.json: heartbeat.shの結線が\${CLAUDE_PLUGIN_ROOT}を使ったパス指定になっている"
else
  fail "hooks.codex.json: heartbeat.shの結線が\${CLAUDE_PLUGIN_ROOT}を使ったパス指定になっている" \
    "$(cat "$HJ_HOOKS_CODEX_JSON")"
fi

# --- フックが参照しているscripts/heartbeat.shが実在する（参照切れの防止） ---

if [ -f "$HJ_HEARTBEAT_SCRIPT" ]; then
  pass "hooks.json/hooks.codex.json: 参照しているscripts/heartbeat.shが実在する"
else
  fail "hooks.json/hooks.codex.json: 参照しているscripts/heartbeat.shが実在する" \
    "見つかりません: ${HJ_HEARTBEAT_SCRIPT}"
fi

# ---------------------------------------------------------------------------
# ドキュメント（共通ルール・generator・README）とアダプタ再生成・v0.13.0（#55）
# ---------------------------------------------------------------------------

echo "== ドキュメント（共通ルール・generator・README）とアダプタ再生成・v0.13.0（#55） =="

DOC55_CLAUDE_PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"
DOC55_CODEX_PLUGIN_JSON="${REPO_ROOT}/.codex-plugin/plugin.json"
# core/instructions.md 本体だけでなく core/references/*.md への退避先も見る（#146）。
DOC55_INSTRUCTIONS="$CORE_INSTRUCTIONS_FLAT"
DOC55_GENERATOR_ROLE="${REPO_ROOT}/core/roles/generator.md"
DOC55_README="${REPO_ROOT}/README.md"
DOC55_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC55_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"

# --- 両 plugin.json のバージョンが 0.17.0 で一致している（#122 でマイナー更新） ---

DOC55_CLAUDE_VERSION="$(grep -m1 '"version"' "$DOC55_CLAUDE_PLUGIN_JSON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
DOC55_CODEX_VERSION="$(grep -m1 '"version"' "$DOC55_CODEX_PLUGIN_JSON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

assert_eq ".claude-plugin/plugin.json のバージョンが0.17.0である" "0.17.0" "$DOC55_CLAUDE_VERSION"
assert_eq ".codex-plugin/plugin.json のバージョンが0.17.0である" "0.17.0" "$DOC55_CODEX_VERSION"
assert_eq "両plugin.jsonのバージョンが一致している" "$DOC55_CLAUDE_VERSION" "$DOC55_CODEX_VERSION"

# --- core/instructions.md に watchdog の3点の記述がある ---

if grep -Fq 'watchdog は検知して通知するだけであり' "$DOC55_INSTRUCTIONS"; then
  pass "core/instructions.md: 「watchdogは検知して通知するだけ」の記述がある"
else
  fail "core/instructions.md: 「watchdogは検知して通知するだけ」の記述がある"
fi

if grep -Fq '自動打ち切りは原理的に実装できない' "$DOC55_INSTRUCTIONS" \
  && grep -Fq 'Claude Code ではサブエージェントを外部から中断できない' "$DOC55_INSTRUCTIONS"; then
  pass "core/instructions.md: 「Claude Codeでは自動打ち切りが原理的に不可能」の記述がある"
else
  fail "core/instructions.md: 「Claude Codeでは自動打ち切りが原理的に不可能」の記述がある"
fi

if grep -Fq 'アダプタ間に' "$DOC55_INSTRUCTIONS" && grep -Fq '機能差を作らないため採用していない' "$DOC55_INSTRUCTIONS"; then
  pass "core/instructions.md: 「Codexでも採用していない（機能差を作らない）」の記述がある"
else
  fail "core/instructions.md: 「Codexでも採用していない（機能差を作らない）」の記述がある"
fi

# --- core/roles/generator.md に拒否メッセージを受けたときの振る舞いの記述がある ---

if grep -Fq '打ち切りが指示されました' "$DOC55_GENERATOR_ROLE" \
  && grep -Fq '別のツールで迂回・回避を試みない' "$DOC55_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 拒否メッセージを受けたときの振る舞い（別のツールで回避しない）の記述がある"
else
  fail "core/roles/generator.md: 拒否メッセージを受けたときの振る舞い（別のツールで回避しない）の記述がある"
fi

if grep -Fq '実施済みの変更・' "$DOC55_GENERATOR_ROLE" && grep -Fq '未コミットの有無' "$DOC55_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 拒否メッセージを受けたときに現状（変更・未コミット）を報告する記述がある"
else
  fail "core/roles/generator.md: 拒否メッセージを受けたときに現状（変更・未コミット）を報告する記述がある"
fi

# --- README に運用手順の節と「抑止できないもの」の記述がある ---

if grep -Fq '## 運用手順（watchdog）' "$DOC55_README"; then
  pass "README.md: 「運用手順（watchdog）」の節がある"
else
  fail "README.md: 「運用手順（watchdog）」の節がある"
fi

if grep -Fq '抑止できないもの' "$DOC55_README" \
  && grep -Fq 'ふたを閉じる操作' "$DOC55_README" \
  && grep -Fq 'バッテリー切れ' "$DOC55_README"; then
  pass "README.md: 「抑止できないもの」（ふたを閉じる操作・バッテリー切れ等）の記述がある"
else
  fail "README.md: 「抑止できないもの」（ふたを閉じる操作・バッテリー切れ等）の記述がある"
fi

if grep -Fq 'DEV_WORKFLOW_WATCHDOG_IDLE_SEC' "$DOC55_README" \
  && grep -Fq 'DEV_WORKFLOW_NO_SLEEP_INHIBIT' "$DOC55_README"; then
  pass "README.md: watchdogの環境変数一覧がある"
else
  fail "README.md: watchdogの環境変数一覧がある"
fi

# セッション中断後は watchdog.sh --stop を実行する旨の記述が存在すること（レビュー#62）。
# セッションをプロセスごと中断するとStopフックが発火せずrunマーカーが残り続け、
# watchdogが打ち切りに気付かないまま無活動検知・エスカレーション通知を出し続けるため。
DOC62_README_HANG_SECTION="$(awk '/^### ハングしたときの対処/{f=1} /^### スリープ抑止/{f=0} f' "$DOC55_README")"

if [ -n "$DOC62_README_HANG_SECTION" ]; then
  pass "README.md: 「ハングしたときの対処」の節が存在する（#62）"
else
  fail "README.md: 「ハングしたときの対処」の節が存在する（#62）" "節が見つかりません"
fi

case "$DOC62_README_HANG_SECTION" in
  *'watchdog.sh" --stop'*)
    pass "README.md: ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" ;;
  *)
    fail "README.md: ハング時の節にセッション中断後の watchdog.sh --stop の指示がある（#62）" \
      "$DOC62_README_HANG_SECTION" ;;
esac

case "$DOC62_README_HANG_SECTION" in
  *'Stop フックが走らず'*'run マーカー'*)
    pass "README.md: セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" ;;
  *)
    fail "README.md: セッション中断時にStopフックが走らずrunマーカーが残る旨の説明がある（#62）" \
      "$DOC62_README_HANG_SECTION" ;;
esac

# --- 生成物（agents/generator.md 等）に正本の追記内容が反映されている ---

if [ -f "$DOC55_AGENT_GENERATOR" ] \
  && grep -Fq '打ち切りが指示されました' "$DOC55_AGENT_GENERATOR" \
  && grep -Fq 'watchdog は検知して通知するだけであり' "$DOC55_AGENT_GENERATOR"; then
  pass "agents/generator.md: 正本（core/roles/generator.md・core/instructions.md）の追記内容が反映されている"
else
  fail "agents/generator.md: 正本（core/roles/generator.md・core/instructions.md）の追記内容が反映されている" \
    "見つかりません: ${DOC55_AGENT_GENERATOR}"
fi

if [ -f "$DOC55_CODEX_AGENT_GENERATOR" ] \
  && grep -Fq '打ち切りが指示されました' "$DOC55_CODEX_AGENT_GENERATOR" \
  && grep -Fq 'watchdog は検知して通知するだけであり' "$DOC55_CODEX_AGENT_GENERATOR"; then
  pass "codex-agents/generator.toml: 正本の追記内容が反映されている"
else
  fail "codex-agents/generator.toml: 正本の追記内容が反映されている" \
    "見つかりません: ${DOC55_CODEX_AGENT_GENERATOR}"
fi

# --- adapters/claude/build.sh・adapters/codex/build.sh の再生成後に差分が出ない（--check） ---

DOC55_CLAUDE_BUILD_CHECK_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-claude-build-check.XXXXXX")"
DOC55_CODEX_BUILD_CHECK_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-codex-build-check.XXXXXX")"

if bash "${REPO_ROOT}/adapters/claude/build.sh" --check >"$DOC55_CLAUDE_BUILD_CHECK_LOG" 2>&1; then
  pass "adapters/claude/build.sh --check: 生成物が正本と一致している（再生成後に差分が無い）"
else
  fail "adapters/claude/build.sh --check: 生成物が正本と一致している（再生成後に差分が無い）" \
    "$(cat "$DOC55_CLAUDE_BUILD_CHECK_LOG")"
fi

if bash "${REPO_ROOT}/adapters/codex/build.sh" --check >"$DOC55_CODEX_BUILD_CHECK_LOG" 2>&1; then
  pass "adapters/codex/build.sh --check: 生成物が正本と一致している（再生成後に差分が無い）"
else
  fail "adapters/codex/build.sh --check: 生成物が正本と一致している（再生成後に差分が無い）" \
    "$(cat "$DOC55_CODEX_BUILD_CHECK_LOG")"
fi

# ---------------------------------------------------------------------------
# generator がバックグラウンド化されたテストの「通知待ち」で停止しない（issue #138）
#
# ハーネスが長時間コマンドを自動でバックグラウンド化しても、それを generator 自身が
# 待たずに「通知待ち」を宣言してターンを終えると、コミット0件のままレーンが停止する
# （7回発生）。単に「バックグラウンド実行しない」と書くのではなく、待たずに終える
# 誤認の理由（後続ターンが存在しない）と、完了確認の手段を明記していることを確認する。
# ---------------------------------------------------------------------------

echo "== generatorがバックグラウンド化されたテストの通知待ちで停止しない（#138） =="

DOC138_GENERATOR_ROLE="${REPO_ROOT}/core/roles/generator.md"
DOC138_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC138_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"
DOC138_SKILL="$RUN_SKILL_FLAT"

if grep -Fq 'バックグラウンド化されても「通知待ち」で停止しない' "$DOC138_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: バックグラウンド化されても停止しない旨の節がある（#138）"
else
  fail "core/roles/generator.md: バックグラウンド化されても停止しない旨の節がある（#138）"
fi

if grep -Fq '後から届く' "$DOC138_GENERATOR_ROLE" && grep -Fq '後続ターンは存在しない' "$DOC138_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 通知を待てない理由（後続ターンが存在しない）が説明されている（#138）"
else
  fail "core/roles/generator.md: 通知を待てない理由（後続ターンが存在しない）が説明されている（#138）"
fi

if grep -Fq 'コミットに到達せずに報告を終えてはならない' "$DOC138_GENERATOR_ROLE" \
  && grep -Fq 'git log --oneline -1' "$DOC138_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: コミット到達前に報告を終えない旨とgit log確認の記述がある（#138）"
else
  fail "core/roles/generator.md: コミット到達前に報告を終えない旨とgit log確認の記述がある（#138）"
fi

if [ -f "$DOC138_AGENT_GENERATOR" ] \
  && grep -Fq 'バックグラウンド化されても「通知待ち」で停止しない' "$DOC138_AGENT_GENERATOR"; then
  pass "agents/generator.md: 正本の#138追記内容が反映されている"
else
  fail "agents/generator.md: 正本の#138追記内容が反映されている" \
    "見つかりません: ${DOC138_AGENT_GENERATOR}"
fi

if [ -f "$DOC138_CODEX_AGENT_GENERATOR" ] \
  && grep -Fq 'バックグラウンド化されても「通知待ち」で停止しない' "$DOC138_CODEX_AGENT_GENERATOR"; then
  pass "codex-agents/generator.toml: 正本の#138追記内容が反映されている"
else
  fail "codex-agents/generator.toml: 正本の#138追記内容が反映されている" \
    "見つかりません: ${DOC138_CODEX_AGENT_GENERATOR}"
fi

# --- run側の救済（提案4。ただし#192でcore/instructions.mdとの矛盾・事実誤認を修正）:
#     skills/run/SKILL.md Step 4 が「コミット0件だが未コミットの変更がある」レーンを
#     通常の失敗と区別して報告する記述を持つ ---
if grep -Fq '未完」として報告に記録する' "$DOC138_SKILL" && grep -Fq 'コミット0件だが作業ツリーに未コミットの変更が残っている' "$DOC138_SKILL"; then
  pass "SKILL.md: レーン内ゲート判定が「コミット0件だが未コミットの変更あり」を失敗と区別している（#138）"
else
  fail "SKILL.md: レーン内ゲート判定が「コミット0件だが未コミットの変更あり」を失敗と区別している（#138）"
fi

# --- #192: 「同一ウェーブ内で再開できる経路があればそれを優先し」というcore/instructions.md
#     「ウェーブ内では再試行しない」と衝突する記述が無く、代わりに
#     core/instructions.mdの規定どおり明記されていることを確認する ---
if grep -Fq '同一ウェーブ内で再開' "$DOC138_SKILL"; then
  fail "SKILL.md: core/instructions.mdと衝突する「同一ウェーブ内で再開」の記述が無い（#192）" \
    "$(grep -n '同一ウェーブ内で再開' "$DOC138_SKILL")"
else
  pass "SKILL.md: core/instructions.mdと衝突する「同一ウェーブ内で再開」の記述が無い（#192）"
fi

if grep -Fq 'ただしウェーブ内では' "$DOC138_SKILL" && grep -Fq '再試行しない' "$DOC138_SKILL"; then
  pass "SKILL.md: 「未完」扱いでもウェーブ内では再試行しない旨がcore/instructions.mdと整合して明記されている（#192）"
else
  fail "SKILL.md: 「未完」扱いでもウェーブ内では再試行しない旨がcore/instructions.mdと整合して明記されている（#192）"
fi

# --- #192: 「未コミットの変更がisolation worktreeに残るため次回そのまま使える」という
#     事実に反する根拠が無く、代わりに新しいworktreeが作られ引き継がれない事実が明記されている ---
if grep -Fq 'そのまま使える' "$DOC138_SKILL"; then
  fail "SKILL.md: 事実に反する根拠（未コミットの変更が次回そのまま使える）が無い（#192）" \
    "$(grep -n 'そのまま使える' "$DOC138_SKILL")"
else
  pass "SKILL.md: 事実に反する根拠（未コミットの変更が次回そのまま使える）が無い（#192）"
fi

if grep -Fq '引き継ぐ機構は存在しない' "$DOC138_SKILL"; then
  pass "SKILL.md: 未コミットの変更が次ウェーブへ引き継がれない事実が明記されている（#192）"
else
  fail "SKILL.md: 未コミットの変更が次ウェーブへ引き継がれない事実が明記されている（#192）"
fi

# --- #192: 「未完」の区別が、run が実際に実行できる手順（次ウェーブ再割当て時の
#     generatorへの再指示に一言添える）として書かれていることを確認する ---
if grep -Fq '#138' "$DOC138_SKILL" && grep -Fq 'Step 3 のプロンプトに' "$DOC138_SKILL" && grep -Fq '一文を追加する' "$DOC138_SKILL"; then
  pass "SKILL.md: 「未完」の区別が、次ウェーブ再割当て時にgeneratorへ一言添えるという実行可能な手順として書かれている（#192）"
else
  fail "SKILL.md: 「未完」の区別が、次ウェーブ再割当て時にgeneratorへ一言添えるという実行可能な手順として書かれている（#192）"
fi

# ---------------------------------------------------------------------------
echo "== Task issueテンプレートの「- Epic: #N」行規定（レビュー#56） =="

# plan-waves.sh の load_from_gh は本文の「- Epic: #N」行で他Epicのタスクを除外する
# （行が無ければフェイルオープンで含める）。この行がどの成果物にも規定されていないと、
# テンプレートどおりに作った Task issue が別Epicの実行中にウェーブ計画へ混入する
# （#39 の再発）。テンプレート・役割定義側に規定があることを固定する。

DOC56_EPIC_SKILL="${REPO_ROOT}/skills/epic/SKILL.md"
DOC56_PLANNER_ROLE="${REPO_ROOT}/core/roles/planner.md"
DOC56_PLAN_SKILL="${REPO_ROOT}/skills/plan/SKILL.md"
DOC56_CODEX_PLAN_SKILL="${REPO_ROOT}/skills-codex/dev-workflow-plan/SKILL.md"
DOC56_PLAN_WAVES="${REPO_ROOT}/scripts/plan-waves.sh"
DOC56_AGENT_PLANNER="${REPO_ROOT}/agents/planner.md"
DOC56_CODEX_AGENT_PLANNER="${REPO_ROOT}/codex-agents/planner.toml"

if grep -Fq -e '- Epic: #[epic番号]' "$DOC56_EPIC_SKILL"; then
  pass "skills/epic/SKILL.md: Task issue本文テンプレートに「- Epic: #[epic番号]」行がある（#56）"
else
  fail "skills/epic/SKILL.md: Task issue本文テンプレートに「- Epic: #[epic番号]」行がある（#56）"
fi

if grep -Fq '`- Epic: #N`' "$DOC56_PLANNER_ROLE"; then
  pass "core/roles/planner.md: 依存宣言の節に「- Epic: #N」の必須化が明記されている（#56）"
else
  fail "core/roles/planner.md: 依存宣言の節に「- Epic: #N」の必須化が明記されている（#56）"
fi

if grep -Fq '`- Epic: #N`' "$DOC56_PLAN_SKILL"; then
  pass "skills/plan/SKILL.md: Task issue要件に「- Epic: #N」が明記されている（#56）"
else
  fail "skills/plan/SKILL.md: Task issue要件に「- Epic: #N」が明記されている（#56）"
fi

if grep -Fq '`- Epic: #N`' "$DOC56_CODEX_PLAN_SKILL"; then
  pass "skills-codex/dev-workflow-plan/SKILL.md: Task issue要件に「- Epic: #N」が明記されている（#56）"
else
  fail "skills-codex/dev-workflow-plan/SKILL.md: Task issue要件に「- Epic: #N」が明記されている（#56）"
fi

if grep -Fq 'skills/epic/SKILL.md' "$DOC56_PLAN_WAVES" && grep -Fq 'Task issue テンプレート' "$DOC56_PLAN_WAVES"; then
  pass "scripts/plan-waves.sh: ヘッダコメントが「- Epic:」行の出所をskills/epic/SKILL.mdに正しく記載している（#56）"
else
  fail "scripts/plan-waves.sh: ヘッダコメントが「- Epic:」行の出所をskills/epic/SKILL.mdに正しく記載している（#56）"
fi

# core/roles/planner.md の追記は adapters/*/build.sh の再生成対象であるため、
# 生成物側にも同じ記述が反映されていることを固定する（生成漏れの検出）。
if [ -f "$DOC56_AGENT_PLANNER" ] && grep -Fq '`- Epic: #N`' "$DOC56_AGENT_PLANNER"; then
  pass "agents/planner.md: 正本（core/roles/planner.md）の「- Epic: #N」追記内容が反映されている（#56）"
else
  fail "agents/planner.md: 正本（core/roles/planner.md）の「- Epic: #N」追記内容が反映されている（#56）" \
    "見つかりません: ${DOC56_AGENT_PLANNER}"
fi

if [ -f "$DOC56_CODEX_AGENT_PLANNER" ] && grep -Fq '`- Epic: #N`' "$DOC56_CODEX_AGENT_PLANNER"; then
  pass "codex-agents/planner.toml: 正本の「- Epic: #N」追記内容が反映されている（#56）"
else
  fail "codex-agents/planner.toml: 正本の「- Epic: #N」追記内容が反映されている（#56）" \
    "見つかりません: ${DOC56_CODEX_AGENT_PLANNER}"
fi

# ---------------------------------------------------------------------------
echo "== DEV_WORKFLOW_TEST_CMD の必須化がREADME/ガイドに反映されている（レビュー#57） =="

# adapters/codex/run-loop.sh は DEV_WORKFLOW_TEST_CMD が未設定なら exit 1 する（#37対応）。
# この必須化が利用者向けドキュメントに反映されていないと、ドキュメントどおりに起動した
# 利用者が原因不明の停止に見える形で失敗する。

DOC57_README="${REPO_ROOT}/README.md"
DOC57_GUIDE="${REPO_ROOT}/docs/dev-workflow-multi-vendor-guide.md"
DOC57_RUN_LOOP="${REPO_ROOT}/adapters/codex/run-loop.sh"

# run-loop.sh の必須チェックが実在し、「DRY_RUNならcodex起動をスキップする」分岐より前に
# あることをまず固定する（ドキュメントの「DRY_RUNでも必須」という説明が実装と食い違わない
# ようにするため）。L72 の `[ "$DRY_RUN" = "1" ] || need codex` は codex コマンドの存在確認を
# 条件分岐しているだけで「スキップして確認だけする」分岐ではないため対象外とし、
# 実際に処理をスキップする `if [ "$DRY_RUN" = "1" ]; then` ブロックの初出を基準にする。
DOC57_RUN_LOOP_REQUIRED_LINE="$(grep -n 'DEV_WORKFLOW_TEST_CMD が未設定です' "$DOC57_RUN_LOOP" | head -1 | cut -d: -f1)"
DOC57_RUN_LOOP_DRY_RUN_LINE="$(grep -n 'if \[ "\$DRY_RUN" = "1" \]; then' "$DOC57_RUN_LOOP" | head -1 | cut -d: -f1)"

if [ -n "$DOC57_RUN_LOOP_REQUIRED_LINE" ] && [ -n "$DOC57_RUN_LOOP_DRY_RUN_LINE" ] \
  && [ "$DOC57_RUN_LOOP_REQUIRED_LINE" -lt "$DOC57_RUN_LOOP_DRY_RUN_LINE" ]; then
  pass "adapters/codex/run-loop.sh: DEV_WORKFLOW_TEST_CMD必須チェック（L${DOC57_RUN_LOOP_REQUIRED_LINE}）がDRY_RUN分岐（L${DOC57_RUN_LOOP_DRY_RUN_LINE}）より前にある（#57）"
else
  fail "adapters/codex/run-loop.sh: DEV_WORKFLOW_TEST_CMD必須チェックがDRY_RUN分岐より前にある（#57）" \
    "required_line=${DOC57_RUN_LOOP_REQUIRED_LINE:-なし} dry_run_line=${DOC57_RUN_LOOP_DRY_RUN_LINE:-なし}"
fi

if grep -Fq 'DEV_WORKFLOW_TEST_CMD=' "$DOC57_README" && grep -Fq 'run-loop.sh' "$DOC57_README"; then
  pass "README.md: 「無人で回す」のコマンド例にDEV_WORKFLOW_TEST_CMDが含まれる（#57）"
else
  fail "README.md: 「無人で回す」のコマンド例にDEV_WORKFLOW_TEST_CMDが含まれる（#57）"
fi

if grep -Fq '必須' "$DOC57_README" && grep -Fq 'DEV_WORKFLOW_TEST_CMD' "$DOC57_README"; then
  pass "README.md: DEV_WORKFLOW_TEST_CMDが必須である旨の説明がある（#57）"
else
  fail "README.md: DEV_WORKFLOW_TEST_CMDが必須である旨の説明がある（#57）"
fi

if grep -Fq 'DRY_RUN より前に走るため' "$DOC57_README"; then
  pass "README.md: DRY_RUNの案内にもDEV_WORKFLOW_TEST_CMDが必要である旨が明記されている（#57）"
else
  fail "README.md: DRY_RUNの案内にもDEV_WORKFLOW_TEST_CMDが必要である旨が明記されている（#57）"
fi

if grep -Fq 'DEV_WORKFLOW_TEST_CMD=' "$DOC57_GUIDE" && grep -Fq 'run-loop.sh' "$DOC57_GUIDE"; then
  pass "docs/dev-workflow-multi-vendor-guide.md: 「完全無人で回す場合」のコマンド例にDEV_WORKFLOW_TEST_CMDが含まれる（#57）"
else
  fail "docs/dev-workflow-multi-vendor-guide.md: 「完全無人で回す場合」のコマンド例にDEV_WORKFLOW_TEST_CMDが含まれる（#57）"
fi

if grep -Fq '必須' "$DOC57_GUIDE" && grep -Fq 'DEV_WORKFLOW_TEST_CMD' "$DOC57_GUIDE"; then
  pass "docs/dev-workflow-multi-vendor-guide.md: DEV_WORKFLOW_TEST_CMDが必須である旨の説明がある（#57）"
else
  fail "docs/dev-workflow-multi-vendor-guide.md: DEV_WORKFLOW_TEST_CMDが必須である旨の説明がある（#57）"
fi

if grep -Fq 'DRY_RUN' "$DOC57_GUIDE" && grep -Fq 'DRY_RUN より前' "$DOC57_GUIDE"; then
  pass "docs/dev-workflow-multi-vendor-guide.md: DRY_RUNの案内にもDEV_WORKFLOW_TEST_CMDが必要である旨が明記されている（#57）"
else
  fail "docs/dev-workflow-multi-vendor-guide.md: DRY_RUNの案内にもDEV_WORKFLOW_TEST_CMDが必要である旨が明記されている（#57）"
fi

# ---------------------------------------------------------------------------
echo "== ponytail の7段ラダーを generator の正本に規定（#69） =="

# ponytail（DietrichGebert/ponytail, MIT）の「最も怠惰なシニア開発者のように考える」7段の判断ラダーを
# core/roles/generator.md に日本語で規定する。実装コードのみが対象でテストは対象外。
# 生成物（agents/generator.md・codex-agents/generator.toml）にも同じ文言が反映されていることを検査する。

DOC69_GENERATOR_ROLE="${REPO_ROOT}/core/roles/generator.md"
DOC69_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC69_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"

# --- core/roles/generator.md に7段のラダーが日本語で規定されている ---

if grep -Fq '7段のラダー' "$DOC69_GENERATOR_ROLE" \
  && grep -Fq 'これは存在する必要があるか？' "$DOC69_GENERATOR_ROLE" \
  && grep -Fq 'ここまで来て初めて: 動く最小限を書く' "$DOC69_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 7段のラダーが日本語で規定されている（#69）"
else
  fail "core/roles/generator.md: 7段のラダーが日本語で規定されている（#69）"
fi

# --- 「削ってはいけないもの」にテスト・回帰確認・検証が含まれている ---

if grep -Fq '削ってはいけないもの' "$DOC69_GENERATOR_ROLE" \
  && grep -Fq 'テスト・回帰確認・検証' "$DOC69_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 「削ってはいけないもの」にテスト・回帰確認・検証が含まれている（#69）"
else
  fail "core/roles/generator.md: 「削ってはいけないもの」にテスト・回帰確認・検証が含まれている（#69）"
fi

# --- 実装コードのみ対象、テストコードには適用しない旨が明記されている ---

if grep -Fq '実装コードにのみ適用する' "$DOC69_GENERATOR_ROLE" \
  && grep -Fq 'テストコードには適用しない' "$DOC69_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 「実装コードのみ対象、テストコードには適用しない」旨が明記されている（#69）"
else
  fail "core/roles/generator.md: 「実装コードのみ対象、テストコードには適用しない」旨が明記されている（#69）"
fi

# --- 出典（DietrichGebert/ponytail, MIT）が明記されている ---

if grep -Fq 'DietrichGebert/ponytail' "$DOC69_GENERATOR_ROLE" \
  && grep -Fq 'MIT License' "$DOC69_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 出典（DietrichGebert/ponytail, MIT）が明記されている（#69）"
else
  fail "core/roles/generator.md: 出典（DietrichGebert/ponytail, MIT）が明記されている（#69）"
fi

# --- 完了報告テンプレートに「作らなかったもの」の欄がある ---

if grep -Fq '作らなかったもの（ラダー判定）' "$DOC69_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 完了報告テンプレートに「作らなかったもの（ラダー判定）」の欄がある（#69）"
else
  fail "core/roles/generator.md: 完了報告テンプレートに「作らなかったもの（ラダー判定）」の欄がある（#69）"
fi

# --- 生成物（agents/generator.md・codex-agents/generator.toml）に正本の追記内容が反映されている ---

if [ -f "$DOC69_AGENT_GENERATOR" ] \
  && grep -Fq '7段のラダー' "$DOC69_AGENT_GENERATOR" \
  && grep -Fq 'DietrichGebert/ponytail' "$DOC69_AGENT_GENERATOR" \
  && grep -Fq '作らなかったもの（ラダー判定）' "$DOC69_AGENT_GENERATOR"; then
  pass "agents/generator.md: 正本（core/roles/generator.md）のponytailラダー追記内容が反映されている（#69）"
else
  fail "agents/generator.md: 正本（core/roles/generator.md）のponytailラダー追記内容が反映されている（#69）" \
    "見つかりません: ${DOC69_AGENT_GENERATOR}"
fi

if [ -f "$DOC69_CODEX_AGENT_GENERATOR" ] \
  && grep -Fq '7段のラダー' "$DOC69_CODEX_AGENT_GENERATOR" \
  && grep -Fq 'DietrichGebert/ponytail' "$DOC69_CODEX_AGENT_GENERATOR" \
  && grep -Fq '作らなかったもの（ラダー判定）' "$DOC69_CODEX_AGENT_GENERATOR"; then
  pass "codex-agents/generator.toml: 正本のponytailラダー追記内容が反映されている（#69）"
else
  fail "codex-agents/generator.toml: 正本のponytailラダー追記内容が反映されている（#69）" \
    "見つかりません: ${DOC69_CODEX_AGENT_GENERATOR}"
fi

# ---------------------------------------------------------------------------
echo "== 「過剰実装・過剰設計」をレビュー観点に追加（#70） =="

# ponytail のラダー（#69）と対になる、evaluator 側の「作らなくてよいものを作った差分」の
# 検出観点を core/roles/evaluator.md と core/instructions.md に規定する。
# core/instructions.md は agents/*.md と codex-agents/*.toml の全ファイルに反映される。

DOC70_INSTRUCTIONS="${REPO_ROOT}/core/instructions.md"
DOC70_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
DOC70_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"

# --- core/roles/evaluator.md のレビューチェックリストに「過剰実装・過剰設計」の小節がある ---
# （Task #151で core/references/review-checklist-over-engineering.md へ退避されたため、
#   平坦化ビュー EVALUATOR_ROLE_FLAT を見る）

if grep -Fq '#### 過剰実装・過剰設計' "$EVALUATOR_ROLE_FLAT"; then
  pass "core/roles/evaluator.md: レビューチェックリストに「過剰実装・過剰設計」の小節がある（#70）"
else
  fail "core/roles/evaluator.md: レビューチェックリストに「過剰実装・過剰設計」の小節がある（#70）"
fi

# --- チェックリストに「削ってはいけないものを削っていないか」の項目が含まれている ---

if grep -Fq 'テスト・回帰確認・検証・セキュリティ・データ損失の扱いを「削減」していないか' "$EVALUATOR_ROLE_FLAT"; then
  pass "core/roles/evaluator.md: 「削ってはいけないものを削っていないか」の項目が含まれている（#70）"
else
  fail "core/roles/evaluator.md: 「削ってはいけないものを削っていないか」の項目が含まれている（#70）"
fi

# --- core/instructions.md のレビュー基準に、過剰実装・過剰設計の重要度の当てはめが明記されている ---

if grep -Fq '過剰実装・過剰設計の重要度の当てはめ' "$DOC70_INSTRUCTIONS" \
  && grep -Fq '仕様・Task issue に無い機能を足している（明確な仕様逸脱） | high' "$DOC70_INSTRUCTIONS" \
  && grep -Fq '重複実装・不要な抽象化・自前実装で済ませられた標準機能の再実装 | medium' "$DOC70_INSTRUCTIONS" \
  && grep -Fq '好みの範囲の簡潔さ（1行にできた等） | low' "$DOC70_INSTRUCTIONS"; then
  pass "core/instructions.md: レビュー基準に過剰実装・過剰設計の重要度の当てはめが明記されている（#70）"
else
  fail "core/instructions.md: レビュー基準に過剰実装・過剰設計の重要度の当てはめが明記されている（#70）"
fi

# --- 生成物（agents/evaluator.md・codex-agents/evaluator.toml）に反映されている ---
# （agents/evaluator.md は core/references/*.md を束ねないため AGENT_EVALUATOR_FLAT を見る）

if [ -f "$DOC70_AGENT_EVALUATOR" ] \
  && grep -Fq '#### 過剰実装・過剰設計' "$AGENT_EVALUATOR_FLAT" \
  && grep -Fq '過剰実装・過剰設計の重要度の当てはめ' "$DOC70_AGENT_EVALUATOR"; then
  pass "agents/evaluator.md: 正本の「過剰実装・過剰設計」追記内容が反映されている（#70）"
else
  fail "agents/evaluator.md: 正本の「過剰実装・過剰設計」追記内容が反映されている（#70）" \
    "見つかりません: ${DOC70_AGENT_EVALUATOR}"
fi

if [ -f "$DOC70_CODEX_AGENT_EVALUATOR" ] \
  && grep -Fq '#### 過剰実装・過剰設計' "$CODEX_AGENT_EVALUATOR_FLAT" \
  && grep -Fq '過剰実装・過剰設計の重要度の当てはめ' "$DOC70_CODEX_AGENT_EVALUATOR"; then
  pass "codex-agents/evaluator.toml: 正本の「過剰実装・過剰設計」追記内容が反映されている（#70）"
else
  fail "codex-agents/evaluator.toml: 正本の「過剰実装・過剰設計」追記内容が反映されている（#70）" \
    "見つかりません: ${DOC70_CODEX_AGENT_EVALUATOR}"
fi

# ---------------------------------------------------------------------------
echo "== プラグイン宣言MCPの未導入時挙動を実測しdocs/optional-mcp-tools.mdに記録している（#67） =="

# Epic #66 Phase 1（#67）: MCP結線方式（方式A: 宣言方式 / 方式B: 非宣言方式）を実測して確定し、
# 後続タスク（#71 context7 / #73 code-review-graph）が同じ文書を参照できるようにする。
# 決め打ちで方式名だけ書いていないか、必須6節が揃っているかを機械的に検査する。

DOC67_MCP="${REPO_ROOT}/docs/optional-mcp-tools.md"

if [ -f "$DOC67_MCP" ]; then
  pass "docs/optional-mcp-tools.md が存在する（#67）"

  for section in "## 対象ツール" "## 実測手順" "## 実測結果" "## 採用方式" "## MCP ツール名" "## 任意依存であることの保証"; do
    if grep -Fq "$section" "$DOC67_MCP"; then
      pass "docs/optional-mcp-tools.md: 「${section}」節がある（#67）"
    else
      fail "docs/optional-mcp-tools.md: 「${section}」節がある（#67）"
    fi
  done

  DOC67_ADOPTED_SECTION="$(awk '/^## 採用方式/{flag=1; next} /^## /{flag=0} flag' "$DOC67_MCP")"
  if printf '%s' "$DOC67_ADOPTED_SECTION" | grep -Fq '方式A: 宣言方式' \
    || printf '%s' "$DOC67_ADOPTED_SECTION" | grep -Fq '方式B: 非宣言方式'; then
    pass "docs/optional-mcp-tools.md: 「## 採用方式」節に方式A/Bいずれかが明記されている（#67）"
  else
    fail "docs/optional-mcp-tools.md: 「## 採用方式」節に方式A/Bいずれかが明記されている（#67）"
  fi
else
  fail "docs/optional-mcp-tools.md が存在する（#67）"
  skip "docs/optional-mcp-tools.md: 必須節の検査（#67）" "ファイルが存在しないためスキップ"
  skip "docs/optional-mcp-tools.md: 採用方式の検査（#67）" "ファイルが存在しないためスキップ"
fi

# ---------------------------------------------------------------------------
echo "== code-review-graph を evaluator にのみ結線する（#73） =="

# Epic #66 Phase 4（#73）: #67で確定した方式Aに従い、code-review-graphをevaluatorにのみ結線する。
# planner/generatorには一切現れないこと、未導入でも壊れないこと（.gitignore）、
# plugin.jsonが変更後もJSONとして妥当であることを機械的に検査する。

DOC73_CLAUDE_PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"
DOC73_GITIGNORE="${REPO_ROOT}/.gitignore"
DOC73_EVALUATOR_ROLE="${REPO_ROOT}/core/roles/evaluator.md"
DOC73_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
DOC73_AGENT_PLANNER="${REPO_ROOT}/agents/planner.md"
DOC73_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC73_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"
DOC73_CODEX_AGENT_PLANNER="${REPO_ROOT}/codex-agents/planner.toml"
DOC73_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"

# --- .claude-plugin/plugin.json に code-review-graph の mcpServers エントリがある ---

if grep -Fq '"code-review-graph"' "$DOC73_CLAUDE_PLUGIN_JSON" \
  && grep -Fq '"command": "code-review-graph"' "$DOC73_CLAUDE_PLUGIN_JSON"; then
  pass ".claude-plugin/plugin.json: mcpServers に code-review-graph のエントリがある（#73）"
else
  fail ".claude-plugin/plugin.json: mcpServers に code-review-graph のエントリがある（#73）"
fi

# --- .claude-plugin/plugin.json が変更後もJSONとして妥当（既存の _hj_json_syntax_ok を再利用） ---

if _hj_json_syntax_ok "$DOC73_CLAUDE_PLUGIN_JSON"; then
  pass ".claude-plugin/plugin.json: 構文として妥当（括弧の対応が取れている）（#73）"
else
  fail ".claude-plugin/plugin.json: 構文として妥当（括弧の対応が取れている）（#73）" \
    "$(cat "$DOC73_CLAUDE_PLUGIN_JSON" 2>&1)"
fi

# --- .gitignore に .code-review-graph/ が追加されている ---

if grep -Fq '.code-review-graph/' "$DOC73_GITIGNORE"; then
  pass ".gitignore: .code-review-graph/ が追加されている（#73）"
else
  fail ".gitignore: .code-review-graph/ が追加されている（#73）"
fi

# --- core/roles/evaluator.md に「任意ツール: code-review-graph」節がある ---

if grep -Fq '## 任意ツール: code-review-graph' "$DOC73_EVALUATOR_ROLE" \
  && grep -Fq 'ツールがあれば使う。無ければ従来どおり' "$DOC73_EVALUATOR_ROLE" \
  && grep -Fq '発火しない' "$DOC73_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 「任意ツール: code-review-graph」節がある（#73）"
else
  fail "core/roles/evaluator.md: 「任意ツール: code-review-graph」節がある（#73）"
fi

# --- 生成物（agents/evaluator.md・codex-agents/evaluator.toml）に反映されている ---

if [ -f "$DOC73_AGENT_EVALUATOR" ] \
  && grep -Fq 'mcp__plugin_dev-workflow_code-review-graph' "$DOC73_AGENT_EVALUATOR" \
  && grep -Fq '## 任意ツール: code-review-graph' "$DOC73_AGENT_EVALUATOR"; then
  pass "agents/evaluator.md: 正本の code-review-graph 結線内容が反映されている（#73）"
else
  fail "agents/evaluator.md: 正本の code-review-graph 結線内容が反映されている（#73）" \
    "見つかりません: ${DOC73_AGENT_EVALUATOR}"
fi

if [ -f "$DOC73_CODEX_AGENT_EVALUATOR" ] \
  && grep -Fq '[mcp_servers.code-review-graph]' "$DOC73_CODEX_AGENT_EVALUATOR" \
  && grep -Fq '## 任意ツール: code-review-graph' "$DOC73_CODEX_AGENT_EVALUATOR"; then
  pass "codex-agents/evaluator.toml: 正本の code-review-graph 結線内容が反映されている（#73）"
else
  fail "codex-agents/evaluator.toml: 正本の code-review-graph 結線内容が反映されている（#73）" \
    "見つかりません: ${DOC73_CODEX_AGENT_EVALUATOR}"
fi

# --- code-review-graph（MCPツール）が evaluator にのみ与えられている（generatorには現れない） ---
# planner.md/toml は #75 で「## 準備コマンド」の例としてCLIコマンド `code-review-graph build`
# を書く（MCPツールの結線ではない）ため、この2ファイルは対象から除外し、MCPツール結線の
# 有無（mcp__plugin_..._code-review-graph という文字列）だけを別途チェックする。

for f in "$DOC73_AGENT_GENERATOR" "$DOC73_CODEX_AGENT_GENERATOR"; do
  rel="${f#"${REPO_ROOT}/"}"
  if [ -f "$f" ]; then
    if grep -Fq 'code-review-graph' "$f"; then
      fail "${rel}: code-review-graph が現れない（evaluator専用であること）（#73）" \
        "$(grep -Fn 'code-review-graph' "$f")"
    else
      pass "${rel}: code-review-graph が現れない（evaluator専用であること）（#73）"
    fi
  else
    fail "${rel}: code-review-graph が現れない（evaluator専用であること）（#73）" "見つかりません: ${f}"
  fi
done

# --- planner.md/toml には code-review-graph の「MCPツール結線」が現れない
#     （#75 の準備コマンド例としての言及 `code-review-graph build` は許容する） ---

for f in "$DOC73_AGENT_PLANNER" "$DOC73_CODEX_AGENT_PLANNER"; do
  rel="${f#"${REPO_ROOT}/"}"
  if [ -f "$f" ]; then
    if grep -Fq 'mcp__plugin_dev-workflow_code-review-graph' "$f" \
      || grep -Fq '[mcp_servers.code-review-graph]' "$f"; then
      fail "${rel}: code-review-graph のMCPツール結線が現れない（evaluator専用であること）（#73/#75）" \
        "$(grep -Fn 'code-review-graph' "$f")"
    else
      pass "${rel}: code-review-graph のMCPツール結線が現れない（evaluator専用であること）（#73/#75）"
    fi
  else
    fail "${rel}: code-review-graph のMCPツール結線が現れない（evaluator専用であること）（#73/#75）" "見つかりません: ${f}"
  fi
done

# ---------------------------------------------------------------------------
echo "== context7 を generator にのみ結線している（#71） =="

# Epic #66 Phase 3（#71）: #67 で確定した方式A（宣言方式）でcontext7を結線し、
# generatorにのみ与える（決定6）。planner / evaluatorには一切現れないことを検査する。
# Codex側はサーバー単位でしか絞れないため、絞り込み方式そのものは異なるが（詳細は
# docs/optional-mcp-tools.md「Phase 3（#71）」節）、結果として「generatorにのみ与える」ことは
# 両CLIで一致していることを検査する。

DOC71_CLAUDE_PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"
DOC71_CODEX_PLUGIN_JSON="${REPO_ROOT}/.codex-plugin/plugin.json"
DOC71_MCP_DOC="${REPO_ROOT}/docs/optional-mcp-tools.md"
DOC71_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC71_AGENT_PLANNER="${REPO_ROOT}/agents/planner.md"
DOC71_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
DOC71_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"
DOC71_CODEX_AGENT_PLANNER="${REPO_ROOT}/codex-agents/planner.toml"
DOC71_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"

# --- .claude-plugin/plugin.json が方式Aどおりcontext7を宣言しており、変更後もJSONとして妥当 ---

if _hj_json_syntax_ok "$DOC71_CLAUDE_PLUGIN_JSON"; then
  pass ".claude-plugin/plugin.json: 変更後もJSON構文として妥当（括弧の対応が取れている）（#71）"
else
  fail ".claude-plugin/plugin.json: 変更後もJSON構文として妥当（括弧の対応が取れている）（#71）" \
    "$(cat "$DOC71_CLAUDE_PLUGIN_JSON" 2>&1)"
fi

if grep -Fq '"mcpServers"' "$DOC71_CLAUDE_PLUGIN_JSON" && grep -Fq '"context7"' "$DOC71_CLAUDE_PLUGIN_JSON"; then
  pass ".claude-plugin/plugin.json: mcpServersにcontext7が宣言されている（方式A）（#71）"
else
  fail ".claude-plugin/plugin.json: mcpServersにcontext7が宣言されている（方式A）（#71）"
fi

# --- context7のツールがgeneratorにのみ与えられている（Claude Code版） ---

if grep -Fq 'mcp__plugin_dev-workflow_context7__resolve-library-id' "$DOC71_AGENT_GENERATOR" \
  && grep -Fq 'mcp__plugin_dev-workflow_context7__query-docs' "$DOC71_AGENT_GENERATOR"; then
  pass "agents/generator.md: context7の2ツール（resolve-library-id / query-docs）がtools:にある（#71）"
else
  fail "agents/generator.md: context7の2ツール（resolve-library-id / query-docs）がtools:にある（#71）" \
    "見つかりません: ${DOC71_AGENT_GENERATOR}"
fi

for f in "$DOC71_AGENT_PLANNER" "$DOC71_AGENT_EVALUATOR"; do
  label="agents/$(basename "$f")"
  if grep -Fq 'context7' "$f"; then
    fail "${label}: context7が現れない（#71）" "見つかりました: ${f}"
  else
    pass "${label}: context7が現れない（#71）"
  fi
done

# --- context7のツールがgeneratorにのみ与えられている（Codex版） ---

if grep -Fq 'mcp_servers.context7' "$DOC71_CODEX_AGENT_GENERATOR"; then
  pass "codex-agents/generator.toml: mcp_servers.context7が宣言されている（#71）"
else
  fail "codex-agents/generator.toml: mcp_servers.context7が宣言されている（#71）" \
    "見つかりません: ${DOC71_CODEX_AGENT_GENERATOR}"
fi

for f in "$DOC71_CODEX_AGENT_PLANNER" "$DOC71_CODEX_AGENT_EVALUATOR"; do
  label="codex-agents/$(basename "$f")"
  if grep -Fq 'context7' "$f"; then
    fail "${label}: context7が現れない（#71）" "見つかりました: ${f}"
  else
    pass "${label}: context7が現れない（#71）"
  fi
done

# --- .codex-plugin/plugin.json にはcontext7を宣言しない（宣言すると全サブエージェントに継承されるため） ---

if grep -Fq 'context7' "$DOC71_CODEX_PLUGIN_JSON"; then
  fail ".codex-plugin/plugin.json: context7を宣言していない（宣言するとplanner/evaluatorにも継承されるため）（#71）"
else
  pass ".codex-plugin/plugin.json: context7を宣言していない（宣言するとplanner/evaluatorにも継承されるため）（#71）"
fi

# --- Claude/Codex間の機能差が無い（同等にできない場合はdocsに理由が明記されている） ---

if grep -Fq '## Phase 3（#71）' "$DOC71_MCP_DOC" \
  && grep -Fq 'Codex にはサブエージェント単位でMCPの「ツール名」を絞り込む機構が無い' "$DOC71_MCP_DOC"; then
  pass "docs/optional-mcp-tools.md: Codex側で同等にできない理由と回避策が明記されている（#71）"
else
  fail "docs/optional-mcp-tools.md: Codex側で同等にできない理由と回避策が明記されている（#71）"
fi

# ---------------------------------------------------------------------------
echo "== generator の規約に context7 の使いどころを追加（#72） =="

# #71 の結線だけではgeneratorはcontext7を使わないため、正本に「いつ使うか」を明記する。
# 完了条件の3点（推測禁止・未導入時の従来動作・ラダー2段目との優先関係）と、
# 生成物への反映を検査する。

DOC72_GENERATOR_ROLE="${REPO_ROOT}/core/roles/generator.md"
DOC72_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC72_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"

# --- 「未知のライブラリ／バージョン依存のAPIは推測で書かずcontext7で確認する」旨が明記されている ---

if grep -Fq '未知のライブラリ' "$DOC72_GENERATOR_ROLE" \
  && grep -Fq 'バージョン依存の API' "$DOC72_GENERATOR_ROLE" \
  && grep -Fq '推測で書かない' "$DOC72_GENERATOR_ROLE" \
  && grep -Fq 'context7' "$DOC72_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 未知のライブラリ／バージョン依存のAPIは推測で書かずcontext7で確認する旨が明記されている（#72）"
else
  fail "core/roles/generator.md: 未知のライブラリ／バージョン依存のAPIは推測で書かずcontext7で確認する旨が明記されている（#72）"
fi

# --- 「未導入なら従来どおり動く」旨が明記されている（必須依存として書かれていないこと） ---

if grep -Fq '未導入なら従来どおり動く' "$DOC72_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 「未導入なら従来どおり動く」旨が明記されている（#72）"
else
  fail "core/roles/generator.md: 「未導入なら従来どおり動く」旨が明記されている（#72）"
fi

if grep -Eiq 'context7[^。\n]*(必ず使う|使わなければならない|使うこと)' "$DOC72_GENERATOR_ROLE"; then
  fail "core/roles/generator.md: context7 を必須依存として書いていない（#72）" \
    "$(grep -EinB1 'context7[^。]*(必ず使う|使わなければならない|使うこと)' "$DOC72_GENERATOR_ROLE")"
else
  pass "core/roles/generator.md: context7 を必須依存として書いていない（#72）"
fi

# --- 「既にコードベースで使われている用法は既存箇所を読む方が優先」旨が明記されている（ラダー2段目との整合） ---

if grep -Fq '既存箇所を読む方が' "$DOC72_GENERATOR_ROLE" \
  && grep -Fq 'このコードベースに既にあるか？' "$DOC72_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 既存箇所を読む方が優先（ラダー2段目との整合）である旨が明記されている（#72）"
else
  fail "core/roles/generator.md: 既存箇所を読む方が優先（ラダー2段目との整合）である旨が明記されている（#72）"
fi

# --- 生成物（agents/generator.md・codex-agents/generator.toml）に正本の追記内容が反映されている ---

if [ -f "$DOC72_AGENT_GENERATOR" ] \
  && grep -Fq '未知のライブラリ' "$DOC72_AGENT_GENERATOR" \
  && grep -Fq '未導入なら従来どおり動く' "$DOC72_AGENT_GENERATOR" \
  && grep -Fq '既存箇所を読む方が' "$DOC72_AGENT_GENERATOR"; then
  pass "agents/generator.md: 正本（core/roles/generator.md）のcontext7使いどころ追記内容が反映されている（#72）"
else
  fail "agents/generator.md: 正本（core/roles/generator.md）のcontext7使いどころ追記内容が反映されている（#72）" \
    "見つかりません: ${DOC72_AGENT_GENERATOR}"
fi

if [ -f "$DOC72_CODEX_AGENT_GENERATOR" ] \
  && grep -Fq '未知のライブラリ' "$DOC72_CODEX_AGENT_GENERATOR" \
  && grep -Fq '未導入なら従来どおり動く' "$DOC72_CODEX_AGENT_GENERATOR" \
  && grep -Fq '既存箇所を読む方が' "$DOC72_CODEX_AGENT_GENERATOR"; then
  pass "codex-agents/generator.toml: 正本のcontext7使いどころ追記内容が反映されている（#72）"
else
  fail "codex-agents/generator.toml: 正本のcontext7使いどころ追記内容が反映されている（#72）" \
    "見つかりません: ${DOC72_CODEX_AGENT_GENERATOR}"
fi

echo "== generator に LSP ツールを与え、探索のターン数を減らす（#154） =="

# Epic #143（#154）: generatorのfrontmatterにLSPのMCPツールを追加し、正本
# （core/roles/generator.md）に「Grepの総当たりより先にLSPを引く」使用方針・
# 「LSP（ホスト）とsandbox-exec.sh（コンテナ）の役割分担」・「未導入なら従来どおり」を明記する。
# Codex側はLSPの同等機能が確認できていないため、宣言せず「非対応」の事実を残す。

DOC154_GENERATOR_ROLE="${REPO_ROOT}/core/roles/generator.md"
DOC154_OVERLAY_GENERATOR="${REPO_ROOT}/adapters/claude/overlays/generator.md"
DOC154_CODEX_OVERLAY_GENERATOR="${REPO_ROOT}/adapters/codex/overlays/generator.toml"
DOC154_AGENT_GENERATOR="${REPO_ROOT}/agents/generator.md"
DOC154_CODEX_AGENT_GENERATOR="${REPO_ROOT}/codex-agents/generator.toml"
DOC154_README="${REPO_ROOT}/README.md"

# --- adapters/claude/overlays/generator.md: frontmatter の tools: に LSP ツールが含まれる ---

if grep -Fq 'mcp__typescript-lsp__' "$DOC154_OVERLAY_GENERATOR" \
  && grep -Fq 'mcp__lua-lsp__' "$DOC154_OVERLAY_GENERATOR" \
  && grep -Fq 'mcp__gopls-lsp__' "$DOC154_OVERLAY_GENERATOR" \
  && grep -Fq 'mcp__rust-analyzer-lsp__' "$DOC154_OVERLAY_GENERATOR"; then
  pass "adapters/claude/overlays/generator.md: tools: に LSP ツール（typescript/lua/gopls/rust-analyzer）が含まれる（#154）"
else
  fail "adapters/claude/overlays/generator.md: tools: に LSP ツール（typescript/lua/gopls/rust-analyzer）が含まれる（#154）" \
    "見つかりません: ${DOC154_OVERLAY_GENERATOR}"
fi

# --- 生成物（agents/generator.md）にも反映されている ---

if [ -f "$DOC154_AGENT_GENERATOR" ] && grep -Fq 'mcp__typescript-lsp__' "$DOC154_AGENT_GENERATOR"; then
  pass "agents/generator.md: 正本（overlay）の LSP ツール追加が反映されている（#154）"
else
  fail "agents/generator.md: 正本（overlay）の LSP ツール追加が反映されている（#154）" \
    "見つかりません: ${DOC154_AGENT_GENERATOR}"
fi

# --- core/roles/generator.md: 「Grepの総当たりより先にLSPを引く」使用方針が書かれている ---

if grep -Fq 'LSP' "$DOC154_GENERATOR_ROLE" \
  && grep -Fq 'Grep の総当たり' "$DOC154_GENERATOR_ROLE" \
  && grep -Fq '先に' "$DOC154_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: 「Grepの総当たりより先にLSPを引く」使用方針が書かれている（#154）"
else
  fail "core/roles/generator.md: 「Grepの総当たりより先にLSPを引く」使用方針が書かれている（#154）"
fi

# --- core/roles/generator.md: 「探索はLSP（ホスト）/ビルド・テストはsandbox-exec.sh（コンテナ）」の役割分担 ---

if grep -Fq 'ホスト側' "$DOC154_GENERATOR_ROLE" \
  && grep -Eq 'sandbox-exec\.sh|Docker sandbox' "$DOC154_GENERATOR_ROLE"; then
  pass "core/roles/generator.md: LSP（ホスト）とビルド・テスト（コンテナ）の役割分担が明記されている（#154）"
else
  fail "core/roles/generator.md: LSP（ホスト）とビルド・テスト（コンテナ）の役割分担が明記されている（#154）"
fi

# --- core/roles/generator.md: LSPが使えない環境でも従来どおり動作する旨が明記されている ---

DOC154_LSP_SECTION="$(awk '/定義・参照の追跡は、Grep の総当たりより先に LSP を引く/,/^### [0-9]/' "$DOC154_GENERATOR_ROLE")"

if printf '%s' "$DOC154_LSP_SECTION" | grep -Fq '未導入なら従来どおり動く' \
  && printf '%s' "$DOC154_LSP_SECTION" | grep -Fq 'Grep' \
  && printf '%s' "$DOC154_LSP_SECTION" | grep -Fq '任意依存'; then
  pass "core/roles/generator.md: LSPが使えない環境でも従来どおり動作する旨が明記されている（#154）"
else
  fail "core/roles/generator.md: LSPが使えない環境でも従来どおり動作する旨が明記されている（#154）" \
    "section=[${DOC154_LSP_SECTION}]"
fi

# --- 生成物（agents/generator.md）にもLSP探索手順の記述が反映されている ---

if [ -f "$DOC154_AGENT_GENERATOR" ] && grep -Fq 'Grep の総当たりより先に LSP を引く' "$DOC154_AGENT_GENERATOR"; then
  pass "agents/generator.md: 正本のLSP探索手順の記述が反映されている（#154）"
else
  fail "agents/generator.md: 正本のLSP探索手順の記述が反映されている（#154）" \
    "見つかりません: ${DOC154_AGENT_GENERATOR}"
fi

# --- Codex側: 同等機能が無い事実が明記されている（推測で書かず、非対応と明記） ---

if grep -Fq 'Codex 側には同等の機能が無い' "$DOC154_CODEX_OVERLAY_GENERATOR"; then
  pass "adapters/codex/overlays/generator.toml: LSPのCodex側非対応の事実が明記されている（#154）"
else
  fail "adapters/codex/overlays/generator.toml: LSPのCodex側非対応の事実が明記されている（#154）"
fi

if [ -f "$DOC154_CODEX_AGENT_GENERATOR" ] && grep -Fq 'Codex 側には同等の機能が無い' "$DOC154_CODEX_AGENT_GENERATOR"; then
  pass "codex-agents/generator.toml: 正本のCodex非対応の記述が反映されている（#154）"
else
  fail "codex-agents/generator.toml: 正本のCodex非対応の記述が反映されている（#154）" \
    "見つかりません: ${DOC154_CODEX_AGENT_GENERATOR}"
fi

# --- Codex側にはLSPのmcp_serversを宣言していない（推測で結線しない） ---

if grep -Eq '^\[mcp_servers\.(typescript|lua|gopls|rust-analyzer)' "$DOC154_CODEX_OVERLAY_GENERATOR"; then
  fail "adapters/codex/overlays/generator.toml: 未確認のLSP mcp_serversを宣言していない（#154）" \
    "$(grep -E '^\[mcp_servers\.' "$DOC154_CODEX_OVERLAY_GENERATOR")"
else
  pass "adapters/codex/overlays/generator.toml: 未確認のLSP mcp_serversを宣言していない（#154）"
fi

# --- README.md: 利用者側の有効化方法（enabledPlugins）が「任意依存の外部ツール」節に書かれている ---

if grep -Fq 'enabledPlugins' "$DOC154_README" && grep -Fq 'treflebonbon/dotfiles' "$DOC154_README"; then
  pass "README.md: LSPの有効化方法（enabledPlugins・確認元）が明記されている（#154）"
else
  fail "README.md: LSPの有効化方法（enabledPlugins・確認元）が明記されている（#154）"
fi

# --- README.md: 「推奨settings.json」節にもenabledPluginsの例が書かれている ---

DOC154_README_SETTINGS_SECTION="$(awk '/### 推奨 settings.json/,/^### パーミッション設定/' "$DOC154_README")"

if printf '%s' "$DOC154_README_SETTINGS_SECTION" | grep -Fq 'enabledPlugins'; then
  pass "README.md: 「推奨settings.json」節にenabledPluginsの例がある（#154）"
else
  fail "README.md: 「推奨settings.json」節にenabledPluginsの例がある（#154）"
fi

# --- build.sh --check が通る（生成物の直接編集が無いことの検査） ---

DOC154_CLAUDE_BUILD_CHECK="$(bash "${REPO_ROOT}/adapters/claude/build.sh" --check 2>&1)"
DOC154_CLAUDE_BUILD_CHECK_EXIT=$?
assert_exit_code "adapters/claude/build.sh --check が通る（#154）" 0 "$DOC154_CLAUDE_BUILD_CHECK_EXIT"

DOC154_CODEX_BUILD_CHECK="$(bash "${REPO_ROOT}/adapters/codex/build.sh" --check 2>&1)"
DOC154_CODEX_BUILD_CHECK_EXIT=$?
assert_exit_code "adapters/codex/build.sh --check が通る（#154）" 0 "$DOC154_CODEX_BUILD_CHECK_EXIT"

# ---------------------------------------------------------------------------
# 役割・スキル定義が permissions.deny 常連コマンドを規定していないことの回帰テスト
# （issue #140・Epic #174 完了基準4。issue #191 で検査対象の抜けと正規表現の
# 取りこぼしを修正）
#
# `git reset --hard` / `git clean` / `git push --force`（`--force-with-lease` /
# `-f` を含む） / `git branch -D` / `rm -rf`（`-fr` / `-r -f` 等の順序違いを含む）は
# 一般的な安全設定の permissions.deny に載っている代表例（Epic #143 のウェーブ2で
# 全3レーンが `git reset --hard` の deny により着手不能になった実例。
# core/roles/generator.md「渡されたベースにHEADを合わせる」参照）。deny はプロジェクト側の
# allow で上書きできないため、役割・スキル定義がこれらを実行例として書いてしまうと
# 許可設定では原理的に救えない。**deny ルールはフラグの有無に関わらずコマンド名の
# 前方一致でブロックされるため**、dry-run（例: 旧 `git clean -nd`）であっても対象になる。
#
# 「コマンド位置」（行頭・`;`・`{`・`&&`・`||` の直後）に出現する場合だけを検出し、
# 「`git reset --hard` は使わない」のような説明文中のバッククォート表記は誤検出しない。
#
# 検査対象は手で保守されるスキル・ロール定義（生成物である agents/・codex-agents/ を含む）を
# 網羅する。`skills-codex/dev-workflow-run/SKILL.md` は adapters/codex/build.sh が生成しない
# 手保守ファイルであり、本Epic自身が `git clean` の記述を書き換えた対象のため必須（#191）。
# `core/references/` も正本の一部として含める。
# ---------------------------------------------------------------------------

echo "== 役割・スキル定義に permissions.deny 常連コマンドの規定が残っていない（issue #140） =="

DENY140_PATTERN='(^|[;{]|&&|\|\|)[[:space:]]*(git reset --hard|git clean|git branch -D|git push[^|]*(--force(-with-lease)?|[[:space:]]-f)|rm[[:space:]]+(-[rRf]{2,}|-[rR]+[[:space:]]+-f+|-f+[[:space:]]+-[rR]+))([[:space:]]|$)'

check_no_deny_common_commands() {
  # check_no_deny_common_commands <説明> <検査対象（ファイルまたはディレクトリ）>
  local desc="$1" target="$2"
  local hits
  if [ ! -e "$target" ]; then
    fail "$desc" "検査対象が存在しません: ${target}（対象消失時に無条件passしないための検査。#191）"
    return
  fi
  hits="$(grep -rnE "$DENY140_PATTERN" "$target" 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    pass "$desc"
  else
    fail "$desc" "$hits"
  fi
}

check_no_deny_common_commands "core/roles/ に deny常連コマンドの実行例が無い（#140）" "${REPO_ROOT}/core/roles"
check_no_deny_common_commands "core/instructions.md に deny常連コマンドの実行例が無い（#140）" "${REPO_ROOT}/core/instructions.md"
check_no_deny_common_commands "core/references/ に deny常連コマンドの実行例が無い（#191）" "${REPO_ROOT}/core/references"
check_no_deny_common_commands "adapters/claude/overlays/ に deny常連コマンドの実行例が無い（#140）" "${REPO_ROOT}/adapters/claude/overlays"
check_no_deny_common_commands "adapters/codex/overlays/ に deny常連コマンドの実行例が無い（#140）" "${REPO_ROOT}/adapters/codex/overlays"
check_no_deny_common_commands "skills/run/ に deny常連コマンドの実行例が無い（#140）" "${REPO_ROOT}/skills/run"
check_no_deny_common_commands "skills-codex/dev-workflow-run/ に deny常連コマンドの実行例が無い（#191）" "${REPO_ROOT}/skills-codex/dev-workflow-run"
check_no_deny_common_commands "agents/ に deny常連コマンドの実行例が無い（#140・生成物）" "${REPO_ROOT}/agents"
check_no_deny_common_commands "codex-agents/ に deny常連コマンドの実行例が無い（#140・生成物）" "${REPO_ROOT}/codex-agents"

# --- 検出パターン自体が実際の実行例に反応することを確認する
#     （正規表現の誤りで検査が常に無反応になっていないことのフィクスチャ確認。
#     #191で取りこぼしが判明した --force-with-lease / rm -fr / rm -r -f / git push -f も
#     個別に確認する） ---

DENY140_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-deny140-fixture.XXXXXX")"
cat > "${DENY140_FIXTURE_DIR}/bad-example.md" <<'EOF'
```bash
git reset --hard "$WAVE_BASE"
```
EOF
DENY140_FIXTURE_HITS="$(grep -rnE "$DENY140_PATTERN" "$DENY140_FIXTURE_DIR" 2>/dev/null || true)"
if [ -n "$DENY140_FIXTURE_HITS" ]; then
  pass "#140: 検出パターンが実際の git reset --hard 実行例に反応する（検査の前提確認）"
else
  fail "#140: 検出パターンが実際の git reset --hard 実行例に反応する（検査の前提確認）" \
    "反応しませんでした（正規表現が壊れている可能性）"
fi

DENY191_CASES_FILE="${DENY140_FIXTURE_DIR}/hit-cases-191.txt"
cat > "$DENY191_CASES_FILE" <<'EOF'
git push --force-with-lease origin x
git push -f origin x
rm -fr build
rm -r -f build
EOF
while IFS= read -r denyLine; do
  denyHit="$(printf '%s\n' "$denyLine" | grep -nE "$DENY140_PATTERN" || true)"
  if [ -n "$denyHit" ]; then
    pass "#191: 検出パターンが「${denyLine}」に反応する（取りこぼし修正の確認）"
  else
    fail "#191: 検出パターンが「${denyLine}」に反応する（取りこぼし修正の確認）" \
      "反応しませんでした"
  fi
done < "$DENY191_CASES_FILE"

# --- 「使わない」という説明文（バッククォート表記）や、置き換え後の非破壊コマンド
#     （git status --short 等）は誤検出しないことも確認する ---

cat > "${DENY140_FIXTURE_DIR}/good-example.md" <<'EOF'
**`git reset --hard`は使わない。**`git clean`もdenyの対象になりうる。
git status --short -- :/
rm -r file.txt
rm -f file.txt
EOF
DENY140_PROSE_HITS="$(grep -nE "$DENY140_PATTERN" "${DENY140_FIXTURE_DIR}/good-example.md" 2>/dev/null || true)"
if [ -z "$DENY140_PROSE_HITS" ]; then
  pass "#140: 説明文中のバッククォート表記・置き換え後の非破壊コマンドは誤検出しない"
else
  fail "#140: 説明文中のバッククォート表記・置き換え後の非破壊コマンドは誤検出しない" "$DENY140_PROSE_HITS"
fi

echo "== Epic一括レビューに「変更50ファイル超」しきい値の3分岐を入れる（#74） =="

# Epic #66 Phase 4（#74）: R1起動前の変更ファイル数しきい値を、既存の「変更50ファイル超」に
# 相乗りさせて3分岐（<=50は従来どおり / >50かつ利用可能ならblast radius / >50かつ未導入なら
# 従来どおりPhase分割）にする。新しいしきい値の軸を増やさないこと、Claude版とCodex版で
# 機能差を作らないこと（決定3）を検査する。

DOC74_RUN_SKILL="$RUN_SKILL_FLAT"
DOC74_CODEX_RUN_SKILL="${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md"

# --- skills/run/SKILL.md: 3分岐（<=50 / >50かつ利用可能 / >50かつ未導入）が記述されている ---

if grep -Fq '<= 50' "$DOC74_RUN_SKILL" \
  && grep -Fq '従来どおり' "$DOC74_RUN_SKILL" \
  && grep -Fq 'code-review-graphが利用可能' "$DOC74_RUN_SKILL" \
  && grep -Fq 'blast radius' "$DOC74_RUN_SKILL" \
  && grep -Fq 'code-review-graphが未導入' "$DOC74_RUN_SKILL"; then
  pass "skills/run/SKILL.md: 変更ファイル数50を境にした3分岐が記述されている（#74）"
else
  fail "skills/run/SKILL.md: 変更ファイル数50を境にした3分岐が記述されている（#74）"
fi

# --- skills/run/SKILL.md: 未導入ならPhase分割にフォールバックする旨が明記されている ---

if grep -Fq '未導入' "$DOC74_RUN_SKILL" && grep -Fq 'Phase単位に分割して起動する' "$DOC74_RUN_SKILL"; then
  pass "skills/run/SKILL.md: code-review-graph未導入ならPhase分割にフォールバックする旨が明記されている（#74）"
else
  fail "skills/run/SKILL.md: code-review-graph未導入ならPhase分割にフォールバックする旨が明記されている（#74）"
fi

# --- skills/run/SKILL.md: 「新しいしきい値の軸は増やさない」旨が明記され、しきい値が50のみである ---

if grep -Fq '新しいしきい値の軸は増やさず' "$DOC74_RUN_SKILL"; then
  pass "skills/run/SKILL.md: 新しいしきい値の軸を増やさない旨が明記されている（#74）"
else
  fail "skills/run/SKILL.md: 新しいしきい値の軸を増やさない旨が明記されている（#74）"
fi

DOC74_THRESHOLD_NUMBERS="$(grep -oE '[0-9]+ファイル超' "$DOC74_RUN_SKILL" | sort -u)"
if [ "$DOC74_THRESHOLD_NUMBERS" = "50ファイル超" ]; then
  pass "skills/run/SKILL.md: 「Xファイル超」しきい値が50のみである（新しい軸が増えていない）（#74）"
else
  fail "skills/run/SKILL.md: 「Xファイル超」しきい値が50のみである（新しい軸が増えていない）（#74）" \
    "検出したしきい値: ${DOC74_THRESHOLD_NUMBERS}"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: 同等の3分岐が記述されている（決定3: 機能差を作らない） ---

if grep -Fq '<= 50' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq '従来どおり' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq 'code-review-graph が利用可能' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq 'blast radius' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq 'code-review-graph が未導入' "$DOC74_CODEX_RUN_SKILL"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: 変更ファイル数50を境にした3分岐が記述されている（#74）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: 変更ファイル数50を境にした3分岐が記述されている（#74）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: 未導入ならPhase分割にフォールバックする旨が明記されている ---

if grep -Fq '未導入' "$DOC74_CODEX_RUN_SKILL" && grep -Fq 'R1 を Phase 単位に分割して起動する' "$DOC74_CODEX_RUN_SKILL"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: code-review-graph未導入ならPhase分割にフォールバックする旨が明記されている（#74）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: code-review-graph未導入ならPhase分割にフォールバックする旨が明記されている（#74）"
fi

# --- Claude版とCodex版で分岐の有無が一致している（決定3: 機能差を作らない） ---

DOC74_CLAUDE_HAS_SECTION="no"
DOC74_CODEX_HAS_SECTION="no"
grep -Fq '### レビュー粒度の調整' "$DOC74_RUN_SKILL" && DOC74_CLAUDE_HAS_SECTION="yes"
grep -Fq '### レビュー粒度の調整' "$DOC74_CODEX_RUN_SKILL" && DOC74_CODEX_HAS_SECTION="yes"

if [ "$DOC74_CLAUDE_HAS_SECTION" = "yes" ] && [ "$DOC74_CODEX_HAS_SECTION" = "yes" ]; then
  pass "skills/run/SKILL.md と skills-codex/dev-workflow-run/SKILL.md の両方に「レビュー粒度の調整」節があり分岐の有無が一致する（#74）"
else
  fail "skills/run/SKILL.md と skills-codex/dev-workflow-run/SKILL.md の両方に「レビュー粒度の調整」節があり分岐の有無が一致する（#74）" \
    "claude=${DOC74_CLAUDE_HAS_SECTION} codex=${DOC74_CODEX_HAS_SECTION}"
fi

# --- しきい値の値は既存記述と同じ50であり、Codex版側にも50以外の新しい軸が増えていない ---

DOC74_CODEX_THRESHOLD_NUMBERS="$(grep -oE '[0-9]+ファイル超' "$DOC74_CODEX_RUN_SKILL" | sort -u)"
if [ "$DOC74_CODEX_THRESHOLD_NUMBERS" = "50ファイル超" ]; then
  pass "skills-codex/dev-workflow-run/SKILL.md: 「Xファイル超」しきい値が50のみである（新しい軸が増えていない）（#74）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: 「Xファイル超」しきい値が50のみである（新しい軸が増えていない）（#74）" \
    "検出したしきい値: ${DOC74_CODEX_THRESHOLD_NUMBERS}"
fi

echo "== CHANGED_FILESのしきい値算出がベースブランチを決め打ちしない（#81） =="

# レビュー指摘 #81: 「変更50ファイル超」しきい値算出（#74）が
# `git diff --name-only master...` とベースブランチを決め打ちしていた。dev-workflowは
# 他プロジェクトを駆動するプラグインでありSKILL.mdは駆動先で実行されるテンプレートなので、
# dev-workflow自身のリポジトリ固有の値（master）を埋め込んではならない。
# また `git diff | wc -l` のパイプはgit diffの失敗を握り潰し0に化けさせるため、
# 失敗時にPhase単位分割へ安全側フォールバックできるよう終了コードを直接見る形にする。

# --- skills/run/SKILL.md: `master...` によるベースブランチ決め打ちが残っていない ---

if grep -Eq 'git diff --name-only master\.\.\.' "$DOC74_RUN_SKILL"; then
  fail "skills/run/SKILL.md: CHANGED_FILES算出がmasterブランチを決め打ちしていない（#81）" \
    "'git diff --name-only master...' が残っている"
else
  pass "skills/run/SKILL.md: CHANGED_FILES算出がmasterブランチを決め打ちしていない（#81）"
fi

# --- skills/run/SKILL.md: ベースブランチを動的に解決している（gh repo view で駆動先の実際の値を使う） ---

if grep -Fq 'gh repo view --json defaultBranchRef' "$DOC74_RUN_SKILL" \
  && grep -Fq 'BASE_BRANCH' "$DOC74_RUN_SKILL"; then
  pass "skills/run/SKILL.md: ベースブランチをgh repo viewで動的に解決している（#81）"
else
  fail "skills/run/SKILL.md: ベースブランチをgh repo viewで動的に解決している（#81）"
fi

# --- skills/run/SKILL.md: git diffをwc -lへ直接パイプしていない（失敗を握り潰さない） ---

if grep -Eq 'git diff --name-only "\$\{BASE_BRANCH\}\.\.\.\$\{EPIC_BRANCH\}" \| wc -l' "$DOC74_RUN_SKILL"; then
  fail "skills/run/SKILL.md: git diffの失敗がwc -lで握り潰されない（#81）" \
    "git diffの出力を直接wc -lにパイプしている箇所が残っている"
else
  pass "skills/run/SKILL.md: git diffの失敗がwc -lで握り潰されない（#81）"
fi

# --- skills/run/SKILL.md: git diff失敗時に「数えられなかった」旨を出しPhase分割へ倒す記述がある ---

if grep -Fq '数えられなかった' "$DOC74_RUN_SKILL" \
  && grep -Fq 'Phase単位分割にフォールバックする' "$DOC74_RUN_SKILL"; then
  pass "skills/run/SKILL.md: git diff失敗時にPhase単位分割へフォールバックする旨が明記されている（#81）"
else
  fail "skills/run/SKILL.md: git diff失敗時にPhase単位分割へフォールバックする旨が明記されている（#81）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: 同様にmaster決め打ちが残っていない（決定3: 機能差を作らない） ---

if grep -Eq 'git diff --name-only master\.\.\.' "$DOC74_CODEX_RUN_SKILL"; then
  fail "skills-codex/dev-workflow-run/SKILL.md: CHANGED_FILES算出がmasterブランチを決め打ちしていない（#81）" \
    "'git diff --name-only master...' が残っている"
else
  pass "skills-codex/dev-workflow-run/SKILL.md: CHANGED_FILES算出がmasterブランチを決め打ちしていない（#81）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: ベースブランチを動的に解決している ---

if grep -Fq 'gh repo view --json defaultBranchRef' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq 'BASE_BRANCH' "$DOC74_CODEX_RUN_SKILL"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: ベースブランチをgh repo viewで動的に解決している（#81）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: ベースブランチをgh repo viewで動的に解決している（#81）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: git diffをwc -lへ直接パイプしていない ---

if grep -Eq 'git diff --name-only "\$\{BASE_BRANCH\}\.\.\.\$\{EPIC_BRANCH\}" \| wc -l' "$DOC74_CODEX_RUN_SKILL"; then
  fail "skills-codex/dev-workflow-run/SKILL.md: git diffの失敗がwc -lで握り潰されない（#81）" \
    "git diffの出力を直接wc -lにパイプしている箇所が残っている"
else
  pass "skills-codex/dev-workflow-run/SKILL.md: git diffの失敗がwc -lで握り潰されない（#81）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: git diff失敗時のフォールバック記述がある ---

if grep -Fq '数えられなかった' "$DOC74_CODEX_RUN_SKILL" \
  && grep -Fq 'Phase 単位分割にフォールバックする' "$DOC74_CODEX_RUN_SKILL"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: git diff失敗時にPhase単位分割へフォールバックする旨が明記されている（#81）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: git diff失敗時にPhase単位分割へフォールバックする旨が明記されている（#81）"
fi

# --- 「Xファイル超」しきい値が依然として50のみである（#81の修正でしきい値の軸が増えていない） ---

DOC81_THRESHOLD_NUMBERS="$(grep -oE '[0-9]+ファイル超' "$DOC74_RUN_SKILL" | sort -u)"
if [ "$DOC81_THRESHOLD_NUMBERS" = "50ファイル超" ]; then
  pass "skills/run/SKILL.md: #81修正後も「Xファイル超」しきい値が50のみである（#81）"
else
  fail "skills/run/SKILL.md: #81修正後も「Xファイル超」しきい値が50のみである（#81）" \
    "検出したしきい値: ${DOC81_THRESHOLD_NUMBERS}"
fi

DOC81_CODEX_THRESHOLD_NUMBERS="$(grep -oE '[0-9]+ファイル超' "$DOC74_CODEX_RUN_SKILL" | sort -u)"
if [ "$DOC81_CODEX_THRESHOLD_NUMBERS" = "50ファイル超" ]; then
  pass "skills-codex/dev-workflow-run/SKILL.md: #81修正後も「Xファイル超」しきい値が50のみである（#81）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: #81修正後も「Xファイル超」しきい値が50のみである（#81）" \
    "検出したしきい値: ${DOC81_CODEX_THRESHOLD_NUMBERS}"
fi

echo "== グラフ構築をEpic開始時の準備に載せ限界を明記する（#75） =="

# Epic #66 Phase 4（#75）: code-review-graphのグラフ構築はEpic開始時に1回だけ、
# 既存の「## 準備コマンド」節（issue #23）に載せる。evaluator自身はグラフを構築しない。
# markdown + bash主体のリポジトリ（dev-workflow自身）では発火しないのが正常である旨を
# core/roles/evaluator.mdとdocs/optional-mcp-tools.mdの両方に明記する。

DOC75_EVALUATOR_ROLE="${REPO_ROOT}/core/roles/evaluator.md"
DOC75_PLANNER_ROLE="${REPO_ROOT}/core/roles/planner.md"
DOC75_OPTIONAL_MCP_DOC="${REPO_ROOT}/docs/optional-mcp-tools.md"
DOC75_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
DOC75_AGENT_PLANNER="${REPO_ROOT}/agents/planner.md"
DOC75_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"
DOC75_CODEX_AGENT_PLANNER="${REPO_ROOT}/codex-agents/planner.toml"

# --- core/roles/evaluator.md: 「epic-review かつ変更50ファイル超のときだけ使う」旨 ---

if grep -Fq 'epic-review かつ変更50ファイル超のときだけ' "$DOC75_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: epic-reviewかつ変更50ファイル超のときだけ使う旨が明記されている（#75）"
else
  fail "core/roles/evaluator.md: epic-reviewかつ変更50ファイル超のときだけ使う旨が明記されている（#75）"
fi

# --- core/roles/evaluator.md: 「evaluator自身はグラフを構築しない」旨 ---

if grep -Fq 'evaluator 自身はグラフを構築しない' "$DOC75_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: evaluator自身はグラフを構築しない旨が明記されている（#75）"
else
  fail "core/roles/evaluator.md: evaluator自身はグラフを構築しない旨が明記されている（#75）"
fi

# --- core/roles/evaluator.md: グラフの出力をそのまま指摘にしない旨 ---

if grep -Fq 'グラフの出力をそのまま指摘にしない' "$DOC75_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: グラフの出力をそのまま指摘にしない旨が明記されている（#75）"
else
  fail "core/roles/evaluator.md: グラフの出力をそのまま指摘にしない旨が明記されている（#75）"
fi

# --- core/roles/evaluator.md と docs/optional-mcp-tools.md の両方に
#     「markdown + bash 主体のリポジトリ...発火しないのが正常」の限界が明記されている ---

if grep -Fq 'markdown + bash 主体のリポジトリ' "$DOC75_EVALUATOR_ROLE" \
  && grep -Fq '発火しないのが正常' "$DOC75_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: markdown + bash主体のリポジトリでは発火しないのが正常という限界が明記されている（#75）"
else
  fail "core/roles/evaluator.md: markdown + bash主体のリポジトリでは発火しないのが正常という限界が明記されている（#75）"
fi

if grep -Fq 'markdown + bash 主体のリポジトリ' "$DOC75_OPTIONAL_MCP_DOC" \
  && grep -Fq '発火しないのが正常' "$DOC75_OPTIONAL_MCP_DOC"; then
  pass "docs/optional-mcp-tools.md: markdown + bash主体のリポジトリでは発火しないのが正常という限界が明記されている（#75）"
else
  fail "docs/optional-mcp-tools.md: markdown + bash主体のリポジトリでは発火しないのが正常という限界が明記されている（#75）"
fi

# --- core/roles/planner.md: 「## 準備コマンド」の説明にグラフ構築コマンドの例が追加されている ---

if grep -Fq 'グラフ構築コマンド' "$DOC75_PLANNER_ROLE" \
  && grep -Fq 'code-review-graph build' "$DOC75_PLANNER_ROLE"; then
  pass "core/roles/planner.md: 準備コマンド節の説明にグラフ構築コマンドの例が追加されている（#75）"
else
  fail "core/roles/planner.md: 準備コマンド節の説明にグラフ構築コマンドの例が追加されている（#75）"
fi

# --- docs/optional-mcp-tools.md: グラフ構築はEpic開始時に1回・evaluatorは構築しない旨 ---

if grep -Fq '## 準備コマンド' "$DOC75_OPTIONAL_MCP_DOC" \
  && grep -Fq 'evaluator 自身はグラフを構築しない' "$DOC75_OPTIONAL_MCP_DOC"; then
  pass "docs/optional-mcp-tools.md: グラフ構築は準備コマンド節に載せevaluatorは構築しない旨が明記されている（#75）"
else
  fail "docs/optional-mcp-tools.md: グラフ構築は準備コマンド節に載せevaluatorは構築しない旨が明記されている（#75）"
fi

# --- 生成物: agents/evaluator.md に正本の内容が反映されている ---

if [ -f "$DOC75_AGENT_EVALUATOR" ] \
  && grep -Fq 'epic-review かつ変更50ファイル超のときだけ' "$DOC75_AGENT_EVALUATOR" \
  && grep -Fq 'evaluator 自身はグラフを構築しない' "$DOC75_AGENT_EVALUATOR" \
  && grep -Fq 'markdown + bash 主体のリポジトリ' "$DOC75_AGENT_EVALUATOR"; then
  pass "agents/evaluator.md: 正本のグラフ構築・限界の記述内容が反映されている（#75）"
else
  fail "agents/evaluator.md: 正本のグラフ構築・限界の記述内容が反映されている（#75）" \
    "見つかりません: ${DOC75_AGENT_EVALUATOR}"
fi

# --- 生成物: agents/planner.md に正本の内容が反映されている ---

if [ -f "$DOC75_AGENT_PLANNER" ] \
  && grep -Fq 'グラフ構築コマンド' "$DOC75_AGENT_PLANNER" \
  && grep -Fq 'code-review-graph build' "$DOC75_AGENT_PLANNER"; then
  pass "agents/planner.md: 正本のグラフ構築コマンド例が反映されている（#75）"
else
  fail "agents/planner.md: 正本のグラフ構築コマンド例が反映されている（#75）" \
    "見つかりません: ${DOC75_AGENT_PLANNER}"
fi

# --- 生成物: codex-agents/evaluator.toml に正本の内容が反映されている ---

if [ -f "$DOC75_CODEX_AGENT_EVALUATOR" ] \
  && grep -Fq 'epic-review かつ変更50ファイル超のときだけ' "$DOC75_CODEX_AGENT_EVALUATOR" \
  && grep -Fq 'evaluator 自身はグラフを構築しない' "$DOC75_CODEX_AGENT_EVALUATOR" \
  && grep -Fq 'markdown + bash 主体のリポジトリ' "$DOC75_CODEX_AGENT_EVALUATOR"; then
  pass "codex-agents/evaluator.toml: 正本のグラフ構築・限界の記述内容が反映されている（#75）"
else
  fail "codex-agents/evaluator.toml: 正本のグラフ構築・限界の記述内容が反映されている（#75）" \
    "見つかりません: ${DOC75_CODEX_AGENT_EVALUATOR}"
fi

# --- 生成物: codex-agents/planner.toml に正本の内容が反映されている ---

if [ -f "$DOC75_CODEX_AGENT_PLANNER" ] \
  && grep -Fq 'グラフ構築コマンド' "$DOC75_CODEX_AGENT_PLANNER" \
  && grep -Fq 'code-review-graph build' "$DOC75_CODEX_AGENT_PLANNER"; then
  pass "codex-agents/planner.toml: 正本のグラフ構築コマンド例が反映されている（#75）"
else
  fail "codex-agents/planner.toml: 正本のグラフ構築コマンド例が反映されている（#75）" \
    "見つかりません: ${DOC75_CODEX_AGENT_PLANNER}"
fi

# ---------------------------------------------------------------------------
echo "== scripts/record-agent-tokens.sh（サブエージェントのトークン消費記録・集計。#76） =="
# ---------------------------------------------------------------------------

# Epic #66 Phase 5（#76）: 導入前後のサブエージェントトークン消費を記録・集計する仕組み。
# jq等の追加依存を使わず素のbashで完結すること、記録先が git 管理外であること、
# 不正入力は明快なエラーで非0終了することを検査する。

RAT_SCRIPT="${REPO_ROOT}/scripts/record-agent-tokens.sh"
RAT_TESTDIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-agent-tokens.XXXXXX")"
RAT_FILE="${RAT_TESTDIR}/agent-tokens.tsv"

# --- 静的検査: jq等の追加依存を呼んでいない（コメント行は対象外。単語境界での一致のみ見る） ---

RAT_FORBIDDEN_HITS="$(grep -v '^[[:space:]]*#' "$RAT_SCRIPT" \
  | grep -E '(^|[^A-Za-z0-9_])jq([^A-Za-z0-9_]|$)' || true)"
if [ -z "$RAT_FORBIDDEN_HITS" ]; then
  pass "record-agent-tokens.sh: スクリプト本体が jq を呼んでいない（#76）"
else
  fail "record-agent-tokens.sh: スクリプト本体が jq を呼んでいない（#76）" "$RAT_FORBIDDEN_HITS"
fi

# --- record: 追記した内容がTSVとして読み戻せる（6列） ---

RAT_RECORD_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role generator --mode "タスク実装" --tokens 90000 --note "dryrun" 2>&1)"
RAT_RECORD_EXIT=$?
assert_exit_code "record-agent-tokens.sh record: 正常入力は exit 0（#76）" 0 "$RAT_RECORD_EXIT"

if [ -f "$RAT_FILE" ]; then
  RAT_LINE="$(tail -n 1 "$RAT_FILE")"
  RAT_COL_COUNT="$(printf '%s' "$RAT_LINE" | awk -F'\t' '{print NF}')"
  assert_eq "record-agent-tokens.sh record: TSVが6列で書かれる（#76）" "6" "$RAT_COL_COUNT"

  RAT_EPIC_COL="$(printf '%s' "$RAT_LINE" | cut -f2)"
  RAT_ROLE_COL="$(printf '%s' "$RAT_LINE" | cut -f3)"
  RAT_MODE_COL="$(printf '%s' "$RAT_LINE" | cut -f4)"
  RAT_TOKENS_COL="$(printf '%s' "$RAT_LINE" | cut -f5)"
  RAT_NOTE_COL="$(printf '%s' "$RAT_LINE" | cut -f6)"
  if [ "$RAT_EPIC_COL" = "76" ] && [ "$RAT_ROLE_COL" = "generator" ] \
    && [ "$RAT_MODE_COL" = "タスク実装" ] && [ "$RAT_TOKENS_COL" = "90000" ] \
    && [ "$RAT_NOTE_COL" = "dryrun" ]; then
    pass "record-agent-tokens.sh record: 各列の値が正しく読み戻せる（#76）"
  else
    fail "record-agent-tokens.sh record: 各列の値が正しく読み戻せる（#76）" \
      "epic=${RAT_EPIC_COL} role=${RAT_ROLE_COL} mode=${RAT_MODE_COL} tokens=${RAT_TOKENS_COL} note=${RAT_NOTE_COL}"
  fi
else
  fail "record-agent-tokens.sh record: TSVが6列で書かれる（#76）" "${RAT_FILE} が作られていません"
  fail "record-agent-tokens.sh record: 各列の値が正しく読み戻せる（#76）" "${RAT_FILE} が作られていません"
fi

# --- record: --note を省略しても6列で書かれる（noteは空文字列） ---

DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role evaluator --mode "epic-review" --tokens 139000 >/dev/null 2>&1
RAT_LINE2="$(tail -n 1 "$RAT_FILE")"
RAT_COL_COUNT2="$(printf '%s' "$RAT_LINE2" | awk -F'\t' '{print NF}')"
assert_eq "record-agent-tokens.sh record: --note省略時も6列で書かれる（#76）" "6" "$RAT_COL_COUNT2"

# --- record: 複数レコードを追記できる（1行1レコード。追記であって上書きではない） ---

RAT_TOTAL_LINES="$(wc -l < "$RAT_FILE" | tr -d ' ')"
assert_eq "record-agent-tokens.sh record: 1行1レコードで追記される（#76）" "2" "$RAT_TOTAL_LINES"

# --- --summary: role・modeごとの件数・合計・平均を出力する ---

DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role generator --mode "タスク実装" --tokens 150000 >/dev/null 2>&1
RAT_SUMMARY_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" bash "$RAT_SCRIPT" --summary --epic 76 2>&1)"
RAT_SUMMARY_EXIT=$?
assert_exit_code "record-agent-tokens.sh --summary: exit 0（#76）" 0 "$RAT_SUMMARY_EXIT"

if printf '%s' "$RAT_SUMMARY_OUT" | grep -Fq "generator" \
  && printf '%s' "$RAT_SUMMARY_OUT" | grep -Fq "240000" \
  && printf '%s' "$RAT_SUMMARY_OUT" | grep -Fq "120000" \
  && printf '%s' "$RAT_SUMMARY_OUT" | grep -Fq "evaluator" \
  && printf '%s' "$RAT_SUMMARY_OUT" | grep -Fq "139000"; then
  pass "record-agent-tokens.sh --summary: role・modeごとの件数・合計・平均を出力する（#76）"
else
  fail "record-agent-tokens.sh --summary: role・modeごとの件数・合計・平均を出力する（#76）" "$RAT_SUMMARY_OUT"
fi

# --- --summary: 他のEpicのレコードは集計に混ざらない ---

RAT_OTHER_EPIC_FILE="${RAT_TESTDIR}/agent-tokens-other.tsv"
DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_OTHER_EPIC_FILE" \
  bash "$RAT_SCRIPT" record --epic 999 --role generator --mode "タスク実装" --tokens 1 >/dev/null 2>&1
RAT_ISOLATION_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_OTHER_EPIC_FILE" bash "$RAT_SCRIPT" --summary --epic 76 2>&1)"
if printf '%s' "$RAT_ISOLATION_OUT" | grep -Fq "記録が0件です"; then
  pass "record-agent-tokens.sh --summary: 指定Epic以外のレコードは集計対象外（#76）"
else
  fail "record-agent-tokens.sh --summary: 指定Epic以外のレコードは集計対象外（#76）" "$RAT_ISOLATION_OUT"
fi

# --- 不正入力: --tokens が数値でない場合は非0終了しエラーメッセージを出す ---

RAT_BAD_TOKENS_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role generator --mode x --tokens abc 2>&1)"
RAT_BAD_TOKENS_EXIT=$?
if [ "$RAT_BAD_TOKENS_EXIT" -ne 0 ] && printf '%s' "$RAT_BAD_TOKENS_OUT" | grep -Fq "数値"; then
  pass "record-agent-tokens.sh record: --tokensが数値でない場合は非0終了しエラーを出す（#76）"
else
  fail "record-agent-tokens.sh record: --tokensが数値でない場合は非0終了しエラーを出す（#76）" \
    "exit=${RAT_BAD_TOKENS_EXIT} out=${RAT_BAD_TOKENS_OUT}"
fi

# --- 不正入力: 必須オプション（--tokens）が欠けている場合は非0終了する ---

RAT_MISSING_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role generator --mode x 2>&1)"
RAT_MISSING_EXIT=$?
assert_exit_code "record-agent-tokens.sh record: 必須オプション欠落は非0終了する（#76）" 2 "$RAT_MISSING_EXIT"

# --- 不正入力: 末尾に値の無いオプションを置いても無限ループしない（ハングしない）（#79） ---
# bash の `shift 2` は $# が2未満のとき何もせず非0を返す。値なしでオプション名だけが
# 末尾に置かれた場合にこれを検出しないと while ループが同じ分岐を回り続けてハングする
# 不具合があった（実測: timeout 5 bash record-agent-tokens.sh record --epic 66 --role
# generator --mode impl --tokens は exit 124 だった。ただし sandbox 内の BusyBox timeout
# は exit 143 を返すため、終了コードのみでは「ハングして timeout に強制終了させられた」
# ことを判定できない。詳細は assert_no_hang 参照）。「必須オプション欠落」テスト（直上）
# はオプションを丸ごと省く形なのでこのケースを通り抜けていた。cmd_record の全オプション
# （--epic/--role/--mode/--tokens/--note）を、他は有効な値を与えたまま1つだけ末尾で
# 値なしにする形で網羅する。

if command -v timeout >/dev/null 2>&1; then
  RAT_NOVAL_OPTS=(--epic --role --mode --tokens --note)
  for RAT_NOVAL_OPT in "${RAT_NOVAL_OPTS[@]}"; do
    RAT_NOVAL_ARGS=(record)
    for RAT_OTHER_OPT in "${RAT_NOVAL_OPTS[@]}"; do
      [ "$RAT_OTHER_OPT" = "$RAT_NOVAL_OPT" ] && continue
      case "$RAT_OTHER_OPT" in
        --epic) RAT_NOVAL_ARGS+=(--epic 76) ;;
        --role) RAT_NOVAL_ARGS+=(--role generator) ;;
        --mode) RAT_NOVAL_ARGS+=(--mode x) ;;
        --tokens) RAT_NOVAL_ARGS+=(--tokens 1) ;;
        --note) RAT_NOVAL_ARGS+=(--note y) ;;
      esac
    done
    RAT_NOVAL_ARGS+=("$RAT_NOVAL_OPT")

    RAT_NOVAL_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
      timeout 5 bash "$RAT_SCRIPT" "${RAT_NOVAL_ARGS[@]}" 2>&1)"
    RAT_NOVAL_EXIT=$?

    assert_no_hang "record-agent-tokens.sh record: ${RAT_NOVAL_OPT}が末尾で値なしでも無限ループせず exit 2 かつエラーメッセージを出す（#79）" \
      2 "$RAT_NOVAL_EXIT" "$RAT_NOVAL_OUT" "${RAT_NOVAL_OPT} に値がありません"
  done

  RAT_SUMMARY_NOVAL_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
    timeout 5 bash "$RAT_SCRIPT" --summary --epic 2>&1)"
  RAT_SUMMARY_NOVAL_EXIT=$?

  assert_no_hang "record-agent-tokens.sh --summary: --epicが末尾で値なしでも無限ループせず exit 2 かつエラーメッセージを出す（#79）" \
    2 "$RAT_SUMMARY_NOVAL_EXIT" "$RAT_SUMMARY_NOVAL_OUT" "--epic に値がありません"
else
  skip "record-agent-tokens.sh: 末尾に値の無いオプションでも無限ループしない（#79）" "timeout コマンドが利用できません"
fi

# --- 不正入力: --role が想定外の値の場合は非0終了する ---

RAT_BADROLE_EXIT_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" \
  bash "$RAT_SCRIPT" record --epic 76 --role reviewer --mode x --tokens 1 2>&1)"
RAT_BADROLE_EXIT=$?
if [ "$RAT_BADROLE_EXIT" -ne 0 ]; then
  pass "record-agent-tokens.sh record: --roleが想定外の値の場合は非0終了する（#76）"
else
  fail "record-agent-tokens.sh record: --roleが想定外の値の場合は非0終了する（#76）" "$RAT_BADROLE_EXIT_OUT"
fi

# --- --summary: --epic が欠けている場合は非0終了する ---

RAT_SUMMARY_NOEPIC_EXIT_OUT="$(DEV_WORKFLOW_AGENT_TOKENS_FILE="$RAT_FILE" bash "$RAT_SCRIPT" --summary 2>&1)"
RAT_SUMMARY_NOEPIC_EXIT=$?
assert_exit_code "record-agent-tokens.sh --summary: --epic欠落は非0終了する（#76）" 2 "$RAT_SUMMARY_NOEPIC_EXIT"

# --- 不正な入力の失敗は記録先ファイルを壊さない（レコード件数が増えていない） ---

RAT_LINES_AFTER_ERRORS="$(wc -l < "$RAT_FILE" | tr -d ' ')"
assert_eq "record-agent-tokens.sh: 不正入力の失敗はファイルへの書き込みを行わない（#76）" "3" "$RAT_LINES_AFTER_ERRORS"

# --- 記録先が git 管理外であること（.gitignore で除外されている） ---
# git worktree（サンドボックスや専用worktree）内では .git ファイルがホスト側の絶対パスを
# 指しており、コンテナ内から親リポジトリを解決できない環境がある（#73のcode-review-graph
# 検査と同じ理由で `git check-ignore` は使わず、.gitignore の内容を直接検査する）。

if grep -Fq '.claude/agent-tokens.tsv' "${REPO_ROOT}/.gitignore"; then
  pass "record-agent-tokens.sh: 既定の記録先（.claude/agent-tokens.tsv）が.gitignoreで除外されている（#76）"
else
  fail "record-agent-tokens.sh: 既定の記録先（.claude/agent-tokens.tsv）が.gitignoreで除外されている（#76）"
fi

# --- run への結線: skills/run/SKILL.md と skills-codex/dev-workflow-run/SKILL.md の両方に
#     record-agent-tokens.sh の呼び出しとPR本文への集計が記述されている ---

RAT_RUN_SKILL="$RUN_SKILL_FLAT"
RAT_CODEX_RUN_SKILL="${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md"

for f in "$RAT_RUN_SKILL" "$RAT_CODEX_RUN_SKILL"; do
  name="${f#"${REPO_ROOT}"/}"
  if grep -Fq 'record-agent-tokens.sh' "$f" \
    && grep -Fq 'record-agent-tokens.sh --summary' "$f" \
    && grep -Fq 'トークン消費' "$f"; then
    pass "${name}: record-agent-tokens.shの結線とPR本文への集計が記述されている（#76）"
  else
    fail "${name}: record-agent-tokens.shの結線とPR本文への集計が記述されている（#76）"
  fi
done

# --- 呼び出し側への注記: 記録に失敗しても自律ループを止めない旨が両SKILL.mdに明記されている ---

for f in "$RAT_RUN_SKILL" "$RAT_CODEX_RUN_SKILL"; do
  name="${f#"${REPO_ROOT}"/}"
  if grep -Fq '自律ループを止めない' "$f" || grep -Fq 'ループは止めない' "$f"; then
    pass "${name}: 記録失敗が自律ループを止めない旨が明記されている（#76）"
  else
    fail "${name}: 記録失敗が自律ループを止めない旨が明記されている（#76）"
  fi
done

# --- docs/optional-mcp-tools.md: ベースライン表と「外す判断基準」が記載されている ---

RAT_DOC="${REPO_ROOT}/docs/optional-mcp-tools.md"
if grep -Fq '81k' "$RAT_DOC" && grep -Fq '150k' "$RAT_DOC" \
  && grep -Fq '83k' "$RAT_DOC" && grep -Fq '139k' "$RAT_DOC" \
  && grep -Fq 'delta-review' "$RAT_DOC" && grep -Fq 'epic-review' "$RAT_DOC"; then
  pass "docs/optional-mcp-tools.md: ベースライン表（Epic #42実測値）が記載されている（#76）"
else
  fail "docs/optional-mcp-tools.md: ベースライン表（Epic #42実測値）が記載されている（#76）"
fi

if grep -Fq '外す判断基準' "$RAT_DOC" \
  && grep -Fq 'record-agent-tokens.sh' "$RAT_DOC"; then
  pass "docs/optional-mcp-tools.md: 「外す判断基準」が明記されている（#76）"
else
  fail "docs/optional-mcp-tools.md: 「外す判断基準」が明記されている（#76）"
fi

# ---------------------------------------------------------------------------
# ドキュメント更新・v0.14.x・両アダプタ再生成（#77）
# ---------------------------------------------------------------------------

echo "== ドキュメント更新・v0.14.x・両アダプタ再生成（#77） =="

DOC77_CLAUDE_PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"
DOC77_CODEX_PLUGIN_JSON="${REPO_ROOT}/.codex-plugin/plugin.json"
DOC77_README="${REPO_ROOT}/README.md"
DOC77_GUIDE="${REPO_ROOT}/docs/dev-workflow-multi-vendor-guide.md"

# --- 両 plugin.json の version が一致している（片方だけ上がる事故の検出。値そのものは固定しない） ---

DOC77_CLAUDE_VERSION="$(grep -m1 '"version"' "$DOC77_CLAUDE_PLUGIN_JSON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
DOC77_CODEX_VERSION="$(grep -m1 '"version"' "$DOC77_CODEX_PLUGIN_JSON" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

if [ -n "$DOC77_CLAUDE_VERSION" ] && [ "$DOC77_CLAUDE_VERSION" = "$DOC77_CODEX_VERSION" ]; then
  pass ".claude-plugin/plugin.json と .codex-plugin/plugin.json の version が一致している（#77）"
else
  fail ".claude-plugin/plugin.json と .codex-plugin/plugin.json の version が一致している（#77）" \
    "claude=[${DOC77_CLAUDE_VERSION}] codex=[${DOC77_CODEX_VERSION}]"
fi

# 具体的なバージョン値の固定は #55 ブロック（.claude-plugin / .codex-plugin の version を
# 直接 assert する箇所）が担っている。ここで同じ値を二重に固定するとリリースのたびに
# 3箇所を直すことになり、実際に v0.14.1 への更新でそれを踏んだため、重複を削った。
# 本ブロックの責務は「片方だけ上がる事故の検出」（直上の一致テスト）に限る。

# --- README.md に「任意依存の外部ツール」節があり、4点（任意依存・未導入時の挙動・入れ方・外す基準）が書かれている ---

if grep -Fq '## 任意依存の外部ツール' "$DOC77_README"; then
  pass "README.md: 「任意依存の外部ツール」節がある（#77）"
else
  fail "README.md: 「任意依存の外部ツール」節がある（#77）"
fi

if grep -Fq '必須依存ではありません' "$DOC77_README"; then
  pass "README.md: 任意依存であり必須依存ではない旨が明記されている（#77）"
else
  fail "README.md: 任意依存であり必須依存ではない旨が明記されている（#77）"
fi

if grep -Fq 'context7 で確認しません' "$DOC77_README" && grep -Fq 'blast radius' "$DOC77_README" \
  && grep -Fq 'Phase 単位に分割' "$DOC77_README"; then
  pass "README.md: 未導入時にcontext7/code-review-graphがどう動かないかが明記されている（#77）"
else
  fail "README.md: 未導入時にcontext7/code-review-graphがどう動かないかが明記されている（#77）"
fi

# --- README に「未導入でも従来どおり動く」旨の記述がある ---

if grep -Fq '入れなくても dev-workflow は従来どおり動作します' "$DOC77_README" \
  || grep -Fq 'いずれもワークフローを止めません' "$DOC77_README"; then
  pass "README.md: 「未導入でも従来どおり動く」旨の記述がある（#77）"
else
  fail "README.md: 「未導入でも従来どおり動く」旨の記述がある（#77）"
fi

if grep -Fq 'optional-mcp-tools.md' "$DOC77_README"; then
  pass "README.md: 入れ方としてdocs/optional-mcp-tools.mdを参照している（#77）"
else
  fail "README.md: 入れ方としてdocs/optional-mcp-tools.mdを参照している（#77）"
fi

if grep -Fq '外す判断基準' "$DOC77_README"; then
  pass "README.md: 「外す判断基準」への参照がある（#77）"
else
  fail "README.md: 「外す判断基準」への参照がある（#77）"
fi

# --- README.md に ponytail のラダー・出典（MIT）・テスト対象外の旨が書かれている ---

if grep -Fq 'DietrichGebert/ponytail' "$DOC77_README" && grep -Fq 'MIT' "$DOC77_README" \
  && grep -Fq '7段の判断ラダー' "$DOC77_README"; then
  pass "README.md: ponytailのラダーと出典（MIT）が明記されている（#77）"
else
  fail "README.md: ponytailのラダーと出典（MIT）が明記されている（#77）"
fi

if grep -Fq 'テスト・回帰確認・検証・セキュリティは削減対象外' "$DOC77_README"; then
  pass "README.md: テスト・検証・安全性は削減対象外である旨が明記されている（#77）"
else
  fail "README.md: テスト・検証・安全性は削減対象外である旨が明記されている（#77）"
fi

# --- docs/dev-workflow-multi-vendor-guide.md にClaude/Codex双方の任意依存の扱いが書かれている ---

if grep -Fq '任意依存の外部 MCP ツール' "$DOC77_GUIDE" \
  && grep -Fq 'ツール単位' "$DOC77_GUIDE" && grep -Fq 'サーバー単位' "$DOC77_GUIDE"; then
  pass "docs/dev-workflow-multi-vendor-guide.md: Claude/Codexの設定場所の違いが書かれている（#77）"
else
  fail "docs/dev-workflow-multi-vendor-guide.md: Claude/Codexの設定場所の違いが書かれている（#77）"
fi

if grep -Fq '機能差は無い' "$DOC77_GUIDE" && grep -Fq '同等にできない箇所' "$DOC77_GUIDE"; then
  pass "docs/dev-workflow-multi-vendor-guide.md: 機能差の有無と同等にできない箇所の理由・回避策が書かれている（#77）"
else
  fail "docs/dev-workflow-multi-vendor-guide.md: 機能差の有無と同等にできない箇所の理由・回避策が書かれている（#77）"
fi

# ---------------------------------------------------------------------------
echo "== docs/dev-workflow-multi-vendor-guide.md の節参照が参照先ファイルに実在する（レビュー#84） =="

# レビュー指摘 #84: ガイドが「正本はそちら」として案内する節見出しが、実際には参照先ファイルに
# 存在しないケース（`core/roles/generator.md`ではなく`docs/optional-mcp-tools.md`にある節を
# 誤って`core/roles/generator.md`と案内していた）が見つかった。ドキュメント自体が成果物である
# このリポジトリでは参照切れが再発しうるため、`` `ファイル名.md` 「見出しテキスト」節 `` という
# 形式で書かれた参照をガイドから機械的に抽出し、参照先ファイルに同名の見出し（`#`〜`######`の
# いずれか）が実在することを検査する。新たに同形式の参照を追加した場合も自動的に対象になる。

DOC84_GUIDE="${REPO_ROOT}/docs/dev-workflow-multi-vendor-guide.md"

# ガイド全文を1行に連結してから抽出する（参照が改行を挟んで書かれていることがあるため）。
DOC84_REFS="$(tr '\n' ' ' < "$DOC84_GUIDE" | grep -oE '`[A-Za-z0-9_./-]+\.md`[[:space:]]*「[^」]+」節' | sort -u)"

if [ -z "$DOC84_REFS" ]; then
  fail "docs/dev-workflow-multi-vendor-guide.md: 節参照の抽出パターンが1件も見つからない（テスト自体が空振りしていないか）（#84）"
else
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    ref_file="$(printf '%s' "$ref" | grep -oE '^`[A-Za-z0-9_./-]+\.md`' | tr -d '`')"
    ref_heading="$(printf '%s' "$ref" | grep -oE '「[^」]+」節$' | sed -E 's/^「//; s/」節$//')"
    ref_target="${REPO_ROOT}/${ref_file}"

    if [ ! -f "$ref_target" ]; then
      fail "docs/dev-workflow-multi-vendor-guide.md: 参照先ファイルが実在する（#84）" \
        "参照=[${ref_file}] 見つかりません"
      continue
    fi

    ref_found=0
    for level in 1 2 3 4 5 6; do
      prefix="$(printf '#%.0s' $(seq 1 "$level"))"
      if grep -Fxq "${prefix} ${ref_heading}" "$ref_target"; then
        ref_found=1
        break
      fi
    done

    if [ "$ref_found" -eq 1 ]; then
      pass "docs/dev-workflow-multi-vendor-guide.md: 「${ref_heading}」節が ${ref_file} に実在する（#84）"
    else
      fail "docs/dev-workflow-multi-vendor-guide.md: 「${ref_heading}」節が ${ref_file} に実在する（#84）" \
        "参照先=[${ref_file}] 見出し=[${ref_heading}] が見つかりません"
    fi
  done <<< "$DOC84_REFS"
fi

# ---------------------------------------------------------------------------
# H1（Task #89）: レーンのHEADをWAVE_BASEに合わせてから実装させる
#
# `skills/run/SKILL.md:378-381`（修正前）は generator に対して「あなたの isolation
# worktree は WAVE_BASE から分岐している」という偽の前提を伝えつつ fetch/checkout/pull を
# 禁止しており、ウェーブ2以降で必ずベース検証が失敗する（詳細は docs/dev-workflow-handover.md
# のH1節）。fetch/checkout/pullの禁止は維持したまま実装着手前に git status --short /
# [ベース合わせコマンド] / git merge-base --is-ancestor / git log --oneline -1 を
# この順で実行させる。
#
# ベース合わせコマンドは当初 `git reset --hard <WAVE_BASE>` のみを例外として許可していたが、
# Task #152 で `git merge --ff-only <WAVE_BASE>` に変更した。`git reset --hard` は一般的な
# 安全設定（permission deny）でブロックされる代表的なコマンドであり、実際に本Epicのウェーブ2で
# 全3レーンがこれにより着手不能になって停止した実績があるため（`merge --ff-only` は破壊的でなく
# ブロックされにくいうえ、isolation worktreeの分岐元はWAVE_BASEの祖先であるためfast-forwardは
# 必ず成功する）。
# ---------------------------------------------------------------------------

echo ""
echo "== H1: レーンのHEADをWAVE_BASEに合わせてから実装させる（回帰防止 #89） =="

# ある1つのテキストの中で、複数の文字列がこの順序（各1回目の出現）で現れることを検査する。
assert_order() {
  # assert_order <説明> <検査対象テキスト> <文字列1> <文字列2> [<文字列3> ...]
  local desc="$1" text="$2"
  shift 2
  local prev_line=0 cur_line ok=1 missing="" needle
  for needle in "$@"; do
    cur_line="$(printf '%s\n' "$text" | grep -nF -- "$needle" | head -1 | cut -d: -f1)"
    if [ -z "$cur_line" ]; then
      ok=0
      missing="$needle"
      break
    fi
    if [ "$cur_line" -le "$prev_line" ]; then
      ok=0
      missing="$needle（直前より前または同じ行）"
      break
    fi
    prev_line="$cur_line"
  done
  if [ "$ok" -eq 1 ]; then
    pass "$desc"
  else
    fail "$desc" "見つからない・順序不正: [${missing}]"
  fi
}

# --- skills/run/SKILL.md: Step 3 プロンプト雛形に4手順がこの順で現れる ---
RS_STEP3="$(awk '/^### Step 3:/{f=1} /^### Step 4:/{f=0} f' "$RUN_SKILL_FLAT")"

assert_order "SKILL.md: Step 3 雛形に git status --short → git merge --ff-only → git merge-base --is-ancestor → git log --oneline -1 がこの順で現れる（#89）" \
  "$RS_STEP3" \
  "git status --short" "git merge --ff-only" "git merge-base --is-ancestor" "git log --oneline -1"

case "$RS_STEP3" in
  *'あなたの isolation worktree は WAVE_BASE から分岐している'*)
    fail "SKILL.md: Step 3 雛形から偽の前提（isolation worktreeはWAVE_BASEから分岐している）が消えている（#89）" \
      "$RS_STEP3" ;;
  *)
    pass "SKILL.md: Step 3 雛形から偽の前提（isolation worktreeはWAVE_BASEから分岐している）が消えている（#89）" ;;
esac

case "$RS_STEP3" in
  *'git fetch'*'git checkout'*'git pull'*'実行しないこと'*)
    pass "SKILL.md: Step 3 雛形に fetch/checkout/pull 禁止の記述が残っている（#89）" ;;
  *)
    fail "SKILL.md: Step 3 雛形に fetch/checkout/pull 禁止の記述が残っている（#89）" "$RS_STEP3" ;;
esac

# --- skills-codex/dev-workflow-run/SKILL.md: Step 3 にも同じ4手順がこの順で現れる ---
CRS_STEP3="$(awk '/^### Step 3:/{f=1} /^### Step 4:/{f=0} f' "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"

assert_order "SKILL.md(codex): Step 3 に git status --short → git merge --ff-only → git merge-base --is-ancestor → git log --oneline -1 がこの順で現れる（#89）" \
  "$CRS_STEP3" \
  "git status --short" "git merge --ff-only" "git merge-base --is-ancestor" "git log --oneline -1"

case "$CRS_STEP3" in
  *'git fetch'*'git checkout'*'git pull'*'実行しないこと'*)
    pass "SKILL.md(codex): Step 3 に fetch/checkout/pull 禁止の記述が残っている（#89）" ;;
  *)
    fail "SKILL.md(codex): Step 3 に fetch/checkout/pull 禁止の記述が残っている（#89）" "$CRS_STEP3" ;;
esac

# --- core/roles/generator.md: 「0. ...」節に同じ4手順・1回だけ・再実行しない旨がある ---
GEN_STEP0="$(awk '/^### 0\. /{f=1} /^### 1\. /{f=0} f' "${REPO_ROOT}/core/roles/generator.md")"

if [ -z "$GEN_STEP0" ]; then
  fail "core/roles/generator.md: 「0. 」節が見つかる（#89）" "節が抽出できませんでした"
else
  pass "core/roles/generator.md: 「0. 」節が見つかる（#89）"
fi

# 手順の順序は「実行する具体的なコマンド列」（```bash フェンス内）だけで検査する。
# 節の冒頭には merge --ff-only を選んだ理由（reset --hard を使わない理由）を説明する散文
# （同じ文字列を含む）があるため、節全体を対象にすると散文側の言及に引きずられて誤検知する。
GEN_STEP0_FENCE="$(printf '%s\n' "$GEN_STEP0" | awk '/^```bash/{f=1;next} /^```/{f=0} f')"

assert_order "core/roles/generator.md: 「0. 」節のコマンド列に git status --short → git merge --ff-only → git merge-base --is-ancestor → git log --oneline -1 がこの順で現れる（#89）" \
  "$GEN_STEP0_FENCE" \
  "git status --short" "git merge --ff-only" "git merge-base --is-ancestor" "git log --oneline -1"

case "$GEN_STEP0" in
  *'実装着手前に'*'1回だけ'*)
    pass "core/roles/generator.md: 「0. 」節に『実装着手前に1回だけ』の明記がある（#89）" ;;
  *)
    fail "core/roles/generator.md: 「0. 」節に『実装着手前に1回だけ』の明記がある（#89）" "$GEN_STEP0" ;;
esac

case "$GEN_STEP0" in
  *'コミットを積んだ後に再実行する必要は無い'*)
    pass "core/roles/generator.md: 「0. 」節に『コミット後に再実行する必要は無い』の明記がある（#89, #152）" ;;
  *)
    fail "core/roles/generator.md: 「0. 」節に『コミット後に再実行する必要は無い』の明記がある（#89, #152）" "$GEN_STEP0" ;;
esac

case "$GEN_STEP0" in
  *'`git merge --ff-only <WAVE_BASE>` のみを例外として許可する'*)
    pass "core/roles/generator.md: 「0. 」節に merge --ff-only のみを例外として許可する旨の明記がある（#152）" ;;
  *)
    fail "core/roles/generator.md: 「0. 」節に merge --ff-only のみを例外として許可する旨の明記がある（#152）" "$GEN_STEP0" ;;
esac

case "$GEN_STEP0" in
  *'git reset --hard'*'一般的な安全設定'*)
    pass "core/roles/generator.md: 「0. 」節に reset --hard を使わない理由（permission denyでの着手不能実績）が明記されている（#152）" ;;
  *)
    fail "core/roles/generator.md: 「0. 」節に reset --hard を使わない理由（permission denyでの着手不能実績）が明記されている（#152）" "$GEN_STEP0" ;;
esac

case "$GEN_STEP0" in
  *'`git fetch`'*'`git checkout`'*'`git pull`'*'実行しない'*)
    pass "core/roles/generator.md: 「0. 」節に fetch/checkout/pull 禁止の記述が残っている（#89）" ;;
  *)
    fail "core/roles/generator.md: 「0. 」節に fetch/checkout/pull 禁止の記述が残っている（#89）" "$GEN_STEP0" ;;
esac

# --- 偽の前提（「isolation worktree は WAVE_BASE から分岐している」）が
#     skills/run/SKILL.md・core/roles/generator.md・README.md のいずれにも無い（grepで0件） ---
for f in "skills/run/SKILL.md" "core/roles/generator.md" "README.md"; do
  if grep -Fq 'isolation worktree は WAVE_BASE から分岐している' "${REPO_ROOT}/${f}"; then
    fail "${f}: 「isolation worktree は WAVE_BASE から分岐している」という偽の前提が消えている（#89）" \
      "$(grep -n 'isolation worktree は WAVE_BASE から分岐している' "${REPO_ROOT}/${f}")"
  else
    pass "${f}: 「isolation worktree は WAVE_BASE から分岐している」という偽の前提が消えている（#89）"
  fi
done

# --- README.md「ウェーブと wave ブランチ」節: 分岐元がハーネス依存であることに触れている ---
README_WAVE_SECTION="$(awk '/^### ウェーブと wave ブランチ/{f=1} /^### `--ff-only`/{f=0} f' "${REPO_ROOT}/README.md")"

case "$README_WAVE_SECTION" in
  *'ハーネスが決めるため'*'WAVE_BASE とは限らない'*)
    pass "README.md: 「ウェーブと wave ブランチ」節が分岐元はハーネス依存でWAVE_BASEとは限らない旨に改められている（#89）" ;;
  *)
    fail "README.md: 「ウェーブと wave ブランチ」節が分岐元はハーネス依存でWAVE_BASEとは限らない旨に改められている（#89）" \
      "$README_WAVE_SECTION" ;;
esac

# ---------------------------------------------------------------------------
# H152（Task #152）: WAVE_BASEへのベース合わせ手段を git reset --hard から
# git merge --ff-only へ変更する（回帰防止）。
#
# 背景: git reset --hard は一般的な安全設定（permission deny）でブロックされる代表的な
# コマンドであり、実際に本Epicのウェーブ2で全3レーンが着手不能になって停止した。
# isolation worktreeの分岐元はWAVE_BASEの祖先であるため、破壊的でない git merge --ff-only
# で必ずfast-forwardできる。この回帰テストは「reset --hardが実行コマンドとして規定されて
# いないこと」と「merge --ff-onlyが実行コマンドとして規定されていること」を機械的に検査する。
# ---------------------------------------------------------------------------

echo ""
echo "== H152: WAVE_BASEへのベース合わせ手段が reset --hard から merge --ff-only へ変更されている =="

# --- 実行コマンド行（`$ git ...` の形でechoされている行）だけを対象に、
#     reset --hard が実行コマンドとして残っていないことを検査する ---
for h152_pair in \
  "skills/run/SKILL.md:${RS_STEP3}" \
  "skills-codex/dev-workflow-run/SKILL.md:${CRS_STEP3}" \
  "core/roles/generator.md:${GEN_STEP0_FENCE}"; do
  h152_f="${h152_pair%%:*}"
  h152_text="${h152_pair#*:}"
  h152_exec_lines="$(printf '%s\n' "$h152_text" | grep -F "echo '\$ git")"
  if printf '%s\n' "$h152_exec_lines" | grep -Fq 'reset --hard'; then
    fail "${h152_f}: WAVE_BASE合わせの実行コマンド行に reset --hard が残っていない（#152）" \
      "$h152_exec_lines"
  else
    pass "${h152_f}: WAVE_BASE合わせの実行コマンド行に reset --hard が残っていない（#152）"
  fi
  if printf '%s\n' "$h152_exec_lines" | grep -Fq 'merge --ff-only'; then
    pass "${h152_f}: WAVE_BASE合わせの実行コマンド行に merge --ff-only が規定されている（#152）"
  else
    fail "${h152_f}: WAVE_BASE合わせの実行コマンド行に merge --ff-only が規定されている（#152）" \
      "$h152_exec_lines"
  fi
done

# --- README.md: WAVE_BASE合わせの説明箇所が merge --ff-only を規定し、
#     reset --hard を使わない理由（permission denyでの着手不能実績）に触れている ---
README_WAVE_BASE_ALIGN="$(awk '/^### ウェーブと wave ブランチ/{f=1} /^### `--ff-only`/{f=0} f' "${REPO_ROOT}/README.md")"
case "$README_WAVE_BASE_ALIGN" in
  *'`git merge --ff-only "$WAVE_BASE"`'*)
    pass "README.md: WAVE_BASE合わせの説明に merge --ff-only が規定されている（#152）" ;;
  *)
    fail "README.md: WAVE_BASE合わせの説明に merge --ff-only が規定されている（#152）" \
      "$README_WAVE_BASE_ALIGN" ;;
esac
case "$README_WAVE_BASE_ALIGN" in
  *'`git reset --hard "$WAVE_BASE"`'*)
    fail "README.md: WAVE_BASE合わせの説明に reset --hard が実行コマンドとして残っていない（#152）" \
      "$README_WAVE_BASE_ALIGN" ;;
  *)
    pass "README.md: WAVE_BASE合わせの説明に reset --hard が実行コマンドとして残っていない（#152）" ;;
esac
if printf '%s\n' "$README_WAVE_BASE_ALIGN" | tr -s ' \n' ' ' | grep -Fq 'ウェーブ2で 全レーンがこれにより着手不能になって停止した'; then
  pass "README.md: reset --hard を使わない理由（実測の着手不能実績）が明記されている（#152）"
else
  fail "README.md: reset --hard を使わない理由（実測の着手不能実績）が明記されている（#152）" \
    "$README_WAVE_BASE_ALIGN"
fi

# --- core/instructions.md「ブランチ戦略」節: reset --hardを使わない理由とmerge --ff-onlyの規定 ---
H152_INSTR_BRANCH="$(awk '/^## ブランチ戦略/{f=1} /^### レーン → wave ブランチ/{f=0} f' "${REPO_ROOT}/core/instructions.md")"
case "$H152_INSTR_BRANCH" in
  *'`git merge --ff-only <WAVE_BASE>`'*'`git reset --hard` は使わない'*)
    pass "core/instructions.md: ブランチ戦略節が merge --ff-only を規定し reset --hard を使わない旨を明記している（#152）" ;;
  *)
    fail "core/instructions.md: ブランチ戦略節が merge --ff-only を規定し reset --hard を使わない旨を明記している（#152）" \
      "$H152_INSTR_BRANCH" ;;
esac

# ---------------------------------------------------------------------------
echo "== skills/epic/SKILL.md: Task issueテンプレートに「- 前提:」行を追加（#90） =="

# plan-waves.sh は Task issue 本文の「- Epic: #N」「- 前提: #N」の2行だけで
# Epic絞り込みと依存グラフを構築する（真実の源）。epic skill のテンプレートに
# 「- 前提:」が無いと、plan skill / planner 経由と挙動が食い違い、epic skill 経由で
# 作った Task issue が必ず宣言漏れ扱いになり完全逐次にフォールバックする（H4-a）。

DOC90_EPIC_SKILL="${REPO_ROOT}/skills/epic/SKILL.md"
DOC90_PLAN_WAVES="${REPO_ROOT}/scripts/plan-waves.sh"
DOC90_README="${REPO_ROOT}/README.md"

# --- Task issueテンプレート本体に「- 前提:」行がある ---
DOC90_TEMPLATE="$(awk '/^gh issue create \\$/{f=1} /^BODY$/{f=0} f' "$DOC90_EPIC_SKILL")"

case "$DOC90_TEMPLATE" in
  *'- Epic: #[epic番号]'*'- 前提: #'*)
    pass "skills/epic/SKILL.md: Task issueテンプレートで「- Epic:」の直後に「- 前提:」行がある（#90）" ;;
  *)
    fail "skills/epic/SKILL.md: Task issueテンプレートで「- Epic:」の直後に「- 前提:」行がある（#90）" \
      "$DOC90_TEMPLATE" ;;
esac

# --- 依存が無い場合に「- 前提: なし」と書かせる指示がある ---
if grep -Fq -e '- 前提: なし' "$DOC90_EPIC_SKILL"; then
  pass "skills/epic/SKILL.md: 依存が無い場合に「- 前提: なし」と明記させる指示がある（#90）"
else
  fail "skills/epic/SKILL.md: 依存が無い場合に「- 前提: なし」と明記させる指示がある（#90）"
fi

# --- 「- Epic: #N」「- 前提: #N」がplan-waves.shの書式であり、表記ゆれが受理されない旨が書かれている ---
DOC90_SECTION6="$(awk '/^### 6\. Task issue の作成/{f=1} /^### 7\./{f=0} f' "$DOC90_EPIC_SKILL")"

case "$DOC90_SECTION6" in
  *'plan-waves.sh'*'真実の源'*'表記ゆれ'*'受理されない'*)
    pass "skills/epic/SKILL.md: plan-waves.shが真実の源であり表記ゆれが受理されない旨が書かれている（#90）" ;;
  *)
    fail "skills/epic/SKILL.md: plan-waves.shが真実の源であり表記ゆれが受理されない旨が書かれている（#90）" \
      "$DOC90_SECTION6" ;;
esac

# 「scripts/plan-waves.shに差分が無い」「README.mdに差分が無い」はこのタスクの実施者が
# 対象外ファイルに触れていないことの確認であり、特定のEpicブランチに依存する差分検査を
# 恒久テストとして埋め込むと当該ブランチが消えた後にテストが壊れるため、ここでは
# スコープの明記（上記）に留め、機械的な差分検査は行わない。

# ---------------------------------------------------------------------------
# count-skips.sh（SKIP件数の機械的カウント、Task #91、Epic #88 H5-a）
#
# `skills/run/SKILL.md` の「SKIP されたテストがあれば件数と内容を報告に含めること」という
# 指示は数え方を示しておらず、`tail` で目視して「SKIP 0件」と誤報告する事故を招いた
# （`docs/dev-workflow-handover.md` H5節）。ここでは呼び出し側の差し替え（#97）は行わず、
# 数える本体だけを固定入力で検証する。Docker には一切触れない。
# ---------------------------------------------------------------------------

echo "== count-skips.sh（SKIP件数の機械的カウント） =="

COUNT_SKIPS_SCRIPT="${REPO_ROOT}/scripts/count-skips.sh"

cs_field() {
  # cs_field <field名(skips|runner|pattern)> <count-skips.shの出力全体>
  printf '%s\n' "$2" | grep -E "^$1=" | head -1 | sed "s/^$1=//"
}

# --- bash -n が通る ---
if bash -n "$COUNT_SKIPS_SCRIPT" 2>/dev/null; then
  pass "count-skips.sh: bash -n の構文チェックが通る（#91）"
else
  fail "count-skips.sh: bash -n の構文チェックが通る（#91）"
fi

# --- ケース1: Go形式・SKIPが3行 → skips=3 / runner=go / exit 0 ---
CS_GO3_INPUT="$(printf -- '--- PASS: TestA (0.00s)\n--- SKIP: TestB (0.00s)\n--- SKIP: TestC (0.00s)\n--- SKIP: TestD (0.00s)\nFAIL\nok  \texample.com/pkg\t0.01s\n')"
CS_GO3_OUTPUT="$(printf '%s\n' "$CS_GO3_INPUT" | bash "$COUNT_SKIPS_SCRIPT")"
CS_GO3_EXIT=$?
assert_eq "Go形式（SKIP3行）: skips=3" "3" "$(cs_field skips "$CS_GO3_OUTPUT")"
assert_eq "Go形式（SKIP3行）: runner=go" "go" "$(cs_field runner "$CS_GO3_OUTPUT")"
assert_exit_code "Go形式（SKIP3行）: exit 0" 0 "$CS_GO3_EXIT"

# --- ケース2: Go形式・SKIPが0行 → skips=0（unknownにならない） / runner=go / exit 0 ---
CS_GO0_INPUT="$(printf -- '--- PASS: TestA (0.00s)\nok  \texample.com/pkg\t0.01s\n')"
CS_GO0_OUTPUT="$(printf '%s\n' "$CS_GO0_INPUT" | bash "$COUNT_SKIPS_SCRIPT")"
CS_GO0_EXIT=$?
assert_eq "Go形式（SKIP0行）: skips=0（unknownにならない）" "0" "$(cs_field skips "$CS_GO0_OUTPUT")"
assert_eq "Go形式（SKIP0行）: runner=go" "go" "$(cs_field runner "$CS_GO0_OUTPUT")"
assert_exit_code "Go形式（SKIP0行）: exit 0" 0 "$CS_GO0_EXIT"

# --- ケース3: jest形式 → skips=2 / runner=jest / exit 0 ---
CS_JEST_INPUT="Tests:       2 skipped, 3 passed, 5 total"
CS_JEST_OUTPUT="$(printf '%s\n' "$CS_JEST_INPUT" | bash "$COUNT_SKIPS_SCRIPT")"
CS_JEST_EXIT=$?
assert_eq "jest形式: skips=2" "2" "$(cs_field skips "$CS_JEST_OUTPUT")"
assert_eq "jest形式: runner=jest" "jest" "$(cs_field runner "$CS_JEST_OUTPUT")"
assert_exit_code "jest形式: exit 0" 0 "$CS_JEST_EXIT"

# --- ケース4: pytest形式 → skips=2 / runner=pytest / exit 0 ---
CS_PYTEST_INPUT="$(printf -- '========== test session starts ==========\n1 passed, 2 skipped in 0.01s\n')"
CS_PYTEST_OUTPUT="$(printf '%s\n' "$CS_PYTEST_INPUT" | bash "$COUNT_SKIPS_SCRIPT")"
CS_PYTEST_EXIT=$?
assert_eq "pytest形式: skips=2" "2" "$(cs_field skips "$CS_PYTEST_OUTPUT")"
assert_eq "pytest形式: runner=pytest" "pytest" "$(cs_field runner "$CS_PYTEST_OUTPUT")"
assert_exit_code "pytest形式: exit 0" 0 "$CS_PYTEST_EXIT"

# --- ケース5: 認識できない形式 → skips=unknown / runner=unknown / exit 1（fail loud） ---
CS_UNKNOWN_INPUT="hello world, nothing test-related here"
CS_UNKNOWN_OUTPUT="$(printf '%s\n' "$CS_UNKNOWN_INPUT" | bash "$COUNT_SKIPS_SCRIPT")"
CS_UNKNOWN_EXIT=$?
assert_eq "認識できない形式: skips=unknown" "unknown" "$(cs_field skips "$CS_UNKNOWN_OUTPUT")"
assert_eq "認識できない形式: runner=unknown" "unknown" "$(cs_field runner "$CS_UNKNOWN_OUTPUT")"
assert_exit_code "認識できない形式: exit 1（fail loud）" 1 "$CS_UNKNOWN_EXIT"

# --- ケース5': このリポジトリ自身のテスト形式（`bash tests/run-tests.sh` の ok/NG/skip 形式）を
#     渡すと、built-inランナー（go/jest/pytest）のどれにも一致せず unknown/exit1 になる。
#     これが「SKIP 0件」（Go形式・ケース2）と「形式を認識できない」（本ケース）を
#     取り違えない、という本タスクの核心を実際のリポジトリ形式で示す ---
CS_SELF_INPUT="$(printf '  ok   - サンプルテスト1\n  skip - サンプルテスト2 (依存物未配置)\n\n== 結果: 1 passed, 0 failed, 1 skipped ==\n')"
CS_SELF_OUTPUT="$(printf '%s\n' "$CS_SELF_INPUT" | bash "$COUNT_SKIPS_SCRIPT")"
CS_SELF_EXIT=$?
assert_eq "このリポジトリ自身のok/NG/skip形式: skips=unknown（0件と誤報告しない）" "unknown" "$(cs_field skips "$CS_SELF_OUTPUT")"
assert_exit_code "このリポジトリ自身のok/NG/skip形式: exit 1（fail loud）" 1 "$CS_SELF_EXIT"

# --- ケース6: --pattern が最優先され runner=custom になる ---
CS_PATTERN_INPUT="$(printf 'skip - foo (reason)\nskip - bar (reason)\n')"
CS_PATTERN_OUTPUT="$(printf '%s\n' "$CS_PATTERN_INPUT" | bash "$COUNT_SKIPS_SCRIPT" --pattern '^skip - ')"
CS_PATTERN_EXIT=$?
assert_eq "--pattern指定: skips=2" "2" "$(cs_field skips "$CS_PATTERN_OUTPUT")"
assert_eq "--pattern指定: runner=custom" "custom" "$(cs_field runner "$CS_PATTERN_OUTPUT")"
assert_eq "--pattern指定: pattern=^skip - " "^skip - " "$(cs_field pattern "$CS_PATTERN_OUTPUT")"
assert_exit_code "--pattern指定: exit 0" 0 "$CS_PATTERN_EXIT"

# --- ケース7: DEV_WORKFLOW_SKIP_PATTERN 環境変数でも同様に custom になる ---
CS_ENV_INPUT="$(printf 'skip - foo\nskip - bar\nskip - baz\n')"
CS_ENV_OUTPUT="$(printf '%s\n' "$CS_ENV_INPUT" | DEV_WORKFLOW_SKIP_PATTERN='^skip - ' bash "$COUNT_SKIPS_SCRIPT")"
CS_ENV_EXIT=$?
assert_eq "DEV_WORKFLOW_SKIP_PATTERN指定: skips=3" "3" "$(cs_field skips "$CS_ENV_OUTPUT")"
assert_eq "DEV_WORKFLOW_SKIP_PATTERN指定: runner=custom" "custom" "$(cs_field runner "$CS_ENV_OUTPUT")"
assert_exit_code "DEV_WORKFLOW_SKIP_PATTERN指定: exit 0" 0 "$CS_ENV_EXIT"

# --- ケース8: --pattern と DEV_WORKFLOW_SKIP_PATTERN が両方あれば --pattern を優先する ---
CS_BOTH_OUTPUT="$(printf 'skip - foo\nSKIPPED bar\n' | DEV_WORKFLOW_SKIP_PATTERN='^SKIPPED' bash "$COUNT_SKIPS_SCRIPT" --pattern '^skip - ')"
assert_eq "--patternとDEV_WORKFLOW_SKIP_PATTERN併存: --patternが優先される" "1" "$(cs_field skips "$CS_BOTH_OUTPUT")"

# --- ケース8': --pattern に不正な ERE（未閉じの角括弧）を渡すと skips=unknown / runner=custom /
#     pattern=<渡された値> になり exit 1（fail loud）。grepのエラー終了コードを検証せず
#     そのまま出力していると skips= が空値のまま exit 0 になってしまう（#101） ---
CS_BADPATTERN_INPUT="$(printf 'a\nb\n')"
CS_BADPATTERN_OUTPUT="$(printf '%s\n' "$CS_BADPATTERN_INPUT" | bash "$COUNT_SKIPS_SCRIPT" --pattern '[' 2>/dev/null)"
CS_BADPATTERN_EXIT=$?
assert_eq "不正なERE: skips=unknown（空値のままにしない）" "unknown" "$(cs_field skips "$CS_BADPATTERN_OUTPUT")"
assert_eq "不正なERE: runner=custom" "custom" "$(cs_field runner "$CS_BADPATTERN_OUTPUT")"
assert_eq "不正なERE: pattern=[（渡された値をそのまま出す）" "[" "$(cs_field pattern "$CS_BADPATTERN_OUTPUT")"
assert_exit_code "不正なERE: exit 1（fail loud）" 1 "$CS_BADPATTERN_EXIT"

# --- ケース8'': --pattern に有効なEREだが一致0件の場合は不正なEREと区別し、
#     従来どおり skips=0 / exit 0 のまま（正常な「一致なし」を壊さない） ---
CS_NOMATCH_INPUT="$(printf 'a\nb\n')"
CS_NOMATCH_OUTPUT="$(printf '%s\n' "$CS_NOMATCH_INPUT" | bash "$COUNT_SKIPS_SCRIPT" --pattern '^zzz$')"
CS_NOMATCH_EXIT=$?
assert_eq "有効なEREで一致0件: skips=0" "0" "$(cs_field skips "$CS_NOMATCH_OUTPUT")"
assert_exit_code "有効なEREで一致0件: exit 0（正常扱いのまま）" 0 "$CS_NOMATCH_EXIT"

# --- ケース9: 引数エラー（exit 2） ---
bash "$COUNT_SKIPS_SCRIPT" --file >/dev/null 2>&1
assert_exit_code "引数エラー: --file に値なしで exit 2" 2 "$?"

bash "$COUNT_SKIPS_SCRIPT" --file /path/does/not/exist.log >/dev/null 2>&1
assert_exit_code "引数エラー: 存在しないファイルで exit 2" 2 "$?"

bash "$COUNT_SKIPS_SCRIPT" --unknown-option >/dev/null 2>&1
assert_exit_code "引数エラー: 未知のオプションで exit 2" 2 "$?"

# --- ケース10: --file 経由の読み込み ---
CS_FILE_FIXTURE="$(mktemp "${TMPDIR:-/tmp}/dw-test-cs-file.XXXXXX")"
printf -- '--- SKIP: T1 (0.00s)\n--- SKIP: T2 (0.00s)\nok  \tpkg\t0.01s\n' > "$CS_FILE_FIXTURE"
CS_FILE_OUTPUT="$(bash "$COUNT_SKIPS_SCRIPT" --file "$CS_FILE_FIXTURE")"
CS_FILE_EXIT=$?
assert_eq "--file経由: skips=2" "2" "$(cs_field skips "$CS_FILE_OUTPUT")"
assert_eq "--file経由: runner=go" "go" "$(cs_field runner "$CS_FILE_OUTPUT")"
assert_exit_code "--file経由: exit 0" 0 "$CS_FILE_EXIT"

# --- ケース11: --file と標準入力が両方ある場合、--file を優先する ---
CS_BOTHIN_OUTPUT="$(printf 'Tests:       0 skipped, 5 passed, 5 total\n' | bash "$COUNT_SKIPS_SCRIPT" --file "$CS_FILE_FIXTURE")"
assert_eq "--fileと標準入力の併存: --fileを優先（go形式のskips=2のまま）" "2" "$(cs_field skips "$CS_BOTHIN_OUTPUT")"
assert_eq "--fileと標準入力の併存: runnerもgoのまま" "go" "$(cs_field runner "$CS_BOTHIN_OUTPUT")"

# --- ケース12（回帰・issue #142）: jest の `PASS <file>` / `FAIL <file>` 行が
#     Go判定の `^(ok|FAIL|PASS)` と字面衝突し、runner=go・skips=0（実際は1件）に
#     誤検出されていた事象を、issue本文のログ断片をfixtureにして固定する。
#     「skips=unknown」ではなく「skips=0（誤り）」として観測される点が最も危険だった。 ---
CS_JEST_MISDETECT_INPUT="$(cat <<'JEST_LOG_142'
yarn run v1.22.19
$ jest
PASS src/components/Foo.test.tsx
FAIL src/components/Bar.test.tsx
  ● Bar renders correctly

    expect(received).toBe(expected)

Test Suites: 5 failed, 69 passed, 74 total
Tests:       13 failed, 1 skipped, 899 passed, 913 total
Snapshots:   0 total
Time:        12.345s
JEST_LOG_142
)"
CS_JEST_MISDETECT_OUTPUT="$(printf '%s\n' "$CS_JEST_MISDETECT_INPUT" | bash "$COUNT_SKIPS_SCRIPT")"
CS_JEST_MISDETECT_EXIT=$?
assert_eq "回帰(#142): PASS/FAIL行を含むjestログでもrunner=jest（goに誤検出しない）" \
  "jest" "$(cs_field runner "$CS_JEST_MISDETECT_OUTPUT")"
assert_eq "回帰(#142): PASS/FAIL行を含むjestログでskips=1（0件に誤検出しない）" \
  "1" "$(cs_field skips "$CS_JEST_MISDETECT_OUTPUT")"
assert_exit_code "回帰(#142): exit 0（正しく数えられた）" 0 "$CS_JEST_MISDETECT_EXIT"

# --- ケース13: --runner jest で自動判定を上書きし、あいまいなログでも強制的にjestとして数える ---
CS_RUNNER_FORCE_OUTPUT="$(printf '%s\n' "$CS_JEST_MISDETECT_INPUT" | bash "$COUNT_SKIPS_SCRIPT" --runner jest)"
CS_RUNNER_FORCE_EXIT=$?
assert_eq "--runner jest: runner=jestを強制する" "jest" "$(cs_field runner "$CS_RUNNER_FORCE_OUTPUT")"
assert_eq "--runner jest: skips=1" "1" "$(cs_field skips "$CS_RUNNER_FORCE_OUTPUT")"
assert_exit_code "--runner jest: exit 0" 0 "$CS_RUNNER_FORCE_EXIT"

# --- ケース14: --runner go / --runner pytest も同様に自動判定を上書きする ---
CS_RUNNER_GO_OUTPUT="$(printf -- '--- SKIP: T1 (0.00s)\n--- SKIP: T2 (0.00s)\nok  \tpkg\t0.01s\n' | bash "$COUNT_SKIPS_SCRIPT" --runner go)"
assert_eq "--runner go: skips=2 / runner=go" "go" "$(cs_field runner "$CS_RUNNER_GO_OUTPUT")"
assert_eq "--runner go: skips=2" "2" "$(cs_field skips "$CS_RUNNER_GO_OUTPUT")"

CS_RUNNER_PYTEST_OUTPUT="$(printf -- '========== test session starts ==========\n1 passed, 2 skipped in 0.01s\n' | bash "$COUNT_SKIPS_SCRIPT" --runner pytest)"
assert_eq "--runner pytest: skips=2 / runner=pytest" "pytest" "$(cs_field runner "$CS_RUNNER_PYTEST_OUTPUT")"
assert_eq "--runner pytest: skips=2" "2" "$(cs_field skips "$CS_RUNNER_PYTEST_OUTPUT")"

# --- ケース15: --pattern と --runner が両方指定された場合、--pattern を優先する ---
CS_RUNNER_AND_PATTERN_OUTPUT="$(printf 'skip - foo\nskip - bar\n' | bash "$COUNT_SKIPS_SCRIPT" --runner go --pattern '^skip - ')"
assert_eq "--runnerと--patternの併存: --patternを優先しrunner=custom" "custom" "$(cs_field runner "$CS_RUNNER_AND_PATTERN_OUTPUT")"
assert_eq "--runnerと--patternの併存: skips=2" "2" "$(cs_field skips "$CS_RUNNER_AND_PATTERN_OUTPUT")"

# --- ケース16: --runner に未知の値を渡すと引数エラー（exit 2） ---
bash "$COUNT_SKIPS_SCRIPT" --runner rspec >/dev/null 2>&1
assert_exit_code "--runner に未知の値でexit 2" 2 "$?"

bash "$COUNT_SKIPS_SCRIPT" --runner >/dev/null 2>&1
assert_exit_code "--runner に値なしでexit 2" 2 "$?"

# --- ケース17: --help は使い方を表示してexit 0（引数エラーにしない） ---
CS_HELP_OUTPUT="$(bash "$COUNT_SKIPS_SCRIPT" --help)"
CS_HELP_EXIT=$?
assert_exit_code "--help: exit 0" 0 "$CS_HELP_EXIT"
case "$CS_HELP_OUTPUT" in
  *'使い方'*'--runner'*)
    pass "--help: 使い方に--runnerの説明が含まれる（#142）" ;;
  *)
    fail "--help: 使い方に--runnerの説明が含まれる（#142）" "$CS_HELP_OUTPUT" ;;
esac

# --- ケース18（回帰・issue #187）: jest判定は `Test Suites:` / `Tests:` / `Snapshots:` の
#     いずれかで決まるが、件数抽出は `Tests:` 行にしか依存できない。`Test Suites:` だけの
#     ログでは `Tests:` 行が存在せず、以前は `COUNT="${COUNT:-0}"` が抽出失敗を0件に潰し
#     `skips=0 / exit 0`（#142と同種の「判定できないのに0件と答える」誤り）を返していた。
#     修正後は skips=unknown / exit 1 になることを固定する ---
CS_JEST_NOTESTS_INPUT="$(printf -- 'PASS a.test.ts\nTest Suites: 1 passed, 1 total\n')"
CS_JEST_NOTESTS_OUTPUT="$(printf '%s\n' "$CS_JEST_NOTESTS_INPUT" | bash "$COUNT_SKIPS_SCRIPT")"
CS_JEST_NOTESTS_EXIT=$?
assert_eq "回帰(#187): Test Suites:だけのjestログはskips=unknown（0件と誤報告しない）" \
  "unknown" "$(cs_field skips "$CS_JEST_NOTESTS_OUTPUT")"
assert_eq "回帰(#187): Test Suites:だけのjestログでもrunner=jest（判定自体は維持）" \
  "jest" "$(cs_field runner "$CS_JEST_NOTESTS_OUTPUT")"
assert_exit_code "回帰(#187): exit 1（fail loud）" 1 "$CS_JEST_NOTESTS_EXIT"

# --- ケース19（回帰・issue #187）: `Snapshots:` だけのログも同様にskips=unknownになる ---
CS_JEST_SNAPONLY_OUTPUT="$(printf 'Snapshots: 0 total\n' | bash "$COUNT_SKIPS_SCRIPT")"
CS_JEST_SNAPONLY_EXIT=$?
assert_eq "回帰(#187): Snapshots:だけのjestログはskips=unknown" \
  "unknown" "$(cs_field skips "$CS_JEST_SNAPONLY_OUTPUT")"
assert_exit_code "回帰(#187): Snapshots:だけのjestログはexit 1" 1 "$CS_JEST_SNAPONLY_EXIT"

# --- ケース20（issue #187）: --runner jest を強制指定してもTests:行が無ければ
#     同様にunknownへ倒れる（--runner分岐と自動判定分岐で抽出ロジックを共用しているため） ---
CS_RUNNERJEST_NOTESTS_OUTPUT="$(printf 'Test Suites: 1 passed, 1 total\n' | bash "$COUNT_SKIPS_SCRIPT" --runner jest)"
CS_RUNNERJEST_NOTESTS_EXIT=$?
assert_eq "issue #187: --runner jestでもTests:行が無ければskips=unknown" \
  "unknown" "$(cs_field skips "$CS_RUNNERJEST_NOTESTS_OUTPUT")"
assert_exit_code "issue #187: --runner jestでもTests:行が無ければexit 1" 1 "$CS_RUNNERJEST_NOTESTS_EXIT"

# --- ケース21（issue #187）: jestでTests:行はあるがskip 0件（`skipped`という語が出ない）は
#     正当な0件として扱う（unknownと混同しない） ---
CS_JEST_ZERO_OUTPUT="$(printf 'Tests:       0 skipped, 5 passed, 5 total\n' | bash "$COUNT_SKIPS_SCRIPT")"
CS_JEST_ZERO_EXIT=$?
assert_eq "issue #187: jestでTests:行があればskipped無しでも正当な0件" \
  "0" "$(cs_field skips "$CS_JEST_ZERO_OUTPUT")"
assert_exit_code "issue #187: jestの正当な0件はexit 0のまま" 0 "$CS_JEST_ZERO_EXIT"

# --- ケース22（issue #187）: pytest側の ${COUNT:-0} も同様に見直す。
#     `test session starts` はあるが最終サマリ行（` in <秒>s`）が無い（出力が途中で切れた等）
#     ログは、以前はskips=0（誤り）になっていた。修正後はskips=unknownへ倒す ---
CS_PYTEST_NOSUMMARY_INPUT="$(printf -- '========== test session starts ==========\ncollecting ...\n')"
CS_PYTEST_NOSUMMARY_OUTPUT="$(printf '%s\n' "$CS_PYTEST_NOSUMMARY_INPUT" | bash "$COUNT_SKIPS_SCRIPT")"
CS_PYTEST_NOSUMMARY_EXIT=$?
assert_eq "issue #187: サマリ行の無いpytestログはskips=unknown（0件と誤報告しない）" \
  "unknown" "$(cs_field skips "$CS_PYTEST_NOSUMMARY_OUTPUT")"
assert_eq "issue #187: サマリ行の無いpytestログでもrunner=pytest（判定自体は維持）" \
  "pytest" "$(cs_field runner "$CS_PYTEST_NOSUMMARY_OUTPUT")"
assert_exit_code "issue #187: サマリ行の無いpytestログはexit 1（fail loud）" 1 "$CS_PYTEST_NOSUMMARY_EXIT"

# --- ケース23（issue #187）: pytestでサマリ行はあるがskip 0件（`skipped`という語が出ない）は
#     正当な0件として扱う ---
CS_PYTEST_ZERO_INPUT="$(printf -- '========== test session starts ==========\n5 passed in 0.01s\n')"
CS_PYTEST_ZERO_OUTPUT="$(printf '%s\n' "$CS_PYTEST_ZERO_INPUT" | bash "$COUNT_SKIPS_SCRIPT")"
CS_PYTEST_ZERO_EXIT=$?
assert_eq "issue #187: pytestでサマリ行があればskipped無しでも正当な0件" \
  "0" "$(cs_field skips "$CS_PYTEST_ZERO_OUTPUT")"
assert_exit_code "issue #187: pytestの正当な0件はexit 0のまま" 0 "$CS_PYTEST_ZERO_EXIT"

# ---------------------------------------------------------------------------
# cleanup-lane-worktrees.sh（取り込み済みレーンworktreeの片付け・Task #93）
#
# 一時 git リポジトリに Epic ブランチ・複数のレーンブランチ・それぞれの worktree を
# 組み立てて検証する（Docker 非依存）。ml_commit_file / ml_branch_from / ml_head_of は
# merge-lane.sh のテスト用に定義済みの汎用ヘルパをそのまま再利用する。
# 呼び出し側（run からの結線）は #95 の担当なので、ここではスクリプト単体の振る舞いのみを見る。
# ---------------------------------------------------------------------------

echo "== cleanup-lane-worktrees.sh（取り込み済みレーンworktreeの片付け） =="

CLW_SCRIPT="${REPO_ROOT}/scripts/cleanup-lane-worktrees.sh"

# --- bash -n が通る ---
if bash -n "$CLW_SCRIPT" 2>/dev/null; then
  pass "cleanup-lane-worktrees.sh: bash -n の構文チェックが通る（#93）"
else
  fail "cleanup-lane-worktrees.sh: bash -n の構文チェックが通る（#93）"
fi

# --- スクリプト内に rm / rmdir によるディレクトリ削除が無い（安全ルール）。
#     コメント行は対象外にし、単語境界での一致だけを見る
#     （ヘッダコメントの「rm / rmdir」という説明文はコメント行なので除外される） ---
CLW_FORBIDDEN_HITS="$(grep -v '^[[:space:]]*#' "$CLW_SCRIPT" \
  | grep -E '(^|[^A-Za-z0-9_])(rm|rmdir)([[:space:]]|$)' || true)"
if [ -z "$CLW_FORBIDDEN_HITS" ]; then
  pass "cleanup-lane-worktrees.sh: rm / rmdir によるディレクトリ削除が無い"
else
  fail "cleanup-lane-worktrees.sh: rm / rmdir によるディレクトリ削除が無い" "$CLW_FORBIDDEN_HITS"
fi

clw_add_worktree() {
  # clw_add_worktree <repo_dir> <worktree_dir> <既存のブランチ名>
  # make_worktree は -b で新規ブランチを作るため、既存ブランチを checkout する
  # 本テストでは使えない。既存ブランチをそのまま worktree に張るための専用ヘルパ。
  local repo="$1" wt_dir="$2" branch="$3"
  (
    cd "$repo" || exit 1
    git worktree add -q "$wt_dir" "$branch"
  ) >/dev/null 2>&1
}

run_cleanup() {
  # run_cleanup <repo_dir> [追加の引数...]  戻り値は標準出力（呼び出し側で $? を確認する）
  local repo="$1"
  shift
  (cd "$repo" || exit 1; bash "$CLW_SCRIPT" "$@")
}

clw_worktree_exists() {
  # clw_worktree_exists <repo_dir> <branch>  worktreeがあれば "yes" 、無ければ "no"
  local repo="$1" branch="$2" found
  found="$(
    (cd "$repo" || exit 1; git worktree list --porcelain) 2>/dev/null \
      | awk -v want="refs/heads/${branch}" '
          $0 == "branch " want { print "yes"; exit }
        '
  )"
  [ -n "$found" ] && echo "yes" || echo "no"
}

# --- 検証用リポジトリの組み立て ---
# CLW_DEFAULT_BRANCH（メインworktreeがチェックアウトしているブランチ）
#   -- init commit
#     -- CLW_EPIC_BRANCH（epic/testclw/93）-- epic base commit
#          -- lane-merged      -- merged.txt commit    （epicへ取り込み済み）
#          -- lane-untouched   -- untouched.txt commit （epicへ取り込み済みだが --lane-branch に渡さない）
#          -- lane-notmerged   -- notmerged.txt commit （epicへ未取り込みのまま）
CLW_REPO="$(make_temp_repo)"
CLW_DEFAULT_BRANCH="$(cd "$CLW_REPO" && git rev-parse --abbrev-ref HEAD)"
CLW_EPIC_BRANCH="epic/testclw/93"

CLW_ROOT_BASE="$(ml_head_of "$CLW_REPO" HEAD)"
ml_branch_from "$CLW_REPO" "$CLW_EPIC_BRANCH" "$CLW_ROOT_BASE"
ml_commit_file "$CLW_REPO" "epic.txt" "epic base\n" "epic base commit"
CLW_EPIC_TIP1="$(ml_head_of "$CLW_REPO" "$CLW_EPIC_BRANCH")"

ml_branch_from "$CLW_REPO" "lane-merged" "$CLW_EPIC_TIP1"
ml_commit_file "$CLW_REPO" "merged.txt" "merged\n" "lane merged change"

ml_branch_from "$CLW_REPO" "lane-untouched" "$CLW_EPIC_TIP1"
ml_commit_file "$CLW_REPO" "untouched.txt" "untouched\n" "lane untouched change"

ml_branch_from "$CLW_REPO" "lane-notmerged" "$CLW_EPIC_TIP1"
ml_commit_file "$CLW_REPO" "notmerged.txt" "not merged\n" "lane not merged change"

# lane-merged / lane-untouched を epic ブランチへ取り込む（epic ブランチを一時的に checkout）
(cd "$CLW_REPO" && git checkout -q "$CLW_EPIC_BRANCH" \
  && git merge -q --no-edit lane-merged \
  && git merge -q --no-edit lane-untouched \
  && git checkout -q "$CLW_DEFAULT_BRANCH") >/dev/null 2>&1

# メインworktree は CLW_DEFAULT_BRANCH のまま（epic ブランチを空ける。同じブランチを
# 2箇所でチェックアウトできないため、linked worktree で epic ブランチを張れるようにする）
clw_add_worktree "$CLW_REPO" "${CLW_REPO}/.claude/worktrees/epicwt" "$CLW_EPIC_BRANCH"
clw_add_worktree "$CLW_REPO" "${CLW_REPO}/.claude/worktrees/lane-merged" "lane-merged"
clw_add_worktree "$CLW_REPO" "${CLW_REPO}/.claude/worktrees/lane-untouched" "lane-untouched"
clw_add_worktree "$CLW_REPO" "${CLW_REPO}/.claude/worktrees/lane-notmerged" "lane-notmerged"

# --- ケース1: --dry-run では取り込み済みレーンが removed 候補として列挙されるが、
#     実際には削除されない（受け入れ条件2） ---
CLW_DRY_OUT="$(run_cleanup "$CLW_REPO" --epic-branch "$CLW_EPIC_BRANCH" \
  --lane-branch lane-merged --lane-branch lane-notmerged --dry-run)"
CLW_DRY_EXIT=$?
assert_exit_code "ケース1: --dry-run は exit 0" 0 "$CLW_DRY_EXIT"

case "$CLW_DRY_OUT" in
  *"removed"*"lane-merged"*"lane-merged"*)
    pass "ケース1: 取り込み済みレーン（lane-merged）が removed 候補として出る" ;;
  *)
    fail "ケース1: 取り込み済みレーン（lane-merged）が removed 候補として出る" "output=[${CLW_DRY_OUT}]" ;;
esac

assert_eq "ケース1: --dry-run 後も lane-merged の worktree は残っている（削除されていない）" \
  "yes" "$(clw_worktree_exists "$CLW_REPO" lane-merged)"

# --- ケース2: 取り込み未の lane-notmerged は --dry-run でも skip reason not-merged になる
#     （受け入れ条件3） ---
case "$CLW_DRY_OUT" in
  *"skip"*"lane-notmerged"*"reason"*"not-merged"*)
    pass "ケース2: 取り込み未のレーン（lane-notmerged）は skip reason not-merged" ;;
  *)
    fail "ケース2: 取り込み未のレーン（lane-notmerged）は skip reason not-merged" "output=[${CLW_DRY_OUT}]" ;;
esac

# --- ケース3: --dry-run 無しで実行すると、実際にレーン worktree が削除される
#     （受け入れ条件: --dry-run 無しで実際に削除される） ---
CLW_REAL_OUT="$(run_cleanup "$CLW_REPO" --epic-branch "$CLW_EPIC_BRANCH" \
  --lane-branch lane-merged --lane-branch lane-notmerged \
  --lane-branch "$CLW_DEFAULT_BRANCH" --lane-branch "$CLW_EPIC_BRANCH" \
  --lane-branch no-such-lane-branch)"
CLW_REAL_EXIT=$?
assert_exit_code "ケース3: --dry-run 無しの実行は exit 0（skipが混ざっていても0）" 0 "$CLW_REAL_EXIT"

case "$CLW_REAL_OUT" in
  *"removed"*"lane-merged"*)
    pass "ケース3: 取り込み済みレーン（lane-merged）が removed と報告される" ;;
  *)
    fail "ケース3: 取り込み済みレーン（lane-merged）が removed と報告される" "output=[${CLW_REAL_OUT}]" ;;
esac

assert_eq "ケース3: 実行後 lane-merged の worktree が実際に削除される（git worktree list から消える）" \
  "no" "$(clw_worktree_exists "$CLW_REPO" lane-merged)"

# --- ケース4: 取り込み未のレーンは削除されず worktree が残ったまま（受け入れ条件3） ---
case "$CLW_REAL_OUT" in
  *"skip"*"lane-notmerged"*"reason"*"not-merged"*)
    pass "ケース4: lane-notmerged は skip reason not-merged で削除されない" ;;
  *)
    fail "ケース4: lane-notmerged は skip reason not-merged で削除されない" "output=[${CLW_REAL_OUT}]" ;;
esac
assert_eq "ケース4: lane-notmerged の worktree は削除されずに残っている" \
  "yes" "$(clw_worktree_exists "$CLW_REPO" lane-notmerged)"

# --- ケース5: メインworktreeがチェックアウトしているブランチは skip reason protected
#     （受け入れ条件4。メインworktree自体は消えず、当然 git rev-parse も生きたまま） ---
case "$CLW_REAL_OUT" in
  *"skip"*"$CLW_DEFAULT_BRANCH"*"reason"*"protected"*)
    pass "ケース5: メインworktreeのブランチは skip reason protected" ;;
  *)
    fail "ケース5: メインworktreeのブランチは skip reason protected" "output=[${CLW_REAL_OUT}]" ;;
esac
assert_eq "ケース5: メインworktreeのブランチは削除後も worktree として残る" \
  "yes" "$(clw_worktree_exists "$CLW_REPO" "$CLW_DEFAULT_BRANCH")"

# --- ケース6: --epic-branch をチェックアウトしている worktree は skip reason protected
#     （受け入れ条件4） ---
case "$CLW_REAL_OUT" in
  *"skip"*"$CLW_EPIC_BRANCH"*"reason"*"protected"*)
    pass "ケース6: --epic-branch の worktree は skip reason protected" ;;
  *)
    fail "ケース6: --epic-branch の worktree は skip reason protected" "output=[${CLW_REAL_OUT}]" ;;
esac
assert_eq "ケース6: --epic-branch の worktree は削除後も残る" \
  "yes" "$(clw_worktree_exists "$CLW_REPO" "$CLW_EPIC_BRANCH")"

# --- ケース7: worktreeが無い（存在しない）レーンブランチは skip reason no-worktree
#     （受け入れ条件: no-worktree で exit 0） ---
case "$CLW_REAL_OUT" in
  *"skip"*"no-such-lane-branch"*"reason"*"no-worktree"*)
    pass "ケース7: worktreeの無いレーンブランチは skip reason no-worktree" ;;
  *)
    fail "ケース7: worktreeの無いレーンブランチは skip reason no-worktree" "output=[${CLW_REAL_OUT}]" ;;
esac

# --- ケース8: --lane-branch に明示的に渡されなかった lane-untouched は、取り込み済みでも
#     一切触れられない（他Epic・未指定worktreeに触れない原則の確認） ---
assert_eq "ケース8: --lane-branch で渡していない lane-untouched の worktree は残ったまま" \
  "yes" "$(clw_worktree_exists "$CLW_REPO" lane-untouched)"

# --- ケース9（R7対策の実機確認）: node_modules 等の symlink を解除してから削除するため、
#     symlink先の実体ディレクトリが誤って消えないこと ---
CLW_SYM_REPO="$(make_temp_repo)"
CLW_SYM_DEFAULT_BRANCH="$(cd "$CLW_SYM_REPO" && git rev-parse --abbrev-ref HEAD)"
CLW_SYM_EPIC_BRANCH="epic/testsym/93"
CLW_SYM_BASE="$(ml_head_of "$CLW_SYM_REPO" HEAD)"
ml_branch_from "$CLW_SYM_REPO" "$CLW_SYM_EPIC_BRANCH" "$CLW_SYM_BASE"
ml_commit_file "$CLW_SYM_REPO" "epic.txt" "epic base\n" "epic base commit"
CLW_SYM_EPIC_TIP="$(ml_head_of "$CLW_SYM_REPO" "$CLW_SYM_EPIC_BRANCH")"
ml_branch_from "$CLW_SYM_REPO" "lane-sym" "$CLW_SYM_EPIC_TIP"
ml_commit_file "$CLW_SYM_REPO" "sym.txt" "sym\n" "lane sym change"
(cd "$CLW_SYM_REPO" && git checkout -q "$CLW_SYM_EPIC_BRANCH" \
  && git merge -q --no-edit lane-sym \
  && git checkout -q "$CLW_SYM_DEFAULT_BRANCH") >/dev/null 2>&1
clw_add_worktree "$CLW_SYM_REPO" "${CLW_SYM_REPO}/.claude/worktrees/lane-sym" "lane-sym"

CLW_SYM_REAL_TARGET="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-clw-realdir.XXXXXX")"
printf 'do not delete me\n' > "${CLW_SYM_REAL_TARGET}/marker.txt"
(cd "${CLW_SYM_REPO}/.claude/worktrees/lane-sym" && ln -s "$CLW_SYM_REAL_TARGET" node_modules) >/dev/null 2>&1

run_cleanup "$CLW_SYM_REPO" --epic-branch "$CLW_SYM_EPIC_BRANCH" --lane-branch lane-sym >/dev/null

assert_eq "ケース9: node_modules症状のレーンworktreeも削除される" \
  "no" "$(clw_worktree_exists "$CLW_SYM_REPO" lane-sym)"

if [ -f "${CLW_SYM_REAL_TARGET}/marker.txt" ]; then
  pass "ケース9: symlink解除後の削除でも symlink先の実体ファイルは消えない（R7対策）"
else
  fail "ケース9: symlink解除後の削除でも symlink先の実体ファイルは消えない（R7対策）" \
    "marker.txt が消えました: ${CLW_SYM_REAL_TARGET}"
fi

# --- ケース9b（Task #109）: --unlink-dir vendor を指定すると vendor の symlink が
#     解除される（既定の node_modules とは別名でも動くこと） ---
CLW_VENDOR_REPO="$(make_temp_repo)"
CLW_VENDOR_DEFAULT_BRANCH="$(cd "$CLW_VENDOR_REPO" && git rev-parse --abbrev-ref HEAD)"
CLW_VENDOR_EPIC_BRANCH="epic/testvendor/109"
CLW_VENDOR_BASE="$(ml_head_of "$CLW_VENDOR_REPO" HEAD)"
ml_branch_from "$CLW_VENDOR_REPO" "$CLW_VENDOR_EPIC_BRANCH" "$CLW_VENDOR_BASE"
ml_commit_file "$CLW_VENDOR_REPO" "epic.txt" "epic base\n" "epic base commit"
CLW_VENDOR_EPIC_TIP="$(ml_head_of "$CLW_VENDOR_REPO" "$CLW_VENDOR_EPIC_BRANCH")"
ml_branch_from "$CLW_VENDOR_REPO" "lane-vendor" "$CLW_VENDOR_EPIC_TIP"
ml_commit_file "$CLW_VENDOR_REPO" "vendor.txt" "vendor\n" "lane vendor change"
(cd "$CLW_VENDOR_REPO" && git checkout -q "$CLW_VENDOR_EPIC_BRANCH" \
  && git merge -q --no-edit lane-vendor \
  && git checkout -q "$CLW_VENDOR_DEFAULT_BRANCH") >/dev/null 2>&1
clw_add_worktree "$CLW_VENDOR_REPO" "${CLW_VENDOR_REPO}/.claude/worktrees/lane-vendor" "lane-vendor"

CLW_VENDOR_REAL_TARGET="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-clw-vendordir.XXXXXX")"
printf 'do not delete me\n' > "${CLW_VENDOR_REAL_TARGET}/marker.txt"
(cd "${CLW_VENDOR_REPO}/.claude/worktrees/lane-vendor" && ln -s "$CLW_VENDOR_REAL_TARGET" vendor) >/dev/null 2>&1

CLW_VENDOR_OUT="$(run_cleanup "$CLW_VENDOR_REPO" --epic-branch "$CLW_VENDOR_EPIC_BRANCH" \
  --lane-branch lane-vendor --unlink-dir vendor)"
CLW_VENDOR_EXIT=$?

assert_exit_code "ケース9b: --unlink-dir vendor 指定時も exit 0" 0 "$CLW_VENDOR_EXIT"

case "$CLW_VENDOR_OUT" in
  *"removed"*"lane-vendor"*)
    pass "ケース9b: --unlink-dir vendor 指定でも removed と報告される（出力契約は変わらない）" ;;
  *)
    fail "ケース9b: --unlink-dir vendor 指定でも removed と報告される（出力契約は変わらない）" \
      "output=[${CLW_VENDOR_OUT}]" ;;
esac

assert_eq "ケース9b: --unlink-dir vendor 指定でレーンworktreeが削除される" \
  "no" "$(clw_worktree_exists "$CLW_VENDOR_REPO" lane-vendor)"

if [ -f "${CLW_VENDOR_REAL_TARGET}/marker.txt" ]; then
  pass "ケース9b: --unlink-dir vendor の symlink解除により symlink先の実体ファイルは消えない"
else
  fail "ケース9b: --unlink-dir vendor の symlink解除により symlink先の実体ファイルは消えない" \
    "marker.txt が消えました: ${CLW_VENDOR_REAL_TARGET}"
fi

# --- ケース9c（Task #109）: --unlink-dir を複数指定できる（vendor と .venv の両方を解除） ---
CLW_MULTI_REPO="$(make_temp_repo)"
CLW_MULTI_DEFAULT_BRANCH="$(cd "$CLW_MULTI_REPO" && git rev-parse --abbrev-ref HEAD)"
CLW_MULTI_EPIC_BRANCH="epic/testmulti/109"
CLW_MULTI_BASE="$(ml_head_of "$CLW_MULTI_REPO" HEAD)"
ml_branch_from "$CLW_MULTI_REPO" "$CLW_MULTI_EPIC_BRANCH" "$CLW_MULTI_BASE"
ml_commit_file "$CLW_MULTI_REPO" "epic.txt" "epic base\n" "epic base commit"
CLW_MULTI_EPIC_TIP="$(ml_head_of "$CLW_MULTI_REPO" "$CLW_MULTI_EPIC_BRANCH")"
ml_branch_from "$CLW_MULTI_REPO" "lane-multi" "$CLW_MULTI_EPIC_TIP"
ml_commit_file "$CLW_MULTI_REPO" "multi.txt" "multi\n" "lane multi change"
(cd "$CLW_MULTI_REPO" && git checkout -q "$CLW_MULTI_EPIC_BRANCH" \
  && git merge -q --no-edit lane-multi \
  && git checkout -q "$CLW_MULTI_DEFAULT_BRANCH") >/dev/null 2>&1
clw_add_worktree "$CLW_MULTI_REPO" "${CLW_MULTI_REPO}/.claude/worktrees/lane-multi" "lane-multi"

CLW_MULTI_VENDOR_TARGET="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-clw-multivendor.XXXXXX")"
CLW_MULTI_VENV_TARGET="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-clw-multivenv.XXXXXX")"
printf 'do not delete me (vendor)\n' > "${CLW_MULTI_VENDOR_TARGET}/marker.txt"
printf 'do not delete me (venv)\n' > "${CLW_MULTI_VENV_TARGET}/marker.txt"
(cd "${CLW_MULTI_REPO}/.claude/worktrees/lane-multi" \
  && ln -s "$CLW_MULTI_VENDOR_TARGET" vendor \
  && ln -s "$CLW_MULTI_VENV_TARGET" .venv) >/dev/null 2>&1

run_cleanup "$CLW_MULTI_REPO" --epic-branch "$CLW_MULTI_EPIC_BRANCH" \
  --lane-branch lane-multi --unlink-dir vendor --unlink-dir .venv >/dev/null
CLW_MULTI_EXIT=$?

assert_exit_code "ケース9c: --unlink-dir を複数指定しても exit 0" 0 "$CLW_MULTI_EXIT"

assert_eq "ケース9c: --unlink-dir を複数指定するとレーンworktreeが削除される" \
  "no" "$(clw_worktree_exists "$CLW_MULTI_REPO" lane-multi)"

if [ -f "${CLW_MULTI_VENDOR_TARGET}/marker.txt" ] && [ -f "${CLW_MULTI_VENV_TARGET}/marker.txt" ]; then
  pass "ケース9c: --unlink-dir を複数指定すると両方の symlink 先の実体ファイルが残る"
else
  fail "ケース9c: --unlink-dir を複数指定すると両方の symlink 先の実体ファイルが残る" \
    "vendor marker exists=$([ -f "${CLW_MULTI_VENDOR_TARGET}/marker.txt" ] && echo yes || echo no), \
venv marker exists=$([ -f "${CLW_MULTI_VENV_TARGET}/marker.txt" ] && echo yes || echo no)"
fi

# --- ケース10: 引数バリデーション（引数エラーは exit 2） ---
CLW_REPO_ARGS="$(make_temp_repo)"

run_cleanup "$CLW_REPO_ARGS" >/dev/null 2>&1
assert_exit_code "引数なしは exit 2" 2 "$?"

run_cleanup "$CLW_REPO_ARGS" --lane-branch dummy >/dev/null 2>&1
assert_exit_code "--epic-branch 省略は exit 2" 2 "$?"

run_cleanup "$CLW_REPO_ARGS" --epic-branch main >/dev/null 2>&1
assert_exit_code "--lane-branch 省略は exit 2" 2 "$?"

run_cleanup "$CLW_REPO_ARGS" --epic-branch >/dev/null 2>&1
assert_exit_code "--epic-branch に値なしは exit 2" 2 "$?"

run_cleanup "$CLW_REPO_ARGS" --epic-branch main --lane-branch >/dev/null 2>&1
assert_exit_code "--lane-branch に値なしは exit 2" 2 "$?"

run_cleanup "$CLW_REPO_ARGS" --epic-branch main --lane-branch dummy --unknown-option >/dev/null 2>&1
assert_exit_code "未知のオプションは exit 2" 2 "$?"

run_cleanup "$CLW_REPO_ARGS" --epic-branch main --lane-branch dummy --unlink-dir >/dev/null 2>&1
assert_exit_code "--unlink-dir に値なしは exit 2（Task #109）" 2 "$?"

# ---------------------------------------------------------------------------
# H2（Task #94）: 準備コマンドをレーンの作業ディレクトリで初回1回だけ実行させる
#
# 「Epic 開始時に1回」は Epic 専用 worktree にしか効かず、generator の isolation
# worktree（レーンの作業ディレクトリ）には及ばない。にもかかわらず旧
# `core/roles/generator.md` は「タスクごとに自前で再実行しない」と単独で禁止しており、
# generator が自力で補うことも抑止していた（詳細は docs/dev-workflow-handover.md のH2節）。
# ここでは「worktreeごとに1回」の意味に改めたことを機械的に検査する。
# ---------------------------------------------------------------------------

echo ""
echo "== H2: 準備コマンドをレーンの作業ディレクトリで初回1回だけ実行させる（回帰防止 #94） =="

# --- skills/run/SKILL.md: Step 3 雛形にPREP_CMDの埋め込みと「初回1回だけ」の指示がある ---
H2_RS_STEP3="$(awk '/^### Step 3:/{f=1} /^### Step 4:/{f=0} f' "$RUN_SKILL_FLAT")"

case "$H2_RS_STEP3" in
  *'PREP_CMD'*'初回1回だけ'*)
    pass "SKILL.md: Step 3 雛形に PREP_CMD の埋め込みと『初回1回だけ』実行させる指示がある（#94）" ;;
  *)
    fail "SKILL.md: Step 3 雛形に PREP_CMD の埋め込みと『初回1回だけ』実行させる指示がある（#94）" \
      "$H2_RS_STEP3" ;;
esac

case "$H2_RS_STEP3" in
  *'空の場合はこの行を出さない'*)
    pass "SKILL.md: Step 3 雛形に『準備コマンド節が無い場合はこの行を出さない』旨（後方互換）がある（#94）" ;;
  *)
    fail "SKILL.md: Step 3 雛形に『準備コマンド節が無い場合はこの行を出さない』旨（後方互換）がある（#94）" \
      "$H2_RS_STEP3" ;;
esac

case "$H2_RS_STEP3" in
  *'2回目以降は実行しない'*)
    pass "SKILL.md: Step 3 雛形に『同一worktree内で2回目以降は実行しない』旨がある（#94）" ;;
  *)
    fail "SKILL.md: Step 3 雛形に『同一worktree内で2回目以降は実行しない』旨がある（#94）" \
      "$H2_RS_STEP3" ;;
esac

# --- skills/run/SKILL.md: Epic開始時1回を残す理由（キャッシュ温め・統合ゲート用Epic worktree配置）が明記されている ---
H2_RS_PREP="$(awk '/^#### プロジェクト固有の準備コマンド/{f=1} /^### サンドボックスへのコマンド投入/{f=0} f' "$RUN_SKILL_FLAT")"

case "$H2_RS_PREP" in
  *'ビルドキャッシュを温める'*'統合ゲート'*'Epic worktree に生成物を配置'*)
    pass "SKILL.md: Epic開始時1回を残す理由（キャッシュ温め・統合ゲート用Epic worktree配置）が明記されている（#94）" ;;
  *)
    fail "SKILL.md: Epic開始時1回を残す理由（キャッシュ温め・統合ゲート用Epic worktree配置）が明記されている（#94）" \
      "$H2_RS_PREP" ;;
esac

# --- skills-codex/dev-workflow-run/SKILL.md: Step 3 の generator プロンプトに準備コマンドを渡していない ---
H2_CRS_STEP3="$(awk '/^### Step 3:/{f=1} /^#### トークン消費の記録/{f=0} f' "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"

if printf '%s\n' "$H2_CRS_STEP3" | grep -Fq 'PREP_CMD'; then
  fail "SKILL.md(codex): Step 3 の generator プロンプトに PREP_CMD を渡していない（#94）" \
    "$H2_CRS_STEP3"
else
  pass "SKILL.md(codex): Step 3 の generator プロンプトに PREP_CMD を渡していない（#94）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: 渡さない理由（Epic worktreeで直接作業するため）が明記されている ---
H2_CRS_PREP="$(awk '/^## サンドボックスの準備/{f=1} /^## 自律実行の開始を記録/{f=0} f' "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"

case "$H2_CRS_PREP" in
  *'generator にはこの準備コマンドを渡さない'*'二重実行'*)
    pass "SKILL.md(codex): 準備コマンドをgeneratorに渡さない理由（二重実行の回避）が明記されている（#94）" ;;
  *)
    fail "SKILL.md(codex): 準備コマンドをgeneratorに渡さない理由（二重実行の回避）が明記されている（#94）" \
      "見つかりませんでした" ;;
esac

# --- core/roles/generator.md: 「タスクごとに自前で再実行しない」という単独の禁止表現が消えている ---
if grep -Fq -- '**タスクごとに自前で再実行しない。**' "${REPO_ROOT}/core/roles/generator.md"; then
  fail "core/roles/generator.md: 「タスクごとに自前で再実行しない」という単独の禁止表現が消えている（#94）" \
    "$(grep -n -- 'タスクごとに自前で再実行しない' "${REPO_ROOT}/core/roles/generator.md")"
else
  pass "core/roles/generator.md: 「タスクごとに自前で再実行しない」という単独の禁止表現が消えている（#94）"
fi

# --- core/roles/generator.md: 「worktreeごとに1回」を意味する記述に置き換わっている ---
# 節の終端は「### 1. 」（review#100 で準備コマンド節を「0. 」の後ろへ移したため、
# 「0. 」は準備コマンド節より前にある。「0. 」を終端にすると節を抽出できない）
GEN_PREP_SECTION="$(awk '/^### プロジェクト固有の準備/{f=1} /^### 1\. /{f=0} f' "${REPO_ROOT}/core/roles/generator.md")"

case "$GEN_PREP_SECTION" in
  *'初回1回だけ'*'同一 worktree 内で2回目以降は実行しない'*)
    pass "core/roles/generator.md: 『worktreeごとに1回』を意味する記述（初回1回だけ・2回目以降は実行しない）がある（#94）" ;;
  *)
    fail "core/roles/generator.md: 『worktreeごとに1回』を意味する記述（初回1回だけ・2回目以降は実行しない）がある（#94）" \
      "$GEN_PREP_SECTION" ;;
esac

case "$GEN_PREP_SECTION" in
  *'渡されていない場合'*'実行しない'*)
    pass "core/roles/generator.md: 準備コマンドが渡されていない場合は自分で探して実行しない旨が残っている（#94）" ;;
  *)
    fail "core/roles/generator.md: 準備コマンドが渡されていない場合は自分で探して実行しない旨が残っている（#94）" \
      "$GEN_PREP_SECTION" ;;
esac

# --- core/roles/generator.md: #89 が入れた「0. 」節（ベース合わせ）が引き続き直後に存在し、壊れていない ---
GEN_STEP0_H2="$(awk '/^### 0\. /{f=1} /^### 1\. /{f=0} f' "${REPO_ROOT}/core/roles/generator.md")"

assert_order "core/roles/generator.md: H2向け編集後も「0. 」節のコマンド列の順序（#89）が保たれている（#94）" \
  "$(printf '%s\n' "$GEN_STEP0_H2" | awk '/^```bash/{f=1;next} /^```/{f=0} f')" \
  "git status --short" "git merge --ff-only" "git merge-base --is-ancestor" "git log --oneline -1"

# --- README.md: 「この1回の準備がウェーブ・レーンをまたいで効く」が消えている ---
if grep -Fq -- 'この1回の準備がウェーブ・レーンをまたいで効く' "${REPO_ROOT}/README.md"; then
  fail "README.md: 『この1回の準備がウェーブ・レーンをまたいで効く』という誤った記述が消えている（#94）" \
    "$(grep -n -- 'この1回の準備がウェーブ・レーンをまたいで効く' "${REPO_ROOT}/README.md")"
else
  pass "README.md: 『この1回の準備がウェーブ・レーンをまたいで効く』という誤った記述が消えている（#94）"
fi

# --- README.md: 準備コマンド節の他の記述（実際の適用範囲）に書き換わっている ---
README_PREP_SECTION="$(awk '/^### Epic の `## 準備コマンド` 節/{f=1} /^## YOLOモード/{f=0} f' "${REPO_ROOT}/README.md")"

case "$README_PREP_SECTION" in
  *'Epic 専用 worktree だけ'*)
    pass "README.md: 準備コマンド節の適用範囲がEpic専用worktreeだけである旨に書き換わっている（#94）" ;;
  *)
    fail "README.md: 準備コマンド節の適用範囲がEpic専用worktreeだけである旨に書き換わっている（#94）" \
      "$README_PREP_SECTION" ;;
esac

# ---------------------------------------------------------------------------
# review#100: core/roles/generator.md の準備コマンド節が「0. 」節より後ろにある
#
# #94 時点の並びは「準備コマンド節 → 0.（ベース合わせ） → 1.」だった。上から読む
# generator は準備を WAVE_BASE に合わせる前に実行してしまうため、順序を
# 「0. → 準備コマンド節 → 1.」へ入れ替えた。この順序が壊れないことを機械的に固定する。
# ---------------------------------------------------------------------------

echo ""
echo "== review#100: 準備コマンド節が「0. 」節より後にある（回帰防止） =="

GEN_FLOW_SECTION="$(awk '/^## 作業フロー/{f=1;next} /^## コーディングルール/{f=0} f' "${REPO_ROOT}/core/roles/generator.md")"

assert_order "core/roles/generator.md: 「## 作業フロー」節で 0.（ベース合わせ）→ プロジェクト固有の準備 → 1.（タスク確認）の順で並んでいる（#100）" \
  "$GEN_FLOW_SECTION" \
  "### 0. 渡されたベースにHEADを合わせる" \
  "### プロジェクト固有の準備は自分の作業ディレクトリで初回1回だけ実行する" \
  "### 1. タスクの確認"

case "$GEN_PREP_SECTION" in
  *'0. 渡されたベースにHEADを合わせる'*'終わってから実行する'*)
    pass "core/roles/generator.md: 準備コマンド節に『0.が終わってから実行する』旨の注記がある（#100）" ;;
  *)
    fail "core/roles/generator.md: 準備コマンド節に『0.が終わってから実行する』旨の注記がある（#100）" \
      "$GEN_PREP_SECTION" ;;
esac

# ---------------------------------------------------------------------------
# review#99: H1・H2 が否定した旧文言が、正本・生成物のいずれにも残っていない
#
# #94/#89 時点の退行防止テストは skills/run/SKILL.md・core/roles/generator.md・README.md の
# 3ファイル限定だった。同じ内容を連結する core/instructions.md が対象外だったため、
# 生成物（agents/*.md・codex-agents/*.toml）内に新旧の記述が同居する状態を検出できなかった。
# 検査対象を「core/instructions.md を連結する全生成物」まで広げ、同じ見落としを再発させない。
# ---------------------------------------------------------------------------

echo ""
echo "== review#99: core/instructions.md と生成物から旧文言が消えている（回帰防止） =="

# for/whileのパイプはbashではサブシェルになりPASS/FAILカウンタが親シェルに伝播しない
# ため、配列 + for（サブシェルを作らない）で回す。
REVIEW99_OLD_PHRASES=(
  "検証1回だけを行う"
  "ウェーブ・レーンをまたいで効く"
  "タスクごとにこの準備を再実行しない"
)

REVIEW99_FILES=(
  "core/instructions.md"
  "docs/dev-workflow-multi-vendor-guide.md"
  "core/roles/generator.md"
  "skills/run/SKILL.md"
  "README.md"
  "agents/generator.md"
  "agents/evaluator.md"
  "agents/planner.md"
  "codex-agents/generator.toml"
  "codex-agents/evaluator.toml"
  "codex-agents/planner.toml"
)

for f in "${REVIEW99_FILES[@]}"; do
  for phrase in "${REVIEW99_OLD_PHRASES[@]}"; do
    if grep -Fq -- "$phrase" "${REPO_ROOT}/${f}"; then
      fail "${f}: 旧文言『${phrase}』が消えている（#99）" \
        "$(grep -n -- "$phrase" "${REPO_ROOT}/${f}")"
    else
      pass "${f}: 旧文言『${phrase}』が消えている（#99）"
    fi
  done
done

# ---------------------------------------------------------------------------
# H6-b（Task #95）: run の後片付けで当該 Epic 分のレーン worktree を削除する
#
# 前提タスク #93 で新設した scripts/cleanup-lane-worktrees.sh を run のクリーンアップ節に
# 結線したことを機械的に検査する。スクリプト自体の振る舞い（削除/skip の判定）は #93 の
# テスト（上の「cleanup-lane-worktrees.sh」節）で検証済みなので、ここでは SKILL.md /
# README.md の記述内容だけを見る。
# ---------------------------------------------------------------------------

echo ""
echo "== H6-b: runの後片付けで当該Epic分のレーンworktreeを削除する（#95） =="

# --- skills/run/SKILL.md: 「isolation worktree はハーネスが自動整理する」という誤った
#     断定が消えている（#93以前の原文そのまま） ---
if grep -Fq -- 'isolation worktree（`.claude/worktrees/agent-*`）はハーネスが自動整理する' \
  "$RUN_SKILL_FLAT"; then
  fail "SKILL.md: 『isolation worktreeはハーネスが自動整理する』という誤った記述が消えている（#95）" \
    "$(grep -n -- 'ハーネスが自動整理する' "$RUN_SKILL_FLAT")"
else
  pass "SKILL.md: 『isolation worktreeはハーネスが自動整理する』という誤った記述が消えている（#95）"
fi

# --- skills/run/SKILL.md: 「worktree クリーンアップ」節を切り出す ---
# 平坦化ビューでは、各参照ファイルの `# ...（run スキル参照資料）` 見出しが節の切れ目になる。
# 「## worktree クリーンアップ」の終端見出しは参照ファイル側には現れないため、参照ファイルの
# 先頭見出し（`# ...（run スキル参照資料）`）も終端に含める（コードブロック内の `# コメント`
# を終端と誤認しないよう、見出し文言まで含めて照合する）。
H6_RS_CLEANUP="$(awk '/^## worktree クリーンアップ/{f=1} /^## 自律動作ポリシー（YOLOモード）/{f=0} /^# .*run スキル参照資料/{f=0} f' \
  "$RUN_SKILL_FLAT")"

if [ -z "$H6_RS_CLEANUP" ]; then
  fail "SKILL.md: 『worktree クリーンアップ』節が見つかる（前提）（#95）" "節が空でした"
else
  pass "SKILL.md: 『worktree クリーンアップ』節が見つかる（前提）（#95）"
fi

# --- クリーンアップ節が cleanup-lane-worktrees.sh を --unlink-dir 付きで呼ぶ手順を案内している
#     （Task #109。Epic本文の「共有ディレクトリ」節で宣言された名前を渡す） ---
case "$H6_RS_CLEANUP" in
  *'cleanup-lane-worktrees.sh'*'--unlink-dir'*)
    pass "SKILL.md: クリーンアップ節が cleanup-lane-worktrees.sh を --unlink-dir 付きで呼ぶ手順を案内している（#109）" ;;
  *)
    fail "SKILL.md: クリーンアップ節が cleanup-lane-worktrees.sh を --unlink-dir 付きで呼ぶ手順を案内している（#109）" \
      "$H6_RS_CLEANUP" ;;
esac

# --- 「共有ディレクトリ」節が無い場合は --unlink-dir を付けない旨が明記されている（#109） ---
case "$H6_RS_CLEANUP" in
  *'節が無い'*'--unlink-dir'*'付けず'*)
    pass "SKILL.md: 『共有ディレクトリ』節が無い場合は --unlink-dir を付けない旨が明記されている（#109）" ;;
  *)
    fail "SKILL.md: 『共有ディレクトリ』節が無い場合は --unlink-dir を付けない旨が明記されている（#109）" \
      "$H6_RS_CLEANUP" ;;
esac

# --- クリーンアップ節が cleanup-lane-worktrees.sh を --epic-branch / --lane-branch 付きで呼ぶ ---
case "$H6_RS_CLEANUP" in
  *'cleanup-lane-worktrees.sh'*'--epic-branch'*'--lane-branch'*)
    pass "SKILL.md: クリーンアップ節が cleanup-lane-worktrees.sh を --epic-branch と --lane-branch 付きで呼んでいる（#95）" ;;
  *)
    fail "SKILL.md: クリーンアップ節が cleanup-lane-worktrees.sh を --epic-branch と --lane-branch 付きで呼んでいる（#95）" \
      "$H6_RS_CLEANUP" ;;
esac

# --- 削除に失敗してもrun全体を落とさない（|| true 等） ---
case "$H6_RS_CLEANUP" in
  *'cleanup-lane-worktrees.sh'*'|| true'*)
    pass "SKILL.md: cleanup-lane-worktrees.sh の呼び出しが失敗してもrun全体を止めない（|| true）（#95）" ;;
  *)
    fail "SKILL.md: cleanup-lane-worktrees.sh の呼び出しが失敗してもrun全体を止めない（|| true）（#95）" \
      "$H6_RS_CLEANUP" ;;
esac

# --- 他Epicのworktreeには触れない旨が明記されている ---
case "$H6_RS_CLEANUP" in
  *'他Epic'*'触れない'*)
    pass "SKILL.md: 他Epicのレーンworktreeには触れない旨が明記されている（#95）" ;;
  *)
    fail "SKILL.md: 他Epicのレーンworktreeには触れない旨が明記されている（#95）" \
      "$H6_RS_CLEANUP" ;;
esac

# --- 取り込めなかったレーンは削除されない（not-merged）旨が明記されている ---
case "$H6_RS_CLEANUP" in
  *'not-merged'*)
    pass "SKILL.md: 取り込めなかったレーンは削除されない（not-merged）旨が明記されている（#95）" ;;
  *)
    fail "SKILL.md: 取り込めなかったレーンは削除されない（not-merged）旨が明記されている（#95）" \
      "$H6_RS_CLEANUP" ;;
esac

# --- 人間向けの棚卸し導線（git worktree list と --dry-run）が案内されている ---
case "$H6_RS_CLEANUP" in
  *'git worktree list'*'--dry-run'*)
    pass "SKILL.md: 人間向けの棚卸し導線（git worktree list と --dry-run）が案内されている（#95）" ;;
  *)
    fail "SKILL.md: 人間向けの棚卸し導線（git worktree list と --dry-run）が案内されている（#95）" \
      "$H6_RS_CLEANUP" ;;
esac

# --- 既存の警告（symlink解除・Epic専用worktreeの削除）が消えずに残っている（統合による破壊が無いこと） ---
case "$H6_RS_CLEANUP" in
  *'symlink越しに実体ファイルが削除される'*'git worktree remove "$EPIC_WT" --force'*)
    pass "SKILL.md: 既存のsymlink警告・Epic専用worktree削除の記述が壊れずに残っている（#95）" ;;
  *)
    fail "SKILL.md: 既存のsymlink警告・Epic専用worktree削除の記述が壊れずに残っている（#95）" \
      "$H6_RS_CLEANUP" ;;
esac

# --- skills/run/SKILL.md に駆動先プロジェクト固有の値（master 等）をハードコードしていない ---
case "$H6_RS_CLEANUP" in
  *'master'*)
    fail "SKILL.md: クリーンアップ節に駆動先プロジェクト固有の値（master）をハードコードしていない（#95）" \
      "$H6_RS_CLEANUP" ;;
  *)
    pass "SKILL.md: クリーンアップ節に駆動先プロジェクト固有の値（master）をハードコードしていない（#95）" ;;
esac

# --- skills-codex/dev-workflow-run/SKILL.md: Codexでは該当なしである旨が明記されている ---
H6_CRS_CLEANUP="$(awk '/^## クリーンアップ（worktree）/{f=1} /^## 自律動作ポリシー/{f=0} f' \
  "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"

case "$H6_CRS_CLEANUP" in
  *'該当なし'*'サブエージェント専用worktree'*)
    pass "SKILL.md(codex): レーンworktreeの片付けはCodexでは該当なしである旨が明記されている（#95）" ;;
  *)
    fail "SKILL.md(codex): レーンworktreeの片付けはCodexでは該当なしである旨が明記されている（#95）" \
      "$H6_CRS_CLEANUP" ;;
esac

# --- skills-codex/dev-workflow-run/SKILL.md: 既存のEpic worktree削除手順は壊れていない ---
case "$H6_CRS_CLEANUP" in
  *'git worktree remove ".codex/worktrees/${EPIC_NUM}" --force'*'git worktree prune'*)
    pass "SKILL.md(codex): 既存のEpic worktree削除手順（node_modules symlink解除・remove・prune）が壊れずに残っている（#95）" ;;
  *)
    fail "SKILL.md(codex): 既存のEpic worktree削除手順（node_modules symlink解除・remove・prune）が壊れずに残っている（#95）" \
      "$H6_CRS_CLEANUP" ;;
esac

# --- README.md: 「worktree運用の注意」節にレーンworktreeの蓄積とcleanup-lane-worktrees.shが書かれている ---
H6_README_SECTION="$(awk '/^### worktree運用の注意/{f=1} /^## 並列実行（ウェーブ実行）/{f=0} f' \
  "${REPO_ROOT}/README.md")"

if [ -z "$H6_README_SECTION" ]; then
  fail "README.md: 『worktree運用の注意』節が見つかる（前提）（#95）" "節が空でした"
else
  pass "README.md: 『worktree運用の注意』節が見つかる（前提）（#95）"
fi

case "$H6_README_SECTION" in
  *'蓄積'*'cleanup-lane-worktrees.sh'*)
    pass "README.md: 『worktree運用の注意』節にレーンworktreeの蓄積とcleanup-lane-worktrees.shが書かれている（#95）" ;;
  *)
    fail "README.md: 『worktree運用の注意』節にレーンworktreeの蓄積とcleanup-lane-worktrees.shが書かれている（#95）" \
      "$H6_README_SECTION" ;;
esac

# --- README.md: 既存のsymlink警告（#87由来）は消えずに残っている ---
case "$H6_README_SECTION" in
  *'symlink越しにメインリポの実体ファイルを削除する'*)
    pass "README.md: 既存のsymlink警告が壊れずに残っている（#95）" ;;
  *)
    fail "README.md: 既存のsymlink警告が壊れずに残っている（#95）" \
      "$H6_README_SECTION" ;;
esac

# ---------------------------------------------------------------------------
# H3（Task #96）: generator が `cd` で作業ディレクトリを変えないことの明示
# ---------------------------------------------------------------------------

echo ""
echo "== H3: cdで作業ディレクトリを変えないことを明記する（#96） =="

# --- core/roles/generator.md: 「#### `cd` で作業ディレクトリを変えない」節が存在する ---
H3_GEN_CD_SECTION="$(awk '/^#### `cd` で作業ディレクトリを変えない/{f=1} /^#### シェルスクリプトを新規生成したら/{f=0} f' \
  "${REPO_ROOT}/core/roles/generator.md")"

if [ -z "$H3_GEN_CD_SECTION" ]; then
  fail "core/roles/generator.md: 『cdで作業ディレクトリを変えない』節が見つかる（#96）" "節が空でした"
else
  pass "core/roles/generator.md: 『cdで作業ディレクトリを変えない』節が見つかる（#96）"
fi

# --- core/roles/generator.md: sandbox-exec.shが呼び出し元cwdからworkdirを解決し、cdがそれを上書きする旨が理由として書かれている ---
case "$H3_GEN_CD_SECTION" in
  *'呼び出し元 cwd'*'workdir'*'上書き'*)
    pass "core/roles/generator.md: workdirが呼び出し元cwdから解決されcdが上書きする旨が理由として書かれている（#96）" ;;
  *)
    fail "core/roles/generator.md: workdirが呼び出し元cwdから解決されcdが上書きする旨が理由として書かれている（#96）" \
      "$H3_GEN_CD_SECTION" ;;
esac

# --- core/roles/generator.md: 自分の変更を検証しないままゲートが緑になる危険が明示されている ---
case "$H3_GEN_CD_SECTION" in
  *'自分の変更'*'検証されていない'*)
    pass "core/roles/generator.md: 自分の変更が検証されないまま緑になる危険が明示されている（#96）" ;;
  *)
    fail "core/roles/generator.md: 自分の変更が検証されないまま緑になる危険が明示されている（#96）" \
      "$H3_GEN_CD_SECTION" ;;
esac

# --- core/roles/generator.md: 悪い例・良い例が書かれている ---
case "$H3_GEN_CD_SECTION" in
  *'悪い例'*'cd /workspace'*'良い例'*)
    pass "core/roles/generator.md: 悪い例・良い例が書かれている（#96）" ;;
  *)
    fail "core/roles/generator.md: 悪い例・良い例が書かれている（#96）" \
      "$H3_GEN_CD_SECTION" ;;
esac

# --- core/roles/generator.md: サブディレクトリを対象にする場合の代替手段（コマンド側の相対指定）が書かれている ---
case "$H3_GEN_CD_SECTION" in
  *'サブディレクトリ'*'相対指定'*'make -C'*)
    pass "core/roles/generator.md: サブディレクトリを対象にする場合の代替手段が書かれている（#96）" ;;
  *)
    fail "core/roles/generator.md: サブディレクトリを対象にする場合の代替手段が書かれている（#96）" \
      "$H3_GEN_CD_SECTION" ;;
esac

# --- skills/run/SKILL.md: Step 3 の雛形に同趣旨の1行がある ---
H3_RS_STEP3="$(awk '/^### Step 3:/{f=1} /^### Step 4:/{f=0} f' "$RUN_SKILL_FLAT")"

case "$H3_RS_STEP3" in
  *'サンドボックスに渡すコマンドの中で `cd`'*'workdir'*)
    pass "SKILL.md: Step 3 の雛形に『cdで作業ディレクトリを変えない』旨の1行がある（#96）" ;;
  *)
    fail "SKILL.md: Step 3 の雛形に『cdで作業ディレクトリを変えない』旨の1行がある（#96）" \
      "$H3_RS_STEP3" ;;
esac

# --- skills/run/SKILL.md: 駆動先プロジェクト固有の値をハードコードしていない（epicXX・汎用コマンド名のみ） ---
if printf '%s\n' "$H3_RS_STEP3" | grep -Eq 'cd .*&& (go |make |npm )'; then
  fail "SKILL.md: Step 3 の雛形に駆動先プロジェクト固有のcd例をハードコードしていない（#96）" \
    "$H3_RS_STEP3"
else
  pass "SKILL.md: Step 3 の雛形に駆動先プロジェクト固有のcd例をハードコードしていない（#96）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: Step 3 のプロンプトが同趣旨・core/roles/generator.mdと揃った表現になっている ---
H3_CRS_STEP3="$(awk '/^### Step 3:/{f=1} /^#### トークン消費の記録/{f=0} f' \
  "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"

case "$H3_CRS_STEP3" in
  *'ここから移動しないこと'*'サンドボックスに渡すコマンドの中で `cd`'*'workdir'*)
    pass "SKILL.md(codex): Step 3 のプロンプトがcore/roles/generator.mdと揃った表現でcd禁止を明記している（#96）" ;;
  *)
    fail "SKILL.md(codex): Step 3 のプロンプトがcore/roles/generator.mdと揃った表現でcd禁止を明記している（#96）" \
      "$H3_CRS_STEP3" ;;
esac

# --- scripts/sandbox-exec.sh: このタスクでは変更しない（H3の「やらないこと」） ---
H3_SANDBOX_EXEC="${REPO_ROOT}/scripts/sandbox-exec.sh"
if [ -f "$H3_SANDBOX_EXEC" ]; then
  pass "scripts/sandbox-exec.sh: ファイルが存在する（変更対象外であることの前提確認）（#96）"
else
  fail "scripts/sandbox-exec.sh: ファイルが存在する（変更対象外であることの前提確認）（#96）" \
    "ファイルが見つかりません"
fi

# ---------------------------------------------------------------------------
# H5-b（Task #97）: レーン内ゲート・統合ゲートのSKIP計測をcount-skips.shに置き換える
#
# `skills/run/SKILL.md:388`（修正前）は「SKIP されたテストがあれば件数と内容を報告に含める
# こと」とだけ指示し、数え方を示していなかった（H5節）。前提タスク #91 で新設した
# scripts/count-skips.sh（本タスクでは変更しない）を呼び出し側に結線する。
# scripts/count-skips.sh 自体の振る舞い（Go/jest/pytest判定・--pattern・
# DEV_WORKFLOW_SKIP_PATTERN・引数エラー）は #91 のテスト（上の「count-skips.sh」節）で
# 検証済みなので、ここでは呼び出し側（generator.md / SKILL.md / SKILL.md(codex) /
# README.md）の記述内容だけを見る。
# ---------------------------------------------------------------------------

echo ""
echo "== H5-b: レーン内ゲート・統合ゲートのSKIP計測をcount-skips.shに置き換える（#97） =="

# --- scripts/count-skips.sh はこのタスクでは変更しない（#91の成果物のまま） ---
if [ -f "${REPO_ROOT}/scripts/count-skips.sh" ]; then
  pass "scripts/count-skips.sh: ファイルが存在する（#91の成果物。本タスクでは変更しない前提）（#97）"
else
  fail "scripts/count-skips.sh: ファイルが存在する（#91の成果物。本タスクでは変更しない前提）（#97）" \
    "ファイルが見つかりません"
fi

# --- core/roles/generator.md: 「#### SKIP を通過扱いにしない」節を切り出す ---
H97_GEN_SKIP="$(awk '/^#### SKIP を通過扱いにしない/{f=1} /^### 5\. コミット/{f=0} f' \
  "${REPO_ROOT}/core/roles/generator.md")"

if [ -z "$H97_GEN_SKIP" ]; then
  fail "core/roles/generator.md: 『SKIP を通過扱いにしない』節が見つかる（前提）（#97）" "節が空でした"
else
  pass "core/roles/generator.md: 『SKIP を通過扱いにしない』節が見つかる（前提）（#97）"
fi

case "$H97_GEN_SKIP" in
  *'tail'*'目視'*'てはならない'*'count-skips.sh'*)
    pass "core/roles/generator.md: SKIP節が tail の目視を禁止しcount-skips.shで数える手順になっている（#97）" ;;
  *)
    fail "core/roles/generator.md: SKIP節が tail の目視を禁止しcount-skips.shで数える手順になっている（#97）" \
      "$H97_GEN_SKIP" ;;
esac

case "$H97_GEN_SKIP" in
  *'skips=unknown'*'0件」と報告してはならない'*'DEV_WORKFLOW_SKIP_PATTERN'*)
    pass "core/roles/generator.md: skips=unknownを『0件』と報告してはならない旨が明記されている（#97）" ;;
  *)
    fail "core/roles/generator.md: skips=unknownを『0件』と報告してはならない旨が明記されている（#97）" \
      "$H97_GEN_SKIP" ;;
esac

# --- core/roles/generator.md: 完了報告テンプレートのSKIP件数欄がcount-skips.shの出力キー（skips=）
#     と同じ命名になっている（Task #156で「count-skips.shの出力をそのまま貼る」形から
#     「証跡ファイルへの参照+1行」形へ変わったため、キー名の一致で検証する） ---
H97_GEN_REPORT="$(awk '/^## 完了報告/{f=1} f' "${REPO_ROOT}/core/roles/generator.md")"

case "$H97_GEN_REPORT" in
  *'skips=[件数|unknown]'*)
    pass "core/roles/generator.md: 完了報告テンプレートのSKIP件数欄がcount-skips.shの出力キー（skips=）と同じ命名になっている（#97/#156）" ;;
  *)
    fail "core/roles/generator.md: 完了報告テンプレートのSKIP件数欄がcount-skips.shの出力キー（skips=）と同じ命名になっている（#97/#156）" \
      "$H97_GEN_REPORT" ;;
esac

# --- skills/run/SKILL.md: 「SKIP されたテストがあれば件数と内容を報告に含めること」という
#     数え方の指定が無い表現が消えている（grepで0件。H5の受け入れ条件） ---
if grep -Fq -- 'SKIP されたテストがあれば件数と内容を報告に含めること' "$RUN_SKILL_FLAT"; then
  fail "SKILL.md: 数え方の指定が無い旧表現『SKIP されたテストがあれば件数と内容を報告に含めること』が消えている（#97）" \
    "$(grep -n -- 'SKIP されたテストがあれば件数と内容を報告に含めること' "$RUN_SKILL_FLAT")"
else
  pass "SKILL.md: 数え方の指定が無い旧表現『SKIP されたテストがあれば件数と内容を報告に含めること』が消えている（#97）"
fi

# --- skills/run/SKILL.md: Step 3 雛形がcount-skips.shを使う手順になっている ---
H97_RS_STEP3="$(awk '/^### Step 3:/{f=1} /^### Step 4:/{f=0} f' "$RUN_SKILL_FLAT")"

case "$H97_RS_STEP3" in
  *'tail'*'count-skips.sh'*'tee'*)
    pass "SKILL.md: Step 3 雛形がテスト出力をteeで保存しcount-skips.shで数える手順になっている（#97）" ;;
  *)
    fail "SKILL.md: Step 3 雛形がテスト出力をteeで保存しcount-skips.shで数える手順になっている（#97）" \
      "$H97_RS_STEP3" ;;
esac

case "$H97_RS_STEP3" in
  *'skips=unknown'*'0件」と報告してはならない'*'DEV_WORKFLOW_SKIP_PATTERN'*)
    pass "SKILL.md: Step 3 雛形がskips=unknownを『0件』と報告してはならない旨を明記している（#97）" ;;
  *)
    fail "SKILL.md: Step 3 雛形がskips=unknownを『0件』と報告してはならない旨を明記している（#97）" \
      "$H97_RS_STEP3" ;;
esac

# --- skills/run/SKILL.md: SKIP_PATTERN（Epic本文の「## SKIPパターン」節）の抽出手順がある ---
H97_RS_SKIPPATTERN="$(awk '/^## 起動時の確認/{f=1} /^## 2エージェント体制/{f=0} f' \
  "$RUN_SKILL_FLAT")"

case "$H97_RS_SKIPPATTERN" in
  *'## SKIPパターン'*'DEV_WORKFLOW_SKIP_PATTERN'*)
    pass "SKILL.md: Epic本文の『## SKIPパターン』節を読みDEV_WORKFLOW_SKIP_PATTERNとして保持する手順がある（#97）" ;;
  *)
    fail "SKILL.md: Epic本文の『## SKIPパターン』節を読みDEV_WORKFLOW_SKIP_PATTERNとして保持する手順がある（#97）" \
      "$H97_RS_SKIPPATTERN" ;;
esac

# --- skills/run/SKILL.md: 「Epic 統合ゲート」節（フルスイートはEpicにつき1回に集約。#144）が
#     run自身でcount-skips.shを実行し、0件でも必ず表示する ---
H97_RS_EPICGATE="$(awk '/^## Epic 統合ゲート/{f=1} /^## Epic一括レビュー/{f=0} f' "$RUN_SKILL_FLAT")"

case "$H97_RS_EPICGATE" in
  *'tee'*'count-skips.sh'*)
    pass "SKILL.md: Epic統合ゲートがテスト出力をteeで保存しcount-skips.shで数えている（#97, #144）" ;;
  *)
    fail "SKILL.md: Epic統合ゲートがテスト出力をteeで保存しcount-skips.shで数えている（#97, #144）" \
      "$H97_RS_EPICGATE" ;;
esac

case "$H97_RS_EPICGATE" in
  *'0件でも必ず表示'*)
    pass "SKILL.md: Epic統合ゲートがSKIP件数を0件でも必ず表示する旨を明記している（#97, #144）" ;;
  *)
    fail "SKILL.md: Epic統合ゲートがSKIP件数を0件でも必ず表示する旨を明記している（#97, #144）" \
      "$H97_RS_EPICGATE" ;;
esac

case "$H97_RS_EPICGATE" in
  *'食い違った場合はEpic統合ゲートの値を採用'*'Epic issue にコメント'*)
    pass "SKILL.md: Epic統合ゲートがレーンの自己申告と食い違った場合にEpic統合ゲートの値を採用しEpic issueにコメントする旨を明記している（#97, #144）" ;;
  *)
    fail "SKILL.md: Epic統合ゲートがレーンの自己申告と食い違った場合にEpic統合ゲートの値を採用しEpic issueにコメントする旨を明記している（#97, #144）" \
      "$H97_RS_EPICGATE" ;;
esac

# --- skills/run/SKILL.md: 「SKIP を通過扱いにしない」節がskips=unknownの扱いを明記している ---
H97_RS_SKIPSECTION="$(awk '/^#### SKIP を通過扱いにしない/{f=1} /^## Epic一括レビュー/{f=0} f' \
  "$RUN_SKILL_FLAT")"

case "$H97_RS_SKIPSECTION" in
  *'skips=unknown'*'「0件」として扱ってはならない'*)
    pass "SKILL.md: 『SKIP を通過扱いにしない』節がskips=unknownを0件扱いしない旨を明記している（#97）" ;;
  *)
    fail "SKILL.md: 『SKIP を通過扱いにしない』節がskips=unknownを0件扱いしない旨を明記している（#97）" \
      "$H97_RS_SKIPSECTION" ;;
esac

# --- skills/run/SKILL.md: Step 3 雛形に駆動先プロジェクト固有のSKIPパターン値をハードコード
#     していない（例: このリポジトリ自身のパターン「^  skip - 」が literal で入っていない） ---
if printf '%s\n' "$H97_RS_STEP3" | grep -Fq -- '^  skip - '; then
  fail "SKILL.md: Step 3 雛形に駆動先プロジェクト固有のSKIPパターンをハードコードしていない（#97）" \
    "$H97_RS_STEP3"
else
  pass "SKILL.md: Step 3 雛形に駆動先プロジェクト固有のSKIPパターンをハードコードしていない（#97）"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: 同様にcount-skips.shを使う手順になっている ---
if grep -Fq -- 'SKIP されたテストがあれば件数と内容を報告に含めること' \
  "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md"; then
  fail "SKILL.md(codex): 数え方の指定が無い旧表現が消えている（#97）" \
    "$(grep -n -- 'SKIP されたテストがあれば件数と内容を報告に含めること' \
      "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"
else
  pass "SKILL.md(codex): 数え方の指定が無い旧表現が消えている（#97）"
fi

H97_CRS_STEP3="$(awk '/^### Step 3:/{f=1} /^#### トークン消費の記録/{f=0} f' \
  "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"

case "$H97_CRS_STEP3" in
  *'tail'*'count-skips.sh'*'tee'*'skips=unknown'*)
    pass "SKILL.md(codex): Step 3 プロンプトがcount-skips.shを使いskips=unknownの扱いも明記している（#97）" ;;
  *)
    fail "SKILL.md(codex): Step 3 プロンプトがcount-skips.shを使いskips=unknownの扱いも明記している（#97）" \
      "$H97_CRS_STEP3" ;;
esac

H97_CRS_EPICGATE="$(awk '/^## Epic 統合ゲート/{f=1} /^## Epic一括レビュー/{f=0} f' \
  "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"

case "$H97_CRS_EPICGATE" in
  *'tee'*'count-skips.sh'*'0件でも必ず表示'*)
    pass "SKILL.md(codex): Epic統合ゲートがteeで保存しcount-skips.shで数え0件でも表示する（#97, #144）" ;;
  *)
    fail "SKILL.md(codex): Epic統合ゲートがteeで保存しcount-skips.shで数え0件でも表示する（#97, #144）" \
      "$H97_CRS_EPICGATE" ;;
esac

case "$H97_CRS_EPICGATE" in
  *'skips=unknown'*'「0件」として扱ってはならない'*)
    pass "SKILL.md(codex): 『SKIP を通過扱いにしない』節がskips=unknownを0件扱いしない旨を明記している（#97, #144）" ;;
  *)
    fail "SKILL.md(codex): 『SKIP を通過扱いにしない』節がskips=unknownを0件扱いしない旨を明記している（#97, #144）" \
      "$H97_CRS_EPICGATE" ;;
esac

# --- README.md: count-skips.sh の使い方・出力・判定順序・DEV_WORKFLOW_SKIP_PATTERN が書かれている ---
H97_README_CS="$(awk '/^### `scripts\/count-skips.sh`/{f=1} /^### Epic の `## SKIPパターン` 節/{f=0} f' \
  "${REPO_ROOT}/README.md")"

if [ -z "$H97_README_CS" ]; then
  fail "README.md: 『scripts/count-skips.sh』節が見つかる（#97）" "節が空でした"
else
  pass "README.md: 『scripts/count-skips.sh』節が見つかる（#97）"
fi

case "$H97_README_CS" in
  *'skips=<件数 または unknown>'*'runner=<go|pytest|jest|custom|unknown>'*'判定順序'*'DEV_WORKFLOW_SKIP_PATTERN'*)
    pass "README.md: count-skips.sh節に出力・判定順序・DEV_WORKFLOW_SKIP_PATTERNが書かれている（#97）" ;;
  *)
    fail "README.md: count-skips.sh節に出力・判定順序・DEV_WORKFLOW_SKIP_PATTERNが書かれている（#97）" \
      "$H97_README_CS" ;;
esac

# --- README.md: --runner オプションとjest優先判定（誤検出対策）が書かれている（#142） ---
case "$H97_README_CS" in
  *'--runner'*'jest と判定できる'*'Go と判定できる'*)
    pass "README.md: count-skips.sh節に--runnerオプションとjest優先の判定順序が書かれている（#142）" ;;
  *)
    fail "README.md: count-skips.sh節に--runnerオプションとjest優先の判定順序が書かれている（#142）" \
      "$H97_README_CS" ;;
esac

# --- README.md: Epic の「## SKIPパターン」節の書き方が案内されている ---
H97_README_EPICSECTION="$(awk '/^### Epic の `## SKIPパターン` 節/{f=1} /^## YOLOモード/{f=0} f' \
  "${REPO_ROOT}/README.md")"

case "$H97_README_EPICSECTION" in
  *'## SKIPパターン'*'DEV_WORKFLOW_SKIP_PATTERN'*'skips=unknown'*)
    pass "README.md: Epicの『## SKIPパターン』節の書き方とDEV_WORKFLOW_SKIP_PATTERNの関係が案内されている（#97）" ;;
  *)
    fail "README.md: Epicの『## SKIPパターン』節の書き方とDEV_WORKFLOW_SKIP_PATTERNの関係が案内されている（#97）" \
      "$H97_README_EPICSECTION" ;;
esac

# ---------------------------------------------------------------------------
# review#102: Epic本文の「## SKIPパターン」節がplanner側に結線されている
#
# 消費側（README.md/skills SKILL.md/generator.md）にしか記載が無く、Epic本文を書く側
# （planner.md/instructions.md）に規定が無かったため、人間が手で追記しない限り節が
# 生成されず、built-inランナー以外のプロジェクトでは常にskips=unknownになっていた。
# 既存の「## 準備コマンド」節（planner.md/instructions.mdの両方に規定済み）と同じ
# 対称性を持たせる。
# ---------------------------------------------------------------------------

echo ""
echo "== review#102: Epic本文の『## SKIPパターン』節がplanner側に結線されている =="

# --- core/roles/planner.md: 「プロジェクト固有の準備コマンド」の隣にSKIPパターン節の書き方がある ---
PLANNER_SKIP_SECTION="$(awk '/^#### SKIPパターン（該当する場合のみ）/{f=1} /^#### Task issue の自己完結化/{f=0} f' \
  "${REPO_ROOT}/core/roles/planner.md")"

if [ -z "$PLANNER_SKIP_SECTION" ]; then
  fail "core/roles/planner.md: 『#### SKIPパターン（該当する場合のみ）』節が見つかる（#102）" "節が空でした"
else
  pass "core/roles/planner.md: 『#### SKIPパターン（該当する場合のみ）』節が見つかる（#102）"
fi

case "$PLANNER_SKIP_SECTION" in
  *'go / jest / pytest'*'## SKIPパターン'*'必ず書く'*'ERE'*)
    pass "core/roles/planner.md: SKIPパターン節がgo/jest/pytest以外は必ず書く旨とERE1行の書式を明記している（#102）" ;;
  *)
    fail "core/roles/planner.md: SKIPパターン節がgo/jest/pytest以外は必ず書く旨とERE1行の書式を明記している（#102）" \
      "$PLANNER_SKIP_SECTION" ;;
esac

case "$PLANNER_SKIP_SECTION" in
  *'count-skips.sh'*'skips=unknown'*)
    pass "core/roles/planner.md: SKIPパターン節が書かないとcount-skips.shがunknownになる旨を明記している（#102）" ;;
  *)
    fail "core/roles/planner.md: SKIPパターン節が書かないとcount-skips.shがunknownになる旨を明記している（#102）" \
      "$PLANNER_SKIP_SECTION" ;;
esac

# --- core/references/epic-sections.md: 「## 準備コマンド」節と対称に「Epic本文の『## SKIPパターン』節」が
#     planner が判断する規定として存在する（詳細は core/instructions.md 本体から
#     core/references/epic-sections.md へ退避されている・#146） ---
INSTR_SKIP_SECTION="$(awk '/^### Epic 本文の `## SKIPパターン` 節/{f=1} f' \
  "${REPO_ROOT}/core/references/epic-sections.md")"

if [ -z "$INSTR_SKIP_SECTION" ]; then
  fail "core/references/epic-sections.md: 『### Epic 本文の \`## SKIPパターン\` 節』が見つかる（#102）" "節が空でした"
else
  pass "core/references/epic-sections.md: 『### Epic 本文の \`## SKIPパターン\` 節』が見つかる（#102）"
fi

case "$INSTR_SKIP_SECTION" in
  *'節を書くかどうかの判断は'*'準備コマンド'*'節と同様に planner が行う'*)
    pass "core/references/epic-sections.md: SKIPパターン節を書くかどうかの判断もplannerが行う旨が準備コマンド節と対称に規定されている（#102）" ;;
  *)
    fail "core/references/epic-sections.md: SKIPパターン節を書くかどうかの判断もplannerが行う旨が準備コマンド節と対称に規定されている（#102）" \
      "$INSTR_SKIP_SECTION" ;;
esac

# --- 生成物（agents/*.md・codex-agents/*.toml）にもcore/instructions.mdのSKIPパターン節が
#     伝播している（build.shの再生成漏れを検知する） ---
for f in agents/planner.md agents/generator.md agents/evaluator.md \
         codex-agents/planner.toml codex-agents/generator.toml codex-agents/evaluator.toml; do
  if grep -Fq -- '### Epic 本文の `## SKIPパターン` 節' "${REPO_ROOT}/${f}"; then
    pass "${f}: core/instructions.mdのSKIPパターン節が生成物に反映されている（#102）"
  else
    fail "${f}: core/instructions.mdのSKIPパターン節が生成物に反映されている（#102）" \
      "節が見つかりませんでした"
  fi
done

# --- 生成物（agents/planner.md・codex-agents/planner.toml）にもcore/roles/planner.mdの
#     SKIPパターン節が伝播している ---
for f in agents/planner.md codex-agents/planner.toml; do
  if grep -Fq -- '#### SKIPパターン（該当する場合のみ）' "${REPO_ROOT}/${f}"; then
    pass "${f}: core/roles/planner.mdのSKIPパターン節が生成物に反映されている（#102）"
  else
    fail "${f}: core/roles/planner.mdのSKIPパターン節が生成物に反映されている（#102）" \
      "節が見つかりませんでした"
  fi
done

# --- skills/run/SKILL.md Step 6: skips=unknownの恒久対処として「次のrunまでに
#     ## SKIPパターン節を追加する」ことが明記されている（都度Epic issueにコメントするだけでは
#     同じrunが来るたびにskips=unknownを繰り返すだけの状態が固定化するため） ---
RUN_SKILL_UNKNOWN="$(awk '/^#### SKIP を通過扱いにしない/{f=1} /^### Step 7: Epicブランチへ取り込んで次のウェーブへ/{f=0} f' \
  "$RUN_SKILL_FLAT")"

case "$RUN_SKILL_UNKNOWN" in
  *'恒久対処'*'次の run までに'*'## SKIPパターン'*)
    pass "SKILL.md: skips=unknown時に次のrunまでに『## SKIPパターン』節を追加することが恒久対処として明記されている（#102）" ;;
  *)
    fail "SKILL.md: skips=unknown時に次のrunまでに『## SKIPパターン』節を追加することが恒久対処として明記されている（#102）" \
      "$RUN_SKILL_UNKNOWN" ;;
esac

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh（準備成果ディレクトリの共有・共有モード、Task #106）
#
# 生成物（node_modules 等）の共有元・レーン側ともに一時ディレクトリ（mktemp -d）で組み立て、
# `DEV_WORKFLOW_SANDBOX_EXEC` にフェイクの sandbox-exec.sh を刺して検証する（Docker 非依存）。
# フェイクは「呼び出し回数を1行ずつ記録してから、最後の引数（コンテナ内スクリプト）を
# 素の sh -c で実行する」だけの単純なスタブであり、共有元・レーン側とも host 上の
# 通常ディレクトリなので `ln -s` はこの検証環境でも十分に動作する。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Task #108: READMEに共有ディレクトリ節とcomposeのキャッシュvolume既知の限界を追記する
#
# 上記1〜5がすべてREADME.mdに記載されていることと、既存記述（container_name:/固定ホスト
# ポートの既知の限界、symlink警告、cleanup-lane-worktrees.shの案内）が消えていないことを
# 確認する。
# ---------------------------------------------------------------------------

echo ""
echo "== README.md（共有ディレクトリ節・composeキャッシュvolumeの既知の限界。#108） =="

DOC108_README="${REPO_ROOT}/README.md"

# --- 1. Epicの「## 共有ディレクトリ」節の書き方が案内されている ---
DOC108_SHARED_SECTION="$(awk '/^### Epic の `## 共有ディレクトリ` 節/{f=1} /^## YOLOモード/{f=0} f' \
  "$DOC108_README")"

if [ -z "$DOC108_SHARED_SECTION" ]; then
  fail "README.md: 『Epic の \`## 共有ディレクトリ\` 節』が見つかる（#108）" "節が空でした"
else
  pass "README.md: 『Epic の \`## 共有ディレクトリ\` 節』が見つかる（#108）"
fi

case "$DOC108_SHARED_SECTION" in
  *'## 共有ディレクトリ'*'node_modules'*'yarn.lock'*'フィンガープリント'*'--detach'*)
    pass "README.md: 共有ディレクトリ節に書式例・フィンガープリントの必須化・--detachの案内がある（#108）" ;;
  *)
    fail "README.md: 共有ディレクトリ節に書式例・フィンガープリントの必須化・--detachの案内がある（#108）" \
      "$DOC108_SHARED_SECTION" ;;
esac

case "$DOC108_SHARED_SECTION" in
  *'節が無ければ何もしない'*)
    pass "README.md: 共有ディレクトリ節が無ければ何もしない（後方互換）旨が明記されている（#108）" ;;
  *)
    fail "README.md: 共有ディレクトリ節が無ければ何もしない（後方互換）旨が明記されている（#108）" \
      "$DOC108_SHARED_SECTION" ;;
esac

# --- 2. composeモードのキャッシュvolume既知の限界とサンプルが記載されている ---
DOC108_COMPOSE_SECTION="$(awk '/^### compose モード/{f=1} /^### Windows の CRLF に注意/{f=0} f' \
  "$DOC108_README")"

if [ -z "$DOC108_COMPOSE_SECTION" ]; then
  fail "README.md: 『compose モード』節が見つかる（前提）（#108）" "節が空でした"
else
  pass "README.md: 『compose モード』節が見つかる（前提）（#108）"
fi

case "$DOC108_COMPOSE_SECTION" in
  *'dockerfile モード専用'*'compose モードでは一切マウントされません'*'named volume'*'介入しません'*)
    pass "README.md: composeモードはキャッシュvolumeがdockerfile専用で介入しない旨が明記されている（#108）" ;;
  *)
    fail "README.md: composeモードはキャッシュvolumeがdockerfile専用で介入しない旨が明記されている（#108）" \
      "$DOC108_COMPOSE_SECTION" ;;
esac

case "$DOC108_COMPOSE_SECTION" in
  *'yarn-cache'*'volumes:'*)
    pass "README.md: composeのキャッシュvolumeサンプルが記載されている（#108）" ;;
  *)
    fail "README.md: composeのキャッシュvolumeサンプルが記載されている（#108）" \
      "$DOC108_COMPOSE_SECTION" ;;
esac

# --- 既存記述: container_name: / 固定ホストポートの既知の限界が消えていない ---
case "$DOC108_COMPOSE_SECTION" in
  *'container_name:'*'固定ホストポート'*'epic の並行実行ができません'*)
    pass "README.md: 既存のcontainer_name:/固定ホストポートの既知の限界が壊れずに残っている（#108）" ;;
  *)
    fail "README.md: 既存のcontainer_name:/固定ホストポートの既知の限界が壊れずに残っている（#108）" \
      "$DOC108_COMPOSE_SECTION" ;;
esac

# --- 3. 「Claude Code との差分」表に共有ディレクトリ機構がClaude Code固有である旨の1行がある ---
DOC108_CODEX_DIFF="$(awk '/^### Claude Code との差分/{f=1} /^## このプラグイン自体を開発する場合/{f=0} f' \
  "$DOC108_README")"

if [ -z "$DOC108_CODEX_DIFF" ]; then
  fail "README.md: 『Claude Code との差分』節が見つかる（前提）（#108）" "節が空でした"
else
  pass "README.md: 『Claude Code との差分』節が見つかる（前提）（#108）"
fi

case "$DOC108_CODEX_DIFF" in
  *'準備成果ディレクトリの共有'*'なし'*'レーン worktree が存在せず'*)
    pass "README.md: Claude Codeとの差分表に共有ディレクトリ機構がClaude Code固有である旨の行がある（#108）" ;;
  *)
    fail "README.md: Claude Codeとの差分表に共有ディレクトリ機構がClaude Code固有である旨の行がある（#108）" \
      "$DOC108_CODEX_DIFF" ;;
esac

# --- 4. 「worktree運用の注意」節に共有symlinkとcleanup-lane-worktrees.shの関係が書かれている ---
DOC108_WORKTREE_SECTION="$(awk '/^### worktree運用の注意/{f=1} /^## 並列実行/{f=0} f' \
  "$DOC108_README")"

if [ -z "$DOC108_WORKTREE_SECTION" ]; then
  fail "README.md: 『worktree運用の注意』節が見つかる（前提）（#108）" "節が空でした"
else
  pass "README.md: 『worktree運用の注意』節が見つかる（前提）（#108）"
fi

case "$DOC108_WORKTREE_SECTION" in
  *'共有 symlink'*'--unlink-dir'*'node_modules'*)
    pass "README.md: worktree運用の注意に共有symlinkと--unlink-dirの関係が明記されている（#108）" ;;
  *)
    fail "README.md: worktree運用の注意に共有symlinkと--unlink-dirの関係が明記されている（#108）" \
      "$DOC108_WORKTREE_SECTION" ;;
esac

# --- 既存記述: symlink警告（node_modules/git worktree remove --force）が消えていない ---
case "$DOC108_WORKTREE_SECTION" in
  *'git worktree remove --force'*'symlink越しにメインリポの実体ファイルを削除する'*)
    pass "README.md: 既存のsymlink警告が壊れずに残っている（#108）" ;;
  *)
    fail "README.md: 既存のsymlink警告が壊れずに残っている（#108）" \
      "$DOC108_WORKTREE_SECTION" ;;
esac

# --- 既存記述: cleanup-lane-worktrees.shの案内が消えていない ---
case "$DOC108_WORKTREE_SECTION" in
  *'scripts/cleanup-lane-worktrees.sh'*)
    pass "README.md: 既存のcleanup-lane-worktrees.shの案内が壊れずに残っている（#108）" ;;
  *)
    fail "README.md: 既存のcleanup-lane-worktrees.shの案内が壊れずに残っている（#108）" \
      "$DOC108_WORKTREE_SECTION" ;;
esac

# --- 5. 環境変数一覧にDEV_WORKFLOW_SANDBOX_EXECが追加されている ---
DOC108_ENVLIST="$(awk '/^### 環境変数一覧/{f=1} /^## Slack通知/{f=0} f' "$DOC108_README")"

if [ -z "$DOC108_ENVLIST" ]; then
  fail "README.md: 『環境変数一覧』節が見つかる（前提）（#108）" "節が空でした"
else
  pass "README.md: 『環境変数一覧』節が見つかる（前提）（#108）"
fi

case "$DOC108_ENVLIST" in
  *'DEV_WORKFLOW_SANDBOX_EXEC'*)
    pass "README.md: 環境変数一覧にDEV_WORKFLOW_SANDBOX_EXECが追加されている（#108）" ;;
  *)
    fail "README.md: 環境変数一覧にDEV_WORKFLOW_SANDBOX_EXECが追加されている（#108）" \
      "$DOC108_ENVLIST" ;;
esac

# --- 駆動先プロジェクト固有の値をハードコードしていない（汎用の例のみ。kikumemo等の固有名詞が無い） ---
if grep -Eq 'kikumemo' "$DOC108_README"; then
  fail "README.md: 駆動先プロジェクト固有の値をハードコードしていない（#108）" \
    "$(grep -n -E 'kikumemo' "$DOC108_README")"
else
  pass "README.md: 駆動先プロジェクト固有の値をハードコードしていない（#108）"
fi

echo ""
echo "== core/roles/generator.md: 共有ディレクトリ機構の結線（Task #113） =="

# ---------------------------------------------------------------------------
# Task #113: core/roles/generator.md に「run から共有ディレクトリの指定が渡された場合は
# share-prepared-dirs.sh を1回だけ呼ぶ」「prep=run でも自前で準備コマンドを追加実行しない」
# 「exit 3（ロック競合）は待たず2本目も起動せず停止する」「exit 4は実装に進まず報告する」
# 「依存マニフェストを変更するタスクでは install 前に --detach する」「未指定時は後方互換」
# が記載されていることを機械的に検査する。正本（core/roles/generator.md）と生成物
# （agents/generator.md・codex-agents/generator.toml）の両方を対象にする。
# ---------------------------------------------------------------------------

GEN113_FILES=(
  "core/roles/generator.md"
  "agents/generator.md"
  "codex-agents/generator.toml"
)

for f in "${GEN113_FILES[@]}"; do
  GEN113_SECTION="$(awk '/^#### 共有ディレクトリの指定がある場合は share-prepared-dirs\.sh を呼ぶ/{f=1} /^### 1\. タスクの確認/{f=0} f' "${REPO_ROOT}/${f}")"

  if [ -z "$GEN113_SECTION" ]; then
    fail "${f}: 『共有ディレクトリの指定がある場合は share-prepared-dirs.sh を呼ぶ』節が見つかる（#113）" \
      "節が空でした"
    continue
  fi
  pass "${f}: 『共有ディレクトリの指定がある場合は share-prepared-dirs.sh を呼ぶ』節が見つかる（#113）"

  case "$GEN113_SECTION" in
    *'share-prepared-dirs.sh'*'自分の作業ディレクトリで1回だけ'*)
      pass "${f}: 共有ディレクトリの指定がある場合 share-prepared-dirs.sh を1回だけ呼ぶ旨がある（#113）" ;;
    *)
      fail "${f}: 共有ディレクトリの指定がある場合 share-prepared-dirs.sh を1回だけ呼ぶ旨がある（#113）" \
        "$GEN113_SECTION" ;;
  esac

  case "$GEN113_SECTION" in
    *'prep=run'*'自前で準備コマンドを追加実行しない'*)
      pass "${f}: prep=run でも自前で準備コマンドを追加実行しない旨がある（#113）" ;;
    *)
      fail "${f}: prep=run でも自前で準備コマンドを追加実行しない旨がある（#113）" \
        "$GEN113_SECTION" ;;
  esac

  case "$GEN113_SECTION" in
    *'exit 3'*'待ったり2本目を起動したりしない'*)
      pass "${f}: exit 3（ロック競合）を受け取ったら待たず2本目も起動せず停止する旨がある（#113）" ;;
    *)
      fail "${f}: exit 3（ロック競合）を受け取ったら待たず2本目も起動せず停止する旨がある（#113）" \
        "$GEN113_SECTION" ;;
  esac

  case "$GEN113_SECTION" in
    *'exit 4'*'実装に進まず'*)
      pass "${f}: exit 4（--run-prepの失敗）は実装に進まず報告する旨がある（#113）" ;;
    *)
      fail "${f}: exit 4（--run-prepの失敗）は実装に進まず報告する旨がある（#113）" \
        "$GEN113_SECTION" ;;
  esac

  case "$GEN113_SECTION" in
    *'依存マニフェスト'*'--detach --dir'*'install'*)
      pass "${f}: 依存マニフェストを変更するタスクではinstall前に--detachする旨がある（#113）" ;;
    *)
      fail "${f}: 依存マニフェストを変更するタスクではinstall前に--detachする旨がある（#113）" \
        "$GEN113_SECTION" ;;
  esac

  case "$GEN113_SECTION" in
    *'完了報告にそのまま貼る'*)
      pass "${f}: スクリプトの実出力を完了報告にそのまま貼る（自己申告にしない）旨がある（#113）" ;;
    *)
      fail "${f}: スクリプトの実出力を完了報告にそのまま貼る（自己申告にしない）旨がある（#113）" \
        "$GEN113_SECTION" ;;
  esac

  case "$GEN113_SECTION" in
    *'共有ディレクトリの指定が渡されていない場合'*'従来どおり'*)
      pass "${f}: 共有ディレクトリの指定が渡されていない場合は従来どおり（後方互換）の旨がある（#113）" ;;
    *)
      fail "${f}: 共有ディレクトリの指定が渡されていない場合は従来どおり（後方互換）の旨がある（#113）" \
        "$GEN113_SECTION" ;;
  esac
done

# --- core/roles/generator.md: H2向け編集後も「## 作業フロー」節の 0. → プロジェクト固有の準備
#     → 共有ディレクトリ節 → 1. の順序が保たれている（#100の並び順テストとの整合） ---
GEN113_FLOW_SECTION="$(awk '/^## 作業フロー/{f=1;next} /^## コーディングルール/{f=0} f' "${REPO_ROOT}/core/roles/generator.md")"

assert_order "core/roles/generator.md: 「## 作業フロー」節で 0. → プロジェクト固有の準備 → 共有ディレクトリ節 → 1. の順で並んでいる（#113）" \
  "$GEN113_FLOW_SECTION" \
  "### 0. 渡されたベースにHEADを合わせる" \
  "### プロジェクト固有の準備は自分の作業ディレクトリで初回1回だけ実行する" \
  "#### 共有ディレクトリの指定がある場合は share-prepared-dirs.sh を呼ぶ" \
  "### 1. タスクの確認"

# --- 既存の「初回1回だけ実行する」規約（Task #94由来）テストを壊していないことの前提確認 ---
GEN113_PREP_SECTION="$(awk '/^### プロジェクト固有の準備/{f=1} /^### 1\. /{f=0} f' "${REPO_ROOT}/core/roles/generator.md")"

case "$GEN113_PREP_SECTION" in
  *'初回1回だけ'*'同一 worktree 内で2回目以降は実行しない'*)
    pass "core/roles/generator.md: 既存の『初回1回だけ実行する』規約（#94）が壊れていない（#113）" ;;
  *)
    fail "core/roles/generator.md: 既存の『初回1回だけ実行する』規約（#94）が壊れていない（#113）" \
      "$GEN113_PREP_SECTION" ;;
esac

# ---------------------------------------------------------------------------
# check-repo-hygiene.sh（.git/info/exclude の冪等整備・骨格）（#124）
# ---------------------------------------------------------------------------

echo ""
echo "== check-repo-hygiene.sh（.git/info/exclude の冪等整備） =="

HYG_SCRIPT="${REPO_ROOT}/scripts/check-repo-hygiene.sh"

# --- bash -n が通る ---
if bash -n "$HYG_SCRIPT" 2>/dev/null; then
  pass "check-repo-hygiene.sh: bash -n の構文チェックが通る（#124）"
else
  fail "check-repo-hygiene.sh: bash -n の構文チェックが通る（#124）"
fi

# --- rm / rmdir / unlink によるファイル削除が無い（安全ルール）。
#     share-prepared-dirs.sh のテストと同じ検査方法（コメント行を除外し、単語境界での一致だけを見る） ---
HYG_FORBIDDEN_HITS="$(grep -v '^[[:space:]]*#' "$HYG_SCRIPT" \
  | grep -E '(^|[^A-Za-z0-9_])(rm|rmdir|unlink)([[:space:]]|$)' || true)"
if [ -z "$HYG_FORBIDDEN_HITS" ]; then
  pass "check-repo-hygiene.sh: rm / rmdir / unlink によるファイル削除が無い（#124）"
else
  fail "check-repo-hygiene.sh: rm / rmdir / unlink によるファイル削除が無い（#124）" "$HYG_FORBIDDEN_HITS"
fi

# --- 未知のオプションで exit 2（完了条件8） ---
HYG_UNKNOWN_OUT="$(bash "$HYG_SCRIPT" --bogus 2>&1)"
HYG_UNKNOWN_EXIT=$?
assert_exit_code "check-repo-hygiene.sh: 未知のオプションで exit 2（#124）" 2 "$HYG_UNKNOWN_EXIT"
case "$HYG_UNKNOWN_OUT" in
  *"ERROR:"*"--bogus"*)
    pass "check-repo-hygiene.sh: 未知のオプションはエラーメッセージ付きで拒否される（黙って無視しない）（#124）" ;;
  *)
    fail "check-repo-hygiene.sh: 未知のオプションはエラーメッセージ付きで拒否される（黙って無視しない）（#124）" "$HYG_UNKNOWN_OUT" ;;
esac

# --- git 管理外のディレクトリで実行しても exit 0、何も書き込まない（完了条件7） ---
HYG_NONGIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hyg-nongit.XXXXXX")"
HYG_NONGIT_EXIT=0
( cd "$HYG_NONGIT_DIR" && bash "$HYG_SCRIPT" ) >/dev/null 2>&1 || HYG_NONGIT_EXIT=$?
assert_exit_code "check-repo-hygiene.sh: git管理外ディレクトリで exit 0（#124）" 0 "$HYG_NONGIT_EXIT"
assert_eq "check-repo-hygiene.sh: git管理外ディレクトリでは .git が作られない（#124）" \
  "no" "$([ -e "${HYG_NONGIT_DIR}/.git" ] && echo yes || echo no)"

# --- 既定モードは stdout に何も出さない・exit 0（SessionStart 用。stdoutを汚さない） ---
HYG_REPO_DEFAULT="$(make_temp_repo)"
HYG_DEFAULT_EXIT=0
HYG_DEFAULT_OUT="$( (cd "$HYG_REPO_DEFAULT" && bash "$HYG_SCRIPT") 2>/dev/null)" || HYG_DEFAULT_EXIT=$?
assert_eq "check-repo-hygiene.sh: 既定モードはstdoutに何も出さない（#124）" "" "$HYG_DEFAULT_OUT"
assert_exit_code "check-repo-hygiene.sh: 既定モードは exit 0（#124）" 0 "$HYG_DEFAULT_EXIT"

# --- --run も本タスクの範囲ではブロックせず exit 0 ---
HYG_RUN_EXIT=0
( cd "$HYG_REPO_DEFAULT" && bash "$HYG_SCRIPT" --run ) >/dev/null 2>&1 || HYG_RUN_EXIT=$?
assert_exit_code "check-repo-hygiene.sh: --run は本タスクの範囲ではブロックせず exit 0（#124）" 0 "$HYG_RUN_EXIT"

# --- 完了条件1: 空の一時 git リポジトリで実行すると .git/info/exclude にブロックが追記される ---
HYG_REPO1="$(make_temp_repo)"
( cd "$HYG_REPO1" && bash "$HYG_SCRIPT" ) >/dev/null 2>&1
HYG_EXCLUDE1="${HYG_REPO1}/.git/info/exclude"
assert_eq "check-repo-hygiene.sh: 空のリポジトリで .git/info/exclude が作られる（#124）" \
  "yes" "$([ -f "$HYG_EXCLUDE1" ] && echo yes || echo no)"

HYG_EXCLUDE1_CONTENT="$(cat -- "$HYG_EXCLUDE1" 2>/dev/null)"
case "$HYG_EXCLUDE1_CONTENT" in
  *'# >>> dev-workflow: ハーネス生成物のローカル除外（自動生成。コミットされません） >>>'*'/.claude/.dev-workflow-*'*'/.claude/worktrees/'*'/.claude/agent-tokens.tsv'*'/.claude/slack-webhook'*'/.claude/settings.local.json'*'# <<< dev-workflow <<<'*)
    pass "check-repo-hygiene.sh: 期待されるブロック内容が書き込まれる（#124）" ;;
  *)
    fail "check-repo-hygiene.sh: 期待されるブロック内容が書き込まれる（#124）" "$HYG_EXCLUDE1_CONTENT" ;;
esac

# --- 完了条件2: 2回連続で実行しても内容は1度しか変わらない（冪等）。2回目は exclude_updated=no ---
HYG_CONTENT_BEFORE="$(cat -- "$HYG_EXCLUDE1")"
HYG_PRINT2="$( cd "$HYG_REPO1" && bash "$HYG_SCRIPT" --print 2>/dev/null )"
HYG_CONTENT_AFTER="$(cat -- "$HYG_EXCLUDE1")"
assert_eq "check-repo-hygiene.sh: 2回目実行後も .git/info/exclude の内容は変わらない（冪等）（#124）" \
  "$HYG_CONTENT_BEFORE" "$HYG_CONTENT_AFTER"
assert_eq "check-repo-hygiene.sh: 2回目実行時は exclude_updated=no（#124）" \
  "no" "$(printf '%s\n' "$HYG_PRINT2" | sed -n 's/^exclude_updated=//p')"

# --- 完了条件3: ユーザーが事前に書いた既存行（マーカー外）が1行も失われない ---
HYG_REPO2="$(make_temp_repo)"
HYG_EXCLUDE2="${HYG_REPO2}/.git/info/exclude"
printf 'existing-line-1\nexisting-line-2\n' > "$HYG_EXCLUDE2"
( cd "$HYG_REPO2" && bash "$HYG_SCRIPT" ) >/dev/null 2>&1
HYG_EXCLUDE2_CONTENT="$(cat -- "$HYG_EXCLUDE2")"
case "$HYG_EXCLUDE2_CONTENT" in
  *'existing-line-1'*'existing-line-2'*)
    pass "check-repo-hygiene.sh: 事前に書かれた既存行が保持される（#124）" ;;
  *)
    fail "check-repo-hygiene.sh: 事前に書かれた既存行が保持される（#124）" "$HYG_EXCLUDE2_CONTENT" ;;
esac
case "$HYG_EXCLUDE2_CONTENT" in
  *'# >>> dev-workflow: ハーネス生成物のローカル除外（自動生成。コミットされません） >>>'*)
    pass "check-repo-hygiene.sh: 既存行があってもブロックが追記される（#124）" ;;
  *)
    fail "check-repo-hygiene.sh: 既存行があってもブロックが追記される（#124）" "$HYG_EXCLUDE2_CONTENT" ;;
esac

# --- 完了条件4: ブロック内容が改変されている状態で実行すると、ブロック内だけが期待値に
#     復元され、マーカー外の行（前方・後方とも）は変更されない ---
HYG_REPO3="$(make_temp_repo)"
HYG_EXCLUDE3="${HYG_REPO3}/.git/info/exclude"
{
  echo "outer-line-kept"
  echo "# >>> dev-workflow: ハーネス生成物のローカル除外（自動生成。コミットされません） >>>"
  echo "/.claude/tampered-line"
  echo "# <<< dev-workflow <<<"
  echo "outer-line-after"
} > "$HYG_EXCLUDE3"

( cd "$HYG_REPO3" && bash "$HYG_SCRIPT" ) >/dev/null 2>&1
HYG_EXCLUDE3_CONTENT="$(cat -- "$HYG_EXCLUDE3")"

case "$HYG_EXCLUDE3_CONTENT" in
  *'outer-line-kept'*)
    pass "check-repo-hygiene.sh: ブロック改変時もマーカー外の前方行は保持される（#124）" ;;
  *)
    fail "check-repo-hygiene.sh: ブロック改変時もマーカー外の前方行は保持される（#124）" "$HYG_EXCLUDE3_CONTENT" ;;
esac
case "$HYG_EXCLUDE3_CONTENT" in
  *'outer-line-after'*)
    pass "check-repo-hygiene.sh: ブロック改変時もマーカー外の後方行は保持される（#124）" ;;
  *)
    fail "check-repo-hygiene.sh: ブロック改変時もマーカー外の後方行は保持される（#124）" "$HYG_EXCLUDE3_CONTENT" ;;
esac
case "$HYG_EXCLUDE3_CONTENT" in
  *'/.claude/tampered-line'*)
    fail "check-repo-hygiene.sh: 改変されたブロック内容は期待値に復元される（#124）" "$HYG_EXCLUDE3_CONTENT" ;;
  *)
    pass "check-repo-hygiene.sh: 改変されたブロック内容は期待値に復元される（#124）" ;;
esac
case "$HYG_EXCLUDE3_CONTENT" in
  *'/.claude/worktrees/'*'/.claude/agent-tokens.tsv'*'/.claude/slack-webhook'*'/.claude/settings.local.json'*)
    pass "check-repo-hygiene.sh: 復元後のブロックに期待される全エントリが含まれる（#124）" ;;
  *)
    fail "check-repo-hygiene.sh: 復元後のブロックに期待される全エントリが含まれる（#124）" "$HYG_EXCLUDE3_CONTENT" ;;
esac

# --- 完了条件5: worktree から実行しても、書き込み先はメインリポの .git/info/exclude になる ---
HYG_REPO4="$(make_temp_repo)"
HYG_WT4_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hyg-wt.XXXXXX")"
make_worktree "$HYG_REPO4" "$HYG_WT4_DIR" "hyg-worktree-branch"

HYG_WT4_GITDIR="$(cd "$HYG_WT4_DIR" && git rev-parse --path-format=absolute --git-dir)"
HYG_WT4_COMMONDIR="$(cd "$HYG_WT4_DIR" && git rev-parse --path-format=absolute --git-common-dir)"
assert_eq "check-repo-hygiene.sh: worktreeのgit-common-dirはメインリポの.gitと一致する（前提確認）（#124）" \
  "${HYG_REPO4}/.git" "$HYG_WT4_COMMONDIR"

( cd "$HYG_WT4_DIR" && bash "$HYG_SCRIPT" ) >/dev/null 2>&1

case "$(cat -- "${HYG_WT4_COMMONDIR}/info/exclude" 2>/dev/null)" in
  *'# >>> dev-workflow'*)
    pass "check-repo-hygiene.sh: worktreeから実行してもgit-common-dir配下のinfo/excludeに書き込まれる（#124）" ;;
  *)
    fail "check-repo-hygiene.sh: worktreeから実行してもgit-common-dir配下のinfo/excludeに書き込まれる（#124）" ;;
esac
assert_eq "check-repo-hygiene.sh: worktree専用git-dir配下にはinfo/excludeが作られない（#124）" \
  "no" "$([ -e "${HYG_WT4_GITDIR}/info/exclude" ] && echo yes || echo no)"

# --- 完了条件6: --check では書き込みが発生しない（ファイルの内容が変わらない）が、
#     exclude_updated は必要性を正しく報告する。
#     `git init` は既定のテンプレートから .git/info/exclude を作るため、実行前から
#     ファイルが存在すること自体は前提にできない（内容がブロックを含まないことだけを前提にする）。 ---
HYG_REPO5="$(make_temp_repo)"
HYG_EXCLUDE5="${HYG_REPO5}/.git/info/exclude"
HYG_EXCLUDE5_BEFORE="$(cat -- "$HYG_EXCLUDE5" 2>/dev/null)"
case "$HYG_EXCLUDE5_BEFORE" in
  *'# >>> dev-workflow'*)
    fail "check-repo-hygiene.sh: --check前提: 実行前はまだブロックが含まれていない（#124）" "$HYG_EXCLUDE5_BEFORE" ;;
  *)
    pass "check-repo-hygiene.sh: --check前提: 実行前はまだブロックが含まれていない（#124）" ;;
esac

HYG_CHECK1_OUT="$( cd "$HYG_REPO5" && bash "$HYG_SCRIPT" --check --print 2>/dev/null )"
assert_eq "check-repo-hygiene.sh: --check時、更新が必要なら exclude_updated=yes（#124）" \
  "yes" "$(printf '%s\n' "$HYG_CHECK1_OUT" | sed -n 's/^exclude_updated=//p')"
assert_eq "check-repo-hygiene.sh: --check時は実際には書き込まれない（ファイル内容が変わらない）（#124）" \
  "$HYG_EXCLUDE5_BEFORE" "$(cat -- "$HYG_EXCLUDE5" 2>/dev/null)"

( cd "$HYG_REPO5" && bash "$HYG_SCRIPT" ) >/dev/null 2>&1
HYG_CHECK2_OUT="$( cd "$HYG_REPO5" && bash "$HYG_SCRIPT" --check --print 2>/dev/null )"
assert_eq "check-repo-hygiene.sh: 整備済み後の --check では exclude_updated=no（#124）" \
  "no" "$(printf '%s\n' "$HYG_CHECK2_OUT" | sed -n 's/^exclude_updated=//p')"

# --- --print の予約領域キー（#126 / #127 が値を埋めるまでの固定値。完了条件の前提整備） ---
HYG_PRINT_KEYS_OUT="$( cd "$HYG_REPO1" && bash "$HYG_SCRIPT" --print 2>/dev/null )"
assert_eq "check-repo-hygiene.sh: --print出力にrepo_rootキーがある（#124）" \
  "yes" "$(printf '%s\n' "$HYG_PRINT_KEYS_OUT" | grep -q '^repo_root=' && echo yes || echo no)"
assert_eq "check-repo-hygiene.sh: --print出力にexclude_fileキーがある（#124）" \
  "yes" "$(printf '%s\n' "$HYG_PRINT_KEYS_OUT" | grep -q '^exclude_file=' && echo yes || echo no)"
assert_eq "check-repo-hygiene.sh: --print出力でtracked_settings_local=no（#126予約領域）" \
  "no" "$(printf '%s\n' "$HYG_PRINT_KEYS_OUT" | sed -n 's/^tracked_settings_local=//p')"
assert_eq "check-repo-hygiene.sh: --print出力でtracked_settings=no（#126予約領域）" \
  "no" "$(printf '%s\n' "$HYG_PRINT_KEYS_OUT" | sed -n 's/^tracked_settings=//p')"
assert_eq "check-repo-hygiene.sh: --print出力でbroad_allow=no（#126予約領域）" \
  "no" "$(printf '%s\n' "$HYG_PRINT_KEYS_OUT" | sed -n 's/^broad_allow=//p')"
assert_eq "check-repo-hygiene.sh: --print出力でsandbox_in_repo_untracked=no（sandbox定義が無いリポジトリ）（#127）" \
  "no" "$(printf '%s\n' "$HYG_PRINT_KEYS_OUT" | sed -n 's/^sandbox_in_repo_untracked=//p')"
assert_eq "check-repo-hygiene.sh: --print出力でverdict=ok（#124）" \
  "ok" "$(printf '%s\n' "$HYG_PRINT_KEYS_OUT" | sed -n 's/^verdict=//p')"

# ---------------------------------------------------------------------------
# check-repo-hygiene.sh（permission 衛生チェックと --run ブロック）（#126）
# ---------------------------------------------------------------------------

echo ""
echo "== check-repo-hygiene.sh（permission 衛生チェックと --run ブロック） =="

make_hyg_perm_repo() {
  # make_hyg_perm_repo <dir> <settings_local_json追跡有無:yes|no> <settings_json内容(空なら未作成)> <settings_json追跡有無:yes|no>
  # 一時 git リポジトリを作り、必要に応じて .claude/settings.local.json /
  # .claude/settings.json を配置・追跡してパスを返す。
  local dir="$1" track_local="$2" settings_content="$3" track_settings="$4"
  (
    cd "$dir" || exit 1
    git init -q
    git config user.email "dev-workflow-test@example.com"
    git config user.name "dev-workflow test"
    printf 'test repo\n' > README.md
    git add README.md
    git commit -q -m "init"
    mkdir -p .claude
    if [ "$track_local" = "yes" ]; then
      printf '{}\n' > .claude/settings.local.json
      git add .claude/settings.local.json
    fi
    if [ -n "$settings_content" ]; then
      printf '%s\n' "$settings_content" > .claude/settings.json
      if [ "$track_settings" = "yes" ]; then
        git add .claude/settings.json
      fi
    fi
    if [ "$track_local" = "yes" ] || { [ -n "$settings_content" ] && [ "$track_settings" = "yes" ]; }; then
      git commit -q -m "add .claude settings"
    fi
  ) >/dev/null 2>&1
}

# --- 完了条件1: settings.local.json を追跡した状態で --run すると exit 2、verdict=block ---
HYG_PERM1="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hyg-perm1.XXXXXX")"
make_hyg_perm_repo "$HYG_PERM1" "yes" "" "no"
HYG_PERM1_OUT="$( cd "$HYG_PERM1" && bash "$HYG_SCRIPT" --run --print 2>/dev/null )"
HYG_PERM1_EXIT=$?
HYG_PERM1_STDERR="$( cd "$HYG_PERM1" && bash "$HYG_SCRIPT" --run --print 2>&1 1>/dev/null )"
assert_exit_code "check-repo-hygiene.sh: settings.local.json追跡＋--runでexit 2（#126完了条件1）" 2 "$HYG_PERM1_EXIT"
assert_eq "check-repo-hygiene.sh: settings.local.json追跡＋--runでverdict=block（#126完了条件1）" \
  "block" "$(printf '%s\n' "$HYG_PERM1_OUT" | sed -n 's/^verdict=//p')"
assert_eq "check-repo-hygiene.sh: settings.local.json追跡＋--runでtracked_settings_local=yes（#126完了条件1）" \
  "yes" "$(printf '%s\n' "$HYG_PERM1_OUT" | sed -n 's/^tracked_settings_local=//p')"

# --- 完了条件2: DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS=1 を付けると exit 0、verdict=warn ---
HYG_PERM2_OUT="$( cd "$HYG_PERM1" && DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS=1 bash "$HYG_SCRIPT" --run --print 2>/dev/null )"
HYG_PERM2_EXIT=$?
assert_exit_code "check-repo-hygiene.sh: opt-out付き--runでexit 0（#126完了条件2）" 0 "$HYG_PERM2_EXIT"
assert_eq "check-repo-hygiene.sh: opt-out付き--runでverdict=warn（#126完了条件2）" \
  "warn" "$(printf '%s\n' "$HYG_PERM2_OUT" | sed -n 's/^verdict=//p')"

# --- 完了条件3: --run なし（既定モード）なら exit 0、verdict=warn ---
HYG_PERM3_OUT="$( cd "$HYG_PERM1" && bash "$HYG_SCRIPT" --print 2>/dev/null )"
HYG_PERM3_EXIT=$?
assert_exit_code "check-repo-hygiene.sh: 既定モードはexit 0（#126完了条件3）" 0 "$HYG_PERM3_EXIT"
assert_eq "check-repo-hygiene.sh: 既定モードはverdict=warn（#126完了条件3）" \
  "warn" "$(printf '%s\n' "$HYG_PERM3_OUT" | sed -n 's/^verdict=//p')"

# --- 完了条件4: settings.local.json が未追跡なら tracked_settings_local=no、--runでもexit 0 ---
HYG_PERM4="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hyg-perm4.XXXXXX")"
make_hyg_perm_repo "$HYG_PERM4" "no" "" "no"
HYG_PERM4_OUT="$( cd "$HYG_PERM4" && bash "$HYG_SCRIPT" --run --print 2>/dev/null )"
HYG_PERM4_EXIT=$?
assert_eq "check-repo-hygiene.sh: settings.local.json未追跡でtracked_settings_local=no（#126完了条件4）" \
  "no" "$(printf '%s\n' "$HYG_PERM4_OUT" | sed -n 's/^tracked_settings_local=//p')"
assert_exit_code "check-repo-hygiene.sh: settings.local.json未追跡なら--runでもexit 0（#126完了条件4）" 0 "$HYG_PERM4_EXIT"

# --- 完了条件5: settings.json を追跡し "Bash(*)" を含めるとbroad_allow=yesだがexit 0（ブロックしない） ---
HYG_PERM5="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hyg-perm5.XXXXXX")"
make_hyg_perm_repo "$HYG_PERM5" "no" '{"permissions":{"allow":["Bash(*)"]}}' "yes"
HYG_PERM5_OUT="$( cd "$HYG_PERM5" && bash "$HYG_SCRIPT" --run --print 2>/dev/null )"
HYG_PERM5_EXIT=$?
assert_eq "check-repo-hygiene.sh: Bash(*)を含む追跡済みsettings.jsonでbroad_allow=yes（#126完了条件5）" \
  "yes" "$(printf '%s\n' "$HYG_PERM5_OUT" | sed -n 's/^broad_allow=//p')"
assert_exit_code "check-repo-hygiene.sh: broad_allow=yesでもexit 0（ブロックしない）（#126完了条件5）" 0 "$HYG_PERM5_EXIT"

# --- 完了条件6: "Bash(npm run test:*)" だけを含む追跡済みsettings.jsonではbroad_allow=no（誤検知しない） ---
HYG_PERM6="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hyg-perm6.XXXXXX")"
make_hyg_perm_repo "$HYG_PERM6" "no" '{"permissions":{"allow":["Bash(npm run test:*)"]}}' "yes"
HYG_PERM6_OUT="$( cd "$HYG_PERM6" && bash "$HYG_SCRIPT" --print 2>/dev/null )"
assert_eq "check-repo-hygiene.sh: 狭い許可のみの追跡済みsettings.jsonではbroad_allow=no（#126完了条件6）" \
  "no" "$(printf '%s\n' "$HYG_PERM6_OUT" | sed -n 's/^broad_allow=//p')"

# --- 完了条件7: settings.json が未追跡なら、広範な allow を含んでいてもbroad_allow=no ---
HYG_PERM7="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hyg-perm7.XXXXXX")"
make_hyg_perm_repo "$HYG_PERM7" "no" '{"permissions":{"allow":["Bash(*)"]}}' "no"
HYG_PERM7_OUT="$( cd "$HYG_PERM7" && bash "$HYG_SCRIPT" --print 2>/dev/null )"
assert_eq "check-repo-hygiene.sh: settings.json未追跡ならbroad_allow=no（#126完了条件7）" \
  "no" "$(printf '%s\n' "$HYG_PERM7_OUT" | sed -n 's/^broad_allow=//p')"
assert_eq "check-repo-hygiene.sh: settings.json未追跡ならtracked_settings=no（#126完了条件7）" \
  "no" "$(printf '%s\n' "$HYG_PERM7_OUT" | sed -n 's/^tracked_settings=//p')"

# --- 完了条件8: stderrにgit rm --cachedの案内が含まれるが、実際にはgit rmを実行していない
#     （テスト後もファイルが追跡されたまま） ---
case "$HYG_PERM1_STDERR" in
  *'git rm --cached .claude/settings.local.json'*)
    pass "check-repo-hygiene.sh: stderrにgit rm --cachedの案内が含まれる（#126完了条件8）" ;;
  *)
    fail "check-repo-hygiene.sh: stderrにgit rm --cachedの案内が含まれる（#126完了条件8）" "$HYG_PERM1_STDERR" ;;
esac
HYG_PERM1_STILL_TRACKED="$( cd "$HYG_PERM1" && git ls-files -- .claude/settings.local.json )"
assert_eq "check-repo-hygiene.sh: 案内後もsettings.local.jsonは実際には削除されず追跡されたまま（#126完了条件8）" \
  ".claude/settings.local.json" "$HYG_PERM1_STILL_TRACKED"

echo ""
echo "== README.mdへのハーネス非注入原則・規約パス・YOLO許可スコープ指針の追記（#130） =="

DOC130_README="${REPO_ROOT}/README.md"
DOC130_INSTRUCTIONS="${REPO_ROOT}/core/instructions.md"
DOC130_SKILL="$RUN_SKILL_FLAT"

# --- 1. 前提条件・Docker sandboxのセットアップに3択が反映されている ---

if grep -Fq '規約パスに置く（推奨）' "$DOC130_README" \
  && grep -Fq '~/.claude/dev-workflow/sandbox/<リポジトリ名>/Dockerfile.dev' "$DOC130_README" \
  && grep -Fq 'リポジトリ直下に置いてコミットする' "$DOC130_README" \
  && grep -Fq 'チームで run を共有する場合のみ' "$DOC130_README"; then
  pass "README.md: サンドボックス定義供給の3択（規約パス・環境変数・リポジトリ直下）が明記されている（#130）"
else
  fail "README.md: サンドボックス定義供給の3択（規約パス・環境変数・リポジトリ直下）が明記されている（#130）"
fi

if grep -Fq '### 1. 規約パスに置く（推奨・駆動先リポジトリを汚さない）' "$DOC130_README"; then
  pass "README.md: 「Docker sandbox のセットアップ」で規約パスが第一候補として書かれている（#130）"
else
  fail "README.md: 「Docker sandbox のセットアップ」で規約パスが第一候補として書かれている（#130）"
fi

# --- 2. 3択の文言がcore/instructions.md・skills/run/SKILL.mdと一致している（完了条件2） ---

DOC130_CHOICE_PHRASES=(
  '規約パスに置く（推奨）'
  '~/.claude/dev-workflow/sandbox/<リポジトリ名>/Dockerfile.dev'
  'DEV_WORKFLOW_DOCKERFILE'
  'DEV_WORKFLOW_DOCKER_COMPOSE_FILE'
  'DEV_WORKFLOW_DOCKER_IMAGE'
  'リポジトリ直下に置いてコミットする'
  'チームで run を共有する場合のみ'
)
DOC130_CHOICE_OK=1
for phrase in "${DOC130_CHOICE_PHRASES[@]}"; do
  if ! grep -Fq "$phrase" "$DOC130_README" \
    || ! grep -Fq "$phrase" "$DOC130_INSTRUCTIONS" \
    || ! grep -Fq "$phrase" "$DOC130_SKILL"; then
    DOC130_CHOICE_OK=0
    break
  fi
done
if [ "$DOC130_CHOICE_OK" = "1" ]; then
  pass "README.md/core/instructions.md/skills/run/SKILL.md: 3択の文言が一致している（#130完了条件2）"
else
  fail "README.md/core/instructions.md/skills/run/SKILL.md: 3択の文言が一致している（#130完了条件2）" \
    "不一致の句: ${phrase}"
fi

# --- 3. サンドボックス設定に解決順の表と新規環境変数がある ---

if grep -Fq '### 解決順' "$DOC130_README" \
  && grep -Fq 'DEV_WORKFLOW_DOCKER_IMAGE` が非空' "$DOC130_README" \
  && grep -Fq 'mode=none`（run は開始しない）' "$DOC130_README"; then
  pass "README.md: サンドボックス設定に解決順の表がある（#130）"
else
  fail "README.md: サンドボックス設定に解決順の表がある（#130）"
fi

if grep -Fq 'DEV_WORKFLOW_SANDBOX_HOME' "$DOC130_README" \
  && grep -Fq 'DEV_WORKFLOW_DOCKER_BUILD_CONTEXT' "$DOC130_README" \
  && grep -Fq 'ビルドコンテキストは' "$DOC130_README" \
  && grep -Fq 'リポジトリルート' "$DOC130_README"; then
  pass "README.md: DEV_WORKFLOW_SANDBOX_HOME/DEV_WORKFLOW_DOCKER_BUILD_CONTEXTとビルドコンテキスト規則が書かれている（#130）"
else
  fail "README.md: DEV_WORKFLOW_SANDBOX_HOME/DEV_WORKFLOW_DOCKER_BUILD_CONTEXTとビルドコンテキスト規則が書かれている（#130）"
fi

# --- 4. YOLOモードにパーミッションのスコープ指針がある ---

if grep -Fq '#### 置き場所（スコープ）' "$DOC130_README" \
  && grep -Fq '.claude/settings.local.json' "$DOC130_README" \
  && grep -Fq '既定の置き場所' "$DOC130_README" \
  && grep -Fq 'チームで共有する場合のみ' "$DOC130_README"; then
  pass "README.md: YOLOモードにpermission設定の置き場所（スコープ）指針がある（#130）"
else
  fail "README.md: YOLOモードにpermission設定の置き場所（スコープ）指針がある（#130）"
fi

if grep -Fq '同意なく適用される' "$DOC130_README" && grep -Fq 'DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS' "$DOC130_README"; then
  pass "README.md: 追跡された設定が同意なくチーム全体に適用される危険性が明記されている（#130）"
else
  fail "README.md: 追跡された設定が同意なくチーム全体に適用される危険性が明記されている（#130）"
fi

# --- 5. 通知マーカーの説明が.git/info/excludeの自動整備に更新されている ---

if grep -Fq '.git/info/exclude' "$DOC130_README" \
  && grep -Fq '駆動先チームの共有ファイルなので触らない' "$DOC130_README"; then
  pass "README.md: 通知マーカーの説明が.git/info/exclude自動整備に更新されている（#130）"
else
  fail "README.md: 通知マーカーの説明が.git/info/exclude自動整備に更新されている（#130）"
fi

if grep -Fq 'echo ".claude/.dev-workflow-\*" >> .gitignore' "$DOC130_README"; then
  fail "README.md: 通知マーカーに旧来の手作業.gitignore追記案内が残っていない（#130）"
else
  pass "README.md: 通知マーカーに旧来の手作業.gitignore追記案内が残っていない（#130）"
fi

# --- 6. 新節「ハーネス非注入原則」がYOLOモード節の近くにあり、check-repo-hygiene.shの使い方が書かれている ---

if grep -Fq '## ハーネス非注入原則' "$DOC130_README"; then
  pass "README.md: 「ハーネス非注入原則」の節がある（#130）"
else
  fail "README.md: 「ハーネス非注入原則」の節がある（#130）"
fi

DOC130_HYGIENE_SECTION="$(awk '/^## ハーネス非注入原則/{f=1} /^## YOLOモード/{f=0} f' "$DOC130_README")"
case "$DOC130_HYGIENE_SECTION" in
  *'check-repo-hygiene.sh'*'--run'*'--check'*)
    pass "README.md: 「ハーネス非注入原則」節にcheck-repo-hygiene.shの--run/--checkの使い方がある（#130）" ;;
  *)
    fail "README.md: 「ハーネス非注入原則」節にcheck-repo-hygiene.shの--run/--checkの使い方がある（#130）" \
      "$DOC130_HYGIENE_SECTION" ;;
esac

case "$DOC130_HYGIENE_SECTION" in
  *'0`'*'OK'*'2`'*'ブロック'*)
    pass "README.md: 「ハーネス非注入原則」節に終了コード（0=OK/2=ブロック）が書かれている（#130）" ;;
  *)
    fail "README.md: 「ハーネス非注入原則」節に終了コード（0=OK/2=ブロック）が書かれている（#130）" \
      "$DOC130_HYGIENE_SECTION" ;;
esac

# 「ハーネス非注入原則」節がYOLOモード節の直前（近く）に配置されている
if grep -Fq '## ハーネス非注入原則' "$DOC130_README" && grep -Fq '## YOLOモード（完全自律動作）' "$DOC130_README"; then
  DOC130_HYGIENE_LINE="$(grep -n '^## ハーネス非注入原則' "$DOC130_README" | head -1 | cut -d: -f1)"
  DOC130_YOLO_LINE="$(grep -n '^## YOLOモード（完全自律動作）' "$DOC130_README" | head -1 | cut -d: -f1)"
  if [ -n "$DOC130_HYGIENE_LINE" ] && [ -n "$DOC130_YOLO_LINE" ] && [ "$DOC130_HYGIENE_LINE" -lt "$DOC130_YOLO_LINE" ] \
    && [ "$((DOC130_YOLO_LINE - DOC130_HYGIENE_LINE))" -lt 40 ]; then
    pass "README.md: 「ハーネス非注入原則」節がYOLOモード節の直前・近くに配置されている（#130）"
  else
    fail "README.md: 「ハーネス非注入原則」節がYOLOモード節の直前・近くに配置されている（#130）" \
      "hygiene=${DOC130_HYGIENE_LINE} yolo=${DOC130_YOLO_LINE}"
  fi
else
  fail "README.md: 「ハーネス非注入原則」節がYOLOモード節の直前・近くに配置されている（#130）" \
    "いずれかの見出しが見つかりません"
fi

# ---------------------------------------------------------------------------
# check-repo-hygiene.sh（孤立START_MARKER・複数START_MARKER・書き込み失敗時の回帰）（#133）
# ---------------------------------------------------------------------------

echo ""
echo "== check-repo-hygiene.sh（孤立START_MARKER・複数START_MARKER・書き込み失敗の回帰） =="

HYG_MARKER_START='# >>> dev-workflow: ハーネス生成物のローカル除外（自動生成。コミットされません） >>>'
HYG_MARKER_END='# <<< dev-workflow <<<'

# --- 完了条件(#133): START_MARKERはあるが対応するEND_MARKERが無い（孤立マーカー）場合、
#     そのマーカー行1行だけが差し替えられ、以降のユーザー行は保持される。
#     （修正前は末尾に丸ごと追記していたため START_MARKER が2つになり、2回目の実行で
#      「最初のSTART_MARKER〜追記ブロックのEND_MARKER」が一括差し替えされ、間の
#      ユーザー行が失われていた） ---
HYG_REPO6="$(make_temp_repo)"
HYG_EXCLUDE6="${HYG_REPO6}/.git/info/exclude"
{
  echo "user-before-orphan-marker"
  echo "$HYG_MARKER_START"
  echo "user-after-orphan-marker-1"
  echo "user-after-orphan-marker-2"
} > "$HYG_EXCLUDE6"

( cd "$HYG_REPO6" && bash "$HYG_SCRIPT" ) >/dev/null 2>&1
HYG_EXCLUDE6_CONTENT="$(cat -- "$HYG_EXCLUDE6")"

case "$HYG_EXCLUDE6_CONTENT" in
  *'user-before-orphan-marker'*'user-after-orphan-marker-1'*'user-after-orphan-marker-2'*)
    pass "check-repo-hygiene.sh: 孤立START_MARKER修正時にユーザー行（前後とも）が保持される（#133）" ;;
  *)
    fail "check-repo-hygiene.sh: 孤立START_MARKER修正時にユーザー行（前後とも）が保持される（#133）" \
      "$HYG_EXCLUDE6_CONTENT" ;;
esac

HYG_EXCLUDE6_START_COUNT="$(grep -Fc -- "$HYG_MARKER_START" "$HYG_EXCLUDE6")"
assert_eq "check-repo-hygiene.sh: 孤立START_MARKER修正後はSTART_MARKERが1つだけになる（複製されない）（#133）" \
  "1" "$HYG_EXCLUDE6_START_COUNT"

case "$HYG_EXCLUDE6_CONTENT" in
  *"$HYG_MARKER_START"*'/.claude/settings.local.json'*"$HYG_MARKER_END"*)
    pass "check-repo-hygiene.sh: 孤立START_MARKER修正時に正しいブロックへ差し替わる（#133）" ;;
  *)
    fail "check-repo-hygiene.sh: 孤立START_MARKER修正時に正しいブロックへ差し替わる（#133）" \
      "$HYG_EXCLUDE6_CONTENT" ;;
esac

# 2回目実行しても内容は変わらず（冪等）、ユーザー行も引き続き失われない
HYG_EXCLUDE6_BEFORE2="$(cat -- "$HYG_EXCLUDE6")"
( cd "$HYG_REPO6" && bash "$HYG_SCRIPT" ) >/dev/null 2>&1
HYG_EXCLUDE6_AFTER2="$(cat -- "$HYG_EXCLUDE6")"
assert_eq "check-repo-hygiene.sh: 孤立START_MARKER修正後は2回目実行しても内容が変わらない（冪等）（#133）" \
  "$HYG_EXCLUDE6_BEFORE2" "$HYG_EXCLUDE6_AFTER2"
case "$HYG_EXCLUDE6_AFTER2" in
  *'user-after-orphan-marker-1'*'user-after-orphan-marker-2'*)
    pass "check-repo-hygiene.sh: 2回目実行後もユーザー行が消えない（レビュー#133指摘の回帰）（#133）" ;;
  *)
    fail "check-repo-hygiene.sh: 2回目実行後もユーザー行が消えない（レビュー#133指摘の回帰）（#133）" \
      "$HYG_EXCLUDE6_AFTER2" ;;
esac

# --- 完了条件(#133): START_MARKERが複数（完全なブロックが2つ）存在する場合、
#     最初のブロックだけが正として差し替えられ、2つめ以降のブロックには一切触れない ---
HYG_REPO7="$(make_temp_repo)"
HYG_EXCLUDE7="${HYG_REPO7}/.git/info/exclude"
{
  echo "outer-before"
  echo "$HYG_MARKER_START"
  echo "/.claude/tampered-first-block"
  echo "$HYG_MARKER_END"
  echo "user-line-between-blocks"
  echo "$HYG_MARKER_START"
  echo "/.claude/second-block-should-be-untouched"
  echo "$HYG_MARKER_END"
  echo "outer-after"
} > "$HYG_EXCLUDE7"

( cd "$HYG_REPO7" && bash "$HYG_SCRIPT" ) >/dev/null 2>&1
HYG_EXCLUDE7_CONTENT="$(cat -- "$HYG_EXCLUDE7")"

case "$HYG_EXCLUDE7_CONTENT" in
  *'/.claude/tampered-first-block'*)
    fail "check-repo-hygiene.sh: 複数START_MARKER時、最初のブロックは期待値に復元される（#133）" \
      "$HYG_EXCLUDE7_CONTENT" ;;
  *)
    pass "check-repo-hygiene.sh: 複数START_MARKER時、最初のブロックは期待値に復元される（#133）" ;;
esac

case "$HYG_EXCLUDE7_CONTENT" in
  *'/.claude/second-block-should-be-untouched'*)
    pass "check-repo-hygiene.sh: 複数START_MARKER時、2つめ以降のブロックには触れない（#133）" ;;
  *)
    fail "check-repo-hygiene.sh: 複数START_MARKER時、2つめ以降のブロックには触れない（#133）" \
      "$HYG_EXCLUDE7_CONTENT" ;;
esac

case "$HYG_EXCLUDE7_CONTENT" in
  *'outer-before'*'user-line-between-blocks'*'outer-after'*)
    pass "check-repo-hygiene.sh: 複数START_MARKER時もマーカー外のユーザー行は保持される（#133）" ;;
  *)
    fail "check-repo-hygiene.sh: 複数START_MARKER時もマーカー外のユーザー行は保持される（#133）" \
      "$HYG_EXCLUDE7_CONTENT" ;;
esac

HYG_EXCLUDE7_START_COUNT="$(grep -Fc -- "$HYG_MARKER_START" "$HYG_EXCLUDE7")"
assert_eq "check-repo-hygiene.sh: 複数START_MARKER時、2つめのSTART_MARKERは意図的に残る（仕様どおり）（#133）" \
  "2" "$HYG_EXCLUDE7_START_COUNT"

# --- 完了条件(low, #133): .git/info/exclude への書き込みに失敗しても異常終了せず、
#     警告を出すだけで済ませる（ファイルシステム構造上の失敗を使い、root権限下でも
#     決定論的に再現できるようにする。permission ビットには依存しない） ---
HYG_REPO8="$(make_temp_repo)"
HYG_GITDIR8="${HYG_REPO8}/.git"
# 削除コマンドは使わず mv で横へ退避する（このファイル冒頭の make_temp_repo の規約に従う）。
# git init 直後の .git/info には exclude しか無く、退避しても以降の検証に影響しない。
mv -- "${HYG_GITDIR8}/info" "${HYG_GITDIR8}/info.orig" 2>/dev/null
printf 'not-a-directory\n' > "${HYG_GITDIR8}/info"

HYG_FAILWRITE_OUT="$( cd "$HYG_REPO8" && bash "$HYG_SCRIPT" 2>&1 )"
HYG_FAILWRITE_EXIT=$?
assert_exit_code "check-repo-hygiene.sh: exclude書き込み失敗時もexitコードは0のまま（#133）" 0 "$HYG_FAILWRITE_EXIT"
case "$HYG_FAILWRITE_OUT" in
  *'警告'*'書き込みに失敗しました'*)
    pass "check-repo-hygiene.sh: exclude書き込み失敗時に警告メッセージを出す（#133）" ;;
  *)
    fail "check-repo-hygiene.sh: exclude書き込み失敗時に警告メッセージを出す（#133）" "$HYG_FAILWRITE_OUT" ;;
esac
assert_eq "check-repo-hygiene.sh: exclude書き込み失敗時も対象パスは変質しない（in-place破壊を避ける）（#133）" \
  "not-a-directory" "$(cat -- "${HYG_GITDIR8}/info" 2>/dev/null)"

echo ""
echo "== share-prepared-dirs.sh（準備成果ディレクトリの共有・共有モード） =="

SPD_SCRIPT="${REPO_ROOT}/scripts/share-prepared-dirs.sh"

# --- bash -n が通る ---
if bash -n "$SPD_SCRIPT" 2>/dev/null; then
  pass "share-prepared-dirs.sh: bash -n の構文チェックが通る（#106）"
else
  fail "share-prepared-dirs.sh: bash -n の構文チェックが通る（#106）"
fi

# --- rm / rmdir によるディレクトリ削除が無い（安全ルール）。cleanup-lane-worktrees.sh と
#     同じ検査方法（コメント行を除外し、単語境界での一致だけを見る） ---
SPD_FORBIDDEN_HITS="$(grep -v '^[[:space:]]*#' "$SPD_SCRIPT" \
  | grep -E '(^|[^A-Za-z0-9_])(rm|rmdir)([[:space:]]|$)' || true)"
if [ -z "$SPD_FORBIDDEN_HITS" ]; then
  pass "share-prepared-dirs.sh: rm / rmdir によるディレクトリ削除が無い（#106）"
else
  fail "share-prepared-dirs.sh: rm / rmdir によるディレクトリ削除が無い（#106）" "$SPD_FORBIDDEN_HITS"
fi

# --- スクリプト冒頭のコメントに背景（#104）・使い方・出力形式・終了コードが書かれている ---
SPD_HEADER="$(awk '/^set -u/{exit} {print}' "$SPD_SCRIPT")"
case "$SPD_HEADER" in
  *'#104'*'使い方'*'出力'*'終了コード'*'prep='*)
    pass "share-prepared-dirs.sh: 冒頭コメントに背景（#104）・使い方・出力・終了コードが書かれている（#106）" ;;
  *)
    fail "share-prepared-dirs.sh: 冒頭コメントに背景（#104）・使い方・出力・終了コードが書かれている（#106）" \
      "見つかりませんでした" ;;
esac

# --- テスト用のフェイク sandbox-exec.sh（呼び出し回数を記録してから最後の引数を sh -c で実行する） ---
spd_make_stub() {
  # spd_make_stub <call_log>  スタブスクリプトのパスを出力する
  local call_log="$1" stub
  stub="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-stub.XXXXXX")"
  {
    echo '#!/bin/bash'
    echo 'set -u'
    printf 'echo 1 >> %q\n' "$call_log"
    echo 'cmd="${@: -1}"'
    echo 'sh -c "$cmd"'
  } > "$stub"
  printf '%s' "$stub"
}

spd_run() {
  # spd_run <lane_dir> <stub> [share-prepared-dirs.shへの追加引数...]
  local lane="$1" stub="$2"
  shift 2
  (cd "$lane" || exit 1; DEV_WORKFLOW_SANDBOX_EXEC="$stub" bash "$SPD_SCRIPT" "$@")
}

SPD_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-source.XXXXXX")"
SPD_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-lane.XXXXXX")"
SPD_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-calllog.XXXXXX")"
SPD_STUB="$(spd_make_stub "$SPD_CALL_LOG")"

mkdir -p "${SPD_SOURCE}/node_modules"
printf 'lock-content\n'    > "${SPD_SOURCE}/yarn.lock"
printf 'package-content\n' > "${SPD_SOURCE}/package.json"
printf 'lock-content\n'    > "${SPD_LANE}/yarn.lock"
printf 'package-content\n' > "${SPD_LANE}/package.json"

# --- ケース1: フィンガープリント一致 → linked / 全件 linked なら prep=skip ---
SPD_OUT1="$(spd_run "$SPD_LANE" "$SPD_STUB" --source "$SPD_SOURCE" \
  --dir "node_modules yarn.lock package.json")"
SPD_EXIT1=$?
assert_exit_code "ケース1: フィンガープリント一致で exit 0" 0 "$SPD_EXIT1"

case "$SPD_OUT1" in
  *"linked"*"node_modules"*)
    pass "ケース1: フィンガープリント一致で linked が出る（#106）" ;;
  *)
    fail "ケース1: フィンガープリント一致で linked が出る（#106）" "output=[${SPD_OUT1}]" ;;
esac

case "$SPD_OUT1" in
  *"prep=skip"*)
    pass "ケース1: 全件 linked のとき prep=skip（#106）" ;;
  *)
    fail "ケース1: 全件 linked のとき prep=skip（#106）" "output=[${SPD_OUT1}]" ;;
esac

assert_eq "ケース1: linked 後、レーン側に node_modules が実在する（#106）" \
  "yes" "$([ -e "${SPD_LANE}/node_modules" ] && echo yes || echo no)"

# --- ケース2: レーン側に既に存在する（ケース1の結果を再利用）→ skip reason exists /
#     全件 exists なら prep=skip ---
SPD_OUT2="$(spd_run "$SPD_LANE" "$SPD_STUB" --source "$SPD_SOURCE" \
  --dir "node_modules yarn.lock package.json")"
case "$SPD_OUT2" in
  *"skip"*"node_modules"*"reason"*"exists"*)
    pass "ケース2: レーン側に既に存在する場合 skip reason exists（#106）" ;;
  *)
    fail "ケース2: レーン側に既に存在する場合 skip reason exists（#106）" "output=[${SPD_OUT2}]" ;;
esac
case "$SPD_OUT2" in
  *"prep=skip"*)
    pass "ケース2: 全件 exists のとき prep=skip（#106）" ;;
  *)
    fail "ケース2: 全件 exists のとき prep=skip（#106）" "output=[${SPD_OUT2}]" ;;
esac

# --- ケース3: 共有元にディレクトリが無い → skip reason no-source / prep=run ---
SPD_OUT3="$(spd_run "$SPD_LANE" "$SPD_STUB" --source "$SPD_SOURCE" \
  --dir "does_not_exist_dir")"
case "$SPD_OUT3" in
  *"skip"*"does_not_exist_dir"*"reason"*"no-source"*)
    pass "ケース3: 共有元にディレクトリが無い場合 skip reason no-source（#106）" ;;
  *)
    fail "ケース3: 共有元にディレクトリが無い場合 skip reason no-source（#106）" "output=[${SPD_OUT3}]" ;;
esac
case "$SPD_OUT3" in
  *"prep=run"*)
    pass "ケース3: no-source を含む場合 prep=run（#106）" ;;
  *)
    fail "ケース3: no-source を含む場合 prep=run（#106）" "output=[${SPD_OUT3}]" ;;
esac

# --- ケース4: フィンガープリント不一致・欠損 → skip reason fingerprint-mismatch / prep=run ---
mkdir -p "${SPD_SOURCE}/mmdir" "${SPD_SOURCE}/mmdir2"
printf 'source-value\n' > "${SPD_SOURCE}/mismatch.lock"
printf 'lane-value\n'   > "${SPD_LANE}/mismatch.lock"

SPD_OUT4="$(spd_run "$SPD_LANE" "$SPD_STUB" --source "$SPD_SOURCE" \
  --dir "mmdir mismatch.lock")"
case "$SPD_OUT4" in
  *"skip"*"mmdir"*"reason"*"fingerprint-mismatch"*)
    pass "ケース4: フィンガープリント不一致で skip reason fingerprint-mismatch（#106）" ;;
  *)
    fail "ケース4: フィンガープリント不一致で skip reason fingerprint-mismatch（#106）" "output=[${SPD_OUT4}]" ;;
esac
case "$SPD_OUT4" in
  *"prep=run"*)
    pass "ケース4: fingerprint-mismatch を含む場合 prep=run（#106）" ;;
  *)
    fail "ケース4: fingerprint-mismatch を含む場合 prep=run（#106）" "output=[${SPD_OUT4}]" ;;
esac

# 欠損（レーン側・共有元側ともにフィンガープリントファイルが無い）場合も同様に扱う
SPD_OUT4B="$(spd_run "$SPD_LANE" "$SPD_STUB" --source "$SPD_SOURCE" \
  --dir "mmdir2 missing.lock")"
case "$SPD_OUT4B" in
  *"skip"*"mmdir2"*"reason"*"fingerprint-mismatch"*)
    pass "ケース4b: フィンガープリントファイルが欠損している場合も skip reason fingerprint-mismatch（#106）" ;;
  *)
    fail "ケース4b: フィンガープリントファイルが欠損している場合も skip reason fingerprint-mismatch（#106）" \
      "output=[${SPD_OUT4B}]" ;;
esac

# --- ケース5: --spec の空行・# 始まりの行が無視される ---
SPD_SPEC_TEXT="$(printf '# comment line\n\n   \nno_such_source_dir_for_spec_test\n#trailing comment\n')"
SPD_OUT5="$(spd_run "$SPD_LANE" "$SPD_STUB" --source "$SPD_SOURCE" --spec "$SPD_SPEC_TEXT")"
case "$SPD_OUT5" in
  *"skip"*"no_such_source_dir_for_spec_test"*"reason"*"no-source"*)
    pass "ケース5: --spec の空行・#始まりの行を挟んでも実体エントリは正しく解釈される（#106）" ;;
  *)
    fail "ケース5: --spec の空行・#始まりの行を挟んでも実体エントリは正しく解釈される（#106）" \
      "output=[${SPD_OUT5}]" ;;
esac
SPD_OUT5_LINES="$(printf '%s\n' "$SPD_OUT5" | grep -c '.')"
assert_eq "ケース5: --spec の空行・#始まりの行は実体エントリとして混入せず出力は2行（対象1件+prep）のみ（#106）" \
  "2" "$SPD_OUT5_LINES"

# --- ケース6: --dry-run で linked を出すが実際には symlink を作らない ---
mkdir -p "${SPD_SOURCE}/dryrun_dir"
SPD_OUT6="$(spd_run "$SPD_LANE" "$SPD_STUB" --source "$SPD_SOURCE" --dir "dryrun_dir" --dry-run)"
case "$SPD_OUT6" in
  *"linked"*"dryrun_dir"*)
    pass "ケース6: --dry-run でも linked 行が出る（#106）" ;;
  *)
    fail "ケース6: --dry-run でも linked 行が出る（#106）" "output=[${SPD_OUT6}]" ;;
esac
assert_eq "ケース6: --dry-run では実際には symlink が作られない（#106）" \
  "no" "$([ -e "${SPD_LANE}/dryrun_dir" ] && echo yes || echo no)"

# --- ケース7: symlink 作成に失敗 → skip reason link-failed / prep=run
#     （レーン側の親ディレクトリが存在しないため ln -s が実際に失敗する） ---
mkdir -p "${SPD_SOURCE}/nopar/child"
SPD_OUT7="$(spd_run "$SPD_LANE" "$SPD_STUB" --source "$SPD_SOURCE" --dir "nopar/child")"
case "$SPD_OUT7" in
  *"skip"*"nopar/child"*"reason"*"link-failed"*)
    pass "ケース7: symlink 作成に失敗すると skip reason link-failed（#106）" ;;
  *)
    fail "ケース7: symlink 作成に失敗すると skip reason link-failed（#106）" "output=[${SPD_OUT7}]" ;;
esac
case "$SPD_OUT7" in
  *"prep=run"*)
    pass "ケース7: link-failed を含む場合 prep=run（#106）" ;;
  *)
    fail "ケース7: link-failed を含む場合 prep=run（#106）" "output=[${SPD_OUT7}]" ;;
esac

# --- ケース8: --source 欠落・値なしオプションで exit 2（無限ループしない） ---
if command -v timeout >/dev/null 2>&1; then
  SPD_NOSRC_OUT="$(timeout 5 bash "$SPD_SCRIPT" --dir "x" 2>&1)"
  SPD_NOSRC_EXIT=$?
  assert_no_hang "ケース8: --source 欠落は無限ループせず exit 2（#106）" \
    2 "$SPD_NOSRC_EXIT" "$SPD_NOSRC_OUT" "--source は必須です"

  SPD_NOVAL_OPTS=(--source --spec --dir --epic)
  for SPD_NOVAL_OPT in "${SPD_NOVAL_OPTS[@]}"; do
    SPD_NOVAL_OUT="$(timeout 5 bash "$SPD_SCRIPT" --source "$SPD_SOURCE" "$SPD_NOVAL_OPT" 2>&1)"
    SPD_NOVAL_EXIT=$?
    assert_no_hang "ケース8: ${SPD_NOVAL_OPT} が末尾で値なしでも無限ループせず exit 2（#106）" \
      2 "$SPD_NOVAL_EXIT" "$SPD_NOVAL_OUT" "${SPD_NOVAL_OPT} には値が必要です"
  done

  SPD_UNKNOWN_OUT="$(timeout 5 bash "$SPD_SCRIPT" --source "$SPD_SOURCE" --unknown-option 2>&1)"
  SPD_UNKNOWN_EXIT=$?
  assert_no_hang "ケース8: 未知のオプションは無限ループせず exit 2（#106）" \
    2 "$SPD_UNKNOWN_EXIT" "$SPD_UNKNOWN_OUT" "未知のオプション"
else
  skip "share-prepared-dirs.sh: --source 欠落・値なしオプションで無限ループしない（#106）" \
    "timeout コマンドが利用できません"
fi

# --- ケース9: コンテナへの投入が1回にまとめられている（スタブの呼び出し回数で検証する） ---
SPD_CALL_LOG9="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-calllog9.XXXXXX")"
SPD_STUB9="$(spd_make_stub "$SPD_CALL_LOG9")"
mkdir -p "${SPD_SOURCE}/multi_a" "${SPD_SOURCE}/multi_b"

SPD_OUT9="$(spd_run "$SPD_LANE" "$SPD_STUB9" --source "$SPD_SOURCE" \
  --dir "multi_a" --dir "multi_b" --dir "no_source_multi" --epic epic105)"
SPD_EXIT9=$?
assert_exit_code "ケース9: 複数エントリでも exit 0" 0 "$SPD_EXIT9"

SPD_CALL_COUNT9="$(grep -c '.' "$SPD_CALL_LOG9" 2>/dev/null || echo 0)"
assert_eq "ケース9: 複数エントリ（no-source混在）でもコンテナ呼び出しは1回にまとめられる（#106）" \
  "1" "$SPD_CALL_COUNT9"

case "$SPD_OUT9" in
  *"linked"*"multi_a"*"linked"*"multi_b"*)
    pass "ケース9: 1回の呼び出しでも複数エントリが正しくlinkedとして報告される（#106）" ;;
  *)
    fail "ケース9: 1回の呼び出しでも複数エントリが正しくlinkedとして報告される（#106）" \
      "output=[${SPD_OUT9}]" ;;
esac

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh --detach（共有リンクの解除、Task #110）
#
# 依存マニフェスト（package.json 等）を変更するタスクが install 前に共有リンクを
# 解除するためのモード。共有モードと同じスタブ（DEV_WORKFLOW_SANDBOX_EXEC）を使い、
# Docker 非依存に検証する。symlink の判定・解除もこの host 上の sh -c で実際に行われる
# ため、判定には -L ではなく -e（存在有無）を使う（ホストが Windows の場合 test -L が
# 誤判定しうるのは冒頭コメントに記載の既知の制約であり、-e はその影響を受けない）。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh --detach（共有リンクの解除） =="

SPD_DETACH_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-detach-lane.XXXXXX")"
SPD_DETACH_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-detach-calllog.XXXXXX")"
SPD_DETACH_STUB="$(spd_make_stub "$SPD_DETACH_CALL_LOG")"

# --- 準備: symlink 1件・実体ディレクトリ1件を用意する（absent は何も作らない） ---
mkdir -p "${SPD_DETACH_LANE}/detach_real_target"
(cd "${SPD_DETACH_LANE}" && ln -s "detach_real_target" "detach_link_dir")
mkdir -p "${SPD_DETACH_LANE}/detach_entity_dir"

# --- ケース1: symlink を解除して detached を出す ---
SPD_DOUT1="$(spd_run "$SPD_DETACH_LANE" "$SPD_DETACH_STUB" --detach --dir "detach_link_dir")"
SPD_DEXIT1=$?
assert_exit_code "--detach ケース1: symlink 解除で exit 0" 0 "$SPD_DEXIT1"
case "$SPD_DOUT1" in
  *"detached"*"detach_link_dir"*)
    pass "--detach ケース1: symlink を解除して detached を出す（#110）" ;;
  *)
    fail "--detach ケース1: symlink を解除して detached を出す（#110）" "output=[${SPD_DOUT1}]" ;;
esac
assert_eq "--detach ケース1: 解除後、レーン側の symlink は消える（#110）" \
  "no" "$([ -e "${SPD_DETACH_LANE}/detach_link_dir" ] && echo yes || echo no)"

# --- ケース2: 実体ディレクトリは skip reason not-a-link で保護され、削除されない ---
SPD_DOUT2="$(spd_run "$SPD_DETACH_LANE" "$SPD_DETACH_STUB" --detach --dir "detach_entity_dir")"
case "$SPD_DOUT2" in
  *"skip"*"detach_entity_dir"*"reason"*"not-a-link"*)
    pass "--detach ケース2: 実体ディレクトリは skip reason not-a-link で保護される（#110）" ;;
  *)
    fail "--detach ケース2: 実体ディレクトリは skip reason not-a-link で保護される（#110）" \
      "output=[${SPD_DOUT2}]" ;;
esac
assert_eq "--detach ケース2: 実体ディレクトリは削除されない（#110）" \
  "yes" "$([ -d "${SPD_DETACH_LANE}/detach_entity_dir" ] && echo yes || echo no)"

# --- ケース3: 存在しない場合 skip reason absent ---
SPD_DOUT3="$(spd_run "$SPD_DETACH_LANE" "$SPD_DETACH_STUB" --detach --dir "detach_missing_dir")"
case "$SPD_DOUT3" in
  *"skip"*"detach_missing_dir"*"reason"*"absent"*)
    pass "--detach ケース3: 存在しない場合 skip reason absent（#110）" ;;
  *)
    fail "--detach ケース3: 存在しない場合 skip reason absent（#110）" "output=[${SPD_DOUT3}]" ;;
esac

# --- ケース4: --dir を複数指定できる／--detach では prep= 行を出さない／
#     コンテナへの投入は1回にまとめられる（スタブの呼び出し回数で検証する） ---
mkdir -p "${SPD_DETACH_LANE}/detach_multi_target_a" "${SPD_DETACH_LANE}/detach_multi_target_b"
(cd "${SPD_DETACH_LANE}" && ln -s "detach_multi_target_a" "detach_multi_link_a")
(cd "${SPD_DETACH_LANE}" && ln -s "detach_multi_target_b" "detach_multi_link_b")

SPD_DETACH_CALL_LOG4="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-detach-calllog4.XXXXXX")"
SPD_DETACH_STUB4="$(spd_make_stub "$SPD_DETACH_CALL_LOG4")"

SPD_DOUT4="$(spd_run "$SPD_DETACH_LANE" "$SPD_DETACH_STUB4" --detach \
  --dir "detach_multi_link_a" --dir "detach_multi_link_b" --dir "detach_missing_dir2")"
SPD_DEXIT4=$?
assert_exit_code "--detach ケース4: 複数エントリでも exit 0" 0 "$SPD_DEXIT4"

case "$SPD_DOUT4" in
  *"detached"*"detach_multi_link_a"*"detached"*"detach_multi_link_b"*)
    pass "--detach ケース4: --dir を複数指定でき、それぞれ detached が出る（#110）" ;;
  *)
    fail "--detach ケース4: --dir を複数指定でき、それぞれ detached が出る（#110）" \
      "output=[${SPD_DOUT4}]" ;;
esac

case "$SPD_DOUT4" in
  *"prep="*)
    fail "--detach ケース4: --detach では prep= 行を出さない（#110）" "output=[${SPD_DOUT4}]" ;;
  *)
    pass "--detach ケース4: --detach では prep= 行を出さない（#110）" ;;
esac

SPD_DETACH_CALL_COUNT4="$(grep -c '.' "$SPD_DETACH_CALL_LOG4" 2>/dev/null || echo 0)"
assert_eq "--detach ケース4: 複数エントリ（absent混在）でもコンテナ呼び出しは1回にまとめられる（#110）" \
  "1" "$SPD_DETACH_CALL_COUNT4"

# --- ケース5: --dry-run では実際には解除しない ---
mkdir -p "${SPD_DETACH_LANE}/detach_dryrun_target"
(cd "${SPD_DETACH_LANE}" && ln -s "detach_dryrun_target" "detach_dryrun_link")

SPD_DOUT5="$(spd_run "$SPD_DETACH_LANE" "$SPD_DETACH_STUB" --detach --dir "detach_dryrun_link" --dry-run)"
case "$SPD_DOUT5" in
  *"detached"*"detach_dryrun_link"*)
    pass "--detach ケース5: --dry-run でも detached 行が出る（#110）" ;;
  *)
    fail "--detach ケース5: --dry-run でも detached 行が出る（#110）" "output=[${SPD_DOUT5}]" ;;
esac
assert_eq "--detach ケース5: --dry-run では実際には解除しない（#110）" \
  "yes" "$([ -e "${SPD_DETACH_LANE}/detach_dryrun_link" ] && echo yes || echo no)"

# --- ケース6: --detach 指定時に --dir が1つも無いと無限ループせず exit 2 ---
if command -v timeout >/dev/null 2>&1; then
  SPD_DETACH_NODIR_OUT="$(timeout 5 bash "$SPD_SCRIPT" --detach 2>&1)"
  SPD_DETACH_NODIR_EXIT=$?
  assert_no_hang "--detach ケース6: --dir 皆無は無限ループせず exit 2（#110）" \
    2 "$SPD_DETACH_NODIR_EXIT" "$SPD_DETACH_NODIR_OUT" "--dir が1つ以上必要です"
else
  skip "share-prepared-dirs.sh --detach: --dir 皆無で無限ループしない（#110）" \
    "timeout コマンドが利用できません"
fi

# ---------------------------------------------------------------------------
# Task #125: 共通ルールに「ハーネス非注入原則」を追加し「前提」節の推奨順を反転する
#
# ハーネス専用のファイルが駆動先（業務）リポジトリのPRに混入する問題（issue #120）に対し、
# 「## サンドボックス方針」の「### 前提」を3択（規約パス > 環境変数 > リポジトリ直下）に
# 書き換え、新節「## ハーネス非注入原則」を追加したことを検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== Task #125: 共通ルールに『ハーネス非注入原則』を追加し『前提』節の推奨順を反転する =="

# --- core/instructions.md: 「### 前提」節が3択（規約パス/環境変数/リポジトリ直下）を
#     リポジトリを汚さない選択肢を第一候補として明記している ---
INSTR_PREREQ_SECTION="$(awk '/^### 前提$/{f=1; next} /^### プロジェクト固有の準備コマンド/{f=0} f' \
  "${REPO_ROOT}/core/instructions.md")"

if [ -z "$INSTR_PREREQ_SECTION" ]; then
  fail "core/instructions.md: 『### 前提』節が見つかる（#125）" "節が空でした"
else
  pass "core/instructions.md: 『### 前提』節が見つかる（#125）"
fi

case "$INSTR_PREREQ_SECTION" in
  *'規約パスに置く（推奨）'*'~/.claude/dev-workflow/sandbox/'*'DEV_WORKFLOW_DOCKERFILE'*'DEV_WORKFLOW_DOCKER_COMPOSE_FILE'*'DEV_WORKFLOW_DOCKER_IMAGE'*'リポジトリ直下に置いてコミットする'*'チームで run を共有する場合のみ'*)
    pass "core/instructions.md: 『### 前提』節が3択（規約パス→環境変数→リポジトリ直下）を明記している（#125）" ;;
  *)
    fail "core/instructions.md: 『### 前提』節が3択（規約パス→環境変数→リポジトリ直下）を明記している（#125）" \
      "$INSTR_PREREQ_SECTION" ;;
esac

case "$INSTR_PREREQ_SECTION" in
  *'docker build'*'docker compose up'*'直接叩いてはならない'*'mode=none'*'自律モードを開始せずに停止する'*)
    pass "core/instructions.md: 『### 前提』節に既存の維持事項（docker直接呼び出し禁止・mode=none停止）が残っている（#125）" ;;
  *)
    fail "core/instructions.md: 『### 前提』節に既存の維持事項（docker直接呼び出し禁止・mode=none停止）が残っている（#125）" \
      "$INSTR_PREREQ_SECTION" ;;
esac

# --- core/instructions.md 本体に「## ハーネス非注入原則」の見出し・原則1文・検証コマンドが
#     残っている。詳細な対応表・背景は core/references/harness-hygiene.md へ退避されている
#     （#125。退避は #146） ---
INSTR_NOINJECT_MAIN_SECTION="$(awk '/^## ハーネス非注入原則/{f=1} /^## 停止させるものと、記録して進めるもの/{f=0} f' \
  "${REPO_ROOT}/core/instructions.md")"

if [ -z "$INSTR_NOINJECT_MAIN_SECTION" ]; then
  fail "core/instructions.md: 『## ハーネス非注入原則』節が見つかる（#125）" "節が空でした"
else
  pass "core/instructions.md: 『## ハーネス非注入原則』節が見つかる（#125）"
fi

case "$INSTR_NOINJECT_MAIN_SECTION" in
  *'駆動先の業務リポジトリに注入しない'*)
    pass "core/instructions.md: ハーネス非注入原則の宣言文がある（#125）" ;;
  *)
    fail "core/instructions.md: ハーネス非注入原則の宣言文がある（#125）" \
      "$INSTR_NOINJECT_MAIN_SECTION" ;;
esac

case "$INSTR_NOINJECT_MAIN_SECTION" in
  *'check-repo-hygiene.sh'*)
    pass "core/instructions.md: 検証はscripts/check-repo-hygiene.shが行う旨が明記されている（#125）" ;;
  *)
    fail "core/instructions.md: 検証はscripts/check-repo-hygiene.shが行う旨が明記されている（#125）" \
      "$INSTR_NOINJECT_MAIN_SECTION" ;;
esac

# --- core/references/harness-hygiene.md に対応表・詳細な背景が退避されている（#146） ---
INSTR_NOINJECT_SECTION="$(cat "${REPO_ROOT}/core/references/harness-hygiene.md")"

case "$INSTR_NOINJECT_SECTION" in
  *'サンドボックス定義'*'~/.claude/dev-workflow/sandbox/<repo>/'*'YOLO 用の permission 設定'*'.claude/settings.local.json'*'マーカー・状態ファイル・worktree'*'.git/info/exclude'*'.gitignore'*'駆動先の共有ファイルなので触らない'*)
    pass "core/references/harness-hygiene.md: ハーネス由来のものと置き場所の対応表（3行）が明記されている（#125）" ;;
  *)
    fail "core/references/harness-hygiene.md: ハーネス由来のものと置き場所の対応表（3行）が明記されている（#125）" \
      "$INSTR_NOINJECT_SECTION" ;;
esac

case "$INSTR_NOINJECT_SECTION" in
  *'DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS=1'*'同意なく適用される'*)
    pass "core/references/harness-hygiene.md: git追跡されたsettings.local.jsonはrunをブロックする旨とその理由が明記されている（#125）" ;;
  *)
    fail "core/references/harness-hygiene.md: git追跡されたsettings.local.jsonはrunをブロックする旨とその理由が明記されている（#125）" \
      "$INSTR_NOINJECT_SECTION" ;;
esac

# --- 生成物（agents/*.md・codex-agents/*.toml）にもcore/instructions.mdの
#     ハーネス非注入原則節が伝播している（build.shの再生成漏れを検知する） ---
for f in agents/planner.md agents/generator.md agents/evaluator.md \
         codex-agents/planner.toml codex-agents/generator.toml codex-agents/evaluator.toml; do
  if grep -Fq -- '## ハーネス非注入原則' "${REPO_ROOT}/${f}"; then
    pass "${f}: core/instructions.mdのハーネス非注入原則節が生成物に反映されている（#125）"
  else
    fail "${f}: core/instructions.mdのハーネス非注入原則節が生成物に反映されている（#125）" \
      "節が見つかりませんでした"
  fi
done

# ---------------------------------------------------------------------------
# Task #107: Epic本文の「## 共有ディレクトリ」節がplanner・共通ルールに定義されている
#
# レーンごとのフル install（#104）を避けるための共有宣言。既存の「## 準備コマンド」節・
# 「## SKIPパターン」節と対称な位置・対称な書き方であることを検証する。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# check-repo-hygiene.sh（sandbox定義の混入検知: sandbox_in_repo_untracked）（#127）
# ---------------------------------------------------------------------------

echo ""
echo "== check-repo-hygiene.sh（sandbox定義の混入検知: sandbox_in_repo_untracked） =="

# --- 完了条件1: 未追跡のDockerfile.devがリポジトリ直下にあると
#     sandbox_in_repo_untracked=yes、verdict=warn、既定モード・--run ともにexit 0（完了条件7も兼ねる） ---
HYG_SBX1="$(make_temp_repo)"
printf 'FROM alpine\n' > "${HYG_SBX1}/Dockerfile.dev"
HYG_SBX1_OUT="$( cd "$HYG_SBX1" && bash "$HYG_SCRIPT" --print 2>/dev/null )"
HYG_SBX1_EXIT=$?
HYG_SBX1_RUN_OUT="$( cd "$HYG_SBX1" && bash "$HYG_SCRIPT" --run --print 2>/dev/null )"
HYG_SBX1_RUN_EXIT=$?
assert_eq "check-repo-hygiene.sh: 未追跡Dockerfile.devでsandbox_in_repo_untracked=yes（#127完了条件1）" \
  "yes" "$(printf '%s\n' "$HYG_SBX1_OUT" | sed -n 's/^sandbox_in_repo_untracked=//p')"
assert_eq "check-repo-hygiene.sh: 未追跡Dockerfile.devでverdict=warn（#127完了条件1）" \
  "warn" "$(printf '%s\n' "$HYG_SBX1_OUT" | sed -n 's/^verdict=//p')"
assert_exit_code "check-repo-hygiene.sh: 未追跡Dockerfile.devでも既定モードはexit 0（#127完了条件1）" 0 "$HYG_SBX1_EXIT"
assert_exit_code "check-repo-hygiene.sh: 未追跡Dockerfile.devでも--runはexit 0（ブロックしない）（#127完了条件1・7）" 0 "$HYG_SBX1_RUN_EXIT"
assert_eq "check-repo-hygiene.sh: --run時もverdict=warnのまま（#127完了条件7）" \
  "warn" "$(printf '%s\n' "$HYG_SBX1_RUN_OUT" | sed -n 's/^verdict=//p')"

# --- 完了条件2: 同じDockerfile.devをgit addして追跡させるとsandbox_in_repo_untracked=no ---
( cd "$HYG_SBX1" && git add Dockerfile.dev && git commit -q -m "add sandbox dockerfile" ) >/dev/null 2>&1
HYG_SBX2_OUT="$( cd "$HYG_SBX1" && bash "$HYG_SCRIPT" --print 2>/dev/null )"
assert_eq "check-repo-hygiene.sh: 追跡済みDockerfile.devでsandbox_in_repo_untracked=no（#127完了条件2）" \
  "no" "$(printf '%s\n' "$HYG_SBX2_OUT" | sed -n 's/^sandbox_in_repo_untracked=//p')"
assert_eq "check-repo-hygiene.sh: 追跡済みDockerfile.devでverdict=ok（#127完了条件2）" \
  "ok" "$(printf '%s\n' "$HYG_SBX2_OUT" | sed -n 's/^verdict=//p')"

# --- 完了条件3: 未追跡のdocker-compose.dev.yml（Dockerfile.devは無し）でもyesになる（compose経路も見ている） ---
HYG_SBX3="$(make_temp_repo)"
printf 'services:\n  app:\n    image: alpine\n' > "${HYG_SBX3}/docker-compose.dev.yml"
HYG_SBX3_OUT="$( cd "$HYG_SBX3" && bash "$HYG_SCRIPT" --print 2>/dev/null )"
assert_eq "check-repo-hygiene.sh: 未追跡docker-compose.dev.ymlでsandbox_in_repo_untracked=yes（#127完了条件3）" \
  "yes" "$(printf '%s\n' "$HYG_SBX3_OUT" | sed -n 's/^sandbox_in_repo_untracked=//p')"

# --- 完了条件4: sandbox定義が無くmode=noneならsandbox_in_repo_untracked=no（警告を出さない） ---
HYG_SBX4="$(make_temp_repo)"
HYG_SBX4_OUT="$( cd "$HYG_SBX4" && bash "$HYG_SCRIPT" --print 2>/dev/null )"
HYG_SBX4_STDERR="$( cd "$HYG_SBX4" && bash "$HYG_SCRIPT" --print 2>&1 1>/dev/null )"
assert_eq "check-repo-hygiene.sh: sandbox定義が無ければsandbox_in_repo_untracked=no（#127完了条件4）" \
  "no" "$(printf '%s\n' "$HYG_SBX4_OUT" | sed -n 's/^sandbox_in_repo_untracked=//p')"
case "$HYG_SBX4_STDERR" in
  *'ハーネス用サンドボックス定義'*)
    fail "check-repo-hygiene.sh: sandbox定義が無ければ警告を出さない（#127完了条件4）" "$HYG_SBX4_STDERR" ;;
  *)
    pass "check-repo-hygiene.sh: sandbox定義が無ければ警告を出さない（#127完了条件4）" ;;
esac

# --- 完了条件5: DEV_WORKFLOW_SANDBOX_HOMEで差し替えた規約パスだけに定義がある場合はno
#     （リポジトリ外なので原則どおりの状態） ---
HYG_SBX5="$(make_temp_repo)"
HYG_SBX5_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hyg-sbxhome.XXXXXX")"
HYG_SBX5_REPO_NAME="$(basename "$HYG_SBX5")"
mkdir -p "${HYG_SBX5_HOME}/${HYG_SBX5_REPO_NAME}"
printf 'FROM alpine\n' > "${HYG_SBX5_HOME}/${HYG_SBX5_REPO_NAME}/Dockerfile.dev"
HYG_SBX5_OUT="$( cd "$HYG_SBX5" && DEV_WORKFLOW_SANDBOX_HOME="$HYG_SBX5_HOME" bash "$HYG_SCRIPT" --print 2>/dev/null )"
assert_eq "check-repo-hygiene.sh: 規約パス（リポジトリ外）だけに定義がある場合はsandbox_in_repo_untracked=no（#127完了条件5）" \
  "no" "$(printf '%s\n' "$HYG_SBX5_OUT" | sed -n 's/^sandbox_in_repo_untracked=//p')"

# --- 完了条件6: DEV_WORKFLOW_DOCKERFILEでリポジトリ外のファイルを明示指定した場合もno ---
HYG_SBX6="$(make_temp_repo)"
HYG_SBX6_EXTERNAL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-hyg-sbxext.XXXXXX")"
printf 'FROM alpine\n' > "${HYG_SBX6_EXTERNAL_DIR}/External.dockerfile"
HYG_SBX6_OUT="$( cd "$HYG_SBX6" && DEV_WORKFLOW_DOCKERFILE="${HYG_SBX6_EXTERNAL_DIR}/External.dockerfile" bash "$HYG_SCRIPT" --print 2>/dev/null )"
assert_eq "check-repo-hygiene.sh: リポジトリ外を明示指定したDockerfileはsandbox_in_repo_untracked=no（#127完了条件6）" \
  "no" "$(printf '%s\n' "$HYG_SBX6_OUT" | sed -n 's/^sandbox_in_repo_untracked=//p')"

# 完了条件8（shellcheck / bash -n が通ること）は冒頭の全 scripts/*.sh 走査
# （bash -n（構文チェック）／shellcheck（利用可能な場合のみ）」の各セクション）で
# check-repo-hygiene.sh も対象に含まれているため、ここでは重複させない。

# ---------------------------------------------------------------------------
# Task #134: README.mdのSlack設定節が.gitignore追記を指示し続け非注入原則と
# 矛盾していた点の回帰テスト（#122一括レビュー指摘、由来: #130）
# ---------------------------------------------------------------------------

echo ""
echo "== Task #134: README.mdのSlack設定節に.gitignore追記案内が残っていない =="

# --- README.md に「.claude/slack-webhook」を.gitignoreへ追記する案内が残っていない ---
if grep -Fq -- 'echo ".claude/slack-webhook" >> .gitignore' "${REPO_ROOT}/README.md"; then
  fail "README.md: Slack設定節に『.claude/slack-webhookを.gitignoreに追記する』案内が残っていない（#134）" \
    "$(grep -n -- 'echo ".claude/slack-webhook" >> .gitignore' "${REPO_ROOT}/README.md")"
else
  pass "README.md: Slack設定節に『.claude/slack-webhookを.gitignoreに追記する』案内が残っていない（#134）"
fi

# --- README.md のSlack設定節が.git/info/excludeによる自動除外を案内している ---
README_SLACK_SECTION="$(awk '/^## Slack通知/{f=1} /^### 通知されるタイミング/{f=0} f' "${REPO_ROOT}/README.md")"
if [ -z "$README_SLACK_SECTION" ]; then
  fail "README.md: 『## Slack通知』節が見つかる（前提）（#134）" "節が空でした"
else
  pass "README.md: 『## Slack通知』節が見つかる（前提）（#134）"
fi

case "$README_SLACK_SECTION" in
  *'.git/info/exclude'*'check-repo-hygiene.sh'*)
    pass "README.md: Slack設定節が.git/info/excludeによる自動除外とcheck-repo-hygiene.shでの整備を案内している（#134）" ;;
  *)
    fail "README.md: Slack設定節が.git/info/excludeによる自動除外とcheck-repo-hygiene.shでの整備を案内している（#134）" \
      "$README_SLACK_SECTION" ;;
esac

# --- README.md のSlack設定節にWebhook URLが秘密情報である旨の注意が残っている ---
case "$README_SLACK_SECTION" in
  *'秘密情報'*)
    pass "README.md: Slack設定節にWebhook URLが秘密情報である旨の注意が残っている（#134）" ;;
  *)
    fail "README.md: Slack設定節にWebhook URLが秘密情報である旨の注意が残っている（#134）" \
      "$README_SLACK_SECTION" ;;
esac

echo ""
echo "== Task #107: Epic本文の『## 共有ディレクトリ』節がplanner・共通ルールに定義されている =="

# --- core/roles/planner.md: 「プロジェクト固有の準備コマンド」と「SKIPパターン」の間に
#     共有ディレクトリ節の書き方がある ---
PLANNER_SHAREDIR_SECTION="$(awk '/^#### 共有ディレクトリ（該当する場合のみ）/{f=1} /^#### SKIPパターン（該当する場合のみ）/{f=0} f' \
  "${REPO_ROOT}/core/roles/planner.md")"

if [ -z "$PLANNER_SHAREDIR_SECTION" ]; then
  fail "core/roles/planner.md: 『#### 共有ディレクトリ（該当する場合のみ）』節が見つかる（#107）" "節が空でした"
else
  pass "core/roles/planner.md: 『#### 共有ディレクトリ（該当する場合のみ）』節が見つかる（#107）"
fi

case "$PLANNER_SHAREDIR_SECTION" in
  *'## 共有ディレクトリ'*'<共有するディレクトリ>'*'<フィンガープリントファイル>'*)
    pass "core/roles/planner.md: 共有ディレクトリ節の見出し・行書式（空白区切り・リポジトリルート相対）が明記されている（#107）" ;;
  *)
    fail "core/roles/planner.md: 共有ディレクトリ節の見出し・行書式（空白区切り・リポジトリルート相対）が明記されている（#107）" \
      "$PLANNER_SHAREDIR_SECTION" ;;
esac

case "$PLANNER_SHAREDIR_SECTION" in
  *'node_modules'*'yarn.lock'*'package.json'*)
    pass "core/roles/planner.md: 共有ディレクトリ節の例（node_modules  yarn.lock package.json）がある（#107）" ;;
  *)
    fail "core/roles/planner.md: 共有ディレクトリ節の例（node_modules  yarn.lock package.json）がある（#107）" \
      "$PLANNER_SHAREDIR_SECTION" ;;
esac

case "$PLANNER_SHAREDIR_SECTION" in
  *'フィンガープリントには lockfile を必ず書く'*)
    pass "core/roles/planner.md: フィンガープリントにlockfileを必ず書く旨が明記されている（#107）" ;;
  *)
    fail "core/roles/planner.md: フィンガープリントにlockfileを必ず書く旨が明記されている（#107）" \
      "$PLANNER_SHAREDIR_SECTION" ;;
esac

case "$PLANNER_SHAREDIR_SECTION" in
  *'Task issue 側にはこの節を書かない'*)
    pass "core/roles/planner.md: Task issue側には書かない旨が明記されている（#107）" ;;
  *)
    fail "core/roles/planner.md: Task issue側には書かない旨が明記されている（#107）" \
      "$PLANNER_SHAREDIR_SECTION" ;;
esac

# --- core/instructions.md: 「Epic 本文の『## SKIPパターン』節」と対称な位置に
#     「Epic 本文の『## 共有ディレクトリ』節」がある ---
# --- core/references/epic-sections.md: 「Epic 本文の『## SKIPパターン』節」と対称な位置に
#     「Epic 本文の『## 共有ディレクトリ』節」がある（詳細は core/instructions.md 本体から
#     core/references/epic-sections.md へ退避されている・#146） ---
INSTR_SHAREDIR_SECTION="$(awk '/^### Epic 本文の `## 共有ディレクトリ` 節/{f=1} /^### Epic 本文の `## SKIPパターン` 節/{f=0} f' \
  "${REPO_ROOT}/core/references/epic-sections.md")"

if [ -z "$INSTR_SHAREDIR_SECTION" ]; then
  fail "core/references/epic-sections.md: 『### Epic 本文の \`## 共有ディレクトリ\` 節』が見つかる（#107）" "節が空でした"
else
  pass "core/references/epic-sections.md: 『### Epic 本文の \`## 共有ディレクトリ\` 節』が見つかる（#107）"
fi

case "$INSTR_SHAREDIR_SECTION" in
  *'#104'*'Step 3'*'generator プロンプトへ渡す'*)
    pass "core/references/epic-sections.md: runがEpic開始時に節を読みStep 3のgeneratorプロンプトへ渡す旨が明記されている（#107）" ;;
  *)
    fail "core/references/epic-sections.md: runがEpic開始時に節を読みStep 3のgeneratorプロンプトへ渡す旨が明記されている（#107）" \
      "$INSTR_SHAREDIR_SECTION" ;;
esac

case "$INSTR_SHAREDIR_SECTION" in
  *'節を書くかどうかの判断は planner が行う'*)
    pass "core/references/epic-sections.md: 節を書くかどうかの判断はplannerが行う旨が明記されている（#107）" ;;
  *)
    fail "core/references/epic-sections.md: 節を書くかどうかの判断はplannerが行う旨が明記されている（#107）" \
      "$INSTR_SHAREDIR_SECTION" ;;
esac

# --- 生成物（agents/*.md・codex-agents/*.toml）にもcore/instructions.mdの共有ディレクトリ節が
#     伝播している（build.shの再生成漏れを検知する） ---
for f in agents/planner.md agents/generator.md agents/evaluator.md \
         codex-agents/planner.toml codex-agents/generator.toml codex-agents/evaluator.toml; do
  if grep -Fq -- '### Epic 本文の `## 共有ディレクトリ` 節' "${REPO_ROOT}/${f}"; then
    pass "${f}: core/instructions.mdの共有ディレクトリ節が生成物に反映されている（#107）"
  else
    fail "${f}: core/instructions.mdの共有ディレクトリ節が生成物に反映されている（#107）" \
      "節が見つかりませんでした"
  fi
done

# --- 生成物（agents/planner.md・codex-agents/planner.toml）にもcore/roles/planner.mdの
#     共有ディレクトリ節が伝播している ---
for f in agents/planner.md codex-agents/planner.toml; do
  if grep -Fq -- '#### 共有ディレクトリ（該当する場合のみ）' "${REPO_ROOT}/${f}"; then
    pass "${f}: core/roles/planner.mdの共有ディレクトリ節が生成物に反映されている（#107）"
  else
    fail "${f}: core/roles/planner.mdの共有ディレクトリ節が生成物に反映されている（#107）" \
      "節が見つかりませんでした"
  fi
done

# ---------------------------------------------------------------------------
# Task #146: core/references/ による参照機構（core/instructions.md の progressive disclosure）
# ---------------------------------------------------------------------------

echo ""
echo "== Task #146: core/references/ による参照機構 =="

# --- core/references/ に退避先ファイルが実在する ---
for f in watchdog.md epic-sections.md harness-hygiene.md; do
  if [ -f "${REPO_ROOT}/core/references/${f}" ]; then
    pass "core/references/${f}: ファイルが実在する（#146）"
  else
    fail "core/references/${f}: ファイルが実在する（#146）" "見つかりません"
  fi
done

# --- core/instructions.md のポインタ行から参照されているパスが実際に解決できる ---
# `${CLAUDE_PLUGIN_ROOT}/core/references/<名前>.md` という記法でポインタ行に書かれている
# パスを1つずつ取り出し、リポジトリルートからの相対パスとして実在するかを確認する。
# for/whileのパイプはサブシェルになりPASS/FAILカウンタが親シェルに伝播しないため、
# 配列 + for（サブシェルを作らない）で回す（review#99 と同じ作法）。
CORE146_POINTER_PATHS=()
while IFS= read -r p; do
  [ -n "$p" ] && CORE146_POINTER_PATHS+=("$p")
done < <(grep -oE 'core/references/[A-Za-z0-9_-]+\.md' "${REPO_ROOT}/core/instructions.md" | sort -u)

if [ "${#CORE146_POINTER_PATHS[@]}" -eq 0 ]; then
  fail "core/instructions.md: core/references/ へのポインタ行が1つ以上ある（#146）" "見つかりません"
else
  pass "core/instructions.md: core/references/ へのポインタ行が1つ以上ある（#146）"
fi

for p in "${CORE146_POINTER_PATHS[@]}"; do
  if [ -f "${REPO_ROOT}/${p}" ]; then
    pass "core/instructions.md のポインタ行: ${p} が解決できる（#146）"
  else
    fail "core/instructions.md のポインタ行: ${p} が解決できる（#146）" "見つかりません: ${p}"
  fi
done

# --- core/instructions.md は core/references/*.md を <!-- include: --> でインライン展開して
#     いない（インライン展開すると本文が再び膨らみ、薄くする目的に反するため） ---
if grep -Fq -- '<!-- include: core/references/' "${REPO_ROOT}/core/instructions.md"; then
  fail "core/instructions.md: core/references/*.md を <!-- include: --> で展開していない（#146）" \
    "include指定が見つかりました"
else
  pass "core/instructions.md: core/references/*.md を <!-- include: --> で展開していない（#146）"
fi

# --- 生成物（agents/*.md・codex-agents/*.toml）にも core/references/*.md の本文が
#     インライン展開されていない（本文だけを include する既存の仕組みを踏襲しているため、
#     参照ファイルの本文そのものは生成物に現れないはず） ---
CORE146_WATCHDOG_ONLY_PHRASE='しきい値（既定値。環境変数で変更可'
CORE146_EPIC_ONLY_PHRASE='含むディレクトリ生成が支配的なコストになる'
CORE146_HYGIENE_ONLY_PHRASE='clone したチームメンバー全員のセッションに'

for f in agents/planner.md agents/generator.md agents/evaluator.md \
         codex-agents/planner.toml codex-agents/generator.toml codex-agents/evaluator.toml; do
  if grep -Fq -- "$CORE146_WATCHDOG_ONLY_PHRASE" "${REPO_ROOT}/${f}" \
    || grep -Fq -- "$CORE146_EPIC_ONLY_PHRASE" "${REPO_ROOT}/${f}" \
    || grep -Fq -- "$CORE146_HYGIENE_ONLY_PHRASE" "${REPO_ROOT}/${f}"; then
    fail "${f}: core/references/*.md の本文がインライン展開されていない（#146）" \
      "参照ファイル専用の記述が生成物中に見つかりました"
  else
    pass "${f}: core/references/*.md の本文がインライン展開されていない（#146）"
  fi
done

# --- core/instructions.md から退避した内容が core/references/*.md 側に実在する
#     （内容消失の回帰防止。移設した代表的なフレーズを1つずつ確認する） ---
case "$(cat "${REPO_ROOT}/core/references/watchdog.md")" in
  *'自動打ち切りは原理的に実装できない'*'アダプタ間に'*'機能差を作らないため採用していない'*)
    pass "core/references/watchdog.md: 退避したアダプタ差異・しきい値の記述が残っている（#146）" ;;
  *)
    fail "core/references/watchdog.md: 退避したアダプタ差異・しきい値の記述が残っている（#146）" \
      "$(cat "${REPO_ROOT}/core/references/watchdog.md")" ;;
esac

case "$(cat "${REPO_ROOT}/core/references/epic-sections.md")" in
  *'isolation'*'worktree）で初回1回だけ実行'*'issue #104'*'DEV_WORKFLOW_SKIP_PATTERN'*)
    pass "core/references/epic-sections.md: 退避した3節の詳細記述が残っている（#146）" ;;
  *)
    fail "core/references/epic-sections.md: 退避した3節の詳細記述が残っている（#146）" \
      "$(cat "${REPO_ROOT}/core/references/epic-sections.md")" ;;
esac

case "$(cat "${REPO_ROOT}/core/references/harness-hygiene.md")" in
  *'サンドボックス定義'*'YOLO 用の permission 設定'*'マーカー・状態ファイル・worktree'*)
    pass "core/references/harness-hygiene.md: 退避した対応表が残っている（#146）" ;;
  *)
    fail "core/references/harness-hygiene.md: 退避した対応表が残っている（#146）" \
      "$(cat "${REPO_ROOT}/core/references/harness-hygiene.md")" ;;
esac

# --- README.md: progressive disclosure 方針の節がある ---
if grep -Fq '## プロンプトの progressive disclosure 方針' "${REPO_ROOT}/README.md"; then
  pass "README.md: 「プロンプトの progressive disclosure 方針」の節がある（#146）"
else
  fail "README.md: 「プロンプトの progressive disclosure 方針」の節がある（#146）" "節が見つかりません"
fi

DOC146_README_PD_SECTION="$(awk '/^## プロンプトの progressive disclosure 方針/{f=1} /^## ワークフロー/{f=0} f' \
  "${REPO_ROOT}/README.md")"

case "$DOC146_README_PD_SECTION" in
  *'skills/run/references/'*'core/references/'*)
    pass "README.md: skills/*/references/ と core/references/ の使い分けが書かれている（#146）" ;;
  *)
    fail "README.md: skills/*/references/ と core/references/ の使い分けが書かれている（#146）" \
      "$DOC146_README_PD_SECTION" ;;
esac

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh のロック兼完了マーカーと --run-prep（Task #111）
#
# 対象はレーンの作業ディレクトリ単位（git rev-parse --git-dir 配下）のため、レーンは
# 実際に git init したディレクトリを使う（共有モードの既存テストブロックが使う SPD_LANE は
# 非 git ディレクトリのままにしておく。既存ブロック内部は無変更）。
# 共有モードと同じスタブ（DEV_WORKFLOW_SANDBOX_EXEC）を使い、Docker 非依存に検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh（ロック兼完了マーカー・--run-prep、Task #111） =="

# --- 冒頭コメントに、ロックを削除しない理由・--force の用途・done を書くタイミングが
#     書かれている ---
SPD_LOCK_HEADER="$(awk '/^set -u/{exit} {print}' "$SPD_SCRIPT")"

case "$SPD_LOCK_HEADER" in
  *'ロックディレクトリは削除しない'*)
    pass "share-prepared-dirs.sh: 冒頭コメントにロックを削除しない理由が書かれている（#111）" ;;
  *)
    fail "share-prepared-dirs.sh: 冒頭コメントにロックを削除しない理由が書かれている（#111）" \
      "見つかりませんでした" ;;
esac

case "$SPD_LOCK_HEADER" in
  *'--force'*'残存ロック'*)
    pass "share-prepared-dirs.sh: 冒頭コメントに--forceの用途が書かれている（#111）" ;;
  *)
    fail "share-prepared-dirs.sh: 冒頭コメントに--forceの用途が書かれている（#111）" \
      "見つかりませんでした" ;;
esac

case "$SPD_LOCK_HEADER" in
  *'成功したときだけ'*'done'*'を書く'*)
    pass "share-prepared-dirs.sh: 冒頭コメントにdoneを書くタイミングが書かれている（#111）" ;;
  *)
    fail "share-prepared-dirs.sh: 冒頭コメントにdoneを書くタイミングが書かれている（#111）" \
      "見つかりませんでした" ;;
esac

# --- テスト用の共有元・呼び出しヘルパー（spd_run / spd_make_stub は既存ブロックで定義済み） ---
SPD_LOCK_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-lock-source.XXXXXX")"
mkdir -p "${SPD_LOCK_SOURCE}/lock_shared_dir"

spd_lock_make_lane() {
  # spd_lock_make_lane  git init 済みの一時レーンディレクトリのパスを出力する
  local lane
  lane="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-lock-lane.XXXXXX")"
  (cd "$lane" && git init -q) >/dev/null 2>&1
  printf '%s' "$lane"
}

spd_count_lines() {
  # spd_count_lines <file>  行数を出力する（0行のときも "0" を1行だけ出す。
  # `grep -c '.' file || echo 0` は grep がマッチ0件で非0終了するため
  # 両方の出力が連結される事故が起きる。wc -l は件数に関わらず必ず0終了するため使わない）
  wc -l < "$1" | tr -d '[:space:]'
}

# --- ケース1: 初回実行でロックが取得され、成功時に done が作られる。
#     ロックは作業ツリーではなく git rev-parse --git-dir 配下（git status --porcelain は空のまま。
#     レーン側に共有対象を事前に置き exists 判定にすることで、共有そのものによる
#     working tree の変化を排除し、ロックだけの影響を検証する） ---
SPD_LOCK_LANE1="$(spd_lock_make_lane)"
mkdir -p "${SPD_LOCK_LANE1}/lock_shared_dir"
SPD_LOCK_CALL_LOG1="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-lock-calllog1.XXXXXX")"
SPD_LOCK_STUB1="$(spd_make_stub "$SPD_LOCK_CALL_LOG1")"

SPD_LOCK_OUT1="$(spd_run "$SPD_LOCK_LANE1" "$SPD_LOCK_STUB1" --source "$SPD_LOCK_SOURCE" --dir "lock_shared_dir")"
SPD_LOCK_EXIT1=$?
assert_exit_code "ロック ケース1: 初回実行は exit 0（#111）" 0 "$SPD_LOCK_EXIT1"

assert_eq "ロック ケース1: 成功時に done マーカーが作られる（#111）" \
  "yes" "$([ -f "${SPD_LOCK_LANE1}/.git/dev-workflow-prep.lock/done" ] && echo yes || echo no)"

SPD_LOCK_STATUS1="$(cd "$SPD_LOCK_LANE1" && git status --porcelain)"
assert_eq "ロック ケース1: ロックは .git 配下にあり git status --porcelain は空のまま（#111）" \
  "" "$SPD_LOCK_STATUS1"

# --- ケース2: done がある状態で再実行すると prep=done-already / exit 0 で、
#     symlink 作成（コンテナ呼び出し）も準備コマンド実行も行われない ---
SPD_LOCK_CALL_COUNT1_BEFORE="$(spd_count_lines "$SPD_LOCK_CALL_LOG1")"
SPD_LOCK_MARKER2="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-lock-marker2.XXXXXX")"

SPD_LOCK_OUT2="$(spd_run "$SPD_LOCK_LANE1" "$SPD_LOCK_STUB1" --source "$SPD_LOCK_SOURCE" --dir "lock_shared_dir" \
  --run-prep "printf x >> $(printf '%q' "$SPD_LOCK_MARKER2")")"
SPD_LOCK_EXIT2=$?
assert_exit_code "ロック ケース2: done ありの再実行は exit 0（#111）" 0 "$SPD_LOCK_EXIT2"

case "$SPD_LOCK_OUT2" in
  *"prep=done-already"*)
    pass "ロック ケース2: done がある場合 prep=done-already（#111）" ;;
  *)
    fail "ロック ケース2: done がある場合 prep=done-already（#111）" "output=[${SPD_LOCK_OUT2}]" ;;
esac

SPD_LOCK_CALL_COUNT1_AFTER="$(spd_count_lines "$SPD_LOCK_CALL_LOG1")"
assert_eq "ロック ケース2: done-already 時は symlink 作成（コンテナ呼び出し）が行われない（#111）" \
  "$SPD_LOCK_CALL_COUNT1_BEFORE" "$SPD_LOCK_CALL_COUNT1_AFTER"

assert_eq "ロック ケース2: done-already 時は --run-prep のコマンドも実行されない（#111）" \
  "no" "$([ -s "$SPD_LOCK_MARKER2" ] && echo yes || echo no)"

# --- ケース3: done の無いロックがある状態で実行すると exit 3 で停止し、
#     stderr にロックパスが出る ---
SPD_LOCK_LANE3="$(spd_lock_make_lane)"
mkdir -p "${SPD_LOCK_LANE3}/.git/dev-workflow-prep.lock"
SPD_LOCK_CALL_LOG3="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-lock-calllog3.XXXXXX")"
SPD_LOCK_STUB3="$(spd_make_stub "$SPD_LOCK_CALL_LOG3")"

SPD_LOCK_OUT3="$(spd_run "$SPD_LOCK_LANE3" "$SPD_LOCK_STUB3" --source "$SPD_LOCK_SOURCE" --dir "lock_shared_dir" 2>&1)"
SPD_LOCK_EXIT3=$?
assert_exit_code "ロック ケース3: 残存ロック（done無し）は exit 3（#111）" 3 "$SPD_LOCK_EXIT3"

case "$SPD_LOCK_OUT3" in
  *"同一 worktree で準備が既に実行中です"*"dev-workflow-prep.lock"*)
    pass "ロック ケース3: stderr にロックパスを含むエラーが出る（#111）" ;;
  *)
    fail "ロック ケース3: stderr にロックパスを含むエラーが出る（#111）" "output=[${SPD_LOCK_OUT3}]" ;;
esac

SPD_LOCK_CALL_COUNT3="$(spd_count_lines "$SPD_LOCK_CALL_LOG3")"
assert_eq "ロック ケース3: 競合時は symlink 作成（コンテナ呼び出し）が行われない（#111）" \
  "0" "$SPD_LOCK_CALL_COUNT3"

# --- ケース4: --force を付けると done の無い残存ロックがあっても続行する
#     （ケース3と同じ残存ロックを再利用する） ---
SPD_LOCK_OUT4="$(spd_run "$SPD_LOCK_LANE3" "$SPD_LOCK_STUB3" --source "$SPD_LOCK_SOURCE" --dir "lock_shared_dir" --force)"
SPD_LOCK_EXIT4=$?
assert_exit_code "ロック ケース4: --force を付けると続行し exit 0（#111）" 0 "$SPD_LOCK_EXIT4"

case "$SPD_LOCK_OUT4" in
  *"prep="*)
    pass "ロック ケース4: --force で通常どおり prep= 行が出る（#111）" ;;
  *)
    fail "ロック ケース4: --force で通常どおり prep= 行が出る（#111）" "output=[${SPD_LOCK_OUT4}]" ;;
esac

assert_eq "ロック ケース4: --force での成功後は done マーカーが作られる（#111）" \
  "yes" "$([ -f "${SPD_LOCK_LANE3}/.git/dev-workflow-prep.lock/done" ] && echo yes || echo no)"

# --- ケース5: prep=skip のときは --run-prep のコマンドが実行されない
#     （レーン側に実体ディレクトリを事前に置き、skip reason exists で prep=skip にする） ---
SPD_LOCK_LANE5="$(spd_lock_make_lane)"
mkdir -p "${SPD_LOCK_LANE5}/lock_shared_dir"
SPD_LOCK_CALL_LOG5="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-lock-calllog5.XXXXXX")"
SPD_LOCK_STUB5="$(spd_make_stub "$SPD_LOCK_CALL_LOG5")"
SPD_LOCK_MARKER5="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-lock-marker5.XXXXXX")"

SPD_LOCK_OUT5="$(spd_run "$SPD_LOCK_LANE5" "$SPD_LOCK_STUB5" --source "$SPD_LOCK_SOURCE" --dir "lock_shared_dir" \
  --run-prep "printf x >> $(printf '%q' "$SPD_LOCK_MARKER5")")"
SPD_LOCK_EXIT5=$?
assert_exit_code "ロック ケース5: prep=skip のときも exit 0（#111）" 0 "$SPD_LOCK_EXIT5"

case "$SPD_LOCK_OUT5" in
  *"prep=skip"*)
    pass "ロック ケース5: レーン側に実体がある場合 prep=skip（#111）" ;;
  *)
    fail "ロック ケース5: レーン側に実体がある場合 prep=skip（#111）" "output=[${SPD_LOCK_OUT5}]" ;;
esac

assert_eq "ロック ケース5: prep=skip のときは --run-prep のコマンドが実行されない（#111）" \
  "no" "$([ -s "$SPD_LOCK_MARKER5" ] && echo yes || echo no)"

# --- ケース6: prep=run のときは --run-prep のコマンドが実行される
#     （共有元に存在しないディレクトリを指定し no-source で prep=run にする） ---
SPD_LOCK_LANE6="$(spd_lock_make_lane)"
SPD_LOCK_CALL_LOG6="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-lock-calllog6.XXXXXX")"
SPD_LOCK_STUB6="$(spd_make_stub "$SPD_LOCK_CALL_LOG6")"
SPD_LOCK_MARKER6="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-lock-marker6.XXXXXX")"

SPD_LOCK_OUT6="$(spd_run "$SPD_LOCK_LANE6" "$SPD_LOCK_STUB6" --source "$SPD_LOCK_SOURCE" --dir "no_such_lock_dir" \
  --run-prep "printf x >> $(printf '%q' "$SPD_LOCK_MARKER6")")"
SPD_LOCK_EXIT6=$?
assert_exit_code "ロック ケース6: prep=run で --run-prep が成功すると exit 0（#111）" 0 "$SPD_LOCK_EXIT6"

case "$SPD_LOCK_OUT6" in
  *"prep=run"*)
    pass "ロック ケース6: 共有元に無い場合 prep=run（#111）" ;;
  *)
    fail "ロック ケース6: 共有元に無い場合 prep=run（#111）" "output=[${SPD_LOCK_OUT6}]" ;;
esac

assert_eq "ロック ケース6: prep=run のときは --run-prep のコマンドが実行される（#111）" \
  "yes" "$([ -s "$SPD_LOCK_MARKER6" ] && echo yes || echo no)"

assert_eq "ロック ケース6: --run-prep 成功後は done マーカーが作られる（#111）" \
  "yes" "$([ -f "${SPD_LOCK_LANE6}/.git/dev-workflow-prep.lock/done" ] && echo yes || echo no)"

# --- ケース7: --run-prep のコマンドが失敗すると exit 4 になり、done が作られない ---
SPD_LOCK_LANE7="$(spd_lock_make_lane)"
SPD_LOCK_CALL_LOG7="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-lock-calllog7.XXXXXX")"
SPD_LOCK_STUB7="$(spd_make_stub "$SPD_LOCK_CALL_LOG7")"

SPD_LOCK_OUT7="$(spd_run "$SPD_LOCK_LANE7" "$SPD_LOCK_STUB7" --source "$SPD_LOCK_SOURCE" --dir "no_such_lock_dir7" \
  --run-prep "exit 1" 2>&1)"
SPD_LOCK_EXIT7=$?
assert_exit_code "ロック ケース7: --run-prep のコマンドが失敗すると exit 4（#111）" 4 "$SPD_LOCK_EXIT7"

assert_eq "ロック ケース7: --run-prep 失敗時は done マーカーが作られない（#111）" \
  "no" "$([ -f "${SPD_LOCK_LANE7}/.git/dev-workflow-prep.lock/done" ] && echo yes || echo no)"

# --- ケース8: --run-prep が末尾で値なしでも無限ループせず exit 2 ---
if command -v timeout >/dev/null 2>&1; then
  SPD_LOCK_NOVAL_OUT="$(timeout 5 bash "$SPD_SCRIPT" --source "$SPD_LOCK_SOURCE" --run-prep 2>&1)"
  SPD_LOCK_NOVAL_EXIT=$?
  assert_no_hang "ロック ケース8: --run-prep が末尾で値なしでも無限ループせず exit 2（#111）" \
    2 "$SPD_LOCK_NOVAL_EXIT" "$SPD_LOCK_NOVAL_OUT" "--run-prep には値が必要です"
else
  skip "share-prepared-dirs.sh: --run-prep 値なしで無限ループしない（#111）" \
    "timeout コマンドが利用できません"
fi

# ---------------------------------------------------------------------------
# Task #112: run に「共有ディレクトリ」節の抽出とStep 3プロンプトの結線を入れる
#
# 「準備コマンド」節・「SKIPパターン」節と同じ流儀（#94・#97のテストと同種）で、
# skills/run/SKILL.md に共有ディレクトリ節の抽出手順とStep 3の結線が入っていることを検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== Task #112: run に『共有ディレクトリ』節の抽出とStep 3プロンプトの結線がある =="

# --- skills/run/SKILL.md: Docker sandbox の準備節に「共有ディレクトリ」節の抽出手順と
#     EPIC_WT_ABS の取得がある ---
H112_RS_SHAREDIR_EXTRACT="$(awk '/^#### 共有ディレクトリ（Epic 本文の `## 共有ディレクトリ` 節/{f=1} /^#### SKIP件数の判定パターン/{f=0} f' \
  "$RUN_SKILL_FLAT")"

if [ -z "$H112_RS_SHAREDIR_EXTRACT" ]; then
  fail "SKILL.md: 『#### 共有ディレクトリ』節が見つかる（#112）" "節が空でした"
else
  pass "SKILL.md: 『#### 共有ディレクトリ』節が見つかる（#112）"
fi

case "$H112_RS_SHAREDIR_EXTRACT" in
  *'## 共有ディレクトリ'*'awk'*'sed -n'*'EPIC_WT_ABS'*)
    pass "SKILL.md: 共有ディレクトリ節の抽出手順（awk/sed）とEPIC_WT_ABSの取得がある（#112）" ;;
  *)
    fail "SKILL.md: 共有ディレクトリ節の抽出手順（awk/sed）とEPIC_WT_ABSの取得がある（#112）" \
      "$H112_RS_SHAREDIR_EXTRACT" ;;
esac

case "$H112_RS_SHAREDIR_EXTRACT" in
  *'SHARED_DIRS'*'は空文字のまま'*'現行と完全に同じ'*)
    pass "SKILL.md: 節が無ければSHARED_DIRSが空文字のままで現行と完全に同じ挙動になる旨が明記されている（#112）" ;;
  *)
    fail "SKILL.md: 節が無ければSHARED_DIRSが空文字のままで現行と完全に同じ挙動になる旨が明記されている（#112）" \
      "$H112_RS_SHAREDIR_EXTRACT" ;;
esac

# --- skills/run/SKILL.md: Step 3 雛形が SHARED_DIRS の空／非空を分岐して明示している ---
H112_RS_STEP3="$(awk '/^### Step 3:/{f=1} /^### Step 4:/{f=0} f' "$RUN_SKILL_FLAT")"

case "$H112_RS_STEP3" in
  *'$SHARED_DIRS'*'空でない'*'share-prepared-dirs.sh'*'--source'*'--spec'*)
    pass "SKILL.md: Step 3 雛形が SHARED_DIRS 非空時に share-prepared-dirs.sh を --source/--spec 付きで呼ぶ行を明示している（#112）" ;;
  *)
    fail "SKILL.md: Step 3 雛形が SHARED_DIRS 非空時に share-prepared-dirs.sh を --source/--spec 付きで呼ぶ行を明示している（#112）" \
      "$H112_RS_STEP3" ;;
esac

case "$H112_RS_STEP3" in
  *'$PREP_CMD'*'空でない場合のみ'*'--run-prep'*)
    pass "SKILL.md: Step 3 雛形が PREP_CMD が空でない場合のみ --run-prep を付ける旨を明示している（#112）" ;;
  *)
    fail "SKILL.md: Step 3 雛形が PREP_CMD が空でない場合のみ --run-prep を付ける旨を明示している（#112）" \
      "$H112_RS_STEP3" ;;
esac

case "$H112_RS_STEP3" in
  *'$SHARED_DIRS'*'空'*'場合は現行どおり'*)
    pass "SKILL.md: Step 3 雛形が SHARED_DIRS 空時は現行どおり PREP_CMD を直接実行させる旨を明示している（#112）" ;;
  *)
    fail "SKILL.md: Step 3 雛形が SHARED_DIRS 空時は現行どおり PREP_CMD を直接実行させる旨を明示している（#112）" \
      "$H112_RS_STEP3" ;;
esac

# --- skills/run/SKILL.md: exit 3 / exit 4 / prep=run のときの generator の振る舞いが明記 ---
case "$H112_RS_STEP3" in
  *'exit 3'*'ロック競合'*'2本目を起動せず'*)
    pass "SKILL.md: Step 3 雛形に exit 3（ロック競合）時は2本目を起動せず報告して停止する旨がある（#112）" ;;
  *)
    fail "SKILL.md: Step 3 雛形に exit 3（ロック競合）時は2本目を起動せず報告して停止する旨がある（#112）" \
      "$H112_RS_STEP3" ;;
esac

case "$H112_RS_STEP3" in
  *'exit 4'*'--run-prep'*'失敗'*'実装に進まず'*)
    pass "SKILL.md: Step 3 雛形に exit 4（--run-prepの失敗）時は実装に進まず報告する旨がある（#112）" ;;
  *)
    fail "SKILL.md: Step 3 雛形に exit 4（--run-prepの失敗）時は実装に進まず報告する旨がある（#112）" \
      "$H112_RS_STEP3" ;;
esac

case "$H112_RS_STEP3" in
  *'prep=run'*'共有できなかった'*'自前で準備コマンドを追加実行しないこと'*)
    pass "SKILL.md: Step 3 雛形に prep=run 時でも自前で準備コマンドを追加実行しない旨がある（#112）" ;;
  *)
    fail "SKILL.md: Step 3 雛形に prep=run 時でも自前で準備コマンドを追加実行しない旨がある（#112）" \
      "$H112_RS_STEP3" ;;
esac

# --- skills/run/SKILL.md: --detach を使う条件（依存マニフェストを変更するタスク）が明記 ---
case "$H112_RS_STEP3" in
  *'依存マニフェスト'*'package.json'*'lockfile'*'--detach'*)
    pass "SKILL.md: Step 3 雛形に依存マニフェストを変更するタスクで --detach を使う条件が明記されている（#112）" ;;
  *)
    fail "SKILL.md: Step 3 雛形に依存マニフェストを変更するタスクで --detach を使う条件が明記されている（#112）" \
      "$H112_RS_STEP3" ;;
esac

# --- skills/run/SKILL.md: Step 3 雛形に駆動先プロジェクト固有の値（共有ディレクトリ名・
#     lockfile名等）をハードコードしていない（プレースホルダのみで表現されている） ---
if printf '%s\n' "$H112_RS_STEP3" | grep -Fq -- 'yarn.lock'; then
  fail "SKILL.md: Step 3 雛形に駆動先プロジェクト固有の値をハードコードしていない（#112）" \
    "$H112_RS_STEP3"
else
  pass "SKILL.md: Step 3 雛形に駆動先プロジェクト固有の値をハードコードしていない（#112）"
fi

case "$H112_RS_STEP3" in
  *'[EPIC_WT_ABSの内容]'*'[SHARED_DIRSの内容]'*)
    pass "SKILL.md: Step 3 雛形が EPIC_WT_ABS/SHARED_DIRS の内容を汎用プレースホルダで埋め込んでいる（#112）" ;;
  *)
    fail "SKILL.md: Step 3 雛形が EPIC_WT_ABS/SHARED_DIRS の内容を汎用プレースホルダで埋め込んでいる（#112）" \
      "$H112_RS_STEP3" ;;
esac

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: ネストしたエントリのsymlinkターゲット計算（Review #115）
#
# symlink のターゲットはリンク自身の親ディレクトリ基準で解決されるため、
# `packages/app/node_modules` のようにネストしたエントリ（行書式はリポジトリルート相対で
# あり、モノレポでは主要な用途）ではレーン worktree 基準の相対パスをそのまま使うと誤った
# ターゲットになり dangling symlink になる（#115）。linked 後に共有元のファイルが実際に
# レーン側から読めることまで確認する（symlink が正しく解決できていることの検証）。
# 既存のフィクスチャ（SPD_SCRIPT / spd_make_stub / spd_run）を再利用する。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh: ネストしたエントリのsymlinkターゲット計算（Review #115） =="

SPD_NEST_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-nest-source.XXXXXX")"
SPD_NEST_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-nest-lane.XXXXXX")"
SPD_NEST_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-nest-calllog.XXXXXX")"
SPD_NEST_STUB="$(spd_make_stub "$SPD_NEST_CALL_LOG")"

mkdir -p "${SPD_NEST_SOURCE}/packages/app/node_modules"
printf 'nested-marker\n' > "${SPD_NEST_SOURCE}/packages/app/node_modules/marker.txt"
# レーン側にも <dir> の親ディレクトリ（packages/app）は既に存在する前提（実運用ではモノレポの
# ソースツリーとしてコミット済み）。symlink 自体（node_modules）だけを本スクリプトが作る。
mkdir -p "${SPD_NEST_LANE}/packages/app"

SPD_NEST_OUT="$(spd_run "$SPD_NEST_LANE" "$SPD_NEST_STUB" --source "$SPD_NEST_SOURCE" \
  --dir "packages/app/node_modules")"
SPD_NEST_EXIT=$?
assert_exit_code "ネストしたエントリ: exit 0（#115）" 0 "$SPD_NEST_EXIT"

case "$SPD_NEST_OUT" in
  *"linked"*"packages/app/node_modules"*)
    pass "ネストしたエントリ: linked が出る（#115）" ;;
  *)
    fail "ネストしたエントリ: linked が出る（#115）" "output=[${SPD_NEST_OUT}]" ;;
esac

case "$SPD_NEST_OUT" in
  *"prep=skip"*)
    pass "ネストしたエントリ: linked のみのとき prep=skip（#115）" ;;
  *)
    fail "ネストしたエントリ: linked のみのとき prep=skip（#115）" "output=[${SPD_NEST_OUT}]" ;;
esac

# 本題: linked 後、共有元のファイルがレーン側から symlink を辿って実際に読める
# （リンク位置基準にターゲットが補正されていないと dangling になり、ここが失敗する）
assert_eq "ネストしたエントリ: linked 後、共有元のファイルがレーン側から読める（#115）" \
  "nested-marker" \
  "$(cat "${SPD_NEST_LANE}/packages/app/node_modules/marker.txt" 2>/dev/null || echo "READ_FAILED")"

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: 実体確認失敗（dangling symlink）時に symlink を撤去してから
# link-failed とする（Review #118）
#
# `ln -s` はターゲットが存在しなくても成功するため、target の計算が誤っている場合
# （--dir に連続スラッシュを含む文字列を渡すと、実際のネスト深さとスラッシュ数
# ベースの up-prefix 計算がずれる。OSはパス解決時に連続スラッシュを1つに畳み込む
# ため、実際のネスト深さは1段（app/node_modules）だが up-prefix はスラッシュ文字数
# 2段分を前置してしまい、symlink のターゲットが1段余分に上へずれて存在しない
# パスを指す）、symlink 作成自体は成功するが辿った実体はディレクトリではない
# （dangling symlink）。#115 時点の実装はこの dangling symlink を <dir> に残した
# まま link-failed を報告していたため、(1) 同一実行内で --run-prep を使うと <dir>
# が dangling symlink に占有されたまま install が失敗する（#116 の解除対象は
# kind=linked のみ）、(2) 再実行すると判定式 `[ -e "$d" ] || [ -L "$d" ]` が
# dangling symlink でも真になり exists と誤判定され、フォールバックが働かないまま
# done が書かれる、という2つの不具合が生じていた（#118）。本テストは、dangling
# symlink になる状況を意図的に作り出し、link-failed が報告されること・レーン側に
# symlink が残らないこと・再実行しても exists に化けず link-failed が再現すること・
# --run-prep での install が dangling symlink に妨げられず成功することを確認する。
# 既存のフィクスチャ（SPD_SCRIPT / spd_make_stub / spd_run）を再利用する。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh: dangling symlink 時に撤去してから link-failed とする（Review #118） =="

# Task #139 のコピー・フォールバックは link-failed になった全エントリに対して
# 実体コピー（cp -a / cp -r）を試みる。本テストの共有元は実在し中身も入っているため、
# コピー・フォールバックを素通しにすると copied になって link-failed を検証できなくなる
# （#118 が検証したいのは symlink 経路の撤去・再現性であり、コピー経路の成否ではない）。
# そのため本テスト専用に「必ず失敗する偽 cp」を PATH へ割り込ませ、コピー・フォールバックの
# 有無に関わらず link-failed が保たれることを確認する。
SPD118D_FAKEBIN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-118d-fakebin.XXXXXX")"
cat > "${SPD118D_FAKEBIN}/cp" <<'EOF'
#!/bin/sh
# テスト専用の偽 cp。#139 のコピー・フォールバックを無効化し、#118 の
# symlink 撤去・再現性の検証に影響しないようにするため、必ず exit 1 する。
exit 1
EOF
chmod +x "${SPD118D_FAKEBIN}/cp"

spd118d_make_stub() {
  # spd118d_make_stub <call_log>  PATH に偽 cp を割り込ませてから sh -c する
  local call_log="$1" stub
  stub="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-118d-stub.XXXXXX")"
  {
    echo '#!/bin/bash'
    echo 'set -u'
    printf 'echo 1 >> %q\n' "$call_log"
    printf 'PATH=%q:"$PATH"\n' "$SPD118D_FAKEBIN"
    echo 'cmd="${@: -1}"'
    echo 'sh -c "$cmd"'
  } > "$stub"
  printf '%s' "$stub"
}

SPD118D_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-118d-source.XXXXXX")"
SPD118D_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-118d-lane.XXXXXX")"
SPD118D_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-118d-calllog.XXXXXX")"
SPD118D_STUB="$(spd118d_make_stub "$SPD118D_CALL_LOG")"

mkdir -p "${SPD118D_SOURCE}/app/node_modules"
printf 'dangling-marker\n' > "${SPD118D_SOURCE}/app/node_modules/marker.txt"
mkdir -p "${SPD118D_LANE}/app"

SPD118D_OUT1="$(spd_run "$SPD118D_LANE" "$SPD118D_STUB" --source "$SPD118D_SOURCE" \
  --dir "app//node_modules")"
SPD118D_EXIT1=$?
assert_exit_code "dangling symlink: 1回目の実行は exit 0（#118）" 0 "$SPD118D_EXIT1"

case "$SPD118D_OUT1" in
  *"skip"*"app//node_modules"*"reason"*"link-failed"*)
    pass "dangling symlink: 実体確認に失敗すると skip reason link-failed（#118）" ;;
  *)
    fail "dangling symlink: 実体確認に失敗すると skip reason link-failed（#118）" "output=[${SPD118D_OUT1}]" ;;
esac

# 本題1: 撤去されているので symlink（dangling含む）はレーン側に一切残らない
assert_eq "dangling symlink: link-failed 後、レーン側に symlink が残らない（#118）" \
  "no" "$([ -L "${SPD118D_LANE}/app/node_modules" ] && echo yes || echo no)"
assert_eq "dangling symlink: link-failed 後、レーン側に何も存在しない（#118）" \
  "no" "$([ -e "${SPD118D_LANE}/app/node_modules" ] && echo yes || echo no)"

# 本題2: 再実行しても撤去済みのため exists に化けず、同じ link-failed が再現する
#     （#118 の失敗モード2: 撤去しないと `[ -e ] || [ -L ]` が dangling でも真になり
#     exists と誤判定され、prep=skip でフォールバックが働かなくなる）
SPD118D_OUT2="$(spd_run "$SPD118D_LANE" "$SPD118D_STUB" --source "$SPD118D_SOURCE" \
  --dir "app//node_modules")"
case "$SPD118D_OUT2" in
  *"skip"*"app//node_modules"*"reason"*"link-failed"*)
    pass "dangling symlink: 再実行しても exists に化けず link-failed が再現する（#118）" ;;
  *)
    fail "dangling symlink: 再実行しても exists に化けず link-failed が再現する（#118）" "output=[${SPD118D_OUT2}]" ;;
esac
case "$SPD118D_OUT2" in
  *"prep=run"*)
    pass "dangling symlink: 再実行後も prep=run のまま（フォールバックが働く）（#118）" ;;
  *)
    fail "dangling symlink: 再実行後も prep=run のまま（フォールバックが働く）（#118）" "output=[${SPD118D_OUT2}]" ;;
esac

# 本題3: 同一実行内で --run-prep を使っても <dir> が dangling symlink に占有されず、
#     install コマンドが正常に <dir> を作成できる（#118 の失敗モード1）
SPD118D_PREP_CMD='mkdir -p app/node_modules && printf installed-ok > app/node_modules/installed.txt'
SPD118D_OUT3="$(spd_run "$SPD118D_LANE" "$SPD118D_STUB" --source "$SPD118D_SOURCE" \
  --dir "app//node_modules" --run-prep "$SPD118D_PREP_CMD")"
SPD118D_EXIT3=$?
assert_exit_code "dangling symlink: --run-prep 併用でも exit 0（占有が解消され install が成功する）（#118）" \
  0 "$SPD118D_EXIT3"
assert_eq "dangling symlink: --run-prep のコマンドが <dir> を実体ディレクトリとして作成できる（#118）" \
  "installed-ok" \
  "$(cat "${SPD118D_LANE}/app/node_modules/installed.txt" 2>/dev/null || echo "READ_FAILED")"

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: 混在ケース（linked 1件 + no-source 1件）+ --run-prep で
# 共有元が書き換えられない（Review #116）
#
# エントリが複数あり一部だけ linked・残りが no-source になると prep=run になり、
# --run-prep のコマンド（yarn install 等）が「linked 済みの symlink を張ったまま」
# レーンで実行されうる。install はレーンの <dir>（= 共有元への symlink）へ書き込むため、
# 対策が無いと共有元と他レーンが参照している実体を書き換えてしまう（issue #104 と同種の
# 破損をレーンをまたいで再現しうる）。--run-prep 実行直前に linked 済みエントリの共有symlink
# を解除する修正により、準備コマンドが共有元へ書き込まないことを検証する。
# 既存のフィクスチャ（SPD_SCRIPT / spd_make_stub / spd_run）を再利用する。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh: 混在ケース + --run-prep で共有元が書き換えられない（Review #116） =="

SPD116_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-116-source.XXXXXX")"
SPD116_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-116-lane.XXXXXX")"
SPD116_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-116-calllog.XXXXXX")"
SPD116_STUB="$(spd_make_stub "$SPD116_CALL_LOG")"

mkdir -p "${SPD116_SOURCE}/shared_ok"
printf 'source-content\n' > "${SPD116_SOURCE}/shared_ok/original.txt"

SPD116_MARKER="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-116-marker.XXXXXX")"
SPD116_PREP_CMD="mkdir -p shared_ok && printf 'lane-write\n' > shared_ok/newfile.txt && printf x >> $(printf '%q' "$SPD116_MARKER")"

SPD116_OUT="$(spd_run "$SPD116_LANE" "$SPD116_STUB" --source "$SPD116_SOURCE" \
  --dir "shared_ok" --dir "no_source_entry" --run-prep "$SPD116_PREP_CMD")"
SPD116_EXIT=$?
assert_exit_code "混在+--run-prep ケース: 準備コマンド成功で exit 0（#116）" 0 "$SPD116_EXIT"

case "$SPD116_OUT" in
  *"linked"*"shared_ok"*)
    pass "混在+--run-prep ケース: shared_ok は linked と報告される（#116）" ;;
  *)
    fail "混在+--run-prep ケース: shared_ok は linked と報告される（#116）" "output=[${SPD116_OUT}]" ;;
esac

case "$SPD116_OUT" in
  *"skip"*"no_source_entry"*"reason"*"no-source"*)
    pass "混在+--run-prep ケース: no_source_entry は skip reason no-source（#116）" ;;
  *)
    fail "混在+--run-prep ケース: no_source_entry は skip reason no-source（#116）" "output=[${SPD116_OUT}]" ;;
esac

case "$SPD116_OUT" in
  *"prep=run"*)
    pass "混在+--run-prep ケース: 一部が no-source のため prep=run（#116）" ;;
  *)
    fail "混在+--run-prep ケース: 一部が no-source のため prep=run（#116）" "output=[${SPD116_OUT}]" ;;
esac

assert_eq "混在+--run-prep ケース: --run-prep のコマンドが実行される（#116）" \
  "yes" "$([ -s "$SPD116_MARKER" ] && echo yes || echo no)"

# 本題1: 共有元の shared_ok に、レーンで実行された準備コマンドの書き込みが入り込んでいない
assert_eq "混在+--run-prep ケース: 共有元の shared_ok に newfile.txt が書き込まれていない（#116）" \
  "no" "$([ -e "${SPD116_SOURCE}/shared_ok/newfile.txt" ] && echo yes || echo no)"

# 共有元の既存ファイルも変化していない
assert_eq "混在+--run-prep ケース: 共有元の既存ファイルが変化していない（#116）" \
  "source-content" "$(cat "${SPD116_SOURCE}/shared_ok/original.txt" 2>/dev/null || echo "READ_FAILED")"

# 本題2: --run-prep 実行前に共有symlinkが解除され、レーン側 shared_ok は実体ディレクトリに
# なっており、準備コマンドの書き込みはレーン側だけに反映されている
assert_eq "混在+--run-prep ケース: --run-prep 前に共有symlinkが解除されレーン側は実体ディレクトリになる（#116）" \
  "no" "$([ -L "${SPD116_LANE}/shared_ok" ] && echo yes || echo no)"

assert_eq "混在+--run-prep ケース: レーン側 shared_ok に準備コマンドの書き込みが反映されている（#116）" \
  "lane-write" "$(cat "${SPD116_LANE}/shared_ok/newfile.txt" 2>/dev/null || echo "READ_FAILED")"

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: 複数行の --run-prep で unlink が失敗した場合、本体の2行目以降が
# 実行されず exit 4 になる（Review #117）
#
# #116 の解除は `unlink <dir> && ${RUN_PREP}` という文字列連結だった。`&&` が守るのは
# RUN_PREP の「1行目」だけであり、RUN_PREP が複数行（Epic本文『## 準備コマンド』節の
# フェンスコードブロックの中身をそのまま渡す実運用での通常形）の場合、unlink が失敗すると
# 1行目はスキップされるが2行目以降は共有symlinkを張ったまま実行されてしまう。
# ここでは unlink が実際に失敗する状況（linkした直後にスタブが symlink を取り除き、
# --run-prep 側の unlink が ENOENT で失敗する）を作り、RUN_PREP の1行目・2行目のどちらも
# 実行されず、exit 4（done マーカーを作らない失敗経路）に合流することを検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh: 複数行の --run-prep で unlink 失敗時に本体が実行されない（Review #117） =="

SPD117_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-117-source.XXXXXX")"
SPD117_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd-117-lane.XXXXXX")"
SPD117_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-117-calllog.XXXXXX")"

mkdir -p "${SPD117_SOURCE}/shared_ok"
printf 'source-content\n' > "${SPD117_SOURCE}/shared_ok/original.txt"

# 通常の spd_make_stub と違い、1回目の呼び出し（symlink作成フェーズ）の直後に
# 作られたばかりの shared_ok symlink を取り除く。これにより2回目の呼び出し
# （--run-prep フェーズ）内の `unlink shared_ok` が実際に ENOENT で失敗する。
SPD117_STUB="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-117-stub.XXXXXX")"
{
  echo '#!/bin/bash'
  echo 'set -u'
  printf 'echo 1 >> %q\n' "$SPD117_CALL_LOG"
  printf 'n=$(wc -l < %q)\n' "$SPD117_CALL_LOG"
  echo 'cmd="${@: -1}"'
  echo 'sh -c "$cmd"'
  echo 'rc=$?'
  echo 'if [ "$n" -eq 1 ]; then'
  echo '  unlink "shared_ok" 2>/dev/null || true'
  echo 'fi'
  echo 'exit $rc'
} > "$SPD117_STUB"

SPD117_MARKER1="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-117-marker1.XXXXXX")"
SPD117_MARKER2="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd-117-marker2.XXXXXX")"
: > "$SPD117_MARKER1"
: > "$SPD117_MARKER2"
SPD117_PREP_CMD="printf x >> $(printf '%q' "$SPD117_MARKER1")
printf x >> $(printf '%q' "$SPD117_MARKER2")"

SPD117_OUT="$(spd_run "$SPD117_LANE" "$SPD117_STUB" --source "$SPD117_SOURCE" \
  --dir "shared_ok" --dir "no_source_entry" --run-prep "$SPD117_PREP_CMD")"
SPD117_EXIT=$?

assert_exit_code "複数行--run-prep + unlink失敗ケース: exit 4 で失敗する（#117）" 4 "$SPD117_EXIT"

case "$SPD117_OUT" in
  *"prep=run"*)
    pass "複数行--run-prep + unlink失敗ケース: prep=run が出る（#117）" ;;
  *)
    fail "複数行--run-prep + unlink失敗ケース: prep=run が出る（#117）" "output=[${SPD117_OUT}]" ;;
esac

# 本題1: unlink 失敗時は RUN_PREP の1行目すら実行されない
assert_eq "複数行--run-prep + unlink失敗ケース: RUN_PREPの1行目が実行されない（#117）" \
  "no" "$([ -s "$SPD117_MARKER1" ] && echo yes || echo no)"

# 本題2（バグの核心）: 旧実装（&&連結）では2行目以降が無条件に実行されてしまっていた。
# 修正後は unlink 失敗で `exit 1` するため、2行目も実行されない。
assert_eq "複数行--run-prep + unlink失敗ケース: RUN_PREPの2行目以降が実行されない（#117）" \
  "no" "$([ -s "$SPD117_MARKER2" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# resolve-sandbox.sh: 規約パスのフォールバックとビルドコンテキスト解決（Task #123, Epic #122）
#
# ここでは resolve-sandbox.sh を sandbox-exec.sh 経由ではなく直接呼び出す
# （eval 用の key=value 出力をそのまま plan_value で読む）。
# ---------------------------------------------------------------------------

echo "== resolve-sandbox.sh: 規約パスのフォールバックとビルドコンテキスト解決（#123） =="

RESOLVE_SANDBOX_SCRIPT="${REPO_ROOT}/scripts/resolve-sandbox.sh"

normalize_test_path() {
  # normalize_test_path <dir>  resolve-sandbox.sh 内の normalize_dir と同じ作法で正規化する
  ( cd "$1" 2>/dev/null && { pwd -W 2>/dev/null || pwd; } )
}

# --- 受け入れ条件1・2: リポジトリ内に何も無く規約パスの Dockerfile.dev だけがある ---
RS1_REPO="$(make_temp_repo)"
RS1_NAME="$(basename "$RS1_REPO")"
RS1_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-sandboxhome.XXXXXX")"
mkdir -p "${RS1_HOME}/${RS1_NAME}"
cat > "${RS1_HOME}/${RS1_NAME}/Dockerfile.dev" <<'EOF'
FROM alpine
EOF

RS1_OUTPUT="$(
  cd "$RS1_REPO" || exit 1
  DEV_WORKFLOW_SANDBOX_HOME="$RS1_HOME" bash "$RESOLVE_SANDBOX_SCRIPT"
)"

assert_eq "規約パス: Dockerfile.devのみ -> mode=dockerfile（受け入れ条件1）" \
  "dockerfile" "$(plan_value DEV_WORKFLOW_SANDBOX_MODE "$RS1_OUTPUT")"
assert_eq "規約パス: DEV_WORKFLOW_SANDBOX_DOCKERFILEが規約パスのフルパスになる（受け入れ条件1）" \
  "${RS1_HOME}/${RS1_NAME}/Dockerfile.dev" "$(plan_value DEV_WORKFLOW_SANDBOX_DOCKERFILE "$RS1_OUTPUT")"
assert_eq "規約パス: build contextがリポジトリルートになる（受け入れ条件2）" \
  "$(normalize_test_path "$RS1_REPO")" "$(plan_value DEV_WORKFLOW_SANDBOX_CONTEXT "$RS1_OUTPUT")"

# --- 受け入れ条件3: リポジトリ内に何も無く規約パスの docker-compose.dev.yml だけがある ---
RS3_REPO="$(make_temp_repo)"
RS3_NAME="$(basename "$RS3_REPO")"
RS3_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-sandboxhome.XXXXXX")"
mkdir -p "${RS3_HOME}/${RS3_NAME}"
cat > "${RS3_HOME}/${RS3_NAME}/docker-compose.dev.yml" <<'EOF'
services:
  app:
    image: alpine
EOF

RS3_OUTPUT="$(
  cd "$RS3_REPO" || exit 1
  DEV_WORKFLOW_SANDBOX_HOME="$RS3_HOME" bash "$RESOLVE_SANDBOX_SCRIPT"
)"

assert_eq "規約パス: composeのみ -> mode=compose（受け入れ条件3）" \
  "compose" "$(plan_value DEV_WORKFLOW_SANDBOX_MODE "$RS3_OUTPUT")"
assert_eq "規約パス: DEV_WORKFLOW_SANDBOX_COMPOSEが規約パスのフルパスになる（受け入れ条件3）" \
  "${RS3_HOME}/${RS3_NAME}/docker-compose.dev.yml" "$(plan_value DEV_WORKFLOW_SANDBOX_COMPOSE "$RS3_OUTPUT")"

# --- 受け入れ条件4: リポジトリ内に Dockerfile.dev がある場合、規約パスにもファイルがあっても
#     リポジトリ内が勝つ（フォールバックであることの確認） ---
RS4_REPO="$(make_temp_repo)"
cat > "${RS4_REPO}/Dockerfile.dev" <<'EOF'
FROM alpine
EOF
(
  cd "$RS4_REPO" || exit 1
  git add Dockerfile.dev
  git commit -q -m "add local dockerfile"
) >/dev/null 2>&1
RS4_NAME="$(basename "$RS4_REPO")"
RS4_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-sandboxhome.XXXXXX")"
mkdir -p "${RS4_HOME}/${RS4_NAME}"
cat > "${RS4_HOME}/${RS4_NAME}/Dockerfile.dev" <<'EOF'
FROM alpine
# convention should be ignored
EOF

RS4_OUTPUT="$(
  cd "$RS4_REPO" || exit 1
  DEV_WORKFLOW_SANDBOX_HOME="$RS4_HOME" bash "$RESOLVE_SANDBOX_SCRIPT"
)"

assert_eq "規約パス: リポジトリ内Dockerfile.devが規約パスより優先される（受け入れ条件4）" \
  "Dockerfile.dev" "$(plan_value DEV_WORKFLOW_SANDBOX_DOCKERFILE "$RS4_OUTPUT")"

# --- 受け入れ条件5: リポジトリ内 Dockerfile がサブディレクトリにある場合、build context は
#     従来どおり dirname(Dockerfile) のまま（リポジトリルート直下では判定できないため
#     サブディレクトリに置いて確認する。後方互換） ---
RS5_REPO="$(make_temp_repo)"
mkdir -p "${RS5_REPO}/sub"
cat > "${RS5_REPO}/sub/Dockerfile.dev" <<'EOF'
FROM alpine
EOF
(
  cd "$RS5_REPO" || exit 1
  git add sub/Dockerfile.dev
  git commit -q -m "add sub dockerfile"
) >/dev/null 2>&1

RS5_OUTPUT="$(
  cd "$RS5_REPO" || exit 1
  DEV_WORKFLOW_DOCKERFILE="sub/Dockerfile.dev" bash "$RESOLVE_SANDBOX_SCRIPT"
)"

assert_eq "リポジトリ内Dockerfile: build contextは従来どおりdirname(Dockerfile)のまま（受け入れ条件5）" \
  "$(normalize_test_path "${RS5_REPO}/sub")" "$(plan_value DEV_WORKFLOW_SANDBOX_CONTEXT "$RS5_OUTPUT")"

# --- 受け入れ条件6: DEV_WORKFLOW_DOCKER_BUILD_CONTEXT を指定すると、リポジトリ内 Dockerfile
#     でもその値が採用される ---
RS6_REPO="$(make_temp_repo)"
cat > "${RS6_REPO}/Dockerfile.dev" <<'EOF'
FROM alpine
EOF
(
  cd "$RS6_REPO" || exit 1
  git add Dockerfile.dev
  git commit -q -m "add dockerfile"
) >/dev/null 2>&1
RS6_CUSTOM_CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-buildctx.XXXXXX")"

RS6_OUTPUT="$(
  cd "$RS6_REPO" || exit 1
  DEV_WORKFLOW_DOCKER_BUILD_CONTEXT="$RS6_CUSTOM_CONTEXT" bash "$RESOLVE_SANDBOX_SCRIPT"
)"

assert_eq "DEV_WORKFLOW_DOCKER_BUILD_CONTEXT指定時はその値が採用される（受け入れ条件6）" \
  "$(normalize_test_path "$RS6_CUSTOM_CONTEXT")" "$(plan_value DEV_WORKFLOW_SANDBOX_CONTEXT "$RS6_OUTPUT")"

# --- 受け入れ条件7: 規約パスにも何も無ければ mode=none のまま ---
# --- リポジトリ外に作られた兄弟 worktree 内の Dockerfile では、build context を
#     リポジトリルートではなくその worktree にする（sandbox-exec.sh がカレントを
#     マウント元にするフォールバック経路と揃える。#122一括レビュー指摘、由来: #123） ---
RS6B_REPO="$(make_temp_repo)"
RS6B_OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-sibling.XXXXXX")/wt"
make_worktree "$RS6B_REPO" "$RS6B_OUTSIDE" "sibling-wt"
cat > "${RS6B_OUTSIDE}/Dockerfile.dev" <<'EOF'
FROM alpine
EOF

RS6B_OUTPUT="$(
  cd "$RS6B_OUTSIDE" || exit 1
  bash "$RESOLVE_SANDBOX_SCRIPT"
)"

assert_eq "リポジトリ外の兄弟worktree内Dockerfile: build contextはその worktree になる（マウント元と一致）" \
  "$(normalize_test_path "$RS6B_OUTSIDE")" "$(plan_value DEV_WORKFLOW_SANDBOX_CONTEXT "$RS6B_OUTPUT")"

RS7_REPO="$(make_temp_repo)"
RS7_NAME="$(basename "$RS7_REPO")"
RS7_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-sandboxhome.XXXXXX")"
mkdir -p "${RS7_HOME}/${RS7_NAME}"

RS7_OUTPUT="$(
  cd "$RS7_REPO" || exit 1
  DEV_WORKFLOW_SANDBOX_HOME="$RS7_HOME" bash "$RESOLVE_SANDBOX_SCRIPT"
)"

assert_eq "規約パスにも何も無ければmode=noneのまま（受け入れ条件7）" \
  "none" "$(plan_value DEV_WORKFLOW_SANDBOX_MODE "$RS7_OUTPUT")"

# --- 受け入れ条件8: worktree から呼んでも規約パスの <repo> 部分が変わらない
#     （既存の「hash が worktree で変わらない」テストと同じ作り方で確認する） ---
RS8_REPO="$(make_temp_repo)"
RS8_NAME="$(basename "$RS8_REPO")"
RS8_WT="${RS8_REPO}/.claude/worktrees/agent-rs8"
make_worktree "$RS8_REPO" "$RS8_WT" "rs8-branch"
RS8_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-sandboxhome.XXXXXX")"
mkdir -p "${RS8_HOME}/${RS8_NAME}"
cat > "${RS8_HOME}/${RS8_NAME}/Dockerfile.dev" <<'EOF'
FROM alpine
EOF

RS8_ROOT_OUTPUT="$(
  cd "$RS8_REPO" || exit 1
  DEV_WORKFLOW_SANDBOX_HOME="$RS8_HOME" bash "$RESOLVE_SANDBOX_SCRIPT"
)"
RS8_WT_OUTPUT="$(
  cd "$RS8_WT" || exit 1
  DEV_WORKFLOW_SANDBOX_HOME="$RS8_HOME" bash "$RESOLVE_SANDBOX_SCRIPT"
)"

assert_eq "規約パス: worktreeから呼んでもmode=dockerfileになる（受け入れ条件8）" \
  "dockerfile" "$(plan_value DEV_WORKFLOW_SANDBOX_MODE "$RS8_WT_OUTPUT")"
assert_eq "規約パス: worktreeから呼んでもDockerfileのフルパスがリポジトリルートから呼んだ場合と一致する（受け入れ条件8）" \
  "$(plan_value DEV_WORKFLOW_SANDBOX_DOCKERFILE "$RS8_ROOT_OUTPUT")" "$(plan_value DEV_WORKFLOW_SANDBOX_DOCKERFILE "$RS8_WT_OUTPUT")"
assert_eq "規約パス: worktreeから呼んでもイメージタグ(hash含む)がリポジトリルートから呼んだ場合と一致する（受け入れ条件8）" \
  "$(plan_value DEV_WORKFLOW_SANDBOX_IMAGE "$RS8_ROOT_OUTPUT")" "$(plan_value DEV_WORKFLOW_SANDBOX_IMAGE "$RS8_WT_OUTPUT")"

# 受け入れ条件9（shellcheck / bash -n）は冒頭の全 scripts/*.sh 走査で resolve-sandbox.sh も
# 対象になっているため、ここでの追加テストは不要。

# ---------------------------------------------------------------------------
# skills/run/SKILL.md・skills-codex/dev-workflow-run/SKILL.md:
# mode=none 時の案内が供給経路3択になっている（Task #128）
# ---------------------------------------------------------------------------

echo ""
echo "== mode=none 時の案内メッセージ（供給経路3択、#128） =="

MODE_NONE_OLD_MSG="プロジェクトルートに開発用Dockerfileまたはcomposeファイルを配置してください"

for f in "skills/run/SKILL.md" "skills-codex/dev-workflow-run/SKILL.md"; do
  MN_TARGET="${REPO_ROOT}/${f}"

  if grep -qF "$MODE_NONE_OLD_MSG" "$MN_TARGET"; then
    fail "${f}: mode=none 案内から旧文言（プロジェクトルートに配置一択）が消えている（#128）" \
      "旧文言がまだ見つかりました"
  else
    pass "${f}: mode=none 案内から旧文言（プロジェクトルートに配置一択）が消えている（#128）"
  fi

  MN_BLOCK="$(awk '/mode=none\$.;/{f=1} f{print} f&&/^fi$/{exit}' "$MN_TARGET")"

  case "$MN_BLOCK" in
    *'規約パスに置く（推奨）'*'~/.claude/dev-workflow/sandbox/'*)
      pass "${f}: mode=none 案内に選択肢1（規約パス）がある（#128）" ;;
    *)
      fail "${f}: mode=none 案内に選択肢1（規約パス）がある（#128）" "$MN_BLOCK" ;;
  esac

  case "$MN_BLOCK" in
    *'環境変数で渡す'*'DEV_WORKFLOW_DOCKERFILE'*'DEV_WORKFLOW_DOCKER_COMPOSE_FILE'*'DEV_WORKFLOW_DOCKER_IMAGE'*)
      pass "${f}: mode=none 案内に選択肢2（環境変数）がある（#128）" ;;
    *)
      fail "${f}: mode=none 案内に選択肢2（環境変数）がある（#128）" "$MN_BLOCK" ;;
  esac

  case "$MN_BLOCK" in
    *'リポジトリ直下に置いてコミットする'*)
      pass "${f}: mode=none 案内に選択肢3（リポジトリ直下）がある（#128）" ;;
    *)
      fail "${f}: mode=none 案内に選択肢3（リポジトリ直下）がある（#128）" "$MN_BLOCK" ;;
  esac

  MN_SYNTAX_TMP="$(mktemp "${TMPDIR:-/tmp}/dw-test-mode-none.XXXXXX")"
  {
    echo 'PLAN="mode=none"'
    printf '%s\n' "$MN_BLOCK"
  } > "$MN_SYNTAX_TMP"
  if bash -n "$MN_SYNTAX_TMP" 2>/dev/null; then
    pass "${f}: mode=none 案内ブロックが bash として構文的に妥当である（#128）"
  else
    fail "${f}: mode=none 案内ブロックが bash として構文的に妥当である（#128）" \
      "$(bash -n "$MN_SYNTAX_TMP" 2>&1)"
  fi
  rm -f "$MN_SYNTAX_TMP"
done

# ---------------------------------------------------------------------------
# SessionStart フックと run スキル両系統への衛生プリフライト結線（#129）
# ---------------------------------------------------------------------------

echo ""
echo "== SessionStart フック / run スキル両系統への衛生プリフライト結線（#129） =="

HYG129_HOOKS_JSON="${REPO_ROOT}/hooks/hooks.json"
HYG129_HOOKS_CODEX_JSON="${REPO_ROOT}/hooks/hooks.codex.json"
HYG129_RUN_SKILL="$RUN_SKILL_FLAT"
HYG129_RUN_SKILL_CODEX="${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md"
HYG129_GOAL_SKILL="${REPO_ROOT}/skills/goal/SKILL.md"

# --- 両JSONとも構文として妥当（既存の _hj_json_syntax_ok を再利用する。#52で定義済み） ---

if _hj_json_syntax_ok "$HYG129_HOOKS_JSON"; then
  pass "hooks.json: check-repo-hygiene.sh結線後も構文として妥当（#129）"
else
  fail "hooks.json: check-repo-hygiene.sh結線後も構文として妥当（#129）" "$(cat "$HYG129_HOOKS_JSON" 2>&1)"
fi

if _hj_json_syntax_ok "$HYG129_HOOKS_CODEX_JSON"; then
  pass "hooks.codex.json: check-repo-hygiene.sh結線後も構文として妥当（#129）"
else
  fail "hooks.codex.json: check-repo-hygiene.sh結線後も構文として妥当（#129）" "$(cat "$HYG129_HOOKS_CODEX_JSON" 2>&1)"
fi

# --- hooks.json: SessionStartにcheck-prerequisites.shの次のエントリとして結線されている ---

HYG129_HOOKS_SESSIONSTART="$(_hj_extract_section "$HYG129_HOOKS_JSON" "SessionStart")"
if printf '%s' "$HYG129_HOOKS_SESSIONSTART" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-repo-hygiene.sh\"'; then
  pass "hooks.json: SessionStartにcheck-repo-hygiene.shが結線されている（#129）"
else
  fail "hooks.json: SessionStartにcheck-repo-hygiene.shが結線されている（#129）" "$HYG129_HOOKS_SESSIONSTART"
fi

HYG129_HOOKS_PREREQ_LINE="$(printf '%s\n' "$HYG129_HOOKS_SESSIONSTART" | grep -n 'check-prerequisites.sh' | head -1 | cut -d: -f1)"
HYG129_HOOKS_HYGIENE_LINE="$(printf '%s\n' "$HYG129_HOOKS_SESSIONSTART" | grep -n 'check-repo-hygiene.sh' | head -1 | cut -d: -f1)"
if [ -n "$HYG129_HOOKS_PREREQ_LINE" ] && [ -n "$HYG129_HOOKS_HYGIENE_LINE" ] \
  && [ "$HYG129_HOOKS_HYGIENE_LINE" -gt "$HYG129_HOOKS_PREREQ_LINE" ]; then
  pass "hooks.json: check-repo-hygiene.shはcheck-prerequisites.shの次のエントリである（#129）"
else
  fail "hooks.json: check-repo-hygiene.shはcheck-prerequisites.shの次のエントリである（#129）" \
    "$HYG129_HOOKS_SESSIONSTART"
fi

# 既定モードなのでブロックしない（--runを付けない。SessionStartエントリに--runが含まれないことを確認）
if printf '%s' "$HYG129_HOOKS_SESSIONSTART" | grep -F 'check-repo-hygiene.sh' | grep -q -- '--run'; then
  fail "hooks.json: SessionStartのcheck-repo-hygiene.shは既定モード（--runを付けない）である（#129）" \
    "$HYG129_HOOKS_SESSIONSTART"
else
  pass "hooks.json: SessionStartのcheck-repo-hygiene.shは既定モード（--runを付けない）である（#129）"
fi

# --- hooks.codex.json: 同様にSessionStartへ結線され、既存エントリと同じくtimeoutが付いている ---

HYG129_HOOKS_CODEX_SESSIONSTART="$(_hj_extract_section "$HYG129_HOOKS_CODEX_JSON" "SessionStart")"
if printf '%s' "$HYG129_HOOKS_CODEX_SESSIONSTART" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-repo-hygiene.sh\"'; then
  pass "hooks.codex.json: SessionStartにcheck-repo-hygiene.shが結線されている（#129）"
else
  fail "hooks.codex.json: SessionStartにcheck-repo-hygiene.shが結線されている（#129）" \
    "$HYG129_HOOKS_CODEX_SESSIONSTART"
fi

HYG129_HOOKS_CODEX_PREREQ_LINE="$(printf '%s\n' "$HYG129_HOOKS_CODEX_SESSIONSTART" | grep -n 'check-prerequisites.sh' | head -1 | cut -d: -f1)"
HYG129_HOOKS_CODEX_HYGIENE_LINE="$(printf '%s\n' "$HYG129_HOOKS_CODEX_SESSIONSTART" | grep -n 'check-repo-hygiene.sh' | head -1 | cut -d: -f1)"
if [ -n "$HYG129_HOOKS_CODEX_PREREQ_LINE" ] && [ -n "$HYG129_HOOKS_CODEX_HYGIENE_LINE" ] \
  && [ "$HYG129_HOOKS_CODEX_HYGIENE_LINE" -gt "$HYG129_HOOKS_CODEX_PREREQ_LINE" ]; then
  pass "hooks.codex.json: check-repo-hygiene.shはcheck-prerequisites.shの次のエントリである（#129）"
else
  fail "hooks.codex.json: check-repo-hygiene.shはcheck-prerequisites.shの次のエントリである（#129）" \
    "$HYG129_HOOKS_CODEX_SESSIONSTART"
fi

# check-repo-hygiene.shのエントリ自体に"timeout": 30が付いている（hooks.codex.jsonの他エントリと同じ作法）
HYG129_HOOKS_CODEX_HYGIENE_ENTRY="$(printf '%s\n' "$HYG129_HOOKS_CODEX_SESSIONSTART" \
  | awk '/check-repo-hygiene\.sh/{f=1} f{print} f&&/^[ \t]*}/{exit}')"
if printf '%s' "$HYG129_HOOKS_CODEX_HYGIENE_ENTRY" | grep -Fq '"timeout": 30'; then
  pass "hooks.codex.json: check-repo-hygiene.shのエントリにtimeout: 30が付いている（#129）"
else
  fail "hooks.codex.json: check-repo-hygiene.shのエントリにtimeout: 30が付いている（#129）" \
    "$HYG129_HOOKS_CODEX_HYGIENE_ENTRY"
fi

if printf '%s' "$HYG129_HOOKS_CODEX_SESSIONSTART" | grep -F 'check-repo-hygiene.sh' | grep -q -- '--run'; then
  fail "hooks.codex.json: SessionStartのcheck-repo-hygiene.shは既定モード（--runを付けない）である（#129）" \
    "$HYG129_HOOKS_CODEX_SESSIONSTART"
else
  pass "hooks.codex.json: SessionStartのcheck-repo-hygiene.shは既定モード（--runを付けない）である（#129）"
fi

# --- 両JSONとも参照しているscripts/check-repo-hygiene.shが実在する（参照切れの防止） ---

if [ -f "${REPO_ROOT}/scripts/check-repo-hygiene.sh" ]; then
  pass "hooks.json/hooks.codex.json: 参照しているscripts/check-repo-hygiene.shが実在する（#129）"
else
  fail "hooks.json/hooks.codex.json: 参照しているscripts/check-repo-hygiene.shが実在する（#129）" \
    "見つかりません: ${REPO_ROOT}/scripts/check-repo-hygiene.sh"
fi

# --- skills/run/SKILL.md: 「## 起動時の確認」の先頭（gh issue viewより前）に--runプリフライトがある ---

HYG129_RUN_STARTUP_BLOCK="$(awk '/^## 起動時の確認$/{f=1; print; next} f && /^#/{exit} f{print}' "$HYG129_RUN_SKILL")"
if printf '%s' "$HYG129_RUN_STARTUP_BLOCK" | grep -Fq 'check-repo-hygiene.sh" --run || exit 1'; then
  pass "skills/run/SKILL.md: 「## 起動時の確認」にcheck-repo-hygiene.sh --runのプリフライトがある（#129）"
else
  fail "skills/run/SKILL.md: 「## 起動時の確認」にcheck-repo-hygiene.sh --runのプリフライトがある（#129）" \
    "$HYG129_RUN_STARTUP_BLOCK"
fi

HYG129_RUN_PREFLIGHT_LINE="$(printf '%s\n' "$HYG129_RUN_STARTUP_BLOCK" | grep -n -- '--run || exit 1' | head -1 | cut -d: -f1)"
HYG129_RUN_ISSUEVIEW_LINE="$(printf '%s\n' "$HYG129_RUN_STARTUP_BLOCK" | grep -n 'gh issue view \$ARGUMENTS' | head -1 | cut -d: -f1)"
if [ -n "$HYG129_RUN_PREFLIGHT_LINE" ] && [ -n "$HYG129_RUN_ISSUEVIEW_LINE" ] \
  && [ "$HYG129_RUN_PREFLIGHT_LINE" -lt "$HYG129_RUN_ISSUEVIEW_LINE" ]; then
  pass "skills/run/SKILL.md: --runプリフライトはgh issue viewより前にある（#129）"
else
  fail "skills/run/SKILL.md: --runプリフライトはgh issue viewより前にある（#129）" "$HYG129_RUN_STARTUP_BLOCK"
fi

if printf '%s' "$HYG129_RUN_STARTUP_BLOCK" | grep -Fq 'exit 2' \
  && printf '%s' "$HYG129_RUN_STARTUP_BLOCK" | grep -Fq 'DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS'; then
  pass "skills/run/SKILL.md: exit 2で停止する旨とopt-out（DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS）が明記されている（#129）"
else
  fail "skills/run/SKILL.md: exit 2で停止する旨とopt-out（DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS）が明記されている（#129）" \
    "$HYG129_RUN_STARTUP_BLOCK"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: 同等の結線が入っている（結線漏れ禁止） ---

if grep -Fq 'check-repo-hygiene.sh" --run || exit 1' "$HYG129_RUN_SKILL_CODEX"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: check-repo-hygiene.sh --runのプリフライトがある（#129）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: check-repo-hygiene.sh --runのプリフライトがある（#129）" \
    "$(cat "$HYG129_RUN_SKILL_CODEX")"
fi

if grep -Fq 'exit 2' "$HYG129_RUN_SKILL_CODEX" \
  && grep -Fq 'DEV_WORKFLOW_ALLOW_TRACKED_SETTINGS' "$HYG129_RUN_SKILL_CODEX"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: exit 2で停止する旨とopt-outが明記されている（#129）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: exit 2で停止する旨とopt-outが明記されている（#129）"
fi

# check-repo-hygiene.sh --runの結線が、Epicブランチ+作業worktree準備（git fetch等）より前にあること
HYG129_CODEX_PREFLIGHT_LINE="$(grep -n -- '--run || exit 1' "$HYG129_RUN_SKILL_CODEX" | head -1 | cut -d: -f1)"
HYG129_CODEX_WORKTREE_LINE="$(grep -n '^## Epic ブランチと作業 worktree の準備$' "$HYG129_RUN_SKILL_CODEX" | head -1 | cut -d: -f1)"
if [ -n "$HYG129_CODEX_PREFLIGHT_LINE" ] && [ -n "$HYG129_CODEX_WORKTREE_LINE" ] \
  && [ "$HYG129_CODEX_PREFLIGHT_LINE" -lt "$HYG129_CODEX_WORKTREE_LINE" ]; then
  pass "skills-codex/dev-workflow-run/SKILL.md: --runプリフライトはEpicブランチ準備より前にある（#129）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: --runプリフライトはEpicブランチ準備より前にある（#129）" \
    "preflight_line=${HYG129_CODEX_PREFLIGHT_LINE} worktree_line=${HYG129_CODEX_WORKTREE_LINE}"
fi

# --- skills/goal/SKILL.md には結線しない（重複結線の禁止） ---

if grep -Fq 'check-repo-hygiene.sh' "$HYG129_GOAL_SKILL"; then
  fail "skills/goal/SKILL.md: check-repo-hygiene.shの重複結線が無い（runに委譲しているため）（#129）" \
    "$(grep -n 'check-repo-hygiene.sh' "$HYG129_GOAL_SKILL")"
else
  pass "skills/goal/SKILL.md: check-repo-hygiene.shの重複結線が無い（runに委譲しているため）（#129）"
fi

# ---------------------------------------------------------------------------
# resolve-sandbox.sh: 出力を%qでシェルクォートし、eval呼び出し側で空白入りパスが
# 分割・誤解釈されないこと（Task #132, Epic #122 レビュー指摘 #132）
#
# $HOME・リポジトリルートの双方に空白を含む規約パス構成で mode=dockerfile を解決させ、
# 出力を eval で取り込んだ後、DEV_WORKFLOW_SANDBOX_DOCKERFILE と
# DEV_WORKFLOW_SANDBOX_CONTEXT が分割されず完全なパスとして復元されることを確認する。
# ---------------------------------------------------------------------------

echo "== resolve-sandbox.sh: 空白を含むパスでもevalで値が分割されない（#132） =="

RS9_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-space-repo.XXXXXX")"
RS9_REPO="${RS9_PARENT}/repo with space"
mkdir -p "$RS9_REPO"
(
  cd "$RS9_REPO" || exit 1
  git init -q
  git config user.email "dev-workflow-test@example.com"
  git config user.name "dev-workflow test"
  printf 'test repo\n' > README.md
  git add README.md
  git commit -q -m "init"
) >/dev/null 2>&1

RS9_NAME="$(basename "$RS9_REPO")"
RS9_HOME_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-space-home.XXXXXX")"
RS9_HOME="${RS9_HOME_PARENT}/home with space"
mkdir -p "${RS9_HOME}/${RS9_NAME}"
cat > "${RS9_HOME}/${RS9_NAME}/Dockerfile.dev" <<'EOF'
FROM alpine
EOF

RS9_OUTPUT="$(
  cd "$RS9_REPO" || exit 1
  DEV_WORKFLOW_SANDBOX_HOME="$RS9_HOME" bash "$RESOLVE_SANDBOX_SCRIPT"
)"

# eval で取り込んだ後の値を確認する（呼び出し側 sandbox-exec.sh / check-repo-hygiene.sh と
# 同じ作法。空白で分割されていれば以下は途中で切れた値になる）
RS9_EVAL_RESULT="$(
  eval "$RS9_OUTPUT"
  printf 'RS9_MODE=%s\nRS9_DOCKERFILE=%s\nRS9_CONTEXT=%s\n' \
    "$DEV_WORKFLOW_SANDBOX_MODE" "$DEV_WORKFLOW_SANDBOX_DOCKERFILE" "$DEV_WORKFLOW_SANDBOX_CONTEXT"
)"

assert_eq "空白入りHOME/リポジトリルート: eval後もmode=dockerfileになる（#132）" \
  "dockerfile" "$(plan_value RS9_MODE "$RS9_EVAL_RESULT")"
assert_eq "空白入りHOME/リポジトリルート: eval後もDEV_WORKFLOW_SANDBOX_DOCKERFILEが完全なパスとして復元される（#132）" \
  "${RS9_HOME}/${RS9_NAME}/Dockerfile.dev" "$(plan_value RS9_DOCKERFILE "$RS9_EVAL_RESULT")"
assert_eq "空白入りHOME/リポジトリルート: eval後もDEV_WORKFLOW_SANDBOX_CONTEXTが完全なパスとして復元される（#132）" \
  "$(normalize_test_path "$RS9_REPO")" "$(plan_value RS9_CONTEXT "$RS9_EVAL_RESULT")"

# ---------------------------------------------------------------------------
# Task #147: evaluator に観点別レビュー（focus）と wave-review モードを追加する
#
# run側の並列起動・マージ手順は別タスクの担当。ここではevaluator側の契約
# （core/roles/evaluator.md・adapters/codex/schemas/evaluator-verdict.json・
# docs/adr/0003）が仕様どおりであることだけを検証する。
# ---------------------------------------------------------------------------

echo ""
echo "== Task #147: evaluator の観点別レビュー（focus）と wave-review モードの契約 =="

H147_EVALUATOR_ROLE="${REPO_ROOT}/core/roles/evaluator.md"

# --- 4観点の定義と、自分の観点の指摘だけを出す規定がある ---
if grep -Fq '`correctness`' "$H147_EVALUATOR_ROLE" \
  && grep -Fq '`readability`' "$H147_EVALUATOR_ROLE" \
  && grep -Fq '`over-engineering`' "$H147_EVALUATOR_ROLE" \
  && grep -Fq '`security`' "$H147_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 4観点（correctness/readability/over-engineering/security）が定義されている（#147）"
else
  fail "core/roles/evaluator.md: 4観点（correctness/readability/over-engineering/security）が定義されている（#147）" \
    "$(grep -n 'focus' "$H147_EVALUATOR_ROLE" | head -20)"
fi

if grep -Fq '観点を指定して起動された evaluator は、自分の観点の指摘だけを出す' "$H147_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 「自分の観点の指摘だけを出す」規定がある（#147）"
else
  fail "core/roles/evaluator.md: 「自分の観点の指摘だけを出す」規定がある（#147）" "節が見つかりません"
fi

# --- 観点未指定時は従来どおり全観点を見る（後方互換）ことが明記されている ---
if grep -Fq '観点未指定で起動された場合は従来どおり全観点を見る' "$H147_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 観点未指定時は従来どおり全観点を見る旨（後方互換）が明記されている（#147）"
else
  fail "core/roles/evaluator.md: 観点未指定時は従来どおり全観点を見る旨（後方互換）が明記されている（#147）" \
    "節が見つかりません"
fi

if grep -Fq 'Codexは観点未指定のまま使う' "$H147_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: Codexは観点未指定のまま使う旨が明記されている（#147）"
else
  fail "core/roles/evaluator.md: Codexは観点未指定のまま使う旨が明記されている（#147）" "節が見つかりません"
fi

# --- wave-review モードが定義され、差分範囲と「範囲外を蒸し返さない」規律が書かれている ---
H147_WAVEREVIEW_ROW="$(grep -n 'wave-review' "$H147_EVALUATOR_ROLE" | head -1)"
case "$H147_WAVEREVIEW_ROW" in
  *'前回レビュー済みcommit'*'epic-branch'*)
    pass "core/roles/evaluator.md: wave-review モードの差分範囲が定義されている（#147）" ;;
  *)
    fail "core/roles/evaluator.md: wave-review モードの差分範囲が定義されている（#147）" "$H147_WAVEREVIEW_ROW" ;;
esac

H147_WAVEREVIEW_SECTION="$(awk '/^### wave-review 特有の規律/{f=1} /^## 観点/{f=0} f' "$H147_EVALUATOR_ROLE")"
case "$H147_WAVEREVIEW_SECTION" in
  *'そのウェーブ差分だけを見る'*)
    pass "core/roles/evaluator.md: wave-reviewが範囲外を蒸し返さない規律を明記している（#147）" ;;
  *)
    fail "core/roles/evaluator.md: wave-reviewが範囲外を蒸し返さない規律を明記している（#147）" \
      "$H147_WAVEREVIEW_SECTION" ;;
esac

case "$H147_WAVEREVIEW_SECTION" in
  *'指摘はその場で直させない'*)
    pass "core/roles/evaluator.md: wave-reviewの指摘はその場で直させない旨が明記されている（#147）" ;;
  *)
    fail "core/roles/evaluator.md: wave-reviewの指摘はその場で直させない旨が明記されている（#147）" \
      "$H147_WAVEREVIEW_SECTION" ;;
esac

# --- 出力JSONに focus（トップレベルとfindings[]の各要素）が追加され、既存フィールドが変更されていない ---
H147_JSON_EXAMPLE="$(awk '/^```json$/{f=1} f{print} f && /^```$/ && NR>1 && !/^```json$/{exit}' "$H147_EVALUATOR_ROLE")"

for h147_field in '"verdict"' '"reviewed_commit"' '"focus"' '"findings"' '"severity"' '"title"' '"location"' '"detail"' '"fix"' '"task_ref"'; do
  if printf '%s\n' "$H147_JSON_EXAMPLE" | grep -Fq -- "$h147_field"; then
    pass "core/roles/evaluator.md: 出力JSON例に ${h147_field} が含まれる（#147）"
  else
    fail "core/roles/evaluator.md: 出力JSON例に ${h147_field} が含まれる（#147）" "$H147_JSON_EXAMPLE"
  fi
done

# focus がトップレベルとfindings要素の両方に出現する（2回以上）こと
H147_FOCUS_COUNT="$(printf '%s\n' "$H147_JSON_EXAMPLE" | grep -c '"focus"')"
if [ "$H147_FOCUS_COUNT" -ge 2 ]; then
  pass "core/roles/evaluator.md: 出力JSON例でfocusがトップレベルとfindings要素の両方に出現する（#147）"
else
  fail "core/roles/evaluator.md: 出力JSON例でfocusがトップレベルとfindings要素の両方に出現する（#147）" \
    "出現回数=${H147_FOCUS_COUNT}"
fi

# reviewed_commit がどのモード・観点でも必須である旨の明記
if grep -Fq 'どのモード・観点でも必ず出す' "$H147_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: reviewed_commitはどのモード・観点でも必須である旨が明記されている（#147）"
else
  fail "core/roles/evaluator.md: reviewed_commitはどのモード・観点でも必須である旨が明記されている（#147）" \
    "節が見つかりません"
fi

# --- adapters/codex/schemas/evaluator-verdict.json が新しいJSONと整合している ---
H147_SCHEMA="${REPO_ROOT}/adapters/codex/schemas/evaluator-verdict.json"

if [ -f "$H147_SCHEMA" ]; then
  pass "adapters/codex/schemas/evaluator-verdict.json: ファイルが存在する（#147）"
else
  fail "adapters/codex/schemas/evaluator-verdict.json: ファイルが存在する（#147）" "ファイルが見つかりません"
fi

if _hj_json_syntax_ok "$H147_SCHEMA"; then
  pass "adapters/codex/schemas/evaluator-verdict.json: JSONとして構文的に妥当である（括弧の対応が取れている）（#147）"
else
  fail "adapters/codex/schemas/evaluator-verdict.json: JSONとして構文的に妥当である（括弧の対応が取れている）（#147）" \
    "$(cat "$H147_SCHEMA" 2>&1)"
fi

for h147_schema_field in '"focus"' '"verdict"' '"reviewed_commit"' '"findings"'; do
  if grep -Fq -- "$h147_schema_field" "$H147_SCHEMA"; then
    pass "evaluator-verdict.json: ${h147_schema_field} が定義されている（#147）"
  else
    fail "evaluator-verdict.json: ${h147_schema_field} が定義されている（#147）" \
      "$(grep -n -- "$h147_schema_field" "$H147_SCHEMA")"
  fi
done

if grep -Fq '"all", "correctness", "readability", "over-engineering", "security"' "$H147_SCHEMA"; then
  pass "evaluator-verdict.json: focusのenumに4観点+allが定義されている（#147）"
else
  fail "evaluator-verdict.json: focusのenumに4観点+allが定義されている（#147）" \
    "$(grep -n 'enum' "$H147_SCHEMA")"
fi

# --- docs/adr/0003-parallel-review-by-focus.md が書かれている ---
H147_ADR="${REPO_ROOT}/docs/adr/0003-parallel-review-by-focus.md"

if [ -f "$H147_ADR" ]; then
  pass "docs/adr/0003-parallel-review-by-focus.md: ファイルが存在する（#147）"
else
  fail "docs/adr/0003-parallel-review-by-focus.md: ファイルが存在する（#147）" "ファイルが見つかりません"
fi

for h147_adr_heading in '## 決定' '## 理由' '## トレードオフ' '## 却下した代案'; do
  if grep -Fq -- "$h147_adr_heading" "$H147_ADR" 2>/dev/null; then
    pass "docs/adr/0003: 『${h147_adr_heading}』節がある（#147）"
  else
    fail "docs/adr/0003: 『${h147_adr_heading}』節がある（#147）" "節が見つかりません"
  fi
done

if grep -Fq 'Codex' "$H147_ADR" 2>/dev/null && grep -Fq '単一' "$H147_ADR" 2>/dev/null; then
  pass "docs/adr/0003: Codexは単一evaluatorのままにする理由が書かれている（#147）"
else
  fail "docs/adr/0003: Codexは単一evaluatorのままにする理由が書かれている（#147）" "節が見つかりません"
fi

# --- 生成物（agents/evaluator.md・codex-agents/evaluator.toml）にfocus契約が反映されている ---
H147_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
H147_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"

if grep -Fq 'wave-review' "$H147_AGENT_EVALUATOR" 2>/dev/null; then
  pass "agents/evaluator.md: core/roles/evaluator.mdのwave-review契約が生成物に反映されている（#147）"
else
  fail "agents/evaluator.md: core/roles/evaluator.mdのwave-review契約が生成物に反映されている（#147）" \
    "反映されていません"
fi

if grep -Fq 'wave-review' "$H147_CODEX_AGENT_EVALUATOR" 2>/dev/null; then
  pass "codex-agents/evaluator.toml: core/roles/evaluator.mdのwave-review契約が生成物に反映されている（#147）"
else
  fail "codex-agents/evaluator.toml: core/roles/evaluator.mdのwave-review契約が生成物に反映されている（#147）" \
    "反映されていません"
fi

# ---------------------------------------------------------------------------
# Task #151: evaluator プロンプトを観点別チェックリストに分割して薄くする
#
# core/roles/evaluator.md の「レビューチェックリスト」を観点ごとに
# core/references/review-checklist-*.md へ分割する。本体には観点と参照先の対応表・
# 「自分の観点だけを読む」指示・可読性原則の要点・JSON規約・判定基準を残す。
# ---------------------------------------------------------------------------

echo ""
echo "== Task #151: evaluator チェックリストの観点別分割（薄化） =="

H151_EVALUATOR_ROLE="${REPO_ROOT}/core/roles/evaluator.md"
H151_REF_CORRECTNESS="${REPO_ROOT}/core/references/review-checklist-correctness.md"
H151_REF_OVERENG="${REPO_ROOT}/core/references/review-checklist-over-engineering.md"
H151_REF_SECURITY="${REPO_ROOT}/core/references/review-checklist-security.md"

# --- 4つの参照ファイル（over-engineering / security / correctness、readabilityは本体）が存在する ---

for h151_ref in "$H151_REF_CORRECTNESS" "$H151_REF_OVERENG" "$H151_REF_SECURITY"; do
  if [ -f "$h151_ref" ]; then
    pass "$(basename "$h151_ref") が存在する（#151）"
  else
    fail "$(basename "$h151_ref") が存在する（#151）" "見つかりません: ${h151_ref}"
  fi
done

# --- 退避した記述が1文字も失われていない（各観点のチェックリスト項目が参照ファイルに残っている） ---

if grep -Fq '#### コード品質' "$H151_REF_CORRECTNESS" && grep -Fq '#### アーキテクチャ' "$H151_REF_CORRECTNESS" \
  && grep -Fq '#### テスト' "$H151_REF_CORRECTNESS" && grep -Fq '#### プロジェクト固有ルール' "$H151_REF_CORRECTNESS"; then
  pass "review-checklist-correctness.md: コード品質・アーキテクチャ・テスト・プロジェクト固有ルールの小節が残っている（#151）"
else
  fail "review-checklist-correctness.md: コード品質・アーキテクチャ・テスト・プロジェクト固有ルールの小節が残っている（#151）" \
    "$(cat "$H151_REF_CORRECTNESS" 2>&1)"
fi

if grep -Fq '#### セキュリティ' "$H151_REF_SECURITY" && grep -Fq '#### テスト安全性' "$H151_REF_SECURITY"; then
  pass "review-checklist-security.md: セキュリティ・テスト安全性の小節が残っている（#151）"
else
  fail "review-checklist-security.md: セキュリティ・テスト安全性の小節が残っている（#151）" \
    "$(cat "$H151_REF_SECURITY" 2>&1)"
fi

# --- 本体に観点と参照先の対応表があり、「自分の観点だけを読む」指示がある ---

if grep -Fq 'core/references/review-checklist-correctness.md' "$H151_EVALUATOR_ROLE" \
  && grep -Fq 'core/references/review-checklist-over-engineering.md' "$H151_EVALUATOR_ROLE" \
  && grep -Fq 'core/references/review-checklist-security.md' "$H151_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 観点と参照先の対応表がある（#151）"
else
  fail "core/roles/evaluator.md: 観点と参照先の対応表がある（#151）"
fi

if grep -Fq '自分に指定された観点の参照ファイルだけを読む' "$H151_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 「自分の観点の参照ファイルだけを読む」指示がある（#151）"
else
  fail "core/roles/evaluator.md: 「自分の観点の参照ファイルだけを読む」指示がある（#151）"
fi

# --- 観点未指定時は全参照ファイルを読む旨が明記されている（後方互換） ---

if grep -Fq 'この場合は上記表の**全ファイルを読む**' "$H151_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 観点未指定時は全参照ファイルを読む旨が明記されている（#151）"
else
  fail "core/roles/evaluator.md: 観点未指定時は全参照ファイルを読む旨が明記されている（#151）"
fi

# --- 可読性原則の要点が本体に残っている ---

if grep -Fq '#### 可読性（最優先・違反は即REQUEST_CHANGES' "$H151_EVALUATOR_ROLE" \
  && grep -Fq 'どの観点で起動されても、可読性原則違反は見逃してよいわけではない' "$H151_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 可読性原則の要点が本体に残っている（#151）"
else
  fail "core/roles/evaluator.md: 可読性原則の要点が本体に残っている（#151）"
fi

# --- JSONの規約・判定基準が本体から動いていない（既存 #147 の検査と同じ H147_EVALUATOR_ROLE 相当を再確認） ---

if grep -Fq '"verdict"' "$H151_EVALUATOR_ROLE" && grep -Fq '"reviewed_commit"' "$H151_EVALUATOR_ROLE" \
  && grep -Fq '## 判定基準' "$H151_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: JSONの規約・判定基準が本体に残っている（#151）"
else
  fail "core/roles/evaluator.md: JSONの規約・判定基準が本体に残っている（#151）"
fi

# --- core/roles/evaluator.md が薄くなっている（元254行に対し目安180行以下。行数競技にはしない。
#     Task #157 が「発見役と確度判定役」の役割分担節を正当に追加するため、しきい値は
#     220行に緩めて「有意に薄くなっていること」だけを検査する） ---

H151_LINES="$(wc -l < "$H151_EVALUATOR_ROLE" | tr -d ' ')"
if [ "$H151_LINES" -le 220 ]; then
  pass "core/roles/evaluator.md: 元254行より有意に薄くなっている（実測 ${H151_LINES} 行）（#151）"
else
  fail "core/roles/evaluator.md: 元254行より有意に薄くなっている（実測 ${H151_LINES} 行）（#151）" \
    "目安の220行を超えています"
fi

# --- 生成物（agents/evaluator.md・codex-agents/evaluator.toml）に対応表・可読性要点が反映されている ---

H151_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
H151_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"

if [ -f "$H151_AGENT_EVALUATOR" ] \
  && grep -Fq 'core/references/review-checklist-correctness.md' "$H151_AGENT_EVALUATOR" \
  && grep -Fq '自分に指定された観点の参照ファイルだけを読む' "$H151_AGENT_EVALUATOR"; then
  pass "agents/evaluator.md: 正本のチェックリスト分割内容が反映されている（#151）"
else
  fail "agents/evaluator.md: 正本のチェックリスト分割内容が反映されている（#151）" \
    "見つかりません: ${H151_AGENT_EVALUATOR}"
fi

if [ -f "$H151_CODEX_AGENT_EVALUATOR" ] \
  && grep -Fq 'core/references/review-checklist-correctness.md' "$H151_CODEX_AGENT_EVALUATOR" \
  && grep -Fq '自分に指定された観点の参照ファイルだけを読む' "$H151_CODEX_AGENT_EVALUATOR"; then
  pass "codex-agents/evaluator.toml: 正本のチェックリスト分割内容が反映されている（#151）"
else
  fail "codex-agents/evaluator.toml: 正本のチェックリスト分割内容が反映されている（#151）" \
    "見つかりません: ${H151_CODEX_AGENT_EVALUATOR}"
fi

# ---------------------------------------------------------------------------
# Task #157: evaluator を「発見は sonnet、確度判定は opus」に変える
#
# ハーネスで確認できた「起動時のモデル指定」（別エージェント定義を増やさない方式）で
# 発見役（既定sonnet）と確度判定役（起動時にopusを明示）を分ける。レビュー基準
# （core/instructions.md）は変更しない。Codex側は未確認のため据え置き、その事実を記述に残す。
# ---------------------------------------------------------------------------

echo ""
echo "== Task #157: evaluatorの発見役(sonnet)・確度判定役(opus)の分離 =="

H157_CLAUDE_OVERLAY="${REPO_ROOT}/adapters/claude/overlays/evaluator.md"
H157_EVALUATOR_ROLE="${REPO_ROOT}/core/roles/evaluator.md"
H157_REVIEW_REF="${REPO_ROOT}/skills/run/references/review.md"
H157_CODEX_OVERLAY="${REPO_ROOT}/adapters/codex/overlays/evaluator.toml"
H157_AGENT_EVALUATOR="${REPO_ROOT}/agents/evaluator.md"
H157_CODEX_AGENT_EVALUATOR="${REPO_ROOT}/codex-agents/evaluator.toml"
H157_README="${REPO_ROOT}/README.md"
H157_ADR="${REPO_ROOT}/docs/adr/0006-evaluator-model-split.md"
H157_INSTRUCTIONS="${REPO_ROOT}/core/instructions.md"

# --- adapters/claude/overlays/evaluator.md: frontmatterのmodelがsonnetに変わっている
#     （別エージェント定義を増やす方式ではなく、起動時上書き方式を採ったことの確認） ---

H157_FRONTMATTER="$(awk '/^---$/{c++; print; next} c==1' "$H157_CLAUDE_OVERLAY")"
if printf '%s\n' "$H157_FRONTMATTER" | grep -Fq 'model: sonnet'; then
  pass "adapters/claude/overlays/evaluator.md: frontmatterのmodelがsonnet（発見役の既定）になっている（#157）"
else
  fail "adapters/claude/overlays/evaluator.md: frontmatterのmodelがsonnet（発見役の既定）になっている（#157）" \
    "$H157_FRONTMATTER"
fi

if grep -Fq 'model: opus' "$H157_CLAUDE_OVERLAY" && grep -Fq '起動時モデル指定' "$H157_CLAUDE_OVERLAY"; then
  pass "adapters/claude/overlays/evaluator.md: 確度判定は起動時にmodel: opusへ上書きする旨が明記されている（#157）"
else
  fail "adapters/claude/overlays/evaluator.md: 確度判定は起動時にmodel: opusへ上書きする旨が明記されている（#157）"
fi

# --- core/roles/evaluator.md: 発見役と確度判定役の責務が分かれている ---

if grep -Fq '## 発見役と確度判定役' "$H157_EVALUATOR_ROLE" \
  && grep -Fq '**発見役**（既定モデル・sonnet）' "$H157_EVALUATOR_ROLE" \
  && grep -Fq '**確度判定役**（起動時に `model: opus` を明示して上書き）' "$H157_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: 発見役(sonnet)と確度判定役(opus)の責務が分かれている（#157）"
else
  fail "core/roles/evaluator.md: 発見役(sonnet)と確度判定役(opus)の責務が分かれている（#157）"
fi

# --- core/roles/evaluator.md: 確度判定を通らなかった指摘を黙って落とさない旨 ---

if grep -Fq '確度判定を経ずに黙って捨てる経路は無い' "$H157_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: highの指摘を黙って落とす経路が無い旨が明記されている（#157）"
else
  fail "core/roles/evaluator.md: highの指摘を黙って落とす経路が無い旨が明記されている（#157）"
fi

# --- core/roles/evaluator.md: wave-review/delta-reviewは確度判定を経由しない旨 ---

if grep -Fq 'wave-review / delta-review はこの確度判定を経由しない' "$H157_EVALUATOR_ROLE"; then
  pass "core/roles/evaluator.md: wave-review/delta-reviewは確度判定を経由しない旨が明記されている（#157）"
else
  fail "core/roles/evaluator.md: wave-review/delta-reviewは確度判定を経由しない旨が明記されている（#157）"
fi

# --- レビュー基準（重要度3段階・判定）が変更されていない ---
# core/instructions.md「レビュー基準」の判定式（APPROVE/REQUEST_CHANGES）が既存のまま残っている

if grep -Fq '**APPROVE**: 指摘なし、または low のみ' "$H157_INSTRUCTIONS" \
  && grep -Fq '**REQUEST_CHANGES**: high または medium の指摘がある' "$H157_INSTRUCTIONS"; then
  pass "core/instructions.md: レビュー基準の判定（APPROVE/REQUEST_CHANGES）が変更されていない（#157）"
else
  fail "core/instructions.md: レビュー基準の判定（APPROVE/REQUEST_CHANGES）が変更されていない（#157）"
fi

# --- skills/run/references/review.md: 確度判定の1節がR1〜R2の間に追加され、R1→確度判定→R2の順序が明確 ---

H157_REVIEW_R1_LINE="$(grep -n '^### R1の結果マージ' "$H157_REVIEW_REF" | head -1 | cut -d: -f1)"
H157_REVIEW_CONF_LINE="$(grep -n '^### 確度判定' "$H157_REVIEW_REF" | head -1 | cut -d: -f1)"
H157_REVIEW_R2_LINE="$(grep -n '^### R2: 指摘をissue化' "$H157_REVIEW_REF" | head -1 | cut -d: -f1)"

if [ -n "$H157_REVIEW_R1_LINE" ] && [ -n "$H157_REVIEW_CONF_LINE" ] && [ -n "$H157_REVIEW_R2_LINE" ] \
  && [ "$H157_REVIEW_R1_LINE" -lt "$H157_REVIEW_CONF_LINE" ] \
  && [ "$H157_REVIEW_CONF_LINE" -lt "$H157_REVIEW_R2_LINE" ]; then
  pass "review.md: R1の結果マージ → 確度判定 → R2の順序でセクションが並んでいる（#157）"
else
  fail "review.md: R1の結果マージ → 確度判定 → R2の順序でセクションが並んでいる（#157）" \
    "R1=${H157_REVIEW_R1_LINE} 確度判定=${H157_REVIEW_CONF_LINE} R2=${H157_REVIEW_R2_LINE}"
fi

# --- #162で、プロンプト本文の1行ではなくTask/Agentツールの起動時パラメータで
#     model: opusを渡す手順に変わった（詳細な検証は下記『Review #162』ブロック）。
#     ここではその移行後も「確度判定はopusで上書きする」という趣旨自体は残っていることだけを見る ---
if grep -Fq 'Task/Agent起動パラメータ: model: opus' "$H157_REVIEW_REF"; then
  pass "review.md: 確度判定の呼び出しでmodel: opusを明示的に上書きする指示がある（#157）"
else
  fail "review.md: 確度判定の呼び出しでmodel: opusを明示的に上書きする指示がある（#157）"
fi

if grep -Fq 'low-confidence` と判定された指摘は、破棄せず' "$H157_REVIEW_REF"; then
  pass "review.md: low-confidenceの指摘は破棄せず軽微な指摘として記録する旨が明記されている（#157）"
else
  fail "review.md: low-confidenceの指摘は破棄せず軽微な指摘として記録する旨が明記されている（#157）"
fi

# --- Codex側: 同等機構は未確認である事実が記述に残っている ---

if grep -Fq '未確認' "$H157_CODEX_OVERLAY" && grep -Fq '推測で実装しない' "$H157_CODEX_OVERLAY"; then
  pass "adapters/codex/overlays/evaluator.toml: モデル切り替え機構が未確認である事実が明記されている（#157）"
else
  fail "adapters/codex/overlays/evaluator.toml: モデル切り替え機構が未確認である事実が明記されている（#157）"
fi

# --- docs/adr/0006-evaluator-model-split.md: 必須節と確認結果・却下した代案が書かれている ---

if [ -f "$H157_ADR" ]; then
  pass "docs/adr/0006-evaluator-model-split.md: ファイルが存在する（#157）"
else
  fail "docs/adr/0006-evaluator-model-split.md: ファイルが存在する（#157）" "ファイルが見つかりません"
fi

for h157_adr_heading in '## 決定' '## 理由' '## トレードオフ' '## 却下した代案'; do
  if grep -Fq -- "$h157_adr_heading" "$H157_ADR" 2>/dev/null; then
    pass "docs/adr/0006: 『${h157_adr_heading}』節がある（#157）"
  else
    fail "docs/adr/0006: 『${h157_adr_heading}』節がある（#157）" "節が見つかりません"
  fi
done

if grep -Fq '(b) が実際に可能であることを確認した' "$H157_ADR" 2>/dev/null \
  && grep -Fq 'advisor toolの有無は確認していない' "$H157_ADR" 2>/dev/null \
  && grep -Fq 'Codex側' "$H157_ADR" 2>/dev/null && grep -Fq '確認していない' "$H157_ADR" 2>/dev/null; then
  pass "docs/adr/0006: ハーネスで確認した方法・未確認事項が事実ベースで書かれている（#157）"
else
  fail "docs/adr/0006: ハーネスで確認した方法・未確認事項が事実ベースで書かれている（#157）"
fi

# --- 生成物（agents/evaluator.md・codex-agents/evaluator.toml）に反映されている ---

if [ -f "$H157_AGENT_EVALUATOR" ] \
  && grep -Fq 'model: sonnet' "$H157_AGENT_EVALUATOR" \
  && grep -Fq '## 発見役と確度判定役' "$H157_AGENT_EVALUATOR"; then
  pass "agents/evaluator.md: 正本のモデル分離内容が反映されている（#157）"
else
  fail "agents/evaluator.md: 正本のモデル分離内容が反映されている（#157）" \
    "見つかりません: ${H157_AGENT_EVALUATOR}"
fi

if [ -f "$H157_CODEX_AGENT_EVALUATOR" ] \
  && grep -Fq '## 発見役と確度判定役' "$H157_CODEX_AGENT_EVALUATOR" \
  && grep -Fq '未確認' "$H157_CODEX_AGENT_EVALUATOR"; then
  pass "codex-agents/evaluator.toml: 正本のモデル分離内容・Codex未対応の明記が反映されている（#157）"
else
  fail "codex-agents/evaluator.toml: 正本のモデル分離内容・Codex未対応の明記が反映されている（#157）" \
    "見つかりません: ${H157_CODEX_AGENT_EVALUATOR}"
fi

# --- README.md: 3エージェント節のモデル構成説明が更新されている ---

if grep -Fq 'Sonnet（発見役・既定） / Opus（確度判定役・起動時上書き）' "$H157_README"; then
  pass "README.md: 3エージェント節のevaluatorモデル構成が発見役/確度判定役に更新されている（#157）"
else
  fail "README.md: 3エージェント節のevaluatorモデル構成が発見役/確度判定役に更新されている（#157）"
fi

# --- adapters/claude/build.sh --check / adapters/codex/build.sh --check が通る ---

if bash "${REPO_ROOT}/adapters/claude/build.sh" --check >/dev/null 2>&1; then
  pass "adapters/claude/build.sh --check: agents/ が core/ と一致している（#157）"
else
  fail "adapters/claude/build.sh --check: agents/ が core/ と一致している（#157）"
fi

if bash "${REPO_ROOT}/adapters/codex/build.sh" --check >/dev/null 2>&1; then
  pass "adapters/codex/build.sh --check: codex-agents/ が core/ と一致している（#157）"
else
  fail "adapters/codex/build.sh --check: codex-agents/ が core/ と一致している（#157）"
fi

# ---------------------------------------------------------------------------
# Task #148: ウェーブ差分の先行レビュー（wave-review）を次ウェーブの実装と並行させる
# ---------------------------------------------------------------------------

echo ""
echo "== Task #148: run側のwave-review起動・REVIEWED_COMMIT管理 =="

H148_WAVEREVIEW_REF="${REPO_ROOT}/skills/run/references/wave-review.md"

if [ -f "$H148_WAVEREVIEW_REF" ]; then
  pass "skills/run/references/wave-review.md が新規作成されている（#148）"
else
  fail "skills/run/references/wave-review.md が新規作成されている（#148）" "ファイルが存在しません"
fi

if grep -Fq 'references/wave-review.md' "${REPO_ROOT}/skills/run/SKILL.md"; then
  pass "SKILL.md本体からwave-review.mdへポインタで参照している（#148）"
else
  fail "SKILL.md本体からwave-review.mdへポインタで参照している（#148）" "参照が見つかりません"
fi

# --- Step 3: 同一メッセージでの起動と、その理由（バッチ全員が終わるまで結果が返らない）が書かれている ---
H148_RS_STEP3="$(awk '/^### Step 3:/{f=1} /^### Step 4:/{f=0} f' "$RUN_SKILL_FLAT")"

case "$H148_RS_STEP3" in
  *'同一メッセージ'*'wave-review'*)
    pass "SKILL.md: Step 3にレーン起動と同一メッセージでwave-reviewを起動する旨が書かれている（#148）" ;;
  *)
    fail "SKILL.md: Step 3にレーン起動と同一メッセージでwave-reviewを起動する旨が書かれている（#148）" \
      "$H148_RS_STEP3" ;;
esac

case "$H148_RS_STEP3" in
  *'バッチ全員が終わるまで結果が返らない'*)
    pass "SKILL.md: Step 3が同一メッセージでなければ並行にならない理由を明記している（#148）" ;;
  *)
    fail "SKILL.md: Step 3が同一メッセージでなければ並行にならない理由を明記している（#148）" \
      "$H148_RS_STEP3" ;;
esac

# --- 最初のウェーブでは起動しないことが書かれている ---
case "$H148_RS_STEP3" in
  *'PREV_WAVE_INCORPORATED'*'false'*)
    pass "SKILL.md: 最初のウェーブではwave-reviewを起動しないことが書かれている（#148）" ;;
  *)
    fail "SKILL.md: 最初のウェーブではwave-reviewを起動しないことが書かれている（#148）" \
      "$H148_RS_STEP3" ;;
esac

# --- バッチ内の動的補充とバッチ間（ウェーブ間）の並行化が区別されている ---
case "$H148_RS_STEP3" in
  *'バッチ間'*)
    pass "SKILL.md: バッチ内の動的補充とバッチ間の並行化が区別されている（#148）" ;;
  *)
    fail "SKILL.md: バッチ内の動的補充とバッチ間の並行化が区別されている（#148）" "$H148_RS_STEP3" ;;
esac

# --- REVIEWED_COMMITの初期値・更新・失敗時に進めない規定 ---
if grep -Fq 'REVIEWED_COMMIT="$(git merge-base "$BASE_BRANCH"' "${REPO_ROOT}/skills/run/SKILL.md"; then
  pass "SKILL.md: REVIEWED_COMMITの初期値（gh repo viewで解決したベースブランチとのmerge-base）が書かれている（#148, #160）"
else
  fail "SKILL.md: REVIEWED_COMMITの初期値（gh repo viewで解決したベースブランチとのmerge-base）が書かれている（#148, #160）" \
    "$(grep -n 'REVIEWED_COMMIT' "${REPO_ROOT}/skills/run/SKILL.md")"
fi

# --- REVIEWED_COMMITの初期化がベースブランチをmain/masterに決め打ちしていない（#160） ---
if grep -Fq 'REVIEWED_COMMIT="$(git merge-base main' "${REPO_ROOT}/skills/run/SKILL.md" \
  || grep -Fq 'REVIEWED_COMMIT="$(git merge-base main' "${REPO_ROOT}/skills/run/references/wave-review.md"; then
  fail "SKILL.md / wave-review.md: REVIEWED_COMMITの初期化がmainにハードコードされていない（#160）" \
    "ハードコードされた 'git merge-base main' が見つかった"
else
  pass "SKILL.md / wave-review.md: REVIEWED_COMMITの初期化がmainにハードコードされていない（#160）"
fi

# --- REVIEWED_COMMITの初期化がgh repo view --json defaultBranchRefで解決している（#160） ---
if grep -Fq 'gh repo view --json defaultBranchRef' "${REPO_ROOT}/skills/run/SKILL.md" \
  && grep -Fq 'gh repo view --json defaultBranchRef' "${REPO_ROOT}/skills/run/references/wave-review.md"; then
  pass "SKILL.md / wave-review.md: REVIEWED_COMMITの初期化がgh repo viewでベースブランチを解決している（#160）"
else
  fail "SKILL.md / wave-review.md: REVIEWED_COMMITの初期化がgh repo viewでベースブランチを解決している（#160）" \
    "$(grep -n 'defaultBranchRef' "${REPO_ROOT}/skills/run/SKILL.md" "${REPO_ROOT}/skills/run/references/wave-review.md")"
fi

if grep -Fq '進めない' "$H148_WAVEREVIEW_REF"; then
  pass "wave-review.md: 失敗時にREVIEWED_COMMITを進めない規定が書かれている（#148）"
else
  fail "wave-review.md: 失敗時にREVIEWED_COMMITを進めない規定が書かれている（#148）" \
    "$(cat "$H148_WAVEREVIEW_REF" 2>/dev/null)"
fi

# --- 指摘をその場で直さずreview issue化し、Epic:と前提:なしを書く ---
case "$(cat "$RUN_SKILL_FLAT")" in
  *'wave-review の指摘はその場で直さない'*'review'*'ラベル'*)
    pass "run スキル: wave-reviewの指摘はその場で直さずreview issue化する旨が明記されている（#148）" ;;
  *)
    fail "run スキル: wave-reviewの指摘はその場で直さずreview issue化する旨が明記されている（#148）" \
      "見つかりません" ;;
esac

H148_WAVEREVIEW_ISSUE_SECTION="$(awk '/^## 指摘の扱い/{f=1} /^## 最終ウェーブ/{f=0} f' "$H148_WAVEREVIEW_REF")"
case "$H148_WAVEREVIEW_ISSUE_SECTION" in
  *'- Epic:'*'- 前提: なし'*)
    pass "wave-review.md: issue本文に - Epic: と - 前提: なし を書く指示がある（#148）" ;;
  *)
    fail "wave-review.md: issue本文に - Epic: と - 前提: なし を書く指示がある（#148）" \
      "$H148_WAVEREVIEW_ISSUE_SECTION" ;;
esac

# --- 最終ウェーブ差分と全体整合をEpic末レビューが見ることが明記されている ---
H148_EPICREVIEW_INTRO="$(awk '/^## Epic一括レビュー/{f=1} /^### R0:/{f=0} f' "${REPO_ROOT}/skills/run/SKILL.md")"
case "$H148_EPICREVIEW_INTRO" in
  *'未レビュー差分'*'全ウェーブ横断の整合'*)
    pass "SKILL.md: Epic一括レビューの守備範囲（未レビュー差分＋全ウェーブ横断整合）が明記されている（#148）" ;;
  *)
    fail "SKILL.md: Epic一括レビューの守備範囲（未レビュー差分＋全ウェーブ横断整合）が明記されている（#148）" \
      "$H148_EPICREVIEW_INTRO" ;;
esac

# --- Codex版は変更しない（README・wave-review.mdに明記。skills-codex/adapters/codexにwave-reviewを持ち込まない） ---
if grep -Fq 'wave-review' "${REPO_ROOT}/README.md"; then
  pass "README.md: wave-review節が追加されている（#148）"
else
  fail "README.md: wave-review節が追加されている（#148）" "見つかりません"
fi

if grep -Fq 'wave-review' "$H148_WAVEREVIEW_REF" && grep -Fq 'Codex' "$H148_WAVEREVIEW_REF"; then
  pass "wave-review.md: Codex版には実装しない旨が明記されている（#148）"
else
  fail "wave-review.md: Codex版には実装しない旨が明記されている（#148）" \
    "$(cat "$H148_WAVEREVIEW_REF" 2>/dev/null)"
fi

if grep -rFq 'wave-review' "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md" 2>/dev/null; then
  fail "skills-codex/dev-workflow-run/SKILL.md: wave-reviewを持ち込んでいない（#148）" \
    "$(grep -n 'wave-review' "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"
else
  pass "skills-codex/dev-workflow-run/SKILL.md: wave-reviewを持ち込んでいない（#148）"
fi

if grep -Fq 'wave-review' "${REPO_ROOT}/adapters/codex/run-loop.sh" 2>/dev/null; then
  fail "adapters/codex/run-loop.sh: wave-reviewを持ち込んでいない（#148）" \
    "$(grep -n 'wave-review' "${REPO_ROOT}/adapters/codex/run-loop.sh")"
else
  pass "adapters/codex/run-loop.sh: wave-reviewを持ち込んでいない（#148）"
fi

# ---------------------------------------------------------------------------
# Task #149: Epic末レビューを観点別4本の並列起動にし、指摘のマージ・重複排除と
#            指摘対応の並列化を行う
# ---------------------------------------------------------------------------

echo ""
echo "== Task #149: Epic末レビューの観点別4本並列起動と指摘対応の並列化 =="

H149_RUN_SKILL="$RUN_SKILL_FLAT"
H149_REVIEW_REF="${REPO_ROOT}/skills/run/references/review.md"
H149_INSTRUCTIONS="$CORE_INSTRUCTIONS_FLAT"
H149_README="${REPO_ROOT}/README.md"

# --- R1: 4観点を同一メッセージで起動する手順になっており、理由が書かれている ---
H149_R1_SECTION="$(awk '/^### R1: 一括レビューの実行/{f=1} /^### R2以降/{f=0} f' "$H149_RUN_SKILL")"

if [ -z "$H149_R1_SECTION" ]; then
  fail "skills/run/SKILL.md: 『### R1: 一括レビューの実行』節が見つかる（#149）" "節が空でした"
else
  pass "skills/run/SKILL.md: 『### R1: 一括レビューの実行』節が見つかる（#149）"
fi

case "$H149_R1_SECTION" in
  *'同一メッセージで4本'*'correctness'*'readability'*'over-engineering'*'security'*)
    pass "skills/run/SKILL.md: R1が4観点をevaluatorの同一メッセージで起動する旨が明記されている（#149）" ;;
  *)
    fail "skills/run/SKILL.md: R1が4観点をevaluatorの同一メッセージで起動する旨が明記されている（#149）" \
      "$H149_R1_SECTION" ;;
esac

case "$H149_R1_SECTION" in
  *'同一メッセージでなければ並行にならない'*)
    pass "skills/run/SKILL.md: 同一メッセージで起動する理由（並行にならない）が書かれている（#149）" ;;
  *)
    fail "skills/run/SKILL.md: 同一メッセージで起動する理由（並行にならない）が書かれている（#149）" \
      "$H149_R1_SECTION" ;;
esac

case "$H149_R1_SECTION" in
  *'観点: correctness'*)
    pass "skills/run/SKILL.md: R1のプロンプト例に観点行がある（#149）" ;;
  *)
    fail "skills/run/SKILL.md: R1のプロンプト例に観点行がある（#149）" "$H149_R1_SECTION" ;;
esac

# --- 「変更50ファイル超」の3分岐が維持され、観点別並列と両立する形で書かれている ---
if grep -Fq 'CHANGED_FILES' "$H149_REVIEW_REF" \
  && grep -Fq '> 50' "$H149_REVIEW_REF" \
  && grep -Fq 'blast radius' "$H149_REVIEW_REF"; then
  pass "review.md: 『変更50ファイル超』の3分岐が維持されている（#149）"
else
  fail "review.md: 『変更50ファイル超』の3分岐が維持されている（#149）" "3分岐の記述が見つかりません"
fi

if grep -Fq '4観点すべてに同じように適用する' "$H149_REVIEW_REF" \
  || grep -Fq '観点別並列は' "$H149_REVIEW_REF"; then
  pass "review.md: 3分岐と観点別並列が両立する旨が書かれている（#149）"
else
  fail "review.md: 3分岐と観点別並列が両立する旨が書かれている（#149）" "記述が見つかりません"
fi

# --- マージ・重複排除の手順が明文化されている ---
H149_MERGE_SECTION="$(awk '/^### R1の結果マージ/{f=1} /^### R2: 指摘をissue化/{f=0} f' "$H149_REVIEW_REF")"

if [ -z "$H149_MERGE_SECTION" ]; then
  fail "review.md: 『### R1の結果マージ』節が見つかる（#149）" "節が空でした"
else
  pass "review.md: 『### R1の結果マージ』節が見つかる（#149）"
fi

case "$H149_MERGE_SECTION" in
  *'同一 `location`'*'最も高い severity'*)
    pass "review.md: 同一locationの統合と最高severityの採用が明記されている（#149）" ;;
  *)
    fail "review.md: 同一locationの統合と最高severityの採用が明記されている（#149）" "$H149_MERGE_SECTION" ;;
esac

case "$H149_MERGE_SECTION" in
  *'由来した観点名'*)
    pass "review.md: 由来した観点名の併記が明記されている（#149）" ;;
  *)
    fail "review.md: 由来した観点名の併記が明記されている（#149）" "$H149_MERGE_SECTION" ;;
esac

case "$H149_MERGE_SECTION" in
  *'verdict の合成'*'1本でも'*'REQUEST_CHANGES'*)
    pass "review.md: verdictの合成（1本でもREQUEST_CHANGESなら全体もREQUEST_CHANGES）が明記されている（#149）" ;;
  *)
    fail "review.md: verdictの合成（1本でもREQUEST_CHANGESなら全体もREQUEST_CHANGES）が明記されている（#149）" \
      "$H149_MERGE_SECTION" ;;
esac

case "$H149_MERGE_SECTION" in
  *'reviewed_commit'*'食い違った場合は'*'最も古いもの'*)
    pass "review.md: reviewed_commit食い違い時は最も古いものを採用する旨が明記されている（#149）" ;;
  *)
    fail "review.md: reviewed_commit食い違い時は最も古いものを採用する旨が明記されている（#149）" \
      "$H149_MERGE_SECTION" ;;
esac

# --- 1本失敗時に「記録して進む」扱いになっている（runを止めない） ---
case "$H149_MERGE_SECTION" in
  *'1本の失敗'*'記録して進む'*'run は止めない'*)
    pass "review.md: 1本失敗時に『記録して進む』扱いでrunを止めない旨が明記されている（#149）" ;;
  *)
    fail "review.md: 1本失敗時に『記録して進む』扱いでrunを止めない旨が明記されている（#149）" \
      "$H149_MERGE_SECTION" ;;
esac

# --- review issueに `- Epic:` と `- 前提: なし` を書く規定がある ---
H149_R2_SECTION="$(awk '/^### R2: 指摘をissue化/{f=1} /^### R3: 指摘対応ループ/{f=0} f' "$H149_REVIEW_REF")"

case "$H149_R2_SECTION" in
  *'- Epic: #'*'- 前提: なし'*)
    pass "review.md: review issueテンプレートに『- Epic:』と『- 前提: なし』がある（#149）" ;;
  *)
    fail "review.md: review issueテンプレートに『- Epic:』と『- 前提: なし』がある（#149）" \
      "$H149_R2_SECTION" ;;
esac

case "$H149_R2_SECTION" in
  *'plan-waves.sh'*)
    pass "review.md: plan-waves.shがこの2行を読む旨が明記されている（#149）" ;;
  *)
    fail "review.md: plan-waves.shがこの2行を読む旨が明記されている（#149）" "$H149_R2_SECTION" ;;
esac

case "$H149_R2_SECTION" in
  *'観点: [focus]'*)
    pass "review.md: review issueテンプレートに観点（focus）が残る（#149）" ;;
  *)
    fail "review.md: review issueテンプレートに観点（focus）が残る（#149）" "$H149_R2_SECTION" ;;
esac

# --- R3: 通常のウェーブループでの並列処理になっており、最大2巡の打ち切りと
#     未対応issueのPR本文への明記が維持されている ---
H149_R3_SECTION="$(awk '/^### R3: 指摘対応ループ/{f=1} /^### R4: 打ち切り条件/{f=0} f' "$H149_REVIEW_REF")"

case "$H149_R3_SECTION" in
  *'1件ずつ generator に渡すのではなく'*'ウェーブループ'*'並列に'*)
    pass "review.md: R3が通常のウェーブループでの並列処理になっている（#149）" ;;
  *)
    fail "review.md: R3が通常のウェーブループでの並列処理になっている（#149）" "$H149_R3_SECTION" ;;
esac

H149_R4_SECTION="$(awk '/^### R4: 打ち切り条件/{f=1} /^### レビュー粒度の調整/{f=0} f' "$H149_REVIEW_REF")"

case "$H149_R4_SECTION" in
  *'最大2巡まで'*)
    pass "review.md: 最大2巡の打ち切りが維持されている（#149）" ;;
  *)
    fail "review.md: 最大2巡の打ち切りが維持されている（#149）" "$H149_R4_SECTION" ;;
esac

case "$H149_R4_SECTION" in
  *'オープンのまま残す'*'PR本文の'*'未対応の指摘'*)
    pass "review.md: 未対応issueをオープンのままPR本文に明記する規定が維持されている（#149）" ;;
  *)
    fail "review.md: 未対応issueをオープンのままPR本文に明記する規定が維持されている（#149）" "$H149_R4_SECTION" ;;
esac

# --- delta-reviewは観点別に分けず1本で行う旨が明記されている ---
if grep -Fq '観点別に分けず' "$H149_REVIEW_REF" && grep -Fq '1本' "$H149_REVIEW_REF"; then
  pass "review.md: delta-reviewは観点別に分けず1本で行う旨が明記されている（#149）"
else
  fail "review.md: delta-reviewは観点別に分けず1本で行う旨が明記されている（#149）" "記述が見つかりません"
fi

# --- core/instructions.md: 「レビュー基準」「レビューはEpic単位でまとめて行う」節が
#     観点別並列の実態に合わせて更新されている ---
H149_INSTR_REVIEW_SECTION="$(awk '/^### レビューはEpic単位でまとめて行う/{f=1} /^### 機械的ゲートの三段構成/{f=0} f' \
  "$H149_INSTRUCTIONS")"

case "$H149_INSTR_REVIEW_SECTION" in
  *'観点'*'correctness'*'readability'*'over-engineering'*'security'*'同一メッセージで並列起動'*)
    pass "core/instructions.md: レビューはEpic単位でまとめて行う節が観点別並列起動に更新されている（#149）" ;;
  *)
    fail "core/instructions.md: レビューはEpic単位でまとめて行う節が観点別並列起動に更新されている（#149）" \
      "$H149_INSTR_REVIEW_SECTION" ;;
esac

case "$H149_INSTR_REVIEW_SECTION" in
  *'Codex は'*'lanes=1'*'単一 evaluator'*)
    pass "core/instructions.md: CodexはlanesはCodexは単一evaluatorのままである旨が明記されている（#149）" ;;
  *)
    fail "core/instructions.md: CodexはlanesはCodexは単一evaluatorのままである旨が明記されている（#149）" \
      "$H149_INSTR_REVIEW_SECTION" ;;
esac

# --- Codexは単一evaluatorのままである旨がREADMEに書かれている ---
H149_README_CODEXDIFF="$(awk '/^### Codex との差/{f=1} /^### `scripts\/plan-waves.sh --print`/{f=0} f' "$H149_README")"

case "$H149_README_CODEXDIFF" in
  *'単一 evaluator の全観点レビューのまま'*)
    pass "README.md: Codexとの差にCodexは単一evaluatorのままである旨が書かれている（#149）" ;;
  *)
    fail "README.md: Codexとの差にCodexは単一evaluatorのままである旨が書かれている（#149）" \
      "$H149_README_CODEXDIFF" ;;
esac

# --- 生成物（agents/*.md・codex-agents/*.toml）にもcore/instructions.mdのレビュー基準節の
#     更新が反映されている（build.shの再生成漏れを検知する） ---
for h149_f in agents/planner.md agents/generator.md agents/evaluator.md \
              codex-agents/planner.toml codex-agents/generator.toml codex-agents/evaluator.toml; do
  if grep -Fq -- '同一メッセージで並列起動' "${REPO_ROOT}/${h149_f}"; then
    pass "${h149_f}: core/instructions.mdの観点別並列起動の記述が生成物に反映されている（#149）"
  else
    fail "${h149_f}: core/instructions.mdの観点別並列起動の記述が生成物に反映されている（#149）" \
      "反映されていません"
  fi
done

# ---------------------------------------------------------------------------
# Review #163: SKILL.md のモデル記述・evaluator起動回数の上限が、#157（モデル分離）と
#              #149（観点別並列 + 確度判定 + delta-review）に追随していること
# ---------------------------------------------------------------------------

echo ""
echo "== Review #163: SKILL.mdのモデル記述・evaluator起動回数の上限の整合 =="

H163_SKILL_RAW="${REPO_ROOT}/skills/run/SKILL.md"
H163_REVIEW_REF="${REPO_ROOT}/skills/run/references/review.md"
H163_README="${REPO_ROOT}/README.md"

# --- (1) SKILL.mdの「モデル構成の確認」節が、#157（既定sonnet + 確度判定だけ起動時opus上書き）
#     と食い違う古い記述（generator・evaluatorとも固定）を含んでいない ---
if grep -Fq 'generator（sonnet）・evaluator（opus）のモデルはエージェント定義側で固定されており' \
  "$H163_SKILL_RAW"; then
  fail "skills/run/SKILL.md: #157以前の古いモデル固定記述（generator・evaluator一括固定）が残っていない（#163）" \
    "古い記述が見つかりました"
else
  pass "skills/run/SKILL.md: #157以前の古いモデル固定記述（generator・evaluator一括固定）が残っていない（#163）"
fi

H163_SKILL_MODEL_SECTION="$(awk '/^### モデル構成の確認/{f=1} /^### Epicブランチ \+ 作業 worktree の準備/{f=0} f' \
  "$H163_SKILL_RAW")"

case "$H163_SKILL_MODEL_SECTION" in
  *'generator（sonnet）のモデルはエージェント定義側で固定されており'*'確度判定役として起動する呼び出しだけ'*'model: opus'*'起動時に上書きする'*)
    pass "skills/run/SKILL.md: モデル構成の確認節がgenerator固定+evaluator確度判定役opus上書きの記述に揃っている（#163）" ;;
  *)
    fail "skills/run/SKILL.md: モデル構成の確認節がgenerator固定+evaluator確度判定役opus上書きの記述に揃っている（#163）" \
      "$H163_SKILL_MODEL_SECTION" ;;
esac

# --- README.mdの対応箇所（推奨settings.jsonの直後）にも同じ趣旨の記述がある ---
if grep -Fq 'generator（sonnet）のモデルはエージェント定義側で固定されており' "$H163_README" \
  && grep -Fq '確度判定役として起動する呼び出しだけ' "$H163_README"; then
  pass "README.md: モデル構成の記述がSKILL.mdと同じ趣旨（generator固定+evaluator確度判定役opus上書き）になっている（#163）"
else
  fail "README.md: モデル構成の記述がSKILL.mdと同じ趣旨（generator固定+evaluator確度判定役opus上書き）になっている（#163）" \
    "記述が見つかりません"
fi

# --- (2) evaluator起動回数の上限が「観点別4本＋確度判定1本＋delta-review1本＝最大6回」で
#     SKILL.md・review.md・core/instructions.md・READMEの4か所すべて一致している ---
if grep -Fq 'evaluator 起動は最大6回' "$H163_SKILL_RAW"; then
  pass "skills/run/SKILL.md: evaluator起動の上限が最大6回と明記されている（#163）"
else
  fail "skills/run/SKILL.md: evaluator起動の上限が最大6回と明記されている（#163）" \
    "$(grep -n 'evaluator.*起動は最大' "$H163_SKILL_RAW" || echo '該当行が見つかりません')"
fi

if grep -Fq 'evaluator起動は最大6回' "$H163_REVIEW_REF"; then
  pass "skills/run/references/review.md: evaluator起動の上限が最大6回と明記されている（#163）"
else
  fail "skills/run/references/review.md: evaluator起動の上限が最大6回と明記されている（#163）" \
    "$(grep -n 'evaluator起動は最大' "$H163_REVIEW_REF" || echo '該当行が見つかりません')"
fi

# --- SKILL.md・review.md に、#149以前の古い上限（最大3回・最大5回）が残っていない ---
for h163_pair in "$H163_SKILL_RAW:skills/run/SKILL.md" "$H163_REVIEW_REF:skills/run/references/review.md"; do
  h163_file="${h163_pair%%:*}"
  h163_label="${h163_pair#*:}"
  if grep -E -q 'evaluator ?起動は最大(3|5)回' "$h163_file"; then
    fail "${h163_label}: #149以前の古いevaluator起動上限（最大3回・最大5回）が残っていない（#163）" \
      "$(grep -nE 'evaluator ?起動は最大(3|5)回' "$h163_file")"
  else
    pass "${h163_label}: #149以前の古いevaluator起動上限（最大3回・最大5回）が残っていない（#163）"
  fi
done

# --- core/instructions.md・READMEも同じ内訳（観点別4本＋確度判定1本＋delta-review1本）を
#     述べており、SKILL.md・review.mdの「最大6回」と矛盾しない ---
for h163_doc in "$CORE_INSTRUCTIONS_FLAT:core/instructions.md" "$H163_README:README.md"; do
  h163_docfile="${h163_doc%%:*}"
  h163_doclabel="${h163_doc#*:}"
  h163_docbody="$(cat "$h163_docfile" 2>/dev/null)"
  case "$h163_docbody" in
    *'観点別4本'*'確度判定1本'*'delta-review'*'1本'*)
      pass "${h163_doclabel}: evaluator起動回数の内訳（観点別4本＋確度判定1本＋delta-review1本）が明記されている（#163）" ;;
    *)
      fail "${h163_doclabel}: evaluator起動回数の内訳（観点別4本＋確度判定1本＋delta-review1本）が明記されている（#163）" \
        "内訳の記述が見つかりません" ;;
  esac
done

# ---------------------------------------------------------------------------
# Review #162: 確度判定役のopus指定が、Task/Agentツールの起動時パラメータとして渡す手順
#              になっており、プロンプト本文の1行に留まっていないこと
# ---------------------------------------------------------------------------

echo ""
echo "== Review #162: 確度判定役のopus起動がTask/Agentの起動時パラメータになっている =="

H162_REVIEW_REF="${REPO_ROOT}/skills/run/references/review.md"
H162_CONFIDENCE_SECTION="$(awk '/^### 確度判定（R1 と R2 の間/{f=1} /^### R2: 指摘をissue化/{f=0} f' \
  "$H162_REVIEW_REF")"

if [ -z "$H162_CONFIDENCE_SECTION" ]; then
  fail "review.md: 『### 確度判定』節が見つかる（#162）" "節が空でした"
else
  pass "review.md: 『### 確度判定』節が見つかる（#162）"
fi

# --- プロンプト本文の中の1行（- 起動時モデル指定: model: opus）に留まっていない ---
case "$H162_CONFIDENCE_SECTION" in
  *'- 起動時モデル指定: model: opus'*)
    fail "review.md: 確度判定のopus指定がプロンプト本文の1行に留まっていない（#162）" \
      "旧来の『- 起動時モデル指定: model: opus』行が残っています" ;;
  *)
    pass "review.md: 確度判定のopus指定がプロンプト本文の1行に留まっていない（#162）" ;;
esac

# --- Task/Agentツールの起動時パラメータとしてmodelを渡す手順が明記されている ---
case "$H162_CONFIDENCE_SECTION" in
  *'Task/Agent ツールの起動時パラメータ'*'model: opus'*)
    pass "review.md: Task/Agentツールの起動時パラメータでmodel: opusを渡す手順が明記されている（#162）" ;;
  *)
    fail "review.md: Task/Agentツールの起動時パラメータでmodel: opusを渡す手順が明記されている（#162）" \
      "$H162_CONFIDENCE_SECTION" ;;
esac

# --- プロンプト雛形自体にも起動時パラメータの行がある ---
case "$H162_CONFIDENCE_SECTION" in
  *'Task/Agent起動パラメータ: model: opus'*)
    pass "review.md: 確度判定のプロンプト雛形にTask/Agent起動パラメータの行がある（#162）" ;;
  *)
    fail "review.md: 確度判定のプロンプト雛形にTask/Agent起動パラメータの行がある（#162）" \
      "$H162_CONFIDENCE_SECTION" ;;
esac

# --- 上書きが効いたかを確認できるよう、出力JSONにモデル名を含めさせる、または
#     record-agent-tokens.shのnoteにモデル名を記録する手順がある ---
case "$H162_CONFIDENCE_SECTION" in
  *'model'*'フィールド'*)
    pass "review.md: 確度判定の出力JSONに実際に動いたモデル名を含めさせる規定がある（#162）" ;;
  *)
    fail "review.md: 確度判定の出力JSONに実際に動いたモデル名を含めさせる規定がある（#162）" \
      "$H162_CONFIDENCE_SECTION" ;;
esac

case "$H162_CONFIDENCE_SECTION" in
  *'--note'*'model='*)
    pass "review.md: record-agent-tokens.shの--noteにモデル名を記録する手順がある（#162）" ;;
  *)
    fail "review.md: record-agent-tokens.shの--noteにモデル名を記録する手順がある（#162）" \
      "$H162_CONFIDENCE_SECTION" ;;
esac

# --- 起動時モデル上書きが実現できなかった場合の扱い（据え置き＝発見役と同一モデルで
#     確度判定する旨）がADR-0006の決定Cと同じ「記録して進む」枠で明記されている ---
case "$H162_CONFIDENCE_SECTION" in
  *'技術的に実現できなかった場合'*'同一モデル'*'記録して進む'*)
    pass "review.md: 起動時モデル上書きが実現できなかった場合の据え置き扱いが明記されている（#162）" ;;
  *)
    fail "review.md: 起動時モデル上書きが実現できなかった場合の据え置き扱いが明記されている（#162）" \
      "$H162_CONFIDENCE_SECTION" ;;
esac

# --- ADR-0006の(b)起動時モデル上書きが確認済みの事実として引用されている ---
case "$H162_CONFIDENCE_SECTION" in
  *'ADR-0006'*'確認したとおり'*)
    pass "review.md: ADR-0006が確認した事実として起動時モデル上書きを引用している（#162）" ;;
  *)
    fail "review.md: ADR-0006が確認した事実として起動時モデル上書きを引用している（#162）" \
      "$H162_CONFIDENCE_SECTION" ;;
esac

# --- 生成物側（core/roles/evaluator.md由来）は変更していないので、既存の記述と矛盾しない ---
if grep -Fq '起動時に `model: opus` を明示して上書き' "${REPO_ROOT}/core/roles/evaluator.md"; then
  pass "core/roles/evaluator.md: 確度判定役は起動時にmodel: opusを明示して上書きする旨が維持されている（#162）"
else
  fail "core/roles/evaluator.md: 確度判定役は起動時にmodel: opusを明示して上書きする旨が維持されている（#162）" \
    "記述が見つかりません"
fi

# ---------------------------------------------------------------------------
# Task #153: レーンをウェーブ横断で維持し generator の cold start を除去する
# ---------------------------------------------------------------------------

echo ""
echo "== Task #153/#152: cross-wave lane reuseの検証結果とその訂正の明記 =="

H153_ADR="${REPO_ROOT}/docs/adr/0004-cross-wave-lane-reuse.md"

if [ -f "$H153_ADR" ]; then
  pass "docs/adr/0004-cross-wave-lane-reuse.md が新規作成されている（#153）"
else
  fail "docs/adr/0004-cross-wave-lane-reuse.md が新規作成されている（#153）" "ファイルが存在しません"
fi

# --- Task #153当時の誤った結論と、Task #152による訂正の両方がADRに書かれている ---
H153_ADR_BODY="$(cat "$H153_ADR" 2>/dev/null)"
case "$H153_ADR_BODY" in
  *'`SendMessage` ツールが実在する'*)
    pass "ADR 0004: SendMessageツールが実在するという訂正後の事実が書かれている（#152）" ;;
  *)
    fail "ADR 0004: SendMessageツールが実在するという訂正後の事実が書かれている（#152）" \
      "$H153_ADR_BODY" ;;
esac
case "$H153_ADR_BODY" in
  *'この結論は誤りだった'*)
    pass "ADR 0004: Task #153の当初結論が誤りだったと明記されている（#152）" ;;
  *)
    fail "ADR 0004: Task #153の当初結論が誤りだったと明記されている（#152）" \
      "$H153_ADR_BODY" ;;
esac
case "$H153_ADR_BODY" in
  *'本 Epic では実際に cross-wave 継続を実装・実地検証してはいない'*)
    pass "ADR 0004: 機構はあるが本Epicでは未検証である旨が明記されている（#152）" ;;
  *)
    fail "ADR 0004: 機構はあるが本Epicでは未検証である旨が明記されている（#152）" \
      "$H153_ADR_BODY" ;;
esac

# --- 決定: 本Epicのスコープでは実装しない（見送り）ことが明記されている ---
case "$H153_ADR_BODY" in
  *'レーンのウェーブ横断維持は、本 Epic のスコープでは実装しない'*)
    pass "ADR 0004: 本Epicのスコープでは実装しない（見送り）という決定が明記されている（#152）" ;;
  *)
    fail "ADR 0004: 本Epicのスコープでは実装しない（見送り）という決定が明記されている（#152）" \
      "$H153_ADR_BODY" ;;
esac

# --- フォールバック用の環境変数を追加しなかった判断と理由がADRにある ---
case "$H153_ADR_BODY" in
  *'環境変数は追加しない'*)
    pass "ADR 0004: フォールバック用環境変数を追加しない判断と理由が書かれている（#153）" ;;
  *)
    fail "ADR 0004: フォールバック用環境変数を追加しない判断と理由が書かれている（#153）" \
      "$H153_ADR_BODY" ;;
esac

# --- 余ったレーンの扱いが決まっている ---
case "$H153_ADR_BODY" in
  *'余ったレーンの扱い'*)
    pass "ADR 0004: 余ったレーンの扱いが決まっている（#153）" ;;
  *)
    fail "ADR 0004: 余ったレーンの扱いが決まっている（#153）" "$H153_ADR_BODY" ;;
esac

# --- SKILL.md Step 3: バッチ内の動的補充とバッチ間（ウェーブ間）継続の区別が明確 ---
H153_RS_STEP3="$(awk '/^### Step 3:/{f=1} /^### Step 4:/{f=0} f' "$RUN_SKILL_FLAT")"
case "$H153_RS_STEP3" in
  *'バッチ内'*'バッチ間'*'Task tool'*)
    pass "SKILL.md: バッチ内の動的補充とバッチ間（ウェーブ間）継続の区別が明確に書かれている（#153）" ;;
  *)
    fail "SKILL.md: バッチ内の動的補充とバッチ間（ウェーブ間）継続の区別が明確に書かれている（#153）" \
      "$H153_RS_STEP3" ;;
esac

# --- レーンはウェーブをまたいで維持されない旨とADR参照がSKILL.mdにある ---
case "$H153_RS_STEP3" in
  *'レーンはウェーブごとに新規 spawn する現行の方式のまま'*'0004-cross-wave-lane-reuse.md'*)
    pass "SKILL.md: レーンをウェーブごとに新規spawnする現行方式を維持する旨とADR参照がある（#153）" ;;
  *)
    fail "SKILL.md: レーンをウェーブごとに新規spawnする現行方式を維持する旨とADR参照がある（#153）" \
      "$H153_RS_STEP3" ;;
esac

# --- core/roles/generator.md にWAVE_BASE追従の書き分け（区別が生じない理由）が明記されている ---
H153_GEN_ROLE="${REPO_ROOT}/core/roles/generator.md"
if grep -Fq 'タスク境界／ウェーブ境界という書き分けは生じない' "$H153_GEN_ROLE"; then
  pass "core/roles/generator.md: WAVE_BASE追従がタスク境界/ウェーブ境界で書き分け不要である理由が明記されている（#153）"
else
  fail "core/roles/generator.md: WAVE_BASE追従がタスク境界/ウェーブ境界で書き分け不要である理由が明記されている（#153）" \
    "$(grep -n 'WAVE_BASE\|境界' "$H153_GEN_ROLE")"
fi

# --- core/instructions.md「タスク選定順序」項目3に、連続処理が同一ウェーブ内に限られる旨が追記されている ---
H153_INSTR="${REPO_ROOT}/core/instructions.md"
H153_INSTR_SEC="$(awk '/^### タスク選定順序/{f=1} /^## ブランチ戦略/{f=0} f' "$H153_INSTR")"
case "$H153_INSTR_SEC" in
  *'この連続処理は同一ウェーブ内に限られる'*)
    pass "core/instructions.md: レーンの連続処理が同一ウェーブ内に限られる旨が明記されている（#153）" ;;
  *)
    fail "core/instructions.md: レーンの連続処理が同一ウェーブ内に限られる旨が明記されている（#153）" \
      "$H153_INSTR_SEC" ;;
esac

# --- README.md にcross-wave lane reuseの検証結果が明記されている ---
if grep -Fq 'cross-wave lane reuse' "${REPO_ROOT}/README.md"; then
  pass "README.md: cross-wave lane reuseの検証結果が明記されている（#153）"
else
  fail "README.md: cross-wave lane reuseの検証結果が明記されている（#153）" "見つかりません"
fi

# --- README.md にTask #153当時の誤った結論とTask #152による訂正の両方が明記されている ---
if grep -Fq '`SendMessage` ツールが実在し' "${REPO_ROOT}/README.md"; then
  pass "README.md: SendMessageツールが実在するという訂正後の事実が明記されている（#152）"
else
  fail "README.md: SendMessageツールが実在するという訂正後の事実が明記されている（#152）" "見つかりません"
fi

# --- 生成物（agents/*.md・codex-agents/*.toml）が core/ と一致している（build.sh実行済み） ---
H153_BUILD_CLAUDE_CHECK="$(bash "${REPO_ROOT}/adapters/claude/build.sh" --check 2>&1)"
H153_BUILD_CLAUDE_EXIT=$?
if [ "$H153_BUILD_CLAUDE_EXIT" -eq 0 ]; then
  pass "adapters/claude/build.sh --check: agents/ が core/ と一致している（#153）"
else
  fail "adapters/claude/build.sh --check: agents/ が core/ と一致している（#153）" "$H153_BUILD_CLAUDE_CHECK"
fi

H153_BUILD_CODEX_CHECK="$(bash "${REPO_ROOT}/adapters/codex/build.sh" --check 2>&1)"
H153_BUILD_CODEX_EXIT=$?
if [ "$H153_BUILD_CODEX_EXIT" -eq 0 ]; then
  pass "adapters/codex/build.sh --check: codex-agents/ が core/ と一致している（#153）"
else
  fail "adapters/codex/build.sh --check: codex-agents/ が core/ と一致している（#153）" "$H153_BUILD_CODEX_CHECK"
fi

# ---------------------------------------------------------------------------
# Task #156: 完了報告を「証跡はファイル、報告は1行」に変えて出力トークンを削る
# ---------------------------------------------------------------------------

echo ""
echo "== 完了報告の証跡ファイル化・1行化（#156） =="

FORMAT_LANE_RESULT_SCRIPT="${REPO_ROOT}/scripts/format-lane-result.sh"

if [ -x "$FORMAT_LANE_RESULT_SCRIPT" ]; then
  pass "scripts/format-lane-result.sh: 実行可能ファイルとして存在する（#156）"
else
  fail "scripts/format-lane-result.sh: 実行可能ファイルとして存在する（#156）" "見つからない、または実行権限が無い"
fi

# --- ケース1: 証跡ファイル1件（成功）から1レーン分の断片を組み立てる ---
H156_EV_A1="$(mktemp "${TMPDIR:-/tmp}/dw-lane-evidence.XXXXXX")"
cat > "$H156_EV_A1" <<'FIXTURE'
== dummy test output ==
ok  	example.com/pkg	0.032s
---
task=5
lane=A
status=success
start_epoch=1000
end_epoch=1480
start_hm=12:03
end_hm=12:11
duration_sec=480
skips=0
runner=go
pattern=none
FIXTURE

H156_OUT_1="$(bash "$FORMAT_LANE_RESULT_SCRIPT" --lane A --file "$H156_EV_A1")"
H156_EXIT_1=$?
assert_exit_code "format-lane-result.sh: 単一の成功タスクは exit 0（#156）" 0 "$H156_EXIT_1"
assert_eq "format-lane-result.sh: 単一の成功タスクの表示（#156）" "A=#5(12:03-12:11 8m00s)" "$H156_OUT_1"

# --- ケース2: 同一レーンで複数タスク（1件失敗）を連続処理した場合、時刻区間は通しで、
#     duration_secは合算し、失敗タスクには (失敗) を付記する ---
H156_EV_A2="$(mktemp "${TMPDIR:-/tmp}/dw-lane-evidence.XXXXXX")"
cat > "$H156_EV_A2" <<'FIXTURE'
== dummy test output ==
---
task=11
lane=A
status=fail
start_epoch=1481
end_epoch=1721
start_hm=12:11
end_hm=12:16
duration_sec=240
skips=unknown
runner=unknown
pattern=none
FIXTURE

H156_OUT_2="$(bash "$FORMAT_LANE_RESULT_SCRIPT" --lane A --file "$H156_EV_A1" --file "$H156_EV_A2")"
assert_eq "format-lane-result.sh: 連続処理（成功+失敗）の表示（#156）" \
  "A=#5,#11(失敗)(12:03-12:16 12m00s)" "$H156_OUT_2"

# --- ケース3: start_hm/end_hm を持たない証跡ファイルは時刻区間を省略する ---
H156_EV_NOHM="$(mktemp "${TMPDIR:-/tmp}/dw-lane-evidence.XXXXXX")"
cat > "$H156_EV_NOHM" <<'FIXTURE'
task=20
lane=C
status=success
duration_sec=60
FIXTURE

assert_eq "format-lane-result.sh: start_hm/end_hm欠落時は時刻区間を省略する（#156）" \
  "C=#20(1m00s)" "$(bash "$FORMAT_LANE_RESULT_SCRIPT" --lane C --file "$H156_EV_NOHM")"

# --- ケース4: 証跡ファイルが存在しない場合は exit 2 で fail loud（黙って進めない） ---
bash "$FORMAT_LANE_RESULT_SCRIPT" --lane B --file "${TMPDIR:-/tmp}/dw-test-nonexistent-evidence-156" \
  >/dev/null 2>/dev/null
H156_MISSING_EXIT=$?
assert_exit_code "format-lane-result.sh: 証跡ファイルが無い場合は exit 2（#156）" 2 "$H156_MISSING_EXIT"

# --- ケース5: 必須フィールド（task=/status=/duration_sec=）欠落は exit 2 ---
H156_EV_BROKEN="$(mktemp "${TMPDIR:-/tmp}/dw-lane-evidence.XXXXXX")"
cat > "$H156_EV_BROKEN" <<'FIXTURE'
lane=A
status=success
FIXTURE
bash "$FORMAT_LANE_RESULT_SCRIPT" --lane A --file "$H156_EV_BROKEN" >/dev/null 2>/dev/null
assert_exit_code "format-lane-result.sh: 必須フィールド欠落は exit 2（#156）" 2 "$?"

# --- ケース6: --lane / --file が無い場合は exit 2（引数エラー） ---
bash "$FORMAT_LANE_RESULT_SCRIPT" >/dev/null 2>/dev/null
assert_exit_code "format-lane-result.sh: --lane 省略は exit 2（#156）" 2 "$?"
bash "$FORMAT_LANE_RESULT_SCRIPT" --lane A >/dev/null 2>/dev/null
assert_exit_code "format-lane-result.sh: --file 省略は exit 2（#156）" 2 "$?"

# --- core/roles/generator.md: 完了報告がタスク1件につき1行（5項目）になっている ---
H156_GEN_ROLE="${REPO_ROOT}/core/roles/generator.md"
H156_GEN_REPORT="$(awk '/^## 完了報告/{f=1} f' "$H156_GEN_ROLE")"
case "$H156_GEN_REPORT" in
  *'証跡はファイルに書き出し'*'パスと1行の判定だけを載せる'*)
    pass "core/roles/generator.md: 完了報告が『証跡はファイル・報告は1行』の方針になっている（#156）" ;;
  *)
    fail "core/roles/generator.md: 完了報告が『証跡はファイル・報告は1行』の方針になっている（#156）" \
      "$H156_GEN_REPORT" ;;
esac

case "$H156_GEN_REPORT" in
  *'タスク番号'*'成功・見送り'*'SKIP件数'*'所要秒数'*'証跡ファイルのパス'*)
    pass "core/roles/generator.md: 報告1行の必須5項目（タスク番号/成功・見送り/SKIP件数/所要秒数/証跡ファイルのパス）が明記されている（#156）" ;;
  *)
    fail "core/roles/generator.md: 報告1行の必須5項目が明記されている（#156）" "$H156_GEN_REPORT" ;;
esac

if grep -Fq 'dw-lane-evidence.XXXXXX' "$H156_GEN_ROLE"; then
  pass "core/roles/generator.md: 証跡ファイルの命名規則が #145 の dw-lane-* 系列に揃っている（#156）"
else
  fail "core/roles/generator.md: 証跡ファイルの命名規則が #145 の dw-lane-* 系列に揃っている（#156）" \
    "dw-lane-evidence.XXXXXX が見つからない"
fi

if grep -Fq '${TMPDIR:-/tmp}' "$H156_GEN_ROLE"; then
  pass "core/roles/generator.md: 証跡ファイルが \${TMPDIR:-/tmp}（リポジトリ外）に置かれる（#156）"
else
  fail "core/roles/generator.md: 証跡ファイルが \${TMPDIR:-/tmp}（リポジトリ外）に置かれる（#156）" "見つからない"
fi

# --- 完了報告の節から「実出力を貼ること」という旧来の要求が消えている ---
H156_GEN_REPORT_OLD_STRICT="$(printf '%s\n' "$H156_GEN_REPORT" | grep -c '実出力を貼る\|実出力をそのまま報告に貼る' || true)"
assert_eq "core/roles/generator.md: 完了報告節に『実出力を貼る』という旧来の要求が残っていない（#156）" \
  "0" "$H156_GEN_REPORT_OLD_STRICT"

# --- skills/run/SKILL.md (+ references) Step 3: 1行報告・証跡ファイル・5項目の要求がある ---
H156_RS_STEP3="$(awk '/^### Step 3:/{f=1} /^### Step 4:/{f=0} f' "$RUN_SKILL_FLAT")"
case "$H156_RS_STEP3" in
  *'証跡はファイルに書き出し'*'パスと1行の判定だけを載せる'*)
    pass "SKILL.md Step 3: レーンプロンプトが『証跡はファイル・報告は1行』の方針を要求している（#156）" ;;
  *)
    fail "SKILL.md Step 3: レーンプロンプトが『証跡はファイル・報告は1行』の方針を要求している（#156）" \
      "$H156_RS_STEP3" ;;
esac

case "$H156_RS_STEP3" in
  *'タスク番号'*'成功・見送り'*'SKIP件数'*'所要秒数'*'証跡ファイルのパス'*)
    pass "SKILL.md Step 3: 報告1行の必須5項目が明記されている（#156）" ;;
  *)
    fail "SKILL.md Step 3: 報告1行の必須5項目が明記されている（#156）" "$H156_RS_STEP3" ;;
esac

if grep -Fq 'dw-lane-evidence.XXXXXX' "${REPO_ROOT}/skills/run/SKILL.md"; then
  pass "skills/run/SKILL.md: 証跡ファイルの命名規則が #145 の dw-lane-* 系列に揃っている（#156）"
else
  fail "skills/run/SKILL.md: 証跡ファイルの命名規則が #145 の dw-lane-* 系列に揃っている（#156）" "見つからない"
fi

# --- skills/run/references/progress-display.md: レーン結果の組み立てをスクリプトへ切り出した ---
H156_PROGRESS_DISPLAY="${REPO_ROOT}/skills/run/references/progress-display.md"
if grep -Fq 'format-lane-result.sh' "$H156_PROGRESS_DISPLAY"; then
  pass "progress-display.md: レーン結果の組み立てを scripts/format-lane-result.sh へ切り出している（#156）"
else
  fail "progress-display.md: レーン結果の組み立てを scripts/format-lane-result.sh へ切り出している（#156）" "見つからない"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: Codex 版も同じ方針に揃っている ---
H156_CODEX_SKILL="${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md"
H156_CODEX_STEP3="$(awk '/^### Step 3:/{f=1} /^### Step 4:/{f=0} f' "$H156_CODEX_SKILL")"
case "$H156_CODEX_STEP3" in
  *'証跡はファイルに書き出し'*'パスと1行の判定だけを載せる'*)
    pass "skills-codex SKILL.md Step 3: 『証跡はファイル・報告は1行』の方針を要求している（#156）" ;;
  *)
    fail "skills-codex SKILL.md Step 3: 『証跡はファイル・報告は1行』の方針を要求している（#156）" \
      "$H156_CODEX_STEP3" ;;
esac

case "$H156_CODEX_STEP3" in
  *'タスク番号'*'成功・見送り'*'SKIP件数'*'所要秒数'*'証跡ファイルのパス'*)
    pass "skills-codex SKILL.md Step 3: 報告1行の必須5項目が明記されている（#156）" ;;
  *)
    fail "skills-codex SKILL.md Step 3: 報告1行の必須5項目が明記されている（#156）" "$H156_CODEX_STEP3" ;;
esac

if grep -Fq 'dw-lane-evidence.XXXXXX' "$H156_CODEX_SKILL"; then
  pass "skills-codex SKILL.md: 証跡ファイルの命名規則が #145 の dw-lane-* 系列に揃っている（#156）"
else
  fail "skills-codex SKILL.md: 証跡ファイルの命名規則が #145 の dw-lane-* 系列に揃っている（#156）" "見つからない"
fi

# --- 生成物（agents/*.md・codex-agents/*.toml）が core/ と一致している（build.sh実行済み） ---
H156_BUILD_CLAUDE_CHECK="$(bash "${REPO_ROOT}/adapters/claude/build.sh" --check 2>&1)"
H156_BUILD_CLAUDE_EXIT=$?
if [ "$H156_BUILD_CLAUDE_EXIT" -eq 0 ]; then
  pass "adapters/claude/build.sh --check: agents/ が core/ と一致している（#156）"
else
  fail "adapters/claude/build.sh --check: agents/ が core/ と一致している（#156）" "$H156_BUILD_CLAUDE_CHECK"
fi

H156_BUILD_CODEX_CHECK="$(bash "${REPO_ROOT}/adapters/codex/build.sh" --check 2>&1)"
H156_BUILD_CODEX_EXIT=$?
if [ "$H156_BUILD_CODEX_EXIT" -eq 0 ]; then
  pass "adapters/codex/build.sh --check: codex-agents/ が core/ と一致している（#156）"
else
  fail "adapters/codex/build.sh --check: codex-agents/ が core/ と一致している（#156）" "$H156_BUILD_CODEX_CHECK"
fi

# ---------------------------------------------------------------------------
# Task #155: PostToolUse フックで型/lint エラーを即時差し戻す（scripts/edit-check.sh）
#
# marker-root.sh の解決は DEV_WORKFLOW_MARKER_ROOT で明示指定し、実リポジトリの
# .claude/.dev-workflow-edit-check を汚さない一時ディレクトリへ隔離する。
# ---------------------------------------------------------------------------

echo ""
echo "== 編集時チェック（PostToolUse フック・#155） =="

EDIT_CHECK_SCRIPT="${REPO_ROOT}/scripts/edit-check.sh"
H155_MARKER_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dw-edit-check-marker.XXXXXX")"
H155_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dw-edit-check-work.XXXXXX")"
printf 'package main\n' > "${H155_WORK}/sample.go"
printf 'const x = 1;\n' > "${H155_WORK}/sample.ts"

edit_check_write() {
  # edit_check_write <spec>
  printf '%s\n' "$1" | DEV_WORKFLOW_MARKER_ROOT="$H155_MARKER_ROOT" bash "$EDIT_CHECK_SCRIPT" --write >/dev/null 2>&1
}
edit_check_clear() {
  DEV_WORKFLOW_MARKER_ROOT="$H155_MARKER_ROOT" bash "$EDIT_CHECK_SCRIPT" --clear >/dev/null 2>&1
}
edit_check_run_hook() {
  # edit_check_run_hook <file> [追加の環境変数 VAR=val ...]
  local file="$1"; shift
  printf '{"tool_input":{"file_path":"%s"}}' "$file" \
    | env DEV_WORKFLOW_MARKER_ROOT="$H155_MARKER_ROOT" "$@" bash "$EDIT_CHECK_SCRIPT"
}

# --- ケース1: 節が無い（マーカーファイル未設定）場合は何もしない（exit 0・即座に返る） ---
edit_check_clear
H155_OUT_NOSPEC="$(edit_check_run_hook "${H155_WORK}/sample.go" 2>&1)"
H155_EXIT_NOSPEC=$?
assert_exit_code "edit-check.sh: 節が無ければ exit 0（既存Epicの挙動を変えない）" 0 "$H155_EXIT_NOSPEC"
assert_eq "edit-check.sh: 節が無ければ標準出力・標準エラーとも空" "" "$H155_OUT_NOSPEC"

# --- ケース2: --write でマーカーファイルへ原子的に書き込み、--clear で消える ---
edit_check_write '*.go gofmt -l {file}'
if [ -f "${H155_MARKER_ROOT}/.claude/.dev-workflow-edit-check" ]; then
  pass "edit-check.sh --write: マーカーファイルが作られる"
else
  fail "edit-check.sh --write: マーカーファイルが作られる" "見つからない: ${H155_MARKER_ROOT}/.claude/.dev-workflow-edit-check"
fi

H155_MARKER_CONTENT="$(cat "${H155_MARKER_ROOT}/.claude/.dev-workflow-edit-check" 2>/dev/null)"
assert_eq "edit-check.sh --write: 書き込んだ仕様がそのまま読める" "*.go gofmt -l {file}" "$H155_MARKER_CONTENT"

edit_check_clear
if [ -f "${H155_MARKER_ROOT}/.claude/.dev-workflow-edit-check" ]; then
  fail "edit-check.sh --clear: マーカーファイルが消える（前回Epicの残留防止）" "まだ存在する"
else
  pass "edit-check.sh --clear: マーカーファイルが消える（前回Epicの残留防止）"
fi

# --- ケース3: globに一致し、コマンドが成功（0終了）すれば exit 0（違反なし） ---
edit_check_write '*.go true'
H155_EXIT_OK=$(edit_check_run_hook "${H155_WORK}/sample.go" >/dev/null 2>&1; echo $?)
assert_exit_code "edit-check.sh: チェックが0終了ならexit 0（違反なし）" 0 "$H155_EXIT_OK"

# --- ケース4: globに一致し、コマンドが非0終了（違反）なら Claude 契約で exit 2 + stderr ---
edit_check_write '*.go echo VIOLATION-MARKER >&2; false'
H155_STDERR_VIOLATION="$(edit_check_run_hook "${H155_WORK}/sample.go" 2>&1 1>/dev/null)"
H155_EXIT_VIOLATION=$(edit_check_run_hook "${H155_WORK}/sample.go" >/dev/null 2>&1; echo $?)
assert_exit_code "edit-check.sh: 違反検出時はClaude契約でexit 2" 2 "$H155_EXIT_VIOLATION"
case "$H155_STDERR_VIOLATION" in
  *"sample.go"*"VIOLATION-MARKER"*)
    pass "edit-check.sh: 違反メッセージにコマンド出力と対象ファイルが含まれる" ;;
  *)
    fail "edit-check.sh: 違反メッセージにコマンド出力と対象ファイルが含まれる" "$H155_STDERR_VIOLATION" ;;
esac

# --- ケース5: DEV_WORKFLOW_HOOK_VENDOR=codex では exit 0 + stdout の continue:false JSON ---
H155_STDOUT_CODEX="$(edit_check_run_hook "${H155_WORK}/sample.go" DEV_WORKFLOW_HOOK_VENDOR=codex 2>/dev/null)"
H155_EXIT_CODEX=$(edit_check_run_hook "${H155_WORK}/sample.go" DEV_WORKFLOW_HOOK_VENDOR=codex >/dev/null 2>&1; echo $?)
assert_exit_code "edit-check.sh: Codex契約はexit 0（JSONで通知）" 0 "$H155_EXIT_CODEX"
case "$H155_STDOUT_CODEX" in
  *'"continue":false'*'VIOLATION-MARKER'*)
    pass "edit-check.sh: Codex契約のJSONにcontinue:falseと違反内容が含まれる" ;;
  *)
    fail "edit-check.sh: Codex契約のJSONにcontinue:falseと違反内容が含まれる" "$H155_STDOUT_CODEX" ;;
esac

# --- ケース6: DEV_WORKFLOW_HOOK_VENDOR=exit-code では exit 1 + stderr（pre-commit想定） ---
H155_EXIT_PRECOMMIT=$(edit_check_run_hook "${H155_WORK}/sample.go" DEV_WORKFLOW_HOOK_VENDOR=exit-code >/dev/null 2>&1; echo $?)
assert_exit_code "edit-check.sh: exit-code契約（pre-commit）はexit 1" 1 "$H155_EXIT_PRECOMMIT"

# --- ケース7: コマンド不在はフック自体のエラーとしてブロックしない（exit 0） ---
edit_check_write '*.go dw-edit-check-nonexistent-command-xyz {file}'
H155_EXIT_NOTFOUND=$(edit_check_run_hook "${H155_WORK}/sample.go" >/dev/null 2>&1; echo $?)
assert_exit_code "edit-check.sh: コマンド不在はブロックしない（exit 0）" 0 "$H155_EXIT_NOTFOUND"

# --- ケース8: タイムアウトはフック自体のエラーとしてブロックしない（exit 0） ---
edit_check_write '*.go sleep 5'
H155_EXIT_TIMEOUT=$(edit_check_run_hook "${H155_WORK}/sample.go" DEV_WORKFLOW_EDIT_CHECK_TIMEOUT=1 >/dev/null 2>&1; echo $?)
assert_exit_code "edit-check.sh: タイムアウトはブロックしない（exit 0）" 0 "$H155_EXIT_TIMEOUT"

# --- ケース9: 一致するglob行が無ければ何もしない（他ファイル種別のチェックコマンドは走らない） ---
edit_check_write '*.go echo SHOULD-NOT-RUN >&2; false'
H155_EXIT_NOMATCH=$(edit_check_run_hook "${H155_WORK}/sample.ts" >/dev/null 2>&1; echo $?)
assert_exit_code "edit-check.sh: 一致するglobが無ければexit 0（他ファイル種別には影響しない）" 0 "$H155_EXIT_NOMATCH"

# --- ケース10: DEV_WORKFLOW_EDIT_CHECK 環境変数はマーカーファイルより優先する ---
edit_check_write '*.go true'
H155_EXIT_ENV_OVERRIDE=$(printf '{"tool_input":{"file_path":"%s"}}' "${H155_WORK}/sample.go" \
  | DEV_WORKFLOW_MARKER_ROOT="$H155_MARKER_ROOT" DEV_WORKFLOW_EDIT_CHECK='*.go false' bash "$EDIT_CHECK_SCRIPT" \
  >/dev/null 2>&1; echo $?)
assert_exit_code "edit-check.sh: DEV_WORKFLOW_EDIT_CHECK環境変数がマーカーファイルより優先する" 2 "$H155_EXIT_ENV_OVERRIDE"

# --- ケース11: 即座に成功するチェックはタイムアウト秒数未満で返る（#158の回帰検出） ---
#
# run_with_timeout の監視用サブシェル ( sleep "$secs"; kill ... ) が、成功パスでも
# 標準出力をコマンド置換のパイプに残したまま孤児化し、EOF待ちで常にタイムアウト秒数ぶん
# ブロックしていたバグ（レビュー#158）。従来のケース3（終了コードのみ検証）はこの遅延を
# 検出できなかったため、所要時間そのものを assert する。DEV_WORKFLOW_EDIT_CHECK_TIMEOUT=10
# を指定し、経過が3秒未満（十分に10秒を下回る）であることを確認する。
edit_check_write '*.go true'
H158_START="$(date +%s)"
edit_check_run_hook "${H155_WORK}/sample.go" DEV_WORKFLOW_EDIT_CHECK_TIMEOUT=10 >/dev/null 2>&1
H158_END="$(date +%s)"
H158_ELAPSED=$((H158_END - H158_START))
if [ "$H158_ELAPSED" -lt 3 ]; then
  pass "edit-check.sh: 即座に成功するチェックはタイムアウト秒数（10秒）未満で返る（実測${H158_ELAPSED}秒・#158）"
else
  fail "edit-check.sh: 即座に成功するチェックはタイムアウト秒数（10秒）未満で返る（実測${H158_ELAPSED}秒・#158）" \
    "監視用サブシェルがパイプの書き込み端を保持し続けタイムアウト秒数ぶんブロックしていないか確認すること"
fi

edit_check_clear

# --- ケース12: ヘッダコメントの仕様例に gofmt -l {file} 単体（終了コード常に0のアンチパターン）が
#     残っていない（#168。#165でcore/roles/planner.md・README.mdは差し替え済みだったが、
#     仕様書式の一次資料であるこのヘッダだけ取りこぼしていた） ---
H168_BARE_GOFMT="$(grep -Fn 'gofmt -l {file}' "${EDIT_CHECK_SCRIPT}" | grep -v 'test -z')"
if [ -n "$H168_BARE_GOFMT" ]; then
  fail "edit-check.sh: ヘッダの仕様例に終了コード常に0のgofmt -l {file}単体が残っていない（#168）" \
    "$H168_BARE_GOFMT"
else
  pass "edit-check.sh: ヘッダの仕様例に終了コード常に0のgofmt -l {file}単体が残っていない（#168）"
fi

if grep -Fq 'test -z "$(gofmt -l {file})"' "${EDIT_CHECK_SCRIPT}"; then
  pass "edit-check.sh: ヘッダの仕様例が終了コードで違反を表現する形（test -z \"\$(gofmt -l {file})\"）になっている（#168）"
else
  fail "edit-check.sh: ヘッダの仕様例が終了コードで違反を表現する形（test -z \"\$(gofmt -l {file})\"）になっている（#168）" \
    "$(sed -n '25,40p' "${EDIT_CHECK_SCRIPT}")"
fi

# --- hooks.json: PostToolUse(Write|Edit|MultiEdit) に edit-check.sh が結線され、
#     既存のcheck-readability.shと共存し、タイムアウトが設定されている ---
HJ_POSTTOOLUSE_WEM="$(_hj_extract_section "$HJ_HOOKS_JSON" "PostToolUse")"
if printf '%s' "$HJ_POSTTOOLUSE_WEM" | grep -Fq '"matcher": "Write|Edit|MultiEdit"' \
  && printf '%s' "$HJ_POSTTOOLUSE_WEM" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/edit-check.sh\"' \
  && printf '%s' "$HJ_POSTTOOLUSE_WEM" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/check-readability.sh\"'; then
  pass "hooks.json: PostToolUse(Write|Edit|MultiEdit)にedit-check.shが結線され、check-readability.shと共存している（#155）"
else
  fail "hooks.json: PostToolUse(Write|Edit|MultiEdit)にedit-check.shが結線され、check-readability.shと共存している（#155）" \
    "$HJ_POSTTOOLUSE_WEM"
fi

if printf '%s' "$HJ_POSTTOOLUSE_WEM" | grep -A2 'edit-check.sh' | grep -Eq '"timeout": [0-9]+'; then
  pass "hooks.json: edit-check.shにtimeoutが設定されている（#155）"
else
  fail "hooks.json: edit-check.shにtimeoutが設定されている（#155）" "$HJ_POSTTOOLUSE_WEM"
fi

# --- hooks.codex.json: 同様にedit-check.shが結線され、タイムアウトが設定されている ---
HJ_CODEX_POSTTOOLUSE_WEM="$(_hj_extract_section "$HJ_HOOKS_CODEX_JSON" "PostToolUse")"
if printf '%s' "$HJ_CODEX_POSTTOOLUSE_WEM" | grep -Fq '"matcher": "Write|Edit|MultiEdit|apply_patch"' \
  && printf '%s' "$HJ_CODEX_POSTTOOLUSE_WEM" | grep -Fq 'bash \"${CLAUDE_PLUGIN_ROOT}/scripts/edit-check.sh\"'; then
  pass "hooks.codex.json: PostToolUse(Write|Edit|MultiEdit|apply_patch)にedit-check.shが結線されている（#155）"
else
  fail "hooks.codex.json: PostToolUse(Write|Edit|MultiEdit|apply_patch)にedit-check.shが結線されている（#155）" \
    "$HJ_CODEX_POSTTOOLUSE_WEM"
fi

if printf '%s' "$HJ_CODEX_POSTTOOLUSE_WEM" | grep -A2 'edit-check.sh' | grep -Eq '"timeout": [0-9]+'; then
  pass "hooks.codex.json: edit-check.shにtimeoutが設定されている（#155）"
else
  fail "hooks.codex.json: edit-check.shにtimeoutが設定されている（#155）" "$HJ_CODEX_POSTTOOLUSE_WEM"
fi

# --- core/instructions.md（+ core/references/）: 4つの任意節と編集時チェック節の説明がある ---
if grep -Fq '4つの任意節' "${REPO_ROOT}/core/instructions.md"; then
  pass "core/instructions.md: 任意節が4つ（編集時チェックを含む）に更新されている（#155）"
else
  fail "core/instructions.md: 任意節が4つ（編集時チェックを含む）に更新されている（#155）" "見つからない"
fi

if grep -Fq '## 編集時チェック' "$CORE_INSTRUCTIONS_FLAT"; then
  pass "core/instructions.md（+references）: 編集時チェック節の説明がある（#155）"
else
  fail "core/instructions.md（+references）: 編集時チェック節の説明がある（#155）" "見つからない"
fi

# --- README.md: 編集時チェック節の説明がある ---
if grep -Fq '## 編集時チェック' "${REPO_ROOT}/README.md" && grep -Fq 'edit-check.sh' "${REPO_ROOT}/README.md"; then
  pass "README.md: Epicの『## 編集時チェック』節の説明がある（#155）"
else
  fail "README.md: Epicの『## 編集時チェック』節の説明がある（#155）" "見つからない"
fi

# --- core/roles/planner.md: 編集時チェック節を書くかどうかの判断が明記されている ---
if grep -Fq '編集時チェック（該当する場合のみ）' "${REPO_ROOT}/core/roles/planner.md"; then
  pass "core/roles/planner.md: 編集時チェック節を書くかどうかの判断が明記されている（#155）"
else
  fail "core/roles/planner.md: 編集時チェック節を書くかどうかの判断が明記されている（#155）" "見つからない"
fi

# --- ADR 0005 が存在し、ホスト側実行の判断根拠が書かれている ---
H155_ADR="${REPO_ROOT}/docs/adr/0005-edit-time-check-hook.md"
if [ -f "$H155_ADR" ]; then
  pass "docs/adr/0005-edit-time-check-hook.md: 存在する（#155）"
else
  fail "docs/adr/0005-edit-time-check-hook.md: 存在する（#155）" "見つからない"
fi

if grep -Fq 'ホスト側' "$H155_ADR" 2>/dev/null && grep -Fq 'コンテナ経由' "$H155_ADR" 2>/dev/null; then
  pass "ADR 0005: ホスト側実行かコンテナ経由かの判断が明記されている（#155）"
else
  fail "ADR 0005: ホスト側実行かコンテナ経由かの判断が明記されている（#155）" "見つからない"
fi

# --- skills/run/SKILL.md: 「Epic 本文の任意節を取り込む」ブロックに編集時チェックが追加されている ---
if grep -Fq "EDIT_CHECK=" "${REPO_ROOT}/skills/run/SKILL.md" \
  && grep -Fq 'edit-check.sh" --write' "${REPO_ROOT}/skills/run/SKILL.md" \
  && grep -Fq 'edit-check.sh" --clear' "${REPO_ROOT}/skills/run/SKILL.md"; then
  pass "skills/run/SKILL.md: Epic本文の任意節取り込みブロックにedit-check.shの--write/--clearがある（#155）"
else
  fail "skills/run/SKILL.md: Epic本文の任意節取り込みブロックにedit-check.shの--write/--clearがある（#155）" \
    "見つからない"
fi

# --- skills-codex/dev-workflow-run/SKILL.md: 同様にedit-check.shの結線がある ---
if grep -Fq 'edit-check.sh" --write' "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md" \
  && grep -Fq 'edit-check.sh" --clear' "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: edit-check.shの--write/--clearが結線されている（#155）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: edit-check.shの--write/--clearが結線されている（#155）" \
    "見つからない"
fi

# --- 生成物（agents/*.md・codex-agents/*.toml）が core/ と一致している（build.sh実行済み） ---
H155_BUILD_CLAUDE_CHECK="$(bash "${REPO_ROOT}/adapters/claude/build.sh" --check 2>&1)"
H155_BUILD_CLAUDE_EXIT=$?
if [ "$H155_BUILD_CLAUDE_EXIT" -eq 0 ]; then
  pass "adapters/claude/build.sh --check: agents/ が core/ と一致している（#155）"
else
  fail "adapters/claude/build.sh --check: agents/ が core/ と一致している（#155）" "$H155_BUILD_CLAUDE_CHECK"
fi

H155_BUILD_CODEX_CHECK="$(bash "${REPO_ROOT}/adapters/codex/build.sh" --check 2>&1)"
H155_BUILD_CODEX_EXIT=$?
if [ "$H155_BUILD_CODEX_EXIT" -eq 0 ]; then
  pass "adapters/codex/build.sh --check: codex-agents/ が core/ と一致している（#155）"
else
  fail "adapters/codex/build.sh --check: codex-agents/ が core/ と一致している（#155）" "$H155_BUILD_CODEX_CHECK"
fi

# ---------------------------------------------------------------------------
# Task #152: 全系統の整合を取り、ADR 索引と生成物・全テストを最終確認する
# ---------------------------------------------------------------------------

echo ""
echo "== Task #152: ADR索引と、スコープ外項目に変更が入っていないことの確認 =="

# --- docs/adr/README.md が存在し、6件のADRを全て索引している ---
H152_ADR_INDEX="${REPO_ROOT}/docs/adr/README.md"
if [ -f "$H152_ADR_INDEX" ]; then
  pass "docs/adr/README.md が新規作成されている（#152）"
else
  fail "docs/adr/README.md が新規作成されている（#152）" "ファイルが存在しません"
fi

H152_ADR_INDEX_BODY="$(cat "$H152_ADR_INDEX" 2>/dev/null)"
for h152_adr_file in \
  "0001-integration-gate-at-epic-end.md" \
  "0002-sandbox-overhead-reduction.md" \
  "0003-parallel-review-by-focus.md" \
  "0004-cross-wave-lane-reuse.md" \
  "0005-edit-time-check-hook.md" \
  "0006-evaluator-model-split.md"; do
  if printf '%s\n' "$H152_ADR_INDEX_BODY" | grep -Fq "$h152_adr_file"; then
    pass "docs/adr/README.md: ${h152_adr_file} を索引している（#152）"
  else
    fail "docs/adr/README.md: ${h152_adr_file} を索引している（#152）" "見つかりません"
  fi
done

# --- docs/adr/README.md の冒頭に「ADRは設計判断の記録、使い方はREADMEに書く」旨の明示がある ---
case "$H152_ADR_INDEX_BODY" in
  *'ADR は設計判断の記録であり、使い方の説明は README に書く'*)
    pass "docs/adr/README.md: 冒頭にADRの役割の明示がある（#152）" ;;
  *)
    fail "docs/adr/README.md: 冒頭にADRの役割の明示がある（#152）" "$H152_ADR_INDEX_BODY" ;;
esac

# --- README.md から2軸（直列区間とプロンプト量の削減／推論ターン数と出力トークン量の削減）が読み取れる ---
case "$(cat "${REPO_ROOT}/README.md")" in
  *'直列区間とプロンプト量の削減'*'推論ターン数と出力トークン量の削減'*)
    pass "README.md: Epic #143 の2軸（直列区間・プロンプト量／推論ターン数・出力トークン量）が明記されている（#152）" ;;
  *)
    fail "README.md: Epic #143 の2軸（直列区間・プロンプト量／推論ターン数・出力トークン量）が明記されている（#152）" \
      "見つかりません" ;;
esac

# --- 「機械的ゲートの二段構成」という古い呼称（#144で三段構成へ改称後の残存）が消えている ---
for h152_f2 in "skills/run/SKILL.md" "core/roles/generator.md" "core/instructions.md" "README.md"; do
  if grep -Fq '機械的ゲートの二段構成' "${REPO_ROOT}/${h152_f2}"; then
    fail "${h152_f2}: 『機械的ゲートの二段構成』という古い呼称が残っていない（三段構成への統一・#152）" \
      "$(grep -n '機械的ゲートの二段構成' "${REPO_ROOT}/${h152_f2}")"
  else
    pass "${h152_f2}: 『機械的ゲートの二段構成』という古い呼称が残っていない（三段構成への統一・#152）"
  fi
done

# --- README.md: wave-reviewが「evaluator側の契約が用意されているだけ」という
#     Task #147時点の古い記述のまま残っていない（#148/#149で実際に呼び出しが結線された） ---
if grep -Fq '現時点では evaluator 側の契約' "${REPO_ROOT}/README.md"; then
  fail "README.md: wave-reviewの呼び出しが既に結線されている旨に更新されている（#152）" \
    "$(grep -n '現時点では evaluator 側の契約' "${REPO_ROOT}/README.md")"
else
  pass "README.md: wave-reviewの呼び出しが既に結線されている旨に更新されている（#152）"
fi
if grep -Fq '呼び出しは Step 3（レーン起動と同一メッセージ）で行う' "${REPO_ROOT}/README.md"; then
  pass "README.md: wave-reviewの実際の呼び出しタイミング（Step 3・レーン起動と同一メッセージ）が明記されている（#152）"
else
  fail "README.md: wave-reviewの実際の呼び出しタイミング（Step 3・レーン起動と同一メッセージ）が明記されている（#152）" \
    "見つかりません"
fi

# --- README.md: Epic本文の任意節（4種）が1か所の一覧にまとまっている ---
H152_EPIC_SECTIONS="$(awk '/^### Epic 本文の任意節（一覧）/{f=1} /^### Epic の `## 準備コマンド`/{f=0} f' "${REPO_ROOT}/README.md")"
case "$H152_EPIC_SECTIONS" in
  *'## 準備コマンド'*'## 共有ディレクトリ'*'## SKIPパターン'*'## 編集時チェック'*)
    pass "README.md: Epic本文の任意節4種が1か所の一覧にまとまっている（#152）" ;;
  *)
    fail "README.md: Epic本文の任意節4種が1か所の一覧にまとまっている（#152）" "$H152_EPIC_SECTIONS" ;;
esac

# --- README.md に「ウェーブごとに全テストを走らせる」旨の記述が残っていない ---
if grep -Fq 'ウェーブごとに全テストを走らせる' "${REPO_ROOT}/README.md"; then
  fail "README.md: 『ウェーブごとに全テストを走らせる』旨の記述が残っていない（完了条件・#152）" \
    "$(grep -n 'ウェーブごとに全テストを走らせる' "${REPO_ROOT}/README.md")"
else
  pass "README.md: 『ウェーブごとに全テストを走らせる』旨の記述が残っていない（完了条件・#152）"
fi

# --- D. スコープ外と宣言した項目に変更が入っていないことの確認 ---

# --- sandbox-exec.sh の CLI契約（--epic/--warm/--down/--ls/--reset-cache/--rebuild/--print-plan）が維持されている ---
H152_SANDBOX="${REPO_ROOT}/scripts/sandbox-exec.sh"
H152_SANDBOX_MISSING=""
for h152_flag in "--epic" "--warm" "--down" "--ls" "--reset-cache" "--rebuild" "--print-plan"; do
  if ! grep -Fq -- "$h152_flag" "$H152_SANDBOX"; then
    H152_SANDBOX_MISSING="${H152_SANDBOX_MISSING} ${h152_flag}"
  fi
done
if [ -z "$H152_SANDBOX_MISSING" ]; then
  pass "scripts/sandbox-exec.sh: CLI契約（--epic/--warm/--down/--ls/--reset-cache/--rebuild/--print-plan）が維持されている（#152）"
else
  fail "scripts/sandbox-exec.sh: CLI契約（--epic/--warm/--down/--ls/--reset-cache/--rebuild/--print-plan）が維持されている（#152）" \
    "欠落:${H152_SANDBOX_MISSING}"
fi

# --- --lanes の既定値が3のままである ---
if grep -Fq '既定は **3**' "${REPO_ROOT}/README.md"; then
  pass "README.md: --lanes の既定値が3のままである（#152）"
else
  fail "README.md: --lanes の既定値が3のままである（#152）" "見つかりません"
fi

# --- merge-lane.sh のmerge-base検証があり、cherry-pickによる載せ替えを行っていない ---
H152_MERGE_LANE="${REPO_ROOT}/scripts/merge-lane.sh"
if grep -Fq 'merge-base' "$H152_MERGE_LANE" && grep -Fq 'cherry-pick による載せ替えは行わない' "$H152_MERGE_LANE"; then
  pass "scripts/merge-lane.sh: merge-base検証があり、cherry-pickによる載せ替えを行わない旨が明記されている（#152）"
else
  fail "scripts/merge-lane.sh: merge-base検証があり、cherry-pickによる載せ替えを行わない旨が明記されている（#152）" \
    "$(grep -n 'merge-base\|cherry-pick' "$H152_MERGE_LANE")"
fi

# --- Epicブランチへのforce push禁止がcore/instructions.mdに残っている ---
if grep -Fq 'force push は行わない' "${REPO_ROOT}/core/instructions.md"; then
  pass "core/instructions.md: Epicブランチへのforce push禁止が残っている（#152）"
else
  fail "core/instructions.md: Epicブランチへのforce push禁止が残っている（#152）" "見つかりません"
fi

# --- 生成物（agents/*.md・codex-agents/*.toml）が core/ と一致している（build.sh実行済み） ---
H152_BUILD_CLAUDE_CHECK="$(bash "${REPO_ROOT}/adapters/claude/build.sh" --check 2>&1)"
H152_BUILD_CLAUDE_EXIT=$?
if [ "$H152_BUILD_CLAUDE_EXIT" -eq 0 ]; then
  pass "adapters/claude/build.sh --check: agents/ が core/ と一致している（#152）"
else
  fail "adapters/claude/build.sh --check: agents/ が core/ と一致している（#152）" "$H152_BUILD_CLAUDE_CHECK"
fi

H152_BUILD_CODEX_CHECK="$(bash "${REPO_ROOT}/adapters/codex/build.sh" --check 2>&1)"
H152_BUILD_CODEX_EXIT=$?
if [ "$H152_BUILD_CODEX_EXIT" -eq 0 ]; then
  pass "adapters/codex/build.sh --check: codex-agents/ が core/ と一致している（#152）"
else
  fail "adapters/codex/build.sh --check: codex-agents/ が core/ と一致している（#152）" "$H152_BUILD_CODEX_CHECK"
fi

# --- タスク見送り時の作業ツリー復旧が git reset --hard HEAD のまま残っていない（#161, #169） ---
# skills/run/SKILL.md は #161 の当初ループに含まれておらず、実際にここで取りこぼしが発生した
# （コミット c6f6969 で後追い修正。#169）。以降の回帰を検出できるよう対象に加える。
for H161_FILE in "core/roles/generator.md" "README.md" "skills/run/SKILL.md" \
  "skills-codex/dev-workflow-run/SKILL.md" "agents/generator.md" "codex-agents/generator.toml"; do
  case "$H161_FILE" in
    skills/run/SKILL.md) H161_PATH="$RUN_SKILL_FLAT" ;;
    *)                   H161_PATH="${REPO_ROOT}/${H161_FILE}" ;;
  esac
  if grep -Fq 'git reset --hard HEAD' "$H161_PATH"; then
    fail "${H161_FILE}: 見送り時の作業ツリー復旧に git reset --hard HEAD が残っていない（#161）" \
      "$(grep -n 'git reset --hard HEAD' "$H161_PATH")"
  else
    pass "${H161_FILE}: 見送り時の作業ツリー復旧に git reset --hard HEAD が残っていない（#161）"
  fi
done

# --- タスク見送り時の作業ツリー復旧が非破壊手順（git restore + git status --short）に
#     置き換わっている（#161, #169, #140） ---
# -- :/ が付いていることも要求する（#167: pathspec省略はcwd相対になり、サブディレクトリから
# 実行するとリポジトリ他所の変更・未追跡ファイルが戻らない／報告されないまま
# 「残留なし」という誤った証跡が残るため）
# skills/run/SKILL.md も対象に加える（#169。実際に取りこぼしが起きたのはこのファイル）
# `git clean -nd` は dry-run でもコマンド名の前方一致で permissions.deny にブロックされうる
# ため、`git status --short` に置き換えた（issue #140、Epic #174 完了基準4）。
# --untracked-files=all が付いていることも要求する（#193: status.showUntrackedFiles=no の
# ローカル設定があると --short の出力が常に空になり、未追跡ファイルが残っていても
# 「残留なし」という誤った証跡が残るため。-uall はこの設定を明示的に上書きする）
for H161_FILE in "core/roles/generator.md" "README.md" "skills/run/SKILL.md" \
  "skills-codex/dev-workflow-run/SKILL.md"; do
  case "$H161_FILE" in
    skills/run/SKILL.md) H161_PATH="$RUN_SKILL_FLAT" ;;
    *)                   H161_PATH="${REPO_ROOT}/${H161_FILE}" ;;
  esac
  if grep -Fq 'git restore --source=HEAD --staged --worktree -- :/' "$H161_PATH" \
    && grep -Fq 'git status --short --untracked-files=all -- :/' "$H161_PATH"; then
    pass "${H161_FILE}: 見送り時の復旧が git restore + git status --short --untracked-files=all -- :/ に置き換わっている（#161, #167, #140, #193）"
  else
    fail "${H161_FILE}: 見送り時の復旧が git restore + git status --short --untracked-files=all -- :/ に置き換わっている（#161, #167, #140, #193）" \
      "$(grep -n 'git restore\|git clean\|git status --short' "$H161_PATH")"
  fi
done

# --- run-loop.sh: set -o pipefail（またはset -uo pipefail）が設定されている（回帰防止 #37, #166） ---
if grep -Eq '^set -[a-zA-Z]*o pipefail\b|^set -o pipefail\b' "${REPO_ROOT}/adapters/codex/run-loop.sh"; then
  pass "run-loop.sh: set -o pipefail（またはset -uo pipefail）が設定されている（#166）"
else
  fail "run-loop.sh: set -o pipefail（またはset -uo pipefail）が設定されている（#166）" \
    "$(grep -n '^set ' "${REPO_ROOT}/adapters/codex/run-loop.sh")"
fi

# --- run-loop.sh: epic_gate()本体がテスト実行の失敗で早期returnする形になっている（静的検証・#166） ---
RL166_EPIC_GATE_BODY_STATIC="$(sed -n '/^epic_gate() {/,/^}/p' "${REPO_ROOT}/adapters/codex/run-loop.sh")"
RL166_EPIC_GATE_ONELINE_STATIC="$(printf '%s' "$RL166_EPIC_GATE_BODY_STATIC" | tr '\n' ' ')"
case "$RL166_EPIC_GATE_ONELINE_STATIC" in
  *'if ! ('*') 2>&1 | tee'*'then'*'return 1'*)
    pass "run-loop.sh: epic_gate()がテスト実行の失敗（パイプライン終端ステータス）で早期returnする形になっている（#166）" ;;
  *)
    fail "run-loop.sh: epic_gate()がテスト実行の失敗（パイプライン終端ステータス）で早期returnする形になっている（#166）" \
      "$RL166_EPIC_GATE_BODY_STATIC" ;;
esac

# --- run-loop.sh: epic_gate()の合否判定がset -o pipefailに依存していることを動的に確認する（#166） ---
# Review #37: mechanical_gate()がテストを走らせず可読性ガードだけ実行していた回帰。#144でepic_gate()に
# 分割された際、「テスト失敗がゲート失敗になること（AND判定）」の検証だけが移植されずに消えていた。
# epic_gate()は `if ! ( ... ) 2>&1 | tee "$log"; then return 1; fi` というパイプライン終端ステータス
# （tee）に依存する形であり、set -o pipefailが外れると無言で通過してしまう。
RL166_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-epicgate.XXXXXX")"
mkdir -p "${RL166_SCRATCH}/scripts"

cat > "${RL166_SCRATCH}/scripts/sandbox-exec.sh" <<'FAKE_SANDBOX_EXEC_166'
#!/bin/bash
echo "fake sandbox-exec.sh: simulated test failure"
exit 1
FAKE_SANDBOX_EXEC_166
chmod +x "${RL166_SCRATCH}/scripts/sandbox-exec.sh"

cat > "${RL166_SCRATCH}/scripts/count-skips.sh" <<'FAKE_COUNT_SKIPS_166'
#!/bin/bash
echo "skips=0"
exit 0
FAKE_COUNT_SKIPS_166
chmod +x "${RL166_SCRATCH}/scripts/count-skips.sh"

cat > "${RL166_SCRATCH}/scripts/check-readability.sh" <<'FAKE_CHECK_READABILITY_166'
#!/bin/bash
exit 0
FAKE_CHECK_READABILITY_166
chmod +x "${RL166_SCRATCH}/scripts/check-readability.sh"

RL166_EPIC_WT="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-epicwt.XXXXXX")"
RL166_EPIC_GATE_FN_BODY="$(sed -n '/^epic_gate() {/,/^}/p' "${REPO_ROOT}/adapters/codex/run-loop.sh")"

# (a) set -o pipefail が有効（本番と同じ）: テスト失敗（fakeなsandbox-exec.shのexit 1）を検知して
#     epic_gate()が非0を返すこと
RL166_WITH_PIPEFAIL_EXIT="$(
  set -o pipefail
  eval "$RL166_EPIC_GATE_FN_BODY"
  DRY_RUN=0
  PLUGIN_ROOT_DIR="$RL166_SCRATCH"
  EPIC_WT="$RL166_EPIC_WT"
  EPIC_NUM="test"
  EPIC_BRANCH="test"
  TEST_CMD="true"
  SKIP_PATTERN=""
  epic_gate >/dev/null 2>&1
  echo $?
)"

if [ "$RL166_WITH_PIPEFAIL_EXIT" != "0" ]; then
  pass "run-loop.sh: set -o pipefail有効時、epic_gate()はテスト失敗を検知して非0を返す（動的検証・回帰防止 #37, #166）"
else
  fail "run-loop.sh: set -o pipefail有効時、epic_gate()はテスト失敗を検知して非0を返す（動的検証・回帰防止 #37, #166）" \
    "exit=${RL166_WITH_PIPEFAIL_EXIT}"
fi

# (b) set -o pipefail が無効: 同じテスト失敗をepic_gate()が検知できず0を返してしまうことを実際に
#     確認する（＝合否判定がset -o pipefailに完全依存していることの証拠。#166が指摘した回帰リスクの再現）
RL166_WITHOUT_PIPEFAIL_EXIT="$(
  set +o pipefail
  eval "$RL166_EPIC_GATE_FN_BODY"
  DRY_RUN=0
  PLUGIN_ROOT_DIR="$RL166_SCRATCH"
  EPIC_WT="$RL166_EPIC_WT"
  EPIC_NUM="test"
  EPIC_BRANCH="test"
  TEST_CMD="true"
  SKIP_PATTERN=""
  epic_gate >/dev/null 2>&1
  echo $?
)"

if [ "$RL166_WITHOUT_PIPEFAIL_EXIT" = "0" ]; then
  pass "run-loop.sh: set -o pipefail無効時にepic_gate()がテスト失敗を無言で見逃すことを再現できる（pipefail依存の証拠・#166）"
else
  fail "run-loop.sh: set -o pipefail無効時にepic_gate()がテスト失敗を無言で見逃すことを再現できる（pipefail依存の証拠・#166）" \
    "exit=${RL166_WITHOUT_PIPEFAIL_EXIT}（0が期待値。0以外はepic_gate()の抽出・スタブ化が想定と異なる）"
fi

# ---------------------------------------------------------------------------
# scripts/feedback-ledger.sh（フィードバック台帳の記録・集計・redact・還流先解決）
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/feedback-ledger.sh（台帳の記録・集計・redact） =="

FL_SCRIPT="${REPO_ROOT}/scripts/feedback-ledger.sh"
FL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-ledger.XXXXXX")"

fl() {
  # fl <引数...>  台帳ディレクトリを一時領域へ固定して feedback-ledger.sh を実行する
  DEV_WORKFLOW_FEEDBACK_DIR="$FL_DIR" bash "$FL_SCRIPT" "$@"
}

# --- 記録と件数 ---

fl record --scope harness --category gate --key gate-flaky --severity high --epic 143 \
  --summary "統合ゲートが誤検知する" --evidence "run.log:gate" >/dev/null 2>&1
FL_RC1=$?
assert_exit_code "record: 正常な引数で記録できる" 0 "$FL_RC1"

fl record --scope harness --category gate --key gate-flaky --severity medium --epic 144 \
  --summary "統合ゲートが誤検知する（2回目）" >/dev/null 2>&1
fl record --scope project --category docs --key project-test-cmd \
  --summary "テストは make test で回す" >/dev/null 2>&1

FL_COUNT_OUT="$(fl count --key gate-flaky)"
assert_eq "count: 同一キーの件数を数える" "count=2" "$(printf '%s\n' "$FL_COUNT_OUT" | head -1)"
assert_eq "count: 既定の昇格閾値は3" "threshold=3" "$(printf '%s\n' "$FL_COUNT_OUT" | tail -1)"

assert_eq "count: 未記録のキーは0件（エラーにしない）" \
  "count=0" "$(fl count --key never-seen | head -1)"

# --- 空フィールドの列ずれ（回帰防止） ---
#
# タブは IFS の「空白」扱いなので、`IFS=$'\t' read` は連続タブを1つに畳む。
# --epic と --evidence を省いた記録を空文字のまま書くと、読み出し時に summary が
# epic の位置に入って列が1つずれる。record 側で `-` を埋めることで防いでいる。

fl record --scope project --category other --key no-optional-fields \
  --summary "省略時でも列がずれない" >/dev/null 2>&1

FL_SHIFT_ROW="$(fl list --key no-optional-fields | head -1)"
assert_eq "list: --epic 省略時は epic 列が - になる（列ずれ回帰防止）" \
  "-" "$(printf '%s\n' "$FL_SHIFT_ROW" | cut -f6)"
assert_eq "list: --epic/--evidence 省略時も summary が正しい列に入る（列ずれ回帰防止）" \
  "省略時でも列がずれない" "$(printf '%s\n' "$FL_SHIFT_ROW" | cut -f7)"
assert_eq "list: --evidence 省略時は evidence 列が - になる（列ずれ回帰防止）" \
  "-" "$(printf '%s\n' "$FL_SHIFT_ROW" | cut -f8)"

# --- ready（昇格閾値の判定） ---

assert_eq "ready: 閾値未満のキーは出力されない" "" "$(fl ready)"

fl record --scope harness --category gate --key gate-flaky --severity low \
  --summary "統合ゲートが誤検知する（3回目）" >/dev/null 2>&1

FL_READY_ROW="$(fl ready | head -1)"
assert_eq "ready: 閾値に達したキーを出力する" "gate-flaky" "$(printf '%s\n' "$FL_READY_ROW" | cut -f1)"
assert_eq "ready: 観測回数を出力する" "3" "$(printf '%s\n' "$FL_READY_ROW" | cut -f2)"
assert_eq "ready: 深刻度は観測の中で最も重いものを採る" "high" "$(printf '%s\n' "$FL_READY_ROW" | cut -f5)"

assert_eq "ready: --scope で絞り込める（project 側は閾値未満）" "" "$(fl ready --scope project)"
assert_eq "ready: --threshold で閾値を下げられる" \
  "project-test-cmd" "$(fl ready --scope project --threshold 1 | head -1 | cut -f1)"

# --- 引数エラー ---

fl record --scope bogus --category gate --key k --summary s >/dev/null 2>&1
assert_exit_code "record: 不正な --scope は exit 2" 2 "$?"

fl record --scope harness --category "Bad Cat" --key k --summary s >/dev/null 2>&1
assert_exit_code "record: スラッグでない --category は exit 2" 2 "$?"

fl record --scope harness --category gate --key "Bad_Key" --summary s >/dev/null 2>&1
assert_exit_code "record: スラッグでない --key は exit 2" 2 "$?"

fl record --scope harness --category gate --key k --severity urgent --summary s >/dev/null 2>&1
assert_exit_code "record: 不正な --severity は exit 2" 2 "$?"

fl record --scope harness --category gate --key k >/dev/null 2>&1
assert_exit_code "record: --summary 欠落は exit 2" 2 "$?"

fl unknown-subcommand >/dev/null 2>&1
assert_exit_code "不明なサブコマンドは exit 2" 2 "$?"

fl render-upstream --key never-seen >/dev/null 2>&1
assert_exit_code "render-upstream: 観測の無いキーは exit 1" 1 "$?"

# --- render-upstream（還流レポートの本文） ---

FL_RENDER="$(fl render-upstream --key gate-flaky)"

case "$FL_RENDER" in
  *"観測回数: 3 回"*) pass "render-upstream: 観測回数を本文に含む" ;;
  *) fail "render-upstream: 観測回数を本文に含む" "$FL_RENDER" ;;
esac

case "$FL_RENDER" in
  *'`gate-flaky`'*) pass "render-upstream: キーを本文に含む（重複issueの検索に使う）" ;;
  *) fail "render-upstream: キーを本文に含む（重複issueの検索に使う）" "$FL_RENDER" ;;
esac

case "$FL_RENDER" in
  *"| 143 |"*) pass "render-upstream: 観測ログの表に Epic 番号が入る" ;;
  *) fail "render-upstream: 観測ログの表に Epic 番号が入る" "$FL_RENDER" ;;
esac

# --- redact（機械的な伏字化） ---

fl_redact() {
  # fl_redact <入力文字列>  HOME とユーザー名を固定して redact を適用する
  printf '%s\n' "$1" | HOME="/home/tester" USER="tester" \
    DEV_WORKFLOW_FEEDBACK_DIR="$FL_DIR" bash "$FL_SCRIPT" redact
}

assert_eq "redact: GitHub の Personal Access Token を伏せる" \
  "token=<secret>" "$(fl_redact 'token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ01')"
assert_eq "redact: github_pat 形式のトークンを伏せる" \
  "token=<secret>" "$(fl_redact 'token=github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ')"
assert_eq "redact: Slack のトークンを伏せる" \
  "token=<secret>" "$(fl_redact 'token=xoxb-1234567890-abcdefghij')"
assert_eq "redact: Slack の Webhook URL を伏せる" \
  "url=<slack-webhook>" "$(fl_redact 'url=https://hooks.slack.com/services/T000/B000/XXXXXXXX')"
assert_eq "redact: メールアドレスを伏せる" \
  "to=<email>" "$(fl_redact 'to=foo.bar+baz@example.co.jp')"
assert_eq "redact: POSIX のホームディレクトリを伏せる" \
  "p=<home>/work" "$(fl_redact 'p=/home/alice/work')"
assert_eq "redact: macOS のホームディレクトリを伏せる" \
  "p=<home>/work" "$(fl_redact 'p=/Users/alice/work')"
assert_eq "redact: Git Bash 形式（/c/Users/...）のホームディレクトリを伏せる" \
  "p=<home>/work" "$(fl_redact 'p=/c/Users/alice/work')"
assert_eq "redact: Windows 形式（C:/Users/...）のホームディレクトリを伏せる" \
  "p=<home>/work" "$(fl_redact 'p=C:/Users/alice/work')"
assert_eq "redact: \$HOME に一致する文字列を伏せる" \
  "p=<home>/x" "$(fl_redact 'p=/home/tester/x')"
assert_eq "redact: ユーザー名を伏せる" \
  "user=<user>" "$(fl_redact 'user=tester')"

# 駆動先が dev-workflow 自身のときにリポジトリ名まで伏せると、還流レポートが読めなくなる。
FL_SELF_REDACT="$(printf 'plugin=dev-workflow\n' | (cd "$REPO_ROOT" && bash "$FL_SCRIPT" redact))"
assert_eq "redact: リポジトリ名が dev-workflow のときは伏せない（還流レポートが読めなくなるため）" \
  "plugin=dev-workflow" "$FL_SELF_REDACT"

# --- upstream-repo（還流先の解決） ---

assert_eq "upstream-repo: マニフェストの repository から owner/repo を解決する" \
  "masatoImayama/dev-workflow" "$(bash "$FL_SCRIPT" upstream-repo)"

assert_eq "upstream-repo: 環境変数で上書きできる（fork・社内ミラー向け）" \
  "acme/dev-workflow-fork" \
  "$(DEV_WORKFLOW_UPSTREAM_REPO="acme/dev-workflow-fork" bash "$FL_SCRIPT" upstream-repo)"

# --- 台帳の置き場所（ハーネス非注入原則の回帰防止） ---
#
# 台帳を駆動先リポジトリの中に作ってしまうと、業務リポジトリのコミット候補に
# ハーネス由来のファイルが混ざる（README「ハーネス非注入原則」）。

FL_HOME_REPO="$(make_temp_repo)"
FL_FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-fbhome.XXXXXX")"
FL_PATH_OUT="$(
  cd "$FL_HOME_REPO" || exit 1
  DEV_WORKFLOW_FEEDBACK_HOME="${FL_FAKE_HOME}/feedback" bash "$FL_SCRIPT" path
)"
assert_eq "path: 台帳は HOME 配下の規約パスに置く（駆動先リポジトリに書き込まない）" \
  "${FL_FAKE_HOME}/feedback/$(basename "$FL_HOME_REPO")" "$FL_PATH_OUT"

case "$FL_PATH_OUT" in
  "${FL_HOME_REPO}"*)
    fail "path: 台帳のパスが駆動先リポジトリの外にある（ハーネス非注入原則）" "$FL_PATH_OUT" ;;
  *)
    pass "path: 台帳のパスが駆動先リポジトリの外にある（ハーネス非注入原則）" ;;
esac

# ---------------------------------------------------------------------------
# scripts/collect-feedback-signals.sh（実行ログの所在と一次集計）
# ---------------------------------------------------------------------------

echo ""
echo "== scripts/collect-feedback-signals.sh（実行ログの所在と一次集計） =="

CFS_SCRIPT="${REPO_ROOT}/scripts/collect-feedback-signals.sh"

bash "$CFS_SCRIPT" --since abc >/dev/null 2>&1
assert_exit_code "--since が数値でなければ exit 2" 2 "$?"

bash "$CFS_SCRIPT" --epic abc >/dev/null 2>&1
assert_exit_code "--epic が数値でなければ exit 2" 2 "$?"

bash "$CFS_SCRIPT" --since >/dev/null 2>&1
assert_exit_code "--since の値が無ければ exit 2" 2 "$?"

bash "$CFS_SCRIPT" --unknown-flag >/dev/null 2>&1
assert_exit_code "不明な引数は exit 2" 2 "$?"

# 一時リポジトリを組み立て、状態ファイルと transcript を仕込んで一次集計を検証する
CFS_REPO="$(make_temp_repo)"
CFS_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-cfs-home.XXXXXX")"
CFS_PROJECTS="${CFS_HOME}/projects"
mkdir -p "${CFS_REPO}/.claude" "$CFS_PROJECTS"

printf 'epic=epic99\nwave=3\nbudget_sec=5400\n' > "${CFS_REPO}/.claude/.dev-workflow-run-state"
printf '%s\tpre\tBash\n' "$(date +%s)" > "${CFS_REPO}/.claude/.dev-workflow-heartbeat"
{
  printf '2026-08-04 15:20:48\ttick\tnow=1\n'
  printf '2026-08-04 15:20:57\tstall\tcount=1\n'
  printf '2026-08-04 15:21:57\tstall\tcount=2\n'
  printf '2026-08-04 15:22:57\tescalate\tlevel=1\n'
  printf '2026-08-04 15:23:57\tinhibit\tos=windows\n'
} > "${CFS_REPO}/.claude/.dev-workflow-watchdog.log"
{
  printf '1785936271\t99\tgenerator\ttask-impl\t1000\t-\n'
  printf '1785936272\t99\tgenerator\ttask-impl\t3000\t-\n'
  printf '1785936273\t98\tevaluator\tepic-review\t5000\t-\n'
} > "${CFS_REPO}/.claude/agent-tokens.tsv"

# transcript は「英数字以外をハイフンに潰した絶対パス」がディレクトリ名になる
CFS_SLUG="$(printf '%s' "$CFS_REPO" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "${CFS_PROJECTS}/${CFS_SLUG}"
printf '{"a":1}\n{"a":2}\n' > "${CFS_PROJECTS}/${CFS_SLUG}/session-a.jsonl"
printf '{"a":1}\n' > "${CFS_PROJECTS}/${CFS_SLUG}/session-b.jsonl"

CFS_OUT="$(
  cd "$CFS_REPO" || exit 1
  DEV_WORKFLOW_MARKER_ROOT="$CFS_REPO" \
  CLAUDE_PROJECTS_DIR="$CFS_PROJECTS" \
  DEV_WORKFLOW_FEEDBACK_DIR="${CFS_HOME}/ledger" \
  bash "$CFS_SCRIPT" --since 3650
)"

assert_eq "run-state を読み出す（中断した run の epic）" \
  "epic99" "$(plan_value runstate.epic "$CFS_OUT")"
assert_eq "run-state が無い場合と区別できるよう available を出す" \
  "1" "$(plan_value runstate.available "$CFS_OUT")"
assert_eq "watchdog: stall の件数を数える" \
  "2" "$(plan_value watchdog.stall_count "$CFS_OUT")"
assert_eq "watchdog: escalate の件数を数える" \
  "1" "$(plan_value watchdog.escalate_count "$CFS_OUT")"
assert_eq "watchdog: abort が無ければ0（無いことを明示する）" \
  "0" "$(plan_value watchdog.abort_count "$CFS_OUT")"
assert_eq "tokens: レコード件数を数える" \
  "3" "$(plan_value tokens.records "$CFS_OUT")"
assert_eq "tokens: role:mode ごとに件数・合計・平均を出す" \
  "count:2,sum:4000,avg:2000" "$(plan_value "tokens.by.generator:task-impl" "$CFS_OUT")"
assert_eq "transcripts: セッションログのディレクトリを解決する" \
  "${CFS_PROJECTS}/${CFS_SLUG}" "$(plan_value transcripts.dir "$CFS_OUT")"
assert_eq "transcripts: 期間内のログを列挙する" \
  "2" "$(plan_value transcripts.listed "$CFS_OUT")"
assert_eq "transcripts: 打ち切っていないことを明示する" \
  "0" "$(plan_value transcripts.truncated "$CFS_OUT")"
assert_eq "repo: 駆動先が dev-workflow 自身かどうかを判定する" \
  "0" "$(plan_value repo.is_dev_workflow "$CFS_OUT")"

# --epic で絞ると、そのEpicのレコードだけが集計対象になる
CFS_OUT_EPIC="$(
  cd "$CFS_REPO" || exit 1
  DEV_WORKFLOW_MARKER_ROOT="$CFS_REPO" \
  CLAUDE_PROJECTS_DIR="$CFS_PROJECTS" \
  DEV_WORKFLOW_FEEDBACK_DIR="${CFS_HOME}/ledger" \
  bash "$CFS_SCRIPT" --since 3650 --epic 99
)"
assert_eq "tokens: --epic で集計対象を絞れる" \
  "2" "$(plan_value tokens.records "$CFS_OUT_EPIC")"

# 上限で打ち切ったことを黙って隠さない（「全部見た」と読める出力を作らない）
CFS_OUT_TRUNC="$(
  cd "$CFS_REPO" || exit 1
  DEV_WORKFLOW_MARKER_ROOT="$CFS_REPO" \
  CLAUDE_PROJECTS_DIR="$CFS_PROJECTS" \
  DEV_WORKFLOW_FEEDBACK_DIR="${CFS_HOME}/ledger" \
  bash "$CFS_SCRIPT" --since 3650 --max-transcripts 1
)"
assert_eq "transcripts: 上限で打ち切ったら truncated=1 を出す" \
  "1" "$(plan_value transcripts.truncated "$CFS_OUT_TRUNC")"
assert_eq "transcripts: 上限で打ち切ったら listed は上限値になる" \
  "1" "$(plan_value transcripts.listed "$CFS_OUT_TRUNC")"

# 状態ファイルが1つも無い環境でも落ちず、available=0 で「無い」ことを明示する
CFS_EMPTY_REPO="$(make_temp_repo)"
CFS_OUT_EMPTY="$(
  cd "$CFS_EMPTY_REPO" || exit 1
  DEV_WORKFLOW_MARKER_ROOT="$CFS_EMPTY_REPO" \
  CLAUDE_PROJECTS_DIR="${CFS_HOME}/nonexistent" \
  DEV_WORKFLOW_FEEDBACK_DIR="${CFS_HOME}/ledger-empty" \
  bash "$CFS_SCRIPT" --since 7
)"
CFS_EMPTY_RC=$?
assert_exit_code "状態ファイルが無くても exit 0（分析側で判断させる）" 0 "$CFS_EMPTY_RC"
assert_eq "状態ファイルが無いことを available=0 で明示する（黙って省略しない）" \
  "0" "$(plan_value runstate.available "$CFS_OUT_EMPTY")"
assert_eq "transcript が無いことを available=0 で明示する" \
  "0" "$(plan_value transcripts.available "$CFS_OUT_EMPTY")"

# ---------------------------------------------------------------------------
# skills/feedback/SKILL.md（修正範囲と承認ゲートの回帰防止）
# ---------------------------------------------------------------------------

echo ""
echo "== skills/feedback/SKILL.md（修正範囲と承認ゲート） =="

FB_SKILL="${REPO_ROOT}/skills/feedback/SKILL.md"
FB_SCOPE_REF="${REPO_ROOT}/skills/feedback/references/scope.md"
FB_UPSTREAM_REF="${REPO_ROOT}/skills/feedback/references/upstream.md"

for f in "$FB_SKILL" "$FB_SCOPE_REF" "$FB_UPSTREAM_REF"; do
  if [ -f "$f" ]; then
    pass "存在する: ${f#"${REPO_ROOT}/"}"
  else
    fail "存在する: ${f#"${REPO_ROOT}/"}" "ファイルが見つかりません"
  fi
done

# SKILL.md 本体 + references を平坦化したビューで内容の有無を問う（run スキルと同じ作法）
FB_FLAT="$(mktemp "${TMPDIR:-/tmp}/dw-feedback-skill-flat.XXXXXX")"
cat "$FB_SKILL" > "$FB_FLAT"
for _fbref in "${REPO_ROOT}"/skills/feedback/references/*.md; do
  [ -f "$_fbref" ] || continue
  printf '\n' >> "$FB_FLAT"
  cat "$_fbref" >> "$FB_FLAT"
done
unset _fbref
FB_FLAT_TEXT="$(cat "$FB_FLAT")"

# プラグイン本体を利用者環境で書き換えると、更新で失われ他の利用者にも届かない。
# 「還流させる」経路が壊れていないことを記述レベルで固定する。
case "$FB_FLAT_TEXT" in
  *'${CLAUDE_PLUGIN_ROOT}'*)
    pass "feedback: プラグイン本体（CLAUDE_PLUGIN_ROOT 配下）への言及がある" ;;
  *)
    fail "feedback: プラグイン本体（CLAUDE_PLUGIN_ROOT 配下）への言及がある" "" ;;
esac

case "$FB_FLAT_TEXT" in
  *"書き換えてはならない"*)
    pass "feedback: 書き換えてはならない対象を明示している（修正範囲の限定）" ;;
  *)
    fail "feedback: 書き換えてはならない対象を明示している（修正範囲の限定）" "" ;;
esac

case "$FB_FLAT_TEXT" in
  *"ハーネス非注入原則"*)
    pass "feedback: ハーネス非注入原則に言及している（駆動先へ書き込まない）" ;;
  *)
    fail "feedback: ハーネス非注入原則に言及している（駆動先へ書き込まない）" "" ;;
esac

case "$FB_FLAT_TEXT" in
  *"承認なしに投稿しない"*)
    pass "feedback: 承認なしに issue を投稿しないと明記している" ;;
  *)
    fail "feedback: 承認なしに issue を投稿しないと明記している" "" ;;
esac

case "$FB_FLAT_TEXT" in
  *"repo.is_dev_workflow"*)
    pass "feedback: 駆動先が dev-workflow 自身のときの例外を扱っている" ;;
  *)
    fail "feedback: 駆動先が dev-workflow 自身のときの例外を扱っている" "" ;;
esac

case "$FB_FLAT_TEXT" in
  *"upstream-repo"*)
    pass "feedback: 還流先をマニフェストから解決する手順がある（fork 配布でも動く）" ;;
  *)
    fail "feedback: 還流先をマニフェストから解決する手順がある（fork 配布でも動く）" "" ;;
esac

case "$FB_FLAT_TEXT" in
  *"投稿しなかったことを"*)
    pass "feedback: 投稿できなかった場合を成功と報告しないと明記している" ;;
  *)
    fail "feedback: 投稿できなかった場合を成功と報告しないと明記している" "" ;;
esac

# 昇格閾値: 1回きりの観測で恒久ルールを書かない仕組みが記述と実装の両方にあること
case "$FB_FLAT_TEXT" in
  *"閾値"*)
    pass "feedback: 昇格閾値の考え方を記述している" ;;
  *)
    fail "feedback: 昇格閾値の考え方を記述している" "" ;;
esac

rm -f "$FB_FLAT"

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: symlink 失敗時のコピー・フォールバック（Task #139）
#
# `ln -s` を人為的に失敗させるため、DEV_WORKFLOW_SANDBOX_EXEC のスタブから呼ばれる
# `sh -c "$cmd"` の PATH に「必ず exit 1 するだけの偽 ln」を割り込ませる。実際の
# Docker には触れず、Windows + Docker Desktop のバインドマウントで報告されている
# `ln -s: Operation not permitted`（issue #139）を model 化したものであり、
# その環境自体を再現するものではない（コメントで明記）。
# ---------------------------------------------------------------------------

echo "== share-prepared-dirs.sh: symlink失敗時のコピー・フォールバック（#139） =="

# 偽binディレクトリを3種用意する。DEV_WORKFLOW_SANDBOX_EXEC のスタブから呼ばれる
# `sh -c "$cmd"` の PATH に割り込ませ、Windows + Docker Desktop のバインドマウントで
# 報告されている `ln -s: Operation not permitted`（issue #139）を model 化する。
# 実際の Docker には触れず、その環境自体を再現するものではない。
#   1. SPD139_FAKEBIN      : 何も作らず exit 1（単純な権限エラーを模す）
#   2. SPD139_FAKEBIN_EMPTY: 対象を「空ディレクトリ」として作ってから exit 1
#                            （issue #139 が報告する「空の実体ディレクトリが副作用として
#                            残る」を model 化）
#   3. SPD139_FAKEBIN_NONEMPTY: 対象を「空でない」ディレクトリとして作ってから exit 1
#                               （中身のあるものには触れないことの防御を検証するため）
SPD139_FAKEBIN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-fakebin.XXXXXX")"
cat > "${SPD139_FAKEBIN}/ln" <<'EOF'
#!/bin/sh
# テスト専用の偽 ln。symlink 作成が失敗する環境（issue #139）を模擬するため、
# 何も作らず必ず exit 1 する。
exit 1
EOF
chmod +x "${SPD139_FAKEBIN}/ln"

SPD139_FAKEBIN_EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-fakebin-empty.XXXXXX")"
cat > "${SPD139_FAKEBIN_EMPTY}/ln" <<'EOF'
#!/bin/sh
# テスト専用の偽 ln。対象（第3引数）を空ディレクトリとして作った直後に失敗する
# Docker Desktop バインドマウントの挙動（issue #139の報告）を模擬する。
mkdir -p "$3" 2>/dev/null
exit 1
EOF
chmod +x "${SPD139_FAKEBIN_EMPTY}/ln"

SPD139_FAKEBIN_NONEMPTY="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-fakebin-nonempty.XXXXXX")"
cat > "${SPD139_FAKEBIN_NONEMPTY}/ln" <<'EOF'
#!/bin/sh
# テスト専用の偽 ln。対象（第3引数）を「空でない」ディレクトリとして作った直後に失敗する。
mkdir -p "$3" 2>/dev/null
echo stray > "$3/stray-leftover.txt" 2>/dev/null
exit 1
EOF
chmod +x "${SPD139_FAKEBIN_NONEMPTY}/ln"

spd139_make_stub() {
  # spd139_make_stub <call_log> <fakebin_dir>  PATH に偽binを割り込ませてから sh -c する
  local call_log="$1" fakebin="$2" stub
  stub="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd139-stub.XXXXXX")"
  {
    echo '#!/bin/bash'
    echo 'set -u'
    printf 'echo 1 >> %q\n' "$call_log"
    printf 'PATH=%q:"$PATH"\n' "$fakebin"
    echo 'cmd="${@: -1}"'
    echo 'sh -c "$cmd"'
  } > "$stub"
  printf '%s' "$stub"
}

SPD139_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd139-calllog.XXXXXX")"
SPD139_STUB="$(spd139_make_stub "$SPD139_CALL_LOG" "$SPD139_FAKEBIN")"
SPD139_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-source.XXXXXX")"
SPD139_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-lane.XXXXXX")"

mkdir -p "${SPD139_SOURCE}/node_modules/.bin"
printf 'pkg-content\n' > "${SPD139_SOURCE}/node_modules/some-pkg.js"

# --- ケース1: 対象が存在しない場合、symlink失敗→コピーで実体が作られ copied になる ---
SPD139_OUT1="$(spd_run "$SPD139_LANE" "$SPD139_STUB" --source "$SPD139_SOURCE" --dir "node_modules")"
SPD139_EXIT1=$?
assert_exit_code "#139 ケース1: symlink失敗でもコピーで成功すれば exit 0" 0 "$SPD139_EXIT1"

case "$SPD139_OUT1" in
  *"copied"*"node_modules"*)
    pass "#139 ケース1: symlink失敗時にコピー・フォールバックで copied が出る" ;;
  *)
    fail "#139 ケース1: symlink失敗時にコピー・フォールバックで copied が出る" "output=[${SPD139_OUT1}]" ;;
esac
case "$SPD139_OUT1" in
  *"prep=skip"*)
    pass "#139 ケース1: copied のみのとき prep=skip" ;;
  *)
    fail "#139 ケース1: copied のみのとき prep=skip" "output=[${SPD139_OUT1}]" ;;
esac
assert_eq "#139 ケース1: コピー先に実ファイルが展開されている（symlinkではない）" \
  "yes" "$([ -f "${SPD139_LANE}/node_modules/some-pkg.js" ] && [ ! -L "${SPD139_LANE}/node_modules" ] && echo yes || echo no)"
assert_eq "#139 ケース1: コピー先の内容がソースと一致する" \
  "yes" "$(cmp -s "${SPD139_SOURCE}/node_modules/some-pkg.js" "${SPD139_LANE}/node_modules/some-pkg.js" && echo yes || echo no)"

# --- ケース2: ln -s 失敗の副作用として「空の」実体ディレクトリが同一呼び出し中に残る場合
#     （issue #139 の報告を model 化。SPD139_FAKEBIN_EMPTY が mkdir してから exit 1 する）
#     → プライマリ呼び出しは link-failed のまま、後続のコピー・フォールバックがその場に
#     内容を展開する（レーン側の <dir> は事前には作らない。副作用として作られる想定） ---
SPD139_STUB_EMPTY="$(spd139_make_stub "$SPD139_CALL_LOG" "$SPD139_FAKEBIN_EMPTY")"
SPD139_LANE2="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-lane2.XXXXXX")"
SPD139_OUT2="$(spd_run "$SPD139_LANE2" "$SPD139_STUB_EMPTY" --source "$SPD139_SOURCE" --dir "node_modules")"
case "$SPD139_OUT2" in
  *"copied"*"node_modules"*)
    pass "#139 ケース2: ln -s失敗の副作用で残る空ディレクトリにもコピーで copied になる" ;;
  *)
    fail "#139 ケース2: ln -s失敗の副作用で残る空ディレクトリにもコピーで copied になる" "output=[${SPD139_OUT2}]" ;;
esac
assert_eq "#139 ケース2: 副作用で残った空ディレクトリに内容が展開される" \
  "yes" "$([ -f "${SPD139_LANE2}/node_modules/some-pkg.js" ] && echo yes || echo no)"

# --- ケース3: ln -s 失敗の副作用として「空でない」実体ディレクトリが残る場合は触れない
#     （データ保護。SPD139_FAKEBIN_NONEMPTY が中身入りで mkdir してから exit 1 する） ---
SPD139_STUB_NONEMPTY="$(spd139_make_stub "$SPD139_CALL_LOG" "$SPD139_FAKEBIN_NONEMPTY")"
SPD139_LANE3="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-lane3.XXXXXX")"
SPD139_OUT3="$(spd_run "$SPD139_LANE3" "$SPD139_STUB_NONEMPTY" --source "$SPD139_SOURCE" --dir "node_modules")"
case "$SPD139_OUT3" in
  *"skip"*"node_modules"*"reason"*"link-failed"*)
    pass "#139 ケース3: 空でない実体ディレクトリには触れず link-failed のまま" ;;
  *)
    fail "#139 ケース3: 空でない実体ディレクトリには触れず link-failed のまま" "output=[${SPD139_OUT3}]" ;;
esac
assert_eq "#139 ケース3: 副作用で残った既存ファイルの内容が変更されていない（データ保護）" \
  "stray" "$(cat "${SPD139_LANE3}/node_modules/stray-leftover.txt" 2>/dev/null)"
assert_eq "#139 ケース3: ソース由来のファイルは持ち込まれない（触れていない証拠）" \
  "no" "$([ -e "${SPD139_LANE3}/node_modules/some-pkg.js" ] && echo yes || echo no)"

# --- ケース4: コピーも失敗する場合（共有元が無い）は copied にならず link-failed/no-source
#     のまま。かつ、コピー失敗時にレーンへ空の実体ディレクトリが残らない ---
SPD139_LANE4="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-lane4.XXXXXX")"
SPD139_OUT4="$(spd_run "$SPD139_LANE4" "$SPD139_STUB" --source "$SPD139_SOURCE" --dir "no_such_dir_139")"
case "$SPD139_OUT4" in
  *"skip"*"no_such_dir_139"*"reason"*"no-source"*)
    pass "#139 ケース4: 共有元が無いエントリはコピー対象にもならず no-source のまま" ;;
  *)
    fail "#139 ケース4: 共有元が無いエントリはコピー対象にもならず no-source のまま" "output=[${SPD139_OUT4}]" ;;
esac
assert_eq "#139 ケース4: レーンに空の実体ディレクトリが残らない" \
  "no" "$([ -e "${SPD139_LANE4}/no_such_dir_139" ] && echo yes || echo no)"

# --- ケース5: --dry-run 時はコピー・フォールバックを一切実行しない（既存の link-failed のまま） ---
SPD139_LANE5="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-lane5.XXXXXX")"
SPD139_OUT5="$(spd_run "$SPD139_LANE5" "$SPD139_STUB" --source "$SPD139_SOURCE" --dir "node_modules" --dry-run)"
case "$SPD139_OUT5" in
  *"copied"*)
    fail "#139 ケース5: --dry-run ではコピー・フォールバックを実行しない" "output=[${SPD139_OUT5}]" ;;
  *)
    pass "#139 ケース5: --dry-run ではコピー・フォールバックを実行しない" ;;
esac
assert_eq "#139 ケース5: --dry-run では実体が作られない" \
  "no" "$([ -e "${SPD139_LANE5}/node_modules" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: prep=run のまま何も実行されない状態を明示する警告（Task #139）
#
# --run-prep を渡さずに prep=run のまま終わる呼び出しは、従来 stdout の prep= 行を
# 見落とすと「何も起きない」まま静かに exit 0 する（issue #139 の実害）。
# stderr に明示の警告が出るかを検証する（exit コードは変えないため 0 のまま）。
# ---------------------------------------------------------------------------

echo "== share-prepared-dirs.sh: prep=run かつ --run-prep 無指定を明示する警告（#139） =="

SPD139_LANE_W1="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-lanew1.XXXXXX")"
SPD139_STDERR_W1="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd139-stderr-w1.XXXXXX")"
(cd "$SPD139_LANE_W1" || exit 1
 DEV_WORKFLOW_SANDBOX_EXEC="$SPD_STUB" bash "$SPD_SCRIPT" --source "$SPD139_SOURCE" \
   --dir "no_such_dir_139_warn" >/dev/null 2>"$SPD139_STDERR_W1")
SPD139_WARN1_EXIT=$?
assert_exit_code "#139 警告ケース1: --run-prep 無指定・prep=run でも exit 0 のまま" 0 "$SPD139_WARN1_EXIT"
case "$(cat "$SPD139_STDERR_W1" 2>/dev/null)" in
  *"WARNING"*"prep=run"*"--run-prep"*)
    pass "#139 警告ケース1: --run-prep 無指定・prep=run のとき stderr に明示の警告が出る" ;;
  *)
    fail "#139 警告ケース1: --run-prep 無指定・prep=run のとき stderr に明示の警告が出る" \
      "stderr=[$(cat "$SPD139_STDERR_W1" 2>/dev/null)]" ;;
esac

# --run-prep を渡した場合は警告が出ない（コマンド自体は実行される。true を渡し成功させる）
SPD139_LANE_W2="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd139-lanew2.XXXXXX")"
SPD139_STDERR_W2="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd139-stderr-w2.XXXXXX")"
(cd "$SPD139_LANE_W2" || exit 1
 DEV_WORKFLOW_SANDBOX_EXEC="$SPD_STUB" bash "$SPD_SCRIPT" --source "$SPD139_SOURCE" \
   --dir "no_such_dir_139_warn2" --run-prep "true" >/dev/null 2>"$SPD139_STDERR_W2")
case "$(cat "$SPD139_STDERR_W2" 2>/dev/null)" in
  *"WARNING"*"prep=run"*)
    fail "#139 警告ケース2: --run-prep 指定時は警告が出ない" \
      "stderr=[$(cat "$SPD139_STDERR_W2" 2>/dev/null)]" ;;
  *)
    pass "#139 警告ケース2: --run-prep 指定時は警告が出ない" ;;
esac

# ---------------------------------------------------------------------------
# sandbox-exec.sh --print-plan: cache_volume は dockerfile モードでのみ出力する（issue #104）
#
# cache_mount_args()（volume の -v 引数を組み立てる関数）は docker run を使う dockerfile
# 分岐でしか呼ばれず、compose モードでは一切マウントされない（README「既知の限界
# （キャッシュ volume）」節）。以前の --print-plan はモードに関わらず cache_volume= 行を
# 出力しており、compose モードでもキャッシュが接続されているかのように誤読させる不整合が
# あった（docs/adr/0008-node-modules-named-volume-deferred.md）。dockerfile モードの既存
# 出力は変えず、compose モードでのみ行が消えることを確認する。
# ---------------------------------------------------------------------------

echo "== --print-plan: cache_volume は dockerfile モード限定（issue #104） =="

CV104_DOCKERFILE_REPO="$(make_temp_repo)"
copy_sandbox_scripts "$CV104_DOCKERFILE_REPO"
CV104_DOCKERFILE_OUTPUT="$(print_plan_in "$CV104_DOCKERFILE_REPO")"

assert_eq "#104: dockerfileモードの一時リポジトリは mode=dockerfile" \
  "dockerfile" "$(plan_value mode "$CV104_DOCKERFILE_OUTPUT")"

CV104_DOCKERFILE_CACHE_COUNT="$(printf '%s\n' "$CV104_DOCKERFILE_OUTPUT" | grep -c '^cache_volume=' || true)"
if [ "$CV104_DOCKERFILE_CACHE_COUNT" -gt 0 ]; then
  pass "#104: dockerfileモードでは従来どおり cache_volume が出力される（${CV104_DOCKERFILE_CACHE_COUNT}件）"
else
  fail "#104: dockerfileモードでは従来どおり cache_volume が出力される" "0件でした"
fi

CV104_COMPOSE_REPO="$(make_temp_repo)"
copy_sandbox_scripts_no_dockerfile "$CV104_COMPOSE_REPO"
printf 'services:\n  app:\n    build: .\n    volumes:\n      - .:/workspace\n' \
  > "${CV104_COMPOSE_REPO}/docker-compose.dev.yml"
(
  cd "$CV104_COMPOSE_REPO" || exit 1
  git add docker-compose.dev.yml
  git commit -q -m "add compose file"
) >/dev/null 2>&1

CV104_COMPOSE_OUTPUT="$(print_plan_in "$CV104_COMPOSE_REPO")"

assert_eq "#104: composeモードの一時リポジトリは mode=compose" \
  "compose" "$(plan_value mode "$CV104_COMPOSE_OUTPUT")"

CV104_COMPOSE_CACHE_COUNT="$(printf '%s\n' "$CV104_COMPOSE_OUTPUT" | grep -c '^cache_volume=' || true)"
assert_eq "#104: composeモードでは cache_volume 行が出力されない（実際には接続されないため）" \
  "0" "$CV104_COMPOSE_CACHE_COUNT"

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: コピー・フォールバックの再設計（Review #177/#178/#179/#180）
#
# 4件はいずれも「部分的に失敗したコピーを成功として確定させない」という同じ根に対する
# 再設計の検証であり、まとめて1セクションに置く。SPD139_SOURCE（node_modules/.bin +
# some-pkg.js）と spd139_make_stub（fakebinをPATHに割り込ませるスタブ生成）を再利用する。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh: コピー・フォールバックの再設計（Review #177/#178/#179/#180） =="

# --- Review #177: cp の部分失敗が入れ子コピーを作らず、copied にも化けない ---
#
# BusyBox の cp は名前衝突（コピー先に同名の非ディレクトリが既にある）等で
# エントリ単位のエラーを起こすと、他のエントリはコピーしたまま rc=1 を返す（部分失敗）。
# 旧実装はこの部分失敗後の再試行 `cp -r "$s" "$tmp"`（要素形。$tmp が既に存在すると
# ネストする）で壊れたツリーを copied として成功報告していた。再設計後は $tmp を新規に
# mkdir してから内容形コピー（"$s/." -> "$tmp/"）のみを使うため、そもそもネストする
# コードパスが無いことを確認する。
SPD177_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd177-source.XXXXXX")"
SPD177_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd177-lane.XXXXXX")"
mkdir -p "${SPD177_SOURCE}/node_modules/dirA"
printf 'one\n' > "${SPD177_SOURCE}/node_modules/dirA/one.txt"
printf 'two\n' > "${SPD177_SOURCE}/node_modules/fileB.txt"

SPD177_REAL_CP="$(command -v cp)"
SPD177_FAKEBIN_LN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd177-fakebin-ln.XXXXXX")"
cat > "${SPD177_FAKEBIN_LN}/ln" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${SPD177_FAKEBIN_LN}/ln"

SPD177_MARKER="$(mktemp -u "${TMPDIR:-/tmp}/dw-test-spd177-marker.XXXXXX")"
SPD177_FAKEBIN_CP="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd177-fakebin-cp.XXXXXX")"
cat > "${SPD177_FAKEBIN_CP}/cp" <<EOF
#!/bin/sh
# コピー先の3番目の引数（cp -aL "\$s/." "\$tmp/" の \$tmp/ に相当）へ、初回呼び出し
# だけ「dirA」という名前の衝突ファイルを先置きし、実物の cp を部分失敗させる。
MARKER="${SPD177_MARKER}"
DEST="\$3"
if [ ! -f "\$MARKER" ]; then
  touch "\$MARKER"
  mkdir -p "\$DEST"
  echo blocker > "\${DEST}dirA"
fi
exec "${SPD177_REAL_CP}" "\$@"
EOF
chmod +x "${SPD177_FAKEBIN_CP}/cp"

SPD177_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd177-calllog.XXXXXX")"
SPD177_STUB="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd177-stub.XXXXXX")"
cat > "$SPD177_STUB" <<EOF
#!/bin/bash
set -u
printf 1 >> "${SPD177_CALL_LOG}"
PATH="${SPD177_FAKEBIN_CP}:${SPD177_FAKEBIN_LN}:\$PATH"
cmd="\${@: -1}"
sh -c "\$cmd"
EOF
chmod +x "$SPD177_STUB"

SPD177_OUT="$(spd_run "$SPD177_LANE" "$SPD177_STUB" --source "$SPD177_SOURCE" --dir "node_modules")"

case "$SPD177_OUT" in
  *"copied"*)
    fail "#177: 部分失敗したコピーが copied にならない" "output=[${SPD177_OUT}]" ;;
  *)
    pass "#177: 部分失敗したコピーが copied にならない" ;;
esac
case "$SPD177_OUT" in
  *"skip"*"node_modules"*"reason"*"link-failed"*)
    pass "#177: 部分失敗したコピーは skip reason link-failed のまま（#139のフォールバック未成立）" ;;
  *)
    fail "#177: 部分失敗したコピーは skip reason link-failed のまま" "output=[${SPD177_OUT}]" ;;
esac

SPD177_NESTED="$(find "$SPD177_LANE" -path '*node_modules*node_modules*' 2>/dev/null)"
assert_eq "#177: レーン側に入れ子コピー（node_modules/node_modules）が作られない" \
  "" "$SPD177_NESTED"

# --- Review #180: 空の実体ディレクトリへの in-place コピーが部分失敗しても、
#     次回実行が exists と誤判定されない ---
#
# ln -s の失敗時に空の実体ディレクトリが副作用として残る状況（issue #139 の報告）を
# SPD139_FAKEBIN_EMPTY で再現し、その状態でコピーも失敗させると <dir> は空のまま残る。
# 旧実装は判定順序2（`[ -e "$d" ]`）が空ディレクトリの存在だけで真になるため、再実行時に
# exists と誤判定されフォールバックが働かなくなっていた（#180）。再設計後は判定順序2が
# 「空の実体ディレクトリ」を exists から除外し、link-failed として毎回コピー・
# フォールバックに委ねることを確認する。
SPD180_SOURCE="$SPD139_SOURCE"
SPD180_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd180-lane.XXXXXX")"

SPD180_FAKEBIN_CPFAIL="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd180-fakebin-cpfail.XXXXXX")"
cat > "${SPD180_FAKEBIN_CPFAIL}/cp" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${SPD180_FAKEBIN_CPFAIL}/cp"

SPD180_STUB1="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd180-stub1.XXXXXX")"
cat > "$SPD180_STUB1" <<EOF
#!/bin/bash
set -u
PATH="${SPD180_FAKEBIN_CPFAIL}:${SPD139_FAKEBIN_EMPTY}:\$PATH"
cmd="\${@: -1}"
sh -c "\$cmd"
EOF
chmod +x "$SPD180_STUB1"

# 1回目: ln -s 失敗の副作用で空ディレクトリが残り、コピーも失敗するため <dir> は空のまま
SPD180_OUT1="$(spd_run "$SPD180_LANE" "$SPD180_STUB1" --source "$SPD180_SOURCE" --dir "node_modules")"
case "$SPD180_OUT1" in
  *"skip"*"node_modules"*"reason"*"link-failed"*)
    pass "#180: 1回目は link-failed（空ディレクトリが副作用として残る想定どおり）" ;;
  *)
    fail "#180: 1回目は link-failed（空ディレクトリが副作用として残る想定どおり）" "output=[${SPD180_OUT1}]" ;;
esac
assert_eq "#180: 1回目の後、<dir> は空のまま（cpが失敗しても部分内容が書き込まれない）" \
  "" "$(ls -A "${SPD180_LANE}/node_modules" 2>/dev/null)"

# 2回目: 同じレーン・同じ状況（ln は相変わらず失敗、cp も相変わらず失敗）で再実行しても
# 判定順序2の exists 誤判定は起きず、link-failed が再現する（#180 本題）
SPD180_OUT2="$(spd_run "$SPD180_LANE" "$SPD180_STUB1" --source "$SPD180_SOURCE" --dir "node_modules")"
case "$SPD180_OUT2" in
  *"skip"*"node_modules"*"reason"*"exists"*)
    fail "#180: 2回目が exists に化けない" "output=[${SPD180_OUT2}]" ;;
  *"skip"*"node_modules"*"reason"*"link-failed"*)
    pass "#180: 2回目が exists に化けない（link-failed が再現する）" ;;
  *)
    fail "#180: 2回目が exists に化けない" "output=[${SPD180_OUT2}]" ;;
esac
case "$SPD180_OUT2" in
  *"prep=run"*)
    pass "#180: 2回目も prep=run のまま（フォールバックが働く）" ;;
  *)
    fail "#180: 2回目も prep=run のまま（フォールバックが働く）" "output=[${SPD180_OUT2}]" ;;
esac

# 3回目: 今度は cp を失敗させない（ln のみ失敗）。空のまま残っていた <dir> に、
# 単一の手順（tmpへコピー→完全性検証→mv -Tで確定）が正しく内容を埋められることを確認する
SPD180_STUB2="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd180-stub2.XXXXXX")"
cat > "$SPD180_STUB2" <<EOF
#!/bin/bash
set -u
PATH="${SPD139_FAKEBIN_EMPTY}:\$PATH"
cmd="\${@: -1}"
sh -c "\$cmd"
EOF
chmod +x "$SPD180_STUB2"

SPD180_OUT3="$(spd_run "$SPD180_LANE" "$SPD180_STUB2" --source "$SPD180_SOURCE" --dir "node_modules")"
case "$SPD180_OUT3" in
  *"copied"*"node_modules"*)
    pass "#180: 3回目（cpが成功する状況）で空だった <dir> に正しく展開される" ;;
  *)
    fail "#180: 3回目（cpが成功する状況）で空だった <dir> に正しく展開される" "output=[${SPD180_OUT3}]" ;;
esac
assert_eq "#180: 復旧後、コピー先の内容がソースと一致する" \
  "yes" "$(cmp -s "${SPD180_SOURCE}/node_modules/some-pkg.js" "${SPD180_LANE}/node_modules/some-pkg.js" && echo yes || echo no)"

# --- Review #179: コピー失敗時の一時ディレクトリの残骸がレーンの作業ツリーに残らない ---
#
# レーンが git worktree の場合（実運用は常にそう）、コピー失敗時の一時ディレクトリは
# git-dir 配下（追跡対象外）に置かれ、レーンの作業ツリーからは一切見えないことを確認する。
SPD179_SOURCE="$SPD139_SOURCE"
SPD179_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd179-lane.XXXXXX")"
(
  cd "$SPD179_LANE" || exit 1
  git init -q
  git config user.email "dw-test@example.com"
  git config user.name "dw-test"
) >/dev/null 2>&1

SPD179_FAKEBIN_CPFAIL="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd179-fakebin-cpfail.XXXXXX")"
cat > "${SPD179_FAKEBIN_CPFAIL}/cp" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${SPD179_FAKEBIN_CPFAIL}/cp"

SPD179_FAKEBIN_LN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd179-fakebin-ln.XXXXXX")"
cat > "${SPD179_FAKEBIN_LN}/ln" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${SPD179_FAKEBIN_LN}/ln"

SPD179_STUB="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd179-stub.XXXXXX")"
cat > "$SPD179_STUB" <<EOF
#!/bin/bash
set -u
PATH="${SPD179_FAKEBIN_CPFAIL}:${SPD179_FAKEBIN_LN}:\$PATH"
cmd="\${@: -1}"
sh -c "\$cmd"
EOF
chmod +x "$SPD179_STUB"

SPD179_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd179-stderr.XXXXXX")"
SPD179_OUT="$(spd_run "$SPD179_LANE" "$SPD179_STUB" --source "$SPD179_SOURCE" --dir "node_modules" 2>"$SPD179_STDERR")"

case "$SPD179_OUT" in
  *"skip"*"node_modules"*"reason"*"link-failed"*)
    pass "#179: コピー失敗時は link-failed のまま（残骸確認の前提が成立）" ;;
  *)
    fail "#179: コピー失敗時は link-failed のまま" "output=[${SPD179_OUT}]" ;;
esac

SPD179_VISIBLE_RESIDUE="$(find "$SPD179_LANE" -mindepth 1 -not -path "${SPD179_LANE}/.git" -not -path "${SPD179_LANE}/.git/*" 2>/dev/null)"
assert_eq "#179: レーンの作業ツリー（.git を除く）に一時ディレクトリの残骸が残らない" \
  "" "$SPD179_VISIBLE_RESIDUE"

SPD179_GITDIR_RESIDUE="$(find "${SPD179_LANE}/.git" -iname '*dwcopy*' 2>/dev/null)"
if [ -n "$SPD179_GITDIR_RESIDUE" ]; then
  pass "#179: 残骸は git-dir 配下（追跡対象外）に置かれている"
else
  fail "#179: 残骸は git-dir 配下（追跡対象外）に置かれている" "見つかりませんでした"
fi

SPD179_GIT_STATUS="$(cd "$SPD179_LANE" && git status --porcelain --ignored 2>/dev/null)"
assert_eq "#179: git status が汚れない（残骸が git の追跡対象外に置かれているため）" \
  "" "$SPD179_GIT_STATUS"

# git-dir を解決できない場合（レーンが git リポジトリでない）は、従来どおりレーンの作業
# ツリー直下に一時ディレクトリが残り、そのパスが stderr に明示されることを確認する。
SPD179_NOGIT_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd179-nogit-lane.XXXXXX")"
SPD179_NOGIT_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd179-nogit-stderr.XXXXXX")"
spd_run "$SPD179_NOGIT_LANE" "$SPD179_STUB" --source "$SPD179_SOURCE" --dir "node_modules" \
  >/dev/null 2>"$SPD179_NOGIT_STDERR"
case "$(cat "$SPD179_NOGIT_STDERR" 2>/dev/null)" in
  *"残骸"*"node_modules.dwtmp"*)
    pass "#179: git-dir が無い場合は残骸のパスを stderr に明示する（従来どおりレーン直下）" ;;
  *)
    fail "#179: git-dir が無い場合は残骸のパスを stderr に明示する" \
      "stderr=[$(cat "$SPD179_NOGIT_STDERR" 2>/dev/null)]" ;;
esac

# --- Review #178: symlink を含むソースが、コピー・フォールバックで正しく実体化される（-L の効果） ---
#
# symlink 作成が拒否される環境では `cp -a` / `cp -r` も symlink(2) を呼ぶため
# `.bin/*` のようなシンボリックリンクで部分的に失敗する（#178）。`-L` を付けて
# シンボリックリンクを辿って実体をコピーすることで、この経路でも正しく実体化される
# ことを確認する。
#
# レビュー #182 で「-L 無しのコピーを先に試す」順序に変更したため、`ln` バイナリを
# 塞ぐだけでは -L 無しの `cp -a` 自体は（symlink(2) がテスト環境では実際には拒否
# されていないため）成功してしまい、`-L` 経路を検証できない。そのため、-L を含まない
# 呼び出しは失敗し、-L を含む呼び出しだけ本物へ委譲する偽 cp を追加し、symlink 作成が
# 拒否される環境を模擬する（issue #139 が報告する状況そのもの）。
spd182_make_cp_requires_l() {
  # spd182_make_cp_requires_l <bindir>  cp を「第1引数に L を含む呼び出しのみ成功する」
  # 偽物に差し替える。symlink 作成そのものが拒否される環境（-L 無しの cp が部分的に
  # 失敗し、-L 付きの cp だけが成功する）を模擬するため。
  local bindir="$1" real_cp
  real_cp="$(command -v cp)"
  mkdir -p "$bindir"
  cat > "${bindir}/cp" <<EOF
#!/bin/sh
case "\$1" in
  *L*) exec "${real_cp}" "\$@" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${bindir}/cp"
}

SPD178_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd178-source.XXXXXX")"
SPD178_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd178-lane.XXXXXX")"
mkdir -p "${SPD178_SOURCE}/node_modules/.bin" "${SPD178_SOURCE}/node_modules/pkgX"
printf '#!/bin/sh\necho real-bin\n' > "${SPD178_SOURCE}/node_modules/pkgX/real-bin"
chmod +x "${SPD178_SOURCE}/node_modules/pkgX/real-bin"
ln -s ../pkgX/real-bin "${SPD178_SOURCE}/node_modules/.bin/real-bin"

SPD178_FAKEBIN_LN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd178-fakebin-ln.XXXXXX")"
cat > "${SPD178_FAKEBIN_LN}/ln" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${SPD178_FAKEBIN_LN}/ln"
SPD178_FAKEBIN_CP="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd178-fakebin-cp.XXXXXX")"
spd182_make_cp_requires_l "$SPD178_FAKEBIN_CP"

SPD178_STUB="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd178-stub.XXXXXX")"
cat > "$SPD178_STUB" <<EOF
#!/bin/bash
set -u
PATH="${SPD178_FAKEBIN_CP}:${SPD178_FAKEBIN_LN}:\$PATH"
cmd="\${@: -1}"
sh -c "\$cmd"
EOF
chmod +x "$SPD178_STUB"

SPD178_OUT="$(spd_run "$SPD178_LANE" "$SPD178_STUB" --source "$SPD178_SOURCE" --dir "node_modules")"
case "$SPD178_OUT" in
  *"copied"*"node_modules"*)
    pass "#178: symlink を含むソースでもコピー・フォールバックが copied になる" ;;
  *)
    fail "#178: symlink を含むソースでもコピー・フォールバックが copied になる" "output=[${SPD178_OUT}]" ;;
esac
assert_eq "#178: .bin 配下の symlink が実ファイルとして展開される（symlinkのままではない）" \
  "yes" "$([ -f "${SPD178_LANE}/node_modules/.bin/real-bin" ] && [ ! -L "${SPD178_LANE}/node_modules/.bin/real-bin" ] && echo yes || echo no)"
assert_eq "#178: 展開されたファイルの内容がリンク先の実体と一致する" \
  "yes" "$(cmp -s "${SPD178_SOURCE}/node_modules/pkgX/real-bin" "${SPD178_LANE}/node_modules/.bin/real-bin" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: コピー元パスの相対化（レビュー #181）
#
# コピー元 $s はコンテナ内ミニスクリプトへそのまま渡されるため、レーンの作業
# ディレクトリ（コンテナ内 workdir）基準の相対パスでなければならない。共有元の
# ホスト絶対パス（--source の値）をそのまま渡すと、コンテナはリポジトリルートを
# /workspace にマウントするためコンテナ内には存在せず cp が必ず失敗していた
# （#181）。生成されるミニスクリプトの s= 行を検査し、ホスト絶対パス（--source の
# 値そのもの）を含まないことを確認する。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh: コピー元パスの相対化（レビュー #181） =="

SPD181_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd181-source.XXXXXX")"
SPD181_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd181-lane.XXXXXX")"
mkdir -p "${SPD181_SOURCE}/node_modules"
printf 'pkg-content\n' > "${SPD181_SOURCE}/node_modules/f.txt"

SPD181_FAKEBIN_LN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd181-fakebin-ln.XXXXXX")"
cat > "${SPD181_FAKEBIN_LN}/ln" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${SPD181_FAKEBIN_LN}/ln"

SPD181_SCRIPT_LOG="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd181-scriptlog.XXXXXX")"
SPD181_STUB="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd181-stub.XXXXXX")"
cat > "$SPD181_STUB" <<EOF
#!/bin/bash
set -u
cmd="\${@: -1}"
{
  printf '%s\n' "\$cmd"
  printf '\n---SPD181-CALL-END---\n'
} >> "${SPD181_SCRIPT_LOG}"
PATH="${SPD181_FAKEBIN_LN}:\$PATH"
sh -c "\$cmd"
EOF
chmod +x "$SPD181_STUB"

SPD181_OUT="$(spd_run "$SPD181_LANE" "$SPD181_STUB" --source "$SPD181_SOURCE" --dir "node_modules")"

case "$SPD181_OUT" in
  *"copied"*"node_modules"*)
    pass "#181: symlink失敗後のコピー・フォールバックが成立する（copied）" ;;
  *)
    fail "#181: symlink失敗後のコピー・フォールバックが成立する（copied）" "output=[${SPD181_OUT}]" ;;
esac

SPD181_S_LINES="$(grep -h '^s=' "$SPD181_SCRIPT_LOG" || true)"
if [ -n "$SPD181_S_LINES" ]; then
  pass "#181: コピー・ミニスクリプトに s= 行が生成される"
else
  fail "#181: コピー・ミニスクリプトに s= 行が生成される" "見つかりませんでした"
fi

case "$SPD181_S_LINES" in
  *"$SPD181_SOURCE"*)
    fail "#181: コピー元 s= がホスト絶対パス（--source の値）を含まない（コンテナ内で解決可能な相対パスであること）" \
      "s=[${SPD181_S_LINES}]" ;;
  *)
    pass "#181: コピー元 s= がホスト絶対パス（--source の値）を含まない（コンテナ内で解決可能な相対パスであること）" ;;
esac

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: コピー・フォールバックの順序変更と循環シンボリックリンク対策
# （レビュー #182）
#
# 「-L 無しのコピーを先に試す」順序変更と、-L を使う前の循環検査を検証する。
# 循環シンボリックリンクの検証は暴走した場合に削除できない残骸を生みうるため、
# ソースは実体5バイト級の最小構成にとどめ、下記の「-L 無しは失敗・-L 付きのみ成功」
# 偽 cp（symlink 作成が拒否される環境の模擬）と組み合わせることで、循環検査に
# よって -L 自体が一度も呼ばれないことを保証したうえで実行する。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh: コピー・フォールバックの順序変更と循環対策（レビュー #182） =="

# --- ケースA: -L 無しのコピーが先に試され、成功すればそれで完結する（順序の検証） ---
#
# 「-L 無しは成功・-L 付きは失敗する」偽 cp を使う。旧実装（-L を無条件に使う）なら
# このソースは copyfailed になるはずで、新実装（-L 無しを先に試す）なら copied になる。
spd182_make_cp_fails_with_l() {
  local bindir="$1" real_cp
  real_cp="$(command -v cp)"
  mkdir -p "$bindir"
  cat > "${bindir}/cp" <<EOF
#!/bin/sh
case "\$1" in
  *L*) exit 1 ;;
  *) exec "${real_cp}" "\$@" ;;
esac
EOF
  chmod +x "${bindir}/cp"
}

SPD182A_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd182a-source.XXXXXX")"
SPD182A_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd182a-lane.XXXXXX")"
mkdir -p "${SPD182A_SOURCE}/node_modules"
printf 'order-check\n' > "${SPD182A_SOURCE}/node_modules/f.txt"

SPD182A_FAKEBIN_LN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd182a-fakebin-ln.XXXXXX")"
cat > "${SPD182A_FAKEBIN_LN}/ln" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${SPD182A_FAKEBIN_LN}/ln"
SPD182A_FAKEBIN_CP="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd182a-fakebin-cp.XXXXXX")"
spd182_make_cp_fails_with_l "$SPD182A_FAKEBIN_CP"

SPD182A_STUB="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd182a-stub.XXXXXX")"
cat > "$SPD182A_STUB" <<EOF
#!/bin/bash
set -u
PATH="${SPD182A_FAKEBIN_CP}:${SPD182A_FAKEBIN_LN}:\$PATH"
cmd="\${@: -1}"
sh -c "\$cmd"
EOF
chmod +x "$SPD182A_STUB"

SPD182A_OUT="$(spd_run "$SPD182A_LANE" "$SPD182A_STUB" --source "$SPD182A_SOURCE" --dir "node_modules")"
case "$SPD182A_OUT" in
  *"copied"*"node_modules"*)
    pass "#182 ケースA: -L 無しのコピーが先に試され、成功すれば -L を使わず完結する（順序の検証）" ;;
  *)
    fail "#182 ケースA: -L 無しのコピーが先に試され、成功すれば -L を使わず完結する（順序の検証）" \
      "output=[${SPD182A_OUT}]" ;;
esac

# --- ケースB: 循環シンボリックリンクがあるソースは、-L を試みず copy-failed のまま
#     確定し、暴走したコピー（PATH_MAX級の残骸）を作らない（issue #182の本題） ---
#
# `-L` 無しは失敗・`-L` 付きのみ成功する偽 cp（symlink 作成が拒否される環境の模擬）と
# 組み合わせ、循環検査（find -L -mindepth/-maxdepth）が -L 呼び出し自体を止めることを
# 確認する。ソースの自己参照 symlink（`self -> ../..`）自体の作成は再帰しないため安全に
# 行える。危険なのは -L で辿った場合であり、それを止めることが本テストの主眼。
SPD182B_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd182b-source.XXXXXX")"
SPD182B_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd182b-lane.XXXXXX")"
mkdir -p "${SPD182B_SOURCE}/node_modules/pkg"
printf 'x\n' > "${SPD182B_SOURCE}/node_modules/pkg/f.txt"
ln -s ../.. "${SPD182B_SOURCE}/node_modules/pkg/self"

SPD182B_FAKEBIN_LN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd182b-fakebin-ln.XXXXXX")"
cat > "${SPD182B_FAKEBIN_LN}/ln" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${SPD182B_FAKEBIN_LN}/ln"
SPD182B_FAKEBIN_CP="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd182b-fakebin-cp.XXXXXX")"
spd182_make_cp_requires_l "$SPD182B_FAKEBIN_CP"

SPD182B_STUB="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd182b-stub.XXXXXX")"
cat > "$SPD182B_STUB" <<EOF
#!/bin/bash
set -u
PATH="${SPD182B_FAKEBIN_CP}:${SPD182B_FAKEBIN_LN}:\$PATH"
cmd="\${@: -1}"
sh -c "\$cmd"
EOF
chmod +x "$SPD182B_STUB"

SPD182B_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd182b-stderr.XXXXXX")"
SPD182B_OUT="$(spd_run "$SPD182B_LANE" "$SPD182B_STUB" --source "$SPD182B_SOURCE" --dir "node_modules" 2>"$SPD182B_STDERR")"

case "$SPD182B_OUT" in
  *"copied"*)
    fail "#182 ケースB: 循環シンボリックリンクを含むソースは copied にならない" "output=[${SPD182B_OUT}]" ;;
  *)
    pass "#182 ケースB: 循環シンボリックリンクを含むソースは copied にならない" ;;
esac
case "$SPD182B_OUT" in
  *"skip"*"node_modules"*"reason"*"copy-cycle-guard"*)
    pass "#182/#185 ケースB: 循環シンボリックリンクを含むソースは copy-cycle-guard reason で確定する（他の失敗原因と区別できる。#185）" ;;
  *)
    fail "#182/#185 ケースB: 循環シンボリックリンクを含むソースは copy-cycle-guard reason で確定する（他の失敗原因と区別できる。#185）" \
      "output=[${SPD182B_OUT}]" ;;
esac
case "$(cat "$SPD182B_STDERR" 2>/dev/null)" in
  *"WARNING"*"循環検査ガード"*"node_modules"*"#185"*)
    pass "#185: ガードが発火して -L を試みなかった事実が stderr に診断として出力される" ;;
  *)
    fail "#185: ガードが発火して -L を試みなかった事実が stderr に診断として出力される" \
      "stderr=[$(cat "$SPD182B_STDERR" 2>/dev/null)]" ;;
esac

# 循環検査が -L 呼び出し自体を止めているため、残骸（<dir>.dwtmp$$。SPD182B_LANE は
# git worktree ではないためレーン直下に残る）は空のまま（-L が一度も走らなければ
# 暴走した深い構造は作られない）。
SPD182B_RESIDUE_DIR="$(find "$SPD182B_LANE" -maxdepth 1 -iname 'node_modules.dwtmp*' 2>/dev/null | head -n 1)"
if [ -n "$SPD182B_RESIDUE_DIR" ]; then
  pass "#182 ケースB: 残骸ディレクトリが見つかる（検証の前提）"
  assert_eq "#182 ケースB: 循環検査により -L が一度も呼ばれず、残骸は空のまま（暴走コピーを作らない）" \
    "" "$(ls -A "$SPD182B_RESIDUE_DIR" 2>/dev/null)"
else
  # -L 無しの cp が mkdir すら行わず tmp を作らずに失敗した場合、残骸自体が無い
  # （これも「暴走コピーを作らない」という主張と矛盾しない。より強い結果）。
  pass "#182 ケースB: 残骸ディレクトリすら作られない（-L 無しの失敗時点で何も書き込まれていない）"
fi

SPD182B_DEEP="$(find "$SPD182B_LANE" -mindepth 8 2>/dev/null | head -n 1)"
assert_eq "#182 ケースB: レーン配下に深さ8を超えるパスが作られない（PATH_MAX級の暴走が無い）" \
  "" "$SPD182B_DEEP"

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: 空の実体ディレクトリへのコピー経路は ln -s の成否と無関係
# （レビュー #183。冒頭コメントの記述訂正の裏付け）
#
# #180 により、レーン側 <dir> が「空の」実体ディレクトリの場合は ln -s を一切試みず
# 無条件に link-failed とする。この分岐は ln -s の成否と無関係なので、ln が正常動作する
# 環境でも発火することを確認する（冒頭コメントが誤って「symlink が確認できる環境では
# この経路は実行されない」と記載していたことの実地での反証）。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh: 空の実体ディレクトリへのコピー経路は ln の成否と無関係（レビュー #183） =="

SPD183_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd183-source.XXXXXX")"
SPD183_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd183-lane.XXXXXX")"
mkdir -p "${SPD183_SOURCE}/node_modules"
printf 'ok\n' > "${SPD183_SOURCE}/node_modules/f.txt"
mkdir -p "${SPD183_LANE}/node_modules"   # レーン側に「空の」実体ディレクトリが既に存在する

# ln は差し替えない（正常動作する環境を模す）。実際に ln -s を試みれば成功するはずの
# 環境でも、空ディレクトリの分岐によりコピー経路が使われることを確認する。
SPD183_OUT="$(spd_run "$SPD183_LANE" "$SPD_STUB" --source "$SPD183_SOURCE" --dir "node_modules")"
case "$SPD183_OUT" in
  *"copied"*"node_modules"*)
    pass "#183: ln が正常動作する環境でも、空の実体ディレクトリはコピー経路が使われる（copied）" ;;
  *)
    fail "#183: ln が正常動作する環境でも、空の実体ディレクトリはコピー経路が使われる（copied）" \
      "output=[${SPD183_OUT}]" ;;
esac
assert_eq "#183: レーン側の node_modules は symlink 化されず実体のまま（コピー経路が使われた証拠）" \
  "yes" "$([ -d "${SPD183_LANE}/node_modules" ] && [ ! -L "${SPD183_LANE}/node_modules" ] && echo yes || echo no)"

# 冒頭コメントの記述が訂正されていることも確認する（#183）。
SPD_HEADER_183="$(awk '/^set -u/{exit} {print}' "$SPD_SCRIPT")"
case "$SPD_HEADER_183" in
  *"symlink が確認できる環境"*"この経路は実行されない"*"既存動作を変えない"*)
    fail "#183: 冒頭コメントの誤った記述（symlink成功環境では実行されないと明記していたもの）が残っていない" \
      "見つかりました" ;;
  *)
    pass "#183: 冒頭コメントの誤った記述（symlink成功環境では実行されないと明記していたもの）が残っていない" ;;
esac
case "$SPD_HEADER_183" in
  *"ln -s"*"成否とは"*"無関係"*)
    pass "#183: 冒頭コメントが、空ディレクトリのコピー経路が ln -s の成否と無関係であることを正しく記述している" ;;
  *)
    fail "#183: 冒頭コメントが、空ディレクトリのコピー経路が ln -s の成否と無関係であることを正しく記述している" \
      "見つかりませんでした" ;;
esac
case "$SPD_HEADER_183" in
  *"root 所有"*)
    pass "#183: 冒頭コメントが root 所有のツリーが残る点に言及している" ;;
  *)
    fail "#183: 冒頭コメントが root 所有のツリーが残る点に言及している" "見つかりませんでした" ;;
esac

# ---------------------------------------------------------------------------
# share-prepared-dirs.sh: 循環検査の深さ CAP 引き上げによる偽陽性の解消（レビュー #185）
#
# CAP=20（#182時点）は、循環の**無い**正当な yarn workspaces 直鎖依存（10パッケージ、
# `packages/pkgN/node_modules/pkgM -> ../../pkgM`）で深さ23〜24に到達し、-L 自体を試みず
# 誤って copy-failed に倒していた（issue #185 がサンドボックスで実測・再現）。CAP=80への
# 引き上げにより、この構成では -L が実際に呼ばれ copied になることを確認する。循環
# （`self -> ../..`）では引き続き発火し -L が一度も呼ばれないことは、上記ケースB（#182/#185）
# で確認済み。
# ---------------------------------------------------------------------------

echo ""
echo "== share-prepared-dirs.sh: 循環検査の深さ CAP 引き上げによる偽陽性の解消（レビュー #185） =="

SPD185_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd185-source.XXXXXX")"
SPD185_LANE="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd185-lane.XXXXXX")"

# issue #185 が実測した構成をそのまま再現する: 10パッケージの直鎖依存
# （packages/pkgN/node_modules/pkgM -> ../../pkgM）。循環は一切無い。
mkdir -p "${SPD185_SOURCE}/packages"
_i=1
while [ "$_i" -le 10 ]; do
  mkdir -p "${SPD185_SOURCE}/packages/pkg${_i}/src/lib/internal"
  printf 'x\n' > "${SPD185_SOURCE}/packages/pkg${_i}/src/lib/internal/file.txt"
  _i=$((_i + 1))
done
_i=1
while [ "$_i" -le 9 ]; do
  _j=$((_i + 1))
  mkdir -p "${SPD185_SOURCE}/packages/pkg${_i}/node_modules"
  ln -s "../../pkg${_j}" "${SPD185_SOURCE}/packages/pkg${_i}/node_modules/pkg${_j}"
  _i=$((_i + 1))
done
unset _i _j

# フィクスチャ自体が旧CAP=20を超える深さに到達することを、検証の前提として確認する
# （前提が崩れていれば、以降のアサーションは「たまたま通っただけ」になってしまう）。
SPD185_DEPTH20_HIT="$(find -L "$SPD185_SOURCE" -mindepth 20 -maxdepth 20 2>/dev/null | head -n 1)"
if [ -n "$SPD185_DEPTH20_HIT" ]; then
  pass "#185: フィクスチャ（10パッケージ直鎖）が旧CAP=20を超える深さに到達する（検証の前提）"
else
  fail "#185: フィクスチャ（10パッケージ直鎖）が旧CAP=20を超える深さに到達する（検証の前提）" \
    "見つかりませんでした"
fi

# -L 無しは失敗・-L 付きのみ成功する偽 cp（symlink 作成が拒否される環境の模擬）と
# 組み合わせ、循環では無いのに新CAPでも誤って -L を止めてしまわないことを確認する。
SPD185_FAKEBIN_LN="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd185-fakebin-ln.XXXXXX")"
cat > "${SPD185_FAKEBIN_LN}/ln" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${SPD185_FAKEBIN_LN}/ln"
SPD185_FAKEBIN_CP="$(mktemp -d "${TMPDIR:-/tmp}/dw-test-spd185-fakebin-cp.XXXXXX")"
spd182_make_cp_requires_l "$SPD185_FAKEBIN_CP"

SPD185_STUB="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd185-stub.XXXXXX")"
cat > "$SPD185_STUB" <<EOF
#!/bin/bash
set -u
PATH="${SPD185_FAKEBIN_CP}:${SPD185_FAKEBIN_LN}:\$PATH"
cmd="\${@: -1}"
sh -c "\$cmd"
EOF
chmod +x "$SPD185_STUB"

SPD185_STDERR="$(mktemp "${TMPDIR:-/tmp}/dw-test-spd185-stderr.XXXXXX")"
SPD185_OUT="$(spd_run "$SPD185_LANE" "$SPD185_STUB" --source "$SPD185_SOURCE" --dir "packages" 2>"$SPD185_STDERR")"

case "$SPD185_OUT" in
  *"copied"*"packages"*)
    pass "#185: 循環の無い正当な10パッケージ直鎖依存では -L が実際に呼ばれ copied になる（偽陽性の解消）" ;;
  *)
    fail "#185: 循環の無い正当な10パッケージ直鎖依存では -L が実際に呼ばれ copied になる（偽陽性の解消）" \
      "output=[${SPD185_OUT}]" ;;
esac
case "$SPD185_OUT" in
  *"copy-cycle-guard"*)
    fail "#185: 循環の無い正当な直鎖依存で循環検査ガードが誤発火しない" "output=[${SPD185_OUT}]" ;;
  *)
    pass "#185: 循環の無い正当な直鎖依存で循環検査ガードが誤発火しない" ;;
esac
assert_eq "#185: 誤発火しないので診断WARNINGも出力されない" \
  "" "$(cat "$SPD185_STDERR" 2>/dev/null)"
assert_eq "#185: コピー先の内容がソースと一致する（末端ファイルまで正しく展開される）" \
  "x" "$(cat "${SPD185_LANE}/packages/pkg9/node_modules/pkg10/src/lib/internal/file.txt" 2>/dev/null)"

# ---------------------------------------------------------------------------
# check-readability.sh: generated/ ディレクトリ配下の codegen 生成物を
# 誤検知しない（回帰防止 #141）
#
# `frontend/src/generated/graphql.ts`（graphql-codegen の client preset 相当）を
# 模した fixture: GraphQL ドキュメントの AST を1行のJSONとして出力する codegen
# ツールの実出力形状を再現し、issue #141 で報告された「極端に長い行」の誤検知
# （ミニファイ/難読化コードとして誤判定される）を回帰テストとして固定する。
#
# 併せて同一テストブロックで次の2点も担保する（Epic #174「#141の修正で、本物の
# ミニファイ/難読化コードの検出を弱めないこと」「判定できなかったときに安全側へ
# 倒れるかを設計すること」への対応）:
#   - `generated/` / `__generated__/` は許可されるが、同じ内容でも許可リストの
#     外（generated/以外の通常ディレクトリ）や、一般的すぎるため意図的に許可
#     リストへ加えなかった `gen/`（issue #141 の提案の一部を採用しなかった判断
#     の回帰確認）は引き続き検出される
#   - 本物のミニファイ/難読化コード（generated/の外）は許可リスト追加後も
#     引き続き検出される（検出力を弱めていないことの担保）
# ---------------------------------------------------------------------------

echo "== check-readability.sh: generated/ ディレクトリの誤検知回帰（#141） =="

RG141_TMP_REPO="$(make_temp_repo)"

# codegen が出力する「1行に集約されたJSONドキュメント」を模したペイロード
# （graphql-codegen の client preset は GraphQL AST をこの形で1行出力する。
# issue #141 の実測では最長行 6115文字）
RG141_LONGLINE_PAYLOAD="$(head -c 6200 /dev/zero | tr '\0' 'x')"

RG141_GENERATED_DIR="frontend/src/generated"
RG141_GENERATED_FILE="${RG141_GENERATED_DIR}/graphql.ts"
RG141_DUNDER_DIR="frontend/src/__generated__"
RG141_DUNDER_FILE="${RG141_DUNDER_DIR}/graphql.ts"
RG141_PLAIN_DIR="frontend/src/api"
RG141_PLAIN_FILE="${RG141_PLAIN_DIR}/graphql.ts"
RG141_GEN_DIR="frontend/src/gen"
RG141_GEN_FILE="${RG141_GEN_DIR}/graphql.ts"

(
  cd "$RG141_TMP_REPO" || exit 1
  mkdir -p "$RG141_GENERATED_DIR" "$RG141_DUNDER_DIR" "$RG141_PLAIN_DIR" "$RG141_GEN_DIR"
  printf 'export const documents = {"%s": Doc};\n' "$RG141_LONGLINE_PAYLOAD" > "$RG141_GENERATED_FILE"
  printf 'export const documents = {"%s": Doc};\n' "$RG141_LONGLINE_PAYLOAD" > "$RG141_DUNDER_FILE"
  printf 'export const documents = {"%s": Doc};\n' "$RG141_LONGLINE_PAYLOAD" > "$RG141_PLAIN_FILE"
  printf 'export const documents = {"%s": Doc};\n' "$RG141_LONGLINE_PAYLOAD" > "$RG141_GEN_FILE"
) >/dev/null 2>&1

# --- generated/ 配下（frontend/src/generated/graphql.ts 相当）は誤検知しない ---
RG141_GENERATED_EXIT=0
(
  cd "$RG141_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG141_GENERATED_FILE" >/dev/null 2>&1
)
RG141_GENERATED_EXIT=$?
assert_exit_code "generated/配下のcodegen生成物（長い1行）は誤検知しない（#141）" 0 "$RG141_GENERATED_EXIT"

# --- __generated__/ 配下も同様に誤検知しない ---
RG141_DUNDER_EXIT=0
(
  cd "$RG141_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG141_DUNDER_FILE" >/dev/null 2>&1
)
RG141_DUNDER_EXIT=$?
assert_exit_code "__generated__/配下のcodegen生成物（長い1行）は誤検知しない（#141）" 0 "$RG141_DUNDER_EXIT"

# --- 同じ内容でもgenerated/の外なら引き続き検出される（検出力は弱めていない） ---
RG141_PLAIN_EXIT=0
(
  cd "$RG141_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG141_PLAIN_FILE" >/dev/null 2>&1
)
RG141_PLAIN_EXIT=$?
assert_exit_code "generated/の外にある同一内容の長い1行は引き続き検出される（検出力の維持）" 2 "$RG141_PLAIN_EXIT"

# --- gen/（一般語で判定できない）配下は意図的に許可リストへ加えていないため引き続き検出される ---
RG141_GEN_EXIT=0
(
  cd "$RG141_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG141_GEN_FILE" >/dev/null 2>&1
)
RG141_GEN_EXIT=$?
assert_exit_code "gen/（一般語で判定できない）配下は許可リストに加えず引き続き検出される（安全側に倒す設計）" 2 "$RG141_GEN_EXIT"

# --- 本物のミニファイ/難読化コード（generated/の外）も引き続き検出される ---
RG141_MINIFIED_FILE="frontend/src/app/bundle.js"
(
  cd "$RG141_TMP_REPO" || exit 1
  mkdir -p "$(dirname "$RG141_MINIFIED_FILE")"
  {
    i=0
    while [ "$i" -lt 400 ]; do
      printf 'var v%d=function(a,b){return a+b};' "$i"
      i=$((i + 1))
    done
    printf '\n'
  } > "$RG141_MINIFIED_FILE"
) >/dev/null 2>&1

RG141_MINIFIED_EXIT=0
(
  cd "$RG141_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG141_MINIFIED_FILE" >/dev/null 2>&1
)
RG141_MINIFIED_EXIT=$?
assert_exit_code "本物のミニファイコード（generated/の外）は許可リスト追加後も引き続き検出される" 2 "$RG141_MINIFIED_EXIT"

# ---------------------------------------------------------------------------
# check-readability.sh: リポジトリ直下の generated/ が許可されない誤検知の回帰
# （issue #188）
#
# `*/generated/*` は先頭に `/` を要求するため、パスが `generated/graphql.ts` の形
# （先頭ディレクトリそのものが generated。`git diff --name-only` / `git ls-files` が
# 返すリポジトリ相対パスで、protobuf 出力・Go の生成物・モノレポのパッケージルート等で
# 実際に起こる形）だと一致しなかった。回帰テストが `frontend/src/generated/...` という
# 入れ子ケースだけを fixture にしていたため、この穴が #141 の回帰テストでは見えていなかった。
#
# 併せて、`generated/*` を先頭一致で足しても `pregenerated/` や `generated-old/` のような
# 紛らわしい名前には誤って一致しないこと（検出力を弱めていないこと）も固定する。
# ---------------------------------------------------------------------------

echo "== check-readability.sh: リポジトリ直下のgenerated/が許可されない誤検知の回帰（#188） =="

RG188_TMP_REPO="$(make_temp_repo)"

RG188_TOPLEVEL_GENERATED_DIR="generated"
RG188_TOPLEVEL_GENERATED_FILE="${RG188_TOPLEVEL_GENERATED_DIR}/graphql.ts"
RG188_TOPLEVEL_DUNDER_DIR="__generated__"
RG188_TOPLEVEL_DUNDER_FILE="${RG188_TOPLEVEL_DUNDER_DIR}/graphql.ts"
RG188_PREGEN_DIR="pregenerated"
RG188_PREGEN_FILE="${RG188_PREGEN_DIR}/graphql.ts"
RG188_GENOLD_DIR="generated-old"
RG188_GENOLD_FILE="${RG188_GENOLD_DIR}/graphql.ts"

(
  cd "$RG188_TMP_REPO" || exit 1
  mkdir -p "$RG188_TOPLEVEL_GENERATED_DIR" "$RG188_TOPLEVEL_DUNDER_DIR" "$RG188_PREGEN_DIR" "$RG188_GENOLD_DIR"
  printf 'export const documents = {"%s": Doc};\n' "$RG141_LONGLINE_PAYLOAD" > "$RG188_TOPLEVEL_GENERATED_FILE"
  printf 'export const documents = {"%s": Doc};\n' "$RG141_LONGLINE_PAYLOAD" > "$RG188_TOPLEVEL_DUNDER_FILE"
  printf 'export const documents = {"%s": Doc};\n' "$RG141_LONGLINE_PAYLOAD" > "$RG188_PREGEN_FILE"
  printf 'export const documents = {"%s": Doc};\n' "$RG141_LONGLINE_PAYLOAD" > "$RG188_GENOLD_FILE"
) >/dev/null 2>&1

# --- リポジトリ直下の generated/（generated/graphql.ts相当）は誤検知しない ---
RG188_TOPLEVEL_EXIT=0
(
  cd "$RG188_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG188_TOPLEVEL_GENERATED_FILE" >/dev/null 2>&1
)
RG188_TOPLEVEL_EXIT=$?
assert_exit_code "リポジトリ直下のgenerated/配下（長い1行）は誤検知しない（#188）" 0 "$RG188_TOPLEVEL_EXIT"

# --- --staged モード（git diff --cached --name-only相当のリポジトリ相対パス。
#     実際の run 経路そのもの）でも同様に許可される。pregenerated/ / generated-old/ の
#     ような本来ブロックされるべきfixtureは一緒にステージしない
#     （--stagedは全ステージ済みファイルの違反を集約して返すため、一緒にステージすると
#     このテストの意図（generated/自体の許可を見る）が別ファイルの違反で覆い隠される） ---
RG188_STAGED_EXIT=0
(
  cd "$RG188_TMP_REPO" || exit 1
  git add "$RG188_TOPLEVEL_GENERATED_FILE" "$RG188_TOPLEVEL_DUNDER_FILE" >/dev/null 2>&1
  bash "$CHECK_READABILITY_SCRIPT" --staged >/dev/null 2>&1
)
RG188_STAGED_EXIT=$?
assert_exit_code "--staged経由（実際の run 経路）でもリポジトリ直下のgenerated/は誤検知しない（#188）" 0 "$RG188_STAGED_EXIT"

# --- リポジトリ直下の __generated__/ も同様に誤検知しない ---
RG188_TOPLEVEL_DUNDER_EXIT=0
(
  cd "$RG188_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG188_TOPLEVEL_DUNDER_FILE" >/dev/null 2>&1
)
RG188_TOPLEVEL_DUNDER_EXIT=$?
assert_exit_code "リポジトリ直下の__generated__/配下（長い1行）は誤検知しない（#188）" 0 "$RG188_TOPLEVEL_DUNDER_EXIT"

# --- pregenerated/（先頭ディレクトリ名がgeneratedと完全一致しない）は誤って許可されない
#     （検出力を弱めていないことの担保） ---
RG188_PREGEN_EXIT=0
(
  cd "$RG188_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG188_PREGEN_FILE" >/dev/null 2>&1
)
RG188_PREGEN_EXIT=$?
assert_exit_code "pregenerated/は先頭一致に誤って一致せず引き続き検出される（検出力の維持・#188）" 2 "$RG188_PREGEN_EXIT"

# --- generated-old/（先頭ディレクトリ名がgeneratedと完全一致しない）も同様に誤って許可されない ---
RG188_GENOLD_EXIT=0
(
  cd "$RG188_TMP_REPO" || exit 1
  bash "$CHECK_READABILITY_SCRIPT" "$RG188_GENOLD_FILE" >/dev/null 2>&1
)
RG188_GENOLD_EXIT=$?
assert_exit_code "generated-old/は先頭一致に誤って一致せず引き続き検出される（検出力の維持・#188）" 2 "$RG188_GENOLD_EXIT"

# ---------------------------------------------------------------------------
# run が generator へ渡すプロンプト（Step 3/4）に、core/roles/generator.md が禁じる
# シェルのポーリングループ例を書き込んでいないことの回帰（issue #194）
#
# #192 の書き直しで、次ウェーブ再割当て時に Step 3 のプロンプトへ添える一文として
# `until grep -q ... done; do sleep 30; done` という具体例が紛れ込んだ。これは同じ差分の
# #189 対応が core/roles/generator.md に明記した「シェルの until ... do ... done のような
# ループ相当の待ち方を書かない（issue #140: 承認プロンプトを誘発する）」という禁止事項と
# 正面から衝突する。run のプロンプトは generator にとって「目の前の具体的な指示」であり、
# 抽象的なロール規定より優先されやすいため、一度紛れ込むと実害が大きい。
#
# 検査範囲は「generatorへ渡すプロンプトの記述」に限定する（run 自身が実行する正当なシェルの
# for ループ等まで誤検出しないため）。具体的には、generator 起動・再指示に関わる Step 3
# （Claude版はStep 4のレーン内ゲート確認も、Step 3のプロンプトに追記する一文の記述元として含む）
# の範囲だけを抽出して調べる。
# ---------------------------------------------------------------------------

echo "== run スキル: generatorへの指示にシェルのポーリングループ例を書かない（#194） =="

RG194_POLL_PATTERN='\b(until|while|for)\b.*\bdo\b.*\bdone\b'

RG194_CLAUDE_STEP_REGION="$(sed -n '/^### Step 3:/,/^### Step 5:/p' "${REPO_ROOT}/skills/run/SKILL.md")"
RG194_CLAUDE_HITS="$(echo "$RG194_CLAUDE_STEP_REGION" | grep -nE "$RG194_POLL_PATTERN" || true)"
if [ -z "$RG194_CLAUDE_HITS" ]; then
  pass "skills/run/SKILL.md: Step 3/4（generatorへ渡すプロンプトの記述範囲）にシェルのポーリングループ例が無い（#194）"
else
  fail "skills/run/SKILL.md: Step 3/4（generatorへ渡すプロンプトの記述範囲）にシェルのポーリングループ例が無い（#194）" \
    "$RG194_CLAUDE_HITS"
fi

RG194_CODEX_STEP_REGION="$(sed -n '/^### Step 3:/,/^### Step 4:/p' "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"
RG194_CODEX_HITS="$(echo "$RG194_CODEX_STEP_REGION" | grep -nE "$RG194_POLL_PATTERN" || true)"
if [ -z "$RG194_CODEX_HITS" ]; then
  pass "skills-codex/dev-workflow-run/SKILL.md: Step 3（generatorへ渡すプロンプトの記述範囲）にシェルのポーリングループ例が無い（#194）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: Step 3（generatorへ渡すプロンプトの記述範囲）にシェルのポーリングループ例が無い（#194）" \
    "$RG194_CODEX_HITS"
fi

# --- 今回の再発そのもの（`until ... done; do sleep 30; done`）も併せて固定する ---

if ! grep -Fq 'until grep -q' "${REPO_ROOT}/skills/run/SKILL.md"; then
  pass "skills/run/SKILL.md: #192由来の具体的な until ポーリング文言が残っていない（#194）"
else
  fail "skills/run/SKILL.md: #192由来の具体的な until ポーリング文言が残っていない（#194）"
fi

# ---------------------------------------------------------------------------
# 「0. 渡されたベースにHEADを合わせる」手順1（作業ツリーが空であることを確認する安全弁）の
# git status --short に --untracked-files=all が付いていることの回帰（issue #195）
#
# #193 は見送り時の作業ツリー復旧（上記H161の回帰テスト対象）には --untracked-files=all を
# 付けたが、実装着手前のベース合わせ手順1は素の `git status --short` のまま据え置かれた。
# status.showUntrackedFiles=no のローカル設定では出力が常に空になり、汚れた作業ツリーの上で
# 着手したうえ「空だった」という誤った証跡が残ってしまう（#193 と同質の失敗モード）。
# BASE_EVIDENCE_FILE 行に絞って検査し、H161（EVIDENCE_FILE = 見送り時の復旧）の対象と
# 混同しないようにする。
# ---------------------------------------------------------------------------

echo "== ベース合わせ手順1のgit status --shortに--untracked-files=allが付いている（#195） =="

for RG195_FILE in "core/roles/generator.md" "skills/run/SKILL.md" \
  "skills-codex/dev-workflow-run/SKILL.md" "agents/generator.md" "codex-agents/generator.toml"; do
  case "$RG195_FILE" in
    skills/run/SKILL.md) RG195_PATH="$RUN_SKILL_FLAT" ;;
    *)                   RG195_PATH="${REPO_ROOT}/${RG195_FILE}" ;;
  esac
  RG195_LINE="$(grep -n 'BASE_EVIDENCE_FILE' "$RG195_PATH" | grep -F 'git status --short' || true)"
  RG195_MISSING_FLAG="$(echo "$RG195_LINE" | grep -Fv 'git status --short --untracked-files=all' || true)"
  if [ -n "$RG195_LINE" ] && [ -z "$RG195_MISSING_FLAG" ]; then
    pass "${RG195_FILE}: ベース合わせ手順1のgit status --shortに--untracked-files=allが付いている（#195）"
  else
    fail "${RG195_FILE}: ベース合わせ手順1のgit status --shortに--untracked-files=allが付いている（#195）" \
      "$RG195_LINE"
  fi
done

# ---------------------------------------------------------------------------
# レビュー指摘対応時に「守るべき性質」の言語化を促す記述（issue #197）
#
# review issue は通常のウェーブループ（Step 1〜7）に載って処理されるため、対応する
# generator は run の手順書ではなく issue 本文を読む。そのため、この指示は run 側の
# 手順書だけでなく、R2 が作成する issue テンプレート自体に埋め込まれている必要がある。
# Claude / Codex 両方の run スキルで、テンプレートの文言が消えたら赤くなることを固定する。
#
# evaluator 側は core/references/review-checklist-correctness.md に対応する確認観点
# （#197「修正の妥当性」）を追加した。correctness 観点の evaluator が読む唯一の詳細
# チェックリストファイルであり、Claude/Codex 双方の evaluator 定義が
# `core/roles/evaluator.md`「観点（focus）」表を通じて共通で参照するため、
# アダプタ別の複製は不要である（本体に直接埋め込むと、観点未指定時にしか働かない
# チェックリスト構造と矛盾するため、`core/references/` 側に置く）。
# ---------------------------------------------------------------------------

echo "== レビュー指摘対応時に「守るべき性質」の言語化を促す記述がある（#197） =="

RG197_INVARIANT_PHRASE='この修正が守ろうとしている性質を1文で書くこと'

RG197_CLAUDE_HIT="$(grep -F "$RG197_INVARIANT_PHRASE" "${REPO_ROOT}/skills/run/references/review.md" || true)"
if [ -n "$RG197_CLAUDE_HIT" ]; then
  pass "skills/run/references/review.md: review issueテンプレートに性質の言語化を促す指示がある（#197）"
else
  fail "skills/run/references/review.md: review issueテンプレートに性質の言語化を促す指示がある（#197）"
fi

RG197_CODEX_HIT="$(grep -F "$RG197_INVARIANT_PHRASE" "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md" || true)"
if [ -n "$RG197_CODEX_HIT" ]; then
  pass "skills-codex/dev-workflow-run/SKILL.md: review issueテンプレートに性質の言語化を促す指示がある（#197）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: review issueテンプレートに性質の言語化を促す指示がある（#197）"
fi

# issueテンプレートに埋め込む以上、実際に `gh issue create` の heredoc（`## 対応時の指示`
# セクション）の中にあることを確認する。手順書の説明文にだけ書いて heredoc から漏れる
# 再発を防ぐ（#194と同種の「別ファイルに書いたつもりが本来の適用箇所から漏れる」失敗）。
RG197_CLAUDE_BODY_REGION="$(sed -n '/^gh issue create --label "task,review"/,/^BODY$/p' "${REPO_ROOT}/skills/run/references/review.md")"
if echo "$RG197_CLAUDE_BODY_REGION" | grep -Fq "$RG197_INVARIANT_PHRASE"; then
  pass "skills/run/references/review.md: 性質の言語化指示がissue本文のheredocの中にある（#197）"
else
  fail "skills/run/references/review.md: 性質の言語化指示がissue本文のheredocの中にある（#197）" \
    "$RG197_CLAUDE_BODY_REGION"
fi

RG197_CODEX_BODY_REGION="$(sed -n '/^gh issue create --label "task,review"/,/^BODY$/p' "${REPO_ROOT}/skills-codex/dev-workflow-run/SKILL.md")"
if echo "$RG197_CODEX_BODY_REGION" | grep -Fq "$RG197_INVARIANT_PHRASE"; then
  pass "skills-codex/dev-workflow-run/SKILL.md: 性質の言語化指示がissue本文のheredocの中にある（#197）"
else
  fail "skills-codex/dev-workflow-run/SKILL.md: 性質の言語化指示がissue本文のheredocの中にある（#197）" \
    "$RG197_CODEX_BODY_REGION"
fi

RG197_CHECKLIST_PHRASE='元の問題と同じ性質の欠陥を別の場所に作っていないか'

if grep -Fq "$RG197_CHECKLIST_PHRASE" "${REPO_ROOT}/core/references/review-checklist-correctness.md"; then
  pass "core/references/review-checklist-correctness.md: 修正の妥当性チェック項目がある（#197）"
else
  fail "core/references/review-checklist-correctness.md: 修正の妥当性チェック項目がある（#197）"
fi

# core/references/*.md は evaluator が起動時に自分で読むファイルであり、生成物
# （agents/evaluator.md・codex-agents/evaluator.toml）には束ねられない。フラット化ビュー
# （EVALUATOR_ROLE_FLAT / AGENT_EVALUATOR_FLAT / CODEX_AGENT_EVALUATOR_FLAT。冒頭で
# core/references/*.md を連結して作る）でも見えることを確認し、Claude/Codex 双方の
# evaluator が同じ観点表を経由して同じチェックリストに到達できることを固定する。
for RG197_FLAT_NAME in EVALUATOR_ROLE_FLAT AGENT_EVALUATOR_FLAT CODEX_AGENT_EVALUATOR_FLAT; do
  RG197_FLAT_PATH="${!RG197_FLAT_NAME}"
  if grep -Fq "$RG197_CHECKLIST_PHRASE" "$RG197_FLAT_PATH"; then
    pass "${RG197_FLAT_NAME}: 修正の妥当性チェック項目に到達できる（#197）"
  else
    fail "${RG197_FLAT_NAME}: 修正の妥当性チェック項目に到達できる（#197）"
  fi
done

# ---------------------------------------------------------------------------
# heredoc本文にdev-workflow内部のissue番号を埋め込んでいないこと（issue #198）
#
# R2（指摘のissue化）が作成するreview issueテンプレートに、dev-workflow自身のissue番号
# `#197` が heredoc 本文（`gh issue create --body` の中身）として埋め込まれ、そのまま
# 駆動先プロジェクトのissue本文として作成される事故があった（#198）。dev-workflowは
# 駆動先プロジェクトでSKILL.mdを実行するプラグインであり、駆動先リポジトリの`#197`は
# 無関係なissueを指す。GitHubはこれをリンクとしてレンダリングしてしまう。
#
# これは#197（「修正が同じ性質の欠陥を別の場所に作り直す」問題）の修正自身が同じ失敗を
# 犯した実例であるため、個別ケースの回帰テストではなく、`skills/`・`skills-codex/`配下の
# 全heredoc本文を機械的に走査する不変条件テストとして固定する（#198「併せて検討すること」）。
#
# heredocの区切りは全ファイルで`cat <<'BODY'`〜`^BODY$`の1種類のみ（事前調査で確認済み）。
# 判定対象はheredoc本文の中だけに限る。heredocの外側にある手順書側の説明文
# （`### 指摘対応時に「性質」を言語化させる（#197）`等）は、駆動先issue本文には漏れないため
# 対象外でよい（review.md「対応時の指示」節参照）。
#
# `#[0-9]+`（`#`の直後が数字）という固定issue番号のパターンだけを検査する。
# プレースホルダ（`#[epic番号]` / `#[番号]` / `#XX` 等）は`#`の直後が`[`や`X`であり
# 数字ではないため一致しない。`$ARGUMENTS`由来の動的な参照も数字を直接書かないため
# 一致しない。誤検出ゼロであることは、既存の全heredoc（epic/task issueテンプレート、
# スキップ済みタスクのコメント、PR本文）を対象に確認済み。
# ---------------------------------------------------------------------------

echo "== heredoc本文にdev-workflow内部のissue番号が埋め込まれていない（#198） =="

RG198_LEAK_DETAIL=""
for RG198_FILE in $(find "${REPO_ROOT}/skills" "${REPO_ROOT}/skills-codex" -name "*.md" | sort); do
  RG198_BODY_REGION="$(awk '/cat <<.BODY./{inblk=1; next} inblk && /^BODY$/{inblk=0; next} inblk' "$RG198_FILE")"
  [ -n "$RG198_BODY_REGION" ] || continue
  RG198_HIT="$(printf '%s\n' "$RG198_BODY_REGION" | grep -noE '#[0-9]+' || true)"
  if [ -n "$RG198_HIT" ]; then
    RG198_LEAK_DETAIL="${RG198_LEAK_DETAIL}${RG198_FILE}: ${RG198_HIT}
"
  fi
done

if [ -z "$RG198_LEAK_DETAIL" ]; then
  pass "skills/ skills-codex/: 全heredoc本文にdev-workflow内部のissue番号が埋め込まれていない（#198）"
else
  fail "skills/ skills-codex/: 全heredoc本文にdev-workflow内部のissue番号が埋め込まれていない（#198）" \
    "$RG198_LEAK_DETAIL"
fi
unset RG198_FILE RG198_BODY_REGION RG198_HIT RG198_LEAK_DETAIL

# ---------------------------------------------------------------------------
# 結果集計
# ---------------------------------------------------------------------------

echo ""
echo "== 結果: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped =="

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "失敗したケース:"
  for c in "${FAILED_CASES[@]}"; do
    echo "  - ${c}"
  done
  exit 1
fi

exit 0
