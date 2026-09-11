import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const ROOT = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, ROOT), "utf8");

test("staff community detail is protected, allowlisted and redirects camp applications", async () => {
  const queries = await read("utils/application-operations/queries.js");
  assert.match(queries, /export async function getStaffCommunityApplicationDetail/);
  assert.match(queries, /await requireStaff\(returnTo\)/);
  assert.match(queries, /row\.usage_type === "camp"/);
  assert.match(queries, /redirectPath: `\/staff\/camps\/\$\{row\.camp_id\}\/applications\/\$\{applicationId\}`/);
  assert.match(queries, /row\.usage_type !== "community_individual"/);
  assert.match(queries, /get_staff_community_application_room_context/);
  assert.match(queries, /get_staff_application_notes/);
  assert.match(queries, /COMMUNITY_DETAIL_FIELDS/);
});

test("staff community page connects all existing individual operations", async () => {
  const [page, forms, actions] = await Promise.all([
    read("app/staff/community/applications/[applicationId]/page.js"),
    read("app/staff/community/applications/[applicationId]/ReviewForms.js"),
    read("app/actions/staff-community-applications.js"),
  ]);
  assert.match(page, /getStaffCommunityApplicationDetail\(applicationId\)/);
  assert.match(page, /if \(result\.redirectPath\) redirect\(result\.redirectPath\)/);
  assert.match(page, /<PaymentForm/);
  assert.match(page, /<StayOperationForm/);
  assert.match(page, /<NoteForm/);
  for (const name of [
    "startCommunityApplicationReviewState",
    "requestCommunityApplicationRevisionState",
    "rejectCommunityApplicationState",
    "assignCommunityApplicationRoomState",
    "approveCommunityApplicationState",
    "confirmCommunityApplicationCancellationState",
  ]) {
    assert.match(forms, new RegExp(name));
    assert.match(actions, new RegExp(`export async function ${name}`));
  }
  assert.match(forms, /useActionState/);
  assert.match(forms, /pendingLabel=/);
  assert.match(forms, /role="alert"/);
});

test("staff community page keeps textual states, labels and narrow-screen layout", async () => {
  const [page, forms, css, loading] = await Promise.all([
    read("app/staff/community/applications/[applicationId]/page.js"),
    read("app/staff/community/applications/[applicationId]/ReviewForms.js"),
    read("app/staff/community/applications/[applicationId]/page.module.css"),
    read("app/staff/community/applications/[applicationId]/loading.js"),
  ]);
  assert.match(page, /<StatusBadge/);
  assert.match(page, /showKind/);
  assert.match(page, /保護者同意書を開く/);
  assert.match(forms, /<FormField/);
  assert.match(css, /@media \(max-width: 599px\)/);
  assert.match(css, /grid-template-columns: 1fr/);
  assert.match(loading, /読み込み中/);
});
