-- ============================================================================
-- Migrasjon 013f — kildeoppdagelsen gjennom den faktiske agentarbeidsformen
--
-- Migrasjon 013e ga kildeoppdagelsen en søkelogg, en port og en maskinelt
-- utført søkevei. Det som mangler, er det leddet som gjør den *semantiske*
-- delen av arbeidet — å planlegge søket, velge hvilke kilder som er egnet til
-- hva, og kontrollere dekningen — og det leddet er en ekstern KI-agent.
--
-- ----------------------------------------------------------------------------
-- Hvorfor dette ikke er en ny agentmotor
--
-- Fordi de nye rollene går gjennom nøyaktig den samme kontrakten som de tre
-- som fantes: `workflow.pipeline_jobs` med sin idempotensnøkkel og sin leie,
-- `workflow.agent_handoff_jobs` for utførelsesmåten, `workflow.agent_task(...)`
-- for oppgaven med sitt avtrykk, og `workflow.record_agent_handoff_answer(...)`
-- for svaret. Den autonome MCP-kjøreren og recovery-importen betjener dem
-- dermed uten én linje ny transport, og de kan strukturelt ikke få større
-- faglige skrivefullmakter enn de gamle.
--
-- Kroppene under er hentet fra databasen med `pg_get_functiondef` og splisset,
-- framfor skrevet av: splisingen starter da fra nøyaktig den kroppen som
-- gjelder, og de eksisterende grenene er ordrett uendret. Den ene endringen i
-- dem er at `else`-grenen er blitt uttømmende — en rolle uten en gren avvises
-- nå framfor å få en oppgave uten inndata, eller en fullført jobb uten at noe
-- klinisk arbeid ble skrevet.
--
-- ----------------------------------------------------------------------------
-- Hvorfor søkeoppgaven ikke inneholder et forventet svar
--
-- Fordi standarden definerer spørsmål og ikke svar (MONOGRAPH_STANDARD.md §1),
-- og fordi et søk låst til en forventet skaderetning er et dårligere søk
-- (SOURCE_POLICY.md §4.1). Oppgaven bærer derfor de relevante behovene med
-- spørsmålene ordrett, avgrensningen, kildeprofilen med sitt første kildevalg
-- og sine særskilte kontroller, de obligatoriske søkesporene, og kriteriene for
-- når søket kan avsluttes — og ingenting om hva svaret bør bli.
--
-- ----------------------------------------------------------------------------
-- Hvorfor kontrollens «jeg søkte selv» ikke er nok
--
-- Fordi en erklæring ikke er en utførelse. `searched_independently` kan bare
-- være sann når kontrollens egen kjøring faktisk har registrert et søk som gikk
-- — ellers avvises svaret. Det er den samme regelen som skiller agentrapportert
-- fra maskinelt bekreftet utførelse, anvendt på motprøvingen: et kontrollledd
-- som bare leser generatorens valgte referanser, kan kontrollere sitatene, men
-- ikke vurdere dekningsgraden (SOURCE_POLICY.md §6).
--
-- Styrende dokumenter: docs/SOURCE_POLICY.md §4, §6, §8,
-- docs/MONOGRAPH_STANDARD.md §1, §4, docs/ANTIDEP_CONSTITUTION.md regel 3, 4, 5,
-- docs/EVIDENCE_PIPELINE.md, AGENTS.md.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Oppgavekontrakten for de to rollene
--
-- Promptmalversjonen og svarformversjonen inngår i avtrykket, og de er de samme
-- verdiene `src/agents/agent-task.ts` skriver. En prøve pinner de to sidene mot
-- hverandre.
-- ----------------------------------------------------------------------------
create or replace function workflow.agent_task_contract(p_agent_role provenance.agent_role)
  returns jsonb
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
    when 'evidence_extraction' then jsonb_build_object(
      'prompt_template_version', 'evidence-extraction/handoff-drafting/1',
      'output_schema_version', 'antidep/extraction-draft@1'
    )
    when 'claim_synthesis' then jsonb_build_object(
      'prompt_template_version', 'claim-synthesis/handoff-drafting/1',
      'output_schema_version', 'antidep/claim-synthesis-draft@1'
    )
    when 'evidence_assessment' then jsonb_build_object(
      'prompt_template_version', 'evidence-assessment/handoff-drafting/1',
      'output_schema_version', 'antidep/evidence-assessment-draft@1'
    )
    when 'source_discovery' then jsonb_build_object(
      'prompt_template_version', 'source-discovery/handoff-search/1',
      'output_schema_version', 'antidep/source-discovery-draft@1'
    )
    when 'source_quality_assessment' then jsonb_build_object(
      'prompt_template_version', 'source-coverage/handoff-control/1',
      'output_schema_version', 'antidep/source-coverage-control-draft@1'
    )
    else null
  end;
$$;

comment on function workflow.agent_task_contract(provenance.agent_role) is
  'Promptmalversjonen og outputschemaversjonen rollen er bundet til i den eksterne agent-handoffen, eller NULL for en rolle som ikke kan ta imot et eksternt agentsvar. Begge verdiene inngår i request_digest, slik at et svar avgitt under en eldre mal eller et eldre skjema ikke kan importeres på en oppgave bygget under en nyere. Verdiene er de samme som i src/agents/agent-task.ts, og pinnes av en prøve på begge sider av databasegrensen. Migrasjon 013f la til kildeoppdagelsen og den separate kontrollen av søkedekningen; de uavhengige deterministiske kontrolleddene står fortsatt ikke her.';

-- Subjektet oppgavenøkkelen bygges av. For kildeleddene er det søkeplanen: to
-- oppgaver om den samme planen i den samme rollen er ett stykke arbeid.
create or replace function workflow.agent_task_manifest_subject(
  p_agent_role provenance.agent_role,
  p_input_manifest jsonb
)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case p_agent_role
    when 'evidence_extraction' then coalesce(p_input_manifest ->> 'source_version_id', '?')
    when 'claim_synthesis' then format('%s+%s',
      coalesce(p_input_manifest ->> 'subject_drug_id', '?'),
      coalesce(p_input_manifest ->> 'topic_concept_id', '?'))
    when 'source_discovery' then coalesce(p_input_manifest ->> 'search_plan_id', '?')
    when 'source_quality_assessment' then coalesce(p_input_manifest ->> 'search_plan_id', '?')
    else coalesce(p_input_manifest ->> 'claim_revision_id', '?')
  end;
$$;

comment on function workflow.agent_task_manifest_subject(provenance.agent_role, jsonb) is
  'Hva en oppgave i rollen handler om, som en stabil tekst: kildeversjonen, virkestoffet og temaet, søkeplanen, eller påstandsrevisjonen. Oppgavenøkkelen bygges av den, og duplikatkontrollen i kjedeovergangene leser den samme — så to oppgaver om det samme arbeidet kan ikke bli to jobber. Migrasjon 013f la til søkeplanen for de to kildeleddene.';

create or replace function workflow.agent_task_subject(p_job workflow.pipeline_jobs)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select case p_job.agent_role
    when 'evidence_extraction' then (
      select jsonb_build_object('kind', 'kilde', 'label', s.title)
      from knowledge.source_versions sv
      join knowledge.sources s on s.id = sv.source_id
      where sv.id = workflow.manifest_uuid(p_job.input_manifest, 'source_version_id')
    )
    when 'claim_synthesis' then (
      select jsonb_build_object('kind', 'påstand',
               'label', format('%s — %s', d.canonical_name, c.canonical_label))
      from catalog.drugs d, catalog.clinical_concepts c
      where d.id = workflow.manifest_uuid(p_job.input_manifest, 'subject_drug_id')
        and c.id = workflow.manifest_uuid(p_job.input_manifest, 'topic_concept_id')
    )
    when 'evidence_assessment' then (
      select jsonb_build_object('kind', 'påstandsrevisjon', 'label', r.statement)
      from knowledge.claim_revisions r
      where r.id = workflow.manifest_uuid(p_job.input_manifest, 'claim_revision_id')
    )
    when 'source_discovery' then (
      select jsonb_build_object('kind', 'søkeplan',
               'label', format('%s — %s', d.canonical_name, sp.question))
      from workflow.monograph_search_plans p
      join knowledge.monograph_editions e on e.id = p.edition_id
      join catalog.drugs d on d.id = e.drug_id
      join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
      where p.id = workflow.manifest_uuid(p_job.input_manifest, 'search_plan_id')
    )
    when 'source_quality_assessment' then (
      select jsonb_build_object('kind', 'kontroll av søkedekning',
               'label', format('%s — %s', d.canonical_name, sp.question))
      from workflow.monograph_search_plans p
      join knowledge.monograph_editions e on e.id = p.edition_id
      join catalog.drugs d on d.id = e.drug_id
      join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
      where p.id = workflow.manifest_uuid(p_job.input_manifest, 'search_plan_id')
    )
  end;
$$;

comment on function workflow.agent_task_subject(workflow.pipeline_jobs) is
  'Hva oppgaven gjelder, i klartekst: kildens tittel, virkestoffet og temaet, påstandens formulering, eller virkestoffet og kildeprofilens spørsmål for en søkeplan. Egen funksjon fordi køen trenger den for hver rad, og hele oppgaven — som kan inneholde en hel forskningsartikkel — er altfor dyr å bygge bare for å lese en overskrift.';

