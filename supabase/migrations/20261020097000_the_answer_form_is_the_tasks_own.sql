-- ============================================================================
-- Migrasjon 014i — svarformen er oppgavens egen
--
-- Kildeoppdagelsen fungerer ende til ende i produksjon. De to første
-- vellykkede kjøringene behandlet tre oppgaver hver: én ble importert, to ble
-- avvist, og de samme to feilklassene gjentok seg. Kontrollen gjorde rett i å
-- avvise begge. Feilen var at svarformen gjorde det gale svaret like lett å
-- skrive som det riktige.
--
-- 1. En tilgangsbegrenset kandidatkilde ble satt til «excluded». Regelen på
--    raden er en tilstandsregel: en kilde med registrert tilgangsbegrensning
--    kan ikke ekskluderes, uansett grunn (SOURCE_POLICY.md §4.3, §8.2, og
--    beskrankningen på raden fra migrasjon 013e). Oppgaven sa den
--    som en regel om begrunnelsen — «en betalingsmur er ikke en faglig
--    eksklusjonsgrunn» — og svarformen tilbød «excluded» for hver kilde. En
--    agent som forkastet et treff som irrelevant, trodde den fulgte regelen.
--    Og nesten hver kandidat er tilgangsbegrenset: PubMed og Crossref sier
--    ingenting om tilgang, så hvert treff derfra er det.
--
-- 2. En søkeforespørsel oppga i narrows_request en runde som ikke er dette
--    leddets. Søkene i oppgaven er begge kildeleddenes: kildeoppdagelsen ser
--    dekningskontrollens motsøk, og kontrollen ser generatorens søk. Ved hvert
--    avkortet søk skrev oppgaven «narrows_request: <referanse>» — også ved det
--    andre leddets — mens importen, med rette, bare godtar en runde bestilt for
--    leddet selv. Svarformen sa bare «32 heksadesimale tegn».
--
-- Rettingen er at oppgaven sier nøyaktig hva som kan oppgis, og at svarformen
-- bygges av det:
--
--   * `workflow.monograph_narrowable_rounds(...)` er rundene dette leddet kan
--     erstatte med et smalere søk på denne planversjonen: bestilt for leddet
--     selv, med et avkortet maskinelt søk som ingen senere runde har dekket —
--     hver med den plattformen og metoden erstatningen må bruke, og som
--     importens egen metodekontroll godtar. Oppgaven bærer listen
--     (`narrowable_rounds`), og svarformen tillater bare disse referansene,
--     og ingen når listen er tom.
--   * Svarformen lister kandidatkildene oppgaven har, og tilbyr ikke
--     «excluded» for en kilde med registrert tilgangsbegrensning. Det leses av
--     `access_limited` på kandidaten, som oppgaven alt bærer.
--   * Promptmalene og svarformene får nye versjoner: en svarform bygget for
--     én oppgave er en annen form enn den faste, og et svar avgitt under den
--     gamle skal ikke kunne importeres på en oppgave bygget under den nye.
--
-- Importens kontroller er uendret. `workflow.record_monograph_discovery_answer
-- (workflow.pipeline_jobs, jsonb, jsonb, uuid, uuid)` avviser fortsatt en
-- runde som ikke er leddets, og raden avviser fortsatt en eksklusjon av en
-- tilgangsbegrenset kilde. Svarformen gjør det riktige svaret til det
-- naturlige; databasen er fortsatt grensen.
--
-- Ingen rader skrives om. Oppgavematerialet bygges når oppgaven leses, så
-- også en oppgave som alt står i køen, får listen.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Rundene et kildeledd kan erstatte med et smalere søk
-- ----------------------------------------------------------------------------

