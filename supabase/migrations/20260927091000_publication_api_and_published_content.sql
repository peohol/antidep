-- ============================================================================
-- Migrasjon 009f — publiseringshandlingen, tilbaketrekkingen, rollbacken og det
--                  publiserte innholdet klinikeren faktisk ser
--
-- Migrasjon 009e bandt publiseringshendelsen til den forseglede kandidaten og
-- til sluttkontrollen som godkjente den. Denne migrasjonen åpner veien inn dit,
-- og veien ut igjen.
--
-- ----------------------------------------------------------------------------
-- 1. Tre handlinger, tre innganger, tre spørsmål
--
-- `api.publish_claim_revision(uuid, text)` er borte. Den het det den gjorde den
-- gangen publisering var en revisjonshandling, og navnet ville vært feil nå: det
-- som publiseres, er et forseglet innhold. Den er heller ikke en funksjon noen
-- har kunnet kalle — resetten stengte den for klientrollene — så ingen kaller
-- mister noe. Den erstattes av `api.publish_candidate(uuid, text, text)`.
--
-- De tre handlingene har hver sin inngang og ikke én med en handlingsparameter,
-- av samme grunn som de tre `knowledge`-operasjonene har det: de stiller
-- genuint forskjellige spørsmål. Å publisere spør «er dette innholdet godkjent
-- og gjeldende?», å trekke tilbake spør ingenting — det er en sikkerhetshandling
-- som aldri skal kunne blokkeres av at grunnlaget er blitt utilstrekkelig — og å
-- rulle tilbake spør «har dette innholdet vært vist før, og holder det fortsatt?».
--
-- ----------------------------------------------------------------------------
-- 2. Kandidaten kalleren navngir, blir kontrollert — aldri stolt på
--
-- `api.publish_candidate` tar kandidatens id og det avtrykket flaten faktisk
-- viste. Ingen av de to er en kilde til sannhet: databasen slår opp kandidaten
-- selv, krever at avtrykket er kandidatens eget, og krever at nettopp den
-- kandidaten er den gjeldende for sin revisjon. Deretter er det
-- `knowledge.publish_claim_revision(uuid, uuid, text)` som avgjør alt — inne i
-- transaksjonen, under låsene, med hele gaten.
--
-- Kontrollene her er altså ikke en andre gate. De finnes for at en flate som
-- viste ett innhold og trykket på et annet, skal få en feilmelding som sier
-- nettopp det, framfor å publisere noe fagpersonen aldri så.
--
-- Publisher-aktøren er ikke en parameter. Den utledes av den innloggede
-- brukerens egen aktørrad, slik at attribusjonen er en observasjon og ikke en
-- påstand fra den som skriver. En agentidentitet har ingen brukerkonto og er
-- `anon` i Data API-et; de tre handlingene er ikke kjørbare for `anon`, og
-- knowledge.assert_publisher_authorized(uuid, uuid) ville uansett avvist en
-- aktør som ikke er et menneske knyttet til den innloggede kontoen.
--
-- ----------------------------------------------------------------------------
-- 3. Gjentatte kall er trygge, og det er låsen som gjør dem trygge
--
-- Alle tre tar radlåsen på påstanden før de leser tilstanden. Er handlingen
-- allerede utført — kandidaten er alt den publiserte, eller ingenting er
-- publisert og den siste hendelsen er en tilbaketrekking — svarer de med den
-- hendelsen som allerede finnes og `changed: false`, framfor å skrive en ny
-- hendelse eller å feile. En dobbeltklikk skal ikke bli to hendelser, og den
-- skal heller ikke bli en feilmelding om noe som faktisk er i orden.
--
-- Selve `knowledge`-operasjonene er uendret strenge: der er en hendelse alltid
-- en reell tilstandsendring. Idempotensen ligger i inngangen, under låsen, og
-- ikke i historikken.
--
-- ----------------------------------------------------------------------------
-- 4. Det publiserte innholdet er kandidatens rad, ordrett
--
-- `api.published_claim(uuid)` leser innholdet ut av den kandidaten
-- publiseringspekeren navngir. Innholdet er ikke bygget på nytt: en
-- gjenoppbygging ville vist dagens rader, og det er nettopp forskjellen mellom
-- «hva sier vi nå» og «hva ble godkjent». Avtrykket følger med, og det er
-- kontrollerbart: `knowledge.candidates` har en CHECK som sier at avtrykket *er*
-- sha256 av innholdet.
--
-- Interne kandidater forblir private. Leseveien gir innhold bare for en kandidat
-- som er publisert nå; en kandidat som aldri ble publisert, eller som er trukket
-- tilbake, gir historikk og ingen tekst. `knowledge.candidates` har fortsatt
-- ingen grant og ingen policy, og originaldokumentene i
-- `knowledge.source_documents` er uberørt av alt dette.
--
-- Leseveien er gitt til `authenticated` og ikke til `anon`. Det er ikke en
-- forglemmelse: det forseglede innholdet bærer ordrette kildeutdrag, og
-- PRODUCT_INFORMATION_ARCHITECTURE.md sier at offentlige utdrag begrenses av
-- rettigheter. Den vurderingen er ikke gjort, og til den er gjort, er
-- klinikerflaten en innlogget flate. De eldre `api.published_*`-viewene er
-- uendret; de bærer ingen utdrag.
--
-- ----------------------------------------------------------------------------
-- 5. Historikken er synlig, også når det ikke står noe publisert
--
-- ANTIDEP_CONSTITUTION.md regel 6: publisert historikk bevares, og
-- tilbaketrekking og rollback skal være synlig. `api.claim_publication_history`
-- svarer derfor på en påstand uten hensyn til om noe er publisert nå — hver
-- hendelse med handling, tidspunkt, hvem, hvorfor, hvilket innhold og hvilket
-- innhold den forrige var. En tilbaketrekking som ikke vises, er ikke synlig.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 5, 6, 7
--   docs/CONTENT_GOVERNANCE.md, docs/PRODUCT_INFORMATION_ARCHITECTURE.md
--   docs/DATABASE_ARCHITECTURE.md, docs/KNOWLEDGE_MODEL.md
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Den gamle revisjonsinngangen
-- ----------------------------------------------------------------------------
drop function api.publish_claim_revision(uuid, text);

