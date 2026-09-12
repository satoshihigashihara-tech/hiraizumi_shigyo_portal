// Run: node --experimental-vm-modules --test tests/community-groups-actions.test.mjs
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const ID = "10000000-0000-4000-8000-000000000001";
const OTHER_ID = "10000000-0000-4000-8000-000000000002";
const USER = "10000000-0000-4000-8000-000000000003";
const KEY = "10000000-0000-4000-8000-000000000004";
const VERSION = "2026-09-11T03:00:00.123456+00:00";
const SAVED = [{ result_id: ID, result_updated_at: VERSION }];
const STARTED = [{ ...SAVED[0], result_status: "collecting", reception_number: "SG-2026-0042",
  submission_time: VERSION, participant_due_at: "2026-09-19T15:00:00+00:00" }];
const FORM = { groupId: ID, updatedAt: VERSION, submissionKey: KEY, confirmed: "true", intent: "confirm",
  groupName: "架空地域研究会", representativeName: "架空代表者", representativeAddress: "架空住所",
  representativePhone: "000-0000-0000", startDate: "2026-10-01", endDate: "2026-10-03",
  usagePlace: "common_and_second_floor", purpose: "架空の地域調査", localActivity: "町内で架空の聞き取り",
  notes: "", plannedParticipants: "4", representativeStays: "false" };
const form = (fields = {}) => new Map(Object.entries({ ...FORM, ...fields }));
const copy = (value) => JSON.parse(JSON.stringify(value));

async function harness(path, { response = { data: SAVED, error: null }, denied = false, readResponse = response } = {}) {
  const calls = [];
  const context = vm.createContext({ URLSearchParams, URL, crypto: { randomUUID: () => KEY } });
  const supabase = {
    async rpc(name, args) { calls.push(["rpc", name, copy(args)]); return response; },
    from(table) { calls.push(["from", table]); return {
      select(columns) { calls.push(["select", columns]); return this; },
      eq(...args) { calls.push(["eq", ...args]); return this; },
      order(...args) { calls.push(["order", ...args]); return this; },
      range(...args) { calls.push(["range", ...args]); return this; },
      then(resolve, reject) { return Promise.resolve(readResponse).then(resolve, reject); },
    }; },
  };
  const authError = new Error("AUTH_REDIRECT");
  const stubs = {
    "server-only": {},
    "next/cache": { revalidatePath(pathname) { calls.push(["revalidate", pathname]); } },
    "next/navigation": { redirect(url) { calls.push(["redirect", url]); throw Object.assign(new Error("REDIRECT"), { url }); } },
    "@/utils/auth/guards": { async requireActiveUser(pathname) {
      calls.push(["auth", pathname]); if (denied) throw authError; return { supabase, user: { id: USER } };
    } },
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
    cache.set(specifier, loadedModule); await loadedModule.link(load); return loadedModule;
  }
  const loadedModule = await load(path); await loadedModule.evaluate();
  return { api: loadedModule.namespace, calls, authError };
}

for (const [action, rpc, data] of [
  ["createCommunityGroupDraft", "create_community_group_draft", SAVED],
  ["saveCommunityGroupDraft", "save_community_group_draft", SAVED],
  ["startCommunityGroupApplication", "start_community_group_application", STARTED],
]) {
  test(`${action} authorizes first, calls its RPC and redirects after refresh`, async () => {
    const { api, calls } = await harness("app/actions/community-groups.js", { response: { data, error: null } });
    await assert.rejects(api[action](form()), /REDIRECT/);
    assert.equal(calls[0][0], "auth");
    assert.equal(calls.find((call) => call[0] === "rpc")[1], rpc);
    assert.ok(calls.some((call) => call[0] === "revalidate" && call[1] === "/calendar"));
    assert.equal(calls.at(-1)[0], "redirect");
  });
  test(`${action} cannot parse inputs or call the DB when authorization fails`, async () => {
    const { api, calls, authError } = await harness("app/actions/community-groups.js", { denied: true });
    await assert.rejects(api[action](null), (error) => error === authError);
    assert.deepEqual(calls, [["auth", "/user/groups/new?mode=fieldwork"]]);
  });
}

