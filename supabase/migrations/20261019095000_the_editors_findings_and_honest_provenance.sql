-- ---------------------------------------------------------------------------
-- Migrasjon 014a — redaktørens treff, og proveniensen agenten faktisk får se
--
-- To hull 013z åpnet, og de hang sammen med hverandre.
--
-- 1. Treffene fra en manuell passering kom ingen vei
--
-- `api.record_monograph_track_by_editor(..., 'covered', ...)` opprettet en
-- søkeloggrad og merket sporet dekket, men hadde ingen vei til å registrere
-- kildene søket faktisk fant. Den semantiske kildeoppgaven vurderer bare
-- `workflow.monograph_candidate_sources`. Et manuelt ClinicalTrials.gov-søk
-- kunne dermed registreres med fire treff og fire gjennomgått, uten at én
-- eneste av dem fantes som kandidat — og dekningen kunne likevel lukkes.
--
-- For et maskinelt søk finnes den veien: kjøringen sender kandidatene med.
-- For en manuell passering fantes den ikke, og nettopp der er det verst:
-- sporene Antidep ikke kan søke selv, er de eneste ingen annen leser. Treffene
-- ville forsvunnet stille.
--
-- Nå tar veien enten kandidatene passeringen ga, eller en uttrykkelig
-- attestasjon på at gjennomgangen ikke ga noen — og et positivt søk uten én av
-- delene holder dekningen åpen framfor å lukke den.
--
-- 2. Agenten fikk et menneskes arbeid presentert som maskinens
--
-- `workflow.monograph_discovery_task_input(...)` la *alle* radene fra
-- `workflow.monograph_searches` i feltet `machine_searches`, og oppgavefilen
-- renderer det feltet under «Søkene Antidep har utført» med setningen
-- «Antideps egen kode kalte endepunktet, leste svaret og registrerte et
-- fingeravtrykk av det».
--
-- Etter 013z inneholder tabellen også `editor_recorded`-rader, som nettopp ikke
-- har endepunkt, responsavtrykk eller kjøring. Agenten ville fått dem
-- presentert som maskinelt bekreftet utførelse, med «endepunkt: ikke
-- registrert» rett under en setning som sa at endepunktet ble kalt. Det er den
-- samme proveniensvaskingen 013v ble skrevet for å fjerne, bare med rollene
-- byttet om: nå var det mennesket som ble omtalt som maskinen.
--
-- De to radtypene er nå to felter, og oppgaven sier om hver av dem hva den er.
-- ---------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 1. Gjennomgangen som ikke ga kandidater, som en registrert opplysning
-- ----------------------------------------------------------------------------

alter table workflow.monograph_searches
  add column screening_note text;

alter table workflow.monograph_searches
  add constraint monograph_searches_screening_note_shape_check
    check (screening_note is null
           or (screening_note = btrim(screening_note)
               and length(screening_note) between 20 and 2000));

comment on column workflow.monograph_searches.screening_note is
  'Hva gjennomgangen av treffene ga, når en passering med treff ikke ga noen kandidatkilde. For et maskinelt søk leser den semantiske agenten de registrerte treffene selv; for et redaktørregistrert søk er redaktøren den eneste som så dem, og da er «ingen av treffene var relevante» en opplysning som må registreres framfor å være et fravær (SOURCE_POLICY.md §4.3).';

