source "https://rubygems.org"
git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }
ruby ">= 3.4.10"
gemspec

group :test do
  gem "rspec", require: false
end

group :lint do
  # use `bundle exec rubocop` to lint.
  gem "standard", require: false
  gem "rubocop-rspec", require: false
end

group :type_check do
  gem "rbs", require: false
end

group :documentation do
  gem "rake", require: false
  # Installing rdoc by bundler causes plugin loading issue.
  # https://github.com/ruby/rubygems/issues/9250
  # https://github.com/ruby/rubygems/issues/9285
  # https://github.com/ruby/rdoc/issues/1609
  gem "rdoc", require: false
end

group :benchmark do
  gem "benchmark-ips", require: false
  gem "ruby-prof", require: false
end
