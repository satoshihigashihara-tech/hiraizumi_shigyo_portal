// Run: node --experimental-vm-modules --test tests/community-applications-actions.test.mjs
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
const EXTENSION_ID = "10000000-0000-4000-8000-000000000005";
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

const ACTIONS = [
 ["app/actions/community-applications.js", "createCommunityApplicationDraft", "create_community_application_draft", SAVED],
 ["app/actions/community-applications.js", "saveCommunityApplicationDraft", "save_community_application_draft", SAVED],
 ["app/actions/community-applications.js", "submitCommunityApplication", "submit_community_application", SUBMITTED],
 ["app/actions/community-applications.js", "requestCommunityApplicationCancellation", "request_community_application_cancellation",
  [{ ...SAVED[0], result_status: "cancellation_requested" }]],
 ...[["startCommunityApplicationReview", "under_review"], ["requestCommunityApplicationRevision", "revision_requested"], ["rejectCommunityApplication", "rejected"]]
  .map(([action, status]) => ["app/actions/staff-community-applications.js", action, "review_community_application", [{ ...SAVED[0], result_status: status }]]),
 ["app/actions/staff-community-applications.js", "confirmCommunityApplicationCancellation", "confirm_community_application_cancellation",
  [{ ...SAVED[0], result_status: "cancelled" }]],
];
for (const [file, action, rpc, data] of ACTIONS) {
 test(`${action} guards first, sends exact version, refreshes then redirects`, async () => {
  const { api, calls } = await harness(file, { response: { data } });
  await assert.rejects(api[action](form()), /REDIRECT/);
  assert.equal(calls[0][0], "auth");
  const invocation = calls.find(c => c[0] === "rpc");
  assert.equal(invocation[1], rpc); assert.equal(invocation[2].target_application_id, ID);
  if (!action.startsWith("create")) assert.equal(invocation[2].expected_updated_at, VERSION);
  assert.ok(calls.some(c => c[0] === "revalidate" && c[1] === "/calendar"));
  assert.ok(calls.some(c => c[0] === "revalidate" && c[1] === "/staff/calendar"));
  assert.equal(calls.at(-1)[0], "redirect");
 });
 test(`${action} cannot reach input/DB without authorization`, async () => {
  const { api, calls, authError } = await harness(file, { denied: true });
  await assert.rejects(api[action](null), e => e === authError); assert.equal(calls.length, 1);
 });
 test(`${action} never redirects on errors and preserves fields without internal details`, async () => {
  const { api, calls } = await harness(file, { response: { error: { code: "P0001", message: "capacity-full", details: "PRIVATE" } } });
  const result = copy(await api[action](form()));
  assert.equal(result.error, "capacity-full"); assert.equal(result.fields.applicationId, ID);
  assert.ok(!JSON.stringify(result).includes("PRIVATE"));
  assert.equal(calls.filter(c => c[0] === "rpc").length, 1);
  assert.ok(!calls.some(c => ["redirect", "revalidate"].includes(c[0])));
 });
}
test("only approved community application actions are exported", async () => {
 for (const file of ["app/actions/community-applications.js", "app/actions/staff-community-applications.js"]) {
  const { api } = await harness(file);
  const extra = file.includes("staff-community") ? ["assignCommunityApplicationRoom", "approveCommunityApplication"]
    : ["createCommunityApplicationExtension"];
  assert.deepEqual(Object.keys(api).sort(), [...ACTIONS.filter(a => a[0] === file).map(a => a[1]), ...extra].sort());
 }
});
test("cancellation actions send only normalized reason and concurrency fields", async () => {
 for (const [file, action, rpc, reasonKey] of [
  ["app/actions/community-applications.js", "requestCommunityApplicationCancellation", "request_community_application_cancellation", "cancellation_reason"],
  ["app/actions/staff-community-applications.js", "confirmCommunityApplicationCancellation", "confirm_community_application_cancellation", "confirmation_reason"],
 ]) {
  const status = action.startsWith("request") ? "cancellation_requested" : "cancelled";
  const { api, calls } = await harness(file, { response: { data: [{ ...SAVED[0], result_status: status }] } });
  await assert.rejects(api[action](form({ reason: "  架空の取消理由  ", status: "cancelled", userId: OTHER_ID })), /REDIRECT/);
  assert.deepEqual(calls.find((call) => call[0] === "rpc").slice(1), [rpc, {
    target_application_id: ID, expected_updated_at: VERSION, [reasonKey]: "架空の取消理由",
  }]);
 }
});
test("cancellation actions reject missing or oversized reasons before RPC", async () => {
 for (const [file, action] of [["app/actions/community-applications.js", "requestCommunityApplicationCancellation"],
  ["app/actions/staff-community-applications.js", "confirmCommunityApplicationCancellation"]]) {
  for (const [reason, expected] of [["   ", "reason-required"], ["あ".repeat(2001), "reason-too-long"]]) {
   const { api, calls } = await harness(file);
   assert.equal((await api[action](form({ reason }))).error, expected);
   assert.equal(calls.filter((call) => call[0] === "rpc").length, 0);
  }
 }
});
test("extension creation sends only its link, end date and normalized reason", async () => {
 const { api, calls } = await harness("app/actions/community-applications.js", {
  response: { data: [{ result_id: EXTENSION_ID, result_updated_at: VERSION }] },
 });
 await assert.rejects(api.createCommunityApplicationExtension(form({ extensionId: EXTENSION_ID,
  originalApplicationId: ID, endDate: "2028-03-04", reason: "  架空の継続理由  ", status: "approved" })), /REDIRECT/);
 assert.deepEqual(calls.find((call) => call[0] === "rpc").slice(1), ["create_community_application_extension", {
  target_extension_id: EXTENSION_ID, target_original_application_id: ID,
  target_end_date: "2028-03-04", extension_reason_value: "架空の継続理由",
 }]);
 assert.equal(calls.at(-1)[1], `/user/applications/${EXTENSION_ID}/edit?created=extension`);
});
test("extension creation validates IDs, date and reason before RPC", async () => {
 for (const [fields, expected] of [[{ extensionId: "bad" }, "invalid-application"],
  [{ originalApplicationId: "bad" }, "invalid-application"], [{ endDate: "2028-02-30" }, "invalid-extension-period"],
  [{ reason: "   " }, "reason-required"], [{ reason: "あ".repeat(2001) }, "reason-too-long"]]) {
  const { api, calls } = await harness("app/actions/community-applications.js");
  assert.equal((await api.createCommunityApplicationExtension(form({ extensionId: EXTENSION_ID,
   originalApplicationId: ID, endDate: "2028-03-04", reason: "架空理由", ...fields }))).error, expected);
  assert.equal(calls.filter((call) => call[0] === "rpc").length, 0);
 }
});
test("empty creation preserves profile defaults, explicit empty fields clear them", async () => {
 for (const extra of [{}, { applicantName: "" }]) {
  const { api, calls } = await harness("app/actions/community-applications.js");
  await assert.rejects(api.createCommunityApplicationDraft(new Map(Object.entries({ applicationId: ID, ...extra }))), /REDIRECT/);
  assert.deepEqual(calls.find(c => c[0] === "rpc")[2].draft_fields, Object.hasOwn(extra, "applicantName") ? { user_name: null } : {});
 }
});
test("save maps only editable inputs; forged owner, fee, status, camp and email are discarded", async () => {
 const { api, calls } = await harness("app/actions/community-applications.js");
 await assert.rejects(api.saveCommunityApplicationDraft(form({ user_id: OTHER_ID, amount: "0", status: "approved", campId: OTHER_ID, email: "fake@example.invalid", intent: "confirm" })), /REDIRECT/);
 const f = calls.find(c => c[0] === "rpc")[2].draft_fields;
 assert.equal(f.local_activity, FORM.localActivity); assert.equal(f.requires_guardian_consent, false);
 for (const key of ["user_id", "status", "amount", "camp_id", "email"]) assert.ok(!Object.hasOwn(f, key));
 assert.equal(calls.at(-1)[1], `/user/applications/${ID}/confirm`);
});
test("submission trusts saved DB state and sends only ID, version, retry key and confirmation", async () => {
 const { api, calls } = await harness("app/actions/community-applications.js", { response: { data: SUBMITTED } });
 await assert.rejects(api.submitCommunityApplication(form({ startDate: "0000-01-01", totalAmount: "1" })), /REDIRECT/);
 assert.deepEqual(calls.find(c => c[0] === "rpc")[2], { target_application_id: ID, expected_updated_at: VERSION, submission_key: KEY, confirmed: true });
 assert.equal(calls.at(-1)[1], `/user/applications/${ID}/complete`);
});
for (const [fields, expected] of [[{ applicationId: "bad" }, "invalid-application"], [{ updatedAt: "" }, "invalid-version"],
 [{ updatedAt: "2026-02-30T00:00:00Z" }, "invalid-version"], [{ updatedAt: "2026-09-10T00:00:00" }, "invalid-version"],
 [{ submissionKey: "bad" }, "invalid-submission-key"], [{ confirmed: "" }, "confirmation-required"], [{ confirmed: "false" }, "confirmation-required"]]) {
 test(`submit rejects ${JSON.stringify(fields)} without RPC`, async () => {
  const { api, calls } = await harness("app/actions/community-applications.js");
  assert.equal((await api.submitCommunityApplication(form(fields))).error, expected);
  assert.equal(calls.length, 1);
 });
}
test("same RPC error 40001/40P01 becomes stale-update without automatic replay", async () => {
 for (const code of ["40001", "40P01"]) {
  const { api, calls } = await harness("app/actions/community-applications.js", { response: { error: { code, message: "PRIVATE" } } });
  assert.equal((await api.submitCommunityApplication(form())).error, "stale-update");
  assert.equal(calls.filter(c => c[0] === "rpc").length, 1);
 }
});
test("invalid DB success payloads never redirect", async () => {
 for (const data of [null, [], [{ ...SUBMITTED[0], result_id: OTHER_ID }], [{ ...SUBMITTED[0], result_updated_at: "bad" }],
  [{ ...SUBMITTED[0], reception_number: "private" }], [{ ...SUBMITTED[0], submission_time: "bad" }]]) {
  const { api, calls } = await harness("app/actions/community-applications.js", { response: { data } });
  assert.equal((await api.submitCommunityApplication(form())).error, "update-failed");
  assert.ok(!calls.some(c => c[0] === "redirect"));
 }
});
test("optional individual revision deadline converts JST without supplying a default", async () => {
 for (const [value, expected] of [["", null], ["2028-02-28T23:59", "2028-02-28T15:00:00.000Z"]]) {
  const { api, calls } = await harness("app/actions/staff-community-applications.js", { response: { data: [{ ...SAVED[0], result_status: "revision_requested" }] } });
  await assert.rejects(api.requestCommunityApplicationRevision(form({ revisionDeadline: value })), /REDIRECT/);
  assert.equal(calls.find(c => c[0] === "rpc")[2].revision_deadline, expected);
 }
});
test("staff requires reasons and valid optional deadline", async () => {
 for (const [fields, expected] of [[{ reason: "" }, "reason-required"], [{ reason: "あ".repeat(2001) }, "reason-too-long"], [{ revisionDeadline: "2028-02-30T00:00" }, "invalid-deadline"]]) {
  const { api, calls } = await harness("app/actions/staff-community-applications.js");
  assert.equal((await api.requestCommunityApplicationRevision(form(fields))).error, expected); assert.equal(calls.length, 1);
 }
});
test("structural validation includes inclusive dates, leap day, unicode and bool", async () => {
 const { api } = await harness("utils/community-applications/validation.js");
 assert.deepEqual(copy(api.validateFields(FORM)), {});
 for (const fields of [{ startDate: "2028-02-30" }, { endDate: FORM.startDate }, { endDate: "2028-03-15" },
  { guardianConsentRequired: "maybe" }, { usagePlace: "whole_facility" }, { applicantPhone: "abc" }, { localActivity: "あ".repeat(2001) }])
  assert.ok(Object.keys(api.validateFields({ ...FORM, ...fields })).length > 0);
 assert.deepEqual(copy(api.validateFields({ ...FORM, endDate: "2028-03-14", applicantName: "😀".repeat(100) })), {});
 assert.equal(api.validateFields({ ...FORM, localActivity: "" }, true).localActivity, "required-fields");
});
const DETAIL = { id: ID, status: "draft", updated_at: VERSION, fields: { user_name: "架空利用者", secret: "PRIVATE" }, can_edit: true,
 events: [{ to_status: "draft", actor_user_id: "PRIVATE" }], estimated_months: [{ month: "2028-02-01", amount: 300, internal: "PRIVATE" }],
 charge: { total_amount: 600, months: [], id: "PRIVATE" }, last_submission_key: "PRIVATE", object_path: "PRIVATE" };
