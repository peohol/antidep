// ============================================================================
// Skriver agentlegitimasjonen inn i en miljøfil
//
//   ANTIDEP_AGENT_IDENTITY_KEY=… ANTIDEP_AGENT_SECRET=… \
//     node src/agents/write-agent-env-cli.ts .env.agent.local
//
//   ANTIDEP_CLAIM_AGENT_IDENTITY_KEY=… ANTIDEP_CLAIM_AGENT_SECRET=… \
//     node src/agents/write-agent-env-cli.ts --prefix ANTIDEP_CLAIM_AGENT .env.agent.local
//
// Prefikset finnes fordi hvert agentledd har sin egen rolle, sin egen identitet
// og sin egen legitimasjon (migrasjon 005e): to ledd som kjører i samme miljø
// trenger to hemmeligheter samtidig, og de kan ikke dele ett variabelnavn.
//
// Kalles av `scripts/issue-agent-credential.sh --write-env`, og finnes som en
// egen fil av samme grunn som `verify-extraction-cli.ts`: skallet skal ikke
// bære logikk som fortjener en test.
//
// **Verdiene leses fra miljøet, ikke fra argumentlisten.** Argumentene til en
// prosess er lesbare for alle på maskinen gjennom `ps`, og en hemmelighet som
// står der, er ikke lenger en hemmelighet.
//
// Filen importeres aldri av appen og havner derfor ikke i klientbunten.
// ============================================================================

import { EnvFileRefused, writeAgentEnvFile } from './agent-env-file.ts'

const USAGE = `Bruk:
  <PREFIKS>_IDENTITY_KEY=… <PREFIKS>_SECRET=… \\
    node src/agents/write-agent-env-cli.ts [--prefix <PREFIKS>] <miljøfil>

Skriver de to variablene inn i miljøfilen, og lar alt annet i den stå. Filen må
være ignorert av git, og ender som 0600. Prefikset er ANTIDEP_AGENT uten
--prefix.`

const DEFAULT_PREFIX = 'ANTIDEP_AGENT'

interface CliOptions {
  readonly file: string | undefined
  readonly prefix: string
  readonly help: boolean
}

/** Leser argumentlisten. Eksportert fordi den fortjener en test. */
export function parseCliArguments(argv: readonly string[]): CliOptions {
  let file: string | undefined
  let prefix = DEFAULT_PREFIX
  let help = false

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--help' || argument === '-h') {
      help = true
    } else if (argument === '--prefix') {
      const value = argv[index + 1]
      // Prefikset settes inn i et variabelnavn, og et navn med skilletegn i seg
      // ville gitt en linje ingen `.env`-leser tolker som den ser ut.
      if (value === undefined || !/^[A-Z][A-Z0-9_]*$/.test(value)) {
        throw new Error('--prefix krever et variabelnavn med store bokstaver, tall og understrek.')
      }
      prefix = value
      index += 1
    } else if (argument !== undefined && !argument.startsWith('--')) {
      file = argument
    } else {
      throw new Error(`Ukjent valg: ${String(argument)}`)
    }
  }

  return { file, prefix, help }
}

function main(argv: readonly string[]): number {
  let options: CliOptions
  try {
    options = parseCliArguments(argv)
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    console.error(USAGE)
    return 2
  }

  const { file, prefix } = options
  if (file === undefined || options.help) {
    console.log(USAGE)
    return file === undefined ? 2 : 0
  }

  const identityName = `${prefix}_IDENTITY_KEY`
  const secretName = `${prefix}_SECRET`
  const identityKey = process.env[identityName]
  const secret = process.env[secretName]

  if (!identityKey || !secret) {
    console.error(`Mangler ${identityName} eller ${secretName} i miljøet. Ingenting er skrevet.`)
    return 2
  }

  try {
    writeAgentEnvFile(file, { [identityName]: identityKey, [secretName]: secret })
  } catch (error) {
    // Meldingen fra `EnvFileRefused` sier hva som er galt uten å gjengi
    // verdien. Alt annet kan i prinsippet bære med seg det som ble skrevet, og
    // gjengis derfor bare som type og ikke som innhold.
    console.error(
      error instanceof EnvFileRefused
        ? error.message
        : `Skrivingen feilet (${error instanceof Error ? error.name : 'ukjent feil'}). Ingenting er skrevet.`,
    )
    return 1
  }

  return 0
}

process.exitCode = main(process.argv.slice(2))
