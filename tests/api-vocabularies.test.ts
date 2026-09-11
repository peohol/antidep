import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  describeClaimMagnitude,
  isWithinArmMeasure,
  type ClaimComparatorState,
} from '../src/lib/claim-effect'
import {
  CERTAINTY_LEVELS,
  CLAIM_DIRECTIONS,
  COMPARATOR_KINDS,
  DATE_PRECISIONS,
  DRUG_STATUSES,
  EFFECT_MEASURES,
  ESTIMATE_UNITS,
  EVIDENCE_CHECK_FIELDS,
  EVIDENCE_DIRECTNESS_VALUES,
  EVIDENCE_RELATIONSHIP_TYPES,
  EXTRACTION_METHODS,
  KNOWLEDGE_TYPES,
  REPORTED_DIRECTIONS,
  SOURCE_STATUSES,
  SOURCE_TYPES,
  STUDY_DESIGNS,
  VALUE_AVAILABILITIES,
  VOCABULARY_STATUSES,
  type EffectMeasure,
} from '../src/types/api'

// ============================================================================
// De lukkede vokabularene i src/types/api.ts er håndskrevne påstander om
// databasen. Ingenting har hittil kontrollert dem, og gjeldsposten står i
// MVP_IMPLEMENTATION_PLAN.md §74.7: en ny enum-verdi eller en omdøpt verdi
// gjør typen usann uten at noe feiler.
//
// Denne testen lukker vokabularhalvdelen av den gjelden. Den leser de
// versjonerte migrasjonene — samme framgangsmåte som
// tests/data-api-exposure.test.ts, og uten en kjørende database — og krever at
// hver union er nøyaktig enum-en den utgir seg for å være.
//
// Kilden vinner: slår kontrollen ut, er TypeScript-typen feil, ikke SQL-en.
//
// Kolonnenavn, nullbarhet og kolonnetyper er fortsatt ukontrollert. Den delen
// av gjeldsposten står.
// ============================================================================

const MIGRATIONS = 'supabase/migrations'

function migrationSql(): string {
  return readdirSync(MIGRATIONS)
    .filter((file) => file.endsWith('.sql'))
    .sort()
    .map((file) => readFileSync(join(MIGRATIONS, file), 'utf8'))
    .join('\n')
}

const SQL = migrationSql()

function quotedList(source: string): string[] {
  return source
    .split(',')
    .map((entry) => entry.trim().replace(/^'|'$/g, ''))
    .filter((entry) => entry.length > 0)
}

/**
 * Verdiene en enum har *etter at alle migrasjonene er kjørt*.
 *
 * `create type` alene er ikke nok. Utvider en senere migrasjon enumet med
 * `alter type … add value`, ville en kontroll som bare leste den opprinnelige
 * definisjonen fortsatt passert — mens databasen kan returnere en verdi
 * TypeScript-unionen ikke kjenner. Vaktposten ville sluttet å måle uten å
 * feile, som er nøyaktig feilmodusen den finnes for å unngå.
 *
 * Formene som forstås er `add value ['if not exists'] 'x' [before|after 'y']`
 * og `rename value 'a' to 'b'`. Alt annet kaster framfor å bli ignorert: en
 * DDL-form vi ikke har tenkt på skal stoppe testen, ikke gli forbi den.
 * (PostgreSQL kan ikke fjerne en enum-verdi, så det finnes ingen tredje form å
 * dekke i dag.)
 */
function enumValuesFrom(sql: string, qualifiedName: string): string[] {
  const name = qualifiedName.replace('.', '\\.')

  const created = new RegExp(`create type ${name} as enum\\s*\\(([^)]*)\\)`, 'i').exec(sql)
  if (created?.[1] === undefined) {
    throw new Error(`fant ingen enum-definisjon for ${qualifiedName} i ${MIGRATIONS}`)
  }
  const values = quotedList(created[1])

  // Endringene leses i filrekkefølge, altså i den rekkefølgen de faktisk kjøres.
  for (const alter of sql.matchAll(new RegExp(`alter type ${name}\\s+([^;]*);`, 'gi'))) {
    const body = (alter[1] ?? '').replace(/\s+/g, ' ').trim()

    const added = /^add value (?:if not exists )?'([^']*)'(?: (?:before|after) '[^']*')?$/i.exec(
      body,
    )
    if (added?.[1] !== undefined) {
      if (!values.includes(added[1])) {
        values.push(added[1])
      }
      continue
    }

    const renamed = /^rename value '([^']*)' to '([^']*)'$/i.exec(body)
    if (renamed?.[1] !== undefined && renamed[2] !== undefined) {
      const at = values.indexOf(renamed[1])
      if (at === -1) {
        throw new Error(
          `«alter type ${qualifiedName} rename value '${renamed[1]}'» viser til en verdi som ikke finnes`,
        )
      }
      values[at] = renamed[2]
      continue
    }

    throw new Error(
      `ukjent «alter type ${qualifiedName}»-form, som denne testen ikke kan tolke: ${body}`,
    )
  }

  return values
}

