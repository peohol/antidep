-- ============================================================================
-- Migrasjon 009a — fulltekstbiblioteket: originalfilen blir liggende, identiteten
--                  er databasens, og tilhørigheten til publikasjonen er kontrollert
--
-- Fram til nå har en dokumentbundet kildeversjon bevist tre ting: at *et*
-- dokument fantes, hva sha256 av bytene var, og hvilken oppskrift teksten ble
-- hentet ut med. Dokumentet selv forsvant med transaksjonen
-- (migrasjon 003e). Konsekvensen var at hver senere agentjobb var avhengig av at
-- noen hadde den samme filen liggende lokalt, og at ingenting i Antidep kunne
-- svare på om filen i det hele tatt var *den artikkelen* kildeversjonen påsto å
-- være.
--
-- Denne migrasjonen lukker begge hullene, og legger til den tredje kontrollen
-- ingen av dem dekket: at fullteksten faktisk er lesbar, tabellene inkludert.
--
-- ----------------------------------------------------------------------------
-- 1. Originalfilen ligger i databasen, ikke i en katalog
--
-- `knowledge.source_documents` er privat på nøyaktig samme måte som resten av
-- `knowledge`: RLS med default deny, ingen grants, ingen policy, ingen view.
-- Ingen klientrolle kan lese én byte av den, og den eneste veien inn er en
-- kontrollert SECURITY DEFINER-funksjon. Det er gjengivelsesgrensen
-- ANTIDEP_CONSTITUTION.md regel 2 krever: originalfilen er privat, og
-- gjengivelsesrett vurderes separat.
--
-- Bytene ligger i en `bytea` og ikke i en objektlagringsbøtte. Valget er ikke
-- et kompromiss: en bøtte er en *annen* tjeneste med sin egen tilgangsmodell,
-- og en fil som lå der, ville hatt en identitet og en tilgangskontroll ingen
-- migrasjon og ingen pgTAP-test kunne håndheve. Her er filen, fingeravtrykket,
-- publikasjonstilhørigheten og lesbarhetskontrollen én transaksjon og ett sett
-- regler — og hele kjeden kan prøves lokalt fra en tom database.
--
-- ----------------------------------------------------------------------------
-- 2. Filidentiteten er databasens, og den er innholdet
--
-- `sha256` er ingen parameter. Den beregnes av bytene
-- (`knowledge.source_document_fingerprint`), og en CHECK gjentar regningen på
-- selve raden: en rad kan ikke lagres med et fingeravtrykk som ikke er
-- innholdets. Det er forskjellen på en garanti og en påstand — og det er derfor
-- unikhetsregelen på `sha256` gjør opplastingen idempotent uten å kunne
-- forveksle to filer: den samme filen lastet opp igjen er den samme raden, og en
-- *annen* fil kan ikke ta plassen til en registrert identitet.
--
-- ----------------------------------------------------------------------------
-- 3. Tilhørigheten til publikasjonen kontrolleres, den erklæres ikke
--
-- Et korrekt fingeravtrykk beviser hvilken fil dette er. Det beviser ingenting
-- om hvilken *artikkel* den er. En redaktør som lastet opp feil PDF under riktig
-- kilde, ville fått en kildeversjon med perfekt proveniens og feil innhold — og
-- hvert ordrett utdrag ville stemt, mot feil artikkel.
--
-- `knowledge.publication_binding_for` leser derfor den uttrukne teksten og
-- krever at den bærer kildens egen registrerte identitet: DOI-en, PMID-en eller
-- tittelen. Finner den ingen av delene, avvises opplastingen. Det er
-- fail-closed: en fil som ikke kan vises å tilhøre publikasjonen, blir ikke en
-- fulltekstversjon i det hele tatt.
--
-- Grunnlaget lagres med raden, fordi «hvordan vet vi det» er en del av svaret.
--
-- ----------------------------------------------------------------------------
-- 4. Lesbarhet, og tabellene særskilt
--
-- En PDF kan gi tekst uten å gi *artikkelen*. To former er vanlige nok til å
-- måtte stenges: et tynt eller ødelagt tekstlag som gir noen hundre tegn støy,
-- og en artikkel der brødteksten kom med mens tallene lå i tabeller som ble
-- droppet som bilder. Den andre er den farlige: teksten ser hel ut, og nettopp
-- de kliniske tallene mangler.
--
-- `knowledge.full_text_readability_metrics` måler derfor fire ting, og
-- `knowledge.full_text_readability_problem` avgjør uttømmende om de holder:
-- mengde tekst, andelen bokstaver, antall linjer, og antall linjer som faktisk
-- er *datarader* — en etikett fulgt av minst to talls-kolonner. I tillegg:
-- erklærer dokumentet en tabell («Table 3», «Tabell 3»), må minst én slik
-- erklæring faktisk ha datarader under seg. Da er det ikke lenger mulig å
-- registrere en fulltekst der tabellene ble borte i uttrekkingen.
--
-- Terskelverdiene står i `knowledge.full_text_readability_problem` og er speilet
-- ordrett i `src/agents/full-text-readability.ts`, slik at opplasteren kan si
-- hva som er galt før filen sendes. Databasen er fasiten; speilet er en
-- høflighet.
--
-- ----------------------------------------------------------------------------
-- 5. Gaten flyttes fra «har en binding» til «ligger i biblioteket»
--
-- `knowledge.assert_clinical_full_text` krevde en komplett dokumentbinding.
-- Den krever nå i tillegg at dokumentet ligger i biblioteket, at det er bundet
-- til nøyaktig den kilden evidensfunnet peker på, og at fullteksten har bestått
-- lesbarhetskontrollen. Et evidensfunn kan dermed ikke lenger bygge på en
-- fulltekst ingen kan hente fram igjen, eller på en fil ingen har vist at
-- tilhører publikasjonen.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 1, 2, 4, 7
--   docs/DATABASE_ARCHITECTURE.md §5, §35, §42-§50
--   docs/EVIDENCE_PIPELINE.md, docs/KNOWLEDGE_MODEL.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. audit.events dekker de fire nye operasjonene
--
-- En generert kolonne kan ikke endres, så begge slippes og lages på nytt — samme
-- grep som i migrasjon 005af, 005ah og 004a.
-- ----------------------------------------------------------------------------
alter table audit.events drop column object_schema;
alter table audit.events drop column object_table;

