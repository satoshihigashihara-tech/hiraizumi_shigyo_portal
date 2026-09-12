// Run: node --experimental-vm-modules --test tests/group-invitations-actions.test.mjs
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const GROUP = "10000000-0000-4000-8000-000000000001";
const APP = "10000000-0000-4000-8000-000000000002";
const USER = "10000000-0000-4000-8000-000000000003";
const VERSION = "2026-09-11T06:30:00.123456+00:00";
const TOKEN = "a".repeat(64);
const CODE = "ABCDEFGHJKLMNPQR";
const ISSUED = [{ result_group_id: GROUP, result_updated_at: VERSION, invite_token: TOKEN,
  invite_code: CODE, expires_at: "2026-09-19T15:00:00+00:00" }];
const JOINED = [{ result_group_id: GROUP, result_application_id: APP, result_group_updated_at: VERSION }];
const copy = (value) => JSON.parse(JSON.stringify(value));
const form = (fields = {}) => new Map(Object.entries({ groupId: GROUP, updatedAt: VERSION,
  applicationId: APP, inviteValue: TOKEN, inviteKind: "token", reason: "架空の参加者変更",
  confirmed: "true", ...fields }));

async function harness(path, { response = { data: ISSUED, error: null }, denied = false } = {}) {
  const calls = [];
  const supabase = { async rpc(name, args) { calls.push(["rpc", name, copy(args)]); return response; } };
  const authError = new Error("AUTH_REDIRECT");
  const context = vm.createContext({ URLSearchParams, URL });
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

test("invite issue authorizes, sends only group/version and returns one-time secrets without redirect", async () => {
  const { api, calls } = await harness("app/actions/group-invitations.js");
  const result = copy(await api.issueCommunityGroupInvite(form({ status: "approved", representativeUserId: USER })));
  assert.equal(calls[0][0], "auth");
  assert.deepEqual(calls.find((call) => call[0] === "rpc").slice(1), ["issue_community_group_invite",
    { target_group_id: GROUP, expected_updated_at: VERSION }]);
  assert.deepEqual(result.invite, { token: TOKEN, code: CODE, expiresAt: "2026-09-19T15:00:00+00:00", groupUpdatedAt: VERSION });
  assert.ok(calls.some((call) => call[0] === "revalidate"));
  assert.ok(!calls.some((call) => call[0] === "redirect"));
});

test("join normalizes a manual code, uses caller UUID and redirects after refresh", async () => {
  const { api, calls } = await harness("app/actions/group-invitations.js", { response: { data: JOINED, error: null } });
  await assert.rejects(api.joinCommunityGroup(form({ inviteKind: "code", inviteValue: "abcd-efgh-jklm-npqr" })), /REDIRECT/);
  assert.deepEqual(calls.find((call) => call[0] === "rpc").slice(1), ["join_community_group", {
    invite_value: CODE, invite_kind: "code", target_application_id: APP,
  }]);
  assert.equal(calls.at(-1)[1], `/user/applications/${APP}/edit?joined=group&mode=fieldwork`);
});

test("representative removes a participant with fixed identifiers and reason", async () => {
  const response = { data: [{ result_group_id: GROUP, result_group_status: "collecting",
    result_group_updated_at: VERSION, result_application_status: "cancelled" }], error: null };
  const { api, calls } = await harness("app/actions/group-invitations.js", { response });
  await assert.rejects(api.removeCommunityGroupParticipant(form()), /REDIRECT/);
  assert.deepEqual(calls.find((call) => call[0] === "rpc"), ["rpc", "remove_community_group_participant", {
    target_group_id: GROUP, target_application_id: APP, expected_updated_at: VERSION,
    removal_reason: "架空の参加者変更",
  }]);
});

test("representative removal requires explicit confirmation before RPC", async () => {
  const { api, calls } = await harness("app/actions/group-invitations.js");
  const result = copy(await api.removeCommunityGroupParticipant(form({ confirmed: "false" })));
  assert.equal(result.error, "confirmation-required");
  assert.equal(calls.filter((call) => call[0] === "rpc").length, 0);
});

for (const action of ["issueCommunityGroupInvite", "joinCommunityGroup", "removeCommunityGroupParticipant"]) {
  test(`${action} authorization failure precedes input and DB access`, async () => {
    const { api, calls, authError } = await harness("app/actions/group-invitations.js", { denied: true });
    await assert.rejects(api[action](null), (error) => error === authError);
    assert.equal(calls.length, 1);
  });
}

test("invalid IDs, versions, token kinds and values fail before RPC", async () => {
  for (const [action, fields, expected] of [
    ["issueCommunityGroupInvite", { groupId: "bad" }, "invalid-group"],
    ["issueCommunityGroupInvite", { updatedAt: "bad" }, "invalid-version"],
    ["joinCommunityGroup", { applicationId: "bad" }, "invalid-application"],
    ["joinCommunityGroup", { confirmed: "false" }, "confirmation-required"],
    ["joinCommunityGroup", { inviteKind: "token", inviteValue: "short" }, "invalid-invite"],
    ["joinCommunityGroup", { inviteKind: "other" }, "invalid-invite"],
  ]) {
    const { api, calls } = await harness("app/actions/group-invitations.js");
    assert.equal((await api[action](form(fields))).error, expected);
    assert.equal(calls.filter((call) => call[0] === "rpc").length, 0);
  }
});

test("approved DB errors are stable; private details and malformed successes fail closed", async () => {
  for (const [error, expected] of [[{ code: "P0001", message: "group-full", details: "PRIVATE" }, "group-full"],
    [{ code: "40001", message: "PRIVATE" }, "stale-update"], [{ code: "XX000", message: "PRIVATE" }, "update-failed"]]) {
    const { api } = await harness("app/actions/group-invitations.js", { response: { data: null, error } });
    const result = copy(await api.joinCommunityGroup(form()));
    assert.equal(result.error, expected); assert.ok(!JSON.stringify(result).includes("PRIVATE"));
  }
  const { api, calls } = await harness("app/actions/group-invitations.js", { response: { data: [{ ...JOINED[0], result_group_id: "bad" }], error: null } });
  assert.equal((await api.joinCommunityGroup(form())).error, "update-failed");
  assert.ok(!calls.some((call) => call[0] === "redirect"));
});

test("invite context requires auth and strips representative/contact/internal fields", async () => {
  const data = { group_id: GROUP, group_name: "架空団体", start_date: "2026-10-01", end_date: "2026-10-03",
    purpose: "架空調査", local_activity: "架空活動", planned_participants: 4, participant_due_at: VERSION,
    joined_participants: 1, already_joined_application_id: null, can_join: true,
    representative_name: "PRIVATE", representative_phone: "PRIVATE", token_hash: "PRIVATE" };
  const { api, calls } = await harness("utils/group-invitations/queries.js", { response: { data, error: null } });
  const result = copy(await api.getCommunityGroupInvite(TOKEN, "token"));
  assert.equal(calls[0][0], "auth"); assert.equal(result.error, null);
  assert.ok(!JSON.stringify(result).includes("PRIVATE"));
});

test("invite context preserves a validated invitation path through login", async () => {
  const data = { group_id: GROUP, group_name: "架空団体", start_date: "2026-10-01", end_date: "2026-10-03",
    purpose: "架空調査", local_activity: "架空活動", planned_participants: 4, participant_due_at: VERSION,
    joined_participants: 1, already_joined_application_id: null, can_join: true };
  const { api, calls } = await harness("utils/group-invitations/queries.js", { response: { data, error: null } });
  await api.getCommunityGroupInvite(TOKEN, "token", `/invite/${TOKEN}`);
  assert.deepEqual(calls[0], ["auth", `/invite/${TOKEN}`]);
});

test("invite pages never render representative contact fields or the secret value as text", async () => {
  const detail = await readFile(new URL("app/invite/[token]/page.js", ROOT), "utf8");
  const entry = await readFile(new URL("app/invite/page.js", ROOT), "utf8");
  const formSource = await readFile(new URL("app/invite/[token]/JoinGroupForm.js", ROOT), "utf8");
  assert.match(entry, /normalizeInvite\(enteredCode, "code"\)/);
  assert.match(detail, /getCommunityGroupInvite\(inviteValue, inviteKind, returnTo\)/);
  assert.match(detail, /crypto\.randomUUID\(\)/);
  assert.match(formSource, /useActionState/);
  assert.match(formSource, /disabled=!\{confirmed\}|disabled=\{!confirmed\}/);
  for (const source of [detail, entry, formSource]) {
    assert.doesNotMatch(source, /representative_(?:name|address|phone)/);
  }
});

test("representative participant list exposes only names and workflow state", async () => {
  const data = { group_id: GROUP, group_name: "架空団体", status: "collecting", updated_at: VERSION,
    planned_participants: 4, participant_due_at: VERSION, representative_address: "PRIVATE",
    participants: [{ application_id: APP, name: "架空参加者", application_status: "draft",
      is_representative: false, joined_at: VERSION, user_id: USER, phone: "PRIVATE" }] };
  const { api } = await harness("utils/group-invitations/queries.js", { response: { data, error: null } });
  const result = copy(await api.getCommunityGroupParticipants(GROUP));
  assert.equal(result.error, null); assert.ok(!JSON.stringify(result).includes("PRIVATE"));
  assert.deepEqual(Object.keys(result.group.participants[0]),
    ["application_id", "name", "application_status", "is_representative", "joined_at"]);
});

test("invite normalization has exact entropy formats and rejects ambiguous characters", async () => {
  const { api } = await harness("utils/group-invitations/validation.js");
  assert.equal(api.normalizeInvite(TOKEN.toUpperCase(), "token"), TOKEN);
  assert.equal(api.normalizeInvite("ABCD-EFGH-JKLM-NPQR", "code"), CODE);
  assert.equal(api.normalizeInvite("ABCDEFGHJKLMNPQ0", "code"), null);
  assert.equal(api.normalizeInvite("x".repeat(64), "token"), null);
});
