// The Markdown edition: a page's rendered HTML as Markdown for agents. It reads
// only the tags the pages emit and throws on any other, so a new tag fails the build.
const decode = text => text.replace(/&(lt|gt|quot|#39|amp);/g, (_, entity) =>
  ({lt: '<', gt: '>', quot: '"', '#39': "'", amp: '&'}[entity]));
const attribute = (node, name) => node.attrs.match(new RegExp(`\\b${name}="([^"]*)"`))?.[1];
const classes = node => (attribute(node, 'class') ?? '').split(/\s+/);
const INLINE = new Set(['code', 'strong', 'b', 'a', 'span', 'small']);
// A link destination with no space, parenthesis or angle bracket left to end it early.
const destination = url => url.replace(/[ ()<>]/g, c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);

// One llms.txt entry; brackets in the name would end its link text early.
export const llmsEntry = (name, url, description) =>
  `- [${name.replace(/[[\]]/g, '\\$&')}](${destination(url)}): ${description}`;

function parse(html) {
  const root = {tag: '#root', attrs: '', children: []};
  const stack = [root];
  for (const match of html.matchAll(/<(\/?)([a-z][a-z0-9-]*)\b([^>]*)>|([^<]+)/g)) {
    const [, close, tag, attrs, text] = match;
    let top = stack[stack.length - 1];
    if (text !== undefined) top.children.push(text);
    else if (close) {
      // HTML lets an <li> end at its list's end tag; the uploads recipe relies on it.
      while (top.tag !== tag && top.tag === 'li' && stack.length > 1) { stack.pop(); top = stack[stack.length - 1]; }
      if (top.tag !== tag) throw new Error(`Markdown edition: </${tag}> closes <${top.tag}> in …${html.slice(Math.max(0, match.index - 160), match.index + 6)}`);
      stack.pop();
    } else {
      const node = {tag, attrs, children: []};
      top.children.push(node);
      stack.push(node);
    }
  }
  if (stack.length !== 1) throw new Error(`Markdown edition: <${stack[stack.length - 1].tag}> is not closed`);
  return root;
}

const text = node => typeof node === 'string' ? decode(node) : node.children.map(text).join('');

export function markdown(html, link) {
  const unknown = tag => { throw new Error(`Markdown edition: no conversion for <${tag}>`); };
  const inline = node => {
    // A < or > in prose stays text: a backslash keeps Markdown from reading it as HTML.
    if (typeof node === 'string') return decode(node).replace(/\s+/g, ' ').replace(/[<>]/g, '\\$&');
    const inner = () => node.children.map(inline).join('');
    switch (node.tag) {
      case 'code': {
        const code = text(node);
        const ticks = '`'.repeat(Math.max(0, ...[...code.matchAll(/`+/g)].map(m => m[0].length)) + 1);
        const pad = /^`|`$/.test(code) ? ' ' : '';
        return ticks + pad + code + pad + ticks;
      }
      case 'strong': case 'b': return `**${inner().trim()}**`;
      case 'a': return `[${inner().trim()}](${destination(link(decode(attribute(node, 'href'))))})`;
      case 'span': case 'small': return inner();
      default: return unknown(node.tag);
    }
  };
  const line = node => node.children.map(inline).join('').replace(/ +/g, ' ').trim();
  const blocks = (children, out) => {
    let run = [];
    const flush = () => { const joined = run.map(inline).join('').replace(/ +/g, ' ').trim(); if (joined) out.push(joined); run = []; };
    for (const child of children) {
      if (typeof child === 'string' || INLINE.has(child.tag)) run.push(child);
      else { flush(); block(child, out); }
    }
    flush();
    return out;
  };
  const list = node => node.children.filter(child => child.tag === 'li').map((item, index) => {
    const marker = node.tag === 'ol' ? `${index + 1}. ` : '- ';
    // Paragraphs of one item keep a blank line between them.
    return marker + blocks(item.children, []).join('\n\n')
      .replace(/\n(?=.)/g, '\n' + ' '.repeat(marker.length));
  }).join('\n');
  const table = node => {
    const rows = [];
    const walk = parent => parent.children.forEach(child => {
      if (child.tag === 'tr') rows.push(child.children.filter(cell => cell.tag === 'th' || cell.tag === 'td')
        .map(cell => line(cell).replaceAll('|', '\\|')));
      else if (typeof child !== 'string') walk(child);
    });
    walk(node);
    const [head, ...body] = rows;
    return [head, head.map(() => '---'), ...body].map(row => `| ${row.join(' | ')} |`).join('\n');
  };
  const block = (node, out) => {
    switch (node.tag) {
      case 'h1': case 'h2': case 'h3': {
        const id = attribute(node, 'id');
        out.push(`${'#'.repeat(Number(node.tag[1]))} ${line(node)}${id ? ` {#${id}}` : ''}`);
        return;
      }
      case 'p': out.push(line(node)); return;
      case 'header': out.push(`**${line(node)}**`); return;
      case 'pre': {
        const code = node.children.find(child => child.tag === 'code') ?? unknown('pre without code');
        const body = text(code);
        const language = attribute(code, 'class')?.match(/language-([a-z]+)/)?.[1] ?? '';
        const fence = '`'.repeat(Math.max(2, ...[...body.matchAll(/`+/g)].map(m => m[0].length)) + 1);
        out.push(`${fence}${language}\n${body.replace(/\n$/, '')}\n${fence}`);
        return;
      }
      case 'ul': case 'ol': out.push(list(node)); return;
      case 'table': out.push(table(node)); return;
      case 'button': return; // after links(), a remaining button is a control on the page, not content
      case 'div': {
        const kinds = classes(node);
        if (kinds.includes('c-tagrow')) out.push(node.children.filter(child => child.tag).map(line).join(' · '));
        else if (kinds.includes('c-note')) out.push(blocks(node.children, []).map(b => b.replace(/^/gm, '> ')).join('\n>\n'));
        else if (kinds.includes('c-files')) out.push(node.children.filter(child => child.tag).map(row => {
          const [file, why] = row.children.filter(child => child.tag);
          return `- ${inline(file)}: ${line(why)}`;
        }).join('\n'));
        else if (kinds.includes('c-next')) out.push(node.children.filter(child => child.tag).map(inline).join(' · '));
        else blocks(node.children, out);
        return;
      }
      default: unknown(node.tag);
    }
  };
  return blocks(parse(html).children, []).join('\n\n') + '\n';
}
