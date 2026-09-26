import { createClient } from 'jsr:@supabase/supabase-js@2';

// Field encryption matching the web app's lib/crypto/field.ts:
//   format = base64( iv(12) | tag(16) | ciphertext ), AES-256-GCM, no AAD.
// The key comes ONLY from the FIELD_ENCRYPTION_KEY secret (Supabase > Edge Functions > Secrets).
// It is never written in code and never reaches the app binary.
const PREFIX = 'enc:v1:';
const IV_LEN = 12;
const TAG_LEN = 16;
const KEY_B64 = Deno.env.get('FIELD_ENCRYPTION_KEY');

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function bytesToB64(bytes: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

async function importKey(): Promise<CryptoKey> {
  if (!KEY_B64) throw new Error('FIELD_ENCRYPTION_KEY secret is not set');
  const raw = b64ToBytes(KEY_B64);
  return await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

async function decryptField(v: string | null): Promise<string | null> {
  if (v == null) return null;
  if (typeof v !== 'string' || !v.startsWith(PREFIX)) return v; // legacy plaintext
  try {
    const buf = b64ToBytes(v.slice(PREFIX.length));
    if (buf.length < IV_LEN + TAG_LEN) return null;
    const iv = buf.subarray(0, IV_LEN);
    const tag = buf.subarray(IV_LEN, IV_LEN + TAG_LEN);
    const ct = buf.subarray(IV_LEN + TAG_LEN);
    // WebCrypto expects ciphertext||tag together.
    const combined = new Uint8Array(ct.length + tag.length);
    combined.set(ct, 0);
    combined.set(tag, ct.length);
    const key = await importKey();
    const ptBuf = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, key, combined);
    return new TextDecoder().decode(ptBuf);
  } catch (_e) {
    return null;
  }
}

async function encryptField(v: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(IV_LEN));
  const key = await importKey();
  const enc = new TextEncoder().encode(v);
  const res = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, enc));
  // WebCrypto returns ciphertext||tag; split tag off and reorder to iv|tag|ct.
  const ct = res.subarray(0, res.length - TAG_LEN);
  const tag = res.subarray(res.length - TAG_LEN);
  const out = new Uint8Array(IV_LEN + TAG_LEN + ct.length);
  out.set(iv, 0);
  out.set(tag, IV_LEN);
  out.set(ct, IV_LEN + TAG_LEN);
  return PREFIX + bytesToB64(out);
}

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const jsonHeaders = { ...cors, 'Content-Type': 'application/json' };

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const authHeader = req.headers.get('Authorization') ?? '';
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  // Client scoped to the caller's JWT, so every query runs under their RLS.
  const supabase = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userErr } = await supabase.auth.getUser();
  if (userErr || !userData?.user) {
    return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: jsonHeaders });
  }

  try {
    const url = new URL(req.url);
    const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {};
    const action = body.action ?? url.searchParams.get('action') ?? 'list';

    if (action === 'threads') {
      // Candidate profile id for the signed-in user.
      const { data: prof } = await supabase.from('candidate_profiles').select('id').limit(1).maybeSingle();
      const candidateId = prof?.id;
      const { data: threads } = await supabase
        .from('message_threads')
        .select('id,candidate_id,company_id,job_id,created_at,last_message_at,last_message_preview,candidate_hidden_at')
        .order('last_message_at', { ascending: false });
      const out = [] as unknown[];
      for (const t of threads ?? []) {
        // Hidden by the candidate, unless a newer message arrived after they deleted it.
        if (t.candidate_hidden_at && (!t.last_message_at || t.last_message_at <= t.candidate_hidden_at)) continue;
        const { candidate_hidden_at: _h, ...rest } = t;
        out.push({ ...rest, last_message_preview: await decryptField(t.last_message_preview) });
      }
      return new Response(JSON.stringify({ threads: out, candidate_id: candidateId }), { headers: jsonHeaders });
    }

    if (action === 'hide' || action === 'unhide') {
      // Candidate-side delete: only hides the conversation from the candidate's list.
      const threadId = body.thread_id;
      if (!threadId) return new Response(JSON.stringify({ error: 'thread_id required' }), { status: 400, headers: jsonHeaders });
      const { data: updated, error } = await supabase
        .from('message_threads')
        .update({ candidate_hidden_at: action === 'hide' ? new Date().toISOString() : null })
        .eq('id', threadId)
        .select('id');
      if (error) throw error;
      if (!updated?.length) return new Response(JSON.stringify({ error: 'Conversation not found.' }), { status: 404, headers: jsonHeaders });
      return new Response(JSON.stringify({ ok: true }), { headers: jsonHeaders });
    }

    if (action === 'list') {
      const threadId = body.thread_id ?? url.searchParams.get('thread_id');
      if (!threadId) return new Response(JSON.stringify({ error: 'thread_id required' }), { status: 400, headers: jsonHeaders });
      // RLS ensures the caller can only read their own thread's messages.
      const { data: msgs, error } = await supabase
        .from('messages')
        .select('id,thread_id,sender_role,sender_user_id,body,created_at,read_at_candidate,read_at_employer')
        .eq('thread_id', threadId)
        .order('created_at', { ascending: true });
      if (error) throw error;
      const out = [] as unknown[];
      for (const m of msgs ?? []) {
        out.push({ ...m, body: await decryptField(m.body) });
      }
      // Mark employer messages as read by the candidate.
      await supabase.from('messages')
        .update({ read_at_candidate: new Date().toISOString() })
        .eq('thread_id', threadId).eq('sender_role', 'employer').is('read_at_candidate', null);
      return new Response(JSON.stringify({ messages: out }), { headers: jsonHeaders });
    }

    if (action === 'send') {
      const threadId = body.thread_id;
      const text = (body.text ?? '').toString();
      if (!threadId || !text.trim()) return new Response(JSON.stringify({ error: 'thread_id and text required' }), { status: 400, headers: jsonHeaders });
      if (text.length > 10000) return new Response(JSON.stringify({ error: 'Message is too long.' }), { status: 400, headers: jsonHeaders });
      const encrypted = await encryptField(text);
      const { data: inserted, error } = await supabase
        .from('messages')
        .insert({ thread_id: threadId, sender_role: 'candidate', sender_user_id: userData.user.id, body: encrypted })
        .select('id,created_at')
        .single();
      if (error) throw error;
      await supabase.from('message_threads')
        .update({ last_message_at: new Date().toISOString(), last_message_preview: encrypted })
        .eq('id', threadId);
      return new Response(JSON.stringify({ ok: true, id: inserted?.id }), { headers: jsonHeaders });
    }

    return new Response(JSON.stringify({ error: 'unknown action' }), { status: 400, headers: jsonHeaders });
  } catch (e) {
    // Log details server-side only; never return internals to the caller.
    console.error(e);
    return new Response(JSON.stringify({ error: 'Something went wrong. Please try again.' }), { status: 500, headers: jsonHeaders });
  }
});
