-- ============================================================================
-- Migrasjon 009d — kandidaten, kildedekningen og den kandidatbundne
--                  sluttkontrollen
--
-- ANTIDEP_CONSTITUTION.md regel 5 sier at bare nøyaktig godkjent kandidat kan
-- publiseres — og la til, ærlig nok, at kandidatbindingen ennå ikke var
-- implementert. Den var ikke det: en godkjenning pekte på en påstandsrevisjon
-- og et evidenssettavtrykk, mens det en fagperson faktisk hadde lest — teksten,
-- vurderingen, kontrollene, kildedekningen — ikke fantes som ett objekt i det
-- hele tatt. Godkjenningen kunne dermed ikke være bundet til det, fordi det
-- ikke var noe å binde den til.
--
-- Denne migrasjonen lager objektet.
--
-- ----------------------------------------------------------------------------
-- 1. Kandidaten er et avtrykk, ikke en kopi med egen mening
--
-- `knowledge.candidate_content` setter sammen alt en kliniker og en
-- sluttkontrollør skal se, ut av rader som allerede finnes: påstanden,
-- evidensvurderingen, kildestøttekontrollen, hvert evidensfunn med sine
-- ordrette utdrag, og kildedekningen. Funksjonen legger ikke til én opplysning
-- og tar ikke stilling til noe. Den er ren og deterministisk, og det er hele
-- poenget: kandidaten er en *forsegling* av noe som allerede er registrert, og
-- kan derfor bygges om igjen og sammenlignes.
--
-- `candidate_digest` er sha256 av nøyaktig det innholdet. Endrer én lenket
-- evidenslenke, ett utdrag eller én vurdering seg, får kandidaten et annet
-- avtrykk — og en godkjenning av det gamle avtrykket gjelder ikke det nye.
--
-- ----------------------------------------------------------------------------
-- 2. Kildedekningen er en del av innholdet, ikke en visningsdetalj
--
-- En kliniker skal kunne se hvilke kilder påstanden faktisk hviler på, og hvor
-- godt hver av dem er dekket: hvilke kontrollfelter som er forankret i ordrett
-- tekst, om fullteksten ligger i biblioteket, og på hvilket grunnlag filen er
-- knyttet til publikasjonen. Det er ikke pynt. ANTIDEP_CONSTITUTION.md regel 4
-- krever at forskningsusikkerhet, agentuenighet og teknisk feil er forskjellige
-- tilstander — og en dekning som ikke vises, leses som full dekning.
--
-- Dekningen ligger derfor *inne i* det avtrykket sluttkontrollen bindes til.
-- Lå den utenfor, kunne den endret seg etter godkjenningen uten at avtrykket
-- merket det.
--
-- ----------------------------------------------------------------------------
-- 3. Sluttkontrollen er bundet til kandidaten av en fremmednøkkel
--
-- `workflow.candidate_final_controls` bærer både `candidate_id` og
-- `candidate_digest`, og en sammensatt fremmednøkkel binder paret til
-- `knowledge.candidates (id, candidate_digest)`. En godkjenning kan dermed ikke
-- registreres med et annet avtrykk enn kandidatens eget — ikke ved en feil, og
-- ikke ved en senere skrivevei som glemte kontrollen. I tillegg krever
-- skriveveien at kalleren oppgir det avtrykket hen faktisk så, og at innholdet
-- fortsatt bygger til nøyaktig det: en kandidat hvis grunnlag er endret etter at
-- den ble forseglet, kan ikke sluttkontrolleres før den er bygget på nytt.
--
-- ----------------------------------------------------------------------------
-- 4. Ingen ny publiseringsvei her
--
-- Sluttkontrollen registrerer en beslutning. Den publiserer ingenting, og denne
-- migrasjonen åpner ingen publiserings-API: `api.publish_claim_revision` er
-- fortsatt stengt for klientrollene, slik Antidep 2-resetten satte den. Rekke-
-- følgen er med vilje — kjeden skal virke før publiseringen åpnes.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 1, 3, 4, 5, 6
--   docs/DATABASE_ARCHITECTURE.md §30, §35, §43, §50
--   docs/EVIDENCE_PIPELINE.md, docs/KNOWLEDGE_MODEL.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Kildedekningen for ett evidensfunn
-- ----------------------------------------------------------------------------
create function knowledge.evidence_source_coverage(p_evidence_item_id uuid)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select jsonb_build_object(
    'required_check_fields',
      to_jsonb(coalesce(workflow.required_check_fields(p_evidence_item_id)::text[], array[]::text[])),
    'covered_check_fields',
      to_jsonb(coalesce(workflow.covered_check_fields(p_evidence_item_id)::text[], array[]::text[])),
    'grounded_check_fields',
      to_jsonb(coalesce(workflow.grounded_check_fields(p_evidence_item_id)::text[], array[]::text[])),
    'grounding_machine_proved', workflow.grounding_machine_proved(p_evidence_item_id)
  );
