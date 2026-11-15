#!/bin/zsh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [[ "$(git branch --show-current)" != "main" ]]; then
    print -u2 "Error: mainブランチで実行してください。"
    exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    print -u2 "Error: 未コミットの変更があります。先に確認してください。"
    git status --short
    exit 1
fi

if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    print -u2 "Error: すでにマージ処理中です。"
    exit 1
fi

git fetch origin

BACKUP_BRANCH="backup/before-github-merge-$(date +%Y%m%d-%H%M%S)"
git branch "$BACKUP_BRANCH" HEAD

printf 'Backup branch: %s\n' "$BACKUP_BRANCH"

if git merge-base --is-ancestor origin/main HEAD; then
    print -u2 "Error: origin/mainはすでにローカルへ取り込まれています。"
    print -u2 "git push -u origin main を実行してください。"
    exit 1
fi

if ! git merge \
    --allow-unrelated-histories \
    --no-ff \
    --no-commit \
    origin/main; then

    print -u2 ""
    print -u2 "マージに失敗したため、自動コミットを停止しました。"
    print -u2 "以下で状態を確認してください:"
    print -u2 "  git status"
    print -u2 ""
    print -u2 "マージ開始前に戻す場合:"
    print -u2 "  git merge --abort"
    exit 1
fi

printf '\n--- Merge changes ---\n'
git diff --cached --stat

git add .
git commit -m 'GitHubの初期履歴をローカルの開発履歴に統合'