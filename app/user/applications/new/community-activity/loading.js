import PageShell from "@/app/components/PageShell";

export default function NewCommunityApplicationLoading() {
  return <PageShell title="地域活動の個人申請" description="申請画面を読み込んでいます。">
    <p role="status" aria-live="polite">申請画面を読み込んでいます。</p>
  </PageShell>;
}
