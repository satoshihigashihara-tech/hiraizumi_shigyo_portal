"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";
import { getText, toTokyoDeadline, reasonError } from "@/utils/calendar/validation";
import { communityFailure, isUuid, isUpdatedAt } from "@/utils/community-applications/validation";

async function review(formData, operation) {
  const { supabase } = await requireStaff("/staff/community/applications");
  const fields = Object.fromEntries(["applicationId", "updatedAt", "reason", "revisionDeadline"].map((key) => [key, getText(formData, key)]));
  if (!isUuid(fields.applicationId)) return communityFailure("invalid-application", fields);
  if (!isUpdatedAt(fields.updatedAt)) return communityFailure("invalid-version", fields);
  const invalidReason = reasonError(fields.reason, operation !== "start_review");
  if (invalidReason) return communityFailure(invalidReason, fields);
  const deadline = operation === "request_revision" && fields.revisionDeadline ? toTokyoDeadline(fields.revisionDeadline) : null;
  if (operation === "request_revision" && fields.revisionDeadline && !deadline) return communityFailure("invalid-deadline", fields);
  const { data, error } = await supabase.rpc("review_community_application", {
    target_application_id: fields.applicationId, expected_updated_at: fields.updatedAt, review_action: operation,
    public_reason: operation === "start_review" ? null : fields.reason, revision_deadline: deadline,
  });
  if (error) return communityFailure(error, fields);
  const result = Array.isArray(data) ? data[0] : null;
  const expectedStatus = { start_review: "under_review", request_revision: "revision_requested", reject: "rejected" }[operation];
  if (result?.result_id !== fields.applicationId || result.result_status !== expectedStatus || !isUpdatedAt(result.result_updated_at)) return communityFailure("update-failed", fields);
  const path = `/staff/community/applications/${fields.applicationId}`;
  for (const route of [path, "/staff", "/staff/community", "/staff/community/applications", "/staff/calendar", "/calendar", "/user", "/user/applications",
    `/user/applications/${fields.applicationId}`, `/user/applications/${fields.applicationId}/edit`, `/user/applications/${fields.applicationId}/confirm`]) revalidatePath(route);
  redirect(`${path}?updated=${result.result_status}`);
}
export async function startCommunityApplicationReview(formData) { return review(formData, "start_review"); }
export async function requestCommunityApplicationRevision(formData) { return review(formData, "request_revision"); }
export async function rejectCommunityApplication(formData) { return review(formData, "reject"); }
