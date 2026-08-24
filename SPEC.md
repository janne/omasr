# Behaviour

What each control does, in each state. This is the contract `test/transport.sh`
checks and the thing to update *first* when behaviour should change.

## The two sources

Everything follows from there being two ways to hear a programme:

- **live** — the channel's HLS live stream, which carries a rolling DVR window
  of roughly **three hours** stamped with absolute times. Anything inside that
  window can be played, whatever the programme is. Small moves use what the
  player has already buffered; reaching further back restarts the stream at
  the right segment, because ffmpeg will not seek inside a live playlist.

  Playback can therefore only begin on a **segment boundary**, about every 6
  seconds. An instant inside a segment rounds *up*, to the boundary at or after
  it: going to a programme's start may miss a few seconds of its opening, but
  never opens with the end of the programme before it.

  Position is measured back from the **live edge**, not forward from the
  playlist's `EXT-X-PROGRAM-DATE-TIME`. SR's stamp runs about half a minute
  ahead of real time, and taking it at face value put every jump that far
  early.
- **recorded** — a file SR has published for a programme. Seekable throughout,
  and the only way back beyond the DVR window.

The DVR window is preferred wherever it reaches, since it does not depend on
SR having published anything.

`omarchy shell omasr status` reports which source is playing:

    playing P1 [live seek at 14:27:50]        live, on the live edge
    playing P1 [-19s seek at 14:27:31]        live, 19s behind
    playing P1 [-1522s seek at 16:48:14]      live, 25 minutes back in the DVR window
    playing P1 [recorded seek at 13:30:00]    a published file
    playing P1 [... NOSEEK ...]               mpv's control socket is not up

## Channel buttons

| Action | Result |
|---|---|
| Press a channel | Tunes in live |
| Press the playing channel | Stops |
| Press another channel | Switches to it |

Exactly one stream plays at a time, always.

## Transport

### Direkt

Lit red lamp while on the live edge; otherwise a button that returns there.
Returning from a recorded programme re-tunes the channel, since a file has no
live edge to seek to.

### Timeline

Spans the programme being heard, labelled with its broadcast start and end.
The bright section is what can actually be reached — the whole programme when
it is published, only what has been buffered when it is not. Clicking seeks to
that instant, switching source if the instant lies in another programme or in
a published file. A target that cannot be reached clamps to the nearest point
that can.

### ↺ 15 / ↻ 15

Jump a quarter minute, and continue across programme boundaries:

- Back off the **start** of a programme → the **end** of the previous one.
- Forward off the **end** of a programme → the **start** of the next one.
- Forward off the end of the programme **on air** → the live broadcast.

Forward never runs past what has been broadcast. Back is dimmed only when
there is genuinely nothing behind; forward only while on the live edge.

### |◀ step back

- Playhead well into the programme → its beginning.
- Within about twenty seconds of the beginning → the previous programme, from
  its start.

Twenty rather than the two or three such a grace would normally be: arriving
is not instant. Restarting the stream takes a few seconds, a jump to a
programme's start already lands several seconds into it, and the listener
needs a moment to press again — a tighter window expires before the second
press lands, which makes walking back through programmes impossible.

Repeated presses keep walking back through the day's schedule.

"Its beginning" is the programme's actual start, reached through the DVR
window or a published file. Only when neither reaches it — a programme older
than the window that SR never published — does it fall back to the oldest
buffered moment. In particular, a short rewind beforehand must not change what
"the beginning" means: it is a property of the programme, not of whatever
happens to be buffered.

### ▶| step forward

Available anywhere behind the live edge, whether that is a published file or a
position inside the DVR window — being time-shifted is not the same as playing
a recording, and both have something ahead of them.

- Behind the live edge → the next programme, from its start.
- The programme **on air** is played from its beginning like any other.
- Already inside the on-air programme → joins the live broadcast.
- A programme playing out to its end advances the same way on its own.

### Cover art and captions

While playing, the panel names the programme being heard and shows its cover
art beneath, whole and at its own proportions -- never cropped, since SR
composes these wide and the subject is often at an edge. A second line carries
what SR is announcing over the stream, but only when it says something the
programme name does not.

All three follow the *playhead*, so stepping back through programmes changes
them. Artwork comes from the schedule entry where it has one and from the
programme otherwise; every programme has one, so it is normal for a picture to
appear a moment after the name.

**They change only when the programme does.** Any seek outside what the player
holds restarts the stream, and while that happens the playhead is briefly
meaningless — so the name and picture are held rather than recomputed, and a
seek that stays inside the same programme leaves the caption untouched. It
must not blink.

### Media keys

The player is on the MPRIS bus, so the system media keys control it and it
appears in the bar's now-playing widget, named after the programme. Pausing
that way is a time shift like any other -- it is taken from mpv rather than
from whoever asked.

### Play / pause

`Space` in the panel, the play/pause button, the media keys, or `omasr pause`.
On a live stream this is itself a time shift: the broadcast carries on
without you and resuming picks up where you stopped.

The playing channel's level meter settles flat while paused, rather than
carrying on or freezing part-way through a bounce.

## Rules that hold everywhere

1. **One mpv process.** Never two, never zero while something is playing.
2. **The playhead never passes the present.** No seek, in either source, may
   reach audio that has not been broadcast.
3. **Live means live.** Direkt reaches the actual broadcast, not the head of
   whatever the player happens to hold. After sleep, or a pause long enough
   for the buffer to stall, that means re-tuning rather than seeking.
4. **The control socket recovers.** If mpv's IPC is not up, every transport
   control disables together, and the retry loop keeps trying — `NOSEEK` is
   never a permanent state while a process is running.
5. **Stopping leaves nothing behind.** No process, no socket.
6. **A control that cannot act is dimmed** rather than silently doing nothing.

## Known limits

- **Beyond about three hours**, only published programmes can be reached. The
  DVR window ends there, so the walk continues through SR's published files
  and how far it reaches depends on what SR has published. Entries with no
  episode behind them at all are stepped over, not stopped on.
- **Restarting the stream costs a second or two.** Any move outside what the
  player has buffered respawns it, so a large jump has a short gap.
- **Positions round to a segment boundary**, so a jump lands within about six
  seconds after the instant asked for, never before it.
- **Repeats map imprecisely.** SR often fills a slot with a repeat whose file
  is a different length from the slot. Offsets derived from the schedule are
  clamped into the file, so clock positions inside such a programme are
  approximate.