create or replace function workflow.monograph_discovery_task_input(
  p_plan_id uuid,
  p_role provenance.agent_role
)
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_edition knowledge.monograph_editions;
  v_profile knowledge.monograph_source_profiles;
  v_drug text;
  v_round integer;
  v_payload jsonb;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;
  if not found then
    return null;
  end if;

  select e.* into v_edition from knowledge.monograph_editions e where e.id = v_plan.edition_id;
  select sp.* into v_profile
  from knowledge.monograph_source_profiles sp where sp.id = v_plan.profile_id;
  select d.canonical_name into v_drug from catalog.drugs d where d.id = v_edition.drug_id;

  v_round := workflow.monograph_search_round(p_plan_id, p_role);

  v_payload := jsonb_build_object(
    'search_plan_id', v_plan.id,
    'plan_reference', v_plan.reference,
    'plan_version', v_plan.plan_version,
    'search_round', v_round,
    'rounds_remaining', greatest(4 - v_round, 0),
    'drug', v_drug,
    'standard_version', v_edition.standard_version,
    'source_profile', jsonb_build_object(
      'code', v_profile.code,
      'question', v_profile.question,
      'first_choice', v_profile.first_choice,
      'supplement_and_control', v_profile.supplement),
    'scope', jsonb_strip_nulls(jsonb_build_object(
      'drug', v_drug,
      'indication', (select c.canonical_label from catalog.clinical_concepts c
                     where c.id = v_plan.indication_concept_id),
      'outcome', (select c.canonical_label from catalog.clinical_concepts c
                  where c.id = v_plan.outcome_concept_id),
      'population', (select pop.canonical_label from catalog.populations pop
                     where pop.id = v_plan.population_id),
      'comparator', (select cd.canonical_name from catalog.drugs cd
                     where cd.id = v_plan.comparator_drug_id),
      'switch_target', (select td.canonical_name from catalog.drugs td
                        where td.id = v_plan.switch_target_drug_id),
      'labels', case when v_plan.scope_labels = '{}'::jsonb then null
                     else v_plan.scope_labels end)),
    -- Behovene, med spørsmålet ordrett fra standarden. Ingen forventet
    -- konklusjon, og ingen antydning om retning.
    'needs', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'need_reference', n.reference,
               'template', t.code,
               'section', t.section,
               'question', t.prompt,
               'requirement', t.requirement_text,
               'answer_form', n.answer_form::text) order by t.ordinal), '[]'::jsonb)
      from workflow.monograph_search_plan_needs pn
      join knowledge.monograph_needs n on n.id = pn.need_id
      join knowledge.monograph_question_templates t on t.id = n.template_id
      where pn.plan_id = v_plan.id),
    'required_tracks', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', k.code, 'label', k.label,
               'state', a.state::text, 'note', a.note) order by k.ordinal), '[]'::jsonb)
      from workflow.monograph_search_track_attempts a
      join knowledge.monograph_search_tracks k on k.id = a.track_id
      where a.plan_id = v_plan.id),
    -- Søkene Antidep faktisk utførte, med endepunkt og responsavtrykk. Dette
    -- er grunnlaget vurderingen gjelder, og det er maskinelt bekreftet
    -- utførelse og ikke noens beretning (SOURCE_POLICY.md §4.3).
    -- Bare Antideps egne kall. Et redaktørregistrert søk har verken endepunkt
    -- eller responsavtrykk, og å legge det her ville gitt agenten falsk
    -- proveniens: oppgaveteksten sier uttrykkelig at disse er maskinelt
    -- utførte (migrasjon 014a).
    'machine_searches', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'platform', s.platform,
               'query', s.query_string,
               'filters', s.filters,
               'outcome', s.outcome::text,
               'result_count', s.result_count,
               'screened_count', s.screened_count,
               'truncated', s.truncated,
               'truncation_note', s.truncation_note,
               'limitation_note', s.limitation_note,
               'endpoint', s.evidence_endpoint,
               'response_digest', s.response_digest,
               'execution_evidence', s.execution_evidence::text,
               'tracks', to_jsonb(s.track_codes),
               'executed_at', s.executed_at,
               'run_role', (select r.agent_role::text from provenance.agent_runs r
                            where r.id = s.agent_run_id))
               order by s.registration_ordinal), '[]'::jsonb)
      from workflow.monograph_searches s
      where s.plan_id = v_plan.id and s.plan_version = v_plan.plan_version
        and s.execution_evidence = 'machine_executed'),
    -- Og passeringene et menneske utførte og registrerte, hver for seg. De er
    -- like sanne, og de er noe annet: ingen kjøring, ingen adresse, intet
    -- avtrykk — en redaktørs dokumenterte arbeid, for et søkespor Antidep ikke
    -- har en maskinell vei til.
    'editor_searches', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'platform', s.platform,
               'query', s.query_string,
               'filters', s.filters,
               'outcome', s.outcome::text,
               'result_count', s.result_count,
               'screened_count', s.screened_count,
               'truncated', s.truncated,
               'truncation_note', s.truncation_note,
               'execution_evidence', s.execution_evidence::text,
               'tracks', to_jsonb(s.track_codes),
               'executed_at', s.executed_at,
               'screening_note', s.screening_note,
               'candidates_recorded', (
                 select count(*) from workflow.monograph_candidate_sources c
                 where c.search_id = s.id))
               order by s.registration_ordinal), '[]'::jsonb)
      from workflow.monograph_searches s
      where s.plan_id = v_plan.id and s.plan_version = v_plan.plan_version
        and s.execution_evidence = 'editor_recorded'),
    -- Og de søkeveiene som ikke svarte, hver for seg. En begrensning som bare
    -- sto som en rad i en lang liste, ville blitt lest som null treff.
    'search_limitations', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'platform', s.platform,
               'outcome', s.outcome::text,
               'limitation_note', s.limitation_note)
               order by s.registration_ordinal), '[]'::jsonb)
      from workflow.monograph_searches s
      where s.plan_id = v_plan.id and s.plan_version = v_plan.plan_version
        and s.outcome in ('unavailable', 'failed')),
    -- Kandidatkildene søkene ga. Vurderingen gjelder nøyaktig disse: en kilde
    -- som ikke står her, er ikke funnet av et søk, og skal ikke fylles inn fra
    -- hukommelsen.
    'candidates', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'identifier_kind', c.identifier_kind,
               'identifier_value', c.identifier_value,
               'title', c.title,
               'authors_or_issuer', c.authors_or_issuer,
               'publisher_or_journal', c.publisher_or_journal,
               'publication_year', c.publication_year,
               'discovery_path', c.discovery_path,
               'found_by_platform', (select s.platform from workflow.monograph_searches s
                                     where s.id = c.search_id),
               'decision', c.decision::text,
               'decision_reason', c.decision_reason,
               'access_limited', c.access_limited,
               'access_limitation_note', c.access_limitation_note,
               'could_change_conclusion', c.could_change_conclusion,
               'materiality_reason', c.materiality_reason,
               'uses', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'need_reference', n.reference,
                          'proposed_use', cn.proposed_use) order by n.reference), '[]'::jsonb)
                 from workflow.monograph_candidate_source_needs cn
                 join knowledge.monograph_needs n on n.id = cn.need_id
                 where cn.candidate_source_id = c.id))
               order by c.created_at), '[]'::jsonb)
      from workflow.monograph_candidate_sources c where c.plan_id = v_plan.id),
    -- Hva en søkeforespørsel kan be om. Listen er uttømmende med vilje: en
    -- forespørsel kan ikke oppgi en adresse, og en plattform ingen har
    -- vurdert, finnes ikke å be om (ANTIDEP_CONSTITUTION.md regel 7).
    'search_request_options', jsonb_build_object(
      'platforms', jsonb_build_array('Europe PMC', 'PubMed', 'Crossref'),
      'strategies', jsonb_build_array('broad', 'targeted'),
      'max_terms', 8,
      'max_drug_aliases', 8,
      'rounds_remaining', greatest(4 - v_round, 0)),
    -- Kriteriene for å avslutte, ordrett, og de fire grunnene som uttrykkelig
    -- ikke holder (SOURCE_POLICY.md §8).
    'closure_criteria', jsonb_build_object(
      'outstanding', workflow.monograph_search_closure_problem(v_plan.id),
      'requirements', jsonb_build_array(
        'Hvert obligatorisk søkespor for kildeprofilen må være forsøkt og dokumentert.',
        'Minst ett søk må faktisk ha gått. En utilgjengelig søkevei er en registrert begrensning og ikke null treff.',
        'Ingen avkortet treffliste kan stå igjen uten et oppfølgende søk på den samme plattformen.',
        'Ingen ulest eller utilgjengelig kilde som med rimelighet kan endre hovedkonklusjonen, kan stå uavklart.',
        'To ulike supplerende søkepasseringer uten nye potensielt konklusjonsendrende kilder — unntatt for de autoritative regulatoriske profilene, der én riktig, gjeldende kilde kan være nok.',
        'Den separate kontrollen av søkedekningen må godta begrunnelsen for å stoppe.'),
      'not_sufficient', jsonb_build_array(
        'At tre artikler er funnet.',
        'At to agenter er enige.',
        'At de første ti treffene er gjennomgått.',
        'At arbeidsbudsjettet er brukt opp. En oppbrukt ressursgrense gir åpent, ventende arbeid og aldri en konklusjon om evidensen.')),
    'rules', jsonb_build_array(
      'Søkene i denne oppgaven er utført av Antideps egen kode, mot navngitte offentlige søketjenester, og registrert med endepunkt og responsavtrykk. Du har ikke utført dem, og du skal ikke skrive som om du hadde.',
      'Du utfører ingen søk selv, og du trenger ingen nettilgang. Trengs det flere eller mer målrettede søk, ber du om dem som søkeforespørsler — Antidep utfører dem og gir deg neste vurderingsrunde.',
      'En kandidatkilde som ikke står i oppgaven, er ikke funnet av et søk. Ikke fyll inn en kilde fra hukommelsen: be heller om et søk som ville funnet den.',
      'En betalingsmur er en tilgangsbegrensning og ikke en faglig eksklusjonsgrunn. Sett slike kilder som «avventer tilgang» med en begrunnelse.',
      'En kilde godkjennes for en bestemt bruk og avgrensning, ikke universelt. Oppgi hva hver kilde kan brukes til for hvert behov.',
      'En søkevei som ikke svarte, står som en begrensning i oppgaven. Den er ikke null treff, og den er aldri en konklusjon om evidensen.'));

  if p_role = 'source_quality_assessment' then
    v_payload := v_payload || jsonb_build_object(
      'control_task', jsonb_build_object(
        'instruction', 'Kontroller søkedekningen. Antidep har utført dine egne, separat initierte motsøk med en annen strategi enn generatorens; vurder resultatene av dem, kontroller de sentrale eksklusjonene, og vurder vesentligheten av de kildene som står uavklarte. Godta begrunnelsen for å stoppe bare når kravene faktisk er oppfylt.',
        'own_search_rule', 'Uavhengigheten din er maskinelt utført og ikke erklært: Antidep har kjørt motsøkene under din egen rolle og din egen kjøring, og du kan verken oppgi eller bestride at de ble gjort. Vurder dem. Trengs det flere, be om dem som søkeforespørsler.',
        'independent_search_confirmed',
          workflow.monograph_control_searched_independently(v_plan.id),
        'own_countersearches', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'platform', s.platform,
                   'query', s.query_string,
                   'outcome', s.outcome::text,
                   'result_count', s.result_count,
                   'screened_count', s.screened_count,
                   'truncated', s.truncated,
                   'limitation_note', s.limitation_note,
                   'endpoint', s.evidence_endpoint,
                   'response_digest', s.response_digest)
                   order by s.registration_ordinal), '[]'::jsonb)
          from workflow.monograph_searches s
          join provenance.agent_runs r on r.id = s.agent_run_id
          where s.plan_id = v_plan.id
            and s.plan_version = v_plan.plan_version
            and s.execution_evidence = 'machine_executed'
            and r.agent_role = 'source_quality_assessment'::provenance.agent_role),
        'generator_searches', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'platform', s.platform,
                   'query', s.query_string,
                   'outcome', s.outcome::text,
                   'result_count', s.result_count,
                   'screened_count', s.screened_count,
                   'truncated', s.truncated)
                   order by s.registration_ordinal), '[]'::jsonb)
          from workflow.monograph_searches s
          join provenance.agent_runs r on r.id = s.agent_run_id
          where s.plan_id = v_plan.id
            and s.plan_version = v_plan.plan_version
            and r.agent_role = 'source_discovery'::provenance.agent_role),
        'excluded_candidates', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'identifier_kind', c.identifier_kind,
                   'identifier_value', c.identifier_value,
                   'title', c.title,
                   'decision_reason', c.decision_reason) order by c.created_at), '[]'::jsonb)
          from workflow.monograph_candidate_sources c
          where c.plan_id = v_plan.id and c.decision = 'excluded'),
        'unresolved_candidates', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'identifier_kind', c.identifier_kind,
                   'identifier_value', c.identifier_value,
                   'title', c.title,
                   'decision', c.decision::text,
                   'access_limited', c.access_limited,
                   'could_change_conclusion', c.could_change_conclusion,
                   'materiality_reason', c.materiality_reason) order by c.created_at), '[]'::jsonb)
          from workflow.monograph_candidate_sources c
          where c.plan_id = v_plan.id and c.decision not in ('included', 'excluded'))));
  end if;

  return v_payload;
