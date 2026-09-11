---
name: create-issue
description: Analyze the codebase interactively and create a GitHub issue. Usage /create-issue [概要]
disable-model-invocation: true
---

# Create Issue: Analyze the Codebase Interactively and Create a GitHub Issue

Analyze the codebase, interactively gather missing information, and create a GitHub Issue after preview confirmation. Skill instructions are written in English; user-facing output is in Japanese.

## Critical Constraints

**Never edit any project source code files during skill execution.**

### Prohibited tools and operations

- `Write` tool (file creation / overwrite)
- `Edit` tool (file editing)
- `NotebookEdit` tool (Jupyter notebook editing)
- `Bash` commands that modify the filesystem: `rm`, `mv`, `cp`, `mkdir`, `touch`, `chmod`, `chown`, `sed -i`, `tee`, `ln`, `dd`, `install`, `patch`, redirections (`>`, `>>`) — and any other command that writes to or modifies files
- Git write operations: `git add`, `git commit`, `git push`, `git merge`, `git rebase`, `git checkout -b`, `git switch -c`, `git branch -d`, `git branch -D`, `git tag`, `git stash`, `git reset`, `git clean`

### Allowed tools and operations

- `Read` tool (file reading)
- `Glob` tool (file search)
- `Grep` tool (content search)
- `Bash` read-only commands: `ls`, `head`, `tail`, `git log`, `git diff`, `git status`, `find`, `wc`, `tree`, `gh` commands, etc.
- `Bash` temporary file operations (for issue creation only): creating and deleting `issue_body.tmp` via HEREDOC is permitted
- `AskUserQuestion` tool (asking the user questions)
- `Agent` tool (codebase analysis via Explore subagent)

## Arguments

- Optional summary text (e.g., `/create-issue ログイン画面にパスワードリセット機能を追加`)
- If omitted, the summary will be gathered via `AskUserQuestion`

## Steps

### 1. Receive summary

Receive the summary in the following priority order:

1. **Provided as argument**: Use the skill argument as-is
2. **Argument omitted**: Use `AskUserQuestion` to ask the user what they want to implement or fix

If the summary is empty or insufficient, display an error and abort:
```
⚠️ エラー: 実装/修正したい内容の概要を入力してください。
```

### 2. Codebase analysis

Invoke the Agent tool (Explore subagent) with the following parameters to automatically investigate the codebase based on the received summary.

```yaml
Task tool parameters:
  subagent_type: "Explore"
  prompt: |
    Investigate the codebase related to the following summary and report the analysis results.

    ## Summary
    {{user-provided summary}}

    ## Investigation scope
    1. **Identify related files**: Search for files related to the summary using Glob and Grep
    2. **Understand existing implementation patterns**: Read related files to understand patterns
    3. **Assess impact scope**: Investigate dependencies, callers, and callees of related files

    ## Output format
    Return results in the following format:
    - List of related files (with a brief description for each)
    - Description of existing implementation patterns
    - Description of impact scope
```

- Store the analysis result for use in subsequent steps

- Display the analysis result before the interactive phase:
  ```
  🔍 コードベース分析結果
  ─────────────────────────────
  📂 関連ファイル:
    - {{file1}} - {{summary}}
    - {{file2}} - {{summary}}
    ...

  🔧 既存の実装パターン:
    {{pattern description}}

  📋 影響範囲:
    {{impact description}}
  ─────────────────────────────
  ```

### 3. Interactive phase (max 3 rounds)

Use `AskUserQuestion` to gather missing information.

- Based on the analysis result, ask about ambiguous points or decisions that need user input
- Build questions dynamically based on what information is actually missing (do not use a fixed template)
- Run up to 3 rounds of interaction. In each round:
  - If no missing information remains, end the phase early
  - Only proceed to the next round if the user's answer raises new questions

Round management pseudocode:
```
round = 0
while round < 3:
  round++
  identify missing info based on analysis and previous answers
  if no missing info:
    break
  AskUserQuestion
  record answer
```

