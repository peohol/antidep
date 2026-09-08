// ============================================================================
// Fikstur for agenttestene
//
// Ett gyldig evidensfunn slik `api.extraction_verification_input(...)` leverer
// det, og én gyldig påstandsrevisjon slik `api.claim_verification_input(...)`
// leverer den, med en overstyring per test. Formene er de migrasjon 005h og 005k
// dokumenterer; hver test varierer nøyaktig det den handler om, slik at det som
// felles testen, er det testen sier den prøver.
// ============================================================================

import type {
  ClaimEvidenceLink,
  ClaimRevisionInput,
  ClaimStatement,
} from './claim-verification-input.ts'
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
  '  <AbstractText Label="RESULTS">Sertraline-treated patients with major depressive',
  '  disorder had a mean weight change of 1.5 kg (95% CI 0.4 to 2.6) &amp; the',
  '  difference was significant.</AbstractText>',
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
    // Engelsk, som resten av fiksturens begreper og av samme grunn: fiksturen er
    // den *positive* kontrollen, der alt raden oppgir faktisk lar seg gjenfinne i
    // kilden. En norsk etikett mot en engelsk kilde er en helt reell situasjon, og
    // den er prøvd der den hører hjemme — i testen som viser at et begrep som ikke
    // ble gjenfunnet, gir `uncertain`.
    populationLabel: 'major depressive disorder',
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
    timepointMin: null,
    timepointMax: null,
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
      // Utdraget navngir armen, populasjonen og endepunktet i samme påstand:
      // alle radens deler må stå i ett sammenhengende treff.
      resultat:
        'Sertraline-treated patients with major depressive disorder had a mean weight ' +
        'change of 1.5 kg (95% CI 0.4 to 2.6)',
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
    sourceType: 'journal_article',
    sourceAuthorsOrIssuer: 'Testforfatter m.fl.',
    sourcePublisherOrJournal: 'Testtidsskrift',
    sourcePublicationDate: '2024-01-01',
    sourcePublicationDatePrecision: 'day',
    sourceStatus: 'active',
    sourceStatusNote: null,
    sourceVersion: sourceVersion === undefined ? sourceVersionFixture() : sourceVersion,
    extraction: extractionFixture(extraction),
    verificationsByThisActor: 0,
    ...rest,
  }
}

// ----------------------------------------------------------------------------
// Claim-verifikasjonen
//
// Én påstandsrevisjon slik `api.claim_verification_input(...)` leverer den, med
// en overstyring per test. Fiksturen er den *positive* kontrollen: påstandens
// strukturerte betydning stemmer med evidensfunnet på hvert felt kontrollen kan
// sammenligne, slik at det som felles i en test, er det testen sier den prøver.
// ----------------------------------------------------------------------------

export function claimStatementFixture(overrides: Partial<ClaimStatement> = {}): ClaimStatement {
  return {
    statement: 'Testpåstand om vektendring ved sertralin.',
    scope: 'Gjelder gjennomsnittlig vektendring fra behandlingsstart.',
    populationId: '52000000-0000-4000-8000-000000000001',
    populationLabel: 'major depressive disorder',
    timeframeMin: null,
    timeframeMax: null,
    comparatorKind: 'none',
    comparatorDrugId: null,
    comparatorDrugName: null,
    direction: 'increase',
    magnitudeMeasure: null,
    magnitudeValue: null,
    magnitudeUnit: null,
    qualifiers: 'Grunnlaget er armspesifikt.',
    uncertaintySummary: 'Ett funn fra én studie.',
    ...overrides,
  }
}

export function claimEvidenceLinkFixture(
  overrides: Partial<Omit<ClaimEvidenceLink, 'evidenceItem'>> & {
    readonly evidenceItem?: Parameters<typeof verificationItemFixture>[0]
  } = {},
): ClaimEvidenceLink {
  const { evidenceItem, ...rest } = overrides
  return {
    claimEvidenceLinkId: '53000000-0000-4000-8000-000000000001',
    relationshipType: 'supports',
    directness: 'direct',
    relevanceNote: 'Funnet rapporterer utfallet påstanden gjelder.',
    evidenceItem: verificationItemFixture(evidenceItem),
    currentExtractionVerification: {
      evidenceVerificationId: '54000000-0000-4000-8000-000000000001',
      outcome: 'verified',
      sourceAccess: 'verifiable_representation',
      checkedFields: ['raw_extraction', 'source_locator'],
      verifiedAt: '2026-09-02T00:00:00+00:00',
    },
    ...rest,
  }
}

export function claimRevisionFixture(
  overrides: Partial<Omit<ClaimRevisionInput, 'claim'>> & {
    readonly claim?: Partial<ClaimStatement>
  } = {},
): ClaimRevisionInput {
  const { claim, ...rest } = overrides
  return {
    claimRevisionId: '55000000-0000-4000-8000-000000000001',
    claimId: '55000000-0000-4000-8000-000000000002',
    revisionNumber: 1,
    knowledgeType: 'evidence_synthesis',
    createdByActorId: '56000000-0000-4000-8000-000000000001',
    createdByActorKey: 'agent:claim-synthesis',
    contentHash: `sha256-v2:${'c'.repeat(64)}`,
    claimRetiredAt: null,
    topicConceptId: '57000000-0000-4000-8000-000000000001',
    topicLabel: 'vektendring',
    subjectDrugId: '58000000-0000-4000-8000-000000000001',
    subjectDrugName: 'sertralin',
    evidenceSetDigest: `sha256-v1:${'d'.repeat(64)}`,
    claim: claimStatementFixture(claim),
    links: [claimEvidenceLinkFixture()],
    unlinkedRelatedEvidence: [],
    verificationsByThisActor: 0,
    verificationsTotal: 0,
    ...rest,
  }
}
