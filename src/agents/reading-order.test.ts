// ============================================================================
// Leserekkefølgen, prøvd på en tospaltet artikkel
//
// Feilen disse prøvene finnes for, sto i produksjon: kildeutdragene i
// `/extraction-review` var hentet ut med `pdftotext -layout`, som gjenskaper den
// fysiske plasseringen på papiret. I en tospaltet artikkel havner venstre og
// høyre spalte da ved siden av hverandre på den samme tekstlinjen — og Antideps
// ordrette kontroll normaliserer blanktegn før den søker. To uavhengige spalter
// ble dermed én sammenhengende tegnstrøm, og en klinisk opplysning kunne bli
// tilskrevet feil behandlingsarm, feil studie eller feil endepunkt (issue #84).
//
// ----------------------------------------------------------------------------
// Hvorfor fiksturen er syntetisk
//
// En ekte tospaltet artikkel er opphavsrettslig beskyttet og kan ikke commites
// (EVIDENCE_PIPELINE.md §14, documents/README.md). Fiksturene bygges derfor som
// gyldige PDF-er i testen, med setninger som gjør feil rekkefølge umulig å
// overse: hver linje sier selv hvilken spalte den står i.
//
// Prøvene kjører **det ekte verktøyet**. Det er poenget: regelen gjelder
// Popplers faktiske utdata, ikke en etterlikning av det, og en prøve mot en
// håndskrevet XML-fil kunne vært grønn mens kjeden var rød. `pdftotext` er
// derfor en forutsetning for testpakken, og CI installerer den.
// ============================================================================

import { describe, expect, it } from 'vitest'

import { sourceVersionContentHash } from './content-hash.ts'
import { verbatimOccursIn, searchProjections } from './extraction-checks.ts'
import {
  extractDocumentText,
  PDF_TEXT_ARGUMENTS,
  PDF_TEXT_TOOL,
  PDF_TEXT_TRANSFORM,
  recipeArguments,
  runToolWithNode,
  type TextExtractionRecipe,
} from './document-text.ts'
import { reconstructReadingOrder } from './reading-order.ts'
import { bboxLayoutDocument, syntheticLayoutPdf, type SyntheticTextBlock } from './test-support.ts'

/** Oppskriften Antidep registrerer nye kildeversjoner med. */
const OPPSKRIFT: TextExtractionRecipe = {
  tool: PDF_TEXT_TOOL,
  toolVersion: 'pdftotext (prøvd mot den installerte)',
  arguments: PDF_TEXT_ARGUMENTS,
  transform: PDF_TEXT_TRANSFORM,
}

/** Den forrige oppskriften, beholdt i listen for de historiske radene. */
const GAMMEL_OPPSKRIFT: TextExtractionRecipe = {
  ...OPPSKRIFT,
  arguments: '-layout -enc UTF-8 -eol unix',
  transform: null,
}

async function tekstMed(
  recipe: TextExtractionRecipe,
  blokker: readonly SyntheticTextBlock[],
): Promise<string> {
  const resultat = await extractDocumentText({
    bytes: syntheticLayoutPdf(blokker),
    recipe,
    run: runToolWithNode,
  })
  if (resultat.status !== 'ok') {
    throw new Error(`Tekstuttrekkingen mislyktes: ${resultat.message}`)
  }
  return resultat.extracted.text
}

/** Posisjonsdataene fra verktøyet, slik rekonstruksjonen får dem. */
async function posisjonsdata(blokker: readonly SyntheticTextBlock[]): Promise<string> {
  const kjøring = await runToolWithNode(
    PDF_TEXT_TOOL,
    [...recipeArguments(OPPSKRIFT), '-', '-'],
    syntheticLayoutPdf(blokker),
  )
  if (kjøring.status !== 'ran' || kjøring.exitCode !== 0) {
    throw new Error('pdftotext svarte ikke. Er poppler installert?')
  }
  return kjøring.stdout
}

// ----------------------------------------------------------------------------
// Fiksturene
// ----------------------------------------------------------------------------

const VENSTRE = [
  'The left column begins here.',
  'It continues with a second line.',
  'Sertraline increased weight by 1.5 kg.',
  'The left column ends here.',
] as const