test("save sends only the editable allowlist and discards forged ownership/status fields", async () => {
  const { api, calls } = await harness("app/actions/community-groups.js");
  await assert.rejects(api.saveCommunityGroupDraft(form({ representativeUserId: OTHER_ID, status: "approved",
    participantDueAt: VERSION, representativeEmail: "forged@example.invalid" })), /REDIRECT/);
  const input = calls.find((call) => call[0] === "rpc")[2];
  assert.equal(input.target_group_id, ID); assert.equal(input.expected_updated_at, VERSION);
  assert.equal(input.draft_fields.planned_participants, 4);
  assert.equal(input.draft_fields.representative_stays, false);
  for (const key of ["representative_user_id", "status", "participant_due_at", "representative_email"]) {
    assert.ok(!Object.hasOwn(input.draft_fields, key));
  }
});

test("empty creation preserves profile defaults; explicitly supplied empty values clear them", async () => {
  for (const extra of [{}, { representativeName: "" }]) {
    const { api, calls } = await harness("app/actions/community-groups.js");
    await assert.rejects(api.createCommunityGroupDraft(new Map(Object.entries({ groupId: ID, ...extra }))), /REDIRECT/);
    assert.deepEqual(calls.find((call) => call[0] === "rpc")[2].draft_fields,
      Object.hasOwn(extra, "representativeName") ? { representative_name: null } : {});
  }
});

test("start trusts saved DB state and sends only concurrency/idempotency fields", async () => {
  const { api, calls } = await harness("app/actions/community-groups.js", { response: { data: STARTED, error: null } });
  await assert.rejects(api.startCommunityGroupApplication(form({ groupName: "改ざん", status: "approved" })), /REDIRECT/);
  assert.deepEqual(calls.find((call) => call[0] === "rpc")[2], {
    target_group_id: ID, expected_updated_at: VERSION, submission_key: KEY, confirmed: true,
  });
  assert.equal(calls.at(-1)[1], `/user/groups/${ID}/complete?mode=fieldwork`);
});

test("representative cancellation requires a reason and calls the group cancellation RPC", async () => {
  const response = { data: [{ result_id: ID, result_status: "cancellation_requested", result_updated_at: VERSION }], error: null };
  const { api, calls } = await harness("app/actions/community-groups.js", { response });
  await assert.rejects(api.requestCommunityGroupCancellation(form({ reason: "架空の取消理由" })), /REDIRECT/);
  assert.deepEqual(calls.find((call) => call[0] === "rpc"), ["rpc", "request_community_group_cancellation", {
    target_group_id: ID, expected_updated_at: VERSION, cancellation_reason: "架空の取消理由",
  }]);
  const invalid = await harness("app/actions/community-groups.js");
  assert.equal((await invalid.api.requestCommunityGroupCancellation(form({ reason: "" }))).error, "reason-required");
});

test("representative cancellation requires explicit confirmation before RPC", async () => {
  const { api, calls } = await harness("app/actions/community-groups.js");
  const result = copy(await api.requestCommunityGroupCancellation(form({ confirmed: "false" })));
  assert.equal(result.error, "confirmation-required");
  assert.equal(calls.filter((call) => call[0] === "rpc").length, 0);
});

for (const [fields, expected] of [
  [{ groupId: "bad" }, "invalid-group"], [{ updatedAt: "" }, "invalid-version"],
  [{ submissionKey: "bad" }, "invalid-submission-key"], [{ confirmed: "false" }, "confirmation-required"],
]) {
  test(`start rejects ${expected} before RPC`, async () => {
    const { api, calls } = await harness("app/actions/community-groups.js");
    assert.equal((await api.startCommunityGroupApplication(form(fields))).error, expected);
    assert.equal(calls.filter((call) => call[0] === "rpc").length, 0);
  });
}

