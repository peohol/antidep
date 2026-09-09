import { describe, expect, it } from 'vitest'

import { agentSecret, redact } from './agent-credential'
import {
  EVIDENCE_EXTRACTION_CREDENTIAL,
  EXTRACTION_VERIFIER_CREDENTIAL,
  readAgentConfig,
  type AgentEnv,
} from './agent-environment'

const VALID: AgentEnv = {
  ANTIDEP_SUPABASE_URL: 'https://prosjekt.supabase.co',
  ANTIDEP_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_testverdi',
  ANTIDEP_AGENT_IDENTITY_KEY: 'agent-identity:extraction-verification-01',
  ANTIDEP_AGENT_SECRET: 'en-hemmelighet',
}

describe('readAgentConfig', () => {
  it('leser en fullstendig konfigurasjon', () => {
    const config = readAgentConfig(VALID)
    expect(config.url).toBe('https://prosjekt.supabase.co')
    expect(config.credential.identityKey).toBe('agent-identity:extraction-verification-01')
    expect(config.credential.secret.reveal()).toBe('en-hemmelighet')
  })

  it.each([
    'ANTIDEP_SUPABASE_URL',
    'ANTIDEP_SUPABASE_PUBLISHABLE_KEY',
    'ANTIDEP_AGENT_IDENTITY_KEY',
    'ANTIDEP_AGENT_SECRET',
  ] as const)('feiler høyt når %s mangler', (name) => {
    expect(() => readAgentConfig({ ...VALID, [name]: undefined })).toThrow(name)
  })

  it('avviser en secret key', () => {
    // DATABASE_ARCHITECTURE.md §49: service_role omgår RLS, og en agent som
    // hadde den, ville hatt alt agentidentiteten finnes for å unngå. Vakten er
    // den samme som nettleserklienten bruker, ikke en kopi.
    expect(() =>
      readAgentConfig({ ...VALID, ANTIDEP_SUPABASE_PUBLISHABLE_KEY: 'sb_secret_noe' }),
    ).toThrow(/secret key/)
  })

  it('avviser en identitetsnøkkel med feil form', () => {
    expect(() =>
      readAgentConfig({ ...VALID, ANTIDEP_AGENT_IDENTITY_KEY: 'Extraction Verifier' }),
    ).toThrow(/type:navn/)
  })

  it('avviser en url som ikke kan nås over http', () => {
    expect(() => readAgentConfig({ ...VALID, ANTIDEP_SUPABASE_URL: 'ftp://noe' })).toThrow(/ftp:/)
  })

  // Rollen er rettighetsgrensen, og hvert ledd har sin egen identitet og sin
  // egen hemmelighet (migrasjon 005e). Re-ekstraksjonen leser begge parene i
  // den samme prosessen, og to roller som delte ett variabelnavn kunne ikke det.
  it('leser ekstraksjonsagentens eget variabelpar', () => {
    const env: AgentEnv = {
      ...VALID,
      ANTIDEP_EXTRACTION_AGENT_IDENTITY_KEY: 'agent-identity:evidence-extraction-01',
      ANTIDEP_EXTRACTION_AGENT_SECRET: 'en-annen-hemmelighet',
    }
    const extraction = readAgentConfig(env, EVIDENCE_EXTRACTION_CREDENTIAL)
    const verification = readAgentConfig(env, EXTRACTION_VERIFIER_CREDENTIAL)

    expect(extraction.credential.identityKey).toBe('agent-identity:evidence-extraction-01')
    expect(extraction.credential.secret.reveal()).toBe('en-annen-hemmelighet')
    expect(verification.credential.identityKey).toBe('agent-identity:extraction-verification-01')
    expect(verification.credential.secret.reveal()).toBe('en-hemmelighet')
  })

  it('feiler høyt når ekstraksjonsagentens hemmelighet mangler', () => {
    expect(() =>
      readAgentConfig(
        {
          ...VALID,
          ANTIDEP_EXTRACTION_AGENT_IDENTITY_KEY: 'agent-identity:evidence-extraction-01',
        },
        EVIDENCE_EXTRACTION_CREDENTIAL,
      ),
    ).toThrow('ANTIDEP_EXTRACTION_AGENT_SECRET')
  })
})

describe('AgentSecret', () => {
  it('lekker ikke ved logging', () => {
    const secret = agentSecret('hemmelig-verdi')
    expect(String(secret)).not.toContain('hemmelig-verdi')
    expect(`${secret}`).toBe('[hemmelighet skjult]')
  })

  it('lekker ikke gjennom JSON', () => {
    const secret = agentSecret('hemmelig-verdi')
    expect(JSON.stringify({ secret })).not.toContain('hemmelig-verdi')
  })

  it('gir verdien bare til den som ber om den eksplisitt', () => {
    expect(agentSecret('hemmelig-verdi').reveal()).toBe('hemmelig-verdi')
  })
})

describe('redact', () => {
  it('fjerner hemmeligheten fra en feilmelding', () => {
    const secret = agentSecret('hemmelig-verdi')
    expect(redact('kall feilet med p_secret=hemmelig-verdi', secret)).toBe(
      'kall feilet med p_secret=[hemmelighet skjult]',
    )
  })

  it('fjerner hvert forekomst, ikke bare den første', () => {
    const secret = agentSecret('abc')
    expect(redact('abc og abc', secret)).toBe('[hemmelighet skjult] og [hemmelighet skjult]')
  })

  it('lar teksten stå når hemmeligheten er tom', () => {
    expect(redact('ingenting å skjule', agentSecret(''))).toBe('ingenting å skjule')
  })
})
