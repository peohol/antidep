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
// «Utenfor et arbeidstre» må være fastslått, ikke antatt
//
// Det ene tilfellet som slipper gjennom uten en ignore-regel, er at banen ligger
// utenfor et arbeidstre: der finnes ingen historikk å havne i. Det gjør nettopp
// den avgjørelsen til den farligste i modulen, og den kan ikke hvile på at git
// ikke svarte.
//
// `git rev-parse --show-toplevel` avslutter nemlig med **128 for alt**: både for
// «not a git repository», som betyr utenfor, og for «detected dubious ownership»,
// «invalid gitfile format» og en rettighetsfeil, som ikke betyr noe om hvor banen
// ligger. Og mangler `git` i PATH, kommer det ingen exit-kode i det hele tatt.
// Første utgave gjorde alle disse til «utenfor», og det var en fail-open
// sikkerhetsfeil funnet i teknisk review: fullteksten kunne bli skrevet i et
// arbeidstre fordi git på *denne* maskinen ikke kunne svare, og så commitet fra
// en maskin der den kan.
//
// Utfallet er derfor tredelt, og «utenfor» krever et **filsystemfaktum** og ikke
// bare en feilmelding: at ingen forelder har en `.git`. Det er uavhengig av
// locale, av konfigurasjon og av om git finnes.
//
//   inside    git svarte med en rot. Banen må være ignorert.
//   outside   git svarte ikke, OG ingen forelder har en `.git`. Tillatt.
//   unknown   git svarte ikke, men en forelder HAR en `.git` — eller oppslaget
//             lot seg ikke utføre. Avvist.
//
// Et bart repo har ingen `.git` og blir dermed `outside`. Det er riktig nok: uten
// et arbeidstre finnes det ingen `git add` som kan ta filen med seg.
// ============================================================================

import { execFileSync } from 'node:child_process'
import { statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

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

/** Hvor banen ligger i forhold til et git-arbeidstre. */
export type WorkTreeVerdict =
  | { readonly kind: 'inside'; readonly root: string }
  | { readonly kind: 'outside' }
  | { readonly kind: 'unknown'; readonly reason: string }

/**
 * Roten git oppgir for banen, eller `null` når git ikke svarte.
 *
 * `null` sier **ingenting** om hvor banen ligger — se hodekommentaren. Bruk
 * `workTreeVerdict` for det spørsmålet; denne er bare git-kallet.
 *
 * Oppslaget gjøres fra den nærmeste forelderen som er en **katalog som finnes**:
 * `git -C` krever nettopp det, og banen vi spør om er som regel en fil — enten
 * en som ikke er opprettet ennå, eller en som ligger der fra en tidligere
 * kjøring. Kravet om at det er en katalog, og ikke bare at den finnes, er et
 * reviewfunn: for en fil ble `git -C <fil>` kalt, som gir «Not a directory», og
 * en `prompt.txt` som alt lå der — altså omkjøringstilfellet — slapp gjennom.
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

/**
 * Den nærmeste forelderen som har en `.git`, eller hvorfor vi ikke vet.
 *
 * Et filsystemfaktum, og det er hele poenget: det gjelder uavhengig av locale,
 * av git-konfigurasjon og av om git i det hele tatt er installert. En katalog vi
 * ikke får lese, gir `unknown` framfor «ingen `.git` her» — ellers ville en
 * rettighetsfeil blitt lest som et bevis for at banen er trygg.
 */
function nearestDotGit(path: string): { found: string | null } | { unknown: string } {
  let probe = resolve(path)
  for (;;) {
    try {
      statSync(join(probe, '.git'))
      return { found: probe }
    } catch (cause) {
      const code = (cause as { code?: string }).code
      if (code !== 'ENOENT' && code !== 'ENOTDIR') {
        return {
          unknown:
            `kunne ikke lese ${join(probe, '.git')} (${code ?? 'ukjent feil'}), så det er ikke ` +
            'fastslått at banen ligger utenfor et arbeidstre',
        }
      }
    }
    const parent = dirname(probe)
    if (parent === probe) {
      return { found: null }
    }
    probe = parent
  }
}

/**
 * Hvor banen ligger, med «utenfor» som en fastslått konklusjon og ikke en
 * antakelse. Se hodekommentaren for hvorfor de tre utfallene er forskjellige.
 */
export function workTreeVerdict(path: string): WorkTreeVerdict {
  const root = gitWorkTreeRoot(path)
  if (root !== null) {
    return { kind: 'inside', root }
  }
  const dotGit = nearestDotGit(path)
  if ('unknown' in dotGit) {
    return { kind: 'unknown', reason: dotGit.unknown }
  }
  if (dotGit.found !== null) {
    return {
      kind: 'unknown',
      reason:
        `git kunne ikke oppgi arbeidstreet for banen, men ${join(dotGit.found, '.git')} finnes. ` +
        'Banen kan dermed ligge i et arbeidstre som en annen maskin, eller et annet oppsett, ' +
        'kan commite fra',
    }
  }
  return { kind: 'outside' }
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
  readonly workTree?: (path: string) => WorkTreeVerdict
  readonly ignores?: (path: string, workTree?: string) => boolean
}

/**
 * Avviser en bane git kunne tatt med i en commit.
 *
 * `what` er hva banen bærer, og står i avvisningen: den skal si hvorfor nettopp
 * denne filen ikke får ligge der, og ikke bare at en regel slo til.
 */
export function assertNotCommittable(path: string, what: string, ports: GitPathPorts = {}): void {
  const verdict = (ports.workTree ?? workTreeVerdict)(path)
  if (verdict.kind === 'outside') {
    return
  }
  if (verdict.kind === 'unknown') {
    throw new CommittablePathRefused(
      `Det er ikke fastslått at ${path} ligger utenfor et git-arbeidstre: ${verdict.reason}. ` +
        `${what}, og filen skrives bare til en bane som ikke kan bli med i en commit. Velg en ` +
        'katalog som er ignorert, eller en som sikkert ligger utenfor et arbeidstre. Ingenting ' +
        'er skrevet.',
    )
  }
  const ignores = ports.ignores ?? gitIgnores
  if (ignores(resolve(path), verdict.root)) {
    return
  }
  throw new CommittablePathRefused(
    `${path} ligger i git-arbeidstreet ${verdict.root} uten å være ignorert, og ${what}. ` +
      'Filen skrives bare til en bane som ikke kan bli med i en commit. Velg en katalog ' +
      'utenfor arbeidstreet, eller en som er ignorert. Ingenting er skrevet.',
  )
}