test("validation accepts boundaries and rejects invalid counts, dates, booleans and oversized text", async () => {
  const { api } = await harness("utils/community-groups/validation.js");
  assert.deepEqual(copy(api.validateGroupFields(FORM, true)), {});
  assert.equal(copy(api.validateGroupFields({ ...FORM, plannedParticipants: "1" })).plannedParticipants, "invalid-participant-count");
  assert.equal(copy(api.validateGroupFields({ ...FORM, plannedParticipants: "2.5" })).plannedParticipants, "invalid-participant-count");
  assert.equal(copy(api.validateGroupFields({ ...FORM, endDate: "2026-10-01" })).endDate, "invalid-duration");
  assert.equal(copy(api.validateGroupFields({ ...FORM, representativeStays: "maybe" })).representativeStays, "invalid-fields");
  assert.equal(copy(api.validateGroupFields({ ...FORM, groupName: "あ".repeat(121) })).groupName, "field-too-long");
});

test("DB failures expose only approved codes and never redirect", async () => {
  for (const [error, expected] of [[{ code: "P0001", message: "calendar-unavailable", details: "PRIVATE" }, "calendar-unavailable"],
    [{ code: "40001", message: "PRIVATE" }, "stale-update"], [{ code: "XX000", message: "PRIVATE" }, "update-failed"]]) {
    const { api, calls } = await harness("app/actions/community-groups.js", { response: { data: null, error } });
    const result = copy(await api.startCommunityGroupApplication(form()));
    assert.equal(result.error, expected); assert.ok(!JSON.stringify(result).includes("PRIVATE"));
    assert.ok(!calls.some((call) => call[0] === "redirect"));
  }
});

test("owner detail query returns only fixed fields and checks modes", async () => {
  const data = { id: ID, status: "draft", updated_at: VERSION, submitted_at: null, participant_due_at: null,
    reception_number: null, secret: "PRIVATE", fields: { group_name: "架空団体", representative_name: "架空代表", secret: "PRIVATE" },
    events: [{ from_status: null, to_status: "draft", public_reason: null, occurred_at: VERSION, actor_user_id: OTHER_ID }] };
  const { api } = await harness("utils/community-groups/queries.js", { response: { data, error: null } });
  const result = copy(await api.getCommunityGroup(ID, "edit"));
  assert.equal(result.error, null); assert.ok(!JSON.stringify(result).includes("PRIVATE"));
  assert.equal((await api.getCommunityGroup(ID, "bad")).error, "not-found");
});

test("group cancellation query strips internal fields", async () => {
  const data = { id: ID, group_name: "架空団体", status: "approved", updated_at: VERSION,
    start_date: "2026-10-01", end_date: "2026-10-03", cancel_reason: null,
    can_request: true, can_confirm: false, representative_address: "PRIVATE" };
  const { api } = await harness("utils/community-groups/queries.js", { response: { data, error: null } });
  const result = copy(await api.getCommunityGroupCancellation(ID));
  assert.equal(result.error, null); assert.ok(!JSON.stringify(result).includes("PRIVATE"));
});

test("owner list uses fixed projection, owner filter and bounded pagination", async () => {
  const readResponse = { data: [{ id: ID, group_name: "架空団体", status: "draft", secret: "PRIVATE" }], error: null };
  const { api, calls } = await harness("utils/community-groups/queries.js", { readResponse });
  const result = copy(await api.getCommunityGroups(2));
  assert.equal(result.error, null); assert.ok(!JSON.stringify(result).includes("PRIVATE"));
  assert.ok(calls.some((call) => call[0] === "eq" && call[1] === "representative_user_id" && call[2] === USER));
  assert.ok(calls.some((call) => call[0] === "range" && call[1] === 50 && call[2] === 99));
  assert.equal((await api.getCommunityGroups(0)).error, "invalid-page");
});
