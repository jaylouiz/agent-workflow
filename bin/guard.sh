#!/usr/bin/env bash
# PreToolUse hook (Bash), registered in the workflow skills' frontmatter. Turns three prose rules into checks:
#   1. `gh pr create`: body has `Closes #<n>` and the Claude Code attribution (WF_PR_ATTRIBUTION=off in the global
#      settings file or the repo config drops the attribution check), and passes the project's wf_pr_body_check
#      (<repo>/.claude/issue-workflow.sh), e.g. a required `Test plan:` line. The project check belongs to the
#      session's repo: a PR for another repo (`-R`, `--repo`, a `GH_REPO=` prefix) skips it.
#   2. `gh issue comment`: body carries a `<!-- decision-` marker, so `decide.sh status` never reads an agent
#      comment as the user's (use `decide.sh note`; with --attach, put `<!-- decision-note -->` in the file),
#      and stays scannable (`decide.sh check`: visible length cap, no wall-of-text line).
#   3. `gh issue edit|create` and `gh pr edit` with a body: the body is not empty; a `gh pr edit` body also has
#      `Closes #<n>` and the attribution (not a fragment) and passes the project check as in 1. (a truncated or
#      empty --body-file once wiped an issue spec).
#   4. Orca V3 (1.4.246+): no `orca orchestration check --wait` at all (coordinators end their turn and Orca wakes
#      them; a waiter takes the mail Orca would wake them with), and `ask` never ends in a trailing `&`.
#   5. `gh pr merge` is its own call: a real invocation followed by another command in the same call (`&&`, `;`,
#      `||`, `|`, `&`, a newline; also inside `bash -c '…'`) is blocked, so the project gate hook sees the merge
#      before `merge-pr.sh after` runs (aw-orchestrate section 2). Preceding commands (`cd x && gh pr merge`)
#      and a lone merge stay allowed; heredoc bodies and quoted text never count.
# One lexing path for every check: prep() (one quote-aware scan: `#` comments, heredoc bodies and line continuations
# dropped, `$'..'` and `"$(..)"` normalised, `<<` in `$((..))` is a shift) feeds shlex; newlines separate commands. So text
# quoted in a comment or heredoc body is never read as a command (#37), and an apostrophe there cannot unbalance the
# quotes (#29). Input that is still unparsable fails open with a visible warning (stderr plus a systemMessage); a crash of
# the python block exits 1 with a stderr warning, never silently (#38).
# Only real invocations count (shell-parsed), not text inside a commit message or an echo.
# A --body-file that does not exist yet (written in the same command) and a body the shell builds at run time
# ("$(cat …)", "$VAR", an ANSI-C $'…' word, a heredoc) are allowed: they cannot be checked here. Exit 2 blocks.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

