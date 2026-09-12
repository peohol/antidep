// ============================================================================
// Leserekkefølgen: fra hvor ordene står på siden, til hvilken tekst de er
//
// En PDF har ingen tekst og ingen rekkefølge. Den har glyfer med koordinater.
// `pdftotext -layout` gjenskaper den **fysiske** plasseringen: står to spalter
// ved siden av hverandre på papiret, står de ved siden av hverandre på linjen —
// og en setning fra venstre spalte ender med mellomrom og deretter en setning
// fra høyre spalte.
//
// Det er ikke et visningsproblem. Antideps ordrette kontroll normaliserer
// blanktegn før den søker (`extraction-checks.ts`), og to spalter som ligger
// side om side på samme linje, blir da én sammenhengende tegnstrøm. En modell
// eller en deterministisk kontroll kan lese ord fra to uavhengige spalter som
// én setning, og en klinisk opplysning kan bli tilskrevet feil arm, feil studie
// eller feil endepunkt. Det er en evidensintegritetsfeil
// (ANTIDEP_CONSTITUTION.md §8, §11, issue #84).
//
// Denne modulen er Antideps eget svar: den leser posisjonsdataene fra Poppler
// (`pdftotext -bbox-layout`) og bygger den **logiske leserekkefølgen**
// deterministisk, eller nekter.
//
// ----------------------------------------------------------------------------
// Hva algoritmen bygger på, og hva den aldri gjør
//
// Den flytter blokker. Den skriver ikke tekst: hvert ord kommer ordrett fra
// verktøyets utdata, og ingen bokstav, tegnsetting eller orddeling finnes på.
// «selec-» og «tive» på hver sin linje blir «selec-» og «tive» — å sette dem
// sammen ville vært å lage et ord som ikke står i dokumentet, og «Long-» pluss
// «Term» viser hvorfor den regelen ikke kan gjøres trygg.
//
// ----------------------------------------------------------------------------
// Rekkefølgen: rekursivt snitt på tomrom
//
// Per side, og rekursivt på hver del:
//
//   1. Finnes en **loddrett tomromskorridor** som ingen blokk krysser, og som
//      er bred nok til å være en spaltemarg? Del der, og les venstre del før
//      høyre. Dette er spaltesnittet.
//   2. Ellers: finnes **vannrette tomromsbånd** som ingen blokk krysser? Del
//      der, og les øverste bånd først.
//   3. Ellers er delen et blad, og blokkene leses ovenfra og ned.
//
// Loddrett før vannrett er ikke en smakssak. Motsatt rekkefølge har en kjent
// feil: har venstre og høyre spalte et avsnittsopphold på samme høyde, finnes
// det et vannrett bånd tvers over begge, og et snitt der ville gitt
// venstre-topp, høyre-topp, venstre-bunn, høyre-bunn — spaltene flettet, altså
// nøyaktig feilen modulen finnes for å hindre. Et loddrett snitt kan ikke gjøre
// det: en tittel eller en tabell over hele sidebredden krysser korridoren, og da
// finnes den ikke, og det vannrette snittet skiller først full bredde fra
// spaltene. Derfor håndteres tittel, ingress og gjennomgående overskrifter av
// den samme regelen som spaltene, uten et eget tilfelle.
//
// ----------------------------------------------------------------------------
// Når rekkefølgen ikke kan avgjøres, avvises dokumentet
//
// Et blad med to blokker som **overlapper loddrett og er atskilt vannrett** er
// to blokker side om side som ingen korridor skilte — altså en spalteinndeling
// algoritmen ikke fant. Rekkefølgen mellom dem er ikke bestemt, og en plausibel
// gjetning er verre enn ingenting: det er viktigere å avvise én vanskelig PDF
// enn å registrere kliniske data lest i feil rekkefølge. Dokumentet markeres da
// som ikke trygt ekstraherbart, og ekstraksjonen stopper.
//
// ----------------------------------------------------------------------------
// Skjev tekst har ingen plass i leserekkefølgen
//
// Et vannmerke — «Copyright 2001 … One personal copy …» på tvers av siden — er
// ikke en del av artikkelens tekst, og det ligger ofte midt i spaltemargen.
// Poppler legger det inn som ord som krysser korridoren, og `-layout` vever det
// inn mellom spaltene.
//
// Skjev tekst kjennes igjen på geometrien alene, uten å tolke et eneste ord:
// **ordene på en linje står ikke på samme grunnlinje**. I vannrett tekst dekker
// to nabo-ord hverandre nesten helt i høyden; på en skrå linje gjør de det ikke i
// det hele tatt. En slik blokk har ingen leserekkefølge å plassere, og holdes
// utenfor.
//
// Det er det eneste signalet, og avgrensningen er tilsiktet. Utelatelse er den
// dyre siden å ta feil på: en setning som forsvinner ut av representasjonen, kan
// få den kildeomfattende fraværskontrollen til å konkludere at en opplysning
// ikke står noe sted. Bredere geometriske regler — «linjer som ligger oppå
// hverandre» — traff derfor også ekte tekst: Poppler legger cellene i en
// tabellrad som egne linjer i den samme blokken, og en bildetekst som strekker
// seg over spaltemargen havner i blokk med spaltelinjene rundt seg. Et
// vannmerkefragment på to tegn som slipper gjennom, står igjen som en egen
// blokk og kan ikke lage en falsk setning; et tapt avsnitt kan.
//
// Utelatelsen er dessuten avgrenset og rapportert: dekker den skjeve teksten mer
// enn en fjerdedel av ordene på en side, er siden ikke et vanlig oppsett med et
// vannmerke over, og dokumentet avvises framfor å bli en tekst der en fjerdedel
// mangler uten at noen ser det.
//
// ----------------------------------------------------------------------------
// Formen på resultatet, og hvorfor blokkskillet er hardt
//
//   ord i en linje   skilles med mellomrom
//   linjer i en blokk skilles med linjeskift          (mykt skille)
//   blokker           skilles med blank linje         (hardt skille)
//   sider             skilles med sideskift `\f`      (hardt skille)
//
// En blokk er Popplers egen avgjørelse om at teksten henger sammen — et avsnitt.
// Innenfor den er et linjeskift bare et linjeskift, og en setning som går over
// to linjer, skal fortsatt kunne siteres. Mellom to blokker er det motsatte
// tilfellet: to avsnitt, en overskrift og et avsnitt, en sidefot og en
// brødtekst. `extraction-checks.ts` behandler derfor den blanke linjen og
// sideskiftet som en grense et ordrett søk ikke kan krysse, slik at
// blanktegnnormaliseringen aldri igjen kan gjøre to uavhengige layoutblokker til
// én sammenhengende tekstsekvens.
//
// ----------------------------------------------------------------------------
// Popplers blokk er ikke alltid ett avsnitt
//
// Det myke skillet inne i en blokk hviler på at blokken *er* et avsnitt. For
// noen tabellrader er den ikke det: Poppler legger radetiketten og cellene i
// raden som egne linjer på samme grunnlinje i den samme blokken, og da skiller
// bare et linjeskift «17-Item HAM-D score,» fra tallet i nabocellen. Det er den
// samme feilen som spaltene, ett nivå lenger ned — og den ordrette kontrollen
// ville godtatt et sitat som gikk fra etiketten og inn i en fremmed celle.
//
// Derfor deles en blokk i cellene sine før rekkefølgen avgjøres, på det samme
// geometriske signalet: to linjer på den samme grunnlinjen, atskilt av et
// tomrom, er to celler, og hver av dem blir sin egen blokk med det harde
// skillet rundt seg. En blokk der ingen rad har mer enn én linje — all vanlig
// brødtekst — røres ikke, og teksten blir tegn for tegn den samme.
//
// Utrygg inndata: utdataene fra verktøyet er data, aldri instruksjoner
// (CLAUDE.md). De leses som koordinater og tekst, og ingenting annet.
// ============================================================================

