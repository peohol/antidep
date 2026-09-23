// ============================================================================
// FEST — den norske myndighetskilden, lest av Antideps egen kode
//
// FEST (Forskrivnings- og ekspedisjonsstøtte) er Direktoratet for medisinske
// produkters nasjonale distribusjon av legemiddeldata. Filen er fritt
// tilgjengelig under Norsk lisens for offentlige data (NLOD), oppdateres to
// ganger i måneden, og er den kilden forskrivningssystemene selv bygger på. For
// REG- og PROD-sporene er det nettopp «direkte kontroll i relevant norsk
// myndighetskilde og kildeversjon» (SOURCE_POLICY.md §4.2):
//
//   OppfLegemiddelMerkevare  hvert markedsført preparat: navn, form, styrke,
//                            reseptgruppe, preparattype (også uregistrerte
//                            preparater med godkjenningsfritak) og lenken til
//                            gjeldende preparatomtale
//   OppfLegemiddelpakning    hver pakning: varenummer, markedsføringsdato,
//                            midlertidig utgått, utgående varenummer
//   OppfVarselSlv            DMPs egne varsler — sikkerhetsinformasjon,
//                            leveringssvikt, retningslinjer og råd — med
//                            referanse til nøyaktig de preparatene de gjelder
//
// ----------------------------------------------------------------------------
// Hvorfor en egen ZIP-leser
//
// Filen distribueres som én ZIP med én XML-fil. Node har inflate, men ingen
// ZIP-leser, og en avhengighet for tjue linjer ville vært en ny forsyningskjede
// for en kjøring med databaselegitimasjon. Leseren her leser den sentrale
// katalogen, finner filen, inflaterer den og kontrollerer CRC-32 mot katalogen:
// en fil som ikke stemmer med sin egen kontrollsum, er ikke FEST, og da er
// søket `failed` framfor et resultat.
//
// ----------------------------------------------------------------------------
// Hvorfor ingen XML-parser
//
// Av samme grunn, og fordi det Antidep leser, er faste, flate elementer i en
// publisert meldingsbeskrivelse (M30). Hver oppføring er en blokk med et kjent
// start- og sluttmerke, og feltene er enkle elementer og attributter. Skjer det
// noe uventet — et manglende rotelement, en tom katalog — er svaret `failed`,
// aldri en tom treffliste.
// ============================================================================

import { crc32, inflateRawSync } from 'node:zlib'

/** Hvor FEST-filen for rekvirenter hentes, slik DMP publiserer den. */
export const FEST_URL =
  'https://www.dmp.no/globalassets/documents/om-oss/distribusjon-av-legemiddeldata/fest/festfiler/fest251.zip'

/** Hvor stor filen kan være før hentingen avbrytes. Filen er rundt 15 MB. */
export const FEST_MAX_BYTES = 48 * 1024 * 1024

/** Én fil lest ut av et ZIP-arkiv. */
export interface ZipEntry {
  readonly name: string
  readonly bytes: Uint8Array
}

function readUInt16(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8)
}

function readUInt32(bytes: Uint8Array, offset: number): number {
  return (
    ((bytes[offset] ?? 0) |
      ((bytes[offset + 1] ?? 0) << 8) |
      ((bytes[offset + 2] ?? 0) << 16) |
      ((bytes[offset + 3] ?? 0) << 24)) >>>
    0
  )
}

/**
 * Filene i et ZIP-arkiv, lest av den sentrale katalogen.
 *
 * Bare metodene «lagret» (0) og «deflate» (8), som er det FEST bruker. Hver fil
 * kontrolleres mot CRC-32 og størrelsen katalogen oppgir. Kaster når arkivet
 * ikke er et arkiv: kalleren gjør det til `failed`.
 */