input=$(cat)
[ -n "$input" ] || exit 0
cmd=$(printf '%s' "$input" | jq -r 'select(.tool_name == "Bash") | .tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null

# Cheap prefilter before parsing.
printf '%s' "$cmd" | grep -Eq 'gh +(pr +(create|edit)|issue +(comment|edit|create))|gh +.*pr +merge|orca +orchestration' || exit 0

# Parse with shlex: one TSV line per finding: kind \t body-kind (file|inline|none) \t target repo (`-`: none given)
# \t value (inline: base64). The value comes last: `read` merges empty tab fields.
findings=$(CMD="$cmd" "${GUARD_PYTHON:-python3}" -I -c '
import os, re, shlex, base64
cmd = os.environ["CMD"]
SEP_CHARS = set(";&|()\n")
OPS = re.compile(r"&&|\|\||;;&|;;|;&|\|&|&|;|\||\(|\)|\n")
def split(toks):
    segs, cur, seps = [], [], []
    for t in toks:
        if t and set(t) <= SEP_CHARS and not (t == "&" and cur and cur[-1] and cur[-1][-1] in "<>"):
            for op in OPS.findall(t):  # shlex glues adjacent operator chars (`&` + newline + `)`): one separator per operator (#39)
                segs.append(cur); seps.append(op); cur = []
        else:
            cur.append(t)
    segs.append(cur); seps.append("")
    return segs, seps
KW = ("if", "while", "until", "then", "do", "else", "elif", "{", "!", "time", "exec", "command")
def strip_env(s):
    i = 0
    while i < len(s) and (s[i] in KW or "=" in s[i] and not s[i].startswith("-") and s[i].split("=")[0].isidentifier()):
        i += 1
    return s[i:]
SQ, DQ, BS, NL = chr(39), chr(34), chr(92), chr(10)  # no literal quotes here: this whole block sits inside shell single quotes
HEREDOC = re.compile(r"<<(-?)[ \t]*(?:" + SQ + "([^" + SQ + r"]*)" + SQ + r"|\"([^\"]*)\"|\\?([^\s;&|()<>`" + DQ + SQ + BS + BS + "]+))")
WORD_START = " \t\n;&|()"  # a `#` after one of these starts a comment
def prep(text):  # one quote-aware scan: comments, line continuations and heredoc bodies go, ANSI-C strings and quoted substitutions are normalised so shlex can lex the rest
    n, pending = len(text), []  # pending: heredocs whose body starts after the next newline
    def bodies(i):  # i: just after a newline; skip the bodies (and delimiter lines) of the pending heredocs
        while pending and i < n:
            d, dash = pending.pop(0)
            while i < n:
                j = text.find(NL, i)
                j = n if j < 0 else j
                line, i = text[i:j], j + 1
                if (line.lstrip("\t") if dash else line) == d: break
        pending.clear()  # an unterminated heredoc runs to the end of the text, as in the shell
        return i
    def arith(i):  # i at the first paren of `((`: index after the matching `))`
        depth = 0
        while i < n:
            if text[i] == "(": depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0: return i + 1
            i += 1
        raise ValueError("unbalanced arithmetic")
    def dq(i):  # after an opening double quote: (body with $(..) collapsed to $(), index after the closing quote)
        out = []
        while i < n:
            ch = text[i]
            if ch == DQ: return "".join(out), i + 1
            if ch == BS and i + 1 < n:
                if text[i + 1] != NL: out.append(text[i:i + 2])  # backslash-newline: the shell deletes both
                i += 2
            elif text.startswith("$((", i):
                j = arith(i + 1); out.append(text[i:j]); i = j
            elif text.startswith("$(", i):
                i = scan(i + 2, True)[1]; out.append("$()")  # never lexed as a command in a word, so its quotes must not reach shlex
            elif ch == "`":
                j = text.find("`", i + 1)
                if j < 0: raise ValueError("unbalanced backtick")
                out.append("``"); i = j + 1
            else:
                out.append(ch); i += 1
        raise ValueError("unbalanced double quote")
    def scan(i, closer):  # command text from i: (cleaned text, index after it); closer: stop after the `)` that ends a $( .. )
        out, depth, esc = [], 0, -2  # esc: index of the last backslash-escaped character
        while i < n:
            ch = text[i]
            if ch == BS and i + 1 < n:
                if text[i + 1] != NL: out.append(text[i:i + 2]); esc = i + 1
                i += 2
            elif ch == SQ:
                j = text.find(SQ, i + 1)
                j = n - 1 if j < 0 else j  # unterminated: the rest stays, shlex reports it
                out.append(text[i:j + 1]); i = j + 1
            elif ch == "$" and text.startswith(SQ, i + 1):  # ANSI-C string: backslash escapes, so an escaped quote does not close it
                j = i + 2
                while j < n and text[j] != SQ: j += 2 if text[j] == BS else 1
                if j >= n: raise ValueError("unbalanced ANSI-C quote")
                out.append("$" + SQ + text[i + 2:j].replace(SQ, "_") + SQ); i = j + 1  # keep the `$`: the word is built at run time (escapes undecoded here), so dyn() leaves it unchecked like "$VAR"
            elif ch == DQ:
                s, i = dq(i + 1); out.append(DQ + s + DQ)
            elif text.startswith("$((", i):
                j = arith(i + 1); out.append(text[i:j]); i = j  # `<<` in here is a shift
            elif text.startswith("((", i):
                j = arith(i); out.append(text[i:j]); i = j
            elif text.startswith("$[", i):  # legacy arithmetic: `<<` in here is a shift
                j = text.find("]", i)
                j = n if j < 0 else j + 1
                out.append(text[i:j]); i = j
            elif ch == "$" and text.startswith("(", i + 1):
                s, i = scan(i + 2, True); out.append("$(" + s + ")")
            elif ch == ")" and closer and depth == 0:
                return "".join(out), i + 1
            elif ch == "#" and esc != i - 1 and (i == 0 or text[i - 1] in WORD_START):
                while i < n and text[i] != NL: i += 1
            elif text.startswith("<<<", i):  # here-string
                out.append("<<<"); i += 3
            elif text.startswith("<<", i):
                m = HEREDOC.match(text, i)
                if m:
                    pending.append((m.group(2) or m.group(3) or m.group(4), m.group(1) == "-")); out.append(m.group(0)); i = m.end()
                else:
                    out.append("<<"); i += 2
            elif ch == NL:
                out.append(NL); i = bodies(i + 1)
            else:
                if ch == "(": depth += 1
                elif ch == ")": depth -= 1
                out.append(ch); i += 1
        if closer: raise ValueError("unbalanced command substitution")
        return "".join(out), i
    return scan(0, False)[0]
def clean_split(text):  # the one lexing path: heredoc bodies and comments gone, newlines separate commands
    lex = shlex.shlex(prep(text), posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace_split = True
    lex.commenters = ""
    lex.whitespace = " \t\r"
    return split(list(lex))
def pr_merge(s):  # gh [-R repo] pr merge …
    i = 1
    while i < len(s) and s[i].startswith("-"): i += 2 if s[i] in ("-R", "--repo") else 1
    return s[i:i + 2] == ["pr", "merge"]
END = ("fi", "done", "esac", "}", "end")
def merge_scan(text, depth=0):  # (has a real `gh pr merge`, another command follows one in the same call)
    try:
        ms, _ = clean_split(text)
    except ValueError:
        return False, False
    has = False
    for i, s in enumerate(ms):
        s = strip_env(s)
        if not s: continue
        exe = os.path.basename(s[0])
        found = False
        if exe == "gh" and pr_merge(s):
            found = True
        elif exe in ("bash", "sh", "zsh") and depth < 2:  # bash -c '…', bash -lc '…'
            c = [j for j, t in enumerate(s[1:-1], 1) if re.fullmatch(r"-[A-Za-z]*c", t)]
            if c:
                h, chained = merge_scan(s[c[0] + 1], depth + 1)
                if chained: return True, True
                found = h
        if found:
            has = True
            for later in ms[i + 1:]:
                later = strip_env(later)
                if later and not later[0].startswith("#") and later[0] not in END: return True, True
    return has, False
if merge_scan(cmd)[1]: print("merge-chain\tnone\t-\t")
def dyn(v):  # built by the shell at run time (command substitution, variable, heredoc): cannot be checked here
    return "$" in v or "`" in v or "<<" in v
def inline(v):
    return ("unverifiable", "") if dyn(v) else ("inline", base64.b64encode(v.encode()).decode())
def body(s):
    for i, t in enumerate(s):
        if t in ("--body-file", "-F") and i + 1 < len(s): return "file", s[i + 1]
        if t.startswith("--body-file="): return "file", t.split("=", 1)[1]
        if t in ("--body", "-b") and i + 1 < len(s): return inline(s[i + 1])
        if t.startswith("--body="): return inline(t.split("=", 1)[1])
    return "none", ""
def target(s, env):  # the repo a gh call names: -R / --repo, else a GH_REPO= prefix; "-" when it names none
    for i, t in enumerate(s):
        if t in ("-R", "--repo") and i + 1 < len(s): return s[i + 1] or "-"
        if t.startswith("--repo="): return t.split("=", 1)[1] or "-"
        if t.startswith("-R") and not t.startswith("-R=") and len(t) > 2: return t[2:]
    for t in env:
        if t.startswith("GH_REPO="): return t.split("=", 1)[1] or "-"
    return "-"
def findings(segs, seps):
    for raw, sep in zip(segs, seps):
        s = strip_env(raw)
        if not s: continue
        exe = os.path.basename(s[0])
        if exe == "gh" and s[1:3] == ["pr", "create"]:
            k, v = body(s); yield "pr-create\t%s\t%s\t%s" % (k, target(s, raw[:len(raw) - len(s)]), v)
        elif exe == "gh" and s[1:3] == ["issue", "comment"]:
            yield "issue-comment\t%s\t-\t%s" % body(s)
        elif exe == "gh" and s[1:3] == ["pr", "edit"]:
            k, v = body(s); yield "pr-edit\t%s\t%s\t%s" % (k, target(s, raw[:len(raw) - len(s)]), v)
        elif exe == "gh" and s[1:3] in (["issue", "edit"], ["issue", "create"]):
            yield "body-write\t%s\t-\t%s" % body(s)
        elif exe == "orca" and s[1:2] == ["orchestration"] and s[2:3] == ["check"] and "--wait" in s:
            yield "check-wait\tnone\t-\t"
        elif exe == "orca" and s[1:2] == ["orchestration"] and sep == "&" and s[2:3] == ["ask"]:
            yield "trailing-amp\tnone\t-\t"
# One view: prep() (comments, heredoc bodies and line continuations gone, quotes normalised) lexed by shlex. A command it
# still cannot lex is reported as `unparsable` (the shell part warns; D2 on #36), never dropped silently.
try:
    segs, seps = clean_split(cmd)
except ValueError:
    print("unparsable\tnone\t-\t")
else:
    seen = set()
    for f in findings(segs, seps):
        if f not in seen: seen.add(f); print(f)
')
py_rc=$?

# A non-zero python exit (crash, SyntaxError) must never pass silently (#38): warn on stderr and exit 1, which Claude Code
# shows as a non-blocking error (exit 2 would let a guard bug block every guarded call; D3 on #36).
warn() { echo "guard.sh (agent-workflow) WARNING: $1" >&2; }
if [ "$py_rc" != 0 ]; then
  warn "the parse block failed (exit $py_rc); the guarded-command checks were skipped for this call. Fix guard.sh."
  exit 1
fi

[ -n "$findings" ] || exit 0

TMPS=""; trap 'rm -f $TMPS' EXIT
block() { echo "guard.sh (agent-workflow): $*" >&2; exit 2; }

body_file() { # body_file <kind> <value>: print a readable path, or nothing when the file does not exist yet
  case "$1" in
    file) [ -f "$2" ] && echo "$2" ;;
    inline) local t; t=$(mktemp); TMPS="$TMPS $t"; printf '%s' "$2" | base64 -d >"$t"; echo "$t" ;;
  esac
}

CFG=""
load_cfg() { # the settings and the project's functions, once: defaults, the global file, the repo config
  [ -z "$CFG" ] || return 0
  # shellcheck source=lib.sh
  . "$DIR/lib.sh"; wf_load; CFG=1
}
attribution_on() { load_cfg; [ "${WF_PR_ATTRIBUTION:-on}" != off ]; }
has_closes() { grep -Eqi '(closes|fixes|resolves) +(#|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#)[0-9]+' "$1" || grep -Eq '^No-issue: [^[:space:]]' "$1"; }
has_attribution() { grep -Fq 'Generated with [Claude Code]' "$1"; }
slug() { # slug <owner/repo | HOST/owner/repo | URL>: owner/repo in lower case
  local s=${1%/}
  s=${s%.git}
  case "$s" in *://*) s=${s#*://}; s=${s#*/} ;; *@*:*) s=${s#*:} ;; */*/*) s=${s#*/} ;; esac
  printf '%s' "$s" | tr '[:upper:]' '[:lower:]'
}
same_repo() { # same_repo <target>: 1 only when the PR names a repo that no GitHub remote of this checkout points to
  local t r u known=0
  case "$1" in - | "" | *'$'* | *'`'*) return 0 ;; esac # none named, or built at run time: this repo, as far as we can tell
  t=$(slug "$1")
  for r in $(git remote 2>/dev/null); do
    u=$(git remote get-url "$r" 2>/dev/null) || continue
    case "$u" in *github.com[:/]*/*) ;; *) continue ;; esac
    known=1
    [ "$(slug "$u")" != "$t" ] || return 0
  done
  [ "$known" = 0 ] # no GitHub remote to compare with: apply the check
}
project_check() { # project_check <body file> <target repo>: the session repo's wf_pr_body_check, for its own PRs only
  local msg
  same_repo "$2" || return 0
  load_cfg
  if wf_has wf_pr_body_check; then
    msg=$(wf_pr_body_check "$1" 2>&1) || block "project check (.claude/issue-workflow.sh wf_pr_body_check): $msg"
  fi
}

while IFS=$'\t' read -r kind bkind repo value; do
  case "$kind" in
    unparsable)
      # Valid bash this lexer cannot read, or a command the shell rejects too: fail open, but say so (D2 on #36).
      msg="could not parse this command (unbalanced quotes?); the guarded-command checks were skipped for this call."
      warn "$msg"; jq -nc --arg m "guard.sh: $msg" '{systemMessage: $m}'
      continue ;;
    check-wait)
      block "no 'orca orchestration check --wait' (Orca V3): end your turn instead; Orca wakes you when a worker reports, asks or stops, and then you run the plain 'check' the wake names. A waiter takes that mail and leaves Orca nothing to wake you with." ;;
    trailing-amp)
      block "no trailing '&' on 'orca orchestration ask': a detached call is lost. Run it in the foreground; it returns at once from a Dispatch." ;;
    merge-chain)
      block "'gh pr merge' must be its own call, after you have read the 'merge-pr.sh prep' output: no '&&', ';', '||', '|' or newline chain with another command (e.g. 'merge-pr.sh after'). Run the merge alone, read its result, then run 'merge-pr.sh after' as a second call." ;;
    pr-create)
      [ "$bkind" = unverifiable ] && continue
      need="'Closes #<n>'"; attribution_on && need="$need and the PR attribution line"
      [ "$bkind" = none ] && block "gh pr create needs --body-file (or --body) with $need; --fill is not enough."
      f=$(body_file "$bkind" "$value"); [ -n "$f" ] || continue
      has_closes "$f" || block "PR body lacks 'Closes #<n>' (the issue it closes) or a line-leading 'No-issue: <reason>' (ad-hoc PR)."
      if attribution_on; then
        has_attribution "$f" || block "PR body lacks the attribution line from the session's attribution instructions ('🤖 Generated with [Claude Code](...)'). A setup without that line sets WF_PR_ATTRIBUTION=off (global settings file or repo config)."
      fi
      project_check "$f" "$repo" ;;
    pr-edit)
      # A PR body written whole must still be a whole body: a fragment (one review line) once replaced a PR's body.
      case "$bkind" in unverifiable|none) continue ;; esac
      f=$(body_file "$bkind" "$value"); [ -n "$f" ] || continue
      grep -q '[^[:space:]]' "$f" || block "refusing an empty issue/PR body ($value): it would wipe the current body."
      whole=1; need="'Closes #<n>'"
      has_closes "$f" || whole=0
      if attribution_on; then need="$need or the attribution line"; has_attribution "$f" || whole=0; fi
      [ "$whole" = 1 ] || block "gh pr edit --body replaces the WHOLE body, and this one lacks $need (a fragment?). Fetch it ('gh pr view <n> --json body -q .body > file'), change the section, write the whole file back with --body-file."
      # The edited body must pass the project's body check too (a line it requires, broken by an edit, would show only at merge).
      project_check "$f" "$repo" ;;
    body-write)
      case "$bkind" in unverifiable|none) continue ;; esac
      f=$(body_file "$bkind" "$value"); [ -n "$f" ] || continue
      grep -q '[^[:space:]]' "$f" || block "refusing an empty issue/PR body ($value): it would wipe the current body. Check the file first (test -s <file>), and keep the user's original text at the top." ;;
    issue-comment)
      [ "$bkind" = unverifiable ] && continue
      f=$(body_file "$bkind" "$value"); [ -n "$f" ] || continue
      grep -Fq '<!-- decision-' "$f" || block "agent issue comments go through '~/.claude/agent-workflow/bin/decide.sh note <n> \"<text>\"' (an unmarked comment reads as the user's). With --attach, start the body file with '<!-- decision-note -->'."
      msg=$(bash "$DIR/decide.sh" check "$f" 2>&1) || block "$msg" ;;
  esac
done <<<"$findings"
exit 0
