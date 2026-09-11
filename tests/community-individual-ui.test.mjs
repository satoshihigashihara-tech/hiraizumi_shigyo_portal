import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("community individual entry creates no draft during render", () => {
  const page = read("app/user/applications/new/community-activity/page.js");
  assert.match(page, /getUserProfile\("\/user\/applications\/new\/community-activity"\)/);
  assert.match(page, /crypto\.randomUUID\(\)/);
  assert.doesNotMatch(page, /createCommunityApplicationDraft\(/);
  assert.match(page, /mode="create"/);
});

test("community form uses the existing guarded actions and complete allowlist", () => {
  const form = read("app/user/applications/[applicationId]/edit/CommunityApplicationForm.js");
  for (const name of ["applicantName", "applicantAddress", "applicantPhone", "emergencyContactName", "emergencyContactAddress", "emergencyContactPhone", "usagePurpose", "localActivity", "notes", "usagePlace", "startDate", "endDate", "guardianConsentRequired"]) {
    assert.match(form, new RegExp(`name="${name}"`));
  }
  assert.match(form, /createCommunityApplicationDraft/);
  assert.match(form, /saveCommunityApplicationDraft/);
  assert.match(form, /useActionState/);
  assert.match(form, /自動保存はされません/);
});

test("shared application routes dispatch only after an owner-scoped type read", () => {
  const query = read("utils/user-applications/queries.js");
  assert.match(query, /getUserApplicationUsageType/);
  assert.match(query, /\.eq\("user_id", user\.id\)/);
  assert.match(query, /\["camp", "community_individual"\]/);
  for (const path of ["edit/page.js", "confirm/page.js", "complete/page.js", "page.js"]) {
    assert.match(read(`app/user/applications/[applicationId]/${path}`), /getUserApplicationUsageType/);
  }
});

test("community confirmation uses version and idempotency fields", () => {
  const page = read("app/user/applications/[applicationId]/confirm/page.js");
  const submit = read("app/user/applications/[applicationId]/confirm/SubmitConfirmation.js");
  assert.match(page, /updatedAt={result\.application\.updated_at}/);
  assert.match(page, /submissionKey={crypto\.randomUUID\(\)}/);
  assert.match(submit, /submitCommunityApplication/);
  assert.match(submit, /name="updatedAt"/);
  assert.match(submit, /name="submissionKey"/);
  assert.match(submit, /useActionState/);
});

test("community detail, receipt and top-level entry are connected", () => {
  const detail = read("app/user/applications/[applicationId]/CommunityApplicationDetail.js");
  assert.match(detail, /申請状態の履歴/);
  assert.match(detail, /料金/);
  assert.match(detail, /許可された部屋と滞在/);
  assert.match(read("app/user/applications/[applicationId]/complete/page.js"), /reception_number/);
  assert.match(read("app/page.js"), /COMMUNITY_LOGIN_HREF/);
  assert.doesNotMatch(read("app/user/applications/new/page.js"), /地域活動の日程を選ぶ手続きは現在準備中/);
});
