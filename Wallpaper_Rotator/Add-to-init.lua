-- ==========================================
-- Hammerspoon Configuration
-- ==========================================

-- Load and start WallpaperRotator Spoon
-- Directory and interval are automatically restored from persisted hs.settings
-- (Default: ~/Pictures/Wallpapers and 300 seconds)
hs.loadSpoon("WallpaperRotator")

-- Bind hotkeys for WallpaperRotator actions
spoon.WallpaperRotator:bindHotkeys({
    rotate = { {"ctrl", "alt", "cmd"}, "W" },
    choose_folder = { {"ctrl", "alt", "cmd"}, "O" },
    set_interval = { {"ctrl", "alt", "cmd"}, "I" }
})

spoon.WallpaperRotator:start()