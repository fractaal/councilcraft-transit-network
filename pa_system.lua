-- CouncilCraft PA & Entertainment System
-- Standalone controller for local audio playback + announcements

local VERSION = "0.2.13-time-synced-viz"

local dfpwm = require("cc.audio.dfpwm")

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

local DEFAULT_API_BASE = "https://example-pa-endpoint.run.app"
local API_KEY = "COUNCILCRAFT_MINECRAFT_SERVER_XD"
local CHIME_URL = "https://raw.githubusercontent.com/fractaal/councilcraft-transit-network/main/sounds/SG_MRT_BELL.dfpwm"
local DEFAULT_PAUSE_DURATION = 30  -- Default pause duration in seconds for playlist entries

local MONITOR_TEXT_SCALE = 1.5
local MARQUEE_MIN_GAP = 6
local MARQUEE_SCROLL_INTERVAL = 0.15  -- Seconds between marquee scroll ticks

local CONFIG_PATH = "/.pa_config"
local STATE_PATH = "/.pa_state"

local DEBUG = true

local config
local state = {
  now_playing = nil,
  pa_active = false,
  marquee_text = nil,
  marquee_rows_state = {},
  playlist = nil,
  loop_mode = "repeat_all",
  current_index = 1,
  api_base_url = nil,
  paused = false,
  elapsed_seconds = 0,
  track_duration = 0,
  playback_start_time = nil,
  volume = 1.0,  -- Volume multiplier (0.0 to 3.0)
  pa_resume_context = nil,
  pause_timer = nil,  -- Timer ID for playlist pause entries
  autoplay_on_start = false,  -- Whether to auto-start playback on controller boot
  reboot_on_playlist_end = false,  -- Whether to reboot when playlist completes (workaround for freezing)
  redstone_side = nil,  -- Optional analog/digital output for music visualizer
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
  -- Timeline tracking for visualizer sync
  stream_start_epoch = nil,    -- When the current stream started playing
  samples_queued_total = 0,     -- Total samples sent to speakers since stream start
  sample_rate = 48000,          -- ComputerCraft standard sample rate
}

local VALID_REDSTONE_SIDES = {
  left = true,
  right = true,
  top = true,
  bottom = true,
  front = true,
  back = true,
}

local function apply_redstone_output(level)
  if not state.redstone_side or not redstone then
    return
  end

  local side = state.redstone_side
  local analog_level = math.max(0, math.min(15, math.floor((level or 0) * 15 + 0.5)))

  if redstone.setAnalogOutput then
    redstone.setAnalogOutput(side, analog_level)
  else
    -- Fallback for computers without analog control: treat high levels as on
    local threshold = 7  -- ~45%
    redstone.setOutput(side, analog_level > threshold)
  end
end

local function clear_redstone_output()
  if not state.redstone_side or not redstone then
    return
  end
  local side = state.redstone_side
  if redstone.setAnalogOutput then
    redstone.setAnalogOutput(side, 0)
  else
    redstone.setOutput(side, false)
  end
end

local visualizer = {
  enabled = true,
  sample_rate = 48000,
  window_samples = 960,        -- ~20ms frames for tighter sync
  smoothing_factor = 0.25,
  decay_tau_ms = 120,
  render_interval_ms = 25,
  active = false,
  label = nil,
  pending_sum = 0,
  pending_count = 0,
  last_level = 0,
  last_frame_epoch = 0,
  last_render_epoch = 0,
  -- Ring buffer for time-indexed RMS values
  rms_buffer = {},             -- Array of {rms, play_epoch, sample_index}
  rms_buffer_size = 100,       -- ~2 seconds of 20ms windows
  rms_buffer_write = 1,        -- Next write position
  rms_buffer_read = 1,         -- Next read position
}

local function visualizer_should_render()
  return visualizer.enabled and #monitors > 0
end

local function visualizer_queue_render()
  if not visualizer_should_render() then
    return
  end
  local now = os.epoch("utc")
  if now - visualizer.last_render_epoch < visualizer.render_interval_ms then
    return
  end
  visualizer.last_render_epoch = now
  os.queueEvent("render_ui")
end

-- Buffer an RMS value with its target playback time
local function visualizer_buffer_rms(rms, play_epoch, sample_index)
  if not visualizer.enabled or not visualizer.active then
    return
  end

  -- Store in ring buffer
  visualizer.rms_buffer[visualizer.rms_buffer_write] = {
    rms = rms,
    play_epoch = play_epoch,
    sample_index = sample_index
  }

  -- Advance write pointer (wrap around)
  visualizer.rms_buffer_write = (visualizer.rms_buffer_write % visualizer.rms_buffer_size) + 1

  -- If we've caught up to read pointer, advance it (overwriting old data)
  if visualizer.rms_buffer_write == visualizer.rms_buffer_read then
    visualizer.rms_buffer_read = (visualizer.rms_buffer_read % visualizer.rms_buffer_size) + 1
  end
end

-- Sync visualizer to current playback time (stateless)
local function visualizer_sync_to_time()
  if not visualizer.enabled or not visualizer.active then
    return
  end

  if not audio_state.stream_start_epoch then
    return
  end

  local now = os.epoch("utc")
  local target_rms = nil
  local best_distance = math.huge

  -- Find the RMS value closest to current time (but not future)
  local read_pos = visualizer.rms_buffer_read
  while read_pos ~= visualizer.rms_buffer_write do
    local entry = visualizer.rms_buffer[read_pos]
    if entry and entry.play_epoch then
      local distance = now - entry.play_epoch

      -- Only consider values that should have played (not future)
      if distance >= 0 and distance < best_distance then
        best_distance = distance
        target_rms = entry.rms

        -- Advance read pointer past consumed entries
        if distance > 100 then -- More than 100ms old, we've passed it
          visualizer.rms_buffer_read = (read_pos % visualizer.rms_buffer_size) + 1
        end
      end
    end

    read_pos = (read_pos % visualizer.rms_buffer_size) + 1
  end

  -- Apply the RMS value if we found one
  if target_rms then
    local clamped = math.min(1, math.max(0, target_rms))
    visualizer.last_level = (visualizer.last_level * visualizer.smoothing_factor) + (clamped * (1 - visualizer.smoothing_factor))
    visualizer.last_frame_epoch = now
    apply_redstone_output(visualizer.last_level)
  end
end

