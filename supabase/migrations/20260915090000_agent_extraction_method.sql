-- ============================================================================
-- Migrasjon 005ab — skriveveien sier hvem som leste kilden, framfor å anta det
--
-- Formål: `api.register_agent_extraction(...)` hardkodet `extraction_method` til
-- `ai_assisted`. Det var riktig så lenge det ikke fantes noe modell-ledd og
-- forslagene i praksis kom fra ett sted. Nå går to slags forslag gjennom den
-- samme skriveveien — et maskinutkast fra modell-leddet, og et menneskes egen
-- ekstraksjon levert som fil — og en fast verdi ville registrert det ene som
-- det andre.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md
--     §8 evidens og proveniens er førsteklasses data
--     §10 KI-arbeidet skal deles i eksplisitte roller
--     §12 KI kan foreslå; mennesker har det faglige ansvaret
--     §14 endringer skal være attribuerte og rapporterbare
--     §20 kunnskapsmodellen og agentpipen skal være leverandøruavhengige
--   docs/DATABASE_ARCHITECTURE.md §29, §50, §60
--   docs/EVIDENCE_PIPELINE.md §18, §61, §65
--   docs/KNOWLEDGE_MODEL.md §11
--
-- ----------------------------------------------------------------------------
-- Hvorfor dette ikke er «å la kalleren påstå fritt»
--
-- Innvendingen mot en parameter var reell: raden skal si hvordan den ble til,
-- og det er ikke noe en klient skal kunne finne på. To ting gjør den likevel
-- riktig her.
--
-- Den ene er at alternativet ikke er «ingen påstand», men *en usann påstand*.
-- En hardkodet `ai_assisted` er også en påstand om hvordan raden ble til, og
-- den er gal for hvert eneste forslag et menneske har skrevet. Å velge mellom
-- en opplysning kalleren oppgir og en opplysning ingen oppgir, er ikke å velge
-- mellom kontroll og ingen kontroll.
--
-- Den andre er at verdien er avgrenset og etterprøvbar. Vokabularet er lukket
-- her — `manual` eller `ai_assisted`, aldri `deterministic_import`, som er en
-- helt annen vei inn i basen og ikke finnes ennå — og verdien inngår i
-- `content_hash`, altså i evidensfunnets identitet. Det samme forslaget
-- registrert som `manual` og som `ai_assisted` er derfor to forskjellige rader,
-- ikke én rad som skifter mening: append-only står, og ingen historikk endres.
--
-- Premissene ved siden av (leverandør, modell, modellversjon, promptmalversjon
-- på `provenance.agent_runs`) er allerede kallerens opplysning, av nøyaktig den
-- samme grunnen: databasen kan ikke observere hvilken modell som leste en
-- artikkel, men den kan kreve at påstanden om det står der og bevares
-- (migrasjon 005e).
--
-- ----------------------------------------------------------------------------
-- Hvorfor parameteren ikke har en standardverdi
--
-- En standardverdi ville gjort nøyaktig det denne migrasjonen fjerner: en
-- kjører som glemte feltet, ville registrert et menneskes arbeid som en
-- modells, og feilen ville vært usynlig. Parameteren er derfor påkrevd, og en
-- kaller som ikke har tatt stilling, får en avvisning framfor en antakelse
-- (ANTIDEP_CONSTITUTION.md §6).
--
-- ----------------------------------------------------------------------------
-- Hvorfor funksjonen slippes og lages på nytt
--
-- `create or replace function` kan ikke legge til en parameter: en ny
-- parameterliste er en ny funksjon, og den gamle ville blitt stående ved siden
-- av med sin egen hardkodede verdi. To skriveveier der den ene stille gjør det
-- gale, er verre enn ingen. `drop function` med den eksakte gamle signaturen
-- fjerner den, og rettighetene settes eksplisitt på nytt under.
--
-- Ingen eksisterende rad røres, og ingen regel er myket opp: hvert vilkår
-- funksjonen hadde — autentisering for rollen, åpen kjøring, påkrevd
-- kildeversjon med registrert representasjon, komplett forankring — står
-- uendret.
-- ============================================================================