create function workflow.monograph_narrowable_rounds(
  p_plan_id uuid,
  p_role provenance.agent_role
)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'request_reference', n.reference,
           'platform', n.platform,
           'method', n.method,
           'queries', to_jsonb(n.queries))
           order by n.first_ordinal, n.platform, n.method), '[]'::jsonb)
  from (
    select r.reference,
           s.platform,
           coalesce(s.search_method, 'keyword') as method,
           array_agg(distinct s.query_string order by s.query_string) as queries,
           min(s.registration_ordinal) as first_ordinal
    from workflow.monograph_search_plans p
    join workflow.monograph_searches s
      on s.plan_id = p.id and s.plan_version = p.plan_version
    join workflow.monograph_search_requests r on r.id = s.search_request_id
    where p.id = p_plan_id
      -- Den samme avgrensningen importen håndhever: en runde på denne planen,
      -- denne planversjonen og for dette leddet.
      and r.plan_id = p.id
      and r.plan_version = p.plan_version
      and r.requested_for_role = p_role
      -- Og bare der det faktisk er noe å erstatte: et avkortet maskinelt søk
      -- som ingen senere runde har dekket resten av.
      and s.execution_evidence = 'machine_executed'
      and s.truncated
      and not workflow.monograph_truncation_resolved(s)
      -- Erstatningen må bruke den samme plattformen og metoden, og den må
      -- passere importens egen metodekontroll mot runden den erstatter.
      and exists (
        select 1
        from workflow.monograph_request_methods(s.platform, coalesce(s.search_method, 'keyword')) a
        join workflow.monograph_request_methods(r.platform, r.method) b
          on b.platform = a.platform and b.method = a.method)
    group by r.reference, s.platform, coalesce(s.search_method, 'keyword')
  ) n;
$$;

comment on function workflow.monograph_narrowable_rounds(uuid, provenance.agent_role) is
  'De søkerundene ett kildeledd kan erstatte med et smalere søk på søkeplanens gjeldende versjon: bestilt for leddet selv, med et avkortet maskinelt søk som ingen senere runde har dekket resten av. Én rad per (runde, plattform, metode), med søkestrengene som ble avkortet. Plattformen og metoden er de erstatningen må bruke, og de passerer importens egen metodekontroll. Oppgavematerialet bærer listen (narrowable_rounds), og svarformen tillater bare disse referansene i narrows_request — ingen når listen er tom (migrasjon 014i).';

revoke execute on function workflow.monograph_narrowable_rounds(uuid, provenance.agent_role) from public;

