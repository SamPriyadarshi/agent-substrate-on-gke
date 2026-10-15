import json
import http.server
import socketserver
import os
import sys

PORT = int(os.environ.get("PORT", "8080"))
TOOL_NAME = os.environ.get("TOOL_NAME", "currency-tool")

class MCPHandler(http.server.BaseHTTPRequestHandler):
    def _send_json_response(self, code, data):
        payload = json.dumps(data).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        # Echo W3C traceparent if provided
        traceparent = self.headers.get("traceparent")
        if traceparent:
            self.send_header("traceparent", traceparent)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        # Health checks and SSE endpoint simulation
        if self.path == "/healthz":
            self._send_json_response(200, {"status": "healthy", "tool": TOOL_NAME})
            return
        elif self.path == "/sse":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            event_payload = f"event: endpoint\ndata: /messages?tool={TOOL_NAME}\n\n"
            self.wfile.write(event_payload.encode("utf-8"))
            self.wfile.flush()
            return
        self._send_json_response(404, {"error": "Not found"})

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8")
        try:
            req = json.loads(body) if body else {}
        except Exception as e:
            self._send_json_response(400, {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": f"Parse error: {str(e)}"}
            })
            return

        method = req.get("method", "")
        req_id = req.get("id", 1)

        # Standard Model Context Protocol (MCP) JSON-RPC 2.0 dispatch
        if method == "tools/list":
            if TOOL_NAME == "currency-tool":
                tools = [{
                    "name": "get_exchange_rate",
                    "description": "Fetch foreign exchange rate between two currency codes",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "from_currency": {"type": "string"},
                            "to_currency": {"type": "string"}
                        },
                        "required": ["from_currency", "to_currency"]
                    }
                }]
            elif TOOL_NAME == "database-tool":
                tools = [{
                    "name": "query_database",
                    "description": "Execute read-only SQL query against customer database",
                    "inputSchema": {
                        "type": "object",
                        "properties": {"query": {"type": "string"}},
                        "required": ["query"]
                    }
                }]
            elif TOOL_NAME == "search-tool":
                tools = [{
                    "name": "web_search",
                    "description": "Perform web search query",
                    "inputSchema": {
                        "type": "object",
                        "properties": {"query": {"type": "string"}},
                        "required": ["query"]
                    }
                }]
            else:
                tools = []

            self._send_json_response(200, {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"tools": tools}
            })
            return

        elif method == "tools/call":
            params = req.get("params", {})
            name = params.get("name", "")
            args = params.get("arguments", {})

            # Simulate tool response
            result_content = []
            if TOOL_NAME == "currency-tool" and name == "get_exchange_rate":
                from_c = args.get("from_currency", "USD")
                to_c = args.get("to_currency", "EUR")
                rate = 0.92 if from_c == "USD" and to_c == "EUR" else 1.10
                result_content = [{
                    "type": "text",
                    "text": json.dumps({"from": from_c, "to": to_c, "rate": rate, "status": "verified"})
                }]
            elif TOOL_NAME == "database-tool" and name == "query_database":
                result_content = [{
                    "type": "text",
                    "text": json.dumps({"rows": [{"id": 101, "customer": "Acme Corp", "balance": 450000}]})
                }]
            elif TOOL_NAME == "search-tool" and name == "web_search":
                result_content = [{
                    "type": "text",
                    "text": json.dumps({"results": [{"title": "GKE Istio Ambient Guide", "url": "https://cloud.google.com"}]})
                }]
            else:
                self._send_json_response(400, {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32601, "message": f"Method or tool '{name}' not found on {TOOL_NAME}"}
                })
                return

            self._send_json_response(200, {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"content": result_content}
            })
            return

        self._send_json_response(404, {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Unknown JSON-RPC method: {method}"}
        })

if __name__ == "__main__":
    print(f"Starting MCP Tool Server '{TOOL_NAME}' on port {PORT}...", flush=True)
    server = socketserver.TCPServer(("", PORT), MCPHandler)
    server.serve_forever()
