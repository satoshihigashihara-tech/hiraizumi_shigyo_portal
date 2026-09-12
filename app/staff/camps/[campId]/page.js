import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { formatDeadline, formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getStaffCamp } from "@/utils/staff-camps/queries";
import styles from "../camps.module.css";

function first(value) { return Array.isArray(value) ? value[0] : value; }

export default async function StaffCampPage({ params, searchParams }) {
  const { campId } = await params;
  const query = (await searchParams) ?? {};
  const result = await getStaffCamp(campId);
  if (result.error === "not-found") notFound();
  if (result.error) return <PageShell title="キャンプ詳細"><AlertMessage tone="error" title="キャンプを読み込めませんでした"><p>{errorMessage(result.error)}</p></AlertMessage></PageShell>;
  const camp = result.camp;
  return <PageShell title={camp.name} description="キャンプの設定と対象者、申請件数を確認します。">
    {first(query.updated) === "saved" && <AlertMessage tone="success" title="キャンプ設定を保存しました" />}
    <section className={styles.card} aria-labelledby="settings-title"><h2 id="settings-title">設定内容</h2>
      <dl className={styles.facts}><div><dt>利用期間</dt><dd>{formatPeriod(camp.start_date, camp.end_date)}</dd></div>
        <div><dt>申請期限</dt><dd>{formatDeadline(camp.application_deadline)}</dd></div>
        <div><dt>対象者</dt><dd>{camp.eligible_count}件</dd></div><div><dt>申請</dt><dd>{camp.application_count}件</dd></div></dl>
      <div className={styles.actions}><LinkButton href={`/staff/camps/${camp.id}/eligible-users`} variant="primary" fullWidthOnMobile>対象者を登録する</LinkButton>
        <LinkButton href={`/staff/camps/${camp.id}/edit`} fullWidthOnMobile>設定を編集・削除する</LinkButton>
        <LinkButton href={`/staff?usageType=camp&q=${encodeURIComponent(camp.name)}`} fullWidthOnMobile>このキャンプの申請を見る</LinkButton></div>
    </section>
    <div><LinkButton href="/staff/camps">キャンプ管理へ戻る</LinkButton></div>
  </PageShell>;
}
