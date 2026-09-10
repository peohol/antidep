-- ============================================================================
-- Migrasjon 007i — ekstraksjonsoppdraget bygges av databasen, ikke for hånd
--
-- Et oppdrag er de opplysningene modell-leddet ikke kan lese ut av artikkelen:
-- hvilken kildeversjon det skal lese, og hvilke virkestoff, endepunkt og
-- populasjoner funnet kan peke på (`assignments/README.md`).
--
-- Fram til nå har filen vært skrevet for hånd, av et menneske som først måtte
-- slå opp sju verdier i fire viewer: `source_id`, `source_version_id`,
-- `retrieved_from`, `content_hash`, og én uuid per katalogvalg. Det er en
-- oppgave for en database, ikke for en kliniker — og hver av de sju er en
-- verdi som kan kopieres feil uten at noe merker det før mye senere.
--
-- ----------------------------------------------------------------------------
-- Hvorfor dette er en databasefunksjon og ikke bare et skript
--
-- Tre grunner, og bare den siste handler om bekvemmelighet:
--
--   1. **Oppdraget er en tiltrodd inndata.** Registreringen kontrollerer
--      forslaget mot oppdragsfilen (migrasjon 005ab, `extraction-run.ts`), så
--      oppdraget er halvparten av kontrollen. Et oppdrag satt sammen av verdier
--      noen har kopiert, er en kontroll mot en kopi.
--
--   2. **Kildebindingen hører sammen.** `retrieved_from`, `content_hash` og
--      dokumentbindingen er én rad i basen. Skrives de inn hver for seg, kan de
--      komme fra hver sin rad — og et oppdrag med fingeravtrykket til én versjon
--      og adressen til en annen ville sendt hele kjeden til feil tekst.
--
--   3. Ingen skal måtte finne en uuid for å komme i gang.
--
-- Funksjonen tar derfor imot **navn** — «sertralin», «vektendring», «voksne med
-- depressiv lidelse» — og svarer med hele oppdraget, ferdig avgrenset. Et navn
-- som ikke finnes i katalogen, er en avvisning som navngir verdien, aldri et
-- oppdrag med ett valg mindre enn kalleren ba om.
--
-- ----------------------------------------------------------------------------
-- Hva funksjonen IKKE gjør
--
-- Den velger ikke kildeversjonen. Hvilken utgave av en artikkel en ekstraksjon
-- skal gjøres av, er en faglig avgjørelse — et sammendrag og en fulltekst er
-- ikke samme grunnlag — og kalleren oppgir versjonen. Kommandoen som bruker
-- funksjonen, slår den opp og skriver ut hva den fant, slik at valget er
-- synlig (`src/ops/extraction-assignment-cli.ts`).
--
-- Den utvider heller ikke modell-leddets tilgang. Oppdraget er fortsatt en fil
-- modell-leddet leser, og modell-leddet har fortsatt ingen databaseflate:
-- funksjonen krever `editor`-rollen, som modell-leddet ikke har og ikke skal ha
-- (EVIDENCE_PIPELINE.md §63).
--
-- ----------------------------------------------------------------------------
-- Hvorfor en kildeversjon uten fingeravtrykk avvises
--
-- Uten `content_hash` finnes det ikke noe å kontrollere en representasjon mot,
-- og hele kjeden hviler på at den kan kontrolleres (MVP_IMPLEMENTATION_PLAN.md
-- §74.32). Uten `representation` vet ingen om ekstraksjonen bygger på et
-- sammendrag eller en fulltekst, og migrasjon 005v avviser en slik versjon
-- allerede ved registreringen. Begge avvisningene står her, slik at de kommer
-- før arbeidet — ikke etter.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §8, §11, §12
--   docs/DATABASE_ARCHITECTURE.md §43, §44, §50
--   docs/EVIDENCE_PIPELINE.md §13, §63
--   docs/MVP_IMPLEMENTATION_PLAN.md §15
-- ============================================================================