end;
$$;
comment on function workflow.monograph_discovery_task_input(uuid, provenance.agent_role) is
  'Oppgavematerialet til de to kildeleddene: de maskinelt utførte søkene med endepunkt og responsavtrykk, de redaktørregistrerte passeringene hver for seg, søkeveiene som ikke svarte, kandidatkildene søkene ga, og hvilke søk runden kan be om. Machine_searches og editor_searches er to felter og ikke ett: et menneskes dokumenterte arbeid har verken endepunkt, responsavtrykk eller kjøring, og å legge det blant Antideps egne kall ville gitt agenten falsk proveniens om nettopp det skillet resten av kjeden hviler på (migrasjon 014a).';

revoke execute on function workflow.monograph_discovery_task_input(uuid, provenance.agent_role) from public;

-- ----------------------------------------------------------------------------
-- 3. Porten: en manuell passering med treff kan ikke stå uavklart
-- ----------------------------------------------------------------------------

create or replace function workflow.monograph_search_closure_problem(p_plan_id uuid)
  returns text
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_pending text;
  v_no_path text;
  v_count integer;
  v_last_candidate_ordinal bigint;
  v_control workflow.monograph_coverage_controls;
  v_unresolved text;
  v_open_truncation text;
  v_open_screening text;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.id = p_plan_id;

  if not found then
    return 'Søkeplanen finnes ikke.';
  end if;

  -- 0. Et oppbrukt budsjett er åpent arbeid, ikke en ferdig søkedekning.
  if v_plan.paused_at is not null then
    return format(
      'Søket står på pause og er ikke ferdig: %s. En oppbrukt ressursgrense gir åpent, ventende arbeid og aldri en konklusjon om evidensen.',
      v_plan.paused_reason);
  end if;

  -- 1. Planen skal dekke minst ett behov.
  select count(*) into v_count
  from workflow.monograph_search_plan_needs n where n.plan_id = p_plan_id;
  if v_count = 0 then
    return 'Søkeplanen dekker ikke noe kunnskapsbehov.';
  end if;

  -- 2. Hvert obligatorisk søkespor skal være forsøkt og dokumentert.
  select string_agg(t.label, '; ' order by t.ordinal) into v_pending
  from workflow.monograph_search_track_attempts a
  join knowledge.monograph_search_tracks t on t.id = a.track_id
  where a.plan_id = p_plan_id and a.state = 'pending';
  if v_pending is not null then
    return format(
      'Disse obligatoriske søkesporene er ikke forsøkt ennå: %s. Et spor som ikke er forsøkt, hindrer at søkedekningen kan erklæres ferdig (SOURCE_POLICY.md §4.2).',
      v_pending);
  end if;

  -- 2b. Et spor ingen registrert søkevei dekker, er dokumentert, men ikke
  --     forsøkt. Det kan ikke telle som dekning — da ville porten sagt «dekket»
  --     om et spor ingen har søkt i, som er nøyaktig feilen 013v fjernet. Men
  --     det kan heller ikke bli stående som en stillhet: her står det hvilke
  --     spor det gjelder og hva som løser dem.
  select string_agg(t.label, '; ' order by t.ordinal) into v_no_path
  from workflow.monograph_search_track_attempts a
  join knowledge.monograph_search_tracks t on t.id = a.track_id
  where a.plan_id = p_plan_id and a.state = 'no_machine_path';
  if v_no_path is not null then
    return format(
      'Ingen av Antideps registrerte søkeveier dekker disse obligatoriske søkesporene: %s. Sporet er dokumentert, men ikke forsøkt, og et forsøk som ikke er gjort, kan ikke telle som dekning. En redaktør registrerer utfallet med api.record_monograph_track_by_editor(...) — enten søket hun har gjort, eller hvorfor sporet ikke var tilgjengelig (SOURCE_POLICY.md §4.2).',
      v_no_path);
  end if;

  -- 3. Minst ett søk må faktisk ha gått.
  select count(*) into v_count
  from workflow.monograph_searches s
  where s.plan_id = p_plan_id
    and s.plan_version = v_plan.plan_version
    and s.outcome in ('executed', 'zero_results');
  if v_count = 0 then
    return 'Ingen søk i denne planversjonen har faktisk gått. En utilgjengelig søkevei er en registrert begrensning og ikke en gjennomført søkedekning (SOURCE_POLICY.md §8.2).';
  end if;

  -- 4. Ingen skjult treffavkorting.
  select string_agg(distinct s.platform, ', ' order by s.platform) into v_open_truncation
  from workflow.monograph_searches s
  where s.plan_id = p_plan_id
    and s.plan_version = v_plan.plan_version
    and s.truncated
    and not exists (
      select 1 from workflow.monograph_searches later
      where later.plan_id = s.plan_id
        and later.plan_version = s.plan_version
        and later.platform = s.platform
        and not later.truncated
        and later.outcome in ('executed', 'zero_results')
        and later.registration_ordinal > s.registration_ordinal
    );
  if v_open_truncation is not null then
    return format(
      'Trefflisten ble avkortet på %s uten at et senere søk dekket resten. En side med ti treff er ikke et søk uten flere treff (SOURCE_POLICY.md §4.3).',
      v_open_truncation);
  end if;

  -- 5. Ingen uavklart kilde som med rimelighet kan endre hovedkonklusjonen.
  select string_agg(c.title, '; ' order by c.title) into v_unresolved
  from workflow.monograph_candidate_sources c
  where c.plan_id = p_plan_id
    and c.could_change_conclusion
    and c.decision not in ('included', 'excluded');
  if v_unresolved is not null then
    return format(
      'Disse kildene kan endre hovedkonklusjonen og er fortsatt uavklarte: %s. En ulest eller utilgjengelig kilde som med rimelighet kan endre svaret, hindrer at søket kan avsluttes (SOURCE_POLICY.md §8.1).',
      v_unresolved);
  end if;

  -- 5b. En manuell passering som ga treff, må enten ha gitt kandidatkilder
  --     eller bære en registrert gjennomgang. For et maskinelt søk leser den
  --     semantiske agenten de registrerte treffene selv; en manuell passering
  --     er det bare redaktøren som har sett, og treffene ville forsvunnet
  --     stille mellom en søkelogg som sa «fire treff, fire gjennomgått» og en
  --     kandidatliste som var tom.
  select string_agg(format('%s (%s treff)', s.platform, s.result_count), '; '
                    order by s.registration_ordinal) into v_open_screening
  from workflow.monograph_searches s
  where s.plan_id = p_plan_id
    and s.plan_version = v_plan.plan_version
    and s.execution_evidence = 'editor_recorded'
    and coalesce(s.result_count, 0) > 0
    and s.screening_note is null
    and not exists (
      select 1 from workflow.monograph_candidate_sources c
      where c.search_id = s.id);
  if v_open_screening is not null then
    return format(
      'Disse manuelt utførte søkepasseringene ga treff, men verken en kandidatkilde eller en registrert gjennomgang: %s. Treffene er sett av én person, og en dekning som lukkes her, mister dem stille (SOURCE_POLICY.md §4.3).',
      v_open_screening);
  end if;

  -- 6. Metningssignalet: to supplerende søkepasseringer uten nye kilder.
  --    Gjelder de profilene som faktisk søker i litteraturen. De autoritative
  --    regulatoriske profilene kan klare seg med én riktig, gjeldende kilde, og
  --    sammendragsleddet gjør ingen selvstendig litteraturjakt (§4.2, §8.1) —
  --    å kreve to søkepasseringer av et ledd som ikke søker, er et krav som
  --    aldri kan oppfylles.
  if workflow.monograph_profile_searches_literature(v_plan.profile_id) then
    select max(s.registration_ordinal) into v_last_candidate_ordinal
    from workflow.monograph_searches s
    join workflow.monograph_candidate_sources c on c.search_id = s.id
    where c.plan_id = p_plan_id;

    if exists (
      select 1 from workflow.monograph_candidate_sources c
      where c.plan_id = p_plan_id and c.search_id is null
        and c.created_at > coalesce(
          (select s.created_at from workflow.monograph_searches s
           where s.plan_id = p_plan_id
             and s.plan_version = v_plan.plan_version
             and s.outcome in ('executed', 'zero_results')
           order by s.registration_ordinal desc limit 1),
          '-infinity'::timestamptz)
    ) then
      return 'En kandidatkilde er lagt til etter siste søkepassering. Metningssignalet krever to supplerende passeringer uten nye potensielt konklusjonsendrende kilder (SOURCE_POLICY.md §8.1).';
    end if;

    select count(distinct s.platform) into v_count
    from workflow.monograph_searches s
    where s.plan_id = p_plan_id
      and s.plan_version = v_plan.plan_version
      and s.outcome in ('executed', 'zero_results')
      and (v_last_candidate_ordinal is null
           or s.registration_ordinal > v_last_candidate_ordinal);

    if v_count < 2 then
      return 'Metningssignalet mangler: to ulike supplerende søkepasseringer uten nye potensielt konklusjonsendrende kilder er ikke gjennomført. Dette er Antideps v1-heuristikk og ikke et bevis på uttømmende dekning, men verken «tre artikler er funnet» eller «de første ti treffene er gjennomgått» erstatter den (SOURCE_POLICY.md §8.1).';
    end if;
  end if;

  -- 7. Og den separate kontrollen må godta begrunnelsen for å stoppe.
  select cc.* into v_control
  from workflow.monograph_coverage_controls cc
  where cc.plan_id = p_plan_id and cc.plan_version = v_plan.plan_version;

  if not found then
    return 'Den separate kontrollen av søkedekningen er ikke utført for denne planversjonen. Enighet mellom agenter er ikke i seg selv fasit, og et kontrollledd som bare leser generatorens valgte referanser, kan ikke vurdere dekningsgraden (SOURCE_POLICY.md §6, §8.1).';
  end if;

  if v_control.outcome <> 'accepted' then
    return format(
      'Den separate kontrollen av søkedekningen godtar ikke begrunnelsen for å stoppe: %s',
      v_control.note);
  end if;

  return null;
