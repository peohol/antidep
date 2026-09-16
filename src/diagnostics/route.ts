// ============================================================================
// Ruten den rå årsaken kommer inn på
//
// En egen transport, og det er hele poenget. Meldingen om at et område ikke
// svarer, går over Data API-et — men den rå årsaken kan ikke gå den samme veien,
// for det er nettopp den veien som kanskje er nede. En observasjon som bare
// overlever når det den beskriver ikke skjedde, er ingen observasjon.
//
// ----------------------------------------------------------------------------
// Hvorfor same-origin, og hvorfor det ikke er en fullmakt for kalleren
//
// Ruten ligger på Antideps egen opprinnelse. Det gir tre ting nettleseren ikke
// får til på tvers av opprinnelser: `sendBeacon` kan levere mens fanen lukkes,
// det finnes ingen preflight å feile på, og serveren kan prøve igjen når
// databasen svarer tregt.
//
// Kalleren får ingen ny fullmakt av at ruten finnes. På normalveien
// videresender den brukerens egen token, og databasen avgjør alt.
//
// ----------------------------------------------------------------------------
// De tre lagringene, i den rekkefølgen de svikter
//
//   1. Kjøreloggen. Én linje i utrullingens egen private logg, skrevet først
//      og alltid. Går ikke gjennom Supabase i det hele tatt. Blir prosessen
//      revet ned i kallet videre, er linjen allerede der.
//
//   2. Raden over Data API-et. Den varige, søkbare kopien, tilskrevet den
//      innloggede brukeren fordi databasen selv kontrollerte tokenen.
//
//   3. Raden gjennom Antideps egen databaseforbindelse (`store.ts`). Reserven
//      for at ledd 2 kan være nede — og den er nede nettopp når årsaken er
//      verdt mest. Den går ikke gjennom PostgREST, og den er varig på samme
//      måte som ledd 2: en rad i den samme private tabellen.
//
// Først når alle tre har sviktet, svarer ruten 503 og ber nettleseren beholde
// observasjonen i utboksen sin.
//
// ----------------------------------------------------------------------------
// Den uinnloggede besøkende, og hvorfor den ikke får sende tekst
//
// Arbeidsoversikten og det publiserte innholdet er åpne for alle. Svikter de
// for noen som ikke er innlogget, finnes det ingen å tilskrive noe — og en åpen
// vei inn for *tekst* ville vært en logg hvem som helst kunne fylle med sine
// egne ord.
//
// Den veien tar derfor ikke imot tekst i det hele tatt. Ruten leser aldri
// `detail` fra en anonym konvolutt, uansett hva som står der, og skriver aldri
// noe av den verken til loggen eller til databasen. Det som går inn, er
// maskinidentifikatorene databasen allerede kontrollerer, og Antidep skriver
// setningen selv av dem.
//
// Tre grenser gjør den veien forsvarlig, og de er strukturelle framfor å hvile
// på en teller alene: ingen fritekst, bare de to områdene en uinnlogget faktisk
// kan se, og en mengdegrense per avsender som databasen håndhever.
//
// ----------------------------------------------------------------------------
// Avsenderen serveren selv observerte
//
// Begge de serverkontrollerte veiene trenger noen å telle på. Uten en
// kontrollert token er det bare én ting serveren vet om avsenderen med
// sikkerhet: hvilken adresse forespørselen kom fra.
//
// Adressen lagres aldri. Det som går til databasen, er en SHA-256 av den, og
// dagens dato går inn i summen slik at pseudonymet roterer i døgnet — kvoten
// gjelder uansett bare den siste timen, så den taper ingenting på det.
//
// Finnes ingen adresse serveren kan stole på, skrives ingenting: en avsender vi
// ikke kan telle, kan vi heller ikke begrense.
//
// ----------------------------------------------------------------------------
// Svaret sier to ting, og ikke én til
//
// 204 betyr *ferdig behandlet*: skrevet ned. 503 betyr *ikke lagret, prøv
// igjen*: ingen av veiene tok imot.
//
// Skillet er ikke kosmetikk. Nettleseren beholder observasjonen i utboksen til
// leveringen er bekreftet, og en rute som svarte 204 på en mislykket lagring,
// ville fått den til å slette årsaken den nettopp skulle berge — den samme
// tapsmåten utboksen finnes for å fjerne.
//
// Utover de to sier svaret ingenting. Om tokenen var gyldig, om kvoten var
// brukt opp, om raden allerede fantes: alt er 204. En rute som skilte dem, ville
// vært et sted å prøve seg fram fra utsiden. Grunnen står i kjøreloggen, som er
// privat.
// ============================================================================