local function visualizer_apply_rms(rms)
  -- Legacy function kept for compatibility, now just buffers for current time
  if not visualizer.enabled then
    return
  end
  local now = os.epoch("utc")
  visualizer_buffer_rms(rms, now, 0)
  visualizer_sync_to_time()
  visualizer_queue_render()
end

local function visualizer_decay()
  if not visualizer.enabled then
    return
  end

  -- First sync to current playback position
  visualizer_sync_to_time()

  if visualizer.last_frame_epoch == 0 then
    return
  end

  local now = os.epoch("utc")
  local elapsed = now - visualizer.last_frame_epoch
  if elapsed <= 0 or visualizer.decay_tau_ms <= 0 then
    return
  end

  -- Apply decay if no recent update from sync
  if elapsed > 50 then -- Only decay if we haven't synced in 50ms
    local decay = math.exp(-elapsed / visualizer.decay_tau_ms)
    visualizer.last_level = visualizer.last_level * decay
    visualizer.last_frame_epoch = now
    apply_redstone_output(visualizer.last_level)
  end
end

local function visualizer_start(label)
  if not visualizer.enabled then
    return
  end
  visualizer.active = true
  visualizer.label = label
  visualizer.pending_sum = 0
  visualizer.pending_count = 0
  visualizer.last_level = 0
  visualizer.last_frame_epoch = os.epoch("utc")
  -- Clear ring buffer for new stream
  visualizer.rms_buffer = {}
  visualizer.rms_buffer_write = 1
  visualizer.rms_buffer_read = 1
  visualizer_queue_render()
end

local function visualizer_finish()
  if not visualizer.enabled then
    return
  end
  visualizer.active = false
  visualizer.label = nil
  visualizer.pending_sum = 0
  visualizer.pending_count = 0
  visualizer.last_level = 0
  visualizer.last_frame_epoch = os.epoch("utc")
  -- Clear ring buffer
  visualizer.rms_buffer = {}
  visualizer.rms_buffer_write = 1
  visualizer.rms_buffer_read = 1
  apply_redstone_output(0)
  visualizer_queue_render()
end

local function visualizer_feed(buffer, buffer_start_sample)
  if not visualizer.enabled or not visualizer.active then
    return
  end
  if not buffer or not audio_state.stream_start_epoch then
    return
  end

  -- Default to current total if not specified
  buffer_start_sample = buffer_start_sample or audio_state.samples_queued_total

  local sum = visualizer.pending_sum
  local count = visualizer.pending_count
  local sample_offset = 0

  for i = 1, #buffer do
    local sample = buffer[i]
    if type(sample) == "number" then
      local normalized = sample / 127
      sum = sum + (normalized * normalized)
      count = count + 1
      sample_offset = sample_offset + 1

      if count >= visualizer.window_samples then
        local rms = math.sqrt(sum / count)

        -- Calculate when this window will actually play
        local window_start_sample = buffer_start_sample + sample_offset - visualizer.window_samples
        local window_play_epoch = audio_state.stream_start_epoch + (window_start_sample / audio_state.sample_rate) * 1000

        -- Buffer the RMS value with its future play time
        visualizer_buffer_rms(rms, window_play_epoch, window_start_sample)

        sum = 0
        count = 0
      end
    end
  end

  visualizer.pending_sum = sum
  visualizer.pending_count = count
end

local function visualizer_bump(level)
  if not visualizer.enabled then
    return
  end
  visualizer.active = true
  visualizer_apply_rms(level or 0.8)
end

local function visualizer_get_level()
  if not visualizer.enabled then
    return 0
  end
  -- Sync to current playback position first
  visualizer_sync_to_time()
  visualizer_decay()
  return math.max(0, math.min(1, visualizer.last_level))
end

local function visualizer_render_line(monitor, y)
  if not visualizer.enabled or not monitor then
    return
  end

  local level = visualizer_get_level()
  if level <= 0.01 and not visualizer.active then
    if state.redstone_side then
      apply_redstone_output(level)
    end
    return
  end

  local width = select(1, monitor.getSize())
  if width < 16 then
    return
  end

  monitor.setCursorPos(1, y)
  monitor.clearLine()
  monitor.setTextColor(colors.gray)
  monitor.write("AUDIO:")

  local bar_width = math.max(0, width - 9)
  if bar_width <= 0 then
    monitor.setTextColor(colors.white)
    return
  end

  local filled = math.floor(level * bar_width + 0.5)
  monitor.setTextColor(colors.gray)
  monitor.write(" [")
  if filled > 0 then
    local color = colors.orange
    if level >= 0.75 then
      color = colors.lime
    elseif level >= 0.45 then
      color = colors.yellow
    elseif level < 0.2 then
      color = colors.gray
    end
    monitor.setTextColor(color)
    monitor.write(string.rep("#", math.min(filled, bar_width)))
  end
  if filled < bar_width then
    monitor.setTextColor(colors.gray)
    monitor.write(string.rep("-", bar_width - filled))
  end
  monitor.write("]")
  monitor.setTextColor(colors.white)
end

local pending_requests = {}
local http_blockers = 0

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
  term.write(string.format("PA System v%s  [Standalone]", VERSION))
  term.setCursorPos(1, 2)

  local api_label = state.api_base_url or DEFAULT_API_BASE
  local line2 = "API: " .. api_label
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

local function debug(msg, ...)
  if DEBUG then
    local out = "[DEBUG] " .. msg
    if select('#', ...) > 0 then
      out = string.format(out, ...)
    end
    log("DEBUG", out)
  end
end

local function print_help()
  local help_text = [[Available commands:
  help - show this help
  status - display current state
  playlist - list playlist entries
  play - start/resume playback
  pause - pause current track
  stop - stop playback
  next - skip to next track
  goto <index> - jump to track by index
  loop [mode] - get/set loop mode (repeat_all|repeat_one|off)
  add <url> - add track to playlist
  addpause [seconds] - add pause between tracks
  edittitle <index> "title" - edit track title
  remove <index> - remove track from playlist
  move <from> <to> - reorder tracks
  volume [0.0-3.0] - get/set playback volume
  autoplay [on|off] - get/set autoplay on startup
  rebootend [on|off] - reboot when playlist ends
  update - install latest version via composer
  pa "msg" [url] - play a PA announcement (optional audio URL)
  clearpa - clear persistent PA text
  reload - reload state from disk
  setapi <url> - update API base URL
  ampout <side|off> - route amplitude meter to redstone (left/right/top/bottom/front/back)
  clear - clear log window]]
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

