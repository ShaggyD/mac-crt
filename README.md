# Mac CRT

[![CI](https://github.com/ShaggyD/mac-crt/actions/workflows/ci.yml/badge.svg)](https://github.com/ShaggyD/mac-crt/actions/workflows/ci.yml)

A macOS menu-bar app that puts an amber/phosphate CRT look over your whole
screen — scanlines, phosphor glow, vignette and optional tube curvature — with
four selectable palettes: **Amber**, **Red**, **Sepia** and **Monochrome**.

Click-through and input-transparent: every click, drag and scroll still reaches
whatever is underneath. It is purely cosmetic.

Requires macOS 14 or later. Apple silicon and Intel.

## Install

### From a release (recommended)

1. Download **`MacCRT.zip`** from the [latest build](https://github.com/ShaggyD/mac-crt/releases/tag/latest)
   (rolling, updated on every push to `main`) or from a
   [tagged release](https://github.com/ShaggyD/mac-crt/releases).
2. Unzip it and drag **Mac CRT.app** into `/Applications`.
3. Clear the quarantine flag — see below.
4. Launch it. There is no Dock icon; look for the `tv` glyph in the menu bar.

#### Why you have to clear the quarantine flag

The app is **not notarized** (that needs a paid Apple Developer account), so
Gatekeeper will refuse to open it with *"Mac CRT is damaged"* or *"cannot be
opened because Apple cannot check it for malicious software"*. The download is
fine; it simply has no signature Apple recognises.

```sh
xattr -dr com.apple.quarantine "/Applications/Mac CRT.app"
```

Or right-click the app and choose **Open** once. Either way, this is a one-time
step. If you would rather not run unsigned software, build it yourself — see
below, it takes about ten seconds.

### From source

```sh
git clone https://github.com/ShaggyD/mac-crt.git
cd mac-crt
make app          # assembles build/Mac CRT.app
make run          # builds and opens it
```

`make app` ad-hoc signs the bundle locally, so no quarantine flag is applied and
nothing needs clearing.

## Turning on the True CRT engine

Out of the box the app uses the **colour-table engine**: no permissions, no
latency. It is enough for the amber look, but it *cannot* produce true
monochrome — see [the two engines](#the-two-engines) for why.

For real per-pixel colour work:

1. Menu bar → **True CRT Engine** (this triggers the system prompt)
2. **System Settings ▸ Privacy & Security ▸ Screen Recording** → enable **Mac CRT**
3. **Relaunch** — macOS only applies a new Screen Recording grant at launch

If the capture stream fails for any reason, the app falls back to the
colour-table engine automatically rather than leaving you with bare scanlines
over an untinted desktop. The menu will say *"True CRT blocked"* when that
happens.

> **Note on rebuilds.** The app is ad-hoc signed, which hashes the binary, so
> every rebuild is a new identity to macOS and the Screen Recording grant will
> be dropped. Sign with a stable certificate if you rebuild often.

## Settings

| Control | Range | Notes |
|---|---|---|
| CRT effect | on/off | master switch |
| Phosphor | Amber / Red / Sepia / Monochrome | Monochrome needs the True CRT engine |
| Colour strength | 0–100% | **0% = original colours, 100% = only the phosphor colour** |
| Contrast | 0.5–2.0× | pivoted at mid grey; counters the flatness heavy desaturation causes |
| Scanlines | 0–100% | |
| Line pitch | 1–8 px | snapped to whole device pixels; see below |
| Curvature | 0–0.5 | **defaults to 0** — see below |
| Vignette | 0–100% | corner darkening |
| Glow | 0–100% | cheap 8-tap phosphor bloom |
| Flicker | 0–0.20 | |
| True CRT engine | on/off | ScreenCaptureKit; needs Screen Recording |
| CRT cursor | on/off | tints the pointer with the rest of the picture |

Settings persist between launches.

## The two engines

This is the whole design, and it exists because of a hard macOS constraint.

| | **Colour tables** (default) | **True CRT engine** (opt-in) |
|---|---|---|
| Mechanism | `CGSetDisplayTransferByTable` + transparent shader overlay | ScreenCaptureKit → Metal shader → opaque overlay |
| Colour | Warm **cast** only | True per-pixel desaturation |
| Monochrome | ❌ not possible | ✅ real |
| Permission | none | Screen Recording (one-time) |
| Latency | none | ~1 frame |
| Cost | ~2% CPU | ~4% CPU |
| In screenshots | ❌ invisible (applied at scanout) | ✅ visible |

### Why the default engine can't do monochrome

`CGSetDisplayTransferByTable` applies **one 1-D curve per channel**. It maps
R→R, G→G, B→B independently. Desaturation is `luminance = 0.2126R + 0.7152G +
0.0722B`, which *mixes* channels per pixel — something a per-channel table
structurally cannot express. Measured on a colour-bar test card, the LUT engine
leaves green green and magenta magenta; only the cast changes.

The arithmetic shows it breaking. Amber is `(1.00, 0.66, 0.15)`. For pure green
to land on that axis you would need `R_out(0) = G_out(1) / 0.66 = 1.51`, which
is outside the `[0,1]` range the hardware accepts. Not a tuning problem;
unreachable.

Getting real channel mixing requires the actual framebuffer pixels, which means
ScreenCaptureKit. So the app ships both, defaults to the free one, and switches
to the real one when you ask for it.

## Technical notes

### Colour strength

This is the saturation control. At 100% the shader replaces every pixel with
`phosphor x luminance`, so nothing but the selected colour survives:

```metal
float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
c = mix(c, P.tint.rgb * lum, P.tint.w);
```

Measured hue deviation from the amber axis across the slider: **33.2° at 0% →
24.9° at 50% → 1.3° at 100%**.

On the colour-table engine this control cannot reach the top of its range, and
the panel says so inline.

### Line pitch

The pitch is snapped to a whole number of device pixels and the phase is taken
from the integer row, so lines land exactly on the pixel grid. Both details
mattered:

- A non-integer pitch resamples the pattern through the frame and beats into a
  moiré haze that reads as blur.
- Using the pixel-*centre* coordinate put the phase at `fract(0.25)` and
  `fract(0.75)` at pitch 2. `cos(2*pi*x)` is zero at both, so every row got an
  identical profile and the scanlines silently vanished into a flat 50% dim.

Measured modulation depth on a flat white strip at 35% scanline strength:
**2px → 42.4%, 3px → 21.4%, 4px → 21.2%, 6px → 14.1%**.

### Curvature

Corner-pinning barrel warp. The radial scale is exactly 1.0 at the corner
(`r2 == 0.5`) and shrinks toward the middle, so the centre bulges while every
sample stays inside the frame. Verified numerically: **zero samples leave
`[0,1]` at every curvature value**, and the radial map is strictly monotonic, so
it cannot fold or crop.

This replaced a standard `uv += centered * r2 * k` warp, which pushes edge
samples past the frame and paints those pixels black — silently cropping
whatever sits near the screen edges.

### The cursor

The macOS cursor is composited by the window server **above every window**,
including the overlay, so by default it sits on top of the effect untinted. With
**CRT cursor** enabled the pointer is captured into the frame and the real one is
hidden, so the shader tints and scanlines it with everything else. It keeps its
real, context-sensitive shape — arrow, I-beam, resize arrows.

The trade-off is about one frame of lag, since the pointer now travels with the
captured frame. Turn the switch off for a crisp native pointer.

The pointer is only hidden while capture is genuinely painting it back; in every
other state the real cursor stays visible.

## Recovery

A gamma table **outlives the process that set it**, and so does the cursor hide
counter. The app restores both:

- on quit (`Restore Display & Quit`)
- on `SIGTERM` / `SIGINT` / `SIGHUP`
- unconditionally on every launch, healing a previous crash

If you ever end up with a tinted display, or an invisible pointer, and no app
running:

```sh
"/Applications/Mac CRT.app/Contents/MacOS/MacCRT" --reset
```

## Diagnostics

```sh
MacCRT --check-access   # is Screen Recording granted?
MacCRT --reset          # restore display colour state and cursor visibility
MacCRT --selftest       # build Metal pipeline + settings panel, then exit
```

`--check-access` run from a terminal reports the **terminal's** permission, not
the app's: a directly-executed binary inherits the calling process's TCC
identity. That is a useful development shortcut — `make dev` runs with your
terminal's grant and skips the one-time prompt — but it also means the app can
look verified while the *bundled* app is silently falling back.

The authoritative answer for the shipped app is written on every capture state
change:

```sh
cat ~/Library/Application\ Support/MacCRT/capture-state.txt
# running
# failed: Screen Recording permission was declined.
```

## Development

```sh
make build      # compile only
make app        # assemble build/Mac CRT.app
make run        # assemble and launch
make dev        # run the raw binary (inherits your terminal's TCC identity)
make selftest   # build + run the self-test
```

### Releases

`.github/workflows/release.yml` handles publishing:

- **Push to `main`** → rebuilds and replaces the assets on a rolling
  [**latest**](https://github.com/ShaggyD/mac-crt/releases/tag/latest)
  pre-release. The `latest` tag itself is a placeholder and does not move.
- **Push a `v*` tag** → creates a versioned release with generated notes.

```sh
git tag v1.0.0 && git push origin v1.0.0
```

`.github/workflows/ci.yml` builds and verifies the bundle on every push and pull
request.

### Layout

```
Sources/MacCRT/
  main.swift                  entry point, flags, signal handlers
  CRTMode.swift               palettes + which engine each needs
  Settings.swift              observable persisted state
  DisplayLUT.swift            colour-table engine (and its limitations)
  CaptureEngine.swift         ScreenCaptureKit, one stream per display
  CRTShader.swift             Metal source + shared parameter block
  OverlayWindow.swift         click-through window above menu bar and Dock
  OverlayCoordinator.swift    owns both engines, the render clock, fallbacks
  SystemCursor.swift          hide/restore the pointer, with crash healing
  SettingsPanel.swift         control panel
  StatusItemController.swift  menu bar
```

## Known limits

- **DRM video renders black** through the True CRT engine (Netflix, some
  players). Standard for any capture-based pipeline.
- The colour-table engine's effects never appear in screenshots or screen
  recordings, because they are applied at display scanout.
- Not notarized, so a downloaded build needs its quarantine flag cleared.
- The overlay sits above the menu bar and Dock by design. System alerts and the
  Force Quit panel still sit above it.
- Curvature cannot crop, but it does reshape the picture: the centre is
  magnified and the edges compressed. Set it to 0 for a geometrically exact
  image.

## Two HiDPI traps worth remembering

Both produced a picture that looked merely "soft" rather than obviously broken,
which is why they are written down.

**`CGDisplayPixelsWide` returns points, not pixels, on a HiDPI panel.** On the
development machine it reports 2056 for a 4112-wide framebuffer. Feeding it to
`SCStreamConfiguration` captured at half resolution, and the compositor then
upscaled 2x into the drawable. The capture size now comes from
`NSScreen.frame * backingScaleFactor`, so capture and drawable match 1:1. This
one bug was the whole of an "it kinda just blurs" complaint.

**A completion handler must be registered before `commit()`.** Metal asserts
otherwise, and the assertion takes the process down.

## Verified behaviour

Measurements taken on macOS 27 (arm64, 4112×2658):

- Colour tables: white → exactly the amber tint `(1.00, 0.66, 0.15)`; restored
  to identity on `SIGTERM`.
- True CRT engine: monochrome mean saturation **`0.0000`** (control: `0.7192`).
  Amber/red/sepia hue deviation **< 1°** — every pixel sits on the tint axis.
- Colour strength spans **33.2° → 1.3°** hue deviation from 0% to 100%.
- Contrast 0.5x/1.8x: luminance std dev **34.2 / 70.5**.
- Scanlines: **42.4%** modulation at 2px pitch, **0.1%** before the phase bug
  was fixed.
- Curvature at 0.5: corner luminance `7.7–42.9` (content present) versus
  `0.1–4.4` before the mapping was fixed (cropped to black).
- Cursor: present in the captured frame with the option on (104 dark pixels,
  darkest `0.0`), absent with it off.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

    Mac CRT — a whole-screen CRT effect for macOS
    Copyright (C) 2026 Dusty Chadwick

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
