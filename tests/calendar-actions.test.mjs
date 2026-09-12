// Run: node --experimental-vm-modules --test tests/calendar-actions.test.mjs
// Load the actual modules; replace only Next.js, auth and DB boundaries.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const ID = "10000000-0000-4000-8000-000000000001";
const OTHER_ID = "10000000-0000-4000-8000-000000000002";
const VERSION = "2026-09-10T12:34:56.123456+00:00";
const SAVED = [{ result_id: ID, result_updated_at: VERSION }];
const FORM = {
  campId: ID, blockedPeriodId: ID, campName: "テストキャンプ",
  startDate: "2028-02-29", endDate: "2028-03-03",
  applicationDeadline: "2028-02-28T23:59", updatedAt: VERSION,
  internalReason: "清掃", reason: "日程変更", confirmed: "true",
};
const copy = (value) => JSON.parse(JSON.stringify(value));
const form = (fields = {}) => new Map(Object.entries({ ...FORM, ...fields }));

async function harness(path, { response = { data: SAVED, error: null }, denied = false } = {}) {
  const calls = [];
  const context = vm.createContext({ URLSearchParams });
  const supabase = {
    async rpc(name, args) { calls.push(["rpc", name, copy(args)]); return response; },
    from(table) {
      calls.push(["from", table]);
      return {
        select(columns) { calls.push(["select", columns]); return this; },
        eq(...args) { calls.push(["eq", ...args]); return this; },
        is(...args) { calls.push(["is", ...args]); return this; },
        async maybeSingle() { return response; },
      };
    },
  };
  const authError = new Error("AUTH_REDIRECT");
  const stubs = {
    "server-only": {},
    "next/cache": { revalidatePath(...args) { calls.push(["revalidate", ...args]); } },
    "next/navigation": { redirect(url) { calls.push(["redirect", url]); throw Object.assign(new Error("REDIRECT"), { url }); } },
    "@/utils/auth/guards": { async requireStaff(path) {
      calls.push(["auth", path]); if (denied) throw authError; return { supabase };
    } },
    "@/utils/supabase/server": { async createClient() { calls.push(["client"]); return supabase; } },
  };
  const cache = new Map();
  async function load(specifier) {
    if (cache.has(specifier)) return cache.get(specifier);
    let loadedModule;
    if (Object.hasOwn(stubs, specifier)) {
      const values = stubs[specifier];
      loadedModule = new vm.SyntheticModule(Object.keys(values), function () {
        for (const [key, value] of Object.entries(values)) this.setExport(key, value);
      }, { context, identifier: specifier });
    } else {
      const filename = specifier.startsWith("@/") ? `${specifier.slice(2)}.js` : specifier;
      loadedModule = new vm.SourceTextModule(await readFile(new URL(filename, ROOT), "utf8"), { context, identifier: filename });
    }
    cache.set(specifier, loadedModule);
    await loadedModule.link(load);
    return loadedModule;
  }
  const loadedModule = await load(path);
  await loadedModule.evaluate();
  return { api: loadedModule.namespace, calls, authError };
}

const ACTIONS = [
  ["app/actions/staff-camps.js", "createStaffCamp", "create_staff_camp", ID],
  ["app/actions/staff-camps.js", "updateStaffCamp", "update_staff_camp", SAVED],
  ["app/actions/staff-camps.js", "deleteStaffCamp", "delete_staff_camp", SAVED],
  ["app/actions/staff-calendar.js", "createStaffBlockedPeriod", "save_staff_blocked_period", SAVED],
  ["app/actions/staff-calendar.js", "updateStaffBlockedPeriod", "save_staff_blocked_period", SAVED],
  ["app/actions/staff-calendar.js", "deleteStaffBlockedPeriod", "delete_staff_blocked_period", SAVED],
];

