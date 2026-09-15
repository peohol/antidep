import { pathToFileURL } from 'node:url'

// Accept only the unambiguous URI emitted by the local Supabase stack. In
// particular, libpq query parameters and service/hostaddr defaults can change
// the actual destination even when the URI appears to name localhost.
export function assertLocalTestDatabase(value, env = process.env) {
  const pattern = /^postgres(?:ql)?:\/\/postgres:postgres@(.+):([1-9][0-9]{0,4})\/postgres$/
  const match = pattern.exec(value)
  if (
    !match ||
    match[0] !== value ||
    !['127.0.0.1', 'localhost', '[::1]'].includes(match[1]) ||
    Number(match[2]) > 65535 ||
    ['PGHOSTADDR', 'PGSERVICE', 'PGSERVICEFILE'].some((key) => env[key])
  ) {
    // Never echo a rejected connection string: it can contain real credentials.
    throw new Error('Database tests require local Supabase without connection overrides.')
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length !== 3) throw new Error('Expected one database URI.')
    assertLocalTestDatabase(process.argv[2])
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
