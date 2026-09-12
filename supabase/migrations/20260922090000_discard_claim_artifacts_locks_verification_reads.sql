-- ============================================================================
-- Migrasjon 005ai — fjerningsveien for påstandsartefakter låser også de
-- tabellene kontrollene LESER
--
-- Funnet i teknisk review av PR #86.
--
-- ----------------------------------------------------------------------------
-- Hullet
--
-- `knowledge.discard_unpublished_claim_artifacts(uuid[], text)` (migrasjon
-- 005ah) tar `ACCESS EXCLUSIVE` på de seks tabellene den sletter fra, før den
-- første kontrollen leser noe. To av kontrollene leser likevel utenfor de seks:
--
--   * ingen MENNESKELIG evidenskontroll på funnene påstanden er lenket til
--     (`workflow.evidence_verifications`), og
--   * ingen reviewbeslutning på dem (`workflow.review_decisions`).
--
-- Begge tabellene peker på `knowledge.evidence_items`. Den tabellen rører denne
-- veien ikke — den sletter påstandssiden, ikke funnene. En innsetting i en av
-- de to trengte derfor ikke røre noen av de seks låste tabellene, og kunne
-- commite i vinduet mellom kontrollens lesing og slettingen:
--
--   Økt A   låser de seks, leser «ingen menneskelig kontroll», …
--   Økt B                     … registrerer en menneskelig kontroll, commiter
--   Økt A   … sletter lenken, revisjonen og påstanden, returnerer suksess
--
-- Utfallet er det motsatte av å feile lukket: kallet lyktes samtidig som
-- vilkåret det lover å stoppe på, var sant — og øyeblikksbildet i auditraden
-- hadde ikke kontrollen med seg.
--
-- Migrasjon 005af har ikke det samme hullet, og grunnen er ikke at den låser
-- mer: der peker begge tabellene på `knowledge.evidence_items`, som **er**
-- tabellen den sletter fra, og `on delete restrict` stopper derfor slettingen
-- framfor å la raden forsvinne med den. Beskyttelsen kom fra
-- fremmednøkkelretningen, og den retningen finnes ikke her.
--
-- ----------------------------------------------------------------------------
-- Rettelsen
--
-- De to tabellene låses i `ACCESS EXCLUSIVE` sammen med de øvrige, før den
-- første kontrollen leser. `workflow.evidence_verifications` står **først**, i
-- samme posisjon som i 005af, slik at de to fjerningsveiene ikke kan ta den
-- samme låsen i motsatt rekkefølge og låse hverandre.
--
-- Fremoverskrivende: 005ah er kjørt og registrert, og Supabase kjører aldri en
-- registrert versjon på nytt. Funksjonen gjenskapes derfor i sin helhet her,
-- med uendret signatur — så ingen grant må gjenopprettes, og PostgREST får
-- ingen overload (§74.32).
--
-- Prøves av `scripts/db-lock-test.sh`, prøve 6 og 7: to reelle forbindelser,
-- der økt B må vente. Uten låsene venter den ikke i det hele tatt.
-- ============================================================================

