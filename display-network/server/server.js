const express = require('express');
const Database = require('better-sqlite3');
const multer = require('multer');
const cors = require('cors');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = process.env.PORT || 3000;
const PASSCODE = process.env.PASSCODE || 'transit2024';

// Paths
const SANJUUNI_PATH = path.join(__dirname, '../../_sanjuuni_reference/sanjuuni');
const UPLOADS_DIR = path.join(__dirname, '../uploads');
const PROCESSED_DIR = path.join(__dirname, '../processed');
const DB_PATH = path.join(__dirname, '../display-network.db');

// Ensure directories exist
[UPLOADS_DIR, PROCESSED_DIR].forEach(dir => {
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
});

// Database setup
const db = new Database(DB_PATH);
db.exec(`
    CREATE TABLE IF NOT EXISTS collections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS images (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        collection_id INTEGER NOT NULL,
        original_filename TEXT NOT NULL,
        stored_filename TEXT NOT NULL,
        processed_filename TEXT NOT NULL,
        caption TEXT,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_collection_images ON images(collection_id);
`);

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, '../public')));
app.use('/uploads', express.static(UPLOADS_DIR)); // Serve uploaded images

// Serve CC client files (for manual download if needed)
app.get('/display.lua', (req, res) => {
    res.sendFile(path.join(__dirname, '../display.lua'));
});
app.get('/startup.lua', (req, res) => {
    res.sendFile(path.join(__dirname, '../startup.lua'));
});

// Multer setup for file uploads
const storage = multer.diskStorage({
    destination: UPLOADS_DIR,
    filename: (req, file, cb) => {
        const uniqueName = `${Date.now()}-${Math.random().toString(36).substring(7)}${path.extname(file.originalname)}`;
        cb(null, uniqueName);
    }
});
const upload = multer({
    storage,
    limits: { fileSize: 10 * 1024 * 1024 }, // 10MB
    fileFilter: (req, file, cb) => {
        const allowedTypes = /jpeg|jpg|png|gif|webp/;
        const mimetype = allowedTypes.test(file.mimetype);
        const extname = allowedTypes.test(path.extname(file.originalname).toLowerCase());

        if (mimetype && extname) {
            return cb(null, true);
        }
        cb(new Error('Only image files are allowed!'));
    }
});

// Auth middleware
function requirePasscode(req, res, next) {
    const passcode = req.headers['x-passcode'] || req.query.passcode;
    if (passcode !== PASSCODE) {
        return res.status(401).json({ error: 'Invalid passcode' });
    }
    next();
}

// Process image with sanjuuni
async function processImage(inputPath, outputPath, width = 156, height = 242) {
    return new Promise((resolve, reject) => {
        const args = [
            '-i', inputPath,
            '-o', outputPath,
            '-b', // BIMG format
            '-W', width.toString(),
            '-H', height.toString(),
            '-L', // CIELAB color space for better quality
            '-k'  // k-means for highest quality color conversion
        ];

        const proc = spawn(SANJUUNI_PATH, args);
        let stderr = '';

        proc.stderr.on('data', (data) => {
            stderr += data.toString();
        });

        proc.on('close', (code) => {
            if (code !== 0) {
                reject(new Error(`sanjuuni failed: ${stderr}`));
            } else {
                resolve();
            }
        });

        proc.on('error', (err) => {
            reject(new Error(`Failed to spawn sanjuuni: ${err.message}`));
        });
    });
}

// API Routes

// GET /api/collections - List all collections
app.get('/api/collections', requirePasscode, (req, res) => {
    const collections = db.prepare(`
        SELECT c.*, COUNT(i.id) as image_count
        FROM collections c
        LEFT JOIN images i ON c.id = i.collection_id
        GROUP BY c.id
        ORDER BY c.created_at DESC
    `).all();
    res.json(collections);
});

// POST /api/collections - Create a new collection
app.post('/api/collections', requirePasscode, (req, res) => {
    const { name } = req.body;
    if (!name || !name.trim()) {
        return res.status(400).json({ error: 'Collection name required' });
    }

    try {
        const result = db.prepare('INSERT INTO collections (name, created_at) VALUES (?, ?)').run(
            name.trim(),
            Date.now()
        );
        res.json({ id: result.lastInsertRowid, name: name.trim() });
    } catch (err) {
        if (err.message.includes('UNIQUE constraint')) {
            res.status(409).json({ error: 'Collection already exists' });
        } else {
            res.status(500).json({ error: err.message });
        }
    }
});

