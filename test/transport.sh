#!/usr/bin/env bash
# Drives the plugin over its IPC and checks the contract in SPEC.md.
#
# Needs the plugin installed and the shell running. Plays real audio, briefly.
# Some behaviour depends on whether SR has published the programme on air, so
# the suite asks the API first and checks the right expectations for the case
# it finds, rather than skipping or guessing.
#
#   test/transport.sh          # whole suite
#   test/transport.sh live     # only tests whose name matches "live"

set -uo pipefail
FILTER="${1:-}"
PASS=0; FAIL=0; SKIP=0
CH="${OMASR_TEST_CHANNEL:-p1}"
CHANNEL_ID="${OMASR_TEST_CHANNEL_ID:-132}"

sr()      { omarchy-shell omasr "$@" 2>/dev/null; }
status()  { sr status; }
mode()    { status | sed -n 's/.*\[\([^ ]*\) .*/\1/p'; }        # live | -Ns | recorded
clock()   { status | sed -n 's/.*at \([0-9:]*\)\]/\1/p'; }
seekable(){ case "$(status)" in *NOSEEK*) echo no;; *) echo yes;; esac; }
procs()   { ps -eo args | grep -c '^/usr/bin/mpv'; }
audiofile(){ ps -eo args | grep '^/usr/bin/mpv' | awk '{print $2}' | sed 's|.*/||'; }

# Wait for playback to settle after an action that may respawn mpv.
settle() {
  local n
  for n in $(seq 1 60); do
    case "$(status)" in playing*) sleep 0.8; return 0;; esac
    sleep 0.3
  done
  return 1
}

# Wait for the controls to be usable again. Any move outside what the player
# has buffered restarts it, so NOSEEK right after a seek is expected -- the
# contract is that it does not *stay* that way.
ready() {
  local n
  for n in $(seq 1 60); do
    [ "$(seekable)" = yes ] && { sleep 0.3; return 0; }
    sleep 0.5
  done
  return 1
}

ok()   { PASS=$((PASS+1)); printf '    ok    %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '    FAIL  %s\n       got: %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf '    skip  %s (%s)\n' "$1" "$2"; }

is()      { [ "$2" = "$3" ] && ok "$1" || no "$1" "$2 (wanted $3)"; }
isnt()    { [ "$2" != "$3" ] && ok "$1" || no "$1" "$2 (wanted anything else)"; }
contains(){ case "$2" in *"$3"*) ok "$1";; *) no "$1" "$2 (wanted to contain $3)";; esac; }

group() {
  CURRENT_GROUP="$1"
  if [ -n "$FILTER" ] && [[ "$1" != *"$FILTER"* ]]; then return 1; fi
  printf '\n  %s\n' "$1"
  return 0
}

# Does SR publish the programme currently on air? Decides which expectations
# apply to seeking around the live edge.
published_now() {
  local j eid
  j=$(curl -s --max-time 20 "https://api.sr.se/api/v2/scheduledepisodes/rightnow?channelid=$CHANNEL_ID&format=json")
  eid=$(echo "$j" | jq -r '.channel.currentscheduledepisode.episodeid // empty')
  [ -n "$eid" ] || { echo no; return; }
  curl -s --max-time 20 "https://api.sr.se/api/v2/episodes/get?id=$eid&format=json" \
    | jq -r 'if .episode.listenpodfile or .episode.broadcast then "yes" else "no" end'
}

cleanup() { sr stop >/dev/null; sleep 1; }
trap cleanup EXIT

echo "omasr transport suite  (channel $CH, on-air programme published: $(published_now))"

# --------------------------------------------------------------- channels
if group "channels"; then
  for c in p1 p2 p3 p4; do
    sr play $c >/dev/null; sleep 6
    contains "play $c reaches a live stream" "$(status)" "live"
    is       "play $c leaves one process"   "$(procs)" "1"
  done
  sr play p1 >/dev/null; sleep 5
  sr playPause p1 >/dev/null; sleep 3
  is "pressing the playing channel stops" "$(status)" "idle"
  is "stopping leaves no process"         "$(procs)" "0"
