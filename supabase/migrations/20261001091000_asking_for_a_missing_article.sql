-- ============================================================================
-- Migrasjon 012c — å be om en artikkel Antidep mangler, uten en terminal
--
-- `api.request_full_text(uuid, uuid[], uuid[], uuid[], text)` har vært riktig
-- kontrakt siden migrasjon 011: den gjør behovet eksplisitt og bærer den
-- redaksjonelle avgrensningen ekstraksjonsoppgaven senere bygges av. Den har
-- bare ikke hatt en flate foran seg — og den formen den har, kan ikke få en:
-- den tar fem uuid-er, og en redaktør som skulle fylt dem ut, måtte først slått
-- opp kilden, virkestoffene, endepunktene og populasjonene i fire viewer.
--
-- Det er den samme erkjennelsen migrasjon 007i gjorde for ekstraksjonsoppdraget:
-- å finne en uuid er en oppgave for en database, ikke for en kliniker. Denne
-- migrasjonen gir bestillingen den samme behandlingen.
--
-- ----------------------------------------------------------------------------
-- Hva flaten faktisk spør om
--
-- Bare det en redaktør kan svare på uten å slå opp noe teknisk:
--
--   * hvilken artikkel som mangler — tittel, forfattere, tidsskrift, år,
--   * artikkelens DOI, som står på forsiden og i enhver referanseliste,
--   * hvilke virkestoff funnet kan gjelde,
--   * hvilke endepunkt funnet kan gjelde,
--   * hvilken populasjon det eventuelt er avgrenset til.
--
-- De tre siste er faglige avgjørelser og hører hjemme hos et menneske
-- (ANTIDEP_CONSTITUTION.md regel 1, AGENTS.md). Alt annet — kildeversjonen,
-- adressen dokumentet hentes fra, fingeravtrykket, jobbnøkkelen, agentrollen —
-- utleder Antidep selv.
--
-- ----------------------------------------------------------------------------
-- Hvorfor DOI-en er et faglig felt og ikke et teknisk
--
-- En DOI er artikkelens bibliografiske identitet. Den står trykt på artikkelen,
-- den brukes i enhver referanseliste, og en redaktør som vet hvilken artikkel
-- som mangler, har den foran seg. Den er dessuten den ene registrerte verdien
-- som peker på *dokumentet* og ikke på en omtale av det: en PMID utledes
-- bevisst ikke, fordi en PubMed-side viser sammendraget.
--
-- Uten den kunne Antidep ikke utlede hvor fullteksten hentes fra, og
-- kildeversjonen ville manglet opphav.
--
-- ----------------------------------------------------------------------------
-- Hvorfor katalogvalgene er navn og ikke id-er
--
-- Den samme grunnen `api.build_extraction_assignment(uuid, text[], text[],
-- text[])` har: et navn er noe et menneske kan lese og kontrollere, en uuid er
-- noe som kan kopieres feil uten at noen merker det før mye senere. Flaten
-- henter listene fra `api.full_text_request_options()` og sender tilbake
-- nøyaktig de navnene, så en verdi utenfor katalogen kan bare oppstå i et
-- kappløp — og avvises da.
--
-- ----------------------------------------------------------------------------
-- Hvorfor kilden kan opprettes her
--
-- En artikkel Antidep mangler fullteksten til, mangler ofte hele raden: den er
-- ikke registrert ennå. Å kreve at noen først oppretter kilden gjennom
-- `api.create_source(...)` ville flyttet ett terminalsteg inn i flaten framfor
-- å fjerne det.
--
-- Opprettelsen er likevel ikke en ny skrivevei ved siden av den kontrollerte:
-- raden skrives med de samme kolonnene og den samme attribusjonen
-- `api.create_source(...)` bruker, og DOI-en er unik på tvers av kilder, så den
-- samme artikkelen bestilt to ganger blir én kilde. Finnes kilden fra før,
-- brukes den — også når den ble registrert på en annen måte.
--
-- Styrende dokumenter: AGENTS.md, docs/ANTIDEP_CONSTITUTION.md (regel 1, 2),
-- docs/EVIDENCE_PIPELINE.md, docs/DATABASE_ARCHITECTURE.md, docs/ROADMAP.md.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Vokabularet flaten velger fra
--
-- Navn og ingenting annet. Ikke id-er: en flate som fikk dem, ville kunnet
-- sende en tilbake, og da ville den redaksjonelle avgrensningen vært en verdi
-- ingen leste. Ikke status heller — hvilke rader som er i bruk, er databasens
-- avgjørelse, og en flate som viste den, ville bedt noen ta stilling til den.
-- ----------------------------------------------------------------------------
create function api.full_text_request_options()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  perform knowledge.assert_editor_authorized();

  return jsonb_build_object(
    'drugs', coalesce(
      (select jsonb_agg(d.canonical_name order by d.canonical_name)
       from catalog.drugs d
       where d.status = 'active'), '[]'::jsonb),
    'outcomes', coalesce(
      (select jsonb_agg(c.canonical_label order by c.canonical_label)
       from catalog.clinical_concepts c
       where c.concept_type = 'outcome' and c.status = 'active'), '[]'::jsonb),
    'populations', coalesce(
      (select jsonb_agg(p.canonical_label order by p.canonical_label)
       from catalog.populations p
       where p.status = 'active'), '[]'::jsonb));
