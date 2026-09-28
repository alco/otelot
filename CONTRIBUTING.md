# Contributing to Otelot

Thanks for your interest! Otelot is maintained by one person ([@alco](https://github.com/alco))
in their spare time, so please read this before opening an issue or a pull request.

## Expectations

- **Support is best effort.** I use Otelot myself and fix bugs that affect real usage, but
  there are no response-time guarantees.
- **Bug reports** are very welcome. Please include the Otelot, Elixir and OTP versions, the
  relevant configuration, what you expected and what happened instead. A minimal
  reproduction makes a fix much more likely.
- **For anything bigger than a small fix, open an issue first** so we can agree on the
  approach before you invest time in code.
- **No drive-by AI-generated issues or pull requests, please.** Using tools to help you
  write code is fine, but you are expected to understand, test and stand behind every line
  you submit. Low-effort generated reports and PRs will be closed without discussion.

## Development setup

The Elixir and Erlang/OTP versions used for development are pinned in `.tool-versions`
(works with [asdf](https://asdf-vm.com) and [mise](https://mise.jdx.dev)). CI additionally
tests against the oldest supported versions listed in the README.

```sh
mix deps.get
mix test
```

Before pushing, make sure these pass:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

To preview the documentation, run `mix docs` and open `doc/index.html`.

## Pull requests

- Keep them small and focused; one logical change per PR.
- Add tests for new behaviour and bug fixes.
- Update the docs (module docs and `guides/`) if you change anything user-visible.
- Add an entry to the `Unreleased` section of `CHANGELOG.md` for user-visible changes, and
  call out breaking changes explicitly.

## Protobuf definitions

The modules under `lib/otelot/opentelemetry/` are generated from the official
[opentelemetry-proto](https://github.com/open-telemetry/opentelemetry-proto) definitions,
which are vendored as a Git submodule. Don't edit them by hand. To regenerate them, install
`protoc` and `protoc-gen-elixir` (`mix escript.install hex protobuf`), then run:

```sh
git submodule update --init
protoc -I opentelemetry-proto \
  --elixir_out=lib/otelot \
  --elixir_opt=package_prefix=otelot \
  opentelemetry-proto/opentelemetry/proto/{common,resource,metrics,logs}/v1/*.proto \
  opentelemetry-proto/opentelemetry/proto/collector/{metrics,logs}/v1/*_service.proto
mix format
```

## Releasing

Releases are published to Hex by the `Publish to Hex.pm` GitHub workflow when a version tag
is pushed.

1. Bump `@version` in `mix.exs`.
2. In `CHANGELOG.md`, rename `Unreleased` to the new version and date.
3. Commit, then tag the commit: `git tag vX.Y.Z`.
4. Push the commit and the tag: `git push origin main vX.Y.Z`.

The workflow refuses to publish if the tag doesn't match the version in `mix.exs`.

Otelot follows [semantic versioning](https://semver.org). Only the latest release receives
fixes.
