// ============================================================================
// Røyktest: ekte søk mot ekte offentlige søketjenester
//
//   ANTIDEP_WEB_SMOKE=1 npm run db:test:web-smoke
//
// Dette er ikke fase D, og det er ikke en faglig prøve. Det er svaret på ett
// spørsmål: kan den nye flyten bruke *ekte* eksterne treff, eller virker den
// bare mot opptak?
//
// Prøven bestiller en monografi, åpner en søkeplan, og kjører deretter den
// *samme kommandoen driften kjører* — `src/ops/monograph-discovery-cli.ts` —
// mot Europe PMC, PubMed og Crossref. Ingen treff er hardkodet, og ingen
// fetcher er byttet ut: `guardedGet` går ut på nettet.
//
// ----------------------------------------------------------------------------
// Hvorfor kommandoen kjøres som en egen prosess
//
// En prøve som hadde bygget `DiscoveryApi` selv, ville prøvd sin egen wiring.
// Her kjøres den installerte kommandoen med de miljøvariablene drift bruker,
// slik at det som prøves, er det som er levert.
//
// ----------------------------------------------------------------------------
// Isolasjon
//
// Basen skal være den lokale. `scripts/local-test-db.mjs` håndhever det, og
// kjøringen nekter å begynne uten `ANTIDEP_WEB_SMOKE=1`: en kjøring som går ut
// på nettet, skal noen ha bedt om.
//
// Treffene som registreres, er offentlige bibliografiske metadata — tittel,
// forfattere, tidsskrift, DOI. Ingen fulltekst hentes her.
// ============================================================================

import { spawnSync } from 'node:child_process'

import { createClient } from '@supabase/supabase-js'

import { guardedGet } from '../src/agents/guarded-http.ts'
import { openAccessPdfUrl } from '../src/ops/monograph-acquisition.ts'
import type { Database } from '../src/types/database.ts'
import { check, psql, q, readLocalStackConfig, userToken } from './local-stack.ts'

const config = readLocalStackConfig(process.argv.slice(2))
const RUN = Math.random().toString(16).slice(2, 10)
const EDITOR_USER = '5b1c0a00-0000-4000-8000-0000000000a1'

function seed(): void {
  psql(
    config,
    `
    insert into auth.users (id, email) values
      (${q(EDITOR_USER)}, ${q(`web-smoke-${RUN}@test.invalid`)});

    insert into provenance.actors
      (actor_type, actor_key, display_name, description, auth_user_id)
    values
      ('human', ${q(`human:web-smoke-${RUN}`)}, 'Røyktestredaktør',
       'Redaktør i den nettbaserte røyktesten.', ${q(EDITOR_USER)});

    insert into workflow.user_roles
      (user_id, role_code, scope_id, valid_from, granted_by_actor_id, grant_reason)
    values
      (${q(EDITOR_USER)}::uuid, 'editor', null, now() - interval '1 hour',
       (select id from provenance.actors where actor_key = 'human:peder-holman'),
       'Den nettbaserte røyktesten.');
    `,
  )
}

