-- ============================================================================
-- Migrasjon 003e — originaldokumentet får et databaseeid fingeravtrykk, og
--                  fullteksten blir bundet til nøyaktig det dokumentet
--
-- Fram til nå har en kildeversjon vært én ting: en adresse som kan hentes på
-- nytt, og sha256 av svaret. Det er riktig for en MEDLINE-post, og det er den
-- eneste representasjonen Antidep har brukt (migrasjon 003, 007f).
--
-- Det holder ikke for en fulltekstartikkel. Den foreligger som en PDF en
-- redaktør har lovlig tilgang til lokalt, og:
--
--   * den ligger ikke på en åpen adresse som kan hentes på nytt,
--   * den er ikke tekst, så den kan ikke hashes som tekst, og
--   * Antidep har ikke nødvendigvis rett til å redistribuere den
--     (EVIDENCE_PIPELINE.md §14).
--
-- Uten en vei for nettopp det, kan Antidep bare ekstrahere fra sammendrag — og
-- det er den tilstanden migrasjon 003 dokumenterer: begge de seedede
-- evidensfunnene står med verdier sammendraget ikke oppgir, fordi fullteksten
-- ikke var tilgjengelig.
--
-- ----------------------------------------------------------------------------
-- Hva denne migrasjonen innfører
--
-- To opplysninger om den samme raden, som til sammen gjør en fulltekst
-- etterprøvbar uten at dokumentet lagres:
--
--   1. **Fingeravtrykket av originaldokumentet.** `document_sha256`,
--      `document_byte_size` og `document_media_type`. Hashen beregnes av
--      databasen selv, av bytene kalleren sender — den er aldri en påstand
--      kalleren skriver om seg selv, av nøyaktig samme grunn som `content_hash`
--      ikke er det (007f). Bytene lagres ikke: de brukes til å beregne
--      fingeravtrykket, og forsvinner når transaksjonen er ferdig.
--
--   2. **Oppskriften teksten ble hentet ut med.** `text_extraction_tool`,
--      `text_extraction_tool_version` og `text_extraction_arguments`. Uten den
--      kan ingen reprodusere teksten: to verktøy gir to forskjellige tekster av
--      den samme PDF-en, og det samme verktøyet gir forskjellig tekst med
--      forskjellige valg.
--
-- Kontrakten utad blir dermed: *kjør denne kommandoen på dokumentet med dette
-- fingeravtrykket, og sha256 av resultatet skal være `content_hash`.* Den
-- krever ingen kjennskap til Antidep, og den er den samme kontrollen kjeden
-- selv gjør ved hvert eneste ledd (`src/agents/source-binding.ts`).
--
-- ----------------------------------------------------------------------------
-- Hvorfor de seks kolonnene er alt-eller-ingenting
--
-- En rad med et dokumentfingeravtrykk, men uten oppskrift, ville sagt «denne
-- teksten kommer fra denne PDF-en» uten å si hvordan — altså en påstand ingen
-- kan etterprøve. En rad med oppskrift, men uten fingeravtrykk, ville sagt
-- hvordan teksten ble laget, men ikke av hva. Begge halvdeler er nødvendige for
-- at noen av dem skal bety noe, og CHECK-en sier det.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en PDF ikke får gå gjennom tekstveien
--
-- `api.create_source_version(...)` tar imot representasjonen som **tekst**, og
-- hasher `convert_to(tekst, 'UTF8')`. En PDF presset gjennom den veien blir
-- ikke fulltekstartikkelen: den blir binærinnholdet omkodet til noe som ligner
-- tekst, og fingeravtrykket ville beskrevet omkodingen framfor filen. Ingen
-- ville kunnet reprodusere det med `sha256sum` på PDF-en, og kildeversjonen
-- ville sett like etterprøvbar ut som alle andre.
--
-- Tekstveien avviser derfor innhold som begynner med PDF-signaturen, med en
-- setning som sier hvilken vei som gjelder i stedet. Det er den ene feilen
-- denne migrasjonen gjør det *lettere* å gjøre, og derfor den ene som stenges
-- eksplisitt.
--
-- ----------------------------------------------------------------------------
-- Hva som holder en abstraktekstraksjon fra å framstå som fulltekst
--
-- Fem regler, hvorav fire allerede fantes:
--
--   1. `source_versions_source_content_key` (003): den samme teksten kan ikke
--      registreres to ganger for den samme kilden. Sammendraget som allerede
--      står som `abstract`, kan derfor ikke registreres på nytt som
--      `full_text`.
--   2. `knowledge.freeze_source_version()` (003c): `representation` kan ikke
--      endres etterpå. Utvides her til å verne de seks nye kolonnene også.
--   3. Tekstveien avviser en PDF (ny, over).
--   4. Kjeden henter teksten til en dokumentbundet versjon **bare** ut av
--      originaldokumentet, aldri fra adressen — og motsatt
--      (`src/agents/source-binding.ts`). Sammendraget hasher aldri til
--      fullteksten, så en forveksling gir ingen kontroll, ikke en gal.
--   5. Kontrollgrunnlaget både mennesket og maskinen leser, bærer
--      representasjonstypen og dokumentbindingen
--      (`workflow.evidence_extraction_dossier`, utvidet her).
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- Ingen eksisterende rad. Ingen eksisterende CHECK, policy, grant eller trigger
-- er fjernet eller svekket. `api.create_source_version(...)` beholder sin
-- signatur og sin virkemåte for alt annet enn en PDF, og de to seedede
-- kildeversjonene står uendret som `abstract` uten dokumentbinding — som er den
-- sanne tilstanden for dem.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md
--     §4  enhver klinisk relevant påstand skal være etterprøvbar
--     §6  usikkerhet skal graderes; manglende opplysning er ikke en verdi
--     §8  evidens og proveniens er førsteklasses data
--     §11 verifikasjon skal skje mot kildematerialet eller en etterprøvbar
--         representasjon av det
--     §14 endringer skal være attribuerte
--   docs/DATABASE_ARCHITECTURE.md §7, §7.1, §18, §36, §38, §43, §50, §57, §59, §60
--   docs/EVIDENCE_PIPELINE.md §13, §14, §19, §22, §65
--   docs/KNOWLEDGE_MODEL.md §10, §11.2
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Kolonnene
-- ----------------------------------------------------------------------------
alter table knowledge.source_versions
  add column document_sha256 text,
  add column document_byte_size bigint,
  add column document_media_type text,
  add column text_extraction_tool text,
  add column text_extraction_tool_version text,
  add column text_extraction_arguments text;