-- ----------------------------------------------------------------------------
-- 2. Felles: kallerens egen aktør
--
-- Skrevet én gang. Tre kopier av det samme oppslaget ville kunnet drive fra
-- hverandre, og et avvik her ville vært et avvik i attribusjonen.
-- ----------------------------------------------------------------------------
create function knowledge.assert_publication_actor()
  returns uuid
  language plpgsql
  stable
  set search_path = ''
as $$
declare
  v_actor_id uuid;
begin
  -- KI-aktørene har auth_user_id NULL (actors_auth_user_is_human_check), så et
  -- treff her er alltid et menneske.
  select a.id into v_actor_id
  from provenance.actors a
  where a.auth_user_id = auth.uid() and a.retired_at is null;

  if v_actor_id is null then
    raise exception using
      errcode = 'insufficient_privilege',
      message = 'Kontoen din er ikke knyttet til en aktiv aktør i Antidep.',
      hint = 'En publisering, tilbaketrekking eller rollback skal attribueres til en navngitt person (ANTIDEP_CONSTITUTION.md regel 5, 6). En kaller uten aktørrad kan ikke utføre den i sitt eget navn.';
  end if;

  return v_actor_id;
end;
$$;

comment on function knowledge.assert_publication_actor() is
  'Den aktive, menneskelige aktøren den innloggede brukeren er, eller en avvisning. Aktøren er aldri en parameter i publiseringslaget: en kallerstyrt aktør ville gjort attribusjonen til en påstand fra den som skriver framfor en observasjon. Selve publiseringsretten avgjøres et annet sted — av knowledge.assert_publisher_authorized(uuid, uuid), inne i den transaksjonen som skriver hendelsen.';

revoke execute on function knowledge.assert_publication_actor() from public;

