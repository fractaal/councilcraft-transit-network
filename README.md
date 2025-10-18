# CouncilCraft Transit Network v0.9

A ComputerCraft: Tweaked automated transit system for Minecraft. This system uses wired modems and networking cables to coordinate multiple stations, dispatching minecarts only when all stations have their carts present.

**NEW in v0.9:** Real-time trip monitoring!
- **Station displays**: "Arriving in 5s" with live delay detection - `[!!]` flashes RED immediately when delayed!
- **Ops center**: Shows "45s/38s" (current/avg) for each in-transit station with color-coded delays
- **Live updates**: Trip status recalculates every display update, not just on arrival!

## Features

- Centralized operations center controlling all stations
- Automatic station discovery via network protocol
- Real-time cart presence detection
- Synchronized dispatch across all stations
- Expandable to multiple lines and stations

## How It Works

Each station monitors a detector rail for cart presence. When all stations report their carts are present, the ops center sends a DISPATCH command, and all stations simultaneously activate their powered rails to send carts to the next station.

This prevents timing issues and ensures smooth, synchronized transit operations!

## Hardware Requirements

### Per Station Terminal:
- 1x Computer
- 1x Wired Modem
- 1x Detector Rail (connected via redstone to computer)
- 1x Powered Rail (controlled via redstone from computer)
- Networking Cable connecting to ops center
- OPTIONAL: Monitors (for station displays - future feature)

### Operations Center:
- 1x Advanced Computer (recommended for color displays)
- 1x Wired Modem
- Networking Cable hub connecting all stations
- OPTIONAL: Large monitor array (3x3+) for status display

## Installation Instructions

### Step 1: Prepare the Installation Disk

1. Craft a Floppy Disk in Minecraft
2. Insert it into a Disk Drive attached to any computer
3. Copy all project files to the disk:

```bash
# On a temporary computer with disk drive attached
# Assuming disk is mounted at /disk

# Copy all folders to the disk
cp -r /path/to/shared /disk/shared
cp -r /path/to/station /disk/station
cp -r /path/to/ops /disk/ops
cp /path/to/install.lua /disk/install.lua
```

### Step 2: Build Your Hardware

**For each station:**
1. Place a Computer
2. Attach a Wired Modem to any side (sneak + right-click)
3. Connect Networking Cable from the modem to your network
4. Connect detector rail redstone signal to computer (note which side)
5. Connect computer redstone output to powered rail (note which side)

**For the ops center:**
1. Place an Advanced Computer
2. Attach a Wired Modem
3. Connect all networking cables to this central point
4. Optionally attach monitors for status display

### Step 3: Install Software

**On each computer (station or ops center):**

1. Insert the installation disk into a disk drive attached to the computer
2. Run the installer:
   ```lua
   disk/install.lua
   ```
3. Follow the prompts:
   - Choose "Station Terminal" (1) or "Operations Center" (2)
   - For stations: Enter station ID, line ID, and redstone sides
   - The computer will automatically reboot when done

### Step 4: Start the System

1. **Start the Operations Center first**
   - It will begin broadcasting DISCOVER messages
   - You'll see "Starting discovery..." on screen

2. **Start each Station Terminal**
   - They will automatically register with the ops center
   - The ops center will show "NEW STATION: [station_id]"

3. **Watch the magic happen!**
   - Place carts on each station's detector rail
   - When all carts are present, the ops center dispatches them
   - Carts travel to the next station and the cycle repeats

## Network Protocol

The system uses a simple message-based protocol on channel 100:

- **DISCOVER**: Ops center broadcasts to find stations
- **REGISTER**: Stations respond with their ID and configuration
- **STATUS**: Stations report cart presence
- **HEARTBEAT**: Keep-alive messages
- **DISPATCH**: Ops center commands stations to send carts

## Configuration

### Station Config (`/station/config.lua`)

