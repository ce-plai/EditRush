# EditRush project format and command line

An EditRush project is a single `.editrush` file of JSON. Anything an edit consists of is in it:
canvas, media, tracks, clips and every clip property. So a script or AI agent can build or change
an edit by writing the file, then check, preview and export it with the command-line modes below.

## Command line

Run the binary inside the app bundle:

```sh
EDITRUSH=/Applications/EditRush.app/Contents/MacOS/EditRush   # or .build/debug/EditRush
```

| Command | What it does |
|---|---|
| `$EDITRUSH --probe a.mov b.wav logo.png` | Prints a JSON array of `media` entries (with new ids) ready to paste into a project. |
| `$EDITRUSH --validate edit.editrush` | Checks the file; prints each issue and an `OK` / `INVALID` summary line. |
| `$EDITRUSH --frame out.png --project edit.editrush --at 12.5 [--max-size 1280x720]` | Renders the video frame at a time to a PNG, at canvas size unless `--max-size`. |
| `$EDITRUSH --export out.mp4 --project edit.editrush [--resolution 720p\|1080p\|4k\|project] [--codec h264\|hevc]` | Exports the movie. Container from the extension (`.mp4` / `.mov`). Defaults: 1080p, H.264. |
| `$EDITRUSH --snapshot out.png --project edit.editrush [--playhead 12.5]` | Screenshot of the whole editor window showing the project. |

Results go to stdout; issues and export progress go to stderr. Every mode exits 0 on success and
1 on failure. `--frame` and `--export` refuse a project with validation errors and print its
warnings. None of these open a window or touch the running app.

A typical loop: `--probe` the media → write the project → `--validate` → fix errors → `--frame`
at a few times to look at the result → `--export`.

## Working alongside the app

An agent can edit a project while someone has it open in EditRush:

- The app watches the open project's file. A change shows up in the editor within about a quarter
  of a second, as one undo step ("Undo Outside Change"), so the person can undo an agent's edit.
  Changes made while the app was closed load when it next opens the project.
- The app saves the person's own edits to the file about 1.5 s after they make them. If the file
  changes before that, the two are merged per clip, track and media item. Where both changed the
  same clip, the person's version wins. If the edits can't be combined (e.g. both put a clip in the
  same spot), the file's version loads and the person can get theirs back with Undo.
- **So the file also changes under the agent.** Re-read it right before each change and write it
  straight back (one quick read–modify–write), rather than writing out a copy read earlier, which
  would undo the person's recent edits.
- A file that can't be read or has validation errors isn't loaded, and the app won't save over
  it. It shows a message and waits for a fixed version. Writing to a temporary file and renaming it
  over the project avoids the app ever seeing a half-written file.
- The app writes the file back pretty-printed with sorted keys and every field filled in, so expect
  the formatting to change after the person edits.

## Example

```json
{
  "canvas": { "width": 1920, "height": 1080, "frameRate": 30 },
  "media": [
    { "id": "00000000-0000-0000-0000-000000000001", "url": "footage/interview.mov", "kind": "video",
      "duration": 42.5, "pixelWidth": 1920, "pixelHeight": 1080, "frameRate": 29.97, "hasAudio": true },
    { "id": "00000000-0000-0000-0000-000000000002", "url": "music.mp3", "kind": "audio",
      "duration": 180, "hasAudio": true }
  ],
  "tracks": [
    { "kind": "video", "clips": [
      { "mediaID": "00000000-0000-0000-0000-000000000001", "start": 0, "duration": 8, "sourceIn": 3, "fadeIn": 0.5 }
    ]},
    { "kind": "video", "clips": [
      { "text": { "text": "Episode 1", "fontSize": 0.08 }, "start": 1, "duration": 3,
        "transform": { "offsetY": 0.35 }, "fadeIn": 0.3, "fadeOut": 0.3 }
    ]},
    { "kind": "audio", "clips": [
      { "mediaID": "00000000-0000-0000-0000-000000000002", "start": 0, "duration": 8, "volume": 0.4, "fadeOut": 2 }
    ]}
  ]
}
```

Any field with a default can be left out. The required ones are marked below.

## Conventions

- **Times** are seconds (decimals). They are snapped to the canvas frame grid on load, so use
  multiples of `1 / frameRate` to avoid surprises.
- **Tracks.** Video tracks hold video, image and text clips; audio tracks hold audio clips only.
  Video tracks are layered in array order: the first video track is the bottom layer. Audio and
  video tracks can be mixed in the array.
- **No overlaps.** Clips on one track must not overlap. To show two things at once, put them on
  different tracks.
- **A video clip plays its own sound** (controlled by its `volume` / `audioMuted`). There's no need
  to add the same file to an audio track.
- **Canvas space.** `offsetX` / `offsetY` move a clip's centre by a fraction of the canvas width /
  height from the canvas centre; +x is right, **+y is down**. `(0.5, 0)` centres it on the right edge.
- **Fades** go to and from black on the bottom layer, and dissolve to the layers below on upper ones.
- **Ids** are UUIDs. Clip and track ids are generated if left out; media ids are required, since
  clips refer to them.

## Reference

### Project