$$;

comment on function knowledge.evidence_source_coverage(uuid) is
  'Kildedekningen for ett evidensfunn, som den vises for en kliniker: hvilke kontrollfelter funnet påstår noe om, hvilke de registrerte kontrollene faktisk dekker, hvilke som er forankret i ordrett kildetekst, og om maskinbeviset for forankringen gjelder (ANTIDEP_CONSTITUTION.md regel 4). Ingen nye tall: de fire leses av de samme funksjonene publiseringsgaten bruker, slik at det som vises, er det som gjelder. En dekning som ikke vises, leses som full dekning, og det er nettopp den feilen dette hindrer.';

revoke execute on function knowledge.evidence_source_coverage(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. Kandidatinnholdet — deterministisk, og uten en eneste ny opplysning
-- ----------------------------------------------------------------------------
create function knowledge.candidate_content(p_claim_revision_id uuid)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'claim_revision', (
      select jsonb_build_object(
        'claim_revision_id', r.id,
        'claim_id', r.claim_id,
        'revision_number', r.revision_number,
        'knowledge_type', r.knowledge_type::text,
        'statement', r.statement,
        'scope', r.scope,
        'subject_drug', d.canonical_name,
        'topic', c.canonical_label,
        'population', p.canonical_label,
        'timeframe_min', r.timeframe_min::text,
        'timeframe_max', r.timeframe_max::text,
        'comparator_kind', r.comparator_kind::text,
        'comparator_drug', cd.canonical_name,
        'direction', r.direction::text,
        'magnitude_measure', r.magnitude_measure::text,
        'magnitude_value', trim_scale(r.magnitude_value)::text,
        'magnitude_unit', r.magnitude_unit::text,
        'qualifiers', r.qualifiers,
        'uncertainty_summary', r.uncertainty_summary,
        'content_hash', r.content_hash
      )
      from knowledge.claim_revisions r
      join knowledge.claims cl on cl.id = r.claim_id
      join catalog.drugs d on d.id = r.subject_drug_id
      join catalog.clinical_concepts c on c.id = cl.topic_concept_id
      left join catalog.populations p on p.id = r.population_id
      left join catalog.drugs cd on cd.id = r.comparator_drug_id
      where r.id = p_claim_revision_id
    ),
    'evidence_assessment', (
      select jsonb_build_object(
        'framework', a.framework::text,
        'certainty_level', a.certainty_level::text,
        'risk_of_bias', a.risk_of_bias::text,
        'inconsistency', a.inconsistency::text,
        'indirectness', a.indirectness::text,
        'imprecision', a.imprecision::text,
        'publication_bias', a.publication_bias::text,
        'other_considerations', a.other_considerations,
        'rationale', a.rationale,
        'evidence_gap', a.evidence_gap
      )
      from knowledge.evidence_assessments a
      where a.claim_revision_id = p_claim_revision_id
      order by a.assessed_at desc, a.id desc
      limit 1
    ),
    'citation_support_check', (
      select jsonb_build_object(
        'outcome', v.outcome::text,
        'source_access', v.source_access::text,
        'source_support', v.source_support::text,
        'population_match', v.population_match::text,
        'comparator_match', v.comparator_match::text,
        'timeframe_match', v.timeframe_match::text,
        'direction_and_magnitude', v.direction_and_magnitude::text,
        'qualifiers_complete', v.qualifiers_complete::text,
        'contradictory_evidence_represented', v.contradictory_evidence_represented::text,
        'rationale', v.rationale,
        'findings', v.findings,
        'verified_evidence_set_digest', v.verified_evidence_set_digest
      )
      from workflow.claim_verifications v
      where v.claim_revision_id = p_claim_revision_id
      order by v.registration_ordinal desc
      limit 1
    ),
    'evidence', coalesce((
      select jsonb_agg(item order by item ->> 'evidence_item_id')
      from (
        select jsonb_build_object(
          'evidence_item_id', e.id,
          'relationship_type', l.relationship_type::text,
          'directness', l.directness::text,
          'relevance_note', l.relevance_note,
          'design_code', e.design_code::text,
          'population', pop.canonical_label,
          'population_detail', e.population_detail,
          'population_availability', e.population_availability::text,
          'sample_size', e.sample_size,
          'sample_size_availability', e.sample_size_availability::text,
          'intervention_drug', idrug.canonical_name,
          'intervention_detail', e.intervention_detail,
          'comparator_kind', e.comparator_kind::text,
          'comparator_drug', cdrug.canonical_name,
          'comparator_detail', e.comparator_detail,
          'outcome', oc.canonical_label,
          'outcome_detail', e.outcome_detail,
          'timepoint_min', e.timepoint_min::text,
          'timepoint_max', e.timepoint_max::text,
          'timepoint_availability', e.timepoint_availability::text,
          'reported_direction', e.reported_direction::text,
          'effect_measure', e.effect_measure::text,
          'estimate', trim_scale(e.estimate)::text,
          'estimate_unit', e.estimate_unit::text,
          'estimate_availability', e.estimate_availability::text,
          'ci_lower', trim_scale(e.ci_lower)::text,
          'ci_upper', trim_scale(e.ci_upper)::text,
          'ci_level_percent', trim_scale(e.ci_level_percent)::text,
          'confidence_interval_availability', e.confidence_interval_availability::text,
          'limitations_text', e.limitations_text,
          'source_locator', e.source_locator,
          'extraction_method', e.extraction_method::text,
          'content_hash', e.content_hash,
          'source', jsonb_build_object(
            'source_id', s.id,
            'title', s.title,
            'authors_or_issuer', s.authors_or_issuer,
            'publisher_or_journal', s.publisher_or_journal,
            'publication_date', s.publication_date::text,
            'publication_date_precision', s.publication_date_precision::text,
            'source_status', s.source_status::text,
            'identifiers', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'system', si.identifier_system::text,
                       'value', si.identifier_value)
                     order by si.identifier_system::text, si.identifier_value)
              from knowledge.source_identifiers si
              where si.source_id = s.id
            ), '[]'::jsonb)
          ),
          'source_version', jsonb_build_object(
            'source_version_id', sv.id,
            'representation', sv.representation::text,
            'retrieved_from', sv.retrieved_from,
            'retrieved_at', sv.retrieved_at,
            'content_hash', sv.content_hash,
            'document_sha256', sv.document_sha256,
            'text_extraction', jsonb_build_object(
              'tool', sv.text_extraction_tool,
              'tool_version', sv.text_extraction_tool_version,
              'arguments', sv.text_extraction_arguments,
              'transform', sv.text_extraction_transform
            ),
            'in_library', exists (
              select 1 from knowledge.source_documents sd where sd.sha256 = sv.document_sha256
            ),
            'publication_binding', (
              select jsonb_build_object(
                'basis', dp.binding_basis::text, 'evidence', dp.binding_evidence)
              from knowledge.source_document_publications dp
              join knowledge.source_documents sd on sd.id = dp.source_document_id
              where sd.sha256 = sv.document_sha256 and dp.source_id = sv.source_id
            ),
            'readability', (
              select jsonb_build_object(
                'character_count', rc.character_count,
                'line_count', rc.line_count,
                'table_row_count', rc.table_row_count,
                'table_declaration_count', rc.table_declaration_count)
              from knowledge.full_text_readability_checks rc
              where rc.source_version_id = sv.id
            )
          ),
          'coverage', knowledge.evidence_source_coverage(e.id),
          'field_groundings', coalesce((
            select jsonb_agg(jsonb_build_object(
                     'check_field', g.check_field::text,
                     'source_excerpt', g.source_excerpt,
                     'source_locator', g.source_locator,
                     'justification', g.justification)
                   order by g.check_field::text, g.source_excerpt)
            from knowledge.evidence_field_groundings g
            where g.evidence_item_id = e.id
          ), '[]'::jsonb),
          'extraction_check', (
            select jsonb_build_object(
              'outcome', ev.outcome::text,
              'source_access', ev.source_access::text,
              'checked_fields', to_jsonb(ev.checked_fields::text[]),
              'rationale', ev.rationale,
              'findings', ev.findings)
            from workflow.evidence_verifications ev
            where ev.evidence_item_id = e.id
            order by ev.registration_ordinal desc
            limit 1
          )
        ) as item
        from knowledge.claim_evidence_links l
        join knowledge.evidence_items e on e.id = l.evidence_item_id
        join knowledge.sources s on s.id = e.source_id
        join knowledge.source_versions sv on sv.id = e.source_version_id
        join catalog.drugs idrug on idrug.id = e.intervention_drug_id
        join catalog.clinical_concepts oc on oc.id = e.outcome_concept_id
        left join catalog.populations pop on pop.id = e.population_id
        left join catalog.drugs cdrug on cdrug.id = e.comparator_drug_id
        where l.claim_revision_id = p_claim_revision_id
      ) as items
    ), '[]'::jsonb),
    'source_coverage', coalesce((
      select jsonb_agg(entry order by entry ->> 'title')
      from (
        select jsonb_build_object(
          'source_id', s.id,
          'title', s.title,
          'evidence_item_count', count(distinct e.id),
          'full_text_in_library', bool_and(
            exists (select 1 from knowledge.source_documents sd where sd.sha256 = sv.document_sha256)
          ),
          'readability_checked', bool_and(
            exists (select 1 from knowledge.full_text_readability_checks rc
                    where rc.source_version_id = sv.id)
          ),
          'grounding_machine_proved', bool_and(workflow.grounding_machine_proved(e.id))
        ) as entry
        from knowledge.claim_evidence_links l
        join knowledge.evidence_items e on e.id = l.evidence_item_id
        join knowledge.sources s on s.id = e.source_id
        join knowledge.source_versions sv on sv.id = e.source_version_id
        where l.claim_revision_id = p_claim_revision_id
        group by s.id, s.title
      ) as sources
    ), '[]'::jsonb),
    'evidence_set_digest', knowledge.claim_evidence_set_digest(p_claim_revision_id)
  ));
