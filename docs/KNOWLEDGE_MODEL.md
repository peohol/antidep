# Kunnskapsmodell

## Eksisterende modell

`knowledge.sources` identifiserer en publikasjon eller autoritativ kilde. `source_versions` identifiserer representasjonen som faktisk ble lest og eventuell dokument-/tekstuttrekksbinding. `evidence_items` er atomiske ekstraksjoner. `claims` gir stabil identitet, mens `claim_revisions` er uforanderlige formuleringer. Lenker binder revisjonen til funn; verifikasjoner, vurderinger, agentkjøringer, reviewbeslutninger og publiseringshendelser gir proveniens og porter.

`knowledge.source_documents` er det private fulltekstbiblioteket: originalfilen selv, innholdsadressert på sitt eget fingeravtrykk. `source_document_publications` sier hvilken publikasjon filen er *vist* å tilhøre, og på hvilket grunnlag. `full_text_readability_checks` bærer målingen bak lesbarhetsdommen for én fulltekstversjon; fraværet av raden er dommen.

`knowledge.candidates` forsegler det agentferdige innholdet for én påstandsrevisjon — påstanden, vurderingen, kontrollene, evidensfunnene med sine ordrette utdrag og kildedekningen — med et avtrykk som *er* innholdet. `workflow.candidate_final_controls` bærer en navngitt fagpersons beslutning om nøyaktig den kandidaten, låst til den av en sammensatt fremmednøkkel.

`workflow.pipeline_jobs` er arbeidet som gjenstår, identifisert av hva det handler om framfor av når det ble lagt inn; `pipeline_job_events` er det append-only sporet over hver tilstandsovergang, og `pipeline_job_runs` sier hvilken agentkjøring som ble åpnet for hvilket uttak. `provenance.role_model_assignments` sier hvilken modellidentitet hver agentrolle handler som, og lar ingen to roller dele en. Raden kan ikke skrives om; den kan bare avsluttes, og både registreringen og avslutningen føres i `audit.events`.

Katalogdata er begreper og legemiddelidentiteter, ikke kliniske konklusjoner. Kildebiblioteket bevares ved reset, mens avledet prototypekunnskap tas ut av aktiv drift.

`knowledge.publication_events` er den append-only historikken over hva Antidep har sagt. Hver hendelse navngir både revisjonen og det forseglede innholdet som ble publisert — og for en tilbaketrekking, det innholdet som ble tatt ut av visning — sammen med den sluttkontrollen publiseringen hviler på. `knowledge.claims` bærer to pekere som ikke kan si hver sin ting: revisjonen og kandidaten som er publisert nå.

## Planlagt, ikke implementert

Et eget studie-/rapportobjekt.