import { createHash } from 'node:crypto'

import { createClient } from '@supabase/supabase-js'

import type { Database } from '../types/database.ts'
import {
  parseDiagnosticEnvelope,
  scrubDetail,
  MAX_DETAIL_CHARS,
  PUBLIC_TECHNICAL_AREAS,
} from './envelope.ts'
import { createDiagnosticsStore, type DiagnosticsStore, type StoreEnvironment } from './store.ts'

/** Den delen av miljøet ruten leser. Samme verdier som resten av utrullingen. */
export interface DiagnosticsEnvironment extends StoreEnvironment {
  readonly ANTIDEP_SUPABASE_URL?: string | undefined
  readonly ANTIDEP_SUPABASE_PUBLISHABLE_KEY?: string | undefined
  readonly VITE_SUPABASE_URL?: string | undefined
  readonly VITE_SUPABASE_PUBLISHABLE_KEY?: string | undefined
}

/** Hvem kallet gjøres som, og mot hva. */
export interface ForwardTarget {
  readonly url: string
  readonly publishableKey: string
  /** Brukerens egen token, videresendt. Ruten har ingen av sine egne. */
  readonly accessToken: string
}

/**
 * Å sende det videre til databasen over Data API-et. Injiserbar, slik at en
 * prøve slipper nettet.
 *
 * `retry` sier om det er verdt et forsøk til: en svikt uten kode er transporten
 * selv, mens en kode er databasens svar, og et svar skal ikke gjentas.
 */
export type ForwardDiagnostic = (
  target: ForwardTarget,
  args: Record<string, unknown>,
) => Promise<{ readonly delivered: boolean; readonly retry: boolean }>

/**
 * Én linje i Antideps egen serverlogg.
 *
 * Bærer aldri tokenen. Den er avsenderens legitimasjon og har ingenting i en
 * logg å gjøre — `reporter` sier bare *om* observasjonen kunne tilskrives noen,
 * ikke hvem.
 */
export interface JournalLine {
  readonly event: string
  /**
   * Hva serveren vet om avsenderen, og ikke hvem den er.
   *
   * `ukjent` er linjen som skrives *før* tokenen er kontrollert. Den bærer
   * aldri den rå teksten: en påstand om å være innlogget er ikke en innlogging,
   * og en tekst fra en ukontrollert avsender skal ikke skrives ned noe sted.
   */
  readonly reporter: 'innlogget' | 'anonym' | 'ukjent'
  readonly area: string
  readonly kind: string
  readonly operation: string | null
  readonly code: string | null
  readonly httpStatus: number | null
  readonly transport: string
  readonly detail: string
  /** Satt når ingen rad kom fram: da er denne linjen det eneste som finnes. */
  readonly bareILoggen?: true
}

/** Å skrive linjen. Injiserbar, slik at en prøve kan lese den. */
export type DiagnosticsJournal = (line: JournalLine) => void

/**
 * Serverens egen logg, og ikke nettleserens konsoll.
 *
 * `console.error` inne i en serverfunksjon havner i utrullingens private
 * kjørelogg. Prefikset gjør linjene søkbare for en teknisk agent uten at den må
 * kjenne formen på dem.
 */
const consoleJournal: DiagnosticsJournal = (line) => {
  try {
    console.error(`antidep-diagnostikk ${JSON.stringify(line)}`)
  } catch {
    // En logg som ikke kan skrives, skal ikke velte det kallet den beskriver.
  }
}

/**
 * Det som står i loggen i stedet for en anonym avsenders tekst.
 *
 * Antideps egen setning, ikke kallerens. `detail` fra en anonym konvolutt leses
 * aldri i det hele tatt.
 */
const NO_PUBLIC_TEXT = '(ingen tekst: meldingen kom fra en uinnlogget besøkende)'

