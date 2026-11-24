# ystack — landing page

A static, self-contained landing page for ystack, served at
**ystack.yihanzhu.com**. It describes the kit and the layer pass. Its copy says
only what [`NORTH_STAR.md`](../NORTH_STAR.md) and [`ROADMAP.md`](../ROADMAP.md) say.

## Files

| File | Purpose |
|------|---------|
| `index.html` | The page (single-page; entry point). |
| `styles.css` | All styling — warm-ember theme. |
| `favicon.svg` | Brand mark (anvil) used as the tab icon. |
| `og.png` | 1200×630 social preview card. Wired as `og:image`/`twitter:image`. |
| `robots.txt` | Allows crawlers; points at the sitemap. |
| `sitemap.xml` | Single-URL sitemap. |

No build step, no dependencies, no JS framework. The only external request is the
Google Fonts stylesheet (Fraunces + Inter), and the page degrades to system fonts if
it fails to load.

## Deploy (Cloudflare Pages)

This folder is the publish root.

- **Build command:** *(none)*
- **Build output directory:** `website`
- **Framework preset:** None / Static HTML

Point the custom domain `ystack.yihanzhu.com` at the Pages project. That's it — the
files are served as-is.

To preview locally:

```sh
cd website && python3 -m http.server 8000   # then open http://localhost:8000
```

## Social preview image

`og.png` is wired via `og:image`/`og:image:width`/`og:image:height` and
`twitter:image`, with `twitter:card` set to `summary_large_image`. Its tagline matches
the page title. To regenerate it, rasterize a self-contained card at 1200×630 (for
example with headless Chrome `--screenshot`) and overwrite `og.png`. Keep the served
asset a static raster.
