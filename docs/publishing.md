# Publishing an update

The plugin is listed on the [Omarchy plugin marketplace][site]
(`omacom/omarchy-plugin-marketplace`, original submission [#2665][initial]).
The listing is pinned to one verified commit, so a push to `main` does not
update it.

## What a push does on its own

- **Installed copies update anyway.** `omarchy plugin update` fast-forwards
  to the repository's current default branch and runs
  `omarchy plugin validate`. It ignores the marketplace snapshot and the
  manifest `version`.
- **The listing goes stale.** The marketplace notices the newer upstream
  commit and marks the detail page "Update unverified" (the card shows
  "Unverified") until that commit is promoted.

## Procedure

1. Run `./check` and `omarchy plugin validate .`.
2. Bump `version` in `manifest.json` for user-visible changes. Nothing
   enforces it, but the listing displays it. Commit as
   `chore: bump version to X.Y.Z`.
3. Push `main`. Include any pending docs or chore commits first: whatever
   lands after the target commit shows as "Update unverified" again.
4. File the verification request against the pushed HEAD:

```bash
sha=$(git rev-parse HEAD)
gh issue create -R omacom/omarchy-plugin-marketplace \
  --title "[Verify]: Newgrounds Radio — newer upstream commit" \
  --body "$(cat <<EOF
### Verification action

Verify and publish a newer upstream commit

### Plugin ID

brenc.newgrounds-radio

### Repository URL

https://github.com/brenc/omarchy-newgrounds-radio

### Target commit

$sha

### Verification acknowledgment

- [X] I understand that only the exact target commit can become a verified marketplace snapshot and that verification is not a security audit.

### Standard installation acknowledgment

- [ ] I confirm that this listed root plugin supports the standard Omarchy installation path and does not require manual setup.
EOF
)"
```

The body mirrors the [verify-plugin issue form][form] field for field;
the workflow parses those headings, so keep them verbatim. Filling in the
web form instead works the same.

Then wait. Opening the issue runs a compatibility check and the Automated
Security Baseline against the exact SHA (community code is never
executed). A maintainer then applies `approved-and-verified`, and the
listing switches atomically. The old snapshot stays live until then.

If the scan reports findings, fix them, push, and edit the issue's target
commit to the new HEAD; editing the issue reruns the checks.

## History

| Version | Commit    | Request |
| ------- | --------- | ------- |
| 1.0.0   | —         | [#2665][initial] (initial listing) |
| 1.1.0   | `6a8a8ca` | [#9212][v1.1.0] — superseded by 1.2.0 before approval |
| 1.2.0   | `b8060e4` | [#9212][v1.1.0] (retargeted; bumped at `f6d1ded`, then review fixes) |

Full policy: [VERIFICATION.md][policy] in the marketplace repository.

[site]: https://plugins.omarchy.org
[form]: https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml
[policy]: https://github.com/omacom/omarchy-plugin-marketplace/blob/main/VERIFICATION.md
[initial]: https://github.com/omacom/omarchy-plugin-marketplace/issues/2665
[v1.1.0]: https://github.com/omacom/omarchy-plugin-marketplace/issues/9212
