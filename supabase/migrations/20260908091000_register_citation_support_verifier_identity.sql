-- ============================================================================
-- Migrasjon 005i — den andre agentidentiteten: claim-verifikatoren
--
-- Utvider aktørregisteret fra migrasjon 005 (§22) og identitetsmodellen fra
-- 005e, og står utenfor den planlagte rekken i MVP_IMPLEMENTATION_PLAN.md
-- §18-§27. Nummeret 009 er fortsatt reservert for DrugProduct-/importfundamentet
-- (§26).
--
-- ----------------------------------------------------------------------------
-- Hvorfor dette er en ny aktør og ikke ekstraksjonsverifikatoren om igjen
--
-- EVIDENCE_PIPELINE.md §61 skiller de to leddene på input, output og mandat:
--
--   ExtractionVerifier   kilde + EvidenceItem  → verifikasjonsrapport
--   CitationVerifier     påstand + evidens     → validerte relasjonstyper
--
-- Den ene kontrollerer at ekstraksjonen gjengir kilden riktig
-- (workflow.evidence_verifications); den andre at evidensen faktisk støtter
-- påstanden slik den er formulert (workflow.claim_verifications, §39). Rollen er
-- rettighetsgrensen (migrasjon 005e), så to mandater krever to aktører — ellers
-- ville én legitimasjon kunnet gjøre begge, og least privilege per pipelineledd
-- (MVP_IMPLEMENTATION_PLAN.md §49) ville vært et navn uten virkning.
--
-- Verdien `citation_support_verification` finnes allerede i
-- provenance.agent_role fra migrasjon 005: den er en av de sju
-- ANTIDEP_CONSTITUTION.md §10 krever. Ingen ny enum-verdi trengs, og migrasjonen
-- kan derfor gjøre både aktøren og identiteten i samme fil.
--
-- ----------------------------------------------------------------------------
-- Hvorfor denne aktøren aldri kan verifisere sin egen påstand
--
-- workflow.claim_verifications krever at verifikatoren er en *annen* aktør enn
-- den som formulerte revisjonen (claim_verifications_separate_actor_check,
-- migrasjon 005). Avlest mot de to påstandsrevisjonene som finnes i produksjon:
-- begge er formulert av `agent:claim-synthesis`, som er en annen aktør med en
-- annen rolle. Denne identiteten har rollen citation_support_verification og
-- ingen annen, så provenance.authenticate_agent_identity() avviser den for
-- enhver ekstraksjons-, syntese- eller kildeoperasjon — og den kan i det hele
-- tatt ikke formulere en påstand, som er nettopp det som gjør at den kan
-- kontrollere alle.
--
-- ----------------------------------------------------------------------------
-- Identiteten er inert etter denne migrasjonen
--
-- secret_hash er NULL, og provenance.authenticate_agent_identity() avviser en
-- identitet uten utstedt legitimasjon. Utstedelsen hører til det miljøet
-- kjøreren faktisk leser hemmeligheten fra, og gjøres med
-- ./scripts/issue-agent-credential.sh — se migrasjon 005f for hvorfor en
-- migrasjon aldri skal generere en hemmelighet (§74.31).
--
-- Løpenummeret `-01` har samme begrunnelse som i 005f: et andre uavhengig
-- kontrollag er en andre aktør med samme rolle, sin egen identitet og sin egen
-- kjøring — ikke en ny rolle og ikke en ny legitimasjon på den samme identiteten.
--
-- Registreringen er attribuert til den navngitte redaktøren, og
-- agent_identities_registered_by_human_check håndhever at den *må* peke på et
-- menneske: en agent som kunne registrere agenter, ville vært en
-- rettighetseskalering med ett ekstra ledd (CONTENT_GOVERNANCE.md §14).
-- ============================================================================

insert into provenance.actors (actor_type, actor_key, display_name, description, agent_role)
values (
  'agent',
  'agent:citation-support-verification',
  'Antidep claim-verifikator',
  'KI-prosess i rollen som kontrollerer om det registrerte evidensgrunnlaget faktisk støtter en påstandsrevisjon slik den er formulert (EVIDENCE_PIPELINE.md §39-§41, ANTIDEP_CONSTITUTION.md §11). Kontrollerer påstander andre aktører har formulert, mot de faktisk koblede evidensfunnene og deres etterprøvbare kilderepresentasjon, og kan aldri kontrollere en påstand den selv står bak: workflow.claim_verifications avviser en verifikasjon der verifikator og forfatter er samme aktør. Rollen er samtidig rettighetsgrensen — aktøren har ingen syntese-, ekstraksjons- eller kilderolle, og kan derfor verken formulere påstander, registrere evidensfunn eller opprette kilder. Kjører med sin egen tekniske identitet (provenance.agent_identities), ikke med en brukerkonto og ikke med service_role.',
  'citation_support_verification'
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
  verifier.id,
  'citation_support_verification'::provenance.agent_role,
  'agent-identity:citation-support-verification-01',
  editor.id,
  'human'::provenance.actor_type,
  'Andre tekniske agentidentitet i Antidep, registrert for at claim-verifikasjonen (MVP_IMPLEMENTATION_PLAN.md §15, ledd 7) skal kunne utføres av en separat KI-verifikator med sitt eget mandat, atskilt fra både den som formulerer påstanden og den som kontrollerer ekstraksjonen (EVIDENCE_PIPELINE.md §61). Identiteten har rollen citation_support_verification og ingen annen, og kan derfor verken registrere evidensfunn, formulere påstander eller registrere en faglig godkjenning — den siste er dessuten forbeholdt mennesker av ANTIDEP_CONSTITUTION.md §12, uendret. Legitimasjon er ikke utstedt: identiteten er inert til provenance.issue_agent_identity_credential(text, text) kalles i det miljøet kjøreren skal lese hemmeligheten fra.'
from
  (select id from provenance.actors where actor_key = 'agent:citation-support-verification') as verifier,
  (select id from provenance.actors where actor_key = 'human:peder-holman') as editor;

-- Registreringen skal ikke kunne bli en stille no-op om et av aktøroppslagene
-- svikter: en tom krysskobling ville satt inn null rader uten å feile, og
-- identiteten ville manglet uten at noe sa fra. Samme resonnement som 005c og
-- 005f.
do $$
begin
  if not exists (
    select 1 from provenance.agent_identities
    where identity_key = 'agent-identity:citation-support-verification-01'
  ) then
    raise exception using
      errcode = 'no_data_found',
      message = 'Agentidentiteten agent-identity:citation-support-verification-01 ble ikke registrert.',
      hint = 'Registreringen forutsetter at både agent:citation-support-verification og human:peder-holman finnes som aktører. Kontroller at migrasjon 005a har kjørt.';
  end if;
end;
$$;
