-- ============================================================================
-- Migrasjon 005af — den ene, sterkt guardede veien til å fjerne et testartefakt
--
-- Antidep sletter ikke klinisk historikk. Hver kunnskaps- og kontrolltabell er
-- append-only, håndhevet av en BEFORE DELETE OR UPDATE-trigger, og det er en
-- av de bærende invariantene: en utført kontroll dokumenterer hva verifikatoren
-- faktisk fant på det tidspunktet, og en forankring dokumenterer hvilket
-- kildeutdrag ekstraksjonen hvilte på (ANTIDEP_CONSTITUTION.md §13, §14,
-- CLAUDE.md: «Normal editorial workflows must not physically delete clinically
-- relevant history»).
--
-- ----------------------------------------------------------------------------
-- Hvorfor det likevel finnes en vei, og hva den koster
--
-- Pipelinen bygges fortsatt, og den har produsert evidensfunn som ikke kan
-- kontrolleres. `pdftotext -layout` la tekst fra to spalter på den samme
-- tekstlinjen, og fulltekstfunnene som er registrert med den representasjonen,
-- hviler på en leserekkefølge ingen kan stole på (migrasjon 003g, issue #84).
-- Å la dem stå i kontrollkøen er ikke det forsiktige valget: det er å invitere
-- en kliniker til å gjøre den faglige kildekontrollen på et grunnlag issue #84
-- selv sier ikke holder.
--
-- Alternativet til en guardet funksjon er ikke «ingen sletting». Den som eier
-- databasen, kan skru av en trigger og slette hva som helst uten et spor.
-- Funksjonen **innskrenker** derfor en operasjon eieren allerede kan gjøre
-- ukontrollert — den utvider ingen rettighet:
--
--   * EXECUTE er revokert fra PUBLIC og gitt til **ingen** klientrolle. Verken
--     anon, authenticated eller service_role kan kalle den. Den er nåbar bare
--     for den som allerede har eiertilgang til databasen.
--   * Den krever i tillegg en autorisert redaktøridentitet
--     (knowledge.assert_editor_authorized), slik at fjerningen attribueres til
--     den som faktisk bestemte den — ikke til «databasen».
--   * Den tar en **eksplisitt liste** med id-er og en begrunnelse. Den kan ikke
--     kalles med et predikat, og den kan ikke feie.
--   * Den feiler **lukket** på hver rad som har kommet lenger i livssyklusen:
--     en menneskelig kontroll, en påstandslenke, en reviewbeslutning eller et
--     sitat i en claim-verifikasjon stopper hele kallet, og ingenting slettes.
--   * Den skriver en auditrad per fjernet funn, med hele kontrollgrunnlaget som
--     `old_revision_or_snapshot`. Det som ble fjernet, er dermed fortsatt
--     rapporterbart (§14) — det er raden som er borte, ikke sporet av den.
--
-- ----------------------------------------------------------------------------
-- Hva den ikke rører
--
-- Kilder, originaldokumenter, kildeversjoner, agentkjøringer og auditrader. En
-- kildeversjon er et øyeblikksbilde av en kilde og har verdi uavhengig av hvilke
-- funn som ble laget av den; å slette den for å få en fremmednøkkel til å gå
-- opp, ville vært å kaste uavhengig kildehistorikk.
--
-- ----------------------------------------------------------------------------
-- Hvorfor triggerne skrus av og på inne i funksjonen
--
-- Append-only-triggerne er fasiten for enhver annen skrivevei, og skal ikke
-- svekkes. Alternativet — å la triggeren godta en delete når et
-- sesjonsflagg er satt — ville gjort en hard garanti om til en garanti som
-- hviler på at ingen andre kan sette flagget. `ALTER TABLE ... DISABLE TRIGGER`
-- tar ACCESS EXCLUSIVE på tabellen, gjelder bare inne i denne transaksjonen, og
-- rulles tilbake med den. En exception-håndterer slår dem på igjen før den
-- kaster videre, slik at en avbrutt kjøring aldri etterlater en tabell uten sitt
-- vern.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §8, §13, §14, §15
--   docs/DATABASE_ARCHITECTURE.md §35, §36, §43, §50
--   issue #84
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Auditvokabularet dekker den nye operasjonen
--
-- De to genererte kolonnene og formkontrollen er uttømmende CASE-uttrykk med
-- `ELSE NULL` og `ELSE false`: en operasjon som ikke står i dem, kan ikke bli en
-- auditrad. Begge slippes og lages på nytt, slik migrasjon 008b sin etterfølger
-- gjorde — en generert kolonne kan ikke endres i stedet.
--
-- Fjerningen er den første operasjonen der det finnes et **før** og ingen
-- **etter**: `old_revision_or_snapshot` bærer det som ble fjernet, og
-- `new_revision_or_snapshot` er NULL fordi det ikke finnes en ny tilstand.
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
      else false
    end
  );

