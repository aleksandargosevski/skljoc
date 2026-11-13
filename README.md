# Škljoc

A menu bar screenshot and screen recording app for macOS, in the spirit of CleanShot. Every screenshot and recording stays on screen as a floating preview with **Copy**, **Save**, **Upload**, **Edit** and **Close**.

- The image editor has crop, rectangle, oval, line, arrow, text, redact and spotlight.
- The video editor trims, changes the resolution and volume, and redacts with keyframes.
- You can drag the result straight into any app.

Requirements: macOS 15 or later on Apple silicon.

## Install

```sh
brew tap aleksandargosevski/tap
brew install skljoc
brew services start skljoc
```

Then:

1. Allow Škljoc under **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. Turn off the macOS shortcuts under **Keyboard → Keyboard Shortcuts → Screenshots**, so ⌘⇧3, ⌘⇧4 and ⌘⇧5 reach Škljoc. Do the same in CleanShot if you have it.

The app is not notarized. If macOS blocks it, use **Open Anyway** in Privacy & Security, or run `xattr -d com.apple.quarantine` on the app.

### From source

```sh
./scripts/create-cert.sh   # once: creates the "Skljoc Dev" signing certificate
./scripts/install.sh       # builds and installs into ~/Applications
```

A stable signing certificate keeps the Screen Recording permission across rebuilds.

## Usage

| Shortcut | Action |
|---|---|
| ⌘⇧4 | Capture an area. Press Space to pick a window instead. |
| ⌘⇧3 | Capture the screen the pointer is on |
| ⌘⇧2 | Capture text: pick an area, its text goes to the clipboard |
| ⌘⇧1 | Capture & Pin: the screenshot floats above all windows |
| ⌘⇧6 | Scrolling capture: one long screenshot of a page |
| ⌘⇧5 | Record the screen. Press it again to stop. |
| ⌘⇧H (menu) | History |

You can change all of them in Settings, and give History a global shortcut there too. ⌘⇧H is Finder's Home folder, so Škljoc leaves it alone by default.

### Capture text

Text is recognized on your Mac with Apple's Vision. Lines and paragraphs are kept. You can also choose **Copy Text** from a preview's right-click menu or in the editor.

### Pin

**Pin** in the preview, or ⌘⇧1, keeps a screenshot on top of every window.

- Drag it to move it. Drag an edge or pinch to resize it.
- Scroll over it to change the opacity.
- Double-click to edit it. Esc or ✕ closes it.

### Scrolling capture

Select the part of the window that scrolls and press **Start**. With **Auto-scroll** on (it needs Accessibility permission), Škljoc scrolls to the end by itself. Otherwise, scroll slowly by hand and press ↩ when done.

Frames are stitched as you go, and sticky headers and footers show up only once. Pages with animations or content that loads late can confuse the stitching.

### History

History shows every screenshot and recording, newest first, with Space for Quick Look and a search over the text in them.

- Open it with ⌘⇧H in the menu, or **Recent → Show All…**.
- Settings → History sets how long items are kept (30 days by default), shows the space they use and can clear them.

### Upload

**Upload** puts the screenshot or recording on your own Cloudflare Worker and copies the link. Nothing goes to anyone else's server.

