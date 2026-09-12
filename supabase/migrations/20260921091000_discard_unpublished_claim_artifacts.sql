-- ============================================================================
-- Migrasjon 005ah — den guardede veien til å fjerne et testartefakt på
-- påstandssiden
--
-- Søsteren til 005af. Den fjernet evidensfunnet; denne fjerner påstanden som
-- ble laget av det: påstandsrevisjonen, påstandslenken, evidensvurderingen,
-- claim-verifikasjonen og sitatet.
--
-- ----------------------------------------------------------------------------
-- Hvorfor den finnes
--
-- 005af feiler med vilje lukket på et funn som bærer en påstandslenke eller er
-- sitert i en claim-verifikasjon, og det skal den fortsette å gjøre: å fjerne et
-- funn under en påstand ville gjort påstanden til en klinisk opplysning uten det
-- grunnlaget den ble laget av (ANTIDEP_CONSTITUTION.md §4, §8).
--
-- Men da står man igjen med to tilstander, og ingen av dem er den man vil ha:
-- funnet blir stående i kontrollkøen som om det kunne kontrolleres, eller
-- påstanden blir stående uten grunnlag. Veien ut er å fjerne **hele opphenget**,
-- i riktig rekkefølge, med det samme sporet — ikke å løsne 005af sin kontroll.
-- Denne funksjonen er derfor et tillegg til den, ikke en erstatning: 005af rører
-- ikke påstandssiden, og denne rører ikke evidensfunnene. Skal begge bort, kalles
-- de etter hverandre, og rekkefølgen er gitt av fremmednøklene.
--
-- ----------------------------------------------------------------------------
-- Hva den koster, og hva som begrenser den
--
-- Det samme som 005af, punkt for punkt:
--
--   * EXECUTE er revokert fra PUBLIC og gitt til **ingen** klientrolle. Verken
--     anon, authenticated eller service_role kan kalle den. Den er nåbar bare
--     for den som allerede har eiertilgang til databasen — og innskrenker
--     dermed en operasjon eieren ellers kunne gjort uten spor.
--   * Den krever en autorisert redaktøridentitet
--     (knowledge.assert_editor_authorized) og en begrunnelse.
--   * Den tar en **eksplisitt liste** med claim-id-er. Ikke et predikat, ingen
--     feiing, maks 50.
--   * Den feiler **lukket**, uten å fjerne noe, dersom påstanden er publisert
--     nå eller har vært det, eller dersom noe i opphenget er kontrollert av et
--     **menneske**. En publisert påstand er klinisk historikk, og en utført
--     menneskelig kontroll er en faglig handling med en ansvarlig bak: ingen av
--     dem skal kunne forsvinne (§12, §13, §14).
--   * Den skriver en auditrad per fjernet påstand, med hele opphenget som
--     `old_revision_or_snapshot`. Det er raden som er borte, ikke sporet av den.
--
-- ----------------------------------------------------------------------------
-- Hva den ikke rører
--
-- Evidensfunn, forankringer, maskinelle evidenskontroller, kilder,
-- kildeversjoner, originaldokumenter, agentkjøringer, katalogen og auditrader.
-- Legemidlene og begrepene påstanden pekte på, er uavhengige data.
--
-- ----------------------------------------------------------------------------
-- Låsen før kontrollene
--
-- Som i 005af, og av samme grunn: kontrollene skal lese den tilstanden
-- fjerningen møter. En publisering eller en menneskelig kontroll commitet
-- mellom lesningen og slettingen ville ellers blitt lest som fraværende og så
-- fjernet — det motsatte av å feile lukket. De seks tabellene låses i ACCESS
-- EXCLUSIVE før den første kontrollen, i den rekkefølgen slettingen bruker.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Auditvokabularet dekker den nye operasjonen
--
-- Verdien selv kom i 008j, som må ha commitet før den kan brukes her. De to
-- genererte kolonnene og formkontrollen er uttømmende CASE-uttrykk med ELSE
-- NULL og ELSE false, og må derfor bygges om for å slippe den gjennom. En
-- generert kolonne kan ikke endres, så begge slippes og lages på nytt.
-- ----------------------------------------------------------------------------
alter table audit.events drop column object_schema;
alter table audit.events drop column object_table;

