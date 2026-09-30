#!/usr/bin/env bash
# sync_main.sh が「他セッションの作業を壊さない」ことを検証する。
# 使い捨てリポジトリだけを触り、実在のリポジトリには一切触れない。
#
#   bash ~/.claude/skills/sync-main/tests/test_sync_main.sh
#
# 落ちたら sync_main.sh の安全性が壊れている。直すまで使わない。

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/sync_main.sh"
T="${TMPDIR:-/tmp}/syncmain-test-$$"
rm -rf "$T"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

g() { git -c user.email=t@t -c user.name=t "$@"; }

# スクリプトは「今いる作業ツリー」で判断するので、必ず cd して呼ぶ。
# CLAUDE_PROJECT_DIR が漏れて実リポジトリを触らないよう明示的に潰す。
run() { (cd "$1" && CLAUDE_PROJECT_DIR='' bash "$SCRIPT" --force 2>&1); }

setup_work() { # $1 = 名前。origin より 1 コミット遅れた main を持つクローンを作る
  g clone -q "$T/origin.git" "$T/$1"
  g -C "$T/$1" reset -q --hard HEAD~1
}

pass=0
fail=0
check() { # $1 = ラベル, $2 = 期待（部分一致）, $3 = 実際
  if echo "$3" | grep -q -- "$2"; then
    echo "  ✅ $1"
    pass=$((pass + 1))
  else
    echo "  ❌ $1 — 期待:「$2」"
    while IFS= read -r line; do echo "     $line"; done <<<"$3"
    fail=$((fail + 1))
  fi
}

# --- 疑似 origin（main に c1, c2） ---
g init -q --bare "$T/origin.git"
g clone -q "$T/origin.git" "$T/up" 2>/dev/null
g -C "$T/up" commit -q --allow-empty -m c1
g -C "$T/up" branch -M main
g -C "$T/up" push -q origin main
g -C "$T/up" commit -q --allow-empty -m c2
g -C "$T/up" push -q origin main

echo "### CASE 1: 自分の作業ツリーが main を checkout・クリーン → 早送りする"
setup_work w1
OUT=$(run "$T/w1")
check "早送りした" "早送りした" "$OUT"
check "main が origin/main に一致" "$(g -C "$T/w1" rev-parse origin/main)" "$(g -C "$T/w1" rev-parse main)"

echo "### CASE 2: main を checkout 中だが作業ツリーが汚れている → 触らない"
setup_work w2
BEFORE=$(g -C "$T/w2" rev-parse main)
echo dirty >"$T/w2/dirty.txt"
OUT=$(run "$T/w2")
check "早送りしないと報告" "作業ツリーが汚れている" "$OUT"
check "main が動いていない" "$BEFORE" "$(g -C "$T/w2" rev-parse main)"
check "未コミットの変更が残っている" "dirty" "$(cat "$T/w2/dirty.txt")"

echo "### CASE 3: 別の作業ツリーが main を checkout 中 → 触らない"
setup_work w3
g -C "$T/w3" worktree add -q -b feat/x "$T/w3-feat"
BEFORE=$(g -C "$T/w3" rev-parse main)
OUT=$(run "$T/w3-feat")
check "別作業ツリーを検出して触らない" "別の作業ツリー" "$OUT"
check "main が動いていない" "$BEFORE" "$(g -C "$T/w3" rev-parse main)"

echo "### CASE 4: main をどこも checkout していない → ref だけ早送りする"
setup_work w4
g -C "$T/w4" switch -q -c other
BEFORE_HEAD=$(g -C "$T/w4" rev-parse HEAD)
OUT=$(run "$T/w4")
check "早送りした" "早送りした" "$OUT"
check "main が origin/main に一致" "$(g -C "$T/w4" rev-parse origin/main)" "$(g -C "$T/w4" rev-parse main)"
check "HEAD(other) は動いていない" "$BEFORE_HEAD" "$(g -C "$T/w4" rev-parse HEAD)"

echo "### CASE 5: ローカル main に独自コミットがある → 巻き戻さない"
setup_work w5
g -C "$T/w5" commit -q --allow-empty -m local-only
BEFORE=$(g -C "$T/w5" rev-parse main)
OUT=$(run "$T/w5")
check "早送り不可と報告" "早送りできないので触らない" "$OUT"
check "独自コミットが消えていない" "$BEFORE" "$(g -C "$T/w5" rev-parse main)"

echo "### CASE 6: ロックが他セッションに握られている → 待たずにスキップ"
setup_work w6
mkdir "$T/w6/.git/sync-main.lock"
BEFORE=$(g -C "$T/w6" rev-parse main)
OUT=$(run "$T/w6")
check "スキップと報告" "別のセッションが同期中" "$OUT"
check "main が動いていない" "$BEFORE" "$(g -C "$T/w6" rev-parse main)"
check "他人のロックを消していない" "yes" "$([ -d "$T/w6/.git/sync-main.lock" ] && echo yes || echo no)"

echo "### CASE 7: 古いロック(TTL超過)は死骸として奪う"
setup_work w7
mkdir "$T/w7/.git/sync-main.lock"
touch -t 202001010000 "$T/w7/.git/sync-main.lock"
OUT=$(run "$T/w7")
check "奪って同期した" "早送りした" "$OUT"
check "ロックを解放した" "no" "$([ -d "$T/w7/.git/sync-main.lock" ] && echo yes || echo no)"

echo "### CASE 8: 同時起動 5 本 → 誰も壊さず、全部 exit 0"
setup_work w8
for i in 1 2 3 4 5; do
  (
    run "$T/w8" >"$T/out.$i" 2>&1
    echo $? >"$T/rc.$i"
  ) &
done
wait
check "全プロセスが exit 0" "^0 $" "$(cat "$T"/rc.* | sort -u | tr '\n' ' ')"
check "main が origin/main に一致" "$(g -C "$T/w8" rev-parse origin/main)" "$(g -C "$T/w8" rev-parse main)"
check "ロックが残っていない" "no" "$([ -d "$T/w8/.git/sync-main.lock" ] && echo yes || echo no)"

echo "### CASE 9: origin に到達できない → exit 0 で報告のみ。既知の状態を壊さない"
g clone -q "$T/origin.git" "$T/w9"
g -C "$T/w9" remote set-url origin "$T/does-not-exist.git"
echo wip >"$T/w9/wip.txt"
BEFORE=$(g -C "$T/w9" rev-parse main)
OUT=$(run "$T/w9")
RC=$?
check "exit 0" "^0$" "$RC"
check "fetch 失敗を報告" "fetch に失敗した" "$OUT"
check "main が動いていない" "$BEFORE" "$(g -C "$T/w9" rev-parse main)"
check "未コミットの変更が残っている" "wip" "$(cat "$T/w9/wip.txt")"

echo "### CASE 10: fetch 失敗時も、取得済み origin/main への早送りは行う（コミットは失わない）"
setup_work w10
g -C "$T/w10" remote set-url origin "$T/does-not-exist.git"
CACHED=$(g -C "$T/w10" rev-parse origin/main)
OUT=$(run "$T/w10")
check "fetch 失敗を報告" "fetch に失敗した" "$OUT"
check "取得済み origin/main までは早送りする" "$CACHED" "$(g -C "$T/w10" rev-parse main)"

echo
echo "=== pass=$pass fail=$fail ==="
[ "$fail" -eq 0 ]
