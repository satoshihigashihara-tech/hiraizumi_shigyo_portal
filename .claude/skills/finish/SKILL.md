---
name: finish
description: Merge the current branch's PR, delete feature branch, switch to base branch, and pull latest. Usage /finish
disable-model-invocation: true
---

# Finish: PR Merge, Branch Cleanup & Update

Merge the current branch's PR, delete the feature branch, switch back to the base branch, and pull latest changes.

Run the finish script:

```bash
bash .claude/skills/finish/finish.sh
```

Display the script output to the user as-is. Do NOT follow up with additional actions (e.g., manual branch deletion) if the script reports errors or warnings.
