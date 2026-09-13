-- ============================================================================
-- Migrasjon 005ak — den tekniske identiteten til synteseagenten
--
-- Aktøren `agent:claim-synthesis` har eksistert siden migrasjon 005 (§22), og
-- rollen `claim_synthesis` siden det samme vokabularet ble laget. Det som har
-- manglet, er identiteten den kan *handle* med — og fram til migrasjon 005aj
-- fantes det ingenting å handle med den: påstandsdannelsen hadde ingen
-- skrivevei.
--
-- 005aj ga rollen skriveveien. Denne migrasjonen gir den en identitet.
--
-- ----------------------------------------------------------------------------
-- Identiteten er inert etter denne migrasjonen
--
-- secret_hash er NULL, og provenance.authenticate_agent_identity() avviser en
-- identitet uten utstedt legitimasjon. Å registrere en identitet og å gi den
-- evnen til å handle er to forskjellige handlinger, og denne migrasjonen gjør
-- bare den første — samme grep og samme begrunnelse som migrasjon 005f og 005w.
--
-- Legitimasjonen utstedes med `./scripts/issue-agent-credential.sh --identity
-- agent-identity:claim-synthesis-01 --env-prefix ANTIDEP_SYNTHESIS_AGENT` i det
-- miljøet kjøreren skal lese hemmeligheten fra. En hemmelighet generert av en
-- migrasjon måtte enten stått i repoet eller vært returnert gjennom en
-- agentsesjons logg; begge deler er utelukket (DATABASE_ARCHITECTURE.md §49).
--
-- ----------------------------------------------------------------------------
-- Hva denne identiteten kan, og hva den ikke kan
--
-- Rollen er rettighetsgrensen. `claim_synthesis` gir tilgang til
-- api.register_claim_synthesis(...) og ingenting annet:
--
--   * den kan ikke ekstrahere evidens, og ikke kontrollere en ekstraksjon
--   * den kan ikke kontrollere påstanden sin egen: claim-verifikasjonen krever
--     rollen citation_support_verification, og
--     claim_verifications_separate_actor_check ville uansett stoppet den
--   * den kan ikke registrere en reviewbeslutning eller publisere:
--     workflow.review_decisions krever en menneskelig aktør, deklarativt
--     håndhevet (ANTIDEP_CONSTITUTION.md §12, uendret)
--
-- Generering og verifikasjon er dermed atskilte operasjoner i tre identiteter
-- med hver sin rolle, slik §10 og §11 krever.
--
-- Registreringen er attribuert til den navngitte kvalifiserte redaktøren, og
-- agent_identities_registered_by_human_check håndhever at den *må* peke på et
-- menneske: en agent som kunne registrere agenter, ville vært en
-- rettighetseskalering med ett ekstra ledd (CONTENT_GOVERNANCE.md §14).
-- ============================================================================

insert into provenance.agent_identities (
  actor_id,
  agent_role,
  identity_key,
  registered_by_actor_id,
  registered_by_actor_type,
  registration_reason
)
select
  synthesiser.id,
  'claim_synthesis'::provenance.agent_role,
  'agent-identity:claim-synthesis-01',
  editor.id,
  'human'::provenance.actor_type,
  'Den tekniske identiteten synteseagenten handler med. Aktøren agent:claim-synthesis har eksistert siden migrasjon 005, men uten en identitet har den vært en attribusjon uten en vei inn, og påstandsdannelsen har vært det ene leddet i kjeden uten en operativ skrivevei: de påstandene som har stått i basen, ble lagt inn av migrasjon 004 selv. Migrasjon 005aj ga rollen skriveveien api.register_claim_synthesis(...), som krever at hvert lenket evidensfunn har nådd kontrollnivået EVIDENCE_PIPELINE.md §26 og §27 krever, og som skriver påstand, revisjon, evidenslenker og evidensvurdering i én transaksjon; denne raden gir den legitimasjonsmodellen den veien autentiserer mot. Rollen er claim_synthesis og ingen annen: identiteten kan verken ekstrahere evidens, kontrollere en ekstraksjon, kontrollere sin egen påstand eller registrere en faglig beslutning — den siste er dessuten forbeholdt mennesker av ANTIDEP_CONSTITUTION.md §12, uendret. Legitimasjon er ikke utstedt: identiteten er inert til provenance.issue_agent_identity_credential(text, text) kalles i det miljøet kjøreren skal lese hemmeligheten fra.'
from
  (select id from provenance.actors where actor_key = 'agent:claim-synthesis') as synthesiser,
  (select id from provenance.actors where actor_key = 'human:peder-holman') as editor;

-- Registreringen skal ikke kunne bli en stille no-op om et av de to
-- aktøroppslagene svikter: en tom krysskobling ville satt inn null rader uten å
-- feile, og identiteten ville manglet uten at noe sa fra. Samme resonnement som
-- migrasjon 005f og 005w.
do $$
begin
  if not exists (
    select 1 from provenance.agent_identities
    where identity_key = 'agent-identity:claim-synthesis-01'
  ) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Agentidentiteten agent-identity:claim-synthesis-01 ble ikke registrert.',
      hint = 'Registreringen forutsetter at både agent:claim-synthesis og human:peder-holman finnes som aktører. Kontroller at migrasjon 005 og 005a har kjørt.';
  end if;
end;
$$;
