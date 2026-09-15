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
// not pretend otherwise. Publication stays closed: the chain asserts that no
// publication event exists when it is done.

import { execFileSync } from 'node:child_process'
import { createHash, createHmac } from 'node:crypto'
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
import { syntheticArticlePdf } from '../src/agents/test-support.ts'
import { parseCandidateView, canBeFinalControlled } from '../src/lib/candidate-view.ts'
import {
  buildAssignmentFromCatalog,
  type EditorCatalogApi,
} from '../src/ops/extraction-assignment.ts'

interface Config {
  readonly dbUrl: string
  readonly apiUrl: string
  readonly anonKey: string
  readonly jwtSecret: string
}

const DEFAULTS = {
  dbUrl: 'postgresql://postgres:postgres@127.0.0.1:54322/postgres',
  apiUrl: 'http://127.0.0.1:54321',
  jwtSecret: 'super-secret-jwt-token-with-at-least-32-characters-long',
}

const SOURCE = 'c2000000-0000-4000-8000-000000000001'
const EDITOR_USER = 'c2000000-0000-4000-8000-0000000000e0'
const EDITOR_ACTOR = 'c2000000-0000-4000-8000-0000000000e1'
// Sluttkontrollen er et menneskes beslutning, og et annet menneske enn den som
// bygger kandidaten: mandatene er forskjellige, og prøven later ikke som noe
// annet (ANTIDEP_CONSTITUTION.md regel 5, §12).
const REVIEWER_USER = 'c2000000-0000-4000-8000-0000000000f0'
const REVIEWER_ACTOR = 'c2000000-0000-4000-8000-0000000000f1'

function localAnonKey(): string {
  const output = execFileSync('npx', ['supabase', 'status', '-o', 'env'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'inherit'],
  })
  const match = /^ANON_KEY="?([^"\n]+)"?$/m.exec(output)
  if (match?.[1] === undefined) {
    throw new Error('Fant ikke ANON_KEY i `supabase status -o env`.')
  }
  return match[1]
}

function readConfig(argv: readonly string[]): Config {
  const flags = new Map<string, string>()
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i]
    const value = argv[i + 1]
    if (flag === undefined || value === undefined || !flag.startsWith('--')) {
      throw new Error(`Ukjent argument: ${String(flag)}`)
    }
    flags.set(flag.slice(2), value)
  }
  return {
    dbUrl: flags.get('db-url') ?? DEFAULTS.dbUrl,
    apiUrl: flags.get('api-url') ?? DEFAULTS.apiUrl,
    anonKey: flags.get('anon-key') ?? process.env['ANTIDEP_LOCAL_ANON_KEY'] ?? localAnonKey(),
    jwtSecret: flags.get('jwt-secret') ?? DEFAULTS.jwtSecret,
  }
}

function q(value: string): string {
  return `'${value.replace(/'/g, "''")}'`
}

function psql(config: Config, sql: string): string {
  const output = execFileSync(
    'psql',
    [config.dbUrl, '-q', '-v', 'ON_ERROR_STOP=1', '-t', '-A', '-c', sql],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] },
  )
  return (
    output
      .split('\n')
      .map((line) => line.trim())
      .find((line) => line.length > 0) ?? ''
  )
}

function userToken(config: Config, userId: string): string {
  const b64 = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url')
  const now = Math.floor(Date.now() / 1000)
  const head = b64({ alg: 'HS256', typ: 'JWT' })
  const body = b64({
    sub: userId,
    role: 'authenticated',
    aud: 'authenticated',
    iat: now,
    exp: now + 3600,
  })
  const signature = createHmac('sha256', config.jwtSecret)
    .update(`${head}.${body}`)
    .digest('base64url')
  return `${head}.${body}.${signature}`
}

