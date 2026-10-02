'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

// Exercise only the labelled disposable project created by the CI workflow.
const project = process.env.RUNTIME_TEST_PROJECT || 'inhouse-runtime-test';
assert.match(project, /^inhouse-runtime-test(?:-[a-z0-9_-]+)?$/);
const port = Number(process.env.RUNTIME_TEST_PORT || '19283');
assert.ok(Number.isSafeInteger(port) && port >= 1024 && port <= 65535);
const base = `http://127.0.0.1:${port}/api`;
const composeFile = path.resolve(process.env.RUNTIME_TEST_COMPOSE || path.join(__dirname, 'runtime-smoke.compose.yml'));
const composeArgs = ['compose', '-p', project, '-f', composeFile];
const fixtureRoot = process.env.RUNTIME_TEST_FIXTURES ? path.resolve(process.env.RUNTIME_TEST_FIXTURES) : undefined;
const resultsFile = path.resolve(
  process.env.RUNTIME_TEST_RESULTS || path.join(process.cwd(), 'runtime-smoke-results.json'),
);
const helper = fs.readFileSync(path.resolve(__dirname, '../../../desktop/server-runtime-queue-handoff.cjs'), 'utf8');
let token;

function compose(...args) {
  return execFileSync('docker', [...composeArgs, ...args], { encoding: 'utf8', maxBuffer: 2 * 1024 * 1024 });
}

function nodeInServer(code, ...args) {
  return execFileSync(
    'docker',
    [...composeArgs, 'exec', '-T', '-w', '/usr/src/app/server', 'server', 'node', '-', ...args],
    {
      input: code,
      encoding: 'utf8',
      timeout: 40000,
      maxBuffer: 2 * 1024 * 1024,
    },
  );
}

function queueAction(action, states) {
  return JSON.parse(
    nodeInServer(helper, action, ...(states ? [Buffer.from(JSON.stringify(states)).toString('base64')] : [])),
  );
}