create or replace function knowledge.discard_unpublished_claim_artifacts(
  p_claim_ids uuid[],
  p_reason text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_actor_id uuid;
  v_id uuid;
  v_snapshots jsonb := '{}'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_citations bigint := 0;
  v_verifications bigint := 0;
  v_assessments bigint := 0;
  v_links bigint := 0;
  v_revisions bigint := 0;
  v_claims bigint := 0;
begin
  -- Fjerningen er en redaksjonell handling med en ansvarlig, ikke en
  -- driftsoperasjon: auditraden skal navngi den som bestemte den.
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Fjerningen mangler en begrunnelse, og da kan den ikke registreres.',
      hint = 'Oppgi hvorfor påstandene fjernes. Begrunnelsen er det som gjør en hard sletting rapporterbar i ettertid (ANTIDEP_CONSTITUTION.md §14).';
  end if;

  if p_claim_ids is null or cardinality(p_claim_ids) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ingen påstander er oppgitt.',
      hint = 'Veien tar en eksplisitt liste med id-er. Den kan ikke kalles med et predikat, og den kan ikke feie: hvilke rader som fjernes, skal være skrevet ned før kallet, ikke utledet av det.';
  end if;

  if cardinality(p_claim_ids) > 50 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%s påstander er oppgitt, og grensen er 50.', cardinality(p_claim_ids)),
      hint = 'En reset er en navngitt liste noen har gått gjennom. Er listen lengre enn dette, er den ikke gjennomgått.';
  end if;

  if (select count(distinct x) from unnest(p_claim_ids) as x)
     <> cardinality(p_claim_ids) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Listen inneholder samme påstand mer enn én gang.',
      hint = 'En dublett betyr at listen ikke er den gjennomgåtte listen. Rett den framfor å la kallet gjøre noe annet enn det som ble bestemt.';
  end if;

  -- ------------------------------------------------------------------------
  -- Låsen. Tas før kontrollene, slik at tilstanden de leser, er den samme
  -- tilstanden slettingen møter.
  --
  -- De to øverste er rettelsen i denne migrasjonen. Kontrollene leser
  -- `workflow.evidence_verifications` og `workflow.review_decisions` for
  -- evidensfunnene påstanden er lenket til — men begge tabellene peker på
  -- `knowledge.evidence_items`, som denne veien ikke rører. En innsetting der
  -- trengte derfor ikke røre noen av de seks låste tabellene, og kunne commite
  -- i vinduet mellom «vakten leste ingen» og slettingen. Da ville kallet
  -- returnert suksess samtidig som vilkåret det lover å feile lukket på, var
  -- sant. `on delete restrict` beskytter ikke her, i motsetning til i
  -- migrasjon 005af: der pekte de samme radene på funnet som ble slettet.
  --
  -- `workflow.evidence_verifications` står først, i samme posisjon som i
  -- 005af, slik at de to veiene ikke kan ta den samme låsen i motsatt
  -- rekkefølge. Resten er slettingens egen rekkefølge, slik at ingen lås må
  -- oppgraderes underveis.
  -- ------------------------------------------------------------------------
  lock table workflow.evidence_verifications in access exclusive mode;
  lock table workflow.review_decisions in access exclusive mode;
  lock table workflow.claim_verification_citations in access exclusive mode;
  lock table workflow.claim_verifications in access exclusive mode;
  lock table knowledge.evidence_assessments in access exclusive mode;
  lock table knowledge.claim_evidence_links in access exclusive mode;
  lock table knowledge.claim_revisions in access exclusive mode;
  lock table knowledge.claims in access exclusive mode;

  -- ------------------------------------------------------------------------
  -- Kontrollene. Alle kjøres før noe slettes, og én rad som feiler stopper
  -- hele kallet: en delvis reset ville etterlatt en tilstand ingen bestemte.
  -- ------------------------------------------------------------------------
  foreach v_id in array p_claim_ids loop
    if not exists (select 1 from knowledge.claims c where c.id = v_id) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Påstanden %s finnes ikke.', v_id),
        hint = 'Listen er ikke den databasen har. Hent tilstanden på nytt framfor å fjerne noe annet enn det som ble gjennomgått.';
    end if;

    if exists (select 1 from knowledge.claims c
               where c.id = v_id and c.current_published_revision_id is not null) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Påstanden %s er publisert, og fjernes ikke.', v_id),
        hint = 'En publisert påstand er klinisk historikk. Den trekkes tilbake gjennom knowledge.withdraw_claim_publication(...), som etterlater et spor — den slettes ikke (ANTIDEP_CONSTITUTION.md §13).';
    end if;

    -- publication_events peker på påstanden selv, ikke på revisjonen, og har
    -- `on delete restrict` mot den: en slettning ville feilet uansett. Kontrollen
    -- står her for å feile med en setning som sier hvorfor, framfor med en
    -- fremmednøkkel.
    if exists (select 1 from knowledge.publication_events pe
               where pe.claim_id = v_id) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Påstanden %s har vært publisert, og fjernes ikke.', v_id),
        hint = 'En påstand som har vært publisert, har vært klinisk innhold noen kan ha lest. Historikken om det skal bestå (§13, §14).';
    end if;

    if exists (
      select 1
      from workflow.claim_verifications cv
      join knowledge.claim_revisions cr on cr.id = cv.claim_revision_id
      join provenance.actors a on a.id = cv.verifier_actor_id
      where cr.claim_id = v_id
        and a.actor_type = 'human'
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Påstanden %s er menneskelig kontrollert, og fjernes ikke.', v_id),
        hint = 'En utført menneskelig kontroll er en faglig handling med en ansvarlig bak. Den skal ikke kunne forsvinne (ANTIDEP_CONSTITUTION.md §12, §14).';
    end if;

    if exists (
      select 1
      from workflow.evidence_verifications ev
      join knowledge.claim_evidence_links l on l.evidence_item_id = ev.evidence_item_id
      join knowledge.claim_revisions cr on cr.id = l.claim_revision_id
      join provenance.actors a on a.id = ev.verifier_actor_id
      where cr.claim_id = v_id
        and a.actor_type = 'human'
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Et evidensfunn under påstanden %s er menneskelig kildekontrollert, og påstanden fjernes ikke.', v_id),
        hint = 'Kontrollen dokumenterer hva en kontrollør faktisk fant. Å fjerne påstanden ville tatt lenken kontrollen gjaldt, med seg (§12, §14).';
    end if;

    if exists (
      select 1
      from workflow.review_decisions rd
      join knowledge.claim_evidence_links l on l.evidence_item_id = rd.evidence_item_id
      join knowledge.claim_revisions cr on cr.id = l.claim_revision_id
      where cr.claim_id = v_id
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Et evidensfunn under påstanden %s har en registrert reviewbeslutning, og påstanden fjernes ikke.', v_id),
        hint = 'En beslutning er en utført faglig handling, og tabellen er append-only av samme grunn som kontrollene.';
    end if;

    -- Øyeblikksbildet tas før slettingen, og er hele kontrollgrunnlaget: det som
    -- fjernes, skal fortsatt kunne leses av den som spør hva som sto der.
    v_snapshots := v_snapshots || jsonb_build_object(
      v_id::text,
      jsonb_build_object(
        -- `id` er påkrevd av events_snapshot_identifies_object_check.
        'id', v_id,
        'claim', (select to_jsonb(c) from knowledge.claims c where c.id = v_id),
        'revisions', (
          select coalesce(jsonb_agg(to_jsonb(cr) order by cr.revision_number), '[]'::jsonb)
          from knowledge.claim_revisions cr where cr.claim_id = v_id
        ),
        'evidence_links', (
          select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at), '[]'::jsonb)
          from knowledge.claim_evidence_links l
          join knowledge.claim_revisions cr on cr.id = l.claim_revision_id
          where cr.claim_id = v_id
        ),
        'evidence_assessments', (
          select coalesce(jsonb_agg(to_jsonb(ea) order by ea.created_at), '[]'::jsonb)
          from knowledge.evidence_assessments ea
          join knowledge.claim_revisions cr on cr.id = ea.claim_revision_id
          where cr.claim_id = v_id
        ),
        'claim_verifications', (
          select coalesce(jsonb_agg(to_jsonb(cv) order by cv.created_at), '[]'::jsonb)
          from workflow.claim_verifications cv
          join knowledge.claim_revisions cr on cr.id = cv.claim_revision_id
          where cr.claim_id = v_id
        ),
        'claim_verification_citations', (
          select coalesce(jsonb_agg(to_jsonb(cc)), '[]'::jsonb)
          from workflow.claim_verification_citations cc
          join workflow.claim_verifications cv on cv.id = cc.claim_verification_id
          join knowledge.claim_revisions cr on cr.id = cv.claim_revision_id
          where cr.claim_id = v_id
        )
      )
    );
  end loop;

  -- ------------------------------------------------------------------------
  -- Slettingen. Append-only-vernet er fasiten for enhver annen skrivevei, og
  -- skrus av bare her, bare i denne transaksjonen, og slås på igjen også når
  -- noe går galt. Rekkefølgen er gitt av fremmednøklene, som alle er RESTRICT.
  -- ------------------------------------------------------------------------
  begin
    -- Samme grunn som i 005af: ALTER TABLE kan ikke kjøre på en tabell med
    -- utsatte triggerhendelser i kø. Modusen settes tilbake etterpå, også når
    -- noe går galt, slik at en lovlig registrering senere i den samme
    -- transaksjonen ikke blir kontrollert før forankringen sin er skrevet.
    set constraints all immediate;

    alter table workflow.claim_verification_citations disable trigger claim_verification_citations_reject_mutation;
    alter table workflow.claim_verifications disable trigger claim_verifications_reject_mutation;
    alter table knowledge.evidence_assessments disable trigger evidence_assessments_reject_mutation;
    alter table knowledge.claim_evidence_links disable trigger claim_evidence_links_reject_mutation;
    alter table knowledge.claim_revisions disable trigger claim_revisions_reject_mutation;

    delete from workflow.claim_verification_citations cc
    where cc.claim_verification_id in (
      select cv.id from workflow.claim_verifications cv
      join knowledge.claim_revisions cr on cr.id = cv.claim_revision_id
      where cr.claim_id = any(p_claim_ids)
    );
    get diagnostics v_citations = row_count;

    delete from workflow.claim_verifications cv
    where cv.claim_revision_id in (
      select cr.id from knowledge.claim_revisions cr where cr.claim_id = any(p_claim_ids)
    );
    get diagnostics v_verifications = row_count;

    delete from knowledge.evidence_assessments ea
    where ea.claim_revision_id in (
      select cr.id from knowledge.claim_revisions cr where cr.claim_id = any(p_claim_ids)
    );
    get diagnostics v_assessments = row_count;

    delete from knowledge.claim_evidence_links l
    where l.claim_revision_id in (
      select cr.id from knowledge.claim_revisions cr where cr.claim_id = any(p_claim_ids)
    );
    get diagnostics v_links = row_count;

    delete from knowledge.claim_revisions cr where cr.claim_id = any(p_claim_ids);
    get diagnostics v_revisions = row_count;

    delete from knowledge.claims c where c.id = any(p_claim_ids);
    get diagnostics v_claims = row_count;

    -- Slettingene setter selv hendelser i kø: fremmednøklene mellom de seks
    -- tabellene er utsatte, og en slettet forelder legger igjen en RI-kontroll
    -- som skal kjøre ved commit. `ALTER TABLE` kan ikke kjøre med hendelser i
    -- kø, så køen tømmes her — kontrollene passerer, fordi begge sider av hver
    -- nøkkel er borte.
    set constraints all immediate;

    alter table knowledge.claim_revisions enable trigger claim_revisions_reject_mutation;
    alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_mutation;
    alter table knowledge.evidence_assessments enable trigger evidence_assessments_reject_mutation;
    alter table workflow.claim_verifications enable trigger claim_verifications_reject_mutation;
    alter table workflow.claim_verification_citations enable trigger claim_verification_citations_reject_mutation;
    set constraints all deferred;
  exception
    when others then
      alter table knowledge.claim_revisions enable trigger claim_revisions_reject_mutation;
      alter table knowledge.claim_evidence_links enable trigger claim_evidence_links_reject_mutation;
      alter table knowledge.evidence_assessments enable trigger evidence_assessments_reject_mutation;
      alter table workflow.claim_verifications enable trigger claim_verifications_reject_mutation;
      alter table workflow.claim_verification_citations enable trigger claim_verification_citations_reject_mutation;
      set constraints all deferred;
      raise;
  end;

  if v_claims <> cardinality(p_claim_ids) then
    -- Kan i praksis ikke skje: eksistensen er kontrollert over, og
    -- transaksjonen har holdt låsen siden før kontrollene.
    raise exception using
      errcode = 'restrict_violation',
      message = format('%s av %s påstander ble fjernet. Ingenting er lagret.',
                       v_claims, cardinality(p_claim_ids));
  end if;

  -- ------------------------------------------------------------------------
  -- Sporet. Én rad per fjernet påstand, med det som sto der.
  -- ------------------------------------------------------------------------
  foreach v_id in array p_claim_ids loop
    insert into audit.events
      (operation, object_id, actor_id, old_revision_or_snapshot, reason, occurred_at)
    values
      ('claim_artifact_discarded', v_id, v_actor_id,
       v_snapshots -> v_id::text, btrim(p_reason), now());
    v_removed := v_removed || to_jsonb(v_id::text);
  end loop;

  return jsonb_build_object(
    'discarded_claim_ids', v_removed,
    'deleted_claim_revisions', v_revisions,
    'deleted_evidence_links', v_links,
    'deleted_evidence_assessments', v_assessments,
    'deleted_claim_verifications', v_verifications,
    'deleted_claim_verification_citations', v_citations,
    'discarded_by_actor_id', v_actor_id,
    'reason', btrim(p_reason)
  );
end;
$$;

comment on function knowledge.discard_unpublished_claim_artifacts(uuid[], text) is
  'Den ene, sterkt guardede veien til å fjerne et upublisert påstandsartefakt med revisjonene, lenkene, vurderingene og kontrollene sine. Uendret fra migrasjon 005ah bortsett fra låsene: workflow.evidence_verifications og workflow.review_decisions låses nå også, fordi kontrollene LESER dem og ingen fremmednøkkel peker fra dem mot noe denne veien sletter. Uten det kunne en menneskelig evidenskontroll eller en reviewbeslutning commite i vinduet mellom kontrollens lesing og slettingen, og kallet ville returnert suksess samtidig som vilkåret det lover å feile lukket på, var sant (funnet i teknisk review av PR #86). workflow.evidence_verifications låses først, i samme posisjon som i migrasjon 005af, slik at de to fjerningsveiene ikke kan ta den samme låsen i motsatt rekkefølge. Ikke en redaksjonell funksjon: EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle.';

revoke execute on function knowledge.discard_unpublished_claim_artifacts(uuid[], text) from public;
