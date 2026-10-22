# EditRush

**[⬇ Download EditRush for Mac](https://github.com/ce-plai/EditRush/releases/latest/download/EditRush.dmg)**
(macOS 15 or later, Apple Silicon and Intel). Open the DMG and drag EditRush to Applications.
It updates itself when new versions come out.

EditRush is a lightweight native macOS video editor, similar to Premiere Rush or CapCut. It
does the everyday jobs well: cut clips together on a multi-track timeline, add titles, fades,
transforms and colour adjustments, and export an MP4 or MOV. It launches instantly, plays and
scrubs smoothly, and saves your work continuously.

No log-ins and no cloud features: your projects and media stay on your Mac. The only thing it
fetches from the internet is the update check.

Built with Swift, SwiftUI + AppKit, AVFoundation and Core Image on Metal. Requires macOS 15
or later (Apple Silicon recommended).

## Build & install

```sh
Scripts/build_app.sh            # release build → build/EditRush.app
cp -R build/EditRush.app /Applications/
```

`Scripts/build_app.sh debug` builds a debug bundle instead. To work on the code directly:

```sh
swift build                     # debug build
swift test                      # unit tests (run Scripts/make_fixtures.sh first; needs ffmpeg)
.build/debug/EditRush           # run without bundling
```

The app icon is generated from the logo in `Resources/Logo.svg` by `swift Scripts/make_icon.swift`
(writes `Resources/AppIcon.icns`; pass a second path to also save a 1024 px PNG preview).

## Features

- **Import** MP4, MOV, MP3, WAV, OGG (Vorbis / Opus), PNG and JPG — via the Import button,
  ⌘I, dragging files from Finder anywhere onto the window, or opening them on the Dock icon.
- **Media bin** with poster frames, audio waveforms, duration badges, a kind filter
  (All / Video / Audio / Images), missing-file detection and relinking (right-click → Locate File…).
  Double-click an item (or use its **+** button) to append it to the main track after the playhead
  (the playhead moves to its end, so repeated adds build a sequence), or drag it to any track.
  If a missing file comes back (e.g. you reconnect the drive), its thumbnails and the preview
  reload when you switch back to EditRush.
- **Multi-track timeline**: video / overlay tracks and audio tracks, snapping, zoom, split and join,
  ripple delete, close gaps, nudge, duplicate, cut / copy / paste, detach audio.
- **Transitions**: fade up from black and fade to black, per clip.
- **Transform**: scale and move clips on the canvas.
- **Titles**: text layers with font, size, colour and placement.
- **Colour**: per-clip brightness, contrast, saturation and filters.
- **Export** at 720p, 1080p, 4K or project size, H.264 or HEVC, MP4 or MOV, with progress,
  time remaining and cancel. You can hide the export sheet and keep editing; the toolbar's
  Export button shows progress. Quitting or closing the window during an export asks first
  (Keep Exporting / Stop Export and Quit); a stopped or failed export never replaces an
  existing file.
- **Undo / redo** for every edit (the last 1000 steps).

## Keyboard shortcuts

Single-key shortcuts are ignored while you are typing in a text field, so you can type freely
in the inspector and the project name.

### File

| Action | Shortcut |
| --- | --- |
| New Project | ⌘N |
| Open… | ⌘O |
| Save | ⌘S |
| Save As… | ⇧⌘S |
| Import Media… | ⌘I |
| Export… | ⌘E |

### Edit

| Action | Shortcut |
| --- | --- |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V |
| Duplicate | ⌘D |
| Delete | ⌫ |
| Ripple Delete | ⇧⌫ |
| Select All | ⌘A |

### Clip

| Action | Shortcut |
| --- | --- |
| Split at Playhead | ⌘B or S |
| Join Clips | ⌘J |
| Add Title | ⌘T |
| Close Gaps, Detach Audio, Fade In 1s, Fade Out 1s, Remove Fades | Clip menu |

### View

| Action | Shortcut |
| --- | --- |
| Zoom In / Out | ⌘= / ⌘− |
| Zoom to Fit | ⇧Z |
| Toggle Snapping | N |

### Playback

| Action | Shortcut |
| --- | --- |
| Play / Pause | Space |
| Previous / Next Frame | ← / → |
| Back / Forward 1 Second | ⇧← / ⇧→ |
| Go to Start | Home or ↑ |
| Go to End | End or ↓ |
| Back 1 Second / Pause / Play (J K L) | J / K / L |
| Nudge Selection Left / Right 1 Frame | , / . |
| Nudge Selection Left / Right 10 Frames | ⇧, / ⇧. |

## Projects & autosave

- A project is a single `.editrush` file (JSON). It references your media files where they
  are on disk; nothing is copied. If you move a file, the bin marks it **Missing** and you can
  relink it from the item's context menu.
- EditRush saves continuously: 1.5 s after each change the project is written to
  `~/Library/Application Support/EditRush/Autosave.editrush` and, if the project has been
  saved to a file, to that file too. Save errors appear as a message at the bottom of the window.
- On launch, EditRush reopens the last session from the autosave, so quitting never loses work.
  Pending changes are flushed when you quit.
- Use **Save As…** (⇧⌘S) to give a project its own file. New Project and Open ask before
  discarding work that has never been saved to a file.
- A saved project is named after its file: renaming it (toolbar title or inspector) renames the
  `.editrush` file in the same folder. If a file with that name already exists there, the
  rename is refused and the old name stays.
- Double-clicking a `.editrush` file in Finder opens it in EditRush. Media files dropped on the
  Dock icon are imported into the current project.

## Scripts and AI agents

Project files are plain JSON, so a script or agent can build an edit by writing one. The app
binary has command-line modes to probe media, validate a project, render a frame and export,
all without opening a window:

```sh
EditRush.app/Contents/MacOS/EditRush --probe clip.mov            # media entry for the project
EditRush.app/Contents/MacOS/EditRush --validate edit.editrush
EditRush.app/Contents/MacOS/EditRush --frame f.png --project edit.editrush --at 5
EditRush.app/Contents/MacOS/EditRush --export out.mp4 --project edit.editrush
```

The open project's file is watched, so an agent can edit it while you work: its changes appear
live as one undoable step and are merged with any edits of yours not yet saved.
[docs/project-format.md](docs/project-format.md) describes the file format, every option, and how
to edit alongside the app.

## Development notes

`EditRush --snapshot out.png [--demo Fixtures] [--select-first] [--playhead 2] [--size 1600x1000]
[--wait 2] [--select-media 0] [--bin-add 0,1] [--status "message"] [--export-sheet]` renders the main window
(or the export sheet) offscreen to a PNG for UI checks without opening a window.
