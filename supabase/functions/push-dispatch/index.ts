import { createClient } from 'jsr:@supabase/supabase-js@2';

// Sends one queued notification from public.push_outbox to the user's iOS
// devices through Apple Push Notification service (APNs).
//
// Called by a database trigger (pg_net) with only { id }. It is safe for this
// endpoint to be public: it can only deliver a row that is already queued,
// unsent and recent, and payloads never contain names, message text or other
// personal details (see migration ios_push_notifications).
//
// Required secrets (Supabase > Edge Functions > Secrets):
//   APNS_KEY_ID       Key ID of the .p8 key from developer.apple.com
//   APNS_TEAM_ID      Apple Developer Team ID
//   APNS_PRIVATE_KEY  Full contents of the .p8 file
//   APNS_BUNDLE_ID    optional, defaults to com.rolelantern.ios

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });

function b64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === 'string' ? new TextEncoder().encode(bytes) : bytes;
  let bin = '';
  for (const x of b) bin += String.fromCharCode(x);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

let cachedJwt: { token: string; at: number } | null = null;

async function apnsJwt(keyId: string, teamId: string, pem: string): Promise<string> {
  // APNs accepts a provider token for up to 60 minutes; refresh every 50.
  if (cachedJwt && Date.now() - cachedJwt.at < 50 * 60 * 1000) return cachedJwt.token;
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) }));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(`${header}.${claims}`)));
  const token = `${header}.${claims}.${b64url(sig)}`;
  cachedJwt = { token, at: Date.now() };
  return token;
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);
  const { id } = await req.json().catch(() => ({}));
  if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/i.test(id)) return json({ error: 'id required' }, 400);

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const since = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const { data: row } = await admin.from('push_outbox')
    .select('id,user_id,kind,title,body,deep_link,sent_at,created_at')
    .eq('id', id).is('sent_at', null).gte('created_at', since).maybeSingle();
  if (!row) return json({ ok: true, skipped: true });

  const keyId = Deno.env.get('APNS_KEY_ID');
  const teamId = Deno.env.get('APNS_TEAM_ID');
  const pem = Deno.env.get('APNS_PRIVATE_KEY');
  const bundleId = Deno.env.get('APNS_BUNDLE_ID') ?? 'com.rolelantern.ios';
  if (!keyId || !teamId || !pem) {
    await admin.from('push_outbox').update({ error: 'apns_not_configured' }).eq('id', row.id);
    return json({ ok: false, error: 'apns_not_configured' });
  }

  // Claim the row first so a duplicate call cannot send twice.
  const { data: claimed } = await admin.from('push_outbox')
    .update({ sent_at: new Date().toISOString() }).eq('id', row.id).is('sent_at', null).select('id');
  if (!claimed?.length) return json({ ok: true, skipped: true });

  const { data: tokens } = await admin.from('device_push_tokens')
    .select('id,token,environment').eq('user_id', row.user_id).eq('platform', 'ios');

  const jwt = await apnsJwt(keyId, teamId, pem);
  const payload = JSON.stringify({
    aps: { alert: { title: row.title, body: row.body }, sound: 'default', 'thread-id': row.kind },
    link: row.deep_link,
  });

  const errors: string[] = [];
  for (const t of tokens ?? []) {
    const host = t.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
    try {
      const res = await fetch(`https://${host}/3/device/${t.token}`, {
        method: 'POST',
        headers: {
          authorization: `bearer ${jwt}`,
          'apns-topic': bundleId,
          'apns-push-type': 'alert',
          'apns-priority': '10',
          'content-type': 'application/json',
        },
        body: payload,
      });
      if (!res.ok) {
        const reason = (await res.json().catch(() => ({}))).reason ?? String(res.status);
        errors.push(reason);
        if (res.status === 410 || reason === 'BadDeviceToken' || reason === 'Unregistered') {
          await admin.from('device_push_tokens').delete().eq('id', t.id);
        }
      }
    } catch (e) {
      errors.push(String(e));
    }
  }
  if (errors.length) await admin.from('push_outbox').update({ error: errors.join('; ').slice(0, 500) }).eq('id', row.id);
  return json({ ok: errors.length === 0, sent: (tokens ?? []).length - errors.length });
});
