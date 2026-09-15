import { describe, expect, it } from 'vitest'
import { HOME_PATH, homePath } from './routes'

describe('routes', () => {
  it('har bare reset-skallet som aktiv inngang', () => {
    expect(HOME_PATH).toBe('/')
    expect(homePath()).toBe('/')
  })
})
