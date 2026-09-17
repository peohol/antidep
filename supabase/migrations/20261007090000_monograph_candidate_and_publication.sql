-- ============================================================================
-- Migrasjon 013j — det samlede monografiutkastet, sluttkontrollen og
--                  publiseringen
--
-- Monografien er en versjonert visning over kildebelagte kunnskapsobjekter, og
-- ikke et stort frittstående tekstdokument (MONOGRAPH_STANDARD.md §1). Utkastet
-- bygges derfor av de strukturerte svarene — ikke av en liste over agentjobber,
-- og ikke av enkeltpåstander uten spørsmålet de svarer på.
--
-- ----------------------------------------------------------------------------
-- Hvorfor kandidaten fryses
--
-- Fordi sluttkontrollen skal gjelde nøyaktig den utgaven som ble lest. En
-- kontroll av «monografien slik den er nå» ville vært en kontroll av noe som
-- kan ha endret seg i mellomtiden, og publiseringen ville tatt i bruk et annet
-- innhold enn det som ble vurdert (ANTIDEP_CONSTITUTION.md regel 5).
--
-- Kandidaten bærer derfor hele den leselige visningen, dekningsoversikten,
-- standardversjonen og de eksakte svarrevisjonene den er bygget av — og et
-- avtrykk av alt sammen. Sluttkontrollen er bundet til avtrykket gjennom en
-- sammensatt fremmednøkkel, ikke gjennom en konvensjon.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en foreldet kandidat ikke kan publiseres
--
-- Fordi det ville tatt i bruk et innhold som ikke lenger er monografiens. Er
-- grunnlaget endret etter kontrollen, skal det bygges en ny kandidat og
-- kontrolleres på nytt: det er én ekstra handling for et menneske, og
-- alternativet er å publisere noe ingen har sett.
--
-- ----------------------------------------------------------------------------
-- Hva som *ikke* ligger her
--
-- Ingen offentlig lesevei. Monografivisningen krever redaktørmandat, og den
-- bærer ordrette kildeutdrag fra private originaldokumenter. En offentlig
-- lesevei ville krevd en egen, rettighetsavklart løsning for hvilke utdrag som
-- kan vises — og den avgjørelsen hører ikke hjemme i en kodeleveranse.
-- Publiseringshendelsen registrerer at en utgave er tatt i bruk; den åpner
-- ingen ny lesevei.
--
-- Styrende dokumenter: docs/MONOGRAPH_STANDARD.md §1, §2, §5.4,
-- docs/CONTENT_GOVERNANCE.md, docs/ANTIDEP_CONSTITUTION.md regel 4, 5, 6.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Den leselige monografien, bygget av svarene
-- ----------------------------------------------------------------------------

create function knowledge.monograph_draft_payload(
  p_edition knowledge.monograph_editions,
  p_with_quotes boolean)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select jsonb_build_object(
    'edition', jsonb_build_object(
      'reference', p_edition.reference,
      'drug', (select d.canonical_name from catalog.drugs d where d.id = p_edition.drug_id),
      'standard_version', p_edition.standard_version,
      'edition_no', p_edition.edition_no,
      'ordered_at', p_edition.ordered_at),
    'sections', coalesce((
      select jsonb_agg(seksjon order by seksjon ->> 'ordinal')
      from (
        select jsonb_build_object(
                 'ordinal', lpad(min(t.ordinal)::text, 4, '0'),
                 'section', t.section,
                 'entries', jsonb_agg(
                   jsonb_build_object(
                     'need_reference', n.reference,
                     'template_code', t.code,
                     'question', t.prompt,
                     'requirement', t.requirement::text,
                     'answer_form', n.answer_form::text,
                     'scope', knowledge.monograph_need_scope_label(n.id),
                     -- De seks dimensjonene holdes atskilt, fordi de betyr
                     -- forskjellige ting: en ubesvart relevans er ikke «ikke
                     -- relevant», og en manglende tilgang er ikke
                     -- «utilstrekkelig evidens» (MONOGRAPH_STANDARD.md §2).
                     'relevance', n.relevance::text,
                     'relevance_reason', n.relevance_reason,
                     'work_state', n.work_state::text,
                     'work_state_note', n.work_state_note,
                     'outcome', n.outcome::text,
                     'answer', case when r.id is null then null else
                       jsonb_strip_nulls(jsonb_build_object(
                         'revision_reference', r.reference,
                         'revision_number', r.revision_number,
                         'knowledge_type', r.knowledge_type::text,
                         'origin', r.origin::text,
                         'statement', r.statement,
                         'structured_value', r.structured_value,
                         'uncertainty_summary', r.uncertainty_summary,
                         'limitation_note', r.limitation_note,
                         'as_of', r.as_of,
                         'recommending_body', r.recommending_body,
                         'recommendation_date', r.recommendation_date,
                         -- Aktualiteten og evidenssikkerheten leses av det
                         -- grunnlaget svaret hviler på, og skrives ikke om.
                         'certainty', (
                           select a.certainty_level::text
                           from knowledge.evidence_assessments a
                           where a.claim_revision_id = r.claim_revision_id),
                         'certainty_framework', (
                           select a.framework::text
                           from knowledge.evidence_assessments a
                           where a.claim_revision_id = r.claim_revision_id),
                         'sources', (
                           select coalesce(jsonb_agg(kilde order by kilde ->> 'title'), '[]'::jsonb)
                           from (
                             select jsonb_strip_nulls(jsonb_build_object(
                                      'title', s.title,
                                      'authors_or_issuer', s.authors_or_issuer,
                                      'publisher_or_journal', s.publisher_or_journal,
                                      'publication_date', s.publication_date,
                                      'retrieved_at', sv.retrieved_at,
                                      'retrieved_from', sv.retrieved_from,
                                      'representation', sv.representation::text,
                                      'locator', c.source_locator,
                                      'as_of', c.as_of,
                                      -- Det ordrette utdraget er et internt
                                      -- utdrag fra et privat originaldokument.
                                      -- Det følger bare med til den redaksjonelle
                                      -- visningen.
                                      'quote', case when p_with_quotes then c.source_quote end
                                    )) as kilde
                             from (
                               select r.source_version_id, r.source_locator,
                                      r.as_of, r.source_quote
                               where r.source_version_id is not null
                               union all
                               select x.source_version_id, x.source_locator,
                                      x.as_of, x.source_quote
                               from knowledge.monograph_answer_revision_sources x
                               where x.answer_revision_id = r.id
                             ) c
                             join knowledge.source_versions sv on sv.id = c.source_version_id
                             join knowledge.sources s on s.id = sv.source_id
                           ) kilder),
                         'evidence_sources', (
                           select coalesce(jsonb_agg(distinct jsonb_build_object(
                                    'title', s.title,
                                    'authors_or_issuer', s.authors_or_issuer,
                                    'publication_date', s.publication_date)), '[]'::jsonb)
                           from knowledge.claim_evidence_links l
                           join knowledge.evidence_items e on e.id = l.evidence_item_id
                           join knowledge.sources s on s.id = e.source_id
                           where l.claim_revision_id = r.claim_revision_id),
                         'controlled_fields', (
                           select to_jsonb(v.checked_fields::text[])
                           from workflow.monograph_answer_verifications v
                           where v.answer_revision_id = r.id)))
                     end)
                   order by t.ordinal, n.reference)) as seksjon
        from knowledge.monograph_needs n
        join knowledge.monograph_question_templates t on t.id = n.template_id
        left join knowledge.monograph_answers a on a.need_id = n.id
        left join knowledge.monograph_answer_revisions r on r.id = a.current_revision_id
        where n.edition_id = p_edition.id
        group by t.section
      ) seksjoner), '[]'::jsonb),
    'coverage', knowledge.monograph_coverage_payload(p_edition));
