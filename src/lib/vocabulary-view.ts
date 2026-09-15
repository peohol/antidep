// ============================================================================
// Vokabularverdier vist på norsk
//
// Ligger i `lib` og ikke i en komponentfil, fordi de leses av flere flater og
// fordi en fil som eksporterer både en komponent og en konstant, mister
// hot-reloaden sin. Det er ingen ny sannhet her: verdiene er de samme lukkede
// vokabularene databasen håndhever.
// ============================================================================

/**
 * En vokabularverdi vist på norsk, eller verdien selv.
 *
 * Ukjente verdier vises ordrett framfor å bli borte: en verdi som ikke lar seg
 * oversette, er en eksplisitt ukjent tilstand, ikke et fravær
 * (ANTIDEP_CONSTITUTION.md regel 4).
 */
export function label(value: string, labels: Readonly<Record<string, string>>): string {
  return labels[value] ?? value
}

export const CERTAINTY_LABELS: Readonly<Record<string, string>> = {
  high: 'høy',
  moderate: 'moderat',
  low: 'lav',
  very_low: 'svært lav',
  no_assessable_evidence: 'ingen vurderbar evidens',
}

export const GRADE_RATING_LABELS: Readonly<Record<string, string>> = {
  not_serious: 'ikke alvorlig',
  serious: 'alvorlig',
  very_serious: 'svært alvorlig',
  not_assessable: 'lot seg ikke vurdere',
}

export const GRADE_DOMAIN_LABELS: Readonly<Record<string, string>> = {
  riskOfBias: 'Risiko for systematisk skjevhet',
  inconsistency: 'Inkonsistens',
  indirectness: 'Indirekthet',
  imprecision: 'Upresishet',
  publicationBias: 'Publikasjonsskjevhet',
}

export const CHECK_RESULT_LABELS: Readonly<Record<string, string>> = {
  ok: 'holder',
  deviation: 'avvik',
  not_assessable: 'lot seg ikke bedømme',
}

export const CHECK_FIELD_LABELS: Readonly<Record<string, string>> = {
  sourceSupport: 'Kildestøtte',
  populationMatch: 'Populasjon',
  comparatorMatch: 'Komparator',
  timeframeMatch: 'Tidsvindu',
  directionAndMagnitude: 'Retning og størrelse',
  qualifiersComplete: 'Forbehold komplett',
  contradictoryEvidenceRepresented: 'Motstridende evidens representert',
}

export const OUTCOME_LABELS: Readonly<Record<string, string>> = {
  verified: 'bekreftet',
  needs_correction: 'må rettes',
  rejected: 'avvist',
  uncertain: 'usikker',
}

export const SOURCE_ACCESS_LABELS: Readonly<Record<string, string>> = {
  original_source: 'originalkilden selv',
  verifiable_representation: 'etterprøvbar representasjon',
  derived_summary: 'avledet sammendrag',
}

export const AVAILABILITY_LABELS: Readonly<Record<string, string>> = {
  reported_value: 'rapportert',
  not_measured: 'ikke målt',
  not_reported: 'ikke rapportert',
  not_applicable: 'ikke relevant',
  not_extractable: 'lot seg ikke hente ut',
  uncertain_extraction: 'usikker uthenting',
}

/** Handlingene en publiseringshendelse kan registrere (migrasjon 006). */
export const PUBLICATION_ACTION_LABELS: Readonly<Record<string, string>> = {
  publish: 'publisert',
  replace: 'erstattet',
  withdraw: 'trukket tilbake',
  rollback: 'rullet tilbake',
}
