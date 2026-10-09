// @vitest-environment node
import { expect, it } from 'vitest';
import { Language, Parser } from 'web-tree-sitter';
import { collectFoldRanges, splitHighlightedLines, visibleSourceLines } from './source-folds';

it.each([
  ['typescript', 'function example() {\n  if (true) {\n    return 42;\n  }\n}\nexample();'],
  ['tsx', 'function Example() {\n  if (true) {\n    return <div />;\n  }\n}\nExample();'],
  ['go', 'func example() {\n  if true {\n    println(42)\n  }\n}\n'],
])(
  'parses real %s WASM and preserves nested folds when expanding a parent',
  async (grammar, content) => {
    await Parser.init();
    const language = await Language.load(
      `node_modules/tree-sitter-wasms/out/tree-sitter-${grammar}.wasm`,
    );
    const parser = new Parser();
    parser.setLanguage(language);
    const tree = parser.parse(content)!;
    try {
      const ranges = collectFoldRanges(tree.rootNode);
      expect(ranges).toEqual([
        { start: 0, end: 4 },
        { start: 1, end: 3 },
      ]);
      expect(visibleSourceLines(6, ranges, new Set([0, 1])).map((row) => row.line)).toEqual([0, 5]);
      expect(visibleSourceLines(6, ranges, new Set([1])).map((row) => row.line)).toEqual([
        0, 1, 4, 5,
      ]);
    } finally {
      tree.delete();
      parser.delete();
    }
  },
);

it.each([
  {
    name: 'props types',
    content: 'type Props = {\n  title: string;\n  children?: React.ReactNode;\n};',
    ranges: [{ start: 0, end: 3 }],
  },
  {
    name: 'expression-bodied arrow components',
    content: 'export const App = () => (\n  <div>hello</div>\n);',
    ranges: [{ start: 0, end: 2 }],
  },
  {
    name: 'nested JSX and expressions',
    content: [
      'export const App = () => (',
      '  <>',
      '    <section>',
      '      {',
      '        ready ? <A /> : <B />',
      '      }',
      '    </section>',
      '  </>',
      ');',
    ].join('\n'),
    ranges: [
      { start: 0, end: 8 },
      { start: 1, end: 7 },
      { start: 2, end: 6 },
      { start: 3, end: 5 },
    ],
  },
])('folds TSX $name', async ({ content, ranges }) => {
  await Parser.init();
  const language = await Language.load('node_modules/tree-sitter-wasms/out/tree-sitter-tsx.wasm');
  const parser = new Parser();
  parser.setLanguage(language);
  const tree = parser.parse(content)!;
  try {
    expect(tree.rootNode.hasError).toBe(false);
    expect(collectFoldRanges(tree.rootNode)).toEqual(ranges);
    const count = content.split('\n').length;
    expect(visibleSourceLines(count, ranges, new Set([0])).map((row) => row.line)).toEqual([0]);
    expect(visibleSourceLines(count, ranges, new Set())).toHaveLength(count);
  } finally {
    tree.delete();
    parser.delete();
  }
});

it('keeps multiline highlighted spans balanced and preserves escaped source', () => {
  expect(
    splitHighlightedLines('<span class="hljs-comment">/* &lt;x&gt;\ntext\n*/</span>\n'),
  ).toEqual([
    '<span class="hljs-comment">/* &lt;x&gt;</span>',
    '<span class="hljs-comment">text</span>',
    '<span class="hljs-comment">*/</span>',
    '',
  ]);
});
