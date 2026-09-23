-- ============================================================================
-- Migrasjon 014f — planens egen beslutning styrer bruken av en kilde
--
-- 014c la utvalgsbeslutningen og vesentligheten per plan: den samme kilden kan
-- være inkludert for effektspørsmålet og ekskludert for bivirkningen. Men
-- bruken av kilden — hvilket behov den skal brukes for, og til hva — sto
-- fortsatt på kilden alene (`workflow.monograph_candidate_source_needs`), og
-- innhentingen leste den gjennom kildens samlede utfall. Plan A kunne dermed
-- ha foreslått en bruk for sitt behov og siden ekskludert kilden, mens plan B
-- inkluderte den; Bs valg gjorde kilden valgt for utgaven, og innhentingen
-- førte så opp As bruk og satte As behov i arbeid. Det er nøyaktig den
-- kryssplan-virkningen beslutningen per plan skulle fjerne.
--
-- Bruken bindes nå til planen gjennom behovet: et behov hører til planen som
-- dekker det (`workflow.monograph_search_plan_needs`), og bruken for det behovet
-- gjelder bare når nettopp den planen har valgt eller inkludert kilden.
-- `workflow.monograph_wanted_candidate_needs` er den ene definisjonen av det,
-- og hver vei videre leser den:
--
--   * innhentingen (`workflow.acquire_monograph_candidate`),
--   * forespørslene om fulltekst og myndighetsdokument og den faglige grunnen
--     de bærer,
--   * registreringen av den godkjente kildebruken, med beslutningens opphav fra
--     planen som valgte kilden,
--   * redaktørens oversikt over forespørslene, og
--   * rekonsilieringen av avbrutte overganger.
--
-- Et behov ingen plan som har funnet kilden, dekker — lagt til utenom en
-- søkeplan — følger kildens samlede utfall, som før.
--
-- Og når en plan velger en kilde en annen plan alt hadde valgt, endres ikke
-- kildens samlede utfall, og kildens egen overgang til innhentingen går ikke.
-- En overgang på planens beslutning tar da den planens behov.
--
-- Funksjonskroppene under er hentet fra databasen med `pg_get_functiondef` og
-- splisset, som i 20261003095000_monograph_discovery_handoff.sql: den eneste endringen i hver av dem er at behovene leses
-- fra `workflow.monograph_wanted_candidate_needs`, og — i registreringen av
-- kildebruken — at opphavet er planens beslutning.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Bruken en plan faktisk vil ha
-- ----------------------------------------------------------------------------

create view workflow.monograph_wanted_candidate_needs
  with (security_invoker = true)
as
-- Et behov på en plan som har funnet kilden: bruken gjelder når den planen har
-- valgt eller inkludert kilden, med den planens beslutning som opphav.
select cn.id,
       cn.candidate_source_id,
       cn.need_id,
       cn.proposed_use,
       cn.created_at,
       w.plan_id,
       w.decided_by_actor_id,
       w.decided_by_agent_run_id
from workflow.monograph_candidate_source_needs cn
cross join lateral (
  select l.plan_id, l.decided_by_actor_id, l.decided_by_agent_run_id
  from workflow.monograph_candidate_source_plans l
  join workflow.monograph_search_plan_needs pn
    on pn.plan_id = l.plan_id and pn.need_id = cn.need_id
  where l.candidate_source_id = cn.candidate_source_id
    and l.decision in ('selected_for_retrieval'::workflow.monograph_candidate_decision,
                       'included'::workflow.monograph_candidate_decision)
  order by workflow.monograph_candidate_decision_rank(l.decision),
           l.decided_at desc nulls last, l.id
  limit 1
) w
union all
-- Et behov ingen plan som har funnet kilden, dekker: kildens samlede utfall.
select cn.id,
       cn.candidate_source_id,
       cn.need_id,
       cn.proposed_use,
       cn.created_at,
       null::uuid,
       c.decided_by_actor_id,
       c.decided_by_agent_run_id
from workflow.monograph_candidate_source_needs cn
join workflow.monograph_candidate_sources c on c.id = cn.candidate_source_id
where c.decision in ('selected_for_retrieval'::workflow.monograph_candidate_decision,
                     'included'::workflow.monograph_candidate_decision)
  and not exists (
    select 1
    from workflow.monograph_candidate_source_plans l
    join workflow.monograph_search_plan_needs pn
      on pn.plan_id = l.plan_id and pn.need_id = cn.need_id
    where l.candidate_source_id = cn.candidate_source_id);

comment on view workflow.monograph_wanted_candidate_needs is
  'Den foreslåtte bruken av en kandidatkilde for et behov, når bruken faktisk er ønsket: behovet hører til en plan som har funnet kilden og valgt eller inkludert den — med den planens beslutning som opphav — eller, for et behov ingen slik plan dekker, når kildens samlede utfall er valgt eller inkludert. Den ene definisjonen innhentingen, forespørslene og registreringen av kildebruken leser, slik at én plans valg aldri fører opp en annen plans bruk (migrasjon 014f).';

