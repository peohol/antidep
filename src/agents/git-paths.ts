// ============================================================================
// Hva git ser, og hva som derfor ikke får skrives i arbeidstreet
//
// To ledd i pipelinen skriver filer som ikke under noen omstendighet skal kunne
// bli med i en commit, og begge trenger det samme oppslaget:
//
//   agentlegitimasjonen   `agent-env-file.ts`. En hemmelighet i historikken er
//                         en lekket hemmelighet.
//   kildeteksten          `absence-review-job.ts`. `prompt.txt` inneholder hele
//                         den reproduserte representasjonen av kilden — i praksis
//                         fulltekstartikkelen, ordrett — og Antidep har ikke rett
//                         til å redistribuere den
//                         (`docs/EVIDENCE_PIPELINE.md` §14, `documents/README.md`).
//
// Oppslaget ligger her framfor i hver av dem, fordi regelen er den samme og fordi
// modulen som skriver hemmeligheter ikke skal måtte importeres av modulen som
// skriver kildetekst for å låne den.
//
// ----------------------------------------------------------------------------
// Kontrollen gjelder banen filen faktisk får, ikke katalogen over den
//
// `assignments/` er en **sporet** katalog med en `.gitignore` i seg: katalogen er
// ikke ignorert, mens alt under den er det. En kontroll på katalogen ville derfor
// avvist nettopp den plasseringen resten av pipelinen bruker. Spør om filen.
//
// ----------------------------------------------------------------------------
// Utenfor et arbeidstre er det ene tilfellet uten en ignore-regel
//
//   utenfor et arbeidstre            Tillatt. Det finnes ingen historikk å havne
//                                    i. Det er plasseringen kjedeprøven og
//                                    Routinene bruker (`mkdtemp` under tmp).
//   i et arbeidstre, ignorert        Tillatt.
//   i et arbeidstre, ikke ignorert   Avvist, og ingenting skrives.
//   git svarer ikke om en bane
//   i et arbeidstre                  Avvist. Å skrive fordi kontrollen ikke lot
//                                    seg utføre, er den motsatte avveiningen av
//                                    den kontrollen finnes for.
//
// Det første slipper gjennom fordi risikoen der ikke finnes, ikke fordi den er
// mindre.
//
// Feilen er ikke hypotetisk: kommandoen som sto dokumentert for den
// kildeomfattende fraværskontrollen, skrev spørsmålet til `fravaer` i repoets
// rot — en katalog ingen regel ignorerte, og derfra er veien inn i historikken
// ett `git add -A`.
// ============================================================================

import { execFileSync } from 'node:child_process'
import { statSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

/** Om banen er en katalog som finnes. En bane som ikke finnes, er `false`. */
function isExistingDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

/**
 * Sier om git faktisk ignorerer banen.
 *
 * Feiler lukket: enhver annen utgang enn «ja, ignorert» er `false`.
 * `git check-ignore` avslutter med 0 for en ignorert bane, 1 for en som ikke
 * er det, og 128 når den ikke kan svare i det hele tatt.
 *
 * `workTree` finnes fordi `check-ignore` bare kan svare om baner i det
 * arbeidstreet den kjøres i: en bane utenfor prosessens eget arbeidstre gir 128,
 * som her blir `false`. Kalleren som allerede vet hvilket arbeidstre banen hører
 * til, oppgir det, og får da et svar om nettopp de ignore-reglene som gjelder
 * der. Utelates det, gjelder prosessens eget arbeidstre som før.
 */
export function gitIgnores(path: string, workTree?: string): boolean {
  const where = workTree === undefined ? [] : ['-C', workTree]
  try {
    execFileSync('git', [...where, 'check-ignore', '--quiet', '--', path], { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

/**
 * Roten av arbeidstreet banen hører til, eller `null` når den ikke hører til et.
 *
 * Slås opp fra den nærmeste forelderen som er en **katalog som finnes**:
 * `git -C` krever nettopp det, og banen vi spør om er som regel en fil — enten
 * en som ikke er opprettet ennå, eller en som ligger der fra en tidligere
 * kjøring. Et `null` dekker også at git ikke finnes på maskinen; da er det
 * heller ingen som kan commite derfra.
 *
 * **Kravet om at det er en katalog, ikke bare at den finnes, er et reviewfunn —
 * og det var en omvei rundt hele kontrollen.** Første utgave stanset så snart
 * banen fantes, og for en fil ble `probe` da filen selv. `git -C <fil>`
 * avslutter med 128 og «Not a directory», `catch` gjorde det til `null`, og
 * `assertNotCommittable` leste det som «utenfor et arbeidstre». En
 * `fravaer/<id>/prompt.txt` som alt lå der — altså nøyaktig tilfellet
 * kommandoene er ment å kunne kjøres om igjen i, og nøyaktig filen den gamle
 * dokumenterte kommandoen etterlot — ble dermed skrevet over med fullteksten
 * uten at kontrollen slo til.
 */
export function gitWorkTreeRoot(path: string): string | null {
  let probe = resolve(path)
  while (!isExistingDirectory(probe)) {
    const parent = dirname(probe)
    if (parent === probe) {
      return null
    }
    probe = parent
  }
  try {
    const root = execFileSync('git', ['-C', probe, 'rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim()
    return root === '' ? null : root
  } catch {
    return null
  }
}

/** Skrivingen ble avvist før noe ble skrevet. */
export class CommittablePathRefused extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'CommittablePathRefused'
  }
}

/** Byttes ut i test. Standard er de ekte git-oppslagene. */
export interface GitPathPorts {
  readonly workTree?: (path: string) => string | null
  readonly ignores?: (path: string, workTree?: string) => boolean
}

/**
 * Avviser en bane git kunne tatt med i en commit.
 *
 * `what` er hva banen bærer, og står i avvisningen: den skal si hvorfor nettopp
 * denne filen ikke får ligge der, og ikke bare at en regel slo til.
 */
export function assertNotCommittable(path: string, what: string, ports: GitPathPorts = {}): void {
  const workTree = (ports.workTree ?? gitWorkTreeRoot)(path)
  if (workTree === null) {
    return
  }
  const ignores = ports.ignores ?? gitIgnores
  if (ignores(resolve(path), workTree)) {
    return
  }
  throw new CommittablePathRefused(
    `${path} ligger i git-arbeidstreet ${workTree} uten å være ignorert, og ${what}. ` +
      'Filen skrives bare til en bane som ikke kan bli med i en commit. Velg en katalog ' +
      'utenfor arbeidstreet, eller en som er ignorert. Ingenting er skrevet.',
  )
}
