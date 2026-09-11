// Run: node --experimental-vm-modules --test tests/camp-edit.test.mjs
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const APPLICATION_ID = "10000000-0000-4000-8000-000000000001";
const USER_ID = "10000000-0000-4000-8000-000000000002";

const BASE_FIELDS = {
  applicationId: APPLICATION_ID,
  applicantName: "架空 利用者",
  applicantAddress: "架空住所1番地",
  applicantPhone: "000-0000-0000",
  emergencyContactName: "架空 連絡先",
  emergencyContactAddress: "架空住所2番地",
  emergencyContactPhone: "000-1111-2222",
  usagePlace: "common_and_second_floor",
  usagePurpose: "キャンプ参加中の滞在",
  notes: "",
  guardianConsentRequired: "false",
  requestedRoomPreference: "shared_ok",
  intent: "save",
};

const form = (overrides = {}) =>
  new Map(Object.entries({ ...BASE_FIELDS, ...overrides }));
const copy = (value) => JSON.parse(JSON.stringify(value));

async function loadAction({ rpcError = null, rpcData = APPLICATION_ID, denied = false, consent = null } = {}) {
  const calls = [];
  const supabase = {
    async rpc(name, args) {
      calls.push(["rpc", name, copy(args)]);
      return { data: rpcData, error: rpcError };
    },
    from(table) {
      calls.push(["from", table]);
      return {
        select(columns) {
          calls.push(["select", columns]);
          return this;
        },
        eq(...args) {
          calls.push(["eq", ...args]);
          return this;
        },
        async maybeSingle() {
          return { data: consent, error: null };
        },
      };
    },
  };
  const authError = new Error("AUTH_REDIRECT");
  const context = vm.createContext({ URLSearchParams });
  const stubs = {
    "next/cache": {
      revalidatePath(...args) {
        calls.push(["revalidate", ...args]);
      },
    },
    "next/navigation": {
      redirect(url) {
        calls.push(["redirect", url]);
        throw Object.assign(new Error("REDIRECT"), { url });
      },
    },
    "@/utils/auth/guards": {
      async requireActiveUser(path) {
        calls.push(["auth", path]);
        if (denied) throw authError;
        return { supabase, user: { id: USER_ID } };
      },
    },
    "@/utils/supabase/server": {
      async createClient() {
        return supabase;
      },
    },
  };
  const cache = new Map();

  async function load(specifier) {
    if (cache.has(specifier)) return cache.get(specifier);
    const loaded = Object.hasOwn(stubs, specifier)
      ? new vm.SyntheticModule(
          Object.keys(stubs[specifier]),
          function () {
            for (const [key, value] of Object.entries(stubs[specifier])) {
              this.setExport(key, value);
            }
          },
          { context, identifier: specifier },
        )
      : new vm.SourceTextModule(
          await readFile(
            new URL(
              specifier.startsWith("@/")
                ? `${specifier.slice(2)}.js`
                : specifier,
              ROOT,
            ),
            "utf8",
          ),
          { context, identifier: specifier },
        );
    cache.set(specifier, loaded);
    await loaded.link(load);
    return loaded;
  }

  const loaded = await load("@/app/actions/camp-applications");
  await loaded.evaluate();
  return { api: loaded.namespace, calls, authError };
}

test("camp edit authorizes before reading input and saves the exact RPC allowlist", async () => {
  const { api, calls } = await loadAction();
  await assert.rejects(
    api.saveCampApplicationDraft(null, form()),
    /REDIRECT/,
  );
  assert.equal(calls[0][0], "auth");
  const rpc = calls.find((call) => call[0] === "rpc");
  assert.deepEqual(rpc, [
    "rpc",
    "save_camp_application_draft",
    {
      target_application_id: APPLICATION_ID,
      applicant_name: BASE_FIELDS.applicantName,
      applicant_address: BASE_FIELDS.applicantAddress,
      applicant_phone: BASE_FIELDS.applicantPhone,
      emergency_contact_name: BASE_FIELDS.emergencyContactName,
      emergency_contact_address: BASE_FIELDS.emergencyContactAddress,
      emergency_contact_phone: BASE_FIELDS.emergencyContactPhone,
      usage_purpose: BASE_FIELDS.usagePurpose,
      notes: "",
      guardian_consent_required: false,
      requested_room_preference: "shared_ok",
    },
  ]);
  assert.equal(calls.at(-1)[1], `/user/applications/${APPLICATION_ID}/edit?saved=1`);
});

