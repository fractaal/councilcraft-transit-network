# CLAUDE.md
This file provides guidance to Claude Code (claude.ai/code) and various other AI agents and tooling when working with code in this repository.

## Project Overview

CouncilCraft Transit Network is a **ComputerCraft: Tweaked** automated transit system for Minecraft. It's a single-file monolithic Lua application (`transit.lua`) that runs on in-game computers to coordinate minecart stations across a network using wired modems.

**Key Concept**: This is NOT a traditional software project - it's Minecraft mod scripting. All code runs inside ComputerCraft computers in-game using Lua 5.2.

## Architecture

### Monolithic Design
- **Single file**: `transit.lua` (~1425 lines) contains ALL code
- **Shared libraries**: Protocol, network, display, and animation systems are embedded at the top
- **Dual mode**: Same file runs as either Station Terminal OR Operations Center based on saved config

### Core Components (in order within transit.lua)
1. **Protocol** (lines 10-82): Message types (DISCOVER, REGISTER, STATUS, DISPATCH, HEARTBEAT, COUNTDOWN) and serialization
2. **Network** (lines 88-129): Modem communication layer, message transmission/reception
3. **Display & Animations** (lines 133-234): Terminal/monitor output, spinners, icons, progress bars, flashing effects
4. **Configuration** (lines 240-390): Auto-setup wizard, config persistence, migration system
5. **Audio** (lines 393-435): Singapore MRT-inspired noteblock sounds (arrival chimes, door closing chirps)
6. **Station Mode** (lines 441-849): Cart detection, state machine (IN_TRANSIT → BOARDING → DEPARTING), trip timing analytics
7. **Operations Center Mode** (lines 856-1403): Network coordinator, multi-station dashboard, dispatch controller

### State Machine (Stations)
```
IN_TRANSIT → (cart arrives) → ARRIVED → (announcements complete) → BOARDING → (DISPATCH received) → DEPARTING → (cart leaves) → IN_TRANSIT
```

**State Descriptions:**
- **IN_TRANSIT**: No cart present, waiting for arrival
- **ARRIVED**: Cart has arrived, playing audio announcements. Station is BLOCKING during audio playback and cannot respond to DISPATCH signals. Ops center sees the cart but doesn't start dispatch countdown yet.
- **BOARDING**: Announcements complete, station is ready to board passengers and accept DISPATCH signal. Ops center starts dispatch countdown only when ALL stations reach this state.
- **DEPARTING**: DISPATCH received, cart is departing

### Network Protocol
- **Channel**: 100 (default, configurable)
- **Discovery**: Ops center broadcasts DISCOVER, stations respond with REGISTER
- **Status**: Stations send STATUS every 0.5s with cart presence, trip timing, state
- **Dispatch**: Ops center sends DISPATCH when all carts present, triggers DEPARTING state
- **Heartbeat**: Keep-alive messages every 5s
- **Update Command** (v0.10+): Ops center sends UPDATE_COMMAND, stations auto-update from GitHub raw and reboot

### Trip Timing System (v0.9 feature)
- Tracks last 10 trips per station
- Real-time status: ON TIME (±10%), EARLY (<-5%), DELAYED (>5%)
- Live ETA calculation during transit: "Arriving in Xs"
- Displays current vs average: "45s/38s"

## Development Commands

### Running the System
**IMPORTANT**: This code runs INSIDE Minecraft using ComputerCraft computers, not on your host machine.

1. **In Minecraft**: Place a computer and run:
   ```lua
   edit transit.lua
   -- Paste the code, save with Ctrl
   transit
   ```

   NOTE: The above is a deprecated way -- you should instead just wget the raw github user content file from the internet in a CC computer.

2. **First run**: Interactive setup wizard configures the computer as Station or Ops Center

3. **Subsequent runs**: Loads saved config from `/.transit_config`, auto-starts

### Testing
- **Manual dispatch**: In ops center console, press `d`
- **Reset stations**: In ops center console, press `r`
- **View stations**: Press `s`
- **Remote update**: Press `u` (updates all stations from GitHub raw)
- **Help**: Press `h`

### Updating Deployed Systems

#### Remote Update (v0.10+) - RECOMMENDED
From the ops center console, press `u` to update ALL stations at once:
1. Ops center broadcasts UPDATE_COMMAND to all stations
2. Each station automatically deletes old version, downloads from GitHub, and reboots
3. No manual intervention needed per-station

~~The pastebin ID is configured in `SCRIPT_OPS_CONFIG.pastebin_id` (line 278).~~
We use GitHub now as our source of truth. You can also update a single machine with `transit -u`.

#### Manual Update (per-computer)
Run `transit -u` on an individual computer (optionally with a custom URL):
```lua
transit -u
```

## Code Style & Conventions

### Lua Idioms
- **Tables start at 1**: `for i = 1, #array do` (NOT 0-indexed)
- **Globals by default**: Prefix local variables with `local`
- **String concatenation**: Use `..` operator: `"Hello " .. name`
- **No `null`**: Use `nil` instead
- **Array length**: `#array` (not `.length`)

