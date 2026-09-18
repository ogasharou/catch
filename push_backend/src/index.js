import { sendPushNotification } from "@mmmike/web-push/send";

const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
};

function corsHeaders(env, request) {
  const origin = request.headers.get("origin") || "";
  const allowed = env.ALLOWED_ORIGIN || "https://ogasharou.github.io";
  const ok =
    origin === allowed ||
    origin === "http://localhost" ||
    origin.startsWith("http://localhost:") ||
    origin.startsWith("http://127.0.0.1:");

  return {
    "access-control-allow-origin": ok ? origin : allowed,
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "86400",
    "vary": "Origin",
  };
}

function reply(request, env, body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...jsonHeaders,
      ...corsHeaders(env, request),
    },
  });
}

function validDeviceId(value) {
  return /^[a-f0-9]{32,96}$/i.test(String(value || ""));
}

function allowedPushEndpoint(endpoint) {
  try {
    const url = new URL(endpoint);
    if (url.protocol !== "https:") return false;
    const h = url.hostname.toLowerCase();
    return (
      h === "fcm.googleapis.com" ||
      h.endsWith(".push.apple.com") ||
      h.endsWith(".push.services.mozilla.com")
    );
  } catch {
    return false;
  }
}

async function requestJson(request) {
  try {
    return await request.json();
  } catch {
    return {};
  }
}

function vapid(env) {
  return {
    publicKey: env.VAPID_PUBLIC_KEY,
    privateKey: env.VAPID_PRIVATE_KEY,
    subject: env.VAPID_SUBJECT || "https://ogasharou.github.io/catch/",
  };
}

async function sendToDevice(env, deviceId, payload) {
  const row = await env.DB.prepare(
    "SELECT subscription_json FROM subscriptions WHERE device_id = ?1",
  ).bind(deviceId).first();

  if (!row?.subscription_json) {
    return { ok: false, message: "この端末は通知登録されていません" };
  }

  const subscription = JSON.parse(row.subscription_json);
  const delivered = await sendPushNotification(
    subscription,
    payload,
    vapid(env),
    {
      ttl: 86400,
      urgency: "high",
    },
  );

  if (!delivered) {
    await env.DB.prepare(
      "DELETE FROM subscriptions WHERE device_id = ?1",
    ).bind(deviceId).run();
    return { ok: false, message: "通知登録の有効期限が切れました。Catchで再度有効化してください" };
  }

  return { ok: true };
}

