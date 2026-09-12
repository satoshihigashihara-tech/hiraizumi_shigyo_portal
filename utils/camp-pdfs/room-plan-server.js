import 'server-only';
import { createClient } from '@/utils/supabase/server';
import { isPdfVersionId, MAX_PDF_BYTES, pdfFailure, pdfPrivateHeaders } from './validation';

export async function deliverCampRoomPlanPdf(request, versionId) {
  const method = request.method;
  try {
    const supabase = await createClient();
    const { data: identity, error } = await supabase.auth.getUser();
    if (error || !identity?.user) return pdfFailure(401, method);
    if (!isPdfVersionId(versionId)) return pdfFailure(404, method);
    const { data, error: sessionError } = await supabase.auth.getSession();
    if (sessionError || !data?.session?.access_token) return pdfFailure(401, method);
    const result = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/camp-room-plan-pdf-delivery?versionId=${encodeURIComponent(versionId)}`, {
      method,
      headers: { apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '', authorization: `Bearer ${data.session.access_token}` },
      cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(45000),
    });
    if (result.status !== 200) return pdfFailure([401, 404].includes(result.status) ? result.status : 503, method);
    const length = Number(result.headers.get('content-length'));
    if (result.headers.get('content-type') !== 'application/pdf' || !Number.isSafeInteger(length) || length < 1 || length > MAX_PDF_BYTES) return pdfFailure(503, method);
    const outgoing = { ...pdfPrivateHeaders, 'content-type': 'application/pdf', 'accept-ranges': 'none',
      'content-disposition': `inline; filename="camp-room-plan-${versionId}.pdf"`, 'content-length': String(length) };
    if (method === 'HEAD') return new Response(null, { status: 200, headers: outgoing });
    const bytes = new Uint8Array(await result.arrayBuffer());
    if (bytes.length !== length) return pdfFailure(503, method);
    return new Response(bytes, { status: 200, headers: outgoing });
  } catch { return pdfFailure(503, method); }
}
