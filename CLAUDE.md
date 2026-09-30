# CLAUDE.md

個人用 Claude Code スキル集。このディレクトリ（`~/.claude/skills`）を Claude Code が直接読み込むため、変更は即座に全セッションへ反映される。

## 構成

- 1スキル = 1ディレクトリ。`<name>/SKILL.md` が本体、補助は `scripts/`・`tests/` に置く
- `synced/` は Claude アプリが自動同期する Anthropic 製スキル。編集しない（git 管理外）

## 規約

- SKILL.md の frontmatter `name` はディレクトリ名と一致させる
- `description` は日本語で、何をするかと呼び出しのきっかけになる言い回し（「〜して」「/name」）を書く
- スクリプトは SKILL.md から `~/.claude/skills/<name>/scripts/...` の絶対パスで参照する

## セキュリティ

- 会社・顧客由来の情報を書かない（組織名・リポジトリ名・Issue/PR 番号・テナント名・社内パス・コード片・URL）。例は `OWNER/REPO#123` のような汎用の値にする
- 秘密情報（トークン・API キー・認証ヘッダ・メールアドレス）を書かない。`~/.claude/` の設定ファイルから値を転記しない
- コミット前に `git diff --cached` で上記が含まれていないことを確認する

## コマンド

- スクリプトを変更したら `just test` を実行する
- `just` はサンドボックス外で実行される（`.claude/settings.json` の `excludedCommands`）。justfile のレシピ = サンドボックス外で実行してよいコマンドの許可リストなので、**レシピを勝手に追加しない**。必要なら何をするレシピかを説明し、ユーザーの許可を得てから追加する
