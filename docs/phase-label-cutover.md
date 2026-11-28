# Phase label cut-over

Per repo that has GitHub issue statuses (a GitHub preview; a repo without them keeps the `phase:*` labels, they are its only phase signal). Rerunnable at any step:

1. Detect: `bash ~/.claude/skills/aw-setup/detect.sh` prints `issue_statuses: yes` (or `no`/`unknown`: stop here). `WF_REPO=<owner>/<repo> bash ~/.claude/agent-workflow/bin/issue-status.sh get <n>` on any issue shows its status.
2. Switch: `WF_PHASE_LABELS=off` in the repo's `.claude/issue-workflow.sh`, merged.
3. Dry run: `WF_REPO=<owner>/<repo> bash ~/.claude/agent-workflow/bin/issue-status.sh cutover` prints the plan per open issue with a `phase:*` label and writes nothing.
4. Apply: the same with `--apply` sets each status (In progress; In review and In progress stay), then removes the label; an issue whose status cannot be set keeps it. Rerun until it prints "nothing to do".
5. Once every repo the board client reads is off, the client drops its `phase:*` rules (Tandem: `src/core/config.ts`, ADR 0006).
