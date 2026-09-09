-- ============================================================================
-- Migrasjon 005u — kildeforankring per kontrollfelt, produsert av ekstraksjonen
--
-- Den menneskelige ekstraksjonskontrollen (005s, 005t) kunne fram til nå bare
-- stille ett spørsmål: «stemmer denne raden med kilden?». Grunnlaget den spurte
-- mot var hele `raw_extraction` — utypet jsonb, uten kobling til hvilket felt et
-- utdrag gjelder, og selv en del av den maskinelle ekstraksjonen. En kontrollør
-- måtte dermed lese hele dossieret og selv finne ut hvilken setning i kilden som
-- svarer til hvilket felt.
--
-- Det er ikke en flatefeil. Koblingen mellom ett kontrollerbart felt og det
-- grunnlaget ekstraktøren faktisk brukte, fantes ikke som data.
--
-- ----------------------------------------------------------------------------
-- Hva som lagres, og hva som bevisst IKKE lagres
--
-- Raden bærer fire ting per felt:
--
--   1. hvilket felt forankringen gjelder (workflow.evidence_check_field)
--   2. det ordrette kildeutdraget, minst mulig og tilstrekkelig
--   3. den presise kildepekeren for nettopp det utdraget
--   4. en kort, eksplisitt begrunnelse for hvordan utdraget ble til verdien
--
-- Den femte tingen — «agentens strukturerte tolkning» — lagres bevisst *ikke*
-- her. Den finnes allerede: det er kolonnen på knowledge.evidence_items selv.
-- En kopi ved siden av ville vært en andre formulering av den kanoniske verdien,
-- og de to kunne kommet i utakt. Da ville kontrolløren bekreftet en setning som
-- ikke er det databasen faktisk holder — nøyaktig den feilen §4 og §8 finnes for
-- å hindre. Kontrollflaten bygger derfor utsagnet «Antidep mener …»
-- deterministisk av den kanoniske raden, og forankringen sier hva utsagnet
-- hviler på.
--
-- Skjult chain-of-thought lagres ikke og etterspørres ikke. `justification` er
-- en kort, eksplisitt begrunnelse beregnet på faglig kontroll — det samme et
-- menneske ville skrevet i margen.
--
-- ----------------------------------------------------------------------------
-- Hvorfor raden ligger i knowledge og ikke i workflow
--
-- Forankringen er en del av ekstraksjonen, ikke en vurdering av den. Den skrives
-- av den som laget funnet, i den samme transaksjonen, og den er append-only av
-- samme grunn som funnet selv. En vurdering av om forankringen holder, er en
-- workflow.evidence_verifications-rad og et annet objekt.
--
-- At forankringen tilhører ekstraktøren, er ikke en konvensjon: den sammensatte
-- fremmednøkkelen låser created_by_actor_id til evidensfunnets egen skaper, på
-- nøyaktig samme måte som speilkolonnene i migrasjon 005. En senere aktør kan
-- derfor ikke feste et utdrag på en annen aktørs ekstraksjon og få det til å se
-- ut som ekstraktørens eget grunnlag.
--
-- ----------------------------------------------------------------------------
-- Gamle funn har ingen forankring, og det skal være synlig
--
-- Ingenting her gjetter forankring for de funnene som allerede finnes. Et funn
-- uten forankring for et felt gir ingen rad, og flaten viser fraværet som
-- fravær. Å utlede et utdrag fra `raw_extraction` ville vært å konstruere det
-- grunnlaget kontrollen skal prøve (ANTIDEP_CONSTITUTION.md §6, §11).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §8, §10, §11, §14, §20
--   docs/DATABASE_ARCHITECTURE.md §19, §29, §35, §36, §43, §50, §59, §60
--   docs/EVIDENCE_PIPELINE.md §25, §61
--   docs/KNOWLEDGE_MODEL.md §19
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §29, §74.32, §74.37
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. audit.events dekker evidence_field_grounding_recorded
--
-- Samme ombygging som 005e, 007c, 007e, 005g, 005j og 006d måtte gjøre, og av
-- samme grunn: PostgreSQL har ingen ALTER COLUMN som endrer uttrykket til en
-- generert kolonne, og en CHECK kan bare endres ved DROP/ADD. Indeksen som
-- bruker begge kolonnene tas ned og opp igjen rundt det. Operasjonen er trygg på
-- levende rader: CASE-uttrykkene dekker hver eksisterende verdi uendret.
-- ----------------------------------------------------------------------------
drop index audit.events_object_occurred_at_idx;

alter table audit.events drop column object_schema;
alter table audit.events drop column object_table;

