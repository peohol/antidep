-- ============================================================================
-- Migrasjon 005å — «senere» avgjøres av registreringsrekkefølgen, ikke av klokka
--
-- ----------------------------------------------------------------------------
-- Hullet
--
-- Hele kontrollkjeden hviler på én regel: den *siste* kontrollen er den
-- gjeldende. Publiseringsgatens G5 og G9 leser den, workflow.covered_check_fields
-- lar et senere avvik nullstille dekningen fra alt som ligger foran det, og
-- workflow.grounding_machine_proved lar et senere avvik nullstille maskinbeviset.
--
-- «Senere» ble avgjort av (verified_at, created_at, id). Begge tidsstemplene
-- settes med now(), som i PostgreSQL er *transaksjonens starttidspunkt* — ikke
-- tidspunktet raden faktisk ble skrevet. To samtidige registreringer kan derfor
-- starte i én rekkefølge og skrive i den motsatte:
--
--   Transaksjon A   begynner (now() = 10:00:00), gjør noe annet en stund.
--   Transaksjon B   begynner (now() = 10:00:05), tar radlåsen, skriver en
--                   bekreftelse, og commiter.
--   Transaksjon A   tar radlåsen etterpå, skriver `needs_correction`, commiter.
--
-- Raden som faktisk ble skrevet sist, bærer det eldste tidsstempelet. Sortert
-- på klokka blir B den gjeldende, og A — et reelt avvik, funnet på det samme
-- grunnlaget — forsvinner bak en bekreftelse som ble skrevet før det. Gaten
-- ville sluppet gjennom en publisering et registrert avvik skulle ha stoppet.
--
-- Låsen serialiserer skrivingene korrekt; det er *rekkefølgen de leses i* som
-- ikke følger den. Tidsstemplene er riktige som opplysninger om når arbeidet
-- ble gjort, og beholdes uendret. De er bare ikke en fasit for rekkefølge.
--
-- ----------------------------------------------------------------------------
-- Rettingen
--
-- Hver verifikasjonsrad får et registreringsnummer fra en sekvens, tildelt
-- *etter* at radlåsen på objektet er tatt. Låsen holdes ut transaksjonen, så to
-- registreringer på det samme objektet kan ikke tildele nummer samtidig, og
-- nummeret følger nødvendigvis den rekkefølgen radene faktisk skrives i.
-- Nummeret er databasens, ikke kallerens: triggeren overskriver enhver verdi
-- som måtte være oppgitt, av samme grunn som verified_grounding_digest ikke er
-- en parameter (migrasjon 005x).
--
-- Sekvensen har `cache 1` med vilje. En bufret sekvens deler ut blokker per
-- økt, og to økter ville da kunnet få numre i motsatt rekkefølge av
-- skrivingene — nøyaktig hullet dette lukker. Hull i nummerrekken er derimot
-- uten betydning: en tilbakerullet transaksjon har ikke skrevet noe, og
-- rekkefølgen mellom de radene som *finnes*, er fortsatt entydig.
--
-- Regelen gjelder begge verifikasjonstabellene. Ekstraksjonsverifikasjonen
-- låser evidensfunnet, claim-verifikasjonen låser påstandsrevisjonen — begge
-- låsene tas allerede av skriveveien, så triggeren tar ingen ny lås; den tar
-- den samme, og garanterer at nummeret tildeles på innsiden av den uansett
-- hvilken vei raden kommer inn.
--
-- Alle lesere som velger «den gjeldende» eller spør «finnes det en senere»,
-- bytter til det samme nummeret, slik at flaten, gaten og maskinbeviset ikke
-- kan bli uenige om hvilken rad som er den siste.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- verified_at og created_at beholdes uendret og leses fortsatt der spørsmålet
-- er *når* noe ble gjort: mandatkontrollene bruker radens eget verified_at,
-- fordi en rolletildeling som senere avsluttes ikke opphever en kontroll som
-- var legitim da den ble gjort. Ingen constraint er myket opp, ingen grant er
-- utvidet, og ingen funksjon har endret signatur.
--
-- Historiske rader nummereres etter nøyaktig den rekkefølgen systemet la til
-- grunn fram til nå — (verified_at, created_at, id) — slik at ingen tidligere
-- vurdering endrer betydning av migrasjonen.
--
-- workflow.review_decisions har samme form på «den gjeldende beslutningen» og
-- dermed samme svakhet. Den ligger utenfor denne PR-ens område og er skilt ut
-- som eget arbeid; å endre den her ville trukket den publiserte lesemodellen
-- inn i en migrasjon om kontrollrekkefølge.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §9, §11, §14, §17
--   docs/DATABASE_ARCHITECTURE.md §29, §30, §38, §57, §60
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §49, §74.38
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Registreringsrekkefølgen
-- ----------------------------------------------------------------------------
create sequence workflow.evidence_verification_registration_seq
  as bigint start with 1 increment by 1 no cycle cache 1;
create sequence workflow.claim_verification_registration_seq
  as bigint start with 1 increment by 1 no cycle cache 1;

revoke all on sequence workflow.evidence_verification_registration_seq from public;
revoke all on sequence workflow.claim_verification_registration_seq from public;

comment on sequence workflow.evidence_verification_registration_seq is
  'Kilden til registreringsnummeret på workflow.evidence_verifications. cache 1 er en del av garantien: en bufret sekvens deler ut blokker per økt, og to økter kunne da fått numre i motsatt rekkefølge av skrivingene — nøyaktig det migrasjon 005å lukker. Hull i rekken er uten betydning; en tilbakerullet transaksjon har ikke skrevet noen rad.';
comment on sequence workflow.claim_verification_registration_seq is
  'Kilden til registreringsnummeret på workflow.claim_verifications. Samme begrunnelse for cache 1 som på ekstraksjonssekvensen (migrasjon 005å).';

alter table workflow.evidence_verifications add column registration_ordinal bigint;
alter table workflow.claim_verifications add column registration_ordinal bigint;

alter sequence workflow.evidence_verification_registration_seq
  owned by workflow.evidence_verifications.registration_ordinal;
alter sequence workflow.claim_verification_registration_seq
  owned by workflow.claim_verifications.registration_ordinal;

-- ----------------------------------------------------------------------------
-- 2. Historiske rader beholder den rekkefølgen de allerede hadde
--
-- Tabellene er append-only, og triggeren som håndhever det, tas ned og opp
-- igjen rundt nummereringen. Den er der for å hindre at en registrert kontroll
-- endres i ettertid; her legges det til et databaseeid nummer på rader som
-- ikke hadde det, i nøyaktig den rekkefølgen systemet allerede la til grunn.
-- Ingen vurdering endrer betydning.
-- ----------------------------------------------------------------------------
alter table workflow.evidence_verifications disable trigger evidence_verifications_reject_mutation;
alter table workflow.claim_verifications disable trigger claim_verifications_reject_mutation;

