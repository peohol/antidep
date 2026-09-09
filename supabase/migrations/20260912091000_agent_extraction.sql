-- ============================================================================
-- Migrasjon 005v — ekstraksjonsagenten får sin egen skrivevei, og forankringen
--                  blir et krav der den hører hjemme
--
-- Migrasjon 005u ga forankringen en tabell, og 007f ga editorens skjema en
-- parameter å sende den i. Det var feil produsent. Forankringen — det ordrette
-- utdraget, den presise pekeren og begrunnelsen — skal lages av det leddet som
-- faktisk leser kilden, samtidig med den strukturerte ekstraksjonen
-- (EVIDENCE_PIPELINE.md §21, §25). En redaktør som skriver utdragene for hånd,
-- gjør nøyaktig det arbeidet forankringen finnes for å slippe.
--
-- Denne migrasjonen gir ekstraksjonsagenten skriveveien, og gjør komplett
-- forankring til et vilkår på den.
--
-- ----------------------------------------------------------------------------
-- To sett av kontrollfelter, og hvorfor skillet er nødvendig
--
-- `workflow.required_check_fields(uuid)` er publiseringsgatens krav og er
-- uendret: den lister alt funnet påstår noe om, inkludert `raw_extraction` og
-- `source_locator`. De to er provenansfelter — «er noe bevart ordrett?» og
-- «hvor i dokumentet står funnet som helhet?» — ikke kliniske påstander en lege
-- kan bedømme som to selvstendige beslutninger.
--
-- `workflow.semantic_check_fields(uuid)` er de øvrige: feltene som sier noe om
-- studien, og som en kliniker faktisk kontrollerer ett av gangen. Det er dette
-- settet forankringen må dekke, og det er dette settet kontrolløkten stiller
-- spørsmål om.
--
-- Garantien de to provenansfeltene bærer, er ikke svekket — den er flyttet dit
-- den er sterkere. Hver forankring har sitt eget ordrette utdrag og sin egen
-- presise peker, så en bekreftet semantisk delkontroll *er* en kontroll av at
-- noe er bevart ordrett og av hvor i kilden det står — for nøyaktig det feltet,
-- framfor for raden under ett. Publiseringsgatens G5b krever fortsatt at
-- `checked_fields` dekker hele `required_check_fields`, og
-- `evidence_verifications_locator_checked_check` krever fortsatt `source_locator`
-- i en bekreftelse. Ingen CHECK er rørt.
--
-- ----------------------------------------------------------------------------
-- Hva agentveien krever som editorveien ikke gjør
--
--   1. en kildeversjon, og den må ha en registrert representasjonstype
--      (migrasjon 003b) — «agenten skal aldri beskrive kildeinnhold som ikke
--      faktisk var tilgjengelig i kjøringen» (EVIDENCE_PIPELINE.md §13)
--   2. komplett forankring: hvert semantisk felt raden påstår noe om, må ha sitt
--      ordrette utdrag, sin peker og sin begrunnelse
--
-- Begge kontrolleres etter innsettingen, fordi begge avhenger av den ferdige
-- raden: `workflow.required_check_fields(uuid)` leser raden selv. Transaksjonen
-- rulles tilbake av unntaket, så en ufullstendig ekstraksjon etterlater
-- ingenting.
--
-- Editorveien er uendret og krever ingen av delene. Det er ikke en oppmykning:
-- den veien er ikke agentekstraksjon, og et funn registrert der er nøyaktig så
-- kontrollerbart som forankringen sier at det er.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §8, §10, §11, §12, §17, §20
--   docs/DATABASE_ARCHITECTURE.md §29, §43, §46, §50, §57
--   docs/EVIDENCE_PIPELINE.md §13, §21, §25
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §49, §74.31
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. De to avledede feltsettene
-- ----------------------------------------------------------------------------
create function workflow.semantic_check_fields(p_evidence_item_id uuid)
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
    array['raw_extraction', 'source_locator']::workflow.evidence_check_field[]
  );
$$;

