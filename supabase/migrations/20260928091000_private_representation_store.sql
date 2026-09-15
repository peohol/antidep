-- ============================================================================
-- Migrasjon 010b — representasjonen blir liggende, privat, ved siden av
-- kildeversjonen
--
-- Fram til nå har `knowledge.source_versions` båret fingeravtrykket av
-- representasjonen, men ikke teksten. Den ble gjenskapt hver gang av
-- originaldokumentet, med `pdftotext` og Antideps leserekkefølge — en kjøring
-- som krever en maskin med verktøyet installert og filen på disk.
--
-- Det holdt så lenge hvert modell-ledd var en kommando i et terminalvindu. Det
-- holder ikke når oppgaven skal kunne hentes ut fra Antidep-flaten av en
-- fagperson som verken har repoet, filen eller verktøyet: en nettleser kan ikke
-- kjøre `pdftotext`, og en oppgave uten kildeteksten er ingen oppgave.
--
-- ----------------------------------------------------------------------------
-- Hvorfor teksten er databasens og ikke en påstand
--
-- Raden bærer sitt eget fingeravtrykk, beregnet av teksten av databasen, og en
-- trigger krever at det er nøyaktig kildeversjonens registrerte `content_hash`.
-- En tekst som ikke er den registrerte representasjonen, kan derfor ikke legges
-- her — og det som ligger her, ER representasjonen, ikke en kopi som kan ha
-- drevet fra den.
--
-- ----------------------------------------------------------------------------
-- Hvorfor den er like privat som originalfilen
--
-- Innholdet er i praksis hele forskningsartikkelen, ordrett. Antidep har ikke
-- rett til å redistribuere den (`documents/README.md`, EVIDENCE_PIPELINE.md).
-- Tabellen har derfor RLS med default deny, ingen grants, ingen view og ingen
-- plass i Data API-et — nøyaktig som `knowledge.source_documents`. Den eneste
-- veien ut går gjennom en SECURITY DEFINER-funksjon som krever mandat, og
-- teksten forlater aldri databasen uten at et menneske med editor-rolle ba om
-- den.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 1, 2, 7
--   docs/DATABASE_ARCHITECTURE.md §5, §43, §48, §50
--   docs/EVIDENCE_PIPELINE.md
-- ============================================================================

create table knowledge.source_version_texts (
  id uuid primary key default gen_random_uuid(),

  -- Naturlig nøkkel, og derfor unik framfor primærnøkkel: kanoniske objekter har
  -- én databasegenerert uuid som primærnøkkel, og en naturlig nøkkel lagres som
  -- et eget felt med en unik constraint (migrasjon 001, konvensjon 1).
  source_version_id uuid not null
    references knowledge.source_versions (id) on update restrict on delete restrict,

  representation text not null,
  -- Databasens eget fingeravtrykk av teksten over. Gjentas som en regel av
  -- triggeren under, slik at kolonnen ikke kan være en påstand.
  content_hash text not null,

  stored_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint source_version_texts_source_version_key unique (source_version_id),
  constraint source_version_texts_representation_not_blank_check
    check (btrim(representation) <> ''),
  constraint source_version_texts_content_hash_format_check
    check (content_hash ~ '^sha256:[0-9a-f]{64}$')
);

comment on table knowledge.source_version_texts is
  'Representasjonen kildeversjonen er registrert med, ordrett og privat (ANTIDEP_CONSTITUTION.md regel 1, 2). Innholdet er i praksis hele forskningsartikkelen, og tabellen har derfor RLS med default deny, ingen grants og ingen view — som knowledge.source_documents. Fingeravtrykket beregnes av teksten av databasen og må være kildeversjonens registrerte content_hash, så raden kan ikke bære en annen tekst enn den versjonen faktisk er. Finnes fordi en agentoppgave skal kunne hentes ut fra Antidep-flaten: en nettleser kan ikke kjøre pdftotext, og en oppgave uten kildeteksten er ingen oppgave.';
comment on column knowledge.source_version_texts.representation is
  'Teksten ordrett, slik den registrerte oppskriften gjenskapte den av originaldokumentet. Aldri normalisert, aldri beskåret: ethvert tegn som ble endret, ville gitt et annet fingeravtrykk enn det kildeversjonen er registrert med.';
comment on column knowledge.source_version_texts.content_hash is
  'sha256 av representasjonen, beregnet av databasen og kontrollert mot kildeversjonens eget content_hash. En kolonne kalleren kunne oppgitt, ville vært en påstand om seg selv.';

alter table knowledge.source_version_texts enable row level security;

create trigger source_version_texts_set_row_timestamps
  before insert or update on knowledge.source_version_texts
  for each row execute function catalog.set_row_timestamps();

