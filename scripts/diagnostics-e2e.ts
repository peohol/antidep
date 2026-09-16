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
//   * at årsaken **fortsatt blir en varig rad når Data API-et er slått ut**,
//     gjennom Antideps egen databaseforbindelse — og at den kan leses tilbake
//   * at den samme årsaken også står i serverloggen
//   * at en uinnlogget besøkende melder problemet uten ett tegn fritekst
//   * at reserverollen ikke kan lese én rad, heller ikke sine egne
// ============================================================================

import { randomUUID } from 'node:crypto'

import {
  serveDiagnostics,
  type ForwardDiagnostic,
  type JournalLine,
} from '../src/diagnostics/route.ts'
import { check, psql, q, readLocalStackConfig, userToken } from './local-stack.ts'

const config = readLocalStackConfig(process.argv.slice(2))
const USER = '9f000000-0000-4000-8000-00000000000d'

// Reserverollen får passord bare her, mot den lokale stacken. I en utrulling
// settes det én gang av den som drifter, og det finnes ikke i repoet.
const RESERVE_PASSORD = 'lokal-proeve-antidep-diagnostikk'
psql(config, `alter role antidep_diagnostics password ${q(RESERVE_PASSORD)};`)

const reserveUrl = config.dbUrl.replace(
  'postgresql://postgres:postgres@',
  `postgresql://antidep_diagnostics:${RESERVE_PASSORD}@`,
)
if (
  !/^postgresql:\/\/antidep_diagnostics:[^@]+@(127\.0\.0\.1|localhost|\[::1\]):/.test(reserveUrl)
) {
  throw new Error('Reserveadressen peker ikke på den lokale stacken.')
}

const environment = {
  ANTIDEP_SUPABASE_URL: config.apiUrl,
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY: config.anonKey,
  ANTIDEP_DIAGNOSTICS_DATABASE_URL: reserveUrl,
}

/**
 * Data API-et som svikter slik det faktisk gjør.
 *
 * PGRST000 til PGRST003 er PostgREST som ikke nådde databasen — tjenesten
 * svarer, men kan ikke utføre kallet. Det er nettopp tilfellet reserven finnes
 * for, og det er også tilfellet der autentiseringstjenesten fortsatt svarer, så
 * avsenderen kan kontrolleres.
 *
 * Å peke hele adressen på en død port ville slått ut begge tjenestene. Da kan
 * ingen bekrefte hvem som sender, og da skal ingenting skrives — riktig, men
 * ikke det som prøves her. Det tilfellet har sin egen påstand nederst.
 */
const postgrestSvikter: ForwardDiagnostic = () => Promise.resolve({ delivered: false, retry: true })

/** Hele Supabase utilgjengelig: verken Data API eller autentisering svarer. */
const altNede = {
  ANTIDEP_SUPABASE_URL: 'http://127.0.0.1:1/ingen-tjeneste',
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY: config.anonKey,
  ANTIDEP_DIAGNOSTICS_DATABASE_URL: reserveUrl,
}

/** Serverloggen, lest av prøven i stedet for av utrullingen. */
function fangLoggen(): { linjer: JournalLine[]; journal: (line: JournalLine) => void } {
  const linjer: JournalLine[] = []
  return { linjer, journal: (line) => linjer.push(line) }
}

