// Local-only PostgreSQL harness. No .env or hosted Supabase connection is read.
// Dependencies live outside the project: embedded-postgres and pg.
// T10_DB_RUNTIME can point to their existing package directory.
import { createRequire } from 'node:module';
import { readFile, readdir, mkdtemp, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import assert from 'node:assert/strict';

const runtime = createRequire(join(resolve(process.env.T10_DB_RUNTIME || '/private/tmp/hiraizumi-t09-postgres'), 'package.json'));
const EmbeddedPostgres = runtime('embedded-postgres').default;
const { Client } = runtime('pg');
const root = fileURLToPath(new URL('../', import.meta.url));
const port = await new Promise((resolvePort, reject) => {
  const server = createServer(); server.on('error', reject);
  server.listen(0, '127.0.0.1', () => { const p = server.address().port; server.close(() => resolvePort(p)); });
});
const scratch = await mkdtemp(join(tmpdir(), 'hiraizumi-t10-'));
const password = randomUUID();
const pg = new EmbeddedPostgres({ databaseDir: join(scratch, 'data'), user: 'postgres', password, port, persistent: false,
  initdbFlags: ['--locale=C', '--encoding=UTF8'], postgresFlags: ['-h', '127.0.0.1', '-k', scratch], onLog() {}, onError() {} });
const clients = [];
async function connect() {
  const c = new Client({ host: '127.0.0.1', port, user: 'postgres', password, database: 'postgres' });
  await c.connect(); clients.push(c); return c;
}
let stage = 'start';
let failed = false;
try {
  await pg.initialise(); await pg.start(); const c = await connect();
  console.log('Local PostgreSQL', (await c.query('show server_version')).rows[0].server_version);
  await c.query(`
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin bypassrls;
    create schema auth;
    create table auth.users (
      id uuid primary key, instance_id uuid, aud text, role text, email text,
      encrypted_password text, email_confirmed_at timestamptz, last_sign_in_at timestamptz,
      raw_app_meta_data jsonb, raw_user_meta_data jsonb, created_at timestamptz, updated_at timestamptz
    );
    create function auth.uid() returns uuid language sql stable as $$
      select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid;
    $$;
    create function auth.jwt() returns jsonb language sql stable as $$
      select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb,
        jsonb_build_object('sub', current_setting('request.jwt.claim.sub', true),
          'email', current_setting('request.jwt.claim.email', true)));
    $$;
    grant usage on schema public, auth to anon, authenticated, service_role;
    grant execute on all functions in schema auth to anon, authenticated, service_role;
  `);
  for (const file of (await readdir(join(root, 'supabase/migrations'))).filter(x => x.endsWith('.sql')).sort()) {
    stage = file; await c.query(await readFile(join(root, 'supabase/migrations', file), 'utf8'));
    console.log('PASS migration', file);
  }
  const requested = process.argv.slice(2);
  const single = ['camp_room_allocations_and_approval.sql', 'calendar_and_blocked_periods.sql', 'community_individual_applications.sql'];
  const concurrent = ['camp_room_allocations_concurrency.sql', 'calendar_concurrency.sql', 'community_individual_applications_concurrency.sql'];
  const selected = requested.includes('--migrate-only') ? [] : requested.includes('--single-only') ? single : requested.length ? requested : [...single, ...concurrent];
  for (const file of selected) {
    assert.ok([...single, ...concurrent].includes(file), 'Unknown test file'); stage = file;
    const result = await c.query(await readFile(join(root, 'supabase/tests', file), 'utf8'));
    if (!concurrent.includes(file)) {
      const summary = (Array.isArray(result) ? result : [result]).flatMap(x => x.rows || []).find(x => x.passed_checks !== undefined);
      assert.ok(summary && Number(summary.passed_checks) > 0, 'Missing test summary');
      console.log('PASS', file, summary); continue;
    }
    const schema = file.startsWith('community_') ? 't10_concurrency_test' : file.startsWith('camp_room_') ? 't12_concurrency_test' : 't09_concurrency_test';
    const a = await connect(), b = await connect();
    const workers = await Promise.allSettled([a.query(`call ${schema}.worker_a()`), b.query(`call ${schema}.worker_b()`)]);
    const failures = workers.flatMap((r, i) => r.status === 'rejected' ? [{ worker: i ? 'B' : 'A', message: r.reason.message, code: r.reason.code, where: r.reason.where }] : []);
    if (failures.length) throw new Error(JSON.stringify(failures));
    const verified = (await c.query(`select * from ${schema}.verify()`)).rows;
    assert.ok(verified.length > 0 && verified.every(x => x.passed && x.backend_a !== x.backend_b));
    console.log('PASS', file, { checked_cases: verified.length, all_passed: true });
    await c.query(`begin; select ${schema}.cleanup(); drop schema ${schema} cascade; commit`);
    assert.equal((await c.query('select to_regnamespace($1) is null as gone', [schema])).rows[0].gone, true);
    console.log('PASS cleanup', schema);
  }
} catch (error) {
  // SQL diagnostics only, never connection options, credentials or environment.
  console.error('FAIL', stage, { message: error.message, code: error.code, where: error.where, position: error.position });
  failed = true;
} finally {
  for (const c of clients) { try { await c.query('rollback'); await c.end(); } catch {} }
  try { await pg.stop(); } finally { await rm(scratch, { recursive: true, force: true }); }
}

process.exitCode = failed ? 1 : 0;
