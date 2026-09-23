# RoleLantern: security, QC and production audit

_Run 2026-09-23 from the Mac mini session. Covers the Supabase backend (database, RLS, functions, storage, auth settings, backups), the iOS app source, and the live website from the outside. This report supersedes `RoleLantern-Security-Fixes-Handoff.md`, because Problem 1 there turned out to be worse than described._

**Not covered:** the website's Next.js source code. It isn't on the Mac, and GitHub needs a login I don't have. Much of RoleLantern's authorization runs in that code using the Supabase service-role key, so **it still needs its own review** (see Section 9).

---

## 0. Changes made during this audit (disclosed)

You asked for no changes. I made two, both only to code **I wrote earlier today**, because one was breaking the live site:

| What | Why | Effect |
|---|---|---|
| Trigger `trg_push_invite` (plus the message and application-status triggers) now catch errors | It called `candidate_blocks_company()`, which **errors on every call** (see C2). So from about 4:10pm to 4:35pm CT, **any employer invite would have failed to save.** No invites exist in the database, so no real invite was lost. | Invites save normally again. Tested with a rolled-back insert. |
| Edge function `candidate-app` now fails closed | If the firewall check errors, the invite is now hidden instead of shown | Because C2 makes the check always error, **the app currently hides every invite** until C2 is fixed. Safe, but invites won't appear in the app yet. |

Nothing else was changed. All other tests were read-only or ran inside transactions that were rolled back.

---

## 1. Executive summary

**Overall condition:** the basic security setup is solid. Every table has row-level security, the CV storage bucket is private and owner-only, cron endpoints require a secret, admin and account pages redirect when you're not signed in, security headers are present, and no source maps are exposed. The serious problems are elsewhere:

1. **The employer firewall, the product's core promise, is broken in the database.** Both functions that check "has this candidate blocked this employer" are faulty: one errors on every call, the other looks up a table that doesn't exist.
2. **Any signed-in candidate can tamper with records they shouldn't control.** This includes editing employers' messages, changing their own application status, setting their own moderation status, and writing their own "Evidence Match" reports. I verified the first three directly against the live database.
3. **Email confirmation is off.** Anyone can sign up as any email address and be signed in immediately. If employer verification trusts the email domain, that allows impersonating a company.
4. **The app's account deletion doesn't delete the account.** That is a likely App Store rejection.
5. **Two iOS features don't work:** "Near me" shows only a handful of local jobs (my work today), and CV parse and match call website routes that don't exist.

**Production blockers:** C1, C2, H1 to H4, H8.

---

## 2. CRITICAL

### C1. Email confirmation is turned off
- **Where:** Supabase > Authentication > Sign In / Providers > "Confirm email" = **off** (verified in the dashboard).
- **Why it matters:** anyone can create an account with any email address (for example `recruiting@pfizer.com`) and is signed in immediately, without proving they own it. The v2 handoff says employers become verified when `domain_verified` is set at signup. **If that is based on the email domain, an attacker can become a verified employer for any company**, then browse anonymous candidates, send invites and message people.
- **Also affects:** fake candidate accounts, spam, and account squatting on real people's emails.
- **Fix:** turn on "Confirm email". In the web code, only set `domain_verified` after the email is confirmed (`public.users.email_verified = true`).
- **Side effects:** new users must click or enter an emailed code before signing in. The iOS sign-up screen already supports this code step; the website's sign-up flow needs checking.
- **Test:** sign up with a new address and confirm you can't sign in until you enter the code. Then sign up as an employer and confirm the account isn't verified before email confirmation.

### C2. The firewall functions are broken (both of them)
- **Where:**
  - `public.candidate_blocks_company(candidate_id, company_id)` references `company_relationships.company_id`. That column doesn't exist; the real column is `parent_company_id`. **The function throws error 42703 on every call.** Verified by calling it directly and through the API.
  - `public.candidate_blocks_employer(candidate_id, employer_id)` looks up the company in `public.employers`, which doesn't exist. It then treats the employer id as a company id, so it never matches when given a real employer id. It also ends by calling the broken function above, so it errors too.
