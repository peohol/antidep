-- ============================================================================
-- Migrasjon 005ap — evidensvurderingens opphav blir et publiseringsvilkår
--
-- Migrasjon 005am flyttet evidensvurderingen ut i sitt eget ledd, med sin egen
-- rolle. Den gjorde ikke noe med de vurderingene som allerede var skrevet av
-- **feil** rolle, og teknisk review fant hullet det etterlot:
--
--   Revisjon 24aefcd7 har en GRADE-vurdering laget av `agent:claim-synthesis`
--   gjennom den gamle veien. Publiseringsgatens G10 kontrollerer bare at en
--   vurdering *finnes*. Revisjonen stopper i dag på G8, fordi den mangler en
--   claim-verifikasjon — men det er ingen permanent sperre. En reviewer kan
--   åpne den i /review, registrere kontrollen som mangler, og deretter godkjenne
--   og publisere den. Da ville den gamle, feilaktig produserte vurderingen
--   tilfredsstilt G10, og den ordinære flaten ville endt med å publisere
--   nøyaktig det artefaktet 005am ble laget for å erstatte.
--
-- 004b sin hodekommentar sier at den raden «ryddes gjennom prosjektets egen
-- discard-vei». **Det er ikke lenger sant, og det er hele grunnen til at denne
-- migrasjonen finnes.** `knowledge.discard_unpublished_claim_artifacts(uuid[], text)`
-- avviser å fjerne påstanden, fordi et evidensfunn under den er menneskelig
-- kildekontrollert:
--
--   «Et evidensfunn under påstanden cfd99886… er menneskelig kildekontrollert,
--   og påstanden fjernes ikke.»
--
-- Vakten er riktig og er ikke rørt. Korreksjonsveien ble derfor en **ny
-- revisjon** som viderefører den gamle (c6b5dd39). Den gamle raden består som
-- historikk — men den skal ikke kunne bære en publisering.
--
-- ----------------------------------------------------------------------------
-- Vilkåret: den som gjorde vurderingen, må ha hatt mandat til det
--
-- `workflow.assessment_author_has_mandate(uuid, uuid, timestamptz)` er formet
-- som `workflow.claim_verifier_has_mandate(...)` og
-- `workflow.evidence_verifier_has_mandate(...)`, og leses av gaten som G10b —
-- speilbildet av G5c og G9c:
--
--   * en **agent** har mandatet gjennom rollen sin, og bare gjennom den:
--     `evidence_assessment` og ingen annen. Det er dette vilkåret den gamle
--     raden faller på — `agent:claim-synthesis` har rollen `claim_synthesis`.
--   * et **menneske** har det gjennom en gyldig `editor`-tildeling som dekker
--     påstandens kliniske tema. En evidensvurdering er redaksjonelt innhold
--     noen forfatter, ikke en kontroll noen utfører, og `editor` er rollen den
--     modellen bruker for å skrive kunnskapsobjekter
--     (`knowledge.assert_editor_authorized(uuid)`).
--   * ingen annen aktørtype kan gjøre en evidensvurdering. En deterministisk
--     prosess, en import eller en systemaktør har ingen faglig vurdering å
--     registrere (ANTIDEP_CONSTITUTION.md §12).
--
-- Tidspunktet er radens eget `assessed_at`, ikke `now()`: en rolletildeling som
-- senere avsluttes, opphever ikke en vurdering som var legitim da den ble gjort.
-- Historikken består (§14).
--
-- ----------------------------------------------------------------------------
-- Hvorfor vilkåret ikke også krever en peker til kjøringen
--
-- 004b ga vurderingen `agent_run_id` med de to sammensatte fremmednøklene mot
-- `provenance.agent_runs`. En rad med en peker er dermed allerede deklarativt
-- bundet til en kjøring i rollen `evidence_assessment`, eid av nøyaktig den
-- aktøren raden attribueres til — og `api.register_evidence_assessment(...)`,
-- som er den eneste veien en klient kan skrive en vurdering på, setter alltid
-- pekeren.
--
-- En vurdering med riktig rolle og tom peker kan derfor bare oppstå gjennom en
-- migrasjon eller direkte SQL som eier av basen, og begge deler er utenfor den
-- sanksjonerte arbeidsmåten (ANTIDEP_CONSTITUTION.md §15). Å gjøre pekeren til
-- et publiseringsvilkår ville i tillegg krevd at hver prøvefikstur som bygger en
-- publiserbar revisjon, åpner en ekte agentkjøring — uten å stenge noen vei som
-- faktisk er åpen. Vilkåret er derfor på **mandatet**, som er der den kjente
-- feilen sitter. Skal pekeren også kreves, er det én fremoverrettet migrasjon
-- til, og ingenting annet må endres.
--
-- ----------------------------------------------------------------------------
-- Hva vilkåret ikke gjør
--
-- Det fjerner ingenting. Revisjon 24aefcd7 og vurderingen på den blir stående,
-- leselige, med sin opprinnelige attribusjon — de var faktisk laget slik.
-- Gaten sier bare nei når noen forsøker å bære en publisering på dem, og sier
-- hvorfor.
--
-- Fremover-skrivende: ingen kjørt migrasjon er redigert.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §6, §10, §11, §12, §14, §15, §17, §20
--   docs/DATABASE_ARCHITECTURE.md §22, §29, §30, §31, §38, §46, §50
--   docs/EVIDENCE_PIPELINE.md §34, §35, §61
--   docs/KNOWLEDGE_MODEL.md §13, §19
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §49
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Mandatet
-- ----------------------------------------------------------------------------
create function workflow.assessment_author_has_mandate(
  p_author_actor_id uuid,
  p_claim_revision_id uuid,
  p_at timestamptz
)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = ''
as $$
declare
  v_actor_type provenance.actor_type;
  v_agent_role provenance.agent_role;
  v_auth_user_id uuid;
  v_topic_concept_id uuid;
