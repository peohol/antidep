// ============================================================================
// Grunnlaget kontrolløren ser: hvem som laget verdiene
//
// Den som skal bedømme om verdiene følger av kilden, leser et maskinutkast fra
// en bestemt modell og en bestemt promptmal annerledes enn en kollegas egen
// ekstraksjon (ANTIDEP_CONSTITUTION.md §12, EVIDENCE_PIPELINE.md §46). Panelet
// skal si hvilket av de to det er — og si fravær som fravær når funnet ble ført
// inn i adminflyten uten en agentkjøring.
// ============================================================================

import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'

import { ExtractionSourcePanel } from './ExtractionDossier'
import { verificationItemFixture } from '../agents/test-support'

describe('ExtractionSourcePanel — hvem som laget verdiene', () => {
  it('viser leverandøren, modellen, promptmalen og da utkastet ble laget', () => {
    render(<ExtractionSourcePanel item={verificationItemFixture()} />)

    expect(screen.getByText('en-leverandør/en-modell 2026-09-15')).toBeInTheDocument()
    expect(
      screen.getByText('Promptmal evidence-extraction/proposal-drafting/1'),
    ).toBeInTheDocument()
    expect(screen.getByText(/Utkastet laget/)).toBeInTheDocument()
  })

  // Databasen kan ikke observere hvilken modell som leste en artikkel. En flate
  // som viste verdien som et observert faktum, ville lovet mer enn den kan
  // holde (ANTIDEP_CONSTITUTION.md §8).
  it('sier med ord at opphavet er forslagets egen erklæring', () => {
    render(<ExtractionSourcePanel item={verificationItemFixture()} />)

    expect(
      screen.getByText('Foreslått av en språkmodell, etter forslagets egen erklæring'),
    ).toBeInTheDocument()
  })

  // Utkastet og registreringen er to operasjoner på to tidspunkter. Ett
  // tidspunkt lest som det andre ville sagt at modellen leste artikkelen i det
  // øyeblikket noen kjørte registreringskommandoen.
  it('skiller kjøringen som registrerte raden fra utkastet', () => {
    render(<ExtractionSourcePanel item={verificationItemFixture()} />)

    expect(screen.getByText('antidep/proposal-grounded-extraction 1.0.0')).toBeInTheDocument()
    expect(screen.getByText('Pipeline antidep-evidence/1')).toBeInTheDocument()
  })

  // Fravær vises som fravær, aldri som tomme felter eller som noe utledet av
  // ekstraksjonsmetoden (ANTIDEP_CONSTITUTION.md §6).
  it('sier at ingen erklæring fulgte med når funnet kom fra adminflyten', () => {
    render(
      <ExtractionSourcePanel
        item={verificationItemFixture({ draftedBy: null, registeredBy: null })}
      />,
    )

    expect(screen.getByText(/Ingen erklæring fulgte med/)).toBeInTheDocument()
    expect(screen.getByText(/Ingen agentkjøring\./)).toBeInTheDocument()
    expect(screen.queryByText(/Promptmal/)).not.toBeInTheDocument()
  })
})
