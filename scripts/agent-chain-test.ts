// Antidep 2 end-to-end database chain.
//
// The chain now runs the full delivery: a private full-text upload with
// server-owned file identity, publication binding and readability control; a
// durable, idempotent job; the real agent steps under separate model roles; a
// sealed candidate with visible source coverage; and a final control bound to
// exactly that candidate.
//
// The final control is performed by a named human actor, because that is what
// the rule requires — an agent identity cannot record one, and the test does
// not pretend otherwise. Publication is a separate, explicit action by a third
// human with the publisher mandate; the chain then reads the published content
// as a clinician, withdraws it and rolls back, and asserts that the history is
// append-only throughout.

import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createClient } from '@supabase/supabase-js'

import {
  createAgentClient,
  createEvidenceExtractionApi,
  createExtractionVerificationApi,
} from '../src/agents/agent-api.ts'
import { agentSecret } from '../src/agents/agent-credential.ts'
import { closeDraftingJob, JOB_FILES, openDraftingJob } from '../src/agents/drafting-job.ts'
import { runEvidenceExtraction } from '../src/agents/extraction-run.ts'
import { runExtractionVerification } from '../src/agents/extraction-verification-run.ts'
import { MODEL_ANSWER_VERSION } from '../src/agents/model-answer.ts'
import { EXTRACTION_VERIFICATION_PREMISES } from '../src/agents/pipeline-version.ts'
import { readProposalFile } from '../src/agents/proposal-files.ts'
import { documentsIn } from '../src/agents/source-document.ts'
import { createPipelineJobApi, jobKey } from '../src/agents/pipeline-job.ts'
import {
  parseAgentTask,
  parseAgentWorkQueue,
  parseImportOutcome,
} from '../src/agents/agent-task.ts'
import { renderAgentTaskFile } from '../src/agents/agent-task-file.ts'
import { parseAgentAnswer, answerBindingProblem } from '../src/agents/agent-answer.ts'
import { handoffResultProblem } from '../src/agents/handoff-result.ts'
import { syntheticArticlePdf } from '../src/agents/test-support.ts'
import {
  check,
  psql,
  q,
  readLocalStackConfig,
  userToken,
  type LocalStackConfig,
} from './local-stack.ts'
import { parseCandidateView, canBeFinalControlled } from '../src/lib/candidate-view.ts'
import {
  parsePublicationOutcome,
  parsePublishedClaim,
  parsePublishedClaimIndex,
} from '../src/lib/published-claim.ts'
import {
  buildAssignmentFromCatalog,
  type EditorCatalogApi,
} from '../src/ops/extraction-assignment.ts'

type Config = LocalStackConfig

const SOURCE = 'c2000000-0000-4000-8000-000000000001'
const EDITOR_USER = 'c2000000-0000-4000-8000-0000000000e0'
const EDITOR_ACTOR = 'c2000000-0000-4000-8000-0000000000e1'
// Sluttkontrollen er et menneskes beslutning, og et annet menneske enn den som
// bygger kandidaten: mandatene er forskjellige, og prøven later ikke som noe
// annet (ANTIDEP_CONSTITUTION.md regel 5, §12).
const REVIEWER_USER = 'c2000000-0000-4000-8000-0000000000f0'
const REVIEWER_ACTOR = 'c2000000-0000-4000-8000-0000000000f1'
// Publisering er en tredje rettighet med sin egen terskel, og den utføres av et
// tredje menneske: å godkjenne og å publisere er to handlinger med hvert sitt
// mandat (ANTIDEP_CONSTITUTION.md regel 5, 6).
const PUBLISHER_USER = 'c2000000-0000-4000-8000-0000000000a0'
const PUBLISHER_ACTOR = 'c2000000-0000-4000-8000-0000000000a1'
// En innlogget kliniker uten noe mandat i det hele tatt. Hen skal kunne lese det
// publiserte innholdet, og ingenting internt.
const CLINICIAN_USER = 'c2000000-0000-4000-8000-0000000000b0'
const CLINICIAN_ACTOR = 'c2000000-0000-4000-8000-0000000000b1'

function seed(config: Config): { secret: string; verifierSecret: string } {
  // The local integration database is reusable. Remove only this test's fixed
  // graph and any rows derived from it, with replication triggers disabled for
  // the cleanup itself. The test never touches real source-library rows.
  psql(
    config,
    `
    set session_replication_role = replica;
    delete from audit.events where object_id in (
      select ev.id from workflow.evidence_verifications ev
      join knowledge.evidence_items e on e.id = ev.evidence_item_id
      where e.source_id = ${q(SOURCE)}
      union select e.id from knowledge.evidence_items e where e.source_id = ${q(SOURCE)}
      union select sv.id from knowledge.source_versions sv where sv.source_id = ${q(SOURCE)}
      union select ${q(SOURCE)}::uuid
    );
    delete from workflow.evidence_verifications where evidence_item_id in (
      select id from knowledge.evidence_items where source_id = ${q(SOURCE)});
    delete from knowledge.evidence_field_groundings where evidence_item_id in (
      select id from knowledge.evidence_items where source_id = ${q(SOURCE)});
    delete from knowledge.evidence_items where source_id = ${q(SOURCE)};
    delete from provenance.agent_runs where input_source_version_id in (
      select id from knowledge.source_versions where source_id = ${q(SOURCE)});
    delete from knowledge.source_versions where source_id = ${q(SOURCE)};
    delete from knowledge.sources where id = ${q(SOURCE)};
    -- Publiseringshistorikken peker på påstanden og på kandidaten med RESTRICT,
    -- og kjeden publiserer nå på ekte. Uten dette ville en ny kjøring i den
    -- gjenbrukbare lokale databasen ikke fått fjernet noe av det den lagde.
    delete from knowledge.publication_events where claim_id::text like 'c2000000%';
    update knowledge.claims
    set current_published_revision_id = null, current_published_candidate_id = null
    where id::text like 'c2000000%';
    delete from workflow.candidate_final_controls where candidate_id in (
      select c.id from knowledge.candidates c
      join knowledge.claim_revisions r on r.id = c.claim_revision_id
      where r.id::text like 'c2000000%');
    delete from knowledge.candidates where claim_revision_id::text like 'c2000000%';
    delete from knowledge.evidence_assessments where claim_revision_id::text like 'c2000000%';
    delete from workflow.claim_verification_citations where claim_revision_id::text like 'c2000000%';
    delete from workflow.claim_verifications where claim_revision_id::text like 'c2000000%';
    delete from knowledge.claim_evidence_links where claim_revision_id::text like 'c2000000%';
    delete from knowledge.claim_revisions where id::text like 'c2000000%';
    delete from knowledge.claims where id::text like 'c2000000%';
    -- Fikstur-kjøringene har faste id-er og ingen input_source_version_id, så
    -- de dekkes ikke av slettingen over. Uten denne ville en ny kjøring i den
    -- gjenbrukbare lokale databasen kollidert på primærnøkkelen.
    delete from provenance.agent_runs where id::text like 'c2000000%';
    delete from workflow.pipeline_job_events where pipeline_job_id in (
      select id from workflow.pipeline_jobs where job_key like 'antidep2-kjede:%');
    delete from workflow.pipeline_job_runs where pipeline_job_id in (
      select id from workflow.pipeline_jobs where job_key like 'antidep2-kjede:%');
    delete from workflow.pipeline_jobs where job_key like 'antidep2-kjede:%';
    -- Handoff-oppgavene kjeden legger inn, har en utledet nøkkel og kan derfor
    -- ikke kjennes igjen på et prefiks. De kjennes igjen på hvem som la dem inn:
    -- kjedens egen redaktøraktør, som slettes og opprettes på nytt hver kjøring.
    -- Uten dette ville en ny kjøring i den gjenbrukbare lokale databasen møtt en
    -- oppgave som allerede var besvart.
    delete from workflow.agent_handoff_imports where pipeline_job_id in (
      select id from workflow.pipeline_jobs
      where job_key like 'agent-handoff:%' and enqueued_by_actor_id = ${q(EDITOR_ACTOR)});
    -- Utførelsesmåten er en egen rad med RESTRICT på jobben. Uten dette ville
    -- slettingen av jobbene under stoppet på fremmednøkkelen.
    delete from workflow.agent_handoff_jobs where pipeline_job_id in (
      select id from workflow.pipeline_jobs
      where job_key like 'agent-handoff:%' and enqueued_by_actor_id = ${q(EDITOR_ACTOR)});
    delete from workflow.pipeline_job_events where pipeline_job_id in (
      select id from workflow.pipeline_jobs
      where job_key like 'agent-handoff:%' and enqueued_by_actor_id = ${q(EDITOR_ACTOR)});
    delete from workflow.pipeline_job_runs where pipeline_job_id in (
      select id from workflow.pipeline_jobs
      where job_key like 'agent-handoff:%' and enqueued_by_actor_id = ${q(EDITOR_ACTOR)});
    delete from workflow.pipeline_jobs
    where job_key like 'agent-handoff:%' and enqueued_by_actor_id = ${q(EDITOR_ACTOR)};
    -- Den semantiske modelltildelingen kjeden registrerer, er append-only i
    -- drift. I den gjenbrukbare testdatabasen må den likevel bort, ellers ville
    -- neste kjøring møtt sin egen modell som «allerede registrert».
    delete from provenance.role_model_assignments
    where capacity = 'semantic' and provider = 'antidep-test';
    delete from knowledge.full_text_readability_checks where source_version_id in (
      select id from knowledge.source_versions where source_id = ${q(SOURCE)});
    delete from knowledge.source_document_publications where source_id = ${q(SOURCE)};
    delete from knowledge.source_identifiers where source_id = ${q(SOURCE)};
    delete from workflow.user_roles where user_id in (
      ${q(EDITOR_USER)}, ${q(REVIEWER_USER)}, ${q(PUBLISHER_USER)}, ${q(CLINICIAN_USER)});
    delete from provenance.actors where id in (
      ${q(EDITOR_ACTOR)}, ${q(REVIEWER_ACTOR)}, ${q(PUBLISHER_ACTOR)}, ${q(CLINICIAN_ACTOR)});
    delete from auth.users where id in (
      ${q(EDITOR_USER)}, ${q(REVIEWER_USER)}, ${q(PUBLISHER_USER)}, ${q(CLINICIAN_USER)});
    reset session_replication_role;

    insert into knowledge.sources
      (id, source_type, title, authors_or_issuer, created_by_actor_id)
    values (
      ${q(SOURCE)}, 'journal_article', 'Antidep 2 syntetisk kjedeprøve',
      'Testforfatter',
      (select id from provenance.actors where actor_key = 'human:peder-holman')
    );

    insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
    values (${q(SOURCE)}, 'doi', '10.5555/antidep2.chain')
    on conflict do nothing;

    insert into auth.users (id, instance_id, aud, role, email)
    values (${q(EDITOR_USER)}, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated', 'antidep2-kjede-editor@example.test'),
           (${q(REVIEWER_USER)}, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated', 'antidep2-kjede-fagperson@example.test'),
           (${q(PUBLISHER_USER)}, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated', 'antidep2-kjede-publisher@example.test'),
           (${q(CLINICIAN_USER)}, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated', 'antidep2-kjede-kliniker@example.test');

    insert into provenance.actors
      (id, actor_key, actor_type, display_name, description, auth_user_id)
    values (${q(EDITOR_ACTOR)}, 'human:antidep2-kjede-editor', 'human',
            'Antidep 2 kjedeprøvens editor', 'Bare for scripts/agent-chain-test.ts.',
            ${q(EDITOR_USER)}),
           (${q(REVIEWER_ACTOR)}, 'human:antidep2-kjede-fagperson', 'human',
            'Antidep 2 kjedeprøvens fagperson', 'Bare for scripts/agent-chain-test.ts.',
            ${q(REVIEWER_USER)}),
           (${q(PUBLISHER_ACTOR)}, 'human:antidep2-kjede-publisher', 'human',
            'Antidep 2 kjedeprøvens publisher', 'Bare for scripts/agent-chain-test.ts.',
            ${q(PUBLISHER_USER)}),
           (${q(CLINICIAN_ACTOR)}, 'human:antidep2-kjede-kliniker', 'human',
            'Antidep 2 kjedeprøvens kliniker', 'Bare for scripts/agent-chain-test.ts.',
            ${q(CLINICIAN_USER)});

    insert into workflow.user_roles
      (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
    values (${q(EDITOR_USER)}, 'editor', null, now() - interval '1 day',
            (select id from provenance.actors where actor_key = 'human:peder-holman'),
            'Antidep 2 syntetisk kjedeprøve.'),
           (${q(REVIEWER_USER)}, 'reviewer',
            (select id from catalog.clinical_concepts where canonical_label = 'vektendring'),
            now() - interval '1 day',
            (select id from provenance.actors where actor_key = 'human:peder-holman'),
            'Antidep 2 syntetisk kjedeprøve: sluttkontroll.'),
           (${q(PUBLISHER_USER)}, 'publisher', null, now() - interval '1 day',
            (select id from provenance.actors where actor_key = 'human:peder-holman'),
            'Antidep 2 syntetisk kjedeprøve: publisering.');
    `,
  )

  return {
    secret: psql(
      config,
      `select provenance.issue_agent_identity_credential(
         'agent-identity:evidence-extraction-01', 'human:peder-holman')`,
    ),
    verifierSecret: psql(
      config,
      `select provenance.issue_agent_identity_credential(
         'agent-identity:extraction-verification-01', 'human:peder-holman')`,
    ),
  }
}

