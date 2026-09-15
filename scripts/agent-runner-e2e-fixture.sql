-- ============================================================================
-- Grunnlaget ende-til-ende-prøven av den autonome kjøreren kjører mot
--
-- Prøven (scripts/agent-runner-e2e.ts) går hele veien gjennom Antideps private
-- MCP-app: tilkobling, uttak, oppgave, svar og registrering. Den trenger derfor
-- én ekte, utførbar handoff-oppgave — og den skal ikke bygge den selv, fordi en
-- prøve som seedet gjennom en skrivevei, ville vært en prøve av den veien.
--
-- Alt her er syntetisk. Ingen linje i artikkelen er en klinisk påstand, og
-- teksten er ikke hentet fra noen publikasjon.
--
-- Fiksturen er idempotent og bygges opp på nytt hver kjøring. Radene i workflow
-- og knowledge er append-only, så oppryddingen kjører med replikeringstriggerne
-- av — bare for oppryddingen, og bare på denne fiksturens egne rader.
--
-- Kjøres av scripts/agent-runner-e2e.ts. Ingenting her hører hjemme i en
-- migrasjon: dette er prøvedata, ikke kunnskap (supabase/README.md).
-- ============================================================================
\set ON_ERROR_STOP on

begin;

set local session_replication_role = replica;

delete from workflow.agent_handoff_imports i
where i.pipeline_job_id in (
  select j.id from workflow.pipeline_jobs j
  where j.enqueued_by_actor_id = '7f000000-0000-4000-8000-0000000000e1');
-- Tilkoblingen slettes ikke. Ett agentledd har høyst én gjeldende kjører. En annen prøve kan ha lagt igjen
-- sin egen; den trekkes tilbake gjennom den vanlige veien framfor å slettes, så
-- regelen prøves og ikke omgås.
update workflow.agent_runner_connections c
set valid_to = statement_timestamp(),
    revoked_by_actor_id = (select a.id from provenance.actors a
                           where a.actor_key = 'human:peder-holman'),
    revocation_reason = 'Ryddet av ende-til-ende-prøven av den autonome kjøreren.'
where c.agent_role = 'evidence_extraction' and c.valid_to is null;

update workflow.agent_runner_secrets s
set revoked_at = statement_timestamp()
where s.revoked_at is null
  and s.connection_id in (
    select c.id from workflow.agent_runner_connections c
    where c.agent_role = 'evidence_extraction');
delete from knowledge.evidence_field_groundings g
where g.evidence_item_id in (
  select e.id from knowledge.evidence_items e
  where e.source_id = '7f000000-0000-4000-8000-000000000001');
delete from knowledge.evidence_items e
where e.source_id = '7f000000-0000-4000-8000-000000000001';

delete from workflow.pipeline_job_runs r
where r.pipeline_job_id in (
  select j.id from workflow.pipeline_jobs j
  where j.enqueued_by_actor_id = '7f000000-0000-4000-8000-0000000000e1');
delete from workflow.agent_handoff_jobs h
where h.pipeline_job_id in (
  select j.id from workflow.pipeline_jobs j
  where j.enqueued_by_actor_id = '7f000000-0000-4000-8000-0000000000e1');
delete from workflow.pipeline_job_events ev
where ev.pipeline_job_id in (
  select j.id from workflow.pipeline_jobs j
  where j.enqueued_by_actor_id = '7f000000-0000-4000-8000-0000000000e1');
delete from provenance.agent_runs r
where r.input_manifest -> 'handoff' -> 'binding' ->> 'pipeline_job_id' in (
  select j.id::text from workflow.pipeline_jobs j
  where j.enqueued_by_actor_id = '7f000000-0000-4000-8000-0000000000e1');
delete from workflow.pipeline_jobs j
where j.enqueued_by_actor_id = '7f000000-0000-4000-8000-0000000000e1';

set local session_replication_role = origin;

