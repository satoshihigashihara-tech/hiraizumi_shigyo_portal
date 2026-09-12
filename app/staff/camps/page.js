import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { formatDeadline, formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getStaffCamps } from "@/utils/staff-camps/queries";
import styles from "./camps.module.css";

export const metadata = { title: "キャンプ管理｜ひらいずみ志業ポータル" };

function first(value) { return Array.isArray(value) ? value[0] : value; }

export default async function StaffCampsPage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const result = await getStaffCamps();
  return (
    <PageShell title="キャンプ管理" description="キャンプの利用期間と申請期限を管理します。">
      <div className={styles.actions}><LinkButton href="/staff/camps/new" variant="primary" fullWidthOnMobile>新しいキャンプを作る</LinkButton></div>
      {first(query.updated) === "deleted" && <AlertMessage tone="success" title="キャンプを削除しました" />}
      {result.error ? <AlertMessage tone="error" title="キャンプを読み込めませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>
        : result.camps.length === 0 ? <EmptyState title="登録済みのキャンプはありません" description="新しいキャンプを作成してください。" />
          : <section aria-labelledby="camp-list-title"><h2 id="camp-list-title" className={styles.sectionTitle}>登録済みのキャンプ</h2>
            <ul className={styles.cardList}>{result.camps.map((camp) => <li className={styles.card} key={camp.id}>
              <h3>{camp.name}</h3><dl className={styles.facts}><div><dt>利用期間</dt><dd>{formatPeriod(camp.start_date, camp.end_date)}</dd></div>
                <div><dt>申請期限</dt><dd>{formatDeadline(camp.application_deadline)}</dd></div></dl>
              <LinkButton href={`/staff/camps/${camp.id}`} fullWidthOnMobile>キャンプを確認する</LinkButton>
            </li>)}</ul></section>}
    </PageShell>
  );
}
