# SnapDesk

A screenshot, screen-recording and image-annotation tool for macOS, written in Swift/AppKit.
It lives in the menu bar (a "Snap" item with a camera icon) and in the Dock.

SnapDesk is an original app. It was inspired by the feature set of the Windows tool PicPick but contains none of its code, assets or branding.

- Requires **macOS 13 (Ventura) or later**, Apple silicon or Intel
- Everything runs locally: no accounts, no telemetry, no network calls

---

## 1. Install

### Option A: run the app that is already built

The built app is `SnapDesk.app`, in the same folder as this README.

1. (Optional) Drag `SnapDesk.app` into `/Applications`.
2. Double-click it. If macOS says it cannot verify the app, right-click it, choose **Open**, then **Open** again. You only need to do this once.
3. A welcome dialog appears. Click OK. SnapDesk is then running in the menu bar (look for **Snap** at the top right) and in the Dock.

### Option B: build it yourself

You need the Swift toolchain. Installing Xcode Command Line Tools is enough; full Xcode is not required.

```bash
xcode-select --install          # only if you do not have the tools yet
cd SnapDesk_App
./build_app.sh                  # builds release and creates SnapDesk.app
open SnapDesk.app
```

`build_app.sh` is a build script, not the app. Do not double-click it. Run it from a terminal.

The app is ad-hoc signed, so it is not notarised. If you build it yourself you may need the right-click → **Open** step above.

### Grant permissions

macOS asks for these the first time a feature needs them. If a feature does nothing, check **System Settings → Privacy & Security**:

| Permission | Needed for |
|---|---|
| **Screen Recording** | All captures, screen recording, color picker, magnifier, pixel ruler |
| **Accessibility** | Scrolling capture (it scrolls the window for you) and picking a single control with Window Control |
| **Microphone** | Recording microphone audio |

After granting Screen Recording, **quit and reopen SnapDesk**.

### Run the self-test (optional)

```bash
.build/release/SnapDesk --selftest
```

This runs 1,668 headless checks of the editor, effects, export, menus and helper logic. It does not test screen capture or recording, which need Screen Recording permission.

---

## 2. Shortcuts

### Global hotkeys (work from any app while SnapDesk is running)

| Action | Shortcut |
|---|---|
| Full Screen | ⌃⌥1 |
| Active Window | ⌃⌥2 |
| Window Control | ⌃⌥3 |
| Scrolling Window | ⌃⌥4 |
| Fixed Region | ⌃⌥5 |
| Region | ⌃⌥6 |
| Freehand | ⌃⌥7 |
| Repeat Last Capture | ⌃⌥8 |
| Start / Stop Recording | ⌃⌥R |
| Color Picker | ⌃⌥C |

(⌃ = Control, ⌥ = Option.) These avoid macOS's own ⌘⇧3/4/5 screenshot shortcuts. Hotkeys cannot be remapped yet.

### Editor shortcuts

| Action | Shortcut |
|---|---|
| Open image | ⌘O |
| Save As | ⌘S |
| Copy image to clipboard | ⌘C |
| Print | ⌘P |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Zoom in / out | ⌘+ / ⌘− |
| Fit to window | ⌘0 |
| Actual size (100%) | ⌘1 |
| Select the whole image | ⌘A |
| Clear the selection | ⌘D or Esc |
| Delete the selected object | ⌫ |
| Nudge the selected object | Arrow keys (hold ⇧ for 10 pixels) |
| Cancel an overlay (region, window picker, whiteboard, etc.) | Esc |

### While capturing

| Action | Key |
|---|---|
| Cancel a capture | Esc or right-click |
| Capture a window, fixed region or region | Click (or drag for Region) |

---

## 3. Using the menu

Click **Snap** in the menu bar, or right-click the Dock icon. The same grouped menu is in the app's menu bar when SnapDesk is in front.

- **Capture**: the eight capture modes
- **Record**: start or stop screen recording
- **Design Tools**: color picker, color palette, pixel ruler, magnifier, crosshair, protractor, whiteboard
- Open Image in Editor, Open Save Folder
- **Settings**
  - *After Capture*: open in editor, copy to clipboard, auto-save to folder
  - *Capture Options*: include mouse cursor, capture delay (none, 3, 5 or 10 seconds)
  - *Output*: image format, save folder
- Quit

By default, captures open in the editor. Auto-save writes to `~/Pictures/SnapDesk`, named `SnapDesk_yyyy-MM-dd_HH-mm-ss`. If two files get the same name, the second is numbered " (2)".

---

## 4. Features

### Screen capture

| Mode | What it does |
|---|---|
| **Full Screen** | Captures the screen the mouse is on |
| **Active Window** | Captures the frontmost window, even when other windows overlap it |
| **Window Control** | Hover to highlight a window (or, with Accessibility permission, the control under the cursor), then click |
| **Scrolling Window** | Pick a window; SnapDesk scrolls it and stitches the frames into one tall image. It stops when the content stops changing, or after 60 steps |
| **Fixed Region** | A rectangle of fixed size follows the mouse; click to capture. The size is set in preferences (default 800 × 600) |
| **Region** | Drag to select. Shows pixel dimensions and a magnifier loupe |
| **Freehand** | Draw a lasso. Pixels outside the shape come out transparent |
| **Repeat Last Capture** | Takes the previous region or window again |

Other capture options: capture delay with an on-screen countdown, include or hide the mouse cursor, multi-monitor support, and full-resolution (Retina) output.

