// ============================================================================
// «Be Antidep om en artikkel»
//
// Den andre av de to handlingene et menneske gjør i kjeden, og den er like
// redaksjonell som den første: å avgjøre hvilken artikkel Antidep trenger, og
// hva et funn fra den kan gjelde. Etter dette går resten av seg selv — helt
// fram til kandidaten, som en navngitt fagperson vurderer i `/kandidater`.
//
// ----------------------------------------------------------------------------
// Hva skjemaet spør om, og hva det aldri spør om
//
// Tittel, forfattere, tidsskrift, år og DOI. Det er bibliografien, altså
// nøyaktig det en redaktør har foran seg når de vet hvilken artikkel som
// mangler — og det samme fulltekstinnboksen senere viser den som skal kjenne
// igjen riktig PDF.
//
// Så de tre faglige avgrensningene: hvilke virkestoff, hvilke endepunkt og
// hvilken populasjon et funn kan gjelde. De velges fra Antideps egen katalog,
// med navn og ikke id-er — en liste er dessuten et svar på spørsmålet «hva kan
// jeg velge?», som fritekst aldri er.
//
// Ingen uuid, ingen hash, ingen oppskrift, ingen jobbnøkkel, ingen agentrolle,
// ingen modell, ingen kjører og ingen terminalkommando. Ingen av dem er noe en
// kliniker skal se, og ingen av dem trengs: Antidep utleder kilderaden,
// adressen dokumentet hentes fra, kildeversjonen og hele køen selv
// (AGENTS.md, issue #101 punkt 3).
//
// ----------------------------------------------------------------------------
// Hvorfor siden spør om hva du kan gjøre, før den viser skjemaet
//
// `/fulltekst` er åpen for både redaktør og administrator, men bare en redaktør
// kan bestille. Et skjema vist til begge ville bedt en administrator gjøre noe
// kallet uansett måtte avvise — og en avvisning på noe man ikke gjorde galt, er
// nettopp den tekniske støyen regelen i AGENTS.md handler om.
// ============================================================================

import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router'

import {
  EMPTY_REQUEST,
  requestOutcomeSentence,
  requestProblem,
  type FullTextRequestDraft,
  type FullTextRequestOptions,
} from '../lib/full-text-request'
import type { FullTextGateway } from './full-text-gateway'
import { pageMessage } from './gateway'
import { fullTextInboxPath, workBoardPath } from './routes'

export interface FullTextRequestPageProps {
  readonly gateway: FullTextGateway
}

/** Hva som skjedde med den siste bestillingen, i én setning til brukeren. */
interface RequestNotice {
  readonly tone: 'ok' | 'problem'
  readonly message: string
}

/**
 * Flervalg som avkrysningsbokser og ikke som en `<select multiple>`.
 *
 * En flervalgsliste krever ctrl-klikk for å velge mer enn ett, og det er ikke
 * åpenbart for noen. Avkrysningsbokser er selvforklarende, leses av en
 * skjermleser som det de er, og viser hele utvalget uten at noen må bla.
 */
function ChoiceList({
  legend,
  help,
  name,
  options,
  selected,
  onChange,
}: {
  readonly legend: string
  readonly help: string
  readonly name: string
  readonly options: readonly string[]
  readonly selected: readonly string[]
  readonly onChange: (next: readonly string[]) => void
}): React.JSX.Element {
  return (
    <fieldset className="choices">
      <legend>{legend}</legend>
      <p className="choices__help">{help}</p>
      {options.length === 0 ? (
        <p className="notice">Antidep har ingen valg å tilby her ennå.</p>
      ) : (
        <ul className="choices__list">
          {options.map((option) => {
            const id = `${name}-${option.replace(/\s+/g, '-')}`
            return (
              <li key={option}>
                <input
                  checked={selected.includes(option)}
                  id={id}
                  onChange={(event) => {
                    onChange(
                      event.target.checked
                        ? [...selected, option]
                        : selected.filter((value) => value !== option),
                    )
                  }}
                  type="checkbox"
                  value={option}
                />{' '}
                <label htmlFor={id}>{option}</label>
              </li>
            )
          })}
        </ul>
      )}
    </fieldset>
  )
}

