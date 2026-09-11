// Run: node --experimental-vm-modules --test tests/individual-room-allocations-actions.test.mjs
// Load the actual modules; replace only Next.js, auth and DB boundaries.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const ID = "10000000-0000-4000-8000-000000000001";
const OTHER_ID = "10000000-0000-4000-8000-000000000002";
const VERSION = "2026-09-10T12:34:56.123456+00:00";
const KEY = "10000000-0000-4000-8000-000000000003";
const USER = "10000000-0000-4000-8000-000000000004";
const SAVED = [{ result_id: ID, result_updated_at: VERSION }];
const SUBMITTED = [{ ...SAVED[0], result_status: "submitted", reception_number: "SG-2026-0001", submission_time: VERSION }];
const FORM = { applicationId: ID, updatedAt: VERSION, submissionKey: KEY, confirmed: "true",
 applicantName: "架空利用者", applicantAddress: "架空住所", applicantPhone: "000-0000-0000",
 emergencyContactName: "架空連絡先", emergencyContactAddress: "架空住所", emergencyContactPhone: "000-0000-0000",
 usagePurpose: "調査", localActivity: "町内で地域文化の調査", notes: "", usagePlace: "common_and_second_floor",
 guardianConsentRequired: "false", startDate: "2028-02-29", endDate: "2028-03-01", reason: "架空の修正理由" };
const copy = (value) => JSON.parse(JSON.stringify(value));
const form = (fields = {}) => new Map(Object.entries({ ...FORM, ...fields }));

