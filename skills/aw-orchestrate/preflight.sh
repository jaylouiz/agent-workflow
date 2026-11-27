#!/usr/bin/env bash
# Preflight of /aw-orchestrate (SKILL.md section 0, step 1): the coordinator needs the `orca` CLI. Without it this
# stops the skill before anything else runs and names the manual path. Run: preflight.sh
# Exit: 0 `orca` is on PATH (prints nothing), 69 it is not (the message below, on stdout, is what the user gets).
set -u
command -v orca >/dev/null 2>&1 && exit 0
cat <<'MSG'
/aw-orchestrate needs Orca: there is no `orca` on PATH (https://github.com/stablyai/orca). Nothing was started.

Without Orca, take each issue through its stages yourself, one skill at a time:
  /aw-ui-design <n>   label needs-design: design rounds, then the UX decision
  /aw-specify <n>     label needs-spec: the spec
  /aw-build <n>       label ready: the PR; then /code-review

A stage that needs a decision from you parks its issue with a decision request. Your decision inbox:
  ~/.claude/agent-workflow/bin/decide.sh status    answered and waiting requests
  ~/.claude/agent-workflow/bin/decide.sh digest    the waiting ones as one list
Answer on the issue, then run the same stage skill again: it reads your answer and continues where it parked.
MSG
exit 69
