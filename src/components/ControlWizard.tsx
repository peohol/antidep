// ============================================================================
// Trekkspillet den menneskelige kontrollen gjøres i
//
// Én beslutning om gangen. Bare det aktive steget står åpent; et ferdig steg
// lukkes med en animasjon og får en diskret markering, og det neste åpnes og
// rulles fram i visningsområdet. Tidligere steg kan åpnes igjen, og et steg som
// åpnes på nytt viser svaret som ble gitt.
//
// ----------------------------------------------------------------------------
// Hvilket steg som er åpent, er ikke en tilstand som styres ved siden av svarene
//
// Det aktive steget er *det første som ikke er ferdig*. Da kan et svar ikke bli
// registrert uten at flaten går videre, og flaten kan ikke gå videre uten at et
// svar er registrert — de to kan ikke komme i utakt, fordi det bare finnes én
// kilde til begge.
//
// Det ene unntaket er kontrolløren selv: klikker hen på et tidligere steg,
// åpnes det. Det valget står til noe endrer seg i økten, og da tar flyten over
// igjen.
//
// ----------------------------------------------------------------------------
// Progresjon og bevegelse
//
// Progresjonen telles bare over stegene som faktisk er en beslutning.
// Innledningen og oppsummeringene er ikke delkontroller, og å telle dem ville
// gjort «18 delkontroller» til et annet tall enn det oppsummeringen til slutt
// oppgir.
//
// Rullingen er en bekvemmelighet og aldri en forutsetning: `scrollIntoView`
// finnes ikke i alle miljøer, og et miljø uten den skal vise nøyaktig det samme
// innholdet. `prefers-reduced-motion` slår av både animasjonen (i CSS) og den
// myke rullingen.
// ============================================================================

import { useEffect, useId, useRef, useState, type ReactNode } from 'react'
import type { ControlChoiceOption } from '../lib/control-session'

/** Ett steg i økten. */
export interface WizardStep {
  /** Stabil identitet. Brukes som nøkkel for svar og for avtrykk av grunnlaget. */
  readonly id: string
  readonly title: string
  /**
   * Svaret, kort, vist på det lukkede steget.
   *
   * `null` betyr at steget ikke er besvart — aldri at svaret var tomt.
   */
  readonly answerSummary: string | null
  readonly isComplete: boolean
  /** Om steget teller som en delkontroll i progresjonen. */
  readonly countsTowardProgress: boolean
  readonly content: ReactNode
}

function prefersReducedMotion(): boolean {
  return (
    typeof window !== 'undefined' &&
    typeof window.matchMedia === 'function' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches
  )
}

/**
 * Ruller steget fram, når miljøet kan.
 *
 * jsdom har ingen `scrollIntoView`, og et kall ville kastet midt i en render.
 * Kontrollen er derfor på funksjonen selv og ikke på nettleseren.
 */
function revealStep(element: HTMLElement | null): void {
  if (element === null || typeof element.scrollIntoView !== 'function') {
    return
  }
  element.scrollIntoView({
    behavior: prefersReducedMotion() ? 'auto' : 'smooth',
    block: 'start',
  })
}

function StepPanel({
  step,
  isOpen,
  onToggle,
  registerRef,
}: {
  readonly step: WizardStep
  readonly isOpen: boolean
  readonly onToggle: () => void
  readonly registerRef: (element: HTMLElement | null) => void
}) {
  const regionId = useId()
  const headingId = useId()
  const state = step.isComplete ? 'done' : isOpen ? 'active' : 'upcoming'

  return (
    <section className="control-step" data-state={state} ref={registerRef}>
      <h3 className="control-step__heading" id={headingId}>
        <button
          aria-controls={regionId}
          aria-expanded={isOpen}
          className="control-step__toggle"
          onClick={onToggle}
          type="button"
        >
          <span className="control-step__title">{step.title}</span>
          {/* Statusen står med ord og ikke bare med farge eller et hakemerke
              (ANTIDEP_CONSTITUTION.md §2, WCAG 1.4.1). */}
          <span className="control-step__status">
            {step.isComplete ? (step.answerSummary ?? 'Ferdig') : isOpen ? 'Åpent' : 'Ikke gjort'}
          </span>
        </button>
      </h3>
      <div
        aria-labelledby={headingId}
        className="control-step__body"
        data-open={isOpen}
        id={regionId}
        role="region"
      >
        <div className="control-step__content">{isOpen ? step.content : null}</div>
      </div>
    </section>
  )
}

