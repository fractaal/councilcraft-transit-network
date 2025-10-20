# Audio Setup Guide

This guide explains how to set up custom station-specific audio announcements for your transit network.

## Current Sound Files

You have the following sound sources in `sound_sources/`:

- `ALIGHT_HINT.wav` - "Please alight here" announcement
- `ARRIVAL_CLOUD_DISTRICT.wav` - "Arriving at Cloud District"
- `ARRIVAL_DRAGONSREACH.wav` - "Arriving at Dragonsreach"
- `ARRIVAL_PLAINS_DISTRICT.wav` - "Arriving at Plains District"
- `ARRIVAL_CITY_HALL.wav` - "Arriving at City Hall"
- `ARRIVAL_GENERIC.wav` - Generic arrival announcement
- `DEPARTURE_CART_DEPARTING.mp3` - Door closing chirp

## Step 1: Convert to DFPWM

ComputerCraft: Tweaked requires audio in **DFPWM format**. Run the conversion script:

```bash
./convert_sounds.sh
```

**Note**: You need `ffmpeg` with DFPWM codec support. If you don't have it:

```bash
# Manual conversion for each file:
ffmpeg -i sound_sources/ALIGHT_HINT.wav -ac 1 -ar 48000 -f dfpwm sounds/ALIGHT_HINT.dfpwm
ffmpeg -i sound_sources/ARRIVAL_CLOUD_DISTRICT.wav -ac 1 -ar 48000 -f dfpwm sounds/ARRIVAL_CLOUD_DISTRICT.dfpwm
ffmpeg -i sound_sources/ARRIVAL_DRAGONSREACH.wav -ac 1 -ar 48000 -f dfpwm sounds/ARRIVAL_DRAGONSREACH.dfpwm
ffmpeg -i sound_sources/ARRIVAL_PLAINS_DISTRICT.wav -ac 1 -ar 48000 -f dfpwm sounds/ARRIVAL_PLAINS_DISTRICT.dfpwm
ffmpeg -i sound_sources/ARRIVAL_CITY_HALL.wav -ac 1 -ar 48000 -f dfpwm sounds/ARRIVAL_CITY_HALL.dfpwm
ffmpeg -i sound_sources/ARRIVAL_GENERIC.wav -ac 1 -ar 48000 -f dfpwm sounds/ARRIVAL_GENERIC.dfpwm
ffmpeg -i sound_sources/DEPARTURE_CART_DEPARTING.mp3 -ac 1 -ar 48000 -f dfpwm sounds/DEPARTURE_CART_DEPARTING.dfpwm
```

**Don't forget**: You also need to record/create the **Singapore MRT bell** sound and convert it:

```bash
ffmpeg -i sound_sources/SG_MRT_BELL.wav -ac 1 -ar 48000 -f dfpwm sounds/SG_MRT_BELL.dfpwm
```

This will create `.dfpwm` files in the `sounds/` directory.

## Step 2: Commit to GitHub

```bash
git add sounds/
git commit -m "Add DFPWM audio files for transit announcements"
git push
```

## Step 3: Configure URLs in transit.lua

Edit `transit.lua` (lines 404-416) and set your GitHub raw URL:

```lua
audio.config = {
    -- Replace with your actual GitHub username/repo:
    base_url = "https://raw.githubusercontent.com/YOUR_USERNAME/councilcraft_transit_network/main/sounds/",

    cache_dir = "/sounds/",
    enable_dfpwm = true,
    preload_sounds = true
}
```

Example:
```lua
base_url = "https://raw.githubusercontent.com/benjude/councilcraft_transit_network/main/sounds/",
```

## Step 4: Configure Station Sequences

The system is already configured with sequences in `transit.lua` (lines 447-484):

```lua
audio.sequences = {
    -- Station-specific arrival sequences
    CLOUD_DISTRICT = {
        "SG_MRT_BELL",              -- Bell chime
        "ARRIVAL_CLOUD_DISTRICT",   -- "Arriving at Cloud District"
        "ALIGHT_HINT"               -- "Please alight here"
    },

    DRAGONSREACH = {
        "SG_MRT_BELL",
        "ARRIVAL_DRAGONSREACH",
        "ALIGHT_HINT"
    },

    -- ... etc

    -- Fallback for stations without specific announcements
    _FALLBACK = {
        "SG_MRT_BELL",
        "ARRIVAL_GENERIC",
        "ALIGHT_HINT"
    }
}
```

### How Station Matching Works

The system uses a mapping table (`audio.station_map`) to match friendly station names to sequences:

- Station ID: `"Cloud District"` → Sequence: `CLOUD_DISTRICT`
- Station ID: `"Dragonsreach"` → Sequence: `DRAGONSREACH`
- Station ID: `"Plains District"` → Sequence: `PLAINS_DISTRICT`
- Station ID: `"City Hall"` → Sequence: `CITY_HALL`
- Station ID: `"Unknown Station"` → Sequence: `_FALLBACK` (not in map)

