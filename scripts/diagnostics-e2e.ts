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
// Den prøver det som betyr noe:
//
//   * at årsaken havner i workflow.client_diagnostics, med stacken i behold
//   * at den samme observasjonen levert to ganger blir én rad, slik at et
//     ubekreftet forsøk kan gjentas uten å doble noe
//   * at en tokenformet streng er vasket bort før lagring
//   * at et kall uten gyldig token ikke legger igjen noe
//   * at årsaken finnes i Antideps egen serverlogg **også når Data API-et er
//     slått ut** — den ene lagringen som ikke går gjennom Supabase
//   * at en uinnlogget besøkende blir skrevet ned i loggen og aldri som en rad
// ============================================================================

import { randomUUID } from 'node:crypto'

import { serveDiagnostics, type JournalLine } from '../src/diagnostics/route.ts'
import { check, psql, q, readLocalStackConfig, userToken } from './local-stack.ts'

const config = readLocalStackConfig(process.argv.slice(2))
const USER = '9f000000-0000-4000-8000-00000000000d'

const environment = {
  ANTIDEP_SUPABASE_URL: config.apiUrl,
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY: config.anonKey,
}

/** Serverloggen, lest av prøven i stedet for av utrullingen. */
function fangLoggen(): { linjer: JournalLine[]; journal: (line: JournalLine) => void } {
  const linjer: JournalLine[] = []
  return { linjer, journal: (line) => linjer.push(line) }
}

function envelope(eventId: string, accessToken: string | null, detail: string): Request {
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

  // Linjeskiftene slås sammen i spørringen: `psql(...)` gir én linje tilbake, og
  // en flerlinjet stack ville blitt kuttet etter den første. Da ville begge
  // påstandene under vært sanne uten å ha sett teksten de handler om — og den
  // ene av dem ville vært sann nettopp fordi den manglet.
  const lagret = psql(
    config,
    `select replace(detail, chr(10), ' / ')
     from workflow.client_diagnostics where client_event_id = ${q(eventId)}`,
  )
  check('med stacken i behold', lagret.includes('at callRpc (gateway.ts:1:1)'), lagret)
  check('og uten den tokenformede strengen', !lagret.includes('hemmelig.signatur'), lagret)
  check('men med linjen den sto på', lagret.includes('authorization:'), lagret)

  // Et ubekreftet forsøk prøves på nytt. Det skal ikke bli to rader.
  const again = await serveDiagnostics(envelope(eventId, token, detail), environment)
  check('den samme observasjonen levert igjen svarer likt', again.status === 204)
  check('og blir fortsatt én rad', stored(eventId) === 1)

  // Uten en gyldig token er det ingen å tilskrive observasjonen. Databasen
  // svarer, så dette er et endelig utfall — og svaret skal ikke skille seg fra
  // et vellykket, ellers ville ruten vært et sted å prøve seg fram fra utsiden.
  const anonymous = randomUUID()
  const refused = await serveDiagnostics(
    envelope(anonymous, 'ikke-en-gyldig-token', detail),
    environment,
  )
  check('et kall uten gyldig token svarer det samme utad', refused.status === 204)
  check('men legger ingenting igjen', stored(anonymous) === 0)

  // Og den ene forskjellen som må finnes: når lagringen ikke er tilgjengelig,
  // skal ruten si fra, slik at nettleseren beholder årsaken framfor å slette
  // den. Dette er tapsmåten utboksen finnes for å fjerne.
  //
  // Her slås Data API-et ut for ekte — adressen peker på en port ingen lytter
  // på — og det er nettopp da den andre lagringen må bevise seg: linjen i
  // Antideps egen serverlogg går ikke gjennom Supabase i det hele tatt.
  const utilgjengelig = randomUUID()
  const uteLogg = fangLoggen()
  const nede = await serveDiagnostics(
    envelope(utilgjengelig, token, detail),
    {
      ANTIDEP_SUPABASE_URL: 'http://127.0.0.1:1/ingen-tjeneste',
      ANTIDEP_SUPABASE_PUBLISHABLE_KEY: config.anonKey,
    },
    undefined,
    uteLogg.journal,
  )
  check('en utilgjengelig lagring svarer 503, ikke 204', nede.status === 503, String(nede.status))
  check('og ingenting ble lagret', stored(utilgjengelig) === 0)
  check(
    'men årsaken står i serverloggen, med stacken i behold',
    uteLogg.linjer[0]?.detail.includes('at callRpc (gateway.ts:1:1)') === true,
    JSON.stringify(uteLogg.linjer[0]?.detail),
  )
  check(
    'og uten den tokenformede strengen',
    uteLogg.linjer.every((linje) => !linje.detail.includes('hemmelig.signatur')),
  )
  check(
    'og linjen sier at loggen er det eneste stedet den finnes',
    uteLogg.linjer.at(-1)?.bareILoggen === true,
  )
  check(
    'og loggen bærer aldri tokenen',
    !JSON.stringify(uteLogg.linjer).includes(token.slice(0, 40)),
  )

  // Den offentlige arbeidsoversikten svikter også for noen som ikke er
  // innlogget. Det finnes ingen å tilskrive en rad, men årsaken er like verdt å
  // forstå — og den skal aldri kunne bli en rad i den private lagringen.
  const anonymtNummer = randomUUID()
  const anonymLogg = fangLoggen()
  const anonym = await serveDiagnostics(
    envelope(anonymtNummer, null, detail),
    environment,
    undefined,
    anonymLogg.journal,
  )
  check('en uinnlogget observasjon tas imot', anonym.status === 204, String(anonym.status))
  check('og står i serverloggen', anonymLogg.linjer[0]?.reporter === 'anonym')
  check('men ble aldri en rad', stored(anonymtNummer) === 0)

  // Og ingen leservei: kontrollen er på grants, ikke på tilfellet.
  const lesbar = psql(
    config,
    `select count(*) from (values ('anon'), ('authenticated'), ('service_role')) as r(name)
     where has_table_privilege(r.name, 'workflow.client_diagnostics', 'SELECT')`,
  )
  check('ingen klientrolle kan lese lagringen', lesbar === '0')
}

await main()
