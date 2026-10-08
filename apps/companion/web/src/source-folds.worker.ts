import { Language, Parser } from 'web-tree-sitter';
import runtimeUrl from 'web-tree-sitter/tree-sitter.wasm?url';
import { collectFoldRanges, type FoldRange } from './source-folds';

const grammars = import.meta.glob<string>(
  '../node_modules/tree-sitter-wasms/out/tree-sitter-{typescript,tsx,javascript,python,go,rust,lua,c,cpp,java,c_sharp,ruby,bash,json,css,html,toml,swift,kotlin,php,zig}.wasm',
  {
    query: '?url',
    import: 'default',
  },
);
const extensions: Record<string, string> = {
  ts: 'typescript',
  tsx: 'tsx',
  js: 'javascript',
  jsx: 'javascript',
  mjs: 'javascript',
  cjs: 'javascript',
  py: 'python',
  go: 'go',
  rs: 'rust',
  lua: 'lua',
  c: 'c',
  h: 'c',
  cpp: 'cpp',
  hpp: 'cpp',
  cc: 'cpp',
  java: 'java',
  cs: 'c_sharp',
  rb: 'ruby',
  sh: 'bash',
  bash: 'bash',
  json: 'json',
  css: 'css',
  html: 'html',
  toml: 'toml',
  swift: 'swift',
  kt: 'kotlin',
  php: 'php',
  zig: 'zig',
};
const initialized = Parser.init({ locateFile: () => runtimeUrl });
const languages = new Map<string, Promise<Language>>();

async function parse(content: string, extension: string): Promise<FoldRange[]> {
  const grammar = extensions[extension];
  const load = grammars[`../node_modules/tree-sitter-wasms/out/tree-sitter-${grammar}.wasm`];
  if (!load) return [];
  await initialized;
  let language = languages.get(grammar);
  if (!language) {
    language = load().then((url) => Language.load(url));
    languages.set(grammar, language);
    void language.catch(() => languages.delete(grammar));
  }
  const parser = new Parser();
  let tree;
  try {
    parser.setLanguage(await language);
    tree = parser.parse(content);
    if (!tree) return [];
    return collectFoldRanges(tree.rootNode);
  } finally {
    tree?.delete();
    parser.delete();
  }
}

self.onmessage = async (
  event: MessageEvent<{ id: number; content: string; extension: string }>,
) => {
  const { id, content, extension } = event.data;
  try {
    self.postMessage({ id, ranges: await parse(content, extension) });
  } catch {
    self.postMessage({ id, ranges: [], error: true });
  }
};
