# Produktinformasjonsarkitektur

Forsiden viser bare ærlig utviklingsstatus og ingen klinisk kunnskap. Klinikerflaten er én renderer, brukt både av klinikeren og av den faglige sluttkontrollen: `/kandidater` viser kandidatene kalleren har mandat til å se, og `/kandidater/:id` viser hele kandidatinnholdet med kildedekningen og sluttkontrollen på samme side.

Rendereren er den samme for kliniker og faglig sluttkontroll. Progressiv fordypning: konklusjon og sikkerhet → forklaring → studier og motstridende funn → kildeutdrag med kontekst og lokalisering → versjon og korte kontrollrapporter. Forbehold som endrer klinisk mening skal stå i hovedteksten.

Internt utkast er privat selv om rendereren deles. Originaldokumenter er private. Offentlige utdrag begrenses av rettigheter. Gamle review-, ekstraksjons- og registreringsadresser er ikke produktinnganger.
