---
name: ystack-pages-domain-review
description: "Audit a small Cloudflare Pages domain and guide account-holder changes to HTTPS, mail DNS, DNSSEC and redirects, checking each result live."
---

# Pages Domain Review

Use for an authorized domain review. The agent audits with read-only access; the account holder makes dashboard changes. Recheck each change live. Do not add services, delete sites or alter mail records without the relevant authorization.

1. Inventory every DNS record and Pages project. Verify the registrar through the API rather than assuming it. Keep working MX, DKIM, SPF, DMARC, live-site records and active Search Console verification. If retirement is authorized, account for both the Pages project and its DNS record.
2. Check HTTPS before HSTS. In SSL/TLS → Edge Certificates, a demonstrated baseline was HSTS max-age 15552000 seconds, subdomains and preload off, and No-Sniff on. Preserve Full (strict) when already set; the Automatic SSL/TLS suggestion alone does not require a change. Check live Strict-Transport-Security and X-Content-Type-Options headers. HSTS persists in clients; do not extend it to subdomains or preload before confirming HTTPS everywhere and understanding rollback.
3. Minimum TLS is under Edge Certificates, but cannot be configured for Pages hostnames. Do not claim that changing the zone setting hardens those hostnames.
4. Before changing SPF from ~all to -all, inventory every legitimate sender and check forwarding paths. Verify public DNS after an authorized edit. SPF fail means the sending host is unauthorized for the checked identity; receivers choose disposition. It does not guarantee rejection, protect every visible From address, or guarantee delivery for listed senders.
5. Enable DNSSEC through DNS settings only within scope. Cloudflare Registrar publishes DS automatically; other registrars generally require a DS step, with documented .ch/.cz exceptions. Verify active status and matching registry DS/key tag; do not mistake pending for active. Do not introduce multi-signer, multi-provider DNS or Email Security solely for a simple single-provider setup.
6. For an approved Page Rule migration, create and verify a Single Redirect before retiring the old rule. The WWW-to-root example uses request `https://www.*`, target `https://${1}`, status 301 and Preserve query string enabled. Do not trust the template default. Test a path plus query, then remove the superseded Page Rule and retest. This pattern covers HTTPS only. Test HTTP separately; an existing Always Use HTTPS setting may already cover it, while HSTS alone does not protect an uncached first visit.
7. Keep a proxied WWW DNS record so edge redirects can run. Cloudflare's Pages example uses A record 192.0.2.1 as a placeholder. Do not remove it as an unused origin.
8. For custom iCloud mail verification, keep existing apple-domain TXT records if the expected value cannot be confirmed. Do not infer that an absent dashboard button makes a record obsolete.

For a crawler-policy review, compare effective live robots.txt with intended policy and account configuration. Repo content alone does not show managed rules are active. Under the documented Security Settings → Bot traffic → Configure AI bot policies path, Training Disallow with Bot Preference Sync publishes directives and enables training-crawler edge blocking; mixed-use crawlers are excluded from that edge block. Keep Search and Agent allowed when that is the authorized goal. Let the account holder make changes unless account mutation is explicitly authorized. Inspect actual crawler lists and responses: robots directives and per-crawler enforcement are different evidence, and HTTP 200 alone does not disprove a policy. Recheck current vendor definitions for training, search and user-triggered retrieval; Google-Extended can also affect grounding. A setting label does not prove every search crawler is allowed.

Output a concise before/after check list with live headers, redirect destinations and DNS results. Stop dependent changes when a check fails or the intended mail/domain scope is unclear.

## Primary checks

If owner automation fails, inspect Bot Fight Mode as a possible cause; do not disable it automatically.

Primary documentation to recheck:
- [Minimum TLS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/minimum-tls/): Pages limitation.
- [Single Redirect](https://developers.cloudflare.com/rules/url-forwarding/examples/redirect-www-to-root/): HTTPS-only pattern and query preservation.
- [Pages WWW redirect](https://developers.cloudflare.com/pages/how-to/www-redirect/): proxied placeholder record; that guide demonstrates Bulk Redirects, a separate mechanism.
- [DNSSEC](https://developers.cloudflare.com/dns/dnssec/): registrar and TLD exceptions. Publication may be delayed; verify rather than assuming immediate activation.
- [HSTS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/http-strict-transport-security/): HTTPS dependency and persistent-client risks. Six months is an example baseline, not a universal requirement.
- [RFC 7208 §8.4](https://www.rfc-editor.org/rfc/rfc7208#section-8.4): receiver policy controls the response to SPF fail.
- [Managed robots.txt](https://developers.cloudflare.com/bots/additional-configurations/managed-robots-txt/): confirms the dashboard path, Sync and the mixed-use edge-block exception. The setting does more than publish directives.
- [Cloudflare content-use policy](https://blog.cloudflare.com/control-content-use-for-ai-training/): additional recheck reference.

Excluding Baiduspider or PetalBot has search-discovery tradeoffs. If the managed block disappears, inspect Sync and live configuration without assuming the cause or changing settings automatically.