-- ----------------------------------------------------------------------------
-- 2. Oppgavematerialet bærer rundene, og reglene sier det som raden håndhever
--
-- Funksjonskroppen er den fra migrasjon 014d, med tre endringer: feltet
-- narrowable_rounds, regelen om tilgangsbegrensning sagt som den tilstandsregelen
-- den er, og regelen om avkorting sagt med listen.
-- ----------------------------------------------------------------------------

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
    -- Sporene, med hvilke av Antideps søkemetoder som utfører hvert av dem for
    -- denne profilen. Et spor uten en metode står med sin begrunnelse; et spor
    -- som følger sentrale kilder, sier det (migrasjon 014d).
    'required_tracks', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', k.code, 'label', k.label,
               'state', a.state::text, 'note', a.note,
               'machine_methods', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'platform', m.platform, 'method', m.method,
                          'follows_central_sources', m.requires_seeds)
                          order by m.platform, m.method), '[]'::jsonb)
                 from knowledge.monograph_search_platforms c
                 join knowledge.monograph_search_methods m
                   on m.platform = c.platform and m.method = c.method
                 where c.track_code = k.code
                   and (c.profile_codes is null or v_profile.code = any (c.profile_codes))))
               order by k.ordinal), '[]'::jsonb)
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
               'method', coalesce(s.search_method, 'keyword'),
               'query', s.query_string,
               'filters', s.filters,
               'outcome', s.outcome::text,
               'result_count', s.result_count,
               'screened_count', s.screened_count,
               'truncated', s.truncated,
               'truncation_note', s.truncation_note,
               -- Om resten av en avkortet treffliste er dekket, og hvilken runde
               -- søket hørte til. Hvilke runder dette leddet kan erstatte, står
               -- i narrowable_rounds og ikke her: søkene er begge leddenes.
               'truncation_resolved', workflow.monograph_truncation_resolved(s),
               'request_reference', (select r.reference from workflow.monograph_search_requests r
                                     where r.id = s.search_request_id),
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
    -- Rundene nettopp dette leddet kan erstatte med et smalere søk, med den
    -- plattformen og metoden erstatningen må bruke (migrasjon 014i). Svarformen
    -- bygges av denne listen: en referanse som ikke står her, finnes ikke å
    -- oppgi, og står den tom, har forespørselen ikke noe narrows_request-felt.
    'narrowable_rounds', workflow.monograph_narrowable_rounds(v_plan.id, p_role),
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
               -- Søket som fant kilden for nettopp denne planen. En kilde en
               -- annen plan fant først, er funnet her også (migrasjon 014c).
               'found_by_platform', (select s.platform from workflow.monograph_searches s
                                     where s.id = coalesce(l.search_id, c.search_id)),
               'found_by_method', (select coalesce(s.search_method, 'keyword')
                                   from workflow.monograph_searches s
                                   where s.id = coalesce(l.search_id, c.search_id)
                                     and s.execution_evidence = 'machine_executed'),
               'decision', l.decision::text,
               'decision_reason', l.decision_reason,
               'access_limited', c.access_limited,
               'access_limitation_note', c.access_limitation_note,
               'could_change_conclusion', l.could_change_conclusion,
               'materiality_reason', l.materiality_reason,
               'uses', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'need_reference', n.reference,
                          'proposed_use', cn.proposed_use) order by n.reference), '[]'::jsonb)
                 from workflow.monograph_candidate_source_needs cn
                 join knowledge.monograph_needs n on n.id = cn.need_id
                 where cn.candidate_source_id = c.id
                   -- Bare planens egne forslag: bruken en annen plan har
                   -- foreslått, er den planens (migrasjon 014c).
                   and (cn.plan_id = v_plan.id
                        or (cn.plan_id is null and exists (
                              select 1 from workflow.monograph_search_plan_needs pn
                              where pn.plan_id = v_plan.id and pn.need_id = cn.need_id)))))
               order by c.created_at), '[]'::jsonb)
      from workflow.monograph_candidate_sources c
      join workflow.monograph_candidate_source_plans l
        on l.candidate_source_id = c.id and l.plan_id = v_plan.id),
    -- Hva en søkeforespørsel kan be om. Listen er uttømmende med vilje: en
    -- forespørsel kan ikke oppgi en adresse, og en plattform ingen har
    -- vurdert, finnes ikke å be om (ANTIDEP_CONSTITUTION.md regel 7).
    'search_request_options', jsonb_build_object(
      -- Fra registeret, ikke skrevet av. En plattform ingen har vurdert,
      -- finnes ikke å be om, og en som er registrert, skal ikke mangle her.
      'platforms', (select coalesce(jsonb_agg(distinct m.platform), '[]'::jsonb)
                    from knowledge.monograph_search_methods m),
      'methods', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'platform', m.platform,
                 'method', m.method,
                 'follows_central_sources', m.requires_seeds,
                 'seed_identifier_kinds', to_jsonb(m.seed_identifier_kinds),
                 'default_when_no_method_is_named', m.default_for_requests,
                 'description', m.description,
                 'covers', m.coverage_note,
                 'required_tracks_it_covers_here', (
                   select coalesce(jsonb_agg(c.track_code order by c.track_code), '[]'::jsonb)
                   from knowledge.monograph_search_platforms c
                   join workflow.monograph_search_track_attempts a2 on a2.plan_id = v_plan.id
                   join knowledge.monograph_search_tracks k2
                     on k2.id = a2.track_id and k2.code = c.track_code
                   where c.platform = m.platform and c.method = m.method
                     and (c.profile_codes is null or v_profile.code = any (c.profile_codes))))
                 order by m.platform, m.method), '[]'::jsonb)
        from knowledge.monograph_search_methods m),
      'max_central_sources_per_request', 10,
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
      'En kandidatkilde med registrert tilgangsbegrensning («access_limited» er true) kan ikke ekskluderes, uansett grunn: Antidep har ikke fått lest den, og en betalingsmur er ikke en faglig eksklusjonsgrunn. Sett den som «avventer tilgang» (awaiting_access) med en begrunnelse.',
      'En kilde godkjennes for en bestemt bruk og avgrensning, ikke universelt. Oppgi hva hver kilde kan brukes til for hvert behov.',
      'En søkevei som ikke svarte, står som en begrensning i oppgaven. Den er ikke null treff, og den er aldri en konklusjon om evidensen.',
      'Hvilke kilder som er sentrale, avgjør du. Referanselistene og de siterende arbeidene til kildene du velger til innhenting, inkluderer eller vurderer som mulig konklusjonsendrende, følger Antidep selv i neste runde. Vil du følge flere, be om metoden «references» eller «citations» med kildene i «seed_candidates».',
      'Hver søkemetode står i oppgaven med hva den dekker og hva den ikke dekker. Er en begrensning vesentlig for spørsmålet — en nasjonal retningslinje Antidep ikke kan søke i, et register som ikke er med — si det i merknaden: det er en opplysning kontrollen og redaktøren skal se.',
      'Et avkortet søk («truncated», og «truncation_resolved» er false) holder søkedekningen åpen: resten av trefflisten er ikke lest. Be om et smalere søk, og oppgi runden det erstatter i «narrows_request». Bare rundene i «narrowable_rounds» kan erstattes fra dette leddet, og bare med nøyaktig den plattformen og metoden som står ved dem; står listen tom, har forespørselen ikke noe «narrows_request». Det er din faglige avgjørelse at det smalere søket er det som betyr noe for spørsmålet; Antidep regner resten som dekket når det smalere søket er lest helt.'));

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
                   'decision_reason', l.decision_reason) order by c.created_at), '[]'::jsonb)
          from workflow.monograph_candidate_sources c
          join workflow.monograph_candidate_source_plans l
            on l.candidate_source_id = c.id and l.plan_id = v_plan.id
          where l.decision = 'excluded'),
        'unresolved_candidates', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'identifier_kind', c.identifier_kind,
                   'identifier_value', c.identifier_value,
                   'title', c.title,
                   'decision', l.decision::text,
                   'access_limited', c.access_limited,
                   'could_change_conclusion', l.could_change_conclusion,
                   'materiality_reason', l.materiality_reason) order by c.created_at), '[]'::jsonb)
          from workflow.monograph_candidate_sources c
          join workflow.monograph_candidate_source_plans l
            on l.candidate_source_id = c.id and l.plan_id = v_plan.id
          where l.decision not in ('included', 'excluded'))));
  end if;

  return v_payload;
