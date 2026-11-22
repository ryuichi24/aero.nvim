# Companion UI components

The companion uses local shadcn/ui components styled with Tailwind CSS v4.
Import controls from this directory (or `@/components/ui/…`). `components.json`
configures the shadcn CLI for this Vite application.

- `Button` provides primary, secondary, outline, ghost, link, and destructive variants.
  Its default type is `button`; form submit actions explicitly use `type="submit"`.
- `Input`, `Textarea`, `NativeSelect`, `Checkbox`, and `Label` are the shared form
  controls. `NativeSelect` retains native option selection and form submission.
- `Dialog` and `ConfirmDialog` use Radix for modal focus management and dismissal.
  `Dialog` keeps a native dialog host for the persistent transcript/composer DOM
  portals. Fullscreen views supply their own initial/return focus targets.
- `Collapsible` uses Radix trigger/content state with native details/summary hosts
  to preserve existing ref-based closing and browser disclosure behavior.
- `Card`, `Badge`, `StatusBadge`, `Progress`, and the table components provide
  shared surfaces and data presentation.

Use `cn()` from `@/lib/utils` to merge Tailwind classes. Semantic color tokens in
`style.css` follow the existing light/dark theme preference. View styling uses
Tailwind utilities; `style.css` retains Tailwind `@apply` rules for rich-text
content, responsive layouts, and the keyboard-aware transcript dock.

ESLint prevents native controls in application views. Native elements belong in
these shared primitives, while tests may use them as fixtures.
