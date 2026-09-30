---
name: post-pr-review
description: レビュー指摘を GitHub の PR に投稿する。指摘は1件ずつ、該当箇所にインラインで付け、各指摘に「修正依頼か要議論か」と「resolve の条件」を書く。「レビューを PR に書いて」「指摘を投稿して」「インラインで付けて」「/post-pr-review」で使う。指摘の見つけ方は扱わない（explain-pr・/code-review・手作業のどれで出た指摘でもよい）。
argument-hint: "<PR番号 | PR URL>"
---

# post-pr-review

**1 指摘 = 1 スレッド。該当箇所に付け、次に何をすれば閉じられるかを書く。**

長文 1 本にまとめて投稿すると、読み手は指摘ごとに議論・修正・resolve ができない。

## Step 1: PR の head を取る

```bash
gh pr view <pr_number> --json number,headRefOid,files > "<スクラッチパッド>/pr-<pr_number>.json"
```

`"number":<pr_number>` が含まれていなければ取得失敗として止まる（終了コードでは判定しない）。

## Step 2: 指摘ごとに投稿先を決める

上から順に、当てはまる最初のものを選ぶ。

| 指摘の対象 | 投稿先 | 付ける値 |
|---|---|---|
| 差分内の行 | インラインコメント | `path` / `line` / `side`（複数行なら `start_line` / `start_side` も） |
| PR で変更したファイルの差分外の行 | ファイル単位のコメント | `path` / `subject_type=file`。本文の先頭に `path:line` を書く |
| PR で変更していないファイル、PR 全体 | 通常コメント | なし |

- 削除された行は `side=LEFT`、それ以外は `side=RIGHT`
- 差分外の行に `line` を付けると 422 になる。迷ったら `gh pr diff <pr_number>` の hunk で確かめる
- 通常コメントも 1 指摘 1 コメントにする。まとめない

**全体の要約コメントは投稿しない。** 個別の指摘と重なり、指摘を直すと古くなる。

## Step 3: 1 件ずつ本文を書く

ファイルは指摘ごとに分ける（`<スクラッチパッド>/review-<pr_number>-<連番>.md`）。

```markdown
**should｜修正依頼** エラー時に、何が失敗したかがログから読み取れない

- 例外を捕まえたあと `"failed"` だけを出力しており、対象の ID も原因も残らない（`:42`）
- リトライ後の失敗と初回の失敗が同じ文言で、区別できない（`:58`）

**提案:** ログに対象 ID・試行回数・例外メッセージを含める

**resolve の条件:** 失敗ログから対象と原因が特定できるようになったら resolve してください
```

- **1 行目**: 重要度（`must` / `should` / `nit`）｜種別（`修正依頼` / `要議論`）、結論 1 文。1 行目だけで何の指摘か分かるようにする
- **根拠**: 見出し・表を使わない
- **提案**: 1 行で直せるものは ```` ```suggestion ```` ブロックにしてよい（インラインのときだけ効く）
- **resolve の条件**: 満たしたかを判断できる形で書く
  - 修正依頼: 「〜が〜になったら resolve してください」
  - 要議論: 「このスレッドで〜の方針が決まったら resolve してください」
  - 通常コメント（resolve できない）: 「このスレッドで〜が決まったら完了です」

## Step 4: 一覧を見せて承認を得る

投稿は外部への送信なので、投稿前に次の一覧をユーザーに見せて承認を得る。

```
1. should｜修正依頼  inline  src/worker/job.py:42        エラー時に、何が失敗したかがログから読み取れない
2. nit｜修正依頼     file    src/config/settings.py:39   設定キーを列挙型で限定する
3. should｜要議論    comment PR 全体                     追加したテストの実行経路が無い
```

## Step 5: 1 件ずつ投稿する

1 投稿 1 コマンド。`for` や `&&` でまとめない（途中で失敗したとき、どこまで投稿したか分からなくなる）。

インライン:

```bash
gh api repos/{owner}/{repo}/pulls/<pr_number>/comments -X POST \
  -f commit_id=<headRefOid> -f path=<path> -F line=<line> -f side=RIGHT \
  -F body=@"<スクラッチパッド>/review-<pr_number>-<連番>.md"
```

複数行にまたがるときは `-F start_line=<開始行> -f start_side=RIGHT` を足す（`line` は終了行）。削除された行なら `side` / `start_side` を `LEFT` にする。

ファイル単位:

```bash
gh api repos/{owner}/{repo}/pulls/<pr_number>/comments -X POST \
  -f commit_id=<headRefOid> -f path=<path> -f subject_type=file \
  -F body=@"<スクラッチパッド>/review-<pr_number>-<連番>.md"
```

通常コメント:

```bash
gh pr comment <pr_number> --body-file "<スクラッチパッド>/review-<pr_number>-<連番>.md"
```

**失敗したら、再投稿の前に一覧を取り直す**（Step 6 と同じコマンド。通常コメントも含む）。投稿済みの指摘を二重に投稿しない。

## Step 6: 付いたことを確かめる

```bash
gh api 'repos/{owner}/{repo}/pulls/<pr_number>/comments?per_page=100' --paginate --slurp > "<スクラッチパッド>/pr_inline-<pr_number>.json"
```

先頭が `[[` でなければ取得失敗。自分の投稿の件数と `path` / `line` が Step 4 の一覧と合うかを確かめる。

通常コメントを投稿したときは、こちらも取り直す。

```bash
gh pr view <pr_number> --json number,comments > "<スクラッチパッド>/pr_comments-<pr_number>.json"
```

`"number":<pr_number>` が含まれていなければ取得失敗。自分の通常コメントの件数と 1 行目が Step 4 の一覧と合うかを確かめる。

## やらないこと

- 指摘を見つけるレビュー（差分の読み方・観点）
- resolve の操作
- まとめたレビュー（`POST .../reviews`）での一括送信。1 件失敗すると全体が送られない
