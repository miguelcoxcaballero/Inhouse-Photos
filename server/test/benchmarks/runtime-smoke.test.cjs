'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { assetMatchesExpected, waitForProcessedAssets } = require('./runtime-smoke.cjs');

const expected = new Map([['video', { extension: '.storage-saver.mp4', inputBytes: 1000 }]]);
const completeQueues = {
  activeJobs: 0,
  videoUnfinishedJobs: 0,
  queues: { storageSaverCompression: { unfinishedJobs: 0 } },
};
const asset = (originalPath, bytes, width = 1920) => ({
  id: 'video',
  originalPath,
  exifInfo: { fileSizeInByte: bytes, exifImageWidth: width, exifImageHeight: 1080 },
});

test('queue completion does not accept an original-path snapshot or stale original metadata', async () => {
  const snapshots = [
    [asset('/data/source.mp4', 1000)],
    [asset('/data/source.mp4.storage-saver.mp4', 1000)],
    [asset('/data/source.mp4.storage-saver.mp4', 600)],
  ];
  let reads = 0;
  let clock = 0;
  const result = await waitForProcessedAssets(expected, {
    getQueues: async () => completeQueues,
    getAssets: async () => snapshots[reads++],
    now: () => clock,
    delay: async () => {
      clock++;
    },
    timeout: 10,
  });
  assert.equal(reads, 3);
  assert.equal(result[0].exifInfo.fileSizeInByte, 600);
});

test('final metadata does not accept a queue which is still processing another job', async () => {
  let reads = 0;
  let clock = 0;
  await waitForProcessedAssets(expected, {
    getQueues: async () => ({ ...completeQueues, videoUnfinishedJobs: reads === 0 ? 1 : 0 }),
    getAssets: async () => {
      reads++;
      return [asset('/data/source.mp4.storage-saver.mp4', 600)];
    },
    now: () => clock,
    delay: async () => {
      clock++;
    },
    timeout: 10,
  });
  assert.equal(reads, 2);
});

test('an efficient-video skip requires unchanged bytes and extracted dimensions', () => {
  const skip = { extension: null, inputBytes: 1000 };
  assert.equal(assetMatchesExpected(asset('/data/source.mp4', 1000), skip), true);
  assert.equal(assetMatchesExpected(asset('/data/source.mp4', 600), skip), false);
  assert.equal(assetMatchesExpected(asset('/data/source.mp4.storage-saver.mp4', 1000), skip), false);
  assert.equal(assetMatchesExpected(asset('/data/source.mp4', 1000, null), skip), false);
});

test('missing assets or unchanged originals time out with the final path and size in diagnostics', async () => {
  for (const snapshot of [[], [asset('/data/source.mp4', 1000)]]) {
    let clock = 0;
    await assert.rejects(
      waitForProcessedAssets(expected, {
        getQueues: async () => completeQueues,
        getAssets: async () => snapshot,
        now: () => clock,
        delay: async () => {
          clock++;
        },
        timeout: 2,
      }),
      /Timed out waiting for final Storage Saver paths and metadata/,
    );
  }
});
