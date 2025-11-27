#!/usr/bin/env node

/**
 * Reprocess all stored images to a new sanjuuni resolution.
 * Usage: node scripts/reprocess-resolution.js [width] [height]
 */

const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const Database = require('better-sqlite3');

const TARGET_WIDTH = (() => {
    const parsed = parseInt(process.argv[2], 10);
    return Number.isInteger(parsed) && parsed > 0 ? parsed : 158;
})();

const TARGET_HEIGHT = (() => {
    const parsed = parseInt(process.argv[3], 10);
    return Number.isInteger(parsed) && parsed > 0 ? parsed : 243;
})();

const ROOT = path.resolve(__dirname, '..');
const SANJUUNI_PATH = path.join(ROOT, '../_sanjuuni_reference/sanjuuni');
const UPLOADS_DIR = path.join(ROOT, 'uploads');
const PROCESSED_DIR = path.join(ROOT, 'processed');
const DB_PATH = path.join(ROOT, 'display-network.db');

if (!fs.existsSync(SANJUUNI_PATH)) {
    console.error(`sanjuuni binary not found at ${SANJUUNI_PATH}`);
    process.exit(1);
}

const db = new Database(DB_PATH);

function processImage(inputPath, outputPath) {
    return new Promise((resolve, reject) => {
        const args = [
            '-i', inputPath,
            '-o', outputPath,
            '-b',
            '-W', TARGET_WIDTH.toString(),
            '-H', TARGET_HEIGHT.toString(),
            '-L',
            '-k'
        ];

        const proc = spawn(SANJUUNI_PATH, args);
        let stderr = '';

        proc.stderr.on('data', (data) => {
            stderr += data.toString();
        });

        proc.on('close', (code) => {
            if (code !== 0) {
                reject(new Error(stderr || `sanjuuni exited with code ${code}`));
            } else {
                resolve();
            }
        });

        proc.on('error', (err) => {
            reject(err);
        });
    });
}

async function main() {
    const images = db.prepare('SELECT id, stored_filename, processed_filename FROM images').all();

    console.log(`Reprocessing ${images.length} images to ${TARGET_WIDTH}x${TARGET_HEIGHT}...`);

    let processed = 0;
    let skipped = 0;

    for (const image of images) {
        const inputPath = path.join(UPLOADS_DIR, image.stored_filename);
        const outputPath = path.join(PROCESSED_DIR, image.processed_filename);

        if (!fs.existsSync(inputPath)) {
            console.warn(`Skipping image ${image.id}: missing original file ${inputPath}`);
            skipped += 1;
            continue;
        }

        try {
            await processImage(inputPath, outputPath);
            db.prepare('UPDATE images SET width = ?, height = ? WHERE id = ?').run(TARGET_WIDTH, TARGET_HEIGHT, image.id);
            processed += 1;
            console.log(`[${processed}/${images.length}] Reprocessed image ${image.id}`);
        } catch (err) {
            console.error(`Failed to process image ${image.id}: ${err.message}`);
        }
    }

    console.log(`
Done. Updated ${processed} images; skipped ${skipped} missing originals.`);
}

main().catch((err) => {
    console.error('Unexpected error:', err);
    process.exit(1);
});
