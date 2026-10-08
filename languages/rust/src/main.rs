// proxymock CNCF demo app (Rust). Exposes a small HTTP API on :8080 and fulfills
// each request by calling the CNCF downstream API. reqwest honors HTTP(S)_PROXY
// by default, but rustls does not read SSL_CERT_FILE, so we load that file as an
// extra root CA when proxymock injects it. Run: cargo run
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

fn downstream() -> String {
    env::var("DOWNSTREAM_URL").unwrap_or_else(|_| "https://demo-api.trafficreplay.com".into())
}

fn port() -> u16 {
    env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8080)
}

fn http_client() -> reqwest::blocking::Client {
    let mut b = reqwest::blocking::Client::builder().timeout(std::time::Duration::from_secs(10));
    // rustls (unlike the curl CLI / OpenSSL) ignores SSL_CERT_FILE. Load it as an
    // extra root so proxymock's TLS interception verifies on record and mock.
    if let Ok(path) = env::var("SSL_CERT_FILE") {
        if let Ok(pem) = fs::read(&path) {
            if let Ok(cert) = reqwest::Certificate::from_pem(&pem) {
                b = b.add_root_certificate(cert);
            }
        }
    }
    b.build().expect("http client")
}

fn random_hex(n: usize) -> String {
    let mut buf = vec![0u8; n];
    fs::File::open("/dev/urandom")
        .expect("urandom")
        .read_exact(&mut buf)
        .expect("urandom read");
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

fn utc_rfc3339() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let hour = rem / 3600;
    let min = (rem % 3600) / 60;
    let sec = rem % 60;
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}T{hour:02}:{min:02}:{sec:02}Z")
}

// Howard Hinnant's civil-from-days (days since 1970-01-01 -> y-m-d).
fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097) as u32;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y as i32, m, d)
}

struct App {
    downstream: String,
    client: reqwest::blocking::Client,
    tokens: HashSet<String>,
    orders: HashMap<String, String>,
}

impl App {
    fn fetch(&self, path: &str) -> (u16, String) {
        match self.client.get(format!("{}{path}", self.downstream)).send() {
            Ok(r) => {
                let code = r.status().as_u16();
                let body = r.text().unwrap_or_default();
                (code, body)
            }
            Err(e) => (502, json!({"error": e.to_string()}).to_string()),
        }
    }

    fn handle(&mut self, mut stream: TcpStream) {
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut request_line = String::new();
        if reader.read_line(&mut request_line).is_err() {
            return;
        }
        let parts: Vec<&str> = request_line.split_whitespace().collect();
        let method = parts.first().copied().unwrap_or("GET");
        let path = parts.get(1).copied().unwrap_or("/");
        let mut auth: Option<String> = None;
        let mut content_length = 0usize;
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line).is_err() {
                return;
            }
            if line == "\r\n" || line == "\n" || line.is_empty() {
                break;
            }
            if let Some((k, v)) = line.split_once(':') {
                let k = k.trim();
                let v = v.trim().trim_end_matches(['\r', '\n']);
                if k.eq_ignore_ascii_case("Authorization") {
                    auth = Some(v.to_string());
                } else if k.eq_ignore_ascii_case("Content-Length") {
                    content_length = v.parse().unwrap_or(0);
                }
            }
        }
        let mut req_body = vec![0u8; content_length];
        if content_length > 0 && reader.read_exact(&mut req_body).is_err() {
            return;
        }
        let authed = auth
            .as_deref()
            .and_then(|h| h.strip_prefix("Bearer "))
            .map(|t| self.tokens.contains(t))
            .unwrap_or(false);

        let (code, body) = match (method, path) {
            ("GET", "/") => (
                200,
                json!({
                    "service": "proxymock-cncf-demo",
                    "lang": "rust",
                    "downstream": self.downstream,
                })
                .to_string(),
            ),
            ("GET", "/api/projects") => self.fetch("/v1/projects"),
            ("GET", p) if p.starts_with("/api/projects/") => {
                self.fetch(&format!("/v1/project/{}", &p["/api/projects/".len()..]))
            }
            ("GET", "/api/categories") => self.fetch("/v1/categories"),
            ("GET", "/api/stats") => {
                let (_, raw) = self.fetch("/v1/projects");
                let projects: Vec<Value> = serde_json::from_str(&raw).unwrap_or_default();
                let mut by = serde_json::Map::new();
                for proj in &projects {
                    if let Some(m) = proj.get("maturity").and_then(Value::as_str) {
                        let n = by.get(m).and_then(Value::as_u64).unwrap_or(0);
                        by.insert(m.to_string(), json!(n + 1));
                    }
                }
                (
                    200,
                    json!({"total": projects.len(), "by_maturity": Value::Object(by)}).to_string(),
                )
            }
            ("POST", "/oauth/token") => {
                let token = random_hex(32);
                self.tokens.insert(token.clone());
                (
                    200,
                    json!({
                        "access_token": token,
                        "token_type": "Bearer",
                        "expires_in": 3600
                    })
                    .to_string(),
                )
            }
            ("POST", "/api/orders") => {
                if !authed {
                    (
                        401,
                        json!({"error": "missing or invalid bearer token"}).to_string(),
                    )
                } else {
                    let parsed: Value = serde_json::from_slice(&req_body).unwrap_or(json!({}));
                    let project = parsed
                        .get("project")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    if project.is_empty() {
                        (400, json!({"error": "project is required"}).to_string())
                    } else {
                        let (dcode, _) = self.fetch(&format!("/v1/project/{project}"));
                        if dcode != 200 {
                            (
                                404,
                                json!({"error": "unknown project", "project": project}).to_string(),
                            )
                        } else {
                            let order_id = format!("order-{}", random_hex(8));
                            let order = json!({
                                "order_id": order_id,
                                "project": project,
                                "status": "created",
                                "created": utc_rfc3339(),
                            })
                            .to_string();
                            self.orders.insert(order_id, order.clone());
                            (201, order)
                        }
                    }
                }
            }
            ("GET", p) if p.starts_with("/api/orders/") => {
                if !authed {
                    (
                        401,
                        json!({"error": "missing or invalid bearer token"}).to_string(),
                    )
                } else {
                    let id = &p["/api/orders/".len()..];
                    match self.orders.get(id) {
                        Some(order) => (200, order.clone()),
                        None => (
                            404,
                            json!({"error": "order not found", "order_id": id}).to_string(),
                        ),
                    }
                }
            }
            _ => (404, json!({"error": "not found"}).to_string()),
        };

        let status = match code {
            200 => "200 OK",
            201 => "201 Created",
            400 => "400 Bad Request",
            401 => "401 Unauthorized",
            404 => "404 Not Found",
            _ => "502 Bad Gateway",
        };
        let resp = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(resp.as_bytes());
    }
}

fn main() {
    let downstream = downstream();
    let port = port();
    let listener = TcpListener::bind(("0.0.0.0", port)).expect("listen");
    println!("rust demo on :{port} (downstream={downstream})");
    let mut app = App {
        downstream,
        client: http_client(),
        tokens: HashSet::new(),
        orders: HashMap::new(),
    };
    for stream in listener.incoming() {
        if let Ok(stream) = stream {
            app.handle(stream);
        }
    }
}