alter table audit.events add column object_schema text not null generated always as (
  case operation
    when 'claim_published' then 'knowledge'
    when 'claim_publication_replaced' then 'knowledge'
    when 'claim_publication_withdrawn' then 'knowledge'
    when 'claim_publication_rolled_back' then 'knowledge'
    when 'role_granted' then 'workflow'
    when 'role_ended' then 'workflow'
    when 'source_created' then 'knowledge'
    when 'evidence_item_created' then 'knowledge'
    when 'agent_identity_registered' then 'provenance'
    when 'agent_identity_credential_issued' then 'provenance'
    when 'agent_identity_revoked' then 'provenance'
    when 'evidence_verification_registered' then 'workflow'
    when 'source_version_registered' then 'knowledge'
    when 'claim_verification_registered' then 'workflow'
    when 'review_decision_registered' then 'workflow'
    when 'evidence_field_grounding_recorded' then 'knowledge'
    when 'extraction_artifact_discarded' then 'knowledge'
    when 'claim_artifact_discarded' then 'knowledge'
    when 'claim_revision_created' then 'knowledge'
    when 'source_document_stored' then 'knowledge'
    when 'role_model_assignment_registered' then 'provenance'
    when 'role_model_assignment_closed' then 'provenance'
    when 'candidate_built' then 'knowledge'
    when 'candidate_final_control_recorded' then 'workflow'
    else null
  end
) stored;

alter table audit.events add column object_table text not null generated always as (
  case operation
    when 'claim_published' then 'claims'
    when 'claim_publication_replaced' then 'claims'
    when 'claim_publication_withdrawn' then 'claims'
    when 'claim_publication_rolled_back' then 'claims'
    when 'role_granted' then 'user_roles'
    when 'role_ended' then 'user_roles'
    when 'source_created' then 'sources'
    when 'evidence_item_created' then 'evidence_items'
    when 'agent_identity_registered' then 'agent_identities'
    when 'agent_identity_credential_issued' then 'agent_identities'
    when 'agent_identity_revoked' then 'agent_identities'
    when 'evidence_verification_registered' then 'evidence_verifications'
    when 'source_version_registered' then 'source_versions'
    when 'claim_verification_registered' then 'claim_verifications'
    when 'review_decision_registered' then 'review_decisions'
    when 'evidence_field_grounding_recorded' then 'evidence_field_groundings'
    when 'extraction_artifact_discarded' then 'evidence_items'
    when 'claim_artifact_discarded' then 'claims'
    when 'claim_revision_created' then 'claim_revisions'
    when 'source_document_stored' then 'source_documents'
    when 'role_model_assignment_registered' then 'role_model_assignments'
    when 'role_model_assignment_closed' then 'role_model_assignments'
    when 'candidate_built' then 'candidates'
    when 'candidate_final_control_recorded' then 'candidate_final_controls'
    else null
  end
) stored;

comment on column audit.events.object_schema is
  'Schemaet objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen framfor oppgitt av kalleren: en kaller som kunne skrive det selv, kunne skrevet feil, og en auditrad som peker på et annet objekt enn den beskriver, er verre enn ingen auditrad. Uttrykket er uttømmende med ELSE NULL, og en ny operasjon uten sin gren feiler derfor på NOT NULL framfor å bli en rad uten sted.';
comment on column audit.events.object_table is
  'Tabellen objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen, med samme begrunnelse som object_schema.';

-- Indeksen henger på de to kolonnene og forsvant med dem. Navnet er det samme
-- som før, fordi supabase/tests/300_audit_structure_test.sql kontrollerer at
-- oppslagsveien loggen finnes for, er indeksert — under sitt navn.
create index events_object_occurred_at_idx
  on audit.events (object_schema, object_table, object_id, occurred_at desc);

alter table audit.events drop constraint events_snapshot_shape_check;
alter table audit.events add constraint events_snapshot_shape_check
  check (
    case operation
      when 'claim_published' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_replaced' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_withdrawn' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_rolled_back' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'role_granted' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'role_ended' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'source_created' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'evidence_item_created' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'agent_identity_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'agent_identity_credential_issued' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'agent_identity_revoked' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'evidence_verification_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'source_version_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'claim_verification_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'review_decision_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'evidence_field_grounding_recorded' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      -- Fjerningen: det finnes et før og ingen etter (migrasjon 005af).
      when 'extraction_artifact_discarded' then old_revision_or_snapshot is not null and new_revision_or_snapshot is null
      -- Påstandssidens fjerning, med den samme formen (migrasjon 005ah).
      when 'claim_artifact_discarded' then old_revision_or_snapshot is not null and new_revision_or_snapshot is null
      -- En ny påstandsrevisjon: det finnes ingen tidligere utgave av *denne*
      -- raden, fordi en revisjon er uforanderlig. Videreføringen den eventuelt
      -- erstatter, står i øyeblikksbildets supersedes_revision_id.
      when 'claim_revision_created' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      -- De fire nye er alle opprettelser av uforanderlige rader: det finnes
      -- ingen tidligere utgave, bare et etter. Øyeblikksbildet av en
      -- biblioteksfil bærer med vilje ikke bytene; se auditskriveren under.
      when 'source_document_stored' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'role_model_assignment_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      -- Avslutningen er en endring av en rad som allerede fantes, så begge
      -- øyeblikksbildene skal være der: uten det gamle kunne ingen se hva som
      -- ble avsluttet.
      when 'role_model_assignment_closed' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'candidate_built' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'candidate_final_control_recorded' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      else false
    end
  );

comment on constraint events_snapshot_shape_check on audit.events is
  'Hvilke øyeblikksbilder hver operasjon skal bære (DATABASE_ARCHITECTURE.md §35). Uttømmende CASE med ELSE false: en ny operasjon uten sin egen gren kan ikke bli en auditrad, og det er tilsiktet — en auditrad uten det øyeblikksbildet operasjonen forutsetter, ville sett ut som et spor uten å være et. En opprettelse har bare et etter, en endring har begge, og en fjerning (extraction_artifact_discarded i migrasjon 005af, claim_artifact_discarded i 005ah) har bare et før.';