$$;

comment on function knowledge.monograph_draft_payload(knowledge.monograph_editions, boolean) is
  'Hele monografien som én lesbar visning, bygget av de strukturerte svarene og ikke av en liste over agentjobber. Relevans, arbeidstilstand, faglig utfall, evidenssikkerhet, aktualitet og kontrollstatus står som seks atskilte opplysninger, fordi de betyr forskjellige ting: en ubesvart relevans er ikke «ikke relevant», og en manglende tilgang er ikke «utilstrekkelig evidens» (MONOGRAPH_STANDARD.md §2). Ordrette kildeutdrag er interne utdrag fra private originaldokumenter og følger bare med når kalleren uttrykkelig ber om dem for den redaksjonelle visningen.';

revoke execute on function knowledge.monograph_draft_payload(knowledge.monograph_editions, boolean) from public;

-- ----------------------------------------------------------------------------
-- 2. Den frosne kandidaten
-- ----------------------------------------------------------------------------

create table knowledge.monograph_edition_candidates (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  edition_id uuid not null
    references knowledge.monograph_editions (id) on update restrict on delete restrict,
  candidate_no integer not null,

  -- Standardversjonen utgaven ble bygget av. En ny standardversjon skal ikke
  -- stille endre spørsmålet under et godkjent innhold.
  standard_version text not null,

  -- De eksakte svarrevisjonene kandidaten er bygget av. Ikke svarene, og ikke
  -- behovene: revisjonene, fordi det er de som er uforanderlige.
  answer_revision_ids uuid[] not null,

  -- Hele den leselige visningen og dekningsoversikten, frosset. Sluttkontrollen
  -- gjelder nøyaktig dette.
  content jsonb not null,
  coverage jsonb not null,
  content_hash text not null,

  built_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  built_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint monograph_edition_candidates_reference_key unique (reference),
  constraint monograph_edition_candidates_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_edition_candidates_no_key unique (edition_id, candidate_no),
  constraint monograph_edition_candidates_no_check check (candidate_no >= 1),
  constraint monograph_edition_candidates_hash_shape_check
    check (content_hash ~ '^sha256:[0-9a-f]{64}$'),
  constraint monograph_edition_candidates_content_shape_check
    check (jsonb_typeof(content) = 'object' and jsonb_typeof(coverage) = 'object'),
  -- Avtrykket er av innholdet, dekningen, standardversjonen og de bundne
  -- svarrevisjonene. Uten det ville «den utgaven som ble kontrollert» vært en
  -- påstand framfor noe som kan regnes ut på nytt.
  constraint monograph_edition_candidates_hash_is_the_content_check
    check (content_hash = 'sha256:' || encode(
      sha256(convert_to(
        content::text || '|' || coverage::text || '|' || standard_version || '|'
        || array_to_string(answer_revision_ids, ','), 'UTF8')), 'hex')),
  -- Sluttkontrollen bindes til nøyaktig denne utgaven av innholdet.
  constraint monograph_edition_candidates_binding_key unique (id, content_hash)
);

comment on table knowledge.monograph_edition_candidates is
  'Én frosset, samlet monografiutgave: hele den leselige visningen, dekningsoversikten, standardversjonen og de eksakte svarrevisjonene den er bygget av — med et avtrykk av alt sammen. Frosset fordi sluttkontrollen skal gjelde nøyaktig den utgaven som ble lest: en kontroll av «monografien slik den er nå» ville vært en kontroll av noe som kan ha endret seg, og publiseringen ville tatt i bruk et annet innhold enn det som ble vurdert (ANTIDEP_CONSTITUTION.md regel 5). En påstandskandidat (knowledge.candidates) er ikke automatisk en monografikandidat: dette er et eget objekt med sin egen kontroll og sin egen publisering.';
