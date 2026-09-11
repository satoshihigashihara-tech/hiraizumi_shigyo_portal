// Run: node --experimental-vm-modules --test tests/components-foundation.test.mjs
// Load the actual dependency-free modules under app/components/; no JSX, no stubs.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);

// Every module here is dependency-free, so a fresh context per load is enough:
// module state cannot leak between tests, and the time-zone test can re-evaluate
// a module after changing process.env.TZ. "@/x" resolves like the app's alias.
async function load(path) {
  const context = vm.createContext({});
  const cache = new Map();
  async function link(specifier) {
    if (cache.has(specifier)) return cache.get(specifier);
    const filename = specifier.startsWith("@/") ? `${specifier.slice(2)}.js` : specifier;
    const loaded = new vm.SourceTextModule(await readFile(new URL(filename, ROOT), "utf8"), { context, identifier: filename });
    cache.set(specifier, loaded);
    await loaded.link(link);
    return loaded;
  }
  const loaded = await link(path);
  await loaded.evaluate();
  return loaded.namespace;
}

const FORMAT = "app/components/format.js";
const STATUS = "app/components/status-labels.js";
const MESSAGES = "app/components/messages.js";
const MOCK = "app/components/mock-data.js";
const CONTRACT = "utils/community-applications/validation.js";
const sum = (values) => values.reduce((total, value) => total + value, 0);

/* ---------------------------------------------------------------- format.js */

test("formatDeadline shows the stored exclusive boundary minus one minute", async () => {
  const { formatDeadline } = await load(FORMAT);
  // docs/database.md 8章: the DB keeps the next day's 00:00, the screen shows 23:59.
  assert.equal(formatDeadline("2026-10-01T00:00:00.000000+09:00"), "2026年9月30日 23:59");
  // The subtraction must cross month and year boundaries, not just the hour.
  assert.equal(formatDeadline("2027-01-01T00:00:00+09:00"), "2026年12月31日 23:59");
  assert.equal(formatDeadline("2026-08-01T00:00:00.000000+09:00"), "2026年7月31日 23:59");
  // A boundary stored in UTC describes the same instant.
  assert.equal(formatDeadline("2026-09-30T15:00:00Z"), "2026年9月30日 23:59");
  for (const value of [null, undefined, "", "  ", "not-a-date", 20261001, "2026-02-31"]) {
    assert.equal(formatDeadline(value), "");
  }
  // A date-only value is not an exclusive boundary: subtracting a minute from
  // the 12:00 JST anchor would print "11:59", a deadline that is not in the data.
  assert.equal(formatDeadline("2026-10-01"), "2026年10月1日");
});

test("formatJstDateTime never invents a time for date-only input", async () => {
  const { formatJstDateTime, formatJstDate } = await load(FORMAT);
  // toDate pins date-only values to 12:00 JST, so formatting them with a time
  // would print "2026年10月11日 12:00" - a time that is not in the data.
  assert.equal(formatJstDateTime("2026-10-11"), "2026年10月11日");
  assert.equal(formatJstDateTime("2026-10-11"), formatJstDate("2026-10-11"));
  assert.equal(formatJstDateTime("2026-09-08T14:59:00.000000+00:00"), "2026年9月8日 23:59");
  assert.equal(formatJstDateTime("2026-09-08T23:59:00+09:00"), "2026年9月8日 23:59");
  // Date-only input that does not exist must not degrade into a nearby day.
  assert.equal(formatJstDateTime("2026-02-31"), "");
  assert.equal(formatJstDateTime(null), "");
});

