// ============================================================================
// Prosessens halvdel av «modell-leddet har ingen legitimasjon»
//
// `drafting-no-write-path.test.ts` prøver koden: ingen import når fram til noe
// som kan skrive. Denne prøver prosessen: en kjører startet i et skall der en
// agenthemmelighet er eksportert, har hemmeligheten i miljøet sitt uansett hva
// koden gjør med den (EVIDENCE_PIPELINE.md §63).
//
// Den viktigste påstanden står nederst: hver legitimasjon som faktisk finnes i
// `agent-environment.ts`, treffes av vakten. Uten den ville et nytt agentledd
// kunnet få en hemmelighet vakten ikke kjente, og vakten ville sett like grønn
// ut som før.
// ============================================================================

import { describe, expect, it } from 'vitest'

import {
  CLAIM_VERIFIER_CREDENTIAL,
  EVIDENCE_EXTRACTION_CREDENTIAL,
  EXTRACTION_VERIFIER_CREDENTIAL,
} from './agent-environment'
import { agentSecretsInEnvironment, assertNoAgentCredentials } from './model-step-guard'

describe('agentSecretsInEnvironment', () => {
  it('finner ingenting i et miljø uten legitimasjon', () => {
    expect(agentSecretsInEnvironment({ PATH: '/usr/bin', HOME: '/home/x' })).toEqual([])
  })

  it('lar det som ikke er en hemmelighet, være i fred', () => {
    expect(
      agentSecretsInEnvironment({
        ANTIDEP_SUPABASE_URL: 'https://eksempel.invalid',
        ANTIDEP_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_x',
        ANTIDEP_AGENT_IDENTITY_KEY: 'agent:evidence-extraction',
      }),
    ).toEqual([])
  })

  it('regner en tom variabel som fraværende, framfor å stoppe en kjøring på ingenting', () => {
    expect(agentSecretsInEnvironment({ ANTIDEP_AGENT_SECRET: '   ' })).toEqual([])
  })

  it('finner hver hemmelighet som faktisk står der, i sortert rekkefølge', () => {
    expect(
      agentSecretsInEnvironment({
        ANTIDEP_EXTRACTION_AGENT_SECRET: 'x',
        ANTIDEP_AGENT_SECRET: 'y',
      }),
    ).toEqual(['ANTIDEP_AGENT_SECRET', 'ANTIDEP_EXTRACTION_AGENT_SECRET'])
  })
})

describe('assertNoAgentCredentials', () => {
  it('slipper gjennom et miljø uten agenthemmeligheter', () => {
    expect(() => {
      assertNoAgentCredentials({ PATH: '/usr/bin' }, 'npm run agent:draft-extraction')
    }).not.toThrow()
  })

  it('stopper kjøringen, og sier hvilken kommando som løser det', () => {
    let message = ''
    try {
      assertNoAgentCredentials(
        { ANTIDEP_EXTRACTION_AGENT_SECRET: 'aldri-i-en-melding-42' },
        'npm run agent:draft-extraction -- --assignment <fil> --open',
      )
    } catch (cause) {
      message = cause instanceof Error ? cause.message : String(cause)
    }

    expect(message).toContain('ANTIDEP_EXTRACTION_AGENT_SECRET')
    expect(message).toContain(
      'env -u ANTIDEP_EXTRACTION_AGENT_SECRET npm run agent:draft-extraction',
    )
    // Selve verdien skal aldri stå i en feilmelding.
    expect(message).not.toContain('aldri-i-en-melding-42')
  })
})

describe('vakten kjenner hver legitimasjon som finnes', () => {
  // Navnene bor i `agent-environment.ts`, som modell-leddet ikke kan importere.
  // Denne testen er broen mellom de to: originalen holder mønsteret i sjakk.
  const credentials = [
    EXTRACTION_VERIFIER_CREDENTIAL,
    CLAIM_VERIFIER_CREDENTIAL,
    EVIDENCE_EXTRACTION_CREDENTIAL,
  ]

  for (const credential of credentials) {
    it(`${credential.secret} treffes av mønsteret`, () => {
      expect(agentSecretsInEnvironment({ [credential.secret]: 'x' })).toEqual([credential.secret])
    })

    it(`${credential.identityKey} stopper ingen kjøring: en nøkkel er ikke en hemmelighet`, () => {
      expect(agentSecretsInEnvironment({ [credential.identityKey]: 'x' })).toEqual([])
    })
  }
})
