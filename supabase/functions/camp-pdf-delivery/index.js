/* global Deno */
import { createClient } from 'npm:@supabase/supabase-js@2.116.0';
import { BUCKET, createDeliveryHandler, readBounded } from '../_shared/camp-pdf.js';
const url = Deno.env.get('SUPABASE_URL');
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const boundedFetch = (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(20000) });
const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false }, global: { fetch: boundedFetch } });
Deno.serve(createDeliveryHandler({ admin, auth: admin.auth, download: async (path, limit) => {
  const result = await boundedFetch(`${url}/storage/v1/object/authenticated/${BUCKET}/${path}`, {
    headers: { apikey: key, authorization: `Bearer ${key}` }, redirect: 'error',
  });
  if (!result.ok) throw new Error('storage-failed');
  return readBounded(result.body, limit);
} }));
