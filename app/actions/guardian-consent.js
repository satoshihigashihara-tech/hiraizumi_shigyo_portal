"use server";

import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const BUCKET_NAME = "guardian-consents";
const MAX_FILE_SIZE = 5 * 1024 * 1024;
const ALLOWED_MIME_TYPES = new Set([
  "application/pdf",
  "image/jpeg",
  "image/png",
]);
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function getText(formData, name) {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function withQuery(path, values) {
  const searchParams = new URLSearchParams();

  for (const [key, value] of Object.entries(values)) {
    if (value) searchParams.set(key, value);
  }

  const query = searchParams.toString();
  return query ? `${path}?${query}` : path;
}

function createAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const secretKey = process.env.SUPABASE_SECRET_KEY;

  if (!url || !secretKey) {
    throw new Error("Supabase server credentials are not configured.");
  }

  return createSupabaseClient(url, secretKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}

async function fileSignatureIsValid(bytes, mimeType) {
  const header = new Uint8Array(bytes.slice(0, 8));

  if (mimeType === "application/pdf") {
    return String.fromCharCode(...header.slice(0, 5)) === "%PDF-";
  }

  if (mimeType === "image/jpeg") {
    return header[0] === 0xff && header[1] === 0xd8 && header[2] === 0xff;
  }

  if (mimeType === "image/png") {
    const pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    return pngSignature.every((value, index) => header[index] === value);
  }

  return false;
}

function documentErrorCode(error) {
  const message = error?.message ?? "";

  if (message.includes("ログイン")) return "login-required";
  if (message.includes("見つかりません")) return "not-found";
  if (message.includes("期限")) return "deadline-passed";
  if (message.includes("状態")) return "not-editable";
  if (message.includes("形式")) return "invalid-type";
  if (message.includes("サイズ")) return "invalid-size";

  return "upload-failed";
}

export async function uploadGuardianConsent(formData) {
  const applicationId = getText(formData, "applicationId");

  if (!UUID_PATTERN.test(applicationId)) {
    redirect(withQuery("/user", { error: "invalid-application" }));
  }

  const editPath = `/user/applications/${applicationId}/edit`;
  const file = formData.get("guardianConsentFile");

  if (!(file instanceof File) || file.size === 0) {
    redirect(withQuery(editPath, { error: "file-required" }));
  }

  if (file.size > MAX_FILE_SIZE) {
    redirect(withQuery(editPath, { error: "invalid-size" }));
  }

  if (!ALLOWED_MIME_TYPES.has(file.type)) {
    redirect(withQuery(editPath, { error: "invalid-type" }));
  }

  const fileBytes = await file.arrayBuffer();

  if (!(await fileSignatureIsValid(fileBytes, file.type))) {
    redirect(withQuery(editPath, { error: "invalid-content" }));
  }

  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    redirect(withQuery("/login", { returnTo: editPath }));
  }

  const { data: application, error: applicationError } = await supabase
    .from("applications")
    .select("id, status, revision_due_at")
    .eq("id", applicationId)
    .maybeSingle();

  if (applicationError || !application) {
    redirect(withQuery(editPath, { error: "not-found" }));
  }

  if (!['draft', 'revision_requested'].includes(application.status)) {
    redirect(withQuery(editPath, { error: "not-editable" }));
  }

  if (
    application.status === "revision_requested" &&
    application.revision_due_at &&
    new Date(application.revision_due_at).getTime() <= Date.now()
  ) {
    redirect(withQuery(editPath, { error: "deadline-passed" }));
  }

  const objectPath = `applications/${applicationId}/${crypto.randomUUID()}`;
  const admin = createAdminClient();
  const { error: uploadError } = await admin.storage
    .from(BUCKET_NAME)
    .upload(objectPath, fileBytes, {
      cacheControl: "3600",
      contentType: file.type,
      upsert: false,
    });

  if (uploadError) {
    redirect(withQuery(editPath, { error: "upload-failed" }));
  }

  const { data: previousObjectPath, error: metadataError } = await supabase.rpc(
    "register_guardian_consent_document",
    {
      target_application_id: applicationId,
      target_object_path: objectPath,
      target_mime_type: file.type,
      target_size_bytes: file.size,
    },
  );

  if (metadataError) {
    await admin.storage.from(BUCKET_NAME).remove([objectPath]);
    redirect(
      withQuery(editPath, {
        error: documentErrorCode(metadataError),
      }),
    );
  }

  if (previousObjectPath && previousObjectPath !== objectPath) {
    await admin.storage.from(BUCKET_NAME).remove([previousObjectPath]);
  }

  revalidatePath(editPath);
  revalidatePath(`/user/applications/${applicationId}/confirm`);
  redirect(withQuery(editPath, { uploaded: "1" }));
}

export async function createGuardianConsentDownloadUrl(applicationId) {
  if (!UUID_PATTERN.test(applicationId)) {
    return { error: "not-found", url: null };
  }

  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return { error: "login-required", url: null };
  }

  const { data: document, error } = await supabase
    .from("consent_documents")
    .select("object_path")
    .eq("application_id", applicationId)
    .maybeSingle();

  if (error || !document) {
    return { error: "not-found", url: null };
  }

  const admin = createAdminClient();
  const { data, error: signedUrlError } = await admin.storage
    .from(BUCKET_NAME)
    .createSignedUrl(document.object_path, 60);

  if (signedUrlError || !data?.signedUrl) {
    return { error: "download-failed", url: null };
  }

  return { error: null, url: data.signedUrl };
}