with ordered as (
  select id, row_number() over (order by verified_at, created_at, id) as n
  from workflow.evidence_verifications
)
update workflow.evidence_verifications ev
set registration_ordinal = ordered.n
from ordered
where ordered.id = ev.id;

with ordered as (
  select id, row_number() over (order by verified_at, created_at, id) as n
  from workflow.claim_verifications
)
update workflow.claim_verifications cv
set registration_ordinal = ordered.n
from ordered
where ordered.id = cv.id;

alter table workflow.evidence_verifications enable trigger evidence_verifications_reject_mutation;
alter table workflow.claim_verifications enable trigger claim_verifications_reject_mutation;

select setval(
  'workflow.evidence_verification_registration_seq',
  coalesce((select max(registration_ordinal) from workflow.evidence_verifications), 0) + 1,
  false
);
select setval(
  'workflow.claim_verification_registration_seq',
  coalesce((select max(registration_ordinal) from workflow.claim_verifications), 0) + 1,
  false
);

-- ----------------------------------------------------------------------------
-- 3. Kolonnen er obligatorisk og entydig
--
-- NOT NULL uten DEFAULT er med vilje: en DEFAULT evalueres *før* BEFORE-triggere
-- fyrer, altså før låsen er tatt, og ville gitt nøyaktig den rekkefølgen denne
-- migrasjonen finnes for å unngå. Uten default feiler enhver skrivevei som
-- omgår triggeren, høylytt og med en gang, framfor å skrive en rad uten plass i
-- rekkefølgen.
-- ----------------------------------------------------------------------------
alter table workflow.evidence_verifications
  alter column registration_ordinal set not null,
  add constraint evidence_verifications_registration_ordinal_key
    unique (registration_ordinal);
alter table workflow.claim_verifications
  alter column registration_ordinal set not null,
  add constraint claim_verifications_registration_ordinal_key
    unique (registration_ordinal);

comment on column workflow.evidence_verifications.registration_ordinal is
  'Rekkefølgen kontrollen ble registrert i, tildelt av databasen fra en sekvens etter at radlåsen på evidensfunnet er tatt (migrasjon 005å). Fasiten for «senere» og «gjeldende» overalt: publiseringsgatens G5 og G5c, workflow.covered_check_fields, workflow.grounding_machine_proved og reviewerflaten leser alle den samme nøkkelen. verified_at kan ikke brukes til det, fordi now() er transaksjonens starttidspunkt: to samtidige registreringer kan starte i én rekkefølge og skrive i den motsatte, og et reelt avvik ville da kunnet gjemme seg bak en bekreftelse som ble skrevet før det. Ikke en parameter: triggeren overskriver enhver oppgitt verdi, av samme grunn som verified_grounding_digest ikke er det.';
comment on column workflow.claim_verifications.registration_ordinal is
  'Rekkefølgen kontrollen ble registrert i, tildelt av databasen fra en sekvens etter at radlåsen på påstandsrevisjonen er tatt (migrasjon 005å). Fasiten for «den gjeldende claim-verifikasjonen» i publiseringsgatens G9, G9b og G9c og i reviewerflaten. Samme begrunnelse som på ekstraksjonsverifikasjonen: verified_at er transaksjonens starttidspunkt og sier derfor ikke hvilken rad som ble skrevet sist.';

-- ----------------------------------------------------------------------------
-- 4. Nummeret tildeles på innsiden av låsen
--
-- Triggerne gjør det framfor skriveveiene, slik at nummeret er en egenskap ved
-- tabellen og ikke ved den ene funksjonen som tilfeldigvis skriver til den.
-- Låsen er den samme skriveveiene allerede tar (workflow.record_evidence_verification
-- og workflow.set_claim_verification_evidence_set_digest), så dette er ingen ny
-- lås og ingen ny låserekkefølge.
-- ----------------------------------------------------------------------------
create function workflow.set_evidence_verification_registration_ordinal()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  -- Låsen først, nummeret etterpå, og låsen holdes ut transaksjonen. Rekkefølgen
  -- er hele poenget: tildeles nummeret før låsen, kan to registreringer få dem i
  -- motsatt rekkefølge av skrivingene.
  perform 1
  from knowledge.evidence_items e
  where e.id = new.evidence_item_id
  for update;

  new.registration_ordinal :=
    nextval('workflow.evidence_verification_registration_seq');

  return new;
end;
$$;

comment on function workflow.set_evidence_verification_registration_ordinal() is
  'Gir databasen eierskap til registreringsrekkefølgen på en ekstraksjonskontroll, og tildeler nummeret på innsiden av radlåsen på evidensfunnet slik at det følger den rekkefølgen radene faktisk skrives i (migrasjon 005å). Overskriver enhver verdi kalleren måtte ha oppgitt: en verdi kalleren kunne valgt, ville vært nøyaktig den påstanden kolonnen finnes for å binde. SECURITY DEFINER fordi knowledge har RLS med default deny; funksjonen leser bare og skriver bare til raden som settes inn.';

revoke execute on function workflow.set_evidence_verification_registration_ordinal() from public;

create function workflow.set_claim_verification_registration_ordinal()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform 1
  from knowledge.claim_revisions r
  where r.id = new.claim_revision_id
  for update;

  new.registration_ordinal :=
    nextval('workflow.claim_verification_registration_seq');

  return new;
end;
$$;

comment on function workflow.set_claim_verification_registration_ordinal() is
  'Gir databasen eierskap til registreringsrekkefølgen på en claim-verifikasjon, og tildeler nummeret på innsiden av radlåsen på påstandsrevisjonen — den samme låsen workflow.set_claim_verification_evidence_set_digest allerede tar (migrasjon 005å). SECURITY DEFINER fordi knowledge har RLS med default deny; funksjonen leser bare og skriver bare til raden som settes inn.';

revoke execute on function workflow.set_claim_verification_registration_ordinal() from public;

-- Navnene er valgt slik at triggerne fyrer etter de øvrige BEFORE INSERT-triggerne
-- på tabellene; rekkefølgen er alfabetisk, og ingen av dem avhenger av de andres
-- resultat.
create trigger evidence_verifications_set_registration_ordinal
  before insert on workflow.evidence_verifications
  for each row execute function workflow.set_evidence_verification_registration_ordinal();

create trigger claim_verifications_set_registration_ordinal
  before insert on workflow.claim_verifications
  for each row execute function workflow.set_claim_verification_registration_ordinal();