-- ----------------------------------------------------------------------------
-- 2. Selve søkeoppgaven
--
-- Den bærer spørsmålene og kriteriene, og ingenting om hva svaret bør bli.
-- Kontrolloppgaven bærer i tillegg generatorens søk, kandidater og
-- eksklusjoner — det er dem den skal motprøve — men den er uttrykkelig bedt om
-- å søke selv.
-- ----------------------------------------------------------------------------
create function workflow.monograph_discovery_task_input(
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

  v_payload := jsonb_build_object(
    'search_plan_id', v_plan.id,
    'plan_reference', v_plan.reference,
    'plan_version', v_plan.plan_version,
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
    'searches_so_far', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'platform', s.platform, 'query', s.query_string, 'filters', s.filters,
               'outcome', s.outcome::text, 'result_count', s.result_count,
               'screened_count', s.screened_count, 'truncated', s.truncated,
               'truncation_note', s.truncation_note,
               'limitation_note', s.limitation_note,
               'execution_evidence', s.execution_evidence::text,
               'tracks', to_jsonb(s.track_codes))
               order by s.registration_ordinal), '[]'::jsonb)
      from workflow.monograph_searches s
      where s.plan_id = v_plan.id and s.plan_version = v_plan.plan_version),
    'candidates_so_far', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'identifier_kind', c.identifier_kind,
               'identifier_value', c.identifier_value,
               'title', c.title,
               'authors_or_issuer', c.authors_or_issuer,
               'publisher_or_journal', c.publisher_or_journal,
               'publication_year', c.publication_year,
               'discovery_path', c.discovery_path,
               'decision', c.decision::text,
               'decision_reason', c.decision_reason,
               'access_limited', c.access_limited,
               'could_change_conclusion', c.could_change_conclusion)
               order by c.created_at), '[]'::jsonb)
      from workflow.monograph_candidate_sources c where c.plan_id = v_plan.id),
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
      'En foreslått søkestreng er ikke et utført søk. Rapporter bare søk du faktisk utførte, med den strengen du faktisk brukte.',
      'Et søk du rapporterer, registreres som agentrapportert utførelse. Antidep skiller det fra sine egne maskinelt utførte søk og hevder ikke at ditt verktøykall er maskinelt bekreftet.',
      'En betalingsmur er en tilgangsbegrensning og ikke en faglig eksklusjonsgrunn. Sett slike kilder som «avventer tilgang» med en begrunnelse.',
      'En kilde godkjennes for en bestemt bruk og avgrensning, ikke universelt. Oppgi hva hver kilde kan brukes til for hvert behov.',
      'Ingen automatisk avgrensning til åpen tilgang, engelsk språk, siste fem år eller statistisk signifikante resultater.'));

  if p_role = 'source_quality_assessment' then
    v_payload := v_payload || jsonb_build_object(
      'control_task', jsonb_build_object(
        'instruction', 'Kontroller søkedekningen. Let selv etter oversette og motstridende kilder, kontroller de sentrale eksklusjonene, og vurder vesentligheten av de kildene som står uavklarte. Godta begrunnelsen for å stoppe bare når kravene faktisk er oppfylt.',
        'own_search_required', true,
        'own_search_rule', 'Antidep godtar ikke en erklæring om at du søkte selv uten at kjøringen din faktisk har registrert et søk som gikk. Rapporter dine egne motsøk i «searches».',
        'excluded_candidates', (
          select coalesce(jsonb_agg(jsonb_build_object(
                   'identifier_value', c.identifier_value,
                   'title', c.title,
                   'decision_reason', c.decision_reason) order by c.created_at), '[]'::jsonb)
          from workflow.monograph_candidate_sources c
          where c.plan_id = v_plan.id and c.decision = 'excluded'),
        'unresolved_candidates', (
          select coalesce(jsonb_agg(jsonb_build_object(
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
  'Innholdet søkeoppgaven og kontrolloppgaven består av: avgrensningen, kildeprofilen med sitt første kildevalg og sine særskilte kontroller, de relevante kunnskapsbehovene med spørsmålene ordrett fra standarden, de obligatoriske søkesporene med tilstanden sin, søkene og kandidatene så langt, og kriteriene for å avslutte — med de fire grunnene som uttrykkelig ikke holder. Ingen forventet klinisk konklusjon og ingen antydet retning: standarden definerer spørsmål, ikke svar (MONOGRAPH_STANDARD.md §1, SOURCE_POLICY.md §4.1). Kontrolloppgaven får i tillegg generatorens eksklusjoner og uavklarte kilder, og beskjed om at en erklæring om egne søk ikke godtas uten registrerte søk.';

revoke execute on function workflow.monograph_discovery_task_input(uuid, provenance.agent_role) from public;

-- ----------------------------------------------------------------------------
-- 3. Oppgaven, forhåndskontrollen og svarveien, splisset
--
-- Kroppene er hentet fra databasen og har de eksisterende grenene ordrett
-- uendret. Det som er lagt til, er kildeleddenes grener og en uttømmende
-- else — en rolle uten en gren avvises nå framfor å gli gjennom.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION workflow.agent_task_input_problem(p_job workflow.pipeline_jobs)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_manifest jsonb := p_job.input_manifest;
  v_source_version_id uuid;
  v_revision_id uuid;
  v_ids uuid[];
  v_count integer;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_plan_id uuid;
  v_plan workflow.monograph_search_plans;
begin
  if p_job.agent_role = 'evidence_extraction' then
    v_source_version_id := workflow.manifest_uuid(v_manifest, 'source_version_id');
    if v_source_version_id is null then
      return 'Oppgaven sier ikke hvilken kildeversjon den gjelder.';
    end if;
    if not exists (select 1 from knowledge.source_versions sv where sv.id = v_source_version_id) then
      return 'Kildeversjonen oppgaven gjelder, finnes ikke.';
    end if;
    if knowledge.source_version_text(v_source_version_id) is null then
      return 'Kildeteksten er ikke lagret for denne kildeversjonen, så oppgaven kan ikke inneholde artikkelen. Last opp fullteksten på nytt gjennom fulltekstbiblioteket.';
    end if;

    v_ids := workflow.manifest_uuids(v_manifest, 'drug_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke virkestoff funnet kan gjelde.';
    end if;
    select count(*) into v_count from catalog.drugs d where d.id = any (v_ids);
    if v_count <> cardinality(v_ids) then
      return 'Ett av virkestoffene i oppgaven finnes ikke i katalogen.';
    end if;

    v_ids := workflow.manifest_uuids(v_manifest, 'outcome_concept_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke endepunkt funnet kan gjelde.';
    end if;
    select count(*) into v_count
    from catalog.clinical_concepts c
    where c.id = any (v_ids) and c.concept_type = 'outcome';
    if v_count <> cardinality(v_ids) then
      return 'Ett av endepunktene i oppgaven finnes ikke i katalogen.';
    end if;

    v_ids := coalesce(workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]);
    select count(*) into v_count from catalog.populations p where p.id = any (v_ids);
    if v_count <> cardinality(v_ids) then
      return 'En av populasjonene i oppgaven finnes ikke i katalogen.';
    end if;
    return null;
  end if;

  if p_job.agent_role = 'claim_synthesis' then
    if workflow.manifest_uuid(v_manifest, 'topic_concept_id') is null
       or workflow.manifest_uuid(v_manifest, 'subject_drug_id') is null then
      return 'Oppgaven sier ikke hvilket tema og virkestoff påstanden skal gjelde.';
    end if;
    -- Katalogverdiene må finnes, og ikke bare ha formen. Uten dette ville
    -- oppgaven blitt bygget av et tomt oppslag, og feilen kommet først når et
    -- ferdig svar ikke lot seg registrere.
    if not exists (
      select 1 from catalog.clinical_concepts c
      where c.id = workflow.manifest_uuid(v_manifest, 'topic_concept_id')
        and c.concept_type = 'outcome'
    ) then
      return 'Temaet oppgaven gjelder, finnes ikke som et endepunkt i katalogen.';
    end if;
    if not exists (
      select 1 from catalog.drugs d
      where d.id = workflow.manifest_uuid(v_manifest, 'subject_drug_id')
    ) then
      return 'Virkestoffet oppgaven gjelder, finnes ikke i katalogen.';
    end if;
    v_ids := workflow.manifest_uuids(v_manifest, 'evidence_item_ids');
    if v_ids is null or cardinality(v_ids) = 0 then
      return 'Oppgaven sier ikke hvilke evidensfunn syntesen skal bygge på.';
    end if;

    -- Kontrollnivået evidensen må ha nådd, lest med skriveveiens egen funksjon.
    -- Et funn uten bekreftet ekstraksjonskontroll — eller med et senere åpent
    -- avvik — kan ikke bære en påstand, og det er like sant før oppgaven hentes
    -- ut som etter at svaret er skrevet.
    return workflow.evidence_usable_problem(
      v_ids, 'Evidensgrunnlaget er ikke klart for en syntese ennå');
  end if;

  if p_job.agent_role = 'evidence_assessment' then
    v_revision_id := workflow.manifest_uuid(v_manifest, 'claim_revision_id');
    if v_revision_id is null then
      return 'Oppgaven sier ikke hvilken påstandsrevisjon den gjelder.';
    end if;

    select r.knowledge_type, c.retired_at into v_knowledge_type, v_retired_at
    from knowledge.claim_revisions r
    join knowledge.claims c on c.id = r.claim_id
    where r.id = v_revision_id;

    if not found then
      return 'Påstandsrevisjonen oppgaven gjelder, finnes ikke.';
    end if;
    if v_knowledge_type <> 'evidence_synthesis' then
      return 'Påstanden er ikke en evidenssyntese, og skal ikke graderes. En klinisk anbefaling og et deterministisk faktum har ingen evidensvurdering.';
    end if;
    if v_retired_at is not null then
      return 'Påstanden er trukket tilbake, og skal ikke vurderes.';
    end if;
    if exists (
      select 1 from knowledge.evidence_assessments a
      where a.claim_revision_id = v_revision_id
    ) then
      return 'Påstanden er allerede vurdert. En endret vurdering av det samme grunnlaget er en ny påstandsformulering, ikke en overskriving.';
    end if;
    if not exists (
      select 1 from workflow.claim_verifications v
      where v.claim_revision_id = v_revision_id
    ) then
      return 'Påstanden er ikke kildestøttekontrollert ennå. Evidensvurderingen kommer etter den kontrollen.';
    end if;

    select array_agg(distinct l.evidence_item_id) into v_ids
    from knowledge.claim_evidence_links l
    where l.claim_revision_id = v_revision_id;

    if v_ids is null then
      return 'Påstanden har ingen evidenslenker, og det finnes ikke noe grunnlag å vurdere.';
    end if;

    -- De samme to vilkårene skriveveien leser på vurderingstidspunktet, i den
    -- samme rekkefølgen: grunnlaget må fortsatt kunne bære påstanden, og
    -- kildestøttekontrollen må være gjeldende, bekreftet og gjort av noen med
    -- mandat — på nøyaktig det evidenssettet som ligger der nå.
    return coalesce(
      workflow.evidence_usable_problem(
        v_ids, 'Evidensgrunnlaget bak påstanden er ikke lenger brukbart'),
      workflow.claim_verified_problem(
        v_revision_id, 'Kildestøttekontrollen av påstanden holder ikke'));
  end if;

  if p_job.agent_role in ('source_discovery', 'source_quality_assessment') then
    v_plan_id := workflow.manifest_uuid(v_manifest, 'search_plan_id');
    if v_plan_id is null then
      return 'Oppgaven sier ikke hvilken søkeplan den gjelder.';
    end if;

    select p.* into v_plan
    from workflow.monograph_search_plans p where p.id = v_plan_id;
    if not found then
      return 'Søkeplanen oppgaven gjelder, finnes ikke.';
    end if;

    if (v_manifest ->> 'plan_version')::integer is distinct from v_plan.plan_version then
      return 'Søkeplanen har fått en ny versjon siden oppgaven ble lagt inn. Arbeidet hører til den nye versjonen.';
    end if;

    if v_plan.closed_at is not null then
      return 'Søkedekningen for denne planen er allerede erklært ferdig.';
    end if;

    if v_plan.paused_at is not null then
      return format('Søket står på pause: %s', v_plan.paused_reason);
    end if;

    if not exists (
      select 1 from workflow.monograph_search_plan_needs pn where pn.plan_id = v_plan_id
    ) then
      return 'Søkeplanen dekker ikke noe kunnskapsbehov, og det finnes ikke noe spørsmål å søke etter.';
    end if;

    if p_job.agent_role = 'source_quality_assessment' then
      -- Kontrollen kontrollerer et søk. Uten et utført søk å kontrollere ville
      -- den vurdert en dekning som ikke finnes (SOURCE_POLICY.md §6).
      if not exists (
        select 1 from workflow.monograph_searches s
        where s.plan_id = v_plan_id
          and s.plan_version = v_plan.plan_version
          and s.outcome in ('executed', 'zero_results')
      ) then
        return 'Ingen søk er utført på denne planversjonen ennå, så det finnes ingen søkedekning å kontrollere.';
      end if;

      if exists (
        select 1 from workflow.monograph_coverage_controls cc
        where cc.plan_id = v_plan_id and cc.plan_version = v_plan.plan_version
      ) then
        return 'Denne planversjonen er allerede dekningskontrollert. Skal dekningen kontrolleres på nytt, er planen blitt en annen.';
      end if;
    end if;

    return null;
  end if;

  return format('Rollen %s har ingen oppgaveform ennå.', p_job.agent_role);
end;
$function$;

CREATE OR REPLACE FUNCTION workflow.agent_task(p_job workflow.pipeline_jobs)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  v_manifest jsonb := p_job.input_manifest;
  v_contract jsonb := workflow.agent_task_contract(p_job.agent_role);
  v_binding jsonb;
  v_input jsonb;
  v_subject jsonb;
  v_ignored jsonb;
  v_prior jsonb := '[]'::jsonb;
  v_model provenance.role_model_assignments;
  v_source_version_id uuid;
  v_revision_id uuid;
  v_evidence_ids uuid[];
  v_drug_ids uuid[];
  v_outcome_ids uuid[];
  v_population_ids uuid[];
  v_plan_id uuid;
begin
  if p_job.agent_role = 'evidence_extraction' then
    v_source_version_id := workflow.manifest_uuid(v_manifest, 'source_version_id');
    v_drug_ids := workflow.manifest_uuids(v_manifest, 'drug_ids');
    v_outcome_ids := workflow.manifest_uuids(v_manifest, 'outcome_concept_ids');
    v_population_ids := coalesce(workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]);

    select jsonb_build_object(
             'source_id', sv.source_id,
             'source_version_id', sv.id,
             'content_hash', sv.content_hash,
             'representation', sv.representation::text,
             'document_sha256', sv.document_sha256,
             'drug_ids', to_jsonb(v_drug_ids),
             'outcome_concept_ids', to_jsonb(v_outcome_ids),
             'population_ids', to_jsonb(v_population_ids)
           ),
           jsonb_build_object(
             'source', jsonb_build_object(
               'source_id', s.id,
               'title', s.title,
               'authors_or_issuer', s.authors_or_issuer,
               'publisher_or_journal', s.publisher_or_journal,
               'publication_date', s.publication_date,
               'source_type', s.source_type::text
             ),
             'source_version', jsonb_build_object(
               'source_version_id', sv.id,
               'retrieved_from', sv.retrieved_from,
               'retrieved_at', sv.retrieved_at,
               'content_hash', sv.content_hash,
               'representation', sv.representation::text,
               'document_sha256', sv.document_sha256
             ),
             'representation_text', knowledge.source_version_text(sv.id),
             'drugs', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'drug_id', d.id, 'label', d.canonical_name) order by d.canonical_name), '[]'::jsonb)
               from catalog.drugs d where d.id = any (v_drug_ids)
             ),
             'outcomes', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'outcome_concept_id', c.id, 'label', c.canonical_label) order by c.canonical_label), '[]'::jsonb)
               from catalog.clinical_concepts c where c.id = any (v_outcome_ids)
             ),
             'populations', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'population_id', p.id, 'label', p.canonical_label) order by p.canonical_label), '[]'::jsonb)
               from catalog.populations p where p.id = any (v_population_ids)
             )
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from knowledge.source_versions sv
    join knowledge.sources s on s.id = sv.source_id
    where sv.id = v_source_version_id;

  elsif p_job.agent_role = 'claim_synthesis' then
    v_evidence_ids := workflow.manifest_uuids(v_manifest, 'evidence_item_ids');

    select jsonb_build_object(
             'topic_concept_id', workflow.manifest_uuid(v_manifest, 'topic_concept_id'),
             'subject_drug_id', workflow.manifest_uuid(v_manifest, 'subject_drug_id'),
             'claim_id', workflow.manifest_uuid(v_manifest, 'claim_id'),
             'population_ids', to_jsonb(coalesce(
               workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[])),
             'evidence', (
               select coalesce(jsonb_agg(
                 jsonb_build_object('evidence_item_id', e.id, 'content_hash', e.content_hash)
                 order by e.id::text), '[]'::jsonb)
               from knowledge.evidence_items e where e.id = any (v_evidence_ids)
             )
           ),
           jsonb_build_object(
             'topic', jsonb_build_object(
               'topic_concept_id', c.id, 'label', c.canonical_label),
             'subject_drug', jsonb_build_object(
               'drug_id', d.id, 'label', d.canonical_name),
             'claim_id', workflow.manifest_uuid(v_manifest, 'claim_id'),
             'populations', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'population_id', p.id, 'label', p.canonical_label) order by p.canonical_label), '[]'::jsonb)
               from catalog.populations p
               where p.id = any (coalesce(
                 workflow.manifest_uuids(v_manifest, 'population_ids'), array[]::uuid[]))
             ),
             'evidence', (
               select coalesce(jsonb_agg(workflow.evidence_extraction_dossier(e.id) order by e.id::text), '[]'::jsonb)
               from knowledge.evidence_items e where e.id = any (v_evidence_ids)
             )
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from catalog.clinical_concepts c, catalog.drugs d
    where c.id = workflow.manifest_uuid(v_manifest, 'topic_concept_id')
      and d.id = workflow.manifest_uuid(v_manifest, 'subject_drug_id');

    select coalesce(jsonb_agg(
             jsonb_build_object('role', r.agent_role::text, 'agent_run_id', r.id)
             order by r.id::text), '[]'::jsonb)
      into v_prior
    from knowledge.evidence_items e
    join provenance.agent_runs r on r.id = e.agent_run_id
    where e.id = any (v_evidence_ids);

  elsif p_job.agent_role in ('source_discovery', 'source_quality_assessment') then
    v_plan_id := workflow.manifest_uuid(v_manifest, 'search_plan_id');

    -- Bindingen er søkeplanen, dens versjon, avgrensningsavtrykket, profilen og
    -- de behovene planen dekket da oppgaven ble bygget — og hvor langt søket
    -- var kommet. Kommer det et nytt søk eller en ny kandidat imellom, får
    -- oppgaven et nytt avtrykk, og et svar avgitt på det gamle grunnlaget kan
    -- ikke importeres (ANTIDEP_CONSTITUTION.md regel 5).
    select jsonb_build_object(
             'search_plan_id', p.id,
             'plan_version', p.plan_version,
             'profile_code', sp.code,
             'scope_digest', p.scope_digest,
             'need_ids', (
               select coalesce(jsonb_agg(pn.need_id order by pn.need_id::text), '[]'::jsonb)
               from workflow.monograph_search_plan_needs pn where pn.plan_id = p.id),
             'searches_seen', coalesce((
               select max(s.registration_ordinal) from workflow.monograph_searches s
               where s.plan_id = p.id and s.plan_version = p.plan_version), 0),
             'candidates_seen', (
               select count(*) from workflow.monograph_candidate_sources c
               where c.plan_id = p.id)
           ),
           workflow.monograph_discovery_task_input(p.id, p_job.agent_role),
           null::jsonb
      into v_binding, v_input, v_ignored
    from workflow.monograph_search_plans p
    join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
    where p.id = v_plan_id;

    -- Kontrollen hviler på generatorens kjøringer, og de står i bindingen:
    -- et svar kan bekrefte hvilke kjøringer det kontrollerte, men ikke velge
    -- dem.
    if p_job.agent_role = 'source_quality_assessment' then
      select coalesce(jsonb_agg(
               jsonb_build_object('role', r.agent_role::text, 'agent_run_id', r.id)
               order by r.id::text), '[]'::jsonb)
        into v_prior
      from workflow.monograph_searches s
      join provenance.agent_runs r on r.id = s.agent_run_id
      where s.plan_id = v_plan_id and s.plan_version = (
        select p.plan_version from workflow.monograph_search_plans p where p.id = v_plan_id);
    end if;

  elsif p_job.agent_role = 'evidence_assessment' then
    v_revision_id := workflow.manifest_uuid(v_manifest, 'claim_revision_id');

    select jsonb_build_object(
             'claim_revision_id', r.id,
             'revision_content_hash', r.content_hash,
             'evidence_set_digest', knowledge.claim_evidence_set_digest(r.id)
           ),
           jsonb_build_object(
             'dossier', workflow.claim_evidence_dossier(r.id),
             'seen_evidence_set_digest', knowledge.claim_evidence_set_digest(r.id)
           ),
           null::jsonb
      into v_binding, v_input, v_ignored
    from knowledge.claim_revisions r
    where r.id = v_revision_id;

    select coalesce(jsonb_agg(
             jsonb_build_object('role', x.role, 'agent_run_id', x.run_id)
             order by x.role, x.run_id::text), '[]'::jsonb)
      into v_prior
    from (
      select r.agent_role::text as role, r.id as run_id
      from knowledge.claim_revisions cr
      join provenance.agent_runs r on r.id = cr.agent_run_id
      where cr.id = v_revision_id
      union all
      select r.agent_role::text, r.id
      from workflow.claim_verifications v
      join provenance.agent_runs r on r.id = v.agent_run_id
      where v.claim_revision_id = v_revision_id
    ) x;
  else
    -- Uttømmende over rollene som kan settes ut. En rolle uten en gren ville
    -- ellers gitt en oppgave uten inndata, og et svar bundet til ingenting.
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Rollen %s har ingen oppgaveform.', p_job.agent_role);
  end if;

  v_subject := workflow.agent_task_subject(p_job);
  v_model := provenance.current_semantic_model(p_job.agent_role);

  v_binding := jsonb_build_object(
    'task_version', workflow.agent_handoff_task_version(),
    'role', p_job.agent_role::text,
    'job_key', p_job.job_key,
    'pipeline_job_id', p_job.id,
    'prompt_template_version', v_contract ->> 'prompt_template_version',
    'output_schema_version', v_contract ->> 'output_schema_version',
    -- Tildelingen er en del av det som binder svaret. Byttes modellen, får hver
    -- utestående oppgave et nytt avtrykk, og et svar avgitt under den gamle
    -- tildelingen kan ikke komme tilbake og registrere den gamle modellen på
    -- nytt (ANTIDEP_CONSTITUTION.md regel 3). Tildelingens id står med, fordi to
    -- tildelinger av den samme modellen er to avgjørelser.
    'semantic_model', case when v_model.id is null then null else jsonb_build_object(
      'assignment_id', v_model.id,
      'provider', v_model.provider,
      'model', v_model.model,
      'model_version', v_model.model_version,
      'model_version_disclosure', v_model.model_version_disclosure::text
    ) end,
    'input', v_binding,
    'prior_runs', v_prior
  );

  return jsonb_build_object(
    'task_version', workflow.agent_handoff_task_version(),
    'answer_version', workflow.agent_handoff_answer_version(),
    'pipeline_job_id', p_job.id,
    'job_key', p_job.job_key,
    'role', p_job.agent_role::text,
    'prompt_template_version', v_contract ->> 'prompt_template_version',
    'output_schema_version', v_contract ->> 'output_schema_version',
    'request_digest', workflow.agent_task_digest(v_binding),
    'binding', v_binding,
    'subject', v_subject,
    'registered_model', case when v_model.id is null then null else jsonb_build_object(
      'provider', v_model.provider,
      'model', v_model.model,
      'model_version', v_model.model_version,
      'model_version_disclosure', v_model.model_version_disclosure::text
    ) end,
    'input', v_input
  );