function check(name: string, condition: boolean, detail = ''): void {
  if (condition) {
    console.log(`  ok   ${name}`)
    return
  }
  console.error(`  FEIL ${name}${detail === '' ? '' : `: ${detail}`}`)
  process.exitCode = 1
}

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
    delete from workflow.pipeline_jobs where job_key like 'antidep2-kjede:%';
    delete from knowledge.full_text_readability_checks where source_version_id in (
      select id from knowledge.source_versions where source_id = ${q(SOURCE)});
    delete from knowledge.source_document_publications where source_id = ${q(SOURCE)};
    delete from knowledge.source_identifiers where source_id = ${q(SOURCE)};
    delete from workflow.user_roles where user_id in (${q(EDITOR_USER)}, ${q(REVIEWER_USER)});
    delete from provenance.actors where id in (${q(EDITOR_ACTOR)}, ${q(REVIEWER_ACTOR)});
    delete from auth.users where id in (${q(EDITOR_USER)}, ${q(REVIEWER_USER)});
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
            'authenticated', 'authenticated', 'antidep2-kjede-fagperson@example.test');

    insert into provenance.actors
      (id, actor_key, actor_type, display_name, description, auth_user_id)
    values (${q(EDITOR_ACTOR)}, 'human:antidep2-kjede-editor', 'human',
            'Antidep 2 kjedeprøvens editor', 'Bare for scripts/agent-chain-test.ts.',
            ${q(EDITOR_USER)}),
           (${q(REVIEWER_ACTOR)}, 'human:antidep2-kjede-fagperson', 'human',
            'Antidep 2 kjedeprøvens fagperson', 'Bare for scripts/agent-chain-test.ts.',
            ${q(REVIEWER_USER)});

    insert into workflow.user_roles
      (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
    values (${q(EDITOR_USER)}, 'editor', null, now() - interval '1 day',
            (select id from provenance.actors where actor_key = 'human:peder-holman'),
            'Antidep 2 syntetisk kjedeprøve.'),
           (${q(REVIEWER_USER)}, 'reviewer',
            (select id from catalog.clinical_concepts where canonical_label = 'vektendring'),
            now() - interval '1 day',
            (select id from provenance.actors where actor_key = 'human:peder-holman'),
            'Antidep 2 syntetisk kjedeprøve: sluttkontroll.');
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
  const config = readConfig(process.argv.slice(2))
  console.log('Antidep 2: PDF → oppdrag → agentekstraksjon → uavhengig verifikasjon.\n')

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

    const extraction = await runEvidenceExtraction({
      api: extractionApi,
      proposal,
      assignment: report.assignment,
      mode: 'with_assignment',
      documents,
    })
    const evidenceItemId = extraction.evidenceItemId ?? ''
    check(
      'ekstraksjonsagenten registrerer EvidenceItem fra fullteksten',
      extraction.decision === 'registered' && evidenceItemId !== '',
      extraction.reason ?? '',
    )
    if (evidenceItemId === '') return

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
    // Den varige, idempotente jobbtilstanden
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
    if (claimed.claimed) {
      const outcome = { evidence_item_id: evidenceItemId }
      await jobs.complete(
        claimed.job.pipelineJobId,
        claimed.job.leaseToken,
        outcome,
        extraction.agentRunId,
      )
      await jobs.complete(
        claimed.job.pipelineJobId,
        claimed.job.leaseToken,
        outcome,
        extraction.agentRunId,
      )
      check(
        'en fullført jobb kan meldes om igjen uten å skrive noe nytt',
        psql(
          config,
          `select (count(*) = 1)::text from workflow.pipeline_job_events e
           where e.pipeline_job_id = ${q(claimed.job.pipelineJobId)} and e.to_state = 'succeeded'`,
        ) === 'true',
      )
    }

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
      'kjeden oppretter ingen menneskelig mikroreview eller publisering',
      psql(
        config,
        `select (count(*) = 0)::text from workflow.review_decisions rd
         where rd.evidence_item_id = ${q(evidenceItemId)}`,
      ) === 'true' &&
        psql(
          config,
          `select (count(*) = 0)::text from knowledge.publication_events pe
           join knowledge.claims c on c.id = pe.claim_id
           where c.id::text like 'c2000000%'`,
        ) === 'true',
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
