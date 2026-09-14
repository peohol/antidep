# Evidenskjeden

## Ønsket kjede

Klinisk spørsmål → discovery → komplett fulltekst → kildevurdering → ekstraksjon → separat ekstraksjonskontroll → syntese → motprøving → kildestøttekontroll → separat evidensvurdering → redaksjonell formulering → meningskontroll → agentferdig kandidat → menneskelig sluttkontroll → eksplisitt publisering.

Abstract og metadata stopper ved discovery. Begrensede representasjoner kan aldri bli EvidenceItem eller indirekte syntesegrunnlag.

## Implementert nå

- Versjonerte kilder, dokumentfingeravtrykk og tillatt PDF-tekstuttrekksoppskrift.
- Opptaksbasert modelladapter og rolleavgrensede agentinnganger for ekstraksjon, kontroll, syntese og evidensvurdering.
- Separate proveniens- og kontrollrader, fulltekststrukturvakt og publiseringsgater.
- Lokal pgTAP-, samtidighets- og kjedeprøve.

## Mangler

Permanent privat PDF-lagring og validering av publikasjonstilhørighet, live semantisk runtime, varig jobbkø, ferdig kliniker-renderer og kandidatbundet sluttgodkjenning/publisering. Et lagringsnavn eller PDF-signatur beviser ikke at disse leddene finnes.
