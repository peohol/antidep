-- ============================================================================
-- Migrasjon 003f — oppskriften teksten hentes ut med, blir en lukket liste
--
-- Migrasjon 003e ga en kildeversjon en **oppskrift**: verktøyet, versjonen av
-- det og argumentene, lagret ordrett, slik at teksten kan hentes ut igjen og
-- fingeravtrykket etterprøves av hvem som helst med sin egen lovlige kopi av
-- dokumentet.
--
-- Den lot samtidig oppskriften være tre frie tekstfelter. Det er den ene
-- registrerte verdien i hele Antidep som senere blir en **prosess**: ved
-- ekstraksjon og ved maskinell etterprøving leses `text_extraction_tool` og
-- `text_extraction_arguments` ut av basen, og kjøres
-- (`src/agents/source-binding.ts`, `src/agents/document-text.ts`). En redaktør
-- som skrev `sh` i feltet, ville dermed fått en lagret verdi til å bli en
-- kommando kjørt med rettighetene og miljøet til den som kontrollerer — altså
-- kodekjøring ut av en skriverettighet, og et brudd på den regelen som gjelder
-- alt importert og lagret innhold: data blir aldri instruksjoner
-- (EVIDENCE_PIPELINE.md §3.8, CLAUDE.md).
--
-- ----------------------------------------------------------------------------
-- Hva denne migrasjonen gjør
--
-- Antidep støtter i dag nøyaktig én oppskrift. Den skrives derfor ned som
-- nøyaktig én:
--
--   text_extraction_tool       = 'pdftotext'
--   text_extraction_arguments  = '-layout -enc UTF-8 -eol unix'
--
-- Håndhevet av en CHECK på tabellen — fasiten, uansett hvilken skrivevei som en
-- dag fører hit — og av en lesbar avvisning i inngangspunktet, slik at den som
-- prøver, får vite hvorfor framfor en constraintfeil.
--
-- Kjørerne kontrollerer den samme listen på nytt umiddelbart før de starter en
-- prosess (`src/agents/document-binding.ts`). Det er ikke det samme stedet to
-- ganger: den ene grensen stenger for at verdien blir lagret, den andre for at
-- en verdi som likevel er lagret — fra en eldre rad, en gjenopprettet base
-- eller en skrivevei som ennå ikke finnes — blir kjørt.
--
-- ----------------------------------------------------------------------------
-- Hvorfor versjonen ikke er med i listen
--
-- `text_extraction_tool_version` er en opplysning, ikke noe som kjøres. Den
-- forklarer et avvik når to bygg av poppler gir forskjellig tekst, og fasiten
-- er uansett fingeravtrykket av teksten. Låst til én verdi ville den gjort en
-- riktig kjøring på en nyere poppler umulig uten å beskytte mot noe.
--
-- ----------------------------------------------------------------------------
-- Hvorfor listen står ordrett og ikke bak en funksjon
--
-- En CHECK som kalte en funksjon, ville flyttet den lukkede listen ett hakk
-- vekk fra det den beskytter, og en senere endring av funksjonen ville ikke
-- vært etterprøvd mot radene som allerede står. Verdien er kort, den er en
-- sikkerhetsgrense, og den skal kunne leses der den gjelder. Den er ordrett den
-- samme i `src/agents/document-binding.ts`, og en prøve pinner begge sider.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- Ingen eksisterende rad: alle dokumentutledede kildeversjoner er registrert
-- gjennom api.create_source_version_from_document(...) med nøyaktig denne
-- oppskriften. Ingen CHECK, policy, grant eller trigger er fjernet eller
-- svekket, og signaturen til inngangspunktet er uendret.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md
--     §11 verifikasjon skal forsøke å falsifisere
--   docs/DATABASE_ARCHITECTURE.md §7, §18, §43, §50
--   docs/EVIDENCE_PIPELINE.md §3.8, §13, §19
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Listen, som en CHECK på tabellen
--
-- `text_extraction_arguments` er ikke-null nøyaktig når verktøyet er det
-- (source_versions_document_provenance_shape_check, 003e), så én betingelse
-- dekker begge.
-- ----------------------------------------------------------------------------
alter table knowledge.source_versions
  add constraint source_versions_text_extraction_recipe_allowlist_check
    check (
      text_extraction_tool is null
      or (
        text_extraction_tool = 'pdftotext'
        and text_extraction_arguments = '-layout -enc UTF-8 -eol unix'
      )
    );

comment on constraint source_versions_text_extraction_recipe_allowlist_check
  on knowledge.source_versions is
  'Oppskriften er lukket: text_extraction_tool må være pdftotext og text_extraction_arguments nøyaktig -layout -enc UTF-8 -eol unix (migrasjon 003f). Begge verdiene blir en prosess ved ekstraksjon og etterprøving, og et fritt felt ville latt en skriverettighet bli kodekjøring hos den som kontrollerer. text_extraction_tool_version er med vilje utenfor listen: den er en opplysning som forklarer et avvik, ikke noe som kjøres, og fasiten er fingeravtrykket av teksten.';

