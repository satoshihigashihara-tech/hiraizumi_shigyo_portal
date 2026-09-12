import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, root), "utf8");

test("camp detail connects edit and eligible management", async () => {
  const [detail, edit, form, eligible] = await Promise.all([
    read("app/staff/camps/[campId]/page.js"), read("app/staff/camps/[campId]/edit/page.js"),
    read("app/staff/camps/[campId]/CampManagementForms.js"),
    read("app/staff/camps/[campId]/eligible-users/EligibleUserForms.js"),
  ]);
  assert.match(detail, /\/edit/); assert.match(edit, /getStaffCamp/);
  assert.match(form, /updateStaffCampState/); assert.match(form, /deleteStaffCampState/);
  assert.match(form, /name="confirmed"/); assert.match(form, /camp-has-applications|conflicts/);
  assert.match(eligible, /updateCampEligibleUserState/); assert.match(eligible, /disableCampEligibleUserState/);
});

test("eligible actions authorize, validate versions and use fixed RPC contracts", async () => {
  const [actions, validation, migration] = await Promise.all([
    read("app/actions/staff-camps.js"), read("utils/calendar/validation.js"),
    read("supabase/migrations/202609120029_camp_eligible_user_management.sql"),
  ]);
  assert.match(actions, /requireStaff\("\/staff\/camps"\)/);
  assert.match(actions, /update_camp_eligible_user/); assert.match(actions, /disable_camp_eligible_user/);
  assert.match(actions, /fields\.confirmed !== "true"/); assert.match(actions, /isUpdatedAt/);
  assert.match(validation, /eligible-has-application/); assert.match(validation, /eligible-email-exists/);
  assert.match(migration, /lower\(btrim\(coalesce\(a\.email_snapshot/);
  assert.match(migration, /private\.check_calendar_version/); assert.match(migration, /audit_logs/);
});

test("camp completion UI keeps existing public-service layout and mobile containment", async () => {
  const [css, forms] = await Promise.all([
    read("app/staff/camps/camps.module.css"),
    read("app/staff/camps/[campId]/CampManagementForms.js"),
  ]);
  assert.match(css, /max-width:599px/); assert.match(css, /dangerZone/); assert.match(css, /errorFocus:focus/);
  assert.doesNotMatch(forms, /—|–/); assert.doesNotMatch(css, /100vh|h-screen/);
});
