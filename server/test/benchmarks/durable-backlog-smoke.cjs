'use strict';

// Real uploads against an isolated runtime: no processing worker or Redis
// backlog is required to acknowledge and preserve the original files.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const sharp = require(path.resolve(__dirname, '../../node_modules/sharp'));

const project = process.env.RUNTIME_TEST_PROJECT || 'inhouse-runtime-test-backlog';
assert.match(project, /^inhouse-runtime-test-backlog(?:-[a-z0-9_-]+)?$/);
const port = Number(process.env.RUNTIME_TEST_PORT || '19284');
assert.ok(Number.isSafeInteger(port) && port >= 1024 && port <= 65535);
const composeFile = path.resolve(process.env.RUNTIME_TEST_COMPOSE || path.join(__dirname, 'runtime-smoke.compose.yml'));
const fixtureRoot = process.env.RUNTIME_TEST_FIXTURES;
const resultsFile = path.resolve(process.env.RUNTIME_TEST_RESULTS || 'durable-backlog-results.json');
const args = ['compose', '-p', project, '-f', composeFile];
const base = `http://127.0.0.1:${port}/api`;
const received = [];
let token;
let workers = 'api';

function compose(...extra) {
  return execFileSync('docker', [...args, ...extra], {
    env: { ...process.env, RUNTIME_TEST_PORT: String(port), RUNTIME_TEST_WORKERS: workers },
    encoding: 'utf8',
    timeout: 360000,
    maxBuffer: 2 * 1024 * 1024,
  });
}

function sql(query) {
  return compose('exec', '-T', 'database', 'psql', '-U', 'postgres', '-d', 'immich', '-tAc', query).trim();
}

async function request(method, endpoint, body, binary = false) {
  const headers = token ? { authorization: `Bearer ${token}` } : {};
  if (body && !(body instanceof FormData)) headers['content-type'] = 'application/json';
  const response = await fetch(`${base}${endpoint}`, {
    method,
    headers,
    body: body ? (body instanceof FormData ? body : JSON.stringify(body)) : undefined,
    signal: AbortSignal.timeout(60000),
  });
  assert.ok(response.ok, `${method} ${endpoint}: ${response.status} ${response.ok ? '' : await response.text()}`);
  if (binary) return Buffer.from(await response.arrayBuffer());
  const text = await response.text();
  return text ? JSON.parse(text) : undefined;
}

async function waitUntil(check, label, timeout = 300000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(`Timed out waiting for ${label}`);
}

async function verifyOriginals() {
  for (const item of received) {
    const original = await request('GET', `/assets/${item.id}/original`, undefined, true);
    assert.equal(createHash('sha256').update(original).digest('hex'), item.sha256);
  }
}

