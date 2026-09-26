import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { test } from "node:test";
import vm from "node:vm";

const path = new URL("../utils/auth/session-timeout.js", import.meta.url);

async function load() {
  const loaded = new vm.SourceTextModule(await readFile(path, "utf8"));
  await loaded.link(() => { throw new Error("session-timeout.js must stay dependency-free"); });
  await loaded.evaluate();
  return loaded.namespace;
}

test("production ignores overrides; development accepts only bounded milliseconds", async () => {
  const { sessionTimeoutMs, SESSION_DURATION_MS } = await load();
  assert.equal(sessionTimeoutMs("production", "90000"), SESSION_DURATION_MS);
  assert.equal(sessionTimeoutMs("development", "90000"), 90000);
  for (const value of ["", "1000", "60000.1", "-1", "1800001", "abc"]) {
    assert.equal(sessionTimeoutMs("development", value), SESSION_DURATION_MS);
  }
});

test("warning starts one minute before expiry and activity extends deadline", async () => {
  const { remainingMs, warningStartsAt } = await load();
  const start = 1_000_000;
  assert.equal(warningStartsAt(start, 1_800_000), start + 1_740_000);
  assert.equal(remainingMs(start, start + 1_740_000, 1_800_000), 60_000);
  assert.equal(remainingMs(start, start + 1_800_000, 1_800_000), 0);
  assert.equal(remainingMs(start + 1_740_000, start + 1_800_000, 1_800_000), 1_740_000);
});

test("activity timestamps and login identities reject invalid state", async () => {
  const { validActivity, sessionStorageId } = await load();
  assert.equal(validActivity("999", 1000), 999);
  for (const raw of [null, "", "0", "-1", "1001", "1.5", "NaN"]) {
    assert.equal(validActivity(raw, 1000), null);
  }
  assert.equal(sessionStorageId({ user: { id: "u", last_sign_in_at: "2026-01-01" } }), "u%3A2026-01-01");
  assert.equal(sessionStorageId({ user: { id: "u" } }), null);
});

test("keyboard and touch activity close the warning and restart the deadline", async () => {
  const require = createRequire(import.meta.url);
  const { transformSync } = require("next/dist/build/swc");
  const source = await readFile(new URL("../app/components/SessionTimeout.js", import.meta.url), "utf8");
  const helper = (await readFile(path, "utf8")).replace(/\bexport /g, "");
  const component = transformSync(source, {
    jsc: {
      target: "es2022",
      parser: { syntax: "ecmascript", jsx: true },
      transform: { react: { runtime: "classic" } },
    },
    module: { type: "es6" },
  }).code
    .replace(/^import[\s\S]*?from "[^"]+";\r?\n/gm, "")
    .replace("export default function SessionTimeout", "function SessionTimeout");

  let now = 2_000_000_000_000;
  let nextTimer = 0;
  let nextState = 0;
  const timers = new Map();
  const listeners = new Map();
  const values = new Map();
  const states = [];
  let signOutCalls = 0;
  let destination = null;
  const add = (name, callback) => {
    if (!listeners.has(name)) listeners.set(name, new Set());
    listeners.get(name).add(callback);
  };
  const remove = (name, callback) => listeners.get(name)?.delete(callback);
  const browser = {
    addEventListener: add,
    removeEventListener: remove,
    setTimeout(callback, delay) {
      const id = ++nextTimer;
      timers.set(id, { at: now + delay, callback });
      return id;
    },
    clearTimeout(id) { timers.delete(id); },
  };
  const context = vm.createContext({
    window: browser,
    document: { hidden: false, addEventListener: add, removeEventListener: remove },
    localStorage: {
      getItem: key => values.has(key) ? values.get(key) : null,
      setItem: (key, value) => values.set(key, value),
    },
    Date: { now: () => now },
    React: { createElement: () => null },
    useRouter: () => ({ replace(value) { destination = value; } }),
    useState(initial) {
      const index = nextState++;
      states[index] = initial;
      return [initial, value => { states[index] = value; }];
    },
    useEffect(callback) { callback(); },
    createClient: () => ({
      auth: {
        getSession: async () => ({ data: { session: { user: { id: "test", last_sign_in_at: "login" } } } }),
        signOut: async () => {
          signOutCalls++;
          return { error: null };
        },
      },
    }),
    styles: { notice: "notice" },
  });
  vm.runInContext(helper + "\n" + component + "\nSessionTimeout({ durationMs: 90000 });", context);
  await new Promise(resolve => setImmediate(resolve));

  function advance(milliseconds) {
    const target = now + milliseconds;
    while (true) {
      const due = [...timers.entries()].sort((a, b) => a[1].at - b[1].at)[0];
      if (!due || due[1].at > target) break;
      timers.delete(due[0]);
      now = due[1].at;
      due[1].callback();
    }
    now = target;
  }
  function act(name) {
    for (const callback of listeners.get(name) ?? []) callback({});
  }
  function lastActivity() {
    const key = [...values.keys()].find(value => value.startsWith("shigyo:last-activity:"));
    return Number(values.get(key));
  }

  advance(30000);
  assert.equal(states[0], true);
  act("keydown");
  assert.equal(states[0], false);
  assert.equal(lastActivity(), now);

  advance(30000);
  assert.equal(states[0], true);
  act("touchstart");
  assert.equal(states[0], false);
  assert.equal(lastActivity(), now);
  assert.equal([...timers.values()][0].at, now + 30000);

  context.localStorage.getItem = () => { throw new Error("Storage unavailable"); };
  context.localStorage.setItem = () => { throw new Error("Storage unavailable"); };
  advance(90000);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(signOutCalls, 1);
  assert.equal(destination, "/login?error=session-timeout");
});