comment on function workflow.semantic_check_fields(uuid) is
  'Feltene et evidensfunn påstår noe *om studien*, og som en kliniker kontrollerer ett av gangen: workflow.required_check_fields(uuid) uten raw_extraction og source_locator. De to er provenansfelter og ikke kliniske påstander — «er noe bevart ordrett?» og «hvor i dokumentet står funnet som helhet?» — og som egne beslutninger i en kontrolløkt ville de vært spørsmål uten klinisk innhold. Garantien de bærer er ikke svekket, men flyttet dit den er sterkere: hver kildeforankring har sitt eget ordrette utdrag og sin egen presise peker, så en bekreftet semantisk delkontroll er en kontroll av begge deler for nøyaktig det feltet. Publiseringsgatens G5b leser fortsatt required_check_fields(uuid), uendret. Rekkefølgen er den required_check_fields(uuid) gir, altså kolonnerekkefølgen på raden.';

revoke execute on function workflow.semantic_check_fields(uuid) from public;

create function workflow.grounded_check_fields(p_evidence_item_id uuid)
  returns workflow.evidence_check_field[]
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(
    array_agg(g.check_field order by g.check_field),
    '{}'::workflow.evidence_check_field[]
  )
  from knowledge.evidence_field_groundings g
  where g.evidence_item_id = p_evidence_item_id;
$$;

comment on function workflow.grounded_check_fields(uuid) is
  'Feltene et evidensfunn har registrert kildeforankring for (migrasjon 005u). Tom liste betyr at ingen forankring finnes — tilstanden alle funn registrert før 005u er i — aldri at forankringen er ukjent. Sammenlign med workflow.semantic_check_fields(uuid), som sier hvilke felter forankringen må dekke for at funnet skal kunne kontrolleres felt for felt.';

