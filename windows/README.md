# EditRush for Windows

Windows port of EditRush (the macOS app in `Sources/`). Same features, same `.editrush` project
format, same keyboard shortcuts with Ctrl in place of Cmd.

Built with Electron (UI, preview and compositing in an HTML canvas, sound through Web Audio) and
ffmpeg (probing, thumbnails, waveforms, audio decoding, and export).

## Requirements

- Windows 10/11 x64
- Node.js (for building only)
- ffmpeg and ffprobe: copy `ffmpeg.exe`, `ffprobe.exe` and `LICENSE` from the gyan.dev release
  "essentials" build (7.1 or later, needed for HEIC) into `windows\ffmpeg\`. That folder is not in
  git; `npm run package` bundles it into the app. Without it, ffmpeg on `PATH` is used.

## Run, test, package

```powershell
cd windows
npm install
npm start                 # run from source
npm test                  # unit tests for the editing core
npm run package           # builds dist\EditRush-win32-x64\EditRush.exe
.\scripts\make_fixtures.ps1   # generates test media into ..\Fixtures
```

`EditRush.exe <file>` opens a `.editrush` project or imports media files.

## Where things are

| Folder | Contents | macOS equivalent |
| --- | --- | --- |
| `src/core` | Project model, editing rules, store (undo, autosave, save/open) | `EditRushCore/Model`, `Store` |
| `src/media` | ffprobe import, thumbnails / waveforms / audio cache | `EditRushCore/Media` |
| `src/engine` | Compositor, colour filters, titles, audio mix, preview playback, exporter | `EditRushCore/Engine` |
| `src/ui` | Window, media bin, preview, inspector, timeline, export dialog | `EditRush/UI`, `EditRush/App` |
| `main.js` | Electron main process: window, menu, dialogs | `EditRushApp.swift` |

Autosave: `%APPDATA%\EditRush\Autosave.editrush`.

## Differences from the macOS version

- Colour filters are approximations of the Core Image presets (same names, similar looks).
- Export renders each frame with the same compositor as the preview and encodes with ffmpeg
  (libx264 / libx265). It runs at roughly real time at 1080p.
- Minimum timeline zoom is 0.5 px/s (macOS: 5) so Zoom to Fit can show long recordings.
- Default title font is Segoe UI. Projects from the Mac keep their font names; a font that is not
  installed falls back to Segoe UI.
- Media paths in projects saved on the Mac do not exist on Windows; those files show as Missing
  and can be relinked (right-click > Locate File...).
- No installer and no `.editrush` file association yet; `npm run package` makes a portable folder.