export function FullTextRequestPage({ gateway }: FullTextRequestPageProps): React.JSX.Element {
  const [options, setOptions] = useState<FullTextRequestOptions | null>(null)
  const [mayRequest, setMayRequest] = useState<boolean | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [draft, setDraft] = useState<FullTextRequestDraft>(EMPTY_REQUEST)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<RequestNotice | null>(null)

  useEffect(() => {
    let cancelled = false
    void (async () => {
      try {
        const capabilities = await gateway.capabilities()
        if (cancelled) {
          return
        }
        setMayRequest(capabilities.mayRequest)
        if (!capabilities.mayRequest) {
          return
        }
        const list = await gateway.requestOptions()
        if (!cancelled) {
          setOptions(list)
          setError(null)
        }
      } catch (cause: unknown) {
        if (!cancelled) {
          setError(pageMessage(cause))
        }
      }
    })()
    return () => {
      cancelled = true
    }
  }, [gateway])

  const send = useCallback(() => {
    // Kontrolleres før kallet. Databasen avviser uansett, men en avvisning som
    // kommer tilbake uten å si hvilket felt den gjaldt, er ikke til å handle på.
    const problem = requestProblem(draft)
    if (problem !== null) {
      setNotice({ tone: 'problem', message: problem })
      return
    }
    setBusy(true)
    setNotice(null)
    void (async () => {
      try {
        const result = await gateway.request(draft)
        setNotice({ tone: 'ok', message: requestOutcomeSentence(result) })
        // Feltene tømmes bare når bestillingen faktisk ble tatt imot. Ble den
        // ikke det, skal den som skrev dem, slippe å skrive alt på nytt.
        if (result.requested) {
          setDraft(EMPTY_REQUEST)
        }
      } catch (cause: unknown) {
        setNotice({ tone: 'problem', message: pageMessage(cause) })
      } finally {
        setBusy(false)
      }
    })()
  }, [draft, gateway])

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Fulltekst</p>
      <h1>Be Antidep om en artikkel</h1>
      <p className="lead">
        Mangler Antidep en artikkel du mener bør være med, kan du be om den her. Du sier hvilken
        artikkel det er, og hva et funn fra den kan gjelde. Resten gjør Antidep selv.
      </p>

      {error !== null ? (
        <p className="notice">{error}</p>
      ) : mayRequest === null ? (
        <p>Henter siden …</p>
      ) : !mayRequest ? (
        <p className="notice">
          Å be om en artikkel er en redaksjonell avgjørelse, og krever redaktørmandat. Ta kontakt
          med en administrator hvis du skulle hatt det.
        </p>
      ) : options === null ? (
        <p>Henter valgene …</p>
      ) : (
        <form
          onSubmit={(event) => {
            event.preventDefault()
            send()
          }}
        >
          <section aria-labelledby="artikkel-title">
            <h2 id="artikkel-title">Hvilken artikkel er det?</h2>
            <p>
              <label htmlFor="tittel">Tittel</label>
              <input
                disabled={busy}
                id="tittel"
                onChange={(event) => {
                  setDraft({ ...draft, title: event.target.value })
                }}
                type="text"
                value={draft.title}
              />
            </p>
            <p>
              <label htmlFor="forfattere">Forfattere</label>
              <input
                disabled={busy}
                id="forfattere"
                onChange={(event) => {
                  setDraft({ ...draft, authors: event.target.value })
                }}
                placeholder="Etternavn m.fl."
                type="text"
                value={draft.authors}
              />
            </p>
            <p>
              <label htmlFor="tidsskrift">Tidsskrift (valgfritt)</label>
              <input
                disabled={busy}
                id="tidsskrift"
                onChange={(event) => {
                  setDraft({ ...draft, journal: event.target.value })
                }}
                type="text"
                value={draft.journal}
              />
            </p>
            <p>
              <label htmlFor="ar">Årstall (valgfritt)</label>
              <input
                disabled={busy}
                id="ar"
                inputMode="numeric"
                onChange={(event) => {
                  setDraft({ ...draft, year: event.target.value })
                }}
                type="text"
                value={draft.year}
              />
            </p>
            <p>
              <label htmlFor="doi">DOI</label>
              <input
                disabled={busy}
                id="doi"
                onChange={(event) => {
                  setDraft({ ...draft, doi: event.target.value })
                }}
                placeholder="10.1016/j.jad.2019.01.001"
                type="text"
                value={draft.doi}
              />
            </p>
            <p className="choices__help">
              DOI-en står på artikkelens forside og i referanselisten. Du kan lime inn en lenke til
              doi.org om det er enklere.
            </p>
          </section>

          <section aria-labelledby="avgrensning-title">
            <h2 id="avgrensning-title">Hva kan et funn fra artikkelen gjelde?</h2>
            <p>
              Dette er den faglige avgrensningen. Den bestemmer hva Antidep leter etter i
              artikkelen, og du blir ikke spurt om den igjen senere.
            </p>
            <ChoiceList
              help="Velg de virkestoffene et funn fra artikkelen kan handle om."
              legend="Virkestoff"
              name="virkestoff"
              onChange={(next) => {
                setDraft({ ...draft, drugs: next })
              }}
              options={options.drugs}
              selected={draft.drugs}
            />
            <ChoiceList
              help="Velg det artikkelen måler — det du vil vite noe om."
              legend="Endepunkt"
              name="endepunkt"
              onChange={(next) => {
                setDraft({ ...draft, outcomes: next })
              }}
              options={options.outcomes}
              selected={draft.outcomes}
            />
            <ChoiceList
              help="Velg pasientgruppen funnet kan gjelde, hvis det er avgrenset til én."
              legend="Populasjon (valgfritt)"
              name="populasjon"
              onChange={(next) => {
                setDraft({ ...draft, populations: next })
              }}
              options={options.populations}
              selected={draft.populations}
            />
          </section>

          <p>
            <button disabled={busy} type="submit">
              {busy ? 'Sender …' : 'Be om artikkelen'}
            </button>
          </p>
          {notice === null ? null : (
            <p aria-live="polite" className={notice.tone === 'ok' ? undefined : 'notice'}>
              {notice.message}
            </p>
          )}
        </form>
      )}

      <p>
        <Link to={fullTextInboxPath()}>Artikler Antidep mangler</Link> — der velges riktig PDF når
        den er skaffet.
      </p>
      <p>
        <Link to={workBoardPath()}>Arbeidsoversikt</Link> — der står bestillingen som planlagt
        arbeid til fullteksten er på plass.
      </p>
    </main>
  )
}