$$;

comment on function knowledge.candidate_content(uuid) is
  'Alt en kliniker og en sluttkontrollør skal se om én påstandsrevisjon, satt sammen av rader som allerede finnes: påstanden, evidensvurderingen, kildestøttekontrollen, hvert lenket evidensfunn med kilde, kildeversjon, ordrette utdrag og gjeldende ekstraksjonskontroll, og kildedekningen per kilde (ANTIDEP_CONSTITUTION.md regel 4, 5). Legger ikke til én opplysning og tar ikke stilling til noe: den er ren og deterministisk, slik at kandidaten kan bygges om igjen og sammenlignes. Rekkefølgen i hver liste er sortert på en stabil nøkkel, fordi avtrykket ellers ville endret seg uten at innholdet gjorde det.';

revoke execute on function knowledge.candidate_content(uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. Kandidaten
-- ----------------------------------------------------------------------------
create table knowledge.candidates (
  id uuid primary key default gen_random_uuid(),

  claim_revision_id uuid not null
    references knowledge.claim_revisions (id) on update restrict on delete restrict,

  -- Avtrykket av nøyaktig det innholdet som er forseglet. Aldri en parameter:
  -- beregnet av innholdet, og gjentatt av CHECK-en under.
  candidate_digest text not null,
  evidence_set_digest text not null,
  content jsonb not null,

  built_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  built_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint candidates_digest_format_check
    check (candidate_digest ~ '^sha256:[0-9a-f]{64}$'),
  -- Evidenssettets avtrykk har sitt eget versjonerte prefiks
  -- (knowledge.claim_evidence_set_digest), og det er ikke det samme som
  -- innholdshashen. Å kreve samme form for begge ville vært å kreve at to
  -- forskjellige kanoniseringer ser like ut.
  constraint candidates_evidence_set_digest_format_check
    check (evidence_set_digest ~ '^sha256-v1:[0-9a-f]{64}$'),
  constraint candidates_digest_is_the_content_check
    check (candidate_digest = knowledge.source_version_content_hash(content::text)),
  -- Den samme revisjonen med det samme innholdet er den samme kandidaten.
  -- Unikheten er idempotensen: å bygge om igjen skriver ingen ny rad.
  constraint candidates_revision_digest_key unique (claim_revision_id, candidate_digest),
  -- Venstresiden sluttkontrollen bindes til. Uten den kunne en godkjenning
  -- registreres med et annet avtrykk enn kandidatens eget.
  constraint candidates_id_digest_key unique (id, candidate_digest)
);

comment on table knowledge.candidates is
  'Ett forseglet, agentferdig kandidatinnhold for én påstandsrevisjon (ANTIDEP_CONSTITUTION.md regel 5). content er knowledge.candidate_content(uuid) på byggetidspunktet, og candidate_digest er sha256 av nøyaktig det — beregnet av databasen og gjentatt av en CHECK, så avtrykket er aldri en påstand kalleren skriver om seg selv. Endrer én lenket evidenslenke, ett utdrag eller én vurdering seg, får en ny bygging et annet avtrykk, og en godkjenning av det gamle gjelder ikke det nye. Raden er uforanderlig: en kandidat rettes ved at en ny bygges.';
comment on column knowledge.candidates.content is
  'Kandidatinnholdet slik det ble forseglet, inkludert kildedekningen. Dekningen ligger inne i avtrykket og ikke utenfor, fordi en dekning som kunne endre seg etter godkjenningen uten at avtrykket merket det, ikke ville vært bundet til noe.';
comment on column knowledge.candidates.candidate_digest is
  'sha256 av content, beregnet av knowledge.source_version_content_hash(text). Venstresiden i den sammensatte fremmednøkkelen workflow.candidate_final_controls bruker: en sluttkontroll kan strukturelt ikke vise til et annet avtrykk enn kandidatens eget.';

alter table knowledge.candidates enable row level security;

create index candidates_claim_revision_idx
  on knowledge.candidates (claim_revision_id, built_at desc);

create trigger candidates_set_row_timestamps
  before insert or update on knowledge.candidates
  for each row execute function catalog.set_row_timestamps();

create trigger candidates_are_append_only
  before update or delete on knowledge.candidates
  for each row execute function knowledge.reject_append_only_mutation(
    'En kandidat er det en fagperson faktisk fikk se. Bygg en ny kandidat for det endrede innholdet; den får sitt eget avtrykk, fordi den er et annet innhold.'
  );

create function audit.record_candidate_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, occurred_at
  )
  values (
    'candidate_built'::audit.event_operation,
    new.id,
    new.built_by_actor_id,
    null,
    -- Øyeblikksbildet uten selve innholdet: innholdet står i kandidaten, og
    -- avtrykket identifiserer det entydig. En andre kopi ville doblet en
    -- tilgangsbegrenset tekst uten å legge til noe spor.
    to_jsonb(new) - 'content',
    now()
  );

  return null;
