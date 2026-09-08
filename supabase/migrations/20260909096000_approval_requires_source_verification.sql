-- ============================================================================
-- Migrasjon 006e — en godkjenning kan ikke gis før grunnlaget er kontrollert
--
-- Migrasjon 006d åpnet skriveveien for den menneskelige publiseringsgodkjenningen,
-- men lot `decision = 'approved'` registreres på et hvilket som helst tidspunkt i
-- livsløpet — også før ekstraksjonen og påstanden i det hele tatt var kontrollert.
--
-- Det er ikke bare et spørsmål om rekkefølge på skjermen. Godkjenningen er
-- append-only og bindes bare til `approved_evidence_set_digest`, altså til
-- *hvilke* evidenslenker som fantes. Den bindes ikke til hvilke kontroller som
-- var gjeldende. Derfor var denne sekvensen mulig:
--
--   1. Revieweren registrerer `approved` mens G5 eller G9 fortsatt blokkerer.
--   2. Senere registreres en ekstraksjons- eller claim-verifikasjon på de samme
--      lenkene, slik at G5 og G9 begynner å passere.
--   3. Den gamle godkjenningen er fortsatt den gjeldende beslutningen, og G13
--      passerer fordi evidenssettets avtrykk er uendret.
--   4. Revisjonen kan publiseres uten at noe menneske har gått god for den
--      *etter* at innholdet faktisk ble kildekontrollert.
--
-- Godkjenningen ville da vært gitt til noe annet enn det som ble publisert: et
-- ukontrollert utkast. Livsløpet ANTIDEP_CONSTITUTION.md §13 og
-- KNOWLEDGE_MODEL.md §20 beskriver — draft → source-verified → human-approved →
-- published — er en rekkefølge nettopp fordi den menneskelige godkjenningen skal
-- være en vurdering av kildekontrollert innhold.
--
-- Funnet i teknisk review av PR #59.
--
-- ----------------------------------------------------------------------------
-- Rettelsen: ett sett forutsetninger, lest to steder
--
-- Vilkårene G1 til G10 er nettopp «alt som skal holde før et menneske tar
-- stilling». De flyttes ordrett ut i
-- knowledge.assert_claim_revision_ready_for_approval(uuid), og
-- publiseringsgaten kaller den framfor å ha dem i kroppen sin. Skriveveien for
-- godkjenningen kaller den samme funksjonen. Ingen logikk er kopiert, og de to
-- kan derfor ikke komme i utakt — samme begrunnelse mandatet har for å ligge i
-- én boolsk funksjon (migrasjon 005j) og dossieret for å ligge i ett uttrykk
-- (migrasjon 005m).
--
-- Gaten er uendret utenfra: den kaller forutsetningene først og har G11, G12 og
-- G13 ordrett som før. Hver eneste avvisning har samme SQLSTATE, samme setning
-- og samme hint som i dag.
--
-- ----------------------------------------------------------------------------
-- Bare `approved` er bundet av forutsetningene
--
-- `rejected` og `changes_requested` skal fortsatt kunne registreres mens noe
-- blokkerer — det er nettopp da de trengs. En reviewer som ser at ekstraksjonen
-- ikke er kontrollert, skal kunne be om endringer, og den beslutningen skal
-- bevares. Vilkåret gjelder derfor bare den beslutningen som kan bære en
-- publisering.
--
-- ----------------------------------------------------------------------------
-- Flaten sier det på forhånd
--
-- api.claim_review_workspace(uuid) får `approval_readiness` ved siden av
-- `publication_gate`. De to er ikke det samme: gaten stopper på det første
-- vilkåret som svikter, og rett før en godkjenning er det alltid G11 — «ikke
-- godkjent av en kvalifisert redaktør». En flate som leste gaten alene, ville
-- derfor ikke kunne skille «mangler bare godkjenningen» fra «grunnlaget er ikke
-- kontrollert ennå». Feltet leses av den samme funksjonen skriveveien bruker, så
-- flaten kan verken love mer eller mindre enn databasen faktisk godtar.
--
-- Fremover-skrivende: ingen kjørt migrasjon er redigert.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §6, §9, §11, §12, §13, §14
--   docs/CONTENT_GOVERNANCE.md §11, §12, §26
--   docs/DATABASE_ARCHITECTURE.md §30, §31, §38, §43, §50
--   docs/KNOWLEDGE_MODEL.md §19.2, §20
--   docs/MVP_IMPLEMENTATION_PLAN.md §15, §42, §74.36
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Forutsetningene før den menneskelige godkjenningen
--
-- Kroppen er G1 til G10, flyttet ordrett fra
-- knowledge.assert_claim_revision_publishable(uuid) slik den ble skrevet i
-- migrasjon 20260908094000. Ikke en linje er endret; kommentarene følger med,
-- fordi de er begrunnelsen for hvert enkelt vilkår.
--
-- SECURITY INVOKER, som gaten selv: den kalles fra DEFINER-kontekster og skal
-- ikke utvide DEFINER-flaten (DATABASE_ARCHITECTURE.md §50).
-- ----------------------------------------------------------------------------
create function knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id uuid)
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
      order by ev.verified_at desc, ev.created_at desc, ev.id desc
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
  -- Kravet er derfor at unionen av `checked_fields` over funnets bekreftede
  -- kontroller dekker feltene raden påstår noe om. Unionen, ikke den siste
  -- raden: en kontroll kan dekke en delmengde, og flere verifikatorledd kan
  -- til sammen dekke resten.
  --
  -- **Dekning har en gjeldende-semantikk, akkurat som utfallet.** En dekning
  -- som gjaldt for alltid ville gitt et senere avvik en vei ut som G5 er ment
  -- å stenge:
  --
  --   t1  full bekreftelse, dekker alt
  --   t2  ny kontroll: tidspunktet er uavklart      → G5 blokkerer, riktig
  --   t3  delkontroll bekrefter sitat og begreper   → G5 slipper (siste er
  --                                                    verified), og dekningen
  --                                                    for tidspunkt hentes fra
  --                                                    t1 — som t2 nettopp
  --                                                    underkjente
  --
  -- Det åpne funnet fra t2 ville dermed vært borte uten at noen så på
  -- tidspunktet igjen. En bekreftelse teller derfor bare mot dekningen når
  -- ingen ikke-bekreftende kontroll er *nyere* enn den: et avvik nullstiller
  -- dekningen, og den må bygges opp igjen etterpå.
  --
  -- Nullstillingen gjelder alle felter, ikke bare det omstridte. Det er ikke
  -- strengere enn nødvendig: en uavklart kontroll fører opp i `checked_fields`
  -- det den *bekreftet*, så feltet den ikke fikk avklart, er nettopp det som
  -- ikke står der — hvilket felt som er omstridt, er ikke avlesbart. Da er den
  -- trygge lesningen at hele ekstraksjonen står åpen til den er kontrollert på
  -- nytt, hvilket også er den arbeidsflyten G5s egen hint beskriver.
  select string_agg(distinct l.evidence_item_id::text, ', ' order by l.evidence_item_id::text)
    into v_offenders
  from knowledge.claim_evidence_links l
  where l.claim_revision_id = p_claim_revision_id
    and exists (
      select 1
      from unnest(workflow.required_check_fields(l.evidence_item_id)) as required(field)
      where required.field <> all (
        select distinct f.field
        from workflow.evidence_verifications ev
        cross join unnest(ev.checked_fields) as f(field)
        where ev.evidence_item_id = l.evidence_item_id
          and ev.outcome = 'verified'
          -- Samme rekkefølge som G5 bruker for «den siste», slik at de to
          -- vilkårene ikke kan bli uenige om hva som er nyere.
          and not exists (
            select 1
            from workflow.evidence_verifications later
            where later.evidence_item_id = l.evidence_item_id
              and later.outcome <> 'verified'
              and (later.verified_at, later.created_at, later.id)
                  > (ev.verified_at, ev.created_at, ev.id)
          )
      )
    );

  if v_offenders is not null then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensfunn uten fullstendig kontrollert ekstraksjon: %s.', v_offenders
      ),
      hint = 'De registrerte kontrollene dekker ikke alle feltene funnet påstår noe om. workflow.required_check_fields(evidence_item_id) viser hva som kreves; en delkontroll kan ikke alene tilfredsstille publiseringsgaten (ANTIDEP_CONSTITUTION.md §11, DATABASE_ARCHITECTURE.md §29). Merk at en ikke-bekreftende kontroll nullstiller dekningen: bekreftelser som ligger foran den, teller ikke lenger.';
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
      order by rd.decided_at desc, rd.created_at desc, rd.id desc
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
  order by cv.verified_at desc, cv.created_at desc, cv.id desc
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
  if v_knowledge_type in ('evidence_synthesis', 'clinical_recommendation')
     and not exists (
       select 1
       from knowledge.evidence_assessments a
       where a.claim_revision_id = p_claim_revision_id
     ) then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L mangler evidensvurdering og kan ikke publiseres som %s.',
        p_claim_revision_id, v_knowledge_type
      ),
      hint = 'En evidenssyntese eller klinisk anbefaling skal ha en eksplisitt vurdering av sikkerheten i kunnskapsgrunnlaget, med de fem GRADE-domenene vurdert (ANTIDEP_CONSTITUTION.md §6). Registrer vurderingen i knowledge.evidence_assessments.';
  end if;

