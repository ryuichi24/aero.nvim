import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import { Markdown } from './markdown';

const { renderDiagram, initialize } = vi.hoisted(() => ({
  renderDiagram: vi.fn(),
  initialize: vi.fn(),
}));
vi.mock('mermaid', () => ({ default: { initialize, render: renderDiagram } }));
afterEach(() => {
  cleanup();
  renderDiagram.mockReset();
});

it('renders Mermaid fences as diagrams while preserving ordinary highlighted code', async () => {
  renderDiagram.mockResolvedValue({ svg: '<svg><text>A to B</text></svg>' });
  const { container } = render(
    <Markdown text={'```mermaid\ngraph TD; A-->B\n```\n\n```js\nconst x = 1;\n```'} />,
  );
  const diagram = await screen.findByRole('img', { name: 'Mermaid diagram' });
  expect(diagram.querySelector('svg')?.textContent).toBe('A to B');
  expect(renderDiagram.mock.calls[0][1]).toBe('graph TD; A-->B\n');
  expect(initialize).toHaveBeenCalledWith({
    startOnLoad: false,
    theme: 'dark',
    securityLevel: 'strict',
  });
  expect(container.querySelector('pre code.language-js .hljs-keyword')).toBeTruthy();
});

it('opens individual diagrams fullscreen, supports zoom, and restores focus on Escape', async () => {
  renderDiagram.mockImplementation(async (_id, source) => ({
    svg: `<svg><text>${source}</text></svg>`,
  }));
  render(
    <Markdown text={'```mermaid\ngraph TD; A-->B\n```\n\n```mermaid\ngraph TD; C-->D\n```'} />,
  );
  await waitFor(() => expect(screen.getAllByRole('img')).toHaveLength(2));
  const trigger = screen.getAllByRole('button', { name: 'Fullscreen diagram' })[1];
  const dialog = screen.getAllByRole<HTMLDialogElement>('dialog', { hidden: true })[1];
  dialog.showModal = () => dialog.setAttribute('open', '');
  dialog.close = () => dialog.removeAttribute('open');
  fireEvent.click(trigger);
  expect(screen.getByRole('dialog', { name: 'Fullscreen Mermaid diagram' })).toBe(dialog);
  expect(within(dialog).getByRole('img').textContent).toContain('C-->D');
  expect(document.body.style.overflow).toBe('hidden');
  fireEvent.click(within(dialog).getByRole('button', { name: 'Zoom in' }));
  expect(within(dialog).getByLabelText('Diagram zoom').textContent).toBe('150%');
  fireEvent.click(within(dialog).getByRole('button', { name: 'Reset zoom' }));
  expect(within(dialog).getByLabelText('Diagram zoom').textContent).toBe('100%');
  fireEvent(dialog, new Event('cancel', { bubbles: true }));
  expect(dialog.hasAttribute('open')).toBe(false);
  expect(document.activeElement).toBe(trigger);
  expect(document.body.style.overflow).toBe('');
  expect(screen.getAllByRole('img')).toHaveLength(2);
  expect(renderDiagram).toHaveBeenCalledTimes(2);
  fireEvent.click(trigger);
  fireEvent.click(within(dialog).getByRole('button', { name: 'Exit fullscreen diagram' }));
  expect(dialog.hasAttribute('open')).toBe(false);
});

it('keeps invalid diagram source readable and removes temporary rendering DOM', async () => {
  renderDiagram.mockImplementation(async (_id, _source, container) => {
    container.innerHTML = '<div data-mermaid-error>Parse error</div>';
    throw new Error('Invalid diagram');
  });
  const { container } = render(<Markdown text={'```mermaid\ninvalid diagram\n```'} />);
  expect((await screen.findByRole('status')).textContent).toContain('Invalid diagram');
  expect(container.querySelector('pre code')?.textContent).toBe('invalid diagram\n');
  expect(document.querySelector('[data-mermaid-error]')).toBeNull();
});

