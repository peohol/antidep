-- ============================================================================
-- Migrasjon 009h — rollbacken gjelder innholdet kalleren valgte, og mandatet
--                  kontrolleres også når handlingen allerede er utført
--
-- Tre funn fra kodegjennomgangen av PR #94. To av dem er dataintegritet.
--
-- ----------------------------------------------------------------------------
-- 1. En rollback kunne gjenopprette et annet innhold enn det som ble valgt
--
-- `api.rollback_claim_publication(...)` tok imot kandidaten flaten viste, men
-- ga bare kandidatens *revisjon* videre til den kontrollerte operasjonen, som
-- deretter valgte revisjonens gjeldende kandidat.
--
-- Den samme revisjonen kan ha vært publisert som flere forskjellige innhold: A
-- publiseres, en nyere revisjon erstatter den, grunnlaget under den gamle
-- endres, den bygges om til B, og en rollback tar B i bruk. Etter det har både A
-- og B vært publisert for den samme revisjonen, og begge står i historikken
-- flaten tilbyr som mål. Velger en publisher A, ville kallet publisert B.
-- Kravet om at målet «har vært publisert», gjorde ikke A og B likeverdige.
--
-- Den kontrollerte operasjonen tar nå kandidaten, ikke revisjonen. Revisjonen
-- utledes av kandidaten — to parametere som kunne si hver sin ting om det samme,
-- ville vært et valg om hvilken av dem som gjelder — og kandidaten må i tillegg
-- være det *gjeldende* innholdet for revisjonen sin. Er den ikke det, er
-- grunnlaget endret siden den ble forseglet, og da er svaret å bygge på nytt og
-- sluttkontrollere, ikke å gjenopprette noe som ikke lenger er det som ligger der.
--
-- ----------------------------------------------------------------------------
-- 2. Hendelsen krever nå selv at kandidaten er den gjeldende
--
-- Migrasjon 009g låser alt kandidatinnholdet bygges av, så kontrollen i
-- publiseringsveien er en garanti og ikke et øyeblikksbilde. Tabellen sa det
-- likevel ikke selv: triggeren fra 009e krevde at sluttkontrollen er den
-- gjeldende, men ikke at kandidaten er det.
--
-- Nå gjør den begge deler. En publiseringshendelse kan bare navngi den
-- kandidaten som er gjeldende for revisjonen sin i det øyeblikket raden skrives.
-- Det er samme mønster som de øvrige tverradsvaktene: en regel som bare finnes i
-- én skrivevei, slutter stille å gjelde den dagen det kommer en til.
--
-- ----------------------------------------------------------------------------
-- 3. Den idempotente no-op-en kontrollerte ikke mandatet
--
-- De tre handlingene svarer `changed: false` når handlingen allerede er utført.
-- Svaret ble gitt før publisher-mandatet ble kontrollert, fordi kontrollen ligger
-- i den kontrollerte operasjonen — som en no-op aldri kalte. Ingen tilstand ble
-- endret, men en kaller uten mandat fikk et svar formet som en vellykket
-- handling, og dokumentasjonen om at handlingen krever mandat, var dermed usann
-- for nettopp det tilfellet.
--
-- Mandatet kontrolleres nå først, i alle tre, også når svaret blir en no-op.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md regel 5, 6, 7
--   docs/DATABASE_ARCHITECTURE.md §40, §46, §50, §60
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Hendelsen publiserer bare det som er gjeldende
-- ----------------------------------------------------------------------------
create function knowledge.assert_publication_publishes_current_candidate()
  returns trigger
  language plpgsql
  set search_path = ''
as $$
declare
  v_current knowledge.candidates;
begin
  -- En tilbaketrekking navngir ingen kandidat; da er det ingenting å kreve.
  if new.candidate_id is null then
    return new;
  end if;

  v_current := knowledge.current_candidate(new.revision_id);

  if v_current.id is distinct from new.candidate_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Publiseringshendelsen navngir kandidaten %L, men det gjeldende innholdet for revisjon %L er %L.',
        new.candidate_id, new.revision_id, v_current.id
      ),
      hint = 'Grunnlaget innholdet ble forseglet av, er endret. Bygg kandidaten på nytt med api.build_candidate(uuid), få den sluttkontrollert, og publiser den nye: et innhold som ikke lenger er det som ligger der, er ikke det Antidep sier (ANTIDEP_CONSTITUTION.md regel 5).';
  end if;

  return new;
end;
$$;

