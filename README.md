# Sveriges Radio for Omarchy

An SR monogram in the Omarchy bar. Click it and you get P1, P2, P3 and P4 as
channel buttons:

- **Press a channel** — tunes in.
- **Press the playing channel again** — stops.
- **Press a different channel** — switches to it.

One stream plays at a time, always.

![The panel](docs/panel.png)

## Install

The plugin is a bar widget for `omarchy-shell`, so it lives in
`~/.config/omarchy/plugins/<plugin-id>/`. Symlink this checkout there, let the
shell find it, and put it in the bar:

```bash
ln -sfn "$PWD" ~/.config/omarchy/plugins/omasr.radio
omarchy-shell shell rescanPlugins
omarchy plugin enable omasr.radio --section left
```

Requires **mpv** (`sudo pacman -S mpv`), which decodes the stream. The panel
says so plainly if it is missing.

## Settings

Configured per bar-widget instance, in Setup > Plugins or directly in the
widget's entry in `~/.config/omarchy/shell.json`:

| Key        | Default          | What it does                                              |
|------------|------------------|-----------------------------------------------------------|
| `p4Region` | `P4 Stockholm`   | Which of the 26 regional P4 stations the P4 button tunes to |
| `barIcon`  | `Channel color`  | Tint the bar monogram with the playing channel's brand color, or keep it in the bar's own color |

## Keyboard and IPC

With the panel open: `1`-`4` tune directly, arrows or `hjkl` move the cursor,
`Enter`/`Space` activates it, `s` stops, `Esc` closes. Middle-clicking the bar
icon stops without opening anything.

Everything is also reachable over the shell's IPC, which is what you bind
Hyprland keys to:

```bash
omarchy-shell omasr play p3        # tune in, no panel
omarchy-shell omasr playPause p3   # same-channel toggle
omarchy-shell omasr stop
omarchy-shell omasr status         # "playing P4 Stockholm" | "idle"
omarchy-shell omasr toggle         # show/hide the panel
```

## How it works

| File             | Role                                                          |
|------------------|---------------------------------------------------------------|
| `Panel.qml`      | Bar button, popup, keyboard handling, IPC surface             |
| `Player.qml`     | Playback state machine over an mpv child process              |
| `ChannelTile.qml`| One channel button and its playing/connecting/dimmed states   |
| `ChannelMark.qml`| The P1-P4 wordmarks as vector geometry                        |
| `SrMark.qml`     | The interlocking SR monogram as vector geometry               |
| `Channels.js`    | Channel table, stream URLs, P4 regions                        |

**Streams.** The URLs are the official `liveaudio` endpoints from SR's open API
(`https://api.sr.se/api/v2/channels`). Each redirects to whichever edge node
and bitrate SR is currently serving, so there is nothing here to keep in sync
when they move things around.

**Logos.** The SR monogram and the four channel wordmarks are drawn with
`QtQuick.Shapes` from Sveriges Radio's 2024 logo artwork rather than shipped as
bitmaps. That keeps them crisp at every bar size and scaling factor, and lets
the bar monogram take the theme's color the way every other Omarchy bar icon
does.

**Why mpv and not QtMultimedia.** `omarchy-shell` is one long-running process
that owns the bar, the panels and the lock screen. A decoder that wedges or
crashes on a bad stream would take the whole desktop shell down with it. A
child process costs one fork, is killed with a signal, and shows up in the
audio mixer as "Sveriges Radio" so its volume is adjustable like any other app.
It runs with `--no-config`, so a personal `~/.config/mpv/mpv.conf` cannot reach
into the bar widget.

**Dropouts.** Live streams drop. An unexpected exit reconnects up to three
times, 1.5s apart, before the panel gives up and reports the failure.

**Now playing.** When SR sends ICY metadata on the stream, the current
programme is shown under the tiles. Not every channel sends it at all times.

## Hacking on it

Editing `Panel.qml` — the manifest's entry point — hot-reloads on save. Edits
to the *other* QML files do not: the shell's QML engine keeps the compiled
types cached, so `rescanPlugins` will keep running the old code. Restart the
shell for those:

```bash
omarchy-restart-shell
```

QML errors land in the journal:

```bash
journalctl --user -f | grep -i omasr
```

## Notes

Sveriges Radio's logos and channel marks are SR's trademarks, reproduced here
to identify their channels in a personal desktop client. This project is not
affiliated with or endorsed by Sveriges Radio.

MIT licensed.
