// ============================================================================
// Opptaksadapteret: modell-leddet kjørt deterministisk, uten leverandørkonto
//
// Et opptak er et modellsvar lagret sammen med fingeravtrykket av forespørselen
// det svarte på. Adapteret slår opp svaret på nettopp det avtrykket, og finner
// det ikke, svarer det ikke.
//
// ----------------------------------------------------------------------------
// Hvorfor dette ikke er en test-dobbel
//
// Adapteret er et fullverdig ledd, ikke en attrapp som finnes for testenes
// skyld, og det er tre ting det gjør i drift:
//
//   * **Prøver kjeden uten kostnad.** Hele veien fra kilde til publisert
//     påstand kan kjøres, om igjen og om igjen, uten en leverandørkonto. Det er
//     forutsetningen for at `scripts/agent-chain-test.ts` kan prøve modell-leddet
//     mot en ekte database.
//   * **Gjør en modellkjøring reproduserbar.** Full determinisme kan ikke
//     kreves av en språkmodell (EVIDENCE_PIPELINE.md §65), men et opptak av det
//     som faktisk ble svart, kan kjøres om igjen gjennom nøyaktig de samme
//     kontrollene. En kjøring som ble avvist, kan derfor undersøkes uten å bli
//     en annen kjøring.
//   * **Er arbeidsformen i dag.** Utkastet lages utenfor Antidep, av ChatGPT
//     eller et menneske, ut av den prompten `--prepare` skriver ut. Svaret
//     limes inn i opptaket, og resten av kjeden er den samme som med et
//     innebygd leverandøradapter (`assignments/README.md`).
//
// ----------------------------------------------------------------------------
// Hvorfor oppslaget er på avtrykket og ikke på et navn
//
// Et opptak nøklet på et filnavn ville kunnet spilles av for en *annen*
// artikkel: forespørselen inneholder hele representasjonen, så et svar som
// passet på hva som helst, ville vært et svar som ikke var lest ut av noe.
// Avtrykket binder svaret til nøyaktig den representasjonen, den katalogen og
// den promptmalen det ble gitt til. Endres én av dem, finnes ikke svaret
// lenger — og det er riktig utfall, ikke et hinder.
//
// Utrygg inndata: opptaket er data. Svaret i det leses bare som et utkast som
// skal gjennom `parseExtractionDraft` og den ordrette kontrollen, aldri som en
// instruksjon (CLAUDE.md).
// ============================================================================

import { modelRequestDigest, type ModelClient } from './model-client.ts'
import { parseModelIdentity, PLACEHOLDER_IDENTITY, type ModelIdentity } from './model-identity.ts'
import {
  asText,
  asObjectList,
  fieldsOf,
  nestedFields,
  problem,
  raw,
  rejectUnknown,
  type Fields,
} from './strict-fields.ts'

const RECORDING_SUBJECT = 'Modellopptaket'

/** Versjonen av opptaksformen, oppgitt i hver fil. */
export const MODEL_RECORDING_VERSION = 'antidep/model-recording@1'

/** Ett svar, bundet til forespørselen det svarte på. */
export interface RecordedCompletion {
  readonly requestDigest: string
  readonly promptTemplateVersion: string
  /** Svaret ordrett. Tom streng betyr et opptak som ennå ikke er fylt ut. */
  readonly completion: string
}

export interface ModelRecording {
  readonly recordingVersion: typeof MODEL_RECORDING_VERSION
  readonly identity: ModelIdentity
  readonly entries: readonly RecordedCompletion[]
}

const DIGEST_PATTERN = /^sha256:[0-9a-f]{64}$/

function parseEntry(parent: Fields, value: unknown, index: number): RecordedCompletion {
  const fields = nestedFields(parent, value, `entries[${String(index)}]`)
  const requestDigest = asText(fields, 'request_digest')
  if (!DIGEST_PATTERN.test(requestDigest)) {
    problem(
      fields.subject,
      `${fields.where}.request_digest`,
      'har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn',
    )
  }
  const promptTemplateVersion = asText(fields, 'prompt_template_version')
  // Svaret kan være tomt, og bare her: et opptak skrevet av `--prepare` er en
  // tom form som venter på at noen limer inn modellens svar. En tom streng
  // avvises av oppslaget med en setning som sier nettopp det, framfor her, der
  // feilen ville sett ut som en ødelagt fil.
  const completion = raw(fields, 'completion')
  if (typeof completion !== 'string') {
    problem(fields.subject, `${fields.where}.completion`, 'mangler eller er ikke tekst')
  }
  rejectUnknown(fields)
  return { requestDigest, promptTemplateVersion, completion }
}