// POST /api/upload - Upload and process image
app.post('/api/upload', requirePasscode, upload.single('image'), async (req, res) => {
    if (!req.file) {
        return res.status(400).json({ error: 'No image file provided' });
    }

    const { collection_id, caption, width, height } = req.body;
    if (!collection_id) {
        fs.unlinkSync(req.file.path); // Clean up
        return res.status(400).json({ error: 'collection_id required' });
    }

    const imageWidth = parseInt(width) || 156;
    const imageHeight = parseInt(height) || 242;

    const processedFilename = `${path.parse(req.file.filename).name}.bimg`;
    const processedPath = path.join(PROCESSED_DIR, processedFilename);

    try {
        // Process with sanjuuni
        await processImage(req.file.path, processedPath, imageWidth, imageHeight);

        // Save to database
        const result = db.prepare(`
            INSERT INTO images (collection_id, original_filename, stored_filename, processed_filename, caption, width, height, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        `).run(
            collection_id,
            req.file.originalname,
            req.file.filename,
            processedFilename,
            caption || null,
            imageWidth,
            imageHeight,
            Date.now()
        );

        res.json({
            id: result.lastInsertRowid,
            message: 'Image uploaded and processed successfully'
        });
    } catch (err) {
        // Clean up on failure
        if (fs.existsSync(req.file.path)) fs.unlinkSync(req.file.path);
        if (fs.existsSync(processedPath)) fs.unlinkSync(processedPath);
        res.status(500).json({ error: `Processing failed: ${err.message}` });
    }
});

// GET /api/collections/:id/images - List images in a collection
app.get('/api/collections/:id/images', requirePasscode, (req, res) => {
    const images = db.prepare('SELECT * FROM images WHERE collection_id = ? ORDER BY created_at DESC').all(req.params.id);
    res.json(images);
});

// PATCH /api/images/:id - Update image caption
app.patch('/api/images/:id', requirePasscode, (req, res) => {
    const { caption } = req.body;
    const image = db.prepare('SELECT * FROM images WHERE id = ?').get(req.params.id);

    if (!image) {
        return res.status(404).json({ error: 'Image not found' });
    }

    db.prepare('UPDATE images SET caption = ? WHERE id = ?').run(caption || null, req.params.id);
    res.json({ message: 'Caption updated' });
});

// GET /api/display/:collection_id_or_name - Get slideshow data for ComputerCraft
app.get('/api/display/:collection_id_or_name', (req, res) => {
    const { collection_id_or_name } = req.params;

    // Try to find collection by ID or name
    let collection;
    if (/^\d+$/.test(collection_id_or_name)) {
        // Numeric ID
        collection = db.prepare('SELECT id FROM collections WHERE id = ?').get(collection_id_or_name);
    } else {
        // Name
        collection = db.prepare('SELECT id FROM collections WHERE name = ?').get(collection_id_or_name);
    }

    if (!collection) {
        return res.status(404).json({ error: 'Collection not found' });
    }

    const images = db.prepare(`
        SELECT id, processed_filename, caption, width, height
        FROM images
        WHERE collection_id = ?
        ORDER BY created_at ASC
    `).all(collection.id);

    if (images.length === 0) {
        return res.status(404).json({ error: 'No images in collection' });
    }

    // Read and return all BIMG data
    const slides = images.map(img => {
        const bimgPath = path.join(PROCESSED_DIR, img.processed_filename);
        if (!fs.existsSync(bimgPath)) {
            return null;
        }
        const bimgData = fs.readFileSync(bimgPath, 'utf8');
        return {
            id: img.id,
            data: bimgData,
            caption: img.caption,
            width: img.width,
            height: img.height
        };
    }).filter(Boolean);

    // Get collection info for response
    const collectionInfo = db.prepare('SELECT id, name FROM collections WHERE id = ?').get(collection.id);

    res.json({
        collection_id: collection.id,
        collection_name: collectionInfo.name,
        count: slides.length,
        updated_at: Date.now(),
        slides
    });
});

// DELETE /api/images/:id - Delete an image
app.delete('/api/images/:id', requirePasscode, (req, res) => {
    const image = db.prepare('SELECT * FROM images WHERE id = ?').get(req.params.id);
    if (!image) {
        return res.status(404).json({ error: 'Image not found' });
    }

    // Delete files
    const uploadPath = path.join(UPLOADS_DIR, image.stored_filename);
    const processedPath = path.join(PROCESSED_DIR, image.processed_filename);
    if (fs.existsSync(uploadPath)) fs.unlinkSync(uploadPath);
    if (fs.existsSync(processedPath)) fs.unlinkSync(processedPath);

    // Delete from database
    db.prepare('DELETE FROM images WHERE id = ?').run(req.params.id);
    res.json({ message: 'Image deleted' });
});

// Health check
app.get('/api/health', (req, res) => {
    res.json({ status: 'ok', timestamp: Date.now() });
});

// Error handlers
process.on('uncaughtException', (err) => {
    console.error('Uncaught Exception:', err);
    process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error('Unhandled Rejection at:', promise, 'reason:', reason);
    process.exit(1);
});

const server = app.listen(PORT, () => {
    console.log(`Display Network server running on port ${PORT}`);
    console.log(`Passcode: ${PASSCODE}`);
    console.log(`sanjuuni path: ${SANJUUNI_PATH}`);
});

server.on('error', (err) => {
    console.error('Server error:', err);
    process.exit(1);
});
