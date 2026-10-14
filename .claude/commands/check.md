---
description: Run Tools/check.sh (the local CI) and explain the result
argument-hint: [--fast | --red]
---

Run `Tools/check.sh $ARGUMENTS` from the repo root (it can take a few minutes in full mode; give it a
generous timeout). Then report:

- **Green:** one line, with the coverage number and whether it rose (if it rose, offer to run
  `Tools/coverage.sh --update-baseline` and commit the baseline).
- **Red:** for each failed step, what failed and the most likely cause, quoting the relevant lines
  from the step's log under `.build/check/`. Explain any iOS-specific cause in a sentence (for
  example, why a Release-only compile error happens). Suggest the fix, but do not change code unless
  asked.

What each step checks is in `docs/process/WORKFLOW.md`, "Local CI".
