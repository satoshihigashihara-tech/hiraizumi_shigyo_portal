import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, root), "utf8");

test("A2 roster actions authenticate first and use only the roster RPC contracts", async () => {
  const source = await read("app/actions/staff-camps.js");
  assert.match(source, /createCampRosterEligibleUserState/);
  assert.match(source, /updateCampRosterEligibleUserState/);
  assert.match(source, /requireStaff\("\/staff\/camps"\)/);
  assert.match(source, /create_camp_roster_eligible_user/);
  assert.match(source, /update_camp_roster_eligible_user/);
  assert.match(source, /expected_updated_at: fields\.updatedAt/);
  assert.match(source, /managementNameError/);
  assert.match(source, /result\.result_management_name/);
  assert.match(source, /result\.result_email/);
});

test("A2 UI separates roster and legacy flows without exposing linked identity", async () => {
  const [page, forms, queries, css] = await Promise.all([
    read("app/staff/camps/[campId]/eligible-users/page.js"),
    read("app/staff/camps/[campId]/eligible-users/EligibleUserForms.js"),
    read("utils/staff-camps/queries.js"),
    read("app/staff/camps/camps.module.css"),
  ]);
  assert.match(page, /room_assignment_mode === "eligible_roster"/);
  assert.match(page, /getCampEligibleRoster/);
  assert.match(forms, /mode === "roster"/);
  assert.match(forms, /管理用氏名/);
  assert.match(forms, /復活・再参加は、この画面では行えません/);
  assert.match(forms, /メールを変更しても結合先アカウントは変更されません/);
  assert.match(queries, /is_linked: row\.linked_user_id !== null/);
  assert.doesNotMatch(queries, /linked_user_id: row\.linked_user_id/);
  assert.match(css, /rosterEmail/);
  assert.match(css, /max-width:599px/);
});

test("A2 database migration fixes the mode, duplicate, version, audit, and execute boundaries", async () => {
  const migration = await read("supabase/migrations/202609120031_camp_roster_eligible_user_management.sql");
  assert.match(migration, /room_assignment_mode<>'eligible_roster'/);
  assert.match(migration, /room_assignment_mode<>'legacy_application'/);
  assert.match(migration, /eligible-email-exists/);
  assert.match(migration, /private\.check_calendar_version/);
  assert.match(migration, /private\.check_calendar_reason/);
  assert.match(migration, /create_camp_roster_eligible_user/);
  assert.match(migration, /update_camp_roster_eligible_user/);
  assert.match(migration, /security definer set search_path=''/);
  assert.match(migration, /revoke all on function public\.create_camp_roster_eligible_user/);
  assert.match(migration, /grant execute on function public\.create_camp_roster_eligible_user/);
});
