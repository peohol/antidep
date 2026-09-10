// ============================================================================
// Originaldokumentet: fingeravtrykket, hva slags fil det er, og hvor det ligger
//
// En kildeversjon har hittil vært én ting: en adresse som kan hentes på nytt,
// og sha256 av svaret. Det holder for en MEDLINE-post. Det holder ikke for en
// fulltekstartikkel, som normalt er en PDF Antidep verken har rett til å
// redistribuere (EVIDENCE_PIPELINE.md §14) eller kan hente på nytt fra en åpen
// adresse.
//
// ----------------------------------------------------------------------------
// Hvorfor dokumentet identifiseres av bytene sine, og ikke av et filnavn
//
// «Fava-2000.pdf» er ikke en identitet. To filer med samme navn kan være to
// forskjellige dokumenter, og det samme dokumentet kan hete noe annet på en
// annen maskin. sha256 av bytene er derimot den samme overalt, kan regnes ut av
// hvem som helst med `sha256sum`, og endrer seg dersom ett eneste tegn i
// dokumentet gjør det.
//
// Fingeravtrykket eies av databasen: `api.create_source_version_from_document`
// beregner det av bytene kalleren sender, akkurat som `content_hash` beregnes
// av teksten (migrasjon 003e). Funksjonene her er kjørerens motstykke — den som
// skal *etterprøve* et fingeravtrykk, må kunne regne det ut selv, ellers ville
// kontrollen vært «databasen sier at databasens egen verdi stemmer».
//
// ----------------------------------------------------------------------------
// Det lokale dokumentlageret
//
// Originaldokumentene ligger som lokale arbeidsfiler og skal ikke commites
// (`documents/README.md`). Et ledd som trenger dokumentet, slår det derfor opp
// på **fingeravtrykket** framfor på et filnavn: katalogen leses, hver fil
// hashes, og den som stemmer er dokumentet. Da kan filene hete hva som helst,
// og en fil som er byttet ut, blir aldri forvekslet med den registrerte.
//
// Utrygg inndata: et dokument er data, aldri instruksjoner (CLAUDE.md). Bytene
// leses aldri som noe annet enn bytes, og teksten som hentes ut av dem, brukes
// bare som høystakk for ordrette søk.
// ============================================================================

import { readdir, readFile, stat } from 'node:fs/promises'
import { join } from 'node:path'

import {
  documentDigest,
  isDocumentDigest,
  looksLikePdf,
  PDF_MAGIC,
  PDF_MEDIA_TYPE,
} from './document-binding.ts'

/** Ett dokument, slik kjeden trenger det. */
export interface LoadedDocument {
  /** Filen bytene ble lest fra, slik kalleren kan navngi den i en melding. */
  readonly path: string
  readonly bytes: Uint8Array
  readonly digest: string
  readonly byteSize: number
  readonly mediaType: string
}

export type DocumentResult =
  | { readonly status: 'ok'; readonly document: LoadedDocument }
  | { readonly status: 'error'; readonly message: string }

/**
 * Oppslaget som en injiserbar grenseflate: ett fingeravtrykk inn, ett utfall ut.
 *
 * Ligger her, sammen med lageret, av samme grunn som `RetrieveLike` ligger i
 * `source-retrieval.ts`: hvert ledd som trenger et dokument, skal kunne prøves
 * uten et filsystem, og typen skal ikke hentes fra en modul som kan skrive en
 * rad.
 */
export type DocumentLookup = (digest: string) => Promise<DocumentResult>

/** Leser ett dokument fra en kjent sti, og beskriver det. */
export async function loadDocumentFile(path: string): Promise<DocumentResult> {
  let bytes: Uint8Array
  try {
    bytes = new Uint8Array(await readFile(path))
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause)
    return { status: 'error', message: `Klarte ikke å lese ${path}: ${message}` }
  }
  if (bytes.length === 0) {
    return { status: 'error', message: `${path} er tom, og en tom fil har ingen fingeravtrykk.` }
  }
  if (!looksLikePdf(bytes)) {
    return {
      status: 'error',
      message:
        `${path} begynner ikke med PDF-signaturen «${PDF_MAGIC}». Antidep henter i dag bare ` +
        'tekst ut av PDF, og en fil av et annet slag ville blitt registrert med en proveniens ' +
        'som ikke kan etterprøves.',
    }
  }
  return {
    status: 'ok',
    document: {
      path,
      bytes,
      digest: await documentDigest(bytes),
      byteSize: bytes.length,
      mediaType: PDF_MEDIA_TYPE,
    },
  }
}

