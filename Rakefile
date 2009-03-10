require 'rake'
require 'rake/testtask'
version='0.1'

Rake::TestTask.new do |t|
  t.test_files = FileList["test/*_test.rb"]
  t.verbose = true
end

task :default => :test

task :package do
  sh "rm -rf uploader-#{version}"
  sh "svn export . uploader-#{version}"
  sh "tar -jcf uploader-#{version}.tar.bz2 uploader-#{version}"
  sh "rm -rf uploader-#{version}"
end
