// ============================================================================
// Kontrollen mot den faglige standarden
//
// `standard.ts` er ikke et andre register over monografispørsmålene, og denne
// prøven er grunnen til at det ikke er det: den leser
// `docs/MONOGRAPH_STANDARD.md` og `docs/SOURCE_POLICY.md` på nytt og krever at
// hver eneste rad er den samme. En faglig endring i dokumentet uten en endring
// her stopper derfor kontrollene, framfor å bli et avvik ingen oppdager før et
// dekningskart mangler et spørsmål.
//
// Prøven leser dokumentene med sin egen parser. Det er med vilje: to uavhengige
// avlesninger av den samme tabellen kan vise at de er enige, mens én felles
// hjelpefunksjon bare ville vist at den er enig med seg selv.
// ============================================================================

import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

import {
  ANSWER_FORMS,
  MONOGRAPH_STANDARD_VERSION,
  PRESCRIBED_SCOPE_VALUES,
  QUESTION_TEMPLATES,
  REQUIREMENT_TYPES,
  SCOPE_AXES,
  SEARCH_TRACKS,
  SOURCE_PROFILES,
  SOURCE_PROFILE_CODES,
  prescribedScopeValues,
  questionTemplate,
  requiredSearchTracks,
  sourceProfile,
} from './standard.ts'

const STANDARD_DOC = 'docs/MONOGRAPH_STANDARD.md'
const POLICY_DOC = 'docs/SOURCE_POLICY.md'

interface DocTemplate {
  readonly code: string
  readonly prompt: string
  readonly requirementText: string
  readonly formCell: string
}

function readDocTemplates(): readonly DocTemplate[] {
  const rows: DocTemplate[] = []
  for (const line of readFileSync(STANDARD_DOC, 'utf8').split('\n')) {
    const match = /^\| (MN\d\d) \| (.*?) \| (.*?) \| (.*?) \|$/.exec(line)
    if (match) {
      rows.push({
        code: match[1] as string,
        prompt: match[2] as string,
        requirementText: match[3] as string,
        formCell: match[4] as string,
      })
    }
  }
  return rows
}

function readDocProfiles(): readonly { code: string; question: string }[] {
  const rows: { code: string; question: string }[] = []
  let inTable = false
  for (const line of readFileSync(POLICY_DOC, 'utf8').split('\n')) {
    if (line.startsWith('| Profil | Spørsmål |')) {
      inTable = true
      continue
    }
    if (inTable) {
      const match = /^\| ([A-Z]{2,4}) \| (.*?) \| (.*?) \| (.*?) \|$/.exec(line)
      if (!match) {
        if (line.startsWith('| --- ')) continue
        inTable = false
        continue
      }
      rows.push({ code: match[1] as string, question: match[2] as string })
    }
  }
  return rows
}

