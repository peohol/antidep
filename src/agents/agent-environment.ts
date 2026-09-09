// ============================================================================
// Miljøet agentkjøreren leser
//
// Fire variabler, ingen av dem med `VITE_`-prefiks. Det er ikke kosmetikk: Vite
// eksponerer nøyaktig de variablene som har det prefikset til nettleseren, så et
// prefiks her ville lagt agentens hemmelighet inn i klientbunten
// (`.env.example` sier det samme, og `src/lib/supabase.ts` bygger på det).
//
//   ANTIDEP_SUPABASE_URL                    prosjektets API-URL
//   ANTIDEP_SUPABASE_PUBLISHABLE_KEY        publishable key — ikke en secret key
//   ANTIDEP_AGENT_IDENTITY_KEY              ekstraksjonsverifikatorens nøkkel
//   ANTIDEP_AGENT_SECRET                    dens hemmelighet, utstedt av
//                                           provenance.issue_agent_identity_credential(text, text)
//   ANTIDEP_CLAIM_AGENT_IDENTITY_KEY        claim-verifikatorens nøkkel
//   ANTIDEP_CLAIM_AGENT_SECRET              dens hemmelighet, utstedt på samme måte
//   ANTIDEP_EXTRACTION_AGENT_IDENTITY_KEY   ekstraksjonsagentens nøkkel
//   ANTIDEP_EXTRACTION_AGENT_SECRET         dens hemmelighet, utstedt på samme måte
//
// ----------------------------------------------------------------------------
// Hvorfor legitimasjonen har mer enn ett variabelnavn
//
// Rollen er rettighetsgrensen, og hver rolle har sin egen aktør, sin egen
// identitet og sin egen legitimasjon (migrasjon 005e, EVIDENCE_PIPELINE.md §61).
// To pipelineledd som kjører i samme miljø — en runner, en CI-jobb — trenger
// derfor to hemmeligheter samtidig, og de kan ikke dele ett variabelnavn.
//
// URL-en og publishable key er derimot miljøets, ikke leddets, og er felles.
// Hvilket par av variabler et ledd leser, oppgis av kalleren framfor å utledes
// av en rolle her: da er sammenhengen mellom kjøreren og miljøet dens lesbar på
// ett sted, og et nytt ledd legger til ett par uten å røre denne filen.
//
// Publishable key og ikke service_role: agenten autentiseres av sin egen
// legitimasjon inne i api-funksjonene, ikke av Data API-rollen
// (DATABASE_ARCHITECTURE.md §49, migrasjon 005e). En service_role-nøkkel ville
// omgått RLS og gitt kjøreren alt — nøyaktig det agentidentiteten finnes for å
// unngå. Vakten fra `src/lib/supabase.ts` gjenbrukes framfor å skrives om, slik
// at regelen står ett sted.
// ============================================================================

import { assertPublishableKey } from '../lib/supabase.ts'
import { agentSecret, type AgentCredential } from './agent-credential.ts'

/** Miljøet slik en kjører leser det. `process.env` passer formen. */
export type AgentEnv = Readonly<Record<string, string | undefined>>

/** Navnene på de to variablene ett pipelineledd henter legitimasjonen sin fra. */
export interface AgentCredentialVariables {
  readonly identityKey: string
  readonly secret: string
}

/** Ekstraksjonsverifikatoren (migrasjon 005f). */
export const EXTRACTION_VERIFIER_CREDENTIAL: AgentCredentialVariables = {
  identityKey: 'ANTIDEP_AGENT_IDENTITY_KEY',
  secret: 'ANTIDEP_AGENT_SECRET',
}

/** Claim-verifikatoren (migrasjon 005i). */
export const CLAIM_VERIFIER_CREDENTIAL: AgentCredentialVariables = {
  identityKey: 'ANTIDEP_CLAIM_AGENT_IDENTITY_KEY',
  secret: 'ANTIDEP_CLAIM_AGENT_SECRET',
}

/**
 * Ekstraksjonsagenten (migrasjon 005w).
 *
 * Eget par og ikke verifikatorens: re-ekstraksjonen kjører begge leddene i den
 * samme prosessen — først ekstraksjonen, så den deterministiske kontrollen av
 * nettopp det funnet — og to roller som deler ett variabelnavn kan ikke det.
 * Skillet er dessuten rettighetsgrensen selv: identiteten autentiseres for
 * *rollen* sin, og en ekstraksjonsnøkkel kan ikke registrere en kontroll
 * (migrasjon 005e, EVIDENCE_PIPELINE.md §61).
 */
export const EVIDENCE_EXTRACTION_CREDENTIAL: AgentCredentialVariables = {
  identityKey: 'ANTIDEP_EXTRACTION_AGENT_IDENTITY_KEY',
  secret: 'ANTIDEP_EXTRACTION_AGENT_SECRET',
}

export interface AgentConfig {
  readonly url: string
  readonly publishableKey: string
  readonly credential: AgentCredential
}

const HELP =
  'Se supabase/README.md, avsnittet «Legitimasjon til agentidentiteten», for hvordan ' +
  'verdiene settes uten at hemmeligheten havner i repoet.'

function required(env: AgentEnv, name: string): string {
  const value = env[name]?.trim()
  if (value === undefined || value.length === 0) {
    throw new Error(`Miljøvariabelen ${name} mangler. ${HELP}`)
  }
  return value
}

/**
 * Leser og validerer miljøet. Feiler høyt og tidlig, av samme grunn som
 * `readSupabaseConfig`: en kjøring som starter med halv konfigurasjon ender i
 * en avvisning som ikke lar seg skille fra «feil legitimasjon», og de to skal
 * aldri se like ut.
 */
export function readAgentConfig(
  env: AgentEnv,
  credentialVariables: AgentCredentialVariables = EXTRACTION_VERIFIER_CREDENTIAL,
): AgentConfig {
  const url = required(env, 'ANTIDEP_SUPABASE_URL')
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    throw new Error(`ANTIDEP_SUPABASE_URL er ikke en gyldig URL: «${url}».`)
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
    throw new Error(`ANTIDEP_SUPABASE_URL må bruke http eller https, ikke «${parsed.protocol}».`)
  }

  const publishableKey = required(env, 'ANTIDEP_SUPABASE_PUBLISHABLE_KEY')
  assertPublishableKey(publishableKey)

  const identityKey = required(env, credentialVariables.identityKey)
  // Samme form som provenance.agent_identities.identity_key krever
  // (agent_identities_identity_key_format_check). Kontrollen er her for at en
  // skrivefeil skal si hva som er galt, framfor å bli til den anonyme
  // «kunne ikke autentiseres» hver mislykket autentisering gir.
  if (!/^[a-z0-9]+(?:[-.][a-z0-9]+)*:[a-z0-9]+(?:[-.][a-z0-9]+)*$/.test(identityKey)) {
    throw new Error(
      `${credentialVariables.identityKey} «${identityKey}» har ikke formen «type:navn», ` +
        'for eksempel agent-identity:extraction-verification-01.',
    )
  }

  return {
    url,
    publishableKey,
    credential: { identityKey, secret: agentSecret(required(env, credentialVariables.secret)) },
  }
}