revoke execute on function workflow.grounded_check_fields(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. Kravet om komplett forankring
--
-- Formulert som en assertion og ikke som en CHECK: den gjelder på tvers av to
-- tabeller og kan først avgjøres når begge er skrevet. Den kalles av
-- agentveien, som er den eneste veien som stiller kravet.
-- ----------------------------------------------------------------------------
create function workflow.assert_extraction_fully_grounded(p_evidence_item_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_missing text;
begin
  select string_agg(f.field::text, ', ' order by f.field::text)
    into v_missing
  from unnest(workflow.semantic_check_fields(p_evidence_item_id)) as f(field)
  where f.field <> all (workflow.grounded_check_fields(p_evidence_item_id));

  if v_missing is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Ekstraksjonen mangler kildeforankring for: %s.', v_missing),
      hint = 'En agentekstraksjon skal for hvert felt den påstår noe om, levere det ordrette kildeutdraget, den presise pekeren og en kort begrunnelse — hentet fra den representasjonen som faktisk ble lest (EVIDENCE_PIPELINE.md §13, §21). Uten forankringen kan ingen kliniker kontrollere feltet uten å lete i kilden selv, og det er nettopp arbeidet forankringen finnes for å fjerne.';
  end if;
end;
$$;

comment on function workflow.assert_extraction_fully_grounded(uuid) is
  'Krever at hvert semantisk kontrollfelt et evidensfunn påstår noe om, har en registrert kildeforankring (workflow.semantic_check_fields(uuid) mot workflow.grounded_check_fields(uuid)). Kalles av agentens skrivevei api.register_agent_extraction etter innsettingen, fordi kravet avhenger av den ferdige raden. Editorveien kaller den ikke: et funn registrert for hånd er nøyaktig så kontrollerbart som forankringen sier, og skal kunne registreres uten. SECURITY DEFINER fordi knowledge har RLS med default deny; funksjonen returnerer ingen data.';

revoke execute on function workflow.assert_extraction_fully_grounded(uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. api.register_agent_extraction(...) — ekstraksjonsagentens skrivevei
--
-- Samme form som api.register_extraction_verification(...): legitimasjonen
-- autentiseres eksplisitt for rollen, en åpen kjøring som tilhører nøyaktig den
-- identiteten kreves, og aktøren raden attribueres til er kjøringens egen — ikke
-- en parameter kalleren kan velge.
-- ----------------------------------------------------------------------------
create function api.register_agent_extraction(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_source_id uuid,
  p_source_version_id uuid,
  p_design_code text,
  p_population_availability text,
  p_population_detail text,
  p_sample_size_availability text,
  p_intervention_drug_id uuid,
  p_comparator_kind text,
  p_outcome_concept_id uuid,
  p_outcome_detail text,
  p_timepoint_availability text,
  p_reported_direction text,
  p_estimate_availability text,
  p_confidence_interval_availability text,
  p_source_locator text,
  p_field_groundings jsonb,
  p_population_id uuid default null,
  p_sample_size integer default null,
  p_intervention_detail text default null,
  p_comparator_drug_id uuid default null,
  p_comparator_detail text default null,
  p_timepoint_min text default null,
  p_timepoint_max text default null,
  p_effect_measure text default null,
  p_estimate numeric default null,
  p_estimate_unit text default null,
  p_ci_lower numeric default null,
  p_ci_upper numeric default null,
  p_ci_level_percent numeric default null,
  p_limitations_text text default null,
  p_source_quote text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_identity_id uuid;
  v_actor_id uuid;
  v_representation knowledge.source_representation;
  v_version_source_id uuid;
  v_evidence_item_id uuid;
begin
  -- Autentiser eksplisitt for rollen evidence_extraction. En identitet i en
  -- annen rolle avvises her, før noe leses eller skrives.
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'evidence_extraction'::provenance.agent_role
  );

  -- Krev en åpen kjøring som tilhører nøyaktig denne identiteten, og la
  -- returverdien — ikke en klientoppgitt parameter — være aktøren raden
  -- attribueres til.
  v_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  -- En agentekstraksjon skal alltid kunne etterprøves mot den representasjonen
  -- den faktisk ble laget av. Kildeversjonen er derfor påkrevd, den må tilhøre
  -- kilden, og den må si hva slags representasjon den er.
  if p_source_version_id is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En agentekstraksjon må peke på den kildeversjonen den ble laget av.',
      hint = 'Registrer kildeversjonen først (api.create_source_version(...)). Uten den finnes det ingen hashet representasjon å etterprøve utdragene mot (ANTIDEP_CONSTITUTION.md §11).';
  end if;

  select sv.representation, sv.source_id
    into v_representation, v_version_source_id
  from knowledge.source_versions sv
  where sv.id = p_source_version_id;

  if v_version_source_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kildeversjonen %L finnes ikke.', p_source_version_id),
      hint = 'Kontroller id-en. En kildeversjon registreres av api.create_source_version(...).';
  end if;

  if v_representation is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kildeversjonen sier ikke hva slags representasjon den er.',
      hint = 'EVIDENCE_PIPELINE.md §13 krever at pipeline vet om vurderingen bygger på fulltekst, abstrakt, registerdata, et regulatorisk sammendrag, en sekundær omtale eller en annen begrenset representasjon. Registrer kildeversjonen på nytt med p_representation satt; uten den kan ingen si hva ekstraksjonen faktisk bygger på.';
  end if;

  v_evidence_item_id := knowledge.record_evidence_item(
    p_source_id, p_design_code, p_population_availability, p_population_detail,
    p_sample_size_availability, p_intervention_drug_id, p_comparator_kind,
    p_outcome_concept_id, p_outcome_detail, p_timepoint_availability,
    p_reported_direction, p_estimate_availability, p_confidence_interval_availability,
    p_source_locator, p_source_version_id, p_population_id, p_sample_size,
    p_intervention_detail, p_comparator_drug_id, p_comparator_detail,
    p_timepoint_min, p_timepoint_max, p_effect_measure, p_estimate, p_estimate_unit,
    p_ci_lower, p_ci_upper, p_ci_level_percent, p_limitations_text, p_source_quote,
    p_field_groundings,
    -- Hardkodet, som `manual` er det på editorveien: raden sier hvordan den ble
    -- til, og det er ikke noe kalleren skal kunne påstå fritt.
    'ai_assisted',
    v_actor_id
  );

  -- Etter innsettingen, fordi kravet leses av den ferdige raden. Feiler den,
  -- rulles hele transaksjonen tilbake, og ekstraksjonen etterlater ingenting.
  perform workflow.assert_extraction_fully_grounded(v_evidence_item_id);

  return v_evidence_item_id;
end;
$$;

comment on function api.register_agent_extraction(
  text, text, uuid, uuid, uuid, text, text, text, text, uuid, text, uuid, text, text,
  text, text, text, text, jsonb, uuid, integer, text, uuid, text, text, text, text,
  numeric, text, numeric, numeric, numeric, text, text
) is
  'Den kontrollerte skriveveien for at ekstraksjonsagenten registrerer ett evidensfunn med komplett kildeforankring (ANTIDEP_CONSTITUTION.md §8, §10, EVIDENCE_PIPELINE.md §13, §21, §25). Autentiserer identiteten eksplisitt for rollen evidence_extraction og krever en åpen agentkjøring som tilhører den (provenance.assert_agent_run_open(uuid, uuid)); aktøren raden attribueres til er kjøringens egen og er ikke en parameter. extraction_method er hardkodet ai_assisted. To vilkår gjelder her og ikke på editorveien: kildeversjonen er påkrevd og må ha en registrert representasjonstype, slik at det alltid finnes en hashet representasjon å etterprøve utdragene mot og det alltid er kjent om ekstraksjonen bygger på fulltekst eller et sammendrag; og forankringen må dekke hvert semantisk felt raden påstår noe om (workflow.assert_extraction_fully_grounded(uuid)). Selve innsettingen gjøres av knowledge.record_evidence_item, den samme funksjonen editorveien bruker, slik at de to ikke kan komme i utakt. SECURITY DEFINER fordi knowledge, catalog og provenance har RLS med default deny; tomt search_path. EXECUTE går til anon og authenticated av samme grunn som de øvrige agentendepunktene: en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

revoke execute on function api.register_agent_extraction(
  text, text, uuid, uuid, uuid, text, text, text, text, uuid, text, uuid, text, text,
  text, text, text, text, jsonb, uuid, integer, text, uuid, text, text, text, text,
  numeric, text, numeric, numeric, numeric, text, text
) from public;
grant execute on function api.register_agent_extraction(
  text, text, uuid, uuid, uuid, text, text, text, text, uuid, text, uuid, text, text,
  text, text, text, text, jsonb, uuid, integer, text, uuid, text, text, text, text,
  numeric, text, numeric, numeric, numeric, text, text
) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. Grunnlaget får kildens identifikatorer, representasjonen og feltsettene
--
-- Fremover-skrivende med `create or replace function`, som i 005r og 005u:
-- signatur, eier og rettigheter er uendret, og svaret får nye nøkler uten at
-- noen eksisterende endrer form.
--
-- Identifikatorene er der fordi den menneskelige lenken til kilden skal bygges
-- av dem. `retrieved_from` er maskinens eksakte henteadresse — den skal beholdes
-- for hashing og proveniens, men den er ikke artikkellenken et menneske skal
-- klikke på, og for et EUtils-kall er den XML.
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
        'has_storage_reference', sv.storage_reference is not null
      )
    end,
    'field_groundings', workflow.evidence_field_groundings(e.id),
    -- Feltene en kliniker kontrollerer ett av gangen, og feltene forankringen
    -- faktisk dekker. Differansen er hva som mangler før funnet kan kontrolleres
    -- felt for felt, og den er ren mengdelære over to lister databasen leverer.
    'semantic_check_fields', to_jsonb(workflow.semantic_check_fields(e.id)::text[]),
    'grounded_check_fields', to_jsonb(workflow.grounded_check_fields(e.id)::text[]),
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
  where e.id = p_evidence_item_id;
$$;

-- ----------------------------------------------------------------------------
-- 5. Avtrykket dekker representasjonstypen
--
-- Grunnlagsavtrykket sier hva en kontroll faktisk gjaldt. Representasjonstypen
-- er nå en del av det kontrolløren ser — den avgjør hva ekstraksjonen kunne
-- bygge på — og en endring av den skal derfor kreve at kontrollen gjøres på
-- nytt. Strengere, ikke løsere: alt som lå i avtrykket før, ligger der fortsatt.
-- ----------------------------------------------------------------------------
create or replace function workflow.evidence_extraction_digest(p_evidence_item_id uuid)
  returns text
  language sql
  stable
  security definer
  set search_path = ''
as $$
  with reviewed as (
    select array[
      e.id::text,
      e.content_hash,
      e.source_id::text,
      s.source_status::text,
      sv.id::text,
      sv.content_hash,
      sv.retrieved_from,
      sv.representation::text,
      (
        select string_agg(ev.id::text, ',' order by ev.id::text)
        from workflow.evidence_verifications ev
        where ev.evidence_item_id = e.id
      ),
      (
        select string_agg(g.id::text, ',' order by g.id::text)
        from knowledge.evidence_field_groundings g
        where g.evidence_item_id = e.id
      )
    ] as parts
    from knowledge.evidence_items e
    join knowledge.sources s on s.id = e.source_id
    left join knowledge.source_versions sv on sv.id = e.source_version_id
    where e.id = p_evidence_item_id
  )
  select 'sha256-v1:' || encode(
    sha256(convert_to(
      (
        select string_agg(
          '|' || coalesce(length(p.part)::text, '~') || ':' || coalesce(p.part, ''),
          '' order by p.ordinality
        )
        from reviewed r2, unnest(r2.parts) with ordinality as p(part, ordinality)
      ),
      'UTF8'
    )),
    'hex'
  )
  from reviewed;
$$;

-- ----------------------------------------------------------------------------
-- 6. Påstandsgrunnlaget bygger evidensfunnet av den samme projeksjonen
--
-- workflow.claim_evidence_dossier(uuid) hadde evidensfunnets projeksjon skrevet
-- ut en gang til, ord for ord lik den i workflow.evidence_extraction_dossier(uuid).
-- Så lenge de to var identiske, var forskjellen uten praktisk konsekvens. Med
-- forankringen (005u), identifikatorene og representasjonstypen (005v og 003b)
-- er de det ikke lenger: den ene har dem, den andre ikke — og da ville
-- påstandskontrollen og ekstraksjonskontrollen sett hvert sitt bilde av det
-- samme evidensfunnet. Det er nøyaktig feilen 005m og 005r ble skrevet for å
-- hindre, oppstått på nytt fordi kopien fikk stå.
--
-- Funksjonen bygger derfor nå `evidence_item` med det ene kallet. Ingenting
-- annet i svaret endres, og joinene som bare fantes for den utskrevne blokken,
-- er fjernet. Fremover-skrivende med `create or replace function`: signatur,
-- eier og rettigheter er uendret.
-- ----------------------------------------------------------------------------
create or replace function workflow.claim_evidence_dossier(p_claim_revision_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select jsonb_build_object(
    'claim_revision_id', r.id,
    'claim_id', r.claim_id,
    'revision_number', r.revision_number,
    'knowledge_type', r.knowledge_type::text,
    'created_at', r.created_at,
    'created_by_actor_id', r.created_by_actor_id,
    'created_by_actor_key', author.actor_key,
    'created_by_actor_type', author.actor_type::text,
    'content_hash', r.content_hash,
    'claim_retired_at', cl.retired_at,
    'topic_concept_id', cl.topic_concept_id,
    'topic_label', topic.canonical_label,
    'subject_drug_id', cl.subject_drug_id,
    'subject_drug_name', subject.canonical_name,
    'evidence_set_digest', knowledge.claim_evidence_set_digest(r.id),
    'claim', jsonb_build_object(
      'statement', r.statement,
      'scope', r.scope,
      'population_id', r.population_id,
      'population_label', pop.canonical_label,
      'timeframe_min', r.timeframe_min::text,
      'timeframe_max', r.timeframe_max::text,
      'comparator_kind', r.comparator_kind::text,
      'comparator_drug_id', r.comparator_drug_id,
      'comparator_drug_name', comparator.canonical_name,
      'direction', r.direction::text,
      'magnitude_measure', r.magnitude_measure::text,
      -- ::text på alle numeric-verdier, av samme grunn som i 005h og 005k: et
      -- JSON-tall blir en IEEE-754 double før noen linje i kjøreren eller
      -- nettleseren leser det, og en avrundet størrelse kunne blitt bekreftet i
      -- stedet for den registrerte.
      'magnitude_value', r.magnitude_value::text,
      'magnitude_unit', r.magnitude_unit::text,
      'qualifiers', r.qualifiers,
      'uncertainty_summary', r.uncertainty_summary
    ),
    'links', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'claim_evidence_link_id', l.id,
          'relationship_type', l.relationship_type::text,
          'directness', l.directness::text,
          'relevance_note', l.relevance_note,
          -- Evidensfunnet bygges av den samme projeksjonen
          -- ekstraksjonskontrollen leser (migrasjon 005r). Blokken stod
          -- tidligere skrevet ut her også, og de to kopiene begynte å drive fra
          -- hverandre i det 005u og 005v la til forankring, identifikatorer og
          -- representasjonstype: den ene hadde dem, den andre ikke. Nå finnes
          -- projeksjonen ett sted, og mennesket og maskinen ser det samme bildet
          -- av evidensen uansett hvilken flate de kommer fra
          -- (ANTIDEP_CONSTITUTION.md §4, §9).
          'evidence_item', workflow.evidence_extraction_dossier(e.id),
          -- Den gjeldende ekstraksjonsverifikasjonen, med samme
          -- «siste vinner»-rekkefølge som publiseringsgatens G5 bruker, slik at
          -- de to aldri kan bli uenige om hva som er nyest. NULL betyr at ingen
          -- kontroll er registrert — ikke at kontrollen var negativ.
          'current_extraction_verification', (
            select jsonb_build_object(
              'evidence_verification_id', ev.id,
              'outcome', ev.outcome::text,
              'source_access', ev.source_access::text,
              'checked_fields', to_jsonb(ev.checked_fields),
              'verified_at', ev.verified_at
            )
            from workflow.evidence_verifications ev
            where ev.evidence_item_id = e.id
            order by ev.verified_at desc, ev.created_at desc, ev.id desc
            limit 1
          )
        )
        order by l.id::text
      ), '[]'::jsonb)
      from knowledge.claim_evidence_links l
      join knowledge.evidence_items e on e.id = l.evidence_item_id
      where l.claim_revision_id = r.id
    ),
    -- Det ene §30-spørsmålet som ikke kan besvares fra lenkene selv: registrert
    -- evidens for samme virkestoff og samme endepunkt som ikke er lenket til
    -- revisjonen. Listen er evidens Antidep HAR registrert, ikke evidensen som
    -- finnes — en tom liste betyr aldri at det ikke finnes motstridende
    -- forskning (ANTIDEP_CONSTITUTION.md §17).
    'unlinked_related_evidence', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'evidence_item_id', ue.id,
          'source_title', us.title,
          'source_status', us.source_status::text,
          'intervention_drug_name', ud.canonical_name,
          'outcome_label', uoc.canonical_label,
          'reported_direction', ue.reported_direction::text,
          'effect_measure', ue.effect_measure::text,
          'estimate', ue.estimate::text,
          'estimate_unit', ue.estimate_unit::text,
          'created_by_actor_key', ucreator.actor_key
        )
        order by ue.id::text
      ), '[]'::jsonb)
      from knowledge.evidence_items ue
      join knowledge.sources us on us.id = ue.source_id
      join catalog.drugs ud on ud.id = ue.intervention_drug_id
      join catalog.clinical_concepts uoc on uoc.id = ue.outcome_concept_id
      join provenance.actors ucreator on ucreator.id = ue.created_by_actor_id
      where ue.intervention_drug_id = cl.subject_drug_id
        and ue.outcome_concept_id = cl.topic_concept_id
        and not exists (
          select 1
          from knowledge.claim_evidence_links l2
          where l2.claim_revision_id = r.id
            and l2.evidence_item_id = ue.id
        )
    )
  )
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  join provenance.actors author on author.id = r.created_by_actor_id
  join catalog.drugs subject on subject.id = cl.subject_drug_id
  join catalog.clinical_concepts topic on topic.id = cl.topic_concept_id
  left join catalog.populations pop on pop.id = r.population_id
  left join catalog.drugs comparator on comparator.id = r.comparator_drug_id
  where r.id = p_claim_revision_id;
$$;
