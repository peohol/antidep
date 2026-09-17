-- ============================================================================
-- Migrasjon 013h — fra valgt kilde til materiale i hus
--
-- Søkeloggen sier hvilke kilder som er valgt. Denne migrasjonen fører dem
-- videre av seg selv, innen den godkjente arbeidsflyten, og uten et
-- godkjenningsklikk per artikkel:
--
--   1. kilden finnes eller opprettes fra kandidatens egen identifikator,
--   2. det private kildebiblioteket spørres først,
--   3. finnes materialet, går arbeidet videre i det samme kallet,
--   4. finnes det ikke, blir det én samlet forespørsel med artikkelidentitet og
--      faglig grunn — og ingen tekniske felter.
--
-- ----------------------------------------------------------------------------
-- Hvorfor to innhentingsveier og ikke én
--
-- Fordi kontraktene er forskjellige. Et forskningsfunn krever fulltekst med
-- etterprøvbar dokumentbinding, og den veien står urørt: den samme PDF-en, det
-- samme fingeravtrykket, den samme tekstuttrekksoppskriften, den samme
-- lesbarhetskontrollen. En regulatorisk opplysning eller en norsk preparatdata
-- kommer derimot som en myndighetsside eller et strukturert datasett, og å
-- presse den inn i en kontrakt som bare passer numeriske forskningsfunn ville
-- enten krevd en PDF som ikke finnes, eller merket et sammendrag som fulltekst.
--
-- `knowledge.authority_documents` er den andre kontrakten: originalfilen med
-- sitt eget fingeravtrykk, sin egen størrelsesgrense og sin egen
-- medietypeliste — og uttrykkelig ikke PDF, slik at den eksisterende
-- PDF-veien blir værende den ene veien for en PDF.
--
-- Et myndighetsdokument gir ingen GRADE-vurdering og ingen evidensrad. Det
-- bærer et ordrett utdrag med en lokalisering og et tidspunkt, og kontrollen er
-- kilde- og aktualitetskontroll. Forskningsporten står igjen der den sto:
-- `knowledge.assert_clinical_full_text(uuid, uuid)` krever fortsatt hele
-- PDF-oppskriften, så et myndighetsdokument kan ikke bære et klinisk
-- evidensfunn — heller ikke når det er registrert som komplett fulltekst.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en betalingsmur ikke stopper arbeidet
--
-- Fordi den er en tilgangsbegrensning og ikke en faglig eksklusjonsgrunn
-- (SOURCE_POLICY.md §5). Kandidaten blir stående som valgt, behovet får
-- tilstanden `awaiting_access`, og forespørselen til et menneske sier hvilken
-- artikkel det gjelder og hvorfor den trengs faglig.
--
-- Styrende dokumenter: docs/SOURCE_POLICY.md §1, §4.3, §5, §7,
-- docs/MONOGRAPH_STANDARD.md §2, docs/EVIDENCE_PIPELINE.md,
-- docs/PRODUCT_INFORMATION_ARCHITECTURE.md, docs/ANTIDEP_CONSTITUTION.md
-- regel 1, 2, 4.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Formen på de nye identifikatorene
--
-- Et system uten en form ville godtatt hva som helst, og da ville identiteten
-- ikke vært en identitet.
-- ----------------------------------------------------------------------------