const HØYRE = [
  'The right column begins here.',
  'It continues with its own line.',
  'Fluoxetine decreased weight by 0.4 kg.',
  'The right column ends here.',
] as const

/**
 * En tospaltet artikkelside: tittel over full bredde, to spalter under, en
 * gjennomgående overskrift i midten, og to spalter igjen.
 *
 * Spaltemargen er 54 punkter, som i en tidsskriftside. Tittelen og overskriften
 * krysser den, og er dermed nøyaktig det tilfellet algoritmen skal håndtere med
 * den samme regelen som spaltene.
 */
const TOSPALTET: readonly SyntheticTextBlock[] = [
  { x: 120, y: 60, lines: ['Weight change with two columns'], fontSize: 16 },
  { x: 56, y: 120, lines: [...VENSTRE] },
  { x: 330, y: 120, lines: [...HØYRE] },
  { x: 150, y: 230, lines: ['DISCUSSION AND CONCLUSION'], fontSize: 13 },
  { x: 56, y: 270, lines: ['The left column resumes below.', 'Left again.'] },
  { x: 330, y: 270, lines: ['The right column resumes below.', 'Right again.'] },
]

/**
 * Den samme siden med et vannmerke på tvers, som i en reell tidsskrift-PDF.
 *
 * Vannmerket ligger midt i spaltemargen og krysser den. Det er derfor ikke et
 * pyntetilfelle: uten at skjev tekst holdes utenfor, ville det gjort
 * spalteinndelingen ubestemmelig og tatt hele siden med seg.
 */
const MED_VANNMERKE: readonly SyntheticTextBlock[] = [
  { x: 56, y: 80, lines: Array.from({ length: 12 }, (_, i) => `Left column line ${i + 1}.`) },
  { x: 330, y: 80, lines: Array.from({ length: 12 }, (_, i) => `Right column line ${i + 1}.`) },
  {
    x: 120,
    y: 300,
    lines: ['Copyright 2001 Physicians Postgraduate Press', 'One personal copy may be printed'],
    fontSize: 20,
    rotate: -45,
  },
]

/**
 * En side der rekkefølgen ikke er gitt av oppsettet.
 *
 * To høye spalter side om side, og en bildetekst som strekker seg fra inne i
 * den venstre spalten til inne i den høyre. Bildeteksten lukker spaltemargen, så
 * ingen tomromskorridor skiller spaltene — og de løper ved siden av hverandre
 * nedover hele siden. Hvilken av dem som leses først, er ikke bestemt.
 */
const TVETYDIG: readonly SyntheticTextBlock[] = [
  { x: 56, y: 80, lines: Array.from({ length: 12 }, (_, i) => `Left column text line ${i + 1}.`) },
  {
    x: 330,
    y: 80,
    lines: Array.from({ length: 12 }, (_, i) => `Right column text line ${i + 1}.`),
  },
  { x: 90, y: 148, lines: ['Figure 1. Caption reaching over the gutter'], fontSize: 18 },
]

describe('dagens problem: den fysiske plasseringen blir én tegnstrøm', () => {
  it('legger tekst fra to spalter på samme tekstlinje', async () => {
    const gammel = await tekstMed(GAMMEL_OPPSKRIFT, TOSPALTET)
    // Én tekstlinje bærer slutten av venstre spalte og starten av høyre.
    expect(gammel).toMatch(/The left column begins here\. +The right column begins here\./)
  })

  it('lar et «ordrett» sitat bestå av ord fra to uavhengige spalter', async () => {
    const gammel = await tekstMed(GAMMEL_OPPSKRIFT, TOSPALTET)
    // Blanktegnnormaliseringen i den ordrette kontrollen slår kolonneavstanden
    // sammen til ett mellomrom. Sitatet under står ikke i artikkelen: de fire
    // første ordene er venstre spalte, de fem siste er høyre.
    const falsktSitat = 'left column ends here. The right column ends here.'
    expect(verbatimOccursIn(searchProjections(gammel), falsktSitat)).toBe(true)
  })
})