revoke all on workflow.monograph_wanted_candidate_needs from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. Innhentingen og det som følger den, fra de ønskede behovene
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION workflow.acquire_monograph_candidate(p_candidate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_cand workflow.monograph_candidate_sources;
  v_source_id uuid;
  v_actor_id uuid;
  v_research_needs uuid[];
  v_authority_needs uuid[];
  v_unscoped_needs uuid[];
  v_research_version knowledge.source_versions;
  v_authority_version knowledge.source_versions;
  v_need_id uuid;
  v_uses integer := 0;
  v_result jsonb := jsonb_build_object();
begin
  select c.* into v_cand
  from workflow.monograph_candidate_sources c
  where c.id = p_candidate_id
  for update;

  if not found or v_cand.decision not in ('selected_for_retrieval', 'included') then
    return null;
  end if;

  -- Behovene, delt etter hva slags materiale de trenger.
  with behov as (
    select cn.need_id,
           knowledge.monograph_need_material_kind(cn.need_id) as kind,
           n.outcome_concept_id
    from workflow.monograph_wanted_candidate_needs cn
    join knowledge.monograph_needs n on n.id = cn.need_id
    where cn.candidate_source_id = p_candidate_id
      and n.relevance <> 'not_applicable'
  )
  select
    coalesce(array_agg(distinct b.need_id) filter (
      where b.kind = 'research_full_text' and b.outcome_concept_id is not null),
      array[]::uuid[]),
    coalesce(array_agg(distinct b.need_id) filter (
      where b.kind = 'authority_document'), array[]::uuid[]),
    coalesce(array_agg(distinct b.need_id) filter (
      where b.kind = 'research_full_text' and b.outcome_concept_id is null),
      array[]::uuid[])
    into v_research_needs, v_authority_needs, v_unscoped_needs
  from behov b;

  if cardinality(v_research_needs) = 0
     and cardinality(v_authority_needs) = 0
     and cardinality(v_unscoped_needs) = 0 then
    return null;
  end if;

  v_actor_id := coalesce(v_cand.decided_by_actor_id, v_cand.recorded_by_actor_id);

  -- En kandidat som bare er identifisert med en tittel, kan ikke bli en kilde:
  -- to publikasjoner kan hete det samme, og en kilde opprettet på tittel ville
  -- enten blitt to kilder eller slått sammen to arbeider. Det er en avklaring
  -- som mangler, og den sier seg selv på behovene framfor å stoppe stille.
  if workflow.monograph_candidate_identifier_system(v_cand.identifier_kind) is null then
    foreach v_need_id in array
      (v_research_needs || v_authority_needs || v_unscoped_needs)
    loop
      perform knowledge.set_monograph_need_work_state(
        v_need_id, 'awaiting_clarification'::knowledge.monograph_work_state,
        format('Kilden %L er valgt, men er bare identifisert med en tittel. '
               || 'Registrer treffets DOI, PMID, PMCID, adresse eller '
               || 'forsøksregisternummer, og innhentingen fortsetter.', v_cand.title),
        null, v_actor_id, v_cand.decided_by_agent_run_id);
    end loop;

    return jsonb_build_object(
      'source_id', null,
      'identifier_missing', true,
      'needs_awaiting_clarification',
        cardinality(v_research_needs || v_authority_needs || v_unscoped_needs));
  end if;

  v_source_id := workflow.ensure_monograph_candidate_source(p_candidate_id);

  -- ------------------------------------------------------------------------
  -- Det private kildebiblioteket først
  --
  -- Finnes dokumentet allerede — fordi en annen monografi, et annet behov
  -- eller en tidligere manuell registrering brakte det inn — er materialet i
  -- hus, og ingen skal bli bedt om det på nytt (SOURCE_POLICY.md §5).
  -- ------------------------------------------------------------------------
  select sv.* into v_research_version
  from knowledge.source_versions sv
  where sv.source_id = v_source_id
    and sv.representation = 'full_text'
  order by sv.retrieved_at desc, sv.id
  limit 1;

  select sv.* into v_authority_version
  from knowledge.source_versions sv
  where sv.source_id = v_source_id
    and sv.representation in ('full_text', 'regulatory_summary',
                              'registry_record', 'secondary_report')
  order by sv.retrieved_at desc, sv.id
  limit 1;

  if cardinality(v_research_needs) > 0 then
    if v_research_version.id is not null then
      v_uses := v_uses + workflow.register_monograph_source_uses(v_research_version.id);
      foreach v_need_id in array v_research_needs loop
        perform knowledge.set_monograph_need_work_state(
          v_need_id, 'extracting'::knowledge.monograph_work_state,
          'Fullteksten fantes i det private kildebiblioteket, og ekstraksjonen er lagt i køen.',
          null, v_actor_id, v_cand.decided_by_agent_run_id);
      end loop;
      v_result := v_result || jsonb_build_object(
        'research', jsonb_build_object(
          'from_library', true,
          'source_version_id', v_research_version.id));
    else
      v_result := v_result || jsonb_build_object(
        'research', coalesce(
          workflow.request_monograph_full_text(v_source_id, v_actor_id),
          jsonb_build_object('requested', false)));
      foreach v_need_id in array v_research_needs loop
        perform knowledge.set_monograph_need_work_state(
          v_need_id, 'awaiting_access'::knowledge.monograph_work_state,
          case when v_cand.access_limited
               then 'Fullteksten er etterspurt. Kilden har en registrert tilgangsbegrensning: '
                    || v_cand.access_limitation_note
               else 'Fullteksten er etterspurt, og arbeidet fortsetter når dokumentet er registrert.'
          end,
          null, v_actor_id, v_cand.decided_by_agent_run_id);
      end loop;
    end if;
  end if;

  if cardinality(v_authority_needs) > 0 then
    if v_authority_version.id is not null then
      v_uses := v_uses + workflow.register_monograph_source_uses(v_authority_version.id);
      foreach v_need_id in array v_authority_needs loop
        perform knowledge.set_monograph_need_work_state(
          v_need_id, 'extracting'::knowledge.monograph_work_state,
          'Dokumentet fantes i det private kildebiblioteket, og er godkjent for dette behovet.',
          null, v_actor_id, v_cand.decided_by_agent_run_id);
      end loop;
      v_result := v_result || jsonb_build_object(
        'authority', jsonb_build_object(
          'from_library', true,
          'source_version_id', v_authority_version.id));
    else
      v_result := v_result || jsonb_build_object(
        'authority', coalesce(
          workflow.request_monograph_document(
            v_source_id, v_cand.edition_id, v_actor_id),
          jsonb_build_object('requested', false)));
      foreach v_need_id in array v_authority_needs loop
        perform knowledge.set_monograph_need_work_state(
          v_need_id, 'awaiting_access'::knowledge.monograph_work_state,
          'Myndighets- eller preparatdokumentet er etterspurt, og arbeidet fortsetter når det er registrert.',
          null, v_actor_id, v_cand.decided_by_agent_run_id);
      end loop;
    end if;
  end if;

  -- Et forskningsbehov uten et navngitt endepunkt kan ikke bære et funn:
  -- ekstraksjonen har ingen avgrensning å kontrolleres mot. Det er en avklaring
  -- som mangler, og den sier seg selv på behovet framfor å bli tiet bort eller
  -- bli til «ingen relevante studier» (ANTIDEP_CONSTITUTION.md regel 4).
  foreach v_need_id in array v_unscoped_needs loop
    perform knowledge.set_monograph_need_work_state(
      v_need_id, 'awaiting_clarification'::knowledge.monograph_work_state,
      'Kilden er valgt, men behovet har ikke noe navngitt endepunkt ennå. '
      || 'Et forskningsfunn kan ikke kontrolleres mot et spørsmål uten et utfall: '
      || 'foreslå utfallsverdien fra dette behovet, og arbeidet fortsetter.',
      null, v_actor_id, v_cand.decided_by_agent_run_id);
  end loop;

  return v_result || jsonb_build_object(
    'source_id', v_source_id,
    'approved_uses_written', v_uses,
    'research_needs', cardinality(v_research_needs),
    'authority_needs', cardinality(v_authority_needs),
    'needs_awaiting_clarification', cardinality(v_unscoped_needs));
end;
$function$;

CREATE OR REPLACE FUNCTION workflow.request_monograph_full_text(p_source_id uuid, p_actor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_drug_ids uuid[];
  v_outcome_ids uuid[];
  v_population_ids uuid[];
  v_any_population boolean;
  v_problem text;
  v_retrieved_from text;
  v_existing workflow.full_text_requests;
  v_reference text;
  v_widened boolean := false;
begin
  -- Avgrensningen, samlet over alle valgte kandidatrader for kilden. Behovene
  -- uten et navngitt endepunkt kan ikke bære et forskningsfunn, og de tas
  -- derfor ikke med her; de får sin egen synlige tilstand.
  select workflow.sorted_unique(array_agg(distinct e.drug_id)),
         workflow.sorted_unique(array_agg(distinct n.outcome_concept_id)),
         workflow.sorted_unique(
           array_remove(array_agg(distinct n.population_id), null)),
         bool_or(n.population_id is null)
    into v_drug_ids, v_outcome_ids, v_population_ids, v_any_population
  from workflow.monograph_candidate_sources c
  join workflow.monograph_wanted_candidate_needs cn on cn.candidate_source_id = c.id
  join knowledge.monograph_needs n on n.id = cn.need_id
  join knowledge.monograph_editions e on e.id = n.edition_id
  where c.source_id = p_source_id
    and c.decision in ('selected_for_retrieval', 'included')
    and n.relevance <> 'not_applicable'
    and n.outcome_concept_id is not null
    and knowledge.monograph_need_material_kind(cn.need_id) = 'research_full_text';

  -- Et behov uten en populasjonsavgrensning gjelder enhver populasjon, og
  -- avgrensningen på forespørselen er en tillatelsesliste: en tom liste ville
  -- betydd at ekstraksjonen ikke fikk navngi den populasjonen artikkelen
  -- faktisk rapporterer, og et funn uten populasjon er et dårligere funn enn
  -- det kilden gir. Listen fylles derfor med de registrerte populasjonene.
  --
  -- Grensen er forespørselens egen (50). Blir katalogen større enn det, står
  -- de eksplisitt avgrensede først, og resten faller utenfor — en synlig
  -- begrensning framfor en avvisning av hele innhentingen.
  if coalesce(v_any_population, false) then
    select workflow.sorted_unique(
             coalesce(v_population_ids, array[]::uuid[])
             || coalesce(array_agg(p.id), array[]::uuid[]))
      into v_population_ids
    from (
      select pop.id
      from catalog.populations pop
      where not (pop.id = any (coalesce(v_population_ids, array[]::uuid[])))
      order by pop.created_at, pop.id
      limit greatest(0, 50 - cardinality(coalesce(v_population_ids, array[]::uuid[])))
    ) p;
  end if;

  if v_outcome_ids is null or cardinality(v_outcome_ids) = 0 then
    return null;
  end if;

  v_problem := workflow.full_text_request_scope_problem(
    v_drug_ids, v_outcome_ids, coalesce(v_population_ids, array[]::uuid[]));
  if v_problem is not null then
    raise exception using errcode = 'invalid_parameter_value', message = v_problem;
  end if;

  select r.* into v_existing
  from workflow.full_text_requests r
  where r.source_id = p_source_id and r.state = 'open'
  for update;

  if v_existing.id is not null then
    -- En union som har vokst, skrives inn. Den forskningsfaglige forespørselen
    -- avviser ellers en annen avgrensning med vilje, fordi et stille ja der
    -- ville latt arbeidet forsvinne; her er utvidelsen nettopp det som skal
    -- skje, og den er en utvidelse og ikke en omskriving: unionen inneholder
    -- alt den gamle avgrensningen inneholdt.
    if not (v_existing.drug_ids @> v_drug_ids
            and v_existing.outcome_concept_ids @> v_outcome_ids
            and v_existing.population_ids @> coalesce(v_population_ids, array[]::uuid[]))
    then
      update workflow.full_text_requests r
      set drug_ids = workflow.sorted_unique(r.drug_ids || v_drug_ids),
          outcome_concept_ids =
            workflow.sorted_unique(r.outcome_concept_ids || v_outcome_ids),
          population_ids = workflow.sorted_unique(
            r.population_ids || coalesce(v_population_ids, array[]::uuid[]))
      where r.id = v_existing.id;
      v_widened := true;
    end if;

    return jsonb_build_object(
      'reference', v_existing.reference,
      'requested', false,
      'widened', v_widened,
      'state', v_existing.state::text);
  end if;

  v_retrieved_from := workflow.source_retrieval_address(p_source_id);
  if v_retrieved_from is null then
    -- Uten en adresse er det ingen utgiver å hente fra, og en kildeversjon uten
    -- opphav er ikke sporbar. En PMID utledes bevisst ikke: en PubMed-side
    -- viser sammendraget og ikke dokumentet.
    select 'https://doi.org/' || i.identifier_value into v_retrieved_from
    from knowledge.source_identifiers i
    where i.source_id = p_source_id and i.identifier_system = 'doi'
    limit 1;
  end if;
  if v_retrieved_from is null then
    select i.identifier_value into v_retrieved_from
    from knowledge.source_identifiers i
    where i.source_id = p_source_id and i.identifier_system = 'url'
    limit 1;
  end if;
  if v_retrieved_from is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kilden har ingen registrert adresse, så Antidep kan ikke si hvor fullteksten hentes fra.',
      hint = 'En PMID utledes bevisst ikke: en PubMed-side viser sammendraget og ikke dokumentet. Registrer kildens DOI eller adresse først.';
  end if;

  begin
    insert into workflow.full_text_requests
      (source_id, drug_ids, outcome_concept_ids, population_ids,
       retrieved_from, requested_by_actor_id)
    values
      (p_source_id, v_drug_ids, v_outcome_ids,
       coalesce(v_population_ids, array[]::uuid[]),
       v_retrieved_from, p_actor_id)
    returning reference into v_reference;
  exception
    when unique_violation then
      select r.* into v_existing
      from workflow.full_text_requests r
      where r.source_id = p_source_id and r.state = 'open';
      return jsonb_build_object(
        'reference', v_existing.reference, 'requested', false,
        'widened', false, 'state', v_existing.state::text);
  end;

  return jsonb_build_object(
    'reference', v_reference, 'requested', true, 'widened', false, 'state', 'open');
end;
$function$;

CREATE OR REPLACE FUNCTION workflow.request_monograph_document(p_source_id uuid, p_edition_id uuid, p_actor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_representation knowledge.source_representation;
  v_reason text;
  v_retrieved_from text;
  v_existing workflow.monograph_document_requests;
  v_reference text;
begin
  -- Den faglige grunnen, satt sammen av behovene selv: malens kode, spørsmålet
  -- og hva kilden er foreslått brukt til. Et menneske skal kunne lese den uten
  -- å kjenne systemet, og uten å bli bedt om en teknisk registrering
  -- (SOURCE_POLICY.md §5).
  select string_agg(
           format('%s (%s): %s',
                  t.code,
                  coalesce(knowledge.monograph_need_scope_label(n.id), 'uten avgrensning'),
                  cn.proposed_use),
           E'\n' order by t.code, n.id)
    into v_reason
  from workflow.monograph_candidate_sources c
  join workflow.monograph_wanted_candidate_needs cn on cn.candidate_source_id = c.id
  join knowledge.monograph_needs n on n.id = cn.need_id
  join knowledge.monograph_question_templates t on t.id = n.template_id
  where c.source_id = p_source_id
    and c.edition_id = p_edition_id
    and c.decision in ('selected_for_retrieval', 'included')
    and n.relevance <> 'not_applicable'
    and knowledge.monograph_need_material_kind(cn.need_id) = 'authority_document';

  if v_reason is null then
    return null;
  end if;

  -- Representasjonen følger kildetypen: en preparatomtale og en regulatorisk
  -- melding *er* sammendrag av myndighetens egen vurdering, og en retningslinje
  -- er et komplett dokument. Å be om «fulltekst» av en preparatomtale ville
  -- vært å be om noe som ikke finnes.
  select case s.source_type
           when 'summary_of_product_characteristics' then 'regulatory_summary'
           when 'regulatory_communication' then 'regulatory_summary'
           when 'public_dataset' then 'registry_record'
           else 'full_text'
         end::knowledge.source_representation
    into v_representation
  from knowledge.sources s
  where s.id = p_source_id;

  select r.* into v_existing
  from workflow.monograph_document_requests r
  where r.source_id = p_source_id and r.state = 'open'
  for update;

  if v_existing.id is not null then
    -- Den samme grunnen står ikke to ganger; en grunn som har vokst, skrives
    -- inn. Forespørselen er den samme, og den er ikke en ny bestilling.
    if v_existing.professional_reason is distinct from v_reason then
      update workflow.monograph_document_requests r
      set professional_reason = v_reason
      where r.id = v_existing.id;
    end if;
    return jsonb_build_object(
      'reference', v_existing.reference, 'requested', false,
      'state', v_existing.state::text);
  end if;

  select i.identifier_value into v_retrieved_from
  from knowledge.source_identifiers i
  where i.source_id = p_source_id and i.identifier_system = 'url'
  limit 1;

  if v_retrieved_from is null then
    select 'https://doi.org/' || i.identifier_value into v_retrieved_from
    from knowledge.source_identifiers i
    where i.source_id = p_source_id and i.identifier_system = 'doi'
    limit 1;
  end if;

  begin
    insert into workflow.monograph_document_requests
      (edition_id, source_id, required_representation, professional_reason,
       retrieved_from, requested_by_actor_id)
    values
      (p_edition_id, p_source_id, v_representation, v_reason,
       v_retrieved_from, p_actor_id)
    returning reference into v_reference;
  exception
    when unique_violation then
      select r.* into v_existing
      from workflow.monograph_document_requests r
      where r.source_id = p_source_id and r.state = 'open';
      return jsonb_build_object(
        'reference', v_existing.reference, 'requested', false,
        'state', v_existing.state::text);
  end;

  return jsonb_build_object(
    'reference', v_reference, 'requested', true, 'state', 'open');
end;
$function$;

CREATE OR REPLACE FUNCTION workflow.register_monograph_source_uses(p_source_version_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_version knowledge.source_versions;
  v_row record;
  v_written integer := 0;
begin
  select sv.* into v_version
  from knowledge.source_versions sv
  where sv.id = p_source_version_id;

  if not found or v_version.representation is null then
    return 0;
  end if;

  for v_row in
    select cn.need_id,
           cn.proposed_use,
           n.scope_digest,
           cn.decided_by_actor_id,
           cn.decided_by_agent_run_id,
           c.recorded_by_actor_id,
           knowledge.monograph_need_material_kind(cn.need_id) as kind
    from workflow.monograph_candidate_sources c
    join workflow.monograph_wanted_candidate_needs cn on cn.candidate_source_id = c.id
    join knowledge.monograph_needs n on n.id = cn.need_id
    where c.source_id = v_version.source_id
      and c.decision in ('selected_for_retrieval', 'included')
      and n.relevance <> 'not_applicable'
    order by cn.need_id
  loop
    -- Representasjonen må passe det behovet trenger. Et sammendrag er ikke
    -- forskningsfulltekst, og et forskningsbehov skal ikke få en godkjent bruk
    -- av noe som ikke kan bære funnet (SOURCE_POLICY.md §5).
    if v_row.kind = 'research_full_text'
       and v_version.representation <> 'full_text' then
      continue;
    end if;
    if v_row.kind = 'authority_document'
       and v_version.representation not in ('full_text', 'regulatory_summary',
                                            'registry_record', 'secondary_report') then
      continue;
    end if;
    if v_row.kind = 'derived' then
      continue;
    end if;

    -- Er området begrenset til forhåndsgodkjente kilder, blir en relevant kilde
    -- utenfor listen et synlig forslag. Den brukes ikke i det stille, og den
    -- erklæres ikke irrelevant (ANTIDEP_CONSTITUTION.md regel 4).
    if not workflow.monograph_source_is_permitted(v_row.need_id, v_version.source_id) then
      perform workflow.record_monograph_revision_proposal(
        v_row.need_id,
        'restricted_source_offered'::workflow.monograph_proposal_kind,
        null, p_source_version_id,
        format('Kilden er valgt for dette behovet (%s), men området er begrenset '
               || 'til forhåndsgodkjente kilder og denne står ikke i listen.',
               v_row.proposed_use),
        coalesce(v_row.decided_by_actor_id, v_row.recorded_by_actor_id),
        v_row.decided_by_agent_run_id);
      continue;
    end if;

    insert into knowledge.monograph_source_uses (
      need_id, source_version_id, approved_use, scope_digest,
      approved_by_actor_id, approved_by_agent_run_id
    )
    values (
      v_row.need_id, p_source_version_id, v_row.proposed_use, v_row.scope_digest,
      case when v_row.decided_by_agent_run_id is null
           then coalesce(v_row.decided_by_actor_id, v_row.recorded_by_actor_id) end,
      v_row.decided_by_agent_run_id
    )
    on conflict on constraint monograph_source_uses_pair_key do nothing;

    if found then
      v_written := v_written + 1;
    end if;
  end loop;

  return v_written;
end;
$function$;

CREATE OR REPLACE FUNCTION api.monograph_source_requests(p_edition_reference text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_edition knowledge.monograph_editions;
  v_research jsonb;
  v_documents jsonb;
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

  -- Forskningsfulltekst. Avgrensningen vises som navn og ikke som id-er: den
  -- som skal finne riktig PDF, trenger artikkelen og grunnen.
  select coalesce(jsonb_agg(x.row order by x.title), '[]'::jsonb) into v_research
  from (
    select s.title,
           jsonb_build_object(
             'reference', r.reference,
             'kind', 'research_full_text',
             'title', s.title,
             'authors_or_issuer', s.authors_or_issuer,
             'publisher_or_journal', s.publisher_or_journal,
             'publication_year',
               case when s.publication_date is null then null
                    else date_part('year', s.publication_date)::integer end,
             'identifiers', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'system', i.identifier_system::text,
                        'value', i.identifier_value)
                        order by i.identifier_system::text), '[]'::jsonb)
               from knowledge.source_identifiers i where i.source_id = s.id),
             'retrieved_from', r.retrieved_from,
             'requested_at', r.requested_at,
             'access_limitation', (
               select string_agg(distinct c.access_limitation_note, ' · ')
               from workflow.monograph_candidate_sources c
               where c.source_id = s.id and c.edition_id = v_edition.id
                 and c.access_limited),
             'professional_reason', (
               select string_agg(
                        format('%s (%s): %s', t.code,
                               coalesce(knowledge.monograph_need_scope_label(n.id),
                                        'uten avgrensning'),
                               cn.proposed_use),
                        E'\n' order by t.code, n.id)
               from workflow.monograph_candidate_sources c
               join workflow.monograph_wanted_candidate_needs cn
                 on cn.candidate_source_id = c.id
               join knowledge.monograph_needs n on n.id = cn.need_id
               join knowledge.monograph_question_templates t on t.id = n.template_id
               where c.source_id = s.id and c.edition_id = v_edition.id
                 and c.decision in ('selected_for_retrieval', 'included'))
           ) as row
    from workflow.full_text_requests r
    join knowledge.sources s on s.id = r.source_id
    where r.state = 'open'
      and exists (
        select 1 from workflow.monograph_candidate_sources c
        where c.source_id = s.id and c.edition_id = v_edition.id
          and c.decision in ('selected_for_retrieval', 'included'))
  ) x;

  select coalesce(jsonb_agg(x.row order by x.title), '[]'::jsonb) into v_documents
  from (
    select s.title,
           jsonb_build_object(
             'reference', r.reference,
             'kind', 'authority_document',
             'required_representation', r.required_representation::text,
             'title', s.title,
             'authors_or_issuer', s.authors_or_issuer,
             'publisher_or_journal', s.publisher_or_journal,
             'identifiers', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'system', i.identifier_system::text,
                        'value', i.identifier_value)
                        order by i.identifier_system::text), '[]'::jsonb)
               from knowledge.source_identifiers i where i.source_id = s.id),
             'retrieved_from', r.retrieved_from,
             'requested_at', r.requested_at,
             'professional_reason', r.professional_reason
           ) as row
    from workflow.monograph_document_requests r
    join knowledge.sources s on s.id = r.source_id
    where r.state = 'open' and r.edition_id = v_edition.id
  ) x;

  return jsonb_build_object(
    'edition', v_edition.reference,
    'drug', (select d.canonical_name from catalog.drugs d where d.id = v_edition.drug_id),
    'research_full_text', v_research,
    'authority_documents', v_documents,
    'open_requests',
      jsonb_array_length(v_research) + jsonb_array_length(v_documents));
