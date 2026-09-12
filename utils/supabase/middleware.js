import { createServerClient } from "@supabase/ssr";
import { NextResponse } from "next/server";

export async function updateSession(request) {
  const requestHeaders = new Headers(request.headers);
  requestHeaders.set("x-sg-path", `${request.nextUrl.pathname}${request.nextUrl.search}`);
  const nextResponse = () => NextResponse.next({ request: { headers: requestHeaders } });
  let supabaseResponse = nextResponse();

  // 匿名アクセスでは外部通信を発生させない。認証Cookieがある場合だけ、
  // Supabase SSRが期限更新したCookieをレスポンスへ引き継ぐ。
  if (!request.cookies.getAll().some(({ name }) => name.startsWith("sb-"))) {
    return supabaseResponse;
  }

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL ?? "",
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "",
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => {
            request.cookies.set(name, value);
          });

          supabaseResponse = nextResponse();

          cookiesToSet.forEach(({ name, value, options }) => {
            supabaseResponse.cookies.set(name, value, options);
          });
        },
      },
    }
  );

  await supabase.auth.getClaims();

  return supabaseResponse;
}
