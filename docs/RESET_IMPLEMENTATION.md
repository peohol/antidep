# Antidep 2-reset – leveranserapport

- A fullført: baseline `e1a41469aca0f142da21dff8ba4b41f2cf204806`; historiske migrasjonshasher registrert. Node, Poppler og Docker-klienten finnes lokalt; containeren mangler kernel-rettigheter til å starte Docker-daemonen.
- B fullført: én kort agent-first dokumentasjon og roadmap; gammel MVP-/mikroreviewpolicy fjernet.
- C implementert, ikke ferdig verifisert: app-testene er seed-uavhengige, og hver berørt pgTAP-test inkluderer en transaksjonslokal, syntetisk og dokumentbundet fulltekst-fixtur som rulles tilbake etter testen.
- D pågår: klient-RPC-er er stengt, og fulltekststrukturvakt og reversibel engangsreset er lagt etter legacy-serien. Hele migrasjonskjeden er ikke lokalt verifisert uten en kjørbar containerdaemon.
- E fullført: gammel frontend og review-wizards fjernet; minimalt skall viser ingen kliniske resultater.
- F fullført så langt miljøet tillater: lint, format, typecheck, målrettede Vitest-tester, build og repokontroll består. Hele Vitest-løpet består (62 filer, 1575 tester). Database-, samtidighets- og kjedeprøven kunne ikke starte fordi Docker-daemonen ikke kan opprette NAT-kjeden i containeren, og må derfor kjøres i CI.

Ingen hostet database er lest eller endret. Permanent PDF-lagring, live modellruntime, kandidatbundet sluttkontroll og klinikerflate er neste leveranse.
