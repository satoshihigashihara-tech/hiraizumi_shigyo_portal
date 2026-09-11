"use server";

import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { requireActiveUser } from "@/utils/auth/guards";
import { isUpdatedAt, communityErrorCode } from "@/utils/community-applications/validation";

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
  const { supabase, user } = await requireActiveUser("/user/applications");
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

  const { data: application, error: applicationError } = await supabase
    .from("applications")
    .select("id, usage_type, status, revision_due_at, updated_at, submitted_at")
    .eq("id", applicationId)
    .eq("user_id", user.id)
    .maybeSingle();

  if (applicationError || !application) {
    redirect(withQuery(editPath, { error: "not-found" }));
  }

  const community = application.usage_type === "community_individual";
  const updatedAt = getText(formData, "updatedAt");
  if (community && !isUpdatedAt(updatedAt)) {
    redirect(withQuery(editPath, { error: "invalid-version" }));
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

  const { data: metadata, error: metadataError } = await admin.rpc(
    community ? "register_community_guardian_consent_document" : "register_guardian_consent_document",
    {
      target_application_id: applicationId,
      expected_user_id: user.id,
      target_object_path: objectPath,
      target_mime_type: file.type,
      target_size_bytes: file.size,
      ...(community ? { expected_updated_at: updatedAt } : {}),
    },
  );

  if (metadataError) {
    await admin.storage.from(BUCKET_NAME).remove([objectPath]);
    redirect(
      withQuery(editPath, {
        error: community ? communityErrorCode(metadataError) : documentErrorCode(metadataError),
      }),
    );
  }

  const previousObjectPath = community ? metadata?.[0]?.previous_object_path : metadata;
  const deletePrevious = community ? metadata?.[0]?.delete_previous === true : !application.submitted_at;
  if (deletePrevious && previousObjectPath && previousObjectPath !== objectPath) {
    await admin.storage.from(BUCKET_NAME).remove([previousObjectPath]);
  }

  revalidatePath(editPath);
  revalidatePath(`/user/applications/${applicationId}`);
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
