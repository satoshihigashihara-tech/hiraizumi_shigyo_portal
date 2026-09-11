// Run: node --experimental-vm-modules --test tests/auth-return-to.test.mjs
// Load the actual dependency-free module under utils/auth/; no stubs.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const RETURN_TO = "utils/auth/return-to.js";

// The module is dependency-free, so a fresh context per load is enough.
// URL must be handed in: a vm context has no globals of its own.
async function load(path) {
  const context = vm.createContext({ URL });
  const loaded = new vm.SourceTextModule(await readFile(new URL(path, ROOT), "utf8"), {
    context,
    identifier: path,
  });
  await loaded.link(() => {
    throw new Error(`${path} must stay dependency-free`);
  });
  await loaded.evaluate();
  return loaded.namespace;
}

test("safeReturnTo keeps internal paths with their query string", async () => {
  const { safeReturnTo } = await load(RETURN_TO);
  assert.equal(safeReturnTo("/user"), "/user");
  assert.equal(safeReturnTo("/staff/applications"), "/staff/applications");
  assert.equal(safeReturnTo("/invite/abc123"), "/invite/abc123");
  // docs/routes.md 8章: 日程付きの安全な本人URLをそのまま戻り先にできる。
  assert.equal(
    safeReturnTo("/user/applications/new?start=2026-10-11&end=2026-10-13"),
    "/user/applications/new?start=2026-10-11&end=2026-10-13",
  );
  // hash はサーバーへ送られないため落とす。
  assert.equal(safeReturnTo("/user?tab=list#section"), "/user?tab=list");
});

test("safeReturnTo rejects anything that can leave the origin", async () => {
  const { safeReturnTo } = await load(RETURN_TO);
  // プロトコル相対URL・完全URL・スキーム付き（docs/routes.md 8章）。
  for (const value of [
    "//evil.example",
    "//evil.example/user",
    "https://evil.example/user",
    "http://evil.example",
    "javascript:alert(1)",
    "javascript:/user",
    "data:text/html,<script>alert(1)</script>",
    "user",
    "../user",
  ]) {
    assert.equal(safeReturnTo(value), null, value);
  }
});

test("safeReturnTo normalizes parser tricks down to an internal path", async () => {
  const { safeReturnTo } = await load(RETURN_TO);
  // URLパーサはバックスラッシュを `//` と同じに扱うため、ホスト部が落ちる。
  assert.equal(safeReturnTo("/\\evil.example"), "/");
  assert.equal(safeReturnTo("/\\evil.example/user"), "/user");
  // タブ・改行は除去されたうえで解釈される。ホストへは化けない。
  assert.equal(safeReturnTo("/\t/evil.example"), "/");
  assert.equal(safeReturnTo("/us\ner"), "/user");
});

test("safeReturnTo returns null for empty and non-string values", async () => {
  const { safeReturnTo } = await load(RETURN_TO);
  for (const value of [null, undefined, "", "   ", 0, 1, {}, [], ["/user"], true]) {
    assert.equal(safeReturnTo(value), null);
  }
});