end;
$$;

comment on function knowledge.assert_claim_revision_ready_for_approval(uuid) is
  'Forutsetningene som skal holde før et menneske tar stilling til publisering: publiseringsgatens G1 til G10, ordrett som de ble skrevet i migrasjon 20260908094000. Revisjonen finnes, påstanden er ikke trukket tilbake, evidenslenkene finnes, hvert lenket evidensfunn er kontrollert, den gjeldende kontrollen bekrefter det, kontrollene dekker til sammen det funnet påstår, ingen ekstraksjon eller kilde er trukket tilbake, påstanden er kontrollert mot grunnlaget av noen med mandat, kontrollen gjaldt det settet som er registrert nå, og evidensvurderingen finnes for de kunnskapstypene som skal ha en. Funksjonen leses to steder og er skrevet ett sted: knowledge.assert_claim_revision_publishable(uuid) kaller den før sine egne G11, G12 og G13, og api.register_publication_approval(uuid, text, text, text) kaller den før den registrerer en approved-beslutning, slik at en godkjenning aldri kan gis til et ukontrollert utkast og siden bli stående når kontrollene kommer (ANTIDEP_CONSTITUTION.md §13, KNOWLEDGE_MODEL.md §20). Avviser med restrict_violation på hvert vilkår, og med invalid_parameter_value når revisjonen ikke finnes. SECURITY INVOKER med tomt search_path: den kalles fra DEFINER-kontekster og skal ikke utvide DEFINER-flaten (DATABASE_ARCHITECTURE.md §50).';

