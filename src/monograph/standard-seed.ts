// ============================================================================
// Standardregisteret slik databasen skal bære det
//
// Migrasjonen som seeder `knowledge.monograph_*`-registeret skriver ikke av 80
// rader for hånd. Den bærer nøyaktig den teksten denne modulen bygger av
// `standard.ts`, og `standard-seed.test.ts` bygger den på nytt og krever at
// migrasjonsfilen inneholder den ordrett.
//
// Det er den samme formen `model-roles.ts` har mot migrasjon 009c: verdiene må
// finnes på begge sider av databasegrensen, og den eneste holdbare måten å ha
// dem to steder på, er at et avvik stopper kontrollene framfor å bli oppdaget
// av en manglende rad i et dekningskart.
//
// Migrasjonen er historikk og endres ikke. En ny standardversjon er en ny
// migrasjon med sin egen seed, og de gamle radene blir stående — et
// dekningskart bærer versjonen det ble opprettet under, og spørsmålet under et
// eksisterende svar skal aldri kunne endre seg (MONOGRAPH_STANDARD.md §9).
// ============================================================================

import {
  MONOGRAPH_STANDARD_VERSION,
  PRESCRIBED_SCOPE_VALUES,
  QUESTION_TEMPLATES,
  SEARCH_TRACKS,
  SOURCE_PROFILES,
} from './standard.ts'

/** En SQL-strengliteral. Apostrofen dobles; ingenting annet endres. */
function literal(value: string): string {
  return `'${value.replace(/'/g, "''")}'`
}

function optionalLiteral(value: string | null): string {
  return value === null ? 'null' : literal(value)
}

function enumArray(values: readonly string[], type: string): string {
  if (values.length === 0) {
    return `array[]::${type}[]`
  }
  return `array[${values.map(literal).join(', ')}]::${type}[]`
}

const VERSION = literal(MONOGRAPH_STANDARD_VERSION)

/**
 * Hele seeden, som én blokk SQL.
 *
 * Rekkefølgen er standardens egen: profilene først, fordi malene peker på dem,
 * og sporene sist. Ingen rad har en id fra denne siden — identiteten er
 * databasens, og koblingene slås opp på de stabile kodene.
 */
export function monographStandardSeedSql(): string {
  const parts: string[] = []

  parts.push(
    [
      'insert into knowledge.monograph_source_profiles',
      '  (standard_version, code, ordinal, question, first_choice, supplement)',
      'values',
      SOURCE_PROFILES.map(
        (profile, index) =>
          `  (${VERSION}, ${literal(profile.code)}, ${String(index + 1)},\n` +
          `   ${literal(profile.question)},\n` +
          `   ${literal(profile.firstChoice)},\n` +
          `   ${literal(profile.supplement)})`,
      ).join(',\n'),
      ';',
    ].join('\n'),
  )

  parts.push(
    [
      'insert into knowledge.monograph_question_templates',
      '  (standard_version, code, ordinal, section, prompt, requirement, requirement_text,',
      '   condition_text, conditional_deepening, answer_forms, open_source_profiles, expansion_axes)',
      'values',
      QUESTION_TEMPLATES.map(
        (template, index) =>
          `  (${VERSION}, ${literal(template.code)}, ${String(index + 1)},\n` +
          `   ${literal(template.section)},\n` +
          `   ${literal(template.prompt)},\n` +
          `   ${literal(template.requirement)}, ${literal(template.requirementText)},\n` +
          `   ${optionalLiteral(template.condition)}, ${optionalLiteral(template.conditionalDeepening)},\n` +
          `   ${enumArray(template.forms, 'knowledge.monograph_answer_form')},\n` +
          `   ${template.openSourceProfiles ? 'true' : 'false'},\n` +
          `   ${enumArray(template.expansionAxes, 'knowledge.monograph_scope_axis')})`,
      ).join(',\n'),
      ';',
    ].join('\n'),
  )

  const links = QUESTION_TEMPLATES.flatMap((template) =>
    template.sourceProfiles.map((profile, index) => ({
      template: template.code,
      profile,
      ordinal: index + 1,
    })),
  )

  parts.push(
    [
      'insert into knowledge.monograph_template_profiles (template_id, profile_id, ordinal)',
      'select t.id, p.id, v.ordinal',
      'from (values',
      links
        .map(
          (link) =>
            `  (${literal(link.template)}, ${literal(link.profile)}, ${String(link.ordinal)})`,
        )
        .join(',\n'),
      ') as v(template_code, profile_code, ordinal)',
      `join knowledge.monograph_question_templates t`,
      `  on t.standard_version = ${VERSION} and t.code = v.template_code`,
      `join knowledge.monograph_source_profiles p`,
      `  on p.standard_version = ${VERSION} and p.code = v.profile_code;`,
    ].join('\n'),
  )

  parts.push(
    [
      'insert into knowledge.monograph_search_tracks (standard_version, code, ordinal, label)',
      'values',
      SEARCH_TRACKS.map(
        (track, index) =>
          `  (${VERSION}, ${literal(track.code)}, ${String(index + 1)}, ${literal(track.label)})`,
      ).join(',\n'),
      ';',
    ].join('\n'),
  )

  const trackLinks = SEARCH_TRACKS.flatMap((track) =>
    track.profiles.map((profile) => ({ track: track.code, profile })),
  )

  parts.push(
    [
      'insert into knowledge.monograph_search_track_profiles (track_id, profile_id)',
      'select k.id, p.id',
      'from (values',
      trackLinks.map((link) => `  (${literal(link.track)}, ${literal(link.profile)})`).join(',\n'),
      ') as v(track_code, profile_code)',
      `join knowledge.monograph_search_tracks k`,
      `  on k.standard_version = ${VERSION} and k.code = v.track_code`,
      `join knowledge.monograph_source_profiles p`,
      `  on p.standard_version = ${VERSION} and p.code = v.profile_code;`,
    ].join('\n'),
  )

  parts.push(
    [
      'insert into knowledge.monograph_prescribed_scope_values',
      '  (template_id, axis, label, ordinal)',
      'select t.id, v.axis::knowledge.monograph_scope_axis, v.label, v.ordinal',
      'from (values',
      PRESCRIBED_SCOPE_VALUES.map(
        (value, index) =>
          `  (${literal(value.template)}, ${literal(value.axis)}, ${literal(value.label)}, ${String(index + 1)})`,
      ).join(',\n'),
      ') as v(template_code, axis, label, ordinal)',
      `join knowledge.monograph_question_templates t`,
      `  on t.standard_version = ${VERSION} and t.code = v.template_code;`,
    ].join('\n'),
  )

  return parts.join('\n\n')
}
