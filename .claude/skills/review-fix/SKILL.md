---
name: review-fix
description: Check PR review comments and fix code accordingly. Usage /review-fix
disable-model-invocation: true
---

# Review Fix

Check PR review comments, fix code based on the feedback, and commit & push the changes.

## Steps

### 1. Check current branch

```bash
git branch --show-current
```

- If on `develop`, `main`, or `staging`, display the following message and abort:
  ```
  ⚠️ エラー: 現在のブランチは '{{branch}}' です。フィーチャーブランチから実行してください。
  ```

### 2. Check for associated PR

```bash
gh pr view --json number,url,state
```

- If no PR exists for the current branch, display the following message and abort:
  ```
  ⚠️ エラー: 現在のブランチに紐づくPRが見つかりません
  ```
- If the PR state is `MERGED`, display the following message and abort:
  ```
  ⚠️ エラー: PR #{{number}} は既にマージ済みです
  ```
- If the PR state is `CLOSED`, display the following message and abort:
  ```
  ⚠️ エラー: PR #{{number}} はクローズされています
  ```
- Save `number` and `url` for subsequent steps

### 3. Fetch review comments

Fetch both inline review comments and general PR comments:

```bash
# Inline review comments (code-level comments from reviews)
gh api repos/{owner}/{repo}/pulls/{{number}}/comments

# General PR comments
gh pr view {{number}} --json comments
```

- From inline review comments, extract: `path`, `line` (or `original_line`), `body`, `user.login`
- From general PR comments, extract: `body`, `author.login`
- Exclude bot comments and the PR author's own comments (focus on reviewer feedback)

### 4. Display comments

Display the retrieved comments in the following format:

**When comments exist:**

```
📝 PR #{{number}} のレビューコメント ({{count}}件) を確認します

【インラインコメント】
1. {{path}}:{{line}}
   💬 @{{user}} "{{body}}"

2. {{path}}:{{line}}
   💬 @{{user}} "{{body}}"

【一般コメント】
3. 💬 @{{user}} "{{body}}"
```

**When no comments exist:**

Display the following message and finish:
```
✅ PR #{{number}} にレビューコメントはありません
```

### 5. Fix code based on comments

- Analyze each review comment to understand what changes are requested
- Read the relevant files referenced in the comments
- Apply the necessary code modifications based on the review feedback
- After all fixes are applied, display a summary:
  ```
  ---
  修正を実行します...

  ✅ {{count}}件のレビューコメントに基づいてコードを修正しました
  ```

### 6. Auto-commit and push

Execute the same process as the `/commit` skill:

1. **Run Laravel Pint**
   - Run `docker compose exec app ./vendor/bin/pint` for code formatting
   - If it fails, display a warning but continue processing

2. **Stage all changes**
   - Stage all changes with `git add -A`

3. **Check staged diff**
   - Get the staged diff with `git diff --cached`
   - If there is no diff (no changes were needed), display a message and finish:
     ```
     ℹ️ 修正による変更はありませんでした
     ```

4. **Auto-generate commit message**
   - Analyze the staged diff and generate a concise commit message in Japanese
   - The commit message should reference that changes are based on review comments
   - Append `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>` at the end

5. **Execute commit**
   - Run `git commit` with the generated message using HEREDOC format:
     ```bash
     git commit -m "$(cat <<'EOF'
     レビューコメントに基づくコード修正

     Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
     EOF
     )"
     ```
   - On success, display:
     ```
     ✅ コミットしました: "{{commit message first line}}"
     ```
   - On failure, display an error message

6. **Push to remote**
   ```bash
   git push
   ```
   - On success, display:
     ```
     ✅ リモートにプッシュしました
     ```
   - On failure, display an error message

## Error Handling

- On `develop`/`main`/`staging`: Display error and abort
- No PR found: Display error and abort
- PR is `MERGED`: Display error and abort
- PR is `CLOSED`: Display error and abort
- No review comments: Display message and finish (not an error)
- No changes needed after review: Display message and finish
- Pint failure: Display warning, continue processing
- Commit failure: Display error and abort
- Push failure: Display error and abort
