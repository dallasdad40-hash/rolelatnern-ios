import { createClient, SupabaseClient } from 'jsr:@supabase/supabase-js@2';

// Candidate-side API for the iOS app: application tracker, invites inbox,
// Privacy Center. The tables behind invites and privacy have no client RLS
// policies (the web reaches them server-side), so this function does the same:
// it verifies the caller's JWT, resolves THEIR candidate profile, and every
// query below is hard-scoped to that candidate id.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const SALARY = ['private', 'private_match_only', 'anonymous_aggregate', 'share_after_apply', 'share_with_approved_employers'];
const REVEAL = ['manual', 'on_accept'];
const BOOL_FIELDS = ['discoverable', 'anonymous_search_optin', 'cv_locked', 'redact_contact_details', 'redact_current_employer', 'auto_protect_parent_subsidiaries'];
const PRIVACY_DEFAULTS = {
  discoverable: false, anonymous_search_optin: false, identity_reveal_policy: 'manual', cv_locked: true,
  redact_contact_details: true, redact_current_employer: true, auto_protect_parent_subsidiaries: true,
  salary_visibility: 'private', invite_limit_per_week: 5,
};

async function jobInfo(admin: SupabaseClient, ids: string[]) {
  const map: Record<string, { job_title: string | null; company_name: string | null; location_text: string | null; status: string | null }> = {};
  const unique = [...new Set(ids.filter(Boolean))];
  if (!unique.length) return map;
  const { data } = await admin.from('board_jobs').select('id,job_title,company_name,location_text,status').in('id', unique);
  for (const j of data ?? []) map[j.id] = j;
  return map;
}

async function employerCompanies(admin: SupabaseClient, employerIds: string[]) {
  const map: Record<string, { company_id: string | null; name: string | null }> = {};
  const unique = [...new Set(employerIds.filter(Boolean))];
  if (!unique.length) return map;
  const { data } = await admin.from('employer_profiles').select('id, company_id, company_profiles(name)').in('id', unique);
  for (const e of data ?? []) {
    // deno-lint-ignore no-explicit-any
    map[e.id] = { company_id: e.company_id ?? null, name: (e as any).company_profiles?.name ?? null };
  }
  return map;
}

