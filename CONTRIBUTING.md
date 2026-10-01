# Contributing

Keep changes small and attach sanitized evidence for the behavior being changed. A saved configuration, healthy container, successful login and validated token are different milestones.

For a new POC, document:

1. The identity population, application and protocol.
2. Existing prerequisites and any license or cost dependency.
3. Configuration using placeholders or fictional data.
4. A successful case and the relevant rejection cases.
5. Cleanup, recovery and the exact scope of the evidence.

Preserve the local issuer and client defaults unless a POC explicitly needs different settings. Avoid recreating existing containers or changing shared trust and policy settings as an incidental step.

Review [SECURITY.md](SECURITY.md) and the staged file list before pushing. The ignore file is a convenience; it is not a secret scanner. Add completed results to [the use-case list](docs/use-cases.md) only when supported by runtime evidence.
