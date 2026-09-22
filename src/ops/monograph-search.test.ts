import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

import {
  buildQueries,
  buildQuery,
  CROSSREF,
  EUROPE_PMC,
  EXECUTABLE_TRACK_CODES,
  PAGE_SIZE,
  PUBMED,
  runSearch,
  SEARCH_PLATFORMS,
  type Fetcher,
} from './monograph-search.ts'

/**
 * Et kontrollert opptak.
 *
 * Ordinær CI søker ikke på nettet: en prøve som gjorde det, ville feilet når en
 * tjeneste var nede, og et grønt resultat ville sagt mer om oppetiden enn om
 * koden. Opptakene er ekte svarformer fra de tre tjenestene, med syntetiske
 * treff — og at de *er* et opptak, står her framfor å bli omtalt som en
 * utført søkerunde (SOURCE_POLICY.md §4.3).
 */
function recorded(file: string, httpStatus = 200): Fetcher {
  return async (url) => ({
    status: 'ok',
    httpStatus,
    contentType: 'application/json',
    bytes: new TextEncoder().encode(readFileSync(`src/ops/fixtures/${file}`, 'utf8')),
    finalUrl: url,
  })
}

const SCOPE = { drug: 'sertralin', indication: 'depressiv lidelse', outcome: 'vektendring' }
const QUERY = buildQuery(SCOPE)

describe('søkestrengen', () => {
  it('har alltid virkestoffet, og de øvrige aksene som ELLER-ledd', () => {
    expect(buildQuery(SCOPE)).toBe('"sertralin" AND ("depressiv lidelse" OR "vektendring")')
  })

  it('er virkestoffet alene når avgrensningen ikke har noen annen akse', () => {
    expect(buildQuery({ drug: 'sertralin' })).toBe('"sertralin"')
  })

  it('tar med de termene en søkeforespørsel ba om', () => {
    expect(buildQuery({ drug: 'sertralin' }, ['sertraline', 'weight gain'])).toBe(
      '"sertralin" AND ("sertraline" OR "weight gain")',
    )
  })
})

// ----------------------------------------------------------------------------
// De to strategiene
//
// Skillet er ikke kosmetisk: dekningskontrollens motsøk kjører alltid
// `targeted`, og et motsøk som gjentok generatorens egen brede streng, ville
// ikke lett etter det generatoren overså (SOURCE_POLICY.md §6).
// ----------------------------------------------------------------------------
describe('søkestrategiene', () => {
  it('gir én bred streng med aksene som ELLER-ledd', () => {
    expect(buildQueries(SCOPE, 'broad')).toEqual([
      '"sertralin" AND ("depressiv lidelse" OR "vektendring")',
    ])
  })

  it('gir én målrettet passering per akse, og ikke generatorens egen streng', () => {
    const targeted = buildQueries(SCOPE, 'targeted')
    expect(targeted).toEqual([
      '"sertralin" AND "depressiv lidelse"',
      '"sertralin" AND "vektendring"',
    ])
    expect(targeted).not.toContain(buildQuery(SCOPE))
  })

  it('tar med de termene forespørselen ba om, og gjentar ingen streng', () => {
    expect(buildQueries({ drug: 'sertralin' }, 'targeted', ['vektendring', 'vektendring'])).toEqual(
      ['"sertralin" AND "vektendring"'],
    )
  })

  it('faller tilbake til virkestoffet alene når ingen akse finnes', () => {
    expect(buildQueries({ drug: 'sertralin' }, 'targeted')).toEqual(['"sertralin"'])
  })
})

// ----------------------------------------------------------------------------
// Synonymer er alternativer, ikke krav i tillegg
//
// Et virkestoffnavn på et annet språk lagt til som en term ville gitt
// «"sertralin" AND "sertraline"» — og da kan ikke en artikkel som bare bruker
// det engelske navnet, treffe i det hele tatt. Nettopp den artikkelen var
// søket ment å finne.
// ----------------------------------------------------------------------------
describe('virkestoffsynonymer', () => {
  it('står som ELLER-ledd sammen med det kanoniske navnet', () => {
    expect(buildQuery({ drug: 'sertralin' }, [], ['sertraline', 'Zoloft'])).toBe(
      '("sertralin" OR "sertraline" OR "Zoloft")',
    )
  })

  it('bærer hele avgrensningen videre i det brede søket', () => {
    expect(buildQuery(SCOPE, [], ['sertraline'])).toBe(
      '("sertralin" OR "sertraline") AND ("depressiv lidelse" OR "vektendring")',
    )
  })

  it('gjentas i hver målrettede passering', () => {
    expect(buildQueries(SCOPE, 'targeted', [], ['sertraline'])).toEqual([
      '("sertralin" OR "sertraline") AND "depressiv lidelse"',
      '("sertralin" OR "sertraline") AND "vektendring"',
    ])
  })

  it('gjentar ikke det kanoniske navnet når det også står som synonym', () => {
    expect(buildQuery({ drug: 'sertralin' }, [], ['sertralin'])).toBe('"sertralin"')
  })
})