end;
$$;

comment on function audit.record_candidate_event() is
  'Auditskriver over forseglede kandidater (DATABASE_ARCHITECTURE.md §35). Øyeblikksbildet bærer avtrykket og ikke innholdet: avtrykket identifiserer innholdet entydig, og en andre kopi ville doblet en tilgangsbegrenset tekst uten å legge til noe spor. Ligger på tabellen og ikke på skriveveien.';

revoke execute on function audit.record_candidate_event() from public;

create trigger candidates_record_audit_event
  after insert on knowledge.candidates
  for each row execute function audit.record_candidate_event();

-- ----------------------------------------------------------------------------
-- 4. Byggingen
-- ----------------------------------------------------------------------------
create function api.build_candidate(p_claim_revision_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_content jsonb;
  v_digest text;
  v_evidence_digest text;
  v_candidate knowledge.candidates;
  v_built boolean := false;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  -- Den samme gaten publiseringen bruker. Kandidaten forsegler et ferdig
  -- agentresultat, og et resultat som ikke er ferdig — uten kontroll, uten
  -- dekning, uten vurdering, uten mandat — skal ikke kunne forsegles og se
  -- ferdig ut (ANTIDEP_CONSTITUTION.md regel 4).
  perform knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id);

  v_content := knowledge.candidate_content(p_claim_revision_id);
  v_digest := knowledge.source_version_content_hash(v_content::text);
  v_evidence_digest := knowledge.claim_evidence_set_digest(p_claim_revision_id);

  select c.* into v_candidate
  from knowledge.candidates c
  where c.claim_revision_id = p_claim_revision_id and c.candidate_digest = v_digest;

  if not found then
    insert into knowledge.candidates
      (claim_revision_id, candidate_digest, evidence_set_digest, content, built_by_actor_id)
    values (p_claim_revision_id, v_digest, v_evidence_digest, v_content, v_actor_id)
    returning * into v_candidate;
    v_built := true;
  end if;

  return jsonb_build_object(
    'candidate_id', v_candidate.id,
    'claim_revision_id', v_candidate.claim_revision_id,
    'candidate_digest', v_candidate.candidate_digest,
    'evidence_set_digest', v_candidate.evidence_set_digest,
    'built', v_built
  );