/** Redaktøren, over de samme api-veiene flaten bruker. */
function editorClient() {
  return createClient<Database, 'api'>(config.apiUrl, config.anonKey, {
    db: { schema: 'api' },
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${userToken(config, EDITOR_USER)}` } },
  })
}

async function call(
  client: ReturnType<typeof editorClient>,
  fn: 'assign_agent_role_model' | 'order_monograph',
  args: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await client.rpc(fn as never, args as never)
  if (error !== null) {
    throw new Error(`${fn}: ${error.message}`)
  }
  return data
}

async function main(): Promise<void> {
  if (process.env['ANTIDEP_WEB_SMOKE'] !== '1') {
    console.error(
      'Denne prøven går ut på det åpne nettet, og må bes om:\n' +
        '  ANTIDEP_WEB_SMOKE=1 npm run db:test:web-smoke\n',
    )
    process.exitCode = 2
    return
  }

  const existing = psql(
    config,
    `select count(*)::text from knowledge.monograph_editions e
     join catalog.drugs d on d.id = e.drug_id
     where d.canonical_name = 'sertralin'`,
  )
  if (existing !== '0') {
    console.error(
      'Det finnes alt en monografiutgave for sertralin i denne basen.\n' +
        'Kjør `npm run db:reset` først: røyktesten trenger en åpen søkeplan.',
    )
    process.exitCode = 2
    return
  }

  console.log('Antidep: ekte søk mot Europe PMC, PubMed og Crossref.\n')

  seed()

  const editor = editorClient()

  // Kildeoppdagelsen er et semantisk ledd, og det trenger en tildelt tjeneste
  // før databasen legger ut arbeid til det. Tildelingen går over den samme
  // api-veien en redaktør bruker.
  await call(editor, 'assign_agent_role_model', {
    p_agent_role: 'source_discovery',
    p_provider: 'antidep-test',
    p_model: `web-smoke-${RUN}`,
    p_model_version_disclosure: 'not_exposed',
    p_reason: 'Den nettbaserte røyktesten.',
  })

  const order = (await call(editor, 'order_monograph', {
    p_drug_name: 'sertralin',
    p_note: 'Den nettbaserte røyktesten.',
  })) as Record<string, unknown>
  const edition = String(order['reference'] ?? '')
  check('bestillingen ga en utgave med kunnskapsbehov', edition.length === 32)

  const plans = psql(
    config,
    `select count(*)::text from workflow.monograph_search_plans p
     join knowledge.monograph_editions e on e.id = p.edition_id
     where e.reference = ${q(edition)}`,
  )
  check('og søkeplaner å søke for', plans !== '0', `${plans} planer`)

  const secret = psql(
    config,
    `select provenance.issue_agent_identity_credential(
       'agent-identity:source-discovery-01', 'human:peder-holman')`,
  )

  // Den installerte kommandoen, med driftens egne miljøvariabler. Ingen
  // fetcher byttes ut: dette går ut på nettet.
  const run = spawnSync(
    process.execPath,
    ['src/ops/monograph-discovery-cli.ts', '--max-plans', '2'],
    {
      env: {
        ...process.env,
        ANTIDEP_SUPABASE_URL: config.apiUrl,
        // Den lokale anon-nøkkelen er en klientnøkkel med rollen `anon`, og
        // `assertPublishableKey` godtar den. Ingen privilegert nøkkel er i
        // spill her.
        ANTIDEP_SUPABASE_PUBLISHABLE_KEY: config.anonKey,
        ANTIDEP_DISCOVERY_AGENT_IDENTITY_KEY: 'agent-identity:source-discovery-01',
        ANTIDEP_DISCOVERY_AGENT_SECRET: secret,
      },
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  )
  process.stdout.write(run.stdout ?? '')
  if ((run.stderr ?? '').length > 0) {
    process.stderr.write(run.stderr ?? '')
  }
  check('kommandoen `ops:discovery` kjørte gjennom', run.status === 0)

  // ------------------------------------------------------------------
  // Det som faktisk står i databasen etterpå
  // ------------------------------------------------------------------
  const rows = psql(
    config,
    `select string_agg(
       s.platform || ' | ' || s.outcome::text || ' | treff=' ||
       coalesce(s.result_count::text, 'ukjent') || ' | lest=' || s.screened_count::text ||
       ' | avtrykk=' || case when s.response_digest is null then 'nei' else 'ja' end ||
       ' | ' || coalesce(s.limitation_note, 'ingen begrensning'),
       '§' order by s.platform, s.executed_at)
     from workflow.monograph_searches s
     join workflow.monograph_search_plans p on p.id = s.plan_id
     join knowledge.monograph_editions e on e.id = p.edition_id
     where e.reference = ${q(edition)}`,
  )
  // `psql()` svarer med første linje, så aggregatet skilles med et tegn som
  // ikke er linjeskift, og brytes opp her.
  console.log(`\nSøkene slik de er lagret:\n  ${rows.split('§').join('\n  ')}\n`)

  const executed = psql(
    config,
    `select count(*)::text from workflow.monograph_searches s
     join workflow.monograph_search_plans p on p.id = s.plan_id
     join knowledge.monograph_editions e on e.id = p.edition_id
     where e.reference = ${q(edition)} and s.outcome = 'executed'`,
  )
  check('minst ett søk ble faktisk utført mot en ekte tjeneste', executed !== '0')

  check(
    'hvert utført søk bærer et avtrykk av svaret det leste',
    psql(
      config,
      `select count(*)::text from workflow.monograph_searches s
       join workflow.monograph_search_plans p on p.id = s.plan_id
       join knowledge.monograph_editions e on e.id = p.edition_id
       where e.reference = ${q(edition)}
         and s.outcome = 'executed'
         and s.response_digest is null`,
    ) === '0',
  )

  // Den faktiske søkestrengen og den faktiske adressen er lagret, og ikke bare
  // «et søk ble gjort»: et foreslått søk er ikke et utført søk.
  const endpoints = psql(
    config,
    `select count(distinct s.evidence_endpoint)::text
     from workflow.monograph_searches s
     join workflow.monograph_search_plans p on p.id = s.plan_id
     join knowledge.monograph_editions e on e.id = p.edition_id
     where e.reference = ${q(edition)} and s.evidence_endpoint is not null`,
  )
  check('den faktiske adressen og søkestrengen er lagret per søk', endpoints !== '0')

  const candidates = psql(
    config,
    `select count(*)::text from workflow.monograph_candidate_sources c
     join workflow.monograph_searches s on s.id = c.search_id
     join workflow.monograph_search_plans p on p.id = s.plan_id
     join knowledge.monograph_editions e on e.id = p.edition_id
     where e.reference = ${q(edition)}`,
  )
  check('ekte treff er registrert som kandidatkilder', candidates !== '0', `${candidates} treff`)

  const titles = psql(
    config,
    `select string_agg(left(c.title, 76), '§' order by c.title)
     from (
       select distinct c.title
       from workflow.monograph_candidate_sources c
       join workflow.monograph_searches s on s.id = c.search_id
       join workflow.monograph_search_plans p on p.id = s.plan_id
       join knowledge.monograph_editions e on e.id = p.edition_id
       where e.reference = ${q(edition)}
       limit 8
     ) c`,
  )
  console.log(`\nEt utvalg av de ekte treffene:\n  ${titles.split('§').join('\n  ')}\n`)

  // Treffene er ekte og ikke prøvens egne: de bærer identifikatorer ingen i
  // dette repoet har skrevet.
  check(
    'treffene bærer sine egne identifikatorer fra tjenesten',
    psql(
      config,
      `select count(*)::text from workflow.monograph_candidate_sources c
       join workflow.monograph_searches s on s.id = c.search_id
       join workflow.monograph_search_plans p on p.id = s.plan_id
       join knowledge.monograph_editions e on e.id = p.edition_id
       where e.reference = ${q(edition)}
         and c.identifier_value is not null
         and c.identifier_value not like '%test%'`,
    ) !== '0',
  )

  // Kjøringen er registrert med den kapasiteten den faktisk hadde:
  // `registration` betyr «Antideps egen kode utførte dette», og skal aldri
  // kunne leses som en semantisk vurdering en KI-agent gjorde.
  check(
    'kjøringen er ført som Antideps egen utførelse og ikke som en semantisk vurdering',
    psql(
      config,
      `select count(*)::text from provenance.agent_runs r
       where r.agent_role = 'source_discovery'
         and r.input_manifest ->> 'mode' = 'machine_executed'`,
    ) !== '0',
  )

  // ------------------------------------------------------------------
  // Innhentingen: finnes originalmaterialet åpent?
  //
  // Søket er den ene halvdelen av kildeoppdagelsen; innhentingen er den andre.
  // Her prøves den mot en ekte DOI fra et ekte treff: Antidep spør Europe PMC
  // om det finnes en åpen fulltekst, og henter i så fall de første bytene
  // gjennom den samme vaktede klienten drift bruker.
  //
  // Ingenting registreres. Å registrere en fulltekst er å begynne det faglige
  // arbeidet, og det hører til fase D.
  // ------------------------------------------------------------------
  const doi = psql(
    config,
    `select c.identifier_value
     from workflow.monograph_candidate_sources c
     join workflow.monograph_searches s on s.id = c.search_id
     join workflow.monograph_search_plans p on p.id = s.plan_id
     join knowledge.monograph_editions e on e.id = p.edition_id
     where e.reference = ${q(edition)}
       and c.identifier_kind = 'doi'
       and c.identifier_value is not null
     order by c.identifier_value
     limit 1`,
  )
  check('et ekte treff bærer en DOI å prøve innhentingen med', doi.length > 0, doi)

  if (doi.length > 0) {
    const openUrl = await openAccessPdfUrl(doi, guardedGet)
    check('innhentingsveien slo opp åpen tilgang for en ekte DOI', true, doi)

    if (openUrl === null) {
      console.log(
        `\nInnhenting: ingen åpen fulltekst for ${doi}.\n` +
          '  Det er en tilgangsbegrensning og ingen faglig utelukkelse.\n',
      )
    } else {
      const fetched = await guardedGet(openUrl, { timeoutMs: 30_000, maxBytes: 8 * 1024 * 1024 })
      const outcome =
        fetched.status === 'ok'
          ? `HTTP ${String(fetched.httpStatus)}, ${String(fetched.bytes.length)} byte, ${fetched.contentType}`
          : fetched.message
      console.log(`\nInnhenting: åpen fulltekst oppgitt for ${doi}.\n  ${openUrl}\n  ${outcome}\n`)

      // Utfallet er *klassifisert*, og det er hele kravet. En utgiver som svarer
      // 403 på en automatisk henting, er en tilgangsbegrensning; en fil som kom,
      // er originalmateriale. Begge er gyldige utfall av en røyktest, og ingen av
      // dem er en konklusjon om kunnskapen. En prøve som krevde at hentingen
      // *lyktes*, ville vært rød på grunn av utgiverens botvern — og ville
      // dermed sagt noe usant om flyten.
      check(
        'og den vaktede klienten ga et entydig utfall: fil eller tilgangsbegrensning',
        fetched.status === 'ok'
          ? fetched.bytes.length > 0
          : fetched.message.length > 0 && !fetched.message.includes('evidens'),
      )
    }
  }

  console.log(
    'Ekte eksterne treff er brukt av den nye flyten, gjennom den kontrollerte\n' +
      'skriveveien, i en isolert lokal base. Dette er en teknisk røyktest og\n' +
      'ingen faglig vurdering.',
  )
}

await main()