comment on column knowledge.source_versions.document_sha256 is
  'sha256 av originaldokumentet denne representasjonen ble hentet ut av, med algoritmen som prefiks. Beregnet av databasen selv av bytene kalleren sendte til api.create_source_version_from_document(uuid, timestamptz, text, text, text, text, text, text, text, text, text): fingeravtrykket er aldri en verdi klienten oppgir, og kan derfor ikke være en garanti uten dekning. Dokumentet selv lagres ikke (EVIDENCE_PIPELINE.md §14). NULL betyr at representasjonen er teksten som lå på retrieved_from, ikke at dokumentet er ukjent.';
comment on column knowledge.source_versions.document_byte_size is
  'Antall byte i originaldokumentet, beregnet av databasen sammen med fingeravtrykket. Sammen med sha256 gjør den en forveksling av to filer synlig også for den som bare har filstørrelsen.';
comment on column knowledge.source_versions.document_media_type is
  'Hva slags dokument originalen er, avlest av databasen på dokumentets egen signatur og ikke av et filnavn. I dag bare application/pdf, som er den ene formen Antidep kan hente tekst ut av med etterprøvbar proveniens.';
comment on column knowledge.source_versions.text_extraction_tool is
  'Verktøyet teksten ble hentet ut av dokumentet med, for eksempel pdftotext. Sammen med versjonen og argumentene er dette hele oppskriften: kjør den på dokumentet med document_sha256, og sha256 av resultatet skal være content_hash (ANTIDEP_CONSTITUTION.md §11, EVIDENCE_PIPELINE.md §13).';
comment on column knowledge.source_versions.text_extraction_tool_version is
  'Versjonen av verktøyet, ordrett slik det selv oppgir den. Ikke et krav ved etterprøving — fasiten er fingeravtrykket av teksten — men den opplysningen som forklarer et avvik når to versjoner gir forskjellig tekst.';
comment on column knowledge.source_versions.text_extraction_arguments is
  'Argumentene verktøyet ble kjørt med, ordrett. Uten dem er oppskriften ufullstendig: det samme verktøyet gir forskjellig tekst med forskjellige valg, og en tekst som ikke kan reproduseres, er ikke en etterprøvbar representasjon.';