/** Og det som står der før tokenen er kontrollert. Samme regel, annen grunn. */
const NO_UNVERIFIED_TEXT = '(ingen tekst: avsenderen er ikke kontrollert ennå)'

/**
 * Koder som betyr «tjenesten er ikke tilgjengelig», ikke «databasen avviste».
 *
 * Skillet avgjør om reserveveien brukes, og det er ikke «har kode» mot «mangler
 * kode»: PostgRESTs egne connection-feil *har* kode. PGRST000 til PGRST003 er
 * nettopp at PostgREST ikke nådde databasen, og SQLSTATE-klassene 08
 * (forbindelsen), 53 (ressurser) og 57 (avbrutt av drift) er det samme sett fra
 * databasen. 40001 og 40P01 er serialisering og vranglås — sanne, men
 * forbigående.
 *
 * Alt annet med en kode er databasens egen avgjørelse om *denne* observasjonen,
 * og den gjelder begge veier: et nytt forsøk ville gitt det samme svaret.
 */
const AVAILABILITY_CODE = /^(PGRST00[0-3]|08[0-9A-Z]{3}|53[0-9A-Z]{3}|57P0[123]|40001|40P01)$/

/** Eksportert slik at listen kan prøves mot de kodene den handler om. */
export function isAvailabilityCode(code: string): boolean {
  return AVAILABILITY_CODE.test(code)
}

/**
 * Å kontrollere at tokenen faktisk er en Antidep-innlogging.
 *
 * Injiserbar, slik at en prøve slipper nettet.
 */
export type VerifyReporter = (target: ForwardTarget) => Promise<'verified' | 'rejected' | 'unknown'>

/**
 * Kontrollen går til autentiseringstjenesten, ikke til Data API-et.
 *
 * Det er poenget: de er to forskjellige tjenester. Er PostgREST nede, kan
 * autentiseringen fortsatt svare — og da kan reserveveien brukes med en
 * avsender som faktisk er kontrollert. Er begge nede, kan ingen bekrefte hvem
 * dette er, og da skal ingen tekst skrives ned.
 */
const goTrueVerify: VerifyReporter = async (target) => {
  try {
    const response = await fetch(`${target.url.replace(/\/+$/, '')}/auth/v1/user`, {
      headers: {
        apikey: target.publishableKey,
        authorization: `Bearer ${target.accessToken}`,
      },
    })
    if (response.ok) {
      return 'verified'
    }
    // Et svar som sier nei, er et svar. Alt annet — 5xx, en gateway i veien —
    // er tjenesten som ikke kunne svare, og det er ikke det samme.
    return response.status === 401 || response.status === 403 ? 'rejected' : 'unknown'
  } catch {
    return 'unknown'
  }
}

/**
 * Kroppen leses med et tak.
 *
 * En konvolutt er noen kilobyte. Alt over er enten en feil eller et forsøk, og
 * ingen av delene skal få lov til å bli lest inn i minnet.
 */
const MAX_BODY_BYTES = 16 * 1024

/** En adresse er aldri i nærheten av dette. Taket står for at summen skal være billig. */
const MAX_ADDRESS_CHARS = 100

/**
 * Formen en token har. Ikke en kontroll av at den er ekte — bare av at den er
 * en token i det hele tatt.
 *
 * Står før Auth-kallet, fordi et kall som uansett ikke kan lykkes, ikke skal
 * koste en rundtur til autentiseringstjenesten.
 */
const TOKEN_SHAPE = /^[\w-]+\.[\w-]+\.[\w-]+$/

/**
 * Hvor mange ganger én avsender får prøve i minuttet før den er kontrollert.
 *
 * En nettleser sender en håndfull. Et forsøk på å fylle kjøreloggen eller
 * autentiseringstjenesten sender flere.
 */
const ATTEMPTS_PER_MINUTE = 30

/** Hvor mange avsendere budsjettet husker av gangen. Minnet skal være bundet. */
const MAX_REMEMBERED_REPORTERS = 5000

const attempts = new Map<string, { minute: number; count: number }>()