-- ----------------------------------------------------------------------------
-- 2. Den lesbare avvisningen i inngangspunktet
--
-- Fremover-skrivende `create or replace`: signatur, eier og rettigheter er
-- uendret. Kontrollen står før innsettingen, slik at den som prøver, får vite
-- hva som er tillatt framfor en constraintfeil uten veiledning.
-- ----------------------------------------------------------------------------
create or replace function api.create_source_version_from_document(
  p_source_id uuid,
  p_retrieved_at timestamptz,
  p_retrieved_from text,
  p_document_base64 text,
  p_extracted_text text,
  p_representation text,
  p_text_extraction_tool text,
  p_text_extraction_tool_version text,
  p_text_extraction_arguments text,
  p_external_version text default null,
  p_storage_reference text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_bytes bytea;
  v_size bigint;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_document_base64, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Originaldokumentet mangler, og da kan ingen dokumentbundet kildeversjon registreres.',
      hint = 'Send dokumentet som base64. Databasen beregner fingeravtrykket av bytene og lagrer ikke dokumentet.';
  end if;

  begin
    v_bytes := decode(p_document_base64, 'base64');
  exception
    when others then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Originaldokumentet er ikke gyldig base64.',
        hint = 'Kod filen slik den er, byte for byte. Enhver omforming underveis ville gitt et fingeravtrykk som ikke er filens.';
  end;

  v_size := octet_length(v_bytes);
  if v_size = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Originaldokumentet er tomt, og en tom fil har ikke noe fingeravtrykk som identifiserer en artikkel.';
  end if;
  -- Grensen finnes for at et dokument som ikke er en artikkel, ikke skal kunne
  -- fylle en transaksjon. En fulltekstartikkel er noen få megabyte.
  if v_size > 64 * 1024 * 1024 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Originaldokumentet er %s byte, og grensen er 67108864.', v_size
      ),
      hint = 'En fulltekstartikkel er normalt noen få megabyte. Er filen større, er den sannsynligvis noe annet enn artikkelen.';
  end if;

  -- PDF-signaturen, avlest av dokumentet selv: %PDF- er 25 50 44 46 2d.
  if substring(v_bytes from 1 for 5) <> '\x255044462d'::bytea then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Originaldokumentet er ikke en PDF.',
      hint = 'Antidep henter i dag bare tekst ut av PDF med etterprøvbar proveniens. Er representasjonen tekst, registrer den med api.create_source_version(...), der teksten er sitt eget fingeravtrykk.';
  end if;

  if nullif(btrim(coalesce(p_representation, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Representasjonstypen mangler.',
      hint = 'En kildeversjon utledet av et dokument skal si hva den er: full_text, abstract, registry_record, regulatory_summary, secondary_report eller other_limited (EVIDENCE_PIPELINE.md §13). En fulltekst som ikke sier at den er en fulltekst, er nettopp det denne veien finnes for å unngå.';
  end if;

  if left(coalesce(p_extracted_text, ''), 5) = '%PDF-' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Den uttrukne teksten er selv en PDF, og er dermed ikke tekst noen kan lese et ordrett utdrag ut av.',
      hint = 'Oppgi resultatet av tekstuttrekkingen, ikke dokumentet en gang til.';
  end if;

  -- Den lukkede listen (migrasjon 003f). Oppskriften er den ene lagrede verdien
  -- som senere blir kjørt, og et fritt felt her ville vært en vei fra
  -- redaktørtilgang til kodekjøring hos den som etterprøver.
  if p_text_extraction_tool is distinct from 'pdftotext'
    or p_text_extraction_arguments is distinct from '-layout -enc UTF-8 -eol unix'
  then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Oppskriften er ikke en Antidep kjører.',
      hint = 'Tillatt er nøyaktig verktøyet pdftotext med argumentene -layout -enc UTF-8 -eol unix. Oppskriften kjøres på nytt ved hver etterprøving, og listen over hva som kan kjøres, er derfor lukket. Versjonen av verktøyet er fri: den er en opplysning, ikke noe som kjøres.';
  end if;

  return knowledge.record_source_version(
    p_source_id,
    p_retrieved_at,
    p_retrieved_from,
    p_extracted_text,
    p_external_version,
    p_storage_reference,
    p_representation,
    v_actor_id,
    knowledge.source_document_fingerprint(v_bytes),
    v_size,
    'application/pdf',
    p_text_extraction_tool,
    p_text_extraction_tool_version,
    p_text_extraction_arguments
  );
end;
$$;

comment on function api.create_source_version_from_document(
  uuid, timestamptz, text, text, text, text, text, text, text, text, text
) is
  'Den kontrollerte skriveveien for å registrere en kildeversjon som er utledet av et originaldokument, i dag en PDF (migrasjon 003e, ANTIDEP_CONSTITUTION.md §11, EVIDENCE_PIPELINE.md §13, §14). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle (knowledge.assert_editor_authorized(uuid), kalt uten begrep), dekoder p_document_base64, krever at bytene er en PDF, beregner sha256 og størrelsen av dem, og setter inn raden gjennom knowledge.record_source_version(uuid, timestamptz, text, text, text, text, text, uuid, text, bigint, text, text, text, text) med content_hash beregnet av p_extracted_text. Verken fingeravtrykket, størrelsen eller mediatypen er parametre: alle tre avleses av dokumentet selv, slik at ingen av dem er en påstand kalleren skriver om seg selv. Dokumentet lagres ikke — bytene brukes til å beregne fingeravtrykket og forsvinner med transaksjonen. p_representation er påkrevd her (til forskjell fra tekstveien), fordi en dokumentutledet representasjon som ikke sier hva den er, er den ene tilstanden denne veien finnes for å unngå. Oppskriften — verktøy, versjon og argumenter — er kontrakten utad: kjør den på dokumentet med document_sha256, og sha256 av resultatet skal være content_hash. Fra migrasjon 003f er oppskriften en lukket liste: p_text_extraction_tool må være pdftotext og p_text_extraction_arguments nøyaktig -layout -enc UTF-8 -eol unix, håndhevet både her og av source_versions_text_extraction_recipe_allowlist_check. Verdien blir kjørt ved hver etterprøving, og et fritt felt ville latt en skriverettighet bli kodekjøring hos den som kontrollerer; p_text_extraction_tool_version er fri, fordi den er en opplysning og ikke noe som kjøres. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi knowledge.source_versions, workflow.user_roles og provenance.actors har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50).';

commit;
