import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatDeadline, formatJstDateTime } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getCommunityGroup } from "@/utils/community-groups/queries";
import styles from "../../groups.module.css";

export const metadata = { title: "団体申請受付完了｜ひらいずみ志業ポータル" };

export default async function CompleteGroupPage({ params }) {
  const { groupId } = await params;
  const result = await getCommunityGroup(groupId, "complete");
  if (result.error === "not-found") notFound();
  if (result.error || !result.group) return <PageShell title="団体申請の受付結果"><AlertMessage tone="error" title="受付結果を確認できませんでした"><p>{errorMessage(result.error)}</p></AlertMessage><LinkButton href="/user/groups" fullWidthOnMobile>団体一覧へ戻る</LinkButton></PageShell>;
  const group = result.group;
  return <PageShell title="団体申請を受け付けました" description="次に参加者を招待してください。">
    <AlertMessage tone="info" title="この時点では利用は確定していません"><p>参加予定者全員の入力と職員の審査が必要です。</p></AlertMessage>
    <section className={styles.panel} aria-labelledby="group-receipt-heading"><h2 id="group-receipt-heading">受付内容</h2><dl className={styles.facts}>
      <div><dt>受付番号</dt><dd className={styles.reception}>{group.reception_number}</dd></div>
      <div><dt>申請開始日時</dt><dd>{formatJstDateTime(group.submitted_at)}</dd></div>
      <div><dt>参加者提出期限</dt><dd>{formatDeadline(group.participant_due_at)}</dd></div>
      <div><dt>団体状態</dt><dd><StatusBadge kind="group" value={group.status} showKind /></dd></div>
    </dl></section>
    <div className={styles.actions}><LinkButton href={`/user/groups/${group.id}`} variant="primary" fullWidthOnMobile>団体詳細を見る</LinkButton><LinkButton href="/user/groups" fullWidthOnMobile>団体一覧へ戻る</LinkButton></div>
  </PageShell>;
}