### Project-Specific Patterns
- **Time**: Use `os.epoch("utc") / 1000` for seconds (milliseconds by default)
- **Colors**: `colors.lime`, `colors.cyan`, etc. (ComputerCraft API)
- **State naming**: UPPERCASE_WITH_UNDERSCORES for states
- **Config keys**: snake_case (e.g., `heartbeat_interval`)

### Animation System
- **Frame-based**: Increment `anim_frame` each display update
- **Spinners**: `anim.getSpinner(frame, style)` - 4 styles available
- **Flashing**: `anim.shouldFlash(frame, frequency)` - returns boolean for toggling
- **Icons**: Use `anim.icons.delayed`, `anim.icons.on_time`, etc.

### Display Guidelines
- **Minecraft-safe characters**: Avoid Unicode outside basic ASCII (use `[!!]` not emojis)
- **Fixed width**: Assume monospace, use `string.rep()` for padding
- **Color support**: Check for Advanced Computer/Monitor for full colors
- **Line limits**: Standard monitor = 7x5 chars, Advanced = varies

## Important Context

### ⚠️ CRITICAL: API Reference
**ALWAYS** consult the official ComputerCraft: Tweaked documentation at **https://tweaked.cc/** before using any API or writing any code, really.

- **DO NOT** assume APIs exist based on intuition or other programming languages
- **DO NOT** invent or guess method names, parameters, or return values
- **DO** use the WebFetch tool to verify APIs at https://tweaked.cc/ when uncertain
- **DO** search existing code in this project for usage examples before adding new API calls

The ComputerCraft API is limited and specific - using non-existent APIs will cause runtime errors in Minecraft with no way to debug except manual testing.