-- ----------------------------------------------------------------------------
-- 5. Leserne bytter fasit
--
-- Hver funksjon under er uendret utenfra: samme signatur, samme resultat, samme
-- avvisninger med samme SQLSTATE og samme tekst. Det eneste som er byttet, er
-- nøkkelen «den gjeldende» og «finnes det en senere» leses med. Alle bytter
-- samtidig og til det samme, slik at gaten, maskinbeviset, dekningen og de to
-- reviewerflatene ikke kan bli uenige om hvilken rad som er den siste.
--
-- Rekkefølgen speiles også i sort_key på de to historikkflatene: en flate som
-- viste kontrollene i én rekkefølge mens gaten leste dem i en annen, ville vist
-- en annen «siste kontroll» enn den som gjelder.
-- ----------------------------------------------------------------------------
create or replace function workflow.covered_check_fields(p_evidence_item_id uuid)
  returns workflow.evidence_check_field[]
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select coalesce(
    array_agg(distinct f.field),
    '{}'::workflow.evidence_check_field[]
  )
  from workflow.evidence_verifications ev
  cross join unnest(ev.checked_fields) as f(field)
  where ev.evidence_item_id = p_evidence_item_id
    -- En kontroll som fant et avvik, dekker ingenting: konklusjonen motsier
    -- raden. En uavklart kontroll motsier ingenting — den konkluderte bare
    -- ikke om raden som helhet, og feltene den førte opp, gikk den gjennom.
    and ev.outcome in ('verified', 'uncertain')
    and not exists (
      select 1
      from workflow.evidence_verifications later
      where later.evidence_item_id = p_evidence_item_id
        and later.outcome in ('needs_correction', 'rejected')
        and later.registration_ordinal > ev.registration_ordinal
    );
$$;

create or replace function workflow.grounding_machine_proved(p_evidence_item_id uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1
    from workflow.evidence_verifications ev
    where ev.evidence_item_id = p_evidence_item_id
      -- En agentkjøring. De to sammensatte fremmednøklene på tabellen
      -- garanterer at den er i rollen extraction_verification.
      and ev.agent_run_id is not null
      -- …som gjelder nøyaktig det grunnlaget raden har nå.
      and ev.verified_grounding_digest
          = workflow.evidence_grounding_digest(p_evidence_item_id)
      -- …og som ikke selv fant et avvik.
      and ev.outcome in ('verified', 'uncertain')
      -- …og som førte opp kildepekeren, som er beviset.
      and 'source_locator' = any (ev.checked_fields)
      -- …og som ingen har underkjent siden. Samme regel som
      -- workflow.covered_check_fields(uuid), og av samme grunn: en tidligere
      -- bekreftelse opphever ikke et senere avvik.
      and not exists (
        select 1
        from workflow.evidence_verifications later
        where later.evidence_item_id = p_evidence_item_id
          and later.outcome in ('needs_correction', 'rejected')
          and later.registration_ordinal > ev.registration_ordinal
      )
  );
$$;