async function api(method, endpoint, body) {
  const headers = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (body && !(body instanceof FormData)) headers['content-type'] = 'application/json';
  const response = await fetch(`${base}${endpoint}`, {
    method,
    headers,
    body: body ? (body instanceof FormData ? body : JSON.stringify(body)) : undefined,
    signal: AbortSignal.timeout(30000),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} ${endpoint}: ${response.status} ${text.slice(0, 500)}`);
  return text ? JSON.parse(text) : undefined;
}

async function upload(filename) {
  const fields = new FormData();
  const now = '2026-09-20T11:12:13.000Z';
  fields.set('fileCreatedAt', now);
  fields.set('fileModifiedAt', now);
  fields.set('storageSaver', 'true');
  fields.set('assetData', new Blob([fs.readFileSync(path.join(fixtureRoot, filename))]), filename);
  const response = await api('POST', '/assets', fields);
  assert.equal(response.status, 'created');
  assert.ok(response.id);
  return response.id;
}

function assetMatchesExpected(asset, expected) {
  if (!asset || !expected || typeof asset.originalPath !== 'string') return false;
  const metadata = asset.exifInfo;
  const bytes = metadata?.fileSizeInByte;
  if (!Number.isSafeInteger(bytes) || bytes <= 0 || !(metadata.exifImageWidth > 0) || !(metadata.exifImageHeight > 0)) {
    return false;
  }
  return expected.extension
    ? asset.originalPath.endsWith(expected.extension) && bytes < expected.inputBytes
    : !asset.originalPath.includes('.storage-saver.') && bytes === expected.inputBytes;
}

async function waitForProcessedAssets(
  expected,
  {
    getAssets,
    getQueues,
    now = Date.now,
    delay = () => new Promise((resolve) => setTimeout(resolve, 1000)),
    timeout = 180000,
  },
) {
  const deadline = now() + timeout;
  let assets = [];
  let pending;
  while (now() < deadline) {
    // Upload creates EXIF.fileSizeInByte with the original size. Queue completion
    // alone cannot prove that an earlier GET includes the final path or refreshed
    // metadata, so obtain a fresh snapshot and verify both final properties.
    pending = await getQueues();
    assets = await getAssets();
    if (
      pending.activeJobs === 0 &&
      pending.videoUnfinishedJobs === 0 &&
      pending.queues.storageSaverCompression.unfinishedJobs === 0 &&
      assets.length === expected.size &&
      assets.every((asset) => assetMatchesExpected(asset, expected.get(asset.id)))
    ) {
      return assets;
    }
    await delay();
  }
  throw new Error(
    `Timed out waiting for final Storage Saver paths and metadata: ${JSON.stringify({
      assets: assets.map((asset) => ({
        id: asset.id,
        originalPath: asset.originalPath,
        bytes: asset.exifInfo?.fileSizeInByte,
        expected: expected.get(asset.id),
      })),
      queues: pending,
    })}`,
  );
}

async function main() {
  assert.ok(fixtureRoot, 'Set RUNTIME_TEST_FIXTURES to the generated benchmark fixtures directory');
  const runtimeThreads = JSON.parse(
    nodeInServer(`
    const fs=require('node:fs');
    const found=[];
    for(const pid of fs.readdirSync('/proc').filter(x=>/^\\d+$/.test(x))) {
      try {
        const argv=fs.readFileSync('/proc/'+pid+'/cmdline','utf8').split('\\0').filter(Boolean);
        const executable=fs.readlinkSync('/proc/'+pid+'/exe');
        if(!executable.endsWith('/node')||!['immich','immich-api'].includes(argv[0])) continue;
        const env=fs.readFileSync('/proc/'+pid+'/environ','utf8').split('\\0');
        found.push({pid:Number(pid),command:argv.slice(0,3),threadPool:env.find(x=>x.startsWith('UV_THREADPOOL_SIZE='))?.split('=')[1],cpuCores:env.find(x=>x.startsWith('CPU_CORES='))?.split('=')[1]});
      } catch(error) {if(error.code!=='ENOENT')throw error;}
    }
    console.log(JSON.stringify(found));
  `),
  );
  assert.ok(runtimeThreads.length >= 2, 'Expected API and microservices Node processes');
  assert.ok(runtimeThreads.some((process) => process.command[0] === 'immich-api'));
  assert.ok(runtimeThreads.some((process) => process.command[0] === 'immich'));
  assert.ok(
    runtimeThreads.every((process) => process.threadPool === '16'),
    'Explicit UV_THREADPOOL_SIZE must survive startup',
  );
  assert.ok(
    runtimeThreads.every((process) => process.cpuCores === '5'),
    'Exercise the greater-than-four-CPU startup path',
  );
  const credentials = {
    email: 'runtime-test@inhouse.invalid',
    password: 'Isolated-Local-Test-Password!82',
    name: 'Runtime verification',
  };
  await api('POST', '/auth/admin-sign-up', credentials);
  const login = await api('POST', '/auth/login', { email: credentials.email, password: credentials.password });
  assert.equal(login.isAdmin, true);
  token = login.accessToken;
  const config = await api('GET', '/system-config');
  config.machineLearning.enabled = false;
  await api('PUT', '/system-config', config);

  const before = queueAction('inspect');
  assert.equal(before.videoUnfinishedJobs, 0);
  const pause = queueAction('pause');
  assert.equal(pause.activeJobs, 0);
  assert.deepEqual(Object.values(pause.pausedStates), [true, true]);

  // Force one queued video through the old mixed queue, as an existing backlog
  // from the previous runtime would be handed to the new video worker.
  const legacyVideoId = await upload('video-1080p.mp4');
  const handoff = JSON.parse(
    nodeInServer(`
    const { Queue } = require('bullmq');
    async function main() {
      const opts={prefix:'immich_bull',connection:{host:'redis'}};
      const video=new Queue('storageSaverVideoCompression',opts);
      const old=new Queue('storageSaverCompression',opts);
      try {
        const jobs=await video.getJobs(['paused','waiting']);
        if(jobs.length!==1||jobs[0].data.id!==${JSON.stringify(legacyVideoId)}) throw new Error('Unexpected test backlog');
        const data=jobs[0].data;
        await jobs[0].remove();
        await old.add('AssetCompressStorageSaver',data,{removeOnComplete:true});
        console.log(JSON.stringify({moved:1}));
      } finally {await video.close();await old.close();}
    }
    main().catch(e=>{console.error(e.message);process.exitCode=1});
  `),
  );
  assert.equal(handoff.moved, 1);
  const imageId = await upload('jpeg-12mp.jpg');
  const efficientVideoId = await upload('video-efficient-720p.mp4');
  const queued = queueAction('inspect');
  assert.equal(queued.queues.storageSaverCompression.counts.paused, 2);
  assert.equal(queued.queues.storageSaverVideoCompression.counts.paused, 1);
  assert.equal(queued.videoUnfinishedJobs, 1);
  assert.throws(() => queueAction('assert-video-empty'), /Rollback refused/);
  queueAction('resume', pause.previousPausedStates);

  const expected = new Map([
    [
      legacyVideoId,
      { extension: '.storage-saver.mp4', inputBytes: fs.statSync(path.join(fixtureRoot, 'video-1080p.mp4')).size },
    ],
    [
      imageId,
      { extension: '.storage-saver.jpg', inputBytes: fs.statSync(path.join(fixtureRoot, 'jpeg-12mp.jpg')).size },
    ],
    [
      efficientVideoId,
      { extension: null, inputBytes: fs.statSync(path.join(fixtureRoot, 'video-efficient-720p.mp4')).size },
    ],
  ]);
  const assets = await waitForProcessedAssets(expected, {
    getAssets: () => Promise.all([...expected.keys()].map((id) => api('GET', `/assets/${id}`))),
    getQueues: () => queueAction('inspect'),
  });
  const finalPause = queueAction('pause');
  const final = queueAction('assert-video-empty');
  assert.equal(final.activeJobs, 0);
  queueAction('resume', finalPause.previousPausedStates);
  const migrations = compose(
    'exec',
    '-T',
    'database',
    'psql',
    '-U',
    'postgres',
    '-d',
    'immich',
    '-tAc',
    'SELECT count(*), max(name) FROM kysely_migrations',
  ).trim();
  const counts = compose(
    'exec',
    '-T',
    'database',
    'psql',
    '-U',
    'postgres',
    '-d',
    'immich',
    '-tAc',
    'SELECT (SELECT count(*) FROM asset), (SELECT count(*) FROM "user")',
  ).trim();
  assert.equal(counts, '3|1');
  const result = {
    verifiedAt: new Date().toISOString(),
    runtimeThreads,
    signupAndLogin: true,
    migrations,
    assetAndUserCounts: counts,
    separatedQueues: true,
    oldVideoBacklogHandoff: true,
    efficientVideoSkipped: true,
    queueHelperPauseRestore: true,
    rollbackBlockedWithPendingVideo: true,
    assets: assets.map((asset) => ({
      id: asset.id,
      type: asset.type,
      originalPath: asset.originalPath,
      bytes: asset.exifInfo.fileSizeInByte,
      width: asset.exifInfo.exifImageWidth,
      height: asset.exifInfo.exifImageHeight,
    })),
    queues: final,
  };
  fs.mkdirSync(path.dirname(resultsFile), { recursive: true });
  fs.writeFileSync(resultsFile, JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
}

module.exports = { assetMatchesExpected, waitForProcessedAssets };

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
