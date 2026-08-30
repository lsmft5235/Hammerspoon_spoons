--- === WallpaperRotator ===
---
--- Periodically rotates desktop wallpapers across all connected screens from a directory of images.
---
--- Download: [https://github.com/Hammerspoon/Spoons](https://github.com/Hammerspoon/Spoons)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "WallpaperRotator"
obj.version = "1.0.0"
obj.author = "LSMFT5235"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- WallpaperRotator.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set default log level.
obj.logger = hs.logger.new("WallpaperRotator")

--- WallpaperRotator.dir
--- Variable
--- Path to the directory containing wallpaper images.
--- Defaults to the persisted setting `WallpaperRotator_dir`, or `~/Pictures/Wallpapers`.
obj.dir = hs.settings.get("WallpaperRotator_dir") or (os.getenv("HOME") .. "/Pictures/Wallpapers")

--- WallpaperRotator.interval
--- Variable
--- Interval in seconds between automatic wallpaper changes.
--- Defaults to the persisted setting `WallpaperRotator_interval`, or 300 (5 minutes).
obj.interval = hs.settings.get("WallpaperRotator_interval") or 300

--- WallpaperRotator.allowedExtensions
--- Variable
--- Table of file extensions allowed for wallpaper selection.
--- Default: `{ jpg = true, jpeg = true, png = true, heic = true, avif = true, webp = true }`
obj.allowedExtensions = {
    jpg = true,
    jpeg = true,
    png = true,
    heic = true,
    avif = true,
    webp = true
}

--- WallpaperRotator.notifyOnChange
--- Variable
--- Boolean indicating whether an alert should be displayed when the wallpaper rotates manually.
--- Default: true
obj.notifyOnChange = true

--- WallpaperRotator.stagingDir
--- Variable
--- Directory used to stage wallpapers in two alternating slots (A and B).
--- Limits path-based entries created by macOS in System Settings.
--- Default: `~/.hammerspoon/.wallpaper_staging`
obj.stagingDir = os.getenv("HOME") .. "/.hammerspoon/.wallpaper_staging"

--- WallpaperRotator.enableCacheCleanup
--- Variable
--- Boolean indicating whether orphaned .BMP wallpaper cache files should be purged periodically.
--- Default: true
obj.enableCacheCleanup = true

--- WallpaperRotator.cleanupInterval
--- Variable
--- Number of rotation cycles between automatic cache cleanups.
--- Default: 10
obj.cleanupInterval = 10

--- WallpaperRotator.showCountdown
--- Variable
--- Boolean indicating whether a countdown overlay badge should be displayed in the lower-left corner.
--- Default: true
obj.showCountdown = true

--- WallpaperRotator.enableFadeTransition
--- Variable
--- Boolean indicating whether smooth crossfade transitions should be used between wallpapers.
--- Default: true
obj.enableFadeTransition = true

--- WallpaperRotator.fadeDuration
--- Variable
--- Duration in seconds for the smooth crossfade transition.
--- Default: 2.0
obj.fadeDuration = 2.0

-- Internal state
obj.timer = nil
obj.hotkeys = {}
obj.currentSlot = "a"
obj.rotationCount = 0
obj.countdownCanvas = nil
obj.countdownTimer = nil
obj.remainingSeconds = 0
obj.screenWatcher = nil
obj.isTransitioning = false

-- Helper: ensure staging directory exists
local function ensureStagingDir(dir)
    local attrs = hs.fs.attributes(dir)
    if not attrs then
        hs.fs.mkdir(dir)
    end
end

-- Helper: binary file copy
local function copyFile(src, dst)
    local infile, err = io.open(src, "rb")
    if not infile then return false, err end
    local outfile, outErr = io.open(dst, "wb")
    if not outfile then
        infile:close()
        return false, outErr
    end
    while true do
        local block = infile:read(65536)
        if not block then break end
        outfile:write(block)
    end
    infile:close()
    outfile:close()
    return true
end

-- Helper: percent-decode a file:// URL so encoding differences don't cause false mismatches
local function decodeUrl(url)
    if not url then return url end
    return (url:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

-- Fallback for displays (e.g. TV-profile HDMI screens) that reject hs.screen:desktopImageURL()
local function setWallpaperViaSystemEvents(desktopIndex, filePath)
    local escapedPath = filePath:gsub('"', '\\"')
    local script = string.format([[
        tell application "System Events"
            set picture of desktop %d to POSIX file "%s"
        end tell
    ]], desktopIndex, escapedPath)
    return hs.osascript.applescript(script)
end

-- Helper: Retrieve valid image files from directory
-- Returns files, errorMessage (errorMessage is nil on success)
local function getWallpaperFiles(dir)
    local files = {}
    local attrs = hs.fs.attributes(dir)
    if not attrs or attrs.mode ~= "directory" then
        return files, "Directory does not exist or is not accessible: " .. tostring(dir)
    end

    local ok, iterFn, dirObj = pcall(hs.fs.dir, dir)
    if not ok or not iterFn then
        return files, "Could not list directory (check Hammerspoon's Files & Folders permission): " .. tostring(iterFn)
    end

    for file in iterFn, dirObj do
        if file ~= "." and file ~= ".." then
            local ext = file:match("^.+(%..+)$")
            if ext then
                ext = ext:sub(2):lower()
                if obj.allowedExtensions[ext] then
                    table.insert(files, dir .. "/" .. file)
                end
            end
        end
    end
    return files
end

-- Applies a staged wallpaper to every screen, falling back to System Events when needed.
function obj:applyWallpaperDirect(stagedPath, fileUrl)
    local failedScreens = {}
    for index, screen in ipairs(hs.screen.allScreens()) do
        screen:desktopImageURL(fileUrl)
        -- Compare decoded URLs since NSURL may re-encode the readback differently
        if decodeUrl(screen:desktopImageURL()) ~= decodeUrl(fileUrl) then
            -- Some displays (e.g. TV-profile HDMI screens) reject the NSScreen API; retry via System Events
            local ok = setWallpaperViaSystemEvents(index, stagedPath)
            if not ok then
                table.insert(failedScreens, screen:name() or tostring(screen:id()))
            end
        end
    end

    if #failedScreens > 0 then
        local msg = "WallpaperRotator: macOS rejected the image for: " .. table.concat(failedScreens, ", ") ..
            "\nGrant Hammerspoon Automation access to System Events under System Settings > Privacy & Security > Automation."
        self.logger.e(msg)
        hs.alert.show(msg)
    end
end

--- WallpaperRotator:rotate()
--- Method
--- Selects and applies a random wallpaper image to all connected screens.
--- Uses two alternating staging paths to limit path-based entries in System Settings.
--- Supports smooth hardware-accelerated crossfade transitions via hs.canvas.
--- Prompts to select a folder if no valid images are found.
---
--- Returns:
---  * The WallpaperRotator object
function obj:rotate()
    if self.isTransitioning then
        self.logger.d("Rotation already in progress, skipping.")
        return self
    end

    local wallpapers, err = getWallpaperFiles(self.dir)

    if err then
        self.logger.e(err)
        hs.alert.show("WallpaperRotator: " .. err)
        return self
    end

    if #wallpapers == 0 then
        self.logger.w("No valid images found in " .. tostring(self.dir))
        hs.alert.show("WallpaperRotator: No valid images found in " .. tostring(self.dir) .. "\nPlease select a folder.")
        self:chooseFolder()
        return self
    end

    ensureStagingDir(self.stagingDir)

    math.randomseed(os.time())
    local randomIndex = math.random(1, #wallpapers)
    local selected = wallpapers[randomIndex]

    -- Two-File Staging Swap: alternate between slots 'a' and 'b'
    local targetSlot = self.currentSlot or "a"
    local ext = selected:match("^.+(%..+)$") or ".jpg"
    local stagedPath = self.stagingDir .. "/stage_" .. targetSlot .. ext

    -- Remove any old staging file for this slot with a different extension
    local okDir, iterFn, dirObj = pcall(hs.fs.dir, self.stagingDir)
    if okDir and iterFn then
        for file in iterFn, dirObj do
            if file:match("^stage_" .. targetSlot .. "%..+$") and file ~= ("stage_" .. targetSlot .. ext) then
                os.remove(self.stagingDir .. "/" .. file)
            end
        end
    end

    -- Copy selected wallpaper to the active staging slot
    local copyOk, copyErr = copyFile(selected, stagedPath)
    if not copyOk then
        local msg = "WallpaperRotator: Failed to stage wallpaper file: " .. tostring(copyErr)
        self.logger.e(msg)
        hs.alert.show(msg)
        return self
    end

    local fileUrl = "file://" .. stagedPath:gsub(" ", "%%20")
    self.logger.i(string.format("Staged wallpaper [slot %s]: %s -> %s", targetSlot, selected, stagedPath))

    -- Toggle slot for next rotation
    self.currentSlot = (targetSlot == "a") and "b" or "a"

    -- Increment rotation counter and run periodic cache purge
    self.rotationCount = (self.rotationCount or 0) + 1
    if self.enableCacheCleanup and (self.rotationCount % self.cleanupInterval == 0) then
        self.logger.i(string.format("Triggering 10th-cycle cache cleanup (rotation #%d)...", self.rotationCount))
        self:cleanCache()
    end

    -- Reset countdown timer to full interval
    self.remainingSeconds = self.interval
    self:updateCountdown()

    -- Check if smooth fade transition is enabled and image is readable
    local img = self.enableFadeTransition and hs.image.imageFromPath(stagedPath)
    if not img then
        -- Direct swap fallback
        self:applyWallpaperDirect(stagedPath, fileUrl)
        return self
    end

    -- Smooth Crossfade Overlay via hs.canvas
    self.isTransitioning = true
    local fadeDuration = self.fadeDuration or 1.2
    local transitionCanvases = {}

    for _, screen in ipairs(hs.screen.allScreens()) do
        local screenFrame = screen:fullFrame()
        local canvas = hs.canvas.new(screenFrame)
        canvas:level(hs.canvas.windowLevels.desktop)
        canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "ignoresCycle" })
        canvas:clickActivating(false)
        canvas:appendElements({
            type = "image",
            image = img,
            imageScaling = "scaleToFit",
            frame = { x = 0, y = 0, w = screenFrame.w, h = screenFrame.h }
        })
        canvas:show(fadeDuration)
        table.insert(transitionCanvases, canvas)
    end

    -- Once the overlay reaches 100% opacity, swap the macOS wallpaper behind it
    hs.timer.doAfter(fadeDuration, function()
        self:applyWallpaperDirect(stagedPath, fileUrl)

        -- Hold the opaque overlay for 0.6s so macOS completes its background render invisibly
        hs.timer.doAfter(0.6, function()
            for _, canvas in ipairs(transitionCanvases) do
                canvas:delete()
            end
            self.isTransitioning = false
        end)
    end)

    return self
end

--- WallpaperRotator:cleanCache()
--- Method
--- Asynchronously purges orphaned .bmp / .BMP files from the macOS wallpaper cache directory.
---
--- Returns:
---  * The WallpaperRotator object
function obj:cleanCache()
    local userHome = os.getenv("HOME")
    local containerCacheDir = userHome .. "/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches"

    local cmd = string.format([[
        container_dir="%s"
        if [ -d "$container_dir" ]; then
            find "$container_dir" -type f \( -iname "*.bmp" \) -delete 2>/dev/null || true
        fi

        cache_dir="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
        if [ -n "$cache_dir" ] && [ -d "$cache_dir" ]; then
            find "$cache_dir" -path "*/com.apple.wallpaper*/*" -type f \( -iname "*.bmp" \) -delete 2>/dev/null || true
        fi
        exit 0
    ]], containerCacheDir)

    hs.task.new("/bin/sh", function(exitCode, stdOut, stdErr)
        if exitCode == 0 then
            self.logger.i("Wallpaper cache cleanup completed successfully.")
        else
            self.logger.w("Wallpaper cache cleanup finished with exit code: " .. tostring(exitCode))
        end
    end, { "-c", cmd }):start()

    return self
end

-- Builds and positions the countdown overlay on the primary screen.
function obj:createCountdownCanvas()
    if self.countdownCanvas then
        self.countdownCanvas:delete()
        self.countdownCanvas = nil
    end

    if not self.showCountdown then return self end

    local screen = hs.screen.primaryScreen() or hs.screen.mainScreen()
    if not screen then return self end

    local screenFrame = screen:fullFrame()
    local badgeW = 76
    local badgeH = 26
    local posX = screenFrame.x + 18
    local posY = screenFrame.y + screenFrame.h - badgeH - 18

    self.countdownCanvas = hs.canvas.new({
        x = posX,
        y = posY,
        w = badgeW,
        h = badgeH
    })

    self.countdownCanvas:level(hs.canvas.windowLevels.overlay)
    self.countdownCanvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary" })
    self.countdownCanvas:clickActivating(false)

    self.countdownCanvas:appendElements(
        -- Element 1: Rounded translucent background pill
        {
            type = "rectangle",
            action = "fill",
            fillColor = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.65 },
            roundedRectRadii = { xRadius = 6, yRadius = 6 },
            frame = { x = 0, y = 0, w = badgeW, h = badgeH }
        },
        -- Element 2: Centered countdown text
        {
            type = "text",
            text = "0:00",
            textFont = "Menlo-Bold",
            textSize = 12,
            textColor = { white = 0.95, alpha = 0.9 },
            textAlignment = "center",
            frame = { x = 0, y = 4, w = badgeW, h = badgeH - 4 }
        }
    )

    self.countdownCanvas:show()
    return self
