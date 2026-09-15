# Antidep 2-reset – leveranserapport

- A fullført: baseline `e1a41469aca0f142da21dff8ba4b41f2cf204806`; historiske migrasjonshasher registrert.
- B fullført: én kort agent-first dokumentasjon og roadmap; gammel MVP-/mikroreviewpolicy fjernet fra gjeldende dokumentasjon og operative arbeidskataloger.
- C implementert med regresjonsdekning: app-testene er seed-uavhengige, berørte pgTAP-tester bruker transaksjonslokale syntetiske fulltekstfiksturer, og repoets operative dokument-/migrasjonsinvarianter kontrolleres i CI.
- D implementert med fail-closed reset: utdaterte klient-RPC-er er stengt, nye kliniske EvidenceItems krever dokumentbundet fulltekst med gjeldende sikre PDF-oppskrift, og engangsresetten er avgrenset til den reviewede legacy-prototypen. CI prøver både oppgradering fra siste legacy-migrasjon og fresh installasjon, inkludert stopp ved publiseringshistorikk, åpen agentkjøring og uventet klinisk scope, samt bokstavelig omkjøring av resetten etter nytt Antidep 2-innhold.
- E fullført: gammel frontend og review-wizards er fjernet; det minimale skallet viser ingen kliniske resultater.
- F verifiseres av CI: lint, format, repoinvarianter, typecheck, hele Vitest-løpet, produksjonsbygg, oppgraderingsprøve, migrasjoner, pgTAP, samtidighetsprøve og den dokumentbundne PDF → ekstraksjon → uavhengig kontroll-kjeden skal alle være grønne på samme PR-head før denne leveransen kan regnes som teknisk ferdig.

Ingen hostet database er lest eller endret. Permanent privat PDF-lagring, kandidatbundet sluttkontroll og klinikerflate kom med den etterfølgende leveransen (migrasjon 009–009d), og publiseringen, tilbaketrekkingen og rollbacken med den neste (migrasjon 009e–009h). Den eksterne agent-handoffen kom med migrasjon 010a–010c; det som gjenstår, er kildeinngangen fra flaten. Se [roadmap](ROADMAP.md).
