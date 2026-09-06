// ============================================================================
// Én kilde som et valg i en nedtrekksliste
//
// Trukket ut av `CreateEvidenceItemPage.tsx` da `CreateSourceVersionPage.tsx`
// fikk bruk for den samme listen. Grunnen er ikke gjenbruk for gjenbrukets
// skyld: etiketten bærer kildestatusen, og ANTIDEP_CONSTITUTION.md §14 krever at
// en tilbaketrukket kilde ikke stille kan velges som om den var normal. To
// kopier av den regelen ville kunnet drive fra hverandre, og avviket ville vært
// at kilden så normal ut i det ene skjemaet og ikke i det andre.
// ============================================================================

import { SOURCE_STATUS_LABELS, termText } from '../components/vocabulary-labels'
import { readSourceStatus } from './evidence-item'
import type { EditorSourceRow } from '../types/api'

/** Et valg i en nedtrekksliste: verdien databasen tar imot, og teksten brukeren ser. */
export interface Choice {
  readonly value: string
  readonly label: string
}

/** Legger statusen på et navn når statusen er noe annet enn den normale. */
export function withStatus(name: string, status: string): string {
  return status === 'active' ? name : `${name} (${status})`
}

/**
 * Én kilde i nedtrekkslisten.
 *
 * Året står med fordi to publikasjoner fra samme forfattergruppe ellers er
 * vanskelige å skille. Kildestatusen står med av en annen grunn: en kilde som er
 * trukket tilbake skal ikke kunne velges uten at det er synlig
 * (ANTIDEP_CONSTITUTION.md §14).
 */
export function sourceChoice(source: EditorSourceRow): Choice {
  const year = source.publication_date?.slice(0, 4)
  const parts = [source.title, source.authors_or_issuer, year].filter(
    (part): part is string => part !== undefined && part.length > 0,
  )
  const status = readSourceStatus(source.source_status)
  const label = parts.join(' — ')
  return {
    value: source.source_id,
    label:
      status.kind === 'known' && status.value === 'active'
        ? label
        : withStatus(label, termText(status, SOURCE_STATUS_LABELS, 'kildestatus')),
  }
}
