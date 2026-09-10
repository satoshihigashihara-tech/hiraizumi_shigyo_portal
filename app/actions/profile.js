"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireActiveUser } from "@/utils/auth/guards";

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

export async function saveProfile(formData) {
  const { supabase, user } = await requireActiveUser("/user/profile");
  const fields = {
    fullName: getText(formData, "fullName"),
    address: getText(formData, "address"),
    phone: getText(formData, "phone"),
    emergencyName: getText(formData, "emergencyName"),
    emergencyAddress: getText(formData, "emergencyAddress"),
    emergencyPhone: getText(formData, "emergencyPhone"),
  };

  const hasLongValue = Object.entries(fields).some(
    ([name, value]) => value.length > FIELD_LIMITS[name],
  );

  if (hasLongValue) {
    redirect(profilePath({ error: "too-long" }));
  }

  if (
    (fields.phone && !PHONE_PATTERN.test(fields.phone)) ||
    (fields.emergencyPhone && !PHONE_PATTERN.test(fields.emergencyPhone))
  ) {
    redirect(profilePath({ error: "invalid-phone" }));
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
    redirect(profilePath({ error: "save-failed" }));
  }

  revalidatePath("/user/profile");
  revalidatePath("/user/applications/new/camp");
  revalidatePath("/user/applications/new/community-activity");
  redirect(profilePath({ saved: "1" }));
}
