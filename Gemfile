# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# `acemq-amqp` is not on rubygems.org. It is published to AceMQ's own static
# feed at https://acemq.org/gems — a directory tree over HTTPS, no account and
# no credential — and this block is what lets the gemspec's dependency on it
# resolve. A gemspec cannot name a source for its own dependencies, so the
# Gemfile has to.
#
# Deliberately not a path dependency to ../acemq-ruby-amqp. This repository's
# job is to prove that the *published* gem works: a path dependency would test
# whatever is on the library's main branch, which is not what anybody installs,
# and this family of repositories has shipped that mistake before.
source "https://acemq.org/gems" do
  gem "acemq-amqp", "~> 0.6"
end

group :development, :test do
  # The transport. The library requires it lazily and names it when it is
  # missing; nothing opens a socket without it, and the specs do.
  gem "bunny", "~> 2.23"

  # Ruby 4.0 dropped `logger` from the default gems and bunny 2.24 still
  # requires it without declaring it, so bunny will not load on a current Ruby
  # without this line. Bunny's omission rather than ours, and it belongs beside
  # bunny for whoever wonders why a standard-library name is in a Gemfile.
  gem "logger", "~> 1.6"

  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.66"
  gem "rubocop-rspec", "~> 3.0"

  # The real-Rails-boot spec generates an application in a temp directory and
  # runs it. It needs the framework, not only railties: `rails new` is in the
  # `rails` gem, ActiveRecord is what makes the executor worth wrapping, and
  # Puma is what proves a controller can publish.
  #
  # CI pins a line through RAILS_VERSION, so the matrix proves 7.1, 7.2 and 8.0
  # rather than whatever bundler resolved on the morning of the run. Unpinned
  # locally, where the newest supported line is the useful one.
  if (line = ENV.fetch("RAILS_VERSION", nil))
    gem "rails", "~> #{line}.0"
  else
    gem "rails", ">= 7.1", "< 9.0"
  end
  gem "sqlite3", ">= 1.4"

  # The documentation site's API reference is generated from the comments in
  # lib/. Here rather than in the gemspec because nobody installing this needs a
  # documentation tool to use it.
  gem "yard", "~> 0.9"
end
