export function destinationForViewer(returnTo, { isActive, isStaff }) {
  if (!isActive) return "/forbidden?reason=account-unavailable";
  if (!returnTo) return isStaff ? "/staff" : "/user";
  if (returnTo === "/staff" || returnTo.startsWith("/staff/")) {
    return isStaff ? returnTo : "/forbidden?reason=staff-only";
  }
  if (returnTo === "/user" || returnTo.startsWith("/user/") ||
      returnTo === "/invite" || returnTo.startsWith("/invite/")) {
    return isStaff ? "/staff" : returnTo;
  }
  return isStaff ? "/staff" : "/user";
}
