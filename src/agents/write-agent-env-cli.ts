// ============================================================================
// Skriver agentlegitimasjonen inn i en miljøfil
//
//   ANTIDEP_AGENT_IDENTITY_KEY=… ANTIDEP_AGENT_SECRET=… \
//     node src/agents/write-agent-env-cli.ts .env.agent.local
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
  ANTIDEP_AGENT_IDENTITY_KEY=… ANTIDEP_AGENT_SECRET=… \\
    node src/agents/write-agent-env-cli.ts <miljøfil>

Skriver de to variablene inn i miljøfilen, og lar alt annet i den stå. Filen må
være ignorert av git, og ender som 0600.`

function main(argv: readonly string[]): number {
  const [file] = argv

  if (file === undefined || file === '--help' || file === '-h') {
    console.log(USAGE)
    return file === undefined ? 2 : 0
  }

  const identityKey = process.env.ANTIDEP_AGENT_IDENTITY_KEY
  const secret = process.env.ANTIDEP_AGENT_SECRET

  if (!identityKey || !secret) {
    console.error(
      'Mangler ANTIDEP_AGENT_IDENTITY_KEY eller ANTIDEP_AGENT_SECRET i miljøet. Ingenting er skrevet.',
    )
    return 2
  }

  try {
    writeAgentEnvFile(file, {
      ANTIDEP_AGENT_IDENTITY_KEY: identityKey,
      ANTIDEP_AGENT_SECRET: secret,
    })
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
