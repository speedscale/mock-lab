# proxymock CNCF demo app (Ruby). Exposes a small HTTP API on :8080 and fulfills each
# request by calling the CNCF downstream API. Net::HTTP is used for the downstream call.
# Minimal stdlib-only server (no gems) so it runs with just `ruby app.rb`.
require "socket"
require "net/http"
require "json"
require "securerandom"
require "set"
require "time"

DOWNSTREAM = ENV.fetch("DOWNSTREAM_URL", "https://demo-api.trafficreplay.com")
PORT = (ENV["PORT"] || "8080").to_i

VALID_TOKENS = Set.new
ORDERS = {}

def fetch(path)
  res = Net::HTTP.get_response(URI(DOWNSTREAM + path))
  [res.code.to_i, res.body]
end

def authed?(auth_header)
  return false unless auth_header && auth_header.start_with?("Bearer ")
  VALID_TOKENS.include?(auth_header[7..])
end

server = TCPServer.new(PORT)
puts "ruby demo on :#{PORT} (downstream=#{DOWNSTREAM})"

loop do
  conn = server.accept
  request_line = conn.gets
  path = request_line ? request_line.split(" ")[1] : "/"
  auth_header = nil
  content_length = 0
  while (line = conn.gets) && line != "\r\n"
    if line =~ /\AAuthorization:\s*(.*?)\r?\n\z/i
      auth_header = $1
    elsif line =~ /\AContent-Length:\s*(\d+)\r?\n\z/i
      content_length = $1.to_i
    end
  end
  req_body = content_length > 0 ? conn.read(content_length) : ""

  code = 200
  begin
    case path
    when "/"
      body = { service: "proxymock-cncf-demo", lang: "ruby", downstream: DOWNSTREAM }.to_json
    when "/api/projects"
      code, body = fetch("/v1/projects")
    when %r{\A/api/projects/(.+)\z}
      code, body = fetch("/v1/project/#{$1}")
    when "/api/categories"
      code, body = fetch("/v1/categories")
    when "/api/stats"
      _, raw = fetch("/v1/projects")
      projects = JSON.parse(raw)
      by_maturity = Hash.new(0)
      projects.each { |proj| by_maturity[proj["maturity"]] += 1 }
      body = { total: projects.size, by_maturity: by_maturity }.to_json
    when "/oauth/token"
      token = SecureRandom.hex(32)
      VALID_TOKENS << token
      code = 200
      body = { access_token: token, token_type: "Bearer", expires_in: 3600 }.to_json
    when "/api/orders"
      if !authed?(auth_header)
        code = 401
        body = { error: "missing or invalid bearer token" }.to_json
      else
        parsed = req_body.empty? ? {} : JSON.parse(req_body)
        project = parsed["project"]
        if project.nil? || project.empty?
          code = 400
          body = { error: "project is required" }.to_json
        else
          dcode, _ = fetch("/v1/project/#{project}")
          if dcode != 200
            code = 404
            body = { error: "unknown project", project: project }.to_json
          else
            order = {
              order_id: "order-#{SecureRandom.hex(8)}",
              project: project,
              status: "created",
              created: Time.now.utc.iso8601
            }
            ORDERS[order[:order_id]] = order
            code = 201
            body = order.to_json
          end
        end
      end
    when %r{\A/api/orders/(.+)\z}
      id = $1
      if !authed?(auth_header)
        code = 401
        body = { error: "missing or invalid bearer token" }.to_json
      elsif (order = ORDERS[id]).nil?
        code = 404
        body = { error: "order not found", order_id: id }.to_json
      else
        code = 200
        body = order.to_json
      end
    else
      code = 404
      body = { error: "not found" }.to_json
    end
  rescue => e
    code = 502
    body = { error: e.message }.to_json
  end

  conn.print "HTTP/1.1 #{code}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  conn.close
end