test("countStayDays counts both ends and rejects dates that do not exist", async () => {
  const { countStayDays } = await load(FORMAT);
  // docs/requirements.md 16.1: both the first and the last day are counted.
  assert.equal(countStayDays("2026-08-15", "2026-08-15"), 1);
  assert.equal(countStayDays("2026-08-15", "2026-08-16"), 2);
  assert.equal(countStayDays("2026-08-15", "2026-09-15"), 32);
  assert.equal(countStayDays("2028-02-28", "2028-03-01"), 3); // leap year
  assert.equal(countStayDays("2026-12-31", "2027-01-01"), 2); // year boundary
  // Date.UTC would roll these over silently: 2/31 -> 3/3, 13月 -> 翌年1月,
  // "0026" -> 1926年. Rolled-over values must not produce a day count.
  assert.equal(countStayDays("2026-02-31", "2026-03-05"), null);
  assert.equal(countStayDays("2026-13-01", "2026-13-05"), null);
  assert.equal(countStayDays("0026-01-01", "0026-01-05"), null);
  assert.equal(countStayDays("2026-00-10", "2026-01-11"), null);
  assert.equal(countStayDays("2027-02-29", "2027-03-01"), null); // not a leap year
  // Start after end, and anything that is not a bare date.
  assert.equal(countStayDays("2026-09-15", "2026-08-15"), null);
  for (const [start, end] of [[null, "2026-08-16"], ["2026-08-15", undefined], ["2026-8-15", "2026-08-16"],
    ["2026-08-15T00:00:00Z", "2026-08-16T00:00:00Z"], ["", ""]]) {
    assert.equal(countStayDays(start, end), null);
  }
});

test("date-only validation is shared, so period display and day count agree", async () => {
  const { formatPeriod, formatJstDate, countStayDays } = await load(FORMAT);
  assert.equal(formatPeriod("2026-08-15", "2026-09-15"), "2026年8月15日 〜 2026年9月15日");
  assert.equal(formatPeriod(null, "2026-09-15"), "未定");
  assert.equal(formatPeriod("2026-08-15", null), "未定");
  assert.equal(formatPeriod(null, null), "未定");
  // A rolled-over start date used to render as "2026年3月3日 〜 2026年3月1日",
  // i.e. a period whose start looks later than its end while countStayDays said null.
  assert.equal(formatJstDate("2026-02-31"), "");
  assert.equal(formatPeriod("2026-02-31", "2026-03-01"), "未定");
  assert.equal(countStayDays("2026-02-31", "2026-03-01"), null);
});

test("formatYen renders integers only", async () => {
  const { formatYen } = await load(FORMAT);
  assert.equal(formatYen(0), "0円");
  assert.equal(formatYen(300), "300円");
  assert.equal(formatYen(9600), "9,600円");
  assert.equal(formatYen(1234567), "1,234,567円");
  for (const value of [null, undefined, "9600", 1.5, NaN, Infinity, {}]) {
    assert.equal(formatYen(value), "");
  }
});

test("formatMonth and jstToday stay on the Japanese calendar day", async () => {
  const { formatMonth, jstToday } = await load(FORMAT);
  assert.equal(formatMonth("2026-08-01"), "2026年8月");
  assert.equal(formatMonth("2026-12-01"), "2026年12月");
  assert.equal(formatMonth("2026-02-31"), "");
  assert.equal(formatMonth(null), "");
  // 23:59:59 JST is still the same day; 00:00 JST is the next one.
  assert.equal(jstToday(new Date("2026-09-08T14:59:59Z")), "2026-09-08");
  assert.equal(jstToday(new Date("2026-09-08T15:00:00Z")), "2026-09-09");
  assert.equal(jstToday(new Date("2026-12-31T15:00:00Z")), "2027-01-01");
});

test("output is fixed to JST and does not follow the process time zone", async () => {
  const original = process.env.TZ;
  const sample = (api) => [
    api.formatDeadline("2026-10-01T00:00:00.000000+09:00"),
    api.formatJstDateTime("2026-09-08T14:59:00Z"),
    api.formatJstDateTime("2026-10-11"),
    api.formatJstDate("2026-08-15"),
    api.formatMonth("2026-08-01"),
    api.formatPeriod("2026-08-15", "2026-09-15"),
    api.countStayDays("2026-08-15", "2026-09-15"),
    api.jstToday(new Date("2026-09-08T15:00:00Z")),
  ];
  try {
    const results = [];
    // The module is re-evaluated after each change, so its module-level
    // Intl.DateTimeFormat instances are built under that time zone.
    for (const zone of ["UTC", "America/New_York", "Pacific/Kiritimati", "Asia/Tokyo"]) {
      process.env.TZ = zone;
      results.push(sample(await load(FORMAT)));
    }
    for (const result of results) assert.deepEqual(result, results[0]);
    assert.deepEqual(results[0], ["2026年9月30日 23:59", "2026年9月8日 23:59", "2026年10月11日",
      "2026年8月15日", "2026年8月", "2026年8月15日 〜 2026年9月15日", 32, "2026-09-09"]);
  } finally {
    if (original === undefined) delete process.env.TZ;
    else process.env.TZ = original;
  }
});