end;
$$;

comment on function api.build_candidate(uuid) is
  'Forsegler det agentferdige kandidatinnholdet for én påstandsrevisjon (ANTIDEP_CONSTITUTION.md regel 5, DATABASE_ARCHITECTURE.md §43). Krever en registrert, aktiv aktør med gyldig editor-rolle, og kjører den samme gaten publiseringen bruker (knowledge.assert_claim_revision_ready_for_approval(uuid)): et resultat uten kontroll, dekning, vurdering eller mandat skal ikke kunne forsegles og se ferdig ut. Innholdet er knowledge.candidate_content(uuid) og avtrykket beregnes av det; byggeren legger ingenting til. Idempotent: uendret innhold gir den samme kandidaten og skriver ingen ny rad, mens endret innhold gir en ny kandidat med et nytt avtrykk. Publiserer ingenting. SECURITY DEFINER med tomt search_path fordi knowledge, workflow og provenance har RLS med default deny (§50).';

revoke execute on function api.build_candidate(uuid) from public;
grant execute on function api.build_candidate(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Sluttkontrollen
-- ----------------------------------------------------------------------------
create type workflow.final_control_decision as enum
  ('approved', 'rejected', 'changes_requested');

revoke usage on type workflow.final_control_decision from public;

comment on type workflow.final_control_decision is
  'Utfallet av en navngitt fagpersons sluttkontroll av ett kandidatinnhold: approved, rejected eller changes_requested. Egen type og ikke workflow.review_outcome, fordi sluttkontrollen er en vurdering av det ferdige produktet i klinikerens egen visning — ikke en felt-for-felt-mikroreview av et mellomprodukt (ANTIDEP_CONSTITUTION.md, versjon 2).';

create table workflow.candidate_final_controls (
  id uuid primary key default gen_random_uuid(),

  candidate_id uuid not null
    references knowledge.candidates (id) on update restrict on delete restrict,
  -- Speilet av kandidatens avtrykk, låst til kandidaten av den sammensatte
  -- fremmednøkkelen under. Det er denne raden som gjør godkjenningen bundet
  -- til akkurat det innholdet som ble lest.
  candidate_digest text not null,

  decision workflow.final_control_decision not null,
  rationale text not null,

  reviewer_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  reviewer_actor_type provenance.actor_type not null,

  decided_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  constraint candidate_final_controls_candidate_fkey
    foreign key (candidate_id, candidate_digest)
    references knowledge.candidates (id, candidate_digest)
    on update restrict on delete restrict,

  -- ANTIDEP_CONSTITUTION.md regel 5 og §12: KI skal aldri være endelig faglig
  -- autoritet. Regelen er strukturell — det finnes ingen skrivevei der en
  -- KI-aktør kan registrere en sluttkontroll.
  constraint candidate_final_controls_reviewer_fkey
    foreign key (reviewer_actor_id, reviewer_actor_type)
    references provenance.actors (id, actor_type)
    on update restrict on delete restrict,
  constraint candidate_final_controls_reviewer_is_human_check
    check (reviewer_actor_type = 'human'),

  constraint candidate_final_controls_rationale_shape_check
    check (rationale = btrim(rationale) and length(rationale) between 1 and 4000)
);

comment on table workflow.candidate_final_controls is
  'En navngitt fagpersons sluttkontroll av ett forseglet kandidatinnhold (ANTIDEP_CONSTITUTION.md regel 5, §12). Raden bærer både kandidatens id og dens avtrykk, og den sammensatte fremmednøkkelen mot knowledge.candidates (id, candidate_digest) gjør at en godkjenning strukturelt ikke kan vise til et annet innhold enn det som faktisk ble lest — ikke ved en feil, og ikke gjennom en senere skrivevei som glemte kontrollen. Reviewer er låst til en human-aktør av den samme grunnen: det finnes ingen vei der en KI-aktør kan være endelig faglig autoritet. Append-only: en omgjøring er en ny rad. Raden publiserer ingenting.';
comment on column workflow.candidate_final_controls.candidate_digest is
  'Avtrykket av kandidaten slik den ble lest. Ikke en kopi for lesbarhetens skyld: det er venstresiden i den sammensatte fremmednøkkelen, og dermed selve bindingen mellom godkjenningen og innholdet.';

alter table workflow.candidate_final_controls enable row level security;

create index candidate_final_controls_candidate_idx
  on workflow.candidate_final_controls (candidate_id, decided_at desc);

-- Tabellen har ingen updated_at, fordi en rad aldri endres. created_at settes
-- derfor av databasen også når kalleren oppgir den.
create trigger candidate_final_controls_set_created_at
  before insert on workflow.candidate_final_controls
  for each row execute function catalog.set_created_at();

create trigger candidate_final_controls_are_append_only
  before update or delete on workflow.candidate_final_controls
  for each row execute function knowledge.reject_append_only_mutation(
    'En sluttkontroll sier hva en navngitt fagperson konkluderte den gangen, om nøyaktig det innholdet. En omgjøring er en ny rad, mot den kandidaten som faktisk ble lest.'
  );

create function audit.record_candidate_final_control_event()
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
    'candidate_final_control_recorded'::audit.event_operation,
    new.id,
    new.reviewer_actor_id,
    null,
    to_jsonb(new),
    new.rationale,
    now()
  );

  return null;
