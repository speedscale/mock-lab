// proxymock CNCF demo app (C++). Exposes a small HTTP API on :8080 and fulfills each
// request by calling the CNCF downstream API. libcurl is used for the downstream call;
// it honors HTTP(S)_PROXY env vars for routing, and the app sets CURLOPT_CAINFO from
// $SSL_CERT_FILE (see http_get) so proxymock's TLS interception is trusted on Linux.
// A minimal POSIX-socket server handles the inbound side. Build/run: make run
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <map>
#include <random>
#include <set>
#include <string>
#include <utility>
#include <unistd.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <curl/curl.h>

// In-memory state for the OAuth/orders endpoints (single-threaded server).
static std::set<std::string> g_valid_tokens;
static std::map<std::string, std::string> g_orders;

// Convert raw bytes to a lowercase hex string.
static std::string to_hex(const unsigned char* bytes, size_t len) {
  static const char* hexd = "0123456789abcdef";
  std::string out;
  out.reserve(len * 2);
  for (size_t i = 0; i < len; i++) {
    out.push_back(hexd[bytes[i] >> 4]);
    out.push_back(hexd[bytes[i] & 0x0f]);
  }
  return out;
}

// Generate `n` random bytes -> 2n hex chars, via std::random_device.
static std::string random_hex(size_t n) {
  std::random_device rd;
  std::string bytes(n, '\0');
  for (size_t i = 0; i < n; i++) {
    bytes[i] = static_cast<char>(rd() & 0xff);
  }
  return to_hex(reinterpret_cast<const unsigned char*>(bytes.data()), n);
}

// Current UTC time as RFC3339, e.g. 2026-06-23T12:34:56Z.
static std::string utc_rfc3339() {
  std::time_t t = std::time(nullptr);
  std::tm tmv{};
  gmtime_r(&t, &tmv);
  char buf[32];
  std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tmv);
  return std::string(buf);
}

static std::string downstream() {
  const char* d = std::getenv("DOWNSTREAM_URL");
  return d ? d : "https://demo-api.trafficreplay.com";
}

static int listen_port() {
  const char* p = std::getenv("PORT");
  return p ? std::atoi(p) : 8080;
}

static size_t write_cb(char* ptr, size_t sz, size_t nm, void* ud) {
  static_cast<std::string*>(ud)->append(ptr, sz * nm);
  return sz * nm;
}

// GET url -> {http_status, body}. libcurl reads *_proxy env vars automatically.
static std::pair<long, std::string> http_get(const std::string& url) {
  CURL* c = curl_easy_init();
  std::string body;
  long code = 0;
  curl_easy_setopt(c, CURLOPT_URL, url.c_str());
  curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, write_cb);
  curl_easy_setopt(c, CURLOPT_WRITEDATA, &body);
  curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(c, CURLOPT_TIMEOUT, 10L);
  // Honor SSL_CERT_FILE so proxymock's TLS interception is trusted. libcurl (unlike
  // the curl CLI) does not read this env var on its own — it uses a compiled-in CA
  // bundle — so we must point CAINFO at it explicitly. Without this, the downstream
  // HTTPS call through proxymock fails with CURLE_PEER_FAILED_VERIFICATION.
  if (const char* ca = std::getenv("SSL_CERT_FILE"); ca && *ca) {
    curl_easy_setopt(c, CURLOPT_CAINFO, ca);
  }
  CURLcode rc = curl_easy_perform(c);
  if (rc == CURLE_OK) {
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
  } else {
    code = 502;
    body = std::string("{\"error\":\"") + curl_easy_strerror(rc) + "\"}";
  }
  curl_easy_cleanup(c);
  return {code, body};
}

static int count_occ(const std::string& s, const std::string& sub) {
  int n = 0;
  size_t i = 0;
  while ((i = s.find(sub, i)) != std::string::npos) {
    n++;
    i += sub.size();
  }
  return n;
}

static void respond(int fd, int code, const std::string& body) {
  const char* status =
      code == 200   ? "200 OK"
      : code == 201 ? "201 Created"
      : code == 400 ? "400 Bad Request"
      : code == 401 ? "401 Unauthorized"
      : code == 404 ? "404 Not Found"
                    : "502 Bad Gateway";
  std::string resp = std::string("HTTP/1.1 ") + status +
                     "\r\nContent-Type: application/json\r\nContent-Length: " +
                     std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
  send(fd, resp.data(), resp.size(), 0);
}