-- ----------------------------------------------------------------------------
-- 2. Det private fulltekstbiblioteket
-- ----------------------------------------------------------------------------
create table knowledge.source_documents (
  id uuid primary key default gen_random_uuid(),

  -- Identiteten. Ingen parameter: beregnet av bytene, og gjentatt av CHECK-en
  -- under, slik at raden ikke kan bære et fingeravtrykk som ikke er innholdets.
  sha256 text not null,
  byte_size bigint not null,
  media_type text not null,
  content bytea not null,

  stored_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  stored_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Innholdsadressert identitet: den samme filen er den samme raden, og en
  -- annen fil kan ikke ta plassen til en registrert identitet. Det er denne
  -- regelen som gjør opplastingen idempotent uten å gjøre den upresis.
  constraint source_documents_sha256_key unique (sha256),
  constraint source_documents_sha256_format_check
    check (sha256 ~ '^sha256:[0-9a-f]{64}$'),
  constraint source_documents_sha256_is_the_content_check
    check (sha256 = knowledge.source_document_fingerprint(content)),
  constraint source_documents_byte_size_check
    check (byte_size > 0 and byte_size = octet_length(content)),
  -- 64 MiB, samme grense som api.create_source_version_from_document. En
  -- fulltekstartikkel er noen få megabyte; er filen større, er den noe annet.
  constraint source_documents_byte_size_limit_check
    check (byte_size <= 67108864),
  constraint source_documents_media_type_check
    check (media_type = 'application/pdf'),
  -- PDF-signaturen, avlest av dokumentet selv: %PDF- er 25 50 44 46 2d.
  constraint source_documents_is_pdf_check
    check (substring(content from 1 for 5) = '\x255044462d'::bytea)
);

comment on table knowledge.source_documents is
  'Det private fulltekstbiblioteket: originalfilen en dokumentbundet kildeversjon er utledet av, lagret varig (ANTIDEP_CONSTITUTION.md regel 2, KNOWLEDGE_MODEL.md). Raden er innholdsadressert — sha256 beregnes av bytene og gjentas av en CHECK, så identiteten er databasens og aldri en påstand kalleren skriver om seg selv. Tabellen har RLS med default deny og ingen grants: ingen klientrolle kan lese én byte, og den eneste veien inn er api.upload_full_text_document(uuid, timestamptz, text, text, text, text, text, text, text, text). Filen er privat; gjengivelsesrett vurderes separat. Append-only: en fil rettes ved at en ny lastes opp, ikke ved at en registrert identitet får nytt innhold.';
comment on column knowledge.source_documents.sha256 is
  'sha256 av filens byte, med algoritmen som prefiks, beregnet av knowledge.source_document_fingerprint(bytea). Aldri en parameter. source_documents_sha256_is_the_content_check gjentar regningen på raden, slik at et fingeravtrykk som ikke er innholdets, ikke kan lagres i det hele tatt.';
comment on column knowledge.source_documents.content is
  'Originalfilens byte, ordrett. Lagret i databasen og ikke i en objektlagringsbøtte, fordi filen, fingeravtrykket, publikasjonstilhørigheten og lesbarhetskontrollen da er én transaksjon og ett sett regler som kan prøves lokalt. Eksternt innhold er data, aldri instruksjoner: bytene leses aldri som noe annet enn bytes.';
comment on column knowledge.source_documents.stored_by_actor_id is
  'Aktøren som la filen i biblioteket. Leses av kallerens egen autorisasjon, ikke oppgitt av kalleren.';

alter table knowledge.source_documents enable row level security;

create trigger source_documents_set_row_timestamps
  before insert or update on knowledge.source_documents
  for each row execute function catalog.set_row_timestamps();

create trigger source_documents_are_append_only
  before update or delete on knowledge.source_documents
  for each row execute function knowledge.reject_append_only_mutation(
    'En registrert originalfil er identiteten til alt som er utledet av den. Last opp den korrigerte filen som en ny rad; den får sitt eget fingeravtrykk, fordi den er en annen fil.'
  );

-- ----------------------------------------------------------------------------
-- 3. Hvilken publikasjon filen tilhører, og hvordan vi vet det
-- ----------------------------------------------------------------------------
create type knowledge.publication_binding_basis as enum ('doi', 'pmid', 'title');

-- PUBLIC har som standard usage på nye typer, og Antidep gir privilegier
-- eksplisitt (migrasjon 001).
revoke usage on type knowledge.publication_binding_basis from public;

comment on type knowledge.publication_binding_basis is
  'Hva som knyttet en biblioteksfil til en publikasjon: doi (kildens registrerte DOI står i fullteksten), pmid (PMID-en står der, navngitt som en PMID) eller title (kildens tittel står der). Rekkefølgen er styrkerekkefølgen, og den er ikke tilfeldig: en DOI identifiserer publikasjonen entydig, mens en tittel kan deles av et referanselistetreff. Bindingsgrunnlaget lagres fordi «hvordan vet vi det» er en del av svaret.';

create table knowledge.source_document_publications (
  id uuid primary key default gen_random_uuid(),

  source_document_id uuid not null
    references knowledge.source_documents (id) on update restrict on delete restrict,
  source_id uuid not null
    references knowledge.sources (id) on update restrict on delete restrict,

  binding_basis knowledge.publication_binding_basis not null,
  -- Nøyaktig den verdien som ble funnet igjen i fullteksten. Lagret slik at en
  -- tredjepart kan gjenta oppslaget uten å måtte gjette hva som ble søkt etter.
  binding_evidence text not null,

  bound_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  bound_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint source_document_publications_pairing_key
    unique (source_document_id, source_id),
  constraint source_document_publications_evidence_not_blank_check
    check (binding_evidence = btrim(binding_evidence)
           and length(binding_evidence) between 1 and 600)
);

comment on table knowledge.source_document_publications is
  'Hvilken publikasjon en biblioteksfil er vist å tilhøre, og på hvilket grunnlag (ANTIDEP_CONSTITUTION.md regel 1, 2). Raden skrives bare av api.upload_full_text_document(uuid, timestamptz, text, text, text, text, text, text, text, text), som leser den uttrukne teksten og krever at den bærer kildens egen registrerte identitet. Et korrekt fingeravtrykk beviser hvilken fil dette er, ikke hvilken artikkel den er; denne tabellen er den andre halvdelen. Én fil kan tilhøre flere kilder bare dersom hver av dem er vist for seg.';
comment on column knowledge.source_document_publications.binding_evidence is
  'Verdien som faktisk ble funnet igjen i fullteksten — DOI-en, PMID-en eller den normaliserte tittelen. Lagret ordrett slik oppslaget kan gjentas av en tredjepart.';

alter table knowledge.source_document_publications enable row level security;

create index source_document_publications_source_id_idx
  on knowledge.source_document_publications (source_id);

create trigger source_document_publications_set_row_timestamps
  before insert or update on knowledge.source_document_publications
  for each row execute function catalog.set_row_timestamps();

