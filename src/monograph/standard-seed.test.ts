// ============================================================================
// Kontrollen som holder migrasjonen og kontrakten fra å drive fra hverandre
//
// Migrasjon 013a bærer 80 malrader og 13 profilrader. De er ikke skrevet av for
// hånd: de er teksten `monographStandardSeedSql()` bygger av `standard.ts`.
// Denne prøven bygger den på nytt og krever at migrasjonsfilen inneholder den
// ordrett.
//
// Migrasjonen er historikk og endres ikke. Prøven er derfor ikke en «husk å
// oppdatere»-påminnelse, men en kontroll av at den versjonen som *er* lagt inn,
// er den samme kontrakten flaten og agentoppgavene leser. Endres `standard.ts`
// uten en ny standardversjon og en ny migrasjon, stopper den her.
// ============================================================================

import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

import { monographStandardSeedSql } from './standard-seed.ts'
import { MONOGRAPH_STANDARD_VERSION, QUESTION_TEMPLATES, SOURCE_PROFILES } from './standard.ts'

const MIGRATION = 'supabase/migrations/20261003090000_monograph_standard_register.sql'

describe('seeden av monografistandarden', () => {
  const migration = readFileSync(MIGRATION, 'utf8')

  it('står ordrett i migrasjonen som la den inn', () => {
    expect(migration).toContain(monographStandardSeedSql())
  })

  it('ligger mellom markørene, slik at grensen er lesbar i filen', () => {
    const start = migration.indexOf('>>> BEGYNNELSEN PÅ DEN GENERERTE SEEDEN')
    const end = migration.indexOf('>>> SLUTTEN PÅ DEN GENERERTE SEEDEN')
    expect(start).toBeGreaterThan(-1)
    expect(end).toBeGreaterThan(start)
    const between = migration.slice(start, end)
    expect(between).toContain(monographStandardSeedSql())
  })

  it('legger inn nøyaktig den versjonen kontrakten uttrykker', () => {
    expect(migration).toContain(
      `'${MONOGRAPH_STANDARD_VERSION}',\n  'Antidep Monograph Standard v1'`,
    )
  })

  it('nevner hver mal og hver profil én gang i verdilisten', () => {
    const seed = monographStandardSeedSql()
    for (const template of QUESTION_TEMPLATES) {
      const occurrences = seed.split(`'${template.code}'`).length - 1
      // Én gang i malinnleggingen, og én gang per kildeprofil i koblingen.
      expect(occurrences, template.code).toBe(1 + template.sourceProfiles.length)
    }
    for (const profile of SOURCE_PROFILES) {
      expect(seed, profile.code).toContain(`'${profile.code}'`)
    }
  })

  it('dobler apostrofer framfor å avslutte en strengliteral', () => {
    // Standardens tekster inneholder « » og – , men ingen apostrof i dag. At
    // rømmingen finnes likevel, er poenget: den neste teksten kan ha en, og en
    // seed som brøt ut av literalen ville vært en migrasjon som ikke kjørte.
    const escaped = monographStandardSeedSql()
    const oddQuotes = escaped.split('\n').filter((line) => (line.split("'").length - 1) % 2 === 1)
    expect(oddQuotes).toEqual([])
  })
})
