// Utfallene ett maskinelt søk kan ha. Eget blad-modul, fordi både søkekoden og
// svarformene leser dem, og svarformene leser også katalogen over søkemetodene:
// en felles liste her hindrer at de to blir en sirkel.

/** Utfallene ett søk kan ha. De to siste er ikke null treff. */
export const SEARCH_OUTCOMES = ['executed', 'zero_results', 'unavailable', 'failed'] as const
