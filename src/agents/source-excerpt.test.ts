// ============================================================================
// Reglene for et kontrollerbart kildeutdrag, prøvd mot de feilene som faktisk
// slapp gjennom
//
// Prøvene her er skrevet av den første reelle menneskelige kildekontrollen
// (Fava 2000 × sertralin × vektendring), ikke av fantasi. Hver negative prøve
// er et utdrag som sto ordrett i artikkelen, passerte hele kjeden, og likevel
// ikke lot kontrolløren avgjøre delpunktet uten å lese artikkelen ved siden av.
//
// De positive prøvene er like viktige: regelen skal ikke avvise legitime utdrag
// fra en PDF. Linjeskift, orddeling over linjer, forkortelser og tall med
// desimaltegn er hverdagen i `pdftotext`-utdata, og et ledd som avviser riktige
// ekstraksjoner, er verre enn intet ledd.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { searchProjections } from './extraction-checks'
import {
  MIN_SOURCE_EXCERPT_LENGTH,
  excerptShapeProblem,
  excerptSourceProblem,
  spansSentenceBoundary,
} from './source-excerpt'

/**
 * Setningen fra Fava 2000 som forankringen skulle ha vært, og litt av det som
 * står rundt den — med et linjeskift midt i, slik `pdftotext` faktisk leverer.
 */
const ARTIKKEL = [
  'J Clin Psychiatry 61:11, November 2000',
  '',
  'Patients (N = 284) with major depressive disorder (DSM-IV) were randomly',
  'assigned to double-blind treatment with fluoxetine (N = 92), sertraline,',
  '(N = 96), or paroxetine (N = 96) for a total of 26 to 32 weeks. Sertraline-',
  'treated patients showed a small mean increase in weight (1.0%); the increase',
  'was not statistically significant.',
].join('\n')

const HELE_SETNINGEN =
  'Patients (N = 284) with major depressive disorder (DSM-IV) were randomly assigned to ' +
  'double-blind treatment with fluoxetine (N = 92), sertraline, (N = 96), or paroxetine ' +
  '(N = 96) for a total of 26 to 32 weeks.'

function sourceProblem(excerpt: string): string | null {
  return excerptSourceProblem(searchProjections(ARTIKKEL), excerpt)
}

describe('excerptShapeProblem', () => {
  it('godtar en hel setning fra kilden', () => {
    expect(excerptShapeProblem(HELE_SETNINGEN)).toBeNull()
  })

  it('godtar to tilstøtende setninger, når én ikke gjør betydningen entydig', () => {
    expect(
      excerptShapeProblem(
        'Sertraline-treated patients showed a small mean increase in weight (1.0%); the ' +
          'increase was not statistically significant.',
      ),
    ).toBeNull()
  })

  // Det som faktisk ble registrert i produksjon. Det er 49 tegn langt og består
  // av ekte ord fra artikkelen — og sier likevel ingenting om hvilken studie,
  // hvilken populasjon eller hvilket virkestoff de 92 gjelder.
  it('avviser fragmentet som ble registrert for Fava 2000', () => {
    expect(excerptShapeProblem('tine (N = 92), sertraline, (N = 96), or paroxetine')).toMatch(
      /inneholder ingen setningsgrense/,
    )
  })

  it('avviser et utdrag som er for kort til å bære kontekst', () => {
    expect(excerptShapeProblem('N = 284.')).toMatch(
      new RegExp(`kortere enn ${String(MIN_SOURCE_EXCERPT_LENGTH)} tegn`),
    )
  })

  // Fragmentet inneholder et punktum, men det er et desimaltegn. Uten unntaket
  // ville «1.0» gjort et hvilket som helst tallfragment til en «setning».
  it('regner ikke et desimaltegn som en setningsgrense', () => {
    expect(spansSentenceBoundary('a small mean increase in weight of 1.0 percent')).toBe(false)
    expect(spansSentenceBoundary('weight increased by 1.0 percent.')).toBe(true)
  })
})

describe('excerptSourceProblem', () => {
  it('godtar en hel setning som står i kilden, på tvers av linjeskift', () => {
    expect(sourceProblem(HELE_SETNINGEN)).toBeNull()
  })

  // Kjernen i saken: utdraget STÅR ordrett i artikkelen, og er likevel et
  // utsnitt av en tegnstrøm. «tine» er halen av «fluoxetine».
  it('avviser et utdrag som begynner midt i et ord', () => {
    expect(sourceProblem('tine (N = 92), sertraline, (N = 96), or paroxetine')).toMatch(
      /midt i et ord/,
    )
  })

  it('avviser et utdrag som slutter midt i et ord', () => {
    expect(sourceProblem('Patients (N = 284) with major depressive dis')).toMatch(/midt i et ord/)
  })

  it('sier fra når utdraget ikke står i kilden i det hele tatt', () => {
    expect(sourceProblem('Patients were randomised to mirtazapine for eight weeks.')).toMatch(
      /ikke står ordrett/,
    )
  })

  // Et utdrag som begynner på et skilletegn kan ikke kappe et ord i to, og da
  // finnes det ingen ordgrense å kreve.
  it('krever ingen ordgrense der utdraget begynner og slutter på skilletegn', () => {
    expect(sourceProblem('(N = 96), or paroxetine (N = 96) for a total of 26 to 32 weeks.')).toBe(
      null,
    )
  })

  // Regresjonsprøve for issue #84, sett fra forankringens side. Sidefoten og
  // brødteksten er to uavhengige layoutblokker, og den blanke linjen mellom dem
  // er grensen den nye representasjonen setter. Uten at kontrollen respekterer
  // grensen, ville et «ordrett» utdrag kunnet sette dem sammen — og en
  // kontrollør ville lest en setning som ikke står i artikkelen.
  it('avviser et utdrag som setter sammen to uavhengige layoutblokker', () => {
    expect(
      sourceProblem('J Clin Psychiatry 61:11, November 2000 Patients (N = 284) with major'),
    ).toMatch(/ikke står ordrett/)
  })
})
