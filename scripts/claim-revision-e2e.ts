// ============================================================================
// Hele forløpet «ny forskning på en påstand som finnes» → ny kandidat
//
// pgTAP prøver SQL, og vitest prøver TypeScript med doble for databasen.
// Grensen mellom dem — at feltnavnene redaktørflaten leser, er nøyaktig de
// `api`-funksjonene svarer med, og at parameternavnene den sender, er nøyaktig
// de funksjonene tar imot — er ikke prøvd av noen av dem. Et felt som skiftet
// navn i SQL-en ville gått gjennom hver eneste enhetsprøve og først blitt
// synlig i produksjon.
//
// Denne kjøringen går hele veien, mot den lokale stacken, gjennom de ekte
// api-funksjonene og med de ekte leserne i `src/lib/claim-revision.ts`:
//
//   1. en etablert, publisert påstand står i basen
//   2. ny, kontrollert evidens kommer til om det samme virkestoffet og
//      endepunktet — og kjeden synteserer den *ikke* om igjen
//   3. en uinnlogget ser at arbeidet venter på en redaksjonell avgjørelse, i
//      vanlig språk og uten én eneste intern verdi
//   4. en innlogget uten redaktørmandat kommer ikke til oppgaven
//   5. redaktøren åpner oppgaven på et ugjennomsiktig håndtak, og ser
//      påstanden og den nye forskningen — ingen uuid
//   6. en beslutning tatt på et foreldet evidensgrunnlag avvises
//   7. redaktøren beslutter revisjon, og Antidep bygger synteseoppgaven selv,
//      med hele det gjeldende grunnlaget og med påstanden den skal gjelde
//   8. oppgaven er ute av den åpne oversikten og ute av redaktørkøen
//   9. resten av kjeden går som før, fram til en ny kandidat til sluttkontroll
//  10. og den forrige publiseringen står uendret
//
// De semantiske agentleddene og de deterministiske kontrollene utføres her med
// databasens egne skriveveier framfor med en kjører: det er ikke de som prøves,
// og de har sine egne prøver (supabase/tests/810, 830, scripts/agent-chain-test).
// Det som prøves her, er den nye flaten og den nye tilstanden — ende til ende,
// over den ekte Data API-en.
//
// Ingen modell kalles, og ingen nøkkel finnes.
// ============================================================================

import { randomUUID } from 'node:crypto'

import { createClient } from '@supabase/supabase-js'

import {
  parseClaimRevisionOutcome,
  parseClaimRevisionQueue,
  parseClaimRevisionTask,
} from '../src/lib/claim-revision.ts'
import { parseWorkBoard } from '../src/lib/work-board.ts'
import type { Database } from '../src/types/database.ts'
import { check, psql, q, readLocalStackConfig, userToken } from './local-stack.ts'

const config = readLocalStackConfig(process.argv.slice(2))

// Nye id-er for hver kjøring. Fiksturet er et forløp og ikke et stillas: en
// gjenbrukt påstand ville allerede hatt oppgaven fra forrige kjøring liggende,
// og prøven ville bestått uten å ha prøvd noe.
const RUN = randomUUID().slice(0, 8)
const EDITOR_USER = randomUUID()
const REVIEWER_USER = randomUUID()
const PUBLISHER_USER = randomUUID()
const CLINICIAN_USER = randomUUID()
const TOPIC = randomUUID()
const SOURCE_OLD = randomUUID()
const SOURCE_NEW = randomUUID()
const VERSION_OLD = randomUUID()
const VERSION_NEW = randomUUID()
const EVIDENCE_BASE = randomUUID()
const EVIDENCE_NEW = randomUUID()
const EVIDENCE_EXTRA = randomUUID()
const CLAIM = randomUUID()
const REVISION_ONE = randomUUID()
const REVISION_TWO = randomUUID()

const UUID_SOMEWHERE = /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-/i

function client(userId: string | null) {
  return createClient<Database, 'api'>(config.apiUrl, config.anonKey, {
    db: { schema: 'api' },
    auth: { persistSession: false, autoRefreshToken: false },
    ...(userId === null
      ? {}
      : { global: { headers: { Authorization: `Bearer ${userToken(config, userId)}` } } }),
  })
}

