-- ============================================================================
-- Migrasjon 005o — arbeidsflaten den menneskelige reviewen faktisk gjøres fra
--
-- ANTIDEP_CONSTITUTION.md §15 krever at en kvalifisert redaktør kan gjøre
-- vanlige faglige innholdsendringer uten Claude, ChatGPT eller direkte
-- databaseinngrep. Skriveveiene finnes fra 005n og 006d. Denne migrasjonen gir
-- dem noe å arbeide fra: alt en reviewer trenger å se for å kunne svare på de
-- sju kontrollpunktene og deretter avgjøre om påstanden kan publiseres.
--
-- ----------------------------------------------------------------------------
-- Hvorfor en funksjon og ikke et view
--
-- Grunnlaget er dypt nøstet — påstanden, hver evidenslenke, hvert evidensfunn,
-- kilden og kildeversjonen, den gjeldende ekstraksjonsverifikasjonen, hver
-- registrerte claim-verifikasjon med sine kontrollrader, evidensvurderingen, hver
-- reviewbeslutning — og et view måtte enten flatet det ut til noe som ikke lar
-- seg lese, eller vært et titalls view som klienten selv måtte satt sammen. Det
-- siste er det farlige: en klient som setter sammen grunnlaget selv, kan miste en
-- lenke uten at noe fanger det, og en reviewer ville da kontrollert en påstand
-- mot mindre enn det som er registrert (ANTIDEP_CONSTITUTION.md §4, §9).
--
-- Funksjonen bygger på workflow.claim_evidence_dossier(uuid) fra 005m, det samme
-- uttrykket claim-verifikatoren leser sitt grunnlag fra. Mennesket og maskinen
-- ser dermed nøyaktig det samme.
--
-- ----------------------------------------------------------------------------
-- Blokkerende mangler leses av gaten selv, ikke av en kopi av den
--
-- Flaten skal si tydelig hva som stopper en publisering. Å regne det ut på nytt
-- her ville vært en andre formulering av publiseringsgaten, og de to ville før
-- eller siden vært uenige — flaten ville sagt «klar til publisering» om noe
-- gaten stengte, eller omvendt. I stedet kalles
-- knowledge.assert_claim_revision_publishable(uuid) på ekte, og avvisningen den
-- gir returneres ordrett. Gaten stopper på det første vilkåret som svikter, så
-- svaret navngir én blokkering om gangen; de underliggende fakta står ved siden
-- av, slik at revieweren ser hele bildet.
--
-- Ingen «du har lov»-boolean (§74.22 «FELLE 4»). Svaret sier hvem kalleren er og
-- hvem som formulerte revisjonen; om de er samme aktør, er noe visningen kan
-- lese av fakta. En rettighetsverdi beregnet her ville uansett ikke vært den som
-- gjelder: skriveveiene avgjør det på nytt, på sitt eget kall.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §9, §11, §12, §15, §17
--   docs/DATABASE_ARCHITECTURE.md §30, §31, §43, §46, §48, §50
--   docs/PRODUCT_INFORMATION_ARCHITECTURE.md §50, §52
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §29, §74.22, §74.35
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. workflow.caller_is_active_reviewer(uuid) — radgrensen for lesingen
--
-- Den boolske tvillingen til workflow.assert_reviewer_authorized(uuid), med
-- nøyaktig samme tre krav. Den finnes av samme grunn som
-- workflow.caller_is_active_editor() finnes ved siden av
-- knowledge.assert_editor_authorized(uuid) (migrasjon 007d): en radgrense
-- trenger et predikat, ikke en avvisning. Skriveveiene tar
-- autorisasjonsbeslutningen på nytt, på sitt eget kall
-- (DATABASE_ARCHITECTURE.md §43, §48).
-- ----------------------------------------------------------------------------
create function workflow.caller_is_active_reviewer(p_scope_concept_id uuid default null)
  returns boolean
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select exists (
    select 1
    from provenance.actors a
    join workflow.user_roles ur on ur.user_id = a.auth_user_id
    where a.auth_user_id = (select auth.uid())
      and a.retired_at is null
      and ur.role_code = 'reviewer'
      and ur.valid_from <= statement_timestamp()
      and (ur.valid_to is null or ur.valid_to > statement_timestamp())
      and (
        p_scope_concept_id is null
        or ur.scope_id is null
        or ur.scope_id = p_scope_concept_id
      )
  );
