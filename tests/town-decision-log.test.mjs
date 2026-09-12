import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const logPath = new URL("../docs/town-decision-log.md", import.meta.url);

test("town decision log preserves the B0 approval gate and all requirement questions", async () => {
  const log = await readFile(logPath, "utf8");

  assert.match(log, /B1以降の制度仕様の実装は開始しない/);
  for (let index = 1; index <= 18; index += 1) {
    assert.match(log, new RegExp(`D${String(index).padStart(2, "0")}`));
  }
  for (let index = 1; index <= 4; index += 1) {
    assert.match(log, new RegExp(`C${String(index).padStart(2, "0")}`));
  }
});

test("town decision log identifies decision owners and downstream areas", async () => {
  const log = await readFile(logPath, "utf8");

  assert.match(log, /町側の主決定者/);
  assert.match(log, /回答後に影響するDB \/ UI \/ 運用/);
  assert.match(log, /決定内容・根拠資料・決定日・決定者/);
});