```lua
config.station_id = "station_alpha"     -- Unique station identifier
config.line_id = "red_line"             -- Line this station belongs to
config.network_channel = 100            -- Network channel (must match ops)
config.detector_side = "bottom"         -- Detector rail input side
config.powered_rail_side = "top"        -- Powered rail output side
config.has_display = false              -- Enable monitor display
config.heartbeat_interval = 5           -- Seconds between heartbeats
config.status_send_interval = 0.5       -- Status update frequency
```

### Ops Center Config (`/ops/ops_center.lua`)

Network channel is set at the top of the file (default: 100). Discovery and dispatch intervals can also be adjusted.

## File Structure

```
/councilcraft_transit_network/
├── shared/
│   ├── protocol.lua          # Message protocol definitions
│   └── network.lua           # Network utilities
├── station/
│   ├── station.lua           # Station controller main program
│   └── config.lua            # Station configuration
├── ops/
│   └── ops_center.lua        # Operations center main program
├── install.lua               # Interactive installer
└── README.md                 # This file
```

## Troubleshooting

**"No modem found!"**
- Make sure you attached a Wired Modem (sneak + right-click on computer)
- Check that networking cables are connected

**Station not registering:**
- Verify ops center is running first
- Check that network channel matches (default: 100)
- Ensure networking cables connect stations to ops center

**Carts not dispatching:**
- Verify detector rail is sending redstone signal to correct side
- Check powered rail receives redstone from correct side
- Confirm all stations report "CART ARRIVED" in ops center

**Timing issues:**
- Adjust `config.status_send_interval` in station config
- Ensure detector rails properly detect cart presence

## Audio Setup (Optional)

The system supports **real Singapore MRT audio** via DFPWM files! By default, it uses noteblock sounds as a fallback.

### Setting Up Real Audio

1. **Prepare your audio files** (on your computer):
   ```bash
   # Convert MP3/WAV to DFPWM format
   ffmpeg -i singapore_arrival.mp3 -ac 1 -ar 48000 -f dfpwm arrival_chime.dfpwm
   ffmpeg -i door_closing.mp3 -ac 1 -ar 48000 -f dfpwm door_closing.dfpwm
   ```

2. **Host on GitHub**:
   - Create a `sounds/` folder in this repository
   - Add your `.dfpwm` files: `arrival_chime.dfpwm`, `door_closing.dfpwm`
   - Commit and push to GitHub

3. **Get the raw URLs**:
   ```
   https://raw.githubusercontent.com/YOUR_USERNAME/councilcraft_transit_network/main/sounds/arrival_chime.dfpwm
   https://raw.githubusercontent.com/YOUR_USERNAME/councilcraft_transit_network/main/sounds/door_closing.dfpwm
   ```

4. **Edit `transit.lua`** (lines 404-416):
   ```lua
   audio.config = {
       arrival_chime_url = "https://raw.githubusercontent.com/..../arrival_chime.dfpwm",
       door_closing_url = "https://raw.githubusercontent.com/..../door_closing.dfpwm",
       enable_dfpwm = true
   }
   ```

5. **Update deployed systems**:
   - Run `update` on each in-game computer to get the new code
   - The system will automatically download and cache the audio files
   - If download fails, it falls back to noteblock sounds

### Audio Behavior

- **Arrival sequence**: Plays once when cart arrives at station (multi-sound sequence)
- **Departure sound**: Plays once when entering DEPARTING state (should contain full announcement + chirp)
- **Caching**: Audio files are cached in `/sounds/` on each computer (no repeated downloads)
- **Fallback**: If DFPWM fails, the system automatically uses noteblock sounds

### Where to Find Singapore MRT Sounds

- YouTube: Search "Singapore MRT door chime" or "SMRT train sounds"
- Reddit: r/singapore occasionally has sound files
- Field recording: Record at actual MRT stations (with permission)

## Future Enhancements (v0.2+)

- Station monitor displays showing line status
- Multi-line support with line-specific dispatch
- Web-based ops center dashboard
- Automated cart replacement system
- Emergency stop functionality
- Station-to-station messaging

## Credits

Built for the CouncilCraft Minecraft server.
Powered by ComputerCraft: Tweaked.

---

Have fun automating your transit network!