describe('den nye representasjonen', () => {
  it('gir hele venstre spalte i riktig intern rekkefølge før høyre spalte', async () => {
    const tekst = await tekstMed(OPPSKRIFT, TOSPALTET)
    const posisjon = (linje: string) => {
      const funnet = tekst.indexOf(linje)
      expect(funnet, `linjen «${linje}» mangler i representasjonen`).toBeGreaterThanOrEqual(0)
      return funnet
    }
    const venstre = VENSTRE.map(posisjon)
    const høyre = HØYRE.map(posisjon)

    // Innen spalten: topp til bunn.
    expect(venstre).toEqual([...venstre].sort((a, b) => a - b))
    expect(høyre).toEqual([...høyre].sort((a, b) => a - b))
    // Og deretter neste spalte: hele venstre spalte kommer før høyre begynner.
    expect(Math.max(...venstre)).toBeLessThan(Math.min(...høyre))
  })

  it('lager ingen setning av fragmenter fra begge spalter', async () => {
    const tekst = await tekstMed(OPPSKRIFT, TOSPALTET)
    const projeksjoner = searchProjections(tekst)
    const falsktSitat = 'left column ends here. The right column ends here.'
    expect(verbatimOccursIn(projeksjoner, falsktSitat)).toBe(false)

    // Ingen setning i representasjonen nevner begge spaltene. Setningene deles
    // på punktum, som er nøyaktig den grensen den ordrette kontrollen bruker.
    const setninger = tekst.split(/(?<!\d)\.(?!\d)/)
    for (const setning of setninger) {
      const begge = /\bleft\b/i.test(setning) && /\bright\b/i.test(setning)
      expect(begge, `setningen «${setning.trim()}» blander spaltene`).toBe(false)
    }
  })

  it('holder tekst over full sidebredde utenfor spaltene', async () => {
    const tekst = await tekstMed(OPPSKRIFT, TOSPALTET)
    const rekkefølge = [
      'Weight change with two columns',
      'The left column begins here.',
      'The right column begins here.',
      'DISCUSSION AND CONCLUSION',
      'The left column resumes below.',
      'The right column resumes below.',
    ].map((linje) => tekst.indexOf(linje))
    expect(rekkefølge.every((index) => index >= 0)).toBe(true)
    expect(rekkefølge).toEqual([...rekkefølge].sort((a, b) => a - b))
  })

  it('skiller hver tekstblokk med en blank linje, som den ordrette kontrollen ikke krysser', async () => {
    const tekst = await tekstMed(OPPSKRIFT, TOSPALTET)
    expect(tekst).toContain('The left column ends here.\n\nThe right column begins here.')
    // Innen en blokk er linjeskiftet mykt: en setning over to linjer i en spalte
    // skal fortsatt kunne siteres ordrett.
    expect(
      verbatimOccursIn(
        searchProjections(tekst),
        'The left column begins here. It continues with a second line.',
      ),
    ).toBe(true)
  })
})

describe('tekst som ikke er lagt vannrett', () => {
  it('holdes utenfor leserekkefølgen, og lar spaltene bli lest riktig likevel', async () => {
    const posisjoner = await posisjonsdata(MED_VANNMERKE)
    const resultat = reconstructReadingOrder(posisjoner)
    expect(resultat.status).toBe('ok')
    if (resultat.status !== 'ok') {
      return
    }
    // Vannmerket krysser spaltemargen. Ble det tatt med, ville ingen korridor
    // skilt spaltene, og siden ville blitt avvist.
    expect(resultat.report.skewedWordCount).toBeGreaterThan(0)
    expect(resultat.text).not.toContain('One personal copy may be printed')
    expect(resultat.text.indexOf('Left column line 12.')).toBeLessThan(
      resultat.text.indexOf('Right column line 1.'),
    )
  })

  it('avviser siden når den skjeve teksten er siden, ikke et vannmerke på den', async () => {
    const posisjoner = await posisjonsdata([
      {
        x: 90,
        y: 200,
        lines: Array.from({ length: 8 }, (_, i) => `Rotated line ${i + 1} of the page.`),
        fontSize: 14,
        rotate: -45,
      },
      { x: 56, y: 60, lines: ['One horizontal line.'] },
    ])
    const resultat = reconstructReadingOrder(posisjoner)
    expect(resultat.status).toBe('rejected')
    expect(resultat.status === 'rejected' ? resultat.message : '').toContain(
      'ikke er lagt vannrett',
    )
  })
})

