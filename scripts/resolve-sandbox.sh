#!/bin/bash
# dev-workflow: サンドボックス設定の解決（ベンダー中立）
#
# Claude Code の plugin userConfig は他CLIに相当物がないため、設定は環境変数を
# 正本として解決する。Claude Code 側のアダプタが userConfig の値を環境変数に
# 流し込む前提で、スクリプトとスキルはこのスクリプトの出力だけを見る。
#
# 使い方:
#   eval "$(bash scripts/resolve-sandbox.sh)"          # 変数として取り込む
#   bash scripts/resolve-sandbox.sh --print            # 人間向けに表示する
#
# 出力する変数:
#   DEV_WORKFLOW_SANDBOX_MODE       dockerfile | compose | none
#   DEV_WORKFLOW_SANDBOX_IMAGE      docker run に渡すイメージ名（compose時は空）
#   DEV_WORKFLOW_SANDBOX_COMPOSE    使用する compose ファイル（dockerfile時は空）
#   DEV_WORKFLOW_SANDBOX_DOCKERFILE 使用する Dockerfile（compose時・DEV_WORKFLOW_DOCKER_IMAGE指定時は空）
#   DEV_WORKFLOW_SANDBOX_CONTEXT    docker build のビルドコンテキスト（compose時・
#                                   DEV_WORKFLOW_DOCKER_IMAGE指定時は空）
#
# 参照する環境変数（いずれも任意。未設定なら既定の探索に従う）:
#   DEV_WORKFLOW_DOCKER_IMAGE          既存イメージを使う（ビルドしない。タグに hash は付けない）
#   DEV_WORKFLOW_DOCKER_COMPOSE_FILE   使用する compose ファイルのパス
#   DEV_WORKFLOW_DOCKERFILE            使用する Dockerfile のパス（既定: Dockerfile.dev）
#   DEV_WORKFLOW_DOCKER_BUILD_CONTEXT  docker build のビルドコンテキスト（明示指定。最優先）
#   DEV_WORKFLOW_SANDBOX_HOME          規約パスのベースディレクトリ
#                                     （既定: ${HOME}/.claude/dev-workflow/sandbox）
#
# 解決順（issue #120。上から順に、最初に成立したものを採用する）:
#   1. DEV_WORKFLOW_DOCKER_IMAGE が非空                                    -> mode=dockerfile（既存イメージ）
#   2. ${DEV_WORKFLOW_DOCKERFILE:-Dockerfile.dev} が存在                   -> mode=dockerfile
#   3. ${DEV_WORKFLOW_DOCKER_COMPOSE_FILE:-docker-compose.dev.yml} が存在  -> mode=compose
#   4. <SANDBOX_HOME>/<repo>/Dockerfile.dev が存在                         -> mode=dockerfile（規約パス・新規）
#   5. <SANDBOX_HOME>/<repo>/docker-compose.dev.yml が存在                 -> mode=compose（規約パス・新規）
#   6. 上記いずれも不成立                                                  -> mode=none
#
# 1〜3 が成立する限り既存挙動は変わらない（完全後方互換）。4/5 は 2 と 3 がともに
# 外れた場合にのみ評価される、リポジトリを汚さない供給経路のフォールバックである。
# <repo> はイメージタグに使う REPO と同一の解決方法（git-common-dir 由来。worktree の
# basename には依存しない）。<SANDBOX_HOME> は ${DEV_WORKFLOW_SANDBOX_HOME:-${HOME}/.claude/dev-workflow/sandbox}
# で、HOME も DEV_WORKFLOW_SANDBOX_HOME も未設定/空なら 4/5 はスキップする。
#
# ビルドコンテキストの解決順（仕様書 4.2）:
#   1. DEV_WORKFLOW_DOCKER_BUILD_CONTEXT が非空 -> その値（正規化して採用）
#   2. 解決した Dockerfile がリポジトリルート配下にある -> dirname(Dockerfile)（既存挙動）
#   3. リポジトリルート配下に無いがカレントディレクトリ配下にある -> dirname(Dockerfile)
#      （sandbox-exec.sh がカレントをマウント元にするフォールバック経路と揃える）
#   4. それ以外（規約パス等） -> リポジトリルート
#
# イメージタグの hash について（仕様書 4.7）:
#   Dockerfile.dev からビルドする場合、タグは dev-sandbox:<repo>-<hash8> とする。
#   hash8 は `git hash-object <Dockerfile>` の先頭8文字（git は必須依存なので追加依存が無い）。
#   Dockerfile の内容だけを見るため、COPY 対象（go.mod 等）の変更は検知できない。
#   その場合は sandbox-exec.sh の --rebuild で明示的に再ビルドする。