revoke execute on function knowledge.assert_claim_revision_ready_for_approval(uuid) from public;

-- ----------------------------------------------------------------------------
-- 2. Publiseringsgaten kaller forutsetningene framfor å eie dem
--
-- Utenfra er gaten uendret: samme navn, samme signatur, samme rekkefølge på
-- vilkårene, samme SQLSTATE, setning og hint på hver eneste avvisning. G11, G12
-- og G13 står ordrett som i migrasjon 20260908094000.
-- ----------------------------------------------------------------------------
create or replace function knowledge.assert_claim_revision_publishable(p_claim_revision_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_latest_decision workflow.review_outcome;
  v_approved_digest text;
begin
  -- G1 til G10: alt som skal holde før et menneske i det hele tatt kan ta
  -- stilling. De samme vilkårene, lest av den samme funksjonen, som
  -- api.register_publication_approval(uuid, text, text, text) krever før den
  -- registrerer en godkjenning (migrasjon 006e).
  perform knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id);

  -- G11: menneskelig faglig godkjenning finnes.
  select rd.decision, rd.approved_evidence_set_digest
    into v_latest_decision, v_approved_digest
  from workflow.review_decisions rd
  where rd.claim_revision_id = p_claim_revision_id
    and rd.review_type = 'publication_approval'
  order by rd.decided_at desc, rd.created_at desc, rd.id desc
  limit 1;

  if not found then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Revisjon %L er ikke godkjent av en kvalifisert redaktør og kan ikke publiseres.',
        p_claim_revision_id
      ),
      hint = 'KI kan foreslå, men mennesker har det faglige ansvaret (ANTIDEP_CONSTITUTION.md §12). Registrer en publication_approval i workflow.review_decisions fra en navngitt kvalifisert redaktør.';
  end if;

  -- G12: godkjenningen er fortsatt den gjeldende beslutningen.
  if v_latest_decision <> 'approved' then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Den gjeldende reviewbeslutningen for revisjon %L er %s, ikke approved.',
        p_claim_revision_id, v_latest_decision
      ),
      hint = 'En senere beslutning gjelder foran en tidligere. Rett revisjonen slik reviewer ba om, i en ny revisjon, og be om ny godkjenning. Både godkjenningen og omgjøringen bevares (DATABASE_ARCHITECTURE.md §31).';
  end if;

  -- G13: evidensgrunnlaget er det samme som godkjenningen ble gitt for.
  -- MVP_IMPLEMENTATION_PLAN.md §42: systemet skal nekte «review av en revisjon
  -- som senere er endret uten nytt review». Selve revisjonsraden kan ikke endres
  -- — den er append-only — men betydningen av en revisjon omfatter
  -- evidensgrunnlaget den hviler på (KNOWLEDGE_MODEL.md §19.2). Et grunnlag som
  -- er endret etter at reviewer sa ja, er nettopp en endring reviewer ikke har
  -- sett.
  --
  -- Kontrollen sammenligner avtrykk, ikke tidspunkter. Begrunnelsen står i
  -- avsnitt 5: en tidssammenligning er ikke samtidighetssikker, fordi now() er
  -- transaksjonens starttidspunkt og ikke committidspunktet, og en lenke derfor
  -- kan bære en created_at foran godkjenningen selv om den ble synlig etter den.
  -- Avtrykket er uavhengig av rekkefølge: er settet et annet nå enn da
  -- beslutningen ble lagret, avvises publiseringen.
  if knowledge.claim_evidence_set_digest(p_claim_revision_id)
     is distinct from v_approved_digest then
    raise exception using
      errcode = 'restrict_violation',
      message = format(
        'Evidensgrunnlaget for revisjon %L er endret etter godkjenningen.',
        p_claim_revision_id
      ),
      hint = 'Godkjenningen gjelder et annet evidenssett enn det som er registrert nå, og dekker derfor ikke grunnlaget påstanden ville blitt publisert på. Opprett en ny revisjon med det fullstendige evidenssettet og be om ny godkjenning, eller registrer en ny godkjenning som dekker det utvidede grunnlaget (KNOWLEDGE_MODEL.md §19.2).';
  end if;