end;
$$;

comment on function api.full_text_request_options() is
  'De faglige valgene en redaktør kan avgrense en fulltekstbestilling med: virkestoffene, endepunktene og populasjonene som finnes i katalogen, som navn og ikke som id-er. Finnes for at flaten foran bestillingsveien skal kunne be om en faglig avgjørelse uten å vise én eneste teknisk verdi (AGENTS.md). Krever editor-mandat, som bestillingen selv. SECURITY DEFINER fordi catalog har RLS med default deny.';

revoke execute on function api.full_text_request_options() from public;
grant execute on function api.full_text_request_options() to authenticated;

-- ----------------------------------------------------------------------------
-- 2. Oppslaget fra navn til katalograd
--
-- Én funksjon per akse ville vært tre nesten like. Dette er den ene, og den
-- svarer med id-ene i den rekkefølgen navnene kom — eller avviser, med navnet
-- som ikke fantes.
--
-- Avvisningen navngir verdien og ikke raden: «vektendringg finnes ikke i
-- katalogen» er noe en redaktør kan rette, mens en uuid ikke er det.
-- ----------------------------------------------------------------------------
create function workflow.catalog_ids_for_names(p_kind text, p_names text[])
  returns uuid[]
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_ids uuid[];
  v_missing text;
begin
  if p_names is null or cardinality(p_names) = 0 then
    return array[]::uuid[];
  end if;

  if p_kind = 'drug' then
    select array_agg(distinct d.id) into v_ids
    from catalog.drugs d
    where d.canonical_name = any (p_names);

    select string_agg(distinct wanted.name, ', ' order by wanted.name) into v_missing
    from unnest(p_names) as wanted(name)
    where not exists (select 1 from catalog.drugs d where d.canonical_name = wanted.name);
  elsif p_kind = 'outcome' then
    select array_agg(distinct c.id) into v_ids
    from catalog.clinical_concepts c
    where c.concept_type = 'outcome' and c.canonical_label = any (p_names);

    select string_agg(distinct wanted.name, ', ' order by wanted.name) into v_missing
    from unnest(p_names) as wanted(name)
    where not exists (
      select 1 from catalog.clinical_concepts c
      where c.concept_type = 'outcome' and c.canonical_label = wanted.name);
  elsif p_kind = 'population' then
    select array_agg(distinct p.id) into v_ids
    from catalog.populations p
    where p.canonical_label = any (p_names);

    select string_agg(distinct wanted.name, ', ' order by wanted.name) into v_missing
    from unnest(p_names) as wanted(name)
    where not exists (select 1 from catalog.populations p where p.canonical_label = wanted.name);
  else
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%L er ikke en katalogakse.', p_kind);
  end if;

  if v_missing is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Disse finnes ikke i katalogen: %s.', v_missing),
      hint = 'Velg fra listen api.full_text_request_options() svarer med. Et navn som ikke finnes, skal aldri bli en avgrensning med ett valg mindre enn den som ba om den, ba om.';
  end if;

  return coalesce(v_ids, array[]::uuid[]);
end;
$$;

