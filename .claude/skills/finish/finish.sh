#!/bin/bash
set -euo pipefail

# Protected branches that cannot run this script
PROTECTED_BRANCHES=("develop" "main" "staging")

# === 0. Check dependencies ===
if ! command -v jq &>/dev/null; then
  echo "⚠️ エラー: jq がインストールされていません。インストールしてから再実行してください。"
  exit 1
fi

# === 1. Check current branch ===
branch=$(git branch --show-current)
for protected in "${PROTECTED_BRANCHES[@]}"; do
  if [[ "$branch" == "$protected" ]]; then
    echo "⚠️ エラー: 現在のブランチは '${branch}' です。フィーチャーブランチから実行してください。"
    exit 1
  fi
done
feature_branch="$branch"

# === 2. Check for associated PR ===
pr_output=$(gh pr view --json number,baseRefName,state,isDraft 2>&1) || {
  echo "⚠️ エラー: 現在のブランチに紐づくPRが見つかりません"
  echo "  詳細: $pr_output"
  exit 1
}
pr_json="$pr_output"

number=$(echo "$pr_json" | jq -r '.number')
base_ref=$(echo "$pr_json" | jq -r '.baseRefName')
state=$(echo "$pr_json" | jq -r '.state')
is_draft=$(echo "$pr_json" | jq -r '.isDraft')

# === 3. Handle PR state ===
skip_merge=false
messages=()

case "$state" in
  MERGED)
    skip_merge=true
    messages+=("ℹ️ PR #${number} は既にマージ済みです")
    ;;
  CLOSED)
    skip_merge=true
    messages+=("⚠️ 警告: PR #${number} はマージされずにクローズされています")
    ;;
  OPEN)
    if [[ "$is_draft" == "true" ]]; then
      echo "⚠️ エラー: PR #${number} はまだDraft状態です。Ready for reviewにしてから実行してください。"
      exit 1
    fi
    ;;
esac

# === 4. Merge the PR (if needed) ===
if [[ "$skip_merge" == "false" ]]; then
  if ! gh pr merge --merge --delete-branch; then
    echo "⚠️ エラー: PR #${number} のマージに失敗しました"
    exit 1
  fi
  messages+=("✅ PR #${number} をマージしました")
fi

# === 5. Switch to base branch and pull latest ===
if ! git switch "$base_ref"; then
  echo "⚠️ エラー: ブランチ '${base_ref}' への切り替えに失敗しました"
  exit 1
fi
if ! git pull origin "$base_ref"; then
  echo "⚠️ エラー: ブランチ '${base_ref}' のpullに失敗しました"
  exit 1
fi

# === 6. Delete feature branch (if not already deleted by gh pr merge) ===
git fetch --prune
if git branch --list "$feature_branch" | grep -q .; then
  if git branch -d "$feature_branch" 2>/dev/null; then
    messages+=("✅ ブランチ '${feature_branch}' を削除しました")
  else
    messages+=("⚠️ 警告: ブランチ '${feature_branch}' の削除に失敗しました。手動で削除してください。")
  fi
else
  messages+=("✅ ブランチ '${feature_branch}' を削除しました")
fi

messages+=("✅ ブランチ '${base_ref}' に切り替え、最新に更新しました")

# === Output results ===
printf '%s\n' "${messages[@]}"
