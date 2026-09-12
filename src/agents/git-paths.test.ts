import { execFileSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

import {
  assertNotCommittable,
  CommittablePathRefused,
  gitIgnores,
  gitWorkTreeRoot,
} from './git-paths.ts'

// ============================================================================
// Hva git ser, og hva som derfor ikke får skrives i arbeidstreet
//
// Kontrollene prøves mot **repoets egne ignore-regler** der de kan, framfor mot
// en oppdiktet katalog: det er de reglene som faktisk avgjør om en fil kan bli
// med i en commit, og en prøve mot en fiksjon ville ikke fanget at en regel
// mangler.
//
// Regresjonen er konkret. Kommandoen som sto dokumentert for den
// kildeomfattende fraværskontrollen, la spørsmålet — som inneholder hele
// fulltekstartikkelen ordrett — i `fravaer` i repoets rot. Ingen regel ignorerte
// den katalogen, så ett `git add -A` ville lagt artikkelen i historikken, og
// Antidep har ikke rett til å redistribuere den
// (`docs/EVIDENCE_PIPELINE.md` §14).
// ============================================================================

const opprettede: string[] = []
/** Baner prøvene legger i selve arbeidstreet, og som må ryddes bort igjen. */
const iRepoet: string[] = []

function midlertidigKatalog(): string {
  const katalog = mkdtempSync(join(tmpdir(), 'antidep-git-'))
  opprettede.push(katalog)
  return katalog
}

afterEach(() => {
  for (const katalog of [...opprettede.splice(0), ...iRepoet.splice(0)]) {
    execFileSync('rm', ['-rf', katalog])
  }
})

describe('gitIgnores', () => {
  it('kjenner igjen repoets egen ignorerte miljøfil, og den sporede malen', () => {
    // Kilden er `.gitignore` i repoet: `*.local` ignorerer den første, og
    // `!.env.example` tar den andre eksplisitt tilbake.
    expect(gitIgnores('.env.agent.local')).toBe(true)
    expect(gitIgnores('.env.example')).toBe(false)
  })

  it('svarer nei framfor å anta, utenfor et git-arbeidstre', () => {
    // Feiler lukket: uten et arbeidstre kan git ikke svare, og da skal
    // ingenting skrives. Katalogen ligger under /tmp, som ikke er i repoet.
    const utenfor = join(midlertidigKatalog(), 'ikke-et-repo')
    mkdirSync(utenfor)
    expect(gitIgnores(join(utenfor, '.env.agent.local'))).toBe(false)
  })

  it('svarer om reglene i det arbeidstreet banen hører til, når det oppgis', () => {
    // Uten `workTree` spør den om prosessens eget arbeidstre, og en absolutt
    // bane kan ligge i et annet. Oppgitt arbeidstre er det som gjør svaret
    // meningsfullt for en bane kalleren allerede har plassert.
    const repo = resolve('.')
    expect(gitIgnores(resolve('documents/eksempel.pdf'), repo)).toBe(true)
    expect(gitIgnores(resolve('documents/README.md'), repo)).toBe(false)
  })
})

describe('gitWorkTreeRoot', () => {
  it('finner repoets rot for en bane i repoet', () => {
    expect(gitWorkTreeRoot('src/agents')).toBe(resolve('.'))
  })

  it('finner roten også for en katalog som ikke finnes ennå', () => {
    // Kjøremappa er som regel ikke opprettet når kontrollen gjøres, og en
    // kontroll som bare kunne svare om eksisterende baner, ville vært ubrukelig
    // der den trengs.
    expect(gitWorkTreeRoot('fravaer/9ba56fb4/prompt.txt')).toBe(resolve('.'))
  })

  // Reviewfunn, og det var en omvei rundt hele kontrollen. Første utgave stanset
  // så snart banen fantes, og for en fil ble oppslaget da gjort med filen som
  // `git -C`-katalog: exit 128, «Not a directory», som `catch` gjorde til `null`
  // — altså «utenfor et arbeidstre». En fil som alt lå der, slapp dermed
  // gjennom.
  it('finner roten for en fil som alt finnes, og ikke bare for en som mangler', () => {
    expect(gitWorkTreeRoot('package.json')).toBe(resolve('.'))
  })

  it('svarer null utenfor et arbeidstre', () => {
    expect(gitWorkTreeRoot(midlertidigKatalog())).toBe(null)
  })
})

describe('assertNotCommittable', () => {
  const hva = 'spørsmålet inneholder hele representasjonen av kilden'

  it('avviser den dokumenterte kjøremappa i repoets rot', () => {
    // Regresjonen. `fravaer/<uuid>/prompt.txt` er ikke ignorert av noen regel i
    // repoet, og nettopp den banen sto i den dokumenterte kommandoen.
    expect(() =>
      assertNotCommittable('fravaer/9ba56fb4-fbb9-414b-899b-7296683f274d/prompt.txt', hva),
    ).toThrow(CommittablePathRefused)
    expect(() => assertNotCommittable('fravaer/x/prompt.txt', hva)).toThrow(
      /ikke være ignorert|uten å være ignorert/,
    )
  })

  // Omkjøringstilfellet, som er det normale: kommandoene er ment å kunne kjøres
  // om igjen, og da ligger `prompt.txt` der fra før. Prøven skriver filen i
  // arbeidstreet på en bane ingen regel ignorerer — nøyaktig den den gamle
  // dokumenterte kommandoen etterlot — og krever at kontrollen slår til
  // likevel. Uten at `gitWorkTreeRoot` krever en KATALOG, ble filen skrevet over
  // med fullteksten uten et pip.
  it('avviser en kjøremappe som alt bærer en prompt fra en tidligere kjøring', () => {
    const mappe = join(resolve('.'), `fravaer-prove-${randomBytes(4).toString('hex')}`)
    iRepoet.push(mappe)
    const fil = join(mappe, '9ba56fb4-fbb9-414b-899b-7296683f274d', 'prompt.txt')
    mkdirSync(dirname(fil), { recursive: true })
    writeFileSync(fil, 'en prompt fra en tidligere kjøring\n', 'utf8')

    expect(gitIgnores(fil, resolve('.'))).toBe(false)
    expect(gitWorkTreeRoot(fil)).toBe(resolve('.'))
    expect(() => assertNotCommittable(fil, hva)).toThrow(CommittablePathRefused)
  })

  it('tillater kjøremappa under assignments, som er sporet men ignorerer alt under seg', () => {
    // Skillet kontrollen hviler på: `assignments` er selv ikke ignorert, mens
    // alt under den er. En kontroll på katalogen framfor på filen ville avvist
    // den plasseringen resten av pipelinen bruker.
    expect(gitIgnores('assignments')).toBe(false)
    expect(() => assertNotCommittable('assignments/kjoring/9ba56fb4/prompt.txt', hva)).not.toThrow()
  })

  it('tillater en bane utenfor et arbeidstre', () => {
    // Kjedeprøven og Routinene legger kjøremappa under tmp. Der finnes ingen
    // historikk å havne i, og det er det ene tilfellet som slipper gjennom uten
    // en ignore-regel.
    expect(() =>
      assertNotCommittable(join(midlertidigKatalog(), '9ba56fb4', 'prompt.txt'), hva),
    ).not.toThrow()
  })

  it('avviser når git ikke kan svare om en bane som ligger i et arbeidstre', () => {
    // Fail-closed. Samme avveining som i `agent-env-file.ts`: å skrive fordi
    // kontrollen ikke lot seg utføre, er den motsatte avveiningen av den
    // kontrollen finnes for.
    expect(() =>
      assertNotCommittable('hvor-som-helst/prompt.txt', hva, {
        workTree: () => '/et/arbeidstre',
        ignores: () => false,
      }),
    ).toThrow(CommittablePathRefused)
  })

  it('sier i avvisningen hva banen bærer, og at ingenting er skrevet', () => {
    expect(() =>
      assertNotCommittable('fravaer/x/prompt.txt', hva, {
        workTree: () => '/et/arbeidstre',
        ignores: () => false,
      }),
    ).toThrow(new RegExp(`${hva}[\\s\\S]*Ingenting er skrevet`))
  })
})