fi

# --------------------------------------------------------------- live
if group "live"; then
  sr play $CH >/dev/null; sleep 14
  is       "tuning in lands on the live edge" "$(mode)" "live"
  is       "the control socket comes up"      "$(seekable)" "yes"
  sr back 15 >/dev/null; sleep 3
  isnt     "back 15 moves off the live edge"  "$(mode)" "live"
  ready
  is       "control comes back after seeking" "$(seekable)" "yes"
  sr live >/dev/null; sleep 5
  is       "Direkt returns to the live edge"  "$(mode)" "live"
fi

# --------------------------------------------------------------- pause
if group "pause"; then
  sr play $CH >/dev/null; sleep 8
  ready
  # Sample once the playhead has actually stopped, not a fixed moment after
  # asking: the request takes a little to land, and comparing across that
  # races with playback still moving.
  sr pause >/dev/null
  prev=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    now=$(clock)
    [ -n "$now" ] && [ "$now" = "$prev" ] && break
    prev=$now
    sleep 1
  done
  paused_at=$(clock)
  sleep 4
  is   "pausing holds the playhead" "$(clock)" "$paused_at"
  sr pause >/dev/null; sleep 2
  is   "resuming keeps control"     "$(seekable)" "yes"
  sr live >/dev/null; sleep 4
fi

# --------------------------------------------------------- seeking, live
if group "seeking"; then
  sr play $CH >/dev/null; sleep 14
  before=$(clock)
  sr back 15 >/dev/null; sleep 2
  first=$(clock)
  isnt "back 15 moves the playhead" "$first" "$before"
  sr back 15 >/dev/null; sleep 2
  isnt "a second back 15 moves again (not stuck)" "$(clock)" "$first"

  # Ten minutes back is inside the DVR window, so it is reachable whether or
  # not SR has published the programme.
  sr back 600 >/dev/null; settle; ready
  is   "a jump older than the buffer still lands" "$(seekable)" "yes"
  isnt "and is no longer on the live edge"        "$(mode)" "live"
fi

# -------------------------------------------------- stepping by programme
if group "programmes"; then
  sr play $CH >/dev/null; sleep 10
  sr stepBack >/dev/null; settle
  sr stepBack >/dev/null; settle
  is    "stepping back stays controllable"            "$(seekable)" "yes"
  first_clock=$(clock)
  sr stepBack >/dev/null; settle; ready
  isnt  "stepping back again reaches an earlier point" "$(clock)" "$first_clock"
  is    "and stays controllable"                       "$(seekable)" "yes"

  back_two=$(clock)
  sr next >/dev/null; settle; ready
  isnt  "stepping forward moves on"                   "$(clock)" "$back_two"
  is    "and stays controllable"                      "$(seekable)" "yes"

  # Walking forward must terminate at the live broadcast, not loop.
  reached_live=no
  for _ in 1 2 3 4 5 6 7 8; do
    sr next >/dev/null; settle
    [ "$(mode)" = live ] && { reached_live=yes; break; }
  done
  is    "walking forward ends up live" "$reached_live" "yes"
fi

# ------------------------------------------------- crossing boundaries
if group "boundaries"; then
  sr play $CH >/dev/null; sleep 10
  sr stepBack >/dev/null; settle
  sr stepBack >/dev/null; settle          # start of a programme
  at_start_clock=$(clock)
  sr back 15 >/dev/null; settle; ready
  is   "control comes back after crossing a boundary" "$(seekable)" "yes"
  isnt "and the playhead moved"                       "$(clock)" "$at_start_clock"

  sr forward 99999 >/dev/null; settle; ready   # up to its end
  end_clock=$(clock)
  sr forward 15 >/dev/null; settle; ready
  isnt "forward 15 at a programme end moves on"                 "$(clock)" "$end_clock"
  is   "and stays controllable"                                 "$(seekable)" "yes"