// ----------------------------------------------------------------------------
// Sporene et søk kan erklære
// ----------------------------------------------------------------------------
describe('sporene søket erklærer', () => {
  it('er skjæringen mellom rundens lov og plattformens egen dekning', async () => {
    const search = await runSearch(EUROPE_PMC, QUERY, recorded('europe-pmc-sertraline.json'), [
      'bibliographic_database',
      'trial_registry',
    ])
    expect(search.trackCodes).toEqual(['bibliographic_database'])
  })

  it('er tom når runden ikke ga noen — som for kontrollens motsøk', async () => {
    const search = await runSearch(EUROPE_PMC, QUERY, recorded('europe-pmc-sertraline.json'), [])
    expect(search.trackCodes).toEqual([])
  })
})

describe('plattformene', () => {
  it('bygger adresser som bare peker på det navngitte, offentlige endepunktet', () => {
    for (const platform of SEARCH_PLATFORMS) {
      const url = new URL(platform.endpoint('sertralin'))
      expect(url.protocol).toBe('https:')
      expect(['www.ebi.ac.uk', 'eutils.ncbi.nlm.nih.gov', 'api.crossref.org']).toContain(url.host)
    }
  })

  it('er tre forskjellige plattformer, slik metningsregelen krever', () => {
    expect(new Set(SEARCH_PLATFORMS.map((platform) => platform.name)).size).toBe(3)
  })
})

describe('runSearch', () => {
  it('leser Europe PMC-treff til kandidatkilder med identitet', async () => {
    const search = await runSearch(EUROPE_PMC, QUERY, recorded('europe-pmc-sertraline.json'))
    expect(search.outcome).toBe('executed')
    expect(search.resultCount).toBe(3)
    expect(search.screenedCount).toBe(2)
    expect(search.candidates[0]?.identifier_kind).toBe('doi')
    expect(search.candidates[0]?.identifier_value).toBe('10.1000/syntetisk.2024.001')
    expect(search.candidates[0]?.publication_year).toBe(2024)
    expect(search.responseDigest).toMatch(/^sha256:[0-9a-f]{64}$/)
  })

  it('sier fra når trefflisten er avkortet', async () => {
    const search = await runSearch(EUROPE_PMC, QUERY, recorded('europe-pmc-sertraline.json'))
    expect(search.truncated).toBe(true)
    expect(search.truncationNote).toContain('3 treff')
  })

  // En kilde som ikke er merket åpen tilgang, er tilgangsbegrenset — ikke
  // ekskludert. Betalingsmuren er en tilgangsbegrensning (SOURCE_POLICY.md §5).
  it('merker en kilde uten åpen tilgang som tilgangsbegrenset', async () => {
    const search = await runSearch(EUROPE_PMC, QUERY, recorded('europe-pmc-sertraline.json'))
    expect(search.candidates[0]?.access_limited).toBe(false)
    expect(search.candidates[1]?.access_limited).toBe(true)
    expect(search.candidates[1]?.access_limitation_note).toBeDefined()
  })

  it('skiller et utført nullsøk fra en utilgjengelig søkevei', async () => {
    const tomt = await runSearch(EUROPE_PMC, QUERY, recorded('europe-pmc-tomt.json'))
    expect(tomt.outcome).toBe('zero_results')
    expect(tomt.resultCount).toBe(0)

    const nede = await runSearch(EUROPE_PMC, QUERY, async () => ({
      status: 'error',
      message: 'tidsavbrudd',
    }))
    expect(nede.outcome).toBe('unavailable')
    expect(nede.resultCount).toBeNull()
    expect(nede.limitationNote).toContain('tidsavbrudd')
  })

  it('skiller et svar som ikke lot seg lese, fra et søk uten treff', async () => {
    const ulesbart = await runSearch(EUROPE_PMC, QUERY, async (url) => ({
      status: 'ok',
      httpStatus: 200,
      contentType: 'text/html',
      bytes: new TextEncoder().encode('<html>ikke json</html>'),
      finalUrl: url,
    }))
    expect(ulesbart.outcome).toBe('failed')
    expect(ulesbart.resultCount).toBeNull()
  })

  it('regner en HTTP-feil som en utilgjengelig søkevei', async () => {
    const feil = await runSearch(EUROPE_PMC, QUERY, recorded('europe-pmc-tomt.json', 503))
    expect(feil.outcome).toBe('unavailable')
    expect(feil.limitationNote).toContain('503')
  })

  it('leser PubMed-identifikatorer uten å finne på en tittel', async () => {
    const search = await runSearch(PUBMED, QUERY, recorded('pubmed-sertraline.json'))
    expect(search.outcome).toBe('executed')
    expect(search.candidates).toHaveLength(2)
    expect(search.candidates[0]?.identifier_kind).toBe('pmid')
    expect(search.candidates[0]?.title).toBe('PubMed-oppføring 40000001')
    expect(search.candidates[0]?.access_limited).toBe(true)
  })

  it('leser Crossref-treff med forfattere og tidsskrift', async () => {
    const search = await runSearch(CROSSREF, QUERY, recorded('crossref-sertraline.json'))
    expect(search.outcome).toBe('executed')
    expect(search.candidates[0]?.identifier_value).toBe('10.1000/syntetisk.2022.003')
    expect(search.candidates[0]?.authors_or_issuer).toBe('Testforfatter D')
    expect(search.candidates[0]?.publisher_or_journal).toBe('Journal of Synthetic Reviews')
    expect(search.candidates[0]?.publication_year).toBe(2022)
  })

  it('leser høyst én side, slik en driftskjøring ikke tømmer en tjeneste', () => {
    for (const platform of SEARCH_PLATFORMS) {
      expect(platform.endpoint('x')).toContain(String(PAGE_SIZE))
    }
  })
})

