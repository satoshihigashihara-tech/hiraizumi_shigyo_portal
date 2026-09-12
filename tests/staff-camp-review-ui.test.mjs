import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const ROOT = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, ROOT), "utf8");

test("staff search is staff-only, GET-based and links only returned canonical paths", async () => {
  const [page, queries] = await Promise.all([
    read("app/staff/page.js"),
    read("utils/application-operations/queries.js"),
  ]);
  assert.match(page, /await searchParams/);
  assert.match(page, /searchStaffApplications\(input\)/);
  assert.match(page, /name="usageType"/);
  assert.match(page, /method="get"/);
  assert.match(page, /href=\{application\.detail_path\}/);
  assert.match(queries, /export async function searchStaffApplications/);
  assert.match(queries, /await requireStaff\("\/staff"\)/);
});

test("camp review validates both route IDs and keeps parent versions in every mutation", async () => {
  const [page, queries, operations] = await Promise.all([
    read("app/staff/camps/[campId]/applications/[applicationId]/page.js"),
    read("utils/application-operations/queries.js"),
    read("app/staff/camps/[campId]/applications/[applicationId]/OperationForms.js"),
  ]);
  assert.match(queries, /getStaffCampApplicationDetail\(campId, applicationId\)/);
  assert.match(queries, /!isUuid\(campId\) \|\| !isUuid\(applicationId\)/);
  assert.match(queries, /\.eq\("camp_id", campId\)\.eq\("usage_type", "camp"\)/);
  assert.match(page, /name="updatedAt" value=\{application\.updated_at\}/);
  assert.match(operations, /name="updatedAt" value=\{updatedAt\}/g);
  assert.match(page, /startCampApplicationReview/);
  assert.match(page, /assignCampApplicationRoom/);
  assert.match(page, /approveCampApplication/);
  assert.match(operations, /updateApplicationPaymentState/);
  assert.match(operations, /checkInApplicationState/);
  assert.match(operations, /checkOutApplicationState/);
  assert.match(operations, /saveApplicationStaffNoteState/);
});

test("staff UI has textual states, labels, pending feedback and narrow layouts", async () => {
  const [listPage, detailPage, forms, notFound, listCss, detailCss] = await Promise.all([
    read("app/staff/page.js"),
    read("app/staff/camps/[campId]/applications/[applicationId]/page.js"),
    read("app/staff/camps/[campId]/applications/[applicationId]/OperationForms.js"),
    read("app/staff/not-found.js"),
    read("app/staff/page.module.css"),
    read("app/staff/camps/[campId]/applications/[applicationId]/page.module.css"),
  ]);
  assert.match(listPage, /<StatusBadge/);
  assert.match(detailPage, /showKind/);
  assert.match(forms, /<label>/);
  assert.match(forms, /pendingLabel=/);
  assert.match(forms, /role="alert"/);
  assert.match(notFound, /href="\/staff"/);
  assert.match(listCss, /@media\(max-width:599px\)/);
  assert.match(detailCss, /@media\(max-width:599px\)/);
});
