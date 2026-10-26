# WCAG Accessibility Guidelines

> **Business context:** Key customers (Amazon, UCSF) require WCAG compliance. All frontend changes MUST be accessibility-compliant going forward. The automated code reviewer will reject PRs that fail these checks.
>
> Reference: [W3C WAI Tips for Designing](https://www.w3.org/WAI/tips/designing/)

## Approach

- **Mobile-first development** — design for mobile (portrait + landscape), then adapt for web
- **AI-assisted compliance** — these rules must be applied automatically during code generation; do not rely on manual post-hoc fixes

---

## 1. Contrast

> WCAG 1.4.3 — Contrast (Minimum)

- Text must have sufficient contrast ratio against its background
- Applies to text on images, gradients, buttons, and other elements
- Use tools to verify: minimum 4.5:1 for normal text, 3:1 for large text
- Logos and incidental/decorative text are exempt
- UI components and graphical objects need 3:1 against adjacent colours (WCAG 1.4.11)

## 2. Color Is Not the Only Indicator

> WCAG 1.4.1 — Use of Color

- Never use color alone to convey information
- Combine color with: icons, text labels, patterns, underlines, asterisks
- Examples: required fields need asterisk + color, not color alone; graph segments need labels, not just different colors; error states need icons + text, not just red borders

## 3. Interactive Element Identification

> WCAG 2.4.7 — Focus Visible; WCAG 3.2.4 — Consistent Identification

- Links, buttons, and interactive elements must have distinct visual styles
- Required visual states: hover, keyboard focus (visible border/outline), active/pressed
- Keyboard navigation must reach ALL interactive elements
- Focus order follows the reading order (WCAG 2.4.3)
- A modal traps focus while open and Escape closes it; focus never escapes behind an overlay
- No keyboard trap: the user can always navigate away from any component (WCAG 2.1.2)
- No hover-only interaction — anything reachable by hover is reachable by focus or click
- **Never remove `outline` on `:focus` without providing an equivalent visible indicator**

```tsx
// BAD — removes focus indicator
button:focus { outline: none; }

// GOOD — custom but visible focus
button:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
}
```

## 4. Consistent Navigation

> WCAG 3.2.3 — Consistent Navigation; WCAG 2.4.5 — Multiple Ways

- Navigation must maintain consistent naming, styling, and positioning across pages
- Provide multiple navigation methods: site search, breadcrumbs, site map
- Clear orientation cues: breadcrumbs, current-page indicators, headings

## 5. Form Labels and Inputs

> WCAG 3.3.2 — Labels or Instructions; WCAG 2.4.6 — Headings and Labels

- **Every form field must have an associated `<label>` element** (use `htmlFor` in React)
- Labels positioned: above or left of text fields, right of checkboxes/radios
- Minimize spacing between labels and their fields
- A placeholder is never the only label: it disappears on focus and leaves the field unnamed
- Set `autocomplete` where a field has a known purpose, e.g. `autoComplete="email"` (WCAG 1.3.5)
- Group related fields with `<fieldset>` and `<legend>`

```tsx
// BAD — no label association
<input type="email" placeholder="Email" />

// GOOD — properly labeled
<label htmlFor="email">Email address</label>
<input id="email" type="email" aria-required="true" />
```

## 6. Feedback and Error Handling

> WCAG 3.3.1 — Error Identification; WCAG 3.3.3 — Error Suggestion

- Form errors must be clearly identified with text (not just color)
- Error messages should suggest how to fix the problem
- Use `aria-invalid`, `aria-describedby` to associate errors with fields
- Important feedback must be announced to screen readers (`aria-live` regions)

```tsx
// GOOD — accessible error feedback
<input
  id="email"
  type="email"
  aria-invalid={!!error}
  aria-describedby={error ? "email-error" : undefined}
/>
{error && (
  <span id="email-error" role="alert">{error}</span>
)}
```

## 7. Headings and Content Structure

> WCAG 2.4.6 — Headings and Labels; WCAG 2.4.10 — Section Headings

- Use semantic heading hierarchy (`h1` > `h2` > `h3`) — never skip levels
- One `<h1>` per page, and each heading describes the content that follows
- Text styled to look like a heading is a heading element, not a styled `<div>`
- Use headings to group related content and create scannable structure
- Separate large text blocks; use lists for clarity

## 8. Responsive / Viewport Design

> Mobile Accessibility Mapping

- **Mobile-first**: design for small screens first, then scale up
- Test both portrait and landscape orientations
- Ensure touch targets are at least 44x44 CSS pixels
- Text must be readable without horizontal scrolling at 320px width
- Text resizes to 200% with no loss of content or function (WCAG 1.4.4)
- Navigation adapts: full nav on desktop, hamburger/icons on mobile

## 9. Images and Media Alternatives

> WCAG 1.1.1 — Non-text Content

- **Every `<img>` must have an `alt` attribute** — descriptive for informational images, empty (`alt=""`) for decorative
- Icons used as buttons need `aria-label` or visible text
- `<svg>` carries `aria-hidden="true"` when decorative, or `role="img"` with `aria-label` when it carries meaning
- Provide text alternatives for charts, graphs, and complex visuals
- Audio/video: provide captions, transcripts, or audio descriptions

```tsx
// BAD — no alt text
<img src="/logo.png" />

// GOOD — informational image
<img src="/logo.png" alt="Acme company logo" />

// GOOD — decorative image
<img src="/divider.png" alt="" role="presentation" />

// GOOD — icon button
<button aria-label="Close dialog">
  <CloseIcon aria-hidden="true" />
</button>
```

## 10. Auto-Playing Content Controls

> WCAG 1.4.2 — Audio Control; WCAG 2.2.2 — Pause, Stop, Hide

- Include visible controls to stop/pause: animations, carousels, auto-playing video/audio
- Content that auto-updates must have a pause mechanism
- Moving/blinking content that starts automatically must be stoppable
- Nothing flashes more than three times per second (WCAG 2.3.1)

---

## Semantic HTML Checklist

Always use the correct semantic element:

| Instead of | Use |
|---|---|
| `<div onClick>` | `<button>` |
| `<div>` for navigation | `<nav>` |
| `<div>` for main content | `<main>` |
| `<div>` for sections | `<section>` with heading |
| `<div>` for footer | `<footer>` |
| `<span>` for links | `<a href>` |
| `<div>` grid for tabular data | `<table>` with `<th>` headers |
| Custom dropdowns without ARIA | Native `<select>` or proper ARIA roles |

## ARIA Essentials

- Use ARIA only when semantic HTML is insufficient
- `aria-label` — labels an element when no visible text exists
- `aria-describedby` — links an element to its description (e.g., error message)
- `aria-hidden="true"` — hides decorative elements from screen readers
- `aria-live="polite"` — announces dynamic content changes
- `aria-required="true"` — marks required form fields
- `aria-expanded` — states whether a collapsible, accordion or dropdown is open
- `role="alert"` — immediately announces important messages
- A non-interactive element carrying a click handler needs both `role` and `tabIndex`, and is usually the wrong element

## PR Review Accessibility Checklist

When reviewing frontend PRs, verify:

- [ ] All images have appropriate `alt` text
- [ ] All form inputs have associated `<label>` elements
- [ ] Interactive elements are keyboard-accessible
- [ ] Focus indicators are visible
- [ ] Color is not the sole information carrier
- [ ] Heading hierarchy is correct (no skipped levels)
- [ ] Touch targets are >= 44x44px
- [ ] Error messages are text-based (not color-only)
- [ ] Semantic HTML used over generic `<div>`/`<span>`
- [ ] ARIA attributes used correctly where needed
- [ ] Responsive design tested (mobile portrait + landscape)

Where `package.json` configures `eslint-plugin-jsx-a11y` or `axe-core`, run it: it is
evidence a review by eye is not, and it must report zero accessibility warnings.

---

## Sources

- [WCAG 2.1 — Web Content Accessibility Guidelines](https://www.w3.org/TR/WCAG21/)
- [W3C WAI — Tips for Designing](https://www.w3.org/WAI/tips/designing/)
- [W3C WAI — Tips for Developing](https://www.w3.org/WAI/tips/developing/)
- [MDN — ARIA](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA)