describe('monografistandarden som maskinlesbar kontrakt', () => {
  it('uttrykker versjonen dokumentet oppgir', () => {
    const doc = readFileSync(STANDARD_DOC, 'utf8')
    expect(doc).toContain(`Versjon: **${MONOGRAPH_STANDARD_VERSION}**`)
  })

  it('har nøyaktig de 80 malene dokumentet har, i den samme rekkefølgen', () => {
    const docCodes = readDocTemplates().map((row) => row.code)
    expect(docCodes).toHaveLength(80)
    expect(QUESTION_TEMPLATES.map((template) => template.code)).toEqual(docCodes)
  })

  it('bruker stabile, sammenhengende malidentiteter MN01–MN80', () => {
    QUESTION_TEMPLATES.forEach((template, index) => {
      expect(template.code).toBe(`MN${String(index + 1).padStart(2, '0')}`)
    })
  })

  it('gjengir spørsmålet og kravkolonnen ordrett fra standarden', () => {
    const byCode = new Map(readDocTemplates().map((row) => [row.code, row]))
    for (const template of QUESTION_TEMPLATES) {
      const row = byCode.get(template.code)
      expect(row, `mangler ${template.code} i ${STANDARD_DOC}`).toBeDefined()
      expect(template.prompt).toBe(row?.prompt)
      expect(template.requirementText).toBe(row?.requirementText)
    }
  })

  it('utleder kravtypen av kravkolonnens egen bokstav', () => {
    const byCode = new Map(readDocTemplates().map((row) => [row.code, row]))
    for (const template of QUESTION_TEMPLATES) {
      const text = byCode.get(template.code)?.requirementText ?? ''
      const expected = text.startsWith('A:')
        ? 'derived'
        : text.startsWith('B:')
          ? 'conditional'
          : 'mandatory'
      expect(template.requirement, template.code).toBe(expected)
      expect(REQUIREMENT_TYPES).toContain(template.requirement)
    }
  })

  it('skiller obligatorisk screening fra betinget fordypning', () => {
    const byCode = new Map(readDocTemplates().map((row) => [row.code, row]))
    for (const template of QUESTION_TEMPLATES) {
      const text = byCode.get(template.code)?.requirementText ?? ''
      const screening = text.startsWith('O screening;')
      expect(template.conditionalDeepening !== null, template.code).toBe(screening)
      if (screening) {
        // En screeningsmal er obligatorisk å undersøke. Fordypningen er
        // betinget, og de to er ikke det samme kravet.
        expect(template.requirement).toBe('mandatory')
      }
    }
    expect(
      QUESTION_TEMPLATES.filter((t) => t.conditionalDeepening !== null).map((t) => t.code),
    ).toEqual(['MN50', 'MN51', 'MN54', 'MN55', 'MN62', 'MN65'])
  })

  it('kobler hver mal til de kildeprofilene standarden oppgir', () => {
    const byCode = new Map(readDocTemplates().map((row) => [row.code, row]))
    for (const template of QUESTION_TEMPLATES) {
      const cell = byCode.get(template.code)?.formCell ?? ''
      const profileCell = cell.split(' / ')[1] ?? ''
      if (profileCell.includes('relevante kildeprofiler')) {
        expect(template.openSourceProfiles, template.code).toBe(true)
        expect(template.sourceProfiles).toEqual([])
        continue
      }
      expect(template.openSourceProfiles, template.code).toBe(false)
      expect(template.sourceProfiles).toEqual(profileCell.split(',').map((part) => part.trim()))
      expect(template.sourceProfiles.length).toBeGreaterThan(0)
    }
  })

  it('bruker bare kjente kildeprofiler, svarformer og akser', () => {
    for (const template of QUESTION_TEMPLATES) {
      for (const profile of template.sourceProfiles) {
        expect(SOURCE_PROFILE_CODES).toContain(profile)
      }
      expect(template.forms.length).toBeGreaterThan(0)
      for (const form of template.forms) {
        expect(ANSWER_FORMS).toContain(form)
      }
      for (const axis of template.expansionAxes) {
        expect(SCOPE_AXES).toContain(axis)
      }
    }
  })

  it('har nøyaktig de 13 kildeprofilene kildepolitikken beskriver', () => {
    const docProfiles = readDocProfiles()
    expect(docProfiles).toHaveLength(13)
    expect(SOURCE_PROFILES.map((profile) => profile.code)).toEqual(
      docProfiles.map((profile) => profile.code),
    )
    const byCode = new Map(docProfiles.map((profile) => [profile.code, profile]))
    for (const profile of SOURCE_PROFILES) {
      expect(profile.question).toBe(byCode.get(profile.code)?.question)
      expect(profile.firstChoice.length).toBeGreaterThan(0)
      expect(profile.supplement.length).toBeGreaterThan(0)
    }
  })

  it('gir hver profil minst ett obligatorisk søkespor', () => {
    for (const code of SOURCE_PROFILE_CODES) {
      expect(requiredSearchTracks(code).length, code).toBeGreaterThan(0)
    }
    for (const track of SEARCH_TRACKS) {
      expect(track.profiles.length).toBeGreaterThan(0)
      for (const profile of track.profiles) {
        expect(SOURCE_PROFILE_CODES).toContain(profile)
      }
    }
  })

  it('brukes av hver profil av minst én mal, slik at ingen profil er død', () => {
    const used = new Set(QUESTION_TEMPLATES.flatMap((template) => template.sourceProfiles))
    for (const code of SOURCE_PROFILE_CODES) {
      expect(used, `kildeprofilen ${code} brukes ikke av noen mal`).toContain(code)
    }
  })

  it('navngir koden når en mal eller profil ikke finnes', () => {
    expect(() => questionTemplate('MN99')).toThrow(/MN99/)
    expect(() => sourceProfile('XYZ')).toThrow(/XYZ/)
    expect(questionTemplate('MN01').code).toBe('MN01')
    expect(sourceProfile('REG').code).toBe('REG')
  })
})

