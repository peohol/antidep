# Produktinformasjonsarkitektur

Forsiden viser bare ærlig utviklingsstatus og ingen klinisk kunnskap. Klinikerflaten er én renderer, brukt både av klinikeren og av den faglige sluttkontrollen.

`/kandidater` viser kandidatene kalleren har mandat til å se, og `/kandidater/:id` viser hele kandidatinnholdet med kildedekningen, sluttkontrollen og publiseringen på samme side. Sluttkontroll og publisering står som to seksjoner med hver sin knapp og hver sin begrunnelse, fordi det er to handlinger med hvert sitt mandat.

`/publisert` viser det Antidep faktisk publiserer nå, og `/publisert/:claimId` viser ett publisert innhold: den forseglede raden ordrett, proveniensen tilbake til kandidaten, sluttkontrollen og publiseringshendelsen, hele historikken, og handlingene for tilbaketrekking og rollback. Historikken vises også når ingenting er publisert: en tilbaketrekking som ikke vises, er ikke synlig. Den publiserte flaten krever innlogging, fordi det forseglede innholdet bærer ordrette kildeutdrag og offentlig gjengivelsesrett er vurdert separat.

Rendereren er den samme for kliniker og faglig sluttkontroll. Progressiv fordypning: konklusjon og sikkerhet → forklaring → studier og motstridende funn → kildeutdrag med kontekst og lokalisering → versjon og korte kontrollrapporter. Forbehold som endrer klinisk mening skal stå i hovedteksten.

Internt utkast er privat selv om rendereren deles. Originaldokumenter er private. Offentlige utdrag begrenses av rettigheter. Gamle review-, ekstraksjons- og registreringsadresser er ikke produktinnganger.