comment on function knowledge.assert_publication_publishes_current_candidate() is
  'Tverradsinvariant: en publiseringshendelse kan bare navngi den kandidaten som er gjeldende for revisjonen sin når raden skrives. Publiseringsveien kontrollerer det samme under låsene fra migrasjon 009g, men en regel som bare finnes i én skrivevei, slutter stille å gjelde den dagen det kommer en til. Sammen med knowledge.assert_publication_cites_current_final_control() sier tabellen dermed selv at det som publiseres, er gjeldende innhold godkjent av en gjeldende sluttkontroll (DATABASE_ARCHITECTURE.md §60).';

revoke execute on function knowledge.assert_publication_publishes_current_candidate() from public;

create trigger publication_events_publish_current_candidate
  before insert on knowledge.publication_events
  for each row execute function knowledge.assert_publication_publishes_current_candidate();

-- ----------------------------------------------------------------------------
-- 2. Rollbacken tar kandidaten
-- ----------------------------------------------------------------------------
drop function knowledge.rollback_claim_publication(uuid, uuid, uuid, text);

create function knowledge.rollback_claim_publication(
  p_claim_id uuid,
  p_target_candidate_id uuid,
  p_publisher_actor_id uuid,
  p_reason text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_topic_concept_id uuid;
  v_target_revision_id uuid;
  v_current_revision_id uuid;
  v_current_revision_number integer;
  v_current_candidate_id uuid;
  v_current_candidate_digest text;
  v_target_claim_id uuid;
  v_target_revision_number integer;
  v_previous_event_id uuid;
  v_candidate knowledge.candidates;
  v_control workflow.candidate_final_controls;
  v_event_id uuid;
begin
  select c.topic_concept_id, c.current_published_revision_id, c.current_published_candidate_id
    into v_topic_concept_id, v_current_revision_id, v_current_candidate_id
  from knowledge.claims c
  where c.id = p_claim_id
  for update;

  if not found then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Påstand %L finnes ikke.', p_claim_id),
      hint = 'Kontroller påstands-ID-en.';
  end if;

  if v_current_revision_id is null then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Påstand %L har ingen publisert revisjon å rulle tilbake fra.', p_claim_id),
      hint = 'En rollback flytter pekeren fra den gjeldende revisjonen tilbake til en tidligere publisert. Er ingenting publisert, er handlingen en publisering.';
  end if;

  -- Målet er et innhold, ikke en revisjon. Revisjonen utledes av kandidaten, og
  -- er aldri en parameter ved siden av den: to parametere som kunne si hver sin
  -- ting om det samme, ville vært et valg om hvilken av dem som gjelder.
  select r.id, r.claim_id, r.revision_number
    into v_target_revision_id, v_target_claim_id, v_target_revision_number
  from knowledge.candidates c
  join knowledge.claim_revisions r on r.id = c.claim_revision_id
  where c.id = p_target_candidate_id;

  if not found or v_target_claim_id <> p_claim_id then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format(
        'Kandidaten %L finnes ikke eller tilhører en annen påstand enn %L.',
        p_target_candidate_id, p_claim_id
      ),
      hint = 'Publiseringspekeren kan bare peke på innhold som hører til den samme påstanden (DATABASE_ARCHITECTURE.md §58).';
  end if;

  perform knowledge.lock_candidate_inputs(v_target_revision_id);

  if v_target_revision_id = v_current_revision_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format('Revisjon %L er allerede den publiserte.', v_target_revision_id),
      hint = 'Publiseringshistorikken skal registrere reelle tilstandsendringer.';
  end if;

  select r.revision_number into v_current_revision_number
  from knowledge.claim_revisions r
  where r.id = v_current_revision_id;

  if v_target_revision_number > v_current_revision_number then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L er nyere enn den publiserte revisjonen og er derfor ikke en rollback.',
        v_target_revision_id
      ),
      hint = 'Å gå framover til en nyere revisjon er en erstatning. Bruk knowledge.publish_claim_revision().';
  end if;

  -- Målet må ha vært publisert før. Uten det kravet ville «rollback» vært en
  -- vilkårlig flytting bakover til noe Antidep aldri har sagt.
  if not exists (
    select 1
    from knowledge.publication_events e
    where e.revision_id = v_target_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har aldri vært publisert og kan derfor ikke rulles tilbake til.',
        v_target_revision_id
      ),
      hint = 'En rollback flytter pekeren tilbake til en tidligere publisert revisjon (DATABASE_ARCHITECTURE.md §40). Skal en revisjon som aldri har vært publisert tas i bruk, er det en publisering.';
  end if;

  perform knowledge.assert_publisher_authorized(p_publisher_actor_id, v_topic_concept_id);

  v_candidate := knowledge.current_candidate(v_target_revision_id);
  if v_candidate.id is not null then
    perform 1 from knowledge.candidates c where c.id = v_candidate.id for share;
    v_candidate := knowledge.current_candidate(v_target_revision_id);
  end if;

  -- Gaten kjøres på nytt på målrevisjonen. Det er ikke overflødig: en revisjon
  -- som var publiserbar i fjor kan ha fått et senere avvist verifikasjonsfunn,
  -- en tilbaketrukket kilde eller en omgjort sluttkontroll. Å rulle tilbake til
  -- den ville da vært å publisere noe som ikke lenger holder.
  perform knowledge.assert_claim_revision_publishable(v_target_revision_id);

  -- Det innholdet kalleren valgte, må være det rollbacken tar i bruk. En
  -- revisjon kan ha vært publisert som flere forskjellige kandidater — bygget om
  -- mellom to publiseringer — og «gå tilbake til revisjon R» er da tvetydig.
  -- Uten denne kontrollen kunne en rollback mot kandidat A endt med å publisere
  -- kandidat B, som er noe annet enn det som ble valgt.
  if v_candidate.id is distinct from p_target_candidate_id then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Kandidaten %L er ikke det gjeldende innholdet for revisjonen sin, og kan ikke tas i bruk igjen.',
        p_target_candidate_id
      ),
      hint = format(
        'Grunnlaget under revisjonen er endret siden den kandidaten ble forseglet; det gjeldende innholdet er nå %L. En rollback gjenoppretter en tidligere publisert versjon som fortsatt holder, ikke et innhold som ikke lenger er det som ligger der (DATABASE_ARCHITECTURE.md §40).',
        v_candidate.id
      );
  end if;

  -- ... og det innholdet må faktisk ha vært vist. Uten dette kravet kunne en
  -- rollback tatt i bruk et innhold som aldri har vært publisert — gaten ville
  -- sluppet det gjennom, fordi det er godkjent, men «tilbake» ville da betydd
  -- «til noe nytt».
  if not exists (
    select 1
    from knowledge.publication_events e
    where e.candidate_id = v_candidate.id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Innholdet %L har aldri vært publisert, og en rollback kan ikke ta det i bruk.',
        v_candidate.id
      ),
      hint = 'Et innhold som aldri har vært publisert, tas i bruk ved en publisering — ikke ved en rollback (DATABASE_ARCHITECTURE.md §40).';
  end if;

  v_control := workflow.current_candidate_final_control(v_candidate.id);

  select c.candidate_digest into v_current_candidate_digest
  from knowledge.candidates c
  where c.id = v_current_candidate_id;

  v_previous_event_id := (knowledge.publication_head_event(p_claim_id)).id;

  update knowledge.claims
  set current_published_revision_id = v_target_revision_id,
      current_published_candidate_id = v_candidate.id
  where id = p_claim_id;

  insert into knowledge.publication_events (
    claim_id, action, revision_id, revision_number,
    previous_revision_id, previous_revision_number, previous_event_id,
    candidate_id, candidate_digest, final_control_id, final_control_decision,
    previous_candidate_id, previous_candidate_digest,
    published_by_actor_id, published_by_actor_type, reason, published_at
  )
  select
    p_claim_id, 'rollback', v_target_revision_id, v_target_revision_number,
    v_current_revision_id, v_current_revision_number, v_previous_event_id,
    v_candidate.id, v_candidate.candidate_digest, v_control.id, v_control.decision,
    v_current_candidate_id, v_current_candidate_digest,
    p_publisher_actor_id, a.actor_type, p_reason, now()
  from provenance.actors a
  where a.id = p_publisher_actor_id
  returning id into v_event_id;

  return v_event_id;