- Option-click Upload, or right-click → **Upload with Options…**, to make the link private, password-protected, expiring or one-time.
- **Upload Files** (⌥⇧⌘U) opens a drop zone. Drop any files there, or use **Choose Files…**, and their links go to the clipboard. Folders are zipped first.
- **Shorten Link in Clipboard** (⌥⇧⌘L) turns a copied link into a short one on your domain. **Shorten Link…** (⌃⌥⇧⌘L) lets you pick its name, like `share.example.com/cv`.
- Option-click Upload (or use the drop zone's options) to pick a name for the link, like `share.example.com/offer`. Leave it empty for a random one.
- **Uploads…** in the menu lists your files and short links. Rename a link there, or change where a short link goes. It also lists everything you uploaded, with views, and lets you copy links, change options or delete.
- Uploading the same version twice reuses the link.
- Set it up once in **Settings → Upload → Set Up Worker**. Škljoc creates everything on your Cloudflare account with an API token; [more options](worker/README.md).
- On another Mac: **Copy Token** in Settings → Upload, then enter the same address and token there. Uploads and links are shared; History stays per Mac.

### Recording

⌘⇧5 (or **Record Screen** / **Record GIF** in the menu) dims the screen so you can pick the area.

Picking the area:

- Drag to select an area.
- Click to select a window.
- Press Space or double-click to select the whole screen.
- Type the size in pixels, or pick a preset (16:9, 1080p, vertical, …).
- Škljoc remembers the last area.

The bar under the area has:

- Video or GIF.
- Camera: a draggable bubble. Use the arrow next to it to pick the camera, size and shape.
- Microphone and Mac sound, each recorded as a separate track.
- Highlight clicks.
- Show keystrokes. This needs Accessibility permission.

Press ↩ or **Record** to start after a 3-2-1 countdown. Click the red menu bar timer to stop. Right-click it to pause or cancel.

### Video editor

- Drag the yellow handles to trim. Space plays, ←/→ step a frame, and ⇧←/→ step a second.
- **Redact**: pause, then drag over the video to cover something with pixelate, blur or solid.
  - A new redaction covers the whole video, so nothing slips through before the moment you drew it. Drag the ends of its bar in the timeline to set when it shows.
  - Move the area at another moment to add a keyframe. The area glides between keyframes.
  - Click a ◆ to jump to that keyframe. ⌫ deletes the selected keyframe, or the whole redaction.
- Below the timeline you set the export format (MP4 or GIF), the resolution, and the volume of Mac sound and the microphone. Each can also be muted.
- GIFs are made from the recording when exported, so a GIF can still be trimmed or exported as an MP4.

### Preview

Hover over a preview to see its actions.

- **Copy** and **Save** close the preview. Option-click Save (or right-click → Save As…) to choose where the file goes.
- **Edit** opens the editor. **Done** brings the edited screenshot back to the preview, with every object still editable.
- Drag the preview into Slack, Finder, mail and other apps.
- While the pointer is over a preview, its shortcuts work (the preview never takes focus, so they don't get in the way otherwise):

| Key | Action |
| --- | --- |
| ⌘C · ⇧⌘C | Copy · Copy Text |
| ⌘S · ⇧⌘S | Save · Save As… |
| ⌘U · ⌥⌘U | Upload · Upload with Options… |
| ⌘E | Edit |
| ⌘P | Pin |
| Esc · ⌘W | Close |
- **Recent** in the menu bar reopens the last 10 screenshots.

### Editor

| Key | Tool |
|---|---|
| C | Crop: Enter applies, Esc cancels, ⇧ keeps the aspect ratio |
| R | Rectangle |
| O | Oval |
| L | Line |
| A | Arrow |
| T | Text: Enter finishes, double-click edits again |
| N | Step numbers: they renumber themselves, and dragging adds an arrow |
| H | Highlighter: a translucent marker; hold ⌥ to draw freehand |
| X | Redact: pixelate, blur or solid (solid is the safest) |
| S | Spotlight: dims everything outside the marked areas |
| B | Background: gradient or color, padding, rounded corners, shadow and size (16:9, 4:3, 1:1). The last style is remembered. |

- Click an object to select it. Then you can move it, resize it with the handles, nudge it with the arrow keys or delete it with ⌫.
- Hold ⇧ while drawing for squares, circles and 45° lines. Hold ⌥ for filled shapes.
- Space + drag pans. ⌘+ / ⌘− / ⌘0 zoom.
- ⌘Z and ⇧⌘Z undo and redo. The editors use the preview's keys: ⌘C copies, ⇧⌘C copies the text, ⌘S saves, ⇧⌘S saves as, ⌘U uploads, ⌥⌘U uploads with options, ⌘P pins, and ⌘W returns to the preview.
- Edits are saved with each screenshot and recording, so they survive a restart.
- Use **Drag** at the bottom to drop the edited image into another app.

## Development

```sh
./scripts/build.sh --run   # build, sign and restart
./scripts/test.sh          # unit tests (works with Command Line Tools only)
```

- `Sources/SkljocCore` holds the logic that has no UI and is unit tested: annotations, geometry, the document and undo history, shortcuts and file names.
- `Sources/Skljoc` is the AppKit/SwiftUI app.
- Screenshots are taken with the system `screencapture` tool and kept in `~/Library/Caches/io.github.aleksandargosevski.skljoc/Captures`.

Releases: push a `v1.2.3` tag. The workflow builds and signs the app, creates a GitHub release and updates the Homebrew formula. It needs the `SKLJOC_CERT_P12_BASE64`, `SKLJOC_CERT_PASSWORD` and `HOMEBREW_TAP_TOKEN` secrets.

## Roadmap

- Use the recording area picker for screenshots too, with a magnifier and Capture Previous Area
- Camera as its own track that can be moved in the editor
- Automatic tracking for redactions (Vision)
