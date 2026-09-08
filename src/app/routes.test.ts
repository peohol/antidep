import { describe, expect, it } from 'vitest'
import {
  accessPath,
  claimEvidencePath,
  claimReviewPath,
  drugPath,
  extractionReviewPath,
  extractionReviewQueuePath,
  homePath,
  newEvidenceItemPath,
  newSourcePath,
  sourcePath,
  topicPath,
  ROUTE_PATTERNS,
} from './routes'

describe('adressene', () => {
  it('bygger nøyaktig de adressene §30 navngir', () => {
    expect(drugPath('sertralin')).toBe('/drugs/sertralin')
    expect(drugPath('mirtazapin')).toBe('/drugs/mirtazapin')
  })

  it('bruker det kanoniske navnet, uavhengig av bokstavstørrelse', () => {
    expect(drugPath('Sertralin')).toBe('/drugs/sertralin')
  })

  it('adresserer et klinisk tema med etiketten', () => {
    expect(topicPath('vektendring')).toBe('/topics/vektendring')
  })

  it('adresserer evidensvisningen med påstandens stabile identitet', () => {
    // claim_id, ikke claim_revision_id: identiteten overlever en ny publisering,
    // så en delt lenke fortsetter å peke på påstanden (ANTIDEP_CONSTITUTION §7).
    expect(claimEvidencePath('11111111-1111-4111-8111-111111111111')).toBe(
      '/claims/11111111-1111-4111-8111-111111111111/evidence',
    )
  })

  it('adresserer kildesiden med kildens stabile identitet', () => {
    // source_id og ikke en slug avledet av tittelen: uuid-en er identiteten, og
    // en tittelslug ville gjentatt sluggjelden fra §74.7 på et tredje objekt.
    expect(sourcePath('88888888-8888-4888-8888-111111111111')).toBe(
      '/sources/88888888-8888-4888-8888-111111111111',
    )
  })

  it('forsiden er roten', () => {
    expect(homePath()).toBe('/')
  })

  it('min tilgang har ingen parameter: adressen er den samme innlogget og ikke', () => {
    expect(accessPath()).toBe('/access')
  })

  it('opprett kilde har ingen parameter', () => {
    // Adressen kolliderer på tegnnivå med sourcePath('new'), og det er nettopp
    // poenget: hvilken side den treffer avgjøres av ruterens rangering av det
    // statiske segmentet foran :sourceId, prøvd direkte i App.test.tsx
    // («/sources/new treffer Opprett kilde»), ikke her.
    expect(newSourcePath()).toBe('/sources/new')
  })

  it('registrer evidensfunn har ingen parameter, selv om funnet hører til én kilde', () => {
    // Kilden velges i skjemaet, ikke i adressen — se doc-kommentaren på
    // newEvidenceItemPath().
    expect(newEvidenceItemPath()).toBe('/evidence/new')
  })

  it('kildekontrollen har sin egen kø, atskilt fra den faglige vurderingen', () => {
    // To køer og ikke ett filter: de spør om to forskjellige ting om to
    // forskjellige objekter, og publiseringsgaten krever dem hver for seg.
    expect(extractionReviewQueuePath()).toBe('/extraction-review')
  })

  it('adresserer kildekontrollen med evidensfunnets stabile identitet', () => {
    // evidence_item_id: raden er append-only, så id-en peker for alltid på den
    // ekstraksjonen som faktisk ble kontrollert. En korrigert ekstraksjon er et
    // nytt funn med en ny adresse.
    expect(extractionReviewPath('66666666-6666-4666-8666-111111111111')).toBe(
      '/extraction-review/66666666-6666-4666-8666-111111111111',
    )
  })

  it('adresserer den faglige vurderingen med den eksakte revisjonen', () => {
    // claim_revision_id og ikke claim_id: en vurdering gjelder nøyaktig den
    // formuleringen som ble lest (KNOWLEDGE_MODEL.md §19.3).
    expect(claimReviewPath('33333333-3333-4333-8333-111111111111')).toBe(
      '/review/33333333-3333-4333-8333-111111111111',
    )
  })

  it('mønstrene og byggerne beskriver samme adresser', () => {
    // Et mønster som drifter fra byggeren gir lenker ruteren ikke kjenner.
    expect(ROUTE_PATTERNS.drug).toBe('/drugs/:drugSlug')
    expect(ROUTE_PATTERNS.topic).toBe('/topics/:topicSlug')
    expect(ROUTE_PATTERNS.claimEvidence).toBe('/claims/:claimId/evidence')
    expect(ROUTE_PATTERNS.source).toBe('/sources/:sourceId')
    expect(ROUTE_PATTERNS.sourceNew).toBe(newSourcePath())
    expect(ROUTE_PATTERNS.evidenceNew).toBe(newEvidenceItemPath())
    expect(ROUTE_PATTERNS.claimReview).toBe('/review/:claimRevisionId')
    expect(ROUTE_PATTERNS.extractionReviewQueue).toBe(extractionReviewQueuePath())
    expect(ROUTE_PATTERNS.extractionReview).toBe('/extraction-review/:evidenceItemId')
    expect(ROUTE_PATTERNS.access).toBe(accessPath())
    expect(ROUTE_PATTERNS.home).toBe(homePath())
  })
})
