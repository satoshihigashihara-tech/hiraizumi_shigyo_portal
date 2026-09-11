---
name: commit
description: Auto-generate commit message from diff and commit. Usage /commit
disable-model-invocation: true
---

# Auto Commit

Auto-generate a commit message from the staged diff and execute the commit.

## Steps

1. **Stage all changes**
   - Stage all changes with `git add -A`

2. **Check staged diff**
   - Get the staged diff with `git diff --cached`
   - If there is no diff, display the following message and abort:
     ```
     ⚠️ エラー: コミットする変更がありません
     ```

3. **Auto-generate commit message**
   - Analyze the staged diff and generate a concise commit message in Japanese
   - Rules:
     - First line: Summary of changes (aim for ~50 characters)
     - Accurately reflect the nature of changes (new feature, bug fix, refactoring, etc.)
     - Append `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>` at the end

4. **Execute commit**
   - Run `git commit` with the generated message
   - Pass the commit message using HEREDOC format:
     ```bash
     git commit -m "$(cat <<'EOF'
     コミットメッセージ

     Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
     EOF
     )"
     ```
   - On success, display in the following format:
     ```
     ✅ コミットしました: "コミットメッセージの1行目"
     ```
   - On failure, display an error message
