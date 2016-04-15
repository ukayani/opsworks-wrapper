# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "opsworks_wrapper"
  spec.version       = '0.1.0'
  spec.authors       = ["Umair Kayani", "Calvin Fernandes"]
  spec.email         = ["ukayani@loyalty.com", "cfernandes@loyalty.com"]

  spec.summary       = "A wrapper for AWS OpsWorks to make deploying to the service easier"
  spec.homepage      = "https://github.com/ukayani/opsworks-wrapper"
  spec.license       = "MIT"


  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'aws-sdk', '~> 2'
  spec.add_dependency 'colorize', '0.7.7'
  spec.add_development_dependency "bundler", "~> 1.11"
  spec.add_development_dependency "rake", "~> 10.0"
end
