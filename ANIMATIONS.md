# Transit Network v0.6 - Animation Guide

## Overview

Version 0.6 introduces a comprehensive animation system with beautiful TUI effects, flashing alerts, and dynamic indicators that bring the transit network displays to life!

## Animation System Features

### 1. Status Icons

Minecraft-friendly character icons for all states:

- `[√]` - ON TIME (trip timing)
- `[!!]` - DELAYED (flashes red/gray for urgency!)
- `[^^]` - EARLY
- `[ ]` - WAITING (empty cart slot)
- `[##]` - CART PRESENT (filled cart slot)
- `[>>]` - IN TRANSIT (moving right)
- `[==]` - BOARDING (stopped)
- `[<<]` - DEPARTING (moving left)

### 2. Spinner Animations

Four different spinner styles for various contexts:

**Style 1** (Classic): `|` → `/` → `-` → `\`
- Used for: IN TRANSIT stations in ops center

**Style 2** (Dot Loader): `.` → `..` → `...` → `..`
- Used for: IN TRANSIT state on station displays

**Style 3** (Traveling Dot): `(   )` → `( . )` → `(  .)` → `( . )` → `(. )`
- Future use: loading sequences

**Style 4** (Progress Bar): `[    ]` → `[=   ]` → `[==  ]` → `[=== ]` → `[====]` → `[ ===]` → `[  ==]` → `[   =]`
- Used for: DEPARTING countdown animation

### 3. Flashing Effects

Dynamic attention-grabbing flashes for urgent states:

- **DELAYED** status: Flashes between red and gray (frequency: every 2 frames)
- **DISPATCHING** message: Flashes between lime and white when all carts ready
- **BOARDING** pulse: Gentle lime/lightGray pulse (every 3 frames) when cart present

### 4. Progress Bars

Visual indicators for completion/readiness:

```
Ready: [##########----------] 10/20
```

- Ops Center: Shows how many stations have carts ready
- Station Display: Shows trip history collection progress (N/10 trips recorded)
- Characters: `#` for filled, `-` for empty

## Station Display (Enhanced)

### Header
```
--------------------------------------------
         COUNCILCRAFT TRANSIT
--------------------------------------------
```

### Line Badge
```
 RED_LINE   ← Cyan background badge
Station: station_alpha
```

### Status Section

**IN TRANSIT:**
```
STATUS:
[>>] IN TRANSIT
       ...        ← Animated dot loader
```

**BOARDING:**
```
STATUS:
[==] BOARDING      ← Gentle pulsing between lime/lightGray
```

**DEPARTING:**
```
STATUS:
[<<] DEPARTING
    [===  ]        ← Animated progress bar
```

### Trip Timing

**ON TIME:**
```
TIMING:
[√] ON TIME        ← Solid lime
Avg: 45.2s
[==========] 10/10
```

**DELAYED (URGENT!):**
```
TIMING:
[!!] DELAYED       ← FLASHES red/gray for attention!
Avg: 45.2s
[==========] 10/10
```

**EARLY:**
```
TIMING:
[^^] EARLY         ← Cyan
Avg: 45.2s
[==========] 10/10
```

### Footer
```
--------------------------------------------
12:34:56                        [ONLINE]
```

## Operations Center Display (Enhanced)

### Header
```
============================================
         COUNCILCRAFT TRANSIT
         OPERATIONS CENTER
============================================
```

### Line Groups

```
 RED_LINE                           2/3

[##] station_alpha       BOARDING      ← Gentle pulse
[ ] station_bravo        IN TRANSIT |  ← Spinner animation
[##] station_charlie     BOARDING

 BLUE_LINE                          1/2

[ ] station_delta        IN TRANSIT /  ← Spinner animation
[##] station_echo        BOARDING
```

### Status Section

**Waiting:**
```
--------------------------------------------
[..] WAITING FOR 2 CART(S)        ← Animated dots

Ready: [######--------------] 6/8
```

**Dispatching:**
```
--------------------------------------------
[>>] DISPATCHING                  ← FLASHES lime/white!

Ready: [####################] 8/8
```

**No Stations:**
```
--------------------------------------------
[!] NO STATIONS REGISTERED        ← Solid red
```

### Footer
```
--------------------------------------------
12:34:56                  NETWORK ACTIVE

Press [h] for help        ← Only on large displays
```

## Color Palette

All colors support both Advanced Monitors (full color) and regular monitors (grayscale):

- **White**: Main text, headers
- **Cyan**: Line badges, secondary headers
- **Lime/Green**: Success, carts present, on time
- **Yellow**: In transit, waiting
- **Orange**: Departing state
- **Red**: Delayed, urgent alerts, errors
- **Gray**: Borders, timestamps, secondary text
- **Blue**: Progress bars (history tracking)
- **LightGray**: Tertiary text, flash states

## Animation Timing

All animations are frame-based and run at the display update interval:

- Station displays: Default 0.1s per frame (10 FPS)
- Ops center: Default 1s per frame (1 FPS)
- Flash frequencies: 2-4 frames per toggle

Configurable via:
- `config.display_update_interval` (stations)
- `config.display_update_interval` (ops)

## Technical Implementation

### Core Animation Functions

```lua
-- Get spinner frame
anim.getSpinner(frame, style)

-- Check if should show flash (urgent states)
anim.shouldFlash(frame, frequency)

-- Generate progress bar
anim.progressBar(progress, width, filled_char, empty_char)
```

### Frame Counter

Each display maintains its own `anim_frame` counter that increments with each display update. Animations use modulo arithmetic to cycle through states smoothly.

## Tips for Best Results

1. **Use Advanced Computers + Advanced Monitors** for full color support
2. **Larger monitors** (3x3 or bigger) show all features including help hints
3. **Adjust display_update_interval** for smoother/faster animations if desired
4. **Dark backgrounds** (default: black) make colors pop beautifully

Enjoy the blinkenlights! ✨
