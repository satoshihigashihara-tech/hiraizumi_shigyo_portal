// Phase 1 only: node --experimental-vm-modules --test tests/application-operations-actions.test.mjs
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