/* -------------------------------------------------------- status-labels.js */

test("statusLabel degrades instead of throwing for unset and unknown values", async () => {
  const { statusLabel } = await load(STATUS);
  assert.equal(statusLabel("application", "submitted"), "申請済み");
  for (const value of [null, undefined, ""]) assert.equal(statusLabel("application", value), "状態未設定");
  for (const value of ["shipped", "APPROVED", " approved", 1, {}]) {
    assert.equal(statusLabel("application", value), "状態不明");
  }
  // An unknown or missing kind must not throw either.
  assert.equal(statusLabel("unknown-kind", "approved"), "状態不明");
  assert.equal(statusLabel(undefined, "approved"), "状態不明");
  assert.equal(statusLabel("application", "toString"), "状態不明"); // no prototype leak
});

test("each kind keeps its own dictionary, so values cannot be read across kinds", async () => {
  const { statusLabel, LABELS_BY_KIND, APPLICATION_STATUS_LABELS, GROUP_STATUS_LABELS,
    PAYMENT_STATUS_LABELS, STAY_STATUS_LABELS } = await load(STATUS);
  assert.equal(LABELS_BY_KIND, undefined); // internal, not part of the API
  // docs/coding_rules.md 7章: 申請・納付・滞在の状態を混ぜない。
  assert.equal(statusLabel("payment", "submitted"), "状態不明");
  assert.equal(statusLabel("payment", "approved"), "状態不明");
  assert.equal(statusLabel("stay", "unpaid"), "状態不明");
  assert.equal(statusLabel("application", "staying"), "状態不明");
  assert.equal(statusLabel("application", "collecting"), "状態不明");
  // collecting is the only value the group dictionary adds to the application one.
  assert.equal(statusLabel("group", "collecting"), "申請中");
  assert.deepEqual(Object.keys(GROUP_STATUS_LABELS).filter((key) => !(key in APPLICATION_STATUS_LABELS)), ["collecting"]);
  assert.deepEqual(Object.keys(APPLICATION_STATUS_LABELS).filter((key) => !(key in GROUP_STATUS_LABELS)), ["submitted"]);
  assert.equal(Object.keys(APPLICATION_STATUS_LABELS).length, 8); // DBの8値すべて
  assert.deepEqual(Object.keys(PAYMENT_STATUS_LABELS), ["unpaid", "paid"]);
  assert.deepEqual(Object.keys(STAY_STATUS_LABELS), ["before_move_in", "staying", "moved_out"]);
  // 「申請済み」を「許可済み」と表示しない。
  assert.equal(statusLabel("application", "submitted"), "申請済み");
  assert.equal(statusLabel("application", "approved"), "許可");
});

test("statusTone covers every label and falls back to neutral", async () => {
  const { statusTone, STATUS_TONES, STATUS_KIND_LABELS, APPLICATION_STATUS_LABELS,
    GROUP_STATUS_LABELS, PAYMENT_STATUS_LABELS, STAY_STATUS_LABELS } = await load(STATUS);
  const dictionaries = { application: APPLICATION_STATUS_LABELS, group: GROUP_STATUS_LABELS,
    payment: PAYMENT_STATUS_LABELS, stay: STAY_STATUS_LABELS };
  const tones = new Set(["neutral", "info", "success", "warning", "danger"]);
  for (const [kind, labels] of Object.entries(dictionaries)) {
    assert.ok(STATUS_KIND_LABELS[kind], `${kind} needs a kind label for screen readers`);
    assert.deepEqual(Object.keys(STATUS_TONES[kind]), Object.keys(labels));
    for (const value of Object.keys(labels)) assert.ok(tones.has(statusTone(kind, value)));
  }
  assert.equal(statusTone("application", "rejected"), "danger");
  assert.equal(statusTone("payment", "unpaid"), "warning");
  for (const [kind, value] of [["application", "shipped"], ["unknown-kind", "approved"],
    ["payment", null], ["application", "toString"], [undefined, undefined]]) {
    assert.equal(statusTone(kind, value), "neutral");
  }
});

