#!/usr/bin/env ruby

require 'rubygems'
require 'sinatra'
require 'braintree'
require 'json'
require 'yaml'

Config = YAML::load(open("bluebottle.yml", 'r'))

Products = YAML::load(open("products.yml", 'r'))
ProductsByUPC = Hash[ *Products.map{|p| [p[:upc], p]}.flatten ]
ProductsByID  = Hash[ *Products.map{|p| [p[:id],  p]}.flatten ]

Cafes = JSON::parse(open("cafes.json", 'r').read)
CafesByID = Hash[ *Cafes.map{|p| [p["id"], p]}.flatten ]

Braintree::Configuration.environment = Config['environment']
Braintree::Configuration.merchant_id = Config['merchant_id']
Braintree::Configuration.public_key  = Config['public_key']
Braintree::Configuration.private_key = Config['private_key']

class Rack::Request
  def client_guid
    env['HTTP_X_CLIENT_ID']
  end
  def session_id
    env['HTTP_X_SESSION_ID']
  end
  def api_key
    env['HTTP_X_API_KEY']
  end
end

before do
  unless request.api_key and Config['api_keys'].include? request.api_key
    json_error 403, "Invalid API key: #{request.api_key}"
  end
end

def json_error code, message
  halt code, {'Content-Type' => 'application/json'}, { errors: [{ message: message }] }.to_json
end

get '/payments/client', provides: :json do
  begin
    client_token = Braintree::ClientToken.generate
    { client: {
        token:              client_token,
        merchant_id:        Config['applepay_merchant_id'],
        currency_code:      Config['currency_code'],
        country_code:       Config['country_code'],
        supported_networks: Config['supported_networks']
    }}.to_json
  rescue e
    json_error e.code, e.message
  end
end

get '/products/:upc', provides: :json do
  product = ProductsByUPC[params[:upc]]
  json_error 404, "Product not found" unless product
  json_error 500, "Invalid product" unless product[:price]
  response = {
    id:          product[:id],
    name:        product[:name],
    description: product[:description],
    price:       product[:price],
    image_url:   product[:image_url]
  }
  response[:tax] = (product[:price] * 0.0875).round if params[:cafe_id] && !product[:is_food]
  { product: response}.to_json
end

post '/payments', provides: :json do
  nonce = params[:nonce]
  json_error 403, "No payment nonce provided!" unless nonce
  
  product_id = params[:product_id].to_i
  product = ProductsByID[product_id]
  json_error 404, "Invalid product!" unless product_id and product and product[:price]
  
  cafe_id = params[:cafe_id].to_i
  cafe = CafesByID[cafe_id]
  json_error 403, "Can't buy physical goods outside a cafe!" unless cafe_id and cafe
  
  email = params[:email] || ''
  
  tax = product[:is_food] ? 0 : (product[:price] * 0.0875).round
  
  amount = "%.02f" % ((tax + product[:price]) / 100.0)
  
  result = Braintree::Transaction.sale(amount: amount, payment_method_nonce: nonce)
  
  case result
  when Braintree::SuccessfulResult
    if result.success?
      { receipt: {
        name:         product[:name],
        price:        product[:price],
        tax:          tax,
        total_price:  tax + product[:price],
        date:         Time.now.utc.iso8601,
        location:     cafe["title"],
        email:        email
      } }.to_json
    else
      json_error 403, "Error processing payment! #{result.errors.first.message}"
    end
  when Braintree::ValidationError
    json_error 403, result.errors.first.message
  when Braintree::ErrorResult
    # different from a validation error or an unsuccessful successful result.
    # e.g., processing two identical payments in a row.
    json_error 403, "Error processing payment!"
  end
end
