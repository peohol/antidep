-- ============================================================================
-- Migrasjon 005w — den tekniske identiteten til ekstraksjonsagenten
--
-- Aktøren `agent:evidence-extraction` har eksistert siden migrasjon 005 (§22):
-- den er allerede oppført som opphav på de seedede evidensfunnene. Det som har
-- manglet, er identiteten den kan *handle* med. Fram til nå har alle
-- ekstraksjoner måttet gå gjennom editorens skjema, og aktøren har vært en
-- attribusjon uten en vei inn.
--
-- Migrasjon 005v ga rollen en skrivevei. Denne migrasjonen gir den en identitet.
--
-- ----------------------------------------------------------------------------
-- Identiteten er inert etter denne migrasjonen
--
-- secret_hash er NULL, og provenance.authenticate_agent_identity() avviser en
-- identitet uten utstedt legitimasjon. Å registrere en identitet og å gi den
-- evnen til å handle er to forskjellige handlinger, og denne migrasjonen gjør
-- bare den første — samme grep og samme begrunnelse som migrasjon 005f.
--
-- Legitimasjonen utstedes med ett kall til
-- provenance.issue_agent_identity_credential(text, text) i det miljøet kjøreren
-- skal lese hemmeligheten fra. En hemmelighet generert av en migrasjon måtte
-- enten stått i repoet eller vært returnert gjennom en agentsesjons logg; begge
-- deler er utelukket (DATABASE_ARCHITECTURE.md §49).
--
-- ----------------------------------------------------------------------------
-- Hva denne identiteten kan, og hva den ikke kan
--
-- Rollen er rettighetsgrensen. `evidence_extraction` gir tilgang til
-- api.register_agent_extraction(...) og ingenting annet:
--
--   * den kan ikke kontrollere en ekstraksjon — heller ikke sin egen, som
--     evidence_verifications_separate_actor_check uansett ville stoppet, men
--     her stopper allerede autentiseringen den
--   * den kan ikke registrere en claim-verifikasjon
--   * den kan ikke registrere en reviewbeslutning: workflow.review_decisions
--     krever en menneskelig aktør, deklarativt håndhevet
--     (ANTIDEP_CONSTITUTION.md §12, uendret)
--
-- Generering og verifikasjon er dermed atskilte operasjoner i to identiteter med
-- hver sin rolle, slik §10 og §11 krever.
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
  extractor.id,
  'evidence_extraction'::provenance.agent_role,
  'agent-identity:evidence-extraction-01',
  editor.id,
  'human'::provenance.actor_type,
  'Den tekniske identiteten ekstraksjonsagenten handler med. Aktøren agent:evidence-extraction har eksistert siden migrasjon 005, men uten en identitet har den vært en attribusjon uten en vei inn, og hver ekstraksjon har måttet gå gjennom editorens skjema. Migrasjon 005v ga rollen skriveveien api.register_agent_extraction(...), som krever komplett kildeforankring per felt og en kildeversjon med registrert representasjonstype; denne raden gir den legitimasjonsmodellen den veien autentiserer mot. Rollen er evidence_extraction og ingen annen: identiteten kan verken kontrollere en ekstraksjon, verifisere en påstand eller registrere en faglig beslutning — den siste er dessuten forbeholdt mennesker av ANTIDEP_CONSTITUTION.md §12, uendret. Legitimasjon er ikke utstedt: identiteten er inert til provenance.issue_agent_identity_credential(text, text) kalles i det miljøet kjøreren skal lese hemmeligheten fra.'
from
  (select id from provenance.actors where actor_key = 'agent:evidence-extraction') as extractor,
  (select id from provenance.actors where actor_key = 'human:peder-holman') as editor;

-- Registreringen skal ikke kunne bli en stille no-op om et av de to
-- aktøroppslagene svikter: en tom krysskobling ville satt inn null rader uten å
-- feile, og identiteten ville manglet uten at noe sa fra. Samme resonnement som
-- migrasjon 005f.
do $$
begin
  if not exists (
    select 1 from provenance.agent_identities
    where identity_key = 'agent-identity:evidence-extraction-01'
  ) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Agentidentiteten agent-identity:evidence-extraction-01 ble ikke registrert.',
      hint = 'Registreringen forutsetter at både agent:evidence-extraction og human:peder-holman finnes som aktører. Kontroller at migrasjon 005 og 005a har kjørt.';
  end if;
end;
$$;