alter table audit.events add column object_schema text not null generated always as (
  case operation
    when 'claim_published' then 'knowledge'
    when 'claim_publication_replaced' then 'knowledge'
    when 'claim_publication_withdrawn' then 'knowledge'
    when 'claim_publication_rolled_back' then 'knowledge'
    when 'role_granted' then 'workflow'
    when 'role_ended' then 'workflow'
    when 'source_created' then 'knowledge'
    when 'evidence_item_created' then 'knowledge'
    when 'agent_identity_registered' then 'provenance'
    when 'agent_identity_credential_issued' then 'provenance'
    when 'agent_identity_revoked' then 'provenance'
    when 'evidence_verification_registered' then 'workflow'
    when 'source_version_registered' then 'knowledge'
    when 'claim_verification_registered' then 'workflow'
    when 'review_decision_registered' then 'workflow'
    when 'evidence_field_grounding_recorded' then 'knowledge'
    when 'extraction_artifact_discarded' then 'knowledge'
    when 'claim_artifact_discarded' then 'knowledge'
    else null
  end
) stored;

alter table audit.events add column object_table text not null generated always as (
  case operation
    when 'claim_published' then 'claims'
    when 'claim_publication_replaced' then 'claims'
    when 'claim_publication_withdrawn' then 'claims'
    when 'claim_publication_rolled_back' then 'claims'
    when 'role_granted' then 'user_roles'
    when 'role_ended' then 'user_roles'
    when 'source_created' then 'sources'
    when 'evidence_item_created' then 'evidence_items'
    when 'agent_identity_registered' then 'agent_identities'
    when 'agent_identity_credential_issued' then 'agent_identities'
    when 'agent_identity_revoked' then 'agent_identities'
    when 'evidence_verification_registered' then 'evidence_verifications'
    when 'source_version_registered' then 'source_versions'
    when 'claim_verification_registered' then 'claim_verifications'
    when 'review_decision_registered' then 'review_decisions'
    when 'evidence_field_grounding_recorded' then 'evidence_field_groundings'
    when 'extraction_artifact_discarded' then 'evidence_items'
    when 'claim_artifact_discarded' then 'claims'
    else null
  end
) stored;

comment on column audit.events.object_schema is
  'Schemaet objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen framfor oppgitt av kalleren: en kaller som kunne skrive det selv, kunne skrevet feil, og en auditrad som peker på et annet objekt enn den beskriver, er verre enn ingen auditrad. Uttrykket er uttømmende med ELSE NULL, og en ny operasjon uten sin gren feiler derfor på NOT NULL framfor å bli en rad uten sted.';
comment on column audit.events.object_table is
  'Tabellen objektet ligger i (DATABASE_ARCHITECTURE.md §35). Avledet av operasjonen, med samme begrunnelse som object_schema.';

-- Indeksen henger på de to kolonnene og forsvant med dem. Navnet er det samme
-- som før, fordi supabase/tests/300_audit_structure_test.sql kontrollerer at
-- oppslagsveien loggen finnes for, er indeksert — under sitt navn.
create index events_object_occurred_at_idx
  on audit.events (object_schema, object_table, object_id, occurred_at desc);

