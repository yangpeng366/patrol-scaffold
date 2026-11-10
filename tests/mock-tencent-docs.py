"""Local mock of the Tencent Docs Smartsheet record API.

Serves the two endpoints the adapter uses so the read path can be exercised
without real credentials:
  GET  /oauth/v2/app-account-token
  POST /openapi/smartbook/v2/files/{fileID}/sheets/{sheetID}
"""
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE_ONE = {
    "ret": 0,
    "data": {
        "getRecords": {
            "total": 3,
            "hasMore": True,
            "next": 2,
            "records": [
                {
                    "recordID": "recAAA",
                    "values": {
                        "项目名": [{"type": "text", "text": "示例项目A-紧急"}],
                        "仓库路径": [{"type": "text", "text": "D:\\gitAll\\demo-a"}],
                        "下一步": [{"type": "text", "text": "跑通 dry-run"}],
                        "优先级": [{"type": "text", "text": "p0"}],
                        "巡检间隔(分钟)": 30,
                        "当前阶段": [{"type": "text", "text": "待处理"}],
                    },
                },
                {
                    "recordID": "recBBB",
                    "values": {
                        "项目名": [{"type": "text", "text": "示例项目B-常规"}],
                        "下一步": [{"type": "text", "text": "等下一轮"}],
                        "优先级": [{"type": "text", "text": "P1"}],
                        "巡检间隔(分钟)": 1440,
                        "当前阶段": [{"type": "text", "text": "归档"}],
                    },
                },
            ],
        }
    }
}

PAGE_TWO = {
    "ret": 0,
    "data": {
        "getRecords": {
            "total": 3,
            "hasMore": False,
            "next": 3,
            "records": [
                {
                    "recordID": "recCCC",
                    "values": {
                        "项目名": [{"type": "text", "text": "示例项目C-中等"}],
                        "下一步": [{"type": "text", "text": "推进中"}],
                        "优先级": [{"type": "text", "text": "P2"}],
                        "巡检间隔(分钟)": 0,
                        "最近巡检时间": [{"type": "text", "text": "1760000000000"}],
                    },
                }
            ],
        }
    }
}

SHEET_PATH = re.compile(r"^/openapi/smartbook/v2/files/[^/]+/sheets/[^/]+$")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _send(self, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/oauth/v2/app-account-token"):
            self._send({"access_token": "mock-token", "user_id": "mock-open-id", "expires_in": 1800})
            return
        self._send({"error": "not found", "path": self.path})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            body = {}
        offset = int((body.get("getRecords") or {}).get("offset") or 0)
        if SHEET_PATH.match(self.path):
            self._send(PAGE_ONE if offset == 0 else PAGE_TWO)
            return
        self._send({"error": "not found", "path": self.path, "body": body})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18923), Handler).serve_forever()