-- ----------------------------------------------------------------------------
-- Redaktøren. Registrerer kjøreren og legger inn oppgaven, som et menneske med
-- mandat gjør det i agentarbeidsflaten.
-- ----------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email)
values ('7f000000-0000-4000-8000-0000000000e0',
        '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'e2e-redaktor@antidep.test')
on conflict (id) do nothing;

insert into provenance.actors
  (id, actor_key, actor_type, display_name, description, auth_user_id)
values ('7f000000-0000-4000-8000-0000000000e1', 'human:e2e-redaktor', 'human',
        'Redaktør for kjørerprøven ende-til-ende',
        'Bare til scripts/agent-runner-e2e.ts. Registrerer ingen faglig vurdering av reelt innhold.',
        '7f000000-0000-4000-8000-0000000000e0')
on conflict (id) do nothing;

insert into workflow.user_roles
  (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
select '7f000000-0000-4000-8000-0000000000e0', 'editor', null, now() - interval '1 year',
       a.id, 'Editor-tildeling for ende-til-ende-prøven av den autonome kjøreren.'
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (
    select 1 from workflow.user_roles ur
    where ur.user_id = '7f000000-0000-4000-8000-0000000000e0'
      and ur.role_code = 'editor'
  );

-- ----------------------------------------------------------------------------
-- Kilden, originalfilen, bindingen, lesbarheten og den private teksten.
--
-- Alle fem er krav den kliniske fulltekstgaten stiller, og fiksturen kommer
-- forbi dem uten å svekke en eneste av dem.
-- ----------------------------------------------------------------------------
create temporary table e2e_text on commit drop as
select E'Syntetisk artikkel for ende-til-ende-prøven av den autonome kjøreren.\n\n' ||
       E'Patients with major depressive disorder were randomised to open-label sertraline for twelve weeks.\n\n' ||
       E'Sixty sertraline-treated patients completed the trial and were analysed.\n\n' ||
       E'Mean percent weight change was 2.4% at endpoint with a 95% confidence interval from 1.6% to 3.2%.\n\n' ||
       E'The trial was limited by its open-label design and its single centre.\n' as text;

create temporary table e2e_pdf on commit drop as
select convert_to('%PDF-1.7' || E'\ne2e-runner\n%%EOF\n', 'UTF8') as bytes;

insert into knowledge.sources
  (id, source_type, title, authors_or_issuer, created_by_actor_id)
select '7f000000-0000-4000-8000-000000000001', 'journal_article',
       'Syntetisk kilde for ende-til-ende-prøven av kjøreren',
       'scripts/agent-runner-e2e.ts', a.id
from provenance.actors a
where a.actor_key = 'human:peder-holman'
  and not exists (select 1 from knowledge.sources s
                  where s.id = '7f000000-0000-4000-8000-000000000001');

insert into knowledge.source_documents
  (sha256, byte_size, media_type, content, stored_by_actor_id)
select knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
       'application/pdf', g.bytes, a.id
from e2e_pdf g
join provenance.actors a on a.actor_key = 'human:peder-holman'
on conflict (sha256) do nothing;

insert into knowledge.source_versions
  (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference, representation,
   retrieved_by_actor_id, document_sha256, document_byte_size, document_media_type,
   text_extraction_tool, text_extraction_tool_version, text_extraction_arguments,
   text_extraction_transform)
select '7f000000-0000-4000-8000-000000000002', '7f000000-0000-4000-8000-000000000001',
       now(), 'file:///e2e-runner.pdf',
       knowledge.source_version_content_hash(t.text),
       'private://e2e-runner.pdf', 'full_text', a.id,
       knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
       'application/pdf', 'pdftotext', '24.02.0',
       '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
from e2e_text t, e2e_pdf g
join provenance.actors a on a.actor_key = 'human:peder-holman'
where not exists (select 1 from knowledge.source_versions v
                  where v.id = '7f000000-0000-4000-8000-000000000002');

insert into knowledge.source_version_texts (source_version_id, representation, stored_by_actor_id)
select '7f000000-0000-4000-8000-000000000002', t.text, a.id
from e2e_text t
join provenance.actors a on a.actor_key = 'human:peder-holman'
where not exists (select 1 from knowledge.source_version_texts x
                  where x.source_version_id = '7f000000-0000-4000-8000-000000000002');

insert into knowledge.source_document_publications
  (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
select d.id, sv.source_id, 'title', 'syntetisk binding for ende-til-ende-prøven',
       sv.retrieved_by_actor_id
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = '7f000000-0000-4000-8000-000000000002'
on conflict on constraint source_document_publications_pairing_key do nothing;

insert into knowledge.full_text_readability_checks
  (source_version_id, source_document_id, character_count, letter_count,
   line_count, table_row_count, table_declaration_count)
select sv.id, d.id, 20000, 15000, 400, 12, 3
from knowledge.source_versions sv
join knowledge.source_documents d on d.sha256 = sv.document_sha256
where sv.id = '7f000000-0000-4000-8000-000000000002'
on conflict on constraint full_text_readability_checks_source_version_key do nothing;

commit;
