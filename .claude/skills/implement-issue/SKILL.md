---
name: implement-issue
description: Fetch a GitHub issue, investigate the codebase, and implement the full workflow (branch → implement → test → commit → PR → review). Usage: /implement-issue <issue番号> [--codex]
disable-model-invocation: true
---

# Implement Issue: Issue → Investigate → Implement → Test → PR → Review

Fetch a GitHub issue by number, analyze the codebase, plan and implement changes, then execute the full workflow automatically.

## Arguments

- An issue number is **required** (e.g., `/implement-issue 42`)
- `--codex` (optional): Use Codex CLI (OpenAI) for review. Defaults to Claude (pr-code-reviewer) when omitted
- Example: `/implement-issue 42 --codex`
- If no argument is provided, display the following message and abort:
  ```
  ⚠️ エラー: イシュー番号を指定してください。使い方: /implement-issue <issue番号> [--codex]
  ```

## Steps

### 1. Validate arguments

- If no issue number is provided, display the error message above and abort

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
  ⚠️ 注意: イシュー #{{number}} はクローズ済みです。クローズ時点の内容で実装します
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

### 3. Investigate the codebase and generate plan via Plan agent

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

    ## Investigation Layers
    Investigate the following layers in order to identify areas that need changes:
    - **Routes**: `routes/web.php`, `routes/api.php` — route definitions
    - **Controllers**: `app/Http/Controllers/` — request handling
    - **Models**: `app/Models/` — Eloquent models and relationships
    - **Migrations**: `database/migrations/` — schema changes
    - **Views**: `resources/views/` — Blade/Volt templates
    - **Tests**: `tests/` — existing test coverage
    - **Config**: `config/` — configuration files
    - **Services/Actions**: `app/Services/`, `app/Actions/` — business logic

    ## Instructions
    1. Thoroughly investigate the codebase across the layers above to identify files that need to be changed
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
- Display investigation summary after the Plan agent completes:
  ```
  🔍 コードベース調査完了
  ─────────────────────────────
  関連ファイル: {{list of key files identified in the plan}}
  {{2-3 line summary of findings from the plan}}
  ─────────────────────────────
  ```

### 4. Save implementation plan

