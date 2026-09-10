// ============================================================================
// Ende-til-ende: den ekte ekstraksjonskjøringen, mot den ekte databasen
//
//   npm run db:test:chain                       # mot den lokale stacken
//   npm run db:test:chain -- --db-url <url> --api-url <url> --anon-key <key>
//
// ----------------------------------------------------------------------------
// Hvorfor dette ikke er en vitest-fil, og ikke en pgTAP-fil
//
// pgTAP-filene kjører i én transaksjon som rulles tilbake, og kan bare prøve
// SQL. Vitest-filene kjører uten database, og må derfor bruke doble for
// databaseflaten. Grensen mellom dem — at parameternavnene `agent-api.ts`
// sender, er nøyaktig de `api`-funksjonene tar imot, og at det TypeScript-koden
// tror den skrev, faktisk er det som står i basen — er ikke prøvd av noen av
// dem. Det er den grensen denne filen finnes for.
//
// Alt som rører nettet er fortsatt fikstur: kildeteksten leveres av en injisert
// `retrieve`. Alt annet er ekte — PostgREST, `api`-funksjonene, constraintene,
// triggerne og publiseringsgaten.
//
// ----------------------------------------------------------------------------
// Kjeden som prøves
//
//   api.begin_agent_run                     ekstraksjonskjøringen åpnes
//   api.register_agent_extraction           forankret evidensfunn registreres
//   api.extraction_verification_input       verifikatoren leser grunnlaget
//   api.register_extraction_verification    maskinbeviset registreres
//   api.register_human_extraction_verification   mennesket bedømmer semantikken
//   api.register_human_claim_verification    påstanden kontrolleres
//   api.register_publication_approval        publiseringsbeslutningen
//   api.publish_claim_revision               publiseringen
//   runExtractionDrafting                    modell-leddet, med opptaksadapteret
//   openDraftingJob / closeDraftingJob       Routine-grensesnittet, som filer
//
// De to første og de to neste går gjennom de ekte kjørerne
// (`runEvidenceExtraction`, `runExtractionVerification`) med de ekte portene
// (`createEvidenceExtractionApi`, `createExtractionVerificationApi`). De
// menneskelige leddene kalles som en innlogget bruker, med en JWT signert med
// den lokale stackens egen nøkkel.
//
// ----------------------------------------------------------------------------
// Re-ekstraksjonen, som er den samme kjeden med to krav til
//
// Til slutt kjøres `runReextraction` gjennom de samme portene, og prøver de to
// tingene bare en ekte database kan avgjøre:
//
//   * at en tørrkjøring ikke skriver en evidensrad, men likevel lukker
//     kjøringen sin med en begrunnelse — `agent_runs_status_shape_check` godtar
//     ikke en avsluttet kjøring uten det, og en dobbel for databasen ville ikke
//     merket forskjellen, og
//   * at det samme forslaget kjørt om igjen ikke skriver noe, fordi
//     `evidence_items_content_hash_key` avviser dubletten. Idempotensen har
//     ingen lokal bokføring; fasiten er basen.
//
// Samtidig prøves regelen re-ekstraksjonen finnes for: det gamle, uforankrede
// funnet står urørt ved siden av det nye, uten forankring lagt til i etterkant.
//
// Og til slutt identitetsregelen fra migrasjon 003d: et forslag med de samme
// strukturerte verdiene, men ett rettet ordrett utdrag, er et *nytt* evidensfunn.
// Det går hele veien til et gyldig maskinbevis, mens den gamle raden står urørt
// og beholder sin egen kontroll, sin claim-lenke og sin publiserte påstand.
//
// ----------------------------------------------------------------------------
// Modell-leddet, kjørt deterministisk
//
// Siste ledd er `runExtractionDrafting` med opptaksadapteret: leddet som leser
// representasjonen og foreslår verdier, uten leverandørkonto og uten kostnad.
// Tre ting kan bare prøves mot en ekte database:
//
//   * at forslaget modellen produserte, går uendret gjennom filformen og de
//     ekte portene til et gyldig maskinbevis,
//   * at kjøringen registreres med *modellens* leverandør, modell,
//     modellversjon og promptmalversjon — ikke med en fast verdi — og at
//     kontrollgrunnlaget viser dem (migrasjon 005ac), og
//   * at de samme verdiene erklært av et menneske blir en *annen* rad, ført som
//     `manual`, fordi ekstraksjonsmetoden inngår i fingeravtrykket
//     (migrasjon 005ab).
//
// Et utkast med et oppdiktet utdrag prøves også: det blir ikke et forslag, og
// ingenting i basen endrer seg av det.
// ============================================================================

import { execFileSync } from 'node:child_process'
import { createHmac } from 'node:crypto'
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
import { sourceVersionContentHash } from '../src/agents/content-hash.ts'
import {
  EXTRACTION_PROPOSAL_VERSION,
  parseExtractionProposal,
} from '../src/agents/extraction-proposal.ts'
import { runEvidenceExtraction } from '../src/agents/extraction-run.ts'
import { runExtractionVerification } from '../src/agents/extraction-verification-run.ts'
import type { RetrieveLike } from '../src/agents/extraction-verification-run.ts'
import { EXTRACTION_VERIFICATION_PREMISES } from '../src/agents/pipeline-version.ts'
import { runReextraction } from '../src/agents/reextraction-run.ts'
import {
  parseAssignmentJson,
  parseExtractionAssignment,
} from '../src/agents/extraction-assignment.ts'
import { serializeExtractionProposal } from '../src/agents/extraction-proposal.ts'
import { EXTRACTION_DRAFTING_PROMPT_VERSION } from '../src/agents/extraction-prompt.ts'
import { createModelClient } from '../src/agents/model-adapters.ts'
import { prepareDraftingRequest, runExtractionDrafting } from '../src/agents/drafting-run.ts'
import { closeDraftingJob, JOB_FILES, openDraftingJob } from '../src/agents/drafting-job.ts'
import { MODEL_ANSWER_VERSION } from '../src/agents/model-answer.ts'
import { readProposalFile } from '../src/agents/proposal-files.ts'

// ----------------------------------------------------------------------------
// Miljøet
// ----------------------------------------------------------------------------

interface Config {
  readonly dbUrl: string
  readonly apiUrl: string
  readonly anonKey: string
  readonly jwtSecret: string
}

const DEFAULTS = {
  dbUrl: 'postgresql://postgres:postgres@127.0.0.1:54322/postgres',
  apiUrl: 'http://127.0.0.1:54321',
  // Den lokale stackens faste utviklingsnøkkel. Ingen hemmelighet: den står i
  // Supabase CLI-ens egen dokumentasjon og gjelder bare `supabase start`.
  jwtSecret: 'super-secret-jwt-token-with-at-least-32-characters-long',
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

  const anonKey = flags.get('anon-key') ?? process.env['ANTIDEP_LOCAL_ANON_KEY'] ?? localAnonKey()
  return {
    dbUrl: flags.get('db-url') ?? DEFAULTS.dbUrl,
    apiUrl: flags.get('api-url') ?? DEFAULTS.apiUrl,
    anonKey,
    jwtSecret: flags.get('jwt-secret') ?? DEFAULTS.jwtSecret,
  }
}

/** Henter publishable key fra CLI-en, som er det eneste stedet den finnes. */
function localAnonKey(): string {
  const output = execFileSync('npx', ['supabase', 'status', '-o', 'env'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'inherit'],
  })
  const match = /^ANON_KEY="?([^"\n]+)"?$/m.exec(output)
  if (match?.[1] === undefined) {
    throw new Error('Fant ikke ANON_KEY i `supabase status -o env`. Er den lokale stacken startet?')
  }
  return match[1]
}