/**
 * Navnet og versjonen på rekonstruksjonen, slik den registreres.
 *
 * Den er en del av oppskriften på lik linje med verktøyet og argumentene: uten
 * den kan ingen tredjepart komme fram til den samme teksten, og `content_hash`
 * ville vært et fingeravtrykk av noe bare Antidep kunne lage. Endres regelen
 * for rekkefølge, endres teksten — og da skal navnet få et nytt tall, ikke den
 * samme verdien et nytt innhold.
 */
export const READING_ORDER_TRANSFORM = 'antidep-reading-order@2'

// ----------------------------------------------------------------------------
// Terskler
//
// Alle er i punkter (1/72 tomme), som er enheten Poppler oppgir. De er få med
// vilje: hver terskel er et sted algoritmen kan ta feil, og en terskel som ikke
// kan begrunnes, er en gjetning med et tall foran seg.
// ----------------------------------------------------------------------------

/**
 * Hvor bred en loddrett tomromskorridor må være for å regnes som en spaltemarg.
 *
 * Spaltemargen i en vitenskapelig artikkel er typisk 15–30 punkter. Grensen er
 * satt lavere enn det, fordi den skal fange en smal marg — men ikke så lavt at
 * to blokker som tilfeldigvis ikke rører hverandre, blir to spalter.
 */