create trigger source_document_publications_are_append_only
  before update or delete on knowledge.source_document_publications
  for each row execute function knowledge.reject_append_only_mutation(
    'Bindingen sier hva som ble kontrollert den gangen. Er bindingen feil, er kildeversjonen bygget på den også feil, og begge deler rettes ved å registrere på nytt.'
  );

-- ----------------------------------------------------------------------------
-- 4. Lesbarhetskontrollen, inkludert tabellene
--
-- Målingen og dommen er skilt med vilje. Målingen er tall om en tekst og kan
-- leses av hvem som helst som vil forstå en avvisning; dommen er én uttømmende
-- regel, på ett sted, som både opplastingen og gaten bruker.
-- ----------------------------------------------------------------------------

/**
 * Tallene lesbarhetsdommen felles på.
 *
 * `table_rows` er den som betyr noe klinisk: en linje med en etikett og minst
 * to talls-kolonner er formen en resultattabell har etter tekstuttrekking. Er
 * det ingen slike linjer, kom tabellene ikke med — og da mangler nettopp de
 * tallene et evidensfunn skal hentes fra.
 */
create function knowledge.full_text_readability_metrics(p_text text)
  returns jsonb
  language sql
  immutable
  set search_path = ''
as $$
  with lines as (
    select line
    from unnest(string_to_array(coalesce(p_text, ''), E'\n')) as line
  ),
  table_rows as (
    -- En datarad er en linje der tallene dominerer: minst to tall-tokens, og
    -- minst en tredel av ordene på linjen.
    --
    -- Regelen måler *ord* og ikke mellomrom, og det er ikke en detalj.
    -- Antideps leserekkefølge (antidep-reading-order@2) bygger teksten av
    -- ordposisjoner og setter nøyaktig ett mellomrom mellom ordene, så en
    -- tabellrad kommer ut som «Age (years) 42.1 41.8». En regel som lette etter
    -- kolonner skilt av flere mellomrom — slik «pdftotext -layout» setter dem —
    -- ville ikke funnet en eneste tabellrad i en ekte artikkel, og
    -- lesbarhetskontrollen ville avvist alt.
    --
    -- Tredelskravet skiller raden fra en resultatsetning: «Mean percent weight
    -- change was 1.0% at endpoint with a 95% confidence interval from 0.5% to
    -- 1.5%» har fire tall blant sytten ord, og er brødtekst.
    select l.line
    from lines l
    cross join lateral (
      select count(*) as total,
             count(*) filter (
               where token ~ '^[-+(\[]?[0-9]+([.,][0-9]+)?[%)\]]?$'
             ) as numeric_tokens
      from regexp_split_to_table(btrim(l.line), '[[:space:]]+') as token
      where token <> ''
    ) t
    where t.total >= 3 and t.numeric_tokens >= 2 and t.numeric_tokens * 3 >= t.total
  ),
  declarations as (
    select line
    from lines
    -- `\y` og ikke `\b`: i PostgreSQLs regexdialekt betyr `\b` backspace, og
    -- ordgrensen heter `\y`. Feilen ville ikke gitt en feilmelding, bare en
    -- tabellkontroll som aldri fant en tabellerklæring.
    where line ~* '^[[:space:]]*(table|tabell)[[:space:]]+([0-9]+|[ivx]+)\y'
  )
  select jsonb_build_object(
    'character_count', length(coalesce(p_text, '')),
    'letter_count', coalesce(length(regexp_replace(coalesce(p_text, ''), '[^[:alpha:]]', '', 'g')), 0),
    'line_count', (select count(*) from lines),
    'table_rows', (select count(*) from table_rows),
    'table_declarations', (select count(*) from declarations)
  );
$$;

revoke execute on function knowledge.full_text_readability_metrics(text) from public;

comment on function knowledge.full_text_readability_metrics(text) is
  'Tallene lesbarhetsdommen felles på: antall tegn, antall bokstaver, antall linjer, antall linjer som har formen til en datarad (en etikett fulgt av minst to talls-kolonner skilt av to eller flere blanktegn), og antall tabellerklæringer («Table 3», «Tabell 3»). Ren måling uten dom, slik at en avvisning kan forklares med tall framfor med en påstand. IMMUTABLE fordi den bare leser argumentet sitt; speilet i src/agents/full-text-readability.ts bruker de samme reglene.';

/**
 * Hvorfor teksten ikke er en lesbar fulltekst, eller NULL når den er det.
 *
 * Uttømmende og fail-closed: alt som ikke oppfyller hver terskel, er en
 * avvisning med én setning som sier hvilken. Tersklene er valgt for å skille en
 * artikkel fra de to formene som ellers slipper gjennom — et tynt tekstlag, og
 * en artikkel der tabellene ble droppet som bilder.
 */
create function knowledge.full_text_readability_problem(p_text text)
  returns text
  language plpgsql
  immutable
  set search_path = ''
as $$
declare
  m jsonb := knowledge.full_text_readability_metrics(p_text);
  v_characters bigint := (m ->> 'character_count')::bigint;
  v_letters bigint := (m ->> 'letter_count')::bigint;
  v_lines bigint := (m ->> 'line_count')::bigint;
  v_table_rows bigint := (m ->> 'table_rows')::bigint;
  v_declarations bigint := (m ->> 'table_declarations')::bigint;
begin
  if v_characters < 3000 then
    return format(
      'Fullteksten er %s tegn, og grensen er 3000. En fulltekstartikkel er tusenvis av tegn; et tynt eller ødelagt tekstlag er ikke en fulltekst noen kan kontrollere et ordrett utdrag mot.',
      v_characters
    );
  end if;
  if v_lines < 60 then
    return format(
      'Fullteksten har %s linjer, og grensen er 60. Så få linjer er et sammendrag eller en forside, ikke en artikkel.',
      v_lines
    );
  end if;
  if v_letters * 2 < v_characters then
    return format(
      'Bare %s av %s tegn er bokstaver, og grensen er halvparten. Et tekstlag som er mest tegnstøy, gir utdrag ingen kan lese tilbake til artikkelen.',
      v_letters, v_characters
    );
  end if;
  if v_table_rows < 3 then
    return format(
      'Fullteksten har %s linjer med form som en datarad, og grensen er 3. Tallene i en artikkel står i tabellene; kom de ikke med i tekstuttrekkingen, ser teksten hel ut samtidig som nettopp de kliniske verdiene mangler.',
      v_table_rows
    );
  end if;
  if v_declarations > 0 and v_table_rows < v_declarations then
    return format(
      'Fullteksten erklærer %s tabeller, men har bare %s linjer med form som en datarad. Minst én erklært tabell står dermed uten innhold, og en tabell som er borte, er ikke et fravær av data — den er data som ikke kom med.',
      v_declarations, v_table_rows
    );
  end if;
  return null;