comment on column knowledge.monograph_edition_candidates.answer_revision_ids is
  'De eksakte svarrevisjonene kandidaten er bygget av — ikke svarene, og ikke behovene, fordi det er revisjonene som er uforanderlige. Listen er det som gjør at «er kandidaten fortsatt monografien?» kan besvares uten å gjette.';

alter table knowledge.monograph_edition_candidates enable row level security;

create index monograph_edition_candidates_edition_idx
  on knowledge.monograph_edition_candidates (edition_id, candidate_no desc);

create trigger monograph_edition_candidates_set_created_at
  before insert or update on knowledge.monograph_edition_candidates
  for each row execute function catalog.set_created_at();

create trigger monograph_edition_candidates_are_append_only
  before update or delete on knowledge.monograph_edition_candidates
  for each row execute function knowledge.reject_append_only_mutation(
    'En monografikandidat er den utgaven et menneske faktisk leste. Bygg en ny kandidat framfor å skrive om den gamle; den nye får sitt eget avtrykk, fordi den er et annet innhold.');

-- Og pekeren på hva som er i bruk.
alter table knowledge.monograph_editions
  add column current_published_candidate_id uuid
    references knowledge.monograph_edition_candidates (id)
    on update restrict on delete restrict;

comment on column knowledge.monograph_editions.current_published_candidate_id is
  'Den monografikandidaten som er i bruk nå, eller NULL. Peker på en frosset utgave og ikke på «det siste»: det som er publisert, er nøyaktig det som ble kontrollert og autorisert.';

-- ----------------------------------------------------------------------------
-- 3. Er kandidaten fortsatt monografien?
-- ----------------------------------------------------------------------------

create function knowledge.monograph_candidate_staleness(p_candidate_id uuid)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_candidate knowledge.monograph_edition_candidates;
  v_changed integer;
  v_added integer;
  v_version text;
begin
  select c.* into v_candidate
  from knowledge.monograph_edition_candidates c
  where c.id = p_candidate_id;

  if not found then
    return 'Kandidaten finnes ikke.';
  end if;

  -- Et svar som har fått en ny revisjon etter at kandidaten ble bygget.
  select count(*)::integer into v_changed
  from knowledge.monograph_answers a
  join knowledge.monograph_needs n on n.id = a.need_id
  where n.edition_id = v_candidate.edition_id
    and a.current_revision_id is not null
    and not (a.current_revision_id = any (v_candidate.answer_revision_ids));

  if v_changed > 0 then
    return format(
      '%s svar har fått en ny revisjon etter at kandidaten ble bygget.', v_changed);
  end if;

  -- Et svar som er kommet til etter at kandidaten ble bygget, teller også: en
  -- monografi som mangler et svar den nå har, er ikke den monografien.
  select count(*)::integer into v_added
  from unnest(v_candidate.answer_revision_ids) as g(id)
  where not exists (
    select 1 from knowledge.monograph_answers a where a.current_revision_id = g.id);

  if v_added > 0 then
    return format(
      '%s av kandidatens svarrevisjoner er ikke lenger gjeldende.', v_added);
  end if;

  -- Og standardversjonen: en ny versjon skal ikke stille endre spørsmålet under
  -- et godkjent innhold (MONOGRAPH_STANDARD.md §2).
  select e.standard_version into v_version
  from knowledge.monograph_editions e where e.id = v_candidate.edition_id;

  if v_version is distinct from v_candidate.standard_version then
    return format('Utgaven er nå bygget av standardversjon %s, og kandidaten av %s.',
                  v_version, v_candidate.standard_version);
  end if;

  return null;
end;
$$;

comment on function knowledge.monograph_candidate_staleness(uuid) is
  'Hvorfor en frosset monografikandidat ikke lenger er den gjeldende monografien, eller NULL når den er det. Finnes fordi et menneske skal kunne se forskjell på «dette er monografien» og «dette var monografien da jeg leste den» — og fordi publiseringen nekter å ta i bruk en utgave grunnlaget har forlatt.';

