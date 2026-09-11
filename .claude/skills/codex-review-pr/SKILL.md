---
name: codex-review-pr
description: Review a PR using Codex CLI (OpenAI) and post the review comment. Usage /codex-review-pr <PR番号>
---

# Codex Review PR

Review a PR using Codex CLI (OpenAI) and post the review comment on the PR.

## Arguments

- A PR number is **required** (e.g., `/codex-review-pr 42`)
- If no argument is provided, display the following message and abort:
  ```
  ⚠️ エラー: PR番号を指定してください。使い方: /codex-review-pr <PR番号>
  ```

## Steps

### 1. Run the review script

```bash
bash .claude/skills/codex-review-pr/codex-review-pr.sh {{number}}
```

The script handles the entire flow end-to-end: fetching PR data, generating a prompt, running Codex CLI, and posting the review comment.
No additional processing by Claude Code (Read / Write / gh commands, etc.) is needed.

## Important Notes

- This skill does NOT modify repository source files or branches
- Works from any branch (does not require checkout of the PR's branch)
- Codex CLI and mise (node) must be installed in the environment
