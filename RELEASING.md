# Releasing

This gem is published to the **AceMQ gem feed** — `AceMQ-Company/gems`, served as
a static index at <https://acemq.org/gems/> beside `acemq-amqp` itself, the Maven
repository and the NuGet feed. It is **not** published to rubygems.org, and
`release.yml` does not use trusted publishing; it pushes a built `.gem` and a
regenerated index into that repository over SSH.

That is deliberate, and it is about reversibility. A version pushed to
rubygems.org cannot really be withdrawn — a yank hides it from the index but does
not free the version number and does not take it back from anybody who already
resolved it. A release in this feed is corrected by deleting a file and
re-indexing, which is the property worth having while the gem is pre-1.0. Moving
to rubygems.org later changes nothing for a consumer except the source line.

## Before tagging

1. **Set the version constant.** `AceMQ::Rails::VERSION` in
   [`lib/acemq/rails/version.rb`](lib/acemq/rails/version.rb) is the single
   source of truth. The gemspec reads it, the built gem carries it, and the
   workflow fails a tag that disagrees with it.

   ```ruby
   VERSION = "0.1.0"
   ```

   **The version comes from the working tree, not from the tag.** A `v0.1.1` tag
   on a commit that still says `0.1.0` fails the run before anything is built, so
   the constant is bumped in the commit the tag points at.

2. **Roll the changelog.** Rename `## [Unreleased]` to `## [<version>] -
   <date>`, leave an empty `## [Unreleased]` above it, and update the two link
   definitions at the bottom of the file.