### 4. Label assignment

#### Type label (auto-detected)

Auto-detect from the summary and analysis result:

| Label | Condition |
|-------|-----------|
| `bug` | Bug, error, or unexpected behavior |
| `enhancement` | New feature or improvement |
| `documentation` | Documentation changes |
| `question` | Question or discussion |

#### Priority label

If the user mentioned priority during the interactive phase, skip the question. Detect priority from keywords such as:
- 「緊急」「急ぎ」「至急」「クリティカル」 → `prio:Critical` or `prio:High`
- 「優先度高」「優先度低」 → corresponding label
- 「後回しでいい」「余裕があれば」 → `prio:Low`

If none of the above apply, ask via `AskUserQuestion` with **exactly these 4 options** (do NOT skip, merge, or omit any):

| # | label | description |
|---|-------|-------------|
| 1 | prio:Critical | 緊急対応が必要 |
| 2 | prio:High | 高優先度 |
| 3 | prio:Medium | 中優先度 |
| 4 | prio:Low | 低優先度 |

### 5. Generate issue title

- Generate a Japanese title from the summary and analysis result
- 50 characters or less, concise and descriptive

### 6. Generate issue body and show preview

Generate the body using the following template:

```markdown
## 概要・背景
{{summary and background}}

## 実装方針
{{concrete implementation approach based on codebase analysis}}

## 影響範囲
{{related files and scope of changes}}

## 受け入れ条件
- [ ] {{condition 1}}
- [ ] {{condition 2}}
- [ ] ...
```

Show preview:
```
📝 イシュープレビュー
══════════════════════════════════════════
タイトル: {{title}}
ラベル:   {{labels}}
──────────────────────────────────────────
{{issue body}}
══════════════════════════════════════════
```

Ask for confirmation via `AskUserQuestion`: 「この内容でイシューを作成してよろしいですか？（はい / 修正内容を入力）」

**Revision loop**: If the user requests changes, apply them and show the preview again. Repeat until the user approves (max 10 iterations). If the limit is reached, suggest creating the issue and editing it directly on GitHub, then ask whether to create or abort.

Revision loop pseudocode:
```
revision_count = 0
loop:
  show preview
  AskUserQuestion for confirmation
  if user approves:
    break
  else:
    revision_count++
    if revision_count >= 10:
      suggest creating and editing on GitHub
      AskUserQuestion: create or abort
      break or abort
    apply revisions
    continue
```

### 7. Create the issue

Create the issue using `gh issue create` after confirmation.

**IMPORTANT**: Use HEREDOC in a Bash command to create the temporary body file. Do NOT use the Write tool.

```bash
cat > issue_body.tmp << 'EOF'
{{body}}
EOF

gh issue create --title '{{title}}' --body-file issue_body.tmp {{label_flags}}

rm -f issue_body.tmp
```

- `{{label_flags}}`: Add `-l "{{label}}"` flag for each label
- Capture the created issue number and URL from the output

### 8. Completion message

```
✅ イシューを作成しました
─────────────────────────────
📋 イシュー:  #{{number}} {{title}}
🏷️  ラベル:   {{labels}}
🔗 URL:       {{url}}
─────────────────────────────

次のステップ:
- プランを作成: /plan-issue {{number}}
- 一気通貫で実装: /implement-issue {{number}}
```

## Error Handling

- `gh` command failure → display error message and abort
- User provides no summary → display error message and abort
- Agent tool (codebase analysis) failure → display warning 「コードベース分析に失敗しました。概要の情報のみで issue を作成します」 and continue from Step 3 without analysis result

## Important Notes

- Never edit project files during skill execution (critical constraint)
- All user-facing messages must be in Japanese
- Use `AskUserQuestion` tool for all interactions
- Use `Agent` (Explore subagent), `Glob`, `Grep`, `Read` tools for codebase analysis
- Create issue body file via HEREDOC, never with the Write tool
- Non-existent labels are automatically created by `gh issue create`
