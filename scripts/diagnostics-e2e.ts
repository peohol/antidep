// ============================================================================
// Den rå årsaken, hele veien fram — mot en ekte stack
//
//   npm run db:test:diagnostics
//
// Enhetsprøvene dekker hver sin halvdel: nettleseren sender, og ruten
// videresender. Ingen av dem beviser at årsaken faktisk *ligger der* etterpå.
// Denne kjøringen går hele veien med den ekte serverruten, den ekte
// Data API-en og den ekte databasen, og leser resultatet med psql — altså
// utenom enhver leservei appen har.
//
// Den prøver fire ting som betyr noe:
//
//   * at årsaken havner i workflow.client_diagnostics, med stacken i behold
//   * at den samme observasjonen levert to ganger blir én rad, slik at et
//     ubekreftet forsøk kan gjentas uten å doble noe
//   * at en tokenformet streng er vasket bort før lagring
//   * at et kall uten gyldig token ikke legger igjen noe
// ============================================================================

import { randomUUID } from 'node:crypto'

import { serveDiagnostics } from '../src/diagnostics/route.ts'
import { check, psql, q, readLocalStackConfig, userToken } from './local-stack.ts'

const config = readLocalStackConfig(process.argv.slice(2))
const USER = '9f000000-0000-4000-8000-00000000000d'

const environment = {
  ANTIDEP_SUPABASE_URL: config.apiUrl,
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY: config.anonKey,
}

function envelope(eventId: string, accessToken: string, detail: string): Request {
  return new Request('https://antidep.example/diagnostics', {
    method: 'POST',
    body: JSON.stringify({
      eventId,
      accessToken,
      area: 'work_queue',
      kind: 'unavailable',
      operation: 'public_work_board',
      code: 'PGRST301',
      httpStatus: 503,
      transport: 'http',
      detail,
    }),
  })
}

function stored(eventId: string): number {
  return Number(
    psql(
      config,
      `select count(*) from workflow.client_diagnostics where client_event_id = ${q(eventId)}`,
    ),
  )
}

async function main(): Promise<void> {
  console.log('Diagnostikkveien, ende til ende')

  psql(
    config,
    `insert into auth.users (id, email)
     values (${q(USER)}, 'diagnostikk-e2e@test.invalid')
     on conflict (id) do nothing;`,
  )

  const token = userToken(config, USER)
  const eventId = randomUUID()
  const detail =
    'TypeError: Failed to fetch\n    at callRpc (gateway.ts:1:1)\n' +
    'authorization: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.hemmelig.signatur'

  const first = await serveDiagnostics(envelope(eventId, token, detail), environment)
  check('ruten tar imot observasjonen', first.status === 204, String(first.status))
  check('og årsaken ligger i den private lagringen', stored(eventId) === 1)

  const lagret = psql(
    config,
    `select detail from workflow.client_diagnostics where client_event_id = ${q(eventId)}`,
  )
  check('med stacken i behold', lagret.includes('at callRpc (gateway.ts:1:1)'))
  check('og uten den tokenformede strengen', !lagret.includes('hemmelig.signatur'))

  // Et ubekreftet forsøk prøves på nytt. Det skal ikke bli to rader.
  const again = await serveDiagnostics(envelope(eventId, token, detail), environment)
  check('den samme observasjonen levert igjen svarer likt', again.status === 204)
  check('og blir fortsatt én rad', stored(eventId) === 1)

  // Uten en gyldig token er det ingen å tilskrive observasjonen.
  const anonymous = randomUUID()
  const refused = await serveDiagnostics(
    envelope(anonymous, 'ikke-en-gyldig-token', detail),
    environment,
  )
  check('et kall uten gyldig token svarer det samme utad', refused.status === 204)
  check('men legger ingenting igjen', stored(anonymous) === 0)

  // Og ingen leservei: kontrollen er på grants, ikke på tilfellet.
  const lesbar = psql(
    config,
    `select count(*) from (values ('anon'), ('authenticated'), ('service_role')) as r(name)
     where has_table_privilege(r.name, 'workflow.client_diagnostics', 'SELECT')`,
  )
  check('ingen klientrolle kan lese lagringen', lesbar === '0')
}

await main()
