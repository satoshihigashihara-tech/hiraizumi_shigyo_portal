import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatDeadline, formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getCommunityGroups } from "@/utils/community-groups/queries";
import styles from "./groups.module.css";

export const metadata = { title: "団体申請一覧｜ひらいずみ志業ポータル" };

export default async function GroupsPage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const page = /^\d+$/.test(String(query.page ?? "")) ? Number(query.page) : 1;
  const result = await getCommunityGroups(page);
  return <PageShell title="団体申請" description="代表者として登録した団体申請を確認できます。">
    <div className={styles.actions}><LinkButton href="/user/groups/new" variant="primary" fullWidthOnMobile>団体申請を始める</LinkButton><LinkButton href="/user" fullWidthOnMobile>利用者ホームへ戻る</LinkButton></div>
    {result.error && <AlertMessage tone="error" title="団体申請を読み込めませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>}
    {!result.error && (result.groups.length ? <ul className={styles.list}>{result.groups.map((group) => <li className={styles.card} key={group.id}><h2>{group.group_name || "団体名未設定"}</h2><StatusBadge kind="group" value={group.status} showKind /><dl className={styles.facts}><div><dt>利用期間</dt><dd>{formatPeriod(group.start_date, group.end_date)}</dd></div><div><dt>予定人数</dt><dd>{group.planned_participants}人</dd></div><div><dt>参加者提出期限</dt><dd>{group.participant_due_at ? formatDeadline(group.participant_due_at) : "未設定"}</dd></div></dl><LinkButton href={`/user/groups/${group.id}`} fullWidthOnMobile>団体詳細を見る</LinkButton></li>)}</ul> : <EmptyState title="団体申請はありません" description="団体で利用する場合は、新しい団体申請を始めてください。" />)}
  </PageShell>;
}
