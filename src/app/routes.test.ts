import { describe, expect, it } from 'vitest'
import {
  AGENT_WORK_PATH,
  CANDIDATE_PATH,
  CANDIDATE_QUEUE_PATH,
  HOME_PATH,
  PUBLISHED_CLAIM_PATH,
  PUBLISHED_PATH,
  agentWorkPath,
  candidatePath,
  candidateQueuePath,
  homePath,
  publishedClaimPath,
  publishedPath,
} from './routes'

describe('routes', () => {
  it('har forsiden og klinikerflaten som de eneste inngangene', () => {
    expect(HOME_PATH).toBe('/')
    expect(homePath()).toBe('/')
    expect(candidateQueuePath()).toBe('/kandidater')
    expect(CANDIDATE_QUEUE_PATH).toBe('/kandidater')
    expect(CANDIDATE_PATH).toBe('/kandidater/:candidateId')
    expect(publishedPath()).toBe('/publisert')
    expect(PUBLISHED_PATH).toBe('/publisert')
    expect(PUBLISHED_CLAIM_PATH).toBe('/publisert/:claimId')
    expect(AGENT_WORK_PATH).toBe('/agentarbeid')
    expect(agentWorkPath()).toBe('/agentarbeid')
  })

  // Agentarbeid og sluttkontroll er to forskjellige handlinger med hvert sitt
  // mandat, og de har hver sin adresse.
  it('holder agentarbeidet fra kandidatflaten og det publiserte innholdet', () => {
    expect(AGENT_WORK_PATH.startsWith(CANDIDATE_QUEUE_PATH)).toBe(false)
    expect(AGENT_WORK_PATH.startsWith(PUBLISHED_PATH)).toBe(false)
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
    for (const path of [
      HOME_PATH,
      CANDIDATE_QUEUE_PATH,
      CANDIDATE_PATH,
      PUBLISHED_PATH,
      PUBLISHED_CLAIM_PATH,
      AGENT_WORK_PATH,
    ]) {
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
})
