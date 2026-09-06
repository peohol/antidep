import { describe, expect, it } from 'vitest'

import { planMigrations, type RemoteMigration } from './migration-plan.ts'

// ============================================================================
// Planen `scripts/deploy-migrations.sh` handler på
//
// Hullkontrollen er en regresjonstest på et funn fra teknisk review av
// MVP_IMPLEMENTATION_PLAN.md §74.34: første utgave av skriptet behandlet enhver
// lokal migrasjon uten en rad som «manglende», så registrert historikk `A, C`
// mot lokal `A, B, C` ville kjørt `B` etter `C`. Mutasjonstestet — uten
// hullkontrollen feller «hull i historikken» rettelsen.
// ============================================================================

const A = '20260101090000_forste.sql'
const B = '20260102090000_andre.sql'
const C = '20260103090000_tredje.sql'

const LOCAL = [A, B, C]

function rad(file: string): RemoteMigration {
  return { version: file.slice(0, 14), name: file.slice(15, -4) }
}

describe('planMigrations', () => {
  it('tar halen når historikken er et sammenhengende prefiks', () => {
    const plan = planMigrations(LOCAL, [rad(A)])

    expect(plan.problems).toEqual([])
    expect(plan.pending.map((m) => m.file)).toEqual([B, C])
    expect(plan.localCount).toBe(3)
    expect(plan.appliedCount).toBe(1)
  })

  it('har ingenting å gjøre når alt er kjørt', () => {
    const plan = planMigrations(LOCAL, [rad(A), rad(B), rad(C)])

    expect(plan.problems).toEqual([])
    expect(plan.pending).toEqual([])
  })

  it('kjører alt mot et tomt prosjekt, i tidsstempelrekkefølge', () => {
    const plan = planMigrations([C, A, B], [])

    expect(plan.problems).toEqual([])
    expect(plan.pending.map((m) => m.file)).toEqual([A, B, C])
  })

  it('avviser et hull i historikken før noe kjøres', () => {
    // Registrert `A, C` mot lokal `A, B, C`: `B` mangler, men `C` er kjørt.
    const plan = planMigrations(LOCAL, [rad(A), rad(C)])

    expect(plan.pending).toEqual([])
    expect(plan.problems).toHaveLength(1)
    expect(plan.problems[0]).toContain('20260102090000')
    expect(plan.problems[0]).toContain('hull')
  })

  it('avviser en versjon i prosjektet som ikke finnes i repoet', () => {
    const plan = planMigrations(LOCAL, [rad(A), { version: '20260104090000', name: 'ukjent' }])

    expect(plan.pending).toEqual([])
    expect(plan.problems.join(' ')).toContain('finnes ikke i repoet')
  })

  it('avviser når navnet på en kjørt versjon ikke stemmer med filen', () => {
    const plan = planMigrations(LOCAL, [{ version: '20260101090000', name: 'noe_annet' }])

    expect(plan.pending).toEqual([])
    expect(plan.problems.join(' ')).toContain('historikken heter')
  })

  it('avviser et filnavn som ikke har versjonsformen', () => {
    const plan = planMigrations([A, 'uten_versjon.sql'], [])

    expect(plan.pending).toEqual([])
    expect(plan.problems.join(' ')).toContain('filnavnet har ikke formen')
  })

  it('avviser to filer med samme versjonsnummer', () => {
    const plan = planMigrations([A, '20260101090000_duplikat.sql'], [])

    expect(plan.pending).toEqual([])
    expect(plan.problems.join(' ')).toContain('samme versjonsnummer')
  })

  it('melder hullet selv når den manglende er den aller eldste', () => {
    const plan = planMigrations(LOCAL, [rad(B), rad(C)])

    expect(plan.pending).toEqual([])
    expect(plan.problems.join(' ')).toContain('20260101090000')
  })
})