// Current-employer firewall. Checks the employer's COMPANY (and its parents /
// subsidiaries via candidate_blocks_company) plus the legacy employer check.
// Fails CLOSED: if the check itself errors, treat the employer as blocked.
async function isBlocked(admin: SupabaseClient, candidateId: string, employerId: string, companyId: string | null) {
  if (companyId) {
    const { data, error } = await admin.rpc('candidate_blocks_company', { candidate_id: candidateId, company_id: companyId });
    if (error) { console.error('firewall check failed', error.code); return true; }
    if (data) return true;
  }
  const { data, error } = await admin.rpc('candidate_blocks_employer', { candidate_id: candidateId, employer_id: employerId });
  if (error) { console.error('firewall check failed', error.code); return true; }
  return !!data;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const authHeader = req.headers.get('Authorization') ?? '';

  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: u, error: uErr } = await userClient.auth.getUser();
  if (uErr || !u?.user) return json({ error: 'unauthorized' }, 401);
  const userId = u.user.id;

  const admin = createClient(url, service, { auth: { persistSession: false } });
  const body = await req.json().catch(() => ({}));
  const action: string = body.action ?? '';
  const ua = req.headers.get('user-agent') ?? 'RoleLantern iOS';

  const { data: prof } = await admin.from('candidate_profiles')
    .select('id').eq('user_id', userId).is('deleted_at', null).limit(1).maybeSingle();
  // Account deletion must work even without an active candidate profile.
  if (!prof?.id && action !== 'delete_account') return json({ error: 'no candidate profile' }, 403);
  const candidateId: string = prof?.id ?? '';

  try {
    // ---------- Application tracker ----------
    if (action === 'applications') {
      const { data: apps, error } = await admin.from('applications')
        .select('id,job_id,application_type,status,submitted_at,external_click_at,created_at,updated_at')
        .eq('candidate_id', candidateId)
        .is('candidate_hidden_at', null)
        .order('created_at', { ascending: false });
      if (error) throw error;
      const jobs = await jobInfo(admin, (apps ?? []).map((a) => a.job_id));
      return json({
        applications: (apps ?? []).map((a) => ({
          ...a,
          job_title: jobs[a.job_id]?.job_title ?? null,
          company_name: jobs[a.job_id]?.company_name ?? null,
          location_text: jobs[a.job_id]?.location_text ?? null,
          job_status: jobs[a.job_id]?.status ?? null,
        })),
      });
    }

    // ---------- Invites inbox ----------
    if (action === 'invites') {
      const { data: invites, error } = await admin.from('employer_candidate_invites')
        .select('id,job_id,employer_id,status,message,sent_at,responded_at')
        .eq('candidate_id', candidateId)
        .is('candidate_hidden_at', null)
        .order('sent_at', { ascending: false });
      if (error) throw error;
      const companies = await employerCompanies(admin, (invites ?? []).map((i) => i.employer_id));
      const visible = [];
      for (const inv of invites ?? []) {
        if (!(await isBlocked(admin, candidateId, inv.employer_id, companies[inv.employer_id]?.company_id ?? null))) visible.push(inv);
      }
      const jobs = await jobInfo(admin, visible.map((i) => i.job_id));
      // Status stays 'sent' until answered: the website only accepts/declines 'sent' invites.
      // For accepted invites, report whether the CV went with them (the application has a CV).
      const acceptedJobIds = visible.filter((i) => i.status === 'accepted').map((i) => i.job_id);
      const cvShared = new Set<string>();
      if (acceptedJobIds.length) {
        const { data: apps } = await admin.from('applications').select('job_id')
          .eq('candidate_id', candidateId).in('job_id', acceptedJobIds).not('cv_file_id', 'is', null);
        for (const a of apps ?? []) cvShared.add(a.job_id);
      }
      return json({
        invites: visible.map((i) => ({
          id: i.id, job_id: i.job_id, status: i.status, message: i.message, sent_at: i.sent_at, responded_at: i.responded_at,
          job_title: jobs[i.job_id]?.job_title ?? null,
          company_name: companies[i.employer_id]?.name ?? jobs[i.job_id]?.company_name ?? null,
          location_text: jobs[i.job_id]?.location_text ?? null,
          cv_shared: cvShared.has(i.job_id),
        })),
      });
    }

    // Accept / decline / stop sharing now go through the website's mobile API
    // (/api/mobile/invites/{id}/accept|decline|revoke) so consent matches the web:
    // name, email and LinkedIn only, CV only if the candidate ticks the box.
    if (action === 'invite_respond') {
      return json({ error: 'Please update the RoleLantern app to answer invites.' }, 410);
    }

    // ---------- Remove from my lists (candidate view only) ----------
    if (action === 'hide_application' || action === 'unhide_application') {
      const id = String(body.id ?? '');
      const { data, error } = await admin.from('applications')
        .update({ candidate_hidden_at: action === 'hide_application' ? new Date().toISOString() : null })
        .eq('id', id).eq('candidate_id', candidateId).select('id');
      if (error) throw error;
      if (!data?.length) return json({ error: 'Not found.' }, 404);
      return json({ ok: true });
    }

    if (action === 'hide_invite' || action === 'unhide_invite') {
      const id = String(body.id ?? '');
      const { data: inv } = await admin.from('employer_candidate_invites')
        .select('id,status').eq('id', id).eq('candidate_id', candidateId).maybeSingle();
      if (!inv) return json({ error: 'Not found.' }, 404);
      const now = new Date().toISOString();
      if (action === 'hide_invite') {
        // Removing an unanswered invite means "not interested": decline it too, so the
        // employer isn't left waiting. Answered invites are only hidden.
        const patch: Record<string, unknown> = { candidate_hidden_at: now };
        if (['sent', 'viewed'].includes(inv.status)) { patch.status = 'declined'; patch.responded_at = now; }
        await admin.from('employer_candidate_invites').update(patch).eq('id', inv.id);
      } else {
        await admin.from('employer_candidate_invites').update({ candidate_hidden_at: null }).eq('id', inv.id);
      }
      return json({ ok: true });
    }

    // ---------- Privacy Center ----------
    if (action === 'privacy_get') {
      const { data: row } = await admin.from('candidate_privacy_center').select('*').eq('candidate_id', candidateId).maybeSingle();
      const { data: blocks } = await admin.from('candidate_protected_employers')
        .select('id,company_name_raw,relationship_type,created_at')
        .eq('candidate_id', candidateId).neq('status', 'removed_by_candidate').order('created_at', { ascending: false });
      const { data: audit } = await admin.from('candidate_privacy_audit')
        .select('id,kind,detail,created_at').eq('candidate_id', candidateId)
        .order('created_at', { ascending: false }).limit(25);
      const settings = { ...PRIVACY_DEFAULTS, ...(row ?? {}) } as Record<string, unknown>;
      delete settings.candidate_id;
      return json({ settings, blocked_employers: blocks ?? [], audit: audit ?? [] });
    }

    if (action === 'privacy_update') {
      const input = body.settings ?? {};
      const patch: Record<string, unknown> = {};
      for (const f of BOOL_FIELDS) if (typeof input[f] === 'boolean') patch[f] = input[f];
      if (typeof input.identity_reveal_policy === 'string' && REVEAL.includes(input.identity_reveal_policy)) patch.identity_reveal_policy = input.identity_reveal_policy;
      if (typeof input.salary_visibility === 'string' && SALARY.includes(input.salary_visibility)) patch.salary_visibility = input.salary_visibility;
      if (Number.isInteger(input.invite_limit_per_week) && input.invite_limit_per_week >= 0 && input.invite_limit_per_week <= 50) patch.invite_limit_per_week = input.invite_limit_per_week;
      if (!Object.keys(patch).length) return json({ error: 'nothing to update' }, 400);

      const { data: before } = await admin.from('candidate_privacy_center').select('*').eq('candidate_id', candidateId).maybeSingle();
      const prev = { ...PRIVACY_DEFAULTS, ...(before ?? {}) } as Record<string, unknown>;
      const { error } = await admin.from('candidate_privacy_center')
        .upsert({ ...prev, ...patch, candidate_id: candidateId, updated_at: new Date().toISOString() }, { onConflict: 'candidate_id' });
      if (error) throw error;

      const changes = Object.keys(patch).filter((k) => prev[k] !== patch[k]);
      if (changes.length) {
        await admin.from('candidate_privacy_audit').insert(changes.map((k) => ({
          candidate_id: candidateId, kind: 'setting_changed', detail: `${k}: ${String(prev[k])} -> ${String(patch[k])} (iOS app)`,
        })));
        if (changes.includes('discoverable') || changes.includes('anonymous_search_optin')) {
          await admin.from('candidate_consent_events').insert({
            candidate_id: candidateId, consent_type: 'profile_visibility_change', consent_version: 'ios-v1',
            consent_text: `discoverable=${patch.discoverable ?? prev.discoverable}, anonymous_search_optin=${patch.anonymous_search_optin ?? prev.anonymous_search_optin}`,
            user_agent: ua,
          });
        }
        if (changes.includes('salary_visibility') && patch.salary_visibility !== 'private') {
          await admin.from('candidate_consent_events').insert({
            candidate_id: candidateId, consent_type: 'salary_visibility_enabled', consent_version: 'ios-v1',
            consent_text: `salary_visibility=${patch.salary_visibility}`, user_agent: ua,
          });
        }
      }
      return json({ ok: true });
    }

    if (action === 'block_employer') {
      const name = String(body.company_name ?? '').trim();
      if (name.length < 2 || name.length > 120) return json({ error: 'Enter a company name.' }, 400);
      const normalized = name.toLowerCase().replace(/[^a-z0-9 ]/g, '')
        .replace(/\b(inc|llc|ltd|corp|corporation|co|plc|gmbh|ag)\b/g, '').replace(/\s+/g, ' ').trim();
      const { data: company } = await admin.from('company_profiles').select('id').eq('normalized_name', normalized).limit(1).maybeSingle();
      const { error } = await admin.from('candidate_protected_employers').insert({
        candidate_id: candidateId, company_id: company?.id ?? null, company_name_raw: name,
        normalized_company_name: normalized, relationship_type: 'manual_block', source: 'candidate_manual', status: 'active',
      });
      if (error) throw error;
      await admin.from('candidate_privacy_audit').insert({ candidate_id: candidateId, kind: 'employer_blocked', detail: `${name} (iOS app)` });
      return json({ ok: true });
    }

    if (action === 'unblock_employer') {
      const id = String(body.id ?? '');
      const { data: row } = await admin.from('candidate_protected_employers').select('id,company_name_raw')
        .eq('id', id).eq('candidate_id', candidateId).maybeSingle();
      if (!row) return json({ error: 'Not found.' }, 404);
      await admin.from('candidate_protected_employers').update({ status: 'removed_by_candidate', updated_at: new Date().toISOString() }).eq('id', row.id);
      await admin.from('candidate_privacy_audit').insert({ candidate_id: candidateId, kind: 'employer_unblocked', detail: `${row.company_name_raw ?? ''} (iOS app)` });
      return json({ ok: true });
    }


    // ---------- Apply (in-app partner apply) ----------
    if (action === 'apply') {
      const jobId = String(body.job_id ?? '');
      const coverNote = body.cover_note == null ? null : String(body.cover_note).slice(0, 4000);
      const { data: job } = await admin.from('board_jobs')
        .select('id,status,expires_at,job_type,company_id').eq('id', jobId).maybeSingle();
      if (!job || job.status !== 'active' || (job.expires_at && new Date(job.expires_at) < new Date())) {
        return json({ error: 'This role is no longer open.' }, 410);
      }
      if (job.job_type !== 'partner_apply') return json({ error: 'Apply on the company site for this role.' }, 400);
      const { data: cv } = await admin.from('cv_files').select('id')
        .eq('candidate_id', candidateId).is('deleted_at', null)
        .order('uploaded_at', { ascending: false }).limit(1).maybeSingle();
      if (!cv?.id) return json({ error: 'Upload a CV before applying.' }, 422);
      const { data: existing } = await admin.from('applications').select('id')
        .eq('candidate_id', candidateId).eq('job_id', jobId).eq('application_type', 'platform_application').maybeSingle();
      if (existing) return json({ error: "You've already applied to this role." }, 409);
      let employerId: string | null = null;
      if (job.company_id) {
        const { data: ep } = await admin.from('employer_profiles').select('id').eq('company_id', job.company_id).limit(1).maybeSingle();
        employerId = ep?.id ?? null;
      }
      const now = new Date().toISOString();
      const { error } = await admin.from('applications').insert({
        candidate_id: candidateId, job_id: jobId, employer_id: employerId,
        application_type: 'platform_application', status: 'submitted', cv_file_id: cv.id,
        cover_note: coverNote, submitted_at: now, consent_at: now, consent_version: 'ios-v1',
      });
      if (error) throw error;
      await admin.from('candidate_consent_events').insert({
        candidate_id: candidateId, employer_id: employerId, job_id: jobId,
        consent_type: 'cv_shared_with_employer', consent_version: 'ios-v1',
        consent_text: 'Applied in the iOS app; CV shared with this employer.', user_agent: ua,
      });
      return json({ ok: true });
    }

    // ---------- Record an external "apply on company site" click ----------
    if (action === 'external_click') {
      const jobId = String(body.job_id ?? '');
      const { data: job } = await admin.from('board_jobs').select('id,status').eq('id', jobId).maybeSingle();
      if (!job) return json({ error: 'Role not found.' }, 404);
      const { data: existing } = await admin.from('applications').select('id')
        .eq('candidate_id', candidateId).eq('job_id', jobId).eq('application_type', 'external_click').maybeSingle();
      if (!existing) {
        const { error } = await admin.from('applications').insert({
          candidate_id: candidateId, job_id: jobId, application_type: 'external_click',
          status: 'clicked', external_click_at: new Date().toISOString(),
        });
        if (error) throw error;
      }
      return json({ ok: true });
    }

    // ---------- Delete account (Apple 5.1.1(v)) ----------
    if (action === 'delete_account') {
      if (body.confirm !== 'DELETE') return json({ error: 'Confirmation missing.' }, 400);
      const { data: role } = await admin.from('users').select('role').eq('id', userId).maybeSingle();
      if (role && role.role !== 'candidate') {
        return json({ error: 'Employer and admin accounts are deleted through support@rolelantern.com.' }, 403);
      }
      // 1) CV files in storage (everything under the user's own folder).
      for (let i = 0; i < 20; i++) {
        const { data: objs } = await admin.storage.from('cv').list(userId, { limit: 100 });
        if (!objs?.length) break;
        await admin.storage.from('cv').remove(objs.map((o) => `${userId}/${o.name}`));
      }
      // 2) Database rows. Deleting public.users cascades to the candidate profile and
      //    everything hanging off it (CVs, applications, messages, invites, consents...).
      await admin.from('concierge_requests').delete().eq('user_id', userId);
      await admin.from('device_push_tokens').delete().eq('user_id', userId);
      const { error: delErr } = await admin.from('users').delete().eq('id', userId);
      if (delErr) throw delErr;
      // 3) The sign-in account itself.
      const { error: authErr } = await admin.auth.admin.deleteUser(userId);
      if (authErr) throw authErr;
      return json({ ok: true });
    }

    return json({ error: 'unknown action' }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: 'Something went wrong. Please try again.' }, 500);
  }
});
