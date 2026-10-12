import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatDeadline, formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getStaffCamp, getCampEligibleRoster, getCampEligibleUsers } from "@/utils/staff-camps/queries";
import CampManagementForms from "./CampManagementForms";
import styles from "../camps.module.css";

function first(value) { return Array.isArray(value) ? value[0] : value; }

export default async function StaffCampPage({ params, searchParams }) {
  const { campId } = await params;
  const query = (await searchParams) ?? {};
  const result = await getStaffCamp(campId);
  if (result.error === "not-found") notFound();
  if (result.error) return <PageShell title="キャンプ詳細"><AlertMessage tone="error" title="キャンプを読み込めませんでした"><p>{errorMessage(result.error)}</p></AlertMessage></PageShell>;
  const camp = result.camp;
  const roster = camp.room_assignment_mode === "eligible_roster"
    ? await getCampEligibleRoster(campId) : await getCampEligibleUsers(campId);
  return <PageShell title={camp.name} description="キャンプの設定と対象者、申請件数を確認します。">
    {first(query.created) === "roster" && <AlertMessage tone="success" title="キャンプと対象者名簿を保存しました"><p>対象者を確認したあと、事前部屋割りを設定できます。</p></AlertMessage>}
    {first(query.updated) === "saved" && <AlertMessage tone="success" title="キャンプ設定を保存しました" />}
    <section className={styles.card} aria-labelledby="settings-title"><h2 id="settings-title">設定内容</h2>
      <dl className={styles.facts}><div><dt>利用期間</dt><dd>{formatPeriod(camp.start_date, camp.end_date)}</dd></div>
        <div><dt>申請期限</dt><dd>{formatDeadline(camp.application_deadline)}</dd></div>
        <div><dt>対象者</dt><dd>{camp.eligible_count}件</dd></div><div><dt>申請</dt><dd>{camp.application_count}件</dd></div></dl>
      <div className={styles.actions}><LinkButton href={`/staff/camps/${camp.id}/eligible-users`} variant="primary" fullWidthOnMobile>{camp.room_assignment_mode === "eligible_roster" ? "対象者名簿を確認・編集する" : "対象者を登録する"}</LinkButton>
        {camp.room_assignment_mode === "eligible_roster" && <LinkButton href={`/staff/camps/${camp.id}/room-plan`} fullWidthOnMobile>事前部屋割りを編集する</LinkButton>}
        <LinkButton href={`/staff/camps/${camp.id}/edit`} fullWidthOnMobile>設定を編集・削除する</LinkButton>
        <LinkButton href="#delete-camp-title" variant="danger" fullWidthOnMobile>キャンプを削除する</LinkButton>
        <LinkButton href={`/staff?usageType=camp&q=${encodeURIComponent(camp.name)}`} fullWidthOnMobile>このキャンプの申請を見る</LinkButton></div>
    </section>
    <section className={styles.card} aria-labelledby="invited-users-title">
      <h2 id="invited-users-title">登録した対象者</h2>
      <p>キャンプ作成時と対象者名簿画面で登録した方を確認できます。</p>
      {roster.error ? <AlertMessage tone="error" title="対象者を読み込めませんでした"><p>{errorMessage(roster.error)}</p></AlertMessage>
        : roster.users.length === 0 ? <p>対象者はまだ登録されていません。</p>
          : <ul className={styles.rosterSummary}>{roster.users.map((member) => <li key={member.id}>
            <strong>{member.management_name || "氏名未登録"}</strong>
            <span>{member.email_normalized}</span>
            <span>{member.disabled_at ? "無効" : member.participation_status === "released" ? "参加終了" : "登録済み"}</span>
            {member.application_status && <StatusBadge kind="application" value={member.application_status} />}
          </li>)}</ul>}
    </section>
    <CampManagementForms camp={camp} deleteOnly />
    <div><LinkButton href="/staff/camps">キャンプ管理へ戻る</LinkButton></div>
  </PageShell>;
}