end;
$function$;


-- ----------------------------------------------------------------------------
-- 4. Svaret fra de to kildeleddene
--
-- Registreres gjennom nøyaktig de samme skriveveiene den maskinelle søkeveien
-- bruker (`workflow.record_monograph_search(...)`,
-- `workflow.record_monograph_candidate_source(...)`,
-- `workflow.record_monograph_coverage_control(...)`), med én forskjell som er
-- hele poenget: utførelsesbeviset er `agent_reported`. Et agentsvar kan ikke
-- bære et responsavtrykk, og kan derfor ikke gi seg ut for å være maskinelt
-- bekreftet (SOURCE_POLICY.md §4.3).
-- ----------------------------------------------------------------------------
create function workflow.record_monograph_discovery_answer(
  p_job workflow.pipeline_jobs,
  p_input jsonb,
  p_result jsonb,
  p_run_id uuid,
  p_actor_id uuid
)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan_id uuid := workflow.manifest_uuid(p_input, 'search_plan_id');
  v_plan workflow.monograph_search_plans;
  v_unknown text;
  v_item jsonb;
  v_use jsonb;
  v_need_id uuid;
  v_search_id uuid;
  v_candidate_id uuid;
  v_outcome workflow.monograph_search_outcome;
  v_decision workflow.monograph_candidate_decision;
  v_axis knowledge.monograph_scope_axis;
  v_searches integer := 0;
  v_candidates integer := 0;
  v_decisions integer := 0;
  v_proposals integer := 0;
  v_control jsonb;
  v_control_id uuid;
  v_own_searches integer := 0;
  v_closed boolean := false;
  v_closure text;
  v_next_job uuid;
  v_allowed text[];
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p
  where p.id = v_plan_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Søkeplanen oppgaven gjelder, finnes ikke lenger.';
  end if;

  -- Ukjente felter avvises framfor å ignoreres: et felt med skrivefeil ville
  -- ellers sett ut som en utelatt opplysning.
  v_allowed := case p_job.agent_role
    when 'source_discovery' then array['searches', 'candidates', 'term_proposals', 'note']
    else array['searches', 'candidates', 'control', 'note']
  end;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(p_result) as k(value)
  where not (k.value = any (v_allowed));
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret har felter denne kontrakten ikke kjenner: %s.', v_unknown),
      hint = format('Feltene rollen %s leser, er %s.',
                    p_job.agent_role, array_to_string(v_allowed, ', '));
  end if;

  -- ------------------------------------------------------------------
  -- Søkene agenten rapporterer
  -- ------------------------------------------------------------------
  if p_result ? 'searches' then
    if jsonb_typeof(p_result -> 'searches') <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'searches er ikke en JSON-liste.';
    end if;

    for v_item in select value from jsonb_array_elements(p_result -> 'searches') loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_item) as k(value)
      where k.value not in (
        'platform', 'query_string', 'filters', 'outcome', 'result_count',
        'screened_count', 'truncated', 'truncation_note', 'limitation_note',
        'track_codes'
      );
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('Et rapportert søk har felter denne kontrakten ikke kjenner: %s.', v_unknown);
      end if;

      begin
        v_outcome := (v_item ->> 'outcome')::workflow.monograph_search_outcome;
      exception
        when invalid_text_representation then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = format('%L er ikke et søkeutfall.', v_item ->> 'outcome'),
            hint = 'Utfallene er executed, zero_results, unavailable og failed. En utilgjengelig søkevei er ikke null treff (SOURCE_POLICY.md §8.2).';
      end;

      v_search_id := workflow.record_monograph_search(
        v_plan_id,
        v_item ->> 'platform',
        v_item ->> 'query_string',
        v_item ->> 'filters',
        statement_timestamp(),
        (v_item ->> 'result_count')::integer,
        coalesce((v_item ->> 'screened_count')::integer, 0),
        coalesce((v_item ->> 'truncated')::boolean, false),
        v_item ->> 'truncation_note',
        v_outcome,
        v_item ->> 'limitation_note',
        -- Agentens egen beretning, og ingenting annet. Verdien settes her og
        -- kan ikke oppgis i svaret.
        'agent_reported'::workflow.monograph_execution_evidence,
        null, null,
        (select coalesce(array_agg(t.value #>> '{}'), array[]::text[])
         from jsonb_array_elements(coalesce(v_item -> 'track_codes', '[]'::jsonb)) as t(value)),
        p_run_id, p_actor_id);

      v_searches := v_searches + 1;
      if v_outcome in ('executed', 'zero_results') then
        v_own_searches := v_own_searches + 1;
      end if;
    end loop;
  end if;

  -- ------------------------------------------------------------------
  -- Kandidatkildene, med sine mulige bruksområder og utvalgsbeslutninger
  -- ------------------------------------------------------------------
  if p_result ? 'candidates' then
    if jsonb_typeof(p_result -> 'candidates') <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'candidates er ikke en JSON-liste.';
    end if;

    for v_item in select value from jsonb_array_elements(p_result -> 'candidates') loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_item) as k(value)
      where k.value not in (
        'identifier_kind', 'identifier_value', 'title', 'authors_or_issuer',
        'publisher_or_journal', 'publication_year', 'discovery_path',
        'access_limited', 'access_limitation_note',
        'could_change_conclusion', 'materiality_reason',
        'decision', 'decision_reason', 'uses'
      );
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('En kandidatkilde har felter denne kontrakten ikke kjenner: %s.', v_unknown);
      end if;

      v_candidate_id := workflow.record_monograph_candidate_source(
        v_plan_id, null,
        v_item ->> 'identifier_kind',
        v_item ->> 'identifier_value',
        v_item ->> 'title',
        v_item ->> 'authors_or_issuer',
        v_item ->> 'publisher_or_journal',
        (v_item ->> 'publication_year')::integer,
        v_item ->> 'discovery_path',
        coalesce((v_item ->> 'access_limited')::boolean, false),
        v_item ->> 'access_limitation_note',
        coalesce((v_item ->> 'could_change_conclusion')::boolean, false),
        v_item ->> 'materiality_reason',
        p_run_id, p_actor_id);
      v_candidates := v_candidates + 1;

      -- Hva kilden kan brukes til, per behov. Behovet må være ett av dem planen
      -- dekker: en bruk utenfor oppgaven ville flyttet kilden til et spørsmål
      -- ingen hadde avgrenset.
      if v_item ? 'uses' then
        for v_use in select value from jsonb_array_elements(coalesce(v_item -> 'uses', '[]'::jsonb)) loop
          select n.id into v_need_id
          from knowledge.monograph_needs n
          join workflow.monograph_search_plan_needs pn on pn.need_id = n.id
          where pn.plan_id = v_plan_id and n.reference = v_use ->> 'need_reference';

          if v_need_id is null then
            raise exception using
              errcode = 'invalid_parameter_value',
              message = 'Svaret oppgir en bruk for et kunnskapsbehov som ikke står i oppgaven.',
              hint = 'Hvilke behov søkeplanen dekker, er en faglig avgrensning som ligger i oppgaven. En bruk utenfor den ville flyttet kilden til et spørsmål ingen hadde avgrenset.';
          end if;

          insert into workflow.monograph_candidate_source_needs
            (candidate_source_id, need_id, proposed_use)
          values (v_candidate_id, v_need_id, v_use ->> 'proposed_use')
          on conflict (candidate_source_id, need_id) do nothing;
        end loop;
      end if;

      if v_item ->> 'decision' is not null then
        begin
          v_decision := (v_item ->> 'decision')::workflow.monograph_candidate_decision;
        exception
          when invalid_text_representation then
            raise exception using
              errcode = 'invalid_parameter_value',
              message = format('%L er ikke en utvalgsbeslutning.', v_item ->> 'decision');
        end;

        perform workflow.decide_monograph_candidate_source(
          v_candidate_id, v_decision, v_item ->> 'decision_reason', null, p_run_id);
        v_decisions := v_decisions + 1;
      end if;
    end loop;
  end if;

  -- ------------------------------------------------------------------
  -- Forslagene om nye avgrensningsverdier
  --
  -- Forslag, og ikke utvidelser: aksepten er en egen handling med et annet
  -- opphav, og den kan ikke være denne kjøringen (MONOGRAPH_STANDARD.md §4).
  -- ------------------------------------------------------------------
  if p_result ? 'term_proposals' then
    if jsonb_typeof(p_result -> 'term_proposals') <> 'array' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'term_proposals er ikke en JSON-liste.';
    end if;

    for v_item in select value from jsonb_array_elements(p_result -> 'term_proposals') loop
      select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
      from jsonb_object_keys(v_item) as k(value)
      where k.value not in ('axis', 'label', 'rationale');
      if v_unknown is not null then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('Et forslag har felter denne kontrakten ikke kjenner: %s.', v_unknown);
      end if;

      begin
        v_axis := (v_item ->> 'axis')::knowledge.monograph_scope_axis;
      exception
        when invalid_text_representation then
          raise exception using
            errcode = 'invalid_parameter_value',
            message = format('%L er ikke en avgrensningsakse.', v_item ->> 'axis');
      end;

      perform knowledge.record_monograph_term_proposal(
        v_plan.edition_id, v_axis, v_item ->> 'label', v_item ->> 'rationale',
        p_actor_id, p_run_id, null, null, null, null, null, null);
      v_proposals := v_proposals + 1;
    end loop;
  end if;

  -- ------------------------------------------------------------------
  -- Kontrollen av søkedekningen
  -- ------------------------------------------------------------------
  if p_job.agent_role = 'source_quality_assessment' then
    v_control := p_result -> 'control';
    if v_control is null or jsonb_typeof(v_control) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen control som er et JSON-objekt.';
    end if;

    select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
    from jsonb_object_keys(v_control) as k(value)
    where k.value not in (
      'outcome', 'note', 'searched_independently', 'missed_candidates',
      'exclusions_checked', 'materiality_assessed'
    );
    if v_unknown is not null then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Kontrollen har felter denne kontrakten ikke kjenner: %s.', v_unknown);
    end if;

    -- En erklæring om egne søk er ikke en utførelse. Kontrollen har nettopp
    -- registrert sine egne søk i den samme transaksjonen; finnes det ingen som
    -- gikk, avvises erklæringen (SOURCE_POLICY.md §6).
    if coalesce((v_control ->> 'searched_independently')::boolean, false)
       and v_own_searches = 0 then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Kontrollen erklærer at den søkte selv, men har ikke rapportert et eget søk som gikk.',
        hint = 'En erklæring er ikke en utførelse. Rapporter dine egne motsøk i «searches»; et kontrollledd som bare leser generatorens valgte referanser, kan kontrollere sitatene, men ikke vurdere dekningsgraden (SOURCE_POLICY.md §6).';
    end if;

    v_control_id := workflow.record_monograph_coverage_control(
      v_plan_id,
      (v_control ->> 'outcome')::workflow.monograph_coverage_outcome,
      v_control ->> 'note',
      coalesce((v_control ->> 'searched_independently')::boolean, false),
      coalesce((v_control ->> 'missed_candidates')::integer, 0),
      coalesce((v_control ->> 'exclusions_checked')::integer, 0),
      coalesce((v_control ->> 'materiality_assessed')::boolean, false),
      p_run_id, p_actor_id);

    -- Godtar kontrollen dekningen, og holder porten, erklæres søkedekningen
    -- ferdig i den samme transaksjonen. Det er ikke et menneskelig
    -- godkjenningsklikk som mangler her: porten er den samme enten en redaktør
    -- eller kjeden erklærer dekningen ferdig, og en redaktør kan fortsatt gjøre
    -- det selv (SOURCE_POLICY.md §10).
    if (v_control ->> 'outcome') = 'accepted' then
      v_closure := workflow.monograph_search_closure_problem(v_plan_id);
      if v_closure is null then
        update workflow.monograph_search_plans
        set closed_at = now(),
            closed_note = format('Søkedekningen erklært ferdig av den separate kontrollen: %s',
                                 v_control ->> 'note'),
            closed_by_actor_id = p_actor_id
        where id = v_plan_id;

        update knowledge.monograph_needs n
        set work_state = 'appraising_sources', work_state_note = null
        where n.id in (
          select pn.need_id from workflow.monograph_search_plan_needs pn
          where pn.plan_id = v_plan_id)
          and n.relevance = 'relevant'
          and n.work_state in ('not_started', 'searching');

        v_closed := true;
      end if;
    end if;
  else
    -- Et registrert søkesvar legger kontrolloppgaven i køen.
    v_next_job := workflow.chain_task_for_search_coverage(v_plan_id);
  end if;

  return jsonb_build_object(
    'search_plan_id', v_plan_id,
    'searches_recorded', v_searches,
    'candidates_recorded', v_candidates,
    'selection_decisions', v_decisions,
    'term_proposals', v_proposals,
    'coverage_control_id', v_control_id,
    'search_coverage_closed', v_closed,
    'closure_problem', workflow.monograph_search_closure_problem(v_plan_id),
    'next_job_id', v_next_job);
end;
$$;

comment on function workflow.record_monograph_discovery_answer(workflow.pipeline_jobs, jsonb, jsonb, uuid, uuid) is
  'Registrerer ett eksternt agentsvar fra kildeoppdagelsen eller den separate kontrollen av søkedekningen, gjennom nøyaktig de samme skriveveiene den maskinelle søkeveien bruker. Én forskjell er hele poenget: utførelsesbeviset settes til agent_reported her og kan ikke oppgis i svaret, så en agents beretning om et verktøykall kan ikke gi seg ut for å være maskinelt bekreftet (SOURCE_POLICY.md §4.3). Ukjente felter avvises, en bruk for et behov utenfor oppgaven avvises, og kontrollens erklæring om egne søk avvises når kjøringen ikke har rapportert et eget søk som gikk. Et registrert søkesvar legger kontrolloppgaven i køen; en godtatt kontroll som holder porten, erklærer søkedekningen ferdig i den samme transaksjonen.';

revoke execute on function workflow.record_monograph_discovery_answer(workflow.pipeline_jobs, jsonb, jsonb, uuid, uuid) from public;
CREATE OR REPLACE FUNCTION workflow.record_agent_handoff_answer(p_pipeline_job_id uuid, p_answer jsonb, p_actor_id uuid, p_runner_connection_id uuid, p_lease_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_actor_id uuid;
  v_attempt integer;
  v_job workflow.pipeline_jobs;
  v_problem text;
  v_task jsonb;
  v_binding jsonb;
  v_input jsonb;
  v_answer_digest text;
  v_existing workflow.agent_handoff_imports;
  v_identity jsonb;
  v_provider text;
  v_model text;
  v_model_version text;
  v_disclosure provenance.model_version_disclosure;
  v_answered_at timestamptz;
  v_result jsonb;
  v_unknown text;
  v_agent_identity provenance.agent_identities;
  v_agent_actor_id uuid;
  v_registration provenance.role_model_assignments;
  v_semantic provenance.role_model_assignments;
  v_lease uuid;
  v_run_id uuid;
  v_outcome jsonb;
  v_extraction jsonb;
  v_claim jsonb;
  v_assessment jsonb;
  v_evidence_item_id uuid;
  v_ids uuid[];
  v_id uuid;
begin
  -- Kalleren har allerede fastslått hvem dette er: en redaktør med mandat i den
  -- manuelle veien, eller den registrerte kjørertilkoblingens egen registrant i
  -- den autonome. Autentiseringen hører i api-funksjonen, arbeidet her.
  v_actor_id := p_actor_id;

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = p_pipeline_job_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Det finnes ingen agentoppgave med id %L.', p_pipeline_job_id);
  end if;

  -- ------------------------------------------------------------------
  -- Gjentakelsen først, før alt annet
  --
  -- Det samme svaret sendt inn igjen — et dobbeltklikk, en gjenopptatt
  -- økt — skal svare med det som allerede ble registrert, framfor å lage
  -- et nytt klinisk objekt. Et *annet* svar på en jobb som allerede er
  -- besvart, er ikke en gjentakelse, og avvises.
  -- ------------------------------------------------------------------
  v_answer_digest := 'sha256:' || encode(sha256(convert_to(p_answer::text, 'UTF8')), 'hex');

  select i.* into v_existing
  from workflow.agent_handoff_imports i
  where i.pipeline_job_id = p_pipeline_job_id;

  if found then
    if v_existing.answer_digest = v_answer_digest then
      return jsonb_build_object(
        'imported', false,
        'already_imported', true,
        'delivered_by', case when v_existing.runner_connection_id is null
                             then 'manual' else 'autonomous_runner' end,
        'pipeline_job_id', p_pipeline_job_id,
        'agent_role', v_existing.agent_role::text,
        'agent_run_id', v_existing.agent_run_id,
        'outcome', v_existing.outcome
      );
    end if;
    raise exception using
      errcode = 'unique_violation',
      message = 'Denne agentoppgaven har allerede tatt imot et annet svar.',
      hint = 'Ett svar per oppgave. To svar ville gitt to kliniske objekter for det samme arbeidet, og ingen ville kunnet si hvilket som gjaldt (ANTIDEP_CONSTITUTION.md regel 4). Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;

  if v_job.state = 'succeeded' then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Agentoppgaven er allerede fullført.',
      hint = 'Jobben har et registrert utfall fra før. Skal arbeidet gjøres om igjen, er det en ny oppgave.';
  end if;
  -- Uttaket, før alt annet som handler om jobbens tilstand.
  --
  -- Den manuelle veien tar selv et uttak, som før. Den autonome kommer med et
  -- uttak den allerede holder, og det uttaket er svarets eneste adgangstegn: et
  -- håndtak som ikke er jobbens gjeldende leie, er et foreldet svar fra en
  -- kjøring som er overtatt eller har løpt ut, og det skal avvises før noe
  -- skrives (ANTIDEP_CONSTITUTION.md regel 4, 7).
  if p_lease_token is not null then
    if v_job.state <> 'leased'
       or v_job.lease_token is distinct from p_lease_token
       or v_job.lease_expires_at is null
       or v_job.lease_expires_at <= statement_timestamp() then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Uttaket dette svaret ble gjort under, gjelder ikke lenger.',
        hint = 'Leien er løpt ut eller overtatt av en annen kjøring. Hent arbeid på nytt framfor å levere et svar på et uttak som ikke er ditt; et svar fra et foreldet uttak ville kunnet skrive over arbeidet en annen kjøring nettopp gjorde.';
    end if;
    v_attempt := v_job.attempts;
    v_lease := p_lease_token;
  else
    if v_job.attempts >= v_job.max_attempts then
      raise exception using
        errcode = 'restrict_violation',
        message = 'Agentoppgaven har brukt opp forsøkene sine og blir stående.',
        hint = 'En oppbrukt jobb skal ikke se ut som en jobb som fortsatt er underveis (ANTIDEP_CONSTITUTION.md regel 4). Legg inn oppgaven på nytt dersom den skal forsøkes igjen.';
    end if;
    v_attempt := v_job.attempts + 1;
    v_lease := gen_random_uuid();
  end if;

  v_problem := workflow.agent_task_problem(v_job, p_lease_token);
  if v_problem is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = v_problem;
  end if;

  -- ------------------------------------------------------------------
  -- Formen på svaret, og bindingen
  -- ------------------------------------------------------------------
  if p_answer is null or jsonb_typeof(p_answer) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret er ikke et JSON-objekt.';
  end if;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(p_answer) as k(value)
  where k.value not in (
    'answer_version', 'task_version', 'role', 'job_key', 'request_digest',
    'output_schema_version', 'identity', 'answered_at', 'result'
  );
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret har felter denne kontrakten ikke kjenner: %s.', v_unknown),
      hint = 'Ukjente felter avvises framfor å ignoreres: et felt med skrivefeil ville ellers sett ut som en utelatt opplysning, og et felt ingen leser, ville vært en påstand uten virkning.';
  end if;

  v_task := workflow.agent_task(v_job);
  v_binding := v_task -> 'binding';
  v_input := v_binding -> 'input';

  if p_answer ->> 'answer_version' is distinct from workflow.agent_handoff_answer_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er skrevet mot %L, men Antidep leser %L.',
        p_answer ->> 'answer_version', workflow.agent_handoff_answer_version());
  end if;
  if p_answer ->> 'task_version' is distinct from workflow.agent_handoff_task_version() then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret gjelder oppgaveformen %L, men denne oppgaven er %L.',
        p_answer ->> 'task_version', workflow.agent_handoff_task_version());
  end if;
  if p_answer ->> 'role' is distinct from v_job.agent_role::text then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er avgitt i rollen %L, mens oppgaven gjelder rollen %L.',
        p_answer ->> 'role', v_job.agent_role::text),
      hint = 'Rollen avgjør hva svaret får lov til å registrere. Et svar fra ett ledd skal ikke kunne lukkes inn i et annet.';
  end if;
  if p_answer ->> 'job_key' is distinct from v_job.job_key then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret gjelder en annen agentoppgave enn den det importeres på.';
  end if;
  if p_answer ->> 'output_schema_version' is distinct from (v_task ->> 'output_schema_version') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svaret er skrevet mot svarformen %L, mens oppgaven krever %L.',
        p_answer ->> 'output_schema_version', v_task ->> 'output_schema_version');
  end if;
  if p_answer ->> 'request_digest' is distinct from (v_task ->> 'request_digest') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Svaret er avgitt på forespørselen %s, mens oppgaven nå er %s.',
        coalesce(p_answer ->> 'request_digest', '(mangler)'), v_task ->> 'request_digest'),
      hint = 'Avtrykket dekker rollen, oppgaven, promptmalen, svarformen og hele grunnlaget oppgaven ble bygget av. Er noe av det endret siden oppgaven ble hentet ut, gjelder ikke det gamle svaret lenger. Hent oppgaven på nytt og be om et nytt svar (ANTIDEP_CONSTITUTION.md regel 2, 4).';
  end if;

  v_result := p_answer -> 'result';
  if v_result is null or jsonb_typeof(v_result) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret har ingen result som er et JSON-objekt.';
  end if;

  -- ------------------------------------------------------------------
  -- Hvem som svarte
  -- ------------------------------------------------------------------
  v_identity := p_answer -> 'identity';
  if v_identity is null or jsonb_typeof(v_identity) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Svaret sier ikke hvilken modell som utførte oppgaven.',
      hint = 'identity skal ha provider, model og model_version_disclosure — og model_version når tjenesten faktisk oppgir en versjon. Uten den kan ingen si om kontrollene i kjeden er uavhengige (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  select string_agg(quote_literal(k.value), ', ' order by k.value) into v_unknown
  from jsonb_object_keys(v_identity) as k(value)
  where k.value not in ('provider', 'model', 'model_version', 'model_version_disclosure');
  if v_unknown is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('identity har felter denne kontrakten ikke kjenner: %s.', v_unknown);
  end if;

  -- Den samme lesningen tildelingen ble gjort med, slik at «samme modell» betyr
  -- det samme begge steder.
  v_identity := provenance.canonical_model_identity(
    v_identity ->> 'provider',
    v_identity ->> 'model',
    v_identity ->> 'model_version',
    v_identity ->> 'model_version_disclosure'
  );
  v_provider := v_identity ->> 'provider';
  v_model := v_identity ->> 'model';
  v_model_version := v_identity ->> 'model_version';
  v_disclosure := (v_identity ->> 'model_version_disclosure')::provenance.model_version_disclosure;

  -- Svaret bekrefter identiteten sin; det etablerer den ikke. Tildelingen er
  -- tatt på forhånd av en redaktør med mandat, den står i bindingen avtrykket er
  -- regnet av, og et svar fra en annen modell avvises her — før noe skrives. Et
  -- svar som fikk registrere sin egen identitet, ville etablert premisset som
  -- autoriserte det selv, og separasjonen mellom leddene ville hvilt på en
  -- erklæring modellen avga om seg selv (ANTIDEP_CONSTITUTION.md regel 3).
  v_semantic := provenance.require_semantic_model_assignment(v_job.agent_role, v_identity);

  if p_answer ->> 'answered_at' is not null then
    begin
      v_answered_at := (p_answer ->> 'answered_at')::timestamptz;
    exception
      when others then
        raise exception using
          errcode = 'invalid_parameter_value',
          message = format('answered_at er %L, som ikke er et tidspunkt.', p_answer ->> 'answered_at');
    end;

    -- Et svar kan ikke være avgitt i framtiden. Slakken finnes fordi agenten
    -- kjører på en annen maskin med en annen klokke, og et tidspunkt avrundet
    -- til nærmeste minutt ikke er en usann påstand; uten den ville en riktig
    -- import blitt stoppet av tre sekunder, og kontrollen blitt skrudd av
    -- framfor fulgt. Samme regel og samme slakk som i den filbaserte kjøringen.
    if v_answered_at > statement_timestamp() + interval '5 minutes'
       or v_answered_at < v_job.enqueued_at - interval '5 minutes' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format(
          'answered_at er %L, som ligger utenfor oppgaven: den ble lagt inn %L og importeres nå.',
          v_answered_at, v_job.enqueued_at
        ),
        hint = 'Tidspunktet registreres som da agenten svarte. Et svar avgitt før oppgaven fantes, eller inn i framtiden, er ikke en unøyaktighet — det er en usann proveniens (ANTIDEP_CONSTITUTION.md regel 4). La feltet stå tomt om du er usikker.';
    end if;
  end if;

  -- ------------------------------------------------------------------
  -- Uttaket og kjøringen
  --
  -- Importen gjør det en kjører ville gjort: tar ut jobben med en leie i
  -- rollens egen agentidentitet, åpner kjøringen for nettopp det uttaket, og
  -- melder utfallet. Da gjelder de samme bindingene og de samme reglene som
  -- for et automatisert ledd — inkludert at kjøringen ikke kan gjenbrukes på
  -- en annen jobb.
  -- ------------------------------------------------------------------
  select ai.* into v_agent_identity
  from provenance.agent_identities ai
  where ai.agent_role = v_job.agent_role
    and ai.valid_from <= statement_timestamp()
    and (ai.valid_to is null or ai.valid_to > statement_timestamp())
  order by ai.valid_from
  limit 1;

  if v_agent_identity.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig agentidentitet å registrere kjøringen under.', v_job.agent_role);
  end if;
  v_agent_actor_id := v_agent_identity.actor_id;

  v_registration := provenance.current_role_model(v_job.agent_role);
  if v_registration.id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Rollen %L har ingen gyldig modelltildeling for registreringsleddet.', v_job.agent_role);
  end if;

  -- Den manuelle veien tar uttaket her; den autonome tok det da den hentet
  -- arbeidet, og skal ikke ta det en gang til — et nytt uttak ville talt et
  -- forsøk som aldri fant sted, og byttet ut nøkkelen midt i sitt eget svar.
  if p_lease_token is null then
    update workflow.pipeline_jobs
    set state = 'leased',
        attempts = v_attempt,
        leased_by_agent_identity_id = v_agent_identity.id,
        lease_expires_at = statement_timestamp() + interval '15 minutes',
        lease_token = v_lease,
        -- Uttaket er et menneskes. Sto det en kjører på raden fra et uttak som
        -- rakk å løpe ut, er den ikke lenger holderen, og skal ikke bli stående
        -- som om den var det.
        runner_connection_id = null,
        -- En jobb som sto som failed, bærer et fullføringstidspunkt. Uttaket er
        -- et nytt forsøk, og et forsøk som pågår, er ikke fullført.
        completed_at = null
    where id = v_job.id;

    perform workflow.record_pipeline_job_event(
      v_job.id, v_job.state, 'leased'::workflow.pipeline_job_state,
      v_attempt, v_actor_id, null,
      'Uttak for import av et eksternt agentsvar.'
    );
  end if;

  insert into provenance.agent_runs (
    agent_identity_id, actor_id, agent_role,
    provider, model, model_version, model_version_disclosure,
    semantic_provider, semantic_model, semantic_model_version,
    semantic_model_version_disclosure,
    prompt_template_version, pipeline_version,
    status, input_manifest, input_source_version_id
  )
  values (
    v_agent_identity.id, v_agent_actor_id, v_job.agent_role,
    v_registration.provider, v_registration.model, v_registration.model_version,
    v_registration.model_version_disclosure,
    v_provider, v_model, v_model_version, v_disclosure,
    v_task ->> 'prompt_template_version', 'antidep-evidence/1',
    'running',
    jsonb_build_object('handoff', jsonb_build_object(
      'task_version', v_task ->> 'task_version',
      'answer_version', v_task ->> 'answer_version',
      'request_digest', v_task ->> 'request_digest',
      'output_schema_version', v_task ->> 'output_schema_version',
      'answer_digest', v_answer_digest,
      'answered_at', v_answered_at,
      'imported_by_actor_id', v_actor_id,
      'binding', v_binding
    )),
    case when v_job.agent_role = 'evidence_extraction'
         then (v_input ->> 'source_version_id')::uuid end
  )
  returning id into v_run_id;

  insert into workflow.pipeline_job_runs (agent_run_id, pipeline_job_id, lease_token, attempt)
  values (v_run_id, v_job.id, v_lease, v_attempt);

  -- ------------------------------------------------------------------
  -- Arbeidet, gjennom de samme skriveveiene som agentkjørerne bruker
  -- ------------------------------------------------------------------
  if v_job.agent_role = 'evidence_extraction' then
    v_extraction := v_result -> 'extraction';
    if v_extraction is null or jsonb_typeof(v_extraction) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen extraction som er et JSON-objekt.';
    end if;

    -- Katalogen er redaktørens avgrensning, og modellen velger innenfor den.
    -- En id utenfor oppgaven ville flyttet funnet til et annet virkestoff eller
    -- et naboendepunkt, og den ordrette kontrollen kontrollerer utdrag — ikke
    -- avgrensning.
    v_ids := workflow.manifest_uuids(v_input, 'drug_ids');
    v_id := workflow.manifest_uuid(v_extraction, 'intervention_drug_id');
    if v_id is null or not (v_id = any (v_ids)) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et virkestoff som ikke står blant virkestoffene i oppgaven.';
    end if;
    v_id := workflow.manifest_uuid(v_extraction, 'comparator_drug_id');
    if v_extraction ->> 'comparator_drug_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et komparatorvirkestoff som ikke står blant virkestoffene i oppgaven.';
    end if;
    v_ids := workflow.manifest_uuids(v_input, 'outcome_concept_ids');
    v_id := workflow.manifest_uuid(v_extraction, 'outcome_concept_id');
    if v_id is null or not (v_id = any (v_ids)) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir et endepunkt som ikke står blant endepunktene i oppgaven.';
    end if;
    v_ids := coalesce(workflow.manifest_uuids(v_input, 'population_ids'), array[]::uuid[]);
    v_id := workflow.manifest_uuid(v_extraction, 'population_id');
    if v_extraction ->> 'population_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir en populasjon som ikke står blant populasjonene i oppgaven.';
    end if;

    v_evidence_item_id := knowledge.record_evidence_item(
      (v_input ->> 'source_id')::uuid,
      v_extraction ->> 'design_code',
      v_extraction ->> 'population_availability',
      v_extraction ->> 'population_detail',
      v_extraction ->> 'sample_size_availability',
      (v_extraction ->> 'intervention_drug_id')::uuid,
      v_extraction ->> 'comparator_kind',
      (v_extraction ->> 'outcome_concept_id')::uuid,
      v_extraction ->> 'outcome_detail',
      v_extraction ->> 'timepoint_availability',
      v_extraction ->> 'reported_direction',
      v_extraction ->> 'estimate_availability',
      v_extraction ->> 'confidence_interval_availability',
      v_extraction ->> 'source_locator',
      (v_input ->> 'source_version_id')::uuid,
      workflow.manifest_uuid(v_extraction, 'population_id'),
      (v_extraction ->> 'sample_size')::integer,
      v_extraction ->> 'intervention_detail',
      workflow.manifest_uuid(v_extraction, 'comparator_drug_id'),
      v_extraction ->> 'comparator_detail',
      v_extraction ->> 'timepoint_min',
      v_extraction ->> 'timepoint_max',
      v_extraction ->> 'effect_measure',
      (v_extraction ->> 'estimate')::numeric,
      v_extraction ->> 'estimate_unit',
      (v_extraction ->> 'ci_lower')::numeric,
      (v_extraction ->> 'ci_upper')::numeric,
      (v_extraction ->> 'ci_level_percent')::numeric,
      v_extraction ->> 'limitations_text',
      v_extraction ->> 'source_quote',
      v_result -> 'field_groundings',
      'ai_assisted',
      v_agent_actor_id,
      v_run_id
    );

    perform workflow.assert_extraction_fully_grounded(v_evidence_item_id);
    v_outcome := jsonb_build_object('evidence_item_id', v_evidence_item_id);

  elsif v_job.agent_role = 'claim_synthesis' then
    v_claim := v_result -> 'claim';
    if v_claim is null or jsonb_typeof(v_claim) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen claim som er et JSON-objekt.';
    end if;

    -- Evidenssettet er oppgavens, ikke svarets. En lenke til et funn utenfor
    -- oppgaven ville gitt en påstand som hvilte på noe ingen hadde avgrenset.
    if exists (
      select 1
      from jsonb_array_elements(coalesce(v_result -> 'evidence_links', '[]'::jsonb)) as link(value)
      where workflow.manifest_uuid(link.value, 'evidence_item_id') is null
         or not (workflow.manifest_uuid(link.value, 'evidence_item_id') = any (
              select (e.value ->> 'evidence_item_id')::uuid
              from jsonb_array_elements(v_input -> 'evidence') as e(value)))
    ) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret lenker til et evidensfunn som ikke står i oppgaven.',
        hint = 'Hvilke funn en syntese kan bygge på, er en faglig avgrensning som ligger i oppgaven. En modell som fikk velge fritt, ville kunnet bygge påstanden på noe ingen hadde tatt stilling til.';
    end if;

    -- Og hele settet, ikke en delmengde av det. Et svar som utelot et funn som
    -- MOTSIER påstanden, ville gitt en syntese som hvilte på et annet grunnlag
    -- enn det redaktøren avgrenset — og uenigheten ville vært borte uten at noe
    -- i kjeden sa fra (ANTIDEP_CONSTITUTION.md regel 4).
    if exists (
      select 1
      from jsonb_array_elements(v_input -> 'evidence') as assigned(value)
      where not exists (
        select 1
        from jsonb_array_elements(coalesce(v_result -> 'evidence_links', '[]'::jsonb)) as link(value)
        where link.value ->> 'evidence_item_id' = assigned.value ->> 'evidence_item_id'
      )
    ) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret dekker ikke alle evidensfunnene oppgaven avgrenset.',
        hint = 'Hvert funn i oppgaven skal ha en relasjon til påstanden — også et funn som motsier den, som da føres som contradicts. Et utelatt funn ville gjort grunnlaget til et annet enn det som finnes.';
    end if;

    -- Populasjonen er redaktørens avgrensning, som katalogen i et
    -- ekstraksjonsoppdrag. En id kopiert ut av dossieret ville passert
    -- fremmednøkkelen og flyttet påstanden til en annen populasjon.
    v_ids := coalesce(workflow.manifest_uuids(v_input, 'population_ids'), array[]::uuid[]);
    v_id := workflow.manifest_uuid(v_claim, 'population_id');
    if v_claim ->> 'population_id' is not null and (v_id is null or not (v_id = any (v_ids))) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret oppgir en populasjon som ikke står blant populasjonene i oppgaven.';
    end if;

    v_outcome := knowledge.record_agent_claim_synthesis(
      v_run_id,
      v_agent_actor_id,
      (v_input ->> 'topic_concept_id')::uuid,
      (v_input ->> 'subject_drug_id')::uuid,
      v_claim ->> 'statement',
      v_claim ->> 'scope',
      v_claim ->> 'comparator_kind',
      v_claim ->> 'uncertainty_summary',
      v_result -> 'evidence_links',
      workflow.manifest_uuid(v_input, 'claim_id'),
      workflow.manifest_uuid(v_claim, 'population_id'),
      v_claim ->> 'timeframe_min',
      v_claim ->> 'timeframe_max',
      workflow.manifest_uuid(v_claim, 'comparator_drug_id'),
      v_claim ->> 'direction',
      v_claim ->> 'magnitude_measure',
      (v_claim ->> 'magnitude_value')::numeric,
      v_claim ->> 'magnitude_unit',
      v_claim ->> 'qualifiers'
    );

  elsif v_job.agent_role in ('source_discovery', 'source_quality_assessment') then
    v_outcome := workflow.record_monograph_discovery_answer(
      v_job, v_input, v_result, v_run_id, v_agent_actor_id);

  elsif v_job.agent_role = 'evidence_assessment' then
    v_assessment := v_result -> 'assessment';
    if v_assessment is null or jsonb_typeof(v_assessment) <> 'object' then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Svaret har ingen assessment som er et JSON-objekt.';
    end if;

    v_outcome := knowledge.record_evidence_assessment_row(
      v_run_id,
      v_agent_actor_id,
      (v_input ->> 'claim_revision_id')::uuid,
      -- Avtrykket av evidenssettet er oppgavens eget, ikke svarets: oppgaven
      -- viste nøyaktig det settet, og request_digest dekker det allerede. En
      -- verdi fra svaret ville vært en påstand om hva agenten så.
      v_input ->> 'evidence_set_digest',
      v_assessment ->> 'framework',
      v_assessment ->> 'certainty_level',
      v_assessment ->> 'rationale',
      v_assessment ->> 'risk_of_bias',
      v_assessment ->> 'inconsistency',
      v_assessment ->> 'indirectness',
      v_assessment ->> 'imprecision',
      v_assessment ->> 'publication_bias',
      v_assessment ->> 'other_considerations',
      v_assessment ->> 'evidence_gap'
    );

  else
    -- Uttømmende over rollene. En rolle uten en gren ville ellers fått
    -- oppgaven registrert som fullført uten at noe klinisk arbeid ble skrevet.
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Rollen %s har ingen skrivevei for et eksternt agentsvar.',
                       v_job.agent_role);
  end if;

  -- ------------------------------------------------------------------
  -- Utfallet
  -- ------------------------------------------------------------------
  update provenance.agent_runs
  set status = 'succeeded', completed_at = now(), output_manifest = v_outcome
  where id = v_run_id;

  update workflow.pipeline_jobs
  set state = 'succeeded',
      agent_run_id = v_run_id,
      output_manifest = v_outcome,
      completed_at = now(),
      failure_reason = null
  where id = v_job.id;

  perform workflow.record_pipeline_job_event(
    v_job.id, 'leased'::workflow.pipeline_job_state, 'succeeded'::workflow.pipeline_job_state,
    v_attempt, v_actor_id, null,
    case when p_runner_connection_id is null
      then 'Eksternt agentsvar importert og registrert.'
      else 'Eksternt agentsvar levert av en autonom kjører og registrert.' end
  );

  insert into workflow.agent_handoff_imports (
    pipeline_job_id, agent_role, request_digest, answer_digest,
    agent_run_id, imported_by_actor_id, answered_at, outcome,
    runner_connection_id
  )
  values (
    v_job.id, v_job.agent_role, v_task ->> 'request_digest', v_answer_digest,
    v_run_id, v_actor_id, v_answered_at, v_outcome,
    p_runner_connection_id
  );

  return jsonb_build_object(
    'imported', true,
    'already_imported', false,
    'delivered_by', case when p_runner_connection_id is null then 'manual' else 'autonomous_runner' end,
    'pipeline_job_id', v_job.id,
    'agent_role', v_job.agent_role::text,
    'agent_run_id', v_run_id,
    'request_digest', v_task ->> 'request_digest',
    'model', jsonb_build_object(
      'provider', v_provider, 'model', v_model,
      'model_version', v_model_version,
      'model_version_disclosure', v_disclosure::text),
    'outcome', v_outcome
  );
