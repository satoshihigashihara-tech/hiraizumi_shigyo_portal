import "server-only";

import { cache } from "react";
import { createClient } from "@/utils/supabase/server";

export const getSessionUser = cache(async () => {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();
  return error || !data.user ? { supabase, user: null } : { supabase, user: data.user };
});

export const getActiveViewer = cache(async () => {
  const { supabase, user } = await getSessionUser();
  if (!user) return { supabase, user: null, isActive: false, isStaff: false };

  const profileRequest = supabase.from("profiles").select("id,account_state")
    .eq("id", user.id).maybeSingle();
  const staffRequest = supabase.from("staff_roles").select("user_id")
    .eq("user_id", user.id).maybeSingle();
  const [profileResult, staffResult] = await Promise.all([profileRequest, staffRequest]);

  return {
    supabase,
    user,
    isActive: !profileResult.error && profileResult.data?.account_state === "active",
    isStaff: !staffResult.error && Boolean(staffResult.data),
  };
});

