#!/bin/bash
# Convert all sound files to DFPWM format
# Requires: ffmpeg with DFPWM codec support

SOUND_SRC="sound_sources"
SOUND_OUT="sounds"

echo "============================================"
echo "  CouncilCraft Transit Network"
echo "  Audio Conversion Script"
echo "============================================"
echo ""

# Check if ffmpeg is installed
if ! command -v ffmpeg &> /dev/null; then
    echo "ERROR: ffmpeg is not installed!"
    echo ""
    echo "Please install ffmpeg with DFPWM support:"
    echo "  - Ubuntu/Debian: sudo apt install ffmpeg"
    echo "  - macOS: brew install ffmpeg"
    echo "  - Windows: Download from ffmpeg.org"
    echo ""
    exit 1
fi

# Create output directory
mkdir -p "$SOUND_OUT"

echo "Converting WAV/MP3 files to DFPWM..."
echo ""

# Convert all files
convert_file() {
    local input="$1"
    local basename=$(basename "$input")
    local name="${basename%.*}"
    local output="$SOUND_OUT/${name}.dfpwm"

    echo -n "  Converting: $basename -> ${name}.dfpwm ... "

    if ffmpeg -i "$input" -ac 1 -ar 48000 -f dfpwm "$output" -y -loglevel error; then
        local size=$(du -h "$output" | cut -f1)
        echo "✓ ($size)"
    else
        echo "✗ FAILED"
    fi
}

# Define files to convert (prefer _V2 versions, skip non-V2 if V2 exists)
FILES_TO_CONVERT=(
    # Bells
    "SG_MRT_BELL.wav"

    # Station-specific announcements (V2 versions)
    "ARRIVAL_CLOUD_DISTRICT_V2.wav"
    "ARRIVAL_DRAGONSREACH_V2.wav"
    "ARRIVAL_PLAINS_DISTRICT_V2.wav"
    "ARRIVAL_RICARDOS_V2.wav"

    # Generic arrival (no V2 version)
    "ARRIVAL_GENERIC.wav"

    # Hints (use V2)
    "ALIGHT_HINT_V2.wav"

    # Other sounds
    "OTHER_TERMINATES_HERE.mp3"
    "DEPARTURE_CART_DEPARTING.wav"
)

# Process specified files
for filename in "${FILES_TO_CONVERT[@]}"; do
    file="$SOUND_SRC/$filename"
    if [ -f "$file" ]; then
        convert_file "$file"
    else
        echo "  WARNING: $filename not found, skipping..."
    fi
done

echo ""
echo "============================================"
echo "Conversion complete!"
echo ""
echo "Output files are in: ./$SOUND_OUT/"
echo ""
echo "Next steps:"
echo "  1. Check if you have SG_MRT_BELL.dfpwm"
echo "     (If not, record/find the bell sound first!)"
echo ""
echo "  2. Upload to GitHub:"
echo "     git add sounds/"
echo "     git commit -m 'Add DFPWM audio files'"
echo "     git push"
echo ""
echo "  3. Update transit.lua with your GitHub URL"
echo "  4. Run 'update' in Minecraft on each computer"
echo "============================================"
