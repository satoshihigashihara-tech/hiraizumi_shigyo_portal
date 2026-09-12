import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

test("community individual entry is unavailable from the UI and direct access returns to selection", () => {
  const page = read("app/user/applications/new/community-activity/page.js");
  const entry = read("app/user/applications/new/page.js");
  assert.match(page, /import \{ redirect \} from "next\/navigation"/);
  assert.match(page, /redirect\("\/user\/applications\/new"\)/);
  assert.doesNotMatch(page, /createCommunityApplicationDraft\(/);
  assert.doesNotMatch(entry, /地域活動で利用する（個人）|個人申請を始める|community-activity/);
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
  assert.match(query, /USAGE_TYPES\.includes\(data\.usage_type\)/);
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
  assert.match(read("app/page.js"), /href="\/user\?mode=fieldwork"/);
  assert.doesNotMatch(read("app/user/applications/new/page.js"), /地域活動の日程を選ぶ手続きは現在準備中/);
});

test("community cancellation and extension screens use guarded reads and existing actions", () => {
  const cancellationPage = read("app/user/applications/[applicationId]/cancel/page.js");
  const cancellationForm = read("app/user/applications/[applicationId]/cancel/CancellationForm.js");
  const extensionPage = read("app/user/applications/[applicationId]/extension/page.js");
  const extensionForm = read("app/user/applications/[applicationId]/extension/ExtensionForm.js");
  assert.match(cancellationPage, /getCommunityApplicationCancellation/);
  assert.match(cancellationPage, /application\.can_request/);
  assert.match(cancellationForm, /requestCommunityApplicationCancellation/);
  assert.match(cancellationForm, /name="updatedAt"/);
  assert.match(cancellationForm, /useActionState/);
  assert.match(extensionPage, /getCommunityApplicationExtensionSource/);
  assert.match(extensionPage, /application\.can_extend/);
  assert.match(extensionPage, /crypto\.randomUUID\(\)/);
  assert.match(extensionForm, /createCommunityApplicationExtension/);
  assert.match(extensionForm, /name="originalApplicationId"/);
  assert.match(extensionForm, /useActionState/);
});

test("community list and detail identify extensions and expose only available operations", () => {
  const list = read("app/user/applications/page.js");
  const page = read("app/user/applications/[applicationId]/page.js");
  const detail = read("app/user/applications/[applicationId]/CommunityApplicationDetail.js");
  assert.match(list, /row\.original_application_id/);
  assert.match(list, /元の申請を見る/);
  assert.match(page, /kind\.originalApplicationId/);
  assert.match(detail, /cancellation\?\.can_request/);
  assert.match(detail, /extension\?\.can_extend/);
  assert.match(detail, /existing_extension_id/);
});