begin
  select a.actor_type, a.agent_role, a.auth_user_id
    into v_actor_type, v_agent_role, v_auth_user_id
  from provenance.actors a
  where a.id = p_author_actor_id;

  if not found then
    return false;
  end if;

  -- En agent har mandatet gjennom rollen sin, og bare gjennom den. Rollen er
  -- rettighetsgrensen (migrasjon 005e), og skillet mellom den som formulerer
  -- påstanden og den som graderer grunnlaget under den, skal være teknisk
  -- (EVIDENCE_PIPELINE.md §61).
  if v_actor_type = 'agent' then
    return v_agent_role = 'evidence_assessment';
  end if;

  if v_actor_type <> 'human' or v_auth_user_id is null then
    return false;
  end if;

  select cl.topic_concept_id into v_topic_concept_id
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  where r.id = p_claim_revision_id;

  -- Et menneske har mandatet gjennom en gyldig editor-tildeling som dekker
  -- påstandens kliniske tema. Scope-regelen er den samme som
  -- knowledge.assert_editor_authorized(uuid) bruker: en uavgrenset tildeling
  -- gjelder alt, en avgrenset må dekke nøyaktig det temaet.
  return exists (
    select 1
    from workflow.user_roles ur
    where ur.user_id = v_auth_user_id
      and ur.role_code = 'editor'
      and ur.created_at <= p_at
      and ur.valid_from <= p_at
      and (ur.valid_to is null or ur.valid_to > p_at)
      and (ur.scope_id is null or ur.scope_id = v_topic_concept_id)
  );
end;
$$;