async function handleFetch(request, env) {
  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders(env, request),
    });
  }

  const url = new URL(request.url);

  if (request.method === "GET" && url.pathname === "/health") {
    return reply(request, env, { ok: true, service: "Catch Free Push" });
  }

  if (request.method === "GET" && url.pathname === "/vapid-public-key") {
    if (!env.VAPID_PUBLIC_KEY) {
      return reply(request, env, { message: "VAPID key is not configured" }, 500);
    }
    return reply(request, env, { publicKey: env.VAPID_PUBLIC_KEY });
  }

  if (request.method === "POST" && url.pathname === "/subscribe") {
    const body = await requestJson(request);
    const deviceId = String(body.deviceId || "");
    const subscription = body.subscription || {};

    if (!validDeviceId(deviceId)) {
      return reply(request, env, { message: "端末IDが正しくありません" }, 400);
    }
    if (
      !subscription.endpoint ||
      !subscription.keys?.p256dh ||
      !subscription.keys?.auth ||
      !allowedPushEndpoint(subscription.endpoint)
    ) {
      return reply(request, env, { message: "Push購読情報が正しくありません" }, 400);
    }

    await env.DB.prepare(
      `INSERT INTO subscriptions(device_id, subscription_json, updated_at)
       VALUES(?1, ?2, ?3)
       ON CONFLICT(device_id) DO UPDATE SET
         subscription_json = excluded.subscription_json,
         updated_at = excluded.updated_at`,
    ).bind(
      deviceId,
      JSON.stringify(subscription),
      new Date().toISOString(),
    ).run();

    return reply(request, env, { ok: true });
  }

  if (request.method === "POST" && url.pathname === "/reminders/sync") {
    const body = await requestJson(request);
    const deviceId = String(body.deviceId || "");
    const reminders = Array.isArray(body.reminders) ? body.reminders : [];

    if (!validDeviceId(deviceId)) {
      return reply(request, env, { message: "端末IDが正しくありません" }, 400);
    }
    if (reminders.length > 500) {
      return reply(request, env, { message: "通知予定が多すぎます" }, 400);
    }

    const statements = [
      env.DB.prepare("DELETE FROM reminders WHERE device_id = ?1")
        .bind(deviceId),
    ];

    const now = Date.now();
    for (const item of reminders) {
      const id = String(item.id || "").slice(0, 120);
      const notifyAt = String(item.notifyAt || "");
      const when = Date.parse(notifyAt);
      if (!id || !Number.isFinite(when) || when <= now) continue;

      statements.push(
        env.DB.prepare(
          `INSERT INTO reminders(
             device_id, reminder_id, notify_at, title, body, url, tag, sent
           ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, 0)`,
        ).bind(
          deviceId,
          id,
          new Date(when).toISOString(),
          String(item.title || "Catch").slice(0, 120),
          String(item.body || "").slice(0, 300),
          String(item.url || "./").slice(0, 300),
          String(item.tag || "catch-reminder").slice(0, 100),
        ),
      );
    }

    await env.DB.batch(statements);
    return reply(request, env, { ok: true, count: statements.length - 1 });
  }

  if (request.method === "POST" && url.pathname === "/test") {
    const body = await requestJson(request);
    const deviceId = String(body.deviceId || "");

    if (!validDeviceId(deviceId)) {
      return reply(request, env, { message: "端末IDが正しくありません" }, 400);
    }

    try {
      const sent = await sendToDevice(env, deviceId, {
        title: "Catch テスト通知",
        body: "iPhoneのWeb Push通知は正常に動いています。",
        url: "./",
        tag: "catch-test",
      });

      return reply(
        request,
        env,
        sent.ok ? { ok: true } : { message: sent.message },
        sent.ok ? 200 : 409,
      );
    } catch (error) {
      return reply(
        request,
        env,
        { message: "通知送信に失敗しました: " + (error?.message || error) },
        500,
      );
    }
  }

  return reply(request, env, { message: "Not found" }, 404);
}

async function sendDueReminders(env) {
  const now = new Date();
  const cutoff = new Date(now.getTime() - 15 * 60 * 1000);

  const due = await env.DB.prepare(
    `SELECT device_id, reminder_id, title, body, url, tag
     FROM reminders
     WHERE sent = 0
       AND notify_at <= ?1
       AND notify_at >= ?2
     ORDER BY notify_at ASC
     LIMIT 100`,
  ).bind(now.toISOString(), cutoff.toISOString()).all();

  for (const row of due.results || []) {
    try {
      const sent = await sendToDevice(env, row.device_id, {
        title: row.title,
        body: row.body,
        url: row.url || "./",
        tag: row.tag || "catch-reminder",
      });

      if (sent.ok) {
        await env.DB.prepare(
          `UPDATE reminders SET sent = 1
           WHERE device_id = ?1 AND reminder_id = ?2`,
        ).bind(row.device_id, row.reminder_id).run();
      }
    } catch {
      // Keep unsent so the next cron can retry within the 15-minute window.
    }
  }

  // Small cleanup keeps the personal free database tidy.
  const old = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000).toISOString();
  await env.DB.prepare(
    "DELETE FROM reminders WHERE notify_at < ?1",
  ).bind(old).run();
}

export default {
  fetch: handleFetch,

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(sendDueReminders(env));
  },
};
