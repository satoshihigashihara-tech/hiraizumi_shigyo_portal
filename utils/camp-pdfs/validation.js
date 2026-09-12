export const MAX_PDF_BYTES = 3 * 1024 * 1024;
export function isPdfVersionId(value) {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}
export const pdfPrivateHeaders = {
  'cache-control': 'private, no-store, max-age=0', 'cdn-cache-control': 'no-store',
  'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', 'vary': 'Cookie, Authorization',
};
export function pdfFailure(status, method) {
  return new Response(method === 'HEAD' ? null : JSON.stringify({ error: status === 401 ? 'login-required' : status === 404 ? 'not-found' : 'pdf-unavailable' }), {
    status, headers: { ...pdfPrivateHeaders, 'content-type': 'application/json' },
  });
}