comment on function workflow.assessment_author_has_mandate(uuid, uuid, timestamptz) is
  'Om en aktør hadde mandat til å gjøre evidensvurderingen for en påstandsrevisjon på et gitt tidspunkt (ANTIDEP_CONSTITUTION.md §10, §12, EVIDENCE_PIPELINE.md §61). Formet som workflow.claim_verifier_has_mandate(uuid, uuid, timestamp with time zone) og workflow.evidence_verifier_has_mandate(uuid, uuid, timestamp with time zone): en agent har mandatet gjennom rollen sin og bare gjennom den — evidence_assessment og ingen annen — og et menneske gjennom en gyldig editor-tildeling som dekker påstandens kliniske tema, med samme scope-regel som knowledge.assert_editor_authorized(uuid). Ingen annen aktørtype kan gjøre en evidensvurdering. Tidspunktet er radens eget assessed_at og ikke now(): en tildeling som senere avsluttes, opphever ikke en vurdering som var legitim da den ble gjort. Leses av publiseringsgatens G10b. SECURITY DEFINER fordi provenance, workflow og knowledge har RLS med default deny; STABLE fordi den bare leser; tomt search_path.';

revoke execute on function workflow.assessment_author_has_mandate(uuid, uuid, timestamptz) from public;

-- ----------------------------------------------------------------------------
-- 2. Gaten leser mandatet
--
-- Uendret utenfra på alle punkter unntatt ett: G10 leser nå vurderingsraden én
-- gang — som G9-gruppen leser claim-verifikasjonen, slik at de to vilkårene
-- aldri kan bli uenige om hvilken rad de snakker om — og G10b er nytt.
-- ----------------------------------------------------------------------------
create or replace function knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_offenders text;
  v_claim_verification_outcome workflow.verification_outcome;
  v_claim_verifier_actor_id uuid;
  v_claim_verified_at timestamptz;
  v_claim_verified_digest text;
  v_assessment_author_actor_id uuid;
  v_assessed_at timestamptz;
