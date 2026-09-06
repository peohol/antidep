// ============================================================================
// Å skrive agentlegitimasjonen inn i en miljøfil
//
// `scripts/issue-agent-credential.sh --write-env` finnes fordi stdout i noen
// miljøer er en logg som lagres — en CI-jobb, og like mye en agentsesjons
// transkripsjon. Hemmeligheten går derfor rett fra utstedelsen og inn i en fil,
// uten å vises noe sted.
//
// En fil er bare et trygt sted for en hemmelighet hvis to ting holder, og
// begge må håndheves her framfor å loves i en kommentar:
//
// ----------------------------------------------------------------------------
// 1. Filen skal være lesbar bare for eieren — også når den fantes fra før
//
// `fs.writeFileSync(fil, tekst, { mode: 0o600 })` setter **bare** modus når
// filen opprettes. Standardtilfellet her er nettopp at filen finnes fra før,
// med `ANTIDEP_SUPABASE_URL` og publishable key i seg, og da beholder den
// modusen den hadde. Er den `0644`, ville hemmeligheten blitt skrevet inn i en
// verdenslesbar fil — og løftet om `0600` ville vært usant uten at noe feilet.
//
// Skrivingen går derfor gjennom en tempfil som opprettes fersk, settes til
// `0600` med `fchmod` (som umask ikke kan utvide eller innskrenke), fylles, og
// først deretter flyttes på plass med `rename`. Rettighetene som gjelder til
// slutt, er tempfilens: `rename` erstatter målet i sin helhet. Da finnes det
// heller ikke noe øyeblikk der hemmeligheten ligger i en fil med for vide
// rettigheter, og heller ikke et der filen er halvskrevet.
//
// ----------------------------------------------------------------------------
// 2. Målfilen skal være ignorert av git
//
// Flagget tar imot en filbane, og en filbane kan peke hvor som helst — også på
// en sporet fil, som `.env.example`. Da ville neste `git add` tatt hemmeligheten
// med seg inn i historikken, og det er den ene feilen hele mekanismen finnes
// for å hindre.
//
// `git check-ignore` er derfor et vilkår og ikke en antakelse, og kontrollen
// feiler lukket: svarer ikke git — fordi det ikke er et arbeidstre, fordi
// kommandoen mangler, eller fordi filen ikke er ignorert — skrives ingenting.
// Å skrive en hemmelighet fordi kontrollen ikke lot seg utføre, er den motsatte
// avveiningen av den denne filen er til for.
// ============================================================================

import { execFileSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import {
  closeSync,
  existsSync,
  fchmodSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeSync,
} from 'node:fs'
import { basename, dirname, join } from 'node:path'

/** Skrivingen ble avvist før noe ble skrevet. */
export class EnvFileRefused extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'EnvFileRefused'
  }
}

/**
 * Sier om git faktisk ignorerer filen.
 *
 * Feiler lukket: enhver annen utgang enn «ja, ignorert» er `false`.
 * `git check-ignore` avslutter med 0 for en ignorert bane, 1 for en som ikke
 * er det, og 128 når den ikke kan svare i det hele tatt.
 */
export function gitIgnores(file: string): boolean {
  try {
    execFileSync('git', ['check-ignore', '--quiet', '--', file], { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

export interface WriteAgentEnvOptions {
  /** Byttes ut i test. Standard er den ekte git-kontrollen. */
  readonly ignores?: (file: string) => boolean
}

/**
 * Setter variablene i `values` i miljøfilen `file`, og lar alt annet i filen
 * stå. Filen ender som `0600`, uansett hva den var før.
 *
 * Kaster `EnvFileRefused` uten å skrive noe hvis filen ikke er gitignorert,
 * eller hvis en verdi ikke kan uttrykkes på én linje.
 */
export function writeAgentEnvFile(
  file: string,
  values: Readonly<Record<string, string>>,
  options: WriteAgentEnvOptions = {},
): void {
  const ignores = options.ignores ?? gitIgnores

  if (!ignores(file)) {
    throw new EnvFileRefused(
      `${file} er ikke ignorert av git. En hemmelighet skrives bare til en fil ` +
        'som ikke kan bli med i en commit. Ingenting er skrevet.',
    )
  }

  // En verdi med linjeskift ville delt seg i to linjer, og resten av
  // hemmeligheten ville blitt lest som et nytt variabelnavn.
  for (const [name, value] of Object.entries(values)) {
    if (/[\r\n]/.test(value)) {
      throw new EnvFileRefused(
        `Verdien for ${name} inneholder linjeskift og kan ikke skrives til en ` +
          'miljøfil. Ingenting er skrevet.',
      )
    }
  }

  const existing = existsSync(file) ? readFileSync(file, 'utf8').split('\n') : []
  const kept = existing.filter(
    (line) => !Object.keys(values).some((name) => line.startsWith(`${name}=`)),
  )
  while (kept.length > 0 && kept.at(-1)?.trim() === '') kept.pop()

  const lines = [...kept, ...Object.entries(values).map(([name, value]) => `${name}=${value}`)]
  writeOwnerOnly(file, lines.join('\n') + '\n')
}

/**
 * Skriver `content` til `file` slik at filen er `0600` også når den fantes fra
 * før: fersk tempfil ved siden av målet, `fchmod`, fyll, `rename` over målet.
 */
function writeOwnerOnly(file: string, content: string): void {
  const directory = dirname(file) || '.'
  const temporary = join(directory, `.${basename(file)}.${randomBytes(8).toString('hex')}.tmp`)

  // `wx` nekter å åpne en fil som allerede finnes, så tempfilen er alltid
  // vår egen — aldri en andre har lagt der på forhånd.
  const handle = openSync(temporary, 'wx', 0o600)
  try {
    // Eksplisitt, fordi modusen i `openSync` maskeres av umask.
    fchmodSync(handle, 0o600)
    writeSync(handle, content)
  } catch (error) {
    closeSync(handle)
    rmSync(temporary, { force: true })
    throw error
  }
  closeSync(handle)

  try {
    renameSync(temporary, file)
  } catch (error) {
    rmSync(temporary, { force: true })
    throw error
  }
}
