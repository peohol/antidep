// ============================================================================
// Fulltekstinnboksen
//
// Den ene flaten der et menneske gjør noe for at kjeden skal gå videre, og
// handlingen er redaksjonell: kjenne igjen hvilken artikkel som mangler, og
// velge riktig fil. Ingenting mer.
//
// Antidep gjør resten selv — binder filen til publikasjonen, kontrollerer at
// den faktisk *er* den artikkelen, prøver om teksten lar seg lese med tabellene
// i behold, kjører det registrerte tekstuttrekket, registrerer kildeversjonen
// og legger neste ledd i kø. Ingen av delene er synlige her, og ingen av dem er
// noe klinikeren blir spurt om (issue #99, punkt 3).
//
// ----------------------------------------------------------------------------
// Ingen teknisk verdi vises, og ingen blir bedt om
//
// Ingen uuid, ingen hash, ingen oppskrift, ingen adresse, ingen
// terminalkommando. Artikkelen identifiseres av tittel, forfattere og år —
// bibliografien, som er nettopp det en redaktør bruker for å vite hvilken PDF
// som er riktig. Håndtaket flaten sender tilbake, er en ugjennomsiktig
// referanse databasen har laget, og den står aldri på skjermen.
//
// ----------------------------------------------------------------------------
// En avvist fil er ikke en feilmelding
//
// «Filen så ikke ut til å være denne artikkelen» er en produkttilstand, og den
// sier hva som kan gjøres i stedet. Den kommer fra en lukket kode databasen
// registrerte, ikke fra en feiltekst (`full-text-inbox.ts`).
// ============================================================================

import { useCallback, useEffect, useState } from 'react'

import {
  describeArticle,
  inboxStateSentence,
  rejectionSentence,
  type FullTextInboxItem,
} from '../lib/full-text-inbox'
import type { FullTextGateway } from './full-text-gateway'
import { pageMessage } from './gateway'

export interface FullTextInboxPageProps {
  readonly gateway: FullTextGateway
}

/** Hva som skjedde med den siste opplastingen, i én setning til brukeren. */
interface UploadNotice {
  readonly reference: string
  readonly tone: 'ok' | 'problem'
  readonly message: string
}

function InboxEntry({
  item,
  busy,
  notice,
  onUpload,
}: {
  readonly item: FullTextInboxItem
  readonly busy: boolean
  readonly notice: UploadNotice | null
  readonly onUpload: (item: FullTextInboxItem, file: File) => void
}): React.JSX.Element {
  const inputId = `fulltekst-${item.reference}`

  return (
    <li className="inbox-item">
      <h3>{item.title}</h3>
      <p className="inbox-item__article">{describeArticle(item)}</p>
      <p>{inboxStateSentence(item.state)}</p>
      {item.previousRejection === null ? null : (
        <p className="notice">{rejectionSentence(item.previousRejection)}</p>
      )}
      {item.state === 'needs_upload' ? (
        <p>
          <label htmlFor={inputId}>Fulltekst som PDF</label>{' '}
          <input
            accept="application/pdf,.pdf"
            disabled={busy}
            id={inputId}
            onChange={(event) => {
              const file = event.target.files?.[0]
              if (file !== undefined) {
                onUpload(item, file)
              }
              // Feltet tømmes slik at den samme filen kan velges om igjen etter
              // en avvisning. Uten det ville et nytt forsøk på nøyaktig samme
              // fil ikke utløst noen hendelse.
              event.target.value = ''
            }}
            type="file"
          />
        </p>
      ) : null}
      {notice === null ? null : (
        <p aria-live="polite" className={notice.tone === 'ok' ? undefined : 'notice'}>
          {notice.message}
        </p>
      )}
    </li>
  )
}

export function FullTextInboxPage({ gateway }: FullTextInboxPageProps): React.JSX.Element {
  const [items, setItems] = useState<readonly FullTextInboxItem[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<UploadNotice | null>(null)

  const load = useCallback(
    (signal: { cancelled: boolean }) =>
      gateway
        .listInbox()
        .then((rows) => {
          if (!signal.cancelled) {
            setItems(rows)
            setError(null)
          }
        })
        .catch((cause: unknown) => {
          if (!signal.cancelled) {
            setItems(null)
            setError(pageMessage(cause))
          }
        }),
    [gateway],
  )

  useEffect(() => {
    const signal = { cancelled: false }
    void load(signal)
    return () => {
      signal.cancelled = true
    }
  }, [load])

  const upload = useCallback(
    (item: FullTextInboxItem, file: File) => {
      setBusy(true)
      setNotice(null)
      void (async () => {
        try {
          // Filen sendes uendret. Databasen beregner fingeravtrykket av
          // nøyaktig disse bytene, og flaten regner aldri ut noe selv.
          const bytes = new Uint8Array(await file.arrayBuffer())
          await gateway.submit(item.reference, bytes)
          setNotice({
            reference: item.reference,
            tone: 'ok',
            message:
              'Takk — Antidep har fått filen og arbeider videre selv. Du trenger ikke gjøre noe mer.',
          })
          await load({ cancelled: false })
        } catch (cause: unknown) {
          setNotice({
            reference: item.reference,
            tone: 'problem',
            message: pageMessage(cause),
          })
        } finally {
          setBusy(false)
        }
      })()
    },
    [gateway, load],
  )

  return (
    <main id="hovedinnhold">
      <p className="eyebrow">Fulltekst</p>
      <h1>Artikler Antidep mangler</h1>
      <p className="lead">
        Antidep kan ikke bygge kliniske funn på et sammendrag. For hver artikkel under trengs hele
        teksten. Velg riktig PDF, så gjør Antidep resten selv.
      </p>
      {error !== null ? (
        <p className="notice">{error}</p>
      ) : items === null ? (
        <p>Henter listen …</p>
      ) : items.length === 0 ? (
        <p className="notice">
          Antidep venter ikke på noen artikler nå. Dukker det opp en, står den her.
        </p>
      ) : (
        <ul className="inbox-list">
          {items.map((item) => (
            <InboxEntry
              busy={busy}
              item={item}
              key={item.reference}
              notice={notice !== null && notice.reference === item.reference ? notice : null}
              onUpload={upload}
            />
          ))}
        </ul>
      )}
    </main>
  )
}
