# Roadmap

Forrige leveranse — **fulltekstbibliotek + reell agentkjede + én lesbar klinikerflate med sluttkontroll** — er implementert.

Den ga privat PDF-lagring i databasen med serverberegnet filidentitet, kontrollert publikasjonstilhørighet, lesbarhets- og tabellkontroll av fullteksten, varig og idempotent jobbtilstand, reelt separate modellroller med databasehåndhevet forbud mot egenverifikasjon, synlig kildedekning, og en forseglet kandidat der sluttkontrollen er bundet til nøyaktig det innholdet som ble lest.

Neste sammenhengende leveranse er **publiseringen**: å åpne den kontrollerte veien fra en sluttkontrollert kandidat til publisert klinikerinnhold, med tilbaketrekking og rollback som synlige hendelser. Publiserings-API-et er fortsatt stengt for klientrollene, og skal først åpnes med den leveransen.

Deretter gjenstår en live semantisk modellruntime, slik at utkastleddene kjøres av en leverandørmodell framfor av et opptak. Datamodellen tar allerede imot det; det som mangler, er legitimasjonen og adapteret.
