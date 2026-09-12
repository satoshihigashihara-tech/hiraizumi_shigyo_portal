import PageShell from "@/app/components/PageShell";

export default function NewCommunityApplicationLoading() {
  return <PageShell title="申請画面を読み込み中">
    <p role="status" aria-live="polite">申請画面を読み込んでいます。</p>
  </PageShell>;
}