1. **Generate plan filename**
   - Convert the issue title to an English kebab-case slug
   - Conversion rules:
     - Translate Japanese to English if needed
     - Convert to all lowercase
     - Replace spaces with hyphens (`-`)
     - Remove all characters except alphanumeric and hyphens
     - Trim leading/trailing hyphens
   - Prepend issue number: `issue-{number}-`
   - Get current datetime with `date +%y%m%d%H%M%S` and append `_{yyMMddHHmmss}` suffix
   - Final filename: `.claude/plans/issue-{number}-{kebab-case}_{yyMMddHHmmss}.md`
   - Example: "ユーザー認証の追加" (Issue #42) → `.claude/plans/issue-42-add-user-authentication_260218143025.md`

2. **Write plan file**
   - Write the Plan agent's output directly to the file (do NOT use a hardcoded template)
   - The Plan agent has already formatted the content according to the template

3. **Display the plan summary**
   ```
   📋 実装プランを保存しました: {{plan-file-path}}
   ─────────────────────────────
   {{Numbered list of implementation tasks extracted from the plan}}
   ─────────────────────────────
   ```

### 5. Check the current branch and create a new branch if needed

```bash
git branch --show-current
```

- A "feature branch" is any branch that is NOT `develop`, `main`, or `staging`
- If already on a feature branch, continue as-is
- If on `develop`, create a new branch using the procedure below
- If on `main` or `staging`, display error and abort:
  ```
  ⚠️ エラー: 新しいブランチは develop からのみ作成できます（現在: {{branch}}）
  次のコマンドでdevelopブランチに切り替えてから再実行してください:
  git switch develop
  ```

#### Branch creation procedure (inline)

1. Confirm the current branch is `develop` (only `develop` is allowed as the base branch for new feature branches)
2. Generate a branch name from the issue title:
   - Convert the issue title into an English branch name
   - Conversion rules: all lowercase, replace spaces with hyphens (`-`), remove all characters except alphanumeric and hyphens
3. Add `feature/` prefix
4. Get today's date with `date +%Y%m%d` and append `_yyyyMMdd` suffix
   - Example: `feature/add-user-authentication_20260218`
5. Create and switch with `git switch -c <branch-name>`
6. Display success message:
   ```
   ✅ ブランチ '{{branch-name}}' を作成し、切り替えました
   ```

### 6. Implement and test via plan-executor agent

Launch the `plan-executor` agent via the **Task tool** to implement the plan and run tests.

```
Task tool parameters:
  subagent_type: "plan-executor"
  prompt: "以下のプランファイルを読み込んで実装してください: {{plan-file-path}}"
```

- The agent will:
  1. Read the plan file and investigate the codebase
  2. Implement all tasks described in the plan
  3. Run the full test suite
  4. Return a summary report

- If Task tool invocation fails or no valid report is returned, display an error and abort processing
- On agent completion, check the report (use the `status` field in テスト結果 section):
  - If status is `succeeded` → proceed to Step 7
  - If status is `failed`:
    ```
    ⚠️ テストが失敗しています。失敗内容を確認してください:
    {{summary from agent report}}

    実装は完了していますが、テスト失敗のため以降のステップをスキップします。
    手動で修正後、/commit → /create-pr → /review-pr を実行してください。
    ```
    Abort processing here

### 7. Commit (inline)

Execute the following commit procedure directly (do NOT call the `/commit` skill):

1. **Run Laravel Pint**
   ```bash
   docker compose exec app ./vendor/bin/pint
   ```
   - If it fails, display a warning but continue processing

2. **Stage all changes**
   ```bash
   git add -A
   ```

3. **Check staged diff**
   ```bash
   git diff --cached
   ```
   - If there is no diff, display the following message and abort:
     ```
     ⚠️ エラー: コミットする変更がありません
     ```

4. **Auto-generate commit message**
   - Analyze the staged diff and generate a concise commit message in Japanese
   - Rules:
     - First line: Summary of changes (aim for ~50 characters)
     - Accurately reflect the nature of changes (new feature, bug fix, refactoring, etc.)
     - Include `Closes #{{issue-number}}` on a separate line to auto-close the issue
     - Append `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>` at the end

5. **Execute commit**
   ```bash
   git commit -m "$(cat <<'EOF'
   コミットメッセージ

   Closes #{{issue-number}}

   Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
   EOF
   )"
   ```
   - On success, display:
     ```
     ✅ コミットしました: "コミットメッセージの1行目"
     ```

### 8. Create a PR (inline)

Execute the following PR creation procedure directly (do NOT call the `/create-pr` skill):

1. **Fetch latest remote branches**
   ```bash
   git fetch origin
   ```

2. **Push current branch if not yet pushed**
   ```bash
   git rev-parse --abbrev-ref HEAD
   git ls-remote --heads origin $(git rev-parse --abbrev-ref HEAD)
   ```
   - If the remote tracking branch does **not** exist (empty output), push:
     ```bash
     git push -u origin HEAD
     ```
   - If it already exists, skip this step

3. **Check diff against the base branch**
   ```bash
   git diff origin/develop...HEAD
   git log origin/develop...HEAD --oneline
   ```

4. **Generate PR title and body**
   - **PR title**: A concise summary of the changes (in Japanese)
   - **PR body**: Fill in all sections (概要, 詳細, 参考, 注意事項) based on the actual changes
   - **Issue linking**: Include `Closes #{{issue-number}}` in the 参考 section

5. **Create PR and open in browser**
   **IMPORTANT**: Use HEREDOC in a Bash command to create the temporary body file. Do NOT use the Write tool.
   ```bash
   cat > prbody.tmp << 'EOF'
   ## 概要
   {{概要}}

   ## 詳細
   {{詳細}}

   ## 参考
   Closes #{{issue-number}}

   ## 注意事項
   {{注意事項}}
   EOF

   gh pr create --draft --base develop --title "{{PRタイトル}}" --body-file prbody.tmp && \
   gh pr view --web

   rm -f prbody.tmp
   ```

   - On success, display:
     ```
     ✅ Pull Request を作成しました（Draft）
     ```
   - Record the created PR number for the next step

### 9. Review & Fix Loop (max 3 iterations)

Use Codex CLI if `--codex` is specified, otherwise use Claude (pr-code-reviewer).

```
loop_count = 0

while loop_count < 3:
  loop_count++

  ## Review (branch by reviewer)

  if reviewer == "claude":
    1. Launch pr-code-reviewer agent via Task tool
       prompt: "PR #{{pr-number}} をレビューしてください --auto-post --no-notify レビューフォーマットの総合評価セクションには必ず「LGTM」「軽微な修正後にマージ可」「修正が必要」「大幅な修正が必要」のいずれかを記載してください。"
       * If the agent returns an error, break the loop, display the error, and go to Step 10

    2. Fetch the latest PR comment and check the verdict
       ```bash
       gh api repos/{owner}/{repo}/issues/{{pr-number}}/comments --jq '[.[] | select(.body | test("総合評価"))] | last | .body'
       ```
       Parse the "総合評価" section from the comment body:
       - Contains "LGTM" → break loop, go to Step 10
       - Otherwise ("軽微な修正後にマージ可", "修正が必要", "大幅な修正が必要") → proceed to fix step
       - Section not found → break loop, display warning, go to Step 10

  if reviewer == "codex":
    1. Run the codex-review-pr script via Bash
       ```bash
       bash .claude/skills/codex-review-pr/codex-review-pr.sh {{pr-number}}
       ```
       * If the script exits with non-zero, break the loop, display the error, and go to Step 10

    2. Fetch the latest PR comment and check the verdict
       ```bash
       gh api repos/{owner}/{repo}/issues/{{pr-number}}/comments --jq '[.[] | select(.body | test("総合評価"))] | last | .body'
       ```
       Parse the "総合評価" section from the comment body:
       - Contains "LGTM" → break loop, go to Step 10
       - Otherwise ("軽微な修正後にマージ可", "修正が必要", "大幅な修正が必要") → proceed to fix step
       - Section not found → break loop, display warning, go to Step 10

  ## Fix (common)

  3. Launch pr-review-fixer agent via Task tool
     prompt: "PR #{{pr-number}} のレビューコメントを修正してコミット＆プッシュしてください --loop-count {{loop_count}} --no-notify"
     * If the agent returns an error, break the loop, display the error, and go to Step 10

  4. Continue to next iteration
```

After the loop:
- If LGTM:
  ```
  ✅ レビューLGTM ({{loop_count}}回目)
  ```
- If not LGTM after 3 iterations:
  ```
  ⚠️ 3回のレビューループでLGTMに至りませんでした。手動で確認してください。
  ```

#### Codex review evaluation (only when `--codex` is specified and NOT LGTM after 3 iterations)

When the loop ends without LGTM and `--codex` was used, evaluate the remaining review comments directly (do NOT launch a subagent). Use the review comment body already fetched in the last iteration of the loop (step 9, codex review section).

1. **Analyze each remaining review comment** from the latest review body
   - Classify each comment into one of three categories:
     - **(A) 対応が必要**: Genuine issues (bugs, security vulnerabilities, logic errors, missing error handling)
     - **(B) 対応推奨（必須ではない）**: Valid suggestions but not blocking (naming improvements, minor refactoring, style preferences beyond linter rules)
     - **(C) 過剰な指摘（対応不要）**: Overly strict or subjective comments (stylistic preferences already handled by linter, unnecessary abstractions, trivial nitpicks)

2. **Determine recommended action**
   - If there are any **(A)** items → recommend "手動修正が必要"
   - If there are only **(B)** and/or **(C)** items → recommend "マージ可"

3. **Display evaluation result**
   ```
   🔍 レビュー指摘の妥当性評価
   ─────────────────────────────
   (A) 対応が必要:
     - {{指摘内容の要約}}
   (B) 対応推奨（必須ではない）:
     - {{指摘内容の要約}}
   (C) 過剰な指摘（対応不要）:
     - {{指摘内容の要約}}
   ─────────────────────────────

   💡 推奨アクション: {{マージ可 / 手動修正が必要}}
   ```
   - If a category has no items, display "なし" for that category
   - Save the recommended action string for Step 10

### 10. Completion message

On completion of all steps, display the following summary:

```
══════════════════════════════════════════
✅ Implement Issue 完了
══════════════════════════════════════════
📋 イシュー:    #{{issue-number}} {{issue-title}}
📄 プラン:      {{plan-file-path}}
🌿 ブランチ:    {{branch-name}}
📝 コミット:    {{commit-hash-short}} "{{commit-message-first-line}}"
🔀 PR:          #{{pr-number}} {{PR title}}
🔍 レビュー:    {{レビュー結果 (例: "LGTM (1回目)" or "3回ループ後も未解決")}}
💡 評価:        {{評価サマリー (--codex かつ LGTM未達の場合のみ表示。例: "推奨アクション: マージ可")}}
══════════════════════════════════════════

次のステップ:
- LGTMの場合: /finish でマージ
- 未解決の指摘がある場合: 手動で確認・修正後、/review-fix で対応
- 評価が「マージ可」の場合: 指摘内容を確認の上、問題なければ /finish でマージ
```

## Error Handling

- No argument → display usage message and abort
- Issue not found → display error and abort
- Issue closed → display warning and continue
- On `main` or non-develop branch → display error and abort
- Test failure (plan-executor agent reports `failed`) → abort in implemented state (skip commit and PR creation)
- Commit/PR/Review errors → display error message and abort

## Important Notes

- All user-facing messages should be in Japanese
- The implementation should follow existing patterns found during codebase investigation
- Automatic test fix retries are limited to 3 attempts
- The commit message and PR body should include `Closes #{{issue-number}}` to auto-close the issue when merged
