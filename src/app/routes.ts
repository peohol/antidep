// ============================================================================
// Adressene i klinikerflaten
//
// Ett sted, fordi URL-en er en kontrakt: §55 i
// PRODUCT_INFORMATION_ARCHITECTURE.md krever at en kliniker kan dele en lenke
// direkte til et virkestoff, en klinisk situasjon og en evidensvisning, og
// invariant 12 gjør dypelenker til standard. En adresse som konstrueres på
// stedet i hver komponent er ikke en kontrakt, den er en vane.
//
// Rutingen eier adressene. `ClaimCard` tar imot `evidenceHref` som en streng og
// kjenner ingen ruting; det er her strengen lages (§74.13 punkt 4).
//
// ----------------------------------------------------------------------------
// Hvorfor stisegmentene er engelske og innholdet norsk
//
// `/drugs/sertralin` står ordrett i MVP_IMPLEMENTATION_PLAN.md §30. Segmentene
// er dermed et teknisk navnerom på engelsk, mens verdiene i dem er de norske
// kanoniske navnene fra katalogen. Å oversette halvparten av stien ville gitt
// et vilkårlig skille; å oversette hele ville brutt med den adressen planen
// navngir.
// ============================================================================

import { toSlug } from '../lib/slug'
import type { Uuid } from '../types/api'

/**
 * Mønstrene ruteren matcher på. Parameternavnene er de `useParams()` gir, og
 * builderne under er de eneste stedene en faktisk adresse settes sammen.
 */
export const ROUTE_PATTERNS = {
  home: '/',
  drug: '/drugs/:drugSlug',
  topic: '/topics/:topicSlug',
  claimEvidence: '/claims/:claimId/evidence',
  source: '/sources/:sourceId',
  sourceNew: '/sources/new',
  sourceVersionNew: '/source-versions/new',
  evidenceNew: '/evidence/new',
  reviewQueue: '/review',
  claimReview: '/review/:claimRevisionId',
  extractionReviewQueue: '/extraction-review',
  extractionReview: '/extraction-review/:evidenceItemId',
  access: '/access',
} as const

/** Forsiden: hvilke virkestoff Antidep har publisert kunnskap om. */
export function homePath(): string {
  return '/'
}

/**
 * Min tilgang (MVP_IMPLEMENTATION_PLAN.md §29, §74.22): innlogging, og et svar
 * på «hvem er jeg, og hva har jeg lov til?». Ingen parameter — adressen er den
 * samme for en uinnlogget og en innlogget kaller, og siden selv avgjør hvilket
 * av de to den viser (`AccessPage.tsx`).
 */
export function accessPath(): string {
  return '/access'
}

/** Legemiddelsiden for ett kanonisk virkestoffnavn (§30). */
export function drugPath(canonicalName: string): string {
  return `/drugs/${encodeURIComponent(toSlug(canonicalName))}`
}

/** Temasiden for ett klinisk begrep (§26). */
export function topicPath(topicLabel: string): string {
  return `/topics/${encodeURIComponent(toSlug(topicLabel))}`
}

/**
 * «Hvorfor sier Antidep dette?» (§15).
 *
 * Adressert med `claim_id` og ikke med revisjonen: identiteten er stabil på
 * tvers av revisjoner (ANTIDEP_CONSTITUTION.md §7), så en delt lenke fortsetter
 * å peke på påstanden også etter en ny publisering. Hvilken revisjon som står
 * publisert, er noe visningen leser, ikke noe adressen fryser.
 */
export function claimEvidencePath(claimId: Uuid): string {
  return `/claims/${encodeURIComponent(claimId)}/evidence`
}

/**
 * Kildesiden: én publikasjon, og alt Antidep bruker den til
 * (PRODUCT_INFORMATION_ARCHITECTURE.md §42).
 *
 * Adressert med `source_id`, av samme grunn som evidensvisningen adresseres med
 * `claim_id`: uuid-en er kildens stabile identitet
 * (DATABASE_ARCHITECTURE.md §8), og den endrer seg ikke når raden redigeres.
 *
 * En slug avledet av tittelen ble vurdert og valgt bort. Kildetitler er inntil
 * 600 tegn og står på kildens eget språk, så sluggen ville blitt både lang og
 * fremmedspråklig — men det avgjørende er at avledningen har nøyaktig den
 * svakheten §74.7 allerede fører som gjeld for `/drugs/:drugSlug` og
 * `/topics/:topicSlug`: en adresse avledet av et visningsnavn er ikke en stabil
 * identitet, den er tapsgivende, og to titler kan kollidere. Å gjenta den på et
 * tredje objekt ville utvidet gjelden framfor å begrense den.
 */
export function sourcePath(sourceId: Uuid): string {
  return `/sources/${encodeURIComponent(sourceId)}`
}

