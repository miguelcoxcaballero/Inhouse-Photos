#!/usr/bin/env node
"use strict";

// Run through `docker exec -i <server> node - <action>` with this file on stdin.
// This helper changes only the paused flags of the two Storage Saver queues.
// It never deletes, moves, retries, or rewrites jobs.
const path = require("node:path");

const QUEUE_NAMES = ["storageSaverCompression", "storageSaverVideoCompression"];
const JOB_STATES = [
  "active",
  "waiting",
  "paused",
  "delayed",
  "prioritized",
  "waiting-children",
  "failed",
];
const ACTIONS = new Set([
  "inspect",
  "pause",
  "resume",
  "restore",
  "assert-video-empty",
]);

function integerEnv(env, key, fallback, minimum, maximum) {
  if (env[key] === undefined || env[key] === "") return fallback;
  const value = Number(env[key]);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`Invalid ${key} configuration.`);
  }
  return value;
}

function redisConnection(env) {
  if (env.REDIS_PASSWORD_FILE) {
    throw new Error(
      "This update helper requires Redis credentials in the existing container environment; REDIS_PASSWORD_FILE is unsupported.",
    );
  }
  let connection = {
    host: env.REDIS_HOSTNAME || "redis",
    port: integerEnv(env, "REDIS_PORT", 6379, 1, 65535),
    db: integerEnv(env, "REDIS_DBINDEX", 0, 0, 2147483647),
    username: env.REDIS_USERNAME || undefined,
    password: env.REDIS_PASSWORD || undefined,
    path: env.REDIS_SOCKET || undefined,
  };

  // Match ConfigRepository: REDIS_URL is a base64 JSON ioredis options object.
  if (env.REDIS_URL?.startsWith("ioredis://")) {
    try {
      connection = JSON.parse(
        Buffer.from(env.REDIS_URL.slice(10), "base64").toString("utf8"),
      );
      if (
        !connection ||
        Array.isArray(connection) ||
        typeof connection !== "object"
      )
        throw new Error();
    } catch {
      throw new Error("Invalid REDIS_URL configuration.");
    }
  }

  return {
    ...connection,
    connectTimeout: 10000,
    maxRetriesPerRequest: 1,
    retryStrategy: () => null,
  };
}

function parsePausedStates(encoded) {
  let value;
  try {
    if (typeof encoded !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded))
      throw new Error();
    const bytes = Buffer.from(encoded, "base64");
    if (bytes.toString("base64") !== encoded) throw new Error();
    value = JSON.parse(bytes.toString("utf8"));
  } catch {
    throw new Error(
      "Restore requires the original pausedStates JSON object encoded as UTF-8 base64.",
    );
  }
  if (
    !value ||
    Array.isArray(value) ||
    typeof value !== "object" ||
    Object.keys(value).length !== QUEUE_NAMES.length ||
    QUEUE_NAMES.some((name) => typeof value[name] !== "boolean")
  ) {
    throw new Error(
      "Restore requires one boolean paused state for each Storage Saver queue.",
    );
  }
  return value;
}

async function inspectQueues(queues) {
  const result = {
    schemaVersion: 1,
    pausedStates: {},
    queues: {},
    activeJobs: 0,
    videoUnfinishedJobs: 0,
  };
  for (let index = 0; index < QUEUE_NAMES.length; index++) {
    const name = QUEUE_NAMES[index];
    const [isPaused, counts] = await Promise.all([
      queues[index].isPaused(),
      queues[index].getJobCounts(...JOB_STATES),
    ]);
    const safeCounts = {};
    for (const state of JOB_STATES) {
      const count = counts[state] ?? 0;
      if (!Number.isSafeInteger(count) || count < 0)
        throw new Error("Invalid queue statistics.");
      safeCounts[state] = count;
    }
    const unfinishedJobs = Object.values(safeCounts).reduce(
      (sum, count) => sum + count,
      0,
    );
    result.pausedStates[name] = isPaused;
    result.queues[name] = { isPaused, counts: safeCounts, unfinishedJobs };
    result.activeJobs += safeCounts.active;
    if (name === "storageSaverVideoCompression")
      result.videoUnfinishedJobs = unfinishedJobs;
  }
  return result;
}

async function runAction(action, encodedStates, queues) {
  if (!ACTIONS.has(action))
    throw new Error(
      "Expected inspect, pause, resume, restore, or assert-video-empty.",
    );
  const states =
    action === "restore" || action === "resume"
      ? parsePausedStates(encodedStates)
      : undefined;
  const before = await inspectQueues(queues);

  if (action === "assert-video-empty") {
    if (QUEUE_NAMES.some((name) => before.pausedStates[name] !== true)) {
      throw new Error(
        "Rollback refused: pause both Storage Saver queues before checking unfinished jobs.",
      );
    }
    if (before.videoUnfinishedJobs !== 0) {
      throw new Error(
        "Rollback refused: the new video queue contains unfinished jobs. Keep the new server image and finish these jobs before rolling back.",
      );
    }
    if (before.activeJobs !== 0)
      throw new Error("Rollback refused: Storage Saver jobs are still active.");
    return before;
  }

  if (action === "pause") {
    for (const queue of queues) await queue.pause();
    return {
      ...(await inspectQueues(queues)),
      previousPausedStates: before.pausedStates,
    };
  }

  if (states) {
    for (let index = 0; index < QUEUE_NAMES.length; index++) {
      if (states[QUEUE_NAMES[index]]) await queues[index].pause();
      else await queues[index].resume();
    }
    return inspectQueues(queues);
  }

  return before;
}

async function main(args = process.argv.slice(2)) {
  const [action, encodedStates, ...extra] = args;
  if (
    !ACTIONS.has(action) ||
    extra.length ||
    (action === "resume" || action === "restore") !==
      (encodedStates !== undefined)
  ) {
    throw new Error(
      "Usage: node - inspect|pause|assert-video-empty, or node - restore <base64 pausedStates JSON>.",
    );
  }
  // Validate restore arguments before creating a connection or mutating Redis.
  if (action === "resume" || action === "restore")
    parsePausedStates(encodedStates);
  const { Queue } = require(
    require.resolve("bullmq", {
      paths: [
        process.cwd(),
        "/usr/src/app/server",
        "/usr/src/app",
        path.join(__dirname, "..", "server"),
      ],
    }),
  );
  const connection = redisConnection(process.env);
  const queues = QUEUE_NAMES.map(
    (name) => new Queue(name, { prefix: "immich_bull", connection }),
  );
  for (const queue of queues) queue.on("error", () => {});
  const timer = setTimeout(() => {
    console.error(
      "Queue check timed out. Queue jobs were preserved; do not replace the server until its queue state is verified.",
    );
    process.exit(1);
  }, 30000);
  try {
    console.log(JSON.stringify(await runAction(action, encodedStates, queues)));
  } finally {
    // Disconnect also finishes promptly if Redis is unavailable.
    await Promise.allSettled(queues.map((queue) => queue.disconnect()));
    clearTimeout(timer);
  }
}

module.exports = {
  QUEUE_NAMES,
  JOB_STATES,
  redisConnection,
  parsePausedStates,
  inspectQueues,
  runAction,
};

if (require.main === module || process.argv[1] === "-") {
  main().catch((error) => {
    // Configuration errors intentionally contain variable names, never values.
    console.error(error.message);
    process.exitCode = 1;
  });
}
