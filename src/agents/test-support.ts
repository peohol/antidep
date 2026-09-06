// ============================================================================
// Fikstur for agenttestene
//
// Ett gyldig evidensfunn slik `api.extraction_verification_input(...)` leverer
// det, med en overstyring per test. Formen er den samme som migrasjon 005h
// dokumenterer; hver test varierer nøyaktig det den handler om, slik at det som
// felles testen, er det testen sier den prøver.
// ============================================================================

import type {
  VerificationExtraction,
  VerificationItem,
  VerificationSourceVersion,
} from './verification-input.ts'

export const FIXTURE_SOURCE_TEXT = [
  '<PubmedArticle>',
  '  <ArticleTitle>Weight gain during long-term treatment</ArticleTitle>',
  '  <AbstractText Label="METHODS">Sertraline patients (N = 284) with major',
  '  depressive disorder were randomised. Fluoxetine was the comparator.</AbstractText>',
  '  <AbstractText Label="RESULTS">Sertraline-treated patients had a mean weight',
  '  change of 1.5 kg (95% CI 0.4 to 2.6) &amp; the difference was significant.</AbstractText>',
  '</PubmedArticle>',
].join('\n')

export function sourceVersionFixture(
  overrides: Partial<VerificationSourceVersion> = {},
): VerificationSourceVersion {
  return {
    sourceVersionId: '51000000-0000-4000-8000-000000000001',
    retrievedAt: '2026-09-01T00:00:00+00:00',
    retrievedFrom: 'https://eksempel.invalid/kilde',
    externalVersion: null,
    contentHash: `sha256:${'a'.repeat(64)}`,
    hasStorageReference: false,
    ...overrides,
  }
}

export function extractionFixture(
  overrides: Partial<VerificationExtraction> = {},
): VerificationExtraction {
  return {
    designCode: 'randomized_controlled_trial',
    populationLabel: 'voksne med depressiv lidelse',
    populationAvailability: 'reported_value',
    populationDetail: 'Voksne med depressiv lidelse.',
    sampleSize: 284,
    sampleSizeAvailability: 'reported_value',
    interventionDrugName: 'sertraline',
    interventionDetail: null,
    comparatorKind: 'none',
    comparatorDrugName: null,
    comparatorDetail: null,
    outcomeLabel: 'weight change',
    outcomeDetail: 'Gjennomsnittlig vektendring.',
    timepointAvailability: 'not_reported',
    reportedDirection: 'increase',
    effectMeasure: 'mean_change',
    estimate: '1.5',
    estimateUnit: 'kg',
    estimateAvailability: 'reported_value',
    ciLower: '0.4',
    ciUpper: '2.6',
    ciLevelPercent: '95',
    confidenceIntervalAvailability: 'reported_value',
    limitationsText: null,
    sourceLocator: 'Sammendrag, resultatavsnittet',
    // To utdrag, som i de seedede radene fra migrasjon 003: tallene kontrolleres
    // mot funnets egne utdrag, så et funn som oppgir utvalgsstørrelse må ha et
    // utdrag som sier den.
    rawExtraction: {
      metode:
        'Sertraline patients (N = 284) with major depressive disorder were randomised. ' +
        'Fluoxetine was the comparator.',
      // Utdraget navngir armen selv: et tall kan bare kontrolleres mot et
      // utdrag som sier hvilken arm det gjelder.
      resultat:
        'Sertraline-treated patients had a mean weight change of 1.5 kg (95% CI 0.4 to 2.6)',
    },
    ...overrides,
  }
}

export function verificationItemFixture(
  overrides: Partial<Omit<VerificationItem, 'extraction' | 'sourceVersion'>> & {
    readonly extraction?: Partial<VerificationExtraction>
    readonly sourceVersion?: VerificationSourceVersion | null
  } = {},
): VerificationItem {
  const { extraction, sourceVersion, ...rest } = overrides
  return {
    evidenceItemId: '3422c284-31eb-428e-b1a0-bebf3f616ffc',
    createdByActorKey: 'agent:evidence-extraction',
    sourceId: '50000000-0000-4000-8000-000000000001',
    sourceTitle: 'Testkilde',
    sourceVersion: sourceVersion === undefined ? sourceVersionFixture() : sourceVersion,
    extraction: extractionFixture(extraction),
    verificationsByThisActor: 0,
    ...rest,
  }
}
