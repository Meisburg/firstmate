#!/usr/bin/env bash
# Supervisor-side intake for worker-reported durable lessons.
#
# A ship or scout worker writes data/<id>/lesson.md in the machine-readable
# block bin/fm-brief.sh's scaffold owns. This script is the supervisor-side
# intake: it lists lessons still waiting for a review, shows one, and records
# the reviewed outcome once firstmate has filed a curated version into home
# memory (data/learnings.md through the stow path) or deliberately skipped it.
#
# It NEVER copies a worker's lesson text into a memory file. Filing stays
# curated by firstmate, because whatever reaches memory is repeated in every
# later brief, and blind promotion is how memory gets poisoned.
#
# Usage:
#   fm-lesson.sh pending
#   fm-lesson.sh show <task-id>
#   fm-lesson.sh reviewed <task-id> {--filed|--skipped} [--note <text>]
#   fm-lesson.sh help
#
# pending prints one task id per line for every data/<id>/lesson.md whose
# data/<id>/lesson.reviewed marker does not exist, and prints nothing when none
# are pending, so a caller can test its output for emptiness. show prints the
# raw block for firstmate to read. reviewed refuses unless exactly one of
# --filed or --skipped is given, refuses a task whose lesson was already
# reviewed, writes data/<id>/lesson.reviewed, and leaves the worker's original
# lesson.md in place as evidence. The marker's one-line format is owned here:
#   action=<filed|skipped> at=<epoch> note=<text>
# Nothing here interprets or tiers the lesson; the stow skill owns memory tiers
# and is what turns a reviewed --filed lesson into a data/learnings.md entry.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() { printf 'fm-lesson: %s\n' "$1" >&2; exit "${2:-1}"; }

lesson_path() {  # <task-id> -> path on stdout, nonzero when invalid
  fm_pr_task_id_valid "$1" || return 1
  printf '%s/%s/lesson.md\n' "$DATA" "$1"
}

review_path() {  # <task-id> -> reviewed marker path on stdout
  printf '%s/%s/lesson.reviewed\n' "$DATA" "$1"
}

cmd=${1:-pending}
case "$cmd" in
  pending)
    [ "$#" -le 1 ] || die "pending takes no arguments" 2
    for lesson in "$DATA"/*/lesson.md; do
      [ -f "$lesson" ] && [ ! -L "$lesson" ] || continue
      id=$(basename "$(dirname "$lesson")")
      fm_pr_task_id_valid "$id" || continue
      [ -f "$(review_path "$id")" ] && continue
      printf '%s\n' "$id"
    done
    # A pending lesson list is a normal empty result, not an error.
    ;;
  show)
    [ "$#" -eq 2 ] || die "usage: fm-lesson.sh show <task-id>" 2
    lesson=$(lesson_path "$2") || die "invalid task id: $2" 2
    [ -f "$lesson" ] && [ ! -L "$lesson" ] || die "no lesson recorded for $2" 1
    cat "$lesson"
    ;;
  reviewed)
    shift
    [ "$#" -ge 2 ] || die "usage: fm-lesson.sh reviewed <task-id> {--filed|--skipped} [--note <text>]" 2
    id=$1
    shift
    lesson=$(lesson_path "$id") || die "invalid task id: $id" 2
    action=
    note=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --filed) [ -z "$action" ] || die "give exactly one of --filed or --skipped" 2; action=filed ;;
        --skipped) [ -z "$action" ] || die "give exactly one of --filed or --skipped" 2; action=skipped ;;
        --note)
          [ "$#" -ge 2 ] || die "--note requires a value" 2
          note=$2
          shift
          ;;
        *) die "unknown argument: $1" 2 ;;
      esac
      shift
    done
    [ -n "$action" ] || die "give exactly one of --filed or --skipped" 2
    [ -f "$lesson" ] && [ ! -L "$lesson" ] || die "no lesson recorded for $id" 1
    marker=$(review_path "$id")
    [ ! -e "$marker" ] || die "$id lesson was already reviewed ($marker)" 1
    # Keep the record one line even when firstmate passes a multi-line note.
    note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | sed 's/   */ /g; s/^ //; s/ $//')
    [ "$#" -eq 0 ] || die "unexpected trailing arguments" 2
    tmp=$(mktemp "$(dirname "$marker")/.lesson.reviewed.XXXXXX") || die "cannot write review marker" 1
    if ! printf 'action=%s at=%s note=%s\n' "$action" "$(date +%s)" "$note" > "$tmp"; then
      rm -f -- "$tmp"
      die "cannot write review marker" 1
    fi
    mv -- "$tmp" "$marker" || { rm -f -- "$tmp"; die "cannot write review marker" 1; }
    printf 'reviewed: %s lesson (%s)\n' "$action" "$id"
    ;;
  help)
    usage
    ;;
  *)
    die "unknown command: $cmd (pending|show|reviewed|help)" 2
    ;;
esac