async function harness(path, { response = { data: SAVED, error: null }, denied = false, readResponse = response, metadata = response, authResponse = { data: { session: {}, user: { id: USER } } } } = {}) {
  const calls = [];
  const context = vm.createContext({ URLSearchParams, URL, File, crypto: { randomUUID: () => KEY }, process: { env: { NEXT_PUBLIC_SUPABASE_URL: "https://example.invalid", SUPABASE_SECRET_KEY: "fictional-test-value" } } });
  const admin = {
    async rpc(name, args) { calls.push(["admin-rpc", name, copy(args)]); return metadata; },
    storage: { from(bucket) { calls.push(["storage", bucket]); return {
      async upload(path, bytes, options) { calls.push(["upload", path, bytes.byteLength, copy(options)]); return {}; },
      async remove(paths) { calls.push(["remove", ...paths]); return {}; },
      async createSignedUrl(path, ttl) { calls.push(["signed-url", path, ttl]); return { data: { signedUrl: "https://example.invalid/download" } }; },
    }; } },
  };
  const supabase = {
    auth: {
      async signUp(args) { calls.push(["signup", copy(args)]); return authResponse; },
      async signInWithPassword(args) { calls.push(["login", copy(args)]); return authResponse; },
      async getUser() { calls.push(["getUser"]); return authResponse; },
    },
    async rpc(name, args) { calls.push(["rpc", name, copy(args)]); return response; },
    from(table) {
      calls.push(["from", table]);
      return {
        select(columns) { calls.push(["select", columns]); return this; },
        eq(...args) { calls.push(["eq", ...args]); return this; },
        is(...args) { calls.push(["is", ...args]); return this; },
        update(args) { calls.push(["update", copy(args)]); return this; },
        order(...args) { calls.push(["order", ...args]); return this; },
        range(...args) { calls.push(["range", ...args]); return this; },
        then(resolve, reject) { return Promise.resolve(readResponse).then(resolve, reject); },
        async maybeSingle() { return readResponse; },
      };
    },
  };
  const authError = new Error("AUTH_REDIRECT");
  const stubs = {
    "server-only": {},
    "next/cache": { revalidatePath(...args) { calls.push(["revalidate", ...args]); } },
    "next/navigation": { redirect(url) { calls.push(["redirect", url]); throw Object.assign(new Error("REDIRECT"), { url }); } },
    "@/utils/auth/guards": {
      async requireActiveUser(path) { calls.push(["auth", "user", path]); if (denied) throw authError; return { supabase, user: { id: USER } }; },
      async requireStaff(path) { calls.push(["auth", "staff", path]); if (denied) throw authError; return { supabase, user: { id: USER } }; },
    },
    "@supabase/supabase-js": { createClient() { calls.push(["admin"]); return admin; } },
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


const CAMP = "20000000-0000-4000-8000-000000000001";
const ROOM = "20000000-0000-4000-8000-000000000002";
const STAFF_FORM = { applicationId: ID, updatedAt: VERSION, roomId: ROOM, reason: "部屋を変更する理由", approvalComment: "許可コメント" };
const actions = [
  ...[["startCommunityApplicationReview", "start_review", "under_review"], ["requestCommunityApplicationRevision", "request_revision", "revision_requested"],
    ["rejectCommunityApplication", "reject", "rejected"], ["assignCommunityApplicationRoom", "assign_room", "under_review"], ["approveCommunityApplication", "approve", "approved"]]
    .map(([name, operation, status]) => ({ file: "app/actions/staff-community-applications.js", name, operation, status, community: true })),
  ...[["startCampApplicationReview", "start_review", "under_review"], ["requestCampApplicationRevision", "request_revision", "revision_requested"],
    ["rejectCampApplication", "reject", "rejected"], ["assignCampApplicationRoom", "assign_room", "under_review"], ["approveCampApplication", "approve", "approved"]]
    .map(([name, operation, status]) => ({ file: "app/actions/staff-applications.js", name, operation, status, community: false })),
];
const staffForm = (fields = {}) => new Map(Object.entries({ ...STAFF_FORM, ...fields }));
for (const action of actions) {
 const data = [{ result_id: ID, result_camp_id: CAMP, result_status: action.status, result_updated_at: VERSION }];
 test(`${action.name}: authorized RPC contract, precise version and correct destination`, async () => {
  const { api, calls } = await harness(action.file, { response: { data }, readResponse: { data: { camp_id: CAMP } } });
  await assert.rejects(api[action.name](staffForm({ peopleCount: "99", startDate: "2099-01-01", status: "approved", staff: "true" })), /REDIRECT/);
  assert.deepEqual(calls[0].slice(0, 2), ["auth", "staff"]);
  const invocation = calls.find(c => c[0] === "rpc");
  assert.equal(invocation[1], action.operation === "assign_room" ? `assign_${action.community ? "community" : "camp"}_application_room` : `review_${action.community ? "community" : "camp"}_application`);
  assert.equal(invocation[2].expected_updated_at, VERSION);
  assert.equal(invocation[2].target_application_id, ID);
  for (const key of ["people_count", "start_date", "end_date", "status", "user_id"]) assert.ok(!Object.hasOwn(invocation[2], key));
  if (action.operation === "assign_room") {
   assert.equal(invocation[2].target_room_id, ROOM); assert.equal(invocation[2].change_reason, STAFF_FORM.reason);
  } else {
   assert.equal(invocation[2].review_action, action.operation);
   if (action.operation === "approve") assert.equal(invocation[2].public_reason, STAFF_FORM.approvalComment);
  }
  const path = action.community ? `/staff/community/applications/${ID}` : `/staff/camps/${CAMP}/applications/${ID}`;
  assert.equal(calls.at(-1)[1], `${path}?updated=${action.operation === "assign_room" ? "room-assigned" : action.status}`);
  for (const route of [path, "/staff", "/staff/calendar", `/user/applications/${ID}`, "/user/applications", "/user"])
   assert.ok(calls.some(c => c[0] === "revalidate" && c[1] === route));
 });
 test(`${action.name}: authorization fails before even parsing input`, async () => {
  const { api, calls, authError } = await harness(action.file, { denied: true });
  await assert.rejects(api[action.name](null), e => e === authError); assert.equal(calls.length, 1);
 });
 test(`${action.name}: stale/serialization errors never trigger retries or success refresh`, async () => {
  for (const error of [{ message: "stale-update" }, { code: "40001", message: "PRIVATE" }, { code: "40P01", message: "PRIVATE" }]) {
   const { api, calls } = await harness(action.file, { response: { error }, readResponse: { data: { camp_id: CAMP } } });
   if (action.community) {
    const result = copy(await api[action.name](staffForm()));
    assert.equal(result.error, "stale-update"); assert.equal(result.fields.updatedAt, VERSION);
    assert.equal(result.fields.roomId, ROOM); assert.equal(result.fields.approvalComment, STAFF_FORM.approvalComment);
    assert.ok(!JSON.stringify(result).includes("PRIVATE"));
   } else await assert.rejects(api[action.name](staffForm()), e => e.url.endsWith("?error=stale-update"));
   assert.equal(calls.filter(c => c[0] === "rpc").length, 1);
   assert.ok(!calls.some(c => c[0] === "revalidate"));
  }
 });
}
test("community first room/approval accepts optional reason/comment, ignores unrelated deadline", async () => {
 for (const [name, status] of [["assignCommunityApplicationRoom", "under_review"], ["approveCommunityApplication", "approved"]]) {
  const { api, calls } = await harness("app/actions/staff-community-applications.js", { response: { data: [{ ...SAVED[0], result_status: status }] } });
  await assert.rejects(api[name](staffForm({ reason: "", approvalComment: "", revisionDeadline: "invalid-unused-deadline" })), /REDIRECT/);
  const args = calls.find(c => c[0] === "rpc")[2];
  if (status === "approved") { assert.equal(args.public_reason, null); assert.equal(args.revision_deadline, null); }
  else assert.equal(args.change_reason, null);
 }
});
test("new community actions reject bad input without RPC and preserve field errors", async () => {
 for (const [name, fields, code, field] of [
  ["assignCommunityApplicationRoom", { roomId: "bad" }, "invalid-room", "roomId"],
  ["assignCommunityApplicationRoom", { applicationId: "bad" }, "invalid-application", null],
  ["assignCommunityApplicationRoom", { updatedAt: "2026-02-30T00:00:00Z" }, "invalid-version", "updatedAt"],
  ["assignCommunityApplicationRoom", { updatedAt: "" }, "invalid-version", "updatedAt"],
  ["assignCommunityApplicationRoom", { reason: "😀".repeat(2001) }, "reason-too-long", "reason"],
  ["approveCommunityApplication", { approvalComment: "😀".repeat(2001) }, "reason-too-long", "approvalComment"],
 ]) {
  const { api, calls } = await harness("app/actions/staff-community-applications.js");
  const result = copy(await api[name](staffForm(fields)));
  assert.equal(result.error, code); if (field) assert.equal(result.fieldErrors[field], code);
  assert.equal(calls.length, 1);
 }
});
test("room and approval error codes are safe and useful without SQL details", async () => {
 for (const code of ["room-required", "room-capacity-full", "facility-capacity-full", "capacity-full", "invalid-allocation", "invalid-stay", "stay-completed", "calendar-inconsistent", "application-inconsistent", "guardian-consent", "invalid-status", "invalid-room"]) {
  const { api, calls } = await harness("app/actions/staff-community-applications.js", { response: { error: { message: code, details: "PRIVATE", hint: "PRIVATE" } } });
  const result = copy(await api.approveCommunityApplication(staffForm()));
  assert.equal(result.error, code); assert.ok(!JSON.stringify(result).includes("PRIVATE"));
  assert.ok(!calls.some(c => ["redirect", "revalidate"].includes(c[0])));
 }
 for (const [error, code] of [[{ code: "42501", message: "PRIVATE" }, "forbidden"], [{ message: "PRIVATE" }, "update-failed"]]) {
  const { api } = await harness("app/actions/staff-community-applications.js", { response: { error } });
  assert.equal((await api.assignCommunityApplicationRoom(staffForm())).error, code);
 }
});
test("DB comment errors point at approvalComment, regardless of supplied room reason", async () => {
 const { api } = await harness("app/actions/staff-community-applications.js", { response: { error: { message: "reason-too-long" } } });
 const result = copy(await api.approveCommunityApplication(staffForm()));
 assert.deepEqual(result.fieldErrors, { approvalComment: "reason-too-long" });
});
test("new community actions reject wrong identities, states and versions in success payloads", async () => {
 for (const name of ["assignCommunityApplicationRoom", "approveCommunityApplication"]) {
  for (const data of [null, [], [{ ...SAVED[0], result_status: "submitted" }], [{ ...SAVED[0], result_id: OTHER_ID, result_status: "approved" }], [{ ...SAVED[0], result_updated_at: "bad", result_status: "approved" }]]) {
   const { api, calls } = await harness("app/actions/staff-community-applications.js", { response: { data } });
   assert.equal((await api[name](staffForm())).error, "update-failed");
   assert.ok(!calls.some(c => ["redirect", "revalidate"].includes(c[0])));
  }
 }
});
test("camp actions retain validation, error redirects and camp ID checks", async () => {
 for (const [fields, error] of [[{ roomId: "bad" }, "invalid-room"], [{ updatedAt: "" }, "invalid-version"], [{ reason: "あ".repeat(2001) }, "reason-too-long"]]) {
  const { api, calls } = await harness("app/actions/staff-applications.js", { readResponse: { data: { camp_id: CAMP } } });
  await assert.rejects(api.assignCampApplicationRoom(staffForm(fields)), e => e.url.endsWith(`?error=${error}`));
  assert.ok(!calls.some(c => c[0] === "rpc"));
 }
 const { api, calls } = await harness("app/actions/staff-applications.js", { readResponse: { data: { camp_id: null } } });
 await assert.rejects(api.approveCampApplication(staffForm()), e => e.url === "/staff?error=not-found");
 assert.ok(!calls.some(c => c[0] === "rpc"));
});
const ROOM_DATA = { room_id: ROOM, room_name: "桐", people_count: 1, start_date: "2028-02-29", end_date: "2028-03-01", released_from: null, is_current: true, reason: "PRIVATE" };
const STAY_DATA = { status: "before_move_in", checked_in_at: null, checked_out_at: null, id: "PRIVATE" };
const CONTEXT = { id: ID, status: "approved", updated_at: VERSION, fields: {}, approval_comment: "許可コメント",
 room_allocation: ROOM_DATA, stay: STAY_DATA, rooms: [{ id: ROOM, name: "桐", capacity: 1, internal: "PRIVATE" }], audit_logs: "PRIVATE" };
test("owner and staff result reads whitelist nested room and stay fields without mutations", async () => {
 for (const name of ["getCommunityApplication", "getStaffCommunityApplicationRoomContext"]) {
  const { api, calls } = await harness("utils/community-applications/queries.js", { response: { data: CONTEXT } });
  const result = copy(await api[name](ID));
  assert.equal(result.error, null); assert.equal(result.application.room_allocation.room_id, ROOM);
  assert.equal(result.application.stay.status, "before_move_in"); assert.equal(result.application.approval_comment, "許可コメント");
  assert.ok(!JSON.stringify(result).includes("PRIVATE"));
  assert.deepEqual(calls.map(c => c[0]), ["auth", "rpc"]);
  assert.equal(calls[0][1], name.startsWith("getStaff") ? "staff" : "user");
 }
});
test("staff context is guarded before validation and handles missing/malformed results", async () => {
 const denied = await harness("utils/community-applications/queries.js", { denied: true });
 await assert.rejects(denied.api.getStaffCommunityApplicationRoomContext(null), e => e === denied.authError);
 assert.equal(denied.calls.length, 1);
 for (const response of [{ data: null }, { data: { ...CONTEXT, id: OTHER_ID } }, { data: { ...CONTEXT, rooms: null } }, { error: { message: "PRIVATE" } }]) {
  const { api } = await harness("utils/community-applications/queries.js", { response });
  assert.equal((await api.getStaffCommunityApplicationRoomContext(ID)).error, "load-failed");
 }
});
