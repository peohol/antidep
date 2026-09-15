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

/**
 * Klinikerflaten: det som faktisk er publisert.
 *
 * Egne adresser, og ikke en visningsmodus på kandidatadressen: det er to
 * forskjellige ting. En kandidat er et internt, eksperimentelt utkast som krever
 * mandat å lese; et publisert innhold er det Antidep faktisk sier, og enhver
 * innlogget kliniker kan lese det (ANTIDEP_CONSTITUTION.md regel 5, 6).
 */
export const PUBLISHED_PATH = '/publisert' as const
export const PUBLISHED_CLAIM_PATH = '/publisert/:claimId' as const

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

export function publishedPath(): string {
  return PUBLISHED_PATH
}

/** Adressen til én publisert påstand. Id-en URL-kodes: den er data, ikke en sti. */
export function publishedClaimPath(claimId: string): string {
  return `${PUBLISHED_PATH}/${encodeURIComponent(claimId)}`
}