async function main() {
  assert.ok(fixtureRoot, 'Set RUNTIME_TEST_FIXTURES to the generated benchmark fixtures directory');
  try {
    compose('up', '-d', '--wait', '--wait-timeout', '300');
    await waitUntil(async () => {
      try {
        await request('GET', '/server/ping');
        return true;
      } catch {
        return false;
      }
    }, 'API startup');
    const credentials = {
      email: 'durable-backlog@inhouse.invalid',
      password: 'Isolated-Local-Test-Password!82',
      name: 'Durable backlog verification',
    };
    await request('POST', '/auth/admin-sign-up', credentials);
    token = (await request('POST', '/auth/login', { email: credentials.email, password: credentials.password }))
      .accessToken;
    const config = await request('GET', '/system-config');
    config.machineLearning.enabled = false;
    await request('PUT', '/system-config', config);

    const input = fs.readFileSync(path.join(fixtureRoot, 'jpeg-12mp.jpg'));
    const originals = [];
    for (let serial = 0; serial < 48; serial++) {
      // Distinct EXIF survives compression; trailing JPEG bytes alone would
      // produce identical outputs and exercise checksum conflicts instead.
      originals.push(
        await sharp(input)
          .keepMetadata()
          .withExifMerge({ IFD0: { ImageDescription: `inhouse-durable-receipt-${serial}` } })
          .jpeg({ quality: 100, chromaSubsampling: '4:4:4' })
          .toBuffer(),
      );
    }
    async function sendOriginal(serial) {
      const fields = new FormData();
      fields.set('fileCreatedAt', '2026-09-20T11:12:13.000Z');
      fields.set('fileModifiedAt', '2026-09-20T11:12:13.000Z');
      fields.set('storageSaver', 'true');
      fields.set('assetData', new Blob([originals[serial]]), `backlog-${serial}.jpg`);
      return request('POST', '/assets', fields);
    }
    const start = Date.now();
    // More than the former maximum mobile compression window (32), and
    // distinct checksums so a duplicate response cannot hide the bottleneck.
    for (let offset = 0; offset < 48; offset += 4) {
      await Promise.all(
        Array.from({ length: 4 }, async (_, index) => {
          const serial = offset + index;
          const bytes = originals[serial];
          const response = await sendOriginal(serial);
          assert.equal(response.status, 'created');
          received.push({
            id: response.id,
            serial,
            bytes: bytes.length,
            sha256: createHash('sha256').update(bytes).digest('hex'),
          });
        }),
      );
    }
    const uploadMs = Date.now() - start;
    assert.equal(received.length, 48);
    assert.equal(Number(sql('SELECT count(*) FROM asset_upload_processing')), 48);
    assert.equal(Number(sql('SELECT count(*) FROM asset')), 48);
    const originalReceipt = received.find((item) => item.serial === 0);
    assert.deepEqual(await sendOriginal(0), { id: originalReceipt.id, status: 'duplicate' });
    assert.equal(
      Number(sql('SELECT "quotaUsageInBytes" FROM "user"')),
      received.reduce((total, item) => total + item.bytes, 0),
    );
    await verifyOriginals();

    // The phone is now disconnected. Destroy the entire disposable Redis
    // database with the server stopped; only the durable DB and files survive.
    compose('stop', 'server');
    assert.equal(compose('exec', '-T', 'redis', 'valkey-cli', 'FLUSHDB').trim(), 'OK');
    compose('up', '-d', '--wait', '--wait-timeout', '300', 'server');
    await waitUntil(async () => {
      try {
        await request('GET', '/server/ping');
        return true;
      } catch {
        return false;
      }
    }, 'API restart after queue loss');
    assert.equal(Number(sql('SELECT count(*) FROM asset_upload_processing')), 48);
    await verifyOriginals();

    // Re-enable workers after receipt; no client uploads or socket events are
    // needed for the database outbox to recreate the lost processing jobs.
    workers = 'api,microservices';
    compose('up', '-d', '--wait', '--wait-timeout', '300', 'server');
    await waitUntil(() => Number(sql('SELECT count(*) FROM asset_upload_processing')) === 0, 'all 48 durable jobs');
    const assets = await Promise.all(received.map((item) => request('GET', `/assets/${item.id}`)));
    for (const asset of assets) {
      const original = received.find((item) => item.id === asset.id);
      assert.ok(asset.originalPath.endsWith('.storage-saver.jpg'));
      assert.ok(asset.exifInfo.fileSizeInByte < original.bytes);
      assert.ok(asset.exifInfo.exifImageWidth > 0 && asset.exifInfo.exifImageHeight > 0);
      assert.ok((await request('GET', `/assets/${asset.id}/original`, undefined, true)).length > 0);
    }
    assert.deepEqual(await sendOriginal(0), { id: originalReceipt.id, status: 'duplicate' });
    assert.equal(Number(sql('SELECT count(*) FROM asset')), 48);
    assert.equal(Number(sql('SELECT count(*) FROM asset_upload_processing')), 0);
    const result = {
      verifiedAt: new Date().toISOString(),
      uploadsWithoutProcessingWorker: received.length,
      uploadMs,
      uploadedBytes: received.reduce((total, item) => total + item.bytes, 0),
      allOriginalChecksumsVerifiedBeforeAndAfterRestart: true,
      recoveryAfterCompleteRedisLoss: true,
      completedWithoutPhoneConnected: assets.length,
      repeatedReceiptBeforeAndAfterCompressionReturnsSameAsset: true,
      pendingProcessingRows: 0,
    };
    fs.mkdirSync(path.dirname(resultsFile), { recursive: true });
    fs.writeFileSync(resultsFile, JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result, null, 2));
  } catch (error) {
    try {
      console.error(compose('logs', '--no-color', '--tail', '120'));
    } catch {}
    throw error;
  } finally {
    compose('down', '--volumes');
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