begin;

drop function api.register_agent_extraction(
  text, text, uuid, uuid, uuid, text, text, text, text, uuid, text, uuid, text, text,
  text, text, text, text, jsonb, uuid, integer, text, uuid, text, text, text, text,
  numeric, text, numeric, numeric, numeric, text, text
);

create function api.register_agent_extraction(
  p_identity_key text,
  p_secret text,
  p_agent_run_id uuid,
  p_source_id uuid,
  p_source_version_id uuid,
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
  p_field_groundings jsonb,
  p_extraction_method text,
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
  v_identity_id uuid;
  v_actor_id uuid;
  v_representation knowledge.source_representation;
  v_version_source_id uuid;
  v_evidence_item_id uuid;
begin
  -- Autentiser eksplisitt for rollen evidence_extraction. En identitet i en
  -- annen rolle avvises her, før noe leses eller skrives.
  v_identity_id := provenance.authenticate_agent_identity(
    p_identity_key, p_secret, 'evidence_extraction'::provenance.agent_role
  );

  -- Krev en åpen kjøring som tilhører nøyaktig denne identiteten, og la
  -- returverdien — ikke en klientoppgitt parameter — være aktøren raden
  -- attribueres til.
  v_actor_id := provenance.assert_agent_run_open(p_agent_run_id, v_identity_id);

  -- Vokabularet er lukket her og ikke bare på kolonnen. `deterministic_import`
  -- er en gyldig verdi i knowledge.extraction_method, men den beskriver en
  -- maskinell import fra en strukturert kilde — en vei inn i basen som ikke
  -- finnes ennå, og som ikke går gjennom et forslag med kildeforankring per
  -- felt. Avvisningen sier hvilke to verdier denne veien tar imot, framfor å
  -- la en tredje bli en rad som påstår noe om en pipeline som ikke kjørte.
  if p_extraction_method is null or p_extraction_method not in ('manual', 'ai_assisted') then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        '%L er ikke en gyldig ekstraksjonsmetode for denne skriveveien.',
        coalesce(p_extraction_method, '')
      ),
      hint = 'Bruk ai_assisted når en modell leste kilden og foreslo verdiene, og manual når et menneske gjorde det. Verdien er ikke kosmetikk: den inngår i evidensfunnets fingeravtrykk, og den sier kontrolløren hva hen faktisk etterprøver (ANTIDEP_CONSTITUTION.md §12).';
  end if;

  -- En agentekstraksjon skal alltid kunne etterprøves mot den representasjonen
  -- den faktisk ble laget av. Kildeversjonen er derfor påkrevd, den må tilhøre
  -- kilden, og den må si hva slags representasjon den er.
  if p_source_version_id is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En agentekstraksjon må peke på den kildeversjonen den ble laget av.',
      hint = 'Registrer kildeversjonen først (api.create_source_version(...)). Uten den finnes det ingen hashet representasjon å etterprøve utdragene mot (ANTIDEP_CONSTITUTION.md §11).';
  end if;

  select sv.representation, sv.source_id
    into v_representation, v_version_source_id
  from knowledge.source_versions sv
  where sv.id = p_source_version_id;

  if v_version_source_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kildeversjonen %L finnes ikke.', p_source_version_id),
      hint = 'Kontroller id-en. En kildeversjon registreres av api.create_source_version(...).';
  end if;

  if v_representation is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kildeversjonen sier ikke hva slags representasjon den er.',
      hint = 'EVIDENCE_PIPELINE.md §13 krever at pipeline vet om vurderingen bygger på fulltekst, abstrakt, registerdata, et regulatorisk sammendrag, en sekundær omtale eller en annen begrenset representasjon. Registrer kildeversjonen på nytt med p_representation satt; uten den kan ingen si hva ekstraksjonen faktisk bygger på.';
  end if;

  v_evidence_item_id := knowledge.record_evidence_item(
    p_source_id, p_design_code, p_population_availability, p_population_detail,
    p_sample_size_availability, p_intervention_drug_id, p_comparator_kind,
    p_outcome_concept_id, p_outcome_detail, p_timepoint_availability,
    p_reported_direction, p_estimate_availability, p_confidence_interval_availability,
    p_source_locator, p_source_version_id, p_population_id, p_sample_size,
    p_intervention_detail, p_comparator_drug_id, p_comparator_detail,
    p_timepoint_min, p_timepoint_max, p_effect_measure, p_estimate, p_estimate_unit,
    p_ci_lower, p_ci_upper, p_ci_level_percent, p_limitations_text, p_source_quote,
    p_field_groundings,
    -- Forslagets egen erklæring om hvem som leste kilden, kontrollert over.
    p_extraction_method,
    v_actor_id,
    -- Kjøringen raden bindes til. Den er kontrollert av
    -- provenance.assert_agent_run_open(...) over, og de to sammensatte
    -- fremmednøklene på tabellen håndhever at den tilhører nettopp denne
    -- aktøren og er i rollen evidence_extraction.
    p_agent_run_id
  );

  -- Etter innsettingen, fordi kravet leses av den ferdige raden. Feiler den,
  -- rulles hele transaksjonen tilbake, og ekstraksjonen etterlater ingenting.
  perform workflow.assert_extraction_fully_grounded(v_evidence_item_id);

  return v_evidence_item_id;