create or replace function workflow.evidence_verification_history(p_evidence_item_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select jsonb_build_object(
    'current_extraction_verification_id', (
      select ev.id
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = p_evidence_item_id
      order by ev.registration_ordinal desc
      limit 1
    ),
    'extraction_verifications', (
      select coalesce(jsonb_agg(v order by v ->> 'sort_key' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'evidence_verification_id', ev.id,
          'sort_key', lpad(ev.registration_ordinal::text, 20, '0'),
          'outcome', ev.outcome::text,
          'source_access', ev.source_access::text,
          'checked_fields', to_jsonb(ev.checked_fields::text[]),
          'findings', ev.findings,
          'rationale', ev.rationale,
          'verified_at', ev.verified_at,
          'created_at', ev.created_at,
          'verifier_actor_id', ev.verifier_actor_id,
          'verifier_actor_key', va.actor_key,
          'verifier_actor_type', va.actor_type::text,
          'verifier_display_name', va.display_name,
          -- NULL betyr at kontrollen ble gjort av et menneske, ikke at en
          -- agentkjøring mangler.
          'agent_run_id', ev.agent_run_id
        ) as v
        from workflow.evidence_verifications ev
        join provenance.actors va on va.id = ev.verifier_actor_id
        where ev.evidence_item_id = p_evidence_item_id
      ) as verifications
    )
  );
$$;

create or replace function api.extraction_review_workspace(p_evidence_item_id uuid default null)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_reviewer_actor_id uuid;
  v_dossier jsonb;
  v_outcome_concept_id uuid;
  v_queue jsonb;
begin
  -- Kalleren må være reviewer i det hele tatt. Avvisningen kommer fra
  -- workflow.assert_reviewer_authorized(uuid) og navngir hvilket krav som
  -- sviktet; uten et begrep godtas enhver gyldig tildeling, avgrenset eller ikke.
  v_reviewer_actor_id := workflow.assert_reviewer_authorized(null);

  if p_evidence_item_id is null then
    select coalesce(jsonb_agg(item order by item ->> 'created_at'), '[]'::jsonb)
    into v_queue
    from (
      select jsonb_build_object(
        'evidence_item_id', e.id,
        'created_at', e.created_at,
        'created_by_actor_id', e.created_by_actor_id,
        'created_by_actor_key', creator.actor_key,
        'source_id', s.id,
        'source_title', s.title,
        'source_status', s.source_status::text,
        'intervention_drug_name', d.canonical_name,
        'outcome_label', oc.canonical_label,
        'outcome_concept_id', e.outcome_concept_id,
        -- Fravær står som fravær: NULL betyr at ingen kontroll er registrert,
        -- aldri at en kontroll konkluderte negativt (§17).
        'current_extraction_verification_outcome', (
          select ev.outcome::text
          from workflow.evidence_verifications ev
          where ev.evidence_item_id = e.id
          order by ev.registration_ordinal desc
          limit 1
        ),
        'verification_count', (
          select count(*)
          from workflow.evidence_verifications ev
          where ev.evidence_item_id = e.id
        ),
        -- Gatens egne funksjoner, ikke en kopi av dem.
        'required_check_fields',
          to_jsonb(workflow.required_check_fields(e.id)::text[]),
        'covered_check_fields',
          to_jsonb(workflow.covered_check_fields(e.id)::text[]),
        'linked_claim_revision_count', (
          select count(*)
          from knowledge.claim_evidence_links l
          where l.evidence_item_id = e.id
        )
      ) as item
      from knowledge.evidence_items e
      join knowledge.sources s on s.id = e.source_id
      join provenance.actors creator on creator.id = e.created_by_actor_id
      join catalog.drugs d on d.id = e.intervention_drug_id
      join catalog.clinical_concepts oc on oc.id = e.outcome_concept_id
      where
        -- Radgrensen: en avgrenset reviewer-tildeling ser bare sitt eget
        -- innholdsområde. En uavgrenset ser alt.
        workflow.caller_is_active_reviewer(e.outcome_concept_id)
        -- Funn kalleren selv har laget er utelatt: de kan aldri kontrolleres av
        -- den (evidence_verifications_separate_actor_check), så å ha dem i køen
        -- ville vært å be om et kall som må avvises. De er fortsatt adresserbare
        -- direkte, og flaten sier da hvorfor de ikke kan behandles.
        and e.created_by_actor_id <> v_reviewer_actor_id
        -- Funn denne aktøren allerede har kontrollert er utelatt. En annen
        -- reviewer ser dem fortsatt: to uavhengige kontrollag er to aktører, og
        -- tabellen er append-only, så begge kontrollene består ved siden av
        -- hverandre.
        and not exists (
          select 1
          from workflow.evidence_verifications ev
          where ev.evidence_item_id = e.id
            and ev.verifier_actor_id = v_reviewer_actor_id
        )
    ) as queue;

    return jsonb_build_object(
      'reviewer_actor_id', v_reviewer_actor_id,
      'queue', v_queue
    );
  end if;

  v_dossier := workflow.evidence_extraction_dossier(p_evidence_item_id);

  if v_dossier is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Evidensfunnet %L finnes ikke.', p_evidence_item_id),
      hint = 'Kontrollen peker på ett bestemt evidensfunn. Kontroller id-en, eller gå til køen og velg et funn derfra.';
  end if;

  select e.outcome_concept_id into v_outcome_concept_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;

  -- En avgrenset reviewer-tildeling gir ikke innsyn utenfor sitt eget
  -- innholdsområde, heller ikke ved direkte oppslag. Avvisningen er den samme
  -- som skriveveien ville gitt.
  perform workflow.assert_reviewer_authorized(v_outcome_concept_id);

  return jsonb_build_object(
    'reviewer_actor_id', v_reviewer_actor_id,
    'item', v_dossier
      || workflow.evidence_verification_history(p_evidence_item_id)
      || jsonb_build_object(
           -- Avtrykket vurderingen bindes til. Sendes tilbake uendret av
           -- skriveveien, som sammenligner det med grunnlaget slik det er da.
           'extraction_digest', workflow.evidence_extraction_digest(p_evidence_item_id),
           'required_check_fields',
             to_jsonb(workflow.required_check_fields(p_evidence_item_id)::text[]),
           'covered_check_fields',
             to_jsonb(workflow.covered_check_fields(p_evidence_item_id)::text[]),
           'linked_claim_revisions', (
             select coalesce(jsonb_agg(
               jsonb_build_object(
                 'claim_revision_id', r.id,
                 'claim_id', r.claim_id,
                 'revision_number', r.revision_number,
                 'statement', r.statement,
                 'subject_drug_name', subject.canonical_name,
                 'topic_label', topic.canonical_label,
                 'relationship_type', l.relationship_type::text,
                 'is_published_revision',
                   coalesce(cl.current_published_revision_id = r.id, false)
               )
               order by r.created_at, r.id::text
             ), '[]'::jsonb)
             from knowledge.claim_evidence_links l
             join knowledge.claim_revisions r on r.id = l.claim_revision_id
             join knowledge.claims cl on cl.id = r.claim_id
             join catalog.drugs subject on subject.id = cl.subject_drug_id
             join catalog.clinical_concepts topic on topic.id = cl.topic_concept_id
             where l.evidence_item_id = p_evidence_item_id
           )
         )
  );
end;
$$;

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
            order by ev.registration_ordinal desc
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

create or replace function knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_offenders text;
  v_claim_verification_outcome workflow.verification_outcome;
  v_claim_verifier_actor_id uuid;
  v_claim_verified_at timestamptz;
  v_claim_verified_digest text;
begin
  -- G1: revisjonen finnes.
  select r.claim_id, r.knowledge_type, c.retired_at
    into v_claim_id, v_knowledge_type, v_retired_at
  from knowledge.claim_revisions r
  join knowledge.claims c on c.id = r.claim_id
  where r.id = p_claim_revision_id;

  if not found then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Påstandsrevisjon %L finnes ikke.', p_claim_revision_id),
      hint = 'Publisering peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  -- G2: påstanden er ikke trukket tilbake.
  if v_retired_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Påstanden bak revisjon %L er trukket tilbake og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'En tilbaketrukket påstand er tatt ut av bruk. Opprett en ny påstand dersom temaet fortsatt skal dekkes; historikken til den gamle bevares (DATABASE_ARCHITECTURE.md §36).';
  end if;

  -- G3: nødvendige EvidenceItems finnes.
  -- ANTIDEP_CONSTITUTION.md §4: ingen publisert klinisk relevant påstand skal
  -- eksistere uten eksplisitt kobling til én eller flere identifiserbare kilder.
  -- Kravet gjelder alle tre kunnskapstypene; også et deterministisk faktum skal
  -- kunne spores til kilden sin.
  if not exists (
    select 1
    from knowledge.claim_evidence_links l
    where l.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrerte evidenslenker og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'Registrer minst ett evidensfunn med en begrunnet relasjon til revisjonen. En publisert påstand uten kobling til en identifiserbar kilde er ikke etterprøvbar (ANTIDEP_CONSTITUTION.md §4).';
  end if;

  -- G4: hvert lenket evidensfunn er faktisk kontrollert av noen.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and not exists (
      select 1
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = l.evidence_item_id
    );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn uten registrert ekstraksjonsverifikasjon: %s.', v_offenders
      ),
      hint = 'En separat kontrollfase skal ha gått gjennom ekstraksjonen mot kildematerialet før påstanden publiseres (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29). Registrer verifikasjonen i workflow.evidence_verifications.';
  end if;

  -- G5: den gjeldende ekstraksjonsverifikasjonen bekrefter funnet.
  -- Den siste kontrollen er den gjeldende: et senere needs_correction, rejected
  -- eller uncertain er et åpent blokkerende verifikasjonsfunn, uansett hvor mange
  -- bekreftelser som ligger foran det.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and (
      select ev.outcome
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = l.evidence_item_id
      order by ev.registration_ordinal desc
      limit 1
    ) <> 'verified';

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn med åpent verifikasjonsfunn: %s.', v_offenders
      ),
      hint = 'Den siste registrerte ekstraksjonsverifikasjonen konkluderer ikke med verified. Rett ekstraksjonen i et nytt evidensfunn og registrer en ny kontroll; en tidligere bekreftelse opphever ikke et senere avvik.';
  end if;

  -- G5b: kontrollene dekker til sammen det raden faktisk påstår.
  --
  -- G5 leste bare `outcome`. En kontroll som *med vilje* lar felter stå
  -- ukontrollert — den deterministiske ekstraksjonsverifikatoren bedømmer
  -- verken tidspunkt, retning, effektmål, availability-semantikk eller
  -- forbehold — kunne dermed tilfredsstille en gate som er ment å bety at
  -- ekstraksjonen er kontrollert. `checked_fields` sa sannheten, men ingen
  -- leste den (DATABASE_ARCHITECTURE.md §29).
  --
  -- Regelen er uendret fra migrasjon 005i, inkludert at dekningen har samme
  -- gjeldende-semantikk som utfallet: en ikke-bekreftende kontroll nullstiller
  -- den, slik at et senere avvik ikke kan omgås av en enda senere delkontroll
  -- som aldri så på det omstridte feltet. Selve unionen står nå i
  -- workflow.covered_check_fields(uuid), fordi reviewerflaten skal vise nøyaktig
  -- den dekningen gaten krever (migrasjon 005q).
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and exists (
      select 1
      from unnest(workflow.required_check_fields(l.evidence_item_id)) as required(field)
      where required.field <> all (workflow.covered_check_fields(l.evidence_item_id))
    );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn uten fullstendig kontrollert ekstraksjon: %s.', v_offenders
      ),
      hint = 'De registrerte kontrollene dekker ikke alle feltene funnet påstår noe om. workflow.required_check_fields(evidence_item_id) viser hva som kreves; en delkontroll kan ikke alene tilfredsstille publiseringsgaten (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29). Merk at en ikke-bekreftende kontroll nullstiller dekningen: bekreftelser som ligger foran den, teller ikke lenger.';
  end if;

  -- G5c: den gjeldende ekstraksjonskontrollen ble gjort av noen med mandat.
  --
  -- Speilbildet av G9c, og det finnes av samme grunn. Migrasjon 005q håndhever
  -- mandatet ved innsetting, og dette vilkåret er den andre lesningen av den
  -- samme regelen — den samme funksjonen, slik at de to ikke kan komme i utakt.
  -- At begge finnes, er bevisst: gaten er stedet der konsekvensen inntreffer, og
  -- en rad skrevet før regelen fantes, gjennom en senere skrivevei, eller av en
  -- vedlikeholdsoperasjon, skal ikke kunne bære en publisering fordi den slapp
  -- forbi det ene laget.
  --
  -- «Den gjeldende» er den samme raden G5 leser, hentet med den samme
  -- rekkefølgen. G4 har allerede slått fast at det finnes minst én.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  cross join lateral (
    select ev.verifier_actor_id, ev.verified_at
    from workflow.evidence_verifications ev
    where ev.evidence_item_id = l.evidence_item_id
    order by ev.registration_ordinal desc
    limit 1
  ) as current_check
  where l.claim_revision_id = p_claim_revision_id
    and not workflow.evidence_verifier_has_mandate(
          current_check.verifier_actor_id, l.evidence_item_id, current_check.verified_at
        );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn der den gjeldende ekstraksjonskontrollen mangler mandat: %s.', v_offenders
      ),
      hint = 'Kontroll av en ekstraksjon mot kilden er et eget mandat (ANTIDEP_CONSTITUTION.md §10): en agent må ha rollen extraction_verification, og et menneske må ha hatt gyldig reviewer-rolle for endepunktet funnet rapporterer om da kontrollen ble gjort. Registrer en ny kontroll fra en aktør som har mandatet.';
  end if;

  -- G6: ingen lenket ekstraksjon er trukket tilbake.
  -- Overlevert eksplisitt fra migrasjon 005: «er dette evidensfunnet trukket
  -- tilbake?» er ikke en statuskolonne, men en avledet tilstand — den siste
  -- beslutningen av typen extraction_withdrawal for funnet.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and (
      select rd.decision
      from workflow.review_decisions rd
      where rd.evidence_item_id = l.evidence_item_id
        and rd.review_type = 'extraction_withdrawal'
      order by rd.decided_at desc, rd.created_at desc, rd.id desc
      limit 1
    ) = 'extraction_withdrawn';

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn med tilbaketrukket ekstraksjon: %s.', v_offenders
      ),
      hint = 'En tilbaketrukket ekstraksjon skal ikke bære en publisert påstand. Opprett en ny revisjon uten det tilbaketrukne funnet, eller registrer en ny beslutning som opprettholder ekstraksjonen dersom tilbaketrekkingen var feil (DATABASE_ARCHITECTURE.md §29).';
  end if;

  -- G7: ingen lenket kilde er trukket tilbake eller tilbakekalt.
  -- DATABASE_ARCHITECTURE.md §58, siste kulepunkt: en withdrawn eller retracted
  -- kilde skal ikke ubemerket tilfredsstille en gate som om statusen var normal.
  select string_agg(distinct s.id::text, ', ' order by s.id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  join knowledge.evidence_items e on e.id = l.evidence_item_id
  join knowledge.sources s on s.id = e.source_id
  where l.claim_revision_id = p_claim_revision_id
    and s.source_status in ('retracted', 'withdrawn');

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Kilder med statusen retracted eller withdrawn i grunnlaget: %s.', v_offenders
      ),
      hint = 'En tilbaketrukket eller tilbakekalt kilde kan ikke bære en publisert påstand. Vurder grunnlaget på nytt i en ny revisjon (DATABASE_ARCHITECTURE.md §58).';
  end if;

  -- G8: påstanden er kontrollert mot grunnlaget.
  -- DATABASE_ARCHITECTURE.md §38 sitt «ClaimEvidenceLinks er kontrollert» er
  -- nettopp claim-verifikasjonen fra §30: den kontrollerer om grunnlaget faktisk
  -- støtter ordlyden, om populasjon, komparator, tidsramme, retning og størrelse
  -- stemmer, om vesentlige forbehold mangler og om motstridende evidens er
  -- representert. Migrasjon 005 håndhever allerede at en verifikasjon ikke kan
  -- konkludere med verified uten at alle sju punktene er bedømt og holder.
  if not exists (
    select 1
    from workflow.claim_verifications cv
    where cv.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrert claim-verifikasjon.', p_claim_revision_id
      ),
      hint = 'En separat kontrollfase skal ha forsøkt å falsifisere påstanden mot det registrerte grunnlaget før den publiseres (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §30). Registrer kontrollen i workflow.claim_verifications.';
  end if;

  -- G9, G9b og G9c leser alle den *gjeldende* claim-verifikasjonen, altså den
  -- siste, med samme rekkefølge G5 bruker for ekstraksjonsverifikasjonene. Den
  -- leses én gang, slik at de tre vilkårene aldri kan bli uenige om hvilken rad
  -- de snakker om.
  select cv.outcome, cv.verifier_actor_id, cv.verified_at, cv.verified_evidence_set_digest
    into v_claim_verification_outcome, v_claim_verifier_actor_id,
         v_claim_verified_at, v_claim_verified_digest
  from workflow.claim_verifications cv
  where cv.claim_revision_id = p_claim_revision_id
  order by cv.registration_ordinal desc
  limit 1;

  -- G9: den gjeldende claim-verifikasjonen bekrefter påstanden.
  if v_claim_verification_outcome <> 'verified' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L konkluderer ikke med verified.',
        p_claim_revision_id
      ),
      hint = 'Den siste registrerte kontrollen er den gjeldende. Rett påstanden i en ny revisjon og få den kontrollert på nytt; en tidligere bekreftelse opphever ikke et senere avvik.';
  end if;

  -- G9b: kontrollen gjaldt det evidenssettet som faktisk ville blitt publisert.
  --
  -- En claim-verifikasjon er en vurdering av påstanden mot et bestemt grunnlag,
  -- og migrasjon 005j gir databasen eierskap til avtrykket av det grunnlaget.
  -- Uten dette vilkåret ville sekvensen «kontroller → legg til en lenke →
  -- publiser» sluppet gjennom en bekreftelse som aldri så den nye lenken — og
  -- den lenken kan være nettopp den motstridende evidensen kontrollen skulle
  -- lete etter (ANTIDEP_CONSTITUTION.md §9, §11, KNOWLEDGE_MODEL.md §19.2).
  --
  -- Sammenligningen er på avtrykk og ikke på tidspunkter, av samme grunn som
  -- G13: now() er transaksjonens starttidspunkt og ikke committidspunktet, så en
  -- lenke kan bære en created_at foran kontrollen og likevel ha blitt synlig
  -- etter den. Avtrykket er uavhengig av rekkefølge.
  if knowledge.claim_evidence_set_digest(p_claim_revision_id)
     is distinct from v_claim_verified_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensgrunnlaget for revisjon %L er endret etter den gjeldende claim-verifikasjonen.',
        p_claim_revision_id
      ),
      hint = 'Kontrollen gjaldt et annet evidenssett enn det som er registrert nå, og dekker derfor ikke grunnlaget påstanden ville blitt publisert på. Registrer en ny claim-verifikasjon som dekker hele det utvidede settet (ANTIDEP_CONSTITUTION.md §4, §9).';
  end if;

  -- G9c: kontrollen ble gjort av noen med mandat til det.
  --
  -- Migrasjon 005j håndhever mandatet ved innsetting, og dette vilkåret er den
  -- andre lesningen av den samme regelen — den samme funksjonen, slik at de to
  -- ikke kan komme i utakt. At begge finnes, er bevisst: gaten er stedet der
  -- konsekvensen inntreffer, og en rad skrevet før regelen fantes, gjennom en
  -- senere skrivevei, eller av en vedlikeholdsoperasjon, skal ikke kunne bære en
  -- publisering fordi den slapp forbi det ene laget.
  --
  -- Tidspunktet er radens eget verified_at, ikke now(): en rolletildeling som
  -- senere avsluttes, opphever ikke en kontroll som var legitim da den ble
  -- gjort. Historikken består (ANTIDEP_CONSTITUTION.md §14).
  if not workflow.claim_verifier_has_mandate(
       v_claim_verifier_actor_id, p_claim_revision_id, v_claim_verified_at
     ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L er registrert av en aktør uten mandat til å kontrollere påstanden.',
        p_claim_revision_id
      ),
      hint = 'Sitat- og kildestøtteverifikasjon er et eget mandat (ANTIDEP_CONSTITUTION.md §10): en agent må ha rollen citation_support_verification, og et menneske må ha hatt gyldig reviewer-rolle for innholdsområdet da kontrollen ble gjort. Registrer en ny kontroll fra en aktør som har mandatet.';
  end if;

  -- G10: evidensvurderingen finnes for de typene som skal ha en.
  -- ANTIDEP_CONSTITUTION.md §6: en evidensbasert syntese skal ha en eksplisitt
  -- vurdering av sikkerheten i kunnskapsgrunnlaget. Migrasjon 004 tillater ikke
  -- en vurdering på et deterministisk faktum, så kravet gjelder de to typene som
  -- kan ha en.
  if v_knowledge_type in ('evidence_synthesis', 'clinical_recommendation')
     and not exists (
       select 1
       from knowledge.evidence_assessments a
       where a.claim_revision_id = p_claim_revision_id
     ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L mangler evidensvurdering og kan ikke publiseres som %s.',
        p_claim_revision_id, v_knowledge_type
      ),
      hint = 'En evidenssyntese eller klinisk anbefaling skal ha en eksplisitt vurdering av sikkerheten i kunnskapsgrunnlaget, med de fem GRADE-domenene vurdert (ANTIDEP_CONSTITUTION.md §6). Registrer vurderingen i knowledge.evidence_assessments.';
  end if;

