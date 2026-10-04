#!/usr/bin/env python3
"""A stand-in for the Rust broker's comparator service (its ADR D13), for
tests/e2e/rust-broker.sh.

A pact passes against a contract when the contract names every request path
in it, as a `  /path:` line of an OpenAPI YAML document; each missing path is
an error. It is no comparator, only enough to tell a pass from a fail.

    stub-comparator.py PORT
"""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def compare(contract, pact):
    paths = {line.strip()[:-1] for line in contract.splitlines() if line.startswith("  /")}
    interactions = pact.get("interactions") or pact.get("messages") or []
    return [
        {"type": "error", "message": f"{path} is not in the provider contract"}
        for path in (i.get("request", {}).get("path") for i in interactions)
        if path and path not in paths
    ]


class Handler(BaseHTTPRequestHandler):
    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") == "/info":
            self.reply({"name": "e2e-stub", "version": "1", "configuration": {}})
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path.rstrip("/") != "/compare":
            self.send_error(404)
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        contract = base64.b64decode(request["contract"]["content"]).decode()
        self.reply({
            "comparisons": [
                {"id": p["id"], "results": compare(contract, json.loads(base64.b64decode(p["content"])))}
                for p in request["pacts"]
            ]
        })

    def log_message(self, format, *args):
        sys.stderr.write("comparator: " + format % args + "\n")


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