end

-- Updates the countdown text element on the canvas.
function obj:updateCountdown()
    if not self.countdownCanvas or not self.showCountdown then return self end

    local totalSecs = math.max(0, math.floor(self.remainingSeconds or 0))
    local mins = math.floor(totalSecs / 60)
    local secs = totalSecs % 60
    local textStr = string.format("%d:%02d", mins, secs)

    self.countdownCanvas[2].text = textStr
    return self
end

-- Initializes and starts the one-second countdown ticker.
function obj:startCountdown()
    self:stopCountdown()
    if not self.showCountdown then return self end

    self:createCountdownCanvas()
    self.remainingSeconds = self.interval
    self:updateCountdown()

    self.countdownTimer = hs.timer.doEvery(1, function()
        if self.remainingSeconds and self.remainingSeconds > 0 then
            self.remainingSeconds = self.remainingSeconds - 1
        end
        self:updateCountdown()
    end)

    return self
end

-- Stops the countdown timer and deletes the overlay canvas.
function obj:stopCountdown()
    if self.countdownTimer then
        self.countdownTimer:stop()
        self.countdownTimer = nil
    end
    if self.countdownCanvas then
        self.countdownCanvas:delete()
        self.countdownCanvas = nil
    end
    return self
end

--- WallpaperRotator:chooseFolder()
--- Method
--- Opens a macOS directory selection dialog to pick a new wallpaper directory.
--- Persists the selected path across restarts.
---
--- Returns:
---  * The WallpaperRotator object
function obj:chooseFolder()
    hs.focus()

    -- Ensure defaultPath exists and is a directory
    local defaultPath = self.dir
    local attrs = defaultPath and hs.fs.attributes(defaultPath)
    if not attrs or attrs.mode ~= "directory" then
        defaultPath = os.getenv("HOME")
    end

    local selection = hs.dialog.chooseFileOrFolder(
        "Choose a wallpaper folder",
        defaultPath,
        false, -- canChooseFiles
        true,  -- canChooseDirectories
        false  -- allowsMultipleSelection
    )

    -- Grab the first entry regardless of whether the returned table uses a
    -- numeric or string "1" key (observed to vary across Hammerspoon versions)
    local chosenPath = nil
    if type(selection) == "table" then
        chosenPath = selection[1] or selection["1"]
    end

    if chosenPath then
        -- Normalize trailing slash
        chosenPath = chosenPath:gsub("/$", "")
        self:setDirectory(chosenPath)
        hs.alert.show("Wallpaper folder updated:\n" .. self.dir)
        self:rotate()
    end

    return self
