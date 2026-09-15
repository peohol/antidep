# Roadmap

Forrige leveranse — **publisering, tilbaketrekking og rollback** — er implementert.

Den åpnet den kontrollerte veien fra en sluttkontrollert kandidat til publisert klinikerinnhold: publiseringshendelsen navngir det forseglede innholdet, avtrykket og den sluttkontrollen den hviler på; klinikerflaten viser den forseglede raden ordrett framfor en gjenoppbygging; og tilbaketrekking og rollback er nye, synlige hendelser som aldri sletter eller skriver om historikk.

Neste sammenhengende leveranse er **live semantisk modellruntime**, slik at utkastleddene kjøres av en leverandørmodell framfor av et opptak. Datamodellen tar allerede imot det: hver agentrolle har sin registrerte modellidentitet, jobbtilstanden er varig og idempotent, og kjøringene er bundet til uttakene sine. Det som mangler, er legitimasjonen og adapteret — og en ærlig håndtering av hva som skjer når en leverandørmodell svarer noe annet enn opptaket gjorde.
