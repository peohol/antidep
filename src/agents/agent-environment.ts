// ============================================================================
// Miljøet agentkjøreren leser
//
// Fire variabler, ingen av dem med `VITE_`-prefiks. Det er ikke kosmetikk: Vite
// eksponerer nøyaktig de variablene som har det prefikset til nettleseren, så et
// prefiks her ville lagt agentens hemmelighet inn i klientbunten
// (`.env.example` sier det samme, og `src/lib/supabase.ts` bygger på det).
//
//   ANTIDEP_SUPABASE_URL              prosjektets API-URL
//   ANTIDEP_SUPABASE_PUBLISHABLE_KEY  publishable key — ikke en secret key
//   ANTIDEP_AGENT_IDENTITY_KEY        identitetsnøkkelen, ikke hemmelig
//   ANTIDEP_AGENT_SECRET              hemmeligheten, utstedt av
//                                     provenance.issue_agent_identity_credential(text, text)
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

export interface AgentEnv {
  readonly ANTIDEP_SUPABASE_URL?: string | undefined
  readonly ANTIDEP_SUPABASE_PUBLISHABLE_KEY?: string | undefined
  readonly ANTIDEP_AGENT_IDENTITY_KEY?: string | undefined
  readonly ANTIDEP_AGENT_SECRET?: string | undefined
}

export interface AgentConfig {
  readonly url: string
  readonly publishableKey: string
  readonly credential: AgentCredential
}

const HELP =
  'Se supabase/README.md, avsnittet «Legitimasjon til agentidentiteten», for hvordan ' +
  'verdiene settes uten at hemmeligheten havner i repoet.'

function required(env: AgentEnv, name: keyof AgentEnv): string {
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
export function readAgentConfig(env: AgentEnv): AgentConfig {
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

  const identityKey = required(env, 'ANTIDEP_AGENT_IDENTITY_KEY')
  // Samme form som provenance.agent_identities.identity_key krever
  // (agent_identities_identity_key_format_check). Kontrollen er her for at en
  // skrivefeil skal si hva som er galt, framfor å bli til den anonyme
  // «kunne ikke autentiseres» hver mislykket autentisering gir.
  if (!/^[a-z0-9]+(?:[-.][a-z0-9]+)*:[a-z0-9]+(?:[-.][a-z0-9]+)*$/.test(identityKey)) {
    throw new Error(
      `ANTIDEP_AGENT_IDENTITY_KEY «${identityKey}» har ikke formen «type:navn», ` +
        'for eksempel agent-identity:extraction-verification-01.',
    )
  }

  return {
    url,
    publishableKey,
    credential: { identityKey, secret: agentSecret(required(env, 'ANTIDEP_AGENT_SECRET')) },
  }
}
