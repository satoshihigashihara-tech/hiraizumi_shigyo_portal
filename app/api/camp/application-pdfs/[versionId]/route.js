import { deliverCampPdf } from '@/utils/camp-pdfs/server';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function GET(request, context) {
  const { versionId } = await context.params;
  return deliverCampPdf(request, versionId);
}
export async function HEAD(request, context) {
  const { versionId } = await context.params;
  return deliverCampPdf(request, versionId);
}
