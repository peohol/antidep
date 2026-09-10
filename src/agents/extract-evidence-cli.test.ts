// ============================================================================
// Sperren som avgjør om et forslag kontrolleres mot oppdraget sitt
//
// Dette er en regresjonstest på en feil som var verre enn den så ut. Sperren
// leste `generated_by.producer` i forslaget for å avgjøre om `--assignment` var
// påkrevd — altså lot den *filen* bestemme om den skulle kontrolleres. Et
// forslag endret etter `--close` kunne bytte `producer` fra `model` til
// `human`, og katalogkontrollen ble hoppet helt over.
//
// Sperren er derfor flyttet til argumentlisten: nøyaktig ett av `--assignment`
// og `--no-assignment-check` er påkrevd for hver registrering, uansett hva
// forslaget måtte si om seg selv. Fravær av kontroll er da en handling noen
// gjorde, ikke en tilstand som oppsto.
//
// `main()` kjøres på toppnivå i CLI-filen og kan ikke importeres av en test.
// Argumentlesingen ligger derfor i `cli-arguments.ts`, og prøves her.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { parseRegistrationArguments } from './cli-arguments'

const PROPOSAL = ['--proposal', 'proposals/fava-2000.json']

describe('parseRegistrationArguments — sperren er lukket', () => {
  it('avviser en registrering uten noen av de to valgene', () => {
    expect(() => parseRegistrationArguments(PROPOSAL)).toThrow(/--assignment <fil>/)
  })

  it('sier hvorfor valget er påkrevd, framfor bare at det mangler', () => {
    let message = ''
    try {
      parseRegistrationArguments(PROPOSAL)
    } catch (cause) {
      message = cause instanceof Error ? cause.message : String(cause)
    }
    expect(message).toMatch(/utrygg inndata/)
  })

  it('avviser begge valgene samtidig', () => {
    expect(() =>
      parseRegistrationArguments([...PROPOSAL, '--assignment', 'a.json', '--no-assignment-check']),
    ).toThrow(/to forskjellige valg/)
  })

  it('tar imot oppdraget', () => {
    expect(parseRegistrationArguments([...PROPOSAL, '--assignment', 'a.json'])).toEqual({
      proposalPath: 'proposals/fava-2000.json',
      assignmentPath: 'a.json',
      dryRun: false,
    })
  })

  it('tar imot det uttrykkelige fravalget, som `null`', () => {
    expect(parseRegistrationArguments([...PROPOSAL, '--no-assignment-check'])).toEqual({
      proposalPath: 'proposals/fava-2000.json',
      assignmentPath: null,
      dryRun: false,
    })
  })

  it('krever valget også for en tørrkjøring', () => {
    // Tørrkjøringen kontrollerer det samme som en registrering, og skal derfor
    // svare på det samme spørsmålet. En tørrkjøring uten kontrollen ville sagt
    // «alt i orden» om noe som ikke var kontrollert.
    expect(() => parseRegistrationArguments([...PROPOSAL, '--dry-run'])).toThrow(/--assignment/)
  })

  it('leser --dry-run sammen med valget', () => {
    expect(
      parseRegistrationArguments([...PROPOSAL, '--no-assignment-check', '--dry-run']),
    ).toMatchObject({ dryRun: true })
  })
})

describe('parseRegistrationArguments — argumentlisten ser ikke på forslaget', () => {
  // Den bærende påstanden: sperren er en egenskap ved kallet, ikke ved filen.
  // Parseren har ingen tilgang til forslaget i det hele tatt, og kan derfor
  // ikke la `generated_by.producer` avgjøre noe.
  it('krever det samme valget uansett hva forslaget heter eller inneholder', () => {
    for (const path of ['fra-en-modell.json', 'skrevet-av-et-menneske.json']) {
      expect(() => parseRegistrationArguments(['--proposal', path])).toThrow(/--assignment/)
      expect(
        parseRegistrationArguments(['--proposal', path, '--no-assignment-check']),
      ).toMatchObject({ assignmentPath: null })
    }
  })
})

describe('parseRegistrationArguments — det som kan besvares uten et forslag', () => {
  it('svarer på --schema uten å kreve noe annet', () => {
    expect(parseRegistrationArguments(['--schema'])).toBe('schema')
  })

  it('svarer på --help uten å kreve noe annet', () => {
    expect(parseRegistrationArguments(['--help'])).toBe('help')
  })

  it('krever forslaget', () => {
    expect(() => parseRegistrationArguments(['--no-assignment-check'])).toThrow(
      /--proposal er påkrevd/,
    )
  })

  it('avviser et ukjent valg framfor å ignorere det', () => {
    expect(() => parseRegistrationArguments([...PROPOSAL, '--assignmnet', 'a.json'])).toThrow(
      /Ukjent valg/,
    )
  })

  it('avviser et flagg som mangler verdien sin', () => {
    expect(() => parseRegistrationArguments([...PROPOSAL, '--assignment', '--dry-run'])).toThrow(
      /krever en filsti/,
    )
  })
})