alter table knowledge.source_identifiers
  add constraint source_identifiers_pmcid_format_check
    check (identifier_system <> 'pmcid' or identifier_value ~ '^PMC[0-9]{1,9}$'),
  add constraint source_identifiers_url_format_check
    check (identifier_system <> 'url'
           or (identifier_value ~ '^https://[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/|$)'
               and identifier_value !~ '\s')),
  add constraint source_identifiers_registry_id_format_check
    check (identifier_system <> 'registry_id'
           or identifier_value ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{2,99}$');

comment on constraint source_identifiers_url_format_check on knowledge.source_identifiers is
  'En adresse som identifiserer en kilde, skal være en hel https-adresse med et vertsnavn. Kravet er identitetens og ikke innhentingens: en adresse uten vertsnavn kunne pekt på hva som helst, og en http-adresse ville gjort identiteten avhengig av et ledd som kan endres underveis.';

-- ----------------------------------------------------------------------------
-- 2. Ett navn på subjektet, også i innleggingsveien
--
-- `api.enqueue_agent_task(text, jsonb)` hadde sin egen kopi av hvordan
-- subjektet og oppgavenøkkelen regnes ut. To kopier av den samme regelen er én
-- for mange: fra migrasjon 013g bærer synteseoppgavens subjekt
-- kunnskapsbehovet, og kopien her ville regnet ut et annet navn enn det
--  kjeden og duplikatoppslaget bruker. Da ville den samme oppgaven kunnet
-- legges inn to ganger.
-- ----------------------------------------------------------------------------

create or replace function api.enqueue_agent_task(
  p_agent_role text,
  p_input_manifest jsonb)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_role provenance.agent_role;
  v_subject text;
  v_job_key text;
  v_result jsonb;
  v_job workflow.pipeline_jobs;
  v_problem text;
begin
  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role);
  end;

  if workflow.agent_task_contract(v_role) is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Rollen %L kan ikke settes ut til en ekstern KI-agent.', p_agent_role),
      hint = 'De uavhengige kontrolleddene er Antideps egen deterministiske kode. En ekstern modell som fikk utføre dem, ville gjort kontrollen til nok en modellvurdering (ANTIDEP_CONSTITUTION.md regel 3).';
  end if;

  if p_input_manifest is null or jsonb_typeof(p_input_manifest) <> 'object' then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Inndatamanifestet må være et JSON-objekt.';
  end if;

  -- Subjektet og nøkkelen leses fra det ene stedet som eier dem. Kjeden,
  -- duplikatoppslaget og denne veien skal aldri kunne bli uenige om hva en
  -- oppgave handler om (migrasjon 013g).
  v_subject := workflow.agent_task_manifest_subject(v_role, p_input_manifest);

  -- Den samme låsen kjedeovergangene tar, på nøyaktig det samme subjektet
  -- (migrasjon 012b). Den avviser ingenting: den gjør bare at en overgang som
  -- spør «har subjektet en oppgave», ikke kan få svaret sitt fra et øyeblikk
  -- denne innleggingen allerede har forlatt. Låsen slippes når transaksjonen er
  -- over, og en kaller uten mandat holder den bare til avvisningen under.
  perform workflow.lock_chain_subject(v_role, v_subject);

  v_job_key := workflow.agent_task_job_key(v_role, p_input_manifest);

  v_result := api.enqueue_pipeline_job(p_agent_role, v_job_key, p_input_manifest);

  select j.* into v_job
  from workflow.pipeline_jobs j
  where j.id = (v_result ->> 'pipeline_job_id')::uuid;

  -- Utførelsesmåten settes i det samme kallet som oppretter jobben, og aldri
  -- etterpå. Fikk vi tilbake en jobb som allerede fantes, må den ha vært en
  -- handoff-jobb fra før: en intern pipelinejobb som ble omdøpt til en ekstern
  -- oppgave i ettertid, ville kunnet stå midt i en kjøring.
  if (v_result ->> 'enqueued')::boolean then
    insert into workflow.agent_handoff_jobs (pipeline_job_id, registered_by_actor_id)
    values (v_job.id, v_job.enqueued_by_actor_id);
  elsif not exists (
    select 1 from workflow.agent_handoff_jobs h where h.pipeline_job_id = v_job.id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Jobben %L finnes allerede for rollen %L som en intern pipelinejobb.', v_job_key, p_agent_role),
      hint = 'Utførelsesmåten avgjøres når jobben legges inn. En intern jobb som ble gjort om til en ekstern agentoppgave i ettertid, kunne stått midt i en kjøring — og det samme arbeidet ville blitt gjort to ganger.';
  end if;

  -- Bare grunnlaget. At ingen KI-tjeneste er valgt for leddet ennå, er ikke en
  -- grunn til å nekte å legge inn oppgaven — det er noe køen ber om, og valget
  -- hører hjemme der og ikke i en innlegging.
  v_problem := workflow.agent_task_input_problem(v_job);
  if v_problem is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = v_problem,
      hint = 'En oppgave som ikke kan bygges, skal ikke legges i køen: den ville stått der som noe som ventet på et menneske, uten å kunne utføres (ANTIDEP_CONSTITUTION.md regel 4).';
  end if;

  return v_result || jsonb_build_object('job_key', v_job_key);
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. Hva slags materiale et kunnskapsbehov trenger
--
-- Svarformen avgjør det, fordi svarformen er standardens eget ord for hva
-- svaret er (MONOGRAPH_STANDARD.md §2). Et estimat, en profil og en
-- sammenfatning hviler på forskning; et faktum, en tabell, et råd og en
-- relasjon hviler på et myndighets-, preparat- eller retningslinjedokument; et
-- avledet svar hviler på andre svar og trenger ingen ny kilde.
-- ----------------------------------------------------------------------------

create type knowledge.monograph_material_kind as enum (
  'research_full_text',
  'authority_document',
  'derived'
);

revoke usage on type knowledge.monograph_material_kind from public;

comment on type knowledge.monograph_material_kind is
  'Hva slags originalmateriale et kunnskapsbehov trenger: research_full_text (forskningsfulltekst gjennom den eksisterende PDF-veien, med ekstraksjon, kontroll og syntese), authority_document (et myndighets-, preparat- eller retningslinjedokument som bærer et ordrett utdrag med lokalisering og tidspunkt, og som får kilde- og aktualitetskontroll framfor en GRADE-vurdering) eller derived (sammensatt av andre kontrollerte svar, uten ny kilde).';

create function knowledge.monograph_need_material_kind(p_need_id uuid)
  returns knowledge.monograph_material_kind
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_form knowledge.monograph_answer_form;
  v_kind knowledge.monograph_material_kind;
begin
  select n.answer_form into v_form
  from knowledge.monograph_needs n
  where n.id = p_need_id;

  if not found then
    return null;
  end if;

  v_kind := case v_form
    when 'estimate' then 'research_full_text'
    when 'profile' then 'research_full_text'
    when 'summary' then 'research_full_text'
    when 'fact' then 'authority_document'
    when 'table' then 'authority_document'
    when 'advice' then 'authority_document'
    when 'relation' then 'authority_document'
    when 'directed_relation' then 'authority_document'
    when 'derived' then 'derived'
  end::knowledge.monograph_material_kind;

  -- Uttømmende med vilje. En ny svarform skal stoppe innhentingen med en
  -- setning om hva som mangler, framfor å havne stille i den ene veien og få
  -- en kontrakt ingen har bestemt at den skal ha.
  if v_kind is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Svarformen %L har ingen innhentingsvei.', v_form),
      hint = 'Hver svarform må si hva slags originalmateriale svaret hviler på, ellers ville materialet blitt hentet gjennom en kontrakt som ikke passer det.';
  end if;

  return v_kind;
end;
$$;

comment on function knowledge.monograph_need_material_kind(uuid) is
  'Hva slags originalmateriale ett kunnskapsbehov trenger, utledet av svarformen standarden gir malen. Finnes fordi innhentingen ellers måtte gjette: en preparatstyrke og et klinisk estimat kommer fra helt forskjellige dokumenter med helt forskjellige kontrollkrav, og én felles vei ville enten krevd en PDF som ikke finnes, eller merket et sammendrag som fulltekst.';

revoke execute on function knowledge.monograph_need_material_kind(uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Arbeidstilstanden, gjennom én skrivevei
--
-- Tilstanden er ikke et faglig utfall. «Mangler tilgang», «venter på en
-- avklaring» og «teknisk stopp» er tre forskjellige ting, og ingen av dem er
-- «ingen relevante studier» (MONOGRAPH_STANDARD.md §2, ANTIDEP_CONSTITUTION.md
-- regel 4).
-- ----------------------------------------------------------------------------

create function knowledge.set_monograph_need_work_state(
  p_need_id uuid,
  p_work_state knowledge.monograph_work_state,
  p_note text,
  p_outcome knowledge.monograph_outcome,
  p_actor_id uuid,
  p_agent_run_id uuid)
  returns boolean
  language plpgsql
  set search_path = ''
as $$
declare
  v_before knowledge.monograph_needs;
begin
  select n.* into v_before
  from knowledge.monograph_needs n
  where n.id = p_need_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kunnskapsbehovet finnes ikke.';
  end if;

  if p_work_state = 'agent_complete' and p_outcome is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et ferdig behandlet behov må ha et faglig utfall.',
      hint = 'Utfallet er konklusjonen. Uten den ville «ferdig» betydd at ingen vet hva svaret ble.';
  end if;

  if p_work_state <> 'agent_complete' and p_outcome is not null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Et behov som ikke er ferdig behandlet, har ikke noe faglig utfall.',
      hint = 'Manglende tilgang, en ubesvart avklaring og en teknisk svikt er arbeidstilstander, ikke konklusjoner om evidensen (ANTIDEP_CONSTITUTION.md regel 4).';
  end if;

  if v_before.work_state = p_work_state
     and v_before.outcome is not distinct from p_outcome then
    return false;
  end if;

  update knowledge.monograph_needs n
  set work_state = p_work_state,
      work_state_note = nullif(btrim(coalesce(p_note, '')), ''),
      outcome = p_outcome
  where n.id = p_need_id;

  -- Ett opphav per hendelse. Er arbeidet gjort av en agentkjøring, er det
  -- kjøringen som er opphavet — aktøren bak den står allerede på kjøringen, og
  -- to opphav på den samme raden ville sagt at to forskjellige gjorde det.
  perform workflow.record_monograph_need_event(
    p_need_id, v_before, p_note,
    case when p_agent_run_id is null then p_actor_id end,
    p_agent_run_id);

  return true;
end;
$$;

comment on function knowledge.set_monograph_need_work_state(uuid, knowledge.monograph_work_state, text, knowledge.monograph_outcome, uuid, uuid) is
  'Setter arbeidstilstanden på ett kunnskapsbehov, og fører endringen i behovets eget spor. Den ene skriveveien finnes fordi tilstanden og det faglige utfallet må holdes atskilt: et behov som mangler tilgang eller står på en avklaring, er ikke et behov uten relevante studier, og bare et ferdig behandlet behov har en konklusjon. Idempotent: den samme tilstanden satt om igjen skriver ingenting.';

revoke execute on function knowledge.set_monograph_need_work_state(uuid, knowledge.monograph_work_state, text, knowledge.monograph_outcome, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 5. Myndighetsdokumentet, med sin egen integritetskontrakt
--
-- Originalfilen, fingeravtrykket og medietypen — for et dokument som ikke er en
-- PDF. Uttrykkelig ikke PDF: den eksisterende `knowledge.source_documents` er
-- og blir den ene veien for en PDF, med sin egen signaturkontroll og sin egen
-- lesbarhetskontroll. To veier for den samme filtypen ville svekket den ene.
-- ----------------------------------------------------------------------------

create table knowledge.authority_documents (
  id uuid primary key default gen_random_uuid(),

  -- Én fil per kildeversjon. Versjonen er det som dateres, siteres og
  -- kontrolleres, så filen hører til nøyaktig den.
  source_version_id uuid not null
    references knowledge.source_versions (id) on update restrict on delete restrict,

  sha256 text not null,
  byte_size bigint not null,
  media_type text not null,
  content bytea not null,

  -- Hvor filen faktisk ble hentet fra, og når. Aktualitetskontrollen leser
  -- dette: en myndighetsopplysning uten et tidspunkt er ikke etterprøvbar.
  retrieved_from text not null,
  retrieved_at timestamptz not null,

  -- Oppskriften teksten ble hentet ut av filen med. Står her og ikke på
  -- kildeversjonen fordi kildeversjonens oppskriftsfelter er PDF-veiens: de
  -- er låst til pdftotext med nøyaktig de argumentene, og en HTML-oppskrift
  -- der ville svekket nettopp den låsen.
  text_extraction_recipe text not null,

  stored_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  created_at timestamptz not null default now(),

  constraint authority_documents_version_key unique (source_version_id),
  constraint authority_documents_sha256_format_check
    check (sha256 ~ '^sha256:[0-9a-f]{64}$'),
  constraint authority_documents_sha256_is_the_content_check
    check (sha256 = knowledge.source_document_fingerprint(content)),
  constraint authority_documents_byte_size_check
    check (byte_size > 0 and byte_size = octet_length(content)),
  -- 16 MB. En myndighetsside eller et strukturert datasett er langt under; en
  -- ubegrenset nedlasting er en driftsrisiko og ikke en kilde.
  constraint authority_documents_byte_size_limit_check
    check (byte_size <= 16777216),
  -- Medietypelisten er uttømmende, og PDF står bevisst ikke i den.
  constraint authority_documents_media_type_check
    check (media_type in ('text/html', 'application/xhtml+xml',
                          'application/xml', 'application/json')),
  constraint authority_documents_retrieved_from_shape_check
    check (retrieved_from ~ '^https://[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/|$|\?)'
           and retrieved_from !~ '\s'
           and length(retrieved_from) between 12 and 2000),
  constraint authority_documents_retrieved_at_not_future_check
    check (retrieved_at <= created_at),
  -- Uttømmende liste. En oppskrift ingen har bestemt seg for, gjør teksten
  -- uetterprøvbar: to forskjellige uttrekk av den samme filen kan gi to
  -- forskjellige utdrag, og da er et ordrett sitat ikke ordrett.
  constraint authority_documents_recipe_allowlist_check
    check (text_extraction_recipe in ('antidep-html-text@1',
                                       'antidep-xml-text@1',
                                       'antidep-json-values@1'))
);

comment on table knowledge.authority_documents is
  'Originalfilen til et myndighets-, preparat- eller retningslinjedokument, med sitt eget fingeravtrykk, sin egen størrelsesgrense og sin egen medietypeliste. Finnes fordi en regulatorisk opplysning kommer som en side eller et strukturert datasett og ikke som en forskningsartikkel: å presse den inn i PDF-kontrakten ville krevd en PDF som ikke finnes, eller merket et sammendrag som fulltekst. PDF står uttrykkelig ikke i medietypelisten — knowledge.source_documents er og blir den ene veien for en PDF, med sin signaturkontroll og sin lesbarhetskontroll, og to veier for den samme filtypen ville svekket den ene (SOURCE_POLICY.md §5).';
comment on column knowledge.authority_documents.text_extraction_recipe is
  'Oppskriften den registrerte teksten ble hentet ut av filen med. Står på originalfilen og ikke på kildeversjonen fordi kildeversjonens oppskriftsfelter er PDF-veiens og er låst til pdftotext med nøyaktig de argumentene; en HTML-oppskrift der ville svekket nettopp den låsen. Listen er uttømmende: to forskjellige uttrekk av den samme filen kan gi to forskjellige utdrag, og da er et ordrett sitat ikke ordrett.';
comment on column knowledge.authority_documents.retrieved_at is
  'Når filen faktisk ble hentet. Aktualitetskontrollen leser dette: en myndighetsopplysning uten et tidspunkt kan ikke etterprøves, og «gjelder i dag» er ikke en egenskap ved teksten.';

alter table knowledge.authority_documents enable row level security;

create trigger authority_documents_set_created_at
  before insert or update on knowledge.authority_documents
  for each row execute function catalog.set_created_at();

create trigger authority_documents_are_append_only
  before update or delete on knowledge.authority_documents
  for each row execute function knowledge.reject_append_only_mutation(
    'En registrert originalfil er identiteten til alt som er utledet av den. Registrer den korrigerte filen som en ny kildeversjon; den får sitt eget fingeravtrykk, fordi den er et annet dokument.');

-- ----------------------------------------------------------------------------
-- 6. Forespørselen om et myndighetsdokument
--
-- Den forskningsfaglige forespørselen (workflow.full_text_requests) bærer
-- avgrensningen som virkestoff, endepunkt og populasjon, fordi det er det
-- ekstraksjonsoppgaven bygges av. Et myndighetsdokument har ingen endepunkt,
-- og en tvungen endepunktliste her ville vært et oppdiktet forskningsspørsmål.
-- Avgrensningen er behovene selv, og de leses av kandidatens egne rader.
-- ----------------------------------------------------------------------------

create type workflow.monograph_document_request_state as enum (
  'open', 'fulfilled', 'withdrawn'
);

revoke usage on type workflow.monograph_document_request_state from public;

comment on type workflow.monograph_document_request_state is
  'Tilstanden til en forespørsel om et myndighets-, preparat- eller retningslinjedokument: open (Antidep venter på dokumentet), fulfilled (dokumentet er registrert som en kildeversjon) eller withdrawn (forespørselen er trukket tilbake med en begrunnelse). En trukket forespørsel er ikke et faglig utfall.';

create table workflow.monograph_document_requests (
  id uuid primary key default gen_random_uuid(),
  reference text not null default workflow.new_public_reference(),

  edition_id uuid not null
    references knowledge.monograph_editions (id) on update restrict on delete restrict,
  source_id uuid not null
    references knowledge.sources (id) on update restrict on delete restrict,

  -- Hvilken representasjon dokumentet må registreres som. Står på
  -- forespørselen fordi den er kontrakten: en side som viser et sammendrag,
  -- oppfyller ikke en forespørsel om det komplette dokumentet.
  required_representation knowledge.source_representation not null,
  -- Den faglige grunnen, slik et menneske kan lese den uten å kjenne systemet.
  professional_reason text not null,
  -- Adressen dokumentet hentes fra, når den er kjent.
  retrieved_from text,

  state workflow.monograph_document_request_state not null default 'open',
  requested_by_actor_id uuid not null
    references provenance.actors (id) on update restrict on delete restrict,
  requested_at timestamptz not null default now(),
  fulfilled_source_version_id uuid
    references knowledge.source_versions (id) on update restrict on delete restrict,
  closed_at timestamptz,
  closed_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint monograph_document_requests_reference_key unique (reference),
  constraint monograph_document_requests_reference_shape_check
    check (reference ~ '^[0-9a-f]{32}$'),
  constraint monograph_document_requests_reason_shape_check
    check (professional_reason = btrim(professional_reason)
           and length(professional_reason) between 1 and 4000),
  constraint monograph_document_requests_retrieved_from_shape_check
    check (retrieved_from is null
           or (retrieved_from = btrim(retrieved_from)
               and length(retrieved_from) between 1 and 2000)),
  constraint monograph_document_requests_closed_reason_shape_check
    check (closed_reason is null
           or (closed_reason = btrim(closed_reason)
               and length(closed_reason) between 1 and 1000)),
  constraint monograph_document_requests_representation_check
    check (required_representation in ('full_text', 'regulatory_summary',
                                       'registry_record', 'secondary_report')),
  constraint monograph_document_requests_state_shape_check
    check (case state
             when 'open' then
               fulfilled_source_version_id is null and closed_at is null
             when 'fulfilled' then
               fulfilled_source_version_id is not null and closed_at is not null
             when 'withdrawn' then
               fulfilled_source_version_id is null and closed_at is not null
               and closed_reason is not null
             else false
           end)
);

comment on table workflow.monograph_document_requests is
  'Én åpen forespørsel om det originalmaterialet en regulatorisk opplysning, en preparatdata eller et attribuert retningslinjeråd hviler på. Atskilt fra workflow.full_text_requests fordi kontraktene er forskjellige: den forskningsfaglige forespørselen bærer virkestoff, endepunkt og populasjon, og en tvungen endepunktliste for en preparatstyrke ville vært et oppdiktet forskningsspørsmål. Avgrensningen her er kunnskapsbehovene selv, lest av kandidatens egne rader — så den står ikke lagret to steder.';
comment on column workflow.monograph_document_requests.required_representation is
  'Representasjonen dokumentet må registreres som. Står på forespørselen fordi den er kontrakten: en side som viser et sammendrag, oppfyller ikke en forespørsel om det komplette dokumentet, og et sammendrag skal ikke kunne merkes som fulltekst for å passere en kontroll (SOURCE_POLICY.md §5).';

alter table workflow.monograph_document_requests enable row level security;

create unique index monograph_document_requests_open_source_key
  on workflow.monograph_document_requests (source_id)
  where state = 'open';

comment on index workflow.monograph_document_requests_open_source_key is
  'Én åpen forespørsel per kilde. Det samme dokumentet etterspurt to ganger er én forespørsel, slik at en gjentatt orkestrering ikke dobler den listen et menneske skal arbeide gjennom.';

create index monograph_document_requests_open_idx
  on workflow.monograph_document_requests (requested_at)
  where state = 'open';

create index monograph_document_requests_edition_idx
  on workflow.monograph_document_requests (edition_id, state);

create trigger monograph_document_requests_set_row_timestamps
  before insert or update on workflow.monograph_document_requests
  for each row execute function catalog.set_row_timestamps();

-- ----------------------------------------------------------------------------
-- 7. Kilden, funnet eller opprettet fra kandidatens egen identifikator
--
-- «Bruk eksisterende privat kildebibliotek først» (SOURCE_POLICY.md §5) er
-- bare mulig hvis den samme publikasjonen funnet to ganger blir én kilde. Det
-- er identifikatoren som gjør det, og derfor er det den som bestemmer om
-- kilden finnes.
-- ----------------------------------------------------------------------------

create function workflow.monograph_candidate_identifier_system(p_kind text)
  returns knowledge.source_identifier_system
  language sql
  immutable
  set search_path = ''
as $$
  select case p_kind
    when 'doi' then 'doi'
    when 'pmid' then 'pmid'
    when 'pmcid' then 'pmcid'
    when 'url' then 'url'
    when 'registry_id' then 'registry_id'
  end::knowledge.source_identifier_system;
$$;

comment on function workflow.monograph_candidate_identifier_system(text) is
  'Identifikatorsystemet en kandidatkildes identifikator hører til, eller NULL for «title». En tittel er ikke en identitet: to artikler kan hete det samme, og en kilde opprettet på tittel alene kunne blitt to kilder eller slått sammen to publikasjoner.';

revoke execute on function workflow.monograph_candidate_identifier_system(text) from public;

create function workflow.monograph_normalized_identifier(p_kind text, p_value text)
  returns text
  language sql
  immutable
  set search_path = ''
as $$
  select case p_kind
    -- DOI-er er ikke bokstavstørrelsesfølsomme, og raden lagrer dem med små
    -- bokstaver. «10.1234/ABC» og «10.1234/abc» er den samme artikkelen.
    when 'doi' then regexp_replace(
      lower(btrim(p_value)), '^https?://(dx\.)?doi\.org/', '')
    when 'pmcid' then upper(btrim(p_value))
    else btrim(p_value)
  end;
$$;

comment on function workflow.monograph_normalized_identifier(text, text) is
  'Kandidatens identifikator på den formen identifikatorraden lagrer den. Normaliseringen finnes fordi to skrivemåter av den samme DOI-en ellers ville blitt to kilder, og da ville det private kildebiblioteket ikke funnet igjen noe Antidep alt har.';

revoke execute on function workflow.monograph_normalized_identifier(text, text) from public;

create function workflow.monograph_profile_source_type(p_profile_code text)
  returns knowledge.source_type
  language sql
  immutable
  set search_path = ''
as $$
  select case p_profile_code
    -- Myndighetsdokumentasjon og norske preparatdata.
    when 'REG' then 'regulatory_communication'
    when 'PROD' then 'summary_of_product_characteristics'
    -- Retningslinjer og andre attribuerte anbefalinger.
    when 'SYN' then 'clinical_guideline'
    -- Og ellers forskningslitteratur.
    else 'journal_article'
  end::knowledge.source_type;
$$;

comment on function workflow.monograph_profile_source_type(text) is
  'Kildetypen et treff funnet under en kildeprofil sannsynligvis er: REG gir en regulatorisk melding, PROD en preparatomtale, SYN en retningslinje, og de øvrige profilene forskningslitteratur (SOURCE_POLICY.md §2). Utledet av profilen fordi søket ble kjørt under den: et treff fra et preparatregister er en preparatomtale, og ikke en artikkel.';

revoke execute on function workflow.monograph_profile_source_type(text) from public;

create function workflow.ensure_monograph_candidate_source(p_candidate_id uuid)
  returns uuid
  language plpgsql
  set search_path = ''
as $$
declare
  v_cand workflow.monograph_candidate_sources;
  v_system knowledge.source_identifier_system;
  v_value text;
  v_profile_code text;
  v_source_id uuid;
begin
  select c.* into v_cand
  from workflow.monograph_candidate_sources c
  where c.id = p_candidate_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Kandidatkilden finnes ikke.';
  end if;

  if v_cand.source_id is not null then
    return v_cand.source_id;
  end if;

  v_system := workflow.monograph_candidate_identifier_system(v_cand.identifier_kind);
  if v_system is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kandidaten er bare identifisert med en tittel, og kan ikke registreres som en kilde.',
      hint = 'En tittel er ikke en identitet: to publikasjoner kan hete det samme. Registrer treffets DOI, PMID, PMCID, adresse eller forsøksregisternummer først (SOURCE_POLICY.md §4.3).';
  end if;

  v_value := workflow.monograph_normalized_identifier(
    v_cand.identifier_kind, v_cand.identifier_value);

  select sp.code into v_profile_code
  from workflow.monograph_search_plans p
  join knowledge.monograph_source_profiles sp on sp.id = p.profile_id
  where p.id = v_cand.plan_id;

  -- Låsen gjør «finn eller opprett» til én udelelig handling, og den står på
  -- den normaliserte identifikatoren og ikke på en rad — nettopp fordi raden
  -- ennå ikke finnes. Uten den ville to samtidige innhentinger av den samme
  -- artikkelen begge sett «finnes ikke», og begge opprettet hver sin.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'antidep:kilde-identifikator:' || v_system::text || ':' || v_value, 0));

  select i.source_id into v_source_id
  from knowledge.source_identifiers i
  where i.identifier_system = v_system and i.identifier_value = v_value;

  if v_source_id is null then
    -- Kilden og identifikatoren settes inn i den samme underblokken med vilje:
    -- taper vi kappløpet mot en annen skrivevei, skal *begge* innsettingene
    -- rulles tilbake. Lå kilderaden utenfor, ville taperen etterlatt en
    -- publikasjon uten identifikator — en rad den neste innhentingen ikke
    -- ville funnet igjen.
    begin
      insert into knowledge.sources (
        source_type, title, authors_or_issuer, publisher_or_journal,
        publication_date, publication_date_precision, created_by_actor_id
      )
      values (
        coalesce(workflow.monograph_profile_source_type(v_profile_code),
                 'journal_article'::knowledge.source_type),
        v_cand.title,
        -- Det treffet faktisk oppgav. Taushet er ikke en forfatterliste, og
        -- den står som det den er framfor å bli fylt inn ved gjetning.
        coalesce(nullif(btrim(coalesce(v_cand.authors_or_issuer, '')), ''),
                 nullif(btrim(coalesce(v_cand.publisher_or_journal, '')), ''),
                 'ikke oppgitt i søketreffet'),
        v_cand.publisher_or_journal,
        case when v_cand.publication_year is null then null
             else make_date(v_cand.publication_year, 1, 1) end,
        case when v_cand.publication_year is null then null
             else 'year'::knowledge.date_precision end,
        v_cand.recorded_by_actor_id
      )
      returning id into v_source_id;

      insert into knowledge.source_identifiers
        (source_id, identifier_system, identifier_value)
      values (v_source_id, v_system, v_value);
    exception
      when unique_violation then
        select i.source_id into v_source_id
        from knowledge.source_identifiers i
        where i.identifier_system = v_system and i.identifier_value = v_value;
        if v_source_id is null then
          raise exception using
            errcode = 'restrict_violation',
            message = 'Kilden kunne ikke registreres nå.',
            hint = 'Unikhetskravet på identifikatoren slo til, men raden som vant, fantes ikke da den ble slått opp igjen. Det er en tilstand innhentingen ikke kan tolke, og den stopper framfor å opprette en publikasjon til.';
        end if;
    end;
  end if;

  update workflow.monograph_candidate_sources c
  set source_id = v_source_id
  where c.id = p_candidate_id;

  return v_source_id;
end;
$$;

comment on function workflow.ensure_monograph_candidate_source(uuid) is
  'Kilderaden en valgt kandidat peker på: den som allerede bærer identifikatoren, eller en ny. Finnes fordi «bruk det private kildebiblioteket først» bare er mulig når den samme publikasjonen funnet to ganger blir én kilde. En kandidat identifisert med tittel alene avvises: to publikasjoner kan hete det samme, og en kilde opprettet på tittel ville enten blitt to kilder eller slått sammen to arbeider.';

revoke execute on function workflow.ensure_monograph_candidate_source(uuid) from public;

-- ----------------------------------------------------------------------------
-- 8. Den godkjente kildebruken, ført opp når materialet finnes
--
-- Godkjenningen ble gitt da kandidaten ble valgt, med en begrunnelse og en
-- navngitt avgjørelse. Raden føres opp her, mot den kildeversjonen som faktisk
-- finnes — fordi en godkjenning uten et dokument ikke er noe å bruke.
-- ----------------------------------------------------------------------------

create function workflow.register_monograph_source_uses(p_source_version_id uuid)
  returns integer
  language plpgsql
  set search_path = ''
as $$
declare
  v_version knowledge.source_versions;
  v_row record;
  v_written integer := 0;
begin
  select sv.* into v_version
  from knowledge.source_versions sv
  where sv.id = p_source_version_id;

  if not found or v_version.representation is null then
    return 0;
  end if;

  for v_row in
    select cn.need_id,
           cn.proposed_use,
           n.scope_digest,
           c.decided_by_actor_id,
           c.decided_by_agent_run_id,
           c.recorded_by_actor_id,
           knowledge.monograph_need_material_kind(cn.need_id) as kind
    from workflow.monograph_candidate_sources c
    join workflow.monograph_candidate_source_needs cn on cn.candidate_source_id = c.id
    join knowledge.monograph_needs n on n.id = cn.need_id
    where c.source_id = v_version.source_id
      and c.decision in ('selected_for_retrieval', 'included')
      and n.relevance <> 'not_applicable'
    order by cn.need_id
  loop
    -- Representasjonen må passe det behovet trenger. Et sammendrag er ikke
    -- forskningsfulltekst, og et forskningsbehov skal ikke få en godkjent bruk
    -- av noe som ikke kan bære funnet (SOURCE_POLICY.md §5).
    if v_row.kind = 'research_full_text'
       and v_version.representation <> 'full_text' then
      continue;
    end if;
    if v_row.kind = 'authority_document'
       and v_version.representation not in ('full_text', 'regulatory_summary',
                                            'registry_record', 'secondary_report') then
      continue;
    end if;
    if v_row.kind = 'derived' then
      continue;
    end if;

    insert into knowledge.monograph_source_uses (
      need_id, source_version_id, approved_use, scope_digest,
      approved_by_actor_id, approved_by_agent_run_id
    )
    values (
      v_row.need_id, p_source_version_id, v_row.proposed_use, v_row.scope_digest,
      case when v_row.decided_by_agent_run_id is null
           then coalesce(v_row.decided_by_actor_id, v_row.recorded_by_actor_id) end,
      v_row.decided_by_agent_run_id
    )
    on conflict on constraint monograph_source_uses_pair_key do nothing;

    if found then
      v_written := v_written + 1;
    end if;
  end loop;

  return v_written;
end;
$$;

comment on function workflow.register_monograph_source_uses(uuid) is
  'Fører opp den godkjente kildebruken for hvert kunnskapsbehov en valgt kandidatkilde er godkjent for, mot den kildeversjonen som faktisk er registrert. Godkjenningen selv ble gitt da kandidaten ble valgt, med begrunnelse og navngitt avgjørelse; dette er stedet den møter et dokument. Representasjonen må passe behovet: et forskningsbehov får ingen godkjent bruk av et sammendrag, fordi et sammendrag ikke kan bære funnet. Idempotent.';

revoke execute on function workflow.register_monograph_source_uses(uuid) from public;

-- ----------------------------------------------------------------------------
-- 9. Forespørselen om forskningsfulltekst, med hele avgrensningen samlet
--
-- Én åpen forespørsel per kilde, og avgrensningen er unionen av de behovene
-- kilden er valgt for. Vokser unionen — fordi et nytt behov ble relevant — må
-- den åpne forespørselen vokse med den. Ellers ville ekstraksjonsoppgaven blitt
-- bygget uten det nye behovet, og arbeidet forsvunnet uten at noen merket det.
-- ----------------------------------------------------------------------------

create function workflow.request_monograph_full_text(
  p_source_id uuid,
  p_actor_id uuid)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_drug_ids uuid[];
  v_outcome_ids uuid[];
  v_population_ids uuid[];
  v_problem text;
  v_retrieved_from text;
  v_existing workflow.full_text_requests;
  v_reference text;
  v_widened boolean := false;
begin
  -- Avgrensningen, samlet over alle valgte kandidatrader for kilden. Behovene
  -- uten et navngitt endepunkt kan ikke bære et forskningsfunn, og de tas
  -- derfor ikke med her; de får sin egen synlige tilstand.
  select workflow.sorted_unique(array_agg(distinct e.drug_id)),
         workflow.sorted_unique(array_agg(distinct n.outcome_concept_id)),
         workflow.sorted_unique(
           array_remove(array_agg(distinct n.population_id), null))
    into v_drug_ids, v_outcome_ids, v_population_ids
  from workflow.monograph_candidate_sources c
  join workflow.monograph_candidate_source_needs cn on cn.candidate_source_id = c.id
  join knowledge.monograph_needs n on n.id = cn.need_id
  join knowledge.monograph_editions e on e.id = n.edition_id
  where c.source_id = p_source_id
    and c.decision in ('selected_for_retrieval', 'included')
    and n.relevance <> 'not_applicable'
    and n.outcome_concept_id is not null
    and knowledge.monograph_need_material_kind(cn.need_id) = 'research_full_text';

  if v_outcome_ids is null or cardinality(v_outcome_ids) = 0 then
    return null;
  end if;

  v_problem := workflow.full_text_request_scope_problem(
    v_drug_ids, v_outcome_ids, coalesce(v_population_ids, array[]::uuid[]));
  if v_problem is not null then
    raise exception using errcode = 'invalid_parameter_value', message = v_problem;
  end if;

  select r.* into v_existing
  from workflow.full_text_requests r
  where r.source_id = p_source_id and r.state = 'open'
  for update;

  if v_existing.id is not null then
    -- En union som har vokst, skrives inn. Den forskningsfaglige forespørselen
    -- avviser ellers en annen avgrensning med vilje, fordi et stille ja der
    -- ville latt arbeidet forsvinne; her er utvidelsen nettopp det som skal
    -- skje, og den er en utvidelse og ikke en omskriving: unionen inneholder
    -- alt den gamle avgrensningen inneholdt.
    if not (v_existing.drug_ids @> v_drug_ids
            and v_existing.outcome_concept_ids @> v_outcome_ids
            and v_existing.population_ids @> coalesce(v_population_ids, array[]::uuid[]))
    then
      update workflow.full_text_requests r
      set drug_ids = workflow.sorted_unique(r.drug_ids || v_drug_ids),
          outcome_concept_ids =
            workflow.sorted_unique(r.outcome_concept_ids || v_outcome_ids),
          population_ids = workflow.sorted_unique(
            r.population_ids || coalesce(v_population_ids, array[]::uuid[]))
      where r.id = v_existing.id;
      v_widened := true;
    end if;

    return jsonb_build_object(
      'reference', v_existing.reference,
      'requested', false,
      'widened', v_widened,
      'state', v_existing.state::text);
  end if;

  v_retrieved_from := workflow.source_retrieval_address(p_source_id);
  if v_retrieved_from is null then
    -- Uten en adresse er det ingen utgiver å hente fra, og en kildeversjon uten
    -- opphav er ikke sporbar. En PMID utledes bevisst ikke: en PubMed-side
    -- viser sammendraget og ikke dokumentet.
    select 'https://doi.org/' || i.identifier_value into v_retrieved_from
    from knowledge.source_identifiers i
    where i.source_id = p_source_id and i.identifier_system = 'doi'
    limit 1;
  end if;
  if v_retrieved_from is null then
    select i.identifier_value into v_retrieved_from
    from knowledge.source_identifiers i
    where i.source_id = p_source_id and i.identifier_system = 'url'
    limit 1;
  end if;
  if v_retrieved_from is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Kilden har ingen registrert adresse, så Antidep kan ikke si hvor fullteksten hentes fra.',
      hint = 'En PMID utledes bevisst ikke: en PubMed-side viser sammendraget og ikke dokumentet. Registrer kildens DOI eller adresse først.';
  end if;

  begin
    insert into workflow.full_text_requests
      (source_id, drug_ids, outcome_concept_ids, population_ids,
       retrieved_from, requested_by_actor_id)
    values
      (p_source_id, v_drug_ids, v_outcome_ids,
       coalesce(v_population_ids, array[]::uuid[]),
       v_retrieved_from, p_actor_id)
    returning reference into v_reference;
  exception
    when unique_violation then
      select r.* into v_existing
      from workflow.full_text_requests r
      where r.source_id = p_source_id and r.state = 'open';
      return jsonb_build_object(
        'reference', v_existing.reference, 'requested', false,
        'widened', false, 'state', v_existing.state::text);
  end;

  return jsonb_build_object(
    'reference', v_reference, 'requested', true, 'widened', false, 'state', 'open');
end;
$$;

comment on function workflow.request_monograph_full_text(uuid, uuid) is
  'Én åpen forespørsel om forskningsfulltekst per kilde, med avgrensningen samlet over alle kunnskapsbehov kilden er valgt for. En union som vokser fordi et nytt behov ble relevant, utvider den åpne forespørselen framfor å bli avvist: ekstraksjonsoppgaven bygges av forespørselens avgrensning, og et nytt behov som ikke kom med, ville forsvunnet uten at noen merket det (SOURCE_POLICY.md §1). Behov uten et navngitt endepunkt tas ikke med — de kan ikke bære et forskningsfunn, og de får sin egen synlige tilstand framfor å bli tiet bort.';

revoke execute on function workflow.request_monograph_full_text(uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 10. Forespørselen om et myndighets-, preparat- eller retningslinjedokument
-- ----------------------------------------------------------------------------

create function workflow.request_monograph_document(
  p_source_id uuid,
  p_edition_id uuid,
  p_actor_id uuid)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_representation knowledge.source_representation;
  v_reason text;
  v_retrieved_from text;
  v_existing workflow.monograph_document_requests;
  v_reference text;
begin
  -- Den faglige grunnen, satt sammen av behovene selv: malens kode, spørsmålet
  -- og hva kilden er foreslått brukt til. Et menneske skal kunne lese den uten
  -- å kjenne systemet, og uten å bli bedt om en teknisk registrering
  -- (SOURCE_POLICY.md §5).
  select string_agg(
           format('%s (%s): %s',
                  t.code,
                  coalesce(knowledge.monograph_need_scope_label(n.id), 'uten avgrensning'),
                  cn.proposed_use),
           E'\n' order by t.code, n.id)
    into v_reason
  from workflow.monograph_candidate_sources c
  join workflow.monograph_candidate_source_needs cn on cn.candidate_source_id = c.id
  join knowledge.monograph_needs n on n.id = cn.need_id
  join knowledge.monograph_question_templates t on t.id = n.template_id
  where c.source_id = p_source_id
    and c.edition_id = p_edition_id
    and c.decision in ('selected_for_retrieval', 'included')
    and n.relevance <> 'not_applicable'
    and knowledge.monograph_need_material_kind(cn.need_id) = 'authority_document';

  if v_reason is null then
    return null;
  end if;

  -- Representasjonen følger kildetypen: en preparatomtale og en regulatorisk
  -- melding *er* sammendrag av myndighetens egen vurdering, og en retningslinje
  -- er et komplett dokument. Å be om «fulltekst» av en preparatomtale ville
  -- vært å be om noe som ikke finnes.
  select case s.source_type
           when 'summary_of_product_characteristics' then 'regulatory_summary'
           when 'regulatory_communication' then 'regulatory_summary'
           when 'public_dataset' then 'registry_record'
           else 'full_text'
         end::knowledge.source_representation
    into v_representation
  from knowledge.sources s
  where s.id = p_source_id;

  select r.* into v_existing
  from workflow.monograph_document_requests r
  where r.source_id = p_source_id and r.state = 'open'
  for update;

  if v_existing.id is not null then
    -- Den samme grunnen står ikke to ganger; en grunn som har vokst, skrives
    -- inn. Forespørselen er den samme, og den er ikke en ny bestilling.
    if v_existing.professional_reason is distinct from v_reason then
      update workflow.monograph_document_requests r
      set professional_reason = v_reason
      where r.id = v_existing.id;
    end if;
    return jsonb_build_object(
      'reference', v_existing.reference, 'requested', false,
      'state', v_existing.state::text);
  end if;

  select i.identifier_value into v_retrieved_from
  from knowledge.source_identifiers i
  where i.source_id = p_source_id and i.identifier_system = 'url'
  limit 1;

  if v_retrieved_from is null then
    select 'https://doi.org/' || i.identifier_value into v_retrieved_from
    from knowledge.source_identifiers i
    where i.source_id = p_source_id and i.identifier_system = 'doi'
    limit 1;
  end if;

  begin
    insert into workflow.monograph_document_requests
      (edition_id, source_id, required_representation, professional_reason,
       retrieved_from, requested_by_actor_id)
    values
      (p_edition_id, p_source_id, v_representation, v_reason,
       v_retrieved_from, p_actor_id)
    returning reference into v_reference;
  exception
    when unique_violation then
      select r.* into v_existing
      from workflow.monograph_document_requests r
      where r.source_id = p_source_id and r.state = 'open';
      return jsonb_build_object(
        'reference', v_existing.reference, 'requested', false,
        'state', v_existing.state::text);
  end;

  return jsonb_build_object(
    'reference', v_reference, 'requested', true, 'state', 'open');
end;
$$;

comment on function workflow.request_monograph_document(uuid, uuid, uuid) is
  'Én åpen forespørsel per kilde om det originalmaterialet en regulatorisk opplysning, en preparatdata eller et attribuert råd hviler på. Den faglige grunnen settes sammen av behovene selv — malens kode, avgrensningen og hva kilden er foreslått brukt til — slik at et menneske kan lese den uten å kjenne systemet, og uten å bli bedt om en teknisk registrering (SOURCE_POLICY.md §5). Representasjonen følger kildetypen: å be om «fulltekst» av en preparatomtale ville vært å be om noe som ikke finnes.';

revoke execute on function workflow.request_monograph_document(uuid, uuid, uuid) from public;

-- ----------------------------------------------------------------------------
-- 11. Innhentingen
--
-- Ett kall per valgt kandidat. Det oppretter ingen faglig vurdering, tar ingen
-- beslutning om evidens, og ber ingen om et godkjenningsklikk. Det finner
-- materialet, eller sier hva som mangler.
-- ----------------------------------------------------------------------------

create function workflow.acquire_monograph_candidate(p_candidate_id uuid)
  returns jsonb
  language plpgsql
  set search_path = ''
as $$
declare
  v_cand workflow.monograph_candidate_sources;
  v_source_id uuid;
  v_actor_id uuid;
  v_research_needs uuid[];
  v_authority_needs uuid[];
  v_unscoped_needs uuid[];
  v_research_version knowledge.source_versions;
  v_authority_version knowledge.source_versions;
  v_need_id uuid;
  v_uses integer := 0;
  v_result jsonb := jsonb_build_object();
begin
  select c.* into v_cand
  from workflow.monograph_candidate_sources c
  where c.id = p_candidate_id
  for update;

  if not found or v_cand.decision not in ('selected_for_retrieval', 'included') then
    return null;
  end if;

  -- Behovene, delt etter hva slags materiale de trenger.
  with behov as (
    select cn.need_id,
           knowledge.monograph_need_material_kind(cn.need_id) as kind,
           n.outcome_concept_id
    from workflow.monograph_candidate_source_needs cn
    join knowledge.monograph_needs n on n.id = cn.need_id
    where cn.candidate_source_id = p_candidate_id
      and n.relevance <> 'not_applicable'
  )
  select
    coalesce(array_agg(distinct b.need_id) filter (
      where b.kind = 'research_full_text' and b.outcome_concept_id is not null),
      array[]::uuid[]),
    coalesce(array_agg(distinct b.need_id) filter (
      where b.kind = 'authority_document'), array[]::uuid[]),
    coalesce(array_agg(distinct b.need_id) filter (
      where b.kind = 'research_full_text' and b.outcome_concept_id is null),
      array[]::uuid[])
    into v_research_needs, v_authority_needs, v_unscoped_needs
  from behov b;

  if cardinality(v_research_needs) = 0
     and cardinality(v_authority_needs) = 0
     and cardinality(v_unscoped_needs) = 0 then
    return null;
  end if;

  v_actor_id := coalesce(v_cand.decided_by_actor_id, v_cand.recorded_by_actor_id);

  -- En kandidat som bare er identifisert med en tittel, kan ikke bli en kilde:
  -- to publikasjoner kan hete det samme, og en kilde opprettet på tittel ville
  -- enten blitt to kilder eller slått sammen to arbeider. Det er en avklaring
  -- som mangler, og den sier seg selv på behovene framfor å stoppe stille.
  if workflow.monograph_candidate_identifier_system(v_cand.identifier_kind) is null then
    foreach v_need_id in array
      (v_research_needs || v_authority_needs || v_unscoped_needs)
    loop
      perform knowledge.set_monograph_need_work_state(
        v_need_id, 'awaiting_clarification'::knowledge.monograph_work_state,
        format('Kilden %L er valgt, men er bare identifisert med en tittel. '
               || 'Registrer treffets DOI, PMID, PMCID, adresse eller '
               || 'forsøksregisternummer, og innhentingen fortsetter.', v_cand.title),
        null, v_actor_id, v_cand.decided_by_agent_run_id);
    end loop;

    return jsonb_build_object(
      'source_id', null,
      'identifier_missing', true,
      'needs_awaiting_clarification',
        cardinality(v_research_needs || v_authority_needs || v_unscoped_needs));
  end if;

  v_source_id := workflow.ensure_monograph_candidate_source(p_candidate_id);

  -- ------------------------------------------------------------------------
  -- Det private kildebiblioteket først
  --
  -- Finnes dokumentet allerede — fordi en annen monografi, et annet behov
  -- eller en tidligere manuell registrering brakte det inn — er materialet i
  -- hus, og ingen skal bli bedt om det på nytt (SOURCE_POLICY.md §5).
  -- ------------------------------------------------------------------------
  select sv.* into v_research_version
  from knowledge.source_versions sv
  where sv.source_id = v_source_id
    and sv.representation = 'full_text'
  order by sv.retrieved_at desc, sv.id
  limit 1;

  select sv.* into v_authority_version
  from knowledge.source_versions sv
  where sv.source_id = v_source_id
    and sv.representation in ('full_text', 'regulatory_summary',
                              'registry_record', 'secondary_report')
  order by sv.retrieved_at desc, sv.id
  limit 1;

  if cardinality(v_research_needs) > 0 then
    if v_research_version.id is not null then
      v_uses := v_uses + workflow.register_monograph_source_uses(v_research_version.id);
      foreach v_need_id in array v_research_needs loop
        perform knowledge.set_monograph_need_work_state(
          v_need_id, 'extracting'::knowledge.monograph_work_state,
          'Fullteksten fantes i det private kildebiblioteket, og ekstraksjonen er lagt i køen.',
          null, v_actor_id, v_cand.decided_by_agent_run_id);
      end loop;
      v_result := v_result || jsonb_build_object(
        'research', jsonb_build_object(
          'from_library', true,
          'source_version_id', v_research_version.id));
    else
      v_result := v_result || jsonb_build_object(
        'research', coalesce(
          workflow.request_monograph_full_text(v_source_id, v_actor_id),
          jsonb_build_object('requested', false)));
      foreach v_need_id in array v_research_needs loop
        perform knowledge.set_monograph_need_work_state(
          v_need_id, 'awaiting_access'::knowledge.monograph_work_state,
          case when v_cand.access_limited
               then 'Fullteksten er etterspurt. Kilden har en registrert tilgangsbegrensning: '
                    || v_cand.access_limitation_note
               else 'Fullteksten er etterspurt, og arbeidet fortsetter når dokumentet er registrert.'
          end,
          null, v_actor_id, v_cand.decided_by_agent_run_id);
      end loop;
    end if;
  end if;

  if cardinality(v_authority_needs) > 0 then
    if v_authority_version.id is not null then
      v_uses := v_uses + workflow.register_monograph_source_uses(v_authority_version.id);
      foreach v_need_id in array v_authority_needs loop
        perform knowledge.set_monograph_need_work_state(
          v_need_id, 'extracting'::knowledge.monograph_work_state,
          'Dokumentet fantes i det private kildebiblioteket, og er godkjent for dette behovet.',
          null, v_actor_id, v_cand.decided_by_agent_run_id);
      end loop;
      v_result := v_result || jsonb_build_object(
        'authority', jsonb_build_object(
          'from_library', true,
          'source_version_id', v_authority_version.id));
    else
      v_result := v_result || jsonb_build_object(
        'authority', coalesce(
          workflow.request_monograph_document(
            v_source_id, v_cand.edition_id, v_actor_id),
          jsonb_build_object('requested', false)));
      foreach v_need_id in array v_authority_needs loop
        perform knowledge.set_monograph_need_work_state(
          v_need_id, 'awaiting_access'::knowledge.monograph_work_state,
          'Myndighets- eller preparatdokumentet er etterspurt, og arbeidet fortsetter når det er registrert.',
          null, v_actor_id, v_cand.decided_by_agent_run_id);
      end loop;
    end if;
  end if;

  -- Et forskningsbehov uten et navngitt endepunkt kan ikke bære et funn:
  -- ekstraksjonen har ingen avgrensning å kontrolleres mot. Det er en avklaring
  -- som mangler, og den sier seg selv på behovet framfor å bli tiet bort eller
  -- bli til «ingen relevante studier» (ANTIDEP_CONSTITUTION.md regel 4).
  foreach v_need_id in array v_unscoped_needs loop
    perform knowledge.set_monograph_need_work_state(
      v_need_id, 'awaiting_clarification'::knowledge.monograph_work_state,
      'Kilden er valgt, men behovet har ikke noe navngitt endepunkt ennå. '
      || 'Et forskningsfunn kan ikke kontrolleres mot et spørsmål uten et utfall: '
      || 'foreslå utfallsverdien fra dette behovet, og arbeidet fortsetter.',
      null, v_actor_id, v_cand.decided_by_agent_run_id);
  end loop;

  return v_result || jsonb_build_object(
    'source_id', v_source_id,
    'approved_uses_written', v_uses,
    'research_needs', cardinality(v_research_needs),
    'authority_needs', cardinality(v_authority_needs),
    'needs_awaiting_clarification', cardinality(v_unscoped_needs));
end;
$$;

comment on function workflow.acquire_monograph_candidate(uuid) is
  'Fører én valgt kandidatkilde videre til materialet er i hus, eller til det står hva som mangler. Kilden finnes eller opprettes fra kandidatens egen identifikator; det private kildebiblioteket spørres først; finnes dokumentet, blir den godkjente kildebruken ført opp i det samme kallet; finnes det ikke, blir det én samlet forespørsel med artikkelidentitet og faglig grunn. Ingen faglig vurdering, ingen beslutning om evidens, og ingen godkjenningsklikk per artikkel (SOURCE_POLICY.md §5).';

revoke execute on function workflow.acquire_monograph_candidate(uuid) from public;

-- ----------------------------------------------------------------------------
-- 12. Overgangene, i den samme transaksjonen
--
-- En valgt kilde skal føres videre av seg selv. En teknisk svikt i overgangen
-- skal ikke rulle tilbake den faglige avgjørelsen som utløste den — den blir et
-- teknisk problem og stoppet arbeid, og rekonsilieringen tar den opp igjen
-- (migrasjon 012b).
-- ----------------------------------------------------------------------------

create function workflow.chain_acquire_after_candidate_decision()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_state text;
begin
  if new.decision not in ('selected_for_retrieval', 'included') then
    return null;
  end if;

  if tg_op = 'UPDATE' and old.decision = new.decision then
    return null;
  end if;

  begin
    perform workflow.acquire_monograph_candidate(new.id);
  exception
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('innhenting', new.id, v_state);
  end;

  return null;
end;
$$;

comment on function workflow.chain_acquire_after_candidate_decision() is
  'Fører en valgt kandidatkilde videre til innhentingen, i den samme transaksjonen som avgjørelsen. En teknisk svikt her ruller ikke tilbake den faglige avgjørelsen: den blir et teknisk problem og stoppet arbeid, og rekonsilieringen tar den opp igjen (migrasjon 012b).';

revoke execute on function workflow.chain_acquire_after_candidate_decision() from public;

create trigger monograph_candidate_sources_acquire
  after insert or update of decision on workflow.monograph_candidate_sources
  for each row execute function workflow.chain_acquire_after_candidate_decision();

-- Et nytt behov lagt til en kilde som alt er valgt, utvider avgrensningen. Uten
-- dette ville ekstraksjonsoppgaven blitt bygget uten det, og det nye behovet
-- ville stått uten grunnlag ingen forsto manglet.
create function workflow.chain_acquire_after_candidate_need()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_state text;
  v_decision workflow.monograph_candidate_decision;
begin
  select c.decision into v_decision
  from workflow.monograph_candidate_sources c
  where c.id = new.candidate_source_id;

  if v_decision not in ('selected_for_retrieval', 'included') then
    return null;
  end if;

  begin
    perform workflow.acquire_monograph_candidate(new.candidate_source_id);
  exception
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('innhenting', new.candidate_source_id, v_state);
  end;

  return null;
end;
$$;

revoke execute on function workflow.chain_acquire_after_candidate_need() from public;

create trigger monograph_candidate_source_needs_acquire
  after insert on workflow.monograph_candidate_source_needs
  for each row execute function workflow.chain_acquire_after_candidate_need();

-- Og når materialet faktisk er registrert: den godkjente kildebruken føres opp,
-- forespørselen lukkes, og behovene går videre.
create function workflow.chain_uses_after_source_version()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_state text;
  v_need_id uuid;
begin
  if new.representation is null then
    return null;
  end if;

  begin
    perform workflow.register_monograph_source_uses(new.id);

    update workflow.monograph_document_requests r
    set state = 'fulfilled',
        fulfilled_source_version_id = new.id,
        closed_at = now()
    where r.source_id = new.source_id
      and r.state = 'open'
      and r.required_representation = new.representation;

    -- Behovene som nå har materialet sitt, går videre. Hvilke det er, leses av
    -- den godkjente bruken og ikke av en gjetning: bare de behovene som
    -- faktisk fikk en bruk, har noe å arbeide med.
    for v_need_id in
      select u.need_id
      from knowledge.monograph_source_uses u
      join knowledge.monograph_needs n on n.id = u.need_id
      where u.source_version_id = new.id
        and n.work_state in ('awaiting_access'::knowledge.monograph_work_state,
                             'searching'::knowledge.monograph_work_state,
                             'appraising_sources'::knowledge.monograph_work_state,
                             'not_started'::knowledge.monograph_work_state)
      order by u.need_id
    loop
      perform knowledge.set_monograph_need_work_state(
        v_need_id, 'extracting'::knowledge.monograph_work_state,
        'Materialet er registrert, og behovet har en godkjent kildebruk.',
        null, new.retrieved_by_actor_id, null);
    end loop;
  exception
    when restrict_violation or no_data_found or invalid_parameter_value then
      null;
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      perform workflow.chain_note_failure('innhenting', new.id, v_state);
  end;

  return null;
end;
$$;

comment on function workflow.chain_uses_after_source_version() is
  'Fører den godkjente kildebruken opp, lukker forespørselen og flytter behovene videre når materialet faktisk er registrert. Ligger på kildeversjonen fordi det er registreringen som er hendelsen: dokumentet kan komme fra fulltekstinnboksen, fra myndighetsveien eller fra en tidligere manuell registrering, og alle tre skal føre arbeidet videre likt.';

revoke execute on function workflow.chain_uses_after_source_version() from public;

create trigger source_versions_register_monograph_uses
  after insert on knowledge.source_versions
  for each row execute function workflow.chain_uses_after_source_version();

-- ----------------------------------------------------------------------------
-- 13. Den ene samlede forespørselen et menneske ser
--
-- Artikkelidentiteten og den faglige grunnen. Ingen kildeversjons-id, ingen
-- jobbnøkkel, ingen behov-uuid: teknisk registrering og intern identitet er
-- ikke klinikerens arbeidsflate (ANTIDEP_CONSTITUTION.md regel 4).
-- ----------------------------------------------------------------------------

create function api.monograph_source_requests(p_edition_reference text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_edition knowledge.monograph_editions;
  v_research jsonb;
  v_documents jsonb;
begin
  perform knowledge.assert_editor_authorized();

  select e.* into v_edition
  from knowledge.monograph_editions e
  where e.reference = p_edition_reference;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen monografiutgave med denne referansen.';
  end if;

  -- Forskningsfulltekst. Avgrensningen vises som navn og ikke som id-er: den
  -- som skal finne riktig PDF, trenger artikkelen og grunnen.
  select coalesce(jsonb_agg(x.row order by x.title), '[]'::jsonb) into v_research
  from (
    select s.title,
           jsonb_build_object(
             'reference', r.reference,
             'kind', 'research_full_text',
             'title', s.title,
             'authors_or_issuer', s.authors_or_issuer,
             'publisher_or_journal', s.publisher_or_journal,
             'publication_year',
               case when s.publication_date is null then null
                    else date_part('year', s.publication_date)::integer end,
             'identifiers', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'system', i.identifier_system::text,
                        'value', i.identifier_value)
                        order by i.identifier_system::text), '[]'::jsonb)
               from knowledge.source_identifiers i where i.source_id = s.id),
             'retrieved_from', r.retrieved_from,
             'requested_at', r.requested_at,
             'access_limitation', (
               select string_agg(distinct c.access_limitation_note, ' · ')
               from workflow.monograph_candidate_sources c
               where c.source_id = s.id and c.edition_id = v_edition.id
                 and c.access_limited),
             'professional_reason', (
               select string_agg(
                        format('%s (%s): %s', t.code,
                               coalesce(knowledge.monograph_need_scope_label(n.id),
                                        'uten avgrensning'),
                               cn.proposed_use),
                        E'\n' order by t.code, n.id)
               from workflow.monograph_candidate_sources c
               join workflow.monograph_candidate_source_needs cn
                 on cn.candidate_source_id = c.id
               join knowledge.monograph_needs n on n.id = cn.need_id
               join knowledge.monograph_question_templates t on t.id = n.template_id
               where c.source_id = s.id and c.edition_id = v_edition.id
                 and c.decision in ('selected_for_retrieval', 'included'))
           ) as row
    from workflow.full_text_requests r
    join knowledge.sources s on s.id = r.source_id
    where r.state = 'open'
      and exists (
        select 1 from workflow.monograph_candidate_sources c
        where c.source_id = s.id and c.edition_id = v_edition.id
          and c.decision in ('selected_for_retrieval', 'included'))
  ) x;

  select coalesce(jsonb_agg(x.row order by x.title), '[]'::jsonb) into v_documents
  from (
    select s.title,
           jsonb_build_object(
             'reference', r.reference,
             'kind', 'authority_document',
             'required_representation', r.required_representation::text,
             'title', s.title,
             'authors_or_issuer', s.authors_or_issuer,
             'publisher_or_journal', s.publisher_or_journal,
             'identifiers', (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'system', i.identifier_system::text,
                        'value', i.identifier_value)
                        order by i.identifier_system::text), '[]'::jsonb)
               from knowledge.source_identifiers i where i.source_id = s.id),
             'retrieved_from', r.retrieved_from,
             'requested_at', r.requested_at,
             'professional_reason', r.professional_reason
           ) as row
    from workflow.monograph_document_requests r
    join knowledge.sources s on s.id = r.source_id
    where r.state = 'open' and r.edition_id = v_edition.id
  ) x;

  return jsonb_build_object(
    'edition', v_edition.reference,
    'drug', (select d.canonical_name from catalog.drugs d where d.id = v_edition.drug_id),
    'research_full_text', v_research,
    'authority_documents', v_documents,
    'open_requests',
      jsonb_array_length(v_research) + jsonb_array_length(v_documents));