end;
$$;



comment on function workflow.monograph_search_closure_problem(uuid) is
  'Én setning om hva som hindrer at søkedekningen kan erklæres ferdig, eller NULL. Er de konkrete stoppkravene i SOURCE_POLICY.md §8.1 som en port: planen må dekke et behov, hvert obligatorisk søkespor må være forsøkt og dokumentert, spor ingen registrert søkevei dekker må være avklart av en redaktør, minst ett søk må faktisk ha gått, ingen avkortet treffliste kan stå igjen udekket, ingen uavklart kilde som kan endre hovedkonklusjonen kan stå åpen, ingen manuell passering med treff kan stå uten kandidatkilder eller en registrert gjennomgang, metningssignalet må være gitt — for de profilene som faktisk søker i litteraturen — og den separate dekningskontrollen må godta begrunnelsen. Et oppbrukt arbeidsbudsjett gir åpent arbeid og aldri en ferdig dekning (§8.2). Porten kan ikke overstyres: verken tre funne artikler, to enige agenter, ti gjennomgåtte treff eller et brukt budsjett er en av kravene.';

-- ----------------------------------------------------------------------------
-- 4. Redaktørveien tar imot treffene passeringen faktisk ga
-- ----------------------------------------------------------------------------

drop function api.record_monograph_track_by_editor(
  text, text, text, text, text, text, text, timestamptz, integer, integer, boolean, text);

