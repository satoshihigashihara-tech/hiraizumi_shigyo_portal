import { deliverCampRoomPlanPdf } from '@/utils/camp-pdfs/room-plan-server';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function GET(request, { params }) {
  const { versionId } = await params;
  return deliverCampRoomPlanPdf(request, versionId);
}
export async function HEAD(request, { params }) {
  const { versionId } = await params;
  return deliverCampRoomPlanPdf(request, versionId);
}
