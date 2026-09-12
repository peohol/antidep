-- ============================================================================
-- 003h + 005ag: leserekkefølgen får sin andre utgave, og fjerningen låser først
--
-- En fremovermigrasjon, ikke en redigering av 003g og 005af. Grunnen er at de
-- to allerede er **kjørt** mot det driftede prosjektet og registrert i
-- supabase_migrations.schema_migrations, og Supabase kjører aldri en registrert
-- versjon på nytt (MVP_IMPLEMENTATION_PLAN.md §74.32). Rettes de i sin egen
-- fil, blir en fersk database bygget av repoet stående med én kontrakt og det
-- driftede prosjektet med en annen — migrasjonsdrift i en sikkerhetskritisk
-- proveniens- og skrivevei. De to filene er derfor satt tilbake til det som
-- faktisk ble kjørt, og alt som kom etter, står her.
--
-- Begge veiene ender i den samme tilstanden:
--
--   fersk database      003g (@1) → 005af (uten lås) → denne (@2, med lås)
--   driftet prosjekt    003g og 005af registrert     → denne (@2, med lås)
--
-- Setningene er derfor skrevet slik at de tåler å kjøre på begge: `drop`/`add`
-- på kontrollen, og `create or replace` på funksjonene. Ingen av dem antar en
-- tilstand de ikke selv setter.
--
-- ----------------------------------------------------------------------------
-- 1. Hva som er nytt i oppskriften
--
-- `antidep-reading-order@2` deler en tabellrad Poppler har lagt i én blokk.
-- Poppler legger radetiketten og verdicellene som egne linjer på den samme
-- grunnlinjen inne i den samme blokken, og et linjeskift er det *myke* skillet
-- et ordrett søk får krysse (src/agents/extraction-checks.ts). Sitatet
-- «17-Item HAM-D score, 19.4 ± 3.9» ble derfor gjenfunnet «ordrett», enda det
-- ikke er en leserekkefølge i dokumentet — den samme evidensintegritetsfeilen
-- som spaltene, ett nivå lenger ned (issue #84, ANTIDEP_CONSTITUTION.md §8, §11).
--
-- Listen over hva som kan **lagres** får dermed en tredje rad: `@1` blir
-- liggende, fordi de kildeversjonene som bærer den, ikke skal skrives om for å
-- se ut som om de ble laget med noe annet enn det de ble laget med (§14). At den
-- kan lagres, betyr verken at den kan registreres på nytt — skriveveien under
-- godtar bare `@2` — eller at den kan kjøres: `@1` er ute av den kjørbare listen
-- i src/agents/document-binding.ts.
--
-- ----------------------------------------------------------------------------
-- 2. Hva som er nytt i fjerningen
--
-- `knowledge.discard_unpublished_extraction_artifacts(...)` leste kontrollen av
-- menneskelig kildekontroll **før** slettingen låste tabellen. En kontroll
-- commitet i mellomtiden ville blitt lest som fraværende og deretter slettet, og
-- øyeblikksbildet ville ikke hatt den — det motsatte av å feile lukket. De tre
-- tabellene låses nå i ACCESS EXCLUSIVE før den første kontrollen.
--
-- Funksjonen er ellers uendret, og signaturen er den samme, så `create or
-- replace` holder: ingen grant skal gjenopprettes, og EXECUTE står fortsatt
-- revokert fra PUBLIC.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Kolonnen sier nå hvilken utgave som er dagens
-- ----------------------------------------------------------------------------
comment on column knowledge.source_versions.text_extraction_transform is
  'Antideps egen etterbehandling av verktøyets utdata, med versjon — i dag antidep-reading-order@2, som bygger den logiske leserekkefølgen av posisjonsdataene fra pdftotext -bbox-layout (migrasjon 003g, src/agents/reading-order.ts). NULL betyr at teksten er verktøyets utdata ordrett; det er tilstanden til hver dokumentutledet kildeversjon registrert før 003g, og den skal bestå. Kolonnen er en del av oppskriften og dermed av proveniensen: uten den kan ingen tredjepart komme fram til den samme teksten, og content_hash ville vært et fingeravtrykk av noe bare Antidep kunne lage.';

-- ----------------------------------------------------------------------------
-- 2. Listen over hva som kan lagres, med tre rader
--
-- `drop` og `add` framfor en endring på stedet: en CHECK-kontroll kan ikke
-- endres, og den nye kontrolleres mot radene som allerede står der. Radene i
-- det driftede prosjektet bærer i dag `@1` eller `-layout`, og begge er med i
-- den nye listen, så den validerer.
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
-- 3. Skriveveien registrerer bare @2
--
-- Signaturen er uendret, så `create or replace` framfor DROP + CREATE: da står
-- grantene, og PostgREST får ingen overload å velge mellom.
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

-- ----------------------------------------------------------------------------
-- 4. Fjerningen låser før den kontrollerer
-- ----------------------------------------------------------------------------
create or replace function knowledge.discard_unpublished_extraction_artifacts(
  p_evidence_item_ids uuid[],
  p_reason text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_id uuid;
  v_snapshots jsonb := '{}'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_verifications bigint := 0;
  v_groundings bigint := 0;
  v_items bigint := 0;
begin
  -- Fjerningen er en redaksjonell handling med en ansvarlig, ikke en
  -- driftsoperasjon: auditraden skal navngi den som bestemte den.
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Fjerningen mangler en begrunnelse, og da kan den ikke registreres.',
      hint = 'Oppgi hvorfor funnene fjernes. Begrunnelsen er det som gjør en hard sletting rapporterbar i ettertid (ANTIDEP_CONSTITUTION.md §14).';
  end if;

  if p_evidence_item_ids is null or cardinality(p_evidence_item_ids) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ingen evidensfunn er oppgitt.',
      hint = 'Veien tar en eksplisitt liste med id-er. Den kan ikke kalles med et predikat, og den kan ikke feie: hvilke rader som fjernes, skal være skrevet ned før kallet, ikke utledet av det.';
  end if;

  if cardinality(p_evidence_item_ids) > 50 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%s evidensfunn er oppgitt, og grensen er 50.', cardinality(p_evidence_item_ids)),
      hint = 'En reset er en navngitt liste noen har gått gjennom. Er listen lengre enn dette, er den ikke gjennomgått.';
  end if;

  if (select count(distinct x) from unnest(p_evidence_item_ids) as x)
     <> cardinality(p_evidence_item_ids) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Listen inneholder samme evidensfunn mer enn én gang.',
      hint = 'En dublett betyr at listen ikke er den gjennomgåtte listen. Rett den framfor å la kallet gjøre noe annet enn det som ble bestemt.';
  end if;

  -- ------------------------------------------------------------------------
  -- Låsen. Den tas før kontrollene, ikke som en følge av slettingen, og det er
  -- rekkefølgen som gjør at kontrollen under faktisk feiler lukket: en
  -- menneskelig kildekontroll commitet etter at kontrollen har lest tabellen,
  -- men før slettingen hadde låst den, ville blitt lest som fraværende og så
  -- slettet av kallet — og øyeblikksbildet ville ikke hatt den. Tilstanden
  -- kontrollene leser, skal være den samme tilstanden slettingen møter.
  --
  -- ACCESS EXCLUSIVE er den samme låsen ALTER TABLE trenger nedenfor, tatt i
  -- den samme rekkefølgen, slik at slettingen ikke må oppgradere en lås
  -- underveis. En egen LOCK-setning framfor å flytte ALTER-setningene hit:
  -- ALTER TABLE krever i tillegg at køen av utsatte triggerhendelser er tom,
  -- og det er et annet krav enn å låse.
  --
  -- De tre øvrige kontrollene — påstandslenke, reviewbeslutning og claim-sitat
  -- — trenger ingen egen lås: de tabellene peker på knowledge.evidence_items
  -- med `on delete restrict`, så en rad commitet underveis stopper slettingen
  -- framfor å forsvinne med den.
  -- ------------------------------------------------------------------------
  lock table workflow.evidence_verifications in access exclusive mode;
  lock table knowledge.evidence_field_groundings in access exclusive mode;
  lock table knowledge.evidence_items in access exclusive mode;

  -- ------------------------------------------------------------------------
  -- Kontrollene. Alle kjøres før noe slettes, og én rad som feiler stopper
  -- hele kallet: en delvis reset ville etterlatt en tilstand ingen bestemte.
  -- ------------------------------------------------------------------------
  foreach v_id in array p_evidence_item_ids loop
    if not exists (select 1 from knowledge.evidence_items e where e.id = v_id) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Evidensfunnet %s finnes ikke.', v_id),
        hint = 'Listen er ikke den databasen har. Hent køen på nytt framfor å fjerne noe annet enn det som ble gjennomgått.';
    end if;

    if exists (
      select 1
      from workflow.evidence_verifications ev
      join provenance.actors a on a.id = ev.verifier_actor_id
      where ev.evidence_item_id = v_id
        and a.actor_type = 'human'
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s er menneskelig kildekontrollert, og fjernes ikke.', v_id),
        hint = 'En utført menneskelig kontroll er en faglig handling med en ansvarlig bak. Den skal ikke kunne forsvinne (ANTIDEP_CONSTITUTION.md §12, §14).';
    end if;

    if exists (select 1 from knowledge.claim_evidence_links l where l.evidence_item_id = v_id) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s bærer en påstandsrevisjon, og fjernes ikke.', v_id),
        hint = 'Funnet er lenket til en claim-revisjon. Å fjerne det ville gjort revisjonen til en påstand uten det grunnlaget den ble laget av — publisert eller ikke (ANTIDEP_CONSTITUTION.md §4, §8).';
    end if;

    if exists (select 1 from workflow.review_decisions rd where rd.evidence_item_id = v_id) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s har en registrert reviewbeslutning, og fjernes ikke.', v_id),
        hint = 'En beslutning er en utført faglig handling, og tabellen er append-only av samme grunn som kontrollene.';
    end if;

    if exists (
      select 1 from workflow.claim_verification_citations c where c.evidence_item_id = v_id
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s er sitert i en claim-verifikasjon, og fjernes ikke.', v_id),
        hint = 'Kontrollen registrerte hva den faktisk leste. Å fjerne funnet ville skrevet om den nedtegnelsen.';
    end if;

    -- Øyeblikksbildet tas før slettingen, og er hele kontrollgrunnlaget: det som
    -- fjernes, skal fortsatt kunne leses av den som spør hva som sto der.
    v_snapshots := v_snapshots || jsonb_build_object(
      v_id::text,
      jsonb_build_object(
        -- `id` er påkrevd av events_snapshot_identifies_object_check: et
        -- øyeblikksbilde skal navngi objektet raden handler om, slik at det
        -- ikke kan havne på feil objekt.
        'id', v_id,
        'dossier', workflow.evidence_extraction_dossier(v_id),
        'extraction_verifications', (
          select coalesce(jsonb_agg(to_jsonb(ev) order by ev.created_at), '[]'::jsonb)
          from workflow.evidence_verifications ev
          where ev.evidence_item_id = v_id
        )
      )
    );
  end loop;

  -- ------------------------------------------------------------------------
  -- Slettingen. Append-only-vernet er fasiten for enhver annen skrivevei, og
  -- skrus av bare her, bare i denne transaksjonen, og slås på igjen også når
  -- noe går galt.
  -- ------------------------------------------------------------------------
  begin
    -- `ALTER TABLE` kan ikke kjøre på en tabell med utsatte triggerhendelser i
    -- kø, og forankringskontrollen på knowledge.evidence_items er utsatt til
    -- commit (migrasjon 003d). I en reset som kjører alene er køen tom og
    -- setningen en nulloperasjon; ligger det en registrering foran i den samme
    -- transaksjonen, kjøres kontrollen av den nå — og en registrering som ikke
    -- holder, stopper fjerningen framfor å bli commitet etter den.
    --
    -- Modusen settes tilbake etterpå, også når noe går galt. Uten det ville en
    -- registrering *senere* i den samme transaksjonen blitt kontrollert før
    -- forankringen sin var skrevet, og en lovlig registrering ville blitt
    -- avvist av et valg denne funksjonen gjorde.
    set constraints all immediate;

    alter table workflow.evidence_verifications disable trigger evidence_verifications_reject_mutation;
    alter table knowledge.evidence_field_groundings disable trigger evidence_field_groundings_reject_mutation;
    alter table knowledge.evidence_items disable trigger evidence_items_reject_mutation;

    delete from workflow.evidence_verifications ev
    where ev.evidence_item_id = any(p_evidence_item_ids);
    get diagnostics v_verifications = row_count;

    delete from knowledge.evidence_field_groundings g
    where g.evidence_item_id = any(p_evidence_item_ids);
    get diagnostics v_groundings = row_count;

    delete from knowledge.evidence_items e
    where e.id = any(p_evidence_item_ids);
    get diagnostics v_items = row_count;

    alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;
    alter table knowledge.evidence_field_groundings enable trigger evidence_field_groundings_reject_mutation;
    alter table workflow.evidence_verifications enable trigger evidence_verifications_reject_mutation;
    set constraints all deferred;
  exception
    when others then
      alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;
      alter table knowledge.evidence_field_groundings enable trigger evidence_field_groundings_reject_mutation;
      alter table workflow.evidence_verifications enable trigger evidence_verifications_reject_mutation;
      set constraints all deferred;
      raise;
  end;

  if v_items <> cardinality(p_evidence_item_ids) then
    -- Kan i praksis ikke skje: eksistensen er kontrollert over, og
    -- transaksjonen holder låsen. En påstand som ikke kontrolleres, er likevel
    -- ikke en påstand noen kan stole på.
    raise exception using
      errcode = 'restrict_violation',
      message = format('%s av %s evidensfunn ble fjernet. Ingenting er lagret.',
                       v_items, cardinality(p_evidence_item_ids));
  end if;

  -- ------------------------------------------------------------------------
  -- Sporet. Én rad per fjernet funn, med det som sto der.
  -- ------------------------------------------------------------------------
  foreach v_id in array p_evidence_item_ids loop
    insert into audit.events
      (operation, object_id, actor_id, old_revision_or_snapshot, reason, occurred_at)
    values
      ('extraction_artifact_discarded', v_id, v_actor_id,
       v_snapshots -> v_id::text, btrim(p_reason), now());
    v_removed := v_removed || to_jsonb(v_id::text);
  end loop;

  return jsonb_build_object(
    'discarded_evidence_item_ids', v_removed,
    'deleted_extraction_verifications', v_verifications,
    'deleted_field_groundings', v_groundings,
    'discarded_by_actor_id', v_actor_id,
    'reason', btrim(p_reason)
  );
end;
$$;

comment on function knowledge.discard_unpublished_extraction_artifacts(uuid[], text) is
  'Fjerner et eksplisitt oppgitt sett upubliserte evidensfunn med sine forankringer og maskinelle kontroller, i én transaksjon, og skriver en auditrad per funn med hele kontrollgrunnlaget som old_revision_or_snapshot (migrasjon 005af, issue #84). Finnes fordi pipelinen fortsatt bygges: fulltekstfunn registrert med den forrige oppskriften hviler på en representasjon der tekst fra to spalter lå på samme tekstlinje, og å la dem stå i kontrollkøen ville invitert en kliniker til å gjøre den faglige kildekontrollen på et grunnlag som ikke holder (migrasjon 003g). Dette er IKKE en redaksjonell funksjon: EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle, så den er nåbar bare for den som allerede har eiertilgang til databasen — og den innskrenker dermed en operasjon eieren ellers kunne gjort uten spor, framfor å utvide noen rettighet. Krever i tillegg en autorisert redaktøridentitet (knowledge.assert_editor_authorized(uuid), kalt uten begrep) og en begrunnelse. Feiler lukket, og uten å slette noe, dersom ett av funnene er menneskelig kildekontrollert, bærer en påstandslenke, har en registrert reviewbeslutning eller er sitert i en claim-verifikasjon; en id som ikke finnes, en dublett, en tom liste og en liste over 50 avvises på samme måte. Kilder, originaldokumenter, kildeversjoner, agentkjøringer og auditrader røres ikke: en kildeversjon er et øyeblikksbilde med verdi uavhengig av hvilke funn som ble laget av den. Append-only-triggerne på de tre tabellene skrus av og på inne i transaksjonen, også når noe går galt, slik at vernet aldri står av utenfor dette kallet. De tre tabellene låses i ACCESS EXCLUSIVE før kontrollene kjører, ikke først ved slettingen: uten det ville en menneskelig kildekontroll commitet mellom kontrollen og slettingen blitt lest som fraværende og så slettet, altså det motsatte av å feile lukket. De tre øvrige kontrollene trenger ingen egen lås: påstandslenker, reviewbeslutninger og claim-sitater peker på knowledge.evidence_items med on delete restrict, så en rad commitet underveis stopper slettingen framfor å forsvinne med den. SECURITY DEFINER fordi knowledge, workflow, provenance og audit har RLS med default deny, og fordi ALTER TABLE ... DISABLE TRIGGER krever eierskap; tomt search_path.';

commit;
