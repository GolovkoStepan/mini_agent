# frozen_string_literal: true

require_relative "lib/mini_agent/version"

Gem::Specification.new do |spec|
  spec.name = "mini_agent"
  spec.version = MiniAgent::VERSION
  spec.authors = ["s.golovko"]
  spec.email = ["s.golovko@tdm-tech.ru"]

  spec.summary = "Минимальный кодовый агент с вызовом инструментов через OpenAI-совместимый API"
  spec.description = "MiniAgent — консольный агент, который решает задачи программирования, " \
                     "вызывая shell-команды через LLM с поддержкой tool calling. " \
                     "Рассчитан на локальный сервер (LM Studio, Ollama) или любой " \
                     "OpenAI-совместимый эндпоинт."
  spec.homepage = "https://github.com/GolovkoStepan/mini_agent"
  spec.license = "MIT"
  # 3.3 — нижняя граница dev-зависимостей (parallel через rubocop, rbs, rdoc);
  # на более старых не встаёт bundle, поэтому и обещать их нельзя.
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
