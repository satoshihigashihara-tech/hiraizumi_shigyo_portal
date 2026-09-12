import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const ROOT = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, ROOT), "utf8");

test("staff home and calendar connect protected month and day reads", async () => {
  const [home, page, queries] = await Promise.all([
    read("app/staff/page.js"),
    read("app/staff/calendar/page.js"),
    read("utils/calendar/queries.js"),
  ]);
  assert.match(home, /href="\/staff\/calendar"/);
  assert.match(page, /getStaffCalendar\(month\)/);
  assert.match(page, /getStaffCalendarDay\(selectedDate\)/);
  assert.match(page, /閲覧だけでは状態を変更しません/);
  assert.match(queries, /requireStaff\("\/staff\/calendar"\)/);
  assert.doesNotMatch(page, /createStaff|updateStaff|deleteStaff/);
});

test("calendar distinguishes every occupancy type and links to canonical details", async () => {
  const page = await read("app/staff/calendar/page.js");
  for (const type of ["camp", "blocked", "individual", "application", "group"]) {
    assert.match(page, new RegExp(`${type}:|entry_type === "${type}"|includes\\(entry.entry_type\\)`));
  }
  for (const path of ["/staff/camps/", "/staff/community/applications/", "/staff/community/groups/", "/staff/calendar/blocked-periods/"]) {
    assert.ok(page.includes(path));
  }
  assert.match(page, /内部理由/);
  assert.doesNotMatch(page, /address|phone|email|emergency|object_path/);
});

test("blocked period pages use existing actions and retain safe failures", async () => {
  const [list, form, edit, action] = await Promise.all([
    read("app/staff/calendar/blocked-periods/page.js"),
    read("app/staff/calendar/blocked-periods/BlockedPeriodForm.js"),
    read("app/staff/calendar/blocked-periods/[blockedPeriodId]/edit/page.js"),
    read("app/actions/staff-calendar.js"),
  ]);
  assert.match(list, /getStaffBlockedPeriods/);
  assert.match(edit, /getStaffBlockedPeriod/);
  for (const name of ["createStaffBlockedPeriodState", "updateStaffBlockedPeriodState", "deleteStaffBlockedPeriodState"]) {
    assert.match(`${form}\n${action}`, new RegExp(name));
  }
  assert.match(form, /useActionState/);
  assert.match(form, /errorAlertItems/);
  assert.match(form, /ConflictList/);
  assert.match(form, /name="confirmed"/);
  assert.match(form, /itemHrefByField=\{\{ reason: "#delete-reason" \}\}/);
  assert.match(action, /operation === "delete" && fields\.confirmed !== "true"/);
  assert.doesNotMatch(`${list}\n${form}\n${edit}`, /—|–/);
});

test("calendar layout has keyboard focus and narrow screen containment", async () => {
  const css = await read("app/staff/calendar/calendar.module.css");
  assert.match(css, /\.dayLink:focus-visible/);
  assert.match(css, /@media \(max-width: 599px\)/);
  assert.match(css, /grid-template-columns: 1fr/);
  assert.doesNotMatch(css, /h-screen|100vh/);
});
