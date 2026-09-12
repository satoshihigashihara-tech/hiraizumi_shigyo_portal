import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const CAMP = "10000000-0000-4000-8000-000000000001";
const USER = "10000000-0000-4000-8000-000000000002";
const ROOM = "10000000-0000-4000-8000-000000000003";
const fields = { campId: CAMP, rosterVersion: "2", roomPlanVersion: "0",
  assignments: JSON.stringify([{ eligible_user_id: USER, room_id: ROOM }]) };
const saved = { camp_id: CAMP, roster_version: "2", room_plan_version: "1", saved_roster_version: "2" };
const plan = { ...saved, room_plan_committed_at: "2026-09-13T01:00:00Z",
  eligible_users: [{ id: USER, management_name: "架空対象者", room_id: ROOM, assignment_version: "1" }],
  rooms: [{ id: ROOM, name: "架空部屋", capacity: 2 }] };
async function harness({ data = saved, error = null, denied = false } = {}) {
  const calls = [];
  const context = vm.createContext({});
  const cache = new Map();
  const stubs = {
    "server-only": {},
    "next/cache": { revalidatePath(path) { calls.push(["revalidate", path]); } },
    "@/utils/auth/guards": { async requireStaff(path) {
      calls.push(["auth", path]);
      if (denied) throw new Error("AUTH_DENIED");
      return { supabase: { async rpc(name, args) { calls.push(["rpc", name, args]); return { data, error }; } } };
    } },
  };
  async function load(name) {
    if (cache.has(name)) return cache.get(name);
    let mod;
    if (Object.hasOwn(stubs, name)) {
      const values = stubs[name];
      mod = new vm.SyntheticModule(Object.keys(values), function () {
        for (const [key, value] of Object.entries(values)) this.setExport(key, value);
      }, { context });
    } else {
      const path = name.replace(/^@\//, "");
      mod = new vm.SourceTextModule(await readFile(new URL(`${path}.js`, ROOT), "utf8"), { context });
    }
    cache.set(name, mod);
    await mod.link(load);
    await mod.evaluate();
    return mod;
  }
  return { calls, action: (await load("@/app/actions/staff-camp-room-plans")).namespace.saveCampRoomPlanState,
    query: (await load("@/utils/staff-camps/room-plan-queries")).namespace.getStaffCampRoomPlan,
    validation: (await load("@/utils/staff-camps/room-plan-validation")).namespace };
}
const form = (extra = {}) => new Map(Object.entries({ ...fields, ...extra }));

test("A3 authenticates before inspecting malformed inputs", async () => {
  const h = await harness({ denied: true });
  await assert.rejects(h.action(null, null), /AUTH_DENIED/);
  await assert.rejects(h.query("bad"), /AUTH_DENIED/);
  assert.equal(h.calls.length, 2);
});
test("A3 sends exact whitelist and preserves bigint versions", async () => {
  const h = await harness({ data: { ...saved, room_plan_version: "9007199254740993" } });
  const result = await h.action(null, form({ roomPlanVersion: "9007199254740992", actor: "spoof", peopleCount: "15" }));
  assert.equal(result.saved, true);
  assert.deepEqual(Object.keys(h.calls[1][2]).sort(), ["expected_room_plan_version", "expected_roster_version", "submitted_assignments", "target_camp_id"]);
  assert.equal(h.calls[1][2].expected_room_plan_version, "9007199254740992");
  assert.equal(result.fields.roomPlanVersion, "9007199254740993");
  assert.equal(h.calls.filter(x => x[0] === "revalidate").length, 4);
});
test("A3 rejects invalid structure versions IDs duplicates and sizes before RPC", async () => {
  const h = await harness();
  for (const bad of [{ campId: "bad" }, { rosterVersion: "-1" }, { rosterVersion: "1.5" }, { rosterVersion: "9223372036854775808" },
    { assignments: "null" }, { assignments: "{}" }, { assignments: "[]" }, { assignments: "bad" },
    { assignments: JSON.stringify([{ eligible_user_id: USER, room_id: ROOM, people_count: 1 }]) },
    { assignments: JSON.stringify([{ eligible_user_id: USER, room_id: ROOM }, { eligible_user_id: USER.toUpperCase(), room_id: ROOM }]) },
    { assignments: " ".repeat(4097) }, { assignments: JSON.stringify(Array(16).fill({ eligible_user_id: USER, room_id: ROOM })) }]) {
    assert.ok((await h.action(null, form(bad))).error);
  }
  assert.ok(h.calls.every(x => x[0] === "auth"));
});
test("A3 maps known errors and never leaks database detail or retries", async () => {
  for (const [error, expected] of [
    [{ code: "P0001", message: "stale-update", details: "private-data" }, "stale-update"],
    [{ code: "40001", message: "internal" }, "stale-update"],
    [{ code: "42501", message: "private-data" }, "staff-required"],
    [{ code: "40P01", message: "private-data" }, "save-failed"],
    [{ code: "23505", message: "private-data" }, "save-failed"],
    [{ code: "P0001", message: "private-data" }, "save-failed"],
    [{ code: "P0001", message: "room-capacity-full" }, "room-capacity-full"],
  ]) {
    const h = await harness({ data: null, error });
    const result = await h.action(null, form());
    assert.equal(result.error, expected);
    assert.equal(result.fields.assignments, fields.assignments);
    assert.ok(!JSON.stringify(result).includes("private-data"));
    assert.equal(h.calls.filter(x => x[0] === "rpc").length, 1);
    assert.ok(!h.calls.some(x => x[0] === "revalidate"));
  }
});
test("A3 validates returned camp and versions before declaring success", async () => {
  for (const data of [null, {}, { ...saved, camp_id: USER }, { ...saved, roster_version: "3" },
    { ...saved, saved_roster_version: "1" }, { ...saved, room_plan_version: "0" }, { ...saved, room_plan_version: 9007199254740992 }]) {
    const h = await harness({ data });
    assert.equal((await h.action(null, form())).error, "save-failed");
    assert.ok(!h.calls.some(x => x[0] === "revalidate"));
  }
});
test("A3 staff projection strips unexpected private fields", async () => {
  const h = await harness({ data: { ...plan, secret: "private-data", eligible_users: [{ ...plan.eligible_users[0], linked_user_id: "private-data" }] } });
  const result = await h.query(CAMP);
  assert.equal(result.plan.complete, true);
  assert.equal(result.plan.users[0].assignmentVersion, "1");
  assert.ok(!JSON.stringify(result).includes("private-data"));
});
test("A3 newly added member invalidates completeness without hiding old assignments", async () => {
  const h = await harness({ data: { ...plan, roster_version: "3", eligible_users: [...plan.eligible_users,
    { id: CAMP, management_name: "架空追加", room_id: null, assignment_version: null }] } });
  const result = await h.query(CAMP);
  assert.equal(result.plan.complete, false);
  assert.equal(result.plan.users[0].roomId, ROOM);
  assert.equal(result.plan.users[1].roomId, null);
});
test("A3 rejects malformed read responses", async () => {
  for (const data of [null, { ...plan, camp_id: USER }, { ...plan, rooms: [{}] }, { ...plan, eligible_users: [null] },
    { ...plan, roster_version: 9007199254740992 }, { ...plan, room_plan_committed_at: "bad" }]) {
    const h = await harness({ data });
    assert.equal((await h.query(CAMP)).error, "load-failed");
  }
});