end;
$$;

comment on function knowledge.assert_claim_revision_publishable(uuid) is
  'Publiseringsgaten. Uendret utenfra fra migrasjon 20260908094000: samme vilkår i samme rekkefølge, med samme SQLSTATE, setning og hint på hver avvisning. Forskjellen er hvor de står: G1 til G10 er flyttet til knowledge.assert_claim_revision_ready_for_approval(uuid), som gaten kaller først, slik at api.register_publication_approval(uuid, text, text, text) kan kreve nøyaktig de samme forutsetningene før den registrerer en approved-beslutning uten at logikken finnes to steder (migrasjon 006e). G11 krever at en publication_approval finnes, G12 at den gjeldende beslutningen er approved, og G13 at evidenssettets avtrykk er det samme nå som da beslutningen ble lagret (KNOWLEDGE_MODEL.md §19.2). De tre leser workflow.review_decisions; forutsetningene leser workflow.evidence_verifications, workflow.claim_verifications og knowledge.evidence_assessments.';

-- ----------------------------------------------------------------------------
-- 3. Skriveveien krever forutsetningene før den registrerer en godkjenning
--
-- Uendret fra migrasjon 006d bortsett fra ett ledd: er beslutningen `approved`,
-- kontrolleres forutsetningene før raden skrives. Vilkåret er lagt der og ikke i
-- en CHECK på tabellen, fordi det avhenger av rader i tre andre tabeller og av
-- hva som er den *gjeldende* kontrollen — noe en radbasert CHECK ikke kan lese.
-- Publiseringsgaten er fortsatt fasiten ved publisering; dette kommer i tillegg
-- og hindrer at en godkjenning i det hele tatt kan gis til noe ukontrollert.
--
-- Kontrollen ligger etter avtrykkskontrollen: «grunnlaget er endret mens du
-- vurderte» er en mer presis beskjed enn «grunnlaget er ikke kontrollert», og
-- den skal komme først når begge er sanne.
-- ----------------------------------------------------------------------------
create or replace function api.register_publication_approval(
  p_claim_revision_id uuid,
  p_seen_evidence_set_digest text,
  p_decision text,
  p_rationale text
)
  returns uuid
  language plpgsql
  security definer
  set search_path = ''