3. **Check the dependency constraint.** `spec.add_dependency "acemq-amqp"` names
   a version of a gem that lives in the same feed. If that library moved,
   the constraint here moves with it and that is a release of this gem — see
   [the version line](#the-version-line) below.

4. **Update the README's status line and version badge**, both of which name the
   version in prose.

5. **Commit, push, and let CI go green** on the whole matrix.

6. **Tag and push.** Annotated, so the tag carries a message and a date.

   ```bash
   git tag -a v0.1.0 -m "AceMQ for Rails 0.1.0"
   git push origin v0.1.0
   ```

## What the workflow does

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs on a `v*`
tag in four jobs. Nothing reaches the feed until all three checking jobs pass.

**`verify`** — on Ruby 3.1, the floor the gemspec promises:

- the tag is on the current release line (see [the version line](#the-version-line));
- `AceMQ::Rails::VERSION` equals the tag with its `v` stripped;
- `bundle exec rspec` and `bundle exec rubocop`;
- `gem build`, then a check that the built `.gem` actually contains the Railtie,
  the consumer, the runner, the registry, the rake file and `exe/acemq-consumer`.
  `spec.files` is a `Dir` glob, so a new file under `lib/` is included by luck
  rather than by decision — and a gem missing its Railtie installs perfectly and
  does nothing at all in somebody else's application;
- the gem installs into a clean `GEM_HOME` with only its declared dependencies
  and `require "acemq/rails"` works there. This is the one thing the specs cannot
  catch: `rails`, `rspec` and `bunny` are all in this repository's Gemfile and
  none of them is a dependency of the gem, so a stray `require "bunny"` passes
  every spec and fails in an application that has only what the gemspec asks for.

**`matrix`** — the full Ruby × Rails grid, on the tag itself. CI proves this on a
pull request, but a tag can point at any commit, so it is proven again rather
than assumed from a green branch.

**`integration`** — the `:integration` specs against RabbitMQ 4, including the
one that generates a real Rails application, boots it under Puma, publishes
through an HTTP request, consumes in a second process and shuts it down with
`SIGTERM`. `spec_helper` *excludes* every integration example when
`ACEMQ_TEST_BROKER` is unset, and an unset variable looks exactly like a passing
run — so the job counts the examples and fails below fifteen, and greps the log
for the real-Rails-application group by name.

**`publish`** — tags only, and only after the other three:

- it checks `GEMS_REPO_DEPLOY_KEY` is non-empty **before building anything**. An
  unset secret is an empty string, and `actions/checkout` reads an empty
  `ssh-key` as "use the default token", which can read a public repository and
  cannot write to it. Without this check the run would get all the way to
  `git push` before failing, having already built and indexed a gem;
- it re-checks the tag against the constant, builds the gem, and then reads the
  version back **out of the built file** with `Gem::Package`. `gem build` reads
  the constant, but the artifact is what anybody installs;
- it checks out `AceMQ-Company/gems`, runs that repository's `scripts/publish.sh`
  over the new gem, and pushes. The feed is cloned first and the index
  regenerated over *everything* already published — building it from this release
  alone would leave `acemq-amqp` on disk and invisible to every client, which
  would break this gem's own dependency as well as the release;
- it then **installs the published gem back out of the feed** and prints its
  version. A feed is only real if a client can resolve from it, and this gem asks
  more of it than the library does: `acemq-amqp ~> 0.7.0` has to resolve from the
  same index in the same install. GitHub Pages takes a moment to serve a new
  commit, so this retries for five minutes rather than racing the deploy.

A manual `workflow_dispatch` runs every check against a branch and stops short of
publishing — `publish` is gated on `refs/tags/v`. That is what makes the workflow
safe to try out, and it is how a release whose publish step failed is re-run
without moving a tag.

The workflow runs **after** the tag is pushed, because that is when a tag event
happens. It cannot prevent a bad release, only refuse to publish one — which is
why the steps under [Before tagging](#before-tagging) are worth doing first.

## Credentials

`GEMS_REPO_DEPLOY_KEY` — an **SSH deploy key with write access to
`AceMQ-Company/gems` and to nothing else in the organisation**, set as an Actions
secret on **this** repository.

A deploy key rather than a personal access token because a token carries its
owner's reach across every repository they can see, and this job needs exactly
one. Secrets are not inherited between repositories: the library having this
secret does nothing for this one, and the key has to be added here before a tag
is cut. Nothing else is needed — the feed is served over plain HTTPS with no
account and no credential on the reading side, and the `gems` environment on the
`publish` job is where an approval requirement would go if one is ever wanted.

## The version line

**`0.1.x` until somebody decides otherwise.** The release workflow refuses
anything else — a tag outside the line fails in `verify` with a message naming
the guard — so moving the line is a deliberate edit to `release.yml` rather than
a typo in a tag. Lift it by changing the `case` pattern and the error message in
the *Check the tag is a 0.1.x version* step, in the same commit that bumps
`VERSION` past the line, so the two facts never disagree.

Guard it, rather than allowing any `v*`, because a gem in a feed somebody has
already resolved against is not recallable in any way that helps them. `v1.0.0`
typed for `v0.1.0` spends the 1.0 number on a pre-1.0 release, and that is not
undone by deleting a file.

### Why this is not the library's version

This gem is `0.1.0` while `acemq-amqp` is `0.7.x`, and the two are not going to
converge. It tracks **two** release trains rather than one: a Rails release that
moves an autoloading hook is a release here and nothing at all in the library,
and a library release that adds a publishing method is a dependency bump here
rather than a new number. Sharing a version would mean one of those two facts had
to be lied about. `acemq-java-amqp-spring-boot-starter` is a separate repository
on a separate line for exactly the same reason, and gives the same reasoning.

## The supported matrix

What a release promises, and what `ci.yml` and the `matrix` job both prove:

| | Rails 7.1 | Rails 7.2 | Rails 8.0 |
|---|---|---|---|
| **Ruby 3.1** | yes | yes | — |
| **Ruby 3.2** | yes | yes | yes |
| **Ruby 3.3** | yes | yes | yes |
| **Ruby 3.4** | yes | yes | yes |

Ruby 3.1 with Rails 8.0 is excluded because Rails 8 requires Ruby 3.2. That is
Rails' constraint rather than one this gem adds, so the combination that cannot
exist is excluded rather than pretended.

The floors are declared in two places and both are part of the release:
`required_ruby_version = ">= 3.1"` and `add_dependency "railties", ">= 7.1", "<
9.0"`.

**Dropping a Rails version is a minor bump, not a patch** — so is raising the
Ruby floor. An application that resolves `~> 0.1.0` and gets a patch expects the
same set of Rails lines to keep working; a patch that raises `railties` to
`>= 7.2` makes `bundle update` fail on an application nobody touched, with a
resolution error rather than anything that names this gem. Adding a Rails line
is a minor too, because the upper bound in the gemspec has to move for it and
that is a change to what the gem accepts.

When a line is dropped, the matrix in `ci.yml` and in `release.yml` and the table
above move together with the gemspec, and the changelog says which line went and
why. Rails 7.1's own security support is the usual reason.

## Verifying a release actually published

The `publish` job does this itself and fails if it cannot — but to check by hand,
from a machine that has never seen the gem:

```bash
GEM_HOME=$(mktemp -d) gem install acemq-amqp-rails -v 0.1.0 \
  --source https://acemq.org/gems/ --source https://rubygems.org/ --no-document
```

Both sources, because `acemq-amqp` comes from the feed and `railties` comes from
rubygems.org. Then in an application:

```ruby
# Gemfile
source "https://acemq.org/gems" do
  gem "acemq-amqp-rails", "~> 0.1.0"
end
```

A gemspec cannot name a source for its own dependencies, which is why the
application's Gemfile has to.

If the install cannot find the version, look at the commit in
`AceMQ-Company/gems` and at whether Pages has deployed it —
<https://acemq.org/gems/versions> should list `acemq-amqp-rails` and the version.
An index built by an old RubyGems writes only the classic index, which looks
empty to a current client and perfectly correct to the generator that made it;
that is why `publish` pins `rubygems: latest` on the floor Ruby.

## If a release is wrong

Delete the `.gem` from `AceMQ-Company/gems`, re-run its `scripts/publish.sh` so
the index no longer lists it, and push. Then delete the tag here and
release the next patch — the number is spent, but nothing is permanent. This is
the whole reason the feed exists rather than rubygems.org.