test("camp edit blocks unauthenticated input before parsing or database access", async () => {
  const { api, calls, authError } = await loadAction({ denied: true });
  await assert.rejects(
    api.saveCampApplicationDraft(null, null),
    (error) => error === authError,
  );
  assert.deepEqual(calls, [["auth", "/user/applications"]]);
});

test("confirm reports required and phone errors beside fields without losing input", async () => {
  const { api, calls } = await loadAction();
  const result = copy(
    await api.saveCampApplicationDraft(
      null,
      form({
        applicantName: "",
        applicantPhone: "abc",
        guardianConsentRequired: "",
        requestedRoomPreference: "",
        intent: "confirm",
      }),
    ),
  );
  assert.equal(result.fields.usagePurpose, BASE_FIELDS.usagePurpose);
  assert.equal(result.fieldErrors.applicantName, "required-fields");
  assert.equal(result.fieldErrors.applicantPhone, "invalid-phone");
  assert.equal(result.fieldErrors.guardianConsentRequired, "required-fields");
  assert.equal(result.fieldErrors.requestedRoomPreference, "required-fields");
  assert.ok(!calls.some((call) => call[0] === "rpc"));
});

test("draft permits incomplete personal fields but rejects forged fixed choices", async () => {
  const { api, calls } = await loadAction();
  const result = copy(
    await api.saveCampApplicationDraft(
      null,
      form({
        applicantName: "",
        applicantAddress: "",
        usagePlace: "private_room_1",
      }),
    ),
  );
  assert.equal(result.error, "invalid-place");
  assert.equal(result.fieldErrors.usagePlace, "invalid-place");
  assert.ok(!calls.some((call) => call[0] === "rpc"));
});

test("database failures preserve safe fields and never redirect", async () => {
  const { api, calls } = await loadAction({
    rpcError: { code: "P0001", message: "現在の状態では申請を編集できません。", details: "PRIVATE" },
  });
  const result = copy(await api.saveCampApplicationDraft(null, form()));
  assert.equal(result.error, "not-editable");
  assert.equal(result.fields.applicantName, BASE_FIELDS.applicantName);
  assert.ok(!JSON.stringify(result).includes("PRIVATE"));
  assert.ok(!calls.some((call) => call[0] === "redirect"));
});

test("confirm requires an uploaded consent document only when the applicant needs one", async () => {
  const { api, calls } = await loadAction();
  const result = copy(
    await api.saveCampApplicationDraft(
      null,
      form({ guardianConsentRequired: "true", intent: "confirm" }),
    ),
  );
  assert.equal(result.error, "guardian-consent");
  assert.equal(result.fieldErrors.guardianConsentFile, "file-required");
  assert.ok(calls.some((call) => call[0] === "rpc"));
  assert.ok(calls.some((call) => call[0] === "from"));
  assert.ok(!calls.some((call) => call[0] === "redirect"));
});

test("camp submission requires the explicit confirmation and never trusts URL receipt data", async () => {
  const { api, calls } = await loadAction();
  await assert.rejects(
    api.submitCampApplication(form({ confirmed: "" })),
    (error) =>
      error.url ===
      `/user/applications/${APPLICATION_ID}/confirm?error=confirmation-required`,
  );
  assert.equal(calls[0][0], "auth");
  assert.ok(!calls.some((call) => call[0] === "rpc"));
});

test("camp submission validates the database result and opens a query-free completion URL", async () => {
  const { api, calls } = await loadAction({
    rpcData: [
      {
        submitted_application_id: APPLICATION_ID,
        reception_number: "SG-2026-0007",
        submission_time: "2026-09-12T01:02:03.000000+00:00",
      },
    ],
  });
  await assert.rejects(
    api.submitCampApplication(form({ confirmed: "true" })),
    (error) =>
      error.url === `/user/applications/${APPLICATION_ID}/complete`,
  );
  assert.ok(calls.some((call) => call[0] === "rpc"));
  assert.ok(!calls.at(-1)[1].includes("?"));
});

test("camp submission authenticates before reading untrusted form input", async () => {
  const { api, calls, authError } = await loadAction({ denied: true });
  await assert.rejects(
    api.submitCampApplication(null),
    (error) => error === authError,
  );
  assert.deepEqual(calls, [["auth", "/user/applications"]]);
});

