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
          /** Hva slags representasjon som ble hentet (migrasjon 003b). */
          p_representation?: string | null
        }
        Returns: Uuid
      }
      // 003e: kildeversjonen som er utledet av et originaldokument. Kalleren
      // sender **bytene** som base64, ikke fingeravtrykket: hashen, størrelsen
      // og mediatypen avleses av databasen av dokumentet selv, slik at ingen av
      // dem er en påstand kalleren skriver om seg selv. Dokumentet lagres ikke.
      create_source_version_from_document: {
        Args: {
          p_source_id: Uuid
          p_retrieved_at: string
          p_retrieved_from: string
          /** Originaldokumentet, base64-kodet, byte for byte slik filen er. */
          p_document_base64: string
          /** Teksten oppskriften ga. Databasen hasher den til content_hash. */
          p_extracted_text: string
          /** Påkrevd her, til forskjell fra tekstveien (migrasjon 003e). */
          p_representation: string
          p_text_extraction_tool: string
          p_text_extraction_tool_version: string
          p_text_extraction_arguments: string
          /** Antideps egen etterbehandling av verktøyets utdata (migrasjon 003g). */
          p_text_extraction_transform: string
          p_external_version?: string | null
          p_storage_reference?: string | null
        }
        Returns: Uuid
      }
      // 007i: hele ekstraksjonsoppdraget, bygget av databasens egne rader.
      // Svaret er `unknown` og ikke en form, av samme grunn som lesegrunnlagene
      // under: det er jsonb, og en jsonb-form har ingen kolonnetyper PostgREST
      // kan håndheve. Det leses av `parseExtractionAssignment`, som avviser alt
      // som ikke er kontrakten framfor å gjette.
      build_extraction_assignment: {
        Args: {
          p_source_version_id: Uuid
          p_drug_names: readonly string[]
          p_outcome_labels: readonly string[]
          p_population_labels?: readonly string[]
        }
        Returns: unknown
      }
      // De tre neste er den menneskelige reviewflyten (migrasjon 005n, 005o og
      // 006d). Lesegrunnlaget og de to beslutningene er tre kall og ikke ett:
      // den faglige kontrollen mot grunnlaget og godkjenningen av at påstanden
      // kan publiseres er to forskjellige faglige utsagn, og publiseringsgaten
      // krever dem hver for seg (ANTIDEP_CONSTITUTION.md §11 og §12).
      //
      // Svaret fra lesegrunnlaget er `unknown` og ikke en form: det er jsonb, og
      // en jsonb-form har ingen kolonnetyper PostgREST kan håndheve. Den leses
      // av `lib/review-workspace.ts`, som avviser et svar uten den formen
      // kontrakten dokumenterer framfor å gjette.
      claim_review_workspace: {
        Args: {
          p_claim_revision_id?: Uuid | null
        }
        Returns: unknown
      }
      // `p_seen_evidence_set_digest` er avtrykket flaten faktisk viste, sendt
      // tilbake uendret. Databasen sammenligner det med settet slik det er nå og
      // avviser hvis en evidenslenke er kommet til mens vurderingen pågikk.
      register_human_claim_verification: {
        Args: {
          p_claim_revision_id: Uuid
          p_seen_evidence_set_digest: string
          p_outcome: string
          p_source_support: string
          p_population_match: string
          p_comparator_match: string
          p_timeframe_match: string
          p_direction_and_magnitude: string
          p_qualifiers_complete: string
          p_contradictory_evidence_represented: string
          p_citations: readonly {
            claim_evidence_link_id: Uuid
            source_access: string
            source_version_id: Uuid | null
            checked_content_hash: string | null
            relationship_supported: string
            finding: string | null
          }[]
          p_rationale: string
          p_findings?: string | null
        }
        Returns: Uuid
      }
      register_publication_approval: {
        Args: {
          p_claim_revision_id: Uuid
          p_seen_evidence_set_digest: string
          p_decision: string
          p_rationale: string
        }
        Returns: Uuid
      }
      // De to neste er den menneskelige ekstraksjonskontrollen (migrasjon 005s
      // og 005t): kontrollen av at et evidensfunn faktisk gjengir det kilden
      // rapporterer. Den er et annet ledd enn kontrollen av at grunnlaget
      // støtter påstanden, og publiseringsgaten krever dem hver for seg (G5 og
      // G9).
      //
      // Svaret fra lesegrunnlaget er `unknown` av samme grunn som for
      // claim_review_workspace: det er jsonb, og formen leses av
      // `lib/extraction-review.ts`.
      extraction_review_workspace: {
        Args: {
          p_evidence_item_id?: Uuid | null
        }
        Returns: unknown
      }
      // `p_checked_fields` er `text[]` i SQL og en liste av strenger her:
      // vokabularet er en enum i `workflow`, som authenticated ikke har usage
      // på, så parameteren tar imot tekst og castes inne i kroppen — samme
      // begrunnelse som for de øvrige vokabularparametrene.
      //
      // `p_seen_extraction_digest` er avtrykket flaten faktisk viste, sendt
      // tilbake uendret. Databasen sammenligner det med grunnlaget slik det er
      // nå, under radlåsen, og avviser hvis kildeversjonen, kildens status eller
      // kontrollhistorikken er endret mens vurderingen pågikk.
      register_human_extraction_verification: {
        Args: {
          p_evidence_item_id: Uuid
          p_seen_extraction_digest: string
          p_outcome: string
          p_source_access: string
          p_checked_fields: readonly string[]
          p_rationale: string
          p_findings?: string | null
        }
        Returns: Uuid
      }
      // Migrasjon 009f: publiseringen, tilbaketrekkingen og rollbacken.
      //
      // Det som publiseres er et forseglet kandidatinnhold, ikke en revisjon:
      // Den klinikervennlige arbeidsflaten (migrasjon 012a).
      //
      // `public_work_board` er den ene funksjonen `anon` får: hva Antidep
      // arbeider med, i et lukket produktvokabular og uten en eneste intern
      // verdi. De øvrige krever mandat, og `technical_problem_summary` svarer
      // stille «ikke synlig» til alle som ikke har admin — et avslag der ville
      // blitt til en feilmelding på hver side for hver innlogget bruker.
      public_work_board: {
        Args: Record<string, never>
        Returns: unknown
      }
      // Fulltekstinnboksen. Referansen er databasens eget ugjennomsiktige
      // håndtak og aldri en uuid: flaten skal kunne peke på en artikkel uten at
      // en intern id står på skjermen.
      full_text_inbox: {
        Args: Record<string, never>
        Returns: unknown
      }
      submit_full_text: {
        Args: {
          p_reference: string
          p_document_base64: string
        }
        Returns: unknown
      }
      // Forespørselen bærer den redaksjonelle avgrensningen ekstraksjonsoppgaven
      // senere bygges av, slik at den som laster opp PDF-en ikke blir spurt om
      // noe som allerede er bestemt.
      request_full_text: {
        Args: {
          p_source_id: Uuid
          p_drug_ids: readonly Uuid[]
          p_outcome_concept_ids: readonly Uuid[]
          p_population_ids?: readonly Uuid[]
          p_retrieved_from?: string | null
        }
        Returns: unknown
      }
      // Antideps eget tekstuttrekk. Kalles av den tekniske arbeideren
      // (`npm run ops:full-text`), aldri av nettleseren: oppskriften må kjøres
      // der `pdftotext` faktisk finnes.
      claim_full_text_extraction: {
        Args: {
          p_lease_seconds?: number
        }
        Returns: unknown
      }
      complete_full_text_extraction: {
        Args: {
          p_handle: Uuid
          p_extracted_text: string
          p_text_extraction_tool_version: string
        }
        Returns: unknown
      }
      fail_full_text_extraction: {
        Args: {
          p_handle: Uuid
          p_stage: string
        }
        Returns: unknown
      }
      // Veien tilbake fra et driftsproblem. Arbeideren kaller den når den har
      // kontrollert at verktøyet oppskriften krever finnes, og alt som sto
      // blokkert, går i kø igjen — uten at noen blir bedt om å laste opp
      // filen på nytt.
      resume_blocked_full_text_extractions: {
        Args: Record<string, never>
        Returns: unknown
      }
      // Den tekniske problemoversikten. Diagnosen er ikke med i noen av dem, og
      // kan ikke leses gjennom noe api-objekt.
      technical_problem_board: {
        Args: Record<string, never>
        Returns: unknown
      }
      technical_problem_summary: {
        Args: Record<string, never>
        Returns: unknown
      }
      // Selvmeldingen fra en brukerflate, og den ene veien den rå årsaken
      // bevares varig.
      //
      // De seks første er maskinidentifikatorer: område, svikttype og
      // transportform er lukkede vokabularer, operasjonen kontrolleres mot
      // funksjonene som finnes i api, koden må være en SQLSTATE eller en
      // PostgREST-kode, og statusen må være en HTTP-status. De skriver
      // tilstandsraden, der setningen er Antideps egen.
      //
      // Den rå årsaken hører ikke hjemme her. Den går sin egen vei, gjennom
      // ruten `/diagnostics` og videre til `api.record_client_diagnostic`,
      // fordi den skal kunne nå fram selv når dette kallet ikke gjør det.
      //
      // Det finnes ingen lukking herfra. En selvmeldt rad gjelder så lenge den
      // fornyes, og databasen avgjør når den er over: en opprydding som hvilte
      // på flatens eget minne, ville vært borte ved første sideoppfriskning.
      report_technical_problem: {
        Args: {
          p_area: string
          p_kind: string
          p_operation?: string | null
          p_code?: string | null
          p_http_status?: number | null
          p_transport?: string | null
        }
        Returns: unknown
      }
      // Den rå årsaken. Kalles av serverruten `/diagnostics` med brukerens egen
      // token, aldri av nettleseren direkte — ikke fordi ruten har mer
      // fullmakt, men fordi den er en transport som tåler at fanen lukkes og
      // at Data API-veien er nede.
      record_client_diagnostic: {
        Args: {
          p_area: string
          p_kind: string
          p_operation?: string | null
          p_code?: string | null
          p_http_status?: number | null
          p_transport?: string | null
          p_detail?: string | null
        }
        Returns: unknown
      }
      // `p_seen_candidate_digest` er avtrykket flaten faktisk viste, sendt
      // tilbake uendret. Databasen stoler ikke på det — den krever at det er
      // kandidatens eget, og at kandidaten fortsatt er den gjeldende.
      // Publisher-aktøren er ikke en parameter; den utledes av den innloggede
      // brukerens egen aktørrad, og hele publiseringsgaten kjøres inne i
      // transaksjonen som skriver hendelsen.
      //
      // Alle tre svarer jsonb, lest av `lib/published-claim.ts`.
      publish_candidate: {
        Args: {
          p_candidate_id: Uuid
          p_seen_candidate_digest: string
          p_reason: string
        }
        Returns: unknown
      }
      withdraw_claim_publication: {
        Args: {
          p_claim_id: Uuid
          p_reason: string
        }
        Returns: unknown
      }
      rollback_claim_publication: {
        Args: {
          p_claim_id: Uuid
          p_target_candidate_id: Uuid
          p_seen_candidate_digest: string
          p_reason: string
        }
        Returns: unknown
      }
      // Klinikerflaten: det som faktisk er publisert, og historikken bak det.
      // `published_claim` svarer med den forseglede raden ordrett, ikke med en
      // gjenoppbygging — se `lib/published-claim.ts`.
      published_claim: {
        Args: {
          p_claim_id: Uuid
        }
        Returns: unknown
      }
      published_claim_index: {
        Args: Record<string, never>
        Returns: unknown
      }
      claim_publication_history: {
        Args: {
          p_claim_id: Uuid
        }
        Returns: unknown
      }
      // 009a: veien inn i det private fulltekstbiblioteket. Kalleren sender
      // **bytene** som base64 og den uttrukne teksten; filidentiteten,
      // størrelsen, mediatypen og representasjonen avleses eller fastsettes av
      // databasen, slik at ingen av dem er en påstand kalleren skriver om seg
      // selv. Svaret er jsonb — filen, kildeversjonen, bindingsgrunnlaget og
      // lesbarhetsmålingen — og leses av `lib/full-text-upload-result.ts`.
      upload_full_text_document: {
        Args: {
          p_source_id: Uuid
          p_retrieved_at: string
          p_retrieved_from: string
          /** Originaldokumentet, base64-kodet, byte for byte slik filen er. */
          p_document_base64: string
          /** Teksten oppskriften ga. Databasen hasher den til content_hash. */
          p_extracted_text: string
          p_text_extraction_tool: string
          p_text_extraction_tool_version: string
          p_text_extraction_arguments: string
          p_text_extraction_transform: string
          p_external_version?: string | null
        }
        Returns: unknown
      }
      // 009b: innleggingen i den varige jobbkøen. Idempotent på (rolle,
      // nøkkel), slik at en avbrutt orkestrering kan gjenta hele listen sin.
      // De tre andre jobbveiene er agentveier og hører ikke hjemme her: appen
      // skal aldri kalle dem, og en type som sa at den kunne, ville vært en
      // invitasjon.
      enqueue_pipeline_job: {
        Args: {
          p_agent_role: string
          p_job_key: string
          p_input_manifest: Record<string, unknown>
        }
        Returns: unknown
      }
      // De fire neste er kandidaten og sluttkontrollen (migrasjon 009d).
      //
      // `build_candidate` forsegler det agentferdige innholdet og er idempotent:
      // uendret innhold gir den samme kandidaten. `candidate_for_control` er
      // leseflaten klinikeren og sluttkontrolløren deler — samme visning, fordi
      // en godkjenning ellers ville vært en godkjenning av noe annet enn det som
      // vises. Begge svarer jsonb, lest av `lib/candidate-view.ts`.
      build_candidate: {
        Args: {
          p_claim_revision_id: Uuid
        }
        Returns: unknown
      }
      candidate_for_control: {
        Args: {
          p_candidate_id: Uuid
        }
        Returns: unknown
      }
      candidate_control_queue: {
        Args: Record<string, never>
        Returns: unknown
      }
      // Agentarbeidet. Alle krever editor-mandat: oppgaven inneholder hele den
      // kontrollerte kildeteksten, og den skal bare forlate databasen til den
      // som faktisk skal utføre agentarbeidet (migrasjon 010c).
      agent_work_queue: {
        Args: Record<string, never>
        Returns: unknown
      }
      // Innleggingen utleder jobbnøkkelen av hva oppgaven handler om, slik at
      // den samme oppgaven lagt inn to ganger er én rad.
      enqueue_agent_task: {
        Args: {
          p_agent_role: string
          p_input_manifest: Record<string, unknown>
        }
        Returns: unknown
      }
      agent_task_payload: {
        Args: {
          p_pipeline_job_id: Uuid
        }
        Returns: unknown
      }
      // Hvilken KI-tjeneste et agentledd utføres av, er en attestert avgjørelse
      // en redaktør tar FØR oppgaven hentes ut. Den inngår i oppgavens binding,
      // og et svar kontrolleres mot den: en modellidentitet som fikk registrere
      // seg selv ved første svar, ville etablert premisset som autoriserte den.
      // `p_replaces_reason` er begrunnelsen for et bytte — uten den avvises en
      // ny tildeling på et ledd som allerede har en.
      assign_agent_role_model: {
        Args: {
          p_agent_role: string
          p_provider: string
          p_model: string
          p_model_version?: string | null
          p_model_version_disclosure?: string
          p_reason?: string | null
          p_replaces_reason?: string | null
        }
        Returns: unknown
      }
      // Svaret sendes ordrett. Databasen kontrollerer bindingen mot oppgaven
      // slik den bygger den nå, og henter de registrerte verdiene ut av svaret
      // selv — en flate kan ikke bytte dem ut underveis.
      import_agent_answer: {
        Args: {
          p_pipeline_job_id: Uuid
          p_answer: Record<string, unknown>
        }
        Returns: unknown
      }
      // Den autonome kjøreren (migrasjon 011a). Redaktørveiene, og bare dem:
      // selve arbeidsflaten kjøreren bruker, er token-autentisert og kalles av
      // MCP-appen, aldri av nettleseren. Tilkoblingskoden er det eneste stedet
      // en hemmelighet forlater databasen i klartekst, og den lever i ti
      // minutter.
      agent_runner_connections: {
        Args: Record<string, never>
        Returns: unknown
      }
      register_agent_runner: {
        Args: {
          p_connection_key: string
          p_display_name: string
          p_agent_role: string
          p_platform_agent_reference: string
          p_platform_model_disclosure: string
          p_reason?: string | null
        }
        Returns: unknown
      }
      issue_agent_runner_pairing_code: {
        Args: {
          p_connection_key: string
        }
        Returns: unknown
      }
      revoke_agent_runner: {
        Args: {
          p_connection_key: string
          p_reason: string
        }
        Returns: unknown
      }
      // `p_seen_candidate_digest` er avtrykket flaten faktisk viste, sendt
      // tilbake uendret. Databasen krever at det er kandidatens eget *og* at
      // innholdet fortsatt bygger til det: en godkjenning avgitt mot ett innhold
      // og registrert mot et annet, ville vært en attestasjon uten dekning.
      record_candidate_final_control: {
        Args: {
          p_candidate_id: Uuid
          p_seen_candidate_digest: string
          p_decision: string
          p_rationale: string
        }
        Returns: unknown
      }
    }
  }
}
