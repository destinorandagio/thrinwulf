# SOCIAL81+ Link Engine

Portable, dependency-free tracking module for SOCIAL81+.

## Goal

For every social creative it creates:

`post -> unique UTM URL -> is.gd short URL -> free-course landing`

Default destination:

`https://corsi.elearningsicurezza.com/pid/2377/`

## Output

`social81/output/latest-link.json` contains:

- final destination
- tracked URL with `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`
- real is.gd short URL
- analytics URL
- creation timestamp

## Run

```bash
python social81/shortlink.py --source instagram --campaign free_courses --content reel_001
```

No Python packages and no API secret are required.

## GitHub Actions

`.github/workflows/social81-shortlink.yml` supports manual execution and scheduled generation for the two SOCIAL81+ publishing slots. GitHub cron is UTC, so daylight-saving changes must be reviewed when Europe/Rome switches between CEST and CET.

## Portability

The `social81/` directory and workflow are deliberately isolated from the host repository. They can later be copied to the canonical 81+ repository without coupling to Thrinwulf.

## Privacy note

UTM values identify campaigns/creatives, not individual users. Do not put personal data, emails, phone numbers or sensitive identifiers into UTM parameters.