describe('tvetydig oppsett', () => {
  it('avvises framfor å gi en plausibel rekkefølge', async () => {
    const posisjoner = await posisjonsdata(TVETYDIG)
    const resultat = reconstructReadingOrder(posisjoner)
    expect(resultat.status).toBe('rejected')
    expect(resultat.status === 'rejected' ? resultat.message : '').toContain('kan ikke bestemmes')
  })

  it('stopper ekstraksjonen, framfor å gi en tekst ingen kan stole på', async () => {
    const resultat = await extractDocumentText({
      bytes: syntheticLayoutPdf(TVETYDIG),
      recipe: OPPSKRIFT,
      run: runToolWithNode,
    })
    expect(resultat.status).toBe('error')
    const melding = resultat.status === 'error' ? resultat.message : ''
    expect(melding).toContain('ikke trygt ekstraherbart')
    expect(melding).toContain('Ekstraksjonen stopper her')
  })
})

describe('reproduserbarheten', () => {
  it('gir identisk tekst og identisk content_hash av samme dokument og samme oppskrift', async () => {
    const bytes = syntheticLayoutPdf(TOSPALTET)
    const første = await extractDocumentText({ bytes, recipe: OPPSKRIFT, run: runToolWithNode })
    const andre = await extractDocumentText({ bytes, recipe: OPPSKRIFT, run: runToolWithNode })
    expect(første.status).toBe('ok')
    expect(andre.status).toBe('ok')
    if (første.status !== 'ok' || andre.status !== 'ok') {
      return
    }
    expect(andre.extracted.text).toBe(første.extracted.text)
    expect(andre.extracted.contentHash).toBe(første.extracted.contentHash)
    // Fingeravtrykket er av teksten oppskriften ga, og kan derfor etterprøves av
    // en tredjepart med sha256 av den samme teksten.
    expect(første.extracted.contentHash).toBe(await sourceVersionContentHash(første.extracted.text))
  })

  it('gir en annen tekst enn den gamle oppskriften — og det er hele endringen', async () => {
    const bytes = syntheticLayoutPdf(TOSPALTET)
    const ny = await extractDocumentText({ bytes, recipe: OPPSKRIFT, run: runToolWithNode })
    const gammel = await extractDocumentText({
      bytes,
      recipe: GAMMEL_OPPSKRIFT,
      run: runToolWithNode,
    })
    expect(ny.status).toBe('ok')
    expect(gammel.status).toBe('ok')
    if (ny.status !== 'ok' || gammel.status !== 'ok') {
      return
    }
    // To forskjellige tekster av det samme dokumentet er nøyaktig grunnen til at
    // oppskriften er en del av proveniensen: en kildeversjon registrert med den
    // ene kan ikke etterprøves med den andre.
    expect(ny.extracted.contentHash).not.toBe(gammel.extracted.contentHash)
  })
})

describe('rekonstruksjonen av noe som ikke er posisjonsdata', () => {
  it('avvises, framfor å bli en tom tekst', () => {
    const resultat = reconstructReadingOrder('Bare vanlig tekst, ingen koordinater.\n')
    expect(resultat.status).toBe('rejected')
    expect(resultat.status === 'rejected' ? resultat.message : '').toContain('-bbox-layout')
  })
})

