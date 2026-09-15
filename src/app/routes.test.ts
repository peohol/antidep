import { describe, expect, it } from 'vitest'
import {
  CANDIDATE_PATH,
  CANDIDATE_QUEUE_PATH,
  HOME_PATH,
  candidatePath,
  candidateQueuePath,
  homePath,
} from './routes'

describe('routes', () => {
  it('har forsiden og klinikerflaten som de eneste inngangene', () => {
    expect(HOME_PATH).toBe('/')
    expect(homePath()).toBe('/')
    expect(candidateQueuePath()).toBe('/kandidater')
    expect(CANDIDATE_QUEUE_PATH).toBe('/kandidater')
    expect(CANDIDATE_PATH).toBe('/kandidater/:candidateId')
  })

  // Adressene til den gamle mikroreviewflyten skal ikke komme tilbake, heller
  // ikke som et prefiks. `scripts/verify-repo.sh` håndhever det samme i CI.
  it('gjenbruker ingen adresse fra den gamle reviewflyten', () => {
    for (const path of [HOME_PATH, CANDIDATE_QUEUE_PATH, CANDIDATE_PATH]) {
      expect(path).not.toContain('/review')
      expect(path).not.toContain('/extraction-review')
    }
  })

  it('URL-koder kandidat-id-en, fordi den er data og ikke en sti', () => {
    expect(candidatePath('11111111-1111-4111-8111-111111111111')).toBe(
      '/kandidater/11111111-1111-4111-8111-111111111111',
    )
    expect(candidatePath('../annet')).toBe('/kandidater/..%2Fannet')
  })
})
