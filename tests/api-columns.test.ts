import { readFileSync } from 'node:fs'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'

// ============================================================================
// Kolonnekontrakten i api, kontrollert mot radtypene i src/types/api.ts.
//
// MVP_IMPLEMENTATION_PLAN.md §74.7 har ført det som gjeld siden migrasjon 007:
// radtypene er håndskrevne påstander om `api`, og en kolonne som skifter navn,
// endrer type eller blir nullbar gjør dem usanne uten at noe feiler.
// `tests/api-vocabularies.test.ts` lukket vokabularhalvdelen; denne filen tar
// kolonnenavn, kolonnetyper og nullbarhet.
//
// Kontrakten er erklært ett sted — `contract`-tabellen i
// `supabase/tests/340_api_column_contract_test.sql` — og kontrolleres derfra i
// to retninger, i hver sin CI-jobb:
//
//   340_api_column_contract_test.sql  kontrakten mot den kjørende databasen
//   denne filen                       kontrakten mot radtypene i TypeScript
//
// Uten lenken hit ville de to halvdelene vært to uavhengige påstander, og
// typene ville fortsatt ikke vært bundet til databasen. Denne filen trenger
// ingen database, av samme grunn som api-vocabularies: kilden den leser er
// versjonert tekst i repoet.
//
// Kilden vinner: slår kontrollen ut, er TypeScript-typen feil — med mindre
// kontrakten selv er feil, og det sier pgTAP-filen fra om i databasejobben.
//
// ----------------------------------------------------------------------------
// Hvorfor typene leses fra AST-en og ikke fra typecheckeren
//
// `Uuid`, `Timestamptz`, `DateText` og `IntervalText` er alle alias for
// `string`. En typechecker ville løst dem opp til `string` og mistet nettopp
// skillet kontrakten handler om — en `uuid` er ikke en `date`. Derfor leses
// den *skrevne* typen: `ts.createSourceFile` parser filen uten å typesjekke
// den, og medlemmets annotasjon leses som tekst.
// ============================================================================

const CONTRACT_SQL = 'supabase/tests/340_api_column_contract_test.sql'
const API_TYPES = 'src/types/api.ts'
const DATABASE_TYPES = 'src/types/database.ts'

type ContractRow = {
  view: string
  column: string
  sqlType: string
  nullable: boolean
}

/**
 * Kontraktsradene, lest ut av `values`-listen i pgTAP-filen.
 *
 * Hver ikke-tom linje i blokken må la seg lese. En linje som ikke gjør det
 * kaster framfor å bli hoppet over: en omformatert liste skal stoppe testen,
 * ikke gjøre den stille sann på et avkortet utvalg. Det er samme feilmodus som
 * en for kort påstand i `scripts/verify-counts.sh`.
 */
function readContract(sql: string): ContractRow[] {
  const start = sql.indexOf(
    'insert into contract (view_name, column_name, sql_type, nullable) values',
  )
  if (start === -1) {
    throw new Error(`fant ingen kontraktsliste i ${CONTRACT_SQL}`)
  }
  const end = sql.indexOf(';', start)
  if (end === -1) {
    throw new Error(`kontraktslisten i ${CONTRACT_SQL} er ikke avsluttet`)
  }

  const body = sql.slice(sql.indexOf('values', start) + 'values'.length, end)
  const rows: ContractRow[] = []

  for (const raw of body.split('\n')) {
    const line = raw.trim()
    if (line.length === 0) {
      continue
    }
    const match = /^\('([a-z_]+)', '([a-z0-9_]+)', '([a-z[\] ]+)', (true|false)\),?$/.exec(line)
    if (match === null) {
      throw new Error(`kontraktslinjen lar seg ikke lese i ${CONTRACT_SQL}: ${line}`)
    }
    rows.push({
      view: match[1] as string,
      column: match[2] as string,
      sqlType: match[3] as string,
      nullable: match[4] === 'true',
    })
  }

  if (rows.length === 0) {
    throw new Error(`kontraktslisten i ${CONTRACT_SQL} er tom`)
  }
  return rows
}

type Member = {
  /** Typen slik den er skrevet, uten `| null`. */
  written: string
  nullable: boolean
}

function parse(path: string): ts.SourceFile {
  return ts.createSourceFile(path, readFileSync(path, 'utf8'), ts.ScriptTarget.Latest, true)
}

/**
 * Medlemmene i hvert `export type X = { … }` i en fil.
 *
 * `A | null` deles i den skrevne typen og nullbarheten. En union med mer enn
 * to ledd, eller med noe annet enn `null` som andre ledd, kaster: kontrakten
 * kjenner bare de to formene, og en tredje skal stoppe testen framfor å bli
 * tolket etter beste evne.
 */
