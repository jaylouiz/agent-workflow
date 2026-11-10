#!/usr/bin/env bash
# Table test for guard.sh (PreToolUse Bash hook). Run: bash skills/orchestrate-gh-issues/test-guard.sh
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude"; git -C "$T" init -q
ATTR='🤖 Generated with [Claude Code](https://claude.com/claude-code)'
printf 'Summary\n\n%s\n' "$ATTR" >"$T/no-closes.md"
printf 'Closes #3\n\nSummary\n' >"$T/no-attr.md"
printf 'Closes #3\n\nSummary\n\n%s\n' "$ATTR" >"$T/good.md"
printf 'Closes #3\n\n%s\n' "$ATTR" >"$T/no-e2e.md"
printf 'Closes #3\nE2E-specs: smoke\n\n%s\n' "$ATTR" >"$T/with-e2e.md"
printf 'PR: https://x\n' >"$T/plain.md"
printf '<!-- decision-note -->\nPR: https://x\n' >"$T/marked.md"
{ echo '<!-- decision-note round R1 -->'; python3 -c 'print("word " * 400)'; } >"$T/marked-long.md"

fail=0; n=0
expect() { # expect <exit> <label> <command> [cwd]
  local want=$1 label=$2 cmd=$3 cwd=${4:-$T} got out
  out=$(jq -n --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | (cd "$cwd" && bash "$DIR/guard.sh") 2>&1)
  got=$?; n=$((n + 1))
  if [ "$got" != "$want" ]; then fail=$((fail + 1)); echo "FAIL [$label] want $want got $got: $out"; fi
}

# gh pr create
expect 2 "pr create inline body without Closes" "gh pr create --title x --body \"no closes $ATTR\""
expect 2 "pr create body-file without Closes" "gh pr create --title x --body-file $T/no-closes.md"
expect 2 "pr create body-file without attribution" "gh pr create --title x --body-file $T/no-attr.md"
expect 0 "pr create good body-file" "gh pr create --title x --body-file $T/good.md"
expect 0 "pr create relative body-file" "gh pr create --title x --body-file good.md"
expect 0 "pr create body-file missing at hook time" "gh pr create --title x --body-file $T/later.md"
expect 2 "pr create without any body" "gh pr create --title x --fill"
expect 0 "pr create after cd &&" "cd $T && gh pr create --title x --body-file good.md --attach a.png#alt"
# project check wf_pr_body_check
printf 'wf_pr_body_check() { grep -q "^E2E-specs:" "$1" || { echo "missing E2E-specs: line"; return 1; }; }\n' >"$T/.claude/issue-workflow.sh"
expect 2 "project check fails" "gh pr create --title x --body-file $T/no-e2e.md"
expect 0 "project check passes" "gh pr create --title x --body-file $T/with-e2e.md"
rm "$T/.claude/issue-workflow.sh"

# gh issue comment
expect 2 "issue comment inline body" "gh issue comment 5 --body \"hi\""
expect 2 "issue comment unmarked file" "gh issue comment 5 --body-file $T/plain.md"
expect 0 "issue comment marked file" "gh issue comment 5 --body-file $T/marked.md --attach $T/a.png"
expect 2 "issue comment over the visible cap" "gh issue comment 5 --body-file $T/marked-long.md"
expect 0 "issue comment marked inline" "gh issue comment 5 --body '<!-- decision-note -->
ok'"
expect 0 "issue comment file missing at hook time" "gh issue comment 5 --body-file /nonexistent/x.md"
: >"$T/empty.md"; printf '\n  \n' >"$T/blank.md"
expect 2 "issue edit empty body-file" "gh issue edit 5 --body-file $T/empty.md"
expect 2 "issue edit whitespace body-file" "gh issue edit 5 --body-file $T/blank.md"
expect 2 "pr edit empty inline body" "gh pr edit 5 --body ''"
expect 0 "issue edit good body-file" "gh issue edit 5 --body-file $T/plain.md"
expect 0 "issue edit labels only" "gh issue edit 5 --add-label ready"
expect 0 "issue edit body-file missing at hook time" "gh issue edit 5 --body-file /nonexistent/x.md"
expect 0 "issue create inbox" "gh issue create --label inbox --title t --body x"
expect 0 "pr comment not covered" "gh pr comment 5 --body x"
expect 0 "decide.sh note" "~/.claude/skills/orchestrate-gh-issues/decide.sh note 5 \"PR: x\""

