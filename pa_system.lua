-- CouncilCraft PA & Entertainment System
-- Combined controller/station runtime for group-scoped audio + announcements

local VERSION = "0.1.2"
local CHANNEL = 143

if not package.path:find("/lib/%.%?%.lua", 1, true) then
  package.path = "/lib/?.lua;/lib/?/init.lua;" .. package.path
end

local composer
do
  local ok, mod = pcall(require, "composer")
  if ok then
    composer = mod
  end
end

local update_checker
local update_state
if composer then
  update_checker, update_state = composer.create_update_checker("pa-system", VERSION, 30)
end

local DEFAULT_API_BASE = "https://example-pa-endpoint.run.app"
local API_KEY = "COUNCILCRAFT_MINECRAFT_SERVER_XD"
local CHIME_URL = "https://raw.githubusercontent.com/fractaal/councilcraft-transit-network/main/sounds/SG_MRT_BELL.dfpwm"

local MONITOR_TEXT_SCALE = 1.5
local MARQUEE_MIN_GAP = 6

local CONFIG_PATH = "/.pa_config"
local STATE_PATH = "/.pa_state"

local modem
local network_side
local role
local group_id
local config
local state = {
  now_playing = nil,
  pa_active = false,
  marquee_text = nil,
  marquee_rows_state = {},
  playlist = nil,
  loop_mode = "repeat_all",
  current_index = 1,
  controller_id = nil,
  controller_present = false,
  controller_last_seen = 0,
  controller_api_base = nil,
  paused = false,
  elapsed_seconds = 0,
  track_duration = 0,
  playback_start_time = nil,
  volume = 1.0,  -- Volume multiplier (0.0 to 3.0)
  pa_resume_context = nil,
  latest_version = VERSION,
  update_available = false,
  last_update_error = nil,
}

local speakers = {}
local monitors = {}

local audio_state = {
  mode = nil,       -- "music" | "pa"
  status = "idle", -- "idle" | "waiting" | "streaming"
  handle = nil,
  url = nil,
  start = nil,
  chunk_size = nil,
  queue = {},
  consecutive_failures = 0,
  decoder = nil,       -- DFPWM decoder instance (reset per stream)
  stop_requested = false,  -- Flag for graceful stop at next chunk
  active_speakers = {},
  flush_pending = nil,
  flush_remaining = 0,
  flush_mode = nil,
  flush_timeout = nil,
}

local pending_requests = {}

local base_term = term.current()
local term_width, term_height = base_term.getSize()
local LOG_HISTORY = math.max(80, term_height - 1)
local log_lines = {}
local command_buffer = ""
local cursor_pos = 0
local command_history = {}
local history_index = nil
local prompt_needs_redraw = true

local function format_time(seconds)
  if not seconds or seconds < 0 then
    return "--:--"
  end
  local mins = math.floor(seconds / 60)
  local secs = math.floor(seconds % 60)
  return string.format("%d:%02d", mins, secs)
end