end;
$$;

comment on function audit.record_candidate_final_control_event() is
  'Auditskriver over sluttkontroller (DATABASE_ARCHITECTURE.md §35, ANTIDEP_CONSTITUTION.md regel 5). Hele øyeblikksbildet, ført på den fagpersonen som konkluderte. Ligger på tabellen og ikke på skriveveien, slik at ingen faglig sluttbeslutning kan registreres uten spor.';

revoke execute on function audit.record_candidate_final_control_event() from public;

create trigger candidate_final_controls_record_audit_event
  after insert on workflow.candidate_final_controls
  for each row execute function audit.record_candidate_final_control_event();

create function api.record_candidate_final_control(
  p_candidate_id uuid,
  p_seen_candidate_digest text,
  p_decision text,
  p_rationale text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_candidate knowledge.candidates;
  v_topic_concept_id uuid;
  v_reviewer_actor_id uuid;
  v_decision workflow.final_control_decision;
  v_current_digest text;
  v_control_id uuid;
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

  -- Låsen tas før kontrollen av avtrykket, slik at en kandidat ikke kan få en
  -- ny sluttkontroll skrevet under oss mellom lesningen og skrivingen.
  select c.* into v_candidate
  from knowledge.candidates c
  where c.id = p_candidate_id
  for share;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kandidaten %L finnes ikke.', p_candidate_id);
  end if;

  select cl.topic_concept_id into v_topic_concept_id
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  where r.id = v_candidate.claim_revision_id;

  -- Mandatet: en navngitt fagperson med gyldig reviewer-rolle for nettopp dette
  -- kliniske begrepet. Avvisningene kommer derfra, uendret.
  v_reviewer_actor_id := workflow.assert_reviewer_authorized(v_topic_concept_id);

  -- Bindingen, lag 1: kalleren skal ha sett nøyaktig denne kandidaten.
  if p_seen_candidate_digest is distinct from v_candidate.candidate_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Sluttkontrollen viser til et annet kandidatavtrykk enn kandidatens eget.',
      hint = 'Avtrykket skal kopieres uendret fra den kandidaten som faktisk ble lest. En godkjenning avgitt mot ett innhold og registrert mot et annet, ville vært en attestasjon uten dekning (ANTIDEP_CONSTITUTION.md regel 5).';
  end if;

  -- Bindingen, lag 2: innholdet skal fortsatt bygge til det samme avtrykket.
  -- Lag 1 alene ville godtatt en godkjenning av en kandidat hvis grunnlag var
  -- endret etter forseglingen — teksten ville stemt, og det den hvilte på,
  -- ville vært noe annet. Fail-closed: bygg kandidaten på nytt først.
  v_current_digest := knowledge.source_version_content_hash(
    knowledge.candidate_content(v_candidate.claim_revision_id)::text
  );
  if v_current_digest is distinct from v_candidate.candidate_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Grunnlaget kandidaten ble forseglet av, er endret siden den ble bygget.',
      hint = format(
        'Kandidaten bærer %s, mens innholdet nå bygger til %s. Bygg kandidaten på nytt med api.build_candidate(uuid) og sluttkontroller den nye; en godkjenning av et innhold som ikke lenger er det som ligger der, er ikke en godkjenning av noe (ANTIDEP_CONSTITUTION.md regel 5).',
        v_candidate.candidate_digest, v_current_digest
      );
  end if;

  insert into workflow.candidate_final_controls (
    candidate_id, candidate_digest, decision, rationale,
    reviewer_actor_id, reviewer_actor_type
  )
  values (
    v_candidate.id, v_candidate.candidate_digest, v_decision, btrim(coalesce(p_rationale, '')),
    v_reviewer_actor_id, 'human'
  )
  returning id into v_control_id;

  return jsonb_build_object(
    'candidate_final_control_id', v_control_id,
    'candidate_id', v_candidate.id,
    'candidate_digest', v_candidate.candidate_digest,
    'decision', v_decision::text,
    -- Sagt eksplisitt, fordi det er den ene misforståelsen som ville vært
    -- alvorlig: en godkjenning er ikke en publisering.
    'published', false
  );
end;
$$;

comment on function api.record_candidate_final_control(uuid, text, text, text) is
  'Registrerer en navngitt fagpersons sluttkontroll av nøyaktig ett forseglet kandidatinnhold (ANTIDEP_CONSTITUTION.md regel 5, §12, DATABASE_ARCHITECTURE.md §43). Krever gyldig reviewer-rolle for påstandens kliniske begrep (workflow.assert_reviewer_authorized(uuid)), og binder beslutningen til kandidaten i to lag: avtrykket kalleren oppgir må være kandidatens eget, og innholdet må fortsatt bygge til nøyaktig det samme avtrykket. Det andre laget er det som fanger at grunnlaget er endret etter forseglingen — teksten ville stemt, og det den hvilte på, ville vært noe annet; da er svaret å bygge kandidaten på nytt, ikke å godkjenne den gamle. Publiserer ingenting: svaret sier published: false, og api.publish_claim_revision(uuid, text) er fortsatt stengt for klientrollene. Append-only — en omgjøring er en ny rad. SECURITY DEFINER med tomt search_path fordi knowledge, workflow og provenance har RLS med default deny (§50).';

revoke execute on function api.record_candidate_final_control(uuid, text, text, text) from public;
grant execute on function api.record_candidate_final_control(uuid, text, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. Leseflaten klinikeren og sluttkontrolløren deler
--
-- Samme visning for begge, med vilje: ANTIDEP_CONSTITUTION.md krever at
-- fagpersonen vurderer det ferdige produktet i *samme visning* som klinikeren
-- får. To visninger ville gjort godkjenningen til en godkjenning av noe annet
-- enn det som vises.
-- ----------------------------------------------------------------------------
create function api.candidate_for_control(p_candidate_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_candidate knowledge.candidates;
  v_topic_concept_id uuid;
  v_current_digest text;
begin
  select c.* into v_candidate
  from knowledge.candidates c
  where c.id = p_candidate_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kandidaten %L finnes ikke.', p_candidate_id);
  end if;

  select cl.topic_concept_id into v_topic_concept_id
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  where r.id = v_candidate.claim_revision_id;

  -- Utkast er tilgangsbegrenset (ANTIDEP_CONSTITUTION.md regel 5). Leseretten
  -- er den samme som mandatet til å sluttkontrollere: en kaller uten den, får
  -- ikke se innholdet i det hele tatt.
  if not workflow.caller_is_active_reviewer(v_topic_concept_id) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kandidatinnhold er tilgangsbegrenset.',
      hint = 'Innholdet er eksperimentelt og ikke publisert. Lesing krever gyldig reviewer-rolle for påstandens kliniske begrep, som er det samme mandatet sluttkontrollen krever.';
  end if;

  v_current_digest := knowledge.source_version_content_hash(
    knowledge.candidate_content(v_candidate.claim_revision_id)::text
  );

  return jsonb_build_object(
    'candidate_id', v_candidate.id,
    'claim_revision_id', v_candidate.claim_revision_id,
    'candidate_digest', v_candidate.candidate_digest,
    'evidence_set_digest', v_candidate.evidence_set_digest,
    'built_at', v_candidate.built_at,
    -- Sagt som en egen opplysning framfor som et fravær: en kandidat som ikke
    -- lenger er gjeldende, skal se annerledes ut enn en som er det.
    'is_current', v_current_digest = v_candidate.candidate_digest,
    'current_digest', v_current_digest,
    'experimental', true,
    'published', false,
    'content', v_candidate.content,
    'final_controls', coalesce((
      select jsonb_agg(jsonb_build_object(
               'decision', fc.decision::text,
               'rationale', fc.rationale,
               'decided_at', fc.decided_at,
               'reviewer', a.display_name,
               'candidate_digest', fc.candidate_digest)
             order by fc.decided_at desc, fc.id desc)
      from workflow.candidate_final_controls fc
      join provenance.actors a on a.id = fc.reviewer_actor_id
      where fc.candidate_id = v_candidate.id
    ), '[]'::jsonb)
  );
end;
$$;

comment on function api.candidate_for_control(uuid) is
  'Leseflaten for ett forseglet kandidatinnhold, den samme for klinikeren og for sluttkontrolløren (ANTIDEP_CONSTITUTION.md regel 5). Innholdet er tilgangsbegrenset: lesing krever det samme mandatet som sluttkontrollen, altså gyldig reviewer-rolle for påstandens kliniske begrep. Svaret bærer kandidatens avtrykk, avtrykket innholdet bygger til akkurat nå, og om de to er like — en kandidat som ikke lenger er gjeldende, skal se annerledes ut enn en som er det, framfor å skille seg ved et fravær. experimental og published står eksplisitt i svaret, slik at en visning ikke kan utelate dem ved en forglemmelse. SECURITY DEFINER med tomt search_path fordi knowledge, workflow og provenance har RLS med default deny (§50).';

revoke execute on function api.candidate_for_control(uuid) from public;
grant execute on function api.candidate_for_control(uuid) to authenticated;

create function api.candidate_control_queue()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
begin
  select a.id into v_actor_id
  from provenance.actors a
  where a.auth_user_id = auth.uid() and a.retired_at is null;

  if v_actor_id is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kontoen din er ikke knyttet til en aktiv aktør i Antidep.';
  end if;

  return coalesce((
    select jsonb_agg(entry order by entry ->> 'built_at' desc)
    from (
      select jsonb_build_object(
        'candidate_id', c.id,
        'claim_revision_id', c.claim_revision_id,
        'candidate_digest', c.candidate_digest,
        'built_at', c.built_at,
        'statement', c.content -> 'claim_revision' ->> 'statement',
        'subject_drug', c.content -> 'claim_revision' ->> 'subject_drug',
        'topic', c.content -> 'claim_revision' ->> 'topic',
        'certainty_level', c.content -> 'evidence_assessment' ->> 'certainty_level',
        'source_count', jsonb_array_length(coalesce(c.content -> 'source_coverage', '[]'::jsonb)),
        'final_control_count', (
          select count(*)
          from workflow.candidate_final_controls fc
          where fc.candidate_id = c.id
        )
      ) as entry
      from knowledge.candidates c
      join knowledge.claim_revisions r on r.id = c.claim_revision_id
      join knowledge.claims cl on cl.id = r.claim_id
      -- Bare kandidater kalleren faktisk har mandat til å se.
      where workflow.caller_is_active_reviewer(cl.topic_concept_id)
    ) as rows
  ), '[]'::jsonb);
end;
$$;

comment on function api.candidate_control_queue() is
  'Kandidatene kalleren har mandat til å lese, med nok til å velge én: påstanden, virkestoffet, temaet, sikkerhetsgraden, antall kilder og hvor mange sluttkontroller som allerede er registrert (ANTIDEP_CONSTITUTION.md regel 5). Viser bare kandidater der kalleren har gyldig reviewer-rolle for det kliniske begrepet; en kaller uten mandat får en tom liste framfor en feil, fordi en tom kø ikke er en avvisning. SECURITY DEFINER med tomt search_path fordi knowledge og workflow har RLS med default deny (§50).';

revoke execute on function api.candidate_control_queue() from public;
grant execute on function api.candidate_control_queue() to authenticated;
