# Display Network

Web portal for uploading images to display on ComputerCraft monitors. Images are automatically processed with [sanjuuni](https://github.com/MCJack123/sanjuuni) for optimal CC display.

## Features

### Web Portal
- 🔐 Passcode-protected access
- 📁 Organize images into collections
- 🖼️ Automatic image processing (portrait 4x6 @ 156x242)
- 📝 Edit captions and delete images
- 👁️ Preview original images in-browser
- 🎨 Tabbed interface for upload and management

### ComputerCraft Client
- ✨ Auto-configuration on first run
- 🔄 Real-time polling (5s interval)
- 🎯 Use collection **names** instead of numeric IDs
- 📊 Live update indicator (e.g., "4/5" in bottom-right)
- 🎨 Custom palette support for accurate colors
- 🔁 Auto-start on boot support
- 💾 Persistent configuration

## Setup

### Requirements

- Node.js 18+
- sanjuuni binary (must be at `../_sanjuuni_reference/sanjuuni` relative to project root)

### Installation

```bash
cd display-network
npm install
```

### Configuration

Set environment variables (optional):

```bash
export PASSCODE=your_secure_passcode  # Default: transit2024
export PORT=3000                       # Default: 3000
```

### Running

```bash
npm start
```

Server will start on `http://localhost:3000`

## Usage

### Web Portal

1. Navigate to `http://your-server:3000`
2. Enter passcode (default: `transit2024`)
3. **Upload Tab:**
   - Create or select a collection
   - Upload images with optional captions
   - Images auto-process to 156x242 resolution
4. **Manage Images Tab:**
   - View all images in selected collection
   - Edit captions
   - Delete images
   - Click images for full-size preview

### ComputerCraft Client

#### First-Time Setup

**Option 1: Using Composer (Recommended)**
```lua
composer install display-network
display
```

**Option 2: Direct Download**
```lua
wget https://your-server:3000/display.lua display
display
```

Then enter configuration:
- Server URL: `http://your-server:3000`
- Collection name: `your-collection-name` (e.g., `adspace-1`)

Configuration is saved to `/.display_config` and reused automatically

#### Auto-Start on Boot

The `startup.lua` file is automatically installed and will start the display on boot. If you need to disable auto-start:

```lua
rm /startup.lua
```

#### Behavior

- Polls server every **5 seconds** for updates
- Shows each slide for **10 seconds**
- Displays **current/total** count in bottom-right (e.g., "3/5")
- Shows caption (if present) above the count
- Automatically detects collection changes
- Works with monitors or terminal

#### Reconfiguration

To change server/collection:

```lua
rm /.display_config
display
```

## API Endpoints

### For Web Portal (Requires Passcode)

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/collections` | List all collections |
| POST | `/api/collections` | Create collection |
| GET | `/api/collections/:id/images` | List images in collection |
| POST | `/api/upload` | Upload & process image |
| PATCH | `/api/images/:id` | Update image caption |
| DELETE | `/api/images/:id` | Delete image |

### For ComputerCraft (No Auth)

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/display/:name_or_id` | Get slideshow data |

Collection lookup supports both numeric IDs and names:
- `/api/display/1` → Collection ID 1
- `/api/display/adspace-1` → Collection named "adspace-1"

## Monitor Setup

The default resolution is **156x242** for:
- **4 monitors wide x 6 monitors tall**
- **0.5 scale** (configured in CC)

To use different setups, modify the upload form's width/height parameters.

## File Structure

```
display-network/
├── server/
│   └── server.js          # Express backend
├── public/
│   └── index.html         # Web UI (with tabs and management)
├── uploads/               # Original uploaded images (served statically)
├── processed/             # BIMG processed files
├── display.lua            # Enhanced CC client
├── startup.lua            # Auto-start script
├── display-network.db     # SQLite database
└── package.json

Root repository also contains:
├── packages/
│   └── display-network.json  # Composer package manifest
```

## Quality Settings

Images are processed with highest quality settings:
- `-L` (CIELAB color space)
- `-k` (k-means color conversion)

These ensure accurate color reproduction on CC monitors.

## Development

### Adding Features

The codebase is structured for easy extension:

- **Backend**: `server/server.js` - Add new API endpoints
- **Frontend**: `public/index.html` - Single-file SPA
- **Client**: `display.lua` - ComputerCraft slideshow logic

### Image Processing

To adjust sanjuuni processing, edit `server/server.js:89-97`:

```javascript
const args = [
    '-i', inputPath,
    '-o', outputPath,
    '-b', // BIMG format
    '-W', width.toString(),
    '-H', height.toString(),
    '-L', // CIELAB color space
    '-k'  // k-means
];
```

## Troubleshooting

**"sanjuuni failed"**
→ Check that sanjuuni binary exists at correct path and is executable

**"Invalid passcode"**
→ Set correct `PASSCODE` env var or use default `transit2024`

**"Collection not found" in CC**
→ Verify collection name matches exactly (case-sensitive)

**Colors look wrong in CC**
→ Restart display client to apply palette fixes

**Server dies immediately**
→ Check for port conflicts (default 3000) or missing directories

## Changelog

### v1.1.0
- Added collection name-based lookup
- Implemented real-time polling (5s)
- Added live update indicator
- Auto-configuration system
- Image management UI (edit/delete)
- Original image preview
- Auto-start on boot support
- Fixed palette application for accurate colors

### v1.0.0
- Initial release
- Basic upload and display functionality

## License

MIT
