// ============================================================================
// Kildeforankringen slik registreringsskjemaet samler den inn
//
// Søster til `evidence-registration.ts`, og bygget på det samme skillet: dette
// er ikke feltvalidering som gjentar databasens CHECK-constraints. Det er
// spørsmålet om skjemaet i det hele tatt har fått nok input til å danne en
// forankring.
//
// En forankring er tre ting som hører sammen: det ordrette utdraget, den
// presise pekeren til hvor utdraget står, og den korte begrunnelsen for hvordan
// utdraget ble til verdien. To av tre er ikke en forankring — et utdrag uten
// peker kan ikke etterprøves, og en peker uten utdrag sier ikke hva som står
// der. Skjemaet sier derfor fra framfor å sende noe databasen ville avvist, og
// framfor å sende en halv forankring som ser komplett ut i kontrollflaten.
//
// Et helt tomt felt er ikke en feil. Et evidensfunn kan mangle forankring for et
// felt, og fraværet vises som fravær i kontrolløkten
// (ANTIDEP_CONSTITUTION.md §6).
// ============================================================================

/** Ett felt slik skjemaet holder det. */
export interface GroundingDraft {
  readonly excerpt: string
  readonly locator: string
  readonly justification: string
}

export const EMPTY_GROUNDING_DRAFT: GroundingDraft = {
  excerpt: '',
  locator: '',
  justification: '',
}

/** Én ferdig forankring, i den formen skriveveien tar imot den. */
export interface FieldGroundingInput {
  readonly checkField: string
  readonly sourceExcerpt: string
  readonly sourceLocator: string
  readonly justification: string
}

export type GroundingCollection =
  | { readonly status: 'ok'; readonly groundings: readonly FieldGroundingInput[] }
  | { readonly status: 'incomplete'; readonly message: string }

function filled(value: string): boolean {
  return value.trim().length > 0
}

/**
 * Forankringene som faktisk er fylt ut, eller beskjed om hva som mangler.
 *
 * `fieldLabel` oversetter feltverdien til det navnet redaktøren ser i skjemaet,
 * slik at meldingen navngir feltet og ikke enum-verdien.
 */
export function collectFieldGroundings(
  drafts: Readonly<Record<string, GroundingDraft>>,
  fieldLabel: (field: string) => string,
): GroundingCollection {
  const groundings: FieldGroundingInput[] = []
  for (const [field, draft] of Object.entries(drafts)) {
    const parts = [draft.excerpt, draft.locator, draft.justification]
    const provided = parts.filter(filled).length
    if (provided === 0) {
      continue
    }
    if (provided < parts.length) {
      return {
        status: 'incomplete',
        message:
          `Kildeforankringen av «${fieldLabel(field)}» er halvferdig. ` +
          'En forankring trenger både det ordrette utdraget, hvor i kilden det står, og en kort ' +
          'begrunnelse for hvordan utdraget ble til verdien. Fyll ut alle tre, eller la feltet stå helt tomt.',
      }
    }
    groundings.push({
      checkField: field,
      sourceExcerpt: draft.excerpt.trim(),
      sourceLocator: draft.locator.trim(),
      justification: draft.justification.trim(),
    })
  }
  return { status: 'ok', groundings }
}
