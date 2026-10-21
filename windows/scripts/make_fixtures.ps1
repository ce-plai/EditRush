# Generates deterministic test media into <repo>\Fixtures (requires ffmpeg on PATH).
# Windows version of Scripts/make_fixtures.sh.
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $root 'Fixtures'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
    # Options containing ':' are quoted: PowerShell would split -c:v into -c: and v.
    function F { & ffmpeg -loglevel error -y @args; if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed: $args" } }
    # Videos with audio
    F -f lavfi -i 'testsrc2=size=1920x1080:rate=30:duration=6' -f lavfi -i 'sine=frequency=440:duration=6' '-c:v' libx264 -pix_fmt yuv420p '-c:a' aac -shortest clip_a.mp4
    F -f lavfi -i 'smptehdbars=size=1280x720:rate=30:duration=5' -f lavfi -i 'sine=frequency=660:duration=5' '-c:v' libx264 -pix_fmt yuv420p '-c:a' aac -shortest clip_b.mov
    # Portrait phone-style video: encoded landscape 1280x720 with a 90 degree display-matrix rotation (displays 720x1280)
    F -f lavfi -i 'testsrc=size=1280x720:rate=30:duration=4' '-c:v' libx264 -pix_fmt yuv420p _land.mp4
    F -display_rotation 90 -i _land.mp4 -c copy rotated_portrait.mov
    Remove-Item _land.mp4
    # Solid colours for pixel-exact engine tests (no audio)
    F -f lavfi -i 'color=c=red:size=640x360:rate=30:duration=3' '-c:v' libx264 -pix_fmt yuv420p -x264-params keyint=1 solid_red.mp4
    F -f lavfi -i 'color=c=blue:size=640x360:rate=30:duration=3' '-c:v' libx264 -pix_fmt yuv420p -x264-params keyint=1 solid_blue.mov
    F -f lavfi -i 'color=c=0x00FF00:size=400x400' '-frames:v' 1 solid_green.png
    F -f lavfi -i 'color=c=white:size=800x600' '-frames:v' 1 '-q:v' 2 solid_white.jpg
    # Photo + transparent PNG logo
    F -f lavfi -i 'testsrc2=size=4000x3000' '-frames:v' 1 '-q:v' 3 photo.jpg
    F -f lavfi -i "color=c=black@0.0:size=512x512,format=rgba,geq=r='255':g='200':b='0':a='if(lt(hypot(X-256,Y-256),200),255,0)'" '-frames:v' 1 logo.png
    # Audio in every supported format
    F -f lavfi -i 'sine=frequency=330:duration=10' -ac 2 '-c:a' libmp3lame '-q:a' 4 music.mp3
    F -f lavfi -i 'sine=frequency=550:duration=4' -ac 2 tone.wav
    F -f lavfi -i 'sine=frequency=880:duration=3' -ac 2 '-c:a' vorbis -strict -2 voice.ogg
    F -f lavfi -i 'sine=frequency=990:duration=3' '-c:a' libopus opus.ogg
    Get-ChildItem | Format-Table Name, Length
} finally {
    Pop-Location
}
