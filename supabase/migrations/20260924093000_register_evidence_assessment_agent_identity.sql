-- ============================================================================
-- Migrasjon 005an — aktøren og identiteten til evidensvurderingsagenten
--
-- De fire agentleddene som har hatt en skrivevei, har hatt hver sin aktør siden
-- migrasjon 005: ekstraksjon, ekstraksjonskontroll, påstandsdannelse og
-- kildestøtteverifikasjon. Evidensvurderingen har ikke hatt noen, fordi ingen
-- vei skrev en vurdering: radene i migrasjon 004 ble lagt inn av migrasjonen
-- selv og attribuert til synteseaktøren, og migrasjon 005aj lot synteseveien
-- fortsette den attribusjonen.
--
-- Migrasjon 005am flytter vurderingen ut i sitt eget ledd. Denne migrasjonen gir
-- leddet en aktør og en identitet, slik at ansvarsgrensen i
-- EVIDENCE_PIPELINE.md §61 blir en teknisk grense og ikke et navn i en prompt.
--
-- ----------------------------------------------------------------------------
-- Identiteten er inert etter denne migrasjonen
--
-- secret_hash er NULL, og provenance.authenticate_agent_identity() avviser en
-- identitet uten utstedt legitimasjon. Å registrere en identitet og å gi den
-- evnen til å handle er to forskjellige handlinger, og denne migrasjonen gjør
-- bare den første — samme grep og samme begrunnelse som migrasjon 005f, 005w og
-- 005ak.
--
-- Legitimasjonen utstedes med `./scripts/issue-agent-credential.sh --identity
-- agent-identity:evidence-assessment-01 --env-prefix ANTIDEP_ASSESSMENT_AGENT` i
-- det miljøet kjøreren skal lese hemmeligheten fra. En hemmelighet generert av
-- en migrasjon måtte enten stått i repoet eller vært returnert gjennom en
-- agentsesjons logg; begge deler er utelukket (DATABASE_ARCHITECTURE.md §49).
--
-- ----------------------------------------------------------------------------
-- Hva denne identiteten kan, og hva den ikke kan
--
-- Rollen er rettighetsgrensen. `evidence_assessment` gir tilgang til
-- api.register_evidence_assessment(...) og ingenting annet:
--
--   * den kan ikke ekstrahere evidens, og ikke kontrollere en ekstraksjon
--   * den kan ikke formulere en påstand: api.register_claim_synthesis(...)
--     krever rollen claim_synthesis
--   * den kan ikke kontrollere påstanden den vurderer grunnlaget for:
--     claim-verifikasjonen krever rollen citation_support_verification
--   * den kan ikke registrere en reviewbeslutning eller publisere:
--     workflow.review_decisions krever en menneskelig aktør, deklarativt
--     håndhevet (ANTIDEP_CONSTITUTION.md §12, uendret)
--
-- Motsatt vei gjelder det samme: synteseidentiteten kan etter 005am ikke lenger
-- registrere en evidensvurdering. Det er hele poenget med denne migrasjonen.
--
-- Registreringen er attribuert til den navngitte kvalifiserte redaktøren, og
-- agent_identities_registered_by_human_check håndhever at den *må* peke på et
-- menneske: en agent som kunne registrere agenter, ville vært en
-- rettighetseskalering med ett ekstra ledd (CONTENT_GOVERNANCE.md §14).
-- ============================================================================

insert into provenance.actors (actor_type, actor_key, display_name, description, agent_role)
values (
  'agent',
  'agent:evidence-assessment',
  'Antidep evidensvurderingsagent',
  'KI-assistert prosess i evidensvurderingsrollen (EVIDENCE_PIPELINE.md §61, EvidenceAssessor). Registrerer den samlede vurderingen av sikkerheten i kunnskapsgrunnlaget for én påstandsrevisjon, gjennom api.register_evidence_assessment(...), etter at kildestøtteverifikasjonen har bekreftet påstanden (MVP_IMPLEMENTATION_PLAN.md §15). Aktøren er ny i migrasjon 005an: fram til migrasjon 005am ble vurderingen skrevet av synteseaktøren i den samme transaksjonen som påstanden, og ansvarsgrensen var dermed ingen teknisk grense. Vurderingene fra migrasjon 004 er fortsatt attribuert til agent:claim-synthesis, fordi de faktisk ble laget der; historikken skrives ikke om.',
  'evidence_assessment'
);

insert into provenance.agent_identities (
  actor_id,
  agent_role,
  identity_key,
  registered_by_actor_id,
  registered_by_actor_type,
  registration_reason
)
select
  assessor.id,
  'evidence_assessment'::provenance.agent_role,
  'agent-identity:evidence-assessment-01',
  editor.id,
  'human'::provenance.actor_type,
  'Den tekniske identiteten evidensvurderingsagenten handler med. EVIDENCE_PIPELINE.md §61 skiller EvidenceAssessor fra ClaimAgent og krever at ansvarsgrensen samtidig er en teknisk grense: egen aktør, egen identitet, egen legitimasjon. Fram til migrasjon 005am skrev synteseveien api.register_claim_synthesis(...) både påstanden, evidenslenkene og den endelige GRADE-vurderingen i én transaksjon, med samme aktør og samme legitimasjon, og skillet var dermed bare et navn. 005am tok vurderingen ut i api.register_evidence_assessment(...), som autentiserer for rollen evidence_assessment og krever at kildestøtteverifikasjonen er bekreftet først (MVP_IMPLEMENTATION_PLAN.md §15); denne raden gir den veien legitimasjonsmodellen den autentiserer mot. Rollen er evidence_assessment og ingen annen: identiteten kan verken ekstrahere evidens, kontrollere en ekstraksjon, formulere en påstand, kontrollere påstanden den vurderer grunnlaget for, eller registrere en faglig beslutning — den siste er dessuten forbeholdt mennesker av ANTIDEP_CONSTITUTION.md §12, uendret. Legitimasjon er ikke utstedt: identiteten er inert til provenance.issue_agent_identity_credential(text, text) kalles i det miljøet kjøreren skal lese hemmeligheten fra.'
from
  (select id from provenance.actors where actor_key = 'agent:evidence-assessment') as assessor,
  (select id from provenance.actors where actor_key = 'human:peder-holman') as editor;

-- Registreringen skal ikke kunne bli en stille no-op om et av de to
-- aktøroppslagene svikter: en tom krysskobling ville satt inn null rader uten å
-- feile, og identiteten ville manglet uten at noe sa fra. Samme resonnement som
-- migrasjon 005f, 005w og 005ak.
do $$
begin
  if not exists (
    select 1 from provenance.agent_identities
    where identity_key = 'agent-identity:evidence-assessment-01'
  ) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Agentidentiteten agent-identity:evidence-assessment-01 ble ikke registrert.',
      hint = 'Registreringen forutsetter at både agent:evidence-assessment og human:peder-holman finnes som aktører. Kontroller at migrasjon 005a og denne migrasjonens egen aktørinnsetting har kjørt.';
  end if;
end;
$$;
