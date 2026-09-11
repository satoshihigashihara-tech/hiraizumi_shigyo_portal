import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("user application list uses active-user RLS query and fixed owner filter", () => {
  const query = read("utils/user-applications/queries.js");
  assert.match(query, /requireActiveUser\("\/user\/applications"\)/);
  assert.match(query, /\.eq\("user_id", user\.id\)/);
  assert.doesNotMatch(query, /service_role|SUPABASE_SECRET_KEY/);
  assert.match(query, /detail_path: row\.usage_type === "camp"/);
});

test("user application list removes mock notice and separates three statuses", () => {
  const page = read("app/user/applications/page.js");
  assert.doesNotMatch(page, /MockDataNotice|MOCK_APPLICATION_LIST|mock-data/);
  assert.match(page, /kind="application"/);
  assert.match(page, /kind="payment"/);
  assert.match(page, /kind="stay"/);
  assert.match(page, /申請はまだありません/);
  assert.match(page, /申請を読み込めませんでした/);
});
