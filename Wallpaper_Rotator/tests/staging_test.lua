-- Run from the repository root with Lua 5.3+ (or fengari-node-cli).
local spoonPath = "Wallpaper_Rotator/WallpaperRotator.spoon/init.lua"
local originalOpen = io.open
local passed = 0
local function noop() end

local function fixture()
    local f = {
        files = {}, logs = {}, alerts = {}, timers = {}, tasks = {}, canvases = {},
        time = 0, uuid = 0, image = false, current = "file:///original.jpg",
        source = "/source/photo.jpg"
    }
    f.files["/source"] = { mode = "directory", dev = 1, ino = 1 }
    f.files["/staging"] = { mode = "directory", dev = 1, ino = 2 }
    f.files["/original.jpg"] = { mode = "file", size = 4, modification = 0 }
    f.files[f.source] = { mode = "file", size = 4, modification = 0 }
    function f.add(name, size, time, mode)
        local path = "/staging/" .. name
        f.files[path] = { mode = mode or "file", size = size, modification = time or 0 }
        return path
    end
    function f.advance(seconds)
        local target = f.time + seconds
        while true do
            local nextTimer
            for _, timer in ipairs(f.timers) do
                if not timer.stopped and timer.at <= target and
                    (not nextTimer or timer.at < nextTimer.at) then nextTimer = timer end
            end
            if not nextTimer then break end
            nextTimer.stopped = true
            f.time = nextTimer.at
            nextTimer.fn()
        end
        f.time = target
    end
    function f.hasLog(text)
        for _, message in ipairs(f.logs) do
            if message:find(text, 1, true) then return true end
        end
        return false
    end
    function f.count()
        local count, bytes = 0, 0
        for path, attrs in pairs(f.files) do
            if path:match("^/staging/stage_") and attrs.mode == "file" then
                count, bytes = count + 1, bytes + attrs.size
            end
        end
        return count, bytes
    end
    local screen = {
        name = function() return "test display" end,
        id = function() return 1 end,
        fullFrame = function() return f.screenFrame or { x = 0, y = 0, w = 100, h = 100 } end,
        desktopImageURL = function(_, url)
            if f.screenError then error("screen unavailable") end
            if url and not f.reject then f.current = url end
            return f.current
        end
    }
    hs = {
        spoons = {
            scriptPath = function() return "Wallpaper_Rotator/WallpaperRotator.spoon" end,
            bindHotkeysToSpec = function(spec) f.hotkeys = spec end
        },
        settings = { get = noop, set = function(key, value) f[key] = value end },
        logger = { new = function()
            local function log(message) f.logs[#f.logs + 1] = message end
            return { i = log, w = log, e = log, d = log }
        end },
        alert = { show = function(message) f.alerts[#f.alerts + 1] = message end },
        host = { uuid = function()
            f.uuid = f.uuid + 1
            return string.format("00000000-0000-4000-8000-%012x", f.uuid)
        end },
        fs = {
            attributes = function(path) return f.files[path] end,
            symlinkAttributes = function(path)
                if f.metadataError then return nil, "metadata unavailable" end
                return f.files[path]
            end,
            pathToAbsolute = function(path)
                if f.resolveError then return nil end
                if f.files[path] then return path end
            end,
            mkdir = function(path)
                if f.mkdirError then return nil, "mkdir failed" end
                f.files[path] = { mode = "directory", dev = 1, ino = 3 }
                return true
            end,
            dir = function(dir)
                if f.dirError == dir then error("cannot list directory") end
                local entries = {}
                for path in pairs(f.files) do
                    if path:sub(1, #dir + 1) == dir .. "/" then
                        local name = path:sub(#dir + 2)
                        if not name:find("/", 1, true) then entries[#entries + 1] = name end
                    end
                end
                table.sort(entries)
                local index = 0
                return function()
                    index = index + 1
                    return entries[index]
                end
            end
        },
        screen = { allScreens = function()
            if f.enumerationError then error("screens unavailable") end
            if f.noScreens then return {} end
            local screens = { screen }
            if f.secondUrl then
                screens[2] = {
                    desktopImageURL = function(_, url)
                        if url then f.secondUrl = url end
                        return f.secondUrl
                    end,
                    name = function() return "second display" end,
                    id = function() return 2 end,
                    fullFrame = function() return f.secondFrame or screen.fullFrame() end
                }
            end
            return screens
        end },
        image = { imageFromPath = function()
            if not f.image then return nil end
            return { size = function() return f.imageSize or { w = 100, h = 100 } end }
        end },
        timer = { doAfter = function(delay, fn)
            local timer = { at = f.time + delay, fn = fn }
            timer.stop = function() timer.stopped = true end
            f.timers[#f.timers + 1] = timer
            return timer
        end },
        task = { new = function(executable, callback, args)
            if f.taskCreateError then return nil end
            local task = { executable = executable, callback = callback, args = args }
            task.start = function() task.started = not f.taskStartError; return task.started and task end
            task.terminate = function() task.terminated = true end
            task.complete = function(code, out, err) callback(code or 0, out or "", err or "") end
            f.tasks[#f.tasks + 1] = task
            return task
        end },
        canvas = {
            windowLevels = { desktop = 1 },
            new = function(frame)
                local canvas = {
                    frame = frame,
                    level = noop, behaviorAsLabels = noop, clickActivating = noop,
                    show = noop
                }
                canvas.appendElements = function(_, element) canvas.element = element end
                canvas.delete = function()
                    assert(not canvas.deleted, "overlay deleted twice")
                    canvas.deleted = true
                end
                f.canvases[#f.canvases + 1] = canvas
                return canvas
            end
        }
    }
    io.open = function(path, mode)
        if mode == "rb" then
            if f.readOpenError then return nil, "open failed" end
            local read = false
            return {
                read = function()
                    if f.readError then return nil, "read failed" end
                    if read then return nil end
                    read = true
                    return "data"
                end,
                close = function() return true end
            }
        end
        if f.writeOpenError then return nil, "write open failed" end
        f.files[path] = { mode = "file", size = 0, modification = f.time }
        return {
            write = function(_, data)
                if f.writeError then return nil, "write failed" end
                f.files[path].size = f.files[path].size + #data
                return true
            end,
            close = function()
                if f.closeError then return nil, "close failed" end
                return true
            end
        }
    end
    os.remove = function(path)
        if f.deleteError then return nil, "permission denied" end
        f.files[path] = nil
        return true
    end
    function f.load()
        local spoon = assert(loadfile(spoonPath))()
        spoon.dir, spoon.stagingDir = "/source", "/staging"
        spoon.updateCountdown = noop
        return spoon
    end
    f.spoon = f.load()
    return f, f.spoon
end

local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        io.stderr:write("FAIL " .. name .. "\n" .. tostring(err) .. "\n")
        os.exit(1)
    end
    passed = passed + 1
    print("PASS " .. name)
end
local function uuidName(n, prefix, ext)
    return string.format("%s00000000-0000-4000-8000-%012x.%s", prefix or "stage_", n, ext or "jpg")
end

test("50-file equality, oldest-first pruning, and reload migration", function()
    local f, s = fixture()
    for n = 1, 50 do f.add(uuidName(n), 4, n) end
    s:cleanStaging()
    assert(f.count() == 50)
    f.add("stage_a.jpg", 4, -2)
    f.add(uuidName(51, "stage_diagnostic_"), 4, -1)
    s:cleanStaging()
    assert(f.count() == 50)
    assert(not f.files["/staging/stage_a.jpg"])
    assert(not f.files["/staging/" .. uuidName(51, "stage_diagnostic_")])
    local reloaded = f.load()
    f.add("stage_b.png", 4, -1)
    reloaded:cleanStaging()
    assert(f.count() == 50 and not f.files["/staging/stage_b.png"])
end)

test("exact byte threshold, overage, both targets, deterministic ties", function()
    local f, s = fixture()
    s.maxStagedFiles, s.maxStagedBytes = 2, 10
    local first = f.add("stage_a.jpg", 5)
    f.add("stage_b.jpg", 5)
    s:cleanStaging()
    local count, bytes = f.count()
    assert(count == 2 and bytes == 10)
    f.add(uuidName(3), 1, 1)
    s:cleanStaging()
    assert(not f.files[first], "filename tie-breaker failed")
    count, bytes = f.count()
    assert(count == 2 and bytes == 6)
    s.maxStagedBytes = 8
    f.add(uuidName(4), 8, 1)
    s:cleanStaging()
    count, bytes = f.count()
    assert(count == 1 and bytes == 8)
end)

test("default 256-MiB target at equality and one byte over", function()
    local f, s = fixture()
    local path = f.add("stage_a.jpg", 268435456, 0)
    s:cleanStaging()
    local count, bytes = f.count()
    assert(count == 1 and bytes == 268435456)
    f.add("stage_b.jpg", 1, 1)
    s:cleanStaging()
    count, bytes = f.count()
    assert(count == 1 and bytes == 1 and not f.files[path])
end)

test("unrelated files, directories, symlinks and source remain untouched", function()
    local f, s = fixture()
    local other = f.add("keep.jpg", 100)
    local malformed = f.add("stage_not-a-uuid.jpg", 100)
    local link = f.add(uuidName(1), 100, 0, "link")
    local dir = f.add(uuidName(2), 100, 0, "directory")
    f.add("stage_a.jpg", 4)
    f.add("stage_b.jpg", 4)
    s.maxStagedFiles = 1
    s:cleanStaging()
    assert(f.files[other] and f.files[malformed] and f.files[link] and f.files[dir])
    assert(f.files[f.source])
end)

test("current and in-flight files protected, oversized candidate logged", function()
    local f, s = fixture()
    local current = f.add("stage_a.jpg", 12)
    local pending = f.add(uuidName(1), 12)
    f.current = "file:///staging/stage%5Fa.jpg"
    s.inFlightPaths[pending] = true
    s.maxStagedFiles, s.maxStagedBytes = 1, 10
    s:cleanStaging()
    assert(f.files[current] and f.files[pending])
    assert(f.hasLog("targets unmet"))
    s.inFlightPaths[pending] = nil
    s:cleanStaging()
    assert(not f.files[pending] and f.files[current])
end)

test("multiple screens, percent-encoded paths and oversized rotation", function()
    local f, s = fixture()
    local first = f.add("stage_a.jpg", 4)
    local second = f.add("stage_b.jpg", 4)
    f.current, f.secondUrl = "file:///staging/stage%5Fa.jpg", "file://localhost/staging/stage_b.jpg"
    s.maxStagedFiles, s.maxStagedBytes = 1, 3
    s:cleanStaging()
    assert(f.files[first] and f.files[second] and f.hasLog("targets unmet"))
    s.enableFadeTransition, s.enableCacheCleanup = false, false
    s:rotate()
    f.advance(0.3)
    assert(f.current == f.secondUrl and not next(s.inFlightPaths))
    local count, bytes = f.count()
    assert(count == 1 and bytes == 4 and f.hasLog("targets unmet"))
end)

test("unsafe lookup and filesystem failures skip pruning and log", function()
    for _, failure in ipairs({
        "screenError", "enumerationError", "noScreens", "metadataError", "resolveError", "deleteError"
    }) do
        local f, s = fixture()
        f.add("stage_a.jpg", 4)
        f.add("stage_b.jpg", 4)
        s.maxStagedFiles = 1
        f[failure] = true
        s:cleanStaging()
        assert(f.count() == 2, failure)
        assert(#f.logs > 0, failure)
    end
    local f, s = fixture()
    f.add("stage_a.jpg", 4)
    s.dir = s.stagingDir
    s:cleanStaging()
    assert(f.hasLog("identical"))
    s.dir = "/source"
    f.dirError = "/staging"
    s:cleanStaging()
    assert(f.hasLog("cannot list directory"))
    s.maxStagedFiles = nil
    s:cleanStaging()
    assert(f.hasLog("positive finite integers"))
end)

test("unique paths across 35 rotations, reload, folder and extension changes", function()
    local f, s = fixture()
    s.enableFadeTransition, s.enableCacheCleanup = false, false
    local seen = {}
    for _ = 1, 35 do
        s:rotate()
        assert(not seen[f.current])
        seen[f.current] = true
        f.advance(1)
    end
    s = f.load()
    s.enableFadeTransition, s.enableCacheCleanup = false, false
    f.files["/other"] = { mode = "directory", dev = 1, ino = 4 }
    f.files["/other/photo.png"] = { mode = "file", size = 4 }
    s.dir = "/other"
    s:rotate()
    assert(not seen[f.current] and f.current:match("%.png$"))
    f.advance(1)
    assert(not next(s.inFlightPaths))
end)

test("overlapping direct rotations protect all pending paths", function()
    local f, s = fixture()
    s.enableFadeTransition, s.enableCacheCleanup = false, false
    s.maxStagedFiles = 1
    s:rotate()
    local first = f.current:sub(8)
    s:rotate()
    local second = f.current:sub(8)
    assert(f.files[first] and f.files[second])
    assert(s.inFlightPaths[first] and s.inFlightPaths[second])
    f.advance(1)
    -- The older URL check starts a fallback; its path stays protected until completion.
    assert(s.inFlightPaths[first])
    f.tasks[1].complete()
    assert(not next(s.inFlightPaths) and f.files[second])
    assert(f.count() == 1)
end)

test("fade waits for fallback; cache purge waits for fade and coalesces", function()
    local f, s = fixture()
    f.image, f.reject = true, true
    s.cleanupInterval = 1
    s:rotate()
    s:cleanCache()
    assert(#f.tasks == 0)
    f.advance(s.fadeDuration + 0.25)
    assert(#f.tasks == 1 and f.tasks[1].executable == "/usr/bin/osascript")
    assert(not f.canvases[1].deleted and next(s.inFlightPaths))
    f.tasks[1].complete()
    f.advance(0.6)
    assert(f.canvases[1].deleted and not next(s.inFlightPaths))
    assert(#f.tasks == 2 and s.cacheCleanupTask == f.tasks[2])
    s:cleanCache()
    s:rotate()
    assert(#f.tasks == 2 and s.rotationCount == 1)
    f.tasks[2].complete(0, "removed 1 BMP / 4 bytes")
    assert(not s.cacheCleanupTask and f.hasLog("removed 1 BMP"))
end)

test("fade covers UHD screens without distortion or a size change at handoff", function()
    local cases = {
        { w = 1920, h = 1080, x = 0, y = 0, width = 3840, height = 2160 },
        { w = 7680, h = 4320, x = 0, y = 0, width = 3840, height = 2160 },
        { w = 1080, h = 1920, x = 0, y = -7000 / 3, width = 3840, height = 20480 / 3 },
        { w = 4000, h = 1000, x = -2400, y = 0, width = 8640, height = 2160 }
    }
    local function near(a, b) assert(math.abs(a - b) < 0.000001, tostring(a) .. " ~= " .. tostring(b)) end
    for _, case in ipairs(cases) do
        local f, s = fixture()
        f.image = true
        f.imageSize = { w = case.w, h = case.h }
        f.screenFrame = { x = -3840, y = 100, w = 3840, h = 2160 }
        f.secondUrl = "file:///original.jpg"
        f.secondFrame = { x = 0, y = 0, w = 1080, h = 1920 }
        s:rotate()
        local canvas = f.canvases[1]
        local element, frame = canvas.element, canvas.element.frame
        assert(canvas.frame.x == -3840 and canvas.frame.y == 100)
        assert(element.imageScaling == "scaleProportionally" and element.imageAlignment == "center")
        near(frame.x, case.x)
        near(frame.y, case.y)
        near(frame.w, case.width)
        near(frame.h, case.height)
        near(frame.w / frame.h, case.w / case.h)
        local second = f.canvases[2].element.frame
        assert(second.w >= 1080 and second.h >= 1920)
        near(second.x, (1080 - second.w) / 2)
        near(second.y, (1920 - second.h) / 2)
        near(second.w / second.h, case.w / case.h)
        f.advance(s.fadeDuration + 0.25 + 0.6)
        assert(canvas.deleted and f.canvases[2].deleted)
        assert(not next(s.inFlightPaths))
    end
end)

test("fallback timeout, failure and task-start/create failure release protection once", function()
    for _, failure in ipairs({ "timeout", "exit", "start", "create" }) do
        local f, s = fixture()
        s.enableFadeTransition, s.enableCacheCleanup = false, false
        f.reject = true
        f.taskStartError = failure == "start"
        f.taskCreateError = failure == "create"
        s:rotate()
        f.advance(0.25)
        if failure == "timeout" then
            f.advance(8)
            assert(f.tasks[1].terminated)
            f.tasks[1].complete(0)
        elseif failure == "exit" then
            f.tasks[1].complete(1, "", "denied")
        end
        assert(not next(s.inFlightPaths), failure)
        assert(f.hasLog("Fallback failed"), failure)
    end
end)

test("cache timeout stays locked until exit; failures are explicit", function()
    local f, s = fixture()
    s:cleanCache()
    f.advance(30)
    assert(f.tasks[1].terminated and s.cacheCleanupTask)
    s:cleanCache()
    assert(#f.tasks == 1)
    f.tasks[1].complete(124, "", "timed out")
    assert(not s.cacheCleanupTask and f.hasLog("timed out"))
    f.taskStartError = true
    s:cleanCache()
    assert(not s.cacheCleanupTask and f.hasLog("Could not start"))
    f.taskStartError, f.taskCreateError = false, true
    s:cleanCache()
    assert(not s.cacheCleanupTask and f.hasLog("Could not create"))
    f.taskCreateError = false
    s:cleanCache()
    f.tasks[#f.tasks].complete(1, "partial measurements", "permission denied")
    assert(f.hasLog("partial measurements") and f.hasLog("permission denied"))
end)

test("no-screen operations release paths and invalid cadence reports an error", function()
    local f, s = fixture()
    f.noScreens = true
    s.enableFadeTransition = false
    s:rotate()
    assert(not next(s.inFlightPaths) and f.hasLog("No connected screens"))
    f.noScreens, f.enumerationError = false, true
    s:rotate()
    assert(not next(s.inFlightPaths) and f.hasLog("Could not enumerate screens"))
    f.enumerationError = false
    s.cleanupInterval = 0
    s:rotate()
    f.advance(0.3)
    assert(not next(s.inFlightPaths) and f.hasLog("cleanupInterval must"))
end)

test("default cache cadence and independent staging retention", function()
    local f, s = fixture()
    assert(s.enableCacheCleanup and s.cleanupInterval == 10 and s.enableFadeTransition)
    s.enableFadeTransition = false
    s.maxStagedFiles = 2
    for n = 1, 10 do
        s:rotate()
        assert(#f.tasks == 0, "purge started before application settled")
        f.advance(0.3)
        if n < 10 then assert(#f.tasks == 0) end
    end
    assert(#f.tasks == 1 and f.count() <= 2)
    f.tasks[1].complete()
    s.enableCacheCleanup = false
    for _ = 1, 12 do s:rotate(); f.advance(0.3) end
    assert(#f.tasks == 1 and f.count() <= 2)
    s:bindHotkeys({})
    f.hotkeys.clean_cache()
    assert(#f.tasks == 2 and #f.alerts == 0)
    f.tasks[2].complete(1, "", "test error")
    assert(#f.alerts == 1)
end)

test("copy and directory failures do not apply partial wallpapers", function()
    for _, failure in ipairs({
        "readOpenError", "writeOpenError", "readError", "writeError", "closeError", "mkdirError"
    }) do
        local f, s = fixture()
        f[failure] = true
        if failure == "mkdirError" then f.files["/staging"] = nil end
        s:rotate()
        assert(s.rotationCount == 0 and f.current == "file:///original.jpg", failure)
        assert(not next(s.inFlightPaths) and f.count() == 0, failure)
        assert(#f.alerts > 0, failure)
    end
end)

test("watchdog cleanup is idempotent while fallback is pending", function()
    local f, s = fixture()
    f.image, f.reject = true, true
    s:rotate()
    f.advance(s.fadeDuration + 6)
    assert(f.canvases[1].deleted and next(s.inFlightPaths))
    f.advance(3)
    assert(not next(s.inFlightPaths))
    f.advance(1)
end)

test("directory, interval, countdown reset and folder-picker interfaces", function()
    local f, s = fixture()
    s.enableFadeTransition, s.enableCacheCleanup = false, false
    s:setDirectory("/source")
    assert(f.WallpaperRotator_dir == "/source")
    s:setInterval(17)
    assert(s.interval == 17 and s.remainingSeconds == 17 and f.WallpaperRotator_interval == 17)
    s.remainingSeconds = 1
    s:rotate()
    assert(s.remainingSeconds == 17)
    f.advance(0.3)
    hs.focus = noop
    hs.dialog = { chooseFileOrFolder = function() return { ["1"] = "/source/" } end }
    s:chooseFolder()
    assert(s.dir == "/source" and s.rotationCount == 2)
    f.advance(0.3)
    hs.dialog.textPrompt = function() return "Save", "23" end
    s:promptInterval()
    assert(s.interval == 23 and s.remainingSeconds == 23)
    s:bindHotkeys({})
    assert(f.hotkeys.rotate and f.hotkeys.choose_folder and f.hotkeys.set_interval and f.hotkeys.clean_cache)
end)

io.open = originalOpen
print(string.format("%d staging/lifecycle tests passed", passed))