alter table audit.events add column object_schema text not null generated always as (
  case operation
    when 'claim_published' then 'knowledge'
    when 'claim_publication_replaced' then 'knowledge'
    when 'claim_publication_withdrawn' then 'knowledge'
    when 'claim_publication_rolled_back' then 'knowledge'
    when 'role_granted' then 'workflow'
    when 'role_ended' then 'workflow'
    when 'source_created' then 'knowledge'
    when 'evidence_item_created' then 'knowledge'
    when 'agent_identity_registered' then 'provenance'
    when 'agent_identity_credential_issued' then 'provenance'
    when 'agent_identity_revoked' then 'provenance'
    when 'evidence_verification_registered' then 'workflow'
    when 'source_version_registered' then 'knowledge'
    when 'claim_verification_registered' then 'workflow'
    when 'review_decision_registered' then 'workflow'
    when 'evidence_field_grounding_recorded' then 'knowledge'
  end
) stored;

alter table audit.events add column object_table text not null generated always as (
  case operation
    when 'claim_published' then 'claims'
    when 'claim_publication_replaced' then 'claims'
    when 'claim_publication_withdrawn' then 'claims'
    when 'claim_publication_rolled_back' then 'claims'
    when 'role_granted' then 'user_roles'
    when 'role_ended' then 'user_roles'
    when 'source_created' then 'sources'
    when 'evidence_item_created' then 'evidence_items'
    when 'agent_identity_registered' then 'agent_identities'
    when 'agent_identity_credential_issued' then 'agent_identities'
    when 'agent_identity_revoked' then 'agent_identities'
    when 'evidence_verification_registered' then 'evidence_verifications'
    when 'source_version_registered' then 'source_versions'
    when 'claim_verification_registered' then 'claim_verifications'
    when 'review_decision_registered' then 'review_decisions'
    when 'evidence_field_grounding_recorded' then 'evidence_field_groundings'
  end
) stored;

comment on column audit.events.object_schema is
  'Schemaet objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen, ikke oppgitt ved siden av den, slik at de to ikke kan komme i utakt. NOT NULL på en generert kolonne gjør at en ny enum-verdi uten tilhørende gren feiler ved innsetting framfor å gi en tom kolonne.';
comment on column audit.events.object_table is
  'Tabellen objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen, med samme begrunnelse som object_schema.';

create index events_object_occurred_at_idx
  on audit.events (object_schema, object_table, object_id, occurred_at desc);

alter table audit.events drop constraint events_snapshot_shape_check;
alter table audit.events add constraint events_snapshot_shape_check
  check (
    case operation
      when 'claim_published' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_replaced' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_withdrawn' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_rolled_back' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'role_granted' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'role_ended' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'source_created' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'evidence_item_created' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'agent_identity_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'agent_identity_credential_issued' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'agent_identity_revoked' then
        old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'evidence_verification_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'source_version_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'claim_verification_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'review_decision_registered' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      -- En opprettelse, som de øvrige registreringene: forankringen skrives i
      -- samme transaksjon som evidensfunnet og er append-only. En korrigert
      -- forankring hører til en korrigert ekstraksjon, som er et nytt funn.
      when 'evidence_field_grounding_recorded' then
        old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      else false
    end
  );

-- ----------------------------------------------------------------------------
-- 2. knowledge.evidence_field_groundings
--
-- Én rad per (evidensfunn, kontrollfelt). Unikheten er ikke ryddighet: to
-- forankringer av samme felt ville vært to påstander om hvilket utdrag verdien
-- hviler på, og en kontrollør som fikk se den ene, ville ikke visst at den andre
-- fantes. En korrigert forankring hører til en korrigert ekstraksjon, og den er
-- et nytt evidensfunn (knowledge.evidence_items er append-only).
-- ----------------------------------------------------------------------------
create table knowledge.evidence_field_groundings (
  id uuid primary key default gen_random_uuid(),

  evidence_item_id uuid not null
    references knowledge.evidence_items (id) on update restrict on delete restrict,

  -- Låst til evidensfunnets egen skaper av den sammensatte fremmednøkkelen
  -- under. Forankringen er en del av ekstraksjonen, ikke en senere påstand om
  -- den (DATABASE_ARCHITECTURE.md §59).
  created_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,

  -- Samme vokabular som en kontroll registrerer dekning i. To vokabularer ville
  -- før eller siden latt et forankret felt og et kontrollert felt være to
  -- forskjellige ting (DATABASE_ARCHITECTURE.md §29).
  check_field workflow.evidence_check_field not null,

  source_excerpt text not null,
  source_locator text not null,
  justification text not null,

  created_at timestamptz not null default now(),

  constraint evidence_field_groundings_item_fkey
    foreign key (evidence_item_id, created_by_actor_id)
    references knowledge.evidence_items (id, created_by_actor_id)
    on update restrict on delete restrict,

  constraint evidence_field_groundings_field_key
    unique (evidence_item_id, check_field),

  -- Et ordrett utdrag er ordrett tekst fra kilden. Ingenting her kan avgjøre om
  -- det er riktig gjengitt — det er kontrollens oppgave, og for de feltene den
  -- deterministiske verifikatoren kan bedømme, er det nettopp dette utdraget den
  -- leter etter ordrett i kilden.
  constraint evidence_field_groundings_excerpt_check
    check (source_excerpt = btrim(source_excerpt)
           and length(source_excerpt) between 1 and 4000),
  constraint evidence_field_groundings_locator_check
    check (source_locator = btrim(source_locator)
           and length(source_locator) between 1 and 600),
  constraint evidence_field_groundings_justification_check
    check (justification = btrim(justification)
           and length(justification) between 1 and 1000)
);

