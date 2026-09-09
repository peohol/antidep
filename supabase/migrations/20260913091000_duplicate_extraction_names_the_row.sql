-- ============================================================================
-- Migrasjon 007h — dublettavvisningen navngir raden som kolliderte
--
-- ----------------------------------------------------------------------------
-- Hullet
--
-- Registreringen av et evidensfunn og den deterministiske kontrollen av det er
-- to skrivinger, i to transaksjoner. Dør prosessen mellom dem, finnes raden uten
-- maskinbevis — og en ny kjøring med det samme forslaget får bare «dublett»
-- tilbake. For å fullføre kontrollen må kjøreren vite *hvilken* rad det var.
--
-- Uten et svar fra databasen måtte den gjettet, og en gjetning på noe annet enn
-- den kanoniske identiteten kan peke på feil rad. To evidensfunn fra den samme
-- kildeversjonen kan legitimt dele kildeforankring — det samme utvalgsutdraget,
-- den samme populasjonssetningen — og likevel gjelde ulike utfall eller
-- effektmål. En kjører som valgte «en rad på den samme kildeversjonen med den
-- samme forankringen», kunne dermed kontrollert et annet, ukontrollert funn enn
-- det som faktisk utløste dubletten.
--
-- ----------------------------------------------------------------------------
-- Rettingen
--
-- Avvisningen fra knowledge.record_evidence_item bærer nå `detail` med
-- evidence_item_id til raden som kolliderte. Den slås opp med nøyaktig den
-- identiteten UNIQUE-regelen bruker: knowledge.evidence_item_content_hash på en
-- radvariabel satt av de samme uttrykkene som innsettingen. Ingen ny definisjon
-- av hva et evidensfunn er — den kanoniske funksjonen er den samme, og
-- migrasjon 006a sin regel om at avtrykket bare finnes ett sted, står.
--
-- To ting følger av at oppslaget er eksakt, og begge er kjørerens ansvar:
-- gjenopptakelsen kontrollerer nøyaktig den raden dubletten gjaldt, og
-- sammenligningen av kildeforankring gjøres på nettopp den raden framfor å
-- utledes av hva som ellers ligger i arbeidskøen.
--
-- ----------------------------------------------------------------------------
-- Hva som ikke endres
--
-- Raden avvises fortsatt. Ingen constraint, trigger, policy eller grant er
-- rørt, funksjonen har samme signatur og samme SECURITY INVOKER, og alle andre
-- avvisninger er ordrett som før. `raw_extraction` utledes nå én gang og brukes
-- to steder — i innsettingen og i radvariabelen — nettopp for at de to ikke skal
-- kunne komme i utakt.
--
-- At kildeforankringen ikke inngår i avtrykket, er uendret og er ført som
-- issue #66. Denne migrasjonen gjør bare at kjøreren kan se hvilken rad den
-- kolliderte med, og dermed skille en avbrutt kjøring fra en rettet forankring.
-- ============================================================================

