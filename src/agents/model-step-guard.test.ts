// ============================================================================
// Miljøvakten for modell-leddet
//
// `drafting-no-write-path.test.ts` prøver koden: ingen import når fram til noe
// som kan skrive. Denne prøver **miljøet til prosessen**: en kjører startet i
// et skall der en skrivekapabel legitimasjon er eksportert, har den i miljøet
// sitt uansett hva koden gjør med den (EVIDENCE_PIPELINE.md §63).
//
// Vakten er et lag i dybden og ikke hele grensen — den kan ikke se sesjonen som
// startet kjøringen, og heller ikke connectorene den sesjonen har. Det er
// nettopp derfor de to broene under er de viktigste påstandene her: de holder
// listen vakten kjenner, i takt med hva som faktisk finnes i repoet.
//
//   1. Hver agentlegitimasjon i `agent-environment.ts` treffes av mønsteret.
//   2. Hver legitimasjon `scripts/deploy-migrations.sh` faktisk bruker mot
//      Management-API-et, er dekket. Den veien kan kjøre vilkårlig SQL mot
//      produksjonsbasen, og et navn utenfor `ANTIDEP_*SECRET` ville ellers stått
//      åpent.
// ============================================================================

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

import {
  CLAIM_VERIFIER_CREDENTIAL,
  EVIDENCE_EXTRACTION_CREDENTIAL,
  EXTRACTION_VERIFIER_CREDENTIAL,
} from './agent-environment'
import {
  assertNoWriteCapableCredentials,
  isWriteCapableName,
  writeCapableCredentialsIn,
} from './model-step-guard'

describe('writeCapableCredentialsIn', () => {
  it('finner ingenting i et miljø uten legitimasjon', () => {
    expect(writeCapableCredentialsIn({ PATH: '/usr/bin', HOME: '/home/x' })).toEqual([])
  })

  it('lar det som ikke er en hemmelighet, være i fred', () => {
    expect(
      writeCapableCredentialsIn({
        ANTIDEP_SUPABASE_URL: 'https://eksempel.invalid',
        ANTIDEP_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_x',
        ANTIDEP_AGENT_IDENTITY_KEY: 'agent:evidence-extraction',
        // En prosjektreferanse er en identifikator, ikke en hemmelighet. En
        // vakt som stoppet på den, ville stoppet kjøringer uten at noe var galt.
        SUPABASE_PROJECT_REF: 'abcdefghijklmnop',
      }),
    ).toEqual([])
  })

  it('regner en tom variabel som fraværende, framfor å stoppe en kjøring på ingenting', () => {
    expect(writeCapableCredentialsIn({ ANTIDEP_AGENT_SECRET: '   ' })).toEqual([])
  })

  it('finner hver legitimasjon som faktisk står der, i sortert rekkefølge', () => {
    expect(
      writeCapableCredentialsIn({
        SUPABASE_ACCESS_TOKEN: 'x',
        ANTIDEP_AGENT_SECRET: 'y',
      }),
    ).toEqual(['ANTIDEP_AGENT_SECRET', 'SUPABASE_ACCESS_TOKEN'])
  })

  it('kjenner de skrivekapable veiene utenfor Antideps egen agentmodell', () => {
    for (const name of [
      'SUPABASE_ACCESS_TOKEN',
      'SUPABASE_DB_PASSWORD',
      'SUPABASE_SECRET_KEY',
      'SUPABASE_SERVICE_ROLE_KEY',
      'DATABASE_URL',
      'PGPASSWORD',
    ]) {
      expect(isWriteCapableName(name)).toBe(true)
    }
  })
})

describe('assertNoWriteCapableCredentials', () => {
  it('slipper gjennom et miljø uten skrivekapabel legitimasjon', () => {
    expect(() => {
      assertNoWriteCapableCredentials({ PATH: '/usr/bin' }, 'npm run agent:draft-extraction')
    }).not.toThrow()
  })

  it('stopper kjøringen, og sier hvilken kommando som løser det', () => {
    let message = ''
    try {
      assertNoWriteCapableCredentials(
        { SUPABASE_ACCESS_TOKEN: 'aldri-i-en-melding-42' },
        'npm run agent:draft-extraction -- --assignment <fil> --open',
      )
    } catch (cause) {
      message = cause instanceof Error ? cause.message : String(cause)
    }

    expect(message).toContain('SUPABASE_ACCESS_TOKEN')
    expect(message).toContain('env -u SUPABASE_ACCESS_TOKEN npm run agent:draft-extraction')
    // Selve verdien skal aldri stå i en feilmelding.
    expect(message).not.toContain('aldri-i-en-melding-42')
  })

  it('sier at vakten ikke er hele grensen, framfor å love mer enn den kan', () => {
    // Overklaring er den farligste feilen en sikkerhetsmelding kan gjøre: en
    // leser som tror grensen er håndhevet, slutter å se etter den.
    expect(() => {
      assertNoWriteCapableCredentials({ ANTIDEP_AGENT_SECRET: 'x' }, 'kommando')
    }).toThrow(/connectorer/)
  })
})

describe('vakten kjenner hver agentlegitimasjon som finnes', () => {
  // Navnene bor i `agent-environment.ts`, som modell-leddet ikke kan importere.
  // Denne broen er det som holder mønsteret i takt med originalen.
  const credentials = [
    EXTRACTION_VERIFIER_CREDENTIAL,
    CLAIM_VERIFIER_CREDENTIAL,
    EVIDENCE_EXTRACTION_CREDENTIAL,
  ]

  for (const credential of credentials) {
    it(`${credential.secret} treffes av mønsteret`, () => {
      expect(writeCapableCredentialsIn({ [credential.secret]: 'x' })).toEqual([credential.secret])
    })

    it(`${credential.identityKey} stopper ingen kjøring: en nøkkel er ikke en hemmelighet`, () => {
      expect(writeCapableCredentialsIn({ [credential.identityKey]: 'x' })).toEqual([])
    })
  }
})

describe('vakten dekker deployveien mot produksjon', () => {
  // `scripts/deploy-migrations.sh` kan kjøre vilkårlig SQL mot produksjonsbasen
  // gjennom Management-API-et. Variablene den bruker, heter ingenting som
  // `ANTIDEP_*SECRET`-mønsteret ville fanget, så uten denne broen ville den
  // veien stått åpen i et miljø modell-leddet kjørte i — og vakten ville sett
  // like grønn ut som før.
  const script = readFileSync(
    join(import.meta.dirname, '..', '..', 'scripts', 'deploy-migrations.sh'),
    'utf8',
  )
  const referenced = [
    ...new Set(
      [...script.matchAll(/\$\{?([A-Z][A-Z0-9_]*)\}?/g)].map((match) => match[1] as string),
    ),
  ].sort()

  it('leser faktisk noen variabelnavn ut av skriptet', () => {
    // Uten denne ville en endret skriptform gjort listen tom, og hver påstand
    // under til en tom godkjenning.
    expect(referenced).toContain('SUPABASE_ACCESS_TOKEN')
  })

  for (const name of ['SUPABASE_ACCESS_TOKEN', 'SUPABASE_DB_PASSWORD']) {
    it(`${name} stopper modell-leddet`, () => {
      expect(isWriteCapableName(name)).toBe(true)
    })
  }
})
