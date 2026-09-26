"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/utils/supabase/client";
import {
  ACTIVITY_THROTTLE_MS,
  remainingMs,
  sessionStorageId,
  validActivity,
  warningStartsAt,
} from "@/utils/auth/session-timeout";
import styles from "./SessionTimeout.module.css";

const LOGIN_URL = "/login?error=session-timeout";

export default function SessionTimeout({ durationMs }) {
  const router = useRouter();
  const [warning, setWarning] = useState(false);
  const [signOutError, setSignOutError] = useState(false);

  useEffect(() => {
    let disposed = false;
    let timer;
    let activityKey;
    let timeoutKey;
    let lastWrite = 0;
    let signingOut = false;
    let lastActivity = Date.now();
    let storageAvailable = true;
    const supabase = createClient();

    function clearTimer() {
      if (timer) window.clearTimeout(timer);
    }

    function readStorage(key) {
      if (!storageAvailable) return null;
      try {
        return localStorage.getItem(key);
      } catch {
        storageAvailable = false;
        return null;
      }
    }

    function writeStorage(key, value) {
      if (!storageAvailable) return;
      try {
        localStorage.setItem(key, value);
      } catch {
        storageAvailable = false;
      }
    }

    async function expire() {
      if (disposed || signingOut) return;
      signingOut = true;
      clearTimer();
      setWarning(false);
      writeStorage(timeoutKey, String(Date.now()));
      try {
        const { error } = await supabase.auth.signOut();
        if (error) throw error;
        if (!disposed) router.replace(LOGIN_URL);
      } catch {
        // Another tab may have already completed the shared Supabase sign-out.
        try {
          const { data: { session } } = await supabase.auth.getSession();
          if (!disposed && !session) {
            router.replace(LOGIN_URL);
            return;
          }
        } catch {
          // Keep the page in an error state if auth status cannot be confirmed.
        }
        signingOut = false;
        if (!disposed) setSignOutError(true);
      }
    }

    function schedule() {
      if (disposed || signingOut || !activityKey) return;
      clearTimer();
      if (readStorage(timeoutKey) !== null) {
        void expire();
        return;
      }
      const now = Date.now();
      const stored = validActivity(readStorage(activityKey), now);
      if (stored !== null) lastActivity = Math.max(lastActivity, stored);
      const remaining = remainingMs(lastActivity, now, durationMs);
      if (remaining === 0) {
        void expire();
        return;
      }
      const isWarning = now >= warningStartsAt(lastActivity, durationMs);
      setWarning(isWarning);
      const nextDelay = isWarning ? remaining : warningStartsAt(lastActivity, durationMs) - now;
      timer = window.setTimeout(schedule, Math.max(1, nextDelay));
    }

    function recordActivity() {
      if (disposed || signingOut || !activityKey || readStorage(timeoutKey) !== null) return;
      const now = Date.now();
      const stored = validActivity(readStorage(activityKey), now);
      if (stored !== null) lastActivity = Math.max(lastActivity, stored);
      if (remainingMs(lastActivity, now, durationMs) === 0) {
        void expire();
        return;
      }
      if (now - lastWrite < ACTIVITY_THROTTLE_MS) return;
      lastWrite = now;
      lastActivity = now;
      writeStorage(activityKey, String(now));
      setWarning(false);
      schedule();
    }

    function onStorage(event) {
      if (event.key === timeoutKey && event.newValue !== null) {
        void expire();
      } else if (event.key === activityKey) {
        schedule();
      }
    }

    function onResume() {
      if (!document.hidden) schedule();
    }

    async function start() {
      const { data: { session } } = await supabase.auth.getSession();
      if (disposed || !session) return;
      const id = sessionStorageId(session);
      if (!id) return;
      activityKey = "shigyo:last-activity:" + id;
      timeoutKey = "shigyo:session-timeout:" + id;
      window.addEventListener("storage", onStorage);
      window.addEventListener("pointerdown", recordActivity, { passive: true });
      window.addEventListener("pointermove", recordActivity, { passive: true });
      window.addEventListener("keydown", recordActivity);
      window.addEventListener("touchstart", recordActivity, { passive: true });
      window.addEventListener("wheel", recordActivity, { passive: true });
      document.addEventListener("visibilitychange", onResume);
      window.addEventListener("focus", schedule);
      const stored = validActivity(readStorage(activityKey), Date.now());
      if (stored !== null) {
        lastActivity = stored;
      } else if (readStorage(timeoutKey) === null) {
        writeStorage(activityKey, String(lastActivity));
      }
      schedule();
    }

    void start();

    return () => {
      disposed = true;
      clearTimer();
      window.removeEventListener("storage", onStorage);
      window.removeEventListener("pointerdown", recordActivity);
      window.removeEventListener("pointermove", recordActivity);
      window.removeEventListener("keydown", recordActivity);
      window.removeEventListener("touchstart", recordActivity);
      window.removeEventListener("wheel", recordActivity);
      document.removeEventListener("visibilitychange", onResume);
      window.removeEventListener("focus", schedule);
    };
  }, [durationMs, router]);

  if (signOutError) {
    return (
      <div className={styles.notice} role="alert">
        セッションを終了できませんでした。通信状態を確認してページを再読み込みしてください。
      </div>
    );
  }

  return warning ? (
    <div className={styles.notice} role="alert">
      操作がないため、残り1分で自動的にログアウトします。操作を続けると時間が延長されます。
    </div>
  ) : null;
}