-- ----------------------------------------------------------------------------
-- 3. Felles: hendelsen som svar
-- ----------------------------------------------------------------------------
create function knowledge.publication_event_summary(p_event_id uuid)
  returns jsonb
  language sql
  stable
  set search_path = ''
as $$
  select jsonb_build_object(
    'publication_event_id', e.id,
    'claim_id', e.claim_id,
    'action', e.action::text,
    'claim_revision_id', e.revision_id,
    'revision_number', e.revision_number,
    'candidate_id', e.candidate_id,
    'candidate_digest', e.candidate_digest,
    'previous_claim_revision_id', e.previous_revision_id,
    'previous_candidate_id', e.previous_candidate_id,
    'previous_candidate_digest', e.previous_candidate_digest,
    'published_at', e.published_at,
    'published_by', a.display_name,
    'reason', e.reason,
    'approval_decided_at', e.approval_decided_at
  )
  from knowledge.publication_events e
  join provenance.actors a on a.id = e.published_by_actor_id
  where e.id = p_event_id;
$$;

comment on function knowledge.publication_event_summary(uuid) is
  'Én publiseringshendelse som svar til en flate: handlingen, hva som er publisert etter den, hva som var publisert før den, hvem som utførte den og hvorfor. Bærer både revisjonen og det forseglede innholdet, fordi en hendelse som bare navngir revisjonen ikke sier hvilket innhold som faktisk ble vist.';

revoke execute on function knowledge.publication_event_summary(uuid) from public;