revoke execute on function knowledge.monograph_candidate_staleness(uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Byggingen av kandidaten
-- ----------------------------------------------------------------------------

create function knowledge.build_monograph_edition_candidate(
  p_edition_id uuid,
  p_actor_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_edition knowledge.monograph_editions;
  v_content jsonb;
  v_coverage jsonb;
  v_ids uuid[];
  v_hash text;
  v_existing knowledge.monograph_edition_candidates;
  v_no integer;
  v_id uuid;
begin
  -- Utgaven låses først. To samtidige byggeforsøk skal bli én kandidat, ikke to
  -- med samme nummer.
  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.id = p_edition_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Monografiutgaven finnes ikke.';
  end if;

  if v_edition.superseded_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'En avløst monografiutgave bygges ikke om til en ny kandidat.',
      hint = 'Utgaven er historikk, og den er det en godkjent monografi ble bygget av.';
  end if;

  select coalesce(array_agg(a.current_revision_id order by a.current_revision_id), array[]::uuid[])
    into v_ids
  from knowledge.monograph_answers a
  join knowledge.monograph_needs n on n.id = a.need_id
  where n.edition_id = p_edition_id
    and a.current_revision_id is not null;

  if cardinality(v_ids) = 0 then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Utgaven har ingen kontrollerte svar å bygge en kandidat av.',
      hint = 'Et dekningskart er ikke en monografikandidat. Kandidaten bygges av de strukturerte svarene, og uten ett eneste svar ville den vært en tom utgave med en dekningsoversikt (MONOGRAPH_STANDARD.md §5.4).';
  end if;

  -- Uten utdragene. Kandidaten er utgaven som kan kontrolleres og publiseres,
  -- og et ordrett utdrag fra et privat originaldokument hører ikke til i et
  -- objekt som kan bli lest videre. Utdragene står i den redaksjonelle
  -- visningen, og kilden og lokaliseringen følger med her.
  v_content := knowledge.monograph_draft_payload(v_edition, false);
  v_coverage := knowledge.monograph_coverage_payload(v_edition);

  v_hash := 'sha256:' || encode(
    sha256(convert_to(
      v_content::text || '|' || v_coverage::text || '|' || v_edition.standard_version
      || '|' || array_to_string(v_ids, ','), 'UTF8')), 'hex');

  -- Den samme utgaven bygget to ganger er én kandidat. Uten dette ville hver
  -- åpning av flaten laget en ny kandidat, og sluttkontrollen ville pekt på en
  -- av mange like.
  select c.* into v_existing
  from knowledge.monograph_edition_candidates c
  where c.edition_id = p_edition_id and c.content_hash = v_hash;

  if found then
    return v_existing.id;
  end if;

  select coalesce(max(c.candidate_no), 0) + 1 into v_no
  from knowledge.monograph_edition_candidates c
  where c.edition_id = p_edition_id;

  insert into knowledge.monograph_edition_candidates (
    edition_id, candidate_no, standard_version, answer_revision_ids,
    content, coverage, content_hash, built_by_actor_id
  )
  values (
    p_edition_id, v_no, v_edition.standard_version, v_ids,
    v_content, v_coverage, v_hash, p_actor_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

comment on function knowledge.build_monograph_edition_candidate(uuid, uuid) is
  'Fryser den gjeldende monografien til én kandidat: hele den leselige visningen uten de private kildeutdragene, dekningsoversikten, standardversjonen og de eksakte svarrevisjonene. Den samme utgaven bygget to ganger er én kandidat, fordi avtrykket er det samme — uten det ville hver åpning av flaten laget en ny, og sluttkontrollen ville pekt på en av mange like. En utgave uten ett eneste kontrollert svar avvises: et dekningskart er ikke en monografikandidat (MONOGRAPH_STANDARD.md §5.4).';

revoke execute on function knowledge.build_monograph_edition_candidate(uuid, uuid) from public;

create function audit.record_monograph_candidate_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason, occurred_at
  )
  values (
    'monograph_candidate_built'::audit.event_operation,
    new.id, new.built_by_actor_id, null,
    -- Uten selve innholdet: sporet skal si at utgaven ble bygget og av hva,
    -- ikke bære en kopi av hele monografien i hver rad.
    to_jsonb(new) - 'content' - 'coverage',
    format('Monografikandidat %s for utgaven, bygget av %s svarrevisjoner.',
           new.candidate_no, cardinality(new.answer_revision_ids)),
    new.built_at
  );
  return null;
end;
$$;

revoke execute on function audit.record_monograph_candidate_event() from public;

create trigger monograph_edition_candidates_record_audit_event
  after insert on knowledge.monograph_edition_candidates
  for each row execute function audit.record_monograph_candidate_event();

-- ----------------------------------------------------------------------------
-- 5. Sluttkontrollen
--
-- Navngitt og menneskelig. Ingen agent skal kunne attestere at et menneske har
-- vurdert innhold, og kravet er strukturelt: aktørtypen står i raden, og en
-- CHECK avviser alt annet enn et menneske.
-- ----------------------------------------------------------------------------

create table workflow.monograph_final_controls (
  id uuid primary key default gen_random_uuid(),

  candidate_id uuid not null,
  -- Avtrykket av nøyaktig den utgaven som ble lest. Den sammensatte
  -- fremmednøkkelen gjør bindingen til en regel og ikke en konvensjon.
  candidate_digest text not null,

  decision workflow.final_control_decision not null,
  rationale text not null,

  reviewer_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  reviewer_actor_type provenance.actor_type not null,
  decided_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint monograph_final_controls_candidate_fkey
    foreign key (candidate_id, candidate_digest)
    references knowledge.monograph_edition_candidates (id, content_hash)
    on update restrict on delete restrict,
  constraint monograph_final_controls_binding_key
    unique (id, candidate_id, candidate_digest, decision),
  constraint monograph_final_controls_reviewer_is_human_check
    check (reviewer_actor_type = 'human'::provenance.actor_type),
  constraint monograph_final_controls_rationale_shape_check
    check (rationale = btrim(rationale) and length(rationale) between 1 and 8000)
);

comment on table workflow.monograph_final_controls is
  'Den navngitte menneskelige sluttkontrollen av én frosset monografikandidat. Bundet til avtrykket av nøyaktig den utgaven som ble lest, gjennom en sammensatt fremmednøkkel: uten den ville «godkjent» kunnet gjelde et annet innhold enn det som faktisk ble vurdert. Aktørtypen står i raden, og en CHECK avviser alt annet enn et menneske — ingen agent skal kunne attestere at et menneske har vurdert innhold (ANTIDEP_CONSTITUTION.md regel 6).';

alter table workflow.monograph_final_controls enable row level security;

create index monograph_final_controls_candidate_idx
  on workflow.monograph_final_controls (candidate_id, decided_at desc);

create trigger monograph_final_controls_set_created_at
  before insert or update on workflow.monograph_final_controls
  for each row execute function catalog.set_created_at();

create trigger monograph_final_controls_are_append_only
  before update or delete on workflow.monograph_final_controls
  for each row execute function knowledge.reject_append_only_mutation();

create function workflow.current_monograph_final_control(p_candidate_id uuid)
  returns workflow.monograph_final_controls
  language sql
  stable
  set search_path = ''
as $$
  select c.*
  from workflow.monograph_final_controls c
  where c.candidate_id = p_candidate_id
  order by c.decided_at desc, c.created_at desc, c.id desc
  limit 1;
$$;

comment on function workflow.current_monograph_final_control(uuid) is
  'Den gjeldende sluttkontrollen av én monografikandidat: den siste. En senere avvisning opphever en tidligere godkjenning, og porten skal lese det som gjelder nå (ANTIDEP_CONSTITUTION.md regel 4).';

revoke execute on function workflow.current_monograph_final_control(uuid) from public;

create function audit.record_monograph_final_control_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason, occurred_at
  )
  values (
    'monograph_final_control_recorded'::audit.event_operation,
    new.id, new.reviewer_actor_id, null, to_jsonb(new),
    new.rationale, new.decided_at
  );
  return null;
end;
$$;

revoke execute on function audit.record_monograph_final_control_event() from public;

create trigger monograph_final_controls_record_audit_event
  after insert on workflow.monograph_final_controls
  for each row execute function audit.record_monograph_final_control_event();

-- ----------------------------------------------------------------------------
-- 6. Publiseringen
--
-- En egen, autorisert handling. Å godkjenne og å publisere er to forskjellige
-- ting, og de krever to forskjellige mandater.
-- ----------------------------------------------------------------------------

create type knowledge.monograph_publication_action as enum (
  'published', 'withdrawn', 'replaced'
);

revoke usage on type knowledge.monograph_publication_action from public;

comment on type knowledge.monograph_publication_action is
  'Hva som skjedde med en publisert monografiutgave: published (tatt i bruk), replaced (avløst av en nyere kandidat) eller withdrawn (trukket tilbake). Historikken er append-only, så en tilbaketrekking sletter ingenting — den sier at utgaven ikke lenger er i bruk, og hvorfor.';

create table knowledge.monograph_publication_events (
  id uuid primary key default gen_random_uuid(),

  edition_id uuid not null
    references knowledge.monograph_editions (id) on update restrict on delete restrict,
  candidate_id uuid not null
    references knowledge.monograph_edition_candidates (id)
    on update restrict on delete restrict,
  -- Sluttkontrollen publiseringen hviler på. Uten den kunne en utgave blitt
  -- publisert uten at noen hadde lest den.
  final_control_id uuid not null,
  final_control_candidate_id uuid not null,
  final_control_digest text not null,
  final_control_decision workflow.final_control_decision not null,

  action knowledge.monograph_publication_action not null,
  reason text not null,
  actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint monograph_publication_events_control_fkey
    foreign key (final_control_id, final_control_candidate_id,
                 final_control_digest, final_control_decision)
    references workflow.monograph_final_controls
      (id, candidate_id, candidate_digest, decision)
    on update restrict on delete restrict,
  -- Kontrollen må gjelde nøyaktig den kandidaten som publiseres, og den må ha
  -- godkjent den. En avvist eller en fremmed kontroll er ikke en godkjenning.
  constraint monograph_publication_events_control_matches_check
    check (final_control_candidate_id = candidate_id),
  constraint monograph_publication_events_control_approved_check
    check (final_control_decision = 'approved'::workflow.final_control_decision),
  constraint monograph_publication_events_reason_shape_check
    check (reason = btrim(reason) and length(reason) between 1 and 2000)
);

comment on table knowledge.monograph_publication_events is
  'Hva som er gjort med en monografiutgave, append-only. Hver rad bærer sluttkontrollen publiseringen hviler på, gjennom en sammensatt fremmednøkkel som krever at kontrollen gjelder nøyaktig den kandidaten og at den er en godkjenning. Uten den bindingen kunne en utgave blitt publisert uten at noen hadde lest den, eller etter en kontroll som avviste den (ANTIDEP_CONSTITUTION.md regel 6).';

alter table knowledge.monograph_publication_events enable row level security;

create index monograph_publication_events_edition_idx
  on knowledge.monograph_publication_events (edition_id, occurred_at desc);

create trigger monograph_publication_events_set_created_at
  before insert or update on knowledge.monograph_publication_events
  for each row execute function catalog.set_created_at();

create trigger monograph_publication_events_are_append_only
  before update or delete on knowledge.monograph_publication_events
  for each row execute function knowledge.reject_append_only_mutation();

-- ----------------------------------------------------------------------------
-- 7. Skriveveiene
-- ----------------------------------------------------------------------------

create function knowledge.publish_monograph_edition(
  p_candidate_id uuid,
  p_publisher_actor_id uuid,
  p_reason text)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_candidate knowledge.monograph_edition_candidates;
  v_edition knowledge.monograph_editions;
  v_control workflow.monograph_final_controls;
  v_stale text;
  v_event_id uuid;
  v_before jsonb;
begin
  select c.* into v_candidate
  from knowledge.monograph_edition_candidates c
  where c.id = p_candidate_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Monografikandidaten finnes ikke.';
  end if;

  -- Utgaven låses, og deretter leses alt annet. To samtidige publiseringer av
  -- forskjellige kandidater for den samme utgaven skal bli to hendelser i
  -- rekkefølge, ikke to som begge tror de er gjeldende.
  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.id = v_candidate.edition_id
  for update;

  v_before := to_jsonb(v_edition);

  -- Sluttkontrollen, slik den er nå. En senere avvisning opphever en tidligere
  -- godkjenning, og det som gjelder, er den siste.
  v_control := workflow.current_monograph_final_control(p_candidate_id);

  if v_control.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Monografiutgaven har ingen sluttkontroll.',
      hint = 'Publisering forutsetter at et navngitt menneske har lest nøyaktig denne utgaven. Uten det ville publiseringen vært en handling ingen hadde vurdert (ANTIDEP_CONSTITUTION.md regel 6).';
  end if;

  if v_control.decision <> 'approved' then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Den gjeldende sluttkontrollen av denne utgaven er %L.',
                       v_control.decision),
      hint = 'En senere avvisning opphever en tidligere godkjenning. Rett innholdet, bygg en ny kandidat, og la den kontrolleres på nytt.';
  end if;

  if v_control.candidate_digest is distinct from v_candidate.content_hash then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Sluttkontrollen gjelder et annet innhold enn kandidaten.',
      hint = 'Kontrollen er bundet til avtrykket av den utgaven som ble lest.';
  end if;

  -- Og grunnlaget: er monografien blitt en annen etter kontrollen, ville
  -- publiseringen tatt i bruk et innhold som ikke lenger er utgavens.
  v_stale := knowledge.monograph_candidate_staleness(p_candidate_id);
  if v_stale is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Monografien er endret siden kandidaten ble bygget: %s', v_stale),
      hint = 'Bygg en ny kandidat og la den kontrolleres. Å publisere den gamle ville tatt i bruk et innhold som ikke lenger er monografiens, og det ingen har lest (ANTIDEP_CONSTITUTION.md regel 5).';
  end if;

  if v_edition.current_published_candidate_id = p_candidate_id then
    -- Allerede i bruk. Ingen ny hendelse: en gjentatt publisering av det samme
    -- er ikke en ny handling.
    return null;
  end if;

  -- Den forrige utgaven blir avløst, og det står i historikken som det.
  if v_edition.current_published_candidate_id is not null then
    insert into knowledge.monograph_publication_events (
      edition_id, candidate_id, final_control_id, final_control_candidate_id,
      final_control_digest, final_control_decision, action, reason, actor_id
    )
    select v_edition.id, v_edition.current_published_candidate_id,
           c.id, c.candidate_id, c.candidate_digest, c.decision,
           'replaced'::knowledge.monograph_publication_action,
           format('Avløst av monografikandidat %s.', v_candidate.candidate_no),
           p_publisher_actor_id
    from workflow.monograph_final_controls c
    where c.id = (workflow.current_monograph_final_control(
                    v_edition.current_published_candidate_id)).id;
  end if;

  insert into knowledge.monograph_publication_events (
    edition_id, candidate_id, final_control_id, final_control_candidate_id,
    final_control_digest, final_control_decision, action, reason, actor_id
  )
  values (
    v_edition.id, p_candidate_id, v_control.id, v_control.candidate_id,
    v_control.candidate_digest, v_control.decision,
    'published'::knowledge.monograph_publication_action,
    btrim(p_reason), p_publisher_actor_id
  )
  returning id into v_event_id;

  update knowledge.monograph_editions e
  set current_published_candidate_id = p_candidate_id
  where e.id = v_edition.id;

  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason, occurred_at
  )
  select 'monograph_published'::audit.event_operation, v_edition.id,
         p_publisher_actor_id, v_before, to_jsonb(e), btrim(p_reason), now()
  from knowledge.monograph_editions e where e.id = v_edition.id;

  return v_event_id;
