import { describe, expect, it } from 'vitest'
import {
  compareNorwegian,
  formatDateAtPrecision,
  formatDurationSpan,
  formatIntervalText,
  formatNumber,
  formatTimestampAsDate,
  formatTimestampWithClock,
  wholeWeeksOf,
} from './norwegian-format'

// Formene under er ikke oppdiktede. De er lest ut av PostgreSQL 16 med
// standardinnstillingen IntervalStyle = postgres, som er den Supabase kjører,
// og to_json() gir nøyaktig samme streng som ::text.
describe('intervalltekst fra PostgreSQL', () => {
  it.each([
    // [databaseverdi, kilden den kom fra, forventet norsk tekst]
    ['56 days', "interval '8 weeks'", '56 dager'],
    ['7 days', "interval '1 week'", '7 dager'],
    ['1 day', "interval '1 day'", '1 dag'],
    ['3 mons', "interval '3 months'", '3 måneder'],
    ['1 mon', "interval '1 month'", '1 måned'],
    ['1 year', "interval '12 months'", '1 år'],
    ['1 year 6 mons', "interval '18 months'", '1 år 6 måneder'],
    ['1 year 2 mons 3 days', 'sammensatt intervall', '1 år 2 måneder 3 dager'],
    ['12:00:00', "interval '12 hours'", '12 timer'],
    ['1 mon 5 days 06:00:00', 'dato- og klokkeledd sammen', '1 måned 5 dager 6 timer'],
    ['00:30:00', "interval '30 minutes'", '30 minutter'],
    ['00:00:45', "interval '45 seconds'", '45 sekunder'],
    ['01:01:01', 'ett av hver, i entall', '1 time 1 minutt 1 sekund'],
  ])('%s (%s) blir «%s»', (raw, _source, expected) => {
    expect(formatIntervalText(raw)).toEqual({ kind: 'formatted', text: expected })
  })

  it('et nullintervall blir en varighet, ikke en tom streng', () => {
    // En tom streng ville sett ut som en manglende verdi, og et manglende felt
    // er nettopp det som ikke skal kunne forveksles med data (§17).
    expect(formatIntervalText('00:00:00')).toEqual({ kind: 'formatted', text: '0 sekunder' })
  })
})

describe('et intervall som ikke lar seg tolke, gjengis uendret', () => {
  it.each([
    ['P56D', 'ISO 8601 fra en annen IntervalStyle'],
    ['PT12H', 'ISO 8601, bare klokkeledd'],
    ['-1 days', 'negativt intervall, som migrasjon 004 forbyr på et tidsrom'],
    ['1 days -02:00:00', 'negativt klokkeledd'],
    ['56 fortnights', 'en enhet PostgreSQL ikke skriver ut'],
    ['56 days extra', 'et ledd for mye'],
    ['3 mons 5', 'et tall uten enhet'],
    ['', 'tom streng'],
    ['   ', 'bare blanktegn'],
    ['1,5 days', 'desimaltall der PostgreSQL skriver heltall'],
  ])('%s (%s)', (raw) => {
    expect(formatIntervalText(raw)).toEqual({ kind: 'unrecognised', text: raw })
  })

  it('gjengir råverdien uendret, ikke en normalisert utgave av den', () => {
    // Poenget med `unrecognised` er at leseren ser hva som faktisk står.
    expect(formatIntervalText('  P56D  ')).toEqual({ kind: 'unrecognised', text: '  P56D  ' })
  })
})

