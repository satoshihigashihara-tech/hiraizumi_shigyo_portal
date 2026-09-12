import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const CAMP = "10000000-0000-4000-8000-000000000001";
const APPLICATION = "10000000-0000-4000-8000-000000000002";
const assigned = { camp_id: CAMP, camp_name: "秋季キャンプ", start_date: "2026-10-01", end_date: "2026-10-03",
  room_assignment_mode: "eligible_roster", application_id: APPLICATION, participation_state: "participating",
  placement_state: "assigned", room_name: "確認済み部屋", floor: 2,
  assignment_start_date: "2026-10-01", assignment_end_date: "2026-10-03" };

async function queryHarness({ data = [assigned], error = null, denied = false } = {}) {
  const calls = [];
  const context = vm.createContext({});
  const cache = new Map();
  const stubs = {
    "server-only": {},
    "@/utils/auth/guards": { async requireActiveUser(path) {
      calls.push(["auth", path]);
      if (denied) throw new Error("AUTH_DENIED");
      return { supabase: { async rpc(name, args) { calls.push(["rpc", name, args]); return { data, error }; } } };
    } },
    "@/utils/application-operations/validation": { isUuid(value) { return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value ?? ""); } },
  };
  async function load(name) {
    if (cache.has(name)) return cache.get(name);
    const values = stubs[name];
    const mod = values ? new vm.SyntheticModule(Object.keys(values), function () {
      for (const [key, value] of Object.entries(values)) this.setExport(key, value);
    }, { context }) : new vm.SourceTextModule(await readFile(new URL(`${name.replace(/^@\//, "")}.js`, ROOT), "utf8"), { context });
    cache.set(name, mod);
    await mod.link(load);
    await mod.evaluate();
    return mod;
  }
  return { calls, query: (await load("@/utils/camp-room-assignments/queries")).namespace.getMyCampRoomAssignments };
}

test("A6 authenticates before loading the signed-in participant room", async () => {
  const h = await queryHarness({ denied: true });
  await assert.rejects(h.query(), /AUTH_DENIED/);
  assert.deepEqual(h.calls, [["auth", "/user/camp-room"]]);
});

test("A6 calls a no-argument self-only RPC and strips unexpected fields", async () => {
  const h = await queryHarness({ data: [{ ...assigned, eligible_user_id: "private", other_rooms: ["private"] }] });
  const result = await h.query();
  assert.equal(result.error, null);
  assert.equal(result.assignments[0].roomName, "確認済み部屋");
  assert.ok(!JSON.stringify(result).includes("private"));
  assert.deepEqual(h.calls[1], ["rpc", "get_my_camp_room_assignments", undefined]);
});

test("A6 accepts explicit unassigned ended and legacy states", async () => {
  const emptyRoom = { room_name: null, floor: null, assignment_start_date: null, assignment_end_date: null };
  const data = [
    { ...assigned, ...emptyRoom, placement_state: "unassigned" },
    { ...assigned, ...emptyRoom, participation_state: "ended", placement_state: "ended" },
    { ...assigned, ...emptyRoom, room_assignment_mode: "legacy_application", participation_state: "legacy", placement_state: "legacy" },
  ];
  assert.equal((await (await queryHarness({ data })).query()).assignments.length, 3);
});

test("A6 rejects malformed or privacy-widened response shapes", async () => {
  for (const data of [null, [null], [{ ...assigned, camp_id: "bad" }], [{ ...assigned, placement_state: "assigned", room_name: null }],
    [{ ...assigned, placement_state: "unassigned" }], [{ ...assigned, room_assignment_mode: "legacy_application" }], Array(101).fill(assigned)]) {
    const result = await (await queryHarness({ data })).query();
    assert.equal(result.error, "load-failed");
    assert.equal(result.assignments.length, 0);
  }
});

test("A6 SQL derives ownership and never aggregates a roster", async () => {
  const sql = await readFile(new URL("supabase/migrations/202609130034_user_camp_room_assignment.sql", ROOT), "utf8");
  assert.match(sql, /e\.linked_user_id = actor/);
  assert.match(sql, /verified\.user_id = actor/);
  assert.match(sql, /verified\.camp_eligible_user_id = e\.id/);
  assert.match(sql, /a\.user_id = actor/);
  assert.match(sql, /create function public\.get_my_camp_room_assignments\(\)/);
  const returnedKeys = [...sql.matchAll(/'([a-z_]+)', [a-z_]+/g)].map((match) => match[1]);
  assert.ok(!returnedKeys.includes("eligible_user_id"));
  assert.ok(!returnedKeys.includes("management_name"));
  assert.ok(!returnedKeys.includes("email_normalized"));
});

test("A6 page provides profile and application routes plus all required states", async () => {
  const [page, profile, detail] = await Promise.all([
    readFile(new URL("app/user/camp-room/page.js", ROOT), "utf8"),
    readFile(new URL("app/user/profile/page.js", ROOT), "utf8"),
    readFile(new URL("app/user/applications/[applicationId]/page.js", ROOT), "utf8"),
  ]);
  for (const text of ["部屋はまだ決まっていません", "参加は終了しています", "従来方式のキャンプです", "2階の案内図は掲載していません"]) assert.match(page, new RegExp(text));
  assert.match(profile, /\/user\/camp-room/);
  assert.match(detail, /\/user\/camp-room/);
  assert.doesNotMatch(page, /eligibleUser|対象者一覧|ほかの方の部屋.*\{/);
});