create or replace function knowledge.record_evidence_item(
  p_source_id uuid,
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
  p_source_version_id uuid,
  p_population_id uuid,
  p_sample_size integer,
  p_intervention_detail text,
  p_comparator_drug_id uuid,
  p_comparator_detail text,
  p_timepoint_min text,
  p_timepoint_max text,
  p_effect_measure text,
  p_estimate numeric,
  p_estimate_unit text,
  p_ci_lower numeric,
  p_ci_upper numeric,
  p_ci_level_percent numeric,
  p_limitations_text text,
  p_source_quote text,
  p_field_groundings jsonb,
  p_extraction_method text,
  p_created_by_actor_id uuid,
  -- NULL for editorveien: en registrering gjennom skjemaet er ingen
  -- agentkjøring, og en id her ville vært en påstand om det motsatte.
  p_agent_run_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_evidence_item_id uuid;
  v_duplicate_field text;
  v_raw_extraction jsonb;
  -- Radvariabelen finnes bare for å kunne be knowledge.evidence_item_content_hash
  -- om avtrykket av nøyaktig den raden innsettingen forsøker. Den er ikke en
  -- kopi av identitetsdefinisjonen: den kanoniske funksjonen er den samme, og
  -- feltene her settes av de samme uttrykkene som INSERT-en bruker.
  v_candidate knowledge.evidence_items;
  v_existing_id uuid;
begin
  -- Forankringen kontrolleres på form før noe skrives, slik at en feil form gir
  -- en setning som sier hva som er galt framfor en fremmednøkkel- eller
  -- casting-feil lenger ned.
  if p_field_groundings is not null
     and jsonb_typeof(p_field_groundings) is distinct from 'array' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'p_field_groundings må være en jsonb-liste av kildeforankringer.',
      hint = 'Hvert element skal ha check_field, source_excerpt, source_locator og justification (migrasjon 005u).';
  end if;

  -- To forankringer av samme felt ville vært to påstander om hvilket utdrag
  -- verdien hviler på. Unikheten er tabellens egen; oversettelsen her navngir
  -- feltet framfor constrainten.
  select g.value ->> 'check_field'
    into v_duplicate_field
  from jsonb_array_elements(coalesce(p_field_groundings, '[]'::jsonb)) as g
  group by g.value ->> 'check_field'
  having count(*) > 1
  limit 1;

  if v_duplicate_field is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Feltet %L er forankret mer enn én gang.', v_duplicate_field),
      hint = 'Ett felt har én forankring: det minste ordrette utdraget som er tilstrekkelig for å bedømme nettopp det feltet. Er to utdrag nødvendige, hører de til ett utdrag med begge setningene.';
  end if;

  -- Et tomt sitatfelt er et fravær, ikke et tomt sitat. Ingen validering av
  -- innholdet: et sitat er ordrett tekst fra kilden, og det er ikke noe her
  -- som kan avgjøre om det er riktig gjengitt — det er verifikatorens oppgave
  -- (ANTIDEP_CONSTITUTION.md §11).
  --
  -- Utledet én gang og brukt to steder: i innsettingen, og i radvariabelen som
  -- avtrykket beregnes av. To uttrykk ville kunnet komme i utakt, og da ville
  -- oppslaget etter en dublett pekt på feil rad eller på ingen.
  v_raw_extraction := case
    when nullif(btrim(coalesce(p_source_quote, '')), '') is null then null
    else jsonb_build_object('sitat', btrim(p_source_quote))
  end;

  -- Feltene knowledge.evidence_item_content_hash(knowledge.evidence_items)
  -- leser, og bare de. Alt annet på raden — id, tidsstempler, aktør,
  -- agentkjøring — inngår ikke i identiteten og settes derfor ikke her.
  v_candidate.source_id := p_source_id;
  v_candidate.source_version_id := p_source_version_id;
  v_candidate.design_code := p_design_code::knowledge.study_design;
  v_candidate.population_id := p_population_id;
  v_candidate.population_availability := p_population_availability::knowledge.value_availability;
  v_candidate.population_detail := p_population_detail;
  v_candidate.sample_size := p_sample_size;
  v_candidate.sample_size_availability := p_sample_size_availability::knowledge.value_availability;
  v_candidate.intervention_drug_id := p_intervention_drug_id;
  v_candidate.intervention_detail := p_intervention_detail;
  v_candidate.comparator_kind := p_comparator_kind::knowledge.comparator_kind;
  v_candidate.comparator_drug_id := p_comparator_drug_id;
  v_candidate.comparator_detail := p_comparator_detail;
  v_candidate.outcome_concept_id := p_outcome_concept_id;
  v_candidate.outcome_detail := p_outcome_detail;
  v_candidate.timepoint_min := p_timepoint_min::interval;
  v_candidate.timepoint_max := p_timepoint_max::interval;
  v_candidate.timepoint_availability := p_timepoint_availability::knowledge.value_availability;
  v_candidate.reported_direction := p_reported_direction::knowledge.effect_direction;
  v_candidate.effect_measure := p_effect_measure::knowledge.effect_measure;
  v_candidate.estimate := p_estimate;
  v_candidate.estimate_unit := p_estimate_unit::knowledge.estimate_unit;
  v_candidate.estimate_availability := p_estimate_availability::knowledge.value_availability;
  v_candidate.ci_lower := p_ci_lower;
  v_candidate.ci_upper := p_ci_upper;
  v_candidate.ci_level_percent := p_ci_level_percent;
  v_candidate.confidence_interval_availability :=
    p_confidence_interval_availability::knowledge.value_availability;
  v_candidate.limitations_text := p_limitations_text;
  v_candidate.source_locator := p_source_locator;
  v_candidate.extraction_method := p_extraction_method::knowledge.extraction_method;
  v_candidate.raw_extraction := v_raw_extraction;

  insert into knowledge.evidence_items (
    source_id, source_version_id, design_code,
    population_id, population_availability, population_detail,
    sample_size, sample_size_availability,
    intervention_drug_id, intervention_detail,
    comparator_kind, comparator_drug_id, comparator_detail,
    outcome_concept_id, outcome_detail,
    timepoint_min, timepoint_max, timepoint_availability,
    reported_direction, effect_measure, estimate, estimate_unit, estimate_availability,
    ci_lower, ci_upper, ci_level_percent, confidence_interval_availability,
    limitations_text, source_locator, extraction_method, raw_extraction,
    created_by_actor_id, agent_run_id
  )
  values (
    p_source_id,
    p_source_version_id,
    p_design_code::knowledge.study_design,
    p_population_id,
    p_population_availability::knowledge.value_availability,
    p_population_detail,
    p_sample_size,
    p_sample_size_availability::knowledge.value_availability,
    p_intervention_drug_id,
    p_intervention_detail,
    p_comparator_kind::knowledge.comparator_kind,
    p_comparator_drug_id,
    p_comparator_detail,
    p_outcome_concept_id,
    p_outcome_detail,
    p_timepoint_min::interval,
    p_timepoint_max::interval,
    p_timepoint_availability::knowledge.value_availability,
    p_reported_direction::knowledge.effect_direction,
    p_effect_measure::knowledge.effect_measure,
    p_estimate,
    p_estimate_unit::knowledge.estimate_unit,
    p_estimate_availability::knowledge.value_availability,
    p_ci_lower,
    p_ci_upper,
    p_ci_level_percent,
    p_confidence_interval_availability::knowledge.value_availability,
    p_limitations_text,
    p_source_locator,
    p_extraction_method::knowledge.extraction_method,
    v_raw_extraction,
    p_created_by_actor_id,
    p_agent_run_id
  )
  returning id into v_evidence_item_id;

  -- Forankringen, i samme transaksjon. Aktøren er den samme som laget funnet,
  -- og den sammensatte fremmednøkkelen på tabellen håndhever nettopp det.
  begin
    insert into knowledge.evidence_field_groundings (
      evidence_item_id, created_by_actor_id, check_field,
      source_excerpt, source_locator, justification
    )
    select
      v_evidence_item_id,
      p_created_by_actor_id,
      (g.value ->> 'check_field')::workflow.evidence_check_field,
      btrim(g.value ->> 'source_excerpt'),
      btrim(g.value ->> 'source_locator'),
      btrim(g.value ->> 'justification')
    from jsonb_array_elements(coalesce(p_field_groundings, '[]'::jsonb)) as g;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'En av kildeforankringene viser til et felt som ikke finnes.',
        hint = 'Gyldige felter er de kolonnene på knowledge.evidence_items som workflow.evidence_check_field lister (DATABASE_ARCHITECTURE.md §29).';
    when not_null_violation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'En av kildeforankringene mangler et påkrevd felt.',
        hint = 'Hvert element skal ha check_field, source_excerpt, source_locator og justification. Et ordrett utdrag uten kildepeker er ikke etterprøvbart, og en peker uten utdrag sier ikke hva som står der.';
  end;

  return v_evidence_item_id;
exception
  -- Den eneste oversatte avvisningen. content_hash dekker de strukturerte
  -- feltene på raden, så en dublett er den samme registreringen en gang til —
  -- og en korreksjon av et hvilket som helst av dem gir en ny hash og slipper
  -- inn ved siden av den gamle (migrasjon 003, 006a).
  --
  -- Avvisningen navngir nå raden som kolliderte, i detail. Uten det måtte en
  -- kaller som vil gjenoppta en avbrutt kjøring gjette seg til hvilken rad det
  -- var, og en gjetning på noe annet enn den kanoniske identiteten kan peke på
  -- feil rad: to funn fra den samme kildeversjonen kan legitimt dele forankring
  -- og likevel gjelde ulike utfall (migrasjon 007h). Oppslaget bruker nøyaktig
  -- den identiteten UNIQUE-regelen bruker — den samme funksjonen, på en
  -- radvariabel satt av de samme uttrykkene som innsettingen.
  --
  -- Finner oppslaget ingenting, står detail tomt framfor å påstå noe. Det er
  -- ikke det forventede tilfellet, men en påstand uten dekning er verre enn en
  -- manglende opplysning.
  when unique_violation then
    select e.id into v_existing_id
    from knowledge.evidence_items e
    where e.content_hash = knowledge.evidence_item_content_hash(v_candidate)
      and e.id is distinct from v_evidence_item_id;

    raise exception using
      errcode = 'unique_violation',
      message = 'Nøyaktig det samme evidensfunnet er allerede registrert.',
      detail = case
        when v_existing_id is null then 'Den kolliderende raden lot seg ikke slå opp.'
        else format('evidence_item_id=%s', v_existing_id)
      end,
      hint = 'Et evidensfunn identifiseres av hele sitt faglige innhold. Er dette en korreksjon, skal minst ett felt være endret — da registreres den som et nytt funn ved siden av det gamle, og det gamle består (knowledge.evidence_items er append-only). Kildeforankringen inngår ikke i avtrykket; se issue #66.';
end;
$$;

comment on function knowledge.record_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text, jsonb, text, uuid, uuid
) is
  'Innsettingen av ett evidensfunn med sin kildeforankring, uten autorisasjon. Finnes fordi det fra migrasjon 005v av er to skriveveier inn i knowledge.evidence_items — editoren med sesjon og editor-rolle, og ekstraksjonsagenten med legitimasjon og en åpen kjøring — og de to skal håndheve nøyaktig de samme invariantene: vokabularverdiene, hvordan raw_extraction bygges av ett sitat under én dokumentert nøkkel, at forankringen skrives i samme transaksjon og attribueres til den som laget funnet, og hvordan dubletten oversettes. Kalleren har allerede avgjort hvem aktøren er og hvilken ekstraksjonsmetode raden har; ingen av de to er verdier som kommer fra klienten. content_hash eies av databasen. Dublettavvisningen navngir fra migrasjon 007h raden som kolliderte, i detail, slått opp med den samme kanoniske identiteten UNIQUE-regelen bruker — slik at en kjøring som ble avbrutt mellom registreringen og kontrollen, kan fullføre kontrollen av nøyaktig den raden framfor å gjette. Ingen feltvalidering er duplisert her: constraintene på knowledge.evidence_items og knowledge.evidence_field_groundings er fasiten, og deres avvisninger propageres uendret.';