$$;

comment on function workflow.caller_is_active_reviewer(uuid) is
  'Om den innloggede brukeren er en registrert, ikke-tilbaketrukket aktør med en gyldig reviewer-tildeling på spørringens eget tidspunkt (statement_timestamp(), ikke transaksjonens starttidspunkt, slik at en tilbakekalling virker umiddelbart — MVP_IMPLEMENTATION_PLAN.md §74.6), eventuelt avgrenset til et klinisk begrep. Den boolske tvillingen til workflow.assert_reviewer_authorized(uuid), og finnes av samme grunn som workflow.caller_is_active_editor() finnes ved siden av knowledge.assert_editor_authorized(uuid): en radgrense trenger et predikat og ikke en avvisning. Brukes bare som radgrense for reviewarbeidsflaten; skriveveiene tar autorisasjonsbeslutningen på nytt, på sitt eget kall (DATABASE_ARCHITECTURE.md §43, §48).';

revoke execute on function workflow.caller_is_active_reviewer(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. workflow.claim_review_history(uuid) — beslutningene som allerede er tatt
--
-- Alle registrerte claim-verifikasjoner med sine kontrollrader, alle registrerte
-- publiseringsgodkjenninger, og evidensvurderingen. Alt nyeste først, og med
-- «den gjeldende» eksplisitt merket etter nøyaktig den rekkefølgen
-- publiseringsgaten bruker (verified_at desc, created_at desc, id desc) — slik
-- at flaten og gaten aldri kan bli uenige om hvilken kontroll som teller.
--
-- Ingenting er filtrert bort. En tidligere avvisning som senere er omgjort, står
-- fortsatt der: både godkjenningen og omgjøringen skal bevares
-- (DATABASE_ARCHITECTURE.md §31), og en flate som bare viste den siste, ville
-- skjult at vurderingen har endret seg.
-- ----------------------------------------------------------------------------
create function workflow.claim_review_history(p_claim_revision_id uuid)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = ''
as $$
  select jsonb_build_object(
    'current_claim_verification_id', (
      select cv.id
      from workflow.claim_verifications cv
      where cv.claim_revision_id = p_claim_revision_id
      order by cv.verified_at desc, cv.created_at desc, cv.id desc
      limit 1
    ),
    'claim_verifications', (
      select coalesce(jsonb_agg(v order by v ->> 'sort_key' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'claim_verification_id', cv.id,
          'sort_key', to_char(cv.verified_at, 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|'
                      || to_char(cv.created_at, 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|'
                      || cv.id::text,
          'outcome', cv.outcome::text,
          'source_access', cv.source_access::text,
          'verified_at', cv.verified_at,
          'created_at', cv.created_at,
          'verifier_actor_id', cv.verifier_actor_id,
          'verifier_actor_key', va.actor_key,
          'verifier_actor_type', va.actor_type::text,
          'verifier_display_name', va.display_name,
          'agent_run_id', cv.agent_run_id,
          'verified_evidence_set_digest', cv.verified_evidence_set_digest,
          'checks', jsonb_build_object(
            'source_support', cv.source_support::text,
            'population_match', cv.population_match::text,
            'comparator_match', cv.comparator_match::text,
            'timeframe_match', cv.timeframe_match::text,
            'direction_and_magnitude', cv.direction_and_magnitude::text,
            'qualifiers_complete', cv.qualifiers_complete::text,
            'contradictory_evidence_represented', cv.contradictory_evidence_represented::text
          ),
          'findings', cv.findings,
          'rationale', cv.rationale,
          'citations', (
            select coalesce(jsonb_agg(
              jsonb_build_object(
                'claim_evidence_link_id', c.claim_evidence_link_id,
                'evidence_item_id', c.evidence_item_id,
                'source_access', c.source_access::text,
                'source_version_id', c.source_version_id,
                'checked_content_hash', c.checked_content_hash,
                'relationship_supported', c.relationship_supported::text,
                'finding', c.finding
              )
              order by c.claim_evidence_link_id::text
            ), '[]'::jsonb)
            from workflow.claim_verification_citations c
            where c.claim_verification_id = cv.id
          )
        ) as v
        from workflow.claim_verifications cv
        join provenance.actors va on va.id = cv.verifier_actor_id
        where cv.claim_revision_id = p_claim_revision_id
      ) as verifications
    ),
    'current_review_decision_id', (
      select rd.id
      from workflow.review_decisions rd
      where rd.claim_revision_id = p_claim_revision_id
        and rd.review_type = 'publication_approval'
      order by rd.decided_at desc, rd.created_at desc, rd.id desc
      limit 1
    ),
    'review_decisions', (
      select coalesce(jsonb_agg(d order by d ->> 'sort_key' desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'review_decision_id', rd.id,
          'sort_key', to_char(rd.decided_at, 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|'
                      || to_char(rd.created_at, 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|'
                      || rd.id::text,
          'decision', rd.decision::text,
          'decided_at', rd.decided_at,
          'created_at', rd.created_at,
          'reviewer_actor_id', rd.reviewer_actor_id,
          'reviewer_actor_key', ra.actor_key,
          'reviewer_display_name', ra.display_name,
          'rationale', rd.rationale,
          'approved_evidence_set_digest', rd.approved_evidence_set_digest
        ) as d
        from workflow.review_decisions rd
        join provenance.actors ra on ra.id = rd.reviewer_actor_id
        where rd.claim_revision_id = p_claim_revision_id
          and rd.review_type = 'publication_approval'
      ) as decisions
    ),
    'evidence_assessment', (
      select jsonb_build_object(
        'evidence_assessment_id', a.id,
        'framework', a.framework::text,
        'certainty_level', a.certainty_level::text,
        'risk_of_bias', a.risk_of_bias::text,
        'inconsistency', a.inconsistency::text,
        'indirectness', a.indirectness::text,
        'imprecision', a.imprecision::text,
        'publication_bias', a.publication_bias::text,
        'other_considerations', a.other_considerations,
        'rationale', a.rationale,
        'evidence_gap', a.evidence_gap,
        'assessed_at', a.assessed_at
      )
      from knowledge.evidence_assessments a
      where a.claim_revision_id = p_claim_revision_id
    )
  );
$$;

comment on function workflow.claim_review_history(uuid) is
  'Beslutningene som allerede er registrert om én påstandsrevisjon: hver claim-verifikasjon med sine sju kontrollpunkter og sine kontrollrader per evidenslenke, hver publiseringsgodkjenning med sin begrunnelse og sitt evidenssettavtrykk, og evidensvurderingen med GRADE-domenene (DATABASE_ARCHITECTURE.md §30, §31, ANTIDEP_CONSTITUTION.md §6, §12). Ingenting filtreres bort: en tidligere avvisning som senere er omgjort, står fortsatt der, fordi både beslutningen og omgjøringen skal bevares. current_claim_verification_id og current_review_decision_id peker på den raden publiseringsgaten leser som den gjeldende, hentet med nøyaktig den samme rekkefølgen (verified_at/decided_at desc, created_at desc, id desc), slik at flaten og gaten ikke kan bli uenige. evidence_assessment er NULL når ingen vurdering er registrert — ikke når grunnlaget er vurdert som svakt; «ingen vurderbar evidens» er en registrert verdi (§6, §17). sort_key er en intern sorteringsnøkkel og ikke en opplysning om objektet. SECURITY DEFINER fordi workflow og knowledge har RLS med default deny; EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

revoke execute on function workflow.claim_review_history(uuid) from public;

-- ----------------------------------------------------------------------------
-- 3. api.claim_review_workspace(uuid) — flaten
-- ----------------------------------------------------------------------------
-- Ikke merket STABLE: funksjonen fanger en avvisning fra publiseringsgaten i en
-- egen subtransaksjon, og gaten er ikke selv merket som lesende. Å love
-- planleggeren mer enn kallkjeden holder, ville vært et løfte uten dekning.
create function api.claim_review_workspace(p_claim_revision_id uuid default null)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_reviewer_actor_id uuid;
  v_dossier jsonb;
  v_topic_concept_id uuid;
  v_gate jsonb;
  v_state text;
  v_message text;
  v_hint text;
  v_queue jsonb;
begin
  -- Kalleren må være reviewer i det hele tatt. Avvisningen kommer fra
  -- workflow.assert_reviewer_authorized(uuid) og navngir hvilket krav som
  -- sviktet; uten et begrep godtas enhver gyldig tildeling, avgrenset eller ikke.
  v_reviewer_actor_id := workflow.assert_reviewer_authorized(null);

  if p_claim_revision_id is null then
    select coalesce(jsonb_agg(item order by item ->> 'created_at'), '[]'::jsonb)
    into v_queue
    from (
      select jsonb_build_object(
        'claim_revision_id', r.id,
        'claim_id', r.claim_id,
        'revision_number', r.revision_number,
        'knowledge_type', r.knowledge_type::text,
        'created_at', r.created_at,
        'created_by_actor_id', r.created_by_actor_id,
        'created_by_actor_key', author.actor_key,
        'statement', r.statement,
        'subject_drug_name', subject.canonical_name,
        'topic_label', topic.canonical_label,
        'topic_concept_id', cl.topic_concept_id,
        'evidence_link_count', (
          select count(*)
          from knowledge.claim_evidence_links l
          where l.claim_revision_id = r.id
        ),
        -- coalesce, ikke en naken sammenligning: uten en publisert revisjon er
        -- current_published_revision_id NULL, og NULL = uuid er ukjent — ikke
        -- usant. En klient som leste den ukjente verdien som «kanskje publisert»
        -- ville sagt noe annet enn «ikke publisert» (ANTIDEP_CONSTITUTION.md §17).
        'is_published_revision', coalesce(cl.current_published_revision_id = r.id, false),
        'current_claim_verification_outcome', (
          select cv.outcome::text
          from workflow.claim_verifications cv
          where cv.claim_revision_id = r.id
          order by cv.verified_at desc, cv.created_at desc, cv.id desc
          limit 1
        ),
        'current_publication_decision', (
          select rd.decision::text
          from workflow.review_decisions rd
          where rd.claim_revision_id = r.id
            and rd.review_type = 'publication_approval'
          order by rd.decided_at desc, rd.created_at desc, rd.id desc
          limit 1
        )
      ) as item
      from knowledge.claim_revisions r
      join knowledge.claims cl on cl.id = r.claim_id
      join provenance.actors author on author.id = r.created_by_actor_id
      join catalog.drugs subject on subject.id = cl.subject_drug_id
      join catalog.clinical_concepts topic on topic.id = cl.topic_concept_id
      where
        -- Radgrensen: en avgrenset reviewer-tildeling ser bare sitt eget
        -- innholdsområde. En uavgrenset ser alt.
        workflow.caller_is_active_reviewer(cl.topic_concept_id)
        -- Påstanden er ikke trukket tilbake.
        and cl.retired_at is null
        -- Revisjoner kalleren selv har formulert er utelatt: hen kan verken
        -- kontrollere dem (claim_verifications_separate_actor_check) eller
        -- godkjenne dem (review_decisions_separate_actor_check), så å ha dem i
        -- køen ville vært å be om et kall som må avvises. De er fortsatt
        -- adresserbare direkte, og flaten sier da hvorfor de ikke kan behandles.
        and r.created_by_actor_id <> v_reviewer_actor_id
        -- En kontroll av en påstand er en kontroll mot et grunnlag. Uten en
        -- eneste evidenslenke finnes det ikke noe å kontrollere mot, og både
        -- dekningskontrollen og publiseringsgatens G3 ville avvist.
        and exists (
          select 1
          from knowledge.claim_evidence_links l
          where l.claim_revision_id = r.id
        )
    ) as queue;

    return jsonb_build_object(
      'reviewer_actor_id', v_reviewer_actor_id,
      'queue', v_queue
    );
  end if;

  v_dossier := workflow.claim_evidence_dossier(p_claim_revision_id);

  if v_dossier is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstandsrevisjonen %L finnes ikke.', p_claim_revision_id),
      hint = 'Review peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  v_topic_concept_id := (v_dossier ->> 'topic_concept_id')::uuid;

  -- En avgrenset reviewer-tildeling gir ikke innsyn utenfor sitt eget
  -- innholdsområde, heller ikke ved direkte oppslag. Avvisningen er den samme
  -- som skriveveien ville gitt.
  perform workflow.assert_reviewer_authorized(v_topic_concept_id);

  -- Publiseringsgaten leses av gaten selv. Den stopper på det første vilkåret
  -- som svikter, så svaret navngir én blokkering om gangen; sqlstate følger med,
  -- slik at en avvisning fra gaten (23001) er til å skille fra en feil som ikke
  -- er en gate.
  begin
    perform knowledge.assert_claim_revision_publishable(p_claim_revision_id);
    v_gate := jsonb_build_object('status', 'passes');
  exception
    when others then
      get stacked diagnostics
        v_state = returned_sqlstate,
        v_message = message_text,
        v_hint = pg_exception_hint;
      v_gate := jsonb_build_object(
        'status', 'blocked',
        'sqlstate', v_state,
        'message', v_message,
        'hint', v_hint
      );
  end;

  return jsonb_build_object(
    'reviewer_actor_id', v_reviewer_actor_id,
    'revision', v_dossier
      || workflow.claim_review_history(p_claim_revision_id)
      || jsonb_build_object(
           'is_published_revision', (
             select coalesce(cl.current_published_revision_id = p_claim_revision_id, false)
             from knowledge.claim_revisions r
             join knowledge.claims cl on cl.id = r.claim_id
             where r.id = p_claim_revision_id
           ),
           'publication_gate', v_gate
         )
  );
end;
$$;

comment on function api.claim_review_workspace(uuid) is
  'Arbeidsflaten en kvalifisert menneskelig reviewer gjør den faglige kontrollen og publiseringsgodkjenningen fra (ANTIDEP_CONSTITUTION.md §11, §12, §15, MVP_IMPLEMENTATION_PLAN.md §15, §29). Kalleren må ha en registrert, ikke-tilbaketrukket aktør og gyldig reviewer-rolle (workflow.assert_reviewer_authorized(uuid)); en avgrenset tildeling ser bare sitt eget innholdsområde, både i køen og ved direkte oppslag. Uten p_claim_revision_id svarer den med arbeidskøen: påstandsrevisjoner kalleren ikke selv har formulert, med minst én evidenslenke, på en påstand som ikke er trukket tilbake — hver med nok til å velge, og med den gjeldende kontrollen og den gjeldende beslutningen som status. Med p_claim_revision_id svarer den om nøyaktig den revisjonen: hele grunnlaget fra workflow.claim_evidence_dossier(uuid) — det samme uttrykket claim-verifikatoren leser, slik at mennesket og maskinen ser det samme — sammen med workflow.claim_review_history(uuid) og publication_gate. Det siste er ikke en egen vurdering av om påstanden kan publiseres: knowledge.assert_claim_revision_publishable(uuid) kalles på ekte, og avvisningen returneres ordrett, slik at flaten aldri kan si «klar» om noe gaten stenger. Gaten stopper på det første vilkåret som svikter, så status = blocked navngir én blokkering om gangen. Svaret inneholder ingen «du har lov»-verdi (§74.22 «FELLE 4»): det sier hvem kalleren er og hvem som formulerte revisjonen, og skriveveiene avgjør retten på nytt på sitt eget kall. SECURITY DEFINER fordi knowledge, catalog, provenance og workflow har RLS med default deny; tomt search_path, og kalleren autoriseres på funksjonens eget kall (§50). EXECUTE gis bare til authenticated: en uinnlogget kaller har ingen aktør og kan ikke ha en reviewer-rolle.';

revoke execute on function api.claim_review_workspace(uuid) from public;
grant execute on function api.claim_review_workspace(uuid) to authenticated;
