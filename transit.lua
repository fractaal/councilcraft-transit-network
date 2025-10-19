-- transit.lua
-- CouncilCraft Transit Network
-- Real-time trip monitoring with live delay detection!

-- ============================================================================
-- VERSION
-- ============================================================================

local VERSION = "v0.10.3-modem-side-selection"

-- ============================================================================
-- SHARED: PROTOCOL
-- ============================================================================

local protocol = {}

protocol.DISCOVER = "DISCOVER"
protocol.REGISTER = "REGISTER"
protocol.STATUS = "STATUS"
protocol.DISPATCH = "DISPATCH"
protocol.HEARTBEAT = "HEARTBEAT"
protocol.COUNTDOWN = "COUNTDOWN"
protocol.UPDATE_COMMAND = "UPDATE_COMMAND"
protocol.SHUTDOWN = "SHUTDOWN"

function protocol.serialize(msg)
    return textutils.serialize(msg)
end

function protocol.deserialize(str)
    return textutils.unserialize(str)
end

function protocol.createDiscover(from)
    return {
        type = protocol.DISCOVER,
        from = from,
        timestamp = os.epoch("utc")
    }
end

function protocol.createRegister(station_id, line_id, has_display)
    return {
        type = protocol.REGISTER,
        from = station_id,
        station_id = station_id,
        line_id = line_id,
        has_display = has_display or false,
        timestamp = os.epoch("utc")
    }
end

function protocol.createStatus(station_id, cart_present, trip_status, avg_trip_time, state, version)
    return {
        type = protocol.STATUS,
        from = station_id,
        station_id = station_id,
        cart_present = cart_present,
        trip_status = trip_status or "N/A",
        avg_trip_time = avg_trip_time,
        state = state or "IN_TRANSIT",  -- IN_TRANSIT, ARRIVED, BOARDING, DEPARTING, SHUTDOWN
        version = version or "unknown",
        timestamp = os.epoch("utc")
    }
end

function protocol.createDispatch(from, target)
    return {
        type = protocol.DISPATCH,
        from = from,
        target = target or "ALL",
        timestamp = os.epoch("utc")
    }
end

function protocol.createHeartbeat(from)
    return {
        type = protocol.HEARTBEAT,
        from = from,
        timestamp = os.epoch("utc")
    }
end

function protocol.createCountdown(from, seconds_remaining)
    return {
        type = protocol.COUNTDOWN,
        from = from,
        seconds_remaining = seconds_remaining,
        timestamp = os.epoch("utc")
    }
end

function protocol.createUpdateCommand(from, github_url, target)
    return {
        type = protocol.UPDATE_COMMAND,
        from = from,
        github_url = github_url,
        target = target or "ALL",
        timestamp = os.epoch("utc")
    }
end

function protocol.createShutdown(from, target)
    return {
        type = protocol.SHUTDOWN,
        from = from,
        target = target or "ALL",
        timestamp = os.epoch("utc")
    }
end

-- ============================================================================
-- SHARED: NETWORK
-- ============================================================================

local network = {}

function network.openModem(channel, preferred_side)
    print("[MODEM] [" .. VERSION .. "] Searching for modem peripheral...")

    local modem
    if preferred_side then
        print("[MODEM] Attempting to use modem on side: " .. preferred_side)
        modem = peripheral.wrap(preferred_side)
        if modem and peripheral.getType(preferred_side) == "modem" then
            print("[MODEM] Successfully connected to modem on side: " .. preferred_side)
        else
            print("[MODEM] WARNING: No modem found on side " .. preferred_side .. ", searching for any modem...")
            modem = nil
        end
    end

    -- Fallback to automatic discovery if no preferred side or preferred side failed
    if not modem then
        print("[MODEM] Auto-discovering modem...")
        modem = peripheral.find("modem")
    end

    if not modem then
        print("[MODEM] ERROR: No modem found!")
        error("No modem found! Please attach a wired modem.")
    end

    local modem_side = peripheral.getName(modem)
    local modem_type = modem.isWireless() and "wireless" or "wired"
    print("[MODEM] Connected to " .. modem_type .. " modem on side: " .. modem_side)
    print("[MODEM] Opening channel " .. channel .. "...")
    modem.open(channel)
    print("[MODEM] Channel " .. channel .. " opened successfully")

    -- Log which channels are currently open
    local open_channels = {}
    for i = 0, 65535 do
        if modem.isOpen(i) then
            table.insert(open_channels, tostring(i))
        end
    end
    print("[MODEM] Open channels: " .. table.concat(open_channels, ", "))

    return modem
end

function network.send(modem, channel, message)
    local serialized = protocol.serialize(message)
    local msg_type = message.type or "UNKNOWN"
    local msg_size = #serialized
    local modem_side = peripheral.getName(modem)
    print("[MODEM:" .. modem_side .. "] TX ch=" .. channel .. " type=" .. msg_type .. " size=" .. msg_size .. "B from=" .. (message.from or "?") .. " to=" .. (message.target or "BROADCAST"))

    local success, err = pcall(function()
        modem.transmit(channel, channel, serialized)
    end)

    if not success then
        print("[MODEM:" .. modem_side .. "] ERROR: Failed to transmit message: " .. tostring(err))
    end
end

function network.broadcast(modem, channel, message)
    network.send(modem, channel, message)
end