set -u

PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

DOCKERFILE="${DEV_WORKFLOW_DOCKERFILE:-Dockerfile.dev}"
COMPOSE_FILE="${DEV_WORKFLOW_DOCKER_COMPOSE_FILE:-docker-compose.dev.yml}"

MODE="none"
IMAGE=""
USE_COMPOSE=""
USE_DOCKERFILE=""
BUILD_CONTEXT=""
CONVENTION_USED=""

# リポジトリ名（REPO）とリポジトリルート（REPO_ROOT_ABS）を先に解決しておく。
# worktree の basename（agent-xxxx 等）を使うと worktree ごとに別タグ/別パスとなり、
# 既にビルド済みのイメージ・規約パスのファイルを取り逃す。
# sandbox-exec.sh の PROJECT（basename(REPO_ROOT)）と同じ解決方法にすること。
GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$GIT_COMMON" ]; then
  REPO_ROOT_ABS="$(dirname "$GIT_COMMON")"
  REPO="$(basename "$REPO_ROOT_ABS")"
else
  REPO_ROOT_ABS=""
  REPO="$(basename "$(pwd)")"
fi

# 規約パス（SANDBOX_HOME/<repo>/...）の候補。HOME も DEV_WORKFLOW_SANDBOX_HOME も
# 未設定/空なら空のままにし、4/5 の判定を確実にスキップする。
SANDBOX_HOME="${DEV_WORKFLOW_SANDBOX_HOME:-}"
if [ -z "$SANDBOX_HOME" ] && [ -n "${HOME:-}" ]; then
  SANDBOX_HOME="${HOME}/.claude/dev-workflow/sandbox"
fi

CONVENTION_DOCKERFILE=""
CONVENTION_COMPOSE=""
if [ -n "$SANDBOX_HOME" ]; then
  CONVENTION_DOCKERFILE="${SANDBOX_HOME}/${REPO}/Dockerfile.dev"
  CONVENTION_COMPOSE="${SANDBOX_HOME}/${REPO}/docker-compose.dev.yml"
fi

# ビルドコンテキストの正規化（仕様書 4.2）。Windows では同じ実体が
# `/c/Users/...` と `C:/Users/...` の2表現になるため、比較前に `pwd -W` で正規化する
# （sandbox-exec.sh:139 の HOST_ROOT と同じ作法）。
normalize_dir() {
  # normalize_dir <dir>  正規化した絶対パスを返す。cd できなければ入力をそのまま返す。
  local dir="$1"
  ( cd "$dir" 2>/dev/null && { pwd -W 2>/dev/null || pwd; } ) || printf '%s' "$dir"
}