/**
 * Kjører SQL og gir tilbake den ene verdien spørringen ga.
 *
 * `-q` er ikke pynt: uten den skriver psql kommandostatusen etter radene, så en
 * `insert ... returning` gir «id» og «INSERT 0 1» på hver sin linje — og
 * kalleren, som venter én verdi, får to. Første ikke-tomme linje tas i tillegg,
 * slik at en tom linje foran ikke kan bli til en verdi.
 */
function psql(config: Config, sql: string): string {
  const output = execFileSync(
    'psql',
    [config.dbUrl, '-q', '-v', 'ON_ERROR_STOP=1', '-t', '-A', '-c', sql],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] },
  )
  const lines = output
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
  return lines[0] ?? ''
}

/**
 * En JWT for en innlogget bruker.
 *
 * De menneskelige skriveveiene leser `auth.uid()`, altså `sub` i tokenet
 * PostgREST fikk. Den lokale stacken signerer med en fast utviklingsnøkkel, så
 * tokenet lages her framfor å gå veien om GoTrue — prøven gjelder
 * skriveveiene, ikke innloggingen.
 */
function userToken(config: Config, userId: string): string {
  const base64url = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url')
  const now = Math.floor(Date.now() / 1000)
  const head = base64url({ alg: 'HS256', typ: 'JWT' })
  const body = base64url({
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

// ----------------------------------------------------------------------------
// Fiksturen
// ----------------------------------------------------------------------------

const SOURCE = 'c0000000-0000-4000-8000-000000000001'
const VERSION = 'c0000000-0000-4000-8000-000000000021'
const REVIEWER_USER = 'c0000000-0000-4000-8000-0000000000c0'
const REVIEWER_ACTOR = 'c0000000-0000-4000-8000-0000000000c1'
const PUBLISHER_USER = 'c0000000-0000-4000-8000-0000000000d0'
const PUBLISHER_ACTOR = 'c0000000-0000-4000-8000-0000000000d1'

const KILDETEKST = [
  '<PubmedArticle>',
  '  <AbstractText Label="METHODS">Sertraline patients were randomised for 8 weeks.</AbstractText>',
  '  <AbstractText Label="RESULTS">Sertraline weight change increased from baseline.</AbstractText>',
  '</PubmedArticle>',
].join('\n')

function retrieve(hash: string): RetrieveLike {
  return (url) =>
    Promise.resolve({
      status: 'ok',
      representation: {
        url,
        status: 200,
        contentType: 'text/xml',
        content: KILDETEKST,
        byteLength: Buffer.byteLength(KILDETEKST, 'utf8'),
        contentHash: hash,
        bytesAreUtf8: true,
      },
    })
}

function q(value: string): string {
  return `'${value.replace(/'/g, "''")}'`
}

/**
 * Setter opp fiksturen, og river den ned igjen først.
 *
 * Kjøringen skriver i en ekte database som ikke rulles tilbake, så prøven må
 * kunne kjøres om igjen. Alt den lager, har id-er med `c0000000`-prefiks, og
 * ryddes i motsatt rekkefølge av fremmednøklene.
 */
function seed(config: Config): { secret: string; verifierSecret: string } {
  psql(
    config,
    `
    set local session_replication_role = replica;
    delete from audit.events where object_id in (
      select id from workflow.evidence_verifications where evidence_item_id in (
        select id from knowledge.evidence_items where source_id = ${q(SOURCE)}));
    delete from workflow.claim_verifications cv using knowledge.claim_revisions r
      where cv.claim_revision_id = r.id and r.id::text like 'c0000000%';
    delete from workflow.review_decisions rd using knowledge.claim_revisions r
      where rd.claim_revision_id = r.id and r.id::text like 'c0000000%';
    delete from workflow.evidence_verifications where evidence_item_id in (
      select id from knowledge.evidence_items where source_id = ${q(SOURCE)});
    update knowledge.claims set current_published_revision_id = null
      where id::text like 'c0000000%';
    -- Publiseringshendelsene må bort før revisjonen, ellers ser den neste
    -- kjøringen at «revisjonen har vært publisert» og nekter å legge
    -- evidensgrunnlaget under den på nytt (migrasjon 006, forseglingen).
    -- Fremmednøkkelen ville normalt ha stoppet slettingen, men denne blokken
    -- kjører med session_replication_role = replica.
    delete from knowledge.publication_events where claim_id::text like 'c0000000%';
    delete from knowledge.claim_evidence_links where claim_revision_id::text like 'c0000000%';
    delete from knowledge.evidence_assessments where claim_revision_id::text like 'c0000000%';
    delete from knowledge.claim_revisions where id::text like 'c0000000%';
    delete from knowledge.claims where id::text like 'c0000000%';
    delete from knowledge.evidence_field_groundings where evidence_item_id in (
      select id from knowledge.evidence_items where source_id = ${q(SOURCE)});
    delete from knowledge.evidence_items where source_id = ${q(SOURCE)};
    delete from provenance.agent_runs where input_source_version_id = ${q(VERSION)};
    delete from knowledge.source_versions where id = ${q(VERSION)};
    delete from knowledge.sources where id = ${q(SOURCE)};
    delete from workflow.user_roles where user_id in (${q(REVIEWER_USER)}, ${q(PUBLISHER_USER)});
    delete from provenance.actors where id in (${q(REVIEWER_ACTOR)}, ${q(PUBLISHER_ACTOR)});
    delete from auth.users where id in (${q(REVIEWER_USER)}, ${q(PUBLISHER_USER)});
    `,
  )

  psql(
    config,
    `
    insert into knowledge.sources (id, source_type, title, authors_or_issuer, created_by_actor_id)
    values (${q(SOURCE)}, 'journal_article', 'Kjedeprøve', 'Testforfatter',
            (select id from provenance.actors where actor_key = 'human:peder-holman'));

    insert into knowledge.source_versions
      (id, source_id, retrieved_at, retrieved_from, content_hash, representation,
       retrieved_by_actor_id)
    values (${q(VERSION)}, ${q(SOURCE)}, now(), 'https://example.test/kjede',
            knowledge.source_version_content_hash(${q(KILDETEKST)}), 'abstract',
            (select id from provenance.actors where actor_key = 'human:peder-holman'));

    insert into auth.users (id, instance_id, aud, role, email)
    values (${q(REVIEWER_USER)}, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated', 'kjede-reviewer@example.test'),
           (${q(PUBLISHER_USER)}, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated', 'kjede-publisher@example.test');

    insert into provenance.actors
      (id, actor_key, actor_type, display_name, description, auth_user_id)
    values (${q(REVIEWER_ACTOR)}, 'human:kjede-reviewer', 'human', 'Kjedeprøvens reviewer',
            'Bare for scripts/agent-chain-test.ts.', ${q(REVIEWER_USER)}),
           (${q(PUBLISHER_ACTOR)}, 'human:kjede-publisher', 'human', 'Kjedeprøvens publisher',
            'Bare for scripts/agent-chain-test.ts.', ${q(PUBLISHER_USER)});

    insert into workflow.user_roles
      (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
    values (${q(REVIEWER_USER)}, 'reviewer', null, now() - interval '1 day',
            (select id from provenance.actors where actor_key = 'human:peder-holman'),
            'Kjedeprøve.'),
           (${q(PUBLISHER_USER)}, 'publisher', null, now() - interval '1 day',
            (select id from provenance.actors where actor_key = 'human:peder-holman'),
            'Kjedeprøve.');
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

function check(name: string, condition: boolean, detail = ''): void {
  if (condition) {
    console.log(`  ok   ${name}`)
    return
  }
  console.error(`  FEIL ${name}${detail === '' ? '' : `: ${detail}`}`)
  process.exitCode = 1
}

async function main(): Promise<void> {
  const config = readConfig(process.argv.slice(2))
  console.log('Kjeden fra ekstraksjonskjøring til publiserbar dekning, mot ekte database.\n')

  const { secret, verifierSecret } = seed(config)
  const contentHash = await sourceVersionContentHash(KILDETEKST)
  const client = createAgentClient({ url: config.apiUrl, publishableKey: config.anonKey })

  // ---- Ledd 1: ekstraksjonen, gjennom den ekte porten -----------------------
  //
  // Forslaget står som data og ikke inne i kallet, fordi ledd 8 trenger nøyaktig
  // de samme strukturerte verdiene med ett rettet utdrag. Var de skrevet av to
  // ganger, kunne de kommet fra hverandre, og påstanden om at forankringen alene
  // skiller de to radene ville sluttet å holde.
  const kjedeForslag = {
    proposal_version: EXTRACTION_PROPOSAL_VERSION,
    source_id: SOURCE,
    generated_by: {
      producer: 'human',
      provider: 'human',
      model: 'manuell-ekstraksjon',
      model_version: 'not_applicable',
      prompt_template_version: 'not_applicable',
      drafted_at: '2026-09-15T08:00:00Z',
    },
    source_version_id: VERSION,
    retrieved_from: 'https://example.test/kjede',
    content_hash: contentHash,
    extraction: {
      design_code: 'randomized_controlled_trial',
      population_availability: 'not_reported',
      population_detail: 'Voksne.',
      sample_size_availability: 'not_reported',
      intervention_drug_id: psql(
        config,
        `select id from catalog.drugs where canonical_name = 'sertralin'`,
      ),
      comparator_kind: 'none',
      outcome_concept_id: psql(
        config,
        `select id from catalog.clinical_concepts where canonical_label = 'vektendring'`,
      ),
      outcome_detail: 'Vektendring.',
      timepoint_availability: 'not_reported',
      reported_direction: 'increase',
      estimate_availability: 'not_reported',
      confidence_interval_availability: 'not_reported',
      source_locator: 'Sammendrag',
    },
    field_groundings: [
      {
        check_field: 'intervention_arm',
        source_excerpt: 'Sertraline patients were randomised for 8 weeks.',
        source_locator: 'METHODS',
        justification: 'Armen står i metodeavsnittet.',
      },
      {
        check_field: 'outcome',
        source_excerpt: 'Sertraline weight change increased from baseline.',
        source_locator: 'RESULTS',
        justification: 'Endepunktet står i resultatavsnittet.',
      },
      {
        check_field: 'reported_direction',
        source_excerpt: 'Sertraline weight change increased from baseline.',
        source_locator: 'RESULTS',
        justification: 'Retningen står i resultatavsnittet.',
      },
      {
        check_field: 'availability_semantics',
        source_excerpt: 'Sertraline patients were randomised for 8 weeks.',
        source_locator: 'METHODS',
        justification: 'Feltene uten verdi er ført som ikke rapportert.',
      },
    ],
  }

  const extraction = await runEvidenceExtraction({
    mode: 'without_assignment',
    api: createEvidenceExtractionApi(client, {
      identityKey: 'agent-identity:evidence-extraction-01',
      secret: agentSecret(secret),
    }),
    proposal: parseExtractionProposal(JSON.parse(JSON.stringify(kjedeForslag))),
    retrieve: retrieve(contentHash),
  })

  check('ekstraksjonen registrerte et evidensfunn', extraction.decision === 'registered')
  const itemId = extraction.evidenceItemId ?? ''
  check(
    'funnet er bundet til kjøringen og til kildeversjonen den leste',
    psql(
      config,
      `select count(*) from knowledge.evidence_items e
       join provenance.agent_runs r
         on r.id = e.agent_run_id and r.input_source_version_id = e.source_version_id
       where e.id = ${q(itemId)}`,
    ) === '1',
  )
  check(
    'forankringen dekker hvert semantisk felt',
    psql(
      config,
      `select cardinality(workflow.semantic_check_fields(${q(itemId)}))
              = cardinality(workflow.grounded_check_fields(${q(itemId)}))`,
    ) === 't',
  )
  check(
    'og ingenting er bevist ennå',
    psql(config, `select workflow.grounding_machine_proved(${q(itemId)})`) === 'f',
  )

  // ---- Ledd 2: den deterministiske kontrollen, gjennom den ekte porten ------
  const verification = await runExtractionVerification({
    api: createExtractionVerificationApi(client, {
      identityKey: 'agent-identity:extraction-verification-01',
      secret: agentSecret(verifierSecret),
    }),
    premises: EXTRACTION_VERIFICATION_PREMISES,
    evidenceItemId: itemId,
    retrieve: retrieve(contentHash),
  })

  check(
    'verifikatoren registrerte sin kontroll',
    verification.items[0]?.decision === 'registered',
    JSON.stringify(verification.items[0]),
  )
  check(
    'og maskinbeviset gjelder nå',
    psql(config, `select workflow.grounding_machine_proved(${q(itemId)})`) === 't',
  )

  // ---- Ledd 3–6: de menneskelige leddene, som innlogget bruker --------------
  const revision = psql(
    config,
    `
    with c as (
      insert into knowledge.claims
        (id, knowledge_type, topic_concept_id, subject_drug_id, created_by_actor_id)
      select 'c0000000-0000-4000-8000-000000000031', 'evidence_synthesis',
             (select id from catalog.clinical_concepts where canonical_label = 'vektendring'),
             (select id from catalog.drugs where canonical_name = 'sertralin'),
             (select id from provenance.actors where actor_key = 'agent:claim-synthesis')
      returning id, knowledge_type, subject_drug_id, created_by_actor_id
    ), r as (
      insert into knowledge.claim_revisions
        (id, claim_id, revision_number, knowledge_type, subject_drug_id,
         statement, scope, comparator_kind, direction, uncertainty_summary, created_by_actor_id)
      select 'c0000000-0000-4000-8000-000000000041', c.id, 1, c.knowledge_type, c.subject_drug_id,
             'Kjedeprøvens påstand.', 'Bare testdata.', 'none', 'increase',
             'Testusikkerhet.', c.created_by_actor_id
      from c returning id
    ), l as (
      insert into knowledge.claim_evidence_links
        (id, claim_revision_id, evidence_item_id, relationship_type, directness,
         relevance_note, created_by_actor_id)
      select 'c0000000-0000-4000-8000-000000000051', r.id, ${q(itemId)}, 'supports', 'direct',
             'Kjedeprøvens lenke.',
             (select id from provenance.actors where actor_key = 'agent:claim-synthesis')
      from r returning id
    )
    insert into knowledge.evidence_assessments
      (claim_revision_id, assessed_knowledge_type, framework, certainty_level,
       risk_of_bias, inconsistency, indirectness, imprecision, publication_bias,
       rationale, assessed_at, created_by_actor_id)
    select 'c0000000-0000-4000-8000-000000000041', 'evidence_synthesis', 'grade', 'low',
           'serious', 'not_assessable', 'not_serious', 'serious', 'not_assessable',
           'Kjedeprøve.', now(),
           (select id from provenance.actors where actor_key = 'agent:claim-synthesis')
    from l
    returning claim_revision_id
    `,
  )

  // De menneskelige leddene kalles som en innlogget bruker. Agentklienten har
  // med vilje ingen sesjon (`agent-api.ts`), så tokenet settes her, på en klient
  // som bare denne prøven bruker.
  const asUser = (userId: string) =>
    createClient(config.apiUrl, config.anonKey, {
      db: { schema: 'api' },
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${userToken(config, userId)}` } },
    })

  const extractionDigest = psql(config, `select workflow.evidence_extraction_digest(${q(itemId)})`)
  const human = await asUser(REVIEWER_USER).rpc('register_human_extraction_verification', {
    p_evidence_item_id: itemId,
    p_seen_extraction_digest: extractionDigest,
    p_outcome: 'verified',
    p_source_access: 'original_source',
    // Nøyaktig det mennesket bedømte. Provenansfeltene dekkes av maskinens rad.
    p_checked_fields: [
      'intervention_arm',
      'outcome',
      'reported_direction',
      'availability_semantics',
    ],
    p_rationale: 'Kjedeprøve: bedømte de semantiske feltene mot hvert felts eget kildeutdrag.',
  })
  check('mennesket bekreftet ekstraksjonen', human.error === null, human.error?.message ?? '')

  check(
    'de to radene dekker til sammen det gaten krever',
    psql(
      config,
      `select count(*) from (
         select unnest(workflow.required_check_fields(${q(itemId)}))::text
         except
         select unnest(workflow.covered_check_fields(${q(itemId)}))::text) as mangler`,
    ) === '0',
  )
  check(
    'og menneskets rad påstår ikke provenansfeltene',
    psql(
      config,
      `select count(*) from workflow.evidence_verifications ev
       where ev.evidence_item_id = ${q(itemId)} and ev.agent_run_id is null
         and ('source_locator' = any (ev.checked_fields)
              or 'raw_extraction' = any (ev.checked_fields))`,
    ) === '0',
  )

  const setDigest = psql(config, `select knowledge.claim_evidence_set_digest(${q(revision)})`)
  const claimCheck = await asUser(REVIEWER_USER).rpc('register_human_claim_verification', {
    p_claim_revision_id: revision,
    p_seen_evidence_set_digest: setDigest,
    p_outcome: 'verified',
    p_source_support: 'ok',
    p_population_match: 'ok',
    p_comparator_match: 'ok',
    p_timeframe_match: 'ok',
    p_direction_and_magnitude: 'ok',
    p_qualifiers_complete: 'ok',
    p_contradictory_evidence_represented: 'ok',
    p_citations: [
      {
        claim_evidence_link_id: 'c0000000-0000-4000-8000-000000000051',
        source_access: 'verifiable_representation',
        source_version_id: VERSION,
        checked_content_hash: contentHash,
        relationship_supported: 'ok',
      },
    ],
    p_rationale: 'Kjedeprøve: kontrollert punkt for punkt mot grunnlaget.',
  })
  check('påstanden er kontrollert', claimCheck.error === null, claimCheck.error?.message ?? '')

  const approval = await asUser(REVIEWER_USER).rpc('register_publication_approval', {
    p_claim_revision_id: revision,
    p_seen_evidence_set_digest: psql(
      config,
      `select knowledge.claim_evidence_set_digest(${q(revision)})`,
    ),
    p_decision: 'approved',
    p_rationale: 'Kjedeprøve: godkjent etter fullført kontroll.',
  })
  check('publiseringen er godkjent', approval.error === null, approval.error?.message ?? '')

  const published = await asUser(PUBLISHER_USER).rpc('publish_claim_revision', {
    p_claim_revision_id: revision,
    p_reason: 'Kjedeprøve: publisert etter fullført kontroll.',
  })
  check('påstanden er publisert', published.error === null, published.error?.message ?? '')
  check(
    'og står som gjeldende publiserte revisjon',
    psql(
      config,
      `select c.current_published_revision_id::text from knowledge.claims c
       join knowledge.claim_revisions r on r.claim_id = c.id where r.id = ${q(revision)}`,
    ) === revision,
  )

  // ---- Ledd 5: re-ekstraksjonen, gjennom de samme ekte portene -------------
  //
  // Et gammelt, uforankret evidensfunn skal ikke muteres og skal ikke få
  // forankring lagt til i etterkant: ingen vet hvilke utdrag det faktisk ble
  // laget av. Re-ekstraksjonen legger et nytt, forankret funn ved siden av det.
  //
  // Idempotensen prøves der den faktisk avgjøres — mot
  // evidence_items_content_hash_key i en ekte database. Ingen lokal bokføring.
  const legacyItem = psql(
    config,
    `insert into knowledge.evidence_items
       (source_id, source_version_id, design_code, population_availability, population_detail,
        sample_size_availability, intervention_drug_id, comparator_kind, outcome_concept_id,
        outcome_detail, timepoint_availability, reported_direction, estimate_availability,
        confidence_interval_availability, source_locator, extraction_method, created_by_actor_id)
     select ${q(SOURCE)}, ${q(VERSION)}, 'randomized_controlled_trial', 'not_reported',
            'Kjedeprøvens gamle, uforankrede funn.', 'not_reported', d.id, 'none', c.id,
            'Vektendring, ført opp for hånd.', 'not_reported', 'increase', 'not_reported',
            'not_reported', 'Sammendrag', 'manual', a.id
     from catalog.drugs d, catalog.clinical_concepts c, provenance.actors a
     where d.canonical_name = 'sertralin' and c.canonical_label = 'vektendring'
       and a.actor_key = 'human:peder-holman'
     returning id`,
  )

  const reProposalInput = {
    proposal_version: EXTRACTION_PROPOSAL_VERSION,
    source_id: SOURCE,
    generated_by: {
      producer: 'human',
      provider: 'human',
      model: 'manuell-ekstraksjon',
      model_version: 'not_applicable',
      prompt_template_version: 'not_applicable',
      drafted_at: '2026-09-15T08:00:00Z',
    },
    source_version_id: VERSION,
    retrieved_from: 'https://example.test/kjede',
    content_hash: contentHash,
    extraction: {
      design_code: 'randomized_controlled_trial',
      population_availability: 'not_reported',
      population_detail: 'Voksne, re-ekstrahert.',
      sample_size_availability: 'not_reported',
      intervention_drug_id: psql(
        config,
        `select id from catalog.drugs where canonical_name = 'sertralin'`,
      ),
      comparator_kind: 'none',
      outcome_concept_id: psql(
        config,
        `select id from catalog.clinical_concepts where canonical_label = 'vektendring'`,
      ),
      outcome_detail: 'Vektendring, re-ekstrahert med forankring.',
      timepoint_availability: 'not_reported',
      reported_direction: 'increase',
      estimate_availability: 'not_reported',
      confidence_interval_availability: 'not_reported',
      source_locator: 'Sammendrag',
    },
    field_groundings: [
      {
        check_field: 'intervention_arm',
        source_excerpt: 'Sertraline patients were randomised for 8 weeks.',
        source_locator: 'METHODS',
        justification: 'Armen står i metodeavsnittet.',
      },
      {
        check_field: 'outcome',
        source_excerpt: 'Sertraline weight change increased from baseline.',
        source_locator: 'RESULTS',
        justification: 'Endepunktet står i resultatavsnittet.',
      },
      {
        check_field: 'reported_direction',
        source_excerpt: 'Sertraline weight change increased from baseline.',
        source_locator: 'RESULTS',
        justification: 'Retningen står i resultatavsnittet.',
      },
      {
        check_field: 'availability_semantics',
        source_excerpt: 'Sertraline patients were randomised for 8 weeks.',
        source_locator: 'METHODS',
        justification: 'Feltene uten verdi er ført som ikke rapportert.',
      },
    ],
  }
  const reProposal = parseExtractionProposal(JSON.parse(JSON.stringify(reProposalInput)))

  const reextractionPorts = {
    extractionApi: createEvidenceExtractionApi(client, {
      identityKey: 'agent-identity:evidence-extraction-01',
      secret: agentSecret(secret),
    }),
    verificationApi: createExtractionVerificationApi(client, {
      identityKey: 'agent-identity:extraction-verification-01',
      secret: agentSecret(verifierSecret),
    }),
    verificationPremises: EXTRACTION_VERIFICATION_PREMISES,
    proposals: [{ label: 'kjedeprove-reekstraksjon.json', proposal: reProposal }],
    retrieve: retrieve(contentHash),
  }

  // Tørrkjøringen først. Den er den kommandoen som faktisk brukes før en ekte
  // registrering, og den skriver ingen evidensrad — men kjøringen registreres
  // og lukkes, slik at også en tørrkjøring er sporbar (§74.31).
  const dryRun = await runReextraction({
    ...reextractionPorts,
    mode: 'without_assignment',
    dryRun: true,
  })
  check(
    'tørrkjøringen kontrollerte forslaget uten å registrere noe',
    dryRun.registered === 0 && dryRun.results[0]?.extraction.decision === 'previewed',
    dryRun.results[0]?.extraction.reason ?? '',
  )
  check(
    'og tørrkjøringen er likevel lukket og sporbar',
    psql(
      config,
      `select status::text || '|' || (failure_reason is not null)::text
       from provenance.agent_runs
       where id = ${q(dryRun.results[0]?.extraction.agentRunId ?? '')}`,
    ) === 'aborted|true',
  )

  const reextraction = await runReextraction({
    ...reextractionPorts,
    mode: 'without_assignment',
  })
  check(
    're-ekstraksjonen registrerte et nytt forankret funn',
    reextraction.registered === 1,
    reextraction.results[0]?.extraction.reason ?? '',
  )
  const reextractedItem = reextraction.results[0]?.extraction.evidenceItemId ?? ''
  check(
    'og kontrollerte nøyaktig det funnet med det samme',
    reextraction.results[0]?.verification?.items[0]?.evidenceItemId === reextractedItem,
  )
  check(
    'maskinbeviset gjelder det nye funnet',
    psql(config, `select workflow.grounding_machine_proved(${q(reextractedItem)})::text`) ===
      'true',
  )

  const igjen = await runReextraction({
    ...reextractionPorts,
    mode: 'without_assignment',
  })
  check(
    'kjørt om igjen skriver den ingenting',
    igjen.registered === 0 && igjen.alreadyRegistered === 1,
  )
  check(
    'og det finnes fortsatt bare ett re-ekstrahert funn',
    psql(
      config,
      `select count(*) from knowledge.evidence_items
       where source_id = ${q(SOURCE)}
         and outcome_detail = 'Vektendring, re-ekstrahert med forankring.'`,
    ) === '1',
  )

  // ---- Ledd 6: en avbrutt kjøring skal kunne fullføres ---------------------
  //
  // Registreringen og kontrollen er to skrivinger, i to transaksjoner. Dør
  // prosessen mellom dem, finnes raden uten maskinbevis, og en ny kjøring får
  // bare «dublett» tilbake — uten en id å kontrollere. Her simuleres det ved å
  // kjøre ekstraksjonen alene, og deretter re-ekstraksjonen med det samme
  // forslaget.
  const avbruttForslag = parseExtractionProposal({
    ...JSON.parse(JSON.stringify(reProposalInput)),
    extraction: {
      ...JSON.parse(JSON.stringify(reProposalInput)).extraction,
      outcome_detail: 'Vektendring, avbrutt kjøring.',
    },
  })

  // Et *annet* funn på den samme kildeversjonen, med nøyaktig den samme
  // forankringen. Det er lovlig: to funn fra én studie kan dele
  // utvalgsutdraget og likevel gjelde ulike utfall. Gjenopptakelsen må aldri
  // kunne velge det.
  const naboForslag = parseExtractionProposal({
    ...JSON.parse(JSON.stringify(reProposalInput)),
    extraction: {
      ...(JSON.parse(JSON.stringify(reProposalInput)) as { extraction: Record<string, unknown> })
        .extraction,
      outcome_detail: 'Vektendring, samme forankring men et annet utfall.',
    },
  })

  const avbrutt = await runEvidenceExtraction({
    mode: 'without_assignment',
    api: reextractionPorts.extractionApi,
    proposal: avbruttForslag,
    retrieve: retrieve(contentHash),
  })
  const nabo = await runEvidenceExtraction({
    mode: 'without_assignment',
    api: reextractionPorts.extractionApi,
    proposal: naboForslag,
    retrieve: retrieve(contentHash),
  })
  check(
    'to funn med samme forankring men ulike verdier er registrert uten kontroll',
    avbrutt.decision === 'registered' && nabo.decision === 'registered',
  )
  const avbruttItem = avbrutt.evidenceItemId ?? ''
  const naboItem = nabo.evidenceItemId ?? ''
  check(
    'og begge står uten maskinbevis',
    psql(
      config,
      `select workflow.grounding_machine_proved(${q(avbruttItem)})::text
              || '|' || workflow.grounding_machine_proved(${q(naboItem)})::text`,
    ) === 'false|false',
  )

  const gjenopptatt = await runReextraction({
    ...reextractionPorts,
    mode: 'without_assignment',
    proposals: [{ label: 'avbrutt.json', proposal: avbruttForslag }],
  })
  check(
    'den nye kjøringen skriver ingen ny rad',
    gjenopptatt.registered === 0 && gjenopptatt.alreadyRegistered === 1,
  )
  check(
    'men fullfører kontrollen av nøyaktig den raden dubletten gjaldt',
    gjenopptatt.unverified === 0 &&
      psql(
        config,
        `select workflow.grounding_machine_proved(${q(avbruttItem)})::text
                || '|' || workflow.grounding_machine_proved(${q(naboItem)})::text`,
      ) === 'true|false',
  )
  check(
    'og lot det gamle funnet på den samme kildeversjonen stå ukontrollert',
    psql(
      config,
      `select count(*) from workflow.evidence_verifications
       where evidence_item_id = ${q(legacyItem)}`,
    ) === '0',
  )

  // Den eksakte dublettraden er nå kontrollert, mens naboen fortsatt står
  // ukontrollert på den samme kildeversjonen. Kjøringen skal fortsatt melde at
  // kjeden er komplett, og ikke dra naboen med seg.
  const enGangTil = await runReextraction({
    ...reextractionPorts,
    mode: 'without_assignment',
    proposals: [{ label: 'avbrutt.json', proposal: avbruttForslag }],
  })
  check(
    'og en tredje kjøring melder kjeden komplett selv om naboen står ukontrollert',
    enGangTil.unverified === 0 && enGangTil.alreadyRegistered === 1,
  )
  check(
    'og naboen står fortsatt ukontrollert',
    psql(
      config,
      `select count(*) from workflow.evidence_verifications
       where evidence_item_id = ${q(naboItem)}`,
    ) === '0',
  )

  // ---- Ledd 7: en rettet forankring er et nytt evidensfunn ----------------
  //
  // `content_hash` dekker fra migrasjon 003d også avtrykket av
  // kildeforankringen. Et forslag med nøyaktig de samme strukturerte verdiene,
  // men ett rettet ordrett utdrag, er derfor ikke en dublett: det registreres
  // ved siden av det gamle og går gjennom den ordinære deterministiske
  // kontrollen (issue #66).
  //
  // Rettelsen gjøres på det *publiserte* funnet fra ledd 1 til 4, fordi det er
  // den raden som faktisk bærer noe å arve: et maskinbevis, en menneskelig
  // ekstraksjonskontroll, en claim-lenke og en publisert påstand. Ingen av
  // delene skal følge med over.
  const gammelHash = psql(
    config,
    `select content_hash from knowledge.evidence_items where id = ${q(itemId)}`,
  )
  const gammelForankring = psql(
    config,
    `select string_agg(check_field::text || '=' || source_excerpt, '|' order by check_field)
     from knowledge.evidence_field_groundings where evidence_item_id = ${q(itemId)}`,
  )
  const gammelKontroll = psql(
    config,
    `select count(*)::text from workflow.evidence_verifications
     where evidence_item_id = ${q(itemId)}`,
  )

  // Bare ett ordrett utdrag er rettet. Det står fortsatt i kilden, så
  // ekstraksjonens egen kontroll slipper det gjennom — det er databasens
  // identitetsregel som avgjør om raden er ny.
  const rettetForslag = parseExtractionProposal({
    ...JSON.parse(JSON.stringify(kjedeForslag)),
    field_groundings: kjedeForslag.field_groundings.map((grounding) =>
      grounding.check_field === 'outcome'
        ? { ...grounding, source_excerpt: 'Sertraline weight change increased' }
        : grounding,
    ),
  })

  const rettet = await runReextraction({
    ...reextractionPorts,
    mode: 'without_assignment',
    proposals: [{ label: 'rettet-forankring.json', proposal: rettetForslag }],
  })
  check(
    'den rettede forankringen registreres som et nytt funn framfor å avvises som dublett',
    rettet.registered === 1 && rettet.alreadyRegistered === 0,
    rettet.results[0]?.extraction.reason ?? '',
  )
  const rettetItem = rettet.results[0]?.extraction.evidenceItemId ?? ''
  check('og det er en annen rad enn den gamle', rettetItem !== '' && rettetItem !== itemId)
  check(
    'de to radene skiller seg bare i forankringen, og har hvert sitt avtrykk',
    psql(
      config,
      `select (a.content_hash <> b.content_hash)::text
              || '|' || (a.grounding_digest <> b.grounding_digest)::text
              || '|' || (a.outcome_detail = b.outcome_detail)::text
              || '|' || (a.source_locator = b.source_locator)::text
       from knowledge.evidence_items a, knowledge.evidence_items b
       where a.id = ${q(itemId)} and b.id = ${q(rettetItem)}`,
    ) === 'true|true|true|true',
  )
  check(
    'den nye raden går hele veien til et gyldig maskinbevis',
    rettet.unverified === 0 &&
      psql(config, `select workflow.grounding_machine_proved(${q(rettetItem)})::text`) === 'true',
  )
  check(
    'og den arver verken den menneskelige kontrollen eller claim-lenken fra den gamle',
    psql(
      config,
      `select (select count(*) from workflow.evidence_verifications
               where evidence_item_id = ${q(rettetItem)} and agent_run_id is null)::text
              || '|' || (select count(*) from knowledge.claim_evidence_links
                         where evidence_item_id = ${q(rettetItem)})::text`,
    ) === '0|0',
  )

  check(
    'det gamle funnet står urørt: samme avtrykk, samme forankring, samme kontroller',
    psql(config, `select content_hash from knowledge.evidence_items where id = ${q(itemId)}`) ===
      gammelHash &&
      psql(
        config,
        `select string_agg(check_field::text || '=' || source_excerpt, '|' order by check_field)
         from knowledge.evidence_field_groundings where evidence_item_id = ${q(itemId)}`,
      ) === gammelForankring &&
      psql(
        config,
        `select count(*)::text from workflow.evidence_verifications
         where evidence_item_id = ${q(itemId)}`,
      ) === gammelKontroll,
  )
  check(
    'og den publiserte påstanden viser fortsatt bare det gamle funnet',
    psql(
      config,
      `select string_agg(distinct evidence_item_id::text, ',')
       from api.published_claim_evidence where claim_revision_id = ${q(revision)}`,
    ) === itemId,
  )

  check(
    'det gamle, uforankrede funnet står urørt, og har fortsatt ingen forankring',
    psql(
      config,
      `select count(*) from knowledge.evidence_items e
       where e.id = ${q(legacyItem)} and e.extraction_method = 'manual'
         and not exists (select 1 from knowledge.evidence_field_groundings g
                         where g.evidence_item_id = e.id)`,
    ) === '1',
  )

  // ---- Ledd 8: modell-leddet, fra kildeversjon til forslag ----------------
  //
  // Leddet som leser artikkelen og foreslår verdier, kjørt med opptaksadapteret
  // — altså deterministisk og uten leverandørkonto. Det som prøves her og ikke
  // kan prøves uten en ekte database, er at forslaget modellen produserte, går
  // uendret gjennom de ekte portene, og at premissene raden registreres under,
  // er modellens egne og ikke en fast verdi.
  const drugId = psql(config, `select id from catalog.drugs where canonical_name = 'sertralin'`)
  const outcomeId = psql(
    config,
    `select id from catalog.clinical_concepts where canonical_label = 'vektendring'`,
  )
  const oppdrag = parseExtractionAssignment({
    assignment_version: 'antidep/extraction-assignment@1',
    source_id: SOURCE,
    source_version_id: VERSION,
    retrieved_from: 'https://example.test/kjede',
    content_hash: contentHash,
    drugs: [{ drug_id: drugId, label: 'sertralin' }],
    outcomes: [{ outcome_concept_id: outcomeId, label: 'vektendring' }],
    populations: [],
  })

  // Slik en operatør faktisk gjør det: --prepare gir prompten og avtrykket,
  // svaret limes inn i opptaket.
  const forberedt = await prepareDraftingRequest({
    assignment: oppdrag,
    retrieve: retrieve(contentHash),
  })
  check(
    'modell-leddet bygger en forespørsel av den hentede representasjonen',
    forberedt.request.user.includes('Sertraline patients were randomised for 8 weeks.') &&
      /^sha256:[0-9a-f]{64}$/.test(forberedt.requestDigest),
  )

  function opptakMed(completion: unknown) {
    return createModelClient('recorded', {
      recording: {
        recording_version: 'antidep/model-recording@1',
        identity: {
          provider: 'kjedeprove',
          model: 'opptaksmodell',
          model_version: '2026-09-15',
        },
        entries: [
          {
            request_digest: forberedt.requestDigest,
            prompt_template_version: forberedt.request.promptTemplateVersion,
            completion: JSON.stringify(completion),
          },
        ],
      },
    })
  }

  const modellUtkast = {
    extraction: {
      design_code: 'randomized_controlled_trial',
      population_availability: 'not_reported',
      population_detail: 'Voksne.',
      sample_size_availability: 'not_reported',
      intervention_drug_id: drugId,
      comparator_kind: 'none',
      outcome_concept_id: outcomeId,
      outcome_detail: 'Vektendring, foreslått av modell-leddet.',
      timepoint_availability: 'not_reported',
      reported_direction: 'increase',
      estimate_availability: 'not_reported',
      confidence_interval_availability: 'not_reported',
      source_locator: 'Sammendrag',
    },
    field_groundings: [
      {
        check_field: 'intervention_arm',
        source_excerpt: 'Sertraline patients were randomised for 8 weeks.',
        source_locator: 'METHODS',
        justification: 'Armen står i metodeavsnittet.',
      },
      {
        check_field: 'outcome',
        source_excerpt: 'Sertraline weight change increased from baseline.',
        source_locator: 'RESULTS',
        justification: 'Endepunktet står i resultatavsnittet.',
      },
      {
        check_field: 'reported_direction',
        source_excerpt: 'Sertraline weight change increased from baseline.',
        source_locator: 'RESULTS',
        justification: 'Retningen står i resultatavsnittet.',
      },
      {
        check_field: 'availability_semantics',
        source_excerpt: 'Sertraline patients were randomised for 8 weeks.',
        source_locator: 'METHODS',
        justification: 'Feltene uten verdi er ført som ikke rapportert.',
      },
    ],
  }

  // Først et utkast med et oppdiktet utdrag. Leddet har ingen skrivevei, så
  // «ingen rad» er ikke en kontroll det gjør — men prøven skal likevel vise at
  // ingenting ble til av et avvist utkast.
  const førAvvist = psql(
    config,
    `select count(*) from knowledge.evidence_items where source_id = ${q(SOURCE)}`,
  )
  const avvist = await runExtractionDrafting({
    assignment: oppdrag,
    model: opptakMed({
      ...modellUtkast,
      field_groundings: [
        {
          check_field: 'intervention_arm',
          source_excerpt: 'Paroxetine patients were randomised for twelve weeks.',
          source_locator: 'METHODS',
          justification: 'Armen står i metodeavsnittet.',
        },
      ],
    }),
    retrieve: retrieve(contentHash),
  })
  check(
    'et utkast med et oppdiktet utdrag blir ikke et forslag',
    avvist.decision === 'rejected' && avvist.proposal === undefined,
    avvist.reason ?? '',
  )
  check(
    'og ingenting ble skrevet av det avviste utkastet',
    psql(config, `select count(*) from knowledge.evidence_items where source_id = ${q(SOURCE)}`) ===
      førAvvist,
  )

  const utkast = await runExtractionDrafting({
    assignment: oppdrag,
    model: opptakMed(modellUtkast),
    retrieve: retrieve(contentHash),
  })
  check(
    'modell-leddet produserte et forslag med sin egen leverandør og modell',
    utkast.decision === 'drafted' &&
      utkast.proposal?.generatedBy.producer === 'model' &&
      utkast.proposal.generatedBy.provider === 'kjedeprove' &&
      utkast.proposal.generatedBy.modelVersion === '2026-09-15',
    utkast.reason ?? '',
  )

  // Forslaget går gjennom filformen på veien, som det gjør i drift: kjøreren
  // skriver en fil, og registreringen leser den.
  const modellForslag = parseExtractionProposal(
    JSON.parse(JSON.stringify(serializeExtractionProposal(utkast.proposal!))) as unknown,
  )
  const modellKjede = await runReextraction({
    ...reextractionPorts,
    mode: 'unchecked_model',
    proposals: [{ label: 'modell-leddet.json', proposal: modellForslag }],
  })
  const modellItem = modellKjede.results[0]?.extraction.evidenceItemId ?? ''
  check(
    'forslaget fra modell-leddet gikk hele veien til et gyldig maskinbevis',
    modellKjede.registered === 1 &&
      modellKjede.unverified === 0 &&
      psql(config, `select workflow.grounding_machine_proved(${q(modellItem)})::text`) === 'true',
    modellKjede.results[0]?.unverifiedReason ?? '',
  )
  check(
    'raden er ført som et KI-assistert forslag',
    psql(
      config,
      `select extraction_method::text from knowledge.evidence_items where id = ${q(modellItem)}`,
    ) === 'ai_assisted',
  )
  // Kjøringen beskriver seg selv: Antideps deterministiske registreringsvei, på
  // det tidspunktet kommandoen ble kjørt. Den er ikke modellkjøringen.
  check(
    'kjøringen står med sine egne premisser, ikke med modellens',
    psql(
      config,
      `select r.provider || '|' || r.model || '|' || r.model_version
              || '|' || r.prompt_template_version || '|' || r.pipeline_version
       from provenance.agent_runs r
       join knowledge.evidence_items e on e.agent_run_id = r.id
       where e.id = ${q(modellItem)}`,
    ) ===
      'antidep|proposal-grounded-extraction|1.0.0|evidence-extraction/proposal/1|antidep-evidence/1',
  )
  check(
    'kontrollgrunnlaget viser hvem som laget verdiene, som en erklæring',
    psql(
      config,
      `select (workflow.evidence_extraction_dossier(${q(modellItem)}) -> 'drafted_by' ->> 'producer')
              || '|' || (workflow.evidence_extraction_dossier(${q(modellItem)})
                         -> 'drafted_by' ->> 'model')
              || '|' || (workflow.evidence_extraction_dossier(${q(modellItem)})
                         -> 'drafted_by' ->> 'prompt_template_version')`,
    ) === `model|opptaksmodell|${EXTRACTION_DRAFTING_PROMPT_VERSION}`,
  )
  // Utkastets eget tidspunkt og forespørselens avtrykk er det som gjør
  // modellkjøringen identifiserbar i ettertid. Uten dem ville proveniensen bare
  // hatt registreringens klokke.
  check(
    'og bærer utkastets eget tidspunkt og forespørselens avtrykk',
    psql(
      config,
      `select (workflow.evidence_extraction_dossier(${q(modellItem)}) -> 'drafted_by' ->> 'drafted_at')
              || '|' || (workflow.evidence_extraction_dossier(${q(modellItem)})
                         -> 'drafted_by' ->> 'request_digest')`,
    ) === `${utkast.proposal?.generatedBy.draftedAt ?? ''}|${utkast.requestDigest ?? ''}`,
  )
  check(
    'og registreringens klokke er en annen enn utkastets',
    psql(
      config,
      `select (workflow.evidence_extraction_dossier(${q(modellItem)})
               -> 'registered_by' ->> 'started_at')
              is distinct from
              (workflow.evidence_extraction_dossier(${q(modellItem)})
               -> 'drafted_by' ->> 'drafted_at')`,
    ) === 't',
  )

  // Det samme utkastet, men erklært som et menneskes ekstraksjon. Verdien
  // inngår i fingeravtrykket, så dette er en *annen* rad — ikke den samme raden
  // som skifter mening.
  const menneskeForslag = parseExtractionProposal({
    ...(JSON.parse(JSON.stringify(serializeExtractionProposal(utkast.proposal!))) as Record<
      string,
      unknown
    >),
    generated_by: {
      producer: 'human',
      provider: 'human',
      model: 'manuell-ekstraksjon',
      model_version: 'not_applicable',
      prompt_template_version: 'not_applicable',
      drafted_at: '2026-09-15T08:00:00Z',
    },
  })
  const menneskeKjede = await runReextraction({
    ...reextractionPorts,
    mode: 'without_assignment',
    proposals: [{ label: 'samme-verdier-menneske.json', proposal: menneskeForslag }],
  })
  const menneskeItem = menneskeKjede.results[0]?.extraction.evidenceItemId ?? ''
  check(
    'de samme verdiene erklært av et menneske blir en annen rad, ført som manuell',
    menneskeKjede.registered === 1 &&
      menneskeItem !== modellItem &&
      psql(
        config,
        `select extraction_method::text from knowledge.evidence_items where id = ${q(menneskeItem)}`,
      ) === 'manual',
  )
  check(
    'og modell-leddets rad står urørt ved siden av',
    psql(
      config,
      `select extraction_method::text from knowledge.evidence_items where id = ${q(modellItem)}`,
    ) === 'ai_assisted',
  )

  // ---- Ledd 9: Routine-grensesnittet, fra oppdrag til registrert rad --------
  //
  // Det samme modell-leddet, men kjørt slik en Claude Code Routine kjører det:
  // to kommandoer med en fil imellom. Det som prøves her og ikke kan prøves
  // uten en ekte database, er at filen `--close` skriver, går uendret gjennom de
  // ekte portene — og at proveniensen som når kontrollgrunnlaget, er den
  // aktøren erklærte i svarfilen, ikke en fast verdi.
  const kjoremappe = mkdtempSync(join(tmpdir(), 'antidep-kjede-routine-'))
  try {
    const oppdragsfil = join(kjoremappe, 'oppdrag.json')
    writeFileSync(
      oppdragsfil,
      JSON.stringify({
        assignment_version: 'antidep/extraction-assignment@1',
        source_id: SOURCE,
        source_version_id: VERSION,
        retrieved_from: 'https://example.test/kjede',
        content_hash: contentHash,
        drugs: [{ drug_id: drugId, label: 'sertralin' }],
        outcomes: [{ outcome_concept_id: outcomeId, label: 'vektendring' }],
        populations: [],
      }),
      'utf8',
    )
    const runDirectory = join(kjoremappe, 'kjoring')
    const åpnet = await openDraftingJob({
      assignmentPath: oppdragsfil,
      runDirectory,
      retrieve: retrieve(contentHash),
    })
    check(
      'Routine-grensesnittet legger igjen prompten og en tom svarfil',
      åpnet.outcome === 'opened' && åpnet.job.state === 'awaiting_answer',
    )

    // Slik aktøren som utfører modellarbeidet, svarer: én fil, med sin egen
    // identitet og sitt eget tidspunkt.
    const førModell = psql(
      config,
      `select count(*) from knowledge.evidence_items where source_id = ${q(SOURCE)}`,
    )
    writeFileSync(
      join(runDirectory, JOB_FILES.answer),
      JSON.stringify({
        answer_version: MODEL_ANSWER_VERSION,
        request_digest: åpnet.job.requestDigest,
        identity: { provider: 'kjedeprove', model: 'routine-modell', model_version: '2026-09-16' },
        answered_at: new Date().toISOString(),
        draft: {
          ...modellUtkast,
          extraction: {
            ...modellUtkast.extraction,
            outcome_detail: 'Vektendring, foreslått gjennom Routine-grensesnittet.',
          },
        },
      }),
      'utf8',
    )
    const lukket = await closeDraftingJob({
      runDirectory,
      assignmentPath: oppdragsfil,
      retrieve: retrieve(contentHash),
    })
    check(
      'og skriver et forslag av svaret, uten å røre en eneste rad',
      lukket.outcome === 'drafted' &&
        psql(
          config,
          `select count(*) from knowledge.evidence_items where source_id = ${q(SOURCE)}`,
        ) === førModell,
      lukket.reason ?? '',
    )

    // Filen leses av nøyaktig den leseren registreringen bruker.
    const routineForslag = await readProposalFile(lukket.proposalPath)
    const routineKjede = await runReextraction({
      ...reextractionPorts,
      mode: 'unchecked_model',
      proposals: [routineForslag],
    })
    const routineItem = routineKjede.results[0]?.extraction.evidenceItemId ?? ''
    check(
      'og forslaget går hele veien til et gyldig maskinbevis',
      routineKjede.registered === 1 &&
        routineKjede.unverified === 0 &&
        psql(config, `select workflow.grounding_machine_proved(${q(routineItem)})::text`) ===
          'true',
      routineKjede.results[0]?.unverifiedReason ?? '',
    )
    // Overleveringen er utrygg: forslaget har vært innom en økt som leste utrygt
    // eksternt innhold. Registreringen kontrollerer det derfor mot redaktørens
    // egen oppdragsfil, og et forslag utenfor katalogen blir ingen rad — selv
    // om hvert utdrag står ordrett i kilden.
    const førUtenfor = psql(
      config,
      `select count(*) from knowledge.evidence_items where source_id = ${q(SOURCE)}`,
    )
    const routineOppdrag = parseAssignmentJson(oppdragsfil, readFileSync(oppdragsfil, 'utf8'))
    const utenfor = await runEvidenceExtraction({
      mode: 'with_assignment',
      api: reextractionPorts.extractionApi,
      proposal: routineForslag.proposal,
      assignment: parseExtractionAssignment({
        assignment_version: 'antidep/extraction-assignment@1',
        source_id: SOURCE,
        source_version_id: VERSION,
        retrieved_from: 'https://example.test/kjede',
        content_hash: contentHash,
        drugs: [{ drug_id: drugId, label: 'sertralin' }],
        // Et annet endepunkt enn det forslaget peker på.
        outcomes: [
          { outcome_concept_id: '41000000-0000-4000-8000-0000000000ff', label: 'et naboendepunkt' },
        ],
        populations: [],
      }),
      retrieve: retrieve(contentHash),
    })
    check(
      'et forslag utenfor oppdraget blir ingen rad, selv med ordrette utdrag',
      utenfor.decision === 'skipped' &&
        (utenfor.reason ?? '').includes('outcome_concept_id') &&
        psql(
          config,
          `select count(*) from knowledge.evidence_items where source_id = ${q(SOURCE)}`,
        ) === førUtenfor,
      utenfor.reason ?? '',
    )
    // Den samme overleveringen, men med bare ett ord endret: `producer` fra
    // «model» til «human». Alt annet passerer — katalogen, kildebindingen,
    // utdragene — og raden ville blitt ført som en menneskelig ekstraksjon.
    // Modusen kalleren registrerer under, er den tiltrodde halvdelen.
    const førOmskrevet = psql(
      config,
      `select count(*) from knowledge.evidence_items where source_id = ${q(SOURCE)}`,
    )
    const omskrevet = parseExtractionProposal({
      ...(JSON.parse(
        JSON.stringify(serializeExtractionProposal(routineForslag.proposal)),
      ) as Record<string, unknown>),
      generated_by: {
        producer: 'human',
        provider: 'human',
        model: 'manuell-ekstraksjon',
        model_version: 'not_applicable',
        prompt_template_version: 'not_applicable',
        drafted_at: '2026-09-16T08:00:00Z',
      },
    })
    let avvist = ''
    try {
      await runEvidenceExtraction({
        api: reextractionPorts.extractionApi,
        proposal: omskrevet,
        assignment: routineOppdrag,
        mode: 'with_assignment',
        retrieve: retrieve(contentHash),
      })
    } catch (cause) {
      avvist = cause instanceof Error ? cause.message : String(cause)
    }
    check(
      'et maskinutkast omskrevet til «human» blir ingen rad, og ingen kjøring',
      avvist.includes('erklært laget av «human»') &&
        psql(
          config,
          `select count(*) from knowledge.evidence_items where source_id = ${q(SOURCE)}`,
        ) === førOmskrevet,
      avvist,
    )
    check(
      'og kontrollgrunnlaget bærer identiteten aktøren erklærte i svarfilen',
      psql(
        config,
        `select (workflow.evidence_extraction_dossier(${q(routineItem)}) -> 'drafted_by' ->> 'provider')
                || '|' || (workflow.evidence_extraction_dossier(${q(routineItem)})
                           -> 'drafted_by' ->> 'model')`,
      ) === 'kjedeprove|routine-modell',
    )
  } finally {
    rmSync(kjoremappe, { recursive: true, force: true })
  }

  console.log(
    process.exitCode === 1 ? '\nMinst én påstand slo feil.' : '\nHele kjeden gikk gjennom.',
  )
}

await main()
