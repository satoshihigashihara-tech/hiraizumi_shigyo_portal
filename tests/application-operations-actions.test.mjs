// Phase 1 + 2 (use --test-name-pattern="stay" for Phase 2): node --experimental-vm-modules --test tests/application-operations-actions.test.mjs
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
const SAVED = [];
const copy = (value) => JSON.parse(JSON.stringify(value));
async function harness(path, { response = { data: SAVED, error: null }, denied = false, readResponse = response, metadata = response, rpcResponses = null, authResponse = { data: { session: {}, user: { id: USER } } } } = {}) {
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
    async rpc(name, args) { calls.push(["rpc", name, copy(args)]); return rpcResponses?.[name] ?? response; },
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
const fields = { applicationId: ID, updatedAt: VERSION, paymentStatus: "paid", paymentDueDate: "2028-02-29", reason: "" };
const form = (values = {}) => new Map(Object.entries({ ...fields, ...values }));
const actionPath = "app/actions/staff-application-operations.js";
const queriesPath = "utils/application-operations/queries.js";
const validationPath = "utils/application-operations/validation.js";
const result = (kind) => [{ result_id: ID, result_usage_type: kind, result_camp_id: kind === "camp" ? CAMP : null, result_updated_at: VERSION }];
for (const kind of ["camp", "community_individual"]) {
  test(`payment ${kind}: exact RPC fields and canonical destination`, async () => {
    const { api, calls } = await harness(actionPath, { response: { data: result(kind) } });
    await assert.rejects(api.updateApplicationPayment(form({ totalAmount: "0", status: "cancelled", campId: OTHER_ID })), /REDIRECT/);
    assert.deepEqual(calls[0], ["auth", "staff", "/staff"]);
    assert.deepEqual(calls.find(c => c[0] === "rpc"), ["rpc", "update_application_payment", {
      target_application_id: ID, expected_updated_at: VERSION, target_payment_status: "paid",
      target_payment_due_date: "2028-02-29", change_reason: null,
    }]);
    const base = kind === "camp" ? `/staff/camps/${CAMP}` : "/staff/community";
    assert.equal(calls.at(-1)[1], `${base}/applications/${ID}?updated=payment-updated`);
    assert.ok(calls.some(c => c[0] === "revalidate" && c[1] === `/user/applications/${ID}`));
    assert.equal(calls.filter(c => c[0] === "rpc").length, 1);
  });
}
for (const [values, code] of [
  [{ applicationId: "bad" }, "invalid-application"], [{ updatedAt: "2026-02-30T00:00:00Z" }, "invalid-version"],
  [{ paymentStatus: "overdue" }, "invalid-payment-status"], [{ paymentDueDate: "2027-02-29" }, "invalid-payment-deadline"],
  [{ reason: "あ".repeat(2001) }, "reason-too-long"],
]) test(`payment rejects ${code} before RPC`, async () => {
  const { api, calls } = await harness(actionPath);
  const output = await api.updateApplicationPayment(form(values));
  assert.equal(output.error, code);
  assert.deepEqual(copy(output.fields), { ...fields, ...values });
  assert.ok(!calls.some(c => ["rpc", "revalidate", "redirect"].includes(c[0])));
});
for (const [error, code] of [[{ message: "reason-required" }, "reason-required"], [{ code: "42501" }, "forbidden"],
  [{ code: "40001" }, "stale-update"], [{ code: "40P01" }, "stale-update"], [{ message: "private SQL", details: "secret" }, "update-failed"]]) {
  test(`payment DB failure ${code} preserves input and never retries`, async () => {
    const { api, calls } = await harness(actionPath, { response: { error } });
    const output = await api.updateApplicationPayment(form());
    assert.equal(output.error, code);
    assert.ok(!JSON.stringify(output).includes("secret"));
    assert.equal(calls.filter(c => c[0] === "rpc").length, 1);
    assert.ok(!calls.some(c => ["revalidate", "redirect"].includes(c[0])));
  });
}
test("empty deadline becomes null; unpaid reason retained", async () => {
  const { api, calls } = await harness(actionPath, { response: { data: result("camp") } });
  await assert.rejects(api.updateApplicationPayment(form({ paymentDueDate: "", paymentStatus: "unpaid", reason: "訂正" })), /REDIRECT/);
  assert.equal(calls.find(c => c[0] === "rpc")[2].target_payment_due_date, null);
  assert.equal(calls.find(c => c[0] === "rpc")[2].change_reason, "訂正");
});
for (const data of [null, [], [{ ...result("camp")[0], result_id: OTHER_ID }], [{ ...result("camp")[0], result_camp_id: "bad" }]]) {
  test(`malformed success fails closed ${JSON.stringify(data)}`, async () => {
    const { api, calls } = await harness(actionPath, { response: { data } });
    assert.equal((await api.updateApplicationPayment(form())).error, "update-failed");
    assert.ok(!calls.some(c => ["revalidate", "redirect"].includes(c[0])));
  });
}
for (const method of ["getApplicationPayment", "getStaffApplicationPayment"]) {
  test(`${method}: auth boundary and field allowlist`, async () => {
    const data = { id: ID, usage_type: "camp", camp_id: CAMP, status: "approved", updated_at: VERSION,
      audit_logs: ["private"], charge: { total_amount: 600, payment_status: "unpaid", payment_due_date: "2000-01-01", reason: "private", months: [{ amount: 600, secret: "private" }] } };
    const { api, calls } = await harness(queriesPath, { response: { data } });
    const output = await api[method](ID);
    assert.equal(output.error, null);
    assert.equal(output.application.charge.is_overdue, true);
    assert.ok(!JSON.stringify(output).includes("private"));
    assert.equal(calls.filter(c => c[0] === "rpc").length, 1);
  });
  test(`${method}: denied guard prevents RPC`, async () => {
    const { api, calls } = await harness(queriesPath, { denied: true });
    await assert.rejects(api[method](ID), /AUTH_REDIRECT/);
    assert.equal(calls.length, 1);
  });
}
test("action guard runs even for invalid input", async () => {
  const { api, calls } = await harness(actionPath, { denied: true });
  await assert.rejects(api.updateApplicationPayment(form({ applicationId: "bad" })), /AUTH_REDIRECT/);
  assert.equal(calls.length, 1);
});
test("overdue starts at JST midnight following deadline; leap day, paid and null", async () => {
  const { api } = await harness(validationPath);
  const charge = { payment_status: "unpaid", payment_due_date: "2028-02-29" };
  assert.equal(api.isPaymentOverdue(charge, new Date("2028-02-29T14:59:59.999Z")), false);
  assert.equal(api.isPaymentOverdue(charge, new Date("2028-02-29T15:00:00Z")), true);
  assert.equal(api.isPaymentOverdue({ ...charge, payment_status: "paid" }, new Date("2028-03-01T15:00:00Z")), false);
  assert.equal(api.isPaymentOverdue({ ...charge, payment_due_date: null }), false);
  assert.equal(api.isPaymentOverdue(null), false);
});
test("existing community detail adds overdue without exposing internal fields", async () => {
  const { api } = await harness("utils/community-applications/queries.js", { response: { data: {
    id: ID, fields: {}, charge: { total_amount: 600, payment_status: "unpaid", payment_due_date: "2000-01-01", months: [], reason: "private" },
  } } });
  const output = await api.getCommunityApplication(ID);
  assert.equal(output.application.charge.is_overdue, true);
  assert.ok(!JSON.stringify(output).includes("private"));
});

const stayPreview = (status = "before_move_in") => ({ id: ID, usage_type: "camp", camp_id: CAMP,
  updated_at: VERSION, status: "approved", stay: { status } });
for (const [method, operation, before, after] of [["checkInApplication", "check_in", "before_move_in", "staying"],
  ["checkOutApplication", "check_out", "staying", "moved_out"]]) {
  for (const kind of ["camp", "community_individual"]) test(`stay ${method} ${kind}: fixed operation, precise version, no user timestamps`, async () => {
    const { api, calls } = await harness(actionPath, { rpcResponses: {
      get_application_stay: { data: stayPreview(before) },
      update_application_stay: { data: [{ ...result(kind)[0], result_status: after }] },
    } });
    await assert.rejects(api[method](form({ checkedInAt: "2000-01-01", stayAction: "cancel", campId: OTHER_ID })), /REDIRECT/);
    assert.deepEqual(calls[0], ["auth", "staff", "/staff"]);
    assert.deepEqual(calls.find(c => c[1] === "update_application_stay"), ["rpc", "update_application_stay", {
      target_application_id: ID, expected_updated_at: VERSION, stay_action: operation,
    }]);
    const base = kind === "camp" ? `/staff/camps/${CAMP}` : "/staff/community";
    assert.equal(calls.at(-1)[1], `${base}/applications/${ID}?updated=${operation === "check_in" ? "checked-in" : "checked-out"}`);
    for (const path of ["/calendar", "/staff/calendar", `/user/applications/${ID}`]) assert.ok(calls.some(c => c[0] === "revalidate" && c[1] === path));
  });
  test(`stay ${method}: no authority no calls`, async () => {
    const { api, calls } = await harness(actionPath, { denied: true });
    await assert.rejects(api[method](form()), /AUTH_REDIRECT/);
    assert.equal(calls.length, 1);
  });
  for (const [data, code] of [[{ ...stayPreview(before), updated_at: "2026-09-10T12:34:56.123457+00:00" }, "stale-update"],
    [{ ...stayPreview(before), status: "under_review" }, "invalid-status"], [stayPreview("moved_out"), "stay-completed"],
    [stayPreview(null), "invalid-stay"]]) test(`stay ${method}: preflight ${code}`, async () => {
    const { api, calls } = await harness(actionPath, { response: { data } });
    assert.equal((await api[method](form())).error, code);
    assert.equal(calls.filter(c => c[0] === "rpc").length, 1);
    assert.ok(!calls.some(c => ["revalidate", "redirect"].includes(c[0])));
  });
  for (const [error, code] of [[{ message: "stale-update" }, "stale-update"], [{ code: "40001" }, "stale-update"],
    [{ code: "40P01" }, "stale-update"], [{ code: "42501" }, "forbidden"], [{ message: "outside-stay-period" }, "outside-stay-period"],
    [{ message: "internal SQL", details: "private" }, "update-failed"]]) test(`stay ${method}: atomic RPC failure ${code}`, async () => {
    const { api, calls } = await harness(actionPath, { rpcResponses: {
      get_application_stay: { data: stayPreview(before) }, update_application_stay: { error },
    } });
    const output = await api[method](form());
    assert.equal(output.error, code);
    assert.deepEqual(copy(output.fields), { applicationId: ID, updatedAt: VERSION });
    assert.ok(!JSON.stringify(output).includes("private"));
    assert.equal(calls.filter(c => c[1] === "update_application_stay").length, 1);
    assert.ok(!calls.some(c => ["revalidate", "redirect"].includes(c[0])));
  });
  test(`stay ${method}: malformed success rejected`, async () => {
    const { api, calls } = await harness(actionPath, { rpcResponses: {
      get_application_stay: { data: stayPreview(before) }, update_application_stay: { data: [{ ...result("camp")[0], result_status: before }] },
    } });
    assert.equal((await api[method](form())).error, "update-failed");
    assert.ok(!calls.some(c => ["revalidate", "redirect"].includes(c[0])));
  });
}
for (const [input, code] of [[{ applicationId: "bad" }, "invalid-application"], [{ updatedAt: "bad" }, "invalid-version"]]) {
  test(`stay input ${code} rejected before read`, async () => {
    const { api, calls } = await harness(actionPath);
    assert.equal((await api.checkInApplication(form(input))).error, code);
    assert.equal(calls.length, 1);
  });
}
for (const method of ["getApplicationStay", "getStaffApplicationStay"]) {
  test(`stay ${method}: safe allowlist, read only`, async () => {
    const { api, calls } = await harness(queriesPath, { response: { data: { ...stayPreview(),
      start_date: "2026-09-10", end_date: "2026-09-12", audit_logs: ["private"],
      room_allocation: { room_name: "桐", released_from: "2026-09-12", is_current: false, reason: "private" },
    } } });
    const output = await api[method](ID);
    assert.equal(output.application.stay.status, "before_move_in");
    assert.equal(output.application.room_allocation.released_from, "2026-09-12");
    assert.ok(!JSON.stringify(output).includes("private"));
    assert.equal(calls.filter(c => c[0] === "rpc").length, 1);
  });
  test(`stay ${method}: auth rejection`, async () => {
    const { api, calls } = await harness(queriesPath, { denied: true });
    await assert.rejects(api[method](ID), /AUTH_REDIRECT/);
    assert.equal(calls.length, 1);
  });
}

for (const kind of ["camp", "community_individual"]) test(`notes ${kind}: create and edit contract`, async () => {
  for (const noteId of ["", OTHER_ID]) {
    const { api, calls } = await harness(actionPath, { response: { data: [{ ...result(kind)[0], result_note_id: OTHER_ID }] } });
    await assert.rejects(api.saveApplicationStaffNote(form({ body: "内部メモ", noteId, authorUserId: USER })), /REDIRECT/);
    assert.deepEqual(calls[0],["auth","staff","/staff"]);
    assert.deepEqual(calls.find(c => c[0]==="rpc"),["rpc","save_application_staff_note",{
      target_application_id:ID,expected_updated_at:VERSION,target_note_id:noteId || null,note_body:"内部メモ",
    }]);
    assert.ok(calls.at(-1)[1].endsWith("?updated=note-saved"));
    assert.ok(!calls.at(-1)[1].includes("内部メモ"));
  }
});
for (const [input, code] of [[{ applicationId:"bad" },"invalid-application"],[{ updatedAt:"bad" },"invalid-version"],
  [{ noteId:"bad" },"invalid-note"],[{ body:"  " },"note-required"],[{ body:"あ".repeat(2001) },"note-too-long"]]) {
  test(`notes validation ${code}`,async()=>{
    const { api,calls }=await harness(actionPath);
    assert.equal((await api.saveApplicationStaffNote(form({body:"メモ",noteId:"",...input}))).error,code);
    assert.ok(!calls.some(c=>c[0]==="rpc"));
  });
}
for(const [error,code] of [[{code:"40001"},"stale-update"],[{code:"40P01"},"stale-update"],
  [{code:"42501"},"forbidden"],[{message:"note-not-found"},"note-not-found"],[{message:"SQL private"},"update-failed"]]) {
  test(`notes DB ${code}`,async()=>{
    const {api,calls}=await harness(actionPath,{response:{error}});
    const output=await api.saveApplicationStaffNote(form({body:"内部メモ",noteId:""}));
    assert.equal(output.error,code);assert.equal(output.fields.body,"内部メモ");
    assert.ok(!JSON.stringify(output).includes("SQL private"));
    assert.equal(calls.filter(c=>c[0]==="rpc").length,1);
    assert.ok(!calls.some(c=>c[0]==="revalidate"));
  });
}
test("notes unauthorized action and getter never return body",async()=>{
  for(const [path,method,arg] of [[actionPath,"saveApplicationStaffNote",form({body:"内部メモ"})],
    [queriesPath,"getStaffApplicationNotes",ID]]) {
    const {api,calls}=await harness(path,{denied:true});
    await assert.rejects(api[method](arg),/AUTH_REDIRECT/);assert.equal(calls.length,1);
  }
});
test("notes getter whitelist; owner payment/stay getters strip injected notes",async()=>{
  const data={...stayPreview(),notes:[{id:OTHER_ID,body:"内部メモ",secret:"hidden"}]};
  const {api}=await harness(queriesPath,{response:{data}});
  assert.equal((await api.getStaffApplicationNotes(ID)).application.notes[0].body,"内部メモ");
  for(const method of ["getApplicationPayment","getApplicationStay"]) {
    assert.ok(!JSON.stringify(await api[method](ID)).includes("内部メモ"));
  }
});
test("audit consent: DB failure compensates uploaded object; submitted old object is retained",async()=>{
  const file=new File([new Uint8Array([0x25,0x50,0x44,0x46,0x2d,0x31])],"consent.pdf",{type:"application/pdf"});
  for(const failed of [false,true]) {
    const {api,calls}=await harness("app/actions/guardian-consent.js",{
      readResponse:{data:{id:ID,usage_type:"camp",status:"revision_requested",submitted_at:VERSION}},
      metadata:failed?{error:{message:"audit storage error"}}:{data:`applications/${ID}/${OTHER_ID}`},
    });
    await assert.rejects(api.uploadGuardianConsent(new Map([["applicationId",ID],["guardianConsentFile",file]])),/REDIRECT/);
    const removals=calls.filter(c=>c[0]==="remove");
    assert.equal(removals.length,failed?1:0);
    if(failed) assert.equal(removals[0][1],`applications/${ID}/${KEY}`);
  }
});
