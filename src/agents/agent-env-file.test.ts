import { execFileSync } from 'node:child_process'
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

import { EnvFileRefused, gitIgnores, writeAgentEnvFile } from './agent-env-file.ts'

// ============================================================================
// Miljøfilen legitimasjonen skrives til
//
// Begge kontrollene her er regresjonstester på funn fra teknisk review av
// MVP_IMPLEMENTATION_PLAN.md §74.34:
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
// Begge er mutasjonstestet: uten `fchmod`-veien feller den første testen
// rettelsen, og uten gitignore-vilkåret feller den andre den.
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
})
