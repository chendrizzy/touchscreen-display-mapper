# touchscreen-display-mapper

Make a USB touchscreen on macOS click on **its own display**.

macOS has no setting that ties a touchscreen to a display. With more than one
display connected, it takes the touch panel's absolute coordinates and scales
them onto **whichever display holds the cursor**. So tapping a secondary
touchscreen, such as a portable monitor or the screen built into a keyboard,
clicks the matching spot on your main monitor instead.

`touchscreen-display-mapper` is a small background agent that fixes that: a
touch on the panel moves the cursor to the touch screen and clicks where your
finger is.

## How it works

The agent runs as a per-user LaunchAgent and:

1. takes exclusive ownership ("seizes") of the touch panel's pointer
   interfaces, so macOS stops acting on them;
2. reads each interface's own **HID report descriptor** to learn where X, Y and
   the touch or button bits sit in its reports, so there is no per-device code;
3. replays each touch as mouse events (move, press, drag, release, double-click)
   inside the bounds of the display you chose.

It understands panels in **mouse-emulation mode** (absolute X/Y plus buttons,
which is what most touch panels send to a Mac; the panel's buttons and wheel
are passed through) and **digitizer** touch screens and pens. On a digitizer,
only a finger that lands while the tool is watching can press; it drives the
pointer until it lifts, and other fingers or a resting palm are ignored
meanwhile and never turn into a press later. If a panel sends both kinds of
report, its touch-screen digitizer reports win once they appear (a pen's do
not: fingers may still arrive only as mouse emulation). Touch *pads* are
deliberately left alone.

## Status

- **Verified end to end** on a MacBook Pro (Apple M4 Pro), macOS 27.0.1, with
  the touchscreen of a KeyGo keyboard (USB `27c0:0859`, wch.cn controller).
- **Descriptor parser tested** against real descriptors from the KeyGo panel,
  a WingCool/Goodix panel (`27c6:0529`) and an ILITEK panel (`222a:0001`).
- **Gestures** (`--gestures`, `--pinch`) verified on the KeyGo: tap, one-finger
  scroll (content follows the finger), rest-then-drag, and double-tap-and-drag
  zoom in Maps and Preview. Two-finger scroll and pinch are unit-tested only;
  the KeyGo reports one point.
- **CI** builds and runs the tests on GitHub's latest macOS runner.
- **Not yet tested:** Intel Macs, macOS 13 to 26, older toolchains, and other
  panels on real hardware. If you try it, please open an issue with your
  `list-devices` output and whether it worked.

## Requirements

- macOS 13 or later.
- A Swift 5.10 or later toolchain to build and install: Xcode 15.3 or later, or
  the Command Line Tools (`xcode-select --install`). Running the test suite
  (`swift test`) needs Swift 6 / Xcode 16 or later, because it uses Swift
  Testing.
- A touchscreen connected over USB.

## Install

```sh
git clone https://github.com/chendrizzy/touchscreen-display-mapper
cd touchscreen-display-mapper

# 1. Find your touch panel: the first column is the --device value.
swift run touchscreen-display-mapper list-devices

# 2. Find the display it sits on: the first column is the --display value.
swift run touchscreen-display-mapper list-displays

# 3. Install and start the agent.
scripts/install.sh --device <VID:PID> --display <VENDOR:MODEL>
```

For example, a KeyGo keyboard's touchscreen on the author's Mac:

```sh
scripts/install.sh --device 27c0:0859 --display 19083:13107
```

Then grant the two permissions the agent asks for, in **System Settings →
Privacy & Security**:

- **Input Monitoring**, to read the touch panel;
- **Accessibility**, to click.

Enable `touchscreen-display-mapper` in both lists. If it is not listed, click
**+** and add `~/.touchscreen-display-mapper/bin/touchscreen-display-mapper`
(press ⌘⇧G in the file picker to type the path). Until both are granted the
agent exits and launchd retries it every 30 seconds.

### Try it without taking over