type Client = ReturnType<typeof client>

async function rpc(caller: Client, fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await caller.rpc(fn as never, args as never)
  if (error !== null) {
    throw new Error(`${fn}: ${error.message}`)
  }
  return data
}

/** Kallet skal avvises. Returnerer avvisningen, eller kaster om den uteble. */
async function rejected(
  caller: Client,
  fn: string,
  args: Record<string, unknown>,
): Promise<string> {
  const { error } = await caller.rpc(fn as never, args as never)
  if (error === null) {
    throw new Error(`${fn} ble ikke avvist, og det skulle den vært.`)
  }
  return error.message
}

/**
 * Én bestått ekstraksjonskontroll av ett funn.
 *
 * To rader, fordi den kildeomfattende halvdelen av et globalt fravær bare kan
 * føres opp av en maskinell kontroll med sin egen kjøring (migrasjon 005ae).
 */
function controlEvidence(evidenceId: string): void {
  const run = randomUUID()
  psql(
    config,
    `
    insert into provenance.agent_runs
      (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
       prompt_template_version, pipeline_version, input_manifest)
    select ${q(run)}, ai.id, ai.actor_id, 'extraction_verification', 'antidep',
           'deterministic-extraction-check', '1.0.0',
           'extraction-verification/deterministic/1', 'antidep-evidence/1',
           '{"mode": "revision-e2e"}'::jsonb
    from provenance.agent_identities ai
    where ai.identity_key = 'agent-identity:extraction-verification-01';

    insert into workflow.evidence_verifications
      (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
       source_access, checked_fields, rationale, verified_at, agent_run_id)
    select e.id, e.created_by_actor_id, a.id, 'verified', 'verifiable_representation',
           array['source_wide_absence']::workflow.evidence_check_field[],
           'Revisjonsprøven: et søk gjennom hele representasjonen fant ingen verdi.',
           now() - interval '1 hour', ${q(run)}
    from knowledge.evidence_items e
    cross join provenance.actors a
    where e.id = ${q(evidenceId)} and a.actor_key = 'agent:extraction-verification'
      and 'source_wide_absence' = any (workflow.required_check_fields(e.id));

    insert into workflow.evidence_verifications
      (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
       source_access, checked_fields, rationale, verified_at)
    select e.id, e.created_by_actor_id, a.id, 'verified', 'verifiable_representation',
           array_remove(workflow.required_check_fields(e.id),
                        'source_wide_absence'::workflow.evidence_check_field),
           'Revisjonsprøven: fullstendig kontrollert ekstraksjon.', now()
    from knowledge.evidence_items e
    cross join provenance.actors a
    where e.id = ${q(evidenceId)} and a.actor_key = 'agent:extraction-verification';
    `,
  )
}

/** Kildestøttekontrollen av én påstandsrevisjon, som Antideps egen kode gjør den. */
function controlClaim(revisionId: string): void {
  const run = randomUUID()
  psql(
    config,
    `
    insert into provenance.agent_runs
      (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
       prompt_template_version, pipeline_version, input_manifest)
    select ${q(run)}, ai.id, ai.actor_id, 'citation_support_verification', 'antidep',
           'deterministic-claim-check', '1.0.0', 'claim-verification/deterministic/1',
           'antidep-evidence/1', '{"mode": "revision-e2e"}'::jsonb
    from provenance.agent_identities ai
    where ai.identity_key = 'agent-identity:citation-support-verification-01';

    insert into workflow.claim_verifications
      (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
       source_access, source_support, population_match, comparator_match, timeframe_match,
       direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
       rationale, verified_at, agent_run_id)
    select r.id, r.created_by_actor_id, a.id, 'verified', 'verifiable_representation',
           'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
           'Revisjonsprøven: påstanden dekkes av grunnlaget.', now(), ${q(run)}
    from knowledge.claim_revisions r
    cross join provenance.actors a
    where r.id = ${q(revisionId)} and a.actor_key = 'agent:citation-support-verification';

    insert into workflow.claim_verification_citations
      (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
       source_access, source_version_id, checked_content_hash, relationship_supported)
    select v.id, v.claim_revision_id, l.id, l.evidence_item_id, 'verifiable_representation',
           e.source_version_id, sv.content_hash, 'ok'
    from workflow.claim_verifications v
    join knowledge.claim_evidence_links l on l.claim_revision_id = v.claim_revision_id
    join knowledge.evidence_items e on e.id = l.evidence_item_id
    join knowledge.source_versions sv on sv.id = e.source_version_id
    where v.claim_revision_id = ${q(revisionId)} and v.agent_run_id = ${q(run)};
    `,
  )
}