end;
$function$;

-- ----------------------------------------------------------------------------
-- 5. Kjedeovergangene
--
-- En ny søkeplan legger søkeoppgaven i køen, og et registrert søkesvar legger
-- kontrolloppgaven i køen. Formen er den samme som for de andre leddene: en
-- overgang som utleder alt av rader som allerede finnes, idempotent på
-- (rolle, jobbnøkkel), uten en eneste verdi fra en kaller.
-- ----------------------------------------------------------------------------
create function workflow.chain_task_for_search_plan(p_plan_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_manifest jsonb;
  v_subject text;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;

  if not found or v_plan.closed_at is not null or v_plan.paused_at is not null then
    return null;
  end if;

  v_manifest := jsonb_build_object(
    'search_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version);

  v_subject := v_plan.id::text;
  perform workflow.lock_chain_subject('source_discovery'::provenance.agent_role, v_subject);
  if workflow.agent_task_subject_queued('source_discovery'::provenance.agent_role, v_subject) then
    return null;
  end if;

  return workflow.chain_enqueue_job(
    'source_discovery'::provenance.agent_role,
    workflow.agent_task_job_key('source_discovery'::provenance.agent_role, v_manifest),
    v_manifest,
    (select e.ordered_by_actor_id from knowledge.monograph_editions e
     where e.id = v_plan.edition_id),
    null,
    true,
    'Søkeoppgaven lagt i køen av den nye søkeplanen.');
end;
$$;

comment on function workflow.chain_task_for_search_plan(uuid) is
  'Legger søkeoppgaven i køen for én ny søkeplan, som en ekstern agentoppgave gjennom den samme kontrakten og den samme jobbtabellen de øvrige semantiske leddene bruker. Idempotent på planen: to oppgaver om den samme planen i den samme rollen er ett stykke arbeid, og låsen tas før spørsmålet om oppgaven finnes. Gjør ingenting for en plan som er erklært ferdig eller står på pause. Svarer med jobbens id, eller NULL.';

revoke execute on function workflow.chain_task_for_search_plan(uuid) from public;

create function workflow.chain_task_for_search_coverage(p_plan_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_plan workflow.monograph_search_plans;
  v_manifest jsonb;
  v_subject text;
begin
  select p.* into v_plan
  from workflow.monograph_search_plans p where p.id = p_plan_id;

  if not found or v_plan.closed_at is not null or v_plan.paused_at is not null then
    return null;
  end if;

  -- Kontrollen kontrollerer et utført søk. Finnes det ikke, er det ingenting å
  -- kontrollere ennå (SOURCE_POLICY.md §6).
  if not exists (
    select 1 from workflow.monograph_searches s
    where s.plan_id = p_plan_id
      and s.plan_version = v_plan.plan_version
      and s.outcome in ('executed', 'zero_results')
  ) then
    return null;
  end if;

  if exists (
    select 1 from workflow.monograph_coverage_controls cc
    where cc.plan_id = p_plan_id and cc.plan_version = v_plan.plan_version
  ) then
    return null;
  end if;

  v_manifest := jsonb_build_object(
    'search_plan_id', v_plan.id,
    'plan_version', v_plan.plan_version);

  v_subject := v_plan.id::text;
  perform workflow.lock_chain_subject(
    'source_quality_assessment'::provenance.agent_role, v_subject);
  if workflow.agent_task_subject_queued(
       'source_quality_assessment'::provenance.agent_role, v_subject) then
    return null;
  end if;

  return workflow.chain_enqueue_job(
    'source_quality_assessment'::provenance.agent_role,
    workflow.agent_task_job_key('source_quality_assessment'::provenance.agent_role, v_manifest),
    v_manifest,
    (select e.ordered_by_actor_id from knowledge.monograph_editions e
     where e.id = v_plan.edition_id),
    null,
    true,
    'Kontrolloppgaven lagt i køen av det registrerte søket.');
end;
$$;

comment on function workflow.chain_task_for_search_coverage(uuid) is
  'Legger den separate kontrollen av søkedekningen i køen for én søkeplan, når det finnes et utført søk å kontrollere og planversjonen ikke allerede er kontrollert. Samme kontrakt, samme jobbtabell og samme idempotens som de øvrige semantiske leddene. Svarer med jobbens id, eller NULL.';

revoke execute on function workflow.chain_task_for_search_coverage(uuid) from public;

-- Og innleggingen skjer der planen faktisk blir til. `build_monograph_search_plans`
-- er den ene veien planer opprettes på, så overgangen hører der — framfor i en
-- trigger som måtte kjørt etter at sporene var lagt inn.
create or replace function workflow.build_monograph_search_plans(p_edition_id uuid)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_edition knowledge.monograph_editions;
  v_created integer := 0;
  v_row record;
  v_plan_id uuid;
  v_plan_key text;
  v_new_plans uuid[] := array[]::uuid[];
  v_plan uuid;
begin
  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.id = p_edition_id
  for update;

  if not found or v_edition.superseded_at is not null then
    return 0;
  end if;

  for v_row in
    select
      n.id as need_id,
      n.indication_concept_id, n.outcome_concept_id, n.population_id,
      n.comparator_drug_id, n.switch_target_drug_id,
      n.scope_labels, n.scope_digest,
      sp.id as profile_id, sp.code as profile_code
    from knowledge.monograph_needs n
    join knowledge.monograph_question_templates t on t.id = n.template_id
    join knowledge.monograph_template_profiles tp on tp.template_id = t.id
    join knowledge.monograph_source_profiles sp on sp.id = tp.profile_id
    where n.edition_id = p_edition_id
      and n.relevance = 'relevant'
      and n.work_state <> 'agent_complete'
    order by n.created_at, sp.ordinal
  loop
    v_plan_key := format('%s|%s', v_row.profile_code, v_row.scope_digest);

    select p.id into v_plan_id
    from workflow.monograph_search_plans p
    where p.edition_id = p_edition_id and p.plan_key = v_plan_key;

    if v_plan_id is null then
      insert into workflow.monograph_search_plans (
        edition_id, profile_id, plan_key,
        indication_concept_id, outcome_concept_id, population_id,
        comparator_drug_id, switch_target_drug_id,
        scope_labels, scope_digest, created_by_actor_id
      )
      values (
        p_edition_id, v_row.profile_id, v_plan_key,
        v_row.indication_concept_id, v_row.outcome_concept_id, v_row.population_id,
        v_row.comparator_drug_id, v_row.switch_target_drug_id,
        v_row.scope_labels, v_row.scope_digest, v_edition.ordered_by_actor_id
      )
      on conflict (edition_id, plan_key) do nothing
      returning id into v_plan_id;

      if v_plan_id is null then
        select p.id into v_plan_id
        from workflow.monograph_search_plans p
        where p.edition_id = p_edition_id and p.plan_key = v_plan_key;
      else
        v_created := v_created + 1;
        v_new_plans := v_new_plans || v_plan_id;

        insert into workflow.monograph_search_track_attempts (plan_id, track_id)
        select v_plan_id, k.id
        from knowledge.monograph_search_tracks k
        join knowledge.monograph_search_track_profiles kp on kp.track_id = k.id
        where k.standard_version = v_edition.standard_version
          and kp.profile_id = v_row.profile_id
        on conflict (plan_id, track_id) do nothing;
      end if;
    end if;

    insert into workflow.monograph_search_plan_needs (plan_id, need_id)
    values (v_plan_id, v_row.need_id)
    on conflict (plan_id, need_id) do nothing;
  end loop;

  -- Søkeoppgavene legges inn etter at sporene og behovskoblingene står, slik at
  -- forhåndskontrollen av grunnlaget leser en komplett plan.
  foreach v_plan in array v_new_plans loop
    perform workflow.chain_task_for_search_plan(v_plan);
  end loop;

  return v_created;
end;
$$;