const MIN_COLUMN_GAP = 8

/**
 * Hvor mye to ord på samme linje minst må overlappe loddrett.
 *
 * Står to ord på den samme grunnlinjen, dekker de hverandre nesten helt. Står de
 * på en skrå linje, gjør de det ikke i det hele tatt. Halvparten skiller de to
 * tilfellene med god margin, og tåler samtidig at ett ord har en bokstav med
 * underlengde og nabo-ordet ikke.
 */
const MIN_WORD_BASELINE_OVERLAP = 0.5

/**
 * Hvor langt to blokker kan løpe ved siden av hverandre uten at de er spalter.
 *
 * Cellene i en tabellrad står også side om side. Forskjellen på en rad og to
 * spalter er ikke hva de inneholder — det kan ingen geometri avgjøre — men hvor
 * langt de løper sammen: en rad er høy som et par linjer, en spalte som en side.
 * Grensen er satt til to tommer, som er mer enn dobbelt så høyt som den høyeste
 * tabellraden i denne kodebasens egne artikler og en brøkdel av en spaltehøyde.
 *
 * Over grensen avvises dokumentet. Det er den dyre siden å ta feil på, og den
 * riktige: det er viktigere å avvise én vanskelig PDF enn å registrere kliniske
 * data lest i feil rekkefølge.
 */
const MAX_PARALLEL_RUN = 144

/**
 * Hvor stor del av ordene på en side som kan være skjev tekst før siden ikke er
 * et vanlig oppsett.
 *
 * Et vannmerke er noen få prosent. En fjerdedel er ikke et vannmerke lenger, og
 * da er ikke spørsmålet hvor mye som skal utelates, men om dokumentet i det hele
 * tatt er en tospaltet artikkel.
 */
const MAX_SKEWED_WORD_SHARE = 0.25

// ----------------------------------------------------------------------------
// Formen på posisjonsdataene
// ----------------------------------------------------------------------------

interface Rect {
  readonly xMin: number
  readonly yMin: number
  readonly xMax: number
  readonly yMax: number
}

interface PdfWord extends Rect {
  readonly text: string
}

interface PdfLine extends Rect {
  readonly words: readonly PdfWord[]
}

interface PdfBlock extends Rect {
  readonly lines: readonly PdfLine[]
  readonly wordCount: number
}

interface PdfPage {
  readonly blocks: readonly PdfBlock[]
}

/** Hva rekonstruksjonen gjorde, slik kalleren kan bedømme den. */
export interface ReadingOrderReport {
  readonly pageCount: number
  readonly blockCount: number
  readonly wordCount: number
  /** Ord i skjev tekst, holdt utenfor leserekkefølgen. */
  readonly skewedWordCount: number
}

export type ReadingOrderResult =
  | { readonly status: 'ok'; readonly text: string; readonly report: ReadingOrderReport }
  | { readonly status: 'rejected'; readonly message: string }

// ----------------------------------------------------------------------------
// Innlesningen
//
// Utdataene fra `-bbox-layout` er maskinskrevet XHTML med en fast form:
// `page > flow > block > line > word`, og hvert nivå har sine fire koordinater.
// Den leses med et enkelt gjennomløp framfor med en XML-parser: en parser ville
// vært en tredjepartsavhengighet i importgrafen til modell-leddet
// (`drafting-no-write-path.test.ts`), og formen her er verktøyets egen og
// forandrer seg ikke med dokumentet.
//
// `flow` hoppes bevisst over. Popplers egen gruppering er dens avgjørelse om
// rekkefølge, og rekkefølgen er nettopp det denne modulen skal avgjøre selv.
// ----------------------------------------------------------------------------

