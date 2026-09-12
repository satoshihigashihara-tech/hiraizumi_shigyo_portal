"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireActiveUser } from "@/utils/auth/guards";
import { normalizeMode, withMode } from "@/utils/navigation/mode";

const PHONE_PATTERN = /^[0-9+][0-9() -]{7,19}$/;

const FIELD_LIMITS = {
  fullName: 100,
  address: 500,
  phone: 20,
  emergencyName: 100,
  emergencyAddress: 500,
  emergencyPhone: 20,
};

function getText(formData, name) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function profilePath(values) {
  const searchParams = new URLSearchParams();

  for (const [key, value] of Object.entries(values)) {
    if (value) searchParams.set(key, value);
  }

  const query = searchParams.toString();
  return query ? `/user/profile?${query}` : "/user/profile";
}

function valueOrNull(value) {
  return value || null;
}

async function saveProfileValues(formData, returnState) {
  const { supabase, user } = await requireActiveUser("/user/profile");
  const mode = normalizeMode(getText(formData, "mode"));
  const fields = {
    fullName: getText(formData, "fullName"),
    address: getText(formData, "address"),
    phone: getText(formData, "phone"),
    emergencyName: getText(formData, "emergencyName"),
    emergencyAddress: getText(formData, "emergencyAddress"),
    emergencyPhone: getText(formData, "emergencyPhone"),
  };

  const fieldErrors = {};
  for (const [name, value] of Object.entries(fields)) {
    if (value.length > FIELD_LIMITS[name]) fieldErrors[name] = "too-long";
  }

  if (Object.keys(fieldErrors).length > 0) {
    if (returnState) return { error: "too-long", fieldErrors, fields };
    redirect(withMode(profilePath({ error: "too-long" }), mode));
  }

  if (fields.phone && !PHONE_PATTERN.test(fields.phone)) {
    fieldErrors.phone = "invalid-phone";
  }
  if (fields.emergencyPhone && !PHONE_PATTERN.test(fields.emergencyPhone)) {
    fieldErrors.emergencyPhone = "invalid-phone";
  }
  if (Object.keys(fieldErrors).length > 0) {
    if (returnState) return { error: "invalid-phone", fieldErrors, fields };
    redirect(withMode(profilePath({ error: "invalid-phone" }), mode));
  }

  const { error } = await supabase
    .from("profiles")
    .update({
      full_name: valueOrNull(fields.fullName),
      address: valueOrNull(fields.address),
      phone: valueOrNull(fields.phone),
      emergency_name: valueOrNull(fields.emergencyName),
      emergency_address: valueOrNull(fields.emergencyAddress),
      emergency_phone: valueOrNull(fields.emergencyPhone),
    })
    .eq("id", user.id);

  if (error) {
    if (returnState) return { error: "save-failed", fieldErrors: {}, fields };
    redirect(withMode(profilePath({ error: "save-failed" }), mode));
  }

  revalidatePath("/user/profile");
  revalidatePath("/user/applications/new/camp");
  revalidatePath("/user/applications/new/community-activity");
  redirect(withMode(profilePath({ saved: "1" }), mode));
}

export async function saveProfile(formData) {
  return saveProfileValues(formData, false);
}

export async function saveProfileState(_previousState, formData) {
  return saveProfileValues(formData, true);
}