test("isPaymentOverdue starts the day after the due date, and only while unpaid", async () => {
  const { isPaymentOverdue } = await load(STATUS);
  const unpaid = { payment_status: "unpaid", payment_due_date: "2026-09-05" };
  // docs/requirements.md 16.2: the due date itself is still in time.
  assert.equal(isPaymentOverdue(unpaid, "2026-09-04"), false);
  assert.equal(isPaymentOverdue(unpaid, "2026-09-05"), false);
  assert.equal(isPaymentOverdue(unpaid, "2026-09-06"), true);
  assert.equal(isPaymentOverdue({ ...unpaid, payment_due_date: "2026-12-31" }, "2027-01-01"), true);
  // Paid charges are never overdue, whatever the date.
  assert.equal(isPaymentOverdue({ payment_status: "paid", payment_due_date: "2026-09-05" }, "2026-12-01"), false);
  // Missing or malformed input must not report an overdue payment.
  for (const charge of [null, undefined, {}, { payment_status: "unpaid" },
    { payment_status: "unpaid", payment_due_date: null },
    { payment_status: "unpaid", payment_due_date: "2026/09/05" },
    { payment_status: "unpaid", payment_due_date: 20260905 }]) {
    assert.equal(isPaymentOverdue(charge, "2026-12-01"), false);
  }
  for (const today of [null, undefined, "", "2026/12/01", 20261201]) {
    assert.equal(isPaymentOverdue(unpaid, today), false);
  }
});

/* -------------------------------------------------------------- messages.js */

test("errorMessage falls back for unknown codes and never prints the code", async () => {
  const { errorMessage, ERROR_MESSAGES } = await load(MESSAGES);
  const fallback = errorMessage("no-such-code-from-a-future-release");
  assert.equal(fallback, "処理できませんでした。時間をおいて、もう一度お試しください。");
  for (const code of [null, undefined, "", "  ".trim(), 404, {}, "toString", "constructor"]) {
    assert.equal(errorMessage(code), fallback);
  }
  assert.equal(errorMessage("capacity-full"), ERROR_MESSAGES["capacity-full"]);
  assert.equal(errorMessage("forbidden"), ERROR_MESSAGES.forbidden);
  // docs/coding_rules.md 4章: the code itself must never reach the screen.
  for (const [code, message] of Object.entries(ERROR_MESSAGES)) {
    assert.ok(message.length > 0 && !message.includes(code), `${code} leaks its code`);
    assert.ok(!/[a-z]+-[a-z]+/.test(message), `${code} leaks an internal identifier`);
  }
});

test("FIELD_LABELS keys are form names, never database columns", async () => {
  const { fieldLabel, FIELD_LABELS } = await load(MESSAGES);
  const { FIELD_NAMES } = await load(CONTRACT);
  // fieldErrors is keyed by the form name, so every form name needs a label.
  for (const name of Object.keys(FIELD_NAMES)) {
    assert.ok(FIELD_LABELS[name], `${name} (docs/routes.md 9.5) has no label`);
    assert.equal(fieldLabel(name), FIELD_LABELS[name]);
  }
  // The DB column names (snake_case) must not be usable as keys: showing them
  // would put internal identifiers on the screen.
  for (const column of Object.values(FIELD_NAMES)) {
    assert.equal(FIELD_LABELS[column], undefined, `${column} is a DB column, not a form name`);
  }
  for (const name of Object.keys(FIELD_LABELS)) {
    assert.ok(!name.includes("_"), `${name} looks like a DB column`);
  }
  assert.equal(fieldLabel("applicantName"), "氏名");
  assert.equal(fieldLabel("startDate"), "使用開始日");
  for (const name of [null, undefined, "", 1, "user_name", "unknownField"]) {
    assert.equal(fieldLabel(name), "入力項目");
  }
});

/* ------------------------------------------------------------- mock-data.js */

