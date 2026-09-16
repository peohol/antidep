// ============================================================================
// Den tekniske problemoversiktens eneste vei til databasen
//
// To kall, og de er med vilje forskjellige i hvordan de avviser:
//
//   board    krever admin-mandat, og sier fra når det mangler
//   summary  svarer stille «ikke synlig» til alle andre
//
// Tellingen leses av navigasjonen på hver side. Et avslag der ville blitt til
// en feilmelding for hver eneste innloggede bruker som ikke er admin — og en
// feilmelding om noe de verken kan eller skal gjøre noe med, er nettopp det
// issue #99 ber om at forsvinner.
// ============================================================================

import { antidepClient, callRpc, type TechnicalArea } from './gateway'
import {
  parseTechnicalProblemSummary,
  parseTechnicalProblems,
  type TechnicalProblem,
  type TechnicalProblemSummary,
} from '../lib/technical-problems'

const AREA: TechnicalArea = 'work_queue'

export interface TechnicalGateway {
  list(): Promise<readonly TechnicalProblem[]>
  summary(): Promise<TechnicalProblemSummary>
}

export function createTechnicalGateway(): TechnicalGateway {
  const client = antidepClient()

  return {
    async list() {
      return callRpc(client, {
        fn: 'technical_problem_board',
        area: AREA,
        parse: parseTechnicalProblems,
        wording: {
          not_authorized:
            'Den tekniske problemoversikten er for administratorer. Ta kontakt med en ' +
            'administrator hvis du skulle hatt tilgang.',
          unavailable: 'Antidep får ikke hentet problemoversikten akkurat nå. Prøv igjen om litt.',
        },
      })
    },

    async summary() {
      return callRpc(client, {
        fn: 'technical_problem_summary',
        area: AREA,
        parse: parseTechnicalProblemSummary,
      })
    },
  }
}