create function api.record_monograph_track_by_editor(
  p_plan_reference text,
  p_track_code text,
  p_outcome text,
  p_note text,
  p_platform text default null,
  p_query_string text default null,
  p_filters text default null,
  p_executed_at timestamptz default null,
  p_result_count integer default null,
  p_screened_count integer default null,
  p_truncated boolean default false,
  p_truncation_note text default null,
  p_candidates jsonb default null,
  p_screening_note text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_plan workflow.monograph_search_plans;
  v_edition knowledge.monograph_editions;
  v_track_id uuid;
  v_attempt workflow.monograph_search_track_attempts;
  v_search_id uuid;
  v_outcome workflow.monograph_search_outcome;
  v_candidate jsonb;
  v_unknown text;
  v_recorded integer := 0;
  v_candidate_count integer := 0;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if p_outcome not in ('covered', 'unavailable') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%L er ikke et utfall for et søkespor.', p_outcome),
      hint = 'En redaktør registrerer enten covered — søket er gjort, og passeringen føres i søkeloggen sammen med sporet — eller unavailable, med begrunnelsen for hvorfor sporet ikke kunne dekkes. Et spor kan ikke settes tilbake til pending for hånd: registeret over søkeveier avgjør selv om en maskinell vei finnes.';
  end if;

  if p_note is null or length(btrim(p_note)) < 20 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et søkespor avklart for hånd krever en begrunnelse på minst 20 tegn.',
      hint = 'Begrunnelsen er det eneste sporet av hva mennesket faktisk gjorde. «ok» dokumenterer ingenting.';
  end if;

  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.reference = p_plan_reference
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen finnes ikke.';
  end if;

  if v_plan.closed_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Søkeplanen er erklært ferdig, og søkeloggen står.';
  end if;

  select e.* into v_edition
  from knowledge.monograph_editions e where e.id = v_plan.edition_id;

  select k.id into v_track_id
  from knowledge.monograph_search_tracks k
  where k.standard_version = v_edition.standard_version and k.code = p_track_code;

  if v_track_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('%L er ikke et søkespor i denne standardversjonen.', p_track_code);
  end if;

  select a.* into v_attempt
  from workflow.monograph_search_track_attempts a
  where a.plan_id = v_plan.id and a.track_id = v_track_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Sporet er ikke obligatorisk for denne planens kildeprofil.';
  end if;

  -- Bare spor uten maskinell vei. Et spor maskinen kan søke i, skal maskinen
  -- søke i: en redaktør som kunne erklære hvilket som helst spor dekket, ville
  -- vært en vei rundt hele den maskinelle søkefasen.
  if v_attempt.state <> 'no_machine_path' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Sporet står som %s og trenger ingen avklaring for hånd.', v_attempt.state),
      hint = 'Redaktørens vei gjelder bare spor ingen registrert søkevei dekker. Et pending spor venter på den maskinelle søkefasen, og et covered eller unavailable spor er allerede ført.';
  end if;

  if p_outcome = 'unavailable' then
    update workflow.monograph_search_track_attempts
    set state = 'unavailable', search_id = null, note = btrim(p_note),
        resolved_by_actor_id = v_actor_id
    where id = v_attempt.id;

    return jsonb_build_object(
      'plan_reference', v_plan.reference,
      'track_code', p_track_code,
      'state', 'unavailable',
      'search_recorded', false,
      'closure_problem', workflow.monograph_search_closure_problem(v_plan.id));
  end if;

  -- «Dekket» er nå en dokumentert passering og ikke en peker til en tilfeldig
  -- eksisterende rad. SOURCE_POLICY.md §4.3 krever plattform, eksakt
  -- søkestreng, filtre, tidspunkt og treffantall for det *utførte* søket — og
  -- før 013z pekte veien på den siste raden på planen uansett hvilket spor den
  -- gjaldt.
  if p_platform is null or length(btrim(p_platform)) < 2 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et dekket spor krever søkeveien passeringen faktisk gikk mot.',
      hint = 'Søkeloggen skal kunne leses av en fagperson: hvor det ble søkt, med hvilken streng, når, og hvor mange treff det ga (SOURCE_POLICY.md §4.3).';
  end if;

  if p_query_string is null or length(btrim(p_query_string)) < 2 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et dekket spor krever den eksakte søkestrengen passeringen brukte.',
      hint = 'En beskrivelse av et søk er ikke et søk. Strengen er det som gjør passeringen etterprøvbar.';
  end if;

  if p_executed_at is null or p_executed_at > now() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et dekket spor krever tidspunktet passeringen faktisk ble utført.',
      hint = 'Et søk uten tidspunkt kan ikke vurderes for aktualitet, og et tidspunkt i framtiden er ikke et utført søk.';
  end if;

  if p_result_count is null or p_result_count < 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et dekket spor krever treffantallet passeringen ga.',
      hint = 'Null treff er et resultat og registreres som 0. Ingen verdi er ikke null treff (SOURCE_POLICY.md §8.2).';
  end if;

  if p_candidates is not null then
    if jsonb_typeof(p_candidates) <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kandidatlisten er ikke en JSON-liste.';
    end if;
    v_candidate_count := jsonb_array_length(p_candidates);
  end if;

  -- En passering som ga treff, må enten gi kandidatkildene den fant, eller si
  -- hva gjennomgangen ga. For et maskinelt søk leser den semantiske agenten de
  -- registrerte treffene selv; her er redaktøren den eneste som har sett dem,
  -- og «fire treff, fire gjennomgått, null kandidater» uten en setning om
  -- hvorfor, er treff som forsvinner stille (SOURCE_POLICY.md §4.3).
  if p_result_count > 0 and v_candidate_count = 0
     and (p_screening_note is null or length(btrim(p_screening_note)) < 20) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En passering med treff må enten gi kandidatkildene den fant, eller si hva gjennomgangen ga.',
      hint = 'Oppgi p_candidates med kildene som er verdt å vurdere, eller p_screening_note med minst 20 tegn om hvorfor ingen av treffene ble kandidater. Et tomt felt er ikke det samme som «ingen relevante treff».';
  end if;

  -- Et kontrollert nullsøk er `zero_results`, og det kan ikke være avkortet.
  v_outcome := case when p_result_count = 0
                    then 'zero_results'::workflow.monograph_search_outcome
                    else 'executed'::workflow.monograph_search_outcome end;

  insert into workflow.monograph_searches (
    plan_id, plan_version, platform, query_string, filters, executed_at,
    result_count, screened_count, truncated, truncation_note,
    outcome, execution_evidence, track_codes, recorded_by_actor_id,
    screening_note
  )
  values (
    v_plan.id, v_plan.plan_version, btrim(p_platform), btrim(p_query_string),
    nullif(btrim(coalesce(p_filters, '')), ''), p_executed_at,
    p_result_count, coalesce(p_screened_count, p_result_count),
    coalesce(p_truncated, false),
    nullif(btrim(coalesce(p_truncation_note, '')), ''),
    v_outcome, 'editor_recorded'::workflow.monograph_execution_evidence,
    array[p_track_code], v_actor_id,
    nullif(btrim(coalesce(p_screening_note, '')), '')
  )
  returning id into v_search_id;

  -- Kandidatene passeringen ga, bundet til nøyaktig denne raden. Samme
  -- kontrakt som det maskinelle søket bruker: ukjente felter avvises framfor å
  -- ignoreres.
  if v_candidate_count > 0 then
    for v_candidate in select value from jsonb_array_elements(p_candidates) loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_candidate) as k(value)
      where k.value not in (
        'identifier_kind', 'identifier_value', 'title', 'authors_or_issuer',
        'publisher_or_journal', 'publication_year', 'discovery_path',
        'access_limited', 'access_limitation_note',
        'could_change_conclusion', 'materiality_reason'
      );
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('Kandidatkilden har felter denne kontrakten ikke kjenner: %s.', v_unknown),
          hint = 'Ukjente felter avvises framfor å ignoreres: et felt med skrivefeil ville ellers sett ut som en utelatt opplysning.';
      end if;

      if workflow.record_monograph_candidate_source(
           v_plan.id, v_search_id,
           v_candidate ->> 'identifier_kind',
           v_candidate ->> 'identifier_value',
           v_candidate ->> 'title',
           v_candidate ->> 'authors_or_issuer',
           v_candidate ->> 'publisher_or_journal',
           (v_candidate ->> 'publication_year')::integer,
           coalesce(v_candidate ->> 'discovery_path',
                    format('Manuelt søk i %s, utført og registrert av en redaktør', btrim(p_platform))),
           coalesce((v_candidate ->> 'access_limited')::boolean, false),
           v_candidate ->> 'access_limitation_note',
           coalesce((v_candidate ->> 'could_change_conclusion')::boolean, false),
           v_candidate ->> 'materiality_reason',
           null, v_actor_id) is not null then
        v_recorded := v_recorded + 1;
      end if;
    end loop;
  end if;

  update workflow.monograph_search_track_attempts
  set state = 'covered', search_id = v_search_id, note = btrim(p_note),
      resolved_by_actor_id = v_actor_id
  where id = v_attempt.id;

  return jsonb_build_object(
    'plan_reference', v_plan.reference,
    'track_code', p_track_code,
    'state', 'covered',
    'search_recorded', true,
    'candidates_recorded', v_recorded,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan.id));
