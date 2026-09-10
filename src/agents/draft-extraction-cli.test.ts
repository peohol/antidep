// ============================================================================
// Argumentene Routine-kjøreren tar
//
// Kjøreren skal ha så få valg som mulig, og hvert av dem skal være entydig. Det
// som prøves her, er nettopp entydigheten: ett steg om gangen, kjøremappa
// utledet framfor valgt, og et ukjent valg avvist framfor ignorert — en
// skrivefeil i `--close` skulle ellers blitt en kjøring som gjorde noe annet
// enn kalleren ba om.
//
// `main()` kjøres på toppnivå i CLI-filen, så den kan ikke importeres av en
// test. Argumentlesingen ligger derfor i `cli-arguments.ts`, sammen med den de
// to verifikatorene deler, og prøves her.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { parseDraftArguments } from './cli-arguments'

describe('parseDraftArguments', () => {
  it('leser oppdraget og steget, og lar kjøremappa være den utledede', () => {
    expect(parseDraftArguments(['--assignment', 'assignments/fava-2000.json', '--open'])).toEqual({
      assignmentPath: 'assignments/fava-2000.json',
      // `null` og ikke en utledet sti: utledningen hører til kjøremappa, og
      // prøves der (`drafting-job.test.ts`).
      runDirectory: null,
      step: 'open',
    })
  })

  it('lar kjøremappa overstyres når noen trenger det', () => {
    const options = parseDraftArguments([
      '--assignment',
      'assignments/fava-2000.json',
      '--run',
      '/tmp/kjoring',
      '--close',
    ])
    expect(options).toMatchObject({ runDirectory: '/tmp/kjoring', step: 'close' })
  })

  it('leser --status', () => {
    expect(parseDraftArguments(['--assignment', 'a.json', '--status'])).toMatchObject({
      step: 'status',
    })
  })

  it('krever oppdraget', () => {
    expect(() => parseDraftArguments(['--open'])).toThrow(/--assignment er påkrevd/)
  })

  it('krever et steg', () => {
    expect(() => parseDraftArguments(['--assignment', 'a.json'])).toThrow(/--open, --close/)
  })

  it('nekter to steg i samme kjøring', () => {
    expect(() => parseDraftArguments(['--assignment', 'a.json', '--open', '--close'])).toThrow(
      /ett steg om gangen/,
    )
  })

  it('avviser et ukjent valg framfor å ignorere det', () => {
    expect(() => parseDraftArguments(['--assignment', 'a.json', '--open', '--model', 'x'])).toThrow(
      /Ukjent valg/,
    )
  })

  it('avviser et flagg som mangler verdien sin', () => {
    expect(() => parseDraftArguments(['--assignment', '--open'])).toThrow(/krever en sti/)
  })

  it('svarer på --help uten å kreve noe annet', () => {
    expect(parseDraftArguments(['--help'])).toBe('help')
  })
})
