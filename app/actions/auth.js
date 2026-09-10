"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function getText(formData, name) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function getPassword(formData) {
  const value = formData.get("password");
  return typeof value === "string" ? value : "";
}

function getSafeReturnTo(value) {
  if (!value || !value.startsWith("/") || value.startsWith("//")) {
    return null;
  }

  try {
    const url = new URL(value, "http://local");
    return `${url.pathname}${url.search}`;
  } catch {
    return null;
  }
}

function loginErrorUrl(code, returnTo) {
  const searchParams = new URLSearchParams({ error: code });

  if (returnTo) {
    searchParams.set("returnTo", returnTo);
  }

  return `/login?${searchParams.toString()}`;
}

function destinationForRole(returnTo, isStaff) {
  if (!returnTo) {
    return isStaff ? "/staff" : "/user";
  }

  if (returnTo === "/staff" || returnTo.startsWith("/staff/")) {
    return isStaff ? returnTo : "/forbidden";
  }

  if (returnTo === "/user" || returnTo.startsWith("/user/")) {
    return isStaff ? "/staff" : returnTo;
  }

  if (returnTo === "/invite" || returnTo.startsWith("/invite/")) {
    return isStaff ? "/staff" : returnTo;
  }

  return isStaff ? "/staff" : "/user";
}

async function userIsStaff(supabase, userId) {
  const { data, error } = await supabase
    .from("staff_roles")
    .select("user_id")
    .eq("user_id", userId)
    .maybeSingle();

  if (error) {
    return false;
  }

  return Boolean(data);
}

export async function login(formData) {
  const email = getText(formData, "email").toLowerCase();
  const password = getPassword(formData);
  const returnTo = getSafeReturnTo(getText(formData, "returnTo"));

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

  const isStaff = await userIsStaff(supabase, data.user.id);

  revalidatePath("/", "layout");
  redirect(destinationForRole(returnTo, isStaff));
}

export async function signUp(formData) {
  const email = getText(formData, "email").toLowerCase();
  const password = getPassword(formData);
  const returnTo = getSafeReturnTo(getText(formData, "returnTo"));

  if (!email || !password) {
    redirect(loginErrorUrl("required", returnTo));
  }

  if (password.length < 6) {
    redirect(loginErrorUrl("short", returnTo));
  }

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signUp({ email, password });

  if (error) {
    redirect(loginErrorUrl("signup", returnTo));
  }

  if (!data.session) {
    redirect(loginErrorUrl("confirm", returnTo));
  }

  revalidatePath("/", "layout");
  redirect(returnTo?.startsWith("/invite/") ? returnTo : "/user");
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();

  revalidatePath("/", "layout");
  redirect("/login");
}
