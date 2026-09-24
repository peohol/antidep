// ============================================================================
// De deterministiske kontrollene av et eksternt agentsvar, før det sendes
//
// `agent-answer.ts` kontrollerer at svaret hører til oppgaven. Denne modulen
// kontrollerer innholdet: at utkastet har kontraktens form, at det holder seg
// innenfor den avgrensningen oppgaven ga, og — for ekstraksjonsleddet — at hvert
// kildeutdrag faktisk står ordrett i den kildeteksten oppgaven inneholdt.
//
// ----------------------------------------------------------------------------
// Hvorfor kontrollene kjøres her og ikke bare i databasen
//
// Fordi det er den samme koden kjederunnerne allerede bruker
// (`drafting-run.ts`), og fordi en andre implementasjon av den ordrette
// kontrollen ville vært en andre kilde til sannhet. Normaliseringen — hva som
// er et ord, hva en blokkgrense er, hvordan entiteter og etiketter håndteres —
// bor ett sted (`extraction-checks.ts`), og to kontroller som kunne svare
// forskjellig på den samme artikkelen, er verre enn én.
//
// Kontrollen her er heller ikke *den* kontrollen. Den uavhengige
// ekstraksjonskontrollen er en egen rolle, med en egen identitet og en egen
// kjøring, senere i kjeden, og uten den kan ingen menneskelig bekreftelse
// registreres. Kontrollen her er generatorens egen aktsomhet: uten den ville et
// oppdiktet utdrag blitt en rad, og så noe en kontrollør måtte avvise. Med den
// blir det ingen rad.
//
// ----------------------------------------------------------------------------
// Hva databasen gjør uansett
//
// Databasen kontrollerer avgrensningen om igjen ved import, av oppgaven slik den
// er *da* (migrasjon 010c). Den henter dessuten alle registrerte verdier ut av
// svaret selv, så en flate kan ikke bytte dem ut underveis. Det som ligger her,
// er derfor et første, forklarende ledd — ikke grensen databasen hviler på.
// ============================================================================

