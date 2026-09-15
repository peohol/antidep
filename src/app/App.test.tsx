import '@testing-library/jest-dom/vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { describe, expect, it } from 'vitest'
import { AppLayout } from './App'

describe('Antidep 2-skallet', () => {
  it('viser ærlig resetstatus uten klinisk prototypeinnhold', () => {
    render(
      <MemoryRouter>
        <AppLayout />
      </MemoryRouter>,
    )
    expect(
      screen.getByRole('heading', { name: 'Kunnskapsgrunnlaget bygges på nytt' }),
    ).toBeVisible()
    expect(screen.getByText(/Ingen klinisk veiledning/)).toBeVisible()
    expect(screen.queryByRole('button')).not.toBeInTheDocument()
  })

  it.each(['/review', '/extraction-review', '/evidence/new', '/drugs/sertralin'])(
    'stenger gammel direkteadresse %s',
    (path) => {
      render(
        <MemoryRouter initialEntries={[path]}>
          <AppLayout />
        </MemoryRouter>,
      )
      expect(screen.getByRole('heading', { name: 'Siden finnes ikke' })).toBeVisible()
    },
  )
})
