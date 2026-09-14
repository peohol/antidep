# Antidep 2-reset – leveranserapport

- A fullført: baseline `e1a41469aca0f142da21dff8ba4b41f2cf204806`; historiske migrasjonshasher registrert. Node finnes; Poppler og Docker mangler lokalt.
- B fullført: én kort agent-first dokumentasjon og roadmap; gammel MVP-/mikroreviewpolicy fjernet.
- C fullført i kode: app- og repokontroller er seed-uavhengige. Databasefiksturer/regresjoner ligger i pgTAP-migrasjonstestene.
- D fullført i kode: klient-RPC-er stengt, fulltekststrukturvakt og reversibel engangsreset lagt etter legacy-serien.
- E fullført: gammel frontend og review-wizards fjernet; minimalt skall viser ingen kliniske resultater.
- F fullført så langt miljøet tillater: lint, format, typecheck, målrettede Vitest-tester, build og repokontroll består. Hele Vitest-løpet stopper i Poppler-testene fordi `pdftotext` mangler. Database-, samtidighets- og kjedeprøven kunne ikke starte fordi Docker mangler, og må derfor kjøres i CI.

Ingen hostet database er lest eller endret. Permanent PDF-lagring, live modellruntime, kandidatbundet sluttkontroll og klinikerflate er neste leveranse.