| Field | Default | Notes |
|---|---|---|
| `tracks` | **required** | Array of tracks (may be empty). |
| `canvas` | 1920×1080, 30 fps | See Canvas. |
| `media` | `[]` | Media files the clips use. |
| `version` | 1 | File format version. |

The project name is taken from the file name.

### Canvas

| Field | Default | Notes |
|---|---|---|
| `width`, `height` | 1920, 1080 | Pixels; use even numbers. |
| `frameRate` | 30 | 1…240. |
| `backgroundColor` | black | RGBA, shown where no clip covers the canvas. |

### Media

Get these from `--probe`, which reads the real values from the file.

| Field | Default | Notes |
|---|---|---|
| `id` | **required** | UUID that clips refer to. |
| `url` | **required** | `file://` URL, absolute path, `~/` path, or a path relative to the project file's folder. |
| `kind` | **required** | `video`, `audio` or `image`. |
| `duration` | 0 | Seconds. **Required in practice** for video and audio (0 for images). |
| `pixelWidth`, `pixelHeight` | 0 | Display size after rotation. **Required in practice** for video and images. |
| `frameRate` | 0 | Video only. |
| `hasAudio` | false | True if a video file has sound; always true for audio. |
| `name` | file name | Shown in the media bin. |

### Track

| Field | Default | Notes |
|---|---|---|
| `kind` | **required** | `video` or `audio`. |
| `clips` | `[]` | Sorted by `start` on load. |
| `isMuted` | false | |
| `isHidden` | false | Hidden video tracks are not rendered. |
| `isLocked` | false | Locks the track against edits in the app. |
| `id` | generated | |

### Clip

A clip has either a `mediaID` (video / audio / image) or a `text` style (title), not both.

| Field | Default | Valid range / notes |
|---|---|---|
| `start` | **required** | Timeline position, ≥ 0. |
| `duration` | **required** | Timeline length, ≥ 1 frame. For video / audio it is cut to what the media has left after `sourceIn`. |
| `mediaID` | – | A `media` id. |
| `text` | – | Text style; makes this a title clip. |
| `sourceIn` | 0 | Seconds into the source where the clip starts (video / audio only). |
| `transform` | identity | See Transform. |
| `color` | identity | See Colour. |
| `filter` | `none` | `none vivid warm cool mono noir sepia chrome fade instant process tonal transfer blur sharpen comic` |
| `filterIntensity` | 1 | 0…1 mix of the filter. |
| `fadeIn`, `fadeOut` | 0 | Seconds; together at most `duration`. |
| `volume` | 1 | 0…2 linear gain. |
| `audioMuted` | false | |
| `label` | – | Shown on the timeline instead of the media name. |
| `id` | generated | |

### Transform

| Field | Default | Valid range / notes |
|---|---|---|
| `scale` | 1 | 0.02…20. 1 = fitted to the canvas (per `fitMode`); for text, the natural text size. |
| `offsetX`, `offsetY` | 0 | Fraction of canvas width / height; +y is down. |
| `rotation` | 0 | Degrees, clockwise. |
| `opacity` | 1 | 0…1. |
| `flipHorizontal`, `flipVertical` | false | |
| `fitMode` | `fit` | `fit` (letterbox) or `fill` (crop to cover). |

### Colour

| Field | Default | Valid range |
|---|---|---|
| `exposure` | 0 | −2…2 stops. |
| `brightness` | 0 | −1…1 (about ±0.5 is the useful range). |
| `contrast` | 1 | 0.25…2. |
| `saturation` | 1 | 0…2 (0 = greyscale). |
| `temperature` | 0 | −1 (cooler) … 1 (warmer). |
| `vignette` | 0 | 0…1. |

### Text

| Field | Default | Notes |
|---|---|---|
| `text` | `"Title"` | Use `\n` for line breaks. |
| `fontFamily` | `"Helvetica Neue"` | Any installed font family. |
| `isBold`, `isItalic` | true, false | |
| `fontSize` | 0.1 | Fraction of canvas height, 0.01…0.6 (0.1 on 1080p = 108 px). |
| `color` | white | RGBA. |
| `backgroundColor` | clear | RGBA box behind the text; alpha 0 = none. |
| `alignment` | `center` | `left`, `center`, `right`. |
| `shadow` | true | |
| `outlineWidth` | 0 | Fraction of font size, 0…1. |
| `outlineColor` | black | RGBA. |

### RGBA

`{ "r": 1, "g": 0.8, "b": 0, "a": 1 }`. Components are 0…1 sRGB; `a` defaults to 1.

## Validation

`--validate` (and `--frame` / `--export` before rendering) reports:

- **Errors**, which stop `--frame` / `--export`: overlapping clips on a track, a `mediaID` that isn't
  in `media`, a clip on the wrong kind of track, a clip with neither or both of `mediaID` and `text`,
  missing media files, media without a duration or pixel size, duplicate ids, and a bad canvas.
- **Warnings**, for values that are adjusted on load: properties outside their valid range, times
  off the frame grid, fades longer than the clip, and clips that run past the end of their media.
  Each warning lists the changes, e.g. `adjusted on load: duration 10 → 4`.

The app applies the same adjustments when it opens a file. It still opens files with errors so you
can fix them by hand, but they may not play or export correctly.
