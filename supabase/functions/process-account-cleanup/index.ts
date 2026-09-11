import { createClient } from "npm:@supabase/supabase-js@2";

const jsonHeaders = { "content-type": "application/json" };

function safeEqual(left: string, right: string) {
  const encoder = new TextEncoder();
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  let difference = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) difference |= (a[index] ?? 0) ^ (b[index] ?? 0);
  return difference === 0;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(JSON.stringify({ error: "method-not-allowed" }), { status: 405, headers: jsonHeaders });
  const cronSecret = Deno.env.get("ACCOUNT_CLEANUP_CRON_SECRET") ?? "";
  const suppliedSecret = request.headers.get("x-cron-secret") ?? "";
  if (!cronSecret || !safeEqual(cronSecret, suppliedSecret)) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: jsonHeaders });
  }
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const secretKey = Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!url || !secretKey) return new Response(JSON.stringify({ error: "server-misconfigured" }), { status: 500, headers: jsonHeaders });
  const supabase = createClient(url, secretKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: jobs, error: claimError } = await supabase.rpc("claim_account_cleanup_job", { batch_size: 10 });
  if (claimError) return new Response(JSON.stringify({ error: "claim-failed" }), { status: 500, headers: jsonHeaders });
  let completed = 0;
  let failed = 0;
  for (const job of jobs ?? []) {
    const jobId = job.job_id as string;
    const userId = job.result_user_id as string;
    try {
      const { data: lookup, error: lookupError } = await supabase.auth.admin.getUserById(userId);
      if (lookupError && !/not found/i.test(lookupError.message)) throw lookupError;
      if (lookup?.user) {
        const { error: deleteError } = await supabase.auth.admin.deleteUser(userId, false);
        if (deleteError && !/not found/i.test(deleteError.message)) throw deleteError;
      }
      const { data: marked, error: markError } = await supabase.rpc("complete_account_cleanup_job", {
        target_job_id: jobId, target_user_id: userId,
      });
      if (markError || marked !== true) throw markError ?? new Error("completion-not-recorded");
      completed += 1;
    } catch (error) {
      failed += 1;
      const message = error instanceof Error ? error.message : "delete-failed";
      await supabase.rpc("fail_account_cleanup_job", {
        target_job_id: jobId, target_user_id: userId, error_message: message.slice(0, 500),
      });
    }
  }
  return new Response(JSON.stringify({ claimed: (jobs ?? []).length, completed, failed }), { status: failed ? 207 : 200, headers: jsonHeaders });
});