async function main(): Promise<void> {
  const config = readLocalStackConfig(process.argv.slice(2))
  console.log(
    'Antidep 2: PDF → oppdrag → agentekstraksjon → uavhengig verifikasjon → forseglet ' +
      'kandidat → sluttkontroll → publisering → klinikervisning → withdraw → rollback.\n',
  )

  const { secret, verifierSecret } = seed(config)
  const editor = createClient(config.apiUrl, config.anonKey, {
    db: { schema: 'api' },
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${userToken(config, EDITOR_USER)}` } },
  })

  const catalog: EditorCatalogApi = {
    listSources: async () => {
      const { data, error } = await editor.from('editor_sources').select('*')
      if (error !== null) throw new Error(error.message)
      return (data ?? []) as never[]
    },
    listSourceVersions: async (sourceId) => {
      const { data, error } = await editor
        .from('editor_source_versions')
        .select('*')
        .eq('source_id', sourceId)
      if (error !== null) throw new Error(error.message)
      return (data ?? []) as never[]
    },
    uploadFullTextDocument: async (input) => {
      const { data, error } = await editor.rpc('upload_full_text_document', {
        p_source_id: input.sourceId,
        p_retrieved_at: input.retrievedAt,
        p_retrieved_from: input.retrievedFrom,
        p_document_base64: input.documentBase64,
        p_extracted_text: input.extractedText,
        p_text_extraction_tool: input.recipe.tool,
        p_text_extraction_tool_version: input.recipe.toolVersion,
        p_text_extraction_arguments: input.recipe.arguments,
        p_text_extraction_transform: input.recipe.transform ?? '',
        p_external_version: input.externalVersion,
      })
      if (error !== null) throw new Error(error.message)
      return data
    },
    createSourceVersionFromDocument: async (input) => {
      const { data, error } = await editor.rpc('create_source_version_from_document', {
        p_source_id: input.sourceId,
        p_retrieved_at: input.retrievedAt,
        p_retrieved_from: input.retrievedFrom,
        p_document_base64: input.documentBase64,
        p_extracted_text: input.extractedText,
        p_representation: input.representation,
        p_text_extraction_tool: input.recipe.tool,
        p_text_extraction_tool_version: input.recipe.toolVersion,
        p_text_extraction_arguments: input.recipe.arguments,
        p_text_extraction_transform: input.recipe.transform,
        p_external_version: input.externalVersion,
      })
      if (error !== null) throw new Error(error.message)
      return data as string
    },
    buildAssignment: async (input) => {
      const { data, error } = await editor.rpc('build_extraction_assignment', {
        p_source_version_id: input.sourceVersionId,
        p_drug_names: input.drugs,
        p_outcome_labels: input.outcomes,
        p_population_labels: input.populations,
      })
      if (error !== null) throw new Error(error.message)
      return data
    },
  }

  const work = mkdtempSync(join(tmpdir(), 'antidep2-chain-'))
  try {
    // En *artikkel*, ikke tre linjer: fra migrasjon 009a må en fulltekst bestå
    // lesbarhetskontrollen, tabellene inkludert, før den kan registreres.
    const pdf = syntheticArticlePdf([
      // Publikasjonstilhørigheten kontrolleres av teksten selv: uten kildens
      // egen identitet i fullteksten blir filen ingen fulltekstversjon.
      'doi: 10.5555/antidep2.chain',
      'Patients with major depressive disorder were randomised to double-blind sertraline treatment for 26 to 32 weeks.',
      'Forty-eight sertraline-treated patients completed the trial and were analysed.',
      'Mean percent weight change was 1.0% at endpoint with a 95% confidence interval from 0.5% to 1.5%.',
      // Den andre armen finnes for at den eksterne agent-handoffen skal kunne
      // registrere sitt eget evidensfunn av den samme artikkelen, uten å bli en
      // dublett av sertralinfunnet over.
      'A parallel mirtazapine arm of forty-two patients was followed for the same period.',
      'Mean percent weight change in the mirtazapine arm was 3.0% at endpoint with a 95% confidence interval from 2.1% to 3.9%.',
    ])
    const pdfPath = join(work, 'article.pdf')
    const documentStore = join(work, 'documents')
    writeFileSync(pdfPath, pdf)

    const report = await buildAssignmentFromCatalog({
      catalog,
      sourceQuery: 'Antidep 2 syntetisk kjedeprøve',
      documentPath: pdfPath,
      retrievedFrom: 'https://example.test/antidep2-chain-fulltext',
      drugs: ['sertralin'],
      outcomes: ['vektendring'],
      populations: ['voksne med depressiv lidelse'],
      documentStore,
    })

    const expectedDigest = `sha256:${createHash('sha256').update(pdf).digest('hex')}`
    check(
      'PDF-en registreres som dokumentbundet fulltekst med databaseeid hash',
      report.representation === 'full_text' &&
        report.assignment.document?.sha256 === expectedDigest &&
        psql(
          config,
          `select document_sha256 from knowledge.source_versions where id = ${q(report.sourceVersionId)}`,
        ) === expectedDigest,
    )

    const assignmentPath = join(work, 'assignment.json')
    const runDirectory = join(work, 'drafting')
    writeFileSync(assignmentPath, JSON.stringify(report.json, null, 2), 'utf8')
    const documents = documentsIn(documentStore)
    const opened = await openDraftingJob({ assignmentPath, runDirectory, documents })
    check(
      'modellgrensen leser teksten fra original-PDF-en',
      opened.job.state === 'awaiting_answer' &&
        readFileSync(opened.promptPath, 'utf8').includes('Mean percent weight change was 1.0%'),
    )

    const drugId = psql(config, `select id from catalog.drugs where canonical_name = 'sertralin'`)
    const outcomeId = psql(
      config,
      `select id from catalog.clinical_concepts where canonical_label = 'vektendring'`,
    )
    const populationId = psql(
      config,
      `select id from catalog.populations where canonical_label = 'voksne med depressiv lidelse'`,
    )

    const methodExcerpt =
      'Patients with major depressive disorder were randomised to double-blind sertraline treatment for 26 to 32 weeks.'
    const sampleExcerpt =
      'Forty-eight sertraline-treated patients completed the trial and were analysed.'
    const resultExcerpt =
      'Mean percent weight change was 1.0% at endpoint with a 95% confidence interval from 0.5% to 1.5%.'

    const draft = {
      extraction: {
        design_code: 'randomized_controlled_trial',
        population_id: populationId,
        population_availability: 'reported_value',
        population_detail: 'Voksne med depressiv lidelse.',
        sample_size: 48,
        sample_size_availability: 'reported_value',
        intervention_drug_id: drugId,
        comparator_kind: 'none',
        outcome_concept_id: outcomeId,
        outcome_detail: 'Gjennomsnittlig prosentvis vektendring ved endepunkt.',
        timepoint_min: '26 weeks',
        timepoint_max: '32 weeks',
        timepoint_availability: 'reported_value',
        reported_direction: 'increase',
        effect_measure: 'mean_change',
        estimate: '1.0',
        estimate_unit: 'percent',
        estimate_availability: 'reported_value',
        ci_lower: '0.5',
        ci_upper: '1.5',
        ci_level_percent: '95',
        confidence_interval_availability: 'reported_value',
        source_locator: 'Syntetisk fulltekst, resultater',
        source_quote: resultExcerpt,
      },
      field_groundings: [
        {
          check_field: 'intervention_arm',
          source_excerpt: methodExcerpt,
          source_locator: 'METHODS',
          justification: 'Intervensjonen står i fullteksten.',
        },
        {
          check_field: 'sample_size',
          source_excerpt: sampleExcerpt,
          source_locator: 'RESULTS',
          justification: 'Utvalgsstørrelsen står i fullteksten.',
        },
        {
          check_field: 'outcome',
          source_excerpt: resultExcerpt,
          source_locator: 'RESULTS',
          justification: 'Endepunktet står i fullteksten.',
        },
        {
          check_field: 'estimate',
          source_excerpt: resultExcerpt,
          source_locator: 'RESULTS',
          justification: 'Estimatet står i fullteksten.',
        },
        {
          check_field: 'effect_measure',
          source_excerpt: resultExcerpt,
          source_locator: 'RESULTS',
          justification: 'Effektmålet står i fullteksten.',
        },
        {
          check_field: 'reported_direction',
          source_excerpt: resultExcerpt,
          source_locator: 'RESULTS',
          justification: 'Retningen står i fullteksten.',
        },
        {
          check_field: 'confidence_interval',
          source_excerpt: resultExcerpt,
          source_locator: 'RESULTS',
          justification: 'Konfidensintervallet står i fullteksten.',
        },
        {
          check_field: 'timepoint',
          source_excerpt: methodExcerpt,
          source_locator: 'METHODS',
          justification: 'Tidsrommet står i fullteksten.',
        },
        {
          check_field: 'population',
          source_excerpt: methodExcerpt,
          source_locator: 'METHODS',
          justification: 'Populasjonen står i fullteksten.',
        },
        {
          check_field: 'availability_semantics',
          source_excerpt: resultExcerpt,
          source_locator: 'RESULTS',
          justification: 'Alle numeriske felt som brukes her er eksplisitt rapportert.',
        },
      ],
    }

    writeFileSync(
      join(runDirectory, JOB_FILES.answer),
      JSON.stringify({
        answer_version: MODEL_ANSWER_VERSION,
        request_digest: opened.job.requestDigest,
        identity: {
          provider: 'antidep-test',
          model: 'deterministic-chain-model',
          model_version: '1',
        },
        answered_at: new Date().toISOString(),
        draft,
      }),
      'utf8',
    )

    const closed = await closeDraftingJob({ runDirectory, assignmentPath, documents })
    check(
      'modellsvaret blir et kildeforankret forslag',
      closed.outcome === 'drafted',
      closed.reason ?? '',
    )
    if (closed.outcome !== 'drafted') return

    const proposal = (await readProposalFile(closed.proposalPath)).proposal
    const agent = createAgentClient({ url: config.apiUrl, publishableKey: config.anonKey })
    const extractionApi = createEvidenceExtractionApi(agent, {
      identityKey: 'agent-identity:evidence-extraction-01',
      secret: agentSecret(secret),
    })
    const verificationApi = createExtractionVerificationApi(agent, {
      identityKey: 'agent-identity:extraction-verification-01',
      secret: agentSecret(verifierSecret),
    })

    // ------------------------------------------------------------------
    // Den varige, idempotente jobbtilstanden — og arbeidet som gjøres *i* den
    //
    // Jobben legges inn og tas ut før ekstraksjonen, fordi ekstraksjonen er
    // det jobben er. Kjøringen åpnes for uttaket, slik at utfallet kan bevise
    // at nettopp denne kjøringen gjorde nettopp denne jobben — ikke bare at
    // identiteten en gang har hatt en vellykket kjøring i rollen.
    // ------------------------------------------------------------------
    const jobs = createPipelineJobApi(agent, {
      identityKey: 'agent-identity:evidence-extraction-01',
      secret: agentSecret(secret),
    })
    const key = jobKey('antidep2-kjede', report.sourceVersionId)
    const enqueued = await editor.rpc('enqueue_pipeline_job', {
      p_agent_role: 'evidence_extraction',
      p_job_key: key,
      p_input_manifest: { source_version_id: report.sourceVersionId },
    })
    const enqueuedAgain = await editor.rpc('enqueue_pipeline_job', {
      p_agent_role: 'evidence_extraction',
      p_job_key: key,
      p_input_manifest: { source_version_id: report.sourceVersionId },
    })
    check(
      'den samme jobben lagt inn to ganger er én rad',
      enqueued.error === null &&
        enqueuedAgain.error === null &&
        (enqueued.data as { pipeline_job_id?: string } | null)?.pipeline_job_id ===
          (enqueuedAgain.data as { pipeline_job_id?: string } | null)?.pipeline_job_id,
      enqueued.error?.message ?? enqueuedAgain.error?.message ?? '',
    )

    const claimed = await jobs.claim('evidence_extraction')
    check('kjøreren tar ut jobben med en leie', claimed.claimed)
    if (!claimed.claimed) return

    const extraction = await runEvidenceExtraction({
      api: extractionApi,
      proposal,
      assignment: report.assignment,
      mode: 'with_assignment',
      documents,
      job: { pipelineJobId: claimed.job.pipelineJobId, leaseToken: claimed.job.leaseToken },
    })
    const evidenceItemId = extraction.evidenceItemId ?? ''
    check(
      'ekstraksjonsagenten registrerer EvidenceItem fra fullteksten',
      extraction.decision === 'registered' && evidenceItemId !== '',
      extraction.reason ?? '',
    )
    if (evidenceItemId === '') return

    check(
      'kjøringen er bundet til nettopp det uttaket den ble åpnet for',
      psql(
        config,
        `select (b.pipeline_job_id = ${q(claimed.job.pipelineJobId)}::uuid
                 and b.lease_token = ${q(claimed.job.leaseToken)}::uuid)::text
         from workflow.pipeline_job_runs b where b.agent_run_id = ${q(extraction.agentRunId)}`,
      ) === 'true',
    )

    await jobs.complete(claimed.job.pipelineJobId, claimed.job.leaseToken, extraction.agentRunId)
    await jobs.complete(claimed.job.pipelineJobId, claimed.job.leaseToken, extraction.agentRunId)
    check(
      'en fullført jobb kan meldes om igjen uten å skrive noe nytt',
      psql(
        config,
        `select (count(*) = 1)::text from workflow.pipeline_job_events e
         where e.pipeline_job_id = ${q(claimed.job.pipelineJobId)} and e.to_state = 'succeeded'`,
      ) === 'true',
    )
    // Køens utfall er kjøringens eget, ikke en parallell påstand.
    check(
      'jobbens utfall er kjøringens eget utdatamanifest',
      psql(
        config,
        `select (j.output_manifest = r.output_manifest)::text
         from workflow.pipeline_jobs j
         join provenance.agent_runs r on r.id = j.agent_run_id
         where j.id = ${q(claimed.job.pipelineJobId)}`,
      ) === 'true',
    )

    check(
      'EvidenceItem er bundet til den samme fulltekstversjonen',
      psql(
        config,
        `select (e.source_version_id = ${q(report.sourceVersionId)}::uuid
                 and sv.representation = 'full_text'
                 and sv.document_sha256 = ${q(expectedDigest)})::text
         from knowledge.evidence_items e
         join knowledge.source_versions sv on sv.id = e.source_version_id
         where e.id = ${q(evidenceItemId)}`,
      ) === 'true',
    )

    const verification = await runExtractionVerification({
      api: verificationApi,
      premises: EXTRACTION_VERIFICATION_PREMISES,
      evidenceItemId,
      documents,
    })
    check(
      'uavhengig verifikator registrerer kontroll mot samme originaldokument',
      verification.items[0]?.decision === 'registered',
      verification.items[0]?.reason ?? '',
    )
    check(
      'maskinbeviset for kildeforankringen gjelder',
      psql(config, `select workflow.grounding_machine_proved(${q(evidenceItemId)})::text`) ===
        'true',
    )

    // ------------------------------------------------------------------
    // Fulltekstbiblioteket: filen ligger der, bundet, og kontrollert
    // ------------------------------------------------------------------
    check(
      'originalfilen ligger i det private biblioteket, med databasens eget fingeravtrykk',
      psql(
        config,
        `select (d.sha256 = knowledge.source_document_fingerprint(d.content))::text
         from knowledge.source_documents d where d.sha256 = ${q(expectedDigest)}`,
      ) === 'true',
    )
    check(
      'filen er vist å tilhøre publikasjonen, på kildens registrerte DOI',
      report.upload?.publicationBinding.basis === 'doi' &&
        psql(
          config,
          `select dp.binding_basis::text
           from knowledge.source_document_publications dp
           join knowledge.source_documents d on d.id = dp.source_document_id
           where d.sha256 = ${q(expectedDigest)} and dp.source_id = ${q(SOURCE)}`,
        ) === 'doi',
      report.upload?.publicationBinding.basis ?? 'ingen binding',
    )
    check(
      'fullteksten har bestått lesbarhetskontrollen, med tabellrader',
      psql(
        config,
        `select (rc.table_row_count >= 3)::text
         from knowledge.full_text_readability_checks rc
         where rc.source_version_id = ${q(report.sourceVersionId)}`,
      ) === 'true',
      `datarader: ${String(report.upload?.readability.tableRowCount ?? 0)}`,
    )

    // ------------------------------------------------------------------
    // Modellrollene er reelt separate
    // ------------------------------------------------------------------
    const wrongPremises = await agent.rpc('begin_agent_run', {
      p_identity_key: 'agent-identity:evidence-extraction-01',
      p_secret: secret,
      p_agent_role: 'evidence_extraction',
      p_provider: 'en-annen-leverandør',
      p_model: 'en-annen-modell',
      p_model_version: '1',
      p_prompt_template_version: 'evidence-extraction/proposal/1',
      p_pipeline_version: 'antidep-evidence/1',
      p_input_manifest: { mode: 'antidep2-kjede' },
      p_input_source_version_id: report.sourceVersionId,
    })
    check(
      'en kjøring med andre premisser enn den registrerte modelltildelingen avvises',
      wrongPremises.error !== null,
      wrongPremises.error?.message ?? 'kjøringen kom i gang',
    )
    check(
      'ekstraksjonen og kontrollen kjørte som to forskjellige modellidentiteter',
      psql(
        config,
        `select (count(distinct (r.provider, r.model, r.model_version)) = 2)::text
         from provenance.agent_runs r
         where r.id in (
           (select e.agent_run_id from knowledge.evidence_items e where e.id = ${q(evidenceItemId)}),
           (select ev.agent_run_id from workflow.evidence_verifications ev
            where ev.evidence_item_id = ${q(evidenceItemId)}
            order by ev.registration_ordinal desc limit 1)
         )`,
      ) === 'true',
    )

    // ------------------------------------------------------------------
    // Den deterministiske kontrollen bekrefter ikke denne raden — og da kan
    // den ikke bære en kandidat
    //
    // Katalogen er norsk og den syntetiske artikkelen engelsk, så
    // `checkExtraction` finner ikke begrepene ordrett og konkluderer
    // `uncertain`. Det er ikke et avvik, men det er heller ikke en
    // bekreftelse — og en ubekreftet ekstraksjon skal ikke kunne forsegles som
    // et ferdig produkt (ANTIDEP_CONSTITUTION.md regel 4, gate G5 i
    // knowledge.assert_claim_revision_ready_for_approval).
    //
    // Prøven fester den tilstanden framfor å skrive over den: en fabrikkert
    // `verified`-rad ville gjort kjedeprøven grønn ved å fjerne nettopp det
    // den skal vise.
    // ------------------------------------------------------------------
    check(
      'den deterministiske kontrollen bekrefter ikke en norsk katalog mot en engelsk kilde',
      psql(
        config,
        `select (ev.outcome <> 'verified')::text
         from workflow.evidence_verifications ev
         where ev.evidence_item_id = ${q(evidenceItemId)}
         order by ev.registration_ordinal desc
         limit 1`,
      ) === 'true',
    )

    // ------------------------------------------------------------------
    // Kandidaten og den kandidatbundne sluttkontrollen
    //
    // Påstandsdannelsen, kildestøttekontrollen og evidensvurderingen har hver
    // sin egen kjører og sin egen prøve; her legges de inn som fikstur, slik at
    // kjedeprøven kan komme fram til det den er til for — grensen mellom
    // TypeScript og de fire nye api-funksjonene.
    //
    // Evidensfunnet er også en fikstur, og et *annet* funn enn det kjeden
    // nettopp laget: en forseglet kandidat krever en bekreftet ekstraksjon, og
    // den bekreftelsen skal komme av en kontroll som faktisk konkluderte — ikke
    // av at prøven skrev om utfallet til det den trengte.
    // ------------------------------------------------------------------
    psql(
      config,
      `
      insert into provenance.agent_runs
        (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
         prompt_template_version, pipeline_version, input_manifest, input_source_version_id)
      select 'c2000000-0000-4000-8000-000000000051', ai.id, ai.actor_id, 'evidence_extraction',
             'antidep', 'proposal-grounded-extraction', '1.1.0',
             'evidence-extraction/proposal/1', 'antidep-evidence/1',
             '{"mode": "antidep2-kjede-fikstur"}'::jsonb, ${q(report.sourceVersionId)}
      from provenance.agent_identities ai
      where ai.identity_key = 'agent-identity:evidence-extraction-01';

      insert into knowledge.evidence_items
        (id, source_id, source_version_id, design_code, population_availability,
         population_detail, sample_size_availability, intervention_drug_id, comparator_kind,
         outcome_concept_id, outcome_detail, timepoint_availability, reported_direction,
         estimate_availability, confidence_interval_availability, source_locator,
         extraction_method, created_by_actor_id, agent_run_id)
      select 'c2000000-0000-4000-8000-000000000011', ${q(SOURCE)}, ${q(report.sourceVersionId)},
             'randomized_controlled_trial', 'not_reported', 'Fikstur i kjedeprøven.',
             'not_reported', d.id, 'none', c.id, 'Fikstur i kjedeprøven.', 'not_reported',
             'increase', 'not_reported', 'not_reported', 'Avsnitt 1', 'ai_assisted',
             (select id from provenance.actors where actor_key = 'agent:evidence-extraction'),
             'c2000000-0000-4000-8000-000000000051'
      from catalog.drugs d, catalog.clinical_concepts c
      where d.canonical_name = 'sertralin' and c.canonical_label = 'vektendring';

      insert into provenance.agent_runs
        (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
         prompt_template_version, pipeline_version, input_manifest)
      select 'c2000000-0000-4000-8000-00000000005a', ai.id, ai.actor_id,
             'extraction_verification', 'antidep', 'deterministic-extraction-check', '1.0.0',
             'extraction-verification/deterministic/1', 'antidep-evidence/1',
             '{"mode": "antidep2-kjede-fikstur"}'::jsonb
      from provenance.agent_identities ai
      where ai.identity_key = 'agent-identity:extraction-verification-01';

      insert into workflow.evidence_verifications
        (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
         source_access, checked_fields, rationale, verified_at, agent_run_id)
      select e.id, e.created_by_actor_id,
             (select id from provenance.actors where actor_key = 'agent:extraction-verification'),
             'verified', 'verifiable_representation',
             array['source_wide_absence']::workflow.evidence_check_field[],
             'Fikstur: den kildeomfattende halvdelen av fraværspåstanden.',
             now() - interval '30 days', 'c2000000-0000-4000-8000-00000000005a'
      from knowledge.evidence_items e
      where e.id = 'c2000000-0000-4000-8000-000000000011'
        and 'source_wide_absence' = any (workflow.required_check_fields(e.id));

      insert into workflow.evidence_verifications
        (evidence_item_id, verified_item_creator_actor_id, verifier_actor_id, outcome,
         source_access, checked_fields, rationale, verified_at)
      select e.id, e.created_by_actor_id,
             (select id from provenance.actors where actor_key = 'agent:extraction-verification'),
             'verified', 'original_source',
             array_remove(workflow.required_check_fields(e.id),
                          'source_wide_absence'::workflow.evidence_check_field),
             'Fikstur: fullstendig kontrollert ekstraksjon.', now()
      from knowledge.evidence_items e
      where e.id = 'c2000000-0000-4000-8000-000000000011';

      insert into knowledge.claims (id, knowledge_type, topic_concept_id, subject_drug_id,
                                    created_by_actor_id)
      select 'c2000000-0000-4000-8000-000000000021', 'evidence_synthesis', c.id, d.id,
             (select id from provenance.actors where actor_key = 'agent:claim-synthesis')
      from catalog.drugs d, catalog.clinical_concepts c
      where d.canonical_name = 'sertralin' and c.canonical_label = 'vektendring';

      insert into knowledge.claim_revisions
        (id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
         comparator_kind, direction, uncertainty_summary, created_by_actor_id)
      select 'c2000000-0000-4000-8000-000000000031', cl.id, 1, cl.knowledge_type,
             cl.subject_drug_id,
             'Sertralin er forbundet med en liten vektøkning ved langtidsbruk.',
             'Kun syntetisk kjedeprøve.', 'none', 'increase',
             'Grunnlaget er ett syntetisk funn.',
             (select id from provenance.actors where actor_key = 'agent:claim-synthesis')
      from knowledge.claims cl where cl.id = 'c2000000-0000-4000-8000-000000000021';

      insert into knowledge.claim_evidence_links
        (claim_revision_id, evidence_item_id, relationship_type, directness, relevance_note,
         created_by_actor_id)
      values ('c2000000-0000-4000-8000-000000000031',
              'c2000000-0000-4000-8000-000000000011', 'supports', 'direct',
              'Eneste lenke i kjedeprøven.',
              (select id from provenance.actors where actor_key = 'agent:claim-synthesis'));

      insert into provenance.agent_runs
        (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
         prompt_template_version, pipeline_version, input_manifest)
      select 'c2000000-0000-4000-8000-000000000052', ai.id, ai.actor_id,
             'citation_support_verification', 'antidep', 'deterministic-claim-check', '1.0.0',
             'claim-verification/deterministic/1', 'antidep-evidence/1',
             '{"mode": "antidep2-kjede"}'::jsonb
      from provenance.agent_identities ai
      where ai.identity_key = 'agent-identity:citation-support-verification-01';

      insert into workflow.claim_verifications
        (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
         source_access, source_support, population_match, comparator_match, timeframe_match,
         direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
         rationale, verified_at, agent_run_id)
      select r.id, r.created_by_actor_id,
             (select id from provenance.actors where actor_key = 'agent:citation-support-verification'),
             'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
             'Kjedeprøve: påstanden dekkes av grunnlaget.', now(),
             'c2000000-0000-4000-8000-000000000052'
      from knowledge.claim_revisions r where r.id = 'c2000000-0000-4000-8000-000000000031';

      insert into workflow.claim_verification_citations
        (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
         source_access, source_version_id, checked_content_hash, relationship_supported)
      select v.id, v.claim_revision_id, l.id, l.evidence_item_id, 'original_source',
             e.source_version_id, sv.content_hash, 'ok'
      from workflow.claim_verifications v
      join knowledge.claim_evidence_links l on l.claim_revision_id = v.claim_revision_id
      join knowledge.evidence_items e on e.id = l.evidence_item_id
      join knowledge.source_versions sv on sv.id = e.source_version_id
      where v.claim_revision_id = 'c2000000-0000-4000-8000-000000000031';

      insert into provenance.agent_runs
        (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
         prompt_template_version, pipeline_version, input_manifest)
      select 'c2000000-0000-4000-8000-000000000053', ai.id, ai.actor_id, 'evidence_assessment',
             'antidep', 'proposal-registered-assessment', '1.0.0',
             'evidence-assessment/proposal/1', 'antidep-evidence/1',
             '{"mode": "antidep2-kjede"}'::jsonb
      from provenance.agent_identities ai
      where ai.identity_key = 'agent-identity:evidence-assessment-01';

      insert into knowledge.evidence_assessments
        (claim_revision_id, assessed_knowledge_type, framework, certainty_level, risk_of_bias,
         inconsistency, indirectness, imprecision, publication_bias, rationale, evidence_gap,
         assessed_at, created_by_actor_id, agent_run_id)
      select r.id, r.knowledge_type, 'grade', 'low', 'serious', 'not_assessable', 'not_serious',
             'serious', 'not_assessable', 'Kjedeprøve: ett funn, alvorlig upresishet.',
             'Syntetisk grunnlag har med vilje begrenset dekning.', now(),
             (select id from provenance.actors where actor_key = 'agent:evidence-assessment'),
             'c2000000-0000-4000-8000-000000000053'
      from knowledge.claim_revisions r where r.id = 'c2000000-0000-4000-8000-000000000031';
      `,
    )

    const built = await editor.rpc('build_candidate', {
      p_claim_revision_id: 'c2000000-0000-4000-8000-000000000031',
    })
    check(
      'kandidaten forsegles av databasens egne rader',
      built.error === null,
      built.error?.message ?? '',
    )
    const candidateId = (built.data as { candidate_id?: string } | null)?.candidate_id ?? ''
    if (candidateId === '') return

    const builtAgain = await editor.rpc('build_candidate', {
      p_claim_revision_id: 'c2000000-0000-4000-8000-000000000031',
    })
    check(
      'en gjentatt bygging av uendret innhold skriver ingen ny kandidat',
      (builtAgain.data as { built?: boolean } | null)?.built === false,
    )

    const reviewer = createClient(config.apiUrl, config.anonKey, {
      db: { schema: 'api' },
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${userToken(config, REVIEWER_USER)}` } },
    })

    const forEditor = await editor.rpc('candidate_for_control', { p_candidate_id: candidateId })
    check(
      'kandidatinnholdet er tilgangsbegrenset for en kaller uten mandat',
      forEditor.error !== null,
      'redaktøren fikk lese innholdet',
    )

    const forControl = await reviewer.rpc('candidate_for_control', { p_candidate_id: candidateId })
    check(
      'fagpersonen kan lese kandidaten',
      forControl.error === null,
      forControl.error?.message ?? '',
    )
    if (forControl.error !== null) return

    const view = parseCandidateView(forControl.data)
    check(
      'kandidaten viser kildedekningen, og at den ikke er publisert',
      view.sourceCoverage.length === 1 &&
        view.sourceCoverage[0]?.fullTextInLibrary === true &&
        view.sourceCoverage[0]?.readabilityChecked === true &&
        view.published === false &&
        view.experimental,
    )
    check('kandidaten er gjeldende og kan sluttkontrolleres', canBeFinalControlled(view))

    const wrongDigest = await reviewer.rpc('record_candidate_final_control', {
      p_candidate_id: candidateId,
      p_seen_candidate_digest: `sha256:${'9'.repeat(64)}`,
      p_decision: 'approved',
      p_rationale: 'Kjedeprøve: feil avtrykk.',
    })
    check(
      'en godkjenning avgitt mot et annet avtrykk avvises',
      wrongDigest.error !== null,
      'godkjenningen ble registrert',
    )

    const control = await reviewer.rpc('record_candidate_final_control', {
      p_candidate_id: candidateId,
      p_seen_candidate_digest: view.candidateDigest,
      p_decision: 'approved',
      p_rationale: 'Kjedeprøve: innholdet er lest i klinikerens egen visning.',
    })
    check(
      'sluttkontrollen registreres, bundet til kandidaten',
      control.error === null,
      control.error?.message ?? '',
    )
    check(
      'sluttkontrollen bærer kandidatens eget avtrykk',
      psql(
        config,
        `select (fc.candidate_digest = c.candidate_digest)::text
         from workflow.candidate_final_controls fc
         join knowledge.candidates c on c.id = fc.candidate_id
         where fc.candidate_id = ${q(candidateId)}`,
      ) === 'true',
    )

    check(
      'kjeden oppretter ingen menneskelig mikroreview',
      psql(
        config,
        `select (count(*) = 0)::text from workflow.review_decisions rd
         where rd.evidence_item_id = ${q(evidenceItemId)}`,
      ) === 'true',
    )

    // ------------------------------------------------------------------
    // Publiseringen, klinikervisningen, tilbaketrekkingen og rollbacken
    //
    // Fra migrasjon 009e og 009f er publisering en egen, eksplisitt handling
    // etter sluttkontrollen, med et annet mandat og på nøyaktig det forseglede
    // innholdet. Kjeden går derfor hele veien: privat PDF → agentkjede →
    // forseglet kandidat → menneskelig sluttkontroll → publisering →
    // klinikervisning, og deretter withdraw og rollback.
    // ------------------------------------------------------------------
    const publisher = createClient(config.apiUrl, config.anonKey, {
      db: { schema: 'api' },
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${userToken(config, PUBLISHER_USER)}` } },
    })
    const clinician = createClient(config.apiUrl, config.anonKey, {
      db: { schema: 'api' },
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${userToken(config, CLINICIAN_USER)}` } },
    })

    const byReviewer = await reviewer.rpc('publish_candidate', {
      p_candidate_id: candidateId,
      p_seen_candidate_digest: view.candidateDigest,
      p_reason: 'Kjedeprøve: fagpersonen publiserer selv.',
    })
    check(
      'å sluttkontrollere gir ikke publiseringsrett',
      byReviewer.error !== null,
      'fagpersonen fikk publisere',
    )

    const staleDigest = await publisher.rpc('publish_candidate', {
      p_candidate_id: candidateId,
      p_seen_candidate_digest: `sha256:${'9'.repeat(64)}`,
      p_reason: 'Kjedeprøve: feil avtrykk.',
    })
    check(
      'en publisering mot et annet avtrykk enn kandidatens eget avvises',
      staleDigest.error !== null,
      'publiseringen gikk gjennom',
    )

    const published = await publisher.rpc('publish_candidate', {
      p_candidate_id: candidateId,
      p_seen_candidate_digest: view.candidateDigest,
      p_reason: 'Kjedeprøve: godkjent innhold tas i bruk.',
    })
    check('publiseringen registreres', published.error === null, published.error?.message ?? '')
    if (published.error !== null) return
    const publishOutcome = parsePublicationOutcome(published.data)
    check(
      'publiseringen er den første hendelsen på påstanden',
      publishOutcome.changed && publishOutcome.event.action === 'publish',
    )

    const again = await publisher.rpc('publish_candidate', {
      p_candidate_id: candidateId,
      p_seen_candidate_digest: view.candidateDigest,
      p_reason: 'Kjedeprøve: gjentatt publisering.',
    })
    check(
      'en gjentatt publisering skriver ingen ny hendelse',
      again.error === null && parsePublicationOutcome(again.data).changed === false,
    )

    const claimId = publishOutcome.event.claimId ?? ''
    const clinicianView = await clinician.rpc('published_claim', { p_claim_id: claimId })
    check(
      'klinikeren kan lese det publiserte innholdet',
      clinicianView.error === null,
      clinicianView.error?.message ?? '',
    )
    if (clinicianView.error !== null) return
    const shown = parsePublishedClaim(clinicianView.data)
    check(
      'det publiserte innholdet er nøyaktig det forseglede kandidatinnholdet',
      shown.published &&
        shown.candidateId === candidateId &&
        shown.candidateDigest === view.candidateDigest &&
        JSON.stringify(shown.content?.sealedContent) === JSON.stringify(view.sealedContent),
    )
    check(
      'og det hasher til det avtrykket sluttkontrollen ble bundet til',
      psql(
        config,
        `select (knowledge.source_version_content_hash(c.content::text) = c.candidate_digest)::text
         from knowledge.candidates c where c.id = ${q(candidateId)}`,
      ) === 'true',
    )
    check(
      'proveniensen peker tilbake til sluttkontrollen',
      shown.finalControl?.reviewer === 'Antidep 2 kjedeprøvens fagperson',
    )

    const internal = await clinician.rpc('candidate_for_control', { p_candidate_id: candidateId })
    check(
      'interne kandidater er fortsatt private for en kliniker uten mandat',
      internal.error !== null,
      'klinikeren fikk lese kandidaten',
    )

    const catalogue = await clinician.rpc('published_claim_index', {})
    check(
      'den publiserte katalogen viser påstanden',
      catalogue.error === null &&
        parsePublishedClaimIndex(catalogue.data).some((entry) => entry.claimId === claimId),
    )

    // En andre revisjon, slik at rollbacken har noe å gå tilbake *fra*.
    psql(
      config,
      `
      insert into knowledge.claim_revisions
        (id, claim_id, revision_number, knowledge_type, subject_drug_id, statement, scope,
         comparator_kind, direction, uncertainty_summary, created_by_actor_id)
      select 'c2000000-0000-4000-8000-000000000032', cl.id, 2, cl.knowledge_type,
             cl.subject_drug_id,
             'Sertralin er forbundet med en liten vektøkning ved langtidsbruk, med forbehold.',
             'Kun syntetisk kjedeprøve.', 'none', 'increase',
             'Grunnlaget er ett syntetisk funn; forbeholdet er presisert.',
             (select id from provenance.actors where actor_key = 'agent:claim-synthesis')
      from knowledge.claims cl where cl.id = 'c2000000-0000-4000-8000-000000000021';

      insert into knowledge.claim_evidence_links
        (claim_revision_id, evidence_item_id, relationship_type, directness, relevance_note,
         created_by_actor_id)
      values ('c2000000-0000-4000-8000-000000000032',
              'c2000000-0000-4000-8000-000000000011', 'supports', 'direct',
              'Eneste lenke i kjedeprøvens andre revisjon.',
              (select id from provenance.actors where actor_key = 'agent:claim-synthesis'));

      insert into provenance.agent_runs
        (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
         prompt_template_version, pipeline_version, input_manifest)
      select 'c2000000-0000-4000-8000-000000000054', ai.id, ai.actor_id,
             'citation_support_verification', 'antidep', 'deterministic-claim-check', '1.0.0',
             'claim-verification/deterministic/1', 'antidep-evidence/1',
             '{"mode": "antidep2-kjede-rev2"}'::jsonb
      from provenance.agent_identities ai
      where ai.identity_key = 'agent-identity:citation-support-verification-01';

      insert into workflow.claim_verifications
        (claim_revision_id, verified_revision_creator_actor_id, verifier_actor_id, outcome,
         source_access, source_support, population_match, comparator_match, timeframe_match,
         direction_and_magnitude, qualifiers_complete, contradictory_evidence_represented,
         rationale, verified_at, agent_run_id)
      select r.id, r.created_by_actor_id,
             (select id from provenance.actors where actor_key = 'agent:citation-support-verification'),
             'verified', 'original_source', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok',
             'Kjedeprøve: den presiserte påstanden dekkes av grunnlaget.', now(),
             'c2000000-0000-4000-8000-000000000054'
      from knowledge.claim_revisions r where r.id = 'c2000000-0000-4000-8000-000000000032';

      insert into workflow.claim_verification_citations
        (claim_verification_id, claim_revision_id, claim_evidence_link_id, evidence_item_id,
         source_access, source_version_id, checked_content_hash, relationship_supported)
      select v.id, v.claim_revision_id, l.id, l.evidence_item_id, 'original_source',
             e.source_version_id, sv.content_hash, 'ok'
      from workflow.claim_verifications v
      join knowledge.claim_evidence_links l on l.claim_revision_id = v.claim_revision_id
      join knowledge.evidence_items e on e.id = l.evidence_item_id
      join knowledge.source_versions sv on sv.id = e.source_version_id
      where v.claim_revision_id = 'c2000000-0000-4000-8000-000000000032';

      insert into provenance.agent_runs
        (id, agent_identity_id, actor_id, agent_role, provider, model, model_version,
         prompt_template_version, pipeline_version, input_manifest)
      select 'c2000000-0000-4000-8000-000000000055', ai.id, ai.actor_id, 'evidence_assessment',
             'antidep', 'proposal-registered-assessment', '1.0.0',
             'evidence-assessment/proposal/1', 'antidep-evidence/1',
             '{"mode": "antidep2-kjede-rev2"}'::jsonb
      from provenance.agent_identities ai
      where ai.identity_key = 'agent-identity:evidence-assessment-01';

      insert into knowledge.evidence_assessments
        (claim_revision_id, assessed_knowledge_type, framework, certainty_level, risk_of_bias,
         inconsistency, indirectness, imprecision, publication_bias, rationale, evidence_gap,
         assessed_at, created_by_actor_id, agent_run_id)
      select r.id, r.knowledge_type, 'grade', 'low', 'serious', 'not_assessable', 'not_serious',
             'serious', 'not_assessable', 'Kjedeprøve: ett funn, alvorlig upresishet.',
             'Syntetisk grunnlag har med vilje begrenset dekning.', now(),
             (select id from provenance.actors where actor_key = 'agent:evidence-assessment'),
             'c2000000-0000-4000-8000-000000000055'
      from knowledge.claim_revisions r where r.id = 'c2000000-0000-4000-8000-000000000032';
      `,
    )

    const built2 = await editor.rpc('build_candidate', {
      p_claim_revision_id: 'c2000000-0000-4000-8000-000000000032',
    })
    const candidate2 = (built2.data as { candidate_id?: string } | null)?.candidate_id ?? ''
    const digest2 = (built2.data as { candidate_digest?: string } | null)?.candidate_digest ?? ''
    check('den andre kandidaten forsegles', built2.error === null && candidate2 !== '')
    if (candidate2 === '') return

    const beforeControl = await publisher.rpc('publish_candidate', {
      p_candidate_id: candidate2,
      p_seen_candidate_digest: digest2,
      p_reason: 'Kjedeprøve: publisering uten sluttkontroll.',
    })
    check(
      'en kandidat uten sluttkontroll kan ikke publiseres',
      beforeControl.error !== null,
      'publiseringen gikk gjennom',
    )

    await reviewer.rpc('record_candidate_final_control', {
      p_candidate_id: candidate2,
      p_seen_candidate_digest: digest2,
      p_decision: 'approved',
      p_rationale: 'Kjedeprøve: den presiserte formuleringen er lest.',
    })

    const replaced = await publisher.rpc('publish_candidate', {
      p_candidate_id: candidate2,
      p_seen_candidate_digest: digest2,
      p_reason: 'Kjedeprøve: den presiserte formuleringen tas i bruk.',
    })
    check(
      'den nyere revisjonen erstatter den publiserte',
      replaced.error === null && parsePublicationOutcome(replaced.data).event.action === 'replace',
      replaced.error?.message ?? '',
    )

    const rolled = await publisher.rpc('rollback_claim_publication', {
      p_claim_id: claimId,
      p_target_candidate_id: candidateId,
      p_seen_candidate_digest: view.candidateDigest,
      p_reason: 'Kjedeprøve: den presiserte formuleringen var feil.',
    })
    check(
      'rollbacken er en ny hendelse tilbake til det forrige innholdet',
      rolled.error === null && parsePublicationOutcome(rolled.data).event.action === 'rollback',
      rolled.error?.message ?? '',
    )

    const afterRollback = parsePublishedClaim(
      (await clinician.rpc('published_claim', { p_claim_id: claimId })).data,
    )
    check(
      'klinikerflaten viser igjen det tidligere godkjente innholdet',
      afterRollback.candidateId === candidateId &&
        JSON.stringify(afterRollback.content?.sealedContent) === JSON.stringify(view.sealedContent),
    )

    const byClinician = await clinician.rpc('withdraw_claim_publication', {
      p_claim_id: claimId,
      p_reason: 'Kjedeprøve: kliniker trekker tilbake.',
    })
    check(
      'tilbaketrekking krever publisher-mandat',
      byClinician.error !== null,
      'klinikeren fikk trekke tilbake',
    )

    const withdrawn = await publisher.rpc('withdraw_claim_publication', {
      p_claim_id: claimId,
      p_reason: 'Kjedeprøve: innholdet tas ut av visning.',
    })
    check(
      'tilbaketrekkingen registreres som en egen hendelse',
      withdrawn.error === null &&
        parsePublicationOutcome(withdrawn.data).event.action === 'withdraw',
      withdrawn.error?.message ?? '',
    )

    const afterWithdraw = parsePublishedClaim(
      (await clinician.rpc('published_claim', { p_claim_id: claimId })).data,
    )
    check(
      'det tilbaketrukne innholdet presenteres ikke lenger som gjeldende',
      !afterWithdraw.published && afterWithdraw.withdrawn && afterWithdraw.content === null,
    )
    check(
      'men hele historikken er bevart og tilbaketrekkingen er synlig',
      afterWithdraw.history.length === 4 &&
        afterWithdraw.history[0]?.action === 'withdraw' &&
        afterWithdraw.history.map((event) => event.action).join(',') ===
          'withdraw,rollback,replace,publish',
    )
    check(
      'ingen publiseringshendelse er slettet eller skrevet om',
      psql(
        config,
        `select count(*)::text from knowledge.publication_events pe
         where pe.claim_id = ${q(claimId)}`,
      ) === '4',
    )

    // ------------------------------------------------------------------
    // Ekstern agent-handoff: Antidep → KI-agent → Antidep
    //
    // Det samme leddet en gang til, men uten en eneste fil på disk og uten en
    // kjøremappe: oppgaven bygges av databasen, «agenten» er koden under, og
    // svaret går inn gjennom api.import_agent_answer. Prøven finnes her og ikke
    // bare i vitest fordi grensen som skal prøves, er den mellom
    // oppgavekontrakten i TypeScript og de api-funksjonene som faktisk tar imot
    // den.
    // ------------------------------------------------------------------
    const otherDrugId = psql(
      config,
      `select id from catalog.drugs where canonical_name = 'mirtazapin'`,
    )

    const enqueuedTask = await editor.rpc('enqueue_agent_task', {
      p_agent_role: 'evidence_extraction',
      p_input_manifest: {
        source_version_id: report.sourceVersionId,
        drug_ids: [otherDrugId],
        outcome_concept_ids: [outcomeId],
        population_ids: [populationId],
      },
    })
    check(
      'agentoppgaven legges inn med en utledet nøkkel',
      enqueuedTask.error === null,
      enqueuedTask.error?.message ?? '',
    )
    const handoffJobId = (enqueuedTask.data as { pipeline_job_id?: string } | null)?.pipeline_job_id
    if (handoffJobId === undefined) return

    // Uttaket kommer etter valget av KI-tjeneste. Tildelingen inngår i
    // bindingen avtrykket er regnet av, og en oppgave bygget uten den ville bedt
    // om et svar ingen kunne si var uavhengig (ANTIDEP_CONSTITUTION.md regel 3).
    const beforeAssignment = await editor.rpc('agent_task_payload', {
      p_pipeline_job_id: handoffJobId,
    })
    check(
      'oppgaven kan ikke hentes ut før en KI-tjeneste er valgt for leddet',
      beforeAssignment.error !== null,
      'oppgaven ble bygget uten en modelltildeling',
    )
    const blockedQueue = parseAgentWorkQueue((await editor.rpc('agent_work_queue', {})).data)
    check(
      'agentkøen sier at tjenesten mangler framfor å vise oppgaven som utførbar',
      blockedQueue.items.some(
        (item) => item.pipelineJobId === handoffJobId && item.blockedReason !== null,
      ),
    )

    const assignment = await editor.rpc('assign_agent_role_model', {
      p_agent_role: 'evidence_extraction',
      p_provider: 'antidep-test',
      p_model: 'ekstern-kjedeagent',
      p_model_version_disclosure: 'not_exposed',
      p_reason: 'Kjedeprøven: tjenesten som utfører ekstraksjonsutkastet.',
    })
    check(
      'KI-tjenesten for leddet velges av redaktøren, før oppgaven hentes ut',
      assignment.error === null,
      assignment.error?.message ?? '',
    )

    const queue = parseAgentWorkQueue((await editor.rpc('agent_work_queue', {})).data)
    check(
      'agentkøen viser oppgaven med hva den gjelder, og ingenting som hindrer den',
      queue.items.some(
        (item) =>
          item.pipelineJobId === handoffJobId &&
          item.blockedReason === null &&
          item.registeredModel?.model === 'ekstern-kjedeagent' &&
          item.subjectLabel.length > 0,
      ),
    )

    const taskPayload = await editor.rpc('agent_task_payload', {
      p_pipeline_job_id: handoffJobId,
    })
    check(
      'oppgaven kan hentes ut av flaten',
      taskPayload.error === null,
      taskPayload.error?.message ?? '',
    )
    if (taskPayload.error !== null) return
    const agentTask = parseAgentTask(taskPayload.data)

    // Filen brukeren laster ned. Den skal bære hele artikkelen, slik at ingen
    // trenger original-PDF-en ved siden av.
    const taskFile = renderAgentTaskFile(agentTask)
    check(
      'oppgavefilen bærer hele den kontrollerte fullteksten og avtrykket',
      taskFile.includes('Mean percent weight change in the mirtazapine arm was 3.0%') &&
        taskFile.includes(agentTask.requestDigest) &&
        taskFile.includes('### Svarmal'),
    )

    const otherArmMethod =
      'A parallel mirtazapine arm of forty-two patients was followed for the same period.'
    const otherArmResult =
      'Mean percent weight change in the mirtazapine arm was 3.0% at endpoint with a 95% confidence interval from 2.1% to 3.9%.'

    const handoffResult = {
      extraction: {
        design_code: 'randomized_controlled_trial',
        population_id: populationId,
        population_availability: 'reported_value',
        population_detail: 'Voksne med depressiv lidelse.',
        sample_size: 42,
        sample_size_availability: 'reported_value',
        intervention_drug_id: otherDrugId,
        comparator_kind: 'none',
        outcome_concept_id: outcomeId,
        outcome_detail: 'Gjennomsnittlig prosentvis vektendring ved endepunkt.',
        timepoint_min: '26 weeks',
        timepoint_max: '32 weeks',
        timepoint_availability: 'reported_value',
        reported_direction: 'increase',
        effect_measure: 'mean_change',
        estimate: '3.0',
        estimate_unit: 'percent',
        estimate_availability: 'reported_value',
        ci_lower: '2.1',
        ci_upper: '3.9',
        ci_level_percent: '95',
        confidence_interval_availability: 'reported_value',
        source_locator: 'Syntetisk fulltekst, resultater',
        source_quote: otherArmResult,
      },
      field_groundings: [
        ['intervention_arm', otherArmMethod],
        ['sample_size', otherArmMethod],
        ['outcome', otherArmResult],
        ['estimate', otherArmResult],
        ['effect_measure', otherArmResult],
        ['reported_direction', otherArmResult],
        ['confidence_interval', otherArmResult],
        ['timepoint', otherArmMethod],
        ['population', methodExcerpt],
        ['availability_semantics', otherArmResult],
      ].map(([field, excerpt]) => ({
        check_field: field,
        source_excerpt: excerpt,
        source_locator: 'RESULTS',
        justification: `Utdraget oppgir verdien for ${String(field)}.`,
      })),
    }

    // «KI-agenten»: kopierer bindingsverdiene uendret ut av oppgaven, og fyller
    // inn de to tingene bare den vet.
    const handoffAnswer = {
      answer_version: agentTask.answerVersion,
      task_version: agentTask.taskVersion,
      role: agentTask.role,
      job_key: agentTask.jobKey,
      request_digest: agentTask.requestDigest,
      output_schema_version: agentTask.outputSchemaVersion,
      identity: {
        provider: 'antidep-test',
        model: 'ekstern-kjedeagent',
        model_version_disclosure: 'not_exposed',
      },
      answered_at: new Date().toISOString(),
      result: handoffResult,
    }

    const parsedAnswer = parseAgentAnswer(handoffAnswer)
    check(
      'svaret hører til oppgaven, og utkastet står ordrett i kildeteksten',
      answerBindingProblem(agentTask, parsedAnswer) === null &&
        handoffResultProblem(agentTask, parsedAnswer.result) === null,
      answerBindingProblem(agentTask, parsedAnswer) ??
        handoffResultProblem(agentTask, parsedAnswer.result) ??
        '',
    )

    const imported = await editor.rpc('import_agent_answer', {
      p_pipeline_job_id: handoffJobId,
      p_answer: handoffAnswer,
    })
    check(
      'det eksterne agentsvaret registreres gjennom den kontrollerte skriveveien',
      imported.error === null && parseImportOutcome(imported.data).imported,
      imported.error?.message ?? '',
    )
    if (imported.error !== null) return
    const importOutcome = parseImportOutcome(imported.data)

    check(
      'kjøringen bærer den eksterne modellen som faktisk gjorde arbeidet',
      psql(
        config,
        `select format('%s/%s/%s', r.semantic_provider, r.semantic_model, r.semantic_model_version)
         from provenance.agent_runs r where r.id = ${q(importOutcome.agentRunId)}`,
      ) === 'antidep-test/ekstern-kjedeagent/ikke-eksponert',
    )

    const importedAgain = await editor.rpc('import_agent_answer', {
      p_pipeline_job_id: handoffJobId,
      p_answer: handoffAnswer,
    })
    check(
      'det samme svaret sendt inn igjen lager ingen doble kliniske artefakter',
      importedAgain.error === null &&
        parseImportOutcome(importedAgain.data).alreadyImported &&
        psql(
          config,
          `select count(*)::text from knowledge.evidence_items e
           where e.source_version_id = ${q(report.sourceVersionId)}
             and e.intervention_drug_id = ${q(otherDrugId)}`,
        ) === '1',
      importedAgain.error?.message ?? '',
    )

    // Et svar avgitt på en oppgave som siden har fått et annet grunnlag, har et
    // annet avtrykk. Her prøves den samme regelen med et avtrykk som aldri var
    // oppgavens.
    const staleJob = await editor.rpc('enqueue_agent_task', {
      p_agent_role: 'evidence_extraction',
      p_input_manifest: {
        source_version_id: report.sourceVersionId,
        drug_ids: [otherDrugId, drugId],
        outcome_concept_ids: [outcomeId],
        population_ids: [populationId],
      },
    })
    const staleJobId = (staleJob.data as { pipeline_job_id?: string } | null)?.pipeline_job_id ?? ''
    const staleTask = parseAgentTask(
      (await editor.rpc('agent_task_payload', { p_pipeline_job_id: staleJobId })).data,
    )

    // Svaret bindes til nettopp denne oppgaven, og bare avtrykket byttes ut.
    // Ellers ville avvisningen kommet på oppgavenøkkelen framfor på avtrykket,
    // og prøven ville sett grønn ut uten å ha prøvd regelen.
    const answerForStaleJob = (
      identity: Record<string, unknown>,
      requestDigest: string,
    ): Record<string, unknown> => ({
      answer_version: staleTask.answerVersion,
      task_version: staleTask.taskVersion,
      role: staleTask.role,
      job_key: staleTask.jobKey,
      request_digest: requestDigest,
      output_schema_version: staleTask.outputSchemaVersion,
      identity,
      result: handoffResult,
    })
    const chainIdentity = {
      provider: 'antidep-test',
      model: 'ekstern-kjedeagent',
      model_version_disclosure: 'not_exposed',
    }

    const stale = await editor.rpc('import_agent_answer', {
      p_pipeline_job_id: staleJobId,
      p_answer: answerForStaleJob(chainIdentity, `sha256:${'a'.repeat(64)}`),
    })
    check('et svar avgitt på et annet grunnlag avvises', stale.error !== null)

    // Synteseleddet trenger sin egen tildeling før det kan ta imot et svar.
    //
    // Om *flere* ledd kan dele den samme modellen, prøves ikke her, og det er
    // med vilje: denne filen kjøres også av `db-upgrade-monograph.sh` mot en
    // base satt til siste migrasjon før monografien — altså før 013t, der den
    // gamle regelen fortsatt gjelder. En påstand om modelldeling ville hatt to
    // forskjellige riktige svar avhengig av hvor langt basen er migrert, og en
    // prøve som måtte spørre om det først, prøver ikke en regel.
    //
    // Regelen prøves der den alltid gjelder: i pgTAP mot en ferdig migrert base
    // (750 på registeret, 780 gjennom `api.assign_agent_role_model`, 860 på de
    // to kildeleddene).
    const synthesisModel = await editor.rpc('assign_agent_role_model', {
      p_agent_role: 'claim_synthesis',
      p_provider: 'antidep-test',
      p_model: 'ekstern-kjedeagent-to',
      p_model_version_disclosure: 'not_exposed',
      p_reason: 'Kjedeprøven: en egen tjeneste for synteseleddet.',
    })
    check(
      'synteseleddet kan tildeles sin egen tjeneste',
      synthesisModel.error === null,
      synthesisModel.error?.message ?? '',
    )

    // Og identiteten kan ikke lånes: et svar som utgir seg for å være det andre
    // leddets modell, avvises. Uten tildelingen på forhånd var dette hullet —
    // svaret selv etablerte premisset som autoriserte det.
    const borrowed = await editor.rpc('import_agent_answer', {
      p_pipeline_job_id: staleJobId,
      p_answer: answerForStaleJob(
        {
          provider: 'antidep-test',
          model: 'ekstern-kjedeagent-to',
          model_version_disclosure: 'not_exposed',
        },
        staleTask.requestDigest,
      ),
    })
    check(
      'et svar som utgir seg for å være et annet ledds modell, avvises',
      borrowed.error !== null,
    )

    // Forhåndskontrollen i køen er importens egen: funnet handoffen nettopp
    // registrerte, er ikke kontrollert av noen ennå, og en syntese på det kunne
    // aldri blitt registrert. Da skal oppgaven heller ikke kunne legges inn
    // (ANTIDEP_CONSTITUTION.md regel 4).
    const unverifiedSynthesis = await editor.rpc('enqueue_agent_task', {
      p_agent_role: 'claim_synthesis',
      p_input_manifest: {
        topic_concept_id: outcomeId,
        subject_drug_id: otherDrugId,
        evidence_item_ids: [String(importOutcome.outcome['evidence_item_id'])],
      },
    })
    check(
      'en synteseoppgave på et ukontrollert evidensfunn kan ikke legges inn',
      unverifiedSynthesis.error !== null,
      'køen godtok en oppgave importen måtte avvist',
    )

    // ------------------------------------------------------------------
    // En leie tilhører den som tok den
    //
    // Hvert RPC-kall under er sin egen commitede transaksjon, så dette er en
    // ekte samtidighetsprøve på tvers av forbindelser — og den kan ikke gjøres
    // i pgTAP, der alt ligger i én transaksjon som rulles tilbake.
    //
    // Først: en vanlig kjører får ikke ta ut en ekstern agentoppgave i det hele
    // tatt. Uten det ville det samme arbeidet blitt gjort to ganger, i to
    // modellidentiteter (ANTIDEP_CONSTITUTION.md regel 4, 7).
    // ------------------------------------------------------------------
    const claimAttempt = await agent.rpc('claim_pipeline_job', {
      p_identity_key: 'agent-identity:evidence-extraction-01',
      p_secret: secret,
      p_agent_role: 'evidence_extraction',
    })
    check(
      'en automatisert kjører tar ikke ut en ekstern agentoppgave',
      claimAttempt.error === null &&
        (claimAttempt.data as { claimed?: boolean } | null)?.claimed === false,
      claimAttempt.error?.message ?? 'kjøreren tok en handoff-jobb',
    )

    // Og motsatt: en vanlig pipelinejobb i den samme rollen kan tas. Uten dette
    // paret kunne regelen over vært oppfylt av en kø som var tom.
    psql(
      config,
      `insert into workflow.pipeline_jobs
         (agent_role, job_key, input_manifest, enqueued_by_actor_id)
       values ('evidence_extraction', 'antidep2-kjede:intern-jobb',
               '{"mode":"antidep2-kjede"}'::jsonb, ${q(EDITOR_ACTOR)})
       returning id`,
    )
    const internalClaim = await agent.rpc('claim_pipeline_job', {
      p_identity_key: 'agent-identity:evidence-extraction-01',
      p_secret: secret,
      p_agent_role: 'evidence_extraction',
    })
    check(
      'en vanlig pipelinejobb i den samme rollen kan tas av kjøreren',
      internalClaim.error === null &&
        (internalClaim.data as { claimed?: boolean; job_key?: string } | null)?.job_key ===
          'antidep2-kjede:intern-jobb',
      internalClaim.error?.message ?? 'kjøreren fikk ingen jobb',
    )

    // Så: en leie som løper, kan ikke overtas av importen. Uttaket settes
    // direkte, fordi kjøreren nettopp ble nektet å ta oppgaven — og det er
    // nøyaktig den tilstanden en gammel kjøring ville etterlatt.
    psql(
      config,
      `update workflow.pipeline_jobs
       set state = 'leased', attempts = 1,
           leased_by_agent_identity_id = (select id from provenance.agent_identities
                                          where identity_key = 'agent-identity:evidence-extraction-01'),
           lease_token = gen_random_uuid(),
           lease_expires_at = now() + interval '15 minutes'
       where id = ${q(staleJobId)}`,
    )
    const heldBefore = psql(
      config,
      `select format('%s|%s', j.attempts, j.lease_token)
       from workflow.pipeline_jobs j where j.id = ${q(staleJobId)}`,
    )
    const stolen = await editor.rpc('import_agent_answer', {
      p_pipeline_job_id: staleJobId,
      p_answer: answerForStaleJob(chainIdentity, staleTask.requestDigest),
    })
    check(
      'en oppgave med en løpende leie kan ikke overtas av importen',
      stolen.error !== null &&
        psql(
          config,
          `select format('%s|%s', j.attempts, j.lease_token)
           from workflow.pipeline_jobs j where j.id = ${q(staleJobId)}`,
        ) === heldBefore,
      'importen tok over uttaket fra en kjøring som holdt det',
    )

    // Leien løper ut, og oppgaven er ledig igjen. Uten dette ville en kjører som
    // døde, låst oppgaven for alltid — og regelen over vært trivielt oppfylt.
    psql(
      config,
      `update workflow.pipeline_jobs
       set lease_expires_at = now() - interval '1 minute'
       where id = ${q(staleJobId)}`,
    )
    check(
      'en utløpt leie gjør oppgaven ledig igjen',
      psql(
        config,
        `select coalesce(workflow.agent_task_problem(j), 'ledig')
         from workflow.pipeline_jobs j where j.id = ${q(staleJobId)}`,
      ) === 'ledig',
    )

    // Et bytte av tjeneste ugyldiggjør de utestående oppgavene: tildelingen
    // inngår i avtrykket, så et svar avgitt under den forrige tildelingen kan
    // ikke komme tilbake og registrere den gamle modellen på nytt.
    const digestBefore = staleTask.requestDigest
    const switched = await editor.rpc('assign_agent_role_model', {
      p_agent_role: 'evidence_extraction',
      p_provider: 'antidep-test',
      p_model: 'ekstern-kjedeagent-tre',
      p_model_version_disclosure: 'not_exposed',
      p_reason: 'Kjedeprøven: leddet bytter tjeneste.',
      p_replaces_reason: 'Kjedeprøven: den forrige tjenesten er ikke i bruk lenger.',
    })
    check(
      'et ledd kan bytte tjeneste, med hvem og hvorfor',
      switched.error === null &&
        (switched.data as { replaced?: boolean } | null)?.replaced === true,
      switched.error?.message ?? 'byttet ble ikke registrert som et bytte',
    )
    const staleTaskAfter = parseAgentTask(
      (await editor.rpc('agent_task_payload', { p_pipeline_job_id: staleJobId })).data,
    )
    check(
      'et tjenestebytte gir den utestående oppgaven et nytt avtrykk',
      staleTaskAfter.requestDigest !== digestBefore,
    )
    const afterSwitch = await editor.rpc('import_agent_answer', {
      p_pipeline_job_id: staleJobId,
      p_answer: answerForStaleJob(chainIdentity, digestBefore),
    })
    check(
      'et svar avgitt under den forrige tildelingen kan ikke importeres etter byttet',
      afterSwitch.error !== null,
    )
  } finally {
    rmSync(work, { recursive: true, force: true })
  }

  if (process.exitCode === 1) {
    console.error('\nMinst én Antidep 2-kjedekontroll slo feil.')
  } else {
    console.log('\nAntidep 2-kjeden gikk gjennom.')
  }
}

await main()
