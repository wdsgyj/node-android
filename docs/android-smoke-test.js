'use strict';

const assert = require('node:assert/strict');
const { once } = require('node:events');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const http = require('node:http');
const { builtinModules } = require('node:module');
const os = require('node:os');
const path = require('node:path');
const { Readable, Transform, Writable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const timers = require('node:timers/promises');
const crypto = require('node:crypto');
const zlib = require('node:zlib');

const results = [];
const expectedPlatform = process.env.NODE_ANDROID_EXPECT_PLATFORM || 'android';
const expectedArch = process.env.NODE_ANDROID_EXPECT_ARCH || 'arm64';
const expectedNodeMajor = process.env.NODE_ANDROID_EXPECT_NODE_MAJOR || '24';

async function check(name, fn) {
  const started = Date.now();
  try {
    await fn();
    results.push({ name, ok: true, ms: Date.now() - started });
  } catch (error) {
    results.push({
      name,
      ok: false,
      ms: Date.now() - started,
      error: error && error.stack ? error.stack : String(error),
    });
  }
}

function requireBuiltin(name) {
  assert.ok(
    builtinModules.includes(name) || builtinModules.includes(`node:${name}`),
    `${name} missing from builtinModules`,
  );
  assert.ok(require(`node:${name}`), `require(node:${name}) failed`);
}

async function main() {
  await check('process metadata', () => {
    assert.equal(process.platform, expectedPlatform);
    assert.equal(process.arch, expectedArch);
    assert.match(process.version, new RegExp(`^v${expectedNodeMajor}\\.`));
    assert.ok(process.versions.v8);
    assert.ok(process.versions.modules);
    assert.ok(process.execPath);
  });

  await check('core builtin loading', () => {
    for (const name of [
      'assert',
      'buffer',
      'crypto',
      'events',
      'fs',
      'http',
      'module',
      'os',
      'path',
      'stream',
      'timers',
      'url',
      'util',
      'vm',
      'zlib',
    ]) {
      requireBuiltin(name);
    }
  });

  await check('buffer and url', () => {
    const text = Buffer.from('android-libnode', 'utf8').toString('base64');
    assert.equal(text, 'YW5kcm9pZC1saWJub2Rl');
    const url = new URL('/api?q=1', 'https://example.test');
    assert.equal(url.href, 'https://example.test/api?q=1');
  });

  await check('filesystem', async () => {
    const dir = await fsp.mkdtemp(path.join(os.tmpdir(), 'node-android-smoke-'));
    const file = path.join(dir, 'sample.txt');
    await fsp.writeFile(file, 'hello android node\n', 'utf8');
    assert.equal(await fsp.readFile(file, 'utf8'), 'hello android node\n');
    assert.equal(fs.statSync(file).isFile(), true);
    await fsp.rm(dir, { recursive: true, force: true });
  });

  await check('crypto', () => {
    assert.equal(
      crypto.createHash('sha256').update('node-android').digest('hex'),
      'fea1953b985f4b4e885b85ef14ff622314ff9bf65383766d1f8e86cd6a39f35d',
    );
    assert.equal(crypto.randomBytes(16).length, 16);
  });

  await check('zlib', async () => {
    const input = Buffer.from('node android zlib');
    const compressed = await new Promise((resolve, reject) => {
      zlib.gzip(input, (error, value) => error ? reject(error) : resolve(value));
    });
    const output = await new Promise((resolve, reject) => {
      zlib.gunzip(compressed, (error, value) => error ? reject(error) : resolve(value));
    });
    assert.equal(output.toString(), input.toString());
  });

  await check('event loop and promises', async () => {
    let microtask = false;
    queueMicrotask(() => {
      microtask = true;
    });
    await timers.setTimeout(5);
    assert.equal(microtask, true);
  });

  await check('streams', async () => {
    let output = '';
    const upper = new Transform({
      transform(chunk, encoding, callback) {
        callback(null, chunk.toString().toUpperCase());
      },
    });
    const sink = new Writable({
      write(chunk, encoding, callback) {
        output += chunk.toString();
        callback();
      },
    });
    await pipeline(Readable.from(['node', '-', 'android']), upper, sink);
    assert.equal(output, 'NODE-ANDROID');
  });

  if (process.env.NODE_ANDROID_SMOKE_NETWORK === '1') {
    await check('http loopback', async () => {
      const server = http.createServer((req, res) => {
        res.end('ok');
      });
      server.listen(0, '127.0.0.1');
      await once(server, 'listening');
      const { port } = server.address();
      const body = await new Promise((resolve, reject) => {
        http.get({ host: '127.0.0.1', port, path: '/' }, (res) => {
          let data = '';
          res.setEncoding('utf8');
          res.on('data', (chunk) => {
            data += chunk;
          });
          res.on('end', () => resolve(data));
        }).on('error', reject);
      });
      await new Promise((resolve, reject) => {
        server.close((error) => error ? reject(error) : resolve());
      });
      assert.equal(body, 'ok');
    });
  }
}

main().finally(() => {
  const failed = results.filter((result) => !result.ok);
  console.log(JSON.stringify({
    ok: failed.length === 0,
    platform: process.platform,
    arch: process.arch,
    version: process.version,
    versions: process.versions,
    results,
  }, null, 2));

  if (failed.length !== 0) {
    process.exitCode = 1;
  }
});
