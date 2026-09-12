import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import { getStaffCamp } from "@/utils/staff-camps/queries";
import { getStaffCampRoomPlan, getStaffCampRoomPlanPdf } from "@/utils/staff-camps/room-plan-queries";
import styles from "../../camps.module.css";
import CampRoomPlanForm from "./CampRoomPlanForm";
import { getStaffCampRoomChange } from "@/utils/staff-camps/review-queries";
import CampRoomChangeForm from "./CampRoomChangeForm";
import CampRoomPlanPdf from "./CampRoomPlanPdf";

export default async function CampRoomPlanPage({ params }) {
  const { campId } = await params;
  const campResult = await getStaffCamp(campId);
  if (campResult.error === "not-found") notFound();
  if (campResult.error) return <PageShell title="事前部屋割り"><AlertMessage tone="error" title="キャンプを読み込めませんでした"><p>{errorMessage(campResult.error)}</p></AlertMessage></PageShell>;

  const camp = campResult.camp;
  if (camp.room_assignment_mode !== "eligible_roster") return <PageShell title="事前部屋割り" description={`${camp.name}の部屋割り`}> 
    <AlertMessage tone="info" title="このキャンプでは事前部屋割りを利用しません"><p>従来方式のキャンプです。対象者名簿による事前部屋割りは編集できません。</p></AlertMessage>
    <LinkButton href={`/staff/camps/${campId}`}>キャンプ詳細へ戻る</LinkButton>
  </PageShell>;

  const planResult = await getStaffCampRoomPlan(campId);
  if (planResult.error === "not-found") notFound();
  const pdfResult = !planResult.error && planResult.plan.complete ? await getStaffCampRoomPlanPdf(campId) : null;
  const changeResult = !planResult.error && planResult.plan.committedAt ? await getStaffCampRoomChange(campId) : null;
  const useReview = changeResult?.context?.users.some((u) => ["submitted", "under_review", "revision_requested", "approved"].includes(u.status));
  return <PageShell title="事前部屋割り" description={`${camp.name}の参加対象者を、確定済みの部屋へ1人ずつ割り当てます。`}>
    {planResult.error ? <AlertMessage tone="error" title="部屋割りを読み込めませんでした"><p>{errorMessage(planResult.error)}</p></AlertMessage>
      : changeResult?.error ? <AlertMessage tone="error" title="変更確認情報を取得できませんでした"><p>画面を再読み込みしてください。</p></AlertMessage>
        : useReview ? <CampRoomChangeForm context={changeResult.context} /> : <CampRoomPlanForm plan={planResult.plan} />}
    {pdfResult?.error && <AlertMessage tone="warning" title="配置表PDFを利用できません"><p>{errorMessage(pdfResult.error)}</p></AlertMessage>}
    {pdfResult?.pdf && <CampRoomPlanPdf pdf={pdfResult.pdf} />}
    <div className={styles.actions}><LinkButton href={`/staff/camps/${campId}/eligible-users`}>対象者名簿を確認する</LinkButton><LinkButton href={`/staff/camps/${campId}`}>キャンプ詳細へ戻る</LinkButton></div>
  </PageShell>;
}
