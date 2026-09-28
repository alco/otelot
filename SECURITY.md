# Security policy

Only the latest released version of Otelot receives security fixes.

Please **don't** report security issues in public GitHub issues. Instead, use
[GitHub's private vulnerability reporting](https://github.com/alco/otelot/security/advisories/new)
for this repository.

Examples of what counts as a security issue: leaking OTLP credentials (e.g. `otlp_headers`)
into logs or exported telemetry, or input from instrumented code that can crash the host
application or exhaust its memory in ways the documentation doesn't warn about.

I'll acknowledge the report as soon as I can and keep you posted on the fix.