end;
$$;


comment on function workflow.monograph_discovery_task_input(uuid, provenance.agent_role) is
  'Oppgavematerialet til de to kildeleddene: de maskinelt utførte søkene med plattform, metode, endepunkt og responsavtrykk, rundene nettopp dette leddet kan erstatte med et smalere søk (narrowable_rounds, migrasjon 014i), de redaktørregistrerte passeringene hver for seg, søkeveiene som ikke svarte, kandidatkildene planen fant — også når en annen plan fant dem først — med om tilgangen er begrenset, og hvilke søk runden kan be om, med hver søkemetode, hva den dekker og hva den ikke dekker (migrasjon 014d). Sporene står med metodene som utfører dem for profilen. Machine_searches og editor_searches er fortsatt to felter: et menneskes dokumenterte arbeid er ikke et maskinelt kall (014a). Svarformen den eksterne agenten får, bygges av dette materialet.';

-- ----------------------------------------------------------------------------
-- 3. Nye versjoner av kildeleddenes promptmaler og svarformer
-- ----------------------------------------------------------------------------

create or replace function workflow.agent_task_contract(p_agent_role provenance.agent_role)
  returns jsonb
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
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
    -- Migrasjon 014i: svarformen er oppgavens egen. Den lister kandidatkildene
    -- oppgaven har, holder «excluded» borte fra dem med en registrert
    -- tilgangsbegrensning, og tillater bare de avkortede rundene dette leddet
    -- faktisk kan erstatte i narrows_request.
    when 'source_discovery' then jsonb_build_object(
      'prompt_template_version', 'source-discovery/machine-search-appraisal/6',
      'output_schema_version', 'antidep/source-discovery-draft@5'
    )
    when 'source_quality_assessment' then jsonb_build_object(
      'prompt_template_version', 'source-coverage/machine-countersearch-control/6',
      'output_schema_version', 'antidep/source-coverage-control-draft@4'
    )
    when 'monograph_answer' then jsonb_build_object(
      'prompt_template_version', 'monograph-answer/handoff-fact/2',
      'output_schema_version', 'antidep/monograph-answer-draft@1'
    )
    else null
  end;
$$;



comment on function workflow.agent_task_contract(provenance.agent_role) is
  'Hvilken promptmal og hvilket svarformat hvert agentledd arbeider etter. Kildeleddenes maler er på versjon 6 og svarformene på @5 og @4 fra migrasjon 014i: svarformen er bygget av den enkelte oppgaven — kandidatkildene den har, uten «excluded» for en kilde med registrert tilgangsbegrensning, og bare de avkortede rundene leddet kan erstatte i narrows_request. Verdiene er de samme som i src/agents/agent-task.ts, og pinnes av en prøve på begge sider av databasegrensen.';