test("mock rooms match the facility master: 8 rooms for 15 people", async () => {
  const { MOCK_ROOMS, findMockRoom } = await load(MOCK);
  const { isUuid } = await load(CONTRACT);
  assert.equal(MOCK_ROOMS.length, 8); // docs/database.md 5.5
  assert.equal(sum(MOCK_ROOMS.map((room) => room.capacity)), 15);
  assert.equal(new Set(MOCK_ROOMS.map((room) => room.id)).size, 8);
  assert.equal(new Set(MOCK_ROOMS.map((room) => room.name)).size, 8);
  for (const room of MOCK_ROOMS) {
    assert.ok(isUuid(room.id), `${room.name} has an id the backend would reject`);
    assert.ok(Number.isInteger(room.capacity) && room.capacity > 0);
  }
  assert.equal(findMockRoom(MOCK_ROOMS[0].id), MOCK_ROOMS[0]);
  for (const id of ["00000000-0000-4000-8000-00000000dead", "", null, undefined]) {
    assert.equal(findMockRoom(id), null);
  }
});

test("ids, versions and contact details match the patterns the backend validates", async () => {
  const { MOCK_USER, MOCK_CAMP, MOCK_APPLICATIONS, MOCK_APPLICATION_LIST, findMockApplication } = await load(MOCK);
  const { isUuid, isUpdatedAt } = await load(CONTRACT);
  assert.ok(isUuid(MOCK_USER.id) && isUuid(MOCK_CAMP.id));
  assert.ok(isUpdatedAt(MOCK_CAMP.application_deadline));
  const timestamps = [];
  for (const application of MOCK_APPLICATIONS) {
    assert.ok(isUuid(application.id));
    // updated_at goes straight into a hidden input, so it keeps its microseconds.
    assert.match(application.updated_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}[+-]\d{2}:\d{2}$/);
    timestamps.push(application.updated_at, application.submitted_at, application.last_submitted_at,
      application.revision_due_at, ...application.events.map((event) => event.occurred_at));
    if (application.room_allocation) assert.ok(isUuid(application.room_allocation.room_id));
    if (application.camp_id !== null) assert.equal(application.camp_id, MOCK_CAMP.id);
    if (application.reception_number !== null) assert.match(application.reception_number, /^SG-\d{4}-\d{4}$/);
    assert.equal(findMockApplication(application.id), application);
  }
  for (const value of timestamps.filter((value) => value !== null)) {
    assert.ok(isUpdatedAt(value), `${value} would fail isUpdatedAt()`);
  }
  assert.equal(findMockApplication("11111111-1111-4111-8111-1111111119999"), null);
  assert.equal(findMockApplication(undefined), null);
  assert.equal(new Set(MOCK_APPLICATION_LIST.map((row) => row.id)).size, MOCK_APPLICATIONS.length);
  // No real personal data: reserved domain, non-existent phone numbers, fictional names.
  assert.match(MOCK_USER.email, /@example\.com$/);
  for (const phone of [MOCK_USER.phone, MOCK_USER.emergency_phone]) assert.match(phone, /^000-/);
  for (const name of [MOCK_USER.full_name, MOCK_USER.emergency_name]) assert.match(name, /（架空）$/);
});

test("mock charges follow min(days × 300, 9,000) and add up to their totals", async () => {
  const { MOCK_APPLICATIONS } = await load(MOCK);
  const { countStayDays } = await load(FORMAT);
  let checked = 0;
  for (const application of MOCK_APPLICATIONS) {
    const groups = [
      [application.estimated_months, application.fields.start_date, application.fields.end_date],
      [application.charge?.months ?? [], application.reserved_start_date, application.reserved_end_date],
    ];
    for (const [months, startDate, endDate] of groups) {
      if (months.length === 0) continue;
      checked += 1;
      for (const month of months) {
        assert.equal(month.daily_rate, 300); // docs/requirements.md 16.1
        assert.equal(month.monthly_cap, 9000);
        assert.equal(month.amount, Math.min(month.usage_days * month.daily_rate, month.monthly_cap));
        assert.match(month.month, /^\d{4}-\d{2}-01$/); // charge_months.month は各月1日
      }
      // The per-month day counts must add up to the stay they were calculated from.
      assert.equal(sum(months.map((month) => month.usage_days)), countStayDays(startDate, endDate));
    }
  }
  // 下書きの見込・修正候補の見込・修正依頼中の確定額・許可済みの確定額
  assert.equal(checked, 4);
  const approved = MOCK_APPLICATIONS[2];
  assert.equal(approved.charge.total_amount, sum(approved.charge.months.map((month) => month.amount)));
  assert.equal(approved.charge.total_amount, 9600); // 8月分5,100円 + 9月分4,500円
  assert.equal(MOCK_APPLICATIONS[1].charge.total_amount, sum(MOCK_APPLICATIONS[1].charge.months.map((month) => month.amount)));
  assert.equal(MOCK_APPLICATIONS[0].charge, null); // 下書きは確定額を持たない
});

