import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("user application list uses active-user RLS query and fixed owner filter", () => {
  const query = read("utils/user-applications/queries.js");
  assert.match(query, /loadUserApplications\("\/user\/applications"\)/);
  assert.match(query, /loadUserApplications\("\/user"\)/);
  assert.match(query, /\.eq\("user_id", user\.id\)/);
  assert.doesNotMatch(query, /service_role|SUPABASE_SECRET_KEY/);
  assert.match(query, /const USAGE_TYPES = \["camp", "community_individual", "community_group"\]/);
  assert.match(query, /detail_path: `\/user\/applications\/\$\{row\.id\}`/);
});

test("user home uses the same real owner query without mock data", () => {
  const page = read("app/user/page.js");
  assert.match(page, /getUserHomeApplications/);
  assert.doesNotMatch(page, /MockDataNotice|MOCK_APPLICATIONS|mock-data|searchParams/);
  assert.match(page, /kind="application"/);
  assert.match(page, /kind="payment"/);
  assert.match(page, /kind="stay"/);
  assert.match(page, /申請を読み込めませんでした/);
  assert.match(page, /申請はまだありません/);
  assert.match(page, /\.slice\(0, 3\)/);
});

test("user home respects the normalized owner-scoped detail path", () => {
  const action = read("app/user/next-action.js");
  const page = read("app/user/page.js");
  assert.match(action, /application\.detail_path === null/);
  assert.match(page, /action\.href \?/);
  assert.match(action, /application\.detail_path \?\?/);
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
