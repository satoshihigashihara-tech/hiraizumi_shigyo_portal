import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import { getStaffBlockedPeriod } from "@/utils/calendar/queries";
import BlockedPeriodForm from "../../BlockedPeriodForm";

export const metadata = { title: "利用停止期間を編集｜ひらいずみ志業ポータル" };

export default async function EditBlockedPeriodPage({ params }) {
  const { blockedPeriodId } = await params;
  const result = await getStaffBlockedPeriod(blockedPeriodId);
  if (result.error === "not-found") notFound();
  if (result.error) return <PageShell title="利用停止期間を編集"><AlertMessage tone="error" title="利用停止期間を読み込めませんでした"><p>{errorMessage(result.error)}</p></AlertMessage><div><LinkButton href="/staff/calendar/blocked-periods">一覧へ戻る</LinkButton></div></PageShell>;
  return <PageShell title="利用停止期間を編集" description="日程と内部理由を変更できます。変更前に競合を再確認します。">
    <BlockedPeriodForm mode="edit" period={result.period} />
    <div><LinkButton href="/staff/calendar/blocked-periods">利用停止期間の一覧へ戻る</LinkButton></div>
  </PageShell>;
}