comment on constraint events_snapshot_shape_check on audit.events is
  'Hvilke øyeblikksbilder hver operasjon skal bære (DATABASE_ARCHITECTURE.md §35). Uttømmende CASE med ELSE false: en ny operasjon uten sin egen gren kan ikke bli en auditrad, og det er tilsiktet — en auditrad uten det øyeblikksbildet operasjonen forutsetter, ville sett ut som et spor uten å være et. En opprettelse har bare et etter, en endring har begge, og en fjerning (extraction_artifact_discarded, migrasjon 005af) har bare et før.';

-- ----------------------------------------------------------------------------
-- 2. Funksjonen
-- ----------------------------------------------------------------------------
create function knowledge.discard_unpublished_extraction_artifacts(
  p_evidence_item_ids uuid[],
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
  v_verifications bigint := 0;
  v_groundings bigint := 0;
  v_items bigint := 0;
begin
  -- Fjerningen er en redaksjonell handling med en ansvarlig, ikke en
  -- driftsoperasjon: auditraden skal navngi den som bestemte den.
  v_actor_id := knowledge.assert_editor_authorized();

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Fjerningen mangler en begrunnelse, og da kan den ikke registreres.',
      hint = 'Oppgi hvorfor funnene fjernes. Begrunnelsen er det som gjør en hard sletting rapporterbar i ettertid (ANTIDEP_CONSTITUTION.md §14).';
  end if;

  if p_evidence_item_ids is null or cardinality(p_evidence_item_ids) = 0 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Ingen evidensfunn er oppgitt.',
      hint = 'Veien tar en eksplisitt liste med id-er. Den kan ikke kalles med et predikat, og den kan ikke feie: hvilke rader som fjernes, skal være skrevet ned før kallet, ikke utledet av det.';
  end if;

  if cardinality(p_evidence_item_ids) > 50 then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('%s evidensfunn er oppgitt, og grensen er 50.', cardinality(p_evidence_item_ids)),
      hint = 'En reset er en navngitt liste noen har gått gjennom. Er listen lengre enn dette, er den ikke gjennomgått.';
  end if;

  if (select count(distinct x) from unnest(p_evidence_item_ids) as x)
     <> cardinality(p_evidence_item_ids) then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = 'Listen inneholder samme evidensfunn mer enn én gang.',
      hint = 'En dublett betyr at listen ikke er den gjennomgåtte listen. Rett den framfor å la kallet gjøre noe annet enn det som ble bestemt.';
  end if;

  -- ------------------------------------------------------------------------
  -- Kontrollene. Alle kjøres før noe slettes, og én rad som feiler stopper
  -- hele kallet: en delvis reset ville etterlatt en tilstand ingen bestemte.
  -- ------------------------------------------------------------------------
  foreach v_id in array p_evidence_item_ids loop
    if not exists (select 1 from knowledge.evidence_items e where e.id = v_id) then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('Evidensfunnet %s finnes ikke.', v_id),
        hint = 'Listen er ikke den databasen har. Hent køen på nytt framfor å fjerne noe annet enn det som ble gjennomgått.';
    end if;

    if exists (
      select 1
      from workflow.evidence_verifications ev
      join provenance.actors a on a.id = ev.verifier_actor_id
      where ev.evidence_item_id = v_id
        and a.actor_type = 'human'
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s er menneskelig kildekontrollert, og fjernes ikke.', v_id),
        hint = 'En utført menneskelig kontroll er en faglig handling med en ansvarlig bak. Den skal ikke kunne forsvinne (ANTIDEP_CONSTITUTION.md §12, §14).';
    end if;

    if exists (select 1 from knowledge.claim_evidence_links l where l.evidence_item_id = v_id) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s bærer en påstandsrevisjon, og fjernes ikke.', v_id),
        hint = 'Funnet er lenket til en claim-revisjon. Å fjerne det ville gjort revisjonen til en påstand uten det grunnlaget den ble laget av — publisert eller ikke (ANTIDEP_CONSTITUTION.md §4, §8).';
    end if;

    if exists (select 1 from workflow.review_decisions rd where rd.evidence_item_id = v_id) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s har en registrert reviewbeslutning, og fjernes ikke.', v_id),
        hint = 'En beslutning er en utført faglig handling, og tabellen er append-only av samme grunn som kontrollene.';
    end if;

    if exists (
      select 1 from workflow.claim_verification_citations c where c.evidence_item_id = v_id
    ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format('Evidensfunnet %s er sitert i en claim-verifikasjon, og fjernes ikke.', v_id),
        hint = 'Kontrollen registrerte hva den faktisk leste. Å fjerne funnet ville skrevet om den nedtegnelsen.';
    end if;

    -- Øyeblikksbildet tas før slettingen, og er hele kontrollgrunnlaget: det som
    -- fjernes, skal fortsatt kunne leses av den som spør hva som sto der.
    v_snapshots := v_snapshots || jsonb_build_object(
      v_id::text,
      jsonb_build_object(
        -- `id` er påkrevd av events_snapshot_identifies_object_check: et
        -- øyeblikksbilde skal navngi objektet raden handler om, slik at det
        -- ikke kan havne på feil objekt.
        'id', v_id,
        'dossier', workflow.evidence_extraction_dossier(v_id),
        'extraction_verifications', (
          select coalesce(jsonb_agg(to_jsonb(ev) order by ev.created_at), '[]'::jsonb)
          from workflow.evidence_verifications ev
          where ev.evidence_item_id = v_id
        )
      )
    );
  end loop;

  -- ------------------------------------------------------------------------
  -- Slettingen. Append-only-vernet er fasiten for enhver annen skrivevei, og
  -- skrus av bare her, bare i denne transaksjonen, og slås på igjen også når
  -- noe går galt.
  -- ------------------------------------------------------------------------
  begin
    -- `ALTER TABLE` kan ikke kjøre på en tabell med utsatte triggerhendelser i
    -- kø, og forankringskontrollen på knowledge.evidence_items er utsatt til
    -- commit (migrasjon 003d). I en reset som kjører alene er køen tom og
    -- setningen en nulloperasjon; ligger det en registrering foran i den samme
    -- transaksjonen, kjøres kontrollen av den nå — og en registrering som ikke
    -- holder, stopper fjerningen framfor å bli commitet etter den.
    --
    -- Modusen settes tilbake etterpå, også når noe går galt. Uten det ville en
    -- registrering *senere* i den samme transaksjonen blitt kontrollert før
    -- forankringen sin var skrevet, og en lovlig registrering ville blitt
    -- avvist av et valg denne funksjonen gjorde.
    set constraints all immediate;

    alter table workflow.evidence_verifications disable trigger evidence_verifications_reject_mutation;
    alter table knowledge.evidence_field_groundings disable trigger evidence_field_groundings_reject_mutation;
    alter table knowledge.evidence_items disable trigger evidence_items_reject_mutation;

    delete from workflow.evidence_verifications ev
    where ev.evidence_item_id = any(p_evidence_item_ids);
    get diagnostics v_verifications = row_count;

    delete from knowledge.evidence_field_groundings g
    where g.evidence_item_id = any(p_evidence_item_ids);
    get diagnostics v_groundings = row_count;

    delete from knowledge.evidence_items e
    where e.id = any(p_evidence_item_ids);
    get diagnostics v_items = row_count;

    alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;
    alter table knowledge.evidence_field_groundings enable trigger evidence_field_groundings_reject_mutation;
    alter table workflow.evidence_verifications enable trigger evidence_verifications_reject_mutation;
    set constraints all deferred;
  exception
    when others then
      alter table knowledge.evidence_items enable trigger evidence_items_reject_mutation;
      alter table knowledge.evidence_field_groundings enable trigger evidence_field_groundings_reject_mutation;
      alter table workflow.evidence_verifications enable trigger evidence_verifications_reject_mutation;
      set constraints all deferred;
      raise;
  end;

  if v_items <> cardinality(p_evidence_item_ids) then
    -- Kan i praksis ikke skje: eksistensen er kontrollert over, og
    -- transaksjonen holder låsen. En påstand som ikke kontrolleres, er likevel
    -- ikke en påstand noen kan stole på.
    raise exception using
      errcode = 'restrict_violation',
      message = format('%s av %s evidensfunn ble fjernet. Ingenting er lagret.',
                       v_items, cardinality(p_evidence_item_ids));
  end if;

  -- ------------------------------------------------------------------------
  -- Sporet. Én rad per fjernet funn, med det som sto der.
  -- ------------------------------------------------------------------------
  foreach v_id in array p_evidence_item_ids loop
    insert into audit.events
      (operation, object_id, actor_id, old_revision_or_snapshot, reason, occurred_at)
    values
      ('extraction_artifact_discarded', v_id, v_actor_id,
       v_snapshots -> v_id::text, btrim(p_reason), now());
    v_removed := v_removed || to_jsonb(v_id::text);
  end loop;

  return jsonb_build_object(
    'discarded_evidence_item_ids', v_removed,
    'deleted_extraction_verifications', v_verifications,
    'deleted_field_groundings', v_groundings,
    'discarded_by_actor_id', v_actor_id,
    'reason', btrim(p_reason)
  );
end;
$$;

comment on function knowledge.discard_unpublished_extraction_artifacts(uuid[], text) is
  'Fjerner et eksplisitt oppgitt sett upubliserte evidensfunn med sine forankringer og maskinelle kontroller, i én transaksjon, og skriver en auditrad per funn med hele kontrollgrunnlaget som old_revision_or_snapshot (migrasjon 005af, issue #84). Finnes fordi pipelinen fortsatt bygges: fulltekstfunn registrert med den forrige oppskriften hviler på en representasjon der tekst fra to spalter lå på samme tekstlinje, og å la dem stå i kontrollkøen ville invitert en kliniker til å gjøre den faglige kildekontrollen på et grunnlag som ikke holder (migrasjon 003g). Dette er IKKE en redaksjonell funksjon: EXECUTE er revokert fra PUBLIC og gitt til ingen klientrolle, så den er nåbar bare for den som allerede har eiertilgang til databasen — og den innskrenker dermed en operasjon eieren ellers kunne gjort uten spor, framfor å utvide noen rettighet. Krever i tillegg en autorisert redaktøridentitet (knowledge.assert_editor_authorized(uuid), kalt uten begrep) og en begrunnelse. Feiler lukket, og uten å slette noe, dersom ett av funnene er menneskelig kildekontrollert, bærer en påstandslenke, har en registrert reviewbeslutning eller er sitert i en claim-verifikasjon; en id som ikke finnes, en dublett, en tom liste og en liste over 50 avvises på samme måte. Kilder, originaldokumenter, kildeversjoner, agentkjøringer og auditrader røres ikke: en kildeversjon er et øyeblikksbilde med verdi uavhengig av hvilke funn som ble laget av den. Append-only-triggerne på de tre tabellene skrus av og på inne i transaksjonen, også når noe går galt, slik at vernet aldri står av utenfor dette kallet. SECURITY DEFINER fordi knowledge, workflow, provenance og audit har RLS med default deny, og fordi ALTER TABLE ... DISABLE TRIGGER krever eierskap; tomt search_path.';

revoke execute on function knowledge.discard_unpublished_extraction_artifacts(uuid[], text) from public;

commit;