describe('en tabellrad Poppler har lagt i én blokk', () => {
  // Formen er hentet fra en ekte artikkel: Poppler la radetiketten og de tre
  // verdicellene som fire `line`-elementer på den samme grunnlinjen inne i én
  // blokk, mens de øvrige radene ble egne blokker per spalte. Ordene her er
  // oppdiktede — det er geometrien som er lånt, ikke teksten.
  //
  // Prøvene går rett på rekonstruksjonen framfor gjennom en PDF, fordi Popplers
  // egen blokkgruppering ikke lar seg styre: en syntetisk tabell blir én blokk
  // per celle, og da er ikke fiksturen den formen feilen oppstår i. At formen
  // *er* verktøyets, er prøvd av resten av filen, som kjører det ekte verktøyet.
  const MED_RAD = bboxLayoutDocument([
    ['Symptom score at baseline,', ['Row label continues here,', '19.4', '20.6', '20.0'], 'mean'],
  ])

  it('gir hver celle sin egen blokk, slik at etikett og verdi ikke blir én tegnstrøm', () => {
    const resultat = reconstructReadingOrder(MED_RAD)
    expect(resultat.status).toBe('ok')
    if (resultat.status !== 'ok') {
      return
    }
    // Det avgjørende: sitatet som krysser fra etiketten og inn i nabocellen,
    // finnes ikke i representasjonen. Med et linjeskift mellom dem ville den
    // ordrette kontrollen godtatt det, fordi et linjeskift er det myke skillet.
    expect(
      verbatimOccursIn(searchProjections(resultat.text), 'Row label continues here, 19.4'),
    ).toBe(false)
    expect(verbatimOccursIn(searchProjections(resultat.text), '19.4 20.6')).toBe(false)
    // Og cellene står der, hver for seg og i rekkefølge fra venstre.
    for (const celle of ['Row label continues here,', '19.4', '20.6', '20.0']) {
      expect(verbatimOccursIn(searchProjections(resultat.text), celle)).toBe(true)
    }
    expect(resultat.text.indexOf('19.4')).toBeLessThan(resultat.text.indexOf('20.6'))
    expect(resultat.text.indexOf('20.6')).toBeLessThan(resultat.text.indexOf('20.0'))
    expect(resultat.report.wordCount).toBe(12)
  })

  it('lar de gjennomgående linjene i den samme blokken bli stående som avsnitt', () => {
    const resultat = reconstructReadingOrder(MED_RAD)
    expect(resultat.status === 'ok' ? resultat.text : '').toContain('Symptom score at baseline,')
    // Linjen over raden og linjen under den er to stablinger, ikke celler, og
    // deles derfor ikke opp videre.
    expect(
      verbatimOccursIn(
        searchProjections(resultat.status === 'ok' ? resultat.text : ''),
        'Symptom score at baseline,',
      ),
    ).toBe(true)
  })

  it('rører ikke en blokk der ingen rad har mer enn én linje', () => {
    // Vanlig brødtekst skal komme ut tegn for tegn som før: en setning over to
    // linjer i det samme avsnittet skal fortsatt kunne siteres.
    const brødtekst = bboxLayoutDocument([
      ['Patients with major depressive disorder', 'were randomly assigned to treatment.'],
    ])
    const resultat = reconstructReadingOrder(brødtekst)
    expect(resultat.status).toBe('ok')
    if (resultat.status !== 'ok') {
      return
    }
    expect(resultat.report.blockCount).toBe(1)
    expect(
      verbatimOccursIn(
        searchProjections(resultat.text),
        'major depressive disorder were randomly assigned to treatment.',
      ),
    ).toBe(true)
  })
})

