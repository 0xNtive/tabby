# Security

tabby runs entirely on your machine: it has no servers and sends nothing anywhere, except the AI tab-naming request that goes to Anthropic through your own Claude Code login (see [TERMS.md](TERMS.md)).

## Reporting a vulnerability

Please report it privately through [GitHub's security advisories](https://github.com/0xNtive/tabby/security/advisories/new), not in a public issue. Include what an attacker could do and the steps to reproduce. You'll get an answer within a few days, and credit in the release notes if you'd like it.

## What's in scope

- The hooks, the CLI and the installer (`install.sh`): anything that runs code or changes files it shouldn't, or trusts input it shouldn't (session files, transcripts, terminal titles).
- Tabby Island: the macOS permissions it asks for (Accessibility, Automation) and what it does with them.
- The release download: the island ships as a zip with a SHA-256 checksum next to it, and the installer rejects a download that doesn't match.