begin;

create function api.build_extraction_assignment(
  p_source_version_id uuid,
  p_drug_names text[],
  p_outcome_labels text[],
  p_population_labels text[] default array[]::text[]
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_version knowledge.source_versions;
  v_drugs jsonb;
  v_outcomes jsonb;
  v_populations jsonb;
  v_missing text;
begin
  -- Uten begrep, som resten av kildeforvaltningen: et oppdrag er ikke avgrenset
  -- til ett klinisk begrep, og en avgrenset editor-tildeling er tilstrekkelig.
  perform knowledge.assert_editor_authorized();

  select * into v_version
  from knowledge.source_versions sv
  where sv.id = p_source_version_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Det finnes ingen kildeversjon med id %L.', p_source_version_id);
  end if;

  if v_version.content_hash is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kildeversjonen har ingen content_hash, og kan derfor ikke bære et ekstraksjonsoppdrag.',
      hint = 'Et sporet besøk uten fingeravtrykk er ikke en etterprøvbar representasjon. Registrer representasjonen på nytt gjennom api.create_source_version(...) eller api.create_source_version_from_document(...), som begge lar databasen beregne fingeravtrykket.';
  end if;

  if v_version.representation is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kildeversjonen sier ikke hva slags representasjon den er.',
      hint = 'En agentekstraksjon kan ikke bygge på en versjon uten representasjonstype (EVIDENCE_PIPELINE.md §13, migrasjon 005v). Registrer en ny kildeversjon som oppgir den.';
  end if;

  -- Katalogvalgene. Hver liste kontrolleres for ukjente navn *før* oppslaget
  -- brukes: et oppdrag med ett valg mindre enn kalleren ba om, ville vært en
  -- annen avgrensning enn den redaktøren gjorde — og forskjellen ville ikke
  -- vist seg før et forslag ble avvist av en grunn som pekte feil vei.
  select string_agg(quote_literal(name), ', ' order by name)
  into v_missing
  from unnest(coalesce(p_drug_names, array[]::text[])) as name
  where not exists (
    select 1 from catalog.drugs d where lower(d.canonical_name) = lower(btrim(name))
  );
  if v_missing is not null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Ukjent virkestoff i katalogen: %s.', v_missing),
      hint = 'Bruk det kanoniske navnet slik det står i api.editor_drugs. Handelsnavn og synonymer er ikke oppslagsnøkler her.';
  end if;

  select string_agg(quote_literal(name), ', ' order by name)
  into v_missing
  from unnest(coalesce(p_outcome_labels, array[]::text[])) as name
  where not exists (
    select 1 from catalog.clinical_concepts c
    where c.concept_type = 'outcome' and lower(c.canonical_label) = lower(btrim(name))
  );
  if v_missing is not null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Ukjent endepunkt i katalogen: %s.', v_missing),
      hint = 'Bruk den kanoniske etiketten slik den står i api.editor_outcomes. Begreper som ikke er endepunkter, kan et evidensfunn ikke peke på.';
  end if;

  select string_agg(quote_literal(name), ', ' order by name)
  into v_missing
  from unnest(coalesce(p_population_labels, array[]::text[])) as name
  where not exists (
    select 1 from catalog.populations p where lower(p.canonical_label) = lower(btrim(name))
  );
  if v_missing is not null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Ukjent populasjon i katalogen: %s.', v_missing),
      hint = 'Bruk den kanoniske etiketten slik den står i api.editor_populations. Passer ingen registrert populasjon, la listen stå tom — da sier forslaget det i population_availability framfor å velge en som nesten passer.';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('drug_id', d.id, 'label', d.canonical_name)
    order by d.canonical_name
  ), '[]'::jsonb)
  into v_drugs
  from catalog.drugs d
  where lower(d.canonical_name) in (
    select lower(btrim(name)) from unnest(coalesce(p_drug_names, array[]::text[])) as name
  );

  if jsonb_array_length(v_drugs) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et oppdrag må åpne for minst ett virkestoff.',
      hint = 'Avgrensningen er redaktørens faglige valg, og en tom liste ville latt modellen velge fritt.';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('outcome_concept_id', c.id, 'label', c.canonical_label)
    order by c.canonical_label
  ), '[]'::jsonb)
  into v_outcomes
  from catalog.clinical_concepts c
  where c.concept_type = 'outcome'
    and lower(c.canonical_label) in (
      select lower(btrim(name)) from unnest(coalesce(p_outcome_labels, array[]::text[])) as name
    );

  if jsonb_array_length(v_outcomes) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et oppdrag må åpne for minst ett endepunkt.',
      hint = 'Avgrensningen er redaktørens faglige valg, og en tom liste ville latt modellen velge fritt.';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('population_id', p.id, 'label', p.canonical_label)
    order by p.canonical_label
  ), '[]'::jsonb)
  into v_populations
  from catalog.populations p
  where lower(p.canonical_label) in (
    select lower(btrim(name)) from unnest(coalesce(p_population_labels, array[]::text[])) as name
  );

  return jsonb_build_object(
    'assignment_version', 'antidep/extraction-assignment@2',
    'source_id', v_version.source_id,
    'source_version_id', v_version.id,
    'retrieved_from', v_version.retrieved_from,
    'content_hash', v_version.content_hash,
    -- Dokumentbindingen følger raden, ikke kalleren. Er den der, hentes teksten
    -- ut av originaldokumentet med nøyaktig denne oppskriften; er den ikke der,
    -- hentes adressen (migrasjon 003e, `src/agents/source-binding.ts`).
    'document', case
      when v_version.document_sha256 is null then null
      else jsonb_build_object(
        'sha256', v_version.document_sha256,
        'byte_size', v_version.document_byte_size,
        'media_type', v_version.document_media_type,
        'text_extraction', jsonb_build_object(
          'tool', v_version.text_extraction_tool,
          'tool_version', v_version.text_extraction_tool_version,
          'arguments', v_version.text_extraction_arguments
        )
      )
    end,
    'drugs', v_drugs,
    'outcomes', v_outcomes,
    'populations', v_populations
  );
