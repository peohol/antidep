import { describe, expect, it } from 'vitest'
import {
  CANDIDATE_PATH,
  CANDIDATE_QUEUE_PATH,
  CLAIM_REVISION_PATH,
  CLAIM_REVISION_QUEUE_PATH,
  FULL_TEXT_INBOX_PATH,
  HOME_PATH,
  MONOGRAPH_EDITION_PATH,
  MONOGRAPH_PATH,
  PUBLISHED_CLAIM_PATH,
  PUBLISHED_PATH,
  TECHNICAL_PROBLEMS_PATH,
  WORK_BOARD_PATH,
  candidatePath,
  candidateQueuePath,
  claimRevisionPath,
  claimRevisionQueuePath,
  fullTextInboxPath,
  homePath,
  monographEditionPath,
  monographPath,
  publishedClaimPath,
  publishedPath,
  technicalProblemsPath,
  workBoardPath,
} from './routes'

const ALL_PATHS = [
  HOME_PATH,
  CANDIDATE_QUEUE_PATH,
  CANDIDATE_PATH,
  PUBLISHED_PATH,
  PUBLISHED_CLAIM_PATH,
  WORK_BOARD_PATH,
  FULL_TEXT_INBOX_PATH,
  CLAIM_REVISION_QUEUE_PATH,
  CLAIM_REVISION_PATH,
  MONOGRAPH_PATH,
  MONOGRAPH_EDITION_PATH,
  TECHNICAL_PROBLEMS_PATH,
] as const

describe('routes', () => {
  it('har forsiden, klinikerflaten og de tre nye flatene som de eneste inngangene', () => {
    expect(HOME_PATH).toBe('/')
    expect(homePath()).toBe('/')
    expect(candidateQueuePath()).toBe('/kandidater')
    expect(CANDIDATE_QUEUE_PATH).toBe('/kandidater')
    expect(CANDIDATE_PATH).toBe('/kandidater/:candidateId')
    expect(publishedPath()).toBe('/publisert')
    expect(PUBLISHED_PATH).toBe('/publisert')
    expect(PUBLISHED_CLAIM_PATH).toBe('/publisert/:claimId')
    expect(WORK_BOARD_PATH).toBe('/arbeid')
    expect(workBoardPath()).toBe('/arbeid')
    expect(FULL_TEXT_INBOX_PATH).toBe('/fulltekst')
    expect(fullTextInboxPath()).toBe('/fulltekst')
    expect(TECHNICAL_PROBLEMS_PATH).toBe('/tekniske-problemer')
    expect(technicalProblemsPath()).toBe('/tekniske-problemer')
    expect(CLAIM_REVISION_QUEUE_PATH).toBe('/ny-evidens')
    expect(claimRevisionQueuePath()).toBe('/ny-evidens')
    expect(CLAIM_REVISION_PATH).toBe('/ny-evidens/:reference')
    expect(MONOGRAPH_PATH).toBe('/monografi')
    expect(monographPath()).toBe('/monografi')
    expect(MONOGRAPH_EDITION_PATH).toBe('/monografi/:reference')
  })

  // Den tekniske agentarbeidsflaten er avviklet. Adressen skal ikke komme
  // tilbake, heller ikke som et prefiks: alt et menneske gjorde der — velge
  // KI-tjeneste, registrere en kjører, laste ned en oppgave, laste opp et svar —
  // var teknisk arbeid som ikke hører hjemme i produktet (issue #99).
  // `scripts/verify-repo.sh` håndhever det samme i CI.
  it('gjeninnfører ikke den tekniske agentarbeidsflaten', () => {
    for (const path of ALL_PATHS) {
      expect(path).not.toContain('/agentarbeid')
    }
  })

  // Den åpne oversikten, fulltekstinnboksen og problemoversikten er tre
  // forskjellige handlinger med hvert sitt mandat, og de har hver sin adresse.
  it('holder de tre nye flatene fra hverandre og fra klinikerflaten', () => {
    const distinct = [
      WORK_BOARD_PATH,
      FULL_TEXT_INBOX_PATH,
      CLAIM_REVISION_QUEUE_PATH,
      MONOGRAPH_PATH,
      TECHNICAL_PROBLEMS_PATH,
      CANDIDATE_QUEUE_PATH,
      PUBLISHED_PATH,
    ]
    expect(new Set(distinct).size).toBe(distinct.length)
    for (const one of distinct) {
      for (const other of distinct) {
        if (one !== other) {
          expect(one.startsWith(`${other}/`)).toBe(false)
        }
      }
    }
  })

  // Kandidaten og det publiserte innholdet er to forskjellige ting, og de har
  // to forskjellige adresser: den ene er et internt utkast som krever mandat,
  // den andre er det Antidep faktisk sier.
  it('holder kandidatadressene og de publiserte adressene fra hverandre', () => {
    expect(PUBLISHED_PATH.startsWith(CANDIDATE_QUEUE_PATH)).toBe(false)
    expect(CANDIDATE_QUEUE_PATH.startsWith(PUBLISHED_PATH)).toBe(false)
  })

  // Adressene til den gamle mikroreviewflyten skal ikke komme tilbake, heller
  // ikke som et prefiks. `scripts/verify-repo.sh` håndhever det samme i CI.
  it('gjenbruker ingen adresse fra den gamle reviewflyten', () => {
    for (const path of ALL_PATHS) {
      expect(path).not.toContain('/review')
      expect(path).not.toContain('/extraction-review')
    }
  })

  it('URL-koder kandidat-id-en, fordi den er data og ikke en sti', () => {
    expect(candidatePath('11111111-1111-4111-8111-111111111111')).toBe(
      '/kandidater/11111111-1111-4111-8111-111111111111',
    )
    expect(candidatePath('../annet')).toBe('/kandidater/..%2Fannet')
    expect(publishedClaimPath('55555555-5555-4555-8555-555555555555')).toBe(
      '/publisert/55555555-5555-4555-8555-555555555555',
    )
    expect(publishedClaimPath('../annet')).toBe('/publisert/..%2Fannet')
  })

  // Håndtaket til en revisjonsoppgave er databasens eget, og det er data på
  // nøyaktig samme måte som en kandidat-id.
  it('URL-koder håndtaket til en revisjonsoppgave', () => {
    expect(claimRevisionPath('9f2c1a4b8e6d0c3a5b7f9e1d')).toBe(
      '/ny-evidens/9f2c1a4b8e6d0c3a5b7f9e1d',
    )
    expect(claimRevisionPath('../annet')).toBe('/ny-evidens/..%2Fannet')
  })

  // Håndtaket til en monografiutgave er databasens eget, av samme grunn.
  it('URL-koder håndtaket til en monografiutgave', () => {
    expect(monographEditionPath('3c7a1f5e9b2d4a6c8e0f1a3b')).toBe(
      '/monografi/3c7a1f5e9b2d4a6c8e0f1a3b',
    )
    expect(monographEditionPath('../annet')).toBe('/monografi/..%2Fannet')
  })
})
