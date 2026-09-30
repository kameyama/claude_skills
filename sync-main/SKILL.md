---
name: sync-main
description: main を最新化してから作業を始めるための個人用スキル。origin/main を fetch し、安全なときだけローカル main を早送りする。ブランチを切る前、rebase する前、`git diff origin/main` を取る前、「main を最新にして」「main が古い」「最新を取り込んで」と言われたときは必ずこのスキルに従う。`git pull` は使わない。
---

# sync-main

**複数の Claude セッションが同じチェックアウトと複数の作業ツリーで同時に動く**前提で、
main を壊さずに最新化する手順を定める。素朴に `git pull` でやると、他セッションの作業を巻き込む。

## 実行

```bash
git fetch --prune origin
bash ~/.claude/skills/sync-main/scripts/sync_main.sh
```

**2 行で 1 セット。順番も省略不可。**
スクリプトは自分でも fetch するが、Claude のシェルはサンドボックス内なのでスクリプト経由の
ネットワークアクセスが落ちることがある。先に素の `git fetch` を打つ（`git *` をサンドボックス除外に
している設定なら通る）。スクリプトは直近 5 分以内の fetch を検出して二重取得を省くので無駄打ちにならない。

セッション開始時に `SessionStart` フックで自動実行する設定にしてある場合、通常は手で叩く必要はない。
手で叩くのは次のとき。

- セッションが長く、開始時の fetch が古くなったとき
- ブランチを切る直前・rebase する直前
- `git diff origin/main...HEAD` の結果が実態と合わないとき

## このスキルの定義する「最新化」

| 対象 | 何をするか |
|---|---|
| `origin/main` | 必ず最新にする。remote-tracking ref の更新だけで、どの作業ツリーのファイルも変わらない |
| ローカル `main` | **安全に早送りできるときだけ**早送りする |

**基点は常に `origin/main`。** ローカル `main` は早送りされないことがあるので、基点に使わない。

```bash
git switch -c <branch> origin/main    # ブランチを切る
git rebase origin/main                # 追従する
git diff origin/main...HEAD           # 差分を見る
```

## ローカル main を触らない条件

次のいずれかに当てはまると、スクリプトはローカル `main` に手を出さず報告だけする。
いずれも「触ると他セッションの作業が壊れる」ケースである。

| 条件 | 触ると何が起きるか |
|---|---|
| 別の作業ツリーが `main` を checkout している | そのセッションの足元のファイルが書き換わる |
| `main` を持つ作業ツリーが汚れている | 未コミットの変更を巻き込む |
| ローカル `main` に `origin/main` へ無いコミットがある | 早送りでは解消できない。巻き戻すとコミットが消える |
| 別セッションが同時に同期中（`.git/sync-main.lock` が取れない） | ref 更新が競合する |

この報告が出てもリカバリは不要。**`origin/main` を基点にすれば作業は成立する。**

`git fetch` に失敗しても、既に取得済みの `origin/main` への早送りは行い、終了コードは 0 のままにする。
ネットワーク断でセッションを止めないため。`origin/main` が古い可能性は出力で申告する。

`origin/main` が無いリポジトリ（main 以外を既定ブランチにしている等）では何もせず終了する。

## 禁止する操作

| 禁止 | 理由 | 代わりに |
|---|---|---|
| `git pull` | マージコミットを作る。checkout 中のブランチと作業ツリーを同時に書き換える | 上の 2 行 → `git rebase origin/main` |
| `git reset --hard` で main を合わせる | 他セッションの未 push コミットが消える | 触らない。`origin/main` を基点にする |
| 他の作業ツリーへの `git switch` / `git checkout` | そのセッションの足元が変わる | 触らない |
| `git stash` / `git stash pop` | stash スタックは全作業ツリーで共有。他セッションの退避を pop しうる | WIP コミットを使う |

## 安全性の検証

安全性はテストで担保する。スクリプトを直したら必ず回す。

```bash
bash ~/.claude/skills/sync-main/tests/test_sync_main.sh
```

使い捨てリポジトリだけを触り、実在のリポジトリには一切触れない。
上の「触らない条件」4 つ、同時起動 5 本、ネットワーク断を検証する。落ちたら使わない。

## セッション開始時に強制する

`~/.claude/settings.json` に入れると全プロジェクトで効く。特定のリポジトリだけなら
そのリポジトリの `.claude/settings.json` に入れる（ただしチーム共有のリポジトリに
`$HOME` 配下のパスをコミットしない）。

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$HOME/.claude/skills/sync-main/scripts/sync_main.sh\" || true",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
```

フックはサンドボックス外で動くので 1 行で完結し、結果がセッション冒頭の文脈に入る。
`|| true` は、スクリプトが未配置の環境でフックが 127 で落ちないようにするため。
