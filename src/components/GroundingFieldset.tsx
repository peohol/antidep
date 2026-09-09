// ============================================================================
// Kildeforankringen, samlet inn som en del av ekstraksjonen
//
// Ett felt om gangen: det ordrette utdraget, hvor i kilden det står, og en kort
// begrunnelse for hvordan utdraget ble til den strukturerte verdien.
//
// ----------------------------------------------------------------------------
// Hvorfor alle feltene tilbys, og ikke bare de raden «påstår noe om»
//
// Hvilke felter et evidensfunn påstår noe om, avgjøres av
// `workflow.required_check_fields(uuid)` — publiseringsgatens egen funksjon, som
// leser den ferdige raden. Raden finnes ikke ennå mens skjemaet fylles ut, og en
// liste her ville vært en andre formulering av den regelen: to steder å endre,
// og to steder å ta feil.
//
// Alle feltene i vokabularet tilbys derfor, i vokabularets egen rekkefølge, og
// hver er lukket til den åpnes. Det redaktøren ikke forankrer, står som
// uforankret i kontrolløkten — synlig, og aldri gjettet.
//
// ----------------------------------------------------------------------------
// Tre felter, ikke to
//
// Et utdrag uten peker kan ikke etterprøves, og en peker uten utdrag sier ikke
// hva som står der. Halvferdige forankringer avvises av
// `collectFieldGroundings(...)` før noe sendes.
// ============================================================================

import { EVIDENCE_CHECK_FIELD_LABELS } from './vocabulary-labels'
import { EVIDENCE_CHECK_FIELDS } from '../types/api'
import { EMPTY_GROUNDING_DRAFT, type GroundingDraft } from '../lib/grounding-draft'

export function GroundingFieldset({
  drafts,
  onChange,
}: {
  readonly drafts: Readonly<Record<string, GroundingDraft>>
  readonly onChange: (field: string, draft: GroundingDraft) => void
}) {
  return (
    <fieldset className="admin-form__section">
      <legend>Kildeforankring per felt</legend>
      <p className="admin-form__hint">
        Den som skal kontrollere funnet, får se ett felt om gangen med kildeutdraget ved siden av
        Antideps tolkning. Feltene du ikke forankrer her, vises som uforankret — Antidep henter
        aldri et utdrag ut av sitatet på egen hånd.
      </p>
      {EVIDENCE_CHECK_FIELDS.map((field) => {
        const draft = drafts[field] ?? EMPTY_GROUNDING_DRAFT
        const label = EVIDENCE_CHECK_FIELD_LABELS[field]
        const isStarted =
          draft.excerpt.length > 0 || draft.locator.length > 0 || draft.justification.length > 0
        return (
          <details className="grounding-field" key={field} open={isStarted}>
            <summary>
              {label}
              {isStarted ? '' : ' — ikke forankret'}
            </summary>
            <label className="field-check__note">
              Ordrett utdrag fra kilden
              <textarea
                onChange={(event) => onChange(field, { ...draft, excerpt: event.target.value })}
                rows={3}
                value={draft.excerpt}
              />
            </label>
            <label className="field-check__note">
              Hvor i kilden står utdraget?
              <textarea
                onChange={(event) => onChange(field, { ...draft, locator: event.target.value })}
                rows={1}
                value={draft.locator}
              />
            </label>
            <label className="field-check__note">
              Hvordan ble utdraget til denne verdien?
              <textarea
                onChange={(event) =>
                  onChange(field, { ...draft, justification: event.target.value })
                }
                rows={2}
                value={draft.justification}
              />
            </label>
          </details>
        )
      })}
    </fieldset>
  )
}
