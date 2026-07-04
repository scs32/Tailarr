Pod::Spec.new do |s|
  s.name             = 'GoLunaSea'
  s.version          = '1.0.0'
  s.summary          = 'Tailscale integration for LunaSea'
  s.description      = 'Go-based Tailscale tsnet HTTP proxy for routing .ts.net traffic'
  s.homepage         = 'https://github.com/JagandeepBrar/LunaSea'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'LunaSea' => 'hello@lunasea.app' }
  s.source           = { :path => '.' }
  s.ios.deployment_target = '13.0'
  s.vendored_frameworks = 'GoLunaSea.xcframework'
  s.static_framework = true
end