end;
$$;

comment on function api.register_agent_extraction(
  text, text, uuid, uuid, uuid, text, text, text, text, uuid, text, uuid, text, text,
  text, text, text, text, jsonb, text, uuid, integer, text, uuid, text, text, text, text,
  numeric, text, numeric, numeric, numeric, text, text
) is
  'Den kontrollerte skriveveien for at ekstraksjonsagenten registrerer ett evidensfunn med komplett kildeforankring (ANTIDEP_CONSTITUTION.md §8, §10, EVIDENCE_PIPELINE.md §13, §21, §25). Autentiserer identiteten eksplisitt for rollen evidence_extraction og krever en åpen agentkjøring som tilhører den (provenance.assert_agent_run_open(uuid, uuid)); aktøren raden attribueres til er kjøringens egen og er ikke en parameter. p_extraction_method er påkrevd og må være manual eller ai_assisted (migrasjon 005ab): den samme skriveveien tar imot både et maskinutkast fra modell-leddet og et menneskes egen ekstraksjon, og en fast verdi ville registrert det ene som det andre. deterministic_import avvises, fordi den beskriver en vei inn i basen som ikke går gjennom et forankret forslag. Verdien inngår i content_hash, så det samme forslaget registrert med hver sin metode er to rader og ikke én rad som skifter mening. To vilkår gjelder her og ikke på editorveien: kildeversjonen er påkrevd og må ha en registrert representasjonstype, slik at det alltid finnes en hashet representasjon å etterprøve utdragene mot og det alltid er kjent om ekstraksjonen bygger på fulltekst eller et sammendrag; og forankringen må dekke hvert semantisk felt raden påstår noe om (workflow.assert_extraction_fully_grounded(uuid)). Selve innsettingen gjøres av knowledge.record_evidence_item, den samme funksjonen editorveien bruker, slik at de to ikke kan komme i utakt. SECURITY DEFINER fordi knowledge, catalog og provenance har RLS med default deny; tomt search_path. EXECUTE går til anon og authenticated av samme grunn som de øvrige agentendepunktene: en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

revoke execute on function api.register_agent_extraction(
  text, text, uuid, uuid, uuid, text, text, text, text, uuid, text, uuid, text, text,
  text, text, text, text, jsonb, text, uuid, integer, text, uuid, text, text, text, text,
  numeric, text, numeric, numeric, numeric, text, text
) from public;
grant execute on function api.register_agent_extraction(
  text, text, uuid, uuid, uuid, text, text, text, text, uuid, text, uuid, text, text,
  text, text, text, text, jsonb, text, uuid, integer, text, uuid, text, text, text, text,
  numeric, text, numeric, numeric, numeric, text, text
) to anon, authenticated;

commit;
