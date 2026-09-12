import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import { getStaffCamp } from "@/utils/staff-camps/queries";
import CampManagementForms from "../CampManagementForms";

function deadlineInput(value) {
  const date = new Date(Date.parse(value) - 60_000);
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Tokyo", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(date).map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`;
}

export default async function StaffCampEditPage({ params }) {
  const { campId } = await params; const result = await getStaffCamp(campId);
  if (result.error === "not-found") notFound();
  if (result.error) return <PageShell title="キャンプを編集"><AlertMessage tone="error" title="キャンプを読み込めませんでした"><p>{errorMessage(result.error)}</p></AlertMessage></PageShell>;
  return <PageShell title="キャンプを編集" description="設定変更の影響を確認してから保存します。">
    <CampManagementForms camp={result.camp} deadlineValue={deadlineInput(result.camp.application_deadline)} />
    <div><LinkButton href={`/staff/camps/${campId}`}>キャンプ詳細へ戻る</LinkButton></div>
  </PageShell>;
}
