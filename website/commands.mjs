import fs from 'node:fs';

// The command reference, read from the sources that define the commands, so
// the published list cannot drift from the release it documents.
const read = path => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const escapeHTML = text => text.replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));
const row = (command, description) => `<div class="c-file"><code>${escapeHTML(command)}</code><small>${escapeHTML(description)}</small></div>`;

// What each application binary command does; CommandLine::USAGE lists them.
const APPLICATION = {
  serve: 'Serve HTTP on the private socket frappe dev names, with Cold Brew’s workers, maintenance and schedules. Refuses to start with pending migrations.',
  work: 'Run Cold Brew’s workers, maintenance and schedules without HTTP. --queues and --concurrency replace CARAMEL_WORKER_QUEUES and CARAMEL_WORKER_CONCURRENCY; --no-scheduler leaves schedules to other processes.',
  seed: 'Load db/seeds.cr into the database.',
  routes: 'Print every route with its action, contract and ingress.',
  schema: 'Print the declared schema as JSON.',
  drift: 'Compare the database with the declared schema; exits 1 when they differ.',
  translations: 'List the keys each locale still takes from the default locale; exits 1 while any is missing.',
  migrate: 'Lint and apply pending migrations; --dev-override relaxes the linter in development.',
  lint: 'Lint pending migrations without applying them; --dev-override relaxes the linter in development.',
};

// Frappé's commands: each `Command.new` in Commands::TABLE, with adjacent
// string literals joined and the constants it interpolates resolved.
export function frappeCommands() {
  const source = read('src/frappe/commands.cr');
  const start = source.indexOf('TABLE = [');
  const table = source.slice(start, source.indexOf('\n    ]\n', start));
  const constants = {
    MODE: source.match(/MODE = "([^"]+)"/)[1],
    'Latte::Postgres::MAX_TEST_WORKERS': read('src/latte/postgres.cr').match(/MAX_TEST_WORKERS\s*=\s*(\d+)/)[1],
  };
  const commands = [];
  for (let at = table.indexOf('Command.new('); at !== -1; at = table.indexOf('Command.new(', at)) {
    const args = [{strings: [], rest: ''}];
    let depth = 0;
    let i = at + 'Command.new('.length;
    for (; i < table.length; i++) {
      const c = table[i];
      if (c === '"') {
        let value = '';
        for (i++; table[i] !== '"'; i++) {
          if (table[i] === '\\') { value += table[++i]; continue; }
          if (table.startsWith('#{', i)) {
            const end = table.indexOf('}', i);
            const name = table.slice(i + 2, end);
            if (!(name in constants)) throw new Error(`commands.cr interpolates ${name}; teach website/commands.mjs its value`);
            value += constants[name];
            i = end;
            continue;
          }
          value += table[i];
        }
        args.at(-1).strings.push(value);
      } else if (c === '(') depth++;
      else if (c === ')' && depth-- === 0) break;
      else if (c === ',' && depth === 0) args.push({strings: [], rest: ''});
      else args.at(-1).rest += c;
    }
    at = i;
    const [syntax, description, ...options] = args.filter(arg => arg.strings.length || arg.rest.trim());
    const option = name => options.find(arg => arg.rest.trim().startsWith(`${name}:`));
    commands.push({
      syntax: `frappe ${syntax.strings.join('')}`,
      description: description.strings.join(''),
      anywhere: /false/.test(option('project')?.rest ?? ''),
      deprecated: option('deprecated')?.strings.join(''),
    });
  }
  if (commands.length === 0) throw new Error('No commands found in src/frappe/commands.cr');
  return commands;
}

// The application binary's commands, from CommandLine::USAGE.
export function applicationCommands() {
  const source = read('src/caramel/command_line.cr');
  const usage = source.slice(source.indexOf('USAGE = ['), source.indexOf('].join', source.indexOf('USAGE = [')));
  return [...usage.matchAll(/"([^"]+)"/g)].map(([, syntax]) => {
    const name = syntax.split(' ')[0];
    if (!APPLICATION[name]) throw new Error(`Describe the application command ${name} in website/commands.mjs`);
    return {syntax: `APP ${syntax}`, description: APPLICATION[name]};
  });
}

// Latte's commands, from the help text src/latte.cr prints.
export function latteCommands() {
  const source = read('src/latte.cr');
  const start = source.indexOf('puts <<-TEXT', source.indexOf('when ["--help"]'));
  const text = source.slice(source.indexOf('\n', start) + 1, source.indexOf('\n      TEXT', start))
    .replace(/ \\\n\s*/g, ' ');
  const commands = [...text.matchAll(/^ {8}(\S+(?: \S+)*?) {2,}(\S.*)$/gm)]
    .map(([, command, description]) => ({syntax: `latte ${command}`, description}));
  if (commands.length === 0) throw new Error('No commands found in src/latte.cr');
  return commands;
}

// The rows of one list on the commands page.
export function commandRows(kind) {
  const commands = {frappe: frappeCommands, app: applicationCommands, latte: latteCommands}[kind]();
  return commands.map(command => {
    let description = command.description;
    if (command.anywhere) description += ' Works outside an application.';
    if (command.deprecated) description += ` Deprecated: ${command.deprecated}`;
    return row(command.syntax, description);
  }).join('');
}