describe('et hevet tegn inne i brødtekst', () => {
  // Posisjonsdata skrevet ut for hånd, fordi prøven handler om én koordinat:
  // hvor høyt et enkelt ord står i forhold til nabo-ordene sine. Verken
  // `syntheticLayoutPdf` eller `bboxLayoutDocument` gir den kontrollen, og et
  // hevet tegn er nettopp det som skal prøves.
  interface FiksturOrd {
    readonly text: string
    readonly yMin: number
  }
  type FiksturLinje = readonly FiksturOrd[]
  type FiksturBlokk = readonly FiksturLinje[]

  const bbox = (blocks: readonly FiksturBlokk[]): string => {
    const rows = [
      '<!DOCTYPE html>',
      '<html xmlns="http://www.w3.org/1999/xhtml">',
      '<head><title>fikstur</title></head>',
      '<body>',
      '<doc>',
      '  <page width="612.000000" height="792.000000">',
    ]
    let top = 142
    for (const lines of blocks) {
      const blockTop = top
      rows.push('    <flow>')
      const at = rows.length
      rows.push('')
      for (const words of lines) {
        let x = 56
        rows.push(
          `        <line xMin="56.000000" yMin="${top.toFixed(6)}" ` +
            `xMax="520.000000" yMax="${(top + 8.2).toFixed(6)}">`,
        )
        for (const word of words) {
          const width = Math.max(4, word.text.length * 5)
          // Et hevet tegn har sin egen, mindre avgrensning: 5,4 punkter mot 8,2
          // for brødteksten, og `yMin` oppgir hvor høyt det står.
          const height = word.yMin === 0 ? 8.2 : 5.4
          const wordTop = top + word.yMin
          rows.push(
            `          <word xMin="${x.toFixed(6)}" yMin="${wordTop.toFixed(6)}" ` +
              `xMax="${(x + width).toFixed(6)}" yMax="${(wordTop + height).toFixed(6)}">` +
              `${word.text}</word>`,
          )
          x += width + 3
        }
        rows.push('        </line>')
        top += 12
      }
      rows[at] =
        `      <block xMin="56.000000" yMin="${blockTop.toFixed(6)}" ` +
        `xMax="520.000000" yMax="${top.toFixed(6)}">`
      rows.push('      </block>', '    </flow>')
      top += 12
    }
    rows.push('  </page>', '</doc>', '</body>', '</html>', '')
    return rows.join('\n')
  }

  /** Et ord på linjens egen grunnlinje. */
  const body = (text: string): FiksturOrd => ({ text, yMin: 0 })
  /** Hevet så høyt at avgrensningen bommer helt på nabo-ordenes. */
  const raised = (text: string): FiksturOrd => ({ text, yMin: -12 })

  it('tar ikke hele avsnittet med seg', () => {
    // Ett hevet sitatmerke blant tolv ord. Med en regel der ett ordpar avgjør,
    // ville hele avsnittet blitt utelatt av representasjonen — og en setning som
    // forsvinner, kan få den kildeomfattende fraværskontrollen til å konkludere
    // at en opplysning ikke står noe sted.
    const resultat = reconstructReadingOrder(
      bbox([
        [
          [
            ...['Mean', 'weight', 'increase', 'was'].map(body),
            raised('12'),
            ...['greater', 'with', 'paroxetine', 'than', 'with', 'the', 'others.'].map(body),
          ],
        ],
      ]),
    )
    expect(resultat.status).toBe('ok')
    if (resultat.status !== 'ok') {
      return
    }
    expect(resultat.report.skewedWordCount).toBe(0)
    expect(resultat.report.wordCount).toBe(12)
    expect(verbatimOccursIn(searchProjections(resultat.text), 'Mean weight increase was')).toBe(
      true,
    )
    expect(verbatimOccursIn(searchProjections(resultat.text), 'greater with paroxetine than')).toBe(
      true,
    )
  })

  it('holder fortsatt en blokk der hvert ord ligger på sin egen høyde, utenfor', () => {
    // En skrå linje: hvert ord et hakk lenger ned, så hvert ordpar svikter. Det
    // er formen et vannmerke har, og den skal fortsatt holdes utenfor. Den står
    // som sin egen blokk ved siden av et vanlig avsnitt, slik at siden ikke
    // avvises på at mer enn en fjerdedel av ordene er skjeve.
    const resultat = reconstructReadingOrder(
      bbox([
        [
          [
            'Patients',
            'were',
            'randomly',
            'assigned',
            'to',
            'double-blind',
            'treatment',
            'for',
            'six',
            'months',
            'in',
            'total.',
          ].map(body),
        ],
        [
          [
            { text: 'One', yMin: -12 },
            { text: 'personal', yMin: 0 },
            { text: 'copy', yMin: 12 },
            { text: 'only', yMin: 24 },
          ],
        ],
      ]),
    )
    expect(resultat.status).toBe('ok')
    if (resultat.status !== 'ok') {
      return
    }
    // Den skjeve blokken holdes utenfor, og det er rapportert. Avsnittet står.
    expect(resultat.report.skewedWordCount).toBe(4)
    expect(resultat.report.wordCount).toBe(12)
    expect(verbatimOccursIn(searchProjections(resultat.text), 'One personal copy only')).toBe(false)
  })
})
