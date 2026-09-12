import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("A5 exposes room-plan editing only for eligible-roster camps", () => {
  const detail = read("app/staff/camps/[campId]/page.js");
  const page = read("app/staff/camps/[campId]/room-plan/page.js");
  assert.match(detail, /room_assignment_mode === "eligible_roster"/);
  assert.match(detail, /room-plan/);
  assert.match(page, /room_assignment_mode !== "eligible_roster"/);
  assert.match(page, /getStaffCampRoomPlan/);
});

test("A5 room-plan form uses stable eligible-user IDs and blocks incomplete or over-capacity saves", () => {
  const form = read("app/staff/camps/[campId]/room-plan/CampRoomPlanForm.js");
  assert.match(form, /eligible_user_id: user\.id/);
  assert.match(form, /room_id: assignments\[user\.id\]/);
  assert.match(form, /unassigned\.length === 0/);
  assert.match(form, /counts\[room\.id\] > room\.capacity/);
  assert.match(form, /pendingLabel="保存中…"/);
  assert.match(form, /stale-update/);
});
