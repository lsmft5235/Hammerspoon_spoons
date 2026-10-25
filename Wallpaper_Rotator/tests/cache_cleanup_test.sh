#!/bin/sh
set -eu
script="$(pwd)/Wallpaper_Rotator/WallpaperRotator.spoon/cache_cleanup.sh"
work=$(/usr/bin/mktemp -d -t wallpaper-cache-test)
cleanup() {
    chmod u+rwx "$work/container" "$work/container/blocked" 2>/dev/null || :
    chmod u+rwx "$work/darwin/other" "$work/darwin/com.apple.wallpaper.test/blocked" 2>/dev/null || :
    /usr/bin/find "$work" -type f -delete
    /usr/bin/find "$work" -type l -delete
    /usr/bin/find "$work" -depth -type d -exec /bin/rmdir {} \;
}
trap cleanup EXIT
mkdir -p "$work/container" "$work/darwin/com.apple.wallpaper.test/nested" "$work/darwin/other" "$work/outside"
mkdir -p "$work/darwin/com.apple.wallpaper.second"
printf '1234' > "$work/container/a.BMP"
printf '123456' > "$work/darwin/com.apple.wallpaper.test/nested/image with spaces.bmp"
printf '123' > "$work/darwin/com.apple.wallpaper.second/second.bmp"
printf 'keep' > "$work/container/keep.jpg"
printf 'keep' > "$work/darwin/other/keep.bmp"
printf 'keep' > "$work/outside/keep.bmp"
ln -s "$work/outside/keep.bmp" "$work/container/link.bmp"
ln -s "$work/outside" "$work/container/linked-directory"
ln -s "$work/outside" "$work/darwin/com.apple.wallpaper.link"
printf 'keep' > "$work/darwin/com.apple.wallpaper.file"

output=$(/bin/sh "$script" "$work/container" "$work/darwin")
printf '%s\n' "$output"
test ! -e "$work/container/a.BMP"
test ! -e "$work/darwin/com.apple.wallpaper.test/nested/image with spaces.bmp"
test ! -e "$work/darwin/com.apple.wallpaper.second/second.bmp"
test -f "$work/container/keep.jpg"
test -f "$work/darwin/other/keep.bmp"
test -f "$work/outside/keep.bmp"
test -L "$work/container/link.bmp"
test -L "$work/darwin/com.apple.wallpaper.link"
test -f "$work/darwin/com.apple.wallpaper.file"
printf '%s\n' "$output" | grep -q 'remove 1 BMP files / 4 bytes'
printf '%s\n' "$output" | grep -q 'remove 2 BMP files / 9 bytes'
printf '%s\n' "$output" | grep -q 'remaining 0 BMP files / 0 bytes'

output=$(/bin/sh "$script" "$work/missing" "$work/darwin")
printf '%s\n' "$output" | grep -q 'Missing cache location'
if /bin/sh "$script" "$work/container/link.bmp" "$work/darwin" > "$work/output" 2> "$work/error"; then
    printf 'ERROR: symlink root was accepted\n' >&2
    exit 1
fi
grep -q 'Unsafe or inaccessible' "$work/error"
if /bin/sh "$script" --batch remove "$work/missing.bmp" > "$work/output" 2> "$work/error"; then
    printf 'ERROR: missing batch file was reported as success\n' >&2
    exit 1
fi
grep -q 'disappeared or changed type' "$work/error"
output=$(/bin/sh "$script" "$work/container" "$work/outside" 2> "$work/error")
test ! -s "$work/error"
printf '%s\n' "$output" | grep -q 'remove 0 BMP files / 0 bytes'
test -f "$work/outside/keep.bmp"
if [ "$(/usr/bin/id -u)" != "0" ]; then
    chmod 000 "$work/darwin/other"
    output=$(/bin/sh "$script" "$work/container" "$work/darwin" 2> "$work/error")
    test ! -s "$work/error"
    chmod 700 "$work/darwin/other"
    test -f "$work/darwin/other/keep.bmp"
    mkdir "$work/darwin/com.apple.wallpaper.test/blocked"
    printf 'keep' > "$work/darwin/com.apple.wallpaper.test/blocked/active.bmp"
    chmod 000 "$work/darwin/com.apple.wallpaper.test/blocked"
    if /bin/sh "$script" "$work/container" "$work/darwin" > "$work/output" 2> "$work/error"; then
        printf 'ERROR: inaccessible wallpaper subtree was reported as success\n' >&2
        exit 1
    fi
    chmod 700 "$work/darwin/com.apple.wallpaper.test/blocked"
    test -f "$work/darwin/com.apple.wallpaper.test/blocked/active.bmp"
    grep -qi 'permission denied' "$work/error"
    mkdir "$work/container/blocked"
    printf 'keep' > "$work/container/blocked/active.bmp"
    chmod 000 "$work/container/blocked"
    if /bin/sh "$script" "$work/container" "$work/darwin" > "$work/output" 2> "$work/error"; then
        printf 'ERROR: inaccessible subtree was reported as success\n' >&2
        exit 1
    fi
    chmod 700 "$work/container/blocked"
    test -f "$work/container/blocked/active.bmp"
    grep -qi 'permission denied' "$work/error"
    printf 'keep' > "$work/container/cannot-delete.bmp"
    chmod 500 "$work/container"
    if /bin/sh "$script" "$work/container" "$work/darwin" > "$work/output" 2> "$work/error"; then
        printf 'ERROR: deletion failure was reported as success\n' >&2
        exit 1
    fi
    chmod 700 "$work/container"
    test -f "$work/container/cannot-delete.bmp"
    grep -qi 'permission denied' "$work/error"
fi
printf 'PASS cache scope, measurements, spaces in filenames, symlinks, missing roots and failures\n'