describe('tidsstempler', () => {
  it('gir norsk dato uten klokkeslett', () => {
    expect(formatTimestampAsDate('2026-08-21T09:15:00+00:00')).toEqual({
      kind: 'formatted',
      text: '21. august 2026',
    })
  })

  it('bruker norsk tid, ikke maskinens sone', () => {
    // 22:30 UTC er 00:30 neste døgn i Oslo om sommeren. Datoen en kliniker ser
    // skal være den samme uansett hvor leseren sitter, og testen skal ikke
    // avhenge av maskinen den kjører på.
    expect(formatTimestampAsDate('2026-08-21T22:30:00Z')).toEqual({
      kind: 'formatted',
      text: '22. august 2026',
    })
  })

  it('gjengir et utolkbart tidsstempel rått framfor «Invalid Date»', () => {
    expect(formatTimestampAsDate('ikke en dato')).toEqual({
      kind: 'unrecognised',
      text: 'ikke en dato',
    })
  })

  it('gir klokkeslett der tidspunktet er en del av identiteten', () => {
    // To hentinger av samme adresse samme dag er to forskjellige
    // øyeblikksbilder. Uten klokkeslettet ville de sett like ut for den som
    // skal velge mellom dem.
    expect(formatTimestampWithClock('2026-08-21T09:15:00+00:00')).toEqual({
      kind: 'formatted',
      text: '21. august 2026 kl. 11:15',
    })
  })

  it('bruker norsk tid også med klokkeslett', () => {
    expect(formatTimestampWithClock('2026-08-21T22:30:00Z')).toEqual({
      kind: 'formatted',
      text: '22. august 2026 kl. 00:30',
    })
  })

  it('gjengir et utolkbart tidsstempel rått også med klokkeslett', () => {
    expect(formatTimestampWithClock('ikke en dato')).toEqual({
      kind: 'unrecognised',
      text: 'ikke en dato',
    })
  })
})

describe('tall', () => {
  it('bruker norsk desimalkomma', () => {
    expect(formatNumber(1.7)).toEqual({ kind: 'formatted', text: '1,7' })
  })

  it('avkorter ikke desimaler', () => {
    // Standardverdien for maximumFractionDigits er 3. Uten overstyring ville
    // 1,7143 blitt 1,714 — en klinisk verdi endret av en formateringsdetalj.
    expect(formatNumber(1.7143)).toEqual({ kind: 'formatted', text: '1,7143' })
  })

  it('beholder et heltall som heltall', () => {
    expect(formatNumber(2)).toEqual({ kind: 'formatted', text: '2' })
  })

  it('beholder null som null', () => {
    // 0 er en målt verdi, ikke en manglende verdi, og skal ikke forsvinne.
    expect(formatNumber(0)).toEqual({ kind: 'formatted', text: '0' })
  })

  it('gjengir et negativt tall med minustegn', () => {
    expect(formatNumber(-0.4)).toEqual({ kind: 'formatted', text: '−0,4' })
  })

  it.each([Number.NaN, Number.POSITIVE_INFINITY])(
    '%s er et kontraktsbrudd og gjengis rått',
    (value) => {
      expect(formatNumber(value)).toEqual({ kind: 'unrecognised', text: String(value) })
    },
  )
})

describe('compareNorwegian', () => {
  it('setter æ, ø og å sist, og i norsk rekkefølge', () => {
    // En sortering på tegnverdi gir å (U+00E5) før æ (U+00E6) før ø (U+00F8).
    expect(['ø', 'å', 'æ', 'z'].sort(compareNorwegian)).toEqual(['z', 'æ', 'ø', 'å'])
  })

  it('sorterer «aa» som «å», slik norsk kollasjon gjør', () => {
    expect(['aal', 'bil'].sort(compareNorwegian)).toEqual(['bil', 'aal'])
  })

  it('er en ordinær alfabetisk sortering ellers', () => {
    expect(['sertralin', 'mirtazapin'].sort(compareNorwegian)).toEqual(['mirtazapin', 'sertralin'])
  })
})

