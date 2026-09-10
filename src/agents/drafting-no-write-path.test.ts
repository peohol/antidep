// ============================================================================
// Modell-leddet har ingen skjult skrivevei inn i Antidep
//
// EVIDENCE_PIPELINE.md §63: et ledd som leser utrygt eksternt innhold, skal
// ikke samtidig ha tilgang til hemmeligheter eller en skrivevei. Det er sagt i
// hodekommentarene til hver av modulene i modell-leddet — men en hodekommentar
// er en påstand, og en `import`-linje er et faktum.
//
// Testen leser importgrafen fra hver av inngangene til modell-leddet, følger
// hver relative import den finner, og krever to ting:
//
//   1. **Ingen av modulene som kan skrive, er nåbare.** Agentporten,
//      legitimasjonen, miljøet med hemmeligheten, og hver kjøring som
//      registrerer noe.
//   2. **Ingen tredjepartsavhengighet er nåbar.** De eneste bare
//      spesifikatorene i grafen er innebygde Node-moduler. Da kan heller ikke
//      en databaseklient komme inn bakveien, uansett hva den måtte hete.
//
// Type-only-importer regnes med, selv om de forsvinner i kjøring. Grensen skal
// kunne leses av et menneske som ser på en importliste, og en liste der én av
// linjene er ufarlig av en grunn som ikke står der, er ikke en lesbar grense.
//
// Kontrollen prøves også *motsatt* vei: de samme forbudte modulene skal være
// nåbare fra registreringskjøreren. Uten den ville en ødelagt vandrer gitt en
// grønn test som ikke prøvde noe.
// ============================================================================

import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const AGENTS = resolve(import.meta.dirname)

/** Inngangene til modell-leddet: alt en Routine eller en operatør kan kjøre. */
const MODEL_STEP_ENTRIES = [
  'draft-extraction-cli.ts',
  'propose-extraction-cli.ts',
  'drafting-job.ts',
  'drafting-run.ts',
  'model-adapters.ts',
  'model-answer.ts',
  'recorded-model.ts',
  'extraction-assignment.ts',
  'extraction-prompt.ts',
]

/** Modulene som kan skrive en rad, eller som bærer det som trengs for å gjøre det. */
const FORBIDDEN = [
  'agent-api.ts',
  'agent-credential.ts',
  'agent-environment.ts',
  'agent-env-file.ts',
  'extraction-run.ts',
  'reextraction-run.ts',
  'extraction-verification-run.ts',
  'claim-verification-run.ts',
  join('..', 'lib', 'supabase.ts'),
]

const IMPORT_PATTERNS = [
  /(?:^|\n)\s*(?:import|export)[\s\S]*?\sfrom\s*['"]([^'"]+)['"]/g,
  /(?:^|\n)\s*import\s*['"]([^'"]+)['"]/g,
  /\bimport\(\s*['"]([^'"]+)['"]\s*\)/g,
]

function specifiersIn(text: string): readonly string[] {
  const found = new Set<string>()
  for (const pattern of IMPORT_PATTERNS) {
    for (const match of text.matchAll(pattern)) {
      const specifier = match[1]
      if (specifier !== undefined) {
        found.add(specifier)
      }
    }
  }
  return [...found]
}

/**
 * Én relativ import til en fil på disk.
 *
 * Endelsen er valgfri i `src/lib`, som skrives mot bundlerens oppslag, og
 * påkrevd i `src/agents`, som kjøres av Node. Vandreren tar imot begge framfor
 * å stoppe på den ene formen — en fil den ikke finner, ville blitt en gren av
 * grafen som ikke ble gått, og det er nettopp der en skrivevei ville kunnet
 * gjemme seg.
 */
function resolveModule(from: string, specifier: string): string {
  const direct = resolve(from, specifier)
  for (const candidate of [direct, `${direct}.ts`, join(direct, 'index.ts')]) {
    if (existsSync(candidate)) {
      return candidate
    }
  }
  throw new Error(`Fant ikke ${specifier} fra ${from}.`)
}

interface Graph {
  /** Hver fil som er nåbar, som en sti relativ til `src/agents`. */
  readonly modules: ReadonlySet<string>
  /** Hver spesifikator som ikke er en fil i repoet. */
  readonly external: ReadonlySet<string>
}

/** Går importgrafen fra én inngang, og tar med alt den kan nå. */
function reachableFrom(entry: string): Graph {
  const modules = new Set<string>()
  const external = new Set<string>()
  const queue = [entry]

  while (queue.length > 0) {
    const current = queue.pop() as string
    if (modules.has(current)) {
      continue
    }
    modules.add(current)

    const text = readFileSync(join(AGENTS, current), 'utf8')
    for (const specifier of specifiersIn(text)) {
      if (!specifier.startsWith('.')) {
        external.add(specifier)
        continue
      }
      queue.push(relative(AGENTS, resolveModule(dirname(join(AGENTS, current)), specifier)))
    }
  }
  return { modules, external }
}

describe('modell-leddet når ikke noe som kan skrive', () => {
  for (const entry of MODEL_STEP_ENTRIES) {
    it(`${entry} når ingen av modulene som kan skrive en rad`, () => {
      const graph = reachableFrom(entry)
      const reached = FORBIDDEN.filter((module) => graph.modules.has(module))
      expect(reached).toEqual([])
    })

    it(`${entry} bruker ingen andre avhengigheter enn Node selv`, () => {
      const graph = reachableFrom(entry)
      const external = [...graph.external].filter((name) => !name.startsWith('node:')).sort()
      expect(external).toEqual([])
    })
  }
})

describe('kontrollen kan faktisk se en skrivevei', () => {
  // Uten denne ville en vandrer som stoppet på første fil, gitt grønt for alt
  // over uten å ha prøvd noe. Registreringskjøreren *skal* nå både agentporten,
  // legitimasjonen og databaseklienten — det er den som har lov.
  it('registreringskjøreren når agentporten, legitimasjonen og databaseklienten', () => {
    const graph = reachableFrom('extract-evidence-cli.ts')
    expect(graph.modules.has('agent-api.ts')).toBe(true)
    expect(graph.modules.has('agent-environment.ts')).toBe(true)
    expect(graph.external.has('@supabase/supabase-js')).toBe(true)
  })
})
