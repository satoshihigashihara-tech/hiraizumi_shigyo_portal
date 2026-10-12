export const SESSION_DURATION_MS = 30 * 60 * 1000;
export const WARNING_DURATION_MS = 60 * 1000;
export const ACTIVITY_THROTTLE_MS = 1000;

// The override is server-only. Production always uses the fixed policy.
export function sessionTimeoutMs(nodeEnv, override) {
  if (nodeEnv === "production" || !/^[1-9]\d*$/.test(override ?? "")) {
    return SESSION_DURATION_MS;
  }
  const value = Number(override);
  return Number.isSafeInteger(value) && value >= WARNING_DURATION_MS && value <= SESSION_DURATION_MS
    ? value
    : SESSION_DURATION_MS;
}

export function remainingMs(lastActivity, now, duration) {
  return Math.max(0, lastActivity + duration - now);
}

export function warningStartsAt(lastActivity, duration) {
  return lastActivity + duration - WARNING_DURATION_MS;
}

export function validActivity(raw, now) {
  const value = Number(raw);
  return raw !== null && raw !== "" && Number.isSafeInteger(value) && value > 0 && value <= now
    ? value
    : null;
}

// Supabase updates last_sign_in_at for a new login and keeps it across token refreshes.
export function sessionStorageId(session) {
  const id = session?.user?.id;
  const signedIn = session?.user?.last_sign_in_at;
  return typeof id === "string" && id && typeof signedIn === "string" && signedIn
    ? encodeURIComponent(id + ":" + signedIn)
    : null;
}
