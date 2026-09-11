---
name: chat
description: Switch to chat-only mode (no file editing). Usage /chat
disable-model-invocation: true
---

# Chat Mode: 対話専用モード

Switch to chat-only mode where no file editing, creation, or deletion is performed. This mode is for conversations, consultations, and code reading only.

## Arguments

- No arguments required (`/chat`)

## Constraints

### Prohibited tools and operations

The following tools and operations are **strictly forbidden** in this mode:

- `Write` tool (file creation / overwrite)
- `Edit` tool (file editing)
- `NotebookEdit` tool (Jupyter notebook editing)
- `Bash` commands that modify the filesystem: `rm`, `mv`, `cp`, `mkdir`, `touch`, `chmod`, `chown`, `sed -i`, `tee`, `ln`, `dd`, `install`, `patch`, redirections (`>`, `>>`) — and any other command that writes to or modifies files
- Git write operations: `git add`, `git commit`, `git push`, `git merge`, `git rebase`, `git checkout -b`, `git switch -c`, `git branch -d`, `git branch -D`, `git tag`, `git stash`, `git reset`, `git clean`

### Allowed tools and operations

The following read-only tools and operations are **allowed**:

- `Read` tool (file reading)
- `Glob` tool (file search)
- `Grep` tool (content search)
- `Bash` read-only commands: `ls`, `head`, `tail`, `git log`, `git diff`, `git status`, `find`, `wc`, `tree`, etc.
- `AskUserQuestion` tool (asking the user questions)

## Startup Message

On activation, display the following message exactly:

```
══════════════════════════════════════════
💬 対話専用モード
══════════════════════════════════════════
ファイルの編集・作成・削除は行いません。
コードの読み取り・検索は可能です。

何でもご相談ください：
- 設計方針の相談・議論
- コードリーディング（コードの説明・解説）
- issue作成前の要件整理
- 技術的な質問・調査
══════════════════════════════════════════
```

## Behavior

- Respond to all user messages in Japanese
- Use codebase reading and searching tools as needed to answer user questions
- If a file change is needed, present the proposed changes as text but do NOT perform any actual file operations
- If the user requests implementation, inform them that this is chat-only mode and suggest invoking another skill (e.g., `/implement-issue`) to naturally exit chat mode and proceed with the implementation

## Important Notes

- This skill is a read-only mode that never modifies any files
- Chat mode remains active for the duration of the session
- Following existing skill conventions: skill instructions are written in English, user-facing output is in Japanese
