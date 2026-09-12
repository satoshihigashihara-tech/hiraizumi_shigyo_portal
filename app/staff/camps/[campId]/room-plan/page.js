import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import { getStaffCamp } from "@/utils/staff-camps/queries";
import { getStaffCampRoomPlan } from "@/utils/staff-camps/room-plan-queries";
import styles from "../../camps.module.css";
import CampRoomPlanForm from "./CampRoomPlanForm";

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
  return <PageShell title="事前部屋割り" description={`${camp.name}の参加対象者を、確定済みの部屋へ1人ずつ割り当てます。`}>
    {planResult.error ? <AlertMessage tone="error" title="部屋割りを読み込めませんでした"><p>{errorMessage(planResult.error)}</p></AlertMessage>
      : <CampRoomPlanForm plan={planResult.plan} />}
    <div className={styles.actions}><LinkButton href={`/staff/camps/${campId}/eligible-users`}>対象者名簿を確認する</LinkButton><LinkButton href={`/staff/camps/${campId}`}>キャンプ詳細へ戻る</LinkButton></div>
  </PageShell>;
}