end;
$$;

-- En DROP tilbakestiller rettighetene på navnet: PostgreSQL gir PUBLIC execute på
-- en nyopprettet funksjon. Uten denne tilbakekallingen ville den nye
-- rollback-funksjonen stått åpen for enhver rolle (030, 080, 270, 370).
revoke execute on function knowledge.rollback_claim_publication(uuid, uuid, uuid, text) from public;

comment on function knowledge.rollback_claim_publication(uuid, uuid, uuid, text) is
  'Rollback (DATABASE_ARCHITECTURE.md §40): flytter begge publiseringspekerne tilbake til et tidligere publisert innhold og registrerer det som en ny hendelse. Sletter aldri den publiseringen den korrigerer. Målet er en *kandidat* og ikke en revisjon: den samme revisjonen kan ha vært publisert som flere forskjellige innhold, og «gå tilbake til revisjonen» ville da vært tvetydig — en rollback mot ett innhold kunne endt med å publisere et annet. Revisjonen utledes av kandidaten. Fire krav om målet, og alle fire håndheves her: revisjonen må faktisk ha vært publisert og ligge bakover i historikken, hele publiseringsgaten må holde på nytt — en revisjon som var publiserbar tidligere kan ha fått et senere avvik eller en omgjort sluttkontroll — kandidaten må være det gjeldende innholdet for revisjonen sin, og nettopp det innholdet må faktisk ha vært vist.';