int main() {
  curl_global_init(CURL_GLOBAL_DEFAULT);

  int srv = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port = htons(listen_port());
  if (bind(srv, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
    perror("bind");
    return 1;
  }
  listen(srv, 16);
  fprintf(stderr, "cpp demo on :%d (downstream=%s)\n", listen_port(), downstream().c_str());

  for (;;) {
    int fd = accept(srv, nullptr, nullptr);
    if (fd < 0) continue;

    char buf[8192];
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) {
      close(fd);
      continue;
    }
    buf[n] = '\0';

    // Parse the request line: "<METHOD> <path> HTTP/1.1".
    std::string req(buf, static_cast<size_t>(n));
    std::string method = "GET";
    std::string path = "/";
    size_t sp1 = req.find(' ');
    if (sp1 != std::string::npos) {
      method = req.substr(0, sp1);
      size_t sp2 = req.find(' ', sp1 + 1);
      if (sp2 != std::string::npos) path = req.substr(sp1 + 1, sp2 - sp1 - 1);
    }

    // Split headers from body at the blank line.
    std::string headers = req;
    std::string body;
    size_t hb = req.find("\r\n\r\n");
    if (hb != std::string::npos) {
      headers = req.substr(0, hb);
      body = req.substr(hb + 4);
    }

    // Extract the bearer token from the Authorization header (case-insensitive name).
    std::string bearer;
    {
      std::string lower = headers;
      for (char& ch : lower) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
      size_t ap = lower.find("authorization:");
      if (ap != std::string::npos) {
        size_t eol = headers.find("\r\n", ap);
        std::string line = headers.substr(ap, eol == std::string::npos ? std::string::npos : eol - ap);
        size_t colon = line.find(':');
        std::string val = colon == std::string::npos ? "" : line.substr(colon + 1);
        size_t b = val.find_first_not_of(" \t");
        if (b != std::string::npos) val = val.substr(b);
        const std::string scheme = "Bearer ";
        if (val.rfind(scheme, 0) == 0) {
          bearer = val.substr(scheme.size());
          size_t e = bearer.find_last_not_of(" \t\r\n");
          if (e != std::string::npos) bearer = bearer.substr(0, e + 1);
        }
      }
    }
    bool authed = !bearer.empty() && g_valid_tokens.count(bearer) > 0;

    const std::string ds = downstream();
    const std::string prefix = "/api/projects/";
    if (path == "/") {
      respond(fd, 200, "{\"service\":\"proxymock-cncf-demo\",\"lang\":\"cpp\",\"downstream\":\"" + ds + "\"}");
    } else if (path == "/api/projects") {
      auto [code, body] = http_get(ds + "/v1/projects");
      respond(fd, code, body);
    } else if (path.rfind(prefix, 0) == 0) {
      auto [code, body] = http_get(ds + "/v1/project/" + path.substr(prefix.size()));
      respond(fd, code, body);
    } else if (path == "/api/categories") {
      auto [code, body] = http_get(ds + "/v1/categories");
      respond(fd, code, body);
    } else if (path == "/api/stats") {
      auto [code, body] = http_get(ds + "/v1/projects");
      (void)code;
      int total = count_occ(body, "\"id\":");
      int g = count_occ(body, "\"Graduated\"");
      int inc = count_occ(body, "\"Incubating\"");
      int s = count_occ(body, "\"Sandbox\"");
      respond(fd, 200, "{\"total\":" + std::to_string(total) + ",\"by_maturity\":{\"Graduated\":" +
                       std::to_string(g) + ",\"Incubating\":" + std::to_string(inc) +
                       ",\"Sandbox\":" + std::to_string(s) + "}}");
    } else if (method == "POST" && path == "/oauth/token") {
      std::string token = random_hex(32);  // 32 bytes -> 64 hex chars
      g_valid_tokens.insert(token);
      respond(fd, 200, "{\"access_token\":\"" + token +
                       "\",\"token_type\":\"Bearer\",\"expires_in\":3600}");
    } else if (method == "POST" && path == "/api/orders") {
      if (!authed) {
        respond(fd, 401, "{\"error\":\"missing or invalid bearer token\"}");
      } else {
        // Extract "project" from the JSON body {"project":"<id>"} via substring search.
        std::string project;
        size_t kp = body.find("\"project\"");
        if (kp != std::string::npos) {
          size_t colon = body.find(':', kp);
          if (colon != std::string::npos) {
            size_t q1 = body.find('"', colon + 1);
            if (q1 != std::string::npos) {
              size_t q2 = body.find('"', q1 + 1);
              if (q2 != std::string::npos) project = body.substr(q1 + 1, q2 - q1 - 1);
            }
          }
        }
        if (project.empty()) {
          respond(fd, 400, "{\"error\":\"project is required\"}");
        } else {
          auto [vcode, vbody] = http_get(ds + "/v1/project/" + project);
          (void)vbody;
          if (vcode != 200) {
            respond(fd, 404, "{\"error\":\"unknown project\",\"project\":\"" + project + "\"}");
          } else {
            std::string order_id = "order-" + random_hex(8);  // 8 bytes -> 16 hex chars
            std::string created = utc_rfc3339();
            std::string order = "{\"order_id\":\"" + order_id + "\",\"project\":\"" + project +
                                "\",\"status\":\"created\",\"created\":\"" + created + "\"}";
            g_orders[order_id] = order;
            respond(fd, 201, order);
          }
        }
      }
    } else if (method == "GET" && path.rfind("/api/orders/", 0) == 0) {
      if (!authed) {
        respond(fd, 401, "{\"error\":\"missing or invalid bearer token\"}");
      } else {
        std::string id = path.substr(std::string("/api/orders/").size());
        auto it = g_orders.find(id);
        if (it == g_orders.end()) {
          respond(fd, 404, "{\"error\":\"order not found\",\"order_id\":\"" + id + "\"}");
        } else {
          respond(fd, 200, it->second);
        }
      }
    } else {
      respond(fd, 404, "{\"error\":\"not found\"}");
    }
    close(fd);
  }

  curl_global_cleanup();
  return 0;
}