async function loadQuery(responses) {
  const calls = [];
  const supabase = {
    from(table) {
      calls.push(["from", table]);
      return {
        select(columns) {
          calls.push(["select", table, columns]);
          return this;
        },
        eq(...args) {
          calls.push(["eq", table, ...args]);
          return this;
        },
        async maybeSingle() {
          return responses[table];
        },
      };
    },
  };
  const context = vm.createContext({ URL, Date });
  const stubs = {
    "server-only": {},
    "@/utils/auth/guards": {
      async requireActiveUser(path) {
        calls.push(["auth", path]);
        return { supabase, user: { id: USER_ID } };
      },
    },
  };
  const cache = new Map();
  async function load(specifier) {
    if (cache.has(specifier)) return cache.get(specifier);
    const loaded = Object.hasOwn(stubs, specifier)
      ? new vm.SyntheticModule(
          Object.keys(stubs[specifier]),
          function () {
            for (const [key, value] of Object.entries(stubs[specifier])) {
              this.setExport(key, value);
            }
          },
          { context, identifier: specifier },
        )
      : new vm.SourceTextModule(
          await readFile(
            new URL(`${specifier.slice(2)}.js`, ROOT),
            "utf8",
          ),
          { context, identifier: specifier },
        );
    cache.set(specifier, loaded);
    await loaded.link(load);
    return loaded;
  }
  const loaded = await load("@/utils/camp-applications/queries");
  await loaded.evaluate();
  return { api: loaded.namespace, calls };
}

function completeQueryResponses({ status = "draft", submitted = false } = {}) {
  return {
    applications: {
      data: {
        id: APPLICATION_ID,
        status,
        start_date: "2026-09-30",
        end_date: "2026-10-02",
        user_name: "架空 利用者",
        user_address: "架空住所1番地",
        user_phone: "000-0000-0000",
        emergency_name: "架空 連絡先",
        emergency_address: "架空住所2番地",
        emergency_phone: "000-1111-2222",
        usage_place: "common_and_second_floor",
        purpose: "キャンプ参加中の滞在",
        special_notes: null,
        requires_guardian_consent: false,
        room_preference: "shared_ok",
        revision_due_at: null,
        decision_reason: null,
        submitted_at: submitted ? "2026-09-12T01:02:03.000000+00:00" : null,
        last_submitted_at: submitted ? "2026-09-12T01:02:03.000000+00:00" : null,
        updated_at: "2026-09-12T01:02:03.000000+00:00",
        camps: {
          name: "動作確認キャンプ（架空）",
          start_date: "2026-09-30",
          end_date: "2026-10-02",
        },
      },
      error: null,
    },
    profiles: {
      data: {
        full_name: "架空 利用者",
        address: "架空住所1番地",
        phone: "000-0000-0000",
        emergency_name: "架空 連絡先",
        emergency_address: "架空住所2番地",
        emergency_phone: "000-1111-2222",
      },
      error: null,
    },
    consent_documents: { data: null, error: null },
    reception_numbers: {
      data: submitted ? { display_number: "SG-2026-0007" } : null,
      error: null,
    },
  };
}

test("camp edit query scopes to the owner and uses profile defaults only for a new draft", async () => {
  const { api, calls } = await loadQuery({
    applications: {
      data: {
        id: APPLICATION_ID,
        status: "draft",
        start_date: "2026-10-01",
        end_date: "2026-10-14",
        user_name: null,
        user_address: null,
        user_phone: null,
        emergency_name: null,
        emergency_address: null,
        emergency_phone: null,
        usage_place: null,
        purpose: null,
        special_notes: null,
        requires_guardian_consent: null,
        room_preference: null,
        revision_due_at: null,
        decision_reason: null,
        submitted_at: null,
        last_submitted_at: null,
        updated_at: "2026-09-12T00:00:00.000000+00:00",
        camps: {
          name: "動作確認キャンプ（架空）",
          start_date: "2026-10-01",
          end_date: "2026-10-14",
        },
      },
      error: null,
    },
    profiles: {
      data: {
        full_name: "架空 利用者",
        address: "架空住所",
        phone: "000-0000-0000",
        emergency_name: "架空 連絡先",
        emergency_address: "架空住所",
        emergency_phone: "000-1111-2222",
      },
      error: null,
    },
    consent_documents: { data: null, error: null },
    reception_numbers: { data: null, error: null },
  });
  const result = copy(await api.getCampApplicationForEdit(APPLICATION_ID));
  assert.equal(result.error, null);
  assert.equal(result.application.fields.applicantName, "架空 利用者");
  assert.equal(
    result.application.fields.usagePlace,
    "common_and_second_floor",
  );
  assert.ok(
    calls.some(
      (call) =>
        call[0] === "eq" &&
        call[1] === "applications" &&
        call[2] === "user_id" &&
        call[3] === USER_ID,
    ),
  );
  const consentProjection = calls.find(
    (call) => call[0] === "select" && call[1] === "consent_documents",
  )[2];
  assert.ok(!consentProjection.includes("object_path"));
});

