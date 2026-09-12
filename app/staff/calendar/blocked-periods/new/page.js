import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import BlockedPeriodForm from "../BlockedPeriodForm";

export const metadata = { title: "利用停止期間を作る｜ひらいずみ志業ポータル" };

export default function NewBlockedPeriodPage() {
  return <PageShell title="利用停止期間を作る" description="申請を受け付けない日程と、職員向けの理由を入力します。">
    <BlockedPeriodForm mode="create" />
    <div><LinkButton href="/staff/calendar/blocked-periods">利用停止期間の一覧へ戻る</LinkButton></div>
  </PageShell>;
}