comment on table knowledge.evidence_field_groundings is
  'Kildeforankringen av ett kontrollerbart felt på ett evidensfunn: det ordrette kildeutdraget verdien er lest ut av, den presise kildepekeren for nettopp det utdraget, og en kort eksplisitt begrunnelse for hvordan utdraget ble til den strukturerte verdien (ANTIDEP_CONSTITUTION.md §8, §11). Produsert av ekstraksjonen selv, i samme transaksjon som evidensfunnet, og append-only som funnet. Den strukturerte verdien lagres bevisst ikke her: den er kolonnen på knowledge.evidence_items, og en kopi ved siden av kunne kommet i utakt med den kanoniske verdien. Skjult chain-of-thought verken lagres eller etterspørres; justification er en kort, eksplisitt begrunnelse beregnet på faglig kontroll. Et evidensfunn uten forankring for et felt gir ingen rad, og fraværet er en opplysning kontrollflaten viser som fravær — aldri noe som gjettes ut av raw_extraction.';
comment on column knowledge.evidence_field_groundings.created_by_actor_id is
  'Speil av aktøren som laget evidensfunnet, låst av den sammensatte fremmednøkkelen. Finnes for at kravet om at forankringen tilhører ekstraktøren skal kunne håndheves deklarativt på raden selv. Ikke en selvstendig sannhet.';
comment on column knowledge.evidence_field_groundings.check_field is
  'Hvilket kontrollerbart felt forankringen gjelder. Samme vokabular som workflow.evidence_verifications.checked_fields, slik at «hva er forankret» og «hva er kontrollert» måles på samme akse.';
comment on column knowledge.evidence_field_groundings.source_excerpt is
  'Det minste ordrette kildeutdraget som er tilstrekkelig for å bedømme feltet. Ordrett tekst fra kilden, aldri en omskrivning: den deterministiske verifikatoren leter etter nettopp denne strengen i den hentede representasjonen.';
comment on column knowledge.evidence_field_groundings.source_locator is
  'Hvor i kilden utdraget står. Mer presis enn evidensfunnets egen source_locator, som peker på funnet som helhet.';
comment on column knowledge.evidence_field_groundings.justification is
  'Kort eksplisitt begrunnelse for hvordan utdraget ble til den strukturerte verdien. Beregnet på faglig kontroll, ikke en gjengivelse av en modells indre resonnement.';

create index evidence_field_groundings_evidence_item_id_idx
  on knowledge.evidence_field_groundings (evidence_item_id);

create trigger evidence_field_groundings_set_created_at
  before insert on knowledge.evidence_field_groundings
  for each row execute function catalog.set_created_at();

create trigger evidence_field_groundings_reject_mutation
  before update or delete on knowledge.evidence_field_groundings
  for each row execute function knowledge.reject_append_only_mutation(
    'Forankringen dokumenterer hvilket kildeutdrag ekstraksjonen faktisk hvilte på da den ble laget. Er den feil, er ekstraksjonen feil: registrer et nytt evidensfunn med riktig verdi og riktig forankring, og la det gamle bestå.'
  );

alter table knowledge.evidence_field_groundings enable row level security;

revoke all privileges on table knowledge.evidence_field_groundings from public;
revoke all privileges on table knowledge.evidence_field_groundings
  from anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Auditsporet
--
-- Hele raden er snapshotet, som for evidensfunnet selv: tabellen er append-only
-- og har ingen egen hendelsestabell under seg (§35, §60).
-- ----------------------------------------------------------------------------
create function audit.record_evidence_field_grounding_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot,
    occurred_at
  )
  values (
    'evidence_field_grounding_recorded'::audit.event_operation,
    new.id,
    new.created_by_actor_id,
    null,
    to_jsonb(new),
    now()
  );

  return null;