alter table audit.events drop constraint events_snapshot_shape_check;
alter table audit.events add constraint events_snapshot_shape_check
  check (
    case operation
      when 'claim_published' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_replaced' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_withdrawn' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'claim_publication_rolled_back' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'role_granted' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'role_ended' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'source_created' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'evidence_item_created' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'agent_identity_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'agent_identity_credential_issued' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'agent_identity_revoked' then old_revision_or_snapshot is not null and new_revision_or_snapshot is not null
      when 'evidence_verification_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'source_version_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'claim_verification_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'review_decision_registered' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      when 'evidence_field_grounding_recorded' then old_revision_or_snapshot is null and new_revision_or_snapshot is not null
      -- Fjerningen: det finnes et før og ingen etter (migrasjon 005af).
      when 'extraction_artifact_discarded' then old_revision_or_snapshot is not null and new_revision_or_snapshot is null
      -- Påstandssidens fjerning, med den samme formen (migrasjon 005ah).
      when 'claim_artifact_discarded' then old_revision_or_snapshot is not null and new_revision_or_snapshot is null
      else false
    end
  );

comment on constraint events_snapshot_shape_check on audit.events is
  'Hvilke øyeblikksbilder hver operasjon skal bære (DATABASE_ARCHITECTURE.md §35). Uttømmende CASE med ELSE false: en ny operasjon uten sin egen gren kan ikke bli en auditrad, og det er tilsiktet — en auditrad uten det øyeblikksbildet operasjonen forutsetter, ville sett ut som et spor uten å være et. En opprettelse har bare et etter, en endring har begge, og en fjerning (extraction_artifact_discarded i migrasjon 005af, claim_artifact_discarded i 005ah) har bare et før.';

-- ----------------------------------------------------------------------------
-- 2. Funksjonen
-- ----------------------------------------------------------------------------
create function knowledge.discard_unpublished_claim_artifacts(
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
  -- tilstanden slettingen møter. Rekkefølgen er slettingens egen, slik at
  -- ingen lås må oppgraderes underveis.
  -- ------------------------------------------------------------------------
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
  'Fjerner et eksplisitt oppgitt sett upubliserte påstander med hele opphenget sitt — revisjoner, påstandslenker, evidensvurderinger, claim-verifikasjoner og sitater — i én transaksjon, og skriver en auditrad per påstand med alt som sto der som old_revision_or_snapshot (migrasjon 005ah, issue #84). Søsteren til knowledge.discard_unpublished_extraction_artifacts(uuid[], text): den fjerner evidensfunnene, denne fjerner påstandssiden, og ingen av dem rører den andres tabeller. Finnes fordi 005af med vilje feiler lukket på et funn som bærer en påstandslenke eller er sitert i en claim-verifikasjon: da står man igjen med enten et funn som blir stående i kontrollkøen som om det kunne kontrolleres, eller en påstand uten det grunnlaget den ble laget av. Veien ut er å fjerne hele opphenget i riktig rekkefølge med det samme sporet, ikke å løsne kontrollen i 005af. Dette er IKKE en redaksjonell funksjon: EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle, så den er nåbar bare for den som allerede har eiertilgang til databasen — og den innskrenker dermed en operasjon eieren ellers kunne gjort uten spor, framfor å utvide noen rettighet. Krever i tillegg en autorisert redaktøridentitet (knowledge.assert_editor_authorized(uuid), kalt uten begrep) og en begrunnelse. Feiler lukket, og uten å fjerne noe, dersom påstanden er publisert nå, har vært publisert, er menneskelig kontrollert, har et menneskelig kildekontrollert evidensfunn under seg, eller har et funn med en registrert reviewbeslutning; en id som ikke finnes, en dublett, en tom liste og en liste over 50 avvises på samme måte. Evidensfunn, forankringer, maskinelle evidenskontroller, kilder, kildeversjoner, originaldokumenter, agentkjøringer, katalogen og auditrader røres ikke. De seks tabellene låses i ACCESS EXCLUSIVE før kontrollene kjører, ikke først ved slettingen, slik at tilstanden kontrollene leser, er den samme tilstanden slettingen møter. Append-only-triggerne skrus av og på inne i transaksjonen, også når noe går galt. SECURITY DEFINER fordi knowledge, workflow, provenance og audit har RLS med default deny, og fordi ALTER TABLE ... DISABLE TRIGGER krever eierskap; tomt search_path.';

revoke execute on function knowledge.discard_unpublished_claim_artifacts(uuid[], text) from public;

commit;