end;
$$;

comment on function knowledge.publish_monograph_edition(uuid, uuid, text) is
  'Tar én kontrollert monografikandidat i bruk. Porten leser den sluttkontrollen som gjelder nå — en senere avvisning opphever en tidligere godkjenning — krever at den gjelder nøyaktig dette innholdet, og nekter når monografien er blitt en annen etter kontrollen: å publisere den gamle ville tatt i bruk et innhold ingen har lest. Den forrige utgaven blir stående i historikken som avløst, ikke slettet.';

revoke execute on function knowledge.publish_monograph_edition(uuid, uuid, text) from public;

create function knowledge.withdraw_monograph_publication(
  p_edition_id uuid,
  p_actor_id uuid,
  p_reason text)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_edition knowledge.monograph_editions;
  v_control workflow.monograph_final_controls;
  v_event_id uuid;
  v_before jsonb;
begin
  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.id = p_edition_id
  for update;

  if not found or v_edition.current_published_candidate_id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Utgaven har ingen publisert monografi å trekke tilbake.';
  end if;

  v_before := to_jsonb(v_edition);
  v_control := workflow.current_monograph_final_control(
    v_edition.current_published_candidate_id);

  insert into knowledge.monograph_publication_events (
    edition_id, candidate_id, final_control_id, final_control_candidate_id,
    final_control_digest, final_control_decision, action, reason, actor_id
  )
  values (
    v_edition.id, v_edition.current_published_candidate_id,
    v_control.id, v_control.candidate_id, v_control.candidate_digest,
    v_control.decision,
    'withdrawn'::knowledge.monograph_publication_action,
    btrim(p_reason), p_actor_id
  )
  returning id into v_event_id;

  update knowledge.monograph_editions e
  set current_published_candidate_id = null
  where e.id = v_edition.id;

  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, reason, occurred_at
  )
  select 'monograph_publication_withdrawn'::audit.event_operation, v_edition.id,
         p_actor_id, v_before, to_jsonb(e), btrim(p_reason), now()
  from knowledge.monograph_editions e where e.id = v_edition.id;

  return v_event_id;
