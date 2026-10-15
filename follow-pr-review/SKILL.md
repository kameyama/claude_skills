---
name: follow-pr-review
description: 自分が PR に付けたレビュー指摘のその後を確かめる。スレッドの返信と PR の最新の head を読み、指摘に書いた resolve の条件を満たしたスレッドを resolve する。満たしていなければ状況を報告し、返信の下書きを出す。依頼があれば、自分の指摘がすべて resolve された PR を approve する。「コメントを確認して」「指摘が直ったか見て」「resolve して」「approve して」「指摘を監視して」「/follow-pr-review」で使う。
argument-hint: "<PR URL | OWNER/REPO#123>"
---

# follow-pr-review

**返信は作者の主張であって、修正の事実ではない。resolve の条件は最新の head で確かめる。**

対象は**自分が起点のスレッドだけ**。他人の指摘のスレッドは読むだけにし、返信も resolve もしない。
resolve は指摘したレビュアーが行うものだから。

指摘の本文は post-pr-review の書式（1 行目が `**重要度｜種別**`、末尾が `**resolve の条件:**`）を前提にする。

## Step 1: スレッドと head を取る

```bash
gh api user --jq .login
```

```bash
gh api graphql -F owner=OWNER -F repo=REPO -F number=N -f query='
query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){
  state headRefOid
  reviewThreads(first:100){nodes{id isResolved isOutdated path line originalLine
    comments(first:50){nodes{databaseId author{login} createdAt body originalCommit{oid}}}}}}}}' > "<スクラッチパッド>/threads-N.json"
```

`"reviewThreads"` が含まれていなければ取得失敗として止まる。

先頭コメントの `author.login` が自分で、`isResolved` が false のスレッドだけを対象にする。対象が無ければ「確認対象なし」と報告して終わる。

## Step 2: スレッドごとに条件を照合する

1. 先頭コメントから `**resolve の条件:**` の行を読む。条件の行が無い指摘は、本文の「提案」を条件とみなす
2. 先頭コメント以降の返信を読む。作者が何をした（する）と言っているかを掴む
3. **最新の head で事実を確かめる。** 指摘を付けたコミット（先頭コメントの `originalCommit.oid`）からの差分を読み、指摘した箇所のファイルを head で読む

```bash
gh api repos/OWNER/REPO/compare/<originalCommit>...<headRefOid> --jq '.files[] | {filename,status,patch}'
```

```bash
gh api "repos/OWNER/REPO/contents/<path>?ref=<headRefOid>" --jq .content | base64 -d
```

`isOutdated` が true でも、修正済みとは限らない。行が動いただけのこともあるので、head で中身を見る。

## Step 3: 判定する

| 判定 | 基準 | 行動 |
|---|---|---|
| 満たした | 条件に書いたことが head に入っている | resolve する（Step 4） |
| 合意待ち | 要議論の指摘で、作者が方針を示したが自分がまだ同意していない | ユーザーに方針を見せて判断を仰ぐ。resolve しない |
| 未対応・不足 | 返信が無い、返信だけで head に入っていない、条件の一部だけ満たす | 足りない点を報告し、返信の下書きを出す |
| 対応しない旨の返信 | 作者が直さない理由を書いた | 理由をユーザーに見せて判断を仰ぐ。resolve しない |

作者が提案と違う直し方をしたときは、文面ではなく**指摘した実害が消えたか**で判断する。

## Step 4: resolve する・返信する

resolve と返信は GitHub への書き込みなので、ユーザーの依頼に含まれているものだけを行う。

- **resolve:** 依頼に「resolve してよい」「resolve して」「監視して」があれば、「満たした」のスレッドを確認なしで resolve する。無ければ一覧を見せて承認を得る
- **返信:** 下書きを見せて承認を得てから投稿する。依頼に返信の指示があっても、文面は先に見せる

```bash
gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"<thread id>"}){thread{isResolved}}}'
```

```bash
gh api repos/OWNER/REPO/pulls/N/comments/<先頭コメントの databaseId>/replies -X POST -F body=@"<スクラッチパッド>/reply-N-<連番>.md"
```

1 投稿 1 コマンドにする。

## Step 5: approve する

依頼に「approve」があり、自分が起点の未解決スレッドが 0 になったら approve する。PR が open でなければしない。

```bash
gh pr review N --repo OWNER/REPO --approve
```

## Step 6: 報告する

```
| スレッド | 判定 | 根拠 | 行動 |
|---|---|---|---|
| path:line 1 行目の要約 | 満たした | head の path:34 に要件が入った | resolve 済み |
| path:line 1 行目の要約 | 合意待ち | 作者は〜を提案 | 判断を仰ぐ |
```

根拠には、確かめた head の場所（`path:line`）を書く。返信の文面だけを根拠にしない。

## 監視する

「監視して」と言われたら、`/loop` で Step 1〜6 を繰り返す。間隔の指定が無ければ自分で刻む（動的モード）。

- 前回から返信も head も変わっていなければ、何もせず次へ（報告しない）
- 変化があったスレッドだけを Step 2〜6 にかける
- **止める条件:** 自分の未解決スレッドが 0 になった、PR が merged / closed になった、合意待ち・対応しない旨の返信でユーザーの判断が要る
