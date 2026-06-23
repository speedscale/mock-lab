# proxymock CNCF demo app (Ruby). Exposes a small HTTP API on :8080 and fulfills each
# request by calling the CNCF downstream API. Net::HTTP is used for the downstream call.
# Minimal stdlib-only server (no gems) so it runs with just `ruby app.rb`.
require "socket"
require "net/http"
require "json"

DOWNSTREAM = ENV.fetch("DOWNSTREAM_URL", "https://demo-api.trafficreplay.com")
PORT = (ENV["PORT"] || "8080").to_i

def fetch(path)
  res = Net::HTTP.get_response(URI(DOWNSTREAM + path))
  [res.code.to_i, res.body]
end

server = TCPServer.new(PORT)
puts "ruby demo on :#{PORT} (downstream=#{DOWNSTREAM})"

loop do
  conn = server.accept
  request_line = conn.gets
  path = request_line ? request_line.split(" ")[1] : "/"
  while (line = conn.gets) && line != "\r\n"; end # drain headers

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