local function ensure_pa_state()
  if fs.exists(STATE_PATH) then
    local tbl = load_table(STATE_PATH)
    if tbl then
      if not tbl.playlist or type(tbl.playlist) ~= "table" then
        tbl.playlist = {}
      end
      return tbl
    end
  end

  local default_state = {
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
    api_base_url = state.api_base_url or DEFAULT_API_BASE,
  }

  save_table(STATE_PATH, default_state)
  return default_state
end

local function persistence_setup()
  config = load_table(CONFIG_PATH) or {}

  if config.api_base_url and config.api_base_url ~= "" then
    state.api_base_url = config.api_base_url
  end
  if config.redstone_side and config.redstone_side ~= "" then
    state.redstone_side = config.redstone_side
  end

  if not state.api_base_url then
    term.clear()
    term.setCursorPos(1, 1)
    print("CouncilCraft PA System v" .. VERSION)
    print("First-time setup")
    print("")

    local api_base = input("Enter streaming API base URL (without trailing slash)", DEFAULT_API_BASE)
    if not api_base or api_base == "" then
      api_base = DEFAULT_API_BASE
    end

    state.api_base_url = api_base
    config.api_base_url = api_base
    persist_config()
  end
end

local function refresh_peripherals()
  speakers = {}
  monitors = {}

  for _, speaker in ipairs({ peripheral.find("speaker") }) do
    table.insert(speakers, speaker)
  end

  for _, monitor in ipairs({ peripheral.find("monitor") }) do
    monitor.setTextScale(MONITOR_TEXT_SCALE)
    table.insert(monitors, monitor)
  end

  if #speakers == 0 then
    log("WARN", "No speakers detected. Audio playback will be muted.")
  end

  visualizer_queue_render()
end

-- Removed sync_update_state() - auto update checker disabled