test("camp confirmation reads saved data and calculates each calendar month on the server", async () => {
  const { api } = await loadQuery(completeQueryResponses());
  const result = copy(await api.getCampApplicationForConfirm(APPLICATION_ID));
  assert.equal(result.error, null);
  assert.deepEqual(result.application.estimatedCharge, {
    months: [
      {
        month: "2026-09-01",
        usageDays: 1,
        dailyRate: 300,
        monthlyCap: 9000,
        amount: 300,
      },
      {
        month: "2026-10-01",
        usageDays: 2,
        dailyRate: 300,
        monthlyCap: 9000,
        amount: 600,
      },
    ],
    totalAmount: 900,
  });
});

test("camp completion reads the receipt and submission time from the database", async () => {
  const { api, calls } = await loadQuery(
    completeQueryResponses({ status: "submitted", submitted: true }),
  );
  const result = copy(await api.getCampApplicationForComplete(APPLICATION_ID));
  assert.equal(result.error, null);
  assert.equal(result.application.receptionNumber, "SG-2026-0007");
  assert.equal(
    result.application.lastSubmittedAt,
    "2026-09-12T01:02:03.000000+00:00",
  );
  assert.ok(
    calls.some(
      (call) =>
        call[0] === "select" && call[1] === "reception_numbers",
    ),
  );
});

test("camp edit page keeps the server page and isolates only form state on the client", async () => {
  const page = await readFile(
    new URL("../app/user/applications/[applicationId]/edit/page.js", import.meta.url),
    "utf8",
  );
  const client = await readFile(
    new URL("../app/user/applications/[applicationId]/edit/CampApplicationForm.js", import.meta.url),
    "utf8",
  );
  assert.doesNotMatch(page, /^"use client"/);
  assert.match(page, /const \{ applicationId \} = await params/);
  assert.match(client, /^"use client"/);
  assert.match(client, /useActionState/);
  assert.match(client, /document\.getElementById/);
  assert.match(client, /uploadGuardianConsent/);
  assert.match(client, /添付済み/);
  assert.match(client, /accept="application\/pdf,image\/jpeg,image\/png"/);
  assert.doesNotMatch(`${page}\n${client}`, /[—–]/);
});

test("camp confirm and complete routes use awaited params, database values and a guarded submit", async () => {
  const confirmPage = await readFile(
    new URL("../app/user/applications/[applicationId]/confirm/page.js", import.meta.url),
    "utf8",
  );
  const completePage = await readFile(
    new URL("../app/user/applications/[applicationId]/complete/page.js", import.meta.url),
    "utf8",
  );
  const submit = await readFile(
    new URL("../app/user/applications/[applicationId]/confirm/SubmitConfirmation.js", import.meta.url),
    "utf8",
  );
  const styles = await readFile(
    new URL("../app/user/applications/[applicationId]/application-view.module.css", import.meta.url),
    "utf8",
  );

  assert.match(confirmPage, /const \{ applicationId \} = await params/);
  assert.match(completePage, /const \{ applicationId \} = await params/);
  assert.doesNotMatch(completePage, /searchParams|receptionNumber.*query/);
  assert.match(submit, /^"use client"/);
  assert.match(submit, /name="confirmed"/);
  assert.match(submit, /disabled=\{!confirmed\}/);
  assert.match(styles, /@media \(max-width: 599px\)/);
  assert.doesNotMatch(`${confirmPage}\n${completePage}\n${submit}`, /[—–]/);
});
