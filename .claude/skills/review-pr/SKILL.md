---
name: review-pr
description: Review a specified pull request by number and post review comment. Usage /review-pr <PR番号>
disable-model-invocation: true
---

# Review PR

Fetch a specified pull request, analyze the code changes, and post a structured review comment on the PR.

## Arguments

- A PR number is **required** (e.g., `/review-pr 42`)
- If no argument is provided, display the following message and abort:
  ```
  ⚠️ エラー: PR番号を指定してください。使い方: /review-pr <PR番号>
  ```

## Steps

### 1. Fetch PR details

```bash
gh pr view {{number}} --json number,title,body,author,baseRefName,headRefName,state,additions,deletions,changedFiles,url
```

- If the PR does not exist, display the following message and abort:
  ```
  ⚠️ エラー: PR #{{number}} が見つかりません
  ```
- If the PR state is `MERGED`, display a warning but continue:
  ```
  ⚠️ 注意: PR #{{number}} は既にマージ済みです。マージ時点のコードをレビューします
  ```
- If the PR state is `CLOSED`, display a warning but continue:
  ```
  ⚠️ 注意: PR #{{number}} はクローズされています。クローズ時点のコードをレビューします
  ```

- Display PR summary:
  ```
  📋 PR #{{number}} の情報
  ─────────────────────────────
  タイトル: {{title}}
  作成者:   @{{author.login}}
  ステータス: {{state}}
  ブランチ: {{headRefName}} → {{baseRefName}}
  変更:    +{{additions}} -{{deletions}} ({{changedFiles}}ファイル)
  URL:     {{url}}
  ─────────────────────────────
  ```

### 2. Fetch changed files list

```bash
gh pr view {{number}} --json files --jq '.files[].path'
```

- Save the file list for determining which review rules to apply

### 3. Fetch the full diff

```bash
gh pr diff {{number}}
```

- Count the diff lines with `gh pr diff {{number}} | wc -l`
- If the diff exceeds 10,000 lines, display a warning:
  ```
  ⚠️ 注意: diffが非常に大きいため ({{lines}}行)、主要な変更に焦点を絞ってレビューします
  ```

### 4. Determine applicable review rules

Based on the changed files, read the applicable `.claude/rules/` files:

| Changed file path pattern | Rule file to read |
|---------------------------|-------------------|
| `app/Models/**`, `database/migrations/**`, `database/seeders/**`, `database/factories/**` | `.claude/rules/database.md` |
| `app/Http/Controllers/Api/**`, `app/Http/Resources/**`, `routes/api.php`, `routes/web.php`, `routes/*.php` | `.claude/rules/api.md` |
| `resources/views/**`, `resources/js/**`, `resources/css/**` | `.claude/rules/frontend.md` |
| `tests/**` | `.claude/rules/testing.md` |
| Any PHP file (`*.php`) | `.claude/rules/laravel.md` |
| Config/doc files (`.md`, `.yml`, `.yaml`, `.json`, `.xml`) | Review for typos, format consistency, and correctness |
| Any file (always apply) | `.claude/rules/security.md` |

Read only the applicable rule files and use them as review criteria.

### 5. Analyze and review the code changes

Thoroughly analyze the diff considering:

1. **PR description alignment** - Do the actual changes match the described intent?
2. **Code quality** - Based on applicable `.claude/rules/`
3. **Potential bugs** - Logic errors, edge cases, null handling
4. **Security** - Based on `.claude/rules/security.md`
5. **Performance** - N+1 queries, unnecessary processing, large dataset handling
6. **Best practices** - Laravel conventions, PSR-12, project patterns

### 6. Post review comment on PR

Compose the review in the following Markdown format and post it as a PR comment.

**Review format:**

```markdown
## 🔍 コードレビュー

### 📝 変更概要
<!-- 2-3 sentence summary -->

### ✅ 良い点
<!-- 1-2 lines max. Keep it brief -->

### ⚠️ 指摘事項
<!-- Only include severity levels that have findings. Omit empty levels entirely (do NOT write "なし") -->
<!-- Available levels (use only those with findings): -->
<!-- #### 🔴 重要 -->
<!-- #### 🟡 推奨 -->
<!-- #### 🔵 軽微 -->

### 📊 総合評価
<!-- LGTM / 軽微な修正後にマージ可 / 修正が必要 / 大幅な修正が必要 -->
```

**Finding format rules:**
- Each finding: **`file/path:line_number`** + 1-2 sentence description
- Code suggestions (```suggestion) only for 🔴 and 🟡, keep them minimal
- No code suggestions for 🔵 (text only)

**Post the comment:**

**IMPORTANT**: Use HEREDOC in a Bash command to create the temporary body file. Do NOT use the Write tool.

```bash
# Create review body as a temp file using HEREDOC
cat > review_body.tmp << 'EOF'
{{レビュー内容}}
EOF

# Post comment on PR
gh pr comment {{number}} --body-file review_body.tmp

# Clean up temp file
rm -f review_body.tmp
```

- On success, display:
  ```
  ✅ PR #{{number}} にレビューコメントを投稿しました
  {{url}}
  ```
- On failure, display the error message

## Error Handling

- No PR number provided: Display usage message and abort
- PR not found: Display error and abort
- `gh` command failure: Display error message and abort
- Excessively large diff: Display warning and continue (focus review on key changes)
- Comment post failure: Display error message

## Important Notes

- This skill does NOT modify any files or branches
- This skill works from any branch (does not require checkout of the PR's branch)
- Always apply `.claude/rules/security.md` regardless of file types
- When the diff is too large, prioritize reviewing: security issues > bugs > code quality > style
- Include specific file paths and approximate line numbers in all feedback
- Provide concrete code suggestions where possible, not just abstract feedback
- All review content should be in Japanese