# trailing & on orca waits
expect 2 "ask with trailing &" "orca orchestration ask --to x --body y &"
expect 2 "check --wait with trailing &" "orca orchestration check --wait --timeout-ms 5 &"
expect 2 "check --wait with trailing & and redirect" "orca orchestration check --wait --json > /tmp/o 2>&1 &"
expect 2 "check --wait foreground (V3)" "orca orchestration check --wait --timeout-ms 5"
expect 2 "check --wait chained (V3)" "orca orchestration check --wait && echo done"
expect 0 "check without wait backgrounded" "orca orchestration check --json &"

# review I1: real-world forms
HEREDOC_CMD="gh pr create --title x --body \"\$(cat <<'EOF'
Closes #3
The \"Jetzt starten\" button
$ATTR
EOF
)\""
expect 0 "heredoc body with inner quotes" "$HEREDOC_CMD"
expect 0 "body from command substitution" 'gh pr create --title x --body "$(cat body.md)"'
expect 0 "body from variable" 'gh pr create --title x --body "$BODY"'
expect 2 "check --wait with 2>&1 (V3)" "orca orchestration check --wait --timeout-ms 5 2>&1"
expect 0 "ask with 2>&1 piped" "orca orchestration ask --to x --body y 2>&1 | tail -3"
expect 2 "check --wait with &> file (V3)" "orca orchestration check --wait &> /tmp/o"
expect 0 "plain check piped to msgs.sh" "orca orchestration check --json | msgs.sh"
expect 0 "ask foreground" "orca orchestration ask --question q"
expect 2 "check --wait 2>&1 then trailing &" "orca orchestration check --wait 2>&1 &"

# gh pr merge is its own call (guard check 5)
MC="bash ~/.claude/skills/orchestrate-gh-issues/merge-pr.sh"
expect 2 "merge && after" "gh pr merge 5 --squash && $MC after 5 \"x\""
expect 2 "merge ; after" "gh pr merge 5 --squash; $MC after 5 x"
expect 2 "merge || after" "gh pr merge 5 --squash || $MC after 5 x"
expect 2 "merge | tail" "gh pr merge 5 --squash 2>&1 | tail -3"
expect 2 "merge newline after" "gh pr merge 5 --squash
$MC after 5 x"
expect 2 "merge & after" "gh pr merge 5 --squash & $MC after 5 x"
expect 2 "merge && echo" "gh pr merge 5 && echo done"
expect 2 "cd && merge && after" "cd $T && gh pr merge 5 --squash --delete-branch && $MC after 5 x"
expect 2 "env prefix merge && after" "GH_TOKEN=x gh pr merge 5 && $MC after 5 x"
expect 2 "merge in subshell chained" "($MC prep 5; gh pr merge 5 && $MC after 5 x)"
expect 2 "merge in if/then" "if gh pr merge 5; then $MC after 5 x; fi"
expect 2 "merge inside bash -c" "bash -c 'gh pr merge 5 && $MC after 5 x'"
expect 2 "merge, comment line, then after" "gh pr merge 5
# done
$MC after 5 x"
expect 2 "merge after a heredoc with an apostrophe" "cat <<EOF >/dev/null
it's a note
EOF
gh pr merge 5 && $MC after 5 x"
expect 2 "merge inside bash -lc chained" "bash -lc 'gh pr merge 5 && $MC after 5 x'"
expect 2 "merge in bash -c, chain outside" "bash -c \"gh pr merge 5\"; $MC after 5 x"
expect 0 "bash -c without merge, chained" "bash -c 'echo hi' && $MC after 5 x"
expect 2 "gh -R repo merge chained" "gh -R a/b pr merge 5 && $MC after 5 x"
expect 2 "gh --repo repo merge chained" "gh --repo a/b pr merge 5; $MC after 5 x"
expect 0 "gh -R repo lone merge" "gh -R a/b pr merge 5 --squash"
expect 0 "comment after lone merge with separators" "gh pr merge 5 --squash # done; ok && more | x"
expect 0 "comment line after lone merge" "gh pr merge 5 --squash
# then: $MC after 5 x"
expect 2 "quoted # is not a comment" "gh pr merge 5 --body '#12' && $MC after 5 x"
expect 2 "# inside a word is not a comment" "gh pr merge 5 --attach a.png#alt && $MC after 5 x"
expect 0 "lone merge" "gh pr merge 5 --squash --delete-branch"
expect 0 "lone merge with trailing semicolon" "gh pr merge 5 --squash;"
expect 0 "lone merge with trailing newline" "gh pr merge 5 --squash
"
expect 0 "lone merge with redirects" "gh pr merge 5 --squash > /tmp/o 2>&1"
expect 0 "lone merge with trailing comment" "gh pr merge 5 --squash # then after"
expect 0 "merge-pr.sh after alone" "$MC after 5 \"summary\""
expect 0 "prep alone" "$MC prep 5"
expect 0 "cd then merge" "cd $T && gh pr merge 5 --squash"
expect 0 "prep piped before merge" "$MC prep 5 | head -3 && gh pr merge 5 --squash"
expect 0 "merge in a subshell alone" "(gh pr merge 5 --squash)"
expect 0 "merge in if with fi" "if true; then gh pr merge 5; fi"
expect 0 "merge inside bash -c alone" "bash -c 'gh pr merge 5'"
expect 0 "commit message mentions merge chain" "git commit -m \"run gh pr merge 5 && merge-pr.sh after\""
expect 0 "echo mentions merge chain" "echo \"gh pr merge 5 && $MC after 5\""
expect 0 "quoted mention across lines" "echo 'first
gh pr merge 5
second'"
expect 0 "grep mentions merge" "grep -n 'gh pr merge' SKILL.md && echo ok"
expect 0 "heredoc body mentions merge" "cat <<'EOF'
Run gh pr merge 5 --squash
then $MC after 5 x
EOF"
expect 0 "indented heredoc (<<-) mentions merge" "cat <<-EOF
	gh pr merge 5
	next line
	EOF