/**
 * Forsøksbudsjettet, og hva det faktisk er verdt.
 *
 * Det er per instans og lever i minnet: en serverless funksjon har ingen delt
 * tilstand, og to instanser teller hver for seg. Det gjør det til en demper og
 * ikke en garanti — den varige grensen er kvotene i databasen, som gjelder
 * uansett hvor kallet kom fra.
 *
 * Men det er nettopp denne grensen som mangler for *ukontrollerte* kall: de når
 * aldri databasen, så databasekvotene binder dem ikke. Her binder de det de kan
 * koste — en linje i kjøreloggen og en rundtur til autentiseringstjenesten.
 */
export function withinAttemptBudget(reporter: string, now = Date.now()): boolean {
  const minute = Math.floor(now / 60_000)
  const seen = attempts.get(reporter)
  if (seen === undefined || seen.minute !== minute) {
    if (attempts.size >= MAX_REMEMBERED_REPORTERS) {
      // Heller glemme alle enn å vokse uten tak. Et budsjett som spiser minnet,
      // er en verre feil enn et budsjett som nullstilles.
      attempts.clear()
    }
    attempts.set(reporter, { minute, count: 1 })
    return true
  }
  seen.count += 1
  return seen.count <= ATTEMPTS_PER_MINUTE
}

/** Bare for prøver: glem alt budsjettet har sett. */
export function forgetAttempts(): void {
  attempts.clear()
}

function pick(
  env: DiagnosticsEnvironment,
  names: readonly (keyof DiagnosticsEnvironment)[],
): string {
  for (const name of names) {
    const value = env[name]?.trim()
    if (value !== undefined && value.length > 0) {
      return value
    }
  }
  throw new Error(`Ingen av miljøvariablene ${names.join(' eller ')} er satt.`)
}

/**
 * Adressen serveren selv observerte, som en sum.
 *
 * `x-forwarded-for` kan kalleren skrive selv, så den leses sist og bare på
 * det første leddet — plattformen setter det. De to andre settes av
 * plattformen alene og går foran.
 *
 * Datoen går inn i summen, slik at pseudonymet roterer i døgnet. Kvoten gjelder
 * bare den siste timen og taper ingenting på det.
 */
export function reporterIpHash(request: Request, today = new Date()): string | null {
  const candidate =
    request.headers.get('x-vercel-forwarded-for') ??
    request.headers.get('x-real-ip') ??
    request.headers.get('x-forwarded-for')?.split(',')[0]
  const address = candidate?.trim().slice(0, MAX_ADDRESS_CHARS)
  if (address === undefined || address.length === 0) {
    return null
  }
  return createHash('sha256')
    .update(`${address}|${today.toISOString().slice(0, 10)}`)
    .digest('hex')
}

const nothing = (): Response => new Response(null, { status: 204 })

/**
 * Den ekte veien videre, gjennom den samme klienten resten av Antidep bruker.
 *
 * Ikke et håndskrevet REST-kall: skjemavalget, nøkkelen og hodene er konvensjon
 * denne klienten allerede eier, og en egen kopi av dem ville vært en kopi å ta
 * feil i. Klienten er bare konfigurasjon og lages per kall — den holder ingen
 * tilstand å gjenbruke.
 */
