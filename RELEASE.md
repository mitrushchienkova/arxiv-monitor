# Release Notes

## 2026-04-21

### Fixed
- Multi-word keyword searches now match arXiv's website search behavior. Previously, a keyword value containing whitespace (e.g. `osculating elements`) was sent to the arXiv API as an exact quoted phrase — which missed papers where the words appear non-adjacently (e.g. "osculating **orbital** elements", as in paper 2510.25161). Multi-word keywords are now split on whitespace and ANDed within the chosen scope. Hyphenated single tokens like `Gromov-Witten` continue to be quoted (required to defeat Lucene's NOT operator). Users who want the old phrase-match behavior can wrap a value in literal double-quotes, e.g. `"mirror symmetry"`.
- HTTP 429 (rate-limit) responses from the arXiv API are now retried with backoff + jitter instead of surfacing as generic failures. A `Retry-After` header is honored when present (clamped to 15–120s and reflected in the UI so the cooldown shown always matches the cooldown the client is actually observing); otherwise a 30s base wait + up to 5s of jitter is used. While a search is in 429 cooldown, the popover status line shows "arXiv rate-limited, retry at 16:10" (absolute time, shown only when all rate-limited searches share that time — otherwise a generic "waiting…") instead of the red "failed · Retry" prompt. The waiting state persists across app relaunches so restored 429s stay classified correctly. Once the cooldown elapses, the search falls back to the normal failed + Retry UI so the user can manually try again — previously, a 429 without `Retry-After` could leave a search stuck in "waiting…" indefinitely. The popover's Retry button now scopes its fetch to the non-rate-limited failed searches so pressing Retry in a mixed state can't inadvertently extend the cooldown on searches still in 429.
- Deleting or materially editing a saved search now scrubs its stale failure / rate-limit metadata, so a removed search can no longer skew the popover's "retry at …" time for unrelated searches.

### Added
- Per-category refresh in the main window. Clicking the refresh button while a specific saved search is selected now fetches only that search. When "All Papers" is selected, all searches are fetched (unchanged). Right-click the refresh button for a "Refresh All" option at any time; ⇧⌘R triggers a full refresh regardless of selection. The menu-bar popover refresh continues to fetch all.
- `LICENSE` (GNU GPL v3).
- `RELEASE.md` to track the history of changes going forward.
- `docs/screenshots/` directory with a checklist of screenshots to add; the README's new Screenshots section will render them automatically once dropped in.

### Changed
- README refresh: softened intro paragraph, added badges (macOS 13+, Swift, GPL-3.0), added a Quick start section, and clarified keyword-search semantics (comma → OR, whitespace → AND, literal quotes → phrase).