export function readZip(archive: Uint8Array, maxUncompressed = 512 * 1024 * 1024): ZipEntry[] {
  // Slutten av den sentrale katalogen: signaturen 0x06054b50, lest bakfra fordi
  // en kommentar kan stå etter den.
  let end = -1
  for (
    let offset = archive.length - 22;
    offset >= Math.max(0, archive.length - 65_557);
    offset -= 1
  ) {
    if (readUInt32(archive, offset) === 0x06054b50) {
      end = offset
      break
    }
  }
  if (end < 0) {
    throw new Error('Arkivet har ingen sentral katalog.')
  }

  const count = readUInt16(archive, end + 10)
  let pointer = readUInt32(archive, end + 16)
  const entries: ZipEntry[] = []

  for (let index = 0; index < count; index += 1) {
    if (readUInt32(archive, pointer) !== 0x02014b50) {
      throw new Error('Den sentrale katalogen er skadet.')
    }
    const method = readUInt16(archive, pointer + 10)
    const expectedCrc = readUInt32(archive, pointer + 16)
    const compressedSize = readUInt32(archive, pointer + 20)
    const uncompressedSize = readUInt32(archive, pointer + 24)
    const nameLength = readUInt16(archive, pointer + 28)
    const extraLength = readUInt16(archive, pointer + 30)
    const commentLength = readUInt16(archive, pointer + 32)
    const localOffset = readUInt32(archive, pointer + 42)
    const name = new TextDecoder('utf-8').decode(
      archive.subarray(pointer + 46, pointer + 46 + nameLength),
    )
    pointer += 46 + nameLength + extraLength + commentLength

    if (uncompressedSize > maxUncompressed) {
      throw new Error(`Filen ${name} er større enn grensen for utpakking.`)
    }
    if (readUInt32(archive, localOffset) !== 0x04034b50) {
      throw new Error(`Filen ${name} har ikke et gyldig lokalt hode.`)
    }
    const localName = readUInt16(archive, localOffset + 26)
    const localExtra = readUInt16(archive, localOffset + 28)
    const start = localOffset + 30 + localName + localExtra
    const compressed = archive.subarray(start, start + compressedSize)

    let bytes: Uint8Array
    if (method === 0) {
      bytes = compressed
    } else if (method === 8) {
      bytes = new Uint8Array(inflateRawSync(compressed, { maxOutputLength: maxUncompressed }))
    } else {
      throw new Error(`Filen ${name} bruker en komprimering leseren ikke kjenner (${method}).`)
    }

    if (bytes.length !== uncompressedSize || crc32(bytes) >>> 0 !== expectedCrc) {
      throw new Error(`Filen ${name} stemmer ikke med sin egen kontrollsum.`)
    }
    entries.push({ name, bytes })
  }

  return entries
}

/** Ett markedsført eller registrert preparat, slik FEST fører det. */
export interface FestProduct {
  readonly entryId: string
  readonly productId: string
  readonly atc: string
  readonly substance: string
  readonly nameFormStrength: string
  readonly brand: string
  readonly form: string
  readonly prescriptionGroup: string | null
  readonly productType: string
  readonly manufacturer: string | null
  readonly status: string
  readonly updatedAt: string
  readonly smpcUrls: readonly string[]
}

/** Én pakning, med markedsføringsopplysningene. */
export interface FestPackage {
  readonly packageId: string
  readonly productId: string | null
  readonly atc: string
  readonly nameFormStrength: string
  readonly itemNumber: string
  readonly marketedFrom: string | null
  readonly temporarilyUnavailableFrom: string | null
  readonly replacedItemNumber: string | null
}

/** Ett varsel fra DMP, med preparatene det gjelder. */
export interface FestNotice {
  readonly entryId: string
  readonly kind: string
  readonly heading: string
  readonly text: string
  readonly from: string | null
  readonly url: string | null
  readonly references: readonly string[]
}

/** Det FEST sier om ett virkestoff. */
export interface FestSubstanceRecord {
  readonly retrievedAt: string
  readonly atcCodes: readonly string[]
  readonly products: readonly FestProduct[]
  readonly packages: readonly FestPackage[]
  readonly notices: readonly FestNotice[]
}

function decodeXml(value: string): string {
  return value
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_all, code: string) => String.fromCodePoint(Number.parseInt(code, 10)))
    .replace(/&amp;/g, '&')
}

function element(block: string, name: string): string | null {
  const match = new RegExp(`<${name}>([^<]*)</${name}>`).exec(block)
  return match === null ? null : decodeXml(match[1] ?? '').trim()
}

function attribute(block: string, name: string, attr: 'V' | 'DN'): string | null {
  const match = new RegExp(`<${name}\\b[^>]*\\b${attr}="([^"]*)"`).exec(block)
  return match === null ? null : decodeXml(match[1] ?? '').trim()
}

function blocks(xml: string, name: string): string[] {
  return [...xml.matchAll(new RegExp(`<${name}>[\\s\\S]*?</${name}>`, 'g'))].map(
    (match) => match[0],
  )
}

/**
 * Id-en til selve produktet, ikke oppføringens. Varsler og pakninger peker på
 * den. Oppføringens egen <Id> står før det indre elementet; den første <Id>
 * inne i det er produktets (M30: underelementene foran den har ingen <Id>).
 */