function network.receiveWithTimeout(timeout)
    timeout = timeout or 1
    local timer = os.startTimer(timeout)

    while true do
        local event, param1, param2, param3, param4, param5 = os.pullEvent()

        if event == "timer" and param1 == timer then
            return nil, nil
        elseif event == "modem_message" then
            os.cancelTimer(timer)
            -- param1 = modem peripheral name
            -- param2 = channel message was sent on
            -- param3 = reply channel
            -- param4 = message payload
            -- param5 = distance (wireless only)
            local modem_side = param1
            local channel = param2
            local reply_channel = param3
            local message = param4
            local distance = param5

            print("[MODEM] RX event: modem=" .. tostring(modem_side) .. " ch=" .. tostring(channel) .. " reply=" .. tostring(reply_channel) .. " dist=" .. tostring(distance or "N/A"))

            if type(message) == "string" then
                print("[MODEM] RX payload type=string size=" .. #message .. "B")
                local decoded = protocol.deserialize(message)
                if decoded then
                    local msg_type = decoded.type or "UNKNOWN"
                    local msg_from = decoded.from or "?"
                    local msg_target = decoded.target or "?"
                    print("[MODEM] RX decoded: type=" .. msg_type .. " from=" .. msg_from .. " to=" .. msg_target)
                    return decoded, channel
                else
                    print("[MODEM] ERROR: Failed to deserialize message")
                end
            else
                print("[MODEM] ERROR: Received non-string message: " .. type(message))
            end
        end
    end
end

function network.checkHealth(modem, expected_channel)
    -- Check if modem peripheral still exists
    local modem_name = peripheral.getName(modem)
    if not modem_name then
        print("[MODEM] ERROR: Modem peripheral lost! No longer attached.")
        return false
    end

    print("[MODEM:" .. modem_name .. "] === Health Check ===")
    print("[MODEM:" .. modem_name .. "] Version: " .. VERSION)

    -- Check if it's still a valid modem
    local modem_type = "unknown"
    if modem.isWireless then
        modem_type = modem.isWireless() and "wireless" or "wired"
    end
    print("[MODEM:" .. modem_name .. "] Type: " .. modem_type)

    -- Check which channels are open
    local open_channels = {}
    for i = 0, 65535 do
        if modem.isOpen(i) then
            table.insert(open_channels, tostring(i))
        end
    end
    print("[MODEM:" .. modem_name .. "] Open channels: " .. (#open_channels > 0 and table.concat(open_channels, ", ") or "NONE"))

    -- Check if expected channel is open
    if expected_channel and not modem.isOpen(expected_channel) then
        print("[MODEM:" .. modem_name .. "] WARNING: Expected channel " .. expected_channel .. " is NOT open!")
        print("[MODEM:" .. modem_name .. "] Attempting to reopen channel " .. expected_channel .. "...")
        modem.open(expected_channel)
        if modem.isOpen(expected_channel) then
            print("[MODEM:" .. modem_name .. "] Successfully reopened channel " .. expected_channel)
        else
            print("[MODEM:" .. modem_name .. "] ERROR: Failed to reopen channel " .. expected_channel)
            return false
        end
    elseif expected_channel then
        print("[MODEM:" .. modem_name .. "] Expected channel " .. expected_channel .. " is open: OK")
    end

    print("[MODEM:" .. modem_name .. "] Health check: PASSED")
    return true
end

-- ============================================================================
-- SHARED: DISPLAY & ANIMATIONS
-- ============================================================================

local display = {}

-- Find monitor or use terminal
function display.getOutput()
    local monitor = peripheral.find("monitor")
    if monitor then
        return monitor
    end
    return term.current()
end

-- Center text on a line
function display.centerText(output, y, text, textColor, bgColor)
    local w, h = output.getSize()
    local x = math.floor((w - #text) / 2) + 1

    if textColor then output.setTextColor(textColor) end
    if bgColor then output.setBackgroundColor(bgColor) end

    output.setCursorPos(x, y)
    output.write(text)
end

-- Draw a horizontal line
function display.drawLine(output, y, char, color)
    local w, h = output.getSize()
    if color then output.setTextColor(color) end
    output.setCursorPos(1, y)
    output.write(string.rep(char or "=", w))
end

-- Clear with color
function display.clear(output, bgColor)
    if bgColor then output.setBackgroundColor(bgColor) end
    output.clear()
    output.setCursorPos(1, 1)
end

-- ============================================================================
-- ANIMATION SYSTEM
-- ============================================================================

local anim = {}

-- Spinner frames (for IN TRANSIT)
anim.spinners = {
    {"|", "/", "-", "\\"},  -- Classic spinner
    {".", "..", "...", ".."},  -- Dot loader
    {"(   )", "( . )", "(  .)", "( . )", "(. )"},  -- Traveling dot
    {"[    ]", "[=   ]", "[==  ]", "[=== ]", "[====]", "[ ===]", "[  ==]", "[   =]"}  -- Progress bar
}

-- Status icons with Minecraft-friendly characters
anim.icons = {
    on_time = "[" .. string.char(251) .. "]",  -- √ checkmark
    delayed = "[!!]",
    early = "[^^]",
    waiting = "[ ]",
    present = "[##]",
    transit = "[>>]",
    boarding = "[==]",
    departing = "[<<]"
}

-- Get spinner frame
function anim.getSpinner(frame, style, fixed_width)
    style = style or 1
    local spinner = anim.spinners[style]
    local result = spinner[(frame % #spinner) + 1]

    -- Pad to fixed width if requested
    if fixed_width then
        local padding = fixed_width - #result
        if padding > 0 then
            result = result .. string.rep(" ", padding)
        end
    end

    return result
end

-- Get flashing state (for urgent alerts)
function anim.shouldFlash(frame, frequency)
    frequency = frequency or 2  -- Flash every N frames
    return (frame % (frequency * 2)) < frequency
end

-- Cycle through colors (for attention-grabbing elements)
function anim.cycleColor(frame, colors_list)
    return colors_list[(frame % #colors_list) + 1]
end

-- Progress bar generator
function anim.progressBar(progress, width, filled_char, empty_char)
    filled_char = filled_char or "="
    empty_char = empty_char or " "
    local filled_width = math.floor(progress * width)
    local empty_width = width - filled_width
    return string.rep(filled_char, filled_width) .. string.rep(empty_char, empty_width)
end

-- ============================================================================
-- CONFIGURATION DETECTION
-- ============================================================================

local CONFIG_FILE = "/.transit_config"

-- ===================================================================
-- SCRIPT-AUTHORITATIVE CONFIG
-- These values are ALWAYS used from the script and can be updated
-- remotely by pushing new versions of transit.lua via update.lua
-- ===================================================================
local SCRIPT_STATION_CONFIG = {
    network_channel = 100,         -- Network channel for modem communication
    heartbeat_interval = 5,        -- Seconds between heartbeat messages
    status_send_interval = 0.5,    -- Seconds between status updates
    display_update_interval = 0.5, -- Seconds between display redraws (faster = smoother)
    powered_rail_duration = 4,     -- Seconds to keep powered rail active
    trip_history_size = 10,        -- Number of trips to track for timing average
    on_time_tolerance = 0.10,      -- ±10% = on time
    early_threshold = -0.05,       -- >5% early = EARLY
    delayed_threshold = 0.1,      -- >5% late = DELAYED
    departing_delay = 3.5            -- Seconds in DEPARTING state before cart leaves
}

local SCRIPT_OPS_CONFIG = {
    network_channel = 100,         -- Network channel for modem communication
    discovery_interval = 10,        -- Seconds between discovery broadcasts
    dispatch_check_interval = 1,  -- Seconds between dispatch checks
    display_update_interval = 1,    -- Seconds between display redraws
    dispatch_delay = 1,            -- Seconds to wait before dispatching (ensures audio completes + boarding time)
    countdown_enabled = true,       -- Broadcast countdown messages during delay
    github_url = "https://raw.githubusercontent.com/fractaal/councilcraft-transit-network/main/transit.lua"  -- GitHub raw URL for remote updates
}

-- ===================================================================
-- PER-STATION CONFIG (stored in .transit_config)
-- These are station-specific settings that differ per deployment:
-- - type (station or ops)
-- - station_id, line_id (identity, stations only)
-- - detector_side, powered_rail_side (hardware wiring, stations only)
-- - has_display (hardware presence)
-- ===================================================================

-- Save per-station config to file (ONLY station-specific settings)
local function saveConfig(config)
    local file = fs.open(CONFIG_FILE, "w")
    file.write(textutils.serialize(config))
    file.close()
end

-- Build runtime config by merging script-authoritative settings with per-station settings
local function buildRuntimeConfig(stored_config)
    local script_defaults = stored_config.type == "station" and SCRIPT_STATION_CONFIG or SCRIPT_OPS_CONFIG

    -- Start with script-authoritative settings (these ALWAYS come from the script)
    local runtime_config = {}
    for key, value in pairs(script_defaults) do
        runtime_config[key] = value
    end

    -- Overlay per-station settings from stored config
    for key, value in pairs(stored_config) do
        runtime_config[key] = value
    end

    return runtime_config
end

-- Migrate old configs: remove script-authoritative keys from stored config
local function migrateConfig(stored_config)
    local script_keys = stored_config.type == "station" and SCRIPT_STATION_CONFIG or SCRIPT_OPS_CONFIG

    -- Remove any script-authoritative keys from stored config
    for key, _ in pairs(script_keys) do
        stored_config[key] = nil
    end

    return stored_config
end

-- Load config from file and merge with script-authoritative settings
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local file = fs.open(CONFIG_FILE, "r")
        local content = file.readAll()
        file.close()
        local stored_config = textutils.unserialize(content)

        if stored_config then
            -- Migrate: clean up old script-authoritative keys from stored config
            stored_config = migrateConfig(stored_config)
            saveConfig(stored_config)  -- Save cleaned config

            -- Build final runtime config by merging script + stored
            return buildRuntimeConfig(stored_config)
        end
    end
    return nil
end

-- ============================================================================
-- STATE PERSISTENCE (for surviving server reboots)
-- ============================================================================

local STATE_FILE = "/.transit_state"

-- Save station runtime state to disk
local function saveState(state_data)
    local file = fs.open(STATE_FILE, "w")
    file.write(textutils.serialize(state_data))
    file.close()
end

-- Load station runtime state from disk
local function loadState()
    if fs.exists(STATE_FILE) then
        local file = fs.open(STATE_FILE, "r")
        local content = file.readAll()
        file.close()
        return textutils.unserialize(content)
    end
    return nil
end

local function configureStation()
    print("Station Configuration")
    print("=====================")
    print("")
    write("Station ID (e.g., 'station_alpha'): ")
    local station_id = read()

    write("Line ID (e.g., 'red_line'): ")
    local line_id = read()

    print("")
    print("Redstone sides: top, bottom, left, right, front, back")
    write("Detector rail input side: ")
    local detector_side = read()

    write("Powered rail output side: ")
    local powered_rail_side = read()

    print("")
    print("Network Modem Configuration")
    print("---------------------------")
    print("If you have multiple modems, specify which side the NETWORK modem is on.")
    print("Sides: top, bottom, left, right, front, back")
    write("Network modem side (or press Enter to auto-detect): ")
    local modem_side = read()
    if modem_side == "" then
        modem_side = nil
    end

    print("")
    write("Has monitors? (y/n): ")
    local has_display = read()
    has_display = (has_display == "y" or has_display == "Y")

    -- Return ONLY per-station settings (script-authoritative settings come from script)
    return {
        type = "station",
        station_id = station_id,
        line_id = line_id,
        detector_side = detector_side,
        powered_rail_side = powered_rail_side,
        modem_side = modem_side,
        has_display = has_display
    }
end

local function configureOps()
    print("Operations Center Configuration")
    print("================================")
    print("")
    print("Network Modem Configuration")
    print("---------------------------")
    print("If you have multiple modems, specify which side the NETWORK modem is on.")
    print("Sides: top, bottom, left, right, front, back")
    write("Network modem side (or press Enter to auto-detect): ")
    local modem_side = read()
    if modem_side == "" then
        modem_side = nil
    end

    -- Return ONLY per-station settings (script-authoritative settings come from script)
    return {
        type = "ops",
        modem_side = modem_side
    }
end

local function initialSetup()
    term.clear()
    term.setCursorPos(1, 1)
    print("CouncilCraft Transit Network")
    print("v0.9 Setup")
    print("========================")
    print("")
    print("What is this computer?")
    print("1) Station Terminal")
    print("2) Operations Center")
    print("")
    write("Choice (1 or 2): ")
    local choice = read()

    local stored_config
    if choice == "1" then
        print("")
        stored_config = configureStation()
    elseif choice == "2" then
        print("")
        stored_config = configureOps()
    else
        print("Invalid choice!")
        sleep(2)
        os.reboot()
    end

    saveConfig(stored_config)
    print("")
    print("Configuration saved!")
    print("Rebooting...")
    sleep(2)
    os.reboot()
end

-- ============================================================================
-- AUDIO SYSTEM (Singapore MRT-inspired sounds!)
-- ============================================================================

local audio = {}

-- ============================================================================
-- AUDIO CONFIGURATION
-- ============================================================================
-- Replace BASE_URL with your actual GitHub raw URL
-- Example: "https://raw.githubusercontent.com/username/repo/main/sounds/"

audio.config = {
    -- Base URL for all sound files (set this to your GitHub raw sounds folder)
    base_url = "https://raw.githubusercontent.com/fractaal/councilcraft-transit-network/main/sounds/",

    -- Cache directory for downloaded sounds
    cache_dir = "/sounds/",

    -- Enable/disable DFPWM playback (fallback to noteblock if false or download fails)
    enable_dfpwm = true,

    -- Preload all sounds on startup (recommended for smooth playback)
    preload_sounds = true
}

-- ============================================================================
-- AUDIO LIBRARY MANIFEST
-- ============================================================================
-- Define all available sound files here

audio.library = {
    -- Chimes
    SG_MRT_BELL = "SG_MRT_BELL.dfpwm",  -- Generic Singapore MRT arrival bell

    -- Station-specific announcements (V2 versions)
    ARRIVAL_GENERIC = "ARRIVAL_GENERIC.dfpwm",
    ARRIVAL_CLOUD_DISTRICT_V2 = "ARRIVAL_CLOUD_DISTRICT_V2.dfpwm",
    ARRIVAL_DRAGONSREACH_V2 = "ARRIVAL_DRAGONSREACH_V2.dfpwm",
    ARRIVAL_PLAINS_DISTRICT_V2 = "ARRIVAL_PLAINS_DISTRICT_V2.dfpwm",
    ARRIVAL_RICARDOS_V2 = "ARRIVAL_RICARDOS_V2.dfpwm",

    -- Hints and instructions (V2 version)
    ALIGHT_HINT_V2 = "ALIGHT_HINT_V2.dfpwm",
    ALIGHT_HINT_V3 = "ALIGHT_HINT_V3.dfpwm",

    LOOPS_HERE_BEFORE_NAME = "LOOPS_HERE_BEFORE_NAME.dfpwm",
    LOOPS_HERE_AFTER_NAME = "LOOPS_HERE_AFTER_NAME.dfpwm",

    OTHER_TERMINATES_HERE = "OTHER_TERMINATES_HERE.dfpwm",

    -- Departure sounds
    DEPARTURE_CART_DEPARTING = "DEPARTURE_CART_DEPARTING.dfpwm",

    -- System announcements
    MAINTENANCE = "MAINTENANCE.dfpwm",
    DELAYED = "DELAYED.dfpwm"
}

-- ============================================================================
-- STATION ID MAPPING
-- ============================================================================
-- Map friendly station IDs (as configured) to sequence keys
-- Add your stations here with their friendly names as keys

audio.station_map = {
    -- Friendly Station Name → Sequence Key
    ["Cloud District (to"] = "CLOUD_DISTRICT_ABRIDGED",
    ["Cloud District"] = "CLOUD_DISTRICT",
    ["Dragonsreach"] = "DRAGONSREACH",
    ["Plains District"] = "PLAINS_DISTRICT",
    ["Ricardo's"] = "RICARDOS",
    ["Ricardo's (to"] = "RICARDOS_ABRIDGED",

    -- Add more stations here as you expand:
    -- ["Station Name"] = "SEQUENCE_KEY",
}

-- ============================================================================
-- AUDIO SEQUENCES (Per-Station Configuration)
-- ============================================================================
-- Define multi-sound sequences for each station
-- Sequences play in order with automatic spacing between sounds

audio.sequences = {
    -- Station-specific arrival sequences

    -- Line 1 sequence, in order

    PLAINS_DISTRICT = {
        "SG_MRT_BELL",
        "LOOPS_HERE_BEFORE_NAME",
        "ARRIVAL_PLAINS_DISTRICT_V2",
        "ALIGHT_HINT_V3"
    },

    CLOUD_DISTRICT = {
        "SG_MRT_BELL",
        "ARRIVAL_CLOUD_DISTRICT_V2",
        "ALIGHT_HINT_V3"
    },

    CLOUD_DISTRICT_ABRIDGED = {
        "SG_MRT_BELL"
    },

    RICARDOS = {
        "SG_MRT_BELL",
        "ARRIVAL_RICARDOS_V2",
    },

    RICARDOS_ABRIDGED = {
        "SG_MRT_BELL"
    },

    DRAGONSREACH = {
        "SG_MRT_BELL",
        "LOOPS_HERE_BEFORE_NAME",
        "ARRIVAL_DRAGONSREACH_V2",
        "ALIGHT_HINT_V3"
    },

    -- Fallback sequence (used if station_id doesn't match)
    _FALLBACK = {
        "SG_MRT_BELL",
        "ARRIVAL_GENERIC"
    },

    -- Departure sequence (same for all stations)
    _DEPARTURE = {
        "DEPARTURE_CART_DEPARTING"
    },

    -- Maintenance announcement (shutdown mode)
    _MAINTENANCE = {
        "MAINTENANCE"
    }
}

-- ============================================================================
-- DFPWM AUDIO SYSTEM
-- ============================================================================

-- Audio cache (in-memory storage of loaded sounds)
audio.cache = {}
audio.cache_initialized = false

-- Download and cache a sound file
function audio.downloadSound(filename)
    if not audio.config.enable_dfpwm then return nil end
    if not audio.config.base_url or audio.config.base_url == "" or audio.config.base_url:sub(1, 11) == "PLACEHOLDER" then
        return nil
    end

    local cache_path = audio.config.cache_dir .. filename
    local url = audio.config.base_url .. filename

    -- Check cache first
    if fs.exists(cache_path) then
        local file = fs.open(cache_path, "rb")
        if file then
            local data = file.readAll()
            file.close()
            return data
        end
    end

    -- Download from URL
    local response = http.get(url)
    if response then
        local data = response.readAll()
        response.close()

        -- Cache it for future use
        if not fs.exists(audio.config.cache_dir) then
            fs.makeDir(audio.config.cache_dir)
        end

        local file = fs.open(cache_path, "wb")
        if file then
            file.write(data)
            file.close()
        end

        return data
    end

    return nil
end

-- Preload all sounds from library into memory
function audio.preloadAll()
    if not audio.config.enable_dfpwm or not audio.config.preload_sounds then
        audio.cache_initialized = true
        return
    end

    print("Preloading audio library...")
    local loaded = 0
    local total = 0

    for name, filename in pairs(audio.library) do
        total = total + 1
        local data = audio.downloadSound(filename)
        if data then
            audio.cache[name] = data
            loaded = loaded + 1
            print("  [OK] " .. name)
        else
            print("  [SKIP] " .. name .. " (download failed)")
        end
    end

    audio.cache_initialized = true
    print("Loaded " .. loaded .. "/" .. total .. " sounds")
end

-- Get sound data (from cache or download)
function audio.getSound(sound_name)
    -- Check in-memory cache first
    if audio.cache[sound_name] then
        return audio.cache[sound_name]
    end

    -- Try to download and cache
    local filename = audio.library[sound_name]
    if filename then
        local data = audio.downloadSound(filename)
        if data then
            audio.cache[sound_name] = data
            return data
        end
    end

    return nil
end

-- DFPWM decoder (shared across all audio playback)
audio.decoder = nil

-- Play a single DFPWM audio file (supports large files via chunking)
function audio.playDFPWM(speaker, dfpwm_data, volume)
    if not speaker then return false end
    if not dfpwm_data then return false end

    -- Lazy-load the DFPWM decoder
    if not audio.decoder then
        local dfpwm = require("cc.audio.dfpwm")
        audio.decoder = dfpwm.make_decoder()
    end

    -- Process audio in chunks (max 16KB DFPWM at a time)
    -- This is necessary because speaker.playAudio has a buffer limit
    local chunk_size = 16 * 1024  -- 16KB chunks
    local pos = 1

    while pos <= #dfpwm_data do
        -- Extract chunk
        local chunk_end = math.min(pos + chunk_size - 1, #dfpwm_data)
        local chunk = dfpwm_data:sub(pos, chunk_end)

        -- Decode DFPWM chunk to PCM
        local pcm_audio = audio.decoder(chunk)

        -- Try to play this chunk
        local success, err = pcall(function()
            while not speaker.playAudio(pcm_audio, volume or 1.0) do
                -- Wait for speaker buffer to have space
                os.pullEvent("speaker_audio_empty")
            end
        end)

        if not success then
            print("[AUDIO] playAudio error: " .. tostring(err))
            return false
        end

        pos = pos + chunk_size
    end

    return true
end

-- Play a sequence of sounds (blocking, waits for each to finish)
function audio.playSequence(speaker, sequence_name, station_id)
    if not speaker then return false end

    -- Determine which sequence to use
    local sequence = nil
    if sequence_name == "arrival" then
        -- Look up station in mapping table using "contains" logic
        local sequence_key = nil
        if station_id then
            -- Try to find a match where station_id contains any of the mapping keys
            for friendly_name, seq_key in pairs(audio.station_map) do
                if string.find(station_id, friendly_name, 1, true) then
                    -- Found a match! (plain text search, case-sensitive)
                    sequence_key = seq_key
                    print("[AUDIO] Station '" .. station_id .. "' contains '" .. friendly_name .. "' → sequence '" .. sequence_key .. "'")
                    break
                end
            end

            if not sequence_key then
                print("[AUDIO] Station '" .. tostring(station_id) .. "' does not match any mapping, using fallback")
            end
        else
            print("[AUDIO] No station_id provided, using fallback")
        end

        -- Get the sequence
        if sequence_key and audio.sequences[sequence_key] then
            sequence = audio.sequences[sequence_key]
        else
            -- Fallback to generic if not found
            sequence = audio.sequences._FALLBACK
        end
    elseif sequence_name == "departure" then
        sequence = audio.sequences._DEPARTURE
    elseif sequence_name == "maintenance" then
        sequence = audio.sequences._MAINTENANCE
    else
        return false
    end

    if not sequence then return false end

    -- Play each sound in the sequence
    for _, sound_name in ipairs(sequence) do
        local audio_data = audio.getSound(sound_name)
        if audio_data then
            print("[AUDIO] Playing: " .. sound_name .. " (" .. #audio_data .. " bytes)")

            -- Play sound
            if not audio.playDFPWM(speaker, audio_data, 1.0) then
                print("[AUDIO] Failed to play DFPWM: " .. sound_name)
                return false  -- Failed to play, stop sequence
            end

            -- Wait for sound to finish (estimate: ~6KB per second of DFPWM)
            local duration = #audio_data / 6000
            sleep(duration + 0.1)  -- Small buffer between sounds
        else
            print("[AUDIO] No data for: " .. sound_name)
        end
    end

    print("[AUDIO] Sequence complete!")
    return true
end

-- ============================================================================
-- NOTEBLOCK FALLBACK SYSTEM
-- ============================================================================

-- Note pitches (semitones, where 12 = F#, relative to noteblock scale)
-- F# is at 0, 12, 24. C is at 6, 18. Each semitone = 1 step.
-- F#3=0, G3=1, A3=3, B3=5, C4=6, D4=8, E4=10, F#4=12, G4=13, A4=15, B4=17, C5=18
audio.notes = {
    G3 = 1,   -- One semitone above F#
    B3 = 5,   -- Five semitones above F#
    D4 = 8,   -- Eight semitones above F#
    G4 = 13,  -- 13 semitones above F#
    F5 = 23   -- High F for door closing chirp
}

-- Noteblock fallback: G3->D4->B3->G4->D4 (Singapore MRT inspired)
function audio.playArrivalChimeNoteblock(speaker)
    if not speaker then return end

    local sequence = {
        {audio.notes.G3, 0.3},   -- 2x slower (was 0.15)
        {audio.notes.D4, 0.3},   -- 2x slower (was 0.15)
        {audio.notes.B3, 0.3},   -- 2x slower (was 0.15)
        {audio.notes.G4, 0.3},   -- 2x slower (was 0.15)
        {audio.notes.D4, 0.6}    -- 2x slower (was 0.3)
    }

    for _, note_data in ipairs(sequence) do
        local pitch, duration = note_data[1], note_data[2]
        speaker.playNote("bell", 1.0, pitch)
        sleep(duration)
    end
end

-- Noteblock fallback: Single chirp
function audio.playDoorClosingChirpNoteblock(speaker)
    if not speaker then return end
    speaker.playNote("pling", 0.8, audio.notes.F5)
end

-- ============================================================================
-- PUBLIC API (with automatic fallback)
-- ============================================================================

-- Play arrival sequence: Tries DFPWM sequence first, falls back to noteblock
function audio.playArrivalChime(speaker, station_id)
    if not speaker then return end

    -- Try DFPWM sequence
    if audio.playSequence(speaker, "arrival", station_id) then
        return  -- Success!
    end

    -- Fallback to noteblock
    audio.playArrivalChimeNoteblock(speaker)
end

-- Play door closing chirp: Tries DFPWM first, falls back to noteblock
-- This should be called repeatedly in a loop until departure
function audio.playDoorClosingChirp(speaker)
    if not speaker then return end

    -- Try DFPWM departure sound
    local audio_data = audio.getSound("DEPARTURE_CART_DEPARTING")
    if audio_data and audio.playDFPWM(speaker, audio_data, 0.8) then
        return  -- Success!
    end

    -- Fallback to noteblock
    audio.playDoorClosingChirpNoteblock(speaker)
end

-- ============================================================================
-- STATION MODE
-- ============================================================================

local function runStation(config)
    -- Load persisted state if exists (for surviving reboots)
    local saved_state = loadState()

    -- State
    local state = "IN_TRANSIT"  -- IN_TRANSIT, ARRIVED, BOARDING, DEPARTING, SHUTDOWN
    local cart_present = false
    local last_heartbeat = 0
    local last_status_send = 0
    local modem = nil
    local speaker = nil  -- Auto-discovered speaker

    -- Trip timing
    local trip_history = {}  -- Array of trip durations in seconds
    local trip_start_time = nil  -- When cart departed (start of current trip)
    local trip_status = "N/A"  -- "ON TIME", "EARLY", "DELAYED", "N/A"

    -- Departing state timer
    local departing_start_time = nil
    local departure_sound_played = false  -- Track if departure sound has been played

    -- Restore saved state if available
    if saved_state then
        state = saved_state.state or "IN_TRANSIT"
        cart_present = saved_state.cart_present or false
        trip_history = saved_state.trip_history or {}
        trip_start_time = saved_state.trip_start_time

        -- Reset transient states (ARRIVED, DEPARTING) to BOARDING on cold boot
        if state == "ARRIVED" or state == "DEPARTING" then
            state = "BOARDING"
        end

        print("Restored state: " .. state)
    end

    -- Setup
    term.clear()
    term.setCursorPos(1, 1)
    print("CouncilCraft Transit Network")
    print("Station Controller " .. VERSION)
    print("========================")
    print("")
    print("Station ID: " .. config.station_id)
    print("Line ID: " .. config.line_id)
    print("")
    print("Opening modem...")

    modem = network.openModem(config.network_channel, config.modem_side)
    print("Modem opened on channel " .. config.network_channel)

    -- Auto-discover speaker
    speaker = peripheral.find("speaker")
    if speaker then
        print("Speaker found! Audio enabled.")
    else
        print("No speaker found. Audio disabled.")
    end

    -- Preload audio library
    print("")
    audio.preloadAll()
    print("")

    print("Waiting for DISCOVER from ops center...")
    print("")

    -- Check detector rail
    local function checkDetector()
        return redstone.getInput(config.detector_side)
    end

    -- Activate powered rail
    local function activatePoweredRail(active)
        redstone.setOutput(config.powered_rail_side, active)
    end

    -- Calculate average trip time (MUST be defined before sendStatus!)
    local function getAverageTripTime()
        if #trip_history == 0 then return nil end
        local sum = 0
        for _, duration in ipairs(trip_history) do
            sum = sum + duration
        end
        return sum / #trip_history
    end

    -- Calculate trip status (ON TIME/EARLY/DELAYED)
    local function calculateTripStatus(trip_duration)
        local avg = getAverageTripTime()
        if not avg then return "N/A" end

        local deviation = (trip_duration - avg) / avg

        if deviation < config.early_threshold then
            return "EARLY"
        elseif deviation > config.delayed_threshold then
            return "DELAYED"
        else
            return "ON TIME"
        end
    end

    -- Get current trip duration (in real-time during transit)
    local function getCurrentTripDuration()
        if not trip_start_time then return nil end
        local now = os.epoch("utc") / 1000
        return now - trip_start_time
    end

    -- Calculate real-time trip status (during transit)
    local function getCurrentTripStatus()
        local current_duration = getCurrentTripDuration()
        if not current_duration then return "N/A", nil end

        local avg = getAverageTripTime()
        if not avg then return "N/A", current_duration end

        return calculateTripStatus(current_duration), current_duration
    end

    -- Record trip completion
    local function recordTrip(duration)
        table.insert(trip_history, duration)
        if #trip_history > config.trip_history_size then
            table.remove(trip_history, 1)  -- Remove oldest
        end
        trip_status = calculateTripStatus(duration)
        print("[" .. os.date("%H:%M:%S") .. "] Trip: " .. string.format("%.1f", duration) .. "s (" .. trip_status .. ")")
    end

    -- Send status (uses getAverageTripTime, so must come after)
    local function sendStatus()
        local avg = getAverageTripTime()
        local current_status, current_duration = getCurrentTripStatus()

        -- Use real-time status if in transit, otherwise use last recorded
        local status_to_send = (state == "IN_TRANSIT" and current_status ~= "N/A") and current_status or trip_status

        local msg = protocol.createStatus(config.station_id, cart_present, status_to_send, avg, state, VERSION)
        -- Add current trip duration for real-time display
        msg.current_trip_duration = current_duration

        network.send(modem, config.network_channel, msg)
    end

    -- Save current state to disk (for surviving reboots)
    local function persistState()
        saveState({
            state = state,
            cart_present = cart_present,
            trip_history = trip_history,
            trip_start_time = trip_start_time
        })
    end

    -- Send heartbeat
    local function sendHeartbeat()
        local msg = protocol.createHeartbeat(config.station_id)
        network.send(modem, config.network_channel, msg)
    end

    -- Handle discovery
    local function handleDiscover(msg)
        print("DISCOVER received from " .. msg.from)
        print("Registering with ops center...")

        local registerMsg = protocol.createRegister(
            config.station_id,
            config.line_id,
            config.has_display
        )

        network.send(modem, config.network_channel, registerMsg)
        print("REGISTER sent!")
    end

    -- Handle dispatch
    local function handleDispatch(msg)
        if msg.target == "ALL" or msg.target == config.station_id then
            print("DISPATCH received!")

            -- Allow DISPATCH to exit SHUTDOWN mode
            if state == "SHUTDOWN" then
                print("Exiting maintenance mode...")
            end

            state = "DEPARTING"
            departing_start_time = os.epoch("utc") / 1000
            persistState()  -- Save state change immediately
            sendStatus()
        end
    end

    -- Handle shutdown (maintenance mode)
    local function handleShutdown(msg)
        if msg.target == "ALL" or msg.target == config.station_id then
            print("SHUTDOWN received! Entering maintenance mode...")
            state = "SHUTDOWN"
            persistState()  -- Save state immediately (critical for reboots!)
            sendStatus()

            -- Play maintenance announcement
            audio.playSequence(speaker, "maintenance", config.station_id)
        end
    end

    -- Handle update command
    local function handleUpdate(msg)
        if msg.target == "ALL" or msg.target == config.station_id then
            print("")
            print("[UPDATE] Remote update command received!")

            -- Safety check for github_url
            if not msg.github_url or msg.github_url == "" then
                print("[UPDATE] ERROR: No GitHub URL provided in update command!")
                return
            end

            print("[UPDATE] GitHub URL: " .. msg.github_url)
            print("[UPDATE] Deleting old version...")

            -- Delete all possible startup file locations
            local startup_files = {"startup/transit.lua", "startup.lua", "transit.lua"}
            for _, file in ipairs(startup_files) do
                if fs.exists(file) then
                    fs.delete(file)
                    print("[UPDATE] Deleted: " .. file)
                end
            end

            -- Create startup directory if needed
            if not fs.exists("startup") then
                fs.makeDir("startup")
            end

            print("[UPDATE] Downloading from GitHub...")
            local target_file = "startup/transit.lua"

            -- Download from GitHub using http.get()
            local response = http.get(msg.github_url)
            if not response then
                print("[UPDATE] ERROR: Failed to download from GitHub!")
                print("[UPDATE] System may be broken - manual fix required")
                return
            end

            local content = response.readAll()
            response.close()

            -- Write to file
            local file = fs.open(target_file, "w")
            file.write(content)
            file.close()

            print("[UPDATE] Download complete!")
            print("[UPDATE] Rebooting in 2 seconds...")
            sleep(2)
            os.reboot()
        end
    end

    -- Handle messages
    local function handleMessage(msg)
        if msg.type == protocol.DISCOVER then
            handleDiscover(msg)
        elseif msg.type == protocol.DISPATCH then
            handleDispatch(msg)
        elseif msg.type == protocol.SHUTDOWN then
            handleShutdown(msg)
        elseif msg.type == protocol.UPDATE_COMMAND then
            handleUpdate(msg)
        end
    end

    -- Display status on monitor (if available)
    local mon = config.has_display and display.getOutput() or nil
    local anim_frame = 0
    local function displayStationStatus()
        if not mon then return end

        display.clear(mon, colors.black)
        local w, h = mon.getSize()

        -- Animated header with box drawing
        display.centerText(mon, 1, string.rep("-", w - 4), colors.gray, colors.black)
        display.centerText(mon, 2, "COUNCILCRAFT TRANSIT", colors.white, colors.black)
        display.centerText(mon, 3, string.rep("-", w - 4), colors.gray, colors.black)

        -- Line info with colored badge
        mon.setCursorPos(2, 5)
        mon.setTextColor(colors.black)
        mon.setBackgroundColor(colors.cyan)
        mon.write(" " .. string.upper(config.line_id) .. " ")
        mon.setBackgroundColor(colors.black)

        mon.setCursorPos(2, 6)
        mon.setTextColor(colors.lightGray)
        mon.write("Station: " .. config.station_id)

        -- State icon and status with animations
        local statusIcon
        local statusText
        local statusColor
        local shouldAnimate = false
        local secondaryAnim = ""

        if state == "SHUTDOWN" then
            statusIcon = "[XX]"
            statusText = "MAINTENANCE"
            statusColor = colors.red
            -- Flash for visibility
            if anim.shouldFlash(anim_frame, 2) then
                statusColor = colors.orange
            end
        elseif state == "DEPARTING" then
            statusIcon = anim.icons.departing
            statusText = "DEPARTING"
            statusColor = colors.orange
            -- Add departure countdown animation
            secondaryAnim = anim.getSpinner(anim_frame, 4)  -- Progress bar style
        elseif state == "BOARDING" then
            statusIcon = anim.icons.boarding
            statusText = "BOARDING"
            statusColor = colors.lime
            -- Gentle pulsing effect
            if anim.shouldFlash(anim_frame, 3) then
                statusColor = colors.lightGray
            end
        elseif state == "ARRIVED" then
            statusIcon = anim.icons.present
            statusText = "ARRIVED"
            statusColor = colors.cyan
            -- Spinner to show announcements playing
            shouldAnimate = true
            secondaryAnim = anim.getSpinner(anim_frame, 2)  -- Dot loader
        else  -- IN_TRANSIT
            statusIcon = anim.icons.transit
            statusText = "IN TRANSIT"
            statusColor = colors.yellow
            shouldAnimate = true
            secondaryAnim = anim.getSpinner(anim_frame, 2)  -- Dot loader
        end

        mon.setCursorPos(2, 9)
        mon.setTextColor(colors.gray)
        mon.write("STATUS:")

        mon.setCursorPos(2, 10)
        mon.setTextColor(statusColor)
        mon.write(statusIcon .. " " .. statusText)

        -- Animated secondary indicator
        if shouldAnimate or state == "DEPARTING" then
            display.centerText(mon, 11, secondaryAnim, statusColor, colors.black)
        end

        -- Maintenance message (only shown in SHUTDOWN state)
        if state == "SHUTDOWN" then
            mon.setCursorPos(2, 13)
            mon.setTextColor(colors.red)
            mon.write("MRT UNDER MAINTENANCE")

            mon.setCursorPos(2, 15)
            mon.setTextColor(colors.gray)
            mon.write("The Ministry of Science")
            mon.setCursorPos(2, 16)
            mon.write("and Technology apologizes")
            mon.setCursorPos(2, 17)
            mon.write("for the inconvenience and")
            mon.setCursorPos(2, 18)
            mon.write("thanks you for your")
            mon.setCursorPos(2, 19)
            mon.write("continued patronage.")
        end

        -- Trip timing status with real-time monitoring
        local current_status, current_duration = getCurrentTripStatus()
        local avg = getAverageTripTime()

        -- Show timing section if we have data
        if (current_status ~= "N/A" or trip_status ~= "N/A") and avg then
            local displayStatus = current_status ~= "N/A" and current_status or trip_status
            local timingIcon
            local timingColor
            local shouldFlash = false

            if displayStatus == "ON TIME" then
                timingIcon = anim.icons.on_time
                timingColor = colors.lime
            elseif displayStatus == "EARLY" then
                timingIcon = anim.icons.early
                timingColor = colors.cyan
            elseif displayStatus == "DELAYED" then
                timingIcon = anim.icons.delayed
                timingColor = colors.red
                shouldFlash = true
            end

            -- Flash DELAYED status for urgency
            local displayColor = timingColor
            if shouldFlash and not anim.shouldFlash(anim_frame, 2) then
                displayColor = colors.gray
            end

            mon.setCursorPos(2, 13)
            mon.setTextColor(colors.gray)
            mon.write("TIMING:")

            mon.setCursorPos(2, 14)
            mon.setTextColor(displayColor)
            mon.write(timingIcon .. " " .. displayStatus)

            -- Show real-time trip progress
            if state == "IN_TRANSIT" and current_duration then
                local eta = avg - current_duration
                mon.setCursorPos(2, 15)
                mon.setTextColor(displayColor)
                mon.write("Arriving in " .. string.format("%.0f", math.max(0, eta)) .. "s")

                -- Show current vs average with color coding
                mon.setCursorPos(2, 16)
                mon.setTextColor(colors.gray)
                mon.write("Trip: ")
                mon.setTextColor(displayColor)
                mon.write(string.format("%.0f", current_duration) .. "s")
                mon.setTextColor(colors.gray)
                mon.write(" / ")
                mon.setTextColor(colors.lightGray)
                mon.write(string.format("%.0f", avg) .. "s")
            else
                -- Show average with progress bar when not in transit
                if #trip_history > 0 then
                    mon.setCursorPos(2, 15)
                    mon.setTextColor(colors.gray)
                    mon.write("Avg: " .. string.format("%.1f", avg) .. "s")

                    -- Visual history indicator
                    local barWidth = math.min(w - 4, 20)
                    local progress = #trip_history / config.trip_history_size
                    local bar = anim.progressBar(progress, barWidth, "=", "-")
                    mon.setCursorPos(2, 16)
                    mon.setTextColor(colors.blue)
                    mon.write("[" .. bar .. "]")
                    mon.setCursorPos(w - 8, 16)
                    mon.setTextColor(colors.gray)
                    mon.write(#trip_history .. "/" .. config.trip_history_size)
                end
            end
        end

        -- Bottom status bar with time
        display.drawLine(mon, h - 1, "-", colors.gray)
        mon.setCursorPos(2, h)
        mon.setTextColor(colors.gray)
        mon.write(os.date("%H:%M:%S"))

        -- Version indicator
        mon.setCursorPos(math.floor(w / 2) - math.floor(#VERSION / 2), h)
        mon.setTextColor(colors.gray)
        mon.write(VERSION)

        -- Connection indicator (heartbeat)
        mon.setCursorPos(w - 8, h)
        mon.setTextColor(colors.lime)
        mon.write("[ONLINE]")
    end

    -- Main loop
    local last_display_update = 0
    local last_state_save = 0
    local last_modem_check = 0
    while true do
        local now = os.epoch("utc") / 1000

        -- State machine
        if state == "IN_TRANSIT" then
            -- Check for cart arrival
            local detector_active = checkDetector()
            if detector_active and not cart_present then
                cart_present = true
                state = "ARRIVED"

                -- Calculate trip time if we have a start time
                if trip_start_time then
                    local trip_duration = now - trip_start_time
                    recordTrip(trip_duration)
                    trip_start_time = nil  -- Stop timer - trip is complete!
                end

                print("[" .. os.date("%H:%M:%S") .. "] Cart arrived! Status: ARRIVED (playing announcements...)")

                -- Send ARRIVED status immediately so ops center sees the cart
                -- but doesn't start dispatch countdown yet
                sendStatus()

                -- Play arrival chime sequence (station-specific or fallback!)
                -- This is BLOCKING - station won't respond to messages during playback
                audio.playArrivalChime(speaker, config.station_id)

                -- Audio complete! Now ready to accept dispatch
                print("[" .. os.date("%H:%M:%S") .. "] Announcements complete! Status: BOARDING")
                state = "BOARDING"
                sendStatus()
            end

        elseif state == "ARRIVED" then
            -- Wait for audio to complete (handled in IN_TRANSIT transition above)
            -- This state should be very brief, just during audio playback
            -- Nothing to do here - just waiting

        elseif state == "DEPARTING" then
            -- Play departure sound ONCE at the start of DEPARTING state
            if not departure_sound_played then
                audio.playDoorClosingChirp(speaker)  -- Plays "Cart Departing" + chirp audio
                departure_sound_played = true
            end

            -- Non-blocking delay in DEPARTING state
            if now - departing_start_time >= config.departing_delay then
                print("[" .. os.date("%H:%M:%S") .. "] Activating powered rail...")

                -- Activate powered rail for duration (no audio during this - already played)
                activatePoweredRail(true)
                local rail_start = now
                while (os.epoch("utc") / 1000) - rail_start < config.powered_rail_duration do
                    -- Still handle messages/display during rail activation
                    displayStationStatus()
                    local msg, channel = network.receiveWithTimeout(0.05)
                    if msg then handleMessage(msg) end
                end
                activatePoweredRail(false)

                -- Cart has left!
                print("[" .. os.date("%H:%M:%S") .. "] Cart departed! Status: IN TRANSIT")
                state = "IN_TRANSIT"
                cart_present = false
                trip_start_time = os.epoch("utc") / 1000  -- Start timing new trip
                departure_sound_played = false  -- Reset for next departure
                sendStatus()
            end

        elseif state == "SHUTDOWN" then
            -- Station is in maintenance mode - cart parked indefinitely
            -- Just wait for DISPATCH command to exit (handled in handleDispatch)
            -- No actions needed here, station is fully parked
        end
        -- BOARDING state just waits for DISPATCH command

        -- Periodic status
        if now - last_status_send > config.status_send_interval then
            sendStatus()
            last_status_send = now
        end

        -- Heartbeat
        if now - last_heartbeat > config.heartbeat_interval then
            sendHeartbeat()
            last_heartbeat = now
        end

        -- Periodic state persistence (every 5 seconds)
        if now - last_state_save > 5 then
            persistState()
            last_state_save = now
        end

        -- Periodic modem health check (every 30 seconds)
        if now - last_modem_check > 30 then
            network.checkHealth(modem, config.network_channel)
            last_modem_check = now
        end

        -- Update display
        if now - last_display_update > config.display_update_interval then
            displayStationStatus()
            anim_frame = anim_frame + 1
            last_display_update = now
        end

        -- Check messages
        local msg, channel = network.receiveWithTimeout(0.1)
        if msg then
            handleMessage(msg)
        end
    end
end

-- ============================================================================
-- OPS CENTER MODE
-- ============================================================================

local function runOps(config)
    -- State
    local stations = {}
    local modem = nil
    local last_discovery = 0
    local shutdown_requested = false  -- Track maintenance mode request

    -- Setup
    term.clear()
    term.setCursorPos(1, 1)
    print("CouncilCraft Transit Network")
    print("Operations Center " .. VERSION)
    print("========================")
    print("")

    modem = network.openModem(config.network_channel, config.modem_side)
    print("Modem opened on channel " .. config.network_channel)
    print("")
    print("Starting discovery...")
    print("")

    -- Send discovery
    local function sendDiscovery()
        local msg = protocol.createDiscover("ops_center")
        network.broadcast(modem, config.network_channel, msg)
        print("[" .. os.date("%H:%M:%S") .. "] DISCOVER broadcast sent")
    end

    -- Handle registration
    local function handleRegister(msg)
        local station_id = msg.station_id

        if not stations[station_id] then
            -- NEW STATION: Initialize with defaults
            print("[" .. os.date("%H:%M:%S") .. "] NEW STATION: " .. station_id .. " (Line: " .. msg.line_id .. ")")

            stations[station_id] = {
                station_id = station_id,
                line_id = msg.line_id,
                cart_present = false,
                last_heartbeat = os.epoch("utc") / 1000,
                has_display = msg.has_display or false,
                trip_status = "N/A",
                avg_trip_time = nil,
                state = "IN_TRANSIT",
                current_trip_duration = nil,
                last_completed_trip_time = nil,  -- Store the final trip time when cart arrives
                version = "---"  -- Will be updated by STATUS messages
            }
        else
            -- EXISTING STATION: Update identity fields only, preserve runtime state
            print("[" .. os.date("%H:%M:%S") .. "] RE-REGISTER: " .. station_id .. " (preserving state)")

            stations[station_id].station_id = station_id
            stations[station_id].line_id = msg.line_id
            stations[station_id].has_display = msg.has_display or false
            stations[station_id].last_heartbeat = os.epoch("utc") / 1000
            -- cart_present, state, trip_status, avg_trip_time, current_trip_duration,
            -- last_completed_trip_time are preserved from existing state
        end
    end

    -- Handle status
    local function handleStatus(msg)
        local station_id = msg.station_id

        if stations[station_id] then
            local old_status = stations[station_id].cart_present
            stations[station_id].cart_present = msg.cart_present
            stations[station_id].last_heartbeat = os.epoch("utc") / 1000

            -- Update trip timing data
            if msg.trip_status then
                stations[station_id].trip_status = msg.trip_status
            end
            if msg.avg_trip_time then
                stations[station_id].avg_trip_time = msg.avg_trip_time
            end

            -- Update real-time trip duration (only during transit)
            if msg.current_trip_duration and msg.state == "IN_TRANSIT" then
                stations[station_id].current_trip_duration = msg.current_trip_duration
            end

            -- When cart arrives, freeze the trip time
            if old_status ~= msg.cart_present and msg.cart_present then
                -- Cart just arrived - capture the final trip time
                if stations[station_id].current_trip_duration then
                    stations[station_id].last_completed_trip_time = stations[station_id].current_trip_duration
                end
            end

            -- Clear last_completed_trip_time when cart departs (starts new trip)
            if old_status ~= msg.cart_present and not msg.cart_present then
                stations[station_id].last_completed_trip_time = nil
            end

            -- Update state
            if msg.state then
                stations[station_id].state = msg.state
            end

            -- Update version (with fallback for old stations)
            if msg.version then
                stations[station_id].version = msg.version
            end

            if old_status ~= msg.cart_present then
                if msg.cart_present then
                    print("[" .. os.date("%H:%M:%S") .. "] " .. station_id .. ": CART ARRIVED")
                else
                    print("[" .. os.date("%H:%M:%S") .. "] " .. station_id .. ": CART DEPARTED")
                end
            end
        end
    end

    -- Handle heartbeat
    local function handleHeartbeat(msg)
        local station_id = msg.from

        if stations[station_id] then
            stations[station_id].last_heartbeat = os.epoch("utc") / 1000
        end
    end

    -- Handle messages
    local function handleMessage(msg)
        if msg.type == protocol.REGISTER then
            handleRegister(msg)
        elseif msg.type == protocol.STATUS then
            handleStatus(msg)
        elseif msg.type == protocol.HEARTBEAT then
            handleHeartbeat(msg)
        end
    end

    -- Check all carts present AND ready (in BOARDING state, not just ARRIVED)
    local function checkAllCartsPresent()
        if next(stations) == nil then
            return false
        end

        for station_id, station in pairs(stations) do
            -- Station must have cart AND be in BOARDING state (not ARRIVED)
            if not station.cart_present or station.state ~= "BOARDING" then
                return false
            end
        end

        return true
    end

    -- Send dispatch with delay and countdown (non-blocking)
    local dispatch_state = "idle"  -- idle, waiting, dispatching
    local dispatch_start_time = nil
    local last_countdown = nil

    local function sendDispatch()
        print("")
        print("[" .. os.date("%H:%M:%S") .. "] ===== ALL CARTS PRESENT =====")

        if config.dispatch_delay > 0 then
            print("[" .. os.date("%H:%M:%S") .. "] Waiting " .. config.dispatch_delay .. " seconds...")
            dispatch_state = "waiting"
            dispatch_start_time = os.epoch("utc") / 1000
            last_countdown = config.dispatch_delay
        else
            -- No delay, dispatch immediately
            print("[" .. os.date("%H:%M:%S") .. "] DISPATCHING ALL STATIONS")
            print("")
            local msg = protocol.createDispatch("ops_center", "ALL")
            network.broadcast(modem, config.network_channel, msg)
        end
    end

    -- Process dispatch delay countdown (called in main loop)
    local function processDispatchDelay()
        if dispatch_state == "waiting" then
            local now = os.epoch("utc") / 1000
            local elapsed = now - dispatch_start_time
            local remaining = math.ceil(config.dispatch_delay - elapsed)

            -- Send countdown messages
            if config.countdown_enabled and remaining > 0 and remaining ~= last_countdown then
                local countdownMsg = protocol.createCountdown("ops_center", remaining)
                network.broadcast(modem, config.network_channel, countdownMsg)
                print("[" .. os.date("%H:%M:%S") .. "] COUNTDOWN: " .. remaining .. " seconds")
                last_countdown = remaining
            end

            -- Time to dispatch!
            if elapsed >= config.dispatch_delay then
                print("[" .. os.date("%H:%M:%S") .. "] DISPATCHING ALL STATIONS")
                print("")
                local msg = protocol.createDispatch("ops_center", "ALL")
                network.broadcast(modem, config.network_channel, msg)
                dispatch_state = "idle"
            end
        end
    end

    -- Request shutdown (wait for all carts to be ready before sending SHUTDOWN)
    local function sendShutdown()
        print("")
        print("[" .. os.date("%H:%M:%S") .. "] ===== SHUTDOWN REQUESTED =====")
        print("[" .. os.date("%H:%M:%S") .. "] Waiting for all carts to board...")
        shutdown_requested = true
    end

    -- Process shutdown request (send SHUTDOWN when all carts ready)
    local function processShutdown()
        if shutdown_requested and checkAllCartsPresent() then
            print("[" .. os.date("%H:%M:%S") .. "] All carts ready - SHUTTING DOWN")
            print("")
            local msg = protocol.createShutdown("ops_center", "ALL")
            network.broadcast(modem, config.network_channel, msg)
            shutdown_requested = false
        end
    end

    -- Display status on monitor
    local mon = display.getOutput()

    -- Set text scale for more screen space (ops center only)
    if mon.setTextScale then
        mon.setTextScale(1.0)
    end

    local anim_frame = 0

    local function displayStatus()
        display.clear(mon, colors.black)
        local w, h = mon.getSize()
        local now = os.epoch("utc") / 1000  -- For heartbeat calculation

        -- Animated header with border
        display.drawLine(mon, 1, "=", colors.gray)
        display.centerText(mon, 2, "COUNCILCRAFT TRANSIT", colors.white, colors.black)
        display.centerText(mon, 3, "OPERATIONS CENTER", colors.cyan, colors.black)
        display.drawLine(mon, 4, "=", colors.gray)

        local y = 6
        local station_count = 0
        local carts_present = 0

        -- Group stations by line
        local lines = {}
        for station_id, station in pairs(stations) do
            local line = station.line_id
            if not lines[line] then
                lines[line] = {}
            end
            table.insert(lines[line], station)
            station_count = station_count + 1
            if station.cart_present then
                carts_present = carts_present + 1
            end
        end

        -- Display stations by line with beautiful formatting
        for line_id, line_stations in pairs(lines) do
            -- Line header with colored badge
            mon.setCursorPos(2, y)
            mon.setTextColor(colors.black)
            mon.setBackgroundColor(colors.cyan)
            mon.write(" " .. string.upper(line_id) .. " ")
            mon.setBackgroundColor(colors.black)

            -- Line stats
            local line_ready = 0
            for _, station in ipairs(line_stations) do
                if station.cart_present then line_ready = line_ready + 1 end
            end
            mon.setCursorPos(w - 10, y)
            mon.setTextColor(colors.gray)
            mon.write(line_ready .. "/" .. #line_stations)

            y = y + 1

            -- Display each station with animated indicators (unified with station displays!)
            for i, station in ipairs(line_stations) do
                -- State-based icons and animations (same as station terminal)
                local statusIcon
                local statusText
                local statusColor
                local secondaryAnim = ""
                local showSecondaryAnim = false

                local state = station.state or "IN_TRANSIT"

                if state == "SHUTDOWN" then
                    statusIcon = "[XX]"
                    statusText = "MAINTENANCE"
                    statusColor = colors.red
                    -- Flash for visibility
                    if anim.shouldFlash(anim_frame, 2) then
                        statusColor = colors.orange
                    end
                elseif state == "DEPARTING" then
                    statusIcon = anim.icons.departing
                    statusText = "DEPARTING"
                    statusColor = colors.orange
                    secondaryAnim = anim.getSpinner(anim_frame, 4)  -- Progress bar style
                    showSecondaryAnim = true
                elseif state == "BOARDING" then
                    statusIcon = anim.icons.boarding
                    statusText = "BOARDING"
                    statusColor = colors.lime
                    -- Gentle pulsing effect
                    if anim.shouldFlash(anim_frame, 3) then
                        statusColor = colors.lightGray
                    end
                elseif state == "ARRIVED" then
                    statusIcon = anim.icons.present
                    statusText = "ARRIVED"
                    statusColor = colors.cyan
                    secondaryAnim = anim.getSpinner(anim_frame, 2)  -- Dot loader (announcements playing)
                    showSecondaryAnim = true
                else  -- IN_TRANSIT
                    statusIcon = anim.icons.transit
                    statusText = "IN TRANSIT"
                    statusColor = colors.yellow
                    secondaryAnim = anim.getSpinner(anim_frame, 2)  -- Dot loader
                    showSecondaryAnim = true
                end

                -- Heartbeat health indicator (MOVED TO LEFT)
                local heartbeat_age = now - station.last_heartbeat
                local heartbeat_color
                if heartbeat_age < 5 then
                    heartbeat_color = colors.lime  -- Healthy (< 5s)
                elseif heartbeat_age < 10 then
                    heartbeat_color = colors.yellow  -- Stale (5-10s)
                else
                    heartbeat_color = colors.red  -- Offline/unhealthy (> 10s)
                end

                -- Version display (fallback to "---" for old stations)
                local version_str = station.version or "---"
                
                -- Abridge version string to just numeric portion (e.g., "v0.10.1" from "v0.10.1-description")
                local abridged_version = version_str
                if version_str ~= "---" then
                    local dash_pos = version_str:find("-")
                    if dash_pos then
                        abridged_version = version_str:sub(1, dash_pos - 1)
                    end
                end

                -- Calculate available space for station name
                -- Layout: [ICON] [HB] [VERSION] NAME          STATUS ANIM
                local version_display = "[" .. abridged_version .. "]"
                local left_side_width = 4 + 5 + #version_display + 1  -- icon (4) + heartbeat (5) + version + space
                local statusX = math.min(w - 18, 40)  -- Increased from 28 to 52 for wider station name column
                local available_width = statusX - left_side_width - 2  -- -2 for spacing

                -- Station name with marquee scrolling if too long
                local station_name = station.station_id
                local display_name = station_name

                if #station_name > available_width then
                    -- Name is too long, apply marquee scrolling
                    -- Use anim_frame + station index for staggered scrolling
                    local scroll_offset = ((anim_frame + (i * 5)) % (#station_name + 3))  -- +3 for spacing before loop

                    -- Create a looping string with padding
                    local loop_string = station_name .. "   "  -- Add 3 spaces between loops

                    -- Extract the visible portion
                    display_name = ""
                    for j = 1, available_width do
                        local char_index = ((scroll_offset + j - 1) % #loop_string) + 1
                        display_name = display_name .. loop_string:sub(char_index, char_index)
                    end
                end

                -- Render: [ICON] [HEARTBEAT] [VERSION] NAME
                mon.setCursorPos(2, y)
                mon.setTextColor(statusColor)
                mon.write(statusIcon .. " ")
                mon.setTextColor(heartbeat_color)
                mon.write("[" .. string.format("%.0fs", heartbeat_age) .. "]")
                mon.write(" ")
                mon.setTextColor(colors.gray)
                mon.write(version_display)
                mon.write(" ")
                mon.setTextColor(colors.white)
                mon.write(display_name)

                -- Status text with animation
                mon.setCursorPos(statusX, y)
                mon.setTextColor(statusColor)
                mon.write(statusText)

                -- Animated indicator (dots for transit, progress bar for departing)
                if showSecondaryAnim then
                    mon.setCursorPos(statusX + #statusText + 1, y)
                    mon.setTextColor(colors.gray)
                    mon.write(secondaryAnim)
                end

                -- Trip timing indicator with real-time duration (if available)
                if station.trip_status and station.trip_status ~= "N/A" then
                    local timingIcon
                    local timingText
                    local timingColor
                    local shouldFlashTiming = false

                    if station.trip_status == "ON TIME" then
                        timingIcon = anim.icons.on_time
                        timingText = "ON TIME"
                        timingColor = colors.lime
                    elseif station.trip_status == "EARLY" then
                        timingIcon = anim.icons.early
                        timingText = "EARLY"
                        timingColor = colors.cyan
                    elseif station.trip_status == "DELAYED" then
                        timingIcon = anim.icons.delayed
                        timingText = "DELAYED"
                        timingColor = colors.red
                        shouldFlashTiming = true
                    end

                    -- Flash DELAYED for urgency
                    local displayTimingColor = timingColor
                    if shouldFlashTiming and not anim.shouldFlash(anim_frame, 2) then
                        displayTimingColor = colors.gray
                    end

                    -- Show trip time with stable layout: [XX] STATUS XXs/XXs
                    -- Use frozen time if cart has arrived, otherwise show real-time
                    local trip_time_to_display = nil
                    if state ~= "IN_TRANSIT" and station.last_completed_trip_time then
                        -- Cart has arrived - show frozen final trip time
                        trip_time_to_display = station.last_completed_trip_time
                    elseif state == "IN_TRANSIT" and station.current_trip_duration then
                        -- Cart in transit - show live updating time
                        trip_time_to_display = station.current_trip_duration
                    end

                    if trip_time_to_display and station.avg_trip_time then
                        local current = trip_time_to_display
                        local avg = station.avg_trip_time
                        local timeStr = string.format("%.2fs/%.2fs", current, avg)
                        local fullStr = timingIcon .. " " .. timingText .. " " .. timeStr

                        -- Right-align the full display
                        local timingX = w - #fullStr - 1
                        mon.setCursorPos(timingX, y)
                        mon.setTextColor(displayTimingColor)
                        mon.write(fullStr)
                    else
                        -- Show icon + text if we don't have timing data yet
                        local fullStr = timingIcon .. " " .. timingText
                        local timingX = w - #fullStr - 1
                        mon.setCursorPos(timingX, y)
                        mon.setTextColor(displayTimingColor)
                        mon.write(fullStr)
                    end
                end

                y = y + 1
            end

            y = y + 1  -- Spacing between lines
        end

        -- Bottom status section with progress bar
        if y < h - 5 then y = h - 5 end

        display.drawLine(mon, y, "-", colors.gray)
        y = y + 1

        -- Main status message
        local statusMsg
        local statusColor
        local statusIcon

        -- Count stations in SHUTDOWN
        local shutdown_count = 0
        for station_id, station in pairs(stations) do
            if station.state == "SHUTDOWN" then
                shutdown_count = shutdown_count + 1
            end
        end

        if station_count == 0 then
            statusMsg = "NO STATIONS REGISTERED"
            statusColor = colors.red
            statusIcon = "[!]"
        elseif shutdown_count == station_count and station_count > 0 then
            -- ALL stations in maintenance mode
            statusMsg = "MAINTENANCE MODE - Press [d] to restart"
            statusColor = colors.red
            statusIcon = "[XX]"
            -- Flash for attention
            if anim.shouldFlash(anim_frame, 2) then
                statusColor = colors.orange
            end
        elseif shutdown_requested then
            -- Waiting for shutdown conditions
            statusMsg = "SHUTDOWN REQUESTED - Waiting for carts..."
            statusColor = colors.orange
            statusIcon = anim.getSpinner(anim_frame, 2, 3)  -- Fixed width of 3 chars
        elseif carts_present == station_count and station_count > 0 then
            statusMsg = "DISPATCHING"
            statusColor = colors.lime
            statusIcon = "[>>]"
            -- Flash when dispatching
            if anim.shouldFlash(anim_frame, 2) then
                statusColor = colors.white
            end
        else
            statusMsg = "WAITING FOR " .. (station_count - carts_present) .. " CART(S)"
            statusColor = colors.yellow
            statusIcon = anim.getSpinner(anim_frame, 2, 3)  -- Fixed width of 3 chars
        end

        mon.setCursorPos(2, y)
        mon.setTextColor(statusColor)
        mon.write(statusIcon .. " " .. statusMsg)

        -- Progress bar for readiness
        if station_count > 0 then
            y = y + 1
            local barWidth = math.min(w - 4, 30)
            local progress = carts_present / station_count
            local bar = anim.progressBar(progress, barWidth, "#", "-")

            mon.setCursorPos(2, y)
            mon.setTextColor(colors.gray)
            mon.write("Ready: ")
            mon.setTextColor(colors.cyan)
            mon.write("[" .. bar .. "]")

            mon.setCursorPos(2 + 7 + barWidth + 3, y)
            mon.setTextColor(colors.white)
            mon.write(carts_present .. "/" .. station_count)
        end

        -- Bottom info bar
        display.drawLine(mon, h - 1, "-", colors.gray)
        mon.setCursorPos(2, h)
        mon.setTextColor(colors.gray)
        mon.write(os.date("%H:%M:%S"))

        -- Version indicator (centered)
        mon.setCursorPos(math.floor(w / 2) - math.floor(#VERSION / 2), h)
        mon.setTextColor(colors.gray)
        mon.write(VERSION)

        -- Network status
        mon.setCursorPos(w - 14, h)
        mon.setTextColor(colors.lime)
        mon.write("NETWORK ACTIVE")

        -- Management hint
        if h > 20 then  -- Only show on larger displays
            mon.setCursorPos(2, h - 2)
            mon.setTextColor(colors.gray)
            mon.write("Press [h] for help")
        end
    end

    -- Management commands
    local function showHelp()
        print("")
        print("=== MANAGEMENT COMMANDS ===")
        print("d - Force dispatch all stations")
        print("m - Enter maintenance mode (shutdown)")
        print("r - Reset all station states to IN_TRANSIT")
        print("s - Show station list")
        print("u - Update all stations from pastebin")
        print("h - Show this help")
        print("===========================")
        print("")
    end

    local function forceDispatch()
        print("")
        print("[MANUAL] Force dispatching all stations...")
        local msg = protocol.createDispatch("ops_center", "ALL")
        network.broadcast(modem, config.network_channel, msg)
        dispatch_state = "idle"
        dispatched = false
        print("[MANUAL] Dispatch command sent!")
        print("")
    end

    local function resetAllStations()
        print("")
        print("[MANUAL] Resetting all station states...")
        -- Send a special reset broadcast (stations will treat missing cart as IN_TRANSIT)
        for station_id, station in pairs(stations) do
            station.cart_present = false
            print("[MANUAL] Reset: " .. station_id)
        end
        dispatched = false
        dispatch_state = "idle"
        print("[MANUAL] All stations reset to IN_TRANSIT")
        print("")
    end

    local function showStations()
        print("")
        print("=== REGISTERED STATIONS ===")
        local count = 0
        for station_id, station in pairs(stations) do
            count = count + 1
            local status = station.state or "IN_TRANSIT"
            print(count .. ". " .. station_id .. " (" .. station.line_id .. ") - " .. status)
        end
        if count == 0 then
            print("No stations registered yet.")
        end
        print("===========================")
        print("")
    end

    local function updateAllStations()
        print("")
        print("[UPDATE] Sending update command to all stations...")

        -- Safety check for github_url
        if not config.github_url or config.github_url == "" then
            print("[UPDATE] ERROR: No GitHub URL configured!")
            print("[UPDATE] This ops center is running old code.")
            print("[UPDATE] Please manually update this ops center first using update.lua")
            print("")
            return
        end

        print("[UPDATE] GitHub URL: " .. config.github_url)
        print("")

        local msg = protocol.createUpdateCommand("ops_center", config.github_url, "ALL")
        network.broadcast(modem, config.network_channel, msg)

        print("[UPDATE] Update command sent!")
        print("[UPDATE] Stations will download and reboot automatically.")
        print("")
    end

    -- Initial discovery
    sendDiscovery()
    showHelp()

    -- Main loop
    local last_dispatch_check = 0
    local dispatched = false
    local last_modem_check = 0

    while true do
        local now = os.epoch("utc") / 1000

        -- Periodic discovery
        if now - last_discovery > config.discovery_interval then
            sendDiscovery()
            last_discovery = now
        end

        -- Check dispatch (skip if shutdown requested - shutdown takes priority!)
        if now - last_dispatch_check > config.dispatch_check_interval then
            if not shutdown_requested and checkAllCartsPresent() then
                if not dispatched then
                    sendDispatch()
                    dispatched = true
                end
            else
                dispatched = false
                dispatch_state = "idle"  -- Cancel any pending dispatch if cart leaves
            end
            last_dispatch_check = now
        end

        -- Process non-blocking dispatch delay
        processDispatchDelay()

        -- Process shutdown request
        processShutdown()

        -- Periodic modem health check (every 30 seconds)
        if now - last_modem_check > 30 then
            network.checkHealth(modem, config.network_channel)
            last_modem_check = now
        end

        -- Display status and update animation frame
        local display_interval_ticks = math.floor(config.display_update_interval)
        if display_interval_ticks < 1 then display_interval_ticks = 1 end
        if math.floor(now) % display_interval_ticks == 0 then
            displayStatus()
            anim_frame = anim_frame + 1
        end

        -- Check for events (messages OR keyboard)
        local timer = os.startTimer(0.1)
        local event, param1, param2, param3, param4, param5 = os.pullEvent()

        if event == "char" then
            -- Keyboard input
            os.cancelTimer(timer)
            if param1 == "d" then
                forceDispatch()
            elseif param1 == "m" then
                -- Check if already shutdown
                local all_shutdown = true
                local count = 0
                for station_id, station in pairs(stations) do
                    count = count + 1
                    if station.state ~= "SHUTDOWN" then
                        all_shutdown = false
                        break
                    end
                end

                if count > 0 and all_shutdown then
                    print("")
                    print("System already in maintenance mode!")
                    print("Press [d] to restart operations.")
                    print("")
                else
                    sendShutdown()
                end
            elseif param1 == "r" then
                resetAllStations()
            elseif param1 == "s" then
                showStations()
            elseif param1 == "u" then
                updateAllStations()
            elseif param1 == "h" then
                showHelp()
            end
        elseif event == "modem_message" then
            -- Network message
            os.cancelTimer(timer)
            local message = param4
            if type(message) == "string" then
                local decoded = protocol.deserialize(message)
                if decoded then
                    handleMessage(decoded)
                end
            end
        elseif event == "timer" and param1 == timer then
            -- Timeout, continue loop
        end
    end
end

-- ============================================================================
-- MAIN ENTRY POINT
-- ============================================================================

local config = loadConfig()

if not config then
    initialSetup()
else
    if config.type == "station" then
        runStation(config)
    elseif config.type == "ops" then
        runOps(config)
    else
        print("Invalid config!")
        fs.delete(CONFIG_FILE)
        os.reboot()
    end
end
