export const HOME_PATH = '/' as const

/**
 * Klinikerflaten: køen av kandidater, og én kandidat.
 *
 * Navnene er norske og nye med vilje. Adressene til den gamle mikroreviewflyten
 * kommer ikke tilbake: Antidep 2 gjeninnfører ikke en menneskelig
 * felt-for-felt-kontroll av mellomprodukter — det som vurderes her, er det
 * ferdige produktet, i den samme visningen klinikeren får.
 * `scripts/verify-repo.sh` håndhever at de gamle adressene holder seg borte, og
 * `routes.test.ts` gjentar kravet på denne siden.
 */
export const CANDIDATE_QUEUE_PATH = '/kandidater' as const
export const CANDIDATE_PATH = '/kandidater/:candidateId' as const

export function homePath(): string {
  return HOME_PATH
}

export function candidateQueuePath(): string {
  return CANDIDATE_QUEUE_PATH
}

/** Adressen til én kandidat. Id-en URL-kodes: den er data, ikke en sti. */
export function candidatePath(candidateId: string): string {
  return `${CANDIDATE_QUEUE_PATH}/${encodeURIComponent(candidateId)}`
}