end;
$$;

comment on function api.monograph_source_requests(text) is
  'Den ene samlede listen over originalmateriale Antidep venter på for én monografiutgave: artikkelidentiteten, den faglige grunnen og en eventuell registrert tilgangsbegrensning. Ingen kildeversjons-id, ingen jobbnøkkel og ingen behov-uuid — teknisk registrering og interne identifikatorer er ikke klinikerens arbeidsflate (ANTIDEP_CONSTITUTION.md regel 4). Listen er ikke et godkjenningssteg: kilden er alt valgt, og dette er bare det Antidep ikke selv kom til.';

revoke execute on function api.monograph_source_requests(text) from public;
grant execute on function api.monograph_source_requests(text) to authenticated;

-- ----------------------------------------------------------------------------
-- 14. Registreringen av et myndighetsdokument
--
-- Filen, teksten og tidspunktet — med filens eget fingeravtrykk. Ingen GRADE,
-- ingen evidensrad, ingen forskningskontrakt.
-- ----------------------------------------------------------------------------

create function api.submit_monograph_document(
  p_reference text,
  p_document_base64 text,
  p_media_type text,
  p_extracted_text text,
  p_text_extraction_recipe text,
  p_retrieved_from text default null,
  p_external_version text default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_request workflow.monograph_document_requests;
  v_bytes bytea;
  v_text text;
  v_retrieved_from text;
  v_source_version_id uuid;
begin
  v_actor_id := workflow.assert_full_text_inbox_authorized();

  select r.* into v_request
  from workflow.monograph_document_requests r
  where r.reference = p_reference and r.state = 'open'
  for update;

  if v_request.id is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Antidep venter ikke på dette dokumentet nå.',
      hint = 'Forespørselen er enten allerede oppfylt eller trukket tilbake. Hent listen på nytt.';
  end if;

  if nullif(btrim(coalesce(p_document_base64, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ingen fil ble sendt med.';
  end if;

  begin
    v_bytes := decode(p_document_base64, 'base64');
  exception
    when others then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = 'Filen lot seg ikke lese slik den ble sendt.',
        hint = 'Send filen byte for byte. Enhver omforming underveis ville gitt et fingeravtrykk som ikke er filens.';
  end;

  -- En PDF hører til den andre veien. To veier for den samme filtypen ville
  -- svekket den ene: PDF-veien har sin egen signaturkontroll, sin egen
  -- tekstuttrekksoppskrift og sin egen lesbarhetskontroll.
  if substring(v_bytes from 1 for 5) = '\x255044462d'::bytea then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Dette er en PDF, og en PDF registreres gjennom fulltekstinnboksen.',
      hint = 'PDF-veien har sin egen signaturkontroll, tekstuttrekksoppskrift og lesbarhetskontroll. To veier for den samme filtypen ville svekket den ene (SOURCE_POLICY.md §5).';
  end if;

  v_text := btrim(coalesce(p_extracted_text, ''));
  if length(v_text) < 200 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Den registrerte teksten er for kort til å være dokumentet.',
      hint = 'Teksten er det et ordrett utdrag senere kontrolleres mot. Et utdrag av et utdrag kunne ikke kontrolleres, og et sammendrag skal ikke kunne stå der det komplette dokumentet skal stå.';
  end if;

  v_retrieved_from := coalesce(
    nullif(btrim(coalesce(p_retrieved_from, '')), ''),
    v_request.retrieved_from);
  if v_retrieved_from is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Oppgi adressen dokumentet faktisk ble hentet fra.',
      hint = 'En kildeversjon uten opphav er ikke sporbar til en utgiver, og aktualitetskontrollen har da ingenting å lese.';
  end if;

  insert into knowledge.source_versions (
    source_id, retrieved_at, retrieved_from, external_version,
    content_hash, representation, retrieved_by_actor_id
  )
  values (
    v_request.source_id, now(), v_retrieved_from,
    nullif(btrim(coalesce(p_external_version, '')), ''),
    knowledge.source_version_content_hash(v_text),
    v_request.required_representation, v_actor_id
  )
  returning id into v_source_version_id;

  insert into knowledge.authority_documents (
    source_version_id, sha256, byte_size, media_type, content,
    retrieved_from, retrieved_at, text_extraction_recipe, stored_by_actor_id
  )
  values (
    v_source_version_id,
    knowledge.source_document_fingerprint(v_bytes),
    octet_length(v_bytes),
    btrim(coalesce(p_media_type, '')),
    v_bytes,
    v_retrieved_from,
    now(),
    btrim(coalesce(p_text_extraction_recipe, '')),
    v_actor_id
  );

  insert into knowledge.source_version_texts
    (source_version_id, representation, stored_by_actor_id)
  values (v_source_version_id, v_text, v_actor_id);

  return jsonb_build_object(
    'reference', v_request.reference,
    'registered', true,
    'representation', v_request.required_representation::text,
    'approved_uses',
      (select count(*)::integer from knowledge.monograph_source_uses u
       where u.source_version_id = v_source_version_id));
end;
$$;

comment on function api.submit_monograph_document(text, text, text, text, text, text, text) is
  'Registrerer originalmaterialet til en regulatorisk opplysning, en preparatdata eller et attribuert råd: filen med sitt eget fingeravtrykk, teksten et ordrett utdrag senere kontrolleres mot, adressen og tidspunktet. En PDF avvises med vilje — den hører til fulltekstinnboksen, som har sin egen signaturkontroll og lesbarhetskontroll, og to veier for den samme filtypen ville svekket den ene. Veien gir ingen GRADE-vurdering og ingen evidensrad: et myndighetsdokument får kilde- og aktualitetskontroll, ikke en oppdiktet forskningsvurdering.';

revoke execute on function api.submit_monograph_document(text, text, text, text, text, text, text) from public;
grant execute on function api.submit_monograph_document(text, text, text, text, text, text, text) to authenticated;

create function api.withdraw_monograph_document_request(
  p_reference text,
  p_reason text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_request workflow.monograph_document_requests;
begin
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En tilbaketrekking krever en begrunnelse.',
      hint = 'Begrunnelsen er det som gjør at en lukket forespørsel ikke blir lest som et faglig utfall senere.';
  end if;

  update workflow.monograph_document_requests r
  set state = 'withdrawn',
      closed_at = now(),
      closed_reason = btrim(p_reason)
  where r.reference = p_reference and r.state = 'open'
  returning * into v_request;

  if v_request.id is null then
    raise exception using
      errcode = 'no_data_found',
      message = 'Det finnes ingen åpen forespørsel med denne referansen.';
  end if;

  return jsonb_build_object(
    'reference', v_request.reference, 'withdrawn', true,
    'actor_id', v_actor_id);
end;
$$;

comment on function api.withdraw_monograph_document_request(text, text) is
  'Trekker tilbake en åpen forespørsel om et myndighets-, preparat- eller retningslinjedokument, med en begrunnelse. Begrunnelsen er påkrevd fordi en lukket forespørsel uten den senere ville blitt lest som en konklusjon om kilden framfor som en avgjørelse et menneske tok.';

revoke execute on function api.withdraw_monograph_document_request(text, text) from public;
grant execute on function api.withdraw_monograph_document_request(text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 15. Tilgangene
--
-- Ingen leserett og ingen leseregel på noen av de to nye tabellene. Originalfilen
-- følger `knowledge.source_documents`: bytene forlater databasen bare gjennom en
-- kontrollert funksjon, aldri gjennom en leserett — en privat originalfil skal
-- ikke kunne lekke gjennom en monografivisning, en eksport eller en offentlig
-- lesevei. Forespørselen leses gjennom api.monograph_source_requests(text), som
-- viser artikkelidentiteten og den faglige grunnen og ingenting annet.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 16. Rekonsilieringen
--
-- Triggerne over kjører i den samme transaksjonen som avgjørelsen, og det er
-- det normale. Men en transaksjon kan bli avbrutt, en kvote kan bli oppbrukt og
-- en tidsgrense kan slå inn, og da skal arbeidet fortsette der det slapp —
-- uten å lage duplikater. To nye ledd føres derfor inn i den samme
-- rekonsilieringsveien som resten av kjeden: søkeoppgavene, og innhentingen.
--
-- Utestående innhenting betyr: kilderaden er ikke løst, eller et behov kilden
-- er valgt for, har verken en godkjent kildebruk eller en åpen forespørsel.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.resume_chain_transitions(p_identity_key text, p_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  -- Grensen er en kostnadsgrense, og den avgjør i tillegg om passeringen nådde
  -- *enden* av leddet: færre rader enn grensen betyr at feiingen er rundt.
  -- Markøren (workflow.chain_reconciliation_cursors) gjør at neste passering
  -- fortsetter der denne slapp, slik at en grense ikke blir til sult.
  v_limit constant integer := workflow.chain_reconciliation_limit();
  v_identity provenance.agent_identities;
  v_row record;
  v_state text;
  v_queued integer := 0;
  v_candidates integer := 0;
  v_reviews integer := 0;
  v_acquisitions integer := 0;
  v_plans integer := 0;
  v_seen integer;
  v_failed boolean;
  v_position text;
begin
  select i.* into v_identity
  from provenance.agent_identities i
  where i.identity_key = p_identity_key;

  if not found or v_identity.agent_role not in
       ('extraction_verification'::provenance.agent_role,
        'citation_support_verification'::provenance.agent_role) then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kjedeoverganger tas opp igjen av de deterministiske kontrolleddene.',
      hint = 'Veien legger aldri inn noe annet enn det databasens egen tilstand allerede tilsier, og tar ikke imot ett eneste felt fra kalleren.';
  end if;

  perform provenance.authenticate_agent_identity(
    p_identity_key, p_secret, v_identity.agent_role);

  -- --------------------------------------------------------------------
  -- Ekstraksjonskontroller som mangler.
  --
  -- Hvert ledd telles og rekonsilieres for seg. `v_failed` er det som avgjør
  -- om leddets tekniske problem kan lukkes, og `v_seen < v_limit` er det som
  -- avgjør om denne passeringen i det hele tatt så hele leddet: en passering
  -- som stoppet på grensen, kan ikke vite om raden bak den fortsatt svikter.
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('ekstraksjonskontroll');
  for v_row in
    select e.id, e.id::text as sort_key
    from knowledge.evidence_items e
    where not exists (
      select 1 from workflow.pipeline_jobs j
      where j.agent_role = 'extraction_verification'::provenance.agent_role
        and j.job_key = workflow.control_job_key('ekstraksjon', e.id))
      and e.id::text > v_position
    order by e.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_control_for_evidence_item(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('ekstraksjonskontroll', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'ekstraksjonskontroll', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('ekstraksjonskontroll');
  end if;

  -- Synteseoppgaver som mangler.
  --
  -- Utvalget er de *subjektene* som mangler en oppgave, og ikke enhver
  -- kontrollert rad: ett subjekt er én oppgave, og uten avgrensningen ville
  -- passeringen brukt grensen sin på rader den allerede hadde gjort ferdig.
  -- Portene speiler overgangens egne — den gjeldende kontrollen er den siste, og
  -- et par som alt har en påstand, er ikke automatikkens å skrive om — slik at
  -- en rad som med rette står, ikke blir liggende i utvalget for alltid.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('syntese');
  for v_row in
    with gjeldende as (
      select distinct on (ev.evidence_item_id)
             ev.evidence_item_id, ev.outcome
      from workflow.evidence_verifications ev
      order by ev.evidence_item_id, ev.registration_ordinal desc
    ),
    utestaaende as (
      select e.intervention_drug_id as drug_id,
             e.outcome_concept_id as topic_id,
             min(e.id::text) as sort_key
      from knowledge.evidence_items e
      join gjeldende g on g.evidence_item_id = e.id and g.outcome = 'verified'
      where not exists (
        select 1 from knowledge.claims c
        where c.topic_concept_id = e.outcome_concept_id
          and c.subject_drug_id = e.intervention_drug_id)
      group by e.intervention_drug_id, e.outcome_concept_id
    )
    select u.sort_key::uuid as id, u.sort_key
    from utestaaende u
    where not workflow.agent_task_subject_queued(
            'claim_synthesis'::provenance.agent_role,
            format('%s+%s', u.drug_id, u.topic_id))
      and u.sort_key > v_position
    order by u.sort_key
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_task_for_verified_extraction(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('syntese', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step('syntese', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('syntese');
  end if;

  -- Kildestøttekontroller som mangler.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('kildestottekontroll');
  for v_row in
    select r.id, r.id::text as sort_key
    from knowledge.claim_revisions r
    where not exists (
      select 1 from workflow.pipeline_jobs j
      where j.agent_role = 'citation_support_verification'::provenance.agent_role
        and j.job_key = workflow.control_job_key('kildestotte', r.id))
      and r.id::text > v_position
    order by r.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_control_for_claim_revision(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kildestottekontroll', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'kildestottekontroll', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kildestottekontroll');
  end if;

  -- Evidensvurderinger som mangler. Som over: de revisjonene som faktisk mangler
  -- oppgaven, lest med den gjeldende kontrollen og ikke med en hvilken som helst.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('evidensvurdering');
  for v_row in
    with gjeldende as (
      select distinct on (cv.claim_revision_id)
             cv.claim_revision_id, cv.outcome
      from workflow.claim_verifications cv
      order by cv.claim_revision_id, cv.registration_ordinal desc
    )
    select g.claim_revision_id as id, g.claim_revision_id::text as sort_key
    from gjeldende g
    where g.outcome = 'verified'
      and not workflow.agent_task_subject_queued(
            'evidence_assessment'::provenance.agent_role, g.claim_revision_id::text)
      and g.claim_revision_id::text > v_position
    order by g.claim_revision_id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_task_for_verified_claim(v_row.id) is not null then
        v_queued := v_queued + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('evidensvurdering', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'evidensvurdering', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('evidensvurdering');
  end if;

  -- Kandidater som mangler. Gaten avgjør, som i overgangen: en revisjon som
  -- ikke er ferdig, forseglet ikke, og det er ikke en feil — det er kjeden som
  -- ikke er kommet dit ennå. De tre klassene som betyr nettopp det, går derfor
  -- stille; alt annet er en teknisk svikt og skal telles som en, akkurat som i
  -- de fire leddene over. Et `when others` som svelget uten å registrere, ville
  -- gjort den ene svikten som *ikke* har en trigger bak seg, usynlig.
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('kandidat');
  for v_row in
    select distinct a.claim_revision_id as id, a.claim_revision_id::text as sort_key
    from knowledge.evidence_assessments a
    where not exists (
      select 1 from knowledge.candidates c where c.claim_revision_id = a.claim_revision_id)
      and a.claim_revision_id::text > v_position
    order by a.claim_revision_id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_candidate_for_assessment(v_row.id) is not null then
        v_candidates := v_candidates + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kandidat', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step('kandidat', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kandidat');
  end if;

  -- ------------------------------------------------------------------
  -- Redaksjonelle revisjonsvurderinger som mangler.
  --
  -- Det sjette leddet, og det eneste som ikke ender i en jobb: her stopper
  -- kjeden med vilje, og det som skal stå igjen, er en synlig oppgave til et
  -- menneske (migrasjon 012d). Svikter den overgangen teknisk, ville den nye
  -- kunnskapen vært usynlig for alltid — derfor feies den igjen her, som de
  -- fem andre.
  --
  -- Utvalget er *parene* som har brukbar evidens ingen revisjon av påstanden
  -- hviler på, og ikke enhver kontrollert rad: ett par er én oppgave.
  -- Brukbarheten avgjøres inne i overgangen, med skriveveiens egen funksjon;
  -- her er utvalget den billigere formen — en gjeldende, bekreftet kontroll —
  -- slik at passeringen ikke bruker grensen sin på rader som uansett faller.
  -- ------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('paastandsrevisjon');
  for v_row in
    with gjeldende as (
      select distinct on (ev.evidence_item_id)
             ev.evidence_item_id, ev.outcome
      from workflow.evidence_verifications ev
      order by ev.evidence_item_id, ev.registration_ordinal desc
    ),
    par as (
      -- Par som har ny, kontrollert evidens ingen revisjon hviler på.
      select c.id as claim_id,
             c.subject_drug_id as drug_id,
             c.topic_concept_id as topic_id,
             c.monograph_need_id as need_id
      from knowledge.claims c
      join knowledge.evidence_items e
        on e.intervention_drug_id = c.subject_drug_id
       and e.outcome_concept_id = c.topic_concept_id
       -- Og innenfor påstandens egen avgrensning. En monografiavgrenset
       -- påstand utfordres ikke av et funn om et annet spørsmål.
       and (c.monograph_need_id is null
            or knowledge.monograph_need_for_evidence_item(e.id) = c.monograph_need_id)
      join gjeldende g on g.evidence_item_id = e.id and g.outcome = 'verified'
      where c.id = workflow.claim_awaiting_revision(
                     c.subject_drug_id, c.topic_concept_id, c.monograph_need_id)
        and not exists (
          select 1
          from knowledge.claim_evidence_links l
          join knowledge.claim_revisions r on r.id = l.claim_revision_id
          where r.claim_id = c.id and l.evidence_item_id = e.id)
      group by c.id, c.subject_drug_id, c.topic_concept_id, c.monograph_need_id
      union
      -- Og oppgavene som alt står åpne. Utvalget over finner dem gjennom en
      -- evidensrad, og en hard sletting tar den raden bort: da ville en oppgave
      -- ingen kan fullføre, ikke vært mulig å nå herfra i det hele tatt. Selve
      -- skrivingen holder tilstanden i takt (avsnitt 14); dette er nettet under.
      select c.id, c.subject_drug_id, c.topic_concept_id, c.monograph_need_id
      from workflow.claim_revision_reviews r
      join knowledge.claims c on c.id = r.claim_id
      where r.state = 'open'
    ),
    utestaaende as (
      -- Ett par og én avgrensning er én oppgave, også når begge kildene over
      -- peker på den.
      select distinct on (
               workflow.claim_synthesis_subject(
                 p.drug_id::text, p.topic_id::text, p.need_id::text))
             p.claim_id, p.drug_id, p.topic_id, p.need_id,
             workflow.claim_synthesis_subject(
               p.drug_id::text, p.topic_id::text, p.need_id::text) as sort_key
      from par p
      order by workflow.claim_synthesis_subject(
                 p.drug_id::text, p.topic_id::text, p.need_id::text),
               p.claim_id
    )
    select u.claim_id as id, u.drug_id, u.topic_id, u.need_id, u.sort_key
    from utestaaende u
    where u.sort_key > v_position
    order by u.sort_key
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.notice_claim_revision_need(
           v_row.drug_id, v_row.topic_id, v_row.need_id) is not null then
        v_reviews := v_reviews + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('paastandsrevisjon', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'paastandsrevisjon', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('paastandsrevisjon');
  end if;

  -- --------------------------------------------------------------------
  -- Søkeplaner uten en oppdagelsesoppgave, og lukkede søk uten en kontroll.
  --
  -- Begge overgangene er idempotente, så leddet kan gå gjennom alle åpne
  -- planer: en plan som alt har oppgavene sine, koster et oppslag.
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('kildeoppdagelse');
  for v_row in
    select p.id, p.id::text as sort_key
    from workflow.monograph_search_plans p
    where p.closed_at is null
      and p.paused_at is null
      and p.id::text > v_position
    order by p.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.chain_task_for_search_plan(v_row.id) is not null then
        v_plans := v_plans + 1;
      end if;
      if workflow.chain_task_for_search_coverage(v_row.id) is not null then
        v_plans := v_plans + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('kildeoppdagelse', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'kildeoppdagelse', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('kildeoppdagelse');
  end if;

  -- --------------------------------------------------------------------
  -- Valgte kilder som ikke er hentet inn.
  --
  -- Utestående betyr: kilderaden er ikke løst, eller et behov kilden er valgt
  -- for, har verken en godkjent kildebruk eller en åpen forespørsel. Et behov
  -- som står på en avklaring, er ikke utestående her — det venter på et
  -- menneske, og det står synlig på behovet (ANTIDEP_CONSTITUTION.md regel 4).
  -- --------------------------------------------------------------------
  v_seen := 0;
  v_failed := false;
  v_position := workflow.chain_cursor_position('innhenting');
  for v_row in
    select c.id, c.id::text as sort_key
    from workflow.monograph_candidate_sources c
    where c.decision in ('selected_for_retrieval'::workflow.monograph_candidate_decision,
                         'included'::workflow.monograph_candidate_decision)
      and workflow.monograph_candidate_identifier_system(c.identifier_kind) is not null
      and (
        c.source_id is null
        or exists (
          select 1
          from workflow.monograph_candidate_source_needs cn
          join knowledge.monograph_needs n on n.id = cn.need_id
          where cn.candidate_source_id = c.id
            and n.relevance <> 'not_applicable'::knowledge.monograph_relevance
            and n.work_state <> 'awaiting_clarification'::knowledge.monograph_work_state
            and knowledge.monograph_need_material_kind(cn.need_id)
                  <> 'derived'::knowledge.monograph_material_kind
            and not exists (
              select 1
              from knowledge.monograph_source_uses u
              join knowledge.source_versions sv on sv.id = u.source_version_id
              where u.need_id = cn.need_id and sv.source_id = c.source_id)
            and not exists (
              select 1 from workflow.full_text_requests r
              where r.source_id = c.source_id and r.state = 'open')
            and not exists (
              select 1 from workflow.monograph_document_requests r
              where r.source_id = c.source_id and r.state = 'open')))
      and c.id::text > v_position
    order by c.id::text
    limit v_limit
  loop
    v_seen := v_seen + 1;
    v_position := v_row.sort_key;
    begin
      if workflow.acquire_monograph_candidate(v_row.id) is not null then
        v_acquisitions := v_acquisitions + 1;
      end if;
    exception
      when restrict_violation or no_data_found or invalid_parameter_value then
        null;
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        perform workflow.chain_note_failure('innhenting', v_row.id, v_state);
        v_failed := true;
    end;
  end loop;
  if workflow.chain_cursor_step(
       'innhenting', v_position, v_failed, v_seen < v_limit) then
    perform workflow.chain_resolve_step('innhenting');
  end if;

  return jsonb_build_object('queued', v_queued, 'candidates_built', v_candidates,
                            'revision_reviews', v_reviews,
                            'search_tasks', v_plans,
                            'acquisitions', v_acquisitions);
end;
$function$;