describe('verdiene standarden selv navngir', () => {
  const doc = readFileSync(STANDARD_DOC, 'utf8')

  it('har nøyaktig de antallene standardens screeningslister skriver ut', () => {
    expect(prescribedScopeValues('MN38')).toHaveLength(11)
    expect(prescribedScopeValues('MN50')).toHaveLength(4)
    expect(prescribedScopeValues('MN51')).toHaveLength(6)
    expect(prescribedScopeValues('MN55')).toHaveLength(5)
    // Og ingen andre maler har prescribed verdier: resten utvides av
    // dokumenterte funn, ikke av en liste i standarden.
    const templates = new Set(PRESCRIBED_SCOPE_VALUES.map((value) => value.template))
    expect([...templates].sort()).toEqual(['MN38', 'MN50', 'MN51', 'MN55'])
  })

  it('gjengir MN38s risikoområder fra standardens egen setning', () => {
    const sentence = doc.split('\n').find((line) => line.startsWith('MN38 skal minst vurdere'))
    expect(sentence).toBeDefined()
    for (const value of prescribedScopeValues('MN38')) {
      expect(sentence, value.label).toContain(value.label)
      expect(value.axis).toBe('risk_area')
    }
  })

  it('gjengir screeningsverdiene fra malens eget spørsmål', () => {
    for (const code of ['MN50', 'MN51', 'MN55']) {
      const prompt = questionTemplate(code).prompt
      for (const value of prescribedScopeValues(code)) {
        expect(prompt, `${code}: ${value.label}`).toContain(value.label)
      }
    }
  })

  it('bruker en akse malen faktisk gjentas på', () => {
    for (const value of PRESCRIBED_SCOPE_VALUES) {
      expect(SCOPE_AXES).toContain(value.axis)
      expect(questionTemplate(value.template).expansionAxes, value.template).toContain(value.axis)
    }
  })

  it('navngir hver verdi bare én gang per mal og akse', () => {
    const keys = PRESCRIBED_SCOPE_VALUES.map(
      (value) => `${value.template}|${value.axis}|${value.label}`,
    )
    expect(new Set(keys).size).toBe(keys.length)
  })
})

// ----------------------------------------------------------------------------
// Utfallsaksen
//
// Et forskningssvar må kunne finne behovet sitt. Uten et navngitt endepunkt på
// behovet finnes det ingen avgrensning ekstraksjonen kan kontrolleres mot, og
// to funn om det samme virkestoffet og den samme indikasjonen ville hatt samme
// avtrykk selv når det ene handler om respons og det andre om frafall
// (MONOGRAPH_STANDARD.md §2).
//
// Men aksen hører bare der delutfallene faktisk *er* målte endepunkter. Der
// standarden selv navngir en annen dimensjon for delutfallene — risikoområde,
// tilleggstilstand eller et navngitt funn — er det den dimensjonen behovet
// gjentas på, og en utfallsakse i tillegg ville delt det samme spørsmålet i to
// lag ingen har bedt om.
// ----------------------------------------------------------------------------
describe('utfallsaksen', () => {
  /** Aksene standarden bruker til å navngi delutfallene i en profil. */
  const SUBRESULT_AXES = ['risk_area', 'comorbidity', 'finding'] as const

  it('står på hver mal som ber om et estimat', () => {
    for (const template of QUESTION_TEMPLATES) {
      if (!template.forms.includes('estimate')) continue
      expect(template.expansionAxes, template.code).toContain('outcome')
    }
  })

  it('står ikke der standarden navngir en annen delutfallsakse', () => {
    for (const template of QUESTION_TEMPLATES) {
      const named = SUBRESULT_AXES.filter((axis) => template.expansionAxes.includes(axis))
      if (named.length === 0) continue
      expect(template.expansionAxes, `${template.code} (${named.join(', ')})`).not.toContain(
        'outcome',
      )
    }
  })

  it('står ikke på en mal som ikke ber om et estimat eller en profil', () => {
    for (const template of QUESTION_TEMPLATES) {
      if (template.forms.includes('estimate') || template.forms.includes('profile')) continue
      expect(template.expansionAxes, template.code).not.toContain('outcome')
    }
  })
})
