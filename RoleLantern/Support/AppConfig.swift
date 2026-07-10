import Foundation

/// Central configuration. Values verified against the live Supabase project on 2026-07-09.
enum AppConfig {
    /// Supabase project (same backend as rolelantern.netlify.app).
    static let supabaseURL = URL(string: "https://vvxuijdzogzebnlcgxhx.supabase.co")!

    /// Public anon key — safe to ship; RLS protects all data. Never embed the service-role key.
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2eHVpamR6b2d6ZWJubGNneGh4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE2NDIwNzQsImV4cCI6MjA5NzIxODA3NH0.Uo-RE1zCybxXy5KSJ8O-gMc0Ryxqpqtr7KaGE9McEG4"

    /// Deep-link redirect used for OAuth and magic links.
    /// Must be added to Supabase Auth → URL Configuration → Redirect URLs.
    static let authRedirectURL = URL(string: "rolelantern://auth-callback")!

    /// Existing web app — used for employer/admin link-out and sensitive server endpoints
    /// (CV parse, identity reveal, evidence match) per the handoff's hybrid recommendation.
    static let webBaseURL = URL(string: "https://rolelantern.netlify.app")!

    /// Server endpoints on the existing Next.js app (keep encryption/authorization in one place).
    /// TODO(founder): confirm exact API routes on the web side before release.
    static var cvParseEndpoint: URL { webBaseURL.appendingPathComponent("api/cv/parse") }
    static var evidenceMatchEndpoint: URL { webBaseURL.appendingPathComponent("api/cv-match") }

    /// Private storage bucket for CV files (verified: bucket `cv`, public = false).
    static let cvBucket = "cv"
}