describe('formatDateAtPrecision', () => {
  it('skriver bare året når bare året er kjent', () => {
    // Datoen lagres avkortet til presisjonsnivået (migrasjon 003). «1. januar
    // 2019» ville vært falsk presisjon (ANTIDEP_CONSTITUTION.md §6), og den er
    // ikke synlig som feil: den ser ut som en helt vanlig dato.
    expect(formatDateAtPrecision('2019-01-01', 'year')).toEqual({
      kind: 'formatted',
      text: '2019',
    })
  })

  it('skriver måned og år når dagen ikke er kjent', () => {
    expect(formatDateAtPrecision('2019-03-01', 'month')).toEqual({
      kind: 'formatted',
      text: 'mars 2019',
    })
  })

  it('skriver hele datoen når dagen er kjent', () => {
    expect(formatDateAtPrecision('2019-03-17', 'day')).toEqual({
      kind: 'formatted',
      text: '17. mars 2019',
    })
  })

  it('tolker datoen uten sone, så dagen ikke kan forskyves', () => {
    // En `Date` ville lagt en sone på en datotekst uten sone, og en omregning
    // kunne flyttet dagen over et døgnskille.
    expect(formatDateAtPrecision('2019-01-01', 'day')).toEqual({
      kind: 'formatted',
      text: '1. januar 2019',
    })
    expect(formatDateAtPrecision('2019-12-31', 'day')).toEqual({
      kind: 'formatted',
      text: '31. desember 2019',
    })
  })

  // Ytterpunktene, ikke bare midten: uten separatorer, med ensifrede ledd, med
  // feil separator, avkortet, med et tidsledd på slutten, tom. En løsere form
  // på mønsteret ville gjort «20190301» og «2019-3-1» til gyldige datoer, og et
  // uforankret mønster ville tatt imot et `timestamptz` og stilltiende kuttet
  // klokkeslettet — altså vist en dato som ikke er den kolonnen bærer.
  it.each([
    '2019-03',
    '19-03-01',
    '2019/03/01',
    '20190301',
    '2019-3-1',
    '2019-03-01T00:00:00Z',
    '',
    'i fjor',
  ])('«%s» er ikke en dato, og gjengis rått', (raw) => {
    expect(formatDateAtPrecision(raw, 'day')).toEqual({ kind: 'unrecognised', text: raw })
  })

  it.each(['2019-13-01', '2019-00-01', '2019-03-00', '2019-03-32'])(
    '«%s» har et ledd utenfor kalenderen, og gjengis rått',
    (raw) => {
      // En dato som ikke lar seg tolke skal ikke se ut som en tolket dato.
      expect(formatDateAtPrecision(raw, 'day')).toEqual({ kind: 'unrecognised', text: raw })
    },
  )
})

// ----------------------------------------------------------------------------
// Varigheten et funn gjelder
//
// Databasen normaliserer uker til dager, men kildene oppgir uker. En kontrollør
// som bare får «182 til 224 dager», må kontrollregne for å se om Antidep
// gjengir kilden riktig — og det er nettopp den jobben flaten skal ta. Begge
// tallene står, så den kanoniske varigheten er ikke byttet ut.
// ----------------------------------------------------------------------------

describe('wholeWeeksOf', () => {
  it.each([
    ['56 days', 8],
    ['182 days', 26],
    ['224 days', 32],
    ['7 days', 1],
  ])('«%s» er %i hele uker', (raw, weeks) => {
    expect(wholeWeeksOf(raw)).toBe(weeks)
  })

  // Måneder og år er ikke faste antall dager, og en omregning ville vært en
  // påstand framfor en identitet. Et intervall som ikke går opp i hele uker,
  // regnes heller ikke om.
  it.each(['10 days', '3 mons', '1 year 6 mons', '12:00:00', '0 days', 'P56D', ''])(
    '«%s» regnes ikke om til uker',
    (raw) => {
      expect(wholeWeeksOf(raw)).toBeNull()
    },
  )
})

describe('formatDurationSpan', () => {
  it('viser uker som hovedform, med dagene som eksplisitt omregning', () => {
    expect(formatDurationSpan('56 days', '56 days')).toBe('8 uker (registrert som 56 dager)')
  })

  // Spennet Fava 2000 faktisk oppgir: «26 to 32 weeks».
  it('viser et spenn i uker, med dagene ved siden av', () => {
    expect(formatDurationSpan('182 days', '224 days')).toBe(
      '26 til 32 uker (registrert som 182 til 224 dager)',
    )
  })

  it('bøyer entallsformen', () => {
    expect(formatDurationSpan('7 days', '7 days')).toBe('1 uke (registrert som 7 dager)')
  })

  // Blandede enheter ville krevd at leseren selv fant ut om grensene var
  // sammenlignbare. Da gjengis databaseverdien som før.
  it('regner ikke om når bare den ene grensen er hele uker', () => {
    expect(formatDurationSpan('56 days', '60 days')).toBe('56 dager til 60 dager')
  })

  it('gjengir en varighet som ikke er hele uker i dager', () => {
    expect(formatDurationSpan('10 days', '10 days')).toBe('10 dager')
  })

  it('merker en varighet som ikke lot seg tolke, framfor å utelate den', () => {
    expect(formatDurationSpan('P56D', 'P56D')).toBe('P56D (ikke tolkbar som varighet)')
  })

  it('er fravær bare når ingen av grensene er registrert', () => {
    expect(formatDurationSpan(null, null)).toBeNull()
    expect(formatDurationSpan(null, '56 days')).toBe('8 uker (registrert som 56 dager)')
    expect(formatDurationSpan('56 days', null)).toBe('8 uker (registrert som 56 dager)')
  })
})