echo done"
expect 0 "commit via heredoc mentions merge" "git commit -F - <<'EOF'
fix: block gh pr merge chains
EOF"
expect 0 "not merge: gh pr view" "gh pr view 5 && gh pr checks 5"
expect 0 "line continuation in lone merge" "gh pr merge 5 \\
  --squash"

# unbalanced quotes outside real quoting (#29): every check still runs after an apostrophe in a comment or heredoc
expect 2 "apostrophe comment, then pr create (the issue example)" "# don't
gh pr create --title x --body y"
expect 2 "apostrophe comment, then pr create without body" "# don't forget
gh pr create --title x --fill"
expect 0 "apostrophe comment, then pr create good body-file" "# don't forget
gh pr create --title x --body-file good.md"
expect 2 "apostrophe comment, pr create body-file without Closes" "# it's late
gh pr create --title x --body-file $T/no-closes.md"
expect 2 "apostrophe trailing comment, then pr create" "echo hi # it's late
gh pr create --title x --body-file $T/no-attr.md"
expect 2 "apostrophe in bare heredoc body, then pr create" "cat > $T/b.md <<EOF
it's a note
EOF
gh pr create --title x --fill"
expect 2 "apostrophe in quoted heredoc body, then pr create" "cat > $T/b.md <<'EOF'
it's a note
EOF
gh pr create --title x --body-file $T/no-closes.md"
expect 0 "apostrophe in heredoc body, then good pr create" "cat > $T/b.md <<EOF
it's a note
EOF
gh pr create --title x --body-file good.md"
expect 0 "apostrophe comment, then pr create with heredoc body" "# it's late
gh pr create --title x --body \"\$(cat <<'EOF'
Closes #3
$ATTR
EOF
)\""
expect 2 "apostrophe comment, then unmarked issue comment" "# don't
gh issue comment 5 --body-file $T/plain.md"
expect 0 "apostrophe comment, then marked issue comment" "# don't
gh issue comment 5 --body-file $T/marked.md"
expect 2 "apostrophe heredoc, then unmarked issue comment" "cat <<EOF >/dev/null
don't
EOF
gh issue comment 5 --body-file $T/plain.md"
expect 2 "apostrophe comment, then empty issue edit body" "# don't
gh issue edit 5 --body-file $T/empty.md"
expect 2 "apostrophe comment, then check --wait" "# don't
orca orchestration check --wait --timeout-ms 5"
expect 2 "apostrophe comment, then ask with trailing &" "# don't
orca orchestration ask --to x --body y &"
expect 2 "apostrophe comment, then merge chain" "# don't
gh pr merge 5 && $MC after 5 x"
expect 0 "apostrophe comment, then lone merge" "# don't
gh pr merge 5 --squash"
expect 2 "comment mentioning a heredoc does not hide the next command" "# write it via <<EOF later
gh pr create --title x --fill"
expect 2 "two apostrophe comments around a command" "# don't
gh pr create --title x --fill
# won't matter"
expect 2 "command on a later line (newline separates)" "echo hi
gh pr create --title x --fill"
expect 2 "command after cd on its own line" "cd $T
gh issue comment 5 --body-file plain.md"
expect 0 "pr create in a loop body, good body" "for i in 1; do
  gh pr create --title x --body-file good.md