-- ----------------------------------------------------------------------------
-- 2. Constraintene
--
-- Alt-eller-ingenting først, fordi den er invarianten. Deretter formen på hver
-- enkelt verdi, med de samme grensene som de eksisterende kolonnene bruker.
-- ----------------------------------------------------------------------------
alter table knowledge.source_versions
  add constraint source_versions_document_provenance_shape_check
    check (
      num_nonnulls(
        document_sha256, document_byte_size, document_media_type,
        text_extraction_tool, text_extraction_tool_version, text_extraction_arguments
      ) in (0, 6)
    ),
  add constraint source_versions_document_sha256_format_check
    check (document_sha256 is null or document_sha256 ~ '^sha256:[0-9a-f]{64}$'),
  add constraint source_versions_document_byte_size_check
    check (document_byte_size is null or document_byte_size > 0),
  -- Ikke en tekstlig mediatype: er representasjonen tekst, er den sitt eget
  -- fingeravtrykk og hører hjemme på tekstveien. Et «dokument» av typen
  -- text/plain ville hatt to fingeravtrykk av det samme innholdet, og en
  -- kontroll måtte da valgt hvilket av dem som gjaldt.
  add constraint source_versions_document_media_type_check
    check (
      document_media_type is null
      or (document_media_type = btrim(document_media_type)
          and length(document_media_type) between 1 and 200
          and document_media_type not like 'text/%')
    ),
  add constraint source_versions_text_extraction_tool_not_blank_check
    check (
      text_extraction_tool is null
      or (text_extraction_tool = btrim(text_extraction_tool)
          and length(text_extraction_tool) between 1 and 200)
    ),
  add constraint source_versions_text_extraction_tool_version_not_blank_check
    check (
      text_extraction_tool_version is null
      or (text_extraction_tool_version = btrim(text_extraction_tool_version)
          and length(text_extraction_tool_version) between 1 and 200)
    ),
  add constraint source_versions_text_extraction_arguments_not_blank_check
    check (
      text_extraction_arguments is null
      or (text_extraction_arguments = btrim(text_extraction_arguments)
          and length(text_extraction_arguments) between 1 and 1000)
    ),
  -- En representasjon utledet av et dokument må si hva den er. `NULL` på
  -- `representation` betyr «ikke registrert» (003b), og en fulltekst som ikke
  -- sier at den er en fulltekst, er nettopp den tilstanden dokumentveien
  -- finnes for å unngå.
  add constraint source_versions_document_requires_representation_check
    check (document_sha256 is null or representation is not null);

-- ----------------------------------------------------------------------------
-- 3. De nye kolonnene er en del av øyeblikksbildet, og fryses med det
--
-- Fremover-skrivende med `create or replace function`: signatur, eier og
-- rettigheter er uendret, og triggeren som kaller den er den samme.
--
-- Kunne dokumentbindingen endres i ettertid, ville en registrert ekstraksjon
-- kunnet flyttes fra ett dokument til et annet uten spor — altså nøyaktig det
-- 003c stengte for `representation`, med et større utfall.
-- ----------------------------------------------------------------------------
create or replace function knowledge.freeze_source_version()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  if new.source_id is distinct from old.source_id
    or new.retrieved_at is distinct from old.retrieved_at
    or new.retrieved_from is distinct from old.retrieved_from
    or new.external_version is distinct from old.external_version
    or new.content_hash is distinct from old.content_hash
    or new.representation is distinct from old.representation
    or new.retrieved_by_actor_id is distinct from old.retrieved_by_actor_id
    or new.document_sha256 is distinct from old.document_sha256
    or new.document_byte_size is distinct from old.document_byte_size
    or new.document_media_type is distinct from old.document_media_type
    or new.text_extraction_tool is distinct from old.text_extraction_tool
    or new.text_extraction_tool_version is distinct from old.text_extraction_tool_version
    or new.text_extraction_arguments is distinct from old.text_extraction_arguments
  then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Et hentet øyeblikksbilde av en kilde er uforanderlig og kan ikke endres.',
      hint = 'Registrer en ny kildeversjon for det nye innholdet. Evidensfunn som peker på den gamle versjonen skal beholde sin opprinnelige dokumentasjon.';
  end if;

  return new;
end;
$$;

comment on function knowledge.freeze_source_version() is
  'Nekter enhver endring av de kolonnene som til sammen utgjør øyeblikksbildet av en hentet kilde: source_id, retrieved_at, retrieved_from, external_version, content_hash, representation, retrieved_by_actor_id, og fra migrasjon 003e også dokumentbindingen — document_sha256, document_byte_size, document_media_type — og oppskriften teksten ble hentet ut med — text_extraction_tool, text_extraction_tool_version, text_extraction_arguments (DATABASE_ARCHITECTURE.md §18, §36). representation kom til i migrasjon 003b og er vernet fra 003c: den sier hva ekstraksjonen faktisk bygde på (EVIDENCE_PIPELINE.md §13), og en rad som stille kunne endres fra abstract til full_text ville latt en ekstraksjon se ut som om den hvilte på noe annet enn den gjorde. Dokumentbindingen er vernet av samme grunn, med et større utfall: kunne den endres, ville en registrert fulltekstekstraksjon kunnet flyttes fra ett dokument til et annet uten spor. storage_reference er med vilje utenfor vernet: hvor kopien ligger, er driftsinformasjon og ikke en påstand om kilden.';

