EditRush for Windows - test build
=================================

A Windows port of EditRush (the macOS video editor). Same features, the same
.editrush project format, and the same keyboard shortcuts with Ctrl in place
of Cmd.

Running it
----------
1. Unzip the whole folder anywhere (e.g. Desktop). Keep all files together.
2. Run EditRush.exe.
   The build is not code-signed, so Windows SmartScreen may say "Windows
   protected your PC". Click "More info", then "Run anyway".
   If Windows blocks it silently: right-click the downloaded .zip >
   Properties > tick "Unblock" > OK, then unzip again.

Nothing is installed. To remove it, delete the folder and
%APPDATA%\EditRush (autosave, recent projects).

Requirements: Windows 10 or 11, 64-bit. ffmpeg is included (ffmpeg folder
inside resources\app); nothing else is needed.

Notes for testing
-----------------
- Projects saved on the Mac open here, but their media paths do not exist on
  Windows: those files show as Missing. Right-click a missing item in the
  media bin > Locate File... to relink it.
- Imports MP4/MOV/M4V video; MP3, WAV, OGG, Opus, M4A, AAC, AIFF, CAF, FLAC
  audio; PNG, JPG, GIF, BMP, WebP, TIFF and HEIC images.
- Export is H.264 or HEVC in MP4 or MOV, at 720p / 1080p / 4K / project size.
  It uses NVIDIA hardware encoding (NVENC) when the PC has an NVIDIA GPU,
  otherwise the CPU. Plain video goes straight through ffmpeg and is fast;
  fades, transforms, colour and filters are drawn frame by frame and are slower.
  The browser console (see below) logs which encoder was used and the timings.
- Colour filter presets approximate the Core Image looks on the Mac;
  titles are drawn by the browser engine, so spacing can differ slightly.
- Developer tools: View > Toggle Developer Tools (Ctrl+Shift+I). Errors are
  written to its Console tab.

Licences
--------
EditRush is built on Electron (MIT licence, see LICENSE and
LICENSES.chromium.html in this folder).
The bundled ffmpeg is the gyan.dev 9.0.2 "essentials" build, licensed under
the GNU GPL v3 (see resources\app\ffmpeg\LICENSE). Source code:
https://ffmpeg.org/download.html and https://www.gyan.dev/ffmpeg/builds/
