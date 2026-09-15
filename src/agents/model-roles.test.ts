import { readFile } from 'node:fs/promises'
import { describe, expect, it } from 'vitest'

import {
  ASSIGNED_AGENT_ROLES,
  hasModelAssignment,
  modelIdentityForRole,
  premisesForRole,
  rolesSharingModelIdentity,
} from './model-roles.ts'

const MIGRATION = 'supabase/migrations/20260926093000_role_model_separation.sql'

describe('premisesForRole', () => {
  it('gir hver rolle sine egne premisser', () => {
    expect(premisesForRole('evidence_extraction').model).toBe('proposal-grounded-extraction')
    expect(premisesForRole('citation_support_verification').model).toBe('deterministic-claim-check')
  })

  it('avviser en rolle uten tildeling framfor å gjette', () => {
    // `adversarial_review` er en rolle i vokabularet uten skrivevei. Databasen
    // ville uansett avvist kjøringen; her sies det med rollens navn.
    expect(() => premisesForRole('adversarial_review')).toThrow(/adversarial_review/)
    expect(hasModelAssignment('adversarial_review')).toBe(false)
  })
})

describe('separasjonen', () => {
  it('lar ingen to roller dele modellidentitet', () => {
    expect(rolesSharingModelIdentity()).toEqual([])
  })

  it('holder generatoren og kontrollen fra hverandre i hvert par', () => {
    // ANTIDEP_CONSTITUTION.md regel 3: egenverifikasjon er forbudt. Paret som
    // betyr mest, er det som lager og det som kontrollerer det samme.
    const pairs: readonly (readonly [string, string])[] = [
      ['evidence_extraction', 'extraction_verification'],
      ['claim_synthesis', 'citation_support_verification'],
      ['claim_synthesis', 'evidence_assessment'],
      ['citation_support_verification', 'evidence_assessment'],
    ]
    for (const [generator, checker] of pairs) {
      expect(modelIdentityForRole(generator)).not.toEqual(modelIdentityForRole(checker))
    }
  })
})

// ----------------------------------------------------------------------------
// Speilet mot fasiten
//
// Migrasjon 009c er registeret. Blir de to uenige, avviser databasen kjøringen
// med en SQLSTATE; denne prøven sier det med navn før det skjer.
// ----------------------------------------------------------------------------
describe('registeret er det samme som databasens', () => {
  it('dekker nøyaktig de rollene migrasjonen tildeler en modell', async () => {
    const sql = await readFile(MIGRATION, 'utf8')
    const assigned = [...sql.matchAll(/^ {2}\('([a-z_]+)', 'antidep', '([^']+)', '([^']+)',$/gm)]
    expect(assigned).toHaveLength(ASSIGNED_AGENT_ROLES.length)

    const fromSql = new Map(assigned.map((match) => [match[1] ?? '', match]))
    expect([...fromSql.keys()].sort()).toEqual([...ASSIGNED_AGENT_ROLES].sort())

    for (const role of ASSIGNED_AGENT_ROLES) {
      const match = fromSql.get(role)
      const identity = modelIdentityForRole(role)
      expect(identity.provider).toBe('antidep')
      expect(match?.[2]).toBe(identity.model)
      expect(match?.[3]).toBe(identity.modelVersion)
    }
  })
})