import { searchProjections, verbatimOccursIn } from './extraction-checks.ts'
import { excerptSourceProblem } from './source-excerpt.ts'
import { parseExtractionDraft } from './extraction-proposal.ts'
import {
  parseProposedClaimRevision,
  parseProposedEvidenceLink,
  type ClaimBinding,
} from './claim-synthesis-proposal.ts'
import { parseProposedAssessment } from './evidence-assessment-proposal.ts'
import {
  CANDIDATE_DECISIONS,
  CANDIDATE_IDENTIFIER_KINDS,
  SEARCH_METHOD_NAMES,
  SEARCH_PLATFORMS,
  SEARCH_REQUEST_MAX_SEEDS,
  SEARCH_REQUEST_MAX_TERMS,
  SEARCH_STRATEGIES,
  SEED_IDENTIFIER_KINDS,
} from './handoff-schemas.ts'
import {
  appraisableCandidate,
  decisionsFor,
  discoveryAnswerBounds,
  narrowingProblem,
  type DiscoveryAnswerBounds,
} from './discovery-answer-bounds.ts'
import {
  asObjectList,
  asOptionalInteger,
  asOptionalText,
  asOptionalVocabulary,
  asText,
  asUuid,
  asVocabulary,
  fieldsOf,
  nestedFields,
  problem,
  raw,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'
import type { AgentTask } from './agent-task.ts'
import type { Uuid } from '../types/api.ts'

const RESULT_SUBJECT = 'Agentsvaret'

function textList(input: Record<string, unknown>, key: string): readonly string[] {
  const value = input[key]
  return Array.isArray(value)
    ? value.filter((entry): entry is string => typeof entry === 'string')
    : []
}

function textOf(input: Record<string, unknown>, key: string): string {
  const value = input[key]
  return typeof value === 'string' ? value : ''
}

function evidenceIdsIn(input: Record<string, unknown>): readonly string[] {
  const value = input['evidence']
  if (!Array.isArray(value)) {
    return []
  }
  return value.flatMap((entry) => {
    if (typeof entry !== 'object' || entry === null) {
      return []
    }
    const id = (entry as Record<string, unknown>)['evidence_item_id']
    return typeof id === 'string' ? [id] : []
  })
}

/**
 * Kontrollerer ekstraksjonsutkastet mot oppgaven det ble laget under.
 *
 * Tre ting, og alle tre er ting en modell kan ta feil av på en måte som ikke
 * synes senere: formen, avgrensningen og de ordrette utdragene.
 */
function extractionProblem(task: AgentTask, result: Record<string, unknown>): string | null {
  const draft = parseExtractionDraft(result, RESULT_SUBJECT)

  const binding = (task.binding['input'] ?? {}) as Record<string, unknown>
  const drugs = textList(binding, 'drug_ids')
  const outcomes = textList(binding, 'outcome_concept_ids')
  const populations = textList(binding, 'population_ids')
  const e = draft.extraction

  if (!drugs.includes(e.interventionDrugId)) {
    return 'Utkastet oppgir et virkestoff som ikke står blant virkestoffene i oppgaven.'
  }
  if (e.comparatorDrugId !== null && !drugs.includes(e.comparatorDrugId)) {
    return 'Utkastet oppgir et komparatorvirkestoff som ikke står blant virkestoffene i oppgaven.'
  }
  if (!outcomes.includes(e.outcomeConceptId)) {
    return 'Utkastet oppgir et endepunkt som ikke står blant endepunktene i oppgaven.'
  }
  if (e.populationId !== null && !populations.includes(e.populationId)) {
    return 'Utkastet oppgir en populasjon som ikke står blant populasjonene i oppgaven.'
  }

  const representation = textOf(task.input, 'representation_text')
  if (representation.length === 0) {
    return 'Oppgaven inneholdt ingen kildetekst, så utdragene kan ikke kontrolleres.'
  }
  const projections = searchProjections(representation)
  for (const grounding of draft.fieldGroundings) {
    const issue = excerptSourceProblem(projections, grounding.sourceExcerpt)
    if (issue !== null) {
      return `Kildeforankringen for ${grounding.checkField} oppgir et utdrag som ${issue}.`
    }
  }
  const quote = e.sourceQuote
  if (quote !== null && !verbatimOccursIn(projections, quote)) {
    return 'source_quote står ikke ordrett i kildeteksten oppgaven inneholdt.'
  }
  return null
}

/** Kontrollerer synteseutkastet mot evidenssettet oppgaven avgrenset. */
function synthesisProblem(task: AgentTask, result: Record<string, unknown>): string | null {
  const binding = (task.binding['input'] ?? {}) as Record<string, unknown>
  const claimBinding: ClaimBinding = {
    claimId: (binding['claim_id'] as Uuid | null) ?? null,
    topicConceptId: String(binding['topic_concept_id'] ?? '') as Uuid,
    subjectDrugId: String(binding['subject_drug_id'] ?? '') as Uuid,
  }

  const fields = fieldsOf(result, RESULT_SUBJECT, 'utkastet')
  const claim = parseProposedClaimRevision(fields, raw(fields, 'claim'), claimBinding)
  const links = asObjectList(fields, 'evidence_links').map((link, index) =>
    parseProposedEvidenceLink(fields, link, index),
  )
  rejectUnknown(fields)

  // Populasjonen er en faglig avgrensning redaktøren har gjort, på linje med
  // katalogen i et ekstraksjonsoppdrag. En id kopiert ut av dossieret ville
  // passert fremmednøkkelen og flyttet påstanden til en annen populasjon enn
  // den oppgaven gjelder.
  const populations = textList(binding, 'population_ids')
  if (claim.populationId !== null && !populations.includes(claim.populationId)) {
    return 'Utkastet oppgir en populasjon som ikke står blant populasjonene i oppgaven.'
  }

  // Hele evidenssettet, og ikke en delmengde av det. Et utkast som utelot et
  // funn som MOTSIER påstanden, ville gitt en syntese som hvilte på et annet
  // grunnlag enn det redaktøren avgrenset — og uenigheten ville vært borte uten
  // at noe i kjeden sa fra (ANTIDEP_CONSTITUTION.md regel 4).
  const assigned = evidenceIdsIn(binding)
  const seen = new Set<string>()
  for (const link of links) {
    if (!assigned.includes(link.evidenceItemId)) {
      return 'Utkastet lenker til et evidensfunn som ikke står i oppgaven.'
    }
    if (seen.has(link.evidenceItemId)) {
      return 'Utkastet fører det samme evidensfunnet mer enn én gang.'
    }
    seen.add(link.evidenceItemId)
  }
  const missing = assigned.filter((id) => !seen.has(id))
  if (missing.length > 0) {
    return (
      `Utkastet mangler ${String(missing.length)} av evidensfunnene oppgaven avgrenset. ` +
      'Hvert funn skal ha en relasjon til påstanden — også et funn som motsier den, som da ' +
      'føres som contradicts.'
    )
  }
  return null
}

/** Kontrollerer vurderingsutkastet. */
function assessmentProblem(result: Record<string, unknown>): string | null {
  const fields = fieldsOf(result, RESULT_SUBJECT, 'utkastet')
  parseProposedAssessment(fields, raw(fields, 'assessment'))
  rejectUnknown(fields)
  return null
}

function optionalBoolean(fields: Fields, key: string): boolean | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'boolean') {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke sann/usann')
  }
  return value
}

