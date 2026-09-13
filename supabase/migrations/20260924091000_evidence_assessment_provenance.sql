-- ============================================================================
-- Migrasjon 004b — evidensvurderingen får si hvilken agentkjøring den kom av
--
-- Speilbildet av migrasjon 004a, og den finnes av samme grunn. 004a ga
-- påstandsrevisjonen de to sammensatte fremmednøklene mot
-- `provenance.agent_runs`, slik at en revisjon ikke kan tilskrives én aktør og
-- peke på en kjøring som tilhører en annen, og ikke kan bæres av en kjøring i
-- en rolle som ikke skal kunne formulere påstander.
--
-- `knowledge.evidence_assessments` har hatt `created_by_actor_id` siden
-- migrasjon 005 — *hvem* vurderte — men ingen peker til kjøringen som bærer
-- modell, modellversjon, promptmal og pipelineversjon. Så lenge vurderingen ble
-- skrevet inne i synteseveien, var den mangelen skjult av at revisjonen ved
-- siden av hadde pekeren. Migrasjon 005am flytter vurderingen ut i sitt eget
-- ledd; da er den sin egen handling, av sin egen aktør, i sin egen kjøring, og
-- må kunne spores som det (ANTIDEP_CONSTITUTION.md §8, §20).
--
--   (agent_run_id, created_by_actor_id) → provenance.agent_runs (id, actor_id)
--   (agent_run_id, agent_run_role)      → provenance.agent_runs (id, agent_role)
--
-- `agent_run_role` er en **generert** konstant, som på `claim_revisions`,
-- `evidence_items`, `evidence_verifications` og `claim_verifications`. Rollen er
-- dermed ikke noe en kaller oppgir, og kan ikke oppgis feil.
--
-- `agent_run_id` er NULL-bar. NULL betyr at vurderingen ikke kom av en
-- agentkjøring — tilstanden til enhver vurdering en kvalifisert redaktør gjør
-- selv. Fremmednøkkelen er MATCH SIMPLE, så en NULL peker slår av kravet. Den
-- ene raden som står i basen i dag, er skrevet av synteseveien og har derfor
-- ingen peker; den ryddes gjennom prosjektets egen discard-vei, ikke herfra.
--
-- ----------------------------------------------------------------------------
-- Hvorfor det ikke kommer en auditrad her
--
-- `knowledge.evidence_assessments` har ingen auditutløser i dag, og får ingen
-- her. Det er en avlesning og ikke en forglemmelse: auditvokabularet dekker de
-- objektene som kan bære en publisering *hver for seg* — kilden, kildeversjonen,
-- evidensfunnet, forankringen, kontrollene, reviewbeslutningene og
-- påstandsrevisjonen. Vurderingen er bundet til nøyaktig én revisjon
-- (`evidence_assessments_claim_revision_key`), er append-only
-- (`evidence_assessments_reject_mutation`) og bærer nå både aktør og kjøring.
-- Å innføre en auditoperasjon for den ville krevd to enumutvidelser og en ny
-- omskriving av de genererte kolonnene i `audit.events`, uten å gjøre noe
-- sporbart som ikke allerede er det. Føres som en egen vurdering hvis
-- vurderingen noen gang får flere skriveveier enn den ene.
--
-- Fremover-skrivende: ingen kjørt migrasjon er redigert.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §6, §8, §10, §14, §20
--   docs/DATABASE_ARCHITECTURE.md §22, §33, §57, §59, §60
--   docs/EVIDENCE_PIPELINE.md §34, §35, §61, §65
--   docs/KNOWLEDGE_MODEL.md §13
-- ============================================================================

alter table knowledge.evidence_assessments
  add column agent_run_id uuid,
  add column agent_run_role provenance.agent_role
    generated always as ('evidence_assessment'::provenance.agent_role) stored;

comment on column knowledge.evidence_assessments.agent_run_id is
  'Agentkjøringen vurderingen ble gjort i, eller NULL når den ikke kom av en agentkjøring. NULL er tilstanden til enhver vurdering en kvalifisert redaktør gjør selv, og betyr aldri at kjøringen er ukjent. Kjøringen bærer modell, modellversjon, promptmal og pipelineversjon (ANTIDEP_CONSTITUTION.md §20), og de sammensatte fremmednøklene håndhever at den tilhører nøyaktig den aktøren raden attribueres til, og er i rollen evidensvurdering.';
comment on column knowledge.evidence_assessments.agent_run_role is
  'Rollen en agentkjøring må ha for å kunne bære en evidensvurdering, som en generert konstant — samme form som på knowledge.claim_revisions og knowledge.evidence_items. Ikke en opplysning kalleren gir: den finnes bare som venstreside for den sammensatte fremmednøkkelen mot provenance.agent_runs (id, agent_role), slik at kravet om at vurderingen av evidenssikkerheten er et annet ansvar enn påstandsdannelsen, håndheves deklarativt (EVIDENCE_PIPELINE.md §61). Verdien er satt også når agent_run_id er NULL; fremmednøkkelen er MATCH SIMPLE og slår da av kravet.';

alter table knowledge.evidence_assessments
  add constraint evidence_assessments_agent_run_actor_fkey
    foreign key (agent_run_id, created_by_actor_id)
    references provenance.agent_runs (id, actor_id)
    on update restrict on delete restrict,
  add constraint evidence_assessments_agent_run_role_fkey
    foreign key (agent_run_id, agent_run_role)
    references provenance.agent_runs (id, agent_role)
    on update restrict on delete restrict;

create index evidence_assessments_agent_run_id_idx
  on knowledge.evidence_assessments (agent_run_id);
