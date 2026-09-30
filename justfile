# レシピ一覧
default:
    just --list

# スクリプトのテストを一括実行
test:
    bash sync-main/tests/test_sync_main.sh
