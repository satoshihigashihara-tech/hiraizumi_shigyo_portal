import PageShell from "@/app/components/PageShell";

export default function LoadingCampRoom() {
  return <PageShell title="キャンプの部屋" description="部屋情報を読み込んでいます。">
    <p role="status">読み込み中です。</p>
  </PageShell>;
}
