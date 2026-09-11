import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import vm from "node:vm";

const ROOT = new URL("../", import.meta.url);
const CAMP_ID = "30000000-0000-4000-8000-000000000001";
const VALID_CAMP = {
  id: CAMP_ID,
  name: "動作確認キャンプ（架空）",
  start_date: "2026-10-01",
  end_date: "2026-10-15",
  application_deadline: "2026-09-21T15:00:00.000000+00:00",
  created_by: "PRIVATE",
};

async function loadQueries(response) {
  const calls = [];
  const query = {
    select(columns) {
      calls.push(["select", columns]);
      return this;
    },
    order(...args) {
      calls.push(["order", ...args]);
      return this;
    },
    then(resolve, reject) {
      return Promise.resolve(response).then(resolve, reject);
    },
  };
  const supabase = {
    from(table) {
      calls.push(["from", table]);
      return query;
    },
  };
  const context = vm.createContext({ URL, Date });
  const stubs = {
    "server-only": {},
    "@/utils/auth/guards": {
      async requireActiveUser(path) {
        calls.push(["auth", path]);
        return { supabase, user: { id: "PRIVATE" } };
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
          await readFile(new URL(specifier.slice(2) + ".js", ROOT), "utf8"),
          { context, identifier: specifier },
        );
    cache.set(specifier, loaded);
    await loaded.link(load);
    return loaded;
  }

  const loadedModule = await load("@/utils/camp-applications/queries");
  await loadedModule.evaluate();
  return { api: loadedModule.namespace, calls };
}

test("eligible camp query authenticates first and returns only approved columns", async () => {
  const { api, calls } = await loadQueries({ data: [VALID_CAMP], error: null });
  const result = JSON.parse(JSON.stringify(await api.getEligibleCamps()));
  assert.equal(calls[0][0], "auth");
  assert.deepEqual(calls[1], ["from", "camps"]);
  assert.deepEqual(calls[2], [
    "select",
    "id,name,start_date,end_date,application_deadline",
  ]);
  assert.equal(result.error, null);
  assert.equal(result.camps.length, 1);
  assert.equal(result.camps[0].name, VALID_CAMP.name);
  assert.ok(!JSON.stringify(result).includes("PRIVATE"));
});

test("eligible camp query keeps the empty state and hides invalid database payloads", async () => {
  for (const response of [
    { data: [], error: null },
    { data: [{ ...VALID_CAMP, id: "bad" }], error: null },
    { data: [VALID_CAMP], error: { message: "PRIVATE" } },
  ]) {
    const { api } = await loadQueries(response);
    const result = JSON.parse(JSON.stringify(await api.getEligibleCamps()));
    if (response.data.length === 0 && !response.error) {
      assert.deepEqual(result, { error: null, camps: [] });
    } else {
      assert.deepEqual(result, { error: "load-failed", camps: [] });
      assert.ok(!JSON.stringify(result).includes("PRIVATE"));
    }
  }
});

test("camp entry pages include required copy and never create a draft during render", async () => {
  const entry = await readFile(new URL("../app/user/applications/new/page.js", import.meta.url), "utf8");
  const camp = await readFile(new URL("../app/user/applications/new/camp/page.js", import.meta.url), "utf8");

  assert.match(entry, /スパルタキャンプで利用する/);
  assert.match(entry, /地域活動で利用する（個人）/);
  assert.match(entry, /団体を作る/);
  assert.match(camp, /利用期間は固定です/);
  assert.match(camp, /受付期間が終了しました。町へ直接お問い合わせください。/);
  assert.match(camp, /action=\{createCampApplicationDraft\}/);
  assert.doesNotMatch(camp, /await createCampApplicationDraft/);
});

test("camp draft creation errors return to the camp selection page", async () => {
  const action = await readFile(new URL("../app/actions/camp-applications.js", import.meta.url), "utf8");
  assert.match(action, /const entryPath = "\/user\/applications\/new\/camp"/);
  assert.match(action, /getAuthenticatedClient\(entryPath\)/);
  assert.match(action, /withQuery\(entryPath, \{\s*error: databaseErrorCode\(error\)/);
});
