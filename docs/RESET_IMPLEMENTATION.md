# Antidep 2-reset – leveranserapport

- A fullført: baseline `e1a41469aca0f142da21dff8ba4b41f2cf204806`; historiske migrasjonshasher registrert.
- B fullført: én kort agent-first dokumentasjon og roadmap; gammel MVP-/mikroreviewpolicy fjernet fra gjeldende dokumentasjon og operative arbeidskataloger.
- C implementert med regresjonsdekning: app-testene er seed-uavhengige, berørte pgTAP-tester bruker transaksjonslokale syntetiske fulltekstfiksturer, og repoets operative dokument-/migrasjonsinvarianter kontrolleres i CI.
- D implementert med fail-closed reset: utdaterte klient-RPC-er er stengt, nye kliniske EvidenceItems krever dokumentbundet fulltekst med gjeldende sikre PDF-oppskrift, og engangsresetten er avgrenset til den reviewede legacy-prototypen. CI prøver både oppgradering fra siste legacy-migrasjon og fresh installasjon, inkludert stopp ved publiseringshistorikk, åpen agentkjøring og uventet klinisk scope, samt bokstavelig omkjøring av resetten etter nytt Antidep 2-innhold. Forhåndskontrollen autoriserer to dokumenterte lineager — den seedede prototyperoten og den hostede fulltekst-reekstraksjonen — og CI prøver begge, samt hver enkelt måte den hostede kan forfalskes på.
- E fullført: gammel frontend og review-wizards er fjernet; det minimale skallet viser ingen kliniske resultater.
- F verifiseres av CI: lint, format, repoinvarianter, typecheck, hele Vitest-løpet, produksjonsbygg, oppgraderingsprøve, migrasjoner, pgTAP, samtidighetsprøve og den dokumentbundne PDF → ekstraksjon → uavhengig kontroll-kjeden skal alle være grønne på samme PR-head før denne leveransen kan regnes som teknisk ferdig.

Produksjonsdatabasen er lest (read-only) for å fastslå hvilken lineage resetten faktisk gjelder; se avsnittet under. Ingen hostet database er endret utenom gjennom migrasjonssystemet. Permanent privat PDF-lagring, kandidatbundet sluttkontroll og klinikerflate kom med den etterfølgende leveransen (migrasjon 009–009d), og publiseringen, tilbaketrekkingen og rollbacken med den neste (migrasjon 009e–009h). Den eksterne agent-handoffen kom med migrasjon 010a–010c, og den autonome kjøreren over den med 011a; det som gjenstår, er kildeinngangen fra flaten og de deterministiske kontrolleddene. Se [roadmap](ROADMAP.md).

## Den faktiske lineagen i produksjon

Forhåndskontrollen stoppet i produksjon fordi den lette etter en tilstand som ikke lenger fantes der. Den forventet at de to evidensrøttene fortsatt pekte på de sammendragssnapshotene migrasjon `20260819064500` seedet, og at de var fra før agentproveniens og creation-audit. Repobaselinen er slik. Produksjonen er det ikke, og har ikke vært det siden 12. september 2026.

Kjeden, lest ut av produksjonens egen append-only audit og uforanderlige metadata:

1. `20260819064500` seedet de to kildene, deres PMID-er og ett uforanderlig MEDLINE-sammendragssnapshot hver (`sha256:797e91b6…` for sertralin, `sha256:c62a6621…` for mirtazapin, begge hentet `2026-08-19T06:17:31Z`). **Begge snapshotene står uendret i produksjon i dag**, og er ankeret hele resten av kjeden henger i.
2. 11.–12. september 2026 ble fulltekstene registrert, først med `pdftotext -layout`, så med `antidep-reading-order@1`.
3. 12. september kl. 10:16 forkastet eieren fire fulltekstfunn (`extraction_artifact_discarded`): tekst fra to spalter havnet på samme tekstlinje, så leserekkefølgen kunne ikke etterprøves (issue #84).
4. 12. september kl. 19:19 forkastet eieren fem funn til og begge påstandene (`extraction_artifact_discarded`, `claim_artifact_discarded`). Begrunnelsen i auditen navngir dem: to fulltekstfunn på `antidep-reading-order@1`, og **de tre sammendragsutledede fra pipelinens tidligste prøver**. Det er de opprinnelige legacy-røttene. De ble altså slettet av eieren selv, før resetten var skrevet.
5. 12. september kl. 19:41 og 20:39 ble de to studiene reekstrahert fra den registrerte fullteksten av to agentkjøringer som begge lyktes. Det er dagens to evidensrøtter.
6. 13. september kl. 02:19 og 05:18 ble den ene gjenstående påstanden syntetisert i to revisjoner.
7. 14. september kl. 08:46:42 UTC autoriserte eieren resetten i commit `e1a41469aca0f142da21dff8ba4b41f2cf204806`.

Alt innholdet i produksjon er altså laget **før** autoriseringen, ingenting er publisert, reviewet eller påstandskontrollert, og mirtazapinroten hviler dessuten på den avløste oppskriften `antidep-reading-order@1`, som dagens fulltekstvakt avviser. Dagens røtter er en legitim videreføring av den avgrensede legacy-prototypen, ikke nyere klinisk innhold.

Forhåndskontrollen autoriserer derfor nøyaktig denne kjeden, og ikke noe mer:

- **Ankeret.** Hver evidensrot må høre til en kilde som fortsatt bærer det autoriserte PMID-et **og** det uforanderlige sammendragssnapshotet med nøyaktig seedet hash, hentetid, EUtils-adresse og eksterne versjon. Rotens egen kildeversjon må enten være det snapshotet, eller en fulltekstrepresentasjon av den samme kilden registrert før autoriseringen.
- **Lineagen.** Roten må enten være seedet fra før agentproveniens og creation-audit, eller være nøyaktig den autoriserte reekstraksjonen: riktig innholdsavtrykk, riktig forankringsavtrykk og riktig avtrykk av modellforespørselen i kjøringens uforanderlige manifest.
- **Grensen.** `audit.events` er append-only, og `occurred_at` settes av triggerens egen `now()` — ikke av kalleren. En klinisk rot stemplet etter autoriseringstidspunktet stopper resetten, uansett hvor legacy-lik den ser ut. En reekstraksjon som gjenskaper det samme innholdsavtrykket, får likevel et nytt forespørselsavtrykk og et nytt stempel.

`scripts/db-upgrade-antidep2-hosted-fulltext-lineage.sh` gjenskaper produksjonsformen og prøver både at den autoriseres, og at den avvises når creation-auditen flyttes forbi autoriseringen, når forespørselsavtrykket er en annen kjørings, og når fullteksten er registrert etter autoriseringen. En creation-audit for en rad som ikke finnes lenger — produksjonen er full av dem etter forkastingene — blokkerer ikke sin egen reset.
