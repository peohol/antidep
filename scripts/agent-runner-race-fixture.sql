-- ============================================================================
-- Fiksturen prøve 16 til 18 i scripts/db-lock-test.sh kappes på
--
-- Prøvene trenger én ekte, utførbar handoff-oppgave og én registrert autonom
-- kjører med et brukbart access-token, slik at det *eneste* som avgjør utfallet,
-- er uttaket: hvem som holder leien, og hva den andre forbindelsen da får lov
-- til. Uten en oppgave som faktisk kan tas, ville prøvene vært grønne fordi
-- ingenting var mulig.
--
-- Tokenet står her i klartekst fordi det er en prøve. Databasen lagrer bare
-- fingeravtrykket, og verdien finnes ingen andre steder enn i denne filen og i
-- db-lock-test.sh. Den gir tilgang til nøyaktig ett agentledd i en lokal
-- testdatabase, og til ingenting annet.
--
-- Fiksturen er idempotent og bygges opp på nytt hver kjøring: uttak teller
-- forsøk, og en jobb som ble stående med oppbrukte forsøk fra forrige kjøring,
-- ville gjort neste kjøring grønn av feil grunn. Radene i workflow er
-- append-only, så oppryddingen kjører med replikeringstriggerne av — bare for
-- oppryddingen, og bare på denne fiksturens egne rader.
--
-- Modelltildelingen bruker leverandøren `antidep-test` med vilje: kjedeprøven
-- (scripts/agent-chain-test.ts) rydder nettopp den bort før den registrerer
-- sine egne, og de to prøvene skal kunne kjøres i samme database uten å møte
-- hverandres tildelinger.
--
-- Kjøres av scripts/db-lock-test.sh. Ingenting her hører hjemme i en migrasjon:
-- dette er prøvedata, ikke kunnskap (supabase/README.md).
-- ============================================================================
\set ON_ERROR_STOP on

begin;

-- ----------------------------------------------------------------------------
-- Opprydding. Bare denne fiksturens egne rader.
-- ----------------------------------------------------------------------------
set local session_replication_role = replica;

delete from workflow.agent_runner_events e
where e.connection_id in (
  select c.id from workflow.agent_runner_connections c
  where c.connection_key = 'agent-runner:laaseprove');
delete from workflow.agent_runner_secrets s
where s.connection_id in (
  select c.id from workflow.agent_runner_connections c
  where c.connection_key = 'agent-runner:laaseprove');
delete from workflow.agent_handoff_imports i
where i.pipeline_job_id in (
  select j.id from workflow.pipeline_jobs j where j.job_key like 'laaseprove-runner:%');
delete from workflow.agent_runner_connections c
where c.connection_key = 'agent-runner:laaseprove';
delete from workflow.pipeline_job_runs r
where r.pipeline_job_id in (
  select j.id from workflow.pipeline_jobs j where j.job_key like 'laaseprove-runner:%');
delete from workflow.agent_handoff_jobs h
where h.pipeline_job_id in (
  select j.id from workflow.pipeline_jobs j where j.job_key like 'laaseprove-runner:%');
delete from workflow.pipeline_job_events ev
where ev.pipeline_job_id in (
  select j.id from workflow.pipeline_jobs j where j.job_key like 'laaseprove-runner:%');
delete from workflow.pipeline_jobs j where j.job_key like 'laaseprove-runner:%';
delete from provenance.role_model_assignments a
where a.capacity = 'semantic' and a.provider = 'antidep-test'
  and a.model = 'laaseprove-ekstraksjon';

set local session_replication_role = origin;

-- Ett agentledd har høyst én gjeldende kjører. En annen prøve i den samme
-- databasen kan ha lagt igjen sin egen i dette leddet; den trekkes tilbake
-- gjennom de vanlige kolonnene framfor å slettes, så regelen prøves og ikke
-- omgås — og prøvene kan kjøres i hvilken som helst rekkefølge.
update workflow.agent_runner_connections c
set valid_to = statement_timestamp(),
    revoked_by_actor_id = (select a.id from provenance.actors a
                           where a.actor_key = 'human:peder-holman'),
    revocation_reason = 'Ryddet av samtidighetsprøven av den autonome kjøreren.'
where c.agent_role = 'evidence_extraction' and c.valid_to is null;