function requiredBoolean(fields: Fields, key: string): boolean {
  const value = optionalBoolean(fields, key)
  if (value === null) {
    problem(fields.subject, `${fields.where}.${key}`, 'mangler')
  }
  return value
}

function optionalArray(fields: Fields, key: string): readonly unknown[] {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return []
  }
  if (!Array.isArray(value)) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke en liste')
  }
  return value
}

function requiredArray(fields: Fields, key: string): readonly unknown[] {
  const value = raw(fields, key)
  if (!Array.isArray(value)) {
    problem(fields.subject, `${fields.where}.${key}`, 'mangler eller er ikke en liste')
  }
  return value
}

function nonNegativeInteger(fields: Fields, key: string): number | null {
  const value = asOptionalInteger(fields, key)
  if (value !== null && value < 0) {
    problem(fields.subject, `${fields.where}.${key}`, 'er negativt')
  }
  return value
}

function stringArray(fields: Fields, key: string): readonly string[] {
  const values = optionalArray(fields, key)
  return values.map((value, index) => {
    if (typeof value !== 'string') {
      problem(fields.subject, `${fields.where}.${key}[${String(index)}]`, 'er ikke tekst')
    }
    return value
  })
}

/**
 * De feltene kildeleddene hadde før migrasjon 013v, og som ikke finnes lenger.
 *
 * De fortjener hver sin setning framfor «ukjent felt». `searches` er ikke en
 * skrivefeil: det er et svar som gjør krav på å ha utført søk, og den veien
 * finnes ikke for et ledd som ikke har verktøy til å søke. `candidates` er en
 * kilde uten en oppdagelsesvei. Den samme regelen står i databasen, med de
 * samme ordene (SOURCE_POLICY.md §4.3, §4.4).
 */
function rejectRetiredDiscoveryFields(result: Record<string, unknown>): string | null {
  if ('searches' in result) {
    return (
      'Svaret rapporterer utførte søk, og det kan ikke dette agentleddet. Søkene utføres av ' +
      'Antideps egen kode og registreres med endepunkt og responsavtrykk; et modellrapportert ' +
      'søk kan ikke fremstilles som maskinelt bekreftet utførelse. Trengs det flere søk, be om ' +
      'dem i «search_requests».'
    )
  }
  if ('candidates' in result) {
    return (
      'Svaret legger til kandidatkilder, og det kan ikke dette agentleddet. Kandidatkildene ' +
      'kommer fra de registrerte søkene; vurder dem i «candidate_appraisals», og be om et ' +
      'søk som ville funnet en kilde du mener mangler.'
    )
  }
  return null
}

