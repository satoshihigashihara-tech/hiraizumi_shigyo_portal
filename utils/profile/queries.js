import "server-only";

import { requireActiveUser } from "@/utils/auth/guards";

const FIELDS = [
  "full_name",
  "address",
  "phone",
  "emergency_name",
  "emergency_address",
  "emergency_phone",
];

function normalizeProfile(data) {
  if (!data || typeof data !== "object" || Array.isArray(data)) return null;
  if (FIELDS.some((name) => data[name] !== null && typeof data[name] !== "string")) {
    return null;
  }
  return {
    fullName: data.full_name ?? "",
    address: data.address ?? "",
    phone: data.phone ?? "",
    emergencyName: data.emergency_name ?? "",
    emergencyAddress: data.emergency_address ?? "",
    emergencyPhone: data.emergency_phone ?? "",
  };
}

export async function getUserProfile(returnTo = "/user/profile") {
  const { supabase, user } = await requireActiveUser(returnTo);
  const { data, error } = await supabase
    .from("profiles")
    .select(FIELDS.join(","))
    .eq("id", user.id)
    .single();
  if (error) return { error: "load-failed", profile: null };
  const profile = normalizeProfile(data);
  return profile
    ? { error: null, profile }
    : { error: "load-failed", profile: null };
}