update workflow.agent_runner_secrets s
set revoked_at = statement_timestamp()
where s.revoked_at is null
  and s.connection_id in (
    select c.id from workflow.agent_runner_connections c
    where c.agent_role = 'evidence_extraction' and c.valid_to is not null);

-- ----------------------------------------------------------------------------
-- Redaktøren. Den manuelle importveien i prøve 17 krever editor-mandat, og den
-- skal avvises av uttaket — ikke av en manglende rettighet.
-- ----------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email)
values ('7e000000-0000-4000-8000-0000000000e0',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'laaseprove-redaktor@antidep.test')
on conflict (id) do nothing;

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values ('7e000000-0000-4000-8000-0000000000e1', 'human:laaseprove-redaktor', 'human',
        'Redaktør for kjørerprøven',
        'Bare til scripts/db-lock-test.sh. Registrerer ingen faglig vurdering av reelt innhold.',
        '7e000000-0000-4000-8000-0000000000e0')
on conflict (id) do nothing;

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select '7e000000-0000-4000-8000-0000000000e0', 'editor', null, now() - interval '1 year',
       a.id, 'Editor-tildeling for kjørerprøven.'
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (
    select 1 from workflow.user_roles ur
    where ur.user_id = '7e000000-0000-4000-8000-0000000000e0'
      and ur.role_code = 'editor'
  );

-- ----------------------------------------------------------------------------
-- Kilden, kildeversjonen og den private representasjonen.
--
-- Oppgaven bygges av disse radene, og uten den lagrede teksten ville jobben
-- vært blokkert av grunnlaget framfor av uttaket.
-- ----------------------------------------------------------------------------
insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, created_by_actor_id)
select '7e000000-0000-4000-8000-000000000001', 'journal_article',
       'Samtidighetsprøve for den autonome kjøreren', 'scripts/db-lock-test.sh', a.id
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (select 1 from knowledge.sources s
                  where s.id = '7e000000-0000-4000-8000-000000000001');

insert into knowledge.source_documents
  (sha256, byte_size, media_type, content, stored_by_actor_id)
select knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
       'application/pdf', g.bytes, a.id
from (select convert_to('%PDF-1.7' || E'\nlaaseprove-runner\n%%EOF\n', 'UTF8') as bytes) g
join provenance.actors a on a.actor_key = 'human:peder-holman'
on conflict (sha256) do nothing;

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference, representation,
   retrieved_by_actor_id, document_sha256, document_byte_size, document_media_type,
   text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
   text_extraction_transform)
select '7e000000-0000-4000-8000-000000000002', '7e000000-0000-4000-8000-000000000001',
       now(), 'file:///laaseprove-runner.pdf',
       knowledge.source_version_content_hash(t.text),
       'private://laaseprove-runner.pdf', 'full_text', a.id,
       knowledge.source_document_fingerprint(convert_to('%PDF-1.7' || E'\nlaaseprove-runner\n%%EOF\n', 'UTF8')),
       octet_length(convert_to('%PDF-1.7' || E'\nlaaseprove-runner\n%%EOF\n', 'UTF8')),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from (select E'Syntetisk artikkel for samtidighetsprøven.\n\nIngen linje her er en klinisk påstand.\n' as text) t
join provenance.actors a on a.actor_key = 'human:peder-holman'
where not exists (select 1 from knowledge.source_versions v
                  where v.id = '7e000000-0000-4000-8000-000000000002');

insert into knowledge.source_version_texts (source_version_id, representation, stored_by_actor_id)
select '7e000000-0000-4000-8000-000000000002',
       E'Syntetisk artikkel for samtidighetsprøven.\n\nIngen linje her er en klinisk påstand.\n',
       a.id
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (select 1 from knowledge.source_version_texts t
                  where t.source_version_id = '7e000000-0000-4000-8000-000000000002');