done"
expect 0 "commented-out pr create" "# gh pr create --title x --fill
echo ok"
expect 0 "apostrophe commit message mentions pr create" "git commit -m \"docs: don't run gh pr create\""
expect 0 "heredoc commit message mentions pr create" "git commit -F - <<'EOF'
fix: guard doesn't skip gh pr create
EOF"
expect 0 "multi-line quoted title" "gh pr create --title \"a
b\" --body-file good.md"
expect 0 "backslash continuation after an apostrophe comment" "# don't
gh pr create --title x \\
  --body-file good.md"
expect 2 "comment ending in a backslash does not join the next line" "# don't \\
gh pr create --title x --fill"
expect 2 "arithmetic << does not hide the next command" "echo \$((1<<n))
gh pr create --title x --fill"
expect 2 "continuation inside double quotes in a body-file path" "gh pr create --title x --body-file \"$T/no-closes\\
.md\""
expect 0 "escaped space before # is not a comment" "gh pr create --title x --body Closes\\ #3\\ \"$ATTR\""
expect 2 "trailing & followed by a newline and more commands, apostrophe comment" "# don't
orca orchestration ask --to x --body y &
echo next"
expect 2 "trailing & followed by blank lines, apostrophe heredoc" "cat <<EOF >/dev/null
it's a note
EOF
orca orchestration ask --to x --body y &

echo next"
expect 0 "&& at a line end is not a trailing &, apostrophe comment" "# don't
orca orchestration ask --to x --body y &&
echo next"
expect 2 "line starting with # inside a quote does not hide a heredoc opener" "git commit -m \"x
# y\" && cat <<'EOF'
it's a note
EOF
gh pr merge 1 && echo x"
expect 0 "line starting with # inside a quote, lone merge after the heredoc" "git commit -m \"x
# y\" && cat <<'EOF'
it's a note
EOF
gh pr merge 1"
# still unbalanced after stripping: deliberately allowed (the shell rejects it too; a block would hit ordinary commands)
expect 0 "unbalanced double quote after stripping" "echo \"oops
gh pr create --title x --fill"

# #36: a quoted or arithmetic << opens no heredoc, so the commands after it are still checked
expect 2 "quoted << does not open a heredoc (pr create)" "git log -m \"use <<EOF here\"
gh pr create --title x --fill"
expect 2 "quoted << does not open a heredoc (merge chain)" "git log -m \"use <<EOF here\"
gh pr merge 5 && $MC after 5 x"
expect 2 "single-quoted << does not open a heredoc" "echo 'a <<EOF b'
gh pr create --title x --fill"
expect 2 "arithmetic << in \$(( )) does not hide the next command" "echo \$((1<<n))
gh pr create --title x --fill"
expect 2 "arithmetic << inside double quotes" "echo \"\$((1<<n))\"
gh pr create --title x --fill"
expect 2 "arithmetic << in a (( )) command" "((i = 1<<n))
gh pr create --title x --fill"
expect 2 "arithmetic << then merge chain" "x=\$((1<<n))
gh pr merge 5 && $MC after 5 x"
expect 2 "here-string <<< opens no heredoc" "cat <<< \"it's\"
gh pr create --title x --fill"
expect 2 "escaped-delimiter heredoc (<<\\EOF) is skipped, the next command is checked" "cat <<\\EOF >/dev/null
it's a note
EOF
gh pr create --title x --fill"
expect 2 "two heredocs on one line, then a command" "cat <<A <<'B' >/dev/null
it's
A
don't
B
gh pr create --title x --fill"
expect 0 "heredoc body hides a separator plus guarded command" "cat <<-EOF >/dev/null
	x; gh pr create --title x --fill
	EOF
