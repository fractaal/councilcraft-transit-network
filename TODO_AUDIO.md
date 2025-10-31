# Audio Setup Checklist

## Your Current Status

### ✅ Complete
- [x] Sound source files collected in `sound_sources/`
- [x] Audio system implemented in `transit.lua`
- [x] Sequence configuration created
- [x] Station-specific matching system
- [x] Preloading system
- [x] Fallback to noteblock sounds
- [x] Conversion script created

### 🔲 TODO

#### 1. Get the Singapore MRT Bell Sound
- [ ] Find/record the SG MRT arrival bell sound
- [ ] Save as `sound_sources/SG_MRT_BELL.wav` or `.mp3`
- [ ] This is the 5-note "ding-ding-ding-ding-dong" chime

**Where to find it:**
- YouTube: Search "Singapore MRT door chime"
- Reddit: r/singapore has posted sound files
- Field recording: Record at actual MRT station (with permission)

#### 2. Convert All Sounds to DFPWM
```bash
./convert_sounds.sh
```

**Expected output:**
```
  Converting: ALIGHT_HINT.wav -> ALIGHT_HINT.dfpwm ... ✓ (20K)
  Converting: ARRIVAL_CLOUD_DISTRICT.wav -> ARRIVAL_CLOUD_DISTRICT.dfpwm ... ✓ (18K)
  Converting: ARRIVAL_DRAGONSREACH.wav -> ARRIVAL_DRAGONSREACH.dfpwm ... ✓ (18K)
  Converting: ARRIVAL_GENERIC.wav -> ARRIVAL_GENERIC.dfpwm ... ✓ (6K)
  Converting: ARRIVAL_PLAINS_DISTRICT.wav -> ARRIVAL_PLAINS_DISTRICT.dfpwm ... ✓ (19K)
  Converting: ARRIVAL_CITY_HALL.wav -> ARRIVAL_CITY_HALL.dfpwm ... ✓ (19K)
  Converting: DEPARTURE_CART_DEPARTING.mp3 -> DEPARTURE_CART_DEPARTING.dfpwm ... ✓ (5K)
  Converting: SG_MRT_BELL.wav -> SG_MRT_BELL.dfpwm ... ✓ (8K)
```

- [ ] All 8 files converted successfully
- [ ] Files are in `sounds/` directory
- [ ] Check file sizes are reasonable (~6KB per second of audio)

#### 3. Upload to GitHub
```bash
git add sounds/
git commit -m "Add DFPWM audio files for transit announcements"
git push
```

- [ ] All `.dfpwm` files pushed to GitHub
- [ ] Files are in `sounds/` folder in repository
- [ ] Verify files are accessible (visit raw URL in browser)

#### 4. Configure transit.lua

Edit line 406 in `transit.lua`:

**Before:**
```lua
base_url = "PLACEHOLDER_BASE_URL",
```

**After:**
```lua
base_url = "https://raw.githubusercontent.com/fractaal/councilcraft-transit-network/main/sounds/",
```

(Replace `fractaal` with your GitHub username if different)

- [ ] `base_url` set to your GitHub raw URL
- [ ] URL ends with `/sounds/`
- [ ] No trailing spaces or typos

Test your URL:
```bash
# Should download the file:
curl "https://raw.githubusercontent.com/YOUR_USERNAME/councilcraft_transit_network/main/sounds/SG_MRT_BELL.dfpwm" > test.dfpwm
```

#### 5. Deploy to Minecraft

