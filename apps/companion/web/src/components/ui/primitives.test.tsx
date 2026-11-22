import { useRef, useState } from 'react';
import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, expect, it, vi } from 'vitest';
import { Button } from './button';
import { Checkbox } from './checkbox';
import { Dialog } from './dialog';
import { Label } from './label';
import { NativeSelect } from './native-select';

afterEach(cleanup);

it('traps keyboard focus in dialogs, dismisses with Escape and restores the opener', async () => {
  function Example() {
    const [open, setOpen] = useState(false);
    const trigger = useRef<HTMLButtonElement>(null);
    return (
      <>
        <Button ref={trigger} onClick={() => setOpen(true)}>
          Open preferences
        </Button>
        <Dialog
          open={open}
          onOpenChange={setOpen}
          aria-label="Preferences"
          onRestoreFocus={() => trigger.current?.focus()}
        >
          <Button>First action</Button>
          <Button onClick={() => setOpen(false)}>Close preferences</Button>
        </Dialog>
      </>
    );
  }
  const user = userEvent.setup();
  render(<Example />);
  const trigger = screen.getByRole('button', { name: 'Open preferences' });
  await user.click(trigger);
  const modal = screen.getByRole('dialog', { name: 'Preferences' });
  expect(document.activeElement).toBe(within(modal).getByRole('button', { name: 'First action' }));
  await user.tab({ shift: true });
  expect(document.activeElement).toBe(
    within(modal).getByRole('button', { name: 'Close preferences' }),
  );
  await user.tab();
  expect(document.activeElement).toBe(within(modal).getByRole('button', { name: 'First action' }));
  await user.keyboard('{Escape}');
  expect(screen.queryByRole('dialog', { name: 'Preferences' })).toBeNull();
  expect(document.activeElement).toBe(trigger);
});

it('keeps checkbox and native-select values in submitted forms without submitting secondary actions', async () => {
  const submit = vi.fn();
  const user = userEvent.setup();
  render(
    <form
      onSubmit={(event) => {
        event.preventDefault();
        submit(Object.fromEntries(new FormData(event.currentTarget)));
      }}
    >
      <Label>
        Agent
        <NativeSelect name="agent" defaultValue="opencode">
          <option value="opencode">OpenCode</option>
          <option value="codex">Codex</option>
        </NativeSelect>
      </Label>
      <Label>
        <Checkbox name="force" value="yes" />
        Force removal
      </Label>
      <Button variant="outline">Preview</Button>
      <Button type="submit">Save</Button>
    </form>,
  );
  await user.click(screen.getByRole('button', { name: 'Preview' }));
  expect(submit).not.toHaveBeenCalled();
  await user.selectOptions(screen.getByRole('combobox', { name: 'Agent' }), 'codex');
  await user.click(screen.getByRole('checkbox', { name: 'Force removal' }));
  await user.click(screen.getByRole('button', { name: 'Save' }));
  expect(submit).toHaveBeenCalledWith({ agent: 'codex', force: 'yes' });
});