echo done"

# #37: text quoted in a comment or heredoc body is never read as a real command
expect 0 "guarded command quoted in a trailing comment after a separator" "echo hi # then; gh pr create --fill"
expect 0 "guarded command quoted after a separator in a quoted heredoc body" "cat > $T/a.md <<'EOF'
run: x; gh pr create --fill
EOF"
expect 0 "guarded command quoted after a separator in a bare heredoc body" "cat > $T/a.md <<EOF
it's: x && gh pr create --fill
EOF"
expect 0 "comment line quoting a chain" "# try: a; orca orchestration check --wait
echo ok"
expect 0 "continued flag line without indent" "gh pr create --title x \\
--body-file good.md"
expect 0 "continued flag line without indent (ask)" "orca orchestration ask --to x \\
--body y"
expect 2 "real command after a comment with a separator" "echo hi # then; gh pr create --fill
gh pr create --title x --fill"
expect 2 "real command after a heredoc quoting one" "cat > $T/a.md <<'EOF'
run: x; gh pr create --fill
EOF
gh pr create --title x --fill"

# #38: ANSI-C strings and nested quotes in a quoted substitution are lexed, so the next command is checked
expect 2 "ANSI-C string with an escaped quote, then pr create" "echo \$'it\\'s'
gh pr create --title x --fill"
expect 0 "ANSI-C string as an argument, good body" "gh pr create --title \$'a b' --body-file good.md"
expect 2 "ANSI-C string as an argument, no body" "gh pr create --title \$'it\\'s' --fill"
expect 2 "nested quotes in a quoted substitution, then pr create" "msg=\"\$(echo \"it's done\")\"
gh pr create --title x --fill"
expect 2 "nested quotes in a quoted substitution, then merge chain" "x=\"\$(echo \"it's\")\"
gh pr merge 5 && $MC after 5 x"
# review of PR 43: an ANSI-C body is built at run time (escapes not decoded here), so it stays unverifiable like "$VAR"
expect 0 "ANSI-C issue comment body, escaped newlines (run-time built)" "gh issue comment 5 --body \$'<!-- decision-note -->\\nheadline\\n\\n$(python3 -c 'print("word " * 100)')'"
expect 0 "ANSI-C issue comment body without the marker (run-time built)" "gh issue comment 5 --body \$'plain'"
expect 2 "ANSI-C title, then an unmarked plain comment still blocked" "gh issue comment 5 --title \$'a b' --body 'plain'"
expect 0 "nested quotes in a quoted substitution, good pr create" "gh pr create --title \"\$(echo \"it's done\")\" --body-file good.md"
expect 0 "backticks in double quotes" "gh pr create --title \"\`echo it's\`\" --body-file good.md"

# #39: a trailing & followed by a newline and a bare paren is still a trailing &
expect 2 "ask & newline bare paren, apostrophe comment" "# don't
(
  orca orchestration ask --to x --body y &
)"
expect 2 "ask & newline bare paren" "(
  orca orchestration ask --to x --body y &
)"
expect 2 "ask & newline bare open paren" "orca orchestration ask --to x --body y &
(echo hi)"
expect 0 "&& newline bare paren is no trailing &" "# don't
(
  orca orchestration ask --to x --body y &&
  echo next
)"