function innerId(block: string, inner: string): string | null {
  const start = block.indexOf(`<${inner}`)
  return start < 0 ? null : element(block.slice(start), 'Id')
}

/**
 * Leser det FEST sier om ett virkestoff, avgrenset av ATC-kodene — eller, når
 * katalogen ikke har en ATC-kode, av virkestoffnavnet FEST fører på koden.
 *
 * Kaster når dokumentet ikke har formen til FEST: kalleren gjør det til
 * `failed`, aldri til null treff.
 */
export function readFestSubstance(
  xml: string,
  atcCodes: readonly string[],
  substanceNames: readonly string[],
): FestSubstanceRecord {
  if (!xml.includes('<FEST') || !xml.includes('<KatLegemiddelMerkevare>')) {
    throw new Error('Dokumentet har ikke formen til en FEST-fil.')
  }
  const retrievedAt = element(xml.slice(0, 4_000), 'HentetDato')
  if (retrievedAt === null) {
    throw new Error('FEST-filen sier ikke når den ble hentet ut.')
  }

  const wantedAtc = new Set(atcCodes.map((code) => code.trim().toUpperCase()))
  const wantedNames = new Set(substanceNames.map((name) => name.trim().toLowerCase()))
  const matches = (block: string): boolean => {
    const atc = attribute(block, 'Atc', 'V')?.toUpperCase() ?? ''
    const name = attribute(block, 'Atc', 'DN')?.toLowerCase() ?? ''
    return wantedAtc.size > 0 ? wantedAtc.has(atc) : wantedNames.has(name)
  }

  const products: FestProduct[] = blocks(xml, 'OppfLegemiddelMerkevare')
    .filter(matches)
    .map((block) => ({
      entryId: element(block, 'Id') ?? '',
      productId: innerId(block, 'LegemiddelMerkevare') ?? '',
      atc: attribute(block, 'Atc', 'V') ?? '',
      substance: attribute(block, 'Atc', 'DN') ?? '',
      nameFormStrength: element(block, 'NavnFormStyrke') ?? '',
      brand: element(block, 'Varenavn') ?? '',
      form:
        element(block, 'LegemiddelformLang') ?? attribute(block, 'LegemiddelformKort', 'DN') ?? '',
      prescriptionGroup: attribute(block, 'Reseptgruppe', 'DN'),
      productType: attribute(block, 'Preparattype', 'DN') ?? '',
      manufacturer: element(block, 'Produsent'),
      status: attribute(block, 'Status', 'DN') ?? '',
      updatedAt: element(block, 'Tidspunkt') ?? '',
      smpcUrls: [
        ...new Set(
          [...block.matchAll(/<Www V="([^"]+)"/g)].map((match) => decodeXml(match[1] ?? '')),
        ),
      ].filter((url) => url.startsWith('https://')),
    }))

  const packages: FestPackage[] = blocks(xml, 'OppfLegemiddelpakning')
    .filter(matches)
    .map((block) => ({
      packageId: innerId(block, 'Legemiddelpakning') ?? '',
      productId: element(block, 'RefLegemiddelMerkevare'),
      atc: attribute(block, 'Atc', 'V') ?? '',
      nameFormStrength: element(block, 'NavnFormStyrke') ?? '',
      itemNumber: element(block, 'Varenr') ?? '',
      marketedFrom: element(block, 'Markedsforingsdato'),
      temporarilyUnavailableFrom: element(block, 'MidlUtgattDato'),
      replacedItemNumber: element(block, 'VarenrUtgaende'),
    }))

  const referenced = new Set([
    ...products.map((product) => product.productId),
    ...packages.map((pack) => pack.packageId),
  ])

  const notices: FestNotice[] = blocks(xml, 'OppfVarselSlv')
    .map((block) => ({
      entryId: element(block, 'Id') ?? '',
      kind: attribute(block, 'Type', 'DN') ?? '',
      heading: element(block, 'Overskrift') ?? '',
      text: element(block, 'Varseltekst') ?? '',
      from: element(block, 'FraDato'),
      url: /<Www V="([^"]+)"/.exec(block)?.[1] ?? null,
      references: [...block.matchAll(/<RefElement>([^<]+)<\/RefElement>/g)].map(
        (match) => match[1] ?? '',
      ),
    }))
    .filter((notice) => notice.references.some((reference) => referenced.has(reference)))

  return { retrievedAt, atcCodes: [...wantedAtc], products, packages, notices }
}