/**
 * Slår opp ett dokument i en lokal katalog, på fingeravtrykket.
 *
 * Katalogen leses flatt og hver fil hashes. Det er med vilje enkelt: lageret er
 * en håndfull artikler en redaktør har lagret lokalt, ikke et arkiv, og et
 * oppslag som gikk på filnavn ville gjort navnet til identiteten.
 *
 * En fil som ikke lar seg lese, hoppes over framfor å stoppe oppslaget: en
 * katalog med én ødelagt fil skal ikke gjøre alle de andre utilgjengelige.
 */
export function documentsIn(directory: string): DocumentLookup {
  return async (digest: string): Promise<DocumentResult> => {
    if (!isDocumentDigest(digest)) {
      return {
        status: 'error',
        message: `«${digest}» har ikke formen «sha256:» etterfulgt av 64 heksadesimale tegn.`,
      }
    }

    let entries: readonly string[]
    try {
      entries = await readdir(directory)
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : String(cause)
      return {
        status: 'error',
        message:
          `Klarte ikke å lese dokumentkatalogen ${directory}: ${message}. Legg ` +
          'originaldokumentet der, eller oppgi katalogen med --documents.',
      }
    }

    for (const entry of [...entries].sort()) {
      const path = join(directory, entry)
      let isFile: boolean
      try {
        isFile = (await stat(path)).isFile()
      } catch {
        continue
      }
      if (!isFile) {
        continue
      }
      let bytes: Uint8Array
      try {
        bytes = new Uint8Array(await readFile(path))
      } catch {
        continue
      }
      if ((await documentDigest(bytes)) !== digest) {
        continue
      }
      return {
        status: 'ok',
        document: {
          path,
          bytes,
          digest,
          byteSize: bytes.length,
          mediaType: PDF_MEDIA_TYPE,
        },
      }
    }

    return {
      status: 'error',
      message:
        `Fant ingen fil i ${directory} med fingeravtrykket ${digest}. Kildeversjonen er ` +
        'registrert med nøyaktig dette dokumentet, og et annet dokument er ikke det samme ' +
        'dokumentet — heller ikke en nyere nedlasting av den samme artikkelen.',
    }
  }
}

/**
 * Katalogen originaldokumentene ligger i når ingen oppgir noe annet.
 *
 * En fast plass i repoet, gitignorert (`documents/README.md`). Verdien er en
 * relativ sti med vilje: den skal peke på arbeidskatalogen til den som kjører,
 * ikke på en maskin.
 */
export const DEFAULT_DOCUMENT_DIRECTORY = 'documents'

/** Miljøvariabelen som flytter dokumentlageret et annet sted. */
export const DOCUMENT_DIRECTORY_VARIABLE = 'ANTIDEP_DOCUMENT_DIR'

/**
 * Dokumentoppslaget hver kjører bruker.
 *
 * Alltid satt, også når katalogen ikke finnes: et ledd som møter en
 * dokumentbundet kildeversjon uten et oppslag, ville sagt «ingen
 * dokumentkatalog oppgitt», mens det som faktisk gjelder er «dokumentet ligger
 * ikke der». Den andre setningen er den som hjelper.
 */
export function documentsFromEnv(
  env: Readonly<Record<string, string | undefined>>,
): DocumentLookup {
  const directory = env[DOCUMENT_DIRECTORY_VARIABLE]?.trim()
  return documentsIn(
    directory === undefined || directory.length === 0 ? DEFAULT_DOCUMENT_DIRECTORY : directory,
  )
}