### ComputerCraft: Tweaked APIs Used (Verified)
These are the APIs currently used in this project (all verified against https://tweaked.cc/):

- **`peripheral.find(type)`**: Auto-discover peripherals by type ("modem", "monitor", "speaker")
- **`redstone.getInput(side)`/`setOutput(side, value)`**: Read/write redstone signals
- **`modem.transmit(channel, replyChannel, message)`**: Send network messages
- **`textutils.serialize(table)`/`unserialize(string)`**: Lua table serialization
- **`term.current()`**: Get current terminal object
- **`os.pullEvent(filter)`**: Event loop (returns: event type, params...)
- **`os.epoch(format)`**: Get UTC time in milliseconds (use "utc")
- **`os.startTimer(seconds)`/`cancelTimer(id)`**: Timer management
- **`speaker.playNote(instrument, volume, pitch)`**: Play noteblock sounds
- **`speaker.playAudio(audio_data, volume)`**: Play DFPWM audio (raw PCM playback)
- **`http.get(url)`**: Download files from HTTP/HTTPS URLs
- **`fs.exists(path)`/`open(path, mode)`/`delete(path)`/`makeDir(path)`**: File system operations
- **`shell.run(command, ...args)`**: Execute shell commands

### Hardware Integration
- **Detector rail → Computer**: Redstone input (configurable side: top/bottom/left/right/front/back)
- **Computer → Powered rail**: Redstone output (configurable side)
- **Networking**: Wired modems + networking cables (NOT wireless)

### Configuration System (v0.10+)
The config system uses a **script-authoritative model** for easy remote updates:

#### Script-Authoritative Settings (lines 247-267)
Settings stored in `SCRIPT_STATION_CONFIG` and `SCRIPT_OPS_CONFIG` are ALWAYS loaded from the script file. These can be updated network-wide by pushing new versions (press `u` in ops) or manually via `transit -u`:
- Timing settings: `dispatch_delay`, `departing_delay`, `heartbeat_interval`, etc.
- Display settings: `display_update_interval`
- Network settings: `network_channel`
- Thresholds: `on_time_tolerance`, `early_threshold`, `delayed_threshold`
- Feature flags: `countdown_enabled`

#### Per-Station Settings (stored in `/.transit_config`)
Only hardware-specific settings are persisted per-computer:
- `type`: "station" or "ops"
- `station_id`, `line_id`: Station identity (stations only)
- `detector_side`, `powered_rail_side`: Redstone wiring (stations only)
- `modem_side`: Network modem side (stations only)
- `has_display`: Monitor presence

#### How It Works
1. **On load**: `loadConfig()` reads `/.transit_config` (per-station settings only)
2. **Migration**: Strips any old script-authoritative keys from stored config
3. **Runtime merge**: `buildRuntimeConfig()` merges script defaults with stored settings
4. **Result**: Runtime config has both script settings (always fresh) and station settings (persisted)

#### Updating Network-Wide Settings
1. Edit `SCRIPT_STATION_CONFIG` or `SCRIPT_OPS_CONFIG` in `transit.lua`
2. Push to GitHub/update source
3. Run `transit -u` on computers or broadcast from ops with `u`
4. Settings apply immediately on next restart (no manual reconfiguration needed)

## Known Behaviors

### Audio System (v0.9+)
The system supports **dual-mode audio**: DFPWM (real audio files) with automatic fallback to noteblock sounds.

#### DFPWM Audio (Primary)
- **Format**: DFPWM (1-bit audio codec designed for ComputerCraft)
- **Source**: Downloads from GitHub raw URLs (configurable at lines 404-416)
- **Caching**: Auto-caches to `/sounds/` directory to avoid repeated downloads
- **Fallback**: Automatically falls back to noteblock if download fails or URLs are placeholders

#### Configuring Audio URLs
Edit `audio.config` in `transit.lua` (lines 404-416):
```lua
audio.config = {
    arrival_chime_url = "https://raw.githubusercontent.com/username/repo/main/sounds/arrival.dfpwm",
    door_closing_url = "https://raw.githubusercontent.com/username/repo/main/sounds/door_closing.dfpwm",
    enable_dfpwm = true  -- Set to false to use noteblock sounds only
}
```

#### Converting Audio to DFPWM
Use `ffmpeg` with DFPWM codec:
```bash
ffmpeg -i input.mp3 -ac 1 -ar 48000 -f dfpwm output.dfpwm
```

#### Noteblock Fallback (Secondary)
- **Arrival chime**: G3→D4→B3→G4→D4 (Singapore MRT inspired), 2x slower than original
- **Door closing chirp**: Continuous high F chirp during DEPARTING state (every 0.05s)
- **Always available**: No external dependencies, pure Minecraft sounds

#### Behavior
- **Arrival sequence**: Plays multi-sound sequence when cart arrives (e.g., Bell → "Arriving at Cloud District" → "Please alight")
- **Departure sound**: Plays once when entering DEPARTING state (should contain full announcement + chirp pre-layered)
- **Station-specific**: Automatically matches station ID to sequence (e.g., `station_cloud_district` → `CLOUD_DISTRICT` sequence)
- **Fallback**: Unknown stations use `_FALLBACK` sequence with generic announcement
- **Speakers optional**: System works without audio, auto-discovers if present

#### Important Notes
- **No audio mixing**: ComputerCraft can't overlay multiple PCM streams - layer sounds in your audio editor before converting to DFPWM
- **Timing**: Sequences auto-calculate duration based on file size (~6KB per second)
- **One sound at a time**: Each sequence plays sounds serially with 0.1s pauses between

### Display Updates
- **Stations**: Default 0.1s (10 FPS) - smooth animations
- **Ops center**: Default 1s (1 FPS) - less frequent
- **Adjustable**: Change `display_update_interval` in config

### Dispatch Delay
- **Default**: 4 seconds (passenger boarding time)
- **Countdown**: Broadcasts countdown messages (3, 2, 1...) if enabled
- **Non-blocking**: System continues responding to messages during delay

## Common Modifications

### Changing Script-Authoritative Settings (v0.10+)
To change network-wide settings like timing or thresholds:
1. Edit values in `SCRIPT_STATION_CONFIG` or `SCRIPT_OPS_CONFIG` (lines 247-267)
2. Deploy via `transit -u` on each computer or broadcast from ops by pressing `u`
3. Settings apply immediately on restart (no per-station reconfiguration needed)

Example: To change dispatch delay from 4s to 6s, edit line 265:
```lua
dispatch_delay = 6,  -- Was: 4
```

### Adding New Script-Authoritative Settings
1. Add key/value to `SCRIPT_STATION_CONFIG` or `SCRIPT_OPS_CONFIG` (lines 247-267)
2. Use via `config.your_new_key` in code
3. Deploy network-wide via the ops broadcast (`u`) or `transit -u`

### Adding New Per-Station Settings
1. Add to `configureStation()` or `configureOps()` setup functions (lines 333-374)
2. Add to stored config return object
3. Requires manual reconfiguration or custom migration script

### Creating New Animations
1. Add spinner frames to `anim.spinners` array (line 180)
2. Or add icon to `anim.icons` table (line 188)
3. Use with `anim.getSpinner(frame, style_number)`

### Modifying Protocol
1. Add new message type constant to `protocol` table (line 16)
2. Add creator function: `protocol.createYourMessage()` (follow existing patterns)
3. Add handler in station/ops message dispatcher

## File Purpose

- **transit.lua**: Main system (all code, includes `-u/--update`)
- **README.md**: Installation & usage guide
- **ANIMATIONS.md**: Visual reference for animation system
- **.claude/settings.local.json**: Claude Code settings (not part of game)

## Testing Notes

Since this runs IN Minecraft:
- No unit tests (ComputerCraft doesn't support test frameworks)
- Manual testing required with actual in-game hardware
- Console logs use `print()` - visible on computer terminal
- Monitor display uses separate rendering (doesn't show in console)

## Version History

- **v0.9**: Real-time trip monitoring with live delay detection
- **v0.6**: Animation system with spinners, flashing, progress bars
- **v0.1**: Initial release (basic station coordination)

## UPDATE VERSION ALWAYS PER CHANGE
Remember to UPDATE THE VERSION STRING IN THE COMPOSER INDEX ALWAYS upon each commit with a meaningful identifier.