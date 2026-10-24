-- ==========================================
-- Hammerspoon Configuration
-- ==========================================

-- Load and start WallpaperRotator Spoon
-- Directory and interval are automatically restored from persisted hs.settings
-- (Default: ~/Pictures/Wallpapers and 300 seconds)
hs.loadSpoon("WallpaperRotator")

-- Unique staging is unconditional. Retention does not protect inactive Spaces.
spoon.WallpaperRotator.maxStagedFiles = 50
spoon.WallpaperRotator.maxStagedBytes = 256 * 1024 * 1024
spoon.WallpaperRotator.enableFadeTransition = true
spoon.WallpaperRotator.enableCacheCleanup = true
spoon.WallpaperRotator.cleanupInterval = 10

-- Bind hotkeys for WallpaperRotator actions
spoon.WallpaperRotator:bindHotkeys({
    rotate = { {"ctrl", "alt", "cmd"}, "W" },
    choose_folder = { {"ctrl", "alt", "cmd"}, "O" },
    set_interval = { {"ctrl", "alt", "cmd"}, "I" }
})

spoon.WallpaperRotator:start()