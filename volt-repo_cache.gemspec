# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'volt/repo_cache/version'

Gem::Specification.new do |spec|
  spec.name          = "volt-repo_cache"
  spec.version       = Volt::RepoCache::VERSION
  spec.authors       = ["Colin Gunn"]
  spec.email         = ["colgunn@icloud.com"]
  spec.summary       = %q{Caching for collections, models and their associations loaded from Volt repositories.}
  spec.description   = %q{Cache multiple collections or query based subsets from any Volt repository. Provides faster and simpler client-side processing. Reduces the burden of promise handling. Changes - updates, creates and destroys - can be saved (flushed) back to the repository at model, collection or cache level.}
  spec.homepage      = "https://github.com/balmoral/volt-repo_cache"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "volt", "~> 0.9.6"

end
