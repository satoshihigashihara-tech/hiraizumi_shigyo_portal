---
name: plan-issue
description: Create a plan file from a GitHub issue. Usage /plan-issue <issue番号> [--ask]
disable-model-invocation: true
---

# Plan Issue: Create a plan file from a GitHub issue

Fetch a GitHub issue by number, analyze the codebase, and generate a plan file under `.claude/plans/`.

## Arguments

- An issue number is **required** (e.g., `/plan-issue 42`)
- If no argument is provided, display the following message and abort:
  ```
  ⚠️ エラー: イシュー番号を指定してください。使い方: /plan-issue <issue番号> [--ask]
  ```
- `--ask` (optional): プラン生成前にユーザーに質問し、回答を踏まえてプランを生成する
- Example: `/plan-issue 42 --ask`

## Steps

### 1. Validate arguments

- Parse the arguments to extract the issue number and optional flags (e.g., `--ask`)
- If no issue number is provided, display the error message above and abort
- Recognized flags: `--ask` (case-sensitive). Unknown or malformed flags (e.g., `--Ask`, `--ASK`, `--foo`) should be ignored with a warning:
  ```
  ⚠️ 警告: 不明なオプション '{{flag}}' は無視されます
  ```

### 2. Fetch issue details

```bash
gh issue view <number> --json number,title,body,labels,state
```

- If the issue does not exist, display the following message and abort:
  ```
  ⚠️ エラー: イシュー #{{number}} が見つかりません
  ```
- If the issue state is `CLOSED`, display a warning but continue:
  ```
  ⚠️ 注意: イシュー #{{number}} はクローズ済みです。クローズ時点の内容でプランを作成します
  ```
- Display issue summary:
  ```
  📋 イシュー #{{number}} の情報
  ─────────────────────────────
  タイトル: {{title}}
  ステータス: {{state}}
  ラベル: {{labels}}
  ─────────────────────────────
  ```

### 3. Ask user for additional context (only when `--ask` is specified)

If `--ask` is NOT specified, skip this step entirely.

If `--ask` is specified:

1. Analyze the issue body and identify what information is missing or ambiguous for creating a concrete implementation plan. Consider aspects such as:
   - Unclear scope or boundaries
   - Multiple possible implementation approaches
   - Missing technical details or constraints
   - Ambiguous requirements that could be interpreted in different ways
   - Dependencies or side effects that need confirmation

2. Use the `AskUserQuestion` tool to ask the user **only about the gaps you identified**. Do NOT use a fixed template -- tailor the questions to what is actually unclear or missing in this specific issue. Keep the number of questions concise (typically 2-4 questions).

3. Evaluate the user's response. If the response is insufficient or raises new questions that are critical for creating a concrete plan, you may ask **one additional follow-up question** using `AskUserQuestion`. Do not ask more than 2 rounds of questions in total.

4. Store the user's response(s) for use in the next step

### 4. Investigate the codebase and generate plan via Plan agent

Delegate codebase investigation and plan generation to a Plan agent via the **Task tool**. The Plan agent has access to Glob, Grep, and Read tools for thorough codebase analysis.

```yaml
Task tool parameters:
  subagent_type: "Plan"
  prompt: |
    Create an implementation plan based on the following GitHub issue.

    ## Issue Details
    - Number: #{{number}}
    - Title: {{title}}
    - Body:
    {{body}}

    <!-- IF --ask was specified and user responded -->
    ## Additional Context from User
    {{user's response from AskUserQuestion}}
    <!-- END IF -->

    ## Instructions
    1. Thoroughly investigate the codebase to identify files that need to be changed
    2. Generate a plan following the template below
    3. For each change, describe the "location", "changes", and "reason" in concrete detail
    4. Follow existing code patterns and conventions. In particular, always refer to `CLAUDE.md` and the coding standards under `.claude/rules/` to ensure compliance
    5. Output only the plan (no preamble or explanation)
    6. Write the plan content in Japanese (section headers and descriptions)

    ## Template
    ```markdown
    # {{Plan title in Japanese}}

    ## Context
    {{Why this change is needed, referencing the issue}}
    GitHub Issue: #{{number}}

    ## 変更対象ファイル

    ### 1. {{Description of change}}
    - **{{新規/変更}}**: `{{file path}}`
    - **変更箇所**: {{Specific location in the file (function name, line number, etc.)}}
    - **変更内容**: {{Concrete description of what to change and how}}
    - **理由**: {{Why this change is necessary}}

    ### 2. {{Description of change}}
    ...

    ## 設計上の考慮点
    {{Design decisions and trade-offs if any}}

    ## 検証方法
    1. {{Verification steps}}
    ```
```

- The Task tool returns the agent's output as its result. Store this return value (the plan body) in a variable for use in the next step

### 5. Save plan file

1. **Get current datetime**
   ```bash
   date +%y%m%d%H%M%S
   ```

2. **Generate filename**
   - Convert the issue title to an English kebab-case slug
   - Conversion rules:
     - Translate Japanese to English if needed
     - Convert to all lowercase
     - Replace spaces with hyphens (`-`)
     - Remove all characters except alphanumeric and hyphens
     - Trim leading/trailing hyphens
   - Prepend issue number: `issue-{number}-`
   - Append datetime suffix: `_{yyMMddHHmmss}`
   - Final filename: `.claude/plans/issue-{number}-{kebab-case}_{yyMMddHHmmss}.md`
   - Example: "ユーザー認証の追加" (Issue #42) → `.claude/plans/issue-42-add-user-authentication_260217143025.md`

3. **Write plan file**
   - Write the Plan agent's output directly to the file (do NOT use a hardcoded template)
   - The Plan agent has already formatted the content according to the template

### 6. Display completion message

```
✅ プランファイルを作成しました
─────────────────────────────
📋 イシュー:  #{{number}} {{title}}
📄 プラン:    {{plan-file-path}}
─────────────────────────────
{{2-3 line summary of the plan}}
─────────────────────────────

次のステップ:
- プランを確認・編集してから実行: /execute-plan {{plan-file-path}}
```

## Error Handling

- No argument provided → display usage message and abort
- Issue not found → display error and abort
- Issue closed → display warning and continue
- `gh` command failure → display error message and abort

## Important Notes

- The plan file content should be written in Japanese (matching existing plan files)
- Issue title conversion to kebab-case should produce a reasonable English slug
- Always include the GitHub issue number reference in the Context section
- The plan should be detailed enough to be executed by `/execute-plan`
- Investigate the codebase thoroughly before generating the plan to ensure accuracy
- All user-facing messages should be in Japanese