-- ----------------------------------------------------------------------------
-- 3b. Fingeravtrykket av et dokument, som en egen ren funksjon
--
-- Motstykket til knowledge.source_version_content_hash(text), og skilt fra den
-- av samme grunn som de to fingeravtrykkene er skilt: det ene er sha256 av en
-- **tekst** UTF-8-kodet, det andre er sha256 av **bytene** slik de er. Samme
-- form på verdien, forskjellig inndata, og en funksjon som tok imot begge ville
-- gjort det mulig å hashe en PDF som om den var tekst.
-- ----------------------------------------------------------------------------
create function knowledge.source_document_fingerprint(p_document bytea)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case
    when p_document is null then null
    else 'sha256:' || encode(sha256(p_document), 'hex')
  end;
$$;

comment on function knowledge.source_document_fingerprint(bytea) is
  'Fingeravtrykket av et originaldokument: sha256 av bytene slik de er, med algoritmen som prefiks — samme form som knowledge.source_version_content_hash(text), men over bytes og ikke over tekst. Verdien skal kunne reproduseres med `sha256sum` på filen av hvem som helst. Ren funksjon uten tabelltilgang. Eies av databasen og oppgis aldri av en klient (migrasjon 003e).';

revoke execute on function knowledge.source_document_fingerprint(bytea) from public;

-- ----------------------------------------------------------------------------
-- 4. Innsettingen tar imot dokumentbindingen, og avviser en PDF på tekstveien
--
-- Funksjonen slippes og lages på nytt framfor å få parametre med standardverdi:
-- en overload ville latt kalleren og ikke kontrakten avgjøre hvilken funksjon
-- som ble kalt. Den er intern (ingen EXECUTE til noen klientrolle), så
-- signaturendringen berører ingen flate utad.
-- ----------------------------------------------------------------------------
drop function knowledge.record_source_version(
  uuid, timestamptz, text, text, text, text, text, uuid
);

create function knowledge.record_source_version(
  p_source_id uuid,
  p_retrieved_at timestamptz,
  p_retrieved_from text,
  p_retrieved_content text,
  p_external_version text,
  p_storage_reference text,
  p_representation text,
  p_retrieved_by_actor_id uuid,
  p_document_sha256 text default null,
  p_document_byte_size bigint default null,
  p_document_media_type text default null,
  p_text_extraction_tool text default null,
  p_text_extraction_tool_version text default null,
  p_text_extraction_arguments text default null
)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_source_version_id uuid;
  v_representation knowledge.source_representation;
