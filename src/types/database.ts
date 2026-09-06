// ============================================================================
// Database-typen supabase-js parametriseres med
//
// Bare kontraktslaget `api` finnes her, og det er hele poenget: de kanoniske
// schemaene er ikke eksponert i Data API-et (`supabase/config.toml`), og
// klientrollene mangler uansett usage på dem. En Database-type som listet
// `knowledge` eller `workflow` ville beskrevet en tilgang som ikke finnes.
//
// Typen er håndskrevet framfor generert. Generering krever en kjørende stack,
// og et generert artefakt ville dessuten flatet ut nettopp de skillene
// `./api.ts` bevarer — hvilke vokabularer som er lukkede, og hva NULL betyr i
// hver enkelt kolonne. Radtypene her er derfor de samme objektene UI-koden
// leser.
//
// Formen er bestemt av supabase-js, ikke av oss: `Tables`, `Views` og
// `Functions` må alle finnes, og hver må være et oppslag. Mangler én, eller
// oppfyller en Row ikke `Record<string, unknown>`, forkastes schemaet stille og
// spørringene gir `never` framfor en typefeil. Se merknaden i `./api.ts`.
//
// De tomme oppslagene er `{ [_ in never]: never }` og ikke
// `Record<string, never>`, av samme grunn. supabase-js slår opp en relasjon i
// `Tables & Views`, og `Record<string, never>` gir *hver* nøkkel typen `never`
// — også viewenes. Snittet blir da `never`, hvert view mister radtypen sin, og
// `never` er tilordnbart til alt, så ingenting feiler. Begge feilformene er
// prøvd ut mot kompilatoren, ikke antatt.
//
// Viewene er lesemodell, så de har `Row` og ingen `Insert`/`Update`: forsøk på
// å skrive gjennom dem blir en typefeil. Skriveveien er og blir en kontrollert
// SECURITY DEFINER-funksjon (DATABASE_ARCHITECTURE.md §43). `Tables` står tom:
// ingen tabell er eller skal bli direkte eksponert. `Functions` fikk sitt
// første medlem i migrasjon 007c: `create_source`, den kontrollerte skriveveien
// for å opprette en Source (MVP_IMPLEMENTATION_PLAN.md §29, §74.24), sitt
// andre i migrasjon 007e: `create_evidence_item`, og sitt tredje i migrasjon
// 007f: `create_source_version`. Args-typene speiler
// parametrene i migrasjonene; hvert vokabular og hvert tidsrom er `string` der
// den underliggende kolonnen er en enum eller et interval, av samme grunn som
// migrasjonenes hodekommentarer gir: PostgREST caster JSON-verdien til
// parameterens deklarerte type i kallerens egen sesjon, og authenticated har
// ikke usage på knowledge — en enum-typet parameter ville derfor gjort
// funksjonen ukjørbar for klientrollen, uansett at selve funksjonen er
// SECURITY DEFINER.
// ============================================================================

import type {
  DateText,
  EditorDrugRow,
  EditorEvidenceItemRow,
  EditorOutcomeRow,
  EditorPopulationRow,
  EditorSourceRow,
  EditorSourceVersionRow,
  MyActorRow,
  MyRoleRow,
  PublishedClaimEvidenceRow,
  PublishedClaimRow,
  PublishedDrugRow,
  Uuid,
} from './api'

