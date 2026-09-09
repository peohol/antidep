-- ============================================================================
-- Migrasjon 005z — kjøringen sier hvilken kildeversjon den leste, og
--                  ekstraksjonen bindes deklarativt til nettopp den
--
-- Migrasjon 007g bandt evidensfunnet til den kjøringen som produserte det.
-- Kjøringen sa likevel ingenting strukturert om hva den hadde lest: adressen,
-- fingeravtrykket og kildeversjonen lå i `input_manifest`, som er fri jsonb.
-- En kjøring kunne dermed åpnes for én kildeversjon og registrere en
-- ekstraksjon mot en helt annen, uten at noe i basen protesterte.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en kolonne og ikke en nøkkel i input_manifest
--
-- `input_manifest` er dokumentasjon av hva kjøringen fikk (DATABASE_ARCHITECTURE.md
-- §33), skrevet av klienten. En regel som leste en nøkkel derfra, ville vært en
-- regel som stolte på en klientkonvensjon — nøyaktig den formen for kobling
-- som ikke tåler at noen skriver en annen nøkkel, eller ingen.
--
-- `input_source_version_id` er derfor en egen kolonne med sin egen
-- fremmednøkkel, og koblingen til ekstraksjonen er en **sammensatt
-- fremmednøkkel**, ikke en kontroll i en funksjonskropp:
--
--   knowledge.evidence_items (agent_run_id, source_version_id)
--     → provenance.agent_runs (id, input_source_version_id)
--
-- Da kan et agentgenerert evidensfunn ikke peke på en annen kildeversjon enn
-- den kjøringen ble åpnet for. Ingen trigger kan glemmes, og ingen skrivevei
-- kan omgå den.
--
-- ----------------------------------------------------------------------------
-- Hvorfor kolonnen er nullbar, og hvor den likevel er påkrevd
--
-- Verifikatorkjøringene leser en arbeidskø, ikke én kildeversjon, og en kolonne
-- de måtte fylle ut ville vært en opplysning uten innhold. NULL betyr «denne
-- kjøringen er ikke åpnet for én bestemt kildeversjon» — aldri «ukjent».
--
-- `api.begin_agent_run` krever den for rollen `evidence_extraction`, og bare
-- der. En ekstraksjonskjøring uten en kildeversjon å lese er ikke en
-- ekstraksjonskjøring.
--
-- MATCH SIMPLE gjør at den sammensatte fremmednøkkelen ikke gjelder når én av
-- kolonnene er NULL. Det er riktig her: et funn uten agentkjøring (editorveien,
-- og alt fra før 007g) har ingen kjøring å bindes til.
--
-- ----------------------------------------------------------------------------
-- Hva som IKKE endres
--
-- Ingen CHECK, policy eller grant er fjernet eller svekket, og
-- `input_manifest` beholder sitt innhold — den er fortsatt dokumentasjonen av
-- hva kjøringen fikk. Den er bare ikke lenger det eneste som binder
-- ekstraksjonen til kilden.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §8, §10, §20
--   docs/DATABASE_ARCHITECTURE.md §33, §43, §50, §57
--   docs/EVIDENCE_PIPELINE.md §21
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Kjøringen får kildeversjonen den ble åpnet for
-- ----------------------------------------------------------------------------
alter table provenance.agent_runs
  add column input_source_version_id uuid
    references knowledge.source_versions (id)
    on update restrict on delete restrict;

comment on column provenance.agent_runs.input_source_version_id is
  'Kildeversjonen kjøringen ble åpnet for å lese. NULL betyr at kjøringen ikke er åpnet for én bestemt kildeversjon — verifikatorkjøringene leser en arbeidskø — aldri at kildeversjonen er ukjent. Påkrevd av api.begin_agent_run for rollen evidence_extraction, og bare der. Egen kolonne og ikke en nøkkel i input_manifest, fordi koblingen håndheves deklarativt: evidence_items_agent_run_source_version_fkey gjør det umulig for et agentgenerert evidensfunn å peke på en annen kildeversjon enn den kjøringen ble åpnet for (DATABASE_ARCHITECTURE.md §33, §57).';

-- Målet for den sammensatte fremmednøkkelen. `id` er allerede primærnøkkel, så
-- unikheten er triviell; constrainten finnes for at paret skal kunne refereres.
alter table provenance.agent_runs
  add constraint agent_runs_id_input_source_version_key
  unique (id, input_source_version_id);

create index agent_runs_input_source_version_id_idx
  on provenance.agent_runs (input_source_version_id);

