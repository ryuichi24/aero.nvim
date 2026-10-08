import type { Node } from 'web-tree-sitter';

export function collectFoldRanges(root: Node): FoldRange[] {
  const ranges = new Map<number, FoldRange>();
  const pending = [root];
  while (pending.length) {
    const node = pending.pop()!;
    pending.push(...node.namedChildren.filter((child): child is Node => child !== null));
    const start = node.startPosition.row;
    const end = node.endPosition.row - (node.endPosition.column === 0 ? 1 : 0);
    if (
      end > start &&
      /(?:block|body|comment|object|array|class_definition|function_definition|table_constructor|element|mapping|sequence|declaration_list|field_declaration_list|use_list|enum_variant_list|arguments)$/.test(
        node.type,
      )
    ) {
      const previous = ranges.get(start);
      if (!previous || end > previous.end) ranges.set(start, { start, end });
    }
  }
  return [...ranges.values()].sort((a, b) => a.start - b.start);
}

export interface FoldRange {
  start: number;
  end: number;
}

export function visibleSourceLines(count: number, ranges: FoldRange[], collapsed: Set<number>) {
  const folds = new Map(ranges.map((range) => [range.start, range]));
  const lines: { line: number; fold?: FoldRange; hidden: number }[] = [];
  for (let line = 0; line < count; line++) {
    const fold = folds.get(line);
    const hidden = fold && collapsed.has(line) ? fold.end - line : 0;
    lines.push({ line, fold, hidden });
    line += hidden;
  }
  return lines;
}

// Highlight.js may keep a span open across newlines. Close and reopen those
// spans so each independently rendered line retains its original highlighting.
export function splitHighlightedLines(html: string): string[] {
  const stack: string[] = [];
  const lines = [''];
  for (const token of html.split(/(<span\b[^>]*>|<\/span>|\n)/g)) {
    if (token === '\n') {
      lines[lines.length - 1] += '</span>'.repeat(stack.length);
      lines.push(stack.join(''));
    } else {
      lines[lines.length - 1] += token;
      if (token.startsWith('<span')) stack.push(token);
      else if (token === '</span>') stack.pop();
    }
  }
  return lines;
}
