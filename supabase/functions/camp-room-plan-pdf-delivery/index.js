/* global Deno */
import { createClient } from 'npm:@supabase/supabase-js@2.116.0';
import { createRoomPlanDeliveryHandler, readBounded } from '../_shared/camp-pdf.js';
const admin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'), {
  auth: { persistSession: false, autoRefreshToken: false },
});
const download = async (path, limit) => {
  const { data, error } = await admin.storage.from('camp-application-pdfs').download(path);
  if (error || !data) throw new Error('download-failed');
  return readBounded(data.stream(), limit);
};
Deno.serve(createRoomPlanDeliveryHandler({ admin, auth: admin.auth, download }));
