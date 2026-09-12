import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
const root = new URL('../', import.meta.url);
const shared = await import(`data:text/javascript;base64,${Buffer.from(await readFile(new URL('supabase/functions/_shared/camp-pdf.js', root), 'utf8')).toString('base64')}`);
const ID = '11111111-1111-4111-8111-111111111111';
const ATTEMPT = '22222222-2222-4222-8222-222222222222';
const USER = '33333333-3333-4333-8333-333333333333';
const SECRET = 'a7-test-only-secret-'.repeat(3);
const PDF = new TextEncoder().encode('%PDF-1.7\nfictional transport fixture, not a validated render\n%%EOF\n');
const hash = await shared.sha256(PDF);
const report = { page_count: 1, fonts_embedded: true, text_verified: true, layout_verified: true };
function fixture(options = {}) {
  const calls = [];
  const permit = { allowed: true, object_path: `${ID}/${ATTEMPT}.pdf`, size_bytes: PDF.length, pdf_hash: hash, ...options.permit };
  let authorizationCount = 0;
  const admin = {
    async rpc(name, args) {
      calls.push([name, args]);
      if (options.rpcErrors?.includes(name)) return { error: { message: 'sensitive database details' } };
      if (name === 'authorize_camp_pdf_delivery') {
        authorizationCount++;
        return { data: options.deny || (options.revokeDuringFetch && authorizationCount > 1) ? { allowed: false } : permit };
      }
      if (name === 'check_camp_pdf_attempt') return { data: options.committed ? { committed: true, pdf_hash: hash, size_bytes: PDF.length, validation: report } : { version_id: ID, object_path: `${ID}/${ATTEMPT}.pdf` } };
      if (name === 'claim_camp_pdf_cleanup') return { data: options.noOrphan ? null : { job_id: ID, cleanup_token: ATTEMPT, object_path: `${ID}/${ATTEMPT}.pdf` } };
      return { data: true };
    },
    storage: {
      async getBucket(bucket) { calls.push(['bucket', bucket]); return { data: { public: options.publicBucket ?? false, file_size_limit: shared.MAX_PDF_BYTES, allowed_mime_types: ['application/pdf'] } }; },
      from(bucket) {
        calls.push(['from', bucket]); return {
          async upload(path, bytes, config) { calls.push(['upload', path, bytes, config]); return options.uploadError ? { error: {} } : {}; },
          async download(path) { calls.push(['download-existing', path]); return { data: new Blob([options.existingBytes ?? PDF]) }; },
          async remove(paths) { calls.push(['remove', paths]); return options.removeError ? { error: {} } : {}; },
        };
      },
    },
  };
  const auth = { async getUser(token) { calls.push(['auth', token]); return options.anonymous ? { error: {} } : { data: { user: { id: USER } } }; } };
  const download = async path => { calls.push(['download', path]); if (options.downloadError) throw new Error('private-path'); return options.bytes ?? PDF; };
  return { calls, delivery: shared.createDeliveryHandler({ admin, auth, download }), worker: shared.createWorkerHandler({ admin, workerSecret: SECRET }), cleanup: shared.createCleanupHandler({ admin, cleanupSecret: SECRET }) };
}
function request(method = 'GET', extra = {}, id = ID) {
  return new Request(`https://example.invalid/pdf?versionId=${id}`, { method, headers: { authorization: 'Bearer verified-test-jwt', ...extra } });
}
for (const method of ['GET', 'HEAD']) {
  test(`${method} authenticates and authorizes both before and after Storage`, async () => {
    const f = fixture(); const r = await f.delivery(request(method));
    assert.equal(r.status, 200); assert.match(r.headers.get('cache-control'), /private, no-store/);
    assert.equal(r.headers.get('location'), null); assert.equal(r.headers.get('etag'), null);
    assert.equal((await r.arrayBuffer()).byteLength, method === 'HEAD' ? 0 : PDF.length);
    assert.equal(f.calls.filter(x => x[0] === 'authorize_camp_pdf_delivery').length, 2);
    assert.equal(f.calls.find(x => x[0] === 'authorize_camp_pdf_delivery')[1].actor, USER);
  });
  for (const [label, opts, code] of [['anonymous', { anonymous: true }, 401], ['denied', { deny: true }, 404], ['revoked during download', { revokeDuringFetch: true }, 404], ['public bucket', { publicBucket: true }, 503], ['hash mismatch', { permit: { pdf_hash: '0'.repeat(64) } }, 503], ['storage failure', { downloadError: true }, 503], ['audit failure', { rpcErrors: ['authorize_camp_pdf_delivery'] }, 503]]) {
    test(`${method} ${label} releases no PDF or internal diagnostics`, async () => {
      const f = fixture(opts); const r = await f.delivery(request(method));
      assert.equal(r.status, code); const body = await r.text();
      assert.doesNotMatch(body, /PDF-|sensitive|private-path|object_path/);
      if (label === 'anonymous' || label === 'denied') assert.equal(f.calls.some(x => x[0] === 'download'), false);
      assert.match(r.headers.get('cache-control'), /no-store/);
    });
  }
}
for (const [value, expected] of [['bytes=0-4', '%PDF-'], ['bytes=-6', '%%EOF\n'], ['bytes=5-', new TextDecoder().decode(PDF.slice(5))]]) {
  test(`authorized range ${value}`, async () => {
    const f = fixture(); const r = await f.delivery(request('GET', { range: value }));
    assert.equal(r.status, 206); assert.equal(await r.text(), expected);
    assert.match(r.headers.get('content-range'), /^bytes /);
  });
}
for (const value of ['bytes=10000-', 'bytes=4-2', 'bytes=-0', 'bytes=0-2,4-8', 'bytes=99999999999999999999-', 'bytes=-', 'items=0-1']) {
  test(`malformed/unsatisfiable range ${value} checks authorization`, async () => {
    const f = fixture(); const r = await f.delivery(request('GET', { range: value }));
    assert.equal(r.status, 416);
    assert.equal(f.calls.filter(x => x[0] === 'authorize_camp_pdf_delivery').length, 2);
    const denied = await fixture({ deny: true }).delivery(request('GET', { range: value }));
    assert.equal(denied.status, 404); assert.equal(denied.headers.get('content-range'), null);
  });
}
test('missing JWT and malformed UUID do not touch storage', async () => {
  const f = fixture();
  assert.equal((await f.delivery(new Request('https://example.invalid/pdf'))).status, 401);
  assert.equal((await f.delivery(request('GET', {}, '../../private'))).status, 404);
  assert.equal(f.calls.some(x => x[0] === 'bucket'), false);
});
function workerRequest(overrides = {}, authenticated = true) {
  return new Request('https://example.invalid/worker', { method: 'POST', headers: authenticated ? { 'x-camp-pdf-worker-secret': SECRET } : {}, body: JSON.stringify({ operation: 'complete', jobId: ID, attemptId: ATTEMPT, sourceHash: 'a'.repeat(64), pdfBase64: Buffer.from(PDF).toString('base64'), validation: report, ...overrides }) });
}
test('worker computes byte hash and uploads immutable object', async () => {
  const f = fixture(); assert.equal((await f.worker(workerRequest())).status, 200);
  assert.deepEqual(f.calls.find(x => x[0] === 'upload')[3], { contentType: 'application/pdf', cacheControl: '0', upsert: false });
  const complete = f.calls.find(x => x[0] === 'complete_camp_pdf_job')[1];
  assert.equal(complete.pdf_hash_value, hash); assert.equal(complete.size_bytes_value, PDF.length);
  assert.equal(f.calls.some(x => x[0] === 'remove'), false);
});
for (const [label, overrides] of [['missing validation', { validation: {} }], ['two pages', { validation: { ...report, page_count: 2 } }], ['missing fonts', { validation: { ...report, fonts_embedded: false } }], ['not PDF', { pdfBase64: Buffer.from('not pdf').toString('base64') }], ['invalid job', { jobId: '../other' }], ['missing source', { sourceHash: '' }]]) {
  test(`worker rejects ${label} before upload`, async () => {
    const f = fixture(); assert.equal((await f.worker(workerRequest(overrides))).status, 400);
    assert.equal(f.calls.some(x => x[0] === 'upload'), false);
  });
}
test('worker authentication required before RPC', async () => {
  const f = fixture(); assert.equal((await f.worker(workerRequest({}, false))).status, 401); assert.equal(f.calls.length, 0);
});
test('committed replay never uploads', async () => {
  const f = fixture({ committed: true }); assert.equal((await f.worker(workerRequest())).status, 200);
  assert.equal(f.calls.some(x => x[0] === 'upload'), false);
});
test('existing equal bytes allow lost upload response recovery', async () => {
  const f = fixture({ uploadError: true }); assert.equal((await f.worker(workerRequest())).status, 200);
  assert.equal(f.calls.some(x => x[0] === 'remove'), false);
});
test('existing different bytes are never overwritten or registered', async () => {
  const f = fixture({ uploadError: true, existingBytes: new TextEncoder().encode('other') });
  assert.equal((await f.worker(workerRequest())).status, 503);
  assert.equal(f.calls.some(x => ['remove', 'complete_camp_pdf_job'].includes(x[0])), false);
});
test('uncertain DB completion never deletes possibly committed PDF', async () => {
  const f = fixture({ rpcErrors: ['complete_camp_pdf_job'] }); assert.equal((await f.worker(workerRequest())).status, 409);
  assert.equal(f.calls.some(x => ['remove', 'fail_camp_pdf_job'].includes(x[0])), false);
  assert.equal(f.calls.some(x => x[0] === 'record_camp_pdf_job_response_failure'), true);
});
for (const [opts, expected] of [[{}, 200], [{ noOrphan: true }, 200], [{ removeError: true }, 503], [{ publicBucket: true }, 503]]) {
  test(`cleanup reservation and retention ${JSON.stringify(opts)}`, async () => {
    const f = fixture(opts); const r = await f.cleanup(new Request('https://example.invalid/cleanup', { method: 'POST', headers: { 'x-camp-pdf-cleanup-secret': SECRET } }));
    assert.equal(r.status, expected);
    if (opts.noOrphan || opts.publicBucket) assert.equal(f.calls.some(x => x[0] === 'remove'), false);
    if (opts.removeError) assert.equal(f.calls.some(x => x[0] === 'complete_camp_pdf_cleanup'), false);
    if (!Object.keys(opts).length) assert.ok(f.calls.findIndex(x => x[0] === 'claim_camp_pdf_cleanup') < f.calls.findIndex(x => x[0] === 'remove'));
  });
}
test('cleanup and worker credentials are separate', async () => {
  const f = fixture(); assert.equal((await f.cleanup(workerRequest())).status, 401); assert.equal(f.calls.length, 0);
});
test('body size is bounded without trusting Content-Length', async () => {
  const stream = new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(10)); controller.enqueue(new Uint8Array(10)); controller.close(); } });
  await assert.rejects(shared.readBounded(stream, 15), /too-large/);
});
// Execute the actual Next.js gateway with auth and transport boundaries replaced.
async function gateway(options = {}) {
  const calls = [];
  const context = vm.createContext({ Request, Response, Headers, Uint8Array, Number, JSON, AbortSignal, process: { env: { NEXT_PUBLIC_SUPABASE_URL: 'https://example.invalid', NEXT_PUBLIC_SUPABASE_ANON_KEY: 'public-key' } },
    fetch: async (url, init) => { calls.push([url, init]); return options.response?.() ?? new Response(init.method === 'HEAD' ? null : PDF, { headers: { 'content-type': 'application/pdf', 'content-length': String(PDF.length), location: 'https://private.invalid/path', 'set-cookie': 'private' } }); },
  });
  const mocks = {
    'server-only': {},
    '@/utils/supabase/server': { createClient: async () => ({ auth: {
      getUser: async () => options.anonymous ? { error: {} } : { data: { user: { id: USER } } },
      getSession: async () => ({ data: { session: { access_token: 'user-jwt' } } }),
    } }) },
  };
  const cache = new Map();
  async function load(path) {
    if (cache.has(path)) return cache.get(path);
    let mod;
    if (mocks[path]) mod = new vm.SyntheticModule(Object.keys(mocks[path]), function () { for (const [k, v] of Object.entries(mocks[path])) this.setExport(k, v); }, { context });
    else mod = new vm.SourceTextModule(await readFile(new URL(path === './validation' ? 'utils/camp-pdfs/validation.js' : path, root), 'utf8'), { context });
    cache.set(path, mod); await mod.link(load); return mod;
  }
  const mod = await load('utils/camp-pdfs/server.js'); await mod.evaluate();
  return { calls, handle: mod.namespace.deliverCampPdf };
}
test('gateway forwards user JWT, uses no-store and strips private upstream headers', async () => {
  const g = await gateway(); const r = await g.handle(request(), ID);
  assert.equal(r.status, 200); assert.equal(r.headers.get('location'), null); assert.equal(r.headers.get('set-cookie'), null);
  assert.equal(g.calls[0][1].headers.authorization, 'Bearer user-jwt'); assert.equal(g.calls[0][1].cache, 'no-store'); assert.equal(g.calls[0][1].redirect, 'error');
  assert.equal((await r.arrayBuffer()).byteLength, PDF.length);
});
test('gateway authenticates before invalid ID and never fetches for anonymous', async () => {
  const g = await gateway({ anonymous: true }); assert.equal((await g.handle(request(), '../other')).status, 401); assert.equal(g.calls.length, 0);
});
for (const status of [302, 304, 401, 404, 500]) {
  test(`gateway sanitizes upstream ${status}`, async () => {
    const g = await gateway({ response: () => new Response([302, 304].includes(status) ? null : 'sensitive', { status, headers: { location: 'https://private.invalid' } }) });
    const r = await g.handle(request(), ID);
    assert.equal(r.status, [401, 404].includes(status) ? status : 503); assert.doesNotMatch(await r.text(), /sensitive|private.invalid/);
  });
}
test('gateway rejects oversized or truncated success bodies', async () => {
  const g = await gateway({ response: () => new Response('short', { headers: { 'content-type': 'application/pdf', 'content-length': '99' } }) });
  assert.equal((await g.handle(request(), ID)).status, 503);
});
test('PDF route awaits dynamic params and implements explicit HEAD', async () => {
  const text = await readFile(new URL('app/api/camp/application-pdfs/[versionId]/route.js', root), 'utf8');
  assert.match(text, /await context.params/); assert.match(text, /export async function HEAD/);
});
// Ensure Web Crypto is available in the same Node runtime used by the suite.
assert.ok(webcrypto.subtle);
