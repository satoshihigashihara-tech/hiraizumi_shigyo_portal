import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const CAMP = "10000000-0000-4000-8000-000000000001";
const USER = "10000000-0000-4000-8000-000000000002";
const ROOM = "10000000-0000-4000-8000-000000000003";
const UPDATED = "2026-09-13T01:00:00.000001+00:00";
const fields = { campId: CAMP, eligibleUserId: USER, updatedAt: UPDATED, rosterVersion: "2", roomPlanVersion: "1",
  applicationId: "", applicationUpdatedAt: "", endAction: "withdraw", reason: "架空終了理由", confirmed: "yes", checkoutConfirmed: "" };
const saved = { camp_id: CAMP, eligible_user_id: USER, updated_at: UPDATED, roster_version: "3", room_plan_version: "2",
  disabled_at: UPDATED, participation_status: "released", application_id: null, application_updated_at: null,
  application_status: null, stay_status: null, released_from: "2026-09-20" };
const contextData = { ...saved, management_name: "架空氏名", released_at: UPDATED, release_reason: "架空理由",
  can_withdraw: false, can_reject: false, requires_checkout_confirmation: false };
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
  return { calls, action: (await load("@/app/actions/staff-camp-lifecycle")).namespace.endCampRosterParticipationState,
    query: (await load("@/utils/staff-camps/lifecycle-queries")).namespace.getStaffCampRosterLifecycle,
    validation: (await load("@/utils/staff-camps/lifecycle-validation")).namespace };
}
const form = (extra = {}) => new Map(Object.entries({ ...fields, ...extra }));

test("A4 authenticates before parsing untrusted inputs", async () => {
 const h=await harness({denied:true});
 await assert.rejects(h.action(null,null),/AUTH_DENIED/);
 await assert.rejects(h.query("bad","bad"),/AUTH_DENIED/);
});
test("A4 requires explicit confirmation, reason, versions and matched application identity", async () => {
 const h=await harness();
 for (const bad of [{campId:"bad"},{eligibleUserId:"bad"},{updatedAt:"bad"},{rosterVersion:"-1"},
  {roomPlanVersion:"9007199254740993.0"},{applicationId:ROOM},{applicationUpdatedAt:UPDATED},
  {endAction:"complete"},{reason:" "},{reason:"あ".repeat(2001)},{confirmed:"true"},{confirmed:""}]) {
  assert.ok((await h.action(null,form(bad))).error);
 }
 assert.equal(h.calls.filter(x=>x[0]==="rpc").length,0);
});
test("A4 submits one atomic RPC with exact allowlist and explicit booleans", async () => {
 const h=await harness(); const result=await h.action(null,form({actor:"spoof",releasedFrom:"2000-01-01"}));
 assert.equal(result.saved,true);
 const rpc=h.calls.find(x=>x[0]==="rpc");
 assert.equal(rpc[1],"end_camp_roster_participation");
 assert.deepEqual(Object.keys(rpc[2]).sort(),["target_camp_id","target_eligible_user_id","expected_updated_at","expected_roster_version",
  "expected_room_plan_version","expected_application_id","expected_application_updated_at","end_action","change_reason","confirmed","checkout_confirmed"].sort());
 assert.equal(rpc[2].expected_application_id,null); assert.equal(rpc[2].checkout_confirmed,false);
 assert.ok(h.calls.some(x=>x[1]===`/staff/camps/${CAMP}/eligible-users`));
 assert.ok(h.calls.some(x=>x[1]===`/staff/camps/${CAMP}/room-plan`));
 assert.ok(h.calls.some(x=>x[1]==="/user/camp-room"));
});
test("A4 bigint values remain decimal strings", async () => {
 const h=await harness({data:{...saved,roster_version:"9007199254740993",room_plan_version:"9007199254740994"}});
 const result=await h.action(null,form({rosterVersion:"9007199254740992",roomPlanVersion:"9007199254740993"}));
 assert.equal(result.saved,true); assert.equal(result.result.room_plan_version,"9007199254740994");
});
test("A4 failures preserve form data, redact private details and never retry", async () => {
 for(const [error,code] of [[{code:"P0001",message:"checkout-confirmation-required"},"checkout-confirmation-required"],
  [{code:"42501",message:"secret"},"staff-required"],[{code:"40001",message:"secret"},"stale-update"],
  [{code:"40P01",message:"secret"},"stale-update"],[{code:"P0001",message:"secret"},"save-failed"]]) {
  const h=await harness({error:{...error,details:"secret"},data:null});
  const result=await h.action(null,form());
  assert.equal(result.error,code); assert.equal(result.fields.reason,fields.reason);
  assert.equal(h.calls.filter(x=>x[0]==="rpc").length,1);
  assert.ok(!h.calls.some(x=>x[0]==="revalidate")); assert.ok(!JSON.stringify(result).includes("secret"));
 }
});
test("A4 refuses malformed success or unrelated result identity", async () => {
 for (const data of [null,{}, {...saved,eligible_user_id:ROOM},{...saved,application_id:ROOM},
  {...saved,roster_version:"2"},{...saved,room_plan_version:9007199254740992},
  {...saved,participation_status:"participating"},{...saved,disabled_at:null},{...saved,released_from:"bad"}]) {
  const h=await harness({data}); assert.equal((await h.action(null,form())).error,"save-failed");
 }
});
test("A4 rejection retains eligibility and refreshes application routes", async () => {
 const h=await harness({data:{...saved,disabled_at:null,application_id:ROOM,application_updated_at:UPDATED,application_status:"rejected"}});
 const result=await h.action(null,form({applicationId:ROOM,applicationUpdatedAt:UPDATED,endAction:"reject"}));
 assert.equal(result.saved,true); assert.ok(h.calls.some(x=>x[1]===`/user/applications/${ROOM}`));
});
test("A4 staff lifecycle projection strips auth and private unrelated properties", async () => {
 const h=await harness({data:{...contextData,linked_user_id:"secret",owner_address:"secret"}});
 const result=await h.query(CAMP,USER); assert.equal(result.error,null);
 assert.equal(result.participant.management_name,"架空氏名"); assert.ok(!JSON.stringify(result).includes("secret"));
});
test("A4 projection rejects incomplete or malformed contracts", async () => {
 for(const data of [null,{...contextData,can_reject:null},{...contextData,released_at:"bad"},{...contextData,management_name:3},
  {...contextData,application_id:ROOM},{...contextData,roster_version:9007199254740992}]) {
  const h=await harness({data}); assert.equal((await h.query(CAMP,USER)).error,"load-failed");
 }
});