for (const [file, action, rpc, data] of ACTIONS) {
  test(`${action}: authorize, preserve RPC contract, refresh before redirect`, async () => {
    const { api, calls } = await harness(file, { response: { data, error: null } });
    await assert.rejects(api[action](form()), (error) => error.message === "REDIRECT");
    assert.equal(calls[0][0], "auth");
    const rpcCalls = calls.filter((c) => c[0] === "rpc");
    assert.equal(rpcCalls.length, 1);
    assert.equal(rpcCalls[0][1], rpc);
    const args = rpcCalls[0][2];
    if (!action.startsWith("create")) {
      assert.equal(args.expected_updated_at, VERSION);
      assert.equal(args.change_reason, FORM.reason);
    }
    if (args.camp_application_deadline) assert.equal(args.camp_application_deadline, "2028-02-28T15:00:00.000Z");
    assert.ok(calls.some((c) => c[0] === "revalidate" && c[1] === "/calendar"));
    assert.ok(calls.some((c) => c[0] === "revalidate" && c[1] === "/staff/calendar"));
    assert.equal(calls.at(-1)[0], "redirect");
  });
  test(`${action}: authorization failure precedes input handling and all DB calls`, async () => {
    const { api, calls, authError } = await harness(file, { denied: true });
    await assert.rejects(api[action](null), (error) => error === authError);
    assert.equal(calls.length, 1);
  });
}

test("updates reject missing/malformed versions without requesting fresh values or retrying", async () => {
  for (const updatedAt of ["", "2026-02-30T12:00:00Z", "2026-09-10T12:00:00", "2026-09-10T12:00:00.1234567Z"]) {
    for (const file of ["app/actions/staff-calendar.js", "app/actions/staff-camps.js"]) {
      const { api, calls } = await harness(file);
      const action = file.includes("staff-calendar") ? api.updateStaffBlockedPeriod : api.updateStaffCamp;
      assert.equal((await action(form({ updatedAt }))).error, "invalid-version");
      assert.equal(calls.length, 1);
    }
  }
});

test("period, name, minute deadline and Unicode reason limits reject invalid form input", async () => {
  for (const [fields, expected] of [
    [{ startDate: "2100-02-29" }, "invalid-period"],
    [{ endDate: "2028-02-28" }, "invalid-period"],
    [{ campName: " " }, "invalid-name"],
    [{ campName: "😀".repeat(121) }, "invalid-name"],
    [{ applicationDeadline: "2028-02-29T00:00" }, "invalid-deadline"],
    [{ applicationDeadline: "2028-02-28T23:60" }, "invalid-deadline"],
    [{ reason: "😀".repeat(2001) }, "reason-too-long"],
  ]) {
    const { api, calls } = await harness("app/actions/staff-camps.js");
    const result = await api.createStaffCamp(form(fields));
    assert.equal(result.error, expected);
    assert.equal(calls.length, 1);
    for (const [key, value] of Object.entries(fields)) assert.equal(result.fields[key], value.trim());
  }
  const { api } = await harness("utils/calendar/validation.js");
  assert.equal(api.reasonError("😀".repeat(2000)), null);
  assert.equal(api.toTokyoDeadline("2028-12-31T23:59"), "2028-12-31T15:00:00.000Z");
});

test("delete requires a reason; update leaves same-value no-op decision to DB", async () => {
  const { api, calls } = await harness("app/actions/staff-calendar.js");
  assert.equal((await api.deleteStaffBlockedPeriod(form({ reason: " " }))).error, "reason-required");
  assert.equal(calls.length, 1);
  await assert.rejects(api.updateStaffBlockedPeriod(form({ reason: "" })), /REDIRECT/);
  assert.equal(calls.find((c) => c[0] === "rpc")[2].change_reason, null);
});

test("blocked period delete requires explicit confirmation before RPC", async () => {
  const { api, calls } = await harness("app/actions/staff-calendar.js");
  const result = await api.deleteStaffBlockedPeriod(form({ confirmed: "" }));
  assert.equal(result.error, "confirmation-required");
  assert.equal(result.fieldErrors.confirmed, "confirmation-required");
  assert.equal(calls.length, 1);
});

