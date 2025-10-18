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

# Process all audio files
for file in "$SOUND_SRC"/*.wav "$SOUND_SRC"/*.mp3; do
    if [ -f "$file" ]; then
        convert_file "$file"
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