local function redraw_logs()
  local prev = term.redirect(base_term)
  term_width, term_height = term.getSize()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()

  term.setCursorPos(1, 1)
  term.write(string.format("PA System v%s  [%s]", VERSION, role))
  term.setCursorPos(1, 2)

  local line2 = string.format("Group: %s", group_id or "?")
  if state.now_playing and audio_state.status == "streaming" and not state.paused then
    local time_str = string.format(" [%s/%s]", format_time(state.elapsed_seconds), format_time(state.track_duration))
    line2 = line2 .. time_str
  elseif state.paused then
    line2 = line2 .. " [PAUSED]"
  end
  term.write(line2)
  term.setCursorPos(1, 3)
  term.write(string.rep("-", term_width))

  local log_start_row = 4
  local visible = term_height - log_start_row
  if visible < 1 then
    visible = 1
  end
  LOG_HISTORY = math.max(200, visible * 10)
  local start = math.max(1, #log_lines - visible + 1)
  for row = 0, visible - 1 do
    term.setCursorPos(1, log_start_row + row)
    term.clearLine()
    local line = log_lines[start + row]
    if line then
      term.write(line)
    end
  end
  term.redirect(prev)
end

local function redraw_prompt()
  local prev = term.redirect(base_term)
  term_width, term_height = term.getSize()
  term.setCursorBlink(true)
  term.setCursorPos(1, term_height)
  term.clearLine()
  local prompt = "> " .. command_buffer
  if #prompt > term_width then
    prompt = prompt:sub(#prompt - term_width + 1)
  end
  term.write(prompt)
  local cursor_x = math.min(term_width, 2 + cursor_pos)
  term.setCursorPos(cursor_x, term_height)
  term.redirect(prev)
  prompt_needs_redraw = false
end

local function queue_prompt_redraw()
  if not prompt_needs_redraw then
    prompt_needs_redraw = true
    os.queueEvent("pa_prompt_refresh")
  end
end

local function log(severity, message)
  if not message then
    message = severity
    severity = "INFO"
  end
  local timestamp = textutils.formatTime(os.time(), true)

  -- Split multiline messages and wrap long lines
  for line in (message .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local formatted = string.format("[%s][%s] %s", timestamp, severity, line)

      -- Wrap long lines to terminal width
      while #formatted > 0 do
        local chunk = formatted:sub(1, term_width)
        table.insert(log_lines, chunk)
        if #log_lines > LOG_HISTORY then
          table.remove(log_lines, 1)
        end
        formatted = formatted:sub(term_width + 1)
      end
    end
  end

  redraw_logs()
  queue_prompt_redraw()
end

local function print_help()
  local help_text
  if role == "controller" then
    help_text = [[Available commands:
  help - show this help
  status - display current state
  playlist - list playlist entries
  play - start/resume playback
  pause - pause current track
  stop - stop playback
  next - skip to next track
  goto <index> - jump to track by index
  add <url> - add track to playlist
  remove <index> - remove track from playlist
  move <from> <to> - reorder tracks
  volume [0.0-3.0] - get/set playback volume
  update - install latest version via composer
  pa "msg" [url] - broadcast PA announcement
  reload - reload state from disk
  setapi <url> - update API base URL
  clear - clear log window]]
  else
    help_text = [[Available commands:
  help - show this help
  status - display current state
  volume [0.0-3.0] - get/set playback volume
  clear - clear log window]]
  end
  log("INFO", help_text)
end

local function read_file(path)
  if not fs.exists(path) then
    return nil
  end
  local handle = fs.open(path, "r")
  if not handle then
    return nil
  end
  local content = handle.readAll()
  handle.close()
  return content
end

local function write_file(path, content)
  local handle = fs.open(path, "w")
  if not handle then
    error("Unable to write " .. path)
  end
  handle.write(content)
  handle.close()
end

local function save_table(path, tbl)
  write_file(path, textutils.serialize(tbl))
end

local function load_table(path)
  local content = read_file(path)
  if not content then
    return nil
  end
  local ok, result = pcall(textutils.unserialize, content)
  if ok then
    return result
  end
  return nil
end

local function persist_config()
  if config then
    save_table(CONFIG_PATH, config)
  end
end

local function input(prompt, default)
  if default and default ~= "" then
    print(prompt .. " [" .. default .. "]")
  else
    print(prompt)
  end
  write(": ")
  local value = read()
  if value == "" and default then
    return default
  end
  return value
end

local function choose_role()
  while true do
    print("Select mode: (1) Controller  (2) Station")
    write("> ")
    local answer = read()
    if answer == "1" then
      return "controller"
    elseif answer == "2" then
      return "station"
    end
    print("Invalid selection. Try again.")
  end
end

local function list_peripheral_by_type(peripheral_type)
  local matches = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == peripheral_type then
      table.insert(matches, name)
    end
  end
  return matches
end

local function ensure_pa_state()
  if fs.exists(STATE_PATH) then
    local tbl = load_table(STATE_PATH)
    if tbl and type(tbl.playlist) == "table" then
      return tbl
    end
  end

  local default_state = {
    group_id = group_id,
    playlist = {
      {
        url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        title = "Example Track 1",
      },
      {
        url = "https://www.youtube.com/watch?v=oHg5SJYRHA0",
        title = "Example Track 2",
      },
    },
    loop_mode = "repeat_all",
    current_index = 1,
    api_base_url = state.controller_api_base or DEFAULT_API_BASE,
  }

  save_table(STATE_PATH, default_state)
  return default_state
end

local function persistence_setup()
  config = load_table(CONFIG_PATH)
  if config then
    role = config.role
    group_id = config.group_id
    network_side = config.network_modem_side
    return
  end

  term.clear()
  term.setCursorPos(1, 1)
  print("CouncilCraft PA System v" .. VERSION)
  print("First-time setup")
  print("")

  role = choose_role()

  group_id = input("Enter group id", "main")

  local modem_names = list_peripheral_by_type("modem")
  if #modem_names == 0 then
    error("No modem peripherals detected. A modem is required.")
  end

  print("Detected modems: " .. table.concat(modem_names, ", "))
  network_side = input("Enter modem side/name for PA signalling", modem_names[1])

  config = {
    role = role,
    group_id = group_id,
    network_modem_side = network_side,
  }

  if role == "controller" then
    config.has_local_audio = input("Does this controller have local speakers? (y/N)", "N"):lower() == "y"
    local api_base = input("Enter streaming API base URL (without trailing slash)", DEFAULT_API_BASE)
    state.controller_api_base = api_base
  end

  persist_config()
end

local function refresh_peripherals()
  speakers = {}
  monitors = {}

  if role == "controller" and config.has_local_audio then
    for _, speaker in ipairs({ peripheral.find("speaker") }) do
      table.insert(speakers, speaker)
    end
  elseif role == "station" then
    for _, speaker in ipairs({ peripheral.find("speaker") }) do
      table.insert(speakers, speaker)
    end
  end

  for _, monitor in ipairs({ peripheral.find("monitor") }) do
    monitor.setTextScale(MONITOR_TEXT_SCALE)
    table.insert(monitors, monitor)
  end

  if role == "controller" and config.has_local_audio and #speakers == 0 then
    log("WARN", "Controller configured for local audio but no speakers detected.")
  end
  if role == "station" and #speakers == 0 then
    log("WARN", "Station has no speakers. Audio playback will be muted.")
  end
end

local function init()
  persistence_setup()

  if role == "controller" then
    local saved_state = ensure_pa_state()
    state.playlist = saved_state.playlist or {}
    state.loop_mode = saved_state.loop_mode or "repeat_all"
    state.current_index = saved_state.current_index or 1
    state.controller_api_base = saved_state.api_base_url or state.controller_api_base or DEFAULT_API_BASE
    state.volume = saved_state.volume or 1.0
  else
    -- Stations get API base from controller broadcasts
    state.controller_api_base = DEFAULT_API_BASE

    -- Load volume if saved
    if fs.exists(STATE_PATH) then
      local saved_state = load_table(STATE_PATH)
      if saved_state then
        state.volume = saved_state.volume or 1.0
      end
    end
  end

  local prev = term.redirect(base_term)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  term.redirect(prev)
  redraw_logs()
  redraw_prompt()

  refresh_peripherals()

  modem = peripheral.wrap(network_side)
  if not modem then
    error("Unable to wrap modem on " .. tostring(network_side))
  end
  if not modem.isOpen(CHANNEL) then
    modem.open(CHANNEL)
  end

  state.controller_id = os.getComputerID()
  state.controller_last_seen = os.epoch("utc")
  log("INFO", "Role: " .. role .. "  Group: " .. group_id)
  if role == "controller" then
    log("INFO", string.format("Playlist entries: %d", #(state.playlist or {})))
  end
  log("INFO", "Type 'help' for command list.")
  sync_update_state()
end

local function persist_pa_state()
  local now = {}

  if role == "controller" then
    now = {
      group_id = group_id,
      playlist = state.playlist,
      loop_mode = state.loop_mode,
      current_index = state.current_index,
      api_base_url = state.controller_api_base,
      volume = state.volume,
    }
  else
    -- Stations only persist volume
    now = {
      volume = state.volume,
    }
  end

  save_table(STATE_PATH, now)
end

local function reload_state()
  if role ~= "controller" then
    log("WARN", "Only controllers can reload playlist state.")
    return
  end
  local saved_state = load_table(STATE_PATH)
  if not saved_state then
    log("ERROR", "Unable to read " .. STATE_PATH)
    return
  end
  state.playlist = saved_state.playlist or {}
  state.loop_mode = saved_state.loop_mode or "repeat_all"
  state.current_index = saved_state.current_index or 1
  state.controller_api_base = saved_state.api_base_url or state.controller_api_base or DEFAULT_API_BASE
  log("INFO", string.format("Reloaded playlist (%d entries)", #(state.playlist or {})))
  os.queueEvent("render_ui")
end

local marquee_rows_config = {
  {
    id = "now_playing",
    color = colors.cyan,
    build = function(ctx)
      local now = ctx.state.now_playing
      if not now then
        return nil
      end
      local title = now.title or now.url or "(unknown)"
      local artist = now.artist
      if artist and artist ~= "" then
        return string.format("NOW PLAYING: %s — %s", title, artist)
      end
      return string.format("NOW PLAYING: %s", title)
    end,
  },
  {
    id = "pa",
    color = colors.orange,
    build = function(ctx)
      local message = ctx.state.marquee_text
      if ctx.state.pa_active and message and message ~= "" then
        return string.format("PA: %s", message)
      end
    end,
  },
}

local function collect_marquee_rows()
  local ctx = { state = state }
  local rows = {}

  for _, config in ipairs(marquee_rows_config) do
    local text = config.build(ctx)
    local row_id = config.id
    if text and text ~= "" then
      local row_state = state.marquee_rows_state[row_id]
      if not row_state then
        row_state = { id = row_id, offset = 0, segment = nil, scroll_length = 0 }
      end
      if row_state.text ~= text or not row_state.segment then
        row_state.offset = 0
        row_state.segment = text .. string.rep(" ", MARQUEE_MIN_GAP)
        row_state.scroll_length = #row_state.segment
      end
      row_state.text = text
      row_state.color = config.color or colors.white
      row_state.active_scroll = false

      state.marquee_rows_state[row_id] = row_state
      table.insert(rows, row_state)
    else
      state.marquee_rows_state[row_id] = nil
    end
  end

  return rows
end

local function sync_update_state()
  if update_state then
    if update_state.latest_version then
      state.latest_version = update_state.latest_version
    end
    state.update_available = update_state.update_available or false
    if update_state.last_error ~= state.last_update_error then
      state.last_update_error = update_state.last_error
      if update_state.last_error then
        log("WARN", "Composer update check failed: " .. tostring(update_state.last_error))
      else
        log("INFO", "Composer update check restored")
      end
    end
  end
end

local function render_monitors()
  if #monitors == 0 then
    return
  end

  sync_update_state()
  local rows = collect_marquee_rows()
  for _, row in ipairs(rows) do
    row.active_scroll = false
  end

  local global_scroll = false

  for _, monitor in ipairs(monitors) do
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    local width, height = monitor.getSize()
    local line_y = 1

    for _, row in ipairs(rows) do
      if line_y > height then
        break
      end

      local display
      local text = row.text or ""
      if #text > width and row.scroll_length and row.scroll_length > 0 then
        local segment = row.segment
        local buffer = segment .. segment
        while #buffer < row.scroll_length + width do
          buffer = buffer .. segment
        end
        local offset = row.offset % row.scroll_length
        display = buffer:sub(offset + 1, offset + width)
        if #display < width then
          display = display .. buffer:sub(1, width - #display)
        end
        row.active_scroll = true
        global_scroll = true
      else
        display = text
        if #display < width then
          display = display .. string.rep(" ", width - #display)
        end
      end

      monitor.setCursorPos(1, line_y)
      monitor.clearLine()
      monitor.setTextColor(row.color or colors.white)
      monitor.write(display)
      line_y = line_y + 1
    end

    monitor.setTextColor(colors.white)
  end

  if global_scroll then
    if not marquee_timer then
      marquee_timer = os.startTimer(0.1)
    end
  elseif marquee_timer then
    os.cancelTimer(marquee_timer)
    marquee_timer = nil
  end
end

local marquee_timer
local time_update_timer

local function start_time_tracker()
  if time_update_timer then
    os.cancelTimer(time_update_timer)
  end
  state.playback_start_time = os.epoch("utc") / 1000
  state.elapsed_seconds = 0
  time_update_timer = os.startTimer(1)
end

local function stop_time_tracker()
  if time_update_timer then
    os.cancelTimer(time_update_timer)
    time_update_timer = nil
  end
  state.elapsed_seconds = 0
  state.playback_start_time = nil
end

local function update_elapsed_time()
  if state.playback_start_time and not state.paused then
    state.elapsed_seconds = (os.epoch("utc") / 1000) - state.playback_start_time
  end
  redraw_logs()
  if not state.paused and audio_state.status == "streaming" then
    time_update_timer = os.startTimer(1)
  end
end

local function stop_audio()
  -- Request graceful stop at next chunk boundary (don't tear down immediately)
  if audio_state.status == "streaming" or audio_state.status == "waiting" then
    audio_state.stop_requested = true
    log("INFO", "Audio stop requested (will complete at next chunk)")

    -- Cancel any pending HTTP requests
    for url, ctx in pairs(pending_requests) do
      if ctx.kind == "music" or ctx.kind == "pa" then
        pending_requests[url] = nil
      end
    end

    stop_time_tracker()
  end
end

local function schedule_marquee()
  if not marquee_timer then
    marquee_timer = os.startTimer(0.1)
  end
end

local function clear_marquee()
  state.pa_active = false
  state.marquee_text = nil
  state.marquee_rows_state["pa"] = nil
  os.queueEvent("render_ui")
end

local function build_api_url(path, yt_url)
  local base = state.controller_api_base or DEFAULT_API_BASE
  if base:sub(-1) == "/" then
    base = base:sub(1, -2)
  end
  return base .. path .. "?track=" .. textutils.urlEncode(yt_url) .. "&key=" .. textutils.urlEncode(API_KEY)
end

local function request_stream(kind, url, context)
  context = context or {}
  context.kind = kind
  log("INFO", string.format("HTTP request queued (%s): %s", kind, url))
  pending_requests[url] = context
  http.request({ url = url, method = "GET", binary = true })
end

local function request_info(url, index)
  local info_url = build_api_url("/info", url)
  log("INFO", "HTTP metadata request: " .. info_url)
  pending_requests[info_url] = { kind = "info", index = index, track_url = url }
  http.request(info_url)
end

local function broadcast(message)
  message.group_id = group_id
  modem.transmit(CHANNEL, CHANNEL, message)
end

local function snapshot_current_track()
  if not state.now_playing or not state.now_playing.url then
    return nil
  end

  return {
    url = state.now_playing.url,
    title = state.now_playing.title,
    artist = state.now_playing.artist,
    duration = state.track_duration,
  }
end

local function start_music_stream(entry)
  state.now_playing = {
    url = entry.url,
    title = entry.title,
    artist = entry.artist,
  }
  state.track_duration = entry.duration or 0
  state.paused = false
  os.queueEvent("render_ui")
  schedule_marquee()

  if entry.title then
    log("INFO", string.format("Starting track: %s (%s)", entry.title, entry.url or ""))
  else
    log("INFO", "Starting track: " .. (entry.url or "(unknown)"))
  end

  local stream_url = build_api_url("/stream", entry.url)

  broadcast({
    type = "music_start",
    track_url = entry.url,
    title = entry.title,
    artist = entry.artist,
    stream_url = stream_url,
    started_at = os.epoch("utc"),
  })

  if #speakers > 0 then
    stop_audio()

    -- Wait for audio to actually stop before starting new stream
    while audio_state.status ~= "idle" do
      os.pullEvent("audio_update")
    end

    audio_state.active_speakers = {}
    audio_state.mode = "music"
    audio_state.status = "waiting"
    audio_state.url = stream_url
    audio_state.stop_requested = false  -- Clear any pending stop for new stream
    request_stream("music", stream_url, { label = "music" })
  end
end

local function advance_playlist()
  if not state.playlist or #state.playlist == 0 then
    state.now_playing = nil
    broadcast({ type = "music_stop" })
    os.queueEvent("render_ui")
    log("WARN", "Playlist empty; nothing to play")
    return
  end

  local entry = state.playlist[state.current_index]
  if not entry then
    state.current_index = 1
    entry = state.playlist[state.current_index]
  end

  -- Only request info if we don't already have it and no request pending
  if not entry.title or not entry.artist then
    local info_url = build_api_url("/info", entry.url)
    if not pending_requests[info_url] then
      request_info(entry.url, state.current_index)
    end
  end

  start_music_stream(entry)

  if state.loop_mode == "repeat_one" then
    -- stay on same index
  else
    state.current_index = state.current_index + 1
    if state.current_index > #state.playlist then
      state.current_index = 1
    end
  end

  persist_pa_state()
end

local function start_current_track()
  if role ~= "controller" then
    log("WARN", "Only controllers can start playback.")
    return
  end
  if not state.playlist or #state.playlist == 0 then
    log("WARN", "Playlist empty; nothing to play")
    return
  end
  local index = state.current_index
  if index < 1 or index > #state.playlist then
    index = 1
    state.current_index = index
  end
  local entry = state.playlist[index]
  if not entry then
    log("ERROR", "Invalid playlist entry at index " .. tostring(index))
    return
  end
  start_music_stream(entry)
  if state.loop_mode ~= "repeat_one" then
    state.current_index = index + 1
    if state.current_index > #state.playlist then
      state.current_index = 1
    end
  end
  persist_pa_state()
end

local function stop_music()
  broadcast({ type = "music_stop" })
  stop_audio()
end

local start_next_audio_in_queue

local function queue_pa_sequence(audio_url)
  if not audio_url or audio_url == "" then
    return
  end

  stop_audio()

  -- Wait for audio to actually stop before starting PA sequence
  while audio_state.status ~= "idle" do
    os.pullEvent("audio_update")
  end

  audio_state.mode = "pa"
  audio_state.status = "waiting"
  audio_state.queue = {}
  audio_state.stop_requested = false  -- Clear any pending stop for new PA sequence
  table.insert(audio_state.queue, { label = "chime", url = CHIME_URL })
  if audio_url and audio_url ~= "" then
    table.insert(audio_state.queue, { label = "announcement", url = audio_url })
  end
  start_next_audio_in_queue()
end

local function resume_music_after_pa()
  local context = state.pa_resume_context
  state.pa_resume_context = nil

  if not context or not context.entry then
    return
  end

  if context.should_resume then
    start_music_stream(context.entry)
  elseif context.was_paused then
    state.paused = true
    state.now_playing = {
      url = context.entry.url,
      title = context.entry.title,
      artist = context.entry.artist,
    }
    state.track_duration = context.entry.duration or 0
    os.queueEvent("render_ui")
  end
end

local function pause_music()
  if state.paused then
    return false, "Playback already paused"
  end
  if not state.now_playing or not state.now_playing.url then
    return false, "Nothing is playing to pause"
  end

  state.paused = true
  broadcast({
    type = "music_pause",
    track_url = state.now_playing.url,
    title = state.now_playing.title,
    artist = state.now_playing.artist,
    duration = state.track_duration,
  })
  stop_audio()
  os.queueEvent("render_ui")
  return true, "Playback paused"
end

local function resume_paused_track()
  if not state.paused then
    return false, "Playback is not paused"
  end

  local entry = snapshot_current_track()
  if not entry then
    state.paused = false
    return false, "No track available to resume"
  end

  start_music_stream(entry)
  return true, "Playback resumed"
end

local function begin_pa(marquee_text, audio_url)
  local has_audio = audio_url and audio_url ~= ""

  if has_audio then
    local resume_entry = snapshot_current_track()
    state.pa_resume_context = nil
    if resume_entry then
      state.pa_resume_context = {
        entry = resume_entry,
        should_resume = not state.paused,
        was_paused = state.paused,
      }
    end
  else
    state.pa_resume_context = nil
  end

  state.pa_active = true
  state.marquee_text = marquee_text
  schedule_marquee()
  os.queueEvent("render_ui")

  log("INFO", "Broadcasting PA: " .. marquee_text)

  if has_audio then
    local ok = pause_music()
    if not ok and state.pa_resume_context then
      -- Failed to pause (probably nothing playing); drop resume context
      state.pa_resume_context = nil
    end
  end

  broadcast({
    type = "pa_begin",
    marquee_text = marquee_text,
    audio_url = audio_url,
  })

  if has_audio and #speakers > 0 then
    queue_pa_sequence(audio_url)
  end
end

local function complete_pa_audio()
  log("INFO", "PA audio sequence complete")
  resume_music_after_pa()
end

local function uiLoop()
  while true do
    local event = { os.pullEvent() }
    local name = event[1]
    if name == "render_ui" then
      render_monitors()
    elseif name == "timer" then
      local timer_id = event[2]
      if marquee_timer and timer_id == marquee_timer then
        local any_scroll = false
        local rows_state = state.marquee_rows_state
        if rows_state then
          for _, row in pairs(rows_state) do
            if row.active_scroll and row.scroll_length and row.scroll_length > 0 then
              row.offset = (row.offset + 1) % row.scroll_length
              any_scroll = true
            end
          end
        end

        if any_scroll then
          render_monitors()
          marquee_timer = os.startTimer(0.1)
        else
          marquee_timer = nil
        end
      elseif time_update_timer and timer_id == time_update_timer then
        update_elapsed_time()
      end
    elseif name == "term_resize" then
      redraw_logs()
      redraw_prompt()
      render_monitors()
    elseif name == "pa_prompt_refresh" then
      -- handled by command loop; ignore here
    elseif name == "terminate" then
      error("Terminated", 0)
    end
  end
end

start_next_audio_in_queue = function()
  if audio_state.status ~= "waiting" then
    return
  end

  if audio_state.mode ~= "pa" then
    audio_state.status = "idle"
    return
  end

  local next_item = table.remove(audio_state.queue, 1)
  if not next_item then
    audio_state.status = "idle"
    os.queueEvent("pa_sequence_complete")
    return
  end
  audio_state.url = next_item.url
  request_stream("pa", next_item.url, { label = next_item.label })
end

local function play_buffer(buffer)
  if #speakers == 0 then
    return
  end

  -- Clamp volume to valid range (0.0 to 3.0)
  local volume = math.max(0, math.min(3, state.volume or 1.0))

  local tasks = {}
  for i, speaker in ipairs(speakers) do
    tasks[i] = function()
      local name = peripheral.getName(speaker)
      while not speaker.playAudio(buffer, volume) do
        local event, dev = os.pullEvent("speaker_audio_empty")
        if event == "speaker_audio_empty" and dev == name then
          -- wait until speaker ready
        end
      end
      audio_state.active_speakers[name] = true
    end
  end
  pcall(parallel.waitForAll, table.unpack(tasks))
end

local function start_speaker_flush(mode)
  if not audio_state.active_speakers then
    audio_state.active_speakers = {}
  end

  local pending = {}
  local count = 0
  for name in pairs(audio_state.active_speakers) do
    pending[name] = true
    count = count + 1
  end

  if count == 0 then
    return false
  end

  audio_state.status = "flushing"
  audio_state.flush_mode = mode
  audio_state.flush_pending = pending
  audio_state.flush_remaining = count
  audio_state.flush_timeout = os.startTimer(0.5)
  return true
end

local function finalize_speaker_flush()
  local mode = audio_state.flush_mode

  audio_state.flush_pending = nil
  audio_state.flush_remaining = 0
  audio_state.flush_mode = nil
  audio_state.flush_timeout = nil
  audio_state.active_speakers = {}

  audio_state.status = "idle"
  audio_state.mode = nil

  if mode == "music" then
    os.queueEvent("music_stream_complete")
  end
end

local function audioLoop()
  while true do
    if audio_state.status == "streaming" and audio_state.handle and audio_state.decoder then
      -- Check for graceful stop request
      if audio_state.stop_requested then
        -- Graceful cleanup at chunk boundary
        if audio_state.handle.close then
          audio_state.handle.close()
        end
        audio_state.handle = nil
        audio_state.decoder = nil
        audio_state.status = "idle"
        local old_mode = audio_state.mode
        audio_state.mode = nil
        audio_state.url = nil
        audio_state.queue = {}
        audio_state.start = nil
        audio_state.chunk_size = nil
        audio_state.stop_requested = false
        audio_state.active_speakers = {}
        audio_state.flush_pending = nil
        audio_state.flush_remaining = 0
        audio_state.flush_mode = nil
        audio_state.flush_timeout = nil

        -- Stop speakers
        for _, speaker in ipairs(speakers) do
          speaker.stop()
        end

        log("INFO", "Audio playback halted gracefully")
        os.queueEvent("audio_update")  -- Wake up any waiting threads
      else
        local chunk = audio_state.handle.read(audio_state.chunk_size)
        if not chunk then
          audio_state.handle.close()
          audio_state.handle = nil
          audio_state.decoder = nil  -- Clear decoder after stream completes
          if audio_state.mode == "music" then
            -- Wait for speakers to finish draining before advancing playlist
            if not start_speaker_flush("music") then
              audio_state.status = "idle"
              audio_state.mode = nil
              audio_state.active_speakers = {}
              audio_state.flush_pending = nil
              audio_state.flush_remaining = 0
              audio_state.flush_mode = nil
              audio_state.flush_timeout = nil
              os.queueEvent("music_stream_complete")
            end
          elseif audio_state.mode == "pa" then
            audio_state.status = "waiting"
            start_next_audio_in_queue()
          else
            audio_state.status = "idle"
          end
        else
          if audio_state.start then
            chunk = audio_state.start .. chunk
            audio_state.start = nil
            audio_state.chunk_size = audio_state.chunk_size + 4
          end

          local buffer = audio_state.decoder(chunk)
          play_buffer(buffer)
        end
      end
    else
      if audio_state.status == "flushing" then
        while audio_state.status == "flushing" do
          local event = { os.pullEvent() }
          local name = event[1]
          if name == "speaker_audio_empty" then
            local device = event[2]
            if audio_state.flush_pending and device and audio_state.flush_pending[device] then
              audio_state.flush_pending[device] = nil
              audio_state.flush_remaining = audio_state.flush_remaining - 1
              if audio_state.flush_remaining <= 0 then
                finalize_speaker_flush()
              end
            end
          elseif name == "timer" then
            local timer_id = event[2]
            if audio_state.flush_timeout and timer_id == audio_state.flush_timeout then
              finalize_speaker_flush()
            else
              os.queueEvent(name, table.unpack(event, 2))
              os.sleep(0)
            end
          else
            os.queueEvent(name, table.unpack(event, 2))
            os.sleep(0)
          end
        end
      else
        os.pullEvent("audio_update")
      end
    end
  end
end

local function handle_music_complete()
  advance_playlist()
end

local function handle_pa_complete()
  if audio_state.mode == "pa" and #audio_state.queue == 0 and audio_state.status ~= "streaming" then
    complete_pa_audio()
  end
end

local function handle_station_music_start(message)
  state.now_playing = {
    url = message.track_url,
    title = message.title,
    artist = message.artist,
  }
  state.controller_present = true
  state.controller_last_seen = os.epoch("utc")
  state.paused = false
  os.queueEvent("render_ui")
  schedule_marquee()

  log("INFO", string.format("Controller started track: %s (%s) stream=%s", message.title or message.track_url or "(unknown)", message.track_url or "", message.stream_url or ""))

  if #speakers == 0 then
    return
  end

  stop_audio()

  -- Wait for audio to actually stop before starting new stream
  while audio_state.status ~= "idle" do
    os.pullEvent("audio_update")
  end

  audio_state.active_speakers = {}
  audio_state.mode = "music"
  audio_state.status = "waiting"
  audio_state.url = message.stream_url
  audio_state.stop_requested = false  -- Clear any pending stop for new stream
  request_stream("music", message.stream_url, { label = "music" })
end

local function handle_station_music_stop()
  stop_audio()
  state.now_playing = nil
  state.paused = false
  os.queueEvent("render_ui")
  log("INFO", "Controller stopped music")
end

local function handle_station_music_pause(message)
  state.paused = true
  stop_audio()

  if message and message.track_url then
    state.now_playing = {
      url = message.track_url,
      title = message.title,
      artist = message.artist,
    }
    state.track_duration = message.duration or state.track_duration
  end

  os.queueEvent("render_ui")
  log("INFO", "Controller paused music")
end

local function handle_station_pa_begin(message)
  state.pa_active = true
  state.marquee_text = message.marquee_text
  schedule_marquee()
  os.queueEvent("render_ui")

  log("INFO", "PA received: " .. message.marquee_text)

  local has_audio = message.audio_url and message.audio_url ~= ""
  if has_audio then
    stop_audio()

  if #speakers > 0 then
    -- Wait for audio to actually stop before starting PA sequence
    while audio_state.status ~= "idle" do
      os.pullEvent("audio_update")
    end

    audio_state.active_speakers = {}
    audio_state.mode = "pa"
    audio_state.status = "waiting"
    audio_state.queue = {}
    audio_state.stop_requested = false  -- Clear any pending stop
    table.insert(audio_state.queue, { label = "chime", url = CHIME_URL })
    if message.audio_url and message.audio_url ~= "" then
      table.insert(audio_state.queue, { label = "announcement", url = message.audio_url })
    end
    start_next_audio_in_queue()
  end
  end
end

local function handle_station_pa_end()
  clear_marquee()
  log("INFO", "PA cleared")
end

local function networkLoop()
  while true do
    local _, side, channel, reply_channel, message = os.pullEvent("modem_message")
    if side == network_side and channel == CHANNEL and type(message) == "table" then
      if message.group_id ~= group_id then
        goto continue
      end

      if message.type == "controller_announce" then
        if role == "station" then
          state.controller_present = true
          state.controller_last_seen = os.epoch("utc")
          state.controller_api_base = message.api_base_url or state.controller_api_base
          os.queueEvent("render_ui")
        elseif role == "controller" then
          if message.controller_id and message.controller_id ~= state.controller_id then
            log("ERROR", "Another controller with group " .. group_id .. " detected. Halting.")
            error("Controller conflict on group " .. group_id, 0)
          end
        end
      elseif message.type == "music_start" then
        if role == "station" then
          handle_station_music_start(message)
        end
      elseif message.type == "music_stop" then
        if role == "station" then
          handle_station_music_stop()
        else
          state.paused = false
        end
      elseif message.type == "music_pause" then
        if role == "station" then
          handle_station_music_pause(message)
        else
          state.paused = true
          os.queueEvent("render_ui")
        end
      elseif message.type == "pa_begin" then
        if role == "station" then
          handle_station_pa_begin(message)
        else
          state.pa_active = true
          state.marquee_text = message.marquee_text
          schedule_marquee()
          os.queueEvent("render_ui")
        end
      elseif message.type == "pa_end" then
        if role == "station" then
          handle_station_pa_end()
        else
          clear_marquee()
        end
      elseif message.type == "station_register" and role == "controller" then
        log("Station registered: " .. tostring(message.station_id or "unknown"))
      end
    end
    ::continue::
  end
end

local function controller_broadcast_loop()
  while true do
    local payload = {
      type = "controller_announce",
      api_base_url = state.controller_api_base,
      controller_id = state.controller_id,
      now_playing = state.now_playing,
      pa_active = state.pa_active,
      paused = state.paused,
    }
    broadcast(payload)
    os.sleep(1)
  end
end

local function station_register()
  broadcast({
    type = "station_register",
    station_id = os.getComputerID(),
    has_speakers = #speakers > 0,
  })
end

local function station_watchdog_loop()
  while true do
    os.sleep(5)
    if role ~= "station" then
      return
    end
    local now = os.epoch("utc")
    if now - state.controller_last_seen > 6000 then
      if state.controller_present then
        state.controller_present = false
        os.queueEvent("render_ui")
        log("WARN", "Controller heartbeat timed out")
      end
    end
  end
end

local function handle_command(line)
  local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then
    return
  end

  table.insert(command_history, trimmed)
  if #command_history > 32 then
    table.remove(command_history, 1)
  end
  history_index = nil

  local cmd, rest = trimmed:match("^(%S+)%s*(.*)$")
  cmd = cmd and cmd:lower() or ""
  rest = rest or ""

  if cmd == "help" or cmd == "?" then
    print_help()
  elseif cmd == "status" then
    sync_update_state()
    local parts = {
      "role=" .. role,
      "group=" .. group_id,
    }
    if state.now_playing then
      table.insert(parts, string.format("now_playing=%s", state.now_playing.title or state.now_playing.url or "(unknown)"))
    else
      table.insert(parts, "now_playing=idle")
    end
    if state.pa_active then
      table.insert(parts, "pa=active")
    else
      table.insert(parts, "pa=idle")
    end
    if composer then
      if state.update_available then
        table.insert(parts, "update_available=" .. tostring(state.latest_version or "?"))
      else
        table.insert(parts, "update=current")
      end
    end
    log("INFO", "Status: " .. table.concat(parts, " | "))
  elseif cmd == "playlist" then
    if role ~= "controller" then
      log("WARN", "Playlist view only available to controller")
    elseif not state.playlist or #state.playlist == 0 then
      log("WARN", "Playlist empty")
    else
      for index, entry in ipairs(state.playlist) do
        local marker = (state.current_index == index) and "*" or " "
        local title = entry.title or "(untitled)"
        log("INFO", string.format("%s[%d] %s", marker, index, title))
      end
    end
  elseif cmd == "next" then
    if role == "controller" then
      advance_playlist()
    else
      log("WARN", "Only controller can skip tracks")
    end
  elseif cmd == "stop" then
    if role == "controller" then
      stop_music()
      state.now_playing = nil
      os.queueEvent("render_ui")
      log("INFO", "Playback stopped")
    else
      log("WARN", "Only controller can stop playback")
    end
  elseif cmd == "play" then
    if role == "controller" then
      if state.paused then
        local ok, message = resume_paused_track()
        if ok then
          log("INFO", message)
        else
          log("WARN", message)
        end
      else
        start_current_track()
      end
    else
      log("WARN", "Only controller can start playback")
    end
  elseif cmd == "pause" then
    if role == "controller" then
      local ok, message = pause_music()
      if ok then
        log("INFO", message)
      else
        log("WARN", message)
      end
    else
      log("WARN", "Only controller can pause playback")
    end
  elseif cmd == "goto" then
    if role ~= "controller" then
      log("WARN", "Only controller can jump to tracks")
    elseif rest == "" then
      log("WARN", "Usage: goto <index>")
    else
      local index = tonumber(rest)
      if not index or index < 1 or index > #state.playlist then
        log("WARN", string.format("Invalid index (must be 1-%d)", #state.playlist))
      else
        state.current_index = index
        stop_music()
        start_current_track()
        persist_pa_state()
        log("INFO", string.format("Jumped to track #%d", index))
      end
    end
  elseif cmd == "move" then
    if role ~= "controller" then
      log("WARN", "Only controller can modify playlist")
    elseif rest == "" then
      log("WARN", "Usage: move <from> <to>")
    else
      local from, to = rest:match("^(%d+)%s+(%d+)$")
      from, to = tonumber(from), tonumber(to)
      if not from or not to or from < 1 or from > #state.playlist or to < 1 or to > #state.playlist then
        log("WARN", string.format("Invalid indices (must be 1-%d)", #state.playlist))
      else
        local track = table.remove(state.playlist, from)
        table.insert(state.playlist, to, track)
        if state.current_index == from then
          state.current_index = to
        elseif from < state.current_index and to >= state.current_index then
          state.current_index = state.current_index - 1
        elseif from > state.current_index and to <= state.current_index then
          state.current_index = state.current_index + 1
        end
        persist_pa_state()
        log("INFO", string.format("Moved track #%d to #%d", from, to))
      end
    end
  elseif cmd == "update" then
    if not composer then
      log("WARN", "Composer not available on this system")
    else
      log("INFO", "Checking for updates via composer...")
      local ok, result = composer.install("pa-system")
      if ok then
        log("INFO", "Update installed. Please restart to run the latest version.")
        if update_state then
          update_state.current_version = result or update_state.latest_version or update_state.current_version
          update_state.update_available = false
        end
        sync_update_state()
      else
        log("ERROR", "Composer update failed: " .. tostring(result or "unknown"))
      end
    end
  elseif cmd == "pa" then
    if role ~= "controller" then
      log("WARN", "Only controller can send announcements")
    else
      if rest == "" then
        log("WARN", 'Usage: pa "Message" [audio_url]')
      else
        local text, audio = rest:match('^"(.-)"%s*(.*)$')
        if not text or text == "" then
          log("WARN", 'PA text must be wrapped in quotes. Example: pa "Mind the gap" https://...')
        else
          if audio == "" then
            audio = nil
          end
          begin_pa(text, audio)
        end
      end
    end
  elseif cmd == "add" then
    if role ~= "controller" then
      log("WARN", "Only controller can modify playlist")
    elseif rest == "" then
      log("WARN", "Usage: add <url>")
    else
      local track_url = rest:match("^%s*(.-)%s*$")  -- trim whitespace
      if not track_url or track_url == "" then
        log("WARN", "Invalid URL")
      else
        local entry = { url = track_url }
        table.insert(state.playlist, entry)
        persist_pa_state()
        log("INFO", string.format("Added track #%d: %s", #state.playlist, track_url))
      end
    end
  elseif cmd == "remove" then
    if role ~= "controller" then
      log("WARN", "Only controller can modify playlist")
    elseif rest == "" then
      log("WARN", "Usage: remove <index>")
    else
      local index = tonumber(rest)
      if not index or index < 1 or index > #state.playlist then
        log("WARN", string.format("Invalid index (must be 1-%d)", #state.playlist))
      else
        local removed = table.remove(state.playlist, index)
        if state.current_index > index then
          state.current_index = state.current_index - 1
        elseif state.current_index == index then
          state.current_index = math.min(state.current_index, #state.playlist)
        end
        persist_pa_state()
        log("INFO", string.format("Removed track #%d: %s", index, removed.title or removed.url))
      end
    end
  elseif cmd == "reload" then
    reload_state()
  elseif cmd == "setapi" then
    if role ~= "controller" then
      log("WARN", "Only controller can change API base URL")
    elseif rest == "" then
      log("WARN", "Usage: setapi <url>")
    else
      state.controller_api_base = rest
      persist_pa_state()
      log("INFO", "API base updated to " .. rest)
    end
  elseif cmd == "volume" then
    if rest == "" then
      log("INFO", string.format("Current volume: %.1f (0.0-3.0)", state.volume))
    else
      local vol = tonumber(rest)
      if not vol then
        log("WARN", "Usage: volume <number> (0.0-3.0)")
      else
        state.volume = math.max(0, math.min(3, vol))
        persist_pa_state()
        log("INFO", string.format("Volume set to %.1f", state.volume))
      end
    end
  elseif cmd == "clear" then
    log_lines = {}
    log("INFO", "Log cleared")
  else
    log("WARN", "Unknown command: " .. cmd)
  end
end

local function commandLoop()
  redraw_prompt()
  while true do
    local event = { os.pullEvent() }
    local name = event[1]
    if name == "char" then
      local char = event[2]
      command_buffer = command_buffer:sub(1, cursor_pos) .. char .. command_buffer:sub(cursor_pos + 1)
      cursor_pos = cursor_pos + 1
      redraw_prompt()
    elseif name == "paste" then
      local text = event[2]
      command_buffer = command_buffer:sub(1, cursor_pos) .. text .. command_buffer:sub(cursor_pos + 1)
      cursor_pos = cursor_pos + #text
      redraw_prompt()
    elseif name == "key" then
      local key = event[2]
      if key == keys.left then
        if cursor_pos > 0 then
          cursor_pos = cursor_pos - 1
        end
      elseif key == keys.right then
        if cursor_pos < #command_buffer then
          cursor_pos = cursor_pos + 1
        end
      elseif key == keys.backspace then
        if cursor_pos > 0 then
          command_buffer = command_buffer:sub(1, cursor_pos - 1) .. command_buffer:sub(cursor_pos + 1)
          cursor_pos = cursor_pos - 1
        end
      elseif key == keys.delete then
        if cursor_pos < #command_buffer then
          command_buffer = command_buffer:sub(1, cursor_pos) .. command_buffer:sub(cursor_pos + 2)
        end
      elseif key == keys.enter then
        local line = command_buffer
        command_buffer = ""
        cursor_pos = 0
        redraw_prompt()
        handle_command(line)
      elseif key == keys.up then
        if #command_history > 0 then
          if not history_index then
            history_index = #command_history
          else
            history_index = math.max(1, history_index - 1)
          end
          command_buffer = command_history[history_index]
          cursor_pos = #command_buffer
        end
      elseif key == keys.down then
        if history_index then
          history_index = history_index + 1
          if history_index > #command_history then
            history_index = nil
            command_buffer = ""
          else
            command_buffer = command_history[history_index]
          end
          cursor_pos = #command_buffer
        else
          command_buffer = ""
          cursor_pos = 0
        end
      end
      redraw_prompt()
    elseif name == "term_resize" then
      local prev = term.redirect(base_term)
      term_width, term_height = term.getSize()
      term.redirect(prev)
      redraw_logs()
      redraw_prompt()
    elseif name == "pa_prompt_refresh" then
      prompt_needs_redraw = false
      redraw_prompt()
    elseif name == "terminate" then
      error("Terminated", 0)
    end
  end
end

local function httpLoop()
  while true do
    parallel.waitForAny(
      function()
        local _, url, handle = os.pullEvent("http_success")
        local request = pending_requests[url]
        pending_requests[url] = nil

        if not request then
          handle.close()
          return
        end

        if request.kind == "info" then
          local body = handle.readAll()
          handle.close()
          log("INFO", string.format("Metadata response (%s): %s", request.track_url or "?", body or ""))
          local ok, data = pcall(textutils.unserialiseJSON, body)
          if ok and data then
            local entry = state.playlist and state.playlist[request.index]
            if entry then
              entry.title = data.title or entry.title
              entry.artist = data.channel or entry.artist
              entry.duration = data.durationSeconds or entry.duration
              persist_pa_state()
              if state.now_playing and state.now_playing.url == entry.url then
                state.now_playing.title = entry.title
                state.now_playing.artist = entry.artist
                state.track_duration = entry.duration or 0
                os.queueEvent("render_ui")
              end
            end
          end
        elseif request.kind == "music" or request.kind == "pa" then
          log("INFO", string.format("Stream ready (%s): %s", request.label or request.kind, url))
          audio_state.handle = handle
          audio_state.status = "streaming"
          audio_state.start = handle.read(4)
          audio_state.chunk_size = 16 * 1024 - 4
          audio_state.consecutive_failures = 0
          -- Create new decoder for this stream
          audio_state.decoder = require("cc.audio.dfpwm").make_decoder()
          if request.kind == "music" then
            start_time_tracker()
          end
          os.queueEvent("audio_update")
        else
          handle.close()
        end
      end,
      function()
        local _, url, err, handle = os.pullEvent("http_failure")
        local request = pending_requests[url]
        pending_requests[url] = nil
        if request and (request.kind == "music" or request.kind == "pa") then
          local detail = err and (" - " .. err) or ""
          local body
          if handle then
            body = handle.readAll()
            handle.close()
          end
          if body and body ~= "" then
            detail = detail .. " | BODY: " .. body
          end
          log("ERROR", string.format("Failed to fetch %s stream (%s)%s", request.label or request.kind, url, detail))

          audio_state.consecutive_failures = audio_state.consecutive_failures + 1

          if audio_state.consecutive_failures >= 3 then
            log("ERROR", "Too many consecutive failures - stopping playback")
            stop_audio()
            if request.kind == "music" then
              state.now_playing = nil
              os.queueEvent("render_ui")
            elseif request.kind == "pa" then
              if role == "controller" then
                complete_pa_audio()
              else
                clear_marquee()
              end
            end
          else
            stop_audio()
            if request.kind == "music" then
              if role == "controller" then
                os.queueEvent("music_stream_complete")  -- Let supervisorLoop handle it async
              else
                state.now_playing = nil
                os.queueEvent("render_ui")
              end
            elseif request.kind == "pa" then
              if role == "controller" then
                complete_pa_audio()
              else
                clear_marquee()
              end
            end
          end
        end
      end
    )
  end
end

local function supervisorLoop()
  while true do
    local event = { os.pullEvent() }
    local name = event[1]
    if name == "music_stream_complete" and role == "controller" then
      handle_music_complete()
    elseif name == "pa_sequence_complete" and role == "controller" then
      complete_pa_audio()
    elseif name == "timer" then
      -- timers handled elsewhere
    end
  end
end

local function controller_main()
  -- Don't auto-play on startup - let user start playback manually
  if update_checker then
    parallel.waitForAny(commandLoop, uiLoop, audioLoop, networkLoop, httpLoop, controller_broadcast_loop, supervisorLoop, update_checker)
  else
    parallel.waitForAny(commandLoop, uiLoop, audioLoop, networkLoop, httpLoop, controller_broadcast_loop, supervisorLoop)
  end
end

local function station_main()
  station_register()
  if update_checker then
    parallel.waitForAny(commandLoop, uiLoop, audioLoop, networkLoop, httpLoop, supervisorLoop, station_watchdog_loop, update_checker)
  else
    parallel.waitForAny(commandLoop, uiLoop, audioLoop, networkLoop, httpLoop, supervisorLoop, station_watchdog_loop)
  end
end

init()
render_monitors()

if role == "controller" then
  controller_main()
else
  station_main()
end