comment on function workflow.catalog_ids_for_names(text, text[]) is
  'Katalogradene bak en liste navn, for én akse: virkestoff, endepunkt eller populasjon. Én funksjon framfor tre nesten like. Avviser med navnet som ikke fantes, aldri med en id og aldri med en avgrensning som har ett valg mindre enn den som ble bedt om — en stille utelatelse ville latt arbeidet bli noe annet enn det redaktøren avgjorde. Samme oppslag api.build_extraction_assignment(uuid, text[], text[], text[]) gjør, som en egen funksjon fordi bestillingsveien trenger nøyaktig det samme.';

revoke execute on function workflow.catalog_ids_for_names(text, text[]) from public;

-- ----------------------------------------------------------------------------
-- 3. Bestillingen
--
-- Én transaksjon: kilden finnes eller opprettes, DOI-en registreres, og
-- forespørselen legges inn gjennom nøyaktig den veien migrasjon 011 skrev.
-- Ingen andre skrivevei, og ingen kontroll er svakere her.
-- ----------------------------------------------------------------------------
create function api.request_missing_full_text(
  p_doi text,
  p_title text,
  p_authors text,
  p_drug_names text[],
  p_outcome_labels text[],
  p_population_labels text[] default array[]::text[],
  p_journal text default null,
  p_year integer default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_doi text;
  v_title text;
  v_authors text;
  v_journal text;
  v_source_id uuid;
  v_created boolean := false;
  v_result jsonb;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  -- DOI-er er ikke bokstavstørrelsesfølsomme, og raden lagrer dem med små
  -- bokstaver. Normaliseringen skjer her, slik at «10.1234/ABC» og
  -- «10.1234/abc» er den samme artikkelen og ikke to.
  v_doi := lower(btrim(coalesce(p_doi, '')));
  v_doi := regexp_replace(v_doi, '^https?://(dx\.)?doi\.org/', '');
  if v_doi !~ '^10\.[0-9]{4,9}/\S+$' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Dette ser ikke ut som en DOI.',
      hint = 'En DOI begynner med 10. og et firesifret tall, for eksempel 10.1016/j.jad.2019.01.001. Den står på artikkelens forside og i referanselisten. En lenke til doi.org godtas også.';
  end if;

  v_title := btrim(coalesce(p_title, ''));
  v_authors := btrim(coalesce(p_authors, ''));
  v_journal := nullif(btrim(coalesce(p_journal, '')), '');
  if length(v_title) = 0 or length(v_authors) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Bestillingen må si hvilken artikkel det gjelder.',
      hint = 'Tittel og forfattere er det fulltekstinnboksen viser den som senere skal kjenne igjen riktig PDF. Uten dem er bestillingen ikke til å handle på.';
  end if;

  if p_year is not null and (p_year < 1800 or p_year > extract(year from now())::integer + 1) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Årstallet ser ikke ut til å høre til en publisert artikkel.';
  end if;

  -- Kilden: den som allerede bærer DOI-en, eller en ny.
  --
  -- Låsen på identifikatorraden gjør at to samtidige bestillinger av den samme
  -- artikkelen blir én kilde. Uten den ville den ene fått unique_violation på
  -- en rad den ikke visste om.
  select i.source_id into v_source_id
  from knowledge.source_identifiers i
  where i.identifier_system = 'doi' and i.identifier_value = v_doi;

  if v_source_id is null then
    insert into knowledge.sources (
      source_type, title, authors_or_issuer, publisher_or_journal,
      publication_date, publication_date_precision, created_by_actor_id
    )
    values (
      'journal_article', v_title, v_authors, v_journal,
      case when p_year is null then null else make_date(p_year, 1, 1) end,
      case when p_year is null then null else 'year'::knowledge.date_precision end,
      v_actor_id
    )
    returning id into v_source_id;
    v_created := true;

    begin
      insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
      values (v_source_id, 'doi', v_doi);
    exception
      -- To samtidige bestillinger av den samme artikkelen er fortsatt én
      -- artikkel. Den som taper kappløpet, bruker den andres kilde — og den
      -- tomme kilderaden blir stående uten identifikator framfor at hele
      -- bestillingen feiler. En kilde uten DOI er ikke en feiltilstand: den er
      -- en rad ingenting peker på.
      when unique_violation then
        select i.source_id into v_source_id
        from knowledge.source_identifiers i
        where i.identifier_system = 'doi' and i.identifier_value = v_doi;
        v_created := false;
    end;
  end if;

  -- Og videre gjennom nøyaktig den veien migrasjon 011 skrev. Avgrensningen
  -- oversettes fra navn til katalograder her, og ingen kontroll er svakere:
  -- api.request_full_text(...) kontrollerer den om igjen.
  v_result := api.request_full_text(
    v_source_id,
    workflow.catalog_ids_for_names('drug', p_drug_names),
    workflow.catalog_ids_for_names('outcome', p_outcome_labels),
    workflow.catalog_ids_for_names('population', p_population_labels),
    null);

  return v_result || jsonb_build_object(
    'title', v_title,
    'source_registered', v_created);
end;
$$;

comment on function api.request_missing_full_text(text, text, text, text[], text[], text[], text, integer) is
  'Ber om fullteksten til én artikkel, med bare de opplysningene en redaktør kan svare på uten å slå opp noe teknisk: artikkelens DOI, tittel, forfattere, tidsskrift og år, og den faglige avgrensningen som navn framfor som id-er. Finner kilden på DOI-en eller oppretter den med de samme kolonnene og den samme attribusjonen api.create_source(text, text, text, text, text, text, text, date, text) bruker, og legger deretter bestillingen inn gjennom nøyaktig api.request_full_text(uuid, uuid[], uuid[], uuid[], text) — ingen andre skrivevei, og ingen kontroll er svakere. Adressen dokumentet hentes fra, utledes av DOI-en; en PMID utledes bevisst ikke, fordi en PubMed-side viser sammendraget og ikke dokumentet. Idempotent: den samme artikkelen med den samme avgrensningen bestilt to ganger er én forespørsel, og en annen avgrensning avvises framfor å svelges stille. Krever editor-mandat: hvilken artikkel Antidep trenger og hva et funn kan gjelde, er en redaksjonell avgjørelse. SECURITY DEFINER fordi knowledge, workflow og catalog har RLS med default deny; tomt search_path, og kalleren valideres på funksjonens eget kall.';

revoke execute on function api.request_missing_full_text(text, text, text, text[], text[], text[], text, integer) from public;
grant execute on function api.request_missing_full_text(text, text, text, text[], text[], text[], text, integer) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. Hva flaten kan gjøre, sett fra den innloggede
--
-- `/fulltekst` er åpen for editor og admin, men bare en editor kan bestille.
-- En flate som viste skjemaet til begge, ville bedt en admin gjøre noe kallet
-- uansett måtte avvise — og det er nettopp den formen for teknisk støy regelen i
-- AGENTS.md handler om.
--
-- Svaret er lukket og bærer ingen rolleliste: «du kan bestille» og «du kan laste
-- opp» er produktopplysninger, mens `editor` og `admin` er interne navn.
-- ----------------------------------------------------------------------------
create function api.full_text_capabilities()
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
begin
  v_actor_id := workflow.active_actor_id();
  if v_actor_id is null then
    return jsonb_build_object('may_request', false, 'may_upload', false);
  end if;

  return jsonb_build_object(
    'may_request', workflow.has_app_role('editor'::workflow.app_role),
    'may_upload', workflow.has_app_role('editor'::workflow.app_role)
                  or workflow.has_app_role('admin'::workflow.app_role));
end;
$$;

comment on function api.full_text_capabilities() is
  'Hva den innloggede kan gjøre på fulltekstflaten, i produktets egne ord: bestille en artikkel, og laste opp en. Svarer stille nei til alle andre framfor å avvise, fordi flaten leser den for å avgjøre hva den skal vise — og en avvisning ville blitt en feilmelding på en side som ikke gjorde noe galt. Bærer ingen rolleliste: editor og admin er interne navn, mens «du kan bestille» er en produktopplysning. Samme aktørgrense som resten, gjennom workflow.active_actor_id(), slik at en tilbaketrukket aktør med en rolletildeling som ennå ikke er utløpt, ikke kan få et skjema flaten ellers ville skjult.';

revoke execute on function api.full_text_capabilities() from public;
grant execute on function api.full_text_capabilities() to authenticated;