as $$
declare
  v_decision workflow.review_outcome;
  v_topic_concept_id uuid;
  v_creator_actor_id uuid;
  v_reviewer_actor_id uuid;
  v_decision_id uuid;
begin
  -- Vokabularet castes først og for seg, slik at en ukjent verdi gir en setning
  -- som sier hva som er galt. Vokabularet er offentlig dokumentert
  -- (DATABASE_ARCHITECTURE.md §31).
  begin
    v_decision := p_decision::workflow.review_outcome;
  exception
    when invalid_text_representation then
      raise exception using
        errcode = 'invalid_parameter_value',
        message = format('%L er ikke en kjent reviewbeslutning.', p_decision),
        hint = 'Gyldige beslutninger for en publiseringsgodkjenning er approved, rejected og changes_requested (DATABASE_ARCHITECTURE.md §31).';
  end;

  -- Temaet påstanden hører under er det en avgrenset reviewer-tildeling
  -- kontrolleres mot, og forfatteren er speilet den sammensatte fremmednøkkelen
  -- krever. Begge leses fra revisjonen, aldri fra kalleren.
  select cl.topic_concept_id, r.created_by_actor_id
    into v_topic_concept_id, v_creator_actor_id
  from knowledge.claim_revisions r
  join knowledge.claims cl on cl.id = r.claim_id
  where r.id = p_claim_revision_id;

  v_reviewer_actor_id := workflow.assert_reviewer_authorized(v_topic_concept_id);

  if v_creator_actor_id is null then
    raise exception using
      errcode = 'no_data_found',
      message = format('Påstandsrevisjonen %L finnes ikke.', p_claim_revision_id),
      hint = 'En godkjenning peker på en eksakt revisjon, ikke på påstandsidentiteten (KNOWLEDGE_MODEL.md §19.3). Kontroller revisjons-ID-en.';
  end if;

  -- Godkjenningen gjelder det grunnlaget revieweren faktisk så. Publiseringsgaten
  -- kontrollerer det samme på nytt ved publisering (G13); denne kontrollen sier
  -- fra med en gang, framfor å la en godkjenning av noe annet bli stående.
  perform workflow.assert_evidence_set_unchanged(
    p_claim_revision_id, p_seen_evidence_set_digest
  );

  -- En godkjenning er en vurdering av kildekontrollert innhold. Uten dette
  -- vilkåret kunne den gis til et ukontrollert utkast og siden bli stående:
  -- godkjenningen er append-only og bundet bare til hvilke evidenslenker som
  -- fantes, ikke til hvilke kontroller som var gjeldende, så en senere
  -- ekstraksjons- eller claim-verifikasjon på de samme lenkene ville fått den
  -- gamle godkjenningen til å bære en publisering av noe ingen hadde gått god
  -- for i kontrollert tilstand (ANTIDEP_CONSTITUTION.md §13, KNOWLEDGE_MODEL.md
  -- §20, MVP_IMPLEMENTATION_PLAN.md §15).
  --
  -- Bare `approved` er bundet. `rejected` og `changes_requested` trengs nettopp
  -- når noe blokkerer, og skal kunne registreres og bevares da.
  if v_decision = 'approved' then
    perform knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id);
  end if;

  insert into workflow.review_decisions (
    claim_revision_id, claim_revision_creator_actor_id,
    review_type, decision, rationale,
    reviewer_actor_id, reviewer_actor_type, decided_at
  )
  select
    p_claim_revision_id, v_creator_actor_id,
    'publication_approval'::workflow.review_type, v_decision, p_rationale,
    v_reviewer_actor_id, a.actor_type, now()
  from provenance.actors a
  where a.id = v_reviewer_actor_id
  returning id into v_decision_id;

  return v_decision_id;