test("the list mirrors the applications columns; only the revision case differs from fields", async () => {
  const { MOCK_APPLICATIONS, MOCK_APPLICATION_LIST } = await load(MOCK);
  assert.equal(MOCK_APPLICATION_LIST.length, MOCK_APPLICATIONS.length);
  for (const row of MOCK_APPLICATION_LIST) {
    // getCommunityApplications() の返却列 + 区分表示用の usage_type だけを持つ。
    assert.deepEqual(Object.keys(row), ["id", "status", "start_date", "end_date", "updated_at",
      "submitted_at", "last_submitted_at", "revision_due_at", "decision_reason", "usage_type"]);
  }
  for (const [index, row] of MOCK_APPLICATION_LIST.entries()) {
    const application = MOCK_APPLICATIONS[index];
    assert.equal(row.id, application.id);
    assert.equal(row.status, application.status);
    // 一覧は applications の列、詳細の fields は coalesce(revision_start_date, start_date)。
    // 提出前は revision_start_date も null なので、両者は fields と一致する。
    const reserved = application.reserved_start_date !== null;
    assert.equal(row.start_date, reserved ? application.reserved_start_date : application.fields.start_date);
    assert.equal(row.end_date, reserved ? application.reserved_end_date : application.fields.end_date);
  }
  // 修正依頼中の2件目だけが、意図的に fields と食い違う唯一の例。
  const differs = MOCK_APPLICATION_LIST.filter((row, index) =>
    row.start_date !== MOCK_APPLICATIONS[index].fields.start_date);
  assert.equal(differs.length, 1);
  assert.equal(differs[0].status, "revision_requested");
  assert.deepEqual([differs[0].start_date, differs[0].end_date], ["2026-10-10", "2026-10-12"]);
  assert.deepEqual([MOCK_APPLICATIONS[1].fields.start_date, MOCK_APPLICATIONS[1].fields.end_date],
    ["2026-10-11", "2026-10-13"]);
});

test("mock statuses and payment dates work with the label and format helpers", async () => {
  const { MOCK_APPLICATIONS, MOCK_APPLICATION_LIST } = await load(MOCK);
  const { statusLabel, isPaymentOverdue } = await load(STATUS);
  const { formatPeriod, formatYen, formatDeadline } = await load(FORMAT);
  for (const row of MOCK_APPLICATION_LIST) {
    assert.notEqual(statusLabel("application", row.status), "状態不明");
    assert.notEqual(formatPeriod(row.start_date, row.end_date), "未定");
  }
  const revision = MOCK_APPLICATIONS[1];
  assert.equal(statusLabel("application", revision.status), "修正依頼");
  assert.equal(statusLabel("payment", revision.charge.payment_status), "未納");
  // 期限超過は表示だけ: 納付状態は「未納」のまま変わらない。
  assert.equal(isPaymentOverdue(revision.charge, "2026-09-05"), false);
  assert.equal(isPaymentOverdue(revision.charge, "2026-09-06"), true);
  assert.equal(statusLabel("payment", revision.charge.payment_status), "未納");
  assert.equal(formatYen(revision.charge.total_amount), "900円");
  assert.equal(formatDeadline(revision.revision_due_at), "2026年9月30日 23:59");
  const approved = MOCK_APPLICATIONS[2];
  assert.equal(statusLabel("stay", approved.stay.status), "入居前");
  assert.equal(isPaymentOverdue(approved.charge, "2027-01-01"), false); // 納付済み
  assert.equal(formatYen(approved.charge.total_amount), "9,600円");
});