# unparsable input: fail open, but say so (stderr + systemMessage); a crash of the parse block exits 1 with a warning
printf 'echo "oops\ngh pr create --title x --fill' >"$T/unbalanced.txt"
out=$(jq -n --rawfile c "$T/unbalanced.txt" --arg d "$T" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | bash "$DIR/guard.sh" 2>"$T/err.txt"); rc=$?; n=$((n + 1))
{ [ $rc = 0 ] && grep -q systemMessage <<<"$out" && grep -q WARNING "$T/err.txt"; } || { fail=$((fail + 1)); echo "FAIL [unparsable warns] rc=$rc out=$out err=$(cat "$T/err.txt")"; }
printf '#!/bin/sh\necho Traceback >&2\nexit 1\n' >"$T/crash.sh"
out=$(jq -n --arg d "$T" '{tool_name:"Bash",tool_input:{command:"gh pr create --title x --fill"},cwd:$d}' | GUARD_PYTHON="$T/crash.sh" bash "$DIR/guard.sh" 2>&1); rc=$?; n=$((n + 1))
{ [ $rc = 1 ] && grep -q WARNING <<<"$out"; } || { fail=$((fail + 1)); echo "FAIL [parse-block crash warns] rc=$rc out=$out"; }
out=$(jq -n --arg d "$T" '{tool_name:"Bash",tool_input:{command:"gh pr create --title x --fill"},cwd:$d}' | GUARD_PYTHON="$T/nonexistent" bash "$DIR/guard.sh" 2>&1); rc=$?; n=$((n + 1))
{ [ $rc = 1 ] && grep -q WARNING <<<"$out"; } || { fail=$((fail + 1)); echo "FAIL [missing python warns] rc=$rc out=$out"; }

# #3: heredoc delimiters are any shell word, and an empty token before & does not hide the separator
for d in PR-BODY EOF.md 1 a.b-c A1 'x,y'; do
  expect 2 "heredoc <<$d: the end line matches, the next command is checked" "cat <<$d >/dev/null
it's a note
$d
gh pr create --title x --fill"
  expect 0 "heredoc <<$d: a body line with a guarded command is not a command" "cat <<$d >/dev/null
x; gh pr create --fill
$d
echo done"
  expect 2 "heredoc <<-$d (tab-indented end line), then a command" "cat <<-$d >/dev/null
	it's
	$d
gh pr create --title x --fill"
  expect 2 "heredoc <<\\$d (escaped), then a command" "cat <<\\$d >/dev/null
it's
$d
gh pr create --title x --fill"
done
expect 2 "heredoc delimiter stops at a redirect (<<EOF>out)" "cat <<EOF>$T/o.txt
it's
EOF
gh pr create --title x --fill"
expect 2 "heredoc delimiter stops at ; (<<EOF;)" "cat <<EOF; echo hi
it's
EOF
gh pr create --title x --fill"
expect 2 "heredoc delimiter stops at ) (<<EOF)" "(cat <<EOF)
it's
EOF
gh pr create --title x --fill"
expect 2 "<<1 in arithmetic still opens no heredoc" "echo \$((1<<3))
gh pr create --title x --fill"
expect 2 "ask with an empty --body before the trailing &" "orca orchestration ask --to x --body \"\" &"
expect 2 "ask with an empty single-quoted token before the trailing &" "orca orchestration ask --to x --body '' &"
expect 2 "ask with an empty token first, trailing &" "orca orchestration ask '' &"
expect 2 "ask, &> redirect, trailing &" "orca orchestration ask --to x --body y &>/dev/null &"
expect 2 "ask, 2>&1, empty token, trailing &" "orca orchestration ask --to x --body \"\" 2>&1 &"
expect 2 "merge with an empty token, then & echo is a merge chain" "gh pr merge 1 \"\" & echo hi"
expect 0 "lone merge with an empty token" "gh pr merge 1 \"\""

# mentions only
expect 0 "commit message mentions pr create" "git commit -m \"gh pr create later\""
expect 0 "echo mentions ask &" "echo \"orca orchestration ask &\""
expect 0 "grep mentions issue comment" "grep -n 'gh issue comment' file.md"

# malformed input
out=$(printf '' | bash "$DIR/guard.sh" 2>&1); rc=$?; n=$((n + 1)); [ $rc = 0 ] || { fail=$((fail + 1)); echo "FAIL [empty input] got $rc: $out"; }
out=$(echo '{"tool_name":"Edit","tool_input":{}}' | bash "$DIR/guard.sh" 2>&1); rc=$?; n=$((n + 1)); [ $rc = 0 ] || { fail=$((fail + 1)); echo "FAIL [non-bash] got $rc: $out"; }

echo "guard: $((n - fail))/$n passed"
[ $fail = 0 ]