begin
  -- G1: revisjonen finnes.
  select r.claim_id, r.knowledge_type, c.retired_at
    into v_claim_id, v_knowledge_type, v_retired_at
  from knowledge.claim_revisions r
  join knowledge.claims c on c.id = r.claim_id
  where r.id = p_claim_revision_id;

  if not found then
    raise exception using
      errcode = 'invalid_parameter_value',
      message = format('Påstandsrevisjon %L finnes ikke.', p_claim_revision_id),
      hint = 'Publisering peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  -- G2: påstanden er ikke trukket tilbake.
  if v_retired_at is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Påstanden bak revisjon %L er trukket tilbake og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'En tilbaketrukket påstand er tatt ut av bruk. Opprett en ny påstand dersom temaet fortsatt skal dekkes; historikken til den gamle bevares (DATABASE_ARCHITECTURE.md §36).';
  end if;

  -- G3: nødvendige EvidenceItems finnes.
  -- ANTIDEP_CONSTITUTION.md §4: ingen publisert klinisk relevant påstand skal
  -- eksistere uten eksplisitt kobling til én eller flere identifiserbare kilder.
  -- Kravet gjelder alle tre kunnskapstypene; også et deterministisk faktum skal
  -- kunne spores til kilden sin.
  if not exists (
    select 1
    from knowledge.claim_evidence_links l
    where l.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrerte evidenslenker og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'Registrer minst ett evidensfunn med en begrunnet relasjon til revisjonen. En publisert påstand uten kobling til en identifiserbar kilde er ikke etterprøvbar (ANTIDEP_CONSTITUTION.md §4).';
  end if;

  -- G4: hvert lenket evidensfunn er faktisk kontrollert av noen.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and not exists (
      select 1
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = l.evidence_item_id
    );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn uten registrert ekstraksjonsverifikasjon: %s.', v_offenders
      ),
      hint = 'En separat kontrollfase skal ha gått gjennom ekstraksjonen mot kildematerialet før påstanden publiseres (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29). Registrer verifikasjonen i workflow.evidence_verifications.';
  end if;

  -- G5: den gjeldende ekstraksjonsverifikasjonen bekrefter funnet.
  -- Den siste kontrollen er den gjeldende: et senere needs_correction, rejected
  -- eller uncertain er et åpent blokkerende verifikasjonsfunn, uansett hvor mange
  -- bekreftelser som ligger foran det.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and (
      select ev.outcome
      from workflow.evidence_verifications ev
      where ev.evidence_item_id = l.evidence_item_id
      order by ev.registration_ordinal desc
      limit 1
    ) <> 'verified';

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn med åpent verifikasjonsfunn: %s.', v_offenders
      ),
      hint = 'Den siste registrerte ekstraksjonsverifikasjonen konkluderer ikke med verified. Rett ekstraksjonen i et nytt evidensfunn og registrer en ny kontroll; en tidligere bekreftelse opphever ikke et senere avvik.';
  end if;

  -- G5b: kontrollene dekker til sammen det raden faktisk påstår.
  --
  -- G5 leste bare `outcome`. En kontroll som *med vilje* lar felter stå
  -- ukontrollert — den deterministiske ekstraksjonsverifikatoren bedømmer
  -- verken tidspunkt, retning, effektmål, availability-semantikk eller
  -- forbehold — kunne dermed tilfredsstille en gate som er ment å bety at
  -- ekstraksjonen er kontrollert. `checked_fields` sa sannheten, men ingen
  -- leste den (DATABASE_ARCHITECTURE.md §29).
  --
  -- Regelen er uendret fra migrasjon 005i, inkludert at dekningen har samme
  -- gjeldende-semantikk som utfallet: en ikke-bekreftende kontroll nullstiller
  -- den, slik at et senere avvik ikke kan omgås av en enda senere delkontroll
  -- som aldri så på det omstridte feltet. Selve unionen står nå i
  -- workflow.covered_check_fields(uuid), fordi reviewerflaten skal vise nøyaktig
  -- den dekningen gaten krever (migrasjon 005q).
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and exists (
      select 1
      from unnest(workflow.required_check_fields(l.evidence_item_id)) as required(field)
      where required.field <> all (workflow.covered_check_fields(l.evidence_item_id))
    );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn uten fullstendig kontrollert ekstraksjon: %s.', v_offenders
      ),
      hint = 'De registrerte kontrollene dekker ikke alle feltene funnet påstår noe om. workflow.required_check_fields(evidence_item_id) viser hva som kreves; en delkontroll kan ikke alene tilfredsstille publiseringsgaten (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29). Merk at en ikke-bekreftende kontroll nullstiller dekningen: bekreftelser som ligger foran den, teller ikke lenger.';
  end if;

  -- G5c: den gjeldende ekstraksjonskontrollen ble gjort av noen med mandat.
  --
  -- Speilbildet av G9c, og det finnes av samme grunn. Migrasjon 005q håndhever
  -- mandatet ved innsetting, og dette vilkåret er den andre lesningen av den
  -- samme regelen — den samme funksjonen, slik at de to ikke kan komme i utakt.
  -- At begge finnes, er bevisst: gaten er stedet der konsekvensen inntreffer, og
  -- en rad skrevet før regelen fantes, gjennom en senere skrivevei, eller av en
  -- vedlikeholdsoperasjon, skal ikke kunne bære en publisering fordi den slapp
  -- forbi det ene laget.
  --
  -- «Den gjeldende» er den samme raden G5 leser, hentet med den samme
  -- rekkefølgen. G4 har allerede slått fast at det finnes minst én.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  cross join lateral (
    select ev.verifier_actor_id, ev.verified_at
    from workflow.evidence_verifications ev
    where ev.evidence_item_id = l.evidence_item_id
    order by ev.registration_ordinal desc
    limit 1
  ) as current_check
  where l.claim_revision_id = p_claim_revision_id
    and not workflow.evidence_verifier_has_mandate(
          current_check.verifier_actor_id, l.evidence_item_id, current_check.verified_at
        );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn der den gjeldende ekstraksjonskontrollen mangler mandat: %s.', v_offenders
      ),
      hint = 'Kontroll av en ekstraksjon mot kilden er et eget mandat (ANTIDEP_CONSTITUTION.md §10): en agent må ha rollen extraction_verification, og et menneske må ha hatt gyldig reviewer-rolle for endepunktet funnet rapporterer om da kontrollen ble gjort. Registrer en ny kontroll fra en aktør som har mandatet.';
  end if;

  -- G6: ingen lenket ekstraksjon er trukket tilbake.
  -- Overlevert eksplisitt fra migrasjon 005: «er dette evidensfunnet trukket
  -- tilbake?» er ikke en statuskolonne, men en avledet tilstand — den siste
  -- beslutningen av typen extraction_withdrawal for funnet.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and (
      select rd.decision
      from workflow.review_decisions rd
      where rd.evidence_item_id = l.evidence_item_id
        and rd.review_type = 'extraction_withdrawal'
      order by rd.registration_ordinal desc
      limit 1
    ) = 'extraction_withdrawn';

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn med tilbaketrukket ekstraksjon: %s.', v_offenders
      ),
      hint = 'En tilbaketrukket ekstraksjon skal ikke bære en publisert påstand. Opprett en ny revisjon uten det tilbaketrukne funnet, eller registrer en ny beslutning som opprettholder ekstraksjonen dersom tilbaketrekkingen var feil (DATABASE_ARCHITECTURE.md §29).';
  end if;

  -- G7: ingen lenket kilde er trukket tilbake eller tilbakekalt.
  -- DATABASE_ARCHITECTURE.md §58, siste kulepunkt: en withdrawn eller retracted
  -- kilde skal ikke ubemerket tilfredsstille en gate som om statusen var normal.
  select string_agg(distinct s.id::text, ', ' order by s.id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  join knowledge.evidence_items e on e.id = l.evidence_item_id
  join knowledge.sources s on s.id = e.source_id
  where l.claim_revision_id = p_claim_revision_id
    and s.source_status in ('retracted', 'withdrawn');

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Kilder med statusen retracted eller withdrawn i grunnlaget: %s.', v_offenders
      ),
      hint = 'En tilbaketrukket eller tilbakekalt kilde kan ikke bære en publisert påstand. Vurder grunnlaget på nytt i en ny revisjon (DATABASE_ARCHITECTURE.md §58).';
  end if;

  -- G8: påstanden er kontrollert mot grunnlaget.
  -- DATABASE_ARCHITECTURE.md §38 sitt «ClaimEvidenceLinks er kontrollert» er
  -- nettopp claim-verifikasjonen fra §30: den kontrollerer om grunnlaget faktisk
  -- støtter ordlyden, om populasjon, komparator, tidsramme, retning og størrelse
  -- stemmer, om vesentlige forbehold mangler og om motstridende evidens er
  -- representert. Migrasjon 005 håndhever allerede at en verifikasjon ikke kan
  -- konkludere med verified uten at alle sju punktene er bedømt og holder.
  if not exists (
    select 1
    from workflow.claim_verifications cv
    where cv.claim_revision_id = p_claim_revision_id
  ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L har ingen registrert claim-verifikasjon.', p_claim_revision_id
      ),
      hint = 'En separat kontrollfase skal ha forsøkt å falsifisere påstanden mot det registrerte grunnlaget før den publiseres (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §30). Registrer kontrollen i workflow.claim_verifications.';
  end if;

  -- G9, G9b og G9c leser alle den *gjeldende* claim-verifikasjonen, altså den
  -- siste, med samme rekkefølge G5 bruker for ekstraksjonsverifikasjonene. Den
  -- leses én gang, slik at de tre vilkårene aldri kan bli uenige om hvilken rad
  -- de snakker om.
  select cv.outcome, cv.verifier_actor_id, cv.verified_at, cv.verified_evidence_set_digest
    into v_claim_verification_outcome, v_claim_verifier_actor_id,
         v_claim_verified_at, v_claim_verified_digest
  from workflow.claim_verifications cv
  where cv.claim_revision_id = p_claim_revision_id
  order by cv.registration_ordinal desc
  limit 1;

  -- G9: den gjeldende claim-verifikasjonen bekrefter påstanden.
  if v_claim_verification_outcome <> 'verified' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L konkluderer ikke med verified.',
        p_claim_revision_id
      ),
      hint = 'Den siste registrerte kontrollen er den gjeldende. Rett påstanden i en ny revisjon og få den kontrollert på nytt; en tidligere bekreftelse opphever ikke et senere avvik.';
  end if;

  -- G9b: kontrollen gjaldt det evidenssettet som faktisk ville blitt publisert.
  --
  -- En claim-verifikasjon er en vurdering av påstanden mot et bestemt grunnlag,
  -- og migrasjon 005j gir databasen eierskap til avtrykket av det grunnlaget.
  -- Uten dette vilkåret ville sekvensen «kontroller → legg til en lenke →
  -- publiser» sluppet gjennom en bekreftelse som aldri så den nye lenken — og
  -- den lenken kan være nettopp den motstridende evidensen kontrollen skulle
  -- lete etter (ANTIDEP_CONSTITUTION.md §9, §11, KNOWLEDGE_MODEL.md §19.2).
  --
  -- Sammenligningen er på avtrykk og ikke på tidspunkter, av samme grunn som
  -- G13: now() er transaksjonens starttidspunkt og ikke committidspunktet, så en
  -- lenke kan bære en created_at foran kontrollen og likevel ha blitt synlig
  -- etter den. Avtrykket er uavhengig av rekkefølge.
  if knowledge.claim_evidence_set_digest(p_claim_revision_id)
     is distinct from v_claim_verified_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensgrunnlaget for revisjon %L er endret etter den gjeldende claim-verifikasjonen.',
        p_claim_revision_id
      ),
      hint = 'Kontrollen gjaldt et annet evidenssett enn det som er registrert nå, og dekker derfor ikke grunnlaget påstanden ville blitt publisert på. Registrer en ny claim-verifikasjon som dekker hele det utvidede settet (ANTIDEP_CONSTITUTION.md §4, §9).';
  end if;

  -- G9c: kontrollen ble gjort av noen med mandat til det.
  --
  -- Migrasjon 005j håndhever mandatet ved innsetting, og dette vilkåret er den
  -- andre lesningen av den samme regelen — den samme funksjonen, slik at de to
  -- ikke kan komme i utakt. At begge finnes, er bevisst: gaten er stedet der
  -- konsekvensen inntreffer, og en rad skrevet før regelen fantes, gjennom en
  -- senere skrivevei, eller av en vedlikeholdsoperasjon, skal ikke kunne bære en
  -- publisering fordi den slapp forbi det ene laget.
  --
  -- Tidspunktet er radens eget verified_at, ikke now(): en rolletildeling som
  -- senere avsluttes, opphever ikke en kontroll som var legitim da den ble
  -- gjort. Historikken består (ANTIDEP_CONSTITUTION.md §14).
  if not workflow.claim_verifier_has_mandate(
       v_claim_verifier_actor_id, p_claim_revision_id, v_claim_verified_at
     ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende claim-verifikasjonen for revisjon %L er registrert av en aktør uten mandat til å kontrollere påstanden.',
        p_claim_revision_id
      ),
      hint = 'Sitat- og kildestøtteverifikasjon er et eget mandat (ANTIDEP_CONSTITUTION.md §10): en agent må ha rollen citation_support_verification, og et menneske må ha hatt gyldig reviewer-rolle for innholdsområdet da kontrollen ble gjort. Registrer en ny kontroll fra en aktør som har mandatet.';
  end if;

  -- G10: evidensvurderingen finnes for de typene som skal ha en.
  -- ANTIDEP_CONSTITUTION.md §6: en evidensbasert syntese skal ha en eksplisitt
  -- vurdering av sikkerheten i kunnskapsgrunnlaget. Migrasjon 004 tillater ikke
  -- en vurdering på et deterministisk faktum, så kravet gjelder de to typene som
  -- kan ha en.
  --
  -- Raden leses én gang, slik G9-gruppen leser claim-verifikasjonen, slik at G10
  -- og G10b aldri kan bli uenige om hvilken vurdering de snakker om. Det er
  -- nøyaktig én per revisjon (evidence_assessments_claim_revision_key).
  if v_knowledge_type in ('evidence_synthesis', 'clinical_recommendation') then
    select a.created_by_actor_id, a.assessed_at
      into v_assessment_author_actor_id, v_assessed_at
    from knowledge.evidence_assessments a
    where a.claim_revision_id = p_claim_revision_id;

    if not found then
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'Revisjon %L mangler evidensvurdering og kan ikke publiseres som %s.',
          p_claim_revision_id, v_knowledge_type
        ),
        hint = 'En evidenssyntese eller klinisk anbefaling skal ha en eksplisitt vurdering av sikkerheten i kunnskapsgrunnlaget, med de fem GRADE-domenene vurdert (ANTIDEP_CONSTITUTION.md §6). Registrer vurderingen med api.register_evidence_assessment(text, text, uuid, uuid, text, text, text, text, text, text, text, text, text, text, text), som krever at kildestøtteverifikasjonen er gjort først.';
    end if;

    -- G10b: vurderingen ble gjort av noen med mandat til det.
    --
    -- Speilbildet av G5c og G9c, og den finnes av samme grunn — men her er den
    -- ikke bare en andre lesning av en regel som håndheves ved innsetting: fram
    -- til migrasjon 005am skrev synteseveien selv den endelige GRADE-vurderingen,
    -- og radene den etterlot, er attribuert til `agent:claim-synthesis`. G10
    -- kontrollerer bare at en vurdering *finnes*, så uten dette vilkåret ville
    -- en slik rad kunnet bære en publisering den dagen revisjonen fikk den
    -- claim-verifikasjonen den mangler. Da ville den ordinære flaten endt med å
    -- publisere nøyaktig det artefaktet 005am ble laget for å erstatte.
    --
    -- Tidspunktet er radens eget assessed_at, ikke now(): en rolletildeling som
    -- senere avsluttes, opphever ikke en vurdering som var legitim da den ble
    -- gjort (ANTIDEP_CONSTITUTION.md §14).
    if not workflow.assessment_author_has_mandate(
         v_assessment_author_actor_id, p_claim_revision_id, v_assessed_at
       ) then
      raise exception using
        errcode = 'restrict_violation',
        message = format(
          'Evidensvurderingen for revisjon %L er gjort av en aktør uten mandat til å vurdere evidenssikkerheten.',
          p_claim_revision_id
        ),
        hint = 'Å gradere sikkerheten i kunnskapsgrunnlaget er et eget mandat (ANTIDEP_CONSTITUTION.md §10, EVIDENCE_PIPELINE.md §61): en agent må ha rollen evidence_assessment, og et menneske må ha hatt gyldig editor-rolle for påstandens kliniske tema da vurderingen ble gjort. En vurdering laget av påstandsdannelsen selv holder ikke — det var nettopp den ansvarsgrensen som manglet. Opprett en ny revisjon og registrer vurderingen med api.register_evidence_assessment(text, text, uuid, uuid, text, text, text, text, text, text, text, text, text, text, text).';
    end if;
  end if;


end;
$$;



comment on function knowledge.assert_claim_revision_ready_for_approval(uuid) is
  'Publiseringsgatens forutsetninger, G1 til G10b. Uendret utenfra fra migrasjon 20260913090000 på alle punkter unntatt ett: G10 leser nå vurderingsraden én gang, som G9-gruppen leser claim-verifikasjonen, og G10b krever at den som gjorde vurderingen, hadde mandat til det (workflow.assessment_author_has_mandate(uuid, uuid, timestamp with time zone)). Vilkåret er speilbildet av G5c og G9c, men lukker i tillegg et konkret hull: fram til migrasjon 005am skrev synteseveien selv den endelige GRADE-vurderingen, og G10 kontrollerer bare at en vurdering finnes. Uten G10b ville en slik rad kunnet bære en publisering den dagen revisjonen fikk den claim-verifikasjonen den manglet. Tidspunktet mandatet leses på, er radens eget assessed_at og ikke now(). Gaten kalles av knowledge.assert_claim_revision_publishable(uuid) og av api.register_publication_approval(uuid, text, text, text), slik at en godkjenning krever nøyaktig de samme forutsetningene som en publisering.';
