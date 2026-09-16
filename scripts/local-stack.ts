// ============================================================================
// Det to integrasjonsprøver deler: adressen, en psql-linje, et brukertoken og
// én linje om hva som gikk bra
//
// `agent-chain-test.ts` har hatt dette for seg selv siden den var den eneste
// prøven som snakket med en ekte stack. Det er den ikke lenger: den autonome
// kjøreren prøves ende-til-ende i `agent-runner-e2e.ts`, mot den samme lokale
// stacken og med den samme legitimasjonen.
//
// To kopier ville kunnet drive fra hverandre om hvilken database de traff, og
// den ene som pekte feil, ville vært stille grønn.
//
// Ingenting her hører hjemme i produksjonskode: dette er verktøyet en lokal
// integrasjonsprøve trenger for å snakke med en lokal stack.
// ============================================================================

import { execFileSync } from 'node:child_process'
import { createHmac } from 'node:crypto'

export interface LocalStackConfig {
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

export function localAnonKey(): string {
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

export function readLocalStackConfig(argv: readonly string[]): LocalStackConfig {
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

/** Én SQL-verdi, sitert. Prøvedata, og aldri en verdi fra en modell. */
export function q(value: string): string {
  return `'${value.replace(/'/g, "''")}'`
}

/** Én linje ut av psql, uten kommandomerker og uten tomme linjer. */
export function psql(config: LocalStackConfig, sql: string): string {
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

/** Et innlogget menneske, signert med den lokale stackens egen nøkkel. */
export function userToken(config: LocalStackConfig, userId: string): string {
  const b64 = (value: object): string => Buffer.from(JSON.stringify(value)).toString('base64url')
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

/** Én linje om hva som gikk bra, eller hva som ikke gjorde det. */
export function check(name: string, condition: boolean, detail = ''): void {
  if (condition) {
    console.log(`  ok   ${name}`)
    return
  }
  console.error(`  FEIL ${name}${detail === '' ? '' : `: ${detail}`}`)
  process.exitCode = 1
}
