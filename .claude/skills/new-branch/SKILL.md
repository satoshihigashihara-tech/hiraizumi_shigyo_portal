---
name: new-branch
description: Create a new git branch from develop with auto-generated name and date suffix. Usage /new-branch "feature description"
---

# Create a New Branch

Create and switch to a new branch from develop. The branch name is auto-generated from arguments with a date suffix.

## Steps

1. **Check current branch**
   - Get the current branch with `git branch --show-current`
   - If not on develop, display a warning and abort

2. **Generate branch name**
   - Convert the provided summary (Japanese accepted) into an English branch name
   - Conversion rules:
     - Convert to all lowercase
     - Replace spaces with hyphens (`-`)
     - Remove all characters except alphanumeric and hyphens
   - Example: "Add User Authentication" → "add-user-authentication"

3. **Add `feature/` prefix**
   - Prepend `feature/` to the branch name

4. **Add date suffix**
   - Get today's date with `date +%Y%m%d` (yyyyMMdd format)
   - Append `_yyyyMMdd` to the branch name
   - Example: "feature/add-user-authentication_20260211"

5. **Create and switch to the branch**
   - Create and switch with `git switch -c <branch-name>`
   - Display a success message

## Important Notes

- **Required check**: Verify the current branch is `develop`
- **If not on develop**: Display an error message and abort
- **If no arguments provided**: Display usage and abort

## Error Message Example

```
⚠️  エラー: 現在のブランチは 'develop' ではありません (現在: main)
developブランチから新しいブランチを作成してください。

次のコマンドでdevelopブランチに切り替えてから再実行してください:
git switch develop
```

## Success Message Example

```
✅ ブランチ 'feature/add-user-authentication_20260211' を作成し、切り替えました
```