resolve_build_context() {
  # resolve_build_context <dockerfile>
  local dockerfile="$1"
  local dockerfile_dir
  dockerfile_dir="$(normalize_dir "$(dirname "$dockerfile")")"

  if [ -n "${DEV_WORKFLOW_DOCKER_BUILD_CONTEXT:-}" ]; then
    normalize_dir "$DEV_WORKFLOW_DOCKER_BUILD_CONTEXT"
    return 0
  fi

  if [ -n "$REPO_ROOT_ABS" ]; then
    local repo_root_norm
    repo_root_norm="$(normalize_dir "$REPO_ROOT_ABS")"
    case "$dockerfile_dir" in
      "$repo_root_norm"|"${repo_root_norm}"/*)
        # Dockerfile はリポジトリルート配下にある -> 既存挙動（dirname のまま）
        printf '%s' "$dockerfile_dir"
        return 0
        ;;
      *)
        # リポジトリルート配下に無い。ただしカレントディレクトリ配下にある場合は
        # そちらを使う。sandbox-exec.sh はカレントがリポジトリルート外のとき
        # （リポジトリ外に作られた兄弟 worktree 等）カレントをマウント元にするため、
        # ここでリポジトリルートを返すとマウント元とビルドコンテキストが食い違い、
        # COPY がメインリポ側の内容を拾ってしまう。
        local cur_norm
        cur_norm="$(normalize_dir "$(pwd)")"
        case "$dockerfile_dir" in
          "$cur_norm"|"${cur_norm}"/*)
            printf '%s' "$dockerfile_dir"
            return 0
            ;;
        esac
        # カレント配下でもない（規約パス等）-> リポジトリルートを使う
        printf '%s' "$repo_root_norm"
        return 0
        ;;
    esac
  fi

  # git情報が取れない場合は判定できないため既存挙動にフォールバックする。
  printf '%s' "$dockerfile_dir"
}

# 明示指定されたイメージが最優先（ビルドを省略できる。hash は付けない）
if [ -n "${DEV_WORKFLOW_DOCKER_IMAGE:-}" ]; then
  MODE="dockerfile"
  IMAGE="$DEV_WORKFLOW_DOCKER_IMAGE"
elif [ -f "$DOCKERFILE" ]; then
  MODE="dockerfile"
  USE_DOCKERFILE="$DOCKERFILE"
elif [ -f "$COMPOSE_FILE" ]; then
  MODE="compose"
  USE_COMPOSE="$COMPOSE_FILE"
elif [ -n "$CONVENTION_DOCKERFILE" ] && [ -f "$CONVENTION_DOCKERFILE" ]; then
  MODE="dockerfile"
  USE_DOCKERFILE="$CONVENTION_DOCKERFILE"
  CONVENTION_USED="$CONVENTION_DOCKERFILE"
elif [ -n "$CONVENTION_COMPOSE" ] && [ -f "$CONVENTION_COMPOSE" ]; then
  MODE="compose"
  USE_COMPOSE="$CONVENTION_COMPOSE"
  CONVENTION_USED="$CONVENTION_COMPOSE"
fi

if [ "$MODE" = "dockerfile" ] && [ -n "$USE_DOCKERFILE" ]; then
  # hash8: Dockerfile の内容から決まるタグ接尾辞。内容が同じなら worktree が
  # 違ってもタグが変わらない。内容が変われば自動的に別タグ（≒別イメージ）になる。
  HASH8="$(git hash-object "$USE_DOCKERFILE" 2>/dev/null | cut -c1-8)"
  if [ -n "$HASH8" ]; then
    IMAGE="dev-sandbox:${REPO}-${HASH8}"
  else
    # git hash-object が使えない異常系のみのフォールバック（通常は到達しない）。
    IMAGE="dev-sandbox:${REPO}"
  fi

  BUILD_CONTEXT="$(resolve_build_context "$USE_DOCKERFILE")"
fi

if [ "$PRINT" -eq 1 ]; then
  case "$MODE" in
    dockerfile)
      if [ -n "$USE_DOCKERFILE" ]; then
        if [ -n "$CONVENTION_USED" ]; then
          echo "サンドボックス: 規約パス ${USE_DOCKERFILE} をビルドして ${IMAGE} として使用（ビルドコンテキスト: ${BUILD_CONTEXT}）"
        else
          echo "サンドボックス: ${USE_DOCKERFILE} をビルドして ${IMAGE} として使用（ビルドコンテキスト: ${BUILD_CONTEXT}）"
        fi
      else
        echo "サンドボックス: 既存イメージ ${IMAGE} を使用（DEV_WORKFLOW_DOCKER_IMAGE 指定）"
      fi
      ;;
    compose)
      if [ -n "$CONVENTION_USED" ]; then
        echo "サンドボックス: 規約パス ${USE_COMPOSE} を使用"
      else
        echo "サンドボックス: ${USE_COMPOSE} を使用"
      fi
      ;;
    none)
      if [ -n "$SANDBOX_HOME" ]; then
        echo "サンドボックス: 未設定（${DOCKERFILE} も ${COMPOSE_FILE} も ${SANDBOX_HOME}/${REPO}/ 配下も見つかりません）"
      else
        echo "サンドボックス: 未設定（${DOCKERFILE} も ${COMPOSE_FILE} も見つかりません）"
      fi
      ;;
  esac
  exit 0
fi

# eval で取り込む呼び出し側（sandbox-exec.sh, check-repo-hygiene.sh）が空白等を
# 含む値（$HOME や リポジトリルートに空白がある環境の規約パス等）で分割・誤解釈
# しないよう、%q でシェルクォートして出力する（issue #132）。
printf 'DEV_WORKFLOW_SANDBOX_MODE=%q\n'       "$MODE"
printf 'DEV_WORKFLOW_SANDBOX_IMAGE=%q\n'      "$IMAGE"
printf 'DEV_WORKFLOW_SANDBOX_COMPOSE=%q\n'    "$USE_COMPOSE"
printf 'DEV_WORKFLOW_SANDBOX_DOCKERFILE=%q\n' "$USE_DOCKERFILE"
printf 'DEV_WORKFLOW_SANDBOX_CONTEXT=%q\n'    "$BUILD_CONTEXT"
