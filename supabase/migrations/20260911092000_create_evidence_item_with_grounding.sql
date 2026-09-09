-- ============================================================================
-- Migrasjon 007g — én delt innsetting for begge skriveveiene inn i evidens
--
-- Migrasjon 005u innførte knowledge.evidence_field_groundings. Denne
-- migrasjonen gir den den eneste skriveveien den skal ha: den samme
-- transaksjonen som registrerer evidensfunnet.
--
-- Hvorfor ikke et eget endepunkt: to kall er to transaksjoner, og mellom dem
-- ville det finnes et evidensfunn uten forankring som en kontrollør kunne rukket
-- å hente fram. Forankringen er ikke et tillegg til ekstraksjonen; den er en del
-- av den (ANTIDEP_CONSTITUTION.md §8), og den skal derfor bli til samtidig.
--
-- ----------------------------------------------------------------------------
-- Editoren skriver ingen forankring
--
-- Forankringen er ekstraksjonens eget produkt: det ordrette utdraget en verdi
-- ble lest ut av, i den representasjonen som faktisk ble hentet. Skrev den
-- menneskelige editoren den selv, ville venstresiden i kontrolløkten vært noe
-- et menneske hadde skrevet inn ved siden av verdien — og da kontrollerer
-- kontrolløren skjemautfyllingen, ikke kilden.
--
-- api.create_evidence_item(...) tar derfor ingen forankringsparameter, og
-- beholder signaturen sin uendret. Forankringen skrives bare av agentveien
-- (api.register_agent_extraction, migrasjon 005v), som har en åpen
-- agentkjøring og en kildeversjon med registrert representasjon å knytte den
-- til.
--
-- ----------------------------------------------------------------------------
-- Hvorfor innsettingen flyttes ut i én funksjon
--
-- Fra migrasjon 005v av finnes det to skriveveier inn i
-- knowledge.evidence_items: editoren med sesjon og editor-rolle, og
-- ekstraksjonsagenten med legitimasjon og en åpen kjøring. De skal håndheve
-- nøyaktig de samme invariantene, og skrevet to ganger kunne de kommet i utakt
-- — da ville den ene veien sluppet gjennom det den andre stengte. Samme
-- begrunnelse som 005s gir for workflow.record_evidence_verification(...).
--
-- Innsettingen ligger derfor i knowledge.record_evidence_item(...), og begge
-- inngangspunktene kaller den. Den kjenner ingen sesjon og ingen legitimasjon:
-- den tar aktøren som allerede er autentisert, og ekstraksjonsmetoden
-- inngangspunktet står inne for.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- Autorisasjonen er den samme funksjonen (knowledge.assert_editor_authorized),
-- extraction_method er fortsatt hardkodet, content_hash eies fortsatt av
-- databasen, raw_extraction bygges fortsatt av p_source_quote under den samme
-- ene nøkkelen, og dublettoversettelsen er ordrett den samme. Ingen constraint,
-- trigger, policy eller grant er fjernet eller svekket.
--
-- Forankringen er valgfri på databasenivå, og det er et bevisst valg: et
-- evidensfunn uten forankring er nettopp den tilstanden alle funn registrert før
-- 005u er i, og den skal kunne beskrives framfor å gjøres uuttrykkelig.
-- Kravet om komplett forankring hører til agentveien, som håndhever det
-- (workflow.assert_extraction_fully_grounded, migrasjon 005v).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §8, §11, §12, §20
--   docs/DATABASE_ARCHITECTURE.md §29, §35, §43, §50, §57, §59
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §29, §74.32
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. knowledge.record_evidence_item(...) — selve innsettingen, ett sted
--
-- Fra migrasjon 005v av finnes det to skriveveier inn i
-- knowledge.evidence_items: editoren med sesjon og editor-rolle, og
-- ekstraksjonsagenten med legitimasjon og en åpen kjøring. De skal håndheve
-- nøyaktig de samme invariantene — hvilke vokabularverdier som er lovlige,
-- hvordan raw_extraction bygges, at forankringen skrives i samme transaksjon og
-- attribueres til den som laget funnet, og hvordan dubletten oversettes.
-- Skrevet to ganger ville de kunnet komme i utakt, og da ville den ene veien
-- sluppet gjennom det den andre stengte. Samme begrunnelse som
-- workflow.record_evidence_verification(...) har i migrasjon 005s.
--
-- Funksjonen kjenner ingen sesjon og ingen legitimasjon: den tar aktøren som
-- allerede er autentisert, og ekstraksjonsmetoden inngangspunktet står inne for.
-- ----------------------------------------------------------------------------
create function knowledge.record_evidence_item(
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
  p_created_by_actor_id uuid
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_evidence_item_id uuid;
  v_duplicate_field text;
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
    created_by_actor_id
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
    -- Et tomt sitatfelt er et fravær, ikke et tomt sitat. Ingen validering av
    -- innholdet: et sitat er ordrett tekst fra kilden, og det er ikke noe her
    -- som kan avgjøre om det er riktig gjengitt — det er verifikatorens
    -- oppgave (ANTIDEP_CONSTITUTION.md §11).
    case
      when nullif(btrim(coalesce(p_source_quote, '')), '') is null then null
      else jsonb_build_object('sitat', btrim(p_source_quote))
    end,
    p_created_by_actor_id
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
  -- Den eneste oversatte avvisningen. content_hash dekker hele radens faglige
  -- innhold, så en dublett er nøyaktig samme registrering en gang til — og en
  -- korreksjon av et hvilket som helst felt gir en ny hash og slipper inn ved
  -- siden av den gamle (migrasjon 003, 006a).
  when unique_violation then
    raise exception using
      errcode = 'unique_violation',
      message = 'Nøyaktig det samme evidensfunnet er allerede registrert.',
      hint = 'Et evidensfunn identifiseres av hele sitt faglige innhold. Er dette en korreksjon, skal minst ett felt være endret — da registreres den som et nytt funn ved siden av det gamle, og det gamle består (knowledge.evidence_items er append-only).';
end;
$$;

comment on function knowledge.record_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text, jsonb, text, uuid
) is
  'Innsettingen av ett evidensfunn med sin kildeforankring, uten autorisasjon. Finnes fordi det fra migrasjon 005v av er to skriveveier inn i knowledge.evidence_items — editoren med sesjon og editor-rolle, og ekstraksjonsagenten med legitimasjon og en åpen kjøring — og de to skal håndheve nøyaktig de samme invariantene: vokabularverdiene, hvordan raw_extraction bygges av ett sitat under én dokumentert nøkkel, at forankringen skrives i samme transaksjon og attribueres til den som laget funnet, og hvordan dubletten oversettes. Kalleren har allerede avgjort hvem aktøren er og hvilken ekstraksjonsmetode raden har; ingen av de to er verdier som kommer fra klienten. content_hash eies av databasen. Ingen feltvalidering er duplisert her: constraintene på knowledge.evidence_items og knowledge.evidence_field_groundings er fasiten, og deres avvisninger propageres uendret.';

