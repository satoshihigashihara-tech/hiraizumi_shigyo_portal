// Dependency-injected handlers: no credentials or network calls at module load.
export const BUCKET = 'camp-application-pdfs';
export const MAX_PDF_BYTES = 3 * 1024 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HASH = /^[0-9a-f]{64}$/;
export const privateHeaders = {
  'cache-control': 'private, no-store, max-age=0',
  'cdn-cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'vary': 'Cookie, Authorization',
};
export function failure(status, code, method = 'GET') {
  return new Response(method === 'HEAD' ? null : JSON.stringify({ error: code }), {
    status, headers: { ...privateHeaders, 'content-type': 'application/json' },
  });
}
export async function readBounded(body, limit) {
  if (!body) throw new Error('empty-body');
  const reader = body.getReader(); const chunks = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > limit) { await reader.cancel(); throw new Error('too-large'); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const part of chunks) { bytes.set(part, offset); offset += part.length; }
  return bytes;
}
export async function sha256(bytes) {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(x => x.toString(16).padStart(2, '0')).join('');
}
export function validPdf(bytes) {
  if (!bytes.length || bytes.length > MAX_PDF_BYTES) return false;
  const text = new TextDecoder('latin1');
  return text.decode(bytes.slice(0, 8)).startsWith('%PDF-') && /%%EOF\s*$/.test(text.decode(bytes.slice(-1024)));
}
export function parseRange(value, size) {
  if (!value) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!m || (!m[1] && !m[2])) throw new Error('invalid-range');
  const first = m[1] ? Number(m[1]) : null; const last = m[2] ? Number(m[2]) : null;
  if ((first !== null && !Number.isSafeInteger(first)) || (last !== null && !Number.isSafeInteger(last))) throw new Error('invalid-range');
  const start = first === null ? Math.max(0, size - last) : first;
  const end = first === null || last === null ? size - 1 : Math.min(last, size - 1);
  if (start >= size || start > end || start < 0 || (first === null && last === 0)) throw new Error('invalid-range');
  return { start, end };
}
async function equalSecret(a, b) {
  if (!a || a.length < 32 || !b || b.length > 512) return false;
  const encoder = new TextEncoder();
  const left = new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(a)));
  const right = new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(b)));
  let difference = 0; for (let i = 0; i < left.length; i++) difference |= left[i] ^ right[i];
  return difference === 0;
}
async function rpc(admin, name, args = {}) {
  const { data, error } = await admin.rpc(name, args);
  if (error) throw new Error('rpc-failed');
  return data;
}
function json(data) { return new Response(JSON.stringify(data), { headers: { ...privateHeaders, 'content-type': 'application/json' } }); }
async function privateBucket(admin) {
  const { data, error } = await admin.storage.getBucket(BUCKET);
  if (error || !data || data.public !== false || data.file_size_limit !== MAX_PDF_BYTES
    || !Array.isArray(data.allowed_mime_types) || data.allowed_mime_types.length !== 1 || data.allowed_mime_types[0] !== 'application/pdf') {
    throw new Error('storage-misconfigured');
  }
}
export function createDeliveryHandler({ admin, auth, download }) {
  return async request => {
    const method = request.method;
    if (!['GET', 'HEAD'].includes(method)) return failure(405, 'method-not-allowed', method);
    const token = /^Bearer (\S+)$/.exec(request.headers.get('authorization') ?? '')?.[1];
    if (!token || token.length > 16384) return failure(401, 'login-required', method);
    let actor; let versionId;
    try {
      const { data, error } = await auth.getUser(token);
      if (error || !data?.user) return failure(401, 'login-required', method);
      actor = data.user.id;
      versionId = new URL(request.url).searchParams.get('versionId');
      if (!UUID.test(versionId ?? '')) return failure(404, 'not-found', method);
      const authorize = () => rpc(admin, 'authorize_camp_pdf_delivery', { target_version_id: versionId, actor, request_method: method });
      const permit = await authorize();
      if (permit?.allowed !== true) return failure(404, 'not-found', method);
      await privateBucket(admin);
      if (!Number.isSafeInteger(permit.size_bytes) || permit.size_bytes < 1 || permit.size_bytes > MAX_PDF_BYTES
        || !HASH.test(permit.pdf_hash ?? '') || !new RegExp(`^${versionId}/[0-9a-f-]{36}\\.pdf$`, 'i').test(permit.object_path ?? '')) throw new Error('invalid-object');
      const bytes = await download(permit.object_path, MAX_PDF_BYTES);
      if (bytes.length !== permit.size_bytes || !validPdf(bytes) || await sha256(bytes) !== permit.pdf_hash) throw new Error('invalid-object');
      // Fetch can take time. Check cancellation again before releasing any bytes.
      const finalPermit = await authorize();
      if (finalPermit?.allowed !== true) return failure(404, 'not-found', method);
      if (finalPermit.pdf_hash !== permit.pdf_hash || finalPermit.object_path !== permit.object_path) throw new Error('invalid-object');
      let range;
      try { range = method === 'HEAD' ? null : parseRange(request.headers.get('range'), bytes.length); }
      catch { return new Response(null, { status: 416, headers: { ...privateHeaders, 'content-range': `bytes */${bytes.length}` } }); }
      const content = range ? bytes.slice(range.start, range.end + 1) : bytes;
      return new Response(method === 'HEAD' ? null : content, { status: range ? 206 : 200, headers: {
        ...privateHeaders, 'content-type': 'application/pdf', 'accept-ranges': 'bytes',
        'content-disposition': `inline; filename="camp-application-${versionId}.pdf"`,
        'content-length': String(content.length),
        ...(range ? { 'content-range': `bytes ${range.start}-${range.end}/${bytes.length}` } : {}),
      } });
    } catch {
      if (actor && UUID.test(versionId ?? '')) {
        try { await rpc(admin, 'record_camp_pdf_delivery_failure', { target_version_id: versionId, actor }); } catch { /* no bytes on audit failure */ }
      }
      return failure(503, 'pdf-unavailable', method);
    }
  };
}
export function createWorkerHandler({ admin, workerSecret }) {
  return async request => {
    if (request.method !== 'POST') return failure(405, 'method-not-allowed');
    if (!await equalSecret(workerSecret, request.headers.get('x-camp-pdf-worker-secret'))) return failure(401, 'unauthorized');
    let body;
    try { body = JSON.parse(new TextDecoder().decode(await readBounded(request.body, 4 * 1024 * 1024 + 8192))); }
    catch { return failure(400, 'invalid-request'); }
    if (!body || (body.operation !== 'claim' && !UUID.test(body.jobId ?? '')) || (body.jobId != null && !UUID.test(body.jobId))) return failure(400, 'invalid-request');
    try {
      if (body.operation === 'claim') {
        await privateBucket(admin);
        return json(await rpc(admin, 'claim_camp_pdf_job', { target_job_id: body.jobId ?? null }));
      }
      if (!UUID.test(body.attemptId ?? '')) return failure(400, 'invalid-request');
      const args = { target_job_id: body.jobId, target_attempt_id: body.attemptId };
      if (body.operation === 'fail') {
        return json({ recorded: await rpc(admin, 'fail_camp_pdf_job', { ...args, error_code_value: 'generation-failed' }) });
      }
      if (body.operation !== 'complete' || !HASH.test(body.sourceHash ?? '') || typeof body.pdfBase64 !== 'string'
        || body.pdfBase64.length > 4 * 1024 * 1024 || !/^[A-Za-z0-9+/]*={0,2}$/.test(body.pdfBase64)) return failure(400, 'invalid-request');
      const report = body.validation;
      if (!report || report.page_count !== 1 || report.fonts_embedded !== true || report.text_verified !== true || report.layout_verified !== true) return failure(400, 'invalid-validation');
      const validation = { page_count: 1, fonts_embedded: true, text_verified: true, layout_verified: true };
      const bytes = Uint8Array.from(atob(body.pdfBase64), c => c.charCodeAt(0));
      if (!validPdf(bytes)) return failure(400, 'invalid-pdf');
      const hash = await sha256(bytes);
      await privateBucket(admin);
      const artifact = await rpc(admin, 'check_camp_pdf_attempt', { ...args, source_hash_value: body.sourceHash });
      if (artifact.committed === true) {
        if (artifact.pdf_hash !== hash || artifact.size_bytes !== bytes.length
          || !Object.keys(validation).every(k => artifact.validation?.[k] === validation[k])) return failure(409, 'job-unavailable');
        return json({ recorded: true });
      }
      const path = artifact.object_path;
      if (!new RegExp(`^[0-9a-f-]{36}/${body.attemptId}\\.pdf$`, 'i').test(path ?? '')) throw new Error('invalid-path');
      const { error } = await admin.storage.from(BUCKET).upload(path, bytes, { contentType: 'application/pdf', cacheControl: '0', upsert: false });
      if (error) {
        // A prior response may be lost. Never overwrite or delete an existing object.
        const { data: existing, error: readError } = await admin.storage.from(BUCKET).download(path);
        if (readError || !existing || existing.size !== bytes.length || await sha256(new Uint8Array(await existing.arrayBuffer())) !== hash) {
          await rpc(admin, 'fail_camp_pdf_job', { ...args, error_code_value: 'storage-failed' });
          return failure(503, 'storage-failed');
        }
      }
      await rpc(admin, 'complete_camp_pdf_job', { ...args, source_hash_value: body.sourceHash, pdf_hash_value: hash, size_bytes_value: bytes.length, validation_value: validation });
      return json({ recorded: true });
    } catch {
      // Completion may already have committed. Do not mark failed/delete blindly;
      // stale attempts expire and the dedicated cleanup RPC decides retention.
      if (UUID.test(body.attemptId ?? '')) {
        try { await rpc(admin, 'record_camp_pdf_job_response_failure', { target_job_id: body.jobId, target_attempt_id: body.attemptId }); } catch { /* no state change or bytes on audit failure */ }
      }
      return failure(409, 'job-unavailable');
    }
  };
}
export function createCleanupHandler({ admin, cleanupSecret }) {
  return async request => {
    if (request.method !== 'POST') return failure(405, 'method-not-allowed');
    if (!await equalSecret(cleanupSecret, request.headers.get('x-camp-pdf-cleanup-secret'))) return failure(401, 'unauthorized');
    try {
      await privateBucket(admin);
      const job = await rpc(admin, 'claim_camp_pdf_cleanup');
      if (!job) return json({ removed: 0 });
      if (!UUID.test(job.job_id ?? '') || !UUID.test(job.cleanup_token ?? '') || !/^[0-9a-f-]{36}\/[0-9a-f-]{36}\.pdf$/.test(job.object_path ?? '')) throw new Error('invalid-path');
      const { error } = await admin.storage.from(BUCKET).remove([job.object_path]);
      if (error) throw new Error('storage-failed');
      const recorded = await rpc(admin, 'complete_camp_pdf_cleanup', { target_job_id: job.job_id, token_value: job.cleanup_token });
      if (recorded !== true) throw new Error('cleanup-failed');
      return json({ removed: 1 });
    } catch { return failure(503, 'cleanup-failed'); }
  };
}
