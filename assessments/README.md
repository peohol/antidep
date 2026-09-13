# Vurderingsforslag

Her ligger **vurderingsforslagene**: én foreslått `EvidenceAssessment` per fil —
graderingen av sikkerheten i kunnskapsgrunnlaget for én påstandsrevisjon.

Filene er **lokale arbeidsfiler**. De er gitignorerte og skal ikke commites: et
forslag er en faglig vurdering av hvor sikkert grunnlaget er, og den vurderingen
skal ende som en rad i basen med proveniens — ikke som en fil i repoet.

## 1. Hvorfor dette er et eget ledd

`EVIDENCE_PIPELINE.md` §61 skiller `ClaimAgent` — som formulerer påstanden — fra
`EvidenceAssessor`, som graderer grunnlaget, og krever at ansvarsgrensen
samtidig er en teknisk grense: «hver rolle som faktisk skriver til
kunnskapsbasen, har en egen aktør med en egen identitet og en egen legitimasjon
… En rolle som bare er et navn i en prompt, er ingen grense.»

Fram til migrasjon 005am skrev synteseveien både påstanden og den endelige
GRADE-vurderingen i den samme transaksjonen, med den samme legitimasjonen.
Vurderingen har nå sin egen rolle (`evidence_assessment`), sin egen identitet
(`agent-identity:evidence-assessment-01`) og sin egen skrivevei
(`api.register_evidence_assessment`).

## 2. Hvor forslaget kommer inn i kjeden

```text
npm run agent:synthesise-claims   påstand, revisjon og evidenslenker
  → npm run agent:verify-claims     en SEPARAT kontroll mot kildene
  → npm run agent:assess-evidence   DENNE filen: graderingen av grunnlaget
  → /review                         den faglige vurderingen, av et menneske
```

Rekkefølgen er `MVP_IMPLEMENTATION_PLAN.md` §15 sin, og databasen håndhever den:
en revisjon uten en gjeldende, bekreftet claim-verifikasjon som dekker nøyaktig
det evidenssettet som ligger der nå, avvises.

Grunnen er faglig. GRADE-domenene **indirekthet**, **upresisjon** og
**inkonsistens** er vurderinger av hvor godt evidensen treffer påstanden slik den
er formulert — populasjon, komparator, tidsramme, retning og størrelse — og det
er nøyaktig det claim-verifikasjonen kontrollerer. En gradering gitt før noen
hadde kontrollert at kilden faktisk støtter ordlyden, ville vært en gradering av
et ukontrollert samsvar.

> `EVIDENCE_PIPELINE.md` nummererer fasene i motsatt rekkefølge (§34 før §39).
> Motstriden er reell og er ført i hodekommentaren til migrasjon 005am; den
> strengeste lesningen er valgt.

## 3. Hva skriveveien krever

- revisjonen finnes, er en `evidence_synthesis`, og påstanden er ikke trukket
  tilbake
- revisjonen har minst én evidenslenke
- hvert lenket evidensfunn har fortsatt nådd kontrollnivået `EVIDENCE_PIPELINE.md`
  §26 og §27 krever — lest på nytt, på vurderingstidspunktet
- den gjeldende claim-verifikasjonen konkluderer med `verified`, dekker det
  evidenssettet som ligger der nå, og ble gjort av en aktør med mandat
- `evidence_set_digest` i filen er avtrykket av evidenssettet slik det er nå
- revisjonen har ikke en vurdering fra før — det er nøyaktig én per revisjon

## 4. Formen

```json
{
  "proposal_version": "antidep/evidence-assessment-proposal@1",
  "generated_by": {
    "producer": "model",
    "provider": "…",
    "model": "…",
    "model_version": "…",
    "prompt_template_version": "…",
    "drafted_at": "2026-09-24T09:00:00Z",
    "request_digest": null
  },
  "claim_revision_id": "…",
  "evidence_set_digest": "sha256-v1:…",
  "assessment": {
    "framework": "grade",
    "certainty_level": "very_low",
    "risk_of_bias": "serious",
    "inconsistency": "not_assessable",
    "indirectness": "serious",
    "imprecision": "serious",
    "publication_bias": "not_assessable",
    "other_considerations": null,
    "rationale": "…",
    "evidence_gap": "…"
  }
}
```

`evidence_set_digest` står i utskriften fra `npm run agent:synthesise-claims`, og
i claim-review-flaten. Den er ikke en formalitet: vurderingen **forsegler**
evidenssettet, så en lenke som kommer til mellom lesningen og registreringen,
ville ellers blitt stilltiende dekket av en gradering som aldri så den. Databasen
sammenligner avtrykket under en lås på revisjonsraden og avviser et utdatert
utkast.

## 5. Hva filen ikke får bestemme

| Felt                      | Hvorfor ikke                                                                                |
| ------------------------- | ------------------------------------------------------------------------------------------- |
| `created_by_actor_id`     | Aktøren er kjøringens egen, hentet av databasen fra legitimasjonen                          |
| `assessed_at`             | Tidspunktet for den faglige vurderingen eies av databasen, som på kontrollene               |
| `assessed_knowledge_type` | Kunnskapstypen leses av revisjonen vurderingen gjelder, og kan ikke være noe annet enn dens |

Et ukjent felt avvises framfor å bli ignorert: en skrivefeil i et feltnavn ville
ellers blitt til en manglende verdi i en klinisk vurdering.

## 6. «Ingen vurderbar evidens» er ikke en femte GRADE-grad

Enten er alle fem domenene vurdert og `certainty_level` er `high`, `moderate`,
`low` eller `very_low` — eller så er `certainty_level` lik
`no_assessable_evidence`, alle fem domenene står tomme, og `evidence_gap` sier
hva som mangler.

Et domene som ikke lar seg bedømme, er `not_assessable` — ikke tomt. Og et
grunnlag som ikke lar seg vurdere, skal aldri se ut som lav risiko eller ingen
effekt (`ANTIDEP_CONSTITUTION.md` §6, §17).

## 7. Kjøringen er ikke idempotent

Databasen tillater nøyaktig én vurdering per revisjon, så en fil kjørt to ganger
avvises den andre gangen med en setning som sier det. Skulle utfallet av en
kjøring være **uavklart** — en forbindelse som ryker, et svar som ikke har formen
kontrakten lover — stopper kjøringen og lukkes som `failed`. Kontroller `/review`
før du kjører om igjen.
