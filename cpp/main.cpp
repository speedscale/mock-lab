// proxymock CNCF demo app (C++). Exposes a small HTTP API on :8080 and fulfills each
// request by calling the CNCF downstream API. libcurl is used for the downstream call;
// it honors HTTP(S)_PROXY env vars, so proxymock can record/mock/replay with no change.
// A minimal POSIX-socket server handles the inbound side. Build/run: make run
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <unistd.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <curl/curl.h>

static std::string downstream() {
  const char* d = std::getenv("DOWNSTREAM_URL");
  return d ? d : "https://demo-api-dev.trafficreplay.com";
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
  const char* status = code == 200 ? "200 OK" : code == 404 ? "404 Not Found" : "502 Bad Gateway";
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

    // Parse the request line: "GET <path> HTTP/1.1".
    std::string req(buf);
    std::string path = "/";
    size_t sp1 = req.find(' ');
    if (sp1 != std::string::npos) {
      size_t sp2 = req.find(' ', sp1 + 1);
      if (sp2 != std::string::npos) path = req.substr(sp1 + 1, sp2 - sp1 - 1);
    }

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
    } else {
      respond(fd, 404, "{\"error\":\"not found\"}");
    }
    close(fd);
  }

  curl_global_cleanup();
  return 0;
}