const PAGE_PATTERN = /<page\b[^>]*>([\s\S]*?)<\/page>/g
const BLOCK_PATTERN =
  /<block xMin="([-\d.eE+]+)" yMin="([-\d.eE+]+)" xMax="([-\d.eE+]+)" yMax="([-\d.eE+]+)">([\s\S]*?)<\/block>/g
const LINE_PATTERN =
  /<line xMin="([-\d.eE+]+)" yMin="([-\d.eE+]+)" xMax="([-\d.eE+]+)" yMax="([-\d.eE+]+)">([\s\S]*?)<\/line>/g
const WORD_PATTERN =
  /<word xMin="([-\d.eE+]+)" yMin="([-\d.eE+]+)" xMax="([-\d.eE+]+)" yMax="([-\d.eE+]+)">([\s\S]*?)<\/word>/g

const NAMED_ENTITIES: Readonly<Record<string, string>> = {
  amp: '&',
  lt: '<',
  gt: '>',
  quot: '"',
  apos: "'",
}

/**
 * Ett kodepunkt fra en numerisk entitet, eller `null` når det ikke finnes noe.
 *
 * Samme totalitet som i `extraction-checks.ts`: en ugyldig sekvens beholdes
 * ordrett framfor å bli til noe annet, fordi vi ikke vet hva den var ment å
 * være, og en gjetning ville endret teksten.
 */
function codePointFrom(digits: string, radix: number): string | null {
  const code = Number.parseInt(digits, radix)
  if (!Number.isInteger(code) || code < 0 || code > 0x10ffff) {
    return null
  }
  return String.fromCodePoint(code)
}

function decodeEntities(text: string): string {
  return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (match, body: string) => {
    if (body.startsWith('#x') || body.startsWith('#X')) {
      return codePointFrom(body.slice(2), 16) ?? match
    }
    if (body.startsWith('#')) {
      return codePointFrom(body.slice(1), 10) ?? match
    }
    return NAMED_ENTITIES[body] ?? match
  })
}

function rectOf(match: RegExpExecArray): Rect {
  return {
    xMin: Number(match[1]),
    yMin: Number(match[2]),
    xMax: Number(match[3]),
    yMax: Number(match[4]),
  }
}

function finiteRect(rect: Rect): boolean {
  return (
    Number.isFinite(rect.xMin) &&
    Number.isFinite(rect.yMin) &&
    Number.isFinite(rect.xMax) &&
    Number.isFinite(rect.yMax)
  )
}

function parsePages(xml: string): readonly PdfPage[] {
  const pages: PdfPage[] = []
  for (const pageMatch of xml.matchAll(PAGE_PATTERN)) {
    const blocks: PdfBlock[] = []
    for (const blockMatch of (pageMatch[1] ?? '').matchAll(BLOCK_PATTERN)) {
      const blockRect = rectOf(blockMatch)
      if (!finiteRect(blockRect)) {
        continue
      }
      const lines: PdfLine[] = []
      let wordCount = 0
      for (const lineMatch of (blockMatch[5] ?? '').matchAll(LINE_PATTERN)) {
        const lineRect = rectOf(lineMatch)
        if (!finiteRect(lineRect)) {
          continue
        }
        const words: PdfWord[] = []
        for (const wordMatch of (lineMatch[5] ?? '').matchAll(WORD_PATTERN)) {
          const wordRect = rectOf(wordMatch)
          const text = decodeEntities(wordMatch[5] ?? '')
          if (!finiteRect(wordRect) || text.length === 0) {
            continue
          }
          words.push({ ...wordRect, text })
        }
        if (words.length === 0) {
          continue
        }
        wordCount += words.length
        lines.push({ ...lineRect, words })
      }
      if (lines.length === 0) {
        continue
      }
      blocks.push({ ...blockRect, lines, wordCount })
    }
    pages.push({ blocks })
  }
  return pages
}

// ----------------------------------------------------------------------------
// Er blokken vanlig, vannrett tekst?
// ----------------------------------------------------------------------------

function verticalOverlapRatio(a: Rect, b: Rect): number {
  const shortest = Math.min(a.yMax - a.yMin, b.yMax - b.yMin)
  if (shortest <= 0) {
    return 0
  }
  return Math.max(0, Math.min(a.yMax, b.yMax) - Math.max(a.yMin, b.yMin)) / shortest
}