local function init()
  persistence_setup()

  local saved_state = ensure_pa_state()
  state.playlist = saved_state.playlist or {}
  state.loop_mode = saved_state.loop_mode or "repeat_all"
  state.current_index = saved_state.current_index or 1
  state.api_base_url = saved_state.api_base_url or state.api_base_url or DEFAULT_API_BASE
  state.volume = saved_state.volume or 1.0
  state.autoplay_on_start = saved_state.autoplay_on_start or false
  state.reboot_on_playlist_end = saved_state.reboot_on_playlist_end or false

  if not config.api_base_url or config.api_base_url == "" then
    config.api_base_url = state.api_base_url
    persist_config()
  end

  if saved_state.persistent_pa_text and saved_state.persistent_pa_text ~= "" then
    state.marquee_text = saved_state.persistent_pa_text
    state.pa_active = true
    log("INFO", "Restored PA text: " .. saved_state.persistent_pa_text)
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

  if state.redstone_side then
    clear_redstone_output()
  end

  log("INFO", string.format("Playlist entries: %d", #(state.playlist or {})))
  log("INFO", "Type 'help' for command list.")
end

local function persist_pa_state()
  local now = {
    playlist = state.playlist,
    loop_mode = state.loop_mode,
    current_index = state.current_index,
    api_base_url = state.api_base_url,
    volume = state.volume,
    persistent_pa_text = state.marquee_text,
    autoplay_on_start = state.autoplay_on_start,
    reboot_on_playlist_end = state.reboot_on_playlist_end,
  }

  save_table(STATE_PATH, now)
end

local function reload_state()
  local saved_state = load_table(STATE_PATH)
  if not saved_state then
    log("ERROR", "Unable to read " .. STATE_PATH)
    return
  end
  state.playlist = saved_state.playlist or {}
  state.loop_mode = saved_state.loop_mode or "repeat_all"
  state.current_index = saved_state.current_index or 1
  state.api_base_url = saved_state.api_base_url or state.api_base_url or DEFAULT_API_BASE
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
        return message
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

local function render_monitors()
  if #monitors == 0 then
    return
  end

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

    local remaining_lines = height - (line_y - 1)

    -- Show debug timing info if streaming
    if remaining_lines >= 2 and audio_state.status == "streaming" and audio_state.stream_start_epoch then
      local now = os.epoch("utc")
      local elapsed_ms = now - audio_state.stream_start_epoch
      local elapsed_s = elapsed_ms / 1000

      -- Calculate estimated current sample from time
      local estimated_sample = math.floor(elapsed_s * audio_state.sample_rate)

      -- Calculate total duration from samples received
      local total_duration_from_samples = audio_state.samples_queued_total / audio_state.sample_rate

      -- Format debug line
      local debug_text = string.format("S:%d/%d (%.1fs/%.1fs",
        estimated_sample,
        audio_state.samples_queued_total,
        elapsed_s,
        total_duration_from_samples)

      -- Add metadata duration if available
      if state.track_duration and state.track_duration > 0 then
        debug_text = debug_text .. string.format(", meta:%.1fs)", state.track_duration)
      else
        debug_text = debug_text .. ")"
      end

      monitor.setCursorPos(1, height - 1)
      monitor.setTextColor(colors.lightGray)
      monitor.write(debug_text:sub(1, width))

      -- Visualizer on last line
      visualizer_render_line(monitor, height)
    elseif remaining_lines >= 1 then
      -- Just visualizer if not enough space for debug
      visualizer_render_line(monitor, height)
    end

    monitor.setTextColor(colors.white)
  end

  if global_scroll then
    if not marquee_timer then
      marquee_timer = os.startTimer(MARQUEE_SCROLL_INTERVAL)
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
  debug("[stop_audio] Called: status=%s, mode=%s, handle=%s, decoder=%s",
    tostring(audio_state.status),
    tostring(audio_state.mode),
    tostring(audio_state.handle ~= nil),
    tostring(audio_state.decoder ~= nil))

  -- Request graceful stop at next chunk boundary (don't tear down immediately)
  if audio_state.status == "streaming" or audio_state.status == "waiting" then
    audio_state.stop_requested = true
    log("INFO", "Audio stop requested (will complete at next chunk)")
    debug("[stop_audio] Set stop_requested=true, NOT queueing audio_update event")

    -- Cancel any pending HTTP requests
    for url, ctx in pairs(pending_requests) do
      if ctx.kind == "music" or ctx.kind == "pa" then
        pending_requests[url] = nil
      end
    end

    stop_time_tracker()
  else
    debug("[stop_audio] No-op: status is '%s' (not streaming/waiting)", tostring(audio_state.status))
  end
end

local function schedule_marquee()
  if not marquee_timer then
    marquee_timer = os.startTimer(MARQUEE_SCROLL_INTERVAL)
  end
end

local function clear_marquee()
  state.pa_active = false
  state.marquee_text = nil
  if state.marquee_rows_state then
    state.marquee_rows_state["pa"] = nil
  end
  os.queueEvent("render_ui")

  -- Clear persistent PA text
  persist_pa_state()
end

local function resolve_audio_url(url)
  if not url then
    return { type = "error", error = "URL is nil" }
  end

  if url:sub(1, 11) == "internal://" then
    local filename = url:sub(12)  -- strip "internal://"
    local path = "/apps/pa_system/sounds/" .. filename .. ".dfpwm"
    if fs.exists(path) then
      return { type = "internal", path = path, url = url }
    else
      return { type = "error", error = "File not found: " .. path }
    end
  else
    return { type = "http", url = url }
  end
end

local function build_api_url(path, track_url)
  if type(track_url) ~= "string" or track_url == "" then
    return nil, "missing track url"
  end

  if track_url:sub(1, 11) == "internal://" then
    return nil, "internal track"
  end

  local base = state.api_base_url or DEFAULT_API_BASE
  if base:sub(-1) == "/" then
    base = base:sub(1, -2)
  end

  local encoded_track = textutils.urlEncode(track_url)
  local encoded_key = textutils.urlEncode(API_KEY)
  return base .. path .. "?track=" .. encoded_track .. "&key=" .. encoded_key
end

local function request_stream(kind, url, context)
  debug("request_stream called with kind=%s url=%s context=%s", tostring(kind), tostring(url), textutils.serialize(context))

  context = context or {}
  context.kind = kind

  -- Resolve URL to check if it's internal or HTTP
  debug("Resolving audio URL: %s", tostring(url))
  local resolved = resolve_audio_url(url)
  debug("Resolved type: %s", tostring(resolved and resolved.type or "nil"))

  if resolved.type == "internal" then
    -- Handle internal file directly
    log("INFO", string.format("Opening internal file (%s): %s", kind, resolved.path))
    debug("Attempting fs.open on: %s", resolved.path)

    local ok, file_handle = pcall(fs.open, resolved.path, "rb")
    debug("fs.open result: ok=%s, file_handle=%s", tostring(ok), tostring(file_handle))
    if not ok or not file_handle then
      log("ERROR", "Failed to open internal file: " .. resolved.path)
      audio_state.status = "idle"
      debug("FAILED: open file_handle")
      return
    end

    -- Validate handle has required methods
    debug("Checking file_handle methods (read/close)")
    if not file_handle.read or not file_handle.close then
      log("ERROR", "Invalid file handle for: " .. resolved.path)
      debug("FAILED: missing method read/close on file_handle")
      pcall(function() file_handle.close() end)
      audio_state.status = "idle"
      return
    end

    -- Set up audio state for streaming from local file
    debug("Setting up audio_state for streaming: set handle, status etc.")
    audio_state.handle = file_handle
    audio_state.status = "streaming"
    -- Initialize timeline tracking
    audio_state.stream_start_epoch = os.epoch("utc")
    audio_state.samples_queued_total = 0

    -- Safely read DFPWM header
    debug("Reading DFPWM header")
    local header_ok, header = pcall(function() return file_handle.read(4) end)
    debug("Header read: ok=%s, header=%s", tostring(header_ok), tostring(header and ("[" .. string.gsub(header, "[%z\1-\31\127-\255]", function(c) return string.format("\\x%02X", string.byte(c)) end) .. "]" or "nil")))
    if not header_ok or not header then
      log("ERROR", "Failed to read DFPWM header from: " .. resolved.path)
      debug("FAILED: reading DFPWM header")
      pcall(function() file_handle.close() end)
      audio_state.status = "idle"
      return
    end

    audio_state.start = header
    audio_state.chunk_size = 16 * 1024 - 4
    audio_state.consecutive_failures = 0
    debug("Audio state after header: chunk_size=%s, start(header) set", tostring(audio_state.chunk_size))
    debug("Checking dfpwm module availability: %s", tostring(dfpwm ~= nil))
    if dfpwm and dfpwm.make_decoder then
      debug("Calling dfpwm.make_decoder()")
      audio_state.decoder = dfpwm.make_decoder()
      debug("Created DFPWM decoder: %s", tostring(audio_state.decoder ~= nil))
      if audio_state.decoder then
        visualizer_start(context.label or kind)
      end
    else
      debug("CRITICAL: dfpwm module or make_decoder not available!")
      log("ERROR", "DFPWM decoder unavailable - audio will not play")
      audio_state.decoder = nil
    end

    if kind == "music" then
      debug("Starting time tracker for music")
      start_time_tracker()
    end

    debug("Queueing audio_update event")
    os.queueEvent("audio_update")
  elseif resolved.type == "http" then
    -- Handle HTTP request as before
    log("INFO", string.format("HTTP request queued (%s): %s", kind, url))
    debug("Queueing HTTP stream: %s", url)
    pending_requests[url] = context
    http.request({ url = url, method = "GET", binary = true })
    debug("HTTP request submitted")
  else
    -- Error case
    log("ERROR", string.format("Failed to resolve URL (%s): %s", kind, resolved.error or "unknown error"))
    debug("FAILED: resolve_audio_url: type=%s, error=%s", tostring(resolved and resolved.type or "nil"), tostring(resolved and resolved.error or "nil"))
    audio_state.status = "idle"
  end
end

local function fetch_track_metadata(url)
  local info_url, err = build_api_url("/info", url)
  if not info_url then
    if err ~= "internal track" then
      log("WARN", string.format("Cannot fetch metadata for %s (%s)", tostring(url), err or "unknown reason"))
    end
    return nil
  end

  log("INFO", "Fetching metadata: " .. info_url)

  http_blockers = http_blockers + 1
  local ok, response, err = pcall(http.get, info_url)
  http_blockers = math.max(0, http_blockers - 1)

  if not ok then
    log("WARN", "Metadata request threw error: " .. tostring(response))
    return nil
  end

  if not response then
    log("WARN", "Metadata request failed: " .. (err or info_url))
    return nil
  end

  local body = response.readAll()
  response.close()

  if not body or body == "" then
    log("WARN", "Metadata response empty for " .. info_url)
    return nil
  end

  local ok, data = pcall(textutils.unserialiseJSON, body)
  if not ok or not data then
    log("WARN", "Unable to parse metadata for track " .. tostring(url))
    return nil
  end

  return {
    title = data.title,
    artist = data.channel,
    duration = data.durationSeconds
  }
end

local function request_info(url, index)
  local metadata = fetch_track_metadata(url)
  if not metadata then
    return
  end

  local entry = state.playlist and state.playlist[index]
  if not entry then
    return
  end

  local updated = false
  if metadata.title and metadata.title ~= "" then
    entry.title = metadata.title
    updated = true
  end
  if metadata.artist and metadata.artist ~= "" then
    entry.artist = metadata.artist
    updated = true
  end
  if metadata.duration then
    entry.duration = metadata.duration
    updated = true
  end

  if updated then
    persist_pa_state()
    if state.now_playing and state.now_playing.url == entry.url then
      state.now_playing.title = entry.title
      state.now_playing.artist = entry.artist
      state.track_duration = entry.duration or 0
      os.queueEvent("render_ui")
    end
  end
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
  if type(entry.url) ~= "string" or entry.url == "" then
    log("ERROR", "Cannot start track: playlist entry missing URL")
    return
  end

  -- Resolve URL to check if it's internal
  local resolved = resolve_audio_url(entry.url)
  if resolved.type == "error" then
    log("ERROR", string.format("Cannot start track: %s", resolved.error or "unknown error"))
    return
  end
  local is_internal = (resolved.type == "internal")

  -- Always fetch metadata for HTTP tracks (mandatory now)
  if not is_internal and (not entry.duration or not entry.title) then
    local metadata = fetch_track_metadata(entry.url)
    if metadata then
      if metadata.title and metadata.title ~= "" then
        entry.title = metadata.title
      end
      if metadata.artist and metadata.artist ~= "" then
        entry.artist = metadata.artist
      end
      if metadata.duration then
        entry.duration = metadata.duration
      end
      persist_pa_state()
    else
      -- Log warning but continue - we'll just not have duration info
      log("WARN", "Could not fetch metadata, proceeding without duration info")
    end
  end

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
    log("INFO", string.format("Starting track: %s (%s, %s seconds)", entry.title, entry.url or "", entry.duration or "unknown"))
  else
    log("INFO", "Starting track: " .. (entry.url or "(unknown)"))
  end

  local stream_url
  if is_internal then
    -- For internal files, use the internal:// URL directly
    stream_url = entry.url
  else
    -- For HTTP URLs, build the API streaming URL
    local built_url, err = build_api_url("/stream", entry.url)
    if not built_url then
      log("ERROR", string.format("Cannot build stream URL for %s (%s)", tostring(entry.url), err or "unknown reason"))
      return
    end
    stream_url = built_url
  end

  if #speakers > 0 then
    debug("[start_music_stream] Calling stop_audio() before starting new stream")
    stop_audio()

    -- Wait for audio to actually stop before starting new stream
    debug("[start_music_stream] Entering blocking wait for audio_state.status == 'idle' (current: %s)", tostring(audio_state.status))
    local wait_iterations = 0
    while audio_state.status ~= "idle" do
      wait_iterations = wait_iterations + 1
      if wait_iterations % 10 == 1 then
        debug("[start_music_stream] Still waiting for idle (iteration %d, status=%s)", wait_iterations, tostring(audio_state.status))
      end
      os.pullEvent("audio_update")
    end
    debug("[start_music_stream] Audio stopped, continuing (waited %d iterations)", wait_iterations)

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
    os.queueEvent("render_ui")
    log("WARN", "Playlist empty; nothing to play")
    return
  end

  local entry = state.playlist[state.current_index]
  if not entry then
    state.current_index = 1
    entry = state.playlist[state.current_index]
  end

  -- Check if this is a pause entry
  if entry.type == "pause" then
    local duration = entry.duration or DEFAULT_PAUSE_DURATION
    log("INFO", string.format("Pausing playlist for %d seconds", duration))

    -- Clear now playing and stop audio
    state.now_playing = nil
    state.paused = false
    os.queueEvent("render_ui")

    -- Start pause timer
    state.pause_timer = os.startTimer(duration)

    -- Advance index for next play
    if state.loop_mode == "repeat_one" then
      -- stay on same index
    else
      state.current_index = state.current_index + 1
      if state.current_index > #state.playlist then
        if state.reboot_on_playlist_end then
          -- Playlist complete - reboot instead of wrapping
          state.current_index = 1
          persist_pa_state()
          log("INFO", "Playlist complete - rebooting per rebootend setting...")
          os.sleep(1)  -- Give time for log to display
          os.reboot()
        elseif state.loop_mode == "off" then
          -- Stop playback at end of playlist
          state.current_index = 1
          log("INFO", "Playlist complete (loop mode: off)")
          return
        else
          state.current_index = 1
        end
      end
    end

    persist_pa_state()
    return
  end

  -- Normal track entry - always fetch fresh metadata for HTTP URLs
  if entry.url and entry.url:sub(1, 11) ~= "internal://" then
    -- Always fetch metadata to ensure we have duration
    local metadata = fetch_track_metadata(entry.url)
    if metadata then
      if metadata.title and metadata.title ~= "" then
        entry.title = metadata.title
      end
      if metadata.artist and metadata.artist ~= "" then
        entry.artist = metadata.artist
      end
      if metadata.duration then
        entry.duration = metadata.duration
      end
      persist_pa_state()
    end
  end

  start_music_stream(entry)

  if state.loop_mode == "repeat_one" then
    -- stay on same index
  else
    state.current_index = state.current_index + 1
    if state.current_index > #state.playlist then
      if state.reboot_on_playlist_end then
        -- Playlist complete - reboot instead of wrapping
        state.current_index = 1
        persist_pa_state()
        log("INFO", "Playlist complete - rebooting per rebootend setting...")
        os.sleep(1)  -- Give time for log to display
        os.reboot()
      elseif state.loop_mode == "off" then
        -- Stop playback at end of playlist
        state.current_index = 1
        persist_pa_state()
        log("INFO", "Playlist complete (loop mode: off)")
        return
      else
        state.current_index = 1
      end
    end
  end

  persist_pa_state()
end

local function start_current_track()
  debug("[start_current_track] Called: audio_state.status=%s, current_index=%d",
    tostring(audio_state.status), state.current_index)

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
  debug("[start_current_track] Starting track at index %d: %s", index, entry.url or "(no url)")
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
  stop_audio()
end

local start_next_audio_in_queue

local function queue_pa_sequence(audio_url)
  if not audio_url or audio_url == "" then
    return
  end

  debug("[queue_pa_sequence] Calling stop_audio() before starting PA")
  stop_audio()

  -- Wait for audio to actually stop before starting PA sequence
  debug("[queue_pa_sequence] Entering blocking wait for audio_state.status == 'idle' (current: %s)", tostring(audio_state.status))
  local wait_iterations = 0
  while audio_state.status ~= "idle" do
    wait_iterations = wait_iterations + 1
    if wait_iterations % 10 == 1 then
      debug("[queue_pa_sequence] Still waiting for idle (iteration %d, status=%s)", wait_iterations, tostring(audio_state.status))
    end
    os.pullEvent("audio_update")
  end
  debug("[queue_pa_sequence] Audio stopped, continuing (waited %d iterations)", wait_iterations)

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

  -- Persist PA text so it survives reboots
  persist_pa_state()

  log("INFO", "Starting PA: " .. marquee_text)

  if has_audio then
    local ok = pause_music()
    if not ok and state.pa_resume_context then
      -- Failed to pause (probably nothing playing); drop resume context
      state.pa_resume_context = nil
    end
  end

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
          marquee_timer = os.startTimer(MARQUEE_SCROLL_INTERVAL)
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
  -- Track where this buffer starts in the stream
  local buffer_start_sample = audio_state.samples_queued_total

  -- Feed visualizer with sample position info
  visualizer_feed(buffer, buffer_start_sample)

  if #speakers == 0 then
    -- Still need to track samples even without speakers
    if buffer then
      audio_state.samples_queued_total = audio_state.samples_queued_total + #buffer
    end
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

  -- Update total samples after successful queue
  if buffer then
    audio_state.samples_queued_total = audio_state.samples_queued_total + #buffer
  end
end

local function start_speaker_flush(mode)
  debug("[start_speaker_flush] Called with mode=%s", tostring(mode))
  if not audio_state.active_speakers then
    audio_state.active_speakers = {}
  end

  local pending = {}
  local count = 0
  for name in pairs(audio_state.active_speakers) do
    pending[name] = true
    count = count + 1
    debug("[start_speaker_flush] Tracking speaker: %s", tostring(name))
  end

  if count == 0 then
    debug("[start_speaker_flush] No active speakers, returning false")
    return false
  end

  audio_state.status = "flushing"
  audio_state.flush_mode = mode
  audio_state.flush_pending = pending
  audio_state.flush_remaining = count
  audio_state.flush_timeout = os.startTimer(0.5)
  debug("[start_speaker_flush] Started flush: count=%d, timeout_id=%s", count, tostring(audio_state.flush_timeout))
  return true
end

local function finalize_speaker_flush()
  local mode = audio_state.flush_mode
  debug("[finalize_speaker_flush] Called: mode=%s, remaining=%d",
    tostring(mode),
    audio_state.flush_remaining or 0)

  audio_state.flush_pending = nil
  audio_state.flush_remaining = 0
  audio_state.flush_mode = nil
  audio_state.flush_timeout = nil
  audio_state.active_speakers = {}

  audio_state.status = "idle"
  audio_state.mode = nil

  visualizer_finish()

  if mode == "music" then
    debug("[finalize_speaker_flush] Queueing music_stream_complete event")
    os.queueEvent("music_stream_complete")
  end
  debug("[finalize_speaker_flush] Flush finalized, status now idle")
end

local function audioLoop()
  while true do
    debug("[audioLoop] Iteration start: status=%s, handle=%s, decoder=%s, mode=%s",
      tostring(audio_state.status),
      tostring(audio_state.handle ~= nil),
      tostring(audio_state.decoder ~= nil),
      tostring(audio_state.mode))

    if audio_state.status == "streaming" and audio_state.handle and audio_state.decoder then
      debug("[audioLoop] Condition MET: entering streaming processing")
      -- Check for graceful stop request
      if audio_state.stop_requested then
        debug("[audioLoop] Processing stop_requested=true, cleaning up gracefully")
        -- Graceful cleanup at chunk boundary
        if audio_state.handle and audio_state.handle.close then
          pcall(function() audio_state.handle.close() end)
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
        -- Reset timeline tracking
        audio_state.stream_start_epoch = nil
        audio_state.samples_queued_total = 0

        -- Stop speakers
        for _, speaker in ipairs(speakers) do
          speaker.stop()
        end

        log("INFO", "Audio playback halted gracefully")
        os.queueEvent("audio_update")  -- Wake up any waiting threads
        visualizer_finish()
      else
        -- Guard against invalid handle
        local ok, chunk = pcall(function()
          return audio_state.handle and audio_state.handle.read and audio_state.handle.read(audio_state.chunk_size)
        end)

        if not ok or not chunk then
          -- Handle read failed or reached end of stream
          if audio_state.handle and audio_state.handle.close then
            pcall(function() audio_state.handle.close() end)
          end
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
              visualizer_finish()
            end
          elseif audio_state.mode == "pa" then
            audio_state.status = "waiting"
            visualizer_finish()
            start_next_audio_in_queue()
          else
            audio_state.status = "idle"
            visualizer_finish()
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
        debug("[audioLoop] Entered flushing loop: flush_remaining=%d, flush_timeout=%s",
          audio_state.flush_remaining or 0,
          tostring(audio_state.flush_timeout))

        -- Re-arm the timeout to ensure we have a fresh timer ID
        -- (original timer may have fired before we entered this loop)
        if audio_state.flush_timeout then
          pcall(os.cancelTimer, audio_state.flush_timeout)
        end
        audio_state.flush_timeout = os.startTimer(0.5)
        debug("[audioLoop] Re-armed flush timeout: new_id=%s", tostring(audio_state.flush_timeout))

        local flush_iterations = 0
        while audio_state.status == "flushing" do
          flush_iterations = flush_iterations + 1
          if flush_iterations % 20 == 1 then
            debug("[audioLoop] Flushing iteration %d: remaining=%d, timeout_id=%s",
              flush_iterations,
              audio_state.flush_remaining or 0,
              tostring(audio_state.flush_timeout))
          end
          local event = { os.pullEvent() }
          local name = event[1]
          if name == "speaker_audio_empty" then
            local device = event[2]
            debug("[audioLoop] speaker_audio_empty from %s (pending: %s)", tostring(device), tostring(audio_state.flush_pending and audio_state.flush_pending[device] or false))
            if audio_state.flush_pending and device and audio_state.flush_pending[device] then
              audio_state.flush_pending[device] = nil
              audio_state.flush_remaining = audio_state.flush_remaining - 1
              debug("[audioLoop] Speaker drained, remaining=%d", audio_state.flush_remaining)
              if audio_state.flush_remaining <= 0 then
                debug("[audioLoop] All speakers drained, finalizing flush")
                finalize_speaker_flush()
              end
            end
          elseif name == "timer" then
            local timer_id = event[2]
            debug("[audioLoop] Timer event: id=%s, expected_flush_timeout=%s, match=%s",
              tostring(timer_id),
              tostring(audio_state.flush_timeout),
              tostring(audio_state.flush_timeout and timer_id == audio_state.flush_timeout))
            if audio_state.flush_timeout and timer_id == audio_state.flush_timeout then
              debug("[audioLoop] Flush timeout reached, finalizing")
              finalize_speaker_flush()
            else
              -- DO NOT RE-QUEUE: This causes runaway timer creation in other coroutines
              -- Just ignore non-matching timers - parallel coroutines have their own event copies
              if flush_iterations % 20 == 1 then
                debug("[audioLoop] Timer mismatch (id=%s), ignoring", tostring(timer_id))
              end
            end
          else
            -- DO NOT RE-QUEUE: Events are already copied to other parallel coroutines
            -- Re-queueing causes infinite loops and runaway event creation
            if flush_iterations % 20 == 1 then
              debug("[audioLoop] Flushing: ignoring event '%s'", tostring(name))
            end
          end
        end
        debug("[audioLoop] Exited flushing loop after %d iterations", flush_iterations)
      else
        debug("[audioLoop] Condition FAILED: waiting for audio_update event (status=%s, handle=%s, decoder=%s)",
          tostring(audio_state.status),
          tostring(audio_state.handle ~= nil),
          tostring(audio_state.decoder ~= nil))
        os.pullEvent("audio_update")
        debug("[audioLoop] Woke up from audio_update event")
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
    local parts = {
      "api=" .. (state.api_base_url or DEFAULT_API_BASE),
      string.format("playlist=%d", state.playlist and #state.playlist or 0),
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
    if state.paused then
      table.insert(parts, "playback=paused")
    elseif audio_state.status == "streaming" then
      table.insert(parts, "playback=streaming")
    else
      table.insert(parts, "playback=idle")
    end
    log("INFO", "Status: " .. table.concat(parts, " | "))
  elseif cmd == "playlist" then
    if not state.playlist or #state.playlist == 0 then
      log("WARN", "Playlist empty")
    else
      for index, entry in ipairs(state.playlist) do
        local marker = (state.current_index == index) and "*" or " "
        local display
        if entry.type == "pause" then
          local duration = entry.duration or DEFAULT_PAUSE_DURATION
          display = string.format("(pause: %ds)", duration)
        else
          display = entry.title or entry.url or "(untitled)"
        end
        log("INFO", string.format("%s[%d] %s", marker, index, display))
      end
    end
  elseif cmd == "next" then
    advance_playlist()
  elseif cmd == "stop" then
    stop_music()
    state.now_playing = nil
    state.paused = false
    os.queueEvent("render_ui")
    log("INFO", "Playback stopped")
  elseif cmd == "play" then
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
  elseif cmd == "pause" then
    local ok, message = pause_music()
    if ok then
      log("INFO", message)
    else
      log("WARN", message)
    end
  elseif cmd == "goto" then
    if rest == "" then
      log("WARN", "Usage: goto <index>")
    else
      local index = tonumber(rest)
      if not index or index < 1 or index > #state.playlist then
        log("WARN", string.format("Invalid index (must be 1-%d)", #state.playlist))
      else
        debug("[goto] Jumping to track #%d (current audio_state: status=%s, mode=%s)",
          index, tostring(audio_state.status), tostring(audio_state.mode))
        state.current_index = index
        debug("[goto] Calling stop_music()")
        stop_music()
        debug("[goto] Calling start_current_track()")
        start_current_track()
        persist_pa_state()
        log("INFO", string.format("Jumped to track #%d", index))
        debug("[goto] Command completed")
      end
    end
  elseif cmd == "loop" then
    if rest == "" then
      log("INFO", string.format("Current loop mode: %s", state.loop_mode))
    else
      local mode = rest:lower()
      if mode == "repeat_all" or mode == "all" then
        state.loop_mode = "repeat_all"
        persist_pa_state()
        log("INFO", "Loop mode set to: repeat_all")
      elseif mode == "repeat_one" or mode == "one" then
        state.loop_mode = "repeat_one"
        persist_pa_state()
        log("INFO", "Loop mode set to: repeat_one")
      elseif mode == "off" or mode == "none" then
        state.loop_mode = "off"
        persist_pa_state()
        log("INFO", "Loop mode set to: off")
      else
        log("WARN", "Invalid loop mode. Use: repeat_all, repeat_one, or off")
      end
    end
  elseif cmd == "move" then
    if rest == "" then
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
      log("INFO", "Installing latest version via composer...")
      local ok, result = composer.install("pa-system")
      if ok then
        log("INFO", "Update installed. Please restart to run the latest version.")
      else
        log("ERROR", "Composer update failed: " .. tostring(result or "unknown"))
      end
    end
  elseif cmd == "pa" then
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
  elseif cmd == "clearpa" then
    clear_marquee()
    log("INFO", "PA text cleared")
  elseif cmd == "add" then
    if rest == "" then
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
  elseif cmd == "addpause" then
    local duration = tonumber(rest) or DEFAULT_PAUSE_DURATION
    local entry = { type = "pause", duration = duration }
    table.insert(state.playlist, entry)
    persist_pa_state()
    log("INFO", string.format("Added pause entry #%d: %d seconds", #state.playlist, duration))
  elseif cmd == "edittitle" then
    if rest == "" then
      log("WARN", 'Usage: edittitle <index> "new title"')
    else
      local index, title = rest:match('^(%d+)%s+"(.-)"$')
      index = tonumber(index)
      if not index or not title or index < 1 or index > #state.playlist then
        log("WARN", string.format('Usage: edittitle <index> "new title". Valid indices: 1-%d', #state.playlist))
      else
        local entry = state.playlist[index]
        if entry.type == "pause" then
          log("WARN", "Cannot edit title of pause entry")
        else
          local old_title = entry.title or entry.url or "(untitled)"
          entry.title = title
          persist_pa_state()
          log("INFO", string.format('Updated track #%d: "%s" -> "%s"', index, old_title, title))
        end
      end
    end
  elseif cmd == "remove" then
    if rest == "" then
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
    if rest == "" then
      log("WARN", "Usage: setapi <url>")
    else
      local trimmed_url = rest:gsub("^%s+", ""):gsub("%s+$", "")
      state.api_base_url = trimmed_url
      config.api_base_url = trimmed_url
      persist_config()
      persist_pa_state()
      log("INFO", "API base updated to " .. trimmed_url)
    end
  elseif cmd == "ampout" then
    local argument = rest and rest:gsub("^%s+", ""):gsub("%s+$", ""):lower() or ""
    if argument == "" then
      if state.redstone_side then
        log("INFO", string.format("Visualizer redstone output: %s", state.redstone_side))
      else
        log("INFO", "Visualizer redstone output disabled. Use ampout <side> to enable.")
      end
    elseif argument == "off" then
      if state.redstone_side then
        clear_redstone_output()
        state.redstone_side = nil
        config.redstone_side = nil
        persist_config()
        log("INFO", "Visualizer redstone output disabled")
      else
        log("INFO", "Visualizer redstone output already disabled")
      end
    elseif VALID_REDSTONE_SIDES[argument] then
      if state.redstone_side and state.redstone_side ~= argument then
        clear_redstone_output()
      end
      state.redstone_side = argument
      config.redstone_side = argument
      persist_config()
      apply_redstone_output(visualizer_get_level())
      log("INFO", "Visualizer redstone output set to side: " .. argument)
    else
      log("WARN", "Invalid side. Use: left, right, top, bottom, front, back, or off")
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
  elseif cmd == "autoplay" then
    if rest == "" then
      log("INFO", string.format("Autoplay on start: %s", state.autoplay_on_start and "on" or "off"))
    else
      local value = rest:lower()
      if value == "on" or value == "true" or value == "1" then
        state.autoplay_on_start = true
        persist_pa_state()
        log("INFO", "Autoplay on start enabled")
      elseif value == "off" or value == "false" or value == "0" then
        state.autoplay_on_start = false
        persist_pa_state()
        log("INFO", "Autoplay on start disabled")
      else
        log("WARN", "Usage: autoplay [on|off]")
      end
    end
  elseif cmd == "rebootend" then
    if rest == "" then
      log("INFO", string.format("Reboot on playlist end: %s", state.reboot_on_playlist_end and "on" or "off"))
    else
      local value = rest:lower()
      if value == "on" or value == "true" or value == "1" then
        state.reboot_on_playlist_end = true
        persist_pa_state()
        log("INFO", "Reboot on playlist end enabled (workaround for freezing)")
      elseif value == "off" or value == "false" or value == "0" then
        state.reboot_on_playlist_end = false
        persist_pa_state()
        log("INFO", "Reboot on playlist end disabled")
      else
        log("WARN", "Usage: rebootend [on|off]")
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
    if http_blockers > 0 or next(pending_requests) == nil then
      os.sleep(0.05)
    else
    parallel.waitForAny(
      function()
        local _, url, handle = os.pullEvent("http_success")
        local request = pending_requests[url]
        pending_requests[url] = nil

        if not request then
          if handle and handle.close then
            handle.close()
          else
            log("WARN", "HTTP request to " .. tostring(url) .. " completed but no pending request found")
          end
          return
        end

        log("INFO", string.format("Stream ready (%s): %s", request.label or request.kind, url))
        debug("[httpLoop] HTTP success, setting up audio_state")
        audio_state.handle = handle
        audio_state.status = "streaming"
        audio_state.start = handle.read(4)
        audio_state.chunk_size = 16 * 1024 - 4
        audio_state.consecutive_failures = 0
        -- Initialize timeline tracking for HTTP streams
        audio_state.stream_start_epoch = os.epoch("utc")
        audio_state.samples_queued_total = 0
        debug("[httpLoop] Checking dfpwm module availability: %s", tostring(dfpwm ~= nil))
        if dfpwm and dfpwm.make_decoder then
          debug("[httpLoop] Calling dfpwm.make_decoder()")
          audio_state.decoder = dfpwm.make_decoder()
          debug("[httpLoop] Created DFPWM decoder: %s", tostring(audio_state.decoder ~= nil))
          if audio_state.decoder then
            visualizer_start(request.label or request.kind)
          end
        else
          debug("[httpLoop] CRITICAL: dfpwm module or make_decoder not available!")
          log("ERROR", "DFPWM decoder unavailable - audio will not play")
          audio_state.decoder = nil
        end
        if request.kind == "music" then
          start_time_tracker()
        end
        debug("[httpLoop] Queueing audio_update event")
        os.queueEvent("audio_update")
      end,
      function()
        local _, url, err, handle = os.pullEvent("http_failure")
        local request = pending_requests[url]
        pending_requests[url] = nil
        if not request then
          if handle and handle.close then
            handle.close()
          end
          return
        end

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
        stop_audio()

        if request.kind == "music" then
          state.now_playing = nil
          os.queueEvent("render_ui")
          if audio_state.consecutive_failures < 3 then
            os.queueEvent("music_stream_complete")
          end
        elseif request.kind == "pa" then
          complete_pa_audio()
        end

        if audio_state.consecutive_failures >= 3 then
          log("ERROR", "Too many consecutive failures - halting retries")
        end
      end
    )
    end
  end
end

local function supervisorLoop()
  while true do
    local event = { os.pullEvent() }
    local name = event[1]
    if name == "music_stream_complete" then
      handle_music_complete()
    elseif name == "pa_sequence_complete" then
      complete_pa_audio()
    elseif name == "timer" then
      local timer_id = event[2]
      if state.pause_timer and timer_id == state.pause_timer then
        state.pause_timer = nil
        log("INFO", "Pause complete, advancing playlist")
        advance_playlist()
      end
    end
  end
end

local function main()
  if state.autoplay_on_start and state.playlist and #state.playlist > 0 then
    log("INFO", "Autoplay enabled - starting playback")
    start_current_track()
  end

  parallel.waitForAny(commandLoop, uiLoop, audioLoop, httpLoop, supervisorLoop)
end

init()
render_monitors()
main()
