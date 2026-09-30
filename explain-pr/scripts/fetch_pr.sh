#!/usr/bin/env bash
# PR の解説とレビューに必要な材料を 1 ディレクトリに集める。GitHub には書き込まない。
#
#   bash fetch_pr.sh <PR URL | owner/repo#N> [出力先ディレクトリ]
#
# 出力:
#   pr.json               PR 本体（title, body, base/head, files, commits, reviews, comments ...）
#   diff.patch            差分
#   review_comments.json  インラインレビューコメント
#   issue-<N>.json        PR に紐づく Issue（closingIssuesReferences と本文中の #N）
#   base/<path>           変更ファイルの base ブランチ側の全文（大元の機能を読むため）
#   history/<path>.log    変更ファイルの base ブランチ上の直近コミット履歴
set -euo pipefail

in="${1:-}"
if [[ "$in" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; num="${BASH_REMATCH[3]}"
elif [[ "$in" =~ ^([^/]+)/([^#]+)#([0-9]+)$ ]]; then
  owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; num="${BASH_REMATCH[3]}"
else
  echo "usage: $0 <https://github.com/OWNER/REPO/pull/N | OWNER/REPO#N> [outdir]" >&2
  exit 1
fi

out="${2:-${TMPDIR:-/tmp}/explain-pr}/$owner-$repo-$num"
mkdir -p "$out/base" "$out/history"
R="$owner/$repo"

gh pr view "$num" -R "$R" \
  --json number,title,body,state,url,author,createdAt,mergedAt,labels,reviewDecision,\
baseRefName,headRefName,baseRefOid,headRefOid,closingIssuesReferences,commits,files,reviews,comments \
  > "$out/pr.json"
gh pr diff "$num" -R "$R" > "$out/diff.patch"
gh api "repos/$R/pulls/$num/comments" --paginate > "$out/review_comments.json"

# 紐づく Issue: closingIssuesReferences + 本文中の #N
{
  jq -r '.closingIssuesReferences[]?.number' "$out/pr.json"
  jq -r '.body // ""' "$out/pr.json" | grep -oE '(^|[^&])#[0-9]+' | grep -oE '[0-9]+'
} | sort -un | while read -r i; do
  gh issue view "$i" -R "$R" --json number,title,body,state,labels,comments \
    > "$out/issue-$i.json" 2>/dev/null || rm -f "$out/issue-$i.json"
done

# 変更ファイルの base 側全文と履歴
base=$(jq -r .baseRefOid "$out/pr.json")
jq -r '.files[].path' "$out/pr.json" | while read -r p; do
  mkdir -p "$out/base/$(dirname "$p")" "$out/history/$(dirname "$p")"
  gh api "repos/$R/contents/$p?ref=$base" --jq '.content' 2>/dev/null \
    | base64 --decode > "$out/base/$p" 2>/dev/null || rm -f "$out/base/$p"   # 新規追加ファイルは base に無い
  gh api "repos/$R/commits?sha=$base&path=$p&per_page=10" \
    --jq '.[] | "\(.sha[0:7]) \(.commit.author.date[0:10]) \(.commit.message | split("\n")[0])"' \
    > "$out/history/$p.log" 2>/dev/null || true
done

echo "$out"
