# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
IN_TRANSIT → (cart arrives) → BOARDING → (DISPATCH received) → DEPARTING → (cart leaves) → IN_TRANSIT
```

### Network Protocol
- **Channel**: 100 (default, configurable)
- **Discovery**: Ops center broadcasts DISCOVER, stations respond with REGISTER
- **Status**: Stations send STATUS every 0.5s with cart presence, trip timing, state
- **Dispatch**: Ops center sends DISPATCH when all carts present, triggers DEPARTING state
- **Heartbeat**: Keep-alive messages every 5s

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

2. **First run**: Interactive setup wizard configures the computer as Station or Ops Center

3. **Subsequent runs**: Loads saved config from `/.transit_config`, auto-starts

### Testing
- **Manual dispatch**: In ops center console, press `d`
- **Reset stations**: In ops center console, press `r`
- **View stations**: Press `s`
- **Help**: Press `h`

### Updating Deployed Systems
Use `update.lua` (pulls from pastebin):
```lua
update
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
**ALWAYS** consult the official ComputerCraft: Tweaked documentation at **https://tweaked.cc/** before using any API.

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

### Configuration Migration
The system auto-migrates old configs by merging with default values (lines 270-281). When adding new config keys:
1. Add to `DEFAULT_STATION_CONFIG` or `DEFAULT_OPS_CONFIG`
2. Migration happens automatically on load
3. Saves updated config back to disk

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
- **Default**: 5 seconds (passenger boarding time)
- **Countdown**: Broadcasts countdown messages (3, 2, 1...) if enabled
- **Non-blocking**: System continues responding to messages during delay

## Common Modifications

### Adding New Config Options
1. Add key/value to `DEFAULT_STATION_CONFIG` or `DEFAULT_OPS_CONFIG` (lines 243-261)
2. Use via `config.your_new_key` in code
3. Migration system handles existing deployments automatically

### Creating New Animations
1. Add spinner frames to `anim.spinners` array (line 180)
2. Or add icon to `anim.icons` table (line 188)
3. Use with `anim.getSpinner(frame, style_number)`

### Modifying Protocol
1. Add new message type constant to `protocol` table (line 16)
2. Add creator function: `protocol.createYourMessage()` (follow existing patterns)
3. Add handler in station/ops message dispatcher

## File Purpose

- **transit.lua**: Main system (all code)
- **update.lua**: Pastebin updater for deployed systems
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