end;
$$;

comment on function api.build_extraction_assignment(uuid, text[], text[], text[]) is
  'Bygger ett ekstraksjonsoppdrag av databasens egne rader (migrasjon 007i, assignments/README.md). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle (knowledge.assert_editor_authorized(uuid), kalt uten begrep), slår opp kildeversjonen med adressen, fingeravtrykket og en eventuell dokumentbinding, og oversetter kanoniske navn til katalogens id-er. Svaret er nøyaktig innholdet i oppdragsfilen modell-leddet leser, på formen antidep/extraction-assignment@2. Ingen av de sju identifikatorene skrives derfor for hånd, og kildebindingen kan ikke settes sammen av verdier fra to forskjellige rader. Navneoppslaget er ufølsomt for store og små bokstaver og bruker kanoniske navn; et ukjent navn gir en avvisning som navngir verdien, aldri et oppdrag med én avgrensning mindre enn kalleren ba om. En kildeversjon uten content_hash eller uten representasjonstype avvises: den første er ikke en etterprøvbar representasjon (§74.32), den andre kan ikke bære en agentekstraksjon (migrasjon 005v). Funksjonen velger ikke kildeversjon — hvilken utgave av en artikkel som skal ekstraheres, er en faglig avgjørelse — og den gir modell-leddet ingen databasetilgang: oppdraget er fortsatt en fil, og editor-rollen er kallerens, ikke modellens (EVIDENCE_PIPELINE.md §63). SECURITY DEFINER fordi knowledge, catalog, workflow og provenance har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50).';

revoke execute on function api.build_extraction_assignment(uuid, text[], text[], text[]) from public;
grant execute on function api.build_extraction_assignment(uuid, text[], text[], text[]) to authenticated;

commit;
