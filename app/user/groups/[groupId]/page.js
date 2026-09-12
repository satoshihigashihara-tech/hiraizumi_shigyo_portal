import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatDeadline, formatJstDateTime } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { statusLabel } from "@/app/components/status-labels";
import { getCommunityGroup } from "@/utils/community-groups/queries";
import GroupReview from "../GroupReview";
import styles from "../groups.module.css";

export const metadata = { title: "団体申請詳細｜ひらいずみ志業ポータル" };

export default async function GroupDetailPage({ params }) {
  const { groupId } = await params;
  const result = await getCommunityGroup(groupId, "detail");
  if (result.error === "not-found") notFound();
  if (result.error || !result.group) return <PageShell title="団体申請詳細"><AlertMessage tone="error" title="団体申請を開けませんでした"><p>{errorMessage(result.error)}</p></AlertMessage><LinkButton href="/user/groups" fullWidthOnMobile>団体一覧へ戻る</LinkButton></PageShell>;
  const group = result.group;
  return <PageShell title="団体申請詳細" description={group.fields.group_name}>
    <StatusBadge kind="group" value={group.status} showKind />
    {group.status === "collecting" && <AlertMessage tone="info" title="次にすること"><p>参加者を招待する画面は次の実装で接続します。</p>{group.participant_due_at && <p>参加者提出期限：{formatDeadline(group.participant_due_at)}</p>}</AlertMessage>}
    {group.status === "draft" && <AlertMessage tone="info" title="次にすること"><p>団体情報を確認し、申請を開始してください。</p></AlertMessage>}
    {group.reception_number && <section className={styles.panel} aria-labelledby="receipt-heading"><h2 id="receipt-heading">受付情報</h2><dl className={styles.facts}>
      <div><dt>受付番号</dt><dd className={styles.reception}>{group.reception_number}</dd></div>
      <div><dt>申請開始日時</dt><dd>{group.submitted_at ? formatJstDateTime(group.submitted_at) : "未提出"}</dd></div>
      <div><dt>参加者提出期限</dt><dd>{group.participant_due_at ? formatDeadline(group.participant_due_at) : "なし"}</dd></div>
    </dl></section>}
    <GroupReview group={group} />
    <section className={styles.panel} aria-labelledby="history-heading"><h2 id="history-heading">団体状態の履歴</h2>{group.events.length ? <ol className={styles.history}>{group.events.map((event, index) => <li key={`${event.occurred_at}-${index}`}><p>{event.from_status ? `${statusLabel("group", event.from_status)} → ` : ""}<strong>{statusLabel("group", event.to_status)}</strong></p>{event.public_reason && <p>{event.public_reason}</p>}<time dateTime={event.occurred_at}>{formatJstDateTime(event.occurred_at)}</time></li>)}</ol> : <EmptyState title="履歴はまだありません" />}</section>
    <div className={styles.actions}>{group.status === "draft" && <LinkButton href={`/user/groups/${group.id}/edit`} variant="primary" fullWidthOnMobile>団体情報を編集する</LinkButton>}<LinkButton href="/user/groups" fullWidthOnMobile>団体一覧へ戻る</LinkButton></div>
  </PageShell>;
}
