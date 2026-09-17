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

/**
 * Den åpne arbeidsoversikten: hva Antidep arbeider med.
 *
 * Erstatter den tekniske flaten `/agentarbeid`, som ba mennesker velge
 * KI-tjeneste, registrere en kjører og frakte filer mellom Antidep og et
 * chatvindu. Ingen av delene var klinisk eller redaksjonelt arbeid (issue #99).
 *
 * Adressen krever ingen innlogging, og det er hele poenget: oversikten viser
 * hva Antidep holder på med, i klinikerens språk, uten én eneste intern verdi.
 * Selve tilstanden kommer fra databasen og ikke fra flaten, slik at historikken
 * overlever en sideoppfriskning og en ny sesjon.
 */
export const WORK_BOARD_PATH = '/arbeid' as const

/**
 * Fulltekstinnboksen: artiklene Antidep mangler, og opplastingen av dem.
 *
 * Egen adresse og ikke en del av arbeidsoversikten: den ene er åpen og
 * read-only, den andre krever mandat og er stedet et menneske faktisk gjør noe.
 * Det som gjøres der, er redaksjonelt — å kjenne igjen hvilken artikkel som
 * mangler, og velge riktig fil.
 */
export const FULL_TEXT_INBOX_PATH = '/fulltekst' as const

/**
 * Bestillingen: å be Antidep om en artikkel som mangler.
 *
 * Egen adresse og ikke en del av innboksen, fordi det er to forskjellige
 * handlinger med to forskjellige mandater. Å avgjøre *hvilken* artikkel Antidep
 * trenger og hva et funn fra den kan gjelde, er en redaksjonell avgjørelse og
 * krever redaktørmandat; å velge riktig PDF for en artikkel som allerede er
 * bestilt, gjør en editor eller en admin (issue #101, punkt 3).
 */
export const FULL_TEXT_REQUEST_PATH = '/be-om-artikkel' as const

/**
 * Den tekniske problemoversikten: driftens egen side.
 *
 * Krever admin-mandat, og sier bare hvilket område som har problemer, når det
 * oppsto og om det fortsatt pågår. Den rå diagnosen finnes, men bare i
 * databasen, der Claude Code og ChatGPT kan lese den (issue #99, punkt 6).
 */
export const TECHNICAL_PROBLEMS_PATH = '/tekniske-problemer' as const

export function homePath(): string {
  return HOME_PATH
}

export function workBoardPath(): string {
  return WORK_BOARD_PATH
}

export function fullTextInboxPath(): string {
  return FULL_TEXT_INBOX_PATH
}

export function fullTextRequestPath(): string {
  return FULL_TEXT_REQUEST_PATH
}

export function technicalProblemsPath(): string {
  return TECHNICAL_PROBLEMS_PATH
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