/** Leser og kontrollerer ett opptak, eller sier hvilket felt som er galt. */
export function parseModelRecording(value: unknown): ModelRecording {
  const fields = fieldsOf(value, RECORDING_SUBJECT, 'opptaket')

  const version = asText(fields, 'recording_version')
  if (version !== MODEL_RECORDING_VERSION) {
    problem(
      RECORDING_SUBJECT,
      'opptaket.recording_version',
      `er ${JSON.stringify(version)}, men denne kjøreren leser ${JSON.stringify(MODEL_RECORDING_VERSION)}`,
    )
  }

  const identity = parseModelIdentity(fields, raw(fields, 'identity'))
  const entryValues = asObjectList(fields, 'entries')
  rejectUnknown(fields)

  const entries = entryValues.map((entry, index) => parseEntry(fields, entry, index))
  const seen = new Set<string>()
  for (const entry of entries) {
    if (seen.has(entry.requestDigest)) {
      problem(
        RECORDING_SUBJECT,
        'opptaket.entries',
        `har to svar på den samme forespørselen (${entry.requestDigest})`,
      )
    }
    seen.add(entry.requestDigest)
  }

  return { recordingVersion: MODEL_RECORDING_VERSION, identity, entries }
}

/**
 * Adapteret som svarer fra et opptak.
 *
 * En forespørsel uten opptak er en feil og ikke et tomt svar: et adapter som
 * svarte noe likevel, ville produsert et utkast som ikke var lest ut av
 * representasjonen. Meldingen navngir avtrykket, som er det kalleren trenger
 * for å fylle ut opptaket.
 */
export function createRecordedModelClient(recording: ModelRecording): ModelClient {
  return {
    identity: recording.identity,
    async complete(request) {
      const digest = await modelRequestDigest(request)
      const entry = recording.entries.find((candidate) => candidate.requestDigest === digest)
      if (entry === undefined) {
        const versions = new Set(recording.entries.map((e) => e.promptTemplateVersion))
        const versionNote = versions.has(request.promptTemplateVersion)
          ? ''
          : ` Opptaket er laget for promptmalen ${[...versions].join(', ')}, mens denne kjøringen bruker ${request.promptTemplateVersion}.`
        throw new Error(
          `Opptaket har ikke noe svar på denne forespørselen (${digest}).${versionNote} ` +
            'Forespørselen dekker representasjonen, katalogen i oppdraget og promptmalen; ' +
            'endres én av dem, gjelder ikke et gammelt svar. Kjør med --prepare for å skrive ' +
            'ut prompten og et tomt opptak med riktig avtrykk.',
        )
      }
      if (entry.completion.trim().length === 0) {
        throw new Error(
          `Opptaket har en tom plass for denne forespørselen (${digest}). Lim modellens svar ` +
            'inn i completion og kjør igjen.',
        )
      }
      return { text: entry.completion }
    },
  }
}

/**
 * Et tomt opptak for én forespørsel, med riktig avtrykk.
 *
 * Skrives av `--prepare` sammen med selve prompten. Identiteten står med
 * plassholdere som den som kjørte modellen, skal rette: verdiene havner i
 * `provenance.agent_runs` som premissene utkastet ble laget under. En
 * plassholder som blir stående, avvises av `parseModelRecording` framfor å bli
 * en usann proveniens (ANTIDEP_CONSTITUTION.md §20).
 */
export function emptyRecording(requestDigest: string, promptTemplateVersion: string): unknown {
  return {
    recording_version: MODEL_RECORDING_VERSION,
    identity: PLACEHOLDER_IDENTITY,
    entries: [
      {
        request_digest: requestDigest,
        prompt_template_version: promptTemplateVersion,
        completion: '',
      },
    ],
  }
}