// ============================================================================
// Speilet: hva kjøreren kan, og hva basen tror den kan
//
// Skjæringen i `runSearch` er halve regelen. Den andre halvdelen er porten i
// databasen, som leser `knowledge.monograph_search_platforms`. Er de to ikke
// enige, er den ene av dem usann — og prøvene ville bestått på den snilleste.
//
// Før migrasjon 013x fantes ikke registeret, og pgTAP-prøvene registrerte søk
// som erklærte `systematic_review_search` og `trial_registries` på Europe PMC.
// Kjeden så dekket ut i en prøve mens den sto stille i produksjon. Denne prøven
// er broen som gjør den feilen umulig å gjenta.
// ============================================================================
describe('registeret over søkeveier', () => {
  const MIGRASJON = 'supabase/migrations/20261019092000_the_runner_declares_what_it_can_execute.sql'

  /** Radene migrasjonen seeder, lest som `plattform → spor`. */
  function seededPairs(): ReadonlySet<string> {
    const sql = readFileSync(MIGRASJON, 'utf8')
    const start = sql.indexOf('insert into knowledge.monograph_search_platforms')
    expect(start).toBeGreaterThan(-1)
    const block = sql.slice(start, sql.indexOf(';', start))
    const pairs = new Set<string>()
    for (const match of block.matchAll(/\('([^']+)',\s*'([^']+)'\)/g)) {
      pairs.add(`${match[1]}|${match[2]}`)
    }
    return pairs
  }

  it('speiler nøyaktig plattformene kjøreren faktisk kaller', () => {
    const fraKoden = new Set(
      SEARCH_PLATFORMS.flatMap((platform) =>
        platform.trackCodes.map((code) => `${platform.name}|${code}`),
      ),
    )
    expect(seededPairs()).toEqual(fraKoden)
  })

  it('og de utførbare sporene er utledet, ikke skrevet av', () => {
    const utledet = [...new Set(SEARCH_PLATFORMS.flatMap((p) => p.trackCodes))].sort()
    expect([...EXECUTABLE_TRACK_CODES]).toEqual(utledet)
  })

  it('et søk erklærer aldri et spor plattformen ikke står oppført med', async () => {
    // Runden gir fire spor; Europe PMC dekker ett. Erklærte søket alle fire,
    // ville porten sett dekket ut for tre spor ingen hadde søkt i.
    const search = await runSearch(
      EUROPE_PMC,
      '"sertralin"',
      recorded('europe-pmc-sertraline.json'),
      ['bibliographic_database', 'systematic_review_search', 'trial_registries', 'citing_works'],
    )
    expect(search.trackCodes).toEqual(['bibliographic_database'])
  })
})
