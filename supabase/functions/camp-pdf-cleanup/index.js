/* global Deno */
import { createClient } from 'npm:@supabase/supabase-js@2.116.0';
import { createCleanupHandler } from '../_shared/camp-pdf.js';
const admin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: { persistSession: false, autoRefreshToken: false },
  global: { fetch: (input, init = {}) => fetch(input, { ...init, signal: AbortSignal.timeout(20000) }) },
});
Deno.serve(createCleanupHandler({ admin, cleanupSecret: Deno.env.get('CAMP_PDF_CLEANUP_SECRET') }));
