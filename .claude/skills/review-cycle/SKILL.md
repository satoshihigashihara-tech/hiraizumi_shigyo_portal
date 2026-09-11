---
name: review-cycle
description: Fix PR review comments and re-review until LGTM (max 3 iterations). Usage /review-cycle [--codex]
disable-model-invocation: true
---

# Review Cycle

Fix PR review comments, re-review, and repeat until LGTM is achieved. Maximum 3 iterations. Uses Claude (pr-code-reviewer) by default, or Codex CLI with the `--codex` flag.

## Arguments

- `--codex` (optional): Use Codex CLI (OpenAI) for review instead of Claude
- Example: `/review-cycle --codex`

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
- Display:
  ```
  🔄 PR #{{number}} のレビューサイクルを開始します (最大3回)
  ```

### 3. Review & Fix Loop (max 3 iterations)

```
iteration = 0
lgtm = false

while iteration < 3 AND lgtm == false:
  iteration++
  display: "── イテレーション {{iteration}}/3 ──"
```

#### 3a. Fix review comments

**On first iteration (iteration == 1):** Check if review comments already exist on the PR:

```bash
# Note: {owner}/{repo} is auto-expanded by gh api; {{number}} is a skill placeholder
gh api repos/{owner}/{repo}/issues/{{number}}/comments --jq '[.[] | select(.body | test("総合評価"))] | length'
```

This filters comments to only count those containing the review format marker ("総合評価"), excluding unrelated comments from the PR author, bots, or other users.

- If the count is **0** (no review comments): Skip this step and proceed directly to step 3b.
- If the count is **> 0** (review comments found): Execute the fix step below (same as iteration >= 2).

This handles cases where the PR already has review comments from a previous review cycle or manual review.

**On subsequent iterations (iteration >= 2):**

Launch the `pr-review-fixer` agent via the **Task tool** to fix code based on review comments, commit, and push.

```
Task tool parameters:
  subagent_type: "pr-review-fixer"
  prompt: "PR #{{number}} のレビューコメントを確認し、指摘に基づいてコードを修正してください。修正後、Laravel Pint を実行してからコミット＆プッシュしてください。"
```

- If the agent reports no review comments exist, display a warning and skip to 3b

#### 3b. Execute review

**When `--codex` is NOT specified (default — Claude review):**

Launch the `pr-code-reviewer` agent via the **Task tool** to review the PR and post a review comment.

```
Task tool parameters:
  subagent_type: "pr-code-reviewer"
  prompt: "PR #{{number}} をレビューして、レビューコメントをPRに投稿してください。レビューフォーマットの総合評価セクションには必ず「LGTM」「軽微な修正後にマージ可」「修正が必要」「大幅な修正が必要」のいずれかを記載してください。"
```

After the agent completes, fetch the latest review comment from the PR and check the verdict:

1. Fetch the latest review comment:
   ```bash
   gh api repos/{owner}/{repo}/issues/{{number}}/comments --jq '[.[] | select(.body | test("総合評価"))] | last | .body'
   ```
   - This filters comments to only those containing the "総合評価" section, avoiding false matches from unrelated comments by other users or bots

2. Parse the "総合評価" section from the comment body:
   - Contains "LGTM" → set `lgtm = true`
   - Otherwise ("軽微な修正後にマージ可", "修正が必要", "大幅な修正が必要") → continue to next iteration
   - Section not found → break the loop and display a warning

**When `--codex` is specified (Codex review):**

1. Run the codex-review-pr script:
   ```bash
   bash .claude/skills/codex-review-pr/codex-review-pr.sh {{number}}
   ```
   - If the script fails, display the error and break the loop

2. Fetch the latest review comment from the PR:
   ```bash
   gh api repos/{owner}/{repo}/issues/{{number}}/comments --jq '[.[] | select(.body | test("総合評価"))] | last | .body'
   ```
   - This filters comments to only those containing the "総合評価" section, avoiding false matches from unrelated comments by other users or bots

3. Parse the "総合評価" section from the comment body:
   - Contains "LGTM" → set `lgtm = true`
   - Otherwise → continue to next iteration

#### 3c. Display iteration result

- If `lgtm == true`:
  ```
  ✅ LGTM！ (イテレーション {{iteration}}/3)
  ```
- If `lgtm == false` and `iteration < 3`:
  ```
  🔄 LGTMではありません。次のイテレーションに進みます...
  ```
- If `lgtm == false` and `iteration == 3`:
  ```
  ⚠️ LGTMではありません。最大イテレーション回数に達しました。
  ```

#### Codex review evaluation (only when `--codex` is specified and `lgtm == false` after 3 iterations)

When the loop ends without LGTM and `--codex` was used, evaluate the remaining review comments directly (do NOT launch a subagent). Use the review comment body already fetched in the last iteration of the loop (step 3b).

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
   - Save the recommended action string for Step 4

### 4. Display final result

After the loop ends:

- If `lgtm == true`:
  ```
  ══════════════════════════════════════════
  ✅ レビューサイクル完了 — LGTM
  ══════════════════════════════════════════
  PR:          #{{number}} {{url}}
  イテレーション: {{iteration}}回目でLGTM取得
  ══════════════════════════════════════════
  ```

- If `lgtm == false` (max iterations reached):
  ```
  ══════════════════════════════════════════
  ⚠️ レビューサイクル完了 — LGTM未達
  ══════════════════════════════════════════
  PR:          #{{number}} {{url}}
  イテレーション: 3回実行しましたがLGTMに至りませんでした
  💡 評価:        {{評価サマリー (--codex かつ LGTM未達の場合のみ表示。例: "推奨アクション: マージ可")}}
  手動で確認してください。
  ══════════════════════════════════════════
  ```

## Error Handling

- On `develop`/`main`/`staging`: Display error and abort
- No PR found: Display error and abort
- PR is `MERGED`: Display error and abort
- PR is `CLOSED`: Display error and abort
- pr-review-fixer agent error: Display error and break the loop
- pr-code-reviewer agent error: Display error and break the loop
- Codex script failure: Display error and break the loop

## Important Notes

- This skill does NOT create PRs — the PR must already exist
- The pr-review-fixer agent handles: reading comments, modifying code, running Pint, committing, and pushing
- The pr-code-reviewer agent handles: fetching diff, analyzing code, and posting a review comment on the PR
- LGTM is the ONLY condition that stops the loop successfully; "軽微な修正後にマージ可" triggers another iteration
- All user-facing messages should be in Japanese
