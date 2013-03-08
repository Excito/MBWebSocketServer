Pod::Spec.new do |s|
  s.name         = "MBWebSocketServer"
  s.version      = "0.0.1"
  s.summary      = "An easy to use Objective-C draft 10 websocket implementation."
  s.homepage     = "https://github.com/Excito/MBWebSocketServer"
  s.license      = 'Public'
  s.author       = { "Max Howell" => "mxcl@me.com" }
  s.source       = { :git => "https://github.com/Excito/MBWebSocketServer.git", :tag => s.version.to_s }
  s.platform     = :ios, '5.0'
  s.source_files = '**/MB*.{h,m}'
  s.requires_arc = true
  s.framework    = 'CFNetwork', 'Security'
end