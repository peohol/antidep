-- ============================================================================
-- Migrasjon 013h-i — identifikatorene en oppdaget kilde faktisk har
--
-- Kildeoppdagelsen registrerer kandidater med den identifikatoren treffet
-- hadde: en DOI, en PMID, en PMCID, en adresse eller et forsøksregisternummer
-- (SOURCE_POLICY.md §4.3). Bare de to første fantes som identifikatorsystem, og
-- da kunne ikke de tre siste kjennes igjen: den samme myndighetssiden funnet i
-- to monografiutgaver ville blitt to kilder, og det private kildebiblioteket
-- ville ikke funnet igjen noe det alt hadde.
--
-- Enumverdier legges til i sin egen migrasjon. En ny verdi kan ikke brukes i
-- den samme transaksjonen som la den til, og innholdet som bruker dem, kommer
-- derfor i migrasjonen etter denne.
-- ============================================================================

alter type knowledge.source_identifier_system add value 'pmcid' after 'pmid';
alter type knowledge.source_identifier_system add value 'url' after 'pmcid';
alter type knowledge.source_identifier_system add value 'registry_id' after 'url';

comment on type knowledge.source_identifier_system is
  'Identifikatorsystemene en kilde kan kjennes igjen på: doi og pmid for forskningslitteratur, pmcid for et åpent arkiv, url for en myndighets- eller utgiveradresse, og registry_id for et forsøksregisternummer. Systemene finnes fordi identiteten er det som gjør at den samme publikasjonen funnet to ganger blir én kilde — og at det private kildebiblioteket finner igjen noe Antidep alt har (SOURCE_POLICY.md §1, §4.3).';
