// Supabase Edge Function: push
// Recibe webhooks de la DB y envia FCM sin necesitar Firebase Blaze
// Deploy: supabase functions deploy push
// Secret:  supabase secrets set FIREBASE_SERVICE_ACCOUNT='{ "type":"service_account", ... }'

import { createClient } from "npm:@supabase/supabase-js@2";

// ─────────────── tipos ───────────────
interface ServiceAccount {
  project_id: string;
  private_key: string;
  client_email: string;
}

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  record: Record<string, unknown>;
}

// ─────────────── JWT / OAuth2 para FCM ───────────────
function b64url(data: string): string {
  return btoa(data).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function getFCMAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);

  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64url(
    JSON.stringify({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      exp: now + 3600,
      iat: now,
    })
  );

  const sigInput = `${header}.${claim}`;

  const pemBody = sa.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\n/g, "")
    .trim();

  const binaryKey = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const sigBytes = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(sigInput)
  );

  const sig = b64url(String.fromCharCode(...new Uint8Array(sigBytes)));
  const jwt = `${sigInput}.${sig}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  const json = await res.json();
  if (!json.access_token) {
    throw new Error("FCM token failed: " + JSON.stringify(json));
  }
  return json.access_token as string;
}

// ─────────────── enviar FCM (data-only) ───────────────
// Data-only = el background handler de Flutter lo captura aunque la app este cerrada
async function sendFCM(
  projectId: string,
  accessToken: string,
  deviceToken: string,
  data: Record<string, string>
): Promise<void> {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        message: {
          token: deviceToken,
          data, // data-only: Flutter muestra la notificacion con botones
          android: {
            priority: "high",
            direct_boot_ok: true,
          },
        },
      }),
    }
  );
  if (!res.ok) {
    const text = await res.text();
    console.error("FCM error for token", deviceToken.slice(0, 20), text);
  }
}

// ─────────────── helpers ───────────────
function trimMsg(content: string, prefix = ""): string {
  const isFile = content.startsWith("<<FILE>>");
  if (isFile) return prefix ? `${prefix}: envio un archivo` : "Envio un archivo";
  const plain = content.length > 80 ? content.slice(0, 80) + "…" : content;
  return prefix ? `${prefix}: ${plain}` : plain;
}

// ─────────────── handler principal ───────────────
Deno.serve(async (req: Request) => {
  try {
    // Verificar secreto del webhook
    const auth = req.headers.get("Authorization") ?? "";
    const secret = Deno.env.get("WEBHOOK_SECRET") ?? "chatty_push_5f9c3d0e7b8a4c4da1b3f6e9a2c7d5f1";
    if (!auth.includes(secret)) {
      return new Response("Unauthorized", { status: 401 });
    }

    const payload = (await req.json()) as WebhookPayload;
    if (payload.type !== "INSERT") return new Response("OK");

    const saRaw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    if (!saRaw) throw new Error("Falta FIREBASE_SERVICE_ACCOUNT en secrets");
    const sa = JSON.parse(saRaw) as ServiceAccount;

    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const rec = payload.record;
    let notifData: Record<string, string> | null = null;
    let receiverIds: string[] = [];

    // ── Mensaje privado ──
    if (payload.table === "messages") {
      const senderId = rec.sender_id as string;
      const receiverId = rec.receiver_id as string;

      const { data: sender } = await sb
        .from("profiles")
        .select("username")
        .eq("id", senderId)
        .maybeSingle();

      const name = sender?.username ?? "Alguien";
      const body = trimMsg(rec.content as string ?? "");

      notifData = {
        kind: "notify",
        event: "msg",
        title: name,
        body,
        tag: `msg-${senderId}`,
        target: JSON.stringify({ type: "private", friendId: senderId, name }),
      };
      receiverIds = [receiverId];

    // ── Mensaje grupal ──
    } else if (payload.table === "group_messages") {
      const senderId = rec.sender_id as string;
      const groupId = rec.group_id as string;

      const [{ data: group }, { data: sender }, { data: members }] =
        await Promise.all([
          sb.from("groups").select("name").eq("id", groupId).maybeSingle(),
          sb.from("profiles").select("username").eq("id", senderId).maybeSingle(),
          sb.from("group_members").select("user_id").eq("group_id", groupId),
        ]);

      const groupName = group?.name ?? "Grupo";
      const senderName = sender?.username ?? "Alguien";

      notifData = {
        kind: "notify",
        event: "grp-msg",
        title: groupName,
        body: trimMsg(rec.content as string ?? "", senderName),
        tag: `grp-${groupId}`,
        target: JSON.stringify({ type: "group", groupId, groupName }),
      };
      receiverIds = (members ?? [])
        .map((m: { user_id: string }) => m.user_id)
        .filter((id: string) => id !== senderId);

    // ── Llamada entrante de grupo ──
    } else if (payload.table === "group_calls") {
      const initiatorId = rec.initiator_id as string ?? rec.sender_id as string;
      const groupId = rec.group_id as string;

      const [{ data: group }, { data: caller }, { data: members }] =
        await Promise.all([
          sb.from("groups").select("name").eq("id", groupId).maybeSingle(),
          sb.from("profiles").select("username").eq("id", initiatorId).maybeSingle(),
          sb.from("group_members").select("user_id").eq("group_id", groupId),
        ]);

      const callerName = caller?.username ?? "Alguien";
      const groupName = group?.name ?? "Grupo";

      notifData = {
        kind: "notify",
        event: "gcall-incoming",
        title: "ChattyFriends",
        body: `${callerName} inicio una llamada en ${groupName}`,
        tag: "gcall-incoming",
        target: JSON.stringify({ type: "gcall", groupId, groupName }),
      };
      receiverIds = (members ?? [])
        .map((m: { user_id: string }) => m.user_id)
        .filter((id: string) => id !== initiatorId);

    // ── Llamada privada entrante ──
    } else if (payload.table === "call_notifications") {
      const callerId = rec.caller_id as string;
      const receiverId = rec.receiver_id as string;
      const mediaType = (rec.media_type as string) ?? "audio";

      const { data: caller } = await sb
        .from("profiles")
        .select("username")
        .eq("id", callerId)
        .maybeSingle();

      const callerName = caller?.username ?? "Alguien";
      const isVideo = mediaType === "video";

      notifData = {
        kind: "notify",
        event: "call-incoming",
        title: "ChattyFriends",
        body: isVideo
          ? `${callerName}: videollamada entrante`
          : `${callerName}: llamada entrante`,
        tag: "call-incoming",
        target: JSON.stringify({ type: "call", callerId, callerName, mediaType }),
      };
      receiverIds = [receiverId];
    } else {
      return new Response("OK");
    }

    if (!notifData || receiverIds.length === 0) return new Response("OK");

    // Obtener tokens de los receptores
    const { data: tokens } = await sb
      .from("device_tokens")
      .select("token")
      .in("user_id", receiverIds);

    if (!tokens || tokens.length === 0) return new Response("OK");

    // Obtener token FCM y enviar a todos
    const accessToken = await getFCMAccessToken(sa);
    await Promise.all(
      tokens.map(({ token }: { token: string }) =>
        sendFCM(sa.project_id, accessToken, token, notifData!)
      )
    );

    return new Response("OK");
  } catch (err) {
    console.error("push function error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