const supabaseForward: ForwardDiagnostic = async (target, args) => {
  const client = createClient<Database, 'api'>(target.url, target.publishableKey, {
    db: { schema: 'api' },
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${target.accessToken}` } },
  })
  const { error } = await client.rpc('record_client_diagnostic', args as never)
  if (error === null) {
    return { delivered: true, retry: false }
  }
  // Uten kode sviktet transporten. Med kode er det databasens svar — men ikke
  // alle koder er en avgjørelse om observasjonen: PostgRESTs egne
  // connection-feil har også kode, og de er nettopp tilfellet reserveveien
  // finnes for.
  const code = typeof error.code === 'string' ? error.code : ''
  return { delivered: false, retry: code.length === 0 || AVAILABILITY_CODE.test(code) }
}

/**
 * Tar imot én observasjon, skriver den ned, og legger den i den private
 * lagringen.
 *
 * Prøver igjen én gang på et svar som kan være forbigående, og går deretter
 * utenom Data API-et. Begge deler er ting en server kan gjøre som en nettleser
 * midt i en navigasjon ikke kan, og de er grunnen til at ruten finnes.
 */
export async function serveDiagnostics(
  request: Request,
  env: DiagnosticsEnvironment,
  forward: ForwardDiagnostic = supabaseForward,
  journal: DiagnosticsJournal = consoleJournal,
  store: DiagnosticsStore | null = createDiagnosticsStore(env),
  verify: VerifyReporter = goTrueVerify,
): Promise<Response> {
  if (request.method !== 'POST') {
    return new Response(null, { status: 405, headers: { allow: 'POST' } })
  }

  let envelope
  try {
    const body = await request.text()
    if (body.length > MAX_BODY_BYTES) {
      return new Response(null, { status: 413 })
    }
    envelope = parseDiagnosticEnvelope(JSON.parse(body))
  } catch {
    // Grunnen står i kjøreloggen og aldri i svaret.
    return new Response(null, { status: 400 })
  }

  const anonymous = envelope.accessToken === null
  const ipHash = reporterIpHash(request)

  if (anonymous) {
    return await servePublic(envelope, ipHash, journal, store)
  }

  // Formen til en token. Et kall som uansett ikke kan lykkes, skal ikke koste
  // en rundtur. Svaret skiller seg ikke ut — ruten er ikke et sted å lese noe
  // ut av.
  if (ipHash === null || !TOKEN_SHAPE.test(envelope.accessToken ?? '')) {
    return nothing()
  }

  // Vaskes her også, uavhengig av hva nettleseren gjorde. Databasen vasker
  // uansett; dette er den samme grensen ett ledd tidligere, for en kaller vi
  // ikke kontrollerer.
  const detail = scrubDetail(envelope.detail).slice(0, MAX_DETAIL_CHARS)

  const line: JournalLine = {
    event: envelope.eventId,
    reporter: 'innlogget',
    area: envelope.area,
    kind: envelope.kind,
    operation: envelope.operation,
    code: envelope.code,
    httpStatus: envelope.httpStatus,
    transport: envelope.transport,
    detail,
  }

  let target: ForwardTarget
  try {
    target = {
      url: pick(env, ['ANTIDEP_SUPABASE_URL', 'VITE_SUPABASE_URL']),
      publishableKey: pick(env, [
        'ANTIDEP_SUPABASE_PUBLISHABLE_KEY',
        'VITE_SUPABASE_PUBLISHABLE_KEY',
      ]),
      accessToken: envelope.accessToken ?? '',
    }
  } catch {
    // Uten adresse finnes verken Data API eller autentiseringstjeneste, og da
    // kan ingen bekrefte avsenderen. Ingen tekst skrives, og nettleseren
    // beholder årsaken.
    journal({ ...line, reporter: 'ukjent', detail: NO_UNVERIFIED_TEXT, bareILoggen: true })
    return new Response(null, { status: 503 })
  }

  // Data API-et først, og det *er* kontrollen av avsenderen.
  //
  // `api.record_client_diagnostic(...)` krever `auth.uid()` selv. Kom kallet
  // gjennom, er avsenderen bekreftet av den som faktisk avgjør — ikke av en
  // påstand, og uten en eneste ekstra rundtur. En oppdiktet token får 42501,
  // som er et endelig svar og ikke utilgjengelighet.
  let cause = { delivered: false, retry: true }
  for (let i = 0; i < 2; i += 1) {
    try {
      cause = await forward(target, {
        p_event_id: envelope.eventId,
        p_area: envelope.area,
        p_kind: envelope.kind,
        p_operation: envelope.operation,
        p_code: envelope.code,
        p_http_status: envelope.httpStatus,
        p_transport: envelope.transport,
        p_detail: detail,
      })
    } catch {
      // Et brudd i nettet mellom ruten og Data API-et. Verdt ett forsøk til.
      cause = { delivered: false, retry: true }
    }
    if (cause.delivered || !cause.retry) {
      break
    }
  }

  if (cause.delivered) {
    journal(line)
    return nothing()
  }
  if (!cause.retry) {
    // Databasen svarte, og svaret var nei. Ingenting skrives: en avsender som
    // ikke er den den utgir seg for, skal ikke etterlate seg noe.
    return nothing()
  }

  // Data API-et svarte ikke. Dette er den ene grenen der reserven finnes — og
  // den eneste der autentiseringstjenesten må spørres, siden databasen ikke
  // fikk sagt noe om hvem dette er. En utenforstående kan ikke utløse den:
  // den krever at Data API-et faktisk er nede.
  if (!withinAttemptBudget(ipHash)) {
    return nothing()
  }

  const verdict = await verify(target)
  if (verdict === 'rejected') {
    return nothing()
  }
  if (verdict !== 'verified') {
    // Ingen kunne bekrefte avsenderen. Da skal ingen tekst skrives ned, og
    // nettleseren beholder årsaken til den kan bekreftes senere.
    journal({ ...line, reporter: 'ukjent', detail: NO_UNVERIFIED_TEXT, bareILoggen: true })
    return new Response(null, { status: 503 })
  }

  // Avsenderen er kontrollert. Linjen går før kallet videre: blir prosessen
  // revet ned der, er årsaken likevel skrevet ned et sted som overlever at
  // fanen lukkes.
  journal(line)

  if (store !== null) {
    const kept = await store.keep({
      reporterIpHash: ipHash,
      eventId: envelope.eventId,
      area: envelope.area,
      kind: envelope.kind,
      operation: envelope.operation,
      code: envelope.code,
      httpStatus: envelope.httpStatus,
      transport: envelope.transport,
      detail,
    })
    if (kept) {
      return nothing()
    }
  }

  // Ingen rad noe sted. Loggen er nå det eneste stedet observasjonen finnes, og
  // den linjen sier det, slik at den som leter, vet hvor den må lete.
  // Nettleseren får samtidig beskjed om å beholde den.
  journal({ ...line, bareILoggen: true })
  return new Response(null, { status: 503 })
}

/**
 * Den uinnloggede besøkendes melding: maskinidentifikatorer, og ikke ett tegn
 * av kallerens egen tekst.
 *
 * `envelope.detail` leses ikke her i det hele tatt. Det er med vilje den
 * sterkeste formen: ikke «teksten filtreres», men «teksten finnes ikke på denne
 * veien», uansett hva kalleren la ved.
 */
async function servePublic(
  envelope: {
    eventId: string
    area: string
    kind: string
    operation: string | null
    code: string | null
    httpStatus: number | null
    transport: string
  },
  ipHash: string | null,
  journal: DiagnosticsJournal,
  store: DiagnosticsStore | null,
): Promise<Response> {
  if (!PUBLIC_TECHNICAL_AREAS.some((area) => area === envelope.area)) {
    // En anonym melding om en flate som bare finnes bak innlogging, beskriver
    // noe avsenderen ikke kan ha sett. Svaret skiller seg likevel ikke ut:
    // ruten er ikke et sted å kartlegge noe fra.
    return nothing()
  }

  if (ipHash === null) {
    // Ingen adresse serveren kan stole på, altså ingen avsender å telle. Da
    // skrives ingenting: en vei uten grense er ingen vei.
    return nothing()
  }

  const line: JournalLine = {
    event: envelope.eventId,
    reporter: 'anonym',
    area: envelope.area,
    kind: envelope.kind,
    operation: envelope.operation,
    code: envelope.code,
    httpStatus: envelope.httpStatus,
    transport: envelope.transport,
    detail: NO_PUBLIC_TEXT,
  }
  journal(line)

  const meldt =
    store !== null &&
    (await store.keepPublicProblem({
      reporterIpHash: ipHash,
      area: envelope.area,
      kind: envelope.kind,
      operation: envelope.operation,
      code: envelope.code,
      httpStatus: envelope.httpStatus,
      transport: envelope.transport,
    }))

  if (!meldt) {
    // Ikke meldt. Et 204 her ville fått nettleseren til å slette observasjonen
    // fordi den trodde den var kommet fram — den samme stille tapsmåten
    // utboksen finnes for å fjerne, bare på den offentlige flaten. Veien er
    // idempotent, så et nytt forsøk koster ingenting.
    journal({ ...line, bareILoggen: true })
    return new Response(null, { status: 503 })
  }

  return nothing()
}
