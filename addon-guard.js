'use strict';
// Preloaded with --require (runs in the main thread and in every worker thread).
//
// --allow-addons is needed for sharp and better-sqlite3, but a native addon runs
// outside the Node permission model. Without this guard, code that can write to
// the content volume could drop a .node file there and load it to escape.
// Only addons inside the root-owned, read-only release tree may be loaded.
// (The permission model also forbids creating symlinks, so realpath can't be spoofed.)
const fs = require('node:fs');

const ALLOWED_PREFIX = (process.env.GHOST_INSTALL || '/ghost') + '/current/node_modules/';
const realDlopen = process.dlopen;

function guardedDlopen(module, filename, ...rest) {
    let real;
    try {
        real = fs.realpathSync(filename);
    } catch {
        real = null;
    }
    if (!real || !real.startsWith(ALLOWED_PREFIX)) {
        const err = new Error(`Native addon blocked by addon-guard: ${filename}`);
        err.code = 'ERR_ACCESS_DENIED';
        throw err;
    }
    return realDlopen.call(process, module, filename, ...rest);
}

Object.defineProperty(process, 'dlopen', {
    value: guardedDlopen,
    writable: false,
    configurable: false,
    enumerable: true
});
