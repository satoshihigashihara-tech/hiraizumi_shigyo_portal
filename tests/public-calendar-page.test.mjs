import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("public calendar renders only the existing public day contract", () => {
  const page = read("app/calendar/page.js");
  assert.match(page, /getPublicCalendar\(month\)/);
  assert.match(page, /day\.date/);
  assert.match(page, /day\.availability/);
  assert.doesNotMatch(page, /internal_reason|display_name|reception_number|people_count/);
});

test("public calendar normalizes months in JST and supports month navigation", () => {
  const month = read("utils/calendar/month.js");
  const page = read("app/calendar/page.js");
  assert.match(month, /timeZone: "Asia\/Tokyo"/);
  assert.match(month, /isDate\(`\$\{candidate\}-01`\)/);
  assert.match(page, /前の月/);
  assert.match(page, /今月/);
  assert.match(page, /次の月/);
});

test("public calendar uses text statuses and has loading and error states", () => {
  const page = read("app/calendar/page.js");
  const loading = read("app/calendar/loading.js");
  for (const label of ["申請可能", "利用不可", "受付開始前"]) assert.match(page, new RegExp(label));
  assert.match(page, /カレンダーを読み込めませんでした/);
  assert.match(loading, /カレンダーを読み込んでいます/);
  assert.match(read("app/page.js"), /href="\/calendar"/);
});