**To add a new station**, edit `transit.lua` (lines 447-456):
```lua
audio.station_map = {
    ["Cloud District"] = "CLOUD_DISTRICT",
    ["Dragonsreach"] = "DRAGONSREACH",
    ["Plains District"] = "PLAINS_DISTRICT",
    ["City Hall"] = "CITY_HALL",
    ["Your New Station"] = "YOUR_NEW_STATION",  -- Add here!
}
```

## Step 5: Adding New Stations

To add a new station's custom announcement:

1. **Record/obtain the audio file** (WAV or MP3)
2. **Convert to DFPWM**:
   ```bash
   ffmpeg -i sound_sources/ARRIVAL_NEW_STATION.wav -ac 1 -ar 48000 -f dfpwm sounds/ARRIVAL_NEW_STATION.dfpwm
   ```
3. **Add to audio library** in `transit.lua` (lines ~428):
   ```lua
   audio.library = {
       -- ... existing sounds ...
       ARRIVAL_NEW_STATION = "ARRIVAL_NEW_STATION.dfpwm",
   }
   ```
4. **Add to station mapping** in `transit.lua` (lines ~447-456):
   ```lua
   audio.station_map = {
       -- ... existing mappings ...
       ["New Station Name"] = "NEW_STATION",  -- Friendly name → Key
   }
   ```
5. **Create sequence** in `transit.lua` (lines ~464):
   ```lua
   audio.sequences = {
       -- ... existing sequences ...
       NEW_STATION = {
           "SG_MRT_BELL",
           "ARRIVAL_NEW_STATION",
           "ALIGHT_HINT"
       }
   }
   ```
6. **Commit and push to GitHub**
7. **Run `update`** on your in-game computers

## Step 6: Deploy

1. **Push your changes** to GitHub
2. **In Minecraft**, run on each station computer:
   ```lua
   update
   ```
3. **Reboot** the computers

On startup, the system will:
- Download all audio files from GitHub
- Cache them locally in `/sounds/`
- Preload them into memory for instant playback

## How It Works

### Arrival Sequence

When a cart arrives at a station:

1. System looks up the station's sequence (e.g., `CLOUD_DISTRICT`)
2. Plays each sound in order:
   - `SG_MRT_BELL.dfpwm` (bell chime)
   - *pause 0.1s*
   - `ARRIVAL_CLOUD_DISTRICT.dfpwm` ("Arriving at Cloud District")
   - *pause 0.1s*
   - `ALIGHT_HINT.dfpwm` ("Please alight here")
3. If DFPWM fails, falls back to noteblock sounds

### Departure Sound

When entering the DEPARTING state:
- Plays `DEPARTURE_CART_DEPARTING.dfpwm` **once** at the beginning
- Your audio file should contain the full sequence: announcement + door chirp
- Example: "Cart Departing." (voice) + Singapore MRT door closing chirp (layered)
- If DFPWM fails, falls back to noteblock chirp (rapid repeating)

### Caching

- **On startup**: All sounds are downloaded and cached to `/sounds/`
- **In memory**: Sounds are preloaded into RAM for instant playback
- **No re-downloading**: Once cached, sounds play immediately without network latency

### Fallback

If anything fails (no internet, file missing, speaker unsupported):
- System automatically falls back to noteblock sounds
- Your transit network keeps working!

## File Size Estimates

DFPWM is very compact (~6KB per second of audio):

- 1-second bell chime: ~6KB
- 3-second announcement: ~18KB
- 1-second door chirp: ~6KB

Total for all sounds: ~100-150KB (minimal storage)

## Troubleshooting

**"[SKIP] sound_name (download failed)"**
- Check your `base_url` in `audio.config`
- Verify files exist on GitHub: visit the raw URL in browser
- Ensure HTTP is enabled in ComputerCraft config (default: on)

**No audio playing**
- Check speaker is attached: `peripheral.find("speaker")`
- Verify files downloaded: `ls /sounds/`
- Check console for errors during preload

**Wrong announcement for station**
- Station ID must match sequence key (e.g., `station_cloud_district` → `CLOUD_DISTRICT`)
- Check station ID: look at computer's config display on startup
- Sequences are case-insensitive after `station_` prefix is removed

## Advanced: Custom Sequences

You can create different sequences for different scenarios:

```lua
-- Example: Express train (skip alight hint)
audio.sequences = {
    CLOUD_DISTRICT_EXPRESS = {
        "SG_MRT_BELL",
        "ARRIVAL_CLOUD_DISTRICT"
        -- No ALIGHT_HINT
    }
}
```

Then modify the `audio.playSequence()` function to accept a custom sequence name instead of always using "arrival".

Enjoy your immersive transit network! 🚇
