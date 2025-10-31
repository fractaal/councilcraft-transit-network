--[[
    Display Network Client for ComputerCraft
    Auto-configurable slideshow display with Composer support

    Version: 1.1.0
    Author: Display Network
]]

local VERSION = "1.1.0"
local CONFIG_FILE = "/.display_config"
local POLL_INTERVAL = 5 -- seconds
local SLIDE_DURATION = 10 -- seconds per slide

-- Find monitor (or use main terminal)
local monitor = peripheral.find("monitor")
local display = monitor or term.current()

if monitor then
    print("Found monitor: " .. peripheral.getName(monitor))
else
    print("No monitor found, using terminal")
end

-- Display setup
display.setTextScale(0.5)
local width, height = display.getSize()
print(string.format("Display size: %dx%d", width, height))

-- Configuration management
local function saveConfig(config)
    local file = fs.open(CONFIG_FILE, "w")
    file.write(textutils.serialize(config))
    file.close()
end

local function loadConfig()
    if not fs.exists(CONFIG_FILE) then
        return nil
    end
    local file = fs.open(CONFIG_FILE, "r")
    local data = file.readAll()
    file.close()
    return textutils.unserialize(data)
end

local function setupConfig()
    print("\n=== Display Network Setup ===\n")

    -- Server URL
    term.write("Server URL (e.g., http://192.168.1.100:3000): ")
    local serverUrl = read()
    if serverUrl == "" then
        error("Server URL required")
    end

    -- Collection name
    term.write("Collection name: ")
    local collectionName = read()
    if collectionName == "" then
        error("Collection name required")
    end

    local config = {
        server_url = serverUrl,
        collection_name = collectionName,
        version = VERSION
    }

    saveConfig(config)
    print("\n✓ Configuration saved!")
    sleep(1)
    return config
end

-- Load or create config
local config = loadConfig()
if not config then
    config = setupConfig()
end

print(string.format("Server: %s", config.server_url))
print(string.format("Collection: %s", config.collection_name))

-- Helper: Draw BIMG frame
local function drawBIMG(bimgData)
    local success, frames = pcall(textutils.unserialize, bimgData)
    if not success or not frames or #frames == 0 then
        return false, "Invalid BIMG data"
    end

    local frame = frames[1] -- First frame

    -- Apply custom palette if present
    if frame.palette then
        for i = 0, #frame.palette do
            local c = frame.palette[i]
            if type(c) == "table" then
                display.setPaletteColor(2^i, table.unpack(c))
            else
                display.setPaletteColor(2^i, c)
            end
        end
    end

    display.clear()

    for y = 1, math.min(#frame, height) do
        local line = frame[y]
        if line and #line == 3 then
            local text, fg, bg = line[1], line[2], line[3]
            display.setCursorPos(1, y)
            display.blit(text, fg, bg)
        end
    end

    return true
end

-- Helper: Draw status overlay (bottom-right corner)
local function drawStatusOverlay(current, total, caption)
    local statusText = string.format("%d/%d", current, total)

    -- Position at bottom-right
    local statusY = height
    local statusX = width - #statusText + 1

    display.setCursorPos(statusX, statusY)
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.lime)
    display.write(statusText)

    -- Draw caption if present (above status)
    if caption and caption ~= "" then
        -- Word wrap caption
        local maxWidth = math.min(width - 2, 40)
        local words = {}
        for word in caption:gmatch("%S+") do
            table.insert(words, word)
        end

        local lines = {}
        local currentLine = ""

        for _, word in ipairs(words) do
            if #currentLine + #word + 1 <= maxWidth then
                currentLine = currentLine .. (currentLine ~= "" and " " or "") .. word
            else
                if currentLine ~= "" then
                    table.insert(lines, currentLine)
                end
                currentLine = word
            end
        end
        if currentLine ~= "" then
            table.insert(lines, currentLine)
        end

        -- Draw caption lines above status
        for i, line in ipairs(lines) do
            local y = height - #lines + i - 1
            if y > 0 then
                local x = width - #line - 1
                display.setCursorPos(math.max(1, x), y)
                display.setBackgroundColor(colors.black)
                display.setTextColor(colors.white)
                display.write(line)
            end
        end
    end
end

-- Helper: Show status message
local function showStatus(message, isError)
    display.clear()
    display.setCursorPos(1, 1)
    display.setBackgroundColor(colors.black)
    display.setTextColor(isError and colors.red or colors.white)
    display.write(message)
end

-- Fetch slideshow data
local function fetchSlideshow()
    local endpoint = config.server_url .. "/api/display/" .. config.collection_name
    local response, err = http.get(endpoint)

    if not response then
        return nil, "HTTP error: " .. (err or "unknown")
    end

    local body = response.readAll()
    response.close()

    local data = textutils.unserializeJSON(body)
    if not data or not data.slides or #data.slides == 0 then
        return nil, "No slides in collection"
    end

    return data
end

-- Cleanup function: reset palette and clear screen
local function cleanup()
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()
    display.setCursorPos(1, 1)
    -- Reset palette to native colors
    for i = 0, 15 do
        display.setPaletteColor(2^i, display.nativePaletteColor(2^i))
    end
end

-- Main slideshow loop
local function runSlideshow()
    local slideIndex = 1
    local currentData = nil
    local lastFetch = 0

    while true do
        local now = os.epoch("utc") / 1000

        -- Fetch new data every POLL_INTERVAL seconds
        if not currentData or (now - lastFetch) >= POLL_INTERVAL then
            print(string.format("[%s] Fetching slideshow...", os.date("%H:%M:%S")))
            local data, err = fetchSlideshow()

            if data then
                currentData = data
                lastFetch = now
                print(string.format("Loaded %d slides from '%s'", #data.slides, data.collection_name or "unknown"))

                -- Reset slide index if collection changed
                if slideIndex > #data.slides then
                    slideIndex = 1
                end
            else
                showStatus("Error: " .. err, true)
                print("Retrying in 30 seconds...")
                sleep(30)
            end
        end

        -- Display current slide
        if currentData and #currentData.slides > 0 then
            local slide = currentData.slides[slideIndex]

            -- Draw image
            local success, drawErr = drawBIMG(slide.data)
            if not success then
                showStatus("Error drawing slide: " .. drawErr, true)
                sleep(5)
            else
                -- Overlay status and caption
                drawStatusOverlay(slideIndex, #currentData.slides, slide.caption)

                -- Wait for next slide
                sleep(SLIDE_DURATION)
            end

            -- Next slide (loop)
            slideIndex = slideIndex + 1
            if slideIndex > #currentData.slides then
                slideIndex = 1
            end
        else
            showStatus("Waiting for slides...", false)
            sleep(5)
        end
    end
end

-- Startup
display.clear()
display.setCursorPos(1, 1)
display.setBackgroundColor(colors.black)
display.setTextColor(colors.lime)
display.write(string.format("Display Network v%s", VERSION))

sleep(1)

print("\nStarting slideshow...")
print("Server: " .. config.server_url)
print("Collection: " .. config.collection_name)
print(string.format("Polling every %ds, showing each slide for %ds\n", POLL_INTERVAL, SLIDE_DURATION))

-- Run main loop with error handling
local success, err = pcall(runSlideshow)
if not success then
    cleanup()
    showStatus("Fatal error: " .. tostring(err), true)
    print("\n" .. tostring(err))
    print("\nPress any key to exit")
    os.pullEvent("key")
end

-- Always cleanup on exit
cleanup()
