-- ---------------------------------------------------------------------------
-- Migrasjon 014b — ordene de nye søkeveiene trenger
--
-- Denne migrasjonen gjør bare én ting: den legger verdiene til. PostgreSQL
-- nekter å *bruke* en enumverdi i den transaksjonen som la den til, og alle tre
-- brukes av 014c — i en check, i en port og i dataflyttingen av de åpne
-- planene. Derfor ligger de alene, slik 013w gjorde av samme grunn.
--
-- Hvorfor verdiene trengs
--
-- 1. `answer_control` på sporet. `reuse_validity_check` — «hvert brukt svar
--    gjelder fortsatt den samme avgrensningen» — er ikke et søk. Det er en
--    kontroll, og den utføres allerede deterministisk av svarkontrollen
--    (`derivation_basis`) for hvert avledet svar (migrasjon 013i). Å kalle
--    sporet `no_machine_path` var usant: kontrollen *har* en maskinell utfører,
--    den er bare ikke en søkevei. Å kalle det `covered` ville vært verre: da
--    ville et søk som aldri gikk, stått som dekning. Sporet får derfor sitt eget
--    ord, og det sier hvor kontrollen faktisk skjer.
--
-- 2. `selection_opened` på søkerunden. Referanselistene og de siterende
--    arbeidene gjelder de *sentrale* kildene, og hvilke kilder som er sentrale,
--    er kildeoppdagelsens faglige avgjørelse. Når den avgjørelsen er registrert,
--    følger Antideps kode kildene selv — uten at leddet må huske å be om det.
--    Runden er verken planens første eller leddets egen bestilling, og den skal
--    ikke kalles noen av delene.
--
-- 3. `registry_opened` på søkerunden. Får et obligatorisk spor en maskinell
--    søkevei etter at planen ble laget, flyttes sporet tilbake til den
--    maskinelle køen (013x). Fram til nå ble det stående der uten at noen runde
--    utførte det — «selvhelbredende» var halvparten sant. Nå åpner registeret en
--    runde for det, og runden sier hvorfor den finnes.
-- ---------------------------------------------------------------------------

alter type workflow.monograph_track_state add value if not exists 'answer_control';

alter type workflow.monograph_search_request_origin add value if not exists 'selection_opened';
alter type workflow.monograph_search_request_origin add value if not exists 'registry_opened';
