require "rake/testtask"
require "rdoc/task"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

RDoc::Task.new(:docs) do |r|
  r.main = "README.md"
  r.title = "Sashiko — Declarative OpenTelemetry for Ruby 4"
  r.rdoc_dir = "doc"
  r.rdoc_files.include("lib/**/*.rb", "README.md")
end

task default: :test
