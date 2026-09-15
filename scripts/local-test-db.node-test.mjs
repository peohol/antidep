import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { assertLocalTestDatabase } from './local-test-db.mjs'

const scripts = dirname(fileURLToPath(import.meta.url))
const local = 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
const remote = 'postgresql://postgres:do-not-print-me@db.example.com:5432/postgres'

for (const host of ['127.0.0.1', 'localhost', '[::1]']) {
  test(`accepts the local Supabase URI for ${host}`, () => {
    assert.doesNotThrow(() =>
      assertLocalTestDatabase(`postgresql://postgres:postgres@${host}:54322/postgres`, {}),
    )
  })
}

for (const value of [
  remote,
  '',
  `${local}?host=db.example.com`,
  `${local}?hostaddr=203.0.113.1`,
  `${local}?service=production`,
  `${local}#fragment`,
  local.replace('54322', '65536'),
  local.replace('54322', '0'),
  local.replace(':54322', ''),
  local.replace('127.0.0.1', '127.0.0.1.example.com'),
  local.replace(/\/postgres$/, '/production'),
  `${local}\n`,
  'host=localhost dbname=postgres',
]) {
  test(`rejects unsafe URI: ${value.replace('do-not-print-me', 'redacted')}`, () => {
    assert.throws(() => assertLocalTestDatabase(value, {}), /local Supabase/)
  })
}

for (const key of ['PGHOSTADDR', 'PGSERVICE', 'PGSERVICEFILE']) {
  test(`rejects libpq ${key} overrides`, () => {
    assert.throws(() => assertLocalTestDatabase(local, { [key]: 'override' }), /overrides/)
  })
}

function runWrapper(args, extraEnv = {}) {
  const root = mkdtempSync(join(tmpdir(), 'antidep-db-safety-'))
  try {
    mkdirSync(join(root, 'scripts'))
    mkdirSync(join(root, 'bin'))
    for (const name of ['db-lock-antidep2.sh', 'local-test-db.mjs']) {
      copyFileSync(join(scripts, name), join(root, 'scripts', name))
    }
    const calls = join(root, 'calls')
    writeFileSync(calls, '')
    writeFileSync(
      join(root, 'bin', 'psql'),
      `#!/usr/bin/env bash
printf 'psql %s\\n' "$*" >> "$DB_TEST_CALLS"
case "$*" in
  *'select text_extraction_transform'*) printf 'antidep-reading-order@2\\n' ;;
  *'revoke execute'*) exit "\${DB_TEST_REVOKE_STATUS:-0}" ;;
  *'grant execute'*) exit "\${DB_TEST_GRANT_STATUS:-0}" ;;
esac
`,
      { mode: 0o755 },
    )
    writeFileSync(
      join(root, 'bin', 'npx'),
      `#!/usr/bin/env bash
printf 'npx %s\\n' "$*" >> "$DB_TEST_CALLS"
printf '{"DB_URL":"%s"}\\n' "$DB_TEST_DISCOVERED_URL"
`,
      { mode: 0o755 },
    )
    writeFileSync(
      join(root, 'scripts', 'db-lock-test.sh'),
      `#!/usr/bin/env bash
printf 'child %s\\n' "$*" >> "$DB_TEST_CALLS"
exit "\${DB_TEST_CHILD_STATUS:-0}"
`,
    )
    const env = { ...process.env }
    for (const key of ['PGHOSTADDR', 'PGSERVICE', 'PGSERVICEFILE']) delete env[key]
    const result = spawnSync('bash', [join(root, 'scripts', 'db-lock-antidep2.sh'), ...args], {
      // Deliberately outside the repository: the wrapper must resolve its own scripts.
      cwd: tmpdir(),
      env: {
        ...env,
        PATH: `${join(root, 'bin')}:${env.PATH}`,
        DB_TEST_CALLS: calls,
        DB_TEST_DISCOVERED_URL: local,
        ...extraEnv,
      },
      encoding: 'utf8',
      timeout: 10000,
    })
    assert.ifError(result.error)
    return { ...result, calls: readFileSync(calls, 'utf8') }
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

for (const args of [
  ['--db-url', remote],
  ['--db-url', `${local}?host=db.example.com`],
  ['--db-url'],
  ['--db-url', ''],
  ['--unknown'],
  ['--db-url', local, '--db-url', remote],
  ['--db-url', local, '--db-url', local],
]) {
  test(`rejects unsafe arguments before SQL: ${args[0]} (${args.length})`, () => {
    const result = runWrapper(args)
    assert.notEqual(result.status, 0)
    assert.equal(result.calls, '')
    assert.doesNotMatch(result.stderr, /do-not-print-me/)
  })
}

test('wrapper rejects an unsafe auto-discovered URI before any SQL', () => {
  const result = runWrapper([], { DB_TEST_DISCOVERED_URL: remote })
  assert.notEqual(result.status, 0)
  assert.doesNotMatch(result.calls, /psql|child/)
  assert.doesNotMatch(result.stderr, /do-not-print-me/)
})

test('wrapper passes exactly the validated auto-discovered URI to the child', () => {
  const result = runWrapper([])
  assert.equal(result.status, 0, result.stderr)
  assert.ok(result.calls.includes(`child --db-url ${local}\n`))
  assert.equal(result.calls.split('npx ').length - 1, 1)
  assert.ok(result.calls.indexOf('grant execute') < result.calls.indexOf('child '))
  assert.ok(result.calls.indexOf('child ') < result.calls.indexOf('revoke execute'))
})

test('wrapper preserves a child failure and still restores the grant', () => {
  const result = runWrapper(['--db-url', local], { DB_TEST_CHILD_STATUS: '23' })
  assert.equal(result.status, 23)
  assert.match(result.calls, /revoke execute/)
})

test('a failed restoration cannot yield a green test', () => {
  const result = runWrapper(['--db-url', local], { DB_TEST_REVOKE_STATUS: '41' })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /Failed to close/)
})

test('an unsuccessful grant still attempts restoration and does not run the child', () => {
  const result = runWrapper(['--db-url', local], { DB_TEST_GRANT_STATUS: '42' })
  assert.equal(result.status, 42)
  assert.match(result.calls, /revoke execute/)
  assert.doesNotMatch(result.calls, /child /)
})
