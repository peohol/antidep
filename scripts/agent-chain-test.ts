// Antidep 2 end-to-end database chain.
//
// This deliberately stops at an independently verified, document-bound
// EvidenceItem. Human responsibility belongs at the final product/publication
// boundary and is therefore not simulated by this infrastructure test.

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
import { syntheticPdf } from '../src/agents/test-support.ts'
import { buildAssignmentFromCatalog, type EditorCatalogApi } from '../src/ops/extraction-assignment.ts'

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
    delete from workflow.user_roles where user_id = ${q(EDITOR_USER)};
    delete from provenance.actors where id = ${q(EDITOR_ACTOR)};
    delete from auth.users where id = ${q(EDITOR_USER)};
    reset session_replication_role;

    insert into knowledge.sources
      (id, source_type, title, authors_or_issuer, created_by_actor_id)
    values (
      ${q(SOURCE)}, 'journal_article', 'Antidep 2 syntetisk kjedeprøve',
      'Testforfatter',
      (select id from provenance.actors where actor_key = 'human:peder-holman')
    );

    insert into auth.users (id, instance_id, aud, role, email)
    values (${q(EDITOR_USER)}, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated', 'antidep2-kjede-editor@example.test');

    insert into provenance.actors
      (id, actor_key, actor_type, display_name, description, auth_user_id)
    values (${q(EDITOR_ACTOR)}, 'human:antidep2-kjede-editor', 'human',
            'Antidep 2 kjedeprøvens editor', 'Bare for scripts/agent-chain-test.ts.',
            ${q(EDITOR_USER)});

    insert into workflow.user_roles
      (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
    values (${q(EDITOR_USER)}, 'editor', null, now() - interval '1 day',
            (select id from provenance.actors where actor_key = 'human:peder-holman'),
            'Antidep 2 syntetisk kjedeprøve.');
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
    const pdf = syntheticPdf([
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
        ci_level_percent: 95,
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
    check('modellsvaret blir et kildeforankret forslag', closed.outcome === 'drafted', closed.reason ?? '')
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
      'maskinbeviset gjelder og alle nødvendige kontrollfelt er dekket',
      psql(config, `select workflow.grounding_machine_proved(${q(evidenceItemId)})::text`) ===
        'true' &&
        psql(
          config,
          `select count(*) from (
             select unnest(workflow.required_check_fields(${q(evidenceItemId)}))::text
             except
             select unnest(workflow.covered_check_fields(${q(evidenceItemId)}))::text
           ) missing`,
        ) === '0',
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
