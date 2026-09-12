import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const GROUP = "10000000-0000-4000-8000-000000000001";
const APP = "10000000-0000-4000-8000-000000000002";
const ROOM = "10000000-0000-4000-8000-000000000003";
const VERSION = "2026-09-11T08:00:00.123456+00:00";
const form = (extra = {}) => new Map(Object.entries({ groupId: GROUP, applicationId: APP, updatedAt: VERSION,
  reason: "架空の理由", revisionDeadline: "2026-10-01T23:59", roomPlan: JSON.stringify([{ roomId: ROOM, peopleCount: 2 }]), confirmed: "true", ...extra }));

async function harness(response, denied = false) {
  const calls = []; const authError = new Error("AUTH");
  const supabase = { async rpc(name, args) { calls.push(["rpc", name, JSON.parse(JSON.stringify(args))]); return response; } };
  const context = vm.createContext({ URLSearchParams, URL, JSON });
  const stubs = {
    "server-only": {},
    "next/cache": { revalidatePath(path) { calls.push(["revalidate", path]); } },
    "next/navigation": { redirect(url) { calls.push(["redirect", url]); throw Object.assign(new Error("REDIRECT"), { url }); } },
    "@/utils/auth/guards": { async requireStaff(path) { calls.push(["auth", path]); if (denied) throw authError; return { supabase }; } },
  };
  const cache = new Map();
  async function load(specifier) {
    if (cache.has(specifier)) return cache.get(specifier);
    let loadedModule;
    if (Object.hasOwn(stubs, specifier)) loadedModule = new vm.SyntheticModule(Object.keys(stubs[specifier]), function () {
      for (const [key, value] of Object.entries(stubs[specifier])) this.setExport(key, value);
    }, { context, identifier: specifier });
    else {
      const filename = specifier.startsWith("@/") ? `${specifier.slice(2)}.js` : specifier;
      loadedModule = new vm.SourceTextModule(await readFile(new URL(filename, ROOT), "utf8"), { context, identifier: filename });
    }
    cache.set(specifier, loadedModule); await loadedModule.link(load); return loadedModule;
  }
  const loaded = await load("app/actions/staff-groups.js"); await loaded.evaluate();
  return { api: loaded.namespace, calls, authError };
}

test("staff authorization runs before reading untrusted form data", async () => {
  const { api, calls, authError } = await harness({ data: null, error: null }, true);
  await assert.rejects(api.approveCommunityGroup(null), (error) => error === authError);
  assert.deepEqual(calls, [["auth", "/staff/community/groups"]]);
});

test("purpose confirmation sends only fixed RPC fields and redirects after revalidation", async () => {
  const { api, calls } = await harness({ data: [{ result_id: GROUP, result_status: "under_review", result_updated_at: VERSION }], error: null });
  await assert.rejects(api.confirmCommunityGroupPurpose(form()), /REDIRECT/);
  assert.deepEqual(calls.find((x) => x[0] === "rpc"), ["rpc", "review_group_application", {
    target_group_id: GROUP, review_action: "confirm_purpose", expected_updated_at: VERSION, public_reason: "架空の理由" }]);
  assert.ok(calls.find((x) => x[0] === "revalidate"));
});

test("room plan is normalized to the DB allowlist", async () => {
  const { api, calls } = await harness({ data: [{ result_id: GROUP, result_status: "under_review", result_updated_at: VERSION }], error: null });
  await assert.rejects(api.setCommunityGroupRooms(form()), /REDIRECT/);
  assert.deepEqual(calls.find((x) => x[0] === "rpc")[2].room_plan, [{ room_id: ROOM, people_count: 2 }]);
});

test("participant review validates IDs and maps approved database errors", async () => {
  let h = await harness({ data: null, error: null });
  assert.equal((await h.api.startCommunityGroupParticipantReview(form({ applicationId: "bad" }))).error, "invalid-application");
  assert.equal(h.calls.filter((x) => x[0] === "rpc").length, 0);
  h = await harness({ data: null, error: { code: "P0001", message: "purpose-review-required", details: "PRIVATE" } });
  const result = await h.api.approveCommunityGroupParticipant(form());
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { error: "purpose-review-required", fields: Object.fromEntries(form()), fieldErrors: {} });
  assert.ok(!JSON.stringify(result).includes("PRIVATE"));
});

test("irreversible group operations require explicit confirmation before RPC", async () => {
  for (const name of ["rejectCommunityGroup", "approveCommunityGroup", "rejectCommunityGroupParticipant",
    "confirmCommunityGroupCancellation", "cancelApprovedCommunityGroupParticipant"]) {
    const h = await harness({ data: null, error: null });
    const result = await h.api[name](form({ confirmed: "" }));
    assert.equal(result.error, "confirmation-required", name);
    assert.equal(result.fieldErrors.confirmed, "confirmation-required", name);
    assert.equal(h.calls.filter((call) => call[0] === "rpc").length, 0, name);
  }
});

test("malformed room plans and success payloads fail closed", async () => {
  let h = await harness({ data: null, error: null });
  assert.equal((await h.api.setCommunityGroupRooms(form({ roomPlan: "[]" }))).error, "invalid-room-plan");
  h = await harness({ data: [{ result_id: "bad", result_status: "approved", result_updated_at: VERSION }], error: null });
  assert.equal((await h.api.approveCommunityGroup(form())).error, "update-failed");
});

test("staff can reject one participant and request replacement", async () => {
  const response = { data: [{ result_id: APP, result_status: "rejected", result_updated_at: VERSION,
    result_group_id: GROUP, result_group_status: "revision_requested", result_group_updated_at: VERSION }], error: null };
  const { api, calls } = await harness(response);
  await assert.rejects(api.rejectCommunityGroupParticipant(form()), /REDIRECT/);
  assert.equal(calls.find((x) => x[0] === "rpc")[1], "reject_group_participant");
});

test("staff confirms group cancellation and reduces an approved group atomically", async () => {
  let response = { data: [{ result_id: GROUP, result_status: "cancelled", result_updated_at: VERSION }], error: null };
  let h = await harness(response);
  await assert.rejects(h.api.confirmCommunityGroupCancellation(form()), /REDIRECT/);
  assert.equal(h.calls.find((x) => x[0] === "rpc")[1], "confirm_community_group_cancellation");
  response = { data: [{ result_id: GROUP, result_status: "approved", result_updated_at: VERSION,
    result_application_status: "cancelled", remaining_participants: 1 }], error: null };
  h = await harness(response);
  await assert.rejects(h.api.cancelApprovedCommunityGroupParticipant(form({ roomPlan: JSON.stringify([{ roomId: ROOM, peopleCount: 1 }]) })), /REDIRECT/);
  const call = h.calls.find((x) => x[0] === "rpc");
  assert.equal(call[1], "cancel_approved_group_participant");
  assert.deepEqual(call[2].room_plan, [{ room_id: ROOM, people_count: 1 }]);
});
