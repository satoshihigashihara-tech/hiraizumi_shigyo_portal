"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { destinationForViewer } from "@/utils/auth/destination";
// 戻り先の検証は画面（app/login/page.js）と共通の1か所に置く。
// "use server" のこのファイルは同期関数を export できないため、
// 純粋モジュール側から双方が import する（utils/auth/return-to.js）。
import { safeReturnTo } from "@/utils/auth/return-to";

function getText(formData, name) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function getPassword(formData) {
  const value = formData.get("password");
  return typeof value === "string" ? value : "";
}

function getRawText(formData, name) {
  const value = formData.get(name);
  return typeof value === "string" ? value : "";
}

function loginErrorUrl(code, returnTo) {
  const searchParams = new URLSearchParams({ error: code });

  if (returnTo) {
    searchParams.set("returnTo", returnTo);
  }

  return `/login?${searchParams.toString()}`;
}

function signUpUrl(parameter, code, returnTo) {
  const searchParams = new URLSearchParams({ [parameter]: code });

  if (returnTo) {
    searchParams.set("returnTo", returnTo);
  }

  return `/signup?${searchParams.toString()}`;
}

async function viewerAccess(supabase, userId) {
  const profileRequest = supabase.from("profiles").select("account_state")
    .eq("id", userId).maybeSingle();
  const staffRequest = supabase.from("staff_roles").select("user_id")
    .eq("user_id", userId).maybeSingle();
  const [profile, staff] = await Promise.all([profileRequest, staffRequest]);
  return {
    isActive: !profile.error && profile.data?.account_state === "active",
    isStaff: !staff.error && Boolean(staff.data),
  };
}

export async function login(formData) {
  const email = getText(formData, "email").toLowerCase();
  const password = getPassword(formData);
  const returnTo = safeReturnTo(getRawText(formData, "returnTo"));

  if (!email || !password) {
    redirect(loginErrorUrl("required", returnTo));
  }

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signInWithPassword({
    email,
    password,
  });

  if (error || !data.user) {
    redirect(loginErrorUrl("invalid", returnTo));
  }

  const access = await viewerAccess(supabase, data.user.id);

  revalidatePath("/", "layout");
  redirect(destinationForViewer(returnTo, access));
}

export async function signUp(formData) {
  const email = getText(formData, "email").toLowerCase();
  const password = getPassword(formData);
  const returnTo = safeReturnTo(getRawText(formData, "returnTo"));

  if (!email || !password) {
    redirect(signUpUrl("error", "required", returnTo));
  }

  if (password.length < 6) {
    redirect(signUpUrl("error", "short", returnTo));
  }

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signUp({ email, password });

  if (error || !data.user) {
    redirect(signUpUrl("error", "signup", returnTo));
  }

  if (!data.session) {
    redirect(signUpUrl("notice", "confirm", returnTo));
  }

  revalidatePath("/", "layout");
  const access = await viewerAccess(supabase, data.user.id);
  redirect(destinationForViewer(returnTo, access));
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();

  revalidatePath("/", "layout");
  redirect("/");
}
