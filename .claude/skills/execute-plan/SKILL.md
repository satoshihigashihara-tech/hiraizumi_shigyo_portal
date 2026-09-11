---
name: execute-plan
description: Read a plan file and execute implementation, testing, PR creation, and review in one go. Usage /execute-plan <plan-file-path> [--codex]
disable-model-invocation: true
---

# Execute Plan: Implement → Test → Create PR → Review

Read a plan file and execute the full workflow from implementation to review automatically.

## Arguments

- A plan file path is **required** (e.g., `/execute-plan docs/plan.md`)
- `--codex` (optional): Use Codex CLI (OpenAI) for review. Defaults to Claude (pr-code-reviewer) when omitted
- Example: `/execute-plan docs/plan.md --codex`
- If no argument is provided, display the following message and abort:
  ```
  ⚠️ エラー: プランファイルのパスを指定してください。使い方: /execute-plan <plan-file-path> [--codex]
  ```

## Steps

### 1. Read the plan file

Read the specified plan file and understand its contents.

- If the file does not exist:
  ```
  ⚠️ エラー: プランファイルが見つかりません: {{path}}
  ```
- If the file is empty:
  ```
  ⚠️ エラー: プランファイルが空です: {{path}}
  ```
- On successful read:
  ```
  📋 プランファイルを読み込みました: {{path}}
  ─────────────────────────────
  {{Summarize the plan in 2-3 lines}}
  ─────────────────────────────
  ```

### 2. Check the current branch and create a new branch if needed

```bash
git branch --show-current
```

- If already on a feature branch, continue as-is
- If on `develop`, create a new branch using the procedure below
- If on `main` or any other non-feature branch, display error and abort:
  ```
  ⚠️ エラー: 新しいブランチは develop からのみ作成できます（現在: {{branch}}）
  次のコマンドでdevelopブランチに切り替えてから再実行してください:
  git switch develop
  ```

#### Branch creation procedure (inline)

1. Confirm the current branch is `develop` (only `develop` is allowed as the base branch for new feature branches)
2. Generate a branch name from the plan content:
   - Convert the plan summary into an English branch name
   - Conversion rules: all lowercase, replace spaces with hyphens (`-`), remove all characters except alphanumeric and hyphens
3. Add `feature/` prefix
4. Get today's date with `date +%Y%m%d` and append `_yyyyMMdd` suffix
   - Example: `feature/add-user-authentication_20260211`
5. Create and switch with `git switch -c <branch-name>`
6. Display success message:
   ```
   ✅ ブランチ '{{branch-name}}' を作成し、切り替えました
   ```

### 3. Implement and test via plan-executor agent

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
  - If status is `succeeded` → proceed to Step 4
  - If status is `failed`:
    ```
    ⚠️ テストが失敗しています。失敗内容を確認してください:
    {{summary from agent report}}

    実装は完了していますが、テスト失敗のため以降のステップをスキップします。
    手動で修正後、/commit → /create-pr → /review-pr を実行してください。
    ```
    Abort processing here

### 4. Commit (inline)

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
     - Append `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>` at the end

5. **Execute commit**
   ```bash
   git commit -m "$(cat <<'EOF'
   コミットメッセージ

   Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
   EOF
   )"
   ```
   - On success, display:
     ```
     ✅ コミットしました: "コミットメッセージの1行目"
     ```

### 5. Create a PR (inline)

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
   - **Issue linking**: If a GitHub issue number is referenced in the context, include `Closes #XX` in the 参考 section

5. **Create PR and open in browser**
   **IMPORTANT**: Use HEREDOC in a Bash command to create the temporary body file. Do NOT use the Write tool.
   ```bash
   cat > prbody.tmp << 'EOF'
   ## 概要
   {{概要}}

   ## 詳細
   {{詳細}}

   ## 参考
   {{参考}}

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

### 6. Review & Fix Loop (max 3 iterations)

Use Codex CLI if `--codex` is specified, otherwise use Claude (pr-code-reviewer).

```
loop_count = 0

while loop_count < 3:
  loop_count++

  ## Review (branch by reviewer)

  if reviewer == "claude":
    1. Launch pr-code-reviewer agent via Task tool
       prompt: "PR #{{pr-number}} をレビューしてください --auto-post --no-notify レビューフォーマットの総合評価セクションには必ず「LGTM」「軽微な修正後にマージ可」「修正が必要」「大幅な修正が必要」のいずれかを記載してください。"
       * If the agent returns an error, break the loop, display the error, and go to Step 7

    2. Fetch the latest PR comment and check the verdict
       ```bash
       gh api repos/{owner}/{repo}/issues/{{pr-number}}/comments --jq '[.[] | select(.body | test("総合評価"))] | last | .body'
       ```
       Parse the "総合評価" section from the comment body:
       - Contains "LGTM" → break loop, go to Step 7
       - Otherwise ("軽微な修正後にマージ可", "修正が必要", "大幅な修正が必要") → proceed to fix step
       - Section not found → break loop, display warning, go to Step 7

  if reviewer == "codex":
    1. Run the codex-review-pr script via Bash
       ```bash
       bash .claude/skills/codex-review-pr/codex-review-pr.sh {{pr-number}}
       ```
       * If the script exits with non-zero, break the loop, display the error, and go to Step 7

    2. Fetch the latest PR comment and check the verdict
       ```bash
       gh api repos/{owner}/{repo}/issues/{{pr-number}}/comments --jq '[.[] | select(.body | test("総合評価"))] | last | .body'
       ```
       Parse the "総合評価" section from the comment body:
       - Contains "LGTM" → break loop, go to Step 7
       - Otherwise ("軽微な修正後にマージ可", "修正が必要", "大幅な修正が必要") → proceed to fix step
       - Section not found → break loop, display warning, go to Step 7

  ## Fix (common)

  3. Launch pr-review-fixer agent via Task tool
     prompt: "PR #{{pr-number}} のレビューコメントを修正してコミット＆プッシュしてください --loop-count {{loop_count}} --no-notify"
     * If the agent returns an error, break the loop, display the error, and go to Step 7

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

When the loop ends without LGTM and `--codex` was used, evaluate the remaining review comments directly (do NOT launch a subagent). Use the review comment body already fetched in the last iteration of the loop (step 6, codex review section).

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
   - Save the recommended action string for Step 7

### 7. Completion message

On completion of all steps, display the following summary:

```
══════════════════════════════════════════
✅ Execute Plan 完了
══════════════════════════════════════════
📋 プラン:      {{plan-file-path}}
🌿 ブランチ:    {{branch-name}}
📝 コミット:    {{commit-hash-short}} "{{commit-message-first-line}}"
🔀 PR:          #{{number}} {{PR title}}
🔍 レビュー:    {{レビュー結果 (例: "LGTM (1回目)" or "3回ループ後も未解決")}}
💡 評価:        {{評価サマリー (--codex かつ LGTM未達の場合のみ表示。例: "推奨アクション: マージ可")}}
══════════════════════════════════════════

次のステップ:
- LGTMの場合: /finish でマージ
- 未解決の指摘がある場合: 手動で確認・修正後、/review-fix で対応
- 評価が「マージ可」の場合: 指摘内容を確認の上、問題なければ /finish でマージ
```

## Error Handling

- No argument: Display usage message and abort
- Plan file not found / empty: Display error and abort
- Test failure (plan-executor agent reports `failed`): Abort in implemented state (skip commit and PR creation)
- Commit/PR/Review errors: Display error message and abort

## Important Notes

- Plan file format is flexible (Markdown recommended)
- All user-facing messages should be in Japanese
- Automatic test fix retries are limited to 3 attempts