end

--- WallpaperRotator:setDirectory(dir)
--- Method
--- Sets and persists the wallpaper directory.
---
--- Parameters:
---  * dir - String containing the path to the directory
---
--- Returns:
---  * The WallpaperRotator object
function obj:setDirectory(dir)
    self.dir = dir
    hs.settings.set("WallpaperRotator_dir", dir)
    return self
end

--- WallpaperRotator:promptInterval()
--- Method
--- Displays an interactive dialog prompt to set a new rotation interval in seconds.
---
--- Returns:
---  * The WallpaperRotator object
function obj:promptInterval()
    local button, input = hs.dialog.textPrompt(
        "Wallpaper Rotation Interval",
        "Enter rotation interval in seconds:",
        tostring(self.interval),
        "Save",
        "Cancel"
    )

    if button == "Save" then
        local num = tonumber(input)
        if num and num > 0 then
            self:setInterval(math.floor(num))
            hs.alert.show(string.format("Rotation interval set to %ds", self.interval))
        else
            hs.alert.show("Invalid interval: please enter a positive number")
        end
    end

    return self
end

--- WallpaperRotator:setInterval(seconds)
--- Method
--- Sets and persists the update interval, restarting the timer if currently active.
---
--- Parameters:
---  * seconds - Integer representing the interval in seconds
---
--- Returns:
---  * The WallpaperRotator object
function obj:setInterval(seconds)
    self.interval = seconds
    hs.settings.set("WallpaperRotator_interval", seconds)
    self.remainingSeconds = seconds
    self:updateCountdown()
    if self.timer then
        self:start()
    end
    return self