end;
$$;

comment on function api.register_publication_approval(uuid, text, text, text) is
  'Den kontrollerte skriveveien for at en kvalifisert menneskelig reviewer registrerer en publiseringsgodkjenning for én påstandsrevisjon (ANTIDEP_CONSTITUTION.md §12, §13, §14, DATABASE_ARCHITECTURE.md §31, §43, MVP_IMPLEMENTATION_PLAN.md §15). Kalleren må ha en registrert, ikke-tilbaketrukket aktør og gyldig reviewer-rolle for påstandens kliniske tema (workflow.assert_reviewer_authorized(uuid)); aktøren beslutningen attribueres til er kallerens egen og er ikke en parameter. p_seen_evidence_set_digest må være avtrykket av evidenssettet slik det er nå — en lenke som er kommet til mens vurderingen pågikk, avviser godkjenningen framfor å bli stilltiende dekket av den; publiseringsgatens G13 kontrollerer det samme igjen ved publisering. En approved-beslutning krever i tillegg at knowledge.assert_claim_revision_ready_for_approval(uuid) holder, altså publiseringsgatens G1 til G10: en godkjenning skal være en vurdering av kildekontrollert innhold, og siden raden er append-only og bundet bare til evidenssettets avtrykk, ville en godkjenning gitt til et ukontrollert utkast blitt stående og båret en publisering den dagen kontrollene kom (KNOWLEDGE_MODEL.md §20). rejected og changes_requested er ikke bundet av det: de trengs nettopp når noe blokkerer. review_type er alltid publication_approval, decided_at er alltid now(), claim_revision_creator_actor_id leses fra revisjonen og approved_evidence_set_digest beregnes av databasen. Alle tre beslutningene bevares, og en omgjøring er en ny rad ved siden av den gamle. Godkjenningen er ikke den faglige kontrollen mot grunnlaget — den er api.register_human_claim_verification(uuid, text, text, text, text, text, text, text, text, text, jsonb, text, text), og publiseringsgaten krever begge, hver for seg (G9 og G11). Ingen feltvalidering er duplisert her: constraintene og triggerne på workflow.review_decisions er fasiten, inkludert at reviewer må være et menneske, ikke kan være den som formulerte revisjonen, og må ha hatt gyldig reviewer-rolle med en tildelingsrad som fantes senest på beslutningstidspunktet. Auditraden skrives av triggeren på tabellen, i samme transaksjon. SECURITY DEFINER fordi workflow, knowledge og provenance har RLS med default deny; tomt search_path, og kalleren autoriseres på funksjonens eget kall (§50). EXECUTE gis bare til authenticated: en uinnlogget kaller har ingen aktør og kan ikke ha en reviewer-rolle.';

