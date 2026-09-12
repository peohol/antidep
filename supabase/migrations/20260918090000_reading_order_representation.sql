-- ============================================================================
-- Migrasjon 003g — oppskriften får en leserekkefølge, og listen får en rad til
--
-- Migrasjon 003e ga en kildeversjon en **oppskrift**: verktøyet, versjonen av
-- det og argumentene, lagret ordrett, slik at teksten kan hentes ut igjen og
-- fingeravtrykket etterprøves av hvem som helst med sin egen lovlige kopi av
-- dokumentet. 003f lukket listen over hva den oppskriften kunne være.
--
-- Oppskriften var `pdftotext -layout -enc UTF-8 -eol unix`, og den er feil.
--
-- ----------------------------------------------------------------------------
-- Hva som var galt
--
-- `-layout` gjenskaper den **fysiske** plasseringen på papiret. I en tospaltet
-- vitenskapelig artikkel står venstre og høyre spalte ved siden av hverandre —
-- og da står de ved siden av hverandre på den samme tekstlinjen i resultatet
-- også. Antideps ordrette kontroll normaliserer blanktegn før den søker
-- (`src/agents/extraction-checks.ts`), så to spalter som fysisk ligger side om
-- side, ble behandlet som **én sammenhengende tegnstrøm**.
--
-- Det er ikke et visningsproblem. En modell eller en deterministisk kontroll
-- kunne lese ord fra to uavhengige spalter som én setning, og en klinisk
-- opplysning kunne dermed bli tilskrevet feil behandlingsarm, feil studie eller
-- feil endepunkt. Det er en evidensintegritetsfeil (ANTIDEP_CONSTITUTION.md §8,
-- §11, issue #84).
--
-- ----------------------------------------------------------------------------
-- Hva oppskriften er nå
--
--   text_extraction_tool       = 'pdftotext'
--   text_extraction_arguments  = '-bbox-layout -enc UTF-8 -eol unix'
--   text_extraction_transform  = 'antidep-reading-order@2'
--
-- `-bbox-layout` gir ikke tekst, men **posisjonsdata**: hvert ord med sine
-- koordinater, gruppert i linjer og blokker. Antideps eget deterministiske ledd
-- (`src/agents/reading-order.ts`) bygger den logiske leserekkefølgen av dem —
-- spalte for spalte, ovenfra og ned, med tekst over full sidebredde håndtert av
-- den samme regelen — og **nekter** framfor å gjette når rekkefølgen ikke er
-- gitt av oppsettet. Leddet flytter blokker; det skriver ikke ett eneste tegn.
--
-- ----------------------------------------------------------------------------
-- Hvorfor etterbehandlingen må stå i raden
--
-- Uten den er representasjonen ikke reproduserbar. En tredjepart som kjører
-- `pdftotext -bbox-layout` på dokumentet, får en XHTML-fil med koordinater —
-- ikke teksten `content_hash` er beregnet av. Kolonnen navngir det siste leddet
-- i oppskriften, med versjon, slik at hele veien fra dokument til tekst er
-- skrevet ned: verktøy, versjon, argumenter, etterbehandling
-- (ANTIDEP_CONSTITUTION.md §8, EVIDENCE_PIPELINE.md §13, §19).
--
-- Endres regelen for rekkefølge, endres teksten. Da skal navnet få et nytt tall
-- — ikke den samme verdien et nytt innhold.
--
-- ----------------------------------------------------------------------------
-- Listen har to rader, og den nederste er ikke en overgangsordning
--
-- Hver dokumentutledet kildeversjon som allerede står i basen, er registrert med
-- `-layout` og uten etterbehandling. De radene **skrives ikke om**: en rad som
-- ble laget på én måte, skal ikke i ettertid påstå at den ble laget på en annen
-- (ANTIDEP_CONSTITUTION.md §14, DATABASE_ARCHITECTURE.md §36). Etterprøvingen av
-- dem skal gjenta det som faktisk ble gjort, og derfor må den gamle oppskriften
-- fortsatt kunne kjøres.
--
-- CHECK-en på tabellen svarer på hva som kan **lagres**, og godtar begge — ellers
-- ville den ikke kunne legges på i det hele tatt uten å underkjenne rader som
-- allerede står der. Inngangspunktet svarer på hva som kan **registreres nå**, og
-- godtar bare den nye. De to grensene er forskjellige grenser, og det er
-- forskjellen som lar historikken bestå uten at en ny rad kan bli laget feil.
--
-- Konsekvensen er tilsiktet og bærer hele leveransen: de fulltekstfunnene som
-- allerede er registrert, hviler på en representasjon med feil leserekkefølge.
-- De skal re-ekstraheres mot en **ny** kildeversjon med den nye oppskriften, og
-- den gamle raden blir stående som historikk.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- Ingen eksisterende rad. Ingen CHECK, policy, grant eller trigger er fjernet
-- eller svekket. `source_versions_text_extraction_recipe_allowlist_check`
-- erstattes av en som er strengere på formen (den dekker nå også
-- etterbehandlingen) og bredere på innholdet (den godtar den historiske raden
-- eksplisitt, framfor at den bare var den eneste).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §8, §11, §14
--   docs/DATABASE_ARCHITECTURE.md §7, §18, §36, §43, §50
--   docs/EVIDENCE_PIPELINE.md §3.8, §13, §19
--   issue #84
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Kolonnen
-- ----------------------------------------------------------------------------
alter table knowledge.source_versions
  add column text_extraction_transform text;

comment on column knowledge.source_versions.text_extraction_transform is
  'Antideps egen etterbehandling av verktøyets utdata, med versjon — i dag antidep-reading-order@2, som bygger den logiske leserekkefølgen av posisjonsdataene fra pdftotext -bbox-layout (migrasjon 003g, src/agents/reading-order.ts). NULL betyr at teksten er verktøyets utdata ordrett; det er tilstanden til hver dokumentutledet kildeversjon registrert før 003g, og den skal bestå. Kolonnen er en del av oppskriften og dermed av proveniensen: uten den kan ingen tredjepart komme fram til den samme teksten, og content_hash ville vært et fingeravtrykk av noe bare Antidep kunne lage.';

-- ----------------------------------------------------------------------------
-- 1b. Kommentarene som navngir en signatur som har endret seg
--
-- To kommentarer navngir skriveveiene med full signatur, og de to signaturene
-- endres i denne migrasjonen. En kommentar som navngir en funksjon som ikke
-- finnes, er nettopp det vakten i
-- supabase/tests/280_content_hash_serialization_test.sql fanger. Innholdet er
-- ordrett det samme; bare signaturen er den nye.
-- ----------------------------------------------------------------------------
comment on column knowledge.source_versions.document_sha256 is
  'sha256 av originaldokumentet denne representasjonen ble hentet ut av, med algoritmen som prefiks. Beregnet av databasen selv av bytene kalleren sendte til api.create_source_version_from_document(uuid, timestamptz, text, text, text, text, text, text, text, text, text, text): fingeravtrykket er aldri en verdi klienten oppgir, og kan derfor ikke være en garanti uten dekning. Dokumentet selv lagres ikke (EVIDENCE_PIPELINE.md §14). NULL betyr at representasjonen er teksten som lå på retrieved_from, ikke at dokumentet er ukjent.';

-- ----------------------------------------------------------------------------
-- 2. Formen på verdien, og hva den kan stå sammen med
--
-- En etterbehandling uten et verktøy er meningsløs: den beskriver hva som ble
-- gjort med utdataene fra en prosess som ikke fant sted. Det motsatte er
-- derimot en gyldig tilstand — verktøyets utdata brukt ordrett — og er nettopp
-- den de historiske radene er i.
-- ----------------------------------------------------------------------------
alter table knowledge.source_versions
  add constraint source_versions_text_extraction_transform_not_blank_check
    check (
      text_extraction_transform is null
      or (text_extraction_transform = btrim(text_extraction_transform)
          and length(text_extraction_transform) between 1 and 200)
    ),
  add constraint source_versions_text_extraction_transform_requires_tool_check
    check (text_extraction_transform is null or text_extraction_tool is not null);

-- ----------------------------------------------------------------------------
-- 3. Den lukkede listen, med to rader
--
-- Listen står ordrett og ikke bak en funksjon, av samme grunn som i 003f: den er
-- en sikkerhetsgrense, og den skal kunne leses der den gjelder. Den er ordrett
-- den samme i `src/agents/document-binding.ts`, og en prøve pinner begge sider.
-- ----------------------------------------------------------------------------
alter table knowledge.source_versions
  drop constraint source_versions_text_extraction_recipe_allowlist_check;

alter table knowledge.source_versions
  add constraint source_versions_text_extraction_recipe_allowlist_check
    check (
      text_extraction_tool is null
      or (
        text_extraction_tool = 'pdftotext'
        and (
          -- Oppskriften nye kildeversjoner registreres med (003g).
          (text_extraction_arguments = '-bbox-layout -enc UTF-8 -eol unix'
            and text_extraction_transform = 'antidep-reading-order@2')
          -- Den samme oppskriften med den første utgaven av etterbehandlingen.
          -- Den kan lagres, men ikke kjøres og ikke registreres på nytt: den
          -- delte ikke en tabellrad Poppler hadde lagt i én blokk, og lot et
          -- sitat gå fra en radetikett og inn i en fremmed celle. Raden står
          -- her fordi de kildeversjonene som bærer den, ikke skal skrives om
          -- for å se ut som om de ble laget med noe annet enn det de ble laget
          -- med.
          or (text_extraction_arguments = '-bbox-layout -enc UTF-8 -eol unix'
            and text_extraction_transform = 'antidep-reading-order@1')
          -- Oppskriften radene fra før 003g bærer. Den skal fortsatt kunne
          -- kjøres, slik at de radene kan etterprøves slik de faktisk ble laget.
          or (text_extraction_arguments = '-layout -enc UTF-8 -eol unix'
            and text_extraction_transform is null)
        )
      )
    );

comment on constraint source_versions_text_extraction_recipe_allowlist_check
  on knowledge.source_versions is
  'Oppskriften er lukket, og listen har tre rader (migrasjon 003g, utvider 003f): pdftotext med «-bbox-layout -enc UTF-8 -eol unix» og etterbehandlingen antidep-reading-order@2, som er den nye kildeversjoner registreres med; den samme med antidep-reading-order@1, som kan lagres men verken kjøres eller registreres på nytt; og pdftotext med «-layout -enc UTF-8 -eol unix» uten etterbehandling, som er den hver rad fra før 003g bærer. De to siste står der fordi historiske rader ikke skrives om: en rad skal si hva som faktisk ble gjort, også når det som ble gjort, ikke er det vi ville gjort i dag. At en oppskrift kan lagres, betyr verken at den kan registreres på nytt — api.create_source_version_from_document(...) godtar bare den første — eller at den kan kjøres: @1 er ute av den kjørbare listen i src/agents/document-binding.ts, fordi den ikke delte en tabellrad Poppler hadde lagt i én blokk og dermed lot et sitat gå fra en radetikett og inn i en fremmed celle. Alle tre verdiene blir en prosess ved ekstraksjon og etterprøving, og et fritt felt ville latt en skriverettighet bli kodekjøring hos den som kontrollerer. text_extraction_tool_version er med vilje utenfor listen: den er en opplysning som forklarer et avvik, ikke noe som kjøres, og fasiten er fingeravtrykket av teksten.';

-- ----------------------------------------------------------------------------
-- 4. Den nye kolonnen er en del av øyeblikksbildet, og fryses med det
--
-- Fremover-skrivende `create or replace function`: signatur, eier og rettigheter
-- er uendret, og triggeren som kaller den er den samme. Kunne etterbehandlingen
-- endres i ettertid, ville en registrert representasjon kunnet påstå at den ble
-- laget med en annen leserekkefølge enn den faktisk ble laget med.
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
    or new.text_extraction_transform is distinct from old.text_extraction_transform
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
  'Nekter enhver endring av de kolonnene som til sammen utgjør øyeblikksbildet av en hentet kilde: source_id, retrieved_at, retrieved_from, external_version, content_hash, representation, retrieved_by_actor_id, dokumentbindingen — document_sha256, document_byte_size, document_media_type — og hele oppskriften teksten ble hentet ut med: text_extraction_tool, text_extraction_tool_version, text_extraction_arguments (migrasjon 003e) og text_extraction_transform (migrasjon 003g) (DATABASE_ARCHITECTURE.md §18, §36). representation kom til i migrasjon 003b og er vernet fra 003c: den sier hva ekstraksjonen faktisk bygde på (EVIDENCE_PIPELINE.md §13), og en rad som stille kunne endres fra abstract til full_text ville latt en ekstraksjon se ut som om den hvilte på noe annet enn den gjorde. Dokumentbindingen og oppskriften er vernet av samme grunn, med et større utfall: kunne de endres, ville en registrert fulltekstekstraksjon kunnet flyttes fra ett dokument til et annet, eller fra én leserekkefølge til en annen, uten spor. storage_reference er med vilje utenfor vernet: hvor kopien ligger, er driftsinformasjon og ikke en påstand om kilden.';

-- ----------------------------------------------------------------------------
-- 5. Dokumentbindingen som JSON, ett sted
--
-- Formen leses av to ledd — ekstraksjonsoppdraget og kontrollgrunnlaget — og sto
-- skrevet to steder. To kopier av en form er to steder å legge til et felt, og
-- feilen ville først vist seg som en kildeversjon hentet på feil måte i det ene
-- leddet og ikke i det andre. Den står nå ett sted.
-- ----------------------------------------------------------------------------
create function knowledge.source_version_document_binding(p_source_version_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select case
    -- NULL — og ikke et objekt med tomme felter — når representasjonen er
    -- teksten på adressen: fravær av et dokument er en opplysning, ikke en
    -- struktur uten verdier.
    when sv.document_sha256 is null then null
    else jsonb_build_object(
      'sha256', sv.document_sha256,
      'byte_size', sv.document_byte_size,
      'media_type', sv.document_media_type,
      'text_extraction', jsonb_build_object(
        'tool', sv.text_extraction_tool,
        'tool_version', sv.text_extraction_tool_version,
        'arguments', sv.text_extraction_arguments,
        -- NULL betyr at teksten er verktøyets utdata ordrett (migrasjon 003g).
        'transform', sv.text_extraction_transform
      )
    )
  end
  from knowledge.source_versions sv
  where sv.id = p_source_version_id;
$$;

comment on function knowledge.source_version_document_binding(uuid) is
  'Originaldokumentet en kildeversjon er utledet av, og hele oppskriften teksten ble hentet ut med, som jsonb — eller NULL når representasjonen er teksten som lå på adressen (migrasjon 003e, 003g). Den ene definisjonen av formen, lest av både api.build_extraction_assignment(uuid, text[], text[], text[]) og workflow.evidence_extraction_dossier(uuid), slik at oppdraget og kontrollgrunnlaget aldri kan beskrive den samme bindingen forskjellig. Formen leses i koden av parseDocumentBinding (src/agents/document-binding.ts). text_extraction.transform er NULL for hver rad registrert før 003g, og betyr da at teksten er verktøyets utdata ordrett. SECURITY DEFINER fordi knowledge har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle. Tar ingen kaller-identitet og gjør ingen autorisasjon: den er et lesegrunnlag og ikke et endepunkt.';

revoke execute on function knowledge.source_version_document_binding(uuid) from public;

-- ----------------------------------------------------------------------------
-- 6. Innsettingen tar imot etterbehandlingen
--
-- DROP + CREATE og ikke en ny parameter med standardverdi: den siste ville laget
-- en *ny* funksjon ved siden av den gamle, og et kall med åtte argumenter ville
-- da vært tvetydig mellom to kandidater som begge har standardverdier for
-- resten. Rettighetene gjenopprettes identisk.
-- ----------------------------------------------------------------------------
drop function knowledge.record_source_version(
  uuid, timestamptz, text, text, text, text, text, uuid,
  text, bigint, text, text, text, text
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
  p_text_extraction_arguments text default null,
  p_text_extraction_transform text default null
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
    text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
    text_extraction_transform
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
    p_text_extraction_arguments,
    nullif(btrim(coalesce(p_text_extraction_transform, '')), '')
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
  text, bigint, text, text, text, text, text
) is
  'Innsettingen av én kildeversjon, uten autorisasjon: hasher den hentede representasjonen med knowledge.source_version_content_hash(text), setter inn raden attribuert til aktøren kalleren oppgir, og returnerer versjonens id. p_representation sier hva slags representasjon som ble hentet (EVIDENCE_PIPELINE.md §13); tom eller utelatt betyr at opplysningen ikke er registrert, og en agentekstraksjon kan da ikke bygge på versjonen (migrasjon 005v). De sju siste parameterne er dokumentbindingen fra migrasjon 003e og etterbehandlingen fra 003g, og oppgis bare av api.create_source_version_from_document(uuid, timestamptz, text, text, text, text, text, text, text, text, text, text); de seks første av dem er alt-eller-ingenting, håndhevet av source_versions_document_provenance_shape_check, mens p_text_extraction_transform er tom for de historiske radene og lagres da som NULL. Autorisasjonen ligger hos inngangspunktet som kaller den, slik at en senere skrivevei med en annen autorisasjonsmodell kan gjenbruke innsettingen framfor å kopiere den. Kalles fra innsiden av en SECURITY DEFINER-funksjon og trenger derfor ikke være det selv. Avviser en tom representasjon, en ukjent representasjonstype og innhold som begynner med PDF-signaturen, og oversetter dubletten til en setning på norsk uten å endre regelen.';

revoke execute on function knowledge.record_source_version(
  uuid, timestamptz, text, text, text, text, text, uuid,
  text, bigint, text, text, text, text, text
) from public;

-- ----------------------------------------------------------------------------
-- 7. Tekstveien, uendret utad
--
-- Samme signatur, samme rettigheter, samme virkemåte. Den lages på nytt fordi
-- den kaller innsettingen, som har fått en ny signatur — ikke fordi noe ved den
-- selv er endret.
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

comment on function api.create_source_version(
  uuid, timestamptz, text, text, text, text, text
) is
  'Den kontrollerte skriveveien for å registrere en kildeversjon (DATABASE_ARCHITECTURE.md §18, §43, MVP_IMPLEMENTATION_PLAN.md §15, §74.30 punkt 1, issue #44). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle (knowledge.assert_editor_authorized(uuid), kalt uten begrep), setter inn raden gjennom knowledge.record_source_version(uuid, timestamptz, text, text, text, text, text, uuid, text, bigint, text, text, text, text, text) attribuert til kallerens egen aktør, og returnerer versjonens id. content_hash er ikke en parameter: databasen beregner den av p_retrieved_content, slik at hashen aldri er en påstand kalleren skriver om seg selv. p_retrieved_content er påkrevd; en versjon uten fingeravtrykk kvalifiserer ikke som verifiserbart grunnlag (§74.32). p_representation sier hva slags representasjon som ble hentet (EVIDENCE_PIPELINE.md §13) og er valgfri utad, men en kildeversjon uten den kan ikke bære en agentekstraksjon (migrasjon 005v). Veien tar ingen dokumentbinding: en representasjon utledet av et originaldokument registreres med api.create_source_version_from_document(uuid, timestamptz, text, text, text, text, text, text, text, text, text, text), som lar databasen beregne dokumentets eget fingeravtrykk. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi knowledge.source_versions, workflow.user_roles og provenance.actors har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50). Ingen feltvalidering er duplisert her: constraintene på knowledge.source_versions er fasiten, og deres avvisninger propageres uendret.';

-- ----------------------------------------------------------------------------
-- 8. Dokumentveien tar imot etterbehandlingen, og godtar bare den nye oppskriften
--
-- DROP + CREATE, fordi signaturen endres og PostgREST ellers ville hatt to
-- kandidater for det samme navnet — hvilken som ble valgt, ville avhengt av
-- hvilke argumenter klienten tilfeldigvis sendte, altså av klienten og ikke av
-- kontrakten. Rettighetene gjenopprettes identisk.
--
-- Kontrollen her er **strengere** enn CHECK-en på tabellen, og det er med
-- hensikt: tabellen svarer på hva som kan lagres (og må godta de historiske
-- radene), inngangspunktet på hva som kan registreres nå. En ny kildeversjon
-- med den gamle oppskriften ville vært en ny rad med en kjent
-- evidensintegritetsfeil i seg.
-- ----------------------------------------------------------------------------
drop function api.create_source_version_from_document(
  uuid, timestamptz, text, text, text, text, text, text, text, text, text
);

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
  p_text_extraction_transform text,
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

  -- Den lukkede listen, sett fra skriveveien (migrasjon 003f, 003g). Bare den
  -- gjeldende oppskriften kan registreres: tabellen godtar i tillegg den
  -- historiske, fordi radene som allerede står der, ikke skrives om — men en ny
  -- rad med den ville vært en ny rad med en kjent evidensintegritetsfeil i seg.
  if p_text_extraction_tool is distinct from 'pdftotext'
    or p_text_extraction_arguments is distinct from '-bbox-layout -enc UTF-8 -eol unix'
    or p_text_extraction_transform is distinct from 'antidep-reading-order@2'
  then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Oppskriften er ikke den Antidep registrerer nye kildeversjoner med.',
      hint = 'Tillatt er nøyaktig verktøyet pdftotext med argumentene -bbox-layout -enc UTF-8 -eol unix og etterbehandlingen antidep-reading-order@2. Oppskriften kjøres på nytt ved hver etterprøving, og listen over hva som kan kjøres, er derfor lukket. Den forrige oppskriften (-layout, uten etterbehandling) la tekst fra to spalter på samme linje og kan ikke brukes til nye rader. Versjonen av verktøyet er fri: den er en opplysning, ikke noe som kjøres.';
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
    p_text_extraction_arguments,
    p_text_extraction_transform
  );
end;
$$;

comment on function api.create_source_version_from_document(
  uuid, timestamptz, text, text, text, text, text, text, text, text, text, text
) is
  'Den kontrollerte skriveveien for å registrere en kildeversjon som er utledet av et originaldokument, i dag en PDF (migrasjon 003e, 003g, ANTIDEP_CONSTITUTION.md §11, EVIDENCE_PIPELINE.md §13, §14). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle (knowledge.assert_editor_authorized(uuid), kalt uten begrep), dekoder p_document_base64, krever at bytene er en PDF, beregner sha256 og størrelsen av dem, og setter inn raden gjennom knowledge.record_source_version(uuid, timestamptz, text, text, text, text, text, uuid, text, bigint, text, text, text, text, text) med content_hash beregnet av p_extracted_text. Verken fingeravtrykket, størrelsen eller mediatypen er parametre: alle tre avleses av dokumentet selv, slik at ingen av dem er en påstand kalleren skriver om seg selv. Dokumentet lagres ikke — bytene brukes til å beregne fingeravtrykket og forsvinner med transaksjonen. p_representation er påkrevd her (til forskjell fra tekstveien), fordi en dokumentutledet representasjon som ikke sier hva den er, er den ene tilstanden denne veien finnes for å unngå. Oppskriften — verktøy, versjon, argumenter og etterbehandling — er kontrakten utad: kjør den på dokumentet med document_sha256, og sha256 av resultatet skal være content_hash. Fra migrasjon 003g godtar denne veien nøyaktig én oppskrift: pdftotext med -bbox-layout -enc UTF-8 -eol unix og etterbehandlingen antidep-reading-order@2, som bygger den logiske leserekkefølgen av posisjonsdataene (src/agents/reading-order.ts). Den forrige oppskriften (-layout, uten etterbehandling) la tekst fra to spalter på samme tekstlinje og er derfor ikke lenger registrerbar, men er fortsatt lovlig lagret og kjørbar, slik at radene som bærer den, kan etterprøves slik de faktisk ble laget (source_versions_text_extraction_recipe_allowlist_check). Verdiene blir kjørt ved hver etterprøving, og et fritt felt ville latt en skriverettighet bli kodekjøring hos den som kontrollerer; p_text_extraction_tool_version er fri, fordi den er en opplysning og ikke noe som kjøres. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi knowledge.source_versions, workflow.user_roles og provenance.actors har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50).';

revoke execute on function api.create_source_version_from_document(
  uuid, timestamptz, text, text, text, text, text, text, text, text, text, text
) from public;
grant execute on function api.create_source_version_from_document(
  uuid, timestamptz, text, text, text, text, text, text, text, text, text, text
) to authenticated;

-- ----------------------------------------------------------------------------
-- 9. Den redaksjonelle lesemodellen viser hele oppskriften
--
-- `create or replace view` legger den nye kolonnen til på slutten. Formen på de
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
  sv.text_extraction_arguments    as text_extraction_arguments,
  sv.text_extraction_transform    as text_extraction_transform
from knowledge.source_versions sv;

comment on column api.editor_source_versions.text_extraction_transform is
  'Antideps egen etterbehandling av verktøyets utdata, med versjon, eller NULL. NULL betyr at teksten er verktøyets utdata ordrett — tilstanden til hver dokumentutledet kildeversjon registrert før migrasjon 003g. Sammen med verktøy, versjon og argumenter er dette hele oppskriften teksten kan reproduseres av.';

-- ----------------------------------------------------------------------------
-- 10. Ekstraksjonsoppdraget bærer hele oppskriften
--
-- Fremover-skrivende `create or replace function`: signatur, eier og rettigheter
-- er uendret. Den ene endringen er at dokumentbindingen nå bygges av
-- knowledge.source_version_document_binding(uuid) framfor av en kopi av formen.
-- ----------------------------------------------------------------------------
create or replace function api.build_extraction_assignment(
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
    'document', knowledge.source_version_document_binding(v_version.id),
    'drugs', v_drugs,
    'outcomes', v_outcomes,
    'populations', v_populations
  );
end;
$$;

comment on function api.build_extraction_assignment(uuid, text[], text[], text[]) is
  'Bygger ett ekstraksjonsoppdrag av databasens egne rader (migrasjon 007i, assignments/README.md). Kontrollerer at kalleren har en registrert, aktiv aktør og en gyldig editor-rolle (knowledge.assert_editor_authorized(uuid), kalt uten begrep), slår opp kildeversjonen med adressen, fingeravtrykket og en eventuell dokumentbinding, og oversetter kanoniske navn til katalogens id-er. Dokumentbindingen bygges fra migrasjon 003g av knowledge.source_version_document_binding(uuid), som er den ene definisjonen av formen og også leses av kontrollgrunnlaget. Svaret er nøyaktig innholdet i oppdragsfilen modell-leddet leser, på formen antidep/extraction-assignment@2. Ingen av de sju identifikatorene skrives derfor for hånd, og kildebindingen kan ikke settes sammen av verdier fra to forskjellige rader. Navneoppslaget er ufølsomt for store og små bokstaver og bruker kanoniske navn; et ukjent navn gir en avvisning som navngir verdien, aldri et oppdrag med én avgrensning mindre enn kalleren ba om. En kildeversjon uten content_hash eller uten representasjonstype avvises: den første er ikke en etterprøvbar representasjon (§74.32), den andre kan ikke bære en agentekstraksjon (migrasjon 005v). Funksjonen velger ikke kildeversjon — hvilken utgave av en artikkel som skal ekstraheres, er en faglig avgjørelse — og den gir modell-leddet ingen databasetilgang: oppdraget er fortsatt en fil, og editor-rollen er kallerens, ikke modellens (EVIDENCE_PIPELINE.md §63). SECURITY DEFINER fordi knowledge, catalog, workflow og provenance har RLS med default deny for authenticated; tomt search_path, og kalleren valideres på funksjonens eget kall (§50).';

-- ----------------------------------------------------------------------------
-- 11. Kontrollgrunnlaget bærer hele oppskriften
--
-- Samme endring, samme grunn: den ene definisjonen av dokumentbindingen, lest
-- av både oppdraget og kontrollgrunnlaget.
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
        'document', knowledge.source_version_document_binding(sv.id),
        'has_storage_reference', sv.storage_reference is not null
      )
    end,
    'field_groundings', workflow.evidence_field_groundings(e.id),
    -- Feltene en kliniker kontrollerer ett av gangen, og feltene forankringen
    -- faktisk dekker. Differansen er hva som mangler før funnet kan kontrolleres
    -- felt for felt, og den er ren mengdelære over to lister databasen leverer.
    'semantic_check_fields', to_jsonb(workflow.semantic_check_fields(e.id)::text[]),
    'grounded_check_fields', to_jsonb(workflow.grounded_check_fields(e.id)::text[]),
    -- Feltene raden fører med en fraværsstatus som gjelder kilden som
    -- helhet. Listen er databasens egen (migrasjon 005ae), slik at
    -- publiseringsgaten, det kildeomfattende kontrollleddet og
    -- kontrollflaten leser nøyaktig det samme settet.
    'source_wide_absence_fields',
      to_jsonb(workflow.source_wide_absence_fields(e.id)::text[]),
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
comment on function workflow.evidence_extraction_dossier(uuid) is
  'Grunnlaget for én ekstraksjonskontroll: evidensfunnets identitet og opphav, hvem som laget utkastet (drafted_by: produsent, leverandør, modell, modellversjon, promptmalversjon, tidspunktet utkastet ble laget og fingeravtrykket av forespørselen — erklæringen forslaget bar med seg, lest ut av kjøringens input_manifest; NULL når ingen erklæring fulgte med), kjøringen som registrerte raden (registered_by: rolle, leverandør, modell, modellversjon, promptmalversjon, pipelineversjon og starttidspunkt — NULL når funnet ble registrert på editorveien og ingen kjøring finnes), kilden med sin status og sine identifikatorer, kildeversjonen (eller null når ingen er registrert, med retrieved_from, content_hash og representasjonstype når den finnes), kildeforankringen per felt, feltsettene (inkludert source_wide_absence_fields: feltene raden fører med en fraværsstatus som gjelder kilden som helhet, migrasjon 005ae) og maskinbeviset, og hele den strukturerte ekstraksjonen ordrett, inkludert source_locator og raw_extraction (ANTIDEP_CONSTITUTION.md §11, §12, §20, DATABASE_ARCHITECTURE.md §29, EVIDENCE_PIPELINE.md §46, §65). De to er skilt fordi utkastet og registreringen er forskjellige operasjoner på forskjellige tidspunkter: registered_by.started_at er registreringstidspunktet, mens drafted_by.drafted_at er da modellen faktisk leste kilden. drafted_by er kontrollgrunnlag og ikke driftsinformasjon: en kontrollør leser et maskinutkast annerledes enn en kollegas ekstraksjon, og «hvilke funn ble laget med denne promptmalen» skal kunne besvares fra kontrollflaten. Uttrykket er den ene projeksjonen både den menneskelige kontrollflaten og den deterministiske verifikatoren leser, slik at de aldri kontrollerer hvert sitt grunnlag (§4, §9). Dokumentbindingen bygges fra migrasjon 003g av knowledge.source_version_document_binding(uuid), som er den ene definisjonen av formen og også leses av ekstraksjonsoppdraget. storage_reference er ikke eksponert, bare om den finnes. Numeriske verdier er ::text, slik at et eksakt desimaltall ikke går veien om en IEEE-754 double før noen leser det. NULL når evidensfunnet ikke finnes. Tar ingen kaller-identitet og gjør ingen autorisasjon: den er et lesegrunnlag og ikke et endepunkt, og hver flate som eksponerer den autentiserer først. SECURITY DEFINER fordi knowledge, catalog og provenance har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

commit;
