-- ============================================================================
-- Migrasjon 005p — bare gatens egen avvisning er en blokkering
--
-- Migrasjon 005o lot api.claim_review_workspace(uuid) prøve publiseringsgaten på
-- ekte og gjengi avvisningen ordrett. Det var riktig grep, men fangsten var for
-- vid: `exception when others` gjorde **enhver** feil fra
-- knowledge.assert_claim_revision_publishable(uuid) om til
-- `publication_gate.status = 'blocked'`.
--
-- Konsekvensen er den motsatte av hensikten. En regresjon i gatefunksjonen, et
-- objekt som er borte, en rettighetsfeil eller en intern SQL-feil ville blitt
-- presentert for revieweren som en ordinær faglig mangel — «publiseringen er
-- blokkert, gaten stopper på det første kravet som ikke er oppfylt» — på nøyaktig
-- den flaten som skal være fasit for om innholdet er klart. En teknisk feil ville
-- da sett ut som et innholdsproblem, og ingen ville lett etter den.
--
-- Funnet i teknisk review av PR #59.
--
-- ----------------------------------------------------------------------------
-- Rettelsen: fang det gaten faktisk sier, og ingenting mer
--
-- Gaten avviser med `restrict_violation` (23001) på hvert eneste av sine vilkår
-- — G1 til G13, uten unntak. Den ene andre feilkoden den kan gi er
-- `invalid_parameter_value` for en revisjon som ikke finnes, og den er allerede
-- utelukket her: api.claim_review_workspace(uuid) leser dossieret først og
-- avviser med sin egen `no_data_found` når revisjonen ikke finnes. Skulle gaten
-- likevel si det, er noe inkonsistent — altså en teknisk feil, ikke en
-- blokkering.
--
-- `when restrict_violation` er derfor både nødvendig og tilstrekkelig. Alt annet
-- propagerer, hele kallet feiler, og klienten viser det som det er: «Antidep fikk
-- ikke hentet grunnlaget», med den tekniske årsaken. En reviewer får da ikke se
-- en flate som ser hel ut mens den skjuler en feil.
--
-- Svarformen er uendret: `status`, `sqlstate`, `message` og `hint` som før.
-- `sqlstate` er nå alltid 23001 for en blokkering, og feltet beholdes fordi
-- klientkontrakten og leseren i `lib/review-workspace.ts` er skrevet om den —
-- og fordi en leser skal kunne se at verdien er gatens egen avvisningskode og
-- ikke en vilkårlig feil.
--
-- Fremover-skrivende, ikke en retusjert linje i 005o: 20260909094000 er allerede
-- kjørt i det hostede prosjektet, og Supabase kjører aldri en registrert
-- migrasjonsversjon på nytt (§74.32).
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §6, §11, §12, §17
--   docs/DATABASE_ARCHITECTURE.md §38, §43, §50
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §74.36
-- ============================================================================

create or replace function api.claim_review_workspace(p_claim_revision_id uuid default null)
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
  -- som svikter, så svaret navngir én blokkering om gangen.
  --
  -- Bare `restrict_violation` fanges, og det er hele poenget (migrasjon 005p):
  -- det er koden gaten avviser med på hvert eneste av sine vilkår. Enhver annen
  -- feil — en regresjon i gaten, et manglende objekt, en rettighetsfeil — er en
  -- teknisk feil og propagerer, slik at hele kallet feiler og klienten viser det
  -- som en feil. En teknisk feil som ble gjengitt som «publiseringen er
  -- blokkert», ville skjult seg som en innholdsmangel på nøyaktig den flaten som
  -- skal være fasit for om innholdet er klart.
  begin
    perform knowledge.assert_claim_revision_publishable(p_claim_revision_id);
    v_gate := jsonb_build_object('status', 'passes');
  exception
    when restrict_violation then
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
  'Arbeidsflaten en kvalifisert menneskelig reviewer gjør den faglige kontrollen og publiseringsgodkjenningen fra (ANTIDEP_CONSTITUTION.md §11, §12, §15, MVP_IMPLEMENTATION_PLAN.md §15, §29). Kalleren må ha en registrert, ikke-tilbaketrukket aktør og gyldig reviewer-rolle (workflow.assert_reviewer_authorized(uuid)); en avgrenset tildeling ser bare sitt eget innholdsområde, både i køen og ved direkte oppslag. Uten p_claim_revision_id svarer den med arbeidskøen: påstandsrevisjoner kalleren ikke selv har formulert, med minst én evidenslenke, på en påstand som ikke er trukket tilbake — hver med nok til å velge, og med den gjeldende kontrollen og den gjeldende beslutningen som status. Med p_claim_revision_id svarer den om nøyaktig den revisjonen: hele grunnlaget fra workflow.claim_evidence_dossier(uuid) — det samme uttrykket claim-verifikatoren leser, slik at mennesket og maskinen ser det samme — sammen med workflow.claim_review_history(uuid) og publication_gate. Det siste er ikke en egen vurdering av om påstanden kan publiseres: knowledge.assert_claim_revision_publishable(uuid) kalles på ekte, og avvisningen returneres ordrett, slik at flaten aldri kan si «klar» om noe gaten stenger. Gaten stopper på det første vilkåret som svikter, så status = blocked navngir én blokkering om gangen. Bare gatens egen avvisningskode (restrict_violation) blir til blocked; enhver annen feil propagerer og feiler hele kallet, slik at en teknisk feil aldri kan presenteres som en innholdsmangel (migrasjon 005p). Svaret inneholder ingen «du har lov»-verdi (§74.22 «FELLE 4»): det sier hvem kalleren er og hvem som formulerte revisjonen, og skriveveiene avgjør retten på nytt på sitt eget kall. SECURITY DEFINER fordi knowledge, catalog, provenance og workflow har RLS med default deny; tomt search_path, og kalleren autoriseres på funksjonens eget kall (§50). EXECUTE gis bare til authenticated: en uinnlogget kaller har ingen aktør og kan ikke ha en reviewer-rolle.';