end;
$$;

comment on function knowledge.withdraw_monograph_publication(uuid, uuid, text) is
  'Trekker en publisert monografiutgave ut av bruk, med en begrunnelse og den sluttkontrollen den hvilte på. Historikken er append-only: tilbaketrekkingen sletter ingenting, den sier at utgaven ikke lenger er i bruk og hvorfor. Den samme kandidaten kan tas i bruk igjen senere, og da står begge hendelsene.';

revoke execute on function knowledge.withdraw_monograph_publication(uuid, uuid, text) from public;

-- ----------------------------------------------------------------------------
-- 8. Flatene
--
-- Alle krever redaktørmandat, og publiseringen krever i tillegg et uavgrenset
-- publisher-mandat: å godkjenne og å publisere er to forskjellige handlinger.
-- ----------------------------------------------------------------------------

create function api.monograph_draft(p_edition_reference text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_edition knowledge.monograph_editions;
  v_candidate knowledge.monograph_edition_candidates;
  v_control workflow.monograph_final_controls;
begin
  perform knowledge.assert_editor_authorized();

  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.reference = p_edition_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografiutgave med denne referansen.';
  end if;

  select c.* into v_candidate
  from knowledge.monograph_edition_candidates c
  where c.edition_id = v_edition.id
  order by c.candidate_no desc
  limit 1;

  if v_candidate.id is not null then
    v_control := workflow.current_monograph_final_control(v_candidate.id);
  end if;

  return knowledge.monograph_draft_payload(v_edition, true)
    || jsonb_build_object(
      'latest_candidate', case when v_candidate.id is null then null else
        jsonb_build_object(
          'reference', v_candidate.reference,
          'candidate_no', v_candidate.candidate_no,
          'built_at', v_candidate.built_at,
          'answer_revisions', cardinality(v_candidate.answer_revision_ids),
          'stale_reason', knowledge.monograph_candidate_staleness(v_candidate.id),
          'final_control', case when v_control.id is null then null else
            jsonb_build_object(
              'decision', v_control.decision::text,
              'decided_at', v_control.decided_at,
              'reviewer', (select a.display_name from provenance.actors a
                           where a.id = v_control.reviewer_actor_id),
              'rationale', v_control.rationale)
          end)
      end,
      'published', case when v_edition.current_published_candidate_id is null then null else
        (select jsonb_build_object(
                  'candidate_reference', c.reference,
                  'candidate_no', c.candidate_no,
                  'published_at', (
                    select max(p.occurred_at)
                    from knowledge.monograph_publication_events p
                    where p.candidate_id = c.id and p.action = 'published'))
         from knowledge.monograph_edition_candidates c
         where c.id = v_edition.current_published_candidate_id)
      end);
end;
$$;

comment on function api.monograph_draft(text) is
  'Hele monografien for én utgave, slik en redaktør leser den: de strukturerte svarene i standardens egne seksjoner, med relevans, arbeidstilstand, faglig utfall, evidenssikkerhet, aktualitet og kontrollstatus atskilt — og med dekningsoversikten, den siste kandidaten, sluttkontrollen og hva som er i bruk. Krever redaktørmandat, fordi visningen bærer ordrette utdrag fra private originaldokumenter. Det finnes ingen offentlig lesevei: hvilke utdrag som kan vises utenfor redaksjonen, er en rettighetsavklaring som ikke hører hjemme i en kodeleveranse.';

revoke execute on function api.monograph_draft(text) from public;
grant execute on function api.monograph_draft(text) to authenticated;

create function api.build_monograph_candidate(p_edition_reference text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_edition knowledge.monograph_editions;
  v_id uuid;
  v_candidate knowledge.monograph_edition_candidates;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.reference = p_edition_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografiutgave med denne referansen.';
  end if;

  v_id := knowledge.build_monograph_edition_candidate(v_edition.id, v_actor_id);

  select c.* into v_candidate
  from knowledge.monograph_edition_candidates c where c.id = v_id;

  return jsonb_build_object(
    'reference', v_candidate.reference,
    'candidate_no', v_candidate.candidate_no,
    'content_digest', v_candidate.content_hash,
    'answer_revisions', cardinality(v_candidate.answer_revision_ids),
    'coverage', v_candidate.coverage -> 'needs',
    'built_at', v_candidate.built_at);
end;
$$;

comment on function api.build_monograph_candidate(text) is
  'Fryser den gjeldende monografien til en kandidat et menneske kan lese og ta stilling til. Den samme utgaven bygget to ganger gir den samme kandidaten. Svaret bærer avtrykket, som sluttkontrollen sendes uendret tilbake med.';

revoke execute on function api.build_monograph_candidate(text) from public;
grant execute on function api.build_monograph_candidate(text) to authenticated;

create function api.monograph_candidate(p_candidate_reference text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_candidate knowledge.monograph_edition_candidates;
  v_control workflow.monograph_final_controls;
begin
  perform knowledge.assert_editor_authorized();

  select c.* into v_candidate
  from knowledge.monograph_edition_candidates c
  where c.reference = p_candidate_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografikandidat med denne referansen.';
  end if;

  v_control := workflow.current_monograph_final_control(v_candidate.id);

  return jsonb_build_object(
    'reference', v_candidate.reference,
    'candidate_no', v_candidate.candidate_no,
    'content_digest', v_candidate.content_hash,
    'standard_version', v_candidate.standard_version,
    'built_at', v_candidate.built_at,
    'stale_reason', knowledge.monograph_candidate_staleness(v_candidate.id),
    'content', v_candidate.content,
    'coverage', v_candidate.coverage,
    'final_control', case when v_control.id is null then null else
      jsonb_build_object(
        'decision', v_control.decision::text,
        'decided_at', v_control.decided_at,
        'reviewer', (select a.display_name from provenance.actors a
                     where a.id = v_control.reviewer_actor_id),
        'rationale', v_control.rationale)
    end,
    'history', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'action', p.action::text,
               'occurred_at', p.occurred_at,
               'reason', p.reason,
               'actor', (select a.display_name from provenance.actors a where a.id = p.actor_id))
               order by p.occurred_at desc), '[]'::jsonb)
      from knowledge.monograph_publication_events p
      where p.candidate_id = v_candidate.id));