/** Evidensvurderingen. Den registrerte vurderingen forsegler kandidaten selv. */
function assessClaim(revisionId: string): void {
  const run = randomUUID()
  psql(
    config,
    `
    insert into provenance.agent_runs
      (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
       prompt_template_version, pipeline_version, input_manifest)
    select ${q(run)}, ai.id, ai.actor_id, 'evidence_assessment', 'antidep',
           'proposal-registered-assessment', '1.0.0', 'evidence-assessment/proposal/1',
           'antidep-evidence/1', '{"mode": "revision-e2e"}'::jsonb
    from provenance.agent_identities ai
    where ai.identity_key = 'agent-identity:evidence-assessment-01';

    insert into knowledge.evidence_assessments
      (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
       risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
       rationale, evidence_gap, assessed_at, created_by_actor_id, agent_run_id)
    select r.id, r.knowledge_type, 'grade', 'low', 'serious', 'not_assessable',
           'not_serious', 'serious', 'not_assessable',
           'Revisjonsprøven: vurdering med alle nødvendige domener.',
           'Syntetisk grunnlag har med vilje begrenset dekning.', now(), a.id, ${q(run)}
    from knowledge.claim_revisions r
    cross join provenance.actors a
    where r.id = ${q(revisionId)} and a.actor_key = 'agent:evidence-assessment';
    `,
  )
}

