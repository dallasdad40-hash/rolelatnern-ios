# RoleLantern iOS

Native SwiftUI candidate app for RoleLantern, built to the iOS handoff spec against the **live production backend** (Supabase project `vvxuijdzogzebnlcgxhx` — schema and anon key verified 2026-07-09).

## Open and run

1. Requires **Xcode 16 or newer** (project uses the modern folder-synced format) and iOS 16+ devices.
2. Open `RoleLantern.xcodeproj`. Xcode will resolve the `supabase-swift` package automatically (SPM, from GitHub).
3. In **Signing & Capabilities**, select your Apple Developer team. The Sign in with Apple capability is pre-configured.
4. Build and run. The app is wired to production data — sign up with a test email to try it.

## What's included (MVP v1 per §13 of the handoff)

Auth: email/password, Google OAuth, magic link, Sign in with Apple (native, App Store requirement), TOTP 2FA (enroll with QR + login challenge, mirrors the web flow). Session persists in the Keychain via the SDK.

Candidate app: job board with search + filters (function, therapeutic area, location, remote), boosted-first ordering, freshness badges; job detail with key requirements, trust panel, and Evidence Match panel; apply flows (external via in-app Safari with `external_click` recorded; partner apply in-app, requires a CV, duplicates blocked); saved jobs; CV upload to the private `cv` bucket with server-side parse trigger; dashboard with availability toggle and applications list; account screen with password change, 2FA setup, sign-out-everywhere, and Apple-required in-app **Delete my name & CV** (scrubs PII, soft-deletes CVs, signs out globally).

Employers/admins are routed to the web app, per the handoff.

Compliance: `PrivacyInfo.xcprivacy` (no tracking, data not sold), `ITSAppUsesNonExemptEncryption = NO`, HTTPS only, private CV storage with short-lived signed URLs for viewing.

## Before you ship — founder checklist

1. **Supabase Auth redirect URL** — add `rolelantern://auth-callback` in Supabase Dashboard → Auth → URL Configuration. OAuth and magic links will not return to the app without this.
2. **Apple OAuth provider** — enable Apple as a provider in Supabase Auth (needed for native Sign in with Apple token exchange), and Google if not already configured for mobile.
3. **Server endpoints** — `AppConfig.swift` points CV parse and evidence match at `rolelantern.netlify.app/api/cv/parse` and `/api/cv-match`. Confirm the actual route names in your Next.js app and adjust; they're called with the user's Supabase JWT as a bearer token. If the routes differ, only `AppConfig.swift` needs editing. Failures are non-fatal (CV upload still works; parse can run later).
4. **Application status strings** — verified live values: `application_type` ∈ `external_click | platform_application` (DB check constraint), platform status `submitted`. External clicks are recorded with status `clicked` — confirm the web tracker displays this sensibly or align the string.
5. **First-run profile creation** — if a candidate signs up in the app without web onboarding, the app inserts a minimal `candidate_profiles` row (generated `anonymous_display_id`, format `RL-XXXXXXXX`). If your web app generates these IDs differently or via trigger, align `DataService.createProfile`.
6. **App icon** — rebuilt as vector art to match the founder-provided logo (`Design/RoleLantern-AppIcon.svg`; the 1024px PNG is already in the asset catalog). If you want the original raster file pixel-for-pixel instead, drop it over `RoleLantern/Assets.xcassets/AppIcon.appiconset/RoleLantern-AppIcon-1024.png`.
7. **Bundle ID** — currently `com.rolelantern.ios`; change in target settings if you registered a different one.
8. **Legal links** — Account screen links to `/privacy` and `/terms` on the web app; confirm those routes exist once attorney review lands.
9. Not in v1 (per phasing): applications tracker screen, invites inbox, Privacy Center (links to web), messaging, push notifications. The data layer already models applications, so v1.1 is mostly UI.

## Project layout

- `RoleLantern/Support` — config, theme (brand palette §8), reusable components, lantern mark drawn natively
- `RoleLantern/Models` — Codable models matching the live schema
- `RoleLantern/Services` — `DataService`: all Supabase reads/writes (RLS-scoped) + authenticated calls to web endpoints
- `RoleLantern/Features` — Auth, Jobs, Insights (CV + match), Dashboard, Account
- `Design/` — recreated icon SVG source
