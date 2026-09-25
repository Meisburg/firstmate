#!/usr/bin/env bash
# Behavior tests for bin/fm-lesson.sh, the supervisor-side intake for
# worker-reported durable lessons.
#
# Coverage:
#   - pending lists only lessons whose reviewed marker is absent, and prints
#     nothing when none are pending
#   - show prints the raw worker block
#   - reviewed records the curated outcome and removes the lesson from pending
#   - reviewed refuses ambiguous, missing, repeated, and invalid requests
#   - the review marker is a single line even for a multi-line note
#   - the intake never writes or creates a memory file
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LESSON="$ROOT/bin/fm-lesson.sh"
TMP_ROOT=$(fm_test_tmproot fm-lesson)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

write_lesson() {  # <home> <id> [<body>]
  local home=$1 id=$2 body=${3:-'lesson: pin the daemon PATH
scope: tooling
evidence: no-mistakes daemon status failed without it'}
  mkdir -p "$home/data/$id"
  printf '%s\n' "$body" > "$home/data/$id/lesson.md"
}

test_pending_lists_only_unreviewed_lessons() {
  local home out
  home=$(make_home pending)
  write_lesson "$home" task-a
  write_lesson "$home" task-b
  write_lesson "$home" task-c
  printf 'action=filed at=1 note=filed\n' > "$home/data/task-b/lesson.reviewed"

  out=$(FM_HOME="$home" "$LESSON" pending)
  assert_contains "$out" "task-a" "pending did not list an unreviewed lesson"
  assert_contains "$out" "task-c" "pending did not list an unreviewed lesson"
  assert_not_contains "$out" "task-b" "pending listed a reviewed lesson"

  FM_HOME="$home" "$LESSON" reviewed task-c --skipped >/dev/null \
    || fail "reviewed --skipped failed"
  out=$(FM_HOME="$home" "$LESSON" pending)
  assert_not_contains "$out" "task-c" "pending still listed a skipped lesson"

  pass "pending lists every unreviewed lesson and no reviewed one"
}

test_pending_is_silent_when_none_wait() {
  local home out rc
  home=$(make_home pending-empty)
  mkdir -p "$home/data/task-empty"
  out=$(FM_HOME="$home" "$LESSON" pending)
  rc=$?
  [ -z "$out" ] || fail "pending printed output with no lesson files: $out"
  [ "$rc" -eq 0 ] || fail "pending should exit zero on an empty result"
  pass "pending is a silent zero-exit empty result"
}

test_show_prints_the_raw_block() {
  local home out
  home=$(make_home show)
  write_lesson "$home" task-show 'lesson: always run shellcheck
scope: tooling
evidence: bin/fm-lint.sh caught it'
  out=$(FM_HOME="$home" "$LESSON" show task-show)
  assert_contains "$out" "lesson: always run shellcheck" "show did not print the lesson line"
  assert_contains "$out" "evidence: bin/fm-lint.sh caught it" "show did not print the evidence line"
  pass "show prints the raw worker lesson block"
}

test_reviewed_writes_a_single_line_marker() {
  local home marker
  home=$(make_home reviewed)
  write_lesson "$home" task-filed
  FM_HOME="$home" "$LESSON" reviewed task-filed --filed --note $'kept\nin learnings' >/dev/null \
    || fail "reviewed --filed failed"
  marker="$home/data/task-filed/lesson.reviewed"
  assert_present "$marker" "reviewed did not write the marker"
  [ "$(wc -l < "$marker")" -eq 1 ] || fail "marker is not a single line: $(cat "$marker")"
  assert_grep 'action=filed ' "$marker" "marker is missing the filed action"
  assert_grep ' at=' "$marker" "marker is missing the epoch"
  pass "reviewed writes a single-line filed marker"
}

test_reviewed_refuses_ambiguous_or_invalid_requests() {
  local home out rc
  home=$(make_home refusals)
  write_lesson "$home" task-refuse

  out=$(FM_HOME="$home" "$LESSON" reviewed task-refuse 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "reviewed accepted a missing action"
  assert_contains "$out" "fm-lesson.sh reviewed" "missing-action refusal did not print usage"

  out=$(FM_HOME="$home" "$LESSON" reviewed task-refuse --filed --skipped 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "reviewed accepted two actions"
  assert_contains "$out" "exactly one of --filed or --skipped" "two-action refusal did not explain"

  out=$(FM_HOME="$home" "$LESSON" show missing-task 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "show accepted a task with no lesson"

  out=$(FM_HOME="$home" "$LESSON" show '../escape' 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "show accepted a path-escaping task id"

  FM_HOME="$home" "$LESSON" reviewed task-refuse --filed >/dev/null || fail "first review failed"
  out=$(FM_HOME="$home" "$LESSON" reviewed task-refuse --filed 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "reviewed accepted a repeated review"
  assert_contains "$out" "already reviewed" "repeated-review refusal did not explain"

  pass "reviewed refuses ambiguous, missing, repeated, and invalid requests"
}

test_intake_never_touches_memory() {
  local home
  home=$(make_home no-memory-write)
  write_lesson "$home" task-memory
  FM_HOME="$home" "$LESSON" reviewed task-memory --filed --note kept >/dev/null \
    || fail "reviewed --filed failed"
  assert_absent "$home/data/learnings.md" "intake created a memory file"
  pass "the intake never writes or creates a memory file"
}

test_pending_lists_only_unreviewed_lessons
test_pending_is_silent_when_none_wait
test_show_prints_the_raw_block
test_reviewed_writes_a_single_line_marker
test_reviewed_refuses_ambiguous_or_invalid_requests
test_intake_never_touches_memory

echo "# fm-lesson.test.sh: all assertions passed"