export type Database = {
  api: {
    Tables: { [_ in never]: never }
    Views: {
      published_drugs: {
        Row: PublishedDrugRow
        Relationships: []
      }
      published_claims: {
        Row: PublishedClaimRow
        Relationships: []
      }
      published_claim_evidence: {
        Row: PublishedClaimEvidenceRow
        Relationships: []
      }
      // Kallerens eget (migrasjon 007b). Ingen av de to er lesbare for `anon`,
      // så en spørring uten sesjon gir avslag og ikke et tomt resultat.
      my_actor: {
        Row: MyActorRow
        Relationships: []
      }
      my_roles: {
        Row: MyRoleRow
        Relationships: []
      }
      // Den redaksjonelle lesemodellen (migrasjon 007d). Heller ikke disse er
      // lesbare for `anon`: de svarer på hva det finnes å registrere mot, og
      // radgrensen er editor-rollen.
      editor_sources: {
        Row: EditorSourceRow
        Relationships: []
      }
      editor_source_versions: {
        Row: EditorSourceVersionRow
        Relationships: []
      }
      editor_drugs: {
        Row: EditorDrugRow
        Relationships: []
      }
      editor_outcomes: {
        Row: EditorOutcomeRow
        Relationships: []
      }
      editor_populations: {
        Row: EditorPopulationRow
        Relationships: []
      }
      editor_evidence_items: {
        Row: EditorEvidenceItemRow
        Relationships: []
      }
    }
    Functions: {
      create_source: {
        Args: {
          p_source_type: string
          p_title: string
          p_authors_or_issuer: string
          p_publisher_or_journal?: string | null
          p_volume?: string | null
          p_issue?: string | null
          p_pages?: string | null
          p_publication_date?: DateText | null
          p_publication_date_precision?: string | null
        }
        Returns: Uuid
      }
      // Det andre medlemmet, fra migrasjon 007e: den kontrollerte skriveveien
      // for å registrere et EvidenceItem. Samme regel som over — hvert
      // vokabular og hvert tidsrom er `string`, fordi funksjonen tar dem imot
      // som `text` og caster dem inne i kroppen. `extraction_method`,
      // `content_hash` og `created_by_actor_id` er ikke parametre: de eies av
      // databasen, ikke av kalleren.
      //
      // Også tallparametrene er `string`, selv om de er `numeric` og `integer`
      // i SQL. PostgREST tar imot en JSON-streng og lar PostgreSQL gjøre
      // casten, og da når et eksakt desimaltall fram uendret — et
      // JavaScript-tall er en IEEE-754 double og ville avrundet et estimat med
      // flere signifikante siffer enn den rommer. Verdiene er kontrollert på
      // form i `lib/evidence-registration.ts` før de kommer hit.
      create_evidence_item: {
        Args: {
          p_source_id: Uuid
          p_design_code: string
          p_population_availability: string
          p_population_detail: string
          p_sample_size_availability: string
          p_intervention_drug_id: Uuid
          p_comparator_kind: string
          p_outcome_concept_id: Uuid
          p_outcome_detail: string
          p_timepoint_availability: string
          p_reported_direction: string
          p_estimate_availability: string
          p_confidence_interval_availability: string
          p_source_locator: string
          p_source_version_id?: Uuid | null
          p_population_id?: Uuid | null
          p_sample_size?: string | null
          p_intervention_detail?: string | null
          p_comparator_drug_id?: Uuid | null
          p_comparator_detail?: string | null
          p_timepoint_min?: string | null
          p_timepoint_max?: string | null
          p_effect_measure?: string | null
          p_estimate?: string | null
          p_estimate_unit?: string | null
          p_ci_lower?: string | null
          p_ci_upper?: string | null
          p_ci_level_percent?: string | null
          p_limitations_text?: string | null
          p_source_quote?: string | null
        }
        Returns: Uuid
      }
      // Det tredje medlemmet, fra migrasjon 007f: den kontrollerte skriveveien
      // for å registrere en kildeversjon (issue #44). `p_retrieved_content` er
      // representasjonen slik den ble hentet, og den er påkrevd — databasen
      // beregner `content_hash` av den. Hashen er derfor ikke en parameter, av
      // samme grunn som `content_hash` ikke er det på et evidensfunn: en verdi
      // klienten kunne oppgi, ville sett ut som en garanti uten å være det.
      //
      // `p_retrieved_at` er `timestamptz` i SQL og en ISO-8601-streng her.
      // Tidspunktet er en hendelse fra virkeligheten (da representasjonen ble
      // hentet), ikke registreringstidspunktet for raden.
      create_source_version: {
        Args: {
          p_source_id: Uuid
          p_retrieved_at: string
          p_retrieved_from: string
          p_retrieved_content: string
          p_external_version?: string | null
          p_storage_reference?: string | null
        }
        Returns: Uuid
      }
    }
  }
}