// ----------------------------------------------------------------------------
// Fikstur: en etablert påstand med én lenket, kontrollert kilde.
//
// Påstanden lages før kontrollen av det første funnet, slik at kjeden ser en
// påstand som finnes — nøyaktig den tilstanden synteseagenten ville etterlatt
// etter å ha besvart oppgaven sin. Alt er syntetisk, og ingenting av det er
// klinisk innhold.
// ----------------------------------------------------------------------------
function seed(): void {
  psql(
    config,
    `
    insert into auth.users (id, email) values
      (${q(EDITOR_USER)}, 'revisjon-${RUN}-redaktor@test.invalid'),
      (${q(REVIEWER_USER)}, 'revisjon-${RUN}-fagperson@test.invalid'),
      (${q(PUBLISHER_USER)}, 'revisjon-${RUN}-publisher@test.invalid'),
      (${q(CLINICIAN_USER)}, 'revisjon-${RUN}-kliniker@test.invalid');

    insert into catalog.clinical_concepts (id, canonical_label, concept_type)
    values (${q(TOPIC)}, 'søvnlengde i revisjonsprøven ${RUN}', 'outcome');

    insert into provenance.actors
      (actor_type, actor_key, display_name, description, auth_user_id)
    values
      ('human', 'human:revisjon-${RUN}-redaktor', 'Redaktør ${RUN}',
       'Syntetisk redaktør for revisjonsprøven.', ${q(EDITOR_USER)}),
      ('human', 'human:revisjon-${RUN}-fagperson', 'Fagperson ${RUN}',
       'Syntetisk fagperson med sluttkontrollmandat.', ${q(REVIEWER_USER)}),
      ('human', 'human:revisjon-${RUN}-publisher', 'Publisher ${RUN}',
       'Syntetisk publisher.', ${q(PUBLISHER_USER)}),
      ('human', 'human:revisjon-${RUN}-kliniker', 'Kliniker ${RUN}',
       'Syntetisk kliniker uten noe mandat.', ${q(CLINICIAN_USER)});

    insert into workflow.user_roles
      (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
    select v.user_id::uuid, v.role_code::workflow.app_role, v.scope::uuid,
           now() - interval '1 hour',
           (select id from provenance.actors
            where actor_key = 'human:revisjon-${RUN}-redaktor'),
           'Revisjonsprøvens egen tildeling.'
    from (values
      (${q(EDITOR_USER)}, 'editor', null),
      (${q(REVIEWER_USER)}, 'reviewer', ${q(TOPIC)}),
      (${q(PUBLISHER_USER)}, 'publisher', null)
    ) as v(user_id, role_code, scope);

    insert into knowledge.sources
      (id, source_type, title, authors_or_issuer, publisher_or_journal, publication_date,
       publication_date_precision, created_by_actor_id)
    select v.id::uuid, 'journal_article', v.title, v.authors, 'Tidsskrift ${RUN}',
           v.year::date, 'year', a.id
    from (values
      (${q(SOURCE_OLD)}, 'Den etablerte artikkelen i revisjonsprøven ${RUN}',
       'Testforfatter A m.fl.', '2019-01-01'),
      (${q(SOURCE_NEW)}, 'Den nye artikkelen i revisjonsprøven ${RUN}',
       'Testforfatter B m.fl.', '2026-01-01')
    ) as v(id, title, authors, year)
    cross join provenance.actors a
    where a.actor_key = 'agent:evidence-extraction';

    insert into knowledge.source_documents
      (sha256, byte_size, media_type, content, stored_by_actor_id)
    select knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
           'application/pdf', g.bytes, a.id
    from (select convert_to('%PDF-1.7' || E'\\nrevisjonsprove-${RUN}\\n%%EOF\\n', 'UTF8')
            as bytes) g
    cross join provenance.actors a
    where a.actor_key = 'agent:evidence-extraction'
    on conflict (sha256) do nothing;

    insert into knowledge.source_versions
      (id, source_id, retrieved_at, retrieved_from, content_hash, storage_reference,
       representation, retrieved_by_actor_id, document_sha256, document_byte_size,
       document_media_type, text_extraction_tool, text_extraction_tool_version,
       text_extraction_arguments, text_extraction_transform)
    select v.id::uuid, v.source_id::uuid, now(),
           'https://example.test/revisjon-${RUN}/' || v.id,
           knowledge.source_version_content_hash('Syntetisk kildetekst ' || v.id),
           'private://revisjon-${RUN}-' || v.id || '.pdf', 'full_text', a.id,
           knowledge.source_document_fingerprint(g.bytes), octet_length(g.bytes),
           'application/pdf', 'pdftotext', '24.02.0',
           '-bbox-layout -enc UTF-8 -eol unix', 'antidep-reading-order@2'
    from (values
      (${q(VERSION_OLD)}, ${q(SOURCE_OLD)}),
      (${q(VERSION_NEW)}, ${q(SOURCE_NEW)})
    ) as v(id, source_id)
    cross join (select convert_to('%PDF-1.7' || E'\\nrevisjonsprove-${RUN}\\n%%EOF\\n', 'UTF8')
                  as bytes) g
    cross join provenance.actors a
    where a.actor_key = 'agent:evidence-extraction';

    insert into knowledge.source_document_publications
      (source_document_id, source_id, binding_basis, binding_evidence, bound_by_actor_id)
    select d.id, sv.source_id, 'title', 'syntetisk binding for revisjonsprøven',
           sv.retrieved_by_actor_id
    from knowledge.source_versions sv
    join knowledge.source_documents d on d.sha256 = sv.document_sha256
    where sv.id in (${q(VERSION_OLD)}, ${q(VERSION_NEW)})
    on conflict on constraint source_document_publications_pairing_key do nothing;

    insert into knowledge.full_text_readability_checks
      (source_version_id, source_document_id, character_count, letter_count,
       line_count, table_row_count, table_declaration_count)
    select sv.id, d.id, 20000, 15000, 400, 12, 3
    from knowledge.source_versions sv
    join knowledge.source_documents d on d.sha256 = sv.document_sha256
    where sv.id in (${q(VERSION_OLD)}, ${q(VERSION_NEW)});

    insert into knowledge.evidence_items (
      id, source_id, source_version_id, design_code, population_id,
      population_availability, population_detail, sample_size, sample_size_availability,
      intervention_drug_id, comparator_kind, outcome_concept_id, outcome_detail,
      timepoint_availability, reported_direction, estimate_availability,
      confidence_interval_availability, source_locator, extraction_method,
      created_by_actor_id
    )
    select v.id::uuid, v.source_id::uuid, v.version_id::uuid, 'randomized_controlled_trial',
           p.id, 'reported_value', 'Voksne med depressiv lidelse i revisjonsprøven.',
           120, 'reported_value', d.id, 'none', ${q(TOPIC)}, v.detail,
           'not_reported', 'increase', 'not_reported', 'not_reported',
           v.locator, 'ai_assisted', a.id
    from (values
      (${q(EVIDENCE_BASE)}, ${q(SOURCE_OLD)}, ${q(VERSION_OLD)},
       'Lengre søvn ved åtte uker.', 'Tabell 1'),
      (${q(EVIDENCE_NEW)}, ${q(SOURCE_NEW)}, ${q(VERSION_NEW)},
       'Kortere søvn ved tolv uker i en ny studie.', 'Tabell 2'),
      (${q(EVIDENCE_EXTRA)}, ${q(SOURCE_NEW)}, ${q(VERSION_NEW)},
       'Et tredje funn om søvnlengde.', 'Tabell 3')
    ) as v(id, source_id, version_id, detail, locator)
    cross join catalog.drugs d
    cross join catalog.populations p
    cross join provenance.actors a
    where d.canonical_name = 'sertralin'
      and p.canonical_label = 'voksne med depressiv lidelse'
      and a.actor_key = 'agent:evidence-extraction';

    insert into knowledge.claims
      (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
    select ${q(CLAIM)}, 'evidence_synthesis', ${q(TOPIC)}, d.id, a.id
    from catalog.drugs d cross join provenance.actors a
    where d.canonical_name = 'sertralin' and a.actor_key = 'agent:claim-synthesis';

    insert into knowledge.claim_revisions
      (id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
       comparator_kind, direction, uncertainty_summary, created_by_actor_id)
    select ${q(REVISION_ONE)}, c.id, 1, 'evidence_synthesis', c.subject_drug_id,
           'Sertralin er forbundet med noe lengre søvn ved åtte uker.',
           'Gjelder bare som testdata i revisjonsprøven.', 'none', 'increase',
           'Testusikkerhet: grunnlaget er syntetisk.', c.created_by_actor_id
    from knowledge.claims c where c.id = ${q(CLAIM)};

    insert into knowledge.claim_evidence_links
      (claim_revision_id, evidence_item_id, relationship_type, directness,
       relevance_note, created_by_actor_id)
    select ${q(REVISION_ONE)}, ${q(EVIDENCE_BASE)}, 'supports', 'direct',
           'Den opprinnelige lenken i revisjonsprøven.', c.created_by_actor_id
    from knowledge.claims c where c.id = ${q(CLAIM)};
    `,
  )
}

