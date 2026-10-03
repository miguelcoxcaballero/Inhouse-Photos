"use strict";

const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
  QUEUE_NAMES,
  JOB_STATES,
  redisConnection,
  parsePausedStates,
  runAction,
} = require("./server-runtime-queue-handoff.cjs");

const encode = (value) =>
  Buffer.from(JSON.stringify(value), "utf8").toString("base64");

function fakeQueue(paused, counts = {}) {
  const queue = {
    paused,
    calls: [],
    async isPaused() {
      return this.paused;
    },
    async getJobCounts(...states) {
      assert.deepEqual(states, JOB_STATES);
      return counts;
    },
    async pause() {
      this.calls.push("pause");
      this.paused = true;
    },
    async resume() {
      this.calls.push("resume");
      this.paused = false;
    },
  };
  return queue;
}

test("inspection counts every unfinished state and never changes jobs or paused flags", async () => {
  const queues = [
    fakeQueue(false, { active: 1, waiting: 2 }),
    fakeQueue(true, { paused: 3, delayed: 4, failed: 5 }),
  ];
  const result = await runAction("inspect", undefined, queues);
  assert.equal(result.activeJobs, 1);
  assert.equal(result.videoUnfinishedJobs, 12);
  assert.deepEqual(result.pausedStates, {
    [QUEUE_NAMES[0]]: false,
    [QUEUE_NAMES[1]]: true,
  });
  assert.deepEqual(
    queues.flatMap((queue) => queue.calls),
    [],
  );
});

test("pause saves original states and restore preserves a previously paused queue", async () => {
  const queues = [fakeQueue(false), fakeQueue(true)];
  const result = await runAction("pause", undefined, queues);
  assert.deepEqual(result.previousPausedStates, {
    [QUEUE_NAMES[0]]: false,
    [QUEUE_NAMES[1]]: true,
  });
  assert.deepEqual(result.pausedStates, {
    [QUEUE_NAMES[0]]: true,
    [QUEUE_NAMES[1]]: true,
  });
  const restored = await runAction(
    "restore",
    encode(result.previousPausedStates),
    queues,
  );
  assert.deepEqual(restored.pausedStates, result.previousPausedStates);
  assert.deepEqual(queues[0].calls, ["pause", "resume"]);
  assert.deepEqual(queues[1].calls, ["pause", "pause"]);
});

test("restore refuses missing, unexpected, or nonboolean states before changing a queue", async () => {
  for (const value of [
    undefined,
    "{}",
    encode({}),
    encode([]),
    encode({ [QUEUE_NAMES[0]]: false, [QUEUE_NAMES[1]]: 0 }),
    encode({ [QUEUE_NAMES[0]]: false, [QUEUE_NAMES[1]]: false, extra: true }),
  ]) {
    const queues = [fakeQueue(true), fakeQueue(true)];
    await assert.rejects(
      runAction("restore", value, queues),
      /Restore requires/,
    );
    assert.deepEqual(
      queues.flatMap((queue) => queue.calls),
      [],
    );
  }
});

test("rollback refuses pending, paused, delayed, active, failed, and dependency jobs", async () => {
  await assert.rejects(
    runAction("assert-video-empty", undefined, [
      fakeQueue(false),
      fakeQueue(true),
    ]),
    /pause both/,
  );
  for (const state of JOB_STATES) {
    const queues = [fakeQueue(true), fakeQueue(true, { [state]: 1 })];
    await assert.rejects(
      runAction("assert-video-empty", undefined, queues),
      /Rollback refused/,
    );
    assert.deepEqual(
      queues.flatMap((queue) => queue.calls),
      [],
    );
  }
  await assert.rejects(
    runAction("assert-video-empty", undefined, [
      fakeQueue(true, { active: 1 }),
      fakeQueue(true),
    ]),
    /still active/,
  );
  await runAction("assert-video-empty", undefined, [
    fakeQueue(true, { paused: 100 }),
    fakeQueue(true),
  ]);
});

test("invalid counts fail closed", async () => {
  await assert.rejects(
    runAction("inspect", undefined, [
      fakeQueue(false),
      fakeQueue(false, { waiting: -1 }),
    ]),
    /Invalid queue/,
  );
});

test("rollback preserves pending durable uploads even when both Redis queues are empty", async () => {
  const queues = [fakeQueue(true), fakeQueue(true)];
  await assert.rejects(
    runAction("assert-rollback-safe", undefined, queues, async () => ({
      present: true,
      pending: true,
    })),
    /persistent upload backlog contains unfinished/,
  );
  assert.deepEqual(
    queues.flatMap((queue) => queue.calls),
    [],
  );
});

test("rollback refuses an installed migration after the outbox drains", async () => {
  await assert.rejects(
    runAction(
      "assert-rollback-safe",
      undefined,
      [fakeQueue(true), fakeQueue(true)],
      async () => ({
        present: true,
        pending: false,
      }),
    ),
    /previous image cannot read this migration/,
  );
});

test("rollback allows the original schema and fails closed without a verified database state", async () => {
  const queues = [fakeQueue(true), fakeQueue(true)];
  const result = await runAction(
    "assert-rollback-safe",
    undefined,
    queues,
    async () => ({
      present: false,
      pending: false,
    }),
  );
  assert.deepEqual(result.durableUploadProcessing, {
    present: false,
    pending: false,
  });
  await assert.rejects(
    runAction("assert-rollback-safe", undefined, queues),
    /check is required/,
  );
  await assert.rejects(
    runAction("assert-rollback-safe", undefined, queues, async () => ({})),
    /invalid persistent backlog state/,
  );
  await assert.rejects(
    runAction("assert-rollback-safe", undefined, queues, async () => {
      throw new Error("Database unavailable");
    }),
    /Database unavailable/,
  );
});

test("connection options match server Redis settings without exposing credentials in errors", () => {
  assert.throws(
    () => redisConnection({ REDIS_PASSWORD_FILE: "/secret/path" }),
    /REDIS_PASSWORD_FILE is unsupported/,
  );
  const explicit = redisConnection({
    REDIS_HOSTNAME: "local-redis",
    REDIS_PORT: "6380",
    REDIS_DBINDEX: "2",
    REDIS_USERNAME: "user",
    REDIS_PASSWORD: "secret",
  });
  assert.equal(explicit.host, "local-redis");
  assert.equal(explicit.port, 6380);
  assert.equal(explicit.db, 2);
  assert.equal(explicit.password, "secret");
  const encoded = Buffer.from(
    JSON.stringify({
      host: "encoded-host",
      db: 3,
      password: "other-secret",
      tls: {},
    }),
  ).toString("base64");
  const parsed = redisConnection({ REDIS_URL: `ioredis://${encoded}` });
  assert.equal(parsed.host, "encoded-host");
  assert.equal(parsed.db, 3);
  assert.deepEqual(parsed.tls, {});
  assert.equal(parsed.retryStrategy(), null);
  assert.throws(
    () => redisConnection({ REDIS_PORT: "secret" }),
    /^Error: Invalid REDIS_PORT configuration\.$/,
  );
  assert.throws(
    () => redisConnection({ REDIS_URL: "ioredis://bad-secret" }),
    /^Error: Invalid REDIS_URL configuration\.$/,
  );
  assert.throws(() => parsePausedStates(encode("secret")), /one boolean/);
});
