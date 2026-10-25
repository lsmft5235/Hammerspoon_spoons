#!/bin/sh

# Batch mode receives only regular BMPs selected by find, without following symlinks.
if [ "$1" = "--batch" ]; then
    action=$2
    shift 2
    result=0
    for file do
        if [ -L "$file" ] || [ ! -f "$file" ]; then
            printf 'Cache file disappeared or changed type: %s\n' "$file" >&2
            result=1
            continue
        fi
        if ! bytes=$(/usr/bin/stat -f '%z' "$file"); then
            result=1
            continue
        fi
        if [ "$action" = "remove" ]; then
            if ! /bin/rm "$file"; then
                result=1
                continue
            fi
        fi
        printf '%s\n' "$bytes"
    done
    exit "$result"
fi

# Defer termination until the current foreground scan returns, avoiding orphaned deletion work.
trap 'exit 124' TERM INT HUP

container_dir=$1
if [ -z "$container_dir" ] || [ "$container_dir" = "/" ]; then
    printf 'Missing or invalid container cache directory\n' >&2
    exit 1
fi
result=0
cache_dir=$2
if [ -z "$cache_dir" ]; then
    if ! cache_dir=$(/usr/bin/getconf DARWIN_USER_CACHE_DIR); then
        printf 'Could not resolve DARWIN_USER_CACHE_DIR\n' >&2
        exit 1
    fi
fi
if [ -z "$cache_dir" ] || [ "$cache_dir" = "/" ]; then
    printf 'Invalid DARWIN_USER_CACHE_DIR\n' >&2
    exit 1
fi

scan() {
    root=$1
    scope=$2
    action=$3
    # A missing child can also mean its parent is inaccessible.
    if [ ! -e "$root" ] && [ ! -L "$root" ]; then
        parent=$(/usr/bin/dirname "$root")
        while [ ! -e "$parent" ] && [ "$parent" != "/" ]; do
            parent=$(/usr/bin/dirname "$parent")
        done
        if [ ! -r "$parent" ] || [ ! -x "$parent" ]; then
            printf 'Cache location inaccessible: %s\n' "$root" >&2
            return 1
        fi
        printf 'Missing cache location: %s\n' "$root"
        return 0
    fi
    if [ -L "$root" ] || [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; then
        printf 'Unsafe or inaccessible cache directory: %s\n' "$root" >&2
        return 1
    fi
    status=0
    if [ "$scope" = "wallpaper" ]; then
        # Select roots before find: pruning inside the shared root can still trigger sandbox errors.
        sizes=$(
            scan_status=0
            for directory in "$root"/com.apple.wallpaper*; do
                if [ -L "$directory" ]; then continue; fi
                if [ ! -e "$directory" ]; then continue; fi
                if [ ! -d "$directory" ]; then continue; fi
                if [ ! -r "$directory" ] || [ ! -x "$directory" ]; then
                    printf 'Wallpaper cache directory inaccessible: %s\n' "$directory" >&2
                    scan_status=1
                    continue
                fi
                /usr/bin/find "$directory" -type f -iname '*.bmp' \
                    -exec /bin/sh "$0" --batch "$action" {} + || scan_status=1
            done
            exit "$scan_status"
        ) || status=1
    else
        sizes=$(/usr/bin/find "$root" -type f -iname '*.bmp' \
            -exec /bin/sh "$0" --batch "$action" {} +) || status=1
    fi
    printf '%s\n' "$sizes" | /usr/bin/awk -v action="$action" -v root="$root" '
        /^[0-9]+$/ { count++; bytes += $1 }
        END { printf "%s: %s %d BMP files / %.0f bytes (accessible files only)\n", root, action, count, bytes }
    '
    return "$status"
}

# Preserve the old purge scope. No active-cache reference map is assumed.
scan "$container_dir" container remove || result=1
scan "$cache_dir" wallpaper remove || result=1
scan "$container_dir" container remaining || result=1
scan "$cache_dir" wallpaper remaining || result=1
exit "$result"
