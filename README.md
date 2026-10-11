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
| Tint | 0–100% | strength of the colour transform |
| Scanlines | 0–100% | |
| Line pitch | 1–8 px | spacing between scanlines |
| Curvature | 0–0.5 | **defaults to 0** — see below |
| Vignette | 0–100% | corner darkening |
| Glow | 0–100% | cheap 8-tap phosphor bloom |
| Flicker | 0–0.20 | |

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

## Verified behaviour

Measurements taken on macOS 27 (arm64, 4112×2658):

- Colour tables: white → exactly the amber tint `(1.00, 0.66, 0.15)`; restored
  to identity on `SIGTERM`.
- Overlay: scanline row-to-row alternation `0.04 → 36.29` on a flat test card.
- True CRT engine: monochrome mean saturation **`0.0000`** (control: `0.7192`).
  Amber/red/sepia hue deviation **< 1°** — every pixel sits on the tint axis.
- Curvature at 0.5: corner luminance `7.9–45.5` (content present) versus
  `0.1–4.4` before the mapping was fixed (cropped to black).
