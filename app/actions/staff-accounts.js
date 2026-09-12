"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";
import { accountDisableFailure, readAccountDisableFields, validateAccountDisable } from "@/utils/account-cleanup/validation";

export async function disableUserAccountState(_previousState, formData) {
  const { supabase } = await requireStaff("/staff");
  const fields = readAccountDisableFields(formData);
  const invalid = validateAccountDisable(fields);
  if (invalid) return accountDisableFailure(invalid, fields);

  const { data: application, error: applicationError } = await supabase
    .from("applications")
    .select("id,user_id,usage_type,camp_id,status")
    .eq("id", fields.applicationId)
    .maybeSingle();
  if (applicationError || !application || !["rejected", "cancelled"].includes(application.status)) {
    return accountDisableFailure("invalid-application", fields);
  }

  const path = application.usage_type === "camp" && application.camp_id
    ? `/staff/camps/${application.camp_id}/applications/${application.id}`
    : application.usage_type === "community_individual" && application.camp_id === null
      ? `/staff/community/applications/${application.id}`
      : null;
  if (!path || typeof application.user_id !== "string") {
    return accountDisableFailure("invalid-application", fields);
  }

  const { data, error } = await supabase.rpc("disable_user_account", {
    target_user_id: application.user_id,
    disable_reason: fields.reason,
  });
  if (error) return accountDisableFailure(error, fields);
  if (data !== true) return accountDisableFailure("update-failed", fields);
  revalidatePath("/staff");
  revalidatePath("/staff/applications");
  revalidatePath(path);
  redirect(`${path}?updated=account-disabled`);
}
