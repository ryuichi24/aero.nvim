import { fireEvent, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { expect, it, vi } from 'vitest';
import { App } from './app';
import { connect, draft, open, response } from './test/companion-harness';

it('keeps slash commands and the same draft editor available in fullscreen and on exit', async () => {
  const fetch = vi.fn().mockResolvedValue(response({ items: [], errors: [] }));
  vi.stubGlobal('fetch', fetch);
  render(<App />);
  connect();
  await open();
  draft('/');
  const dialog = document.querySelector<HTMLDialogElement>('.prompt-fullscreen')!;
  dialog.showModal = () => dialog.setAttribute('open', '');
  dialog.close = () => dialog.removeAttribute('open');
  const input = screen.getByRole('textbox', { name: 'Follow-up prompt' });
  await userEvent.click(screen.getByRole('button', { name: 'Fullscreen prompt' }));
  const modal = screen.getByRole('dialog', { name: 'Fullscreen prompt editor' });
  expect(within(modal).getByRole('textbox', { name: 'Follow-up prompt' })).toBe(input);
  await userEvent.click(
    within(modal).getByRole('button', {
      name: '/prompt — Insert a custom prompt snippet into the draft',
    }),
  );
  expect((input as HTMLTextAreaElement).value).toBe('/prompt');
  await userEvent.click(within(modal).getByRole('button', { name: 'Exit fullscreen prompt' }));
  expect(screen.getByRole('textbox', { name: 'Follow-up prompt' })).toBe(input);
  expect(document.activeElement).toBe(input);
  await userEvent.click(screen.getByRole('button', { name: 'Fullscreen prompt' }));
  fireEvent(
    screen.getByRole('dialog', { name: 'Fullscreen prompt editor' }),
    new Event('cancel', { cancelable: true }),
  );
  expect(screen.queryByRole('dialog', { name: 'Fullscreen prompt editor' })).toBeNull();
  expect((input as HTMLTextAreaElement).value).toBe('/prompt');
});
