require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
  t.verbose = false
end

load 'lib/workbench/tasks/smoke_test.rake'

task default: :test
