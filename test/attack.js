'use strict';
// Simulates an attacker with JS execution inside the Ghost process.
// Run by test/smoke.sh under the image's exact Node flags. Prints "ok"/"FAIL" lines.
const fs = require('node:fs');
const path = require('node:path');
const {Worker} = require('node:worker_threads');

const results = [];
const report = (pass, name, detail) => console.log(`${pass ? 'ok   ' : 'FAIL '} ${name}${detail ? ` (${detail})` : ''}`);

function blocked(name, fn) {
    try {
        fn();
        report(false, `blocked: ${name}`, 'was allowed');
    } catch (e) {
        report(true, `blocked: ${name}`, e.code || e.message.slice(0, 60));
    }
}
function allowed(name, fn) {
    try {
        fn();
        report(true, `allowed: ${name}`);
    } catch (e) {
        report(false, `allowed: ${name}`, e.code || e.message.slice(0, 60));
    }
}
function inWorker(name, code) {
    results.push(new Promise((resolve) => {
        const w = new Worker(`try { ${code}; console.log('FAIL  blocked in worker: ${name} (was allowed)') }
            catch (e) { console.log('ok    blocked in worker: ${name} (' + (e.code || e.message) + ')') }`, {eval: true});
        w.on('exit', resolve);
        w.on('error', resolve);
    }));
}

const rel = '/ghost/current/node_modules/.pnpm';
const findAddon = (prefix, re) => {
    const dir = fs.readdirSync(rel).find((d) => d.startsWith(prefix));
    const walk = (d) => fs.readdirSync(d, {withFileTypes: true}).flatMap((e) =>
        e.isDirectory() ? walk(path.join(d, e.name)) : (re.test(e.name) ? [path.join(d, e.name)] : []));
    return walk(path.join(rel, dir));
};
const linuxAddon = (prefix) => findAddon(prefix, /\.node$/).find((p) => p.includes(`linux-${process.arch}`) || p.includes('Release'));

// Subprocesses
blocked('child_process.execSync', () => require('node:child_process').execSync('id'));
blocked('child_process.spawn', () => require('node:child_process').spawn('/bin/sh'));
blocked('process.binding("spawn_sync")', () => process.binding('spawn_sync'));
inWorker('child_process.execSync', "require('node:child_process').execSync('id')");

// Filesystem
blocked('read /etc/passwd', () => fs.readFileSync('/etc/passwd'));
blocked('read /proc/self/environ', () => fs.readFileSync('/proc/self/environ'));
blocked('list /', () => fs.readdirSync('/'));
blocked('write Ghost code', () => fs.appendFileSync('/ghost/current/core/boot.js', '//x'));
blocked('write Ghost config', () => fs.appendFileSync('/ghost/config.production.json', ' '));
blocked('symlink', () => fs.symlinkSync('/ghost/current', '/ghost/content/link'));
blocked('WASI', () => new (require('node:wasi').WASI)({version: 'preview1'}));

// Native addons: only the release tree may be loaded
const sqlite = linuxAddon('better-sqlite3@');
fs.copyFileSync(sqlite, '/tmp/evil.node');
fs.copyFileSync(sqlite, '/ghost/content/data/evil.node');
blocked('addon from /tmp', () => require('/tmp/evil.node'));
blocked('addon from content volume', () => require('/ghost/content/data/evil.node'));
inWorker('addon from content volume', "require('/ghost/content/data/evil.node')");
blocked('replace process.dlopen', () => {
    process.dlopen = () => {};
    if (process.dlopen.name === 'guardedDlopen') throw new Error('assignment ignored');
});
allowed('sharp addon from release tree', () => require(linuxAddon('@img+sharp-linux-')));
allowed('better-sqlite3 addon from release tree', () => require(sqlite));

Promise.all(results).then(() => {
    for (const f of ['/tmp/evil.node', '/ghost/content/data/evil.node']) fs.rmSync(f, {force: true});
    console.log('DONE');
});