end;
$$;

create or replace function workflow.claim_review_history(p_claim_revision_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select jsonb_build_object(
    'current_claim_verification_id', (
      select cv.id
      from workflow.claim_verifications cv
      where cv.claim_revision_id = p_claim_revision_id
      order by cv.registration_ordinal desc
      limit 1
    ),
    'claim_verifications', (
      select coalesce(jsonb_agg(v order by v ->> 'sort_key' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'claim_verification_id', cv.id,
          'sort_key', lpad(cv.registration_ordinal::text, 20, '0'),
          'outcome', cv.outcome::text,
          'source_access', cv.source_access::text,
          'verified_at', cv.verified_at,
          'created_at', cv.created_at,
          'verifier_actor_id', cv.verifier_actor_id,
          'verifier_actor_key', va.actor_key,
          'verifier_actor_type', va.actor_type::text,
          'verifier_display_name', va.display_name,
          'agent_run_id', cv.agent_run_id,
          'verified_evidence_set_digest', cv.verified_evidence_set_digest,
          'checks', jsonb_build_object(
            'source_support', cv.source_support::text,
            'population_match', cv.population_match::text,
            'comparator_match', cv.comparator_match::text,
            'timeframe_match', cv.timeframe_match::text,
            'direction_and_magnitude', cv.direction_and_magnitude::text,
            'qualifiers_complete', cv.qualifiers_complete::text,
            'contradictory_evidence_represented', cv.contradictory_evidence_represented::text
          ),
          'findings', cv.findings,
          'rationale', cv.rationale,
          'citations', (
            select coalesce(jsonb_agg(
              jsonb_build_object(
                'claim_evidence_link_id', c.claim_evidence_link_id,
                'evidence_item_id', c.evidence_item_id,
                'source_access', c.source_access::text,
                'source_version_id', c.source_version_id,
                'checked_content_hash', c.checked_content_hash,
                'relationship_supported', c.relationship_supported::text,
                'finding', c.finding
              )
              order by c.claim_evidence_link_id::text
            ), '[]'::jsonb)
            from workflow.claim_verification_citations c
            where c.claim_verification_id = cv.id
          )
        ) as v
        from workflow.claim_verifications cv
        join provenance.actors va on va.id = cv.verifier_actor_id
        where cv.claim_revision_id = p_claim_revision_id
      ) as verifications
    ),
    'current_review_decision_id', (
      select rd.id
      from workflow.review_decisions rd
      where rd.claim_revision_id = p_claim_revision_id
        and rd.review_type = 'publication_approval'
      order by rd.decided_at desc, rd.created_at desc, rd.id desc
      limit 1
    ),
    'review_decisions', (
      select coalesce(jsonb_agg(d order by d ->> 'sort_key' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'review_decision_id', rd.id,
          'sort_key', to_char(rd.decided_at, 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|'
                      || to_char(rd.created_at, 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|'
                      || rd.id::text,
          'decision', rd.decision::text,
          'decided_at', rd.decided_at,
          'created_at', rd.created_at,
          'reviewer_actor_id', rd.reviewer_actor_id,
          'reviewer_actor_key', ra.actor_key,
          'reviewer_display_name', ra.display_name,
          'rationale', rd.rationale,
          'approved_evidence_set_digest', rd.approved_evidence_set_digest
        ) as d
        from workflow.review_decisions rd
        join provenance.actors ra on ra.id = rd.reviewer_actor_id
        where rd.claim_revision_id = p_claim_revision_id
          and rd.review_type = 'publication_approval'
      ) as decisions
    ),
    'evidence_assessment', (
      select jsonb_build_object(
        'evidence_assessment_id', a.id,
        'framework', a.framework::text,
        'certainty_level', a.certainty_level::text,
        'risk_of_bias', a.risk_of_bias::text,
        'inconsistency', a.inconsistency::text,
        'indirectness', a.indirectness::text,
        'imprecision', a.imprecision::text,
        'publication_bias', a.publication_bias::text,
        'other_considerations', a.other_considerations,
        'rationale', a.rationale,
        'evidence_gap', a.evidence_gap,
        'assessed_at', a.assessed_at
      )
      from knowledge.evidence_assessments a
      where a.claim_revision_id = p_claim_revision_id
    )
  );
$$;

create or replace function api.claim_review_workspace(p_claim_revision_id uuid default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_reviewer_actor_id uuid;
  v_dossier jsonb;
  v_topic_concept_id uuid;
  v_gate jsonb;
  v_readiness jsonb;
  v_state text;
  v_message text;
  v_hint text;
  v_queue jsonb;
begin
  -- Kalleren må være reviewer i det hele tatt. Avvisningen kommer fra
  -- workflow.assert_reviewer_authorized(uuid) og navngir hvilket krav som
  -- sviktet; uten et begrep godtas enhver gyldig tildeling, avgrenset eller ikke.
  v_reviewer_actor_id := workflow.assert_reviewer_authorized(null);

  if p_claim_revision_id is null then
    select coalesce(jsonb_agg(item order by item ->> 'created_at'), '[]'::jsonb)
    into v_queue
    from (
      select jsonb_build_object(
        'claim_revision_id', r.id,
        'claim_id', r.claim_id,
        'revision_number', r.revision_number,
        'knowledge_type', r.knowledge_type::text,
        'created_at', r.created_at,
        'created_by_actor_id', r.created_by_actor_id,
        'created_by_actor_key', author.actor_key,
        'statement', r.statement,
        'subject_drug_name', subject.canonical_name,
        'topic_label', topic.canonical_label,
        'topic_concept_id', cl.topic_concept_id,
        'evidence_link_count', (
          select count(*)
          from knowledge.claim_evidence_links l
          where l.claim_revision_id = r.id
        ),
        -- coalesce, ikke en naken sammenligning: uten en publisert revisjon er
        -- current_published_revision_id NULL, og NULL = uuid er ukjent — ikke
        -- usant. En klient som leste den ukjente verdien som «kanskje publisert»
        -- ville sagt noe annet enn «ikke publisert» (ANTIDEP_CONSTITUTION.md §17).
        'is_published_revision', coalesce(cl.current_published_revision_id = r.id, false),
        'current_claim_verification_outcome', (
          select cv.outcome::text
          from workflow.claim_verifications cv
          where cv.claim_revision_id = r.id
          order by cv.registration_ordinal desc
          limit 1
        ),
        'current_publication_decision', (
          select rd.decision::text
          from workflow.review_decisions rd
          where rd.claim_revision_id = r.id
            and rd.review_type = 'publication_approval'
          order by rd.decided_at desc, rd.created_at desc, rd.id desc
          limit 1
        )
      ) as item
      from knowledge.claim_revisions r
      join knowledge.claims cl on cl.id = r.claim_id
      join provenance.actors author on author.id = r.created_by_actor_id
      join catalog.drugs subject on subject.id = cl.subject_drug_id
      join catalog.clinical_concepts topic on topic.id = cl.topic_concept_id
      where
        -- Radgrensen: en avgrenset reviewer-tildeling ser bare sitt eget
        -- innholdsområde. En uavgrenset ser alt.
        workflow.caller_is_active_reviewer(cl.topic_concept_id)
        -- Påstanden er ikke trukket tilbake.
        and cl.retired_at is null
        -- Revisjoner kalleren selv har formulert er utelatt: hen kan verken
        -- kontrollere dem (claim_verifications_separate_actor_check) eller
        -- godkjenne dem (review_decisions_separate_actor_check), så å ha dem i
        -- køen ville vært å be om et kall som må avvises. De er fortsatt
        -- adresserbare direkte, og flaten sier da hvorfor de ikke kan behandles.
        and r.created_by_actor_id <> v_reviewer_actor_id
        -- En kontroll av en påstand er en kontroll mot et grunnlag. Uten en
        -- eneste evidenslenke finnes det ikke noe å kontrollere mot, og både
        -- dekningskontrollen og publiseringsgatens G3 ville avvist.
        and exists (
          select 1
          from knowledge.claim_evidence_links l
          where l.claim_revision_id = r.id
        )
    ) as queue;

    return jsonb_build_object(
      'reviewer_actor_id', v_reviewer_actor_id,
      'queue', v_queue
    );
  end if;

  v_dossier := workflow.claim_evidence_dossier(p_claim_revision_id);

  if v_dossier is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstandsrevisjonen %L finnes ikke.', p_claim_revision_id),
      hint = 'Review peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  v_topic_concept_id := (v_dossier ->> 'topic_concept_id')::uuid;

  -- En avgrenset reviewer-tildeling gir ikke innsyn utenfor sitt eget
  -- innholdsområde, heller ikke ved direkte oppslag. Avvisningen er den samme
  -- som skriveveien ville gitt.
  perform workflow.assert_reviewer_authorized(v_topic_concept_id);

  -- Forutsetningene før godkjenningen, lest av den samme funksjonen skriveveien
  -- krever (migrasjon 006e). Den er ikke utledbar av `publication_gate`: gaten
  -- stopper på det første vilkåret som svikter, og rett før en godkjenning er
  -- det alltid G11 — «ikke godkjent av en kvalifisert redaktør». En flate som
  -- leste gaten alene, kunne derfor ikke skille «mangler bare godkjenningen» fra
  -- «grunnlaget er ikke kontrollert ennå», og ville tilbudt revieweren en
  -- handling databasen kommer til å avvise.
  --
  -- Samme smale fangst og samme begrunnelse som under: bare gatens egen
  -- avvisningskode blir til `blocked`, alt annet propagerer.
  begin
    perform knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id);
    v_readiness := jsonb_build_object('status', 'passes');
  exception
    when restrict_violation then
      get stacked diagnostics
        v_state = returned_sqlstate,
        v_message = message_text,
        v_hint = pg_exception_hint;
      v_readiness := jsonb_build_object(
        'status', 'blocked',
        'sqlstate', v_state,
        'message', v_message,
        'hint', v_hint
      );
  end;

  -- Publiseringsgaten leses av gaten selv. Den stopper på det første vilkåret
  -- som svikter, så svaret navngir én blokkering om gangen.
  --
  -- Bare `restrict_violation` fanges, og det er hele poenget (migrasjon 005p):
  -- det er koden gaten avviser med på hvert eneste av sine vilkår. Enhver annen
  -- feil — en regresjon i gaten, et manglende objekt, en rettighetsfeil — er en
  -- teknisk feil og propagerer, slik at hele kallet feiler og klienten viser det
  -- som en feil. En teknisk feil som ble gjengitt som «publiseringen er
  -- blokkert», ville skjult seg som en innholdsmangel på nøyaktig den flaten som
  -- skal være fasit for om innholdet er klart.
  begin
    perform knowledge.assert_claim_revision_publishable(p_claim_revision_id);
    v_gate := jsonb_build_object('status', 'passes');
  exception
    when restrict_violation then
      get stacked diagnostics
        v_state = returned_sqlstate,
        v_message = message_text,
        v_hint = pg_exception_hint;
      v_gate := jsonb_build_object(
        'status', 'blocked',
        'sqlstate', v_state,
        'message', v_message,
        'hint', v_hint
      );
  end;

  return jsonb_build_object(
    'reviewer_actor_id', v_reviewer_actor_id,
    'revision', v_dossier
      || workflow.claim_review_history(p_claim_revision_id)
      || jsonb_build_object(
           'is_published_revision', (
             select coalesce(cl.current_published_revision_id = p_claim_revision_id, false)
             from knowledge.claim_revisions r
             join knowledge.claims cl on cl.id = r.claim_id
             where r.id = p_claim_revision_id
           ),
           'publication_gate', v_gate,
           'approval_readiness', v_readiness
         )
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. Kommentarene som navngir rekkefølgen
-- ----------------------------------------------------------------------------
comment on function workflow.covered_check_fields(uuid) is
  'Feltene funnets registrerte kontroller til sammen har gått gjennom og funnet i orden. Unionen over kontroller med utfallet verified eller uncertain: en uavklart kontroll motsier ingenting, og feltene den førte opp i checked_fields, gikk den faktisk gjennom — det er nettopp arbeidsdelingen mellom den deterministiske kontrollen, som beviser provenansfeltene, og mennesket, som bedømmer de semantiske. En kontroll som fant et avvik (needs_correction, rejected) nullstiller derimot dekningen fra alt som ligger foran den: en tidligere bekreftelse opphever ikke et senere avvik. «Foran» og «senere» avgjøres av registration_ordinal, databasens egen registreringsrekkefølge, og ikke av verified_at: now() er transaksjonens starttidspunkt, og et avvik som ble skrevet sist kunne ellers båret det eldste tidsstempelet og forsvunnet bak en bekreftelse (migrasjon 005å). At noen faktisk konkluderte, er G5 sin oppgave, ikke denne funksjonens: gaten krever at den *siste* kontrollen er verified. Leses av publiseringsgatens G5b og av reviewerflaten, som viser nøyaktig det samme settet.';

comment on function workflow.grounding_machine_proved(uuid) is
  'Om det finnes et *gjeldende* maskinbevis for venstresiden: en maskinell ekstraksjonskontroll som gjelder nøyaktig det grunnlaget evidensfunnet har nå, som beviste at representasjonen lot seg reprodusere, at forankringen er komplett og at hvert forankret utdrag står ordrett i den — og som ingen har underkjent siden. Kravene er en agentkjøring (ev.agent_run_id, som de sammensatte fremmednøklene binder til rollen extraction_verification), et verified_grounding_digest lik det gjeldende, et utfall som ikke er et avvik, source_locator i checked_fields, og at ingen senere kontroll på det samme funnet endte i needs_correction eller rejected. Det siste kom til i migrasjon 005ø: uten det overlevde et gammelt bevis et nyere avvik, og den menneskelige feltkontrollen åpnet fortsatt. «Senere» avgjøres av registration_ordinal fra migrasjon 005å — registreringsrekkefølgen, ikke veggklokketid, som ville latt et avvik skrevet sist bære det eldste tidsstempelet. Regelen er ordrett den samme som workflow.covered_check_fields(uuid) bruker, og av samme grunn — en tidligere bekreftelse opphever ikke et senere avvik. source_locator er beviset uttrykt i et vokabular som allerede finnes: src/agents/extraction-checks.ts fører opp feltet bare under nøyaktig de tre vilkårene. Leses av skriveveien workflow.record_evidence_verification, som avviser en menneskelig bekreftelse uten den, og av grunnlagsflaten, som stopper kontrolløkten før feltskuffene når beviset mangler (ANTIDEP_CONSTITUTION.md §11, §17).';

comment on function workflow.evidence_verification_history(uuid) is
  'Kontrollene som allerede er registrert på ett evidensfunn: hver ekstraksjonsverifikasjon med sitt utfall, sin kildetilgang, feltene den faktisk gikk gjennom, funnene og begrunnelsen (DATABASE_ARCHITECTURE.md §29). Ingenting filtreres bort: en tidligere bekreftelse som et senere avvik har underkjent, står fortsatt der, fordi begge er utførte observasjoner og tabellen er append-only. current_extraction_verification_id peker på den raden publiseringsgatens G5 leser som den gjeldende, hentet med nøyaktig den samme rekkefølgen (registration_ordinal desc, databasens egen registreringsrekkefølge fra migrasjon 005å), slik at flaten og gaten ikke kan bli uenige. agent_run_id er NULL for en menneskelig kontroll. sort_key er en intern sorteringsnøkkel og ikke en opplysning om objektet; den er den samme rekkefølgen, tekstlig utfylt slik at den sorterer likt. SECURITY DEFINER fordi workflow og provenance har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

comment on function workflow.claim_review_history(uuid) is
  'Beslutningene som allerede er registrert om én påstandsrevisjon: hver claim-verifikasjon med sine sju kontrollpunkter og sine kontrollrader per evidenslenke, hver publiseringsgodkjenning med sin begrunnelse og sitt evidenssettavtrykk, og evidensvurderingen med GRADE-domenene (DATABASE_ARCHITECTURE.md §30, §31, ANTIDEP_CONSTITUTION.md §6, §12). Ingenting filtreres bort: en tidligere avvisning som senere er omgjort, står fortsatt der, fordi både beslutningen og omgjøringen skal bevares. current_claim_verification_id og current_review_decision_id peker på den raden publiseringsgaten leser som den gjeldende, hentet med nøyaktig den samme rekkefølgen som gaten (registration_ordinal desc for claim-verifikasjonen, fra migrasjon 005å; decided_at desc, created_at desc, id desc for beslutningen), slik at flaten og gaten ikke kan bli uenige. evidence_assessment er NULL når ingen vurdering er registrert — ikke når grunnlaget er vurdert som svakt; «ingen vurderbar evidens» er en registrert verdi (§6, §17). sort_key er en intern sorteringsnøkkel og ikke en opplysning om objektet. SECURITY DEFINER fordi workflow og knowledge har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';