function candidateFor(revisionId: string): { readonly id: string; readonly digest: string } {
  return {
    id: psql(
      config,
      `select id from knowledge.candidates where claim_revision_id = ${q(revisionId)}`,
    ),
    digest: psql(
      config,
      `select candidate_digest from knowledge.candidates
       where claim_revision_id = ${q(revisionId)}`,
    ),
  }
}

async function main(): Promise<void> {
  seed()
  controlEvidence(EVIDENCE_BASE)
  controlClaim(REVISION_ONE)
  assessClaim(REVISION_ONE)

  const anonymous = client(null)
  const editor = client(EDITOR_USER)
  const reviewer = client(REVIEWER_USER)
  const publisher = client(PUBLISHER_USER)
  const clinician = client(CLINICIAN_USER)

  console.log('En etablert, publisert påstand')
  const first = candidateFor(REVISION_ONE)
  check('kjeden førte den første påstanden fram til en kandidat', first.id.length > 0)
  await rpc(reviewer, 'record_candidate_final_control', {
    p_candidate_id: first.id,
    p_seen_candidate_digest: first.digest,
    p_decision: 'approved',
    p_rationale: 'Revisjonsprøven: fagpersonen godkjenner det ferdige produktet.',
  })
  await rpc(publisher, 'publish_candidate', {
    p_candidate_id: first.id,
    p_seen_candidate_digest: first.digest,
    p_reason: 'Revisjonsprøven: første publisering.',
  })
  check(
    'og den er publisert — dette er en påstand Antidep allerede sier noe med',
    psql(
      config,
      `select current_published_revision_id from knowledge.claims where id = ${q(CLAIM)}`,
    ) === REVISION_ONE,
  )
  check(
    'og evidensen den hviler på, er ikke ny evidens',
    psql(
      config,
      `select count(*) from workflow.claim_revision_reviews where claim_id = ${q(CLAIM)}`,
    ) === '0',
  )

  console.log('Ny, kontrollert forskning om det samme')
  controlEvidence(EVIDENCE_NEW)
  controlEvidence(EVIDENCE_EXTRA)
  check(
    'kjeden synteserer ikke om igjen en påstand som allerede finnes',
    psql(
      config,
      `select count(*) from workflow.pipeline_jobs
       where agent_role = 'claim_synthesis'
         and input_manifest ->> 'topic_concept_id' = ${q(TOPIC)}`,
    ) === '0',
  )
  check(
    'men tilstanden er eksplisitt: én rad venter på en redaksjonell avgjørelse',
    psql(
      config,
      `select count(*) from workflow.claim_revision_reviews where claim_id = ${q(CLAIM)}`,
    ) === '1',
  )

  console.log('Den åpne arbeidsoversikten, uten innlogging')
  // Håndtaket oversikten viser, er databasens eget avtrykk av radens id. Det
  // slås opp her — utenfor flaten — slik at prøven kan peke på nøyaktig denne
  // raden i en oversikt som også bærer andre kjøringers arbeid.
  const boardReference = psql(
    config,
    `select workflow.work_board_reference(id) from workflow.claim_revision_reviews
     where claim_id = ${q(CLAIM)}`,
  )
  const board = parseWorkBoard(await rpc(anonymous, 'public_work_board', {}))
  const waiting = board.filter((item) => item.reference === boardReference)
  check('den uinnloggede ser at ny kunnskap venter på en redaktør', waiting.length === 1)
  check(
    'i produktets eget vokabular, og ikke som en teknisk tilstand',
    waiting.every(
      (item) => item.activity === 'claim_revision' && item.waitingFor === 'editorial_decision',
    ),
  )
  check(
    'den står som planlagt arbeid, og aldri som stoppet',
    waiting.every((item) => item.status === 'planned'),
  )
  check(
    'og den sier hvilket virkestoff det gjelder',
    waiting.some((item) => item.subjects.includes('sertralin')),
  )
  const boardText = JSON.stringify(board.filter((item) => item.activity === 'claim_revision'))
  check('uten én eneste uuid', !UUID_SOMEWHERE.test(boardText), boardText)
  check(
    'uten påstandstekst, agentrolle eller avtrykk',
    !/Sertralin er forbundet|claim_synthesis|sha256/i.test(boardText),
    boardText,
  )

  console.log('Grensen rundt den redaksjonelle flaten')
  check(
    'en uinnlogget kommer ikke til revisjonskøen',
    (await rejected(anonymous, 'claim_revision_queue', {})).length > 0,
  )
  check(
    'og en innlogget uten redaktørmandat heller ikke',
    (await rejected(clinician, 'claim_revision_queue', {})).includes('editor'),
  )

  console.log('Redaktøren åpner oppgaven')
  const queue = parseClaimRevisionQueue(await rpc(editor, 'claim_revision_queue', {}))
  const entry = queue.find((item) => item.topic === `søvnlengde i revisjonsprøven ${RUN}`)
  if (entry === undefined) {
    throw new Error('Revisjonsoppgaven sto ikke i redaktørkøen.')
  }
  check('køen navngir påstanden slik den står i dag', entry.statement.startsWith('Sertralin er'))
  check('virkestoffet den gjelder', entry.subjectDrug === 'sertralin')
  check('hvor mye ny forskning som er kommet til', entry.newEvidenceCount === 2)
  check('og at den er publisert og i bruk', entry.published)
  check(
    'køen bærer ingen uuid',
    !UUID_SOMEWHERE.test(JSON.stringify({ ...entry, evidenceBasis: '' })),
  )

  const task = parseClaimRevisionTask(
    await rpc(editor, 'claim_revision_for_decision', { p_reference: entry.reference }),
  )
  check('oppgaven viser hver ny artikkel', task.newEvidence.length === 2)
  check(
    'navngitt med bibliografien sin',
    task.newEvidence.every((item) => item.articleTitle.includes('Den nye artikkelen')),
  )
  check(
    'med studiedesignen og populasjonen den faglige avgjørelsen trenger',
    task.newEvidence.every(
      (item) =>
        item.studyDesign === 'randomized_controlled_trial' &&
        item.population === 'voksne med depressiv lidelse',
    ),
  )
  check(
    'og ingen uuid i det redaktøren får se',
    !UUID_SOMEWHERE.test(JSON.stringify({ ...task, evidenceBasis: '' })),
  )

  console.log('Fail-closed: en beslutning på et foreldet grunnlag')
  const stale = await rejected(editor, 'record_claim_revision_decision', {
    p_reference: entry.reference,
    p_decision: 'revise',
    p_seen_evidence_basis: `sha256-v1:${'a'.repeat(64)}`,
    p_note: null,
  })
  check('avvises', stale.includes('Evidensgrunnlaget er endret'), stale)
  const noReason = await rejected(editor, 'record_claim_revision_decision', {
    p_reference: entry.reference,
    p_decision: 'set_aside',
    p_seen_evidence_basis: task.evidenceBasis,
    p_note: null,
  })
  check('og en konklusjon uten begrunnelse avvises', noReason.includes('begrunnelse'), noReason)

  console.log('Redaktøren beslutter revisjon')
  const outcome = parseClaimRevisionOutcome(
    await rpc(editor, 'record_claim_revision_decision', {
      p_reference: entry.reference,
      p_decision: 'revise',
      p_seen_evidence_basis: task.evidenceBasis,
      p_note: 'Den nye studien peker i motsatt retning av dagens formulering.',
    }),
  )
  check('beslutningen registreres', outcome.recorded)
  check(
    'Antidep bygger selv synteseoppgaven, og nøyaktig én',
    psql(
      config,
      `select count(*) from workflow.pipeline_jobs
       where agent_role = 'claim_synthesis'
         and input_manifest ->> 'topic_concept_id' = ${q(TOPIC)}`,
    ) === '1',
  )
  check(
    'oppgaven sier hvilken påstand revisjonen gjelder',
    psql(
      config,
      `select input_manifest ->> 'claim_id' from workflow.pipeline_jobs
       where agent_role = 'claim_synthesis'
         and input_manifest ->> 'topic_concept_id' = ${q(TOPIC)}`,
    ) === CLAIM,
  )
  check(
    'og bærer hele det gjeldende evidensgrunnlaget',
    psql(
      config,
      `select jsonb_array_length(input_manifest -> 'evidence_item_ids')
       from workflow.pipeline_jobs
       where agent_role = 'claim_synthesis'
         and input_manifest ->> 'topic_concept_id' = ${q(TOPIC)}`,
    ) === '3',
  )

  const repeated = parseClaimRevisionOutcome(
    await rpc(editor, 'record_claim_revision_decision', {
      p_reference: entry.reference,
      p_decision: 'revise',
      p_seen_evidence_basis: task.evidenceBasis,
      p_note: 'Den samme beslutningen en gang til.',
    }),
  )
  check('den samme beslutningen om igjen er den samme beslutningen', !repeated.recorded)

  console.log('Oppgaven er ute av begge flatene')
  const afterBoard = parseWorkBoard(await rpc(anonymous, 'public_work_board', {}))
  check(
    'den uinnloggede ser ikke lenger at noe venter på en redaktør for denne påstanden',
    !afterBoard.some((item) => item.reference === boardReference),
  )
  check(
    'og redaktørkøen har ikke lenger denne oppgaven',
    !parseClaimRevisionQueue(await rpc(editor, 'claim_revision_queue', {})).some(
      (item) => item.reference === entry.reference,
    ),
  )
  check(
    'oppgaven kan ikke lenger åpnes',
    (await rejected(editor, 'claim_revision_for_decision', { p_reference: entry.reference }))
      .length > 0,
  )

  console.log('Resten av kjeden går som før')
  // Synteseagentens svar: en ny revisjon av den samme påstanden, med hele
  // grunnlaget lenket. Selve handoffen prøves i scripts/agent-runner-e2e.ts.
  psql(
    config,
    `
    insert into knowledge.claim_revisions
      (id, claim_id, revision_number, knowledge_type, subject_drug_id,
       supersedes_revision_id, statement, scope, comparator_kind, direction,
       uncertainty_summary, created_by_actor_id)
    select ${q(REVISION_TWO)}, c.id, 2, 'evidence_synthesis', c.subject_drug_id,
           ${q(REVISION_ONE)},
           'Sertralin har usikker effekt på søvnlengde; nyere data spriker.',
           'Gjelder bare som testdata i revisjonsprøven.', 'none', 'no_clear_difference',
           'Testusikkerhet: to studier peker i hver sin retning.', c.created_by_actor_id
    from knowledge.claims c where c.id = ${q(CLAIM)};

    insert into knowledge.claim_evidence_links
      (claim_revision_id, evidence_item_id, relationship_type, directness,
       relevance_note, created_by_actor_id)
    select ${q(REVISION_TWO)}, e.id,
           case when e.id = ${q(EVIDENCE_NEW)}
                then 'contradicts'::knowledge.claim_evidence_relationship
                else 'supports'::knowledge.claim_evidence_relationship end,
           'direct', 'Lenke i den reviderte påstanden.', c.created_by_actor_id
    from knowledge.claims c
    cross join knowledge.evidence_items e
    where c.id = ${q(CLAIM)}
      and e.id in (${q(EVIDENCE_BASE)}, ${q(EVIDENCE_NEW)}, ${q(EVIDENCE_EXTRA)});
    `,
  )
  check(
    'den nye revisjonen legger kildestøttekontrollen i køen, som enhver revisjon',
    psql(
      config,
      `select count(*) from workflow.pipeline_jobs
       where job_key = 'kontroll:kildestotte:${REVISION_TWO}'`,
    ) === '1',
  )
  controlClaim(REVISION_TWO)
  check(
    'og den beståtte kontrollen legger evidensvurderingen i køen',
    psql(
      config,
      `select count(*) from workflow.pipeline_jobs
       where agent_role = 'evidence_assessment'
         and input_manifest ->> 'claim_revision_id' = ${q(REVISION_TWO)}`,
    ) === '1',
  )
  assessClaim(REVISION_TWO)

  const second = candidateFor(REVISION_TWO)
  check('den registrerte vurderingen forsegler en ny kandidat', second.id.length > 0)
  check(
    'som ligger til sluttkontroll, og ikke er publisert',
    psql(
      config,
      `select count(*) from workflow.candidate_final_controls
       where candidate_id = ${q(second.id)}`,
    ) === '0',
  )

  console.log('Og historikken står')
  check('den forrige kandidaten er uendret', candidateFor(REVISION_ONE).digest === first.digest)
  check(
    'den forrige publiseringen står som den sto',
    psql(
      config,
      `select count(*) from knowledge.publication_events
       where revision_id = ${q(REVISION_ONE)}`,
    ) === '1',
  )
  check(
    'og det publiserte innholdet endres ikke av at en ny revisjon er bygget',
    psql(
      config,
      `select current_published_revision_id from knowledge.claims where id = ${q(CLAIM)}`,
    ) === REVISION_ONE,
  )
  check(
    'ingenting av dette ble til et teknisk problem',
    psql(
      config,
      `select count(*) from workflow.technical_incidents
       where area = 'automatic_task' and signature like 'kjede:%' and resolved_at is null`,
    ) === '0',
  )
}

await main()
