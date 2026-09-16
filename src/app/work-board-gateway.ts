// ============================================================================
// Den åpne arbeidsoversiktens eneste vei til databasen
//
// Ett kall, og ingen flere. Tilstanden er databasens egen: den overlever en
// sideoppfriskning, en ny sesjon og en ny nettleser, fordi ingenting av den
// ligger i React (issue #99, punkt 9).
//
// Flaten er lesbar uten innlogging, og kallet er det eneste `anon` har.
// ============================================================================

import { antidepClient, callRpc, type TechnicalArea } from './gateway'
import { parseWorkBoard, type WorkBoardItem } from '../lib/work-board'

const AREA: TechnicalArea = 'work_queue'

export interface WorkBoardGateway {
  list(): Promise<readonly WorkBoardItem[]>
}

export function createWorkBoardGateway(): WorkBoardGateway {
  const client = antidepClient()

  return {
    async list() {
      return callRpc(client, {
        fn: 'public_work_board',
        area: AREA,
        parse: parseWorkBoard,
        wording: {
          unavailable: 'Antidep får ikke hentet arbeidsoversikten akkurat nå. Prøv igjen om litt.',
          unreadable_answer:
            'Antidep får ikke hentet arbeidsoversikten akkurat nå. Prøv igjen om litt.',
        },
      })
    },
  }
}