function objectTypeMembers(source: ts.SourceFile): Map<string, Map<string, Member>> {
  const types = new Map<string, Map<string, Member>>()

  for (const statement of source.statements) {
    if (!ts.isTypeAliasDeclaration(statement) || !ts.isTypeLiteralNode(statement.type)) {
      continue
    }
    const members = new Map<string, Member>()

    for (const member of statement.type.members) {
      if (!ts.isPropertySignature(member) || member.type === undefined) {
        throw new Error(`uventet medlem i ${statement.name.text} i ${source.fileName}`)
      }
      const name = member.name.getText(source)

      if (ts.isUnionTypeNode(member.type)) {
        const parts = member.type.types.map((part) => part.getText(source))
        if (parts.length !== 2 || parts[1] !== 'null') {
          throw new Error(
            `${statement.name.text}.${name} har en unionsform kontrakten ikke kjenner: ${parts.join(' | ')}`,
          )
        }
        members.set(name, { written: parts[0] as string, nullable: true })
      } else {
        members.set(name, { written: member.type.getText(source), nullable: false })
      }
    }
    types.set(statement.name.text, members)
  }

  return types
}

/**
 * Navnene på de lukkede vokabularene: `export type Y = (typeof X)[number]` der
 * `X` er en `as const`-liste av strengliteraler.
 *
 * De er alle `text` i databasen — enum-verdiene castes til text i viewene — og
 * utledes framfor å listes opp her, slik at et nytt vokabular ikke trenger en
 * endring to steder for å bli gjenkjent.
 */
function textVocabularies(source: ts.SourceFile): Set<string> {
  const stringConstants = new Set<string>()

  for (const statement of source.statements) {
    if (!ts.isVariableStatement(statement)) {
      continue
    }
    for (const declaration of statement.declarationList.declarations) {
      const initializer = declaration.initializer
      if (
        initializer !== undefined &&
        ts.isAsExpression(initializer) &&
        ts.isArrayLiteralExpression(initializer.expression) &&
        initializer.expression.elements.every((element) => ts.isStringLiteral(element))
      ) {
        stringConstants.add(declaration.name.getText(source))
      }
    }
  }

  const vocabularies = new Set<string>()
  for (const statement of source.statements) {
    if (!ts.isTypeAliasDeclaration(statement)) {
      continue
    }
    const written = statement.type.getText(source)
    const match = /^\(typeof (\w+)\)\[number\]$/.exec(written)
    if (match !== null && stringConstants.has(match[1] as string)) {
      vocabularies.add(statement.name.text)
    }
  }
  return vocabularies
}

/**
 * Aliasene som gir en `string` sin SQL-betydning: `export type Uuid = string`.
 *
 * Kontrakten skiller `uuid`, `date`, `interval` og `timestamptz` fra hverandre
 * og fra ren tekst, og alle fire er `string` i TypeScript. Utledningen krever
 * at aliaset faktisk er `string`, slik at et alias som endres til noe annet
 * ikke stilltiende fortsetter å bety det samme.
 */
function stringAliases(source: ts.SourceFile): Set<string> {
  const aliases = new Set<string>()
  for (const statement of source.statements) {
    if (ts.isTypeAliasDeclaration(statement) && statement.type.getText(source) === 'string') {
      aliases.add(statement.name.text)
    }
  }
  return aliases
}

/**
 * `api`-viewene i `Database`-typen, med radtypen hver av dem er parametrisert
 * med. Kartet er ikke skrevet ned her: leses det ut av `database.ts`, må et
 * nytt view i kontrakten også være erklært for supabase-js for at kontrollen
 * skal gå opp — og et view som fjernes fra `Database` uten å fjernes fra
 * kontrakten slår ut på samme måte.
 */
function databaseViewRowTypes(source: ts.SourceFile): Map<string, string> {
  const views = new Map<string, string>()

  const visit = (node: ts.Node): void => {
    if (
      ts.isPropertySignature(node) &&
      node.name.getText(source) === 'Views' &&
      node.type !== undefined &&
      ts.isTypeLiteralNode(node.type)
    ) {
      for (const view of node.type.members) {
        if (!ts.isPropertySignature(view) || view.type === undefined) {
          throw new Error(`uventet Views-medlem i ${source.fileName}`)
        }
        const row = view.type.getText(source).match(/Row:\s*(\w+)/)?.[1]
        if (row === undefined) {
          throw new Error(
            `fant ingen Row-type for ${view.name.getText(source)} i ${DATABASE_TYPES}`,
          )
        }
        views.set(view.name.getText(source), row)
      }
      return
    }
    ts.forEachChild(node, visit)
  }
  ts.forEachChild(source, visit)

  if (views.size === 0) {
    throw new Error(`fant ingen views i Database-typen i ${DATABASE_TYPES}`)
  }
  return views
}

const contract = readContract(readFileSync(CONTRACT_SQL, 'utf8'))
const apiSource = parse(API_TYPES)
const rowTypes = objectTypeMembers(apiSource)
const vocabularies = textVocabularies(apiSource)
const aliases = stringAliases(apiSource)
const viewRowTypes = databaseViewRowTypes(parse(DATABASE_TYPES))