const enumValues = (qualifiedName: string): string[] => enumValuesFrom(SQL, qualifiedName)

describe('de lukkede vokabularene er nøyaktig enum-ene i migrasjonene', () => {
  it.each([
    ['knowledge.knowledge_type', KNOWLEDGE_TYPES],
    ['knowledge.certainty_level', CERTAINTY_LEVELS],
    ['knowledge.claim_direction', CLAIM_DIRECTIONS],
    ['knowledge.comparator_kind', COMPARATOR_KINDS],
    ['knowledge.effect_measure', EFFECT_MEASURES],
    ['knowledge.estimate_unit', ESTIMATE_UNITS],
    ['knowledge.claim_evidence_relationship', EVIDENCE_RELATIONSHIP_TYPES],
    ['knowledge.evidence_directness', EVIDENCE_DIRECTNESS_VALUES],
    ['knowledge.value_availability', VALUE_AVAILABILITIES],
    ['knowledge.effect_direction', REPORTED_DIRECTIONS],
    ['knowledge.study_design', STUDY_DESIGNS],
    ['knowledge.source_type', SOURCE_TYPES],
    ['knowledge.source_status', SOURCE_STATUSES],
    ['knowledge.date_precision', DATE_PRECISIONS],
    ['knowledge.extraction_method', EXTRACTION_METHODS],
    ['workflow.evidence_check_field', EVIDENCE_CHECK_FIELDS],
    ['catalog.drug_status', DRUG_STATUSES],
    ['catalog.vocabulary_status', VOCABULARY_STATUSES],
  ] as [string, readonly string[]][])('%s', (name, declared) => {
    // Som sett, ikke som liste: rekkefølgen i TypeScript er en presentasjons-
    // detalj, mens medlemskapet er påstanden om databasen.
    expect(new Set(declared)).toEqual(new Set(enumValues(name)))
  })

  it('kildens retningsvokabular er ikke påstandens', () => {
    // De to ser like ut og er det ikke: `knowledge.effect_direction` har den
    // fjerde verdien `not_stated`. Å behandle dem som samme vokabular ville
    // latt «kilden oppgir ingen retning» og «Antidep konkluderer med ingen klar
    // forskjell» bytte plass — to helt forskjellige epistemiske utsagn
    // (ANTIDEP_CONSTITUTION.md §5). Kontrollen er mot migrasjonene, ikke mot
    // TypeScript-unionene, slik at den også fanger at *databasen* skulle slå
    // dem sammen.
    const reported = new Set(enumValues('knowledge.effect_direction'))
    const claim = new Set(enumValues('knowledge.claim_direction'))
    expect(reported).not.toEqual(claim)
    expect(reported.has('not_stated')).toBe(true)
    expect(claim.has('not_stated')).toBe(false)
  })

  it('finner faktisk enum-ene den leter etter', () => {
    // Uten denne ville en omskrevet migrasjon gjort hele testen stille sann:
    // enumValues() kaster, men bare hvis den kalles på et navn som finnes.
    expect(enumValues('knowledge.claim_direction')).toContain('no_clear_difference')
    expect(() => enumValues('knowledge.finnes_ikke')).toThrow(/fant ingen enum-definisjon/)
  })
})

