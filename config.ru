require 'rack'
require 'rack/contrib'

use Rack::PostBodyContentTypeParser

require './shortcut.rb'

run Sinatra::Application