revoke execute on function knowledge.record_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text, jsonb, text, uuid
) from public;

-- ----------------------------------------------------------------------------
-- 2. api.create_evidence_item(...) — inngangspunktet for en editor
-- ----------------------------------------------------------------------------
create or replace function api.create_evidence_item(
  -- Påkrevd: nøyaktig de kolonnene knowledge.evidence_items krever.
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
  -- Valgfritt. Utelatt betyr NULL, og NULL betyr det den ledsagende
  -- `*_availability`-kolonnen sier at det betyr — aldri null og aldri
  -- «ingen effekt» (ANTIDEP_CONSTITUTION.md §6, DATABASE_ARCHITECTURE.md §19.1).
  p_source_version_id uuid default null,
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
  v_actor_id uuid;
begin
  -- Endepunktet er innholdsområdet et evidensfunn hører under, og det er derfor
  -- det en avgrenset editor-tildeling kontrolleres mot.
  v_actor_id := knowledge.assert_editor_authorized(p_outcome_concept_id);

  return knowledge.record_evidence_item(
    p_source_id, p_design_code, p_population_availability, p_population_detail,
    p_sample_size_availability, p_intervention_drug_id, p_comparator_kind,
    p_outcome_concept_id, p_outcome_detail, p_timepoint_availability,
    p_reported_direction, p_estimate_availability, p_confidence_interval_availability,
    p_source_locator, p_source_version_id, p_population_id, p_sample_size,
    p_intervention_detail, p_comparator_drug_id, p_comparator_detail,
    p_timepoint_min, p_timepoint_max, p_effect_measure, p_estimate, p_estimate_unit,
    p_ci_lower, p_ci_upper, p_ci_level_percent, p_limitations_text, p_source_quote,
    -- Ingen forankring: den er ekstraksjonsagentens produkt, ikke editorens.
    null::jsonb,
    -- Hardkodet: en registrering gjennom denne veien *er* en menneskelig
    -- ekstraksjon. En klientoppgitt verdi ville gjort det mulig å merke en
    -- håndskrevet rad som maskinelt produsert.
    'manual',
    v_actor_id
  );
end;
$$;

comment on function api.create_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text
) is
  'Den kontrollerte skriveveien for at en kvalifisert redaktør kan registrere et EvidenceItem (DATABASE_ARCHITECTURE.md §43, MVP_IMPLEMENTATION_PLAN.md §15, §29). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle for endepunktet funnet gjelder (knowledge.assert_editor_authorized(uuid)), og setter inn raden attribuert til kallerens egen aktør gjennom knowledge.record_evidence_item, som er den samme innsettingen agentveien api.register_agent_extraction bruker. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi knowledge.evidence_items, workflow.user_roles og provenance.actors har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50). extraction_method er ikke parameter og er alltid manual, content_hash eies av databasen, og raw_extraction bygges av p_source_quote. Skriver ingen kildeforankring: forankringen er ekstraksjonens eget produkt — det ordrette utdraget en verdi ble lest ut av i den representasjonen som faktisk ble hentet — og et utdrag en redaktør skrev inn ved siden av verdien, ville gjort kontrolløkten til en kontroll av skjemautfyllingen framfor av kilden. Ingen feltvalidering er duplisert her: constraintene på tabellen er fasiten, og deres avvisninger propageres uendret. Unntaket er dubletten, som oversettes til en setning på norsk uten at noen regel endres.';

revoke execute on function api.create_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text
) from public;
grant execute on function api.create_evidence_item(
  uuid, text, text, text, text, uuid, text, uuid, text, text, text, text, text, text,
  uuid, uuid, integer, text, uuid, text, text, text, text, numeric, text, numeric,
  numeric, numeric, text, text
) to authenticated;