/**
 * Opprett kilde (MVP_IMPLEMENTATION_PLAN.md §29, §74.24): steg 2 av
 * adminflyten, «Editor oppretter Source» (§15). Det statiske segmentet `new`
 * rangeres foran det dynamiske `:sourceId` av react-router selv, uavhengig av
 * rekkefølgen rutene er deklarert i (`App.tsx`) — en kilde kan derfor aldri få
 * uuid-en `new`, og adressen kolliderer ikke med `sourcePath()`.
 */
export function newSourcePath(): string {
  return '/sources/new'
}

/**
 * Registrer kildeversjon (MVP_IMPLEMENTATION_PLAN.md §15, issue #44): leddet
 * mellom å opprette kilden og å registrere et evidensfunn fra den.
 *
 * Adressen er `/source-versions/new` og ikke `/sources/:sourceId/versions/new`,
 * av samme grunn som for evidensfunn: skjemaet lar redaktøren velge kilden i en
 * nedtrekksliste, fordi listen er nettopp det hen trenger å se for å velge
 * riktig. En adresse som bakte kilden inn ville forutsatt at valget allerede var
 * tatt et sted som ikke finnes ennå.
 */
export function newSourceVersionPath(): string {
  return '/source-versions/new'
}

/**
 * Registrer evidensfunn (MVP_IMPLEMENTATION_PLAN.md §29): steg 3 av
 * adminflyten, «Editor registrerer EvidenceItem» (§15).
 *
 * Adressen er `/evidence/new` og ikke `/sources/:sourceId/evidence/new`, selv
 * om funnet alltid hører til én kilde. Grunnen er hvor valget faktisk tas:
 * skjemaet lar redaktøren velge kilden i en nedtrekksliste, fordi listen over
 * kilder er nettopp det hen trenger å se for å velge riktig — og en adresse som
 * bakte kilden inn ville forutsatt at valget allerede var tatt et sted som ikke
 * finnes ennå. En admin-visning av én kilde med «registrer funn herfra» er en
 * egen sak, og den PR-en kan legge til en adresse med kilden i.
 */
export function newEvidenceItemPath(): string {
  return '/evidence/new'
}

/**
 * Reviewkøen (MVP_IMPLEMENTATION_PLAN.md §15, ANTIDEP_CONSTITUTION.md §15):
 * hvilke påstandsrevisjoner som venter på faglig vurdering.
 *
 * Ingen parameter. Køen er kallerens egen — den avhenger av hvem som er
 * innlogget og hvilket innholdsområde reviewer-tildelingen dekker — og en
 * adresse som bakte inn et filter ville lovet at den kunne deles med noen som
 * ser noe annet.
 */
export function reviewQueuePath(): string {
  return '/review'
}

/**
 * Reviewarbeidsflaten for én påstandsrevisjon.
 *
 * Adressert med `claim_revision_id` og ikke med `claim_id`, til forskjell fra
 * `claimEvidencePath()`. Det er et bevisst skille: klinikerflaten peker på
 * påstandens stabile identitet, fordi den skal fortsette å peke på påstanden
 * etter en ny publisering. En faglig vurdering peker på nøyaktig den
 * formuleringen som ble vurdert (KNOWLEDGE_MODEL.md §19.3) — en godkjenning som
 * fulgte med over på en senere revisjon, ville vært en godkjenning av noe annet
 * enn det som ble lest.
 */
export function claimReviewPath(claimRevisionId: Uuid): string {
  return `/review/${encodeURIComponent(claimRevisionId)}`
}

/**
 * Køen for ekstraksjonskontroll (MVP_IMPLEMENTATION_PLAN.md §15,
 * ANTIDEP_CONSTITUTION.md §11): hvilke evidensfunn som venter på at et menneske
 * kontrollerer dem mot kilden.
 *
 * En egen adresse og ikke et filter på `/review`. De to køene er to forskjellige
 * arbeidsoppgaver på to forskjellige objekter: den ene spør «gjengir denne
 * ekstraksjonen kilden riktig?», den andre «støtter grunnlaget denne påstanden?».
 * Publiseringsgaten krever dem hver for seg (G5 og G9), og en samlet kø ville
 * skjult at de er to ledd.
 */
export function extractionReviewQueuePath(): string {
  return '/extraction-review'
}

/**
 * Kontrollflaten for ett evidensfunn.
 *
 * Adressert med `evidence_item_id`, som er funnets stabile identitet:
 * `knowledge.evidence_items` er append-only, så id-en peker for alltid på den
 * ekstraksjonen som faktisk ble kontrollert. En korrigert ekstraksjon er et nytt
 * funn med en ny adresse, og det er riktig — en kontroll som fulgte med over på
 * en rettet versjon, ville vært en kontroll av noe annet enn det som ble lest.
 */
export function extractionReviewPath(evidenceItemId: Uuid): string {
  return `/extraction-review/${encodeURIComponent(evidenceItemId)}`
}
