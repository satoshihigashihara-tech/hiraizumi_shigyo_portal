import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const ROOT = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, ROOT), "utf8");

test("staff home and group list expose the group review route", async () => {
  const [home, list, queries] = await Promise.all([
    read("app/staff/page.js"),
    read("app/staff/community/groups/page.js"),
    read("utils/community-groups/staff-queries.js"),
  ]);
  assert.match(home, /href="\/staff\/community\/groups"/);
  assert.match(list, /getStaffCommunityGroups/);
  assert.match(list, /団体名/);
  assert.match(list, /団体状態/);
  assert.match(queries, /requireStaff\("\/staff\/community\/groups"\)/);
  assert.match(queries, /select\(columns\.join\(","\), \{ count: "exact" \}\)/);
});

test("group detail renders the mandatory review order and allowlisted data", async () => {
  const [page, forms, queries] = await Promise.all([
    read("app/staff/community/groups/[groupId]/page.js"),
    read("app/staff/community/groups/[groupId]/GroupReviewForms.js"),
    read("utils/community-groups/staff-queries.js"),
  ]);
  for (const text of ["利用目的の確認", "参加者の審査", "部屋別人数", "団体の最終判断"]) {
    assert.match(`${page}\n${forms}`, new RegExp(text));
  }
  assert.match(page, /getStaffCommunityGroupReview/);
  assert.match(page, /getStaffCommunityGroupCancellation/);
  assert.match(queries, /get_staff_group_review_context/);
  assert.doesNotMatch(`${page}\n${forms}\n${queries}`, /audit_logs|representative_address|emergency_phone/);
});

test("group operation forms connect every staff action with confirmation and room totals", async () => {
  const forms = await read("app/staff/community/groups/[groupId]/GroupReviewForms.js");
  for (const action of [
    "confirmCommunityGroupPurposeState",
    "startCommunityGroupParticipantReviewState",
    "requestCommunityGroupParticipantRevisionState",
    "approveCommunityGroupParticipantState",
    "rejectCommunityGroupParticipantState",
    "setCommunityGroupRoomsState",
    "approveCommunityGroupState",
    "rejectCommunityGroupState",
    "confirmCommunityGroupCancellationState",
    "cancelApprovedCommunityGroupParticipantState",
  ]) assert.match(forms, new RegExp(action));
  assert.match(forms, /name="roomPlan"/);
  assert.match(forms, /name="confirmed"/);
  assert.match(forms, /入力合計 \{total\}人 \/ 対象 \{target\}人/);
  assert.match(forms, /disabled=\{total !== target/);
  assert.match(forms, /useActionState/);
  assert.match(forms, /pendingLabel/);
  assert.doesNotMatch(forms, /—|–/);
});