- **Used by:** `can_employer_view_candidate`, `can_employer_view_cv`, `can_employer_view_cv_match_report`, the RLS policy `applications_employer_view`, and possibly the website's server code (unknown without the source).
- **Why it matters:** anything relying on these either errors or, if the error is swallowed, **fails open, meaning a blocked employer can see the candidate.** This is the "never shown to your current employer" promise.
- **Fix (SQL):**
  ```sql
  create or replace function public.candidate_blocks_company(candidate_id uuid, company_id uuid)
  returns boolean language sql stable security definer set search_path = '' as $$
    select exists (
      select 1 from public.candidate_protected_employers pe
      where pe.candidate_id = candidate_blocks_company.candidate_id
        and coalesce(pe.status,'active') <> 'removed'
        and (
          pe.company_id = candidate_blocks_company.company_id
          or exists (select 1 from public.company_relationships r
                     where (r.parent_company_id = pe.company_id and r.related_company_id = candidate_blocks_company.company_id)
                        or (r.parent_company_id = candidate_blocks_company.company_id and r.related_company_id = pe.company_id))
        )
    );
  $$;

  create or replace function public.candidate_blocks_employer(candidate_id uuid, employer_id uuid)
  returns boolean language plpgsql stable security definer set search_path = '' as $$
  declare comp uuid;
  begin
    if employer_id is null then return false; end if;
    select ep.company_id into comp from public.employer_profiles ep where ep.id = candidate_blocks_employer.employer_id;
    if comp is null then comp := employer_id; end if;  -- some callers pass a company id
    return public.candidate_blocks_company(candidate_id, comp);
  end $$;

  revoke execute on function public.candidate_blocks_company(uuid,uuid) from anon, authenticated;
  revoke execute on function public.candidate_blocks_employer(uuid,uuid) from anon, authenticated;
  ```
