import js from '@eslint/js'
import { defineConfig, globalIgnores } from 'eslint/config'
import eslintConfigPrettier from 'eslint-config-prettier'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import globals from 'globals'
import tseslint from 'typescript-eslint'

export default defineConfig([
  // `supabase/.temp/` er CLI-ens egne arbeidsfiler fra en kjørende lokal
  // stack — gitignorert, men eslint leser katalogen likevel, og en
  // utvikler som har kjørt `npm run db:start` fikk da over to hundre feil
  // i kode Antidep verken har skrevet eller kan rette.
  globalIgnores(['dist', 'coverage', 'supabase/.temp']),
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      tseslint.configs.recommended,
      reactHooks.configs.flat['recommended-latest'],
      reactRefresh.configs.vite,
    ],
    languageOptions: {
      globals: globals.browser,
    },
  },
  eslintConfigPrettier,
])
