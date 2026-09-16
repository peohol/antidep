// ============================================================================
// Hele forløpet «venter på fulltekst» → PDF lastes opp → arbeid fortsetter
//
// pgTAP prøver SQL, og vitest prøver TypeScript med doble for databasen.
// Grensen mellom dem — at parameternavnene fulltekstinnboksen og Antideps egen
// tekstuttrekker sender, er nøyaktig de `api`-funksjonene tar imot, og at det
// *ekte* `pdftotext` gir en tekst databasen faktisk godtar — er ikke prøvd av
// noen av dem.
//
// Denne kjøringen går hele veien, mot den lokale stacken:
//
//   1. en uinnlogget leser ser arbeidsoversikten, og den er tom
//   2. en redaktør ber om fullteksten til én artikkel
//   3. den uinnloggede ser «venter på fulltekst» som planlagt arbeid
//   4. redaktøren laster opp PDF-en, og gjør ingenting annet
//   5. den uinnloggede ser at arbeidet pågår
//   6. Antideps egen tekstuttrekker kjører den registrerte oppskriften
//   7. kildeversjonen er registrert, og neste ledd ligger i køen
//   8. den uinnloggede ser planlagt arbeid — uten én eneste teknisk verdi
//   9. grensene holder: uinnlogget, redaktør og admin får hver sitt
//
// Ingen modell kalles, og ingen nøkkel finnes. Det eneste eksterne verktøyet er
// `pdftotext`, som er den registrerte oppskriften.
// ============================================================================

import { createClient } from '@supabase/supabase-js'

import { syntheticArticlePdf } from '../src/agents/test-support.ts'
import { parseWorkBoard } from '../src/lib/work-board.ts'
import { parseFullTextInbox, parseFullTextSubmission } from '../src/lib/full-text-inbox.ts'
import { parseTechnicalProblems } from '../src/lib/technical-problems.ts'
import { runFullTextWorker, type FullTextIntakeApi } from '../src/ops/full-text-worker.ts'
import type { Database } from '../src/types/database.ts'
import { check, psql, q, readLocalStackConfig, userToken } from './local-stack.ts'

const config = readLocalStackConfig(process.argv.slice(2))

const EDITOR_USER = '9f000000-0000-4000-8000-000000000001'
const ADMIN_USER = '9f000000-0000-4000-8000-000000000002'
const CLINICIAN_USER = '9f000000-0000-4000-8000-000000000003'
const DOI = '10.1234/antidep.intake-e2e'
const TITLE = 'Fulltekstinnboksens ende-til-ende-artikkel'

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

// ----------------------------------------------------------------------------
// Fikstur. Alt er syntetisk, og ingenting av det er klinisk innhold.
// ----------------------------------------------------------------------------
function seed(): { readonly sourceId: string } {
  psql(
    config,
    `
    delete from workflow.full_text_intake
      where source_id in (select id from knowledge.sources where title = ${q(TITLE)});
    delete from workflow.full_text_requests
      where source_id in (select id from knowledge.sources where title = ${q(TITLE)});

    insert into auth.users (id, email) values
      (${q(EDITOR_USER)}, 'intake-e2e-editor@test.invalid'),
      (${q(ADMIN_USER)}, 'intake-e2e-admin@test.invalid'),
      (${q(CLINICIAN_USER)}, 'intake-e2e-kliniker@test.invalid')
    on conflict (id) do nothing;

    insert into provenance.actors
      (actor_type, actor_key, display_name, description, auth_user_id)
    values
      ('human', 'human:intake-e2e-editor', 'Redaktør intake-e2e',
       'Syntetisk redaktør for fulltekstprøven.', ${q(EDITOR_USER)}),
      ('human', 'human:intake-e2e-admin', 'Admin intake-e2e',
       'Syntetisk admin for fulltekstprøven.', ${q(ADMIN_USER)}),
      ('human', 'human:intake-e2e-kliniker', 'Kliniker intake-e2e',
       'Syntetisk kliniker uten mandat.', ${q(CLINICIAN_USER)})
    on conflict (actor_key) do nothing;

    insert into workflow.user_roles
      (user_id, role_code, valid_from, granted_by_actor_id, grant_reason)
    select v.user_id::uuid, v.role_code::workflow.app_role, now() - interval '1 hour',
           (select id from provenance.actors where actor_key = 'human:intake-e2e-editor'),
           'Fulltekstprøvens egen tildeling.'
    from (values (${q(EDITOR_USER)}, 'editor'), (${q(ADMIN_USER)}, 'admin'))
      as v(user_id, role_code)
    where not exists (
      select 1 from workflow.user_roles ur
      where ur.user_id = v.user_id::uuid and ur.role_code = v.role_code::workflow.app_role
    );

    insert into knowledge.sources
      (source_type, title, authors_or_issuer, publication_date, publication_date_precision,
       created_by_actor_id)
    select 'journal_article', ${q(TITLE)}, 'Prøveforfatter', date '2019-01-01', 'year',
           (select id from provenance.actors where actor_key = 'human:intake-e2e-editor')
    where not exists (select 1 from knowledge.sources where title = ${q(TITLE)});

    insert into knowledge.source_identifiers (source_id, identifier_system, identifier_value)
    select s.id, 'doi', ${q(DOI)}
    from knowledge.sources s
    where s.title = ${q(TITLE)}
      and not exists (
        select 1 from knowledge.source_identifiers i
        where i.source_id = s.id and i.identifier_system = 'doi'
      );
    `,
  )
  return {
    sourceId: psql(config, `select id from knowledge.sources where title = ${q(TITLE)}`),
  }
}

