import { redirect } from "next/navigation";
import { modeFromSearchParams, withMode } from "@/utils/navigation/mode";

export const metadata = { title: "団体申請一覧｜ひらいずみ志業ポータル" };

export default async function GroupsPage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const mode = modeFromSearchParams(query) ?? "fieldwork";
  redirect(withMode("/user", mode));
}