end;
$$;

revoke execute on function knowledge.full_text_readability_problem(text) from public;

comment on function knowledge.full_text_readability_problem(text) is
  'Hvorfor en uttrukket tekst ikke er en lesbar fulltekst, eller NULL når den er det (ANTIDEP_CONSTITUTION.md regel 1, 4). Uttømmende og fail-closed: for lite tekst, for få linjer, for lav bokstavandel, for få datarader, eller flere erklærte tabeller enn det finnes datarader til. Den siste er tabellkontrollen: en artikkel der tabellene ble droppet som bilder, ser hel ut i brødteksten samtidig som de kliniske tallene mangler. Tersklene er speilet ordrett i src/agents/full-text-readability.ts; databasen er fasiten.';

create table knowledge.full_text_readability_checks (
  id uuid primary key default gen_random_uuid(),

  source_version_id uuid not null
    references knowledge.source_versions (id) on update restrict on delete restrict,
  source_document_id uuid not null
    references knowledge.source_documents (id) on update restrict on delete restrict,

  -- Målingen, ordrett slik den ble gjort. Tallene er ikke en oppsummering: de
  -- er grunnlaget dommen ble felt på, og de gjør en senere strengere terskel
  -- etterprøvbar mot rader som allerede står der.
  character_count bigint not null,
  letter_count bigint not null,
  line_count bigint not null,
  table_row_count bigint not null,
  table_declaration_count bigint not null,

  checked_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Én kontroll per kildeversjon. Raden finnes bare når kontrollen gikk
  -- gjennom: opplastingen er én transaksjon, og en avvist fulltekst etterlater
  -- verken kildeversjon eller kontrollrad. Fraværet av raden er derfor dommen,
  -- og gaten leser den slik.
  constraint full_text_readability_checks_source_version_key unique (source_version_id),
  constraint full_text_readability_checks_counts_check
    check (character_count >= 0 and letter_count >= 0 and line_count >= 0
           and table_row_count >= 0 and table_declaration_count >= 0)
);

comment on table knowledge.full_text_readability_checks is
  'Målingen bak lesbarhetsdommen for én fulltekstversjon (ANTIDEP_CONSTITUTION.md regel 1, 4). Raden finnes bare når knowledge.full_text_readability_problem(text) svarte NULL: opplastingen er én transaksjon, og en avvist fulltekst etterlater verken kildeversjon eller kontrollrad. Fraværet av raden er derfor selve dommen, og knowledge.assert_clinical_full_text leser den slik — fail-closed. Tallene lagres fordi en senere strengere terskel da kan etterprøves mot rader som allerede står der, framfor å gjelde ukjent grunnlag.';

alter table knowledge.full_text_readability_checks enable row level security;

create index full_text_readability_checks_document_idx
  on knowledge.full_text_readability_checks (source_document_id);

create trigger full_text_readability_checks_set_row_timestamps
  before insert or update on knowledge.full_text_readability_checks
  for each row execute function catalog.set_row_timestamps();

create trigger full_text_readability_checks_are_append_only
  before update or delete on knowledge.full_text_readability_checks
  for each row execute function knowledge.reject_append_only_mutation(
    'Kontrollen sier hva som ble målt den gangen. En ny måling hører til en ny kildeversjon.'
  );

-- ----------------------------------------------------------------------------
-- 5. Publikasjonstilhørigheten, kontrollert av teksten selv
-- ----------------------------------------------------------------------------

/**
 * Teksten slik et oppslag gjøres i den: små bokstaver, uten orddeling over
 * linjeskift, og med hvert blanktegn samlet til ett mellomrom.
 *
 * Normaliseringen er nødvendig fordi en PDF setter linjeskift og orddeling der
 * det passer for papiret. Den er samtidig smal med vilje: den fjerner ingen
 * tegn ut over dem, så et treff er fortsatt et treff på den faktiske teksten.
 */
