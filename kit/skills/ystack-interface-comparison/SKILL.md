---
name: ystack-interface-comparison
description: "Compare interface layout and motion in realistic demos, then validate visual states, accessibility and browser limits."
---

# Interface Comparison

Inputs: the requested visual problem, current page, target devices and existing design constraints. Output: a visible comparison and evidence for the selected change. This workflow supplies no publishing or merge authority.

1. Match the actual layout and representative content before comparing options. Where appropriate, hide proposal sources during ranking. Compare short explanation placement and responsive behavior, not just screenshot appeal. A compact contents list can retain explanations on the name line on desktop and below it on phones. Keep display taglines separate from machine-readable descriptions/status when they serve different purposes.
2. Reduce competing emphasis before adding emphasis. Try space/background before borders, make between-group spacing exceed within-group spacing and remove redundant labels. Check whether an existing end mark already separates sections. Reassess spacing after nearby content changes. A site's text color need not preserve hierarchy on an OG card; compare each context before unifying tokens.
3. For motion, identify the state change each effect explains. Compare component examples, comparable working tools and target-browser support. Build a replica with simulated data and an independent toggle for each effect; trigger it, toggle one effect and repeat. Check reduced-motion behavior. Do not infer browser support or access restrictions from the demo's description.
4. Inspect animation during and after real interaction. Load-dependent rolling digits or traces may be absent even when completion tests pass. Use per-request data when a trace should show variation and stable numeric widths to align adjacent graphics. Check empty/loading/error/completed states, soft navigation and screen-reader announcements. Hidden completion text must remain accessible.
5. For snapping hover text, inspect nested spans separately from the anchor. One fix is `transition: inherit`; verify the current selectors and computed styles. A slowed comparison can expose the difference. For progress on a quiet text action, a background underline can fill without adding a separate control.
6. Recheck target-browser compatibility and real-device behavior. A Details effect can animate height in Chrome but only fade in Safari. Do not make a permanent compatibility claim without versions and tests. A cover fade can hide loading; a continuously animated clock can compete with reading. These are tradeoffs, not bans on later exploration.
7. Keep review screenshots out of main when useful through an authorized orphan artifact branch, one folder per PR, with commit-SHA blob links ending in `?raw=true`. Verify retrieval and access scope. This organization does not authorize publishing private images. Inspect diagnostic screenshots for personal values such as city and colo.

## Calibrate and check the selected layout

- Compare the actual current page and alternatives at desktop and phone widths, idle and with results. Match full-page appearance as well as height; equal height alone is insufficient. Use neutral labels and vary presentation order when collecting independent judgments. Preserve script/test IDs during implementation, update changed wording checks, then compare the real page with the chosen demo.
- Inspect reset CSS when mock colors differ; one fix is `:where()` to reduce reset specificity. After flex-to-grid changes, inspect inherited row gaps; a retained flex-rule gap can cause excess spacing. For a narrow column, inspect inherited alignment and explicit width; `justify-content: space-between` can be a cause.
- Give equivalent actions the same underline. Keep data-use notices adjacent to their action and available with the button to screen readers, along with the current step. Check touch areas after removing boxes, and use a real text-underline fallback in forced colors. A phone field fix is a case measurement, not a universal minimum. Test whether users recognize the action on a real phone.
- Inspect hover at normal speed after a slowed comparison, such as a 4× slow mode. Keep current behavior when the difference is imperceptible at normal speed. Check nested text, unlinked secondary text and reduced-motion computed duration on built pages. Motion should explain meaningful change; frequent actions may need less. This frequency advice is not a permanent design restriction.
- Artifact branches can be built with Git plumbing while the working tree stays on the PR branch. Check every image at the exact linked commit, then test retrieval and rendering separately. In zsh, delimit a variable before a literal colon with braces; `$c:r` is parsed as a filename modifier.

## Check the perceived effect

Compare an animation-free baseline with frames from first visits, soft navigation, persistent-profile disk-cache returns, scrolling and slow networks. Inspect the frames yourself and state precisely what was checked. Class changes and final opacity prove mechanics only. Hold navigation pending to expose delayed feedback; check narrow wrapping, reduced motion and cached covers. Keep first-screen entrance separate from scroll reveals. Rebuild comparison screenshots after each proposal change and exclude stale frames. Inventory every page that uses the same element before applying a shared design.

## Validate comparison controls and hit areas

- Run baseline against itself before trusting screenshot differences. Bound each capture with a timeout and visible progress. Diagnose on a small subset before a full comparison; avoid competing heavy test jobs. Preserve the baseline build and disclose routes, widths, themes, normalization and intended exceptions. Compare brand assets separately. Fewer test declarations do not prove lost or retained coverage.
- When consolidating page loads, preserve responsive coverage by scanning one width, resizing and scanning again. A phone-only scan cannot validate desktop font rules. Recheck the final tree after later edits.
- Test expanded links independently for idle appearance, destination, hit-area alignment, hover and accessibility. For final-color assertions, suppress transitions only in that assertion and inspect real hover separately. Tap just outside the visible icon and on adjacent unrelated content. A duplicate adjacent destination may use one announced keyboard link, but inspect exact accessibility semantics and loading-feedback selectors.
- Measure actual first-screen content, not only a shorter footer. Separate row-spacing changes from removal of a different content row. Recheck real-phone appearance after selecting the spacing.
