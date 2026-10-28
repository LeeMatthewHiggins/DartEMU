---
version: alpha
name: DartEMU tutorial design
description: Digital Workforce visual rules adapted for the browser tutorial.
colors:
  background: "#F7F8F8"
  foreground: "#1A1A1A"
  card: "#FFFFFF"
  primary: "#00DBA8"
  primaryForeground: "#002B22"
  secondary: "#E0FAF5"
  secondaryForeground: "#006B53"
  muted: "#F0F2F1"
  mutedForeground: "#6B7280"
  border: "#E2E5E4"
  input: "#EAEDEC"
  ring: "#00DBA8"
  destructive: "#C62828"
  statusWorking: "#B86E00"
  darkBackground: "#0F1210"
  darkForeground: "#E8EDEB"
  darkCard: "#181D1B"
  darkMuted: "#131815"
  darkMutedForeground: "#8A9490"
  darkBorder: "#242E2B"
  darkStatusWorking: "#FFB74D"
  darkDestructive: "#EF5350"
typography:
  fontFamily: Geist Sans, Geist, ui-sans-serif, system-ui, sans-serif
  monoFamily: Geist Mono, SFMono-Regular, Consolas, monospace
  letterSpacing: 0
  display: { fontSize: 32px, lineHeight: 40px, fontWeight: 600 }
  heading: { fontSize: 20px, lineHeight: 28px, fontWeight: 600 }
  body: { fontSize: 14px, lineHeight: 22px, fontWeight: 400 }
  label: { fontSize: 12px, lineHeight: 16px, fontWeight: 500 }
rounded:
  small: 4px
  control: 6px
  card: 8px
spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 20px
  xl: 24px
components:
  buttonPrimary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.primaryForeground}"
    height: 36px
    paddingInline: 16px
    rounded: "{rounded.control}"
  compactControl:
    height: 32px
  card:
    backgroundColor: "{colors.card}"
    padding: 20px
    rounded: "{rounded.card}"
---

<!-- cspell:words Consolas -->

## Purpose

Use Digital Workforce's compact layout, neutral colors, and mint actions.
The terminal is the main content. Keep the tutorial visible beside it on
wide screens and above it on small screens.

## Implementation

Change reusable values in [tokens.css](example/web/tutorial/tokens.css)
first. Compose them in [style.css](example/web/tutorial/style.css) and keep
this file in sync. This static page uses plain HTML and CSS; it does not
need the Digital Workforce application packages.

Use borders to separate panels. Reserve mint for actions, selection and
focus, amber for pending work, and red for errors or destructive actions.
Keep the terminal dark. Use the system font when Geist is unavailable.

## Content

Each lesson has a title, one instruction, a command, and an expected result.
Increase complexity across lessons. Make each example runnable on its own.
State session limits once. Show status beside the terminal and errors beside
the action that failed. Use plain words and remove repeated explanations.

## Review

Build and preview the page using the [example instructions](example/README.md).
Check narrow and wide screens, keyboard navigation, boot, command output,
copy, and restart. Keep focus visible, respect reduced motion, and prevent
horizontal page scrolling. Update the README screenshot when the page changes.