it('ignores stale diagram results when the source changes', async () => {
  let resolveFirst!: (value: { svg: string }) => void;
  renderDiagram.mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        resolveFirst = resolve;
      }),
  );
  renderDiagram.mockResolvedValue({ svg: '<svg><text>New diagram</text></svg>' });
  const { rerender } = render(<Markdown text={'```mermaid\ngraph TD; A-->B\n```'} />);
  await waitFor(() => expect(renderDiagram).toHaveBeenCalledTimes(1));
  rerender(<Markdown text={'```mermaid\ngraph TD; C-->D\n```'} />);
  expect((await screen.findByRole('img')).textContent).toBe('New diagram');
  resolveFirst({ svg: '<svg><text>Old diagram</text></svg>' });
  await waitFor(() => expect(document.body.children.length).toBe(1));
  expect(screen.getByRole('img').textContent).toBe('New diagram');
});

it.each(['markdown', 'md'])(
  'automatically previews an isolated diagram wrapped in %s',
  async (language) => {
    renderDiagram.mockResolvedValue({ svg: '<svg><text>Wrapped diagram</text></svg>' });
    const source = '\n  ~~~~mermaid\n  graph TD; A-->B\n  ~~~~\n';
    const { container } = render(
      <Markdown text={`\`\`\`\`\`\`${language}\n${source}\n\`\`\`\`\`\``} />,
    );
    expect((await screen.findByRole('img')).textContent).toBe('Wrapped diagram');
    expect(renderDiagram.mock.calls[0][1]).toBe('graph TD; A-->B');
    expect(container.querySelector('pre')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'View source' }));
    expect(container.querySelector('pre code')?.textContent).toBe(`${source}\n`);
    expect(screen.queryByRole('img')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Preview diagram' }));
    expect(await screen.findByRole('img')).toBeTruthy();
  },
);

it('offers an opt-in preview for mixed Markdown without hiding its source', async () => {
  renderDiagram.mockResolvedValue({ svg: '<svg><text>Preview</text></svg>' });
  const source = '# Instructions\n\n```mermaid\ngraph TD; A-->B\n```\n\n```js\nconst x = 1;\n```';
  const { container } = render(<Markdown text={`\`\`\`\`markdown\n${source}\n\`\`\`\``} />);
  expect(renderDiagram).not.toHaveBeenCalled();
  expect(container.querySelector('pre code')?.textContent).toBe(`${source}\n`);
  fireEvent.click(screen.getByRole('button', { name: 'Preview diagram' }));
  expect(await screen.findByRole('img')).toBeTruthy();
  expect(container.querySelector('pre code')?.textContent).toBe(`${source}\n`);
  fireEvent.click(screen.getByRole('button', { name: 'Hide preview' }));
  expect(screen.queryByRole('img')).toBeNull();
});

it('previews multiple diagrams inside mixed Markdown on request', async () => {
  renderDiagram.mockResolvedValue({ svg: '<svg><text>Preview</text></svg>' });
  render(
    <Markdown
      text={
        '````md\n```mermaid\ngraph TD; A-->B\n```\n\n```mermaid\nsequenceDiagram\nA->>B: Hello\n```\n````'
      }
    />,
  );
  expect(renderDiagram).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Preview diagrams' }));
  await waitFor(() => expect(screen.getAllByRole('img')).toHaveLength(2));
  expect(renderDiagram.mock.calls.map((call) => call[1])).toEqual([
    'graph TD; A-->B',
    'sequenceDiagram\nA->>B: Hello',
  ]);
});

it('leaves ordinary Markdown examples and other code languages unchanged', () => {
  const { container } = render(
    <Markdown
      text={
        '````markdown\n# Example\n\n```js\nconst x = 1;\n```\n````\n\n````text\n```mermaid\ngraph TD; A-->B\n```\n````'
      }
    />,
  );
  expect(container.querySelectorAll('pre')).toHaveLength(2);
  expect(screen.queryByRole('button')).toBeNull();
  expect(renderDiagram).not.toHaveBeenCalled();
});

it('automatically recovers when a streamed Markdown example becomes an isolated diagram', async () => {
  renderDiagram.mockResolvedValue({ svg: '<svg><text>Recovered</text></svg>' });
  const { rerender } = render(<Markdown text={'````markdown\n```merm'} />);
  expect(renderDiagram).not.toHaveBeenCalled();
  rerender(<Markdown text={'````markdown\n```mermaid\ngraph TD; A-->B\n```\n````'} />);
  expect((await screen.findByRole('img')).textContent).toBe('Recovered');
});
