# Antidep 2-reset – leveranserapport

- A fullført: baseline `e1a41469aca0f142da21dff8ba4b41f2cf204806`; historiske migrasjonshasher registrert.
- B fullført: én kort agent-first dokumentasjon og roadmap; gammel MVP-/mikroreviewpolicy fjernet.
- C fullført og verifisert: app-testene er seed-uavhengige, og hver berørt pgTAP-test inkluderer en transaksjonslokal, syntetisk og dokumentbundet fulltekst-fixtur som rulles tilbake etter testen. Hele databasepakken består i CI (56 pgTAP-filer, 1699 tester).
- D fullført og verifisert: utdaterte klient-RPC-er er stengt, fulltekststrukturvakten gjelder alle nye EvidenceItems, og den reversible engangsresetten ligger etter legacy-serien. Migrasjonene går fra bunnen av i CI, og både samtidighetsprøven og den dokumentbundne PDF → ekstraksjon → uavhengig kontroll-kjeden består mot en ekte lokal Supabase-stack.
- E fullført: gammel frontend og review-wizards fjernet; minimalt skall viser ingen kliniske resultater.
- F fullført for repoets isolerte kontrollflate: lint, format, repoinvarianter, typecheck, hele Vitest-løpet, produksjonsbygg, migrasjoner, pgTAP, samtidighetsprøve og kjedeprøve består i CI.

Ingen hostet database er lest eller endret. Permanent PDF-lagring, live modellruntime, kandidatbundet sluttkontroll og klinikerflate er neste leveranse.
