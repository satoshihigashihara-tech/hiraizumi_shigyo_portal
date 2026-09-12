import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const APP = "10000000-0000-4000-8000-000000000001";
const GROUP = "10000000-0000-4000-8000-000000000002";
const VERSION = "2026-09-11T10:00:00.123456+00:00";
const KEY = "10000000-0000-4000-8000-000000000003";
const form = (extra = {}) => new Map(Object.entries({ applicationId: APP, updatedAt: VERSION,
  applicantName: "架空参加者", applicantAddress: "架空住所", applicantPhone: "000-0000-0000",
  emergencyContactName: "架空連絡先", emergencyContactAddress: "架空住所", emergencyContactPhone: "000-0000-0000",
  notes: "本人メモ", guardianConsentRequired: "false", submissionKey: KEY, confirmed: "true", ...extra }));

async function harness(path, response) {
  const calls = []; const context = vm.createContext({ URLSearchParams, URL });
  const supabase = { async rpc(name, args) { calls.push(["rpc", name, structuredClone(args)]); return response; } };
  const stubs = { "server-only": {}, "next/cache": { revalidatePath(value) { calls.push(["revalidate", value]); } },
    "next/navigation": { redirect(value) { calls.push(["redirect", value]); throw new Error("REDIRECT"); } },
    "@/utils/auth/guards": { async requireActiveUser(value) { calls.push(["auth", value]); return { supabase }; } } };
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
  const loadedModule = await load(path); await loadedModule.evaluate(); return { api: loadedModule.namespace, calls };
}

test("save sends only participant-owned fields", async () => {
  const response = { data: [{ result_id: APP, result_updated_at: VERSION }], error: null };
  const { api, calls } = await harness("app/actions/group-participants.js", response);
  await assert.rejects(api.saveGroupParticipantApplication(form({ purpose: "改ざん", startDate: "2099-01-01" })), /REDIRECT/);
  const [, args] = calls.find((call) => call[0] === "rpc").slice(1);
  assert.equal(args.target_application_id, APP); assert.equal(args.expected_updated_at, VERSION);
  assert.deepEqual(Object.keys(args.draft_fields).sort(), ["emergency_address", "emergency_name", "emergency_phone",
    "requires_guardian_consent", "special_notes", "user_address", "user_name", "user_phone"]);
  assert.ok(!JSON.stringify(args).includes("改ざん")); assert.ok(!JSON.stringify(args).includes("2099"));
});

test("submit validates confirmation and accepts collecting or under_review result", async () => {
  let h = await harness("app/actions/group-participants.js", { data: null, error: null });
  assert.equal((await h.api.submitGroupParticipantApplication(form({ confirmed: "false" }))).error, "confirmation-required");
  assert.equal(h.calls.filter((call) => call[0] === "rpc").length, 0);
  h = await harness("app/actions/group-participants.js", { data: [{ result_id: APP, result_status: "submitted",
    result_updated_at: VERSION, reception_number: "SG-2026-0001", submission_time: VERSION,
    result_group_id: GROUP, result_group_status: "under_review", result_group_updated_at: VERSION }], error: null });
  await assert.rejects(h.api.submitGroupParticipantApplication(form()), /REDIRECT/);
  assert.equal(h.calls.find((call) => call[0] === "rpc")[1], "submit_group_participant_application");
});

test("query strips unapproved and other-participant data", async () => {
  const data = { id: APP, group_id: GROUP, group_name: "架空団体", group_status: "collecting", status: "draft",
    updated_at: VERSION, start_date: "2026-10-01", end_date: "2026-10-03", usage_place: "common_and_second_floor",
    purpose: "架空目的", local_activity: "架空活動", participant_due_at: VERSION, can_edit: true,
    fields: { user_name: "本人", user_address: "本人住所", user_phone: "000", emergency_name: "緊急",
      emergency_address: "緊急住所", emergency_phone: "111", special_notes: "本人メモ", requires_guardian_consent: false,
      representative_address: "PRIVATE", other_participants: ["PRIVATE"] }, representative_phone: "PRIVATE" };
  const { api } = await harness("utils/group-participants/queries.js", { data, error: null });
  const result = structuredClone(await api.getGroupParticipantApplication(APP));
  assert.equal(result.error, null); assert.ok(!JSON.stringify(result).includes("PRIVATE"));
});

test("approved database errors are stable and malformed successes fail closed", async () => {
  for (const [error, expected] of [[{ code: "P0001", message: "participant-deadline-passed" }, "participant-deadline-passed"],
    [{ code: "40001", message: "private" }, "stale-update"], [{ code: "XX000", message: "private" }, "update-failed"]]) {
    const { api } = await harness("app/actions/group-participants.js", { data: null, error });
    assert.equal((await api.submitGroupParticipantApplication(form())).error, expected);
  }
});

test("participant UI exposes only owned fields and dispatches all shared routes", async () => {
  const formSource = await readFile(new URL("app/user/applications/[applicationId]/edit/GroupParticipantForm.js", ROOT), "utf8");
  for (const name of ["applicantName", "applicantAddress", "applicantPhone", "emergencyContactName",
    "emergencyContactAddress", "emergencyContactPhone", "notes", "guardianConsentRequired"]) {
    assert.match(formSource, new RegExp(`name="${name}"`));
  }
  for (const forbidden of ["representativeAddress", "representativePhone", "otherParticipants", "startDate", "endDate", "usagePurpose"]) {
    assert.doesNotMatch(formSource, new RegExp(`name="${forbidden}"`));
  }
  assert.match(formSource, /saveGroupParticipantApplication/);
  assert.match(formSource, /useActionState/);
  assert.match(formSource, /自動保存はされません/);

  const submitSource = await readFile(new URL("app/user/applications/[applicationId]/confirm/SubmitConfirmation.js", ROOT), "utf8");
  assert.match(submitSource, /submitGroupParticipantApplication/);
  assert.match(submitSource, /usageType === "community_group"/);
  for (const path of ["edit/page.js", "confirm/page.js", "complete/page.js", "page.js"]) {
    const source = await readFile(new URL(`app/user/applications/[applicationId]/${path}`, ROOT), "utf8");
    assert.match(source, /kind\.usageType === "community_group"/);
    assert.match(source, /getGroupParticipantApplication/);
  }
});

test("correction migration aligns read and consent edit guards", async () => {
  const sql = await readFile(new URL("supabase/migrations/202609120028_group_participant_read_corrections.sql", ROOT), "utf8");
  assert.match(sql, /create or replace function public\.get_group_participant_application/);
  assert.match(sql, /create or replace function public\.register_group_guardian_consent_document/);
  assert.match(sql, /a\.status='revision_requested' and g\.status='revision_requested'/);
  assert.match(sql, /'active_deadline',deadline/);
  assert.match(sql, /coalesce\(a\.decision_reason,g\.decision_reason\)/);
  assert.doesNotMatch(sql, /representative_address|representative_phone|other_participants/);
});