/**
 * Kildevurderingene, mot kildene oppgaven faktisk har.
 *
 * To av avvisningene er de samme databasen gjør, og de står her fordi det er
 * de svarformen ble bygget for å gjøre umulige (migrasjon 014i): en kilde som
 * ikke står i oppgaven, og «excluded» for en kilde med registrert
 * tilgangsbegrensning. Et svar som var gyldig etter oppgavens svarform, skal
 * ikke avvises her — og et som ikke var det, skal ikke først møte databasen.
 */
function discoveryAppraisals(fields: Fields, bounds: DiscoveryAnswerBounds): void {
  const appraisals = requiredArray(fields, 'candidate_appraisals')
  appraisals.forEach((value, index) => {
    const candidate = nestedFields(fields, value, `candidate_appraisals[${String(index)}]`)
    const kind = asVocabulary(candidate, 'identifier_kind', CANDIDATE_IDENTIFIER_KINDS)
    const identifier = asText(candidate, 'identifier_value')
    const known = appraisableCandidate(bounds, kind, identifier)
    if (known === null) {
      problem(
        candidate.subject,
        candidate.where,
        `vurderer kilden ${kind}:${identifier}, som ikke står blant kandidatkildene i oppgaven. ` +
          'Bare kilder et registrert søk har funnet, kan vurderes; mangler en kilde du mener ' +
          'bør være der, be om et søk som ville funnet den',
      )
    }
    const material = optionalBoolean(candidate, 'could_change_conclusion')
    const reason = asOptionalText(candidate, 'materiality_reason')
    if (material === true && reason === null) {
      problem(
        candidate.subject,
        `${candidate.where}.materiality_reason`,
        'mangler, og en kilde som kan endre hovedkonklusjonen, må ha en begrunnelse',
      )
    }
    const decision = asOptionalVocabulary(candidate, 'decision', CANDIDATE_DECISIONS)
    if (decision !== null && !decisionsFor(known).includes(decision)) {
      problem(
        candidate.subject,
        `${candidate.where}.decision`,
        `er «${decision}», men kilden ${kind}:${identifier} har en registrert ` +
          'tilgangsbegrensning og kan ikke ekskluderes, uansett grunn: Antidep har ikke fått ' +
          'lest den. Sett «awaiting_access» og skriv hvorfor i decision_reason',
      )
    }
    asOptionalText(candidate, 'decision_reason')

    const uses = optionalArray(candidate, 'uses')
    uses.forEach((useValue, useIndex) => {
      const use = nestedFields(candidate, useValue, `${candidate.where}.uses[${String(useIndex)}]`)
      asText(use, 'need_reference')
      asText(use, 'proposed_use')
      rejectUnknown(use)
    })
    rejectUnknown(candidate)
  })
}

/**
 * Søkeforespørslene: den ene veien fra en semantisk vurdering til et nytt søk.
 *
 * Grensene er de samme som raden håndhever. De står også her fordi flaten skal
 * kunne si hva som er galt før databasen avviser det — og fordi en forespørsel
 * som kunne navngi en vilkårlig tjeneste, ikke ville vært en søkeforespørsel,
 * men en proxy (ANTIDEP_CONSTITUTION.md regel 7).
 */
