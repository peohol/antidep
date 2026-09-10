// ============================================================================
// Sperren som avgjør om et forslag kontrolleres mot oppdraget sitt
//
// Dette er en regresjonstest på en feil som var verre enn den så ut. Sperren
// leste `generated_by.producer` i forslaget for å avgjøre om `--assignment` var
// påkrevd — altså lot den *filen* bestemme om den skulle kontrolleres. Et
// forslag endret etter `--close` kunne bytte `producer` fra `model` til
// `human`, og katalogkontrollen ble hoppet helt over.
//
// Sperren er derfor flyttet til argumentlisten: nøyaktig ett av tre valg er
// påkrevd for hver registrering, uansett hva forslaget måtte si om seg selv.
// Valget avgjør både om avgrensningen kontrolleres og om raden føres som
// KI-assistert eller manuell — begge deler er da en handling noen gjorde, ikke
// en tilstand som oppsto.
//
// `main()` kjøres på toppnivå i CLI-filen og kan ikke importeres av en test.
// Argumentlesingen ligger derfor i `cli-arguments.ts`, og prøves her.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { parseReextractionArguments, parseRegistrationArguments } from './cli-arguments'

const PROPOSAL = ['--proposal', 'proposals/fava-2000.json']

describe('parseRegistrationArguments — sperren er lukket', () => {
  it('avviser en registrering uten noen av de tre valgene', () => {
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
    expect(message).toMatch(/KI-assistert eller\s+manuell/)
  })

  it('avviser to av valgene samtidig', () => {
    expect(() =>
      parseRegistrationArguments([...PROPOSAL, '--assignment', 'a.json', '--human-proposal']),
    ).toThrow(/nøyaktig ett av/)
    expect(() =>
      parseRegistrationArguments([...PROPOSAL, '--model-proposal', '--human-proposal']),
    ).toThrow(/nøyaktig ett av/)
  })

  it('tar imot oppdraget', () => {
    expect(parseRegistrationArguments([...PROPOSAL, '--assignment', 'a.json'])).toEqual({
      proposalPath: 'proposals/fava-2000.json',
      assignmentPath: 'a.json',
      mode: 'with_assignment',
      dryRun: false,
    })
  })

  it('tar imot et maskinutkast uten oppdrag, uten å gjøre det til et menneskes arbeid', () => {
    expect(parseRegistrationArguments([...PROPOSAL, '--model-proposal'])).toEqual({
      proposalPath: 'proposals/fava-2000.json',
      assignmentPath: null,
      mode: 'unchecked_model',
      dryRun: false,
    })
  })

  it('tar imot en redaktørs eget arbeid', () => {
    expect(parseRegistrationArguments([...PROPOSAL, '--human-proposal'])).toEqual({
      proposalPath: 'proposals/fava-2000.json',
      assignmentPath: null,
      mode: 'without_assignment',
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
      parseRegistrationArguments([...PROPOSAL, '--human-proposal', '--dry-run']),
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
      expect(parseRegistrationArguments(['--proposal', path, '--model-proposal'])).toMatchObject({
        mode: 'unchecked_model',
      })
      expect(parseRegistrationArguments(['--proposal', path, '--human-proposal'])).toMatchObject({
        mode: 'without_assignment',
      })
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
    expect(() => parseRegistrationArguments(['--human-proposal'])).toThrow(/--proposal er påkrevd/)
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

// ----------------------------------------------------------------------------
// Re-ekstraksjonen: den samme sperren, uten oppdraget
//
// Denne veien var bypass-en. Modusen var valgfri, og køen oppga den ikke, så
// forslagsfilene avgjorde selv om de ble ført som KI-assistert eller manuell.
// ----------------------------------------------------------------------------

const KØ = ['--directory', 'proposals']

describe('parseReextractionArguments', () => {
  it('avviser en kø uten et uttrykkelig valg', () => {
    expect(() => parseReextractionArguments(KØ)).toThrow(/--model-proposal/)
  })

  it('kjenner ikke --assignment: en kø har ingen oppdrag å kontrolleres mot', () => {
    expect(() => parseReextractionArguments([...KØ, '--assignment', 'a.json'])).toThrow(
      /Ukjent valg/,
    )
  })

  it('tar imot en kø av maskinutkast', () => {
    expect(parseReextractionArguments([...KØ, '--model-proposal'])).toEqual({
      directory: 'proposals',
      proposalPaths: [],
      mode: 'unchecked_model',
      dryRun: false,
    })
  })

  it('tar imot en kø av en redaktørs eget arbeid', () => {
    expect(parseReextractionArguments([...KØ, '--human-proposal'])).toMatchObject({
      mode: 'without_assignment',
    })
  })

  it('avviser to valg samtidig', () => {
    expect(() =>
      parseReextractionArguments([...KØ, '--model-proposal', '--human-proposal']),
    ).toThrow(/nøyaktig ett av/)
  })

  it('krever fortsatt enten en katalog eller minst ett forslag', () => {
    expect(() => parseReextractionArguments(['--model-proposal'])).toThrow(
      /--directory eller minst én/,
    )
  })

  it('tar imot flere enkeltforslag, i den rekkefølgen de står', () => {
    // Veien ut av en blandet katalog: arbeidsformen gjelder hele køen, så en
    // katalog med både maskinutkast og en redaktørs eget arbeid avvises under
    // begge valgene. `proposals/README.md` viser til nettopp denne formen.
    expect(
      parseReextractionArguments([
        '--proposal',
        'proposals/fava-2000.json',
        '--proposal',
        'proposals/rush-2006.json',
        '--human-proposal',
      ]),
    ).toEqual({
      directory: null,
      proposalPaths: ['proposals/fava-2000.json', 'proposals/rush-2006.json'],
      mode: 'without_assignment',
      dryRun: false,
    })
  })

  it('nekter katalog og enkeltforslag samtidig', () => {
    expect(() =>
      parseReextractionArguments([...KØ, '--proposal', 'a.json', '--model-proposal']),
    ).toThrow(/ikke begge/)
  })
})