-- Fingeravtrykket beregnes, og det må være kildeversjonens.
--
-- To regler i én trigger, fordi de er den samme regelen sett fra hver sin side:
-- teksten skal være den registrerte representasjonen, og raden skal ikke kunne
-- påstå noe annet om seg selv.
create function knowledge.bind_source_version_text()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_registered text;
begin
  new.content_hash := knowledge.source_version_content_hash(new.representation);

  select sv.content_hash into v_registered
  from knowledge.source_versions sv
  where sv.id = new.source_version_id;

  if v_registered is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kildeversjonen har ingen registrert content_hash, og representasjonen kan derfor ikke bindes til den.',
      hint = 'Et sporet besøk uten fingeravtrykk er ikke en etterprøvbar representasjon (ANTIDEP_CONSTITUTION.md regel 2).';
  end if;

  if new.content_hash <> v_registered then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Teksten har fingeravtrykket %L, mens kildeversjonen er registrert med %L.',
        new.content_hash, v_registered
      ),
      hint = 'Representasjonen som lagres, skal være nøyaktig den kildeversjonen er registrert med. En annen tekst ville gjort at agentoppgaven ble bygget av noe annet enn det ekstraksjonen kommer til å peke på (ANTIDEP_CONSTITUTION.md regel 2).';
  end if;

  return new;
end;
$$;

comment on function knowledge.bind_source_version_text() is
  'Beregner fingeravtrykket av representasjonen og krever at det er kildeversjonens registrerte content_hash (ANTIDEP_CONSTITUTION.md regel 2). Uten regelen kunne raden båret en annen tekst enn versjonen faktisk er, og en agentoppgave bygget av den ville vært lest ut av noe annet enn det ekstraksjonen kommer til å peke på.';

revoke execute on function knowledge.bind_source_version_text() from public;

create trigger source_version_texts_bind_content_hash
  before insert or update on knowledge.source_version_texts
  for each row execute function knowledge.bind_source_version_text();

create trigger source_version_texts_are_append_only
  before update or delete on knowledge.source_version_texts
  for each row execute function knowledge.reject_append_only_mutation(
    'Representasjonen er det kildeversjonens fingeravtrykk ble beregnet av. En endret eller slettet tekst ville gjort hvert utdrag som er forankret i den, uetterprøvbart.'
  );

-- ----------------------------------------------------------------------------
-- Innskrivingen, uten autorisasjon
--
-- Kalleren har allerede avgjort hvem aktøren er. Idempotent: den samme teksten
-- lagt inn igjen er den samme raden, og en avbrutt opplasting kan derfor kjøres
-- om igjen uten å rydde.
-- ----------------------------------------------------------------------------
create function knowledge.record_source_version_text(
  p_source_version_id uuid,
  p_representation text,
  p_actor_id uuid
)
  returns void
  language plpgsql
  set search_path = ''
as $$
begin
  insert into knowledge.source_version_texts (
    source_version_id, representation, stored_by_actor_id
  )
  values (p_source_version_id, p_representation, p_actor_id)
  on conflict on constraint source_version_texts_source_version_key do nothing;
end;
$$;

comment on function knowledge.record_source_version_text(uuid, text, uuid) is
  'Legger representasjonen ved kildeversjonen, uten autorisasjon: kalleren har allerede avgjort hvem aktøren er. Idempotent — den samme teksten lagt inn igjen er den samme raden — slik at en avbrutt opplasting kan kjøres om igjen uten å rydde. Triggeren på tabellen beregner fingeravtrykket og krever at det er kildeversjonens registrerte.';

revoke execute on function knowledge.record_source_version_text(uuid, text, uuid) from public;

-- ----------------------------------------------------------------------------
-- Leseveien, internt
--
-- Ingen api-funksjon leser denne tabellen direkte. Teksten forlater databasen
-- bare som en del av en agentoppgave, gjennom api.agent_task_payload(...), som
-- krever mandat (migrasjon 010c).
-- ----------------------------------------------------------------------------
create function knowledge.source_version_text(p_source_version_id uuid)
  returns text
  language sql
  stable
  set search_path = ''
as $$
  select t.representation
  from knowledge.source_version_texts t
  where t.source_version_id = p_source_version_id;
$$;

comment on function knowledge.source_version_text(uuid) is
  'Representasjonen kildeversjonen er registrert med, eller NULL når den ikke er lagret. NULL er en reell tilstand: kildeversjoner registrert før migrasjon 010b har ingen lagret tekst, og en agentoppgave for en slik versjon kan ikke bygges. Det er riktig utfall — alternativet ville vært en oppgave uten kildetekst.';

revoke execute on function knowledge.source_version_text(uuid) from public;

-- ----------------------------------------------------------------------------
-- Opplastingen lagrer representasjonen i den samme transaksjonen
--
-- Signaturen er uendret, så `create or replace`: da står grantene, og
-- PostgREST får ingen overload å velge mellom. Kroppen er den samme som i
-- migrasjon 009a, med ett tillegg — kallet til
-- knowledge.record_source_version_text(...) rett før svaret bygges.
-- ----------------------------------------------------------------------------
create or replace function api.upload_full_text_document(
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

  -- Representasjonen blir liggende privat ved siden av kildeversjonen
  -- (migrasjon 010b). Den ligger her og ikke i en egen kommando fordi en
  -- kildeversjon uten sin egen tekst ikke kan bære en agentoppgave, og en
  -- andre kommando er et sted å glemme.
  perform knowledge.record_source_version_text(v_source_version_id, p_extracted_text, v_actor_id);

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