test("DB failures retain fields, map concurrency safely and never auto-retry", async () => {
  for (const [error, expected] of [
    [{ code: "40001", message: "database internals" }, "stale-update"],
    [{ code: "40P01", message: "database internals" }, "stale-update"],
    [{ code: "42501", message: "private" }, "forbidden"],
    [{ message: "stale-update" }, "stale-update"],
    [{ message: "private SQL error", details: "private details" }, "update-failed"],
  ]) {
    const { api, calls } = await harness("app/actions/staff-calendar.js", { response: { data: null, error } });
    const result = copy(await api.updateStaffBlockedPeriod(form()));
    assert.equal(result.error, expected);
    assert.equal(result.fields.updatedAt, VERSION);
    assert.deepEqual(result.conflicts, []);
    assert.equal(calls.filter((c) => c[0] === "rpc").length, 1);
    assert.ok(!calls.some((c) => ["revalidate", "redirect"].includes(c[0])));
    assert.ok(!JSON.stringify(result).includes("private"));
  }
});

test("staff conflict details expose only the specified summary fields", async () => {
  const conflict = { type: "application", id: ID, campId: OTHER_ID, name: "架空利用者",
    receptionNumber: "TEST-001", status: "submitted", startDate: FORM.startDate, endDate: FORM.endDate };
  const error = { message: "date-conflict", details: JSON.stringify([
    { ...conflict, address: "private", phone: "private", email: "private", internal_reason: "private" },
    { ...conflict, id: "malformed" }, null,
  ]) };
  const { api } = await harness("app/actions/staff-camps.js", { response: { error } });
  assert.deepEqual(copy((await api.createStaffCamp(form())).conflicts), [conflict]);
});

test("unexpected RPC result identity or version cannot produce a success redirect", async () => {
  for (const data of [null, [], [{ result_id: OTHER_ID, result_updated_at: VERSION }], [{ result_id: ID, result_updated_at: "bad" }]]) {
    const { api, calls } = await harness("app/actions/staff-camps.js", { response: { data } });
    assert.equal((await api.updateStaffCamp(form())).error, "update-failed");
    assert.ok(!calls.some((c) => c[0] === "redirect"));
  }
});

test("eligible-email entry keeps normalization/deduplication and rechecks authorization", async () => {
  const { api, calls } = await harness("app/actions/staff-camps.js", { response: { data: 2 } });
  await assert.rejects(api.addCampEligibleUsers(form({ eligibleEmails: "A@example.invalid; a@example.invalid B@example.invalid" })), /REDIRECT/);
  assert.equal(calls[0][0], "auth");
  assert.deepEqual(calls.find((c) => c[0] === "rpc"), ["rpc", "add_camp_eligible_users", {
    target_camp_id: ID, eligible_emails: ["a@example.invalid", "b@example.invalid"],
  }]);
  assert.ok(calls.at(-1)[1].endsWith("?registered=2&duplicates=1"));
  const denied = await harness("app/actions/staff-camps.js", { denied: true });
  await assert.rejects(denied.api.addCampEligibleUsers(null), /AUTH_REDIRECT/);
});

const DAYS = Array.from({ length: 29 }, (_, i) => ({ date: `2028-02-${String(i + 1).padStart(2, "0")}`, availability: "available" }));
test("public month returns exactly date/availability without staff authorization", async () => {
  const data = DAYS.map((day) => ({ ...day, id: ID, name: "private", internal_reason: "private", count: 15 }));
  const { api, calls } = await harness("utils/calendar/queries.js", { response: { data } });
  assert.deepEqual(copy(await api.getPublicCalendar("2028-02")), { error: null, days: DAYS });
  assert.deepEqual(calls, [["client"], ["rpc", "get_public_calendar", { target_month: "2028-02-01" }]]);
});

