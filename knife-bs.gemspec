# -*- encoding: utf-8 -*-
$:.push File.expand_path('../lib', __FILE__)
require 'knife-bs/version'
Gem::Specification.new do |s|
  s.name             = 'knife-bs'
  s.version          = Knife::Bs::VERSION
  s.date             = '2014-03-24'
  s.authors          = ['Parth Santpurkar', 'Kevin Amorin',
                        'Isaac Boehman', 'Pasha Sadikov']
  s.email            = 'ops@bitsighttech.com'
  s.homepage         = 'https://github.com/cbitlabs/knife-bs'
  s.summary          = 'Declarative cloud infrastructure tool'
  s.description      = 'BitSight Knife plugin to interact with EC2'

  s.files            = Dir['lib/chef/knife/*.rb'] +
                       Dir['lib/knife-bs/*.rb']
  s.files           += Dir['lib/*.yaml'] +
                       Dir.glob('lib/chef/knife/mixins/**/*')
  s.files           += Dir['lib/chef/bs_utils/*.rb'] +
                       Dir['lib/knife-bs/monkey_patches/*.rb']
  s.files           += %w[.gitignore Gemfile knife-bs.gemspec Rakefile]
  s.require_paths    = ['lib']
  s.license          = 'Apache v2.0'
  s.has_rdoc         = false

  s.add_dependency 'unf'
  s.add_dependency 'chef', '>= 0.10.18'
  s.add_dependency 'knife-ec2', '>= 0.8.0'
  s.add_dependency 'terminal-table', '~> 1.4.3'
  s.add_dependency 'parallel', '~> 0.6.2'
  s.add_dependency 'ruby-progressbar', '~> 1.1.1'
  s.add_dependency 'awesome_print', '~> 1.0.0'
  s.add_dependency 'kwalify', '~> 0.7.2'

  # Development requirements
  # s.add_development_dependency 'rspec-core'
  # s.add_development_dependency 'rspec-expectations'
  # s.add_development_dependency 'rspec-mocks'
  # s.add_development_dependency 'rspec_junit_formatter'
  s.add_development_dependency 'pry'
end
