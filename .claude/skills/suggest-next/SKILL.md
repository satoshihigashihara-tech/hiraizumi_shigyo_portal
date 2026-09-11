---
name: suggest-next
description: Analyze project status and recent 20 PRs to suggest prioritized next actions. Usage /suggest-next
disable-model-invocation: true
---

# Suggest Next: Analyze project status and suggest next actions

Analyze the current project state (branch status, uncommitted changes, open issues, recent PRs) and generate prioritized suggestions for next actions. Save the result to `working/suggests/yyyyMMddHHmm.md`.

## Arguments

- No arguments required (`/suggest-next`)

## Steps

### 1. Check current branch status

```bash
git branch --show-current
git status --short
```

- Record the current branch name and whether there are uncommitted changes
- If there are uncommitted changes, flag this for inclusion in high-priority suggestions

### 2. Collect GitHub data

Run the following commands **in parallel** to collect project data:

```bash
# Recent 20 PRs (all states)
gh pr list --state all --limit 20 --json number,title,state,mergedAt,labels,headRefName,createdAt

# Open issues (include updatedAt for accurate stale detection)
gh issue list --state open --json number,title,labels,createdAt,updatedAt,assignees

# Open PRs (to identify drafts)
gh pr list --state open --json number,title,headRefName,createdAt,isDraft
```

- If `gh` commands fail, display the following message and abort:
  ```
  ⚠️ エラー: GitHubへのアクセスに失敗しました。`gh auth status` で認証状態を確認してください。
  ```

### 3. Analyze data

#### 3a. Identify incomplete work

- **Draft PRs**: PRs with `isDraft == true` — these need to be completed and reviewed
- **Open PRs (non-draft)**: PRs awaiting review or merge
- **Uncommitted changes**: Work in progress on the current branch

#### 3b. Prioritize open issues by labels

- Labels containing `bug` or `urgent` → **High priority**
- Labels containing `enhancement` or `feature` → **Medium priority**
- No labels or other labels → **Normal priority**
- Issues with no updates (`updatedAt`) for more than 30 days → Add stale warning regardless of label

#### 3c. Analyze recent PR patterns

Examine the titles, labels, and branch names of the most recent 20 PRs to identify:

- **Work themes**: What areas of the codebase have been actively worked on (e.g., consecutive bug fixes, feature development on a specific module, refactoring)
- **Follow-up needs**: Based on patterns, suggest logical next steps (e.g., after a series of bug fixes → suggest test improvements; after feature development → suggest documentation)
- **Merge frequency**: Count PRs merged in the last 7 days to gauge development velocity

### 4. Generate suggestions in 3 priority levels

Based on the analysis, generate suggestions categorized as follows. Each category has a maximum of 3 items.

**🔴 今すぐ対応（高優先度）** — max 3 items:
- Uncommitted changes that need to be committed or stashed
- Draft PRs that need to be completed
- Open issues with `bug` or `urgent` labels

**🟡 近いうちに対応（中優先度）** — max 3 items:
- Open PRs awaiting review or merge
- Open issues with `enhancement` or `feature` labels
- Follow-up tasks inferred from recent PR patterns

**🟢 余裕があれば対応（低優先度）** — max 3 items:
- Stale issues (30+ days old)
- Test improvements or documentation suggested by recent patterns
- General maintenance or refactoring opportunities

Each suggestion must include:
- A concise description of what needs to be done
- A reference to the relevant issue number (`#XX`) or PR number (`PR #XX`) where applicable
- A concrete action using an existing skill command (e.g., `/implement-issue XX`, `/plan-issue XX`, `/finish`, `/review-fix`, `/create-issue`)

### 5. Save suggestions to file

1. **Get current datetime**
   ```bash
   date +%Y%m%d%H%M
   ```

2. **Create directory if needed**
   ```bash
   mkdir -p working/suggests
   ```

3. **Save to file using HEREDOC in Bash** (do NOT use the Write tool)
   - Filename: `working/suggests/{{yyyyMMddHHmm}}.md`
   - **HEREDOC delimiter note**: Use a unique delimiter (e.g., `'SUGGEST_EOF'`) with single quotes to prevent variable expansion. If suggestion content may contain special characters, ensure the delimiter does not appear in the content.

File content format:

```markdown
# 提案: {{yyyy/MM/dd HH:mm}}

## プロジェクト状況サマリー
- ブランチ: {{current-branch}}
- 未コミット変更: {{あり / なし}}
- オープンイシュー: {{count}}件
- オープンPR: {{count}}件（うちドラフト{{count}}件）
- 直近マージ済PR: {{count}}件（過去7日間）

## 直近の開発トレンド
{{2-3 line summary of recent development trends}}

## 🔴 今すぐ対応（高優先度）
1. {{suggestion}} #XX
   → {{concrete action}}

## 🟡 近いうちに対応（中優先度）
1. {{suggestion}} #XX
   → {{concrete action}}

## 🟢 余裕があれば対応（低優先度）
1. {{suggestion}}
   → {{concrete action}}
```

- If a category has no items, write "なし" under that heading

### 6. Display formatted result to console

```
══════════════════════════════════════════
📊 プロジェクト状況サマリー
══════════════════════════════════════════
ブランチ:       {{current-branch}}
未コミット変更:  {{あり / なし}}
オープンイシュー: {{count}}件
オープンPR:       {{count}}件（うちドラフト{{count}}件）
直近マージ済PR:   {{count}}件（過去7日間）
══════════════════════════════════════════

📈 直近の開発トレンド
─────────────────────────────────────────
{{2-3 line summary of recent development trends}}
─────────────────────────────────────────

🔴 今すぐ対応（高優先度）
─────────────────────────────────────────
1. {{suggestion}} #XX
   → {{concrete action (e.g., /implement-issue XX)}}
─────────────────────────────────────────

🟡 近いうちに対応（中優先度）
─────────────────────────────────────────
1. {{suggestion}} #XX
   → {{concrete action}}
─────────────────────────────────────────

🟢 余裕があれば対応（低優先度）
─────────────────────────────────────────
1. {{suggestion}}
   → {{concrete action}}
─────────────────────────────────────────

💾 保存先: working/suggests/{{yyyyMMddHHmm}}.md

次のステップ:
- イシューの実装: /implement-issue <issue番号>
- プラン作成: /plan-issue <issue番号>
- 新規イシュー: /create-issue
══════════════════════════════════════════
```

- If a category has no items, display "なし" under that heading

### 7. Handle empty suggestions

If there are no open issues, no draft PRs, no open PRs, and no uncommitted changes:

```
══════════════════════════════════════════
📊 プロジェクト状況サマリー
══════════════════════════════════════════
ブランチ:       {{current-branch}}
未コミット変更:  なし
オープンイシュー: 0件
オープンPR:       0件
══════════════════════════════════════════

✨ 現在、対応が必要なタスクはありません！

💾 保存先: working/suggests/{{yyyyMMddHHmm}}.md

次のステップ:
- 新規イシュー: /create-issue
══════════════════════════════════════════
```

## Error Handling

- `gh` command failure (authentication error, etc.) → display error message and abort
- Not a GitHub repository → display error message and abort

## Important Notes

- This skill makes NO code changes — it is read-only analysis plus file save only
- Limit each priority category to a maximum of 3 suggestions to avoid information overload
- Each suggestion must include a reference to an existing skill command for actionable next steps
- Save file must be created using HEREDOC in Bash, NOT the Write tool
- All user-facing messages (display output, file content) should be in Japanese
- Skill prompt/instructions are written in English (matching existing skill conventions)