### Screen recording

- Records a region, a window or the full screen to an `.mp4` file (H.264 video, AAC audio)
- Optional system audio and microphone
- Adjustable frame rate and quality
- A small floating control shows elapsed time and a Stop button, and is not captured in the video
- The file is saved to your save folder and shown in Finder when you stop

The ⌃⌥R hotkey records a region with system audio, 30 fps, no microphone.

### Image editor

The editor uses a ribbon with three tabs: **Home**, **Image** and **View**. Hover over any ribbon button for a short description.

**Home tab**

- **File**: Open, Save As (PNG, JPEG, BMP, GIF, TIFF, PDF), Copy, Print, Share (AirDrop, Mail, Messages and more)
- **Edit**: Undo, Redo, Delete
- **Arrange**: Bring to Front, Send to Back, Forward, Backward
- **Select**: Select Area (a rectangle that limits effects), Select (move and resize annotations), Freehand Selection (cut out a lasso area), Crop
- **Annotate**: Text, Arrow, Line, Rectangle, Ellipse, Rounded Rectangle, Speech Bubble, Numbered Stamp (numbers go up automatically), Cursor Stamp, Symbol Icon
- **Draw**: Pencil, Brush, Marker, Airbrush, Calligraphy, Highlighter
- **Retouch**: Blur Region, Mosaic Region, Fill Bucket, Eraser, Retouch (a brush that softly blurs)
- **Style**: line color, fill color, fill on/off, line width, font size. Changing these restyles the selected object.
- **Options**: which symbol the Symbol Icon places, and the strength of Blur Region and Mosaic Region

**Image tab**

- **Canvas**: Crop, Resize (pixels), Canvas Size
- **Transform**: Rotate left, Rotate right, Flip horizontal, Flip vertical
- **Effects**: Blur, Sharpen, Mosaic, Grayscale, Invert
- **Adjust**: Brightness and contrast, Hue and saturation, Color balance
- **Decorate**: Frame (border), Drop shadow, Watermark (text)

**View tab**: Zoom in, Zoom out, Fit, 100%

### Blurring or editing only part of an image

There are two ways:

1. **Blur Region** (or **Mosaic Region**) in the Retouch group: drag over the area and only that area is blurred or pixelated.
2. **Select Area**, then any effect: pick **Select Area**, drag a rectangle, then go to the **Image** tab and click Blur, Sharpen, Mosaic, Grayscale, Invert, Brightness, Hue / Sat or Balance. The effect applies only inside the rectangle. With no selection, effects apply to the whole image. Press Esc or ⌘D to clear the selection.

Everything is undoable with ⌘Z.

### Design tools

| Tool | What it does |
|---|---|
| **Color Picker** | Full-screen picker with a magnifier. Click to pick. Shows and copies HEX, RGB, HTML (`#rrggbb`), C++ (`0xBBGGRR`), Delphi (`$00BBGGRR`) and Swift. Keeps a history of recent colors |
| **Color Palette** | RGB and HSV sliders with a hex field and swatches you can save (stored between sessions) |
| **Pixel Ruler** | A draggable, resizable ruler in px, inches or cm at several DPI settings. Right-click or double-click to rotate it |
| **Magnifier** | An always-on-top lens that follows the cursor, 2× to 16× zoom |
| **Crosshair** | Full-screen guide lines with live X/Y. Click to lock a point and measure the distance from it. Right-click clears it |
| **Protractor** | Three draggable handles that measure an angle in degrees |
| **Whiteboard** | Draw directly over the desktop with a pen, highlighter or eraser. Esc or Done to exit |

Choosing a tool from the menu while it is open closes it.

---

## 5. Folder layout

```
SnapDesk_App/
  Package.swift          Swift package definition
  build_app.sh           builds the release binary and wraps it into SnapDesk.app
  SnapDesk.app           the built app
  Sources/
    SnapCore/            shared settings, image export, test logging
    CaptureKit/          screen capture and scrolling-capture stitching
    EditorKit/           the image editor and ribbon
    ToolsKit/            color picker, ruler, magnifier and the other design tools
    RecorderKit/         screen recording
    SnapDesk/            the menu-bar app, hotkeys, self-test
```

The accompanying `website/` folder (next to this one) holds a static feature website for SnapDesk. Open `website/index.html` in a browser.

---

## 6. Known limitations

- Hotkeys cannot be remapped yet, and only the color picker has a design-tool hotkey; the other tools are in the menu.
- Capture delay runs before the selection overlay appears, not after you pick an area.
- A region or freehand selection cannot span more than one screen.
- Scrolling capture needs Accessibility permission. Fixed headers and footers can be duplicated, and pages with large blank bands may stitch wrongly.
- On macOS 13 the cursor is not drawn in captures.
- The microphone is recorded as a separate second audio track, not mixed in. Some players only play the first track.
- Full-screen recording uses the main display only. There is no pause.
- Editor effect dialogs use typed values rather than live sliders, so there is no live preview.
- Geometry operations (crop, resize, rotate, flip, frame, shadow, watermark) merge annotations into the image first, so annotations can't be edited afterwards, though the step can be undone.
- Fill Bucket and Eraser change the image directly; the eraser paints white, not transparent.
- The app is ad-hoc signed and not notarised.
- Screen capture, recording and the screen overlays were verified only by building and reading the code, not by automated tests, because they need Screen Recording permission.
