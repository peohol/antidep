import { execFileSync } from 'node:child_process'
import { chmodSync, existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

import { EnvFileRefused, temporaryEnvPath, writeAgentEnvFile } from './agent-env-file.ts'
import { gitIgnores } from './git-paths.ts'

// ============================================================================
// Miljøfilen legitimasjonen skrives til
//
// Kontrollene her er regresjonstester på tre funn fra teknisk review av
// MVP_IMPLEMENTATION_PLAN.md §74.34, alle om hvor hemmeligheten kunne bli
// liggende:
//
// 1. `writeFileSync(..., { mode: 0o600 })` setter bare modus på en **ny** fil.
//    Standardtilfellet er at miljøfilen finnes fra før, med URL og publishable
//    key i seg, og da beholdt den modusen den hadde — så en `0644`-fil ville
//    fått hemmeligheten skrevet inn i seg mens koden så ut til å love `0600`.
//
// 2. `--write-env <fil>` tar imot en vilkårlig bane, mens både skriptet og
//    dokumentasjonen lover at målet er gitignorert. Uten en kontroll kunne
//    hemmeligheten skrives rett i en sporet fil, for eksempel `.env.example`.
//
// 3. Tempfilen rettelsen på punkt 1 innførte, bærer den samme hemmeligheten
//    fram til `rename`, og het først `..env.agent.local.<token>.tmp` — som
//    ingen regel i `.gitignore` matcher. En krasj i det vinduet ville etterlatt
//    hemmeligheten i en sporbar fil.
//
// Alle tre er mutasjonstestet: uten `fchmod`-veien feller den første testen
// rettelsen, uten gitignore-vilkåret på målet feller de neste to den, og med
// det innledende punktumet tilbake i tempnavnet feller tempfil-testen den.
// ============================================================================

const opprettede: string[] = []

function midlertidigKatalog(): string {
  const katalog = mkdtempSync(join(tmpdir(), 'antidep-env-'))
  opprettede.push(katalog)
  return katalog
}

afterEach(() => {
  for (const katalog of opprettede.splice(0)) {
    execFileSync('rm', ['-rf', katalog])
  }
})

/** Filens rettigheter som oktal tekst, slik `stat -c %a` viser dem. */
function modus(fil: string): string {
  return (statSync(fil).mode & 0o777).toString(8)
}

const IGNORERER_ALT = () => true

describe('writeAgentEnvFile', () => {
  it('gir en fil som fantes fra før med for vide rettigheter, modus 0600', () => {
    const fil = join(midlertidigKatalog(), '.env.agent.local')
    writeFileSync(fil, 'ANTIDEP_SUPABASE_URL=https://eksempel.supabase.co\n')
    chmodSync(fil, 0o644)
    expect(modus(fil)).toBe('644')

    writeAgentEnvFile(fil, { ANTIDEP_AGENT_SECRET: 'hemmelig' }, { ignores: IGNORERER_ALT })

    expect(modus(fil)).toBe('600')
    expect(readFileSync(fil, 'utf8')).toContain('ANTIDEP_AGENT_SECRET=hemmelig')
  })

  it('gir en fil som ikke fantes fra før, modus 0600', () => {
    const fil = join(midlertidigKatalog(), '.env.agent.local')

    writeAgentEnvFile(fil, { ANTIDEP_AGENT_SECRET: 'hemmelig' }, { ignores: IGNORERER_ALT })

    expect(modus(fil)).toBe('600')
  })

  it('lar de andre variablene i filen stå, og erstatter dem den setter', () => {
    const fil = join(midlertidigKatalog(), '.env.agent.local')
    writeFileSync(
      fil,
      [
        'ANTIDEP_SUPABASE_URL=https://eksempel.supabase.co',
        'ANTIDEP_SUPABASE_PUBLISHABLE_KEY=sb_publishable_eksempel',
        'ANTIDEP_AGENT_SECRET=utgått',
        '',
      ].join('\n'),
    )

    writeAgentEnvFile(
      fil,
      {
        ANTIDEP_AGENT_IDENTITY_KEY: 'agent-identity:extraction-verification-01',
        ANTIDEP_AGENT_SECRET: 'ny',
      },
      { ignores: IGNORERER_ALT },
    )

    const linjer = readFileSync(fil, 'utf8').split('\n').filter(Boolean)
    expect(linjer).toEqual([
      'ANTIDEP_SUPABASE_URL=https://eksempel.supabase.co',
      'ANTIDEP_SUPABASE_PUBLISHABLE_KEY=sb_publishable_eksempel',
      'ANTIDEP_AGENT_IDENTITY_KEY=agent-identity:extraction-verification-01',
      'ANTIDEP_AGENT_SECRET=ny',
    ])
    expect(readFileSync(fil, 'utf8')).not.toContain('utgått')
  })

  it('avviser en målfil git ikke ignorerer, uten å skrive hemmeligheten', () => {
    const fil = join(midlertidigKatalog(), '.env.example')
    writeFileSync(fil, 'ANTIDEP_AGENT_SECRET=\n')

    expect(() =>
      writeAgentEnvFile(fil, { ANTIDEP_AGENT_SECRET: 'hemmelig' }, { ignores: () => false }),
    ).toThrow(EnvFileRefused)

    expect(readFileSync(fil, 'utf8')).not.toContain('hemmelig')
  })

  it('legger ikke igjen en tempfil når målfilen avvises', () => {
    const katalog = midlertidigKatalog()
    const fil = join(katalog, '.env.example')

    expect(() =>
      writeAgentEnvFile(fil, { ANTIDEP_AGENT_SECRET: 'hemmelig' }, { ignores: () => false }),
    ).toThrow(EnvFileRefused)

    expect(execFileSync('ls', ['-A', katalog]).toString().trim()).toBe('')
  })

  it('avviser en verdi med linjeskift, framfor å dele den i to linjer', () => {
    const fil = join(midlertidigKatalog(), '.env.agent.local')

    expect(() =>
      writeAgentEnvFile(fil, { ANTIDEP_AGENT_SECRET: 'to\nlinjer' }, { ignores: IGNORERER_ALT }),
    ).toThrow(EnvFileRefused)
  })
})

describe('tempfilen hemmeligheten skrives gjennom', () => {
  // Regresjon på det tredje reviewfunnet: tempfilen bærer hemmeligheten fram
  // til `rename`, og en krasj i det vinduet etterlater den. Første utgave het
  // `..env.agent.local.<token>.tmp` — to innledende punktum — som verken
  // `.env.*` eller `*.local` matcher. Kontrollen her bruker repoets faktiske
  // ignore-regler, ikke en gjengivelse av dem.
  it('har et navn repoets egne ignore-regler faktisk fanger', () => {
    const mål = '.env.agent.local'
    const temp = temporaryEnvPath(mål, '0123456789abcdef')

    expect(temp).toBe('.env.agent.local.0123456789abcdef.tmp')
    expect(gitIgnores(mål)).toBe(true)
    expect(gitIgnores(temp)).toBe(true)

    // Navnet den hadde før rettelsen, som kontroll på at testen ville sagt fra.
    expect(gitIgnores('..env.agent.local.0123456789abcdef.tmp')).toBe(false)
  })

  it('skriver ingenting når tempbanen ikke er ignorert, selv om målet er det', () => {
    const katalog = midlertidigKatalog()
    const fil = join(katalog, '.env.agent.local')

    // Tempnavnet får et tilfeldig ledd, så stubben avviser formen framfor en
    // bestemt bane: målet slipper gjennom, tempfilen ikke.
    expect(() =>
      writeAgentEnvFile(
        fil,
        { ANTIDEP_AGENT_SECRET: 'hemmelig' },
        { ignores: (bane) => !bane.endsWith('.tmp') },
      ),
    ).toThrow(EnvFileRefused)

    expect(existsSync(fil)).toBe(false)
    expect(execFileSync('ls', ['-A', katalog]).toString().trim()).toBe('')
  })
})
