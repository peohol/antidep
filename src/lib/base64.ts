// ============================================================================
// Byte til base64, uten å bygge én kjempestreng av gangen
//
// En fulltekstartikkel er normalt noen få megabyte, og grensen er 64. Et enkelt
// `String.fromCharCode(...bytes)` ville sendt hele filen inn som argumenter og
// sprengt kallstakken lenge før den grensen. Omformingen går derfor i biter.
//
// Filen sendes byte for byte, uendret. Enhver omforming underveis ville gitt et
// fingeravtrykk som ikke er filens — og databasen beregner fingeravtrykket av
// nøyaktig de bytene den får (ANTIDEP_CONSTITUTION.md regel 2).
// ============================================================================

const CHUNK = 0x8000

export function toBase64(bytes: Uint8Array): string {
  let binary = ''
  for (let offset = 0; offset < bytes.length; offset += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + CHUNK))
  }
  return btoa(binary)
}
