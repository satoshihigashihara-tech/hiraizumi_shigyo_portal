import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("profile query is protected and selects only the current user", () => {
  const query = read("utils/profile/queries.js");
  assert.match(query, /getUserProfile\(returnTo = "\/user\/profile"\)/);
  assert.match(query, /requireActiveUser\(returnTo\)/);
  assert.match(query, /\.eq\("id", user\.id\)/);
  assert.doesNotMatch(query, /service_role|SUPABASE_SECRET_KEY/);
});

test("profile form uses the existing server action and preserves failed input", () => {
  const action = read("app/actions/profile.js");
  const form = read("app/user/profile/ProfileForm.js");
  assert.match(action, /export async function saveProfileState/);
  assert.match(action, /fieldErrors, fields/);
  assert.match(form, /useActionState\(saveProfileState/);
  assert.match(form, /pendingLabel="保存中…"/);
  for (const name of ["fullName", "address", "phone", "emergencyName", "emergencyAddress", "emergencyPhone"]) {
    assert.match(form, new RegExp(`name="${name}"`));
  }
});

test("profile page provides success, load failure and return navigation", () => {
  const page = read("app/user/profile/page.js");
  assert.match(page, /プロフィールを保存しました/);
  assert.match(page, /プロフィールを読み込めませんでした/);
  assert.match(page, /href="\/user"/);
});
