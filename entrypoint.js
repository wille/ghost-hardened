'use strict';
// Replaces the official image's bash entrypoint (there is no shell in distroless).
// Seeds the content volume, then boots Ghost in-process, so the Node permission
// model set on the command line covers both steps.
const fs = require('node:fs');
const path = require('node:path');

const install = process.env.GHOST_INSTALL || '/ghost';
const content = process.env.GHOST_CONTENT || path.join(install, 'content');
const skeleton = path.join(install, 'content.orig');
const bundledThemes = path.join(install, 'current', 'content', 'themes');

// The image tree is read-only, so copy without preserving modes.
function copy(src, dest) {
    if (fs.statSync(src).isDirectory()) {
        fs.mkdirSync(dest, {recursive: true, mode: 0o755});
        for (const name of fs.readdirSync(src)) copy(path.join(src, name), path.join(dest, name));
    } else {
        fs.writeFileSync(dest, fs.readFileSync(src), {mode: 0o644});
    }
}

function themeVersion(dir) {
    try {
        return JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8')).version;
    } catch {
        return null;
    }
}

// 1. Empty top-level dirs (data, images, logs, settings, themes, ...).
for (const d of fs.readdirSync(skeleton, {withFileTypes: true})) {
    const target = path.join(content, d.name);
    if (d.isDirectory() && !fs.existsSync(target)) fs.mkdirSync(target, {recursive: true, mode: 0o755});
}

// 2. Bundled themes. Upstream symlinks these to the release's copy so they track
//    image upgrades; the permission model forbids symlink(), so copy them and
//    refresh whenever the image ships a different version.
for (const name of fs.readdirSync(bundledThemes)) {
    const src = path.join(bundledThemes, name);
    const dest = path.join(content, 'themes', name);
    const want = themeVersion(src);
    if (fs.existsSync(dest) && themeVersion(dest) === want) continue;
    fs.rmSync(dest, {recursive: true, force: true});
    copy(src, dest);
    console.log(`entrypoint: installed bundled theme ${name}@${want}`);
}

process.chdir(install);
require(path.join(install, 'current', 'index.js'));
