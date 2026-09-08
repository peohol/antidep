-- ============================================================================
-- Migrasjon 006c — publiseringsgaten leser hvem som kontrollerte påstanden,
-- og hva kontrollen gjaldt
--
-- G8 krevde at det *finnes* en claim-verifikasjon, og G9 at den gjeldende sier
-- `verified`. Ingen av dem leste hvem som skrev raden, eller hvilket
-- evidensgrunnlag kontrollen faktisk gjaldt.
--
-- Begge hullene er reelle, og de er hver sin type:
--
--   **Feil rolle.** Fram til migrasjon 005j kunne enhver aktør som ikke
--   tilfeldigvis var forfatteren, registrere raden G9 leser — en
--   ekstraksjonsagent, en synteseagent, en bruker uten reviewer-rolle. 005j
--   stengte det ved innsetting; dette vilkåret (G9c) leser den samme regelen der
--   konsekvensen inntreffer, slik at en rad som mot formodning kom forbi det
--   første laget, ikke kan bære en publisering.
--
--   **Gammel kontroll.** En bekreftelse av et smalere evidenssett er ikke en
--   bekreftelse av det settet som ville blitt publisert. Sekvensen «kontroller →
--   legg til en lenke → publiser» var lovlig, og den nye lenken kan være nettopp
--   den motstridende evidensen kontrollen skulle lete etter
--   (ANTIDEP_CONSTITUTION.md §9, KNOWLEDGE_MODEL.md §19.2). G9b sammenligner
--   avtrykket kontrollen ble registrert med (migrasjon 005j) mot settet slik det
--   er nå — samme mekanisme G13 bruker for godkjenningen, og av samme grunn:
--   en tidssammenligning er ikke samtidighetssikker.
--
-- Fremoverskrivende: ingen merget migrasjon er endret. Gatefunksjonen gjenskapes
-- i sin helhet med to nye vilkår lagt inn etter G9, og resten ordrett som i
-- migrasjon 20260907093000.
--
-- Styrende dokumenter:
--   docs/ANTIDEP_CONSTITUTION.md §4, §9, §10, §11, §12, §14
--   docs/DATABASE_ARCHITECTURE.md §30, §38, §46, §58
--   docs/EVIDENCE_PIPELINE.md §39-§41, §51 publiseringsporter
--   docs/KNOWLEDGE_MODEL.md §19.2
--   docs/MVP_IMPLEMENTATION_PLAN.md §42, §74.30-§74.34
-- ============================================================================

create or replace function knowledge.assert_claim_revision_publishable(p_claim_revision_id uuid)
  returns void
  language plpgsql
  set search_path = ''
as $$
declare
  v_claim_id uuid;
  v_knowledge_type knowledge.knowledge_type;
  v_retired_at timestamptz;
  v_offenders text;
  v_latest_decision workflow.review_outcome;
  v_approved_digest text;
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
  'Publiseringsgaten. Uendret fra migrasjon 20260907093000 bortsett fra G9b og G9c. G9b krever at den gjeldende claim-verifikasjonens verified_evidence_set_digest er avtrykket av evidenssettet slik det er nå: en bekreftelse av et smalere grunnlag er ikke en bekreftelse av det som ville blitt publisert, og sekvensen «kontroller, legg til en lenke, publiser» var lovlig uten vilkåret (KNOWLEDGE_MODEL.md §19.2, ANTIDEP_CONSTITUTION.md §9). G9c krever at aktøren bak den gjeldende kontrollen hadde mandat til å utføre den (workflow.claim_verifier_has_mandate), lest på radens eget verified_at slik at en senere avsluttet rolletildeling ikke opphever en kontroll som var legitim da den ble gjort. De tre vilkårene G9, G9b og G9c leser den samme raden, hentet én gang, slik at de aldri kan bli uenige om hvilken kontroll som er den gjeldende.';