end;
$$;

comment on function audit.record_evidence_field_grounding_event() is
  'Auditskriver for kildeforankringen av ett felt, med hele raden som snapshot. Kjører med kallerens rettigheter, ikke som SECURITY DEFINER, slik at en auditrad aldri kan skrives av noen som ikke kunne utført operasjonen selv (samme begrunnelse som audit.record_evidence_item_event()).';

revoke execute on function audit.record_evidence_field_grounding_event() from public;

create trigger evidence_field_groundings_record_audit_event
  after insert on knowledge.evidence_field_groundings
  for each row execute function audit.record_evidence_field_grounding_event();

-- ----------------------------------------------------------------------------
-- 4. workflow.evidence_field_groundings(uuid) — forankringene som finnes
--
-- Rekkefølgen er vokabularets egen (enum-rekkefølgen følger kolonnene på
-- evidensfunnet), slik at en kontrollflate som lister dem, lister dem i den
-- rekkefølgen raden er bygget. Tom liste betyr «ingen forankring registrert»,
-- aldri «ukjent».
-- ----------------------------------------------------------------------------
create function workflow.evidence_field_groundings(p_evidence_item_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'field_grounding_id', g.id,
        'check_field', g.check_field::text,
        'source_excerpt', g.source_excerpt,
        'source_locator', g.source_locator,
        'justification', g.justification,
        'created_at', g.created_at,
        'created_by_actor_id', g.created_by_actor_id
      )
      order by g.check_field
    ),
    '[]'::jsonb
  )
  from knowledge.evidence_field_groundings g
  where g.evidence_item_id = p_evidence_item_id;
$$;

comment on function workflow.evidence_field_groundings(uuid) is
  'Kildeforankringene som er registrert på ett evidensfunn, i vokabularets egen rekkefølge (ANTIDEP_CONSTITUTION.md §8, §11). Tom liste betyr at ingen forankring er registrert — aldri at forankringen er ukjent, og aldri noe en flate kan fylle inn fra raw_extraction. Brukes av workflow.evidence_extraction_dossier(uuid), slik at mennesket og den deterministiske verifikatoren ser nøyaktig den samme forankringen. SECURITY DEFINER fordi knowledge har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

revoke execute on function workflow.evidence_field_groundings(uuid) from public;

-- ----------------------------------------------------------------------------
-- 5. workflow.evidence_extraction_dossier(uuid) — grunnlaget får forankringen
--
-- Fremover-skrivende med `create or replace function`, som i 005r: signatur,
-- eier og rettigheter er uendret, og 20260910091000 er allerede kjørt i det
-- hostede prosjektet (§74.32). Svaret får én nøkkel til, `field_groundings`, og
-- ingen eksisterende nøkkel endrer form. Både
-- api.extraction_verification_input(...) (agenten),
-- api.extraction_review_workspace(uuid) (mennesket) og
-- workflow.claim_evidence_dossier(uuid) (påstandskontrollen) bygger svaret sitt
-- av denne funksjonen, så alle tre ser forankringen uten å bli endret hver for
-- seg.
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
      'status_note', s.status_note
    ),
    'source_version', case
      when sv.id is null then null
      else jsonb_build_object(
        'source_version_id', sv.id,
        'retrieved_at', sv.retrieved_at,
        'retrieved_from', sv.retrieved_from,
        'external_version', sv.external_version,
        'content_hash', sv.content_hash,
        'has_storage_reference', sv.storage_reference is not null
      )
    end,
    -- Forankringen per felt. Tom liste for et funn registrert før migrasjon
    -- 005u; fraværet er en opplysning og skal vises som fravær.
    'field_groundings', workflow.evidence_field_groundings(e.id),
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
-- 6. workflow.evidence_extraction_digest(uuid) — avtrykket dekker forankringen
--
-- Avtrykket sier hva en menneskelig kontroll faktisk gjaldt. Fra nå av er
-- forankringen en del av det kontrolløren leser felt for felt, og en forankring
-- som kommer til mens økten pågår, endrer nettopp det grunnlaget. Settet av
-- forankrings-ID-er legges derfor til, med samme begrunnelse som settet av
-- tidligere kontroller: en telling ville vært uendret av en sletting pluss en
-- innsetting (DATABASE_ARCHITECTURE.md §36).
--
-- Ingen lagret rad bærer et tidligere avtrykk — workflow.evidence_verifications
-- lagrer ikke det avtrykket kontrollen ble registrert mot — så en utvidelse her
-- ugyldiggjør ingen historikk. Den er strengere og ikke løsere: alt som lå i
-- avtrykket før, ligger der fortsatt.
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