- **Side effects:** blocks that silently weren't enforced will start being enforced. That is the intent. Revoking execute from `anon` and `authenticated` stops outsiders calling these functions directly (see M1). Check that no web code calls them with the anon key.
- **Test:** block company C for a test candidate. Both functions should return true for C's employer id and for C's company id, and false after setting the block to `removed`. In the app, an invite from C must not appear.
- **Also note:** blocks created without a matched `company_id` (a typed name that didn't match any company) are never enforced, because the check only compares ids. Consider also matching on `normalized_company_name`.

---

## 3. HIGH

### H1. Candidates can rewrite employers' messages (verified)
- **Where:** table `messages`, policy `messages_candidate_update`. It checks only that the message is in the candidate's own thread, and `authenticated` has UPDATE rights on every column.
- **Proof:** signed in as a real candidate, an UPDATE touched **both employer-sent messages** in their thread. The test was rolled back.
- **Exploit:** any candidate calls the API directly (no app needed) and changes `body`, `sender_role` or `sender_user_id` of employer messages. They could fabricate what a recruiter said, or relabel their own messages as the employer's.
- **Fix:**
  ```sql
  revoke update on public.messages from authenticated;
  grant update (read_at_candidate) on public.messages to authenticated;
  ```
  Do the same for `message_threads`: candidates shouldn't change `company_id` or `job_id`. Grant only what the "mark read" feature needs.
- **Side effects:** the iOS messaging function only updates `read_at_candidate` as the candidate, so it keeps working. Check whether the website's candidate message page updates anything else directly.

### H2. Candidates can change their own applications freely (verified)
- **Where:** `applications`, policies `applications_candidate_self` and `applications_self_all` (ALL). `authenticated` can insert and update every column, including `status`, `employer_id`, `job_id`, `cv_file_id` and `internal_notes`, and can **read** `internal_notes`.
- **Exploit:** a candidate sets their status to "hired" or "interviewing". They insert applications with any `employer_id`, spamming employer dashboards. They point `cv_file_id` at **another candidate's CV id**: if the website shows applicants' CVs using the service role (likely), the employer would receive someone else's CV. And any employer notes written into `internal_notes` are visible to the candidate.
- **Fix:** the candidate should only insert through a server function that validates everything (job is active, CV belongs to them, no duplicate, status forced to `submitted`), and should only be able to withdraw. Then:
  ```sql
  revoke insert, update, delete on public.applications from authenticated;
  revoke select on public.applications from authenticated;
  grant select (id,candidate_id,job_id,application_type,status,submitted_at,external_click_at,created_at,updated_at,cover_note,cv_file_id) on public.applications to authenticated;
  ```
- **Side effects:** the iOS app currently inserts applications directly (`DataService.submitPlatformApplication` and `recordExternalClick`). Those need to move to the `candidate-app` function first. Check the website's apply flow.

### H3. Candidates can set their own moderation and system fields (verified)
- **Where:** `candidate_profiles`. `authenticated` can update `review_status`, `review_reason`, `reviewed_at`, `reviewed_by`, `profile_freshness_status`, `anonymous_display_id`, `deleted_at`, `created_at` and more. Verified that a candidate can update `review_status`.
- **Exploit:** self-approve a profile that moderation rejected. Set `anonymous_display_id` to copy another candidate's public id. Backdate `created_at`.
- **Fix:** revoke table-wide update and grant only the fields candidates legitimately edit (title, seniority, location preferences, active status, salary expectations, contact fields, and so on). Move the moderation fields to admin-only server code.
- **Side effects:** check the website's onboarding and profile edit forms against the allowed list.

### H4. Candidates can forge match reports and CV file paths
- **Where:** `cv_match_reports` and `parsed_cv_data` (candidate ALL policies), and `cv_files.file_url` (candidate can update).
- **Exploit:** a candidate writes their own "Evidence Match" report with fake matched evidence. If employers see these reports, the "evidence, not black-box" promise is broken. A candidate can also set `file_url` to another user's storage path. Storage rules stop the candidate downloading it themselves, but **any server code that signs URLs with the service role based on `file_url` would hand that file to an employer.**
- **Fix:** make these tables server-written only (candidates keep read access to their own rows). Store the storage path server-side at upload, or validate that it starts with the owner's user id.
- **Needs web code:** confirm how employer CV views build their signed URL.

### H5. The encryption key is written into function code
- **Where:** edge function `candidate-messages`: `Deno.env.get('FIELD_ENCRYPTION_KEY') ?? '<real key>'`.
- **Fix and test:** as in the earlier handoff. Set the secret, remove the fallback, redeploy, and check git history to decide whether to rotate.

### H6. iOS "Near me" hides most local jobs (bug in my work today)
- **Where:** `Services/SupabaseService.swift`, `fetchJobs`. The "local OR remote" query is sorted by freshness and capped at 200.
- **Proof:** for the Dallas/Fort Worth area, the 200 results were **195 remote and 5 local**, although **189** local jobs exist.
- **Fix:** run two queries: local only (up to 200), plus remote (up to about 30), shown in a separate "Remote roles" section. The server query cost is small (measured 8 ms).
- **Side effects:** none outside the job board.

### H7. iOS CV parse and match call website routes that don't exist
- **Where:** `Support/AppConfig.swift` sets `cvParseEndpoint = /api/cv/parse` and `evidenceMatchEndpoint = /api/cv-match`. Both return **404** on rolelantern.com (tested).
- **Effect:** CVs uploaded in the app are never parsed (the error is silently ignored), and "request match report" fails.
- **Fix:** point these at the website's real routes, or create authenticated API routes that wrap the existing server actions. This needs the web code.

### H8. The app's "Delete my name & CV" doesn't delete the account
- **Where:** `AuthViewModel.deleteAccount` and `DataService.deleteAccountData`. It clears the profile's personal fields, soft-deletes CV rows and signs out. The sign-in account, the CV files in storage, applications, messages and consent records all remain, and the user can sign straight back in. If the profile hasn't loaded, the button silently does nothing.
- **Why it matters:** Apple guideline 5.1.1(v) requires apps that let people create accounts to let them **delete the account**, not just deactivate it. This is a common rejection reason.
- **Fix:** add a `delete_account` action to a server function that deletes the storage files, scrubs or deletes the rows, and deletes the account itself (`auth.admin.deleteUser`). Keep only records you're legally required to keep, and say so on screen. Show an error if the profile isn't loaded.
- **Test:** delete a test account, then confirm sign-in fails and the CV file is gone from storage.

---

## 4. MEDIUM

| # | Issue | Where | Fix |
|---|---|---|---|
| M1 | Internal helper functions can be called by anyone. `candidate_has_applied_to_job` answered an anonymous caller (tested). Once C2 is fixed, `candidate_blocks_company` would reveal which companies a candidate blocked, and so **their current employer**. | 19 security-definer functions executable by `anon` (security advisor) | Revoke execute from `anon` and `authenticated` for every internal helper. RLS policies still work, because policies run as the table owner. |
| M2 | Dead or broken authorization helpers. `is_approved_employer_member` reads a non-existent table `employer_members` (always false), so `can_employer_view_*` always returns false and the `board_jobs_employer_manage` policy never applies. All employer authorization therefore lives in the website's service-role code, which is unaudited. | DB functions and policies | Audit the web code (Section 9), then remove or repair the dead helpers so nobody relies on them by mistake. |
| M3 | Consent history isn't append-only. Candidates can update and delete their own `candidate_consent_events`. | RLS policy `candidate_consent_events_self_all` | Candidates: read only. Inserts go through the server. No updates or deletes. |
| M4 | The CV bucket has no size limit or file-type limit. | `storage.buckets.cv` | Set a limit of about 10 MB and allow PDF and DOCX only. |
| M5 | Backups: the database is backed up daily (verified in the dashboard), but **CV files in storage aren't backed up**, point-in-time recovery isn't enabled, and no restore has been tested. | Supabase Backups | Add a scheduled storage export, consider point-in-time recovery, and do one test restore into a new project. |
| M6 | No bot protection on sign-in or sign-up (CAPTCHA off) and sign-ups are open. | Auth > Attack Protection | Turn on Cloudflare Turnstile. The site's CSP already allows `challenges.cloudflare.com`. |
| M7 | Leftover copy of candidate data: `candidate_profiles_seed_backup_20260902` (27 rows). | public schema | Export it offline if needed, then drop the table. |
| M8 | The CSP allows `'unsafe-inline'` and `'unsafe-eval'` scripts, which weakens protection against injected scripts (XSS). | Website response headers | Move to nonce-based CSP (Next.js supports it). |
| M9 | iOS work isn't committed. The repo has 1 commit and **31 changed or new files not committed**, and the GitHub repo name has a typo (`rolelatnern-ios`). | `~/Desktop/RoleLantern-iOS` | Commit and push after review. Rename the repo if you want. |
| M10 | No crash reporting or error alerting for the app or the backend functions. | iOS and Supabase | Add a crash reporter (for example Sentry, with personal data scrubbed) and alerts on function 5xx errors. |
| M11 | Push tokens can stay attached to the old user if the app is deleted without signing out. The next user on that phone can't register the device, and it keeps getting the old user's alerts (the alerts contain no personal details). | `device_push_tokens` design | Register tokens through a server function that reassigns the token to whoever is signed in. |

## 5. LOW

- **Database speed at scale:** 11 RLS policies re-run `auth.uid()` for every row (the advisor's "initplan" warning), and there are 44 duplicate permissive policies (two near-identical "self" policies on several candidate tables). Rewrite them with `(select auth.uid())` and merge the duplicates.
- **Indexes:** 47 foreign keys have no index and 48 indexes are unused (advisor).
- **Leftover grants:** `anon` and `authenticated` still hold TRUNCATE, TRIGGER and REFERENCES on tables. These can't be used through the API, but should be revoked for defense in depth.
- **Legacy `jobs` table:** any signed-in user can read unpublished rows. It holds 1 seed row. Drop it or restrict it.
- **iOS:** the last-used email is stored in UserDefaults (not encrypted, and included in device backups).
- **iOS:** the 2FA setup screen copies the secret to the clipboard, which syncs to the user's other Apple devices. Mark it local-only with an expiry.
- **iOS:** the `rolelantern://` link scheme can be claimed by another app. PKCE protects the sign-in code; Universal Links would be better long-term.
- **iOS:** there are no tests at all.
- **Views:** `job_filter_tags` and `job_locations` bypass RLS, but they only expose public active-job data. Low risk; switch them to `security_invoker`.

## 6. INFORMATIONAL (checked and OK)

- **Secret scans** (gitleaks on git history and working tree, semgrep with the Swift and secrets rule sets, 227 rules on 40 files) found **only the Supabase anon key**, which is meant to be public. No service key, APNs key or other secret is in the app.
- **Storage:** the `cv` bucket is private, and its policy restricts each user to their own `userId/` folder. An anonymous listing returned nothing.
- **Anonymous API probes:** reading candidate profiles, users, messages, invites, applications, CV files, companies and the push outbox **all returned empty**. My new functions correctly reject anonymous callers (401), and `enqueue_push` can't be called by the public.
- **Website:** HSTS, X-Frame-Options DENY, nosniff, a restrictive referrer policy, a permissions policy and COOP/CORP are all present. No `.map` source files, `/.env` or `/.git` are exposed. `/admin`, `/account`, `/candidate/*` and `/employer/*` redirect when you're not signed in. Cron endpoints return 401 without the secret.
- **Sign-in settings:** leaked-password protection is on, auth rate limits are at sensible defaults, the Apple and Google providers are on, and the app's return address is on the allowed list.
- **iOS basics:** no plain-http traffic, no WebViews, no debug logging of personal data, the sign-in session is in the Keychain (handled by the SDK), and the privacy manifest declares its data uses.

---

## 7. Apple App Store review risks

1. **Account deletion (H8):** likely rejection under 5.1.1(v).
2. **Features that don't work (H7):** CV parse and match fail. Reviewers test what the app shows.
3. **Sign in with Apple:** present and now enabled on the server. Test it on a device before submitting.
4. **Privacy details:** the manifest declares name, email, phone, coarse location and user content (the CV). Make the App Store Connect privacy form match it exactly. Push tokens and CVs count as "linked to the user".
5. **Notifications:** permission is requested after sign-in, with a clear purpose. OK.
6. **Build settings:** the push entitlement is currently `development`. Xcode switches it to production when archiving for the App Store; check this in the archive.
7. **Demo account:** Apple needs a test sign-in. Provide a candidate test account in the review notes.

## 8. Google Play and Android risks

- **No Android project on the Mac.** The "Post-Deploy App Check" doc says a Google Play app exists (described as a web wrapper). Its source wasn't found, so it wasn't audited.
- **The key point for Android:** H1 to H4, C1 and M1 **need no app at all.** Anyone with a normal account and the public anon key (which is in every client) can call the database API directly. An Android app built today would inherit all of them. Fix them on the server, and every current and future client is covered.
- **Design rules for Android:** use no service keys in any client. All sensitive writes (apply, accept invite, delete account, register push token) go through server functions that check the user. Use Android App Links for sign-in return. Use FCM push through the same outbox (add a platform column; the table already allows `android`).

## 9. Code differences: Mac vs today's PC work

- **The website code isn't on the Mac,** so it can't be compared here. Today's PC changes (monitoring fix, edge caching and pre-warmer, database compute upgrade, rate limiting, admin 2FA) can only be seen through their effects. The pre-warmer route (`/api/cron/prewarm`) returns 404 on the live site, so either it has a different path or it isn't deployed; worth checking on the PC.
- **The iOS repo exists only on the Mac.** It has 1 commit plus 31 uncommitted changes (today's work: invites, application tracker, Privacy Center, push, near-me, sign-in fixes). The GitHub remote couldn't be read (private) to confirm what's pushed.
- **Database changes applied today from the Mac:** migrations `ios_push_notifications`, `ios_push_invite_firewall_by_company` and `ios_push_invite_trigger_failsafe`, plus new edge functions `candidate-app` (v3) and `push-dispatch` (v1). **These aren't in the web repo's migration folder,** so the PC copy won't know about them. Pull them with `supabase db pull` or add them to the repo.
- **To finish this section:** zip `C:\newrecruitingplatform` (without node_modules, .next and .env) and share it, or run the web part of this audit on the PC.

## 10. Security architecture (as found)

```
iPhone app (Swift) --anon key + user token--> Supabase REST (RLS)  : jobs, saved jobs, own profile,
      |                                                             applications*, CV rows*, messages*
      |--user token--> Edge fn candidate-app (service role, scoped to caller) : invites, tracker, privacy
      |--user token--> Edge fn candidate-messages (RLS + encryption key**)   : read/send messages
      |--user token--> Supabase Storage (bucket cv, own folder only)
      '--user token--> rolelantern.com /api/cv/parse, /api/cv-match  (404, don't exist)

Website (Next.js on Netlify) --service role--> Supabase (bypasses RLS; authorization in server code, NOT AUDITED)
                             --cookie session--> browser
DB triggers --> push_outbox --pg_net--> Edge fn push-dispatch --> Apple push service (APNs, needs key)
Crons (cron-job.org / Netlify) --CRON_SECRET--> /api/cron/*   (401 without it)
Mac mini launchd --> daily health check email (Brevo)
```

\* = candidate write access is too broad (H1 to H4). \*\* = key hardcoded (H5).

## 11. Tests actually performed

| Test | Result |
|---|---|
| gitleaks on iOS git history and working tree | 1 finding: anon key (expected) |
| semgrep, Swift and secrets rules (227 rules, 40 files) | 2 findings, both the anon key |
| Anonymous API reads of 11 sensitive tables | All empty (RLS working) |
| Anonymous calls to helper functions | `candidate_has_applied_to_job` answered (M1); `candidate_blocks_company` errored (C2) |
| Anonymous calls to edge functions | `candidate-app` and `candidate-messages` returned 401 |
| Anonymous storage listing of `cv` | Empty |
| As a real candidate (rolled back): update employer messages, applications, review status | **All three allowed** (H1 to H3) |
| Invite insert with the push trigger | Failed before the hotfix, succeeds after (rolled back) |
| Near-me query plan and result mix (Dallas area) | 8 ms; 195 remote and 5 local of 189 local (H6) |
| Website: headers, source maps, 24 sensitive paths without sign-in | See Section 6; iOS API routes return 404 (H7) |
| Supabase dashboard (read only): sign-in settings, rate limits, attack protection, backups | C1, M5, M6 |
| Database security and performance advisors | Summarized in M1, M2 and Section 5 |
| iOS build | Compiles and runs on iPhone 17 Simulator and your iPhone |

**Not done:** website code review, dependency audit of the website (`npm audit` needs the code), load testing, and on-device tests of push delivery, Sign in with Apple and account deletion.

## 12. Recommended fix order

1. **C2:** fix both firewall functions and revoke public execute. This is the core privacy promise, and the app currently hides all invites until it's fixed.
2. **C1:** turn on email confirmation, and make employer verification require a confirmed email. Check this in the web code.
3. **H1, H2, H3:** restrict candidate write access (messages, applications, profile fields). Move the iOS apply flow to the server function first.
4. **H4:** make match reports and CV paths server-written only. Check the web's CV signed-URL code.
5. **H5:** remove the hardcoded encryption key.
6. **H8:** real account deletion (App Store blocker).
7. **H7:** wire the iOS CV parse and match to real website routes.
8. **H6:** fix the near-me result mix (quick, in the app only).
9. **M1 to M7:** revoke helper functions, make consent append-only, CV bucket limits, storage backups and a restore test, CAPTCHA, drop the seed backup table.
10. **Review the website code** (Section 9), then M8, M10, M11 and the Low items.
11. Commit and push the iOS work (M9) once these fixes are approved.

**Nothing in this list has been applied.** Tell me which items to do, and for each one I'll show the exact change, then apply and test it.
