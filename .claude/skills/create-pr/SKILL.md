---
name: create-pr
description: Create a draft pull request to develop (or specified branch). Usage /create-pr [base-branch]
---

# Create a Pull Request

Create a draft pull request from the current branch. The base branch defaults to `develop`, but can be overridden by providing a branch name as an argument.

## Arguments

- If an argument is provided, use it as the base branch (e.g., `/create-pr main` → base branch is `main`)
- If no argument is provided, use `develop` as the base branch

## Steps

### 1. Fetch latest remote branches

```bash
git fetch origin
```

### 2. Push current branch if not yet pushed

Check if the current branch has been pushed to the remote:

```bash
git rev-parse --abbrev-ref HEAD
git ls-remote --heads origin $(git rev-parse --abbrev-ref HEAD)
```

- If the remote tracking branch does **not** exist (empty output), push the current branch:
  ```bash
  git push -u origin HEAD
  ```
- If it already exists, skip this step

### 3. Check diff against the base branch

```bash
git diff origin/{{base-branch}}...HEAD
```

- Review the diff to understand all changes
- Also run `git log origin/{{base-branch}}...HEAD --oneline` to see commit history

### 4. Generate PR title and body

Based on the diff and commit history:

- **PR title**: A concise summary of the changes (in Japanese)
- **PR body**: Fill in all sections below based on the actual changes
- **Issue linking**: If a GitHub issue number is referenced in the context (e.g., plan file, commit messages, branch name like `issue-42-...`), include `Closes #XX` in the 参考 section. This allows GitHub to automatically close the issue when the PR is merged.

### 5. Create PR and open in browser

**IMPORTANT**: Use HEREDOC in a Bash command to create the temporary body file. Do NOT use the Write tool.

```bash
# Create PR body as a temp file using HEREDOC
cat > prbody.tmp << 'EOF'
## 概要
<!-- 変更の概要を箇条書きで記載 -->

{{概要}}

## 詳細
<!-- 変更内容の詳細を記載 -->

{{詳細}}

## 参考
<!-- 関連するissueやドキュメントのリンクなど -->

{{参考}}

## 注意事項
<!-- レビュアーへの注意事項やテスト方法など -->

{{注意事項}}
EOF

# Create PR and open in browser (push was already handled in step 2)
gh pr create --draft --base {{base-branch}} --title "{{PRタイトル}}" --body-file prbody.tmp && \
gh pr view --web

# Clean up temp file
rm -f prbody.tmp
```

## Important Notes

- **Default**: Always create as **Draft** PR unless explicitly instructed otherwise
- **Body file**: Always use HEREDOC in Bash to create `pr_body.tmp` — never use the Write tool
- **Sections**: Fill in all four sections (概要, 詳細, 参考, 注意事項) based on the actual diff
- **Language**: PR title and body should be in Japanese
- **Labels**: Add appropriate labels with `-l` flag if applicable
- **Clean up**: Always remove the temp file after PR creation

## Error Handling

- If `git push` fails, display the error and abort
- If `gh pr create` fails (e.g., PR already exists), display the error message
- If the base branch doesn't exist on remote, display an error and abort

## Success Message Example

```
✅ Pull Request を作成しました（Draft）
ブラウザで PR ページを開いています...
```
