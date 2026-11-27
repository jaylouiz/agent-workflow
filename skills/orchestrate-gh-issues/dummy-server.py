#!/usr/bin/env python3
"""Test fixture: serve the current directory on 127.0.0.1:<port>, the stand-in dev server of the test-*.sh suites.

Not `python3 -m http.server`: its HTTPServer.server_bind calls socket.getfqdn(), a reverse DNS lookup between bind
and listen. On a host whose resolver hangs (GitHub's macOS runners, mDNS) the port stays bound but never listens.
"""
import http.server
import socketserver
import sys


class Server(socketserver.TCPServer):
    allow_reuse_address = True


Server(("127.0.0.1", int(sys.argv[1])), http.server.SimpleHTTPRequestHandler).serve_forever()