insert into knowledge.source_document_publications
  (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
select d.id, sv.source_id, 'title', 'syntetisk binding for samtidighetsprøven',
       sv.retrieved_by_actor_id
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = '7e000000-0000-4000-8000-000000000002'
on conflict on constraint source_document_publications_pairing_key do nothing;

insert into knowledge.full_text_readability_checks
  (source_version_id, source_document_id, character_count, letter_count,
   line_count, table_row_count, table_declaration_count)
select sv.id, d.id, 20000, 15000, 400, 12, 3
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = '7e000000-0000-4000-8000-000000000002'
on conflict on constraint full_text_readability_checks_source_version_key do nothing;

-- ----------------------------------------------------------------------------
-- Modelltildelingen. Uten den er oppgaven blokkert av at ingen KI-tjeneste er
-- valgt, og prøvene ville ikke sagt noe om uttaket.
-- ----------------------------------------------------------------------------
insert into provenance.role_model_assignments
  (agent_role, capacity, provider, model, model_version, model_version_disclosure,
   valid_from, registered_by_actor_id, reason)
select 'evidence_extraction', 'semantic', 'antidep-test', 'laaseprove-ekstraksjon',
       provenance.unexposed_model_version(), 'not_exposed', now() - interval '1 hour',
       a.id, 'Samtidighetsprøvens tjeneste for ekstraksjonsleddet.'
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (
    select 1 from provenance.role_model_assignments b
    where b.agent_role = 'evidence_extraction' and b.capacity = 'semantic'
      and b.valid_to is null);

-- ----------------------------------------------------------------------------
-- Oppgaven. Én ekte handoff-jobb, med den strukturelle raden som gjør den til
-- en ekstern agentoppgave framfor en jobb Antideps egne kjørere skal ta.
-- ----------------------------------------------------------------------------
insert into workflow.pipeline_jobs
  (id, agent_role, job_key, input_manifest, enqueued_by_actor_id)
select '7e000000-0000-4000-8000-00000000000a', 'evidence_extraction',
       'laaseprove-runner:ekstraksjon',
       jsonb_build_object(
         'source_version_id', '7e000000-0000-4000-8000-000000000002',
         'drug_ids', jsonb_build_array(d.id),
         'outcome_concept_ids', jsonb_build_array(c.id)),
       '7e000000-0000-4000-8000-0000000000e1'
from catalog.drugs d, catalog.clinical_concepts c
where d.canonical_name = 'sertralin'
  and c.canonical_label = 'vektendring' and c.concept_type = 'outcome';

insert into workflow.agent_handoff_jobs (pipeline_job_id, registered_by_actor_id)
values ('7e000000-0000-4000-8000-00000000000a', '7e000000-0000-4000-8000-0000000000e1');

-- ----------------------------------------------------------------------------
-- Kjøreren og tokenet.
--
-- Databasen lagrer bare fingeravtrykket. Verdien står i db-lock-test.sh, og den
-- gir arbeid i nøyaktig ett agentledd i en lokal testdatabase.
-- ----------------------------------------------------------------------------
-- Perioden begynner der den forrige sluttet, som i api.register_agent_runner:
-- to perioder i det samme leddet kan ikke overlappe, og en kjører ryddet bort
-- rett over ble avsluttet i dette øyeblikket.
insert into workflow.agent_runner_connections
  (id, connection_key, display_name, agent_role, platform_agent_reference,
   platform_model_disclosure, valid_from, registered_by_actor_id, registration_reason)
select '7e000000-0000-4000-8000-0000000000c1', 'agent-runner:laaseprove',
       'Kjøreren i samtidighetsprøven', 'evidence_extraction',
       'Låseprøvens agent', 'not_exposed',
       greatest(statement_timestamp(),
                coalesce(max(c.valid_to), statement_timestamp())),
       '7e000000-0000-4000-8000-0000000000e1',
       'Bare til scripts/db-lock-test.sh.'
from workflow.agent_runner_connections c
where c.agent_role = 'evidence_extraction'
   or c.connection_key = 'agent-runner:laaseprove'
   or c.platform_agent_reference = 'Låseprøvens agent';

insert into workflow.agent_runner_clients (client_id, client_name, redirect_uris)
values ('7e000000000000000000000000000e11', 'Klienten i samtidighetsprøven',
        array['https://laaseprove.example/callback'])
on conflict (client_id) do nothing;

-- Tokenet bærer den MCP-serveren det gjelder for (RFC 8707). Prøven kaller
-- databasefunksjonene direkte og oppgir ingen adresse å kontrollere mot, men
-- raden skal likevel være en lovlig token-rad.
insert into workflow.agent_runner_secrets
  (kind, secret_hash, connection_id, client_id, resource, expires_at)
values ('access_token',
        workflow.agent_runner_secret_hash(
          'access_token',
          '7e00000000000000000000000000000000000000000000000000000000000001'),
        '7e000000-0000-4000-8000-0000000000c1', '7e000000000000000000000000000e11',
        'https://laaseprove.example/mcp',
        now() + interval '1 day');

commit;
