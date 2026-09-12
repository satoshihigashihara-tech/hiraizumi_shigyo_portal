import { redirect } from "next/navigation";
// 戻り先の検証は画面・Server Action と共通の1か所に置く
// （utils/auth/return-to.js）。同じ判定をここへ複製すると、
// 片方だけ直したときに防御がずれる（.claude/rules/security.md）。
import { safeReturnTo } from "@/utils/auth/return-to";
import { getActiveViewer } from "@/utils/auth/session";

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
  const viewer = await getActiveViewer();
  if (!viewer.user) {
    redirect(loginPath(destination));
  }
  if (!viewer.isActive) {
    redirect("/forbidden?reason=account-unavailable");
  }
  return { supabase: viewer.supabase, user: viewer.user };
}

export async function requireStaff(returnTo = "/staff") {
  const destination = safeInternalPath(returnTo, "/staff");
  const viewer = await getActiveViewer();
  if (!viewer.user) redirect(loginPath(destination));
  if (!viewer.isActive) redirect("/forbidden?reason=account-unavailable");
  if (!viewer.isStaff) {
    redirect("/forbidden?reason=staff-only");
  }
  return { supabase: viewer.supabase, user: viewer.user };
}