create function knowledge.normalize_for_binding(p_text text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select btrim(regexp_replace(
    regexp_replace(lower(coalesce(p_text, '')), '-[[:space:]]+', '', 'g'),
    '[[:space:]]+', ' ', 'g'
  ));
$$;

revoke execute on function knowledge.normalize_for_binding(text) from public;

comment on function knowledge.normalize_for_binding(text) is
  'Teksten slik et bindingsoppslag gjøres i den: små bokstaver, orddeling over linjeskift fjernet, og hvert blanktegn samlet til ett mellomrom. Smal med vilje — ingen andre tegn fjernes, så et treff er et treff på den faktiske teksten. Brukes både på fullteksten og på det som søkes etter, slik at de to er normalisert likt.';

/**
 * Hvilken av kildens registrerte identiteter fullteksten faktisk bærer.
 *
 * Svarer med `{basis, evidence}` eller NULL. NULL er en avvisning og ikke en
 * tvil: en fil ingen kan vise tilhører publikasjonen, blir ikke en
 * fulltekstversjon.
 */
create function knowledge.publication_binding_for(p_source_id uuid, p_text text)
  returns jsonb
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_text text := knowledge.normalize_for_binding(p_text);
  v_value text;
  v_title text;
  v_probe text;
begin
  -- DOI først: den identifiserer publikasjonen entydig, og et treff kan ikke
  -- forveksles med noe annet i teksten.
  for v_value in
    select i.identifier_value
    from knowledge.source_identifiers i
    where i.source_id = p_source_id and i.identifier_system = 'doi'
    order by i.identifier_value
  loop
    if position(knowledge.normalize_for_binding(v_value) in v_text) > 0 then
      return jsonb_build_object('basis', 'doi', 'evidence', v_value);
    end if;
  end loop;

  -- PMID: et bart tall er ingen identitet, så tallet må stå navngitt som en
  -- PMID. Uten det kravet ville et sidetall kunnet binde feil artikkel.
  for v_value in
    select i.identifier_value
    from knowledge.source_identifiers i
    where i.source_id = p_source_id and i.identifier_system = 'pmid'
    order by i.identifier_value
  loop
    if v_text ~ ('(pmid|pubmed)[^0-9]{0,20}' || v_value || '([^0-9]|$)') then
      return jsonb_build_object('basis', 'pmid', 'evidence', v_value);
    end if;
  end loop;

  -- Tittelen er det svakeste grunnlaget og står derfor sist: den kan i
  -- prinsippet treffe en referanseliste. Den er likevel med, fordi en
  -- fulltekst uten registrert DOI eller PMID ellers ikke kunne bindes i det
  -- hele tatt — og et krav ingen kan oppfylle, blir et krav som slås av.
  select knowledge.normalize_for_binding(s.title) into v_title
  from knowledge.sources s
  where s.id = p_source_id;

  if v_title is not null and length(v_title) >= 20 then
    -- Lange titler brytes og omskrives i sats. Prøven er derfor de første 60
    -- tegnene, som er langt mer enn nok til å identifisere en artikkel, og
    -- kort nok til å overleve en linjedeling midt i tittelen.
    v_probe := left(v_title, 60);
    if position(v_probe in v_text) > 0 then
      return jsonb_build_object('basis', 'title', 'evidence', v_probe);
    end if;
  end if;

  return null;
end;
$$;

revoke execute on function knowledge.publication_binding_for(uuid, text) from public;

comment on function knowledge.publication_binding_for(uuid, text) is
  'Hvilken av kildens registrerte identiteter fullteksten faktisk bærer, som {basis, evidence} — eller NULL når den ikke bærer noen (ANTIDEP_CONSTITUTION.md regel 1, 2). Prøver DOI, så PMID, så tittel, i den rekkefølgen fordi det er styrkerekkefølgen. PMID-en må stå navngitt som en PMID: et bart tall er ingen identitet, og et sidetall ville ellers kunnet binde feil artikkel. Tittelprøven er de første 60 tegnene av den normaliserte tittelen, som overlever en linjedeling i sats. NULL er en avvisning og ikke en tvil: api.upload_full_text_document(uuid, timestamptz, text, text, text, text, text, text, text, text) stopper der.';

-- ----------------------------------------------------------------------------
-- 6. Auditskriveren over nye biblioteksfiler
--
-- Øyeblikksbildet er raden **uten bytene**. En auditlogg er et spor over hva som
-- skjedde, ikke en andre kopi av en opphavsrettslig beskyttet fulltekst — og en
-- kopi der ville dessuten ligget utenfor den ene tabellen hele tilgangsmodellen
-- er skrevet for.
-- ----------------------------------------------------------------------------
create function audit.record_source_document_event()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
begin
  insert into audit.events (
    operation, object_id, actor_id,
    old_revision_or_snapshot, new_revision_or_snapshot, occurred_at
  )
  values (
    'source_document_stored'::audit.event_operation,
    new.id,
    new.stored_by_actor_id,
    null,
    to_jsonb(new) - 'content',
    now()
  );

  return null;
end;
$$;

comment on function audit.record_source_document_event() is
  'Auditskriver over nye filer i fulltekstbiblioteket (DATABASE_ARCHITECTURE.md §35). Øyeblikksbildet er raden uten bytene: loggen skal bære sporet, ikke en andre kopi av en opphavsrettslig beskyttet fulltekst utenfor den tabellen tilgangsmodellen er skrevet for. Fingeravtrykket står igjen, og det er det som identifiserer filen. Ligger på tabellen og ikke på skriveveien, slik at en senere skrivevei ikke kan legge inn en fil uten spor.';

revoke execute on function audit.record_source_document_event() from public;

create trigger source_documents_record_storage_audit_event
  after insert on knowledge.source_documents
  for each row execute function audit.record_source_document_event();

-- ----------------------------------------------------------------------------
-- 7. Skriveveien: én opplasting, én transaksjon, tre kontroller
-- ----------------------------------------------------------------------------
create function api.upload_full_text_document(
  p_source_id uuid,
  p_retrieved_at timestamptz,
  p_retrieved_from text,
  p_document_base64 text,
  p_extracted_text text,
  p_text_extraction_tool text,
  p_text_extraction_tool_version text,
  p_text_extraction_arguments text,
  p_text_extraction_transform text,
  p_external_version text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_bytes bytea;
  v_size bigint;
  v_sha text;
  v_document_id uuid;
  v_document_created boolean := false;
  v_binding jsonb;
  v_problem text;
  v_metrics jsonb;
  v_content_hash text;
  v_source_version_id uuid;
  v_version_created boolean := false;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if not exists (select 1 from knowledge.sources s where s.id = p_source_id) then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kilden %L finnes ikke.', p_source_id),
      hint = 'En fulltekst hører til en registrert publikasjon. Opprett kilden med api.create_source(...) først.';
  end if;

  if nullif(btrim(coalesce(p_document_base64, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Originaldokumentet mangler, og da er det ingenting å legge i biblioteket.',
      hint = 'Send filen som base64, byte for byte. Databasen beregner fingeravtrykket selv.';
  end if;

  begin
    v_bytes := decode(p_document_base64, 'base64');
  exception
    when others then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Originaldokumentet er ikke gyldig base64.',
        hint = 'Kod filen slik den er. Enhver omforming underveis ville gitt et fingeravtrykk som ikke er filens.';
  end;

  v_size := octet_length(v_bytes);
  if v_size = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Originaldokumentet er tomt, og en tom fil identifiserer ingen artikkel.';
  end if;
  if v_size > 67108864 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Originaldokumentet er %s byte, og grensen er 67108864.', v_size),
      hint = 'En fulltekstartikkel er normalt noen få megabyte. Er filen større, er den sannsynligvis noe annet enn artikkelen.';
  end if;
  if substring(v_bytes from 1 for 5) <> '\x255044462d'::bytea then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Originaldokumentet er ikke en PDF.',
      hint = 'Antidep henter i dag bare tekst ut av PDF med etterprøvbar proveniens.';
  end if;

  if left(coalesce(p_extracted_text, ''), 5) = '%PDF-' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Den uttrukne teksten er selv en PDF, og er dermed ikke tekst noen kan lese et ordrett utdrag ut av.',
      hint = 'Oppgi resultatet av tekstuttrekkingen, ikke dokumentet en gang til.';
  end if;

  -- Den lukkede oppskriftslisten, sett fra skriveveien (migrasjon 003f, 003g).
  -- Bare den gjeldende oppskriften kan registreres.
  if p_text_extraction_tool is distinct from 'pdftotext'
    or p_text_extraction_arguments is distinct from '-bbox-layout -enc UTF-8 -eol unix'
    or p_text_extraction_transform is distinct from 'antidep-reading-order@2'
  then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Oppskriften er ikke den Antidep registrerer nye kildeversjoner med.',
      hint = 'Tillatt er nøyaktig verktøyet pdftotext med argumentene -bbox-layout -enc UTF-8 -eol unix og etterbehandlingen antidep-reading-order@2. Oppskriften kjøres på nytt ved hver etterprøving, og listen over hva som kan kjøres, er derfor lukket. Versjonen av verktøyet er fri: den er en opplysning, ikke noe som kjøres.';
  end if;

  -- 1. Filidentiteten. Innholdsadressert, så en gjentatt opplasting av den
  --    samme filen finner den samme raden framfor å lage en til.
  v_sha := knowledge.source_document_fingerprint(v_bytes);
  select d.id into v_document_id
  from knowledge.source_documents d
  where d.sha256 = v_sha;

  if v_document_id is null then
    insert into knowledge.source_documents
      (sha256, byte_size, media_type, content, stored_by_actor_id)
    values (v_sha, v_size, 'application/pdf', v_bytes, v_actor_id)
    returning id into v_document_id;
    v_document_created := true;
  end if;

  -- 2. Publikasjonstilhørigheten. Fail-closed: uten et treff blir dette ingen
  --    fulltekstversjon, og transaksjonen tar filen med seg.
  v_binding := knowledge.publication_binding_for(p_source_id, p_extracted_text);
  if v_binding is null then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Fullteksten bærer ingen av kildens registrerte identiteter, og kan derfor ikke vises å være denne publikasjonen.',
      hint = 'Kontrollen leter etter kildens DOI, dens PMID navngitt som en PMID, eller de første 60 tegnene av tittelen — i den uttrukne teksten. Et korrekt fingeravtrykk beviser hvilken fil dette er, ikke hvilken artikkel den er. Registrer kildens DOI eller PMID med api.create_source(...)-flyten, eller last opp riktig fil.';
  end if;

  insert into knowledge.source_document_publications
    (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
  values (
    v_document_id, p_source_id,
    (v_binding ->> 'basis')::knowledge.publication_binding_basis,
    v_binding ->> 'evidence',
    v_actor_id
  )
  on conflict on constraint source_document_publications_pairing_key do nothing;

  -- 3. Lesbarheten, tabellene inkludert.
  v_problem := knowledge.full_text_readability_problem(p_extracted_text);
  if v_problem is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = v_problem,
      hint = 'Kliniske funn krever en fulltekst som faktisk lar seg lese, tabellene inkludert (ANTIDEP_CONSTITUTION.md regel 1). En representasjon som ikke oppfyller det, registreres ikke — en manglende kontroll kan ikke kalles verifisert.';
  end if;

  -- Kildeversjonen. Idempotent: (source_id, content_hash) er unik, så den
  -- samme fullteksten lastet opp igjen finner raden framfor å kollidere. Det er
  -- forskjellen på en jobb som kan gjenopptas og en som må ryddes etter.
  v_content_hash := knowledge.source_version_content_hash(p_extracted_text);
  select sv.id into v_source_version_id
  from knowledge.source_versions sv
  where sv.source_id = p_source_id and sv.content_hash = v_content_hash;

  if v_source_version_id is null then
    v_source_version_id := knowledge.record_source_version(
      p_source_id,
      p_retrieved_at,
      p_retrieved_from,
      p_extracted_text,
      p_external_version,
      null,
      'full_text',
      v_actor_id,
      v_sha,
      v_size,
      'application/pdf',
      p_text_extraction_tool,
      p_text_extraction_tool_version,
      p_text_extraction_arguments,
      p_text_extraction_transform
    );
    v_version_created := true;
  elsif exists (
    select 1
    from knowledge.source_versions sv
    where sv.id = v_source_version_id and sv.document_sha256 is distinct from v_sha
  ) then
    -- Den samme teksten registrert fra et annet dokument er ikke den samme
    -- representasjonen, og en stille gjenbruk ville knyttet et nytt
    -- originaldokument til en rad som sier at det var et annet.
    raise exception using
      errcode = 'restrict_violation',
      message = 'Den uttrukne teksten er allerede registrert for denne kilden, men fra et annet originaldokument.',
      hint = 'En kildeversjon er teksten *og* dokumentet den kom av. To forskjellige filer som gir samme tekst, er to representasjoner, og bare den registrerte er den kildeversjonen bærer.';
  end if;

  v_metrics := knowledge.full_text_readability_metrics(p_extracted_text);
  insert into knowledge.full_text_readability_checks (
    source_version_id, source_document_id,
    character_count, letter_count, line_count, table_row_count, table_declaration_count
  )
  values (
    v_source_version_id, v_document_id,
    (v_metrics ->> 'character_count')::bigint,
    (v_metrics ->> 'letter_count')::bigint,
    (v_metrics ->> 'line_count')::bigint,
    (v_metrics ->> 'table_rows')::bigint,
    (v_metrics ->> 'table_declarations')::bigint
  )
  on conflict on constraint full_text_readability_checks_source_version_key do nothing;

  return jsonb_build_object(
    'source_document_id', v_document_id,
    'document_sha256', v_sha,
    'document_byte_size', v_size,
    'document_stored', v_document_created,
    'source_version_id', v_source_version_id,
    'source_version_created', v_version_created,
    'content_hash', v_content_hash,
    'publication_binding', v_binding,
    'readability', v_metrics
  );
end;
$$;

comment on function api.upload_full_text_document(
  uuid, timestamptz, text, text, text, text, text, text, text, text
) is
  'Den kontrollerte veien inn i det private fulltekstbiblioteket (ANTIDEP_CONSTITUTION.md regel 1, 2, 4). Én transaksjon gjør fire ting, og alle fire er databasens: filen legges i knowledge.source_documents med sha256 beregnet av bytene, publikasjonstilhørigheten kontrolleres mot kildens registrerte DOI, PMID eller tittel (knowledge.publication_binding_for(uuid, text)), fullteksten prøves mot lesbarhetskravene inkludert tabellkontrollen (knowledge.full_text_readability_problem(text)), og kildeversjonen registreres som full_text gjennom knowledge.record_source_version(uuid, timestamptz, text, text, text, text, text, uuid, text, bigint, text, text, text, text, text). Feiler én av dem, blir ingenting stående — heller ikke filen. Verken fingeravtrykk, størrelse, mediatype eller representasjon er parametre: alle avleses av dokumentet selv eller er fastsatt av veien, slik at ingen av dem er en påstand kalleren skriver om seg selv. Kallet er idempotent: den samme filen finner sin egen rad på fingeravtrykket, og den samme teksten finner sin egen kildeversjon på (source_id, content_hash), slik at en avbrutt jobb kan gjenopptas uten å rydde. Oppskriften er låst til pdftotext med -bbox-layout -enc UTF-8 -eol unix og antidep-reading-order@2; verktøyversjonen er fri, fordi den er en opplysning og ikke noe som kjøres. Svaret er et jsonb-objekt med filens og kildeversjonens id, om hver av dem ble opprettet nå, bindingsgrunnlaget og lesbarhetsmålingen. SECURITY DEFINER fordi knowledge, workflow og provenance har RLS med default deny; tomt search_path, og kalleren valideres på funksjonens eget kall (§50).';

revoke execute on function api.upload_full_text_document(
  uuid, timestamptz, text, text, text, text, text, text, text, text
) from public;
grant execute on function api.upload_full_text_document(
  uuid, timestamptz, text, text, text, text, text, text, text, text
) to authenticated;

-- ----------------------------------------------------------------------------
-- 8. Gaten krever nå biblioteket, bindingen og lesbarheten
-- ----------------------------------------------------------------------------
create or replace function knowledge.assert_clinical_full_text(
  p_source_id uuid,
  p_source_version_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v knowledge.source_versions;
  v_status knowledge.source_status;
  v_document_id uuid;
begin
  if p_source_version_id is null then
    raise exception using errcode = '22023', message = 'Kliniske evidensfunn krever en eksplisitt fulltekstversjon.';
  end if;

  select sv.* into v
  from knowledge.source_versions sv
  where sv.id = p_source_version_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'Kildeversjonen finnes ikke.';
  end if;

  select s.source_status into v_status
  from knowledge.sources s
  where s.id = v.source_id;

  if v.source_id <> p_source_id then
    -- Preserve the composite foreign key's error class for a mismatched source.
    raise exception using errcode = '23503', message = 'Kildeversjonen tilhører ikke evidensfunnets kilde.';
  end if;
  if v_status in ('retracted', 'withdrawn') then
    raise exception using errcode = '23001', message = 'En tilbaketrukket kilde kan ikke bære klinisk evidens.';
  end if;
  if v.representation is distinct from 'full_text'::knowledge.source_representation then
    raise exception using errcode = '23001', message = 'Abstract og begrensede representasjoner er bare til kildeoppdagelse; klinisk evidens krever fulltekst.';
  end if;
  if v.document_sha256 is null or v.document_sha256 !~ '^sha256:[0-9a-f]{64}$'
     or v.document_byte_size is null or v.document_byte_size <= 0
     or v.document_media_type is distinct from 'application/pdf'
     or v.content_hash is null or v.content_hash !~ '^sha256:[0-9a-f]{64}$'
     or v.text_extraction_tool is distinct from 'pdftotext'
     or nullif(btrim(v.text_extraction_tool_version), '') is null
     or v.text_extraction_arguments is distinct from '-bbox-layout -enc UTF-8 -eol unix'
     or v.text_extraction_transform is distinct from 'antidep-reading-order@2' then
    raise exception using
      errcode = '23001',
      message = 'Fulltekstversjonen mangler komplett dokumentbinding eller gjeldende tillatt tekstuttrekksoppskrift.';
  end if;

  -- Fra migrasjon 009a: bindingen alene er ikke nok. Originalfilen skal ligge i
  -- biblioteket, slik at en senere jobb kan hente den fram igjen uten lokal
  -- filtransport — og uten den ville «etterprøvbar» hvilt på at noen tilfeldigvis
  -- hadde filen liggende.
  select d.id into v_document_id
  from knowledge.source_documents d
  where d.sha256 = v.document_sha256;

  if v_document_id is null then
    raise exception using
      errcode = '23001',
      message = 'Originaldokumentet ligger ikke i fulltekstbiblioteket.',
      hint = 'Registrer fullteksten med api.upload_full_text_document(...). En kildeversjon som viser til en fil ingen kan hente fram igjen, er ikke etterprøvbar for en tredjepart.';
  end if;

  if not exists (
    select 1
    from knowledge.source_document_publications p
    where p.source_document_id = v_document_id and p.source_id = v.source_id
  ) then
    raise exception using
      errcode = '23001',
      message = 'Originaldokumentet er ikke vist å tilhøre denne publikasjonen.',
      hint = 'Et korrekt fingeravtrykk beviser hvilken fil dette er, ikke hvilken artikkel den er. Bindingen registreres av api.upload_full_text_document(...), som krever at fullteksten bærer kildens DOI, PMID eller tittel.';
  end if;

  if not exists (
    select 1
    from knowledge.full_text_readability_checks c
    where c.source_version_id = v.id
  ) then
    raise exception using
      errcode = '23001',
      message = 'Fulltekstversjonen har ingen bestått lesbarhetskontroll.',
      hint = 'Kontrollen gjøres av api.upload_full_text_document(...) og krever blant annet at tabellene faktisk kom med i tekstuttrekkingen. Fraværet av kontrollraden er dommen: en manglende kontroll kan ikke kalles verifisert (ANTIDEP_CONSTITUTION.md regel 4).';
  end if;
end;
$$;

comment on function knowledge.assert_clinical_full_text(uuid, uuid) is
  'Gaten hvert klinisk evidensfunn må gjennom (ANTIDEP_CONSTITUTION.md regel 1, 2, 4). Krever at kildeversjonen finnes, tilhører evidensfunnets kilde, ikke hører til en tilbaketrukket kilde, er en full_text-representasjon, har komplett dokumentbinding med gjeldende tillatt uttrekksoppskrift — og fra migrasjon 009a at originalfilen ligger i det private fulltekstbiblioteket, at den er vist å tilhøre nettopp denne publikasjonen, og at fullteksten har bestått lesbarhetskontrollen inkludert tabellkontrollen. De tre siste er fail-closed på fravær: en fil ingen kan hente fram igjen, en fil ingen har vist tilhører artikkelen, og en fulltekst ingen har kontrollert, er tre forskjellige mangler og ingen av dem er en usikkerhet kjeden kan bygge videre på.';

revoke execute on function knowledge.assert_clinical_full_text(uuid, uuid)
  from public, anon, authenticated;