`--observe` opens the panel without seizing it and posts nothing. Touches keep
behaving as they do today, and the log shows where each would have landed:

```sh
scripts/install.sh --device <VID:PID> --display <VENDOR:MODEL> --observe
tail -f ~/.touchscreen-display-mapper/log/stdout.log
```

Observe mode needs only Input Monitoring. Run `scripts/install.sh` again
without `--observe` to take the panel over; that also needs Accessibility.

### Multi-input mode (experimental)

Windows-style touch panels start up as a one-finger mouse, and only report
each finger separately once the host sets their *Device Mode* feature to
multi-input (2). Windows does that; macOS never does. `--multitouch` sends it
when the agent opens the panel and puts mouse mode (or the mode the panel
reported) back when the agent stops. Some panels, the KeyGo among them, answer
a read of the mode with bytes that are not the report, so the confirmation is
the log line `digitizer touches are arriving` on the next touch. If the log says a touch
`arrived as mouse emulation after multi-input mode was sent` and no digitizer
touches follow, the panel ignored the switch. Without `--gestures` one finger
still drives the pointer; with it, two fingers scroll, or zoom with `--pinch`
(see below). `--multitouch` changes the panel even with `--observe`.

### Gestures (experimental)

By default every touch is a mouse press, so dragging a finger selects or moves
things. `--gestures` makes the panel behave like a phone instead:

| Touch | Does |
|---|---|
| Tap | clicks where the finger landed; taps on nearly the same spot count up into a double-click |
| Drag | scrolls what is under the finger, so the content follows it |
| Rest half a second, then drag | presses where the finger landed and drags (move a window, select text) |
| Two fingers, drag | scrolls, on panels that report each finger |
| With `--pinch`: double-tap, then drag down or up | zooms in or out |
| With `--pinch`: two fingers apart or together | zooms, on panels that report each finger |

