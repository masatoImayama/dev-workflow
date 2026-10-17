#!/bin/bash
# dev-workflow: 「クラウドか」「Docker が使えるか」「gh で GitHub に到達できるか」の
# 判定を一元化する共通ライブラリ（クラウド（Claude Desktop）対応・Task #268）
#
# クラウド対応では上記3つの判定を多数のスクリプト・スキルから参照する。同じ判定を
# 各所に書くと片方だけ直して食い違う事故が起きるため、正本をここに1つだけ置く。
#
# クラウドセッションの実測では `CLAUDE_CODE_REMOTE=true` /
# `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE=cloud_default` が設定されていた。
# `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE` は値の集合が未公開で、増えたときに判定が
# 壊れるため**判定には使わない**。診断表示用に値を返す関数だけ用意する。
#
# 使い方: このファイルを source すると以下の関数が使えるようになる。
#
#   dev_workflow_is_remote
#     真: CLAUDE_CODE_REMOTE が "true"
#
#   dev_workflow_docker_available
#     真: `command -v docker` が見つかり、かつ `docker info` が成功する
#
#   dev_workflow_gh_available
#     真: `gh auth status` が成功し、かつ軽量な API 疎通（`gh api rate_limit`）が成功する
#
#   dev_workflow_remote_environment_type
#     CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE の値をそのまま返す（診断表示専用。判定には使わない）
#
# docker / gh の呼び出しはデーモン・ネットワークに出るため、呼ぶたびに実行すると
# hook の実行時間を押し上げる。そのため結果はプロセス内（グローバル変数）でキャッシュし、
# 2回目以降の呼び出しは実プロセスを起動しない。
#
# 上書き環境変数（テストと、判定が外れた環境での逃げ道を同じ仕組みで賄う）:
#
#   DEV_WORKFLOW_FORCE_REMOTE
#     空文字以外が設定されていれば dev_workflow_is_remote の判定を上書きする。
#     "true" または "1" なら真、それ以外の値（"false" / "0" など）なら偽として扱う。
#
#   DEV_WORKFLOW_DOCKER_UNAVAILABLE
#     空文字以外が設定されていれば（値の内容は問わない）dev_workflow_docker_available を
#     強制的に偽にする。実際の docker を呼ばない。
#
#   DEV_WORKFLOW_GH_UNAVAILABLE
#     空文字以外が設定されていれば（値の内容は問わない）dev_workflow_gh_available を
#     強制的に偽にする。実際の gh を呼ばない。
#
# これら上書き変数は、キャッシュより優先して毎回評価する（同一プロセス内で後から
# 設定されても即座に効く。実プロセスを起動する前の分岐なので、キャッシュの有無に
# コストを払わない）。
#
# scripts/lib/ の既存ファイル（marker-root.sh 等）の作法に倣い、source されただけでは
# 何もしない（docker / gh は関数が呼ばれるまで起動しない）。
#
# このファイルは複数のスクリプト・スキルから source される想定。

set -u

_DEV_WORKFLOW_DOCKER_AVAILABLE_CACHE=""
_DEV_WORKFLOW_GH_AVAILABLE_CACHE=""

dev_workflow_is_remote() {
  if [ -n "${DEV_WORKFLOW_FORCE_REMOTE:-}" ]; then
    case "$DEV_WORKFLOW_FORCE_REMOTE" in
      true | 1) return 0 ;;
      *) return 1 ;;
    esac
  fi

  [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]
}

dev_workflow_remote_environment_type() {
  printf '%s' "${CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE:-}"
}

dev_workflow_docker_available() {
  if [ -n "${DEV_WORKFLOW_DOCKER_UNAVAILABLE:-}" ]; then
    return 1
  fi

  if [ -z "$_DEV_WORKFLOW_DOCKER_AVAILABLE_CACHE" ]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      _DEV_WORKFLOW_DOCKER_AVAILABLE_CACHE="0"
    else
      _DEV_WORKFLOW_DOCKER_AVAILABLE_CACHE="1"
    fi
  fi

  return "$_DEV_WORKFLOW_DOCKER_AVAILABLE_CACHE"
}

dev_workflow_gh_available() {
  if [ -n "${DEV_WORKFLOW_GH_UNAVAILABLE:-}" ]; then
    return 1
  fi

  if [ -z "$_DEV_WORKFLOW_GH_AVAILABLE_CACHE" ]; then
    if gh auth status >/dev/null 2>&1 && gh api rate_limit >/dev/null 2>&1; then
      _DEV_WORKFLOW_GH_AVAILABLE_CACHE="0"
    else
      _DEV_WORKFLOW_GH_AVAILABLE_CACHE="1"
    fi
  fi

  return "$_DEV_WORKFLOW_GH_AVAILABLE_CACHE"
}