-- ----------------------------------------------------------------------------
-- 4. Arbeidsflaten sier hva skriveveien kommer til å godta
-- ----------------------------------------------------------------------------
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
  v_readiness jsonb;
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

  -- Forutsetningene før godkjenningen, lest av den samme funksjonen skriveveien
  -- krever (migrasjon 006e). Den er ikke utledbar av `publication_gate`: gaten
  -- stopper på det første vilkåret som svikter, og rett før en godkjenning er
  -- det alltid G11 — «ikke godkjent av en kvalifisert redaktør». En flate som
  -- leste gaten alene, kunne derfor ikke skille «mangler bare godkjenningen» fra
  -- «grunnlaget er ikke kontrollert ennå», og ville tilbudt revieweren en
  -- handling databasen kommer til å avvise.
  --
  -- Samme smale fangst og samme begrunnelse som under: bare gatens egen
  -- avvisningskode blir til `blocked`, alt annet propagerer.
  begin
    perform knowledge.assert_claim_revision_ready_for_approval(p_claim_revision_id);
    v_readiness := jsonb_build_object('status', 'passes');
  exception
    when restrict_violation then
      get stacked diagnostics
        v_state = returned_sqlstate,
        v_message = message_text,
        v_hint = pg_exception_hint;
      v_readiness := jsonb_build_object(
        'status', 'blocked',
        'sqlstate', v_state,
        'message', v_message,
        'hint', v_hint
      );
  end;

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
           'publication_gate', v_gate,
           'approval_readiness', v_readiness
         )
  );
end;
$$;

comment on function api.claim_review_workspace(uuid) is
  'Arbeidsflaten en kvalifisert menneskelig reviewer gjør den faglige kontrollen og publiseringsgodkjenningen fra (ANTIDEP_CONSTITUTION.md §11, §12, §15, MVP_IMPLEMENTATION_PLAN.md §15, §29). Kalleren må ha en registrert, ikke-tilbaketrukket aktør og gyldig reviewer-rolle (workflow.assert_reviewer_authorized(uuid)); en avgrenset tildeling ser bare sitt eget innholdsområde, både i køen og ved direkte oppslag. Uten p_claim_revision_id svarer den med arbeidskøen: påstandsrevisjoner kalleren ikke selv har formulert, med minst én evidenslenke, på en påstand som ikke er trukket tilbake — hver med nok til å velge, og med den gjeldende kontrollen og den gjeldende beslutningen som status. Med p_claim_revision_id svarer den om nøyaktig den revisjonen: hele grunnlaget fra workflow.claim_evidence_dossier(uuid) — det samme uttrykket claim-verifikatoren leser, slik at mennesket og maskinen ser det samme — sammen med workflow.claim_review_history(uuid), approval_readiness og publication_gate. De to siste er ikke egne vurderinger: knowledge.assert_claim_revision_ready_for_approval(uuid) og knowledge.assert_claim_revision_publishable(uuid) kalles på ekte, og avvisningen returneres ordrett, slik at flaten aldri kan si «klar» om noe databasen stenger. approval_readiness er forutsetningene skriveveien krever før en approved-beslutning, og er ikke utledbar av publication_gate: gaten stopper på det første vilkåret som svikter, og rett før en godkjenning er det alltid G11 (migrasjon 006e). Begge stopper på ett vilkår om gangen, så status = blocked navngir én blokkering. Bare gatens egen avvisningskode (restrict_violation) blir til blocked; enhver annen feil propagerer og feiler hele kallet, slik at en teknisk feil aldri kan presenteres som en innholdsmangel (migrasjon 005p). Svaret inneholder ingen «du har lov»-verdi (§74.22 «FELLE 4»): det sier hvem kalleren er og hvem som formulerte revisjonen, og skriveveiene avgjør retten på nytt på sitt eget kall. SECURITY DEFINER fordi knowledge, catalog, provenance og workflow har RLS med default deny; tomt search_path, og kalleren autoriseres på funksjonens eget kall (§50). EXECUTE gis bare til authenticated: en uinnlogget kaller har ingen aktør og kan ikke ha en reviewer-rolle.';