-- ----------------------------------------------------------------------------
-- 3. Mandatet kontrolleres før den idempotente no-op-en
-- ----------------------------------------------------------------------------
create or replace function api.publish_candidate(
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
  v_topic_concept_id uuid;
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

  -- Publisher-mandatet kontrolleres før alt annet, også før den idempotente
  -- no-op-en. Ellers ville en kaller uten mandat fått et svar formet som en
  -- vellykket handling, og dokumentasjonen om at handlingen krever mandat, ville
  -- vært usann for nettopp det tilfellet. Den kontrollerte operasjonen avgjør
  -- retten på nytt inne i transaksjonen; dette er ikke en erstatning for den.
  select cl.topic_concept_id into v_topic_concept_id
  from knowledge.claims cl
  where cl.id = v_claim_id;

  perform knowledge.assert_publisher_authorized(v_actor_id, v_topic_concept_id);

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

create or replace function api.withdraw_claim_publication(
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
  v_claim_id uuid := p_claim_id;
  v_topic_concept_id uuid;
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

  -- Publisher-mandatet kontrolleres før alt annet, også før den idempotente
  -- no-op-en. Ellers ville en kaller uten mandat fått et svar formet som en
  -- vellykket handling, og dokumentasjonen om at handlingen krever mandat, ville
  -- vært usann for nettopp det tilfellet. Den kontrollerte operasjonen avgjør
  -- retten på nytt inne i transaksjonen; dette er ikke en erstatning for den.
  select cl.topic_concept_id into v_topic_concept_id
  from knowledge.claims cl
  where cl.id = v_claim_id;

  perform knowledge.assert_publisher_authorized(v_actor_id, v_topic_concept_id);

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

create or replace function api.rollback_claim_publication(
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
  v_claim_id uuid := p_claim_id;
  v_topic_concept_id uuid;
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

  -- Publisher-mandatet kontrolleres før alt annet, også før den idempotente
  -- no-op-en. Ellers ville en kaller uten mandat fått et svar formet som en
  -- vellykket handling, og dokumentasjonen om at handlingen krever mandat, ville
  -- vært usann for nettopp det tilfellet. Den kontrollerte operasjonen avgjør
  -- retten på nytt inne i transaksjonen; dette er ikke en erstatning for den.
  select cl.topic_concept_id into v_topic_concept_id
  from knowledge.claims cl
  where cl.id = v_claim_id;

  perform knowledge.assert_publisher_authorized(v_actor_id, v_topic_concept_id);

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

  -- Kandidaten føres gjennom, ikke revisjonen. En revisjon kan ha vært publisert
  -- som flere forskjellige innhold, og «gå tilbake til revisjonen» ville da vært
  -- tvetydig: den kontrollerte operasjonen ville valgt det gjeldende innholdet,
  -- som kan være et annet enn det flaten viste og kalleren valgte.
  v_event_id := knowledge.rollback_claim_publication(
    p_claim_id, p_target_candidate_id, v_actor_id, p_reason
  );

  return jsonb_build_object('changed', true, 'published', true)
    || knowledge.publication_event_summary(v_event_id);
end;
$$;

comment on function api.rollback_claim_publication(uuid, uuid, text, text) is
  'Ruller publiseringen tilbake til et tidligere publisert innhold for den samme påstanden (ANTIDEP_CONSTITUTION.md regel 6, DATABASE_ARCHITECTURE.md §40). En ny hendelse som peker på hva man går tilbake til og hvorfor; den gamle hendelsen skrives aldri om. Målet er den kandidaten flaten viste, med avtrykket den viste, og kandidaten føres uendret gjennom til den kontrollerte operasjonen — ikke revisjonen sin, som kan ha vært publisert som flere forskjellige innhold. Rollbacken omgår ingen gate: knowledge.rollback_claim_publication(uuid, uuid, uuid, text) krever publisher-mandat, at revisjonen faktisk har vært publisert og ligger bakover, at hele publiseringsgaten holder på nytt, at kandidaten er det gjeldende innholdet for revisjonen sin, og at nettopp det innholdet har vært vist. Publisher-mandatet kontrolleres også før den idempotente no-op-en, slik at svaret aldri er formet som en vellykket handling for en kaller uten mandat. SECURITY DEFINER med tomt search_path (§50); EXECUTE bare til authenticated.';
