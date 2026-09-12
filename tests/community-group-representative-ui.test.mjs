import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const ROOT = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, ROOT), "utf8");

test("group routes use protected owner queries without creating data on GET", async () => {
  const [home, list, create, edit, confirm, complete, detail] = await Promise.all([
    read("app/user/page.js"),
    read("app/user/groups/page.js"),
    read("app/user/groups/new/page.js"),
    read("app/user/groups/[groupId]/edit/page.js"),
    read("app/user/groups/[groupId]/confirm/page.js"),
    read("app/user/groups/[groupId]/complete/page.js"),
    read("app/user/groups/[groupId]/page.js"),
  ]);
  assert.match(home, /getCommunityGroupsForHome\(\)/);
  assert.match(await read("utils/community-groups/queries.js"), /loadCommunityGroups\(1, "\/user\?mode=fieldwork"\)/);
  assert.match(list, /redirect\(withMode\("\/user", mode\)\)/);
  assert.doesNotMatch(create, /createCommunityGroupDraft\(/);
  for (const [source, mode] of [[edit, "edit"], [confirm, "confirm"], [complete, "complete"], [detail, "detail"]]) {
    assert.match(source, new RegExp(`getCommunityGroup\\(groupId, "${mode}"\\)`));
  }
});

test("group form sends the existing allowlisted field names and preserves errors", async () => {
  const form = await read("app/user/groups/[groupId]/edit/GroupForm.js");
  for (const name of ["groupId", "updatedAt", "groupName", "representativeName",
    "representativeAddress", "representativePhone", "startDate", "endDate",
    "usagePlace", "purpose", "localActivity", "notes", "plannedParticipants",
    "representativeStays", "intent"]) {
    assert.match(form, new RegExp(`name="${name}"`));
  }
  assert.match(form, /useActionState/);
  assert.match(form, /state\?\.fields/);
  assert.match(form, /errorAlertItems/);
  assert.match(form, /pendingLabel=/);
  assert.match(form, /自動保存はされません/);
});

test("group confirmation uses a stable idempotency key and explicit consent", async () => {
  const submit = await read("app/user/groups/[groupId]/confirm/SubmitGroup.js");
  assert.match(submit, /useState\(\(\) => crypto\.randomUUID\(\)\)/);
  assert.match(submit, /name="submissionKey" value=\{submissionKey\}/);
  assert.match(submit, /name="confirmed"/);
  assert.match(submit, /disabled=\{!confirmed\}/);
  assert.match(submit, /startCommunityGroupApplication/);
});

test("group pages show textual state, completion facts and next navigation", async () => {
  const [home, complete, detail, labels] = await Promise.all([
    read("app/user/page.js"),
    read("app/user/groups/[groupId]/complete/page.js"),
    read("app/user/groups/[groupId]/page.js"),
    read("app/components/status-labels.js"),
  ]);
  assert.match(home, /kind="group"/);
  assert.match(complete, /受付番号/);
  assert.match(complete, /参加者提出期限/);
  assert.match(detail, /団体状態の履歴/);
  assert.match(detail, /href=\{`\/user\/groups\/\$\{group\.id\}\/participants`\}/);
  assert.match(labels, /GROUP_STATUS_LABELS/);
});

test("representative invitation screen uses one-time secrets and a minimal participant list", async () => {
  const [page, panel, removal, queries] = await Promise.all([
    read("app/user/groups/[groupId]/participants/page.js"),
    read("app/user/groups/[groupId]/participants/InvitePanel.js"),
    read("app/user/groups/[groupId]/participants/ParticipantRemovalForm.js"),
    read("utils/group-invitations/queries.js"),
  ]);
  assert.match(page, /getCommunityGroupParticipants\(groupId\)/);
  assert.match(page, /participant\.name/);
  assert.doesNotMatch(page, /participant\.(address|phone|emergency|guardian)/);
  assert.match(panel, /issueCommunityGroupInvite/);
  assert.match(panel, /useActionState/);
  assert.match(panel, /invite\?\.groupUpdatedAt/);
  assert.match(panel, /navigator\.clipboard\.writeText/);
  assert.match(panel, /一度だけ表示/);
  assert.match(page, /ParticipantRemovalForm/);
  assert.match(removal, /removeCommunityGroupParticipant/);
  assert.match(removal, /name="reason"/);
  assert.match(removal, /name="confirmed"/);
  assert.match(removal, /新しい招待を発行/);
  assert.match(queries, /\["application_id", "name", "application_status", "is_representative", "joined_at"\]/);
});

test("group detail connects guarded representative cancellation without exposing participant details", async () => {
  const [detail, cancellation] = await Promise.all([
    read("app/user/groups/[groupId]/page.js"),
    read("app/user/groups/[groupId]/GroupCancellationForm.js"),
  ]);
  assert.match(detail, /getCommunityGroupCancellation/);
  assert.match(detail, /cancellationResult\.cancellation\?\.can_request/);
  assert.match(cancellation, /requestCommunityGroupCancellation/);
  assert.match(cancellation, /name="reason"/);
  assert.match(cancellation, /name="confirmed"/);
  assert.doesNotMatch(`${detail}\n${cancellation}`, /participant\.(address|phone|emergency|guardian)/);
});

test("group UI follows existing 8px system and collapses at narrow widths", async () => {
  const [css, layout, home, chooser] = await Promise.all([
    read("app/user/groups/groups.module.css"),
    read("app/user/layout.js"),
    read("app/user/page.js"),
    read("app/user/applications/new/page.js"),
  ]);
  assert.match(css, /var\(--sg-radius, 8px\)/);
  assert.match(css, /@media \(max-width: 599px\)/);
  assert.match(css, /grid-template-columns: 1fr/);
  assert.match(layout, /currentReturnTo/);
  assert.match(home, /href="\/user\/groups\/new\?mode=fieldwork"/);
  assert.match(chooser, /href="\/user\/groups\/new"/);
  assert.doesNotMatch(`${home}\n${chooser}`, /団体.*準備中/);
});