begin
  -- Innholdet er påkrevd fordi hashen er det. En tom representasjon ville gitt
  -- hashen av den tomme strengen, altså et fingeravtrykk som er likt for enhver
  -- kilde og derfor ikke identifiserer noe. Kontrollen er på fravær av innhold,
  -- ikke på formen: hva en representasjon *er*, avgjøres av kilden.
  if nullif(btrim(coalesce(p_retrieved_content, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Den hentede representasjonen mangler, og da kan ingen kildeversjon registreres.',
      hint = 'Oppgi innholdet nøyaktig slik det ble hentet fra adressen. Databasen beregner content_hash av det, og hashen er det som gjør versjonen etterprøvbar (ANTIDEP_CONSTITUTION.md §11).';
  end if;

  -- En PDF er ikke tekst, og skal ikke hashes som om den var det. Kontrollen
  -- står her og ikke bare i inngangspunktet, fordi den gjelder enhver vei inn i
  -- tabellen: innholdet som hashes, skal være den teksten noen faktisk kan lese
  -- ekstraksjonens utdrag ut av.
  if left(p_retrieved_content, 5) = '%PDF-' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Innholdet er en PDF, og en PDF kan ikke registreres som en tekstrepresentasjon.',
      hint = 'Bruk api.create_source_version_from_document(...). Den beregner fingeravtrykket av selve dokumentet, lagrer oppskriften teksten ble hentet ut med, og hasher teksten — slik at begge deler kan etterprøves. En PDF hashet som tekst ville gitt et fingeravtrykk ingen kan reprodusere med sha256sum på filen.';
  end if;

  begin
    v_representation := nullif(btrim(coalesce(p_representation, '')), '')::knowledge.source_representation;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent representasjonstype.', p_representation),
        hint = 'Gyldige verdier er full_text, abstract, registry_record, regulatory_summary, secondary_report og other_limited (EVIDENCE_PIPELINE.md §13).';
  end;

  insert into knowledge.source_versions (
    source_id, retrieved_at, retrieved_from, external_version,
    content_hash, storage_reference, representation, retrieved_by_actor_id,
    document_sha256, document_byte_size, document_media_type,
    text_extraction_tool, text_extraction_tool_version, text_extraction_arguments
  )
  values (
    p_source_id,
    p_retrieved_at,
    p_retrieved_from,
    p_external_version,
    -- Ubeskåret innhold: btrim over er bare en tomhetskontroll, aldri en
    -- normalisering av det som hashes.
    knowledge.source_version_content_hash(p_retrieved_content),
    p_storage_reference,
    v_representation,
    p_retrieved_by_actor_id,
    p_document_sha256,
    p_document_byte_size,
    p_document_media_type,
    p_text_extraction_tool,
    p_text_extraction_tool_version,
    p_text_extraction_arguments
  )
  returning id into v_source_version_id;

  return v_source_version_id;
exception
  -- source_versions_source_content_key. Den eneste oversatte avvisningen, og
  -- samme resonnement som dubletten i api.create_evidence_item(...): dette er en
  -- forventet utgang av en riktig utfylt form — den samme representasjonen hentet
  -- en gang til — og databasens egen tekst navngir en mekanisme framfor å si hva
  -- som skjedde.
  when unique_violation then
    raise exception using
      errcode = 'unique_violation',
      message = 'Nøyaktig samme innhold er allerede registrert som en kildeversjon for denne kilden.',
      hint = 'At hashen er lik betyr at kilden er uendret siden forrige henting. Bruk den registrerte versjonen framfor å lage en ny; en ny rad ville vært den samme observasjonen om igjen.';
end;
$$;

comment on function knowledge.record_source_version(
  uuid, timestamptz, text, text, text, text, text, uuid,
  text, bigint, text, text, text, text
) is
  'Innsettingen av én kildeversjon, uten autorisasjon: hasher den hentede representasjonen med knowledge.source_version_content_hash(text), setter inn raden attribuert til aktøren kalleren oppgir, og returnerer versjonens id. p_representation sier hva slags representasjon som ble hentet (EVIDENCE_PIPELINE.md §13); tom eller utelatt betyr at opplysningen ikke er registrert, og en agentekstraksjon kan da ikke bygge på versjonen (migrasjon 005v). De seks siste parameterne er dokumentbindingen fra migrasjon 003e og oppgis bare av api.create_source_version_from_document(uuid, timestamptz, text, text, text, text, text, text, text, text, text); de er alt-eller-ingenting, håndhevet av source_versions_document_provenance_shape_check. Autorisasjonen ligger hos inngangspunktet som kaller den, slik at en senere skrivevei med en annen autorisasjonsmodell kan gjenbruke innsettingen framfor å kopiere den. Kalles fra innsiden av en SECURITY DEFINER-funksjon og trenger derfor ikke være det selv. Avviser en tom representasjon, en ukjent representasjonstype og innhold som begynner med PDF-signaturen, og oversetter dubletten til en setning på norsk uten å endre regelen.';

revoke execute on function knowledge.record_source_version(
  uuid, timestamptz, text, text, text, text, text, uuid,
  text, bigint, text, text, text, text
) from public;

-- ----------------------------------------------------------------------------
-- 5. Tekstveien, uendret utad
--
-- Samme signatur, samme rettigheter, samme virkemåte. Den må lages på nytt
-- fordi den kaller innsettingen, som har fått en ny signatur — ikke fordi noe
-- ved den selv er endret.
-- ----------------------------------------------------------------------------
create or replace function api.create_source_version(
  p_source_id uuid,
  p_retrieved_at timestamptz,
  p_retrieved_from text,
  p_retrieved_content text,
  p_external_version text default null,
  p_storage_reference text default null,
  p_representation text default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
begin
  -- Uten begrep: en kildeversjon er, som kilden selv, ikke avgrenset til noe
  -- klinisk begrep, og en avgrenset editor-tildeling er derfor tilstrekkelig.
  v_actor_id := knowledge.assert_editor_authorized();

  return knowledge.record_source_version(
    p_source_id,
    p_retrieved_at,
    p_retrieved_from,
    p_retrieved_content,
    p_external_version,
    p_storage_reference,
    p_representation,
    v_actor_id
  );
end;
$$;

-- Kommentaren navngir innsettingen med full signatur, og den signaturen er ny.
-- En kommentar som navngir en funksjon som ikke finnes, er nettopp det
-- supabase/tests/280_content_hash_serialization_test.sql fanger. Innholdet er
-- ordrett det samme; bare signaturen og den nye avvisningen er lagt til.
comment on function api.create_source_version(
  uuid, timestamptz, text, text, text, text, text
) is
  'Den kontrollerte skriveveien for å registrere en kildeversjon av en tekstrepresentasjon (DATABASE_ARCHITECTURE.md §18, §43, MVP_IMPLEMENTATION_PLAN.md §15, §74.30 punkt 1, issue #44). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle (knowledge.assert_editor_authorized(uuid), kalt uten begrep), setter inn raden gjennom knowledge.record_source_version(uuid, timestamptz, text, text, text, text, text, uuid, text, bigint, text, text, text, text) attribuert til kallerens egen aktør, og returnerer versjonens id. content_hash er ikke en parameter: databasen beregner den av p_retrieved_content, slik at hashen aldri er en påstand kalleren skriver om seg selv. p_retrieved_content er påkrevd; en versjon uten fingeravtrykk kvalifiserer ikke som verifiserbart grunnlag (§74.32). p_representation sier hva slags representasjon som ble hentet (EVIDENCE_PIPELINE.md §13) og er valgfri utad, men en kildeversjon uten den kan ikke bære en agentekstraksjon (migrasjon 005v). Innhold som begynner med PDF-signaturen avvises fra og med migrasjon 003e: en PDF hashet som tekst gir et fingeravtrykk ingen kan reprodusere med sha256sum på filen, og et originaldokument har sin egen skrivevei. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi knowledge.source_versions, workflow.user_roles og provenance.actors har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50). Ingen feltvalidering er duplisert her: constraintene på knowledge.source_versions er fasiten, og deres avvisninger propageres uendret.';

-- ----------------------------------------------------------------------------
-- 6. Dokumentveien
--
-- Kalleren sender **bytene**, ikke fingeravtrykket. Det er hele poenget: en
-- hash klienten oppga, ville sett ut som en garanti uten å være det, og
-- fingeravtrykket er det eneste som binder teksten til originalen.
--
-- Bytene lagres ikke. De dekodes, måles og hashes i denne transaksjonen, og er
-- borte når den er ferdig. Antidep lagrer bibliografiske metadata, egne
-- strukturerte ekstraksjoner og fingeravtrykk — ikke fulltekstene selv
-- (EVIDENCE_PIPELINE.md §14).
--
-- Mediatypen avleses av dokumentets egen signatur og er ikke en parameter. Et
-- filnavn er en påstand den som lagret filen gjorde; de første bytene er
-- dokumentet selv.
-- ----------------------------------------------------------------------------
create function api.create_source_version_from_document(
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
  'Den kontrollerte skriveveien for å registrere en kildeversjon som er utledet av et originaldokument, i dag en PDF (migrasjon 003e, ANTIDEP_CONSTITUTION.md §11, EVIDENCE_PIPELINE.md §13, §14). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle (knowledge.assert_editor_authorized(uuid), kalt uten begrep), dekoder p_document_base64, krever at bytene er en PDF, beregner sha256 og størrelsen av dem, og setter inn raden gjennom knowledge.record_source_version(uuid, timestamptz, text, text, text, text, text, uuid, text, bigint, text, text, text, text) med content_hash beregnet av p_extracted_text. Verken fingeravtrykket, størrelsen eller mediatypen er parametre: alle tre avleses av dokumentet selv, slik at ingen av dem er en påstand kalleren skriver om seg selv. Dokumentet lagres ikke — bytene brukes til å beregne fingeravtrykket og forsvinner med transaksjonen. p_representation er påkrevd her (til forskjell fra tekstveien), fordi en dokumentutledet representasjon som ikke sier hva den er, er den ene tilstanden denne veien finnes for å unngå. Oppskriften — verktøy, versjon og argumenter — er kontrakten utad: kjør den på dokumentet med document_sha256, og sha256 av resultatet skal være content_hash. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi knowledge.source_versions, workflow.user_roles og provenance.actors har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50).';

revoke execute on function api.create_source_version_from_document(
  uuid, timestamptz, text, text, text, text, text, text, text, text, text
) from public;
grant execute on function api.create_source_version_from_document(
  uuid, timestamptz, text, text, text, text, text, text, text, text, text
) to authenticated;

-- ----------------------------------------------------------------------------
-- 7. Den redaksjonelle lesemodellen viser hva en versjon faktisk er
--
-- `representation` har manglet her siden 003b, og dokumentbindingen er ny. Uten
-- begge kan ingen — verken et menneske i adminflyten eller kommandoen som
-- bygger et ekstraksjonsoppdrag — se om en registrert versjon er et sammendrag
-- eller en fulltekst, eller hvilket dokument den er utledet av.
--
-- `create or replace view` legger nye kolonner til på slutten. Formen på de
-- eksisterende er uendret, og kolonnekontrakten i
-- supabase/tests/340_api_column_contract_test.sql er oppdatert i takt.
-- ----------------------------------------------------------------------------
create or replace view api.editor_source_versions
  with (security_invoker = true) as
select
  sv.id                           as source_version_id,
  sv.source_id                    as source_id,
  sv.retrieved_at                 as retrieved_at,
  sv.retrieved_from               as retrieved_from,
  sv.external_version             as external_version,
  sv.content_hash                 as content_hash,
  sv.representation::text         as representation,
  sv.document_sha256              as document_sha256,
  sv.document_byte_size           as document_byte_size,
  sv.document_media_type          as document_media_type,
  sv.text_extraction_tool         as text_extraction_tool,
  sv.text_extraction_tool_version as text_extraction_tool_version,
  sv.text_extraction_arguments    as text_extraction_arguments
from knowledge.source_versions sv;

comment on column api.editor_source_versions.representation is
  'Hva slags representasjon som ble hentet (EVIDENCE_PIPELINE.md §13). NULL betyr at opplysningen ikke er registrert — tilstanden alle versjoner registrert før migrasjon 003b er i — aldri at representasjonen er ukjent men brukbar.';
comment on column api.editor_source_versions.document_sha256 is
  'sha256 av originaldokumentet representasjonen ble hentet ut av, eller NULL når representasjonen er teksten på adressen. Beregnet av databasen (migrasjon 003e).';
comment on column api.editor_source_versions.document_byte_size is
  'Antall byte i originaldokumentet, eller NULL.';
comment on column api.editor_source_versions.document_media_type is
  'Hva slags dokument originalen er, avlest av dokumentets egen signatur, eller NULL.';
comment on column api.editor_source_versions.text_extraction_tool is
  'Verktøyet teksten ble hentet ut av dokumentet med, eller NULL.';
comment on column api.editor_source_versions.text_extraction_tool_version is
  'Versjonen av verktøyet, ordrett slik det selv oppgir den, eller NULL.';
comment on column api.editor_source_versions.text_extraction_arguments is
  'Argumentene verktøyet ble kjørt med, ordrett, eller NULL. Sammen med verktøy og versjon er dette hele oppskriften teksten kan reproduseres av.';

-- ----------------------------------------------------------------------------
-- 8. Kontrollgrunnlaget bærer dokumentbindingen
--
-- Én projeksjon, lest av både den deterministiske verifikatoren og den
-- menneskelige kontrolløkten (migrasjon 005r). Verifikatoren trenger den for i
-- det hele tatt å kunne skaffe representasjonen på nytt: en dokumentbundet
-- versjon hentes ikke over nett. Mennesket trenger den for å vite hvilket
-- dokument utdragene står i.
--
-- Fremover-skrivende: signatur, eier og rettigheter er uendret, og `source_
-- version` får tre nye nøkler uten at noen eksisterende endrer form.
-- ----------------------------------------------------------------------------
create or replace function workflow.evidence_extraction_dossier(p_evidence_item_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select jsonb_build_object(
    'evidence_item_id', e.id,
    'created_at', e.created_at,
    'created_by_actor_id', e.created_by_actor_id,
    'created_by_actor_key', creator.actor_key,
    'created_by_actor_type', creator.actor_type::text,
    'extraction_method', e.extraction_method::text,
    'content_hash', e.content_hash,
    -- Erklæringen om hvem som laget utkastet, og når. NULL når kjøringen ikke
    -- fikk en: et funn registrert på editorveien, eller før migrasjon 005ab.
    -- Et objekt med tomme felter ville påstått at erklæringen fantes.
    'drafted_by', case
      when ar.input_manifest -> 'generated_by' ->> 'producer' is null then null
      else jsonb_build_object(
        'producer', ar.input_manifest -> 'generated_by' ->> 'producer',
        'provider', ar.input_manifest -> 'generated_by' ->> 'provider',
        'model', ar.input_manifest -> 'generated_by' ->> 'model',
        'model_version', ar.input_manifest -> 'generated_by' ->> 'model_version',
        'prompt_template_version',
          ar.input_manifest -> 'generated_by' ->> 'prompt_template_version',
        'drafted_at', ar.input_manifest -> 'generated_by' ->> 'drafted_at',
        'request_digest', ar.input_manifest -> 'generated_by' ->> 'request_digest'
      )
    end,
    -- Kjøringen som faktisk skrev raden, med sine egne premisser. NULL for et
    -- funn registrert på editorveien: der finnes ingen kjøring.
    'registered_by', case
      when ar.id is null then null
      else jsonb_build_object(
        'agent_run_id', ar.id,
        'agent_role', ar.agent_role::text,
        'provider', ar.provider,
        'model', ar.model,
        'model_version', ar.model_version,
        'prompt_template_version', ar.prompt_template_version,
        'pipeline_version', ar.pipeline_version,
        'started_at', ar.started_at
      )
    end,
    'source', jsonb_build_object(
      'source_id', s.id,
      'source_type', s.source_type::text,
      'title', s.title,
      'authors_or_issuer', s.authors_or_issuer,
      'publisher_or_journal', s.publisher_or_journal,
      'publication_date', s.publication_date,
      'publication_date_precision', s.publication_date_precision::text,
      'source_status', s.source_status::text,
      'status_note', s.status_note,
      -- De globale identifikatorene, som den menneskelige lenken bygges av.
      'identifiers', (
        select coalesce(jsonb_agg(
          jsonb_build_object(
            'identifier_system', si.identifier_system::text,
            'identifier_value', si.identifier_value
          )
          order by si.identifier_system::text
        ), '[]'::jsonb)
        from knowledge.source_identifiers si
        where si.source_id = s.id
      )
    ),
    'source_version', case
      when sv.id is null then null
      else jsonb_build_object(
        'source_version_id', sv.id,
        'retrieved_at', sv.retrieved_at,
        'retrieved_from', sv.retrieved_from,
        'external_version', sv.external_version,
        'content_hash', sv.content_hash,
        -- NULL betyr at opplysningen ikke er registrert, aldri at
        -- representasjonen er ukjent men brukbar (migrasjon 003b).
        'representation', sv.representation::text,
        -- Originaldokumentet representasjonen ble hentet ut av, og oppskriften
        -- den ble hentet ut med (migrasjon 003e). NULL — og ikke et objekt med
        -- tomme felter — når representasjonen er teksten på adressen: fravær av
        -- et dokument er en opplysning, ikke en struktur uten verdier.
        'document', case
          when sv.document_sha256 is null then null
          else jsonb_build_object(
            'sha256', sv.document_sha256,
            'byte_size', sv.document_byte_size,
            'media_type', sv.document_media_type,
            'text_extraction', jsonb_build_object(
              'tool', sv.text_extraction_tool,
              'tool_version', sv.text_extraction_tool_version,
              'arguments', sv.text_extraction_arguments
            )
          )
        end,
        'has_storage_reference', sv.storage_reference is not null
      )
    end,
    'field_groundings', workflow.evidence_field_groundings(e.id),
    -- Feltene en kliniker kontrollerer ett av gangen, og feltene forankringen
    -- faktisk dekker. Differansen er hva som mangler før funnet kan kontrolleres
    -- felt for felt, og den er ren mengdelære over to lister databasen leverer.
    'semantic_check_fields', to_jsonb(workflow.semantic_check_fields(e.id)::text[]),
    'grounded_check_fields', to_jsonb(workflow.grounded_check_fields(e.id)::text[]),
    -- Om maskinen har bevist venstresiden for nøyaktig dette grunnlaget. Uten
    -- den kan ingen menneskelig bekreftelse registreres (migrasjon 005x), og
    -- kontrolløkten skal si det før noen begynner å bedømme semantikken.
    'grounding_machine_proved', workflow.grounding_machine_proved(e.id),
    'extraction', jsonb_build_object(
      'design_code', e.design_code::text,
      'population_id', e.population_id,
      'population_label', pop.canonical_label,
      'population_availability', e.population_availability::text,
      'population_detail', e.population_detail,
      'sample_size', e.sample_size,
      'sample_size_availability', e.sample_size_availability::text,
      'intervention_drug_id', e.intervention_drug_id,
      'intervention_drug_name', d.canonical_name,
      'intervention_detail', e.intervention_detail,
      'comparator_kind', e.comparator_kind::text,
      'comparator_drug_id', e.comparator_drug_id,
      'comparator_drug_name', cd.canonical_name,
      'comparator_detail', e.comparator_detail,
      'outcome_concept_id', e.outcome_concept_id,
      'outcome_label', oc.canonical_label,
      'outcome_detail', e.outcome_detail,
      'timepoint_min', e.timepoint_min::text,
      'timepoint_max', e.timepoint_max::text,
      'timepoint_availability', e.timepoint_availability::text,
      'reported_direction', e.reported_direction::text,
      'effect_measure', e.effect_measure::text,
      'estimate', e.estimate::text,
      'estimate_unit', e.estimate_unit::text,
      'estimate_availability', e.estimate_availability::text,
      'ci_lower', e.ci_lower::text,
      'ci_upper', e.ci_upper::text,
      'ci_level_percent', e.ci_level_percent::text,
      'confidence_interval_availability', e.confidence_interval_availability::text,
      'limitations_text', e.limitations_text,
      'source_locator', e.source_locator,
      'raw_extraction', e.raw_extraction
    )
  )
  from knowledge.evidence_items e
  join knowledge.sources s on s.id = e.source_id
  join provenance.actors creator on creator.id = e.created_by_actor_id
  join catalog.drugs d on d.id = e.intervention_drug_id
  join catalog.clinical_concepts oc on oc.id = e.outcome_concept_id
  left join catalog.drugs cd on cd.id = e.comparator_drug_id
  left join catalog.populations pop on pop.id = e.population_id
  left join knowledge.source_versions sv on sv.id = e.source_version_id
  -- LEFT JOIN, fordi agent_run_id er nullbar: editorveien registrerer et funn
  -- uten kjøring (migrasjon 005u).
  left join provenance.agent_runs ar on ar.id = e.agent_run_id
  where e.id = p_evidence_item_id;
$$;

commit;
