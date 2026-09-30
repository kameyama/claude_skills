#!/usr/bin/env bash
# main を最新化する。複数の Claude セッションが同時に走っても壊れないことを最優先にする。
#
# やること
#   1. origin を fetch して origin/main を最新にする（どの作業ツリーの中身も変えない）
#   2. ローカル main を、安全に早送りできるときだけ早送りする
#
# やらないこと（他セッションの作業を壊す操作は一切しない）
#   git pull / git reset --hard / ブランチ切り替え / stash / マージコミットの作成
#   自分以外の作業ツリーが checkout しているブランチへの書き込み
#
# 終了コードは常に 0。ネットワーク断や競合でセッションを止めないため、
# 失敗は標準出力のメッセージで伝える。

set -uo pipefail

FETCH_MAX_AGE=${SYNC_MAIN_FETCH_MAX_AGE:-300} # 秒。これより新しい fetch は省略する
LOCK_TTL=${SYNC_MAIN_LOCK_TTL:-120}           # 秒。これを超えたロックは死骸とみなす

say() { echo "sync-main: $*"; }

now() { date +%s; }

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# 「今どの作業ツリーにいるか」が「ローカル main を触ってよいか」の判定を左右するので、
# カレントディレクトリを優先する。CLAUDE_PROJECT_DIR は worktree セッションでも
# 元のプロジェクトルートを指すため、これを使うと他セッションの作業ツリーを
# 自分のものと誤認して早送りしてしまう。
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  say "git リポジトリではないので何もしない"
  exit 0
fi

# ロックと fetch の鮮度は全作業ツリーで共有したいので、共通の .git 配下に置く
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" && pwd)
LOCK="$GIT_COMMON/sync-main.lock"

# mkdir は atomic なので、これだけで多重起動を弾ける。
# 取れなければ「他のセッションが今まさに同期中」なので、待たずに諦めるのが安全。
acquire_lock() {
  mkdir "$LOCK" 2>/dev/null && return 0

  local born age
  born=$(mtime "$LOCK") || return 1
  age=$(($(now) - ${born:-0}))
  if [ "$age" -gt "$LOCK_TTL" ]; then
    rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null && return 0
  fi
  return 1
}

fetch_age() {
  local head="$GIT_COMMON/FETCH_HEAD" born
  [ -f "$head" ] || { echo 999999; return; }
  born=$(mtime "$head")
  echo $(($(now) - ${born:-0}))
}

# main を checkout している作業ツリーのパス（無ければ空）
main_worktree() {
  git worktree list --porcelain |
    awk '/^worktree /{wt=substr($0,10)} /^branch refs\/heads\/main$/{print wt; exit}'
}

short() { git rev-parse --short "$1" 2>/dev/null; }

if ! acquire_lock; then
  say "別のセッションが同期中なのでスキップした（origin/main: $(short origin/main)）"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# --- 1. origin/main の更新 ------------------------------------------------
# remote-tracking ref を書き換えるだけで、どの作業ツリーのファイルも変わらない。

if [ "${1:-}" != "--force" ] && [ "$(fetch_age)" -lt "$FETCH_MAX_AGE" ]; then
  say "直近 ${FETCH_MAX_AGE} 秒以内に fetch 済みのため省略した"
elif git fetch --prune --quiet origin 2>/dev/null; then
  say "origin を fetch した"
else
  say "fetch に失敗した。origin/main が古いままの可能性がある"
fi

if ! git rev-parse --verify --quiet origin/main >/dev/null; then
  say "origin/main が無いリポジトリなので、以降はスキップする"
  exit 0
fi

REMOTE=$(git rev-parse origin/main)
say "origin/main = $(short origin/main)"

# --- 2. ローカル main の早送り（安全なときだけ） --------------------------

if ! git rev-parse --verify --quiet main >/dev/null; then
  say "ローカル main は無い。origin/main を基点に使う"
  exit 0
fi

LOCAL=$(git rev-parse main)

if [ "$LOCAL" = "$REMOTE" ]; then
  say "ローカル main は origin/main と同一"
  exit 0
fi

# origin/main の祖先でない = ローカル main に独自コミットがある。
# 早送りでは解消できないので触らない（巻き戻すと他セッションの作業が消える）。
if ! git merge-base --is-ancestor main origin/main; then
  say "ローカル main に origin/main へ含まれないコミットがある。早送りできないので触らない"
  exit 0
fi

WT=$(main_worktree)
HERE=$(git rev-parse --show-toplevel)

if [ -z "$WT" ]; then
  # どの作業ツリーも main を checkout していない。
  # ref だけの早送りなので、誰の作業ファイルにも触れない。
  if git fetch --quiet origin main:main 2>/dev/null; then
    say "ローカル main を $(short main) へ早送りした"
  else
    say "ローカル main の早送りに失敗した。origin/main を基点に使う"
  fi
elif [ "$WT" = "$HERE" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    say "main を checkout 中だが作業ツリーが汚れている。早送りしない"
  elif [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
    say "main はこの作業ツリーに属するが HEAD が main ではない。早送りしない"
  elif git merge --ff-only --quiet origin/main 2>/dev/null; then
    say "main を $(short main) へ早送りした"
  else
    say "早送りに失敗した。origin/main を基点に使う"
  fi
else
  say "ローカル main は別の作業ツリー ($WT) が checkout 中。触らない"
fi

say "新しいブランチは origin/main から切ること: git switch -c <branch> origin/main"