The click of a tap is posted when the finger lifts; to press and hold, rest the
finger first. The KeyGo reports a single point however many fingers touch (it
ignores `--multitouch` on a Mac), so there a two-finger drag also scrolls as one
finger; the two-finger gestures have only been unit-tested, never on a panel. Zoom
uses gesture events that no public macOS API creates; their encoding comes from
[HIDTouch](https://github.com/koshi545/HIDTouch), and a macOS update could
change it, in which case zooming stops without any error in the log. With
`--gestures` only the touch itself is read: a pen's barrel buttons are ignored.

### Signing and permissions

macOS remembers the Input Monitoring and Accessibility grants against the
binary's code signature. `install.sh` signs with the first **Developer ID
Application** or **Apple Development** identity in your keychain, so the
grants survive reinstalls.

Without one, it signs ad-hoc and warns you. The agent works the same, but every
reinstall looks like a new app to macOS, and you have to re-enable it in both
lists. To avoid that, create a self-signed code-signing certificate (Keychain
Access → Certificate Assistant → Create a Certificate…, Identity Type *Self
Signed Root*, Certificate Type *Code Signing*) and install with:

```sh
TSDM_SIGN_IDENTITY="<certificate name>" scripts/install.sh --device … --display …
```

The self-signed route follows the usual practice for macOS input tools but has
not been tested with this project yet.

## Usage

| Task | Command |
|---|---|
| Logs | `tail -f ~/.touchscreen-display-mapper/log/stdout.log` |
| Status | `launchctl print gui/$(id -u)/io.github.chendrizzy.touchscreen-display-mapper` |
| Update | `git pull`, then `scripts/install.sh` with the same arguments |
| Uninstall | `scripts/uninstall.sh` (the panel goes back to macOS at once). It leaves `~/.touchscreen-display-mapper` (binary and logs) and the permission entries; remove those by hand |

`install.sh` options:

| Option | Meaning |
|---|---|
| `--device VID:PID` | the touch panel, hexadecimal, from `list-devices` |
| `--display VENDOR:MODEL[:SERIAL]` | the display, decimal, from `list-displays`. The serial is only needed when two displays share a vendor and model |
| `--lift-timeout MS` | release a held touch after this many milliseconds without a report (default 500; `0` disables). See below |
| `--multitouch` | switch the panel to multi-input mode; see above |
| `--gestures` | phone-style touch: tap, scroll, rest-then-drag; see above |
| `--pinch` | with `--gestures`: zoom by double-tap-and-drag or two fingers; see above |
| `--observe` | listen only; see above |
| `--dry-run` | print what would be installed and stop |

Environment: `TSDM_SIGN_IDENTITY` (signing identity name or SHA-1; `-` forces
ad-hoc) and `TSDM_HOME` (install directory, default
`~/.touchscreen-display-mapper`).

## Troubleshooting

- **Touches still land on the cursor's display.** Check the log for
  `opened … seized` lines. A `could not open … another process already seized
  it` line means another tool owns the panel.
- **Touches do nothing.** Look for `display … is not online` (the display is
  off or `--display` is wrong) or `N displays match` (add the serial).
- **Long presses or slow drags get cut short.** Panels resend their state while
  a finger is down, and a gap longer than `--lift-timeout` counts as a lost
  release. Reinstall with a larger value, or `0` to turn it off.
- **`ignoring report id …` and no touches.** The panel sends a report the
  decoder does not understand. Please open an issue with the `list-devices`
  output and that log line.

## Limitations

- **Two fingers at most.** Without `--gestures`, one finger drives the pointer
  as the left mouse button. With it, gestures use one or two fingers; there is
  no right-click (such as a two-finger tap), no scroll momentum after the
  finger lifts, and no three- or four-finger gestures.
- **`--multitouch` is put back only on a clean stop.** If the agent crashes,
  macOS gets the panel back still in multi-input mode until launchd restarts
  the agent or the panel is replugged; how macOS handles a panel in that mode
  has not been tested. Neither has whether a panel drops back to mouse mode on
  its own after the Mac sleeps.
- **Whole interfaces are taken over.** If a pen display reports its express
  keys or pen buttons on the same HID interface as the pen, those stop working
  while the agent runs.
- **One panel per install.** Two panels with the same VID:PID would both be
  mapped to the same display.
- **Fast user switching** (expected from how seizing works, not tested): the
  agent keeps the panel for the user who started it, so other logged-in users
  get no touch input.
- **Logs are not rotated.** `--observe` logs every touch, so do not leave it on.
- **Panels are assumed to resend while touched** (Windows-certified panels
  do; the tested KeyGo resends every 9 to 19 ms). A held finger that sends
  nothing for `--lift-timeout` is released, and on a digitizer that does not
  resend stationary contacts, a resting finger can then press once when it
  moves. With `--gestures` on such a panel, a resting finger is released
  before it can become a press-and-drag unless `--lift-timeout` is above 500
  or `0`. With `--lift-timeout 0`, a panel that never reports a lift can leave
  a touch held until the agent restarts.
- **A hung agent blocks the panel.** If the agent hangs rather than crashes,
  touch stays unresponsive until it is restarted:
  `launchctl kickstart -k gui/$(id -u)/io.github.chendrizzy.touchscreen-display-mapper`.

## Acknowledgements

The parser tests use real report descriptors published by
[HIDTouch](https://github.com/koshi545/HIDTouch) (WingCool/Goodix panel) and
[mitm-touch](https://github.com/mmarsz/mitm-touch) (ILITEK panel), both under
the MIT License; see `Tests/TouchMapperCoreTests/OtherPanelFixtures.swift`.
HIDTouch's `CGEventInjector.swift` is also the source of the zoom gesture's
event encoding and of the finding that a mouse release posted together with its
press is dropped.
[Touchward](https://github.com/nguyenthienthanh/touchward) documented a
key IOKit pitfall: opening the HID manager before seizing a device makes the
seize silently fail.

## License

MIT. See [LICENSE](LICENSE).