test("public calendar rejects incomplete, duplicate, invalid or unordered responses", async () => {
  for (const data of [[], null, DAYS.slice(1), [...DAYS.slice(0, 28), DAYS[0]],
    [...DAYS.slice(0, 28), null], [...DAYS].reverse(), DAYS.map((d) => ({ ...d, availability: "private" }))]) {
    const { api } = await harness("utils/calendar/queries.js", { response: { data } });
    assert.deepEqual(copy(await api.getPublicCalendar("2028-02")), { error: "load-failed", days: [] });
  }
  const { api, calls } = await harness("utils/calendar/queries.js");
  assert.equal((await api.getPublicCalendar("0000-01")).error, "invalid-month");
  assert.equal(calls.length, 0);
});

for (const [name, argument] of [["getStaffCalendar", "bad"], ["getStaffCalendarDay", "bad"],
  ["getStaffBlockedPeriods", "bad"], ["getStaffBlockedPeriod", "bad"]]) {
  test(`${name}: requires staff even for invalid inputs`, async () => {
    const { api, calls, authError } = await harness("utils/calendar/queries.js", { denied: true });
    await assert.rejects(api[name](argument), (error) => error === authError);
    assert.equal(calls.length, 1);
  });
}

test("staff read shapes strip private fields and never call mutation or cache APIs", async () => {
  const row = { entry_type: "blocked", entry_id: ID, id: ID, start_date: FORM.startDate, end_date: FORM.endDate,
    internal_reason: "清掃", updated_at: VERSION, address: "private", phone: "private", emergency: "private" };
  const { api, calls } = await harness("utils/calendar/queries.js", { response: { data: [row] } });
  const month = copy(await api.getStaffCalendar("2028-02"));
  const day = copy(await api.getStaffCalendarDay("2028-02-29"));
  const blocked = copy(await api.getStaffBlockedPeriods("2028-02"));
  assert.deepEqual(Object.keys(month.entries[0]), ["entry_type", "entry_id", "start_date", "end_date", "title", "people_count", "internal_reason", "updated_at"]);
  assert.equal(day.entries[0].updated_at, VERSION);
  assert.deepEqual(blocked.periods, month.entries);
  assert.ok(!JSON.stringify([month, day, blocked]).includes("private"));
  assert.ok(calls.every((c) => c[0] === "auth" || c[0] === "rpc" && c[1].startsWith("get_")));
  const single = await harness("utils/calendar/queries.js", { response: { data: row } });
  const result = copy(await single.api.getStaffBlockedPeriod(ID));
  assert.deepEqual(Object.keys(result.period), ["id", "start_date", "end_date", "internal_reason", "updated_at"]);
  assert.ok(single.calls.some((c) => c[0] === "is" && c[1] === "deleted_at" && c[2] === null));
});

test("missing and failed blocked-period reads use stable error responses", async () => {
  for (const [response, expected] of [[{ data: null }, "not-found"], [{ error: { message: "private" } }, "load-failed"]]) {
    const { api } = await harness("utils/calendar/queries.js", { response });
    assert.deepEqual(copy(await api.getStaffBlockedPeriod(ID)), { error: expected, period: null });
  }
});

test("individual calendar entries preserve type/ID and strip contact information", async () => {
  const row = { entry_type: "individual", entry_id: ID, camp_id: null, start_date: FORM.startDate, end_date: FORM.endDate,
    title: "架空利用者", people_count: 1, updated_at: VERSION, status: "revision_requested", reception_number: "SG-2026-0001",
    display_name: "架空利用者", user_address: "private", user_phone: "private", object_path: "private" };
  const { api, calls } = await harness("utils/calendar/queries.js", { response: { data: [row] } });
  const month = await api.getStaffCalendar("2028-02");
  row.entry_type = "application";
  const day = await api.getStaffCalendarDay("2028-02-29");
  assert.equal(month.entries[0].entry_type, "individual");
  assert.equal(day.entries[0].entry_type, "application");
  assert.equal(day.entries[0].camp_id, null);
  assert.equal(day.entries[0].entry_id, ID);
  assert.ok(!JSON.stringify([month, day]).includes("private"));
  assert.ok(calls.every(c => c[0] === "auth" || c[0] === "rpc" && c[1].startsWith("get_")));
});