function discoverySearchRequests(fields: Fields, bounds: DiscoveryAnswerBounds): number {
  const requests = optionalArray(fields, 'search_requests')
  requests.forEach((value, index) => {
    const request = nestedFields(fields, value, `search_requests[${String(index)}]`)
    asText(request, 'rationale')
    const platform = asOptionalVocabulary(request, 'platform', SEARCH_PLATFORMS)
    const method = asOptionalVocabulary(request, 'method', SEARCH_METHOD_NAMES)
    asOptionalVocabulary(request, 'strategy', SEARCH_STRATEGIES)
    // Bare en runde oppgaven sier at dette leddet kan erstatte, og med den
    // plattformen og metoden runden står med (migrasjon 014i). Databasen
    // avviser de samme; her får agenten vite hvilke som finnes.
    const narrows = asOptionalText(request, 'narrows_request')
    if (narrows !== null) {
      const issue = narrowingProblem(bounds, narrows, platform, method)
      if (issue !== null) {
        problem(request.subject, `${request.where}.narrows_request`, issue)
      }
    }
    const seeds = optionalArray(request, 'seed_candidates')
    if (seeds.length > SEARCH_REQUEST_MAX_SEEDS) {
      problem(
        request.subject,
        `${request.where}.seed_candidates`,
        `har flere enn ${String(SEARCH_REQUEST_MAX_SEEDS)} kilder`,
      )
    }
    seeds.forEach((seedValue, seedIndex) => {
      const seed = nestedFields(
        request,
        seedValue,
        `${request.where}.seed_candidates[${String(seedIndex)}]`,
      )
      asVocabulary(seed, 'identifier_kind', SEED_IDENTIFIER_KINDS)
      asText(seed, 'identifier_value')
      rejectUnknown(seed)
    })
    for (const key of ['drug_aliases', 'query_terms'] as const) {
      const terms = stringArray(request, key)
      if (terms.length > SEARCH_REQUEST_MAX_TERMS) {
        problem(
          request.subject,
          `${request.where}.${key}`,
          `har flere enn ${String(SEARCH_REQUEST_MAX_TERMS)} termer`,
        )
      }
      terms.forEach((term, termIndex) => {
        if (term.trim() !== term || term.length < 2 || term.length > 120 || /["\n\r]/.test(term)) {
          problem(
            request.subject,
            `${request.where}.${key}[${String(termIndex)}]`,
            'har ikke formen en søkestreng kan bære: 2–120 tegn, uten anførselstegn og linjeskift',
          )
        }
      })
    }
    asOptionalText(request, 'filters_note')
    rejectUnknown(request)
  })
  return requests.length
}

function sourceDiscoveryProblem(
  task: AgentTask,
  role: 'source_discovery' | 'source_quality_assessment',
  result: Record<string, unknown>,
): string | null {
  const retired = rejectRetiredDiscoveryFields(result)
  if (retired !== null) {
    return retired
  }

  const fields = fieldsOf(result, RESULT_SUBJECT, 'utkastet')
  const bounds = discoveryAnswerBounds(task.input)
  discoveryAppraisals(fields, bounds)
  const requested = discoverySearchRequests(fields, bounds)

  if (role === 'source_discovery') {
    const proposals = optionalArray(fields, 'term_proposals')
    proposals.forEach((value, index) => {
      const proposal = nestedFields(fields, value, `term_proposals[${String(index)}]`)
      asText(proposal, 'axis')
      asText(proposal, 'label')
      asText(proposal, 'rationale')
      asOptionalText(proposal, 'from_need')
      rejectUnknown(proposal)
    })
  } else {
    const raw_control = raw(fields, 'control')
    const hasControl = raw_control !== undefined && raw_control !== null

    if (hasControl && requested > 0) {
      return (
        'Kontrollen ber om flere søk og avgjør dekningen i det samme svaret. De to er ' +
        'forskjellige utfall av én kontrollrunde: be om søkene, vurder resultatene, og avgjør ' +
        'etterpå.'
      )
    }
    if (!hasControl && requested === 0) {
      return (
        'Kontrollen verken avgjør dekningen eller ber om flere motsøk. Én av delene må stå i ' +
        'svaret: ellers er kontrollrunden uten et utfall.'
      )
    }

    if (hasControl) {
      const control = nestedFields(fields, raw_control, 'control')
      if (raw(control, 'searched_independently') !== undefined) {
        return (
          'Kontrollen erklærer selv at den søkte uavhengig, og det er ikke lenger en opplysning ' +
          'svaret gir. Antidep kjørte motsøkene under kontrollens egen rolle og kjøring, og ' +
          'leser det av søkeloggen — en erklæring et svar kan bestå ved å skrive den, ' +
          'kontrollerer ingenting.'
        )
      }
      asVocabulary(control, 'outcome', ['accepted', 'insufficient'])
      asText(control, 'note')
      nonNegativeInteger(control, 'missed_candidates')
      nonNegativeInteger(control, 'exclusions_checked')
      requiredBoolean(control, 'materiality_assessed')
      rejectUnknown(control)
    }
  }

  asOptionalText(fields, 'note')
  rejectUnknown(fields)
  return null
}

function optionalObject(fields: Fields, key: string): Record<string, unknown> | null {
  const value = raw(fields, key)
  if (value === undefined || value === null) {
    return null
  }
  if (typeof value !== 'object' || Array.isArray(value)) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke et objekt')
  }
  return value as Record<string, unknown>
}

function isCalendarDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false
  }
  const date = new Date(`${value}T00:00:00.000Z`)
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value
}

function requiredDate(fields: Fields, key: string): string {
  const value = asText(fields, key)
  if (!isCalendarDate(value)) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke en gyldig dato på formen ÅÅÅÅ-MM-DD')
  }
  return value
}

function optionalDate(fields: Fields, key: string): string | null {
  const value = asOptionalText(fields, key)
  if (value !== null && !isCalendarDate(value)) {
    problem(fields.subject, `${fields.where}.${key}`, 'er ikke en gyldig dato på formen ÅÅÅÅ-MM-DD')
  }
  return value
}

function monographAnswerProblem(result: Record<string, unknown>): string | null {
  const fields = fieldsOf(result, RESULT_SUBJECT, 'utkastet')
  const answer = nestedFields(fields, raw(fields, 'answer'), 'answer')

  asVocabulary(answer, 'knowledge_type', ['regulatory_fact', 'product_data', 'attributed_advice'])
  asText(answer, 'statement')
  optionalObject(answer, 'structured_value')
  asOptionalText(answer, 'uncertainty_summary')
  asOptionalText(answer, 'limitation_note')
  requiredDate(answer, 'as_of')
  asText(answer, 'source_quote')
  asText(answer, 'source_locator')
  asOptionalText(answer, 'recommending_body')
  optionalDate(answer, 'recommendation_date')

  const additionalSources = optionalArray(answer, 'additional_sources')
  additionalSources.forEach((value, index) => {
    const source = nestedFields(answer, value, `answer.additional_sources[${String(index)}]`)
    asUuid(source, 'source_version_id')
    asText(source, 'source_quote')
    asText(source, 'source_locator')
    requiredDate(source, 'as_of')
    rejectUnknown(source)
  })

  rejectUnknown(answer)
  rejectUnknown(fields)
  return null
}

/**
 * Om svaret holder mål, eller hvorfor det ikke gjør det.
 *
 * Returnerer én setning på norsk, eller `null`. Kaster aldri: en modell som
 * svarte noe annet enn kontrakten, er et normalt utfall for dette leddet, og
 * flaten skal kunne si hva som er galt framfor å gå i stykker.
 */
export function handoffResultProblem(
  task: AgentTask,
  result: Record<string, unknown>,
): string | null {
  try {
    switch (task.role) {
      case 'evidence_extraction':
        return extractionProblem(task, result)
      case 'claim_synthesis':
        return synthesisProblem(task, result)
      case 'evidence_assessment':
        return assessmentProblem(result)

      case 'source_discovery':
      case 'source_quality_assessment':
        return sourceDiscoveryProblem(task, task.role, result)
      case 'monograph_answer':
        return monographAnswerProblem(result)

      default: {
        const exhaustive: never = task.role
        return exhaustive
      }
    }
  } catch (cause) {
    return cause instanceof Error ? cause.message : String(cause)
  }
}
