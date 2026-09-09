// ============================================================================
// Lenken et menneske skal åpne, og hvorfor den ikke er henteadressen
//
// `source_version.retrieved_from` er maskinens *eksakte* henteadresse. Den er
// riktig og nødvendig der den brukes: fingeravtrykket er beregnet av nøyaktig
// det den peker på, så uten den kan ingen hente representasjonen på nytt og
// etterprøve den (DATABASE_ARCHITECTURE.md §18).
//
// Den er samtidig ubrukelig for et menneske. For sertralinkilden peker den på
// et EUtils-kall som svarer med XML:
//
//   https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&…&retmode=xml
//
// En kontrollør som klikker på den, får en maskinlesbar post — ikke artikkelen.
//
// ----------------------------------------------------------------------------
// Den menneskelige lenken bygges av kildens identifikatorer
//
// DOI er den stabile, forlagsuavhengige adressen til publikasjonen selv, og den
// er den primære. Finnes ingen DOI, er PubMed-siden den beste menneskelige
// inngangen til en bibliografisk post. Finnes ingen av delene, finnes det ingen
// menneskelig lenke Antidep kan konstruere — og da sier flaten det, framfor å
// tilby henteadressen som om den var en artikkellenke.
//
// De to adressemønstrene er de eneste to konstruksjonene her, og begge bygges av
// en identifikator databasen allerede validerer på form
// (`source_identifiers_doi_format_check`, `source_identifiers_pmid_format_check`).
// Verdien prosentkodes likevel før den settes inn: en identifikator er
// registrert av et menneske eller en agent og behandles som utrygg inndata
// (CLAUDE.md).
// ============================================================================

import type { SourceIdentifier } from '../agents/verification-input'

/** Adressen et menneske skal åpne, med begrunnelsen for hvilken den er. */
export type HumanSourceLink =
  | { readonly kind: 'doi'; readonly href: string; readonly label: string }
  | { readonly kind: 'pubmed'; readonly href: string; readonly label: string }
  /** Ingen identifikator Antidep kan bygge en menneskelig adresse av. */
  | { readonly kind: 'none' }

function findIdentifier(identifiers: readonly SourceIdentifier[], system: string): string | null {
  for (const identifier of identifiers) {
    if (identifier.system !== system) {
      continue
    }
    const value = identifier.value.trim()
    if (value.length > 0) {
      return value
    }
  }
  return null
}

/**
 * Den menneskelige lenken til kilden.
 *
 * DOI først, PubMed som reserve, og ingenting når kilden ikke har noen av
 * delene. Henteadressen brukes aldri: den er maskinens, og den kan være XML.
 */
export function humanSourceLink(identifiers: readonly SourceIdentifier[]): HumanSourceLink {
  const doi = findIdentifier(identifiers, 'doi')
  if (doi !== null) {
    // Skråstreken i en DOI er en del av adressen og skal ikke kodes; resten
    // kodes. `encodeURI` gjør nøyaktig det skillet.
    return { kind: 'doi', href: `https://doi.org/${encodeURI(doi)}`, label: `DOI ${doi}` }
  }
  const pmid = findIdentifier(identifiers, 'pmid')
  if (pmid !== null) {
    return {
      kind: 'pubmed',
      href: `https://pubmed.ncbi.nlm.nih.gov/${encodeURIComponent(pmid)}/`,
      label: `PubMed ${pmid}`,
    }
  }
  return { kind: 'none' }
}
