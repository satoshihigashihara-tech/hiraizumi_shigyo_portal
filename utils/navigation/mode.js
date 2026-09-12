export const MODES = Object.freeze({
  camp: "camp",
  fieldwork: "fieldwork",
});

export function normalizeMode(value) {
  return typeof value === "string" && Object.hasOwn(MODES, value)
    ? MODES[value]
    : null;
}

export function modeForUsageType(usageType) {
  if (usageType === "camp") return MODES.camp;
  if (usageType === "community_group") return MODES.fieldwork;
  return null;
}

export function usageTypeForMode(mode) {
  if (mode === MODES.camp) return "camp";
  if (mode === MODES.fieldwork) return "community_group";
  return null;
}

export function withMode(path, mode) {
  const normalized = normalizeMode(mode);
  if (!normalized || typeof path !== "string" || !path.startsWith("/") || path.startsWith("//")) return path;
  if (/[?&]mode=/.test(path)) {
    return path.replace(/([?&])mode=[^&#]*/, `$1mode=${normalized}`);
  }
  const hashIndex = path.indexOf("#");
  const beforeHash = hashIndex === -1 ? path : path.slice(0, hashIndex);
  const hash = hashIndex === -1 ? "" : path.slice(hashIndex);
  return `${beforeHash}${beforeHash.includes("?") ? "&" : "?"}mode=${normalized}${hash}`;
}

export function modeFromSearchParams(query) {
  const value = query?.mode;
  return normalizeMode(Array.isArray(value) ? null : value);
}
