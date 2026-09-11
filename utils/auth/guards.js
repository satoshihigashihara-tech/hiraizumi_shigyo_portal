import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function safeInternalPath(value, fallback) {
  if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//")) {
    return fallback;
  }

  try {
    const url = new URL(value, "http://local");
    return `${url.pathname}${url.search}`;
  } catch {
    return fallback;
  }
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