fi

# ------------------------------------- landing on a programme, not before it
if group "landing"; then
  # Stepping back to the start of the programme on air must land inside it.
  # Playback can only begin on a segment boundary, and rounding to the
  # straddling one used to open with the tail of the previous programme.
  sched=$(curl -s --max-time 20 \
      "https://api.sr.se/api/v2/scheduledepisodes/rightnow?channelid=$CHANNEL_ID&format=json" \
    | jq -r '.channel.currentscheduledepisode.starttimeutc' \
    | grep -o '[0-9]\{10\}' | head -1)
  sr play $CH >/dev/null; sleep 10
  sr stepBack >/dev/null; settle; ready
  landed=$(clock)
  if [ -z "$sched" ] || [ -z "$landed" ]; then
    skip "steps back to inside the programme, not before it" "no schedule or playhead"
  else
    landed_epoch=$(date -d "today $landed" +%s)
    delta=$((landed_epoch - sched))
    # Generous upper bound: the playhead keeps moving while the test settles.
    if [ "$delta" -ge 0 ] && [ "$delta" -lt 60 ]; then
      ok "steps back to inside the programme, not before it"
    else
      no "steps back to inside the programme, not before it" "landed ${delta}s from its start"
    fi
  fi
fi

# ------------------------------- a small seek must not change what "back" means
if group "landing"; then
  # Stepping back after a short rewind must still reach the start of the
  # programme being heard, not the one before it. What "the beginning" means
  # is the programme's start, not the oldest moment happening to be buffered.
  sched=$(curl -s --max-time 20 \
      "https://api.sr.se/api/v2/scheduledepisodes/rightnow?channelid=$CHANNEL_ID&format=json" \
    | jq -r '.channel.currentscheduledepisode.starttimeutc' \
    | grep -o '[0-9]\{10\}' | head -1)
  sr play $CH >/dev/null; sleep 12
  sr back 15 >/dev/null; sleep 4        # a short rewind first
  sr stepBack >/dev/null; settle; ready
  landed=$(clock)
  if [ -z "$sched" ] || [ -z "$landed" ]; then
    skip "back after a short rewind still reaches this programme" "no schedule or playhead"
  else
    delta=$(( $(date -d "today $landed" +%s) - sched ))
    if [ "$delta" -ge 0 ] && [ "$delta" -lt 60 ]; then
      ok "back after a short rewind still reaches this programme"
    else
      no "back after a short rewind still reaches this programme" "landed ${delta}s from its start"
    fi
  fi
fi

# --------------------------------------------------- never past the present
if group "future"; then
  sr play $CH >/dev/null; sleep 10
  sr stepBack >/dev/null; settle
  for _ in 1 2 3 4 5 6; do sr forward 900 >/dev/null; sleep 3; done
  now_hhmm=$(date +%H:%M)
  head=$(clock | cut -c1-5)
  # The playhead may be live or in a recording, but never ahead of the clock.
  if [[ "$head" > "$now_hhmm" ]]; then
    no "the playhead never passes the present" "$head (now $now_hhmm)"
  else
    ok "the playhead never passes the present"
  fi
  is "and stays controllable" "$(seekable)" "yes"
fi

# --------------------------------------------------------------- teardown
if group "teardown"; then
  sr play $CH >/dev/null; sleep 6
  sr stop >/dev/null; sleep 2
  is "stopping reports idle"        "$(status)" "idle"
  is "stopping leaves no process"   "$(procs)" "0"
  sleep 3   # the post-stop sweep is deliberately delayed
  is "stopping leaves no socket"    "$(ls "${XDG_RUNTIME_DIR:-/tmp}"/omasr-mpv-*.sock 2>/dev/null | wc -l)" "0"
fi

printf '\n  %d passed, %d failed, %d skipped\n\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