test("owner read is guarded, read-only and strips internal fields from all nested objects", async () => {
 const { api, calls } = await harness("utils/community-applications/queries.js", { response: { data: DETAIL } });
 const result = copy(await api.getCommunityApplication(ID));
 assert.equal(result.error, null); assert.equal(result.application.fields.user_name, "架空利用者");
 assert.ok(!JSON.stringify(result).includes("PRIVATE"));
 assert.deepEqual(calls.map(c => c[0]), ["auth", "rpc"]);
});
test("read modes handle draft completion, expired revisions, and confirmation races", async () => {
 for (const [mode, extra, expected] of [["complete", {}, "not-submittable"], ["edit", { can_edit: false, status: "submitted" }, "not-editable"],
  ["edit", { can_edit: false, status: "revision_requested" }, "revision-expired"], ["confirm", { validation_error: "capacity-full" }, "capacity-full"],
  ["complete", { submitted_at: VERSION, reception_number: "SG-2026-0001" }, null]]) {
  const { api } = await harness("utils/community-applications/queries.js", { response: { data: { ...DETAIL, ...extra } } });
  assert.equal((await api.getCommunityApplication(ID, mode)).error, expected);
 }
});
test("owner list explicitly scopes user/type, paginates and returns fixed columns", async () => {
 const { api, calls } = await harness("utils/community-applications/queries.js", { response: { data: [{ id: ID, address: "PRIVATE" }] } });
 const result = await api.getCommunityApplications(2);
 assert.equal(result.error, null); assert.ok(!JSON.stringify(result).includes("PRIVATE"));
 assert.ok(calls.some(c => c[0] === "eq" && c[1] === "user_id" && c[2] === USER));
 assert.ok(calls.some(c => c[0] === "eq" && c[1] === "usage_type" && c[2] === "community_individual"));
 assert.deepEqual(calls.find(c => c[0] === "range"), ["range", 50, 99]);
});
test("cancellation context is guarded, fixed-field and read-only", async () => {
 const data = { id: ID, status: "approved", updated_at: VERSION, start_date: "2028-02-29", end_date: "2028-03-01",
  cancel_reason: null, stay_status: "before_move_in", can_request: true, can_confirm: false, private: "PRIVATE" };
 const { api, calls } = await harness("utils/community-applications/queries.js", { response: { data } });
 const result = copy(await api.getCommunityApplicationCancellation(ID));
 assert.equal(result.error, null); assert.equal(result.application.can_request, true);
 assert.ok(!JSON.stringify(result).includes("PRIVATE"));
 assert.deepEqual(calls.map((call) => call[0]), ["auth", "rpc"]);
});
test("extension source is guarded, fixed-field and read-only", async () => {
 const data = { id: ID, status: "approved", end_date: "2028-03-01", stay_status: "before_move_in",
  extension_start_date: "2028-03-02", existing_extension_id: null, can_extend: true, private: "PRIVATE" };
 const { api, calls } = await harness("utils/community-applications/queries.js", { response: { data } });
 const result = copy(await api.getCommunityApplicationExtensionSource(ID));
 assert.equal(result.error, null); assert.equal(result.application.can_extend, true);
 assert.ok(!JSON.stringify(result).includes("PRIVATE"));
 assert.deepEqual(calls.map((call) => call[0]), ["auth", "rpc"]);
});
test("owner reads guard before invalid arguments", async () => {
 for (const [name, argument] of [["getCommunityApplication", "bad"], ["getCommunityApplications", -1]]) {
  const { api, calls, authError } = await harness("utils/community-applications/queries.js", { denied: true });
  await assert.rejects(api[name](argument), e => e === authError); assert.equal(calls.length, 1);
 }
});
const PDF = new File(["%PDF-1.7\nfictional"], "consent.pdf", { type: "application/pdf" });
const CURRENT = { id: ID, usage_type: "community_individual", status: "revision_requested", updated_at: VERSION };
test("community consent upload uses owner guard and versioned service RPC; submitted old file survives", async () => {
 const { api, calls } = await harness("app/actions/guardian-consent.js", { readResponse: { data: CURRENT }, metadata: { data: [{ previous_object_path: "old", delete_previous: false, result_updated_at: VERSION }] } });
 await assert.rejects(api.uploadGuardianConsent(form({ guardianConsentFile: PDF })), /REDIRECT/);
 assert.equal(calls[0][0], "auth"); assert.ok(calls.some(c => c[0] === "eq" && c[1] === "user_id" && c[2] === USER));
 assert.equal(calls.find(c => c[0] === "admin-rpc")[1], "register_community_guardian_consent_document");
 assert.equal(calls.find(c => c[0] === "admin-rpc")[2].expected_updated_at, VERSION);
 assert.equal(calls.find(c => c[0] === "admin-rpc")[2].target_object_path, `applications/${ID}/${KEY}`);
 assert.ok(!calls.some(c => c[0] === "remove"));
});
test("consent stale failure removes only newly uploaded object", async () => {
 const { api, calls } = await harness("app/actions/guardian-consent.js", { readResponse: { data: CURRENT }, metadata: { error: { message: "stale-update" } } });
 await assert.rejects(api.uploadGuardianConsent(form({ guardianConsentFile: PDF })), e => e.url.endsWith("?error=stale-update"));
 assert.deepEqual(calls.filter(c => c[0] === "remove"), [["remove", `applications/${ID}/${KEY}`]]);
});
test("draft consent replacement removes old object only when DB authorizes it", async () => {
 const { api, calls } = await harness("app/actions/guardian-consent.js", { readResponse: { data: { ...CURRENT, status: "draft" } }, metadata: { data: [{ previous_object_path: "old", delete_previous: true, result_updated_at: VERSION }] } });
 await assert.rejects(api.uploadGuardianConsent(form({ guardianConsentFile: PDF })), /REDIRECT/);
 assert.deepEqual(calls.filter(c => c[0] === "remove"), [["remove", "old"]]);
});
test("legacy camp attachment RPC contract is preserved", async () => {
 const { api, calls } = await harness("app/actions/guardian-consent.js", { readResponse: { data: { ...CURRENT, usage_type: "camp", status: "draft" } }, metadata: { data: "old" } });
 await assert.rejects(api.uploadGuardianConsent(form({ guardianConsentFile: PDF, updatedAt: "" })), /REDIRECT/);
 const invocation = calls.find(c => c[0] === "admin-rpc");
 assert.equal(invocation[1], "register_guardian_consent_document"); assert.ok(!Object.hasOwn(invocation[2], "expected_updated_at"));
});
test("consent rejects disabled caller and invalid PDF before Storage", async () => {
 const denied = await harness("app/actions/guardian-consent.js", { denied: true });
 await assert.rejects(denied.api.uploadGuardianConsent(null), e => e === denied.authError); assert.equal(denied.calls.length, 1);
 const { api, calls } = await harness("app/actions/guardian-consent.js");
 await assert.rejects(api.uploadGuardianConsent(form({ guardianConsentFile: new File(["fake"], "a.pdf", { type: "application/pdf" }) })), e => e.url.endsWith("?error=invalid-content"));
 assert.ok(!calls.some(c => c[0] === "admin"));
});
test("missing community version and non-owner application cannot reach Storage", async () => {
 for (const [readResponse, updatedAt, expected] of [[{ data: CURRENT }, "", "invalid-version"], [{ data: null }, VERSION, "not-found"]]) {
  const { api, calls } = await harness("app/actions/guardian-consent.js", { readResponse });
  await assert.rejects(api.uploadGuardianConsent(form({ guardianConsentFile: PDF, updatedAt })), e => e.url.endsWith(`?error=${expected}`));
  assert.ok(!calls.some(c => c[0] === "admin"));
 }
});
test("signup and login retain community dates and reject external redirects", async () => {
 const target = "/user/applications/new/community-activity?start=2028-02-29&end=2028-03-01";
 for (const action of ["signUp", "login"]) {
  for (const [returnTo, destination] of [[target, target], ["https://example.invalid/steal", "/user"], ["//example.invalid", "/user"], ["/staff", "/forbidden"]]) {
   const { api } = await harness("app/actions/auth.js", { readResponse: { data: null } });
   await assert.rejects(api[action](new Map(Object.entries({ email: "fictional@example.invalid", password: "fictional-password", returnTo }))), e => e.url === destination);
  }
 }
 const { api } = await harness("app/actions/auth.js", { authResponse: { data: { session: null } } });
 await assert.rejects(api.signUp(new Map(Object.entries({ email: "fictional@example.invalid", password: "fictional-password", returnTo: target }))), e => new URL(e.url, "http://local").searchParams.get("returnTo") === target);
});
test("profile update invalidates community creation defaults", async () => {
 const { api, calls } = await harness("app/actions/profile.js", { readResponse: {} });
 await assert.rejects(api.saveProfile(new Map(Object.entries({ fullName: "架空利用者" }))), /REDIRECT/);
 assert.ok(calls.some(c => c[0] === "revalidate" && c[1] === "/user/applications/new/community-activity"));
});