end;
$$;


comment on function api.record_monograph_track_by_editor(text, text, text, text, text, text, text, timestamptz, integer, integer, boolean, text, jsonb, text) is
  'Lar en redaktør registrere utfallet av et obligatorisk søkespor ingen av Antideps registrerte søkeveier dekker. Gjelder bare spor som står som no_machine_path: et spor maskinen kan søke i, skal maskinen søke i. Utfallet unavailable krever en begrunnelse. Utfallet covered fører selve passeringen inn i søkeloggen som en egen rad med editor_recorded som utførelsesbevis — plattform, eksakt søkestreng, filtre, tidspunkt, treffantall og eventuell avkorting (SOURCE_POLICY.md §4.3) — og knytter sporet til nøyaktig den raden. Ga passeringen treff, må den enten gi kandidatkildene den fant, eller si hva gjennomgangen ga: for et maskinelt søk leser den semantiske agenten de registrerte treffene selv, mens en manuell passering er det bare redaktøren som har sett, og treffene ville ellers forsvunnet stille (014a). Krever editor-mandat, og aktøren føres på søket, sporet og hver kandidat.';

revoke execute on function api.record_monograph_track_by_editor(text, text, text, text, text, text, text, timestamptz, integer, integer, boolean, text, jsonb, text) from public;
grant execute on function api.record_monograph_track_by_editor(text, text, text, text, text, text, text, timestamptz, integer, integer, boolean, text, jsonb, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Kontrakten: oppgaveformen har fått et felt, og malen teller det
-- ----------------------------------------------------------------------------

create or replace function workflow.agent_task_contract(p_agent_role provenance.agent_role)
  returns jsonb
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
    -- Promptmalene står på /2 fra migrasjon 013u: den delte delen av
    -- oppgaveteksten ble skrevet om for alle seks rollene i den samme
    -- endringen. Svarformene er uendret — `result` er det samme som før.
    when 'evidence_extraction' then jsonb_build_object(
      'prompt_template_version', 'evidence-extraction/handoff-drafting/2',
      'output_schema_version', 'antidep/extraction-draft@1'
    )
    when 'claim_synthesis' then jsonb_build_object(
      'prompt_template_version', 'claim-synthesis/handoff-drafting/2',
      'output_schema_version', 'antidep/claim-synthesis-draft@1'
    )
    when 'evidence_assessment' then jsonb_build_object(
      'prompt_template_version', 'evidence-assessment/handoff-drafting/2',
      'output_schema_version', 'antidep/evidence-assessment-draft@1'
    )
    -- Migrasjon 013v: kildeleddene vurderer maskinelt utførte søk og ber om
    -- flere som strukturerte søkeforespørsler. De rapporterer ikke lenger søk,
    -- og `searches` finnes ikke i noen av de to svarformene.
    --
    -- Migrasjon 014a: oppgaven skiller nå Antideps egne kall fra passeringene
    -- en redaktør utførte. Svarformene er uendret — det er materialet agenten
    -- leser som har fått et felt til, og det er promptmalen som teller det.
    when 'source_discovery' then jsonb_build_object(
      'prompt_template_version', 'source-discovery/machine-search-appraisal/4',
      'output_schema_version', 'antidep/source-discovery-draft@3'
    )
    when 'source_quality_assessment' then jsonb_build_object(
      'prompt_template_version', 'source-coverage/machine-countersearch-control/4',
      'output_schema_version', 'antidep/source-coverage-control-draft@2'
    )
    -- Migrasjon 013i: svaret på et behov som hviler på et myndighets-,
    -- preparat- eller retningslinjedokument. Den deterministiske
    -- svarkontrollen står bevisst ikke her: den er Antideps egen kode.
    when 'monograph_answer' then jsonb_build_object(
      'prompt_template_version', 'monograph-answer/handoff-fact/2',
      'output_schema_version', 'antidep/monograph-answer-draft@1'
    )
    else null
  end;
$$;

comment on function workflow.agent_task_contract(provenance.agent_role) is
  'Hvilken promptmal og hvilket svarformat hvert agentledd arbeider etter. Kildeleddenes maler er på versjon 4 fra migrasjon 014a: oppgavematerialet skiller Antideps egne kall fra passeringene en redaktør utførte, slik at agenten ikke får et menneskes arbeid presentert som maskinelt bekreftet utførelse. Svarformene er uendret.';
