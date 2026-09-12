import "server-only";

import { headers } from "next/headers";
import { safeReturnTo } from "@/utils/auth/return-to";

export async function currentReturnTo(fallback) {
  const value = (await headers()).get("x-sg-path");
  return safeReturnTo(value) ?? fallback;
}