export function ControlWizard({
  steps,
  progressLabel,
}: {
  readonly steps: readonly WizardStep[]
  /** Hva progresjonen teller, for eksempel «delkontroller». */
  readonly progressLabel: string
}) {
  const [manualOpenId, setManualOpenId] = useState<string | null>(null)
  const elements = useRef(new Map<string, HTMLElement>())

  const firstIncomplete = steps.find((step) => !step.isComplete)
  const lastStep = steps.at(-1)
  const flowStepId = firstIncomplete?.id ?? lastStep?.id ?? null
  const manualStepExists = steps.some((step) => step.id === manualOpenId)
  const openId = manualStepExists ? manualOpenId : flowStepId

  // Går flyten videre, slipper et manuelt åpnet steg taket: kontrolløren skal
  // ikke måtte lukke et gammelt steg for å komme videre i økten.
  const previousFlowStepId = useRef(flowStepId)
  useEffect(() => {
    if (previousFlowStepId.current !== flowStepId) {
      previousFlowStepId.current = flowStepId
      setManualOpenId(null)
    }
  }, [flowStepId])

  // Rull det åpne steget fram når det bytter, men ikke ved første visning: da
  // står kontrolløren allerede øverst.
  const previousOpenId = useRef<string | null>(null)
  useEffect(() => {
    if (previousOpenId.current !== null && previousOpenId.current !== openId && openId !== null) {
      revealStep(elements.current.get(openId) ?? null)
    }
    previousOpenId.current = openId
  }, [openId])

  const progressSteps = steps.filter((step) => step.countsTowardProgress)
  const openIndex = progressSteps.findIndex((step) => step.id === openId)
  const doneCount = progressSteps.filter((step) => step.isComplete).length
  // Står kontrolløren i et delkontrollsteg, er det nummeret som vises. Står hen
  // i et steg som ikke teller, vises hvor langt økten er kommet.
  const position = openIndex >= 0 ? openIndex + 1 : Math.min(doneCount + 1, progressSteps.length)

  return (
    <div className="control-wizard">
      <p aria-live="polite" className="control-wizard__progress">
        {progressSteps.length === 0
          ? `Ingen ${progressLabel} gjenstår.`
          : `${progressLabel}: ${String(position)} av ${String(progressSteps.length)}`}
      </p>
      {steps.map((step) => (
        <StepPanel
          isOpen={step.id === openId}
          key={step.id}
          onToggle={() => setManualOpenId(step.id === openId ? null : step.id)}
          registerRef={(element) => {
            if (element === null) {
              elements.current.delete(step.id)
            } else {
              elements.current.set(step.id, element)
            }
          }}
          step={step}
        />
      ))}
    </div>
  )
}

/**
 * Svarknappene.
 *
 * Knapper og ikke en nedtrekksliste: valget er selve beslutningen, og en liste
 * som må åpnes før alternativene vises, skjuler at «kan ikke avgjøre» finnes.
 * `aria-pressed` bærer hvilket valg som står — ikke en farge alene.
 */
export function ControlChoice({
  legend,
  options,
  value,
  onChoose,
}: {
  readonly legend: string
  readonly options: readonly ControlChoiceOption[]
  readonly value: string | null
  readonly onChoose: (value: string) => void
}) {
  const legendId = useId()
  return (
    <div aria-labelledby={legendId} className="control-choice" role="group">
      <p className="control-choice__legend" id={legendId}>
        {legend}
      </p>
      <div className="control-choice__options">
        {options.map((option) => (
          <button
            aria-pressed={value === option.value}
            className="control-choice__option"
            key={option.value}
            onClick={() => onChoose(option.value)}
            type="button"
          >
            {option.label}
          </button>
        ))}
      </div>
    </div>
  )
}
