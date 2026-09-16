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
  /**
   * Endepunktet den rå tekniske årsaken sendes til, når et er valgt.
   * Leses av `src/app/diagnostics-sink.ts`. Uten den går ingenting ut av
   * nettleseren, og oppførselen er som før: én linje i konsollen.
   *
   * Dette er en driftsbeslutning og ingen produktflate — hvilken
   * observability-tjeneste Antidep bruker, hører til deployen (issue #99).
   */
  readonly VITE_ANTIDEP_DIAGNOSTICS_URL?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