function isHorizontalBlock(block: PdfBlock): boolean {
  for (const line of block.lines) {
    for (let index = 1; index < line.words.length; index += 1) {
      const previous = line.words[index - 1]
      const current = line.words[index]
      if (previous === undefined || current === undefined) {
        continue
      }
      if (verticalOverlapRatio(previous, current) < MIN_WORD_BASELINE_OVERLAP) {
        return false
      }
    }
  }
  return true
}

// ----------------------------------------------------------------------------
// Snittene
// ----------------------------------------------------------------------------

interface Span {
  readonly min: number
  readonly max: number
}

/** Tomrommene mellom blokkenes utstrekninger langs én akse, bredeste først. */
function gapsBetween(spans: readonly Span[], minimumWidth: number): readonly Span[] {
  const sorted = [...spans].sort((a, b) => a.min - b.min)
  const gaps: Span[] = []
  let reach = Number.NEGATIVE_INFINITY
  for (const span of sorted) {
    if (reach > Number.NEGATIVE_INFINITY && span.min - reach >= minimumWidth) {
      gaps.push({ min: reach, max: span.min })
    }
    reach = Math.max(reach, span.max)
  }
  return gaps
}

function horizontalSpan(block: PdfBlock): Span {
  return { min: block.xMin, max: block.xMax }
}

function verticalSpan(block: PdfBlock): Span {
  return { min: block.yMin, max: block.yMax }
}

/** Én blokk av et sett linjer, med omrisset og ordtallet regnet ut på nytt. */
function blockOfLines(lines: readonly PdfLine[]): PdfBlock {
  return {
    xMin: lines.reduce((least, line) => Math.min(least, line.xMin), Number.POSITIVE_INFINITY),
    yMin: lines.reduce((least, line) => Math.min(least, line.yMin), Number.POSITIVE_INFINITY),
    xMax: lines.reduce((most, line) => Math.max(most, line.xMax), Number.NEGATIVE_INFINITY),
    yMax: lines.reduce((most, line) => Math.max(most, line.yMax), Number.NEGATIVE_INFINITY),
    lines,
    wordCount: lines.reduce((total, line) => total + line.words.length, 0),
  }
}

/**
 * Linjene i blokken gruppert i grunnlinjerader, øverste rad først.
 *
 * En rad er de linjene som står på den samme grunnlinjen som den første av dem.
 * Overlappet måles mot den første linjen i raden, ikke mot hvilken som helst av
 * dem: en kjede av små overlapp kunne ellers dratt en hel spalte inn i én rad.
 */
function baselineRows(lines: readonly PdfLine[]): readonly (readonly PdfLine[])[] {
  const sorted = [...lines].sort((a, b) => a.yMin - b.yMin || a.xMin - b.xMin)
  const rows: PdfLine[][] = []
  for (const line of sorted) {
    const current = rows.at(-1)
    const anchor = current?.[0]
    if (
      current === undefined ||
      anchor === undefined ||
      verticalOverlapRatio(anchor, line) < MIN_WORD_BASELINE_OVERLAP
    ) {
      rows.push([line])
      continue
    }
    current.push(line)
  }
  return rows
}

/** Raden delt i celler på tomrommene mellom linjene, fra venstre. */
function rowCells(row: readonly PdfLine[]): readonly (readonly PdfLine[])[] {
  const sorted = [...row].sort((a, b) => a.xMin - b.xMin)
  const cells: PdfLine[][] = []
  let reach = Number.NEGATIVE_INFINITY
  for (const line of sorted) {
    const current = cells.at(-1)
    if (current === undefined || line.xMin - reach >= MIN_COLUMN_GAP) {
      cells.push([line])
    } else {
      current.push(line)
    }
    reach = Math.max(reach, line.xMax)
  }
  return cells
}