describe('uthentingen tar med senere endringer av enumet', () => {
  // Migrasjon 005ad utvider `workflow.evidence_check_field` med `alter type`,
  // så den virkelige SQL-en eksersiserer nå begge formene. Prøvene under holder
  // likevel hver form for seg: de dekker `if not exists`, plassering, omdøping
  // og rekkefølge, som den virkelige SQL-en ikke bruker alle av.
  const CREATE = "create type knowledge.demo as enum ('a', 'b');"

  it('leser den opprinnelige definisjonen', () => {
    expect(enumValuesFrom(CREATE, 'knowledge.demo')).toEqual(['a', 'b'])
  })

  it('tar med en verdi lagt til senere', () => {
    // Uten dette passerer vaktposten mens databasen kan returnere «c».
    const sql = `${CREATE}\nalter type knowledge.demo add value 'c';`
    expect(enumValuesFrom(sql, 'knowledge.demo')).toEqual(['a', 'b', 'c'])
  })

  it('tar med en verdi lagt til med if not exists og plassering', () => {
    const sql = `${CREATE}\nalter type knowledge.demo add value if not exists 'c' before 'b';`
    expect(new Set(enumValuesFrom(sql, 'knowledge.demo'))).toEqual(new Set(['a', 'b', 'c']))
  })

  it('teller ikke en verdi to ganger', () => {
    const sql = `${CREATE}\nalter type knowledge.demo add value if not exists 'b';`
    expect(enumValuesFrom(sql, 'knowledge.demo')).toEqual(['a', 'b'])
  })

  it('følger en omdøpt verdi', () => {
    const sql = `${CREATE}\nalter type knowledge.demo rename value 'b' to 'c';`
    expect(enumValuesFrom(sql, 'knowledge.demo')).toEqual(['a', 'c'])
  })

  it('leser endringene i rekkefølge', () => {
    const sql = [
      CREATE,
      "alter type knowledge.demo add value 'c';",
      "alter type knowledge.demo rename value 'c' to 'd';",
    ].join('\n')
    expect(enumValuesFrom(sql, 'knowledge.demo')).toEqual(['a', 'b', 'd'])
  })

  it('rører ikke et annet enum med liknende navn', () => {
    const sql = `${CREATE}\ncreate type knowledge.other as enum ('x');\nalter type knowledge.other add value 'y';`
    expect(enumValuesFrom(sql, 'knowledge.demo')).toEqual(['a', 'b'])
    expect(enumValuesFrom(sql, 'knowledge.other')).toEqual(['x', 'y'])
  })

  it('kaster på en endringsform den ikke kan tolke, framfor å ignorere den', () => {
    // Det er dette som gjør at vaktposten ikke kan bli stille: en DDL-form vi
    // ikke har tenkt på stopper testen i stedet for å gli forbi.
    const sql = `${CREATE}\nalter type knowledge.demo owner to postgres;`
    expect(() => enumValuesFrom(sql, 'knowledge.demo')).toThrow(/ukjent «alter type/)
  })

  it('kaster når en omdøping viser til en verdi som ikke finnes', () => {
    const sql = `${CREATE}\nalter type knowledge.demo rename value 'z' to 'c';`
    expect(() => enumValuesFrom(sql, 'knowledge.demo')).toThrow(
      /viser til en verdi som ikke finnes/,
    )
  })
})

describe('skillet mellom dimensjonale og dimensjonsløse effektmål følger migrasjon 004', () => {
  // claim_revisions_magnitude_unit_check krever enhet for målene den lister,
  // og forbyr enhet for resten. `claim-effect.ts` gjentar det skillet i en
  // egen liste, og de to kan drive fra hverandre uten at noe feiler.
  const constraint =
    /when magnitude_measure in \(([^)]*)\)\s*then magnitude_unit is not null/i.exec(SQL)

  const requiresUnit = (constraint?.[1] ?? '')
    .split(',')
    .map((entry) => entry.trim().replace(/^'|'$/g, ''))
    .filter((entry) => entry.length > 0)

  it('finner regelen i migrasjonen', () => {
    expect(requiresUnit.length).toBeGreaterThan(0)
    expect(requiresUnit.every((measure) => EFFECT_MEASURES.includes(measure as never))).toBe(true)
  })

  // Komparatoren velges slik at den stemmer med målet, ellers ville den andre
  // invarianten — kontrastivt mål krever komparator — slått ut først og skjult
  // det denne testen faktisk måler.
  function fittingComparator(measure: EffectMeasure): ClaimComparatorState {
    return isWithinArmMeasure(measure) ? { kind: 'none' } : { kind: 'placebo' }
  }

  it.each(EFFECT_MEASURES)('%s behandles som migrasjonen sier', (measure) => {
    const dimensional = requiresUnit.includes(measure)
    const comparator = fittingComparator(measure)
    expect(
      describeClaimMagnitude(
        { magnitude_measure: measure, magnitude_value: 1.2, magnitude_unit: 'kg' },
        comparator,
      ),
    ).toMatchObject(
      dimensional ? { kind: 'quantified' } : { reason: 'unit_on_dimensionless_measure' },
    )
    expect(
      describeClaimMagnitude(
        { magnitude_measure: measure, magnitude_value: 1.2, magnitude_unit: null },
        comparator,
      ),
    ).toMatchObject(dimensional ? { reason: 'missing_unit' } : { kind: 'quantified' })
  })
})