/**
 * SQL-typen bestemmer hvilke skrevne TypeScript-typer som er tillatt.
 *
 * `number` dekker `integer`, `bigint` og `numeric`, og det er ikke en
 * slapphet: TypeScript har ett talltype-begrep, og kontrakten kan ikke påstå
 * et skille språket ikke har. Presisjonen ligger i SQL-typen, som pgTAP-filen
 * kontrollerer mot katalogen.
 */
function allowedWrittenTypes(sqlType: string): Set<string> {
  switch (sqlType) {
    case 'uuid':
      return new Set(['Uuid'])
    case 'text':
      return new Set(['string', ...vocabularies])
    case 'text[]':
      return new Set(['string[]'])
    case 'integer':
    case 'bigint':
    case 'numeric':
      return new Set(['number'])
    case 'boolean':
      return new Set(['boolean'])
    case 'interval':
      return new Set(['IntervalText'])
    case 'date':
      return new Set(['DateText'])
    case 'timestamp with time zone':
      return new Set(['Timestamptz'])
    default:
      // En SQL-type kontrakten ikke kjenner skal stoppe testen, ikke gli forbi
      // den. Samme regel som «ukjent alter type»-formen i api-vocabularies.
      throw new Error(`kontrakten bruker en SQL-type denne testen ikke kjenner: ${sqlType}`)
  }
}

describe('kontrakten og Database-typen navngir de samme viewene', () => {
  it('hvert view i kontrakten er erklært i Database-typen, og omvendt', () => {
    expect(new Set(viewRowTypes.keys())).toEqual(new Set(contract.map((row) => row.view)))
  })

  it('hver radtype Database viser til finnes i api.ts', () => {
    for (const [view, rowType] of viewRowTypes) {
      expect(rowTypes.has(rowType), `${view} viser til ${rowType}`).toBe(true)
    }
  })
})

describe('aliasene og vokabularene kontrakten hviler på finnes', () => {
  it('de fire SQL-betydningsaliasene er alias for string', () => {
    // Endres ett av dem til noe annet, slutter det å bety det kontrakten sier.
    for (const alias of ['Uuid', 'Timestamptz', 'DateText', 'IntervalText']) {
      expect(aliases.has(alias), `${alias} er alias for string`).toBe(true)
    }
  })

  it('de lukkede vokabularene blir gjenkjent som tekstverdier', () => {
    // Uten dette ville et vokabular som ikke ble gjenkjent gitt «ukjent type»
    // for hver kolonne som bruker det — en støyende feil, men på feil sted.
    expect(vocabularies.has('KnowledgeType')).toBe(true)
    expect(vocabularies.has('CertaintyLevel')).toBe(true)
    expect(vocabularies.has('SourceStatus')).toBe(true)
    expect(vocabularies.has('Uuid')).toBe(false)
  })
})

describe('hver kolonne i kontrakten har sin egenskap i radtypen', () => {
  it.each(contract.map((row) => [`${row.view}.${row.column}`, row] as [string, ContractRow]))(
    '%s',
    (_label, row) => {
      const rowType = viewRowTypes.get(row.view)
      expect(rowType, `${row.view} er erklært i Database-typen`).toBeDefined()

      const members = rowTypes.get(rowType as string)
      expect(members, `${rowType} finnes i ${API_TYPES}`).toBeDefined()

      const member = (members as Map<string, Member>).get(row.column)
      expect(member, `${rowType}.${row.column} finnes`).toBeDefined()

      const allowed = allowedWrittenTypes(row.sqlType)
      expect(
        allowed.has((member as Member).written),
        `${rowType}.${row.column} er skrevet som ${(member as Member).written}, som ikke svarer til ${row.sqlType}`,
      ).toBe(true)

      // Nullbarheten er den halvdelen information_schema.columns ikke kan
      // svare på; kontraktsverdien er målt på faktiske rader i pgTAP-filen.
      expect(
        (member as Member).nullable,
        `${rowType}.${row.column} skal ${row.nullable ? '' : 'ikke '}kunne være null`,
      ).toBe(row.nullable)
    },
  )
})

describe('radtypene har ingen egenskaper kontrakten ikke dekker', () => {
  it.each([...viewRowTypes].map(([view, rowType]) => [rowType, view, rowType] as const))(
    '%s',
    (_label, view, rowType) => {
      const declared = new Set((rowTypes.get(rowType) as Map<string, Member>).keys())
      const covered = new Set(contract.filter((row) => row.view === view).map((row) => row.column))
      // Begge veier i én sammenligning: en egenskap uten kolonne er en påstand
      // om en kolonne som ikke finnes, og en kolonne uten egenskap er en
      // kolonne klienten ikke kan lese.
      expect(declared).toEqual(covered)
    },
  )
})