end;
$$;

revoke execute on function api.monograph_candidate(text) from public;
grant execute on function api.monograph_candidate(text) to authenticated;

create function api.record_monograph_final_control(
  p_candidate_reference text,
  p_seen_content_digest text,
  p_decision text,
  p_rationale text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_reviewer_actor_id uuid;
  v_candidate knowledge.monograph_edition_candidates;
  v_decision workflow.final_control_decision;
  v_stale text;
  v_id uuid;
begin
  begin
    v_decision := p_decision::workflow.final_control_decision;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke et kjent utfall av en sluttkontroll.', p_decision),
        hint = 'Gyldige utfall er approved, rejected og changes_requested.';
  end;

  -- Sluttkontrollen er en redaksjonell handling med mandat, og den er
  -- uavgrenset: en monografi spenner over mange kliniske temaer, og en
  -- avgrenset tildeling dekker ikke hele utgaven.
  v_reviewer_actor_id := workflow.assert_reviewer_authorized(null);

  select c.* into v_candidate
  from knowledge.monograph_edition_candidates c
  where c.reference = p_candidate_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografikandidat med denne referansen.';
  end if;

  -- Avtrykket flaten sendte uendret tilbake. Er det et annet, har mennesket
  -- lest noe annet enn det det nå tar stilling til.
  if p_seen_content_digest is distinct from v_candidate.content_hash then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Avtrykket du leste, er ikke kandidatens.',
      hint = 'Sluttkontrollen er bundet til nøyaktig den utgaven som ble lest (ANTIDEP_CONSTITUTION.md regel 5). Hent kandidaten på nytt.';
  end if;

  -- Og grunnlaget: en godkjenning av en utgave monografien alt har forlatt,
  -- ville vært en godkjenning av noe som ikke gjelder.
  v_stale := knowledge.monograph_candidate_staleness(v_candidate.id);
  if v_decision = 'approved' and v_stale is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Monografien er endret siden kandidaten ble bygget: %s', v_stale),
      hint = 'Bygg en ny kandidat og les den. En godkjenning av en utgave monografien alt har forlatt, ville vært en godkjenning av noe som ikke gjelder.';
  end if;

  insert into workflow.monograph_final_controls (
    candidate_id, candidate_digest, decision, rationale,
    reviewer_actor_id, reviewer_actor_type
  )
  values (
    v_candidate.id, v_candidate.content_hash, v_decision, btrim(p_rationale),
    v_reviewer_actor_id, 'human'::provenance.actor_type
  )
  returning id into v_id;

  return jsonb_build_object(
    'candidate', v_candidate.reference,
    'decision', v_decision::text,
    'recorded', true);
end;
$$;

comment on function api.record_monograph_final_control(text, text, text, text) is
  'Den navngitte menneskelige sluttkontrollen av én monografikandidat, uten feltvis godkjenning: mennesket tar stilling til utgaven som helhet. Avtrykket sendes uendret tilbake, slik at kontrollen er bundet til nøyaktig det som ble lest. En godkjenning av en utgave monografien alt har forlatt, avvises. Mandatet er uavgrenset reviewer-rolle, fordi en monografi spenner over mange kliniske temaer.';

revoke execute on function api.record_monograph_final_control(text, text, text, text) from public;
grant execute on function api.record_monograph_final_control(text, text, text, text) to authenticated;

create function api.publish_monograph(
  p_candidate_reference text,
  p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_candidate knowledge.monograph_edition_candidates;
  v_event_id uuid;
begin
  -- Publisering krever en menneskelig aktør med uavgrenset publisher-rolle.
  -- Å godkjenne og å publisere er to forskjellige handlinger, og de skal ikke
  -- kunne gjøres av det samme mandatet.
  select a.id into v_actor_id
  from provenance.actors a
  where a.auth_user_id = auth.uid();

  if v_actor_id is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kontoen din er ikke knyttet til en aktør i Antidep.';
  end if;

  perform knowledge.assert_publisher_authorized(v_actor_id, null);

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Publiseringen krever en begrunnelse.';
  end if;

  select c.* into v_candidate
  from knowledge.monograph_edition_candidates c
  where c.reference = p_candidate_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografikandidat med denne referansen.';
  end if;

  v_event_id := knowledge.publish_monograph_edition(
    v_candidate.id, v_actor_id, p_reason);

  return jsonb_build_object(
    'candidate', v_candidate.reference,
    'published', v_event_id is not null,
    'already_published', v_event_id is null);
end;
$$;

comment on function api.publish_monograph(text, text) is
  'Tar én kontrollert monografikandidat i bruk. Krever en menneskelig aktør med uavgrenset publisher-rolle: å godkjenne og å publisere er to forskjellige handlinger, og reviewer-rollen gir ingen publiseringsrett. Veien åpner ingen ny lesevei — den registrerer at utgaven er tatt i bruk.';

revoke execute on function api.publish_monograph(text, text) from public;
grant execute on function api.publish_monograph(text, text) to authenticated;

create function api.withdraw_monograph_publication(
  p_edition_reference text,
  p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_edition knowledge.monograph_editions;
begin
  select a.id into v_actor_id
  from provenance.actors a
  where a.auth_user_id = auth.uid();

  if v_actor_id is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kontoen din er ikke knyttet til en aktør i Antidep.';
  end if;

  perform knowledge.assert_publisher_authorized(v_actor_id, null);

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En tilbaketrekking krever en begrunnelse.',
      hint = 'Begrunnelsen er det som gjør at en tilbaketrukket utgave senere kan leses som en avgjørelse framfor som en feil.';
  end if;

  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.reference = p_edition_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografiutgave med denne referansen.';
  end if;

  perform knowledge.withdraw_monograph_publication(v_edition.id, v_actor_id, p_reason);

  return jsonb_build_object('edition', v_edition.reference, 'withdrawn', true);
end;
$$;

revoke execute on function api.withdraw_monograph_publication(text, text) from public;
grant execute on function api.withdraw_monograph_publication(text, text) to authenticated;
