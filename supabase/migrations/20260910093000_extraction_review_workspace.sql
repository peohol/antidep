-- ============================================================================
-- Migrasjon 005t — arbeidsflaten den menneskelige ekstraksjonskontrollen gjøres fra
--
-- Speilbildet av migrasjon 005o for evidensfunn. ANTIDEP_CONSTITUTION.md §15
-- krever at en kvalifisert redaktør kan korrigere og kontrollere ekstraksjoner
-- uten Claude, ChatGPT eller direkte databaseinngrep. Skriveveien finnes fra
-- 005s. Denne migrasjonen gir den noe å arbeide fra: alt en reviewer trenger for
-- å kunne kontrollere ekstraksjonen mot kilden, og for å kunne si presist hvilke
-- felter kontrollen faktisk dekket.
--
-- ----------------------------------------------------------------------------
-- Grunnlaget er den samme funksjonen agenten leser
--
-- Selve evidensfunnet med kilden, kildeversjonen og hele ekstraksjonen er
-- nøyaktig den formen workflow.evidence_extraction_dossier(uuid) bygger
-- (migrasjon 005r), altså det samme uttrykket
-- api.extraction_verification_input(...) leverer til den deterministiske
-- verifikatoren. Mennesket og maskinen ser dermed det samme bildet av kilden.
--
-- Det denne funksjonen legger til, er det bare et menneske trenger:
-- kontrollhistorikken, avtrykket vurderingen bindes til, hvilke felter funnet
-- påstår noe om, hvilke som per nå teller som kontrollert, og hvilke
-- påstandsrevisjoner funnet allerede bærer.
--
-- ----------------------------------------------------------------------------
-- Dekningen leses av gatens egen funksjon
--
-- required_check_fields og covered_check_fields er workflow.required_check_fields(uuid)
-- og workflow.covered_check_fields(uuid) — de samme funksjonene publiseringsgatens
-- G5b bruker. Flaten regner ingenting ut på nytt. Hadde den gjort det, kunne den
-- sagt at ekstraksjonen var ferdig kontrollert mens gaten stengte, eller
-- omvendt.
--
-- Differansen mellom de to — hva som står igjen — er et rent mengdeuttrykk over
-- to lister databasen har levert, ikke en andre formulering av regelen, og
-- overlates til visningen.
--
-- ----------------------------------------------------------------------------
-- Ingen «du har lov»-boolean (§74.22 «FELLE 4»)
--
-- Svaret sier hvem kalleren er og hvem som laget ekstraksjonen; om de er samme
-- aktør, er noe visningen leser av fakta. Skriveveien avgjør retten på nytt, på
-- sitt eget kall.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §6, §10, §11, §12, §15, §17
--   docs/DATABASE_ARCHITECTURE.md §29, §43, §46, §48, §50
--   docs/PRODUCT_INFORMATION_ARCHITECTURE.md §50, §52
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §29, §74.22, §74.34, §74.36
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. workflow.evidence_verification_history(uuid) — kontrollene som finnes
--
-- Alle registrerte ekstraksjonskontroller på ett funn, nyeste først, med «den
-- gjeldende» eksplisitt merket etter nøyaktig den rekkefølgen publiseringsgaten
-- bruker (verified_at desc, created_at desc, id desc) — slik at flaten og gaten
-- aldri kan bli uenige om hvilken kontroll som teller.
--
-- Ingenting er filtrert bort. En tidligere bekreftelse som et senere avvik har
-- underkjent, står fortsatt der: begge er utførte observasjoner, og en flate som
-- bare viste den siste, ville skjult at vurderingen har endret seg.
-- ----------------------------------------------------------------------------
create function workflow.evidence_verification_history(p_evidence_item_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select jsonb_build_object(
    'current_extraction_verification_id', (
      select ev.id
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = p_evidence_item_id
      order by ev.verified_at desc, ev.created_at desc, ev.id desc
      limit 1
    ),
    'extraction_verifications', (
      select coalesce(jsonb_agg(v order by v ->> 'sort_key' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'evidence_verification_id', ev.id,
          'sort_key', to_char(ev.verified_at, 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|'
                      || to_char(ev.created_at, 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|'
                      || ev.id::text,
          'outcome', ev.outcome::text,
          'source_access', ev.source_access::text,
          'checked_fields', to_jsonb(ev.checked_fields::text[]),
          'findings', ev.findings,
          'rationale', ev.rationale,
          'verified_at', ev.verified_at,
          'created_at', ev.created_at,
          'verifier_actor_id', ev.verifier_actor_id,
          'verifier_actor_key', va.actor_key,
          'verifier_actor_type', va.actor_type::text,
          'verifier_display_name', va.display_name,
          -- NULL betyr at kontrollen ble gjort av et menneske, ikke at en
          -- agentkjøring mangler.
          'agent_run_id', ev.agent_run_id
        ) as v
        from workflow.evidence_verifications ev
        join provenance.actors va on va.id = ev.verifier_actor_id
        where ev.evidence_item_id = p_evidence_item_id
      ) as verifications
    )
  );
$$;

comment on function workflow.evidence_verification_history(uuid) is
  'Kontrollene som allerede er registrert på ett evidensfunn: hver ekstraksjonsverifikasjon med sitt utfall, sin kildetilgang, feltene den faktisk gikk gjennom, funnene og begrunnelsen (DATABASE_ARCHITECTURE.md §29). Ingenting filtreres bort: en tidligere bekreftelse som et senere avvik har underkjent, står fortsatt der, fordi begge er utførte observasjoner og tabellen er append-only. current_extraction_verification_id peker på den raden publiseringsgatens G5 leser som den gjeldende, hentet med nøyaktig den samme rekkefølgen (verified_at desc, created_at desc, id desc), slik at flaten og gaten ikke kan bli uenige. agent_run_id er NULL for en menneskelig kontroll. sort_key er en intern sorteringsnøkkel og ikke en opplysning om objektet. SECURITY DEFINER fordi workflow og provenance har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

revoke execute on function workflow.evidence_verification_history(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. api.extraction_review_workspace(uuid) — flaten
-- ----------------------------------------------------------------------------
create function api.extraction_review_workspace(p_evidence_item_id uuid default null)
  returns jsonb
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_reviewer_actor_id uuid;
  v_dossier jsonb;
  v_outcome_concept_id uuid;
  v_queue jsonb;
begin
  -- Kalleren må være reviewer i det hele tatt. Avvisningen kommer fra
  -- workflow.assert_reviewer_authorized(uuid) og navngir hvilket krav som
  -- sviktet; uten et begrep godtas enhver gyldig tildeling, avgrenset eller ikke.
  v_reviewer_actor_id := workflow.assert_reviewer_authorized(null);

  if p_evidence_item_id is null then
    select coalesce(jsonb_agg(item order by item ->> 'created_at'), '[]'::jsonb)
    into v_queue
    from (
      select jsonb_build_object(
        'evidence_item_id', e.id,
        'created_at', e.created_at,
        'created_by_actor_id', e.created_by_actor_id,
        'created_by_actor_key', creator.actor_key,
        'source_id', s.id,
        'source_title', s.title,
        'source_status', s.source_status::text,
        'intervention_drug_name', d.canonical_name,
        'outcome_label', oc.canonical_label,
        'outcome_concept_id', e.outcome_concept_id,
        -- Fravær står som fravær: NULL betyr at ingen kontroll er registrert,
        -- aldri at en kontroll konkluderte negativt (§17).
        'current_extraction_verification_outcome', (
          select ev.outcome::text
          from workflow.evidence_verifications ev
          where ev.evidence_item_id = e.id
          order by ev.verified_at desc, ev.created_at desc, ev.id desc
          limit 1
        ),
        'verification_count', (
          select count(*)
          from workflow.evidence_verifications ev
          where ev.evidence_item_id = e.id
        ),
        -- Gatens egne funksjoner, ikke en kopi av dem.
        'required_check_fields',
          to_jsonb(workflow.required_check_fields(e.id)::text[]),
        'covered_check_fields',
          to_jsonb(workflow.covered_check_fields(e.id)::text[]),
        'linked_claim_revision_count', (
          select count(*)
          from knowledge.claim_evidence_links l
          where l.evidence_item_id = e.id
        )
      ) as item
      from knowledge.evidence_items e
      join knowledge.sources s on s.id = e.source_id
      join provenance.actors creator on creator.id = e.created_by_actor_id
      join catalog.drugs d on d.id = e.intervention_drug_id
      join catalog.clinical_concepts oc on oc.id = e.outcome_concept_id
      where
        -- Radgrensen: en avgrenset reviewer-tildeling ser bare sitt eget
        -- innholdsområde. En uavgrenset ser alt.
        workflow.caller_is_active_reviewer(e.outcome_concept_id)
        -- Funn kalleren selv har laget er utelatt: de kan aldri kontrolleres av
        -- den (evidence_verifications_separate_actor_check), så å ha dem i køen
        -- ville vært å be om et kall som må avvises. De er fortsatt adresserbare
        -- direkte, og flaten sier da hvorfor de ikke kan behandles.
        and e.created_by_actor_id <> v_reviewer_actor_id
        -- Funn denne aktøren allerede har kontrollert er utelatt. En annen
        -- reviewer ser dem fortsatt: to uavhengige kontrollag er to aktører, og
        -- tabellen er append-only, så begge kontrollene består ved siden av
        -- hverandre.
        and not exists (
          select 1
          from workflow.evidence_verifications ev
          where ev.evidence_item_id = e.id
            and ev.verifier_actor_id = v_reviewer_actor_id
        )
    ) as queue;

    return jsonb_build_object(
      'reviewer_actor_id', v_reviewer_actor_id,
      'queue', v_queue
    );
  end if;

  v_dossier := workflow.evidence_extraction_dossier(p_evidence_item_id);

  if v_dossier is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Evidensfunnet %L finnes ikke.', p_evidence_item_id),
      hint = 'Kontrollen peker på ett bestemt evidensfunn. Kontroller id-en, eller gå til køen og velg et funn derfra.';
  end if;

  select e.outcome_concept_id into v_outcome_concept_id
  from knowledge.evidence_items e
  where e.id = p_evidence_item_id;

  -- En avgrenset reviewer-tildeling gir ikke innsyn utenfor sitt eget
  -- innholdsområde, heller ikke ved direkte oppslag. Avvisningen er den samme
  -- som skriveveien ville gitt.
  perform workflow.assert_reviewer_authorized(v_outcome_concept_id);

  return jsonb_build_object(
    'reviewer_actor_id', v_reviewer_actor_id,
    'item', v_dossier
      || workflow.evidence_verification_history(p_evidence_item_id)
      || jsonb_build_object(
           -- Avtrykket vurderingen bindes til. Sendes tilbake uendret av
           -- skriveveien, som sammenligner det med grunnlaget slik det er da.
           'extraction_digest', workflow.evidence_extraction_digest(p_evidence_item_id),
           'required_check_fields',
             to_jsonb(workflow.required_check_fields(p_evidence_item_id)::text[]),
           'covered_check_fields',
             to_jsonb(workflow.covered_check_fields(p_evidence_item_id)::text[]),
           'linked_claim_revisions', (
             select coalesce(jsonb_agg(
               jsonb_build_object(
                 'claim_revision_id', r.id,
                 'claim_id', r.claim_id,
                 'revision_number', r.revision_number,
                 'statement', r.statement,
                 'subject_drug_name', subject.canonical_name,
                 'topic_label', topic.canonical_label,
                 'relationship_type', l.relationship_type::text,
                 'is_published_revision',
                   coalesce(cl.current_published_revision_id = r.id, false)
               )
               order by r.created_at, r.id::text
             ), '[]'::jsonb)
             from knowledge.claim_evidence_links l
             join knowledge.claim_revisions r on r.id = l.claim_revision_id
             join knowledge.claims cl on cl.id = r.claim_id
             join catalog.drugs subject on subject.id = cl.subject_drug_id
             join catalog.clinical_concepts topic on topic.id = cl.topic_concept_id
             where l.evidence_item_id = p_evidence_item_id
           )
         )
  );
end;
$$;

comment on function api.extraction_review_workspace(uuid) is
  'Arbeidsflaten en kvalifisert menneskelig reviewer kontrollerer en ekstraksjon mot kilden fra (ANTIDEP_CONSTITUTION.md §11, §12, §15, MVP_IMPLEMENTATION_PLAN.md §15, §29). Kalleren må ha en registrert, ikke-tilbaketrukket aktør og gyldig reviewer-rolle (workflow.assert_reviewer_authorized(uuid)); en avgrenset tildeling ser bare sitt eget innholdsområde, både i køen og ved direkte oppslag, målt mot endepunktet evidensfunnet rapporterer om. Uten p_evidence_item_id svarer den med arbeidskøen: evidensfunn kalleren ikke selv har laget og ikke selv har kontrollert, hver med nok til å velge — kilden og dens status, utfallet av den gjeldende kontrollen (NULL betyr at ingen er registrert, aldri at en var negativ), og hvilke felter som kreves kontrollert mot hvilke som per nå er dekket. Med p_evidence_item_id svarer den om nøyaktig det funnet: hele grunnlaget fra workflow.evidence_extraction_dossier(uuid) — det samme uttrykket den deterministiske verifikatoren leser, slik at mennesket og maskinen ser det samme — sammen med workflow.evidence_verification_history(uuid), avtrykket vurderingen bindes til (workflow.evidence_extraction_digest(uuid)), feltdekningen lest av publiseringsgatens egne funksjoner (workflow.required_check_fields(uuid) og workflow.covered_check_fields(uuid)), og de påstandsrevisjonene funnet allerede er lenket til. Svaret inneholder ingen «du har lov»-verdi (§74.22 «FELLE 4») og ingen vurdering av om ekstraksjonen «er godkjent»: det sier hva som er registrert, og skriveveien avgjør retten på nytt på sitt eget kall. SECURITY DEFINER fordi knowledge, catalog, provenance og workflow har RLS med default deny; tomt search_path, og kalleren autoriseres på funksjonens eget kall (§50). EXECUTE gis bare til authenticated: en uinnlogget kaller har ingen aktør og kan ikke ha en reviewer-rolle.';

revoke execute on function api.extraction_review_workspace(uuid) from public;
grant execute on function api.extraction_review_workspace(uuid) to authenticated;
