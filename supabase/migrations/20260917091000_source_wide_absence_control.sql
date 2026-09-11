-- ============================================================================
-- Migrasjon 005ae — et globalt fravær får et kontrollledd som kan bære det
--
-- Migrasjon 005ad la verdien `source_wide_absence` til
-- `workflow.evidence_check_field`. Denne migrasjonen tar den i bruk, og
-- innfrir gjelden fra issue #74.
--
-- ----------------------------------------------------------------------------
-- Tilstanden før
--
-- `not_reported` og `not_measured` er påstander om kilden eller studien **som
-- helhet**. Den menneskelige kildekontrollen fikk et innsnevret spørsmål — om
-- opplysningen mangler der forankringsutdraget viser at den ville stått — fordi
-- det er det eneste spørsmålet ett lokalt utdrag kan bære. Svaret ble bevart,
-- men feltet ble med vilje **ikke** ført opp i `checked_fields`
-- (DATABASE_ARCHITECTURE.md §29: en rad skal aldri påstå større dekning enn
-- operasjonen faktisk hadde).
--
-- Prisen var at `availability_semantics` — som alltid kreves — ble stående
-- udekket for ethvert funn med et slikt fravær, og at publiseringsgatens G5b
-- ble stående åpen uten at noe navnga hva som manglet. Fava 2000 × sertralin ×
-- vektendring er nettopp et slikt funn: konfidensintervallet er ført som ikke
-- rapportert.
--
-- ----------------------------------------------------------------------------
-- Løsningen er å dele påstanden, ikke å svekke den
--
-- Påstanden «kilden oppgir ikke dette» har to halvdeler, og de har hvert sitt
-- kontrollgrunnlag:
--
--   LOKALT           mangler opplysningen der den ville stått?
--                    Grunnlag: forankringsutdraget. Et menneske avgjør det av
--                    det flaten viser. Feltet er `availability_semantics`.
--
--   KILDEOMFATTENDE  står opplysningen noe annet sted i kildeversjonen?
--                    Grunnlag: hele den registrerte representasjonen. To
--                    maskinelle ledd avgjør det — et deterministisk søk som kan
--                    AVKREFTE, og en uavhengig gjennomlesning av hele teksten
--                    som kan KONKLUDERE. Feltet er `source_wide_absence`.
--
-- Begge kreves nå eksplisitt av publiseringsgaten for et funn som fører et
-- slikt fravær. Det er en **strengere** gate enn før, ikke en løsere: hullet
-- var der hele tiden, men det var navnløst og så ut som et udekket
-- `availability_semantics`. Nå har det et navn, et krav og et kontrollledd.
--
-- ----------------------------------------------------------------------------
-- Hvorfor mennesket ikke kan registrere den kildeomfattende halvdelen
--
-- Det var det andre alternativet i issue #74: la en kontrollør med fullteksten
-- bekrefte fraværet globalt. Det ville gjort Peder til manuell fulltekstleser
-- for hvert eneste felt uten verdi, og Antidep skal i størst mulig grad drives
-- av agenter (MVP_IMPLEMENTATION_PLAN.md §74.31). Viktigere: kontrolløkten
-- *stiller ikke* det spørsmålet, og et «ja» på det lokale spørsmålet ville da
-- blitt bokført som et svar på det globale.
--
-- `evidence_verifications_source_wide_absence_check` gjør det umulig framfor
-- frarådet: feltet kan bare føres opp av en rad med en agentkjøring, og bare
-- når kontrollen hadde mer enn et avledet sammendrag å gå gjennom. Skal et menneske
-- kunne bære påstanden senere, er det et eget kontrollobjekt med sin egen
-- dekning og sin egen flate — ikke en oppmyking av denne regelen.
--
-- ----------------------------------------------------------------------------
-- Hva feltet betyr, og hva det med vilje ikke betyr
--
-- Rekkevidden er **kildeversjonen**, ikke publikasjonen — som er nøyaktig det
-- `*_availability`-kolonnene selv sier at statusen gjelder (migrasjon 003).
-- Kontrollen gjelder derfor den påstanden raden faktisk gjør.
--
-- Styrken følger av hva versjonen er, og ordlyden sier det: kontrollraden
-- navngir representasjonen som ble gjennomgått, slik at et abstrakt ikke leses
-- som en fulltekst.
--
-- ----------------------------------------------------------------------------
-- Hvorfor et søk ALENE ikke fører feltet opp
--
-- Den første utgaven av kontrollleddet førte feltet opp så snart et mønstersøk
-- ikke fant noe. Teknisk review felte den: mønstrene kjente `CI`, `C.I.` og
-- `confidence interval(s)`, men ikke `CIs` og ikke `confidence limits`, og «The
-- 95% CIs were 0.4 to 2.6.» ville da blitt bokført som «ingen konfidensintervall
-- i kildeversjonen». Å legge til de to formene løser ikke feilklassen: naturlig
-- språk har ingen uttømmende mønsterliste, og `not_measured` gjør det tydeligere
-- — en kilde kan si at vekt ble *målt* uten å oppgi et eneste tall.
--
-- `src/agents/extraction-checks.ts` fører derfor feltet opp bare når ALLE tre
-- holder: representasjonen lot seg reprodusere, det deterministiske søket fant
-- ingenting, og en uavhengig gjennomlesning av hele representasjonen
-- (`src/agents/absence-review.ts`) svarte at opplysningen ikke står der. Søket
-- er falsifikasjonsleddet — et treff blokkerer alene — og gjennomlesningen er
-- det ene leddet som kan konkludere. Et negativt søkeresultat er et manglende
-- motbevis, ikke et bevis (issue #74).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §10, §11, §17
--   docs/DATABASE_ARCHITECTURE.md §29, §50, §57
--   docs/EVIDENCE_PIPELINE.md §19.1, §24, §25.1
--   docs/PRODUCT_INFORMATION_ARCHITECTURE.md §63.1
--   docs/MVP_IMPLEMENTATION_PLAN.md §74.7
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Hvilke felter raden fører med en fraværsstatus som gjelder kilden
--
-- Ett sted, fordi tre lesere trenger svaret: gaten (for å vite om
-- `source_wide_absence` kreves), det kildeomfattende kontrollleddet (for å vite
-- hva det skal lete etter, og hva gjennomlesningen skal spørres om) og
-- kontrollflaten (for å si hva mennesket ikke blir spurt om). Tre formuleringer
-- av den samme regelen ville før eller siden svart forskjellig.
--
-- `not_applicable` og `not_extractable` er ikke med, og det er poenget:
-- `not_applicable` er en påstand om funnet, og `not_extractable` sier at
-- opplysningen *står* i kilden. Ingen av dem er en påstand om kilden som
-- helhet, og en kildeomfattende kontroll ville verken kunnet bekrefte eller
-- avkrefte dem.
-- ----------------------------------------------------------------------------
create function workflow.source_wide_absence_fields(p_evidence_item_id uuid)
  returns workflow.evidence_check_field[]
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select array_remove(
    array[
      case
        when e.population_availability in ('not_reported', 'not_measured')
        then 'population'
      end,
      case
        when e.sample_size_availability in ('not_reported', 'not_measured')
        then 'sample_size'
      end,
      case
        when e.timepoint_availability in ('not_reported', 'not_measured')
        then 'timepoint'
      end,
      case
        when e.estimate_availability in ('not_reported', 'not_measured')
        then 'estimate'
      end,
      case
        when e.confidence_interval_availability in ('not_reported', 'not_measured')
        then 'confidence_interval'
      end
    ]::workflow.evidence_check_field[],
    null
  )
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;
$$;

comment on function workflow.source_wide_absence_fields(uuid) is
  'Feltene et evidensfunn fører uten verdi med en begrunnelse som gjelder kilden eller studien SOM HELHET: not_reported («ikke rapportert i kilden») og not_measured («ikke målt i studien»). Tom liste betyr at raden ikke gjør noen slik påstand — aldri at den er ukjent. not_applicable og not_extractable er med vilje utelatt: den første er en påstand om funnet, og den andre sier at opplysningen står i kilden men ikke lar seg lese entydig ut, så en kildeomfattende kontroll kan verken bekrefte eller avkrefte dem. Leses tre steder og er skrevet ett: workflow.required_check_fields(uuid) krever source_wide_absence når listen ikke er tom, det kildeomfattende kontrollleddet leser den for å vite hvilke felter det skal lete etter i hele representasjonen og be gjennomlesningen om et svar på, og kontrollflaten leser den for å kunne si hva mennesket ikke blir spurt om. SECURITY DEFINER fordi knowledge har RLS med default deny.';

revoke execute on function workflow.source_wide_absence_fields(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. Gaten krever den kildeomfattende halvdelen når raden gjør påstanden
--
-- Uendret fra migrasjon 005y bortsett fra den siste `case`-grenen. Kravet er
-- betinget av raden selv, på nøyaktig samme måte som de øvrige: et funn som
-- ikke fører noe globalt fravær, påstår ingenting kildeomfattende, og et krav
-- om å kontrollere det ville aldri kunnet oppfylles.
-- ----------------------------------------------------------------------------
create or replace function workflow.required_check_fields(p_evidence_item_id uuid)
  returns workflow.evidence_check_field[]
  language sql
  stable
  set search_path = ''
as $$
  select array_remove(
    array[
      -- Alltid: raden påstår disse uansett hvordan den er fylt ut.
      'source_locator',
      'intervention_arm',
      'outcome',
      'reported_direction',
      -- At de øvrige feltene er ført som rapportert eller ikke rapportert, er
      -- selv en påstand om kilden, og en av de enkleste å ta feil på uten at
      -- noe tall ser galt ut. Feltet dekker den LOKALE halvdelen: at grunnen er
      -- av riktig art, og at verdien mangler der den ville stått.
      'availability_semantics',
      -- …og den KILDEOMFATTENDE halvdelen, når raden faktisk gjør en slik
      -- påstand. `not_reported` og `not_measured` gjelder kilden som helhet, og
      -- ett lokalt utdrag kan ikke bære dem (migrasjon 005ad).
      case
        when cardinality(workflow.source_wide_absence_fields(e.id)) > 0
        then 'source_wide_absence'
      end,
      -- Den rå gjengivelsen er valgfri, og fra migrasjon 005v er den ikke
      -- kontrollgrunnlaget — kildeforankringen er. En rad uten den påstår
      -- ingenting der, og et krav om å kontrollere den ville aldri kunnet
      -- oppfylles.
      case when e.raw_extraction is not null then 'raw_extraction' end,
      case when e.effect_measure is not null then 'effect_measure' end,
      case when e.comparator_kind <> 'none' then 'comparator_arm' end,
      case when e.population_availability = 'reported_value' then 'population' end,
      case when e.sample_size_availability = 'reported_value' then 'sample_size' end,
      case when e.timepoint_availability = 'reported_value' then 'timepoint' end,
      case when e.estimate_availability = 'reported_value' then 'estimate' end,
      case
        when e.confidence_interval_availability = 'reported_value'
        then 'confidence_interval'
      end,
      case when e.limitations_text is not null then 'limitations' end
    ]::workflow.evidence_check_field[],
    null
  )
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;
$$;

comment on function workflow.required_check_fields(uuid) is
  'Feltene et evidensfunn faktisk påstår noe om, og som til sammen må være kontrollert før funnet kan bære en publisert påstand (publiseringsgatens G5b). Utledet av raden selv framfor av en vedlikeholdt liste: et felt som ikke er rapportert, påstår ingenting og kreves ikke — men at det er ført som ikke rapportert, dekkes av availability_semantics, som alltid kreves. Fra migrasjon 005ae kreves i tillegg source_wide_absence når raden fører minst ett felt med not_reported eller not_measured (workflow.source_wide_absence_fields(uuid)): de to statusene er påstander om kilden som helhet, og availability_semantics dekker bare den lokale halvdelen av dem. Fra migrasjon 005y gjelder det samme raw_extraction: kolonnen er valgfri, og fra agentkontrakten i 005v er kildeforankringen kontrollgrunnlaget, så en rad uten rå gjengivelse påstår ingenting der. Én kontroll trenger ikke dekke alt; kravet gjelder unionen over funnets kontroller (workflow.covered_check_fields(uuid)), slik at flere verifikatorledd kan dele arbeidet.';

-- ----------------------------------------------------------------------------
-- 3. Mennesket får ikke et steg for den kildeomfattende halvdelen
--
-- `semantic_check_fields` er feltene en kliniker kontrollerer ett av gangen, og
-- den utelater allerede `raw_extraction` og `source_locator` fordi de er
-- provenansfelter uten klinisk innhold. `source_wide_absence` utelates av en
-- beslektet, men sterkere grunn: kontrolløren har ikke grunnlaget. Spørsmålet
-- er «står opplysningen noe annet sted i hele artikkelen?», og det kan bare
-- besvares ved å lese hele artikkelen — nøyaktig arbeidsformen
-- PRODUCT_INFORMATION_ARCHITECTURE.md §63.1 finnes for å fjerne.
--
-- Det følger av dette at forankringskravet heller ikke gjelder feltet:
-- `workflow.assert_extraction_fully_grounded(uuid)` leser
-- `semantic_check_fields`, og en kildeomfattende kontroll har ingen ett enkelt
-- utdrag å forankres i. Det er riktig — grunnlaget er hele representasjonen,
-- og fingeravtrykket av den står i kontrollraden.
-- ----------------------------------------------------------------------------
create or replace function workflow.semantic_check_fields(p_evidence_item_id uuid)
  returns workflow.evidence_check_field[]
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(
    array_agg(f.field order by f.ordinality),
    '{}'::workflow.evidence_check_field[]
  )
  from unnest(workflow.required_check_fields(p_evidence_item_id))
       with ordinality as f(field, ordinality)
  where f.field <> all (
    array[
      'raw_extraction',
      'source_locator',
      'source_wide_absence'
    ]::workflow.evidence_check_field[]
  );
$$;

comment on function workflow.semantic_check_fields(uuid) is
  'Feltene et evidensfunn påstår noe *om studien*, og som en kliniker kontrollerer ett av gangen: workflow.required_check_fields(uuid) uten raw_extraction, source_locator og source_wide_absence. De to første er provenansfelter og ikke kliniske påstander — «er noe bevart ordrett?» og «hvor i dokumentet står funnet som helhet?» — og som egne beslutninger i en kontrolløkt ville de vært spørsmål uten klinisk innhold. Garantien de bærer er ikke svekket, men flyttet dit den er sterkere: hver kildeforankring har sitt eget ordrette utdrag og sin egen presise peker, så en bekreftet semantisk delkontroll er en kontroll av begge deler for nøyaktig det feltet. source_wide_absence utelates av en sterkere grunn (migrasjon 005ae): spørsmålet er om opplysningen står noe annet sted i hele artikkelen, og det kan bare besvares ved å lese hele artikkelen — arbeidsformen PRODUCT_INFORMATION_ARCHITECTURE.md §63.1 finnes for å fjerne. Det leddet er maskinelt og har sin egen rad. Publiseringsgatens G5b leser fortsatt required_check_fields(uuid), uendret. Rekkefølgen er den required_check_fields(uuid) gir, altså kolonnerekkefølgen på raden.';

-- ----------------------------------------------------------------------------
-- 4. Feltet kan bare føres opp av et ledd som faktisk gjennomgikk kilden
--
-- Deklarativt og på tabellen, ikke i én skrivevei: begge veiene inn i
-- workflow.evidence_verifications går gjennom
-- workflow.record_evidence_verification, men regelen skal holde uansett hvilken
-- vei som senere kommer til (DATABASE_ARCHITECTURE.md §29).
--
-- `agent_run_id is not null` er beviset for at raden kommer fra en agentkjøring,
-- og de to sammensatte fremmednøklene på tabellen binder den kjøringen til
-- rollen `extraction_verification`. En menneskelig kontrolløkt har ingen
-- kjøring — kolonnen er bygget for nettopp det skillet (migrasjon 005g) — og
-- kan derfor ikke føre feltet opp.
--
-- Kildetilgangen er med av samme grunn som i
-- `evidence_verifications_source_access_check`: en gjennomgang av et annet
-- ledds sammendrag er ikke en gjennomgang av kilden, og ANTIDEP_CONSTITUTION.md §11
-- forbyr å bygge en bekreftelse på det.
-- ----------------------------------------------------------------------------
alter table workflow.evidence_verifications
  add constraint evidence_verifications_source_wide_absence_check
  check (
    not ('source_wide_absence' = any (checked_fields))
    or (agent_run_id is not null and source_access <> 'derived_summary')
  );

comment on column workflow.evidence_verifications.checked_fields is
  'Nøyaktig de feltene denne ene operasjonen gikk gjennom og fant i orden — aldri flere. En rad skal aldri påstå større dekning enn operasjonen faktisk hadde (DATABASE_ARCHITECTURE.md §29). Publiseringsgatens G5b leser unionen over funnets kontroller (workflow.covered_check_fields(uuid)), slik at maskinen kan dekke provenansfeltene og mennesket de semantiske, uten at noen av dem overdriver. Fram til migrasjon 005y krevde evidence_verifications_locator_checked_check at enhver bekreftelse førte opp source_locator; kravet er flyttet til gaten, der unionen avgjør. Fra migrasjon 005ae kan source_wide_absence bare føres opp av en rad med en agentkjøring og med mer enn et avledet sammendrag som grunnlag (evidence_verifications_source_wide_absence_check): feltet er påstanden om at opplysningen ikke står noe sted i hele den kontrollerte representasjonen, avgjort av to maskinelle ledd — et deterministisk søk som kan avkrefte og en uavhengig gjennomlesning som kan konkludere — og en menneskelig kontrolløkt stiller ikke det spørsmålet.';

-- ----------------------------------------------------------------------------
-- 5. Grunnlaget sier hvilke felter som bærer en kildeomfattende fraværspåstand
--
-- Uendret fra migrasjon 005ac bortsett fra den ene nye nøkkelen. Uten den ville
-- kontrollflaten og det kildeomfattende kontrollleddet måttet regne ut det
-- samme settet selv, av de fem `*_availability`-kolonnene — altså en andre
-- formulering av regelen i punkt 1.
-- ----------------------------------------------------------------------------
create or replace function workflow.evidence_extraction_dossier(p_evidence_item_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select jsonb_build_object(
    'evidence_item_id', e.id,
    'created_at', e.created_at,
    'created_by_actor_id', e.created_by_actor_id,
    'created_by_actor_key', creator.actor_key,
    'created_by_actor_type', creator.actor_type::text,
    'extraction_method', e.extraction_method::text,
    'content_hash', e.content_hash,
    -- Erklæringen om hvem som laget utkastet, og når. NULL når kjøringen ikke
    -- fikk en: et funn registrert på editorveien, eller før migrasjon 005ab.
    -- Et objekt med tomme felter ville påstått at erklæringen fantes.
    'drafted_by', case
      when ar.input_manifest -> 'generated_by' ->> 'producer' is null then null
      else jsonb_build_object(
        'producer', ar.input_manifest -> 'generated_by' ->> 'producer',
        'provider', ar.input_manifest -> 'generated_by' ->> 'provider',
        'model', ar.input_manifest -> 'generated_by' ->> 'model',
        'model_version', ar.input_manifest -> 'generated_by' ->> 'model_version',
        'prompt_template_version',
          ar.input_manifest -> 'generated_by' ->> 'prompt_template_version',
        'drafted_at', ar.input_manifest -> 'generated_by' ->> 'drafted_at',
        'request_digest', ar.input_manifest -> 'generated_by' ->> 'request_digest'
      )
    end,
    -- Kjøringen som faktisk skrev raden, med sine egne premisser. NULL for et
    -- funn registrert på editorveien: der finnes ingen kjøring.
    'registered_by', case
      when ar.id is null then null
      else jsonb_build_object(
        'agent_run_id', ar.id,
        'agent_role', ar.agent_role::text,
        'provider', ar.provider,
        'model', ar.model,
        'model_version', ar.model_version,
        'prompt_template_version', ar.prompt_template_version,
        'pipeline_version', ar.pipeline_version,
        'started_at', ar.started_at
      )
    end,
    'source', jsonb_build_object(
      'source_id', s.id,
      'source_type', s.source_type::text,
      'title', s.title,
      'authors_or_issuer', s.authors_or_issuer,
      'publisher_or_journal', s.publisher_or_journal,
      'publication_date', s.publication_date,
      'publication_date_precision', s.publication_date_precision::text,
      'source_status', s.source_status::text,
      'status_note', s.status_note,
      -- De globale identifikatorene, som den menneskelige lenken bygges av.
      'identifiers', (
        select coalesce(jsonb_agg(
          jsonb_build_object(
            'identifier_system', si.identifier_system::text,
            'identifier_value', si.identifier_value
          )
          order by si.identifier_system::text
        ), '[]'::jsonb)
        from knowledge.source_identifiers si
        where si.source_id = s.id
      )
    ),
    'source_version', case
      when sv.id is null then null
      else jsonb_build_object(
        'source_version_id', sv.id,
        'retrieved_at', sv.retrieved_at,
        'retrieved_from', sv.retrieved_from,
        'external_version', sv.external_version,
        'content_hash', sv.content_hash,
        -- NULL betyr at opplysningen ikke er registrert, aldri at
        -- representasjonen er ukjent men brukbar (migrasjon 003b).
        'representation', sv.representation::text,
        -- Originaldokumentet representasjonen ble hentet ut av, og oppskriften
        -- den ble hentet ut med (migrasjon 003e). NULL — og ikke et objekt med
        -- tomme felter — når representasjonen er teksten på adressen: fravær av
        -- et dokument er en opplysning, ikke en struktur uten verdier.
        'document', case
          when sv.document_sha256 is null then null
          else jsonb_build_object(
            'sha256', sv.document_sha256,
            'byte_size', sv.document_byte_size,
            'media_type', sv.document_media_type,
            'text_extraction', jsonb_build_object(
              'tool', sv.text_extraction_tool,
              'tool_version', sv.text_extraction_tool_version,
              'arguments', sv.text_extraction_arguments
            )
          )
        end,
        'has_storage_reference', sv.storage_reference is not null
      )
    end,
    'field_groundings', workflow.evidence_field_groundings(e.id),
    -- Feltene en kliniker kontrollerer ett av gangen, og feltene forankringen
    -- faktisk dekker. Differansen er hva som mangler før funnet kan kontrolleres
    -- felt for felt, og den er ren mengdelære over to lister databasen leverer.
    'semantic_check_fields', to_jsonb(workflow.semantic_check_fields(e.id)::text[]),
    'grounded_check_fields', to_jsonb(workflow.grounded_check_fields(e.id)::text[]),
    -- Feltene raden fører med en fraværsstatus som gjelder kilden som
    -- helhet. Listen er databasens egen (migrasjon 005ae), slik at
    -- publiseringsgaten, det kildeomfattende kontrollleddet og
    -- kontrollflaten leser nøyaktig det samme settet.
    'source_wide_absence_fields',
      to_jsonb(workflow.source_wide_absence_fields(e.id)::text[]),
    -- Om maskinen har bevist venstresiden for nøyaktig dette grunnlaget. Uten
    -- den kan ingen menneskelig bekreftelse registreres (migrasjon 005x), og
    -- kontrolløkten skal si det før noen begynner å bedømme semantikken.
    'grounding_machine_proved', workflow.grounding_machine_proved(e.id),
    'extraction', jsonb_build_object(
      'design_code', e.design_code::text,
      'population_id', e.population_id,
      'population_label', pop.canonical_label,
      'population_availability', e.population_availability::text,
      'population_detail', e.population_detail,
      'sample_size', e.sample_size,
      'sample_size_availability', e.sample_size_availability::text,
      'intervention_drug_id', e.intervention_drug_id,
      'intervention_drug_name', d.canonical_name,
      'intervention_detail', e.intervention_detail,
      'comparator_kind', e.comparator_kind::text,
      'comparator_drug_id', e.comparator_drug_id,
      'comparator_drug_name', cd.canonical_name,
      'comparator_detail', e.comparator_detail,
      'outcome_concept_id', e.outcome_concept_id,
      'outcome_label', oc.canonical_label,
      'outcome_detail', e.outcome_detail,
      'timepoint_min', e.timepoint_min::text,
      'timepoint_max', e.timepoint_max::text,
      'timepoint_availability', e.timepoint_availability::text,
      'reported_direction', e.reported_direction::text,
      'effect_measure', e.effect_measure::text,
      'estimate', e.estimate::text,
      'estimate_unit', e.estimate_unit::text,
      'estimate_availability', e.estimate_availability::text,
      'ci_lower', e.ci_lower::text,
      'ci_upper', e.ci_upper::text,
      'ci_level_percent', e.ci_level_percent::text,
      'confidence_interval_availability', e.confidence_interval_availability::text,
      'limitations_text', e.limitations_text,
      'source_locator', e.source_locator,
      'raw_extraction', e.raw_extraction
    )
  )
  from knowledge.evidence_items e
  join knowledge.sources s on s.id = e.source_id
  join provenance.actors creator on creator.id = e.created_by_actor_id
  join catalog.drugs d on d.id = e.intervention_drug_id
  join catalog.clinical_concepts oc on oc.id = e.outcome_concept_id
  left join catalog.drugs cd on cd.id = e.comparator_drug_id
  left join catalog.populations pop on pop.id = e.population_id
  left join knowledge.source_versions sv on sv.id = e.source_version_id
  -- LEFT JOIN, fordi agent_run_id er nullbar: editorveien registrerer et funn
  -- uten kjøring (migrasjon 005u).
  left join provenance.agent_runs ar on ar.id = e.agent_run_id
  where e.id = p_evidence_item_id;
$$;

comment on function workflow.evidence_extraction_dossier(uuid) is
  'Grunnlaget for én ekstraksjonskontroll: evidensfunnets identitet og opphav, hvem som laget utkastet (drafted_by: produsent, leverandør, modell, modellversjon, promptmalversjon, tidspunktet utkastet ble laget og fingeravtrykket av forespørselen — erklæringen forslaget bar med seg, lest ut av kjøringens input_manifest; NULL når ingen erklæring fulgte med), kjøringen som registrerte raden (registered_by: rolle, leverandør, modell, modellversjon, promptmalversjon, pipelineversjon og starttidspunkt — NULL når funnet ble registrert på editorveien og ingen kjøring finnes), kilden med sin status og sine identifikatorer, kildeversjonen (eller null når ingen er registrert, med retrieved_from, content_hash og representasjonstype når den finnes), kildeforankringen per felt, feltsettene (inkludert source_wide_absence_fields: feltene raden fører med en fraværsstatus som gjelder kilden som helhet, migrasjon 005ae) og maskinbeviset, og hele den strukturerte ekstraksjonen ordrett, inkludert source_locator og raw_extraction (ANTIDEP_CONSTITUTION.md §11, §12, §20, DATABASE_ARCHITECTURE.md §29, EVIDENCE_PIPELINE.md §46, §65). De to er skilt fordi utkastet og registreringen er forskjellige operasjoner på forskjellige tidspunkter: registered_by.started_at er registreringstidspunktet, mens drafted_by.drafted_at er da modellen faktisk leste kilden. drafted_by er kontrollgrunnlag og ikke driftsinformasjon: en kontrollør leser et maskinutkast annerledes enn en kollegas ekstraksjon, og «hvilke funn ble laget med denne promptmalen» skal kunne besvares fra kontrollflaten. Uttrykket er den ene projeksjonen både den menneskelige kontrollflaten og den deterministiske verifikatoren leser, slik at de aldri kontrollerer hvert sitt grunnlag (§4, §9). storage_reference er ikke eksponert, bare om den finnes. Numeriske verdier er ::text, slik at et eksakt desimaltall ikke går veien om en IEEE-754 double før noen leser det. NULL når evidensfunnet ikke finnes. Tar ingen kaller-identitet og gjør ingen autorisasjon: den er et lesegrunnlag og ikke et endepunkt, og hver flate som eksponerer den autentiserer først. SECURITY DEFINER fordi knowledge, catalog og provenance har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';