-- ----------------------------------------------------------------------------
-- 4. Publisering
-- ----------------------------------------------------------------------------
create function api.publish_candidate(
  p_candidate_id uuid,
  p_seen_candidate_digest text,
  p_reason text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_candidate knowledge.candidates;
  v_claim_id uuid;
  v_current_candidate_id uuid;
  v_current knowledge.candidates;
  v_event_id uuid;
begin
  v_actor_id := knowledge.assert_publication_actor();

  select c.* into v_candidate
  from knowledge.candidates c
  where c.id = p_candidate_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kandidaten %L finnes ikke.', p_candidate_id);
  end if;

  select r.claim_id into v_claim_id
  from knowledge.claim_revisions r
  where r.id = v_candidate.claim_revision_id;

  -- Låsen først. Alt under leses av den tilstanden låsen holder fast, og
  -- rekkefølgen påstand -> revisjon -> kandidat er den samme som
  -- knowledge.publish_claim_revision(uuid, uuid, text) bruker.
  select cl.current_published_candidate_id into v_current_candidate_id
  from knowledge.claims cl
  where cl.id = v_claim_id
  for update;

  -- Lag 1: kalleren skal ha sett nøyaktig denne kandidaten.
  if p_seen_candidate_digest is distinct from v_candidate.candidate_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Publiseringen viser til et annet kandidatavtrykk enn kandidatens eget.',
      hint = 'Avtrykket skal kopieres uendret fra den kandidaten som faktisk ble vist. En publisering avgitt mot ett innhold og utført på et annet, ville vært en publisering av noe ingen har sett (ANTIDEP_CONSTITUTION.md regel 5).';
  end if;

  -- Allerede utført. Svaret er hendelsen som finnes, ikke en ny hendelse og
  -- ikke en feil: en gjentatt publisering av det samme innholdet har ikke
  -- endret noe, og historikken skal bare bære reelle tilstandsendringer.
  if v_current_candidate_id = p_candidate_id then
    return jsonb_build_object('changed', false, 'published', true)
      || knowledge.publication_event_summary((knowledge.publication_head_event(v_claim_id)).id);
  end if;

  -- Lag 2: kandidaten skal fortsatt være den gjeldende for sin revisjon.
  -- Gaten avgjør det samme på nytt under låsene; kontrollen her finnes for at
  -- feilmeldingen skal navngi hva som er galt med akkurat denne kandidaten.
  v_current := knowledge.current_candidate(v_candidate.claim_revision_id);
  if v_current.id is distinct from p_candidate_id then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Kandidaten er ikke den gjeldende for påstandsrevisjonen sin, og kan ikke publiseres.',
      hint = 'Grunnlaget er endret siden kandidaten ble forseglet, så innholdet bygger nå til et annet avtrykk. Bygg kandidaten på nytt med api.build_candidate(uuid), få den sluttkontrollert, og publiser den nye. En publisering av et innhold som ikke lenger er det som ligger der, ville ikke vært en publisering av noe (ANTIDEP_CONSTITUTION.md regel 5).';
  end if;

  v_event_id := knowledge.publish_claim_revision(
    v_candidate.claim_revision_id, v_actor_id, p_reason
  );

  return jsonb_build_object('changed', true, 'published', true)
    || knowledge.publication_event_summary(v_event_id);
end;
$$;

comment on function api.publish_candidate(uuid, text, text) is
  'Den redaksjonelle handlingen som publiserer ett forseglet kandidatinnhold (ANTIDEP_CONSTITUTION.md regel 5, 6). En egen og eksplisitt handling etter sluttkontrollen, med et annet mandat: sluttkontrollen krever reviewer-rollen, publiseringen krever publisher-rollen, og å godkjenne og å publisere er to beslutninger med hver sin rad. Kandidat-id og avtrykk er kallerens, men ingen av dem er en kilde til sannhet: databasen slår opp kandidaten selv, krever at avtrykket er kandidatens eget og at kandidaten fortsatt er den gjeldende for sin revisjon, og lar deretter knowledge.publish_claim_revision(uuid, uuid, text) avgjøre alt inne i transaksjonen — publisher-rett, hele publiseringsgaten, låsene og hendelsen. Publisher-aktøren er ikke en parameter; den utledes av den innloggede brukerens egen aktørrad. Idempotent under radlåsen: er kandidaten alt den publiserte, svarer funksjonen med den hendelsen som finnes og changed: false, framfor å skrive en ny. SECURITY DEFINER med tomt search_path fordi knowledge, workflow og provenance har RLS med default deny (§50). EXECUTE gis bare til authenticated: en agentidentitet er anon i Data API-et og har ingen brukerkonto å ha en publisher-rolle på.';

revoke execute on function api.publish_candidate(uuid, text, text) from public;
grant execute on function api.publish_candidate(uuid, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Tilbaketrekking
-- ----------------------------------------------------------------------------
create function api.withdraw_claim_publication(
  p_claim_id uuid,
  p_reason text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_current_revision_id uuid;
  v_head knowledge.publication_events;
  v_event_id uuid;
begin
  v_actor_id := knowledge.assert_publication_actor();

  select cl.current_published_revision_id into v_current_revision_id
  from knowledge.claims cl
  where cl.id = p_claim_id
  for update;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstand %L finnes ikke.', p_claim_id);
  end if;

  v_head := knowledge.publication_head_event(p_claim_id);

  -- Allerede trukket tilbake. Svaret er den tilbaketrekkingen som finnes.
  if v_current_revision_id is null and v_head.action = 'withdraw' then
    return jsonb_build_object('changed', false, 'published', false)
      || knowledge.publication_event_summary(v_head.id);
  end if;

  v_event_id := knowledge.withdraw_claim_publication(p_claim_id, v_actor_id, p_reason);

  return jsonb_build_object('changed', true, 'published', false)
    || knowledge.publication_event_summary(v_event_id);
end;
$$;

comment on function api.withdraw_claim_publication(uuid, text) is
  'Trekker det publiserte innholdet for én påstand ut av klinikerflaten (ANTIDEP_CONSTITUTION.md regel 6). En ny append-only hendelse, aldri en sletting eller en omskriving: den gamle publiseringshendelsen står, og den nye navngir hvilket forseglet innhold som ble tatt ut av visning, hvem som gjorde det og hvorfor. Krever en navngitt menneskelig aktør med gyldig publisher-mandat, avgjort av knowledge.withdraw_claim_publication(uuid, uuid, text) inne i transaksjonen, og en begrunnelse — en tilbaketrekking uten begrunnelse er ikke etterprøvbar. Kjører bevisst ingen publiseringsgate: å ta innhold ut av visning skal aldri kunne blokkeres av at grunnlaget er blitt utilstrekkelig, for det er nettopp da handlingen trengs. Idempotent under radlåsen: er innholdet alt trukket tilbake, svarer funksjonen med den hendelsen som finnes og changed: false. SECURITY DEFINER med tomt search_path (§50); EXECUTE bare til authenticated.';

revoke execute on function api.withdraw_claim_publication(uuid, text) from public;
grant execute on function api.withdraw_claim_publication(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 6. Rollback
-- ----------------------------------------------------------------------------
create function api.rollback_claim_publication(
  p_claim_id uuid,
  p_target_candidate_id uuid,
  p_seen_candidate_digest text,
  p_reason text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_candidate knowledge.candidates;
  v_target_claim_id uuid;
  v_current_candidate_id uuid;
  v_event_id uuid;
begin
  v_actor_id := knowledge.assert_publication_actor();

  select c.* into v_candidate
  from knowledge.candidates c
  where c.id = p_target_candidate_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Kandidaten %L finnes ikke.', p_target_candidate_id);
  end if;

  select r.claim_id into v_target_claim_id
  from knowledge.claim_revisions r
  where r.id = v_candidate.claim_revision_id;

  if v_target_claim_id is distinct from p_claim_id then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Kandidaten %L hører til en annen påstand enn %L.', p_target_candidate_id, p_claim_id
      ),
      hint = 'Publiseringspekeren kan bare peke på innhold som hører til den samme påstanden.';
  end if;

  select cl.current_published_candidate_id into v_current_candidate_id
  from knowledge.claims cl
  where cl.id = p_claim_id
  for update;

  if p_seen_candidate_digest is distinct from v_candidate.candidate_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = 'Rollbacken viser til et annet kandidatavtrykk enn kandidatens eget.',
      hint = 'Avtrykket skal kopieres uendret fra den versjonen flaten faktisk viste. En rollback til ett innhold, utført på et annet, ville gjenopprettet noe ingen valgte (ANTIDEP_CONSTITUTION.md regel 6).';
  end if;

  if v_current_candidate_id = p_target_candidate_id then
    return jsonb_build_object('changed', false, 'published', true)
      || knowledge.publication_event_summary((knowledge.publication_head_event(p_claim_id)).id);
  end if;

  v_event_id := knowledge.rollback_claim_publication(
    p_claim_id, v_candidate.claim_revision_id, v_actor_id, p_reason
  );

  return jsonb_build_object('changed', true, 'published', true)
    || knowledge.publication_event_summary(v_event_id);
end;
$$;

comment on function api.rollback_claim_publication(uuid, uuid, text, text) is
  'Ruller publiseringen tilbake til en tidligere publisert versjon av den samme påstanden (ANTIDEP_CONSTITUTION.md regel 6, DATABASE_ARCHITECTURE.md §40). En ny hendelse som peker på hva man går tilbake til og hvorfor; den gamle hendelsen skrives aldri om. Målet oppgis som den kandidaten man vil tilbake til, med avtrykket flaten viste, og begge kontrolleres mot databasens egne rader. Rollbacken omgår ingen gate: knowledge.rollback_claim_publication(uuid, uuid, uuid, text) krever publisher-mandat, at målrevisjonen faktisk har vært publisert, at hele publiseringsgaten holder på nytt — inkludert at den gjeldende sluttkontrollen fortsatt er approved — og at målets gjeldende kandidat er et innhold som faktisk har vært vist. Er grunnlaget endret siden den gangen, er veien framover en ny kandidat og en ny sluttkontroll, ikke en rollback. Idempotent under radlåsen. SECURITY DEFINER med tomt search_path (§50); EXECUTE bare til authenticated.';

revoke execute on function api.rollback_claim_publication(uuid, uuid, text, text) from public;
grant execute on function api.rollback_claim_publication(uuid, uuid, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 7. Historikken
-- ----------------------------------------------------------------------------
create function api.claim_publication_history(p_claim_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_claim knowledge.claims;
begin
  select cl.* into v_claim from knowledge.claims cl where cl.id = p_claim_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstand %L finnes ikke.', p_claim_id);
  end if;

  return jsonb_build_object(
    'claim_id', v_claim.id,
    'published', v_claim.current_published_candidate_id is not null,
    'current_candidate_id', v_claim.current_published_candidate_id,
    -- Rekkefølgen leses av kjeden og aldri av klokka. Alle hendelsene i én
    -- transaksjon bærer det samme published_at, fordi now() er transaksjonens
    -- starttidspunkt; en sortering på tid ville da vært vilkårlig, og en
    -- tilbaketrekking kunne stått under den publiseringen den opphevet. Hver
    -- hendelse navngir sin egen forgjenger, og kjeden kan ikke forgrenes
    -- (publication_events_no_forked_history_key), så dybden er entydig.
    'events', coalesce((
      with recursive chain as (
        select e.id, e.previous_event_id, 0 as depth
        from knowledge.publication_events e
        where e.claim_id = p_claim_id and e.previous_event_id is null
        union all
        select e.id, e.previous_event_id, chain.depth + 1
        from knowledge.publication_events e
        join chain on chain.id = e.previous_event_id
        where e.claim_id = p_claim_id
      )
      select jsonb_agg(jsonb_build_object(
               'publication_event_id', e.id,
               'sequence', chain.depth,
               'action', e.action::text,
               'published_at', e.published_at,
               'published_by', a.display_name,
               'reason', e.reason,
               'claim_revision_id', e.revision_id,
               'revision_number', e.revision_number,
               'candidate_id', e.candidate_id,
               'candidate_digest', e.candidate_digest,
               'previous_claim_revision_id', e.previous_revision_id,
               'previous_revision_number', e.previous_revision_number,
               'previous_candidate_id', e.previous_candidate_id,
               'previous_candidate_digest', e.previous_candidate_digest,
               'approval_decided_at', e.approval_decided_at,
               'final_control', case when e.final_control_id is null then null else (
                 select jsonb_build_object(
                          'decision', fc.decision::text,
                          'decided_at', fc.decided_at,
                          'reviewer', fa.display_name,
                          'rationale', fc.rationale)
                 from workflow.candidate_final_controls fc
                 join provenance.actors fa on fa.id = fc.reviewer_actor_id
                 where fc.id = e.final_control_id
               ) end)
             order by chain.depth desc)
      from chain
      join knowledge.publication_events e on e.id = chain.id
      join provenance.actors a on a.id = e.published_by_actor_id
    ), '[]'::jsonb)
  );
end;
$$;

comment on function api.claim_publication_history(uuid) is
  'Hele publiseringshistorikken for én påstand, uavhengig av om noe er publisert nå (ANTIDEP_CONSTITUTION.md regel 6). Rekkefølgen leses av hendelseskjeden og aldri av klokka: alle hendelsene i én transaksjon bærer det samme published_at, og en tidssortering ville da kunnet sette en tilbaketrekking under den publiseringen den opphevet. Nyeste først, og hver rad bærer sitt eget sekvensnummer i kjeden. Hver hendelse med handlingen, tidspunktet, den navngitte personen som utførte den, begrunnelsen, hvilket forseglet innhold den etterlot og hvilket den hadde før seg — og for en publisering eller rollback også sluttkontrollen den hviler på. En tilbaketrekking som ikke vises, er ikke synlig, og historikken er nettopp det som gjør den etterprøvbar. Leser bare; historikken er append-only, og ingen hendelse fjernes eller skrives om. SECURITY DEFINER med tomt search_path (§50); EXECUTE bare til authenticated.';

revoke execute on function api.claim_publication_history(uuid) from public;
grant execute on function api.claim_publication_history(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 8. Det publiserte innholdet
-- ----------------------------------------------------------------------------
create function api.published_claim(p_claim_id uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_claim knowledge.claims;
  v_candidate knowledge.candidates;
  v_head knowledge.publication_events;
  v_published_event knowledge.publication_events;
begin
  select cl.* into v_claim from knowledge.claims cl where cl.id = p_claim_id;

  if not found then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstand %L finnes ikke.', p_claim_id);
  end if;

  v_head := knowledge.publication_head_event(p_claim_id);

  if v_claim.current_published_candidate_id is null then
    -- Ikke publisert nå. Innholdet utelates, og fraværet er sagt eksplisitt
    -- framfor å være en tom tekst: et innhold som ikke vises, skal ikke kunne
    -- forveksles med et innhold uten forbehold (ANTIDEP_CONSTITUTION.md regel 4).
    return jsonb_build_object(
      'claim_id', v_claim.id,
      'published', false,
      'withdrawn', v_head.action = 'withdraw',
      'content', null,
      'history', api.claim_publication_history(p_claim_id) -> 'events'
    );
  end if;

  select c.* into v_candidate
  from knowledge.candidates c
  where c.id = v_claim.current_published_candidate_id;

  -- Hendelsen som satte det som står nå. Det er hodet i kjeden: pekeren og
  -- hodet flyttes i den samme transaksjonen, så de kan ikke si hver sin ting.
  v_published_event := v_head;

  return jsonb_build_object(
    'claim_id', v_claim.id,
    'published', true,
    'withdrawn', false,
    'claim_revision_id', v_candidate.claim_revision_id,
    'candidate_id', v_candidate.id,
    -- Avtrykket står ved siden av innholdet med vilje: det er kontrollerbart,
    -- og en leser kan regne det ut av innholdet selv.
    'candidate_digest', v_candidate.candidate_digest,
    'evidence_set_digest', v_candidate.evidence_set_digest,
    'built_at', v_candidate.built_at,
    -- Ordrett den raden sluttkontrollen godkjente. Ikke bygget på nytt: en
    -- gjenoppbygging ville vist dagens rader, og det er nettopp forskjellen
    -- mellom «hva sier vi nå» og «hva ble godkjent».
    'content', v_candidate.content,
    'publication', knowledge.publication_event_summary(v_published_event.id),
    'final_control', (
      select jsonb_build_object(
               'decision', fc.decision::text,
               'decided_at', fc.decided_at,
               'reviewer', a.display_name,
               'rationale', fc.rationale,
               'candidate_digest', fc.candidate_digest)
      from workflow.candidate_final_controls fc
      join provenance.actors a on a.id = fc.reviewer_actor_id
      where fc.id = v_published_event.final_control_id
    ),
    'history', api.claim_publication_history(p_claim_id) -> 'events'
  );
end;
$$;

comment on function api.published_claim(uuid) is
  'Det publiserte klinikerinnholdet for én påstand (PRODUCT_INFORMATION_ARCHITECTURE.md). Innholdet er raden i knowledge.candidates som publiseringspekeren navngir, ordrett og uendret — ikke en gjenoppbygging fra dagens tilstand, som ville kunnet vise noe annet enn det en navngitt fagperson godkjente. Avtrykket følger med og kan regnes ut av innholdet selv, så identiteten er etterprøvbar og ikke en påstand. Proveniensen peker tilbake til kandidaten, påstandsrevisjonen, sluttkontrollen og publiseringshendelsen, og hele historikken følger med, slik at en tilbaketrekking eller rollback er synlig der innholdet leses. Er ingenting publisert nå, er content null og published false, og historikken står igjen: et innhold som ikke vises, skal ikke kunne forveksles med et innhold uten forbehold. Interne kandidater er ikke lesbare her — bare den som er publisert nå. SECURITY DEFINER med tomt search_path fordi knowledge og workflow har RLS med default deny (§50); EXECUTE bare til authenticated, fordi det forseglede innholdet bærer ordrette kildeutdrag og offentlig gjengivelsesrett er vurdert separat.';

revoke execute on function api.published_claim(uuid) from public;
grant execute on function api.published_claim(uuid) to authenticated;

create function api.published_claim_index()
  returns jsonb
  language sql
  security definer
  set search_path = ''
as $$
  select coalesce(jsonb_agg(entry order by entry ->> 'published_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'claim_id', cl.id,
      'candidate_id', c.id,
      'candidate_digest', c.candidate_digest,
      'claim_revision_id', c.claim_revision_id,
      'statement', c.content -> 'claim_revision' ->> 'statement',
      'subject_drug', c.content -> 'claim_revision' ->> 'subject_drug',
      'topic', c.content -> 'claim_revision' ->> 'topic',
      'certainty_level', c.content -> 'evidence_assessment' ->> 'certainty_level',
      'source_count', jsonb_array_length(coalesce(c.content -> 'source_coverage', '[]'::jsonb)),
      'published_at', (knowledge.publication_head_event(cl.id)).published_at
    ) as entry
    from knowledge.claims cl
    join knowledge.candidates c on c.id = cl.current_published_candidate_id
    where cl.retired_at is null
  ) as rows;
$$;

comment on function api.published_claim_index() is
  'Påstandene Antidep publiserer nå, med nok til å velge én: påstanden, virkestoffet, temaet, sikkerhetsgraden, antall kilder og når den ble publisert. Alle verdiene leses ut av det forseglede innholdet og ikke av dagens rader, slik at listen og siden bak den ikke kan si forskjellige ting. En påstand uten publisert innhold står ikke her — heller ikke en som er trukket tilbake; den finnes fortsatt i api.claim_publication_history(uuid), som er der tilbaketrekkingen skal være synlig. SECURITY DEFINER med tomt search_path (§50); EXECUTE bare til authenticated.';

revoke execute on function api.published_claim_index() from public;
grant execute on function api.published_claim_index() to authenticated;

-- ----------------------------------------------------------------------------
-- 9. Kommentaren som navnga den gamle inngangen
--
-- workflow.ensure_publisher_role_grant() forklarer hva publisher-rollen åpner,
-- og navnga api.publish_claim_revision(uuid, text). Den funksjonen finnes ikke
-- lenger, og en kommentar som navngir en funksjon som ikke finnes, er en
-- usannhet 280_content_hash_serialization_test.sql fanger. Rollen den åpner, er
-- den samme; det er inngangen som har byttet navn fordi det som publiseres, er
-- et innhold.
-- ----------------------------------------------------------------------------
comment on function workflow.ensure_publisher_role_grant() is
  'Idempotent tildeling av `publisher`-rollen til den navngitte kvalifiserte redaktørens brukerkonto, altså retten til å utføre selve publiseringen. Åpner knowledge.publish_claim_revision(uuid, uuid, text) og api.publish_candidate(uuid, text, text), som krever en gyldig publisher-tildeling gjennom knowledge.assert_publisher_authorized(uuid, uuid), og sammen med dem api.withdraw_claim_publication(uuid, text) og api.rollback_claim_publication(uuid, uuid, text, text). Gir ikke faglig godkjenningsrett: å sluttkontrollere og å publisere er to forskjellige handlinger med hver sin rolle og hver sin rad, og publiseringsgatens G11 og G12 krever sluttkontrollen uavhengig av hvem som publiserer. Åpner ingen gate: alle vilkårene kjøres på nytt inne i publiseringstransaksjonen. Forutsetter at aktørraden er knyttet til kontoen av workflow.ensure_named_editor_authorization() (migrasjon 005b) og setter ikke koblingen selv. Returnerer account_missing (ingen rad i auth.users), authorized (tildelingen ble skrevet), already_authorized (en tildeling er gyldig nå), role_not_yet_valid (en tildeling begynner å gjelde senere) eller role_ended (en tildeling er avsluttet). Bare authorized skriver noe. Gyldighet måles med statement_timestamp() fordi predikatet avgjør noe. En avsluttet tildeling gjeninnføres aldri (DATABASE_ARCHITECTURE.md §46). Konto, aktørnøkkel og rolle er konstanter i kroppen: funksjonen kan bare gjøre denne ene tildelingen, aldri en vilkårlig.';