end;
$function$;

CREATE OR REPLACE FUNCTION api.resume_chain_transitions(p_identity_key text, p_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  -- Grensen er en kostnadsgrense, og den avgjør i tillegg om passeringen nådde
  -- *enden* av leddet: færre rader enn grensen betyr at feiingen er rundt.
  -- Markøren (workflow.chain_reconciliation_cursors) gjør at neste passering
  -- fortsetter der denne slapp, slik at en grense ikke blir til sult.
  v_limit constant integer := workflow.chain_reconciliation_limit();
  v_identity provenance.agent_identities;
  v_row record;
  v_state text;
  v_queued integer := 0;
  v_candidates integer := 0;
  v_reviews integer := 0;
  v_acquisitions integer := 0;
  v_plans integer := 0;
  v_answers integer := 0;
  v_seen integer;
  v_failed boolean;
  v_position text;
begin
  select i.* into v_identity
  from provenance.agent_identities i
  where i.identity_key = p_identity_key;

  if not found or v_identity.agent_role not in
       ('extraction_verification'::provenance.agent_role,
        'citation_support_verification'::provenance.agent_role) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kjedeoverganger tas opp igjen av de deterministiske kontrolleddene.',
      hint = 'Veien legger aldri inn noe annet enn det databasens egen tilstand allerede tilsier, og tar ikke imot ett eneste felt fra kalleren.';
  end if;

  perform provenance.authenticate_agent_identity(
    p_identity_key, p_secret, v_identity.agent_role);

  -- --------------------------------------------------------------------
  -- Ekstraksjonskontroller som mangler.
  --
  -- Hvert ledd telles og rekonsilieres for seg. `v_failed` er det som avgjør
  -- om leddets tekniske problem kan lukkes, og `v_seen < v_limit` er det som
  -- avgjør om denne passeringen i det hele tatt så hele leddet: en passering
  -- som stoppet på grensen, kan ikke vite om raden bak den fortsatt svikter.
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('ekstraksjonskontroll');
  for v_row in
    select e.id, e.id::text as sort_key
    from knowledge.evidence_items e
    where not exists (
      select 1 from workflow.pipeline_jobs j
      where j.agent_role = 'extraction_verification'::provenance.agent_role
        and j.job_key = workflow.control_job_key('ekstraksjon', e.id))
      and e.id::text > v_position
    order by e.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_control_for_evidence_item(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('ekstraksjonskontroll', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'ekstraksjonskontroll', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('ekstraksjonskontroll');
  end if;

  -- Synteseoppgaver som mangler.
  --
  -- Utvalget er de *subjektene* som mangler en oppgave, og ikke enhver
  -- kontrollert rad: ett subjekt er én oppgave, og uten avgrensningen ville
  -- passeringen brukt grensen sin på rader den allerede hadde gjort ferdig.
  -- Portene speiler overgangens egne — den gjeldende kontrollen er den siste, og
  -- et par som alt har en påstand, er ikke automatikkens å skrive om — slik at
  -- en rad som med rette står, ikke blir liggende i utvalget for alltid.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('syntese');
  for v_row in
    with gjeldende as (
      select distinct on (ev.evidence_item_id)
             ev.evidence_item_id, ev.outcome
      from workflow.evidence_verifications ev
      order by ev.evidence_item_id, ev.registration_ordinal desc
    ),
    utestaaende as (
      select e.intervention_drug_id as drug_id,
             e.outcome_concept_id as topic_id,
             min(e.id::text) as sort_key
      from knowledge.evidence_items e
      join gjeldende g on g.evidence_item_id = e.id and g.outcome = 'verified'
      where not exists (
        select 1 from knowledge.claims c
        where c.topic_concept_id = e.outcome_concept_id
          and c.subject_drug_id = e.intervention_drug_id)
      group by e.intervention_drug_id, e.outcome_concept_id
    )
    select u.sort_key::uuid as id, u.sort_key
    from utestaaende u
    where not workflow.agent_task_subject_queued(
            'claim_synthesis'::provenance.agent_role,
            format('%s+%s', u.drug_id, u.topic_id))
      and u.sort_key > v_position
    order by u.sort_key
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_task_for_verified_extraction(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('syntese', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step('syntese', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('syntese');
  end if;

  -- Kildestøttekontroller som mangler.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('kildestottekontroll');
  for v_row in
    select r.id, r.id::text as sort_key
    from knowledge.claim_revisions r
    where not exists (
      select 1 from workflow.pipeline_jobs j
      where j.agent_role = 'citation_support_verification'::provenance.agent_role
        and j.job_key = workflow.control_job_key('kildestotte', r.id))
      and r.id::text > v_position
    order by r.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_control_for_claim_revision(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kildestottekontroll', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'kildestottekontroll', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kildestottekontroll');
  end if;

  -- Evidensvurderinger som mangler. Som over: de revisjonene som faktisk mangler
  -- oppgaven, lest med den gjeldende kontrollen og ikke med en hvilken som helst.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('evidensvurdering');
  for v_row in
    with gjeldende as (
      select distinct on (cv.claim_revision_id)
             cv.claim_revision_id, cv.outcome
      from workflow.claim_verifications cv
      order by cv.claim_revision_id, cv.registration_ordinal desc
    )
    select g.claim_revision_id as id, g.claim_revision_id::text as sort_key
    from gjeldende g
    where g.outcome = 'verified'
      and not workflow.agent_task_subject_queued(
            'evidence_assessment'::provenance.agent_role, g.claim_revision_id::text)
      and g.claim_revision_id::text > v_position
    order by g.claim_revision_id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_task_for_verified_claim(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('evidensvurdering', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'evidensvurdering', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('evidensvurdering');
  end if;

  -- Kandidater som mangler. Gaten avgjør, som i overgangen: en revisjon som
  -- ikke er ferdig, forseglet ikke, og det er ikke en feil — det er kjeden som
  -- ikke er kommet dit ennå. De tre klassene som betyr nettopp det, går derfor
  -- stille; alt annet er en teknisk svikt og skal telles som en, akkurat som i
  -- de fire leddene over. Et `when others` som svelget uten å registrere, ville
  -- gjort den ene svikten som *ikke* har en trigger bak seg, usynlig.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('kandidat');
  for v_row in
    select distinct a.claim_revision_id as id, a.claim_revision_id::text as sort_key
    from knowledge.evidence_assessments a
    where not exists (
      select 1 from knowledge.candidates c where c.claim_revision_id = a.claim_revision_id)
      and a.claim_revision_id::text > v_position
    order by a.claim_revision_id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_candidate_for_assessment(v_row.id) is not null then
        v_candidates := v_candidates + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kandidat', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step('kandidat', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kandidat');
  end if;

  -- ------------------------------------------------------------------
  -- Redaksjonelle revisjonsvurderinger som mangler.
  --
  -- Det sjette leddet, og det eneste som ikke ender i en jobb: her stopper
  -- kjeden med vilje, og det som skal stå igjen, er en synlig oppgave til et
  -- menneske (migrasjon 012d). Svikter den overgangen teknisk, ville den nye
  -- kunnskapen vært usynlig for alltid — derfor feies den igjen her, som de
  -- fem andre.
  --
  -- Utvalget er *parene* som har brukbar evidens ingen revisjon av påstanden
  -- hviler på, og ikke enhver kontrollert rad: ett par er én oppgave.
  -- Brukbarheten avgjøres inne i overgangen, med skriveveiens egen funksjon;
  -- her er utvalget den billigere formen — en gjeldende, bekreftet kontroll —
  -- slik at passeringen ikke bruker grensen sin på rader som uansett faller.
  -- ------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('paastandsrevisjon');
  for v_row in
    with gjeldende as (
      select distinct on (ev.evidence_item_id)
             ev.evidence_item_id, ev.outcome
      from workflow.evidence_verifications ev
      order by ev.evidence_item_id, ev.registration_ordinal desc
    ),
    par as (
      -- Par som har ny, kontrollert evidens ingen revisjon hviler på.
      select c.id as claim_id,
             c.subject_drug_id as drug_id,
             c.topic_concept_id as topic_id,
             c.monograph_need_id as need_id
      from knowledge.claims c
      join knowledge.evidence_items e
        on e.intervention_drug_id = c.subject_drug_id
       and e.outcome_concept_id = c.topic_concept_id
       -- Og innenfor påstandens egen avgrensning. En monografiavgrenset
       -- påstand utfordres ikke av et funn om et annet spørsmål.
       and (c.monograph_need_id is null
            or knowledge.monograph_need_for_evidence_item(e.id) = c.monograph_need_id)
      join gjeldende g on g.evidence_item_id = e.id and g.outcome = 'verified'
      where c.id = workflow.claim_awaiting_revision(
                     c.subject_drug_id, c.topic_concept_id, c.monograph_need_id)
        and not exists (
          select 1
          from knowledge.claim_evidence_links l
          join knowledge.claim_revisions r on r.id = l.claim_revision_id
          where r.claim_id = c.id and l.evidence_item_id = e.id)
      group by c.id, c.subject_drug_id, c.topic_concept_id, c.monograph_need_id
      union
      -- Og oppgavene som alt står åpne. Utvalget over finner dem gjennom en
      -- evidensrad, og en hard sletting tar den raden bort: da ville en oppgave
      -- ingen kan fullføre, ikke vært mulig å nå herfra i det hele tatt. Selve
      -- skrivingen holder tilstanden i takt (avsnitt 14); dette er nettet under.
      select c.id, c.subject_drug_id, c.topic_concept_id, c.monograph_need_id
      from workflow.claim_revision_reviews r
      join knowledge.claims c on c.id = r.claim_id
      where r.state = 'open'
    ),
    utestaaende as (
      -- Ett par og én avgrensning er én oppgave, også når begge kildene over
      -- peker på den.
      select distinct on (
               workflow.claim_synthesis_subject(
                 p.drug_id::text, p.topic_id::text, p.need_id::text))
             p.claim_id, p.drug_id, p.topic_id, p.need_id,
             workflow.claim_synthesis_subject(
               p.drug_id::text, p.topic_id::text, p.need_id::text) as sort_key
      from par p
      order by workflow.claim_synthesis_subject(
                 p.drug_id::text, p.topic_id::text, p.need_id::text),
               p.claim_id
    )
    select u.claim_id as id, u.drug_id, u.topic_id, u.need_id, u.sort_key
    from utestaaende u
    where u.sort_key > v_position
    order by u.sort_key
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.notice_claim_revision_need(
           v_row.drug_id, v_row.topic_id, v_row.need_id) is not null then
        v_reviews := v_reviews + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('paastandsrevisjon', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'paastandsrevisjon', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('paastandsrevisjon');
  end if;

  -- --------------------------------------------------------------------
  -- Søkeplaner uten en oppdagelsesoppgave, og lukkede søk uten en kontroll.
  --
  -- Begge overgangene er idempotente, så leddet kan gå gjennom alle åpne
  -- planer: en plan som alt har oppgavene sine, koster et oppslag.
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('kildeoppdagelse');
  for v_row in
    select p.id, p.id::text as sort_key
    from workflow.monograph_search_plans p
    where p.closed_at is null
      and p.paused_at is null
      and p.id::text > v_position
    order by p.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_task_for_search_plan(v_row.id) is not null then
        v_plans := v_plans + 1;
      end if;
      if workflow.chain_task_for_search_coverage(v_row.id) is not null then
        v_plans := v_plans + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kildeoppdagelse', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'kildeoppdagelse', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kildeoppdagelse');
  end if;

  -- --------------------------------------------------------------------
  -- Valgte kilder som ikke er hentet inn.
  --
  -- Utestående betyr: kilderaden er ikke løst, eller et behov kilden er valgt
  -- for, har verken en godkjent kildebruk eller en åpen forespørsel. Et behov
  -- som står på en avklaring, er ikke utestående her — det venter på et
  -- menneske, og det står synlig på behovet (ANTIDEP_CONSTITUTION.md regel 4).
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('innhenting');
  for v_row in
    select c.id, c.id::text as sort_key
    from workflow.monograph_candidate_sources c
    where c.decision in ('selected_for_retrieval'::workflow.monograph_candidate_decision,
                         'included'::workflow.monograph_candidate_decision)
      and workflow.monograph_candidate_identifier_system(c.identifier_kind) is not null
      and (
        c.source_id is null
        or exists (
          select 1
          from workflow.monograph_wanted_candidate_needs cn
          join knowledge.monograph_needs n on n.id = cn.need_id
          where cn.candidate_source_id = c.id
            and n.relevance <> 'not_applicable'::knowledge.monograph_relevance
            and n.work_state <> 'awaiting_clarification'::knowledge.monograph_work_state
            and knowledge.monograph_need_material_kind(cn.need_id)
                  <> 'derived'::knowledge.monograph_material_kind
            and not exists (
              select 1
              from knowledge.monograph_source_uses u
              join knowledge.source_versions sv on sv.id = u.source_version_id
              where u.need_id = cn.need_id and sv.source_id = c.source_id)
            and not exists (
              select 1 from workflow.full_text_requests r
              where r.source_id = c.source_id and r.state = 'open')
            and not exists (
              select 1 from workflow.monograph_document_requests r
              where r.source_id = c.source_id and r.state = 'open')))
      and c.id::text > v_position
    order by c.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.acquire_monograph_candidate(v_row.id) is not null then
        v_acquisitions := v_acquisitions + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('innhenting', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'innhenting', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('innhenting');
  end if;

  -- --------------------------------------------------------------------
  -- Monografisvar som mangler.
  --
  -- To slag: et forskningsbehov der påstanden er vurdert uten at svaret er
  -- bundet til den vurderte revisjonen, og et myndighetsbehov der materialet
  -- er godkjent uten at svaroppgaven står i køen.
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('monografisvar');
  for v_row in
    with utestaaende as (
      select c.monograph_need_id as need_id,
             r.id as claim_revision_id
      from knowledge.evidence_assessments a
      join knowledge.claim_revisions r on r.id = a.claim_revision_id
      join knowledge.claims c on c.id = r.claim_id
      where c.monograph_need_id is not null
        and not exists (
          select 1
          from knowledge.monograph_answers ma
          join knowledge.monograph_answer_revisions mr on mr.id = ma.current_revision_id
          where ma.need_id = c.monograph_need_id
            and mr.claim_revision_id = r.id)
      union all
      select u.need_id, null::uuid
      from knowledge.monograph_source_uses u
      join knowledge.monograph_needs n on n.id = u.need_id
      where n.relevance <> 'not_applicable'::knowledge.monograph_relevance
        and knowledge.monograph_need_material_kind(u.need_id)
              = 'authority_document'::knowledge.monograph_material_kind
        and not exists (
          select 1
          from knowledge.monograph_answers ma
          join knowledge.monograph_answer_revisions mr on mr.id = ma.current_revision_id
          where ma.need_id = u.need_id
            and mr.source_version_id = u.source_version_id)
        and not exists (
          select 1 from workflow.pipeline_jobs j
          where j.agent_role = 'monograph_answer'::provenance.agent_role
            and j.job_key like 'agent-handoff:' || u.need_id::text || ':%')
    )
    select distinct on (u.need_id::text || coalesce(u.claim_revision_id::text, ''))
           u.need_id as id, u.claim_revision_id,
           u.need_id::text || coalesce(u.claim_revision_id::text, '') as sort_key
    from utestaaende u
    where u.need_id::text || coalesce(u.claim_revision_id::text, '') > v_position
    order by u.need_id::text || coalesce(u.claim_revision_id::text, '')
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if v_row.claim_revision_id is not null then
        if workflow.chain_answer_for_assessment(v_row.claim_revision_id) is not null then
          v_answers := v_answers + 1;
        end if;
      else
        if workflow.chain_task_for_monograph_answer(v_row.id) is not null then
          v_answers := v_answers + 1;
        end if;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('monografisvar', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'monografisvar', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('monografisvar');
  end if;

  return jsonb_build_object('queued', v_queued, 'candidates_built', v_candidates,
                            'revision_reviews', v_reviews,
                            'search_tasks', v_plans,
                            'acquisitions', v_acquisitions,
                            'monograph_answers', v_answers);
end;
$function$;

comment on function workflow.acquire_monograph_candidate(uuid) is
  'Fører én valgt kandidatkilde videre til materialet er i hus, eller til det står hva som mangler. Kilden finnes eller opprettes fra kandidatens egen identifikator; det private kildebiblioteket spørres først; finnes dokumentet, blir den godkjente kildebruken ført opp i det samme kallet; finnes det ikke, blir det én samlet forespørsel med artikkelidentitet og faglig grunn. Fra migrasjon 014f gjelder det bare behovene på planer som selv har valgt eller inkludert kilden (workflow.monograph_wanted_candidate_needs). Ingen faglig vurdering, ingen beslutning om evidens, og ingen godkjenningsklikk per artikkel (SOURCE_POLICY.md §5).';

comment on function workflow.register_monograph_source_uses(uuid) is
  'Fører opp den godkjente kildebruken for hvert kunnskapsbehov en valgt kandidatkilde er godkjent for, mot den kildeversjonen som faktisk er registrert, med beslutningens opphav fra planen som valgte kilden (migrasjon 014f). Et behov på en plan som ikke har valgt kilden, får ingen bruk av den. Representasjonen må passe behovet: et forskningsbehov får ingen godkjent bruk av et sammendrag, fordi et sammendrag ikke kan bære funnet. Idempotent.';

-- ----------------------------------------------------------------------------
-- 3. Når én plan velger en kilde en annen plan alt har valgt
-- ----------------------------------------------------------------------------

create function workflow.chain_acquire_after_plan_decision()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_state text;
  v_decision workflow.monograph_candidate_decision;
begin
  if new.decision not in ('selected_for_retrieval', 'included') then
    return null;
  end if;

  if tg_op = 'UPDATE' and old.decision = new.decision then
    return null;
  end if;

  -- Denne overgangen går før kildens samlede utfall oppdateres. Står kilden
  -- alt som valgt, var det en annen plan som valgte den, og kildens egen
  -- overgang går ikke på nytt: denne tar da den nye planens behov. Står den
  -- ikke som valgt, tar kildens egen overgang dem når utfallet endres.
  select c.decision into v_decision
  from workflow.monograph_candidate_sources c
  where c.id = new.candidate_source_id;

  if v_decision not in ('selected_for_retrieval', 'included') then
    return null;
  end if;

  begin
    perform workflow.acquire_monograph_candidate(new.candidate_source_id);
  exception
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('innhenting', new.candidate_source_id, v_state);
  end;

  return null;
end;
$$;

comment on function workflow.chain_acquire_after_plan_decision() is
  'Fører behovene til en plan som velger eller inkluderer en kandidatkilde videre til innhentingen, når en annen plan alt hadde valgt kilden og kildens samlede utfall derfor ikke endres. En teknisk svikt ruller ikke tilbake den faglige avgjørelsen: den blir et teknisk problem, og rekonsilieringen tar den opp igjen (migrasjon 014f).';

revoke execute on function workflow.chain_acquire_after_plan_decision() from public;

-- Navnet sorterer før synkroniseringen av kildens utfall, og overgangen går
-- derfor mens utfallet fortsatt er det det var.
create trigger monograph_candidate_source_plans_acquire
  after insert or update of decision on workflow.monograph_candidate_source_plans
  for each row execute function workflow.chain_acquire_after_plan_decision();
