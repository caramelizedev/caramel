import hljs from './vendor/highlightjs/core.cjs';
import crystal from './vendor/highlightjs/languages/crystal.cjs';
import bash from './vendor/highlightjs/languages/bash.cjs';
import yaml from './vendor/highlightjs/languages/yaml.cjs';
import markdown from './vendor/highlightjs/languages/markdown.cjs';
import javascript from './vendor/highlightjs/languages/javascript.cjs';

hljs.registerLanguage('crystal', engine => {
  const grammar = crystal(engine);
  // Blueprint's class: argument must not start a Crystal class declaration.
  grammar.contains.unshift(
    {scope:'attr', begin:/\b[a-z_]\w*[!?]?:(?!:)/},
    {scope:'type', begin:/\b[A-Z]\w*(?:::[A-Z]\w*)*/},
  );
  return grammar;
});
hljs.registerLanguage('bash', engine => {
  const grammar = bash(engine);
  // Application commands and executable paths are meaningful in these examples.
  grammar.contains.unshift({scope:'built_in', begin:/^[\t ]*(?:[\w.-]+\/)*[\w.-]+(?=[\t ]|$)/m});
  return grammar;
});
hljs.registerLanguage('yaml', yaml);
hljs.registerLanguage('markdown', markdown);
hljs.registerLanguage('javascript', javascript);

export const decodeCode = html => html.replace(/&(amp|lt|gt|quot|#39);/g,
  (_, entity) => ({amp:'&', lt:'<', gt:'>', quot:'"', '#39':"'"}[entity]));

export function highlightCode(html) {
  return html.replace(/<code class="language-([a-z]+)">([\s\S]*?)<\/code>/g, (_, language, code) => {
    if (!hljs.getLanguage(language)) throw new Error(`Unknown snippet language: ${language}`);
    const result = hljs.highlight(decodeCode(code), {language, ignoreIllegals:true});
    return `<code class="hljs language-${language}">${result.value}</code>`;
  });
}
