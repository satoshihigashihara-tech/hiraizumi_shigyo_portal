import { redirect } from "next/navigation";
// 戻り先の検証は画面・Server Action と共通の1か所に置く
// （utils/auth/return-to.js）。同じ判定をここへ複製すると、
// 片方だけ直したときに防御がずれる（.claude/rules/security.md）。
import { safeReturnTo } from "@/utils/auth/return-to";
import { createClient } from "@/utils/supabase/server";

/**
 * 戻り先を安全な内部パスへ絞る。判定できない値は fallback へ落とす。
 *
 * @param {unknown} value
 * @param {string} fallback
 * @returns {string}
 */
function safeInternalPath(value, fallback) {
  return safeReturnTo(value) ?? fallback;
}

function loginPath(returnTo) {
  const searchParams = new URLSearchParams({ returnTo });
  return `/login?${searchParams.toString()}`;
}

export async function requireActiveUser(returnTo = "/user") {
  const destination = safeInternalPath(returnTo, "/user");
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    redirect(loginPath(destination));
  }

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("id, account_state")
    .eq("id", user.id)
    .maybeSingle();

  if (profileError || !profile || profile.account_state !== "active") {
    redirect("/forbidden?reason=account-unavailable");
  }

  return { supabase, user };
}

export async function requireStaff(returnTo = "/staff") {
  const destination = safeInternalPath(returnTo, "/staff");
  const { supabase, user } = await requireActiveUser(destination);
  const { data: staffRole, error: roleError } = await supabase
    .from("staff_roles")
    .select("user_id")
    .eq("user_id", user.id)
    .maybeSingle();

  if (roleError || !staffRole) {
    redirect("/forbidden?reason=staff-only");
  }

  return { supabase, user };
}
