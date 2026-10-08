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