function catalogIds(): { readonly drugId: string; readonly outcomeId: string } {
  return {
    drugId: psql(config, "select id from catalog.drugs where canonical_name = 'sertralin'"),
    outcomeId: psql(
      config,
      "select id from catalog.clinical_concepts where concept_type = 'outcome' and canonical_label = 'vektendring'",
    ),
  }
}

/** Databasegrensen tekstuttrekkeren bruker, med redaktørens egen klient. */
function intakeApi(caller: Client): FullTextIntakeApi {
  return {
    claim: (leaseSeconds) =>
      rpc(caller, 'claim_full_text_extraction', { p_lease_seconds: leaseSeconds }),
    complete: (handle, extractedText, toolVersion) =>
      rpc(caller, 'complete_full_text_extraction', {
        p_handle: handle,
        p_extracted_text: extractedText,
        p_text_extraction_tool_version: toolVersion,
      }),
    fail: (handle, stage) =>
      rpc(caller, 'fail_full_text_extraction', { p_handle: handle, p_stage: stage }),
  }
}

async function main(): Promise<void> {
  const { sourceId } = seed()
  const { drugId, outcomeId } = catalogIds()

  const anonymous = client(null)
  const editor = client(EDITOR_USER)
  const admin = client(ADMIN_USER)
  const clinician = client(CLINICIAN_USER)

  console.log('Grensene rundt de innloggede flatene')
  check(
    'en uinnlogget kaller kommer ikke til fulltekstinnboksen',
    (await rejected(anonymous, 'full_text_inbox', {})).length > 0,
  )
  check(
    'en uinnlogget kaller kommer ikke til den tekniske oversikten',
    (await rejected(anonymous, 'technical_problem_board', {})).length > 0,
  )
  check(
    'en innlogget kliniker uten mandat kommer ikke til innboksen',
    (await rejected(clinician, 'full_text_inbox', {})).includes('editor- eller admin-rolle'),
  )
  check(
    'en redaktør uten admin-mandat kommer ikke til den tekniske oversikten',
    (await rejected(editor, 'technical_problem_board', {})).includes('admin-rolle'),
  )

  console.log('Forespørselen')
  await rpc(editor, 'request_full_text', {
    p_source_id: sourceId,
    p_drug_ids: [drugId],
    p_outcome_concept_ids: [outcomeId],
  })

  const waiting = parseWorkBoard(await rpc(anonymous, 'public_work_board', {}))
  const waitingItem = waiting.find(
    (item) => item.activity === 'full_text' && item.waitingForFullText,
  )
  check('den uinnloggede ser den ventende artikkelen', waitingItem !== undefined)
  check('og den står som planlagt arbeid', waitingItem?.status === 'planned')
  check(
    'og den sier hvilket virkestoff det gjelder',
    waitingItem?.subjects.includes('sertralin') === true,
  )

  const boardText = JSON.stringify(await rpc(anonymous, 'public_work_board', {}))
  for (const teknisk of [TITLE, DOI, sourceId, 'evidence_extraction', 'pipeline', 'sha256']) {
    check(`den åpne oversikten bærer ikke «${teknisk.slice(0, 24)}»`, !boardText.includes(teknisk))
  }

  console.log('Opplastingen')
  const inbox = parseFullTextInbox(await rpc(editor, 'full_text_inbox', {}))
  const entry = inbox.find((item) => item.title === TITLE)
  check('innboksen navngir artikkelen i klartekst', entry !== undefined)
  check('og ber om en opplasting', entry?.state === 'needs_upload')
  if (entry === undefined) {
    throw new Error('Innboksen manglet artikkelen prøven nettopp ba om.')
  }

  // Teksten bærer kildens DOI, som er bindingsgrunnlaget. Artikkelen er
  // syntetisk og består lesbarhetskontrollen med sine egne tabellrader.
  const pdf = syntheticArticlePdf([TITLE, `doi: ${DOI}`, 'Sertraline increased weight by 1.5 kg.'])
  const submission = parseFullTextSubmission(
    await rpc(editor, 'submit_full_text', {
      p_reference: entry.reference,
      p_document_base64: Buffer.from(pdf).toString('base64'),
    }),
  )
  check('filen tas imot', submission.accepted)

  const processing = parseWorkBoard(await rpc(anonymous, 'public_work_board', {}))
  check(
    'den uinnloggede ser at Antidep nå arbeider med den',
    processing.some((item) => item.activity === 'full_text' && item.status === 'in_progress'),
  )

  console.log('Antideps eget tekstuttrekk')
  const report = await runFullTextWorker({ api: intakeApi(editor), maxTasks: 5 })
  check('én fil ble behandlet', report.claimed >= 1, JSON.stringify(report))
  check('og den ble registrert', report.registered >= 1, JSON.stringify(report))
  check('uten at noe stoppet teknisk', report.failed === 0, JSON.stringify(report))

  check(
    'kildeversjonen er registrert som fulltekst',
    psql(
      config,
      `select count(*) from knowledge.source_versions
       where source_id = ${q(sourceId)} and representation = 'full_text'`,
    ) === '1',
  )
  check(
    'originalfilen ligger i det private biblioteket',
    psql(
      config,
      `select count(*) from knowledge.source_document_publications where source_id = ${q(sourceId)}`,
    ) === '1',
  )
  check(
    'og innboksen har gitt bytene fra seg',
    psql(
      config,
      `select count(*) from workflow.full_text_intake
       where source_id = ${q(sourceId)} and content is not null`,
    ) === '0',
  )
  check(
    'fulltekstforespørselen er lukket',
    psql(
      config,
      `select state from workflow.full_text_requests where source_id = ${q(sourceId)}`,
    ) === 'fulfilled',
  )
  check(
    'og neste ledd ligger i køen med den avgrensningen forespørselen bar',
    psql(
      config,
      `select count(*) from workflow.pipeline_jobs j
       join knowledge.source_versions sv
         on sv.id = (j.input_manifest ->> 'source_version_id')::uuid
       where sv.source_id = ${q(sourceId)}
         and j.agent_role = 'evidence_extraction'
         and j.input_manifest -> 'drug_ids' ? ${q(drugId)}`,
    ) === '1',
  )

  console.log('Etterpå')
  const queued = parseWorkBoard(await rpc(anonymous, 'public_work_board', {}))
  check(
    'den uinnloggede ser uttrekket som planlagt arbeid',
    queued.some((item) => item.activity === 'findings' && item.status === 'planned'),
  )
  check(
    'og ingenting venter lenger på fulltekst for denne artikkelen',
    !queued.some((item) => item.activity === 'full_text' && item.waitingForFullText),
  )
  check(
    'innboksen er tom for denne artikkelen',
    !parseFullTextInbox(await rpc(editor, 'full_text_inbox', {})).some(
      (item) => item.title === TITLE,
    ),
  )

  const problems = parseTechnicalProblems(await rpc(admin, 'technical_problem_board', {}))
  check(
    'og ingenting av dette ble til et teknisk problem',
    problems.every((problem) => !problem.ongoing),
    JSON.stringify(problems),
  )
  const problemText = JSON.stringify(await rpc(admin, 'technical_problem_board', {}))
  check('den tekniske oversikten bærer ingen diagnose', !problemText.includes('diagnosis'))
}

await main()
