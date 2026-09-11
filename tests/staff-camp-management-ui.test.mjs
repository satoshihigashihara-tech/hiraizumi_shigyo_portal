import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("staff camp management pages use protected queries and existing actions", () => {
  const queries = read("utils/staff-camps/queries.js");
  const actions = read("app/actions/staff-camps.js");
  const pages = ["app/staff/camps/page.js", "app/staff/camps/NewCampForm.js", "app/staff/camps/new/page.js",
    "app/staff/camps/[campId]/page.js", "app/staff/camps/[campId]/eligible-users/page.js"].map(read).join("\n");
  assert.match(queries, /requireStaff\("\/staff\/camps"\)/);
  assert.match(queries, /\.eq\("camp_id", campId\)/);
  assert.match(actions, /createStaffCampState/);
  assert.match(pages, /createStaffCampState/);
  assert.match(pages, /addCampEligibleUsers/);
});

test("staff camp management includes pending labels and mobile layout", () => {
  const pages = ["app/staff/camps/NewCampForm.js", "app/staff/camps/[campId]/eligible-users/page.js"].map(read).join("\n");
  const css = read("app/staff/camps/camps.module.css");
  assert.match(pages, /作成中…/);
  assert.match(pages, /登録中…/);
  assert.match(css, /max-width:599px/);
});