end

--- WallpaperRotator:bindHotkeys(mapping)
--- Method
--- Binds hotkey actions for WallpaperRotator.
---
--- Parameters:
---  * mapping - A table containing action-to-hotkey mappings. Valid keys are:
---    * `rotate` - Rotate wallpaper immediately
---    * `choose_folder` - Open folder picker dialog
---    * `set_interval` - Prompt for new interval dialog
---    * `clean_cache` - Purge .BMP wallpaper cache immediately
---
--- Returns:
---  * The WallpaperRotator object
function obj:bindHotkeys(mapping)
    local def = {
        rotate = function()
            self:rotate()
            if self.notifyOnChange then
                hs.alert.show("Wallpaper Rotated 🖼️")
            end
        end,
        choose_folder = function()
            self:chooseFolder()
        end,
        set_interval = function()
            self:promptInterval()
        end,
        clean_cache = function()
            self:cleanCache()
            if self.notifyOnChange then
                hs.alert.show("Wallpaper Cache Cleaned 🧹")
            end
        end
    }
    hs.spoons.bindHotkeysToSpec(def, mapping)
    return self
end

--- WallpaperRotator:start()
--- Method
--- Starts the background rotation timer, begins the countdown overlay, and applies a wallpaper immediately.
---
--- Returns:
---  * The WallpaperRotator object
function obj:start()
    self:stop()

    -- Screen topology watcher to reposition badge if resolution or displays change
    if not self.screenWatcher then
        self.screenWatcher = hs.screen.watcher.new(function()
            if self.showCountdown and self.countdownCanvas then
                self:createCountdownCanvas()
                self:updateCountdown()
            end
        end)
        self.screenWatcher:start()
    end

    self:startCountdown()

    self.timer = hs.timer.doEvery(self.interval, function()
        self:rotate()
    end)
    self:rotate()
    return self
end

--- WallpaperRotator:stop()
--- Method
--- Stops the background rotation timer and removes the countdown overlay.
---
--- Returns:
---  * The WallpaperRotator object
function obj:stop()
    if self.timer then
        self.timer:stop()
        self.timer = nil
    end
    self:stopCountdown()
    if self.screenWatcher then
        self.screenWatcher:stop()
        self.screenWatcher = nil
    end
    return self
end

--- WallpaperRotator:init()
--- Method
--- Initializes the Spoon and prepares staging directory.
---
--- Returns:
---  * The WallpaperRotator object
function obj:init()
    ensureStagingDir(self.stagingDir)
    return self
end

return obj
