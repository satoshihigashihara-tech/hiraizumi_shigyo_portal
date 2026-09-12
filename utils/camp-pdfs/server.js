import 'server-only';
import { createClient } from '@/utils/supabase/server';
import { isPdfVersionId, MAX_PDF_BYTES, pdfFailure, pdfPrivateHeaders } from './validation';

export async function deliverCampPdf(request, versionId) {
  const method = request.method;
  try {
    const supabase = await createClient();
    const { data: identity, error } = await supabase.auth.getUser();
    if (error || !identity?.user) return pdfFailure(401, method);
    if (!isPdfVersionId(versionId)) return pdfFailure(404, method);
    const { data, error: sessionError } = await supabase.auth.getSession();
    if (sessionError || !data?.session?.access_token) return pdfFailure(401, method);
    const headers = { apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '', authorization: `Bearer ${data.session.access_token}` };
    if (method === 'GET' && request.headers.has('range')) headers.range = request.headers.get('range');
    const result = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/camp-pdf-delivery?versionId=${encodeURIComponent(versionId)}`, {
      method, headers, cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(45000),
    });
    if (result.status === 416) return new Response(null, { status: 416, headers: pdfPrivateHeaders });
    if (![200, 206].includes(result.status)) return pdfFailure([401, 404].includes(result.status) ? result.status : 503, method);
    const length = Number(result.headers.get('content-length'));
    if (result.headers.get('content-type') !== 'application/pdf' || !Number.isSafeInteger(length) || length < 1 || length > MAX_PDF_BYTES) return pdfFailure(503, method);
    // Only a fixed header allowlist crosses the gateway; never forward Location,
    // Set-Cookie, upstream diagnostics, or cached 304 responses.
    const outgoing = { ...pdfPrivateHeaders, 'content-type': 'application/pdf', 'accept-ranges': 'bytes',
      'content-disposition': `inline; filename="camp-application-${versionId}.pdf"`, 'content-length': String(length) };
    if (result.status === 206) {
      const range = result.headers.get('content-range');
      if (!/^bytes \d+-\d+\/\d+$/.test(range ?? '')) return pdfFailure(503, method);
      outgoing['content-range'] = range;
    }
    if (method === 'HEAD') return new Response(null, { status: 200, headers: outgoing });
    const reader = result.body?.getReader(); if (!reader) return pdfFailure(503, method);
    let size = 0; const chunks = [];
    try {
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        size += value.length;
        if (size > length) { await reader.cancel(); return pdfFailure(503, method); }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
    if (size !== length) return pdfFailure(503, method);
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    return new Response(bytes, { status: result.status, headers: outgoing });
  } catch { return pdfFailure(503, method); }
}