function envelope(eventId: string, accessToken: string | null, detail: string): Request {
  return new Request('https://antidep.example/diagnostics', {
    method: 'POST',
    // Adressen plattformen setter. Serveren teller avsenderen på en sum av
    // den, siden ingen token kan kontrolleres når PostgREST er nede.
    headers: { 'x-real-ip': '198.51.100.7' },
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

  // Radene autentiseringstjenesten faktisk slår opp i. Uten aud og role ville
  // den ikke kjent igjen brukeren tokenet peker på, og kontrollen av avsenderen
  // ville sagt nei av feil grunn.
  psql(
    config,
    `insert into auth.users (id, instance_id, aud, role, email)
     values (${q(USER)}, '00000000-0000-0000-0000-000000000000',
             'authenticated', 'authenticated', 'diagnostikk-e2e@test.invalid')
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

  // En påstand om å være innlogget er ikke en innlogging.
  //
  // Dette går gjennom den ekte autentiseringstjenesten på den lokale stacken:
  // ingen injisert kontroll, ingen doble. Tokenen er oppdiktet, og da skal
  // ingen tekst skrives noe sted — verken i loggen eller i databasen. Svaret
  // skal likevel ikke skille seg fra et vellykket, ellers ville ruten vært et
  // sted å prøve seg fram fra utsiden.
  const påstått = randomUUID()
  const påførtLogg = fangLoggen()
  const refused = await serveDiagnostics(
    envelope(påstått, 'ikke-en-gyldig-token', 'HEMMELIG-PÅFØRT-TEKST fra en fremmed'),
    environment,
    undefined,
    påførtLogg.journal,
  )
  check('en oppdiktet token svarer det samme utad', refused.status === 204, String(refused.status))
  check('men legger ingenting igjen', stored(påstått) === 0)
  check(
    'og ingen av avsenderens ord ble skrevet ned',
    !JSON.stringify(påførtLogg.linjer).includes('HEMMELIG-PÅFØRT-TEKST'),
    JSON.stringify(påførtLogg.linjer),
  )

  // ==========================================================================
  // Selve poenget: Data API-et er nede, og raden kommer fram likevel.
  //
  // Adressen peker på en port ingen lytter på, så PostgREST er utilgjengelig
  // for ekte. Observasjonen skal da gå gjennom Antideps egen
  // databaseforbindelse — og den skal kunne leses tilbake etterpå, som en rad
  // og ikke bare som en linje i en logg.
  // ==========================================================================
  const utenDataApi = randomUUID()
  const uteLogg = fangLoggen()
  const nede = await serveDiagnostics(
    envelope(utenDataApi, token, detail),
    environment,
    postgrestSvikter,
    uteLogg.journal,
  )
  check('et sviktende Data API svarer likevel 204', nede.status === 204, String(nede.status))
  check('fordi raden gikk gjennom den egne forbindelsen', stored(utenDataApi) === 1)

  const varig = psql(
    config,
    `select replace(detail, chr(10), ' / ')
     from workflow.client_diagnostics where client_event_id = ${q(utenDataApi)}`,
  )
  check(
    'og den kan leses tilbake, med stacken i behold',
    varig.includes('at callRpc (gateway.ts:1:1)'),
    varig,
  )
  check('og uten den tokenformede strengen', !varig.includes('hemmelig.signatur'), varig)

  const avsender = psql(
    config,
    `select coalesce(reported_by_user_id::text, '') || '|' || coalesce(reporter_ip_hash, '')
     from workflow.client_diagnostics where client_event_id = ${q(utenDataApi)}`,
  )
  check('raden er merket som serverens observasjon', /^\|[0-9a-f]{64}$/.test(avsender), avsender)
  check('og adressen selv er aldri lagret', !avsender.includes('198.51.100.7'), avsender)

  check(
    'den samme årsaken står også i serverloggen',
    uteLogg.linjer.some((linje) => linje.detail.includes('at callRpc (gateway.ts:1:1)')),
    JSON.stringify(uteLogg.linjer.map((linje) => linje.reporter)),
  )
  check(
    'og den første linjen, før avsenderen var kontrollert, bar ingen tekst',
    uteLogg.linjer[0]?.reporter === 'ukjent' && !uteLogg.linjer[0].detail.includes('callRpc'),
    JSON.stringify(uteLogg.linjer[0]),
  )
  check(
    'og loggen sier ikke at den er det eneste stedet, for raden kom fram',
    uteLogg.linjer.every((linje) => linje.bareILoggen !== true),
  )
  check(
    'og loggen bærer aldri tokenen',
    !JSON.stringify(uteLogg.linjer).includes(token.slice(0, 40)),
  )

  // Det samme forsøket en gang til blir den samme raden, ikke en til.
  const igjen = await serveDiagnostics(
    envelope(utenDataApi, token, detail),
    environment,
    postgrestSvikter,
    fangLoggen().journal,
  )
  check('et nytt forsøk svarer likt', igjen.status === 204)
  check('og blir fortsatt én rad', stored(utenDataApi) === 1)

  // Og når heller ikke den egne forbindelsen finnes, skal ruten si fra framfor
  // å la nettleseren slette årsaken.
  const uten = randomUUID()
  const utenLogg = fangLoggen()
  const helt = await serveDiagnostics(
    envelope(uten, token, detail),
    { ...environment, ANTIDEP_DIAGNOSTICS_DATABASE_URL: '' },
    postgrestSvikter,
    utenLogg.journal,
  )
  check('uten noen vei igjen svarer ruten 503', helt.status === 503, String(helt.status))
  check('og ingenting ble lagret', stored(uten) === 0)
  check('men loggen sier at den er det eneste stedet', utenLogg.linjer.at(-1)?.bareILoggen === true)

  // ==========================================================================
  // Er *alt* nede, kan ingen bekrefte hvem som sender.
  //
  // Da skal ingen tekst skrives noe sted — heller ikke i reserven, som ellers
  // ville tatt imot en fremmeds ord som om de kom fra en bruker. Nettleseren
  // beholder årsaken til noen kan bekrefte avsenderen.
  // ==========================================================================
  const altBorte = randomUUID()
  const altLogg = fangLoggen()
  const ingen = await serveDiagnostics(
    envelope(altBorte, token, detail),
    altNede,
    postgrestSvikter,
    altLogg.journal,
  )
  check(
    'uten noen å bekrefte avsenderen svarer ruten 503',
    ingen.status === 503,
    String(ingen.status),
  )
  check('og ingenting ble lagret', stored(altBorte) === 0)
  check(
    'og ingen tekst ble skrevet ned',
    !JSON.stringify(altLogg.linjer).includes('callRpc'),
    JSON.stringify(altLogg.linjer),
  )

  // ==========================================================================
  // Den uinnloggede besøkende: et problem meldt, og ikke ett tegn fritekst.
  // ==========================================================================
  const anonymtNummer = randomUUID()
  const anonymLogg = fangLoggen()
  const anonym = await serveDiagnostics(
    envelope(anonymtNummer, null, 'HEMMELIG-PÅFØRT-TEKST fra en fremmed'),
    environment,
    undefined,
    anonymLogg.journal,
  )
  check('en uinnlogget melding tas imot', anonym.status === 204, String(anonym.status))
  check('og står i serverloggen', anonymLogg.linjer[0]?.reporter === 'anonym')
  check('men ble aldri en rå-årsak-rad', stored(anonymtNummer) === 0)
  check(
    'og ingenting av kallerens egen tekst finnes noe sted',
    !JSON.stringify(anonymLogg.linjer).includes('HEMMELIG-PÅFØRT-TEKST'),
  )

  const meldt = psql(
    config,
    `select count(*) from workflow.technical_incident_events
     where reporter_key like 'offentlig:%'
       and occurred_at > now() - interval '5 minutes'`,
  )
  check('problemet er meldt på det offentlige sporet', Number(meldt) >= 1, meldt)

  const forurenset = psql(
    config,
    `select count(*) from workflow.technical_incident_events
     where diagnosis like '%HEMMELIG-PÅFØRT-TEKST%'`,
  )
  check('og sporet bærer ingen tekst fra avsenderen', forurenset === '0', forurenset)

  // ==========================================================================
  // Reserverollen kan legge til, og ingenting mer.
  // ==========================================================================
  const kanLese = psql(
    config,
    `select count(*) from (values
       ('workflow.client_diagnostics'),
       ('workflow.technical_incidents'),
       ('workflow.technical_incident_events')) as t(name)
     where has_table_privilege('antidep_diagnostics', t.name, 'SELECT')
        or has_table_privilege('antidep_diagnostics', t.name, 'INSERT')
        or has_table_privilege('antidep_diagnostics', t.name, 'UPDATE')
        or has_table_privilege('antidep_diagnostics', t.name, 'DELETE')`,
  )
  check('reserverollen kan hverken lese eller skrive de tre tabellene', kanLese === '0', kanLese)

  // Lest av ACL-en framfor av den effektive rettigheten: has_function_privilege
  // tar med alt som er gitt til PUBLIC, og en telling på den ville sagt noe om
  // resten av databasen framfor om denne rollen.
  const gitt = psql(
    config,
    `select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     cross join lateral aclexplode(coalesce(p.proacl, array[]::aclitem[])) a
     where n.nspname in ('workflow', 'provenance', 'knowledge', 'catalog', 'audit', 'api')
       and a.grantee = 'antidep_diagnostics'::regrole::oid
       and a.privilege_type = 'EXECUTE'`,
  )
  check('og er gitt nøyaktig de to append-funksjonene', gitt === '2', gitt)

  // Og den som betyr noe uansett hvor granten kom fra: ingen annen
  // SECURITY DEFINER-funksjon er nåbar. En vanlig funksjon kjører med rollens
  // egne rettigheter, og de er ingen.
  const andreDefinere = psql(
    config,
    `select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('workflow', 'provenance', 'knowledge', 'catalog', 'audit', 'api')
       and p.prosecdef
       and has_function_privilege('antidep_diagnostics', p.oid, 'execute')
       and p.proname not in ('ingest_client_diagnostic', 'ingest_public_technical_problem')`,
  )
  check(
    'og kan ikke kjøre noen annen SECURITY DEFINER-funksjon',
    andreDefinere === '0',
    andreDefinere,
  )

  const egenskaper = psql(
    config,
    `select rolsuper::text || rolcreatedb::text || rolcreaterole::text
            || rolbypassrls::text || rolinherit::text
     from pg_roles where rolname = 'antidep_diagnostics'`,
  )
  check(
    'og er hverken superbruker, kan opprette noe eller gå utenom RLS',
    egenskaper === 'fffff',
    egenskaper,
  )

  // Og ingen leservei: kontrollen er på grants, ikke på tilfellet.
  const lesbar = psql(
    config,
    `select count(*) from (values ('anon'), ('authenticated'), ('service_role')) as r(name)
     where has_table_privilege(r.name, 'workflow.client_diagnostics', 'SELECT')`,
  )
  check('ingen klientrolle kan lese lagringen', lesbar === '0')
}

await main()