**Option A: Update from pastebin** (if you're using pastebin):
```lua
-- In Minecraft on each station computer:
update
reboot
```

**Option B: Manual copy** (if not using pastebin):
- Copy updated `transit.lua` to each computer
- Reboot each computer

- [ ] Updated all station computers
- [ ] All computers rebooted
- [ ] No errors on startup

#### 6. Test Audio

- [ ] Let cart arrive at `station_cloud_district`
  - Should hear: Bell → "Arriving at Cloud District" → "Please alight"

- [ ] Let cart arrive at `station_dragonsreach`
  - Should hear: Bell → "Arriving at Dragonsreach" → "Please alight"

- [ ] Let cart arrive at `station_unknown` (test fallback)
  - Should hear: Bell → Generic announcement → "Please alight"

- [ ] Test departure sound
  - Should hear: Continuous door closing chirp during DEPARTING state

- [ ] Verify caching
  - Check `/sounds/` directory exists on computers
  - Files should persist after reboot

## Verification Commands (In Minecraft)

```lua
-- Check if sounds are cached:
ls /sounds/

-- Expected output:
-- ALIGHT_HINT.dfpwm
-- ARRIVAL_CLOUD_DISTRICT.dfpwm
-- ARRIVAL_DRAGONSREACH.dfpwm
-- ARRIVAL_GENERIC.dfpwm
-- ARRIVAL_PLAINS_DISTRICT.dfpwm
-- ARRIVAL_CITY_HALL.dfpwm
-- DEPARTURE_CART_DEPARTING.dfpwm
-- SG_MRT_BELL.dfpwm

-- Check if speaker is found:
peripheral.find("speaker")
-- Should return the speaker peripheral

-- Test download manually:
response = http.get("https://raw.githubusercontent.com/YOUR_USERNAME/councilcraft_transit_network/main/sounds/SG_MRT_BELL.dfpwm")
print(response ~= nil)  -- Should print "true"
response.close()
```

## Troubleshooting

### "Preloading audio library... [SKIP] SG_MRT_BELL (download failed)"

**Causes:**
- File doesn't exist on GitHub
- URL is wrong in `base_url`
- HTTP is disabled in ComputerCraft config
- No internet connectivity in game

**Solutions:**
1. Visit your GitHub raw URL in browser - does it download?
2. Check `base_url` in transit.lua - any typos?
3. Check CC:Tweaked config: `http.enabled = true`

### "No audio playing"

**Causes:**
- Speaker not attached
- DFPWM playback failed (using fallback)
- Volume too low

**Solutions:**
1. Check speaker: `peripheral.find("speaker")` should return a peripheral
2. Check console logs - any errors?
3. Check if noteblock fallback is playing (should hear beeps)

### "Wrong announcement for station"

**Causes:**
- Station ID doesn't match sequence key
- Sequence not configured

**Solutions:**
1. Check station ID on startup screen (e.g., `station_cloud_district`)
2. Check sequence exists in `audio.sequences` for that station
3. Naming: `station_cloud_district` → `CLOUD_DISTRICT` (strips `station_`, uppercase)

## Quick Reference

### Station ID → Sequence Mapping

| Station ID | Sequence Key | Plays |
|------------|--------------|-------|
| `station_cloud_district` | `CLOUD_DISTRICT` | Bell + Cloud District + Alight |
| `station_dragonsreach` | `DRAGONSREACH` | Bell + Dragonsreach + Alight |
| `station_plains_district` | `PLAINS_DISTRICT` | Bell + Plains District + Alight |
| `station_city_hall` | `CITY_HALL` | Bell + City Hall + Alight |
| `station_anything_else` | `_FALLBACK` | Bell + Generic + Alight |

### File Inventory

| Sound Name | Filename | Purpose |
|------------|----------|---------|
| `SG_MRT_BELL` | SG_MRT_BELL.dfpwm | Singapore MRT arrival bell |
| `ARRIVAL_GENERIC` | ARRIVAL_GENERIC.dfpwm | Fallback announcement |
| `ARRIVAL_CLOUD_DISTRICT` | ARRIVAL_CLOUD_DISTRICT.dfpwm | Cloud District announcement |
| `ARRIVAL_DRAGONSREACH` | ARRIVAL_DRAGONSREACH.dfpwm | Dragonsreach announcement |
| `ARRIVAL_PLAINS_DISTRICT` | ARRIVAL_PLAINS_DISTRICT.dfpwm | Plains District announcement |
| `ARRIVAL_CITY_HALL` | ARRIVAL_CITY_HALL.dfpwm | City Hall announcement |
| `ALIGHT_HINT` | ALIGHT_HINT.dfpwm | "Please alight here" |
| `DEPARTURE_CART_DEPARTING` | DEPARTURE_CART_DEPARTING.dfpwm | Door closing chirp |

---

**Status:** Ready to convert and deploy! Just need the SG MRT bell sound. 🔔
