/// <reference types="vite/client" />

interface ImportMetaEnv {
  /**
   * Supabase-prosjektets URL. Leses av `src/lib/supabase.ts`.
   */
  readonly VITE_SUPABASE_URL?: string
  /**
   * Supabase publishable-nøkkel for nettleserklienten.
   * Legg ALDRI secret-/service_role-nøkler i klientkode eller i repoet;
   * `assertPublishableKey()` avviser dem, men vakten er et supplement til
   * regelen, ikke en erstatning for den.
   */
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