/**
 * Blokken delt i cellene sine, eller blokken selv.
 *
 * Poppler legger noen tabellrader i én blokk: radetiketten og cellene i raden
 * blir egne `line`-elementer på samme grunnlinje inne i den samme blokken. Står
 * de igjen som linjer, skiller bare et linjeskift dem — og linjeskiftet er det
 * *myke* skillet, det et ordrett søk får krysse fordi en setning skal kunne gå
 * over to linjer (`extraction-checks.ts`). Da blir «17-Item HAM-D score,» og
 * tallet i nabocellen én sammenhengende tegnstrøm, og en klinisk verdi kan
 * siteres som om den hørte til etiketten ved siden av. Det er den samme feilen
 * modulen finnes for å hindre, bare ett nivå under spaltene: Popplers blokk er
 * ikke alltid ett avsnitt.
 *
 * Signalet er geometrisk, som resten av modulen: **to linjer på den samme
 * grunnlinjen, atskilt av et tomrom**. To linjer som ikke overlapper i høyden,
 * står over hverandre og er en vanlig stabling — et avsnitt skal ikke deles i
 * to fordi en kort sistelinje ikke rører linjen over. To linjer som rører
 * hverandre vannrett, er én synlig tekstlinje Poppler delte, og hører sammen.
 *
 * Radene med bare én linje blir derfor liggende igjen i sin egen blokk, mens
 * hver celle i en rad med flere blir en blokk med det harde skillet rundt seg.
 * En blokk der ingen rad har mer enn én linje — altså all vanlig brødtekst —
 * røres ikke, og teksten blir tegn for tegn den samme. Ingen tekst flyttes, og
 * intet ord endres: bare skillet mellom dem blir det det er.
 */
function splitIntoCells(block: PdfBlock): readonly PdfBlock[] {
  const rows = baselineRows(block.lines)
  const cellRows = rows.map(rowCells)
  if (cellRows.every((cells) => cells.length === 1)) {
    return [block]
  }

  const parts: PdfBlock[] = []
  let stacked: PdfLine[] = []
  for (const cells of cellRows) {
    const only = cells.length === 1 ? cells[0] : undefined
    if (only !== undefined) {
      stacked.push(...only)
      continue
    }
    if (stacked.length > 0) {
      parts.push(blockOfLines(stacked))
      stacked = []
    }
    for (const cell of cells) {
      parts.push(blockOfLines(cell))
    }
  }
  if (stacked.length > 0) {
    parts.push(blockOfLines(stacked))
  }
  return parts
}

/**
 * Blokkene i leserekkefølge, eller `null` når rekkefølgen ikke er bestemt.
 *
 * `null` betyr alltid det samme og bobler opp uendret: én del av én side uten
 * avgjort rekkefølge gjør hele dokumentet ikke trygt ekstraherbart.
 */
function orderRegion(blocks: readonly PdfBlock[]): readonly PdfBlock[] | null {
  if (blocks.length <= 1) {
    return blocks
  }

  // 1. Spaltesnittet, på den bredeste korridoren. Rekursjonen tar de øvrige.
  const corridors = gapsBetween(blocks.map(horizontalSpan), MIN_COLUMN_GAP)
  const widest = corridors.reduce<Span | null>(
    (best, gap) => (best === null || gap.max - gap.min > best.max - best.min ? gap : best),
    null,
  )
  if (widest !== null) {
    const left = orderRegion(blocks.filter((block) => block.xMax <= widest.min))
    const right = orderRegion(blocks.filter((block) => block.xMin >= widest.max))
    return left === null || right === null ? null : [...left, ...right]
  }

  // 2. De vannrette båndene. Et hvilket som helst tomrom tvers over delen er en
  //    entydig stabling: øverste bånd leses først.
  const bands = gapsBetween(blocks.map(verticalSpan), Number.MIN_VALUE)
  if (bands.length > 0) {
    const boundaries = [...bands.map((gap) => gap.min)].sort((a, b) => a - b)
    const ordered: PdfBlock[] = []
    let floor = Number.NEGATIVE_INFINITY
    for (const boundary of [...boundaries, Number.POSITIVE_INFINITY]) {
      const band = blocks.filter((block) => block.yMin > floor && block.yMin <= boundary)
      floor = boundary
      if (band.length === 0) {
        continue
      }
      const bandOrder = orderRegion(band)
      if (bandOrder === null) {
        return null
      }
      ordered.push(...bandOrder)
    }
    return ordered
  }

  // 3. Bladet. Her finnes verken en korridor eller et bånd, og blokkene leses
  //    ovenfra og ned — med ett unntak, som er hele grunnen til at modulen
  //    finnes: to blokker som er atskilt vannrett og løper ved siden av
  //    hverandre nedover siden, er to spalter som ingen korridor skilte. Da er
  //    rekkefølgen mellom dem ikke gitt av oppsettet, og dokumentet avvises.
  for (let i = 0; i < blocks.length; i += 1) {
    for (let j = i + 1; j < blocks.length; j += 1) {
      const a = blocks[i]
      const b = blocks[j]
      if (a === undefined || b === undefined) {
        continue
      }
      const sideBySide = a.xMax + MIN_COLUMN_GAP <= b.xMin || b.xMax + MIN_COLUMN_GAP <= a.xMin
      const run = Math.min(a.yMax, b.yMax) - Math.max(a.yMin, b.yMin)
      if (sideBySide && run > MAX_PARALLEL_RUN) {
        return null
      }
    }
  }
  return [...blocks].sort((a, b) => a.yMin - b.yMin || a.xMin - b.xMin)
}