-- ----------------------------------------------------------------------------
-- 2. Ekstraksjonen bindes til kjøringens egen kildeversjon
-- ----------------------------------------------------------------------------
alter table knowledge.evidence_items
  add constraint evidence_items_agent_run_source_version_fkey
  foreign key (agent_run_id, source_version_id)
  references provenance.agent_runs (id, input_source_version_id)
  on update restrict on delete restrict;

-- ----------------------------------------------------------------------------
-- 3. api.begin_agent_run tar imot kildeversjonen
--
-- Slippes og lages på nytt framfor å få en overload: en ny parameter med
-- standardverdi ville laget en *ny* funksjon ved siden av den gamle, og
-- PostgREST ville da valgt kandidat ut fra hvilke argumenter klienten
-- tilfeldigvis sendte — altså ut fra klienten og ikke kontrakten.
-- ----------------------------------------------------------------------------
drop function api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb);

create function api.begin_agent_run(
  p_identity_key text,
  p_secret text,
  p_agent_role text,
  p_provider text,
  p_model text,
  p_model_version text,
  p_prompt_template_version text,
  p_pipeline_version text,
  p_input_manifest jsonb,
  -- Kildeversjonen kjøringen skal lese. Påkrevd for evidence_extraction, uten
  -- betydning for de øvrige rollene.
  p_input_source_version_id uuid default null
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_role provenance.agent_role;
  v_identity_id uuid;
  v_actor_id uuid;
  v_run_id uuid;
begin
  -- Casten skjer først og for seg selv, slik at en ukjent rolle gir en setning
  -- som sier hva som er galt. Vokabularet er offentlig dokumentert
  -- (ANTIDEP_CONSTITUTION.md §10, EVIDENCE_PIPELINE.md §61), så meldingen røper
  -- ingenting autentiseringen skjuler.
  begin
    v_role := p_agent_role::provenance.agent_role;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent agentrolle.', p_agent_role),
        hint = 'Gyldige roller er de eksplisitte agentrollene i ANTIDEP_CONSTITUTION.md §10 og EVIDENCE_PIPELINE.md §61.';
  end;

  v_identity_id := provenance.authenticate_agent_identity(p_identity_key, p_secret, v_role);

  -- Etter autentiseringen: en melding om manglende kildeversjon skal ikke
  -- kunne leses av noen uten gyldig legitimasjon.
  if v_role = 'evidence_extraction' and p_input_source_version_id is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'En ekstraksjonskjøring må åpnes for den kildeversjonen den skal lese.',
      hint = 'Oppgi p_input_source_version_id. Evidensfunnet kjøringen registrerer, bindes deklarativt til nettopp den kildeversjonen (evidence_items_agent_run_source_version_fkey, migrasjon 005z), slik at en kjøring ikke kan lese én utgave og registrere en annen.';
  end if;

  select ai.actor_id into v_actor_id
  from provenance.agent_identities ai
  where ai.id = v_identity_id;

  insert into provenance.agent_runs (
    agent_identity_id, actor_id, agent_role,
    provider, model, model_version, prompt_template_version, pipeline_version,
    status, input_manifest, input_source_version_id
  )
  values (
    v_identity_id, v_actor_id, v_role,
    p_provider, p_model, p_model_version, p_prompt_template_version, p_pipeline_version,
    'running', p_input_manifest, p_input_source_version_id
  )
  returning id into v_run_id;

  return v_run_id;
end;
$$;

comment on function api.begin_agent_run(
  text, text, text, text, text, text, text, text, jsonb, uuid
) is
  'Åpner en agentkjøring og registrerer premissene den skal kunne rekonstrueres fra: leverandør, modell, modellversjon, promptmalversjon og pipelineversjon (ANTIDEP_CONSTITUTION.md §20). Autentiserer legitimasjonen eksplisitt for den oppgitte rollen; aktøren kjøringen attribueres til, er identitetens egen og er ikke en parameter. p_input_source_version_id sier hvilken kildeversjon kjøringen skal lese, og er påkrevd for rollen evidence_extraction: evidensfunnet kjøringen registrerer, bindes deklarativt til nettopp den (migrasjon 005z). De øvrige rollene leser en arbeidskø og lar den stå NULL. Erstatter signaturen fra migrasjon 005e, som er sluppet: en overload ville latt klienten og ikke kontrakten avgjøre hvilken funksjon PostgREST kaller. SECURITY DEFINER fordi provenance har RLS med default deny; tomt search_path. EXECUTE går til anon og authenticated av samme grunn som de øvrige agentendepunktene: en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

revoke execute on function api.begin_agent_run(
  text, text, text, text, text, text, text, text, jsonb, uuid
) from public;
grant execute on function api.begin_agent_run(
  text, text, text, text, text, text, text, text, jsonb, uuid
) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. Kommentarene som navngir den gamle signaturen
--
-- To kommentarer navngir api.begin_agent_run med full signatur, og signaturen
-- er nettopp byttet. En kommentar som navngir en funksjon som ikke finnes, er
-- en kommentar som lyver — det er nøyaktig det vakten i
-- supabase/tests/280_content_hash_serialization_test.sql finnes for å fange.
--
-- Innholdet er ordrett det samme; bare signaturen er den nye. Kommentarene
-- erstattes her framfor i migrasjonene som skrev dem, som allerede er kjørt i
-- det hostede prosjektet (§74.32).
-- ----------------------------------------------------------------------------
comment on function api.complete_agent_run(text, text, uuid, text, jsonb, text) is
  'Avslutter en agentkjøring med et endelig utfall og et outputmanifest, eller med en begrunnelse for at den feilet eller ble stoppet. Rollen autentiseringen krever, hentes fra kjøringen selv og oppgis ikke av kalleren. Overgangen kan bare skje én gang og bare fra running; provenance.freeze_agent_run() håndhever det, og en avsluttet kjøring kan verken gjenåpnes eller omskrives. Hvilke felter som må være satt for hvilken status, håndheves av agent_runs_status_shape_check, og avvisningen derfra propageres uendret. Samme SECURITY DEFINER-form og samme grants som api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb, uuid).';

comment on function api.register_extraction_verification(
  text, text, uuid, uuid, text, text, text[], text, text
) is
  'Den kontrollerte skriveveien for at en autentisert ekstraksjonsverifikator registrerer en kontroll av ett EvidenceItem mot kildematerialet (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29, §43). Autentiserer identiteten eksplisitt for rollen extraction_verification (avviser enhver annen rolle), krever en åpen agentkjøring i samme rolle som tilhører samme identitet (provenance.assert_agent_run_open(uuid, uuid), som tar radlås på kjøringen — se den funksjonens kommentar), og attribuerer raden til den aktøren kjøringen faktisk tilhører — verken aktør, rolle eller kjøring er parametre kalleren kan oppgi fritt. verified_item_creator_actor_id leses fra evidensfunnet selv, ikke fra kalleren. verified_at settes til now(): denne veien registrerer alltid kontrollen i det den konkluderes. p_source_access = ''verifiable_representation'' avvises eksplisitt når evidensfunnets source_version_id er NULL, eller når kildeversjonen den peker på ikke selv har content_hash satt (§74.30 punkt 1/2): retrieved_from og content_hash sammen er det som gjør en kildeversjon etterprøvbar for en tredjepart, og uten begge ville raden vært en påstand uten grunnlag. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi workflow.evidence_verifications, provenance.agent_runs og provenance.agent_identities har RLS med default deny; tomt search_path, og kalleren autentiseres på funksjonens eget kall (§50). EXECUTE går til anon og authenticated av samme grunn som api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb, uuid) og api.complete_agent_run(text, text, uuid, text, jsonb, text) (migrasjon 005e): en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen. Utover vokabularcastene og source_version-sjekken er ingen feltvalidering duplisert her: evidence_verifications_separate_actor_check, evidence_verifications_source_access_check og de øvrige constraintene på tabellen (migrasjon 005) er fasiten, og deres avvisninger propageres uendret — inkludert at en agent aldri kan verifisere sitt eget arbeid.';

comment on function api.extraction_verification_input(text,text,uuid,uuid) is
  'Lesegrunnlaget en autentisert ekstraksjonsverifikator arbeider fra (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §43, MVP_IMPLEMENTATION_PLAN.md §15). Autentiserer identiteten eksplisitt for rollen extraction_verification og krever en åpen agentkjøring som tilhører den (provenance.assert_agent_run_open(uuid, uuid)); uten begge deler returneres ingenting, og avvisningen er den samme som for enhver mislykket agentautentisering. Uten p_evidence_item_id svarer den med arbeidskøen: evidensfunn aktøren ikke selv har laget og ikke selv har kontrollert. Med p_evidence_item_id svarer den om nøyaktig det funnet, også et allerede kontrollert. Svaret er et jsonb-objekt med agent_run_id, verifier_actor_id og items, der hvert element har evidensfunnets identitet og opphav, kilden, kildeversjonen (eller null når ingen er registrert, med retrieved_from og content_hash når den finnes) og hele ekstraksjonen ordrett, inkludert raw_extraction og source_locator. storage_reference er ikke eksponert, bare om den finnes. SECURITY DEFINER fordi knowledge, catalog, provenance og workflow har RLS med default deny; tomt search_path, og kalleren autentiseres på funksjonens eget kall (§50). EXECUTE går til anon og authenticated av samme grunn som api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb, uuid): en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

comment on function api.claim_verification_input(text,text,uuid,uuid) is
  'Lesegrunnlaget en autentisert claim-verifikator arbeider fra (ANTIDEP_CONSTITUTION.md §4, §9, §11, EVIDENCE_PIPELINE.md §39, DATABASE_ARCHITECTURE.md §30, §43). Autentiserer identiteten eksplisitt for rollen citation_support_verification og krever en åpen agentkjøring som tilhører den (provenance.assert_agent_run_open(uuid, uuid)); uten begge deler returneres ingenting, og avvisningen er den samme som for enhver mislykket agentautentisering. Uten p_claim_revision_id svarer den med arbeidskøen: påstandsrevisjoner aktøren ikke selv har formulert, ikke selv har kontrollert, og som har minst én evidenslenke. Med p_claim_revision_id svarer den om nøyaktig den revisjonen, også en allerede kontrollert. Svaret er et jsonb-objekt med agent_run_id, verifier_actor_id og revisions, der hver revisjon har påstanden i sin helhet, evidenssettets avtrykk, hver evidenslenke med relasjonstype, begrunnelse, hele evidensfunnet ordrett, kildeversjonens adresse og fingeravtrykk og den gjeldende ekstraksjonsverifikasjonen for funnet, samt unlinked_related_evidence: registrerte evidensfunn for samme virkestoff og endepunkt som ikke er lenket til revisjonen. Den siste lista er det som gjør DATABASE_ARCHITECTURE.md §30 sitt spørsmål om urepresentert motstridende evidens besvarbart i det hele tatt — men den er evidens Antidep har registrert, ikke evidensen som finnes: en tom liste betyr aldri at det ikke finnes motstridende forskning (ANTIDEP_CONSTITUTION.md §17). storage_reference er ikke eksponert, bare om den finnes. SECURITY DEFINER fordi knowledge, catalog, provenance og workflow har RLS med default deny; tomt search_path, og kalleren autentiseres på funksjonens eget kall (§50). EXECUTE går til anon og authenticated av samme grunn som api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb, uuid): en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen.';

comment on function api.register_claim_verification(text,text,uuid,uuid,text,text,text,text,text,text,text,text,jsonb,text,text) is
  'Den kontrollerte skriveveien for at en autentisert claim-verifikator registrerer en kontroll av én påstandsrevisjon mot det registrerte evidensgrunnlaget (ANTIDEP_CONSTITUTION.md §4, §9, §11, DATABASE_ARCHITECTURE.md §30, §43, EVIDENCE_PIPELINE.md §39-§41). Autentiserer identiteten eksplisitt for rollen citation_support_verification (avviser enhver annen rolle, også extraction_verification), krever en åpen agentkjøring i samme rolle som tilhører samme identitet (provenance.assert_agent_run_open(uuid, uuid), som tar radlås på kjøringen), og attribuerer raden til den aktøren kjøringen faktisk tilhører — verken aktør, rolle eller kjøring er parametre kalleren kan oppgi fritt. verified_revision_creator_actor_id leses fra revisjonen selv, verified_evidence_set_digest beregnes av databasen, og source_access utledes som den svakeste kildetilgangen blant de kontrollerte lenkene, slik at en samlet påstand aldri blir sterkere enn det svakeste leddet den hviler på. p_citations er én rad per evidenslenke som ble kontrollert, med claim_evidence_link_id, source_access og relationship_supported, og eventuelt source_version_id, checked_content_hash og finding; evidensfunnet leses fra lenken. Kontrollen må dekke hele evidenssettet til revisjonen, og en bekreftelse kan ikke ha uavklarte lenker under seg — workflow.assert_claim_verification_complete(uuid) kalles på slutten av kallet og håndheves i tillegg av en constraint-trigger ved commit. verified_at settes til now(): denne veien registrerer alltid kontrollen i det den konkluderes. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi workflow, knowledge og provenance har RLS med default deny; tomt search_path, og kalleren autentiseres på funksjonens eget kall (§50). EXECUTE går til anon og authenticated av samme grunn som api.begin_agent_run(text, text, text, text, text, text, text, text, jsonb, uuid): en agent har ingen brukerkonto, og det er legitimasjonen og ikke Data API-rollen som er kontrollen. Utover vokabularcastene og lenkekontrollen er ingen feltvalidering duplisert her: constraintene på workflow.claim_verifications og workflow.claim_verification_citations er fasiten, og deres avvisninger propageres uendret — inkludert at en agent aldri kan verifisere sin egen påstand, og at en aktør uten mandat ikke kan registrere raden i det hele tatt.';
