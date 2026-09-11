"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireStaff } from "@/utils/auth/guards";
import { accountDisableFailure, readAccountDisableFields, validateAccountDisable } from "@/utils/account-cleanup/validation";

export async function disableUserAccount(formData) {
  const { supabase } = await requireStaff("/staff");
  const fields = readAccountDisableFields(formData);
  const invalid = validateAccountDisable(fields);
  if (invalid) return accountDisableFailure(invalid, fields);
  const { data, error } = await supabase.rpc("disable_user_account", {
    target_user_id: fields.userId,
    disable_reason: fields.reason,
  });
  if (error) return accountDisableFailure(error, fields);
  if (data !== true) return accountDisableFailure("update-failed", fields);
  revalidatePath("/staff");
  revalidatePath("/staff/applications");
  redirect("/staff?updated=account-disabled");
}
