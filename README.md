# Hammerspoon_spoons
Spoon tools for Hammerspoon.
See: https://www.hammerspoon.org/

## Spoons

### WallpaperRotator
Periodically rotates desktop wallpapers across all connected screens, picking a random image from a configurable directory (default `~/Pictures/Wallpapers`). Features include:
- Configurable rotation interval, persisted across restarts
- Smooth crossfade transitions between wallpapers via `hs.canvas`
- A folder picker for choosing the wallpaper directory
- An optional on-screen countdown badge showing time until the next rotation
- Periodic cleanup of orphaned macOS wallpaper cache files
- Hotkey bindings for rotating now, choosing a folder, setting the interval, and cleaning the cache

- Tested with MacOS Tahoe 26.6.2

See [Wallpaper_Rotator/init.lua](Wallpaper_Rotator/init.lua) for an example configuration.


