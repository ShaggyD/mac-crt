# CRT Overlay

A macOS menu-bar app that puts an amber/phosphate CRT look over your whole
screen — scanlines, phosphor glow, vignette and optional tube curvature — with
four selectable palettes: **Amber**, **Red**, **Sepia** and **Monochrome**.

Click-through and input-transparent: every click, drag and scroll still reaches
whatever is underneath. It is purely cosmetic.

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

Getting real channel mixing requires the actual framebuffer pixels, which means
ScreenCaptureKit. So the app ships both, defaults to the free one, and switches
to the real one when you ask for it.

## Build and run

```sh
cd ~/dev/crt-overlay
make app          # assembles build/CRTOverlay.app (ad-hoc signed)
make run          # builds and opens it
```

Requires macOS 14+. The app is an accessory (no Dock icon) — look for the `tv`
glyph in the menu bar.

### Enabling the True CRT engine

1. Menu bar → **True CRT Engine**, or toggle it in **Settings…**
2. Approve **System Settings ▸ Privacy & Security ▸ Screen Recording**
3. Relaunch — macOS only applies a new Screen Recording grant at launch

If the stream fails, the app falls back to the colour-table engine automatically
rather than leaving you with bare scanlines over an untinted desktop.

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

### Colour strength

This is the saturation control. At 100% the shader replaces every pixel with
`phosphor x luminance`, so nothing but the selected colour survives:

```metal
float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
c = mix(c, P.tint.rgb * lum, P.tint.w);
```

Measured hue deviation from the amber axis across the slider: **33.2° at 0% →
24.9° at 50% → 1.3° at 100%**.

On the **colour-table engine** this control cannot reach the top of its range.
A per-channel curve cannot express `phosphor x luminance` at all, so it only
casts. That is the same limitation as Monochrome, and the panel says so inline.

### Line pitch

The pitch is snapped to a whole number of device pixels and the phase is taken
from the integer row, so lines land exactly on the pixel grid. Both details
mattered:

- A non-integer pitch resamples the pattern through the frame and beats into a
  moire haze that reads as blur.
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

## Recovery

A gamma table **outlives the process that set it**, so the app also restores the
display:

- on quit (`Restore Display & Quit`)
- on `SIGTERM` / `SIGINT` / `SIGHUP`
- unconditionally on every launch, healing a previous crash

If you ever end up with a tinted display and no app running:

```sh
./build/CRTOverlay.app/Contents/MacOS/CRTOverlay --reset
```

## Diagnostics

```sh
CRTOverlay --check-access   # is Screen Recording granted?
CRTOverlay --reset          # restore display colour state
CRTOverlay --selftest       # build Metal pipeline + settings panel, then exit
```

`--check-access` run from a terminal reports the **terminal's** permission, not
the app's: a directly-executed binary inherits the calling process's TCC
identity. That is a useful development shortcut — `make dev` runs with your
terminal's grant and skips the one-time prompt — but it also means the app can
look verified while the *bundled* app is silently falling back.

The authoritative answer for the shipped app is written on every capture state
change:

```sh
cat ~/Library/Application\ Support/CRTOverlay/capture-state.txt
# running
# failed: Screen Recording permission was declined.
```

## Granting Screen Recording

A new grant only takes effect at launch, so the sequence is:

1. Menu bar → **True CRT Engine** (this triggers the system prompt)
2. System Settings ▸ Privacy & Security ▸ **Screen Recording** → enable **CRT Overlay**
3. **Relaunch** the app

Until then the app runs the colour-table engine and the menu says
*"True CRT blocked · Screen Recording not granted"*.

## Layout

```
Sources/CRTOverlay/
  main.swift              entry point, flags, signal handlers
  CRTMode.swift           palettes + which engine each needs
  Settings.swift          observable persisted state
  DisplayLUT.swift        colour-table engine (and its limitations)
  CaptureEngine.swift     ScreenCaptureKit, one stream per display
  CRTShader.swift         Metal source + shared parameter block
  OverlayWindow.swift     click-through window above menu bar and Dock
  OverlayCoordinator.swift owns both engines, the render clock, fallbacks
  SettingsPanel.swift     control panel
  StatusItemController.swift  menu bar
```

## Known limits

- **DRM video renders black** through the True CRT engine (Netflix, some
  players). Standard for any capture-based pipeline.
- The colour-table engine's effects never appear in screenshots or screen
  recordings, because they are applied at display scanout.
- Rebuilding the app changes its code signature hash, so macOS may re-ask for
  Screen Recording permission.
- The overlay sits above the menu bar and Dock by design. System alerts and the
  Force Quit panel still sit above it.
- Curvature cannot crop, but it does reshape the picture: the centre is
  magnified and the edges compressed. Set it to 0 for a geometrically exact
  image.

## Two HiDPI traps worth remembering

Both produced a picture that looked merely "soft" rather than obviously broken,
which is why they are written down.

**`CGDisplayPixelsWide` returns points, not pixels, on a HiDPI panel.** On this
machine it reports 2056 for a 4112-wide framebuffer. Feeding it to
`SCStreamConfiguration` captured at half resolution, and the compositor then
upscaled 2x into the drawable. The capture size now comes from
`NSScreen.frame * backingScaleFactor`, so capture and drawable match 1:1. This
one bug was the whole of the "it kinda just blurs" complaint.

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