// ----------------------------------------------------------------------------
// Teksten
// ----------------------------------------------------------------------------

function blockText(block: PdfBlock): string {
  return block.lines.map((line) => line.words.map((word) => word.text).join(' ')).join('\n')
}

/**
 * Den logiske leserekkefølgen av `pdftotext -bbox-layout`, eller en avvisning.
 *
 * Ren funksjon: samme inndata gir alltid den samme teksten, som er hele
 * grunnlaget for at `content_hash` kan etterprøves av noen andre.
 */
export function reconstructReadingOrder(bboxXml: string): ReadingOrderResult {
  if (!bboxXml.includes('<doc>')) {
    return {
      status: 'rejected',
      message:
        'Utdataene fra pdftotext har ikke formen -bbox-layout gir, og inneholder derfor ingen ' +
        'posisjonsdata å bygge en leserekkefølge av.',
    }
  }

  const pages = parsePages(bboxXml)
  if (pages.length === 0) {
    return {
      status: 'rejected',
      message: 'Dokumentet har ingen sider med posisjonsdata.',
    }
  }

  const pageTexts: string[] = []
  let blockCount = 0
  let wordCount = 0
  let skewedWordCount = 0

  for (const [index, page] of pages.entries()) {
    const pageNumber = index + 1
    const horizontal = page.blocks.filter(isHorizontalBlock)
    const skewed = page.blocks.filter((block) => !isHorizontalBlock(block))
    const pageWords = page.blocks.reduce((total, block) => total + block.wordCount, 0)
    const skewedWords = skewed.reduce((total, block) => total + block.wordCount, 0)

    if (pageWords > 0 && skewedWords / pageWords > MAX_SKEWED_WORD_SHARE) {
      return {
        status: 'rejected',
        message:
          `Side ${String(pageNumber)} har ${String(skewedWords)} av ${String(pageWords)} ord i ` +
          'tekst som ikke er lagt vannrett. Da er siden ikke et vanlig oppsett med et vannmerke ' +
          'over, og en leserekkefølge for den ville vært en gjetning.',
      }
    }

    const ordered = orderRegion(horizontal.flatMap(splitIntoCells))
    if (ordered === null) {
      return {
        status: 'rejected',
        message:
          `Leserekkefølgen på side ${String(pageNumber)} kan ikke bestemmes: siden har ` +
          'tekstblokker som står side om side uten en tomromskorridor mellom seg, og ' +
          'rekkefølgen mellom dem er ikke gitt av oppsettet. Dokumentet er ikke trygt ' +
          'ekstraherbart, og en plausibel rekkefølge ville vært en gjetning.',
      }
    }

    blockCount += ordered.length
    wordCount += pageWords - skewedWords
    skewedWordCount += skewedWords
    pageTexts.push(ordered.map(blockText).join('\n\n'))
  }

  if (wordCount === 0) {
    return {
      status: 'rejected',
      message:
        'Dokumentet ga ingen ord i en avgjort leserekkefølge. En innskannet PDF uten tekstlag ' +
        'kan ikke bære en ordrett kontroll.',
    }
  }

  return {
    status: 'ok',
    // Sideskiftet står etter hver side, slik pdftotext selv skriver det: et
    // kildeutdrag skal kunne stedfestes, og skilletegnet er det eneste i teksten
    // som sier hvor en side slutter.
    text: pageTexts.map((page) => `${page}\n\f`).join(''),
    report: { pageCount: pages.length, blockCount, wordCount, skewedWordCount },
  }
}
